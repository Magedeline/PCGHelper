-- playability.lua - A* playability check and the room metrics.
--
-- Lua port of the pathfinding and evaluation half of utils/utils.py in
-- https://github.com/robilouis/seleCte (MIT): astar, get_min_dist_to_nle,
-- get_interest_space, evaluate_room_difficulty, evaluate_room_interestingness,
-- get_entropy_data, plus Room.extract_room_path / is_playable_room /
-- is_valid_special from celeskeleton.py.
--
-- What A* models is 8-connected movement through open cells with weighted
-- direction costs: no gravity, no jump or dash reach, no stamina, no
-- wall-grab. "Playable" means a path through empty space exists. This is
-- the comparison baseline seleCte keeps on purpose; its docs say so.
--
-- Two changes to the search. The Python rescans its open and closed lists
-- linearly per child (62% of its runtime in Node.__eq__, by its own
-- profile); here both are keyed by position, which is what its author says
-- removes essentially all of that cost. Costs, heuristic, shuffled expansion
-- order and the iteration cap are the same.
--
-- The second is a deliberate deviation. The Python appends a child to the
-- open list whenever its g is not WORSE than an open copy, and never checks
-- whether a popped node was already closed - so every tie (and moving down
-- costs 0, so ties are everywhere) adds a duplicate that is later popped,
-- counted against the iteration cap, and re-expanded into more duplicates.
-- The cap is the room's area, meant to let the search visit every cell
-- once; on a 40x23 room the churn fits under it, on a 200x200 room it does
-- not, and A* gives up on points a flood fill reaches in a few thousand
-- steps. Here a cell is expanded once (a stale pop is discarded and not
-- counted) and only a strictly better g re-enters the open list, so the cap
-- is a true bound on cells visited and a reachable goal is always found.

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

-- =========================================================================
-- Nearest safe ground (get_coords_around_pos / get_min_dist_to_nle)
-- =========================================================================

local SAFE = {}
for _, s in ipairs(alphabet.NON_LETHAL_ENTITIES) do
	SAFE[s] = true
end
SAFE[alphabet.SOLID] = true
M.SAFE_GROUND = SAFE

