-- recombine.lua - existing rooms -> the single-grid training corpus.
--
-- Lua port of the offline head of https://github.com/robilouis/seleCte (MIT):
--   * data_loader/data_loader.jl              decode a .bin into per-room
--                                             tiles + entities (via Maple)
--   * pcg/preprocessing/recombine_fg_entities  collapse every solid tileset to
--                                             "1" and stamp each known entity's
--                                             symbol over the tiles it covers
--   * pcg/preprocessing/collect_bg_rooms       validate a background layer
--
-- Input rooms are plain tables, so the same code serves rooms read out of
-- Loenn's open map and rooms decoded from a .bin on disk:
--   { name, fgRows = {"0001...", ...}, bgRows = {...} or nil,
--     entities = { { name = "spikesUp", x = px, y = px, width = px?, height = px?, red = bool? }, ... } }
--
-- The result feeds mdmc.estimate, which is what dpe_generation.py does with
-- the csv corpus - so retraining no longer needs Julia or Python at all.

local function req(name)
	local ok, mods = pcall(require, "mods")
	if ok and type(mods) == "table" and mods.requireFromPlugin then
		local m = mods.requireFromPlugin("library.selecte." .. name)
		if not m then
			error("seleCte: could not load library.selecte." .. name .. " (see the Loenn log for the Lua error)")
		end
		return m
	end
	return require("library.selecte." .. name)
end

local alphabet = req("alphabet")
local mdmc = req("mdmc")

local M = {}

M.TILE_SIZE = 8

-- A point entity's box is centred on (x, y) rather than starting there, so
-- it covers the tile before the one the coordinate lands in (every spinner
-- in the game data has originX == originY == 8, exactly this shift).
M.POINT_ENTITY_SHIFT = 1

-- =========================================================================
-- Foreground
-- =========================================================================

-- collapse_fg_tiles: every solid tileset glyph -> "1"; unknown glyphs are
-- passed through so they can be reported.
function M.collapseFgRows(fgRows)
	local data = {}
	for r, line in ipairs(fgRows) do
		local row = {}
		for c = 1, #line do
			local v = line:sub(c, c)
			if alphabet.VALID_FG_SET[v] then
				row[c] = alphabet.SOLID
			elseif v == " " or v == "" then
				row[c] = alphabet.VOID
			else
				row[c] = v
			end
		end
		data[r] = row
	end
	return data
end

-- invalid_symbol_counts over a collapsed grid: {symbol = count} for cells
-- outside `valid` (a set).
function M.invalidSymbolCounts(data, valid)
	local counts = {}
	for r = 1, #data do
		for c = 1, #data[r] do
			local v = data[r][c]
			if not valid[v] then
				counts[v] = (counts[v] or 0) + 1
			end
		end
	end
	return counts
end

-- _resolve_entity_name: boosters split on their `red` flag.
local function resolveName(e)
	if e.name ~= "booster" then
		return e.name
	end
	if e.red == nil then
		return nil
	end
	return e.red and "redBooster" or "greenBooster"
end

-- filter_entities: the entities the vocabulary has a symbol for, in order.
function M.filterEntities(entities, entitySymbols)
	entitySymbols = entitySymbols or alphabet.ENTITY_SYMBOLS
	local out = {}
	for _, e in ipairs(entities or {}) do
		local name = resolveName(e)
		local symbol = name and entitySymbols[name]
		if symbol and type(e.x) == "number" and type(e.y) == "number" then
			out[#out + 1] = {
				name = name, symbol = symbol, x = e.x, y = e.y,
				width = type(e.width) == "number" and e.width or nil,
				height = type(e.height) == "number" and e.height or nil,
			}
		end
	end
	return out
end

-- _tile_span: one axis of a pixel box -> a 1-based inclusive tile span
-- clamped to [1, limit], or nil when nothing is covered. Asymmetric on
-- purpose: a point entity shifted below tile 1 still covers tile 1.
local function tileSpan(originPx, sizePx, limit)
	local start = math.floor(originPx / M.TILE_SIZE)
	local stop
	if sizePx == nil then
		start = math.max(start - M.POINT_ENTITY_SHIFT, 0)
		stop = start + 1
	else
		stop = start + math.floor(sizePx / M.TILE_SIZE)
	end
	local low = math.max(start, 0)
	local high = math.min(stop, limit)
	if high <= low then
		return nil
	end
	return low + 1, high
end
M.tileSpan = tileSpan

-- stamp_entity: writes the symbol over every tile the entity covers.
-- Returns false when the entity lies outside the room.
function M.stampEntity(data, e)
	local h = #data
	local w = h > 0 and #data[1] or 0
	local c0, c1 = tileSpan(e.x, e.width, w)
	local r0, r1 = tileSpan(e.y, e.height, h)
	if not c0 or not r0 then
		return false
	end
	for r = r0, r1 do
		for c = c0, c1 do
			data[r][c] = e.symbol
		end
	end
	return true
