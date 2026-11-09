"""Versioned, bounded framing for immutable public-report exchange."""

from dataclasses import dataclass
import re
import struct


KINDS = {name: index for index, name in enumerate(
    ("", "HELLO", "SUMMARY", "REQUEST", "OFFER", "CHUNK", "RECEIVED", "CLOSE", "DONE")) if name}
NAMES = {value: key for key, value in KINDS.items()}
MAX_FRAME = 16384
MAX_CALLBACK = 262144


class WireError(ValueError):
    def __init__(self, code="invalid"):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class Frame:
    kind: str
    source: bytes
    destination: bytes
    fields: dict


def encode_frame(frame, *, max_frame=16384):
    """Encode exactly one frame; dictionary fields mirror the shared literal vectors."""
    _limit(max_frame, 512, MAX_FRAME)
    if not isinstance(frame, Frame) or not isinstance(frame.kind, str) or frame.kind not in KINDS:
        raise WireError()
    if (not isinstance(frame.source, bytes) or len(frame.source) != 16 or
            frame.source == bytes(16) or not isinstance(frame.destination, bytes) or
            len(frame.destination) != 16):
        raise WireError()
    if (frame.destination == bytes(16)) != (frame.kind == "HELLO"):
        raise WireError()
    if frame.kind != "HELLO" and frame.source == frame.destination:
        raise WireError()
    f = frame.fields
    kind = frame.kind
    if kind == "HELLO":
        _keys(f, "features", "max_frame", "max_chunk")
        _limit(f["features"], 0, 0xffffffff)
        if not f["features"] & 1:
            raise WireError("unsupported")
        _limit(f["max_frame"], 512, MAX_FRAME)
        _limit(f["max_chunk"], 64, 1024)
        body = struct.pack(">IHH", f["features"], f["max_frame"], f["max_chunk"])
    elif kind == "SUMMARY":
        _keys(f, "page", "more", "entries")
        _limit(f["page"], 0, 7)
        _limit(f["more"], 0, 1)
        if f["page"] == 7 and f["more"]:
            raise WireError()
        _list(f["entries"], 8)
        body = struct.pack(">HBB", f["page"], f["more"], len(f["entries"]))
        ids = []
        for entry in f["entries"]:
            _keys(entry, "id", "size", "hops")
            identifier = _hex(entry["id"], 32, 32)
            ids.append(entry["id"])
            _limit(entry["size"], 1, 8192)
            _limit(entry["hops"], 1, 12)
            body += identifier + struct.pack(">HB", entry["size"], entry["hops"])
        if ids != sorted(set(ids)):
            raise WireError()
    elif kind == "REQUEST":
        _keys(f, "ids")
        _list(f["ids"], 8)
        identifiers = [_hex(x, 32, 32) for x in f["ids"]]
        if f["ids"] != sorted(set(f["ids"])):
            raise WireError()
        body = bytes([len(f["ids"])]) + b"".join(identifiers)
    elif kind == "OFFER":
        _keys(f, "transfer", "id", "total", "hops")
        _limit(f["transfer"], 1, 32)
        _limit(f["total"], 1, 8192)
        _limit(f["hops"], 1, 12)
        body = (struct.pack(">I", f["transfer"]) + _hex(f["id"], 32, 32) +
                struct.pack(">HB", f["total"], f["hops"]))
    elif kind == "CHUNK":
        _keys(f, "transfer", "offset", "total", "data")
        _limit(f["transfer"], 1, 32)
        _limit(f["total"], 1, 8192)
        _limit(f["offset"], 0, f["total"] - 1)
        chunk = _hex(f["data"], 1, 1024)
        if f["offset"] + len(chunk) > f["total"]:
            raise WireError()
        body = struct.pack(">IHH", f["transfer"], f["offset"], f["total"]) + chunk
    elif kind == "RECEIVED":
        _keys(f, "transfer", "id", "result")
        _limit(f["transfer"], 1, 32)
        _limit(f["result"], 0, 5)
        body = struct.pack(">I", f["transfer"]) + _hex(f["id"], 32, 32) + bytes([f["result"]])
    elif kind == "CLOSE":
        _keys(f, "reason")
        _limit(f["reason"], 0, 7)
        body = bytes([f["reason"]])
    else:
        _keys(f)
        body = b""
    payload = (b"TMXR" + bytes([1, 0, KINDS[kind]]) +
               frame.source + frame.destination + body)
    if len(payload) > max_frame:
        raise WireError()
    return struct.pack(">I", len(payload)) + payload


