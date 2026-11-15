"""Corroborate logical v2 probe results across redacted device exports."""

import argparse
import json
import re
from pathlib import Path

from tools.transport.foreground_exchange import ExchangeError, make_test_payload, sha256_hex

SESSION_PATTERN = re.compile(r"[0-9a-f]{32}\Z")
MAX_LOG_BYTES = 1024 * 1024
MAX_RECORDS = 512
MAX_GROUP_LOGS = 9  # One phone and the eight peers allowed by its controlled test journal.


def _header(log: dict) -> None:
    if (not isinstance(log, dict)
            or log.get("schema") != "trailmesh.foreground-probe-log"
            or type(log.get("version")) is not int or log["version"] != 2
            or type(log.get("probe_protocol")) is not int or log["probe_protocol"] != 2
            or log.get("platform") not in ("ios", "android")
            or not isinstance(log.get("session_id"), str)
            or not SESSION_PATTERN.fullmatch(log["session_id"])
            or not isinstance(log.get("attempts"), list)
            or type(log.get("evicted_records", 0)) is not int or log.get("evicted_records", 0) < 0
            or len(log["attempts"]) > MAX_RECORDS
            or any(not isinstance(r, dict) for r in log["attempts"])):
        raise ExchangeError("Invalid or oversized v2 device export")


def _evidence(log: dict, peer: dict, event: str, payload_size: int) -> dict[int, dict]:
    evidence = {}
    for record in log["attempts"]:
        if record.get("event") != event or record.get("peer_session_id") != peer["session_id"]:
            continue
        index = record.get("attempt_index")
        if (type(index) is not int or not 0 <= index < 20
                or type(record.get("payload_size_bytes")) is not int
                or record["payload_size_bytes"] != payload_size
                or type(record.get("success")) is not bool):
            raise ExchangeError("Malformed attempt evidence")
        if index in evidence:
            fields = ("success", "expected_sha256", "received_sha256", "payload_size_bytes")
            if event == "attempt_result" or any(record.get(f) != evidence[index].get(f) for f in fields):
                raise ExchangeError("Duplicate or conflicting final attempt evidence")
            continue  # A retransmitted receipt cannot increase the logical delivery count.
        evidence[index] = record
    return evidence


def validate_pair(first: dict, second: dict, *, payload_size: int = 2048,
                  minimum_successes: int = 18) -> dict[str, int]:
    """Reject duplicate, uncorrelated or digest-mismatched success evidence."""

    if (type(payload_size) is not int or payload_size not in (256, 2048, 8192)
            or type(minimum_successes) is not int or not 0 <= minimum_successes <= 20):
        raise ExchangeError("Invalid validation gate")
    _header(first)
    _header(second)
    if first["session_id"] == second["session_id"]:
        raise ExchangeError("Two distinct device sessions are required")
    results = {}
    same_platform = first["platform"] == second["platform"]
    for ordinal, (sender, receiver) in enumerate(((first, second), (second, first)), 1):
        outgoing = _evidence(sender, receiver, "attempt_result", payload_size)
        incoming = _evidence(receiver, sender, "payload_received", payload_size)
        if set(outgoing) != set(range(20)):
            raise ExchangeError("A complete batch of 20 unique final results is required")
        successes = 0
        for index, record in outgoing.items():
            if not record["success"]:
                reason = record.get("failure_reason")
                if not isinstance(reason, str) or not reason.strip():
                    raise ExchangeError("A failed result lacks a failure reason")
                continue
            receipt = incoming.get(index)
            digest = sha256_hex(make_test_payload(payload_size, attempt_index=index))
            if (receipt is None or not receipt["success"]
                    or any(r.get("expected_sha256") != digest
                           or r.get("received_sha256") != digest for r in (record, receipt))):
                raise ExchangeError("A success lacks matching peer receipt and generated-byte digest")
            successes += 1
        if successes < minimum_successes:
            raise ExchangeError("The corroborated delivery count is below the acceptance gate")
        label = f'{sender["platform"]}-to-{receiver["platform"]}'
        if same_platform:
            label = f'{sender["platform"]}[{ordinal}]-to-{receiver["platform"]}[{3 - ordinal}]'
        results[label] = successes
    return results


