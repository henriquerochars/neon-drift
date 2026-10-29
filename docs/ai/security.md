# Shared safety boundaries

Decisions: ADR 0007 D02, D07, D08, D09, D15, D16. Interface:
[contracts](contracts.md#guard-toolsagent_hooks). The classifier lives in
`tools/agent_hooks/policy.py`. The CLI is `tools/agent.sh guard`.

## Threat model

The guard protects cooperative coding agents from accidents on documented tool paths:
reading signing material, dumping the environment, wiping the worktree, force-pushing,
and restricted publication or editing policy files without a native approval. It is a denylist plus
an approval list. Unknown local commands are allowed (ADR 0007 D09). It is not a sandbox
and does not contain a hostile program.

Malformed input, an internal error and an adapter failure all deny. A field in the
request that claims approval is not approval. The provider's own permission system still
applies after an allow.

## Outcomes

| Decision | Exit | Meaning |
|---|---|---|
| `allow` | 0 | Recognized as safe, or not on the denylist |
| `deny` | 1 | Prohibited on the supported path |
| `approval-required` | 2 | The provider must ask the human |
| invalid request | 3 | Bad JSON, unknown version or kind |
| internal error | 4 | The classifier raised or returned garbage |

Messages are fixed strings. They never echo the command or the path.

## Rules

Stable reason codes: `safe`, `secret-read`, `env-dump`, `destructive-command`,
`force-push`, `shared-stash`, `publication`, `policy-file-write`,
`sensitive-file-write`, `outside-root-write`, `invalid-request`, `policy-error`.

- **Secrets.** Reads of keystores, `.env` (except `.env.example`), `export_credentials.cfg`,
  SSH, AWS and `gh` config, Steam `config.vdf` / `ssfn*`, and paths whose segments are
  `secrets`, `credentials` or a PixelLab key/token name are denied. Writes to those paths
  ask. `tools/build.sh` may load signing material internally; reading the file is still denied.
- **Environment dumps.** Bare `env`, `printenv`, `export -p`, `set`, `declare -x` and
  `/proc/*/environ` are denied.
- **Destruction.** Recursive delete of `/`, `$HOME`, the worktree root, `.git`, `.tools`,
  `src`, `data`, `art`, `tests`, `addons`, `docs` or `tools` is denied. So are
  `git reset --hard`, `git clean -f`, `git checkout .`, `git restore .`,
  `git branch -D main`, `git push --delete` and `git worktree remove --force`.
  Deleting `.godot/`, `artifacts/` and `build/` is allowed.
- **Force push.** `git push` with `-f`, `--force`, `--force-with-lease` or a `+refspec` is denied.
- **Shared stash.** Bare `git stash`, `pop`, `drop` and `clear` are denied. `push -m`,
  `list`, `show` and `apply` are allowed. The stash ref is shared by every worktree.
- **Publication.** Ordinary branch pushes and `gh pr create` are allowed. Tag pushes,
  other mutating `gh` commands, `butler push` and `steamcmd` ask. Provider permissions still apply.
- **Policy edits.** Writes to `AGENTS.md`, `CLAUDE.md`, `.claude/`, `.grok/`, `.agents/`,
  `tools/agent_hooks/` and `.github/workflows/` ask. A gameplay task does not authorize them.

Shell text is split on operators, quotes and command substitutions. Unbalanced quotes deny.
`bash -c` bodies are classified again. The most severe segment wins.

## Adapters

| Provider | What is enforced | What is only an instruction |
|---|---|---|
| Claude Code | `PreToolUse` on Bash, Read, Grep, Glob, Edit, MultiEdit, Write, NotebookEdit, via `.claude/settings.json`. Deny blocks. Approval asks. | Tools the matcher does not list |
| Claude Code `Stop` | Prints the gate status when it is not `current pass` | Never blocks the turn (ADR D20) |
| Grok, Codex, T3 | none verified | `AGENTS.md` safety section |

An unsupported hook must not be described as enforced. Native allow rules are not an
exemption from this guard on the paths it covers.

## Limits

- The shell grammar is one literal command with a small set of operators. It is not a shell.
- `realpath` follows symlinks. It does not detect hard links.
- A process that does not go through the adapter is outside this boundary.
- Receipts and logs must not contain secret values. The guard does not scan their contents.
