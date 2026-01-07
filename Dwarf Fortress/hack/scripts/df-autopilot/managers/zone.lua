-- df-autopilot/managers/zone.lua
-- Zone management (bedrooms, dining, meeting areas)
-- Creates and manages zones for dwarf needs

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")
local planner = nil  -- Loaded lazily to avoid circular dependency

local MANAGER_NAME = "zone"
local last_check = 0
local CHECK_INTERVAL = 1000

-- Try to load planner (may not be present)
local function get_planner()
    if planner then return planner end
    local ok, p = pcall(function()
        return reqscript("df-autopilot/fortress_planner")
    end)
    if ok and p then
        planner = p
    end
    return planner
end

-------------------------------------------------------------------------------
-- Helper Functions (v50+ compatible)
-------------------------------------------------------------------------------

--- Safely check if a building is a room
local function building_is_room(building)
    -- Try multiple approaches for v50+ compatibility
    
    -- Try room.extents approach
    local ok1, _ = pcall(function()
        if building.room and building.room.extents then
            return true
        end
    end)
    if ok1 then
        local ok2, val = pcall(function() 
            return building.room and building.room.extents 
        end)
        if ok2 and val then return true end
    end
    
    -- Try is_room field
    local ok3, val3 = pcall(function() return building.is_room end)
    if ok3 and val3 then return true end
    
    return false
end

--- Safely get building owner
local function get_building_owner(building)
    local ok, val = pcall(function() return building.owner end)
    if ok then
        return val or -1
    end
    return -1
end

-------------------------------------------------------------------------------
-- Zone Detection (v50+ compatible)
-------------------------------------------------------------------------------

--- Check if a meeting area exists
local function has_meeting_area()
    local ok, result = pcall(function()
        for _, zone in pairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if zone.type == df.civzone_type.MeetingHall or
               zone.type == df.civzone_type.MeetingArea then
                return true
            end
        end
        return false
    end)
    
    if ok then return result end
    return #df.global.world.buildings.other.ACTIVITY_ZONE > 0
end

--- Check if a dining room exists (room with tables/chairs)
local function has_dining_room()
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Table then
            if building_is_room(building) then
                return true
            end
        end
    end
    return false
end

--- Check if a hospital zone exists
local function has_hospital()
    local ok, result = pcall(function()
        for _, zone in pairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if zone.type == df.civzone_type.Hospital then
                return true
            end
        end
        return false
    end)
    
    if ok then return result end
    return false
end

--- Count assigned bedrooms
local function count_bedrooms()
    local count = 0
    local assigned = 0
    
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Bed then
            if building_is_room(building) then
                count = count + 1
                local owner = get_building_owner(building)
                if owner ~= -1 then
                    assigned = assigned + 1
                end
            end
        end
    end
    
    return count, assigned
end

--- Count beds (not made into rooms)
local function count_unassigned_beds()
    local count = 0
    
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Bed then
            if not building_is_room(building) then
                count = count + 1
            end
        end
    end
    
    return count
end

--- Count pasture zones
local function count_pastures()
    local count = 0
    local ok, _ = pcall(function()
        for _, zone in pairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if zone.type == df.civzone_type.Pasture or
               zone.type == df.civzone_type.PenPasture then
                count = count + 1
            end
        end
    end)
    return count
end

-------------------------------------------------------------------------------
-- Zone Creation
-------------------------------------------------------------------------------

--- Get the fortress main level from mining state
local function get_main_level()
    local mining_state = state.get_manager_state("mining")
    if mining_state and mining_state.main_z then
        return mining_state.center_x, mining_state.center_y, mining_state.main_z
    end
    return nil, nil, nil
end

