local T = require("testing")
local skel = require("library.selecte.skeleton")
local Rng = require("library.selecte.rng").Rng

local Room = skel.Room

T.test("skeleton: Room basics - corners, overlap, faces", function()
	local a = Room.new(10, 5, 0, 0)
	local b = Room.new(4, 4, 10, 1)
	T.assertEqual(table.concat(a:getCorners(), ","), "0,0,10,5")
	T.assertTrue(not a:isOverlapping(b), "flush rooms overlap")
	T.assertTrue(a:faces(b, "right"))
	T.assertTrue(b:faces(a, "left"))
	T.assertTrue(not a:faces(b, "up"))
	local c = Room.new(4, 4, 9, 1)
	T.assertTrue(a:isOverlapping(c))
	T.assertTrue(not pcall(Room.new, 0, 3))
end)

T.test("skeleton: exits are absolute and move with the origin", function()
	local r = Room.new(10, 8, 0, 0)
	T.assertTrue(r:addExit("up", 2, 5))
	T.assertTrue(not r:addExit("up", 0, 3), "out of bounds exit accepted")
	T.assertTrue(not r:addExit("left", 5, 3), "reversed span accepted")
	r:setOrigin(3, 7)
	T.assertEqual(r.exits.up[1][1], 5)
	T.assertEqual(r.exits.up[1][2], 8)
	T.assertTrue(r:addExit("left", 8, 10))
	r:setOrigin(3, 9)
	T.assertEqual(r.exits.left[1][1], 10)
end)

T.test("skeleton: local row/col flip the y axis", function()
	-- 40x23 at origin (0,0): absolute y=0 is the bottom row (23), y=22 the top (1)
	local r = Room.new(40, 23, 0, 0)
	T.assertEqual(r:localRow(0), 23)
	T.assertEqual(r:localRow(22), 1)
	T.assertEqual(r:localCol(0), 1)
	T.assertEqual(r:localCol(39), 40)
end)

