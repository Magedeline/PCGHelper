'use strict';

const fs = require('fs');
const path = require('path');
const { TILE } = require('./model');

/*
	Chapter model -> one Ogmo Editor 3 level (.json) per room, matching the
	celeste.ogmo project template so the rooms open straight in OgmoEditor3-CE.

	The on-disk Ogmo level shape (what the editor writes after Export.stripJSON
	removes its _name/_contents helpers):

	  { ogmoVersion, width, height, offsetX, offsetY, values:{...},
	    layers: [
	      { name, _eid, offsetX, offsetY, gridCellWidth, gridCellHeight,
	        gridCellsX, gridCellsY,
	        arrayMode:1, grid:[ "0","1",... ] }          // grid layers (solids/bg)
	      { name, _eid, ...same grid fields...,
	        entities:[ {name,id,_eid,x,y,originX,originY,width?,height?,values?} ] }
	    ] }

	GridLayer arrayMode ONE is row-major (y outer, x inner) — exactly Grid.toFlatArray().

	Enum entity/level values serialize in Ogmo as their integer choice index, not
	the string; the model stores the Celeste-facing string, so we map it back here
	using the project's own value definitions.
*/

function indexProject(project) {
	const layerByName = {};
	for (const l of project.layers) layerByName[l.name] = l;

	const entityDefs = {};
	for (const e of project.entities) entityDefs[e.name] = e;

	const levelValueDefs = {};
	for (const v of project.levelValues || []) levelValueDefs[v.name] = v;

	return { layerByName, entityDefs, levelValueDefs };
}

function enumIndex(def, value) {
	if (!def || !Array.isArray(def.choices)) return value;
	const i = def.choices.indexOf(value);
	return i >= 0 ? i : def.defaults || 0;
}

/** coerce one attribute to its Ogmo on-disk representation given its value definition */
function ogmoValue(def, value) {
	if (!def) return value;
	switch (def.definition) {
		case 'Enum':
			return enumIndex(def, value);
		case 'Boolean':
			return !!value;
		case 'Integer':
			return Math.round(Number(value));
		case 'Float':
			return Number(value);
		default:
			return value == null ? '' : String(value);
	}
}

function gridLayer(layerDef, grid) {
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

function entityLayer(layerDef, entities, room, ctx) {
	const list = entities.map((e) => {
		const def = ctx.entityDefs[e.name] || {};
		const valueDefs = {};
		for (const v of def.values || []) valueDefs[v.name] = v;

		const out = {
			name: e.name,
			id: e.id,
			_eid: def.exportID != null ? def.exportID : 0,
			x: e.x - room.worldPxX(),
			y: e.y - room.worldPxY(),
		};

		if (e.originX != null) out.originX = e.originX;
		if (e.originY != null) out.originY = e.originY;
		if (e.width != null && def.resizeableX) out.width = e.width;
		if (e.height != null && def.resizeableY) out.height = e.height;

		const values = {};
		let has = false;
		for (const [k, v] of Object.entries(e.attrs || {})) {
			values[k] = ogmoValue(valueDefs[k], v);
			has = true;
		}
		if (has) out.values = values;

		if (e.nodes && e.nodes.length) {
			out.nodes = e.nodes.map((n) => ({ x: n.x - room.worldPxX(), y: n.y - room.worldPxY() }));
		}
		return out;
	});

	return {
		name: layerDef.name,
		_eid: layerDef.exportID,
		offsetX: 0,
		offsetY: 0,
		gridCellWidth: TILE,
		gridCellHeight: TILE,
		gridCellsX: room.w,
		gridCellsY: room.h,
		entities: list,
	};
}

function levelValues(project, chapter, ctx) {
	const out = {};
	for (const v of project.levelValues || []) {
		let val;
		switch (v.name) {
			case 'music':
				val = chapter.meta.music || '';
				break;
			case 'ambience':
				val = chapter.meta.ambience || '';
				break;
			default:
				val = v.defaults;
		}
		if (v.definition === 'Enum') out[v.name] = enumIndex(v, val);
		else if (v.definition === 'Boolean') out[v.name] = typeof v.defaults === 'boolean' ? v.defaults : false;
		else if (v.definition === 'String') out[v.name] = typeof v.defaults === 'string' ? v.defaults : '';
		else out[v.name] = v.defaults != null ? v.defaults : 0;
	}
	return out;
}

function roomToOgmoLevel(room, chapter, project, ctx) {
	const { layerByName } = ctx;
	const layers = [];
	for (const l of project.layers) {
		if (l.name === 'solids') layers.push(gridLayer(l, room.solids));
		else if (l.name === 'bg') layers.push(gridLayer(l, room.bg));
		else if (l.name === 'entities') layers.push(entityLayer(l, room.entities, room, ctx));
		else if (l.name === 'triggers') layers.push(entityLayer(l, room.triggers, room, ctx));
	}

	return {
		ogmoVersion: project.ogmoVersion || '3.4.0',
		width: room.widthPx(),
		height: room.heightPx(),
		// the room's world position, so loading every room into one Ogmo project
		// lays the chapter out the way the .bin has it (incl. vertical stacking)
		offsetX: room.worldPxX(),
		offsetY: room.worldPxY(),
		values: levelValues(project, chapter, ctx),
		layers,
	};
}

/**
 * Write one Ogmo level file per room plus a copy of the project template:
 *   <outDir>/ogmo/celeste.ogmo
 *   <outDir>/ogmo/<room>.json
 */
function writeOgmoProject(chapter, outDir, ogmoTemplatePath) {
	const project = JSON.parse(fs.readFileSync(ogmoTemplatePath, 'utf8'));
	const ctx = indexProject(project);

	const dir = path.join(outDir, 'ogmo');
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(path.join(dir, 'celeste.ogmo'), JSON.stringify(project));

	const files = [];
	for (const room of chapter.rooms) {
		const level = roomToOgmoLevel(room, chapter, project, ctx);
		const file = path.join(dir, `${room.name}.json`);
		fs.writeFileSync(file, JSON.stringify(level));
		files.push(file);
	}
	return { dir, files };
}

module.exports = { writeOgmoProject, roomToOgmoLevel, indexProject, ogmoValue, enumIndex };
