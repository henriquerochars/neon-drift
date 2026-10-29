#!/usr/bin/env bash
# Idempotent installer for the pinned Godot editor and export templates.
#   tools/setup_godot.sh            editor (if missing) + templates (if missing)
#   tools/setup_godot.sh editor     editor only
#   tools/setup_godot.sh templates  templates only
# Env: GODOT_TEMPLATES=all  extract every template (default: windows x64, web, android only)
#      GODOT_DL_CACHE=dir   keep downloads there (default .tools/dl, deleted after success)
# Linux: the editor is installed as .tools/godot, found automatically by tools/godot.sh.
set -euo pipefail

VERSION=4.7.2
TAG="${VERSION}-stable"
BASE="https://github.com/godotengine/godot/releases/download/${TAG}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS="$ROOT/.tools"
DL="${GODOT_DL_CACHE:-$TOOLS/dl}"
WHAT="${1:-all}"

case "$(uname -s)" in
  Darwin)
    EDITOR_ZIP="Godot_v${VERSION}-stable_macos.universal.zip"
    TEMPLATES_DIR="$HOME/Library/Application Support/Godot/export_templates/${VERSION}.stable"
    EDITOR_BIN="$TOOLS/Godot.app/Contents/MacOS/Godot" ;;
  Linux)
    EDITOR_ZIP="Godot_v${VERSION}-stable_linux.x86_64.zip"
    TEMPLATES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/${VERSION}.stable"
    EDITOR_BIN="$TOOLS/godot" ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
TEMPLATES_TPZ="Godot_v${VERSION}-stable_export_templates.tpz"

mkdir -p "$TOOLS" "$DL"
PROGRESS=--silent; [ -t 1 ] && PROGRESS=--progress-bar

sha512_of() {
  if command -v sha512sum >/dev/null 2>&1; then sha512sum "$1" | cut -d' ' -f1
  else shasum -a 512 "$1" | cut -d' ' -f1; fi
}

# fetch <file>: download into $DL and verify against the release's SHA512-SUMS.txt.
fetch() {
  local file="$1"
  [ -s "$DL/SHA512-SUMS.txt" ] || curl --fail --silent --show-error --location --retry 3 \
    "$BASE/SHA512-SUMS.txt" --output "$DL/SHA512-SUMS.txt"
  local want
  want=$(grep " ${file}\$" "$DL/SHA512-SUMS.txt" | cut -d' ' -f1)
  [ -n "$want" ] || { echo "No checksum for $file" >&2; exit 1; }
  if [ -f "$DL/$file" ] && [ "$(sha512_of "$DL/$file")" = "$want" ]; then
    echo "Using cached $file"
  else
    echo "Downloading $file"
    curl --fail --show-error --location --retry 3 $PROGRESS "$BASE/$file" --output "$DL/$file"
    [ "$(sha512_of "$DL/$file")" = "$want" ] || { echo "Checksum mismatch: $file" >&2; exit 1; }
  fi
}

install_editor() {
  if [ -x "$EDITOR_BIN" ]; then
    local installed
    installed=$(GODOT_BIN="$EDITOR_BIN" "$ROOT/tools/godot.sh" --version 2>/dev/null || true)
    case "$installed" in
      "$VERSION.stable."*) echo "Editor present: $EDITOR_BIN ($installed)"; return ;;
      *) echo "Replacing editor '$installed' with pinned $VERSION.stable" ;;
    esac
  fi
  fetch "$EDITOR_ZIP"
  local tmp="$DL/editor_extract"
  rm -rf "$tmp"; mkdir -p "$tmp"
  unzip -q "$DL/$EDITOR_ZIP" -d "$tmp"
  if [ "$(uname -s)" = Darwin ]; then
    rm -rf "$TOOLS/Godot.app"; mv "$tmp/Godot.app" "$TOOLS/Godot.app"
  else
    mv "$tmp/Godot_v${VERSION}-stable_linux.x86_64" "$EDITOR_BIN"; chmod +x "$EDITOR_BIN"
  fi
  rm -rf "$tmp" "$DL/$EDITOR_ZIP"
  echo "Installed editor: $EDITOR_BIN ($(GODOT_BIN="$EDITOR_BIN" "$ROOT/tools/godot.sh" --version))"
}

install_templates() {
  local complete=1 template
  for template in windows_debug_x86_64.exe windows_release_x86_64.exe web_nothreads_debug.zip web_nothreads_release.zip android_source.zip android_debug.apk android_release.apk; do
    [ -s "$TEMPLATES_DIR/$template" ] || complete=0
  done
  if [ "${GODOT_TEMPLATES:-}" = all ] && [ ! -f "$TEMPLATES_DIR/.neondrift_all" ]; then complete=0; fi
  if [ -f "$TEMPLATES_DIR/version.txt" ] && [ "$(cat "$TEMPLATES_DIR/version.txt")" = "${VERSION}.stable" ] \
     && [ "$complete" = 1 ]; then
    echo "Templates present: $TEMPLATES_DIR"
    return
  fi
  fetch "$TEMPLATES_TPZ"
  local tmp="$DL/templates_extract"
  rm -rf "$tmp"; mkdir -p "$tmp" "$TEMPLATES_DIR"
  if [ "${GODOT_TEMPLATES:-}" = all ]; then
    unzip -q -o "$DL/$TEMPLATES_TPZ" -d "$tmp"
  else
    unzip -q -o "$DL/$TEMPLATES_TPZ" 'templates/windows_*_x86_64*' 'templates/web_*' \
      'templates/android_*' 'templates/version.txt' 'templates/icudt_godot.dat' -d "$tmp"
  fi
  cp -R "$tmp"/templates/. "$TEMPLATES_DIR"/
  touch "$TEMPLATES_DIR/.neondrift_ok"
  if [ "${GODOT_TEMPLATES:-}" = all ]; then touch "$TEMPLATES_DIR/.neondrift_all"; fi
  rm -rf "$tmp" "$DL/$TEMPLATES_TPZ"
  echo "Installed templates into $TEMPLATES_DIR (version $(cat "$TEMPLATES_DIR/version.txt"))"
}

case "$WHAT" in
  all) install_editor; install_templates ;;
  editor) install_editor ;;
  templates) install_templates ;;
  *) echo "Usage: $0 [all|editor|templates]" >&2; exit 2 ;;
esac

if [ "$(uname -s)" = Linux ] && [ -x "$EDITOR_BIN" ]; then
  echo "Set GODOT_BIN=$EDITOR_BIN"
  [ -n "${GITHUB_ENV:-}" ] && echo "GODOT_BIN=$EDITOR_BIN" >> "$GITHUB_ENV"
fi
exit 0
