-- main.lua - LOVE entry point for the seleCte Lua port's test suite:
--   love Loenn/library/selecte/test
-- (LOVE = LuaJIT, the exact runtime Loenn runs on.) Requires every
-- *_test.lua here, writes test_report.txt next to this file, exits non-zero
-- on any failure. Same harness as Loenn/pcg_engine/celeste-pcg/lua/test.

local here = love.filesystem.getSource() .. "/"
-- `library.selecte.<module>` and `pcg_engine.celeste-pcg.lua.binary_packer`
-- resolve against the Loenn/ directory, three levels up.
local loennDir = here .. "../../../"
package.path = package.path .. ";" .. here .. "?.lua;" .. loennDir .. "?.lua"

local T = require("testing")
T.here = here

require("alphabet_test")
require("rng_test")
require("mdmc_test")
require("skeleton_test")
require("playability_test")
require("encoder_test")
require("recombine_test")
require("level_test")

local allPassed = T.report(here)
os.exit(allPassed and 0 or 1)
