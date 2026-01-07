-- df-autopilot/utils.lua
-- Utility functions for the AI

--@ module = true

local config = reqscript("df-autopilot/config")

-------------------------------------------------------------------------------
-- Logging System
-------------------------------------------------------------------------------

local LOG_LEVELS = {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    error = 4
}

-- Log buffer for file output
local log_buffer = {}
local MAX_BUFFER_SIZE = 100
local log_file_path = "dfhack-config/df-autopilot/autopilot.log"

-- Activity tracking for periodic reports
local activity_log = {
    orders_created = {},
    designations = 0,
    labors_assigned = 0,
    threats_detected = 0,
    bedrooms_assigned = 0,
    last_report_tick = 0
}

local function get_log_level()
    local level_name = config.get("log_level", "info")
    return LOG_LEVELS[level_name] or LOG_LEVELS.info
end

local function get_timestamp()
    local year = df.global.cur_year
    local tick = df.global.cur_year_tick
    -- Convert ticks to season/day/time
    local ticks_per_day = 1200
    local days_per_month = 28
    local months_per_year = 12
    
    local day_of_year = math.floor(tick / ticks_per_day)
    local month = math.floor(day_of_year / days_per_month) + 1
    local day = (day_of_year % days_per_month) + 1
    
    local seasons = {"Spring", "Summer", "Autumn", "Winter"}
    local season = seasons[math.floor((month - 1) / 3) + 1] or "???"
    
    return string.format("Y%d %s D%d", year, season, day)
end

local function format_log(level, message, manager)
    local timestamp = get_timestamp()
    local manager_str = manager and ("[" .. manager .. "]") or ""
    return string.format("[df-autopilot][%s][%s]%s %s", timestamp, level, manager_str, message)
end

-- Write to log file (immediate flush for real-time visibility)
local function write_to_log_file(formatted_message)
    local ok, err = pcall(function()
        local file = io.open(log_file_path, "a")
        if file then
            file:write(formatted_message .. "\n")
            file:flush()
            file:close()
        end
    end)
end

--- Flush the log buffer to file (kept for compatibility)
function flush_log_buffer()
    -- Now writes immediately, nothing to flush
end

--- Broadcast log entry to overlay widget
local function broadcast_to_overlay(level, message, manager)
    local ok, overlay_module = pcall(reqscript, "df-autopilot-overlay")
    if ok and overlay_module and overlay_module.add_log_entry then
        overlay_module.add_log_entry(level, message, manager)
    end
end

--- Log a trace message (very verbose)
function log_trace(message, manager)
    if get_log_level() <= LOG_LEVELS.trace then
        local formatted = format_log("TRACE", message, manager)
        print(formatted)
        write_to_log_file(formatted)
        broadcast_to_overlay("TRACE", message, manager)
    end
end

--- Log a debug message
function log_debug(message, manager)
    if get_log_level() <= LOG_LEVELS.debug then
        local formatted = format_log("DEBUG", message, manager)
        print(formatted)
        write_to_log_file(formatted)
        broadcast_to_overlay("DEBUG", message, manager)
    end
end

--- Log an info message
function log(message, manager)
    if get_log_level() <= LOG_LEVELS.info then
        local formatted = format_log("INFO", message, manager)
        print(formatted)
        write_to_log_file(formatted)
        broadcast_to_overlay("INFO", message, manager)
    end
end

--- Log a warning message
function log_warn(message, manager)
    if get_log_level() <= LOG_LEVELS.warn then
        local formatted = format_log("WARN", message, manager)
        print(formatted)
        write_to_log_file(formatted)
        broadcast_to_overlay("WARN", message, manager)
    end
end

--- Log an error message
function log_error(message, manager)
    if get_log_level() <= LOG_LEVELS.error then
        local formatted = format_log("ERROR", message, manager)
        dfhack.printerr(formatted)
        write_to_log_file(formatted)
        broadcast_to_overlay("ERROR", message, manager)
    end
end

-------------------------------------------------------------------------------
-- Activity Tracking
-------------------------------------------------------------------------------

--- Track an order being created
function track_order(job_type, amount)
    local job_name = tostring(df.job_type[job_type])
    if not activity_log.orders_created[job_name] then
        activity_log.orders_created[job_name] = 0
    end
    activity_log.orders_created[job_name] = activity_log.orders_created[job_name] + amount
end

--- Track designations made
function track_designation(count)
    activity_log.designations = (activity_log.designations or 0) + (count or 1)
end

--- Track labor assignments
function track_labor_assignment(count)
    activity_log.labors_assigned = (activity_log.labors_assigned or 0) + (count or 1)
end

--- Track threats
function track_threat()
    activity_log.threats_detected = (activity_log.threats_detected or 0) + 1
end

--- Track bedroom assignments
function track_bedroom_assignment(count)
    activity_log.bedrooms_assigned = (activity_log.bedrooms_assigned or 0) + (count or 1)
end

-------------------------------------------------------------------------------
-- Periodic Status Reports
-------------------------------------------------------------------------------