--- Create an activity zone at a location (v53.08 compatible)
local function create_zone(x, y, z, width, height, zone_type)
    local ok, result = pcall(function()
        -- Create a new activity zone building
        local zone = df.building_civzonest:new()
        
        zone.race = df.global.plotinfo.race_id
        zone.x1 = x
        zone.y1 = y
        zone.x2 = x + width - 1
        zone.y2 = y + height - 1
        zone.z = z
        
        -- Set zone type
        zone.type = zone_type
        zone.is_active = true
        
        -- Check if tiles are free (v53.08 uses building pointer)
        local tiles_ok = true
        local check_ok, check_result = pcall(function()
            return dfhack.buildings.checkFreeTiles(zone)
        end)
        if check_ok then
            tiles_ok = check_result
        end
        
        if not tiles_ok then
            zone:delete()
            return nil
        end
        
        -- Use dfhack.buildings API to insert (handles ID and linking)
        local insert_ok, insert_result = pcall(function()
            return dfhack.buildings.insert(zone)
        end)
        
        if insert_ok and insert_result then
            return zone
        end
        
        -- Fallback: manual insertion if dfhack.buildings.insert not available
        zone.id = df.global.building_next_id
        df.global.building_next_id = df.global.building_next_id + 1
        
        df.global.world.buildings.all:insert('#', zone)
        df.global.world.buildings.other.ACTIVITY_ZONE:insert('#', zone)
        
        -- Try to link into world
        pcall(function() dfhack.buildings.linkIntoWorld(zone) end)
        
        return zone
    end)
    
    if ok and result then
        return result
    end
    return nil
end

--- Create a meeting area zone
local function create_meeting_area()
    if has_meeting_area() then
        return false
    end
    
    local cx, cy, z = get_main_level()
    if not cx then
        utils.log_debug("No main level for meeting area", MANAGER_NAME)
        return false
    end
    
    -- Create meeting area at fortress center (11x11)
    local zone = create_zone(cx - 5, cy - 5, z, 11, 11, df.civzone_type.MeetingHall)
    if zone then
        utils.log_action(MANAGER_NAME, "Created meeting area",
            "11x11 at (" .. (cx-5) .. ", " .. (cy-5) .. ", " .. z .. ")")
        return true
    end
    
    return false
end

--- Create a hospital zone
local function create_hospital()
    if has_hospital() then
        return false
    end
    
    local cx, cy, z = get_main_level()
    if not cx then
        utils.log_debug("No main level for hospital", MANAGER_NAME)
        return false
    end
    
    -- Create hospital near center but offset (5x5)
    local zone = create_zone(cx + 8, cy - 5, z, 5, 5, df.civzone_type.Hospital)
    if zone then
        utils.log_action(MANAGER_NAME, "Created hospital zone",
            "5x5 at (" .. (cx+8) .. ", " .. (cy-5) .. ", " .. z .. ")")
        return true
    end
    
    return false
end

--- Check if a tavern exists
local function has_tavern()
    local ok, result = pcall(function()
        for _, zone in pairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if zone.type == df.civzone_type.Tavern or
               zone.type == df.civzone_type.Inn then
                return true
            end
        end
        return false
    end)
    
    if ok then return result end
    return false
end

--- Check if a temple exists
local function has_temple()
    local ok, result = pcall(function()
        for _, zone in pairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if zone.type == df.civzone_type.Temple then
                return true
            end
        end
        return false
    end)
    
    if ok then return result end
    return false
end

--- Create a tavern zone
local function create_tavern()
    if has_tavern() then
        return false
    end
    
    local cx, cy, z = get_main_level()
    if not cx then
        utils.log_debug("No main level for tavern", MANAGER_NAME)
        return false
    end
    
    -- Create tavern on main level offset from center (7x7)
    local zone = create_zone(cx - 12, cy + 8, z, 7, 7, df.civzone_type.Tavern)
    if zone then
        utils.log_action(MANAGER_NAME, "Created tavern zone",
            "7x7 at (" .. (cx-12) .. ", " .. (cy+8) .. ", " .. z .. ")")
        return true
    end
    
    return false
end

