-- df-autopilot/managers/wood.lua
-- Wood management - integrates with DFHack autochop

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "wood"
local last_check = 0
local CHECK_INTERVAL = 1000

-------------------------------------------------------------------------------
-- Wood Counting
-------------------------------------------------------------------------------

--- Count logs in stockpiles
local function count_logs()
    local count = 0
    
    local ok, _ = pcall(function()
        -- Try specific WOOD list first (faster)
        local items = df.global.world.items.other[df.items_other_id.WOOD] 
        -- Fallback to IN_PLAY if WOOD list is empty/invalid (unlikely but safe)
        if not items or #items == 0 then
            items = df.global.world.items.other[df.items_other_id.IN_PLAY]
        end

        for _, item in pairs(items) do
            if item:getType() == df.item_type.WOOD and utils.is_valid_item(item) then
                count = count + item:getStackSize()
            end
        end
    end)
    
    return count
end

--- Count trees on the map
local function count_trees()
    local count = 0
    
    local ok, _ = pcall(function()
        -- Count plants that are trees
        for _, plant in pairs(df.global.world.plants.all) do
            if plant.tree_info then
                count = count + 1
            end
        end
    end)
    
    return count
end

--- Count designated trees (marked for chopping)
local function count_designated_trees()
    local count = 0
    
    local ok, _ = pcall(function()
        for _, plant in pairs(df.global.world.plants.all) do
            if plant.tree_info then
                local x, y, z = plant.pos.x, plant.pos.y, plant.pos.z
                local designation = dfhack.maps.getTileFlags(x, y, z)
                if designation and designation.dig == df.tile_dig_designation.Default then
                    count = count + 1
                end
            end
        end
    end)
    
    return count
end

-------------------------------------------------------------------------------
-- Autochop Integration
-------------------------------------------------------------------------------

--- Check if autochop is running
local function is_autochop_active()
    local ok, result = pcall(function()
        local output = dfhack.run_command_silent("autochop status")
        return output and (output:find("enabled") ~= nil or output:find("Running") ~= nil)
    end)
    
    return ok and result
end

--- Set autochop target
local function set_autochop_target(min_logs, max_logs)
    local ok, _ = pcall(function()
        dfhack.run_command_silent(string.format("autochop target %d %d", min_logs, max_logs))
    end)
    return ok
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function update()
    local current_tick = df.global.cur_year_tick
    if current_tick - last_check < CHECK_INTERVAL then
        return
    end
    last_check = current_tick
    
    local mgr_state = state.get_manager_state(MANAGER_NAME) or {}
    
    -- Count wood resources
    mgr_state.logs = count_logs()
    mgr_state.trees = count_trees()
    mgr_state.designated = count_designated_trees()
    
    -- Check autochop status
    mgr_state.autochop_active = is_autochop_active()
    
    -- Configure autochop targets if active and not yet configured
    if mgr_state.autochop_active and not mgr_state.targets_set then
        local min_logs = config.get("wood.min_logs", 50)
        local max_logs = config.get("wood.max_logs", 100)
        set_autochop_target(min_logs, max_logs)
        mgr_state.targets_set = true
        utils.log_action(MANAGER_NAME, "Set autochop targets", min_logs .. "-" .. max_logs)
    end
    
    -- Warn if low on wood and autochop not active
    local min_warning = config.get("wood.min_warning", 20)
    if mgr_state.logs < min_warning and not mgr_state.autochop_active then
        if not mgr_state.warned_low then
            utils.log_warn("Low on wood (" .. mgr_state.logs .. " logs) - enable autochop!")
            mgr_state.warned_low = true
        end
    else
        mgr_state.warned_low = false
    end
    
    mgr_state.last_check = current_tick
    state.set_manager_state(MANAGER_NAME, mgr_state)
end

function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state or not mgr_state.logs then
        return "waiting"
    end
    
    local status = string.format("logs: %d, trees: %d",
        mgr_state.logs or 0,
        mgr_state.trees or 0
    )
    
    if mgr_state.designated and mgr_state.designated > 0 then
        status = status .. ", " .. mgr_state.designated .. " designated"
    end
    
    if not mgr_state.autochop_active then
        status = status .. " [autochop off]"
    end
    
    return status
end

return _ENV
