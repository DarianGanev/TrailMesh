"""Fail a platform check if its JUnit reports are missing, empty, skipped, or failing."""
import argparse
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
args = parser.parse_args()
files = list(args.directory.rglob("TEST-*.xml"))
if not files:
    raise SystemExit("Missing JUnit results")
tests = failures = skipped = 0
for path in files:
    root = ET.parse(path).getroot()
    suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
    for suite in suites:
        tests += int(suite.get("tests", 0))
        failures += int(suite.get("failures", 0)) + int(suite.get("errors", 0))
        skipped += int(suite.get("skipped", 0))
if tests == 0 or failures or skipped:
    raise SystemExit(f"JUnit gate failed: tests={tests}, failures={failures}, skipped={skipped}")
print(f"Passed {tests} tests across {len(files)} JUnit reports")
