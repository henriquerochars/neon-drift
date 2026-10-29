#!/usr/bin/env python3
"""Play Neon Drift in a browser through a Cloudflare quick tunnel (skill ``start-game``).

    tools/start_game.sh [start] [--from main|current] [--rebuild | --no-build] [--restart]
                        [--port N] [--cloudflared PATH]
    tools/start_game.sh status
    tools/start_game.sh stop
    tools/start_game.sh install-cloudflared

``start`` serves ``main`` by default: it fetches ``origin/main`` and moves a dedicated detached
worktree (``$NEONDRIFT_PLAY_CHECKOUT``, default ``~/.cache/neon-drift/play-main``) to it, so the
caller's own checkout, branch and uncommitted work are never touched. ``--from current`` serves
the invoking checkout instead. The Web export (``tools/build.sh web``) runs when the last build
does not match the served commit or that tree is dirty; the export is copied into
``.neondrift/start-game/site/``, served on 127.0.0.1 and published through an account-less
``trycloudflare.com`` tunnel over HTTP/2 (QUIC connections were seen dropping after minutes).
Both processes are detached so they outlive the agent session; ``stop`` ends them.

The Web export has no thread support, so it needs no cross-origin isolation headers. Online
rooms use ENet (UDP), which browsers cannot open: the browser build plays solo races only.

The link is public to anyone who has it, has no uptime guarantee and changes on every tunnel
restart. ``start`` reuses a healthy session serving the same commit instead of restarting it.

Exit codes: 0 success, 1 a step failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence

ROOT = Path(__file__).resolve().parents[1]
BUILD_SUBDIR = Path("build") / "web"
BUILD_TARGET = "web"
STATE_DIR = ROOT / ".neondrift" / "start-game"
CACHED_CLOUDFLARED = Path.home() / ".cache" / "neon-drift" / "cloudflared"
PLAY_CHECKOUT = Path(
    os.environ.get("NEONDRIFT_PLAY_CHECKOUT", str(Path.home() / ".cache" / "neon-drift" / "play-main"))
).expanduser()
MAIN_REF = "origin/main"
CLOUDFLARED_RELEASE = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-{arch}"
LINUX_ARCHES = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}

# The tunnel host, never the quick-tunnel API host cloudflared may name in an error.
TUNNEL_URL = re.compile(r"https://(?!api\.)[a-z0-9-]+\.trycloudflare\.com")
STAGED_SKIP_SUFFIXES = (".zip", ".import")
ENTRY_PAGE = "index.html"
ENGINE_BINARY = "index.wasm"
USER_AGENT = "neon-drift-start-game"
SERVER_MARKER = "http.server"
TUNNEL_MARKER = "cloudflared"

SERVER_READY_SECONDS = 15.0
TUNNEL_URL_SECONDS = 60.0
PUBLIC_READY_SECONDS = 90.0
STOP_GRACE_SECONDS = 5.0
POLL_SECONDS = 0.5
HTTP_TIMEOUT_SECONDS = 15.0
LOG_TAIL_LINES = 20


class StartGameError(Exception):
    """A step failed; the message is shown to the user as is."""


@dataclass
class Session:
    """What ``start`` launched, persisted in ``state.json``."""

    commit: str
    port: int
    url: str
    server_pid: int
    tunnel_pid: int
    started_at: str
    source: str = "current"

    @property
    def page(self) -> str:
        return f"{self.url}/{ENTRY_PAGE}"


# ---------------------------------------------------------------- pure helpers


def find_tunnel_url(log_text: str) -> Optional[str]:
    """First ``trycloudflare.com`` URL cloudflared printed, if any."""
    match = TUNNEL_URL.search(log_text)
    return match.group(0) if match else None


def build_is_current(stamp: Optional[Dict[str, object]], head: str, dirty: bool, has_build: bool) -> bool:
    """True when the exported build was made from ``head`` with a clean tree."""
    if dirty or not has_build or stamp is None:
        return False
    return stamp.get("commit") == head and stamp.get("dirty") is False


def staged_files(build_dir: Path) -> List[Path]:
    """Files of an export worth serving: no packaged zip, no stray Godot ``.import`` sidecars."""
    return sorted(
        path for path in build_dir.iterdir() if path.is_file() and not path.name.endswith(STAGED_SKIP_SUFFIXES)
    )


def cloudflared_candidates(explicit: Optional[str], env: Dict[str, str], which: Callable[[str], Optional[str]]) -> List[Path]:
    """Lookup order: ``--cloudflared``, ``$CLOUDFLARED``, ``PATH``, the cached download."""
    found: List[Path] = []
    for value in (explicit, env.get("CLOUDFLARED"), which("cloudflared")):
        if value:
            found.append(Path(value).expanduser())
    found.append(CACHED_CLOUDFLARED)
    return found


def parse_session(data: Dict[str, object]) -> Session:
    """Validate ``state.json``; raises ``StartGameError`` on a malformed file."""
    try:
        return Session(
            commit=str(data["commit"]),
            port=int(str(data["port"])),
            url=str(data["url"]),
            server_pid=int(str(data["server_pid"])),
            tunnel_pid=int(str(data["tunnel_pid"])),
            started_at=str(data["started_at"]),
            source=str(data.get("source", "current")),
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise StartGameError(f"{STATE_DIR / 'state.json'} is malformed ({exc}); run stop") from exc


# ---------------------------------------------------------------- git and files


def git(*args: str, cwd: Optional[Path] = None) -> str:
    result = subprocess.run(("git", *args), cwd=cwd if cwd is not None else ROOT, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise StartGameError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def tree_is_dirty(cwd: Optional[Path] = None) -> bool:
    return bool(git("status", "--porcelain", "--untracked-files=normal", cwd=cwd))


def behind_origin_main(cwd: Optional[Path] = None) -> Optional[int]:
    """Commits on local ``origin/main`` missing from ``HEAD``; None when the ref is absent."""
    try:
        git("rev-parse", "--verify", "--quiet", MAIN_REF, cwd=cwd)
        return int(git("rev-list", "--count", f"HEAD..{MAIN_REF}", cwd=cwd))
    except (StartGameError, ValueError):
        return None


def common_dir(cwd: Optional[Path] = None) -> Path:
    return Path(git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd)).resolve()


def primary_checkout() -> Path:
    """The main working tree of this repository (owner of ``.tools/``)."""
    common = common_dir()
    return common.parent if common.name == ".git" else Path(git("rev-parse", "--show-toplevel"))


def is_worktree_of_this_repo(path: Path) -> bool:
    if not (path / ".git").exists():
        return False
    try:
        return common_dir(path) == common_dir()
    except StartGameError:
        return False


def prepare_main_checkout(checkout: Optional[Path] = None) -> Path:
    """Fetch ``origin/main`` and move the dedicated play worktree to it (detached, never reset)."""
    checkout = checkout if checkout is not None else PLAY_CHECKOUT
    print(f"Fetching {MAIN_REF}...")
    git("fetch", "--quiet", "origin", "main")
    target = git("rev-parse", MAIN_REF)
    if checkout.exists() and not is_worktree_of_this_repo(checkout):
        raise StartGameError(
            f"{checkout} exists but is not a worktree of this repository; "
            "move it away or set NEONDRIFT_PLAY_CHECKOUT"
        )
    if not checkout.exists():
        checkout.parent.mkdir(parents=True, exist_ok=True)
        git("worktree", "prune")
        git("worktree", "add", "--detach", str(checkout), target)
        print(f"Created the play checkout {checkout}")
    else:
        if tree_is_dirty(checkout):
            raise StartGameError(
                f"the play checkout {checkout} has local changes, but it is reserved for "
                f"start-game; inspect it, then remove it with: git worktree remove {checkout}"
            )
        if git("rev-parse", "HEAD", cwd=checkout) != target:
            git("checkout", "--quiet", "--detach", target, cwd=checkout)
    link_engine(checkout)
    return checkout


def link_engine(checkout: Path) -> None:
    """Give the play checkout the pinned engine of the primary checkout (``.tools/``)."""
    tools = checkout / ".tools"
    if os.path.lexists(tools) or os.environ.get("GODOT_BIN"):
        return
    source = primary_checkout() / ".tools"
    if not source.exists():
        raise StartGameError(
            f"no pinned engine at {source}; run tools/setup_godot.sh in the primary checkout or set GODOT_BIN"
        )
    tools.symlink_to(source, target_is_directory=True)


def read_json(path: Path) -> Optional[Dict[str, object]]:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def write_json(path: Path, data: Dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(path)


def tail(path: Path, lines: int = LOG_TAIL_LINES) -> str:
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])
    except OSError:
        return "(no log)"


# ---------------------------------------------------------------- processes


def pid_matches(pid: int, marker: str) -> bool:
    """Alive and still the process we launched (guards against PID reuse)."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return False
    result = subprocess.run(("ps", "-o", "command=", "-p", str(pid)), capture_output=True, text=True, check=False)
    return result.returncode == 0 and marker in result.stdout


