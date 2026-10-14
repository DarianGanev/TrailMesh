"""Decode exported synthetic-probe wire vectors independently of native codecs."""

import struct

from tools.transport.foreground_exchange import ExchangeError, MAX_PAYLOAD_BYTES, decode_frame


ATTEMPTS_PER_BATCH = 20
PAYLOAD_SIZES = {256, 2048, 8192}


def _uint32(message: bytes, offset: int) -> int:
    return struct.unpack_from("!I", message, offset)[0]


def decode_message(message: bytes) -> dict[str, object]:
    """Validate one exact, bounded v2 frame for interoperability tooling."""

    if not isinstance(message, bytes) or not 4 <= len(message) <= MAX_PAYLOAD_BYTES + 60:
        raise ExchangeError("invalid probe envelope size")
    magic = message[:4]
    expected_size = {b"TMH2": 44, b"TMA2": 57, b"TMF2": 45}.get(magic)
    if expected_size is not None and len(message) != expected_size:
        raise ExchangeError("invalid probe control length")
    if magic == b"TMD2" and len(message) < 61:
        raise ExchangeError("probe data is empty or truncated")
    if magic not in {b"TMH2", b"TMD2", b"TMA2", b"TMF2"}:
        raise ExchangeError("unknown probe version or message")
    sender = message[4:20].hex()
    if magic in {b"TMH2", b"TMF2"}:
        peer = message[20:36].hex()
        if sender == peer:
            raise ExchangeError("peer session must be distinct")
        if magic == b"TMH2":
            size, count = _uint32(message, 36), _uint32(message, 40)
            if size not in PAYLOAD_SIZES or count != ATTEMPTS_PER_BATCH:
                raise ExchangeError("unsupported batch configuration")
            return {"kind": "hello", "sessionID": sender, "peerSessionID": peer,
                    "payloadSize": size, "attemptCount": count}
        flag, successes, failures = message[36], _uint32(message, 37), _uint32(message, 41)
        if flag not in {0, 1} or successes + failures != ATTEMPTS_PER_BATCH:
            raise ExchangeError("invalid finish totals or status")
        return {"kind": "finish", "sessionID": sender, "peerSessionID": peer,
                "acknowledgement": bool(flag), "successfulAttempts": successes,
                "failedAttempts": failures}
    attempt = _uint32(message, 20)
    if attempt >= ATTEMPTS_PER_BATCH:
        raise ExchangeError("probe attempt outside negotiated batch")
    if magic == b"TMD2":
        payload = decode_frame(message[24:])
        if not payload:
            raise ExchangeError("probe data must be nonempty")
        return {"kind": "data", "sessionID": sender, "attemptIndex": attempt,
                "payload": payload, "digest": message[28:60].hex()}
    flag = message[24]
    if flag not in {0, 1}:
        raise ExchangeError("invalid acknowledgement status")
    return {"kind": "ack", "sessionID": sender, "attemptIndex": attempt,
            "accepted": bool(flag), "digest": message[25:].hex()}
