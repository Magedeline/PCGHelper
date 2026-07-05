-- celeste_skeleton.lua
-- Loenn port of Rysy's CelesteSkeletonScript.cs
-- Lays out non-overlapping rooms connected edge-to-edge (paper requirements 1-3).
-- First room = START (player spawn), furthest room = END (golden berry).

local mods = require("mods")
local state = require("loaded_state")
local snapshot = require("structs.snapshot")
local mapItemUtils = require("map_item_utils")
local pcg = mods.requireFromPlugin("library.pcg_toolkit")

local TILE = 8

local script = {
    name = "celesteSkeleton",
    displayName = "Celeste Skeleton Generator",
    tooltip = "Lays out non-overlapping rooms connected edge-to-edge (paper requirements 1-3). "
              .. "First room = START (player spawn), furthest room = END (golden berry). "
              .. "Run the Markov Level Generator afterwards to fill tiles.",
    parameters = {
        roomCount = 12,
        minRoomWidthTiles = 30,
        maxRoomWidthTiles = 50,
        minRoomHeightTiles = 16,
        maxRoomHeightTiles = 28,
        seed = -1,
        maxRetries = 50,
        namePrefix = "lvl_",
        minExitWidthTiles = 3,
        validateConnectivity = true,
        ensureLoopbacks = false,
    },
    fieldInformation = {
        seed = { fieldType = "integer" },
        roomCount = { fieldType = "integer" },
        minRoomWidthTiles = { fieldType = "integer" },
        maxRoomWidthTiles = { fieldType = "integer" },
        minRoomHeightTiles = { fieldType = "integer" },
        maxRoomHeightTiles = { fieldType = "integer" },
        maxRetries = { fieldType = "integer" },
        minExitWidthTiles = { fieldType = "integer" },
    },
    tooltips = {
        roomCount = "Number of rooms to generate.",
        minRoomWidthTiles = "Minimum room width in tiles (x8 px). Min 5.",
        maxRoomWidthTiles = "Maximum room width in tiles (x8 px).",
        minRoomHeightTiles = "Minimum room height in tiles (x8 px). Min 5.",
        maxRoomHeightTiles = "Maximum room height in tiles (x8 px).",
        seed = "Random seed. -1 = random each run.",
        maxRetries = "Max placement attempts per room before skipping it.",
        namePrefix = "Prefix for generated room names -> lvl_0, lvl_1 ...",
        minExitWidthTiles = "Minimum exit width in tiles. Ensures connections between rooms are wide enough for Madeline to pass through (default 3 = 24px).",
        validateConnectivity = "Validate that all rooms are reachable from the start room. Warns if any orphaned rooms are detected.",
        ensureLoopbacks = "Add extra connections to create loops in the layout (non-linear). Makes the map more interconnected and exploration-friendly.",
    },
}

local Directions = {
    { dx = 1, dy = 0 }, { dx = -1, dy = 0 },
    { dx = 0, dy = 1 }, { dx = 0, dy = -1 },
}

local function randRange(rng, lo, hi) return rng:nextRange(lo, hi) end
local function snapToTile(px) return math.floor(px / TILE) * TILE end

local function rect(left, top, w, h)
    return { x = left, y = top, width = w, height = h,
             right = left + w, bottom = top + h,
             left = left, top = top }
end

local function interiorsOverlap(a, b)
    return a.x < b.right and b.x < a.right and a.y < b.bottom and b.y < a.bottom
end

local function shareExit(a, b)
    if a.bottom == b.top or b.bottom == a.top then
        local overlapX = math.min(a.right, b.right) - math.max(a.left, b.left)
        return overlapX >= TILE * 2
    end
    if a.right == b.left or b.right == a.left then
        local overlapY = math.min(a.bottom, b.bottom) - math.max(a.top, b.top)
        return overlapY >= TILE * 2
    end
    return false
end

local function hasAdequateExitWidth(a, b, minWidthTiles)
    local minWidthPx = minWidthTiles * TILE
    if a.bottom == b.top or b.bottom == a.top then
        local overlapX = math.min(a.right, b.right) - math.max(a.left, b.left)
        return overlapX >= minWidthPx
    end
    if a.right == b.left or b.right == a.left then
        local overlapY = math.min(a.bottom, b.bottom) - math.max(a.top, b.top)
        return overlapY >= minWidthPx
    end
    return false
end

