# PCGHelper

A procedural content generation toolkit for Celeste map editors (Lönn).
PCGHelper brings Unity procedural tilemap patterns, style-aware tileset era
handling, and MdMC/WFC generation into the Lönn editor, implementing the
pipeline from Robinet, Gómez-Maureira & Preuss, *"Towards a Celeste AI
Framework: Agent-free Automated 2D Level Generation for Multidirectional
Platformers"* (FDG '25,
[DOI 10.1145/3723498.3723796](https://doi.org/10.1145/3723498.3723796)):
skeleton layout → Multi-dimensional Markov Chain (MdMC) / WFC / noise tile
generation → playability repair → scoring → entity placement.

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

## Lönn Scripts

| Script | Location | Purpose |
|---|---|---|
| **Celeste PCG Pipeline** | `Loenn/scripts/celeste_pcg_pipeline.lua` | One-shot end-to-end generation of multiple rooms. Start with a **preset**: `quick` (small fast map), `simple_fair` (balanced, low-noise, fair both in-editor and in-game), `explore` (labyrinth), `challenge` (hazard-heavy) — or `custom` to use the individual knobs. |
| **Celeste Skeleton Generator** | `Loenn/scripts/celeste_skeleton.lua` | Lays out non-overlapping, edge-connected empty rooms (start room spawn + golden berry end room). |
| **Markov Level Generator** | `Loenn/scripts/markov_level_gen.lua` | Fills the current/selected rooms with MdMC / WFC / Hybrid / Unity-generated tiles. |

## Quick Start

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

## Companion CLI

For big maps and batch workflows, the
[loenn-mcp](https://github.com/Magedeline/loenn-mcp) project ships a
`pcgscene` CLI that can `scan`, `validate`, `fix`, `diff`, and `generate`
`.bin` maps outside the editor, with JSON reports and automatic backups.

## Dependencies

- Everest 1.808.0+
- LoennScripts 1.0.8+ (optional, for script UI fields)

## Disclaimer

This mod was developed with the assistance of **Claude (Anthropic)** as a
coding tool, implementing the algorithms published in the FDG '25 paper cited
above. The mod itself contains **no AI**: all generation is deterministic and
procedural (Markov chains, wave-function collapse, noise, BFS) — no models,
no API calls, no network access. All output has been human-tested in Lönn and
in-game.

## Credits

Procedural generator algorithms adapted from Robinet, Gómez-Maureira & Preuss (FDG '25): [https://dl.acm.org/doi/10.1145/3723498.3723796](https://dl.acm.org/doi/10.1145/3723498.3723796)
