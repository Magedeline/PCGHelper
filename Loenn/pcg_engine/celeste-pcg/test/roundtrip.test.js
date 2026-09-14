'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');

const { encodeMap, decodeMap } = require('../src/binary-packer');
const { generateChapter } = require('../src/generate');
const { buildMapTree, encodeChapterBin } = require('../src/emit-bin');
const { roundTripAscii, roomsOverlap } = require('./helpers');
const { roomToOgmoLevel, indexProject } = require('../src/emit-ogmo');
const { importBin } = require('../src/import-bin');
const os = require('os');

/** the repo's real celeste.ogmo lives at Ogmo/ogmo/celeste.ogmo, one level up
    from celeste-pcg/ — fall back to Ogmo/celeste.ogmo in case a checkout ever
    puts it there instead, and skip cleanly if neither exists. */
function findOgmoTemplate() {
	const candidates = [
		path.join(__dirname, '..', '..', 'ogmo', 'celeste.ogmo'),
		path.join(__dirname, '..', '..', 'celeste.ogmo'),
	];
	return candidates.find((p) => fs.existsSync(p)) || null;
}

/* ------------------------------------------------ low-level packer round-trip */

test('binary-packer: mixed value types survive a round-trip', () => {
	const tree = {
		name: 'Map',
		attrs: {},
		children: [
			{
				name: 'levels',
				attrs: {},
				children: [
					{
						name: 'level',
						attrs: {
							name: 'lvl_0',
							x: 0,
							y: -256,
							width: 320,
							height: 184,
							dark: true,
							space: false,
							windPattern: 'None',
							cameraOffsetX: 0,
							bigNumber: 70000, // forces int32
							floaty: 1.5, // forces float32
						},
						children: [
							{ name: 'solids', attrs: { offsetX: 0, offsetY: 0 }, innerText: '000\n0110\n111', children: [] },
							{
								name: 'entities',
								attrs: {},
								children: [
									{ name: 'player', attrs: { id: 1, x: 8, y: 40 }, children: [] },
									{
										name: 'spinner',
										attrs: { id: 2, x: 100, y: 50, color: 'blue' },
										children: [{ name: 'node', attrs: { x: 120, y: 50 }, children: [] }],
									},
								],
							},
						],
					},
				],
			},
		],
	};

	const buf = encodeMap(tree, 'MyMod/0-Test');
	const decoded = decodeMap(buf);

	assert.equal(decoded.header, 'CELESTE MAP');
	assert.equal(decoded.package, 'MyMod/0-Test');
	assert.equal(decoded.root.name, 'Map');

	const level = decoded.root.children[0].children[0];
	assert.equal(level.name, 'level');
	assert.equal(level.attrs.name, 'lvl_0');
	assert.equal(level.attrs.x, 0);
	assert.equal(level.attrs.y, -256);
	assert.equal(level.attrs.width, 320);
	assert.equal(level.attrs.dark, true);
	assert.equal(level.attrs.space, false);
	assert.equal(level.attrs.windPattern, 'None');
	assert.equal(level.attrs.bigNumber, 70000);
	assert.equal(Math.abs(level.attrs.floaty - 1.5) < 1e-6, true);

	const solids = level.children[0];
	assert.equal(solids.innerText, '000\n0110\n111');

	const entities = level.children[1];
	assert.equal(entities.children[0].name, 'player');
	assert.equal(entities.children[0].attrs.id, 1);
	assert.equal(entities.children[1].name, 'spinner');
	assert.equal(entities.children[1].attrs.color, 'blue');
	assert.equal(entities.children[1].children[0].name, 'node');
	assert.equal(entities.children[1].children[0].attrs.x, 120);
});

test('binary-packer: negative/large ints and empty strings', () => {
	const tree = {
		name: 'Map',
		attrs: { a: -1, b: -40000, c: 255, d: 256, e: '' },
		children: [],
	};
	const decoded = decodeMap(encodeMap(tree, ''));
	assert.equal(decoded.root.attrs.a, -1);
	assert.equal(decoded.root.attrs.b, -40000);
	assert.equal(decoded.root.attrs.c, 255);
	assert.equal(decoded.root.attrs.d, 256);
	assert.equal(decoded.root.attrs.e, '');
});

/* ------------------------------------------------------- generated chapter */

