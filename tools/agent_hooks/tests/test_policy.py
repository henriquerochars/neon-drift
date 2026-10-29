"""Unit tests for the shared guard policy (docs/ai/contracts.md, ADR 0007)."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from agent_hooks import policy  # noqa: E402

# A home that exists nowhere: the policy only needs the string, and it must not be under a
# temporary root (writes under /tmp are allowed by design).
FAKE_HOME = "/home/guard-test-user"


class PolicyCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.realpath(self.tmp.name)
        for name in ("src", "data", ".godot", "artifacts", "build", "docs", ".claude", "tools/agent_hooks"):
            os.makedirs(os.path.join(self.root, name), exist_ok=True)
        Path(self.root, "release.keystore").write_text("not really a keystore\n")
        Path(self.root, "notes.txt").write_text("plain\n")
        os.symlink("release.keystore", os.path.join(self.root, "alias.txt"))
        os.symlink("CLAUDE.md", os.path.join(self.root, "policy-alias.md"))
        env = mock.patch.dict(os.environ, {"HOME": FAKE_HOME}, clear=False)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("TMPDIR", None)

    def request(self, operation: dict, cwd: str = "") -> policy.Decision:
        return policy.evaluate(
            {"version": 1, "root": self.root, "cwd": cwd or self.root, "operation": operation}
        )

    def shell(self, text: str, cwd: str = "") -> policy.Decision:
        return self.request({"kind": "shell", "text": text}, cwd)

    def read(self, *paths: str) -> policy.Decision:
        return self.request({"kind": "read", "paths": list(paths)})

    def write(self, *paths: str) -> policy.Decision:
        return self.request({"kind": "write", "paths": list(paths)})

    def assertDecision(self, decision: policy.Decision, expected: str, reason: str) -> None:
        self.assertEqual((decision.decision, decision.reason), (expected, reason))

    def assertAllow(self, decision: policy.Decision) -> None:
        self.assertDecision(decision, "allow", "safe")

    def assertDeny(self, decision: policy.Decision, reason: str) -> None:
        self.assertDecision(decision, "deny", reason)

    def assertAsk(self, decision: policy.Decision, reason: str) -> None:
        self.assertDecision(decision, "approval-required", reason)


class RequestValidationTest(PolicyCase):
    def test_unknown_version_is_invalid(self) -> None:
        decision = policy.evaluate({"version": 2, "root": self.root, "cwd": self.root, "operation": {"kind": "mcp", "name": "x"}})
        self.assertDeny(decision, "invalid-request")

    def test_missing_operation_and_unknown_kind(self) -> None:
        self.assertDeny(policy.evaluate({"version": 1, "root": self.root, "cwd": self.root}), "invalid-request")
        self.assertDeny(self.request({"kind": "exec", "text": "ls"}), "invalid-request")

    def test_wrong_payload_types(self) -> None:
        self.assertDeny(self.request({"kind": "shell", "text": ["ls"]}), "invalid-request")
        self.assertDeny(self.request({"kind": "read", "paths": "notes.txt"}), "invalid-request")
        self.assertDeny(self.request({"kind": "write", "paths": [""]}), "invalid-request")
        self.assertDeny(self.request({"kind": "shell", "text": "ls \x00"}), "invalid-request")

    def test_relative_root_is_invalid(self) -> None:
        decision = policy.evaluate({"version": 1, "root": "repo", "cwd": "repo", "operation": {"kind": "mcp", "name": "x"}})
        self.assertDeny(decision, "invalid-request")

    def test_mcp_and_empty_paths_allow(self) -> None:
        self.assertAllow(self.request({"kind": "mcp", "name": "pixellab.create_character"}))
        self.assertAllow(self.request({"kind": "read", "paths": []}))

    def test_decision_shape(self) -> None:
        data = self.shell("ls").as_dict()
        self.assertEqual(data, {"version": 1, "decision": "allow", "reason": "safe", "message": policy.REASONS["safe"][1]})
        self.assertEqual(set(policy.REASONS), {
            "safe", "secret-read", "env-dump", "destructive-command", "force-push", "shared-stash", "publication",
            "policy-file-write", "sensitive-file-write", "outside-root-write", "invalid-request", "policy-error",
        })


class SecretReadTest(PolicyCase):
    def test_shell_readers_on_secret_files_deny(self) -> None:
        for command in (
            "cat release.keystore",
            "less ~/.ssh/id_ed25519",
            "head -c 100 export_credentials.cfg",
            "tail -f .env",
            "cat .env.local",
            "grep token ~/.aws/credentials",
            "rg -n host ~/.config/gh/hosts.yml",
            "base64 upload.jks",
            "xxd cert.p12",
            "strings signing.pem",
            "open server.key",
            "cat ~/.netrc",
            "cat ~/.git-credentials",
            "cat ~/.claude.json",
            "cat ~/Library/Application\\ Support/Steam/config/config.vdf",
            "cat ssfn1234567890",
            "cat config/secrets/api.json",
            "cat build/credentials/x.txt",
            "cat ~/.config/pixellab/token",
            "python3 tools/x.py --out .env",
            "node scripts/x.js ~/.ssh/id_rsa",
            "source .env",
            ". .env.production",
            "awk '{print}' release.keystore",
            "sed -n 1p .env",
            "cp release.keystore /tmp/copy",
            "wc -l < .env",
            "keytool -list -keystore release.keystore",
            "gh auth token",
            "echo $(cat ~/.ssh/id_ed25519)",
            "echo `cat .env`",
            "cd ~/.ssh && cat id_ed25519",
        ):
            with self.subTest(command=command):
                self.assertDeny(self.shell(command), "secret-read")

    def test_non_secret_reads_allow(self) -> None:
        for command in (
            "cat .env.example",
            "cat notes.txt",
            "cat docs/GDD.md",
            "grep -r secrets src/",
            "grep -rn credentials docs/",
            "rg -e token src/",
            "head -20 tools/build.sh",
            "ls ~/.ssh",
            "printenv HOME",
            "python3 tools/art/gen_placeholders.py",
            "keytool -genkeypair -keystore /tmp/debug.keystore -alias debug",
            "ssh -i ~/.ssh/id_ed25519 host true",
        ):
            with self.subTest(command=command):
                self.assertNotEqual(self.shell(command).reason, "secret-read")
        self.assertAllow(self.shell("cat .env.example"))
        self.assertAllow(self.shell("grep -r secrets src/"))

    def test_read_operations(self) -> None:
        self.assertAllow(self.read("notes.txt", "src/player.gd"))
        self.assertDeny(self.read("release.keystore"), "secret-read")
        self.assertDeny(self.read("notes.txt", ".env.local"), "secret-read")
        self.assertDeny(self.read(os.path.join(FAKE_HOME, ".ssh", "config")), "secret-read")
        self.assertDeny(self.read("~/.aws/credentials"), "secret-read")

    def test_symlink_alias_to_secret_is_caught(self) -> None:
        self.assertDeny(self.read("alias.txt"), "secret-read")
        self.assertDeny(self.shell("cat alias.txt"), "secret-read")

    def test_build_script_stays_allowed(self) -> None:
        self.assertAllow(self.shell("tools/build.sh android"))
        self.assertAllow(self.shell("GODOT_ANDROID_KEYSTORE_RELEASE_PATH=/x/release.keystore tools/build.sh android"))


class EnvDumpTest(PolicyCase):
    def test_dumps_deny(self) -> None:
        for command in (
            "env",
            "env | grep TOKEN",
            "env FOO=1",
            "printenv",
            "export",
            "export -p",
            "set",
            "declare -x",
            "declare",
            "typeset -p",
            "cat /proc/self/environ",
            "cat /proc/1234/environ",
            "sudo env",
        ):
            with self.subTest(command=command):
                self.assertDeny(self.shell(command), "env-dump")

    def test_non_dumps_allow(self) -> None:
        # printenv with a named variable is not a dump (documented decision).
        for command in (
            "printenv HOME",
            "env FOO=1 python3 x.py",
            "env -u FOO tools/test.sh",
            "export FOO=1",
            "set -e",
            "set -o pipefail",
            "declare -a arr",
            "declare -f",
        ):
            with self.subTest(command=command):
                self.assertAllow(self.shell(command))


class DestructiveTest(PolicyCase):
    def test_recursive_rm_on_protected_roots_denies(self) -> None:
        for command in (
            "rm -rf src",
            "rm -rf ./data/",
            "rm -rf ~",
            "rm -fr /",
            "rm -Rf art",
            "rm -r tests",
            "rm --recursive addons",
            "rm -rf *",
            "rm -rf src/*",
            "rm -rf .",
            "rm -rf ..",
            "rm -rf .git",
            "rm -rf .tools",
            "rm -rf docs tools",
            "rm -rf $HOME",
            "rm -rf " + self.root,
            "rm -rf " + self.root + "/",
            "rm -rf " + os.path.dirname(self.root),
            "rm -rfv -- src",
            "sudo rm -rf /",
            "rm -rf data",
            "find src -delete",
            "find . -name '*.pyc' -delete",
        ):
            with self.subTest(command=command):
                self.assertDeny(self.shell(command), "destructive-command")

    def test_rm_relative_to_subdirectory_cwd(self) -> None:
        self.assertDeny(self.shell("rm -rf ../src", cwd=os.path.join(self.root, "build")), "destructive-command")
        self.assertDeny(self.shell("rm -rf ..", cwd=os.path.join(self.root, "build")), "destructive-command")
        self.assertAllow(self.shell("rm -rf gameplay", cwd=os.path.join(self.root, "src")))

    def test_bounded_cleanup_allows(self) -> None:
        for command in (
            "rm -rf .godot artifacts build",
            "rm -rf .godot artifacts",
            "rm -rf .godot/*",
            "rm -rf build/web",
            "rm -rf /tmp/neondrift-scratch",
            "rm src/old.gd",
            "rm -f artifacts/*.log",
            "rm -rf *.log",
            "find .godot -delete",
        ):
            with self.subTest(command=command):
                self.assertAllow(self.shell(command))

    def test_git_destructive_denies(self) -> None:
        for command in (
            "git reset --hard HEAD~1",
            "git reset --hard",
            "git -C /x reset --hard",
            "git --no-pager -c core.pager=cat reset --hard",
            "git clean -fdx",
            "git clean -f",
            "git clean --force",
            "git checkout -- .",
            "git checkout .",
            "git checkout -- src",
            "git restore .",
            "git restore src",
            "git restore --source=HEAD~1 src/a.gd",
            "git restore --staged --worktree .",
            "git branch -D main",
            "git branch -d main",
            "git branch --delete main",
            "git update-ref -d refs/heads/main",
            "git worktree remove --force ../other",
            "git worktree remove -f ../other",
            "git filter-branch --all",
            "git push --delete origin feat",
            "git push origin :feat",
            "ls && git reset --hard",
            "(cd src && git reset --hard)",
            "if true; then git clean -fdx; fi",
            "bash -c 'git clean -fdx'",
        ):
            with self.subTest(command=command):
                self.assertDeny(self.shell(command), "destructive-command")

    def test_git_non_destructive_allows(self) -> None:
        for command in (
            "git status",
            "git log -5",
            "git diff --stat",
            "git reset HEAD~1",
            "git reset --soft HEAD~1",
            "git clean -n",
            "git checkout main",
            "git checkout -b feat/x",
            "git checkout -- src/player.gd",
            "git restore --staged .",
            "git restore src/player.gd",
            "git branch -D feat/x",
            "git branch -d feat/x",
            "git worktree remove ../other",
            "git worktree add ../other",
            "git commit -m 'feat: x'",
            "git add -A",
            "git fetch origin main",
            "git tag v1.0.0",
        ):
            with self.subTest(command=command):
                self.assertAllow(self.shell(command))


class SharedStashTest(PolicyCase):
    def test_denied_forms(self) -> None:
        for command in ("git stash", "git stash -u", "git stash pop", "git stash drop", "git stash clear", "git stash drop stash@{0}"):
            with self.subTest(command=command):
                self.assertDeny(self.shell(command), "shared-stash")

    def test_allowed_forms(self) -> None:
        for command in (
            "git stash push -u -m tag",
            "git stash push -m tag",
            "git stash apply 0123abcd",
            "git stash list --format='%H %gs'",
            "git stash show -p stash@{1}",
        ):
            with self.subTest(command=command):
                self.assertAllow(self.shell(command))


class PublicationTest(PolicyCase):
    def test_force_push_denies(self) -> None:
        for command in (
            "git push --force-with-lease",
            "git push --force-with-lease=main origin main",
            "git push --force origin main",
            "git push -f",
            "git push -fu origin feat",
            "git push origin +main",
            "git push --force-if-includes origin main",
        ):
            with self.subTest(command=command):
                self.assertDeny(self.shell(command), "force-push")

    def test_publication_asks(self) -> None:
        for command in (
            "git push --tags",
            "git push origin HEAD:refs/tags/v1",
            "gh pr merge 12",
            "gh pr close 12",
            "gh pr ready 12",
            "gh pr review 12 --approve",
            "gh pr comment 12 --body hi",
            "gh pr edit 12 --title x",
            "gh issue create --title x",
            "gh issue close 3",
            "gh issue comment 3 --body x",
            "gh issue edit 3",
            "gh release create v1.0.0",
            "gh release delete v1.0.0",
            "gh repo create x",
            "gh repo edit --visibility public",
            "gh repo delete x",
            "gh workflow run tests.yml",
            "gh api -X POST repos/x/y/issues",
            "gh api --method DELETE repos/x/y",
            "gh api --method=PATCH repos/x/y",
            "gh api -f title=x repos/x/y/issues",
            "gh api -F body=@x repos/x/y/issues",
            "gh api --input body.json repos/x/y/issues",
            "butler push build/web user/game:web",
            "steamcmd +login user +run_app_build x.vdf",
            'bash -c "git push --tags"',
        ):
            with self.subTest(command=command):
                self.assertAsk(self.shell(command), "publication")

    def test_branch_push_and_pr_create_allow(self) -> None:
        for command in ("git push", "git push -u origin feat", "git push origin HEAD:refs/heads/feat",
                        "gh pr create --fill", "bash -c 'git push'"):
            with self.subTest(command=command):
                self.assertEqual(self.shell(command).decision, "allow")

    def test_read_only_remote_commands_allow(self) -> None:
        for command in (
            "gh pr view 12",
            "gh pr list",
            "gh pr checks 12",
            "gh pr diff 12",
            "gh issue list",
            "gh issue view 3",
            "gh release list",
            "gh release view v1.0.0",
            "gh api repos/x/y",
            "gh api -X GET repos/x/y",
            "gh api --method GET repos/x/y/pulls",
            "gh run list",
            "gh auth status",
        ):
            with self.subTest(command=command):
                self.assertAllow(self.shell(command))

    def test_deny_beats_approval_across_segments(self) -> None:
        self.assertDeny(self.shell("git push && git reset --hard"), "destructive-command")
        self.assertDeny(self.shell("git reset --hard; git push"), "destructive-command")
        self.assertAsk(self.shell("echo hi > AGENTS.md && git push"), "policy-file-write")


class WriteTest(PolicyCase):
    def test_policy_file_writes_ask(self) -> None:
        for command in (
            "echo hi > AGENTS.md",
            "echo x>AGENTS.md",
            "echo x >> CLAUDE.md",
            "echo x &> CLAUDE.md",
            "sed -i '' s/a/b/ CLAUDE.md",
            "sed -i.bak s/a/b/ AGENTS.md",
            "sed -i -e s/a/b/ .claude/settings.json",
            "perl -pi -e 's/a/b/' CLAUDE.md",
            "tee .claude/settings.json",
            "tee -a .github/workflows/tests.yml",
            "mv CLAUDE.md CLAUDE.old",
            "mv notes.txt CLAUDE.md",
            "cp notes.txt .claude/settings.json",
            "cp -r x .grok/",
            "rm CLAUDE.md",
            "rm -rf .claude",
            "rm -rf .agents",
            "touch tools/agent_hooks/extra.py",
            "truncate -s 0 AGENTS.md",
            "ln -s x .gitattributes",
            "chmod +x tools/agent_hooks/guard.py",
            "install -m 644 x tools/agent_hooks/x.py",
            "rsync -a x/ .claude/",
            "dd if=/dev/zero of=CLAUDE.md",
            "cat <<'EOF' > CLAUDE.md\nrm -rf src\nEOF\n",
            "cat > .github/workflows/ci.yml <<EOF\nname: x\nEOF",
            "echo hi > src/CLAUDE.md",
            "echo hi > policy-alias.md",
        ):
            with self.subTest(command=command):
                self.assertAsk(self.shell(command), "policy-file-write")
        for path in (
            ".claude/settings.json",
            "AGENTS.md",
            "CLAUDE.md",
            "docs/CLAUDE.md",
            ".grok/agents/x.md",
            ".agents/skills/x/SKILL.md",
            "tools/agent_hooks/policy.py",
            ".github/workflows/tests.yml",
            ".gitattributes",
            os.path.join(self.root, ".claude", "settings.json"),
            "policy-alias.md",
        ):
            with self.subTest(path=path):
                self.assertAsk(self.write(path), "policy-file-write")

    def test_sensitive_file_writes_ask(self) -> None:
        for command in (
            "echo x > .env",
            "echo x > .env.local",
            "tee export_credentials.cfg",
            "keytool -genkeypair -keystore new.keystore -alias x",
            "cp notes.txt keys/new.p12",
            "mv x secrets/x",
        ):
            with self.subTest(command=command):
                self.assertAsk(self.shell(command), "sensitive-file-write")
        self.assertAsk(self.write("release.keystore"), "sensitive-file-write")
        self.assertAsk(self.write(".env"), "sensitive-file-write")
        self.assertAsk(self.write("alias.txt"), "sensitive-file-write")
        self.assertAllow(self.write(".env.example"))

    def test_outside_root_writes_ask(self) -> None:
        for command in (
            "echo hi > /Users/someone/other",
            "tee -a ~/.zshrc",
            "cp notes.txt ~/Desktop/",
            "mv notes.txt /opt/x",
            "rm -rf ~/Library/Caches/neondrift",
            "echo x > /etc/hosts",
            "touch $HOME/x",
        ):
            with self.subTest(command=command):
                self.assertAsk(self.shell(command), "outside-root-write")
        self.assertAsk(self.write("/Users/someone/other/file"), "outside-root-write")
        self.assertAsk(self.write(os.path.join(FAKE_HOME, "x")), "outside-root-write")
        # A sibling of the root is outside it. Use a fake root that is not under a tmp root:
        # on Linux the test root itself lives in /tmp, where writes are allowed by design.
        sibling = policy.evaluate(
            {
                "version": 1,
                "root": "/srv/work/neondrift",
                "cwd": "/srv/work/neondrift",
                "operation": {"kind": "write", "paths": ["/srv/work/sibling.txt"]},
            }
        )
        self.assertAsk(sibling, "outside-root-write")

    def test_inside_root_and_tmp_writes_allow(self) -> None:
        for command in (
            "echo hi > /tmp/x",
            "echo hi > /private/tmp/x",
            "echo hi > notes.txt",
            "echo hi >> src/new.gd",
            "tee artifacts/run.log",
            "tools/godot.sh --headless --import > artifacts/import.log 2>&1",
            "cmd 2>&1 | tee out.log",
            "sed -i '' s/a/b/ src/player.gd",
            "mv src/a.gd src/b.gd",
            "cp notes.txt build/",
            "ln -sf /primary/.tools .tools",
            "mkdir -p .neondrift",
            "cat <<EOF\ngit push\nEOF\necho ok",
            "cat > data/items/new.tres <<'EOF'\n[gd_resource]\nEOF",
        ):
            with self.subTest(command=command):
                self.assertAllow(self.shell(command))
        self.assertAllow(self.write("/tmp/x"))
        self.assertAllow(self.write("src/player.gd", "data/balance/enemies.csv", "docs/GDD.md"))
        self.assertAllow(self.write(os.path.join(self.root, "artifacts", "run.gif")))

    def test_tmpdir_env_counts_as_tmp(self) -> None:
        with mock.patch.dict(os.environ, {"TMPDIR": "/var/folders/zz/T"}):
            self.assertAllow(self.write("/var/folders/zz/T/x"))
            self.assertAllow(self.shell("echo x > $TMPDIR/x"))


class ShellParsingTest(PolicyCase):
    def test_unbalanced_quotes_deny(self) -> None:
        self.assertDeny(self.shell("echo 'unbalanced"), "invalid-request")
        self.assertDeny(self.shell('echo "unbalanced'), "invalid-request")
        self.assertDeny(self.shell("echo $(cat x"), "invalid-request")
        self.assertDeny(self.shell("echo `cat x"), "invalid-request")

    def test_depth_limit_denies(self) -> None:
        nested = "ls"
        for _ in range(policy.MAX_DEPTH + 1):
            nested = "bash -c '" + nested.replace("'", "'\\''") + "'"
        self.assertDeny(self.shell(nested), "invalid-request")
        self.assertAllow(self.shell("bash -c 'bash -c ls'"))

    def test_quoted_operators_are_data(self) -> None:
        self.assertAllow(self.shell("grep '>' CLAUDE.md"))
        self.assertAllow(self.shell("echo 'rm -rf src'"))
        self.assertAllow(self.shell('echo "git push"'))
        self.assertAllow(self.shell("echo 'a; git reset --hard'"))

    def test_heredoc_body_is_data(self) -> None:
        self.assertAllow(self.shell("cat <<EOF\ngit reset --hard\nrm -rf src\nEOF\nls"))
        self.assertAllow(self.shell("cat <<-'END'\n\tgit push\n\tEND\n"))
        self.assertAsk(self.shell("cat <<EOF > AGENTS.md\nhello\nEOF"), "policy-file-write")
        self.assertDeny(self.shell("cat <<EOF\nx\nEOF\ngit reset --hard"), "destructive-command")

    def test_fd_redirections_are_not_files(self) -> None:
        self.assertAllow(self.shell("ls 2>&1"))
        self.assertAllow(self.shell("ls >&2"))
        self.assertAllow(self.shell("ls 1>&2 2>/dev/null"))
        self.assertAllow(self.shell("echo 2>/tmp/err"))

    def test_wrappers_are_stripped(self) -> None:
        self.assertDeny(self.shell("sudo -u root git reset --hard"), "destructive-command")
        self.assertDeny(self.shell("command git reset --hard"), "destructive-command")
        self.assertDeny(self.shell("nice -n 10 git reset --hard"), "destructive-command")
        self.assertDeny(self.shell("time git reset --hard"), "destructive-command")
        self.assertDeny(self.shell("xargs -n 1 git reset --hard"), "destructive-command")
        self.assertDeny(self.shell("env FOO=1 git reset --hard"), "destructive-command")
        self.assertDeny(self.shell("FOO=1 BAR=2 git reset --hard"), "destructive-command")
        self.assertDeny(self.shell("exec git reset --hard"), "destructive-command")

    def test_cd_tracking_resolves_later_segments(self) -> None:
        self.assertDeny(self.shell("cd build && rm -rf ../src"), "destructive-command")
        self.assertAllow(self.shell("cd build && rm -rf web"))

    def test_arithmetic_and_loops_do_not_confuse_the_splitter(self) -> None:
        self.assertAllow(self.shell("echo $((1+2))"))
        self.assertAllow(self.shell("for f in a b; do echo $f; done"))
        self.assertAllow(self.shell("while read l; do echo $l; done < notes.txt"))
        self.assertAllow(self.shell("arr=(a b); echo ${arr[0]}"))
        self.assertAllow(self.shell("{ ls; ls -la; }"))
        self.assertAllow(self.shell("! ls"))

    def test_shell_wrapper_without_c_is_opaque(self) -> None:
        # bash script.sh cannot be inspected: allowed by ADR D09 (documented limitation).
        self.assertAllow(self.shell("bash tools/test.sh"))
        self.assertAllow(self.shell("bash -x tools/lint.sh"))


class ToolingAllowTest(PolicyCase):
    def test_everyday_project_commands_allow(self) -> None:
        for command in (
            "tools/godot.sh --headless --import",
            "tools/godot.sh --version",
            "tools/test.sh",
            "tools/lint.sh",
            "tools/build.sh android",
            "tools/build.sh windows",
            "tools/agent.sh check",
            "tools/agent.sh bootstrap --skip-import",
            "python3 tools/art/gen_placeholders.py --all",
            ".venv/bin/gdlint src",
            "ffmpeg -i artifacts/run.mp4 artifacts/run.gif",
            "python3 -m unittest discover -s tools/agent_hooks/tests",
            "ls -la && git status && git diff --stat",
            "some-unknown-tool --flag value",
            "echo hello world",
            "git stash list",
            "cat project.godot | head -20",
            "rg 'class_name' src/ -l",
            "grep -rn 'preload' src/gameplay",
        ):
            with self.subTest(command=command):
                self.assertAllow(self.shell(command))


if __name__ == "__main__":
    unittest.main()
