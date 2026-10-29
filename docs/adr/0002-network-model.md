# ADR 0002 — Networking model

Status: accepted (2026-10-29).

Decision: Godot high-level multiplayer over `ENetMultiplayerPeer`. Each peer has authority
over its own `CarState` (zero input latency, interpolation on others). The host (peer 1)
owns the race phase, clock, finish order and the verdict of crush/landing events, which
clients only report. Up to 8 peers. Join by address:port; NAT traversal is backlog.

Why: a racer tolerates peer-owned positions far better than input-latency; the host
still arbitrates everything that decides the result.
