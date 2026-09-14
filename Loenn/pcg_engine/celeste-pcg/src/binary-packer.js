'use strict';

/*
	Celeste "CELESTE MAP" BinaryPacker reader/writer.

	Format ported from CelestialCartographers/Loenn's src/mapcoder.lua (MIT) and
	cross-checked against OgmoEditor3-CE's src/io/BinaryExport.hx in this same repo
	tree — same varint strings, same shared string lookup table, same value-type
	tags, same little-endian ints.

	Element tree node shape used by this module:
	  { name: string,
	    attrs: { [key]: boolean | number | string },
	    children: node[],
	    innerText?: string }        // large tile blobs — key interned, value never

	Value type tags:
	  0 bool(u8)  1 u8  2 i16  3 i32  4 f32  5 stringLookup(i16 index)  6 string(varint)  7 RLE
	This writer never emits 7; the reader decodes it for completeness.
*/

/* ----------------------------------------------------------- byte buffers */

class ByteWriter {
	constructor() {
		this.b = [];
	}
	u8(n) {
		this.b.push(n & 0xff);
	}
	u16(n) {
		this.b.push(n & 0xff, (n >>> 8) & 0xff);
	}
	i16(n) {
		this.u16(n & 0xffff);
	}
	i32(n) {
		this.b.push(n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff);
	}
	f32(n) {
		const d = new DataView(new ArrayBuffer(4));
		d.setFloat32(0, n, true);
		for (let i = 0; i < 4; i++) this.b.push(d.getUint8(i));
	}
	raw(buf) {
		for (let i = 0; i < buf.length; i++) this.b.push(buf[i]);
	}
	toBuffer() {
		return Buffer.from(this.b);
	}
}

class ByteReader {
	constructor(buf) {
		this.buf = buf;
		this.p = 0;
	}
	u8() {
		return this.buf[this.p++];
	}
	u16() {
		const v = this.buf.readUInt16LE(this.p);
		this.p += 2;
		return v;
	}
	i16() {
		const v = this.buf.readInt16LE(this.p);
		this.p += 2;
		return v;
	}
	i32() {
		const v = this.buf.readInt32LE(this.p);
		this.p += 4;
		return v;
	}
	f32() {
		const v = this.buf.readFloatLE(this.p);
		this.p += 4;
		return v;
	}
	raw(n) {
		const v = this.buf.subarray(this.p, this.p + n);
		this.p += n;
		return v;
	}
}

/* base-128 varint length prefix, low groups first, high bit = "more" */
function writeVarString(w, s) {
	const bytes = Buffer.from(s, 'utf8');
	let len = bytes.length;
	while (len > 127) {
		w.u8((len & 0x7f) | 0x80);
		len >>>= 7;
	}
	w.u8(len);
	w.raw(bytes);
}

function readVarString(r) {
	let len = 0;
	let shift = 0;
	for (;;) {
		const byte = r.u8();
		len |= (byte & 0x7f) << shift;
		if ((byte & 0x80) === 0) break;
		shift += 7;
	}
	return Buffer.from(r.raw(len)).toString('utf8');
}

/* --------------------------------------------------------------- encoding */

const HEADER = 'CELESTE MAP';

function encodeMap(root, packageName) {
	const lookup = [];
	const index = new Map();
	const intern = (s) => {
		if (!index.has(s)) {
			index.set(s, lookup.length);
			lookup.push(s);
		}
	};

	(function collect(node) {
		intern(node.name);
		for (const [k, v] of Object.entries(node.attrs || {})) {
			intern(k);
			if (typeof v === 'string') intern(v);
		}
		if (node.innerText != null) intern('innerText');
		for (const c of node.children || []) collect(c);
	})(root);

	const w = new ByteWriter();
	writeVarString(w, HEADER);
	writeVarString(w, packageName || '');
	w.u16(lookup.length);
	for (const s of lookup) writeVarString(w, s);

	(function encodeElement(node) {
		w.u16(index.get(node.name));

		const entries = Object.entries(node.attrs || {});
		const hasInner = node.innerText != null;
		w.u8(entries.length + (hasInner ? 1 : 0));

		for (const [k, v] of entries) {
			w.u16(index.get(k));
			encodeValue(w, v, index);
		}
		if (hasInner) {
			w.u16(index.get('innerText'));
			w.u8(6); // literal string — never a lookup ref, matches Loenn's carve-out
			writeVarString(w, node.innerText);
		}

		const kids = node.children || [];
		w.u16(kids.length);
		for (const c of kids) encodeElement(c);
	})(root);

	return w.toBuffer();
}

function encodeValue(w, v, index) {
	if (typeof v === 'boolean') {
		w.u8(0);
		w.u8(v ? 1 : 0);
		return;
	}
	if (typeof v === 'number') {
		encodeNumber(w, v);
		return;
	}
	if (typeof v === 'string') {
		if (index.has(v)) {
			w.u8(5);
			w.i16(index.get(v));
		} else {
			w.u8(6);
			writeVarString(w, v);
		}
		return;
	}
	throw new Error(`binary-packer: unencodable attribute value ${JSON.stringify(v)} (${typeof v})`);
}

/* smallest exact representation, matching mapcoder.lua's encodeNumber */
function encodeNumber(w, n) {
	if (Number.isInteger(n)) {
		if (n >= 0 && n <= 255) {
			w.u8(1);
			w.u8(n);
			return;
		}
		if (n >= -32768 && n <= 32767) {
			w.u8(2);
			w.i16(n);
			return;
		}
		if (n >= -2147483648 && n <= 2147483647) {
			w.u8(3);
			w.i32(n);
			return;
		}
	}
	w.u8(4);
	w.f32(n);
}

/* --------------------------------------------------------------- decoding */

function decodeMap(buffer) {
	const r = new ByteReader(buffer);
	const header = readVarString(r);
	const pkg = readVarString(r);
	const n = r.u16();
	const lookup = [];
	for (let i = 0; i < n; i++) lookup.push(readVarString(r));
	const root = decodeElement(r, lookup);
	return { header, package: pkg, lookup, root };
}

function decodeElement(r, lookup) {
	const name = lookup[r.u16()];
	const attrCount = r.u8();
	const attrs = {};
	for (let i = 0; i < attrCount; i++) {
		const key = lookup[r.u16()];
		attrs[key] = decodeValue(r, lookup);
	}
	const childCount = r.u16();
	const children = [];
	for (let i = 0; i < childCount; i++) children.push(decodeElement(r, lookup));

	let innerText;
	if (Object.prototype.hasOwnProperty.call(attrs, 'innerText')) {
		innerText = attrs.innerText;
		delete attrs.innerText;
	}
	return { name, attrs, children, innerText };
}

function decodeValue(r, lookup) {
	const t = r.u8();
	switch (t) {
		case 0:
			return r.u8() !== 0;
		case 1:
			return r.u8();
		case 2:
			return r.i16();
		case 3:
			return r.i32();
		case 4:
			return r.f32();
		case 5:
			return lookup[r.i16()];
		case 6:
			return readVarString(r);
		case 7: {
			const byteCount = r.i16();
			let out = '';
			for (let i = 0; i < byteCount; i += 2) {
				const count = r.u8();
				const ch = String.fromCharCode(r.u8());
				out += ch.repeat(count);
			}
			return out;
		}
		default:
			throw new Error(`binary-packer: unknown value type ${t}`);
	}
}

module.exports = { encodeMap, decodeMap, HEADER };
