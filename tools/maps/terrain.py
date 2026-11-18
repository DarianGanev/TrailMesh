"""Prepare real Terrarium elevation tiles for local MapLibre hillshading.

The source is the account-free Mapzen AWS Open Data bucket. This utility
preserves source pixels and records hashes and imagery-source provenance.
It produces PNG MBTiles for conversion with the pinned PMTiles CLI.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
import math
from pathlib import Path
import sqlite3
import struct
import urllib.request
import zlib

SOURCE = "https://elevation-tiles-prod.s3.amazonaws.com/terrarium"
MAX_TILE_BYTES = 1024 * 1024
ATTRIBUTION = (
    "Mapzen Terrain Tiles; Europe terrain produced using Copernicus data and "
    "information funded by the European Union — EU-DEM layers; SRTM terrain "
    "data courtesy of the U.S. Geological Survey."
)
ATTRIBUTION_HTML = (
    '<a href="https://registry.opendata.aws/terrain-tiles/">Mapzen Terrain Tiles</a> / '
    '<a href="https://land.copernicus.eu/en/faq/data-use-terms-and-conditions">Copernicus EU-DEM</a> / '
    '<a href="https://www.usgs.gov/">USGS</a>'
)


def tile_coordinates(bounds, min_zoom=10, max_zoom=12):
    """Return a bounded deterministic XYZ tile set for a non-wrapping region."""
    if (len(bounds) != 4 or any(type(v) not in (int, float) or not math.isfinite(v) for v in bounds)
            or not -180 <= bounds[0] < bounds[2] <= 180
            or not -85.05112878 <= bounds[1] < bounds[3] <= 85.05112878
            or type(min_zoom) is not int or type(max_zoom) is not int
            or not 10 <= min_zoom <= max_zoom <= 12):
        raise ValueError("invalid bounded terrain region")
    west, south, east, north = bounds
    result = []
    for zoom in range(min_zoom, max_zoom + 1):
        count = 2**zoom
        def x_for(lon):
            return min(count - 1, max(0, math.floor((lon + 180) / 360 * count)))
        def y_for(lat):
            return min(count - 1, max(0, math.floor((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * count)))
        x0, x1, y0, y1 = x_for(west), x_for(east), y_for(north), y_for(south)
        if len(result) + (x1 - x0 + 1) * (y1 - y0 + 1) > 1000:
            raise ValueError("terrain region exceeds 1000 tiles")
        result.extend((zoom, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1))
    return result


def validate_png(data):
    """Reject truncated/oversized PNGs and invalid Terrarium RGB pixel streams."""
    if len(data) > MAX_TILE_BYTES or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("invalid terrain PNG")
    offset, compressed, seen_header, finished = 8, bytearray(), False, False
    while offset + 12 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        if length > MAX_TILE_BYTES or offset + length + 12 > len(data):
            raise ValueError("truncated PNG chunk")
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        if zlib.crc32(kind + payload) != crc:
            raise ValueError("terrain PNG checksum mismatch")
        if not seen_header:
            if kind != b"IHDR" or length != 13 or struct.unpack(">IIBBBBB", payload) != (256, 256, 8, 2, 0, 0, 0):
                raise ValueError("terrain must be 256px RGB8 noninterlaced PNG")
            seen_header = True
        elif kind == b"IHDR":
            raise ValueError("duplicate PNG header")
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            if length or offset + 12 != len(data):
                raise ValueError("invalid PNG end")
            finished = True
            break
        offset += length + 12
    if not finished or not compressed:
        raise ValueError("incomplete terrain PNG")
    expected = (256 * 3 + 1) * 256
    decoder = zlib.decompressobj()
    try:
        raw = decoder.decompress(compressed, expected + 1)
    except zlib.error as error:
        raise ValueError("invalid terrain pixel stream") from error
    if len(raw) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("terrain pixel stream size mismatch")
    if any(raw[row * 769] > 4 for row in range(256)):
        raise ValueError("invalid PNG row filter")


def fetch_tile(zoom, x, y):
    url = f"{SOURCE}/{zoom}/{x}/{y}.png"
    request = urllib.request.Request(url, headers={"User-Agent": "TrailMesh-region-builder/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        if response.status != 200 or not response.geturl().startswith(SOURCE + "/"):
            raise ValueError("unexpected terrain response")
        data = response.read(MAX_TILE_BYTES + 1)
        metadata = {
            "imagerySources": response.headers.get("x-amz-meta-x-imagery-sources", ""),
            "lastModified": response.headers.get("Last-Modified", ""),
            "versionId": response.headers.get("x-amz-version-id", ""),
        }
    # Rila uses EU-DEM with SRTM gap filling. Fail on an unreviewed source
    # instead of silently redistributing data with different license terms.
    sources = [value.strip() for value in metadata["imagerySources"].split(",")]
    if not sources or any(not item.startswith(("eudem/", "srtm/")) for item in sources):
        raise ValueError("terrain source requires license review")
    return data, metadata


def build_mbtiles(output, bounds, min_zoom=10, max_zoom=12, *, fetch=fetch_tile, lock=None):
    """Publish a complete MBTiles file or leave no partial database on failure."""
    output = Path(output)
    if output.exists():
        raise FileExistsError(output)
    tiles = tile_coordinates(bounds, min_zoom, max_zoom)
    locked = None
    if lock is not None:
        if (lock.get("format") != 1 or lock.get("bounds") != list(bounds)
                or lock.get("minZoom") != min_zoom or lock.get("maxZoom") != max_zoom):
            raise ValueError("terrain lock region mismatch")
        locked = {(item["z"], item["x"], item["y"]): item["sha256"] for item in lock["tiles"]}
        if len(locked) != len(lock["tiles"]) or set(locked) != set(tiles):
            raise ValueError("terrain lock tile set mismatch")
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_suffix(output.suffix + ".partial")
    # Exclusive creation prevents two preparations from sharing a database.
    with partial.open("xb"):
        pass
    records = []
    try:
        with sqlite3.connect(partial) as database:
            database.executescript(
                "CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT NOT NULL);"
                "CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB,"
                "PRIMARY KEY (zoom_level,tile_column,tile_row));"
            )
            database.executemany("INSERT INTO metadata VALUES (?,?)", {
                "name": "Rila shaded relief", "description": ATTRIBUTION,
                "attribution": ATTRIBUTION_HTML, "format": "png", "type": "baselayer",
                "version": "1", "bounds": ",".join(map(str, bounds)),
                "minzoom": str(min_zoom), "maxzoom": str(max_zoom), "encoding": "terrarium",
            }.items())
            # executor.map preserves tile order for reproducible provenance.
            with ThreadPoolExecutor(max_workers=4) as pool:
                def fetched_batches():
                    for start in range(0, len(tiles), 4):
                        yield from pool.map(lambda tile: fetch(*tile), tiles[start:start + 4])
                for (zoom, x, y), (data, metadata) in zip(tiles, fetched_batches()):
                    validate_png(data)
                    digest = hashlib.sha256(data).hexdigest()
                    if locked is not None and locked[(zoom, x, y)] != digest:
                        raise ValueError("terrain lock checksum mismatch")
                    database.execute("INSERT INTO tiles VALUES (?,?,?,?)", (zoom, x, 2**zoom - 1 - y, data))
                    records.append({"z": zoom, "x": x, "y": y, "sha256": digest, **metadata})
            database.commit()
            if database.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("terrain database integrity failure")
        # On Windows SQLite's context manager commits, but does not close.
        database.close()
        # Linking publishes atomically and fails if another builder already won.
        os.link(partial, output)
    except BaseException:
        if "database" in locals():
            database.close()
        partial.unlink(missing_ok=True)
        raise
    partial.unlink()
    return {"format": 1, "source": SOURCE, "accessedAt": datetime.now(timezone.utc).isoformat(),
            "bounds": list(bounds), "minZoom": min_zoom, "maxZoom": max_zoom, "tiles": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bounds", nargs=4, type=float, default=[22.95, 41.75, 24.05, 42.50])
    parser.add_argument("--lock", type=Path)
    parser.add_argument("--write-lock", type=Path, required=True)
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text(encoding="utf-8")) if args.lock else None
    result = build_mbtiles(args.output, args.bounds, lock=lock)
    args.write_lock.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {len(result['tiles'])} real terrain tiles: {args.output}")


if __name__ == "__main__":
    main()
