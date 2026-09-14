#!/usr/bin/env node
'use strict';

/*
	Pre-release content check for PCGHelper. Run before packaging a release
	(see scripts/package-release.js) or in CI on every push/PR.

	Checks, roughly cheapest-and-most-likely-to-catch-a-typo first:
	  1. everest.yaml has the fields Everest actually needs to load the mod
	  2. every Loenn/scripts/*.lua looks like a real Loenn script (returns a
	     table with the fields Loenn's script menu reads) -- a regex check,
	     not a real Lua parser, but enough to catch a stray typo or a script
	     that forgot to `return script`
	  3. the vendored celeste-pcg Node engine's own test suite passes
	  4. end-to-end smoke test: generate a small chapter, then run it back
	     through `celeste-pcg analyze` and make sure it comes back clean --
	     this is what would actually break for a player if steps 1-3 all
	     passed but the two tools drifted apart

	Exits non-zero (and prints every failure, not just the first) if anything
	is wrong.
*/

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const ENGINE_DIR = path.join(ROOT, 'Loenn', 'pcg_engine', 'celeste-pcg');
const ENGINE_BIN = path.join(ENGINE_DIR, 'bin', 'celeste-pcg.js');

const failures = [];
const fail = (msg) => failures.push(msg);
const ok = (msg) => console.log(`  ok  ${msg}`);

function checkEverestYaml() {
	console.log('everest.yaml');
	const p = path.join(ROOT, 'everest.yaml');
	if (!fs.existsSync(p)) {
		fail('everest.yaml: file not found');
		return;
	}
	const text = fs.readFileSync(p, 'utf8');

	const name = text.match(/^-?\s*Name:\s*(\S+)/m);
	const version = text.match(/^\s*Version:\s*(\S+)/m);
	const hasEverestDep = /Dependencies:[\s\S]*?-\s*Name:\s*Everest/m.test(text);

	if (!name) fail('everest.yaml: missing "Name:"');
	else ok(`Name: ${name[1]}`);

	if (!version) fail('everest.yaml: missing "Version:"');
	else if (!/^\d+\.\d+\.\d+$/.test(version[1])) fail(`everest.yaml: Version "${version[1]}" is not X.Y.Z`);
	else ok(`Version: ${version[1]}`);

	if (!hasEverestDep) fail('everest.yaml: Dependencies must list Everest');
	else ok('depends on Everest');
}

function checkLoennScripts() {
	console.log('Loenn/scripts/*.lua');
	const dir = path.join(ROOT, 'Loenn', 'scripts');
	const files = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith('.lua')) : [];
	if (!files.length) {
		fail('Loenn/scripts: no .lua files found');
		return;
	}
	for (const f of files) {
		const text = fs.readFileSync(path.join(dir, f), 'utf8');
		const issues = [];
		if (!/\breturn\s+script\s*$/m.test(text.trimEnd())) issues.push('does not end with "return script"');
		if (!/\bname\s*=\s*["']/.test(text)) issues.push('script table has no "name" field');
		if (!/\bdisplayName\s*=\s*["']/.test(text)) issues.push('script table has no "displayName" field');
		if (issues.length) fail(`${f}: ${issues.join('; ')}`);
		else ok(f);
	}
}

function checkEngineTests() {
	console.log('celeste-pcg test suite');
	try {
		execFileSync(process.execPath, ['--test'], { cwd: ENGINE_DIR, stdio: 'pipe' });
		ok('npm test passed');
	} catch (e) {
		fail(`celeste-pcg tests failed:\n${e.stdout || e.message}`);
	}
}

function checkSmokeGenerateAnalyze() {
	console.log('generate -> analyze smoke test');
	const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pcghelper-validate-'));
	try {
		execFileSync(process.execPath, [
			ENGINE_BIN,
			'--seed', 'pcghelper-validate',
			'--rooms', '6',
			'--name', 'ValidateSmoke',
			'--format', 'bin',
			'--out', tmpDir,
		]);
		const binPath = path.join(tmpDir, 'ValidateSmoke', 'Maps', 'ValidateSmoke.bin');
		const { analyzeBin } = require(path.join(ENGINE_DIR, 'src', 'analyze'));
		const r = analyzeBin(binPath);
		const hardIssues = r.rooms.reduce((n, room) => n + room.warnings.length, 0);
		if (hardIssues > 0) {
			fail(`generate -> analyze smoke test: ${hardIssues} playability issue(s) in a freshly generated chapter`);
		} else {
			ok(`generated + analyzed a ${r.roomCount}-room chapter cleanly`);
		}
	} catch (e) {
		fail(`generate -> analyze smoke test threw: ${e.message}`);
	} finally {
		fs.rmSync(tmpDir, { recursive: true, force: true });
	}
}

checkEverestYaml();
checkLoennScripts();
checkEngineTests();
checkSmokeGenerateAnalyze();

console.log('');
if (failures.length) {
	console.log(`${failures.length} check(s) failed:`);
	for (const f of failures) console.log(`  ! ${f}`);
	process.exit(1);
}
console.log('all checks passed');
