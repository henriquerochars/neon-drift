"""D12 selection table (ADR 0007) and the gate's ignore list."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from agent.lib.selection import (  # noqa: E402
    CHECK_ORDER,
    checks_for_path,
    filter_relevant,
    is_relevant,
    normalize_path,
    record_advisory,
    select_checks,
)

ALL = list(CHECK_ORDER)
CODE = ["lint", "godot-tests"]


class SelectionTableTest(unittest.TestCase):
    def test_prose_outside_docs_selects_nothing(self) -> None:
        self.assertEqual(select_checks(["README.md", "LICENSE", "CHANGELOG.md", "art/LICENSE"]), [])
        self.assertEqual(select_checks(["LICENSE-ART.txt", "src/net/README.md", ".github/README.md"]), [])

    def test_docs_select_only_the_record_check(self) -> None:
        self.assertEqual(select_checks(["docs/GDD.md", "README.md", "LICENSE"]), ["record"])
        self.assertEqual(select_checks(["docs/adr/0007.md", "docs/qa/report.txt", "docs/qa/x.png"]), ["record"])

    def test_root_agent_files_are_harness_not_docs(self) -> None:
        for path in (
            "AGENTS.md", "CLAUDE.md", "docs/AGENTS.md", "tools/check_harness.py",
            ".agents/model_routing.json",
        ):
            self.assertEqual(select_checks([path]), ["harness"], path)

    def test_code_paths_select_lint_and_tests(self) -> None:
        for path in (
            "src/gameplay/player/player.gd",
            "tests/unit/foo_test.gd",
            "data/items/sword.tres",
            "project.godot",
            "other/thing.tscn",
            "shader/x.gdshader",
            "src/net/x.gd.uid",
        ):
            self.assertEqual(select_checks([path]), CODE, path)

    def test_balance_csv(self) -> None:
        self.assertEqual(select_checks(["data/balance/enemies.csv"]), ["lint", "balance", "godot-tests"])
        self.assertEqual(select_checks(["data/balance/notes.txt"]), CODE)

    def test_art_paths(self) -> None:
        self.assertEqual(select_checks(["art/dogs/pug.png"]), ["lint", "art", "godot-tests"])
        self.assertEqual(select_checks(["art/dogs/pug.png.import"]), ["lint", "art", "godot-tests"])
        self.assertEqual(select_checks(["tools/art/validate.py"]), ["lint", "art", "godot-tests"])
        self.assertEqual(select_checks(["tools/art/audit_resources.gd"]), ["lint", "art", "godot-tests"])

    def test_harness_paths(self) -> None:
        for path in (
            "tools/agent/check_changed.py",
            "tools/agent/lib/selection.py",
            "tools/agent_hooks/guard.py",
            ".claude/settings.json",
            ".claude/agents/architect.md",
            ".grok/skills/x/SKILL.md",
            ".agents/skills/x/SKILL.md",
        ):
            self.assertEqual(select_checks([path]), ["harness"], path)

    def test_toolchain_paths_select_everything(self) -> None:
        for path in (
            "tools/test.sh",
            "tools/agent.sh",
            ".github/workflows/test.yml",
            "export_presets.cfg",
            "addons/gdUnit4/plugin.cfg",
            "tools/playtest/bot.gd",
            "tools/data/import_balance.gd",
        ):
            self.assertEqual(select_checks([path]), ALL, path)

    def test_unknown_paths_select_everything(self) -> None:
        self.assertEqual(select_checks(["tools/check_layers.py"]), ALL)
        self.assertEqual(select_checks(["Makefile"]), ALL)
        self.assertEqual(select_checks(["tools/art"]), ["lint", "art", "godot-tests"])

    def test_union_is_ordered_by_check_order(self) -> None:
        selected = select_checks(["data/balance/a.csv", "art/x.png", "tools/agent/x.py", "docs/a.md"])
        self.assertEqual(selected, ["harness", "record", "lint", "balance", "art", "godot-tests"])

    def test_rename_counts_both_paths(self) -> None:
        self.assertEqual(select_checks(["docs/old.md", "src/new.gd"]), ["record", *CODE])
        self.assertEqual(
            select_checks(["data/balance/old.csv", "docs/new.md"]), ["record", "lint", "balance", "godot-tests"]
        )

    def test_deleted_path_still_selects(self) -> None:
        self.assertEqual(checks_for_path("src/gone.gd"), frozenset(CODE))


class IgnoreListTest(unittest.TestCase):
    def test_ignored_paths(self) -> None:
        for path in (
            ".godot/imported/x.ctex",
            ".neondrift/gate/latest.json",
            ".tools/Godot.app/x",
            ".venv/bin/python",
            "artifacts/tests.log",
            "build/windows/x.zip",
            "reports/x.html",
            "src/debug.log",
            "art/.DS_Store",
            ".DS_Store",
        ):
            self.assertFalse(is_relevant(path), path)
            self.assertEqual(checks_for_path(path), frozenset(), path)

    def test_similar_names_are_not_ignored(self) -> None:
        self.assertTrue(is_relevant("src/builder.gd"))
        self.assertTrue(is_relevant("src/logger.gd"))
        self.assertTrue(is_relevant("tools/reports_tool.py"))

    def test_filter_relevant_normalises_and_sorts(self) -> None:
        self.assertEqual(filter_relevant(["./src/b.gd", "src/a.gd", "src/a.gd", ".godot/x"]), ["src/a.gd", "src/b.gd"])
        self.assertEqual(normalize_path("./docs/x.md/"), "docs/x.md")

    def test_paths_with_spaces(self) -> None:
        self.assertEqual(select_checks(["src/my file.gd"]), CODE)
        self.assertEqual(select_checks(["docs/my notes.md"]), ["record"])


class RecordAdvisoryTest(unittest.TestCase):
    def test_source_or_content_without_the_record_reminds(self) -> None:
        for paths in (["src/gameplay/hub/hub_view.gd"], ["data/characters/toby.tres", "docs/GDD.md"]):
            advisory = record_advisory(paths)
            self.assertIsNotNone(advisory, paths)
            assert advisory is not None
            self.assertIn("docs/STATUS.md", advisory)
            self.assertIn("1 file(s)", advisory)

    def test_record_update_or_unrelated_paths_stay_silent(self) -> None:
        self.assertIsNone(record_advisory(["src/gameplay/hub/hub_view.gd", "./docs/STATUS.md"]))
        self.assertIsNone(record_advisory(["data/balance/enemies.csv", "tests/unit/x_test.gd", "docs/GDD.md"]))
        self.assertIsNone(record_advisory(["src/debug.log", ".godot/x", "art/dogs/pug.png"]))
        self.assertIsNone(record_advisory([]))

    def test_advisory_never_selects_a_check(self) -> None:
        self.assertEqual(select_checks(["src/a.gd"]), CODE)


if __name__ == "__main__":
    unittest.main()
