-- grid_test.lua - cross-checked against the real grid.js's actual output
-- (see the conversation this port was built in) before being hardcoded.

local T = require("testing")
local Grid = require("grid").Grid

T.test("grid: fillRect/set/get/solid/toInnerText/toFlatArray match grid.js", function()
	local g = Grid.new(5, 3, "0")
	g:fillRect(1, 0, 3, 1, "1")
	g:set(0, 2, "9")

	T.assertEqual(g:toInnerText(), "01110\n01110\n90000", "toInnerText")

	local flat = g:toFlatArray()
	local expected = { "0", "1", "1", "1", "0", "0", "1", "1", "1", "0", "9", "0", "0", "0", "0" }
	T.assertEqual(#flat, #expected, "toFlatArray length")
	for i = 1, #expected do
		T.assertEqual(flat[i], expected[i], "toFlatArray[" .. i .. "]")
	end

	T.assertEqual(g:solid(1, 0), true, "solid(1,0)")
	T.assertEqual(g:solid(0, 0), false, "solid(0,0)")
	T.assertEqual(g:get(99, 99), "0", "out-of-bounds get returns air")
end)

T.test("grid: out-of-bounds set is a no-op, not an error", function()
	local g = Grid.new(3, 3, "0")
	g:set(-1, -1, "5") -- should silently do nothing
	g:set(100, 100, "5")
	T.assertEqual(g:toInnerText(), "000\n000\n000", "out-of-bounds writes should not corrupt the grid")
end)
