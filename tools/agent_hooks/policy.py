"""Shared guard policy (ADR 0007 D02, D07, D08, D09, D15, D16; docs/ai/contracts.md).

``evaluate(request)`` is pure: it performs no I/O beyond ``os.path`` resolution of the
paths it is given (``realpath`` follows symlinks so an alias to a secret or policy file is
caught) and reads no environment except ``HOME`` and ``TMPDIR`` for path expansion.

The policy is a denylist for destruction and secret inspection plus an approval list for
publication and policy edits. Unknown local commands are allowed (ADR 0007 D09). It
protects cooperative agents from accidents on documented tool paths; it is not a sandbox.
"""

from __future__ import annotations

import os
import re
import shlex
from dataclasses import dataclass
from typing import Callable, Optional

REQUEST_VERSION = 1

ALLOW = "allow"
APPROVAL = "approval-required"
DENY = "deny"
SEVERITY = {ALLOW: 0, APPROVAL: 1, DENY: 2}

# Reason code -> (decision, fixed message). Messages never echo request content.
REASONS: dict[str, tuple[str, str]] = {
    "safe": (ALLOW, "Allowed by the shared guard."),
    "secret-read": (DENY, "Reading signing material, credentials or .env files is denied (ADR 0007 D07)."),
    "env-dump": (DENY, "Dumping the process environment is denied (ADR 0007 D07)."),
    "destructive-command": (
        DENY,
        "Destructive command denied; use bounded cleanup of .godot/, artifacts/ or build/ (ADR 0007 D08).",
    ),
    "force-push": (DENY, "Force pushes are denied (ADR 0007 D08)."),
    "shared-stash": (
        DENY,
        "The stash is shared by every worktree: use git stash push -u -m <tag> and git stash apply <sha> (ADR 0007 D08).",
    ),
    "publication": (APPROVAL, "Publishing outside the worktree needs the human's approval (ADR 0007 D15)."),
    "policy-file-write": (APPROVAL, "Editing harness or policy files needs harness authorization (ADR 0007 D16)."),
    "sensitive-file-write": (APPROVAL, "Writing a secret or signing file needs approval (ADR 0007 D07)."),
    "outside-root-write": (APPROVAL, "Writing outside the worktree root needs approval (ADR 0007 D03)."),
    "invalid-request": (DENY, "The guard could not parse the request and fails closed (ADR 0007 D09)."),
    "policy-error": (DENY, "The guard failed internally and fails closed (ADR 0007 D09)."),
}


@dataclass(frozen=True)
class Decision:
    decision: str
    reason: str
    message: str

    def as_dict(self) -> dict[str, object]:
        return {
            "version": REQUEST_VERSION,
            "decision": self.decision,
            "reason": self.reason,
            "message": self.message,
        }


def decision_for(reason: str) -> Decision:
    decision, message = REASONS[reason]
    return Decision(decision, reason, message)


SAFE = decision_for("safe")
INVALID = decision_for("invalid-request")


def worst(decisions: list[Decision]) -> Decision:
    """Most severe decision wins; ties keep the first one found."""
    result = SAFE
    for item in decisions:
        if SEVERITY[item.decision] > SEVERITY[result.decision]:
            result = item
    return result


# --------------------------------------------------------------------------- paths

PROTECTED_ROOT_NAMES = (".git", ".tools", "src", "data", "art", "tests", "addons", "docs", "tools")
SECRET_SUFFIXES = (".keystore", ".jks", ".p12", ".pem", ".key")
SECRET_BASENAMES = {
    "export_credentials.cfg",
    ".env",
    "config.vdf",
    ".netrc",
    ".git-credentials",
    ".claude.json",
}
SECRET_SEGMENTS = {"secrets", "credentials"}
HOME_SECRET_DIRS = (".ssh", ".aws", os.path.join(".config", "gh"))
POLICY_BASENAMES = {"AGENTS.md", "CLAUDE.md", ".gitattributes"}
POLICY_DIR_SEGMENTS = {".claude", ".grok", ".agents"}
POLICY_RELATIVE_DIRS = (os.path.join("tools", "agent_hooks"), os.path.join(".github", "workflows"))
TMP_ROOTS = ("/tmp", "/private/tmp")
DEVICE_ROOT = "/dev"
LITERAL_WIPE_TARGETS = {".", "..", "*", "./", "../", "/", "/*", "~", "~/", "~/*", "$HOME", "${HOME}", "$HOME/*"}


@dataclass
class Context:
    root_forms: tuple[str, ...]
    cwd: str
    home: str
    tmp_roots: tuple[str, ...]


def _strip_trailing_sep(path: str) -> str:
    if len(path) > 1:
        return path.rstrip(os.sep)
    return path


