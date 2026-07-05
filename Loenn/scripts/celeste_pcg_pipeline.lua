-- celeste_pcg_pipeline.lua
-- Loenn port of Rysy's CelestePCGPipelineScript.cs
-- End-to-end PCG: skeleton generation -> MdMC/WFC tile filling -> playability
-- repair -> entity placement -> (optional) CelesteRandomizer YAML export.
-- Combines the skeleton + markov scripts into a single one-shot generator.

local mods = require("mods")
local state = require("loaded_state")
local snapshot = require("structs.snapshot")
local mapItemUtils = require("map_item_utils")
local filesystem = require("utils.filesystem")
local pcg = mods.requireFromPlugin("library.pcg_toolkit")
local unity = mods.requireFromPlugin("library.pcg_unity_generators")

local TILE = 8

local script = {
    name = "celestePCGPipeline",
    displayName = "Celeste PCG Pipeline",
    tooltip = "End-to-end PCG: skeleton layout -> MdMC/WFC tile filling -> playability repair -> entity placement. "
              .. "Combines the skeleton + Markov scripts into a single one-shot generator.",
    parameters = {
        -- Skeleton
        roomCount = 8,
        roomWidthTiles = 40,
        roomHeightTiles = 23,
        proba = 0.5,
        carveExits = true,
        resetSkeleton = false,

        -- Training
        trainSource = "all_rooms",
        configuration = "000011012",
        generationMode = "mdmc",
        tilesetEra = "new",

        -- MdMC
        maxBacktrackDepth = 8,
        triesLimit = 20,
        seed = -1,

        -- Scoring
        w1 = 1.0, w2 = 1.0, w3 = 1.0, minInterestingness = 0.0,
        z1 = 1.0, z2 = 1.0, z3 = 1.0, numPaths = 5,

        -- Playability + entities
        ensurePlayable = true,
        placeEntities = true,
        namePrefix = "gen_",

        -- CelesteRandomizer metadata export
        exportRandoYaml = false,
        randoOutputPath = "rando.yaml",

        -- Tileset improvements
        autoTile = true,
        preserveExits = true,
        generateBG = false,
        useEnhancedBG = false,
        cleanupPasses = 2,
        hazardDensity = 0.05,
        springDensity = 0.02,
        usePatternMode = false,
        difficulty = 3,

        -- Unity procedural generator settings
        unityModifier = 0.1,
        unityFloorPercent = 45,
        unityBirthLimit = 4,
        unityDeathLimit = 3,
        unityPasses = 4,
        unityInitialDensity = 0.45,

        -- Smart placement
        placementMode = "smart",
        placeDecals = true,
        placeTriggers = true,
        decalDensity = 0.12,
        triggerMode = "camera",
    },
    fieldInformation = {
        roomCount = { fieldType = "integer" },
        roomWidthTiles = { fieldType = "integer" },
        roomHeightTiles = { fieldType = "integer" },
        trainSource = { fieldType = "loennScripts.dropdown", options = { "all_rooms", "current_room" }, editable = false },
        configuration = { fieldType = "loennScripts.dropdown", options = (function()
            local opts = {}
            for k, _ in pairs(pcg.MdmcPresets) do table.insert(opts, k) end
            table.sort(opts)
            return opts
        end)(), editable = true },
        generationMode = { fieldType = "loennScripts.dropdown", options = { "mdmc", "wfc", "hybrid", "perlin_top", "perlin_cave", "randomwalk_cave", "directional_tunnel", "cellular" }, editable = false },
        tilesetEra = { fieldType = "loennScripts.dropdown", options = { "new", "old", "mixed", "trained" }, editable = false },
        placementMode = { fieldType = "loennScripts.dropdown", options = { "smart", "legacy" }, editable = false },
        triggerMode = { fieldType = "loennScripts.dropdown", options = { "camera", "spawn", "all", "none" }, editable = false },
        maxBacktrackDepth = { fieldType = "integer" },
        triesLimit = { fieldType = "integer" },
        seed = { fieldType = "integer" },
        numPaths = { fieldType = "integer" },
        cleanupPasses = { fieldType = "integer" },
        difficulty = { fieldType = "integer" },
        unityModifier = { fieldType = "number" },
        unityFloorPercent = { fieldType = "integer" },
        unityBirthLimit = { fieldType = "integer" },
        unityDeathLimit = { fieldType = "integer" },
        unityPasses = { fieldType = "integer" },
        unityInitialDensity = { fieldType = "number" },
    },
    tooltips = {
        roomCount = "Number of rooms to generate in the skeleton.",
        roomWidthTiles = "Width of every room in tiles (x8 px).",
        roomHeightTiles = "Height of every room in tiles (x8 px).",
        proba = "Skeleton pathway/labyrinth parameter (paper §CLI -p). 0 = pathway (chain), 1 = labyrinth (random attach), 0.5 = balanced.",
        carveExits = "Carve aligned 2x3 / 3x2 doorways between adjacent skeleton rooms so the map is actually traversable.",
        resetSkeleton = "Rebuild the skeleton if no acceptable tile layout is produced (paper §CLI -r).",
        trainSource = "Which rooms to train the MdMC on.",
        configuration = "3x3 configuration matrix (row-major).",
        generationMode = "MdMC, WFC, Hybrid, or Unity procedural seeds (Perlin / Random Walk / Cellular / Tunnel).",
        tilesetEra = "Which tileset era to use: new, old, a 50/50 mix, or whatever the training rooms already contain.",
        maxBacktrackDepth = "Maximum tiles to backtrack when an unseen n-gram is encountered.",
        triesLimit = "Full-room generation retries per room before accepting the best candidate.",
        seed = "Random seed. -1 = random each run.",
        w1 = "Weight for global NLE density in interestingness I (§4.2).",
        w2 = "Weight for local NLE density (AOI) in interestingness I (§4.2).",
        w3 = "Weight for NLE diversity (Shannon entropy) in interestingness I (§4.2).",
        minInterestingness = "Minimum interestingness I required to accept a generated room. 0 = accept any.",
        z1 = "Weight for hole frequency Hf in difficulty D (§4.3).",
        z2 = "Weight for local LE density in difficulty D (§4.3).",
        z3 = "Weight for NLE scarcity in difficulty D (§4.3).",
        numPaths = "Number of BFS paths to sample for path variance analysis (§4.1).",
        ensurePlayable = "Platformer repair pass: verifies reachability and carves corridors / stepping-stones.",
        placeEntities = "Place player spawn, strawberries, golden berry and spikes after tile generation.",
        namePrefix = "Prefix for generated room names -> gen_0, gen_1 ...",
        exportRandoYaml = "Write a .rando.yaml compatible with CelesteRandomizer after generation.",
        randoOutputPath = "Path for the .rando.yaml output (relative to the map file's directory).",
        autoTile = "Auto-tiling pass: blends tile edges for smooth transitions.",
        preserveExits = "Smart borders: preserve existing room exits/connections.",
        generateBG = "Also generate background tiles based on foreground layout.",
        useEnhancedBG = "Enhanced background: style-aware BG with depth-appropriate fill.",
        cleanupPasses = "Number of cleanup passes to remove isolated tiles and fill holes.",
        hazardDensity = "Density of hazards (spikes) to place on walkable surfaces (0-1).",
        springDensity = "Density of springs to place in vertical passages (0-1).",
        usePatternMode = "Pattern mode: extract and stitch patterns from training data.",
        difficulty = "Difficulty level (1-5) for pattern mode generation.",
        unityModifier = "Perlin cave modifier (0.01-0.5). Higher = messier / more fragmented.",
        unityFloorPercent = "Random-walk cave: target percentage of open floor cells.",
        unityBirthLimit = "Cellular automata: neighbour count that turns air into solid.",
        unityDeathLimit = "Cellular automata: neighbour count below which solid becomes air.",
        unityPasses = "Cellular automata: number of smoothing passes.",
        unityInitialDensity = "Cellular automata: initial chance of a solid cell (0-1).",
        placementMode = "Smart: precision placement of entities/decals/triggers using spatial analysis. Legacy: old random shuffle.",
        placeDecals = "Place background and foreground decals based on room geometry.",
        placeTriggers = "Place camera / spawn triggers based on room geometry.",
        decalDensity = "Density of decals (0-1). Higher = more decals.",
        triggerMode = "Trigger placement mode: camera targets for vertical areas, spawn points for safe floors, all, or none.",
    },
}

