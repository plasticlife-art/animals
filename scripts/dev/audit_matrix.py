#!/usr/bin/env python3
"""Compare balance variants over many seeds, seed by seed.

    python3 scripts/dev/audit_matrix.py --out DIR [--seeds 1-8] [--mode lod|off]
        [--seconds 1440] [--jobs 4]
        --variant base
        --variant slow_hunger species.herbivore.metabolism.hunger_rate=0.5 ...
        [--variant other_code @path=/path/to/another/worktree]
        [--baseline base]

Every variant runs `scripts/dev/ecology_audit.gd` once per seed. The audit is
deterministic, so a seed never needs repeating; what varies is the map, and one map
says little. A single seed has sent a change up 44% and the next seed down 20%.
So each variant is compared with the baseline on the same seeds, pair by pair: the
mean difference, its 95% interval, and on how many seeds the variant came out higher.
An interval that does not cross zero is marked with an arrow.

`key=value` tokens override the config exactly as `ecology_audit.gd` takes them.
`@path=DIR` runs the variant from another project checkout, to compare code rather
than settings; that checkout must have been imported (`Godot --headless --import`).

Reports land in DIR/<variant>/seed-NN.json, with the Godot log beside each. A run
whose report already matches its seed, mode, length and overrides is not repeated, so
an interrupted matrix resumes where it stopped. The summary is printed and written to
DIR/summary.md and DIR/summary.json. `--summary-only` rebuilds it from the reports.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
GODOT = Path(os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot"))
AUDIT = "res://scripts/dev/ecology_audit.gd"

# Two-sided 95% critical values of Student's t, by degrees of freedom.
T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365, 8: 2.306,
       9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145, 15: 2.131,
       16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086, 25: 2.060, 30: 2.042}

def late_mean(report: dict, key: str) -> float:
    """Mean of a history column over the second half of the run, as `regulation` averages."""
    rows = report.get("history", [])
    late = rows[len(rows) // 2:]
    return sum(float(row.get(key, 0.0)) for row in late) / max(1, len(late))


def last_value(report: dict, key: str, default: float = 1.0) -> float:
    """A history column's last value, `default` where no row has it (a trait without heredity)."""
    for row in reversed(report.get("history", [])):
        if key in row:
            return float(row[key])
    return default


def trait_metrics() -> list:
    """Each species' mean inherited traits at the end of the run (1.0 without heredity)."""
    metrics = []
    for species in ("herbivore", "predator", "scavenger"):
        for name in ("speed", "vision", "appetite", "longevity"):
            key = f"{species}_trait_{name}"
            metrics.append((key, f"{species} {name}, end", lambda r, key=key: last_value(r, key)))
    return metrics


