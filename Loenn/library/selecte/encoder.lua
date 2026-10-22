-- encoder.lua - a generated level -> rooms Celeste can load.
--
-- Lua port of room_encoder/data_to_level.jl from
-- https://github.com/robilouis/seleCte (MIT) and of the two Maple routines
-- it leans on: `FgTiles` (keep tileset glyphs, blank the rest to air) and
-- `entityMap` (turn the blanked glyphs into entities, sizing runs of
-- repeated glyphs). Both read the SAME grid: the alphabet partitions the
-- character set so a symbol is a tileset glyph or an entity glyph, never
-- both. See alphabet.lua and seleCte's ALPHABET.md.
--
-- Two outputs from one room table:
--   * encodeRoom     - tile rows + entity list + Celeste position, which the
--                      Loenn script turns into an editor room;
--   * buildMapTree   - a whole level as the element tree binary_packer.lua
--                      writes as a `.bin`, carrying the chapter `meta` that
--                      makes the crystal heart end the level (HeartIsEnd),
--                      exactly as data_to_level.jl encodes a Maple `Side`.

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

M.TILE_SIZE = 8

-- =========================================================================
-- Maple: FgTiles + entityMap
-- =========================================================================

-- Maple's searchSize: how far the glyph at (r, c) repeats right and/or down.
local function searchSize(data, r, c, sw, sh)
	if not sw and not sh then
		return 1, 1
	end
	local ch = data[r][c]
	local h, w = #data, #data[1]
	local stopC, stopR = c, r
	while sw and stopC + 1 <= w and data[r][stopC + 1] == ch do
		stopC = stopC + 1
	end
	while sh and stopR + 1 <= h do
		local allSame = true
		for cc = c, stopC do
			if data[stopR + 1][cc] ~= ch then
				allSame = false
				break
			end
		end
		if not allSame then
			break
		end
		stopR = stopR + 1
	end
	return stopC - c + 1, stopR - r + 1
end

-- entityMap: row-major scan; each entity glyph becomes
--   { name, x, y, width?, height?, attrs, symbol }
-- in room-local pixels, placed by Maple's rule
--   x = col * 8 + ox - 8,  y = row * 8 + oy - 8   (1-based row/col).
function M.entityMap(data, entityMap)
	entityMap = entityMap or alphabet.ENTITY_MAP
	local h = #data
	local w = h > 0 and #data[1] or 0
	local complete = {}
	for r = 1, h do
		complete[r] = {}
	end
	local out = {}
	local T = M.TILE_SIZE
	for r = 1, h do
		for c = 1, w do
			local v = data[r][c]
			local spec = entityMap[v]
			if spec and not complete[r][c] then
				local tw, th = searchSize(data, r, c, spec.sw, spec.sh)
				for rr = r, r + th - 1 do
					for cc = c, c + tw - 1 do
						complete[rr][cc] = true
					end
				end
				local e = {
					name = spec.name,
					symbol = v,
					x = c * T + spec.ox - T,
					y = r * T + spec.oy - T,
					attrs = {},
				}
				for k, val in pairs(spec.attrs or {}) do
					e.attrs[k] = val
				end
				if spec.sw then
					e.width = tw * T
				end
				if spec.sh then
					e.height = th * T
				end
				out[#out + 1] = e
			end
		end
	end
	return out
end

-- FgTiles: rows of tileset glyphs, everything else blanked to air. `solid`
-- optionally redraws the alphabet's "1" with another vanilla tileset glyph.
function M.fgRows(data, solid)
	local rows = {}
	for r = 1, #data do
		local chars = {}
		for c = 1, #data[r] do
			local v = data[r][c]
			if alphabet.VALID_FG_SET[v] then
				if v == alphabet.SOLID and solid and solid ~= alphabet.SOLID then
					v = solid
				end
				chars[c] = v
			else
				chars[c] = alphabet.VOID
			end
		end
		rows[r] = table.concat(chars)
	end
	return rows
end

-- Background rows: tileset glyphs kept, anything else air.
function M.bgRows(data)
	local rows = {}
	for r = 1, #data do
		local chars = {}
		for c = 1, #data[r] do
			local v = data[r][c]
			chars[c] = alphabet.VALID_BG_SET[v] and v or alphabet.VOID
		end
		rows[r] = table.concat(chars)
	end
	return rows
end

-- =========================================================================
-- data_to_level.jl
-- =========================================================================

-- The skeleton's origin is the room's BOTTOM-left corner with y pointing
-- up; Celeste's position is the TOP-left with y pointing down. Flipping the
-- sign alone drops every room by its own height, which rooms of one height
-- survive as a translation and rooms of different heights do not: the
-- height has to be subtracted for the flip to be rigid.
function M.roomPosition(origin, heightTiles)
	local T = M.TILE_SIZE
	return origin[1] * T, -(origin[2] * T + heightTiles * T)
end

-- One room -> { name, x, y, width, height, fgRows, bgRows, entities }.
-- opts: { solid = "1", bgData = <bg grid or nil> }
function M.encodeRoom(room, name, opts)
	opts = opts or {}
	local w, h = room.size[1], room.size[2]
	local x, y = M.roomPosition(room.origin, h)
	return {
		name = name,
		x = x,
		y = y,
		width = w * M.TILE_SIZE,
		height = h * M.TILE_SIZE,
		widthTiles = w,
		heightTiles = h,
		fgRows = M.fgRows(room.data, opts.solid),
		bgRows = opts.bgData and M.bgRows(opts.bgData) or nil,
		entities = M.entityMap(room.data),
	}
end

-- Every room of a skeleton, in insertion order. `bgByName` optionally maps a
-- room name to its background grid.
function M.encodeSkeleton(skeleton, opts, bgByName)
	local out = {}
	for _, name in ipairs(skeleton:listAllRooms()) do
		local room = skeleton:getRoomByName(name)
		out[#out + 1] = M.encodeRoom(room, name, {
			solid = opts and opts.solid,
			bgData = bgByName and bgByName[name],
		})
	end
	return out
