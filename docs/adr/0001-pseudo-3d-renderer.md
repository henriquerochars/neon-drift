# ADR 0001 — Pseudo-3D segment renderer

Status: accepted (2026-10-29).

Decision: the road is a list of segments (curve, hill, length) projected per frame with
the classic "camera depth" projection and drawn as polygons in a `Node2D._draw`, with
sprites scaled by projection. No 3D nodes, no Mode-7 shader.

Why: it is the exact look of the reference (OutRun/Top Gear/GBA racers), runs on the
Compatibility renderer and Web, and keeps the simulation 1D along the track plus a
lateral axis, which makes networking and AI simple.

Consequences: hills and curves are faked (no real 3D collision); all gameplay geometry
is `TrackModel` queries by `z`.
