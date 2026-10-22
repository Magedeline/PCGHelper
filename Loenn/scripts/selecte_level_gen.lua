-- selecte_level_gen.lua
-- Loenn front end for the native Lua port of seleCte
-- (https://github.com/robilouis/seleCte, Robinet et al., FDG '25), the
-- research generator behind the paper this mod implements. Replaces the
-- Python + Julia pipeline (level_generation.py -> data_to_level.jl) with
-- pure Lua under Loenn/library/selecte/: no Python, no Julia, no Node.
--
-- Pipeline, as in the original:
--   1. draw a level skeleton - a tree of same-size rooms (p = 0 corridor,
--      p -> 1 labyrinth) with exits punched through shared borders;
--   2. fill every room by sampling tiles from a multi-dimensional Markov
--      chain trained on Celeste's 824 vanilla rooms (the trained model ships
--      in dpe_data.lua), carve the exits back in, add respawn points;
--   3. hold the rooms on the start->end route to an A* playability check,
--      resampling until each can be crossed; place the player spawn in the
--      first room and a crystal heart in the last;
--   4. encode: tileset glyphs become the fg layer, entity glyphs become
--      entities (Maple's entityMap), and the whole level either lands in the
--      open map as new rooms or is written to disk as a standalone chapter
--      .bin whose metadata makes collecting the heart end the level.
--
-- Beyond the original: the model can be re-estimated in-editor from the
-- open map's rooms or from a folder of .bin maps (the data_loader +
-- recombine_fg_entities + dpe_generation stages, also ported), and a
-- per-chapter background model can fill the bg layer, which seleCte itself
-- stops short of.

local mods = require("mods")
local state = require("loaded_state")
local snapshot = require("structs.snapshot")
local mapItemUtils = require("map_item_utils")
local filesystem = require("utils.filesystem")
local fileLocations = require("file_locations")

local pcg = mods.requireFromPlugin("library.pcg_toolkit")
local alphabet = mods.requireFromPlugin("library.selecte.alphabet")
local mdmc = mods.requireFromPlugin("library.selecte.mdmc")
local level = mods.requireFromPlugin("library.selecte.level")
local encoder = mods.requireFromPlugin("library.selecte.encoder")
local recombine = mods.requireFromPlugin("library.selecte.recombine")
local playability = mods.requireFromPlugin("library.selecte.playability")
local dpeData = mods.requireFromPlugin("library.selecte.dpe_data")
local Rng = mods.requireFromPlugin("library.selecte.rng").Rng

local TILE = 8

local MODEL_OPTIONS = {
	"pe_d5_full", "fg_1", "fg_2", "fg_3", "fg_4", "fg_5", "fg_6", "fg_7", "fg_8", "fg_9",
	"open_map", "bin_folder",
}
local BACKGROUND_OPTIONS = {
	"none", "bg_1", "bg_2", "bg_3", "bg_4", "bg_5", "bg_6", "bg_7", "bg_8", "bg_9",
	"open_map", "bin_folder",
}
local SOLID_OPTIONS = (function()
	local opts = {}
	for glyph in pairs(alphabet.FG_TILE_NAMES) do
		opts[#opts + 1] = glyph
	end
	table.sort(opts)
	return opts
end)()
local MUSIC_OPTIONS = {
	"music_city", "music_oldsite", "music_oldsite_mirror", "music_resort_intro",
	"music_cliffside_main", "music_temple_normal", "music_reflection_main",
	"music_summit_main", "music_core_main",
	"music_rmx_01_forsaken_city", "music_rmx_02_old_site", "music_rmx_03_resort",
	"music_rmx_04_cliffside", "music_rmx_05_mirror_temple", "music_rmx_06_reflection",
	"music_rmx_07_summit", "music_rmx_09_core", "music_pico8_area1", "",
}

-- Loenn's path field with a folder picker; blank is allowed (the script
-- picks a default) and so is a folder that does not exist yet (outputDir).
local FOLDER_FIELD = {
	fieldType = "path", allowFolders = true, allowFiles = false,
	allowEmpty = true, allowMissingPath = true, relativeToMod = false,
}

