-- skeleton.lua - room rectangles and how they connect.
--
-- Lua port of celeskeleton/celeskeleton.py from
-- https://github.com/robilouis/seleCte (MIT), minus the matplotlib plotting.
--
-- A skeleton is the coarse geometry of a level before any tile is sampled:
-- named rooms, each an axis-aligned rectangle on one integer tile grid.
-- `room.origin` is the BOTTOM-left corner {x, y} with y pointing UP (the
-- skeleton's convention, flipped by the encoder), `room.size` is {width,
-- height}, and `room.exits[side]` holds openings as {c1, c2} spans in
-- ABSOLUTE grid coordinates - which is why setOrigin shifts them.
--
-- `room.data` is the (height x width) tile grid, data[row][col], 1-based,
-- row 1 at the TOP. Later stages author its contents; this module draws the
-- borders, punches the exits, and places the spawn and the crystal heart.
--
-- The Python raises ValueError where a random placement cannot work and the
-- generator catches it to retry; here those paths return false instead.

local function req(name)
	local ok, mods = pcall(require, "mods")
	if ok and type(mods) == "table" and mods.requireFromPlugin then
		local m = mods.requireFromPlugin("library.selecte." .. name)
		if not m then
			error("seleCte: could not load library.selecte." .. name .. " (see the Loenn log for the Lua error)")
		end
		return m
	end
	return require("library.selecte." .. name)
end

local alphabet = req("alphabet")

local M = {}

M.SIDES = { "up", "down", "left", "right" }
M.OPPOSITE_SIDE = { up = "down", down = "up", left = "right", right = "left" }

-- Python's int() on a float: truncation toward zero (exit coordinates can be
-- negative, where math.floor would differ).
local function trunc(x)
	if x >= 0 then
		return math.floor(x)
	end
	return math.ceil(x)
end
M.trunc = trunc

-- =========================================================================
-- Room
-- =========================================================================

local Room = {}
Room.__index = Room
M.Room = Room

function Room.new(width, height, originX, originY, status)
	width = width or 1
	height = height or 1
	if width <= 0 or height <= 0 then
		error("Width and height have to be positive!")
	end
	local self = setmetatable({}, Room)
	self.size = { width, height }
	self.origin = { originX or 0, originY or 0 }
	self.exits = { up = {}, down = {}, left = {}, right = {} }
	self.status = status
	self.data = {}
	for r = 1, height do
		local row = {}
		for c = 1, width do
			row[c] = alphabet.VOID
		end
		self.data[r] = row
	end
	return self
end

function Room:width()
	return self.size[1]
end

function Room:height()
	return self.size[2]
end

function Room:getTrCorner()
	return { self.origin[1] + self.size[1], self.origin[2] + self.size[2] }
end

-- {x0, y0, x1, y1}: bottom-left and top-right corners.
function Room:getCorners()
	local tr = self:getTrCorner()
	return { self.origin[1], self.origin[2], tr[1], tr[2] }
end

function Room:clearExits()
	self.exits = { up = {}, down = {}, left = {}, right = {} }
end

function Room:setStatus(status)
	if status == "start" or status == "end" then
		self.status = status
	else
		error("Room can only have start or end status, or None.")
	end
end

function Room:setSize(width, height)
	for side, list in pairs(self.exits) do
		if #list > 0 then
			error("At least one exit detected " .. side .. ", clear exits before changing the size.")
		end
	end
	if width <= 0 or height <= 0 then
		error("Width and height have to be positive!")
	end
	self.size = { width, height }
end

-- Moves the room; exits are absolute, so they move along.
function Room:setOrigin(x, y)
	local dx, dy = x - self.origin[1], y - self.origin[2]
	self.origin = { x, y }
	for _, exit in ipairs(self.exits.up) do
		exit[1], exit[2] = exit[1] + dx, exit[2] + dx
	end
	for _, exit in ipairs(self.exits.down) do
		exit[1], exit[2] = exit[1] + dx, exit[2] + dx
	end
	for _, exit in ipairs(self.exits.left) do
		exit[1], exit[2] = exit[1] + dy, exit[2] + dy
	end
	for _, exit in ipairs(self.exits.right) do
		exit[1], exit[2] = exit[1] + dy, exit[2] + dy
	end
end

