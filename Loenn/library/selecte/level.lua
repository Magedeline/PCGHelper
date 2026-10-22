-- level.lua - the online generation step: a skeleton filled with sampled tiles.
--
-- Lua port of pcg/level_generation.py plus utils.generate_temp_room from
-- https://github.com/robilouis/seleCte (MIT).
--
-- A sampled room is not guaranteed usable, so generation retries at three
-- nested levels, every loop bounded:
--   * special points - a start/end room is resampled until its spawn or
--     crystal heart fits (MAX_ROOM_RESAMPLES);
--   * room - a room on the traversal path must be crossable by A*, and is
--     resampled up to `triesLimit` times;
--   * skeleton - with `resetSkeleton`, a room that never comes out playable
--     throws the whole level away and redraws it (MAX_SKELETON_REDRAWS).
-- Only rooms on the start->end route are held to the check; side branches
-- are filled once.
--
-- One deliberate deviation. The Python's `extract_room_path` returns nothing
-- for a room with fewer than two exits, so `is_playable_room` is False for
-- every such room - and the end room of a tree-shaped skeleton always has
-- exactly one exit (the start room usually does too). The original therefore
-- never accepts its own start/end rooms, exhausts every retry, and with
-- --reset-skeleton redraws ten levels for nothing; its source carries a TODO
-- to "adapt is playable to 1-exit rooms". Here a start/end room with a single
-- exit counts as playable once its special point has been placed, because
-- `add_special_points` only accepts a point that A* connects to every exit -
-- which for one exit is exactly the crossing that would otherwise be checked.

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
local skeletonLib = req("skeleton")
local playability = req("playability")

local M = {}

M.MAX_ROOM_RESAMPLES = 10
M.MAX_SKELETON_REDRAWS = 10
M.DEFAULT_ROOM_SIZE = { 40, 23 }

local function noop() end

-- generate_temp_room: samples one room and fits it to the slot a skeleton
-- reserved for it - exits carved back in, respawn points added.
function M.generateTempRoom(room, dpe, btDepth, rng, log)
	local w, h = room.size[1], room.size[2]
	local temp = skeletonLib.Room.new(w, h, 0, 0, room.status)
	temp:setData(mdmc.generateRoomData(dpe, w, h, rng, { btDepth = btDepth }))
	temp:setOrigin(room.origin[1], room.origin[2])
	temp:setExits(room:copyExits())
	temp:createExitsInMatrix()
	temp:addRespawnPoints()
	return temp
end

-- fill_room: samples a room's tiles, resampling until its special point
-- fits. Returns the detached room and whether the special point was placed
-- (always true for a room that is neither start nor end).
function M.fillRoom(room, dpe, opts, rng, log)
	log = log or noop
	local temp = room
	for attempt = 1, M.MAX_ROOM_RESAMPLES do
		temp = M.generateTempRoom(room, dpe, opts.btDepth or 0, rng, log)
		if temp:addSpecialPoints(opts.triesLimit or 10, rng, playability, log) then
			return temp, true
		end
		log(string.format("Special point placement failed, resample %d.", attempt))
	end
	log(string.format("No special point placed in %d resamples - keeping the last attempt.", M.MAX_ROOM_RESAMPLES))
	return temp, false
end

-- fill_traversal_path: fills the rooms a run must cross, resampling each
-- until it is playable. The latest attempt is written back either way.
-- Returns whether every room on the path came out playable; `report`
-- collects per-room {name, tries, playable, path} for the caller's log.
function M.fillTraversalPath(skeleton, traversalPath, dpe, opts, rng, log, report)
	log = log or noop
	local allPlayable = true
	for _, roomName in ipairs(traversalPath) do
		local room = skeleton:getRoomByName(roomName)
		local isPlayable, tries, path = false, 0, {}
		while not isPlayable and tries < (opts.triesLimit or 10) do
			tries = tries + 1
			log(string.format("%s, try nb %d", roomName, tries))
			local temp, specialPlaced = M.fillRoom(room, dpe, opts, rng, log)
			local ok = false
			if specialPlaced then
				local exitPoints = temp:getStartingEndingPoints()
				if #exitPoints < 2 and temp.status and temp.specialPoint and #exitPoints == 1 then
					-- single-exit start/end room: the special point reaches the
					-- exit (see the module comment); keep that path for metrics
					path = playability.astar(temp.data, temp:extractAstarReadyData(), temp.specialPoint, exitPoints[1], rng)
					ok = #path > 0
				else
					ok, path = playability.isPlayableRoom(temp, 0, rng, log)
				end
			end
			isPlayable = specialPlaced and ok
			room:setData(temp.data)
		end
		if report then
			report[#report + 1] = { name = roomName, tries = tries, playable = isPlayable, path = path }
		end
		if not isPlayable then
			allPlayable = false
			log(string.format("%s generation failed in %d tries.", roomName, tries))
			if opts.resetSkeleton then
				return false
			end
		else
			log(string.format("Generated %s in %d iterations.", roomName, tries))
		end
	end
	return allPlayable
end

-- main: draws and fills skeletons until the traversal path is playable.
--
-- opts: { nbRooms, proba, roomSize = {w, h}, btDepth, triesLimit, resetSkeleton }
-- Returns the skeleton (formatted: borders + exits), the traversal path, and
-- a summary { redraws, allPlayable, rooms = {{name, tries, playable, path}} }.
function M.generate(dpe, opts, rng, log)
	log = log or noop
	opts = opts or {}
	local nbRooms = opts.nbRooms or 7
	local roomSize = opts.roomSize or M.DEFAULT_ROOM_SIZE

	local skeleton, traversalPath
	local summary = { redraws = 0, allPlayable = false, rooms = {} }

	for redraw = 1, M.MAX_SKELETON_REDRAWS do
		summary.redraws = redraw
		summary.rooms = {}
		log("Generating new level skeleton...")
		skeleton = skeletonLib.generateCeleskeleton(nbRooms, opts.proba or 0.5, roomSize, rng)
		traversalPath = skeleton:getTraversalPath()
		log(string.format("Traversal path, %d of %d rooms: %s",
			#traversalPath, nbRooms, table.concat(traversalPath, " -> ")))

		if M.fillTraversalPath(skeleton, traversalPath, dpe, opts, rng, log, summary.rooms) then
			summary.allPlayable = true
			break
		end
		if not opts.resetSkeleton then
			log("Pursuing generation with an unplayable room.")
			break
		end
		if redraw == M.MAX_SKELETON_REDRAWS then
			log(string.format("%d skeletons in a row had a room that never came out playable - "
				.. "keeping the last one. The level is very likely not completable.", M.MAX_SKELETON_REDRAWS))
			break
		end
		log("Re-generating a skeleton.")
	end

	local onPath = {}
	for _, name in ipairs(traversalPath) do
		onPath[name] = true
	end
	for _, name in ipairs(skeleton:listAllRooms()) do
		if not onPath[name] then
			log(string.format("Filling %s, off the traversal path.", name))
			local room = skeleton:getRoomByName(name)
			local filled = M.fillRoom(room, dpe, opts, rng, log)
			room:setData(filled.data)
		end
	end

	skeleton:formatFilled()
	return skeleton, traversalPath, summary
end

-- Background layer for one room, sampled from a background dict (the
-- `rooms_generation --layer bg` path: void border, VALID_BG_TILES fallback).
function M.generateBackground(bgDpe, width, height, rng, btDepth)
	return mdmc.generateRoomData(bgDpe, width, height, rng, {
		btDepth = btDepth or 0,
		allSymbols = alphabet.VALID_BG_TILES,
		border = alphabet.VOID,
	})
end

return M
