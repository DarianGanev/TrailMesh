"""Fail clearly on incomplete tilemaker output before PMTiles conversion."""
from contextlib import closing
import json
import math
from pathlib import Path
import sqlite3
import sys
import zlib

from google.protobuf.message import DecodeError
from mapbox_vector_tile.Mapbox.vector_tile_pb2 import tile as VectorTile


MAX_COMPRESSED_BYTES = 16 * 1024 * 1024
MAX_DECOMPRESSED_BYTES = 16 * 1024 * 1024


def valid_geometry(feature):
    # MVT geometry is a sequence of packed commands and coordinate operands.
    commands = feature.geometry
    if feature.type == VectorTile.GeomType.Point:
        return (len(commands) > 1 and commands[0] & 7 == 1
                and len(commands) == 1 + 2 * (commands[0] >> 3))
    if feature.type not in (VectorTile.GeomType.LineString, VectorTile.GeomType.Polygon) or not commands:
        return False

    polygon = feature.type == VectorTile.GeomType.Polygon
    index = 0
    while index < len(commands):
        if index + 3 >= len(commands) or commands[index] != 9:  # MoveTo(1), x, y
            return False
        line_to = commands[index + 3]
        count = line_to >> 3
        if line_to & 7 != 2 or count < (2 if polygon else 1):
            return False
        index += 4 + 2 * count
        if polygon:
            if index >= len(commands) or commands[index] != 15:  # ClosePath(1)
                return False
            index += 1
    return index == len(commands)


def validate_vector_tile(compressed):
    if compressed is None:
        raise ValueError('expected a bounded gzip blob')
    gzip = zlib.decompressobj(wbits=16 + zlib.MAX_WBITS)
    raw = gzip.decompress(compressed, MAX_DECOMPRESSED_BYTES + 1)
    if len(raw) > MAX_DECOMPRESSED_BYTES or not gzip.eof or gzip.unused_data:
        raise ValueError('invalid or oversized gzip stream')

    # Tilemaker also emits the canonical empty tile for some edge coordinates.
    if not raw:
        return
    tile = VectorTile.FromString(raw)
    if not tile.IsInitialized() or not tile.layers:
        raise ValueError('missing vector tile layers or required layer fields')
    names = set()
    for layer in tile.layers:
        if layer.version != 2 or not layer.name or not layer.extent or layer.name in names:
            raise ValueError('invalid vector tile layer')
        names.add(layer.name)
        for feature in layer.features:
            tags = feature.tags
            if (len(tags) % 2 or any(key >= len(layer.keys) for key in tags[::2])
                    or any(value >= len(layer.values) for value in tags[1::2])):
                raise ValueError('invalid vector tile feature tags')
            if not valid_geometry(feature):
                raise ValueError('invalid vector tile feature geometry')


def validate_mbtiles(path, bounds_e7):
    with closing(sqlite3.connect(Path(path).resolve().as_uri()+'?mode=ro',uri=True)) as db:
        if db.execute('PRAGMA integrity_check').fetchall()!=[('ok',)]:
            raise ValueError('tilemaker MBTiles SQLite integrity failure')
        rows=db.execute('SELECT name,value FROM metadata').fetchall()
        metadata=dict(rows)
        if len(rows)!=len(metadata): raise ValueError('duplicate MBTiles metadata')
        try: bounds=[float(v) for v in metadata['bounds'].split(',')]
        except (KeyError,ValueError): raise ValueError('missing or invalid MBTiles bounds') from None
        if (len(bounds)!=4 or not all(math.isfinite(v) for v in bounds)
                or not -180<=bounds[0]<bounds[2]<=180
                or not -85.05112878<=bounds[1]<bounds[3]<=85.05112878
                or any(abs(a-b/1e7)>1e-7 for a,b in zip(bounds,bounds_e7))):
            raise ValueError('MBTiles bounds must equal declared nonzero region; preserve extract header with --set-bounds')
        if metadata.get('minzoom')!='0' or metadata.get('maxzoom')!='14' or metadata.get('format')!='pbf':
            raise ValueError('unexpected MBTiles format or zoom range')
        count=db.execute('SELECT count(*) FROM tiles').fetchone()[0]
        if not count or db.execute('SELECT count(*) FROM tiles WHERE tile_data IS NULL OR length(tile_data)=0 OR zoom_level<0 OR zoom_level>14 OR tile_column<0 OR tile_row<0 OR tile_column>=(1<<zoom_level) OR tile_row>=(1<<zoom_level)').fetchone()[0]:
            raise ValueError('MBTiles tiles missing, empty or outside valid tile coordinates')
        try: layers=json.loads(metadata['json'])['vector_layers']
        except (KeyError,ValueError,TypeError): raise ValueError('missing MBTiles vector layer metadata') from None
        if not isinstance(layers,list) or not layers: raise ValueError('empty MBTiles vector layer metadata')
        tiles = db.execute(
            "SELECT zoom_level, tile_column, tile_row, CASE "
            "WHEN typeof(tile_data) = 'blob' AND length(tile_data) <= ? THEN tile_data END FROM tiles",
            (MAX_COMPRESSED_BYTES,),
        )
        for zoom, column, row, compressed in tiles:
            try:
                validate_vector_tile(compressed)
            except (DecodeError, ValueError, zlib.error) as error:
                raise ValueError(f'invalid MBTiles vector tile at {zoom}/{column}/{row}: {error}') from error
        return dict(bounds=bounds,tileCount=count,minZoom=0,maxZoom=14,sqliteIntegrity='ok')


if __name__=='__main__':
    metadata=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
    print(json.dumps(validate_mbtiles(sys.argv[1],metadata['boundsE7']),sort_keys=True))
