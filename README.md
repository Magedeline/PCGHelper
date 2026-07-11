# PCGHelper

A procedural content generation toolkit for Celeste map editors (Lönn). PCGHelper brings Unity procedural tilemap patterns, style-aware tileset era handling, and MdMC/WFC generation into the Lönn editor.

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

| Script                 | Location                                  | Purpose                                            |
|------------------------|-------------------------------------------|----------------------------------------------------|
| Celeste PCG Pipeline   | `Loenn/scripts/celeste_pcg_pipeline.lua`  | One-shot generation of multiple rooms              |
| Markov Level Generator | `Loenn/scripts/markov_level_gen.lua`      | Single-room MdMC / WFC / Hybrid / Unity generation |

## Quick Start

1. Install the mod through Everest (or unzip the release into your `Mods` folder).
2. Open Lönn and load a map.
3. Run **Celeste PCG Pipeline** or **Markov Level Generator** from the Scripts menu.

## Dependencies

- Everest 1.808.0+
- LoennScripts 1.0.8+ (optional, for script UI fields)

## Credits

Procedural generator algorithms adapted from this link of the blog series: [https://dl.acm.org/doi/10.1145/3723498.3723796](https://dl.acm.org/doi/10.1145/3723498.3723796)
