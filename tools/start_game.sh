#!/bin/sh
# Play Neon Drift (latest origin/main by default) in a browser through a Cloudflare quick tunnel (skill: start-game).
#   tools/start_game.sh [start] [--from main|current] [--rebuild | --no-build] [--restart] [--port N] [--cloudflared PATH]
#   tools/start_game.sh status | stop | install-cloudflared
# Details and exit codes: tools/start_game.py.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "${NEONDRIFT_PYTHON:-python3}" "$ROOT/tools/start_game.py" "$@"
