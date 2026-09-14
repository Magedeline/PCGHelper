'use strict';

const { Rng } = require('./rng');
const { Chapter, Room, TILE } = require('./model');

/*
	Path-carve platformer generator, with room-to-room transitions in all four
	directions.

	Layout is a self-avoiding walk on an integer room grid: room i+1 is placed
	Right / Left / Up / Down of room i (right-biased), never onto an occupied
	cell. Rooms are a uniform size so every shared edge is full-width/height and
	an opening carved at a given local row (L/R) or local column (U/D) lines up
	on both sides with no arithmetic.

	Each room is carved as a horizontal "spine" channel plus a "spur" to every
	non-horizontal port:
	  - up-exit      : a shaft from the spine to the ceiling with a jumpThru ladder
	  - up-entrance   : player pops in through the floor; a jumpThru at spine level
	                    catches them, ladder continues down to the opening
	  - down-exit    : the spine floor is cut away over the opening — walk off, fall out
	  - down-entrance : an open shaft from the ceiling down onto the solid spine floor

	A platformer-aware BFS (walk / 1-tile ledge / jump <=4 high, +-3 across / fall
	to a landing, with jumpThru tops counting as ground) verifies entrance port ->
	exit port. Up to 10 re-carves with rising flat-bias, then a flat-spine +
	simple-shaft fallback that is always solvable. Layout itself retries on the
	rare "walk boxed itself in", then falls back to a straight horizontal chain.

	Each room is also assigned a BIOME (see BIOMES below), which drives its tile
	color, ceiling height, floor variance and decoration mix — so a chapter reads
	as a sequence of distinct places (cave / tunnel / cliffside / ...) instead of
	one uniform corridor repeated. Biomes only change *how* a room is carved and
	dressed, never the room-to-room transition contract, so any biome can follow
	any other.
*/

// ------------------------------------------------------------------ biomes

/*
	tile / bg reference into celeste.ogmo's grid legends:
	  solids: 1 brown  4 grey  5 dark-green  6 grey-blue  9 tan  a teal
	          b purple  n near-black
	  bg:     1 dark-teal  2 navy  3 dark-blue  6 orange  9 dark-purple
	          a green  e dark-teal
*/
const BIOMES = [
	{ name: 'cave', tile: '1', bg: '1', chTop: 5, maxRise: 3, maxDrop: 4, flatBias: 0.3, spikeType: 'default', spinnerColor: 'blue' },
	{ name: 'tunnel', tile: '4', bg: '3', chTop: 3, maxRise: 1, maxDrop: 2, flatBias: 0.75, spikeType: 'outline', spinnerColor: null },
	{ name: 'cliffside', tile: '6', bg: '3', chTop: 6, maxRise: 4, maxDrop: 5, flatBias: 0.2, spikeType: 'cliffside', spinnerColor: null },
	{ name: 'forest', tile: '5', bg: 'a', chTop: 5, maxRise: 3, maxDrop: 3, flatBias: 0.35, spikeType: 'default', spinnerColor: 'blue' },
	{ name: 'crystal', tile: 'b', bg: '9', chTop: 5, maxRise: 3, maxDrop: 4, flatBias: 0.3, spikeType: 'outline', spinnerColor: 'purple' },
	{ name: 'depths', tile: 'n', bg: '2', chTop: 4, maxRise: 4, maxDrop: 5, flatBias: 0.2, spikeType: 'default', spinnerColor: 'red', seeker: true },
	{ name: 'lake', tile: 'a', bg: 'e', chTop: 4, maxRise: 2, maxDrop: 3, flatBias: 0.45, spikeType: 'tentacles', spinnerColor: null, water: true },
	{ name: 'core', tile: '9', bg: '6', chTop: 4, maxRise: 3, maxDrop: 3, flatBias: 0.45, spikeType: 'default', spinnerColor: 'core', lava: true },
];

const BIOME_BY_NAME = Object.fromEntries(BIOMES.map((b) => [b.name, b]));
const BIOME_NAMES = BIOMES.map((b) => b.name);
const MAX_CH_TOP = Math.max(...BIOMES.map((b) => b.chTop));

/** `opt` is undefined/'random'/'mixed' (all biomes, shuffled per room), a single
    biome name, or a comma-separated subset. Throws on an unknown name so a typo
    in --biome fails loudly instead of silently generating an all-cave chapter. */
function resolveBiomePool(opt) {
	if (!opt || opt === 'random' || opt === 'mixed') return BIOMES;
	const names = String(opt)
		.split(',')
		.map((s) => s.trim().toLowerCase())
		.filter(Boolean);
	const picked = names.map((n) => BIOME_BY_NAME[n]).filter(Boolean);
	if (!picked.length) {
		throw new Error(`unknown --biome "${opt}" (valid: ${BIOME_NAMES.join(', ')}, or "random")`);
	}
	return picked;
}

