'use strict';

/*
	Structural gate used by the tests: is the carved open space a single connected
	pocket that touches both the entrance port and the exit port (or the goal cell
	in the final room)?

	Deliberately weaker than the platformer-aware BFS in src/generate.js (which
	already gates generation and falls back). Here we only assert the carve didn't
	split the route into disconnected caverns. 4-connected flood over open cells;
	jumpThru columns are open, so they don't block the flood.
*/

function portCells(room, port, whichFY) {
	if (!port) return [{ x: (room._spineL || 1) + 1, y: (whichFY || room._startFY) - 1 }];
	if (port.edge === 'left') {
		const fy = room._startFY;
		return [1, 2].flatMap((x) => [fy - 1, fy - 2, fy - 3].map((y) => ({ x, y })));
	}
	if (port.edge === 'right') {
		const fy = room._endFY;
		return [room.w - 2, room.w - 3].flatMap((x) => [fy - 1, fy - 2, fy - 3].map((y) => ({ x, y })));
	}
	if (port.edge === 'top') {
		return [port.mid - 1, port.mid, port.mid + 1].map((x) => ({ x, y: 1 }));
	}
	// bottom
	return [port.mid - 1, port.mid, port.mid + 1].map((x) => ({ x, y: port.spineFY - 1 }));
}

function roundTripAscii(room) {
	const S = room.solids;
	const open = (x, y) => x >= 0 && y >= 0 && x < room.w && y < room.h && !S.solid(x, y);

	const seen = new Set();
	const q = [];
	for (const c of portCells(room, room._entrance, room._startFY)) {
		if (open(c.x, c.y)) {
			seen.add(c.y * room.w + c.x);
			q.push([c.x, c.y]);
		}
	}
	if (!q.length) return false;

	while (q.length) {
		const [x, y] = q.pop();
		for (const [dx, dy] of [
			[1, 0],
			[-1, 0],
			[0, 1],
			[0, -1],
		]) {
			const nx = x + dx;
			const ny = y + dy;
			if (!open(nx, ny)) continue;
			const k = ny * room.w + nx;
			if (seen.has(k)) continue;
			seen.add(k);
			q.push([nx, ny]);
		}
	}

	const targets = room._exit
		? portCells(room, room._exit, room._endFY)
		: [room._goalCell || { x: room.w - 4, y: room._endFY - 1 }];
	return targets.some((c) => seen.has(c.y * room.w + c.x));
}

/** world-space AABB overlap between two rooms (tiles) */
function roomsOverlap(a, b) {
	return a.tx < b.tx + b.w && b.tx < a.tx + a.w && a.ty < b.ty + b.h && b.ty < a.ty + a.h;
}

module.exports = { roundTripAscii, roomsOverlap };
