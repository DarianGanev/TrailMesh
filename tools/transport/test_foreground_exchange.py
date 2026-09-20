import unittest

from tools.transport.foreground_exchange import (
    MAX_PAYLOAD_BYTES,
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

        def corrupt(frame: bytes) -> bytes:
            damaged = bytearray(frame)
            damaged[-1] ^= 0x01
            return bytes(damaged)

        evidence = run_exchange(
            payload,
            corrupt,
            direction="android-to-iphone",
            attempt_id="attempt-002",
        )

        self.assertFalse(evidence.success)
        self.assertEqual(evidence.error, "payload checksum mismatch")
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