--- Create a temple zone
local function create_temple()
    if has_temple() then
        return false
    end
    
    local cx, cy, z = get_main_level()
    if not cx then
        utils.log_debug("No main level for temple", MANAGER_NAME)
        return false
    end
    
    -- Create temple on main level offset from center (5x5)
    local zone = create_zone(cx + 12, cy + 8, z, 5, 5, df.civzone_type.Temple)
    if zone then
        utils.log_action(MANAGER_NAME, "Created temple zone",
            "5x5 at (" .. (cx+12) .. ", " .. (cy+8) .. ", " .. z .. ")")
        return true
    end
    
    return false
end

--- Make a bed into a room
local function make_bed_room(bed_building)
    local ok, result = pcall(function()
        if not bed_building then return false end
        if building_is_room(bed_building) then return false end
        
        -- Set up room extents (3x3 around bed)
        local x, y, z = bed_building.x1, bed_building.y1, bed_building.z
        
        bed_building.is_room = 1
        bed_building.room.x = x - 1
        bed_building.room.y = y - 1
        bed_building.room.width = 3
        bed_building.room.height = 3
        bed_building.room.extents = df.new('uint8_t', 9)
        for i = 0, 8 do
            bed_building.room.extents[i] = 1
        end
        
        return true
    end)
    
    if ok then return result end
    return false
end

--- Assign a bed (room) to a dwarf
local function assign_bed_to_dwarf(bed_building, unit)
    local ok, result = pcall(function()
        if not bed_building or not unit then return false end
        
        -- Make it a room first if needed
        if not building_is_room(bed_building) then
            make_bed_room(bed_building)
        end
        
        -- Assign owner
        bed_building.owner = unit.id
        
        return true
    end)
    
    if ok then return result end
    return false
end

--- Log zone recommendations
local function recommend_zones()
    local population = utils.get_population()
    local recommendations = {}
    
    if not has_meeting_area() then
        table.insert(recommendations, "Create a meeting area (zone > meeting area)")
    end
    
    if not has_dining_room() then
        table.insert(recommendations, "Create a dining room (place tables/chairs, define room)")
    end
    
    if not has_hospital() then
        table.insert(recommendations, "Create a hospital zone")
    end
    
    local bedrooms, assigned = count_bedrooms()
    local needed_bedrooms = population - bedrooms
    if needed_bedrooms > 0 then
        table.insert(recommendations, 
            string.format("Need %d more bedrooms (%d/%d)", needed_bedrooms, bedrooms, population))
    end
    
    return recommendations
end

-------------------------------------------------------------------------------
-- Room Assignment
-------------------------------------------------------------------------------

--- Get dwarves without bedrooms
local function get_homeless_dwarves()
    local homeless = {}
    local citizens = utils.get_citizens()
    
    for _, unit in ipairs(citizens) do
        local has_room = false
        
        -- Check if this dwarf owns a bedroom
        for _, building in pairs(df.global.world.buildings.all) do
            if building:getType() == df.building_type.Bed then
                if building_is_room(building) and get_building_owner(building) == unit.id then
                    has_room = true
                    break
                end
            end
        end
        
        if not has_room and not dfhack.units.isChild(unit) and not dfhack.units.isBaby(unit) then
            table.insert(homeless, unit)
        end
    end
    
    return homeless
end

--- Find unassigned bedroom
local function find_unassigned_bedroom()
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Bed then
            if building_is_room(building) and get_building_owner(building) == -1 then
                return building
            end
        end
    end
    return nil
end

--- Assign bedroom to dwarf
local function assign_bedroom(bed, unit)
    if bed and unit then
        local ok, _ = pcall(function()
            bed.owner = unit.id
        end)
        return ok
    end
    return false
end

--- Automatically assign unassigned bedrooms to homeless dwarves
local function auto_assign_bedrooms()
    local ok, homeless = pcall(get_homeless_dwarves)
    if not ok or not homeless then return 0 end
    
    local assigned = 0
    
    for _, unit in ipairs(homeless) do
        local bed = find_unassigned_bedroom()
        if bed then
            if assign_bedroom(bed, unit) then
                assigned = assigned + 1
                utils.log_debug("Assigned bedroom to " .. dfhack.units.getReadableName(unit))
            end
        else
            break
        end
    end
    
    if assigned > 0 then
        utils.log("Assigned " .. assigned .. " bedrooms to homeless dwarves")
    end
    
    return assigned
