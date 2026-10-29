# Neon Drift — repository guidance

Canonical instruction set for every coding agent. `CLAUDE.md` only points here. Procedures
live in [`docs/ai/`](docs/ai/README.md); roles in [`docs/AGENTS.md`](docs/AGENTS.md); the
plan in [`docs/PLAN.md`](docs/PLAN.md); design in [`docs/GDD.md`](docs/GDD.md).

Arcade pseudo-3D racer in the spirit of Game Boy Advance racers: 320x180 pixel art,
behind-the-car camera, synthwave 80s world. Five cars, garage tuning with parts and paint,
nitro, air-thruster jumps (landing on a car hurts both), online rooms with one host and up
to 8 players. Godot 4.7.2, GDScript only. Targets Windows, Web (automated playtest) and
Android. Open source: MIT (code) + CC-BY 4.0 (art).

Talk to the human in pt-BR. Code, commits, file names, comments and technical docs in English.

## Stack (non-negotiable)
- Godot 4.7.2 stable. Binary in `.tools/godot` (not committed; symlink to the Pawsphemy
  checkout on this machine). Always launch through `tools/godot.sh` (`GODOT_BIN` overrides).
- GDScript only, fully statically typed; `untyped_declaration` is an error.
- Compatibility renderer. Viewport 320x180, stretch `viewport`, scale mode `integer`,
  texture filter `Nearest`, 2D snapping on.
- Networking: Godot high-level multiplayer over `ENetMultiplayerPeer` (ADR 0002).
- Content as typed `Resource` `.tres` under `data/`; global tunables in `data/balance/physics.csv`.
- Tests: gdUnit4 (`addons/gdUnit4`), headless through `tools/test.sh`; the runner also fails on
  `SCRIPT ERROR` / `ERROR:` in the engine log.
- Art: generated with the PixelLab MCP (`tools/art/import_pixellab.py` records provenance).
- Audio: generated deterministically by `tools/audio/gen_audio.py` (standard library + ffmpeg).

## Architecture rules
1. Every race participant is a `CarState` stepped by `CarSim`; the scene never owns physics.
2. Host decides race results, finish order and crush verdicts. Each peer owns its own car.
3. Data-driven: no car, part or track hardcoded. New content = new `.tres` + sprite.
4. `src/net/**` is owned by `net-engineer` only. Everyone else uses `NetSession` and `RaceSync`
   (`docs/NET_API.md`). No `@rpc`, `multiplayer.*`, `MultiplayerSpawner` or
   `MultiplayerSynchronizer` outside `src/net/`.
5. Every feature ships with a headless test. No test, no merge.
6. Input only through `DriverInputSource` subclasses in `src/gameplay/input/` and the UI's
   built-in focus navigation. No `Input.*`, `_input()` or `_unhandled_input()` elsewhere.
7. Layer graph: `gameplay -> net -> core`, `gameplay -> data -> core`, `ui -> gameplay`,
   `audio -> core`. `tools/check_layers.py` enforces it. No cycles.
8. Static typing everywhere. No string node paths outside the owning scene (`@export` or
   `%UniqueName`). No magic numbers in GDScript: constants, `.tres` or `physics.csv`.
   Autoloads only the ones in `docs/ARCHITECTURE.md`.

## Art rules
- Cars 64x64 (8 directions from PixelLab, north = rear view used in the race), scenery
  sprites up to 96px, backgrounds 400x112 panoramas, UI panels 9-sliced.
- Synthwave palette: dark navy, purple, hot pink, cyan, orange sunset; 1px dark outline on
  sprites, none on backgrounds. `art/LICENSE` is CC-BY 4.0; provenance in `art/source/`.

## Engine files
- Commit `*.import` and `*.uid`. Never commit or hand-edit `.godot/`.
- Agents never open the editor GUI. Network tests bind port 0.

## Work and verification
1. `tools/agent.sh bootstrap` prepares a worktree (engine link, `.venv`, import).
2. Inspect before editing; stage explicit paths, never `git add .`; never bare `git stash`.
3. `tools/agent.sh check` validates the changed scope and writes a receipt.
4. Claim completion only with a current passing receipt (`tools/agent.sh status`).
5. Anything a player sees or feels also ships with runtime evidence from `tools/playtest/`.
6. The human owns taste. Report what changed, why, the verification and limitations.

## Safety and authorization
- Implementation, tests, local commits and branch pushes are authorized without routine
  confirmation; releases, tags and store uploads need explicit authorization.
- Never read keystores, `export_credentials.cfg`, `.env*`, SSH or GitHub CLI configuration.
- Raw destructive commands are blocked by the shared guard (`tools/agent.sh guard`).
- Editing harness files (`AGENTS.md`, `CLAUDE.md`, `.claude/`, `.agents/`,
  `tools/agent_hooks/`, `.github/workflows/`) needs explicit harness authorization.

## Agents
Role contracts: `.claude/agents/<role>.md` (`model: inherit`). The orchestrator delegates one
goal + acceptance criterion + allowed folders per task; lanes run in parallel with exclusive
file ownership. `qa-playtester` never fixes. See `docs/AGENTS.md`.

## Commands
```
tools/agent.sh bootstrap | check | status | test-harness | guard
tools/godot.sh --headless --import        # regenerate imports
tools/lint.sh                              # gdformat --check, gdlint, layer checker
tools/test.sh [res://tests/unit/x ...]     # headless gdUnit4
tools/build.sh windows|web|android
tools/doctor.sh [test|windows|web|android]
```

## Project layout
```
src/core src/data src/net src/audio src/gameplay/<feature> src/ui/<screen>
data/cars data/parts data/tracks data/balance   art/   audio/   tests/unit tests/integration
tools/agent tools/agent_hooks tools/art tools/audio tools/data tools/playtest
docs/ .agents/skills .claude/agents .claude/skills .tools .neondrift
```
