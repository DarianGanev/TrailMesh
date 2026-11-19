#!/usr/bin/env bash
# AGP removes the APKs after connected tests. Run both phases on the separately
# installed app so the restart test can only pass by reopening the saved pack.
set -euo pipefail
pack="${1:?device pack path required}"
manifest_sha="${2:?manifest SHA-256 required}"
render="${3:?render mode required}"
output="${4:?output directory required}"
ADB_BIN="${ADB_BIN:-adb}"
runner=org.trailmesh.app.test/androidx.test.runner.AndroidJUnitRunner

for phase in install verify; do
  if [[ "$phase" == verify ]]; then
    "$ADB_BIN" shell am force-stop org.trailmesh.app
  fi
  log="$output/map-$phase.txt"
  "$ADB_BIN" shell am instrument -w -r \
    -e class org.trailmesh.app.maps.OfflineRegionSmokeTest \
    -e trailmeshMapPack "$pack" -e trailmeshRequireMapPack true \
    -e trailmeshMapPhase "$phase" -e trailmeshMapRender "$render" \
    -e trailmeshManifestSha256 "$manifest_sha" "$runner" | tee "$log"
  grep -Eq '^OK \(1 test\)' "$log"
done
