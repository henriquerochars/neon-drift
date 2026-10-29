# Shared skills

Canonical copies live here; `.claude/skills/` holds relative symlinks (`tools/check_harness.py`
verifies them). `neon-gate` runs the validation gate; `neon-evidence` captures runtime evidence.
`start-game` builds the latest `main` for the Web and shares it through a Cloudflare quick tunnel
(`tools/start_game.sh`).