def _expand_token(token: str, ctx: Context) -> str:
    text = token.replace("${HOME}", ctx.home).replace("$HOME", ctx.home)
    tmpdir = ctx.tmp_roots[-1] if len(ctx.tmp_roots) > len(TMP_ROOTS) else ""
    if tmpdir:
        text = text.replace("${TMPDIR}", tmpdir).replace("$TMPDIR", tmpdir)
    if text == "~" or text.startswith("~" + os.sep):
        text = ctx.home + text[1:]
    return text


def path_forms(token: str, ctx: Context) -> tuple[str, str]:
    """Lexical (abspath) and physical (realpath) forms of a path token, both absolute."""
    expanded = _expand_token(token, ctx)
    if not os.path.isabs(expanded):
        expanded = os.path.join(ctx.cwd, expanded)
    lexical = _strip_trailing_sep(os.path.normpath(expanded))
    physical = _strip_trailing_sep(os.path.realpath(expanded))
    return lexical, physical


def _is_under(path: str, parent: str) -> bool:
    parent = _strip_trailing_sep(parent)
    if parent == os.sep:
        return True
    return path == parent or path.startswith(parent + os.sep)


def is_secret_path(path: str, ctx: Context) -> bool:
    base = os.path.basename(path)
    lower = base.lower()
    if lower.endswith(SECRET_SUFFIXES) or lower in SECRET_BASENAMES or lower.startswith("ssfn"):
        return True
    if lower.startswith(".env.") and lower != ".env.example":
        return True
    parts = [part.lower() for part in path.split(os.sep) if part]
    if any(part in SECRET_SEGMENTS for part in parts):
        return True
    for index, part in enumerate(parts):
        if "pixellab" in part and any("key" in later or "token" in later for later in parts[index:]):
            return True
    for name in HOME_SECRET_DIRS:
        if _is_under(path, os.path.join(ctx.home, name)):
            return True
    return False


def _relative_to_root(path: str, ctx: Context) -> Optional[str]:
    for root in ctx.root_forms:
        if _is_under(path, root):
            return os.path.relpath(path, root)
    return None


def is_policy_path(path: str, ctx: Context) -> bool:
    if os.path.basename(path) in POLICY_BASENAMES:
        return True
    relative = _relative_to_root(path, ctx)
    if relative is None:
        return False
    parts = relative.split(os.sep)
    if any(part in POLICY_DIR_SEGMENTS for part in parts):
        return True
    return any(relative == prefix or relative.startswith(prefix + os.sep) for prefix in POLICY_RELATIVE_DIRS)


def is_inside_root(path: str, ctx: Context) -> bool:
    return any(_is_under(path, root) for root in ctx.root_forms)


def is_tmp_path(path: str, ctx: Context) -> bool:
    """Scratch locations where writes need no approval: /tmp, $TMPDIR and /dev (null, stdout)."""
    return _is_under(path, DEVICE_ROOT) or any(_is_under(path, tmp) for tmp in ctx.tmp_roots)


def classify_read_path(token: str, ctx: Context) -> Decision:
    for form in path_forms(token, ctx):
        if is_secret_path(form, ctx):
            return decision_for("secret-read")
    return SAFE


def classify_write_path(token: str, ctx: Context) -> Decision:
    forms = path_forms(token, ctx)
    if any(is_policy_path(form, ctx) for form in forms):
        return decision_for("policy-file-write")
    if any(is_secret_path(form, ctx) for form in forms):
        return decision_for("sensitive-file-write")
    if not all(is_inside_root(form, ctx) or is_tmp_path(form, ctx) for form in forms):
        return decision_for("outside-root-write")
    return SAFE


def _protected_dirs(ctx: Context) -> set[str]:
    protected = {os.sep, _strip_trailing_sep(ctx.home)}
    for root in ctx.root_forms:
        protected.add(root)
        for name in PROTECTED_ROOT_NAMES:
            protected.add(os.path.join(root, name))
        ancestor = os.path.dirname(root)
        while ancestor and ancestor != os.sep:
            protected.add(ancestor)
            ancestor = os.path.dirname(ancestor)
    for name in HOME_SECRET_DIRS:
        protected.add(os.path.join(ctx.home, name))
    return protected


def is_wipe_target(token: str, ctx: Context) -> bool:
    """True when a recursive deletion of ``token`` would remove a protected root (D08)."""
    if token in LITERAL_WIPE_TARGETS:
        return True
    candidate = token
    if any(char in token for char in "*?["):
        head, tail = os.path.split(token.rstrip(os.sep))
        if tail not in ("*", "**"):
            return False
        candidate = head or "."
    protected = _protected_dirs(ctx)
    return any(form in protected for form in path_forms(candidate, ctx))


# --------------------------------------------------------------------------- shell splitting

MAX_DEPTH = 8
MARK = "\x01"
SUBST_PLACEHOLDER = "__cmdsubst__"
REDIRECT_RE = re.compile(r"^\x01(\d*)(&>>|&>|>>|>\||>&|<&|<>|<<<|<|>)\x01$")
PROC_ENVIRON_RE = re.compile(r"/proc/(\d+|self|thread-self)/environ")
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
HEREDOC_WORD_END = set(" \t\n;&|<>()")


