local T = require("testing")
local Rng = require("library.selecte.rng").Rng

T.test("rng: same seed, same stream; different seed, different stream", function()
	local a, b, c = Rng.new("seleCte"), Rng.new("seleCte"), Rng.new("other")
	local same, differ = true, false
	for _ = 1, 32 do
		local x, y, z = a:random(), b:random(), c:random()
		if x ~= y then same = false end
		if x ~= z then differ = true end
		T.assertTrue(x >= 0 and x < 1, "random() out of [0, 1)")
	end
	T.assertTrue(same, "identical seeds diverged")
	T.assertTrue(differ, "different seeds never diverged")
end)

T.test("rng: range is half-open and nil on an empty range, int is inclusive", function()
	local r = Rng.new(7)
	local seenLo, seenHiMinus1 = false, false
	for _ = 1, 400 do
		local v = r:range(3, 6)
		T.assertTrue(v >= 3 and v <= 5, "range(3, 6) gave " .. tostring(v))
		if v == 3 then seenLo = true end
		if v == 5 then seenHiMinus1 = true end
	end
	T.assertTrue(seenLo and seenHiMinus1, "range never reached both ends")
	T.assertEqual(r:range(5, 5), nil)
	T.assertEqual(r:range(6, 5), nil)
	local seen6 = false
	for _ = 1, 200 do
		local v = r:int(4, 6)
		T.assertTrue(v >= 4 and v <= 6)
		if v == 6 then seen6 = true end
	end
	T.assertTrue(seen6, "int(4, 6) never returned 6")
end)

T.test("rng: weighted draw follows the flat distribution", function()
	local r = Rng.new("weights")
	T.assertEqual(r:weighted({ "a", 1 }), "a")
	T.assertEqual(r:weighted({ "a", 0, "b", 0.5 }), "b")
	local counts = { x = 0, y = 0 }
	for _ = 1, 2000 do
		local s = r:weighted({ "x", 0.9, "y", 0.1 })
		counts[s] = counts[s] + 1
	end
	T.assertTrue(counts.x > 1650 and counts.x < 1950, "x drawn " .. counts.x .. " times of 2000")
end)

T.test("rng: shuffle and choice keep to the list", function()
	local r = Rng.new("shuffle")
	local list = r:shuffle({ 1, 2, 3, 4, 5 })
	local sum = 0
	for _, v in ipairs(list) do sum = sum + v end
	T.assertEqual(sum, 15)
	T.assertEqual(#list, 5)
	for _ = 1, 20 do
		local v = r:choice({ "p", "q" })
		T.assertTrue(v == "p" or v == "q")
	end
end)

T.test("rng: an empty seed still yields a usable, recorded seed", function()
	local r = Rng.new("")
	T.assertTrue(r.seed ~= nil and r.seed ~= "", "seed not recorded")
	T.assertTrue(r:random() < 1)
end)
