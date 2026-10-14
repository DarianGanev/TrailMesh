import copy
from dataclasses import FrozenInstanceError
import json
from pathlib import Path
import unittest

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.protocol.report import RejectionCode, ReportRejection, ValidatedReport, validate_report
from tools.protocol.vector import b64url_encode, bundle_id, canonical_core_bytes, sign_core


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = json.loads((ROOT / "protocol/fixture-v1.json").read_text(encoding="utf-8"))
KEY = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
))
NOW = FIXTURE["core"]["created_at_ms"] + 600000


def envelope(core=None):
    core = copy.deepcopy(FIXTURE["core"] if core is None else core)
    canonical = canonical_core_bytes(core)
    return {"core": core, "signature": sign_core(KEY, canonical), "bundle_id": bundle_id(canonical)}


def wire(value=None):
    return json.dumps(envelope() if value is None else value, ensure_ascii=False).encode("utf-8")


class ReportAdmissionTests(unittest.TestCase):
    def assertRejected(self, raw, code=RejectionCode.INVALID, now=NOW, reason=None):
        result = validate_report(raw, now_ms=now)
        self.assertIsInstance(result, ReportRejection)
        self.assertEqual(result.code, code)
        if reason is not None:
            self.assertEqual(result.reason, reason)
        return result

    def assertAccepted(self, raw, now=NOW):
        result = validate_report(raw, now_ms=now)
        self.assertIsInstance(result, ValidatedReport)
        return result

    def changed(self, *, core=None, body=None):
        changed = copy.deepcopy(FIXTURE["core"])
        changed.update(core or {})
        changed["body"].update(body or {})
        return wire(envelope(changed))

    def test_frozen_fixture_passes_without_changing_signed_bytes_or_projection(self):
        original = {"core": FIXTURE["core"], "signature": FIXTURE["signature"],
                    "bundle_id": FIXTURE["bundleId"]}
        result = self.assertAccepted(wire(original))
        self.assertEqual(result.bundle_id, FIXTURE["bundleId"])
        self.assertEqual(result.canonical_core, FIXTURE["canonicalCore"].encode())
        self.assertEqual(result.report.observed_at_ms, 1789646100000)
        self.assertEqual((result.report.category, result.report.status), ("water", "dry"))
        self.assertEqual(result.report.note, "No flow observed at the spring.")
        self.assertEqual(result.canonical_envelope, canonical_core_bytes(original))

    def test_admitted_objects_are_immutable_and_receipt_time_does_not_refresh_them(self):
        first = self.assertAccepted(wire())
        later = self.assertAccepted(wire(), now=NOW + 60000)
        self.assertEqual(first, later)
        with self.assertRaises(FrozenInstanceError):
            first.expires_at_ms = NOW
        with self.assertRaises(FrozenInstanceError):
            first.report.note = "changed"
        self.assertIsInstance(first.canonical_core, bytes)

    def test_canonical_envelope_can_be_forwarded_without_resigning(self):
        result = self.assertAccepted(wire())
        self.assertEqual(self.assertAccepted(result.canonical_envelope), result)

    def test_invalid_encodings_json_and_duplicate_keys_are_rejected(self):
        duplicate = wire().replace(b'"bundle_id":', b'"bundle_id":"' + b"0" * 64 + b'","bundle_id":', 1)
        for raw in (b"", b"\xff", wire().decode().encode("utf-16"), b"\xef\xbb\xbf" + wire(),
                    wire() + b"{}", b"[]", b"null", b'{"x":NaN}', duplicate):
            with self.subTest(raw=raw[:30]):
                self.assertRejected(raw)

    def test_size_and_depth_are_bounded_before_recursive_parsing(self):
        payload = wire()
        self.assertAccepted(payload + b" " * (8192 - len(payload)))
        self.assertRejected(b" " * 8193, reason="size")
        self.assertRejected(b"[" * 9 + b"0" + b"]" * 9, reason="depth")
        self.assertRejected(b"[" * 3000 + b"]" * 3000, reason="depth")
        self.assertAccepted(self.changed(body={"note": 'Quoted "{{[[\\]]}}" text'}))

    def test_arbitrary_field_types_return_rejections_without_crashing(self):
        values = (None, True, False, 0, 1.5, "", [], {})
        for path in ((), ("core",), ("core", "body")):
            sample = envelope()
            target = sample
            for key in path:
                target = target[key]
            for field in target:
                for replacement in values:
                    if type(replacement) is type(target[field]) and replacement == target[field]:
                        continue
                    candidate = copy.deepcopy(sample)
                    changed = candidate
                    for key in path:
                        changed = changed[key]
                    changed[field] = replacement
                    with self.subTest(path=path, field=field, value=replacement):
                        result = validate_report(wire(candidate), now_ms=NOW)
                        self.assertIsInstance(result, ReportRejection)
        for raw in (None, "{}", bytearray(b"{}")):
            self.assertRejected(raw)

    def test_invalid_signature_is_not_classified_as_expired(self):
        raw = envelope()
        raw["signature"] = b64url_encode(b"\x00" * 64)
        self.assertRejected(wire(raw), now=FIXTURE["core"]["expires_at_ms"], reason="signature")

    def test_envelope_core_and_body_field_sets_are_exact(self):
        for path in ((), ("core",), ("core", "body")):
            for operation in ("missing", "extra"):
                value = envelope()
                target = value
                for key in path:
                    target = target[key]
                if operation == "missing":
                    target.pop(next(iter(target)))
                else:
                    target["unexpected"] = "untrusted"
                with self.subTest(path=path, operation=operation):
                    self.assertRejected(wire(value))

    def test_booleans_signed_floats_and_unsafe_integers_are_rejected(self):
        cases = (("version", True), ("created_at_ms", False), ("max_hops", 1.0),
                 ("created_at_ms", 9007199254740992))
        for field, value in cases:
            raw = envelope()
            raw["core"][field] = value
            with self.subTest(field=field, value=value):
                self.assertRejected(wire(raw))
        for field, value in (("lat_e7", 421790000.0), ("accuracy_m", True),
                             ("observed_at_ms", -9007199254740992)):
            raw = envelope()
            raw["core"]["body"][field] = value
            self.assertRejected(wire(raw))

    def test_unsupported_versions_and_kinds_are_distinct_from_invalid_reports(self):
        self.assertRejected(self.changed(core={"version": 2}), RejectionCode.UNSUPPORTED)
        self.assertRejected(self.changed(core={"kind": "private_message"}), RejectionCode.UNSUPPORTED)
        self.assertRejected(self.changed(core={"protocol": "other"}))

    def test_binary_field_lengths_and_noncanonical_base64_are_rejected(self):
        for field, value in (("author_key", b64url_encode(b"x" * 31)),
                             ("nonce", b64url_encode(b"x" * 15)),
                             ("author_key", FIXTURE["core"]["author_key"] + "=")):
            self.assertRejected(self.changed(core={field: value}))
        self.assertRejected(self.changed(body={"event_id": b64url_encode(b"x" * 17)}))
        raw = envelope()
        raw["signature"] = b64url_encode(b"x" * 63)
        self.assertRejected(wire(raw))

    def test_tampering_bad_signature_and_bad_id_never_admit_a_report(self):
        raw = envelope()
        raw["core"]["body"]["note"] = "tampered"
        self.assertRejected(wire(raw))
        raw = envelope()
        raw["signature"] = b64url_encode(b"\x00" * 64)
        self.assertRejected(wire(raw), reason="signature")
        for value in ("0" * 64, FIXTURE["bundleId"].upper(), "x", None):
            raw = envelope()
            raw["bundle_id"] = value
            self.assertRejected(wire(raw))

    def test_expiry_lifetime_and_future_clock_boundaries(self):
        created = FIXTURE["core"]["created_at_ms"]
        expiry = FIXTURE["core"]["expires_at_ms"]
        self.assertAccepted(wire(), now=expiry - 1)
        self.assertRejected(wire(), RejectionCode.EXPIRED, now=expiry)
        self.assertAccepted(wire(), now=created - 300000)
        self.assertRejected(wire(), now=created - 300001, reason="future")
        self.assertAccepted(self.changed(core={"expires_at_ms": created + 259200000}))
        self.assertRejected(self.changed(core={"expires_at_ms": created + 259200001}))
        for value in (created, created - 1):
            self.assertRejected(self.changed(core={"expires_at_ms": value}))
        self.assertRejected(self.changed(body={"observed_at_ms": created + 1}))
        self.assertRejected(self.changed(core={"created_at_ms": -1}))

    def test_coordinates_accuracy_hops_and_supersedes_are_validated(self):
        self.assertAccepted(self.changed(body={"lat_e7": -900000000, "lon_e7": 1800000000,
                                              "accuracy_m": 0, "supersedes": "a" * 64}, core={"max_hops": 0}))
        for field, value in (("lat_e7", 900000001), ("lat_e7", -900000001),
                             ("lon_e7", 1800000001), ("lon_e7", -1800000001),
                             ("accuracy_m", -1), ("supersedes", "A" * 64)):
            self.assertRejected(self.changed(body={field: value}))
        for value in (-1, 13):
            self.assertRejected(self.changed(core={"max_hops": value}))

    def test_category_and_status_pairs_must_be_known(self):
        self.assertAccepted(self.changed(body={"category": "hut", "status": "closed"}))
        for body in ({"category": "water", "status": "closed"}, {"category": "unknown"},
                     {"status": "invented"}, {"category": []}, {"note": None}):
            raw = envelope()
            raw["core"]["body"].update(body)
            self.assertRejected(wire(raw))

    def test_unicode_scalar_limit_validity_and_no_normalization(self):
        note = "\U0001f3d4" * 500
        accepted = self.assertAccepted(self.changed(body={"note": note}))
        self.assertEqual(accepted.report.note, note)
        self.assertRejected(self.changed(body={"note": note + "a"}))
        decomposed = self.assertAccepted(self.changed(body={"note": "e\u0301"}))
        composed = self.assertAccepted(self.changed(body={"note": "\u00e9"}))
        self.assertNotEqual(decomposed.canonical_core, composed.canonical_core)
        raw = envelope()
        raw["core"]["body"]["note"] = "\ud800"
        self.assertRejected(json.dumps(raw).encode())

    def test_rejection_reasons_do_not_echo_untrusted_content(self):
        secret = "PRIVATE_EXAMPLE_THAT_MUST_NOT_APPEAR"
        raw = envelope()
        raw[secret] = secret
        result = self.assertRejected(wire(raw))
        self.assertNotIn(secret, repr(result))

    def test_invalid_local_clock_is_a_caller_error(self):
        for now in (True, -1, 1.0, 9007199254740992):
            with self.subTest(now=now), self.assertRaises(ValueError):
                validate_report(wire(), now_ms=now)
