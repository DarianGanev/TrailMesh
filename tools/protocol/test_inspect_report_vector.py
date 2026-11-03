import io
import unittest
from contextlib import redirect_stdout

from tools.protocol.inspect_report_vector import main


class InspectReportVectorTests(unittest.TestCase):
    def test_frozen_vector_exposes_decoded_wire_and_expected_outcome(self):
        output = io.StringIO()
        with redirect_stdout(output):
            result = main(['frozen-v1'])
        self.assertEqual(result, 0)
        self.assertIn('"protocol": "trailmesh"', output.getvalue())
        self.assertIn('"outcome": "accepted"', output.getvalue())
        self.assertIn("now_ms: 1789647000000", output.getvalue())

    def test_unknown_vector_fails_without_dumping_fixture(self):
        output = io.StringIO()
        with redirect_stdout(output):
            result = main(['no-such-vector'])
        self.assertEqual(result, 1)
        self.assertIn('Unknown vector', output.getvalue())