def validate_group(logs: list[dict], *, payload_size: int = 2048,
                   minimum_successes: int = 18) -> dict[str, int]:
    """Corroborate every observed pair in a bounded, connected group of exports.

    Results describe logical deliveries. They cannot establish that links were
    simultaneous, or that the phones used particular radios or lifecycle states.
    """

    if not 2 <= len(logs) <= MAX_GROUP_LOGS:
        raise ExchangeError("A group requires two through nine device exports")
    if (type(payload_size) is not int or payload_size not in (256, 2048, 8192)
            or type(minimum_successes) is not int or not 0 <= minimum_successes <= 20):
        raise ExchangeError("Invalid validation gate")
    sessions = {}
    for index, log in enumerate(logs):
        _header(log)
        if log["session_id"] in sessions:
            raise ExchangeError("Every device export must have a distinct session")
        sessions[log["session_id"]] = index

    pairs = set()
    neighbors = [set() for _ in logs]
    for index, log in enumerate(logs):
        for record in log["attempts"]:
            if record.get("event") not in ("attempt_result", "payload_received"):
                continue
            peer = record.get("peer_session_id")
            if not isinstance(peer, str) or peer not in sessions or sessions[peer] == index:
                raise ExchangeError("Every observed peer requires a distinct device export")
            other = sessions[peer]
            pairs.add((min(index, other), max(index, other)))
            neighbors[index].add(other)
            neighbors[other].add(index)

    reached = {0}
    pending = [0]
    while pending:
        for other in neighbors[pending.pop()] - reached:
            reached.add(other)
            pending.append(other)
    if len(reached) != len(logs):
        raise ExchangeError("Device exports must describe one connected group")

    results = {}
    for first, second in sorted(pairs):
        forward, reverse = validate_pair(
            logs[first], logs[second], payload_size=payload_size,
            minimum_successes=minimum_successes,
        ).values()
        first_label = f'{logs[first]["platform"]}[{first + 1}]'
        second_label = f'{logs[second]["platform"]}[{second + 1}]'
        results[f"{first_label}-to-{second_label}"] = forward
        results[f"{second_label}-to-{first_label}"] = reverse
    return results


def _load(path: Path) -> dict:
    # Limit the read itself, including when the file grows after a stat check.
    with path.open("rb") as stream:
        data = stream.read(MAX_LOG_BYTES + 1)
    if len(data) > MAX_LOG_BYTES:
        raise ExchangeError("Device export exceeds the file size limit")
    try:
        return json.loads(data, object_pairs_hook=_unique_object,
                          parse_constant=lambda _: _invalid_json())
    except (ValueError, UnicodeError, RecursionError) as error:
        raise ExchangeError("Device export is not valid JSON") from error


def _invalid_json():
    raise ValueError("Invalid JSON constant")


def _unique_object(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exports", type=Path, nargs="+", help="Two through nine device exports")
    parser.add_argument("--payload-size", type=int, choices=(256, 2048, 8192), default=2048)
    args = parser.parse_args()
    try:
        if not 2 <= len(args.exports) <= MAX_GROUP_LOGS:
            raise ExchangeError("A group requires two through nine device exports")
        logs = [_load(path) for path in args.exports]
        if len(logs) == 2:
            results = validate_pair(logs[0], logs[1], payload_size=args.payload_size)
        else:
            results = validate_group(logs, payload_size=args.payload_size)
    except (ExchangeError, OSError):
        print("FAIL: exports are invalid, incomplete or lack matching delivery evidence.")
        return 1
    for direction, count in results.items():
        print(f"{direction}: {count}/20 corroborated successful attempts")
    print("Record concurrency, radio settings and interruption conditions separately; logs alone do not prove them.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
