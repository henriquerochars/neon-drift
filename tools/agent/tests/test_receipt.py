"""Receipt storage: per-fingerprint file, latest.json, round trip and exit codes."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from agent.lib import receipt as rc  # noqa: E402
from agent.lib.worktree import Worktree  # noqa: E402

FIELDS = (
    "version",
    "fingerprint",
    "baseline_ref",
    "baseline_sha",
    "head_sha",
    "checks",
    "steps",
    "status",
    "finished_at",
)


def fake_worktree(root: Path) -> Worktree:
    return Worktree(
        root=root,
        git_dir=root / ".git",
        common_dir=root / ".git",
        primary_root=root,
        is_primary=True,
        id="0123456789ab",
        state_dir=root / ".neondrift",
    )


class ReceiptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.worktree = fake_worktree(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _receipt(self, fingerprint: str = "f" * 64, status: str = rc.STATUS_PASS) -> rc.Receipt:
        return rc.Receipt(
            fingerprint=fingerprint,
            baseline_ref="origin/main",
            baseline_sha="a" * 40,
            head_sha="b" * 40,
            checks=["lint", "godot-tests"],
            steps=[rc.Step("lint", 0, 1.5, ".neondrift/gate/logs/x/lint.log")],
            status=status,
        )

    def test_write_and_read_round_trip(self) -> None:
        receipt = self._receipt()
        path = rc.write_receipt(self.worktree, receipt)
        self.assertEqual(path, self.root / ".neondrift" / "gate" / "receipts" / f"{'f' * 64}.json")
        data = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(tuple(data), FIELDS)
        self.assertEqual(data["version"], rc.RECEIPT_VERSION)
        self.assertTrue(data["finished_at"])
        self.assertEqual(data["steps"], [{"check": "lint", "exit_code": 0, "seconds": 1.5, "log": ".neondrift/gate/logs/x/lint.log"}])
        loaded = rc.read_receipt(self.worktree, "f" * 64)
        assert loaded is not None
        self.assertEqual(loaded, receipt)
        self.assertEqual(rc.read_latest(self.worktree), receipt)
        self.assertTrue((self.root / ".neondrift" / ".gdignore").exists())

    def test_latest_follows_last_write(self) -> None:
        rc.write_receipt(self.worktree, self._receipt("1" * 64))
        rc.write_receipt(self.worktree, self._receipt("2" * 64, rc.STATUS_FAIL))
        latest = rc.read_latest(self.worktree)
        assert latest is not None
        self.assertEqual(latest.fingerprint, "2" * 64)
        self.assertIsNotNone(rc.read_receipt(self.worktree, "1" * 64))
        self.assertEqual(sorted(p.name for p in rc.receipts_dir(self.worktree).iterdir()), [f"{'1' * 64}.json", f"{'2' * 64}.json"])

    def test_missing_and_corrupt_receipts_read_as_none(self) -> None:
        self.assertIsNone(rc.read_receipt(self.worktree, "nope"))
        self.assertIsNone(rc.read_latest(self.worktree))
        rc.latest_path(self.worktree).parent.mkdir(parents=True, exist_ok=True)
        rc.latest_path(self.worktree).write_text("{not json", encoding="utf-8")
        self.assertIsNone(rc.read_latest(self.worktree))
        rc.latest_path(self.worktree).write_text("[]", encoding="utf-8")
        self.assertIsNone(rc.read_latest(self.worktree))

    def test_invalid_status_rejected(self) -> None:
        with self.assertRaises(ValueError):
            rc.write_receipt(self.worktree, self._receipt(status="maybe"))

    def test_exit_codes(self) -> None:
        self.assertEqual(self._receipt().exit_code(), 0)
        self.assertEqual(self._receipt(status=rc.STATUS_FAIL).exit_code(), 1)
        self.assertEqual(self._receipt(status=rc.STATUS_STALE).exit_code(), 3)
        prereq = self._receipt(status=rc.STATUS_FAIL)
        prereq.steps = [rc.Step(rc.PREREQUISITES_STEP, 4, 0.0, "x.log")]
        self.assertEqual(prereq.exit_code(), 4)

    def test_from_dict_defaults(self) -> None:
        loaded = rc.Receipt.from_dict({"fingerprint": "x", "steps": [{"check": "lint", "exit_code": 2, "seconds": 0}]})
        self.assertEqual(loaded.status, rc.STATUS_FAIL)
        self.assertEqual(loaded.steps[0].log, "")
        self.assertEqual(loaded.version, rc.RECEIPT_VERSION)


if __name__ == "__main__":
    unittest.main()
