#!/usr/bin/env bash
# Export a platform into build/<platform>/ using export_presets.cfg and zip where applicable.
#   tools/build.sh windows|android|web
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
PLATFORM="${1:-}"
case "$PLATFORM" in windows|android|web) ;; *) echo "Usage: $0 windows|android|web" >&2; exit 2 ;; esac
DOCTOR_TARGET="$PLATFORM"

if ! "$ROOT/tools/doctor.sh" "$DOCTOR_TARGET" >/dev/null; then
  "$ROOT/tools/doctor.sh" "$DOCTOR_TARGET" || true
  echo "build: toolchain for '$PLATFORM' is incomplete (see above)." >&2
  exit 1
fi

VERSION=$(sed -n 's/^config\/version="\(.*\)"$/\1/p' project.godot)
OUT="build/$PLATFORM"
mkdir -p artifacts
touch artifacts/.gdignore
LOG="artifacts/build-$PLATFORM.log"
rm -rf "$OUT"; mkdir -p "$OUT"

# ship_licenses <dir>: every build carries the code, art and audio licenses and the Godot notice.
ship_licenses() {
  cp "$ROOT/LICENSE" "$1/LICENSE"
  cp "$ROOT/art/LICENSE" "$1/ART_LICENSE"
  [ ! -f "$ROOT/audio/LICENSE" ] || cp "$ROOT/audio/LICENSE" "$1/AUDIO_LICENSE"
  [ ! -f "$ROOT/THIRD_PARTY_NOTICES.md" ] || cp "$ROOT/THIRD_PARTY_NOTICES.md" "$1/THIRD_PARTY_NOTICES.md"
}

export_preset() { # <preset> <path>
  # A fresh checkout (.godot/ missing) needs an unscanned warm-up import first: the project theme
  # references the font and UI panel before their first import (same as tools/test.sh).
  if [ ! -d "$ROOT/.godot/imported" ]; then
    "$ROOT/tools/godot.sh" --headless --import >"${LOG%.log}-warmup.log" 2>&1 || true
  fi
  if ! "$ROOT/tools/godot.sh" --headless --import >"$LOG" 2>&1; then
    tail -40 "$LOG" >&2
    echo "build: import failed (see $LOG)" >&2
    exit 1
  fi
  if grep -qE 'SCRIPT ERROR|ERROR:|Parse Error:' "$LOG"; then
    tail -40 "$LOG" >&2
    echo "build: engine errors during import (see $LOG)" >&2
    exit 1
  fi
  "$ROOT/tools/godot.sh" --headless --export-release "$1" "$2" >>"$LOG" 2>&1 || {
    tail -40 "$LOG" >&2
    echo "build: export failed (see $LOG)" >&2; exit 1; }
  # Read the file directly: grep -q can close a pipe early and make its producer
  # fail with SIGPIPE, hiding a matching error when pipefail is enabled.
  if grep -qE 'SCRIPT ERROR|ERROR:|Parse Error:' "$LOG"; then
    grep -m 20 -E 'SCRIPT ERROR|ERROR:|Parse Error:' "$LOG" >&2
    echo "build: engine errors during export (see $LOG)" >&2; exit 1
  fi
  [ -s "$2" ] || { echo "build: $2 was not produced" >&2; exit 1; }
}

case "$PLATFORM" in
  windows)
    export_preset "Windows Desktop" "$OUT/Neon Drift.exe"
    ZIP="neondrift-windows-x64-$VERSION.zip"
    ship_licenses "$OUT"
    ( cd "$OUT" && zip -q -j "$ZIP" Neon Drift.exe LICENSE ART_LICENSE ) ;;
  web)
    export_preset "Web" "$OUT/index.html"
    ZIP="neondrift-web-$VERSION.zip"
    ship_licenses "$OUT"
    ( cd "$OUT" && zip -q -r "$ZIP" . -x "$ZIP" ) ;;
  android)
    # Godot reads SDK locations from Editor Settings, not JAVA_HOME/ANDROID_HOME.
    # Keep the developer's other settings and retain a backup before the first update.
    python3 - <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

java_home = os.environ.get("JAVA_HOME", "")
if not java_home:
    result = subprocess.run(["java", "-XshowSettings:properties", "-version"],
                            capture_output=True, text=True, check=True)
    match = re.search(r"^\s*java.home\s*=\s*(.+)$", result.stderr, re.MULTILINE)
    if not match:
        raise SystemExit("build: cannot locate the JDK; set JAVA_HOME")
    java_home = match.group(1).strip()
sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
if not sdk:
    raise SystemExit("build: set ANDROID_HOME to the Android SDK")
if sys.platform == "darwin":
    config_dir = Path.home() / "Library/Application Support/Godot"
else:
    config_dir = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "godot"
settings = config_dir / "editor_settings-4.7.tres"
content = settings.read_text() if settings.exists() else '[gd_resource type="EditorSettings" format=3]\n\n[resource]\n'
if "[resource]\n" not in content:
    raise SystemExit(f"build: invalid Editor Settings resource: {settings}")
for key, value in {"export/android/java_sdk_path": java_home,
                   "export/android/android_sdk_path": sdk}.items():
    line = f"{key} = {json.dumps(str(Path(value).resolve()), ensure_ascii=False)}"
    pattern = re.compile(r"^" + re.escape(key) + r"\s*=.*$", re.MULTILINE)
    if pattern.search(content):
        content = pattern.sub(lambda _: line, content)
    else:
        content = content.replace("[resource]\n", "[resource]\n" + line + "\n", 1)
config_dir.mkdir(parents=True, exist_ok=True)
backup = settings.with_suffix(".tres.neondrift-backup")
if settings.exists() and not backup.exists():
    shutil.copy2(settings, backup)
with tempfile.NamedTemporaryFile(mode="w", dir=config_dir, delete=False) as temporary:
    temporary.write(content)
os.replace(temporary.name, settings)
print(f"build: configured Android SDK and JDK in {settings}")
PY
    # Gradle build template: unpack the matching android_source.zip once (what the editor menu does).
    if [ ! -f android/build/build.gradle ]; then
      case "$(uname -s)" in
        Darwin) TD="$HOME/Library/Application Support/Godot/export_templates/4.7.2.stable" ;;
        *) TD="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/4.7.2.stable" ;;
      esac
      mkdir -p android/build; unzip -q -o "$TD/android_source.zip" -d android/build
      echo "4.7.2.stable" > android/.build_version
    fi
    touch android/.gdignore
    if [ -z "${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:-}" ]; then
      KS="$ROOT/.tools/debug.keystore"
      if [ ! -f "$KS" ]; then
        mkdir -p "$ROOT/.tools"
        KEYTOOL=keytool
        [ -z "${JAVA_HOME:-}" ] || KEYTOOL="$JAVA_HOME/bin/keytool"
        "$KEYTOOL" -genkeypair -keystore "$KS" -alias androiddebugkey -keyalg RSA -keysize 2048 \
          -validity 10000 -storepass android -keypass android \
          -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
      fi
      export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KS"
      export GODOT_ANDROID_KEYSTORE_RELEASE_USER=androiddebugkey
      export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=android
      echo "build: no release keystore configured, signing with the debug keystore"
    fi
    export_preset "Android" "$OUT/neondrift-$VERSION.aab" ;;
esac
echo "build: OK"; ls -la "$OUT"
