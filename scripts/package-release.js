#!/usr/bin/env node
'use strict';

/*
	Build the mod zip for a GitHub/GameBanana release, matching the layout of
	every PCGHelper release so far (checked against the v1.3.5 release asset):
	a flat zip root containing exactly everest.yaml and Loenn/ -- no README,
	docs/, dotfiles, or dev-only scratch directories.

	Uses `git archive` scoped to those two paths at HEAD, so it only ever
	contains committed, tracked files -- untracked scratch (out/, a stray
	root-level celeste-pcg/ dev copy, node_modules) can never leak into a
	release by accident.

	Does not tag, push, or touch GitHub in any way -- it only writes a zip to
	dist/. Uploading it is a separate, deliberate step (e.g. `gh release
	create`), same as every past PCGHelper release.
*/

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');

function readEverestField(field) {
	const text = fs.readFileSync(path.join(ROOT, 'everest.yaml'), 'utf8');
	const m = text.match(new RegExp(`^-?\\s*${field}:\\s*(\\S+)`, 'm'));
	if (!m) throw new Error(`everest.yaml: missing "${field}:"`);
	return m[1];
}

function main() {
	const name = readEverestField('Name');
	const version = readEverestField('Version');

	const status = execFileSync('git', ['status', '--porcelain', '--', 'everest.yaml', 'Loenn'], {
		cwd: ROOT,
		encoding: 'utf8',
	});
	if (status.trim()) {
		console.error('working tree has uncommitted changes under everest.yaml / Loenn:');
		console.error(status);
		console.error('commit or stash them first -- this script packages HEAD, not the working tree.');
		process.exit(1);
	}

	const distDir = path.join(ROOT, 'dist');
	fs.mkdirSync(distDir, { recursive: true });
	const outPath = path.join(distDir, `${name}.zip`);

	execFileSync(
		'git',
		['archive', '--format=zip', `--output=${outPath}`, 'HEAD', '--', 'everest.yaml', 'Loenn'],
		{ cwd: ROOT },
	);

	const { size } = fs.statSync(outPath);
	console.log(`wrote ${path.relative(ROOT, outPath)}  (${(size / 1024).toFixed(1)} KiB)  version ${version}`);
	console.log(`next: gh release create v${version} ${path.relative(ROOT, outPath)} --title "..." --notes "..."`);
}

main();