class ShellSyntaxError(ValueError):
    """Raised when the command text cannot be split safely."""


def _extract_paren(text: str, start: int) -> tuple[str, int]:
    depth = 1
    i = start
    in_single = in_double = False
    while i < len(text):
        ch = text[i]
        if in_single:
            in_single = ch != "'"
        elif ch == "\\":
            i += 1
        elif in_double:
            in_double = ch != '"'
        elif ch == "'":
            in_single = True
        elif ch == '"':
            in_double = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[start:i], i + 1
        i += 1
    raise ShellSyntaxError("unterminated command substitution")


def _extract_backtick(text: str, start: int) -> tuple[str, int]:
    i = start
    while i < len(text):
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == "`":
            return text[start:i], i + 1
        i += 1
    raise ShellSyntaxError("unterminated backtick substitution")


def _pop_fd(buf: list[str]) -> str:
    digits: list[str] = []
    index = len(buf) - 1
    while index >= 0 and buf[index].isdigit() and len(buf[index]) == 1:
        digits.append(buf[index])
        index -= 1
    if not digits or (index >= 0 and not buf[index].isspace()):
        return ""
    del buf[index + 1 :]
    return "".join(reversed(digits))


def _skip_heredoc_bodies(text: str, start: int, pending: list[tuple[str, bool]]) -> int:
    i = start
    for delimiter, strip_tabs in pending:
        while i < len(text):
            end = text.find("\n", i)
            if end < 0:
                end = len(text)
            line = text[i:end]
            if strip_tabs:
                line = line.lstrip("\t")
            i = end + 1
            if line == delimiter:
                break
    return min(i, len(text))


def split_shell(text: str) -> tuple[list[str], list[str]]:
    """Split a shell command into simple-command segments and substitution bodies.

    Returns ``(segments, bodies)``. Segments have redirection operators isolated as
    ``\\x01<op>\\x01`` tokens, heredoc markers removed (their bodies are data) and command
    substitutions replaced by a placeholder word. Bodies are the raw ``$( )`` / backtick
    contents, to be classified recursively.
    """
    segments: list[str] = []
    bodies: list[str] = []
    buf: list[str] = []
    pending_heredocs: list[tuple[str, bool]] = []
    in_single = in_double = False
    i = 0
    n = len(text)

    def flush() -> None:
        segment = "".join(buf).strip()
        if segment:
            segments.append(segment)
        buf.clear()

    def substitution(start: int, closer: Callable[[str, int], tuple[str, int]]) -> int:
        body, after = closer(text, start)
        bodies.append(body)
        buf.append(SUBST_PLACEHOLDER)
        return after

    while i < n:
        ch = text[i]
        if in_single:
            buf.append(ch)
            in_single = ch != "'"
            i += 1
            continue
        if ch == "\\":
            buf.append(text[i : i + 2])
            i += 2
            continue
        if in_double:
            if ch == '"':
                in_double = False
                buf.append(ch)
                i += 1
            elif text.startswith("$(", i) and not text.startswith("$((", i):
                i = substitution(i + 2, _extract_paren)
            elif ch == "`":
                i = substitution(i + 1, _extract_backtick)
            else:
                buf.append(ch)
                i += 1
            continue
        if ch == "'":
            in_single = True
            buf.append(ch)
            i += 1
        elif ch == '"':
            in_double = True
            buf.append(ch)
            i += 1
        elif text.startswith("$((", i):
            end = text.find("))", i)
            end = n if end < 0 else end + 2
            buf.append(text[i:end])
            i = end
        elif text.startswith("$(", i):
            i = substitution(i + 2, _extract_paren)
        elif ch == "`":
            i = substitution(i + 1, _extract_backtick)
        elif ch == "\n":
            flush()
            i += 1
            if pending_heredocs:
                i = _skip_heredoc_bodies(text, i, pending_heredocs)
                pending_heredocs = []
        elif ch == ";":
            flush()
            i += 1
        elif ch == "|":
            flush()
            i += 2 if text[i + 1 : i + 2] in ("|", "&") else 1
        elif ch == "&":
            if text.startswith("&>", i):
                op = "&>>" if text.startswith("&>>", i) else "&>"
                buf.append(" " + MARK + op + MARK + " ")
                i += len(op)
            else:
                flush()
                i += 2 if text.startswith("&&", i) else 1
        elif ch in "()":
            flush()
            i += 1
        elif text.startswith("<<", i) and not text.startswith("<<<", i):
            _pop_fd(buf)
            op_len = 3 if text.startswith("<<-", i) else 2
            j = i + op_len
            while j < n and text[j] in " \t":
                j += 1
            word_start = j
            while j < n and text[j] not in HEREDOC_WORD_END:
                j += 1
            delimiter = text[word_start:j].replace("'", "").replace('"', "").replace("\\", "")
            pending_heredocs.append((delimiter, op_len == 3))
            buf.append(" ")
            i = j
        elif ch in "<>":
            op = ch
            for candidate in ("<<<", ">>", ">|", ">&", "<&", "<>"):
                if text.startswith(candidate, i):
                    op = candidate
                    break
            fd = _pop_fd(buf)
            buf.append(" " + MARK + fd + op + MARK + " ")
            i += len(op)
        else:
            buf.append(ch)
            i += 1
    if in_single or in_double:
        raise ShellSyntaxError("unbalanced quotes")
    flush()
    return segments, bodies


