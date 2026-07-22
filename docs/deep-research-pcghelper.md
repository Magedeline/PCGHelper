# PCGHelper Deep Research — Robustness, CLI Pipeline, and In-Game Reliability

*Research date: 2026-07-22. Sources: FDG '25 paper "Towards a Celeste AI Framework" (Robinet, Gómez-Maureira, Preuss — DOI 10.1145/3723498.3723796), the PCGHelper Lönn mod (this repo, v1.2.0), and the loenn-mcp server (E:\Celeste\loenn-mcp, v6.0.0).*

---

## 1. What exists today

Three pieces make up the current ecosystem:

| Piece | Where | Role |
|---|---|---|
| **PCGHelper Lönn mod** | this repo (`Loenn/scripts`, `Loenn/library`) | In-editor generation: skeleton layout, MdMC/WFC/noise tile fill, repair, scoring, entity placement. Pure Lua, no AI. |
| **loenn-mcp server** | `E:\Celeste\loenn-mcp` | Headless .bin reader/writer + MCP tools (`pcg_score_room`, `pcg_pipeline`, `pcg_skeleton_generate`, `pcg_markov_fill`) + **AI tools** (`ai_analyzer.py`, hard `anthropic` dependency). |
| **FDG '25 paper** | the PDF | Defines the algorithms: Celeskeleton (§3.3.1), MdMC with backtracking (§3.3.2), playability via Celeste-A* + path-AOI (§4.1), interestingness I (§4.2), difficulty D (§4.3), and a reference CLI (Appendix A). |

There is **no CLI today** — the only entry points are Lönn script dialogs (45+ raw parameters) and MCP tool calls. The scoring logic is duplicated in Lua (`pcg_toolkit.lua`) and Python (`loenn_mcp/pcg.py`), which will drift apart over time.

---

## 2. Paper vs. implementation — fidelity gaps that cause real problems

These are places where the port deviates from the paper in ways that directly explain the symptoms you described (over-randomness, unreliable scoring on big rooms):

### 2.1 AOI is a static box, not the path (paper §4.1)
The paper defines the Area of Interest as *n* tiles around the **found path** — "where the player will actually be." The Lua port (`pcg_toolkit.lua:1378-1382` and `1458-1460`) uses the **center third of the room** as a fixed box. Local NLE density, LE density, and scarcity are therefore measured in a region the player may never visit. On big rooms the center box and the actual route diverge badly → scores stop meaning anything → the accept/reject filter passes bad rooms.

**Fix:** compute the BFS path first (already done), then build AOI = path tiles ± 2 rows, and measure `d_local`, `le_local`, `scarcity` inside that mask. This is a small change since `pcg.score` already collects path cells.

### 2.2 Scoring is horizontal-only (paper's core challenge was verticality)
`pcg.bfsPathLength` (`pcg_toolkit.lua:1335-1368`) starts at a random row **in the bottom half of the left edge** and succeeds only when reaching `x == w-2` (right edge). Vertical rooms — the thing that makes Celeste Celeste — score as "no path" or get nonsense means/variances. This also poisons `passesVarianceCheck` and hole frequency `Hf = holes / pathLen`.

**Fix:** detect the room's actual exits (border air runs, which the rando-YAML exporter already computes in `celeste_pcg_pipeline.lua:436-473`) and run BFS **exit-to-exit** for every exit pair. Score the room on the worst/mean over real exit pairs. This single change makes scoring correct for vertical, horizontal, and multi-exit rooms, and it reuses code you already have.

### 2.3 Maximizing interestingness selects the *most random* room
The candidate loop (`celeste_pcg_pipeline.lua:663-703`) keeps the candidate with the **highest** I. But I contains an **unnormalized Shannon entropy** term (`w3 * entropy`, `pcg_toolkit.lua:1487`) — and entropy is maximized by uniformly random tile soup. With default `w1=w2=w3=1`, "pick the best room" literally means "pick the noisiest room." This is the direct mechanical cause of *"when they adjust between too little or too much it gets too randomized."*

