---
name: neon-evidence
description: Capture runtime evidence (screenshots, GIFs, seeded race metrics) for a Neon Drift change a player would see or feel, or when the user asks to see the game.
---

1. Decide the evidence kind: visual (screenshot/GIF) or metrics (seeded race batch).
2. Read the header of the capture script under `tools/playtest/` for its exact arguments.
   Launch only through `tools/godot.sh`; rendering needs a display (`xvfb-run` works).
3. Record the seed and `git rev-parse --short HEAD` with every artefact under
   `docs/qa/<topic>-<YYYY-MM-DD>/`. Look at the image yourself before describing it.
4. Report measured facts only. Whether it looks or feels right is the human's decision.
