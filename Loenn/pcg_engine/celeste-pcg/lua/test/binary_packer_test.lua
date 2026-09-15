-- binary_packer_test.lua - the most fragile file in this whole port
-- (varint strings + hand-rolled IEEE754 float32, since LuaJIT has no
-- string.pack). Covers: round-trip within Lua alone (every value type,
-- negatives, large ints, empty strings - mirroring binary-packer.js's own
-- test/roundtrip.test.js coverage), and a cross-language fixture: bytes
-- actually produced by the real JS encodeMap, decoded here with the Lua
-- decoder and checked against exact expected values (including an f32
-- value's exact double-precision truncation, verified byte-identical to
-- what Node's own decoder produces from the same bytes - see the
-- conversation this was built in).

local T = require("testing")
local bp = require("binary_packer")

-- love.filesystem.getSource() (absolute), not debug.getinfo - see
-- main.lua's comment on why debug.getinfo's source isn't reliably a real
-- path under LOVE
local function scriptDir()
	return love.filesystem.getSource() .. "/"
end

T.test("binary_packer: mixed value types survive a round-trip", function()
	local tree = {
		name = "Root",
		attrs = { boolT = true, boolF = false, u8v = 200, i16v = -1000, i32v = 100000, f32v = 1.5, str = "hello", empty = "" },
		children = {
			{ name = "child", attrs = { ref = "hello" }, children = {} }, -- "hello" should reuse the lookup entry
		},
	}
	local bytes = bp.encodeMap(tree, "pkg")
	local decoded = bp.decodeMap(bytes)

	T.assertEqual(decoded.header, "CELESTE MAP", "header")
	T.assertEqual(decoded.package, "pkg", "package")
	local a = decoded.root.attrs
	T.assertEqual(a.boolT, true, "boolT")
	T.assertEqual(a.boolF, false, "boolF")
	T.assertEqual(a.u8v, 200, "u8v")
	T.assertEqual(a.i16v, -1000, "i16v")
	T.assertEqual(a.i32v, 100000, "i32v")
	T.assertClose(a.f32v, 1.5, 1e-6, "f32v")
	T.assertEqual(a.str, "hello", "str")
	T.assertEqual(a.empty, "", "empty")
	T.assertEqual(decoded.root.children[1].attrs.ref, "hello", "lookup-referenced string")
end)

T.test("binary_packer: negative/large ints and empty strings round-trip", function()
	local tree = {
		name = "R",
		attrs = {
			maxI32 = 2147483647, minI32 = -2147483648,
			maxU8 = 255, minU8 = 0,
			maxI16 = 32767, minI16 = -32768,
			overflowsI32 = 3000000000.5, -- forces the f32 fallback path
		},
		children = {},
	}
	local decoded = bp.decodeMap(bp.encodeMap(tree, ""))
	local a = decoded.root.attrs
	T.assertEqual(a.maxI32, 2147483647, "maxI32")
	T.assertEqual(a.minI32, -2147483648, "minI32")
	T.assertEqual(a.maxU8, 255, "maxU8")
	T.assertEqual(a.minU8, 0, "minU8")
	T.assertEqual(a.maxI16, 32767, "maxI16")
	T.assertEqual(a.minI16, -32768, "minI16")
	T.assertClose(a.overflowsI32, 3000000000.5, 200, "overflowsI32 (f32 precision loss expected at this magnitude)")
end)

T.test("binary_packer: innerText round-trips exactly, including newlines", function()
	local tree = { name = "solids", attrs = { offsetX = 0 }, children = {}, innerText = "111\n000\n999" }
	local decoded = bp.decodeMap(bp.encodeMap(tree, "p"))
	T.assertEqual(decoded.root.innerText, "111\n000\n999", "innerText")
	T.assertEqual(decoded.root.attrs.innerText, nil, "innerText should not also appear as a regular attr")
end)

T.test("binary_packer: decodes a fixture ENCODED BY THE REAL JS ENCODER (cross-language check)", function()
	local f = io.open(scriptDir() .. "fixtures/cross_check_js_encoded.bin", "rb")
	T.assertTrue(f ~= nil, "fixture file should exist")
	local bytes = f:read("*a")
	f:close()

	local decoded = bp.decodeMap(bytes)
	T.assertEqual(decoded.header, "CELESTE MAP", "header")
	T.assertEqual(decoded.package, "CrossCheck", "package")

	local level = decoded.root.children[1]
	T.assertEqual(level.name, "level", "level name")
	local a = level.attrs
	T.assertEqual(a.name, "a-00", "name")
	T.assertEqual(a.x, 0, "x")
	T.assertEqual(a.y, -128, "y")
	T.assertEqual(a.width, 320, "width")
	T.assertEqual(a.height, 184, "height")
	T.assertEqual(a.c, 255, "c")
	T.assertEqual(a.dark, false, "dark")
	T.assertEqual(a.music, "music_city", "music")
	T.assertEqual(a.cameraOffsetX, -12345, "cameraOffsetX")
	T.assertClose(a.alpha, 0.5, 1e-9, "alpha")
	T.assertEqual(a.tiny, 3, "tiny")
	T.assertEqual(a.big, 2000000000, "big")
	T.assertEqual(a.neg, -300, "neg")
	-- the exact f32-truncated value real Node's own decoder produces from
	-- these same bytes - not "close to the original 3.14159265", the
	-- ACTUAL bit-for-bit result: 3.1415927410125732
	T.assertClose(a.fraction, 3.1415927410125732, 1e-13, "fraction (f32 truncation, cross-checked against Node's own decode)")

	local solids = level.children[1]
	T.assertEqual(solids.innerText, "111\n000\n999", "solids innerText")

	local player = level.children[2].children[1]
	T.assertEqual(player.name, "player", "player name")
	T.assertEqual(player.attrs.id, 1, "player id")
	T.assertEqual(player.attrs.winged, true, "player winged")
	T.assertEqual(player.attrs.tag, "music_city", "player tag (shares a lookup entry with level.music)")
	T.assertEqual(player.children[1].name, "node", "player has a node child")
	T.assertEqual(player.children[1].attrs.x, 41, "node x")
end)
