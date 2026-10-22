-- rng.lua - deterministic, seedable random source for the seleCte port.
--
-- The Python original draws from numpy's global RNG (and `random`), so its
-- output is only reproducible within one numpy version and never across
-- languages. This port makes "same seed, same level" an actual guarantee:
-- mulberry32 on LuaJIT (Loenn's runtime), with a pure-arithmetic LCG fallback
-- for a Lua without the `bit` library, so the module loads anywhere.
--
-- Draw conventions follow the numpy calls they replace:
--   rng:random()          float in [0, 1)                 np.random.rand()
--   rng:range(lo, hi)     integer in [lo, hi), nil if hi <= lo   np.random.randint(lo, hi)
--   rng:int(lo, hi)       integer in [lo, hi] inclusive    random.randint(a, b)
--   rng:choice(list)      uniform element                   np.random.choice(a)
--   rng:weighted(pairs)   element of a flat {sym, p, sym, p, ...} list, by p
--   rng:shuffle(list)     in-place Fisher-Yates             random.shuffle

local hasBit, bit = pcall(require, "bit")
if not hasBit or type(bit) ~= "table" then
	bit = nil
end

local Rng = {}
Rng.__index = Rng

local TWO32 = 4294967296

local function hashString(str)
	-- FNV-1a in 32-bit arithmetic when `bit` is available, else a 31-multiplier
	-- hash that stays exact in doubles (31 * 2^32 < 2^53).
	if bit then
		local h = bit.tobit(2166136261)
		for i = 1, #str do
			h = bit.bxor(h, string.byte(str, i))
			-- Math.imul-style 32-bit multiply via 16-bit halves.
			local aHi = bit.band(bit.rshift(h, 16), 0xffff)
			local aLo = bit.band(h, 0xffff)
			local b = 16777619
			local bHi = bit.band(bit.rshift(b, 16), 0xffff)
			local bLo = bit.band(b, 0xffff)
			h = bit.tobit(aLo * bLo + bit.lshift(aHi * bLo + aLo * bHi, 16))
		end
		if h < 0 then
			h = h + TWO32
		end
		return h
	end
	local h = 5381
	for i = 1, #str do
		h = (h * 31 + string.byte(str, i)) % TWO32
	end
	return h
end

local function imul(a, b)
	local aHi = bit.band(bit.rshift(a, 16), 0xffff)
	local aLo = bit.band(a, 0xffff)
	local bHi = bit.band(bit.rshift(b, 16), 0xffff)
	local bLo = bit.band(b, 0xffff)
	return bit.tobit(aLo * bLo + bit.lshift(aHi * bLo + aLo * bHi, 16))
end

-- seed: a string, a number, or nil/"" for a time-based seed. The seed that
-- was actually used is kept in `rng.seed` so a run can be reported/replayed.
function Rng.new(seed)
	local self = setmetatable({}, Rng)
	if seed == nil or seed == "" then
		seed = tostring(os.time()) .. "-" .. tostring(os.clock()):gsub("%.", "")
	end
	self.seed = seed
	local numeric
	if type(seed) == "number" then
		numeric = math.floor(math.abs(seed)) % TWO32
	else
		numeric = hashString(tostring(seed))
	end
	if numeric == 0 then
		numeric = 1
	end
	self.state = numeric
	return self
end

if bit then
	function Rng:random()
		self.state = (self.state + 0x6d2b79f5) % TWO32
		local t = bit.tobit(self.state)
		t = imul(bit.bxor(t, bit.rshift(t, 15)), bit.bor(t, 1))
		t = bit.bxor(t, t + imul(bit.bxor(t, bit.rshift(t, 7)), bit.bor(t, 61)))
		local r = bit.bxor(t, bit.rshift(t, 14))
		if r < 0 then
			r = r + TWO32
		end
		return r / TWO32
	end
else
	function Rng:random()
		-- Two LCG steps, top 16 bits of each, for 32 bits of resolution.
		self.state = (self.state * 1664525 + 1013904223) % TWO32
		local hi = math.floor(self.state / 65536)
		self.state = (self.state * 1664525 + 1013904223) % TWO32
		local lo = math.floor(self.state / 65536)
		return (hi * 65536 + lo) / TWO32
	end
end

function Rng:range(lo, hi)
	if hi <= lo then
		return nil
	end
	local r = lo + math.floor(self:random() * (hi - lo))
	if r >= hi then
		r = hi - 1
	end
	return r
end

function Rng:int(lo, hi)
	return self:range(lo, hi + 1)
end

function Rng:choice(list)
	return list[self:range(1, #list + 1)]
end

-- `dist` is a flat { symbol, probability, symbol, probability, ... } list
-- (the shape dpe_data.lua stores). Probabilities are renormalised on the fly
-- so a dict whose entries do not sum to exactly 1 still samples correctly.
function Rng:weighted(dist)
	local total = 0
	for i = 2, #dist, 2 do
		total = total + dist[i]
	end
	if total <= 0 then
		return nil
	end
	local r = self:random() * total
	local acc = 0
	local last
	for i = 1, #dist - 1, 2 do
		local p = dist[i + 1]
		if p > 0 then
			last = dist[i]
			acc = acc + p
			if r < acc then
				return dist[i]
			end
		end
	end
	return last
end

function Rng:shuffle(list)
	for i = #list, 2, -1 do
		local j = self:range(1, i + 1)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

return { Rng = Rng, hashString = hashString }
