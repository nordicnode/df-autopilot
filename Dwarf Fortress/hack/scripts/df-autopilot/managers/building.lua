-- df-autopilot/managers/building.lua
-- Building and construction management
-- Handles furniture and structure construction

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "building"
local last_check = 0
local CHECK_INTERVAL = 500

-------------------------------------------------------------------------------
-- Furniture Counting
-------------------------------------------------------------------------------

--- Count tables (both item and placed)
local function count_tables()
    local items = utils.count_items(df.item_type.TABLE, nil)
    local placed = #utils.get_buildings(df.building_type.Table, nil)
    return items, placed
end

--- Count chairs/thrones
local function count_chairs()
    local items = utils.count_items(df.item_type.CHAIR, nil)
    local placed = #utils.get_buildings(df.building_type.Chair, nil)
    return items, placed
end

--- Count doors
local function count_doors()
    local items = utils.count_items(df.item_type.DOOR, nil)
    local placed = #utils.get_buildings(df.building_type.Door, nil)
    return items, placed
end

--- Count cabinets
local function count_cabinets()
    local items = utils.count_items(df.item_type.CABINET, nil)
    local placed = #utils.get_buildings(df.building_type.Cabinet, nil)
    return items, placed
end

--- Count chests/coffers
local function count_chests()
    local items = utils.count_items(df.item_type.BOX, nil)
    local placed = #utils.get_buildings(df.building_type.Box, nil)
    return items, placed
end

--- Count statues
local function count_statues()
    local items = utils.count_items(df.item_type.STATUE, nil)
    local placed = #utils.get_buildings(df.building_type.Statue, nil)
    return items, placed
end

-------------------------------------------------------------------------------
-- Workshop Detection
-------------------------------------------------------------------------------

--- Check if we have required workshops
local function check_required_workshops()
    local missing = {}
    
    local required = {
        {type = df.workshop_type.Carpenters, name = "Carpenter's Workshop"},
        {type = df.workshop_type.Masons, name = "Mason's Workshop"},
        {type = df.workshop_type.Craftsdwarfs, name = "Craftdwarf's Workshop"},
        {type = df.workshop_type.Mechanics, name = "Mechanic's Workshop"},
        {type = df.workshop_type.Still, name = "Still"},
        {type = df.workshop_type.Kitchen, name = "Kitchen"},
        {type = df.workshop_type.Farmers, name = "Farmer's Workshop"},
        {type = df.workshop_type.Butchers, name = "Butcher's Shop"},
    }
    
    for _, ws in ipairs(required) do
        if utils.count_workshops(ws.type) == 0 then
            table.insert(missing, ws)
        end
    end
    
    return missing
end

-------------------------------------------------------------------------------
-- Furniture Production
-------------------------------------------------------------------------------

--- Queue table production
local function ensure_tables()
    local items, placed = count_tables()
    local population = utils.get_population()
    
    -- Need enough tables for dining (1 per 2 dwarves)
    local needed = math.ceil(population / 2) - (items + placed)
    
    if needed > 0 and not utils.order_exists(df.job_type.ConstructTable, 0) then
        local to_make = math.min(needed, 5)
        utils.create_order(df.job_type.ConstructTable, to_make)
        state.increment("stats.orders_created")
        return to_make
    end
    return 0
end

--- Queue chair production
local function ensure_chairs()
    local items, placed = count_chairs()
    local population = utils.get_population()
    
    -- Need enough chairs for dining (1 per 2 dwarves) 
    local needed = math.ceil(population / 2) - (items + placed)
    
    if needed > 0 and not utils.order_exists(df.job_type.ConstructThrone, 0) then
        local to_make = math.min(needed, 5)
        utils.create_order(df.job_type.ConstructThrone, to_make)
        state.increment("stats.orders_created")
        return to_make
    end
    return 0
end

--- Queue door production  
local function ensure_doors()
    local items, placed = count_doors()
    
    -- Keep a reserve of doors
    local needed = 10 - items
    
    if needed > 0 and not utils.order_exists(df.job_type.ConstructDoor, 0) then
        local to_make = math.min(needed, 5)
        utils.create_order(df.job_type.ConstructDoor, to_make)
        state.increment("stats.orders_created")
        return to_make
    end
    return 0
end

--- Queue cabinet production (for bedrooms)
local function ensure_cabinets()
    local items, placed = count_cabinets()
    local population = utils.get_population()
    
    -- Need cabinets for bedrooms (1 per citizen)
    local needed = population - (items + placed)
    
    if needed > 0 and not utils.order_exists(df.job_type.ConstructCabinet, 0) then
        local to_make = math.min(needed, 5)
        utils.create_order(df.job_type.ConstructCabinet, to_make)
        state.increment("stats.orders_created")
        return to_make
    end
    return 0
end

--- Queue chest production (for bedrooms)
local function ensure_chests()
    local items, placed = count_chests()
    local population = utils.get_population()
    
    -- Need chests for bedrooms (1 per citizen)
    local needed = population - (items + placed)
    
    if needed > 0 and not utils.order_exists(df.job_type.ConstructChest, 0) then
        local to_make = math.min(needed, 5)
        utils.create_order(df.job_type.ConstructChest, to_make)
        state.increment("stats.orders_created")
        return to_make
    end
    return 0
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
    
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    -- Count furniture
    local table_items, table_placed = count_tables()
    local chair_items, chair_placed = count_chairs()
    local door_items, door_placed = count_doors()
    local cabinet_items, cabinet_placed = count_cabinets()
    local chest_items, chest_placed = count_chests()
    
    mgr_state.tables = table_items + table_placed
    mgr_state.chairs = chair_items + chair_placed
    mgr_state.doors = door_items + door_placed
    mgr_state.cabinets = cabinet_items + cabinet_placed
    mgr_state.chests = chest_items + chest_placed
    
    -- Check for missing workshops
    local missing_workshops = check_required_workshops()
    mgr_state.missing_workshop_count = #missing_workshops
    
    if #missing_workshops > 0 then
        -- Log missing workshops (but not too often)
        if not mgr_state.last_workshop_log or 
           current_tick - mgr_state.last_workshop_log > 5000 then
            for _, ws in ipairs(missing_workshops) do
                utils.log_debug("Missing workshop: " .. ws.name)
            end
            mgr_state.last_workshop_log = current_tick
        end
    end
    
    mgr_state.last_check = current_tick
    state.set_manager_state(MANAGER_NAME, mgr_state)
    
    -- Ensure furniture production
    ensure_tables()
    ensure_chairs()
    ensure_doors()
    ensure_cabinets()
    ensure_chests()
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state.tables then
        return "waiting"
    end
    
    local status = string.format("tables: %d, chairs: %d, doors: %d",
        mgr_state.tables or 0,
        mgr_state.chairs or 0,
        mgr_state.doors or 0
    )
    
    if mgr_state.missing_workshop_count and mgr_state.missing_workshop_count > 0 then
        status = status .. string.format(" [missing %d workshops]", mgr_state.missing_workshop_count)
    end
    
    return status
end

return _ENV