/** One biome per room, seeded so a given seed always reproduces the same
    chapter. Avoids repeating the same biome twice in a row when the pool
    allows it, so back-to-back rooms read as a change of scenery. */
function pickRoomBiomes(rng, roomCount, pool) {
	const out = [];
	let last = null;
	for (let i = 0; i < roomCount; i++) {
		let choice = pool[0];
		if (pool.length > 1) {
			do {
				choice = pool[rng.int(0, pool.length - 1)];
			} while (choice === last);
		}
		out.push(choice);
		last = choice;
	}
	return out;
}

// ------------------------------------------------------------------ config

const DEFAULT_W = 44;
const DEFAULT_H = 23;

/** Shared geometry used for layout — the one thing every room must agree on
    regardless of biome, since transition rows/cols are fixed before any room
    is carved. FLOOR_MIN uses the tallest biome's ceiling so a transition row
    chosen here is always low enough for every biome to carve a real ceiling
    above it (a short-ceiling biome like tunnel just ends up with extra open
    space above its channel at that row — never a room that can't fit). */
function makeBaseCfg(opts) {
	const H = Math.max(14, opts.roomHeight | 0 || DEFAULT_H);
	const W = Math.max(20, opts.roomWidth | 0 || DEFAULT_W);
	const CH_TOP = MAX_CH_TOP;
	return {
		W,
		H,
		CH_TOP,
		FLOOR_MIN: CH_TOP + 2,
		FLOOR_MAX: H - 3,
		MAX_RISE: 4,
		MAX_DROP: 5,
		GAP_V: 3, // vertical opening width, in tiles — shared across biomes so a transition matches on both sides
	};
}

/** Per-room carve config: base geometry (for FLOOR_MIN/MAX/GAP_V/W/H, so ports
    still line up) plus this room's biome overrides (ceiling height, floor
    variance, tile colors, decoration mix). */
function withBiome(baseCfg, biome) {
	return {
		...baseCfg,
		// seamChTop stays the shared base value (kept BEFORE the CH_TOP override
		// below) so a left/right doorway is carved to the same height on both
		// sides of the seam no matter which two biomes are meeting there — only
		// interior carving uses the biome's own, possibly shorter/taller, CH_TOP.
		seamChTop: baseCfg.CH_TOP,
		CH_TOP: biome.chTop,
		MAX_RISE: biome.maxRise,
		MAX_DROP: biome.maxDrop,
		tile: biome.tile,
		bgTile: biome.bg,
		biome,
	};
}

const clampFloor = (cfg, y) => Math.max(cfg.FLOOR_MIN, Math.min(cfg.FLOOR_MAX, y));

/* ------------------------------------------------------------------- layout */

const DIRS = { R: [1, 0], L: [-1, 0], U: [0, -1], D: [0, 1] };
const OPP = { R: 'L', L: 'R', U: 'D', D: 'U' };
// which edge of the destination room the player enters through, per travel dir
const ENTRY_EDGE = { R: 'left', L: 'right', D: 'top', U: 'bottom' };
// which edge of the source room the player leaves through, per travel dir
const EXIT_EDGE = { R: 'right', L: 'left', D: 'bottom', U: 'top' };

function buildLayout(rng, roomCount, cfg) {
	const occ = new Map([['0,0', 0]]);
	const cells = [{ cx: 0, cy: 0 }];
	const transitions = [];
	let lastDir = null;

	// right-biased, but ~2 in 5 transitions go vertical; left is rare
	const WEIGHT = { R: 42, D: 26, U: 20, L: 12 };

	for (let i = 1; i < roomCount; i++) {
		const prev = cells[i - 1];

		// a weighted shuffle of the four directions (weighted-random without replacement)
		const pool = ['R', 'D', 'U', 'L'].map((d) => ({ d, k: Math.pow(rng.next(), 1 / WEIGHT[d]) }));
		const order = pool.sort((a, b) => b.k - a.k).map((e) => e.d);

		let placed = null;
		let dir = null;
		for (const pass of [0, 1]) {
			for (const d of order) {
				if (pass === 0 && lastDir && d === OPP[lastDir]) continue; // avoid immediate backtrack first
				const [dx, dy] = DIRS[d];
				const key = `${prev.cx + dx},${prev.cy + dy}`;
				if (occ.has(key)) continue;
				placed = { cx: prev.cx + dx, cy: prev.cy + dy };
				dir = d;
				break;
			}
			if (placed) break;
		}
		if (!placed) throw new Error('layout boxed');

		cells.push(placed);
		occ.set(`${placed.cx},${placed.cy}`, i);
		lastDir = dir;

		if (dir === 'R' || dir === 'L') {
			transitions.push({ dir, from: i - 1, to: i, row: rng.int(cfg.FLOOR_MIN, cfg.FLOOR_MAX) });
		} else {
			transitions.push({ dir, from: i - 1, to: i, col: rng.int(4, cfg.W - 4 - cfg.GAP_V), gap: cfg.GAP_V });
		}
	}
	return { cells, transitions };
}

