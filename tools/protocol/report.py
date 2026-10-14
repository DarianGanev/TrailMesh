"""Bounded admission contract for immutable signed public reports."""

from dataclasses import dataclass
from enum import Enum
import json
from pathlib import Path
import re

from cryptography.exceptions import InvalidSignature

from tools.protocol.vector import (
    b64url_decode, bundle_id, canonical_core_bytes, parse_json_strict, verify_core,
)


_PROFILE = json.loads((Path(__file__).resolve().parents[2] /
                       "protocol/report-v1-profile.json").read_text(encoding="utf-8"))
_LIMITS = _PROFILE["limits"]
_ID = re.compile(r"[0-9a-f]{64}\Z")


def _integer(value: object) -> bool:
    return type(value) is int and abs(value) <= _LIMITS["safe_integer"]


def _valid_tree(value: object) -> bool:
    """Reject lossy numeric coercions and invalid Unicode before canonicalization."""
    if isinstance(value, str):
        value.encode("utf-8", errors="strict")
        return True
    if value is None or _integer(value):
        return True
    if isinstance(value, dict):
        return all(_valid_tree(k) and _valid_tree(v) for k, v in value.items())
    if isinstance(value, list):
        return all(_valid_tree(v) for v in value)
    return False


def _depth_ok(text: str) -> bool:
    depth = 0
    quoted = escaped = False
    for char in text:
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "[{":
            depth += 1
            if depth > _LIMITS["json_depth"]:
                return False
        elif char in "]}":
            depth -= 1
    return True  # The JSON parser checks syntax, matching delimiters, and trailing data.


def _fields(value: object, name: str) -> bool:
    return isinstance(value, dict) and set(value) == set(_PROFILE[name])


def _binary(value: object, size: int) -> bytes:
    decoded = b64url_decode(value)
    if len(decoded) != size:
        raise ValueError("binary length")
    return decoded


def _identifier(value: object) -> bool:
    return isinstance(value, str) and _ID.fullmatch(value) is not None


class RejectionCode(str, Enum):
    INVALID = "invalid"
    EXPIRED = "expired"
    UNSUPPORTED = "unsupported"


@dataclass(frozen=True, slots=True)
class ReportRejection:
    code: RejectionCode
    reason: str


@dataclass(frozen=True, slots=True)
class ReportProjection:
    event_id: bytes
    category: str
    status: str
    observed_at_ms: int
    lat_e7: int
    lon_e7: int
    accuracy_m: int
    note: str
    supersedes: str | None


@dataclass(frozen=True, slots=True)
class ValidatedReport:
    bundle_id: str
    canonical_core: bytes
    canonical_envelope: bytes
    author_key: bytes
    signature: bytes
    created_at_ms: int
    expires_at_ms: int
    max_hops: int
    report: ReportProjection


def validate_report(raw: bytes, *, now_ms: int) -> ValidatedReport | ReportRejection:
    """Verify and admit one report; caller supplies its local clock estimate."""
    if not _integer(now_ms) or now_ms < 0:
        raise ValueError("now_ms must be a nonnegative safe integer")

    def invalid(reason: str) -> ReportRejection:
        return ReportRejection(RejectionCode.INVALID, reason)

    if not isinstance(raw, bytes):
        return invalid("encoding")
    if len(raw) > _LIMITS["envelope_bytes"]:
        return invalid("size")
    try:
        text = raw.decode("utf-8", errors="strict")
        if text.startswith("\ufeff"):
            return invalid("encoding")
        if not _depth_ok(text):
            return invalid("depth")
        value = parse_json_strict(text)
        if not _valid_tree(value):
            return invalid("types")
    except (ValueError, RecursionError):
        return invalid("encoding")
    if not _fields(value, "envelope_fields"):
        return invalid("fields")
    core = value["core"]
    if not _fields(core, "core_fields"):
        return invalid("fields")
    if core["protocol"] != "trailmesh" or not _integer(core["version"]) or not isinstance(core["kind"], str):
        return invalid("protocol")
    if core["version"] != 1 or core["kind"] != "report":
        return ReportRejection(RejectionCode.UNSUPPORTED, "protocol")
    body = core["body"]
    if not _fields(body, "body_fields"):
        return invalid("fields")
    try:
        author = _binary(core["author_key"], 32)
        _binary(core["nonce"], 16)
        event = _binary(body["event_id"], 16)
        signature = _binary(value["signature"], 64)
    except ValueError:
        return invalid("binary")
    if not _identifier(value["bundle_id"]) or (body["supersedes"] is not None and not _identifier(body["supersedes"])):
        return invalid("identifier")
    category, status, note = body["category"], body["status"], body["note"]
    if (not isinstance(category, str) or not isinstance(status, str) or
            status not in _PROFILE["category_statuses"].get(category, ())):
        return invalid("category_status")
    if (not isinstance(note, str) or len(note) > _LIMITS["note_scalars"] or
            len(note.encode("utf-8")) > _LIMITS["note_utf8_bytes"]):
        return invalid("note")
    created, expires, hops = core["created_at_ms"], core["expires_at_ms"], core["max_hops"]
    observed, lat, lon, accuracy = (body[k] for k in ("observed_at_ms", "lat_e7", "lon_e7", "accuracy_m"))
    if not all(_integer(n) for n in (created, expires, hops, observed, lat, lon, accuracy)):
        return invalid("types")
    if not (0 <= observed <= created < expires and expires - created <= _LIMITS["lifetime_ms"]):
        return invalid("times")
    if not (abs(lat) <= _LIMITS["latitude_e7"] and abs(lon) <= _LIMITS["longitude_e7"] and
            accuracy >= 0 and 0 <= hops <= _LIMITS["max_hops"]):
        return invalid("bounds")
    canonical = canonical_core_bytes(core)
    if bundle_id(canonical) != value["bundle_id"]:
        return invalid("identifier")
    try:
        verify_core(author, canonical, value["signature"])
    except InvalidSignature:
        return invalid("signature")
    if created > now_ms + _LIMITS["future_tolerance_ms"]:
        return invalid("future")
    if now_ms >= expires:
        return ReportRejection(RejectionCode.EXPIRED, "expiry")
    return ValidatedReport(
        bundle_id=value["bundle_id"], canonical_core=canonical,
        canonical_envelope=canonical_core_bytes(value), author_key=author,
        signature=signature, created_at_ms=created, expires_at_ms=expires, max_hops=hops,
        report=ReportProjection(event, category, status, observed, lat, lon, accuracy, note, body["supersedes"]),
    )
