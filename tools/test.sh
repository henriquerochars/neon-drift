#!/usr/bin/env bash
# Import the project and run gdUnit4 headless over tests/ (or the paths given as arguments).
# Fails on a non-zero exit code OR on SCRIPT ERROR / ERROR: lines in the engine log.
# Logs and reports: artifacts/import.log, artifacts/tests.log, artifacts/reports/.
#   tools/test.sh [res://tests/unit/foo ...]
# NEONDRIFT_RENDER_TESTS=1 runs the test stage with a window (no --headless) so suites that read
# rendered pixels do not self-skip. Needs a display; CI runners have none. Import stays headless.
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
ART="$ROOT/artifacts"
IMPORT_TIMEOUT="${IMPORT_TIMEOUT:-300}"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"
rm -rf "$ART"; mkdir -p "$ART"
# Keep Godot from importing generated reports and logs.
touch "$ART/.gdignore"

# Benign engine lines we cannot act on (none known yet; add with a justification):
IGNORE_RE='^$^'
# Errors we look for. gdUnit4's own "Exit code:" noise does not match.
ERROR_RE='SCRIPT ERROR|(^|[^A-Za-z_])ERROR:|Parse Error:'

# run_bounded <seconds> <logfile> <args...>: run tools/godot.sh with a watchdog (no GNU timeout on macOS).
run_bounded() {
  local secs="$1" log="$2"; shift 2
  tools/godot.sh --log-file "$log" "$@" >"${log%.log}.stdout.log" 2>&1 &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local dog=$!
  wait "$pid"; local rc=$?
  pkill -P "$dog" 2>/dev/null; kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  [ "$rc" -eq 137 ] && echo "TIMEOUT after ${secs}s" >>"${log%.log}.stdout.log"
  return "$rc"
}

scan() { # scan <label> <log files...>: print offending lines, return 1 if any
  local label="$1"; shift
  local hits
  hits=$(cat "$@" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E "$ERROR_RE" | grep -Ev "$IGNORE_RE" || true)
  if [ -n "$hits" ]; then echo "FAIL: $label log has engine errors:"; echo "$hits" | head -30; return 1; fi
  return 0
}

STATUS=0

echo "== import"
run_bounded "$IMPORT_TIMEOUT" "$ART/import.log" --headless --import
rc=$?
[ "$rc" -ne 0 ] && { echo "FAIL: import exited $rc (see artifacts/import.log)"; STATUS=1; }
scan import "$ART/import.log" "$ART/import.stdout.log" || STATUS=1

echo "== tests"
if [ "$#" -gt 0 ]; then PATHS=("$@"); else PATHS=(res://tests); fi
ARGS=()
for p in "${PATHS[@]}"; do ARGS+=(-a "$p"); done
# --ignoreHeadlessMode: gdUnit4 refuses to run headless otherwise. -c: do not stop at first failure.
DISPLAY_ARGS=(--headless)
if [ "${NEONDRIFT_RENDER_TESTS:-0}" = "1" ]; then
  echo "(render tests: running with a window, --headless dropped)"
  DISPLAY_ARGS=()
fi
run_bounded "$TEST_TIMEOUT" "$ART/tests.log" ${DISPLAY_ARGS[@]+"${DISPLAY_ARGS[@]}"} -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd \
  "${ARGS[@]}" -c --ignoreHeadlessMode -rd res://artifacts/reports
rc=$?
sed 's/\x1b\[[0-9;]*m//g' "$ART/tests.stdout.log" | grep -E "^(Run Test Suite|Statistics|Overall Summary|Executed|  res://.*(FAILED|ERROR))|FAILED|TIMEOUT" || true
[ "$rc" -ne 0 ] && { echo "FAIL: test run exited $rc (see artifacts/tests.stdout.log)"; STATUS=1; }
scan tests "$ART/tests.log" "$ART/tests.stdout.log" || STATUS=1

if [ "$STATUS" -eq 0 ]; then echo "PASS"; else echo "FAILED"; fi
exit "$STATUS"
