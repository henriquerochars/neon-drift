# Neon Drift

@AGENTS.md

`AGENTS.md` is the canonical guidance (imported above).

Claude Code specifics:
- Role contracts live in `.claude/agents/<role>.md` (`model: inherit`); the orchestrator
  dispatches them as native subagents with exclusive folders.
- Hooks: `.claude/settings.json` routes `PreToolUse` through the shared guard
  (`tools/agent_hooks/claude.py`) and reports the gate receipt on `Stop` (advisory).
- Skills: `.claude/skills/` are relative symlinks to `.agents/skills/`.
