"""Cache the frozen Bulgaria source only after its size and hash match."""
from pathlib import Path
import subprocess
import sys
import tempfile

from pack import sha256_file

SOURCE_URL = "https://download.geofabrik.de/europe/bulgaria-261116.osm.pbf"
SOURCE_SHA256 = "032898493cabce0157fd3e3b907dd7fab78dd1e8ec220759a7b113c67a9b71fe"
SOURCE_BYTES = 177664451


def cache_source(output, url, size, digest):
    def verified(path):
        return path.is_file() and path.stat().st_size == size and sha256_file(path) == digest

    if verified(output):
        return
    with tempfile.TemporaryDirectory(prefix=".pbf-", dir=output.parent) as directory:
        download = Path(directory) / output.name
        subprocess.run([
            "curl", "--fail", "--location", "--retry", "3", "--max-filesize", str(size),
            "--output", str(download), url,
        ], check=True)
        if not verified(download):
            raise ValueError("frozen PBF size or SHA256 mismatch")
        download.replace(output)


if __name__ == "__main__":
    cache_source(Path(sys.argv[1]), SOURCE_URL, SOURCE_BYTES, SOURCE_SHA256)
