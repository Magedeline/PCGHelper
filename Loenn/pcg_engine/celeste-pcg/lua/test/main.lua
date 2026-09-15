-- main.lua - LOVE entry point for the Lua port's test suite. Run with:
--   love Loenn/pcg_engine/celeste-pcg/lua/test
-- (or `lovec` for a version that keeps a console window open on error).
-- Requires every *_test.lua in this directory (each just calls T.test(...)
-- as a side effect of being required), then reports and exits non-zero on
-- any failure - the closest equivalent to `node --test` this runtime has.

-- resolve paths from LOVE's own idea of the game directory (absolute),
-- not debug.getinfo - when main.lua is loaded as LOVE's entry point (as
-- opposed to required from a script whose own CWD happens to match),
-- debug.getinfo's source is just the virtual path "main.lua" with no
-- directory component at all, which silently breaks relative package.path
-- entries (found by actually running this, not assumed - see the
-- conversation this harness was built in)
local here = love.filesystem.getSource() .. "/"
package.path = package.path .. ";" .. here .. "?.lua;" .. here .. "../?.lua"

local T = require("testing")

require("rng_test")
require("grid_test")
require("binary_packer_test")

local allPassed = T.report(here)
os.exit(allPassed and 0 or 1)
