# Full playtest — 2026-10-29

## Environment and scope

Production commit `4d6aadc`, branch `qa/full-playtest-2026-10-29`, exclusively
`/home/user/neon-drift-qa`. Godot `4.7.2.stable.official.ed1daf0bf`, Linux,
Compatibility renderer under Xvfb; headless gdUnit4; ffmpeg palettegen/paletteuse,
15 fps looping GIFs. No production code changed. Visual seed 7; screen fixture seed
271029; metrics seeds 1, 2, 3. Manifest records commit, seeds and image hashes.

## Verification

- Initial import completed successfully through `tools/godot.sh --headless --import`.
- `tools/lint.sh`: `Lint OK`, layer check OK, record check PASS.
- Full `tools/test.sh`: 69 cases, 0 errors, 3 assertion failures in the two deliberate
  bug tests below; `FAILED`. Shutdown additionally logged `ERROR: 4 resources still
  in use at exit`. This was absent when excluding the failing regression suite.
- Acceptance-only run: `tools/test.sh res://tests/unit res://tests/integration
  res://tests/qa/profile_flow_qa_test.gd`: 67 cases, 0 errors/failures/skips/orphans,
  `PASS`. This is local verification, not hosted CI.
- `profile_flow_qa_test.gd`: all 18 purchases (six slots, tiers 1–3) strictly increase
  their associated physical stat and deduct exact catalog prices; eight paints wrap;
  repair restores integrity and deducts cost; profile and all settings round-trip.
- `test_solo_reaches_results_and_persists_earnings`: real App/select/launcher/race/results
  flow completes under bounded AI ticks, adds the prize and reloads the saved profile.
  All QA persistence uses `user://test-qa-*`, never writes `user://profile.json`.
- The gate is expected to be red because regression tests intentionally assert the
  corrected behavior. See `logs/gate.log` and the receipt status below.

The first test invocation cleared concurrently written `artifacts/` logs (the runner
removes that directory). Tests, metrics, online smoke and captures were repeated with
logs preserved under this evidence directory. Capture repeat images were disposable;
the reviewed original images were retained. No claim is based solely on exit code.

## Visual evidence and direct inspection

Evidence root: `docs/qa/full-playtest-2026-10-29/`. Inspected all 720 source race PNGs
and all 12 screen PNGs via contact sheets (`review-01.jpg` through `review-04.jpg`,
30 sequential frames per sheet). GIFs encode those same source frames. Each race
folder has `frame_0000.png` through `frame_0476.png` in steps of four,
`race.gif`, `mid-race.png` (tick 240), and `manifest.json`.

| Folder | What the images show |
|---|---|
| `coast-raw/` | Perspective grey road, red/white edges, beach/ocean/mountains, palms, signs, eight-car grid; red local car remains visible, jumps and lands with dust. No HUD by design. |
| `sunset_city-raw/` | Perspective road bends against a magenta skyline and large striped sun; lamps and signs advance; rival cars, cyan jump jets/orange rings, then tan landing dust. |
| `desert_night-raw/` | Dark perspective road with pale edges, moon/mountains/cacti/rocks; multiple cars and blue nitro effects, jump rings and landing dust. |
| `coast-app/` | Real HUD over beach race; speed rises from zero, lap 1/3, place changes from invalid 0TH to 1ST; thruster bar drops. A close jumping rival becomes very large and obscures the centre around ticks 400–440. |
| `sunset_city-app/` | Real HUD over city road, changing speed and thruster meter, local red car and close rival; turn develops late in capture. |
| `desert_night-app/` | Real HUD over night road; position changes through 1ST–5TH, nitro is consumed/refilled, cyan flame, jump jet/ring and dust are visible. |

Road convergence, depth scaling, moving roadside sprites and visible cars confirm an
actual pseudo-3D road, not a static background. Speed, lap, place, nitro, thrust and
hull labels/meters are readable at native 320×180, though the cyan speed has lower
contrast against the bright Coast sky. The right edge contains the progress strip.
Lap stays 1/3 because these clips cover only eight simulation seconds (three countdown,
five racing). Hull can remain full without damage; this is not evidence of a frozen HUD.
`*-app/samples.json` records changing speed, nitro, altitude and integrity.

