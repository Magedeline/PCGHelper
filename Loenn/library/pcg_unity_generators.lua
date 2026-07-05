-- pcg_unity_generators.lua
-- Unity blog procedural patterns (Perlin noise, Random Walk, Cellular Automata,
-- Directional Tunnel) ported to the PCG toolkit grid format.
-- All generators return a 0-based grid where "0" = air and the requested tile
-- character = solid. They are intended as seeders / alternative generation modes
-- for the Celeste PCG Pipeline.

local mods = require("mods")
local pcg = mods.requireFromPlugin("library.pcg_toolkit")

local unity = {}

-- =========================================================================
-- 2D Perlin noise helper (deterministic, no external dependencies).
-- =========================================================================
local PerlinPerm = {
    151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
    140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,
    247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,
    57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,
    74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,
    60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,
    65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,
    200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,
    52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,
    207,206,59,227,47,16,58,17,182,189,28,42,23,183,194,213,
    157,6,76,84,45,35,172,112,128,24,50,129,153,35,189,93,
    180,170,188,131,206,85,29,173,16,38,115,210,247,170,87,68,
    232,58,161,7,203,252,157,59,121,181,106,255,141,180,133,109,
    233,178,235,252,116,251,145,150,110,241,115,233,181,21,245,146,
    144,157,226,143,250,131,141,239,163,81,183,142,255,123,187,62
}
-- Duplicate table so overflow indices are safe (1-based Lua, 512 entries).
for i = 1, 256 do PerlinPerm[i + 256] = PerlinPerm[i] end

local function fade(t)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(t, a, b)
    return a + t * (b - a)
end

local function grad(hash, x, y, z)
    local h = hash % 16
    local u = (h < 8) and x or y
    local v = (h < 4) and y or ((h == 12 or h == 14) and x or z)
    return ((h % 2) == 0 and u or -u) + ((h % 4) < 2 and v or -v)
end

local function perlinNoise2D(x, y, z)
    z = z or 0
    local X = math.floor(x) % 256 + 1
    local Y = math.floor(y) % 256 + 1
    local Z = math.floor(z) % 256 + 1
    x = x - math.floor(x)
    y = y - math.floor(y)
    z = z - math.floor(z)
    local u = fade(x)
    local v = fade(y)
    local w = fade(z)

    local A = PerlinPerm[X] + Y
    local AA = PerlinPerm[A] + Z
    local AB = PerlinPerm[A + 1] + Z
    local B = PerlinPerm[X + 1] + Y
    local BA = PerlinPerm[B] + Z
    local BB = PerlinPerm[B + 1] + Z

    local raw = lerp(w,
        lerp(v,
            lerp(u, grad(PerlinPerm[AA], x, y, z), grad(PerlinPerm[BA], x - 1, y, z)),
            lerp(u, grad(PerlinPerm[AB], x, y - 1, z), grad(PerlinPerm[BB], x - 1, y - 1, z))
        ),
        lerp(v,
            lerp(u, grad(PerlinPerm[AA + 1], x, y, z - 1), grad(PerlinPerm[BA + 1], x - 1, y, z - 1)),
            lerp(u, grad(PerlinPerm[AB + 1], x, y - 1, z - 1), grad(PerlinPerm[BB + 1], x - 1, y - 1, z - 1))
        )
    )
    -- Perlin gradient noise is in [-1, 1]; map to [0, 1] like Mathf.PerlinNoise.
    return (raw + 1) * 0.5
end

-- =========================================================================
-- Part 1: Perlin top layer
-- Generates a 1D height profile and fills everything below it with solid.
-- =========================================================================
function unity.perlinTopLayer(w, h, rng, solidTile, seed, reduction)
    solidTile = solidTile or "1"
    seed = seed or rng:nextDouble() * 1000
    reduction = reduction or 0.5
    local scale = 0.05
    local grid = pcg.newGrid(w, h, "0")
    for x = 0, w - 1 do
        local n = perlinNoise2D(x * scale, seed, 0)
        local height = math.floor((n - reduction) * h)
        height = height + math.floor(h / 2)
        height = math.max(0, math.min(h - 1, height))
        for y = 0, height do
            grid[x][y] = solidTile
        end
    end
    return grid
end

-- =========================================================================
-- Part 2: Perlin noise cave
-- 2D Perlin thresholded to binary; optional solid edges.
-- =========================================================================
function unity.perlinCave(w, h, rng, solidTile, modifier, edgesAreWalls)
    solidTile = solidTile or "1"
    modifier = modifier or 0.1
    edgesAreWalls = edgesAreWalls ~= false
    local seed = rng:nextDouble() * 1000
    local grid = pcg.newGrid(w, h, "0")
    for x = 0, w - 1 do
        for y = 0, h - 1 do
            if edgesAreWalls and (x == 0 or y == 0 or x == w - 1 or y == h - 1) then
                grid[x][y] = solidTile
            else
                local n = perlinNoise2D(x * modifier, y * modifier, seed)
                grid[x][y] = (n >= 0.5) and solidTile or "0"
            end
        end
    end
    return grid
end

