-- pcg_toolkit.lua
-- Shared helpers for the PCG Loenn scripts, ported from the Rysy C# scripts:
--   * MdmcConfigMatrix  (3x3 configuration matrix parser)
--   * WfcTileGenerator  (wave-function-collapse tile generator, CelesteWFC-style)
--   * PlatformerRepair  (jump/dash/climb reachability + repair)
--   * Common MdMC / scoring / entity / room helpers used by the generator scripts
--
-- Internal tile grids are 0-based: grid[x][y] with x in [0, w-1], y in [0, h-1],
-- each cell a single-character string ('0' = air). This mirrors the C# char[,]
-- so the algorithm bodies port almost line-for-line.

local matrixLib = require("utils.matrix")
local tilesStruct = require("structs.tiles")
local objectTilesStruct = require("structs.object_tiles")

local pcg = {}

local TILE = 8

-- =========================================================================
-- Logging
-- =========================================================================
local function log(msg)
    print("[PCG] " .. tostring(msg))
end
pcg.log = log

-- =========================================================================
-- RNG  (LCG — Lua 5.1 has no bitwise operators, so we avoid xorshift)
-- Mirrors the subset of System.Random used by the C# scripts:
--   rng:nextDouble()      -> [0, 1)
--   rng:next(hi)          -> [0, hi)        (C# Next(hi))
--   rng:nextRange(lo, hi) -> [lo, hi] incl. (C# Next(lo, hi+1))
-- =========================================================================
function pcg.makeRng(seed)
    local state
    if seed == nil or seed == -1 then
        state = (os.time() * 1000003) % 4294967296
        if math.random then state = (state + math.random(0, 999999)) % 4294967296 end
    else
        state = seed % 4294967296
    end
    if state == 0 then state = 257 end

    local M = 4294967296 -- 2^32
    local function nextRaw()
        state = (state * 1664525 + 1013904223) % M
        return state
    end

    local rng = {}
    function rng:nextDouble()
        return nextRaw() / M
    end
    function rng:next(hi)
        if hi == nil then return nextRaw() end
        if hi <= 0 then return 0 end
        local r = math.floor(self:nextDouble() * hi)
        if r >= hi then r = hi - 1 end
        return r
    end
    function rng:nextRange(lo, hi)
        return lo + self:next(hi - lo + 1)
    end
    return rng
end

-- =========================================================================
-- Tile grid <-> Loenn matrix conversion
-- =========================================================================

-- Loenn matrices are 1-based (x: 1..w, y: 1..h). We expose a 0-based grid.
function pcg.matrixToGrid(matrix)
    local w, h = matrix:size()
    local grid = {}
    for x = 0, w - 1 do
        grid[x] = {}
        for y = 0, h - 1 do
            grid[x][y] = matrix:get(x + 1, y + 1, "0") or "0"
        end
    end
    return grid, w, h
end

function pcg.gridToMatrix(grid, w, h)
    local m = matrixLib.filled("0", w, h)
    for x = 0, w - 1 do
        for y = 0, h - 1 do
            m:set(x + 1, y + 1, grid[x][y] or "0")
        end
    end
    return m
end

function pcg.tilesStructToGrid(tiles)
    if not tiles or not tiles.matrix then
        return nil, 0, 0
    end
    return pcg.matrixToGrid(tiles.matrix)
end

function pcg.gridToTilesStruct(grid, w, h)
    return tilesStruct.fromMatrix(pcg.gridToMatrix(grid, w, h))
end

function pcg.newGrid(w, h, fill)
    fill = fill or "0"
    local grid = {}
    for x = 0, w - 1 do
        grid[x] = {}
        for y = 0, h - 1 do
            grid[x][y] = fill
        end
    end
    return grid
end

-- SafeTileAt equivalent: out-of-bounds returns '0'
function pcg.getTile(grid, x, y, w, h)
    if x < 0 or y < 0 or x >= w or y >= h then return "0" end
    return grid[x][y] or "0"
end

function pcg.setTile(grid, x, y, w, h, v)
    if x < 0 or y < 0 or x >= w or y >= h then return end
    grid[x][y] = v
end

-- =========================================================================
-- MdmcConfigMatrix  (paper §3.3.2)
-- =========================================================================
pcg.MdmcDefault = "000011012"

pcg.MdmcPresets = {
    ["000011012"] = "E+S — L-shape (paper default)",
    ["000011112"] = "E+SW+S — 3-neighbour causal",
    ["001001112"] = "NE+E+SW+S — 4-neighbour (paper)",
    ["011011012"] = "N+NE+W+E+S — 5-neighbour",
    ["010111010"] = "N+W+E+S — cross (recommended for WFC)",
    ["101000101"] = "NW+NE+SW+SE — diagonals only",
    ["111101111"] = "All 8 neighbours — full context",
}

-- Celeste tileset families: canonical style -> new and old foreground IDs.
-- Background tiles use the same ID characters (the renderer distinguishes layer).
pcg.StyleFamilies = {
    city       = { new = "1", old = "2" },
    snow       = { new = "3", old = "4" },
    resort     = { new = "5", old = "6" },
    cave       = { new = "8", old = "9" },
    temple     = { new = "d", old = "a" },
    reflection = { new = "g", old = "b" },
    summit     = { new = "i", old = "c" },
    core       = { new = "k", old = "e" },
}

function pcg.parseConfig(cfg)
    local valid = cfg ~= nil and #cfg == 9
    if valid then
        for i = 1, #cfg do
            local c = cfg:sub(i, i)
            if c ~= "0" and c ~= "1" and c ~= "2" then valid = false break end
        end
    end
    if not valid then
        if cfg and #cfg > 0 then
            log("Invalid configuration matrix '" .. tostring(cfg) .. "' — falling back to " .. pcg.MdmcDefault)
        end
        cfg = pcg.MdmcDefault
    end

    local offsets = {}
    for k = 0, 8 do
        if k ~= 4 then
            local c = cfg:sub(k + 1, k + 1)
            if c == "1" then
                local dy = math.floor(k / 3) - 1
                local dx = (k % 3) - 1
                table.insert(offsets, { dy = dy, dx = dx })
            end
        end
    end
    if #offsets == 0 then return pcg.parseConfig(pcg.MdmcDefault) end
    return offsets
end

-- =========================================================================
-- WfcTileGenerator  (inspired by aczw/CelesteWFC)
-- Domains are boolean arrays indexed 1..n (n = alphabet size, <= 64).
-- =========================================================================

local function domainFull(n)
    local d = {}
    for i = 1, n do d[i] = true end
    return d
end

local function domainSize(dom, n)
    local c = 0
    for i = 1, n do if dom[i] then c = c + 1 end end
    return c
end

local function domainCopy(dom, n)
    local d = {}
    for i = 1, n do d[i] = dom[i] end
    return d
end

-- Computes allowed = union of allowed[d][ti] for every ti present in dom.
local function allowedUnion(allowedD, dom, n)
    local u = {}
    for ti = 1, n do
        if dom[ti] then
            local a = allowedD[ti]
            if a then
                for ni = 1, n do
                    if a[ni] then u[ni] = true end
                end
            end
        end
    end
    return u
end

-- Trains adjacency rules + tile weights from the given grids.
-- grids: list of 0-based grids. offsets: list of {dy,dx}.
-- Returns model table or nil when data too uniform.
function pcg.trainAdjacency(grids, offsets)
    local freq = {}
    for _, g in ipairs(grids) do
        local w, h = pcg.gridSize(g)
        for x = 0, w - 1 do
            for y = 0, h - 1 do
                local t = pcg.getTile(g, x, y, w, h)
                freq[t] = (freq[t] or 0) + 1
            end
        end
    end
    freq["0"] = math.max(freq["0"] or 1, 1)

    local count = 0
    for _ in pairs(freq) do count = count + 1 end
    if count < 2 then return nil end

    -- alphabet sorted by frequency desc, take <= 64
    local sorted = {}
    for ch, c in pairs(freq) do table.insert(sorted, { ch = ch, c = c }) end
    table.sort(sorted, function(a, b) return a.c > b.c end)
    local alphabet = {}
    local index = {}
    local n = 0
    for i = 1, math.min(64, #sorted) do
        n = n + 1
        alphabet[n] = sorted[i].ch
        index[sorted[i].ch] = n
    end

    -- symmetric closure of constraint directions
    local dirSet = {}
    local function key(dy, dx) return dy .. "," .. dx end
    for _, o in ipairs(offsets) do
        dirSet[key(o.dy, o.dx)] = { dy = o.dy, dx = o.dx }
        dirSet[key(-o.dy, -o.dx)] = { dy = -o.dy, dx = -o.dx }
    end
    dirSet[key(0, 0)] = nil
    local dirs = {}
    for _, d in pairs(dirSet) do table.insert(dirs, d) end
    if #dirs == 0 then
        dirs = { { dy = 0, dx = 1 }, { dy = 0, dx = -1 }, { dy = 1, dx = 0 }, { dy = -1, dx = 0 } }
    end

    -- allowed[d][ti] = set of neighbour indices
    local allowed = {}
    for d = 1, #dirs do
        allowed[d] = {}
        for ti = 1, n do allowed[d][ti] = {} end
    end

    for _, g in ipairs(grids) do
        local w, h = pcg.gridSize(g)
        for x = 0, w - 1 do
            for y = 0, h - 1 do
                local ti = index[pcg.getTile(g, x, y, w, h)]
                if ti then
                    for d = 1, #dirs do
                        local nx = x + dirs[d].dx
                        local ny = y + dirs[d].dy
                        local ni = index[pcg.getTile(g, nx, ny, w, h)]
                        if ni then allowed[d][ti][ni] = true end
                    end
                end
            end
        end
    end

    local total = 0.0
    for i = 1, n do total = total + freq[alphabet[i]] end
    local weights = {}
    for i = 1, n do weights[i] = freq[alphabet[i]] / total end

    return {
        alphabet = alphabet,
        weights = weights,
        dirs = dirs,
        allowed = allowed,
        index = index,
        n = n,
    }
end

-- Helper: get grid w/h from a 0-based grid (max x/y + 1)
function pcg.gridSize(grid)
    local w, h = 0, 0
    for x, col in pairs(grid) do
        local xi = tonumber(x)
        if xi and xi >= w then w = xi + 1 end
        for y, _ in pairs(col) do
            local yi = tonumber(y)
            if yi and yi >= h then h = yi + 1 end
        end
    end
    return w, h
end

-- Runs one WFC attempt. Returns 0-based grid or nil on contradiction.
function pcg.wfcGenerate(model, w, h, rng, constrainBorderSolid)
    if constrainBorderSolid == nil then constrainBorderSolid = true end
    local n = model.n
    local ndirs = #model.dirs

    -- domains[idx] = boolean array 1..n, idx = y*w + x (0-based)
    local domains = {}
    local full = domainFull(n)
    for i = 0, w * h - 1 do domains[i] = domainCopy(full, n) end

    local inQueue = {}
    local queue = {} -- simple list used as FIFO
    local qHead = 1
    local function enqueue(idx)
        if not inQueue[idx] then
            inQueue[idx] = true
            table.insert(queue, idx)
        end
    end

    if constrainBorderSolid and model.index["0"] then
        local airIdx = model.index["0"]
        local solidMask = domainCopy(full, n)
        solidMask[airIdx] = false
        local hasSolid = false
        for i = 1, n do if solidMask[i] then hasSolid = true break end end
        if hasSolid then
            for x = 0, w - 1 do
                domains[x] = domainCopy(solidMask, n); enqueue(x)
                domains[(h - 1) * w + x] = domainCopy(solidMask, n); enqueue((h - 1) * w + x)
            end
            for y = 0, h - 1 do
                domains[y * w] = domainCopy(solidMask, n); enqueue(y * w)
                domains[y * w + w - 1] = domainCopy(solidMask, n); enqueue(y * w + w - 1)
            end
        end
    end

    local function propagate()
        while qHead <= #queue do
            local idx = queue[qHead]; qHead = qHead + 1
            inQueue[idx] = false
            local cx = idx % w
            local cy = math.floor(idx / w)
            local dom = domains[idx]
            for d = 1, ndirs do
                local nx = cx + model.dirs[d].dx
                local ny = cy + model.dirs[d].dy
                if nx >= 0 and ny >= 0 and nx < w and ny < h then
                    local nIdx = ny * w + nx
                    local allow = allowedUnion(model.allowed[d], dom, n)
                    local nd = domains[nIdx]
                    local changed = false
                    local empty = true
                    for i = 1, n do
                        if nd[i] and not allow[i] then
                            nd[i] = false
                            changed = true
                        end
                        if nd[i] then empty = false end
                    end
                    if changed then
                        if empty then return false end
                        enqueue(nIdx)
                    end
                end
            end
        end
        return true
    end

    -- drain helper: reset queue between phases
    local function drainQueue()
        queue = {}
        qHead = 1
        inQueue = {}
    end

    if not propagate() then return nil end

    while true do
        drainQueue()
        local bestIdx = -1
        local bestEntropy = math.huge
        for i = 0, w * h - 1 do
            local sz = domainSize(domains[i], n)
            if sz > 1 then
                local sumW, sumWLog = 0.0, 0.0
                for ti = 1, n do
                    if domains[i][ti] then
                        local wt = model.weights[ti]
                        sumW = sumW + wt
                        sumWLog = sumWLog + wt * math.log(wt)
                    end
                end
                local entropy = math.log(sumW) - sumWLog / sumW + rng:nextDouble() * 1e-6
                if entropy < bestEntropy then bestEntropy = entropy bestIdx = i end
            end
        end
        if bestIdx < 0 then break end

        -- frequency-weighted collapse
        local dom = domains[bestIdx]
        local totalW = 0.0
        for ti = 1, n do if dom[ti] then totalW = totalW + model.weights[ti] end end
        local roll = rng:nextDouble() * totalW
        local cum, chosen = 0.0, nil
        for ti = 1, n do
            if dom[ti] then
                chosen = ti
                cum = cum + model.weights[ti]
                if roll <= cum then break end
            end
        end
        local newDom = {}
        for ti = 1, n do newDom[ti] = (ti == chosen) end
        domains[bestIdx] = newDom
        enqueue(bestIdx)
        if not propagate() then return nil end
    end

    local tiles = pcg.newGrid(w, h, "0")
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local dom = domains[y * w + x]
            local ch = "0"
            for ti = 1, n do if dom[ti] then ch = model.alphabet[ti] break end end
            tiles[x][y] = ch
        end
    end
    return tiles
end

-- Hybrid helper: checks whether placing candidate at (x,y) violates any
-- learned adjacency rule against already-placed neighbours.
function pcg.isLocallyConsistent(model, grid, w, h, x, y, candidate, isPlaced)
    local ci = model.index[candidate]
    if not ci then return true end
    for d = 1, #model.dirs do
        local nx = x + model.dirs[d].dx
        local ny = y + model.dirs[d].dy
        if nx >= 0 and ny >= 0 and nx < w and ny < h then
            if isPlaced(nx, ny) then
                local ni = model.index[grid[nx][ny] or "0"]
                if ni and not model.allowed[d][ci][ni] then return false end
            end
        end
    end
    return true
end

-- =========================================================================
-- PlatformerRepair  (jump/dash/climb reachability + repair)
-- =========================================================================
pcg.AirBudget = 8
pcg.UpCost = 2
pcg.MaxUnsupportedRun = 4

local function findPois(tiles, w, h)
    local pois = {}

    local function edgeRuns(horizontal, edge, inward)
        local len = horizontal and w or h
        local runStart = -1
        for k = 0, len do
            local air = k < len and (horizontal and tiles[k][edge] == "0" or tiles[edge][k] == "0")
            if air then
                if runStart < 0 then runStart = k end
            else
                if runStart >= 0 and k - runStart >= 2 then
                    local mid = math.floor((runStart + k - 1) / 2)
                    if horizontal then
                        table.insert(pois, { x = mid, y = inward })
                    else
                        table.insert(pois, { x = inward, y = mid })
                    end
                end
                runStart = -1
            end
        end
    end

    edgeRuns(true, 0, 1)
    edgeRuns(true, h - 1, h - 2)
    edgeRuns(false, 0, 1)
    edgeRuns(false, w - 1, w - 2)

    if #pois < 2 then
        local left, right
        for x = 1, w - 2 do
            for y = 1, h - 2 do
                if tiles[x][y] == "0" and tiles[x][y + 1] ~= "0" then
                    if not left then left = { x = x, y = y } end
                    right = { x = x, y = y }
                end
            end
        end
        if left and right and not (left.x == right.x and left.y == right.y) then
            table.insert(pois, left)
            table.insert(pois, right)
        end
    end
    return pois
end

local function computeReachable(tiles, w, h, start)
    local reach = {}
    for x = 0, w - 1 do reach[x] = {} end
    if tiles[start.x][start.y] ~= "0" then return reach end

    local bestBudget = {}
    for x = 0, w - 1 do
        bestBudget[x] = {}
        for y = 0, h - 1 do bestBudget[x][y] = -1 end
    end

    local q = {}
    local qHead = 1
    table.insert(q, { x = start.x, y = start.y, b = pcg.AirBudget })
    bestBudget[start.x][start.y] = pcg.AirBudget
    reach[start.x][start.y] = true

    local moves = {
        { dx = -1, dy = 0, cost = 1 },
        { dx = 1, dy = 0, cost = 1 },
        { dx = 0, dy = 1, cost = 0 },
        { dx = 0, dy = -1, cost = pcg.UpCost },
    }

    while qHead <= #q do
        local cur = q[qHead]; qHead = qHead + 1
        local x, y, b = cur.x, cur.y, cur.b
        local standing = (y + 1 < h and tiles[x][y + 1] ~= "0")
        local climbing = (x > 0 and tiles[x - 1][y] ~= "0") or (x + 1 < w and tiles[x + 1][y] ~= "0")
        local b0 = (standing or climbing) and pcg.AirBudget or b

        for _, mv in ipairs(moves) do
            local nx = x + mv.dx
            local ny = y + mv.dy
            if nx >= 0 and ny >= 0 and nx < w and ny < h then
                if tiles[nx][ny] == "0" then
                    local nb = b0 - mv.cost
                    if nb >= 0 and nb > bestBudget[nx][ny] then
                        bestBudget[nx][ny] = nb
                        reach[nx][ny] = true
                        table.insert(q, { x = nx, y = ny, b = nb })
                    end
                end
            end
        end
    end
    return reach
end

local function bridgeTo(tiles, w, h, reach, goal, solid)
    local dist = {}
    local parent = {}
    for x = 0, w - 1 do
        dist[x] = {}
        parent[x] = {}
        for y = 0, h - 1 do
            dist[x][y] = math.huge
            parent[x][y] = { x = -1, y = -1 }
        end
    end

    -- 0-1 BFS using a deque (two lists: front and back)
    local front, back = {}, {}
    local fHead = 1
    for x = 1, w - 2 do
        for y = 1, h - 2 do
            if reach[x][y] then
                dist[x][y] = 0
                table.insert(back, { x = x, y = y })
            end
        end
    end
    if #back == 0 then return end

    local dxs = { -1, 1, 0, 0 }
    local dys = { 0, 0, -1, 1 }

    local function popFront()
        if fHead <= #front then
            local v = front[fHead]; front[fHead] = nil; fHead = fHead + 1
            return v
        else
            return table.remove(back, 1)
        end
    end
    local function pushFront(v)
        table.insert(front, v) -- not a true deque but cost-0 pushes go to front list
    end
    local function pushBack(v)
        table.insert(back, v)
    end

    while #front - (fHead - 1) + #back > 0 do
        local cur = popFront()
        if not cur then break end
        local x, y = cur.x, cur.y
        for d = 1, 4 do
            local nx = x + dxs[d]
            local ny = y + dys[d]
            if nx >= 1 and ny >= 1 and nx < w - 1 and ny < h - 1 then
                local cost = tiles[nx][ny] == "0" and 0 or 1
                local nd = dist[x][y] + cost
                if nd < dist[nx][ny] then
                    dist[nx][ny] = nd
                    parent[nx][ny] = { x = x, y = y }
                    if cost == 0 then pushFront({ x = nx, y = ny }) else pushBack({ x = nx, y = ny }) end
                end
            end
        end
    end

    if dist[goal.x][goal.y] == math.huge then return end

    -- build path goal -> frontier
    local path = {}
    local cur = { x = goal.x, y = goal.y }
    while cur.x >= 0 do
        table.insert(path, { x = cur.x, y = cur.y })
        if dist[cur.x][cur.y] == 0 then break end
        cur = parent[cur.x][cur.y]
    end
    -- reverse
    local function reverse(t)
        local r = {}
        for i = #t, 1, -1 do table.insert(r, t[i]) end
        return r
    end
    path = reverse(path)
    local onPath = {}
    for _, p in ipairs(path) do onPath[p.x .. "," .. p.y] = true end

    -- carve corridor (2 tiles tall)
    for _, p in ipairs(path) do
        if tiles[p.x][p.y] ~= "0" then tiles[p.x][p.y] = "0" end
        if p.y - 1 >= 1 and tiles[p.x][p.y - 1] ~= "0" and not onPath[p.x .. "," .. (p.y - 1)] then
            tiles[p.x][p.y - 1] = "0"
        end
    end

    -- stepping stones
    local sinceSupport = 0
    for _, p in ipairs(path) do
        local px, py = p.x, p.y
        local supported =
            (py + 1 < h and tiles[px][py + 1] ~= "0") or
            (py + 2 < h and tiles[px][py + 2] ~= "0") or
            (px > 0 and tiles[px - 1][py] ~= "0") or
            (px + 1 < w and tiles[px + 1][py] ~= "0")

        if supported then sinceSupport = 0
        else
            sinceSupport = sinceSupport + 1
            if sinceSupport < pcg.MaxUnsupportedRun then
            else
                if py + 2 <= h - 1 and not onPath[px .. "," .. (py + 2)] and tiles[px][py + 2] == "0" then
                    tiles[px][py + 2] = solid
                elseif py + 1 <= h - 1 and not onPath[px .. "," .. (py + 1)] and tiles[px][py + 1] == "0" then
                    tiles[px][py + 1] = solid
                end
                sinceSupport = 0
            end
        end
    end
end

function pcg.ensurePlayable(tiles, w, h, solid, maxRepairs)
    if maxRepairs == nil then maxRepairs = 3 end
    if w < 5 or h < 5 then return true end

    local pois = findPois(tiles, w, h)
    local start = { x = -1, y = -1 }
    for _, p in ipairs(pois) do
        if tiles[p.x][p.y] == "0" then start = p break end
    end
    if start.x < 0 or #pois < 2 then return true end

    local attempt = 0
    while true do
        local reach = computeReachable(tiles, w, h, start)
        local unreachable = {}
        for _, p in ipairs(pois) do
            if not reach[p.x][p.y] then table.insert(unreachable, p) end
        end
        if #unreachable == 0 then
            if attempt > 0 then log("Repaired room traversal in " .. attempt .. " pass(es)") end
            return true
        end
        if attempt >= maxRepairs then
            log(#unreachable .. " exit(s) still unreachable after " .. maxRepairs .. " repair passes")
            return false
        end
        for _, goal in ipairs(unreachable) do
            bridgeTo(tiles, w, h, reach, goal, solid)
        end
        attempt = attempt + 1
    end
end

-- =========================================================================
-- Shared MdMC / scoring / entity helpers
-- =========================================================================

function pcg.dominantSolidTile(grids)
    local freq = {}
    for _, g in ipairs(grids) do
        local w, h = pcg.gridSize(g)
        for x = 0, w - 1 do
            for y = 0, h - 1 do
                local t = pcg.getTile(g, x, y, w, h)
                if t ~= "0" then freq[t] = (freq[t] or 0) + 1 end
            end
        end
    end
    local best, bestC = "3", 0
    for t, c in pairs(freq) do
        if c > bestC then best, bestC = t, c end
    end
    return best
end

-- Counts n-gram -> { tileChar -> count }.
function pcg.train(grids, offsets)
    local counts = {}
    for _, grid in ipairs(grids) do
        local w, h = pcg.gridSize(grid)
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local ngram = pcg.buildNgramFromArray(grid, x, y, offsets, w, h)
                local tile = pcg.getTile(grid, x, y, w, h)
                local tc = counts[ngram]
                if not tc then tc = {} counts[ngram] = tc end
                tc[tile] = (tc[tile] or 0) + 1
            end
        end
    end
    return counts
end

function pcg.buildNgramFromArray(grid, x, y, offsets, w, h)
    local buf = {}
    for k, o in ipairs(offsets) do
        local nx = x + o.dx
        local ny = y + o.dy
        buf[k] = (nx < 0 or ny < 0 or nx >= w or ny >= h) and "0" or (grid[nx][ny] or "0")
    end
    return table.concat(buf)
end

function pcg.normalise(counts)
    local probs = {}
    for ngram, tc in pairs(counts) do
        local total = 0.0
        for _, c in pairs(tc) do total = total + c end
        local dist = {}
        for tile, cnt in pairs(tc) do dist[tile] = cnt / total end
        probs[ngram] = dist
    end
    return probs
end

function pcg.sample(dist, rng)
    local r = rng:nextDouble()
    local cum = 0.0
    local last = nil
    for tile, prob in pairs(dist) do
        last = tile
        cum = cum + prob
        if r <= cum then return tile end
    end
    return last
end

function pcg.injectSyntheticNGrams(counts, dominantTile, offsets)
    local contextCount = #offsets
    if contextCount == 0 then return end
    local airNgram = string.rep("0", contextCount)
    local solidNgram = string.rep(dominantTile, contextCount)

    if not counts[airNgram] then
        counts[airNgram] = { ["0"] = 7, [dominantTile] = 3 }
    end
    if not counts[solidNgram] then
        counts[solidNgram] = { ["0"] = 2, [dominantTile] = 8 }
    end

    local rng = pcg.makeRng(42)
    local limit = math.min(8, math.floor(2 ^ contextCount))
    for i = 1, limit do
        local buf = {}
        for j = 1, contextCount do
            buf[j] = rng:nextDouble() > 0.5 and "0" or dominantTile
        end
        local mixed = table.concat(buf)
        if not counts[mixed] then
            counts[mixed] = { ["0"] = rng:nextRange(3, 6), [dominantTile] = rng:nextRange(3, 6) }
        end
    end
    log("Injected synthetic n-grams (now have " .. pcg.tableCount(counts) .. " total)")
end

function pcg.tableCount(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

-- MdMC generation with tile-level backtracking (paper §3.3.2).
function pcg.generateMdmc(probs, offsets, w, h, maxBacktrackDepth, rng, defaultTile, adjacency)
    if defaultTile == nil then defaultTile = "3" end

    -- collect all known tile chars
    local allTiles = {}
    local seen = {}
    for _, dist in pairs(probs) do
        for tile, _ in pairs(dist) do
            if not seen[tile] then seen[tile] = true table.insert(allTiles, tile) end
        end
    end
    if #allTiles == 0 then allTiles = { "0", defaultTile } end
    if not seen["0"] then table.insert(allTiles, "0") end
    if not seen[defaultTile] then table.insert(allTiles, defaultTile) end

    local tiles = pcg.newGrid(w, h, "0")

    -- scan right-to-left, bottom-to-top
    local order = {}
    for y = h - 1, 0, -1 do
        for x = w - 1, 0, -1 do
            table.insert(order, { x = x, y = y })
        end
    end

    local tried = {}
    local useFallback = pcg.tableCount(probs) < 10
    if useFallback then log("Using fallback distribution for unseen n-grams (sparse training data)") end

    local pos = 1
    local backtrackCount = 0
    local maxSteps = math.max(#order * 8, 4096)
    local steps = 0
    -- Number of cells that had to be filled with a random tile because the
    -- model had no answer ("degeneration", paper §3.3.2). Returned so callers
    -- can reject rooms that are mostly noise.
    local degenCount = 0

    while pos <= #order do
        steps = steps + 1
        if steps > maxSteps then
            for p = pos, #order do
                local fxy = order[p]
                local ngramF = pcg.buildNgramFromArray(tiles, fxy.x, fxy.y, offsets, w, h)
                local fdist = probs[ngramF]
                if fdist and pcg.tableCount(fdist) > 0 then
                    tiles[fxy.x][fxy.y] = pcg.sample(fdist, rng)
                else
                    tiles[fxy.x][fxy.y] = allTiles[rng:next(#allTiles) + 1]
                    degenCount = degenCount + 1
                end
            end
            log("Backtracking exceeded step budget - finished room with a greedy pass")
            break
        end

        local xy = order[pos]
        local x, y = xy.x, xy.y
        local posKey = y * w + x
        local triedSet = tried[posKey]
        if not triedSet then triedSet = {} tried[posKey] = triedSet end

        local ngram = pcg.buildNgramFromArray(tiles, x, y, offsets, w, h)
        local dist = probs[ngram]
        local hasNgram = dist ~= nil

        if not hasNgram and useFallback then
            dist = { ["0"] = 0.5, [defaultTile] = 0.5 }
            hasNgram = true
        end

        if hasNgram then
            -- total weight over untried tiles
            local totalWeight = 0.0
            for tile, prob in pairs(dist) do
                if not triedSet[tile] then totalWeight = totalWeight + prob end
            end

            if totalWeight > 0 then
                local r = rng:nextDouble() * totalWeight
                local cum = 0.0
                local chosen, lastUntried
                for tile, prob in pairs(dist) do
                    if not triedSet[tile] then
                        lastUntried = tile
                        cum = cum + prob
                        if r <= cum then chosen = tile break end
                    end
                end
                if not chosen then chosen = lastUntried end
                triedSet[chosen] = true

                if adjacency then
                    local function isPlaced(nx, ny)
                        return ny > y or (ny == y and nx > x)
                    end
                    if not pcg.isLocallyConsistent(adjacency, tiles, w, h, x, y, chosen, isPlaced) then
                        -- veto: stay at same pos, resample next iteration
                    else
                        tiles[x][y] = chosen
                        pos = pos + 1
                        backtrackCount = 0
                    end
                else
                    tiles[x][y] = chosen
                    pos = pos + 1
                    backtrackCount = 0
                end
            end
        end

        -- If we didn't advance, backtrack.
        if pos <= #order and order[pos].x == x and order[pos].y == y then
            -- still at same cell -> all options exhausted
            tried[posKey] = nil
            tiles[x][y] = "0"
            if pos == 1 or backtrackCount >= maxBacktrackDepth then
                tiles[x][y] = allTiles[rng:next(#allTiles) + 1]
                degenCount = degenCount + 1
                pos = pos + 1
                backtrackCount = 0
            else
                backtrackCount = backtrackCount + 1
                pos = pos - 1
            end
        end
    end

    return tiles, degenCount
end

function pcg.applyBorder(tiles, w, h, borderTile)
    for x = 0, w - 1 do tiles[x][0] = borderTile tiles[x][h - 1] = borderTile end
    for y = 0, h - 1 do tiles[0][y] = borderTile tiles[w - 1][y] = borderTile end
end

function pcg.generateFallback(w, h, material, rng, solidRatio)
    if solidRatio == nil then solidRatio = 0.35 end
    local m = pcg.newGrid(w, h, "0")
    for y = h - 3, h - 1 do
        for x = 0, w - 1 do m[x][y] = material end
    end
    local platformCount = math.max(2, math.floor(w * h * solidRatio * 0.02))
    for p = 1, platformCount do
        local px = rng:nextRange(3, w - 6)
        local py = rng:nextRange(4, h - 5)
        local pLen = rng:nextRange(3, 7)
        for dx = 0, pLen - 1 do
            if px + dx < w - 1 then m[px + dx][py] = material end
        end
    end
    return m
end

function pcg.cleanupTiles(tiles, w, h, dominantTile)
    -- remove isolated single tiles
    for y = 1, h - 2 do
        for x = 1, w - 2 do
            if tiles[x][y] ~= "0" then
                local neighbors = 0
                if tiles[x - 1][y] ~= "0" then neighbors = neighbors + 1 end
                if tiles[x + 1][y] ~= "0" then neighbors = neighbors + 1 end
                if tiles[x][y - 1] ~= "0" then neighbors = neighbors + 1 end
                if tiles[x][y + 1] ~= "0" then neighbors = neighbors + 1 end
                if neighbors == 0 then tiles[x][y] = "0" end
            end
        end
    end
    -- fill 1x1 holes inside solids
    for y = 1, h - 2 do
        for x = 1, w - 2 do
            if tiles[x][y] == "0" then
                local sn = 0
                if tiles[x - 1][y] ~= "0" then sn = sn + 1 end
                if tiles[x + 1][y] ~= "0" then sn = sn + 1 end
                if tiles[x][y - 1] ~= "0" then sn = sn + 1 end
                if tiles[x][y + 1] ~= "0" then sn = sn + 1 end
                if sn == 4 then tiles[x][y] = dominantTile end
            end
        end
    end
end

function pcg.autoTilePass(tiles, w, h, dominantTile)
    for y = 1, h - 2 do
        for x = 1, w - 2 do
            local current = tiles[x][y]
            if current ~= "0" then
                local neighborTypes = {}
                local function addT(t) if t ~= "0" then neighborTypes[t] = true end end
                addT(tiles[x - 1][y]) addT(tiles[x + 1][y])
                addT(tiles[x][y - 1]) addT(tiles[x][y + 1])

                local ntypes = 0
                for _ in pairs(neighborTypes) do ntypes = ntypes + 1 end
                if ntypes > 1 and not neighborTypes[current] then
                    local typeCounts = {}
                    for t, _ in pairs(neighborTypes) do
                        local c = 0
                        if tiles[x - 1][y] == t then c = c + 1 end
                        if tiles[x + 1][y] == t then c = c + 1 end
                        if tiles[x][y - 1] == t then c = c + 1 end
                        if tiles[x][y + 1] == t then c = c + 1 end
                        typeCounts[t] = c
                    end
                    local maxCount = 0
                    for _, c in pairs(typeCounts) do if c > maxCount then maxCount = c end end
                    if (typeCounts[dominantTile] or 0) == maxCount then
                        tiles[x][y] = dominantTile
                    else
                        local mostCommon
                        for t, c in pairs(typeCounts) do
                            if c == maxCount then mostCommon = t break end
                        end
                        tiles[x][y] = mostCommon
                    end
                end
            end
        end
    end
end

function pcg.detectStyle(grids)
    local tileCounts = {}
    for _, grid in ipairs(grids) do
        local w, h = pcg.gridSize(grid)
        for x = 0, w - 1 do
            for y = 0, h - 1 do
                local t = pcg.getTile(grid, x, y, w, h)
                if t ~= "0" then tileCounts[t] = (tileCounts[t] or 0) + 1 end
            end
        end
    end
    local count = 0
    for _ in pairs(tileCounts) do count = count + 1 end
    if count == 0 then return "default", "1", "3", "new" end

    local sorted = {}
    for t, c in pairs(tileCounts) do table.insert(sorted, { t = t, c = c }) end
    table.sort(sorted, function(a, b) return a.c > b.c end)
    local primary = sorted[1].t
    local secondary = #sorted > 1 and sorted[2].t or primary

    -- Map both new and old tile IDs to a canonical style and era.
    local styleMap = {
        ["1"] = "city", ["2"] = "city",
        ["3"] = "snow", ["4"] = "snow",
        ["5"] = "resort", ["6"] = "resort",
        ["8"] = "cave", ["9"] = "cave",
        ["d"] = "temple", ["a"] = "temple",
        ["g"] = "reflection", ["b"] = "reflection",
        ["i"] = "summit", ["c"] = "summit",
        ["k"] = "core", ["e"] = "core",
    }
    local eraMap = {
        ["1"] = "new", ["2"] = "old",
        ["3"] = "new", ["4"] = "old",
        ["5"] = "new", ["6"] = "old",
        ["8"] = "new", ["9"] = "old",
        ["d"] = "new", ["a"] = "old",
        ["g"] = "new", ["b"] = "old",
        ["i"] = "new", ["c"] = "old",
        ["k"] = "new", ["e"] = "old",
    }
    local styleName = styleMap[primary] or "custom"
    local era = eraMap[primary] or "new"
    return styleName, primary, secondary, era
end

function pcg.getStyleDefaultTile(style)
    local m = { city = "1", snow = "3", resort = "5", temple = "d", reflection = "g",
                summit = "i", core = "k", cave = "8" }
    return m[style] or "1"
end

function pcg.resolveTileForStyle(style, era)
    local fam = pcg.StyleFamilies[style]
    if fam then
        return fam[era] or fam.new or "1"
    end
    return pcg.getStyleDefaultTile(style) or "1"
end

function pcg.styleAndEraForTile(id)
    for style, fam in pairs(pcg.StyleFamilies) do
        if fam.new == id then return style, "new" end
        if fam.old == id then return style, "old" end
    end
    return "custom", "new"
end

-- Valid vanilla Celeste decal paths (relative to Graphics/Atlases/Gameplay).
-- These are specific texture files from the vanilla graphics dump, so Lönn and
-- in-game rendering can resolve them without custom assets.
function pcg.decalSetForStyle(style, era)
    local catalog = {
        city       = { bg = { "particles/circle", "particles/cloud" },          fg = { "decals/generic/grass_a", "decals/generic/grass_b", "decals/generic/hanginggrass_a" } },
        snow       = { bg = { "particles/snow" },                               fg = { "decals/generic/snow_a", "decals/generic/snow_b", "decals/generic/snow_c" } },
        resort     = { bg = { "particles/circle", "particles/cloud" },          fg = { "decals/generic/grass_a", "decals/generic/algae_a", "decals/generic/algae_b" } },
        cave       = { bg = { "particles/blob", "particles/circle" },           fg = { "decals/generic/algae_a", "decals/generic/algae_b", "decals/generic/algae_c" } },
        temple     = { bg = { "particles/circle", "particles/blob" },           fg = { "decals/generic/algae_a", "decals/generic/algae_b" } },
        reflection = { bg = { "particles/circle", "particles/cloud" },          fg = { "decals/generic/grass_a", "decals/generic/algae_a" } },
        summit     = { bg = { "particles/snow" },                               fg = { "decals/generic/snow_a", "decals/generic/snow_b", "decals/generic/grass_a" } },
        core       = { bg = { "particles/circle", "particles/fire" },           fg = { "decals/generic/algae_a", "decals/generic/algae_b" } },
    }
    local sets = catalog[style] or catalog["city"]
    if era == "old" then
        -- Old era: keep the same generic decals; they exist in every era.
        local oldOverrides = {
            city       = { fg = { "decals/generic/grass_a", "decals/generic/grass_b" } },
            snow       = { fg = { "decals/generic/snow_a", "decals/generic/snow_b" } },
            resort     = { fg = { "decals/generic/grass_a", "decals/generic/algae_a" } },
        }
        local old = oldOverrides[style]
        if old then
            for k, v in pairs(old) do sets[k] = v end
        end
    end
    return sets
end

-- Ensure a decal texture path is a specific, renderable file. If it looks like a
-- directory, pick a known variant; if it is still unrecognised, fall back to a
-- safe vanilla particle that is guaranteed to render.
function pcg.resolveDecalTexture(name)
    if not name or name == "" then
        return "particles/circle"
    end
    local known = {
        ["particles/circle"] = true, ["particles/cloud"] = true, ["particles/blob"] = true,
        ["particles/snow"] = true, ["particles/fire"] = true,
        ["particles/stars/00"] = true, ["particles/starfield/00"] = true,
        ["decals/generic/grass_a"] = true, ["decals/generic/grass_b"] = true,
        ["decals/generic/grass_c"] = true, ["decals/generic/grass_d"] = true,
        ["decals/generic/hanginggrass_a"] = true,
        ["decals/generic/snow_a"] = true, ["decals/generic/snow_b"] = true,
        ["decals/generic/snow_c"] = true, ["decals/generic/snow_d"] = true,
        ["decals/generic/snow_e"] = true, ["decals/generic/snow_f"] = true,
        ["decals/generic/snow_g"] = true, ["decals/generic/snow_h"] = true,
        ["decals/generic/snow_i"] = true, ["decals/generic/snow_j"] = true,
        ["decals/generic/snow_k"] = true, ["decals/generic/snow_l"] = true,
        ["decals/generic/snow_m"] = true, ["decals/generic/snow_n"] = true,
        ["decals/generic/snow_o"] = true,
        ["decals/generic/algae_a"] = true, ["decals/generic/algae_b"] = true,
        ["decals/generic/algae_c"] = true, ["decals/generic/algae_d"] = true,
        ["decals/generic/algae_e"] = true,
    }
    if known[name] then
        return name
    end
    local directoryVariants = {
        ["decals/generic/grass"] = { "decals/generic/grass_a", "decals/generic/grass_b", "decals/generic/grass_c", "decals/generic/grass_d" },
        ["decals/generic/snow"] = { "decals/generic/snow_a", "decals/generic/snow_b", "decals/generic/snow_c" },
        ["decals/generic/algae"] = { "decals/generic/algae_a", "decals/generic/algae_b", "decals/generic/algae_c" },
        ["particles/stars"] = { "particles/stars/00" },
        ["particles/starfield"] = { "particles/starfield/00" },
    }
    if directoryVariants[name] then
        return directoryVariants[name][1]
    end
    return "particles/circle"
end

function pcg.preserveBordersAndExits(tiles, w, h, originalTiles, borderTile)
    local hasLeftExit, hasRightExit, hasTopExit, hasBottomExit = false, false, false, false
    for y = 0, h - 1 do
        if originalTiles[0][y] == "0" then hasLeftExit = true end
        if originalTiles[w - 1][y] == "0" then hasRightExit = true end
    end
    for x = 0, w - 1 do
        if originalTiles[x][0] == "0" then hasTopExit = true end
        if originalTiles[x][h - 1] == "0" then hasBottomExit = true end
    end
    for x = 0, w - 1 do
        if not hasTopExit or (x < math.floor(w / 2) - 1 or x > math.floor(w / 2) + 1) then
            tiles[x][0] = borderTile
        end
        if not hasBottomExit or (x < math.floor(w / 2) - 1 or x > math.floor(w / 2) + 1) then
            tiles[x][h - 1] = borderTile
        end
    end
    for y = 0, h - 1 do
        if not hasLeftExit or (y < math.floor(h / 2) - 1 or y > math.floor(h / 2) + 1) then
            tiles[0][y] = borderTile
        end
        if not hasRightExit or (y < math.floor(h / 2) - 1 or y > math.floor(h / 2) + 1) then
            tiles[w - 1][y] = borderTile
        end
    end
end

function pcg.decorationPass(tiles, w, h, rng, hazardDensity, springDensity)
    if hazardDensity == nil then hazardDensity = 0.05 end
    if springDensity == nil then springDensity = 0.02 end
    local decorations = {}

    local exposedSurfaces = {}
    for x = 1, w - 2 do
        for y = 1, h - 3 do
            if tiles[x][y] == "0" and tiles[x][y + 1] ~= "0" then
                if y > 2 and tiles[x][y - 1] == "0" and tiles[x][y - 2] == "0" then
                    table.insert(exposedSurfaces, { x = x, y = y })
                end
            end
        end
    end

    local numSpikes = math.floor(#exposedSurfaces * hazardDensity)
    -- shuffle
    for i = #exposedSurfaces, 2, -1 do
        local j = rng:next(i) + 1
        exposedSurfaces[i], exposedSurfaces[j] = exposedSurfaces[j], exposedSurfaces[i]
    end
    local lim = math.min(numSpikes, #exposedSurfaces)
    for i = 1, lim do
        local s = exposedSurfaces[i]
        if s.x > 2 and s.x < w - 3 then
            -- Place floor spikes at the standing tile, pointing up.
            table.insert(decorations, { x = s.x, y = s.y, type = "spikesUp" })
        end
    end

    for x = 2, w - 3 do
        for y = 2, h - 5 do
            if tiles[x][y] == "0" and tiles[x][y + 1] ~= "0" and
               tiles[x][y - 1] == "0" and tiles[x][y - 2] == "0" then
                local hasHeadroom = true
                for dy = 2, 5 do
                    if y - dy >= 0 and tiles[x][y - dy] ~= "0" then hasHeadroom = false break end
                end
                local hasWallNearby = (x > 2 and tiles[x - 1][y] ~= "0") or
                                      (x < w - 3 and tiles[x + 1][y] ~= "0")
                if hasHeadroom and hasWallNearby and rng:nextDouble() < springDensity then
                    -- Place the spring on the floor tile, launching upward.
                    table.insert(decorations, { x = x, y = y, type = "spring" })
                end
            end
        end
    end
    return decorations
end

function pcg.generateBackground(fgTiles, w, h, material)
    local bg = pcg.newGrid(w, h, "0")
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if fgTiles[x][y] ~= "0" then
                bg[x][y] = material
                if y + 1 < h and fgTiles[x][y + 1] == "0" then
                    bg[x][y + 1] = material
                end
            end
        end
    end
    return bg
end

function pcg.generateBackgroundEnhanced(fgTiles, w, h, material, style)
    local bg = pcg.newGrid(w, h, "0")
    local bgThickness = (style == "cave") and 3 or 2
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if fgTiles[x][y] ~= "0" then
                bg[x][y] = material
                for dy = 1, bgThickness do
                    if y + dy < h and fgTiles[x][y + dy] == "0" then
                        bg[x][y + dy] = material
                    end
                end
                if x > 0 and fgTiles[x - 1][y] == "0" then bg[x - 1][y] = material end
                if x < w - 1 and fgTiles[x + 1][y] == "0" then bg[x + 1][y] = material end
            end
        end
    end
    return bg
end

-- Border exits: contiguous air runs (>= minRun tiles) along each border side.
-- Returns a list of { side = "left"|"right"|"top"|"bottom", cells = { {x,y}, ... } }.
function pcg.findExits(tiles, w, h, minRun)
    minRun = minRun or 2
    local exits = {}
    local function scanLine(len, getCell, makeCell, side)
        local runStart = nil
        for k = 0, len do
            local isAir = k < len and getCell(k) == "0"
            if isAir then
                if not runStart then runStart = k end
            elseif runStart then
                if k - runStart >= minRun then
                    local cells = {}
                    for i = runStart, k - 1 do table.insert(cells, makeCell(i)) end
                    table.insert(exits, { side = side, cells = cells })
                end
                runStart = nil
            end
        end
    end
    scanLine(h, function(y) return tiles[0][y] end, function(y) return { x = 0, y = y } end, "left")
    scanLine(h, function(y) return tiles[w - 1][y] end, function(y) return { x = w - 1, y = y } end, "right")
    scanLine(w, function(x) return tiles[x][0] end, function(x) return { x = x, y = 0 } end, "top")
    scanLine(w, function(x) return tiles[x][h - 1] end, function(x) return { x = x, y = h - 1 } end, "bottom")
    return exits
end

-- Multi-source BFS through air from one exit's cells to another exit's cells.
-- Returns (distance, pathCells) or nil when disconnected.
local function bfsExitToExit(tiles, w, h, fromCells, toCells)
    local target = {}
    for _, c in ipairs(toCells) do target[c.y * w + c.x] = true end

    local visited, parent = {}, {}
    local q, qHead = {}, 1
    for _, c in ipairs(fromCells) do
        local k = c.y * w + c.x
        if tiles[c.x] and tiles[c.x][c.y] == "0" and not visited[k] then
            visited[k] = true
            table.insert(q, { x = c.x, y = c.y, dist = 0 })
        end
    end

    local dxs = { -1, 1, 0, 0 }
    local dys = { 0, 0, -1, 1 }
    while qHead <= #q do
        local cur = q[qHead]; qHead = qHead + 1
        local ck = cur.y * w + cur.x
        if target[ck] then
            local path = {}
            local k = ck
            while k do
                table.insert(path, { x = k % w, y = math.floor(k / w) })
                k = parent[k]
            end
            return cur.dist, path
        end
        for d = 1, 4 do
            local nx, ny = cur.x + dxs[d], cur.y + dys[d]
            if nx >= 0 and ny >= 0 and nx < w and ny < h and tiles[nx][ny] == "0" then
                local nk = ny * w + nx
                if not visited[nk] then
                    visited[nk] = true
                    parent[nk] = ck
                    table.insert(q, { x = nx, y = ny, dist = cur.dist + 1 })
                end
            end
        end
    end
    return nil
end

-- Old structural heuristic, kept as the fallback gate for rooms without two
-- border exits (e.g. refilling a closed practice room in markov_level_gen).
local function interiorLooksPlayable(tiles, w, h)
    local floorY = {}
    for x = 1, w - 2 do
        for y = h - 2, 1, -1 do
            if tiles[x][y] == "0" and tiles[x][y + 1] ~= "0" then
                table.insert(floorY, y) break
            end
        end
    end
    local minFloors = math.min(3, math.floor(w / 4))
    if #floorY < minFloors then return false end
    if #floorY >= 3 then
        local mn, mx = math.huge, -math.huge
        for _, v in ipairs(floorY) do if v < mn then mn = v end if v > mx then mx = v end end
        if mx - mn < 2 then return false end
    end
    local air = 0
    for x = 1, w - 2 do
        for y = 1, h - 2 do
            if tiles[x][y] == "0" then air = air + 1 end
        end
    end
    return air >= math.floor((w - 2) * (h - 2) * 15 / 100)
end

-- Playability gate (paper §4.1): when the room has two or more border exits,
-- every exit must be BFS-reachable from the first one — this is the actual
-- clearability criterion and it works for vertical rooms too. Connected rooms
-- only need an air-ratio sanity check (a flat room is boring but clearable);
-- rooms with fewer than two exits fall back to the structural heuristic.
function pcg.isPlayable(tiles, w, h)
    local exits = pcg.findExits(tiles, w, h)
    if #exits >= 2 then
        for i = 2, #exits do
            local dist = bfsExitToExit(tiles, w, h, exits[1].cells, exits[i].cells)
            if not dist then return false end
        end
        local air = 0
        for x = 1, w - 2 do
            for y = 1, h - 2 do
                if tiles[x][y] == "0" then air = air + 1 end
            end
        end
        return air >= math.floor((w - 2) * (h - 2) * 15 / 100)
    end
    return interiorLooksPlayable(tiles, w, h)
end

function pcg.bfsPathLength(tiles, w, h, rng)
    local startY = rng:nextRange(math.floor(h / 2), h - 3)
    local sx = -1
    for x = 1, w - 2 do
        if tiles[x][startY] == "0" then sx = x break end
    end
    if sx < 0 then return -1 end

    local visited = {}
    for x = 0, w - 1 do visited[x] = {} end
    local q = {}
    local qHead = 1
    table.insert(q, { x = sx, y = startY, dist = 0 })
    visited[sx][startY] = true

    local dxs = { -1, 1, 0, 0 }
    local dys = { 0, 0, -1, 1 }

    while qHead <= #q do
        local cur = q[qHead]; qHead = qHead + 1
        if cur.x == w - 2 then return cur.dist end
        for d = 1, 4 do
            local nx = cur.x + dxs[d]
            local ny = cur.y + dys[d]
            if nx >= 1 and ny >= 1 and nx < w - 1 and ny < h - 1 then
                if tiles[nx][ny] == "0" and not visited[nx][ny] then
                    visited[nx][ny] = true
                    table.insert(q, { x = nx, y = ny, dist = cur.dist + 1 })
                end
            end
        end
    end
    return -1
end

-- Scarcity used to use a 999 sentinel when the local NLE density was zero,
-- which made the difficulty score explode on any sparse room (the instability
-- the paper itself flags in §4.3.1). A clamp keeps D comparable across rooms.
local SCARCITY_CAP = 20

-- How far the AOI extends around each path cell (paper §4.1 uses AOI_n; n=2).
local AOI_RADIUS = 2

-- Shared scoring core (paper §4.1-§4.3, with the port fixes):
--  * paths run exit-to-exit through the real border openings, so vertical and
--    multi-exit rooms score correctly; rooms with <2 exits fall back to the
--    old horizontal sweep
--  * the AOI is the union of found paths dilated by AOI_RADIUS — the area the
--    player actually visits — instead of a fixed centre box
--  * Shannon entropy is normalised to [0,1] by log(#tile types), so the
--    diversity term can no longer reward pure noise
local function scoreCore(tiles, w, h, dominant, numPaths, rng)
    local exits = pcg.findExits(tiles, w, h)
    local pathLens = {}
    local pathCells = {}
    local sampledPairs, connectedPairs = 0, 0

    if #exits >= 2 then
        local exitPairs = {}
        for i = 1, #exits do
            for j = i + 1, #exits do table.insert(exitPairs, { i, j }) end
        end
        for i = #exitPairs, 2, -1 do
            local j = rng:next(i) + 1
            exitPairs[i], exitPairs[j] = exitPairs[j], exitPairs[i]
        end
        sampledPairs = math.min(#exitPairs, math.max(1, numPaths))
        for k = 1, sampledPairs do
            local pr = exitPairs[k]
            local dist, path = bfsExitToExit(tiles, w, h, exits[pr[1]].cells, exits[pr[2]].cells)
            if dist then
                connectedPairs = connectedPairs + 1
                table.insert(pathLens, dist)
                for _, c in ipairs(path) do pathCells[c.y * w + c.x] = true end
            end
        end
    else
        for p = 1, numPaths do
            local len = pcg.bfsPathLength(tiles, w, h, rng)
            if len >= 0 then table.insert(pathLens, len) end
        end
    end

    -- AOI mask: dilated paths when available, centre-third box as fallback.
    local aoi = {}
    local aoiArea = 0
    if next(pathCells) ~= nil then
        for k in pairs(pathCells) do
            local cx, cy = k % w, math.floor(k / w)
            for dx = -AOI_RADIUS, AOI_RADIUS do
                for dy = -AOI_RADIUS, AOI_RADIUS do
                    local nx, ny = cx + dx, cy + dy
                    if nx >= 1 and ny >= 1 and nx < w - 1 and ny < h - 1 then
                        local nk = ny * w + nx
                        if not aoi[nk] then aoi[nk] = true aoiArea = aoiArea + 1 end
                    end
                end
            end
        end
    else
        local ax0, ax1 = math.floor(w / 3), math.floor(w * 2 / 3)
        local ay0, ay1 = math.floor(h / 3), math.floor(h * 2 / 3)
        for x = ax0, ax1 - 1 do
            for y = ay0, ay1 - 1 do
                aoi[y * w + x] = true
                aoiArea = aoiArea + 1
            end
        end
    end
    aoiArea = math.max(1, aoiArea)

    local area = (w - 2) * (h - 2)
    local nleTotal, nleInAoi, leInAoi, holeCols = 0, 0, 0, 0
    local tileFreq = {}

    for x = 1, w - 2 do
        if tiles[x][h - 2] == "0" then holeCols = holeCols + 1 end
        for y = 1, h - 2 do
            local t = tiles[x][y]
            if t ~= "0" then
                tileFreq[t] = (tileFreq[t] or 0) + 1
                local inAoi = aoi[y * w + x]
                local isNle = (t ~= dominant)
                local isLe = (t == dominant) and (tiles[x][y - 1] == "0")
                if isNle then
                    nleTotal = nleTotal + 1
                    if inAoi then nleInAoi = nleInAoi + 1 end
                end
                if isLe and inAoi then leInAoi = leInAoi + 1 end
            end
        end
    end

    local pathMean, pathVar = 0, 0
    if #pathLens > 0 then
        local sum = 0
        for _, l in ipairs(pathLens) do sum = sum + l end
        pathMean = sum / #pathLens
        if #pathLens > 1 then
            local vs = 0
            for _, l in ipairs(pathLens) do vs = vs + (l - pathMean) * (l - pathMean) end
            pathVar = vs / #pathLens
        end
    end

    local totalTiles, tileTypes = 0, 0
    for _, c in pairs(tileFreq) do totalTiles = totalTiles + c tileTypes = tileTypes + 1 end
    local entropy = 0
    if totalTiles > 0 and tileTypes > 1 then
        for _, cnt in pairs(tileFreq) do
            local pi = cnt / totalTiles
            if pi > 0 then entropy = entropy - pi * math.log(pi) end
        end
        entropy = entropy / math.log(tileTypes)
    end

    local dGlobal = nleTotal / area
    local dLocal = nleInAoi / aoiArea
    local scarcity = dLocal > 0 and math.min(1 / dLocal, SCARCITY_CAP) or SCARCITY_CAP

    return {
        exits = exits,
        sampledPairs = sampledPairs,
        connectedPairs = connectedPairs,
        pathLengths = pathLens,
        pathMean = pathMean,
        pathVariance = pathVar,
        globalNleDensity = dGlobal,
        localNleDensity = dLocal,
        shannonDiversity = entropy,
        -- Hf = holes / path length (§4.3); without a sampled path, normalise
        -- by interior width so the term stays a bounded ratio.
        holeFrequency = holeCols / (pathMean > 0 and pathMean or math.max(w - 2, 1)),
        localLeDensity = leInAoi / aoiArea,
        scarcity = scarcity,
    }
end

-- Computes full RoomMetrics (paper §4.1/4.2/4.3).
function pcg.computeMetrics(tiles, w, h, numPaths, rng, w1, w2, w3, z1, z2, z3, dominantSolid)
    local m = scoreCore(tiles, w, h, dominantSolid, numPaths, rng)
    m.interestingness = w1 * m.globalNleDensity + w2 * m.localNleDensity + w3 * m.shannonDiversity
    m.difficulty = z1 * m.holeFrequency + z2 * m.localLeDensity + z3 * m.scarcity
    return m
end

function pcg.passesVarianceCheck(pathLengths, pathVariance)
    if #pathLengths < 2 then return true end
    local sorted = {}
    for _, v in ipairs(pathLengths) do table.insert(sorted, v) end
    table.sort(sorted)
    local n = #sorted
    local median = (n % 2 == 1) and sorted[(n + 1) / 2] or (sorted[n / 2] + sorted[n / 2 + 1]) / 2
    return pathVariance <= 2 * median
end

-- Compact score (I, D, pathMean, pathVar, pathLens) used by the pipeline.
-- Thin wrapper over the shared scoring core so the pipeline and the
-- per-room generator can never drift apart again.
function pcg.score(tiles, w, h, dominant, numPaths, rng, w1, w2, w3, z1, z2, z3)
    local m = scoreCore(tiles, w, h, dominant, numPaths, rng)
    local I = w1 * m.globalNleDensity + w2 * m.localNleDensity + w3 * m.shannonDiversity
    local D = z1 * m.holeFrequency + z2 * m.localLeDensity + z3 * m.scarcity
    return I, D, m.pathMean, m.pathVariance, m.pathLengths
end

-- =========================================================================
-- Entity / room helpers
-- =========================================================================

local function isAirTile(tiles, x, y, w, h)
    return x >= 0 and y >= 0 and x < w and y < h and tiles[x][y] == "0"
end

local function cellKey(x, y) return x .. "," .. y end

local function shuffleInPlace(t, rng)
    for i = #t, 2, -1 do
        local j = rng:next(i) + 1
        t[i], t[j] = t[j], t[i]
    end
    return t
end

function pcg.clearEntities(room)
    if room.entities then
        for i = #room.entities, 1, -1 do room.entities[i] = nil end
    end
end

function pcg.clearDecals(room)
    if room.decalsFg then
        for i = #room.decalsFg, 1, -1 do room.decalsFg[i] = nil end
    end
    if room.decalsBg then
        for i = #room.decalsBg, 1, -1 do room.decalsBg[i] = nil end
    end
end

function pcg.clearTriggers(room)
    if room.triggers then
        for i = #room.triggers, 1, -1 do room.triggers[i] = nil end
    end
end

-- Entity defaults so Lönn and the game render them without missing fields.
local entityDefaults = {
    player = {},
    strawberry = { winged = false, golden = false },
    spikes = { type = "default" },
    spring = { direction = "up" },
    goldenBerry = { winged = false, golden = true },
}

function pcg.addEntity(room, name, x, y, attrs)
    local e = { _type = "entity", _name = name, x = x, y = y }
    local defaults = entityDefaults[name]
    if defaults then
        for k, v in pairs(defaults) do
            if e[k] == nil then e[k] = v end
        end
    end
    if attrs then for k, v in pairs(attrs) do e[k] = v end end
    if not room.entities then room.entities = {} end
    table.insert(room.entities, e)
    return e
end

function pcg.addDecal(room, layer, name, x, y, attrs)
    local tex = pcg.resolveDecalTexture(name)
    local d = { _type = "decal", _name = tex, texture = tex, x = x, y = y, scaleX = 1, scaleY = 1, rotation = 0, color = "ffffff" }
    if attrs then for k, v in pairs(attrs) do d[k] = v end end
    local key = (layer == "bg") and "decalsBg" or "decalsFg"
    if not room[key] then room[key] = {} end
    table.insert(room[key], d)
    return d
end

local triggerDefaults = {
    CameraTargetTrigger = { lerpStrength = 0.5, positionMode = "NoEffect", xOnly = false, targetEntities = "", deleteFlag = "" },
    SpawnPointTrigger = {},
}

function pcg.addTrigger(room, name, x, y, width, height, attrs)
    local t = { _type = "trigger", _name = name, x = x, y = y, width = width, height = height }
    local defaults = triggerDefaults[name]
    if defaults then
        for k, v in pairs(defaults) do
            if t[k] == nil then t[k] = v end
        end
    end
    if attrs then for k, v in pairs(attrs) do t[k] = v end end
    if not room.triggers then room.triggers = {} end
    table.insert(room.triggers, t)
    return t
end

local function findFloorSurfaces(tiles, w, h)
    local out = {}
    for x = 1, w - 2 do
        for y = 1, h - 2 do
            if tiles[x][y] == "0" and tiles[x][y + 1] ~= "0" then
                table.insert(out, { x = x, y = y })
            end
        end
    end
    return out
end

local function findExposedTopSurfaces(tiles, w, h)
    local out = {}
    for x = 1, w - 2 do
        for y = 1, h - 2 do
            if tiles[x][y] ~= "0" and tiles[x][y - 1] == "0" then
                table.insert(out, { x = x, y = y })
            end
        end
    end
    return out
end

-- Single-pass spatial analysis used by all smart placement routines.
function pcg.analyzeRoom(tiles, w, h, opts)
    opts = opts or {}
    local a = {
        width = w, height = h,
        floors = {}, ceilings = {}, walls = {},
        airCells = {}, solidCells = {},
        ledges = {}, highPoints = {},
        regionId = {}, regions = {},
        spawn = nil, goal = nil
    }

    for x = 0, w - 1 do a.regionId[x] = {} end

    -- Single-pass scan.
    for y = 1, h - 2 do
        for x = 1, w - 2 do
            local air = isAirTile(tiles, x, y, w, h)
            if air then
                table.insert(a.airCells, { x = x, y = y })
                if tiles[x][y + 1] ~= "0" then
                    table.insert(a.floors, { x = x, y = y })
                end
            else
                table.insert(a.solidCells, { x = x, y = y })
                if tiles[x][y - 1] == "0" then
                    table.insert(a.ceilings, { x = x, y = y })
                end
                if isAirTile(tiles, x - 1, y, w, h) then
                    table.insert(a.walls, { x = x, y = y, side = "left" })
                end
                if isAirTile(tiles, x + 1, y, w, h) then
                    table.insert(a.walls, { x = x, y = y, side = "right" })
                end
            end
        end
    end

    -- Ledges: floors with open space on one side at head height.
    for _, f in ipairs(a.floors) do
        local openLeft = isAirTile(tiles, f.x - 1, f.y, w, h) and isAirTile(tiles, f.x - 1, f.y - 1, w, h)
        local openRight = isAirTile(tiles, f.x + 1, f.y, w, h) and isAirTile(tiles, f.x + 1, f.y - 1, w, h)
        if openLeft or openRight then
            table.insert(a.ledges, f)
        end
    end

    -- Connected air regions.
    local dirs = { { dx = 1, dy = 0 }, { dx = -1, dy = 0 }, { dx = 0, dy = 1 }, { dx = 0, dy = -1 } }
    local id = 0
    for y = 1, h - 2 do
        for x = 1, w - 2 do
            if isAirTile(tiles, x, y, w, h) and not a.regionId[x][y] then
                id = id + 1
                local reg = {}
                a.regions[id] = reg
                local q = { { x = x, y = y } }
                local head = 1
                while head <= #q do
                    local c = q[head]; head = head + 1
                    if not a.regionId[c.x][c.y] then
                        a.regionId[c.x][c.y] = id
                        table.insert(reg, c)
                        for _, d in ipairs(dirs) do
                            local nx, ny = c.x + d.dx, c.y + d.dy
                            if nx >= 1 and ny >= 1 and nx < w - 1 and ny < h - 1 then
                                if isAirTile(tiles, nx, ny, w, h) and not a.regionId[nx][ny] then
                                    table.insert(q, { x = nx, y = ny })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Spawn point: reachable floor near the left side, central y.
    if #a.floors > 0 then
        local best, bestScore = nil, math.huge
        for _, f in ipairs(a.floors) do
            local score = f.x + math.abs(f.y - math.floor(h / 2)) * 3
            if score < bestScore then
                bestScore = score
                best = f
            end
        end
        a.spawn = best
    end

    -- Goal: reachable floor near the right side, prefer a different region.
    if #a.floors > 0 then
        local best, bestScore = nil, -math.huge
        local spawnRegion = a.spawn and a.regionId[a.spawn.x][a.spawn.y] or 0
        for _, f in ipairs(a.floors) do
            local region = a.regionId[f.x][f.y]
            local diffBonus = (region ~= spawnRegion) and 200 or 0
            local score = f.x * 2 + diffBonus - math.abs(f.y - math.floor(h / 2)) * 2
            if score > bestScore then
                bestScore = score
                best = f
            end
        end
        a.goal = best
    end

    -- High points: air in the upper third with solid support below.
    for _, c in ipairs(a.airCells) do
        if c.y < math.floor(h / 3) then
            local supported = false
            for dy = 1, 5 do
                if c.y + dy < h and tiles[c.x][c.y + dy] ~= "0" then
                    supported = true
                    break
                end
            end
            if supported then
                table.insert(a.highPoints, c)
            end
        end
    end

    return a
end

-- Distance transform from a set of source cells through passable tiles.
function pcg.distanceTransform(tiles, w, h, sources, passable)
    passable = passable or function(x, y) return tiles[x][y] == "0" end
    local dist = {}
    for x = 0, w - 1 do
        dist[x] = {}
        for y = 0, h - 1 do dist[x][y] = math.huge end
    end
    local q = {}
    local head = 1
    for _, s in ipairs(sources) do
        if s.x >= 0 and s.y >= 0 and s.x < w and s.y < h and passable(s.x, s.y) then
            dist[s.x][s.y] = 0
            table.insert(q, s)
        end
    end
    local dirs = { { dx = 1, dy = 0 }, { dx = -1, dy = 0 }, { dx = 0, dy = 1 }, { dx = 0, dy = -1 } }
    while head <= #q do
        local c = q[head]; head = head + 1
        for _, d in ipairs(dirs) do
            local nx, ny = c.x + d.dx, c.y + d.dy
            if nx >= 1 and ny >= 1 and nx < w - 1 and ny < h - 1 then
                if passable(nx, ny) and dist[nx][ny] > dist[c.x][c.y] + 1 then
                    dist[nx][ny] = dist[c.x][c.y] + 1
                    table.insert(q, { x = nx, y = ny })
                end
            end
        end
    end
    return dist
end

-- Place player, golden berry, strawberries, spikes and springs with spatial awareness.
-- Strawberry/spike/spring counts are density budgets (clamp(area * density, min, max))
-- rather than raw candidate-tile fractions, so counts stay sane on large/open rooms.
-- opts supports: analysis, berryCount, berryDensity, berryMin, berryMax, berrySpacing,
-- spikeCount, spikeMax, hazardDensity, springDensity, springMax.
function pcg.placeEntities(room, tiles, w, h, rng, isStart, isEnd, opts, analysis)
    opts = opts or {}
    local T = TILE
    local a = analysis or opts.analysis or pcg.analyzeRoom(tiles, w, h, opts)
    local floors = a.floors
    local regionId = a.regionId
    local spawn = a.spawn
    local spawnRegion = spawn and regionId[spawn.x][spawn.y] or 0
    local used = {}

    pcg.clearEntities(room)

    -- Player spawn. Every room gets one: dying in a room with no spawn point
    -- errors out in-game, so a spawn per room is a hard requirement, not a
    -- start-room nicety.
    if spawn then
        pcg.addEntity(room, "player", spawn.x * T, spawn.y * T)
        used[cellKey(spawn.x, spawn.y)] = true
    end

    -- Golden berry: at the smart goal location, reachable.
    if isEnd and a.goal then
        local g = a.goal
        pcg.addEntity(room, "goldenBerry", g.x * T, (g.y - 1) * T)
        used[cellKey(g.x, g.y)] = true
    end

    -- Strawberries: density budget (clamp(room_area * density, min, max)),
    -- reachable floors, spaced, roughly ordered along the path. The old
    -- "#floors / 6" formula had no upper bound, so open rooms with lots of
    -- walkable floor tiles could nominate dozens of berries; clamping keeps
    -- the count sane regardless of room shape.
    local berryDensity = opts.berryDensity or 0.002
    local berryMin = opts.berryMin or 1
    local berryMax = opts.berryMax or 3
    local berryCount = opts.berryCount or math.max(berryMin, math.min(berryMax, math.floor(w * h * berryDensity + 0.5)))
    local berrySpots = {}
    local candidates = {}
    for _, f in ipairs(floors) do
        if f.y - 1 >= 1 and regionId[f.x][f.y] == spawnRegion and not used[cellKey(f.x, f.y)] then
            table.insert(candidates, f)
        end
    end

    for _, c in ipairs(candidates) do
        local dx = c.x - (spawn and spawn.x or 2)
        local dy = c.y - (spawn and spawn.y or math.floor(h / 2))
        c.score = dx * 2 - math.abs(dy)
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)

    local minBerryDist = opts.berrySpacing or math.max(4, math.floor(w / 14))

    local function fillBerrySpots(spacing)
        for _, c in ipairs(candidates) do
            if #berrySpots >= berryCount then break end
            local k = cellKey(c.x, c.y)
            if not used[k] then
                local tooClose = false
                for _, b in ipairs(berrySpots) do
                    if math.abs(b.x - c.x) + math.abs(b.y - c.y) < spacing then
                        tooClose = true
                        break
                    end
                end
                if not tooClose then
                    table.insert(berrySpots, c)
                    used[k] = true
                end
            end
        end
    end

    fillBerrySpots(minBerryDist)
    if #berrySpots < berryCount and minBerryDist > 1 then
        -- Not enough spread-out candidates — relax spacing to top up.
        fillBerrySpots(math.max(1, math.floor(minBerryDist / 2)))
    end

    for _, b in ipairs(berrySpots) do
        pcg.addEntity(room, "strawberry", b.x * T + math.floor(T / 2), (b.y - 1) * T)
    end

    -- Spikes: reachable ceilings, spaced, avoid spawn area.
    local spikeMax = opts.spikeMax or 12
    local spikeCount = opts.spikeCount or math.min(spikeMax, math.floor(#a.ceilings / 4))
    local hazardDensity = opts.hazardDensity
    if hazardDensity and hazardDensity > 0 then
        spikeCount = math.min(spikeMax, math.floor(#a.ceilings * hazardDensity))
    end
    local spikeSpots = {}
    local dangerAroundSpawn = {}
    if spawn then
        for dx = -3, 3 do
            for dy = -3, 3 do
                dangerAroundSpawn[cellKey(spawn.x + dx, spawn.y + dy)] = true
            end
        end
    end

    local spikeCandidates = {}
    for _, c in ipairs(a.ceilings) do
        if c.x > 2 and c.x < w - 3 and c.y > 2 and c.y < h - 2 then
            if not dangerAroundSpawn[cellKey(c.x, c.y)] and regionId[c.x][c.y - 1] == spawnRegion then
                table.insert(spikeCandidates, c)
            end
        end
    end

    -- Prefer ledges and wall edges.
    for _, c in ipairs(spikeCandidates) do
        local nearWall = isAirTile(tiles, c.x - 1, c.y, w, h) and isAirTile(tiles, c.x - 1, c.y - 1, w, h)
        local nearWallR = isAirTile(tiles, c.x + 1, c.y, w, h) and isAirTile(tiles, c.x + 1, c.y - 1, w, h)
        c.score = (nearWall or nearWallR) and 2 or 1
    end
    table.sort(spikeCandidates, function(a, b) return a.score > b.score end)
    shuffleInPlace(spikeCandidates, rng)

    for _, c in ipairs(spikeCandidates) do
        if #spikeSpots >= spikeCount then break end
        local k = cellKey(c.x, c.y)
        if not used[k] then
            local tooClose = false
            for _, s in ipairs(spikeSpots) do
                if math.abs(s.x - c.x) + math.abs(s.y - c.y) < 2 then
                    tooClose = true
                    break
                end
            end
            if not tooClose then
                table.insert(spikeSpots, c)
                used[k] = true
            end
        end
    end

    for _, s in ipairs(spikeSpots) do
        -- Ceiling spikes hang from the tile above, so they point down.
        pcg.addEntity(room, "spikes", s.x * T, s.y * T, { direction = "down", type = "default" })
    end

    -- Springs: vertical shafts with headroom and nearby wall.
    local springDensity = opts.springDensity
    if springDensity and springDensity > 0 then
        local springMax = opts.springMax or 6
        local springCount = math.min(springMax, math.floor(#a.airCells * springDensity / 4))
        local springSpots = {}
        for _, c in ipairs(a.airCells) do
            if c.y >= 2 and c.y <= h - 5 and c.x >= 2 and c.x <= w - 3 then
                local hasFloor = tiles[c.x][c.y + 1] ~= "0"
                local hasHeadroom = isAirTile(tiles, c.x, c.y - 1, w, h) and isAirTile(tiles, c.x, c.y - 2, w, h) and isAirTile(tiles, c.x, c.y - 3, w, h)
                local hasWall = (tiles[c.x - 1][c.y] ~= "0") or (tiles[c.x + 1][c.y] ~= "0")
                if hasFloor and hasHeadroom and hasWall and regionId[c.x][c.y] == spawnRegion then
                    table.insert(springSpots, c)
                end
            end
        end
        shuffleInPlace(springSpots, rng)
        local placed = 0
        for _, c in ipairs(springSpots) do
            if placed >= springCount then break end
            pcg.addEntity(room, "spring", c.x * T, c.y * T)
            placed = placed + 1
        end
    end

    return #room.entities
end

-- Legacy random-shuffle placement (preserves old behavior for fallback).
function pcg.placeEntitiesLegacy(room, tiles, w, h, rng, isStart, isEnd)
    local T = TILE
    local floors = findFloorSurfaces(tiles, w, h)
    local surfaces = findExposedTopSurfaces(tiles, w, h)

    local spawn
    if #floors > 0 then spawn = floors[math.floor(#floors / 4) + 1] else spawn = { x = math.floor(w / 2), y = math.floor(h / 2) } end

    -- Every room needs a spawn point (dying in a spawn-less room errors in-game).
    pcg.addEntity(room, "player", spawn.x * T, spawn.y * T)
    if isEnd then
        pcg.addEntity(room, "goldenBerry", math.floor(w * T / 2), math.floor(h * T / 2 - T * 2))
    end

    local berryCandidates = {}
    for _, f in ipairs(floors) do
        if f.y - 1 >= 1 then table.insert(berryCandidates, f) end
    end
    for i = #berryCandidates, 2, -1 do
        local j = rng:next(i) + 1
        berryCandidates[i], berryCandidates[j] = berryCandidates[j], berryCandidates[i]
    end
    local berryCount = math.max(1, math.floor(#floors / 6))
    for i = 1, math.min(berryCount, #berryCandidates) do
        local s = berryCandidates[i]
        pcg.addEntity(room, "strawberry", s.x * T + math.floor(T / 2), (s.y - 1) * T)
    end

    for i = #surfaces, 2, -1 do
        local j = rng:next(i) + 1
        surfaces[i], surfaces[j] = surfaces[j], surfaces[i]
    end
    local spikeCount = math.floor(#surfaces / 4)
    for i = 1, math.min(spikeCount, #surfaces) do
        local k = surfaces[i]
        -- Exposed top surfaces are ceilings; spikes hang down from them.
        pcg.addEntity(room, "spikes", k.x * T, k.y * T, { direction = "down", type = "default" })
    end
end

-- Guarantee the room has at least one player spawn on safe ground.
-- Dying in a room without a spawn point errors out in-game, so this runs as a
-- final safety net after any placement path. Returns true if a spawn was added.
function pcg.ensureSpawn(room, tiles, w, h)
    for _, e in ipairs(room.entities or {}) do
        if e._name == "player" then return false end
    end
    local best, bestScore = nil, -math.huge
    if tiles then
        for x = 1, w - 2 do
            for y = 2, h - 2 do
                if tiles[x][y] == "0" and tiles[x][y + 1] ~= "0" and tiles[x][y - 1] == "0" then
                    -- Prefer low, horizontally central floor cells with head clearance.
                    local score = y - math.abs(x - math.floor(w / 2))
                    if score > bestScore then
                        bestScore = score
                        best = { x = x, y = y }
                    end
                end
            end
        end
    end
    if not best then best = { x = math.floor(w / 2), y = math.floor(h / 2) } end
    pcg.addEntity(room, "player", best.x * TILE, best.y * TILE)
    return true
end

-- Place decals with spatial awareness: background particles in air, foreground details on surfaces.
function pcg.placeDecals(room, tiles, w, h, rng, opts, analysis)
    opts = opts or {}
    local T = TILE
    local a = analysis or pcg.analyzeRoom(tiles, w, h, opts)
    local density = opts.decalDensity or 0.12
    if density <= 0 then return 0 end

    local style = opts.style or "city"
    local era = opts.era or "new"
    local defaultSets = pcg.decalSetForStyle(style, era)
    local bgDecals = opts.bgDecalSet or defaultSets.bg
    local fgDecals = opts.fgDecalSet or defaultSets.fg

    -- Background decals: scattered in reachable air.
    local bgCount = (#bgDecals > 0) and math.floor(#a.airCells * density / 8) or 0
    local placed = 0
    for i = 1, bgCount do
        if #a.airCells == 0 then break end
        local c = a.airCells[rng:next(#a.airCells) + 1]
        if c and isAirTile(tiles, c.x, c.y, w, h) then
            local name = bgDecals[rng:next(#bgDecals) + 1]
            local scale = 0.4 + rng:nextDouble() * 0.6
            local rot = rng:nextDouble() * 0.2 - 0.1
            local dx = math.max(0, math.min(room.width - 1, c.x * T + rng:next(T)))
            local dy = math.max(0, math.min(room.height - 1, c.y * T + rng:next(T)))
            pcg.addDecal(room, "bg", name, dx, dy, { scaleX = scale, scaleY = scale, rotation = rot })
            placed = placed + 1
        end
    end

    -- Foreground decals: attached to walls/ceilings.
    local fgCount = (#fgDecals > 0) and math.floor(#a.walls * density / 2) or 0
    for i = 1, fgCount do
        if #a.walls == 0 then break end
        local c = a.walls[rng:next(#a.walls) + 1]
        if c then
            local name = fgDecals[rng:next(#fgDecals) + 1]
            local ox = (c.side == "left") and -rng:nextDouble() * 4 or rng:nextDouble() * 4
            local oy = rng:nextDouble() * 4
            local scale = 0.8 + rng:nextDouble() * 0.4
            local dx = math.max(0, math.min(room.width - 1, c.x * T + ox))
            local dy = math.max(0, math.min(room.height - 1, c.y * T + oy))
            pcg.addDecal(room, "fg", name, dx, dy, { scaleX = scale, scaleY = scale })
            placed = placed + 1
        end
    end

    return placed
end

-- Place triggers with spatial awareness: camera targets for high areas, spawn points for safe floors.
function pcg.placeTriggers(room, tiles, w, h, rng, opts, analysis)
    opts = opts or {}
    local T = TILE
    local a = analysis or pcg.analyzeRoom(tiles, w, h, opts)
    local regionId = a.regionId
    local triggerMode = opts.triggerMode or "camera"
    if triggerMode == "none" then return 0 end

    local placed = 0

    -- Camera target triggers for vertical shafts / high areas.
    if triggerMode == "camera" or triggerMode == "all" then
        local camPoints = {}
        for _, c in ipairs(a.highPoints) do
            table.insert(camPoints, c)
        end
        if #a.floors > 0 then
            for _, f in ipairs(a.floors) do
                if f.y < math.floor(h / 2) then
                    table.insert(camPoints, { x = f.x, y = f.y - 3 })
                end
            end
        end
        shuffleInPlace(camPoints, rng)
        local camCount = math.min(3, math.floor(#camPoints / 6))
        for i = 1, camCount do
            local c = camPoints[i]
            if c then
                local roomW = room.width or w * T
                local roomH = room.height or h * T
                local tw = math.min(w * T / 2, 160)
                local th = math.min(h * T, 120)
                local tx = math.max(0, c.x * T - tw / 2)
                local ty = math.max(0, c.y * T - th / 2)
                -- Clamp to room bounds so the trigger always renders inside the room.
                if tx + tw > roomW then tx = math.max(0, roomW - tw) end
                if ty + th > roomH then ty = math.max(0, roomH - th) end
                pcg.addTrigger(room, "CameraTargetTrigger", tx, ty, tw, th, {
                    lerpStrength = 0.5, positionMode = "NoEffect", xOnly = false,
                    targetPosition = { x = c.x * T, y = c.y * T },
                    targetEntities = "", deleteFlag = ""
                })
                placed = placed + 1
            end
        end
    end

    -- Spawn point triggers near safe reachable floors.
    if triggerMode == "spawn" or triggerMode == "all" then
        local spawnCandidates = {}
        for _, f in ipairs(a.floors) do
            if f.x >= 3 and f.x <= w - 4 and regionId[f.x][f.y] == (a.spawn and regionId[a.spawn.x][a.spawn.y] or 0) then
                table.insert(spawnCandidates, f)
            end
        end
        if #spawnCandidates > 0 then
            local c = spawnCandidates[rng:next(#spawnCandidates) + 1]
            pcg.addTrigger(room, "SpawnPointTrigger", c.x * T, (c.y - 1) * T, T * 2, T * 2, { spawnPoint = { x = c.x * T, y = c.y * T } })
            placed = placed + 1
        end
    end

    return placed
end

-- Fast, one-pass smart placement for entities, decals and triggers.
-- Returns counts of placed items.
function pcg.placeAll(room, tiles, w, h, rng, opts)
    opts = opts or {}
    local a = pcg.analyzeRoom(tiles, w, h, opts)
    local counts = { entities = 0, decals = 0, triggers = 0 }

    if opts.placeEntities ~= false then
        pcg.placeEntities(room, tiles, w, h, rng, opts.isStart, opts.isEnd, opts, a)
        counts.entities = #room.entities
    end
    if opts.placeDecals then
        counts.decals = pcg.placeDecals(room, tiles, w, h, rng, opts, a)
    end
    if opts.placeTriggers then
        counts.triggers = pcg.placeTriggers(room, tiles, w, h, rng, opts, a)
    end

    log("Smart placement: " .. counts.entities .. " entities, " .. counts.decals .. " decals, " .. counts.triggers .. " triggers")
    return counts
end

-- Create a fresh, properly-structured room table.
function pcg.createRoom(name, x, y, wTiles, hTiles)
    local w, h = wTiles, hTiles
    local room = {
        _type = "room",
        name = name,
        x = x,
        y = y,
        width = w * TILE,
        height = h * TILE,
        musicLayer1 = true, musicLayer2 = true, musicLayer3 = true, musicLayer4 = true,
        musicProgress = "", ambienceProgress = "",
        dark = false, space = false, underwater = false, whisper = false,
        disableDownTransition = false, delayAlternativeMusicFade = false,
        music = "", musicAlternative = "", ambience = "",
        windPattern = "None", color = 0,
        cameraOffsetX = 0, cameraOffsetY = 0,
        entities = {}, triggers = {},
        decalsFg = {}, decalsBg = {},
    }
    room.tilesFg = tilesStruct.fromMatrix(matrixLib.filled("0", w, h))
    room.tilesBg = tilesStruct.fromMatrix(matrixLib.filled("0", w, h))
    room.sceneryObj = objectTilesStruct.fromMatrix(matrixLib.filled(-1, w, h))
    room.sceneryFg = objectTilesStruct.fromMatrix(matrixLib.filled(-1, w, h))
    room.sceneryBg = objectTilesStruct.fromMatrix(matrixLib.filled(-1, w, h))
    return room
end

-- Apply a 0-based grid to a room's fg (or bg) tiles struct (resizing if needed).
function pcg.applyGridToRoom(room, layer, grid, w, h)
    local key = (layer == "fg") and "tilesFg" or "tilesBg"
    local struct = tilesStruct.resize(tilesStruct.fromMatrix(pcg.gridToMatrix(grid, w, h)), w, h, "0")
    room[key] = struct
end

return pcg
