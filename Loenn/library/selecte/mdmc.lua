-- mdmc.lua - multi-dimensional Markov chain sampling and estimation.
--
-- Lua port of the model half of https://github.com/robilouis/seleCte (MIT):
--   * utils/utils.py        generate_empty_room_data, extract_pattern,
--                           generate_new_tile, update_room_array (with
--                           backtracking), generate_room_data, load_dpe
--   * pcg/dpe_generation.py estimate_dpe, get_all_submatrices, submatrix_to_count
--
-- Rooms are `data[row][col]` tables of one-character strings, 1-based, row 1
-- being the TOP edge - the same (height, width) orientation as the numpy
-- arrays, shifted by one. Window positions are given as the 1-based (row,
-- col) of the window's top-left corner.
--
-- A DPE ("dict of probability estimation") is
--   { mask = "000011012", patterns = { [pattern] = { sym, p, sym, p, ... } } }
-- which is what dpe_data.lua stores and what `estimate` produces.

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

local M = {}

M.MAX_BACKTRACK_ITERATIONS = 100

-- =========================================================================
-- Rooms
-- =========================================================================

-- generate_empty_room_data: void inside a one-tile border of `border`.
function M.emptyRoom(width, height, border)
	border = border or alphabet.SOLID
	local data = {}
	for r = 1, height do
		local row = {}
		for c = 1, width do
			if r == 1 or r == height or c == 1 or c == width then
				row[c] = border
			else
				row[c] = alphabet.VOID
			end
		end
		data[r] = row
	end
	return data
end

function M.copyRoom(data)
	local out = {}
	for r = 1, #data do
		local row, src = {}, data[r]
		for c = 1, #src do
			row[c] = src[c]
		end
		out[r] = row
	end
	return out
end

function M.roomSize(data)
	local h = #data
	local w = h > 0 and #data[1] or 0
	return w, h
end

-- Rows as strings, one per line - the shape a csv/tile blob wants.
function M.roomToRows(data)
	local rows = {}
	for r = 1, #data do
		rows[r] = table.concat(data[r])
	end
	return rows
end

-- Inverse of roomToRows.
function M.rowsToRoom(rows)
	local data = {}
	for r, line in ipairs(rows) do
		local row = {}
		for c = 1, #line do
			row[c] = line:sub(c, c)
		end
		data[r] = row
	end
	return data
end

-- =========================================================================
-- DPE loading / validation (utils.py load_dpe, check_dpe_matches_mask)
-- =========================================================================

local function patternCount(dpe)
	local n = 0
	for _ in pairs(dpe.patterns) do
		n = n + 1
	end
	return n
end

function M.resolveMask(dpe)
	return alphabet.parseMask(dpe.mask or alphabet.DEFAULT_MASK)
end

