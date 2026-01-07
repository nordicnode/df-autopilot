-- df-autopilot/managers/mining.lua
-- Mining and expansion management
-- Handles fortress digging and expansion

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")
local terrain = reqscript("df-autopilot/terrain")
local planner = reqscript("df-autopilot/fortress_planner")

local MANAGER_NAME = "mining"
local last_check = 0
local CHECK_INTERVAL = 500
local USE_DYNAMIC_PLANNER = true  -- Enable new dynamic fortress generation

-------------------------------------------------------------------------------
-- Tile Type Helpers
-------------------------------------------------------------------------------

--- Check if a tile is diggable (wall, floor, etc.)
local function is_diggable(ttype)
    if not ttype then return false end
    
    local ok, shape = pcall(function()
        return df.tiletype.attrs[ttype].shape
    end)
    if not ok then return false end
    
    return shape == df.tiletype_shape.WALL or
           shape == df.tiletype_shape.FORTIFICATION
end

--- Check if a tile is open (floor, open space)
local function is_open(ttype)
    if not ttype then return false end
    
    local ok, shape = pcall(function()
        return df.tiletype.attrs[ttype].shape
    end)
    if not ok then return false end
    
    return shape == df.tiletype_shape.FLOOR or
           shape == df.tiletype_shape.EMPTY or
           shape == df.tiletype_shape.RAMP or
           shape == df.tiletype_shape.STAIR_UP or
           shape == df.tiletype_shape.STAIR_DOWN or
           shape == df.tiletype_shape.STAIR_UPDOWN
end

--- Check if a tile has a mining designation
local function has_dig_designation(x, y, z)
    if not utils.is_valid_pos(x, y, z) then return true end -- Treat out of bounds as "already dug"
    
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then return false end
    
    local designation = block.designation[x % 16][y % 16]
    return designation.dig ~= df.tile_dig_designation.No
end

--- Check if a tile is safe to dig (no aquifer, water, magma)
local function is_safe_to_dig(x, y, z)
    if not utils.is_valid_pos(x, y, z) then
        return false
    end
    
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then return false end
    
    local ok, result = pcall(function()
        local designation = block.designation[x % 16][y % 16]
        
        -- Check for water
        if designation.flow_size > 0 then
            return false
        end
        
        -- Check for aquifer
        if designation.water_table then
            return false
        end
        
        -- Check tile flags for special features
        local tileflags = block.tiletype[x % 16][y % 16]
        local attrs = df.tiletype.attrs[tileflags]
        
        -- Don't dig through constructed walls
        if attrs and attrs.material == df.tiletype_material.CONSTRUCTION then
            return false
        end
        
        return true
    end)
    
    if ok then return result end
    return false
end

--- Set a mining designation (with comprehensive safety checks)
local function designate_dig(x, y, z, dig_type)
    dig_type = dig_type or df.tile_dig_designation.Default
    
    -- Bounds check
    if not utils.is_valid_pos(x, y, z) then
        return false
    end
    
    -- Basic safety check for aquifer/water/magma
    if not is_safe_to_dig(x, y, z) then
        return false
    end
    
    -- INTELLIGENT HAZARD CHECK using terrain module
    local analysis = terrain.analyze_tile(x, y, z)
    if not analysis.safe then
        utils.log_debug(string.format(
            "BLOCKED dig at (%d,%d,%d): %s",
            x, y, z, analysis.reason or "unsafe"
        ), MANAGER_NAME)
        return false
    end
    
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then return false end
    
    local designation = block.designation[x % 16][y % 16]
    designation.dig = dig_type
    
    -- Mark the block as needing a job refresh
    block.flags.designated = true
    
    state.increment("stats.designations")
    return true
end

-------------------------------------------------------------------------------
-- Fortress Location
-------------------------------------------------------------------------------