local script = {
	name = "selecteLevelGen",
	displayName = "seleCte Level Generator (MdMC, pure Lua)",
	tooltip = "Native Lua port of seleCte (Robinet et al., FDG '25): draws a tree-shaped level skeleton, "
		.. "fills each room from a multi-dimensional Markov chain trained on Celeste's vanilla rooms, "
		.. "checks the start->end route with A*, places the spawn and a crystal heart, and either adds "
		.. "the rooms to the open map or writes a standalone chapter .bin. No Python, Julia or Node needed.",
	parameters = {
		nbRooms = 7,
		proba = 0.3,
		roomWidthTiles = 40,
		roomHeightTiles = 23,
		triesLimit = 10,
		btDepth = 0,
		resetSkeleton = false,
		seed = "",
		model = "pe_d5_full",
		background = "none",
		trainBinFolder = "",
		solidTileset = "1",
		output = "map",
		namePrefix = "selecte_",
		setHeartIsEnd = false,
		chapterName = "SeleCteChapter",
		music = "music_city",
		outputDir = "",
		verbose = false,
	},
	fieldInformation = {
		nbRooms = { fieldType = "integer", options = { min = 2, max = 64 } },
		roomWidthTiles = { fieldType = "integer", options = { min = 8, max = 200 } },
		roomHeightTiles = { fieldType = "integer", options = { min = 8, max = 200 } },
		triesLimit = { fieldType = "integer", options = { min = 1, max = 100 } },
		btDepth = { fieldType = "integer", options = { min = 0, max = 16 } },
		model = { fieldType = "loennScripts.dropdown", options = MODEL_OPTIONS, editable = false },
		background = { fieldType = "loennScripts.dropdown", options = BACKGROUND_OPTIONS, editable = false },
		solidTileset = { fieldType = "loennScripts.dropdown", options = SOLID_OPTIONS, editable = false },
		output = { fieldType = "loennScripts.dropdown", options = { "map", "bin", "both" }, editable = false },
		music = { fieldType = "loennScripts.dropdown", options = MUSIC_OPTIONS, editable = true },
		trainBinFolder = FOLDER_FIELD,
		outputDir = FOLDER_FIELD,
	},
	tooltips = {
		nbRooms = "Number of rooms in the level (seleCte --nb-rooms).",
		proba = "Layout shape (seleCte --proba): 0 attaches every room to the previous one (a corridor), "
			.. "values near 1 attach to a random earlier room (a labyrinth).",
		roomWidthTiles = "Width of every room in tiles (seleCte --room-size). All rooms share one size.",
		roomHeightTiles = "Height of every room in tiles. seleCte's default is 40x23, the modal vanilla room.",
		triesLimit = "Resamples per room on the start->end route before giving up on it (seleCte --tries-limit).",
		btDepth = "MdMC backtracking depth (seleCte --bt-depth): look this many tiles ahead before committing a tile. 0 = plain sampling.",
		resetSkeleton = "When a route room never comes out playable, throw the whole skeleton away and redraw it "
			.. "(seleCte --reset-skeleton), up to 10 times. Off: keep the unplayable room and finish.",
		seed = "Any text. The same seed and settings always produce the same level. Blank = random (the seed used is logged).",
		model = "Which trained Markov model fills the rooms: pe_d5_full = all 824 vanilla rooms (seleCte's default); "
			.. "fg_N = vanilla chapter N only; open_map = estimate a fresh model from the rooms of the open map; "
			.. "bin_folder = estimate it from every .bin in trainBinFolder (e.g. your Celeste/Content/Maps).",
		background = "Background tile layer: none, bg_N = sample it from vanilla chapter N's background model, "
			.. "or estimate one from the open map / trainBinFolder like the foreground.",
		trainBinFolder = "Folder of .bin maps to train on when model/background is bin_folder. "
			.. "Blank = the Content/Maps folder of the Celeste install Loenn is configured with (the vanilla chapters).",
		solidTileset = "Vanilla tileset the solid glyph is drawn with (1 = Dirt, as seleCte encodes it; 3 = Snow, 6 = Stone, ...).",
		output = "map = add the rooms to the open map beside its existing rooms (undoable); bin = write a standalone "
			.. "chapter to disk exactly like seleCte's data_to_level.jl, with HeartIsEnd metadata; both = do both.",
		namePrefix = "Prefix for the generated room names when adding to the open map -> selecte_room_1 ...",
		setHeartIsEnd = "When adding to the open map, also set the map's HeartIsEnd metadata so collecting the "
			.. "generated crystal heart ends the chapter. Affects the whole map and is not undone by Ctrl+Z.",
		chapterName = "Map name and .bin filename for bin output.",
		music = "Level music event for bin output. Blank = silent.",
		outputDir = "Where bin output goes. Blank = a pcg_output folder next to the open map (or next to this script).",
		verbose = "Log every room attempt, not just the summary.",
	},
}

