import base64
import hashlib
import json
import unittest
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.protocol.vector import (
    CORE_DOMAIN,
    ID_DOMAIN,
    b64url_decode,
    b64url_encode,
    bundle_id,
    canonical_core_bytes,
    parse_json_strict,
    sign_core,
    verify_core,
)


FIXTURE_PATH = Path(__file__).parents[2] / "protocol" / "fixture-v1.json"
EXPECTED_CANONICAL_CORE = (
    '{"author_key":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",'
    '"body":{"accuracy_m":30,"category":"water",'
    '"event_id":"ABEiM0RVZneImaq7zN3u_w","lat_e7":421790000,'
    '"lon_e7":235850000,"note":"No flow observed at the spring.",'
    '"observed_at_ms":1789646100000,"status":"dry","supersedes":null},'
    '"created_at_ms":1789646400000,"expires_at_ms":1789732800000,'
    '"kind":"report","max_hops":12,"nonce":"_-7dzLuqmYh3ZlVEMyIRAA",'
    '"protocol":"trailmesh","version":1}'
)
EXPECTED_BUNDLE_ID = "78dc6fce5951274be68ba560addc2576153b200040368f906c0694983af12e74"
EXPECTED_SIGNATURE = (
    "-KjTOzqOa-SsXPxSQ1aSxcz3HCcqeir5wAgWtSU9UVRY1H22EQWBDZa-5JlgVZBkrkkSLhw_pA5A0Ny-z5okCw"
)
TEST_SEED = bytes.fromhex(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
)


class ProtocolVectorTests(unittest.TestCase):
    def test_frozen_fixture_matches_rfc8785_hash_and_signature_vectors(self):
        fixture = parse_json_strict(FIXTURE_PATH.read_text(encoding="utf-8"))
        core_bytes = canonical_core_bytes(fixture["core"])

        self.assertEqual(fixture["fixtureVersion"], 1)
        self.assertEqual(fixture["status"], "frozen")
        self.assertEqual(fixture["canonicalCore"], EXPECTED_CANONICAL_CORE)
        self.assertEqual(core_bytes.decode("utf-8"), EXPECTED_CANONICAL_CORE)
        self.assertEqual(
            fixture["canonicalCoreSha256"], hashlib.sha256(core_bytes).hexdigest()
        )
        self.assertEqual(fixture["bundleId"], EXPECTED_BUNDLE_ID)
        self.assertEqual(fixture["signature"], EXPECTED_SIGNATURE)
        self.assertEqual(fixture["coreDomain"], CORE_DOMAIN.decode("ascii"))
        self.assertEqual(fixture["idDomain"], ID_DOMAIN.decode("ascii"))
        self.assertEqual(bundle_id(core_bytes), EXPECTED_BUNDLE_ID)

        verify_core(
            b64url_decode(fixture["publicKey"]),
            core_bytes,
            fixture["signature"],
        )

    def test_known_test_key_produces_the_frozen_signature(self):
        private_key = Ed25519PrivateKey.from_private_bytes(TEST_SEED)
        core = json.loads(
            json.dumps(
                {
                    "author_key": "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
                    "body": {
                        "accuracy_m": 30,
                        "category": "water",
                        "event_id": "ABEiM0RVZneImaq7zN3u_w",
                        "lat_e7": 421790000,
                        "lon_e7": 235850000,
                        "note": "No flow observed at the spring.",
                        "observed_at_ms": 1789646100000,
                        "status": "dry",
                        "supersedes": None,
                    },
                    "created_at_ms": 1789646400000,
                    "expires_at_ms": 1789732800000,
                    "kind": "report",
                    "max_hops": 12,
                    "nonce": "_-7dzLuqmYh3ZlVEMyIRAA",
                    "protocol": "trailmesh",
                    "version": 1,
                }
            )
        )
        self.assertEqual(sign_core(private_key, canonical_core_bytes(core)), EXPECTED_SIGNATURE)

    def test_tampering_invalidates_the_signature(self):
        fixture = parse_json_strict(FIXTURE_PATH.read_text(encoding="utf-8"))
        tampered = dict(fixture["core"])
        tampered["max_hops"] = 11

        with self.assertRaises(InvalidSignature):
            verify_core(
                b64url_decode(fixture["publicKey"]),
                canonical_core_bytes(tampered),
                fixture["signature"],
            )

    def test_base64url_is_unpadded_and_strict(self):
        encoded = b64url_encode(b"TrailMesh\x00vector")
        self.assertNotIn("=", encoded)
        self.assertEqual(b64url_decode(encoded), b"TrailMesh\x00vector")
        with self.assertRaises(ValueError):
            b64url_decode(encoded + "=")
        with self.assertRaises(ValueError):
            b64url_decode("not base64!")
        with self.assertRaises(ValueError):
            b64url_decode("AB")

    def test_json_parser_rejects_duplicate_keys_and_non_standard_constants(self):
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            parse_json_strict('{"a":1,"a":2}')
        with self.assertRaisesRegex(ValueError, "non-standard JSON constant"):
            parse_json_strict('{"a":NaN}')


if __name__ == "__main__":
    unittest.main()
