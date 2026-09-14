-- celeste_pcg_analyze.lua
-- Read-only playability/connectivity report for the currently open map,
-- powered by the vendored celeste-pcg Node engine's `analyze` subcommand
-- (Loenn/pcg_engine/celeste-pcg/bin/celeste-pcg.js analyze).
--
-- Per room: is there a player spawn, and is every bit of open space reachable
-- from it (a flood fill catches sealed pockets a carve/decoration pass left
-- behind). Map-wide: rooms whose world rects touch an edge but have no
-- carved opening on that shared border (reported as a note, not an error --
-- not every geometric neighbour is meant to be a door).
--
-- Requires Node.js on PATH and the map to already be saved to disk -- the
-- Node tool reads the .bin file, not Loenn's in-memory editor state.

local mods = require("mods")
local state = require("loaded_state")
local filesystem = require("utils.filesystem")
local pcg = mods.requireFromPlugin("library.pcg_toolkit")

local script = {
    name = "celestePcgAnalyze",
    displayName = "Analyze Map (Node)",
    tooltip = "Runs the bundled celeste-pcg Node tool's playability/connectivity checks against the "
              .. "currently open map's saved .bin file: per-room spawn presence, reachable open space, "
              .. "and rooms that touch on the world grid with no carved opening between them. "
              .. "Read-only -- logs results, does not change the map. Requires Node.js on PATH and a "
              .. "saved map.",
    parameters = {
        json = false,
    },
    tooltips = {
        json = "Log the raw JSON report instead of the human-readable summary.",
    },
}

local function scriptDir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return filesystem.dirname(source)
end

local function engineBin()
    return filesystem.joinpath(scriptDir(), "..", "pcg_engine", "celeste-pcg", "bin", "celeste-pcg.js")
end

local function quote(s)
    return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

function script.prerun(args)
    local mapPath = state.filename
    if not mapPath or mapPath == "" then
        pcg.log("Analyze Map: save the map to a .bin file first -- celeste-pcg reads the file on "
                 .. "disk, not Loenn's in-memory editor state.")
        return nil
    end

    local nodeScript = engineBin()
    local check = io.open(nodeScript, "r")
    if not check then
        pcg.log("celeste-pcg engine not found at " .. nodeScript
                 .. " (vendored copy missing under Loenn/pcg_engine/celeste-pcg/)")
        return nil
    end
    io.close(check)

    local json = args.json == true
    local cmd = string.format(
        "node %s analyze --bin %s%s 2>&1",
        quote(nodeScript), quote(mapPath), json and " --json" or ""
    )
    local proc = io.popen(cmd, "r")
    if not proc then
        pcg.log("Analyze Map: failed to launch Node -- is it installed and on PATH?")
        return nil
    end

    local output = proc:read("*a") or ""
    proc:close()

    if output == "" then
        pcg.log("Analyze Map: no output from celeste-pcg -- is Node.js installed and on PATH?")
    else
        for line in output:gmatch("[^\r\n]+") do
            pcg.log(line)
        end
    end

    -- Read-only: nothing to undo, so no snapshot.
    return nil
end

return script
