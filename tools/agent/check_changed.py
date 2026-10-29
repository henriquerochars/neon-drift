#!/usr/bin/env python3
"""Changed-scope gate with receipts (ADR 0007 D05/D11/D12/D19/D20, G1).

    tools/agent.sh check [--base REF] [--force] [--retry] [--status] [--json] [--quiet]

Compares the working tree (committed, staged, unstaged and untracked files) with the
merge base against ``origin/main`` (or ``--base``), selects checks from the changed
paths, runs them from the worktree root and records a receipt bound to the exact
contents, the toolchain and the selected checks. A passing receipt is reused while the
fingerprint matches. The gate never fetches and never starts the game.

Exit codes: 0 pass, 1 a check failed, 2 usage/baseline error, 3 stale (a source file
changed during the run), 4 missing prerequisite, 75 busy (another gate holds the lock).
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Sequence

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from agent.lib import fingerprint as fp  # noqa: E402
from agent.lib import receipt as rc  # noqa: E402
from agent.lib.jobs import run_job  # noqa: E402
from agent.lib.selection import (  # noqa: E402
    CHECK_ORDER,
    filter_relevant,
    record_advisory,
    select_checks,
)
from agent.lib.worktree import Worktree, ensure_state_dir, get_worktree  # noqa: E402

DEFAULT_BASE = "origin/main"
# Used when origin/main does not exist (no remote yet): the local main branch.
LOCAL_FALLBACK_BASE = "main"
JOB_NAME = "gate"
EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_STALE = 3
EXIT_PREREQUISITE = rc.EXIT_PREREQUISITE
EXIT_BUSY = 75
EXIT_CANNOT_RUN = 127
GODOT_VERSION_PREFIX = "4.7.2.stable"
# Same scan as tools/test.sh: engine errors fail a step even when the exit code is 0.
ENGINE_ERROR_RE = re.compile(r"SCRIPT ERROR|(^|[^A-Za-z_])ERROR:|Parse Error:")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
ENGINE_SCAN_CHECKS: frozenset[str] = frozenset(("balance",))
ENGINE_CHECKS: frozenset[str] = frozenset(("balance", "godot-tests"))
ART_PYTHON = "python3"

CommandTable = Mapping[str, Sequence[Sequence[str]]]
DEFAULT_COMMANDS: dict[str, tuple[tuple[str, ...], ...]] = {
    "harness": (
        ("python3", "tools/check_harness.py"),
        ("python3", "-m", "unittest", "discover", "-s", "tools/agent/tests"),
        ("python3", "-m", "unittest", "discover", "-s", "tools/agent_hooks/tests"),
    ),
    "record": (("python3", "tools/agent/check_record.py"),),
    "toolchain": (("bash", "tools/test_toolchain.sh"),),
    "lint": (("tools/lint.sh",),),
    "balance": (("python3", "tools/data/check_balance.py"),),
    "art": ((ART_PYTHON, "tools/art/validate.py"),),
    "godot-tests": (("tools/test.sh",),),
}
STATUS_CURRENT_PASS = "current pass"
STATUS_CURRENT_FAIL = "current fail"
STATUS_STALE = "stale"
STATUS_NONE = "none"
STATUS_EXIT_CODES: dict[str, int] = {
    STATUS_CURRENT_PASS: EXIT_PASS,
    STATUS_CURRENT_FAIL: EXIT_FAIL,
    STATUS_STALE: EXIT_STALE,
    STATUS_NONE: EXIT_FAIL,
}


class GateError(Exception):
    """Usage or baseline error; carries the exit code."""

    def __init__(self, message: str, exit_code: int = EXIT_USAGE) -> None:
        super().__init__(message)
        self.exit_code = exit_code


@dataclass(frozen=True)
class Baseline:
    ref: str
    sha: str
    head_sha: str


@dataclass(frozen=True)
class Scope:
    baseline: Baseline
    paths: list[str]
    checks: list[str]
    source: str
    env: dict[str, str]
    fingerprint: str


# --- git -----------------------------------------------------------------------------


def _git_bytes(root: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", *args], cwd=str(root), capture_output=True, check=False
    )
    if result.returncode != 0:
        raise GateError(
            f"git {' '.join(args)} failed: {result.stderr.decode('utf-8', 'replace').strip()}"
        )
    return result.stdout


def _git(root: Path, *args: str) -> str:
    return _git_bytes(root, *args).decode("utf-8", "replace").strip()


def resolve_baseline(root: Path, base: str) -> Baseline:
    """merge-base of HEAD and ``base``; exit 2 with guidance when either is missing."""
    try:
        head = _git(root, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
    except GateError as error:
        raise GateError("HEAD has no commit; commit once before running the gate") from error
    if base == DEFAULT_BASE:
        try:
            _git(root, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
        except GateError:
            base = LOCAL_FALLBACK_BASE
    try:
        _git(root, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
    except GateError as error:
        raise GateError(
            f"baseline {base!r} not found. Run `git fetch origin main` or pass "
            "--base REF (the gate never fetches)."
        ) from error
    try:
        sha = _git(root, "merge-base", "HEAD", base)
    except GateError as error:
        raise GateError(f"no merge base between HEAD and {base!r}; pass --base REF") from error
    return Baseline(ref=base, sha=sha, head_sha=head)


def _parse_name_status(data: bytes) -> list[str]:
    """Paths from ``git diff --name-status -z``; renames and copies yield both paths."""
    fields = data.split(b"\0")
    paths: list[str] = []
    index = 0
    while index < len(fields):
        status = fields[index].decode("utf-8", "replace")
        if not status:
            index += 1
            continue
        count = 2 if status[:1] in ("R", "C") else 1
        for offset in range(1, count + 1):
            if index + offset < len(fields) and fields[index + offset]:
                paths.append(fields[index + offset].decode("utf-8", "replace"))
        index += count + 1
    return paths


def changed_paths(root: Path, baseline_sha: str) -> list[str]:
    """Tracked changes vs the baseline (working tree) plus untracked files, filtered."""
    diff = _git_bytes(
        root, "diff", "--name-status", "-z", "-M", "--no-color", "--no-ext-diff", baseline_sha
    )
    untracked = _git_bytes(root, "ls-files", "--others", "--exclude-standard", "-z")
    paths = _parse_name_status(diff)
    paths.extend(
        part.decode("utf-8", "replace") for part in untracked.split(b"\0") if part
    )
    return filter_relevant(paths)


def compute_scope(worktree: Worktree, base: str) -> Scope:
    root = worktree.root
    baseline = resolve_baseline(root, base)
    paths = changed_paths(root, baseline.sha)
    checks = select_checks(paths)
    source = fp.source_fingerprint(root, paths)
    env = fp.environment_fingerprint(root)
    digest = fp.gate_fingerprint(baseline.sha, source, env, checks)
    return Scope(baseline, paths, checks, source, env, digest)


# --- prerequisites -------------------------------------------------------------------


def prerequisite_problems(root: Path, checks: Sequence[str]) -> list[str]:
    """Actionable messages for every missing prerequisite of the selected checks."""
    problems: list[str] = []
    if ENGINE_CHECKS & set(checks):
        version = fp.godot_version(root)
        if not version.startswith(GODOT_VERSION_PREFIX):
            problems.append(
                f"Godot {GODOT_VERSION_PREFIX} is required for "
                f"{', '.join(sorted(ENGINE_CHECKS & set(checks)))} "
                f"(tools/godot.sh --version gave {version!r}): run tools/agent.sh bootstrap "
                "or set GODOT_BIN"
            )
    if "art" in checks and not (root / "tools" / "art" / "validate.py").is_file():
        problems.append("the art check needs tools/art/validate.py")
    return problems


# --- steps ---------------------------------------------------------------------------


def _relative(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return str(path)


def run_step(
    root: Path,
    check: str,
    commands: Sequence[Sequence[str]],
    log_file: Path,
    log: Callable[[str], None],
) -> rc.Step:
    """Run a check's commands in order, streaming output to ``log_file`` and ``log``."""
    started = time.monotonic()
    exit_code = 0
    engine_hit = False
    scan = check in ENGINE_SCAN_CHECKS
    with log_file.open("a", encoding="utf-8") as sink:
        for argv in commands:
            argv = [str(part) for part in argv]
            header = f"$ {shlex.join(argv)}"
            sink.write(header + "\n")
            log(header)
            try:
                process = subprocess.Popen(
                    argv,
                    cwd=str(root),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    errors="replace",
                )
            except OSError as error:
                message = f"cannot run {argv[0]}: {error}"
                sink.write(message + "\n")
                log(message)
                exit_code = EXIT_CANNOT_RUN
                break
            assert process.stdout is not None
            for line in process.stdout:
                sink.write(line)
                sink.flush()
                log(line.rstrip("\n"))
                if scan and ENGINE_ERROR_RE.search(ANSI_RE.sub("", line)):
                    engine_hit = True
            exit_code = process.wait()
            if exit_code != 0:
                break
        if exit_code == 0 and engine_hit:
            exit_code = EXIT_FAIL
            message = f"FAIL: {check} output has engine errors (exit code was 0)"
            sink.write(message + "\n")
            log(message)
    return rc.Step(
        check=check,
        exit_code=exit_code,
        seconds=round(time.monotonic() - started, 3),
        log=_relative(root, log_file),
    )


