# Project record

Updated by the orchestrator after each integration. Paths are the feature map the record
check (`tools/agent/check_record.py`) verifies.

## Feature map
- `src/core/` — autoload buses, contracts (`CarState`, `CarStats`, `DriverInput`), constants.
- `src/data/` — resource definitions and balance CSV loader.
- `src/net/` — NetSession, RaceSync, lobby resources.
- `src/audio/` — AudioDirector autoload and SFX bank.
- `src/gameplay/input/` — driver input sources (local, scripted).
- `src/gameplay/sim/` — CarSim and TrackModel (pure simulation).
- `src/gameplay/road/` — pseudo-3D road renderer.
- `src/gameplay/race/` — race scene, manager, participants.
- `src/gameplay/ai/` — AI drivers.
- `src/ui/app/` — main scene and screen router.
- `src/ui/title/`, `src/ui/menu/`, `src/ui/options/`, `src/ui/garage/`, `src/ui/select/`,
  `src/ui/lobby/`, `src/ui/hud/`, `src/ui/results/`, `src/ui/pause/` — screens.

## Review R1 fixes
- `fix/review-r1`: authoritative results and finish confirmation, countdown resync,
  signed bump payloads, crush feedback relay, finish interpolation and post-finish
  contact/coast handling; disconnect recovery, profile refresh and fresh solo retries.
- Regression suite: 73 tests; three consecutive clean full runs after explicit audio
  teardown (baseline: 64 tests passed but all three runs leaked four resources).
- Local evidence: `build/review-r1/screens/` (12 UI captures, fixture seed 271029) and
  `build/review-r1/race-seed-3.json` (coast, eight finishers, seed 3, 4988 ticks).
  Capture tools produced images/metrics but still report shutdown resource leaks;
  they are not part of the clean gdUnit runs. Network tests use local ENet, not internet.
  Visual fixtures do not demonstrate real two-machine online play.

## Integrated QA
- Phase 3 evidence: `docs/qa/full-playtest-2026-10-29.md` contains 12 screens,
  6 race GIFs, 9 seeded races and a two-process loopback lobby/start smoke.
- Review R1 fixes and countdown ranking regression are integrated. The final local
  suite passes 78 gdUnit tests; harness suites pass 193 tests.
- Captures predate the final fixes. Capture-tool shutdown warnings remain a known
  limitation; neither eight-machine internet play nor exported builds are verified.

## In flight
- Initial delivery PR: `feat/neon-drift` against the new repository's `main`.
  The branch preserves the integrated game as a snapshot; original development
  history remains on local `main` at `215f0e7`.
- Remaining scope: NAT traversal / join codes (join is address:port), Windows/Android/Web
  export verification, touch virtual stick, driver portraits, curve-speed balance,
  capture-tool audio cleanup and human assessment of game feel.
