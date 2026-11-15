"""Cross-platform literal cases for local-only relevance selection."""

import json
import math
from pathlib import Path
import unittest

from tools.protocol.relevance import evaluate, select_reports, segment_distance_m


ROOT = Path(__file__).resolve().parents[2]


class RelevanceTests(unittest.TestCase):
    def test_shared_decisions(self):
        vectors = json.loads((ROOT / "protocol/relevance-v1-vectors.json").read_text())
        for case in vectors["cases"]:
            with self.subTest(case["name"]):
                self.assertEqual(evaluate(case["report"], case["context"], case["now_ms"]),
                                 case["expected"])

    def test_shared_selection(self):
        vectors = json.loads((ROOT / "protocol/relevance-v1-vectors.json").read_text())
        for case in vectors["selection_cases"]:
            with self.subTest(case["name"]):
                result = select_reports(case["reports"], case["context"], case["now_ms"])
                self.assertEqual([report["id"] for report in result], case["expected_ids"])

    def test_invalid_runtime_values_are_typed(self):
        report = dict(id="a", observed_at_ms=1, expires_at_ms=100, lat_e7=0, lon_e7=0)
        for accuracy in (math.nan, math.inf, -math.inf, True, "1", -1, 10 ** 1000):
            with self.subTest(accuracy=accuracy):
                context = {"gps_area": {"center": {"lat_e7": 0, "lon_e7": 0},
                            "radius_m": 100, "accuracy_m": accuracy, "fix_at_ms": 0}}
                self.assertEqual(evaluate(report, context, 1), "invalidConfiguration")

    def test_route_point_bound_and_all_vertices_are_validated(self):
        report = dict(id="a", observed_at_ms=1, expires_at_ms=100, lat_e7=0, lon_e7=0)
        point = {"lat_e7": 0, "lon_e7": 0}
        context = {"route": {"points": [point] * 2048}}
        self.assertEqual(evaluate(report, context, 1), "eligible")
        context["route"]["points"].append(point)
        self.assertEqual(evaluate(report, context, 1), "invalidConfiguration")
        context["route"]["points"] = [point, {"lat_e7": True, "lon_e7": 0}]
        self.assertEqual(evaluate(report, context, 1), "invalidConfiguration")

    def test_geometry_is_symmetric_and_closed_at_each_endpoint(self):
        start = {"lat_e7": 720000000, "lon_e7": 1700000000}
        end = {"lat_e7": 740000000, "lon_e7": -1600000000}
        point = {"lat_e7": 750000000, "lon_e7": 1800000000}
        self.assertAlmostEqual(segment_distance_m(point, start, end),
                               segment_distance_m(point, end, start), places=6)
        self.assertAlmostEqual(segment_distance_m(end, start, end), 0, places=6)

    def test_segment_distance_uses_minor_arc_and_endpoints(self):
        origin = {"lat_e7": 0, "lon_e7": 0}
        east = {"lat_e7": 0, "lon_e7": 100000000}
        self.assertAlmostEqual(segment_distance_m(origin, origin, east), 0, places=6)
        north = {"lat_e7": 10000000, "lon_e7": 50000000}
        self.assertAlmostEqual(segment_distance_m(north, origin, east),
                               6371008.8 * math.pi / 180, places=6)
        behind = {"lat_e7": 0, "lon_e7": -10000000}
        self.assertAlmostEqual(segment_distance_m(behind, origin, east),
                               6371008.8 * math.pi / 180, places=6)
