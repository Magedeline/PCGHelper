local T = require("testing")
local recombine = require("library.selecte.recombine")
local encoder = require("library.selecte.encoder")
local mdmc = require("library.selecte.mdmc")
local alphabet = require("library.selecte.alphabet")

local function blankRows(w, h)
	local rows = {}
	for r = 1, h do rows[r] = string.rep("0", w) end
	return rows
end

T.test("recombine: solid tileset variants collapse to 1, unknown glyphs are reported", function()
	local data = recombine.collapseFgRows({ "13ah", "0 0z", "0000" })
	T.assertEqual(table.concat(mdmc.roomToRows(data), "|"), "1111|0001|0000")
	local bad = recombine.collapseFgRows({ "1#1", "0(0" })
	local invalid = recombine.invalidSymbolCounts(bad, { ["0"] = true, ["1"] = true })
	T.assertEqual(invalid["#"], 1)
	T.assertEqual(invalid["("], 1)
	local grid, report = recombine.recombineRoom({ fgRows = { "1#1", "0(0", "000" }, entities = {} })
	T.assertEqual(grid, nil)
	T.assertEqual(report.invalid["#"], 1)
end)

T.test("recombine: sized entities stamp the tiles they cover, point entities shift one tile", function()
	-- spikesUp at x=16, y=32, width=24: columns 3..5 (1-based), the row above
	-- the one y lands in (the missing height is the point-entity shift).
	local grid = recombine.recombineRoom({
		fgRows = blankRows(10, 6),
		entities = {
			{ name = "spikesUp", x = 16, y = 32, width = 24 },
			{ name = "spinner", x = 60, y = 20 },
			{ name = "booster", x = 4, y = 4, red = true },
			{ name = "zipMover", x = 0, y = 0, width = 16, height = 16 },
		},
	})
	local rows = mdmc.roomToRows(grid)
	T.assertEqual(rows[4], "00^^^00000")
	T.assertEqual(rows[5], "0000000000")
	-- spinner: floor(60/8)=7 -> 6 -> col 7; floor(20/8)=2 -> 1 -> row 2
	T.assertEqual(rows[2]:sub(7, 7), "S")
	-- red booster at (4,4): floor 0 -> clamp 0 -> col 1, row 1
	T.assertEqual(rows[1]:sub(1, 1), "Q")
	T.assertEqual(rows[1]:sub(2, 2), "0", "unknown entity stamped something")
end)

T.test("recombine: entities outside the room are counted, not stamped", function()
	local grid, report = recombine.recombineRoom({
		fgRows = blankRows(4, 4),
		entities = {
			{ name = "refill", x = 200, y = 8 },
			{ name = "refill", x = -8, y = 8 },
		},
	})
	T.assertEqual(report.kept, 2)
	T.assertEqual(report.outside, 1)
	T.assertEqual(mdmc.roomToRows(grid)[1], "R000", "a box straddling the left border covers tile 1")
end)

T.test("recombine: a booster without a red flag is dropped, green/red split on it", function()
	local ents = recombine.filterEntities({
		{ name = "booster", x = 0, y = 0 },
		{ name = "booster", x = 0, y = 0, red = false },
		{ name = "booster", x = 0, y = 0, red = true },
	})
	T.assertEqual(#ents, 2)
	T.assertEqual(ents[1].symbol, "O")
	T.assertEqual(ents[2].symbol, "Q")
end)

T.test("recombine: encode then decode round-trips tiles, dream blocks and up-spikes exactly", function()
	-- D carries both sizes, so neither axis is shifted on the way back; ^ has
	-- a width and the (0, 8) offset, which the sizeless-axis shift undoes.
	local data = mdmc.rowsToRoom({
		"1111111111",
		"1000000001",
		"1000DD0001",
		"100^^^0001",
		"1111111111",
	})
	local room = { size = { 10, 5 }, origin = { 0, 0 }, data = data }
	local encoded = encoder.encodeRoom(room, "r")
	local back = recombine.recombineRoom({ fgRows = encoded.fgRows, entities = encoded.entities })
	T.assertEqual(table.concat(mdmc.roomToRows(back), "|"), table.concat(mdmc.roomToRows(data), "|"))
end)

T.test("recombine: a width-only entity with no offset drifts one row up on decode", function()
	-- _tile_span applies the point-entity shift per axis whenever that axis
	-- carries no size, so a jumpThru (width only, zero offset) comes back one
	-- row above where it was encoded. The Python does the same; seleCte's
	-- ALPHABET.md documents the drift for point entities and ^/<.
	local data = mdmc.rowsToRoom({ "0000000", "0000000", "00___00", "0000000" })
	local encoded = encoder.encodeRoom({ size = { 7, 4 }, origin = { 0, 0 }, data = data }, "r")
	local back = recombine.recombineRoom({ fgRows = encoded.fgRows, entities = encoded.entities })
	T.assertEqual(table.concat(mdmc.roomToRows(back), "|"), "0000000|00___00|0000000|0000000")
end)

T.test("recombine: point entities come back one tile up and to the left (documented drift)", function()
	local data = mdmc.rowsToRoom({ "0000", "00R0", "0000" })
	local encoded = encoder.encodeRoom({ size = { 4, 3 }, origin = { 0, 0 }, data = data }, "r")
	local back = recombine.recombineRoom({ fgRows = encoded.fgRows, entities = encoded.entities })
	T.assertEqual(mdmc.roomToRows(back)[1], "0R00")
end)

T.test("recombine: background rooms are validated, never collapsed", function()
	local grid = recombine.collectBgRoom({ bgRows = { "0a0", "aa ", "000" } })
	T.assertEqual(table.concat(mdmc.roomToRows(grid), "|"), "0a0|aa0|000")
	local bad, report = recombine.collectBgRoom({ bgRows = { "0z0", "000", "000" } })
	T.assertEqual(bad, nil)
	T.assertEqual(report.invalid.z, 1)
end)

T.test("recombine: buildCorpus skips bad rooms and feeds mdmc.estimate", function()
	local rooms = {
		{ name = "ok", fgRows = { "111111", "100001", "100001", "111111" }, entities = { { name = "spinner", x = 20, y = 20 } } },
		{ name = "modded", fgRows = { "###", "#0#", "###" }, entities = {} },
		{ name = "tiny", fgRows = { "11", "11" }, entities = {} },
	}
	local grids, summary = recombine.buildCorpus(rooms, "fg")
	T.assertEqual(#grids, 1)
	T.assertEqual(summary.kept, 1)
	T.assertEqual(#summary.skipped, 2)
	T.assertEqual(summary.entities, 1)
	local dpe = mdmc.estimate(grids, alphabet.DEFAULT_MASK)
	T.assertTrue(mdmc.patternCount(dpe) > 0)
end)
