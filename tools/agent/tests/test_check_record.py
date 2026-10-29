"""Project record check: source areas in docs/STATUS.md, docs and ADR indexes, local links."""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from agent import check_record as record  # noqa: E402

STATUS = """# Status

| Area | Code |
|---|---|
| Core | `src/core/` |
| Players | `src/gameplay/players/` |
| HUD | `src/ui/main/` |

Contract: [players](PLAYERS_API.md#movement).
"""
INDEX = """# Docs

- [Status](STATUS.md)
- [Players](PLAYERS_API.md)
- [ADRs](adr/README.md)
- [QA evidence](qa/)
- [Home](https://example.com/x.md)
"""
ADR_INDEX = """# ADRs

- [0001](0001-first.md)
"""


class RecordFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        for folder in ("src/core", "src/gameplay/players", "src/ui/main", "docs/adr", "docs/qa/run-1"):
            (self.root / folder).mkdir(parents=True)
        self.write("docs/STATUS.md", STATUS)
        self.write("docs/README.md", INDEX)
        self.write("docs/PLAYERS_API.md", "# Players\n")
        self.write("docs/adr/README.md", ADR_INDEX)
        self.write("docs/adr/0001-first.md", "# 0001\n")
        self.write("docs/qa/run-1/README.md", "# Run\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, relative: str, text: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def problems(self) -> list[str]:
        return record.check(self.root)


class SourceAreaTest(RecordFixture):
    def test_mapped_repository_passes(self) -> None:
        self.assertEqual(self.problems(), [])

    def test_areas_are_layers_and_feature_folders(self) -> None:
        (self.root / "src" / "net").mkdir()
        (self.root / "src" / "gameplay" / ".hidden").mkdir()
        self.assertEqual(
            record.source_areas(self.root),
            ["src/core/", "src/gameplay/players/", "src/net/", "src/ui/main/"],
        )

    def test_new_feature_folder_must_be_mapped(self) -> None:
        (self.root / "src" / "gameplay" / "arsenal").mkdir()
        self.assertEqual(
            self.problems(), ["docs/STATUS.md does not map the source area `src/gameplay/arsenal/`"]
        )

    def test_a_bare_mention_without_backticks_does_not_count(self) -> None:
        (self.root / "src" / "net").mkdir()
        self.write("docs/STATUS.md", STATUS + "\nThe src/net/ layer is mentioned in prose.\n")
        self.assertIn("docs/STATUS.md does not map the source area `src/net/`", self.problems())


class IndexTest(RecordFixture):
    def test_new_top_level_doc_must_be_indexed(self) -> None:
        self.write("docs/FEATURES.md", "# Features\n")
        self.assertEqual(self.problems(), ["docs/README.md does not link docs/FEATURES.md"])

    def test_new_docs_folder_must_be_indexed(self) -> None:
        self.write("docs/plans/a.plan.md", "# Plan\n")
        self.assertEqual(self.problems(), ["docs/README.md does not link the folder docs/plans/"])

    def test_a_link_inside_a_folder_covers_the_folder(self) -> None:
        self.write("docs/plans/a.plan.md", "# Plan\n")
        self.write("docs/README.md", INDEX + "- [A plan](plans/a.plan.md)\n")
        self.assertEqual(self.problems(), [])

    def test_new_adr_must_be_indexed(self) -> None:
        self.write("docs/adr/0002-second.md", "# 0002\n")
        self.assertEqual(self.problems(), ["docs/adr/README.md does not link docs/adr/0002-second.md"])

    def test_missing_record_documents_are_reported_first(self) -> None:
        (self.root / "docs" / "STATUS.md").unlink()
        self.assertEqual(self.problems(), ["docs/STATUS.md is missing"])


class LinkTest(RecordFixture):
    def test_broken_relative_link_fails(self) -> None:
        self.write("docs/STATUS.md", STATUS + "\nSee [gone](qa/gone/README.md).\n")
        self.assertEqual(self.problems(), ["docs/STATUS.md links to a missing path: qa/gone/README.md"])

    def test_external_anchor_and_fenced_links_are_ignored(self) -> None:
        extra = "\n[top](#status) [web](https://example.com/missing.md)\n\n```\n[x](missing.md)\n```\n"
        self.write("docs/STATUS.md", STATUS + extra)
        self.assertEqual(self.problems(), [])

    def test_percent_encoded_and_titled_links_resolve(self) -> None:
        self.write("docs/qa/my run.md", "# Run\n")
        self.write("docs/STATUS.md", STATUS + '\n[run](qa/my%20run.md "Run") [b](<qa/my run.md>) [c](<qa/no such.md>)\n')
        self.assertEqual(self.problems(), ["docs/STATUS.md links to a missing path: qa/no such.md"])

    def test_local_links_strip_fragments(self) -> None:
        self.assertEqual(
            record.local_links('[a](A.md#x) [b](#y) [c](mailto:me@x.y) [d](../src/) [e](<my run.md>) [f](g.md "T")'),
            ["A.md", "../src/", "my run.md", "g.md"],
        )


class CliTest(RecordFixture):
    def run_main(self) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = record.main(["--root", str(self.root)])
        return code, out.getvalue()

    def test_pass_exit_zero(self) -> None:
        code, out = self.run_main()
        self.assertEqual(code, 0, out)
        self.assertIn("PASS: record maps 3 source areas", out)

    def test_drift_exit_one_with_guidance(self) -> None:
        (self.root / "src" / "gameplay" / "arsenal").mkdir()
        code, out = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("FAIL: docs/STATUS.md does not map the source area `src/gameplay/arsenal/`", out)
        self.assertIn("AGENTS.md", out)


if __name__ == "__main__":
    unittest.main()
