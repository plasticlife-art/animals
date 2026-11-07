#!/usr/bin/env bash
# Runs a heavy command - a Godot batch run: tests, audits, matrices, captures, an
# import - in heavy's machine-wide queue (https://github.com/mokevnin/heavy), so the
# sessions of every project on this laptop take turns instead of all running at once.
#
#   scripts/dev/heavy.sh /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
#     res://scenes/tests/test_runner.tscn > tests.log 2>&1; echo $?
#
# The machine pool has 2 slots, shared with lottery-bot's scripts/heavy.sh; after 10
# minutes without a slot the command runs anyway. A test suite or a save check first
# takes the single slot of pool "animals-user-data": every checkout of the project
# shares one user:// folder, and two suites at once overwrite each other's saves.
# Without heavy installed the command runs at once. The exit status is the command's.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: scripts/dev/heavy.sh <command> [args...]" >&2
  exit 64
fi

if ! command -v heavy >/dev/null 2>&1; then
  exec "$@"
fi

log="${HEAVY_LOG:-${TMPDIR:-/tmp}/heavy.log}"
machine=(heavy --slots "${HEAVY_SLOTS:-2}" --timeout "${HEAVY_TIMEOUT:-600}"
  --on-timeout "${HEAVY_ON_TIMEOUT:-run}" --log "$log" --)

user_data=false
for arg in "$@"; do
  case "$arg" in
    *test_runner.tscn* | *check_save.gd* | *check_autosave.gd*) user_data=true ;;
  esac
done

if ! $user_data; then
  exec "${machine[@]}" "$@"
fi

lock=(heavy --pool animals-user-data --slots 1 --timeout "${HEAVY_USER_DATA_TIMEOUT:-1200}"
  --on-timeout fail --log "$log" --)
# heavy remembers only the innermost pool held (HEAVY_HELD). A caller already in a
# machine slot keeps it: asking for another from inside the lock could wait on itself.
if [[ "${HEAVY_HELD:-}" == "${HEAVY_POOL:-default}" ]]; then
  run=("${lock[@]}" "$@")
else
  run=("${lock[@]}" "${machine[@]}" "$@")
fi

status=0
"${run[@]}" || status=$?
if [[ $status -eq 75 ]]; then
  cat >&2 <<'MSG'
heavy.sh: another Animals test suite or save check has held user:// for too long.
  heavy --pool animals-user-data --status    shows who holds it
A suite stuck at 0% CPU is usually Godot's modal alert: run test_runner.tscn as a scene,
never as --script.
MSG
fi
exit "$status"
