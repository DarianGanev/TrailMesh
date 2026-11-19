from contextlib import closing
import gzip
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from validate_mbtiles import validate_mbtiles


# MVT 2 layer "transportation", extent 4096, with one point at (1, 2).
POINT_TILE = bytes.fromhex('1a1e78020a0e7472616e73706f72746174696f6e120718012203090204288020')


class MBTilesTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'map.mbtiles'
        with closing(sqlite3.connect(self.path, isolation_level=None)) as db:
            db.executescript('CREATE TABLE metadata(name TEXT,value TEXT); CREATE TABLE tiles(zoom_level INTEGER,tile_column INTEGER,tile_row INTEGER,tile_data BLOB);')
            db.executemany('INSERT INTO metadata VALUES (?,?)',[('bounds','22.95,41.75,24.05,42.5'),('minzoom','0'),('maxzoom','14'),('format','pbf'),('json',json.dumps({'vector_layers':[{'id':'transportation'}]}))])
            db.execute('INSERT INTO tiles VALUES (14,9250,6100,?)',(gzip.compress(POINT_TILE),))

    def test_valid_declared_region(self):
        with closing(sqlite3.connect(self.path, isolation_level=None)) as db:
            db.execute('INSERT INTO tiles VALUES (14,9251,6100,?)',(gzip.compress(b''),))
        self.assertEqual(validate_mbtiles(self.path,[229500000,417500000,240500000,425000000])['tileCount'],2)

    def test_zero_area_missing_or_mismatched_bounds_fail_before_conversion(self):
        for bounds in ['0,0,0,0','22.95,41.75,24.05,nan','22,41,24,43','bad']:
            with closing(sqlite3.connect(self.path, isolation_level=None)) as db: db.execute("UPDATE metadata SET value=? WHERE name='bounds'",(bounds,))
            with self.subTest(bounds=bounds), self.assertRaisesRegex(ValueError,'bounds'): validate_mbtiles(self.path,[229500000,417500000,240500000,425000000])

    def test_empty_tiles_fail(self):
        with closing(sqlite3.connect(self.path, isolation_level=None)) as db: db.execute('DELETE FROM tiles')
        with self.assertRaisesRegex(ValueError,'tiles'): validate_mbtiles(self.path,[229500000,417500000,240500000,425000000])

    def test_every_payload_must_be_a_bounded_gzip_vector_tile(self):
        valid_gzip = gzip.compress(POINT_TILE)
        for payload in (
            b'not a vector tile',
            POINT_TILE,
            valid_gzip[:-1],
            valid_gzip + gzip.compress(POINT_TILE),
            gzip.compress(b'not a vector tile'),
            gzip.compress(bytes.fromhex('0801')),  # Nonempty protobuf with no MVT layers.
            gzip.compress(bytes.fromhex('1a00')),  # Layer lacks required fields.
            gzip.compress(POINT_TILE.replace(b'\x09\x02\x04', b'\x00\x02\x04')),
            gzip.compress(b'\x00' * (16 * 1024 * 1024 + 1)),
            valid_gzip + b'\x00' * (16 * 1024 * 1024),
        ):
            with closing(sqlite3.connect(self.path, isolation_level=None)) as db:
                db.execute('INSERT OR REPLACE INTO tiles(rowid,zoom_level,tile_column,tile_row,tile_data) VALUES (2,14,9251,6100,?)', (payload,))
            with self.subTest(payload=payload[:24]), self.assertRaisesRegex(ValueError, '14/9251/6100'):
                validate_mbtiles(self.path,[229500000,417500000,240500000,425000000])

    def test_missing_bounds_fail(self):
        with closing(sqlite3.connect(self.path, isolation_level=None)) as db: db.execute("DELETE FROM metadata WHERE name='bounds'")
        with self.assertRaisesRegex(ValueError,'bounds'): validate_mbtiles(self.path,[229500000,417500000,240500000,425000000])