test('generated chapter: valid Map tree shape', () => {
	const chapter = generateChapter({ seed: 'test-a', rooms: 5, name: 'TestA' });
	assert.equal(chapter.rooms.length, 5);

	const decoded = decodeMap(encodeChapterBin(chapter, 'TestA'));
	assert.equal(decoded.root.name, 'Map');

	const names = decoded.root.children.map((c) => c.name).sort();
	assert.deepEqual(names, ['Style', 'levels']);

	const levels = decoded.root.children.find((c) => c.name === 'levels');
	assert.equal(levels.children.length, 5);

	for (const lvl of levels.children) {
		assert.equal(lvl.name, 'level');
		assert.equal(typeof lvl.attrs.name, 'string');
		assert.equal(lvl.attrs.x % 8, 0, 'level x is 8-aligned');
		assert.equal(lvl.attrs.y % 8, 0, 'level y is 8-aligned');
		assert.equal(lvl.attrs.width % 8, 0);
		assert.equal(lvl.attrs.height % 8, 0);

		const kids = lvl.children.map((c) => c.name);
		for (const need of ['solids', 'bg', 'entities', 'triggers']) assert.ok(kids.includes(need), `level has <${need}>`);

		const solids = lvl.children.find((c) => c.name === 'solids');
		const rows = solids.innerText.split('\n');
		assert.equal(rows.length, lvl.attrs.height / 8, 'solids row count == room height in tiles');
		assert.equal(rows[0].length, lvl.attrs.width / 8, 'solids row length == room width in tiles');
	}
});

test('generated chapter: exactly one goal, ids are unique, first room has a player', () => {
	const chapter = generateChapter({ seed: 'test-b', rooms: 7, name: 'TestB' });

	const ids = [];
	let players = 0;
	let goals = 0;
	for (const room of chapter.rooms) {
		for (const e of [...room.entities, ...room.triggers]) {
			ids.push(e.id);
			if (e.name === 'player') players++;
			if (e.name === 'everest/completeAreaTrigger') goals++;
		}
	}
	assert.equal(new Set(ids).size, ids.length, 'entity ids are unique across the whole map');
	assert.equal(players, chapter.rooms.length, 'one spawn point per room');
	assert.equal(goals, 1, 'exactly one complete-area trigger');

	const firstRoomPlayers = chapter.rooms[0].entities.filter((e) => e.name === 'player');
	assert.equal(firstRoomPlayers.length, 1);
});

test('generated chapter: every transition opening lines up on both sides', () => {
	for (const seed of ['seam-1', 'seam-2', 'seam-3', 'seam-4']) {
		const chapter = generateChapter({ seed, rooms: 10, name: 'Seam' });
		assert.equal(chapter.transitions.length, chapter.rooms.length - 1);

		for (const tr of chapter.transitions) {
			const a = chapter.rooms[tr.from];
			const b = chapter.rooms[tr.to];

			if (tr.dir === 'R' || tr.dir === 'L') {
				const aX = tr.dir === 'R' ? a.w - 1 : 0;
				const bX = tr.dir === 'R' ? 0 : b.w - 1;
				const aOpen = [];
				const bOpen = [];
				for (let y = 0; y < a.h; y++) {
					if (!a.solids.solid(aX, y)) aOpen.push(y);
					if (!b.solids.solid(bX, y)) bOpen.push(y);
				}
				assert.ok(aOpen.length >= 3, `${seed} ${tr.dir} ${tr.from}->${tr.to}: source edge open`);
				assert.deepEqual(aOpen, bOpen, `${seed} ${tr.dir} ${tr.from}->${tr.to}: rows line up`);
			} else {
				const aY = tr.dir === 'D' ? a.h - 1 : 0;
				const bY = tr.dir === 'D' ? 0 : b.h - 1;
				const aOpen = [];
				const bOpen = [];
				for (let x = 0; x < a.w; x++) {
					if (!a.solids.solid(x, aY)) aOpen.push(x);
					if (!b.solids.solid(x, bY)) bOpen.push(x);
				}
				assert.ok(aOpen.length >= tr.gap, `${seed} ${tr.dir} ${tr.from}->${tr.to}: source edge open`);
				assert.deepEqual(aOpen, bOpen, `${seed} ${tr.dir} ${tr.from}->${tr.to}: columns line up`);
			}
		}
	}
});

test('generated chapter: vertical transitions are produced, and no two rooms overlap', () => {
	let sawVertical = false;
	for (const seed of ['v1', 'v2', 'v3', 'v4', 'v5', 'v6']) {
		const chapter = generateChapter({ seed, rooms: 14, name: 'V' });
		if (chapter.transitions.some((t) => t.dir === 'U' || t.dir === 'D')) sawVertical = true;

		for (let i = 0; i < chapter.rooms.length; i++) {
			for (let j = i + 1; j < chapter.rooms.length; j++) {
				assert.ok(!roomsOverlap(chapter.rooms[i], chapter.rooms[j]), `${seed}: rooms ${i} and ${j} must not overlap`);
			}
		}
	}
	assert.ok(sawVertical, 'at least one U/D transition across the sampled seeds');
});

test('generated chapter: --straight stays a horizontal chain', () => {
	const chapter = generateChapter({ seed: 'straight-1', rooms: 8, name: 'S', straight: true });
	assert.ok(
		chapter.transitions.every((t) => t.dir === 'R'),
		'every transition is rightward',
	);
	assert.ok(
		chapter.rooms.every((r) => r.cy === 0),
		'every room on row 0',
	);
});

