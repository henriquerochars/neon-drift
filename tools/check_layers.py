#!/usr/bin/env python3
"""Enforce the Neon Drift layer graph on everything under src/.

Allowed direct edges (AGENTS.md rule 7, docs/ARCHITECTURE.md):

    gameplay -> net -> core
    gameplay -> data -> core
    audio -> core
    ui -> gameplay, ui -> audio

The allowed set is the transitive closure of those edges, so `ui` may also reach
`net`, `data` and `core`, and `gameplay` may reach `core`. Same-layer references
are always fine. `addons/` is third-party and may be used by any layer. `tests/`
and `tools/` are not checked (they may reference anything), but `src/` must never
reference them.

A reference is any of:
  * a `res://` or `uid://` string in a .gd file (preload, load, ResourceLoader,
    extends "res://...") or in a .gdshader #include;
  * an `[ext_resource]` path/uid or `script_class` in a .tscn/.tres file;
  * an identifier in GDScript code that names a global `class_name` or an
    autoload declared in project.godot.
References to assets under data/ or art/ are followed through the asset's own
references, so a core script cannot reach gameplay by preloading a .tres.

Cycles are rejected at two levels: between layers, and between files linked by
hard load-time dependencies (preload, extends "res://...", scene/resource
ext_resource), which Godot cannot resolve.

Exit codes: 0 clean, 1 violations found, 2 usage or internal error.
Python 3.9+, standard library only.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

LAYERS: Tuple[str, ...] = ("core", "net", "data", "audio", "gameplay", "ui")
BASE_EDGES: Dict[str, Set[str]] = {
    "core": set(),
    "net": {"core"},
    "data": {"core"},
    "audio": {"core"},
    "gameplay": {"net", "data"},
    "ui": {"gameplay", "audio"},
}
SOURCE_SUFFIXES: Tuple[str, ...] = (".gd", ".tscn", ".tres", ".gdshader", ".gdshaderinc")
ASSET_ROOTS: Tuple[str, ...] = ("data", "art")
FREE_ROOTS: Tuple[str, ...] = ("addons",)
FORBIDDEN_ROOTS: Tuple[str, ...] = ("tests", "tools")
SKIP_DIRS: Set[str] = {".godot", ".git", ".claude", ".tools", ".venv", "build", "artifacts", "reports"}

RES_PREFIX = "res://"
UID_PREFIX = "uid://"
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
CLASS_NAME_RE = re.compile(
    r"^[ \t]*(?:@[A-Za-z_]+(?:\([^)\n]*\))?[ \t]+)*class_name[ \t]+([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)
EXT_RESOURCE_RE = re.compile(r"^\[ext_resource\b([^\]]*)\]", re.MULTILINE)
ATTR_RE = re.compile(r'\b(path|uid)="([^"]*)"')
SCRIPT_CLASS_RE = re.compile(r'\bscript_class="([A-Za-z_][A-Za-z0-9_]*)"')
HEADER_UID_RE = re.compile(r'^\[gd_(?:scene|resource)\b[^\]]*\buid="(uid://[^"]+)"', re.MULTILINE)
SHADER_INCLUDE_RE = re.compile(r'^[ \t]*#include[ \t]+"([^"]+)"', re.MULTILINE)
IMPORT_UID_RE = re.compile(r'^uid="(uid://[^"]+)"', re.MULTILINE)
AUTOLOAD_LINE_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)="\*?(res://[^"]+)"')
HARD_BEFORE_STRING_RE = re.compile(r"(?:\bpreload[ \t]*\([ \t]*|\bextends[ \t]+)$")


def allowed_closure() -> Dict[str, Set[str]]:
    """Transitive closure of BASE_EDGES."""
    closure: Dict[str, Set[str]] = {}
    for layer in LAYERS:
        seen: Set[str] = set()
        stack: List[str] = list(BASE_EDGES[layer])
        while stack:
            nxt = stack.pop()
            if nxt in seen:
                continue
            seen.add(nxt)
            stack.extend(BASE_EDGES[nxt])
        closure[layer] = seen
    return closure


@dataclass
class Ref:
    """One outgoing reference found in a file."""

    target: str  # repo-relative path of the referenced file
    line: int
    how: str  # human description, e.g. 'preload("res://...")'
    hard: bool  # load-time dependency that participates in file-cycle detection


@dataclass
class Lexed:
    """A GDScript file split into code (strings and comments blanked) and string literals."""

    code: str
    strings: List[Tuple[str, int, bool]] = field(default_factory=list)  # value, line, hard


def lex_gdscript(text: str) -> Lexed:
    """Blank out comments and string literals, keep newlines so offsets map to lines."""
    out: List[str] = []
    strings: List[Tuple[str, int, bool]] = []
    i = 0
    n = len(text)
    line = 1
    while i < n:
        ch = text[i]
        if ch == "#":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        prefix_len = 0
        if ch in "r&^" and i + 1 < n and text[i + 1] in "\"'":
            prefix_len = 1
        if ch in "\"'" or prefix_len:
            start_line = line
            raw = ch == "r"
            q_start = i + prefix_len
            quote = text[q_start]
            triple = text[q_start:q_start + 3] == quote * 3
            delim = quote * 3 if triple else quote
            code_before = "".join(out[-64:]).split("\n")[-1]
            hard = HARD_BEFORE_STRING_RE.search(code_before) is not None
            j = q_start + len(delim)
            value: List[str] = []
            while j < n:
                if text[j] == "\\" and j + 1 < n:
                    value.append(text[j + 1] if not raw else text[j:j + 2])
                    j += 2
                    continue
                if text.startswith(delim, j):
                    j += len(delim)
                    break
                if text[j] == "\n" and not triple:
                    break
                value.append(text[j])
                j += 1
            segment = text[i:j]
            line += segment.count("\n")
            out.append("".join("\n" if c == "\n" else " " for c in segment))
            strings.append(("".join(value), start_line, hard))
            i = j
            continue
        if ch == "\n":
            line += 1
        out.append(ch)
        i += 1
    return Lexed(code="".join(out), strings=strings)


class Project:
    """Index of the repository: files, class names, autoloads and UIDs."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.class_to_file: Dict[str, str] = {}
        self.file_to_classes: Dict[str, Set[str]] = {}
        self.autoloads: Dict[str, str] = {}
        self.uid_to_file: Dict[str, str] = {}
        self.errors: List[str] = []
        self._asset_cache: Dict[str, List[Ref]] = {}
        self._index()

    # ---- indexing -------------------------------------------------------------------
    def _walk(self) -> Iterable[Path]:
        for path in sorted(self.root.rglob("*")):
            rel_parts = path.relative_to(self.root).parts
            if any(part in SKIP_DIRS for part in rel_parts):
                continue
            if path.is_file():
                yield path

    def rel(self, path: Path) -> str:
        return path.relative_to(self.root).as_posix()

    def _index(self) -> None:
        for path in self._walk():
            rel = self.rel(path)
            if path.suffix == ".uid":
                uid = path.read_text(encoding="utf-8", errors="replace").strip()
                if uid.startswith(UID_PREFIX):
                    self.uid_to_file[uid] = rel[: -len(".uid")]
            elif path.suffix == ".import":
                match = IMPORT_UID_RE.search(path.read_text(encoding="utf-8", errors="replace"))
                if match:
                    self.uid_to_file[match.group(1)] = rel[: -len(".import")]
            elif path.suffix in (".tscn", ".tres"):
                match = HEADER_UID_RE.search(path.read_text(encoding="utf-8", errors="replace"))
                if match:
                    self.uid_to_file[match.group(1)] = rel
            elif path.suffix == ".gd":
                code = lex_gdscript(path.read_text(encoding="utf-8", errors="replace")).code
                for match in CLASS_NAME_RE.finditer(code):
                    name = match.group(1)
                    previous = self.class_to_file.get(name)
                    if previous and previous != rel:
                        self.errors.append(
                            f"{rel}: class_name {name} already declared in {previous}"
                        )
                    self.class_to_file[name] = rel
                    self.file_to_classes.setdefault(rel, set()).add(name)
        project_file = self.root / "project.godot"
        if project_file.is_file():
            in_autoload = False
            for raw_line in project_file.read_text(encoding="utf-8").splitlines():
                stripped = raw_line.strip()
                if stripped.startswith("["):
                    in_autoload = stripped == "[autoload]"
                    continue
                if in_autoload:
                    match = AUTOLOAD_LINE_RE.match(stripped)
                    if match:
                        self.autoloads[match.group(1)] = match.group(2)[len(RES_PREFIX):]

    # ---- reference resolution -------------------------------------------------------
    def resolve(self, reference: str) -> Optional[str]:
        """Map a res:// or uid:// string to a repo-relative path, or None if not a file ref."""
        reference = reference.strip()
        if reference.startswith(UID_PREFIX):
            return self.uid_to_file.get(reference)
        if reference.startswith(RES_PREFIX):
            return reference[len(RES_PREFIX):].split("::", 1)[0]
        return None

    def refs_of(self, rel: str) -> List[Ref]:
        path = self.root / rel
        if not path.is_file():
            return []
        text = path.read_text(encoding="utf-8", errors="replace")
        refs: List[Ref] = []
        if path.suffix == ".gd":
            lexed = lex_gdscript(text)
            for value, line, hard in lexed.strings:
                target = self.resolve(value)
                if target is not None:
                    kind = "preload/extends" if hard else "load"
                    refs.append(Ref(target, line, f'{kind} "{value}"', hard))
            own = self.file_to_classes.get(rel, set())
            code = lexed.code
            line_starts = [0] + [m.end() for m in re.finditer("\n", code)]
            for match in IDENT_RE.finditer(code):
                name = match.group(0)
                if name in own:
                    continue
                start = match.start()
                if start > 0 and code[start - 1] == ".":
                    continue
                target = self.class_to_file.get(name)
                how = f"class {name}"
                if target is None and name in self.autoloads:
                    target = self.autoloads[name]
                    how = f"autoload {name}"
                if target is None or target == rel:
                    continue
                line = _line_of(line_starts, start)
                refs.append(Ref(target, line, how, False))
        elif path.suffix in (".tscn", ".tres"):
            line_starts = [0] + [m.end() for m in re.finditer("\n", text)]
            for match in EXT_RESOURCE_RE.finditer(text):
                attrs = dict(ATTR_RE.findall(match.group(1)))
                value = attrs.get("path") or attrs.get("uid") or ""
                target = self.resolve(value)
                if target is None and attrs.get("uid"):
                    target = self.resolve(attrs["uid"])
                if target is not None:
                    line = _line_of(line_starts, match.start())
                    refs.append(Ref(target, line, f'ext_resource "{value}"', True))
            for match in SCRIPT_CLASS_RE.finditer(text):
                target = self.class_to_file.get(match.group(1))
                if target is not None and target != rel:
                    line = _line_of(line_starts, match.start())
                    refs.append(Ref(target, line, f"script_class {match.group(1)}", False))
        elif path.suffix in (".gdshader", ".gdshaderinc"):
            line_starts = [0] + [m.end() for m in re.finditer("\n", text)]
            for match in SHADER_INCLUDE_RE.finditer(text):
                target = self.resolve(match.group(1))
                if target is not None:
                    line = _line_of(line_starts, match.start())
                    refs.append(Ref(target, line, f'#include "{match.group(1)}"', True))
        return refs

    def src_refs_through_asset(self, asset: str, trail: Tuple[str, ...] = ()) -> List[Ref]:
        """References from an asset (data/, art/) into src/, following asset-to-asset links."""
        if asset in self._asset_cache:
            return self._asset_cache[asset]
        if asset in trail:
            return []
        found: List[Ref] = []
        for ref in self.refs_of(asset):
            root = ref.target.split("/", 1)[0]
            if root == "src":
                found.append(Ref(ref.target, ref.line, f"{asset} -> {ref.how}", False))
            elif root in ASSET_ROOTS:
                found.extend(self.src_refs_through_asset(ref.target, trail + (asset,)))
        self._asset_cache[asset] = found
        return found