--- Find the wagon/embark location (approximate fortress center)
local function find_fortress_center()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    -- If we already found it, return cached location
    if mgr_state.center_x then
        return mgr_state.center_x, mgr_state.center_y, mgr_state.center_z
    end
    
    -- Look for wagons or just use map center
    local x_max, y_max, z_max = utils.get_map_size()
    
    -- Try to find wagon
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Wagon then
            local cx = math.floor((building.x1 + building.x2) / 2)
            local cy = math.floor((building.y1 + building.y2) / 2)
            local cz = building.z
            
            -- Cache it
            mgr_state.center_x = cx
            mgr_state.center_y = cy
            mgr_state.center_z = cz
            state.set_manager_state(MANAGER_NAME, mgr_state)
            
            return cx, cy, cz
        end
    end
    
    -- Try to find a meeting hall zone using civzone_type
    local ok, _ = pcall(function()
        for _, zone in pairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if zone.type == df.civzone_type.MeetingHall or
               zone.type == df.civzone_type.MeetingArea then
                local cx = math.floor((zone.x1 + zone.x2) / 2)
                local cy = math.floor((zone.y1 + zone.y2) / 2)
                local cz = zone.z
                
                mgr_state.center_x = cx
                mgr_state.center_y = cy
                mgr_state.center_z = cz
                state.set_manager_state(MANAGER_NAME, mgr_state)
                
                return cx, cy, cz
            end
        end
    end)
    
    if mgr_state.center_x then
        return mgr_state.center_x, mgr_state.center_y, mgr_state.center_z
    end
    
    -- Fall back to map center at ground level
    -- Find the surface level by scanning
    local cx = math.floor(x_max / 2)
    local cy = math.floor(y_max / 2)
    local cz = z_max - 1
    
    -- Scan down to find a solid layer
    for z = z_max - 1, 0, -1 do
        local ttype = utils.get_tile_type(cx, cy, z)
        if ttype and is_diggable(ttype) then
            cz = z + 1  -- Start above the solid layer
            break
        end
    end
    
    mgr_state.center_x = cx
    mgr_state.center_y = cy
    mgr_state.center_z = cz
    state.set_manager_state(MANAGER_NAME, mgr_state)
    
    return cx, cy, cz
end

-------------------------------------------------------------------------------
-- Simple Dig Patterns
-------------------------------------------------------------------------------

--- Dig a horizontal corridor
local function dig_corridor(x1, y1, z, x2, y2)
    local count = 0
    local min_x = math.min(x1, x2)
    local max_x = math.max(x1, x2)
    local min_y = math.min(y1, y2)
    local max_y = math.max(y1, y2)
    
    for x = min_x, max_x do
        for y = min_y, max_y do
            local ttype = utils.get_tile_type(x, y, z)
            if is_diggable(ttype) and not has_dig_designation(x, y, z) then
                if designate_dig(x, y, z) then
                    count = count + 1
                end
            end
        end
    end
    
    return count
end

--- Dig a room (rectangular area)
local function dig_room(x, y, z, width, height)
    local half_w = math.floor(width / 2)
    local half_h = math.floor(height / 2)
    
    return dig_corridor(x - half_w, y - half_h, z, x + half_w, y + half_h)
end

--- Dig stairs down
local function dig_stairs_down(x, y, z)
    local ttype = utils.get_tile_type(x, y, z)
    if is_diggable(ttype) and not has_dig_designation(x, y, z) then
        designate_dig(x, y, z, df.tile_dig_designation.DownStair)
        return true
    end
    return false
end

--- Dig stairs up
local function dig_stairs_up(x, y, z)
    local ttype = utils.get_tile_type(x, y, z)
    if is_diggable(ttype) and not has_dig_designation(x, y, z) then
        designate_dig(x, y, z, df.tile_dig_designation.UpStair)
        return true
    end
    return false
end

