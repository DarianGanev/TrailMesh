import unittest

from tools.transport.foreground_exchange import (
    MAX_PAYLOAD_BYTES,
    AdapterError,
    ExchangeError,
    decode_frame,
    encode_frame,
    loopback_send,
    run_exchange,
    sha256_hex,
)


class ForegroundExchangeTests(unittest.TestCase):
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