def decode_frame(raw, *, max_frame=16384, max_chunk=1024):
    """Decode one full frame without accepting trailing bytes or numeric coercions."""
    _limit(max_frame, 512, MAX_FRAME)
    _limit(max_chunk, 64, 1024)
    if len(raw) < 4:
        raise WireError()
    size = int.from_bytes(raw[:4], "big")
    if not 39 <= size <= max_frame or len(raw) != size + 4:
        raise WireError()
    reader = _Reader(memoryview(raw)[4:])
    if reader.take(4) != b"TMXR":
        raise WireError()
    if reader.integer(1) != 1 or reader.integer(1) != 0:
        raise WireError("unsupported")
    kind = NAMES.get(reader.integer(1))
    if kind is None:
        raise WireError()
    source, destination = reader.take(16), reader.take(16)
    if kind == "HELLO":
        fields = dict(features=reader.integer(4), max_frame=reader.integer(2),
                      max_chunk=reader.integer(2))
    elif kind == "SUMMARY":
        page, more, count = reader.integer(2), reader.integer(1), reader.integer(1)
        _limit(count, 0, 8)
        fields = dict(page=page, more=more, entries=[
            dict(id=reader.take(32).hex(), size=reader.integer(2), hops=reader.integer(1))
            for _ in range(count)])
    elif kind == "REQUEST":
        count = reader.integer(1)
        _limit(count, 0, 8)
        fields = dict(ids=[reader.take(32).hex() for _ in range(count)])
    elif kind == "OFFER":
        fields = dict(transfer=reader.integer(4), id=reader.take(32).hex(),
                      total=reader.integer(2), hops=reader.integer(1))
    elif kind == "CHUNK":
        fields = dict(transfer=reader.integer(4), offset=reader.integer(2),
                      total=reader.integer(2), data=reader.take(reader.remaining).hex())
        if len(fields["data"]) // 2 > max_chunk:
            raise WireError()
    elif kind == "RECEIVED":
        fields = dict(transfer=reader.integer(4), id=reader.take(32).hex(),
                      result=reader.integer(1))
    elif kind == "CLOSE":
        fields = dict(reason=reader.integer(1))
    else:
        fields = {}
    if reader.remaining:
        raise WireError()
    frame = Frame(kind, source, destination, fields)
    encode_frame(frame, max_frame=max_frame)  # One set of structural/range rules.
    return frame


class FrameDecoder:
    """Incremental framing with one reserved payload and bounded callback work.

    Discard this decoder after a WireError. A new encounter must negotiate its
    own limits and bind decoded messages to the current nonces and generation.
    """
    def __init__(self, max_frame=16384):
        _limit(max_frame, 512, MAX_FRAME)
        self.max_frame = max_frame
        self._buffer = bytearray()
        self._size = None
        self._failed = False

    @property
    def buffered_bytes(self):
        return len(self._buffer)

    def feed(self, data):
        """Consume a bounded callback; hold at most one validated-size frame."""
        if self._failed:
            raise WireError()
        frames = []
        try:
            if len(data) > MAX_CALLBACK:
                raise WireError()
            source = memoryview(data)
            offset = 0
            while offset < len(source):
                target = 4 if self._size is None else self._size + 4
                amount = min(target - len(self._buffer), len(source) - offset)
                self._buffer.extend(source[offset:offset + amount])
                offset += amount
                if len(self._buffer) < target:
                    continue
                if self._size is None:
                    self._size = int.from_bytes(self._buffer, "big")
                    if not 39 <= self._size <= self.max_frame:
                        raise WireError()
                else:
                    if len(frames) == 64:
                        raise WireError()
                    frames.append(decode_frame(self._buffer, max_frame=self.max_frame))
                    self._buffer.clear()
                    self._size = None
            return frames
        except WireError:
            self._failed = True
            self._buffer.clear()
            self._size = None
            raise

    def finish(self):
        """Reject a disconnected stream that ends inside a prefix or payload."""
        if self._failed or self._buffer:
            self._failed = True
            self._buffer.clear()
            raise WireError()


def _limit(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise WireError()


def _keys(value, *keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise WireError()


def _list(value, maximum):
    if not isinstance(value, list) or len(value) > maximum:
        raise WireError()


def _hex(value, minimum, maximum):
    if (not isinstance(value, str) or not minimum * 2 <= len(value) <= maximum * 2 or
            len(value) % 2 or re.fullmatch(r"[0-9a-f]+", value) is None):
        raise WireError()
    return bytes.fromhex(value)


class _Reader:
    def __init__(self, source):
        self.source = source
        self.position = 0

    @property
    def remaining(self):
        return len(self.source) - self.position

    def take(self, count):
        if count < 0 or count > self.remaining:
            raise WireError()
        result = bytes(self.source[self.position:self.position + count])
        self.position += count
        return result

    def integer(self, count):
        return int.from_bytes(self.take(count), "big")


def verify_native_frames(path):
    """Require full native golden-case coverage with independently decoded values."""
    import json
    from pathlib import Path
    profile = Path(__file__).resolve().parents[2] / "protocol/exchange-v1-vectors.json"
    cases = json.loads(profile.read_text(encoding="utf-8"))["cases"]
    expected = {c["wire_hex"]: c["frame"] for c in cases if c["expected"] == "valid"}
    with open(path, "rb") as source:
        raw = source.read(2_097_153)
    if len(raw) > 2_097_152:
        raise WireError()
    try:
        rows = json.loads(raw)
        if not isinstance(rows, list) or not 1 <= len(rows) <= 1024:
            raise WireError()
        seen = set()
        for row in rows:
            _keys(row, "wire_hex")
            wire = _hex(row["wire_hex"], 43, MAX_FRAME + 4)
            if row["wire_hex"] not in expected or row["wire_hex"] in seen:
                raise WireError()
            seen.add(row["wire_hex"])
            frame = decode_frame(wire)
            value = expected[row["wire_hex"]]
            if (frame.kind != value["kind"] or frame.source.hex() != value["source"] or
                    frame.destination.hex() != value["destination"] or frame.fields != value["fields"] or
                    encode_frame(frame) != wire):
                raise WireError()
        if seen != set(expected):
            raise WireError()
    except (TypeError, UnicodeError, ValueError) as error:
        raise WireError() from error
    return len(rows)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-native", required=True)
    options = parser.parse_args()
    print(f"Verified {verify_native_frames(options.verify_native)} native exchange frames")