# --- reporting -----------------------------------------------------------------------


def _silent(_text: str) -> None:
    """Log sink for --quiet/--json: check output stays in the per-step log files."""


def _say(args: argparse.Namespace, text: str) -> None:
    if not args.quiet and not args.json:
        print(text, flush=True)


def _print_scope(args: argparse.Namespace, scope: Scope) -> None:
    baseline = scope.baseline
    _say(
        args,
        f"baseline: {baseline.ref} merge-base {baseline.sha[:12]} (HEAD {baseline.head_sha[:12]})",
    )
    _say(args, f"changed files: {len(scope.paths)}")
    _say(args, f"checks: {', '.join(scope.checks) if scope.checks else '(none)'}")
    _say(args, f"fingerprint: {fp.short(scope.fingerprint)}")
    advisory = record_advisory(scope.paths)
    if advisory:
        _say(args, advisory)


def _print_summary(args: argparse.Namespace, worktree: Worktree, receipt: rc.Receipt) -> None:
    if args.quiet or args.json:
        return
    print(f"{'step':<14}{'exit':>5}{'seconds':>10}  log", flush=True)
    for step in receipt.steps:
        print(f"{step.check:<14}{step.exit_code:>5}{step.seconds:>10.1f}  {step.log}", flush=True)
    if not receipt.steps:
        print("(no steps)", flush=True)
    print(f"receipt: {_relative(worktree.root, rc.receipt_path(worktree, receipt.fingerprint))}")