--- Dig up/down stairs
local function dig_stairs_updown(x, y, z)
    local ttype = utils.get_tile_type(x, y, z)
    if is_diggable(ttype) and not has_dig_designation(x, y, z) then
        designate_dig(x, y, z, df.tile_dig_designation.UpDownStair)
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Initial Fortress Layout
--- Create a basic starter dig plan with proper surface access
--- INTELLIGENT APPROACH: Scans 360° for safest direction
--- Uses terrain module to avoid water/magma/aquifers
local function create_starter_layout()
    local wagon_x, wagon_y, wagon_z = find_fortress_center()
    if not wagon_x then return 0 end
    
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    -- Only do this once
    if mgr_state.starter_layout_complete then
        return 0
    end
    
    utils.log_action(MANAGER_NAME, "Creating starter fortress layout", 
        string.format("Wagon at: (%d, %d, %d)", wagon_x, wagon_y, wagon_z))
    
    local designations = 0
    local surface_z = wagon_z
    
    -- Step 1: USE TERRAIN MODULE to find safest direction
    -- This scans all 4 directions and picks the one with fewest hazards
    local best_dir, safety_score, hazards, all_scores = terrain.find_safest_direction(
        wagon_x, wagon_y, surface_z
    )
    
    if not best_dir then
        utils.log_error("CRITICAL: No safe direction found for dig!", MANAGER_NAME)
        return 0
    end
    
    -- Log the analysis
    utils.log(string.format("Direction analysis -> Best: %s (score: %d)", 
        best_dir, safety_score), MANAGER_NAME)
    
    if #hazards > 0 and #hazards <= 3 then
        for _, h in ipairs(hazards) do
            utils.log_debug("  Hazard: " .. h, MANAGER_NAME)
        end
    end
    
    -- Calculate entrance position based on best direction
    local entrance_x, entrance_y = wagon_x, wagon_y
    local direction_vectors = {
        north = {0, -10},
        south = {0, 10},
        east = {10, 0},
        west = {-10, 0}
    }
    local vec = direction_vectors[best_dir]
    entrance_x = wagon_x + vec[1]
    entrance_y = wagon_y + vec[2]
    local direction = best_dir
    
    utils.log_debug("  Entrance 10 tiles " .. direction .. " of wagon", MANAGER_NAME)
    
    -- Step 2: Find the first underground level (with diggable stone)
    local underground_z = nil
    for z = surface_z - 1, surface_z - 10, -1 do
        if is_safe_to_dig(entrance_x, entrance_y, z) then
            local ttype = utils.get_tile_type(entrance_x, entrance_y, z)
            if is_diggable(ttype) then
                underground_z = z
                break
            end
        end
    end
    
    if not underground_z then
        utils.log_warn("Could not find underground layer", MANAGER_NAME)
        return 0
    end
    
    utils.log_debug("  Underground at Z=" .. underground_z, MANAGER_NAME)
    
    -- Step 3: Channel from surface to underground (creates ramp)
    -- Channel each level from surface down to underground
    local channel_count = 0
    for z = surface_z, underground_z + 1, -1 do
        if is_safe_to_dig(entrance_x, entrance_y, z) then
            designate_dig(entrance_x, entrance_y, z, df.tile_dig_designation.Channel)
            channel_count = channel_count + 1
        end
    end
    designations = designations + channel_count
    utils.log_debug("  Channeled " .. channel_count .. " levels for ramp access", MANAGER_NAME)
    
    -- Step 4: Dig corridor at underground level from ramp
    local entry_z = underground_z
    local cx, cy = entrance_x, entrance_y
    
    -- Dig corridor extending away from wagon
    local corridor_len = 15
    local corridor_tiles = 0
    if direction == "north" then
        for i = 0, corridor_len do
            if is_diggable(utils.get_tile_type(cx, cy - i, entry_z)) then
                designate_dig(cx, cy - i, entry_z)
                corridor_tiles = corridor_tiles + 1
            end
        end
        cy = cy - corridor_len
    elseif direction == "south" then
        for i = 0, corridor_len do
            if is_diggable(utils.get_tile_type(cx, cy + i, entry_z)) then
                designate_dig(cx, cy + i, entry_z)
                corridor_tiles = corridor_tiles + 1
            end
        end
        cy = cy + corridor_len
    elseif direction == "west" then
        for i = 0, corridor_len do
            if is_diggable(utils.get_tile_type(cx - i, cy, entry_z)) then
                designate_dig(cx - i, cy, entry_z)
                corridor_tiles = corridor_tiles + 1
            end
        end
        cx = cx - corridor_len
    else  -- east
        for i = 0, corridor_len do
            if is_diggable(utils.get_tile_type(cx + i, cy, entry_z)) then
                designate_dig(cx + i, cy, entry_z)
                corridor_tiles = corridor_tiles + 1
            end
        end
        cx = cx + corridor_len
    end
    designations = designations + corridor_tiles
    utils.log_debug("  Entry corridor: " .. corridor_tiles .. " tiles", MANAGER_NAME)
    
    -- Step 5: Main fortress area at end of corridor
    -- Down stair at corridor end
    if is_diggable(utils.get_tile_type(cx, cy, entry_z)) then
        designate_dig(cx, cy, entry_z, df.tile_dig_designation.DownStair)
        designations = designations + 1
    end
    
    -- Cross corridors for workshops
    local cross1 = dig_corridor(cx - 10, cy, entry_z, cx + 10, cy)
    local cross2 = dig_corridor(cx, cy - 10, entry_z, cx, cy + 10)
    designations = designations + cross1 + cross2
    utils.log_debug("  Cross corridors: " .. (cross1 + cross2) .. " tiles", MANAGER_NAME)
    
    -- Workshop rooms (4x 5x5)
    local rooms = 0
    rooms = rooms + dig_room(cx - 8, cy - 3, entry_z, 5, 5)
    rooms = rooms + dig_room(cx - 8, cy + 3, entry_z, 5, 5)
    rooms = rooms + dig_room(cx + 8, cy - 3, entry_z, 5, 5)
    rooms = rooms + dig_room(cx + 8, cy + 3, entry_z, 5, 5)
    designations = designations + rooms
    utils.log_debug("  Workshop rooms: " .. rooms .. " tiles", MANAGER_NAME)
    
    -- Central hall
    local hall = dig_room(cx, cy, entry_z, 9, 9)
    designations = designations + hall
    utils.log_debug("  Central hall: " .. hall .. " tiles", MANAGER_NAME)
    
    -- Step 6: Lower level for storage
    local storage_z = entry_z - 1
    if is_safe_to_dig(cx, cy, storage_z) then
        -- Up/down stairs
        if is_diggable(utils.get_tile_type(cx, cy, storage_z)) then
            designate_dig(cx, cy, storage_z, df.tile_dig_designation.UpDownStair)
            designations = designations + 1
        end
        
        -- Storage corridors
        local s1 = dig_corridor(cx - 15, cy, storage_z, cx + 15, cy)
        local s2 = dig_corridor(cx, cy - 15, storage_z, cx, cy + 15)
        designations = designations + s1 + s2
        utils.log_debug("  Storage level: " .. (s1 + s2) .. " tiles", MANAGER_NAME)
    end
    
    -- Save state
    if designations > 0 then
        mgr_state.starter_layout_complete = true
        mgr_state.center_x = cx
        mgr_state.center_y = cy
        mgr_state.surface_z = surface_z
        mgr_state.entry_z = entry_z
        mgr_state.storage_z = storage_z
        state.set_manager_state(MANAGER_NAME, mgr_state)
        
        utils.log_action(MANAGER_NAME, "Layout complete", 
            designations .. " tiles designated")
        utils.track_designation(designations)
    end
    
    return designations
