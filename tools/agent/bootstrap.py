#!/usr/bin/env python3
"""Per-worktree setup for the shared AI harness (ADR 0007 D04/D10, D13, D14, D18).

    tools/agent.sh bootstrap [--retry] [--skip-import]

Steps (each logged): resolve the worktree and create ``.neondrift/``; link ``.tools`` from the
primary checkout when missing (unless ``GODOT_BIN`` is set) and require Godot 4.7.2; create the
project-local lint ``.venv`` when missing (mirrors ``tools/lint.sh``); run the headless import
with the same engine-error scan as ``tools/test.sh``. Never downloads the engine, never installs
host tools, never starts the game, never touches other worktrees or tracked files.

Exit codes: 0 success, 1 a step failed, 2 usage or not a git worktree, 4 missing or wrong engine,
75 another bootstrap with a different fingerprint is running.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Set

TOOLS_ROOT = Path(__file__).resolve().parents[1]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

from agent.lib.jobs import run_job  # noqa: E402
from agent.lib.worktree import (  # noqa: E402
    LINK_CREATED,
    LINK_EXISTS,
    LINK_NO_SOURCE,
    Worktree,
    WorktreeError,
    ensure_state_dir,
    get_worktree,
    link_primary_tools,
)

JOB_NAME = "bootstrap"
FINGERPRINT_VERSION = 1
ENGINE_VERSION_PREFIX = "4.7.2.stable"
ENGINE_HINT = "run tools/setup_godot.sh in the primary checkout or set GODOT_BIN"
ENGINE_VERSION_TIMEOUT = 60
DEFAULT_IMPORT_TIMEOUT = 300
MAX_REPORTED_HITS = 30

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_PREREQUISITE = 4

# Same patterns as tools/test.sh.
ERROR_RE = re.compile(r"SCRIPT ERROR|(^|[^A-Za-z_])ERROR:|Parse Error:")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

LogFn = Callable[[str], None]
VenvCreator = Callable[[Path, LogFn], int]


# ---------------------------------------------------------------------------
# Helpers


def _say(text: str, *, err: bool = False) -> None:
    stream = sys.stderr if err else sys.stdout
    stream.write(text + "\n")
    stream.flush()


def _file_hash(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError:
        return "missing"


def _import_files(root: Path) -> List[str]:
    proc = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.import"],
        cwd=str(root),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if proc.returncode != 0:
        return []
    names = {name for name in proc.stdout.decode("utf-8", "surrogateescape").split("\0") if name}
    return sorted(name for name in names if (root / name).is_file())


def _import_hashes(root: Path) -> List[List[str]]:
    return [[name, _file_hash(root / name)] for name in _import_files(root)]


def compute_fingerprint(root: Path, engine_version: str, skip_import: bool) -> str:
    payload = {
        "version": FINGERPRINT_VERSION,
        "engine": engine_version,
        "requirements_lint": _file_hash(root / "tools" / "requirements-lint.txt"),
        "project_godot": _file_hash(root / "project.godot"),
        "imports": _import_hashes(root),
        "import_step": "skipped" if skip_import else "run",
    }
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def _tracked_changes(root: Path) -> Set[str]:
    proc = subprocess.run(
        ["git", "status", "--porcelain=v1", "-z", "--untracked-files=no"],
        cwd=str(root),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if proc.returncode != 0:
        return set()
    return {e for e in proc.stdout.decode("utf-8", "surrogateescape").split("\0") if e}


def _gdlint_ready(root: Path) -> bool:
    return os.access(str(root / ".venv" / "bin" / "gdlint"), os.X_OK)


# ---------------------------------------------------------------------------
# Engine


def engine_version(root: Path) -> Optional[str]:
    """Last non-empty line of ``tools/godot.sh --version``, or None if it cannot run."""
    launcher = root / "tools" / "godot.sh"
    if not launcher.is_file():
        return None
    try:
        proc = subprocess.run(
            [str(launcher), "--version"],
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=ENGINE_VERSION_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    if proc.returncode != 0 or not lines:
        return None
    return lines[-1]


# ---------------------------------------------------------------------------
# Steps run as the job owner


def default_venv_creator(root: Path, log: LogFn) -> int:
    """Create ``.venv`` and install the pinned lint requirements (mirrors tools/lint.sh)."""
    commands = [
        [sys.executable, "-m", "venv", ".venv"],
        [
            str(root / ".venv" / "bin" / "pip"),
            "install",
            "--quiet",
            "--disable-pip-version-check",
            "-r",
            "tools/requirements-lint.txt",
        ],
    ]
    for command in commands:
        proc = subprocess.run(
            command,
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if proc.stdout.strip():
            log(proc.stdout.rstrip())
        if proc.returncode != 0:
            log(f"venv: '{' '.join(command[1:3])}' exited {proc.returncode}")
            return EXIT_FAIL
    return EXIT_OK


def _venv_step(root: Path, log: LogFn, creator: VenvCreator) -> int:
    if _gdlint_ready(root):
        log("venv: .venv/bin/gdlint present")
        return EXIT_OK
    log("venv: creating .venv with tools/requirements-lint.txt")
    code = creator(root, log)
    if code != EXIT_OK:
        log(f"venv: FAIL (exit {code})")
        return EXIT_FAIL
    if not _gdlint_ready(root):
        log("venv: FAIL, .venv/bin/gdlint is still missing after the install")
        return EXIT_FAIL
    log("venv: ready")
    return EXIT_OK


def _import_timeout() -> int:
    raw = os.environ.get("IMPORT_TIMEOUT", "")
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_IMPORT_TIMEOUT
    return value if value > 0 else DEFAULT_IMPORT_TIMEOUT


def scan_engine_errors(paths: Sequence[Path]) -> List[str]:
    hits: List[str] = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            continue
        for line in text.splitlines():
            clean = ANSI_RE.sub("", line)
            if ERROR_RE.search(clean):
                hits.append(clean)
    return hits


def _import_step(root: Path, job_dir: Path, log: LogFn) -> int:
    engine_log = job_dir / "import.log"
    stdout_log = job_dir / "import.stdout.log"
    for stale in (engine_log, stdout_log):
        if stale.exists():
            stale.unlink()
    log("import: tools/godot.sh --headless --import")
    tracked_before = _tracked_changes(root)
    imports_before = _import_hashes(root)
    timeout = _import_timeout()
    with open(stdout_log, "w", encoding="utf-8") as out:
        proc = subprocess.Popen(
            [str(root / "tools" / "godot.sh"), "--log-file", str(engine_log), "--headless", "--import"],
            cwd=str(root),
            stdin=subprocess.DEVNULL,
            stdout=out,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                proc.kill()
            proc.wait()
            out.write("TIMEOUT (IMPORT_TIMEOUT elapsed)\n")
            log(f"import: FAIL, timed out (IMPORT_TIMEOUT); see {stdout_log}")
            return EXIT_FAIL
    status = EXIT_OK
    if code != 0:
        log(f"import: FAIL, exited {code} (see {stdout_log})")
        status = EXIT_FAIL
    hits = scan_engine_errors([engine_log, stdout_log])
    if hits:
        log("import: FAIL, the import log has engine errors:")
        for hit in hits[:MAX_REPORTED_HITS]:
            log(f"  {hit}")
        status = EXIT_FAIL
    new_tracked = sorted(_tracked_changes(root) - tracked_before)
    if new_tracked:
        log("import: warning, the engine modified tracked files (review before committing):")
        for entry in new_tracked[:MAX_REPORTED_HITS]:
            log(f"  {entry}")
    if _import_hashes(root) != imports_before:
        log("import: warning, *.import files changed; commit them so the next bootstrap can reuse")
    if status == EXIT_OK:
        log("import: OK")
    return status


# ---------------------------------------------------------------------------
# Entry point


def _parse(argv: Optional[Sequence[str]]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="tools/agent.sh bootstrap",
        description="Prepare this worktree: engine link, lint venv, headless import.",
    )
    parser.add_argument("--retry", action="store_true", help="rerun after a recorded failure")
    parser.add_argument("--skip-import", action="store_true", help="skip the headless import")
    return parser.parse_args(list(argv) if argv is not None else None)


def _engine_preflight(worktree: Worktree, notes: List[str]) -> Optional[str]:
    if os.environ.get("GODOT_BIN"):
        notes.append("engine: GODOT_BIN is set; using it (no .tools link)")
    else:
        outcome = link_primary_tools(worktree)
        if outcome == LINK_CREATED:
            notes.append(f"engine: linked .tools -> {worktree.primary_root / '.tools'}")
        elif outcome == LINK_EXISTS:
            notes.append("engine: .tools already present; left untouched")
        elif outcome == LINK_NO_SOURCE:
            notes.append("engine: primary checkout has no .tools/; nothing to link")
        else:
            notes.append("engine: primary checkout; no link needed")
    for note in notes:
        _say(note)
    version = engine_version(worktree.root)
    if version is None or not version.startswith(ENGINE_VERSION_PREFIX):
        found = "nothing" if version is None else f"'{version}'"
        _say(
            f"engine: FAIL, need Godot {ENGINE_VERSION_PREFIX} from tools/godot.sh --version, "
            f"got {found}: {ENGINE_HINT}",
            err=True,
        )
        return None
    note = f"engine: Godot {version}"
    notes.append(note)
    _say(note)
    return version


def main(
    argv: Optional[Sequence[str]] = None,
    *,
    cwd: Optional[Path] = None,
    venv_creator: VenvCreator = default_venv_creator,
) -> int:
    args = _parse(argv)
    try:
        worktree = get_worktree(cwd)
    except WorktreeError as exc:
        _say(f"bootstrap: {exc}", err=True)
        return EXIT_USAGE
    state = ensure_state_dir(worktree)
    kind = "primary" if worktree.is_primary else "linked"
    notes = [f"worktree: {worktree.root} ({kind}, id {worktree.id}); state {state}"]
    version = _engine_preflight(worktree, notes)
    if version is None:
        return EXIT_PREREQUISITE

    root = worktree.root
    fingerprint = compute_fingerprint(root, version, args.skip_import)
    outputs_present = _gdlint_ready(root) and (args.skip_import or (root / ".godot").is_dir())
    job_dir = state / "jobs" / JOB_NAME

    def runner(log: LogFn) -> int:
        # The preflight notes were already printed; record them in the job log only.
        with open(job_dir / f"{JOB_NAME}.log", "a", encoding="utf-8") as handle:
            handle.writelines(f"{note}\n" for note in notes)
        log(f"fingerprint: {fingerprint}")
        if _venv_step(root, log, venv_creator) != EXIT_OK:
            return EXIT_FAIL
        if args.skip_import:
            log("import: skipped (--skip-import)")
        elif _import_step(root, job_dir, log) != EXIT_OK:
            return EXIT_FAIL
        log("bootstrap: OK")
        return EXIT_OK

    result = run_job(
        worktree,
        JOB_NAME,
        fingerprint,
        runner,
        retry=args.retry,
        reuse_success=outputs_present,
    )
    if result.exit_code != EXIT_OK:
        _say(f"bootstrap: FAILED with exit {result.exit_code} (log: {result.log_path})", err=True)
    elif result.reused:
        _say(f"bootstrap: OK (reused; log: {result.log_path})")
    elif result.followed:
        _say(f"bootstrap: OK (followed a concurrent run; log: {result.log_path})")
    return result.exit_code


if __name__ == "__main__":
    sys.exit(main())
