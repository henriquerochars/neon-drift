---
name: start-game
description: Build the latest Neon Drift main branch for the Web and publish it through a Cloudflare quick tunnel so the human can play it in any browser. Use when the user asks to start, run, play, test or share the game in a browser, wants a link to the current main, or says a previous game link stopped working.
---

Serve the game through `tools/start_game.sh` (details in the header of `tools/start_game.py`).
Talk to the human in pt-BR.

1. **Always serve the latest `main`** unless the human names another branch. The default
   `tools/start_game.sh` (same as `start --from main`) fetches `origin/main` and moves a
   dedicated detached worktree (`~/.cache/neon-drift/play-main`, override with
   `NEONDRIFT_PLAY_CHECKOUT`) to it. It never switches, stashes or resets the human's checkout.
   To serve the work in progress instead, run `tools/start_game.sh --from current` and say so.
2. The script exports `tools/build.sh web` when the last export does not match the served
   commit, serves a copy on 127.0.0.1 and opens a `trycloudflare.com` tunnel over HTTP/2.
   A healthy session for the same commit and source is reused.
   - `cloudflared not found`: on Linux run `tools/start_game.sh install-cloudflared`; on macOS
     ask the human to run `brew install cloudflared`.
   - The first run in a fresh play checkout imports the whole project (a few minutes).
   - Build failure: quote the failing lines of the log the script names; do not edit code
     unless the task covers the fix. "No space left on device": report it, never delete
     files you did not create.
   - The play checkout has local changes: it is reserved for this skill; tell the human,
     do not discard anything yourself.
3. Report the `Play:` link only after the script printed `Public check passed`. If a browser
   preview tool is available, open the link and check that the game leaves the Godot loading
   bar and shows the title screen before saying it loads; otherwise say you only checked HTTP.
4. Tell the human: the commit served, that the link is public to anyone holding it, that it
   lasts while this machine keeps the detached processes running, that a restarted tunnel gets
   a new link, and that the browser build plays solo races only (online rooms use ENet/UDP,
   which browsers cannot open).
5. "The link stopped working": run `tools/start_game.sh status`. If anything is down, run
   `tools/start_game.sh --restart` and send the new link.
6. When the human is done, or asks to stop sharing, run `tools/start_game.sh stop`.

Do not expose any other directory and do not start long-lived servers or tunnels by hand
outside the script.
