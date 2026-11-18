from contextlib import closing
"""Fail clearly on incomplete tilemaker output before PMTiles conversion."""
import json
import math
from pathlib import Path
import sqlite3
import sys


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
        return dict(bounds=bounds,tileCount=count,minZoom=0,maxZoom=14,sqliteIntegrity='ok')


if __name__=='__main__':
    metadata=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
    print(json.dumps(validate_mbtiles(sys.argv[1],metadata['boundsE7']),sort_keys=True))
