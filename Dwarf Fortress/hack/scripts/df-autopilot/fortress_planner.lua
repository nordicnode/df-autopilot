-- df-autopilot/fortress_planner.lua
-- Intelligent procedural fortress layout generation
-- Uses BSP (Binary Space Partitioning) and graph-based connectivity

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")
local terrain = reqscript("df-autopilot/terrain")
local pf = reqscript("df-autopilot/pathfinding")

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local PLANNER_NAME = "planner"

-- Room type definitions with sizes and priorities
local json = require("json")

-- Room type definitions
-- Loaded from config/room_layouts.json with hardcoded fallback
local ROOM_TYPES = {}

local function load_room_config()
    local config_path = "df-autopilot/config/room_layouts.json"
    
    -- Try to load from file
    local file = io.open(dfhack.getHackPath() .. "/scripts/" .. config_path, "r")
    if not file then
        -- Try relative path if not absolute
        file = io.open(config_path, "r")
    end
    
    if file then
        local content = file:read("*all")
        file:close()
        local ok, data = pcall(json.decode, content)
        if ok and data then
            ROOM_TYPES = data
            utils.log("Loaded room layouts from " .. config_path, PLANNER_NAME)
            return
        else
            utils.log_error("Failed to parse room layouts config: " .. tostring(data), PLANNER_NAME)
        end
    else
        utils.log_warn("Room layouts config not found at " .. config_path, PLANNER_NAME)
    end
    
    -- Fallback defaults if load failed
    ROOM_TYPES = {
        ENTRANCE = { id="entrance", name="Entrance", min_w=3, min_h=3, max_w=5, max_h=5, priority=1, count=1, z_pref="entry" },
        WORKSHOP_HALL = { id="workshop_hall", name="Workshop Hall", min_w=7, min_h=7, max_w=15, max_h=15, priority=1, count=1, z_pref="entry" },
        STORAGE_MAIN = { id="storage_main", name="Main Storage", min_w=6, min_h=6, max_w=12, max_h=12, priority=1, count=1, z_pref="storage" },
        DINING = { id="dining", name="Dining Hall", min_w=5, min_h=5, max_w=9, max_h=9, priority=2, count=1, z_pref="common" },
        DORMITORY = { id="dormitory", name="Dormitory", min_w=4, min_h=4, max_w=7, max_h=7, priority=2, per_pop=10, z_pref="living" },
        BEDROOM = { id="bedroom", name="Bedroom", min_w=2, min_h=2, max_w=3, max_h=3, priority=3, per_pop=1, z_pref="living" },
        HOSPITAL = { id="hospital", name="Hospital", min_w=4, min_h=4, max_w=6, max_h=6, priority=2, count=1, z_pref="common" },
        TAVERN = { id="tavern", name="Tavern", min_w=5, min_h=5, max_w=8, max_h=8, priority=3, count=1, z_pref="common" },
        TEMPLE = { id="temple", name="Temple", min_w=4, min_h=4, max_w=7, max_h=7, priority=3, count=1, z_pref="common" },
        LIBRARY = { id="library", name="Library", min_w=3, min_h=3, max_w=5, max_h=5, priority=4, count=1, z_pref="common" },
        BARRACKS = { id="barracks", name="Barracks", min_w=5, min_h=5, max_w=8, max_h=8, priority=3, per_military=10, z_pref="military" },
        TRAINING = { id="training", name="Training Room", min_w=5, min_h=5, max_w=10, max_h=10, priority=3, count=1, z_pref="military" },
        FARM = { id="farm", name="Farm Plot Area", min_w=4, min_h=4, max_w=6, max_h=6, priority=2, count=2, z_pref="entry", needs_soil=true },
        CISTERN = { id="cistern", name="Cistern", min_w=3, min_h=3, max_w=5, max_h=5, priority=4, count=1, z_pref="deep" },
        FORGE_AREA = { id="forge_area", name="Forge Area", min_w=6, min_h=6, max_w=10, max_h=10, priority=3, count=1, z_pref="entry" },
        JAIL = { id="jail", name="Jail", min_w=3, min_h=3, max_w=5, max_h=5, priority=4, count=1, z_pref="common" },
        TOMB = { id="tomb", name="Tomb", min_w=5, min_h=5, max_w=10, max_h=10, priority=4, count=1, z_pref="deep" },
        TRADE_DEPOT = { id="trade_depot", name="Trade Depot Area", min_w=5, min_h=5, max_w=7, max_h=7, priority=2, count=1, z_pref="entry" },
        PASTURE = { id="pasture", name="Pasture", min_w=6, min_h=6, max_w=12, max_h=12, priority=3, count=1, z_pref="entry", surface_only=true },
        CORRIDOR = { id="corridor", name="Corridor", min_w=1, min_h=1, max_w=1, max_h=50, priority=0, count=-1, z_pref="any" },
        STAIRWELL = { id="stairwell", name="Stairwell", min_w=1, min_h=1, max_w=3, max_h=3, priority=0, count=-1, z_pref="any" }
    }
end

-- Initialize room types on module load
load_room_config()


-- Z-level organization (functional separation)
local Z_LEVELS = {
    entry = 0,      -- Surface access, workshops
    storage = -1,   -- Main stockpiles
    common = -2,    -- Dining, hospital, tavern, temple
    living = -3,    -- Bedrooms (expands downward)
    military = -4,  -- Barracks, training
    deep = -5,      -- Cistern, future magma access
}

-------------------------------------------------------------------------------
-- Room Class (supports rectangular, L-shaped, and T-shaped rooms)
-------------------------------------------------------------------------------

local Room = {}
Room.__index = Room

