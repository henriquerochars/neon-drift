from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Callable, Dict, List, Tuple
from unittest import mock

TOOLS_ROOT = Path(__file__).resolve().parents[2]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

from agent import bootstrap  # noqa: E402

# Fake launcher committed into the fixture: tools/godot.sh. Behaviour comes from FAKE_* vars.
FAKE_GODOT = """#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOG=""; IMPORT=0; VERSION=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-file) LOG=$2; shift ;;
    --import) IMPORT=1 ;;
    --version) VERSION=1 ;;
  esac
  shift
done
if [ "$VERSION" = 1 ]; then echo "${FAKE_GODOT_VERSION:-4.7.2.stable.official.abc}"; exit 0; fi
if [ "$IMPORT" = 1 ]; then
  [ -z "${FAKE_GODOT_CALLS:-}" ] || echo import >> "$FAKE_GODOT_CALLS"
  mkdir -p "$ROOT/.godot"
  case "${FAKE_GODOT_IMPORT:-ok}" in
    ok) echo "importing"; [ -z "$LOG" ] || echo "import finished" > "$LOG"; exit 0 ;;
    error) echo "importing"; [ -z "$LOG" ] || echo "ERROR: Failed loading resource: res://broken.png" > "$LOG"; exit 0 ;;
    exit) echo "crashed"; exit 3 ;;
  esac
fi
exit 0
"""

ENGINE_HINT = "run tools/setup_godot.sh in the primary checkout or set GODOT_BIN"


def clean_env() -> Dict[str, str]:
    return {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "FAKE_GODOT_"))
            and k not in ("GODOT_BIN", "IMPORT_TIMEOUT")}


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=str(cwd), check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, env=clean_env()).stdout


class FakeVenv:
    def __init__(self, code: int = 0) -> None:
        self.code = code
        self.calls = 0

    def __call__(self, root: Path, log: Callable[[str], None]) -> int:
        self.calls += 1
        if self.code == 0:
            bin_dir = root / ".venv" / "bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            gdlint = bin_dir / "gdlint"
            gdlint.write_text("#!/bin/sh\nexit 0\n")
            gdlint.chmod(0o755)
        return self.code


class BootstrapTestCase(unittest.TestCase):
    def setUp(self) -> None:
        env = mock.patch.dict(os.environ, clean_env(), clear=True)
        env.start()
        self.addCleanup(env.stop)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()
        self.calls_file = self.tmp / "godot-calls"
        os.environ["FAKE_GODOT_CALLS"] = str(self.calls_file)

        self.primary = self.tmp / "primary"
        (self.primary / "tools").mkdir(parents=True)
        git(self.primary, "-c", "init.defaultBranch=main", "init", "-q")
        git(self.primary, "config", "user.name", "Harness Test")
        git(self.primary, "config", "user.email", "harness@example.invalid")
        git(self.primary, "config", "commit.gpgsign", "false")
        godot = self.primary / "tools" / "godot.sh"
        godot.write_text(FAKE_GODOT)
        godot.chmod(0o755)
        (self.primary / "tools" / "requirements-lint.txt").write_text("gdtoolkit==4.5.0\n")
        (self.primary / "project.godot").write_text("config_version=5\n")
        (self.primary / "icon.png.import").write_text("[remap]\nimporter=\"texture\"\n")
        (self.primary / ".gitignore").write_text("/.tools\n.godot/\n.neondrift/\n.venv/\n")
        git(self.primary, "add", ".")
        git(self.primary, "commit", "-q", "-m", "fixture")
        (self.primary / ".tools").mkdir()
        self.linked = self.tmp / "linked"
        git(self.primary, "worktree", "add", "-q", "-b", "feat", str(self.linked))
        self.venv = FakeVenv()

    def bootstrap(self, root: Path, *argv: str) -> Tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = bootstrap.main(list(argv), cwd=root, venv_creator=self.venv)
        return code, out.getvalue(), err.getvalue()

    def import_calls(self) -> int:
        if not self.calls_file.exists():
            return 0
        return len(self.calls_file.read_text().split())

    def log_text(self, root: Path) -> str:
        return (root / ".neondrift" / "jobs" / "bootstrap" / "bootstrap.log").read_text()


