'use strict';

const fs = require('fs');
const path = require('path');
const { encodeMap } = require('./binary-packer');
const { TILE } = require('./model');

/*
	Chapter model -> Celeste ".bin" map.

	Tree:
	  Map
	   ├─ Style
	   │   ├─ Backgrounds        (empty — a generator can't safely reference stylegrounds
	   │   └─ Foregrounds        (empty    that may not ship with the player's install)
	   └─ levels
	       └─ level  (one per room)
	           ├─ solids   innerText = fg tile blob
	           ├─ bg       innerText = bg tile blob
	           ├─ entities  (child <entity id x y .../> elements, <node/> children)
	           ├─ triggers  (same shape)
	           ├─ fgdecals  (empty)
	           └─ bgdecals  (empty)

	Celeste entity elements carry ONLY id/x/y/width/height + custom values + nodes —
	no name-as-attr, no _eid, no origin (that's Ogmo bookkeeping). The element's tag
	name IS the entity name.
*/

function entityElement(e) {
	const attrs = { id: e.id, x: e.x, y: e.y };
	if (e.width != null) attrs.width = e.width;
	if (e.height != null) attrs.height = e.height;
	for (const [k, v] of Object.entries(e.attrs || {})) attrs[k] = v;

	const children = (e.nodes || []).map((n) => ({ name: 'node', attrs: { x: Math.round(n.x), y: Math.round(n.y) }, children: [] }));
	return { name: e.name, attrs, children };
}

function levelElement(room, chapter) {
	const meta = chapter.meta;
	const level = {
		name: room.name,
		x: room.worldPxX(),
		y: room.worldPxY(),
		width: room.widthPx(),
		height: room.heightPx(),
		music: meta.music || '',
		alt_music: '',
		ambience: meta.ambience || '',
		musicLayer1: true,
		musicLayer2: true,
		musicLayer3: true,
		musicLayer4: true,
		musicProgress: '',
		ambienceProgress: '',
		dark: false,
		underwater: false,
		space: false,
		disableDownTransition: false,
		windPattern: 'None',
		c: 0,
		cameraOffsetX: 0,
		cameraOffsetY: 0,
	};

	const children = [
		{ name: 'solids', attrs: { offsetX: 0, offsetY: 0 }, innerText: room.solids.toInnerText(), children: [] },
		{ name: 'bg', attrs: { offsetX: 0, offsetY: 0 }, innerText: room.bg.toInnerText(), children: [] },
		{ name: 'entities', attrs: {}, children: room.entities.map(entityElement) },
		{ name: 'triggers', attrs: {}, children: room.triggers.map(entityElement) },
		{ name: 'fgdecals', attrs: { tileset: '0', offsetX: 0, offsetY: 0 }, children: [] },
		{ name: 'bgdecals', attrs: { tileset: '0', offsetX: 0, offsetY: 0 }, children: [] },
	];

	return { name: 'level', attrs: level, children };
}

function buildMapTree(chapter) {
	return {
		name: 'Map',
		attrs: {},
		children: [
			{
				name: 'Style',
				attrs: {},
				children: [
					{ name: 'Backgrounds', attrs: {}, children: [] },
					{ name: 'Foregrounds', attrs: {}, children: [] },
				],
			},
			{
				name: 'levels',
				attrs: {},
				children: chapter.rooms.map((r) => levelElement(r, chapter)),
			},
		],
	};
}

/** encode just the .bin bytes. `packageName` is the map's internal id (path under Maps/, no extension). */
function encodeChapterBin(chapter, packageName) {
	return encodeMap(buildMapTree(chapter), packageName || chapter.name);
}

/**
 * Write a ready-to-zip Everest mod folder:
 *   <outDir>/
 *     everest.yaml
 *     Maps/<name>.bin
 */
function writeMod(chapter, outDir, opts = {}) {
	const name = chapter.name;
	const everestVersion = opts.everestVersion || '1.4489.0';
	fs.mkdirSync(path.join(outDir, 'Maps'), { recursive: true });

	const bin = encodeChapterBin(chapter, name);
	const binPath = path.join(outDir, 'Maps', `${name}.bin`);
	fs.writeFileSync(binPath, bin);

	const yaml =
		`- Name: ${name}\n` +
		`  Version: 1.0.0\n` +
		`  Dependencies:\n` +
		`    - Name: Everest\n` +
		`      Version: ${everestVersion}\n`;
	fs.writeFileSync(path.join(outDir, 'everest.yaml'), yaml);

	return { binPath, bytes: bin.length, mapId: name };
}

module.exports = { buildMapTree, encodeChapterBin, writeMod };
