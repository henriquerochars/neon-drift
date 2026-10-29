from __future__ import annotations

import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Callable, Dict, List, Optional
from unittest import mock

TOOLS_ROOT = Path(__file__).resolve().parents[2]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

from agent.lib import jobs  # noqa: E402
from agent.lib.worktree import Worktree, get_worktree  # noqa: E402

POLL = 0.05
WAIT_LIMIT = 30.0

HOLDER = textwrap.dedent(
    """
    import sys, time
    from pathlib import Path
    sys.path.insert(0, sys.argv[1])
    from agent.lib.jobs import run_job
    from agent.lib.worktree import get_worktree
    root, fingerprint, started, release = Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]), Path(sys.argv[5])

    def runner(log):
        log("owner: working")
        started.write_text("1")
        while not release.exists():
            time.sleep(0.02)
        log("owner: done")
        return 7

    result = run_job(get_worktree(root), "demo", fingerprint, runner, poll_seconds=0.05)
    sys.exit(result.exit_code)
    """
)


def clean_env() -> Dict[str, str]:
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=str(cwd), check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, env=clean_env())


def wait_for(predicate: Callable[[], bool], what: str) -> None:
    deadline = time.monotonic() + WAIT_LIMIT
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {what}")
        time.sleep(0.02)


class Recorder:
    def __init__(self, code: int = 0, delay: float = 0.0) -> None:
        self.code = code
        self.delay = delay
        self.calls = 0
        self._lock = threading.Lock()

    def __call__(self, log: Callable[[str], None]) -> int:
        with self._lock:
            self.calls += 1
        log("runner: hello")
        if self.delay:
            time.sleep(self.delay)
        return self.code


class JobsTestCase(unittest.TestCase):
    def setUp(self) -> None:
        env = mock.patch.dict(os.environ, clean_env(), clear=True)
        env.start()
        self.addCleanup(env.stop)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()
        self.root = self.tmp / "repo"
        self.root.mkdir()
        git(self.root, "init", "-q")
        git(self.root, "config", "user.name", "Harness Test")
        git(self.root, "config", "user.email", "harness@example.invalid")
        self.wt: Worktree = get_worktree(self.root)
        self.job_dir = self.root / ".neondrift" / "jobs" / "demo"
        self.out = io.StringIO()
        self.err = io.StringIO()

    def run_job(self, fingerprint: str, runner: Callable[[Callable[[str], None]], int],
                **kwargs: object) -> jobs.JobResult:
        with redirect_stdout(self.out), redirect_stderr(self.err):
            return jobs.run_job(self.wt, "demo", fingerprint, runner, poll_seconds=POLL, **kwargs)  # type: ignore[arg-type]

    def start_holder(self, fingerprint: str) -> "Holder":
        holder = Holder(self.tmp, self.root, fingerprint)
        self.addCleanup(holder.stop)
        return holder

    def write_lock(self, pid: int, fingerprint: str, process_start: Optional[str] = None) -> None:
        self.job_dir.mkdir(parents=True, exist_ok=True)
        lock = {"pid": pid, "started_at": "2026-01-01T00:00:00+00:00", "fingerprint": fingerprint,
                "host": socket.gethostname(), "process_start": process_start, "token": "old"}
        (self.job_dir / "lock.json").write_text(json.dumps(lock))


