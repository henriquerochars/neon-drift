"""Owned, deduplicated setup jobs (ADR 0007 D12/D14, docs/ai/contracts.md "Jobs and locks").

State per job lives in ``.neondrift/jobs/<name>/``:

- ``lock.json``   owner of the running job: ``pid``, ``started_at``, ``fingerprint``, ``host``,
                  plus ``process_start`` (the owner's start identity from ``ps``) and ``token``.
- ``status.json`` last completed run: ``fingerprint``, ``exit_code``, ``finished_at``, ``token``.
- ``<name>.log``  log of the last run started by an owner.

Mutual exclusion: every decision (inspect, reclaim, create, release) happens while holding an
``flock`` on ``.guard`` in the job directory, and ``lock.json`` is published with an atomic
``os.link`` that fails if it already exists. The guard is held only for the decision, never for
the job itself, and the kernel drops it if the holder dies, so it cannot go stale.

Ownership: a lock whose owner PID is alive (``os.kill(pid, 0)``; ``PermissionError`` counts as
alive) and whose recorded process start identity still matches is kept regardless of age. A
dead or recycled owner's lock is reclaimed and the reclaim is logged. There is no timeout-based
stealing. A lock written on another host is never reclaimed.
"""

from __future__ import annotations

import fcntl
import json
import os
import socket
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, Optional

from agent.lib.worktree import Worktree, ensure_state_dir

EXIT_BUSY = 75
EXIT_RUNNER_CRASHED = 1
JOB_FILE_MODE = 0o600
JOB_DIR_MODE = 0o700

LogFn = Callable[[str], None]
Runner = Callable[[LogFn], int]


@dataclass
class JobResult:
    exit_code: int
    reused: bool  # a matching completed success was reused
    followed: bool  # a matching running job was followed instead of duplicated
    log_path: Path


# ---------------------------------------------------------------------------
# Process identity


_OWN_START: Optional[str] = None
_OWN_START_KNOWN = False


def process_start_identity(pid: int) -> Optional[str]:
    """Return the start time of ``pid`` as reported by ``ps -o lstart=``, or None."""
    try:
        proc = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env={"LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")},
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    value = " ".join(proc.stdout.split())
    if proc.returncode != 0 or not value:
        return None
    return value


def _own_start_identity() -> Optional[str]:
    global _OWN_START, _OWN_START_KNOWN
    if not _OWN_START_KNOWN:
        _OWN_START = process_start_identity(os.getpid())
        _OWN_START_KNOWN = True
    return _OWN_START


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def owner_alive(lock: Dict[str, Any]) -> bool:
    """True when the lock's owner is still the process that took it."""
    host = lock.get("host")
    if isinstance(host, str) and host and host != socket.gethostname():
        # Cannot check a process on another host: never reclaim.
        return True
    pid = lock.get("pid")
    if not isinstance(pid, int) or isinstance(pid, bool):
        return False
    if not pid_alive(pid):
        return False
    recorded = lock.get("process_start")
    if isinstance(recorded, str) and recorded:
        current = process_start_identity(pid)
        if current is not None and current != recorded:
            return False  # PID recycled by an unrelated process
    return True


# ---------------------------------------------------------------------------
# Small file helpers


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _read_json(path: Path) -> Optional[Dict[str, Any]]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_tmp(directory: Path, prefix: str, data: Dict[str, Any]) -> Path:
    tmp = directory / f".{prefix}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, JOB_FILE_MODE)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    return tmp


def _write_json_atomic(path: Path, data: Dict[str, Any]) -> None:
    tmp = _write_tmp(path.parent, path.name, data)
    os.replace(str(tmp), str(path))


def _create_exclusive(path: Path, data: Dict[str, Any]) -> bool:
    """Publish ``data`` at ``path`` only if ``path`` does not exist (atomic link)."""
    tmp = _write_tmp(path.parent, path.name, data)
    try:
        os.link(str(tmp), str(path))
    except FileExistsError:
        return False
    finally:
        os.unlink(str(tmp))
    return True


def _describe(lock: Dict[str, Any]) -> str:
    return f"pid {lock.get('pid')}, started {lock.get('started_at')}"


# ---------------------------------------------------------------------------
# Job


class _Job:
    def __init__(self, worktree: Worktree, name: str) -> None:
        if not name or "/" in name or name.startswith("."):
            raise ValueError(f"invalid job name: {name!r}")
        state = ensure_state_dir(worktree)
        jobs_dir = state / "jobs"
        jobs_dir.mkdir(mode=JOB_DIR_MODE, exist_ok=True)
        self.name = name
        self.dir = jobs_dir / name
        self.dir.mkdir(mode=JOB_DIR_MODE, exist_ok=True)
        self.lock_path = self.dir / "lock.json"
        self.status_path = self.dir / "status.json"
        self.log_path = self.dir / f"{name}.log"
        self.guard_path = self.dir / ".guard"

    @contextmanager
    def guard(self) -> Iterator[None]:
        fd = os.open(str(self.guard_path), os.O_RDWR | os.O_CREAT, JOB_FILE_MODE)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


def _say(text: str, *, err: bool = False) -> None:
    stream = sys.stderr if err else sys.stdout
    stream.write(text if text.endswith("\n") else text + "\n")
    stream.flush()


def _make_logger(log_path: Path) -> Callable[[str], None]:
    def log(text: str) -> None:
        line = text if text.endswith("\n") else text + "\n"
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(line)
        sys.stdout.write(line)
        sys.stdout.flush()

    return log


