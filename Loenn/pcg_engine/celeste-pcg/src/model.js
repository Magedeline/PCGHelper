'use strict';

const { Grid } = require('./grid');

const TILE = 8; // Celeste's grid unit, in pixels

/*
	Emitter-agnostic in-memory model.

	A Chapter is one Celeste map: a list of Rooms plus a shared entity-id counter
	(entity `id` must be unique across the WHOLE map, not per room).

	Coordinates in the model are WORLD coordinates:
	  - Room.tx / Room.ty : world position in TILES
	  - Entity.x / Entity.y : world position in PIXELS
	The Celeste .bin emitter uses these as-is. The Ogmo per-room emitter converts
	entities to room-local pixels by subtracting the room origin.
*/

class Entity {
	constructor(name, x, y, opts = {}) {
		this.name = name;
		this.x = Math.round(x);
		this.y = Math.round(y);
		this.width = opts.width != null ? Math.round(opts.width) : null;
		this.height = opts.height != null ? Math.round(opts.height) : null;
		this.originX = opts.originX != null ? opts.originX : null;
		this.originY = opts.originY != null ? opts.originY : null;
		this.attrs = opts.attrs || {}; // custom values, e.g. { color: 'blue' }
		this.nodes = opts.nodes || []; // [{x,y}, ...] world pixels
		this.id = 0; // assigned by Chapter.finalize()
	}
}

class Room {
	constructor(name, tx, ty, w, h) {
		this.name = name;
		this.tx = tx;
		this.ty = ty;
		this.w = w; // tiles
		this.h = h; // tiles
		this.solids = new Grid(w, h, '1'); // start as solid rock, carve into it
		this.bg = new Grid(w, h, '1'); // full background wall behind everything
		this.entities = [];
		this.triggers = [];
		// channel-top row (0-based, room-local) at each shared border. null = map edge.
		this.entranceRow = null;
		this.exitRow = null;
		// room-local cells that the guaranteed route passes through — decoration must not block these
		this.protectedCells = new Set();
	}

	key(x, y) {
		return y * this.w + x;
	}

	protect(x, y) {
		this.protectedCells.add(this.key(x, y));
	}

	isProtected(x, y) {
		return this.protectedCells.has(this.key(x, y));
	}

	worldPxX() {
		return this.tx * TILE;
	}
	worldPxY() {
		return this.ty * TILE;
	}
	widthPx() {
		return this.w * TILE;
	}
	heightPx() {
		return this.h * TILE;
	}

	/** Clamp a would-be entity position + footprint so it always lands strictly
	    inside this room's own rectangle (at least one tile in from every wall).
	    Without this, a math slip in a carve/decorate pass can hand back a
	    coordinate outside the room; Celeste's .bin only ever gives an entity
	    the tiles of the level it's listed under, so anything outside that
	    rectangle spawns in the void and just doesn't work (no collision, no
	    trigger fire, nothing to stand on). Centralizing the clamp here means
	    every call site works safely, present and future. */
	clampToBounds(x, y, opts = {}) {
		const margin = TILE;
		const w = opts.width || 0;
		const h = opts.height || 0;
		let minX = this.worldPxX() + margin;
		let maxX = this.worldPxX() + this.widthPx() - margin - w;
		let minY = this.worldPxY() + margin;
		let maxY = this.worldPxY() + this.heightPx() - margin - h;
		if (maxX < minX) maxX = minX;
		if (maxY < minY) maxY = minY;
		return {
			x: Math.min(Math.max(x, minX), maxX),
			y: Math.min(Math.max(y, minY), maxY),
		};
	}

	addEntity(name, worldX, worldY, opts) {
		const p = this.clampToBounds(worldX, worldY, opts);
		const e = new Entity(name, p.x, p.y, opts);
		this.entities.push(e);
		return e;
	}

	addTrigger(name, worldX, worldY, opts) {
		const p = this.clampToBounds(worldX, worldY, opts);
		const e = new Entity(name, p.x, p.y, opts);
		this.triggers.push(e);
		return e;
	}
}

class Chapter {
	constructor(name, meta = {}) {
		this.name = name;
		this.rooms = [];
		// one entry per consecutive room pair: { dir:'R'|'L'|'U'|'D', from, to, row? , col?, gap? }
		this.transitions = [];
		this.meta = Object.assign(
			{
				music: '', // e.g. "music_city"; "" = silent
				ambience: '',
				seed: 0,
			},
			meta,
		);
	}

	addRoom(room) {
		this.rooms.push(room);
		return room;
	}

	/** assign globally-unique ids to every entity and trigger. Call once, last. */
	finalize() {
		let id = 1;
		for (const room of this.rooms) {
			for (const e of room.entities) e.id = id++;
			for (const t of room.triggers) t.id = id++;
		}
		this.nextId = id;
		return this;
	}
}

module.exports = { Chapter, Room, Entity, TILE };
