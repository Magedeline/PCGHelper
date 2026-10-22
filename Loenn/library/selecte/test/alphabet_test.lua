local T = require("testing")
local alphabet = require("library.selecte.alphabet")

T.test("alphabet: default mask parses to the d5 window", function()
	local m = alphabet.parseMask("000011012")
	T.assertEqual(m.side, 3)
	T.assertEqual(#m.offsets, 3)
	T.assertEqual(m.offsets[1][1] .. "," .. m.offsets[1][2], "1,1")
	T.assertEqual(m.offsets[2][1] .. "," .. m.offsets[2][2], "1,2")
	T.assertEqual(m.offsets[3][1] .. "," .. m.offsets[3][2], "2,1")
	T.assertEqual(m.target[1] .. "," .. m.target[2], "2,2")
end)

T.test("alphabet: bad masks are rejected like the Python ValueErrors", function()
	T.assertTrue(not pcall(alphabet.parseMask, "0000110"), "non-square")
	T.assertTrue(not pcall(alphabet.parseMask, "000000002"), "no neighbourhood cell")
	T.assertTrue(not pcall(alphabet.parseMask, "000011011"), "no target")
	T.assertTrue(not pcall(alphabet.parseMask, "000011022"), "two targets")
end)

T.test("alphabet: entity glyphs and tileset glyphs never overlap", function()
	for glyph in pairs(alphabet.ENTITY_MAP) do
		T.assertTrue(not alphabet.VALID_FG_SET[glyph], glyph .. " is both an entity and a tileset glyph")
	end
	for name, glyph in pairs(alphabet.ENTITY_SYMBOLS) do
		T.assertTrue(alphabet.VOCABULARY_SET[glyph], name .. " maps to a symbol outside the vocabulary")
	end
end)

T.test("alphabet: entity_symbols agree with Maple's names where both know a glyph", function()
	-- The Julia smoke test's last block: O/Q are both Maple `booster`s, L has
	-- no Maple entry, everything else must name the same entity.
	for name, glyph in pairs(alphabet.ENTITY_SYMBOLS) do
		local spec = alphabet.ENTITY_MAP[glyph]
		if spec and glyph ~= "O" and glyph ~= "Q" then
			T.assertEqual(spec.name, name, "glyph " .. glyph)
		end
	end
	T.assertEqual(alphabet.ENTITY_MAP["L"], nil, "lightbeam has no encoder entry")
	T.assertEqual(alphabet.ENTITY_MAP["H"].name, "blackGem")
end)
