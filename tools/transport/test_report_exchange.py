"""Literal framing contract for durable signed-report encounters (not probe-v2)."""

import json
from pathlib import Path
import unittest
import tempfile

from tools.transport.report_exchange import (
    Frame, FrameDecoder, WireError, decode_frame, encode_frame, verify_native_frames,
)


ROOT = Path(__file__).resolve().parents[2]
SOURCE = bytes.fromhex("11" * 16)
DESTINATION = bytes.fromhex("22" * 16)


class ExchangeWireTests(unittest.TestCase):
    def test_literal_valid_and_invalid_vectors(self):
        vectors = json.loads((ROOT / "protocol/exchange-v1-vectors.json").read_text())
        for case in vectors["cases"]:
            with self.subTest(case=case["name"]):
                raw = bytes.fromhex(case["wire_hex"])
                if case["expected"] == "valid":
                    frame = decode_frame(raw)
                    self.assertEqual(frame.kind, case["frame"]["kind"])
                    self.assertEqual(frame.source.hex(), case["frame"]["source"])
                    self.assertEqual(frame.destination.hex(), case["frame"]["destination"])
                    self.assertEqual(frame.fields, case["frame"]["fields"])
                    self.assertEqual(encode_frame(frame), raw)
                else:
                    with self.assertRaises(WireError) as error:
                        decode_frame(raw)
                    self.assertEqual(error.exception.code, case["expected"])

    def test_vectors_include_accepted_collection_and_chunk_boundaries(self):
        vectors = json.loads((ROOT / "protocol/exchange-v1-vectors.json").read_text())
        names = {case["name"] for case in vectors["cases"] if case["expected"] == "valid"}
        self.assertTrue({"summary-eight", "request-eight", "offer-transfer-32",
                         "chunk-1024", "chunk-exact-end", "received-transfer-32"} <= names)

    def test_split_headers_payloads_and_coalesced_frames(self):
        wire = encode_frame(Frame("HELLO", SOURCE, bytes(16), {
            "features": 1, "max_frame": 512, "max_chunk": 64,
        }))
        decoder = FrameDecoder()
        frames = []
        for octet in wire:
            frames.extend(decoder.feed(bytes([octet])))
        self.assertEqual([decode_frame(wire)], frames)
        self.assertEqual([decode_frame(wire)] * 2, decoder.feed(wire + wire))
        decoder.finish()

    def test_oversize_prefix_rejected_before_payload_is_buffered(self):
        decoder = FrameDecoder(max_frame=512)
        with self.assertRaises(WireError):
            decoder.feed((513).to_bytes(4, "big") + b"x" * 100_000)
        self.assertEqual(0, decoder.buffered_bytes)

    def test_truncated_stream_and_zero_prefix_fail_closed(self):
        for data in (b"\0", b"\0\0\0", (39).to_bytes(4, "big") + b"TM"):
            decoder = FrameDecoder()
            decoder.feed(data)
            with self.assertRaises(WireError):
                decoder.finish()
        with self.assertRaises(WireError):
            FrameDecoder().feed(bytes(4))

    def test_unknown_fields_bool_numbers_and_bad_identifiers_reject(self):
        for fields in ({"reason": True}, {"reason": 0, "extra": 1}, {"reason": 8}):
            with self.assertRaises(WireError):
                encode_frame(Frame("CLOSE", SOURCE, DESTINATION, fields))
        with self.assertRaises(WireError):
            encode_frame(Frame("REQUEST", SOURCE, DESTINATION, {"ids": ["AA" * 32]}))
        with self.assertRaises(WireError):
            encode_frame(Frame("REQUEST", SOURCE, DESTINATION, {"ids": [[]]}))
        with self.assertRaises(WireError):
            encode_frame(Frame([], SOURCE, DESTINATION, {}))

    def test_chunk_and_inventory_hard_bounds(self):
        for data, offset, total in (("ab" * 1025, 0, 8192), ("ab", 2, 2), ("", 0, 1)):
            with self.assertRaises(WireError):
                encode_frame(Frame("CHUNK", SOURCE, DESTINATION, {
                    "transfer": 1, "offset": offset, "total": total, "data": data,
                }))
        entries = [{"id": "01" * 32, "size": 1, "hops": 1}] * 2
        with self.assertRaises(WireError):
            encode_frame(Frame("SUMMARY", SOURCE, DESTINATION, {
                "page": 0, "more": 0, "entries": entries,
            }))

    def test_negotiated_frame_and_chunk_limits_are_enforced(self):
        frame = Frame("CHUNK", SOURCE, DESTINATION, {
            "transfer": 1, "offset": 0, "total": 8192, "data": "aa" * 1024,
        })
        raw = encode_frame(frame)
        with self.assertRaises(WireError):
            decode_frame(raw, max_frame=512)
        with self.assertRaises(WireError):
            decode_frame(raw, max_chunk=64)

    def test_decoder_output_and_callback_work_are_bounded(self):
        wire = encode_frame(Frame("DONE", SOURCE, DESTINATION, {}))
        with self.assertRaises(WireError):
            FrameDecoder().feed(wire * 65)

    def test_native_export_requires_present_nonempty_valid_frames(self):
        wire = encode_frame(Frame("DONE", SOURCE, DESTINATION, {}))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frames.json"
            for value in ([], [{"wire_hex": "00"}], [{"other": wire.hex()}]):
                path.write_text(json.dumps(value), encoding="utf-8")
                with self.assertRaises(WireError):
                    verify_native_frames(path)
            path.write_text(json.dumps([{"wire_hex": wire.hex()}]), encoding="utf-8")
            with self.assertRaises(WireError):
                verify_native_frames(path)
            vectors = json.loads((ROOT / "protocol/exchange-v1-vectors.json").read_text())
            valid = [{"wire_hex": c["wire_hex"]} for c in vectors["cases"] if c["expected"] == "valid"]
            path.write_text(json.dumps(valid), encoding="utf-8")
            self.assertEqual(len(valid), verify_native_frames(path))


if __name__ == "__main__":
    unittest.main()