-- The ring of cells at Chebyshev distance `dist` from (r, c), clipped to the
-- room and kept to rows at or below r.
local function ringAtOrBelow(h, w, r, c, dist)
	local out = {}
	for _, side in ipairs({ -1, 1 }) do
		for k = -dist, dist do
			local rr, cc = r + side * dist, c + k
			if rr >= r and rr >= 1 and rr <= h and cc >= 1 and cc <= w then
				out[#out + 1] = { rr, cc }
			end
		end
		for k = -dist + 1, dist - 1 do
			local rr, cc = r + k, c + side * dist
			if rr >= r and rr >= 1 and rr <= h and cc >= 1 and cc <= w then
				out[#out + 1] = { rr, cc }
			end
		end
	end
	return out
end

-- Chebyshev distance from (r, c) to the nearest solid tile or non-lethal
-- entity at or below it; 0 if (r, c) is one. Returns max(h, w) where the
-- Python raised (a room with no safe ground at all).
function M.minDistToSafeGround(data, r, c)
	local h = #data
	local w = #data[1]
	if SAFE[data[r][c]] then
		return 0
	end
	local limit = math.max(h, w)
	local dist = 1
	while dist < limit do
		for _, pos in ipairs(ringAtOrBelow(h, w, r, c, dist)) do
			if SAFE[data[pos[1]][pos[2]]] then
				return dist
			end
		end
		dist = dist + 1
	end
	return limit
end

-- The same distance for every cell at once, as a flat array indexed
-- (r - 1) * w + c. A multi-source flood fill from every safe cell that only
-- steps up, left, right and up-diagonally: along such moves the step count
-- to a cell at or above the source is exactly the Chebyshev distance, so
-- each cell ends with the distance to its nearest safe cell at or below it.
-- Cells no safe cell reaches get max(h, w), as minDistToSafeGround does.
-- O(h * w), against the per-cell rings that cost A* most of its time on
-- large rooms. Only the distance to safe ground is read, so a tile's
-- passability does not matter here.
function M.safeGroundMap(data)
	local h = #data
	local w = #data[1]
	local limit = math.max(h, w)
	local dist = {}
	local queue, head, tail = {}, 1, 0
	for r = 1, h do
		local row, base = data[r], (r - 1) * w
		for c = 1, w do
			if SAFE[row[c]] then
				dist[base + c] = 0
				tail = tail + 1
				queue[tail] = base + c
			else
				dist[base + c] = limit
			end
		end
	end
	while head <= tail do
		local idx = queue[head]
		head = head + 1
		local d = dist[idx] + 1
		local r = math.floor((idx - 1) / w) + 1
		local c = idx - (r - 1) * w
		-- (r, c-1), (r, c+1), (r-1, c-1), (r-1, c), (r-1, c+1)
		if c > 1 and dist[idx - 1] > d then
			dist[idx - 1] = d
			tail = tail + 1
			queue[tail] = idx - 1
		end
		if c < w and dist[idx + 1] > d then
			dist[idx + 1] = d
			tail = tail + 1
			queue[tail] = idx + 1
		end
		if r > 1 then
			local up = idx - w
			for dc = -1, 1 do
				local cc = c + dc
				if cc >= 1 and cc <= w and dist[up + dc] > d then
					dist[up + dc] = d
					tail = tail + 1
					queue[tail] = up + dc
				end
			end
		end
	end
	return dist
end

-- =========================================================================
-- Binary min-heap on f
-- =========================================================================

local function heapPush(heap, node)
	heap[#heap + 1] = node
	local i = #heap
	while i > 1 do
		local p = math.floor(i / 2)
		if heap[p].f <= heap[i].f then
			break
		end
		heap[p], heap[i] = heap[i], heap[p]
		i = p
	end
end

local function heapPop(heap)
	local top = heap[1]
	local last = heap[#heap]
	heap[#heap] = nil
	if #heap > 0 then
		heap[1] = last
		local i, n = 1, #heap
		while true do
			local l, r = 2 * i, 2 * i + 1
			local s = i
			if l <= n and heap[l].f < heap[s].f then
				s = l
			end
			if r <= n and heap[r].f < heap[s].f then
				s = r
			end
			if s == i then
				break
			end
			heap[s], heap[i] = heap[i], heap[s]
			i = s
		end
	end
	return top
end

-- =========================================================================
-- astar
-- =========================================================================

local DIAGONAL_MOVES = {
	{ 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 },
	{ -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 },
}
local DIAGONAL_COSTS = { 0.1, 0.1, 0.05, 0, 0.5, 0.5, 0.01, 0.01 }
local STRAIGHT_MOVES = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }
local STRAIGHT_COSTS = { 1.0, 1.0, 1.0, 1.0 }

-- Returns the {r, c} path from `start` to `goal` through `maze` (0 = open),
-- or an empty list when none was found before `maxIterations` expansions
-- (default: the cell count). `data` is the room's tile grid, used to score
-- how close a step stays to safe ground - `safeMap` is its safeGroundMap,
-- computed here when the caller has not already (callers that run several
-- searches on one room pass it in). `rng` shuffles the expansion order
-- each iteration, as the original does to avoid a decision bias.
function M.astar(data, maze, start, goal, rng, maxIterations, allowDiagonal, safeMap)
	if allowDiagonal == nil then
		allowDiagonal = true
	end
	local h = #maze
	local w = #maze[1]
	local area = w * h
	local maxIter = (maxIterations and maxIterations > 0) and maxIterations or area

	local moves = allowDiagonal and DIAGONAL_MOVES or STRAIGHT_MOVES
	local costs = allowDiagonal and DIAGONAL_COSTS or STRAIGHT_COSTS
	local order = {}
	for i = 1, #moves do
		order[i] = i
	end

	safeMap = safeMap or M.safeGroundMap(data)
	local function safeDist(r, c)
		return safeMap[(r - 1) * w + c]
	end

	local function key(r, c)
		return r * (w + 2) + c
	end

	local startNode = { r = start[1], c = start[2], g = 0, h = 0, f = 0, parent = nil }
	local open = { startNode }
	local openBest = { [key(start[1], start[2])] = 0 }
	local closed = {}
	local goalR, goalC = goal[1], goal[2]

	local iterations = 0
	while #open > 0 do
		local current = heapPop(open)
		local ck = key(current.r, current.c)
		if not closed[ck] then
			-- an entry superseded by a better g for the same cell is dropped
			-- here without counting as an iteration
			iterations = iterations + 1
			if iterations > maxIter then
				return {}, iterations
			end
			rng:shuffle(order)
			closed[ck] = true

			if current.r == goalR and current.c == goalC then
				local path = {}
				local node = current
				while node do
					table.insert(path, 1, { node.r, node.c })
					node = node.parent
				end
				return path, iterations
			end

			for _, pick in ipairs(order) do
				local move = moves[pick]
				local nr, nc = current.r + move[1], current.c + move[2]
				if nr >= 1 and nr <= h and nc >= 1 and nc <= w and maze[nr][nc] == 0 then
					local k = key(nr, nc)
					if not closed[k] then
						local g = current.g + (costs[pick] + safeDist(nr, nc) / 10) * area
						local best = openBest[k]
						if not best or g < best then
							openBest[k] = g
							local dr, dc = nr - goalR, nc - goalC
							local hh = dr * dr + dc * dc
							heapPush(open, { r = nr, c = nc, g = g, h = hh, f = g + hh, parent = current })
						end
					end
				end
			end
		end
	end
	return {}, iterations
end

-- =========================================================================
-- Room-level checks (celeskeleton.Room)
-- =========================================================================

-- extract_room_path: a path between consecutive exits, or {} when any pair
-- is unreachable. With more than two exits only the last pair's path is
-- returned (the original's known limitation).
function M.extractRoomPath(room, maxIterations, rng)
	local maze = room:extractAstarReadyData()
	local points = room:getStartingEndingPoints()
	if #points < 2 then
		return {}
	end
	local safeMap = M.safeGroundMap(room.data)
	local path = {}
	for k = 1, #points - 1 do
		path = M.astar(room.data, maze, points[k], points[k + 1], rng, maxIterations, nil, safeMap)
		if #path == 0 then
			return {}
		end
	end
	return path
end

function M.isPlayableRoom(room, maxIterations, rng, log)
	local path = M.extractRoomPath(room, maxIterations, rng)
	if #path == 0 then
		if log then
			log("A* room playability failed in current room.")
		end
		return false, path
	end
	return true, path
end

-- is_valid_special: whether `point` reaches every exit.
function M.isValidSpecial(room, point, maxIterations, rng)
	local maze = room:extractAstarReadyData()
	local safeMap = M.safeGroundMap(room.data)
	for _, exitPoint in ipairs(room:getStartingEndingPoints()) do
		local path = M.astar(room.data, maze, point, exitPoint, rng, maxIterations, nil, safeMap)
		if #path == 0 then
			return false
		end
	end
	return true
end

-- =========================================================================
-- Metrics
-- =========================================================================

-- get_interest_space: the cells within `sensibility` of any path position,
-- in bounds, duplicates kept (counts stay proportional to path coverage).
function M.getInterestSpace(data, path, sensibility)
	local h = #data
	local w = #data[1]
	local out = {}
	for _, pos in ipairs(path) do
		for i = -sensibility, sensibility do
			for j = -sensibility, sensibility do
				local r, c = pos[1] + i, pos[2] + j
				if r >= 1 and r <= h and c >= 1 and c <= w then
					out[#out + 1] = { r, c }
				end
			end
		end
	end
	return out
end

local function positionsWith(data, predicate)
	local out = {}
	for r = 1, #data do
		for c = 1, #data[r] do
			if predicate(data[r][c]) then
				out[#out + 1] = { r, c }
			end
		end
	end
	return out
end

local function toKeySet(positions, w)
	local set = {}
	for _, p in ipairs(positions) do
		set[p[1] * (w + 2) + p[2]] = true
	end
	return set
end

-- danger_presence: whether falling from (r, c) lands on a hazard. A column
-- of pure void counts as dangerous.
function M.dangerPresence(data, r, c)
	for rr = r, #data do
		local s = data[rr][c]
		if s ~= alphabet.VOID then
			return s == "^" or s == "S"
		end
	end
	return true
end

-- evaluate_room_difficulty -> holes, local density of lethal+void, scarcity.
function M.evaluateDifficulty(data, path, sensibility)
	sensibility = sensibility or 2
	local w = #data[1]
	local dangerous = 0
	for _, pos in ipairs(path) do
		if M.dangerPresence(data, pos[1], pos[2]) then
			dangerous = dangerous + 1
		end
	end
	local holes = #path > 0 and dangerous / #path or 0

	local zoi = M.getInterestSpace(data, path, sensibility)
	local zoiSet = toKeySet(zoi, w)
	local nonLethalOrVoid = positionsWith(data, function(s)
		return SAFE[s] or s == alphabet.VOID
	end)
	local nonLethal = positionsWith(data, function(s)
		return SAFE[s]
	end)
	local inZoi = 0
	for _, p in ipairs(nonLethalOrVoid) do
		if zoiSet[p[1] * (w + 2) + p[2]] then
			inZoi = inZoi + 1
		end
	end
	local nleInZoi = 0
	for _, p in ipairs(nonLethal) do
		if zoiSet[p[1] * (w + 2) + p[2]] then
			nleInZoi = nleInZoi + 1
		end
	end
	local localDensity = #zoi > 0 and (#zoi - inZoi) / #zoi or 0
	local scarcity = nleInZoi > 0 and #zoi / nleInZoi or math.huge
	return holes, localDensity, scarcity
end

-- get_entropy_data: Shannon entropy of the tile distribution, base 10.
function M.entropy(data)
	local counts, total = {}, 0
	for r = 1, #data do
		for c = 1, #data[r] do
			local s = data[r][c]
			counts[s] = (counts[s] or 0) + 1
			total = total + 1
		end
	end
	local e = 0
	for _, n in pairs(counts) do
		local p = n / total
		e = e - p * math.log10(p)
	end
	return e
end

-- evaluate_room_interestingness -> room-wide density of safe ground, the
-- same density in the zone of interest, and the tile entropy.
function M.evaluateInterestingness(data, path, sensibility)
	sensibility = sensibility or 2
	local w = #data[1]
	local zoi = M.getInterestSpace(data, path, sensibility)
	local zoiSet = toKeySet(zoi, w)
	local nonLethal = positionsWith(data, function(s)
		return SAFE[s]
	end)
	local inZoi = 0
	for _, p in ipairs(nonLethal) do
		if zoiSet[p[1] * (w + 2) + p[2]] then
			inZoi = inZoi + 1
		end
	end
	local density = #nonLethal / (#data * w)
	local score = #zoi > 0 and inZoi / #zoi or 0
	return density, score, M.entropy(data)
end

return M
