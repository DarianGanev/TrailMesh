"""Verify bounded handling of a guest svc process killed during emulator startup."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class AndroidOfflinePreparationTests(unittest.TestCase):
    def run_helper(self, failures, code, marker=True):
        bash = shutil.which("bash")
        if os.name == "nt":
            bash = r"C:\Program Files\Git\bin\bash.exe"
        self.assertTrue(bash)
        with tempfile.TemporaryDirectory(prefix="trailmesh-adb-") as directory:
            root = Path(directory)
            fake = root / "adb.sh"
            fake.write_text("""#!/usr/bin/env bash
set -eu
if [[ "$1" == shell && "$2" == svc* ]]; then
  count=$(cat "$STATE" 2>/dev/null || echo 0)
  count=$((count + 1)); echo "$count" > "$STATE"
  if (( count <= FAILURES )); then
    [[ "$MARKER" == yes ]] && echo "trailmesh_guest_svc_status=$CODE"
    exit "$CODE"
  fi
  echo trailmesh_guest_svc_status=0; exit 0
fi
if [[ "$1" == get-state ]]; then echo device; fi
exit 0
""", encoding="utf-8")
            fake.chmod(0o755)
            environment = dict(os.environ, ADB_BIN=fake.as_posix(),
                               STATE=(root / "calls").as_posix(),
                               FAILURES=str(failures), CODE=str(code),
                               MARKER="yes" if marker else "no",
                               TRAILMESH_ANDROID_RETRY_DELAY_SECONDS="0",
                               RUNNER_TEMP=root.as_posix())
            script = Path(__file__).with_name("prepare_android_offline.sh")
            result = subprocess.run([bash, str(script)], env=environment,
                                    capture_output=True, text=True, timeout=15)
            count = int((root / "calls").read_text())
            return result, count

    def test_confirmed_guest_kill_retries_then_disables_both_radios(self):
        result, count = self.run_helper(1, 137)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(count, 3)

    def test_other_errors_and_unconfirmed_kills_are_not_retried(self):
        for code, marker in [(1, True), (137, False)]:
            result, count = self.run_helper(5, code, marker)
            self.assertEqual(result.returncode, code, result.stdout + result.stderr)
            self.assertEqual(count, 1)

    def test_guest_kill_retries_are_bounded(self):
        result, count = self.run_helper(5, 137)
        self.assertEqual(result.returncode, 137, result.stdout + result.stderr)
        self.assertEqual(count, 3)


if __name__ == "__main__":
    unittest.main()
