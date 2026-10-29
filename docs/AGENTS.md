# Roles and orchestration

Orchestrator: the main Claude Code session. It plans, writes the skeleton, delegates lanes
to native subagents, generates art through the PixelLab MCP, integrates, runs the gate and
keeps `docs/STATUS.md`.

| Role | Owns | Model |
|---|---|---|
| architect | `src/core`, `src/data`, `project.godot`, docs/adr | inherit |
| gameplay-dev | one feature folder under `src/gameplay` or `src/ui` per task | inherit |
| net-engineer | `src/net` | inherit |
| pixel-artist | `art/`, `tools/art` (PixelLab MCP) | inherit |
| audio-designer | `audio/`, `tools/audio`, `src/audio` | inherit |
| game-designer | `docs/GDD.md`, `data/balance` | inherit |
| qa-playtester | `tests/qa`, `docs/qa`, `tools/playtest` | inherit |
| release-engineer | `tools/*.sh`, `export_presets.cfg`, `.github` | inherit |

Model policy (2026-10-29, human decision): every delegated task runs on Codex **GPT-6-Astra,
reasoning high** through T3 `delegate_task` (`.agents/model_routing.json`). The role files keep
`model: inherit` for native compatibility only; do not start Claude subagents unless the human
asks again. Phase 1 lanes (race, net, ui, audio) ran before the switch as Claude subagents.

Phase progression: 0 skeleton → 1 lanes (parallel) → 2 integration → 3 QA → release.
