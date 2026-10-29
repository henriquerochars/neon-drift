# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's private reporting instead:
**Security → Report a vulnerability** on this repository. You will get an answer as soon as
possible, and we will agree on a disclosure date once a fix is ready.

Useful details: the version or commit, your platform, steps to reproduce, and the impact.

## Scope

The most relevant areas are the online multiplayer layer (`src/net/`: ENet host/join, lobby
and race messages a malicious peer could send), save and settings files under `user://`, and
the build and CI scripts. Only the latest commit on `main` receives fixes.