def terminate(pid: int, marker: str) -> bool:
    """SIGTERM, then SIGKILL after a grace period. False when nothing matching was running."""
    if not pid_matches(pid, marker):
        return False
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + STOP_GRACE_SECONDS
    while time.monotonic() < deadline:
        if not pid_matches(pid, marker):
            return True
        time.sleep(POLL_SECONDS)
    if pid_matches(pid, marker):
        os.kill(pid, signal.SIGKILL)
    return True


def spawn_detached(command: Sequence[str], log: Path, cwd: Path) -> subprocess.Popen[bytes]:
    """Start ``command`` in its own session so it survives the caller; output goes to ``log``."""
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("wb") as handle:
        return subprocess.Popen(
            list(command),
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def port_is_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def http_status(url: str, method: str = "GET") -> tuple[int, int]:
    """HTTP status and Content-Length (-1 when absent); (0, -1) on a network error."""
    request = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return int(response.status), int(response.headers.get("Content-Length") or -1)
    except urllib.error.HTTPError as exc:
        return int(exc.code), -1
    except (urllib.error.URLError, OSError):
        return 0, -1


def wait_for(check: Callable[[], bool], seconds: float, alive: Callable[[], bool]) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return True
        if not alive():
            return False
        time.sleep(POLL_SECONDS)
    return check()


# ---------------------------------------------------------------- cloudflared


def resolve_cloudflared(explicit: Optional[str]) -> Path:
    for candidate in cloudflared_candidates(explicit, dict(os.environ), shutil.which):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    hint = "brew install cloudflared" if sys.platform == "darwin" else "tools/start_game.sh install-cloudflared"
    raise StartGameError(f"cloudflared not found (looked at --cloudflared, $CLOUDFLARED, PATH, {CACHED_CLOUDFLARED}). Install it: {hint}")


def install_cloudflared() -> int:
    if sys.platform == "darwin":
        raise StartGameError("on macOS install it with: brew install cloudflared")
    arch = LINUX_ARCHES.get(platform.machine().lower())
    if not sys.platform.startswith("linux") or arch is None:
        raise StartGameError(f"no cloudflared download for {sys.platform}/{platform.machine()}; install it manually")
    url = CLOUDFLARED_RELEASE.format(arch=arch)
    CACHED_CLOUDFLARED.parent.mkdir(parents=True, exist_ok=True)
    partial = CACHED_CLOUDFLARED.with_suffix(".partial")
    print(f"Downloading {url}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response, partial.open("wb") as out:
            shutil.copyfileobj(response, out)
    except (urllib.error.URLError, OSError) as exc:
        partial.unlink(missing_ok=True)
        raise StartGameError(f"download failed: {exc}") from exc
    partial.chmod(0o755)
    version = subprocess.run((str(partial), "--version"), capture_output=True, text=True, check=False)
    if version.returncode != 0:
        partial.unlink(missing_ok=True)
        raise StartGameError("the downloaded cloudflared does not run on this machine")
    partial.replace(CACHED_CLOUDFLARED)
    print(f"Installed {version.stdout.strip()} at {CACHED_CLOUDFLARED}")
    return 0


# ---------------------------------------------------------------- session


def load_session() -> Optional[Session]:
    data = read_json(STATE_DIR / "state.json")
    return parse_session(data) if data is not None else None


def session_health(session: Session) -> Dict[str, bool]:
    local_ok = http_status(f"http://127.0.0.1:{session.port}/{ENTRY_PAGE}")[0] == 200
    return {
        "server": pid_matches(session.server_pid, SERVER_MARKER),
        "tunnel": pid_matches(session.tunnel_pid, TUNNEL_MARKER),
        "local": local_ok,
    }


def stop_session(quiet: bool = False) -> bool:
    state = STATE_DIR / "state.json"
    data = read_json(state)
    stopped = False
    if data is not None:
        for key, marker in (("tunnel_pid", TUNNEL_MARKER), ("server_pid", SERVER_MARKER)):
            try:
                pid = int(str(data.get(key, 0)))
            except ValueError:
                continue
            stopped = terminate(pid, marker) or stopped
    state.unlink(missing_ok=True)
    if not quiet:
        print("Stopped the game server and tunnel." if stopped else "Nothing was running.")
    return stopped


def warm_up_import(source: Path) -> None:
    """First import of a fresh checkout logs spurious errors (the theme loads assets before their
    first import); build.sh scans its import log, so run one unscanned pass first."""
    if (source / ".godot" / "imported").is_dir():
        return
    print("Fresh checkout: running a warm-up import first (a few minutes the first time).")
    subprocess.run(
        (str(source / "tools" / "godot.sh"), "--headless", "--import"),
        cwd=source,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def ensure_build(source: Path, rebuild: bool, no_build: bool, head: str, dirty: bool) -> Path:
    """Export ``source`` for the Web unless its last export already matches; return the build dir."""
    build_dir = source / BUILD_SUBDIR
    stamp_path = STATE_DIR / "build.json"
    has_build = (build_dir / ENTRY_PAGE).is_file() and (build_dir / ENGINE_BINARY).is_file()
    stamp = read_json(stamp_path)
    if stamp is not None and stamp.get("source") != str(source):
        stamp = None
    if no_build:
        if not has_build:
            raise StartGameError(f"--no-build given but {build_dir} has no Web export")
        print(f"Serving the existing {build_dir} export as is (--no-build).")
        return build_dir
    if not rebuild and build_is_current(stamp, head, dirty, has_build):
        print(f"{build_dir} already matches {head[:7]}; skipping the export.")
        return build_dir
    reason = "--rebuild" if rebuild else ("uncommitted changes" if dirty else f"no export for {head[:7]}")
    print(f"Exporting the Web build ({reason}): tools/build.sh {BUILD_TARGET} in {source}")
    stamp_path.unlink(missing_ok=True)
    warm_up_import(source)
    result = subprocess.run((str(source / "tools" / "build.sh"), BUILD_TARGET), cwd=source, check=False)
    if result.returncode != 0:
        log = source / "artifacts" / f"build-{BUILD_TARGET}.log"
        raise StartGameError(f"tools/build.sh {BUILD_TARGET} failed (see {log})")
    write_json(
        stamp_path,
        {"commit": head, "dirty": dirty, "source": str(source), "built_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")},
    )
    return build_dir


def stage_site(build_dir: Path) -> Path:
    site = STATE_DIR / "site"
    if site.exists():
        shutil.rmtree(site)
    site.mkdir(parents=True)
    for path in staged_files(build_dir):
        shutil.copy2(path, site / path.name)
    return site


def start(args: argparse.Namespace) -> int:
    source = prepare_main_checkout() if args.source == "main" else ROOT
    head = git("rev-parse", "HEAD", cwd=source)
    dirty = tree_is_dirty(source)
    if args.source == "main":
        print(f"Serving origin/main @ {head[:7]} from {source}")
    else:
        branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=source)
        print(f"Serving the current checkout: {branch} @ {head[:7]}{' (dirty)' if dirty else ''}")
        behind = behind_origin_main(source)
        if behind:
            print(f"Note: HEAD is {behind} commit(s) behind the local origin/main ref.")

    existing = load_session()
    if existing is not None and not (args.restart or args.rebuild or dirty):
        health = session_health(existing)
        if all(health.values()) and existing.commit == head and existing.source == args.source:
            print(f"Already running {head[:7]} (started {existing.started_at}).")
            print(f"Play: {existing.page}")
            return 0
    if existing is not None:
        print("Restarting the previous session.")
        stop_session(quiet=True)

    cloudflared = resolve_cloudflared(args.cloudflared)
    if args.port and not port_is_free(args.port):
        raise StartGameError(f"port {args.port} is already in use on 127.0.0.1; omit --port to pick a free one")
    build_dir = ensure_build(source, args.rebuild, args.no_build, head, dirty)
    site = stage_site(build_dir)
    port = args.port or free_port()

    server_log = STATE_DIR / "server.log"
    server = spawn_detached(
        (sys.executable, "-m", SERVER_MARKER, str(port), "--bind", "127.0.0.1", "--directory", str(site)),
        server_log,
        site,
    )
    session = Session(head, port, "", server.pid, 0, time.strftime("%Y-%m-%dT%H:%M:%S%z"), args.source)
    write_json(STATE_DIR / "state.json", asdict(session))
    local = f"http://127.0.0.1:{port}/{ENTRY_PAGE}"
    if not wait_for(lambda: http_status(local)[0] == 200, SERVER_READY_SECONDS, lambda: server.poll() is None):
        stop_session(quiet=True)
        raise StartGameError(f"the local server did not answer on {local}:\n{tail(server_log)}")
    print(f"Serving {site} on {local}")

    tunnel_log = STATE_DIR / "tunnel.log"
    tunnel = spawn_detached(
        (str(cloudflared), "tunnel", "--no-autoupdate", "--protocol", "http2", "--url", f"http://127.0.0.1:{port}"),
        tunnel_log,
        STATE_DIR,
    )
    session.tunnel_pid = tunnel.pid
    write_json(STATE_DIR / "state.json", asdict(session))
    found: List[str] = []

    def url_ready() -> bool:
        url = find_tunnel_url(tunnel_log.read_text(errors="replace")) if tunnel_log.exists() else None
        if url:
            found.append(url)
        return url is not None

    if not wait_for(url_ready, TUNNEL_URL_SECONDS, lambda: tunnel.poll() is None):
        stop_session(quiet=True)
        raise StartGameError(f"cloudflared did not publish a tunnel URL:\n{tail(tunnel_log)}")
    session.url = found[-1]
    write_json(STATE_DIR / "state.json", asdict(session))

    wasm_size = (site / ENGINE_BINARY).stat().st_size
    print(f"Tunnel {session.url}; waiting until it serves the game...")
    page_ok = wait_for(lambda: http_status(session.page)[0] == 200, PUBLIC_READY_SECONDS, lambda: tunnel.poll() is None)
    wasm_status, wasm_length = http_status(f"{session.url}/{ENGINE_BINARY}", "HEAD") if page_ok else (0, -1)
    wasm_ok = wasm_status == 200 and wasm_length in (wasm_size, -1)
    if not (page_ok and wasm_ok):
        print(f"Warning: the public URL did not serve the game yet; processes keep running.\n{tail(tunnel_log)}")
        print(f"Check again with: tools/start_game.sh status   Link: {session.page}")
        return 1
    print(f"Public check passed ({ENTRY_PAGE} 200, {ENGINE_BINARY} {wasm_size} bytes).")
    print(f"Play: {session.page}")
    print("Stop with: tools/start_game.sh stop")
    return 0


def status(_args: argparse.Namespace) -> int:
    session = load_session()
    if session is None:
        print("Not running. Start with: tools/start_game.sh")
        return 1
    health = session_health(session)
    public = http_status(session.page)[0] == 200 if session.url and health["tunnel"] else False
    print(f"Commit {session.commit[:7]} ({session.source}), port {session.port}, started {session.started_at}")
    print(f"Server process: {'up' if health['server'] else 'down'}; local page: {'ok' if health['local'] else 'failing'}")
    print(f"Tunnel process: {'up' if health['tunnel'] else 'down'}; public page: {'ok' if public else 'failing'}")
    print(f"Link: {session.page if session.url else '(none yet)'}")
    healthy = all(health.values()) and public
    if not healthy:
        print("Unhealthy: run tools/start_game.sh --restart (a new tunnel gets a new link).")
    return 0 if healthy else 1


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="tools/start_game.sh", description=__doc__.splitlines()[0])
    parser.add_argument("command", nargs="?", default="start", choices=("start", "status", "stop", "install-cloudflared"))
    build = parser.add_mutually_exclusive_group()
    build.add_argument("--rebuild", action="store_true", help="always export the Web build again")
    build.add_argument("--no-build", action="store_true", help="serve the existing build/web as it is")
    parser.add_argument(
        "--from",
        dest="source",
        choices=("main", "current"),
        default="main",
        help="main: a dedicated checkout of the latest origin/main (default); current: this checkout",
    )
    parser.add_argument("--restart", action="store_true", help="restart even if a healthy session is running")
    parser.add_argument("--port", type=int, default=0, help="local port (default: a free one)")
    parser.add_argument("--cloudflared", help="path to the cloudflared binary")
    args = parser.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)  # keep our lines ordered with build.sh output
    try:
        if args.command == "status":
            return status(args)
        if args.command == "stop":
            stop_session()
            return 0
        if args.command == "install-cloudflared":
            return install_cloudflared()
        return start(args)
    except StartGameError as exc:
        print(f"start-game: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
