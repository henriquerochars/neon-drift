# Changed-scope validation

Decisions: ADR 0007 D05/D11/D19, D12, D20, G1. Interface: [contracts](contracts.md#gate-toolsagentcheck_changedpy).

## Run

```sh
tools/agent.sh check                     # baseline: merge base with local origin/main
tools/agent.sh check --base main         # explicit baseline
tools/agent.sh check --force             # ignore a matching passing receipt
tools/agent.sh check --retry             # rerun after a recorded failure
tools/agent.sh status                    # current pass | current fail | stale | none
tools/agent.sh check --status --json     # the receipt itself
```

The gate never fetches. If `origin/main` is missing or old, run `git fetch origin main`
yourself or pass `--base`. It reports the baseline it used.

## What is checked

The changed set is the branch diff against the baseline plus staged, unstaged and
untracked files (renames and deletions included). Regenerable state (`.godot/`,
`artifacts/`, `build/`, `.venv/`, `.tools/`, `.neondrift/`) is ignored.

| Changed paths | Checks |
|---|---|
| prose outside `docs/` (`README.md`, `CHANGELOG.md`, `LICENSE*`, other `*.md`) | none (a pass receipt with no steps) |
| `docs/**` (except `docs/AGENTS.md`) | `record` |
| GDScript, scenes, resources, `src/`, `tests/`, `data/`, `project.godot` | `lint`, `godot-tests` |
| `data/balance/*.csv` | + `balance` (importer `--check`) |
| `art/`, `tools/art/` | + `art` (`tools/art/validate.py`) |
| harness: `tools/agent*`, `.claude/`, `.grok/`, `.agents/`, `AGENTS.md`, `CLAUDE.md`, `docs/AGENTS.md` | `harness` |
| toolchain: `tools/*.sh`, `.github/`, `export_presets.cfg`, `addons/`, `tools/playtest/`, `tools/data/` | everything |
| anything unrecognised | everything |

`godot-tests` is `tools/test.sh`: headless import plus every gdUnit4 suite, failing on
engine errors in the log even when the exit code is 0. Builds and exports are not part of
the gate; CI builds on `v*` tags.

`record` is `python3 tools/agent/check_record.py`. It fails when a folder under `src/` (each
feature folder of `src/gameplay/` and `src/ui/`, and every other layer) is not named in
[`docs/STATUS.md`](../STATUS.md), when a top-level doc or `docs/` folder is not linked from
[`docs/README.md`](../README.md), when an ADR is not in its index, or when a local link in
those pages is broken. `tools/lint.sh` runs the same script, so every code change and CI
check it too.

## Record advisory

When `src/` or `data/` (except `data/balance/`) changed and `docs/STATUS.md` did not, the
gate prints one `record:` line after the scope and adds it to `advisories` in `--json`
output. It never selects a check and never fails the gate: a refactor or a bug fix may leave
the map untouched. Before calling a PR ready, either update the page (feature map, or the
"In flight" row) or say in the PR why it did not need a change.

## Receipts

Receipts live in `.neondrift/gate/`. A receipt is bound to the content and mode of every
changed file, the baseline SHA, the selected checks, the toolchain (Godot, Python,
gdtoolkit, gdUnit4, project and lint configuration) and the gate's own code. A commit
hash alone certifies nothing.

- A matching passing receipt is reused; `--force` reruns.
- A failing step keeps its exit code and the receipt records the failure.
- Editing files while the gate runs makes the run `stale` (exit 3); rerun it.
- A missing prerequisite (engine, `.venv`, Pillow for art) fails with exit 4 and names the
  setup command. It is never a silent skip.
- A second identical gate in the same worktree follows the running one.

## Completion rule

Claim a feature complete or a PR ready only when `tools/agent.sh status` prints
`current pass` for the final state. Draft/WIP commits and PRs may go out with failing or
missing checks if they say so. In Claude Code the `Stop` hook prints the receipt status
when the worktree has unvalidated changes; it is a reminder, not a block.

A pass means lint is clean, the project imports, and the tests pass. It is not a playtest
(see [game verification](gamedev.md)) and not hosted CI.
