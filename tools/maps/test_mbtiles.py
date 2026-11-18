from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from validate_mbtiles import validate_mbtiles


class MBTilesTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'map.mbtiles'
        with closing(sqlite3.connect(self.path, isolation_level=None)) as db:
            db.executescript('CREATE TABLE metadata(name TEXT,value TEXT); CREATE TABLE tiles(zoom_level INTEGER,tile_column INTEGER,tile_row INTEGER,tile_data BLOB);')
            db.executemany('INSERT INTO metadata VALUES (?,?)',[('bounds','22.95,41.75,24.05,42.5'),('minzoom','0'),('maxzoom','14'),('format','pbf'),('json',json.dumps({'vector_layers':[{'id':'transportation'}]}))])
            db.execute('INSERT INTO tiles VALUES (14,9250,6100,?)',(b'nonempty tile fixture',))

    def test_valid_declared_region(self):
        self.assertEqual(validate_mbtiles(self.path,[229500000,417500000,240500000,425000000])['tileCount'],1)

    def test_zero_area_missing_or_mismatched_bounds_fail_before_conversion(self):
        for bounds in ['0,0,0,0','22.95,41.75,24.05,nan','22,41,24,43','bad']:
            with closing(sqlite3.connect(self.path, isolation_level=None)) as db: db.execute("UPDATE metadata SET value=? WHERE name='bounds'",(bounds,))
            with self.subTest(bounds=bounds), self.assertRaisesRegex(ValueError,'bounds'): validate_mbtiles(self.path,[229500000,417500000,240500000,425000000])

    def test_empty_tiles_fail(self):
        with closing(sqlite3.connect(self.path, isolation_level=None)) as db: db.execute('DELETE FROM tiles')
        with self.assertRaisesRegex(ValueError,'tiles'): validate_mbtiles(self.path,[229500000,417500000,240500000,425000000])

    def test_missing_bounds_fail(self):
        with closing(sqlite3.connect(self.path, isolation_level=None)) as db: db.execute("DELETE FROM metadata WHERE name='bounds'")
        with self.assertRaisesRegex(ValueError,'bounds'): validate_mbtiles(self.path,[229500000,417500000,240500000,425000000])