end

-------------------------------------------------------------------------------
-- Planner-based Zone Creation
-------------------------------------------------------------------------------

--- Create zone for a planned room
local function create_zone_for_room(room)
    if not room or room.zone_created then
        return false
    end
    
    local fp = get_planner()
    if not fp then
        return false
    end
    
    -- Get zone type for this room
    local zone_type_str = fp.get_zone_type_for_room(room.room_type.id)
    if not zone_type_str then
        return false
    end
    
    -- Map string to DF zone type
    local zone_type_map = {
        bedroom = df.civzone_type.Bedroom,
        dormitory = df.civzone_type.Dormitory,
        dining_hall = df.civzone_type.DiningHall,
        hospital = df.civzone_type.Hospital,
        tavern = df.civzone_type.Tavern,
        temple = df.civzone_type.Temple,
        library = df.civzone_type.Library,
        barracks = df.civzone_type.Barracks,
        training = df.civzone_type.ArcheryRange,  -- Close enough
        jail = df.civzone_type.Dungeon,
        tomb = df.civzone_type.Tomb,
        pasture = df.civzone_type.Pasture,
        meeting_hall = df.civzone_type.MeetingHall,
    }
    
    local zone_type = zone_type_map[zone_type_str]
    if not zone_type then
        return false
    end
    
    -- Create the zone
    local zone = create_zone(room.x, room.y, room.z, room.width, room.height, zone_type)
    
    if zone then
        room.zone_created = true
        utils.log_action(MANAGER_NAME, "Created zone for planned room",
            room.room_type.name .. " at (" .. room.x .. ", " .. room.y .. ", " .. room.z .. ")")
        return true
    end
    
    return false
end