def _extract_redirects(tokens: list[str]) -> tuple[list[str], list[str], list[str]]:
    """Return ``(reads, writes, remaining_tokens)`` from redirection operator tokens."""
    reads: list[str] = []
    writes: list[str] = []
    remaining: list[str] = []
    i = 0
    while i < len(tokens):
        match = REDIRECT_RE.match(tokens[i])
        if not match:
            remaining.append(tokens[i])
            i += 1
            continue
        op = match.group(2)
        target = tokens[i + 1] if i + 1 < len(tokens) else ""
        i += 2
        if not target or op == "<<<":
            continue
        if op in (">&", "<&") and (target.isdigit() or target == "-"):
            continue
        if op in ("<", "<&"):
            reads.append(target)
        else:
            writes.append(target)
    return reads, writes, remaining


# --------------------------------------------------------------------------- command tables

SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
CONTROL_KEYWORDS = {"if", "then", "else", "elif", "fi", "while", "until", "do", "done", "esac", "!", "{", "}"}
LOOP_HEADERS = {"for", "select", "case", "function"}
PLAIN_WRAPPERS = {"nohup", "exec", "builtin", "command", "time", "nice", "doas", "stdbuf", "caffeinate"}
WRAPPER_VALUE_FLAGS = {
    "sudo": set("ugpCDhrtU"),
    "doas": set("u"),
    "nice": set("n"),
    "time": set("o"),
    "xargs": set("InPLsdaERSJ"),
    "timeout": set("ks"),
    "caffeinate": set("tw"),
    "stdbuf": set("ioe"),
    "command": set(),
    "nohup": set(),
    "exec": set(),
    "builtin": set(),
}
READERS = {
    "cat", "less", "more", "head", "tail", "tac", "nl", "cut", "grep", "rg", "ag", "awk", "sed",
    "base64", "xxd", "od", "hexdump", "strings", "open", "bat", "python", "python3", "node",
    "source", ".", "diff", "cmp", "jq", "yq", "vim", "vi", "nano",
}
PATTERN_FIRST = {"grep", "rg", "ag", "awk", "sed"}
PATTERN_FLAGS = {"-e", "--regexp", "-f", "--file", "--expression", "-E"}
READER_VALUE_FLAGS = {
    "grep": {"-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "--include", "--exclude", "--exclude-dir", "--label"},
    "rg": {"-e", "-f", "-g", "-t", "-T", "-A", "-B", "-C", "-m", "-M", "-E", "-j", "-r", "--type", "--glob",
           "--iglob", "--max-depth", "--threads", "--replace", "--pre", "--sort", "--sortr", "--color"},
    "ag": {"-A", "-B", "-C", "-G", "--ignore", "--file-search-regex"},
    "awk": {"-F", "-v", "-f"},
    "sed": {"-e", "-f", "-l", "--expression", "--file"},
}
GIT_VALUE_GLOBALS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
GIT_PUSH_VALUE_FLAGS = {"--repo", "-o", "--push-option", "--receive-pack", "--exec"}
GH_PUBLICATION = {
    "pr": {"merge", "close", "ready", "review", "comment", "edit", "reopen", "lock", "unlock", "update-branch"},
    "issue": {"create", "close", "comment", "edit", "reopen", "delete", "transfer", "pin", "unpin", "lock", "unlock"},
    "repo": {"create", "edit", "delete", "archive", "unarchive", "rename", "fork", "sync"},
    "workflow": {"run", "enable", "disable"},
    "gist": {"create", "delete", "edit"},
    "label": {"create", "delete", "edit", "clone"},
    "secret": {"set", "delete", "remove"},
    "variable": {"set", "delete", "remove"},
}
GH_RELEASE_READ = {"list", "view", "download"}
GH_API_FIELD_FLAGS = {"-f", "-F", "--field", "--raw-field", "--input"}
KEYTOOL_READ_FLAGS = {"-list", "-exportcert", "-export", "-printcert", "-importkeystore"}


def _basename_command(token: str) -> str:
    if token in (".", ".."):
        return token
    return os.path.basename(token)


def _strip_wrappers(tokens: list[str]) -> tuple[list[str], bool]:
    """Strip leading assignments, env/sudo/xargs-style wrappers and control keywords.

    Returns ``(tokens, env_dump)`` where ``env_dump`` is True when ``env`` ended up with no
    command operand (it would print the environment).
    """
    while tokens:
        first = tokens[0]
        name = _basename_command(first)
        if ASSIGNMENT_RE.match(first):
            tokens = tokens[1:]
        elif name in CONTROL_KEYWORDS:
            tokens = tokens[1:]
        elif name in LOOP_HEADERS:
            return [], False
        elif name == "env":
            tokens = tokens[1:]
            while tokens:
                tok = tokens[0]
                if ASSIGNMENT_RE.match(tok):
                    tokens = tokens[1:]
                elif tok in ("-u", "--unset", "-C", "--chdir", "-S", "--split-string"):
                    tokens = tokens[2:]
                elif tok.startswith("-"):
                    tokens = tokens[1:]
                else:
                    break
            if not tokens:
                return [], True
        elif name == "sudo" or name in PLAIN_WRAPPERS or name in ("xargs", "timeout"):
            value_flags = WRAPPER_VALUE_FLAGS.get(name, set())
            tokens = tokens[1:]
            while tokens and tokens[0].startswith("-") and tokens[0] != "--":
                tok = tokens[0]
                takes_value = (
                    not tok.startswith("--")
                    and len(tok) == 2
                    and tok[1] in value_flags
                ) or (tok.startswith("--") and "=" not in tok and tok[2:] in ("adjustment", "max-args", "replace", "kill-after", "signal"))
                tokens = tokens[2:] if takes_value else tokens[1:]
            if tokens and tokens[0] == "--":
                tokens = tokens[1:]
            if name == "timeout" and tokens:
                tokens = tokens[1:]  # the DURATION operand
        else:
            break
    return tokens, False


def _non_options(args: list[str], value_flags: Optional[set[str]] = None) -> list[str]:
    """Operands of a command: tokens that are not options nor values of ``value_flags``."""
    result: list[str] = []
    values = value_flags or set()
    i = 0
    literal = False
    while i < len(args):
        tok = args[i]
        if literal or not tok.startswith("-") or tok == "-":
            result.append(tok)
        elif tok == "--":
            literal = True
        elif tok in values:
            i += 1
        i += 1
    return result


def _short_cluster_has(args: list[str], letter: str) -> bool:
    return any(tok.startswith("-") and not tok.startswith("--") and letter in tok[1:] for tok in args)


# --------------------------------------------------------------------------- command classifiers


def _classify_git(args: list[str], ctx: Context) -> list[Decision]:
    i = 0
    cwd = ctx.cwd
    while i < len(args) and args[i].startswith("-"):
        if args[i] in GIT_VALUE_GLOBALS:
            if args[i] == "-C" and i + 1 < len(args):
                cwd = path_forms(args[i + 1], ctx)[0]
            i += 2
        else:
            i += 1
    if i >= len(args):
        return []
    sub, rest = args[i], args[i + 1 :]
    local = Context(ctx.root_forms, cwd, ctx.home, ctx.tmp_roots)
    if sub == "reset" and "--hard" in rest:
        return [decision_for("destructive-command")]
    if sub == "clean" and (_short_cluster_has(rest, "f") or "--force" in rest):
        return [decision_for("destructive-command")]
    if sub in ("checkout", "restore"):
        return _classify_git_restore(sub, rest, local)
    if sub == "branch" and (_short_cluster_has(rest, "d") or _short_cluster_has(rest, "D") or "--delete" in rest):
        if "main" in _non_options(rest):
            return [decision_for("destructive-command")]
    if sub == "update-ref" and "-d" in rest:
        return [decision_for("destructive-command")]
    if sub == "worktree" and rest[:1] == ["remove"] and ("--force" in rest or _short_cluster_has(rest[1:], "f")):
        return [decision_for("destructive-command")]
    if sub == "filter-branch":
        return [decision_for("destructive-command")]
    if sub == "push":
        return _classify_git_push(rest)
    if sub == "stash":
        operands = _non_options(rest)
        if not operands or operands[0] in ("pop", "drop", "clear"):
            return [decision_for("shared-stash")]
    return []


def _classify_git_restore(sub: str, rest: list[str], ctx: Context) -> list[Decision]:
    if sub == "restore":
        if "--source" in rest or any(tok.startswith("--source=") for tok in rest) or "-s" in rest:
            return [decision_for("destructive-command")]
        staged_only = ("--staged" in rest or _short_cluster_has(rest, "S")) and not (
            "--worktree" in rest or _short_cluster_has(rest, "W")
        )
        if staged_only:
            return []
        pathspecs = _non_options(rest, {"-s", "--source"})
    elif "--" in rest:
        pathspecs = rest[rest.index("--") + 1 :]
    else:
        # Without "--" a checkout operand is usually a branch; only unmistakable paths count.
        operands = _non_options(rest, {"-b", "-B", "--orphan", "--conflict", "--pathspec-from-file"})
        pathspecs = [tok for tok in operands if tok in LITERAL_WIPE_TARGETS or os.path.isabs(tok)]
    if any(is_wipe_target(tok, ctx) for tok in pathspecs):
        return [decision_for("destructive-command")]
    return []


def _classify_git_push(rest: list[str]) -> list[Decision]:
    if "--delete" in rest or _short_cluster_has(rest, "d"):
        return [decision_for("destructive-command")]
    refspecs = _non_options(rest, GIT_PUSH_VALUE_FLAGS)
    if any(ref.startswith(":") for ref in refspecs):
        return [decision_for("destructive-command")]
    forced = (
        _short_cluster_has(rest, "f")
        or "--force" in rest
        or any(tok == "--force-with-lease" or tok.startswith("--force-with-lease=") for tok in rest)
        or "--force-if-includes" in rest
        or any(ref.startswith("+") for ref in refspecs)
    )
    if forced:
        return [decision_for("force-push")]
    if ("--tags" in rest or "--follow-tags" in rest or
            any(ref.startswith("refs/tags/") or ":refs/tags/" in ref for ref in refspecs)):
        return [decision_for("publication")]
    return []


def _classify_gh(args: list[str]) -> list[Decision]:
    if not args:
        return []
    command = args[0]
    sub = args[1] if len(args) > 1 else ""
    if command == "api":
        return _classify_gh_api(args[1:])
    if command == "auth":
        if sub == "token" or (sub == "status" and ("--show-token" in args or _short_cluster_has(args[2:], "t"))):
            return [decision_for("secret-read")]
        return []
    if command == "release":
        return [] if sub in GH_RELEASE_READ or not sub else [decision_for("publication")]
    if sub in GH_PUBLICATION.get(command, set()):
        return [decision_for("publication")]
    return []


def _classify_gh_api(args: list[str]) -> list[Decision]:
    i = 0
    while i < len(args):
        tok = args[i]
        method = ""
        if tok in ("-X", "--method"):
            method = args[i + 1] if i + 1 < len(args) else ""
            i += 1
        elif tok.startswith("--method=") or (tok.startswith("-X") and len(tok) > 2):
            method = tok.split("=", 1)[1] if "=" in tok else tok[2:]
        if method and method.upper() != "GET":
            return [decision_for("publication")]
        if method == "" and (tok in GH_API_FIELD_FLAGS or any(tok.startswith(flag + "=") for flag in GH_API_FIELD_FLAGS)):
            return [decision_for("publication")]
        i += 1
    return []


def _classify_rm(args: list[str], ctx: Context) -> list[Decision]:
    recursive = False
    targets: list[str] = []
    literal = False
    for tok in args:
        if literal or not tok.startswith("-") or tok == "-":
            targets.append(tok)
        elif tok == "--":
            literal = True
        elif tok == "--recursive":
            recursive = True
        elif not tok.startswith("--") and ("r" in tok[1:] or "R" in tok[1:]):
            recursive = True
    decisions: list[Decision] = []
    for target in targets:
        if recursive and is_wipe_target(target, ctx):
            decisions.append(decision_for("destructive-command"))
        else:
            decisions.append(classify_write_path(target, ctx))
    return decisions


def _classify_find(args: list[str], ctx: Context, depth: int) -> list[Decision]:
    decisions: list[Decision] = []
    start_paths: list[str] = []
    i = 0
    while i < len(args) and not args[i].startswith("-") and args[i] not in ("(", "!"):
        start_paths.append(args[i])
        i += 1
    if "-delete" in args:
        decisions.extend(_classify_rm(["-r"] + (start_paths or ["."]), ctx))
    while i < len(args):
        if args[i] in ("-exec", "-execdir", "-ok", "-okdir"):
            j = i + 1
            while j < len(args) and args[j] not in (";", "+"):
                j += 1
            decisions.extend(_classify_tokens(args[i + 1 : j], ctx, depth))
            i = j
        i += 1
    return decisions


def _reader_candidates(name: str, args: list[str]) -> list[str]:
    operands = _non_options(args, READER_VALUE_FLAGS.get(name, set()))
    if name in PATTERN_FIRST and operands and not any(
        tok in PATTERN_FLAGS or tok.startswith("--expression=") or tok.startswith("--regexp=") for tok in args
    ):
        operands = operands[1:]
    return operands


def _classify_sed(args: list[str], ctx: Context) -> list[Decision]:
    in_place = any(
        (tok.startswith("-") and not tok.startswith("--") and "i" in tok[1:]) or tok.startswith("--in-place")
        for tok in args
    )
    if not in_place:
        return [classify_read_path(tok, ctx) for tok in _reader_candidates("sed", args)]
    cleaned: list[str] = []
    i = 0
    while i < len(args):
        tok = args[i]
        cleaned.append(tok)
        if tok == "-i" and i + 1 < len(args):
            nxt = args[i + 1]
            if nxt == "" or (nxt.startswith(".") and os.sep not in nxt):
                i += 1  # BSD sed backup suffix
        i += 1
    operands = _non_options(cleaned, READER_VALUE_FLAGS["sed"])
    if not any(tok in ("-e", "-f", "--expression", "--file") or tok.startswith("--expression=") for tok in cleaned):
        operands = operands[1:]
    return [classify_write_path(tok, ctx) for tok in operands]


def _classify_perl(args: list[str], ctx: Context) -> list[Decision]:
    in_place = any(tok.startswith("-") and not tok.startswith("--") and "i" in tok[1:] for tok in args)
    if not in_place:
        return []
    files = _non_options(args, {"-e", "-E", "-M", "-m", "-I"})
    return [classify_write_path(tok, ctx) for tok in files]


def _classify_writer(name: str, args: list[str], ctx: Context) -> list[Decision]:
    decisions: list[Decision] = []
    if name == "tee":
        return [classify_write_path(tok, ctx) for tok in _non_options(args)]
    if name == "cp":
        operands = _non_options(args, {"-t", "--target-directory"})
        if len(operands) >= 2:
            decisions.extend(classify_read_path(tok, ctx) for tok in operands[:-1])
            decisions.append(classify_write_path(operands[-1], ctx))
        return decisions
    if name in ("mv", "rmdir", "unlink", "touch", "shred"):
        return [classify_write_path(tok, ctx) for tok in _non_options(args, {"-t"})]
    if name == "truncate":
        return [classify_write_path(tok, ctx) for tok in _non_options(args, {"-s", "--size", "-r", "--reference"})]
    if name == "ln":
        operands = _non_options(args, {"-t", "--target-directory"})
        return [classify_write_path(operands[-1], ctx)] if len(operands) >= 2 else []
    if name in ("chmod", "chown", "chgrp"):
        operands = _non_options(args, {"--reference"})
        return [classify_write_path(tok, ctx) for tok in operands[1:]]
    if name == "install":
        operands = _non_options(args, {"-m", "-o", "-g", "-t", "--mode", "--owner", "--group", "--target-directory"})
        if _short_cluster_has(args, "d"):
            return [classify_write_path(tok, ctx) for tok in operands]
        return [classify_write_path(operands[-1], ctx)] if len(operands) >= 2 else []
    if name == "rsync":
        operands = _non_options(args, {"-e", "--rsh", "--exclude", "--include", "--filter", "--files-from"})
        if len(operands) >= 2 and ":" not in operands[-1]:
            return [classify_write_path(operands[-1], ctx)]
        return []
    if name == "dd":
        return [classify_write_path(tok[3:], ctx) for tok in args if tok.startswith("of=")]
    return decisions


def _classify_env_dumpers(name: str, args: list[str]) -> list[Decision]:
    operands = _non_options(args)
    if name == "printenv":
        return [] if operands else [decision_for("env-dump")]
    if name == "export":
        return [decision_for("env-dump")] if not args or "-p" in args else []
    if name == "set":
        return [decision_for("env-dump")] if not args else []
    if name in ("declare", "typeset"):
        if operands:
            return []
        if not args or _short_cluster_has(args, "x") or _short_cluster_has(args, "p"):
            return [decision_for("env-dump")]
    return []


def _classify_shell_wrapper(args: list[str], ctx: Context, depth: int) -> list[Decision]:
    saw_c = False
    i = 0
    while i < len(args):
        tok = args[i]
        if tok == "--":
            i += 1
            if i < len(args) and saw_c:
                return _classify_text(args[i], ctx, depth + 1)
            return []
        if tok.startswith("-") and len(tok) > 1:
            if tok in ("-o", "+o"):
                i += 1
            elif not tok.startswith("--") and "c" in tok[1:]:
                saw_c = True
            i += 1
            continue
        return _classify_text(tok, ctx, depth + 1) if saw_c else []
    return []


def _classify_keytool(args: list[str], ctx: Context) -> list[Decision]:
    stores = [args[i + 1] for i, tok in enumerate(args[:-1]) if tok == "-keystore"]
    if not stores:
        return []
    if any(tok in KEYTOOL_READ_FLAGS for tok in args):
        return [decision_for("secret-read") for _ in stores]
    return [classify_write_path(tok, ctx) for tok in stores]


def _classify_tokens(tokens: list[str], ctx: Context, depth: int) -> list[Decision]:
    """Classify one simple command (tokens without redirections)."""
    decisions: list[Decision] = []
    if any(PROC_ENVIRON_RE.search(tok) for tok in tokens):
        decisions.append(decision_for("env-dump"))
    tokens, env_dump = _strip_wrappers(tokens)
    if env_dump:
        decisions.append(decision_for("env-dump"))
    if not tokens:
        return decisions
    name = _basename_command(tokens[0])
    args = tokens[1:]
    if name in SHELLS:
        decisions.extend(_classify_shell_wrapper(args, ctx, depth))
    elif name == "eval":
        decisions.extend(_classify_text(" ".join(args), ctx, depth + 1))
    elif name == "git":
        decisions.extend(_classify_git(args, ctx))
    elif name == "gh":
        decisions.extend(_classify_gh(args))
    elif name == "rm":
        decisions.extend(_classify_rm(args, ctx))
    elif name == "find":
        decisions.extend(_classify_find(args, ctx, depth))
    elif name in ("printenv", "export", "set", "declare", "typeset"):
        decisions.extend(_classify_env_dumpers(name, args))
    elif name == "sed":
        decisions.extend(_classify_sed(args, ctx))
    elif name == "perl":
        decisions.extend(_classify_perl(args, ctx))
    elif name == "keytool":
        decisions.extend(_classify_keytool(args, ctx))
    elif name in READERS:
        decisions.extend(classify_read_path(tok, ctx) for tok in _reader_candidates(name, args))
    elif name in ("tee", "cp", "mv", "rmdir", "unlink", "touch", "shred", "truncate", "ln", "chmod", "chown",
                  "chgrp", "install", "rsync", "dd"):
        decisions.extend(_classify_writer(name, args, ctx))
    elif name == "butler" and args[:1] == ["push"]:
        decisions.append(decision_for("publication"))
    elif name == "steamcmd":
        decisions.append(decision_for("publication"))
    elif name in ("cd", "pushd"):
        operands = _non_options(args)
        if not operands:
            ctx.cwd = ctx.home
        elif operands[0] != "-" and "$" not in operands[0]:
            ctx.cwd = path_forms(operands[0], ctx)[0]
    return decisions


def _classify_text(text: str, ctx: Context, depth: int) -> list[Decision]:
    if depth > MAX_DEPTH:
        return [INVALID]
    try:
        segments, bodies = split_shell(text)
    except ValueError:
        return [INVALID]
    decisions: list[Decision] = []
    for body in bodies:
        decisions.extend(_classify_text(body, ctx, depth + 1))
    for segment in segments:
        try:
            tokens = shlex.split(segment)
        except ValueError:
            return decisions + [INVALID]
        reads, writes, tokens = _extract_redirects(tokens)
        decisions.extend(classify_read_path(tok, ctx) for tok in reads)
        decisions.extend(classify_write_path(tok, ctx) for tok in writes)
        decisions.extend(_classify_tokens(tokens, ctx, depth))
    return decisions


# --------------------------------------------------------------------------- entry point


def _build_context(request: dict) -> Optional[Context]:
    root = request.get("root")
    cwd = request.get("cwd")
    if not isinstance(root, str) or not root or not os.path.isabs(root):
        return None
    if not isinstance(cwd, str) or not cwd:
        return None
    home = os.environ.get("HOME") or os.path.expanduser("~")
    home = _strip_trailing_sep(os.path.normpath(home))
    tmp_roots: list[str] = list(TMP_ROOTS)
    tmpdir = os.environ.get("TMPDIR", "")
    if tmpdir:
        tmpdir = _strip_trailing_sep(os.path.normpath(tmpdir))
        tmp_roots.append(_strip_trailing_sep(os.path.realpath(tmpdir)))
        tmp_roots.append(tmpdir)
    root_lexical = _strip_trailing_sep(os.path.normpath(root))
    root_physical = _strip_trailing_sep(os.path.realpath(root))
    if not os.path.isabs(cwd):
        cwd = os.path.join(root_lexical, cwd)
    cwd = _strip_trailing_sep(os.path.normpath(cwd))
    return Context((root_lexical, root_physical), cwd, home, tuple(tmp_roots))


def _string_list(value: object) -> Optional[list[str]]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        return None
    return list(value)


def evaluate(request: dict) -> Decision:
    """Evaluate a version-1 guard request (see docs/ai/contracts.md)."""
    if not isinstance(request, dict) or request.get("version") != REQUEST_VERSION:
        return INVALID
    operation = request.get("operation")
    if not isinstance(operation, dict):
        return INVALID
    ctx = _build_context(request)
    if ctx is None:
        return INVALID
    kind = operation.get("kind")
    if kind == "shell":
        text = operation.get("text")
        if not isinstance(text, str) or "\x00" in text:
            return INVALID
        return worst(_classify_text(text, ctx, 0))
    if kind in ("read", "write"):
        paths = _string_list(operation.get("paths"))
        if paths is None or any("\x00" in path for path in paths):
            return INVALID
        classify = classify_read_path if kind == "read" else classify_write_path
        return worst([classify(path, ctx) for path in paths])
    if kind == "mcp":
        return SAFE if isinstance(operation.get("name"), str) else INVALID
    return INVALID