-- =========================================================================
-- Part 2: Random walk cave
-- Carves a drunkard's walk through a solid map until enough floor is open.
-- =========================================================================
function unity.randomWalkCave(w, h, rng, solidTile, requiredFloorPercent)
    solidTile = solidTile or "1"
    requiredFloorPercent = requiredFloorPercent or 45
    local grid = pcg.newGrid(w, h, solidTile)
    local floorX = rng:nextRange(1, w - 2)
    local floorY = rng:nextRange(1, h - 2)
    grid[floorX][floorY] = "0"
    local floorCount = 1
    local reqFloor = math.floor(w * h * requiredFloorPercent / 100)
    local dirs = { {1,0}, {-1,0}, {0,1}, {0,-1} }
    while floorCount < reqFloor do
        local d = dirs[rng:next(4) + 1]
        floorX = math.max(1, math.min(w - 2, floorX + d[1]))
        floorY = math.max(1, math.min(h - 2, floorY + d[2]))
        if grid[floorX][floorY] ~= "0" then
            grid[floorX][floorY] = "0"
            floorCount = floorCount + 1
        end
    end
    return grid
end

-- =========================================================================
-- Part 2: Directional tunnel
-- Horizontal tunnel from left to right with configurable width and roughness.
-- =========================================================================
function unity.directionalTunnel(w, h, rng, solidTile, minPathWidth, maxPathWidth, maxPathChange, roughness, curvyness)
    solidTile = solidTile or "1"
    minPathWidth = minPathWidth or 1
    maxPathWidth = maxPathWidth or 3
    maxPathChange = maxPathChange or 1
    roughness = roughness or 1
    curvyness = curvyness or 1
    local grid = pcg.newGrid(w, h, solidTile)

    local tunnelWidth = minPathWidth + rng:next(maxPathWidth - minPathWidth + 1)
    local x = math.floor(w / 2)
    local y = 0
    for i = -tunnelWidth, tunnelWidth do
        if x + i >= 0 and x + i < w and y < h then grid[x + i][y] = "0" end
    end

    while y < h - 1 do
        if rng:next(100) < roughness then
            tunnelWidth = math.max(minPathWidth, math.min(maxPathWidth, tunnelWidth + rng:nextRange(-1, 1)))
        end
        if rng:next(100) < curvyness then
            x = math.max(tunnelWidth + 1, math.min(w - tunnelWidth - 2, x + rng:nextRange(-maxPathChange, maxPathChange)))
        end
        y = y + 1
        for i = -tunnelWidth, tunnelWidth do
            if x + i >= 0 and x + i < w and y < h then grid[x + i][y] = "0" end
        end
    end
    return grid
end

-- =========================================================================
-- Part 2: Cellular automata
-- Seed with random noise, then smooth with birth/survival rules.
-- =========================================================================
function unity.cellularAutomata(w, h, rng, solidTile, birthLimit, deathLimit, passes, initialDensity)
    solidTile = solidTile or "1"
    birthLimit = birthLimit or 4
    deathLimit = deathLimit or 3
    passes = passes or 4
    initialDensity = initialDensity or 0.45

    local grid = pcg.newGrid(w, h, "0")
    for x = 1, w - 2 do
        for y = 1, h - 2 do
            grid[x][y] = (rng:nextDouble() < initialDensity) and solidTile or "0"
        end
    end
    -- Keep border solid for stability.
    for x = 0, w - 1 do grid[x][0] = solidTile; grid[x][h - 1] = solidTile end
    for y = 0, h - 1 do grid[0][y] = solidTile; grid[w - 1][y] = solidTile end

    for _ = 1, passes do
        local newGrid = pcg.newGrid(w, h, "0")
        for x = 1, w - 2 do
            for y = 1, h - 2 do
                local neighbours = 0
                for dx = -1, 1 do
                    for dy = -1, 1 do
                        if dx ~= 0 or dy ~= 0 then
                            if grid[x + dx] and grid[x + dx][y + dy] == solidTile then
                                neighbours = neighbours + 1
                            end
                        end
                    end
                end
                if grid[x][y] == solidTile then
                    newGrid[x][y] = (neighbours < deathLimit) and "0" or solidTile
                else
                    newGrid[x][y] = (neighbours > birthLimit) and solidTile or "0"
                end
            end
        end
        -- Preserve border.
        for x = 0, w - 1 do newGrid[x][0] = solidTile; newGrid[x][h - 1] = solidTile end
        for y = 0, h - 1 do newGrid[0][y] = solidTile; newGrid[w - 1][y] = solidTile end
        grid = newGrid
    end
    return grid
end

-- =========================================================================
-- Part 1: Smoothed random walk top layer
-- Samples height at intervals and interpolates between sample points.
-- =========================================================================
function unity.smoothedRandomWalkTop(w, h, rng, solidTile, interval)
    solidTile = solidTile or "1"
    interval = math.max(2, interval or 5)
    local scale = 0.05
    local seed = rng:nextDouble() * 1000

    local noiseX = {}
    local noiseY = {}
    for x = 0, w - 1, interval do
        local n = perlinNoise2D(x * scale, seed, 0)
        table.insert(noiseY, math.floor((n - 0.5) * h))
        table.insert(noiseX, x)
    end
    if #noiseY == 0 then
        noiseY[1] = math.floor(h / 2)
        noiseX[1] = 0
    end

    local grid = pcg.newGrid(w, h, "0")
    for i = 2, #noiseY do
        local lastPos = { x = noiseX[i - 1], y = noiseY[i - 1] + math.floor(h / 2) }
        local currentPos = { x = noiseX[i], y = noiseY[i] + math.floor(h / 2) }
        for x = lastPos.x, currentPos.x do
            local t = (currentPos.x - lastPos.x == 0) and 0 or ((x - lastPos.x) / (currentPos.x - lastPos.x))
            local height = math.floor(lerp(t, lastPos.y, currentPos.y))
            height = math.max(0, math.min(h - 1, height))
            for y = 0, height do
                grid[x][y] = solidTile
            end
        end
    end
    return grid
end

return unity