end

-------------------------------------------------------------------------------
-- Expansion Logic
-------------------------------------------------------------------------------

--- Count existing beds (placed buildings)
local function count_placed_beds()
    local count = 0
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Bed then
            count = count + 1
        end
    end
    return count
end

--- Dig a bedroom level (grid of small rooms with corridors)
local function dig_bedroom_level(z)
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    local cx = mgr_state.center_x
    local cy = mgr_state.center_y
    
    if not cx then return 0 end
    
    local designations = 0
    
    utils.log_action(MANAGER_NAME, "Digging bedroom level", "Z=" .. z)
    
    -- Main corridor through bedroom level
    designations = designations + dig_corridor(cx - 20, cy, z, cx + 20, cy)
    
    -- Side corridors
    designations = designations + dig_corridor(cx - 15, cy - 8, z, cx - 15, cy + 8)
    designations = designations + dig_corridor(cx + 15, cy - 8, z, cx + 15, cy + 8)
    designations = designations + dig_corridor(cx - 8, cy - 8, z, cx - 8, cy + 8)
    designations = designations + dig_corridor(cx + 8, cy - 8, z, cx + 8, cy + 8)
    
    -- Individual bedroom cells (3x3 each)
    -- Left section
    for offset_x = -18, -10, 4 do
        for offset_y = -6, 6, 4 do
            designations = designations + dig_room(cx + offset_x, cy + offset_y, z, 3, 3)
        end
    end
    
    -- Right section
    for offset_x = 10, 18, 4 do
        for offset_y = -6, 6, 4 do
            designations = designations + dig_room(cx + offset_x, cy + offset_y, z, 3, 3)
        end
    end
    
    return designations
end

--- Check if we need more bedroom space
local function needs_more_bedrooms()
    local population = utils.get_population()
    local beds = count_placed_beds()
    
    -- Need expansion if population exceeds beds
    return population > beds + 5  -- Buffer of 5
