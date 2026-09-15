-- binary_packer.lua - Lua port of ../src/binary-packer.js. See rng.lua's
-- header comment for why this port exists: so Loenn scripts can encode/
-- decode Celeste's "CELESTE MAP" BinaryPacker format in-process, no
-- Node.js needed. Byte-for-byte cross-checked against the JS original's
-- actual output (see lua/test/binary_packer_test.lua), not just reasoned
-- about - this is the single most fragile file in the whole port (varint
-- strings + hand-rolled IEEE754 float32, since LuaJIT has no string.pack).

local bit = require("bit")

--[[ ----------------------------------------------------------- byte buffers

Element tree node shape used by this module (a plain Lua table):
  { name = string,
    attrs = { [key] = boolean | number | string },   -- ipairs-safe: use pairs()
    children = { node, node, ... },                  -- 1-indexed array
    innerText = string or nil }        -- large tile blobs

Value type tags (same as the JS original):
  0 bool(u8)  1 u8  2 i16  3 i32  4 f32  5 stringLookup(i16 index)  6 string(varint)  7 RLE
This writer never emits 7; the reader decodes it for completeness.
--]]

local ByteWriter = {}
ByteWriter.__index = ByteWriter

function ByteWriter.new()
	return setmetatable({ b = {} }, ByteWriter)
end

