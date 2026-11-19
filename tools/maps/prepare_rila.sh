#!/usr/bin/env bash
# Run on Ubuntu 24.04. Outputs remain outside the checkout.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(realpath -m "${1:?usage: prepare_rila.sh /absolute/output}")
mkdir -p "$OUT/work" "$OUT/pack" "$OUT/release-assets"
PM_SHA=3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f
IMAGE=ghcr.io/valhalla/valhalla:3.9.2@sha256:1c68a8c0f870a018b3b04dddee4b21ef2f41d24bbda68fa7b48e2bee053d5eef
cd "$OUT/work"
python3 "$ROOT/tools/maps/fetch_pbf.py" bulgaria.osm.pbf
osmium extract --bbox 22.95,41.75,24.05,42.50 --set-bounds --strategy complete_ways --overwrite bulgaria.osm.pbf -o rila.osm.pbf
osmium fileinfo --json rila.osm.pbf > "$OUT/osm-fileinfo.json"
curl --fail --location --retry 3 https://github.com/protomaps/go-pmtiles/releases/download/v1.31.2/go-pmtiles_1.31.2_Linux_x86_64.tar.gz -o pmtiles.tgz
echo "$PM_SHA  pmtiles.tgz" | sha256sum -c -
tar xzf pmtiles.tgz pmtiles
python3 "$ROOT/tools/maps/prepare_tilemaker.py" "$ROOT/tools/maps/upstream" "$OUT/work"
tilemaker --input rila.osm.pbf --bbox 22.95,41.75,24.05,42.50 --output rila.mbtiles --config config.json --process process.lua
python3 "$ROOT/tools/maps/validate_mbtiles.py" rila.mbtiles "$ROOT/tools/maps/rila-metadata.json" > "$OUT/mbtiles-evidence.json"
./pmtiles convert rila.mbtiles "$OUT/pack/map.pmtiles"
./pmtiles verify "$OUT/pack/map.pmtiles"
./pmtiles show "$OUT/pack/map.pmtiles" --metadata > "$OUT/map-metadata.json"
cp -R "$ROOT/tools/maps/assets/." "$OUT/pack/"
cp "$ROOT/tools/maps/style.json" "$OUT/pack/style.json"
cp "$ROOT/tools/maps/upstream/NOTICE.txt" "$OUT/pack/licenses/Tilemaker-OpenMapTiles.txt"
python3 "$ROOT/tools/maps/extract_places.py" rila.osm.pbf "$OUT/pack/places.json" "$OUT/route-smoke.json"
mkdir -p "$OUT/tiles"
docker pull "$IMAGE"
docker run --rm --entrypoint bash -v "$OUT:/data" "$IMAGE" -euc '
  valhalla_build_config --mjolnir-tile-dir /data/tiles --mjolnir-tile-extract /data/pack/routing.tar > /data/valhalla.json
  valhalla_build_tiles -c /data/valhalla.json /data/work/rila.osm.pbf
  valhalla_build_extract -c /data/valhalla.json
  test -s /data/pack/routing.tar
'
# Root supplies real, licensed DEM pipeline; terrain is optional until that step succeeds.
if [[ -f "$ROOT/tools/maps/terrain.py" ]]; then
  python3 "$ROOT/tools/maps/terrain.py" "$OUT/work/terrain.mbtiles" --lock "$ROOT/tools/maps/terrain-lock.json" --write-lock "$OUT/terrain-evidence.json"
  ./pmtiles convert "$OUT/work/terrain.mbtiles" "$OUT/pack/terrain.pmtiles"
  ./pmtiles verify "$OUT/pack/terrain.pmtiles"
fi
python3 "$ROOT/tools/maps/finalize.py" "$OUT" "$ROOT"
node "$ROOT/tools/maps/validate-style.cjs" "$OUT/pack/style.json"
cp "$OUT/route-smoke.json" "$OUT/smoke.json"
python3 "$ROOT/tools/maps/pack.py" "$OUT/pack" "$ROOT/tools/maps/rila-metadata.json" | tee "$OUT/manifest.sha256"
python3 - "$OUT" <<'PY'
import json,pathlib,shutil,sys
p=pathlib.Path(sys.argv[1]); m=json.loads((p/'pack/manifest.json').read_text())
for f in m['files']: shutil.copyfile(p/'pack'/f['path'],p/'release-assets'/f['asset'])
shutil.copyfile(p/'pack/manifest.json',p/'release-assets/manifest.json')
shutil.copyfile(p/'work/rila.osm.pbf',p/'release-assets/rila-source.osm.pbf')
PY
