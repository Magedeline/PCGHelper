local T = require("testing")
local alphabet = require("library.selecte.alphabet")
local mdmc = require("library.selecte.mdmc")
local dpeData = require("library.selecte.dpe_data")
local Rng = require("library.selecte.rng").Rng

T.test("mdmc: shipped dicts load, carry the d5 mask and match it", function()
	local names = { "pe_d5_full", "fg_1", "fg_7", "bg_3", "bg_9" }
	for _, n in ipairs(names) do
		local dpe = dpeData[n]
		T.assertTrue(dpe ~= nil, n .. " missing")
		T.assertEqual(dpe.mask, "000011012", n)
		mdmc.checkDpeMatchesMask(dpe, mdmc.resolveMask(dpe))
	end
	T.assertEqual(mdmc.patternCount(dpeData.pe_d5_full), 301)
	-- every distribution sums to ~1 and only holds vocabulary symbols
	for pattern, dist in pairs(dpeData.pe_d5_full.patterns) do
		local sum = 0
		for i = 1, #dist - 1, 2 do
			T.assertTrue(alphabet.VOCABULARY_SET[dist[i]], pattern .. " -> " .. dist[i])
			sum = sum + dist[i + 1]
		end
		T.assertClose(sum, 1, 1e-9, "pattern " .. pattern)
	end
end)

T.test("mdmc: empty room is void inside a border", function()
	local d = mdmc.emptyRoom(6, 4)
	T.assertEqual(table.concat(mdmc.roomToRows(d), "|"), "111111|100001|100001|111111")
	local b = mdmc.emptyRoom(3, 3, "0")
	T.assertEqual(table.concat(mdmc.roomToRows(b), "|"), "000|000|000")
end)

T.test("mdmc: extractPattern reads the d5 neighbourhood in mask order", function()
	local d = mdmc.rowsToRoom({ "abc", "def", "ghi" })
	local m = alphabet.parseMask("000011012")
	T.assertEqual(mdmc.extractPattern(d, 1, 1, m.offsets), "efh")
end)

T.test("mdmc: generateRoomData keeps the top/left border, stays in vocabulary, is deterministic", function()
	-- The sweep's target cell trails the window, so row 1 and column 1 keep
	-- the border while the last row/column are written over like any other
	-- cell (the Python does the same; formatFilled restores full borders).
	-- Rows 1-2 and columns 1-2 are never written at all.
	local dpe = dpeData.pe_d5_full
	local a = mdmc.generateRoomData(dpe, 22, 14, Rng.new("room-a"))
	local b = mdmc.generateRoomData(dpe, 22, 14, Rng.new("room-a"))
	local c = mdmc.generateRoomData(dpe, 22, 14, Rng.new("room-c"))
	T.assertEqual(#a, 14)
	T.assertEqual(#a[1], 22)
	local same, differ, nonVoid = true, false, 0
	for r = 1, 14 do
		for col = 1, 22 do
			T.assertTrue(alphabet.VOCABULARY_SET[a[r][col]], "symbol " .. tostring(a[r][col]))
			if r == 1 or col == 1 then
				T.assertEqual(a[r][col], "1", "border at " .. r .. "," .. col)
			elseif (r == 2 and col < 22) or (col == 2 and r < 14) then
				T.assertEqual(a[r][col], "0", "second row/column at " .. r .. "," .. col)
			end
			if a[r][col] ~= b[r][col] then same = false end
			if a[r][col] ~= c[r][col] then differ = true end
			if r > 2 and r < 14 and col > 2 and col < 22 and a[r][col] ~= "0" then nonVoid = nonVoid + 1 end
		end
	end
	T.assertTrue(same, "same seed gave different rooms")
	T.assertTrue(differ, "different seeds gave the same room")
	T.assertTrue(nonVoid > 0, "room interior is entirely void")
end)

T.test("mdmc: backtracking depth produces a valid room too", function()
	local d = mdmc.generateRoomData(dpeData.pe_d5_full, 20, 12, Rng.new("bt"), { btDepth = 3 })
	for r = 1, 12 do
		for c = 1, 20 do
			T.assertTrue(alphabet.VOCABULARY_SET[d[r][c]])
		end
	end
end)

T.test("mdmc: generateNewTile raises when every positive symbol is excluded", function()
	local rng = Rng.new("ex")
	local ok = pcall(mdmc.generateNewTile, { "a", 0.5, "b", 0.5, "c", 0 }, nil, { "a", "b" }, rng)
	T.assertTrue(not ok, "should have raised")
	local tile = mdmc.generateNewTile({ "a", 0.5, "b", 0.5 }, nil, { "a" }, rng)
	T.assertTrue(tile == "a" or tile == "b")
	T.assertTrue(alphabet.VOCABULARY_SET[mdmc.generateNewTile(nil, alphabet.ALL_TILES_AND_ENTITIES, nil, rng)])
end)

T.test("mdmc: estimate counts patterns and normalises per pattern", function()
	-- 5x5, all void except a solid column: the d5 window sees a handful of
	-- patterns whose distributions must sum to 1.
	local rooms = { mdmc.rowsToRoom({ "00100", "00100", "00100", "00100", "00100" }) }
	local dpe, n = mdmc.estimate(rooms, "000011012", alphabet.ALL_TILES_AND_ENTITIES)
	T.assertEqual(n, 1)
	T.assertEqual(dpe.mask, "000011012")
	-- window at (1,1): e=(2,2)=0 f=(2,3)=1 h=(3,2)=0 -> "010" predicts (3,3)=1
	T.assertEqual(dpe.patterns["010"][1], "1")
	T.assertClose(dpe.patterns["010"][2], 1)
	for _, dist in pairs(dpe.patterns) do
		local sum = 0
		for i = 2, #dist, 2 do sum = sum + dist[i] end
		T.assertClose(sum, 1)
	end
	-- an estimated dict samples straight away
	local d = mdmc.generateRoomData(dpe, 8, 6, Rng.new("est"))
	T.assertEqual(#d, 6)
end)

T.test("mdmc: estimate refuses an empty corpus", function()
	T.assertTrue(not pcall(mdmc.estimate, {}, "000011012"))
	T.assertTrue(not pcall(mdmc.estimate, { mdmc.rowsToRoom({ "00", "00" }) }, "000011012"))
end)
