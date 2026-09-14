'use strict';

/*
	A dense 2D grid of single-character tile ids, row-major.

	Celeste tile chars (see celeste.ogmo "solids"/"bg" legends):
	  '0' = air / empty
	  '1' = the default generic tileset (dirt for solids, rock wall for bg)
	  '3'..'n' = other vanilla tilesets (snow, girder, cliffside, ...)

	The .bin only stores this char matrix; Celeste does all visual autotiling at
	render time from its own ForegroundTiles.xml / BackgroundTiles.xml rules, so
	there is nothing to "autotile" here — a correct char grid is the whole job.
*/

const AIR = '0';

class Grid {
	constructor(w, h, fill = AIR) {
		this.w = w;
		this.h = h;
		this.cells = new Array(w * h).fill(fill);
	}

	inside(x, y) {
		return x >= 0 && y >= 0 && x < this.w && y < this.h;
	}

	get(x, y) {
		if (!this.inside(x, y)) return AIR;
		return this.cells[y * this.w + x];
	}

	set(x, y, v) {
		if (!this.inside(x, y)) return;
		this.cells[y * this.w + x] = v;
	}

	/** is this cell non-air (i.e. collision for the "solids" grid)? */
	solid(x, y) {
		return this.get(x, y) !== AIR;
	}

	fillRect(x0, y0, x1, y1, v) {
		for (let y = y0; y <= y1; y++) {
			for (let x = x0; x <= x1; x++) this.set(x, y, v);
		}
	}

	/** row-major flat array of 1-char strings — exactly Ogmo GridLayer arrayMode ONE. */
	toFlatArray() {
		return this.cells.slice();
	}

	/** newline-joined rows — exactly Celeste's <solids innerText="..."> blob. */
	toInnerText() {
		const rows = [];
		for (let y = 0; y < this.h; y++) {
			rows.push(this.cells.slice(y * this.w, (y + 1) * this.w).join(''));
		}
		return rows.join('\n');
	}
}

module.exports = { Grid, AIR };
