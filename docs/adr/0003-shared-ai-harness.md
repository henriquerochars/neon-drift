# ADR 0003 — Shared AI harness adopted from Pawsphemy

Status: accepted (2026-10-29).

Decision: copy the Pawsphemy harness (bootstrap, changed-scope gate with receipts, shared
guard with the Claude Code adapter, layer checker, lint, headless test runner) and rename
its state to `.neondrift/`. Checks: harness, record, toolchain, lint, balance (CSV
validator), art (PNG validator), godot-tests. Decision numbers referenced in the code
(D02...D20) keep their meaning from Pawsphemy ADR 0007.

Orchestration: Claude Code native subagents with role contracts in `.claude/agents/`
(`model: inherit`), one lane per role with exclusive folders; the orchestrator integrates.
