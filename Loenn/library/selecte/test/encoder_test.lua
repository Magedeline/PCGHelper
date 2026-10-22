local T = require("testing")
local skel = require("library.selecte.skeleton")
local encoder = require("library.selecte.encoder")
local recombine = require("library.selecte.recombine")
local mdmc = require("library.selecte.mdmc")
local packer = require("pcg_engine.celeste-pcg.lua.binary_packer")

-- seleCte's hand-written 40x23 round-trip fixture (space-separated, as
-- np.savetxt writes it) -> a data grid.
local function loadFixture()
	local f = assert(io.open(T.here .. "fixtures/round_trip_room.csv", "r"))
	local rows = {}
	for line in f:lines() do
		if line:match("%S") then
			rows[#rows + 1] = line:gsub("%s+", "")
		end
	end
	f:close()
	return mdmc.rowsToRoom(rows)
end

local function fixtureRoom()
	local data = loadFixture()
	local room = skel.Room.new(40, 23, 0, 0)
	room:setData(data)
	return room
end

local EXPECTED = {
	{ "refill", 164, 28 },
	{ "blackGem", 256, 32 },
	{ "refill", 148, 52 },
	{ "refill", 116, 76 },
	{ "booster", 212, 84 },
	{ "refill", 204, 116 },
	{ "infiniteStar", 116, 140 },
	{ "refill", 196, 140 },
	{ "player", 48, 152 },
	{ "jumpThru", 32, 160, 24 },
	{ "spikesUp", 112, 176, 192 },
}

T.test("encoder: the fixture encodes to the eleven-entity table in ALPHABET.md", function()
	local encoded = encoder.encodeRoom(fixtureRoom(), "room_1")
	T.assertEqual(#encoded.entities, 11)
	for i, exp in ipairs(EXPECTED) do
		local e = encoded.entities[i]
		T.assertEqual(e.name, exp[1], "entity " .. i)
		T.assertEqual(e.x, exp[2], exp[1] .. " x")
		T.assertEqual(e.y, exp[3], exp[1] .. " y")
		T.assertEqual(e.width, exp[4], exp[1] .. " width")
		T.assertEqual(e.height, nil, exp[1] .. " height")
	end
	T.assertEqual(encoded.entities[5].attrs.red, true, "Q is the red booster")
	T.assertEqual(encoded.width, 320)
	T.assertEqual(encoded.height, 184)
	T.assertEqual(#encoded.fgRows, 23)
	T.assertEqual(#encoded.fgRows[1], 40)
	-- FgTiles: the entity glyphs are blanked, the walls survive
	T.assertEqual(encoded.fgRows[1], string.rep("1", 40))
	T.assertEqual(encoded.fgRows[22], "1" .. string.rep("0", 38) .. "1")
	T.assertEqual(encoded.fgRows[19]:sub(6, 6), "0", "player glyph left in the tiles")
end)

T.test("encoder: a solid tileset override only touches the walls", function()
	local encoded = encoder.encodeRoom(fixtureRoom(), "room_1", { solid = "3" })
	T.assertEqual(encoded.fgRows[1], string.rep("3", 40))
	T.assertEqual(encoded.fgRows[2], "3" .. string.rep("0", 38) .. "3")
end)

T.test("encoder: size search runs right and down, and rectangles stay one entity", function()
	local data = mdmc.rowsToRoom({
		"000000",
		"0DD000",
		"0DD0<0",
		"0000<0",
		"0WW000",
		"0W0000",
	})
	local ents = encoder.entityMap(data)
	T.assertEqual(#ents, 4)
	T.assertEqual(ents[1].name, "dreamBlock")
	T.assertEqual(ents[1].x .. "," .. ents[1].y .. "," .. ents[1].width .. "," .. ents[1].height, "8,8,16,16")
	T.assertEqual(ents[2].name, "spikesLeft")
	T.assertEqual(ents[2].x .. "," .. ents[2].y .. "," .. tostring(ents[2].width) .. "," .. ents[2].height, "40,16,nil,16")
	-- the water is an L shape: a 2x1 strip then the leftover cell below
	T.assertEqual(ents[3].name, "water")
	T.assertEqual(ents[3].width .. "x" .. ents[3].height, "16x8")
	T.assertEqual(ents[4].name, "water")
	T.assertEqual(ents[4].x .. "," .. ents[4].y, "8,40")
end)

T.test("encoder: rooms of different heights stay adjacent after the y flip", function()
	-- The Julia smoke test's regression guard: 40x23 below, 40x46 directly
	-- above it (origin is bottom-left, y grows upwards).
	local a = skel.Room.new(40, 23, 0, 0)
	local b = skel.Room.new(40, 46, 0, 23)
	local ea = encoder.encodeRoom(a, "room_1")
	local eb = encoder.encodeRoom(b, "room_2")
	T.assertEqual(ea.y, -184)
	T.assertEqual(ea.y + ea.height, 0)
	T.assertEqual(eb.y, -552)
	T.assertEqual(eb.y + eb.height, -184)
end)

T.test("encoder: the .bin carries the chapter meta that makes the heart end the level", function()
	local encodedRooms = { encoder.encodeRoom(fixtureRoom(), "room_1") }
	local tree = encoder.buildMapTree(encodedRooms, { music = "music_city" })
	local bytes = packer.encodeMap(tree, "round_trip_room")
	T.assertTrue(#bytes > 200, "suspiciously small .bin")
	local decoded = packer.decodeMap(bytes)
	T.assertEqual(decoded.package, "round_trip_room")
	local meta, levels
	for _, child in ipairs(decoded.root.children) do
		if child.name == "meta" then meta = child end
		if child.name == "levels" then levels = child end
	end
	T.assertTrue(meta ~= nil, "no meta element")
	T.assertEqual(meta.children[1].name, "mode")
	T.assertEqual(meta.children[1].attrs.HeartIsEnd, true)
	T.assertEqual(meta.children[1].children[1].name, "audiostate")
	T.assertEqual(meta.attrs.IntroType, "WakeUp")
	T.assertEqual(#levels.children, 1)
	local level = levels.children[1]
	T.assertEqual(level.attrs.name, "room_1")
	T.assertEqual(level.attrs.music, "music_city")
	T.assertEqual(level.attrs.width, 320)

	-- data_loader.jl's side: the rooms read back with 23 rows of 40 glyphs
	-- and every entity carries a name and x/y.
	local rooms = recombine.roomsFromMapTree(decoded.root)
	T.assertEqual(#rooms, 1)
	T.assertEqual(#rooms[1].fgRows, 23)
	T.assertEqual(#rooms[1].fgRows[1], 40)
	T.assertEqual(#rooms[1].entities, 11)
	local heart
	for _, e in ipairs(rooms[1].entities) do
		T.assertTrue(e.name and e.x and e.y, "entity missing name/x/y")
		if e.name == "blackGem" then heart = e end
	end
	T.assertTrue(heart ~= nil, "blackGem dropped")
	T.assertEqual(heart.x .. "," .. heart.y, "256,32")
end)

T.test("encoder: everest.yaml names the map", function()
	local yaml = encoder.everestYaml("MyChapter")
	T.assertTrue(yaml:find("- Name: MyChapter\n", 1, true) ~= nil)
	T.assertTrue(yaml:find("Name: Everest", 1, true) ~= nil)
end)