function Room:setExits(exits)
	self.exits = {
		up = exits.up or {}, down = exits.down or {},
		left = exits.left or {}, right = exits.right or {},
	}
end

-- Deep copy of the exits, for handing a skeleton's exits to a fresh room.
function Room:copyExits()
	local out = {}
	for _, side in ipairs(M.SIDES) do
		out[side] = {}
		for i, exit in ipairs(self.exits[side]) do
			out[side][i] = { exit[1], exit[2] }
		end
	end
	return out
end

function Room:setData(data)
	local h = #data
	local w = h > 0 and #data[1] or 0
	if h ~= self.size[2] or w ~= self.size[1] then
		error(string.format("Can't assign data of shape (%d, %d) to a room of shape (%d, %d)!",
			h, w, self.size[2], self.size[1]))
	end
	self.data = data
end

-- add_exit: returns false (instead of raising) when the span is out of bounds.
function Room:addExit(side, c1, c2)
	if c1 >= c2 then
		return false
	end
	if not self.exits[side] then
		return false
	end
	if side == "up" or side == "down" then
		if c1 >= self.origin[1] + 1 and c2 <= self.origin[1] + self.size[1] - 1 then
			table.insert(self.exits[side], { c1, c2 })
			return true
		end
	else
		if c1 >= self.origin[2] + 1 and c2 <= self.origin[2] + self.size[2] - 1 then
			table.insert(self.exits[side], { c1, c2 })
			return true
		end
	end
	return false
end

-- generate_exit: a random exit of `size` on `side`.
function Room:generateExit(side, size, rng)
	local c
	if side == "up" or side == "down" then
		c = rng:range(self.origin[1] + 1, self.origin[1] + self.size[1] - size)
	else
		c = rng:range(self.origin[2] + 1, self.origin[2] + self.size[2] - size)
	end
	if not c then
		return false
	end
	return self:addExit(side, c, c + size)
end

