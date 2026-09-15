#!/usr/bin/env python3
"""Run and summarize the deterministic P3 ecology acceptance matrix."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import subprocess
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
AUDIT = "res://scripts/dev/ecology_audit.gd"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=1440.0)
    parser.add_argument("--seeds", default="1-10", help="Range (1-10) or comma list")
    parser.add_argument("--modes", default="lod,off", help="Comma list: lod,off")
    parser.add_argument("--jobs", type=int, default=2)
    return parser.parse_args()


def parse_seeds(value: str) -> list[int]:
    if "-" in value and "," not in value:
        start, end = (int(part) for part in value.split("-", 1))
        return list(range(start, end + 1))
    return [int(part) for part in value.split(",") if part]


def run_one(output: Path, seconds: float, seed: int, mode: str) -> dict:
    report_path = output / f"seed-{seed:02d}-{mode}.json"
    log_path = output / f"seed-{seed:02d}-{mode}.log"
    if report_path.exists():
        cached = json.loads(report_path.read_text(encoding="utf-8"))
        expected_lod = mode == "lod"
        if (
            int(cached.get("seed", -1)) == seed
            and bool(cached.get("lod", not expected_lod)) == expected_lod
            and abs(float(cached.get("requested_seconds", -1.0)) - seconds) < 0.001
        ):
            return cached
    command = [
        str(GODOT), "--headless", "--path", str(PROJECT), "--script", AUDIT,
        "--", str(seed), mode, str(seconds), str(report_path),
    ]
    completed = subprocess.run(command, cwd=PROJECT, text=True, capture_output=True)
    log_path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
    if completed.returncode != 0 or not report_path.exists():
        raise RuntimeError(f"seed={seed} mode={mode} exit={completed.returncode}; see {log_path}")
    return json.loads(report_path.read_text(encoding="utf-8"))


def summarize(runs: list[dict], seconds: float, seeds: list[int], modes: list[str]) -> dict:
    species = sorted(runs[0]["population"].keys()) if runs else []
    by_mode: dict[str, dict] = {}
    for mode in modes:
        selected = [run for run in runs if ("lod" if run["lod"] else "off") == mode]
        mode_summary = {"runs": len(selected), "species": {}}
        for species_id in species:
            survived = sum(bool(run["outcome"][species_id]["survived"]) for run in selected)
            reproduced = sum(bool(run["outcome"][species_id]["reproduced"]) for run in selected)
            within_capacity = sum(
                int(run["population_max"][species_id]) <= int(run["reproductive_capacity"][species_id])
                for run in selected
            )
            mode_summary["species"][species_id] = {
                "survived": survived,
                "reproduced": reproduced,
                "within_capacity": within_capacity,
                "final_min": min((int(run["population"][species_id]) for run in selected), default=0),
                "final_max": max((int(run["population"][species_id]) for run in selected), default=0),
            }
        primary_pass = all(
            mode_summary["species"].get(species_id, {}).get("survived", 0) >= 9
            and mode_summary["species"].get(species_id, {}).get("reproduced", 0) >= 9
            for species_id in ("herbivore", "predator")
        ) if len(selected) == 10 else None
        mode_summary["primary_acceptance_pass"] = primary_pass
        by_mode[mode] = mode_summary
    return {
        "schema_version": 1,
        "requested_seconds": seconds,
        "seeds": seeds,
        "modes": modes,
        "runs": len(runs),
        "by_mode": by_mode,
    }


def main() -> int:
    args = parse_args()
    seeds = parse_seeds(args.seeds)
    modes = [part for part in args.modes.split(",") if part]
    if not seeds or any(mode not in {"lod", "off"} for mode in modes):
        raise SystemExit("invalid seeds or modes")
    args.output.mkdir(parents=True, exist_ok=True)
    jobs = max(1, args.jobs)
    requests = [(seed, mode) for mode in modes for seed in seeds]
    runs: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = {
            executor.submit(run_one, args.output, args.seconds, seed, mode): (seed, mode)
            for seed, mode in requests
        }
        for future in concurrent.futures.as_completed(futures):
            seed, mode = futures[future]
            runs.append(future.result())
            print(f"complete seed={seed} mode={mode}", flush=True)
    runs.sort(key=lambda run: (bool(run["lod"]), int(run["seed"])))
    summary = summarize(runs, args.seconds, seeds, modes)
    (args.output / "summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