function straightLayout(roomCount, cfg, rng) {
	const cells = [];
	const transitions = [];
	for (let i = 0; i < roomCount; i++) {
		cells.push({ cx: i, cy: 0 });
		if (i > 0) transitions.push({ dir: 'R', from: i - 1, to: i, row: rng.int(cfg.FLOOR_MIN, cfg.FLOOR_MAX) });
	}
	return { cells, transitions };
}

/* ------------------------------------------------------------------ carving */

function carveRunCols(room, cfg, x0, x1, fy, floorAtX) {
	for (let x = x0; x <= x1; x++) {
		if (x < 0 || x >= room.w) continue;
		for (let y = fy - cfg.CH_TOP; y <= fy - 1; y++) room.solids.set(x, y, '0');
		room.solids.set(x, fy, cfg.tile);
		room.protect(x, fy - 1);
		room.protect(x, fy - 2);
		room.protect(x, fy);
		if (floorAtX) floorAtX[x] = fy;
	}
}

function stairUp(room, cfg, x, fy, target, floorAtX, end) {
	let cx = x;
	let f = fy;
	while (f > target && cx < end - 1) {
		f -= 1;
		carveRunCols(room, cfg, cx, cx + 1, f, floorAtX);
		cx += 2;
	}
	return { x: cx, floorY: f };
}

function drop(room, cfg, x, fy, target, floorAtX, end) {
	const x1 = Math.min(x + 1, end);
	for (let y = fy - cfg.CH_TOP; y <= target - 1; y++) {
		room.solids.set(x, y, '0');
		room.solids.set(x1, y, '0');
		room.protect(x, y);
		room.protect(x1, y);
	}
	carveRunCols(room, cfg, x, x1, target, floorAtX);
	return { x: x1 + 1, floorY: target };
}

/** meandering horizontal channel across [x0..x1], floor fy0 -> fy1 */
function meander(room, cfg, rng, x0, x1, fy0, fy1, flatBias, floorAtX) {
	let x = x0;
	let fy = fy0;
	carveRunCols(room, cfg, x, Math.min(x + 2, x1), fy, floorAtX);
	x += 3;

	while (x < x1 - 1) {
		const remaining = x1 - x;
		const runW = Math.min(remaining, rng.int(3, 6));
		carveRunCols(room, cfg, x, x + runW, fy, floorAtX);
		x += runW;
		if (x >= x1 - 2) break;

		let next;
		if (remaining <= 8) {
			next = clampFloor(cfg, fy + Math.sign(fy1 - fy) * Math.min(Math.abs(fy1 - fy), cfg.MAX_RISE));
		} else {
			const roll = rng.next();
			if (roll < flatBias) next = fy;
			else if (roll < flatBias + (1 - flatBias) * 0.45) next = clampFloor(cfg, fy - rng.int(1, cfg.MAX_RISE));
			else next = clampFloor(cfg, fy + rng.int(1, cfg.MAX_DROP));
		}

		if (next < fy) ({ x, floorY: fy } = stairUp(room, cfg, x, fy, next, floorAtX, x1));
		else if (next > fy) ({ x, floorY: fy } = drop(room, cfg, x, fy, next, floorAtX, x1));
	}

	// Settle to the pinned end row (fy1): cut a 2-wide vertical slot at the
	// junction so the meander body and the end channel are always 4-connected
	// (with a jumpThru ladder if it's a tall climb), then a flat run at fy1 to
	// the edge. The slot columns are kept clear of that run.
	const jx = Math.max(x0, Math.min(x + 1, x1 - 4));
	if (x < jx) carveRunCols(room, cfg, x, jx - 1, fy, floorAtX);
	const lo = Math.min(fy, fy1) - cfg.CH_TOP;
	const hi = Math.max(fy, fy1) - 1;
	for (let yy = lo; yy <= hi; yy++) {
		room.solids.set(jx, yy, '0');
		room.solids.set(jx + 1, yy, '0');
		room.protect(jx, yy);
		room.protect(jx + 1, yy);
	}
	if (fy1 < fy - cfg.MAX_RISE) {
		for (let yy = fy - 3; yy > fy1; yy -= 3) jumpThruAt(room, cfg, jx, jx + 1, yy);
	}
	carveRunCols(room, cfg, jx + 2, x1, fy1, floorAtX);
}