-- =========================================================================
-- helpers
-- =========================================================================

local function scriptDir()
	local source = debug.getinfo(1, "S").source:match("^@(.*)$") or ""
	return filesystem.dirname(source)
end

-- Content/Maps of the Celeste install Loenn is configured with: the vanilla
-- chapters, seleCte's own training corpus. nil when unknown or missing.
local function defaultTrainBinFolder()
	local ok, celesteDir = pcall(fileLocations.getCelesteDir)
	if not ok or not celesteDir or celesteDir == "" then
		return nil
	end
	local mapsDir = filesystem.joinpath(celesteDir, "Content", "Maps")
	if filesystem.isDirectory(mapsDir) then
		return mapsDir
	end
	return nil
end

local function defaultOutputDir()
	local mapDir = state.filename and filesystem.dirname(state.filename)
	return filesystem.joinpath(mapDir or scriptDir(), "pcg_output")
end

local function matrixRows(tiles)
	if not tiles or not tiles.matrix then
		return nil
	end
	local w, h = tiles.matrix:size()
	local rows = {}
	for y = 1, h do
		local chars = {}
		for x = 1, w do
			chars[x] = tiles.matrix:get(x, y, "0") or "0"
		end
		rows[y] = table.concat(chars)
	end
	return rows
end

-- Loenn rooms -> the plain room tables recombine.lua reads.
local function roomsFromOpenMap(map)
	local rooms = {}
	for _, room in ipairs(map.rooms or {}) do
		local entities = {}
		for _, e in ipairs(room.entities or {}) do
			entities[#entities + 1] = {
				name = e._name, x = e.x, y = e.y, width = e.width, height = e.height, red = e.red,
			}
		end
		rooms[#rooms + 1] = {
			name = room.name,
			fgRows = matrixRows(room.tilesFg) or {},
			bgRows = matrixRows(room.tilesBg),
			entities = entities,
		}
	end
	return rooms
end

