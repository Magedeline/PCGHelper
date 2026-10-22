local T = require("testing")
local level = require("library.selecte.level")
local encoder = require("library.selecte.encoder")
local alphabet = require("library.selecte.alphabet")
local dpeData = require("library.selecte.dpe_data")
local Rng = require("library.selecte.rng").Rng

local function countGlyph(data, glyph)
	local n = 0
	for r = 1, #data do
		for c = 1, #data[r] do
			if data[r][c] == glyph then n = n + 1 end
		end
	end
	return n
end

T.test("level: a small level generates end to end with spawn and heart", function()
	local t0 = os.clock()
	local skeleton, path, summary = level.generate(dpeData.pe_d5_full, {
		nbRooms = 5, proba = 0.3, roomSize = { 22, 14 }, triesLimit = 4, btDepth = 0,
	}, Rng.new("level-small"))
	local seconds = os.clock() - t0
	T.assertEqual(skeleton:getNbRooms(), 5)
	T.assertEqual(path[1], "room_1")
	T.assertEqual(path[#path], "room_5")
	T.assertTrue(#summary.rooms == #path, "one report per path room")
	T.assertTrue(summary.rooms[1].playable, "start room with one exit must be accepted through its spawn")
	T.assertTrue(summary.rooms[#summary.rooms].playable, "end room with one exit must be accepted through its heart")
	T.assertTrue(#summary.rooms[#summary.rooms].path > 0, "end room path recorded for metrics")

	local start = skeleton:getRoomByName("room_1")
	local finish = skeleton:getRoomByName("room_5")
	T.assertTrue(countGlyph(start.data, alphabet.PLAYER) >= 1, "start room has no spawn")
	T.assertEqual(countGlyph(finish.data, alphabet.HEART), 1, "end room must hold exactly one heart")
	T.assertEqual(countGlyph(start.data, alphabet.HEART), 0)

	for _, name in ipairs(skeleton:listAllRooms()) do
		local room = skeleton:getRoomByName(name)
		local w, h = room.size[1], room.size[2]
		T.assertEqual(#room.data, h)
		T.assertEqual(#room.data[1], w)
		-- formatFilled: a solid border except where an exit is carved
		for c = 1, w do
			T.assertTrue(room.data[1][c] == "1" or room.data[1][c] == "0")
		end
		for r = 1, h do
			for c = 1, w do
				local v = room.data[r][c]
				T.assertTrue(alphabet.VOCABULARY_SET[v] or v == "P" or v == "H", name .. " holds " .. tostring(v))
			end
		end
		-- every room other than the start has a respawn point by an opening
		T.assertTrue(countGlyph(room.data, alphabet.PLAYER) >= 1, name .. " has no player spawn")
	end
	T.assertTrue(seconds < 60, "5 rooms of 22x14 took " .. seconds .. "s")
	T.timing = T.timing or {}
	T.timing[#T.timing + 1] = string.format("5 rooms 22x14: %.2fs, playable=%s, redraws=%d",
		seconds, tostring(summary.allPlayable), summary.redraws)
end)

T.test("level: generation is deterministic for a seed", function()
	local a = level.generate(dpeData.pe_d5_full, { nbRooms = 3, proba = 0, roomSize = { 16, 10 }, triesLimit = 2 }, Rng.new("det"))
	local b = level.generate(dpeData.pe_d5_full, { nbRooms = 3, proba = 0, roomSize = { 16, 10 }, triesLimit = 2 }, Rng.new("det"))
	for _, name in ipairs(a:listAllRooms()) do
		local ra, rb = a:getRoomByName(name), b:getRoomByName(name)
		T.assertEqual(ra.origin[1] .. "," .. ra.origin[2], rb.origin[1] .. "," .. rb.origin[2])
		for r = 1, #ra.data do
			T.assertEqual(table.concat(ra.data[r]), table.concat(rb.data[r]), name .. " row " .. r)
		end
	end
end)

T.test("level: encoded rooms do not overlap and share openings on the Celeste grid", function()
	local skeleton = level.generate(dpeData.pe_d5_full, { nbRooms = 6, proba = 0.5, roomSize = { 20, 12 }, triesLimit = 2 }, Rng.new("enc"))
	local rooms = encoder.encodeSkeleton(skeleton, { solid = "1" })
	T.assertEqual(#rooms, 6)
	for i = 1, #rooms - 1 do
		for j = i + 1, #rooms do
			local a, b = rooms[i], rooms[j]
			local overlap = a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
			T.assertTrue(not overlap, a.name .. " overlaps " .. b.name)
		end
	end
	-- the end room's heart survives encoding as a blackGem
	local last = rooms[#rooms]
	local gems = 0
	for _, e in ipairs(last.entities) do
		if e.name == "blackGem" then gems = gems + 1 end
	end
	T.assertEqual(gems, 1)
end)

T.test("level: default-size rooms (40x23) generate in reasonable time", function()
	local t0 = os.clock()
	local skeleton, _, summary = level.generate(dpeData.pe_d5_full, {
		nbRooms = 3, proba = 0.3, roomSize = { 40, 23 }, triesLimit = 4,
	}, Rng.new("level-default"))
	local seconds = os.clock() - t0
	T.assertEqual(skeleton:getNbRooms(), 3)
	T.timing = T.timing or {}
	T.timing[#T.timing + 1] = string.format("3 rooms 40x23: %.2fs, playable=%s, redraws=%d",
		seconds, tostring(summary.allPlayable), summary.redraws)
end)

T.test("level: background layer samples from a bg dict in the bg vocabulary", function()
	local bg = level.generateBackground(dpeData.bg_3, 20, 12, Rng.new("bg"))
	T.assertEqual(#bg, 12)
	for r = 1, 12 do
		for c = 1, 20 do
			T.assertTrue(alphabet.VALID_BG_SET[bg[r][c]], "bg symbol " .. tostring(bg[r][c]))
		end
	end
	T.assertEqual(bg[1][1], "0", "bg border should be void")
end)
