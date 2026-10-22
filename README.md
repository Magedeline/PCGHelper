<div align="center">

# PCGHelper

**Procedural level generation for [Celeste](https://www.celestegame.com/), built as [Lönn](https://github.com/CelestialCartographers/Loenn) scripts.**

[![Latest release](https://img.shields.io/github/v/release/Magedeline/PCGHelper?label=release)](https://github.com/Magedeline/PCGHelper/releases/latest)
[![FDG '25 paper](https://img.shields.io/badge/paper-FDG%20%2725-blue)](https://doi.org/10.1145/3723498.3723796)

</div>

Implements the pipeline from Robinet, Gómez-Maureira & Preuss,
*"Towards a Celeste AI Framework: Agent-free Automated 2D Level Generation
for Multidirectional Platformers"* (FDG '25,
[DOI 10.1145/3723498.3723796](https://doi.org/10.1145/3723498.3723796)):
skeleton layout → Multi-dimensional Markov Chain (MdMC) / WFC / noise tile
generation → playability repair → scoring → entity placement.

## Contents

- [Features](#features)
- [Lönn scripts](#lönn-scripts)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Fairness guarantees](#fairness-guarantees)
- [seleCte port](#selecte-port)
- [Companion CLI](#companion-cli)
- [Dependencies](#dependencies)
- [Disclaimer](#disclaimer)
- [Credits](#credits)

## Features

- **Unity Procedural Generators** — ported from the classic Unity tilemap procedural generation blog posts:
  - Perlin top-surface / platform generation
  - Perlin cave
  - Random-walk cave
  - Directional tunnel
  - Cellular automata cave
- **Simplex Noise Generators** — Ken Perlin's simplex algorithm (ported from [weswigham/simplex](https://github.com/weswigham/simplex)), fewer directional artifacts and cheaper per sample than the classic Perlin noise above:
  - Simplex top-surface / platform generation
  - Simplex cave
  - Simplex FBM cave (layered octaves for richer, less uniform texture)
- **Style & Tileset Era Support** — generate rooms using `new` (post-Farewell) or `old` (classic) tile IDs, auto-detect from training rooms, or mix.
- **MdMC / WFC / Hybrid Modes** — train a Multi-dimensional Markov Chain on existing rooms, generate with Wave Function Collapse, or combine both.
- **Smart Placement** — entities, decals, and triggers placed based on room geometry and style.

## Lönn scripts

| Script | Location | Purpose |
|---|---|---|
| **Celeste PCG Pipeline** | `Loenn/scripts/celeste_pcg_pipeline.lua` | One-shot end-to-end generation of multiple rooms. Start with a **preset**: `quick` (small fast map), `simple_fair` (balanced, low-noise, fair both in-editor and in-game), `explore` (labyrinth), `challenge` (hazard-heavy) — or `custom` to use the individual knobs. |
| **Celeste Skeleton Generator** | `Loenn/scripts/celeste_skeleton.lua` | Lays out non-overlapping, edge-connected empty rooms (start room spawn + golden berry end room). Optionally gates some connections behind a `lockBlock` + key for metroidvania-style progression. |
| **Markov Level Generator** | `Loenn/scripts/markov_level_gen.lua` | Fills the current/selected rooms with MdMC / WFC / Hybrid / Unity-generated tiles. |
| **Celeste PCG Runner** | `Loenn/scripts/celeste_pcg_runner.lua` | Alternate generator: deterministic path-carve layout (guaranteed-traversable by construction, vs. MdMC/WFC above). Writes a brand-new standalone chapter to disk via the bundled [celeste-pcg](Loenn/pcg_engine/celeste-pcg) Node tool instead of editing the open map. Requires Node.js on PATH — see [Dependencies](#dependencies). |
| **seleCte Level Generator (MdMC, pure Lua)** | `Loenn/scripts/selecte_level_gen.lua` | Native Lua port of [seleCte](https://github.com/robilouis/seleCte), the research generator behind the FDG '25 paper: tree-shaped skeleton → rooms sampled from a Markov model trained on all 824 vanilla rooms (shipped) → A* route check → spawn + crystal heart. Adds the rooms to the open map, or writes a standalone chapter `.bin` with `HeartIsEnd` metadata like seleCte's Julia encoder. Can also re-train the model in-editor from the open map or a folder of `.bin` maps, and fill the background layer from a per-chapter model. No Python, Julia or Node — see [seleCte port](#selecte-port). |
| **Analyze Map (Node)** | `Loenn/scripts/celeste_pcg_analyze.lua` | Read-only playability/connectivity report for the **currently open, saved** map: per-room spawn + reachable-space checks, plus rooms that touch on the world grid with no carved opening between them. Logs to the Lönn console; does not change the map. Requires Node.js on PATH. |

## Installation

**Via Everest:** drop the mod into your Celeste `Mods` folder (as a subfolder,
or as the zip from the [latest release](https://github.com/Magedeline/PCGHelper/releases/latest))
and let Everest load it on next launch.

**Manual:**
```bash
git clone https://github.com/Magedeline/PCGHelper.git
```
then copy (or symlink) the `PCGHelper` folder into `Celeste/Mods/`.

Either way you'll need [Lönn](https://github.com/CelestialCartographers/Loenn)
installed to run the scripts — see [Dependencies](#dependencies).

## Quick start

1. Install the mod through Everest (or unzip the release into your `Mods` folder).
2. Open Lönn and load a map.
3. Run **Celeste PCG Pipeline**, **Celeste Skeleton Generator**, or **Markov Level Generator** from the Scripts menu.

## Fairness guarantees

Generated maps are held to a checkable standard, not a vibe:

- every room gets a **player spawn point** (dying in a spawn-less room errors
  out in-game, so this is enforced as a safety net after any placement path)
- rooms are only accepted when their **real exits are BFS-connected**
  (works for vertical rooms), with door openings carved before scoring
- skeleton connections are only counted when the shared edge is wide enough
  to actually carve a door — no more sealed dead ends
- rooms where the Markov model degenerated into random tiles are rejected
- scoring follows the paper (§4.1–4.3) with normalized entropy, path-based
  area-of-interest, and capped scarcity, so "most interesting" can no longer
  mean "most random"
- optional lock-and-key gating (`lockCount` in the Skeleton Generator) only
  ever places keys in rooms reachable from spawn without crossing a locked
  door, so every key is guaranteed collectible before it's needed

## seleCte port

[seleCte](https://github.com/robilouis/seleCte) (MIT, Louis Robinet) is the
reference implementation of the paper this mod is built on. Upstream it is a
Python package plus two Julia scripts (`data_loader.jl` to dump `.bin` maps
into training csvs, `data_to_level.jl` to encode a generated level back into
a `.bin` through a fork of Maple). `Loenn/library/selecte/` is a complete
native-Lua port of that pipeline, so the **seleCte Level Generator** script
runs it inside Lönn with no external runtime:

| Upstream | Lua port |
|---|---|
| `utils/data/tiles_info.json`, Maple `entity_map.jl` | `alphabet.lua` — the tile alphabet, the glyph→entity table (offsets, size search, attribute defaults), MdMC mask parsing |
| `probability_estimation_dicts/*.json` (the trained model) | `dpe_data.lua` — all 19 dicts (`pe_d5_full`, `fg_1..9`, `bg_1..9`), generated by `scripts/convert-selecte-dpe.js` |
| `utils.py` sampling, `dpe_generation.py` | `mdmc.lua` — room sampling with backtracking, and model estimation from a corpus |
| `celeskeleton.py` | `skeleton.lua` — rooms, exits, `connect`, `generate_celeskeleton`, traversal path, spawn/heart placement |
| `utils.py` A\* and metrics | `playability.lua` — A\* (open/closed lists keyed by position), difficulty and interestingness metrics |
| `level_generation.py` | `level.lua` — the bounded resample / redraw loops |
| `data_to_level.jl` + Maple `FgTiles`/`entityMap`, `metadata.jl` | `encoder.lua` — grid → fg tiles + entities, the y-axis flip, and the `.bin` tree with chapter `meta` (`HeartIsEnd`) |
| `data_loader.jl`, `recombine_fg_entities.py`, `collect_bg_rooms.py` | `recombine.lua` — rooms (from the open map or a decoded `.bin`) → corpus grids |
| numpy's global RNG | `rng.lua` — seedable, so the same seed gives the same level |

The `.bin` writer reuses `Loenn/pcg_engine/celeste-pcg/lua/binary_packer.lua`.
Two deliberate deviations from upstream, both marked in the source: a start or
end room with a single exit is accepted once its spawn/heart demonstrably
reaches that exit (upstream always rejects such rooms, see the TODO in its
`celeskeleton.py`), and the respawn ledge under each entrance is written after
the surrounding pocket is cleared rather than before (upstream cleared it away
again). Everything else — including A\*'s no-gravity movement model and the
one-tile decode drift of point entities — is the same, so seleCte's own
[limitations](https://github.com/robilouis/seleCte#limitations) apply.

Tests: `love Loenn/library/selecte/test` (LÖVE is LuaJIT, the runtime Lönn
runs on) writes `test_report.txt` next to the suite; `node scripts/validate.js`
runs it too when `love` is on PATH.

## Companion CLI

For big maps and batch workflows, the
[loenn-mcp](https://github.com/Magedeline/loenn-mcp) project ships a
`pcgscene` CLI that can `scan`, `validate`, `fix`, `diff`, and `generate`
`.bin` maps outside the editor, with JSON reports and automatic backups:

```bash
pip install loenn-mcp
pcgscene scan MyMap.bin
```

## Dependencies

- Everest 1.808.0+
- LoennScripts 1.0.8+ (optional, for script UI fields)
- Node.js 18+ on PATH (optional, only needed for the **Celeste PCG Runner** and **Analyze Map (Node)** scripts — the other Lönn scripts are pure Lua and need nothing extra)

## Dev scripts

Repo-root Node scripts for maintaining the mod (not needed to just play it):

| Script | Purpose |
|---|---|
| `node scripts/validate.js` | Pre-release content check: everest.yaml sanity, every Lönn script looks well-formed, the vendored [celeste-pcg](Loenn/pcg_engine/celeste-pcg) test suite passes, a generate→analyze smoke test comes back clean, and — when `love` is on PATH — the two Lua test suites (celeste-pcg's Lua port and the seleCte port) pass. Runs in CI on every push/PR (`.github/workflows/test.yml`). |
| `node scripts/convert-selecte-dpe.js <seleCte checkout>` | Regenerates `Loenn/library/selecte/dpe_data.lua` from seleCte's trained `probability_estimation_dicts/`. Only needed to pick up a retrained upstream model; the committed file holds seleCte 0.10.0's. |
| `node scripts/package-release.js` | Builds `dist/PCGHelper.zip` via `git archive` (tracked files only, matching the layout of every past release: `everest.yaml` + `Loenn/` at the zip root). Refuses to run with uncommitted changes. Packaging only — attaching it to a GitHub release is a separate, manual step. |

## Disclaimer

This mod was developed with the assistance of **Claude (Anthropic)** as a
coding tool, implementing the algorithms published in the FDG '25 paper cited
above. The mod itself contains **no AI**: all generation is deterministic and
procedural (Markov chains, wave-function collapse, noise, BFS) — no models,
no API calls, no network access. All output has been human-tested in Lönn and
in-game.

## Credits

Procedural generator algorithms adapted from Robinet, Gómez-Maureira & Preuss (FDG '25): [https://dl.acm.org/doi/10.1145/3723498.3723796](https://dl.acm.org/doi/10.1145/3723498.3723796)

`Loenn/library/selecte/` is a Lua port of [seleCte](https://github.com/robilouis/seleCte) by Louis Robinet (MIT), including its trained MdMC model, and of the `entityMap`/`FgTiles` routines and chapter metadata defaults of [Maple](https://github.com/CelestialCartographers/Maple) (Celestial Cartographers, MIT) as pinned by seleCte's fork.
