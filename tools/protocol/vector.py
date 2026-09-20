"""Small reference implementation for the frozen TrailMesh v1 vector.

This module deliberately contains protocol primitives only. Transport, storage,
routing, and application policy belong in their platform-specific layers.
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
from typing import Any

import rfc8785
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)


CORE_DOMAIN = b"TrailMesh/core/v1\n"
ID_DOMAIN = b"TrailMesh/id/v1\n"
_BASE64URL_RE = re.compile(r"^[A-Za-z0-9_-]*$")


def b64url_encode(value: bytes) -> str:
    """Encode bytes as unpadded Base64URL."""

    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def b64url_decode(value: str) -> bytes:
    """Decode strict, unpadded Base64URL and reject ambiguous input."""

    if not isinstance(value, str) or "=" in value or not _BASE64URL_RE.fullmatch(value):
        raise ValueError("value must be unpadded Base64URL")
    try:
        decoded = base64.b64decode(
            value + "=" * (-len(value) % 4), altchars=b"-_", validate=True
        )
    except (ValueError, base64.binascii.Error) as exc:
        raise ValueError("invalid Base64URL") from exc
    if b64url_encode(decoded) != value:
        raise ValueError("value is not canonical Base64URL")
    return decoded


def canonical_core_bytes(core: Any) -> bytes:
    """Return RFC 8785 canonical UTF-8 bytes for a protocol core."""

    return rfc8785.dumps(core)


def parse_json_strict(value: str | bytes) -> Any:
    """Parse JSON while rejecting duplicate keys and non-standard constants."""

    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = item
        return result

    def reject_constant(value: str) -> None:
        raise ValueError(f"non-standard JSON constant: {value}")

    return json.loads(
        value,
        object_pairs_hook=reject_duplicates,
        parse_constant=reject_constant,
    )


def bundle_id(core_bytes: bytes) -> str:
    """Compute the lowercase SHA-256 bundle ID from canonical core bytes."""

    return hashlib.sha256(ID_DOMAIN + core_bytes).hexdigest()


def sign_core(private_key: Ed25519PrivateKey, core_bytes: bytes) -> str:
    """Sign the domain-separated canonical core and return Base64URL."""

    return b64url_encode(private_key.sign(CORE_DOMAIN + core_bytes))


def verify_core(public_key: bytes, core_bytes: bytes, signature: str) -> None:
    """Verify a domain-separated signature, raising on invalid input."""

    Ed25519PublicKey.from_public_bytes(public_key).verify(
        b64url_decode(signature), CORE_DOMAIN + core_bytes
    )
