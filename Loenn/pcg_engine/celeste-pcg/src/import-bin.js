'use strict';

const fs = require('fs');
const path = require('path');
const { decodeMap } = require('./binary-packer');
const { Grid } = require('./grid');
const { TILE } = require('./model');
const { indexProject, ogmoValue } = require('./emit-ogmo');

/*
	Celeste ".bin" -> OgmoEditor3-CE per-room JSON, the reverse of emit-ogmo.js /
	emit-bin.js. This is what makes ANY Celeste map — vanilla or a mod's, not just
	one this tool generated — openable and hand-editable in OgmoEditor3-CE: decode
	the binary tree (binary-packer.js already implements that half), then rebuild
	each <level> as an Ogmo level JSON using the target celeste.ogmo project for
	the entity origin/size and enum/value definitions the .bin format itself
	doesn't carry (see the comment atop emit-bin.js — a Celeste entity element is
	only ever id/x/y/width/height + custom values + nodes).

	Two limitations, both surfaced back to the caller rather than silently
	swallowed:
	  - an entity name absent from the target project's <entities> list imports
	    with position/size/values intact but origin (0,0) and _eid 0 — Ogmo will
	    still load and show it, just without that entity's real anchor point.
	  - fgdecals/bgdecals are dropped: this repo's celeste.ogmo has no decal layer
	    to put them in (Ogmo3 decal layers are a separate, larger feature).
*/

function findChild(node, name) {
	return (node.children || []).find((c) => c.name === name);
}
function findChildren(node, name) {
	return (node.children || []).filter((c) => c.name === name);
}

/** reverse of Grid.toInnerText(): newline rows -> a w x h Grid, padding short
    rows/short maps with air and truncating anything longer than expected. */
function parseGridInnerText(innerText, w, h) {
	const grid = new Grid(w, h, '0');
	const rows = (innerText || '').split('\n');
	for (let y = 0; y < h; y++) {
		const row = rows[y] || '';
		for (let x = 0; x < w; x++) grid.set(x, y, row[x] || '0');
	}
	return grid;
}

function gridLayerJson(layerDef, grid) {
	return {
		name: layerDef.name,
		_eid: layerDef.exportID,
		offsetX: 0,
		offsetY: 0,
		gridCellWidth: TILE,
		gridCellHeight: TILE,
		gridCellsX: grid.w,
		gridCellsY: grid.h,
		arrayMode: 1,
		grid: grid.toFlatArray(),
	};
}

/** one .bin <entity>/<trigger> element -> one Ogmo entity JSON object.
    Celeste's .bin stores x/y in WORLD pixels (one shared space for the whole
    map); Ogmo's per-room JSON stores them room-LOCAL (see emit-ogmo.js's
    entityLayer: `x: e.x - room.worldPxX()`). levelX/levelY is that room's own
    world offset, so it has to come back out here or every room but the one
    sitting at world (0,0) imports with every entity shifted into a neighbour. */
function importEntity(node, levelX, levelY, ctx, unknownNames) {
	const def = ctx.entityDefs[node.name];
	if (!def) unknownNames.add(node.name);
	const valueDefs = {};
	if (def) for (const v of def.values || []) valueDefs[v.name] = v;

	const attrs = node.attrs || {};
	const { id, x, y, width, height, ...rest } = attrs;

	const out = {
		name: node.name,
		id: id != null ? id : 0,
		_eid: def && def.exportID != null ? def.exportID : 0,
		x: (x || 0) - levelX,
		y: (y || 0) - levelY,
		originX: def && def.origin ? def.origin.x : 0,
		originY: def && def.origin ? def.origin.y : 0,
	};
	if (width != null && (!def || def.resizeableX)) out.width = width;
	if (height != null && (!def || def.resizeableY)) out.height = height;

	const values = {};
	let hasValues = false;
	for (const [k, v] of Object.entries(rest)) {
		values[k] = ogmoValue(valueDefs[k], v);
		hasValues = true;
	}
	if (hasValues) out.values = values;

	const nodeChildren = findChildren(node, 'node');
	if (nodeChildren.length) {
		out.nodes = nodeChildren.map((n) => ({ x: ((n.attrs && n.attrs.x) || 0) - levelX, y: ((n.attrs && n.attrs.y) || 0) - levelY }));
	}
	return out;
}

