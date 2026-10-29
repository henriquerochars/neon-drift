#!/bin/sh
# Public entry point of the shared AI harness (ADR 0007, docs/ai/README.md).
#   tools/agent.sh bootstrap [--retry] [--skip-import]
#   tools/agent.sh check [--base REF] [--force] [--retry] [--status] [--json] [--quiet]
#   tools/agent.sh status                 # same as: check --status
#   tools/agent.sh test-harness           # harness unit tests + tools/check_harness.py
#   tools/agent.sh guard                  # shared guard: one JSON request on stdin
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PY=${NEONDRIFT_PYTHON:-python3}
cd "$ROOT"
[ "$#" -gt 0 ] || { sed -n '2,7p' "$0" >&2; exit 2; }
COMMAND=$1
shift
case "$COMMAND" in
  bootstrap) exec "$PY" tools/agent/bootstrap.py "$@" ;;
  check) exec "$PY" tools/agent/check_changed.py "$@" ;;
  status) exec "$PY" tools/agent/check_changed.py --status "$@" ;;
  test-harness)
    [ "$#" -eq 0 ] || { echo "test-harness takes no arguments" >&2; exit 2; }
    "$PY" tools/check_harness.py
    "$PY" -m unittest discover -s tools/agent/tests
    exec "$PY" -m unittest discover -s tools/agent_hooks/tests
    ;;
  guard)
    [ "$#" -eq 0 ] || { echo "guard reads its request from stdin and takes no arguments" >&2; exit 2; }
    exec "$PY" tools/agent_hooks/guard.py
    ;;
  *) echo "Unknown command: $COMMAND (bootstrap, check, status, test-harness, guard)" >&2; exit 2 ;;
esac
