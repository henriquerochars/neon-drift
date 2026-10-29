"""Gate fingerprints (ADR 0007 D05/D11/D19, docs/ai/contracts.md "Fingerprint").

The source fingerprint covers only the changed files (path, mode, content hash). The
environment fingerprint covers the toolchain pins and the gate's own code. Neither reads
environment variable values.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path
from typing import Iterable

GODOT_LAUNCHER = "tools/godot.sh"
ENVIRONMENT_FILES: tuple[str, ...] = (
    "tools/requirements-lint.txt",
    "tools/art/requirements.txt",
    "addons/gdUnit4/plugin.cfg",
    "project.godot",
    ".gdlintrc",
    "export_presets.cfg",
)
GATE_CODE_DIR = "tools/agent"
GATE_CODE_SKIP_DIRS: frozenset[str] = frozenset(("__pycache__",))
GATE_CODE_SKIP_SUFFIXES: tuple[str, ...] = (".pyc", ".pyo")
MISSING = "missing"
DELETED = "deleted"
PROBE_TIMEOUT_SECONDS = 15.0


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_entry(root: Path, relative: str) -> tuple[str, str, str]:
    """``(path, mode, digest)``; a missing path is ``("", "deleted")``.

    Symlinks hash their target text instead of following it.
    """
    full = root / relative
    try:
        info = os.lstat(full)
    except FileNotFoundError:
        return (relative, "", DELETED)
    mode = f"{stat.S_IFMT(info.st_mode) | stat.S_IMODE(info.st_mode):06o}"
    if stat.S_ISLNK(info.st_mode):
        return (relative, mode, sha256_bytes(os.readlink(full).encode("utf-8")))
    if stat.S_ISDIR(info.st_mode):
        return (relative, mode, sha256_bytes(b""))
    return (relative, mode, sha256_file(full))


def source_fingerprint(root: Path, paths: Iterable[str]) -> str:
    """sha256 over sorted ``(path, mode, sha256(content) | "deleted")`` entries."""
    entries = sorted(file_entry(root, path) for path in set(paths))
    return sha256_bytes(json.dumps(entries, separators=(",", ":")).encode("utf-8"))


def _run_probe(argv: list[str], cwd: Path) -> str:
    try:
        result = subprocess.run(
            argv,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            check=False,
            timeout=PROBE_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return MISSING
    if result.returncode != 0:
        return MISSING
    first = (result.stdout or result.stderr).strip().splitlines()
    return first[0].strip() if first else MISSING


def godot_version(root: Path) -> str:
    """First line of ``tools/godot.sh --version`` or ``"missing"``."""
    launcher = root / GODOT_LAUNCHER
    if not launcher.is_file():
        return MISSING
    return _run_probe(["sh", GODOT_LAUNCHER, "--version"], root)


def python_version() -> str:
    return _run_probe(["python3", "--version"], Path.cwd())


def _hash_or_missing(path: Path) -> str:
    return sha256_file(path) if path.is_file() else MISSING


def gate_code_hash(root: Path) -> str:
    """Hash of every file under ``tools/agent/`` (relative path and content)."""
    base = root / GATE_CODE_DIR
    digest = hashlib.sha256()
    if not base.is_dir():
        return MISSING
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in GATE_CODE_SKIP_DIRS)
        for name in sorted(filenames):
            if name.endswith(GATE_CODE_SKIP_SUFFIXES):
                continue
            full = Path(dirpath) / name
            relative = full.relative_to(root).as_posix()
            digest.update(relative.encode("utf-8") + b"\0")
            digest.update(sha256_file(full).encode("ascii") + b"\0")
    return digest.hexdigest()


def environment_fingerprint(root: Path) -> dict[str, str]:
    """Toolchain identity: versions, pin-file hashes and the gate's own code."""
    env: dict[str, str] = {
        "godot": godot_version(root),
        "python3": python_version(),
    }
    for relative in ENVIRONMENT_FILES:
        env[relative] = _hash_or_missing(root / relative)
    env[GATE_CODE_DIR] = gate_code_hash(root)
    return env


def gate_fingerprint(
    baseline_sha: str, source: str, env: dict[str, str], checks: list[str]
) -> str:
    payload = {
        "baseline_sha": baseline_sha,
        "source": source,
        "env": dict(sorted(env.items())),
        "checks": list(checks),
    }
    return sha256_bytes(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def short(fingerprint: str, length: int = 12) -> str:
    return f"{fingerprint[:length]}…"
