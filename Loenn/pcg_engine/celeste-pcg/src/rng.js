'use strict';

/*
	Deterministic, seedable PRNG. Same seed -> byte-identical chapter, on any machine.
	mulberry32: tiny, fast, good enough distribution for level layout. Not cryptographic.
*/

function hashStringToSeed(str) {
	// xfnv1a — turns a string seed ("my-chapter") into a 32-bit integer.
	let h = 2166136261 >>> 0;
	for (let i = 0; i < str.length; i++) {
		h ^= str.charCodeAt(i);
		h = Math.imul(h, 16777619);
	}
	return h >>> 0;
}

class Rng {
	constructor(seed) {
		if (typeof seed === 'string') seed = hashStringToSeed(seed);
		this.state = (seed >>> 0) || 1;
	}

	/** float in [0, 1) */
	next() {
		let t = (this.state += 0x6d2b79f5);
		t = Math.imul(t ^ (t >>> 15), t | 1);
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	}

	/** integer in [min, max] inclusive */
	int(min, max) {
		return min + Math.floor(this.next() * (max - min + 1));
	}

	/** true with probability p */
	chance(p) {
		return this.next() < p;
	}

	/** random element of an array */
	pick(arr) {
		return arr[this.int(0, arr.length - 1)];
	}

	/** in-place Fisher-Yates */
	shuffle(arr) {
		for (let i = arr.length - 1; i > 0; i--) {
			const j = this.int(0, i);
			[arr[i], arr[j]] = [arr[j], arr[i]];
		}
		return arr;
	}
}

module.exports = { Rng, hashStringToSeed };
