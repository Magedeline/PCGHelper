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
-- 2D Simplex noise (Ken Perlin's simplex algorithm, ported from
-- https://github.com/weswigham/simplex). Skews the input onto a triangular
-- grid and sums contributions from 3 corners instead of 4, which removes
-- the faint axis-aligned bias visible in the classic Perlin noise above and
-- is cheaper per sample. Uses '%' instead of the reference's bit.band so it
-- has no LuaJIT bitop dependency.
-- =========================================================================
local SimplexPerm = {
    151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
    140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,
    247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,
    57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,
    74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,
    60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,
    65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,
    200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,
    52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,
    207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,
    119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,
    129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,
    218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,
    81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,
    184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,
    222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180
}
-- Duplicate so ii + perm[jj] (up to 510) never needs index wrapping.
for i = 1, 256 do SimplexPerm[i + 256] = SimplexPerm[i] end

-- Same 12 gradient directions the reference uses for both its 2D and 3D noise.
local SimplexGrad3 = {
    {1,1,0}, {-1,1,0}, {1,-1,0}, {-1,-1,0},
    {1,0,1}, {-1,0,1}, {1,0,-1}, {-1,0,-1},
    {0,1,1}, {0,-1,1}, {0,1,-1}, {0,-1,-1},
}

-- SimplexPerm is a 1-based Lua array standing in for the reference's 0-based
-- perm[0..511]; simplexPerm(k) reads perm[k] for k in [0, 511].
local function simplexPerm(k)
    return SimplexPerm[k + 1]
end

local function simplexDot2D(g, x, y)
    return g[1] * x + g[2] * y
end

local SimplexF2 = 0.5 * (math.sqrt(3.0) - 1.0)
local SimplexG2 = (3.0 - math.sqrt(3.0)) / 6.0

-- Raw 2D simplex noise in [-1, 1].
local function simplexNoise2DRaw(xin, yin)
    local n0, n1, n2

    local s = (xin + yin) * SimplexF2
    local i = math.floor(xin + s)
    local j = math.floor(yin + s)
    local t = (i + j) * SimplexG2
    local X0 = i - t
    local Y0 = j - t
    local x0 = xin - X0
    local y0 = yin - Y0

    local i1, j1
    if x0 > y0 then i1, j1 = 1, 0 else i1, j1 = 0, 1 end

    local x1 = x0 - i1 + SimplexG2
    local y1 = y0 - j1 + SimplexG2
    local x2 = x0 - 1.0 + 2.0 * SimplexG2
    local y2 = y0 - 1.0 + 2.0 * SimplexG2

    local ii = i % 256
    local jj = j % 256

    local gi0 = simplexPerm(ii + simplexPerm(jj)) % 12
    local gi1 = simplexPerm(ii + i1 + simplexPerm(jj + j1)) % 12
    local gi2 = simplexPerm(ii + 1 + simplexPerm(jj + 1)) % 12

    local t0 = 0.5 - x0 * x0 - y0 * y0
    if t0 < 0 then
        n0 = 0.0
    else
        t0 = t0 * t0
        n0 = t0 * t0 * simplexDot2D(SimplexGrad3[gi0 + 1], x0, y0)
    end

    local t1 = 0.5 - x1 * x1 - y1 * y1
    if t1 < 0 then
        n1 = 0.0
    else
        t1 = t1 * t1
        n1 = t1 * t1 * simplexDot2D(SimplexGrad3[gi1 + 1], x1, y1)
    end

    local t2 = 0.5 - x2 * x2 - y2 * y2
    if t2 < 0 then
        n2 = 0.0
    else
        t2 = t2 * t2
        n2 = t2 * t2 * simplexDot2D(SimplexGrad3[gi2 + 1], x2, y2)
    end

    return 70.0 * (n0 + n1 + n2)
end

-- Simplex noise mapped to [0, 1], matching perlinNoise2D's convention above.
local function simplexNoise2D(x, y)
    return (simplexNoise2DRaw(x, y) + 1) * 0.5
end

-- Fractal Brownian motion: layers `octaves` simplex samples at doubling
-- frequency / decaying amplitude for richer, less uniform terrain than a
-- single-frequency sample (e.g. ridged summits vs. smooth plains). Result
-- is mapped to [0, 1].
local function simplexFbm2D(x, y, octaves, persistence, lacunarity)
    octaves = math.max(1, octaves or 4)
    persistence = persistence or 0.5
    lacunarity = lacunarity or 2.0
    local total, amplitude, frequency, maxValue = 0, 1, 1, 0
    for _ = 1, octaves do
        total = total + simplexNoise2DRaw(x * frequency, y * frequency) * amplitude
        maxValue = maxValue + amplitude
        amplitude = amplitude * persistence
        frequency = frequency * lacunarity
    end
    return (total / maxValue + 1) * 0.5
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
-- Part 1: Simplex top layer
-- Drop-in simplex replacement for perlinTopLayer above.
-- =========================================================================
function unity.simplexTopLayer(w, h, rng, solidTile, seed, reduction)
    solidTile = solidTile or "1"
    seed = seed or rng:nextDouble() * 1000
    reduction = reduction or 0.5
    local scale = 0.05
    local grid = pcg.newGrid(w, h, "0")
    for x = 0, w - 1 do
        local n = simplexNoise2D(x * scale, seed)
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
-- Part 2: Simplex noise cave
-- 2D simplex thresholded to binary; drop-in replacement for perlinCave.
-- =========================================================================
function unity.simplexCave(w, h, rng, solidTile, modifier, edgesAreWalls)
    solidTile = solidTile or "1"
    modifier = modifier or 0.1
    edgesAreWalls = edgesAreWalls ~= false
    local seedX = rng:nextDouble() * 1000
    local seedY = rng:nextDouble() * 1000
    local grid = pcg.newGrid(w, h, "0")
    for x = 0, w - 1 do
        for y = 0, h - 1 do
            if edgesAreWalls and (x == 0 or y == 0 or x == w - 1 or y == h - 1) then
                grid[x][y] = solidTile
            else
                local n = simplexNoise2D(x * modifier + seedX, y * modifier + seedY)
                grid[x][y] = (n >= 0.5) and solidTile or "0"
            end
        end
    end
    return grid
end

-- =========================================================================
-- Part 2: Simplex FBM cave
-- Layers multiple simplex octaves (fractal Brownian motion) before
-- thresholding, giving richer, less uniform texture than a single-frequency
-- cave — useful for a distinct "new environment" biome look.
-- =========================================================================
function unity.simplexFbmCave(w, h, rng, solidTile, modifier, octaves, persistence, edgesAreWalls)
    solidTile = solidTile or "1"
    modifier = modifier or 0.1
    octaves = math.max(1, octaves or 4)
    persistence = persistence or 0.5
    edgesAreWalls = edgesAreWalls ~= false
    local seedX = rng:nextDouble() * 1000
    local seedY = rng:nextDouble() * 1000
    local grid = pcg.newGrid(w, h, "0")
    for x = 0, w - 1 do
        for y = 0, h - 1 do
            if edgesAreWalls and (x == 0 or y == 0 or x == w - 1 or y == h - 1) then
                grid[x][y] = solidTile
            else
                local n = simplexFbm2D(x * modifier + seedX, y * modifier + seedY, octaves, persistence, 2.0)
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