def _print_json(label: str, scope: Scope, receipt: rc.Receipt | None) -> None:
    payload = {
        "gate": label,
        "fingerprint": scope.fingerprint,
        "baseline_ref": scope.baseline.ref,
        "baseline_sha": scope.baseline.sha,
        "checks": scope.checks,
        "changed_files": len(scope.paths),
        "advisories": [text for text in (record_advisory(scope.paths),) if text],
        "receipt": receipt.to_dict() if receipt else None,
    }
    print(json.dumps(payload, indent=2), flush=True)


def _final_line(label: str, fingerprint: str) -> None:
    """One-line status; the fingerprint is shown only when a receipt backs the label."""
    if label in (STATUS_NONE, STATUS_STALE, rc.STATUS_STALE):
        print(f"gate: {label}", flush=True)
        return
    print(f"gate: {label} ({fp.short(fingerprint)})", flush=True)


# --- modes ---------------------------------------------------------------------------


def status_label(worktree: Worktree, scope: Scope) -> tuple[str, rc.Receipt | None]:
    receipt = rc.read_receipt(worktree, scope.fingerprint)
    if receipt is not None:
        if receipt.status == rc.STATUS_PASS:
            return STATUS_CURRENT_PASS, receipt
        if receipt.status == rc.STATUS_FAIL:
            return STATUS_CURRENT_FAIL, receipt
        return STATUS_STALE, receipt
    latest = rc.read_latest(worktree)
    return (STATUS_STALE if latest is not None else STATUS_NONE), None


def status_gate(worktree: Worktree, args: argparse.Namespace) -> int:
    scope = compute_scope(worktree, args.base)
    label, receipt = status_label(worktree, scope)
    if args.json:
        _print_json(label, scope, receipt)
    else:
        _print_scope(args, scope)
        if receipt is not None:
            _print_summary(args, worktree, receipt)
        _final_line(label, scope.fingerprint)
    return STATUS_EXIT_CODES[label]


