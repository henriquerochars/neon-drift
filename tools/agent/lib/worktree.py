"""Worktree identity and per-worktree harness state (ADR 0007 D04/D10, docs/ai/contracts.md)."""

from __future__ import annotations

import hashlib
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

STATE_DIR_NAME = ".neondrift"
STATE_DIR_MODE = 0o700
TOOLS_DIR_NAME = ".tools"
WORKTREE_ID_LENGTH = 12

# Outcomes of link_primary_tools (stable strings, safe to print).
LINK_CREATED = "created"
LINK_EXISTS = "exists"
LINK_PRIMARY = "primary"
LINK_NO_SOURCE = "no-source"


class WorktreeError(RuntimeError):
    """Raised when the current directory is not inside a usable git worktree."""


@dataclass(frozen=True)
class Worktree:
    root: Path  # git rev-parse --show-toplevel, resolved
    git_dir: Path  # git rev-parse --absolute-git-dir, resolved
    common_dir: Path  # git rev-parse --git-common-dir, resolved
    primary_root: Path  # common_dir.parent when common_dir ends in ".git", else root
    is_primary: bool
    id: str  # first 12 hex chars of sha256(str(git_dir))
    state_dir: Path  # root / ".neondrift"


def _git(cwd: Path, *args: str) -> str:
    try:
        proc = subprocess.run(
            ["git", *args],
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise WorktreeError("git is not installed or not on PATH") from exc
    if proc.returncode != 0:
        raise WorktreeError(f"not inside a git worktree: {cwd} (git {' '.join(args)} failed)")
    return proc.stdout.strip()


def get_worktree(cwd: Optional[Path] = None) -> Worktree:
    """Resolve the git worktree containing ``cwd`` (default: the process cwd)."""
    base = Path(cwd if cwd is not None else os.getcwd()).resolve()
    root = Path(_git(base, "rev-parse", "--show-toplevel")).resolve()
    git_dir = Path(_git(base, "rev-parse", "--absolute-git-dir")).resolve()
    common_raw = Path(_git(base, "rev-parse", "--git-common-dir"))
    # --git-common-dir may be relative to the directory git ran in.
    common_dir = (common_raw if common_raw.is_absolute() else base / common_raw).resolve()
    primary_root = common_dir.parent if common_dir.name == ".git" else root
    is_primary = git_dir == common_dir
    worktree_id = hashlib.sha256(str(git_dir).encode("utf-8")).hexdigest()[:WORKTREE_ID_LENGTH]
    return Worktree(
        root=root,
        git_dir=git_dir,
        common_dir=common_dir,
        primary_root=primary_root,
        is_primary=is_primary,
        id=worktree_id,
        state_dir=root / STATE_DIR_NAME,
    )


def ensure_state_dir(worktree: Worktree) -> Path:
    """Create ``.neondrift/`` (mode 0700) with an empty ``.gdignore``; return its path."""
    state = worktree.state_dir
    state.mkdir(mode=STATE_DIR_MODE, parents=False, exist_ok=True)
    # mkdir honours the umask; force the documented mode.
    os.chmod(state, STATE_DIR_MODE)
    gdignore = state / ".gdignore"
    if not gdignore.exists():
        gdignore.touch()
    return state


def link_primary_tools(worktree: Worktree) -> str:
    """Link ``<root>/.tools`` to the primary checkout's ``.tools/`` when it is missing.

    Never overwrites an existing ``.tools`` (file, directory or symlink, even a broken one),
    never copies and never downloads. Returns one of the ``LINK_*`` outcome strings.
    """
    target = worktree.root / TOOLS_DIR_NAME
    if os.path.lexists(target):
        return LINK_EXISTS
    if worktree.is_primary or worktree.primary_root == worktree.root:
        return LINK_PRIMARY
    source = worktree.primary_root / TOOLS_DIR_NAME
    if not source.is_dir():
        return LINK_NO_SOURCE
    try:
        os.symlink(str(source), str(target), target_is_directory=True)
    except FileExistsError:
        # A concurrent bootstrap won the race; whatever is there now is kept.
        return LINK_EXISTS
    return LINK_CREATED