-- =========================================================================
-- Skeleton (paper §CLI -p: pathway <-> labyrinth)
-- =========================================================================
local CardinalDirs = {
    { dx = 1, dy = 0 }, { dx = -1, dy = 0 },
    { dx = 0, dy = 1 }, { dx = 0, dy = -1 },
}

local function interiorsOverlap(a, b)
    return a.x < b.right and b.x < a.right and a.y < b.bottom and b.y < a.bottom
end

local function shareExit(a, b)
    if a.bottom == b.top or b.bottom == a.top then
        return math.min(a.right, b.right) - math.max(a.left, b.left) >= TILE * 2
    end
    if a.right == b.left or b.right == a.left then
        return math.min(a.bottom, b.bottom) - math.max(a.top, b.top) >= TILE * 2
    end
    return false
end

local function rect(left, top, w, h)
    return { x = left, y = top, width = w, height = h,
             right = left + w, bottom = top + h, left = left, top = top }
end

local function buildSkeleton(count, roomW, roomH, proba, maxRetries, rng)
    local slots = {}
    table.insert(slots, { bounds = rect(0, 0, roomW, roomH), parentIdx = -1, neighbours = {} })

    for i = 2, count do
        local placed = false
        for attempt = 1, maxRetries do
            if placed then break end

            local parentIdx
            if rng:nextDouble() < proba then
                parentIdx = rng:next(#slots) + 1
            else
                parentIdx = #slots
            end

            local parent = slots[parentIdx].bounds
            local dir = CardinalDirs[rng:next(#CardinalDirs) + 1]

            local nx, ny
            if dir.dx ~= 0 then
                nx = dir.dx > 0 and parent.right or (parent.left - roomW)
                ny = parent.y + rng:next(math.max(1, parent.height - TILE * 2))
            else
                ny = dir.dy > 0 and parent.bottom or (parent.top - roomH)
                nx = parent.x + rng:next(math.max(1, parent.width - TILE * 2))
            end

            nx = math.floor(nx / TILE) * TILE
            ny = math.floor(ny / TILE) * TILE

            local candidate = rect(nx, ny, roomW, roomH)

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
                local hasParent = false
                for _, n in ipairs(slot.neighbours) do if n == parentIdx then hasParent = true break end end
                if not hasParent then
                    table.insert(slot.neighbours, parentIdx)
                    table.insert(slots[parentIdx].neighbours, idx)
                end
                placed = true
            end
        end
    end
    return slots
end

local function furthestFrom(slots, origin)
    local best, bestDist = 1, 0
    local ocx = slots[origin].bounds.x + math.floor(slots[origin].bounds.width / 2)
    local ocy = slots[origin].bounds.y + math.floor(slots[origin].bounds.height / 2)
    for i = 2, #slots do
        local cx = slots[i].bounds.x + math.floor(slots[i].bounds.width / 2)
        local cy = slots[i].bounds.y + math.floor(slots[i].bounds.height / 2)
        local d = math.abs(cx - ocx) + math.abs(cy - ocy)
        if d > bestDist then bestDist = d best = i end
    end
    return best
end

-- =========================================================================
-- Exit carving
-- =========================================================================
local function carveDoorHorizontal(tiles, w, h, xStart, doorTop, solid)
    doorTop = math.max(1, math.min(h - 4, doorTop))
    for x = xStart, xStart + 1 do
        if x >= 0 and x < w then
            for dy = 0, 2 do tiles[x][doorTop + dy] = "0" end
            tiles[x][doorTop + 3] = solid
        end
    end
end

local function carveDoorVertical(tiles, w, h, yStart, doorLeft)
    doorLeft = math.max(1, math.min(w - 4, doorLeft))
    for y = yStart, yStart + 1 do
        if y >= 0 and y < h then
            for dx = 0, 2 do tiles[doorLeft + dx][y] = "0" end
        end
    end
end

local function carveSharedExit(roomA, roomB, solid)
    local aw = math.floor(roomA.width / TILE)
    local ah = math.floor(roomA.height / TILE)
    local bw = math.floor(roomB.width / TILE)
    local bh = math.floor(roomB.height / TILE)
    if aw < 5 or ah < 6 or bw < 5 or bh < 6 then return end

    local a, b = roomA, roomB
    local aW, aH, bW, bH = aw, ah, bw, bh

    -- horizontal adjacency: normalise so a is the left room
    if b.x + b.width == a.x then
        a, b = b, a
        aW, aH, bW, bH = bW, bH, aW, aH
    end
    if a.x + a.width == b.x then
        local loPx = math.max(a.y, b.y)
        local hiPx = math.min(a.y + a.height, b.y + b.height)
        local span = math.floor((hiPx - loPx) / TILE)
        if span < 5 then return end

        local doorTop = math.max(
            math.floor(loPx / TILE) + 1,
            math.min(math.floor(hiPx / TILE) - 4,
                     math.floor(hiPx / TILE) - 5))

        local aFg = pcg.tilesStructToGrid(a.tilesFg)
        local bFg = pcg.tilesStructToGrid(b.tilesFg)
        if aFg and bFg then
            carveDoorHorizontal(aFg, aW, aH, aW - 2, doorTop - math.floor(a.y / TILE), solid)
            carveDoorHorizontal(bFg, bW, bH, 0, doorTop - math.floor(b.y / TILE), solid)
            pcg.applyGridToRoom(a, "fg", aFg, aW, aH)
            pcg.applyGridToRoom(b, "fg", bFg, bW, bH)
        end
        return
    end

    -- vertical adjacency: normalise so a is the upper room
    if b.y + b.height == a.y then
        a, b = b, a
        aW, aH, bW, bH = bW, bH, aW, aH
    end
    if a.y + a.height == b.y then
        local loPx = math.max(a.x, b.x)
        local hiPx = math.min(a.x + a.width, b.x + b.width)
        local span = math.floor((hiPx - loPx) / TILE)
        if span < 5 then return end

        local doorLeft = math.max(
            math.floor(loPx / TILE) + 1,
            math.min(math.floor(hiPx / TILE) - 4,
                     math.floor((loPx + hiPx) / 2 / TILE) - 1))

        local aFg = pcg.tilesStructToGrid(a.tilesFg)
        local bFg = pcg.tilesStructToGrid(b.tilesFg)
        if aFg and bFg then
            carveDoorVertical(aFg, aW, aH, aH - 2, doorLeft - math.floor(a.x / TILE))
            carveDoorVertical(bFg, bW, bH, 0, doorLeft - math.floor(b.x / TILE))
            pcg.applyGridToRoom(a, "fg", aFg, aW, aH)
            pcg.applyGridToRoom(b, "fg", bFg, bW, bH)
        end
    end
end

-- =========================================================================
-- Rando YAML export
-- =========================================================================
local function roomHasMatchingHole(allRooms, room, side, lo, hi, minWidth)
    local oppSide = ({ Up = "Down", Down = "Up", Left = "Right", Right = "Left" })[side] or "Up"

    local worldLo, worldHi
    if side == "Up" or side == "Down" then
        worldLo = room.x + lo * TILE
        worldHi = room.x + hi * TILE + TILE - 1
    else
        worldLo = room.y + lo * TILE
        worldHi = room.y + hi * TILE + TILE - 1
    end

    for _, other in ipairs(allRooms) do
        if other ~= room then
            local adjacent = false
            if side == "Up" then adjacent = (other.y + other.height == room.y)
            elseif side == "Down" then adjacent = (room.y + room.height == other.y)
            elseif side == "Left" then adjacent = (other.x + other.width == room.x)
            elseif side == "Right" then adjacent = (room.x + room.width == other.x) end
            if not adjacent then
            else
                local ot = pcg.tilesStructToGrid(other.tilesFg)
                if ot then
                    local ow = math.floor(other.width / TILE)
                    local oh = math.floor(other.height / TILE)
                    local oLen = (oppSide == "Up" or oppSide == "Down") and ow or oh
                    local runStart = -1
                    for k = 0, oLen do
                        local t = "3"
                        if k < oLen then
                            if oppSide == "Up" then t = ot[k][0] or "3"
                            elseif oppSide == "Down" then t = ot[k][oh - 1] or "3"
                            elseif oppSide == "Left" then t = ot[0][k] or "3"
                            elseif oppSide == "Right" then t = ot[ow - 1][k] or "3" end
                        end
                        if t == "0" then
                            if runStart < 0 then runStart = k end
                        elseif runStart >= 0 then
                            if k - runStart >= minWidth then
                                local owLo, owHi
                                if oppSide == "Up" or oppSide == "Down" then
                                    owLo = other.x + runStart * TILE
                                    owHi = other.x + (k - 1) * TILE + TILE - 1
                                else
                                    owLo = other.y + runStart * TILE
                                    owHi = other.y + (k - 1) * TILE + TILE - 1
                                end
                                if owLo <= worldHi and owHi >= worldLo then return true end
                            end
                            runStart = -1
                        end
                    end
                end
            end
        end
    end
    return false
end

local function exportRandoYaml(rooms, outputPath, mapFilename, endIdx)
    local minHoleWidth = 2
    local refDiag = 46.15

    local lines = {}
    table.insert(lines, "# Generated by Loenn PCG Pipeline - CelesteRandomizer metadata")
    table.insert(lines, "# https://github.com/rhelmot/CelesteRandomizer/blob/master/docs/metadata.md")
    table.insert(lines, "")
    table.insert(lines, "ASide:")

    for i, room in ipairs(rooms) do
        local w = math.floor(room.width / TILE)
        local h = math.floor(room.height / TILE)
        local tiles = pcg.tilesStructToGrid(room.tilesFg)
        local worth = math.floor((math.sqrt(w * w + h * h) / refDiag) * 100 + 0.5) / 100
        local isEnd = (i - 1) == endIdx

        table.insert(lines, string.format('- Room: "%s"', room.name))
        table.insert(lines, string.format("  Worth: %.2f", worth))
        if isEnd then table.insert(lines, "  End: true") end

        if tiles then
            local anyHole = false
            local sides = { "Up", "Down", "Left", "Right" }
            local holeIdx = 0
            for _, side in ipairs(sides) do
                local len = (side == "Up" or side == "Down") and w or h
                local runStart = -1

                local function flushRun(runEnd)
                    if runStart < 0 or runEnd - runStart < minHoleWidth then return end
                    if not anyHole then table.insert(lines, "  Holes:") anyHole = true end

                    local shared = roomHasMatchingHole(rooms, room, side, runStart, runEnd - 1, minHoleWidth)
                    local kind = shared and "inout" or "out"

                    table.insert(lines, "  - Side: " .. side)
                    table.insert(lines, "    Idx: " .. holeIdx)
                    table.insert(lines, "    Kind: " .. kind)
                    table.insert(lines, "    LowBound: " .. runStart)
                    table.insert(lines, "    HighBound: " .. (runEnd - 1))
                    holeIdx = holeIdx + 1
                end

                for k = 0, len - 1 do
                    local t = "3"
                    if side == "Up" then t = tiles[k][0] or "3"
                    elseif side == "Down" then t = tiles[k][h - 1] or "3"
                    elseif side == "Left" then t = tiles[0][k] or "3"
                    elseif side == "Right" then t = tiles[w - 1][k] or "3" end
                    if t == "0" then
                        if runStart < 0 then runStart = k end
                    else
                        flushRun(k)
                        runStart = -1
                    end
                end
                flushRun(len)
            end
        end

        -- Collectables
        local berries = {}
        for _, e in ipairs(room.entities or {}) do
            if e._name == "strawberry" or e._name == "goldenBerry" then
                table.insert(berries, e)
            end
        end
        table.sort(berries, function(a, b) return (a.x or 0) < (b.x or 0) end)
        if #berries > 0 then
            table.insert(lines, "  Collectables:")
            for bi = 1, #berries do
                table.insert(lines, string.format("  - Idx: %d", bi - 1))
            end
        end

        table.insert(lines, "")
    end

    local content = table.concat(lines, "\n")

    -- Try to write next to the map file
    local fullPath = outputPath
    local mapPath = mapFilename
    if mapPath and not string.match(outputPath, "^[/\\]") and not string.match(outputPath, "^%a:[/\\]") then
        local dir = filesystem.dirname(mapPath) or ""
        fullPath = filesystem.joinpath(dir, outputPath)
    end

    -- Create parent directory if needed
    local parentDir = filesystem.dirname(fullPath)
    if parentDir and parentDir ~= "" then
        pcall(filesystem.mkpath, parentDir)
    end

    local ok, err = pcall(function()
        local fh = io.open(fullPath, "w")
        if fh then
            fh:write(content)
            fh:close()
        else
            error("Could not open file for writing: " .. fullPath)
        end
    end)
    if ok then
        pcg.log("Wrote rando metadata -> " .. fullPath)
    else
        pcg.log("Failed to write rando YAML: " .. tostring(err))
    end
end

-- =========================================================================
-- Main pipeline
-- =========================================================================
function script.prerun(args)
    local config        = args.configuration or "000011012"
    local trainSource   = args.trainSource or "all_rooms"
    local roomCount     = math.max(2, tonumber(args.roomCount) or 8)
    local proba         = math.max(0, math.min(1, tonumber(args.proba) or 0.5))
    local roomW         = math.max(10, tonumber(args.roomWidthTiles) or 40) * TILE
    local roomH         = math.max(5, tonumber(args.roomHeightTiles) or 23) * TILE
    local btDepth       = math.max(1, tonumber(args.maxBacktrackDepth) or 8)
    local triesLimit    = math.max(1, tonumber(args.triesLimit) or 20)
    local resetSkeleton = args.resetSkeleton == true
    local w1            = tonumber(args.w1) or 1.0
    local w2            = tonumber(args.w2) or 1.0
    local w3            = tonumber(args.w3) or 1.0
    local minI          = tonumber(args.minInterestingness) or 0.0
    local z1            = tonumber(args.z1) or 1.0
    local z2            = tonumber(args.z2) or 1.0
    local z3            = tonumber(args.z3) or 1.0
    local numPaths      = math.max(1, tonumber(args.numPaths) or 5)
    local rawSeed       = tonumber(args.seed) or -1
    local prefix        = args.namePrefix or "gen_"
    local placeEnts     = args.placeEntities ~= false

    local autoTile      = args.autoTile ~= false
    local preserveExits = args.preserveExits ~= false
    local generateBG    = args.generateBG == true
    local useEnhancedBG = args.useEnhancedBG == true
    local cleanupPasses = math.max(0, tonumber(args.cleanupPasses) or 2)
    local hazardDensity = math.max(0, math.min(1, tonumber(args.hazardDensity) or 0.05))
    local springDensity = math.max(0, math.min(1, tonumber(args.springDensity) or 0.02))
    local usePatternMode = args.usePatternMode == true
    local difficulty    = math.max(1, math.min(5, tonumber(args.difficulty) or 3))

    local generationMode = args.generationMode or "mdmc"
    local tilesetEra     = args.tilesetEra or "new"
    local ensurePlayable = args.ensurePlayable ~= false
    local carveExits     = args.carveExits ~= false

    local unityModifier       = math.max(0.001, math.min(1.0, tonumber(args.unityModifier) or 0.1))
    local unityFloorPercent   = math.max(0, math.min(100, tonumber(args.unityFloorPercent) or 45))
    local unityBirthLimit     = math.max(0, tonumber(args.unityBirthLimit) or 4)
    local unityDeathLimit     = math.max(0, tonumber(args.unityDeathLimit) or 3)
    local unityPasses         = math.max(0, tonumber(args.unityPasses) or 4)
    local unityInitialDensity = math.max(0, math.min(1, tonumber(args.unityInitialDensity) or 0.45))

    local placementMode = args.placementMode or "smart"
    local useSmartPlacement = placementMode ~= "legacy"
    local placeDecals   = args.placeDecals == true
    local placeTriggers = args.placeTriggers == true
    local decalDensity  = math.max(0, math.min(1, tonumber(args.decalDensity) or 0.12))
    local triggerMode   = args.triggerMode or "camera"

    local exportRando   = args.exportRandoYaml == true
    local randoOutPath  = args.randoOutputPath or "rando.yaml"

    local map = state.map
    if not map then return nil end

    local rng     = pcg.makeRng(rawSeed)
    local offsets = pcg.parseConfig(config)
    if #offsets == 0 then offsets = pcg.parseConfig("000011012") end

    -- Stage 1 & 2: training data + DPT
    local trainingList = {}
    if trainSource == "current_room" then
        if map.rooms and #map.rooms > 0 then
            local g = pcg.tilesStructToGrid(map.rooms[1].tilesFg)
            if g then table.insert(trainingList, g) end
        end
    else
        for _, r in ipairs(map.rooms or {}) do
            local g = pcg.tilesStructToGrid(r.tilesFg)
            if g then table.insert(trainingList, g) end
        end
    end

    local rawDominant = pcg.dominantSolidTile(trainingList)
    local style, _, _, trainedEra = pcg.detectStyle(trainingList)
    local effectiveEra = tilesetEra
    if effectiveEra == "mixed" then
        effectiveEra = (rng:nextDouble() < 0.5) and "old" or "new"
    elseif effectiveEra == "trained" then
        effectiveEra = trainedEra
    end
    local dominant = pcg.resolveTileForStyle(style, effectiveEra)
    pcg.log("Dominant tile: '" .. dominant .. "' (style=" .. style .. ", era=" .. effectiveEra .. ") | training rooms: " .. #trainingList)

    local counts = pcg.train(trainingList, offsets)
    if pcg.tableCount(counts) < 5 then
        pcg.injectSyntheticNGrams(counts, dominant, offsets)
    end
    local probs = pcg.normalise(counts)

    local adjacency = nil
    if generationMode == "wfc" or generationMode == "hybrid" then
        adjacency = pcg.trainAdjacency(trainingList, offsets)
        if not adjacency then
            pcg.log("Training data too uniform for WFC adjacency rules - falling back to MdMC mode")
            generationMode = "mdmc"
        end
    end

    -- Stage 3: skeleton
    local maxSkeletonResets = resetSkeleton and 5 or 1
    local slots = nil
    for skReset = 1, maxSkeletonResets do
        slots = buildSkeleton(roomCount, roomW, roomH, proba, 50, rng)
        if #slots >= 2 then break end
    end
    if not slots or #slots < 1 then return nil end

    local endIdx = furthestFrom(slots, 1)

    -- Stage 4: fill rooms
    local built = {}
    for i = 1, #slots do
        local slot = slots[i]
        local wTiles = math.floor(slot.bounds.width / TILE)
        local hTiles = math.floor(slot.bounds.height / TILE)
        local isStart = (i == 1)
        local isEnd = (i == endIdx)

        local room = pcg.createRoom(prefix .. (i - 1), slot.bounds.x, slot.bounds.y, wTiles, hTiles)

        local filled = false
        local isUnityMode = (generationMode == "perlin_top" or generationMode == "perlin_cave" or
                             generationMode == "randomwalk_cave" or generationMode == "directional_tunnel" or
                             generationMode == "cellular")
        if pcg.tableCount(probs) > 0 or isUnityMode then
            local bestTiles, bestI = nil, -math.huge

            for attempt = 1, triesLimit do
                local candidate
                if generationMode == "wfc" then
                    candidate = pcg.wfcGenerate(adjacency, wTiles, hTiles, rng, true)
                elseif generationMode == "hybrid" then
                    candidate = pcg.generateMdmc(probs, offsets, wTiles, hTiles, btDepth, rng, dominant, adjacency)
                elseif generationMode == "perlin_top" then
                    candidate = unity.perlinTopLayer(wTiles, hTiles, rng, dominant)
                elseif generationMode == "perlin_cave" then
                    candidate = unity.perlinCave(wTiles, hTiles, rng, dominant, unityModifier)
                elseif generationMode == "randomwalk_cave" then
                    candidate = unity.randomWalkCave(wTiles, hTiles, rng, dominant, unityFloorPercent)
                elseif generationMode == "directional_tunnel" then
                    candidate = unity.directionalTunnel(wTiles, hTiles, rng, dominant)
                elseif generationMode == "cellular" then
                    candidate = unity.cellularAutomata(wTiles, hTiles, rng, dominant, unityBirthLimit, unityDeathLimit, unityPasses, unityInitialDensity)
                else
                    candidate = pcg.generateMdmc(probs, offsets, wTiles, hTiles, btDepth, rng, dominant)
                end
                if not candidate then
                else
                    pcg.applyBorder(candidate, wTiles, hTiles, dominant)
                    if not pcg.isPlayable(candidate, wTiles, hTiles) then
                    else
                        local cI, _, _, cVar, pathLens = pcg.score(candidate, wTiles, hTiles, dominant,
                            numPaths, rng, w1, w2, w3, z1, z2, z3)
                        if not pcg.passesVarianceCheck(pathLens, cVar) then
                        elseif cI < minI then
                        elseif cI > bestI then
                            bestI = cI
                            bestTiles = candidate
                        end
                    end
                end
            end

            if not bestTiles and resetSkeleton then
                if generationMode == "wfc" then
                    bestTiles = pcg.wfcGenerate(adjacency, wTiles, hTiles, rng, true)
                elseif generationMode == "hybrid" then
                    bestTiles = pcg.generateMdmc(probs, offsets, wTiles, hTiles, btDepth, rng, dominant, adjacency)
                elseif generationMode == "perlin_top" then
                    bestTiles = unity.perlinTopLayer(wTiles, hTiles, rng, dominant)
                elseif generationMode == "perlin_cave" then
                    bestTiles = unity.perlinCave(wTiles, hTiles, rng, dominant, unityModifier)
                elseif generationMode == "randomwalk_cave" then
                    bestTiles = unity.randomWalkCave(wTiles, hTiles, rng, dominant, unityFloorPercent)
                elseif generationMode == "directional_tunnel" then
                    bestTiles = unity.directionalTunnel(wTiles, hTiles, rng, dominant)
                elseif generationMode == "cellular" then
                    bestTiles = unity.cellularAutomata(wTiles, hTiles, rng, dominant, unityBirthLimit, unityDeathLimit, unityPasses, unityInitialDensity)
                else
                    bestTiles = pcg.generateMdmc(probs, offsets, wTiles, hTiles, btDepth, rng, dominant)
                end
                if bestTiles then pcg.applyBorder(bestTiles, wTiles, hTiles, dominant) end
            end

            if bestTiles then
                for pass = 1, cleanupPasses do pcg.cleanupTiles(bestTiles, wTiles, hTiles, dominant) end
                if autoTile then pcg.autoTilePass(bestTiles, wTiles, hTiles, dominant) end
                if preserveExits then
                    local orig = pcg.tilesStructToGrid(room.tilesFg)
                    if orig then pcg.preserveBordersAndExits(bestTiles, wTiles, hTiles, orig, dominant) end
                end
                pcg.applyGridToRoom(room, "fg", bestTiles, wTiles, hTiles)
                filled = true

                local suffix = string.format("  I=%.2f", bestI)
                if not room.name:find("I=") then room.name = room.name .. suffix end

                if generateBG then
                    local bgTiles
                    if useEnhancedBG then
                        bgTiles = pcg.generateBackgroundEnhanced(bestTiles, wTiles, hTiles, dominant, style)
                    else
                        bgTiles = pcg.generateBackground(bestTiles, wTiles, hTiles, dominant)
                    end
                    pcg.applyGridToRoom(room, "bg", bgTiles, wTiles, hTiles)
                end
            end
        end

        table.insert(built, { room = room, filled = filled, wTiles = wTiles, hTiles = hTiles,
                              isStart = isStart, isEnd = isEnd, slotIdx = i })
    end

    -- Stage 4.5: carve aligned exits between neighbouring rooms
    if carveExits then
        for i = 1, #slots do
            for _, j in ipairs(slots[i].neighbours) do
                if j < i then
                    carveSharedExit(built[i].room, built[j].room, dominant)
                end
            end
        end
    end

    -- Stage 5: playability repair + entity placement
    for _, b in ipairs(built) do
        local room, filled = b.room, b.filled
        local wTiles, hTiles = b.wTiles, b.hTiles

        if filled and ensurePlayable then
            local fg = pcg.tilesStructToGrid(room.tilesFg)
            if fg then
                pcg.ensurePlayable(fg, wTiles, hTiles, dominant)
                pcg.applyGridToRoom(room, "fg", fg, wTiles, hTiles)
            end
        end

        local fg = pcg.tilesStructToGrid(room.tilesFg)
        if not filled then
            if b.isStart then
                pcg.addEntity(room, "player", TILE * 2, (hTiles - 2) * TILE)
            end
        elseif placeEnts then
            if fg then
                pcg.clearEntities(room)
                pcg.clearDecals(room)
                pcg.clearTriggers(room)

                local placementOpts = {
                    isStart = b.isStart,
                    isEnd = b.isEnd,
                    hazardDensity = hazardDensity,
                    springDensity = springDensity,
                    decalDensity = decalDensity,
                    triggerMode = triggerMode,
                    placeEntities = true,
                    placeDecals = placeDecals,
                    placeTriggers = placeTriggers,
                    style = style,
                    era = effectiveEra,
                }

                if useSmartPlacement then
                    pcg.placeAll(room, fg, wTiles, hTiles, rng, placementOpts)
                else
                    -- Legacy path: old random shuffle + decoration pass.
                    pcg.placeEntitiesLegacy(room, fg, wTiles, hTiles, rng, b.isStart, b.isEnd)
                    if hazardDensity > 0 or springDensity > 0 then
                        local decorations = pcg.decorationPass(fg, wTiles, hTiles, rng, hazardDensity, springDensity)
                        for _, d in ipairs(decorations) do
                            if d.type == "spikesUp" then
                                pcg.addEntity(room, "spikes", d.x * TILE, d.y * TILE, { direction = "up", type = "default" })
                            elseif d.type == "spring" then
                                pcg.addEntity(room, "spring", d.x * TILE, d.y * TILE)
                            end
                        end
                    end
                end
            end
        else
            if b.isStart then
                pcg.addEntity(room, "player", TILE * 2, (hTiles - 2) * TILE)
            end
            if b.isEnd then
                pcg.addEntity(room, "goldenBerry", math.floor(room.width / 2),
                    math.floor(room.height / 2 - TILE * 2))
            end
        end
    end

    -- Commit rooms to the map via snapshot (undoable)
    local createdRooms = {}
    local function forward()
        for _, b in ipairs(built) do
            mapItemUtils.addItem(map, b.room, false)
            table.insert(createdRooms, b.room)
        end
    end
    local function backward()
        for i = #createdRooms, 1, -1 do
            mapItemUtils.deleteRoom(map, createdRooms[i])
        end
    end

    forward()

    -- Optional rando YAML export
    if exportRando and #built > 0 then
        local roomsList = {}
        for _, b in ipairs(built) do table.insert(roomsList, b.room) end
        exportRandoYaml(roomsList, randoOutPath, state.filename, endIdx - 1)
    end

    local filledCount = 0
    for _, b in ipairs(built) do if b.filled then filledCount = filledCount + 1 end end
    pcg.log(string.format("PCG Pipeline: generated %d room(s) (%d filled)", #built, filledCount))
    return snapshot.create(script.name, {}, backward, forward)
end

return script