end

-- recombine_room: a room's foreground rows + entities -> one alphabet grid.
-- Returns the grid and a report { kept, outside, invalid = {sym = n} }, or
-- nil plus the report when the tiles hold glyphs outside the vocabulary.
function M.recombineRoom(room, entitySymbols)
	local data = M.collapseFgRows(room.fgRows or {})
	local invalid = M.invalidSymbolCounts(data, { [alphabet.VOID] = true, [alphabet.SOLID] = true })
	local entities = M.filterEntities(room.entities, entitySymbols)
	local report = { kept = #entities, outside = 0, invalid = invalid }
	if next(invalid) then
		return nil, report
	end
	for _, e in ipairs(entities) do
		if not M.stampEntity(data, e) then
			report.outside = report.outside + 1
		end
	end
	return data, report
end

-- =========================================================================
-- Background (collect_bg_rooms: validate only, nothing collapsed)
-- =========================================================================

function M.collectBgRoom(room)
	if not room.bgRows then
		return nil, { invalid = {} }
	end
	local data = mdmc.rowsToRoom(room.bgRows)
	for r = 1, #data do
		for c = 1, #data[r] do
			if data[r][c] == " " or data[r][c] == "" then
				data[r][c] = alphabet.VOID
			end
		end
	end
	local invalid = M.invalidSymbolCounts(data, alphabet.VALID_BG_SET)
	if next(invalid) then
		return nil, { invalid = invalid }
	end
	return data, { invalid = {} }
end

-- =========================================================================
-- Corpus building
-- =========================================================================

-- Every room -> its grid, skipping rooms with unknown glyphs (reported, like
-- the Python's warning) and rooms too small for a 3x3 window.
-- layer: "fg" (default) or "bg". Returns grids and a summary.
function M.buildCorpus(rooms, layer)
	layer = layer or "fg"
	local grids = {}
	local summary = { total = #rooms, kept = 0, skipped = {}, entities = 0, outside = 0 }
	for _, room in ipairs(rooms) do
		local data, report
		if layer == "bg" then
			data, report = M.collectBgRoom(room)
		else
			data, report = M.recombineRoom(room)
		end
		if data and #data >= 3 and #data[1] >= 3 then
			grids[#grids + 1] = data
			summary.kept = summary.kept + 1
			summary.entities = summary.entities + (report.kept or 0)
			summary.outside = summary.outside + (report.outside or 0)
		else
			summary.skipped[#summary.skipped + 1] = { name = room.name, invalid = report.invalid }
		end
	end
	return grids, summary
end

-- =========================================================================
-- data_loader.jl: rooms out of a decoded .bin element tree
-- =========================================================================

local function splitRows(text)
	local rows = {}
	for line in (text or ""):gmatch("([^\n]*)\n?") do
		rows[#rows + 1] = line
	end
	-- gmatch yields one trailing empty match
	if rows[#rows] == "" then
		rows[#rows] = nil
	end
	return rows
end

-- Pads ragged tile blobs to the room's tile size, as the game does.
local function normaliseRows(rows, wTiles, hTiles)
	local out = {}
	for r = 1, hTiles do
		local line = rows[r] or ""
		if #line < wTiles then
			line = line .. string.rep(alphabet.VOID, wTiles - #line)
		elseif #line > wTiles then
			line = line:sub(1, wTiles)
		end
		out[r] = line
	end
	return out
end

-- A `{ name, attrs, children, innerText }` tree from binary_packer.decodeMap
-- -> the plain room tables above.
function M.roomsFromMapTree(root)
	local rooms = {}
	for _, child in ipairs(root.children or {}) do
		if child.name == "levels" then
			for _, level in ipairs(child.children or {}) do
				if level.name == "level" then
					local a = level.attrs or {}
					local wTiles = math.floor((a.width or 0) / M.TILE_SIZE)
					local hTiles = math.floor((a.height or 0) / M.TILE_SIZE)
					local room = { name = a.name or "", fgRows = {}, bgRows = nil, entities = {} }
					for _, part in ipairs(level.children or {}) do
						if part.name == "solids" then
							room.fgRows = normaliseRows(splitRows(part.innerText), wTiles, hTiles)
						elseif part.name == "bg" then
							room.bgRows = normaliseRows(splitRows(part.innerText), wTiles, hTiles)
						elseif part.name == "entities" then
							for _, e in ipairs(part.children or {}) do
								local ea = e.attrs or {}
								room.entities[#room.entities + 1] = {
									name = e.name, x = ea.x, y = ea.y,
									width = ea.width, height = ea.height, red = ea.red,
								}
							end
						end
					end
					if #room.fgRows == 0 then
						room.fgRows = normaliseRows({}, wTiles, hTiles)
					end
					rooms[#rooms + 1] = room
				end
			end
		end
	end
	return rooms
end

return M