-- Every .bin directly inside `dir` -> rooms (data_loader.jl, in-process).
local function roomsFromBinFolder(dir, log)
	local packer = mods.requireFromPlugin("pcg_engine.celeste-pcg.lua.binary_packer")
	if not packer then
		error("binary_packer.lua not found under Loenn/pcg_engine/celeste-pcg/lua/")
	end
	if not dir or dir == "" then
		error("trainBinFolder is blank and the Celeste directory Loenn is configured with has no Content/Maps folder: "
			.. "set trainBinFolder to a folder of .bin maps")
	end
	if not filesystem.isDirectory(dir) then
		error("trainBinFolder is not a directory: " .. tostring(dir))
	end
	local names = {}
	for name in filesystem.listDir(dir) do
		if name:lower():match("%.bin$") then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	if #names == 0 then
		error("No .bin map found in " .. dir)
	end
	local rooms = {}
	for _, name in ipairs(names) do
		local path = filesystem.joinpath(dir, name)
		local f = io.open(path, "rb")
		if f then
			local bytes = f:read("*a")
			f:close()
			local ok, decoded = pcall(packer.decodeMap, bytes)
			if ok and decoded and decoded.root then
				local mapRooms = recombine.roomsFromMapTree(decoded.root)
				for _, r in ipairs(mapRooms) do
					r.name = name .. ":" .. r.name
					rooms[#rooms + 1] = r
				end
				log(string.format("  %s: %d rooms", name, #mapRooms))
			else
				log("  " .. name .. ": could not decode (" .. tostring(decoded) .. "), skipped")
			end
		end
	end
	return rooms
end

local function estimateFromRooms(rooms, layer, log)
	local grids, summary = recombine.buildCorpus(rooms, layer)
	local vocabulary = (layer == "bg") and alphabet.VALID_BG_TILES or alphabet.ALL_TILES_AND_ENTITIES
	local dpe, nRooms = mdmc.estimate(grids, alphabet.DEFAULT_MASK, vocabulary)
	log(string.format("Estimated a %s model: %d patterns over %d/%d rooms (%d skipped for unknown tiles, %d entities mapped)",
		layer, mdmc.patternCount(dpe), nRooms, summary.total, #summary.skipped, summary.entities))
	return dpe
end

local function resolveModel(choice, layer, sources, log)
	if choice == "none" then
		return nil
	end
	if choice == "open_map" then
		if not sources.openMap then
			sources.openMap = roomsFromOpenMap(state.map)
		end
		return estimateFromRooms(sources.openMap, layer, log)
	end
	if choice == "bin_folder" then
		if not sources.binFolder then
			log("Decoding .bin maps from " .. sources.binDir)
			sources.binFolder = roomsFromBinFolder(sources.binDir, log)
		end
		return estimateFromRooms(sources.binFolder, layer, log)
	end
	local dpe = dpeData[choice]
	if not dpe then
		error("Unknown model " .. tostring(choice))
	end
	return dpe
end

local function rowsToGrid(rows, w, h)
	local grid = pcg.newGrid(w, h, "0")
	for y = 1, h do
		local line = rows[y] or ""
		for x = 1, w do
			grid[x - 1][y - 1] = line:sub(x, x) ~= "" and line:sub(x, x) or "0"
		end
	end
	return grid
end

local function uniquePrefix(map, prefix)
	local taken = {}
	for _, room in ipairs(map.rooms or {}) do
		taken[room.name] = true
	end
	local candidate, n = prefix, 1
	while taken[candidate .. "room_1"] do
		n = n + 1
		candidate = prefix .. n .. "_"
	end
	return candidate
end

-- Where to drop the level in the open map: to the right of everything that
-- is already there, top-aligned with it (or at the origin of an empty map).
local function placementOffset(map, encodedRooms)
	local minX, minY = math.huge, math.huge
	for _, r in ipairs(encodedRooms) do
		minX = math.min(minX, r.x)
		minY = math.min(minY, r.y)
	end
	local maxRight, mapMinY = nil, nil
	for _, room in ipairs(map.rooms or {}) do
		maxRight = math.max(maxRight or -math.huge, room.x + room.width)
		mapMinY = math.min(mapMinY or math.huge, room.y)
	end
	local targetX = maxRight and (maxRight + TILE * 8) or 0
	local targetY = mapMinY or 0
	return targetX - minX, targetY - minY
end

local function quietLog(line)
	-- the per-attempt chatter of the original's INFO log, kept for --verbose
	if line:match("^room_%d+, try nb") or line:match("^Generated room_") or line:match("^Filling room_")
		or line:match("^Special point placement failed") or line:match("^A%* room playability")
		or line:match("^No success in") then
		return
	end
	pcg.log(line)
end

-- =========================================================================
-- prerun
-- =========================================================================

function script.prerun(args)
	local nbRooms = math.max(2, math.min(64, math.floor(tonumber(args.nbRooms) or 7)))
	local proba = math.max(0, math.min(1, tonumber(args.proba) or 0.3))
	local roomW = math.max(8, math.floor(tonumber(args.roomWidthTiles) or 40))
	local roomH = math.max(8, math.floor(tonumber(args.roomHeightTiles) or 23))
	local triesLimit = math.max(1, math.floor(tonumber(args.triesLimit) or 10))
	local btDepth = math.max(0, math.floor(tonumber(args.btDepth) or 0))
	local resetSkeleton = args.resetSkeleton == true
	local modelChoice = args.model or "pe_d5_full"
	local bgChoice = args.background or "none"
	local solid = alphabet.FG_TILE_NAMES[args.solidTileset] and args.solidTileset or "1"
	local output = args.output or "map"
	local prefix = (args.namePrefix and args.namePrefix ~= "") and args.namePrefix or "selecte_"
	local chapterName = (args.chapterName and args.chapterName ~= "") and args.chapterName or "SeleCteChapter"
	local music = args.music or ""
	local outDir = (args.outputDir and args.outputDir ~= "") and args.outputDir or defaultOutputDir()
	local verbose = args.verbose == true
	local log = verbose and pcg.log or quietLog

	local map = state.map
	local wantMap = output == "map" or output == "both"
	local wantBin = output == "bin" or output == "both"
	if wantMap and not map then
		pcg.log("seleCte: open a map first (or choose output = bin).")
		return nil
	end
	if (modelChoice == "open_map" or bgChoice == "open_map") and not map then
		pcg.log("seleCte: model/background = open_map needs an open map.")
		return nil
	end

	local rng = Rng.new(args.seed)
	pcg.log(string.format("seleCte: seed %q, %d rooms of %dx%d, proba %.2f, model %s, background %s",
		tostring(rng.seed), nbRooms, roomW, roomH, proba, modelChoice, bgChoice))

	-- 1. the model(s)
	local binDir = args.trainBinFolder or ""
	if binDir == "" and (modelChoice == "bin_folder" or bgChoice == "bin_folder") then
		binDir = defaultTrainBinFolder() or ""
		if binDir ~= "" then
			pcg.log("seleCte: trainBinFolder is blank, training on the vanilla chapters in " .. binDir)
		end
	end
	local sources = { binDir = binDir }
	local okModel, dpe = pcall(resolveModel, modelChoice, "fg", sources, pcg.log)
	if not okModel then
		pcg.log("seleCte: could not load the model - " .. tostring(dpe))
		return nil
	end
	local okBg, bgDpe = pcall(resolveModel, bgChoice, "bg", sources, pcg.log)
	if not okBg then
		pcg.log("seleCte: could not load the background model - " .. tostring(bgDpe))
		return nil
	end

	-- 2./3. skeleton + sampling + playability (level_generation.main)
	local t0 = os.clock()
	local okGen, skeleton, traversalPath, summary = pcall(level.generate, dpe, {
		nbRooms = nbRooms, proba = proba, roomSize = { roomW, roomH },
		btDepth = btDepth, triesLimit = triesLimit, resetSkeleton = resetSkeleton,
	}, rng, log)
	if not okGen then
		pcg.log("seleCte: generation failed - " .. tostring(skeleton))
		return nil
	end
	pcg.log(string.format("seleCte: generated %d rooms in %.1fs (%d skeleton draw%s, route %s, every route room playable: %s)",
		skeleton:getNbRooms(), os.clock() - t0, summary.redraws, summary.redraws == 1 and "" or "s",
		table.concat(traversalPath, " -> "), tostring(summary.allPlayable)))
	for _, r in ipairs(summary.rooms) do
		if #r.path > 0 then
			local holes, density, scarcity = playability.evaluateDifficulty(skeleton:getRoomByName(r.name).data, r.path, 2)
			local nle, interest, entropy = playability.evaluateInterestingness(skeleton:getRoomByName(r.name).data, r.path, 2)
			pcg.log(string.format("  %s: %d tries, playable=%s | difficulty: holes %.2f, lethal+void density %.2f, scarcity %.2f | "
				.. "interestingness: safe density %.2f, in zone %.2f, entropy %.2f",
				r.name, r.tries, tostring(r.playable), holes, density, scarcity, nle, interest, entropy))
		else
			pcg.log(string.format("  %s: %d tries, playable=%s", r.name, r.tries, tostring(r.playable)))
		end
	end

	-- optional background layer, one bg room per fg room
	local bgByName
	if bgDpe then
		bgByName = {}
		for _, name in ipairs(skeleton:listAllRooms()) do
			bgByName[name] = level.generateBackground(bgDpe, roomW, roomH, rng, btDepth)
		end
	end

	-- 4. encode (data_to_level.jl + Maple entityMap)
	local encodedRooms = encoder.encodeSkeleton(skeleton, { solid = solid }, bgByName)

	-- bin output: a standalone chapter folder, like celeste-pcg's writeMod
	if wantBin then
		local packer = mods.requireFromPlugin("pcg_engine.celeste-pcg.lua.binary_packer")
		if not packer then
			pcg.log("seleCte: binary_packer.lua missing under Loenn/pcg_engine/celeste-pcg/lua/ - skipping bin output")
		else
			local tree = encoder.buildMapTree(encodedRooms, { music = music })
			local bytes = packer.encodeMap(tree, chapterName)
			local chapterDir = filesystem.joinpath(outDir, chapterName)
			local mapsDir = filesystem.joinpath(chapterDir, "Maps")
			pcall(filesystem.mkpath, mapsDir)
			local binPath = filesystem.joinpath(mapsDir, chapterName .. ".bin")
			local f, err = io.open(binPath, "wb")
			if not f then
				pcg.log("seleCte: could not write " .. binPath .. " (" .. tostring(err) .. ")")
			else
				f:write(bytes)
				f:close()
				local y = io.open(filesystem.joinpath(chapterDir, "everest.yaml"), "wb")
				if y then
					y:write(encoder.everestYaml(chapterName))
					y:close()
				end
				pcg.log(string.format("seleCte: wrote %s (%d bytes, %d rooms, HeartIsEnd on). Drop the %s folder into Celeste/Mods.",
					binPath, #bytes, #encodedRooms, chapterName))
			end
		end
	end

	if not wantMap then
		return nil
	end

	-- map output: new rooms beside the existing ones, undoable
	local dx, dy = placementOffset(map, encodedRooms)
	local namePrefix = uniquePrefix(map, prefix)
	local built = {}
	for _, enc in ipairs(encodedRooms) do
		local room = pcg.createRoom(namePrefix .. enc.name, enc.x + dx, enc.y + dy, enc.widthTiles, enc.heightTiles)
		pcg.applyGridToRoom(room, "fg", rowsToGrid(enc.fgRows, enc.widthTiles, enc.heightTiles), enc.widthTiles, enc.heightTiles)
		if enc.bgRows then
			pcg.applyGridToRoom(room, "bg", rowsToGrid(enc.bgRows, enc.widthTiles, enc.heightTiles), enc.widthTiles, enc.heightTiles)
		end
		for _, e in ipairs(enc.entities) do
			local attrs = {}
			for k, v in pairs(e.attrs or {}) do
				attrs[k] = v
			end
			if e.width then
				attrs.width = e.width
			end
			if e.height then
				attrs.height = e.height
			end
			pcg.addEntity(room, e.name, e.x, e.y, attrs)
		end
		built[#built + 1] = room
	end

	if args.setHeartIsEnd == true and state.side then
		state.side.meta = state.side.meta or {}
		state.side.meta.mode = state.side.meta.mode or {}
		state.side.meta.mode.HeartIsEnd = true
		pcg.log("seleCte: set map metadata HeartIsEnd = true (not undone by Ctrl+Z).")
	elseif args.setHeartIsEnd ~= true then
		pcg.log("seleCte: the end room holds a crystal heart; set HeartIsEnd in the map metadata (or enable setHeartIsEnd) for it to end the chapter.")
	end

	local createdRooms = {}
	local function forward()
		createdRooms = {}
		for _, room in ipairs(built) do
			mapItemUtils.addItem(map, room, false)
			createdRooms[#createdRooms + 1] = room
		end
	end
	local function backward()
		for i = #createdRooms, 1, -1 do
			mapItemUtils.deleteRoom(map, createdRooms[i])
		end
	end

	forward()
	pcg.log(string.format("seleCte: added %d room(s) as %sroom_1 .. %sroom_%d", #built, namePrefix, namePrefix, #built))
	return snapshot.create(script.name, {}, backward, forward)
end

return script
