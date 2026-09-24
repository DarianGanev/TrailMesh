"""Bounded foreground exchange contract and evidence recorder.

The transport callback represents a platform adapter.  It receives one framed
application object and returns the peer's received frame.  Native iOS and
Android adapters can use the same framing and evidence shape while keeping
radio discovery and lifecycle details platform-specific.
"""

from __future__ import annotations

import hashlib
import struct
import uuid
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from typing import Callable


MAX_PAYLOAD_BYTES = 16 * 1024
SHA256_BYTES = hashlib.sha256().digest_size
FRAME_HEADER = struct.Struct("!I")


class ExchangeError(ValueError):
    """Raised when an exchange frame or evidence record is invalid."""


class AdapterError(RuntimeError):
    """Raised by a platform adapter with a safe code and lifecycle stage."""

    def __init__(self, message: str, *, code: str = "adapter_error", stage: str = "transport"):
        super().__init__(message)
        self.code = code
        self.stage = stage


@dataclass(frozen=True)
class LifecycleEvent:
    """One observable stage transition in an exchange attempt."""

    state: str
    at: str


@dataclass
class ExchangeEvidence:
    """Redacted evidence for one bounded foreground exchange attempt."""

    attempt_id: str
    transport: str
    direction: str
    internet_disabled: bool
    payload_size: int
    expected_sha256: str
    strategy: str | None = None
    permission_state: str | None = None
    radio_state: str | None = None
    consent_result: str | None = None
    authentication_result: str | None = None
    received_sha256: str | None = None
    success: bool = False
    error: str | None = None
    failure_reason: dict[str, str] | None = None
    events: list[LifecycleEvent] = field(default_factory=list)

    def record(self, state: str) -> None:
        """Append a UTC lifecycle event without recording payload contents."""

        self.events.append(
            LifecycleEvent(
                state=state,
                at=datetime.now(UTC).isoformat(timespec="milliseconds"),
            )
        )

    def to_dict(self) -> dict[str, object]:
        """Return a JSON-serializable redacted evidence object."""

        return asdict(self)


def sha256_hex(payload: bytes) -> str:
    """Return the lowercase SHA-256 digest used by the exchange evidence."""

    return hashlib.sha256(payload).hexdigest()


def make_test_payload(size: int, *, attempt_index: int) -> bytes:
    """Create deterministic synthetic bytes shared by the native probe apps."""

    if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_PAYLOAD_BYTES:
        raise ExchangeError("test payload size must be between 1 byte and 16 KiB")
    if not isinstance(attempt_index, int) or isinstance(attempt_index, bool) or attempt_index < 0:
        raise ExchangeError("attempt index must be a non-negative integer")
    return bytes((index + attempt_index) % 251 for index in range(size))


def _safe_failure_message(exc: BaseException) -> str:
    """Map internal exceptions to stable messages safe for exported evidence."""

    if isinstance(exc, AdapterError):
        return "adapter operation failed"
    if isinstance(exc, TimeoutError):
        return "transport timed out"
    if isinstance(exc, OSError):
        return "transport I/O failed"
    if isinstance(exc, ExchangeError):
        return "exchange validation failed"
    return "exchange input failed"


def encode_frame(payload: bytes) -> bytes:
    """Encode one bounded payload as length, digest, and bytes."""

    if not isinstance(payload, bytes):
        raise ExchangeError("payload must be bytes")
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ExchangeError("payload exceeds the 16 KiB foreground limit")
    return FRAME_HEADER.pack(len(payload)) + hashlib.sha256(payload).digest() + payload


def decode_frame(frame: bytes) -> bytes:
    """Decode and checksum one complete frame, rejecting truncation or corruption."""

    if not isinstance(frame, bytes) or len(frame) < FRAME_HEADER.size + SHA256_BYTES:
        raise ExchangeError("frame is truncated")
    (payload_size,) = FRAME_HEADER.unpack_from(frame)
    if payload_size > MAX_PAYLOAD_BYTES:
        raise ExchangeError("payload exceeds the 16 KiB foreground limit")
    expected_size = FRAME_HEADER.size + SHA256_BYTES + payload_size
    if len(frame) != expected_size:
        raise ExchangeError("frame length does not match its payload length")
    digest_start = FRAME_HEADER.size
    digest_end = digest_start + SHA256_BYTES
    digest = frame[digest_start:digest_end]
    payload = frame[digest_end:]
    if hashlib.sha256(payload).digest() != digest:
        raise ExchangeError("payload checksum mismatch")
    return payload


def run_exchange(
    payload: bytes,
    send: Callable[[bytes, Callable[[str], None]], bytes],
    *,
    direction: str,
    transport: str = "test-loopback",
    internet_disabled: bool,
    attempt_id: str | None = None,
    strategy: str | None = None,
    permission_state: str | None = None,
    radio_state: str | None = None,
    consent_result: str | None = None,
    authentication_result: str | None = None,
) -> ExchangeEvidence:
    """Run one foreground exchange through an adapter and record its outcome.

    ``send`` is deliberately the only adapter dependency.  A production
    adapter must perform discovery, consent/authentication, and byte transfer
    while the coordinator owns framing, validation, and durable acceptance.
    """

    if not direction:
        raise ExchangeError("direction is required")
    evidence = ExchangeEvidence(
        attempt_id=attempt_id or str(uuid.uuid4()),
        transport=transport,
        direction=direction,
        internet_disabled=internet_disabled,
        payload_size=len(payload),
        expected_sha256=sha256_hex(payload),
        strategy=strategy,
        permission_state=permission_state,
        radio_state=radio_state,
        consent_result=consent_result,
        authentication_result=authentication_result,
    )
    try:
        frame = encode_frame(payload)
        received_frame = send(frame, evidence.record)
        evidence.record("validating")
        received = decode_frame(received_frame)
        evidence.received_sha256 = sha256_hex(received)
        if received != payload:
            raise ExchangeError("received payload differs from the sent payload")
        evidence.record("accepted")
        evidence.success = True
    except (AdapterError, ExchangeError, OSError, TimeoutError, TypeError, ValueError) as exc:
        evidence.error = _safe_failure_message(exc)
        evidence.failure_reason = {
            "code": getattr(exc, "code", type(exc).__name__.lower()),
            "stage": getattr(
                exc,
                "stage",
                evidence.events[-1].state if evidence.events else "setup",
            ),
            "message": evidence.error,
        }
        evidence.record("failed")
    return evidence


def loopback_send(frame: bytes, record: Callable[[str], None]) -> bytes:
    """Return a frame unchanged while emulating adapter lifecycle callbacks."""

    for state in ("discovering", "connecting", "verifying_link", "transferring"):
        record(state)
    return frame