function carveEdgeOpening(room, cfg, side, fy) {
	const x = side === 'left' ? 0 : room.w - 1;
	for (let y = fy - cfg.seamChTop; y <= fy - 1; y++) {
		room.solids.set(x, y, '0');
		room.protect(x, y);
	}
	room.solids.set(x, fy, cfg.tile);
	room.protect(x, fy);
}

function jumpThruAt(room, cfg, x0, x1, row) {
	room.addEntity('jumpThru', room.worldPxX() + x0 * TILE, room.worldPxY() + row * TILE, {
		width: (x1 - x0 + 1) * TILE,
		originX: 0,
		originY: 0,
		attrs: { texture: 'Wood' },
	});
}

/** carve the shaft for one vertical port; returns the info the BFS needs.
    The shaft is exactly `gap` columns wide so the opening at the true edge row
    (0 for top, h-1 for bottom) is the same width on both sides of the seam. */
function carveVerticalPort(room, cfg, edge, isEntrance, col, gap, floorAtX) {
	const w = room.w;
	const h = room.h;
	const gap0 = Math.max(1, col);
	const gap1 = Math.min(w - 2, col + gap - 1);
	const mid = Math.min(Math.max(gap0 + (gap >> 1), 1), w - 2);
	let spineFY = floorAtX[mid] || floorAtX[gap0] || Math.round((cfg.FLOOR_MIN + cfg.FLOOR_MAX) / 2);
	spineFY = clampFloor(cfg, spineFY);

	const openCol = (x, y0, y1) => {
		for (let y = y0; y <= y1; y++) {
			room.solids.set(x, y, '0');
			room.protect(x, y);
		}
	};

	if (edge === 'top') {
		for (let x = gap0; x <= gap1; x++) openCol(x, 0, spineFY - 1);
		if (!isEntrance) {
			// climb aid: a jumpThru every 3 rows from the spine up to the ceiling
			for (let y = spineFY - 3; y >= 2; y -= 3) jumpThruAt(room, cfg, gap0, gap1, y);
		}
	} else {
		// bottom
		const flankL = Math.max(1, gap0 - 1);
		const flankR = Math.min(w - 2, gap1 + 1);
		if (isEntrance) {
			for (let x = gap0; x <= gap1; x++) openCol(x, spineFY - 1, h - 1);
			jumpThruAt(room, cfg, gap0, gap1, spineFY); // catch the up-pop at spine level
			for (let y = spineFY + 3; y <= h - 3; y += 3) jumpThruAt(room, cfg, gap0, gap1, y);
		} else {
			for (let x = gap0; x <= gap1; x++) openCol(x, spineFY - cfg.CH_TOP, h - 1);
		}
		// solid floor immediately beside the hole so you can stand next to it
		room.solids.set(flankL, spineFY, cfg.tile);
		room.solids.set(flankR, spineFY, cfg.tile);
	}

	return { edge, isEntrance, gap0, gap1, sc0: gap0, sc1: gap1, mid, spineFY };
}

function portColumns(room, cfg, port) {
	if (!port) return [];
	if (port.edge === 'left') return [1];
	if (port.edge === 'right') return [room.w - 2];
	return [Math.min(Math.max(port.col + (port.gap >> 1), 2), room.w - 3)];
}

/*
	Floor row at the spine's left end (startFY) and right end (endFY).

	A horizontal port pins its own end to the row it shares with the neighbour
	across the seam — whether that port is the entrance or the exit, so a leftward
	chapter works like a rightward one. An unpinned end stays near the pinned one
	(a gentle spine) or, with no pin at all, is chosen mid-ish. Top/bottom ports
	don't move the spine — their shafts (with jumpThru ladders) span whatever gap
	is left to the edge.
*/
function spineEndRows(ports, cfg, rng) {
	const leftPort = ports.find((p) => p.edge === 'left');
	const rightPort = ports.find((p) => p.edge === 'right');
	const jitter = (base) => clampFloor(cfg, base + (rng ? rng.int(-4, 4) : 0));
	const free = () => (rng ? rng.int(cfg.FLOOR_MIN + 2, cfg.FLOOR_MAX - 2) : Math.round((cfg.FLOOR_MIN + cfg.FLOOR_MAX) / 2));

	const startFY = leftPort ? leftPort.row : rightPort ? jitter(rightPort.row) : free();
	const endFY = rightPort ? rightPort.row : leftPort ? jitter(leftPort.row) : clampFloor(cfg, startFY + (rng ? rng.int(-3, 3) : 0));
	return { startFY, endFY };
}

/** carve each port's opening; startFY/endFY already equal the L/R port rows */
function wirePorts(room, cfg, floorAtX, startFY, endFY) {
	const one = (port, isEntrance) => {
		if (!port) return null;
		if (port.edge === 'left') {
			carveEdgeOpening(room, cfg, 'left', startFY);
			return { edge: 'left', fy: startFY };
		}
		if (port.edge === 'right') {
			carveEdgeOpening(room, cfg, 'right', endFY);
			return { edge: 'right', fy: endFY };
		}
		return carveVerticalPort(room, cfg, port.edge, isEntrance, port.col, port.gap, floorAtX);
	};
	room._entrance = one(room.entrancePort, true);
	room._exit = one(room.exitPort, false);
}