# (key, label, how to read it from a report). Late-half figures come from the audit's
# `regulation` block, which averages the second half of the run.
METRICS = [
    ("herbivore_mean", "herbivores, late mean", lambda r: r["regulation"]["herbivore"]["mean"]),
    ("herbivore_low", "herbivores, late low", lambda r: r["regulation"]["herbivore"]["min"]),
    ("herbivore_end", "herbivores at the end", lambda r: r["population"]["herbivore"]),
    ("predator_mean", "predators, late mean", lambda r: r["regulation"]["predator"]["mean"]),
    ("predator_cap", "predators, share on cap", lambda r: r["regulation"]["predator"]["share_at_cap"]),
    ("predator_low", "predators, late low", lambda r: r["regulation"]["predator"]["min"]),
    ("scavenger_mean", "scavengers, late mean", lambda r: r["regulation"]["scavenger"]["mean"]),
    ("scavenger_cap", "scavengers, share on cap", lambda r: r["regulation"]["scavenger"]["share_at_cap"]),
    ("scavenger_low", "scavengers, late low", lambda r: r["regulation"]["scavenger"]["min"]),
    ("grass", "grass density, late", lambda r: r["regulation"]["grass_density_mean"]),
    ("births_herbivore", "herbivore births", lambda r: r["counters"].get("births_herbivore", 0)),
    ("starved_herbivore", "herbivores starved", lambda r: r["counters"].get("deaths_starvation_herbivore", 0)),
    ("preyed_herbivore", "herbivores killed", lambda r: r["counters"].get("deaths_predation_herbivore", 0)),
    ("births_predator", "predator births", lambda r: r["counters"].get("births_predator", 0)),
    ("starved_predator", "predators starved", lambda r: r["counters"].get("deaths_starvation_predator", 0)),
    ("births_scavenger", "scavenger births", lambda r: r["counters"].get("births_scavenger", 0)),
    ("starved_scavenger", "scavengers starved", lambda r: r["counters"].get("deaths_starvation_scavenger", 0)),
    ("carcasses_wasted", "carcasses expired, share",
     lambda r: r["counters"].get("carcasses_expired", 0) / max(1, r["counters"].get("carcasses_spawned", 0))),
    ("meat_lying", "meat lying on the map, late", lambda r: late_mean(r, "carcass_meat")),
    ("herd_migrations", "herd migrations", lambda r: r["counters"].get("herd_migrations", 0)),
    ("chain_broken", "food chain broke", lambda r: 0 if r.get("stop_reason") == "duration" else 1),
    ("species_lost", "species lost", lambda r: sum(1 for count in r["population"].values() if int(count) == 0)),
    ("herbivore_min", "herbivores, lowest", lambda r: r["population_min"]["herbivore"]),
    ("predator_min", "predators, lowest", lambda r: r["population_min"]["predator"]),
    ("scavenger_min", "scavengers, lowest", lambda r: r["population_min"]["scavenger"]),
] + trait_metrics()


def parse_seeds(value: str) -> list[int]:
    seeds: list[int] = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start, end = (int(bound) for bound in part.split("-", 1))
            seeds.extend(range(start, end + 1))
        else:
            seeds.append(int(part))
    return seeds


def parse_variants(raw: list[list[str]] | None) -> list[dict]:
    variants = []
    for tokens in raw or [["base"]]:
        name, rest = tokens[0], tokens[1:]
        path = PROJECT
        overrides: list[str] = []
        for token in rest:
            if token.startswith("@path="):
                path = Path(token.split("=", 1)[1]).expanduser().resolve()
            elif "=" in token:
                overrides.append(token)
            else:
                raise SystemExit(f"variant {name}: not key=value or @path=: {token}")
        variants.append({"name": name, "path": path, "overrides": overrides})
    names = [variant["name"] for variant in variants]
    if len(set(names)) != len(names):
        raise SystemExit("variant names must differ")
    return variants


def expected_overrides(overrides: list[str]) -> dict:
    """What the audit records for these tokens: values parsed as JSON where they parse."""
    result = {}
    for token in overrides:
        key, raw = token.split("=", 1)
        try:
            result[key] = json.loads(raw)
        except json.JSONDecodeError:
            result[key] = raw
    return result


def matches(report: dict, seed: int, lod: bool, seconds: float, overrides: list[str]) -> bool:
    return (int(report.get("seed", -1)) == seed
            and bool(report.get("lod")) == lod
            and abs(float(report.get("requested_seconds", -1.0)) - seconds) < 0.001
            and report.get("overrides", {}) == expected_overrides(overrides))