class BootstrapTests(BootstrapTestCase):
    def test_linked_worktree_success(self) -> None:
        code, out, err = self.bootstrap(self.linked)
        self.assertEqual(code, 0, out + err)
        link = self.linked / ".tools"
        self.assertTrue(link.is_symlink())
        self.assertEqual(Path(os.readlink(link)), self.primary / ".tools")
        self.assertEqual(self.venv.calls, 1)
        self.assertEqual(self.import_calls(), 1)
        self.assertTrue((self.linked / ".neondrift" / ".gdignore").is_file())
        log = self.log_text(self.linked)
        for step in ("worktree:", "engine: linked .tools", "engine: Godot 4.7.2.stable",
                     "venv: creating", "import: OK", "bootstrap: OK"):
            self.assertIn(step, log)
        # Only ignored state was created: tracked files untouched, nothing untracked.
        self.assertEqual(git(self.linked, "status", "--porcelain"), "")
        self.assertFalse(os.path.lexists(self.primary / ".neondrift" / "jobs"))

    def test_second_run_is_reused(self) -> None:
        self.assertEqual(self.bootstrap(self.linked)[0], 0)
        code, out, _ = self.bootstrap(self.linked)
        self.assertEqual(code, 0)
        self.assertIn("reused", out)
        self.assertEqual(self.import_calls(), 1)
        self.assertEqual(self.venv.calls, 1)

    def test_missing_import_cache_is_not_reused(self) -> None:
        self.assertEqual(self.bootstrap(self.linked)[0], 0)
        shutil.rmtree(self.linked / ".godot")
        self.assertEqual(self.bootstrap(self.linked)[0], 0)
        self.assertEqual(self.import_calls(), 2)

    def test_changed_import_file_is_not_reused(self) -> None:
        self.assertEqual(self.bootstrap(self.linked)[0], 0)
        (self.linked / "icon.png.import").write_text("[remap]\nimporter=\"other\"\n")
        self.assertEqual(self.bootstrap(self.linked)[0], 0)
        self.assertEqual(self.import_calls(), 2)

    def test_existing_venv_is_kept(self) -> None:
        FakeVenv()(self.linked, lambda _: None)
        self.assertEqual(self.bootstrap(self.linked)[0], 0)
        self.assertEqual(self.venv.calls, 0)
        self.assertIn("venv: .venv/bin/gdlint present", self.log_text(self.linked))

    def test_venv_failure_fails(self) -> None:
        self.venv = FakeVenv(code=1)
        code, _, _ = self.bootstrap(self.linked)
        self.assertEqual(code, 1)
        self.assertEqual(self.import_calls(), 0)

    def test_existing_tools_is_not_overwritten(self) -> None:
        own = self.linked / ".tools"
        own.mkdir()
        self.assertEqual(self.bootstrap(self.linked)[0], 0)
        self.assertFalse(own.is_symlink())
        self.assertIn("left untouched", self.log_text(self.linked))

    def test_godot_bin_skips_link_and_is_not_printed(self) -> None:
        secret_path = "/opt/very-private-godot-location/Godot"
        os.environ["GODOT_BIN"] = secret_path
        code, out, err = self.bootstrap(self.linked)
        self.assertEqual(code, 0, out + err)
        self.assertFalse(os.path.lexists(self.linked / ".tools"))
        self.assertIn("GODOT_BIN is set", out)
        self.assertNotIn(secret_path, out + err + self.log_text(self.linked))

    def test_primary_checkout(self) -> None:
        code, out, err = self.bootstrap(self.primary)
        self.assertEqual(code, 0, out + err)
        self.assertTrue((self.primary / ".tools").is_dir())
        self.assertFalse((self.primary / ".tools").is_symlink())
        self.assertIn("left untouched", out)
        self.assertEqual(out.count("engine: Godot"), 1)

    def test_primary_without_tools_is_not_linked(self) -> None:
        (self.primary / ".tools").rmdir()
        code, out, err = self.bootstrap(self.primary)
        self.assertEqual(code, 0, out + err)
        self.assertFalse(os.path.lexists(self.primary / ".tools"))
        self.assertIn("primary checkout; no link needed", out)

    def test_wrong_engine_version_fails_with_hint(self) -> None:
        os.environ["FAKE_GODOT_VERSION"] = "4.6.1.stable.official.def"
        code, out, err = self.bootstrap(self.linked)
        self.assertEqual(code, bootstrap.EXIT_PREREQUISITE)
        self.assertIn(ENGINE_HINT, err)
        self.assertIn("4.6.1.stable", err)
        self.assertEqual(self.import_calls(), 0)
        self.assertEqual(self.venv.calls, 0)

    def test_missing_engine_fails_with_hint(self) -> None:
        (self.linked / "tools" / "godot.sh").unlink()
        code, _, err = self.bootstrap(self.linked)
        self.assertEqual(code, 4)
        self.assertIn(ENGINE_HINT, err)

    def test_engine_error_in_import_log_fails(self) -> None:
        os.environ["FAKE_GODOT_IMPORT"] = "error"
        code, out, _ = self.bootstrap(self.linked)
        self.assertEqual(code, 1)
        self.assertIn("ERROR: Failed loading resource", out)
        self.assertIn("engine errors", self.log_text(self.linked))

    def test_import_exit_code_fails(self) -> None:
        os.environ["FAKE_GODOT_IMPORT"] = "exit"
        code, _, _ = self.bootstrap(self.linked)
        self.assertEqual(code, 1)
        self.assertIn("exited 3", self.log_text(self.linked))

    def test_recorded_failure_needs_retry(self) -> None:
        os.environ["FAKE_GODOT_IMPORT"] = "error"
        self.assertEqual(self.bootstrap(self.linked)[0], 1)
        os.environ["FAKE_GODOT_IMPORT"] = "ok"
        code, _, err = self.bootstrap(self.linked)
        self.assertEqual(code, 1)
        self.assertIn("--retry", err)
        self.assertEqual(self.import_calls(), 1)
        code, out, err = self.bootstrap(self.linked, "--retry")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.import_calls(), 2)

    def test_skip_import(self) -> None:
        code, _, _ = self.bootstrap(self.linked, "--skip-import")
        self.assertEqual(code, 0)
        self.assertEqual(self.import_calls(), 0)
        self.assertIn("import: skipped", self.log_text(self.linked))
        # A full bootstrap does not reuse the skip-import success.
        self.assertEqual(self.bootstrap(self.linked)[0], 0)
        self.assertEqual(self.import_calls(), 1)

    def test_not_a_worktree(self) -> None:
        plain = self.tmp / "plain"
        plain.mkdir()
        os.environ["GIT_CEILING_DIRECTORIES"] = str(self.tmp)
        code, _, err = self.bootstrap(plain)
        self.assertEqual(code, 2)
        self.assertIn("not inside a git worktree", err)

    def test_usage_error(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            self.bootstrap(self.linked, "--bogus")
        self.assertEqual(ctx.exception.code, 2)


class ScanTests(unittest.TestCase):
    def test_scan_matches_test_sh_patterns(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "x.log"
            log.write_text("\n".join([
                "ok line",
                "\x1b[31mERROR:\x1b[0m bad",
                "SCRIPT ERROR: Parse",
                "Parse Error: oops",
                "MY_ERROR: not an engine error",
                "Exit code: 0",
            ]))
            hits: List[str] = bootstrap.scan_engine_errors([log, Path(tmp) / "missing.log"])
        self.assertEqual(hits, ["ERROR: bad", "SCRIPT ERROR: Parse", "Parse Error: oops"])


if __name__ == "__main__":
    unittest.main()