function Room.new(id, room_type, x, y, z, width, height)
    local self = setmetatable({}, Room)
    self.id = id
    self.room_type = room_type
    self.x = x
    self.y = y
    self.z = z
    self.width = width
    self.height = height
    self.shape = "rect"  -- rect, L, T
    self.shape_variant = nil  -- For L: "NE", "NW", "SE", "SW"; For T: "N", "S", "E", "W"
    self.connected_to = {}
    self.dig_complete = false
    self.zone_created = false
    self.furniture_placed = false
    self.extensions = {}  -- Additional rectangular areas for L/T shapes
    return self
end

function Room:set_shape(shape_type, variant)
    self.shape = shape_type
    self.shape_variant = variant
    self.extensions = {}
    
    if shape_type == "L" then
        -- L-shape: main rectangle + extension
        -- variant: "NE", "NW", "SE", "SW" indicates where the extension goes
        local ext_w = math.floor(self.width / 2)
        local ext_h = math.floor(self.height / 2)
        
        if variant == "NE" then
            table.insert(self.extensions, {
                x = self.x + self.width,
                y = self.y,
                w = ext_w,
                h = ext_h
            })
        elseif variant == "NW" then
            table.insert(self.extensions, {
                x = self.x - ext_w,
                y = self.y,
                w = ext_w,
                h = ext_h
            })
        elseif variant == "SE" then
            table.insert(self.extensions, {
                x = self.x + self.width,
                y = self.y + self.height - ext_h,
                w = ext_w,
                h = ext_h
            })
        elseif variant == "SW" then
            table.insert(self.extensions, {
                x = self.x - ext_w,
                y = self.y + self.height - ext_h,
                w = ext_w,
                h = ext_h
            })
        end
    elseif shape_type == "T" then
        -- T-shape: main rectangle + extension perpendicular
        local ext_w = math.floor(self.width / 2)
        local ext_h = math.floor(self.height / 2)
        
        if variant == "N" then
            -- Extension goes north from center top
            table.insert(self.extensions, {
                x = self.x + math.floor(self.width / 2) - math.floor(ext_w / 2),
                y = self.y - ext_h,
                w = ext_w,
                h = ext_h
            })
        elseif variant == "S" then
            table.insert(self.extensions, {
                x = self.x + math.floor(self.width / 2) - math.floor(ext_w / 2),
                y = self.y + self.height,
                w = ext_w,
                h = ext_h
            })
        elseif variant == "E" then
            table.insert(self.extensions, {
                x = self.x + self.width,
                y = self.y + math.floor(self.height / 2) - math.floor(ext_h / 2),
                w = ext_w,
                h = ext_h
            })
        elseif variant == "W" then
            table.insert(self.extensions, {
                x = self.x - ext_w,
                y = self.y + math.floor(self.height / 2) - math.floor(ext_h / 2),
                w = ext_w,
                h = ext_h
            })
        end
    end
end

function Room:get_center()
    return self.x + math.floor(self.width / 2),
           self.y + math.floor(self.height / 2)
end

function Room:get_tiles()
    local tiles = {}
    local seen = {}  -- Avoid duplicate tiles
    
    local function add_tile(x, y)
        local key = x .. "," .. y
        if not seen[key] then
            seen[key] = true
            table.insert(tiles, {x = x, y = y, z = self.z})
        end
    end
    
    -- Main rectangle
    for dx = 0, self.width - 1 do
        for dy = 0, self.height - 1 do
            add_tile(self.x + dx, self.y + dy)
        end
    end
    
    -- Extensions (for L and T shapes)
    for _, ext in ipairs(self.extensions) do
        for dx = 0, ext.w - 1 do
            for dy = 0, ext.h - 1 do
                add_tile(ext.x + dx, ext.y + dy)
            end
        end
    end
    
    return tiles
end

function Room:connect_to(other_room)
    if not self.connected_to[other_room.id] then
        self.connected_to[other_room.id] = true
        other_room.connected_to[self.id] = true
    end
end

function Room:get_area()
    local area = self.width * self.height
    for _, ext in ipairs(self.extensions) do
        area = area + ext.w * ext.h
    end
    return area
end

-------------------------------------------------------------------------------
-- BSP Tree Node
-------------------------------------------------------------------------------

local BSPNode = {}
BSPNode.__index = BSPNode

function BSPNode.new(x, y, width, height)
    local self = setmetatable({}, BSPNode)
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.left = nil
    self.right = nil
    self.room = nil
    return self
end

function BSPNode:is_leaf()
    return self.left == nil and self.right == nil
end

function BSPNode:split(min_size)
    if self.left or self.right then
        return false  -- Already split
    end
    
    -- Determine split direction
    local split_h = true
    if self.width > self.height and self.width / self.height >= 1.25 then
        split_h = false
    elseif self.height > self.width and self.height / self.width >= 1.25 then
        split_h = true
    else
        split_h = math.random() > 0.5
    end
    
    local max_size = (split_h and self.height or self.width) - min_size
    if max_size <= min_size then
        return false  -- Too small to split
    end
    
    -- Random split point
    local split = math.random(min_size, max_size)
    
    if split_h then
        self.left = BSPNode.new(self.x, self.y, self.width, split)
        self.right = BSPNode.new(self.x, self.y + split, self.width, self.height - split)
    else
        self.left = BSPNode.new(self.x, self.y, split, self.height)
        self.right = BSPNode.new(self.x + split, self.y, self.width - split, self.height)
    end
    
    return true
end

function BSPNode:get_leaves()
    if self:is_leaf() then
        return {self}
    end
    
    local leaves = {}
    if self.left then
        for _, leaf in ipairs(self.left:get_leaves()) do
            table.insert(leaves, leaf)
        end
    end
    if self.right then
        for _, leaf in ipairs(self.right:get_leaves()) do
            table.insert(leaves, leaf)
        end
    end
    return leaves
end

-------------------------------------------------------------------------------
-- Fortress Graph
-------------------------------------------------------------------------------

local FortressGraph = {}
FortressGraph.__index = FortressGraph

