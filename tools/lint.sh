#!/usr/bin/env bash
# gdformat --check, gdlint, the layer checker and the project record check. Creates .venv with pinned gdtoolkit if missing.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
if [ ! -x .venv/bin/gdlint ]; then
  echo "Creating .venv with tools/requirements-lint.txt"
  python3 -m venv .venv
  .venv/bin/pip install --quiet --disable-pip-version-check -r tools/requirements-lint.txt
fi
echo "== gdformat --check"; .venv/bin/gdformat --check src tests tools
echo "== gdlint";           .venv/bin/gdlint src tests tools
echo "== check_layers";     python3 tools/check_layers.py
echo "== check_record";     python3 tools/agent/check_record.py
echo "Lint OK"