end

--- Dig additional storage rooms
local function expand_storage(z)
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    local cx = mgr_state.center_x
    local cy = mgr_state.center_y
    
    if not cx then return 0 end
    
    local designations = 0
    
    utils.log_action(MANAGER_NAME, "Expanding storage", "Z=" .. z)
    
    -- Extend corridors
    designations = designations + dig_corridor(cx - 30, cy, z, cx + 30, cy)
    designations = designations + dig_corridor(cx, cy - 25, z, cx, cy + 25)
    
    -- Large storage rooms
    designations = designations + dig_room(cx - 25, cy - 10, z, 8, 8)
    designations = designations + dig_room(cx - 25, cy + 10, z, 8, 8)
    designations = designations + dig_room(cx + 25, cy - 10, z, 8, 8)
    designations = designations + dig_room(cx + 25, cy + 10, z, 8, 8)
    
    return designations
end

--- Main expansion check
local function check_expansion()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    if not mgr_state.starter_layout_complete then
        return 0
    end
    
    local designations = 0
    local population = utils.get_population()
    
    -- Track expansion levels
    mgr_state.bedroom_levels = mgr_state.bedroom_levels or 0
    mgr_state.storage_expanded = mgr_state.storage_expanded or false
    
    -- Expand bedrooms if needed (every 15 dwarves, add a level)
    local needed_bedroom_levels = math.floor(population / 15)
    
    if needed_bedroom_levels > mgr_state.bedroom_levels then
        -- Dig new bedroom level below storage
        local bedroom_z = mgr_state.storage_z - 1 - mgr_state.bedroom_levels
        
        -- First add stairway
        dig_stairs_updown(mgr_state.center_x, mgr_state.center_y, bedroom_z)
        
        -- Then dig the level
        designations = dig_bedroom_level(bedroom_z)
        
        if designations > 0 then
            mgr_state.bedroom_levels = mgr_state.bedroom_levels + 1
            utils.log_action(MANAGER_NAME, "Bedroom level added",
                "Level " .. mgr_state.bedroom_levels .. ", " .. designations .. " tiles")
            utils.track_designation(designations)
        end
    end
    
    -- Expand storage once population hits 20
    if population >= 20 and not mgr_state.storage_expanded then
        local storage_designations = expand_storage(mgr_state.storage_z)
        if storage_designations > 0 then
            mgr_state.storage_expanded = true
            designations = designations + storage_designations
            utils.log_action(MANAGER_NAME, "Storage expanded", 
                storage_designations .. " tiles")
            utils.track_designation(storage_designations)
        end
    end
    
    state.set_manager_state(MANAGER_NAME, mgr_state)
    return designations
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Create dynamic fortress using planner
local function create_dynamic_fortress()
    local wagon_x, wagon_y, wagon_z = find_fortress_center()
    if not wagon_x then 
        utils.log_debug("No wagon found for dynamic planning", MANAGER_NAME)
        return 0 
    end
    
    local population = utils.get_population() or 7
    
    utils.log_action(MANAGER_NAME, "Generating dynamic fortress plan", 
        "Population: " .. population)
    
    -- Generate plan
    local plan = planner.generate_fortress_plan(wagon_x, wagon_y, wagon_z, population)
    
    if not plan or not plan.tiles or #plan.tiles == 0 then
        utils.log_warn("Dynamic planner returned no tiles", MANAGER_NAME)
        return 0
    end
    
    -- Queue all dig designations
    local designations = 0
    for _, tile in ipairs(plan.tiles) do
        local dig_type = df.tile_dig_designation.Default
        
        if tile.dig_type == "channel" then
            dig_type = df.tile_dig_designation.Channel
        elseif tile.dig_type == "ramp" then
            dig_type = df.tile_dig_designation.Ramp
        elseif tile.stair_type == "up" then
            dig_type = df.tile_dig_designation.UpStair
        elseif tile.stair_type == "down" then
            dig_type = df.tile_dig_designation.DownStair
        elseif tile.stair_type == "updown" then
            dig_type = df.tile_dig_designation.UpDownStair
        end
        
        -- Get tile type first
        local ttype = utils.get_tile_type(tile.x, tile.y, tile.z)
        local shape = nil
        if ttype then
            pcall(function()
                shape = df.tiletype.attrs[ttype].shape
            end)
        end
        
        -- Designate based on what the tile is
        local designated = false
        
        if is_diggable(ttype) then
            -- Standard diggable tile (rock, soil)
            designate_dig(tile.x, tile.y, tile.z, dig_type)
            designated = true
        elseif tile.dig_type == "channel" or tile.dig_type == "ramp" then
            -- Channels and ramps can be placed on floor tiles or grass
            local is_floor = shape and (shape == df.tiletype_shape.FLOOR or 
                                        shape == df.tiletype_shape.SHRUB or
                                        shape == df.tiletype_shape.SAPLING or
                                        shape == df.tiletype_shape.BOULDER or
                                        shape == df.tiletype_shape.PEBBLES)
            if is_floor then
                pcall(function()
                    designate_dig(tile.x, tile.y, tile.z, dig_type)
                end)
                designated = true
            end
        end
        
        if designated then
            designations = designations + 1
        end
    end
    
    -- Save state
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    mgr_state.starter_layout_complete = true
    mgr_state.center_x = plan.center_x
    mgr_state.center_y = plan.center_y
    mgr_state.entry_z = plan.entry_z
    mgr_state.surface_z = plan.entry_z + 1
    mgr_state.storage_z = plan.entry_z - 1
    mgr_state.direction = plan.direction
    mgr_state.using_dynamic_planner = true
    state.set_manager_state(MANAGER_NAME, mgr_state)
    
    -- Save plan to planner state
    planner.save_plan_to_state(plan)
    
    utils.log_action(MANAGER_NAME, "Dynamic layout complete", 
        designations .. " tiles designated, " .. (plan.graph and "with room graph" or "tiles only"))
    utils.track_designation(designations)
    
    return designations