VFX identification: cyan flame/energy near cars (nitro), vertical cyan jet with orange
ring (thruster), tan expanding puffs behind landed cars (landing dust), matching the
strips loaded by `RaceVfx`. All three are visible across the captured sequences.
Large nearby airborne rival sprites obscure the road in Coast App capture; this needs
human art/game-feel review, not a claim that perspective scaling is definitively broken.

Timers run in wall time while capture tools manually advance simulation. The long-lived
GO label in these accelerated clips is therefore not classified as a production bug.

| Screen PNG (`screens/`) | Direct observation |
|---|---|
| `title.png` | Neon Drift logo, sunset skyline and PRESS START. |
| `menu.png` | Solo/online/garage/options/quit choices and money/profile card over coastline. |
| `garage.png` | Red Vortex preview, six part rows, paint and repair; purchase feedback and stat bars. |
| `options.png` | Three volume sliders, fullscreen/vsync/FPS/window/name controls. |
| `options_controls.png` | Keyboard/gamepad mapping table and back button. |
| `select_car.png` | Vortex preview, description, paint swatch and six stat bars. |
| `select_track.png` | Coast thumbnail, description, three laps and first prize. |
| `lobby_connect.png` | Name, loopback address, port and host/join/back controls. |
| `lobby_host.png` | Ready host, seven empty seats, car/track/ready/start/leave controls. |
| `hud.png` | Synthetic fixture: 220 km/h, lap 1/3, computed standing, meters, progress strip and LAP 2 flash. |
| `pause.png` | Dimmed fixture HUD behind resume/options/quit overlay. |
| `results.png` | Fixture finish table with one DNF, 2ND, +$800 and money transition. |

HUD/pause/results screenshots from capture_screens are fixtures, not evidence that a
race ended. The separate passing App race test supplies the real completion/persistence
check.

## Seeded metrics

Eight AI cars per run; 60 physics ticks/s; finish times exclude countdown.
`race-runs.json` includes every driver's time/place/earnings. Offroad is the maximum
per-car offroad tick count, not a fleet total. All 72 entries finished; no DNF, no race
above 150 s, no finish below 30 s; crushes occurred in every run.

| Track | Seed | First–last finish (s) | Crushes | Bumps | Max offroad ticks |
|---|---:|---:|---:|---:|---:|
| coast | 1 | 63.05–79.43 | 6 | 16 | 35 |
| coast | 2 | 63.58–78.73 | 5 | 19 | 230 |
| coast | 3 | 65.80–80.12 | 5 | 21 | 85 |
| desert_night | 1 | 68.25–84.30 | 2 | 20 | 0 |
| desert_night | 2 | 67.48–84.30 | 6 | 42 | 76 |
| desert_night | 3 | 70.37–84.30 | 5 | 34 | 3 |
| sunset_city | 1 | 72.73–91.78 | 4 | 41 | 40 |
| sunset_city | 2 | 73.95–92.33 | 4 | 26 | 71 |
| sunset_city | 3 | 74.55–92.85 | 7 | 22 | 50 |

Suspicious metrics: Desert Night seed 3 has ids 2 and 5 both finishing at 72.800 s,
assigned places 2 and 3; `_check_finishes` iterates participants within a tick, so this
is consistent with tick-quantised timing and array-order tie-breaking (inference).
Id 1 finishes at 84.300 s in all three Desert seeds. Scenery hits are zero in all nine
runs. These are balance/coverage flags, not demonstrated defects. Coast seed 2 has
230 offroad ticks for its worst car (~3.83 s), noticeably above the other runs.

## Two-process online smoke

`tools/playtest/online_smoke.sh` starts separate host/client processes, uses an ephemeral
host port, waits for two ready seats, starts Coast, and asserts identical seeds and
successful bounded exits. Raw output:

```
HOST
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

SMOKE_PORT=41076
SMOKE_SEED=1474570407
SMOKE_SEATS=2
CLIENT
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

SMOKE_SEED=1474570407
SMOKE_SEATS=2

ONLINE_SMOKE_PASS
```

