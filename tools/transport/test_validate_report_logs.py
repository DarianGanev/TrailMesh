"""Corroborate stored synthetic reports without inferring physical conditions."""

import copy
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.transport.foreground_exchange import ExchangeError
from tools.transport import validate_report_logs


class ReportLogTests(unittest.TestCase):
    def exports(self):
        report = {
            "bundle_id": "a" * 64, "canonical_core_sha256": "b" * 64,
            "original_wire_sha256": "c" * 64, "observed_at_ms": 1000,
            "is_expired": False, "is_quarantined": False, "remaining_hops": 3,
        }
        return [
            {
                "schema": "trailmesh.report-session-log", "version": 1,
                "platform": platform, "deviceModel": "synthetic test device",
                "osVersion": "test", "appBuild": "test", "state": "stopped",
                "exportID": str(index) * 32, "sessionID": str(index + 3) * 32,
                "events": [], "saved_test_reports": [{**report, "remaining_hops": 4 - index}],
            }
            for index, platform in ((1, "ios"), (2, "android"), (3, "android"))
        ]

    def test_three_saved_copies_match_original_hashes_and_observation(self):
        result = validate_report_logs.validate_relay(*self.exports(), bundle_id="a" * 64)
        self.assertEqual(result["bundle_id"], "a" * 64)
        self.assertEqual(result["observed_at_ms"], 1000)
        self.assertEqual(result["saved_copies"], 3)

    def test_changed_hash_time_or_missing_copy_is_rejected(self):
        for field, value in (("canonical_core_sha256", "d" * 64),
                             ("original_wire_sha256", "d" * 64), ("observed_at_ms", 1001)):
            logs = self.exports()
            logs[2]["saved_test_reports"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ExchangeError):
                validate_report_logs.validate_relay(*logs, bundle_id="a" * 64)
        logs = self.exports()
        logs[1]["saved_test_reports"] = []
        with self.assertRaises(ExchangeError):
            validate_report_logs.validate_relay(*logs, bundle_id="a" * 64)

    def test_expired_quarantined_or_conflicting_duplicate_evidence_is_rejected(self):
        for field in ("is_expired", "is_quarantined"):
            logs = self.exports()
            logs[2]["saved_test_reports"][0][field] = True
            with self.subTest(field=field), self.assertRaises(ExchangeError):
                validate_report_logs.validate_relay(*logs, bundle_id="a" * 64)
        logs = self.exports()
        logs[1]["saved_test_reports"] *= 2
        with self.assertRaises(ExchangeError):
            validate_report_logs.validate_relay(*logs, bundle_id="a" * 64)

    def test_boolean_numbers_unbounded_records_and_reused_exports_are_rejected(self):
        for field, value in (("observed_at_ms", True), ("remaining_hops", True),
                             ("remaining_hops", 13), ("is_expired", 0)):
            logs = self.exports()
            logs[0]["saved_test_reports"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ExchangeError):
                validate_report_logs.validate_relay(*logs, bundle_id="a" * 64)
        for field, count in (("events", 513), ("saved_test_reports", 65)):
            logs = self.exports()
            item = {} if field == "events" else logs[0][field][0]
            logs[0][field] = [copy.deepcopy(item) for _ in range(count)]
            with self.subTest(field=field), self.assertRaises(ExchangeError):
                validate_report_logs.validate_relay(*logs, bundle_id="a" * 64)
        logs = self.exports()
        logs[1]["exportID"] = logs[0]["exportID"]
        with self.assertRaises(ExchangeError):
            validate_report_logs.validate_relay(*logs, bundle_id="a" * 64)

    def test_native_event_fields_and_optional_source_commit_are_accepted(self):
        logs = self.exports()
        logs[0]["sourceCommit"] = "e" * 40
        logs[0]["events"] = [{"code": "report_authored", "timestamp_ms": 1000,
                              "bundle_id": "a" * 64}]
        self.assertEqual(validate_report_logs.validate_relay(*logs, bundle_id="a" * 64)["saved_copies"], 3)

    def test_unknown_export_fields_cannot_hide_raw_routes_or_report_text(self):
        for field in ("route", "report_text", "private_key"):
            logs = self.exports()
            logs[0][field] = "unexpected diagnostic content"
            with self.subTest(field=field), self.assertRaises(ExchangeError):
                validate_report_logs.validate_relay(*logs, bundle_id="a" * 64)

    def test_cli_reads_native_shape_and_states_physical_evidence_limit(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = []
            for index, log in enumerate(self.exports()):
                path = Path(folder) / f"phone-{index}.json"
                path.write_text(json.dumps(log), encoding="utf-8")
                paths.append(str(path))
            output = io.StringIO()
            with patch.object(sys, "argv", ["validate_report_logs", *paths, "--bundle-id", "a" * 64]), contextlib.redirect_stdout(output):
                self.assertEqual(validate_report_logs.main(), 0)
            self.assertIn("three saved copies", output.getvalue())
            self.assertIn("Record physical range", output.getvalue())
            Path(paths[1]).write_text('{"schema": 1, "schema": 2}', encoding="utf-8")
            with patch.object(sys, "argv", ["validate_report_logs", *paths, "--bundle-id", "a" * 64]), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(validate_report_logs.main(), 1)


if __name__ == "__main__":
    unittest.main()