class Holder:
    """A separate process that owns job 'demo' until released."""

    def __init__(self, tmp: Path, root: Path, fingerprint: str) -> None:
        self.started = tmp / f"started-{fingerprint}"
        self.release = tmp / f"release-{fingerprint}"
        script = tmp / "holder.py"
        script.write_text(HOLDER)
        self.proc = subprocess.Popen(
            [sys.executable, str(script), str(TOOLS_ROOT), str(root), fingerprint,
             str(self.started), str(self.release)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        wait_for(self.started.exists, "the holder to start its job")

    def finish(self) -> int:
        self.release.write_text("1")
        return self.proc.wait(timeout=WAIT_LIMIT)

    def stop(self) -> None:
        if self.proc.poll() is None:
            self.release.write_text("1")
            try:
                self.proc.wait(timeout=WAIT_LIMIT)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


class RunTests(JobsTestCase):
    def test_owner_runs_logs_and_records_status(self) -> None:
        runner = Recorder()
        result = self.run_job("fp1", runner)
        self.assertEqual((result.exit_code, result.reused, result.followed), (0, False, False))
        self.assertEqual(runner.calls, 1)
        self.assertEqual(result.log_path, self.job_dir / "demo.log")
        self.assertIn("runner: hello", result.log_path.read_text())
        self.assertIn("runner: hello", self.out.getvalue())
        status = json.loads((self.job_dir / "status.json").read_text())
        self.assertEqual(status["fingerprint"], "fp1")
        self.assertEqual(status["exit_code"], 0)
        self.assertIn("finished_at", status)
        self.assertFalse((self.job_dir / "lock.json").exists())

    def test_success_is_reused(self) -> None:
        self.run_job("fp1", Recorder())
        runner = Recorder()
        result = self.run_job("fp1", runner)
        self.assertEqual((result.exit_code, result.reused), (0, True))
        self.assertEqual(runner.calls, 0)
        self.assertIn("reused", self.out.getvalue())

    def test_reuse_can_be_disabled(self) -> None:
        self.run_job("fp1", Recorder())
        runner = Recorder()
        result = self.run_job("fp1", runner, reuse_success=False)
        self.assertFalse(result.reused)
        self.assertEqual(runner.calls, 1)

    def test_new_fingerprint_reruns(self) -> None:
        self.run_job("fp1", Recorder())
        runner = Recorder()
        self.assertFalse(self.run_job("fp2", runner).reused)
        self.assertEqual(runner.calls, 1)

    def test_recorded_failure_needs_retry(self) -> None:
        self.assertEqual(self.run_job("fp1", Recorder(code=3)).exit_code, 3)
        runner = Recorder()
        result = self.run_job("fp1", runner)
        self.assertEqual(result.exit_code, 3)
        self.assertEqual(runner.calls, 0)
        self.assertIn("--retry", self.err.getvalue())
        result = self.run_job("fp1", runner, retry=True)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(runner.calls, 1)

    def test_runner_exception_is_recorded_failure(self) -> None:
        def boom(log: Callable[[str], None]) -> int:
            raise RuntimeError("kaput")

        result = self.run_job("fp1", boom)
        self.assertEqual(result.exit_code, 1)
        self.assertIn("RuntimeError: kaput", result.log_path.read_text())
        self.assertFalse((self.job_dir / "lock.json").exists())


class ConcurrencyTests(JobsTestCase):
    def test_same_fingerprint_follows_owner_process(self) -> None:
        holder = self.start_holder("fpA")
        runner = Recorder()
        results: List[jobs.JobResult] = []
        with redirect_stdout(self.out), redirect_stderr(self.err):
            thread = threading.Thread(
                target=lambda: results.append(
                    jobs.run_job(self.wt, "demo", "fpA", runner, poll_seconds=POLL)))
            thread.start()
            wait_for(lambda: "following" in self.out.getvalue(), "the follower to attach")
            self.assertEqual(holder.finish(), 7)
            thread.join(WAIT_LIMIT)
        self.assertFalse(thread.is_alive())
        self.assertEqual(runner.calls, 0)
        self.assertEqual(len(results), 1)
        self.assertEqual((results[0].exit_code, results[0].followed, results[0].reused), (7, True, False))
        self.assertIn("owner: done", self.out.getvalue())  # the owner's log was echoed

    def test_different_fingerprint_while_running_is_busy(self) -> None:
        holder = self.start_holder("fpA")
        runner = Recorder()
        result = self.run_job("fpB", runner)
        self.assertEqual(result.exit_code, jobs.EXIT_BUSY)
        self.assertEqual(result.exit_code, 75)
        self.assertEqual(runner.calls, 0)
        self.assertIn("busy", self.err.getvalue())
        self.assertTrue((self.job_dir / "lock.json").exists())  # never stolen
        self.assertEqual(holder.finish(), 7)

    def test_concurrent_threads_run_once(self) -> None:
        runner = Recorder(code=0, delay=0.5)
        results: List[jobs.JobResult] = []
        with redirect_stdout(self.out), redirect_stderr(self.err):
            threads = [threading.Thread(target=lambda: results.append(
                jobs.run_job(self.wt, "demo", "fp1", runner, poll_seconds=POLL))) for _ in range(4)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(WAIT_LIMIT)
        self.assertEqual(runner.calls, 1)
        self.assertEqual(sorted(r.exit_code for r in results), [0, 0, 0, 0])
        owners = [r for r in results if not r.followed and not r.reused]
        self.assertEqual(len(owners), 1)


class ReclaimTests(JobsTestCase):
    def dead_pid(self) -> int:
        proc = subprocess.Popen([sys.executable, "-c", "pass"])
        proc.wait()
        return proc.pid

    def test_dead_owner_lock_is_reclaimed_and_logged(self) -> None:
        self.write_lock(self.dead_pid(), "fp1")
        runner = Recorder()
        result = self.run_job("fp1", runner)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(runner.calls, 1)
        self.assertIn("reclaimed lock of dead owner", result.log_path.read_text())
        self.assertFalse((self.job_dir / "lock.json").exists())

    def test_dead_owner_with_other_fingerprint_is_reclaimed(self) -> None:
        self.write_lock(self.dead_pid(), "other")
        self.assertEqual(self.run_job("fp1", Recorder()).exit_code, 0)

    def test_recycled_pid_is_not_the_owner(self) -> None:
        if jobs.process_start_identity(os.getpid()) is None:
            self.skipTest("ps -o lstart= is unavailable on this host")
        self.write_lock(os.getpid(), "other", process_start="Thu Jan  1 00:00:00 1970")
        runner = Recorder()
        result = self.run_job("fp1", runner)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(runner.calls, 1)
        self.assertIn("reclaimed", result.log_path.read_text())

    def test_live_owner_is_kept_regardless_of_age(self) -> None:
        self.write_lock(os.getpid(), "other", process_start=jobs.process_start_identity(os.getpid()))
        runner = Recorder()
        self.assertEqual(self.run_job("fp1", runner).exit_code, 75)
        self.assertEqual(runner.calls, 0)
        self.assertTrue((self.job_dir / "lock.json").exists())

    def test_lock_from_other_host_is_never_reclaimed(self) -> None:
        self.write_lock(self.dead_pid(), "other")
        lock_path = self.job_dir / "lock.json"
        lock = json.loads(lock_path.read_text())
        lock["host"] = "some-other-host.invalid"
        lock_path.write_text(json.dumps(lock))
        self.assertEqual(self.run_job("fp1", Recorder()).exit_code, 75)


class LivenessTests(unittest.TestCase):
    def test_pid_alive(self) -> None:
        self.assertTrue(jobs.pid_alive(os.getpid()))
        self.assertFalse(jobs.pid_alive(0))
        self.assertFalse(jobs.pid_alive(-5))

    def test_permission_error_counts_as_alive(self) -> None:
        with mock.patch.object(jobs.os, "kill", side_effect=PermissionError):
            self.assertTrue(jobs.pid_alive(12345))


if __name__ == "__main__":
    unittest.main()
