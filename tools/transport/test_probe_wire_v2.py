"""Shared literal wire vectors and hostile-input checks for native probe parity."""

import json
from pathlib import Path
import struct
import unittest

from tools.transport.foreground_exchange import ExchangeError
from tools.transport.probe_wire_v2 import decode_message


VECTORS = json.loads(
    (Path(__file__).resolve().parents[2] / "protocol" / "probe-v2-vectors.json").read_text()
)
SID = "000102030405060708090a0b0c0d0e0f"
PID = "101112131415161718191a1b1c1d1e1f"
DIGEST = "0488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d5070"


class ProbeWireV2Tests(unittest.TestCase):
    def test_literal_hello_binds_two_distinct_sessions_and_fixed_batch(self):
        self.assertEqual(decode_message(bytes.fromhex(VECTORS["hello"])), {
            "kind": "hello", "sessionID": SID, "peerSessionID": PID,
            "payloadSize": 2048, "attemptCount": 20,
        })

    def test_literal_data_correlates_payload_and_index_with_sender_session(self):
        self.assertEqual(decode_message(bytes.fromhex(VECTORS["data"])), {
            "kind": "data", "sessionID": SID, "attemptIndex": 3,
            "payload": bytes([3, 4, 5, 6]), "digest": DIGEST,
        })

    def test_literal_ack_keeps_session_index_acceptance_and_digest(self):
        self.assertEqual(decode_message(bytes.fromhex(VECTORS["ack"])), {
            "kind": "ack", "sessionID": SID, "attemptIndex": 3,
            "accepted": True, "digest": DIGEST,
        })

    def test_finish_and_reciprocal_ack_keep_exact_totals_and_session_direction(self):
        self.assertEqual(decode_message(bytes.fromhex(VECTORS["finish"])), {
            "kind": "finish", "sessionID": SID, "peerSessionID": PID,
            "acknowledgement": False, "successfulAttempts": 19, "failedAttempts": 1,
        })
        self.assertEqual(decode_message(bytes.fromhex(VECTORS["finish_ack"])), {
            "kind": "finish", "sessionID": PID, "peerSessionID": SID,
            "acknowledgement": True, "successfulAttempts": 19, "failedAttempts": 1,
        })

    def test_each_frame_rejects_truncation_and_trailing_bytes(self):
        for name in ("hello", "data", "ack", "finish", "finish_ack"):
            wire = bytes.fromhex(VECTORS[name])
            for invalid in (wire[:-1], wire + b"\x00"):
                with self.subTest(name=name, length=len(invalid)):
                    with self.assertRaises(ExchangeError):
                        decode_message(invalid)

    def test_impossible_attempt_size_status_and_finish_totals_are_rejected(self):
        ack = bytearray.fromhex(VECTORS["ack"])
        data = bytearray.fromhex(VECTORS["data"])
        hello = bytearray.fromhex(VECTORS["hello"])
        finish = bytearray.fromhex(VECTORS["finish"])
        invalid = []
        for index in (20, 0x80000000, 0xFFFFFFFF):
            frame = bytearray(ack)
            frame[20:24] = struct.pack("!I", index)
            invalid.append(frame)
        ack[24] = 2
        invalid.append(ack)
        data[24:28] = struct.pack("!I", 0)
        invalid.append(data)
        hello[36:40] = struct.pack("!I", 1234)
        invalid.append(hello)
        finish[41:45] = struct.pack("!I", 2)
        invalid.append(finish)
        for frame in invalid:
            with self.subTest(wire=frame[:4]):
                with self.assertRaises(ExchangeError):
                    decode_message(bytes(frame))

    def test_checksum_corruption_and_unknown_version_are_rejected(self):
        damaged = bytearray.fromhex(VECTORS["data"])
        damaged[-1] ^= 1
        for frame in (bytes(damaged), b"TMD1" + bytes(damaged[4:]), b"x" * 20000):
            with self.assertRaises(ExchangeError):
                decode_message(frame)


if __name__ == "__main__":
    unittest.main()
