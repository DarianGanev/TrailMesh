"""Synthetic PNGs here test decoding only; they are never shipped as map data."""
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest
import zlib

from tools.maps.terrain import build_mbtiles, tile_coordinates, validate_png


def png():
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 256, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + b"\x80\0\0" * 256) * 256)) + chunk(b"IEND", b""))


class TerrainTests(unittest.TestCase):
    def test_coordinates_cover_rila_and_are_bounded(self):
        tiles = tile_coordinates([22.95, 41.75, 24.05, 42.50], 10, 12)
        self.assertIn((12, 2313, 1517), tiles)
        self.assertEqual(len(set(tiles)), len(tiles))
        self.assertLess(len(tiles), 1000)
        for bounds in ([170, 40, -170, 45], [0, float("nan"), 1, 2], [-181, 0, 1, 2], [0, 0, 0, 1]):
            with self.assertRaises(ValueError):
                tile_coordinates(bounds, 10, 12)
        with self.assertRaises(ValueError):
            tile_coordinates([-180, -80, 180, 80], 10, 12)

    def test_png_rejects_corruption_trailing_data_and_oversized_input(self):
        image = png()
        validate_png(image)
        for bad in (b"<html>error</html>", image[:-1], image + b"extra", image[:40] + bytes([image[40] ^ 1]) + image[41:]):
            with self.assertRaises(ValueError):
                validate_png(bad)
        with self.assertRaises(ValueError):
            validate_png(b"x" * (1024 * 1024 + 1))

    def test_png_bounds_decompression_even_for_valid_chunk_checksums(self):
        image = png()
        compressed = zlib.compress(b"x" * (4 * 1024 * 1024))
        chunk = (struct.pack(">I", len(compressed)) + b"IDAT" + compressed
                 + struct.pack(">I", zlib.crc32(b"IDAT" + compressed)))
        # Keep the valid header and IEND, replacing only the pixel stream.
        bad = image[:33] + chunk + image[-12:]
        with self.assertRaisesRegex(ValueError, "pixel stream size mismatch"):
            validate_png(bad)

    def test_build_writes_tms_rows_and_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "terrain.mbtiles"
            calls = []
            def fetch(z, x, y):
                calls.append((z,x,y))
                return png(), {"imagerySources":"eudem/test.tif", "lastModified":"2017-11-22", "versionId":"test"}
            lock = build_mbtiles(output, [23.36, 42.16, 23.38, 42.18], 10, 10, fetch=fetch)
            with sqlite3.connect(output) as db:
                self.assertEqual(db.execute("SELECT tile_row FROM tiles").fetchone()[0], 2**10 - 1 - calls[0][2])
                self.assertEqual(dict(db.execute("SELECT name,value FROM metadata"))["format"], "png")
            db.close()
            self.assertEqual(lock["tiles"][0]["imagerySources"], "eudem/test.tif")
            self.assertEqual(len(lock["tiles"][0]["sha256"]), 64)
            with self.assertRaises(FileExistsError):
                build_mbtiles(output, [23.36, 42.16, 23.38, 42.18], 10, 10, fetch=fetch)

    def test_lock_mismatch_never_publishes_database(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "terrain.mbtiles"
            bounds = [23.36, 42.16, 23.38, 42.18]
            lock = {"format":1,"bounds":bounds,"minZoom":10,"maxZoom":10,"tiles":[{"z":10,"x":578,"y":379,"sha256":"0"*64}]}
            with self.assertRaises(ValueError):
                build_mbtiles(output, bounds, 10, 10, fetch=lambda *args: (png(),{}), lock=lock)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_suffix(".mbtiles.partial").exists())

if __name__ == "__main__":
    unittest.main()
