-- testing.lua - a minimal assert-based test runner, since there's no
-- "lua --test" the way there's "node --test". Run via LOVE headlessly:
--   love Loenn/library/selecte/test  (conf.lua disables window/graphics/audio)
-- Every *_test.lua file in this directory calls test(name, fn); main.lua
-- requires them all, then calls report(), which writes results to
-- test_report.txt (LOVE's stdout isn't reliably capturable on Windows -
-- see the conversation this harness was built in) and os.exit()s non-zero
-- on any failure.

local M = { results = {} }

function M.test(name, fn)
	local ok, err = pcall(fn)
	table.insert(M.results, { name = name, ok = ok, err = err })
end

local function fmt(v)
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

function M.assertEqual(actual, expected, msg)
	if actual ~= expected then
		error((msg or "assertEqual failed") .. ": expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
	end
end

function M.assertTrue(v, msg)
	if not v then
		error(msg or "assertTrue failed: value was falsy", 2)
	end
end

function M.assertClose(actual, expected, epsilon, msg)
	epsilon = epsilon or 1e-6
	if math.abs(actual - expected) > epsilon then
		error((msg or "assertClose failed") .. ": expected ~" .. fmt(expected) .. ", got " .. fmt(actual), 2)
	end
end

-- writes results to <outDir>/test_report.txt, returns true iff everything passed
function M.report(outDir)
	local path = (outDir or "") .. "test_report.txt"
	local f = io.open(path, "w")
	local pass, fail = 0, 0
	for _, r in ipairs(M.results) do
		if r.ok then
			pass = pass + 1
			f:write("  ok  " .. r.name .. "\n")
		else
			fail = fail + 1
			f:write("  FAIL " .. r.name .. "\n       " .. tostring(r.err) .. "\n")
		end
	end
	for _, line in ipairs(M.timing or {}) do
		f:write("  time " .. line .. "\n")
	end
	f:write("\n" .. pass .. " passed, " .. fail .. " failed\n")
	f:close()
	return fail == 0
end

return M
