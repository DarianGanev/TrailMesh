import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

BUNDLE = "org.trailmesh.ios"
BASE = Path(sys.argv[1])
OUTPUT = BASE / "TrailMeshScreens"

STARTUP = (
    "opening-rila first-download downloading-rila download-failed download-insufficient-space "
    "map-repair map-missing-resource map-replace-confirmation map-open-failed"
).split()
SCREENS = (
    "map-loading explore explore-location explore-location-denied explore-location-unavailable "
    "offline-maps map-credits "
    "search-empty search-results search-no-results place-details "
    "route-planner route-start-picker route-destination-picker route-location route-location-denied "
    "route-loading route-no-result route-result route-preview "
    "guidance-waiting guidance-active guidance-centering-paused guidance-location-denied "
    "reports-empty reports-recent reports-expired-empty reports-expired reports-loading reports-more reports-failed "
    "reports-clock-confirmation reports-cleanup-confirmation report-details report-details-expired report-on-map report-saved "
    "report-compose report-pin-picker report-pin-outside report-pin-selected report-ready-to-save "
    "report-location report-location-pending report-location-denied report-location-unavailable "
    "report-note-too-long report-saving report-storage-error "
    "nearby-idle nearby-area-picker nearby-area-outside nearby-area-selected nearby-consented nearby-opening "
    "nearby-active nearby-active-route nearby-received nearby-paused nearby-stopped nearby-interrupted "
    "nearby-bluetooth-off nearby-bluetooth-denied nearby-bluetooth-unsupported nearby-bluetooth-pending "
    "nearby-storage-failed nearby-radio-failed nearby-route-unavailable "
    "diagnostics diagnostics-maps diagnostics-clock-confirmation diagnostics-cleanup-confirmation"
).split()


def command(*args, **kwargs):
    return subprocess.run(["xcrun", "simctl", *map(str, args)], check=True, text=True, **kwargs)


def capture(simulator, data, manifest_hash, number, name):
    subprocess.run(["xcrun", "simctl", "terminate", simulator, BUNDLE],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    marker = data / "Documents/capture-status.txt"
    marker.unlink(missing_ok=True)
    reports = data / "Library/Application Support/TrailMeshReports"
    for suffix in ("", "-wal", "-shm"):
        (reports / ("field-reports.sqlite" + suffix)).unlink(missing_ok=True)
    env = dict(os.environ, SIMCTL_CHILD_TRAILMESH_CAPTURE_SCREEN=name,
               SIMCTL_CHILD_TRAILMESH_CAPTURE_MAP_HASH=manifest_hash)
    command("launch", simulator, BUNDLE, env=env, timeout=35)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if marker.is_file():
            result = marker.read_text()
            if result != "ready":
                raise RuntimeError(result)
            file = OUTPUT / f"{number:02}-{name}.png"
            command("io", simulator, "screenshot", file, timeout=15)
            return file.name
        time.sleep(0.2)
    raise RuntimeError("The app did not acknowledge this screen")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    index = {"captureSource": "TrailMesh product SwiftUI app on iOS Simulator",
             "productBase": "828ff2a", "captureCommit": os.environ["GITHUB_SHA"],
             "screens": []}
    devices = json.loads(command("list", "devices", "available", "--json", capture_output=True).stdout)["devices"]
    prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
    candidates = [(tuple(int(p) for p in runtime.removeprefix(prefix).split("-")),
                   phone["name"] == "iPhone 17", phone["udid"], phone["name"])
                  for runtime, phones in devices.items() if runtime.startswith(prefix + "26-")
                  for phone in phones if phone["name"] in ("iPhone 16", "iPhone 17")]
    version, _, simulator, model = max(candidates)
    index.update(model=model, osVersion=".".join(map(str, version)))
    command("boot", simulator, timeout=45)
    command("bootstatus", simulator, "-b", timeout=180)
    command("status_bar", simulator, "override", "--time", "9:41", "--dataNetwork", "wifi",
            "--wifiMode", "active", "--wifiBars", 3, "--cellularMode", "active", "--cellularBars", 4,
            "--batteryState", "unplugged", "--batteryLevel", 100)
    command("ui", simulator, "appearance", "light")
    command("install", simulator, BASE / "TrailMeshCapture/Build/Products/Debug-iphonesimulator/TrailMesh.app")
    data = Path(command("get_app_container", simulator, BUNDLE, "data", capture_output=True).stdout.strip())
    (data / "Documents").mkdir(exist_ok=True)
    pack = BASE / "Rila/pack"
    shutil.copy2(BASE / "Rila/smoke.json", data / "Documents/capture-rila.json")
    manifest = json.loads((pack / "manifest.json").read_text())
    manifest_hash = (BASE / "Rila/manifest.sha256").read_text().split()[0]
    for number, name in enumerate(STARTUP + SCREENS, 1):
        if number == len(STARTUP) + 1:
            subprocess.run(["xcrun", "simctl", "terminate", simulator, BUNDLE], check=False)
            destination = data / "Library/Application Support/OfflineRegions" / manifest["id"] / manifest["revision"]
            shutil.copytree(pack, destination)
        try:
            file = capture(simulator, data, manifest_hash, number, name)
            result = {"state": name, "file": file}
        except (RuntimeError, subprocess.SubprocessError) as error:
            result = {"state": name, "error": str(error)}
        print(json.dumps(result), flush=True)
        index["screens"].append(result)
        (OUTPUT / "index.json").write_text(json.dumps(index, indent=2) + "\n")
    if any("error" in item for item in index["screens"]):
        raise SystemExit("One or more requested screens could not be captured")


if __name__ == "__main__":
    main()
