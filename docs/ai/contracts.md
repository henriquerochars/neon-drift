# Shared harness contracts

Status: implementation contract for [ADR 0007](../adr/0007-shared-ai-harness.md).
Actual verification is recorded in [the execution record](implementation.md).

All harness code is POSIX shell or Python 3.9+ using only the standard library. No new
runtime dependency. Every Python module starts with `from __future__ import annotations`
and is typed. Tests use `unittest` and run with
`python3 -m unittest discover -s tools/agent/tests` and
`python3 -m unittest discover -s tools/agent_hooks/tests`, on temporary fixtures, never
on the real worktree state.

Import layout: `tools/` is the import root. `tools/agent/`, `tools/agent/lib/` and
`tools/agent_hooks/` are packages (`__init__.py`). Entry scripts and test modules insert
`<repo>/tools` at the front of `sys.path` and import `agent.lib.worktree`,
`agent_hooks.policy` and so on. Test files are named `test_*.py`.

## Ownership

| Owner | Files |
|---|---|
| Bootstrap (PR-B) | `tools/agent/bootstrap.py`, `tools/agent/lib/worktree.py`, `tools/agent/lib/jobs.py`, `tools/agent/tests/test_bootstrap.py`, `test_worktree.py`, `test_jobs.py` |
| Gate (PR-C) | `tools/agent/check_changed.py`, `tools/agent/lib/selection.py`, `fingerprint.py`, `receipt.py`, `tools/agent/tests/test_selection.py`, `test_fingerprint.py`, `test_receipt.py`, `test_gate.py` |
| Guard (PR-D) | `tools/agent_hooks/**` |
| Coordinator | `tools/agent.sh`, `tools/agent/__init__.py`, `tools/agent/lib/__init__.py`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`, `docs/**`, `.claude/settings.json`, `.agents/`, skills, CI, `tools/check_harness.py` |

The gate may import `worktree.py` and `jobs.py` from PR-B through the interfaces below. If
PR-B is not merged yet, PR-C codes against these signatures and the coordinator integrates.

## Worktree and state (`tools/agent/lib/worktree.py`)

```python
@dataclass(frozen=True)
class Worktree:
    root: Path        # git rev-parse --show-toplevel, resolved
    git_dir: Path     # git rev-parse --absolute-git-dir
    common_dir: Path  # git rev-parse --git-common-dir, resolved
    primary_root: Path  # common_dir.parent when common_dir ends in ".git", else root
    is_primary: bool
    id: str           # first 12 hex chars of sha256(str(git_dir))
    state_dir: Path   # root / ".neondrift"

def get_worktree(cwd: Path | None = None) -> Worktree
def ensure_state_dir(worktree: Worktree) -> Path
```

`ensure_state_dir` creates `.neondrift/` with mode `0o700` and an empty `.gdignore` inside
(so Godot never imports it). `.neondrift/` is git-ignored.

## Jobs and locks (`tools/agent/lib/jobs.py`)

```python
@dataclass
class JobResult:
    exit_code: int
    reused: bool      # a matching completed success was reused
    followed: bool    # a matching running job was followed instead of duplicated
    log_path: Path

def run_job(worktree: Worktree, name: str, fingerprint: str,
            runner: Callable[[Callable[[str], None]], int],
            *, retry: bool = False, reuse_success: bool = True,
            poll_seconds: float = 0.5) -> JobResult
```

State lives in `.neondrift/jobs/<name>/`: `lock.json` (`pid`, `started_at`, `fingerprint`,
`host`), `status.json` (`fingerprint`, `exit_code`, `finished_at`), `<name>.log`. The runner
receives a `log(text)` callback that appends to the log and echoes to stdout.

- Matching running job (same fingerprint, owner PID alive): wait for it and return its
  outcome with `followed=True`.
- Running job with a different fingerprint: return exit code `75` ("busy") with a clear
  message; never steal it.
- Lock whose owner PID is dead: reclaim it and log that it was reclaimed. No timeout-based
  stealing.
- Completed failure with the same fingerprint: return the recorded failure unless `retry`.
- Completed success with the same fingerprint and `reuse_success`: return `reused=True`.

## Bootstrap (`tools/agent/bootstrap.py`)

CLI: `tools/agent.sh bootstrap [--retry] [--skip-import]`. Steps, each logged:

1. Resolve the worktree. Create the state directory.
2. Engine: if `GODOT_BIN` is set, use it. Else if `<root>/.tools` is missing and the
   primary checkout has `.tools/`, create the symlink `<root>/.tools -> <primary>/.tools`.
   Never copy or download. Then require `tools/godot.sh --version` to start with `4.7.2.stable`;
   otherwise fail with "run tools/setup_godot.sh in the primary checkout or set GODOT_BIN".
3. Lint venv: if `.venv/bin/gdlint` is missing, create `.venv` and install
   `tools/requirements-lint.txt` (this mirrors `tools/lint.sh`; it is project-local, not a
   host install).
4. Import cache: unless `--skip-import`, run `tools/godot.sh --headless --import` with the
   same engine-error scan as `tools/test.sh` (log under `.neondrift/jobs/bootstrap/`).
5. Never start the game, never touch other worktrees, never modify tracked files.

The job fingerprint covers: engine version string, `tools/requirements-lint.txt` hash,
`project.godot` hash and the list of `*.import` files with their hashes. Exit `0` on success.

## Gate (`tools/agent/check_changed.py`)

CLI: `tools/agent.sh check [--base REF] [--force] [--retry] [--status] [--json] [--quiet]`. `--quiet` prints only the one-line status.

- Baseline: `git merge-base HEAD <base>` where base defaults to `origin/main`. Print the
  baseline ref and SHA. Missing ref: exit `2` with a message suggesting `git fetch origin main`
  or `--base`. Never fetch.
- Changed set: `git diff --name-status -z <mergebase>` (working tree vs baseline, covering
  committed, staged and unstaged changes, including deletions and renames) plus
  `git ls-files --others --exclude-standard -z`. Ignore `.godot/`, `.neondrift/`, `.tools/`,
  `.venv/`, `artifacts/`, `build/`, `reports/`, `*.log`, `.DS_Store`.

### Selection (`tools/agent/lib/selection.py`)

```python
CHECK_ORDER = ("harness", "record", "toolchain", "lint", "balance", "art", "godot-tests")
def select_checks(paths: Iterable[str]) -> list[str]   # ordered by CHECK_ORDER
def record_advisory(paths: Iterable[str]) -> str | None  # advisory only, never a check
```

Rules are the D12 table in ADR 0007. Commands per check:

| Check | Command |
|---|---|
| `harness` | `python3 tools/check_harness.py`, then the two `unittest discover` commands above |
| `record` | `python3 tools/agent/check_record.py` (also run by `tools/lint.sh`) |
| `toolchain` | `bash tools/test_toolchain.sh` |
| `lint` | `tools/lint.sh` |
| `balance` | `tools/godot.sh --headless --script res://tools/data/import_balance.gd -- --check` with the engine-error scan |
| `art` | `.venv/bin/python tools/art/validate.py` (requires `tools/art/requirements.txt` in `.venv`; missing → prerequisite failure, not a silent skip) |
| `godot-tests` | `tools/test.sh` |

### Fingerprint (`tools/agent/lib/fingerprint.py`)

```python
def source_fingerprint(root: Path, paths: Iterable[str]) -> str
def environment_fingerprint(root: Path) -> dict[str, str]
def gate_fingerprint(baseline_sha: str, source: str, env: dict[str, str], checks: list[str]) -> str
```

Source: sorted `(path, mode, sha256(content) | "deleted")`. Environment: Godot version
string, `python3 --version`, hashes of `tools/requirements-lint.txt`,
`tools/art/requirements.txt`, `addons/gdUnit4/plugin.cfg`, `project.godot`, `.gdlintrc`,
`export_presets.cfg`, and the gate code itself (`tools/agent/**`). No environment variable
values, no secrets.

### Receipt (`tools/agent/lib/receipt.py`)

Stored at `.neondrift/gate/receipts/<fingerprint>.json` and `.neondrift/gate/latest.json`:
`version`, `fingerprint`, `baseline_ref`, `baseline_sha`, `head_sha`, `checks`,
`steps: [{check, exit_code, seconds, log}]`, `status: pass|fail|stale`, `finished_at`.

- Snapshot the source fingerprint before and after running checks. If it changed, write
  `status: stale` and exit `3`.
- Reuse a `pass` receipt whose fingerprint matches unless `--force`. Reuse prints "reused".
- `--status` recomputes the fingerprint, prints `current pass`, `current fail`, `stale` or
  `none`, and exits `0` only for `current pass`. `--json` prints the receipt.
- Empty check selection (docs-only) yields a `pass` receipt with no steps.
- Use `run_job(worktree, "gate", fingerprint, ...)` so a concurrent identical gate follows.
- Exit codes: `0` pass, `1` a check failed, `2` usage/baseline error, `3` stale, `4`
  missing prerequisite, `75` busy.

## Guard (`tools/agent_hooks/`)

```
tools/agent_hooks/policy.py   pure: evaluate(request: dict) -> Decision
tools/agent_hooks/guard.py    CLI: one JSON request on stdin -> one JSON response on stdout
tools/agent_hooks/claude.py   Claude Code adapter: PreToolUse and Stop events
```

Request (version 1):

```json
{"version": 1, "root": "/abs/worktree", "cwd": "/abs/cwd",
 "operation": {"kind": "shell", "text": "git push origin main"}}
```

`operation.kind` is `shell` (`text`), `read` (`paths`), `write` (`paths`) or `mcp`
(`name`). Response: `{"version": 1, "decision": "allow|deny|approval-required",
"reason": "<stable-code>", "message": "<fixed safe text>"}`. Messages never echo the request.

Guard exit codes: `0` allow, `1` deny, `2` approval-required, `3` invalid request, `4`
internal error. Malformed JSON, unknown version or kind, and exceptions deny.

Reason codes (stable): `safe`, `secret-read`, `env-dump`, `destructive-command`,
`force-push`, `shared-stash`, `publication`, `policy-file-write`, `sensitive-file-write`,
`outside-root-write`, `invalid-request`, `policy-error`.

Shell analysis is conservative: split on `;`, `&&`, `||`, `|`, `&`, newlines and command
substitution boundaries, tokenise each segment with `shlex` (unbalanced quotes deny), strip
leading `env VAR=...`, `sudo`, `command`, `nice`, `time`, `xargs`. Every segment is
classified; the most severe outcome wins (`deny` > `approval-required` > `allow`).
`bash -c`/`sh -c`/`zsh -c` and `eval` bodies are classified recursively.

Rules (ADR 0007 D07, D08, D09, D15, D16):

- **Secret read** (`deny`, read operations and shell reads such as `cat`, `less`, `head`,
  `tail`, `grep`, `rg`, `cp`, `base64`, `xxd`, `strings`, `open`): `*.keystore`, `*.jks`,
  `*.p12`, `*.pem`, `*.key`, `export_credentials.cfg`, `.env` and `.env.*` (except
  `.env.example`), `~/.ssh/`, `~/.aws/`, `~/.config/gh/`, `~/.netrc`, `~/.git-credentials`,
  `config.vdf` and `ssfn*` (Steam), `~/.claude.json`, any path segment named `secrets`,
  `credentials` or containing `pixellab` plus `key`/`token`.
- **Env dump** (`deny`): `env`/`printenv` with no command operand, `export -p`, `set`
  with no arguments, `declare -x`, reading `/proc/*/environ`.
- **Destructive** (`deny`): ADR D08 list. `rm -r`/`-rf`/`-fr`/`--recursive` targeting `/`,
  `~`, `$HOME`, `.`, `..`, `*`, the worktree root, `.git`, `.tools`, `src`, `data`, `art`,
  `tests`, `addons`, `docs`, `tools` (relative to the worktree root, after resolving `cwd`).
  `git reset --hard`, `git clean` with `-f`, `git checkout -- .`/`git checkout .`,
  `git restore .`/`git restore --source`, `git branch -D main`, `git update-ref -d`,
  `git worktree remove --force`, `git filter-branch`, `git push --delete`.
- **Force push** (`deny`): `git push` with `-f`, `--force`, `--force-with-lease`, or a
  `+refspec`.
- **Shared stash** (`deny`): `git stash` with no subcommand, `pop`, `drop`, `clear`.
  `git stash push -m <tag>`, `list`, `show`, `apply` are allowed.
- **Publication** (`approval-required`): `gh pr merge|close|ready|review|comment|edit`,
  `gh issue create|close|comment|edit`, `gh release *` (except `list`/`view`), `gh repo create|edit|delete`,
  `gh workflow run`, `gh api` with `-X`/`--method` other than `GET` or with `-f`/`-F`/`--input`,
  `butler push`, `steamcmd`, `git tag` pushed via `git push --tags`.
  Ordinary branch pushes and `gh pr create` are allowed; provider permissions still apply.
- **Policy file write** (`approval-required`, write operations and shell writes such as
  `>`/`>>` redirects, `tee`, `mv`, `cp` destination, `sed -i`, `rm`): `AGENTS.md`,
  `CLAUDE.md`, `.claude/`, `.grok/`, `.agents/`, `tools/agent_hooks/`, `.github/workflows/`,
  `.gitattributes`.
- **Sensitive file write** (`approval-required`): secret paths above.
- **Outside-root write** (`approval-required`): write operations outside the worktree
  root, except `/tmp`, `$TMPDIR` and `/private/tmp`.
- Everything else: `allow` (ADR D09 deviation).

Claude adapter (`tools/agent_hooks/claude.py`):

- `PreToolUse`: maps `Bash` → shell, `Read`/`Grep`/`Glob` (`file_path`/`path`) → read,
  `Edit`/`MultiEdit`/`Write`/`NotebookEdit` → write. Uses the event's `cwd` and
  `CLAUDE_PROJECT_DIR` (or `git rev-parse --show-toplevel` from `cwd`) as root. `deny` →
  `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
  "permissionDecisionReason": "<message>"}}`; `approval-required` → same with `"ask"`;
  `allow` → no output, exit 0 (the native permission system still applies). Any adapter
  error → `deny`.
- `Stop`: runs `check_changed.py --status --quiet` with a 20 s bound. If the result is not
  `current pass` and the worktree has relevant changes, prints a `systemMessage` stating the
  receipt status. Never blocks (ADR D20: advisory).
