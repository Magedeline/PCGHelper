local T = require("testing")
local skel = require("library.selecte.skeleton")
local play = require("library.selecte.playability")
local mdmc = require("library.selecte.mdmc")
local Rng = require("library.selecte.rng").Rng
local dpeData = require("library.selecte.dpe_data")

local function roomFromRows(rows, originX, originY)
	local data = mdmc.rowsToRoom(rows)
	local r = skel.Room.new(#rows[1], #rows, originX or 0, originY or 0)
	r:setData(data)
	return r
end

T.test("playability: astar crosses an open room and fails on a wall", function()
	local rng = Rng.new("astar")
	local open = roomFromRows({
		"111111111111",
		"100000000001",
		"000000000000",
		"100000000001",
		"111111111111",
	})
	local maze = open:extractAstarReadyData()
	local path = play.astar(open.data, maze, { 3, 1 }, { 3, 12 }, rng)
	T.assertTrue(#path >= 12, "no path across an open room")
	T.assertEqual(path[1][1] .. "," .. path[1][2], "3,1")
	T.assertEqual(path[#path][1] .. "," .. path[#path][2], "3,12")

	local walled = roomFromRows({
		"111111111111",
		"100000100001",
		"000000100000",
		"100000100001",
		"111111111111",
	})
	T.assertEqual(#play.astar(walled.data, walled:extractAstarReadyData(), { 3, 1 }, { 3, 12 }, rng), 0)
end)

T.test("playability: dream blocks, water and the spawn are passable, spikes are not", function()
	local r = roomFromRows({
		"11111",
		"1DWP1",
		"1^S_1",
		"11111",
	})
	local m = r:extractAstarReadyData()
	T.assertEqual(table.concat(m[1], ""), "11111")
	T.assertEqual(table.concat(m[2], ""), "10001")
	T.assertEqual(table.concat(m[3], ""), "11111")
end)

T.test("playability: isPlayableRoom goes exit to exit through the skeleton's exits", function()
	local rng = Rng.new("exits")
	local r = roomFromRows({
		"111111111111",
		"100000000001",
		"100000000001",
		"100000000001",
		"111111111111",
	})
	r:addExit("left", 1, 2)
	r:addExit("right", 1, 2)
	r:createExitsInMatrix()
	local ok, path = play.isPlayableRoom(r, 0, rng)
	T.assertTrue(ok, "open room judged unplayable")
	T.assertTrue(#path > 0)
	-- seal the middle
	for row = 1, 5 do r.data[row][6] = "1" end
	T.assertTrue(not play.isPlayableRoom(r, 0, rng))
	-- a single-exit room has nothing to connect, so no path
	local single = roomFromRows({ "11111", "10001", "10001", "11111" })
	single:addExit("left", 1, 2)
	T.assertEqual(#play.extractRoomPath(single, 0, rng), 0)
end)

T.test("playability: isValidSpecial needs every exit reachable", function()
	local rng = Rng.new("special")
	local r = roomFromRows({
		"111111111111",
		"100000000001",
		"100000000001",
		"100000000001",
		"111111111111",
	})
	r:addExit("left", 1, 2)
	r:addExit("right", 1, 2)
	r:createExitsInMatrix()
	T.assertTrue(play.isValidSpecial(r, { 3, 6 }, 0, rng))
	for row = 1, 5 do r.data[row][9] = "1" end
	T.assertTrue(not play.isValidSpecial(r, { 3, 6 }, 0, rng))
end)

T.test("playability: nearest safe ground looks at or below the cell", function()
	local r = roomFromRows({
		"11111",
		"00000",
		"00000",
		"00100",
		"11111",
	})
	T.assertEqual(play.minDistToSafeGround(r.data, 4, 3), 0)
	T.assertEqual(play.minDistToSafeGround(r.data, 3, 3), 1)
	T.assertEqual(play.minDistToSafeGround(r.data, 2, 3), 2)
	-- (4,3) is at Chebyshev distance 2 from (2,1); the row above is never searched
	T.assertEqual(play.minDistToSafeGround(r.data, 2, 1), 2)
	T.assertEqual(play.minDistToSafeGround(r.data, 3, 5), 2, "the border row below counts as ground")
end)

T.test("playability: metrics are finite and bounded", function()
	local rng = Rng.new("metrics")
	local r = roomFromRows({
		"1111111111",
		"1000000001",
		"0000S00000",
		"1^^^000__1",
		"1111111111",
	})
	r:addExit("left", 1, 2)
	r:addExit("right", 1, 2)
	r:createExitsInMatrix()
	local ok, path = play.isPlayableRoom(r, 0, rng)
	T.assertTrue(ok)
	local holes, density, scarcity = play.evaluateDifficulty(r.data, path, 2)
	T.assertTrue(holes >= 0 and holes <= 1, "holes " .. holes)
	T.assertTrue(density >= 0 and density <= 1, "density " .. density)
	T.assertTrue(scarcity >= 1, "scarcity " .. scarcity)
	local d, s, e = play.evaluateInterestingness(r.data, path, 2)
	T.assertTrue(d > 0 and d < 1)
	T.assertTrue(s >= 0 and s <= 1)
	T.assertTrue(e > 0)
	T.assertTrue(play.dangerPresence(r.data, 2, 2), "spikes below not seen")
	T.assertTrue(not play.dangerPresence(r.data, 2, 8), "jumpThru below counted as danger")
end)

T.test("playability: safeGroundMap matches minDistToSafeGround on a sampled room", function()
	local rng = Rng.new("safemap")
	local data = mdmc.generateRoomData(dpeData.pe_d5_full, 60, 40, rng)
	local map = play.safeGroundMap(data)
	for r = 1, 40 do
		for c = 1, 60 do
			T.assertEqual(map[(r - 1) * 60 + c], play.minDistToSafeGround(data, r, c), "cell " .. r .. "," .. c)
		end
	end
	-- a room with no safe ground at all: every cell gets max(h, w)
	local bare = mdmc.rowsToRoom({ "000", "000", "000", "000" })
	for i = 1, 12 do
		T.assertEqual(play.safeGroundMap(bare)[i], 4)
	end
end)

T.test("playability: astar finds a reachable goal in a large room within the area cap", function()
	-- the cap is the cell count; with every cell expanded at most once a
	-- reachable goal is always found (upstream's duplicate churn exhausted
	-- the cap on rooms this size and reported them unplayable)
	local rng = Rng.new("big")
	local w, h = 200, 200
	local data = mdmc.generateRoomData(dpeData.pe_d5_full, w, h, rng)
	local room = skel.Room.new(w, h, 0, 0)
	room:setData(data)
	local maze = room:extractAstarReadyData()
	-- flood fill from the centre; every open cell it reaches must be found by A*
	local sr, sc = 100, 100
	maze[sr][sc] = 0
	local reach, stack = {}, { { sr, sc } }
	reach[sr * (w + 2) + sc] = true
	while #stack > 0 do
		local p = table.remove(stack)
		for dr = -1, 1 do
			for dc = -1, 1 do
				local nr, nc = p[1] + dr, p[2] + dc
				if nr >= 1 and nr <= h and nc >= 1 and nc <= w and maze[nr][nc] == 0 and not reach[nr * (w + 2) + nc] then
					reach[nr * (w + 2) + nc] = true
					stack[#stack + 1] = { nr, nc }
				end
			end
		end
	end
	local safeMap = play.safeGroundMap(data)
	local checked, found = 0, 0
	for _, goal in ipairs({ { 2, 2 }, { 2, 199 }, { 199, 2 }, { 199, 199 }, { 50, 150 }, { 150, 50 } }) do
		if reach[goal[1] * (w + 2) + goal[2]] then
			checked = checked + 1
			local path, iters = play.astar(data, maze, { sr, sc }, goal, rng, 0, nil, safeMap)
			T.assertTrue(#path > 0, string.format("no path to reachable (%d,%d) after %d iterations", goal[1], goal[2], iters))
			T.assertTrue(iters <= w * h, "iteration count above the area cap")
			found = found + 1
		end
	end
	T.assertTrue(checked >= 3, "sampled room too fragmented for the test (" .. checked .. " corners reachable)")
	T.assertEqual(found, checked)
end)