function ByteWriter:u8(n)
	self.b[#self.b + 1] = string.char(bit.band(n, 0xff))
end

function ByteWriter:u16(n)
	self:u8(n)
	self:u8(bit.rshift(n, 8))
end

function ByteWriter:i16(n)
	self:u16(bit.band(n, 0xffff))
end

function ByteWriter:i32(n)
	self:u8(n)
	self:u8(bit.rshift(n, 8))
	self:u8(bit.rshift(n, 16))
	self:u8(bit.rshift(n, 24))
end

-- IEEE754 single precision, little-endian. LuaJIT has no string.pack, so
-- this is hand-rolled via math.frexp (splits n = mantissa * 2^exponent,
-- 0.5 <= mantissa < 1) - see the module doc comment for why this is
-- cross-checked against Node's actual DataView output rather than trusted
-- on reasoning alone. Handles zero/normal finite numbers correctly (the
-- only cases this codebase's own data ever produces); NaN/Infinity and
-- subnormals are handled but not as rigorously verified.
function ByteWriter:f32(n)
	local bits
	if n ~= n then -- NaN
		bits = 0x7fc00000
	elseif n == math.huge then
		bits = 0x7f800000
	elseif n == -math.huge then
		bits = bit.bor(0x7f800000, bit.lshift(1, 31))
	else
		local sign = 0
		if n < 0 or (n == 0 and 1 / n < 0) then
			sign = 1
			n = -n
		end
		if n == 0 then
			bits = bit.lshift(sign, 31)
		else
			local mantissa, exponent = math.frexp(n) -- n = mantissa * 2^exponent
			exponent = exponent - 1
			mantissa = mantissa * 2 -- now 1 <= mantissa < 2
			local biasedExp = exponent + 127
			local mantissaBits
			if biasedExp <= 0 then
				-- subnormal: denormalize by shifting the mantissa down
				mantissa = mantissa * (2 ^ biasedExp)
				biasedExp = 0
				mantissaBits = math.floor(mantissa * 8388608 + 0.5)
			elseif biasedExp >= 255 then
				biasedExp = 255
				mantissaBits = 0
			else
				mantissaBits = math.floor((mantissa - 1) * 8388608 + 0.5)
				if mantissaBits >= 8388608 then
					mantissaBits = 0
					biasedExp = biasedExp + 1
				end
			end
			bits = bit.bor(bit.lshift(sign, 31), bit.lshift(bit.band(biasedExp, 0xff), 23), bit.band(mantissaBits, 0x7fffff))
		end
	end
	self:u8(bits)
	self:u8(bit.rshift(bits, 8))
	self:u8(bit.rshift(bits, 16))
	self:u8(bit.rshift(bits, 24))
end

function ByteWriter:raw(str)
	self.b[#self.b + 1] = str
end

function ByteWriter:toBuffer()
	return table.concat(self.b)
end

local ByteReader = {}
ByteReader.__index = ByteReader

function ByteReader.new(buf)
	return setmetatable({ buf = buf, p = 1 }, ByteReader)
end

function ByteReader:u8()
	local v = string.byte(self.buf, self.p)
	self.p = self.p + 1
	return v
end

function ByteReader:u16()
	local lo = self:u8()
	local hi = self:u8()
	return lo + bit.lshift(hi, 8)
end

function ByteReader:i16()
	local v = self:u16()
	if v >= 32768 then
		v = v - 65536
	end
	return v
end

function ByteReader:i32()
	local b1 = self:u8()
	local b2 = self:u8()
	local b3 = self:u8()
	local b4 = self:u8()
	-- bit.bor/bit.lshift already return a signed 32-bit Lua number (LuaJIT's
	-- bit library models exactly this), so this IS the signed i32 directly -
	-- no separate ">= 2^31 ? subtract 2^32" step needed, unlike u16/i16 above
	-- (which use plain arithmetic, not bit.*, so they stay unsigned until
	-- explicitly corrected).
	return bit.bor(b1, bit.lshift(b2, 8), bit.lshift(b3, 16), bit.lshift(b4, 24))
end

function ByteReader:f32()
	local b1 = self:u8()
	local b2 = self:u8()
	local b3 = self:u8()
	local b4 = self:u8()
	local bits = bit.bor(b1, bit.lshift(b2, 8), bit.lshift(b3, 16), bit.lshift(b4, 24))
	local sign = (bit.band(bit.rshift(bits, 31), 1) == 1) and -1 or 1
	local exponent = bit.band(bit.rshift(bits, 23), 0xff)
	local mantissaBits = bit.band(bits, 0x7fffff)
	if exponent == 0 then
		if mantissaBits == 0 then
			return sign * 0.0
		end
		return sign * (mantissaBits / 8388608) * (2 ^ -126)
	elseif exponent == 255 then
		if mantissaBits == 0 then
			return sign * math.huge
		end
		return 0 / 0 -- NaN
	end
	local mantissa = 1 + mantissaBits / 8388608
	return sign * mantissa * (2 ^ (exponent - 127))
end

function ByteReader:raw(n)
	local v = self.buf:sub(self.p, self.p + n - 1)
	self.p = self.p + n
	return v
end

-- base-128 varint length prefix, low groups first, high bit = "more"
local function writeVarString(w, s)
	local len = #s
	while len > 127 do
		w:u8(bit.bor(bit.band(len, 0x7f), 0x80))
		len = bit.rshift(len, 7)
	end
	w:u8(len)
	w:raw(s)
end

local function readVarString(r)
	local len = 0
	local shift = 0
	while true do
		local byte = r:u8()
		len = bit.bor(len, bit.lshift(bit.band(byte, 0x7f), shift))
		if bit.band(byte, 0x80) == 0 then
			break
		end
		shift = shift + 7
	end
	return r:raw(len)
end

--[[ --------------------------------------------------------------- encoding ]]

local HEADER = "CELESTE MAP"

-- smallest exact representation, matching mapcoder.lua's encodeNumber
local function encodeNumber(w, n)
	if n == math.floor(n) and n == n and n ~= math.huge and n ~= -math.huge then
		if n >= 0 and n <= 255 then
			w:u8(1)
			w:u8(n)
			return
		end
		if n >= -32768 and n <= 32767 then
			w:u8(2)
			w:i16(n)
			return
		end
		if n >= -2147483648 and n <= 2147483647 then
			w:u8(3)
			w:i32(n)
			return
		end
	end
	w:u8(4)
	w:f32(n)
end

local function encodeValue(w, v, index)
	local t = type(v)
	if t == "boolean" then
		w:u8(0)
		w:u8(v and 1 or 0)
		return
	end
	if t == "number" then
		encodeNumber(w, v)
		return
	end
	if t == "string" then
		if index[v] then
			w:u8(5)
			w:i16(index[v])
		else
			w:u8(6)
			writeVarString(w, v)
		end
		return
	end
	error("binary_packer: unencodable attribute value (" .. t .. ")")
end

-- sorted attr keys - NOT for matching JS's insertion order (never
-- guaranteed to matter - determinism only needs to hold within one
-- implementation, decode doesn't care what order attrs were written in),
-- but because Lua's pairs() iteration order over a table is not a
-- language-guaranteed stable function of insertion history the way JS
-- object key order is. Sorting makes "same seed -> byte-identical output"
-- (this engine's own core promise) hold by construction rather than by
-- incidentally-stable hashing behavior.
local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

local function collectStrings(node, index, lookup)
	if not index[node.name] then
		index[node.name] = #lookup
		lookup[#lookup + 1] = node.name
	end
	for _, k in ipairs(sortedKeys(node.attrs or {})) do
		if not index[k] then
			index[k] = #lookup
			lookup[#lookup + 1] = k
		end
		local v = node.attrs[k]
		if type(v) == "string" and not index[v] then
			index[v] = #lookup
			lookup[#lookup + 1] = v
		end
	end
	if node.innerText ~= nil and not index["innerText"] then
		index["innerText"] = #lookup
		lookup[#lookup + 1] = "innerText"
	end
	for _, c in ipairs(node.children or {}) do
		collectStrings(c, index, lookup)
	end
end

-- attrs order matters for byte-identical output across runs (Lua's pairs()
-- iteration order is not guaranteed stable the way JS's Object.entries is
-- insertion-ordered) - every caller in this engine passes attrs built via
-- an explicit, fixed key list for exactly this reason; see model.lua /
-- emit_bin.lua's entityElement.
local function encodeElement(w, node, index)
	w:u16(index[node.name])

	local keys = sortedKeys(node.attrs or {})
	local hasInner = node.innerText ~= nil
	w:u8(#keys + (hasInner and 1 or 0))

	for _, k in ipairs(keys) do
		w:u16(index[k])
		encodeValue(w, node.attrs[k], index)
	end
	if hasInner then
		w:u16(index["innerText"])
		w:u8(6) -- literal string - never a lookup ref, matches Loenn's carve-out
		writeVarString(w, node.innerText)
	end

	local kids = node.children or {}
	w:u16(#kids)
	for _, c in ipairs(kids) do
		encodeElement(w, c, index)
	end
end

local function encodeMap(root, packageName)
	local lookup = {}
	local index = {}
	collectStrings(root, index, lookup)

	local w = ByteWriter.new()
	writeVarString(w, HEADER)
	writeVarString(w, packageName or "")
	w:u16(#lookup)
	for _, s in ipairs(lookup) do
		writeVarString(w, s)
	end

	encodeElement(w, root, index)

	return w:toBuffer()
end

--[[ --------------------------------------------------------------- decoding ]]

local function decodeValue(r, lookup)
	local t = r:u8()
	if t == 0 then
		return r:u8() ~= 0
	elseif t == 1 then
		return r:u8()
	elseif t == 2 then
		return r:i16()
	elseif t == 3 then
		return r:i32()
	elseif t == 4 then
		return r:f32()
	elseif t == 5 then
		return lookup[r:i16() + 1] -- lookup is 1-indexed Lua array; stored index is 0-based
	elseif t == 6 then
		return readVarString(r)
	elseif t == 7 then
		local byteCount = r:i16()
		local out = {}
		local i = 0
		while i < byteCount do
			local count = r:u8()
			local ch = string.char(r:u8())
			out[#out + 1] = ch:rep(count)
			i = i + 2
		end
		return table.concat(out)
	else
		error("binary_packer: unknown value type " .. tostring(t))
	end
end

local function decodeElement(r, lookup)
	local name = lookup[r:u16() + 1]
	local attrCount = r:u8()
	local attrs = {}
	for _ = 1, attrCount do
		local key = lookup[r:u16() + 1]
		attrs[key] = decodeValue(r, lookup)
	end
	local childCount = r:u16()
	local children = {}
	for i = 1, childCount do
		children[i] = decodeElement(r, lookup)
	end

	local innerText = nil
	if attrs["innerText"] ~= nil then
		innerText = attrs["innerText"]
		attrs["innerText"] = nil
	end
	return { name = name, attrs = attrs, children = children, innerText = innerText }
end

local function decodeMap(buffer)
	local r = ByteReader.new(buffer)
	local header = readVarString(r)
	local pkg = readVarString(r)
	local n = r:u16()
	local lookup = {}
	for i = 1, n do
		lookup[i] = readVarString(r)
	end
	local root = decodeElement(r, lookup)
	return { header = header, package = pkg, lookup = lookup, root = root }
end

return {
	encodeMap = encodeMap,
	decodeMap = decodeMap,
	HEADER = HEADER,
	ByteWriter = ByteWriter,
	ByteReader = ByteReader,
	_writeVarString = writeVarString,
	_readVarString = readVarString,
}
