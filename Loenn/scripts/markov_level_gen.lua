-- markov_level_gen.lua
-- Loenn port of Rysy's MarkovLevelGenScript.cs
-- Generates tile layouts using a Multi-dimensional Markov Chain (MdMC) trained
-- on existing rooms (paper §3.3.2), with WFC / hybrid modes, tile-level
-- backtracking, template & pattern fallbacks, cleanup, auto-tiling, BG
-- generation, playability repair, interestingness/difficulty scoring and
-- entity placement.

local mods = require("mods")
local state = require("loaded_state")
local tilesStruct = require("structs.tiles")
local pcg = mods.requireFromPlugin("library.pcg_toolkit")
local unity = mods.requireFromPlugin("library.pcg_unity_generators")

local TILE = 8

local script = {
    name = "markovLevelGen",
    displayName = "Markov Level Generator",
    tooltip = "Generates tile layouts using a Multi-dimensional Markov Chain (MdMC) trained on existing rooms. "
              .. "Configuration matrix, tile-level backtracking and entity placement are all supported.",
    parameters = {
        trainSource = "all_rooms",
        configuration = "000011012",
        generationMode = "mdmc",
        tilesetEra = "new",
        ensurePlayable = true,
        seed = -1,
        maxRetries = 20,
        maxBacktrackDepth = 8,
        targetLayer = "fg",
        keepBorder = true,
        placeEntities = true,
        w1 = 1.0, w2 = 1.0, w3 = 1.0, minInterestingness = 0.0,
        z1 = 1.0, z2 = 1.0, z3 = 1.0,
        numPaths = 5,
        useTemplateMode = false,
        generateBG = false,
        cleanupPasses = 2,
        usePatternMode = false,
        difficulty = 3,
        autoTile = true,
        preserveExits = false,
        hazardDensity = 0.05,
        springDensity = 0.02,
        useEnhancedBG = false,

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
        trainSource = { fieldType = "loennScripts.dropdown", options = { "all_rooms", "current_room" }, editable = false },
        configuration = { fieldType = "loennScripts.dropdown", options = (function()
            local opts = {}
            for k, _ in pairs(pcg.MdmcPresets) do table.insert(opts, k) end
            table.sort(opts)
            return opts
        end)(), editable = true },
        generationMode = { fieldType = "loennScripts.dropdown", options = { "mdmc", "wfc", "hybrid", "perlin_top", "perlin_cave", "randomwalk_cave", "directional_tunnel", "cellular" }, editable = false },
        tilesetEra = { fieldType = "loennScripts.dropdown", options = { "new", "old", "mixed", "trained" }, editable = false },
        targetLayer = { fieldType = "loennScripts.dropdown", options = { "fg", "bg" }, editable = false },
        placementMode = { fieldType = "loennScripts.dropdown", options = { "smart", "legacy" }, editable = false },
        triggerMode = { fieldType = "loennScripts.dropdown", options = { "camera", "spawn", "all", "none" }, editable = false },
        seed = { fieldType = "integer" },
        maxRetries = { fieldType = "integer" },
        maxBacktrackDepth = { fieldType = "integer" },
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
        trainSource = "Which rooms to train the MdMC on.",
        configuration = "3x3 configuration matrix (row-major, 0 = ignore, 1 = use, 2 = target). Layout: NW(0) N(1) NE(2) / W(3) .(4) E(5) / SW(6) S(7) SE(8).",
        generationMode = "MdMC, WFC, Hybrid, or Unity procedural seeds (Perlin / Random Walk / Cellular / Tunnel).",
        tilesetEra = "Which tileset era to use: new, old, a 50/50 mix, or whatever the training rooms already contain.",
        ensurePlayable = "Platformer repair pass: verifies all room exits are reachable and carves corridors / adds stepping-stones when not.",
        seed = "Random seed. -1 = random each run.",
        maxRetries = "Full-room generation retries before giving up.",
        maxBacktrackDepth = "Maximum tiles to backtrack when an unseen n-gram is encountered (paper §3.3.2).",
        targetLayer = "Tile layer to generate into.",
        keepBorder = "Preserve the room's outer 1-tile solid border after generation.",
        placeEntities = "Place a player spawn, strawberries above open pockets, and up-spikes on exposed solid surfaces after generation.",
        w1 = "Weight for global NLE density in interestingness score I (§4.2).",
        w2 = "Weight for local NLE density (AOI) in interestingness score I (§4.2).",
        w3 = "Weight for NLE diversity (Shannon entropy) in interestingness score I (§4.2).",
        minInterestingness = "Minimum interestingness score I required to accept a generated room. 0 = accept any.",
        z1 = "Weight for hole frequency Hf in difficulty score D (§4.3).",
        z2 = "Weight for local LE density dLE,local in difficulty score D (§4.3).",
        z3 = "Weight for NLE scarcity s_scarcity in difficulty score D (§4.3).",
        numPaths = "Number of BFS paths to sample for path variance analysis (§4.1).",
        useTemplateMode = "Template mode: uses fallback generator to create basic platformer layouts instead of Markov chain.",
        generateBG = "Also generate background tiles based on foreground layout.",
        cleanupPasses = "Number of cleanup passes to remove isolated tiles and fill small holes.",
        usePatternMode = "Pattern mode: extracts patterns from training data and stitches them together (marioGen-v2 style).",
        difficulty = "Difficulty level (1-5) for pattern mode.",
        autoTile = "Auto-tiling pass: blends tile edges for smooth transitions.",
        preserveExits = "Smart borders: preserve existing room exits/connections.",
        hazardDensity = "Density of hazards (spikes) to place on walkable surfaces (0-1).",
        springDensity = "Density of springs to place in vertical passages (0-1).",
        useEnhancedBG = "Enhanced background: style-aware BG with depth-appropriate fill.",
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
-- Pattern mode (marioGen-v2 inspired)
-- =========================================================================
local PatternTransitions = {
    flat_ground = { { "flat_ground", 3.0 }, { "easy_pit", 1.0 }, { "platforms", 0.8 },
                    { "stairs_up", 0.6 }, { "stairs_down", 0.6 }, { "wall", 0.4 } },
    easy_pit = { { "flat_ground", 2.8 }, { "medium_pit", 0.7 }, { "platforms", 0.5 } },
    medium_pit = { { "flat_ground", 2.8 }, { "hard_pit", 0.5 }, { "platforms", 0.4 } },
    hard_pit = { { "flat_ground", 3.4 }, { "two_jumps", 0.5 }, { "wall", 0.4 } },
    platforms = { { "flat_ground", 2.5 }, { "easy_pit", 0.8 }, { "stairs_up", 0.5 } },
    stairs_up = { { "high_ground", 1.5 }, { "stairs_down", 1.0 }, { "platforms", 0.4 } },
    stairs_down = { { "flat_ground", 2.5 }, { "easy_pit", 0.8 }, { "wall", 0.5 } },
    high_ground = { { "stairs_down", 1.5 }, { "platforms", 0.5 }, { "flat_ground", 0.8 } },
    wall = { { "flat_ground", 2.5 }, { "easy_pit", 0.6 }, { "stairs_down", 0.4 } },
    two_jumps = { { "flat_ground", 3.2 }, { "easy_pit", 0.5 }, { "platforms", 0.4 } },
}

local function extractPatternsFromTraining(trainingGrids, patternWidth, patternHeight)
    local patterns = {}
    local rng = pcg.makeRng(42)
    for _, grid in ipairs(trainingGrids) do
        local w, h = pcg.gridSize(grid)
        local startX = 0
        while startX + patternWidth <= w do
            local startY = 0
            while startY + patternHeight <= h do
                local pat = { id = "extracted_" .. #patterns, tiles = pcg.newGrid(patternWidth, patternHeight, "0"),
                              width = patternWidth, height = patternHeight, minDifficulty = 1, tags = {} }
                local hasGround = false
                for px = 0, patternWidth - 1 do
                    for py = 0, patternHeight - 1 do
                        local tx = math.min(startX + px, w - 1)
                        local ty = math.min(startY + py, h - 1)
                        pat.tiles[px][py] = grid[tx][ty]
                        if grid[tx][ty] ~= "0" then hasGround = true end
                    end
                end
                if hasGround and #patterns < 20 then
                    table.insert(pat.tags, hasGround and "ground" or "air")
                    table.insert(patterns, pat)
                end
                startY = startY + patternHeight
            end
            startX = startX + math.floor(patternWidth / 2)
        end
    end
    return patterns
end

local function copyPattern(target, pattern, startX, width, targetHeight, targetW)
    for px = 0, width - 1 do
        local tx = startX + px
        if tx >= 0 and tx < targetW then
            for py = 0, pattern.height - 1 do
                if py < targetHeight then
                    target[tx][py] = pattern.tiles[px][py]
                end
            end
        end
    end
end

local function chooseNextPattern(current, available, rng, difficulty)
    local transitions = PatternTransitions[current.id] or { { "flat_ground", 1.0 } }
    local candidates = {}
    for _, entry in ipairs(transitions) do
        local targetId, baseWeight = entry[1], entry[2]
        local candidate = nil
        for _, p in ipairs(available) do if p.id == targetId then candidate = p break end end
        if candidate and candidate.minDifficulty <= difficulty then
            local weight = baseWeight
            local hasHard, hasEasy = false, false
            for _, t in ipairs(candidate.tags) do
                if t == "hard" then hasHard = true end
                if t == "easy" then hasEasy = true end
            end
            if hasHard and difficulty < 3 then weight = weight * 0.5 end
            if hasEasy and difficulty > 3 then weight = weight * 0.7 end
            table.insert(candidates, { pattern = candidate, weight = weight })
        end
    end
    if #candidates == 0 then return available[rng:next(#available) + 1] end
    local totalWeight = 0.0
    for _, c in ipairs(candidates) do totalWeight = totalWeight + c.weight end
    local roll = rng:nextDouble() * totalWeight
    local cum = 0.0
    for _, c in ipairs(candidates) do
        cum = cum + c.weight
        if roll <= cum then return c.pattern end
    end
    return candidates[#candidates].pattern
end

local function generateFromPatterns(w, h, patterns, rng, difficulty)
    local result = pcg.newGrid(w, h, "0")
    if #patterns == 0 then return result end
    local available = {}
    for _, p in ipairs(patterns) do if p.minDifficulty <= difficulty then table.insert(available, p) end end
    if #available == 0 then available = patterns end

    local currentPattern = available[1]
    for _, p in ipairs(available) do if p.id:find("flat") then currentPattern = p break end end

    local cursor = 0
    while cursor < w do
        local remaining = w - cursor
        if remaining < 4 then
            local flat = nil
            for _, p in ipairs(available) do if p.id:find("flat") then flat = p break end end
            if flat then
                local width = math.min(flat.width, remaining)
                copyPattern(result, flat, cursor, width, h, w)
            end
            break
        end
        local nextPattern = chooseNextPattern(currentPattern, available, rng, difficulty)
        local fitWidth = math.min(nextPattern.width, remaining)
        copyPattern(result, nextPattern, cursor, fitWidth, h, w)
        cursor = cursor + fitWidth
        currentPattern = nextPattern
    end
    return result
end

-- =========================================================================
-- Training-grid collection
-- =========================================================================
local function collectTrainingGrids(trainSource, targetLayer, room)
    local grids = {}
    if trainSource == "current_room" then
        local g = pcg.tilesStructToGrid(targetLayer == "fg" and room.tilesFg or room.tilesBg)
        if g then table.insert(grids, g) end
    else
        local rooms = (state.map and state.map.rooms) or {}
        for _, r in ipairs(rooms) do
            local g = pcg.tilesStructToGrid(targetLayer == "fg" and r.tilesFg or r.tilesBg)
            if g then table.insert(grids, g) end
        end
    end
    return grids
end

local function gridHasAnySolid(grid)
    local w, h = pcg.gridSize(grid)
    for x = 0, w - 1 do for y = 0, h - 1 do if grid[x][y] ~= "0" then return true end end end
    return false
end

-- =========================================================================
-- Main run
-- =========================================================================
function script.run(room, args)
    local trainSource = args.trainSource or "all_rooms"
    local configString = args.configuration or "000011012"
    local rawSeed = tonumber(args.seed) or -1
    local maxRetries = math.max(1, tonumber(args.maxRetries) or 20)
    local maxBacktrackDepth = math.max(1, tonumber(args.maxBacktrackDepth) or 8)
    local targetLayer = args.targetLayer or "fg"
    local keepBorder = args.keepBorder ~= false
    local placeEntities = args.placeEntities ~= false

    local w1 = tonumber(args.w1) or 1.0
    local w2 = tonumber(args.w2) or 1.0
    local w3 = tonumber(args.w3) or 1.0
    local minInteresting = tonumber(args.minInterestingness) or 0.0
    local z1 = tonumber(args.z1) or 1.0
    local z2 = tonumber(args.z2) or 1.0
    local z3 = tonumber(args.z3) or 1.0
    local numPaths = math.max(1, tonumber(args.numPaths) or 5)

    local useTemplateMode = args.useTemplateMode == true
    local generateBG = args.generateBG == true
    local cleanupPasses = math.max(0, tonumber(args.cleanupPasses) or 2)
    local usePatternMode = args.usePatternMode == true
    local difficulty = math.max(1, math.min(5, tonumber(args.difficulty) or 3))

    local autoTile = args.autoTile ~= false
    local preserveExits = args.preserveExits == true
    local hazardDensity = math.max(0, math.min(1, tonumber(args.hazardDensity) or 0.05))
    local springDensity = math.max(0, math.min(1, tonumber(args.springDensity) or 0.02))
    local useEnhancedBG = args.useEnhancedBG == true

    local placementMode = args.placementMode or "smart"
    local useSmartPlacement = placementMode ~= "legacy"
    local placeDecals = args.placeDecals == true
    local placeTriggers = args.placeTriggers == true
    local decalDensity = math.max(0, math.min(1, tonumber(args.decalDensity) or 0.12))
    local triggerMode = args.triggerMode or "camera"

    local generationMode = args.generationMode or "mdmc"
    local tilesetEra = args.tilesetEra or "new"
    local ensurePlayable = args.ensurePlayable ~= false

    local unityModifier = math.max(0.001, math.min(1.0, tonumber(args.unityModifier) or 0.1))
    local unityFloorPercent = math.max(0, math.min(100, tonumber(args.unityFloorPercent) or 45))
    local unityBirthLimit = math.max(0, tonumber(args.unityBirthLimit) or 4)
    local unityDeathLimit = math.max(0, tonumber(args.unityDeathLimit) or 3)
    local unityPasses = math.max(0, tonumber(args.unityPasses) or 4)
    local unityInitialDensity = math.max(0, math.min(1, tonumber(args.unityInitialDensity) or 0.45))

    local isUnityMode = (generationMode == "perlin_top" or generationMode == "perlin_cave" or
                         generationMode == "randomwalk_cave" or generationMode == "directional_tunnel" or
                         generationMode == "cellular")
    if isUnityMode then
        usePatternMode = false
        useTemplateMode = false
    end

    local offsets = pcg.parseConfig(configString)
    if #offsets == 0 then offsets = pcg.parseConfig("000011012") end
    local rng = pcg.makeRng(rawSeed)

    local trainingList = collectTrainingGrids(trainSource, targetLayer, room)

    -- fall back to all rooms if current room is empty
    if trainSource == "current_room" and #trainingList > 0 and not gridHasAnySolid(trainingList[1]) then
        pcg.log("Current room has no tiles - falling back to 'All rooms in map'")
        trainingList = collectTrainingGrids("all_rooms", targetLayer, room)
    end

    pcg.log("Training on " .. #trainingList .. " room(s)")
    if #trainingList == 0 then
        pcg.log("MarkovGen: No valid training data (empty rooms)")
        return
    end

    local function applyPlacement(tiles, wT, hT, style, era)
        if not (placeEntities and targetLayer == "fg") then return end
        pcg.clearEntities(room)
        pcg.clearDecals(room)
        pcg.clearTriggers(room)

        local placementOpts = {
            isStart = false,
            isEnd = false,
            hazardDensity = hazardDensity,
            springDensity = springDensity,
            decalDensity = decalDensity,
            triggerMode = triggerMode,
            placeEntities = true,
            placeDecals = placeDecals,
            placeTriggers = placeTriggers,
            style = style,
            era = era,
        }

        if useSmartPlacement then
            pcg.placeAll(room, tiles, wT, hT, rng, placementOpts)
        else
            -- Legacy path: old random shuffle + decoration pass.
            pcg.placeEntitiesLegacy(room, tiles, wT, hT, rng, false, false)
            if hazardDensity > 0 or springDensity > 0 then
                local decorations = pcg.decorationPass(tiles, wT, hT, rng, hazardDensity, springDensity)
                for _, d in ipairs(decorations) do
                    if d.type == "spikesUp" then
                        pcg.addEntity(room, "spikes", d.x * 8, d.y * 8, { direction = "up", type = "default" })
                    elseif d.type == "spring" then
                        pcg.addEntity(room, "spring", d.x * 8, d.y * 8)
                    end
                end
                if #decorations > 0 then
                    pcg.log("Placed " .. #decorations .. " decorations (hazards/springs)")
                end
            end
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
    local dominantTile = pcg.resolveTileForStyle(style, effectiveEra)
    pcg.log("Dominant tile: '" .. dominantTile .. "' (style=" .. style .. ", era=" .. effectiveEra .. ")")

    local targetStruct = targetLayer == "fg" and room.tilesFg or room.tilesBg
    local wT = math.floor(room.width / TILE)
    local hT = math.floor(room.height / TILE)

    -- ----------------------------------------------------------------
    -- Standard Markov chain training
    -- ----------------------------------------------------------------
    local counts = pcg.train(trainingList, offsets)
    pcg.log("Learned " .. pcg.tableCount(counts) .. " unique n-grams")
    if pcg.tableCount(counts) == 0 and not isUnityMode then
        pcg.log("MarkovGen: No n-grams learned - training rooms may be empty or uniform")
        return
    end
    if pcg.tableCount(counts) < 5 and not isUnityMode then
        pcg.log("Training data has only " .. pcg.tableCount(counts) .. " n-gram(s) - injecting synthetic patterns")
        pcg.injectSyntheticNGrams(counts, dominantTile, offsets)
    end
    local probs = pcg.normalise(counts)

    -- WFC / hybrid adjacency
    local adjacency = nil
    if generationMode == "wfc" or generationMode == "hybrid" then
        adjacency = pcg.trainAdjacency(trainingList, offsets)
        if not adjacency then
            pcg.log("Training data too uniform for WFC adjacency rules - falling back to MdMC mode")
            generationMode = "mdmc"
        else
            pcg.log("WFC model: " .. adjacency.n .. " tile types, " .. #adjacency.dirs .. " constraint directions")
        end
    end

    local bestTiles, bestMetrics = nil, nil

    -- ----------------------------------------------------------------
    -- Pattern mode
    -- ----------------------------------------------------------------
    if usePatternMode then
        pcg.log("Using pattern mode (marioGen-v2 style)")
        local patterns = extractPatternsFromTraining(trainingList, 8, hT)
        pcg.log("Extracted " .. #patterns .. " patterns from training data")
        if #patterns == 0 then
            pcg.log("No patterns extracted - falling back to template mode")
            useTemplateMode = true
        else
            for attempt = 1, maxRetries do
                local candidate = generateFromPatterns(wT, hT, patterns, rng, difficulty)
                if keepBorder then pcg.applyBorder(candidate, wT, hT, dominantTile) end
                for pass = 1, cleanupPasses do pcg.cleanupTiles(candidate, wT, hT, dominantTile) end
                if pcg.isPlayable(candidate, wT, hT) then
                    bestTiles = candidate
                    pcg.log("Generated pattern-based room on attempt " .. attempt)
                    break
                end
            end
            if bestTiles then
                if autoTile then pcg.autoTilePass(bestTiles, wT, hT, dominantTile) end
                if preserveExits and targetLayer == "fg" then
                    local orig = pcg.tilesStructToGrid(room.tilesFg)
                    if orig then pcg.preserveBordersAndExits(bestTiles, wT, hT, orig, dominantTile) end
                end
                if ensurePlayable and targetLayer == "fg" then
                    pcg.ensurePlayable(bestTiles, wT, hT, dominantTile)
                end
                pcg.applyGridToRoom(room, targetLayer, bestTiles, wT, hT)
                if generateBG and targetLayer == "fg" then
                    local bgTiles
                    if useEnhancedBG then
                        bgTiles = pcg.generateBackgroundEnhanced(bestTiles, wT, hT, dominantTile, style)
                    else
                        bgTiles = pcg.generateBackground(bestTiles, wT, hT, dominantTile)
                    end
                    pcg.applyGridToRoom(room, "bg", bgTiles, wT, hT)
                end
                applyPlacement(bestTiles, wT, hT, style, effectiveEra)
                pcg.log("MarkovGen: generated pattern-based room")
                return
            end
        end
    end

    -- ----------------------------------------------------------------
    -- MdMC / WFC / Hybrid generation loop
    -- ----------------------------------------------------------------
    local desperationMode = pcg.tableCount(probs) < 10
    if desperationMode then pcg.log("Desperation mode: relaxing validation due to sparse training data") end

    for attempt = 1, maxRetries do
        local candidate
        if generationMode == "wfc" then
            candidate = pcg.wfcGenerate(adjacency, wT, hT, rng, keepBorder)
        elseif generationMode == "hybrid" then
            candidate = pcg.generateMdmc(probs, offsets, wT, hT, maxBacktrackDepth, rng, dominantTile, adjacency)
        elseif generationMode == "perlin_top" then
            candidate = unity.perlinTopLayer(wT, hT, rng, dominantTile)
        elseif generationMode == "perlin_cave" then
            candidate = unity.perlinCave(wT, hT, rng, dominantTile, unityModifier)
        elseif generationMode == "randomwalk_cave" then
            candidate = unity.randomWalkCave(wT, hT, rng, dominantTile, unityFloorPercent)
        elseif generationMode == "directional_tunnel" then
            candidate = unity.directionalTunnel(wT, hT, rng, dominantTile)
        elseif generationMode == "cellular" then
            candidate = unity.cellularAutomata(wT, hT, rng, dominantTile, unityBirthLimit, unityDeathLimit, unityPasses, unityInitialDensity)
        else
            candidate = pcg.generateMdmc(probs, offsets, wT, hT, maxBacktrackDepth, rng, dominantTile)
        end
        if not candidate then
        else
            if keepBorder then pcg.applyBorder(candidate, wT, hT, dominantTile) end

            if not pcg.isPlayable(candidate, wT, hT) then
                if not desperationMode then
                else
                    local hasAnyFloor = false
                    for x = 1, wT - 2 do
                        if hasAnyFloor then break end
                        for y = hT - 2, 1, -1 do
                            if candidate[x][y] == "0" and candidate[x][y + 1] ~= "0" then hasAnyFloor = true break end
                        end
                    end
                    if not hasAnyFloor then
                    else
                        local metrics = pcg.computeMetrics(candidate, wT, hT, numPaths, rng,
                            w1, w2, w3, z1, z2, z3, dominantTile)
                        if bestTiles == nil or metrics.interestingness > bestMetrics.interestingness then
                            bestTiles = candidate
                            bestMetrics = metrics
                            break -- accept first viable in desperation mode
                        end
                    end
                end
            else
                local metrics = pcg.computeMetrics(candidate, wT, hT, numPaths, rng,
                    w1, w2, w3, z1, z2, z3, dominantTile)
                if not desperationMode and not pcg.passesVarianceCheck(metrics.pathLengths, metrics.pathVariance) then
                elseif not desperationMode and metrics.interestingness < minInteresting then
                else
                    if bestTiles == nil or metrics.interestingness > bestMetrics.interestingness then
                        bestTiles = candidate
                        bestMetrics = metrics
                    end
                end
            end
        end
    end

    if not bestTiles then
        if not useTemplateMode then
            pcg.log("Markov generation failed - falling back to template mode")
            useTemplateMode = true
        else
            pcg.log("MarkovGen: No valid candidate generated after " .. maxRetries .. " retries")
            return
        end
    end

    if useTemplateMode and not bestTiles then
        pcg.log("Using template mode to generate basic platformer layout")
        bestTiles = pcg.generateFallback(wT, hT, dominantTile, rng)
        if keepBorder then pcg.applyBorder(bestTiles, wT, hT, dominantTile) end
        for pass = 1, cleanupPasses do pcg.cleanupTiles(bestTiles, wT, hT, dominantTile) end
        pcg.log("Generated template room (ground floor + platforms)")
    end

    if not bestTiles then return end

    if bestMetrics then
        pcg.log(string.format("Generated room: I=%.2f D=%.2f sp=%.1f",
            bestMetrics.interestingness, bestMetrics.difficulty, bestMetrics.pathMean))
    end

    for pass = 1, cleanupPasses do pcg.cleanupTiles(bestTiles, wT, hT, dominantTile) end

    if autoTile then
        pcg.autoTilePass(bestTiles, wT, hT, dominantTile)
        pcg.log("Applied auto-tiling pass")
    end

    if preserveExits and targetLayer == "fg" then
        local orig = pcg.tilesStructToGrid(room.tilesFg)
        if orig then pcg.preserveBordersAndExits(bestTiles, wT, hT, orig, dominantTile) end
        pcg.log("Preserved room exits/connections")
    end

    if ensurePlayable and targetLayer == "fg" then
        if pcg.ensurePlayable(bestTiles, wT, hT, dominantTile) then
            pcg.log("Playability verified (jump/dash/climb reachability)")
        end
    end

    pcg.applyGridToRoom(room, targetLayer, bestTiles, wT, hT)

    if generateBG and targetLayer == "fg" then
        local bgTiles
        if useEnhancedBG then
            bgTiles = pcg.generateBackgroundEnhanced(bestTiles, wT, hT, dominantTile, style)
            pcg.log("Generated enhanced " .. style .. "-style background tiles")
        else
            bgTiles = pcg.generateBackground(bestTiles, wT, hT, dominantTile)
            pcg.log("Generated background tiles")
        end
        pcg.applyGridToRoom(room, "bg", bgTiles, wT, hT)
    end

    -- append scores to room name
    if bestMetrics then
        local suffix = string.format("  I=%.2f D=%.2f sp=%.1f",
            bestMetrics.interestingness, bestMetrics.difficulty, bestMetrics.pathMean)
        if not room.name:find("I=") then room.name = room.name .. suffix end
    end

    applyPlacement(bestTiles, wT, hT, style, effectiveEra)

    pcg.log("MarkovGen: room generated")
end

return script
