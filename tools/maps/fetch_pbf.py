"""Cache the frozen Bulgaria source only after its size and hash match."""
from pathlib import Path
import subprocess
import sys
import tempfile

from pack import sha256_file

SOURCE_URL = "https://download.geofabrik.de/europe/bulgaria-261116.osm.pbf"
SOURCE_ARCHIVE_URL = (
    "https://github.com/DarianGanev/TrailMesh/releases/download/"
    "map-source-bulgaria-2026-11-16/bulgaria-261116.osm.pbf"
)
SOURCE_SHA256 = "032898493cabce0157fd3e3b907dd7fab78dd1e8ec220759a7b113c67a9b71fe"
SOURCE_BYTES = 177664451
RETRYABLE_CURL_ERRORS = {5, 6, 7, 18, 28, 52, 55, 56}
UNAVAILABLE_HTTP_STATUS = {"404", "408", "410", "429", "500", "502", "503", "504"}


def cache_source(output, url, size, digest, *, fallback_url=None):
    def verified(path):
        return path.is_file() and path.stat().st_size == size and sha256_file(path) == digest

    def download_from(url, target):
        subprocess.run([
            "curl", "--fail", "--location", "--retry", "3", "--max-filesize", str(size),
            "--write-out", "%{http_code}", "--output", str(target), url,
        ], check=True, stdout=subprocess.PIPE, text=True)

    if verified(output):
        return
    with tempfile.TemporaryDirectory(prefix=".pbf-", dir=output.parent) as directory:
        download = Path(directory) / output.name
        try:
            download_from(url, download)
        except subprocess.CalledProcessError as error:
            unavailable = error.returncode in RETRYABLE_CURL_ERRORS or (
                error.returncode == 22 and error.stdout in UNAVAILABLE_HTTP_STATUS
            )
            if not fallback_url or not unavailable:
                raise
            print("Frozen Geofabrik extract unavailable; trying its pinned archive.", file=sys.stderr)
            download.unlink(missing_ok=True)
            download_from(fallback_url, download)
        if not verified(download):
            raise ValueError("frozen PBF size or SHA256 mismatch")
        download.replace(output)


if __name__ == "__main__":
    cache_source(Path(sys.argv[1]), SOURCE_URL, SOURCE_BYTES, SOURCE_SHA256, fallback_url=SOURCE_ARCHIVE_URL)
