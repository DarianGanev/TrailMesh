import copy
import unittest

from tools.transport.foreground_exchange import ExchangeError, make_test_payload, sha256_hex
from tools.transport.validate_probe_logs import validate_pair


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
        next(r for r in damaged["attempts"] if r["event"] == "attempt_result" and r["attempt_index"] == 2)["success"] = False
        with self.assertRaises(ExchangeError):
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


if __name__ == "__main__":
    unittest.main()