--- Process planner rooms that are ready for zones
local function process_planner_zones()
    local fp = get_planner()
    if not fp then
        return 0
    end
    
    -- Get rooms from planner state
    local rooms = fp.get_rooms_from_state()
    if not rooms or #rooms == 0 then
        return 0
    end
    
    local zones_created = 0
    
    for _, room in ipairs(rooms) do
        -- Skip if zone already created
        if room.zone_created then
            goto continue
        end
        
        -- Check if this room type needs a zone
        local zone_type_str = fp.get_zone_type_for_room(room.type_id)
        if not zone_type_str then
            goto continue
        end
        
        -- Check if room is dug out (simplified check for stored rooms)
        local tiles_dug = 0
        local total_tiles = room.width * room.height
        
        for dx = 0, room.width - 1 do
            for dy = 0, room.height - 1 do
                local ok, ttype = pcall(function()
                    return utils.get_tile_type(room.x + dx, room.y + dy, room.z)
                end)
                
                if ok and ttype then
                    local ok2, shape = pcall(function()
                        return df.tiletype.attrs[ttype].shape
                    end)
                    
                    if ok2 and (shape == df.tiletype_shape.FLOOR or 
                                shape == df.tiletype_shape.STAIR_UP or
                                shape == df.tiletype_shape.STAIR_DOWN or
                                shape == df.tiletype_shape.STAIR_UPDOWN) then
                        tiles_dug = tiles_dug + 1
                    end
                end
            end
        end
        
        -- Only create zone if 80% dug
        if tiles_dug < total_tiles * 0.8 then
            goto continue
        end
        
        -- Map string to DF zone type
        local zone_type_map = {
            bedroom = df.civzone_type.Bedroom,
            dormitory = df.civzone_type.Dormitory,
            dining_hall = df.civzone_type.DiningHall,
            hospital = df.civzone_type.Hospital,
            tavern = df.civzone_type.Tavern,
            temple = df.civzone_type.Temple,
            library = df.civzone_type.Library,
            barracks = df.civzone_type.Barracks,
            training = df.civzone_type.ArcheryRange,
            jail = df.civzone_type.Dungeon,
            tomb = df.civzone_type.Tomb,
            pasture = df.civzone_type.Pasture,
            meeting_hall = df.civzone_type.MeetingHall,
        }
        
        local zone_type = zone_type_map[zone_type_str]
        if not zone_type then
            goto continue
        end
        
        -- Create the zone
        local zone = create_zone(room.x, room.y, room.z, room.width, room.height, zone_type)
        
        if zone then
            fp.mark_room_zone_created(room.id)
            zones_created = zones_created + 1
            utils.log_action(MANAGER_NAME, "Created zone from planner",
                room.type_name .. " (" .. room.width .. "x" .. room.height .. ") at Z=" .. room.z)
        end
        
        ::continue::
    end
    
    return zones_created
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Main update function
function update()
    local current_tick = df.global.cur_year_tick
    if current_tick - last_check < CHECK_INTERVAL then
        return
    end
    last_check = current_tick
    
    local population = utils.get_population()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    -- Check zone status (wrapped in pcall for safety)
    local ok1, meeting = pcall(has_meeting_area)
    local ok2, dining = pcall(has_dining_room)
    local ok3, hospital = pcall(has_hospital)
    
    mgr_state.has_meeting_area = ok1 and meeting or false
    mgr_state.has_dining_room = ok2 and dining or false
    mgr_state.has_hospital = ok3 and hospital or false
    
    local ok4, bedrooms, assigned = pcall(count_bedrooms)
    if ok4 then
        mgr_state.bedroom_count = bedrooms
        mgr_state.assigned_bedrooms = assigned
    else
        mgr_state.bedroom_count = 0
        mgr_state.assigned_bedrooms = 0
    end
    mgr_state.population = population
    
    local ok5, pastures = pcall(count_pastures)
    mgr_state.pasture_count = ok5 and pastures or 0
    
    local ok6, unassigned = pcall(count_unassigned_beds)
    mgr_state.unassigned_beds = ok6 and unassigned or 0
    
    mgr_state.last_check = current_tick
    
    -- Auto-create missing zones (wrapped for safety)
    if config.get("zone.auto_create", true) then
        if not mgr_state.has_meeting_area then
            pcall(create_meeting_area)
        end
        
        if not mgr_state.has_hospital then
            pcall(create_hospital)
        end
        
        -- Auto-create tavern and temple (for happiness)
        local ok_tavern, has_tav = pcall(has_tavern)
        if ok_tavern and not has_tav then
            pcall(create_tavern)
        end
        
        local ok_temple, has_temp = pcall(has_temple)
        if ok_temple and not has_temp then
            pcall(create_temple)
        end
        
        -- Process zones from fortress planner (dug rooms need zones)
        local ok_planner, planner_zones = pcall(process_planner_zones)
        if ok_planner and planner_zones and planner_zones > 0 then
            mgr_state.planner_zones_created = (mgr_state.planner_zones_created or 0) + planner_zones
        end
    end
    
    -- Auto-assign bedrooms (wrapped for safety)
    pcall(auto_assign_bedrooms)
    
    -- Log recommendations (less frequently)
    if not mgr_state.last_recommendation_tick or 
       current_tick - mgr_state.last_recommendation_tick > 10000 then
        local ok7, recommendations = pcall(recommend_zones)
        if ok7 and recommendations and #recommendations > 0 then
            utils.log_debug("Zone recommendations:")
            for _, rec in ipairs(recommendations) do
                utils.log_debug("  - " .. rec)
            end
        end
        mgr_state.last_recommendation_tick = current_tick
    end
    
    state.set_manager_state(MANAGER_NAME, mgr_state)
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state.bedroom_count then
        return "waiting"
    end
    
    local status = string.format("bedrooms: %d/%d",
        mgr_state.assigned_bedrooms or 0,
        mgr_state.population or 0
    )
    
    local missing = {}
    if not mgr_state.has_meeting_area then
        table.insert(missing, "meeting")
    end
    if not mgr_state.has_hospital then
        table.insert(missing, "hospital")
    end
    
    if #missing > 0 then
        status = status .. " [need: " .. table.concat(missing, ", ") .. "]"
    end
    
    return status
end

return _ENV
