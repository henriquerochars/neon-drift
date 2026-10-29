#!/bin/sh
# Pinned Godot launcher. Order: $GODOT_BIN, project-local .tools/, /Applications, PATH.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -n "${GODOT_BIN:-}" ]; then
  BIN="$GODOT_BIN"
elif [ -x "$ROOT/.tools/Godot.app/Contents/MacOS/Godot" ]; then
  BIN="$ROOT/.tools/Godot.app/Contents/MacOS/Godot"
elif [ -x "$ROOT/.tools/godot" ]; then
  BIN="$ROOT/.tools/godot"
elif [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
  BIN=/Applications/Godot.app/Contents/MacOS/Godot
elif command -v godot >/dev/null 2>&1; then
  BIN=$(command -v godot)
else
  echo "Godot 4 not found. Run tools/setup_godot.sh or set GODOT_BIN." >&2
  exit 1
fi
exec "$BIN" --path "$ROOT" "$@"
