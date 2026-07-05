-- Lönn Script: PCGHelper AI Map Importer
-- Imports AI-generated map data from the gamelab PCG AI into the current map.
-- Usage: Open a map in Lönn, then run this script from the Scripts menu.

local state = require("loaded_state")
local snapshot = require("structs.snapshot")
local mapItemUtils = require("map_item_utils")
local mods = require("mods")
local filesystem = require("utils.filesystem")
local pcg = mods.requireFromPlugin("library.pcg_toolkit")

local TILE = 8

local PCGImport = {}

PCGImport.name = "pcgHelperAiImport"
PCGImport.displayName = "PCGHelper AI: Import Generated Map"
PCGImport.tooltip = "Imports AI-generated map data from the gamelab PCG AI server.\nExpects a JSON file at Loenn/pcg/output/generated_map.json"

PCGImport.parameters = {
    inputFile = "Loenn/pcg/output/generated_map.json",
    mode = "merge",          -- "merge" or "replace"
    targetRoom = "",         -- empty = import all rooms, or specify a room name
    offset_x = 0,
    offset_y = 0,
    dryRun = false,
}

PCGImport.fieldInformation = {
    inputFile = { fieldType = "string", description = "Path to the AI-generated map JSON file" },
    mode = { fieldType = "string", description = "merge = add to existing map, replace = clear and replace" },
    targetRoom = { fieldType = "string", description = "Import into a specific room (empty = create new rooms)" },
    offset_x = { fieldType = "integer", description = "X offset for imported entities/tiles" },
    offset_y = { fieldType = "integer", description = "Y offset for imported entities/tiles" },
    dryRun = { fieldType = "boolean", description = "Preview without applying changes" },
}

PCGImport.fieldOrder = {"inputFile", "mode", "targetRoom", "offset_x", "offset_y", "dryRun"}

local function loadJSON(filepath)
    local file = io.open(filepath, "r")
    if not file then
        print(string.format("[ERROR] Could not open file: %s", filepath))
        return nil
    end
    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        print("[ERROR] File is empty")
        return nil
    end

    local success, json = pcall(require, "json")
    if success and json then
        local ok, data = pcall(json.decode, content)
        if ok then return data end
    end

    local ok2, dkjson = pcall(require, "dkjson")
    if ok2 and dkjson then
        local data = dkjson.decode(content)
        if data then return data end
    end

    print("[ERROR] No JSON library found (tried 'json' and 'dkjson')")
    return nil
end