T.test("skeleton: carved exits line up on both rooms", function()
	local s = skel.Skeleton.new()
	local a = Room.new(12, 9, 0, 0)
	s:addRoom(a, "room_1")
	local b = Room.new(12, 9, 0, 0)
	local rng = Rng.new("carve")
	local ok
	repeat
		b = Room.new(12, 9, 0, 0)
		ok = b:connect(a, "right", s, rng) and not s:isOverlappingWith(b)
	until ok
	T.assertEqual(#a.exits.right, 1)
	T.assertEqual(#b.exits.left, 1)
	local e = a.exits.right[1]
	T.assertEqual(e[1], b.exits.left[1][1])
	T.assertEqual(e[2], b.exits.left[1][2])
	for _, room in ipairs({ a, b }) do
		for r = 1, 9 do
			for c = 1, 12 do room.data[r][c] = "1" end
		end
	end
	a:createExitsInMatrix()
	b:createExitsInMatrix()
	for y = e[1], e[2] do
		T.assertEqual(a.data[a:localRow(y)][12], "0", "a not carved at y=" .. y)
		T.assertEqual(b.data[b:localRow(y)][1], "0", "b not carved at y=" .. y)
	end
	-- and nothing else on that border is carved
	for r = 1, 9 do
		local y = a.origin[2] + 9 - r
		local carved = y >= e[1] and y <= e[2]
		T.assertEqual(a.data[r][12] == "0", carved, "row " .. r)
	end
	T.assertTrue(a:isConnectedTo(b) and b:isConnectedTo(a))
end)

T.test("skeleton: respawn point sits inside each opening with a ledge below", function()
	local r = Room.new(12, 9, 0, 0)
	r:addExit("left", 3, 5)
	r:createExitsInMatrix()
	r:addRespawnPoints()
	local row = r:localRow(4)
	T.assertEqual(r.data[row][3], "P")
	T.assertEqual(r.data[row + 1][2] .. r.data[row + 1][3] .. r.data[row + 1][4], "DDD")
	T.assertEqual(r.data[row - 1][3], "0")
end)

T.test("skeleton: generateCeleskeleton builds a non-overlapping tree with a traversal path", function()
	for _, seed in ipairs({ "tree-1", "tree-2", "tree-3" }) do
		local rng = Rng.new(seed)
		local s = skel.generateCeleskeleton(8, 0.4, { 22, 14 }, rng)
		T.assertEqual(s:getNbRooms(), 8, seed)
		T.assertEqual(#s:globalOverlapping(), 0, seed .. ": rooms overlap")
		T.assertEqual(s:getStartingRoom(), "room_1")
		T.assertEqual(s:getEndingRoom(), "room_8")
		local graph = s:getRoomGraph()
		local edges = 0
		for _, set in pairs(graph) do
			for _ in pairs(set) do edges = edges + 1 end
		end
		T.assertEqual(edges / 2, 7, seed .. ": not a tree")
		local path = s:getTraversalPath()
		T.assertEqual(path[1], "room_1")
		T.assertEqual(path[#path], "room_8")
		for i = 1, #path - 1 do
			T.assertTrue(graph[path[i]][path[i + 1]], seed .. ": path step not connected")
		end
		-- every exit has a partner on the facing room
		for _, name in ipairs(s:listAllRooms()) do
			local room = s:getRoomByName(name)
			for side, list in pairs(room.exits) do
				for _, exit in ipairs(list) do
					local partner = false
					for _, other in ipairs(s:listAllRooms()) do
						if other ~= name then
							local o = s:getRoomByName(other)
							if room:faces(o, side) then
								for _, oe in ipairs(o.exits[skel.OPPOSITE_SIDE[side]]) do
									if oe[1] == exit[1] and oe[2] == exit[2] then partner = true end
								end
							end
						end
					end
					T.assertTrue(partner, seed .. ": " .. name .. " " .. side .. " exit has no partner")
				end
			end
		end
	end
end)

T.test("skeleton: p=0 is a chain where every room attaches to the previous one", function()
	local s = skel.generateCeleskeleton(6, 0, { 20, 12 }, Rng.new("chain"))
	local graph = s:getRoomGraph()
	for k = 1, 5 do
		T.assertTrue(graph["room_" .. k]["room_" .. (k + 1)], "room_" .. k .. " not linked to the next")
	end
	T.assertEqual(#s:getTraversalPath(), 6)
end)

T.test("skeleton: formatFilled restores borders and re-carves exits", function()
	local s = skel.generateCeleskeleton(3, 0, { 12, 9 }, Rng.new("fmt"))
	for _, name in ipairs(s:listAllRooms()) do
		local room = s:getRoomByName(name)
		for r = 1, 9 do
			for c = 1, 12 do room.data[r][c] = "0" end
		end
	end
	s:formatFilled()
	local room = s:getRoomByName("room_2")
	local carved = 0
	for c = 1, 12 do
		if room.data[1][c] == "0" then carved = carved + 1 end
		if room.data[9][c] == "0" then carved = carved + 1 end
	end
	for r = 1, 9 do
		if room.data[r][1] == "0" then carved = carved + 1 end
		if room.data[r][12] == "0" then carved = carved + 1 end
	end
	local expected = 0
	for _, list in pairs(room.exits) do
		for _, e in ipairs(list) do expected = expected + (e[2] - e[1] + 1) end
	end
	T.assertEqual(carved, expected)
	T.assertEqual(room.data[5][5], "0", "interior touched")
end)

T.test("skeleton: json round trip keeps origins, sizes and exits", function()
	local s = skel.generateCeleskeleton(4, 0.5, { 16, 10 }, Rng.new("json"))
	local back = skel.fromJsonTable(s:toJsonTable())
	T.assertEqual(back:getNbRooms(), 4)
	for _, name in ipairs(s:listAllRooms()) do
		local a, b = s:getRoomByName(name), back:getRoomByName(name)
		T.assertEqual(a.origin[1], b.origin[1])
		T.assertEqual(a.origin[2], b.origin[2])
		T.assertEqual(#a.exits.up + #a.exits.down + #a.exits.left + #a.exits.right,
			#b.exits.up + #b.exits.down + #b.exits.left + #b.exits.right)
	end
	T.assertEqual(table.concat(back:getTraversalPath(), ">"), table.concat(s:getTraversalPath(), ">"))
end)