class _Follow:
    """Echo a running owner's log to stdout while waiting."""

    def __init__(self, log_path: Path) -> None:
        self.log_path = log_path
        self.offset = 0

    def pump(self) -> None:
        try:
            with open(self.log_path, "r", encoding="utf-8", errors="replace") as handle:
                handle.seek(self.offset)
                chunk = handle.read()
                self.offset = handle.tell()
        except FileNotFoundError:
            return
        if chunk:
            sys.stdout.write(chunk)
            sys.stdout.flush()


def run_job(
    worktree: Worktree,
    name: str,
    fingerprint: str,
    runner: Callable[[Callable[[str], None]], int],
    *,
    retry: bool = False,
    reuse_success: bool = True,
    poll_seconds: float = 0.5,
) -> JobResult:
    """Run ``runner`` as the single owner of job ``name``, or follow/reuse/refuse.

    See the module docstring and docs/ai/contracts.md for the exact rules.
    """
    job = _Job(worktree, name)
    while True:
        reclaimed: Optional[Dict[str, Any]] = None
        follow: Optional[Dict[str, Any]] = None
        mine: Dict[str, Any] = {}
        with job.guard():
            lock = _read_json(job.lock_path)
            if lock is not None:
                if owner_alive(lock):
                    if lock.get("fingerprint") != fingerprint:
                        _say(
                            f"{name}: busy, another run with a different fingerprint is in "
                            f"progress ({_describe(lock)}). Wait for it to finish, then rerun.",
                            err=True,
                        )
                        return JobResult(EXIT_BUSY, False, False, job.log_path)
                    follow = lock
                else:
                    os.unlink(str(job.lock_path))
                    reclaimed = lock
            if follow is None:
                status = _read_json(job.status_path)
                if status and status.get("fingerprint") == fingerprint:
                    code = status.get("exit_code")
                    finished = status.get("finished_at")
                    if isinstance(code, int) and not isinstance(code, bool):
                        if code == 0 and reuse_success:
                            if reclaimed is not None:
                                _say(f"{name}: reclaimed lock of dead owner ({_describe(reclaimed)})")
                            _say(f"{name}: reused, succeeded at {finished} with the same fingerprint")
                            return JobResult(0, True, False, job.log_path)
                        if code != 0 and not retry:
                            if reclaimed is not None:
                                _say(f"{name}: reclaimed lock of dead owner ({_describe(reclaimed)})")
                            _say(
                                f"{name}: previous run with the same fingerprint failed with exit "
                                f"{code} at {finished} (log: {job.log_path}). Fix the cause and "
                                "rerun with --retry.",
                                err=True,
                            )
                            return JobResult(code, False, False, job.log_path)
                mine = {
                    "pid": os.getpid(),
                    "started_at": _now(),
                    "fingerprint": fingerprint,
                    "host": socket.gethostname(),
                    "process_start": _own_start_identity(),
                    "token": uuid.uuid4().hex,
                }
                if not _create_exclusive(job.lock_path, mine):
                    continue  # cannot happen under the guard; re-evaluate defensively
                with open(job.log_path, "w", encoding="utf-8"):
                    pass
        if follow is None:
            return _own(job, mine, runner, reclaimed)
        result = _follow(job, follow, fingerprint, poll_seconds)
        if result is not None:
            return result
        # The owner vanished without a status: start over (reclaim, reuse or run).


def _own(
    job: _Job,
    mine: Dict[str, Any],
    runner: Callable[[Callable[[str], None]], int],
    reclaimed: Optional[Dict[str, Any]],
) -> JobResult:
    log = _make_logger(job.log_path)
    completed = False
    exit_code = EXIT_RUNNER_CRASHED
    try:
        if reclaimed is not None:
            log(f"{job.name}: reclaimed lock of dead owner ({_describe(reclaimed)})")
        try:
            raw = runner(log)
            exit_code = int(raw) if isinstance(raw, int) and not isinstance(raw, bool) else 1
        except Exception as exc:  # the runner's failure becomes a recorded failure
            log(f"{job.name}: runner raised {type(exc).__name__}: {exc}")
            exit_code = EXIT_RUNNER_CRASHED
        completed = True
    finally:
        with job.guard():
            if completed:
                _write_json_atomic(
                    job.status_path,
                    {
                        "fingerprint": mine["fingerprint"],
                        "exit_code": exit_code,
                        "finished_at": _now(),
                        "token": mine["token"],
                    },
                )
            current = _read_json(job.lock_path)
            if current and current.get("token") == mine["token"]:
                os.unlink(str(job.lock_path))
    return JobResult(exit_code, False, False, job.log_path)


def _follow(
    job: _Job, owner: Dict[str, Any], fingerprint: str, poll_seconds: float
) -> Optional[JobResult]:
    _say(f"{job.name}: following the running job with the same fingerprint ({_describe(owner)})")
    tail = _Follow(job.log_path)
    token = owner.get("token")
    while True:
        tail.pump()
        lock = _read_json(job.lock_path)
        if lock is None or lock.get("token") != token:
            break
        if not owner_alive(lock):
            break
        time.sleep(poll_seconds)
    tail.pump()
    status = _read_json(job.status_path)
    if status and status.get("token") == token and status.get("fingerprint") == fingerprint:
        code = status.get("exit_code")
        if isinstance(code, int) and not isinstance(code, bool):
            _say(f"{job.name}: followed run finished with exit {code}")
            return JobResult(code, False, True, job.log_path)
    _say(f"{job.name}: the followed owner stopped without a result; re-evaluating")
    return None
