-- celeste_pcg_runner.lua
-- Bridges the standalone celeste-pcg Node generator (vendored under
-- Loenn/pcg_engine/celeste-pcg/, originally from OgmoEditor3-CE) into
-- PCGHelper's script menu.
--
-- Different algorithm from the Skeleton/Markov scripts: a deterministic
-- path-carve layout (self-avoiding walk + carved spine/spur rooms) that
-- guarantees a traversable route by construction, rather than MdMC/WFC tile
-- filling. It writes a brand-new standalone chapter to disk (.bin and/or
-- Ogmo .json levels) instead of editing the currently open map.
--
-- Requires Node.js on PATH.

local mods = require("mods")
local state = require("loaded_state")
local snapshot = require("structs.snapshot")
local filesystem = require("utils.filesystem")
local pcg = mods.requireFromPlugin("library.pcg_toolkit")

local MUSIC_OPTIONS = {
    "music_city", "music_oldsite", "music_oldsite_mirror", "music_resort_intro",
    "music_cliffside_main", "music_temple_normal", "music_reflection_main",
    "music_summit_main", "music_core_main",
    "music_rmx_01_forsaken_city", "music_rmx_02_old_site", "music_rmx_03_resort",
    "music_rmx_04_cliffside", "music_rmx_05_mirror_temple", "music_rmx_06_reflection",
    "music_rmx_07_summit", "music_rmx_09_core", "music_pico8_area1", "",
}

local script = {
    name = "celestePcgRunner",
    displayName = "Celeste PCG Runner (path-carve)",
    tooltip = "Generates a brand-new, guaranteed-traversable multi-room chapter with the bundled "
              .. "celeste-pcg Node tool and writes it to disk as a standalone .bin (and/or Ogmo "
              .. "levels), rather than editing the currently open map. Requires Node.js on PATH.",
    parameters = {
        seed = "celeste-pcg",
        rooms = 8,
        chapterName = "GeneratedChapter",
        music = "music_city",
        difficulty = "normal",
        roomWidthTiles = 44,
        roomHeightTiles = 23,
        straight = false,
        format = "bin",
        outputDir = "",
    },
    fieldInformation = {
        rooms = { fieldType = "integer", options = { min = 4, max = 64 } },
        roomWidthTiles = { fieldType = "integer" },
        roomHeightTiles = { fieldType = "integer" },
        difficulty = { fieldType = "loennScripts.dropdown", options = { "normal", "chill" }, editable = false },
        format = { fieldType = "loennScripts.dropdown", options = { "bin", "ogmo", "both" }, editable = false },
        music = { fieldType = "loennScripts.dropdown", options = MUSIC_OPTIONS, editable = true },
    },
    tooltips = {
        seed = "Deterministic seed -- the same seed always produces byte-identical output.",
        rooms = "Number of rooms in the generated chapter (4-64).",
        chapterName = "Map name and output .bin filename.",
        music = "FMOD music event for the generated chapter. Blank = silent.",
        difficulty = "chill disables hazards (spikes); normal includes them.",
        roomWidthTiles = "Room width in tiles. Rooms are a uniform size -- required for the carve's edge-aligned transitions.",
        roomHeightTiles = "Room height in tiles.",
        straight = "Force a horizontal-only chain of rooms (no vertical transitions).",
        format = "bin = load directly in Celeste via F6. ogmo = per-room .json for hand-editing in OgmoEditor3-CE. both = write both.",
        outputDir = "Where to write the generated chapter. Blank = a pcg_output folder next to the currently open map (or next to this script if no map is open).",
    },
}

local function scriptDir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return filesystem.dirname(source)
end

local function engineBin()
    return filesystem.joinpath(scriptDir(), "..", "pcg_engine", "celeste-pcg", "bin", "celeste-pcg.js")
end

local function defaultOutputDir()
    local mapDir = state.filename and filesystem.dirname(state.filename)
    return filesystem.joinpath(mapDir or scriptDir(), "pcg_output")
end

local function quote(s)
    return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

function script.prerun(args)
    local seed = (args.seed and args.seed ~= "") and args.seed or "celeste-pcg"
    local rooms = math.max(4, math.min(64, math.floor(tonumber(args.rooms) or 8)))
    local name = (args.chapterName and args.chapterName ~= "") and args.chapterName or "GeneratedChapter"
    local music = args.music or "music_city"
    local difficulty = args.difficulty or "normal"
    local roomW = math.max(10, math.floor(tonumber(args.roomWidthTiles) or 44))
    local roomH = math.max(10, math.floor(tonumber(args.roomHeightTiles) or 23))
    local format = args.format or "bin"
    local straight = args.straight == true
    local outDir = (args.outputDir and args.outputDir ~= "") and args.outputDir or defaultOutputDir()

    local nodeScript = engineBin()
    local check = io.open(nodeScript, "r")
    if not check then
        pcg.log("celeste-pcg engine not found at " .. nodeScript
                 .. " (vendored copy missing under Loenn/pcg_engine/celeste-pcg/)")
        return nil
    end
    io.close(check)

    local function forward()
        pcall(filesystem.mkpath, outDir)

        local cmd = string.format(
            "node %s --seed %s --rooms %d --name %s --music %s --difficulty %s "
            .. "--room-width %d --room-height %d --format %s --out %s%s",
            quote(nodeScript), quote(seed), rooms, quote(name), quote(music), quote(difficulty),
            roomW, roomH, quote(format), quote(outDir), straight and " --straight" or ""
        )

        local ok = os.execute(cmd)
        local success = ok == true or ok == 0

        if success then
            local mapPath = filesystem.joinpath(outDir, name, "Maps", name .. ".bin")
            pcg.log(string.format(
                "celeste-pcg: generated '%s' (%d rooms, %s difficulty) -> %s",
                name, rooms, difficulty, mapPath))
        else
            pcg.log("celeste-pcg failed -- is Node.js installed and on PATH? Command: " .. cmd)
        end
    end

    local function backward()
        pcg.log("celeste-pcg wrote its output directly to disk; undo does not delete those files "
                 .. "-- remove the output folder by hand if needed.")
    end

    forward()
    return snapshot.create(script.name, {}, backward, forward)
end

return script