-- exits_to_list: every exit as an absolute {x0, y0, x1, y1} segment.
function Room:exitsToList()
	local out = {}
	local base = self:getCorners()
	local x0, y0, x1, y1 = base[1], base[2], base[3], base[4]
	for _, exit in ipairs(self.exits.left) do
		out[#out + 1] = { x0, exit[1], x0, exit[2] }
	end
	for _, exit in ipairs(self.exits.down) do
		out[#out + 1] = { exit[1], y0, exit[2], y0 }
	end
	for _, exit in ipairs(self.exits.right) do
		out[#out + 1] = { x1, exit[1], x1, exit[2] }
	end
	for _, exit in ipairs(self.exits.up) do
		out[#out + 1] = { exit[1], y1, exit[2], y1 }
	end
	return out
end

function Room:isOverlapping(room)
	local a, b = self:getCorners(), room:getCorners()
	return not (a[1] >= b[3] or a[3] <= b[1] or a[4] <= b[2] or a[2] >= b[4])
end

-- faces: whether `room` sits flush against this one on `side` (adjacency
-- only, exits not considered).
function Room:faces(room, side)
	local x0, y0 = self.origin[1], self.origin[2]
	local tr = self:getTrCorner()
	local x1, y1 = tr[1], tr[2]
	local rx0, ry0 = room.origin[1], room.origin[2]
	local rtr = room:getTrCorner()
	local rx1, ry1 = rtr[1], rtr[2]
	if side == "up" then
		return y1 == ry0
	elseif side == "down" then
		return y0 == ry1
	elseif side == "left" then
		return x0 == rx1
	elseif side == "right" then
		return x1 == rx0
	end
	error("Select a side among up/down/left/right")
end

-- is_connected_to: flush against each other AND holding the same exit span
-- on the two facing sides - exactly what `connect` writes.
function Room:isConnectedTo(room)
	for side, opposite in pairs(M.OPPOSITE_SIDE) do
		if self:faces(room, side) then
			for _, mine in ipairs(self.exits[side]) do
				for _, theirs in ipairs(room.exits[opposite]) do
					if mine[1] == theirs[1] and mine[2] == theirs[2] then
						return true
					end
				end
			end
		end
	end
	return false
end

-- connect: moves self flush against `room` on `side` and opens a shared exit.
-- Returns false where the Python raised ValueError (a randint with an empty
-- range, or an exit that does not fit); the caller retries with a new draw.
-- When the moved room overlaps the skeleton no exit is opened, and the
-- caller's overlap check rejects the placement.
function Room:connect(room, side, skeleton, rng)
	local x0, y0 = room.origin[1], room.origin[2]
	local rw, rh = room.size[1], room.size[2]
	local w, h = self.size[1], self.size[2]

	if side == "up" or side == "down" then
		local x = rng:range(x0 + 3 - w, x0 + rw - 2)
		if not x then
			return false
		end
		self:setOrigin(x, side == "up" and (y0 + rh) or (y0 - h))
		if skeleton:isOverlappingWith(self) then
			return true
		end
		local xb = self.origin[1]
		local rangeMin = math.max(x0, xb)
		local rangeMax = math.min(x0 + rw, xb + w)
		local size = rng:range(2, rangeMax - rangeMin - 1)
		if not size then
			return false
		end
		local c = rng:range(rangeMin + 1, rangeMax - size - 1)
		if not c then
			return false
		end
		if side == "up" then
			return self:addExit("down", c, c + size) and room:addExit("up", c, c + size)
		end
		return self:addExit("up", c, c + size) and room:addExit("down", c, c + size)

	elseif side == "right" or side == "left" then
		local y = rng:range(y0 + 3 - h, y0 + rh - 2)
		if not y then
			return false
		end
		self:setOrigin(side == "right" and (x0 + rw) or (x0 - w), y)
		if skeleton:isOverlappingWith(self) then
			return true
		end
		local yb = self.origin[2]
		local rangeMin = math.max(y0, yb)
		local rangeMax = math.min(y0 + rh, yb + h)
		local size = rng:range(2, rangeMax - rangeMin - 1)
		if not size then
			return false
		end
		local c = rng:range(rangeMin + 1, rangeMax - size - 1)
		if not c then
			return false
		end
		if side == "right" then
			return self:addExit("left", c, c + size) and room:addExit("right", c, c + size)
		end
		return self:addExit("right", c, c + size) and room:addExit("left", c, c + size)
	end
	error("Selected side incorrect")
end

-- Absolute skeleton y -> 1-based row into data. Row 1 is the TOP edge while
-- the skeleton's y points UP from `origin`, so this flips; the result
-- depends on y alone, which is what makes a shared opening land at the same
-- height in both rooms.
function Room:localRow(yAbs)
	return (self.size[2] - 1) - (yAbs - self.origin[2]) + 1
end

-- Absolute skeleton x -> 1-based column into data (no flip).
function Room:localCol(xAbs)
	return xAbs - self.origin[1] + 1
end

-- get_starting_ending_points: one {row, col} per exit, on the border it
-- opens through.
function Room:getStartingEndingPoints()
	local points = {}
	local h, w = self.size[2], self.size[1]
	for _, exit in ipairs(self.exits.up) do
		points[#points + 1] = { 1, self:localCol(trunc((exit[1] + exit[2]) / 2)) }
	end
	for _, exit in ipairs(self.exits.down) do
		points[#points + 1] = { h, self:localCol(trunc((exit[1] + exit[2]) / 2)) }
	end
	for _, exit in ipairs(self.exits.left) do
		points[#points + 1] = { self:localRow(trunc((exit[1] + exit[2]) / 2)), 1 }
	end
	for _, exit in ipairs(self.exits.right) do
		points[#points + 1] = { self:localRow(trunc((exit[1] + exit[2]) / 2)), w }
	end
	return points
end

-- extract_astar_ready_data: 0 where Madeline can pass, 1 otherwise.
function Room:extractAstarReadyData()
	local out = {}
	for r = 1, self.size[2] do
		local row, src = {}, self.data[r]
		for c = 1, self.size[1] do
			local v = src[c]
			if v == alphabet.VOID or alphabet.ASTAR_PASSABLE[v] then
				row[c] = 0
			else
				row[c] = 1
			end
		end
		out[r] = row
	end
	return out
end

-- create_exits_in_matrix: writes void along the border for every exit. On
-- the vertical axis the local conversion flips the span, so c1 (the lower
-- edge) is the HIGHER row index.
function Room:createExitsInMatrix()
	local h, w = self.size[2], self.size[1]
	for _, side in ipairs({ "left", "right", "up", "down" }) do
		for _, exit in ipairs(self.exits[side]) do
			local c1, c2 = exit[1], exit[2]
			if side == "left" or side == "right" then
				local rowLo, rowHi = self:localRow(c2), self:localRow(c1)
				local col = (side == "left") and 1 or w
				for r = math.max(1, rowLo), math.min(h, rowHi) do
					self.data[r][col] = alphabet.VOID
				end
			else
				local colLo, colHi = self:localCol(c1), self:localCol(c2)
				local row = (side == "up") and 1 or h
				for c = math.max(1, colLo), math.min(w, colHi) do
					self.data[row][c] = alphabet.VOID
				end
			end
		end
	end
end

local function inBounds(self, r, c)
	return r >= 1 and r <= self.size[2] and c >= 1 and c <= self.size[1]
end

-- add_respawn_points: a player entity just inside each opening, on a short
-- dream-block ledge, with a pocket of void cleared around it.
--
-- Deliberate deviation from the Python: there the ledge is written BEFORE the
-- clearing loop, which then overwrites the whole row below the spawn with
-- void, so no ledge ever survived. The pocket is cleared first here, then the
-- spawn and its ledge are written, which is what the code was clearly meant
-- to produce.
function Room:addRespawnPoints(clearSpaceSize)
	clearSpaceSize = clearSpaceSize or 2
	local h, w = self.size[2], self.size[1]
	for _, side in ipairs(M.SIDES) do
		for _, exit in ipairs(self.exits[side]) do
			local mid = trunc((exit[1] + exit[2]) / 2)
			local row, col
			if side == "up" then
				row, col = 3, self:localCol(mid)
			elseif side == "down" then
				row, col = h - 2, self:localCol(mid)
			elseif side == "left" then
				row, col = self:localRow(mid), 3
			else
				row, col = self:localRow(mid), w - 2
			end

			for a = -clearSpaceSize + 1, clearSpaceSize - 1 do
				for b = -clearSpaceSize + 1, clearSpaceSize - 1 do
					if not (a == 0 and b == 0) and inBounds(self, row + a, col + b) then
						self.data[row + a][col + b] = alphabet.VOID
					end
				end
			end
			if inBounds(self, row, col) then
				self.data[row][col] = alphabet.PLAYER
			end
			for b = -1, 1 do
				if inBounds(self, row + 1, col + b) then
					self.data[row + 1][col + b] = "D"
				end
			end
		end
	end
end

-- add_special_points: the player spawn (start room) or the crystal heart
-- (end room) at a random point that can reach every exit. Returns whether a
-- valid point was found within `nbTriesLimit` tries, and records it as
-- `room.specialPoint`. Other rooms: true.
function Room:addSpecialPoints(nbTriesLimit, rng, playability, log)
	if not self.status then
		return true
	end
	local h, w = self.size[2], self.size[1]
	local valid, tries = false, 0
	local sp
	while not valid and tries < nbTriesLimit do
		tries = tries + 1
		-- np.random.randint([h - 4, w - 3]) + [3, 1], then +1 for 1-based
		local r = rng:range(0, h - 4)
		local c = rng:range(0, w - 3)
		if not r or not c then
			break
		end
		sp = { r + 3 + 1, c + 1 + 1 }
		valid = playability.isValidSpecial(self, sp, 0, rng)
	end

	if not valid then
		if log then
			log(string.format("No success in %d iterations - re-generating room.", nbTriesLimit))
		end
		return false
	end

	self.specialPoint = { sp[1], sp[2] }
	if self.status == "end" then
		self.data[sp[1]][sp[2]] = alphabet.HEART
	elseif self.status == "start" then
		for b = -1, 1 do
			if inBounds(self, sp[1], sp[2] + b) then
				self.data[sp[1]][sp[2] + b] = "D"
			end
		end
		if inBounds(self, sp[1] - 1, sp[2]) then
			self.data[sp[1] - 1][sp[2]] = alphabet.PLAYER
		end
	else
		error("Status should be either nil, 'start' or 'end'!")
	end
	return true
end

-- =========================================================================
-- Celeskeleton
-- =========================================================================

local Skeleton = {}
Skeleton.__index = Skeleton
M.Skeleton = Skeleton

function Skeleton.new()
	local self = setmetatable({}, Skeleton)
	self.lvl = {}     -- name -> Room
	self.names = {}   -- insertion order (Python dicts are ordered)
	self.startingRoom = nil
	self.endingRoom = nil
	return self
end

function Skeleton:listAllRooms()
	local out = {}
	for i, n in ipairs(self.names) do
		out[i] = n
	end
	return out
end

function Skeleton:getNbRooms()
	return #self.names
end

local function roomsWithStatus(self, status)
	local out = {}
	for _, name in ipairs(self.names) do
		if self.lvl[name].status == status then
			out[#out + 1] = name
		end
	end
	return out
end

function Skeleton:getStartingRoom()
	local c = roomsWithStatus(self, "start")
	if #c > 1 then
		error("Multiple starting rooms have been found: " .. table.concat(c, ", "))
	elseif #c == 0 then
		error("No starting room have been found.")
	end
	return c[1]
end

function Skeleton:getEndingRoom()
	local c = roomsWithStatus(self, "end")
	if #c > 1 then
		error("Multiple ending rooms have been found: " .. table.concat(c, ", "))
	elseif #c == 0 then
		error("No ending room have been found.")
	end
	return c[1]
end

function Skeleton:addRoom(room, name)
	if self.lvl[name] then
		error("Room " .. name .. " already exists! Please use another name.")
	end
	self.lvl[name] = room
	self.names[#self.names + 1] = name
end

function Skeleton:removeRoom(name)
	if not self.lvl[name] then
		error("Room " .. name .. " does not exists!")
	end
	self.lvl[name] = nil
	for i, n in ipairs(self.names) do
		if n == name then
			table.remove(self.names, i)
			break
		end
	end
end

function Skeleton:globalOverlapping()
	local out = {}
	for i = 1, #self.names - 1 do
		for j = i + 1, #self.names do
			if self.lvl[self.names[i]]:isOverlapping(self.lvl[self.names[j]]) then
				out[#out + 1] = { self.names[i], self.names[j] }
			end
		end
	end
	return out
end

function Skeleton:isOverlappingWith(room)
	for _, name in ipairs(self.names) do
		if room:isOverlapping(self.lvl[name]) then
			return true
		end
	end
	return false
end

function Skeleton:getRoomByName(name)
	local room = self.lvl[name]
	if not room then
		error("No room named " .. tostring(name))
	end
	return room
end

-- select_last_room: with probability p a random room, else `roomName`.
function Skeleton:selectLastRoom(roomName, p, rng)
	local name = roomName
	if rng:random() < p then
		name = rng:choice(self.names)
	end
	return self:getRoomByName(name)
end

function Skeleton:setStartEnd()
	self.startingRoom = self.names[1]
	self.endingRoom = self.names[#self.names]
	self:getRoomByName(self.startingRoom):setStatus("start")
	self:getRoomByName(self.endingRoom):setStatus("end")
end

function Skeleton:getSpecialRooms()
	local special = {}
	if self.startingRoom and self.lvl[self.startingRoom] then
		special[self.startingRoom] = "start"
	end
	if self.endingRoom and self.lvl[self.endingRoom] then
		special[self.endingRoom] = "end"
	end
	for _, name in ipairs(self.names) do
		local status = self.lvl[name].status
		if status then
			special[name] = status
		end
	end
	return special
end

-- get_room_graph: name -> set of names it shares an opening with. A tree for
-- generated skeletons (n rooms, n-1 connections), but read off the exits so
-- any skeleton is described faithfully.
function Skeleton:getRoomGraph()
	local graph = {}
	for _, name in ipairs(self.names) do
		graph[name] = {}
	end
	for i = 1, #self.names - 1 do
		for j = i + 1, #self.names do
			local a, b = self.names[i], self.names[j]
			if self.lvl[a]:isConnectedTo(self.lvl[b]) then
				graph[a][b] = true
				graph[b][a] = true
			end
		end
	end
	return graph
end

-- get_traversal_path: the rooms a run must cross, start to end (BFS, with
-- neighbours visited in sorted order for determinism). Errors when nothing
-- connects the two.
function Skeleton:getTraversalPath()
	local start, finish = self:getStartingRoom(), self:getEndingRoom()
	local graph = self:getRoomGraph()
	local cameFrom = { [start] = false }
	local queue, head = { start }, 1
	while head <= #queue do
		local current = queue[head]
		head = head + 1
		if current == finish then
			local path = {}
			local node = current
			while node do
				table.insert(path, 1, node)
				node = cameFrom[node]
			end
			return path
		end
		local neighbours = {}
		for n in pairs(graph[current]) do
			neighbours[#neighbours + 1] = n
		end
		table.sort(neighbours)
		for _, n in ipairs(neighbours) do
			if cameFrom[n] == nil then
				cameFrom[n] = current
				queue[#queue + 1] = n
			end
		end
	end
	error(string.format("No path connects %s to %s: the skeleton is not traversable.", start, finish))
end

-- format_filled_celeskeleton: full solid borders on every room, exits re-carved.
function Skeleton:formatFilled()
	for _, name in ipairs(self.names) do
		local room = self.lvl[name]
		local h, w = room.size[2], room.size[1]
		for c = 1, w do
			room.data[1][c] = alphabet.SOLID
			room.data[h][c] = alphabet.SOLID
		end
		for r = 1, h do
			room.data[r][1] = alphabet.SOLID
			room.data[r][w] = alphabet.SOLID
		end
		room:createExitsInMatrix()
	end
end

-- extract_rooms_metadata: {size, origin, exits} per room, in order.
function Skeleton:extractRoomsMetadata()
	local out = {}
	for _, name in ipairs(self.names) do
		local room = self.lvl[name]
		out[#out + 1] = { size = room.size, origin = room.origin, exits = room.exits, name = name }
	end
	return out
end

-- The data.json payload Celeskeleton.save writes: name -> {origin, size, exits}.
function Skeleton:toJsonTable()
	local out = {}
	for _, name in ipairs(self.names) do
		local room = self.lvl[name]
		out[name] = {
			origin = { room.origin[1], room.origin[2] },
			size = { room.size[1], room.size[2] },
			exits = room:copyExits(),
		}
	end
	return out
end

-- =========================================================================
-- generate_celeskeleton
-- =========================================================================

-- Grows a level as a tree: each new room attaches to the previous one, or
-- with probability p to a random existing room (p = 0 corridor, p -> 1
-- labyrinth). roomSize {w, h} fixes every room's size; without it sizes are
-- drawn in [10, 100] like the original. `maxAttempts` bounds the placement
-- loop per room (the Python loops until it succeeds).
function M.generateCeleskeleton(nbRooms, p, roomSize, rng, maxAttempts)
	p = p or 0.5
	maxAttempts = maxAttempts or 1000
	local skeleton = Skeleton.new()

	local function newRoom()
		if roomSize then
			return Room.new(roomSize[1], roomSize[2])
		end
		return Room.new(rng:int(10, 100), rng:int(10, 100))
	end

	local k = 1
	local roomName = "room_" .. k
	skeleton:addRoom(newRoom(), roomName)

	while skeleton:getNbRooms() < nbRooms do
		k = k + 1
		local placed = false
		for _ = 1, maxAttempts do
			local lastRoom = skeleton:selectLastRoom(roomName, p, rng)
			local side = rng:choice(M.SIDES)
			local room = newRoom()
			if room:connect(lastRoom, side, skeleton, rng) and not skeleton:isOverlappingWith(room) then
				roomName = "room_" .. k
				skeleton:addRoom(room, roomName)
				placed = true
				break
			end
		end
		if not placed then
			error(string.format("Could not place room %d after %d attempts.", k, maxAttempts))
		end
	end

	skeleton:setStartEnd()
	return skeleton
end

-- json_to_skeleton: rebuilds a skeleton from a data.json-shaped table.
function M.fromJsonTable(data, order)
	local skeleton = Skeleton.new()
	local names = order
	if not names then
		names = {}
		for name in pairs(data) do
			names[#names + 1] = name
		end
		table.sort(names, function(a, b)
			local na, nb = tonumber(a:match("(%d+)$")), tonumber(b:match("(%d+)$"))
			if na and nb then
				return na < nb
			end
			return a < b
		end)
	end
	for _, name in ipairs(names) do
		local entry = data[name]
		local room = Room.new(entry.size[1], entry.size[2], entry.origin[1], entry.origin[2])
		room:setExits(entry.exits or {})
		skeleton:addRoom(room, name)
	end
	skeleton:setStartEnd()
	return skeleton
end

return M
