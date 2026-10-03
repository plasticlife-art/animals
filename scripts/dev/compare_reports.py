#!/usr/bin/env python3
"""Whether two `ecology_audit.gd` reports describe the same world, bit for bit.

    python3 scripts/dev/compare_reports.py REFERENCE CANDIDATE [--strict]

For a change that must leave a world alone when it is switched off: run the audit on
the reference code and on the change with its switches off, then compare. Everything
the reference has is compared exactly - the history rows, the counters, the
population with its lows and highs, the regulation and formation summaries, the
outcome and the capacities - on the reference's own keys, so columns or counters the
change adds are allowed. Wall-clock timings are never compared; `--strict` adds the
performance counters that are not timings. When the runs differ in length, only the
shared prefix of history is compared and the totals are skipped.

Prints IDENTICAL or the first difference, and exits 0 or 1.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SUMMARIES = ["population", "population_min", "population_max", "regulation", "formation", "outcome",
             "reproductive_capacity", "initial_population", "starvation_risk_animal_seconds", "lod_counts",
             "stop_reason", "simulated_seconds"]


def first_difference(reference, candidate, path: str) -> str | None:
    """The first place `candidate` does not match `reference`, on the reference's keys."""
    if isinstance(reference, dict):
        if not isinstance(candidate, dict):
            return f"{path}: {type(candidate).__name__} instead of a dictionary"
        for key in reference:
            if key not in candidate:
                return f"{path}.{key}: missing"
            found = first_difference(reference[key], candidate[key], f"{path}.{key}")
            if found:
                return found
        return None
    if isinstance(reference, list):
        if not isinstance(candidate, list) or len(candidate) != len(reference):
            return f"{path}: list differs in length"
        for index, (left, right) in enumerate(zip(reference, candidate)):
            found = first_difference(left, right, f"{path}[{index}]")
            if found:
                return found
        return None
    if reference != candidate:
        return f"{path}: {reference!r} != {candidate!r}"
    return None


def compare(reference: dict, candidate: dict, strict: bool) -> str | None:
    rows = min(len(reference.get("history", [])), len(candidate.get("history", [])))
    for index in range(rows):
        found = first_difference(reference["history"][index], candidate["history"][index],
                                 f"history[{index}] (t={reference['history'][index].get('time')})")
        if found:
            return found
    if len(reference.get("history", [])) != len(candidate.get("history", [])):
        return None
    for key in ["counters"] + SUMMARIES:
        if key in reference:
            found = first_difference(reference[key], candidate.get(key), key)
            if found:
                return found
    if strict:
        counters = {key: value for key, value in reference.get("performance_counters", {}).items()
                    if not key.endswith("_ms")}
        found = first_difference(counters, candidate.get("performance_counters", {}), "performance_counters")
        if found:
            return found
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    reference = json.loads(args.reference.read_text(encoding="utf-8"))
    candidate = json.loads(args.candidate.read_text(encoding="utf-8"))
    found = compare(reference, candidate, args.strict)
    rows = min(len(reference.get("history", [])), len(candidate.get("history", [])))
    if found:
        print(f"DIFFERENT {found}")
        return 1
    same_length = len(reference.get("history", [])) == len(candidate.get("history", []))
    print(f"IDENTICAL {rows} history rows" + (", totals too" if same_length else " (prefix; totals not compared)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