function entityLayerJson(layerDef, entityNodes, gridW, gridH, levelX, levelY, ctx, unknownNames) {
	return {
		name: layerDef.name,
		_eid: layerDef.exportID,
		offsetX: 0,
		offsetY: 0,
		gridCellWidth: TILE,
		gridCellHeight: TILE,
		gridCellsX: gridW,
		gridCellsY: gridH,
		entities: entityNodes.map((n) => importEntity(n, levelX, levelY, ctx, unknownNames)),
	};
}

function countDecals(levelNode) {
	let n = 0;
	for (const key of ['fgdecals', 'bgdecals']) {
		const dnode = findChild(levelNode, key);
		if (dnode) n += (dnode.children || []).length;
	}
	return n;
}

function importLevel(levelNode, project, ctx, unknownNames) {
	const attrs = levelNode.attrs || {};
	const w = attrs.width || 0;
	const h = attrs.height || 0;
	const levelX = attrs.x || 0;
	const levelY = attrs.y || 0;
	const gridW = Math.round(w / TILE);
	const gridH = Math.round(h / TILE);

	const solidsNode = findChild(levelNode, 'solids');
	const bgNode = findChild(levelNode, 'bg');
	const entitiesNode = findChild(levelNode, 'entities');
	const triggersNode = findChild(levelNode, 'triggers');

	const solidsGrid = parseGridInnerText(solidsNode && solidsNode.innerText, gridW, gridH);
	const bgGrid = parseGridInnerText(bgNode && bgNode.innerText, gridW, gridH);
	const entityNodes = entitiesNode ? entitiesNode.children || [] : [];
	const triggerNodes = triggersNode ? triggersNode.children || [] : [];

	const layers = [];
	for (const l of project.layers) {
		if (l.name === 'solids') layers.push(gridLayerJson(l, solidsGrid));
		else if (l.name === 'bg') layers.push(gridLayerJson(l, bgGrid));
		else if (l.name === 'entities') layers.push(entityLayerJson(l, entityNodes, gridW, gridH, levelX, levelY, ctx, unknownNames));
		else if (l.name === 'triggers') layers.push(entityLayerJson(l, triggerNodes, gridW, gridH, levelX, levelY, ctx, unknownNames));
	}

	const values = {};
	for (const v of project.levelValues || []) {
		const raw = Object.prototype.hasOwnProperty.call(attrs, v.name) ? attrs[v.name] : v.defaults;
		values[v.name] = ogmoValue(v, raw);
	}

	return {
		ogmoVersion: project.ogmoVersion || '3.4.0',
		width: w,
		height: h,
		offsetX: attrs.x || 0,
		offsetY: attrs.y || 0,
		values,
		layers,
	};
}

/**
 * Decode a Celeste .bin and write one Ogmo level JSON per room into `outDir`,
 * ready to open in OgmoEditor3-CE.
 *
 * @param {string} binPath          path to the .bin map
 * @param {string} outDir           directory to write into (celeste.ogmo copy +
 *                                  one <levelname>.json per room, unless
 *                                  opts.copyProject is false)
 * @param {string} ogmoTemplatePath celeste.ogmo project supplying entity/value
 *                                  definitions for the reverse enum/origin lookup
 * @param {{copyProject?: boolean}} opts
 */
function importBin(binPath, outDir, ogmoTemplatePath, opts = {}) {
	const copyProject = opts.copyProject !== false;
	const project = JSON.parse(fs.readFileSync(ogmoTemplatePath, 'utf8'));
	const ctx = indexProject(project);

	const buf = fs.readFileSync(binPath);
	const { root, package: pkg } = decodeMap(buf);
	const levelsNode = findChild(root, 'levels');
	const levelNodes = levelsNode ? findChildren(levelsNode, 'level') : [];
	if (!levelNodes.length) {
		throw new Error(`no <level> elements found in ${binPath} — is this a valid Celeste .bin?`);
	}

	fs.mkdirSync(outDir, { recursive: true });
	if (copyProject) fs.writeFileSync(path.join(outDir, 'celeste.ogmo'), JSON.stringify(project));

	const unknownEntities = new Set();
	let decalCount = 0;
	const files = [];
	levelNodes.forEach((levelNode, i) => {
		const level = importLevel(levelNode, project, ctx, unknownEntities);
		const name = (levelNode.attrs && levelNode.attrs.name) || `level_${i}`;
		const file = path.join(outDir, `${name}.json`);
		fs.writeFileSync(file, JSON.stringify(level));
		files.push(file);
		decalCount += countDecals(levelNode);
	});

	return {
		dir: outDir,
		files,
		packageName: pkg,
		roomCount: levelNodes.length,
		unknownEntities: [...unknownEntities],
		decalCount,
	};
}

module.exports = { importBin };