function carveRoom(room, cfg, rng, flatBias) {
	room.solids.fillRect(0, 0, room.w - 1, room.h - 1, cfg.tile);
	room.protectedCells.clear();
	room.entities.length = 0; // drop jumpThrus from any earlier attempt
	room.triggers.length = 0;
	const floorAtX = new Array(room.w).fill(cfg.FLOOR_MIN + 2);

	const ports = [room.entrancePort, room.exitPort].filter(Boolean);

	// spine span: cover every port column plus a margin, but never a pointless
	// full-width corridor when both ports are vertical and close together
	let cols = [];
	for (const p of ports) cols = cols.concat(portColumns(room, cfg, p));
	if (cols.length === 0) cols = [3, room.w - 4]; // shouldn't happen
	if (cols.length === 1) cols.push(cols[0] < room.w / 2 ? Math.min(room.w - 4, cols[0] + 10) : Math.max(3, cols[0] - 10));
	const spineL = Math.max(1, Math.min(...cols) - 2);
	const spineR = Math.min(room.w - 2, Math.max(...cols) + 2);

	const { startFY, endFY } = spineEndRows(ports, cfg, rng);

	meander(room, cfg, rng, spineL, spineR, startFY, endFY, flatBias, floorAtX);

	room._floorAtX = floorAtX;
	room._spineL = spineL;
	room._spineR = spineR;
	room._startFY = startFY;
	room._endFY = endFY;

	wirePorts(room, cfg, floorAtX, startFY, endFY);
}

function carveRoomFallback(room, cfg) {
	room.solids.fillRect(0, 0, room.w - 1, room.h - 1, cfg.tile);
	room.protectedCells.clear();
	room.entities.length = 0;
	room.triggers.length = 0;
	const floorAtX = new Array(room.w).fill(cfg.FLOOR_MIN + 2);

	const ports = [room.entrancePort, room.exitPort].filter(Boolean);
	const { startFY, endFY } = spineEndRows(ports, cfg, null);

	// monotone ramp spine, <= 1 tile height change per column — always walkable
	const span = Math.max(1, room.w - 3);
	let fy = startFY;
	for (let x = 1; x <= room.w - 2; x++) {
		const want = Math.round(startFY + ((endFY - startFY) * (x - 1)) / span);
		if (want > fy) fy = Math.min(fy + 1, want);
		else if (want < fy) fy = Math.max(fy - 1, want);
		carveRunCols(room, cfg, x, x, fy, floorAtX);
	}

	room._floorAtX = floorAtX;
	room._spineL = 1;
	room._spineR = room.w - 2;
	room._startFY = startFY;
	room._endFY = endFY;

	wirePorts(room, cfg, floorAtX, startFY, endFY);
}

/* ------------------------------------------------------- reachability check */

