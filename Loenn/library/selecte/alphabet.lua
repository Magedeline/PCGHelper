-- alphabet.lua - the seleCte tile alphabet and its Celeste correspondence.
--
-- Lua port of three things from https://github.com/robilouis/seleCte (MIT):
--   * utils/data/tiles_info.json      - the vocabulary the MdMC model samples
--   * utils/utils.py (mask helpers)   - parse_mdmc_matrix / mdmc_offsets
--   * Maple's src/entity_map.jl       - how each glyph becomes a Celeste entity
--     (the robilouis/Maple fork pinned by seleCte, which adds 'H' => CrystalHeart)
--
-- One character per tile throughout:
--   0 void   1 solid   ^ < v > spikes   S spinner   D dreamBlock   C crumbleBlock
--   _ jumpThru   O greenBooster   Q redBooster   W water   B bigSpinner (bumper)
--   R refill   F infiniteStar (feather)   L lightbeam
-- P (player) and H (crystal heart) are placed after generation and are not in
-- the sampled vocabulary. See seleCte's room_encoder/ALPHABET.md.

local M = {}

M.VOID = "0"
M.SOLID = "1"
M.PLAYER = "P"
M.HEART = "H"

-- tiles_info.json, verbatim.
M.ALL_TILES_AND_ENTITIES = { "0", "1", "^", "<", "v", ">", "D", "C", "_", "O", "Q", "W", "S", "B", "R", "F", "L" }
M.LETHAL_ENTITIES = { "^", "<", "v", ">", "S" }
M.NON_LETHAL_ENTITIES = { "D", "C", "_", "O", "Q", "W", "B", "R", "F" }
M.VALID_FG_TILES = { "1", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f", "g", "G", "h", "i", "j", "k", "l", "m", "n", "z" }
M.VALID_BG_TILES = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e" }

-- Which game entity becomes which symbol when a map is turned into training
-- data (recombine_fg_entities.py). Boosters are split on their `red` flag.
M.ENTITY_SYMBOLS = {
	spikesUp = "^",
	spikesLeft = "<",
	spikesDown = "v",
	spikesRight = ">",
	dreamBlock = "D",
	crumbleBlock = "C",
	jumpThru = "_",
	greenBooster = "O",
	redBooster = "Q",
	water = "W",
	spinner = "S",
	bigSpinner = "B",
	refill = "R",
	infiniteStar = "F",
	lightbeam = "L",
}

-- Maple's default_entity_map + entity_offsets + search_for_size, folded into
-- one table per glyph. `ox`/`oy` is the pixel offset added to the cell's
-- top-left corner; `sw`/`sh` whether entityMap walks right/down over repeated
-- glyphs to size the entity; `attrs` are the constructor defaults Maple's
-- @mapdef gives the entity, so a generated .bin carries the same attributes a
-- seleCte-encoded one does. 'L' has no entry on purpose: upstream Maple cannot
-- encode a lightbeam either, and the glyph is lost at encode time.
M.ENTITY_MAP = {
	["^"] = { name = "spikesUp", ox = 0, oy = 8, sw = true, sh = false, attrs = { type = "default" } },
	["<"] = { name = "spikesLeft", ox = 8, oy = 0, sw = false, sh = true, attrs = { type = "default" } },
	["v"] = { name = "spikesDown", ox = 0, oy = 0, sw = true, sh = false, attrs = { type = "default" } },
	[">"] = { name = "spikesRight", ox = 0, oy = 0, sw = false, sh = true, attrs = { type = "default" } },
	["P"] = { name = "player", ox = 8, oy = 8, sw = false, sh = false, attrs = {} },
	["D"] = { name = "dreamBlock", ox = 0, oy = 0, sw = true, sh = true, attrs = { fastMoving = false, oneUse = false, below = false } },
	["C"] = { name = "crumbleBlock", ox = 0, oy = 0, sw = true, sh = false, attrs = { texture = "default" } },
	["_"] = { name = "jumpThru", ox = 0, oy = 0, sw = true, sh = false, attrs = { texture = "wood", surfaceIndex = -1 } },
	["O"] = { name = "booster", ox = 4, oy = 4, sw = false, sh = false, attrs = { red = false, ch9_hub_booster = false } },
	["Q"] = { name = "booster", ox = 4, oy = 4, sw = false, sh = false, attrs = { red = true, ch9_hub_booster = false } },
	["W"] = { name = "water", ox = 0, oy = 0, sw = true, sh = true, attrs = { hasBottom = false } },
	["S"] = { name = "spinner", ox = 4, oy = 4, sw = false, sh = false, attrs = { attachToSolid = false } },
	["B"] = { name = "bigSpinner", ox = 4, oy = 4, sw = false, sh = false, attrs = {} },
	["R"] = { name = "refill", ox = 4, oy = 4, sw = false, sh = false, attrs = { twoDash = false, oneUse = false } },
	["F"] = { name = "infiniteStar", ox = 4, oy = 4, sw = false, sh = false, attrs = { shielded = false, singleUse = false } },
	["H"] = { name = "blackGem", ox = 0, oy = 0, sw = false, sh = false,
		attrs = { fake = false, removeCameraTriggers = false, fakeHeartDialog = "CH9_FAKE_HEART", keepGoingDialog = "CH9_KEEP_GOING" } },
}

-- Symbols the A* playability check treats as passable even though they are
-- not void (celeskeleton.Room.extract_astar_ready_data).
M.ASTAR_PASSABLE = { D = true, L = true, P = true, W = true }

-- Maple's tile_fg_names, for picking which tileset `1` is drawn with.
M.FG_TILE_NAMES = {
	["1"] = "Dirt", ["3"] = "Snow", ["4"] = "Girder", ["5"] = "Tower", ["6"] = "Stone",
	["7"] = "Cement", ["8"] = "Rock", ["9"] = "Wood", ["a"] = "Wood Stone", ["b"] = "Cliffside",
	["c"] = "Pool Edges", ["d"] = "Temple A", ["e"] = "Temple B", ["f"] = "Cliffside Alt",
	["g"] = "Reflection", ["G"] = "Reflection Alt", ["h"] = "Grass", ["i"] = "Summit",
	["j"] = "Summit No Snow", ["k"] = "Core", ["l"] = "Deadgrass", ["m"] = "Lost Levels",
	["n"] = "Scifi", ["z"] = "Template",
}

function M.toSet(list)
	local set = {}
	for _, v in ipairs(list) do
		set[v] = true
	end
	return set
end

M.VALID_FG_SET = M.toSet(M.VALID_FG_TILES)
M.VALID_BG_SET = M.toSet(M.VALID_BG_TILES)
M.VOCABULARY_SET = M.toSet(M.ALL_TILES_AND_ENTITIES)
M.NON_LETHAL_SET = M.toSet(M.NON_LETHAL_ENTITIES)

-- =========================================================================
-- MdMC neighbourhood masks (utils.py: parse_mdmc_matrix / mdmc_offsets /
-- mdmc_target_offset)
-- =========================================================================

-- The mask every shipped dict was trained with:
--   0 0 0
--   0 1 1
--   0 1 2
M.DEFAULT_MASK = "000011012"

-- Parses a flattened mask into { side, offsets = {{di, dj}, ...}, target = {ti, tj} }.
-- Offsets are 0-based from the window's top-left corner, in row-major order,
-- exactly like np.argwhere. Errors mirror the Python ValueErrors.
function M.parseMask(flat)
	flat = tostring(flat)
	local n = #flat
	local side = math.floor(math.sqrt(n) + 0.5)
	if side * side ~= n then
		error(string.format("MdMC mask %q has %d cells, which is not a square.", flat, n))
	end
	local offsets, target = {}, nil
	for idx = 1, n do
		local ch = flat:sub(idx, idx)
		local i = math.floor((idx - 1) / side)
		local j = (idx - 1) % side
		if ch == "1" then
			offsets[#offsets + 1] = { i, j }
		elseif ch == "2" then
			if target then
				error(string.format("MdMC mask %q needs exactly one target cell (a `2`).", flat))
			end
			target = { i, j }
		elseif ch ~= "0" then
			error(string.format("MdMC mask %q holds a cell that is not 0, 1 or 2.", flat))
		end
	end
	if #offsets == 0 then
		error(string.format("MdMC mask %q has no neighbourhood cell (a `1`).", flat))
	end
	if not target then
		error(string.format("MdMC mask %q needs exactly one target cell (a `2`).", flat))
	end
	return { flat = flat, side = side, offsets = offsets, target = target }
end

return M
