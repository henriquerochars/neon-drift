# Neon Drift — delivery plan

Working title chosen for the project: **Neon Drift** (the reference game's name is not used).
Reference material: the 80s pseudo-3D racer video (behind-the-car OutRun/Top Gear camera,
garage with a rotating car and purchasable parts, world map, rival list, sunset/beach/night
palettes, coin rewards) and the Super Indie Karts store page (pixel-art kart racer with
multiplayer). Both are design lessons only; no asset or name is copied.

## Pillars
1. Game Boy Advance feel: 320x180 integer-scaled pixel art, nearest filtering, chunky UI.
2. Pseudo-3D road (segment projection), behind-the-car camera, curves and hills.
3. Five cars with distinct stats, tuning through parts, paint customisation.
4. Nitro (burst of speed) and air thrusters (jump over cars; landing on a car hurts both).
5. Online rooms up to 8 players, one host, ENet high-level multiplayer.
6. Menu, options, chiptune soundtrack and SFX, all art generated with PixelLab.

## Phases
| Phase | Owner | Output |
|---|---|---|
| 0 Skeleton | orchestrator (architect role) | repo, harness, `project.godot`, core contracts, data resources, docs |
| 1 Lanes (parallel) | gameplay-dev ×2, net-engineer, audio-designer | road renderer + race, UI flow, NetSession + RaceSync, soundtrack/SFX |
| 1 Art (parallel) | pixel-artist (orchestrator with PixelLab MCP) | cars (8 directions), scenery, backgrounds, UI, font, VFX |
| 2 Integration | orchestrator | wire lanes, imports, gate, fixes |
| 3 QA | qa-playtester | headless suite, scripted race metrics, screenshots/GIF evidence |

## Lane briefs (one goal, one acceptance test, exclusive folders)
- **L1 Race core** (`src/gameplay/road`, `src/gameplay/race`, `src/gameplay/ai`,
  `tests/*/race`): pseudo-3D renderer over `TrackModel`, `RaceScene` that runs `CarSim`
  for every participant, AI drivers, landing/crush detection, HUD data; acceptance:
  a seeded 8-car solo race finishes with a deterministic result table.
- **L2 Networking** (`src/net`, `tests/*/net`): `NetSession` lobby (host/join, 8 seats,
  ready, car choice), `RaceSync` replication of `CarState`, host-authoritative race
  events; acceptance: host + client on port 0 exchange lobby state and a race countdown.
- **L3 UI** (`src/ui`, `tests/*/ui`): title, main menu, options, garage/tuning, car and
  track select, online lobby, HUD, pause, results; acceptance: a scripted walk through
  every screen without errors and the options round-trip through `GameSettings`.
- **L4 Audio** (`tools/audio`, `audio/`, `src/audio`, `tests/*/audio`): deterministic
  Python synth for 3 tracks + jingle + 12 SFX, `AudioDirector` autoload mapped to
  `RaceBus`; acceptance: generator is reproducible and every manifest entry loads.

## Definition of done
- `tools/agent.sh check` passes (lint, layer graph, headless gdUnit4 suite, balance, art,
  harness) with a current receipt.
- Runtime evidence under `docs/qa/`: screenshots of each screen and a GIF of a race.
- Solo race against 7 AI cars on 3 tracks, garage purchases persist, options persist,
  host/join lobby works on LAN, 8 seats.