def run_gate(
    worktree: Worktree, args: argparse.Namespace, commands: CommandTable | None = None
) -> int:
    table: CommandTable = DEFAULT_COMMANDS if commands is None else commands
    root = worktree.root
    scope = compute_scope(worktree, args.base)
    _print_scope(args, scope)
    unknown = [check for check in scope.checks if check not in table]
    if unknown:
        raise GateError(f"no command for checks: {', '.join(unknown)}")

    retry = args.force or args.retry
    if not args.force:
        existing = rc.read_receipt(worktree, scope.fingerprint)
        if existing is not None and existing.status == rc.STATUS_PASS:
            _say(args, "reused: a passing receipt matches the current fingerprint")
            return _finish(args, worktree, scope, existing)
        if existing is not None and existing.exit_code() == EXIT_PREREQUISITE:
            # Prerequisites are not part of the fingerprint (a venv is not a pin), so a
            # recorded prerequisite failure is probed again on every run.
            retry = True
        elif existing is not None and existing.status == rc.STATUS_FAIL and not args.retry:
            _say(args, "recorded failure matches the current fingerprint (rerun with --retry)")
            return _finish(args, worktree, scope, existing)

    verbose = not (args.quiet or args.json)

    def runner(log: Callable[[str], None]) -> int:
        emit: Callable[[str], None] = log if verbose else _silent
        logs = rc.logs_dir(worktree, scope.fingerprint)
        logs.mkdir(parents=True, exist_ok=True)
        receipt = rc.Receipt(
            fingerprint=scope.fingerprint,
            baseline_ref=scope.baseline.ref,
            baseline_sha=scope.baseline.sha,
            head_sha=scope.baseline.head_sha,
            checks=list(scope.checks),
        )
        problems = prerequisite_problems(root, scope.checks)
        if problems:
            prereq_log = logs / f"{rc.PREREQUISITES_STEP}.log"
            prereq_log.write_text("\n".join(problems) + "\n", encoding="utf-8")
            for problem in problems:
                emit(f"missing prerequisite: {problem}")
            receipt.steps.append(
                rc.Step(rc.PREREQUISITES_STEP, EXIT_PREREQUISITE, 0.0, _relative(root, prereq_log))
            )
            receipt.status = rc.STATUS_FAIL
            rc.write_receipt(worktree, receipt)
            return EXIT_PREREQUISITE
        for check in scope.checks:
            emit(f"== {check}")
            step = run_step(root, check, table[check], logs / f"{check}.log", emit)
            receipt.steps.append(step)
            emit(f"== {check}: exit {step.exit_code} in {step.seconds:.1f}s")
        after = fp.source_fingerprint(root, scope.paths)
        if after != scope.source:
            emit("source changed during the run; receipt is stale")
            receipt.status = rc.STATUS_STALE
            rc.write_receipt(worktree, receipt)
            return EXIT_STALE
        failed = [step for step in receipt.steps if step.exit_code != 0]
        receipt.status = rc.STATUS_FAIL if failed else rc.STATUS_PASS
        rc.write_receipt(worktree, receipt)
        return EXIT_FAIL if failed else EXIT_PASS

    result = run_job(
        worktree,
        JOB_NAME,
        scope.fingerprint,
        runner,
        retry=retry,
        reuse_success=not args.force,
    )
    if result.exit_code == EXIT_BUSY:
        _say(args, f"busy: another gate is running with a different fingerprint ({result.log_path})")
        if args.quiet:
            print("gate: busy", flush=True)
        return EXIT_BUSY
    if result.followed:
        _say(args, "followed a running gate with the same fingerprint")
    elif result.reused:
        _say(args, "reused: a completed job matches the current fingerprint")
    receipt = rc.read_receipt(worktree, scope.fingerprint)
    if receipt is None:
        _say(args, f"no receipt was written (job exit {result.exit_code})")
        if args.quiet:
            print(f"gate: fail ({fp.short(scope.fingerprint)})", flush=True)
        return result.exit_code or EXIT_FAIL
    return _finish(args, worktree, scope, receipt)


def _finish(
    args: argparse.Namespace, worktree: Worktree, scope: Scope, receipt: rc.Receipt
) -> int:
    code = receipt.exit_code()
    label = receipt.status
    if code == EXIT_PREREQUISITE:
        label = "fail (missing prerequisite)"
    if args.json:
        _print_json(label, scope, receipt)
    else:
        _print_summary(args, worktree, receipt)
        _final_line(label, scope.fingerprint)
    return code


# --- CLI -----------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tools/agent.sh check",
        description="Changed-scope gate: selects checks from the diff against the baseline "
        "and records a receipt bound to the exact contents (ADR 0007).",
    )
    parser.add_argument("--base", default=DEFAULT_BASE, help=f"baseline ref (default {DEFAULT_BASE})")
    parser.add_argument("--force", action="store_true", help="rerun even with a matching receipt")
    parser.add_argument("--retry", action="store_true", help="rerun a recorded failure")
    parser.add_argument("--status", action="store_true", help="report the receipt status, run nothing")
    parser.add_argument("--json", action="store_true", help="print the receipt as JSON")
    parser.add_argument("--quiet", action="store_true", help="print only the one-line status")
    return parser


def main(
    argv: Sequence[str] | None = None,
    commands: CommandTable | None = None,
    cwd: Path | None = None,
) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    try:
        worktree = get_worktree(cwd)
        ensure_state_dir(worktree)
        if args.status:
            return status_gate(worktree, args)
        return run_gate(worktree, args, commands)
    except GateError as error:
        print(f"gate: error: {error}", file=sys.stderr, flush=True)
        if args.quiet:
            print(f"gate: {STATUS_NONE}", flush=True)
        return error.exit_code
    except KeyboardInterrupt:
        print("gate: interrupted", file=sys.stderr, flush=True)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
