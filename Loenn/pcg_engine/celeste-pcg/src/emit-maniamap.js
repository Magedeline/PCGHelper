'use strict';

const fs = require('fs');
const path = require('path');

/*
	Chapter model → ManiaMap LayoutGraph + RoomTemplate JSON.

	ManiaMap (https://github.com/mpewsey/ManiaMap) generates metroidvania-style
	layouts from a LayoutGraph (room connectivity graph) and RoomTemplates (2D cell
	grids with door positions). This emitter converts a generated Chapter to those
	two formats so ManiaMap can visualise or re-layout the room graph.

	Outputs:
	  <outDir>/maniamap/<name>.graph.json      — LayoutGraph  (nodes + edges)
	  <outDir>/maniamap/<name>.templates.json  — RoomTemplate array (one per room)

	ManiaMap door-direction mapping (Celeste edge → ManiaMap direction):
	  'left'   exit / entrance  → West  door  at col 0
	  'right'  exit / entrance  → East  door  at col room.w − 1
	  'top'    exit / entrance  → North door  at row 0
	  'bottom' exit / entrance  → South door  at row room.h − 1

	Door alignment guarantee:
	  Horizontal transitions (R/L): both rooms use the same transition.row as the
	  solid floor row, so the door cell (row = transition.row − 1) is identical in
	  both room-local coordinate systems → ManiaMap door alignment holds.

	  Vertical transitions (U/D): both rooms share transition.col / transition.gap,
	  so the centre column (col + floor(gap/2)) is the same on both sides → aligned.

	Loading in C# with ManiaMap:
	  var graphJson     = File.ReadAllText("genchapter.graph.json");
	  var templatesJson = File.ReadAllText("genchapter.templates.json");
	  // Use a JSON library (e.g. System.Text.Json or Newtonsoft.Json) to deserialise
	  // into ManiaMap.LayoutGraph / ManiaMap.RoomTemplate objects, then pass to
	  // LayoutGenerator.Generate(id, graph, templateGroups, randomSeed).
	  //
	  // The Grid string encodes tile data row-major: '0' = open (Cell.New), '1' = wall.
	  // Rebuild Array2D<Cell> by scanning: null for '1' cells, Cell.New for '0' cells,
	  // then attach doors from the Doors array to their boundary cells.
*/

// ── door position helpers ────────────────────────────────────────────────────

// Bottommost open row above the solid floor row for a horizontal (L/R) port.
// carveEdgeOpening carves rows [port.row − CH_TOP .. port.row − 1] open, so
// port.row − 1 is always the lowest open cell at that boundary column.
function hDoorRow(portRow) {
	return portRow - 1;
}

// Centre column for a vertical (U/D) port matching carveVerticalPort's `mid`.
function vDoorCol(portCol, portGap) {
	return portCol + Math.floor((portGap || 3) / 2);
}

// Return the ManiaMap door descriptors for a room's entrance and exit ports.
function roomDoors(room) {
	const doors = [];
	for (const port of [room.entrancePort, room.exitPort]) {
		if (!port) continue;
		switch (port.edge) {
			case 'left':
				doors.push({ Row: hDoorRow(port.row), Col: 0, Direction: 'West' });
				break;
			case 'right':
				doors.push({ Row: hDoorRow(port.row), Col: room.w - 1, Direction: 'East' });
				break;
			case 'top':
				doors.push({ Row: 0, Col: vDoorCol(port.col, port.gap), Direction: 'North' });
				break;
			case 'bottom':
				doors.push({ Row: room.h - 1, Col: vDoorCol(port.col, port.gap), Direction: 'South' });
				break;
		}
	}
	return doors;
}

// ── graph builder ────────────────────────────────────────────────────────────

/*
	LayoutGraph JSON shape (ManiaMap DataMember property names):
	{
	  "Id": 1,
	  "Name": "GenChapter",
	  "Nodes": [ { "Id": 1, "Name": "genchapter_0", "Z": 0, "TemplateGroup": "genchapter_0", ... } ],
	  "Edges": [ { "FromNode": 1, "ToNode": 2, "Direction": "Both", "RequireRoom": true, ... } ]
	}
*/
function buildGraph(chapter) {
	const nodes = chapter.rooms.map((room, i) => ({
		Id: i + 1,
		Name: room.name,
		Z: 0,
		TemplateGroup: room.name, // each room has a unique template so layout is preserved
		Color: { R: 25, G: 25, B: 112, A: 255 },
		Tags: [],
	}));

	const edges = chapter.transitions.map((t) => ({
		Name: '',
		FromNode: t.from + 1, // ManiaMap node ids are 1-based
		ToNode: t.to + 1,
		Direction: 'Both',    // rooms are reachable in both directions
		DoorCode: 0,
		Z: 0,
		RoomChance: 1.0,
		RequireRoom: true,
		Color: { R: 25, G: 25, B: 112, A: 255 },
		TemplateGroup: '',
		Tags: [],
	}));

	return { Id: 1, Name: chapter.name, Nodes: nodes, Edges: edges };
}

// ── template builder ─────────────────────────────────────────────────────────

/*
	Templates JSON shape (one entry per room):
	{
	  "Templates": [
	    {
	      "Id": 1,
	      "Name": "genchapter_0",
	      "TemplateGroup": "genchapter_0",
	      "Rows": 23,
	      "Cols": 44,
	      "Grid": "1111...0001...",  // flat row-major, '1'=solid, '0'=open
	      "Doors": [
	        { "Row": 10, "Col": 0,  "Direction": "West"  },
	        { "Row": 10, "Col": 43, "Direction": "East"  }
	      ]
	    }
	  ]
	}

	To reconstruct a ManiaMap Array2D<Cell> in C#:
	  for each (row, col): cells[row, col] = Grid[row*Cols+col]=='1' ? null : Cell.New;
	  foreach door in Doors: cells[door.Row, door.Col].SetDoors(door.Direction[0].ToString(), Door.TwoWay);
*/
function buildTemplates(chapter) {
	const templates = chapter.rooms.map((room, i) => ({
		Id: i + 1,
		Name: room.name,
		TemplateGroup: room.name,
		Rows: room.h,
		Cols: room.w,
		Grid: room.solids.toFlatArray().join(''), // '1'=solid wall, '0'=open
		Doors: roomDoors(room),
	}));

	return { Templates: templates };
}

// ── writer ───────────────────────────────────────────────────────────────────

/**
 * Write ManiaMap LayoutGraph and RoomTemplate JSON files.
 *
 * @returns {{ dir, graphPath, templatesPath }}
 */
function writeManiaMap(chapter, outDir) {
	const dir = path.join(outDir, 'maniamap');
	fs.mkdirSync(dir, { recursive: true });

	const base = chapter.name.toLowerCase();
	const graphPath = path.join(dir, `${base}.graph.json`);
	const templatesPath = path.join(dir, `${base}.templates.json`);

	fs.writeFileSync(graphPath, JSON.stringify(buildGraph(chapter), null, 2));
	fs.writeFileSync(templatesPath, JSON.stringify(buildTemplates(chapter), null, 2));

	return { dir, graphPath, templatesPath };
}

module.exports = { writeManiaMap, buildGraph, buildTemplates, roomDoors };
