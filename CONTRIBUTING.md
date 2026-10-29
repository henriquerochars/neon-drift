# Contributing to Neon Drift

Thanks for wanting to help! Bug reports, balance feedback, new tracks, cars, art, sounds and
code are all welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Be kind. This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- Security problems go through a private report, never a public issue. See [SECURITY.md](SECURITY.md).

## Set up

You need Godot **4.7.2** (standard build), Python 3.9+, ffmpeg (audio and media tools) and Git.

```sh
tools/setup_godot.sh        # pinned Godot into .tools/ (Linux and macOS)
tools/agent.sh bootstrap    # import the project, create .venv for gdtoolkit
tools/godot.sh              # run the game
```

Or point `GODOT_BIN` at your own Godot 4.7.2 binary.

## Workflow

1. Fork, then create one branch per change (`feat/…`, `fix/…`, `docs/…`).
2. Keep the architecture rules in [AGENTS.md](AGENTS.md): static typing everywhere, no magic
   numbers (use `data/` resources or `data/balance/physics.csv`), networking only in `src/net/`,
   input only through `src/gameplay/input/`, and the layer graph `gameplay -> net/data -> core`,
   `ui -> gameplay`.
3. Every feature or fix ships with a headless gdUnit4 test under `tests/`.
4. Run the gate and make it pass:

   ```sh
   tools/agent.sh check     # lint, layer graph, balance, art, harness and headless tests
   ```

5. If players can see or feel the change (sprites, HUD, camera, handling, balance), attach a
   screenshot or GIF. `tools/playtest/` has capture tools; `tools/playtest/readme_media.sh`
   re-records the README media.
6. Use [Conventional Commits](https://www.conventionalcommits.org) (`feat(race): …`,
   `fix(net): …`) and open a pull request. CI runs the same checks.

## Adding content

- **A car:** a `CarDef` in `data/cars/`, eight rotations in `art/cars/<id>/`, then list it in
  `data/catalog.tres`.
- **A part:** a `PartDef` in `data/parts/` and a catalog entry.
- **A track:** a `TrackDef` in `data/tracks/` with its pieces, colours, background and scenery.
- Generated art goes through `tools/art/import_pixellab.py` so its provenance is recorded.

No code changes are needed for new content.

## Licensing of contributions

By contributing you agree that your code is released under the [MIT License](LICENSE) and your
art and audio under [CC BY 4.0](LICENSING.md). Only submit work you made or have the right to
license this way; no assets from other games.