function reachable(room, cfg) {
	const S = room.solids;
	const W = room.w;

	// jumpThru tops -> "solid from above" (you pass up/through, land on top)
	const jumpTop = new Set();
	for (const e of room.entities) {
		if (e.name !== 'jumpThru') continue;
		const lx = Math.round((e.x - room.worldPxX()) / 8);
		const ly = Math.round((e.y - room.worldPxY()) / 8);
		const cols = Math.max(1, Math.round((e.width || 8) / 8));
		for (let k = 0; k < cols; k++) jumpTop.add(ly * W + (lx + k));
	}

	const open = (x, y) => y >= 0 && y < room.h && x >= 0 && x < W && !S.solid(x, y);
	const grounded = (x, y) => open(x, y) && (S.solid(x, y + 1) || jumpTop.has((y + 1) * W + x));

	// falling with air control: from an open cell you can reach the open cell
	// below it or either diagonal-below. Returns the set of open cells reached
	// and every grounded cell touched along the way.
	const driftDown = (starts) => {
		const vis = new Set();
		const stack = [];
		const grd = [];
		for (const [x, y] of starts) {
			if (open(x, y) && !vis.has(y * W + x)) {
				vis.add(y * W + x);
				stack.push([x, y]);
			}
		}
		while (stack.length) {
			const [x, y] = stack.pop();
			if (grounded(x, y)) grd.push([x, y]);
			// straight down / sideways, plus a diagonal-down only when it isn't
			// squeezing through a solid corner (need an orthogonal open cell too)
			const moves = [
				[x, y + 1, true],
				[x - 1, y, true],
				[x + 1, y, true],
				[x - 1, y + 1, open(x - 1, y) || open(x, y + 1)],
				[x + 1, y + 1, open(x + 1, y) || open(x, y + 1)],
			];
			for (const [nx, ny, okMove] of moves) {
				if (!okMove || !open(nx, ny)) continue;
				const k = ny * W + nx;
				if (vis.has(k)) continue;
				vis.add(k);
				stack.push([nx, ny]);
			}
		}
		return { vis, grounded: grd };
	};

	const ent = room._entrance;
	const ex = room._exit;
	const goalCell = room._goalCell;

	const bottomGapCells = () => {
		const cs = [];
		if (ex && ex.edge === 'bottom') for (let x = ex.gap0; x <= ex.gap1; x++) cs.push([x, room.h - 1]);
		return cs;
	};
	const bottomGapKeys = new Set(bottomGapCells().map(([x, y]) => y * W + x));

	// --- start states (grounded cells the player can stand on right away) ---
	const seen = new Set();
	const q = [];
	const push = (x, y) => {
		const k = y * W + x;
		if (!seen.has(k)) {
			seen.add(k);
			q.push([x, y]);
		}
	};
	const seedGrounded = (x, y) => {
		let sy = y;
		while (sy < room.h && !grounded(x, sy)) sy++;
		if (sy < room.h) push(x, sy);
	};

	if (!ent) {
		seedGrounded(room._spineL + 1, room._startFY - 1);
	} else if (ent.edge === 'left') {
		seedGrounded(1, room._startFY - 1);
	} else if (ent.edge === 'right') {
		seedGrounded(W - 2, room._endFY - 1);
	} else if (ent.edge === 'top') {
		// fell in through the ceiling: drift down, land on any ledge — and if the
		// drift falls straight out a bottom exit, that's already a valid traversal
		const d = driftDown([
			[ent.mid, 0],
			[ent.mid, 1],
		]);
		for (const k of bottomGapKeys) if (d.vis.has(k)) return true;
		for (const [x, y] of d.grounded) push(x, y);
	} else {
		// bottom entrance: the up-pop is caught by the jumpThru at spine level
		seedGrounded(ent.mid, ent.spineFY - 1);
	}

	const hitGoal = () => {
		if (goalCell) {
			for (let dy = -2; dy <= 1; dy++) if (seen.has((goalCell.y + dy) * W + goalCell.x)) return true;
		}
		if (!ex) return false;
		if (ex.edge === 'right') {
			for (let dy = -3; dy <= 1; dy++) if (seen.has((room._endFY + dy) * W + (W - 2))) return true;
			return false;
		}
		if (ex.edge === 'left') {
			for (let dy = -3; dy <= 1; dy++) if (seen.has((room._startFY + dy) * W + 1)) return true;
			return false;
		}
		if (ex.edge === 'top') {
			for (let x = ex.gap0; x <= ex.gap1; x++) for (let y = 0; y <= 3; y++) if (seen.has(y * W + x)) return true;
			return false;
		}
		// bottom exit: from any reached cell, can we drift/fall out the hole?
		if (seen.size) {
			const d = driftDown([...seen].map((k) => [k % W, (k / W) | 0]));
			for (const k of bottomGapKeys) if (d.vis.has(k)) return true;
		}
		return false;
	};

	while (q.length) {
		const [x, y] = q.shift();
		if (hitGoal()) return true;
		// walk / step down (fall to a landing) / step up one ledge
		for (const dir of [-1, 1]) {
			if (open(x + dir, y)) {
				let ly = y;
				while (ly + 1 < room.h && open(x + dir, ly + 1) && !jumpTop.has((ly + 1) * W + (x + dir))) ly++;
				if (grounded(x + dir, ly)) push(x + dir, ly);
			}
			if (open(x + dir, y) && open(x + dir, y - 1) && grounded(x + dir, y - 1)) push(x + dir, y - 1);
		}
		// jump: up to 4 high, +-3 across, straight-up then across clearance
		for (let dh = 1; dh <= 4; dh++) {
			let up = true;
			for (let k = 1; k <= dh; k++) if (!open(x, y - k)) up = false;
			if (!up) break;
			for (let dx = -3; dx <= 3; dx++) {
				const tx = x + dx;
				const ty = y - dh;
				let clear = true;
				for (let cx = Math.min(x, tx); cx <= Math.max(x, tx); cx++) if (!open(cx, ty)) clear = false;
				if (!clear) continue;
				let ly = ty;
				while (ly + 1 < room.h && open(tx, ly + 1) && !jumpTop.has((ly + 1) * W + tx)) ly++;
				if (grounded(tx, ly)) push(tx, ly);
			}
		}
	}
	return hitGoal();
}

/* ------------------------------------------------------------- decoration */