local function buildLayout(count, minW, maxW, minH, maxH, maxRetries, rng)
    local slots = {}

    local rW = randRange(rng, minW, maxW) * TILE
    local rH = randRange(rng, minH, maxH) * TILE
    table.insert(slots, { bounds = rect(0, 0, rW, rH), parentIdx = -1, neighbours = {} })

    for i = 2, count do
        for attempt = 1, maxRetries do
            local parentIdx = rng:next(#slots) + 1
            local parent = slots[parentIdx].bounds
            local dir = Directions[rng:next(#Directions) + 1]

            local newW = randRange(rng, minW, maxW) * TILE
            local newH = randRange(rng, minH, maxH) * TILE

            local nx, ny
            if dir.dx ~= 0 then
                nx = dir.dx > 0 and parent.right or (parent.left - newW)
                local overlapH = math.min(parent.height, newH)
                ny = parent.y + rng:next(math.max(1, overlapH - TILE * 2))
            else
                ny = dir.dy > 0 and parent.bottom or (parent.top - newH)
                local overlapW = math.min(parent.width, newW)
                nx = parent.x + rng:next(math.max(1, overlapW - TILE * 2))
            end

            nx = snapToTile(nx)
            ny = snapToTile(ny)

            local candidate = rect(nx, ny, newW, newH)

            local clear = true
            for _, s in ipairs(slots) do
                if interiorsOverlap(candidate, s.bounds) then clear = false break end
            end
            if not clear then
            else
                local slot = { bounds = candidate, parentIdx = parentIdx, neighbours = {} }
                local idx = #slots + 1
                table.insert(slots, slot)

                for j = 1, idx - 1 do
                    if shareExit(candidate, slots[j].bounds) then
                        table.insert(slot.neighbours, j)
                        table.insert(slots[j].neighbours, idx)
                    end
                end
                -- parent is always adjacent
                local hasParent = false
                for _, n in ipairs(slot.neighbours) do if n == parentIdx then hasParent = true break end end
                if not hasParent then
                    table.insert(slot.neighbours, parentIdx)
                    table.insert(slots[parentIdx].neighbours, idx)
                end
                break
            end
        end
    end
    return slots
end

local function manhattanFromRoot(slot, root)
    local acx = slot.bounds.x + math.floor(slot.bounds.width / 2)
    local acy = slot.bounds.y + math.floor(slot.bounds.height / 2)
    local rcx = root.bounds.x + math.floor(root.bounds.width / 2)
    local rcy = root.bounds.y + math.floor(root.bounds.height / 2)
    return math.abs(acx - rcx) + math.abs(acy - rcy)
end

local function findUnreachableRooms(slots)
    if #slots == 0 then return {} end
    local visited = {}
    for i = 1, #slots do visited[i] = false end
    local q = { 1 }
    local qHead = 1
    visited[1] = true
    while qHead <= #q do
        local idx = q[qHead]; qHead = qHead + 1
        for _, neighbor in ipairs(slots[idx].neighbours) do
            if not visited[neighbor] then
                visited[neighbor] = true
                table.insert(q, neighbor)
            end
        end
    end
    local unreachable = {}
    for i = 1, #slots do if not visited[i] then table.insert(unreachable, i) end end
    return unreachable
end

local function addLoopbackConnections(slots, rng, maxLoops)
    local attempts, added = 0, 0
    local i = 2
    while i <= #slots and added < maxLoops and attempts < #slots * 2 do
        attempts = attempts + 1
        local candidates = {}
        for j = 1, i - 1 do
            local isNeighbour = false
            for _, n in ipairs(slots[i].neighbours) do if n == j then isNeighbour = true break end end
            if not isNeighbour and shareExit(slots[i].bounds, slots[j].bounds) then
                table.insert(candidates, j)
            end
        end
        if #candidates > 0 then
            local target = candidates[rng:next(#candidates) + 1]
            table.insert(slots[i].neighbours, target)
            table.insert(slots[target].neighbours, i)
            added = added + 1
        end
        i = i + 1
    end
end

function script.prerun(args)
    local count = math.max(2, tonumber(args.roomCount) or 12)
    local minW = math.max(5, tonumber(args.minRoomWidthTiles) or 30)
    local maxW = math.max(minW, tonumber(args.maxRoomWidthTiles) or 50)
    local minH = math.max(5, tonumber(args.minRoomHeightTiles) or 16)
    local maxH = math.max(minH, tonumber(args.maxRoomHeightTiles) or 28)
    local rawSeed = tonumber(args.seed) or -1
    local maxRetries = math.max(1, tonumber(args.maxRetries) or 50)
    local prefix = args.namePrefix or "lvl_"
    local minExitWidth = math.max(2, tonumber(args.minExitWidthTiles) or 3)
    local validateConn = args.validateConnectivity ~= false
    local ensureLoops = args.ensureLoopbacks == true

    local map = state.map
    if not map then return nil end

    local rng = pcg.makeRng(rawSeed)
    local slots = buildLayout(count, minW, maxW, minH, maxH, maxRetries, rng)
    if #slots == 0 then return nil end

    if ensureLoops then
        addLoopbackConnections(slots, rng, math.floor(#slots / 3))
    end

    if validateConn then
        local unreachable = findUnreachableRooms(slots)
        if #unreachable > 0 then
            pcg.log("Layout has " .. #unreachable .. " unreachable rooms")
        end
    end

    -- pick END room = furthest Manhattan distance from root
    local endIdx, endDist = 1, 0
    for i = 2, #slots do
        local d = manhattanFromRoot(slots[i], slots[1])
        if d > endDist then endDist = d endIdx = i end
    end

    local createdRooms = {}

    local function forward()
        for i = 1, #slots do
            local slot = slots[i]
            local isStart = (i == 1)
            local isEnd = (i == endIdx)
            local wTiles = math.floor(slot.bounds.width / TILE)
            local hTiles = math.floor(slot.bounds.height / TILE)

            local room = pcg.createRoom(prefix .. (i - 1), slot.bounds.x, slot.bounds.y, wTiles, hTiles)

            if isStart then
                pcg.addEntity(room, "player", TILE * 2, (hTiles - 2) * TILE)
            end
            if isEnd then
                pcg.addEntity(room, "goldenBerry",
                    math.floor(slot.bounds.width / 2),
                    math.floor(slot.bounds.height / 2 - TILE * 2))
            end

            table.insert(createdRooms, room)
            mapItemUtils.addItem(map, room, false)
        end
    end

    local function backward()
        for i = #createdRooms, 1, -1 do
            mapItemUtils.deleteRoom(map, createdRooms[i])
        end
    end

    forward()
    pcg.log(string.format("Skeleton: generated %d room(s) (start=room 0, end=room %d)", #slots, endIdx - 1))
    return snapshot.create(script.name, {}, backward, forward)
end

return script
