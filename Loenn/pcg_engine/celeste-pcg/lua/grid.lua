-- grid.lua - Lua port of ../src/grid.js. See rng.lua's header comment for
-- why this port exists. A dense 2D grid of single-character tile ids,
-- row-major, backed by a flat 1-indexed Lua array (matching Grid.cells'
-- flat array in the JS original, just 1-indexed instead of 0-indexed).

local AIR = "0"

local Grid = {}
Grid.__index = Grid

function Grid.new(w, h, fill)
	fill = fill or AIR
	local self = setmetatable({}, Grid)
	self.w = w
	self.h = h
	self.cells = {}
	for i = 1, w * h do
		self.cells[i] = fill
	end
	return self
end

function Grid:inside(x, y)
	return x >= 0 and y >= 0 and x < self.w and y < self.h
end

-- x, y are 0-indexed (matching every caller across this whole engine,
-- ported as-is from JS) - only the underlying flat array is 1-indexed.
local function flatIndex(self, x, y)
	return y * self.w + x + 1
end

function Grid:get(x, y)
	if not self:inside(x, y) then
		return AIR
	end
	return self.cells[flatIndex(self, x, y)]
end

function Grid:set(x, y, v)
	if not self:inside(x, y) then
		return
	end
	self.cells[flatIndex(self, x, y)] = v
end

function Grid:solid(x, y)
	return self:get(x, y) ~= AIR
end

function Grid:fillRect(x0, y0, x1, y1, v)
	for y = y0, y1 do
		for x = x0, x1 do
			self:set(x, y, v)
		end
	end
end

-- flat row-major array of 1-char strings - a plain copy, exactly Ogmo
-- GridLayer arrayMode ONE. Returns a new 1-indexed Lua array.
function Grid:toFlatArray()
	local out = {}
	for i = 1, #self.cells do
		out[i] = self.cells[i]
	end
	return out
end

-- newline-joined rows - exactly Celeste's <solids innerText="..."> blob.
function Grid:toInnerText()
	local rows = {}
	for y = 0, self.h - 1 do
		local rowChars = {}
		for x = 0, self.w - 1 do
			rowChars[x + 1] = self:get(x, y)
		end
		rows[y + 1] = table.concat(rowChars)
	end
	return table.concat(rows, "\n")
end

return { Grid = Grid, AIR = AIR }
