# Setup and local state

Decisions: ADR 0007 D04/D10, D13, D14, D18. Interface: [contracts](contracts.md#bootstrap-toolsagentbootstrappy).

## Bootstrap a worktree

```sh
tools/agent.sh bootstrap            # engine link, .venv, headless import
tools/agent.sh bootstrap --skip-import
tools/agent.sh bootstrap --retry    # rerun after a recorded failure
```

What it does, in order:

1. Creates `.neondrift/` (mode 0700, with `.gdignore` so Godot never imports it).
2. Finds the engine. `GODOT_BIN` wins. In a linked worktree without `.tools/`, it symlinks
   `.tools` to the primary checkout's `.tools/` (the pinned Godot.app, Android SDK, JDK).
   It never downloads. A missing or wrong engine fails with the next step to take:
   `tools/setup_godot.sh` in the primary checkout, or `GODOT_BIN`.
3. Creates `.venv` with the pinned gdtoolkit if missing (the same thing `tools/lint.sh`
   does on first use).
4. Runs `tools/godot.sh --headless --import` and fails on engine errors in its log.

It never starts the game, never edits tracked files and never touches another worktree.
A second identical run reuses the recorded success. A concurrent identical run waits for
the first and returns its result. A job whose owner process died is reclaimed and the log
says so; a live owner keeps its lock however long it runs.

Optional extras the gate asks for when relevant:

```sh
.venv/bin/pip install -r tools/art/requirements.txt   # art validation (Pillow)
tools/setup_godot.sh templates                         # export templates for builds
```

## Local state

| Path | Owner | Safe to delete |
|---|---|---|
| `.godot/` | Godot import cache | yes, regenerate with bootstrap |
| `artifacts/` | `tools/test.sh` logs and reports | yes |
| `build/` | `tools/build.sh` exports | yes |
| `.venv/` | lint and art Python tools | yes, bootstrap recreates it |
| `.neondrift/` | harness locks, logs, receipts | yes; receipts are lost |
| `.tools` (linked worktree) | symlink to the primary checkout | remove the link, never `rm -rf` through it |

Uncommitted work, other worktrees and the shared git stash are never touched by harness
commands.

## Recovery

- "busy" (exit 75): another job with different inputs is running in this worktree. Wait
  for it or stop its process; the lock names its PID.
- A recorded failure: fix the cause, then `--retry`.
- Wrong engine version: `tools/godot.sh --version` must print `4.7.2.stable...`.
