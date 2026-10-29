"""Gate receipts (docs/ai/contracts.md "Receipt").

A receipt is stored twice: ``.neondrift/gate/receipts/<fingerprint>.json`` (one per
fingerprint) and ``.neondrift/gate/latest.json`` (the most recent run). Writes are
atomic (temporary file plus rename).
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from agent.lib.worktree import Worktree, ensure_state_dir

RECEIPT_VERSION = 1
STATUS_PASS = "pass"
STATUS_FAIL = "fail"
STATUS_STALE = "stale"
STATUSES: tuple[str, ...] = (STATUS_PASS, STATUS_FAIL, STATUS_STALE)
GATE_DIR = "gate"
RECEIPTS_DIR = "receipts"
LOGS_DIR = "logs"
LATEST_FILE = "latest.json"
PREREQUISITES_STEP = "prerequisites"
EXIT_PREREQUISITE = 4


@dataclass
class Step:
    check: str
    exit_code: int
    seconds: float
    log: str


@dataclass
class Receipt:
    fingerprint: str
    baseline_ref: str
    baseline_sha: str
    head_sha: str
    checks: list[str]
    steps: list[Step] = field(default_factory=list)
    status: str = STATUS_FAIL
    finished_at: str = ""
    version: int = RECEIPT_VERSION

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        return {
            "version": data["version"],
            "fingerprint": data["fingerprint"],
            "baseline_ref": data["baseline_ref"],
            "baseline_sha": data["baseline_sha"],
            "head_sha": data["head_sha"],
            "checks": data["checks"],
            "steps": data["steps"],
            "status": data["status"],
            "finished_at": data["finished_at"],
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Receipt:
        steps = [
            Step(
                check=str(step["check"]),
                exit_code=int(step["exit_code"]),
                seconds=float(step["seconds"]),
                log=str(step.get("log", "")),
            )
            for step in data.get("steps", [])
        ]
        return cls(
            fingerprint=str(data["fingerprint"]),
            baseline_ref=str(data.get("baseline_ref", "")),
            baseline_sha=str(data.get("baseline_sha", "")),
            head_sha=str(data.get("head_sha", "")),
            checks=[str(check) for check in data.get("checks", [])],
            steps=steps,
            status=str(data.get("status", STATUS_FAIL)),
            finished_at=str(data.get("finished_at", "")),
            version=int(data.get("version", RECEIPT_VERSION)),
        )

    @property
    def passed(self) -> bool:
        return self.status == STATUS_PASS

    def exit_code(self) -> int:
        """Gate exit code implied by this receipt (contract exit-code table)."""
        if self.status == STATUS_PASS:
            return 0
        if self.status == STATUS_STALE:
            return 3
        for step in self.steps:
            if step.check == PREREQUISITES_STEP and step.exit_code != 0:
                return EXIT_PREREQUISITE
        return 1


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def gate_dir(worktree: Worktree) -> Path:
    return ensure_state_dir(worktree) / GATE_DIR


def receipts_dir(worktree: Worktree) -> Path:
    return gate_dir(worktree) / RECEIPTS_DIR


def logs_dir(worktree: Worktree, fingerprint: str) -> Path:
    return gate_dir(worktree) / LOGS_DIR / fingerprint


def receipt_path(worktree: Worktree, fingerprint: str) -> Path:
    return receipts_dir(worktree) / f"{fingerprint}.json"


def latest_path(worktree: Worktree) -> Path:
    return gate_dir(worktree) / LATEST_FILE


def _write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def write_receipt(worktree: Worktree, receipt: Receipt) -> Path:
    if receipt.status not in STATUSES:
        raise ValueError(f"invalid receipt status {receipt.status!r}")
    if not receipt.finished_at:
        receipt.finished_at = now_iso()
    text = json.dumps(receipt.to_dict(), indent=2, sort_keys=False) + "\n"
    path = receipt_path(worktree, receipt.fingerprint)
    _write_atomic(path, text)
    _write_atomic(latest_path(worktree), text)
    return path


def _read(path: Path) -> Receipt | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or "fingerprint" not in data:
        return None
    try:
        return Receipt.from_dict(data)
    except (KeyError, TypeError, ValueError):
        return None


def read_receipt(worktree: Worktree, fingerprint: str) -> Receipt | None:
    return _read(receipt_path(worktree, fingerprint))


def read_latest(worktree: Worktree) -> Receipt | None:
    return _read(latest_path(worktree))