def _line_of(line_starts: List[int], offset: int) -> int:
    lo, hi = 0, len(line_starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if line_starts[mid] <= offset:
            lo = mid
        else:
            hi = mid - 1
    return lo + 1


def layer_of(rel: str) -> Optional[str]:
    parts = rel.split("/")
    if len(parts) >= 3 and parts[0] == "src":
        return parts[1]
    return None


def find_cycles(graph: Dict[str, Set[str]]) -> List[List[str]]:
    """Strongly connected components with more than one node, or a self-loop (Tarjan)."""
    index_of: Dict[str, int] = {}
    low: Dict[str, int] = {}
    on_stack: Set[str] = set()
    stack: List[str] = []
    result: List[List[str]] = []
    counter = [0]

    def visit(node: str) -> None:
        index_of[node] = low[node] = counter[0]
        counter[0] += 1
        stack.append(node)
        on_stack.add(node)
        for nxt in sorted(graph.get(node, set())):
            if nxt not in index_of:
                visit(nxt)
                low[node] = min(low[node], low[nxt])
            elif nxt in on_stack:
                low[node] = min(low[node], index_of[nxt])
        if low[node] == index_of[node]:
            component: List[str] = []
            while True:
                top = stack.pop()
                on_stack.discard(top)
                component.append(top)
                if top == node:
                    break
            if len(component) > 1 or node in graph.get(node, set()):
                result.append(sorted(component))

    sys.setrecursionlimit(max(10000, sys.getrecursionlimit()))
    for node in sorted(graph):
        if node not in index_of:
            visit(node)
    return result


def check(root: Path, verbose: bool) -> int:
    src = root / "src"
    if not src.is_dir():
        print(f"check_layers: no src/ directory under {root}", file=sys.stderr)
        return 2
    project = Project(root)
    closure = allowed_closure()
    violations: List[str] = list(project.errors)
    layer_graph: Dict[str, Set[str]] = {layer: set() for layer in LAYERS}
    file_graph: Dict[str, Set[str]] = {}
    edge_count = 0

    sources = [
        p for p in sorted(src.rglob("*"))
        if p.is_file() and p.suffix in SOURCE_SUFFIXES
    ]
    for path in sources:
        rel = project.rel(path)
        layer = layer_of(rel)
        if layer not in LAYERS:
            violations.append(
                f"{rel}: not inside a known layer folder (src/{{{','.join(LAYERS)}}}/)"
            )
            continue
        refs = project.refs_of(rel)
        expanded: List[Ref] = []
        for ref in refs:
            expanded.append(ref)
            if ref.target.split("/", 1)[0] in ASSET_ROOTS:
                for via in project.src_refs_through_asset(ref.target):
                    expanded.append(Ref(via.target, ref.line, f"{ref.how} -> {via.how}", False))
        for ref in expanded:
            if ref.hard and ref.target.startswith("src/"):
                file_graph.setdefault(rel, set()).add(ref.target)
            root_dir = ref.target.split("/", 1)[0]
            if root_dir in FREE_ROOTS or root_dir in ASSET_ROOTS:
                continue
            if root_dir in FORBIDDEN_ROOTS:
                violations.append(
                    f"{rel}:{ref.line}: src/ must not reference {root_dir}/ ({ref.how})"
                )
                continue
            target_layer = layer_of(ref.target)
            if root_dir != "src" or target_layer is None:
                continue
            if target_layer not in LAYERS:
                violations.append(f"{rel}:{ref.line}: reference into unknown layer ({ref.how})")
                continue
            if target_layer == layer:
                continue
            edge_count += 1
            layer_graph[layer].add(target_layer)
            if target_layer not in closure[layer]:
                allowed = ", ".join(sorted(closure[layer])) or "nothing outside itself"
                violations.append(
                    f"{rel}:{ref.line}: forbidden edge {layer} -> {target_layer} via {ref.how}"
                    f" (target {ref.target}; {layer} may depend on: {allowed})"
                )

    for cycle in find_cycles(layer_graph):
        violations.append(f"layer cycle: {' <-> '.join(cycle)}")
    for cycle in find_cycles(file_graph):
        violations.append(f"load-time dependency cycle between files: {' <-> '.join(cycle)}")

    if verbose:
        print(f"scanned {len(sources)} files under src/, {edge_count} cross-layer references")
        for layer in LAYERS:
            targets = ", ".join(sorted(layer_graph[layer])) or "-"
            print(f"  {layer:9s} -> {targets}")

    if violations:
        print(f"check_layers: {len(violations)} violation(s)", file=sys.stderr)
        for violation in violations:
            print(f"  {violation}", file=sys.stderr)
        print(
            "Allowed: gameplay -> net -> core, gameplay -> data -> core, ui -> gameplay"
            " (transitive). See docs/ARCHITECTURE.md.",
            file=sys.stderr,
        )
        return 1
    print("check_layers: OK")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root (default: parent of tools/)",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="print the edge summary")
    args = parser.parse_args(argv)
    try:
        return check(args.root.resolve(), args.verbose)
    except OSError as exc:
        print(f"check_layers: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
