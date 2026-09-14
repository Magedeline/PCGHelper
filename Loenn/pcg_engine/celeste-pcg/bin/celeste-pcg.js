#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { generateChapter, BIOME_NAMES } = require('../src/generate');
const { writeMod } = require('../src/emit-bin');
const { writeOgmoProject } = require('../src/emit-ogmo');
const { writeManiaMap } = require('../src/emit-maniamap');

function parseArgs(argv) {
	const opts = {
		seed: 'celeste-pcg',
		rooms: 6,
		name: 'GenChapter',
		music: '',
		ambience: '',
		difficulty: 'normal',
		roomWidth: 44,
		roomHeight: 23,
		straight: false,
		biome: 'random',
		out: path.join(process.cwd(), 'out'),
		format: 'both', // bin | ogmo | maniamap | both | all
		ogmoTemplate: path.join(__dirname, '..', '..', 'celeste.ogmo'),
		preview: false,
	};
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		const next = () => argv[++i];
		switch (a) {
			case '--seed': opts.seed = next(); break;
			case '--rooms': opts.rooms = parseInt(next(), 10); break;
			case '--name': opts.name = next(); break;
			case '--music': opts.music = next(); break;
			case '--ambience': opts.ambience = next(); break;
			case '--difficulty': opts.difficulty = next(); break;
			case '--room-width': opts.roomWidth = parseInt(next(), 10); break;
			case '--room-height': opts.roomHeight = parseInt(next(), 10); break;
			case '--straight': opts.straight = true; break;
			case '--biome': opts.biome = next(); break;
			case '--out': opts.out = path.resolve(next()); break;
			case '--format': opts.format = next(); break;
			case '--ogmo-template': opts.ogmoTemplate = path.resolve(next()); break;
			case '--preview': opts.preview = true; break;
			case '-h':
			case '--help': opts.help = true; break;
			default:
				console.error(`unknown arg: ${a}`);
				opts.help = true;
		}
	}
	return opts;
}

const HELP = `celeste-pcg — procedural multi-room chapter generator for Celeste mods

usage: celeste-pcg [options]

  --seed <str>          deterministic seed (default: celeste-pcg)
  --rooms <n>           number of rooms in the chapter (default: 6, max 64)
  --name <str>          chapter / map name, also the .bin filename (default: GenChapter)
  --music <event>       Celeste FMOD event, e.g. music_city (default: silent)
  --ambience <event>    ambience event (default: none)
  --difficulty <t>      chill | normal  — 'chill' omits hazards (default: normal)
  --room-width <n>      room width in tiles  (default: 44 — uniform, for clean transitions)
  --room-height <n>     room height in tiles (default: 23)
  --straight            horizontal chain only, no up/down transitions
  --biome <name(s)>     terrain style: ${BIOME_NAMES.join(' | ')} | random
                        comma-separated list picks a subset to mix (default: random — all of them)
  --out <dir>           output directory (default: ./out)
  --format <fmt>        bin | ogmo | maniamap | both | all  (default: both)
  --ogmo-template <p>   path to celeste.ogmo (default: ../celeste.ogmo next to this repo)
  --preview             print the chapter layout + an ASCII map of each room

output (format=both):
  <out>/<name>/everest.yaml
  <out>/<name>/Maps/<name>.bin          drop <out>/<name> into Celeste/Mods/, load with F6
  <out>/<name>/ogmo/celeste.ogmo        open in OgmoEditor3-CE to edit any room
  <out>/<name>/ogmo/<name>_<i>.json
`;

function layoutMap(chapter) {
	const cxs = chapter.rooms.map((r) => r.cx);
	const cys = chapter.rooms.map((r) => r.cy);
	const w = Math.max(...cxs) + 1;
	const h = Math.max(...cys) + 1;
	const grid = Array.from({ length: h }, () => Array(w).fill('  ·  '));
	chapter.rooms.forEach((r, i) => {
		grid[r.cy][r.cx] = String(i).padStart(3, ' ') + '  ';
	});
	const arrow = { R: '→', L: '←', U: '↑', D: '↓' };
	const t = chapter.transitions.map((x) => arrow[x.dir]).join(' ');
	return [
		'chapter layout (room index by grid cell):',
		...grid.map((row) => '  ' + row.join('')),
		`  path: ${t}`,
		'',
	].join('\n');
}