test('generated chapter: determinism — same seed, identical bytes', () => {
	const a = encodeChapterBin(generateChapter({ seed: 'det', rooms: 8, name: 'Det' }), 'Det');
	const b = encodeChapterBin(generateChapter({ seed: 'det', rooms: 8, name: 'Det' }), 'Det');
	assert.ok(a.equals(b), 'byte-identical for the same seed');

	const c = encodeChapterBin(generateChapter({ seed: 'other', rooms: 8, name: 'Det' }), 'Det');
	assert.ok(!a.equals(c), 'different seed -> different bytes');
});

test('generated chapter: every room is traversable entrance -> exit', () => {
	// re-run the generator's own reachability model as an independent gate
	for (const seed of ['t1', 't2', 't3', 't4', 't5']) {
		const chapter = generateChapter({ seed, rooms: 8, name: 'Trav' });
		for (const room of chapter.rooms) {
			assert.ok(roundTripAscii(room), `seed ${seed} room ${room.name} has a continuous open channel`);
		}
	}
});

/* ------------------------------------------------------------ ogmo emitter */

test('ogmo emitter: room -> level matches the celeste.ogmo template', (t) => {
	const tpl = findOgmoTemplate();
	if (!tpl) {
		t.skip('celeste.ogmo template not found (checked ogmo/celeste.ogmo and celeste.ogmo)');
		return;
	}
	const project = JSON.parse(fs.readFileSync(tpl, 'utf8'));
	const ctx = indexProject(project);
	const chapter = generateChapter({ seed: 'ogmo-1', rooms: 3, name: 'OgmoT' });
	const room = chapter.rooms[1];
	const level = roomToOgmoLevel(room, chapter, project, ctx);

	assert.equal(level.width, room.w * 8);
	assert.equal(level.height, room.h * 8);
	assert.equal(level.offsetX, room.worldPxX(), 'ogmo level offset carries the room world position');
	assert.equal(level.offsetY, room.worldPxY());

	const solids = level.layers.find((l) => l.name === 'solids');
	assert.equal(String(solids._eid), String(ctx.layerByName.solids.exportID));
	assert.equal(solids.arrayMode, 1);
	assert.equal(solids.grid.length, room.w * room.h, 'flat grid length == w*h');
	assert.ok(
		solids.grid.every((c) => typeof c === 'string' && c.length === 1),
		'grid cells are single chars',
	);

	const ents = level.layers.find((l) => l.name === 'entities');
	const player = ents.entities.find((e) => e.name === 'player');
	assert.ok(player, 'player present in entities layer');
	assert.ok(player.x >= 0 && player.x <= level.width, 'player x is room-local');
	assert.equal(String(player._eid), String(ctx.entityDefs.player.exportID));

	// enum attrs must be integer indices in Ogmo output
	for (const room2 of chapter.rooms) {
		const lvl = roomToOgmoLevel(room2, chapter, project, ctx);
		const el = lvl.layers.find((l) => l.name === 'entities');
		const spikes = el.entities.find((e) => e.name === 'spikesDown');
		if (spikes && spikes.values && 'type' in spikes.values) {
			assert.equal(typeof spikes.values.type, 'number', 'spikesDown.type is an enum index');
		}
	}
});

/* -------------------------------------------------------------- import-bin */

test('import-bin: decoding a generated .bin reproduces the ogmo emitter\'s own JSON exactly', (t) => {
	const tpl = findOgmoTemplate();
	if (!tpl) {
		t.skip('celeste.ogmo template not found (checked ogmo/celeste.ogmo and celeste.ogmo)');
		return;
	}
	const project = JSON.parse(fs.readFileSync(tpl, 'utf8'));
	const ctx = indexProject(project);

	// mixed biomes + a non-zero world offset (room 0 sits at the layout's
	// origin, so exercise a later room too) is exactly what caught the
	// world-vs-room-local coordinate bug this test guards against.
	const chapter = generateChapter({ seed: 'import-roundtrip', rooms: 6, name: 'ImportRT', biome: 'random' });
	const bin = encodeChapterBin(chapter, chapter.name);

	const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'celeste-pcg-import-test-'));
	const binPath = path.join(tmpDir, 'ImportRT.bin');
	fs.writeFileSync(binPath, bin);

	const r = importBin(binPath, tmpDir, tpl, { copyProject: false });
	assert.equal(r.roomCount, chapter.rooms.length);
	assert.deepEqual(r.unknownEntities, [], 'every entity this generator emits is defined in the template');
	assert.equal(r.decalCount, 0, 'the generator never emits decals');

	for (const room of chapter.rooms) {
		const expected = roomToOgmoLevel(room, chapter, project, ctx);
		const actual = JSON.parse(fs.readFileSync(path.join(tmpDir, `${room.name}.json`), 'utf8'));
		assert.deepEqual(actual, expected, `${room.name}: import-bin output matches the ogmo emitter's own output`);
	}

	fs.rmSync(tmpDir, { recursive: true, force: true });
});