end

-- Maple's default_meta / default_mode / default_audiostate from the seleCte
-- fork, merged the way data_to_level.jl's chapter_metadata does. HeartIsEnd
-- is the one that matters: without it the heart is a collectible.
function M.chapterMetadata(overrides)
	overrides = overrides or {}
	local meta = {
		Icon = "",
		Interlude = false,
		TitleBaseColor = "6c7c81",
		TitleAccentColor = "2f344b",
		TitleTextColor = "ffffff",
		IntroType = "WakeUp",
		Dreaming = false,
		ColorGrade = "",
		Wipe = "",
		DarknessAlpha = 0.05,
		BloomBase = 0.0,
		BloomStrength = 1.0,
		CoreMode = "",
		CassetteSong = "",
		ForegroundTiles = "",
		BackgroundTiles = "",
		AnimatedTiles = "",
		Portraits = "",
		Sprites = "",
		OverrideASideMeta = true,
		PostcardSoundID = "",
	}
	local mode = {
		IgnoreLevelAudioLayerData = false,
		Inventory = "Default",
		StartLevel = "",
		HeartIsEnd = true,
		SeekerSlowdown = true,
		TheoInBubble = false,
	}
	local audiostate = {
		Ambience = overrides.ambience or "event:/env/amb/01_main",
		Music = overrides.music or "event:/music/lvl1/main",
	}
	if overrides.meta then
		for k, v in pairs(overrides.meta) do
			meta[k] = v
		end
	end
	if overrides.mode then
		for k, v in pairs(overrides.mode) do
			mode[k] = v
		end
	end
	return meta, mode, audiostate
end

-- =========================================================================
-- .bin element tree (for pcg_engine/celeste-pcg/lua/binary_packer.lua)
-- =========================================================================

local function entityElement(e, id)
	local attrs = { id = id, x = e.x, y = e.y }
	if e.width then
		attrs.width = e.width
	end
	if e.height then
		attrs.height = e.height
	end
	for k, v in pairs(e.attrs or {}) do
		attrs[k] = v
	end
	return { name = e.name, attrs = attrs, children = {} }
end

local function levelElement(encoded, nextId, levelMusic)
	local entities = {}
	for _, e in ipairs(encoded.entities) do
		entities[#entities + 1] = entityElement(e, nextId())
	end
	local bgRows = encoded.bgRows
	if not bgRows then
		bgRows = {}
		local blank = string.rep(alphabet.VOID, encoded.widthTiles)
		for r = 1, encoded.heightTiles do
			bgRows[r] = blank
		end
	end
	return {
		name = "level",
		attrs = {
			name = encoded.name,
			x = encoded.x,
			y = encoded.y,
			width = encoded.width,
			height = encoded.height,
			music = levelMusic or "",
			alt_music = "",
			ambience = "",
			musicLayer1 = true,
			musicLayer2 = true,
			musicLayer3 = true,
			musicLayer4 = true,
			musicProgress = "",
			ambienceProgress = "",
			dark = false,
			underwater = false,
			space = false,
			whisper = false,
			disableDownTransition = false,
			windPattern = "None",
			c = 0,
			cameraOffsetX = 0,
			cameraOffsetY = 0,
		},
		children = {
			{ name = "solids", attrs = { offsetX = 0, offsetY = 0 }, innerText = table.concat(encoded.fgRows, "\n"), children = {} },
			{ name = "bg", attrs = { offsetX = 0, offsetY = 0 }, innerText = table.concat(bgRows, "\n"), children = {} },
			{ name = "entities", attrs = {}, children = entities },
			{ name = "triggers", attrs = {}, children = {} },
			{ name = "fgdecals", attrs = { tileset = "0", offsetX = 0, offsetY = 0 }, children = {} },
			{ name = "bgdecals", attrs = { tileset = "0", offsetX = 0, offsetY = 0 }, children = {} },
		},
	}
end

-- A whole level as a Map element tree: levels + Style + Filler (what Maple's
-- encodeMap writes) plus the `meta` element a Side carries.
-- opts: { music = <level music event or ""> , metadata = overrides for chapterMetadata }
function M.buildMapTree(encodedRooms, opts)
	opts = opts or {}
	local id = 0
	local function nextId()
		id = id + 1
		return id
	end
	local levels = {}
	for _, encoded in ipairs(encodedRooms) do
		levels[#levels + 1] = levelElement(encoded, nextId, opts.music)
	end
	local meta, mode, audiostate = M.chapterMetadata(opts.metadata)
	return {
		name = "Map",
		attrs = {},
		children = {
			{ name = "levels", attrs = {}, children = levels },
			{ name = "Style", attrs = {}, children = {
				{ name = "Backgrounds", attrs = {}, children = {} },
				{ name = "Foregrounds", attrs = {}, children = {} },
			} },
			{ name = "Filler", attrs = {}, children = {} },
			{ name = "meta", attrs = meta, children = {
				{ name = "mode", attrs = mode, children = {
					{ name = "audiostate", attrs = audiostate, children = {} },
				} },
			} },
		},
	}
end

-- The everest.yaml a standalone chapter folder needs beside Maps/<name>.bin.
function M.everestYaml(name, everestVersion)
	return "- Name: " .. name .. "\n"
		.. "  Version: 1.0.0\n"
		.. "  Dependencies:\n"
		.. "    - Name: Everest\n"
		.. "      Version: " .. (everestVersion or "1.4489.0") .. "\n"
end

return M