function FortressGraph.new()
    local self = setmetatable({}, FortressGraph)
    self.rooms = {}
    self.corridors = {}
    self.stairwells = {}
    self.next_room_id = 1
    self.z_levels = {}  -- Track which z-levels are in use
    return self
end

function FortressGraph:add_room(room)
    self.rooms[room.id] = room
    
    -- Track z-level
    if not self.z_levels[room.z] then
        self.z_levels[room.z] = {}
    end
    table.insert(self.z_levels[room.z], room)
    
    return room
end

function FortressGraph:get_next_id()
    local id = self.next_room_id
    self.next_room_id = self.next_room_id + 1
    return "room_" .. id
end

function FortressGraph:get_rooms_by_type(room_type_id)
    local result = {}
    for _, room in pairs(self.rooms) do
        if room.room_type.id == room_type_id then
            table.insert(result, room)
        end
    end
    return result
end

function FortressGraph:count_rooms_by_type(room_type_id)
    return #self:get_rooms_by_type(room_type_id)
end

function FortressGraph:get_rooms_on_level(z)
    return self.z_levels[z] or {}
end

-------------------------------------------------------------------------------
-- Corridor Generation
-------------------------------------------------------------------------------

local function create_corridor_tiles(x1, y1, x2, y2, z)
    local tiles = {}
    
    -- L-shaped corridor (horizontal first, then vertical)
    -- Or randomly choose vertical first
    local h_first = math.random() > 0.5
    
    if h_first then
        -- Horizontal segment
        local start_x = math.min(x1, x2)
        local end_x = math.max(x1, x2)
        for x = start_x, end_x do
            table.insert(tiles, {x = x, y = y1, z = z})
        end
        
        -- Vertical segment
        local start_y = math.min(y1, y2)
        local end_y = math.max(y1, y2)
        for y = start_y, end_y do
            table.insert(tiles, {x = x2, y = y, z = z})
        end
    else
        -- Vertical segment first
        local start_y = math.min(y1, y2)
        local end_y = math.max(y1, y2)
        for y = start_y, end_y do
            table.insert(tiles, {x = x1, y = y, z = z})
        end
        
        -- Horizontal segment
        local start_x = math.min(x1, x2)
        local end_x = math.max(x1, x2)
        for x = start_x, end_x do
            table.insert(tiles, {x = x, y = y2, z = z})
        end
    end
    
    return tiles
end

local function create_stairwell_tiles(x, y, z1, z2)
    local tiles = {}
    local min_z = math.min(z1, z2)
    local max_z = math.max(z1, z2)
    
    for z = min_z, max_z do
        local dig_type = "updown"
        if z == max_z then
            dig_type = "down"
        elseif z == min_z then
            dig_type = "up"
        end
        table.insert(tiles, {x = x, y = y, z = z, stair_type = dig_type})
    end
    
    return tiles
end

-------------------------------------------------------------------------------
-- Needs Calculator
-------------------------------------------------------------------------------

local function calculate_fortress_needs(population, military_count, current_graph)
    local needs = {}
    
    for type_id, type_def in pairs(ROOM_TYPES) do
        local current_count = current_graph:count_rooms_by_type(type_def.id)
        local needed = 0
        
        if type_def.count then
            if type_def.count > 0 then
                needed = math.max(0, type_def.count - current_count)
            end
        elseif type_def.per_pop then
            local target = math.ceil(population / type_def.per_pop)
            needed = math.max(0, target - current_count)
        elseif type_def.per_military then
            local target = math.ceil(military_count / type_def.per_military)
            needed = math.max(0, target - current_count)
        end
        
        if needed > 0 then
            table.insert(needs, {
                type_id = type_id,
                type_def = type_def,
                count = needed,
                priority = type_def.priority
            })
        end
    end
    
    -- Sort by priority
    table.sort(needs, function(a, b) return a.priority < b.priority end)
    
    return needs
end

-------------------------------------------------------------------------------
-- BSP-based Layout Generation
-------------------------------------------------------------------------------

