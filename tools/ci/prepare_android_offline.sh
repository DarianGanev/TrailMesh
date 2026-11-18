#!/usr/bin/env bash
# A booting emulator can kill the guest app_process used by svc. Retry only a
# confirmed guest SIGKILL; preserve evidence and fail on every other error.
set -euo pipefail
ADB_BIN="${ADB_BIN:-adb}"
DELAY="${TRAILMESH_ANDROID_RETRY_DELAY_SECONDS:-2}"
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  exec > >(tee "$RUNNER_TEMP/android-network-preparation.log") 2>&1
fi

diagnostics() {
  "$ADB_BIN" get-state || true
  "$ADB_BIN" shell cat /proc/meminfo || true
  "$ADB_BIN" logcat -b all -d -t 300 || true
  "$ADB_BIN" shell dumpsys wifi || true
  if [[ -r /sys/fs/cgroup/memory.events ]]; then cat /sys/fs/cgroup/memory.events; fi
}

disable_radio() {
  local radio="$1" output status attempt
  for attempt in 1 2 3; do
    if output=$("$ADB_BIN" shell "svc $radio disable; result=\$?; echo trailmesh_guest_svc_status=\$result; exit \$result" 2>&1); then
      printf '%s\n' "$output"
      return 0
    else
      status=$?
    fi
    printf '%s\n' "$output"
    diagnostics
    if [[ "$status" != 137 || "$output" != *trailmesh_guest_svc_status=137* || "$attempt" == 3 ]]; then
      return "$status"
    fi
    # A host-side SIGKILL or disconnected emulator must not be mistaken for the
    # recoverable child status printed by the remote shell above.
    "$ADB_BIN" shell true || return "$status"
    sleep "$DELAY"
  done
}

"$ADB_BIN" shell cat /proc/meminfo
disable_radio wifi
disable_radio data
# The real-pack instrumentation also verifies that no Internet-capable default
# network remains before executing the local route and HTTP-blocked renderer.
