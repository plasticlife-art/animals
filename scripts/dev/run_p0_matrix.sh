#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
OUTPUT_DIR="${1:-/private/tmp/animals-p0-matrix}"
REPETITIONS="${2:-3}"
MEASURED_FRAMES="${3:-720}"
SEED_BASE="${4:-1337}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-2}"

styles=(topdown_kenney isometric_craftpix)
map_sizes=(small medium large)
mixes=(balanced few_predators many_predators large_herds small_herds)

mkdir -p "$OUTPUT_DIR"
for style in "${styles[@]}"; do
  for map_size in "${map_sizes[@]}"; do
    for mix in "${mixes[@]}"; do
      for ((repeat = 1; repeat <= REPETITIONS; repeat++)); do
        seed=$((SEED_BASE + repeat - 1))
        run_dir="$OUTPUT_DIR/${style}_${map_size}_${mix}_r${repeat}"
        mkdir -p "$run_dir"
        if jq -e '.results | length == 3' "$run_dir/performance.json" >/dev/null 2>&1; then
          echo "reuse $run_dir/performance.json"
          continue
        fi
        "$GODOT_BIN" --path "$PROJECT_DIR" \
          --script res://scripts/dev/visual_audit.gd -- \
          "$style" "$map_size" "$mix" 1.0 "$run_dir" "$MEASURED_FRAMES" "$seed"
        if [[ "$COOLDOWN_SECONDS" != "0" ]]; then
          sleep "$COOLDOWN_SECONDS"
        fi
      done
    done
  done
done

expected_reports=$((2 * 3 * 5 * REPETITIONS))
actual_reports="$(find "$OUTPUT_DIR" -name performance.json | wc -l | tr -d ' ')"
if [[ "$actual_reports" -ne "$expected_reports" ]]; then
  echo "Expected $expected_reports performance reports, found $actual_reports" >&2
  exit 1
fi

find "$OUTPUT_DIR" -name performance.json -print0 \
  | xargs -0 jq -s '.' > "$OUTPUT_DIR/matrix.json"

jq '[.[] as $run | $run.results[] | {
  selection: $run.selection,
  seed: $run.seed,
  view: .view,
  logical_viewport_resolution: $run.logical_viewport_resolution,
  frame_p95_ms: .performance.frame_ms.p95,
  frame_p99_ms: .performance.frame_ms.p99,
  actual_speed: .measured_actual_speed,
  dropped_simulation_seconds: .performance.dropped_simulation_seconds,
  tier: (if ($run.selection.mix == "many_predators" or $run.selection.mix == "large_herds")
    then "extreme" else "standard" end),
  accepted: (.logical_viewport_resolution == [1600, 900]
    and .performance.frame_ms.p95 <= 16.7
    and .performance.frame_ms.p99 <= 33.3
    and .measured_actual_speed >= 0.98
    and .performance.dropped_simulation_seconds <= 0.056)
}]' "$OUTPUT_DIR/matrix.json" > "$OUTPUT_DIR/acceptance.json"

jq '[.[] | select(.tier == "standard")]' "$OUTPUT_DIR/acceptance.json" \
  > "$OUTPUT_DIR/standard-acceptance.json"
jq '[.[] | select(.tier == "extreme")]' "$OUTPUT_DIR/acceptance.json" \
  > "$OUTPUT_DIR/extreme-report.json"

# Stress presets are always reported, including real-time slowdown, but the P0
# acceptance gate follows the plan's explicit allowance for a separate extreme
# report. Every standard view in all three repeats must pass.
jq -e '[.[] | select(.tier == "standard") | .accepted] | all' \
  "$OUTPUT_DIR/acceptance.json"