end

--- Main update function
function update()
    if not config.get("mining.auto_expand", true) then
        return
    end
    
    local current_tick = df.global.cur_year_tick
    if current_tick - last_check < CHECK_INTERVAL then
        return
    end
    last_check = current_tick
    
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    -- Validate state - if layout is "complete" but no center coordinates, reset it
    if mgr_state.starter_layout_complete and not mgr_state.center_x then
        utils.log_debug("Mining state corrupted - resetting", MANAGER_NAME)
        mgr_state.starter_layout_complete = false
        state.set_manager_state(MANAGER_NAME, mgr_state)
    end
    
    -- Create starter layout if not done
    if not mgr_state.starter_layout_complete then
        utils.log_debug("Starting layout creation...", MANAGER_NAME)
        
        local designations = 0
        if USE_DYNAMIC_PLANNER then
            -- Use new dynamic planner
            designations = create_dynamic_fortress()
        else
            -- Use legacy static layout
            designations = create_starter_layout()
        end
        
        if designations > 0 then
            utils.log("Mining: designated " .. designations .. " tiles")
        else
            utils.log_debug("Layout returned 0 designations", MANAGER_NAME)
        end
    end
    
    -- Check for expansion needs
    if mgr_state.starter_layout_complete then
        if USE_DYNAMIC_PLANNER and mgr_state.using_dynamic_planner then
            -- Use planner-based expansion
            local population = utils.get_population() or 7
            local military_count = 0
            
            -- Check if planner recommends expansion
            local needs_expansion = false
            pcall(function()
                needs_expansion = planner.should_expand(population)
            end)
            
            if needs_expansion then
                -- Get expansion recommendation
                local recommendations = {}
                pcall(function()
                    recommendations = planner.get_expansion_recommendation(population, military_count)
                end)
                
                if #recommendations > 0 then
                    utils.log_action(MANAGER_NAME, "Expansion needed",
                        "Population " .. population .. " exceeds capacity, need " .. recommendations[1].count .. " " .. recommendations[1].type)
                    
                    -- Fall back to basic expansion for now
                    -- Future: use planner.expand_fortress()
                    check_expansion()
                end
            end
        else
            check_expansion()
        end
    end
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    if not mgr_state.starter_layout_complete then
        return "planning"
    end
    
    local bedroom_levels = mgr_state.bedroom_levels or 0
    local storage = mgr_state.storage_expanded and "expanded" or "normal"
    
    return string.format("layout ok, bedrooms:%d lvls, storage:%s", 
        bedroom_levels, storage)
end

return _ENV