local function generate_level_layout(center_x, center_y, z, width, height, needs, graph)
    local rooms_created = {}
    
    -- Create BSP tree for this level
    local root = BSPNode.new(
        center_x - math.floor(width / 2),
        center_y - math.floor(height / 2),
        width,
        height
    )
    
    -- Recursively split
    local min_room_size = 4
    local max_depth = 4
    
    local function recursive_split(node, depth)
        if depth >= max_depth then return end
        
        if node:split(min_room_size) then
            recursive_split(node.left, depth + 1)
            recursive_split(node.right, depth + 1)
        end
    end
    
    recursive_split(root, 0)
    
    -- Get leaf nodes and assign rooms
    local leaves = root:get_leaves()
    local need_idx = 1
    
    for _, leaf in ipairs(leaves) do
        if need_idx > #needs then break end
        
        local need = needs[need_idx]
        local type_def = need.type_def
        
        -- Check if the leaf is big enough for this room type
        if leaf.width >= type_def.min_w and leaf.height >= type_def.min_h then
            -- Create room with some padding
            local room_w = math.min(leaf.width - 2, type_def.max_w)
            local room_h = math.min(leaf.height - 2, type_def.max_h)
            local room_x = leaf.x + 1
            local room_y = leaf.y + 1
            
            local room = Room.new(
                graph:get_next_id(),
                type_def,
                room_x, room_y, z,
                room_w, room_h
            )
            
            -- Randomly apply L or T shape to larger rooms (30% chance)
            -- Only for rooms that are large enough to have interesting shapes
            if room_w >= 5 and room_h >= 5 and math.random() < 0.3 then
                local shape_roll = math.random()
                if shape_roll < 0.6 then
                    -- L-shape (60% of shaped rooms)
                    local variants = {"NE", "NW", "SE", "SW"}
                    room:set_shape("L", variants[math.random(#variants)])
                    utils.log_debug("Created L-shaped " .. type_def.name .. " (" .. room.shape_variant .. ")", PLANNER_NAME)
                else
                    -- T-shape (40% of shaped rooms)
                    local variants = {"N", "S", "E", "W"}
                    room:set_shape("T", variants[math.random(#variants)])
                    utils.log_debug("Created T-shaped " .. type_def.name .. " (" .. room.shape_variant .. ")", PLANNER_NAME)
                end
            end
            
            graph:add_room(room)
            table.insert(rooms_created, room)
            leaf.room = room
            
            need.count = need.count - 1
            if need.count <= 0 then
                need_idx = need_idx + 1
            end
        end
    end
    
    -- Connect rooms with corridors
    for i = 1, #rooms_created - 1 do
        local room_a = rooms_created[i]
        local room_b = rooms_created[i + 1]
        
        local ax, ay = room_a:get_center()
        local bx, by = room_b:get_center()
        
        local corridor_tiles = create_corridor_tiles(ax, ay, bx, by, z)
        table.insert(graph.corridors, {
            from = room_a.id,
            to = room_b.id,
            tiles = corridor_tiles
        })
        
        room_a:connect_to(room_b)
    end
    
    return rooms_created
end

-------------------------------------------------------------------------------
-- Main Generation Function
-------------------------------------------------------------------------------

function generate_fortress_plan(wagon_x, wagon_y, surface_z, population)
    population = population or 7
    local military_count = 0
    
    local graph = FortressGraph.new()
    local all_tiles = {}  -- All tiles to dig
    
    -- Find safest direction for entry
    local best_dir, safety_score = terrain.find_safest_direction(wagon_x, wagon_y, surface_z)
    if not best_dir then
        best_dir = "north"
    end
    
    -- Calculate entry point - close to wagon
    local direction_vectors = {
        north = {0, -1},
        south = {0, 1},
        east = {1, 0},
        west = {-1, 0}
    }
    local vec = direction_vectors[best_dir]
    local entry_x = wagon_x + vec[1] * 5
    local entry_y = wagon_y + vec[2] * 5
    
    -- Find safe underground level (HUB)
    -- We scan a 30x30 area to ensure the main workshop level is safe
    local entry_z = terrain.find_enclosed_z_level(entry_x, entry_y, surface_z, 30, 30)
    
    utils.log_debug("Entry point: (" .. entry_x .. ", " .. entry_y .. ") surface_z=" .. surface_z .. " hub_z=" .. entry_z, PLANNER_NAME)
    
    -- --- 1 & 2. SAFE RAMP & TRADE DEPOT (Surface to Safe Level) ---
    -- CRITICAL UPDATE: We now scan for aquifers layer-by-layer.
    
    local ramp_path_tiles = {}
    local depot_level = nil
    
    -- Function to check a 3x3 area for safety (wagon width)
    local function is_area_safe_for_ramp(cx, cy, cz)
        for dx = -1, 1 do
            for dy = -1, 1 do
                if terrain.is_aquifer(cx+dx, cy+dy, cz) then return false end
                if terrain.has_magma(cx+dx, cy+dy, cz) then return false end
                -- Note: We allow water if it's surface water (we can channel it), 
                -- but avoid underground water sources.
            end
        end
        return true
    end

    -- Smart Ramp Generation using A* Pathfinding
    -- Attempts to find a safe wagon-accessible path from Surface to Depth-20
    utils.log("Starting A* Ramp Generation from Z=" .. surface_z .. " to Z=" .. (surface_z-20), PLANNER_NAME)
    
    local start_node = {x = wagon_x, y = wagon_y, z = surface_z}
    local target_depth_abs = surface_z - 20
    local goal_node = {x = wagon_x, y = wagon_y, z = target_depth_abs}
    
    -- Safety check helper
    local function is_safe_3x3(nx, ny, nz)
        for dx = -1, 1 do
            for dy = -1, 1 do
                local t = terrain.analyze_tile(nx + dx, ny + dy, nz)
                if t.aquifer then return false end
                if t.hidden_void or t.open_space then 
                    -- Only safe if it's natural open space (surface) or we are digging?
                    -- Caverns are hidden_void usually.
                    return false 
                end
                if t.magma or t.water then return false end
            end
        end
        return true
    end

    local callbacks = {
        neighbors = function(node)
            local neighbors = {}
            -- Horizontal
            local dirs = {{0,1}, {0,-1}, {1,0}, {-1,0}}
            for _, d in ipairs(dirs) do
                table.insert(neighbors, {x = node.x + d[1], y = node.y + d[2], z = node.z})
            end
            -- Downward (Ramp)
            for _, d in ipairs(dirs) do
                 table.insert(neighbors, {x = node.x + d[1], y = node.y + d[2], z = node.z - 1})
            end
            return neighbors
        end,
        
        cost = function(curr, next)
            local dist = math.abs(curr.x - next.x) + math.abs(curr.y - next.y) + math.abs(curr.z - next.z)
            local cost = dist
            
            -- Heavily penalize invalid terrain to act as "Avoid"
            -- We must check the 3x3 footprint at the TARGET location
            if not is_safe_3x3(next.x, next.y, next.z) then
                return 999999 -- Infinite cost for hazard
            end
            
            if next.z < curr.z then
                 cost = cost + 2 -- Bias against plunging too fast/stairs
            end
            
            return cost
        end,
        
        is_valid = function(node)
            if node.z > surface_z or node.z < 0 then return false end
            return true
        end,
        
        heuristic = function(node, goal)
            -- Encourage going DOWN (to z) over horizontal
            local dz = math.abs(node.z - goal.z)
            local dxy = math.abs(node.x - goal.x) + math.abs(node.y - goal.y)
            return dz * 0.8 + dxy * 2 -- Heuristic tuning
        end
    }
    
    local path = pf.find_path(start_node, goal_node, callbacks)
    
    if not path then
         utils.log_error("CRITICAL: A* Ramp Generation Failed. No safe non-aquifer path found.", PLANNER_NAME)
         return false
    end
    
    -- Convert path to designations
    local depot_level = path[#path].z
    local depot_found = true
    
    for i = 1, #path do
        local p = path[i]
        local prev = path[i-1]
        
        -- Dig 3-wide
        for dx = -1, 1 do
            for dy = -1, 1 do
                 if prev and p.z < prev.z then
                     -- Ramp Down
                     table.insert(ramp_path_tiles, {x=p.x + dx, y=p.y + dy, z=p.z, dig_type="ramp"})
                     table.insert(ramp_path_tiles, {x=p.x + dx, y=p.y + dy, z=prev.z, dig_type="channel"})
                 else
                     -- Flat
                     table.insert(ramp_path_tiles, {x=p.x + dx, y=p.y + dy, z=p.z, dig_type="dig"})
                 end
            end
        end
    end
    
    -- Commit the ramp tiles
    for _, t in ipairs(ramp_path_tiles) do table.insert(all_tiles, t) end
    
    depot_room_x = path[#path].x
    depot_room_y = path[#path].y
    
    -- Create Trade Depot Room
    utils.log("Placing Trade Depot at Z-" .. (surface_z - depot_level), PLANNER_NAME)
    
    local depot_room = Room.new(graph:get_next_id(), ROOM_TYPES.TRADE_DEPOT, depot_room_x, depot_room_y, depot_level, 7, 7)
    graph:add_room(depot_room)
    for _, tile in ipairs(depot_room:get_tiles()) do table.insert(all_tiles, tile) end
    
    -- Update entry info
    depot_z = depot_level
    tunnel_end_x = depot_room_x
    tunnel_end_y = depot_room_y


    -- --- 4. TRAP HALL (Depot to Hub) ---
    -- Long narrow(ish) corridor connecting Depot Z to Central Stairwell
    -- Connect depot to center_hub X/Y
    local center_x = entry_x + vec[1] * 15 -- Push hub further back
    local center_y = entry_y + vec[2] * 15
    
    -- Create Trap Corridor
    local trap_hall_tiles = create_corridor_tiles(depot_room_x, depot_room_y, center_x, center_y, depot_z)
    for _, t in ipairs(trap_hall_tiles) do
         table.insert(all_tiles, t)
    end
    
    -- --- 5. CENTRAL STAIRWELL (Hub) ---
    -- Starts at Depot Z (top) goes down to Hub Z bottom
    
    -- Ensure Hub Z is at least below Depot Z
    if entry_z >= depot_z then entry_z = depot_z - 3 end
    
    -- Create central stairwell (3x3)
    local deepest_z = entry_z - 4
    for z = depot_z, deepest_z, -1 do
        for dx = -1, 1 do
            for dy = -1, 1 do
                local dig_type = "updown"
                if z == depot_z then
                    dig_type = "down"
                elseif z == deepest_z then
                    dig_type = "up"
                end
                table.insert(all_tiles, {x = center_x + dx, y = center_y + dy, z = z, stair_type = dig_type})
            end
        end
    end
    
    table.insert(graph.stairwells, {center_x = center_x, center_y = center_y, top_z = depot_z, bottom_z = deepest_z})
    
    -- Connect Trap Hall to Central Stairwell
    -- (Already implicitly connected by coords)
    
        
    -- (Hub design integrated above in step 5)
    
    -- Define rooms for each level using simple grid layout
    -- Each level has rooms arranged in a cross pattern around the stairwell
    
    local room_configs = {
        -- Level 0 (entry_z): Workshops
        {z = entry_z, rooms = {
            {type = ROOM_TYPES.WORKSHOP_HALL, dx = -12, dy = 0, w = 10, h = 10},
            {type = ROOM_TYPES.WORKSHOP_HALL, dx = 12, dy = 0, w = 10, h = 10},
        }},
        -- Level -1: Storage
        {z = entry_z - 1, rooms = {
            {type = ROOM_TYPES.STORAGE_MAIN, dx = 0, dy = -12, w = 10, h = 10},
            {type = ROOM_TYPES.STORAGE_MAIN, dx = 0, dy = 12, w = 10, h = 10},
        }},
        -- Level -2: Common areas
        {z = entry_z - 2, rooms = {
            {type = ROOM_TYPES.DINING, dx = -12, dy = 0, w = 8, h = 8},
            {type = ROOM_TYPES.HOSPITAL, dx = 12, dy = 0, w = 6, h = 6},
            {type = ROOM_TYPES.TAVERN, dx = 0, dy = -12, w = 7, h = 7},
        }},
        -- Level -3: Living quarters
        {z = entry_z - 3, rooms = {
            {type = ROOM_TYPES.DORMITORY, dx = -10, dy = -10, w = 6, h = 6},
            {type = ROOM_TYPES.DORMITORY, dx = 10, dy = -10, w = 6, h = 6},
            {type = ROOM_TYPES.DORMITORY, dx = -10, dy = 10, w = 6, h = 6},
            {type = ROOM_TYPES.DORMITORY, dx = 10, dy = 10, w = 6, h = 6},
        }},
        -- Level -4: Deeper living / future expansion
        {z = entry_z - 4, rooms = {
            {type = ROOM_TYPES.BARRACKS, dx = -10, dy = 0, w = 8, h = 8},
            {type = ROOM_TYPES.TRAINING, dx = 10, dy = 0, w = 8, h = 8},
        }},
    }
    
    local room_count = 0
    
    for _, level_config in ipairs(room_configs) do
        local z = level_config.z
        
        for _, room_def in ipairs(level_config.rooms) do
            local room_x = center_x + room_def.dx - math.floor(room_def.w / 2)
            local room_y = center_y + room_def.dy - math.floor(room_def.h / 2)
            
            -- SAFETY CHECK: verify this room area is safe to dig
            if terrain.check_area_safety(room_x, room_y, z, room_def.w, room_def.h) then
                -- Create the room
                local room = Room.new(
                    graph:get_next_id(),
                    room_def.type,
                    room_x, room_y, z,
                    room_def.w, room_def.h
                )
                
                -- Randomly add L/T shapes to larger rooms
                if room_def.w >= 6 and room_def.h >= 6 and math.random() < 0.3 then
                    local variants_L = {"NE", "NW", "SE", "SW"}
                    local variants_T = {"N", "S", "E", "W"}
                    if math.random() < 0.6 then
                        room:set_shape("L", variants_L[math.random(#variants_L)])
                        utils.log_debug("Created L-shaped " .. room_def.type.name .. " (" .. room.shape_variant .. ")", PLANNER_NAME)
                    else
                        room:set_shape("T", variants_T[math.random(#variants_T)])
                        utils.log_debug("Created T-shaped " .. room_def.type.name .. " (" .. room.shape_variant .. ")", PLANNER_NAME)
                    end
                end
                
                graph:add_room(room)
                room_count = room_count + 1
                
                -- Add room tiles
                for _, tile in ipairs(room:get_tiles()) do
                    table.insert(all_tiles, tile)
                end
                
                -- CRITICAL: Create corridor from stairwell to this room
                local room_cx, room_cy = room:get_center()
                local corridor_tiles = create_corridor_tiles(center_x, center_y, room_cx, room_cy, z)
                
                table.insert(graph.corridors, {
                    from = "stairwell",
                    to = room.id,
                    tiles = corridor_tiles
                })
                
                for _, tile in ipairs(corridor_tiles) do
                    table.insert(all_tiles, tile)
                end
            else
                utils.log_warn("Skipping unsafe room " .. room_def.type.name .. " at " .. z, PLANNER_NAME)
            end
        end
    end
    
    utils.log_action(PLANNER_NAME, "Fortress plan generated",
        room_count .. " rooms, " .. #graph.corridors .. " corridors, " .. #all_tiles .. " tiles")
    
    return {
        graph = graph,
        tiles = all_tiles,
        center_x = center_x,
        center_y = center_y,
        entry_z = entry_z,
        direction = best_dir
    }
end

-------------------------------------------------------------------------------
-- Expansion Functions
-------------------------------------------------------------------------------

function check_expansion_needs(current_graph, population, military_count)
    local needs = calculate_fortress_needs(population, military_count, current_graph)
    
    if #needs > 0 then
        utils.log_debug("Expansion needed: " .. #needs .. " room types under capacity", PLANNER_NAME)
        return true, needs
    end
    
    return false, {}
end

function expand_fortress(current_graph, needs, center_x, center_y, base_z)
    -- Find the lowest z-level in use for living quarters
    local lowest_living_z = base_z - 3
    for z, rooms in pairs(current_graph.z_levels) do
        for _, room in ipairs(rooms) do
            if room.room_type.z_pref == "living" then
                lowest_living_z = math.min(lowest_living_z, z)
            end
        end
    end
    
    -- Expand one level below
    local new_z = lowest_living_z - 1
    
    -- Filter needs to just what we can build on a living level
    local living_needs = {}
    for _, need in ipairs(needs) do
        if need.type_def.z_pref == "living" then
            table.insert(living_needs, need)
        end
    end
    
    if #living_needs == 0 then
        return nil, 0
    end
    
    -- Generate new level
    local new_rooms = generate_level_layout(center_x, center_y, new_z, 20, 20, living_needs, current_graph)
    
    -- Connect to level above via stairs
    table.insert(current_graph.stairwells, create_stairwell_tiles(center_x, center_y, lowest_living_z, new_z))
    
    -- Collect tiles
    local tiles = {}
    for _, room in ipairs(new_rooms) do
        for _, tile in ipairs(room:get_tiles()) do
            table.insert(tiles, tile)
        end
    end
    
    utils.log_action(PLANNER_NAME, "Fortress expanded",
        "New level at Z=" .. new_z .. " with " .. #new_rooms .. " rooms")
    
    return tiles, #new_rooms
end

-------------------------------------------------------------------------------
-- Helper to check if terrain is diggable
-------------------------------------------------------------------------------

function terrain.is_diggable_z(x, y, z)
    if not utils.is_valid_pos(x, y, z) then return false end
    
    local ok, ttype = pcall(function()
        return utils.get_tile_type(x, y, z)
    end)
    
    if not ok or not ttype then return false end
    
    local ok2, shape = pcall(function()
        return df.tiletype.attrs[ttype].shape
    end)
    
    if not ok2 then return false end
    
    return shape == df.tiletype_shape.WALL or
           shape == df.tiletype_shape.FORTIFICATION
end

-------------------------------------------------------------------------------
-- State Management
-------------------------------------------------------------------------------

-- Cached graph for the current session (not persisted, rebuilt on load)
local current_graph = nil

function save_plan_to_state(plan)
    local planner_state = state.get_manager_state(PLANNER_NAME) or {}
    
    planner_state.center_x = plan.center_x
    planner_state.center_y = plan.center_y
    planner_state.entry_z = plan.entry_z
    planner_state.direction = plan.direction
    planner_state.room_count = 0
    
    -- Serialize room data for later use
    planner_state.rooms = {}
    
    if plan.graph then
        current_graph = plan.graph  -- Cache for current session
        
        for id, room in pairs(plan.graph.rooms) do
            planner_state.room_count = planner_state.room_count + 1
            
            -- Save essential room data (can be reconstructed)
            table.insert(planner_state.rooms, {
                id = room.id,
                type_id = room.room_type.id,
                type_name = room.room_type.name,
                x = room.x,
                y = room.y,
                z = room.z,
                width = room.width,
                height = room.height,
                shape = room.shape,
                shape_variant = room.shape_variant,
                zone_created = room.zone_created or false,
                furniture_placed = room.furniture_placed or false,
            })
        end
    end
    
    planner_state.tiles_to_dig = #plan.tiles
    planner_state.plan_generated = true
    
    state.set_manager_state(PLANNER_NAME, planner_state)
end

function get_plan_from_state()
    return state.get_manager_state(PLANNER_NAME)
end

function get_rooms_from_state()
    local planner_state = get_plan_from_state()
    if planner_state and planner_state.rooms then
        return planner_state.rooms
    end
    return {}
end

function get_current_graph()
    return current_graph
end

function mark_room_zone_created(room_id)
    local planner_state = get_plan_from_state()
    if planner_state and planner_state.rooms then
        for _, room in ipairs(planner_state.rooms) do
            if room.id == room_id then
                room.zone_created = true
                break
            end
        end
        state.set_manager_state(PLANNER_NAME, planner_state)
    end
    
    -- Also update cached graph
    if current_graph and current_graph.rooms[room_id] then
        current_graph.rooms[room_id].zone_created = true
    end
end

function mark_room_furniture_placed(room_id)
    local planner_state = get_plan_from_state()
    if planner_state and planner_state.rooms then
        for _, room in ipairs(planner_state.rooms) do
            if room.id == room_id then
                room.furniture_placed = true
                break
            end
        end
        state.set_manager_state(PLANNER_NAME, planner_state)
    end
    
    if current_graph and current_graph.rooms[room_id] then
        current_graph.rooms[room_id].furniture_placed = true
    end
end

-------------------------------------------------------------------------------
-- Room Furniture Requirements
-------------------------------------------------------------------------------

-- Defines what furniture each room type needs
local ROOM_FURNITURE = {
    bedroom = {
        required = {"bed", "cabinet", "chest"},
        optional = {"table", "chair"}
    },
    dormitory = {
        required = {"bed", "bed", "bed", "bed"},
        optional = {"cabinet", "chest"}
    },
    dining = {
        required = {"table", "chair", "table", "chair", "table", "chair"},
        optional = {"statue"}
    },
    hospital = {
        required = {"bed", "table", "traction_bench"},
        optional = {"chest", "cabinet"}
    },
    tavern = {
        required = {"table", "chair", "table", "chair"},
        optional = {"keg", "instrument"}
    },
    temple = {
        required = {},
        optional = {"altar", "statue"}
    },
    library = {
        required = {"table", "chair", "bookcase"},
        optional = {"bookcase", "chair"}
    },
    barracks = {
        required = {"weapon_rack", "armor_stand"},
        optional = {"cabinet", "chest"}
    },
    training = {
        required = {},
        optional = {"weapon_rack"}
    },
    jail = {
        required = {"cage", "chain"},
        optional = {}
    },
    tomb = {
        required = {"coffin"},
        optional = {"coffin", "coffin", "statue"}
    },
}

function get_room_furniture_needs(room_type_id)
    return ROOM_FURNITURE[room_type_id] or {required = {}, optional = {}}
end

-------------------------------------------------------------------------------
-- Zone Type Mapping
-------------------------------------------------------------------------------

-- Maps room types to DF zone types for auto-zone creation
local ROOM_ZONE_TYPES = {
    bedroom = "bedroom",
    dormitory = "dormitory", 
    dining = "dining_hall",
    hospital = "hospital",
    tavern = "tavern",
    temple = "temple",
    library = "library",
    barracks = "barracks",
    training = "training",
    jail = "jail",
    tomb = "tomb",
    pasture = "pasture",
    meeting = "meeting_hall",
}

function get_zone_type_for_room(room_type_id)
    return ROOM_ZONE_TYPES[room_type_id]
end

-------------------------------------------------------------------------------
-- Room Status Checking
-------------------------------------------------------------------------------

function is_room_dug(room)
    if not room then return false end
    
    local tiles = room:get_tiles()
    local dug_count = 0
    
    for _, tile in ipairs(tiles) do
        local ok, ttype = pcall(function()
            return utils.get_tile_type(tile.x, tile.y, tile.z)
        end)
        
        if ok and ttype then
            local ok2, shape = pcall(function()
                return df.tiletype.attrs[ttype].shape
            end)
            
            if ok2 and (shape == df.tiletype_shape.FLOOR or 
                        shape == df.tiletype_shape.STAIR_UP or
                        shape == df.tiletype_shape.STAIR_DOWN or
                        shape == df.tiletype_shape.STAIR_UPDOWN) then
                dug_count = dug_count + 1
            end
        end
    end
    
    -- Room is "dug" if at least 80% of tiles are floors
    return dug_count >= (#tiles * 0.8)
end

function get_rooms_ready_for_zone(graph)
    local ready = {}
    
    for _, room in pairs(graph.rooms) do
        if is_room_dug(room) and not room.zone_created then
            table.insert(ready, room)
        end
    end
    
    return ready
end

-------------------------------------------------------------------------------
-- Stockpile-Room Matching
-------------------------------------------------------------------------------

-- Maps room types to ideal stockpile types
local ROOM_STOCKPILE_TYPES = {
    storage_main = {"stone", "wood", "bars_blocks", "furniture"},
    workshop_hall = {"stone", "wood", "bars_blocks"},
    forge_area = {"bars_blocks", "weapons", "armor", "ammo"},
    kitchen = {"food"},
    dining = {"food"},
    hospital = {"cloth", "finished_goods"},
    barracks = {"weapons", "armor", "ammo"},
    tomb = {},
    library = {"finished_goods"},
}

function get_stockpile_types_for_room(room_type_id)
    return ROOM_STOCKPILE_TYPES[room_type_id] or {}
end

-------------------------------------------------------------------------------
-- Workshop Recommendations by Room
-------------------------------------------------------------------------------

-- Maps room types to workshops that should be placed there
local ROOM_WORKSHOP_TYPES = {
    workshop_hall = {
        df.workshop_type.Carpenters,
        df.workshop_type.Masons,
        df.workshop_type.Craftsdwarfs,
        df.workshop_type.Mechanics,
        df.workshop_type.Still,
        df.workshop_type.Kitchen,
        df.workshop_type.Butchers,
        df.workshop_type.Tanners,
        df.workshop_type.Farmers,
        df.workshop_type.Loom,
        df.workshop_type.Clothiers,
        df.workshop_type.Leatherworks,
    },
    forge_area = {
        -- Workshops will use furnaces instead
    },
}

function get_workshop_types_for_room(room_type_id)
    return ROOM_WORKSHOP_TYPES[room_type_id] or {}
end

-------------------------------------------------------------------------------
-- Smart Room Utilities
-------------------------------------------------------------------------------

-- Get rooms by type from state
function get_rooms_by_type_from_state(type_id)
    local rooms = get_rooms_from_state()
    local result = {}
    
    for _, room in ipairs(rooms) do
        if room.type_id == type_id then
            table.insert(result, room)
        end
    end
    
    return result
end

-- Find room at a position
function find_room_at_pos(x, y, z)
    local rooms = get_rooms_from_state()
    
    for _, room in ipairs(rooms) do
        if room.z == z then
            if x >= room.x and x < room.x + room.width and
               y >= room.y and y < room.y + room.height then
                return room
            end
        end
    end
    
    return nil
end

-- Get the center positions of workshop hall rooms
function get_workshop_placement_positions()
    local positions = {}
    local workshop_halls = get_rooms_by_type_from_state("workshop_hall")
    
    for _, room in ipairs(workshop_halls) do
        -- Calculate grid positions for workshop placement (3x3 workshops)
        local spacing = 4  -- 3 for workshop + 1 gap
        local cols = math.floor((room.width - 2) / spacing)
        local rows = math.floor((room.height - 2) / spacing)
        
        for row = 0, rows - 1 do
            for col = 0, cols - 1 do
                table.insert(positions, {
                    x = room.x + 1 + col * spacing + 1,  -- +1 for center of 3x3
                    y = room.y + 1 + row * spacing + 1,
                    z = room.z,
                    room_id = room.id
                })
            end
        end
    end
    
    return positions
end

-- Get storage room for stockpile placement
function get_storage_rooms()
    return get_rooms_by_type_from_state("storage_main")
end

-- Check if we need to expand (population vs room capacity)
function should_expand(population)
    local bedrooms = get_rooms_by_type_from_state("bedroom")
    local dormitories = get_rooms_by_type_from_state("dormitory")
    
    -- Each dormitory holds ~4, each bedroom holds 1
    local capacity = #bedrooms + (#dormitories * 4)
    
    return population > capacity * 0.8
end

-- Check if a Z-level is safe for expansion (no caverns, magma, water)
function check_z_level_safety(z, center_x, center_y, radius)
    -- Sample points in a grid around the center
    local step = 10
    radius = radius or 40
    
    for x = center_x - radius, center_x + radius, step do
        for y = center_y - radius, center_y + radius, step do
            local analysis = terrain.analyze_tile(x, y, z)
            if not analysis.safe then
                -- Ignore solid walls, we only care about bad stuff
                if analysis.reason ~= "solid wall" then
                    -- If it's a specific hazard like magma/water/open space
                    if analysis.liquid or analysis.open then
                         return false, analysis.reason
                    end
                end
            end
            
            -- Also check strictly for open space (caverns) if terrain analyzer didn't catch it
            local ttype = utils.get_tile_type(x, y, z)
            if ttype then
                local shape = df.tiletype.attrs[ttype].shape
                if shape == df.tiletype_shape.EMPTY or shape == df.tiletype_shape.RAMP_TOP then
                    return false, "cavern/open space"
                end
            end
        end
    end
    
    return true
end


-- Find the next safe Z-level for expansion (Vertical vs Horizontal)
-- Returns: z_level, strategy ("vertical" or "horizontal")
function get_safe_expansion_z(current_lowest_z, center_x, center_y)
    -- Try going down first
    local next_z = current_lowest_z - 1
    local safe, reason = check_z_level_safety(next_z, center_x, center_y)
    
    if safe then
        return next_z, "vertical"
    end
    
    utils.log(string.format("Vertical expansion to Z=%d blocked: %s", next_z, reason), PLANNER_NAME)
    
    -- Vertical blocked. Try horizontal expansion on existing levels?
    -- For now, just try to find ANY safe level below, skipping unsafe ones?
    -- Or stick to current level?
    
    -- Attempt skip (try up to 5 levels down)
    for i = 2, 5 do
        local check_z = current_lowest_z - i
        local s, r = check_z_level_safety(check_z, center_x, center_y)
        if s then
             utils.log(string.format("Found safe level at Z=%d (skipped %d levels)", check_z, i-1), PLANNER_NAME)
             return check_z, "vertical"
        end
    end
    
    -- If we can't go down, return nil to halt expansion or current level to force horizontal (not impl yet)
    utils.log_error("Could not find safe expansion level!", PLANNER_NAME)
    return nil, "blocked"
end


-- Get recommended expansion type
function get_expansion_recommendation(population, military_count)
    military_count = military_count or 0
    
    local needs = {}
    
    -- Check bedroom capacity
    local bedrooms = get_rooms_by_type_from_state("bedroom")
    if #bedrooms < population then
        table.insert(needs, {
            type = "bedroom",
            count = population - #bedrooms,
            priority = 1
        })
    end
    
    -- Check military needs
    if military_count > 0 then
        local barracks = get_rooms_by_type_from_state("barracks")
        if #barracks < math.ceil(military_count / 10) then
            table.insert(needs, {
                type = "barracks",
                count = 1,
                priority = 2
            })
        end
    end
    
    -- Sort by priority
    table.sort(needs, function(a, b) return a.priority < b.priority end)
    
    return needs
end

return _ENV
