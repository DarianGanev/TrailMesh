import unittest

from tools.transport.foreground_exchange import (
    MAX_PAYLOAD_BYTES,
    AdapterError,
    ExchangeError,
    decode_frame,
    encode_frame,
    loopback_send,
    make_test_payload,
    run_exchange,
    sha256_hex,
)


class ForegroundExchangeTests(unittest.TestCase):
    def test_probe_payload_matches_the_cross_platform_golden_vector(self):
        payload = make_test_payload(2048, attempt_index=0)

        self.assertEqual(len(payload), 2048)
        self.assertEqual(
            sha256_hex(payload),
            "b2a8170614e23194ae2951423d601987f518ce2f11205d7b0b708080103b9f76",
        )
        frame = encode_frame(payload)
        self.assertEqual(
            frame[:36].hex(),
            "00000800b2a8170614e23194ae2951423d601987f518ce2f11205d7b0b708080103b9f76",
        )
        self.assertEqual(decode_frame(frame), payload)

    def test_probe_payload_changes_for_each_attempt(self):
        first = make_test_payload(2048, attempt_index=0)
        second = make_test_payload(2048, attempt_index=1)

        self.assertNotEqual(first, second)
        self.assertNotEqual(sha256_hex(first), sha256_hex(second))

    def test_probe_payload_rejects_invalid_sizes_and_attempts(self):
        with self.assertRaises(ExchangeError):
            make_test_payload(0, attempt_index=0)
        with self.assertRaises(ExchangeError):
            make_test_payload(MAX_PAYLOAD_BYTES + 1, attempt_index=0)
        with self.assertRaises(ExchangeError):
            make_test_payload(2048, attempt_index=-1)

    def test_two_kib_loopback_records_a_successful_lifecycle(self):
        payload = bytes(range(256)) * 8
        evidence = run_exchange(
            payload,
            loopback_send,
            direction="iphone-to-android",
            internet_disabled=True,
            attempt_id="attempt-001",
        )

        self.assertTrue(evidence.success)
        self.assertTrue(evidence.internet_disabled)
        self.assertEqual(evidence.payload_size, 2048)
        self.assertEqual(evidence.expected_sha256, sha256_hex(payload))
        self.assertEqual(evidence.received_sha256, evidence.expected_sha256)
        self.assertEqual(
            [event.state for event in evidence.events],
            [
                "discovering",
                "connecting",
                "verifying_link",
                "transferring",
                "validating",
                "accepted",
            ],
        )

    def test_corruption_is_recorded_as_failure(self):
        payload = b"trailmesh"

        def corrupt(frame: bytes, record) -> bytes:
            loopback_send(frame, record)
            damaged = bytearray(frame)
            damaged[-1] ^= 0x01
            return bytes(damaged)

        evidence = run_exchange(
            payload,
            corrupt,
            direction="android-to-iphone",
            internet_disabled=True,
            attempt_id="attempt-002",
        )

        self.assertFalse(evidence.success)
        self.assertEqual(evidence.error, "exchange validation failed")
        self.assertEqual(evidence.failure_reason["stage"], "validating")
        self.assertEqual(evidence.events[-1].state, "failed")

    def test_adapter_failure_is_structured_without_false_success(self):
        def fail(_frame: bytes, record) -> bytes:
            record("discovering")
            raise AdapterError("permission denied", code="permission_denied", stage="discovering")

        evidence = run_exchange(
            b"payload",
            fail,
            direction="iphone-to-android",
            internet_disabled=False,
        )

        self.assertFalse(evidence.success)
        self.assertEqual(evidence.failure_reason["code"], "permission_denied")
        self.assertEqual(evidence.failure_reason["stage"], "discovering")
        self.assertEqual(evidence.error, "adapter operation failed")
        self.assertEqual(evidence.failure_reason["message"], "adapter operation failed")
        self.assertEqual(evidence.events[-1].state, "failed")

    def test_frame_rejects_oversized_payloads(self):
        with self.assertRaises(ExchangeError):
            encode_frame(b"x" * (MAX_PAYLOAD_BYTES + 1))

    def test_frame_rejects_trailing_bytes(self):
        frame = encode_frame(b"payload")
        with self.assertRaisesRegex(ExchangeError, "frame length"):
            decode_frame(frame + b"trailing")


if __name__ == "__main__":
    unittest.main()