This proves loopback lobby admission, readiness and start-seed delivery in two OS
processes. It does not prove race-state/results replication, eight-process capacity,
or NAT connectivity. Existing integration tests cover eight-seat lobby behavior.

## Bugs (ordered by severity)

### QA-01 — P1 / High: official finish ignored after client predicts its finish

Commit `4d6aadc`, Coast seed 7. Reproduce headlessly with
`test_authoritative_finish_replaces_predicted_client_finish` in
`tests/qa/race_contract_bug_test.gd`: start a client-authority race, advance the local
car across the final lap via `step_tick`, then deliver `force_finish(local_id, 2, 70.0)`.
Expected: official place 2 and finish time 70.0 replace the provisional state.
Actual: provisional place remains 1 and finish_time remains 0.0. Both assertions fail.
`_check_finishes` sets finished locally; `_finish` returns early for a finished car
with a positive provisional place. This is a controlled replication-contract repro,
not a demonstrated complete two-machine race. Owner: race gameplay / net integration.

### QA-02 — P3 / Low: countdown displays impossible 0TH position

Commit `4d6aadc`, all three tracks seed 7. Start Solo through App/select and watch the
three-second countdown (`*-app/frame_0000.png`). Expected: grid position in 1..8
(or a deliberately hidden place); actual: visible `0TH`. The contract says place_of
is one-based, but ranking is not initialised until racing starts.
Failing test: `test_countdown_place_is_one_based` in
`tests/qa/race_contract_bug_test.gd`. Owner: race gameplay/UI integration.

### QA-03 — P3 / Low: playtest processes report live resources at shutdown

Commit `4d6aadc`, race seeds 1–3; captures seed 7 / screen fixture 271029.
Run any `race_runs.tscn` command above and scan stdout after its result JSON.
Expected: clean teardown with no engine ERROR lines. Actual: all nine metric runs
exit 0 and finish, but print `ERROR: 6/8/10 resources still in use at exit` (count
varies by track/seed); capture tools also log 4–24 live resources. No SCRIPT ERROR
was observed in the preserved runs. See `logs/` for exact per-run counts.
Root cause is not isolated; this may be tool teardown rather than gameplay failure.
No gdUnit regression added: the reproducible assertion is the external process's
shutdown log scan, after the test runner's lifecycle. Owner: playtest/gameplay resource
lifecycle. Do not call these executions engine-error-free based on exit 0.

## Limitations and handoff

No real human driving or audio listening, controller/touch acceptance, Windows/Android
export, cross-machine LAN/NAT, adverse latency or full online race through UI. No
approval of fun/art direction. UI online start beyond the lobby was optional and not
exercised. Raw versus App roster/local grid differs by design; seeds match but clips
are not frame-for-frame comparison tests. Captures only cover early racing; seeded
metrics and App acceptance cover completion.

Keep `race_contract_bug_test.gd` failing until production
fixes land. To validate unaffected behavior, use the explicit acceptance-only command
above; do not weaken harness rules. Logs include exit-time resource warnings in playtest processes and the full failing
suite; the acceptance suite is clean. No push performed.

## Gate receipt

`tools/agent.sh check` uses fallback baseline `main`, merge-base `4d6aadc12065`.
Harness, record, toolchain, lint, balance and art each exit 0; godot-tests exits 1.
Status: `gate: fail` (expected deliberate regression failures), **no current passing
receipt** and no claim that the feature is ready. Full suite: 69 cases / 3 failed
assertions across two bug cases. The 67 unaffected cases pass independently.

## Follow-up (orchestrator, same day)

All three bugs were fixed on `main` after this report: the P1 predicted-finish bug and the
shutdown audio leak in `fix/review-r1` (merged as 2d1cd82), the `0TH` countdown place by
ranking the grid before the countdown starts. `tests/qa/race_contract_bug_test.gd` became
`tests/qa/race_contract_regression_test.gd` and passes; the full suite is 78/78 and the gate
is green. Capture utilities under `tools/playtest/` may still log "resources still in use"
at exit; they are not part of the gate.
