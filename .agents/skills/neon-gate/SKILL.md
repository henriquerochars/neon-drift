---
name: neon-gate
description: Run Neon Drift's changed-scope validation gate and report its receipt. Use before claiming a feature complete, after integrating a lane, or when the user asks whether the current changes pass.
---

1. If `tools/agent.sh status` cannot find the engine or `.venv`, run `tools/agent.sh bootstrap`.
2. Run `tools/agent.sh check` (pass `--base <ref>` only if the user named a baseline).
3. Report baseline, selected checks, each step's exit code, the final status line and the
   receipt path under `.neondrift/gate/`.
4. On failure quote the first failing lines and name the owner role (`docs/AGENTS.md`).
5. A pass proves lint, import and tests; visual or feel changes still need `neon-evidence`.