-- check_dpe_matches_mask: a dict trained with another mask would silently
-- turn every lookup into a miss and generation into uniform noise.
function M.checkDpeMatchesMask(dpe, mask)
	if not dpe or not dpe.patterns or patternCount(dpe) == 0 then
		error("Empty DPE dict - nothing to generate from.")
	end
	local anyPattern = next(dpe.patterns)
	if #anyPattern ~= #mask.offsets then
		error(string.format(
			"DPE patterns are %d symbols long but the MdMC mask has %d neighbourhood cells: "
			.. "this dict was trained with a different mask.", #anyPattern, #mask.offsets))
	end
end

-- =========================================================================
-- Sampling
-- =========================================================================

-- extract_pattern: the symbols at the mask's neighbourhood offsets, joined.
function M.extractPattern(data, r, c, offsets)
	local parts = {}
	for i, off in ipairs(offsets) do
		parts[i] = data[r + off[1]][c + off[2]]
	end
	return table.concat(parts)
end

-- extract_proba_from_tile: the flat distribution for the window at (r, c),
-- or nil for a pattern the dict never saw.
function M.lookup(data, r, c, dpe, offsets)
	return dpe.patterns[M.extractPattern(data, r, c, offsets)]
end

local function listContains(list, v)
	for _, x in ipairs(list) do
		if x == v then
			return true
		end
	end
	return false
end

-- generate_new_tile. `dist` nil/empty => uniform draw over `allSymbols`
-- (an unseen pattern). With `exclude`, raises when every symbol of non-zero
-- probability is already excluded - the backtracking signal; otherwise one
-- redraw is attempted if the first pick is excluded (as in the original,
-- which does not loop until it finds an unexcluded one).
function M.generateNewTile(dist, allSymbols, exclude, rng)
	if not dist or #dist == 0 then
		return rng:choice(allSymbols)
	end
	if exclude and #exclude > 0 then
		local allExcluded = true
		for i = 1, #dist - 1, 2 do
			if dist[i + 1] > 0 and not listContains(exclude, dist[i]) then
				allExcluded = false
				break
			end
		end
		if allExcluded then
			error("There is no symbol with a strictly positive proba left!")
		end
	end
	local tile = rng:weighted(dist)
	if exclude and listContains(exclude, tile) then
		tile = rng:weighted(dist)
	end
	return tile
end

-- update_room_array: samples the one tile the window at (r, c) predicts, in
-- place. With btDepth > 0 the next btDepth tiles to the right are sampled on
-- a copy first, and a choice that strands a later position is rejected.
function M.updateRoomArray(data, r, c, dpe, btDepth, mask, allSymbols, rng, log)
	local ti, tj = mask.target[1], mask.target[2]
	local offsets = mask.offsets
	local width = #data[1]
	-- Python: min(bt_depth, array.shape[1] - y - 3), y = c - 1
	local btDepthTrue = math.min(btDepth or 0, width - c - 2)

	if btDepthTrue > 0 then
		local excluded = {}
		for k = 0, btDepthTrue - 1 do
			excluded[k] = {}
		end
		local k, nIter = 0, 0
		local temp = M.copyRoom(data)

		while k >= 0 and k < btDepthTrue and nIter < M.MAX_BACKTRACK_ITERATIONS do
			nIter = nIter + 1
			local dist = M.lookup(temp, r, c + k, dpe, offsets)
			if dist then
				local ok, tile = pcall(M.generateNewTile, dist, allSymbols, excluded[k], rng)
				if ok then
					table.insert(excluded[k], tile)
					temp[r + ti][c + tj + k] = tile
					k = k + 1
				else
					-- no tiles left at level k: backtrack to k-1
					k = k - 1
				end
			else
				-- unseen state further right: backtrack
				k = k - 1
			end
		end

		if nIter == M.MAX_BACKTRACK_ITERATIONS then
			if log then
				log("Backtracking stuck in loop! Random generation.")
			end
			data[r + ti][c + tj] = M.generateNewTile(nil, allSymbols, nil, rng)
		end
		if k == -1 then
			if log then
				log("Backtracking failed! Random generation.")
			end
			data[r + ti][c + tj] = M.generateNewTile(nil, allSymbols, nil, rng)
		else
			data[r + ti][c + tj] = temp[r + ti][c + tj]
		end
	else
		data[r + ti][c + tj] = M.generateNewTile(M.lookup(data, r, c, dpe, offsets), allSymbols, nil, rng)
	end
	return data
end

-- generate_room_data: sweeps the window row-major over an empty bordered
-- room. Rows 1-2 and columns 1-2 are never written (the target cell trails
-- the window): row/column 1 keep the border, row/column 2 the void.
--
-- opts: { btDepth = 0, allSymbols = ALL_TILES_AND_ENTITIES, border = "1", log = fn }
function M.generateRoomData(dpe, width, height, rng, opts)
	opts = opts or {}
	local mask = M.resolveMask(dpe)
	if mask.side ~= 3 then
		error(string.format("Room generation only supports 3x3 MdMC masks, got %dx%d.", mask.side, mask.side))
	end
	M.checkDpeMatchesMask(dpe, mask)

	local allSymbols = opts.allSymbols or alphabet.ALL_TILES_AND_ENTITIES
	local data = M.emptyRoom(width, height, opts.border or alphabet.SOLID)
	for r = 1, height - 2 do
		for c = 1, width - 2 do
			M.updateRoomArray(data, r, c, dpe, opts.btDepth or 0, mask, allSymbols, rng, opts.log)
		end
	end
	return data
end

-- =========================================================================
-- Estimation (dpe_generation.estimate_dpe)
-- =========================================================================

-- Counts tile patterns across a corpus of rooms and normalises per pattern.
--   rooms:      list of data tables (any sizes, each at least 3x3)
--   maskFlat:   e.g. "000011012"
--   vocabulary: symbols the layer can hold (ALL_TILES_AND_ENTITIES / VALID_BG_TILES)
-- Only patterns the corpus holds are emitted. Observed symbols keep the order
-- they were first seen in; patterns are emitted in vocabulary order so the
-- result is a pure function of the corpus. Returns the DPE and the room count.
function M.estimate(rooms, maskFlat, vocabulary)
	maskFlat = maskFlat or alphabet.DEFAULT_MASK
	vocabulary = vocabulary or alphabet.ALL_TILES_AND_ENTITIES
	local mask = alphabet.parseMask(maskFlat)
	local size = mask.side
	local ti, tj = mask.target[1], mask.target[2]

	-- pattern -> { order = {sym...}, counts = {[sym] = n}, total = n }
	local observed = {}
	local nRooms = 0
	for _, data in ipairs(rooms) do
		local w, h = M.roomSize(data)
		if w >= size and h >= size then
			nRooms = nRooms + 1
			for r = 1, h - size + 1 do
				for c = 1, w - size + 1 do
					local pattern = M.extractPattern(data, r, c, mask.offsets)
					local sym = data[r + ti][c + tj]
					if sym == "" or sym == " " then
						sym = alphabet.VOID
					end
					local entry = observed[pattern]
					if not entry then
						entry = { order = {}, counts = {}, total = 0 }
						observed[pattern] = entry
					end
					if not entry.counts[sym] then
						entry.counts[sym] = 0
						entry.order[#entry.order + 1] = sym
					end
					entry.counts[sym] = entry.counts[sym] + 1
					entry.total = entry.total + 1
				end
			end
		end
	end

	if nRooms == 0 then
		error("No room in the corpus is at least " .. size .. "x" .. size .. " - nothing to estimate from.")
	end

	local symbolOrder = {}
	for i, sym in ipairs(vocabulary) do
		symbolOrder[sym] = i
	end
	local unknownRank = #vocabulary + 1
	local keys = {}
	for pattern in pairs(observed) do
		keys[#keys + 1] = pattern
	end
	table.sort(keys, function(a, b)
		for i = 1, #a do
			local ra = symbolOrder[a:sub(i, i)] or unknownRank
			local rb = symbolOrder[b:sub(i, i)] or unknownRank
			if ra ~= rb then
				return ra < rb
			end
		end
		return a < b
	end)

	local patterns = {}
	for _, pattern in ipairs(keys) do
		local entry = observed[pattern]
		local dist = {}
		for _, sym in ipairs(entry.order) do
			dist[#dist + 1] = sym
			dist[#dist + 1] = entry.counts[sym] / entry.total
		end
		patterns[pattern] = dist
	end

	return { mask = maskFlat, patterns = patterns, _order = keys }, nRooms
end

M.patternCount = patternCount

return M