--- Generate and print a status report
function print_status_report(managers)
    local current_tick = df.global.cur_year_tick
    local report_interval = config.get("status_report_interval", 5000)
    
    -- Only report periodically
    if current_tick - activity_log.last_report_tick < report_interval then
        return
    end
    activity_log.last_report_tick = current_tick
    
    -- Build the report
    local lines = {}
    table.insert(lines, "")
    table.insert(lines, "+================================================================+")
    table.insert(lines, "|              DF-AUTOPILOT STATUS REPORT                       |")
    table.insert(lines, "+================================================================+")
    
    -- Population
    local population = get_population()
    local idle = #get_idle_dwarves()
    table.insert(lines, string.format("| Population: %-5d  Idle: %-5d                                |", population, idle))
    table.insert(lines, "+----------------------------------------------------------------+")
    
    -- Manager statuses
    if managers then
        for name, mgr in pairs(managers) do
            if mgr and mgr.get_status then
                local ok, status = pcall(mgr.get_status)
                if ok and status then
                    local padded_name = name .. string.rep(" ", 12 - #name)
                    local padded_status = status:sub(1, 46)
                    padded_status = padded_status .. string.rep(" ", 46 - #padded_status)
                    table.insert(lines, string.format("| %s: %s |", padded_name, padded_status))
                end
            end
        end
    end
    
    table.insert(lines, "+----------------------------------------------------------------+")
    
    -- Recent activity summary
    local has_activity = false
    if next(activity_log.orders_created) then
        table.insert(lines, "| Recent Orders:                                                |")
        for job_name, amount in pairs(activity_log.orders_created) do
            local short_name = job_name:sub(1, 40)
            table.insert(lines, string.format("|   %-40s x%-5d             |", short_name, amount))
        end
        has_activity = true
    end
    
    if activity_log.designations > 0 then
        table.insert(lines, string.format("| Tiles Designated: %-43d |", activity_log.designations))
        has_activity = true
    end
    
    if activity_log.labors_assigned > 0 then
        table.insert(lines, string.format("| Labors Assigned: %-44d |", activity_log.labors_assigned))
        has_activity = true
    end
    
    if activity_log.bedrooms_assigned > 0 then
        table.insert(lines, string.format("| Bedrooms Assigned: %-42d |", activity_log.bedrooms_assigned))
        has_activity = true
    end
    
    if not has_activity then
        table.insert(lines, "| No major activity this period                                 |")
    end
    
    table.insert(lines, "+================================================================+")
    table.insert(lines, "")
    
    -- Print all lines
    for _, line in ipairs(lines) do
        print(line)
    end
    
    -- Write to log file
    for _, line in ipairs(lines) do
        write_to_log_file(line)
    end
    
    -- Reset activity counters
    activity_log.orders_created = {}
    activity_log.designations = 0
    activity_log.labors_assigned = 0
    activity_log.bedrooms_assigned = 0
end

-------------------------------------------------------------------------------
-- Verbose Action Logging
-------------------------------------------------------------------------------

--- Log a manager action with full details
function log_action(manager, action, details)
    local msg = string.format("%s: %s", action, details or "")
    log(msg, manager)
end

--- Log a manager decision with reasoning
function log_decision(manager, decision, reason)
    local msg = string.format("DECISION: %s | Reason: %s", decision, reason)
    log_debug(msg, manager)
end

--- Log when a manager skips an action
function log_skip(manager, action, reason)
    local msg = string.format("Skipping %s: %s", action, reason)
    log_trace(msg, manager)
end

-------------------------------------------------------------------------------
-- Unit Helpers
-------------------------------------------------------------------------------

--- Get all living citizens
-- @return Table of citizen units
function get_citizens()
    local citizens = {}
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) then
            table.insert(citizens, unit)
        end
    end
    return citizens
end

--- Get population count
-- @return Number of living citizens
function get_population()
    return #get_citizens()
end

--- Get idle dwarves (no current job)
-- @return Table of idle citizen units
function get_idle_dwarves()
    local idle = {}
    for _, unit in pairs(get_citizens()) do
        if not unit.job.current_job then
            table.insert(idle, unit)
        end
    end
    return idle
end

--- Check if a unit has a specific labor enabled
-- @param unit The unit to check
-- @param labor The labor to check (e.g., df.unit_labor.MINE)
-- @return boolean
function has_labor(unit, labor)
    return unit.status.labors[labor]
end

--- Enable a labor for a unit
-- @param unit The unit to modify
-- @param labor The labor to enable
function enable_labor(unit, labor)
    unit.status.labors[labor] = true
end

--- Disable a labor for a unit
-- @param unit The unit to modify
-- @param labor The labor to disable
function disable_labor(unit, labor)
    unit.status.labors[labor] = false
end

-------------------------------------------------------------------------------
-- Item Helpers
-------------------------------------------------------------------------------

--- Check if an item is valid (not rotten, forbidden, etc.)
-- @param item The item to check
-- @return boolean
function is_valid_item(item)
    local flags = item.flags
    if flags.rotten or flags.trader or flags.hostile or flags.forbid
        or flags.dump or flags.on_fire or flags.garbage_collect 
        or flags.owned or flags.removed or flags.encased 
        or flags.spider_web or flags.in_building then
        return false
    end
    return true
end

--- Count items of a specific type
-- @param item_type The item type (e.g., df.item_type.FOOD)
-- @param subtype Optional subtype filter
-- @return Total count (considering stack sizes)
function count_items(item_type, subtype)
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if item:getType() == item_type and is_valid_item(item) then
            if subtype == nil or item:getSubtype() == subtype then
                count = count + item:getStackSize()
            end
        end
    end
    return count
end

--- Count empty containers of a type
-- @param item_type The container type (e.g., df.item_type.BIN)
-- @return Number of empty containers
function count_empty_containers(item_type)
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if item:getType() == item_type and is_valid_item(item) then
            -- Check if container is empty
            if #item.general_refs == 0 then
                count = count + 1
            end
        end
    end
    return count
end

-------------------------------------------------------------------------------
-- Building Helpers
-------------------------------------------------------------------------------

--- Get all buildings of a type
-- @param building_type The building type (e.g., df.building_type.Workshop)
-- @param subtype Optional subtype
-- @return Table of buildings
function get_buildings(building_type, subtype)
    local buildings = {}
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == building_type then
            if subtype == nil or building:getSubtype() == subtype then
                table.insert(buildings, building)
            end
        end
    end
    return buildings
end

--- Count workshops of a specific type
-- @param workshop_type The workshop subtype
-- @return Number of workshops
function count_workshops(workshop_type)
    local count = 0
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Workshop then
            if building:getSubtype() == workshop_type then
                count = count + 1
            end
        end
    end
    return count
end

-------------------------------------------------------------------------------
-- Manager Order Helpers
-------------------------------------------------------------------------------

--- Check if a similar order already exists
-- @param job_type The job type to check
-- @param amount_threshold Only count if order has more than this amount
-- @return boolean
function order_exists(job_type, amount_threshold)
    amount_threshold = amount_threshold or 0
    for _, order in pairs(df.global.world.manager_orders.all) do
        if order.job_type == job_type and order.amount_left > amount_threshold then
            return true
        end
    end
    return false
end

--- Create a simple work order (v53.08 compatible)
-- @param job_type The job type
-- @param amount Number of items to produce
-- @return The created order, or nil if failed
function create_order(job_type, amount)
    if not job_type or not amount or amount <= 0 then
        log_debug("Invalid order parameters: job_type=" .. tostring(job_type) .. " amount=" .. tostring(amount))
        return nil
    end
    
    if order_exists(job_type, 0) then
        log_skip("orders", "create order", "already exists for " .. tostring(df.job_type[job_type]))
        return nil
    end
    
    local ok, result = pcall(function()
        local order = df.manager_order:new()
        
        -- Core fields
        order.id = df.global.world.manager_orders.manager_order_next_id
        df.global.world.manager_orders.manager_order_next_id = 
            df.global.world.manager_orders.manager_order_next_id + 1
        
        order.job_type = job_type
        order.amount_left = amount
        order.amount_total = amount
        
        -- v53.08 required fields
        order.frequency = df.workquota_frequency_type.OneTime
        order.status.validated = true
        order.status.active = true
        
        -- Material settings (default: any)
        order.mat_type = -1
        order.mat_index = -1
        order.item_type = -1
        order.item_subtype = -1
        
        df.global.world.manager_orders.all:insert('#', order)
        
        return order
    end)
    
    if not ok then
        log_error("Failed to create order: " .. tostring(result))
        return nil
    end
    
    -- Track and log
    local job_name = tostring(df.job_type[job_type])
    track_order(job_type, amount)
    log_action("orders", "Created work order", job_name .. " x" .. amount)
    
    return result
end

-------------------------------------------------------------------------------
-- Map Helpers
-------------------------------------------------------------------------------

--- Get the map dimensions
-- @return x_size, y_size, z_size
function get_map_size()
    local ok, x, y, z = pcall(function()
        return df.global.world.map.x_count,
               df.global.world.map.y_count,
               df.global.world.map.z_count
    end)
    if ok then
        return x, y, z
    end
    return 0, 0, 0
end

--- Check if a position is valid on the map
-- @param x, y, z The position
-- @return boolean
function is_valid_pos(x, y, z)
    if x == nil or y == nil or z == nil then return false end
    local x_max, y_max, z_max = get_map_size()
    if x_max == nil or y_max == nil or z_max == nil then return false end
    return x >= 0 and x < x_max and
           y >= 0 and y < y_max and
           z >= 0 and z < z_max
end

--- Get tile type at position
-- @param x, y, z The position
-- @return tile type or nil
function get_tile_type(x, y, z)
    if not is_valid_pos(x, y, z) then return nil end
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then return nil end
    return block.tiletype[x % 16][y % 16]
end

-------------------------------------------------------------------------------
-- Stockpile Helpers
-------------------------------------------------------------------------------

--- Get all stockpiles
-- @return Table of stockpile buildings
function get_stockpiles()
    local stockpiles = {}
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Stockpile then
            table.insert(stockpiles, building)
        end
    end
    return stockpiles
end

return _ENV
