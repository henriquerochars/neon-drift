#!/usr/bin/env bash
# Reports the toolchain and exits non-zero if the requested target misses something.
#   tools/doctor.sh            tests (godot, python, gdtoolkit via tools/lint.sh venv)
#   tools/doctor.sh windows|web|android|all   also checks templates (+ JDK and Android SDK)
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET="${1:-test}"
VERSION=4.7.2
FAIL=0

ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=1; }
# need <required:0|1> <ok message> <missing message>; reads status in $?
report() { local req="$1" okmsg="$2" badmsg="$3" rc="$4"
  if [ "$rc" -eq 0 ]; then ok "$okmsg"; elif [ "$req" = 1 ]; then bad "$badmsg"; else warn "$badmsg"; fi; }

need_templates=0; need_android=0
case "$TARGET" in
  test) ;;
  windows|web) need_templates=1 ;;
  android) need_templates=1; need_android=1 ;;
  all) need_templates=1; need_android=1 ;;
  *) echo "Usage: $0 [test|windows|web|android|all]" >&2; exit 2 ;;
esac

echo "Neon Drift doctor (target: $TARGET)"

# Godot
GV=$("$ROOT/tools/godot.sh" --version 2>/dev/null | tail -n1)
case "$GV" in
  "$VERSION".stable*) ok "Godot $GV" ;;
  "") bad "Godot not found. Run tools/setup_godot.sh or set GODOT_BIN" ;;
  *) bad "Godot is '$GV', need $VERSION.stable (tools/setup_godot.sh)" ;;
esac

# Export templates
case "$(uname -s)" in
  Darwin) TD="$HOME/Library/Application Support/Godot/export_templates/$VERSION.stable" ;;
  *) TD="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$VERSION.stable" ;;
esac
[ -f "$TD/version.txt" ] && grep -qx "$VERSION.stable" "$TD/version.txt"
report "$need_templates" "Export templates $VERSION in $TD" \
  "Export templates $VERSION missing (tools/setup_godot.sh templates)" $?
check_template() {
  if [ -s "$TD/$1" ]; then ok "Template: $1"
  else bad "Template missing or empty: $TD/$1 (tools/setup_godot.sh templates)"; fi
}
case "$TARGET" in
  windows|all) check_template windows_release_x86_64.exe ;;
esac
case "$TARGET" in
  web|all) check_template web_nothreads_release.zip ;;
esac
case "$TARGET" in
  android|all) check_template android_source.zip ;;
esac

# Python
if command -v python3 >/dev/null 2>&1; then ok "$(python3 --version)"; else bad "python3 missing"; fi

# gdtoolkit (lint only; the venv is created by tools/lint.sh)
if [ -x "$ROOT/.venv/bin/gdlint" ]; then ok "gdtoolkit $("$ROOT/.venv/bin/gdlint" --version 2>&1 | tail -n1) (.venv)"
elif command -v gdlint >/dev/null 2>&1; then ok "gdtoolkit $(gdlint --version 2>&1 | tail -n1) (PATH)"
else warn "gdtoolkit not installed (tools/lint.sh creates .venv)"; fi

# ffmpeg (GIF capture only)
if command -v ffmpeg >/dev/null 2>&1; then ok "ffmpeg $(ffmpeg -version 2>&1 | head -n1 | cut -d' ' -f3)"
else warn "ffmpeg missing (only needed for GIF capture)"; fi

# JDK 17 (Android)
JV=""
JAVA=java
[ -z "${JAVA_HOME:-}" ] || JAVA="$JAVA_HOME/bin/java"
if "$JAVA" -version >/dev/null 2>&1; then JV=$("$JAVA" -version 2>&1 | head -n1); fi
[[ "$JV" =~ version\ \"17[\".] ]]
report "$need_android" "JDK: $JV" "JDK 17 missing or wrong version (set JAVA_HOME; found '${JV:-none}')" $?
if [ "$need_android" = 1 ]; then
  for java_tool in javac keytool; do
    if [ -n "${JAVA_HOME:-}" ]; then [ -x "$JAVA_HOME/bin/$java_tool" ]; else command -v "$java_tool" >/dev/null 2>&1; fi
    report 1 "JDK tool: $java_tool" "JDK tool missing: $java_tool (set JAVA_HOME to a full JDK 17)" $?
  done
fi

# Android SDK
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$SDK" ] && [ -d "$SDK" ]
report "$need_android" "Android SDK: $SDK" \
  "Android SDK missing (set ANDROID_HOME)" $?
if [ "$need_android" = 1 ]; then
  for sdk_file in platform-tools/adb build-tools/36.1.0/aapt2 build-tools/36.1.0/apksigner build-tools/36.1.0/zipalign platforms/android-36/android.jar; do
    [ -n "$SDK" ] && [ -s "$SDK/$sdk_file" ]
    report 1 "Android SDK file: $sdk_file" "Android SDK missing: $sdk_file (sdkmanager 'platform-tools' 'build-tools;36.1.0' 'platforms;android-36')" $?
  done
fi

# Android signing (optional)
if [ "$need_android" = 1 ]; then
  if [ -n "${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:-}" ]; then
    [ -s "$GODOT_ANDROID_KEYSTORE_RELEASE_PATH" ] && [ -n "${GODOT_ANDROID_KEYSTORE_RELEASE_USER:-}" ] && [ -n "${GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD:-}" ]
    report 1 "Release keystore configured" "Release signing requires an existing keystore, key alias and password" $?
  else warn "No GODOT_ANDROID_KEYSTORE_RELEASE_PATH: Android builds are debug-signed"; fi
fi

if [ "$FAIL" -eq 0 ]; then echo "Result: OK"; else echo "Result: MISSING REQUIREMENTS"; fi
exit "$FAIL"