function asciiPreview(chapter) {
	const lines = [layoutMap(chapter)];
	for (const room of chapter.rooms) {
		const e = room._entrance ? room._entrance.edge : 'spawn';
		const x = room._exit ? room._exit.edge : 'goal';
		lines.push(`--- ${room.name}  [${room.biome}]  ${room.w}x${room.h} @ (${room.tx},${room.ty})  in:${e}  out:${x} ---`);
		const ents = new Map();
		for (const en of [...room.entities, ...room.triggers]) {
			const gx = Math.round((en.x - room.worldPxX()) / 8);
			const gy = Math.round((en.y - room.worldPxY()) / 8);
			const ch =
				en.name === 'player' ? 'P'
				: en.name === 'checkpoint' ? 'C'
				: en.name === 'refill' ? 'o'
				: en.name === 'strawberry' ? '*'
				: en.name === 'blackGem' ? 'H'
				: en.name === 'jumpThru' ? '='
				: en.name.startsWith('spikes') ? '^'
				: en.name.includes('completeArea') ? 'E'
				: '?';
			for (let k = 0; k < Math.max(1, Math.round((en.width || 8) / 8)); k++) {
				if (!ents.has(`${gx + k},${gy}`)) ents.set(`${gx + k},${gy}`, ch);
			}
		}
		for (let y = 0; y < room.h; y++) {
			let row = '';
			for (let xx = 0; xx < room.w; xx++) {
				const k = `${xx},${y}`;
				if (ents.has(k)) row += ents.get(k);
				else row += room.solids.solid(xx, y) ? '#' : ' ';
			}
			lines.push(row);
		}
		lines.push('');
	}
	return lines.join('\n');
}

function main() {
	const opts = parseArgs(process.argv.slice(2));
	if (opts.help) {
		process.stdout.write(HELP);
		process.exit(0);
	}

	const chapter = generateChapter({
		seed: opts.seed,
		rooms: opts.rooms,
		name: opts.name,
		music: opts.music,
		ambience: opts.ambience,
		difficulty: opts.difficulty,
		roomWidth: opts.roomWidth,
		roomHeight: opts.roomHeight,
		straight: opts.straight,
		biome: opts.biome,
	});

	const modDir = path.join(opts.out, opts.name);
	fs.mkdirSync(modDir, { recursive: true });

	const results = [];
	if (opts.format === 'bin' || opts.format === 'both') {
		const r = writeMod(chapter, modDir);
		results.push(`bin       ${path.relative(process.cwd(), r.binPath)}  (${r.bytes} bytes, map id "${r.mapId}")`);
	}
	if (opts.format === 'ogmo' || opts.format === 'both' || opts.format === 'all') {
		if (!fs.existsSync(opts.ogmoTemplate)) {
			console.error(`ogmo template not found: ${opts.ogmoTemplate}\n  pass --ogmo-template <path to celeste.ogmo>, or use --format bin`);
			process.exit(1);
		}
		const r = writeOgmoProject(chapter, modDir, opts.ogmoTemplate);
		results.push(`ogmo      ${path.relative(process.cwd(), r.dir)}  (${r.files.length} room files + celeste.ogmo)`);
	}
	if (opts.format === 'maniamap' || opts.format === 'all') {
		const r = writeManiaMap(chapter, modDir);
		results.push(`maniamap  ${path.relative(process.cwd(), r.dir)}  (${chapter.name.toLowerCase()}.graph.json + .templates.json)`);
	}

	if (opts.preview) process.stdout.write(asciiPreview(chapter) + '\n');

	process.stdout.write(
		`celeste-pcg: "${opts.name}"  seed=${opts.seed}  rooms=${chapter.rooms.length}  biome=${opts.biome}  entities=${chapter.nextId - 1}\n` +
			results.map((s) => '  ' + s).join('\n') +
			`\n\nnext: copy ${path.relative(process.cwd(), modDir)} into Celeste/Mods/, launch via Everest, press F6, pick "${opts.name}".\n`,
	);
}