function flatRuns(room) {
	const f = room._floorAtX || [];
	const L = room._spineL || 1;
	const R = room._spineR || room.w - 2;
	const runs = [];
	let start = L;
	for (let x = L + 1; x <= R; x++) {
		if (f[x] !== f[start]) {
			if (x - start >= 4) runs.push([start, x - 1, f[start]]);
			start = x;
		}
	}
	if (R - start >= 4) runs.push([start, R, f[start]]);
	return runs;
}

function spawnCell(room, cfg) {
	const ent = room._entrance;
	if (!ent) return { x: room._spineL + 1, y: room._startFY };
	if (ent.edge === 'left') return { x: 2, y: room._startFY };
	if (ent.edge === 'right') return { x: room.w - 3, y: room._endFY };
	return { x: ent.mid, y: ent.spineFY }; // top/bottom: land at spine level
}

function decorate(chapter, room, rng, isLast, opts, cfg) {
	const wx = room.worldPxX();
	const wy = room.worldPxY();
	const runs = flatRuns(room);
	const roomIndex = chapter.rooms.indexOf(room);
	const biome = cfg.biome;
	const hazardsOn = opts.difficulty !== 'chill';

	if (runs.length) {
		const [a, b, fy] = rng.pick(runs);
		const cx = Math.floor((a + b) / 2);
		room.addEntity('strawberry', wx + cx * TILE, wy + (fy - cfg.CH_TOP) * TILE, {
			originX: 0,
			originY: 0,
			attrs: { winged: false, moon: false, checkpointID: -1, order: -1 },
		});
	}

	if (room.w >= 46 && runs.length >= 2) {
		const [a, b, fy] = runs[Math.floor(runs.length / 2)];
		const cx = Math.floor((a + b) / 2);
		room.addEntity('refill', wx + cx * TILE + 8, wy + (fy - 2) * TILE, {
			originX: 8,
			originY: 8,
			attrs: { oneUse: false, twoDash: false },
		});
	}

	if (hazardsOn && runs.length >= 3) {
		const [a, b, fy] = runs[1 + rng.int(0, runs.length - 3)];
		const start = a + 1 + rng.int(0, Math.max(0, b - a - 3));
		const span = Math.min(3, b - start);
		if (span >= 1) {
			room.addEntity('spikesDown', wx + start * TILE, wy + (fy - cfg.CH_TOP) * TILE, {
				width: span * TILE,
				originX: 0,
				originY: 0,
				attrs: { type: biome.spikeType || 'default' },
			});
		}
	}

	// biome-flavoured decoration — same guaranteed-route caveats as the
	// spikesDown hazard above (a hazard on the path is a fair-but-risky
	// crossing, not a blocked one; reachability only cares about geometry)
	if (biome.spinnerColor && hazardsOn && runs.length >= 2) {
		const pickIdx = runs.length >= 3 ? 1 + rng.int(0, runs.length - 2) : rng.int(0, runs.length - 1);
		const [a, b, fy] = runs[pickIdx];
		const cx = Math.floor((a + b) / 2);
		room.addEntity('spinner', wx + cx * TILE, wy + (fy - 3) * TILE, {
			originX: 0,
			originY: 0,
			attrs: { color: biome.spinnerColor },
		});
	}

	if (biome.water && runs.length) {
		const [a, b, fy] = runs[runs.length - 1];
		const span = b - a;
		if (span >= 2) {
			room.addEntity('water', wx + a * TILE, wy + (fy - 2) * TILE, {
				width: span * TILE,
				height: 2 * TILE,
				originX: 0,
				originY: 0,
			});
		}
	}

	if (biome.lava && hazardsOn && runs.length >= 2) {
		const [a, b, fy] = runs[0];
		const span = Math.min(4, b - a);
		if (span >= 1) {
			room.addEntity('sandwichLava', wx + a * TILE, wy + (fy - 1) * TILE, {
				width: span * TILE,
				originX: 0,
				originY: 0,
			});
		}
	}

	if (biome.seeker && hazardsOn && runs.length >= 2 && roomIndex % 2 === 0) {
		const [a, b, fy] = runs[runs.length - 1];
		const cx = Math.floor((a + b) / 2);
		room.addEntity('seeker', wx + cx * TILE, wy + (fy - 8) * TILE, { originX: 0, originY: 0 });
	}

	if (roomIndex === 0 || roomIndex % 3 === 0) {
		const s = spawnCell(room, cfg);
		room.addEntity('checkpoint', wx + s.x * TILE, wy + s.y * TILE - 16, {
			originX: 0,
			originY: 0,
			attrs: { inventory: '', dreaming: false },
		});
	}

	if (isLast) {
		const fy = room._endFY;
		const px = Math.max(room._spineL + 1, room._spineR - 3);
		room.solids.set(px, fy, cfg.tile);
		room.solids.set(px + 1, fy, cfg.tile);
		room.addEntity('blackGem', wx + px * TILE, wy + (fy - 2) * TILE, { originX: 0, originY: 0 });
		room.addTrigger('everest/completeAreaTrigger', wx + (px - 1) * TILE, wy + (fy - cfg.CH_TOP) * TILE, {
			width: 4 * TILE,
			height: cfg.CH_TOP * TILE,
			originX: 0,
			originY: 0,
			attrs: {},
		});
	}
}