local function deserializeTiles(rows, w, h)
    if not rows or #rows == 0 then return nil end
    local grid = pcg.newGrid(w, h, "0")
    for y, row in ipairs(rows) do
        local y0 = y - 1
        if y0 < h then
            for x = 1, math.min(#row, w) do
                grid[x - 1][y0] = row:sub(x, x)
            end
        end
    end
    return pcg.gridToTilesStruct(grid, w, h)
end

local function copyNodesWithOffset(nodes, ox, oy)
    if not nodes then return nil end
    local out = {}
    for _, node in ipairs(nodes) do
        table.insert(out, { x = (node.x or 0) + ox, y = (node.y or 0) + oy })
    end
    return out
end

local function importRoom(roomData, ox, oy)
    local wPixels = roomData.width or 320
    local hPixels = roomData.height or 184
    local wTiles = math.floor(wPixels / TILE)
    local hTiles = math.floor(hPixels / TILE)
    local room = pcg.createRoom(roomData.name or "pcg_room", (roomData.x or 0) + ox, (roomData.y or 0) + oy, wTiles, hTiles)

    if roomData.tilesFg and #roomData.tilesFg > 0 then
        room.tilesFg = deserializeTiles(roomData.tilesFg, wTiles, hTiles)
    end
    if roomData.tilesBg and #roomData.tilesBg > 0 then
        room.tilesBg = deserializeTiles(roomData.tilesBg, wTiles, hTiles)
    end

    for _, entData in ipairs(roomData.entities or {}) do
        local name = entData.name or entData._name or "unknown"
        local attrs = {}
        attrs.nodes = copyNodesWithOffset(entData.nodes, ox, oy)
        for k, v in pairs(entData) do
            if k ~= "name" and k ~= "_name" and k ~= "x" and k ~= "y" and k ~= "nodes" then
                attrs[k] = v
            end
        end
        pcg.addEntity(room, name, (entData.x or 0) + ox, (entData.y or 0) + oy, attrs)
    end

    for _, trigData in ipairs(roomData.triggers or {}) do
        local name = trigData.name or trigData._name or "unknown"
        local attrs = {}
        attrs.nodes = copyNodesWithOffset(trigData.nodes, ox, oy)
        for k, v in pairs(trigData) do
            if k ~= "name" and k ~= "_name" and k ~= "x" and k ~= "y" and k ~= "width" and k ~= "height" and k ~= "nodes" then
                attrs[k] = v
            end
        end
        pcg.addTrigger(room, name, (trigData.x or 0) + ox, (trigData.y or 0) + oy, trigData.width or 16, trigData.height or 16, attrs)
    end

    for _, decal in ipairs(roomData.decalsFg or {}) do
        pcg.addDecal(room, "fg", decal.texture or "", (decal.x or 0) + ox, (decal.y or 0) + oy, {
            scaleX = decal.scaleX or 1, scaleY = decal.scaleY or 1, rotation = decal.rotation or 0
        })
    end
    for _, decal in ipairs(roomData.decalsBg or {}) do
        pcg.addDecal(room, "bg", decal.texture or "", (decal.x or 0) + ox, (decal.y or 0) + oy, {
            scaleX = decal.scaleX or 1, scaleY = decal.scaleY or 1, rotation = decal.rotation or 0
        })
    end

    room.music = roomData.music or ""
    room.ambience = roomData.ambience or ""
    room.color = roomData.color or 0
    room.windPattern = roomData.windPattern or "None"
    room.dark = roomData.dark or false
    room.space = roomData.space or false

    return room
end

local function mergeIntoRoom(existingRoom, roomData, ox, oy)
    local merged = 0

    for _, entData in ipairs(roomData.entities or {}) do
        local name = entData.name or entData._name or "unknown"
        local attrs = {}
        attrs.nodes = copyNodesWithOffset(entData.nodes, ox, oy)
        for k, v in pairs(entData) do
            if k ~= "name" and k ~= "_name" and k ~= "x" and k ~= "y" and k ~= "nodes" then
                attrs[k] = v
            end
        end
        pcg.addEntity(existingRoom, name, (entData.x or 0) + ox, (entData.y or 0) + oy, attrs)
        merged = merged + 1
    end

    for _, trigData in ipairs(roomData.triggers or {}) do
        local name = trigData.name or trigData._name or "unknown"
        local attrs = {}
        attrs.nodes = copyNodesWithOffset(trigData.nodes, ox, oy)
        for k, v in pairs(trigData) do
            if k ~= "name" and k ~= "_name" and k ~= "x" and k ~= "y" and k ~= "width" and k ~= "height" and k ~= "nodes" then
                attrs[k] = v
            end
        end
        pcg.addTrigger(existingRoom, name, (trigData.x or 0) + ox, (trigData.y or 0) + oy, trigData.width or 16, trigData.height or 16, attrs)
        merged = merged + 1
    end

    if roomData.tilesFg and #roomData.tilesFg > 0 then
        local wTiles = math.floor((existingRoom.width or 320) / TILE)
        local hTiles = math.floor((existingRoom.height or 184) / TILE)
        existingRoom.tilesFg = deserializeTiles(roomData.tilesFg, wTiles, hTiles)
        merged = merged + 1
    end

    if roomData.tilesBg and #roomData.tilesBg > 0 then
        local wTiles = math.floor((existingRoom.width or 320) / TILE)
        local hTiles = math.floor((existingRoom.height or 184) / TILE)
        existingRoom.tilesBg = deserializeTiles(roomData.tilesBg, wTiles, hTiles)
        merged = merged + 1
    end

    for _, decal in ipairs(roomData.decalsFg or {}) do
        pcg.addDecal(existingRoom, "fg", decal.texture or "", (decal.x or 0) + ox, (decal.y or 0) + oy, {
            scaleX = decal.scaleX or 1, scaleY = decal.scaleY or 1, rotation = decal.rotation or 0
        })
        merged = merged + 1
    end
    for _, decal in ipairs(roomData.decalsBg or {}) do
        pcg.addDecal(existingRoom, "bg", decal.texture or "", (decal.x or 0) + ox, (decal.y or 0) + oy, {
            scaleX = decal.scaleX or 1, scaleY = decal.scaleY or 1, rotation = decal.rotation or 0
        })
        merged = merged + 1
    end

    return merged
end

function PCGImport.run(args)
    args = args or PCGImport.parameters

    local map = state.map
    if not map then
        print("[ERROR] No map loaded! Open a map in Lönn first.")
        return
    end

    local data = loadJSON(args.inputFile)
    if not data then
        print(string.format("[ERROR] Failed to load PCG data from: %s", args.inputFile))
        print("[INFO] Make sure the gamelab PCG AI has generated a map file.")
        print("[INFO] Expected format: { rooms: [ { name, x, y, width, height, entities, triggers, tilesFg, tilesBg } ] }")
        return
    end

    local rooms = data.rooms or data
    if type(rooms) ~= "table" then
        print("[ERROR] Invalid PCG data format: expected 'rooms' array")
        return
    end

    local totalEntities = 0
    local totalTriggers = 0
    local totalRooms = 0
    for _, roomData in ipairs(rooms) do
        totalRooms = totalRooms + 1
        totalEntities = totalEntities + #(roomData.entities or {})
        totalTriggers = totalTriggers + #(roomData.triggers or {})
    end

    print(string.format("\n=== PCGHelper AI MAP IMPORT ==="))
    print(string.format("Source: %s", args.inputFile))
    print(string.format("Mode: %s", args.mode))
    print(string.format("Rooms to import: %d", totalRooms))
    print(string.format("Entities: %d, Triggers: %d", totalEntities, totalTriggers))
    if args.dryRun then
        print("[DRY RUN] No changes will be applied")
    end

    if args.dryRun then
        for _, roomData in ipairs(rooms) do
            local roomName = roomData.name or "unnamed"
            local entCount = #(roomData.entities or {})
            local trigCount = #(roomData.triggers or {})
            print(string.format("  [Room] %s (%dx%d) - %d entities, %d triggers",
                roomName, roomData.width or 320, roomData.height or 184, entCount, trigCount))

            local entityTypes = {}
            for _, ent in ipairs(roomData.entities or {}) do
                local name = ent.name or ent._name or "unknown"
                entityTypes[name] = (entityTypes[name] or 0) + 1
            end
            for name, count in pairs(entityTypes) do
                print(string.format("    - %s x%d", name, count))
            end
        end
        print("\n[DRY RUN COMPLETE] Set dryRun=false to apply changes.")
        return
    end

    local createdRooms = {}
    local function forward()
        if args.mode == "replace" then
            print("[INFO] Replacing all rooms...")
            map.rooms = {}
        end

        if not map.rooms then
            map.rooms = {}
        end

        for _, roomData in ipairs(rooms) do
            if args.targetRoom and args.targetRoom ~= "" then
                local targetFound = false
                for _, existingRoom in ipairs(map.rooms) do
                    if existingRoom.name == args.targetRoom then
                        local merged = mergeIntoRoom(existingRoom, roomData, args.offset_x, args.offset_y)
                        print(string.format("[INFO] Merged %d items into room '%s'", merged, args.targetRoom))
                        targetFound = true
                        break
                    end
                end
                if not targetFound then
                    print(string.format("[WARN] Target room '%s' not found, creating new room", args.targetRoom))
                    local room = importRoom(roomData, args.offset_x, args.offset_y)
                    room.name = args.targetRoom
                    mapItemUtils.addItem(map, room, false)
                    table.insert(createdRooms, room)
                end
            else
                local existingIdx = nil
                for i, existingRoom in ipairs(map.rooms) do
                    if existingRoom.name == (roomData.name or "") then
                        existingIdx = i
                        break
                    end
                end

                if existingIdx and args.mode == "merge" then
                    local merged = mergeIntoRoom(map.rooms[existingIdx], roomData, args.offset_x, args.offset_y)
                    print(string.format("[INFO] Updated room '%s' (+%d items)", roomData.name or "unnamed", merged))
                else
                    local room = importRoom(roomData, args.offset_x, args.offset_y)
                    mapItemUtils.addItem(map, room, false)
                    table.insert(createdRooms, room)
                    print(string.format("[INFO] Created room '%s' (%d entities, %d triggers)",
                        room.name, #(room.entities or {}), #(room.triggers or {})))
                end
            end
        end
    end

    local function backward()
        for i = #createdRooms, 1, -1 do
            mapItemUtils.deleteRoom(map, createdRooms[i])
        end
    end

    forward()

    print(string.format("\n=== IMPORT COMPLETE ==="))
    print(string.format("  New rooms created: %d", #createdRooms))
    print("\n[IMPORTANT] Remember to:")
    print("  1. Save the map (Ctrl+S)")
    print("  2. Review imported content in the editor")
    print("  3. Test in-game before committing")
    print("  4. Use the Lönn undo command if needed")

    return snapshot.create(PCGImport.name, {}, backward, forward)
end

return PCGImport