function parseImportArgs(argv) {
	const opts = {
		bin: null,
		out: null,
		ogmoTemplate: path.join(__dirname, '..', '..', 'celeste.ogmo'),
		copyProject: true,
	};
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		const next = () => argv[++i];
		switch (a) {
			case '--bin': opts.bin = path.resolve(next()); break;
			case '--out': opts.out = path.resolve(next()); break;
			case '--ogmo-template': opts.ogmoTemplate = path.resolve(next()); break;
			case '--copy-project': opts.copyProject = true; break;
			case '--no-copy-project': opts.copyProject = false; break;
			case '-h':
			case '--help': opts.help = true; break;
			default:
				console.error(`unknown arg: ${a}`);
				opts.help = true;
		}
	}
	return opts;
}

const IMPORT_HELP = `celeste-pcg import-bin — open any Celeste .bin map for editing in OgmoEditor3-CE

usage: celeste-pcg import-bin --bin <path> [options]

  --bin <path>          Celeste .bin map to import (required) — vanilla or any mod's Maps/*.bin
  --out <dir>           ogmo directory to write into: celeste.ogmo (unless --no-copy-project) plus
                         one <levelname>.json per room  (default: ./out/<mapname>/ogmo)
  --ogmo-template <p>   celeste.ogmo project supplying entity/value definitions (default: ../celeste.ogmo)
  --no-copy-project     write only the level JSON files and leave any celeste.ogmo already in --out
                         alone — use this to import levels straight into a project you have open
`;

function mainImport(argv) {
	const opts = parseImportArgs(argv);
	if (opts.help || !opts.bin) {
		process.stdout.write(IMPORT_HELP);
		process.exit(opts.help ? 0 : 1);
	}
	if (!opts.out) {
		const base = path.basename(opts.bin, path.extname(opts.bin));
		opts.out = path.join(process.cwd(), 'out', base, 'ogmo');
	}
	if (!fs.existsSync(opts.ogmoTemplate)) {
		console.error(`ogmo template not found: ${opts.ogmoTemplate}\n  pass --ogmo-template <path to celeste.ogmo>`);
		process.exit(1);
	}

	const { importBin } = require('../src/import-bin');
	let r;
	try {
		r = importBin(opts.bin, opts.out, opts.ogmoTemplate, { copyProject: opts.copyProject });
	} catch (e) {
		console.error(`import-bin: ${e.message}`);
		process.exit(1);
	}

	const notes = [];
	if (r.unknownEntities.length) {
		notes.push(`  note: ${r.unknownEntities.length} entity type(s) not in the ogmo template (imported, but shown without a real origin): ${r.unknownEntities.join(', ')}`);
	}
	if (r.decalCount) {
		notes.push(`  note: ${r.decalCount} decal(s) skipped — this ogmo project has no decal layer to hold them`);
	}

	process.stdout.write(
		`celeste-pcg import-bin: "${path.basename(opts.bin)}"  package="${r.packageName}"  rooms=${r.roomCount}\n` +
			`  wrote  ${path.relative(process.cwd(), r.dir)}  (${r.files.length} room file(s)${opts.copyProject ? ' + celeste.ogmo' : ''})\n` +
			(notes.length ? notes.join('\n') + '\n' : '') +
			`\nopen ${path.relative(process.cwd(), path.join(r.dir, 'celeste.ogmo'))} in OgmoEditor3-CE to edit it.\n`,
	);
}

if (require.main === module) {
	if (process.argv[2] === 'import-bin') {
		mainImport(process.argv.slice(3));
	} else {
		main();
	}
}

module.exports = { main, parseArgs, HELP, layoutMap, asciiPreview, mainImport, parseImportArgs };
