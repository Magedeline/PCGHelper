# PCGHelper

A procedural content generation toolkit for Celeste map editors (Lönn). PCGHelper brings Unity procedural tilemap patterns, style-aware tileset era handling, and an AI-powered map generation workflow into the Lönn editor.

## Features

- **Unity Procedural Generators** — ported from the classic Unity tilemap procedural generation blog posts:
  - Perlin top-surface / platform generation
  - Perlin cave
  - Random-walk cave
  - Directional tunnel
  - Cellular automata cave
- **Style & Tileset Era Support** — generate rooms using `new` (post-Farewell) or `old` (classic) tile IDs, auto-detect from training rooms, or mix.
- **MdMC / WFC / Hybrid Modes** — train a Multi-dimensional Markov Chain on existing rooms, generate with Wave Function Collapse, or combine both.
- **AI Map Generation** — build a generation request for the gamelab PCG AI MCP server and import the resulting JSON map back into Lönn.
- **Smart Placement** — entities, decals, and triggers placed based on room geometry and style.

## Lönn Scripts

| Script | Location | Purpose |
|--------|----------|---------|
| Celeste PCG Pipeline | `Loenn/scripts/celeste_pcg_pipeline.lua` | One-shot generation of multiple rooms |
| Markov Level Generator | `Loenn/scripts/markov_level_gen.lua` | Single-room MdMC / WFC / Hybrid / Unity generation |
| PCGHelper AI: Build Generation Request | `Loenn/scripts/pcg_ai_request.lua` | Export current map as an AI generation request |
| PCGHelper AI: Import Generated Map | `Loenn/scripts/pcg_ai_import.lua` | Import AI-generated JSON into the current map |

## Quick Start

1. Install the mod through Everest (or unzip the release into your `Mods` folder).
2. Open Lönn and load a map.
3. Run **Celeste PCG Pipeline** or **Markov Level Generator** from the Scripts menu.
4. For AI generation, run **PCGHelper AI: Build Generation Request**, send the request to the gamelab-mcp server, then run **PCGHelper AI: Import Generated Map**.

## Configuration

- `Loenn/pcg/pcg_config.json` — presets, server URL, and output format for the AI workflow.
- `Loenn/pcg/entity_catalog.json` — entity catalog used by the AI generator (vanilla Celeste by default).

## Dependencies

- Everest 1.808.0+
- LoennScripts 1.0.8+ (optional, for script UI fields)

## Credits

Procedural generator algorithms adapted from the Unity tilemap procedural generation blog series. AI integration based on the DZ mod PCG AI workflow.
