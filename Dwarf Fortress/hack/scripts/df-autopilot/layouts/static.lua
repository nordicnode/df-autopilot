-- df-autopilot/layouts/static.lua
-- Legacy/Static fortress layout generator
-- Extracted from managers/mining.lua

--@ module = true

local utils = reqscript("df-autopilot/utils")
local terrain = reqscript("df-autopilot/terrain")

-------------------------------------------------------------------------------
-- Helper Functions
-------------------------------------------------------------------------------

--- Check if a tile is diggable (wall, fortification)
local function is_diggable(x, y, z)
    local ttype = utils.get_tile_type(x, y, z)
    if not ttype then return false end
    
    local ok, shape = pcall(function()
        return df.tiletype.attrs[ttype].shape
    end)
    if not ok then return false end
    
    return shape == df.tiletype_shape.WALL or
           shape == df.tiletype_shape.FORTIFICATION
end

-- Collect dig operation
local function add_dig(plan, x, y, z, dig_type)
    table.insert(plan, {
        x = x, 
        y = y, 
        z = z, 
        dig_type = dig_type or "dig"
    })
end

-- Horizontal corridor
local function plan_corridor(plan, x1, y1, z, x2, y2)
    local min_x = math.min(x1, x2)
    local max_x = math.max(x1, x2)
    local min_y = math.min(y1, y2)
    local max_y = math.max(y1, y2)
    
    for x = min_x, max_x do
        for y = min_y, max_y do
            if is_diggable(x, y, z) then
                add_dig(plan, x, y, z, "dig")
            end
        end
    end
end

-- Rectangular room
local function plan_room(plan, x, y, z, width, height)
    local half_w = math.floor(width / 2)
    local half_h = math.floor(height / 2)
    plan_corridor(plan, x - half_w, y - half_h, z, x + half_w, y + half_h)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Generate the static starter layout
--- @param wagon_x, wagon_y, wagon_z Coordinates of embark center
--- @return table Plan object with .tiles array
function generate(wagon_x, wagon_y, wagon_z)
    local plan = {
        tiles = {},
        center_x = wagon_x,
        center_y = wagon_y,
        surface_z = wagon_z,
        entry_z = nil,
        storage_z = nil,
        direction = nil
    }
    
    utils.log("Generating static layout plan...", "layouts/static")
    
    -- Step 1: Find safe direction
    local surface_z = wagon_z
    local best_dir, safety_score, hazards = terrain.find_safest_direction(wagon_x, wagon_y, surface_z)
    
    if not best_dir then
        utils.log_error("No safe direction found!", "layouts/static")
        return nil
    end
    
    plan.direction = best_dir
    
    -- Calculate entrance pos
    local direction_vectors = {
        north = {0, -10},
        south = {0, 10},
        east = {10, 0},
        west = {-10, 0}
    }
    local vec = direction_vectors[best_dir]
    local entrance_x = wagon_x + vec[1]
    local entrance_y = wagon_y + vec[2]
    
    -- Step 2: Find first underground level
    local underground_z = nil
    for z = surface_z - 1, surface_z - 10, -1 do
        if terrain.is_safe_to_dig(entrance_x, entrance_y, z) and is_diggable(entrance_x, entrance_y, z) then
            underground_z = z
            break
        end
    end
    
    if not underground_z then
        utils.log_warn("Could not find underground layer", "layouts/static")
        return nil
    end
    
    plan.entry_z = underground_z
    
    -- Step 3: Channel ramp
    for z = surface_z, underground_z + 1, -1 do
        if terrain.is_safe_to_dig(entrance_x, entrance_y, z) then
            add_dig(plan.tiles, entrance_x, entrance_y, z, "channel")
        end
    end
    
    -- Step 4: Dig Entry Corridor
    local cx, cy = entrance_x, entrance_y
    local corridor_len = 15
    local entry_z = underground_z
    
    if plan.direction == "north" then
        for i = 0, corridor_len do
            if is_diggable(cx, cy - i, entry_z) then
                add_dig(plan.tiles, cx, cy - i, entry_z, "dig")
            end
        end
        cy = cy - corridor_len
    elseif plan.direction == "south" then
        for i = 0, corridor_len do
             if is_diggable(cx, cy + i, entry_z) then
                add_dig(plan.tiles, cx, cy + i, entry_z, "dig")
            end
        end
        cy = cy + corridor_len
    elseif plan.direction == "west" then
        for i = 0, corridor_len do
             if is_diggable(cx - i, cy, entry_z) then
                add_dig(plan.tiles, cx - i, cy, entry_z, "dig")
            end
        end
        cx = cx - corridor_len
    else -- east
        for i = 0, corridor_len do
             if is_diggable(cx + i, cy, entry_z) then
                add_dig(plan.tiles, cx + i, cy, entry_z, "dig")
            end
        end
        cx = cx + corridor_len
    end
    
    -- Update "center" of the fort to be the end of the corridor
    plan.center_x = cx
    plan.center_y = cy
    
    -- Step 5: Main Hub
    -- Down stair
    if is_diggable(cx, cy, entry_z) then
        add_dig(plan.tiles, cx, cy, entry_z, "stair_down")
    end
    
    -- Cross corridors
    plan_corridor(plan.tiles, cx - 10, cy, entry_z, cx + 10, cy)
    plan_corridor(plan.tiles, cx, cy - 10, entry_z, cx, cy + 10)
    
    -- Workshops
    plan_room(plan.tiles, cx - 8, cy - 3, entry_z, 5, 5)
    plan_room(plan.tiles, cx - 8, cy + 3, entry_z, 5, 5)
    plan_room(plan.tiles, cx + 8, cy - 3, entry_z, 5, 5)
    plan_room(plan.tiles, cx + 8, cy + 3, entry_z, 5, 5)
    
    -- Central Hall
    plan_room(plan.tiles, cx, cy, entry_z, 9, 9)
    
    -- Step 6: Lower Storage Level
    local storage_z = entry_z - 1
    if terrain.is_safe_to_dig(cx, cy, storage_z) then
        plan.storage_z = storage_z
        
        -- Up/Down stair
        if is_diggable(cx, cy, storage_z) then
            add_dig(plan.tiles, cx, cy, storage_z, "stair_updown")
        end
        
        -- Storage Corridors
        plan_corridor(plan.tiles, cx - 15, cy, storage_z, cx + 15, cy)
        plan_corridor(plan.tiles, cx, cy - 15, storage_z, cx, cy + 15)
        
        -- Storage Rooms
        plan_room(plan.tiles, cx - 25, cy - 10, storage_z, 8, 8)
        plan_room(plan.tiles, cx - 25, cy + 10, storage_z, 8, 8)
        plan_room(plan.tiles, cx + 25, cy - 10, storage_z, 8, 8)
        plan_room(plan.tiles, cx + 25, cy + 10, storage_z, 8, 8)
    end
    
    return plan
end

return _ENV