def run_one(out: Path, variant: dict, seed: int, lod: bool, seconds: float) -> dict:
    folder = out / variant["name"]
    folder.mkdir(parents=True, exist_ok=True)
    report_path = folder / f"seed-{seed:02d}.json"
    if report_path.exists():
        cached = json.loads(report_path.read_text(encoding="utf-8"))
        if matches(cached, seed, lod, seconds, variant["overrides"]):
            return cached
    command = [str(GODOT), "--headless", "--path", str(variant["path"]), "--script", AUDIT, "--",
               str(seed), "lod" if lod else "off", str(seconds), str(report_path), *variant["overrides"]]
    # Output goes straight to the log file, not through a pipe: if this matrix is stopped,
    # runs already going keep writing and finish their reports, which the next matrix
    # picks up. Through a pipe they died of SIGPIPE on their last print.
    with open(folder / f"seed-{seed:02d}.log", "w", encoding="utf-8") as log:
        completed = subprocess.run(command, cwd=variant["path"], stdout=log, stderr=subprocess.STDOUT)
    if completed.returncode != 0 or not report_path.exists():
        raise RuntimeError(f"{variant['name']} seed {seed}: exit {completed.returncode}, see its log")
    return json.loads(report_path.read_text(encoding="utf-8"))


def t95(df: int) -> float:
    if df in T95:
        return T95[df]
    known = sorted(key for key in T95 if key <= df)
    return T95[known[-1]] if known else T95[1]


def describe(values: list[float]) -> tuple[float, float]:
    mean = sum(values) / len(values)
    if len(values) < 2:
        return mean, 0.0
    return mean, math.sqrt(sum((value - mean) ** 2 for value in values) / (len(values) - 1))


def paired(base: list[float], other: list[float]) -> dict:
    """Mean of `other - base` seed by seed, its 95% interval, and how often other was higher."""
    diffs = [b - a for a, b in zip(base, other)]
    mean, sd = describe(diffs)
    half = t95(len(diffs) - 1) * sd / math.sqrt(len(diffs)) if len(diffs) > 1 else math.inf
    return {"mean": mean, "low": mean - half, "high": mean + half,
            "higher": sum(diff > 0 for diff in diffs), "lower": sum(diff < 0 for diff in diffs),
            "n": len(diffs)}


def summarize(variants: list[dict], seeds: list[int], reports: dict, baseline: str) -> dict:
    summary = {"seeds": seeds, "baseline": baseline, "variants": {}}
    for variant in variants:
        name = variant["name"]
        rows = [reports[(name, seed)] for seed in seeds if (name, seed) in reports]
        entry = {"overrides": variant["overrides"], "path": str(variant["path"]), "runs": len(rows), "metrics": {}}
        for key, _label, read in METRICS:
            values = [float(read(row)) for row in rows]
            if not values:
                continue
            mean, sd = describe(values)
            metric = {"mean": mean, "sd": sd, "by_seed": dict(zip([row["seed"] for row in rows], values))}
            if name != baseline:
                shared = [seed for seed in seeds if (name, seed) in reports and (baseline, seed) in reports]
                if shared:
                    metric["vs_baseline"] = paired([float(read(reports[(baseline, seed)])) for seed in shared],
                                                   [float(read(reports[(name, seed)])) for seed in shared])
            entry["metrics"][key] = metric
        summary["variants"][name] = entry
    return summary


def number(value: float) -> str:
    if value == 0 or abs(value) >= 10:
        return f"{value:.0f}"
    return f"{value:.2f}"