/* ----------------------------------------------------------------- driver */

function generateChapter(options = {}) {
	const opts = Object.assign(
		{ seed: 'celeste-pcg', rooms: 6, name: 'GenChapter', music: '', ambience: '', difficulty: 'normal', straight: false, biome: 'random' },
		options,
	);

	const baseCfg = makeBaseCfg(opts);
	const roomCount = Math.max(1, Math.min(64, (opts.rooms | 0) || 6));
	const chapter = new Chapter(opts.name, { music: opts.music, ambience: opts.ambience, seed: opts.seed });

	const biomePool = resolveBiomePool(opts.biome);
	const roomBiomes = pickRoomBiomes(new Rng(`${opts.seed}:biome`), roomCount, biomePool);

	// --- layout: self-avoiding walk, retry, straight-chain fallback ---
	let layout = null;
	if (!opts.straight) {
		for (let attempt = 0; attempt < 24 && !layout; attempt++) {
			try {
				layout = buildLayout(new Rng(`${opts.seed}:layout:${attempt}`), roomCount, baseCfg);
			} catch (e) {
				/* boxed — retry */
			}
		}
	}
	if (!layout) layout = straightLayout(roomCount, baseCfg, new Rng(`${opts.seed}:layout:straight`));
	chapter.transitions = layout.transitions;

	// normalise cell coords so the world origin is (0,0)
	const minCx = Math.min(...layout.cells.map((c) => c.cx));
	const minCy = Math.min(...layout.cells.map((c) => c.cy));

	// --- build rooms + attach ports ---
	for (let i = 0; i < roomCount; i++) {
		const c = layout.cells[i];
		const room = new Room(
			`${opts.name.toLowerCase()}_${i}`,
			(c.cx - minCx) * baseCfg.W,
			(c.cy - minCy) * baseCfg.H,
			baseCfg.W,
			baseCfg.H,
		);
		room.cx = c.cx - minCx;
		room.cy = c.cy - minCy;
		room.biome = roomBiomes[i].name;

		const tin = layout.transitions[i - 1]; // into this room
		const tout = layout.transitions[i]; // out of this room
		room.entrancePort = tin
			? { edge: ENTRY_EDGE[tin.dir], row: tin.row, col: tin.col, gap: tin.gap }
			: null;
		room.exitPort = tout ? { edge: EXIT_EDGE[tout.dir], row: tout.row, col: tout.col, gap: tout.gap } : null;

		chapter.addRoom(room);
	}

	// --- carve each room, verify, fall back ---
	chapter.rooms.forEach((room, i) => {
		const cfg = withBiome(baseCfg, roomBiomes[i]);
		room._cfg = cfg;

		if (i === roomCount - 1) room._goalCell = { x: Math.max(1, room.w - 6), y: room.h - 3 }; // placeholder, refined after carve

		let ok = false;
		for (let attempt = 0; attempt < 10 && !ok; attempt++) {
			const rng = new Rng(`${opts.seed}:${i}:${attempt}`);
			const flatBias = Math.min(0.9, cfg.biome.flatBias + attempt * 0.06);
			carveRoom(room, cfg, rng, flatBias);
			if (i === roomCount - 1) {
				const fy = room._endFY;
				room._goalCell = { x: Math.max(room._spineL + 1, room._spineR - 3), y: fy - 1 };
			}
			ok = reachable(room, cfg);
		}
		if (!ok) {
			carveRoomFallback(room, cfg);
			if (i === roomCount - 1) {
				const fy = room._endFY;
				room._goalCell = { x: Math.max(room._spineL + 1, room._spineR - 3), y: fy - 1 };
			}
		}

		for (let y = 0; y < room.h; y++) {
			for (let x = 0; x < room.w; x++) room.bg.set(x, y, room.solids.solid(x, y) ? '0' : cfg.bgTile);
		}

		const s = spawnCell(room, cfg);
		room.addEntity('player', room.worldPxX() + s.x * TILE, room.worldPxY() + s.y * TILE, {
			originX: 4,
			originY: 12,
			attrs: {},
		});
	});

	chapter.rooms.forEach((room, i) =>
		decorate(chapter, room, new Rng(`${opts.seed}:deco:${i}`), i === roomCount - 1, opts, room._cfg),
	);

	return chapter.finalize();
}

module.exports = { generateChapter, DEFAULT_W, DEFAULT_H, BIOMES, BIOME_NAMES };
