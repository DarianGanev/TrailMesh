"""Consume literal vectors shared with future Swift/Kotlin store adapters."""

import base64
import hashlib
import json
from pathlib import Path
import unittest

from tools.protocol.report import ReportRejection, ValidatedReport, validate_report


class SharedReportVectorTests(unittest.TestCase):
    def test_language_neutral_admission_vectors(self):
        path = Path(__file__).resolve().parents[2] / "protocol/report-v1-vectors.json"
        vectors = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(vectors["schema"], "trailmesh.report-admission-vectors")
        self.assertEqual(vectors["version"], 1)
        names = set()
        for case in vectors["cases"]:
            with self.subTest(case=case["name"]):
                self.assertNotIn(case["name"], names)
                names.add(case["name"])
                raw = base64.b64decode(case["wire_base64"], validate=True)
                result = validate_report(raw, now_ms=case["now_ms"])
                expected = case["expected"]
                if expected["outcome"] == "accepted":
                    self.assertIsInstance(result, ValidatedReport)
                    self.assertEqual(result.bundle_id, expected["bundle_id"])
                    self.assertEqual(result.canonical_core, base64.b64decode(expected["canonical_core_base64"]))
                    self.assertEqual(result.canonical_envelope, base64.b64decode(expected["canonical_envelope_base64"]))
                    self.assertEqual(hashlib.sha256(result.canonical_core).hexdigest(), expected["core_sha256"])
                    projection = {name: getattr(result.report, name) for name in expected["report"]}
                    projection["event_id"] = projection["event_id"].hex()
                    self.assertEqual(projection, expected["report"])
                else:
                    self.assertIsInstance(result, ReportRejection)
                    self.assertEqual(result.code.value, expected["outcome"])
        self.assertGreaterEqual(len(names), 15)
