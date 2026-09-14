# celeste-pcg

Procedural **multi-room chapter** generator for Celeste mods.

One generator core, two emitters:

| Emitter | Output | Use |
|---|---|---|
| `emit-bin` | a single Celeste `.bin` map (`<Map><levels>…`) + `everest.yaml` | drop into `Celeste/Mods/`, load in‑game with **F6** |
| `emit-ogmo` | one Ogmo Editor 3 level `.json` per room + a copy of `celeste.ogmo` | open in **OgmoEditor3‑CE** to hand‑edit any room |

Same seed → byte‑identical output, on any machine.

## Usage

```bash
node bin/celeste-pcg.js --seed forsaken-01 --rooms 8 --name MyChapter --music music_city --preview
```

```
--seed <str>        deterministic seed                 (default: celeste-pcg)
--rooms <n>         rooms in the chapter, max 64       (default: 6)
--name <str>        map name + .bin filename           (default: GenChapter)
--music <event>     FMOD event, e.g. music_city        (default: silent)
--ambience <event>  ambience event                     (default: none)
--difficulty <t>    chill | normal (chill = no hazards)(default: normal)
--room-width <n>    room width in tiles                (default: 44)
--room-height <n>   room height in tiles               (default: 23)
--straight          horizontal chain only, no up/down transitions
--out <dir>         output directory                   (default: ./out)
--format <fmt>      bin | ogmo | both                  (default: both)
--ogmo-template <p> path to celeste.ogmo              (default: ../celeste.ogmo)
--preview          print the chapter layout + an ASCII map of each room
```

Output (`--format both`):

```
out/<name>/
  everest.yaml
  Maps/<name>.bin              ← map id is "<name>"
  ogmo/celeste.ogmo
  ogmo/<name>_0.json … _N.json
```

## How it generates

**Approach: path‑carve platformer** — chosen over cellular‑automata caves and
template‑stitching because it is the only one of the three that *guarantees a
traversable route by construction*.

1. **Layout.** A self‑avoiding walk on an integer room grid: room *i+1* is placed
   Right / Left / Up / Down of room *i* (right‑biased, ~2 in 5 transitions go
   vertical), never onto an occupied cell. Rooms are a uniform size, so every
   shared edge is a full edge and an opening carved at a given local row (L/R) or
   local column (U/D) lines up on both sides with no arithmetic. The walk retries
   if it boxes itself in, then falls back to a straight horizontal chain
   (`--straight` forces that).
2. **Carve.** Each room starts as solid rock and gets a horizontal **spine**
   channel (4‑tall, floored; rises as short 1‑tile staircases, drops that always
   land on a floor) plus a **spur** to every non‑horizontal port:
   - **up‑exit** — a shaft to the ceiling with a `jumpThru` ladder to climb
   - **up‑entrance** — you pop in through the floor; a `jumpThru` at spine level
     catches you, the ladder continues down to the opening
   - **down‑exit** — the spine floor is cut away over the opening: walk off, fall out
   - **down‑entrance** — an open shaft from the ceiling drops you onto the spine
3. **Verify.** A platformer‑aware BFS (walk / 1‑tile ledge / jump ≤ 4 high, ±3
   across / fall to a landing, with `jumpThru` tops counting as ground, and a
   falling‑with‑air‑control flood for drop‑ins and drop‑outs) checks the entrance
   port reaches the exit port. Up to 10 re‑carves with rising flat‑bias, then a
   flat‑spine + simple‑shaft **fallback** that is always solvable.
4. **Decorate** without blocking the guaranteed route (protected cells are tracked
   during the carve): a strawberry per room, refills in longer rooms, a short
   ceiling‑spike stretch (skipped on `--difficulty chill`), a `checkpoint` at the
   spawn of every third room, and in the final room a crystal heart plus an
   `everest/completeAreaTrigger` as the chapter goal.

**Tradeoff:** rooms read as deliberate corridors rather than organic caverns,
quality is bounded by the carve heuristics rather than hand‑authored chunks, and
enabling free vertical movement means a uniform room size (no per‑room width
variety). For a first playable multi‑room chapter, guaranteed‑solvable wins.

## Format notes

`src/binary-packer.js` is a from‑scratch reader/writer for Celeste's
`CELESTE MAP` BinaryPacker format — varint‑prefixed strings, a shared string
lookup table, `0 bool · 1 u8 · 2 i16 · 3 i32 · 4 f32 · 5 lookup · 6 string · 7 RLE`
value tags, little‑endian. Ported from Loenn's `mapcoder.lua` and cross‑checked
against `OgmoEditor3-CE/src/io/BinaryExport.hx` in this same tree. The writer
never emits type 7 (RLE); the reader decodes it.

## Tests

```bash
node --test test/*.test.js
```

Covers: packer round‑trip for every value type incl. negatives / int32 / float32 /
`innerText` / nodes; generated `<Map>` tree shape and 8‑pixel alignment; unique
entity ids; exactly one goal; **every transition opening lines up on both sides**
(all four directions); **vertical transitions are produced and no two rooms
overlap**; `--straight` stays a horizontal chain; determinism (same seed →
identical bytes); every room passes the reachability gate; and the Ogmo emitter
matching `celeste.ogmo` (layer `_eid`s, world‑position offsets, flat row‑major
grids, enum values written as integer indices).

## Not verified here

The `.bin` has not been loaded in an actual Celeste + Everest install from this
environment. The tests prove the *format* and the *structure*; loading in‑game is
the remaining check. If a room won't transition, confirm your Everest build reads
map ids the way `Maps/<name>.bin` implies (`<name>`).
