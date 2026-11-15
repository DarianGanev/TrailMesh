import copy
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.transport.foreground_exchange import ExchangeError, make_test_payload, sha256_hex
from tools.transport.validate_probe_logs import validate_pair
from tools.transport import validate_probe_logs


class ProbeLogValidationTests(unittest.TestCase):
    def pair(self):
        first = {"schema": "trailmesh.foreground-probe-log", "version": 2,
                 "probe_protocol": 2, "platform": "ios", "session_id": "1" * 32, "attempts": []}
        second = {**first, "platform": "android", "session_id": "2" * 32, "attempts": []}
        for sender, receiver in ((first, second), (second, first)):
            for index in range(20):
                digest = sha256_hex(make_test_payload(2048, attempt_index=index))
                common = {"attempt_index": index, "payload_size_bytes": 2048,
                          "expected_sha256": digest, "received_sha256": digest, "success": True}
                sender["attempts"].append({**common, "event": "attempt_result",
                                           "peer_session_id": receiver["session_id"]})
                receiver["attempts"].append({**common, "event": "payload_received",
                                             "peer_session_id": sender["session_id"]})
        return first, second

    def test_both_directions_require_matching_unique_receiver_evidence(self):
        first, second = self.pair()
        self.assertEqual(validate_pair(first, second), {"ios-to-android": 20, "android-to-ios": 20})

    def test_twenty_copies_of_one_receipt_cannot_prove_twenty_deliveries(self):
        first, second = self.pair()
        receipt = next(r for r in second["attempts"] if r["event"] == "payload_received")
        second["attempts"] = [r for r in second["attempts"] if r["event"] != "payload_received"] + [receipt] * 20
        with self.assertRaises(ExchangeError):
            validate_pair(first, second)

    def test_twenty_copies_of_one_result_cannot_prove_a_complete_batch(self):
        first, second = self.pair()
        result = next(r for r in first["attempts"] if r["event"] == "attempt_result")
        first["attempts"] = [r for r in first["attempts"] if r["event"] != "attempt_result"] + [result] * 20
        with self.assertRaises(ExchangeError):
            validate_pair(first, second)

    def test_old_peer_nonce_or_tampered_digest_is_not_corroboration(self):
        for field, value in (("peer_session_id", "3" * 32), ("received_sha256", "0" * 64)):
            first, second = self.pair()
            for record in second["attempts"]:
                if record["event"] == "payload_received":
                    record[field] = value
            with self.assertRaises(ExchangeError):
                validate_pair(first, second)

    def test_gate_tolerates_two_recorded_failures_but_not_three(self):
        first, second = self.pair()
        for log in (first, second):
            for record in log["attempts"]:
                if record["event"] == "attempt_result" and record["attempt_index"] < 2:
                    record["success"] = False
                    record["failure_reason"] = "acknowledgement_timeout"
        self.assertEqual(validate_pair(first, second), {"ios-to-android": 18, "android-to-ios": 18})
        damaged = copy.deepcopy(first)
        third_failure = next(r for r in damaged["attempts"]
                             if r["event"] == "attempt_result" and r["attempt_index"] == 2)
        third_failure.update(success=False, failure_reason="acknowledgement_timeout")
        with self.assertRaisesRegex(ExchangeError, "below the acceptance gate"):
            validate_pair(damaged, second)

    def test_failed_result_requires_a_nonblank_string_reason(self):
        for reason in (None, 1, "", "   "):
            first, second = self.pair()
            result = next(r for r in first["attempts"] if r["event"] == "attempt_result")
            result["success"] = False
            if reason is not None:
                result["failure_reason"] = reason
            with self.subTest(reason=reason), self.assertRaises(ExchangeError):
                validate_pair(first, second)

    def test_bounded_diagnostic_loss_does_not_replace_delivery_evidence(self):
        first, second = self.pair()
        first["evicted_records"] = 809
        self.assertEqual(validate_pair(first, second)["ios-to-android"], 20)
        for counter in (-1, True, "809"):
            first["evicted_records"] = counter
            with self.subTest(counter=counter), self.assertRaises(ExchangeError):
                validate_pair(first, second)

    def test_replayed_or_conflicting_log_results_are_rejected(self):
        first, second = self.pair()
        result = next(r for r in first["attempts"] if r["event"] == "attempt_result")
        first["attempts"].append(result)
        with self.assertRaises(ExchangeError):
            validate_pair(first, second)

    def test_invalid_schema_or_same_session_is_rejected(self):
        for field, value in (("version", 1), ("session_id", "2" * 32), ("platform", "web")):
            first, second = self.pair()
            first[field] = value
            with self.assertRaises(ExchangeError):
                validate_pair(first, second)

    def test_repeated_receipt_with_new_timestamp_does_not_inflate_counts(self):
        first, second = self.pair()
        receipt = next(r for r in second["attempts"] if r["event"] == "payload_received")
        second["attempts"].append({**receipt, "observed_at": "later"})
        self.assertEqual(validate_pair(first, second)["ios-to-android"], 20)

    def test_android_pair_keeps_both_directions_separate(self):
        first, second = self.pair()
        first["platform"] = "android"
        self.assertEqual(validate_pair(first, second),
                         {"android[1]-to-android[2]": 20, "android[2]-to-android[1]": 20})

    def test_boolean_indices_and_unbounded_records_are_rejected(self):
        first, second = self.pair()
        first["attempts"][0]["attempt_index"] = True
        with self.assertRaises(ExchangeError):
            validate_pair(first, second)
        first, second = self.pair()
        first["attempts"] += [{"event": "diagnostic"}] * 513
        with self.assertRaises(ExchangeError):
            validate_pair(first, second)

    def group(self):
        logs = [
            {"schema": "trailmesh.foreground-probe-log", "version": 2,
             "probe_protocol": 2, "platform": platform, "session_id": digit * 32, "attempts": []}
            for digit, platform in (("1", "ios"), ("2", "android"), ("3", "ios"))
        ]
        # A shared phone exchanges with two neighbors. The neighbors need no direct link.
        for neighbor in logs[1:]:
            for sender, receiver in ((logs[0], neighbor), (neighbor, logs[0])):
                for index in range(20):
                    digest = sha256_hex(make_test_payload(2048, attempt_index=index))
                    common = {"attempt_index": index, "payload_size_bytes": 2048,
                              "expected_sha256": digest, "received_sha256": digest, "success": True}
                    sender["attempts"].append({**common, "event": "attempt_result",
                                               "peer_session_id": receiver["session_id"]})
                    receiver["attempts"].append({**common, "event": "payload_received",
                                                 "peer_session_id": sender["session_id"]})
        return logs

    def test_group_corroborates_each_observed_link_with_separate_peer_evidence(self):
        self.assertEqual(validate_probe_logs.validate_group(self.group()), {
            "ios[1]-to-android[2]": 20, "android[2]-to-ios[1]": 20,
            "ios[1]-to-ios[3]": 20, "ios[3]-to-ios[1]": 20,
        })

    def test_group_cannot_borrow_receipts_from_another_neighbor(self):
        logs = self.group()
        logs[2]["attempts"] = [r for r in logs[2]["attempts"] if r["event"] != "payload_received"]
        with self.assertRaises(ExchangeError):
            validate_probe_logs.validate_group(logs)

    def test_group_requires_unique_sessions_and_every_referenced_export(self):
        for logs in (self.group()[:2], self.group() + [self.group()[0]]):
            with self.assertRaises(ExchangeError):
                validate_probe_logs.validate_group(logs)

    def test_group_rejects_disconnected_or_empty_device_exports(self):
        logs = self.group()
        logs.append({**logs[0], "session_id": "4" * 32, "attempts": []})
        with self.assertRaises(ExchangeError):
            validate_probe_logs.validate_group(logs)

    def test_group_rejects_two_disconnected_pairs_with_complete_results(self):
        first_pair = list(self.pair())
        second_pair = list(self.pair())
        renamed = {"1" * 32: "3" * 32, "2" * 32: "4" * 32}
        for log in second_pair:
            log["session_id"] = renamed[log["session_id"]]
            for record in log["attempts"]:
                record["peer_session_id"] = renamed[record["peer_session_id"]]
        with self.assertRaises(ExchangeError):
            validate_probe_logs.validate_group(first_pair + second_pair)

    def test_group_rejects_unknown_malformed_or_self_peer_references(self):
        for peer in ("f" * 32, [], "1" * 32):
            logs = self.group()
            logs[0]["attempts"][0]["peer_session_id"] = peer
            with self.subTest(peer=peer), self.assertRaises(ExchangeError):
                validate_probe_logs.validate_group(logs)

    def test_group_enforces_bounded_count_and_validation_parameters(self):
        for logs in ([], self.group()[:1], self.group() * 4):
            with self.assertRaises(ExchangeError):
                validate_probe_logs.validate_group(logs)
        for gate in (-1, True, 21):
            with self.assertRaises(ExchangeError):
                validate_probe_logs.validate_group(self.group(), minimum_successes=gate)

    def test_cli_accepts_three_exports_and_preserves_two_export_output(self):
        for logs in (self.group(), list(self.pair())):
            with self.subTest(devices=len(logs)), tempfile.TemporaryDirectory() as directory:
                paths = []
                for index, log in enumerate(logs):
                    path = Path(directory) / f"device-{index}.json"
                    path.write_text(json.dumps(log), encoding="utf-8")
                    paths.append(str(path))
                output = io.StringIO()
                with patch.object(sys, "argv", ["validate_probe_logs", *paths]), contextlib.redirect_stdout(output):
                    self.assertEqual(validate_probe_logs.main(), 0)
                expected = "ios[1]-to-android[2]" if len(logs) == 3 else "ios-to-android"
                self.assertIn(f"{expected}: 20/20 corroborated successful attempts", output.getvalue())

    def test_cli_rejects_file_count_before_reading_exports(self):
        with patch.object(sys, "argv", ["validate_probe_logs", "missing.json"]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(validate_probe_logs.main(), 1)


if __name__ == "__main__":
    unittest.main()
