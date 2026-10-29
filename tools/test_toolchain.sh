#!/usr/bin/env bash
# Toolchain self-test without export templates: shell syntax of every script, the pinned engine
# version through tools/godot.sh, and the art/balance validators on the real tree.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
echo "== bash -n tools/*.sh"
for script in tools/*.sh; do bash -n "$script"; done
echo "== start-game tool"
python3 tools/test_start_game.py
echo "== python compile"
python3 -m py_compile tools/check_layers.py tools/check_harness.py tools/art/validate.py tools/data/check_balance.py tools/start_game.py
echo "== godot version"
VERSION=$(tools/godot.sh --version 2>/dev/null | tail -n1)
case "$VERSION" in
  4.7.2.stable*) echo "   $VERSION" ;;
  *) echo "FAIL: expected Godot 4.7.2.stable, got '$VERSION'" >&2; exit 1 ;;
esac
echo "== export presets"
grep -q 'name="Web"' export_presets.cfg
grep -q 'name="Windows Desktop"' export_presets.cfg
echo "toolchain OK"