def markdown(summary: dict, mode: str, seconds: float) -> str:
    names = list(summary["variants"].keys())
    baseline = summary["baseline"]
    lines = [f"Mode {mode}, {seconds:.0f} s, seeds {', '.join(str(seed) for seed in summary['seeds'])}. "
             f"Mean ± sd over seeds; against `{baseline}`: mean difference [95% interval], "
             f"seeds where the variant was higher / lower. An arrow marks an interval clear of zero.", ""]
    header = "| metric | " + " | ".join(names) + " |"
    lines += [header, "|" + "---|" * (len(names) + 1)]
    for key, label, _read in METRICS:
        cells = []
        for name in names:
            metric = summary["variants"][name]["metrics"].get(key)
            if metric is None:
                cells.append("-")
                continue
            cell = f"{number(metric['mean'])} ± {number(metric['sd'])}"
            versus = metric.get("vs_baseline")
            if versus:
                arrow = "↑ " if versus["low"] > 0 else ("↓ " if versus["high"] < 0 else "")
                interval = "n/a" if math.isinf(versus["high"]) else f"{number(versus['low'])}..{number(versus['high'])}"
                cell += f"<br>{arrow}{'+' if versus['mean'] >= 0 else ''}{number(versus['mean'])} [{interval}] " \
                        f"{versus['higher']}/{versus['lower']}"
            cells.append(cell)
        lines.append(f"| {label} | " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n"


def self_test() -> None:
    result = paired([10.0, 20.0, 30.0], [12.0, 23.0, 31.0])
    assert abs(result["mean"] - 2.0) < 1e-9, result
    # sd of (2, 3, 1) is 1; t(2) = 4.303; half width 4.303 / sqrt(3)
    assert abs(result["high"] - (2.0 + 4.303 / math.sqrt(3))) < 1e-6, result
    assert result["higher"] == 3 and result["lower"] == 0
    assert parse_seeds("1-3,7") == [1, 2, 3, 7]
    assert expected_overrides(["a.b=0.5", "a.c=false", "a.d=text"]) == {"a.b": 0.5, "a.c": False, "a.d": "text"}
    report = {"history": [{"herbivore_trait_speed": 1.02}, {"herbivore": 0}]}
    assert last_value(report, "herbivore_trait_speed") == 1.02 and last_value(report, "predator_trait_speed") == 1.0
    print("self test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", type=Path)
    parser.add_argument("--seeds", default="1-8")
    parser.add_argument("--mode", choices=["lod", "off"], default="lod")
    parser.add_argument("--seconds", type=float, default=1440.0)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--variant", nargs="+", action="append", metavar="NAME [key=value | @path=DIR]",
                        help="a name, then its overrides; repeat per variant (default: one variant, base)")
    parser.add_argument("--baseline")
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.out is None:
        parser.error("--out is required")
    seeds = parse_seeds(args.seeds)
    variants = parse_variants(args.variant)
    baseline = args.baseline or variants[0]["name"]
    if baseline not in [variant["name"] for variant in variants]:
        raise SystemExit(f"baseline {baseline} is not a variant")
    lod = args.mode == "lod"
    args.out.mkdir(parents=True, exist_ok=True)
    try:
        load = os.getloadavg()[0]
        if load > (os.cpu_count() or 1):
            print(f"note: load {load:.1f} on {os.cpu_count()} cores; runs will be slow, results are unaffected",
                  flush=True)
    except OSError:
        pass

    reports: dict = {}
    failures: list[str] = []
    # Seed-major, so a matrix stopped halfway still holds every variant on the same seeds.
    requests = [(variant, seed) for seed in seeds for variant in variants]
    if args.summary_only:
        for variant, seed in requests:
            path = args.out / variant["name"] / f"seed-{seed:02d}.json"
            if path.exists():
                report = json.loads(path.read_text(encoding="utf-8"))
                if matches(report, seed, lod, args.seconds, variant["overrides"]):
                    reports[(variant["name"], seed)] = report
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            futures = {pool.submit(run_one, args.out, variant, seed, lod, args.seconds): (variant["name"], seed)
                       for variant, seed in requests}
            for future in concurrent.futures.as_completed(futures):
                name, seed = futures[future]
                try:
                    reports[(name, seed)] = future.result()
                    print(f"done {name} seed {seed} ({len(reports)}/{len(requests)})", flush=True)
                except RuntimeError as error:
                    failures.append(str(error))
                    print(f"FAILED {error}", flush=True)

    summary = summarize(variants, seeds, reports, baseline)
    summary.update({"mode": args.mode, "seconds": args.seconds, "failures": failures})
    table = markdown(summary, args.mode, args.seconds)
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (args.out / "summary.md").write_text(table, encoding="utf-8")
    print(table)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
