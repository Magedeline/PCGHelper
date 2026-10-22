-- rng.lua
-- Lua port of ../src/rng.js. Deterministic, seedable PRNG (mulberry32) --
-- same seed produces the exact same number stream as the JS original, byte
-- for byte, verified against it directly (see lua/test/rng_test.lua).
--
-- Ported rather than shared with the JS file because this whole lua/
-- directory exists specifically so Loenn scripts can run this engine
-- in-process, with no Node.js/external process dependency at all.

local bit = require("bit")

local Rng = {}
Rng.__index = Rng

-- Math.imul: 32-bit integer multiply with 32-bit wraparound, standard
-- 16-bit-split polyfill (same algorithm every JS Math.imul polyfill uses).
local function imul(a, b)
	local aHi = bit.band(bit.rshift(a, 16), 0xffff)
	local aLo = bit.band(a, 0xffff)
	local bHi = bit.band(bit.rshift(b, 16), 0xffff)
	local bLo = bit.band(b, 0xffff)
	local low = aLo * bLo
	local mid = bit.lshift(aHi * bLo + aLo * bHi, 16)
	return bit.tobit(low + mid)
end

-- JS's `x >>> 0`: reinterpret a 32-bit bit pattern as unsigned (0..2^32-1).
-- bit.* functions return LuaJIT's signed int32 range (-2^31..2^31-1); this
-- converts to the unsigned numeric value the original code's final
-- `/ 4294967296` division needs (dividing a negative number would be wrong).
local function toUnsigned32(n)
	if n < 0 then
		return n + 4294967296
	end
	return n
end

-- xfnv1a: turns a string seed into a 32-bit integer, same as rng.js.
local function hashStringToSeed(str)
	local h = bit.tobit(2166136261)
	for i = 1, #str do
		h = bit.bxor(h, string.byte(str, i))
		h = imul(h, 16777619)
	end
	return toUnsigned32(h)
end

function Rng.new(seed)
	local self = setmetatable({}, Rng)
	if type(seed) == "string" then
		seed = hashStringToSeed(seed)
	end
	seed = toUnsigned32(bit.tobit(seed))
	-- JS's `(seed >>> 0) || 1`: falls back to 1 only when the unsigned seed
	-- is exactly 0 - written explicitly here since 0 is truthy in Lua
	-- (unlike JS), so a direct `or` translation would be wrong.
	if seed == 0 then
		seed = 1
	end
	self.state = seed
	return self
end

-- float in [0, 1). Deliberately does NOT truncate self.state back to 32
-- bits between calls, matching rng.js exactly: `this.state += ...` there
-- is a plain accumulating add, only the LOCAL working value gets bitwise-
-- truncated each call. Every bit.* call below auto-normalizes whatever Lua
-- number it's given to a 32-bit int first, so this stays exact.
function Rng:next()
	self.state = self.state + 0x6d2b79f5
	local t = self.state
	t = imul(bit.bxor(t, bit.rshift(t, 15)), bit.bor(t, 1))
	t = bit.bxor(t, t + imul(bit.bxor(t, bit.rshift(t, 7)), bit.bor(t, 61)))
	local result = toUnsigned32(bit.bxor(t, bit.rshift(t, 14)))
	return result / 4294967296
end

-- integer in [min, max] inclusive
function Rng:int(min, max)
	return min + math.floor(self:next() * (max - min + 1))
end

-- true with probability p
function Rng:chance(p)
	return self:next() < p
end

-- random element of a 1-indexed Lua array
function Rng:pick(arr)
	return arr[self:int(1, #arr)]
end

-- in-place Fisher-Yates over a 1-indexed Lua array
function Rng:shuffle(arr)
	for i = #arr, 2, -1 do
		local j = self:int(1, i)
		arr[i], arr[j] = arr[j], arr[i]
	end
	return arr
end

return { Rng = Rng, hashStringToSeed = hashStringToSeed, _imul = imul, _toUnsigned32 = toUnsigned32 }