**Fix (three parts):**
1. Normalize entropy by `log(T)` (T = tile alphabet size) so it's in [0,1] like the density terms.
2. Replace *maximize I* with a **target band**: accept the candidate whose I and D are closest to a preset target `(I*, D*)`, i.e. minimize `|I−I*| + λ|D−D*|`. The paper's user study (§4.2.2) showed high-I rooms weren't what players liked anyway — beginners liked mid-I rooms.
3. Cap scarcity: `scarcity = min(1/d_local, 20)` instead of the `999` sentinel (`pcg_toolkit.lua:1439, 1532`). The 999 makes D explode on any sparse room, which is exactly the instability the paper flagged in §4.3.1 (Fig. 18) — the port kept the flaw.

### 2.4 `isPlayable` is a weak gate
`pcg_toolkit.lua:1310-1332` accepts any room with ≥15% air, ≥3 floor columns and ≥2 rows of floor-height variety. Random noise passes this easily. After 2.2 lands, replace it with "every real exit pair is BFS-connected AND path passes the variance check" — the paper's actual criterion.

---

## 3. Bug / patch list (ranked by in-game impact)

### P0 — things that break maps in-game

1. **Rooms with no spawn point.** The pipeline only places a `player` entity in the start room (and in filled rooms via `placeAll`). Any reachable room without a spawn crashes Celeste on death/retry in that room (Everest error: no spawn found). **Patch:** after entity placement, assert every generated room has ≥1 `player` entity on a floor tile near an entrance; add one if missing. This belongs in a `validate`/`repair` pass, and it's the #1 "map works in editor but breaks in game" cause.
2. **Connectivity mismatch: skeleton says connected, game says wall.** The skeleton counts two rooms as neighbours with a shared span of ≥2 tiles (`shareExit`, `celeste_pcg_pipeline.lua:177-185`), but `carveSharedExit` refuses to carve when the shared span is <5 tiles (`:308, :335`). Any pair in the 2-4 tile range stays sealed → dead ends / unreachable end room in-game, invisible in the editor. **Patch:** use the same threshold (≥5) in both places, or grow/slide rooms until every graph edge is carvable, and re-run global reachability *on the carved tiles* (not the skeleton graph) before finishing.
3. **Score suffix in room names.** `room.name = room.name .. "  I=0.42"` (`celeste_pcg_pipeline.lua:742-743`). Spaces/`=`/`.` in room names break debug-console teleports, checkpoint references, and make rando YAML references fragile. **Patch:** never encode metadata in names; write scores to the generation report (see §6 CLI) or Lönn log only.
4. **Golden berry is not a golden berry.** `addEntity(room, "strawberry", …, { golden = true })` (`celeste_skeleton.lua:269`, pipeline fallback path `:832`). The real entity is `goldenBerry`; the `golden` attr on `strawberry` is ignored in-game, so the "end" reward silently becomes a normal berry. The rando exporter even searches for both names (`:479`) — the writer should just emit `goldenBerry`.
5. **map.bin writes are not atomic and have no backup** (loenn-mcp side — ~30 call sites of `cb.write_map(path, data)` in `server.py`). A crash mid-write, or writing a subtly wrong tree, destroys the only copy. **Patch (small, high value):** in `celeste_bin.write_map`: (a) serialize to bytes, (b) **re-parse those bytes with `read_map` as a round-trip self-check**, (c) write to `path + ".tmp"`, (d) copy existing file to a timestamped `.bak` (keep last N), (e) `os.replace(tmp, path)` (atomic on Windows). After this, a bad write can never eat a map again — this is the direct answer to "get the map working in game without breaking the map.bin entirely."

### P1 — correctness / quality

