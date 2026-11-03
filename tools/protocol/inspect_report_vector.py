"""Inspect one literal report vector without modifying the shared fixture."""

import argparse
import base64
import json
from pathlib import Path


VECTORS = Path(__file__).resolve().parents[2] / 'protocol' / 'report-v1-vectors.json'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', help='Exact vector case name')
    args = parser.parse_args(argv)
    vectors = json.loads(VECTORS.read_text(encoding='utf-8'))
    case = next((item for item in vectors['cases'] if item['name'] == args.name), None)
    if case is None:
        print(f'Unknown vector: {args.name}')
        return 1
    wire = base64.b64decode(case['wire_base64'], validate=True)
    try:
        text = wire.decode('utf-8')
        # Pretty-print only standard JSON; preserve invalid cases as escaped bytes.
        from tools.protocol.vector import parse_json_strict
        decoded = parse_json_strict(text)
        rendered = json.dumps(decoded, ensure_ascii=True, indent=2)
    except (UnicodeError, ValueError, RecursionError):
        rendered = repr(wire)
    print(f'Case: {case["name"]}\nWire bytes: {len(wire)}\nDecoded wire:')
    print(rendered)
    print(f'now_ms: {case["now_ms"]}')
    print('Expected:')
    print(json.dumps(case['expected'], ensure_ascii=True, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
