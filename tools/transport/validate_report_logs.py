"""Corroborate saved synthetic report copies from three product exports.

Physical range, relay order, process restart and simultaneous radio links require
the operator's recorded observations. Matching exports alone cannot prove them.
"""

import argparse
import re
import uuid
from pathlib import Path

from tools.transport.foreground_exchange import ExchangeError
from tools.transport.validate_probe_logs import _load


SAFE_INTEGER = 9007199254740991
HASH = re.compile(r"[0-9a-f]{64}\Z")
SESSION = re.compile(r"[0-9a-f]{32}\Z")
CODE = re.compile(r"[a-z][a-z0-9_]{0,63}\Z")
REPORT_FIELDS = {
    "bundle_id", "canonical_core_sha256", "original_wire_sha256", "observed_at_ms",
    "is_expired", "is_quarantined", "remaining_hops",
}
HEADER_FIELDS = {
    "schema", "version", "platform", "deviceModel", "osVersion", "appBuild",
    "sourceCommit", "exportID", "sessionID", "state", "events", "saved_test_reports",
}


def _integer(value, maximum=SAFE_INTEGER):
    return type(value) is int and 0 <= value <= maximum


def _hash(value):
    return isinstance(value, str) and HASH.fullmatch(value) is not None


def _text(value, maximum):
    return isinstance(value, str) and 0 < len(value) <= maximum and bool(value.strip())


def _header(log):
    if (not isinstance(log, dict) or not set(log) <= HEADER_FIELDS
            or log.get("schema") != "trailmesh.report-session-log"
            or type(log.get("version")) is not int or log["version"] != 1
            or log.get("platform") not in ("ios", "android")
            or not all(_text(log.get(key), 128) for key in ("deviceModel", "osVersion", "appBuild", "state"))
            or not _text(log.get("exportID"), 36)
            or not isinstance(log.get("sessionID"), str)
            or not SESSION.fullmatch(log["sessionID"]) or log["sessionID"] == "0" * 32
            or not isinstance(log.get("events"), list) or len(log["events"]) > 512
            or not isinstance(log.get("saved_test_reports"), list) or len(log["saved_test_reports"]) > 64):
        raise ExchangeError("Invalid or oversized product export")
    try:
        identifier = uuid.UUID(log["exportID"])
    except ValueError as error:
        raise ExchangeError("Invalid export identifier") from error
    if log.get("sourceCommit") is not None and not _text(log["sourceCommit"], 64):
        raise ExchangeError("Invalid source reference")
    for event in log["events"]:
        if (not isinstance(event, dict)
                or not {"code", "timestamp_ms"} <= set(event)
                or not set(event) <= {"code", "timestamp_ms", "peer_session_id", "bundle_id"}
                or not isinstance(event["code"], str) or not CODE.fullmatch(event["code"])
                or not _integer(event["timestamp_ms"])
                or ("peer_session_id" in event and not _text(event["peer_session_id"], 64))
                or ("bundle_id" in event and not _hash(event["bundle_id"]))):
            raise ExchangeError("Malformed diagnostic event")
    return identifier


def _reports(log):
    reports = {}
    for record in log["saved_test_reports"]:
        if (not isinstance(record, dict) or set(record) != REPORT_FIELDS
                or not all(_hash(record.get(key)) for key in
                           ("bundle_id", "canonical_core_sha256", "original_wire_sha256"))
                or not _integer(record.get("observed_at_ms"))
                or not _integer(record.get("remaining_hops"), 12)
                or type(record.get("is_expired")) is not bool
                or type(record.get("is_quarantined")) is not bool
                or record["bundle_id"] in reports):
            raise ExchangeError("Malformed or duplicate saved-report evidence")
        reports[record["bundle_id"]] = record
    return reports


def validate_relay(creator, carrier, receiver, *, bundle_id):
    """Require matching current stored copies, without inferring radio conditions."""
    if not _hash(bundle_id):
        raise ExchangeError("Invalid report identifier")
    exports = (creator, carrier, receiver)
    export_ids = [_header(log) for log in exports]
    if len(set(export_ids)) != 3 or len({log["sessionID"] for log in exports}) != 3:
        raise ExchangeError("Three distinct exports and sessions are required")
    records = []
    for log in exports:
        record = _reports(log).get(bundle_id)
        if record is None or record["is_expired"] or record["is_quarantined"]:
            raise ExchangeError("A current stored report is missing")
        records.append(record)
    immutable = ("canonical_core_sha256", "original_wire_sha256", "observed_at_ms")
    original = records[0]
    if any(record[key] != original[key] for record in records[1:] for key in immutable):
        raise ExchangeError("Saved copies disagree with the original report")
    return {"bundle_id": bundle_id, "canonical_core_sha256": original["canonical_core_sha256"],
            "original_wire_sha256": original["original_wire_sha256"],
            "observed_at_ms": original["observed_at_ms"], "saved_copies": 3}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("creator", type=Path)
    parser.add_argument("carrier", type=Path)
    parser.add_argument("receiver", type=Path)
    parser.add_argument("--bundle-id", required=True)
    args = parser.parse_args()
    try:
        # Reuse the probe tooling's bounded read and strict duplicate-key JSON parser.
        validate_relay(_load(args.creator), _load(args.carrier), _load(args.receiver), bundle_id=args.bundle_id)
    except (ExchangeError, OSError):
        print("FAIL: saved-report exports are invalid, incomplete or disagree.")
        return 1
    print("PASS: three saved copies have matching report ID, hashes and observation time.")
    print("Record physical range, relay order, restart and concurrency separately.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