6. **Scoring fidelity issues** — §2.1–2.4 above.
7. **`preserveExits` is a no-op in the pipeline.** It reads `room.tilesFg` of the *freshly created empty room* as the "original" (`celeste_pcg_pipeline.lua:735-738`), so every border reads as "has exit" and the pass changes nothing. Harmless but misleading — remove it from the pipeline path (it's only meaningful in `markov_level_gen.lua` where a real room exists).
8. **Silent room-count shortfall.** `buildSkeleton` gives up on a room after `maxRetries` placement attempts without logging; `resetSkeleton` only retries when fewer than 2 rooms exist (`:633-639`). Users ask for 20 rooms and silently get 14. Log the shortfall and retry with relaxed constraints.
9. **Backtracking degeneration.** When MdMC backtracking exhausts, a random tile is assigned (paper §3.3.2 accepts this). Combined with §2.3 it amplifies noise. Track a per-room "degeneration count" and reject rooms above a threshold — cheap and very effective against the "too random" complaint.

### P2 — hygiene

10. Duplicated skeleton code between `celeste_skeleton.lua` and `celeste_pcg_pipeline.lua` (drift already visible: variable sizes vs fixed sizes).
11. Duplicated scoring in Lua and Python — pick one source of truth (the CLI, §6) and have the other call it or port from it verbatim with shared test fixtures.
12. `PCGHelper.zip` committed at repo root — stale release artifact; move to GitHub Releases.

---

## 4. The randomness/fairness problem — presets instead of 45 knobs

The pipeline dialog exposes ~45 raw parameters. The paper's own findings give the calibration: config `000011012`, backtracking depth 2, training on a *single coherent level* (playability 0.55-0.76), and mid-range interestingness preferred by players. Nobody should have to rediscover that per run.

**Design: 4 named presets + an Advanced toggle.** Same presets in the Lönn dialog and the CLI, defined once in a shared table:

| Preset | Intent | Key values |
|---|---|---|
| **Quick** | fast, small, safe — "I just want a playable map now" | 6 rooms 40×23, mdmc, bt=2, tries=10, target I* = median, hazards 0.02, no BG/decals |
| **Simple & Fair** | the one you described: quick, simple, fair in game and editor | 8-10 rooms, mdmc, bt=2, target band I*±0.15 with normalized entropy, D* low, degeneration threshold strict, spawn-per-room on |
| **Explore** | labyrinth, loops, bigger rooms | proba 0.8, loopbacks on, larger sizes, D* mid |
| **Challenge** | for experienced players | hazards up, scarcity target higher, D* high — honest about the paper's limits here (§5 of paper: difficulty control is the weakest area) |

"Fair" becomes measurable: a room is *fair* when (a) every exit pair is connected, (b) path variance passes, (c) degeneration count ≈ 0, (d) D within band, (e) spawn exists, (f) no spike placed on the only path tile (check spike cells against the path mask). That's an objective gate, not a vibe — and it's the same gate in the editor and in the CLI, so in-game and in-editor results agree.

Seeds: every run logs its seed (already supported, `-1` = random); presets always print the effective seed so a "fair" result is reproducible.

---

## 5. Removing the AI — and the disclaimer

**Finding: the PCGHelper mod itself contains zero AI.** All Lua is pure algorithms (MdMC, WFC, noise, BFS). The AI lives in **loenn-mcp**:

- `loenn_mcp/ai_analyzer.py` (Claude API calls, `claude-3-5-sonnet` default)
- 3 MCP tools: `ai_analyze_map`, `ai_describe_room`, `ai_suggest_entities`
- `pyproject.toml:28` — `anthropic>=0.40.0` is a **hard install dependency** even for users who never touch AI tools

**Removal plan:**
1. Delete `ai_analyzer.py` and the three `ai_*` tool registrations in `server.py`.
2. Drop `anthropic` from `dependencies` (nothing else imports it — verify with a grep before release).
3. Bump loenn-mcp major version; note the removal in RELEASE_NOTES.
4. Nothing in the PCGHelper mod changes — it never had AI.

**Disclaimer** (honest and standard practice; put in both READMEs and the GameBanana page):

> PCGHelper was developed with the assistance of Claude (Anthropic) as a coding tool, based on the algorithms published in Robinet et al., *"Towards a Celeste AI Framework"* (FDG '25). All generation is deterministic/procedural — the mod contains no AI models and makes no network calls. All output has been human-tested in Lönn and in-game.

---

## 6. The CLI: `pcgscene` — one pipeline, three frontends

You asked for two CLI things: a **PCG scene pipeline CLI** (replace ad-hoc scripts, scale to big maps) and a **Lönn CLI** ("so the map editor knows what's going on"). They should be one tool. loenn-mcp already has everything needed (bin parser, pcg module, no Lönn dependency) — add a `cli.py` and a console entry point beside the existing `loenn-mcp` script (`pyproject.toml [project.scripts]`).

The paper's Appendix A CLI is the model (`--config`, `--training-dataset`, `--nb-rooms`, `--proba`, `--room-size`, `--bt-depth`, `--tries-limit`, `--reset-skeleton`) — keep those flags for familiarity, add the safety/scale layer:

```
pcgscene scan <map.bin> [--json report.json]     # score every room (I, D, playability,
                                                 #   exit connectivity, spawn check, fairness gate)
                                                 #   → the "patch or bug fixes by scanning rooms" ask
pcgscene fix <map.bin> [--only spawns,exits]     # apply safe auto-repairs (spawn-per-room,
                                                 #   carve missed exits, degeneration cleanup);
                                                 #   always writes .bak + atomic replace
pcgscene generate <map.bin> --preset simple-fair [--seed N] [--rooms 12] [--train <other.bin>]
pcgscene validate <map.bin>                      # round-trip parse + Everest-load checklist,
                                                 #   exit code 0/1 → usable in CI or pre-package
pcgscene score <map.bin> --room lvl_3            # one-room deep report
pcgscene diff <a.bin> <b.bin>                    # what changed (rooms, entities, tiles) —
                                                 #   "know what's going on" for map editors
```

Design rules that make it work on big maps with lots of rooms:

- **Batch-first**: `scan` iterates all rooms in one pass; Python BFS on a 120×69 room is milliseconds, so a 200-room map scans in seconds (contrast the paper's A* at 15-329 s/room — BFS + exit-pairs is the cheap approximation that scales).
- **JSON everywhere** (`--json`): the report is machine-readable so Lönn (via the existing `install_loenn_manager` bridge or a "Load PCG report" script) can highlight flagged rooms in-editor. That's the honest version of a "Lönn CLI" — Lönn itself is a GUI app with no headless mode, so the CLI operates on the same .bin and feeds results *back into* Lönn, rather than pretending to drive Lönn.
- **Never destructive**: every write path goes through the atomic-write + backup + round-trip-validate `write_map` from §3.5. `--dry-run` on `fix` and `generate` prints the plan without writing.
- **Deterministic**: `--seed` respected end-to-end; the report records seed + preset + version so any map can be regenerated or bisected.
- **Single source of truth**: the Lua mod stays for interactive in-editor use; the CLI/Python becomes the reference implementation for scoring, with shared test fixtures (same room grid → same I/D in both, within tolerance) to stop drift.

---

## 7. In-game reliability checklist (why maps break, in one list)

A generated map loads and plays in Celeste iff:

1. .bin round-trips through the parser (guard: validate-on-write, §3.5).
2. Every reachable room has ≥1 spawn (`player` entity) on solid ground (§3.1).
3. Start room spawn is not inside solid tiles.
4. Every skeleton edge is actually carved through tiles (§3.2), and tile-level BFS confirms start→end reachability across rooms.
5. Room names are simple identifiers (no spaces/`=`) (§3.3).
6. Only real entity names are emitted (`goldenBerry` not `strawberry{golden}`) (§3.4).
7. Tile characters all exist in the target tileset era (already handled by `resolveTileForStyle`; keep a validation that unknown chars never reach `innerText`).
8. No room exceeds Everest practical limits (very large `innerText` strings are fine — RLE handles them — but keep rooms ≤ ~200×200 tiles).

`pcgscene validate` checks all eight; `pcgscene fix` repairs 2-6 automatically.

---

## 8. Suggested roadmap

**Phase 1 — Safety (small diffs, do first):** atomic/backup/round-trip `write_map`; spawn-per-room repair; carve-threshold mismatch fix; remove name suffix; `goldenBerry` fix. *Result: maps stop breaking in-game and map.bin can't be destroyed.*

**Phase 2 — Scoring truth:** exit-pair BFS scoring; path-based AOI; normalized entropy; scarcity clamp; degeneration counter; replace `isPlayable`. Port to both Lua and Python with shared fixtures. *Result: scores mean what the paper meant; "scan" is trustworthy.*

**Phase 3 — CLI:** `pcgscene` with `scan`/`validate`/`fix`/`score` first (read-mostly, immediate value on big maps), then `generate`/`diff`. JSON reports + Lönn report-viewer script.

**Phase 4 — Fairness presets:** the 4 presets + target-band acceptance, exposed identically in the Lönn dialogs and CLI; collapse the 45-knob dialog behind an Advanced toggle.

**Phase 5 — De-AI release:** strip `ai_analyzer.py` + `anthropic` dep from loenn-mcp, add the disclaimer to both READMEs, ship PCGHelper v1.3.0 + loenn-mcp v7.0.0.
