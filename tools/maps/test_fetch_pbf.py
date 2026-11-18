import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from fetch_pbf import cache_source


class SourceCacheTests(unittest.TestCase):
    def test_failed_download_retries_then_reuses_verified_cache(self):
        complete = b"complete source"
        digest = hashlib.sha256(complete).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "source.osm.pbf"

            def disconnect(command, **kwargs):
                download = Path(command[-2])
                self.assertFalse(output.exists())
                download.write_bytes(b"partial")
                raise subprocess.CalledProcessError(18, command)

            with patch("fetch_pbf.subprocess.run", side_effect=disconnect), self.assertRaises(subprocess.CalledProcessError):
                cache_source(output, "https://example.invalid", len(complete), digest)
            self.assertEqual(list(output.parent.iterdir()), [])

            def invalid_download(command, **kwargs):
                Path(command[-2]).write_bytes(b"!" * len(complete))

            with patch("fetch_pbf.subprocess.run", side_effect=invalid_download), self.assertRaisesRegex(ValueError, "SHA256"):
                cache_source(output, "https://example.invalid", len(complete), digest)
            self.assertEqual(list(output.parent.iterdir()), [])

            output.write_bytes(b"old truncated cache")

            def valid_download(command, **kwargs):
                self.assertEqual(output.read_bytes(), b"old truncated cache")
                Path(command[-2]).write_bytes(complete)

            with patch("fetch_pbf.subprocess.run", side_effect=valid_download) as run:
                cache_source(output, "https://example.invalid", len(complete), digest)
                cache_source(output, "https://example.invalid", len(complete), digest)
                run.assert_called_once()
            self.assertEqual(output.read_bytes(), complete)
            self.assertEqual(list(output.parent.iterdir()), [output])
