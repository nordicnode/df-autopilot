-- df-autopilot/managers/labor.lua
-- Labor assignment management for v53.08+
-- Delegates to DFHack's autolabor plugin which handles Work Details

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "labor"
local last_check = 0
local CHECK_INTERVAL = 2000 -- Check less frequently

-------------------------------------------------------------------------------
-- Autolabor Integration
-------------------------------------------------------------------------------

-- Track if we've enabled autolabor
local autolabor_enabled = false
local labormanager_enabled = false

--- Check if autolabor plugin is available and running
local function is_autolabor_running()
    local ok, result = pcall(function()
        -- Check if autolabor or labormanager is enabled
        local help_output = dfhack.run_command_silent("autolabor")
        return help_output and not help_output:match("not found")
    end)
    
    if ok then return result end
    return false
end

--- Enable autolabor plugin
local function enable_autolabor()
    local ok, result = pcall(function()
        -- Try autolabor first
        local success = dfhack.run_command_silent("autolabor enable")
        if success then
            autolabor_enabled = true
            utils.log_action(MANAGER_NAME, "Enabled autolabor", "DFHack autolabor managing labor assignments")
            return true
        end
        return false
    end)
    
    if ok and result then return true end
    
    -- Try labormanager as fallback
    ok, result = pcall(function()
        local success = dfhack.run_command_silent("labormanager enable")
        if success then
            labormanager_enabled = true
            utils.log_action(MANAGER_NAME, "Enabled labormanager", "DFHack labormanager managing labor assignments")
            return true
        end
        return false
    end)
    
    if ok and result then return true end
    return false
end

--- Get autolabor status
local function get_autolabor_status()
    local ok, result = pcall(function()
        if autolabor_enabled then
            return "autolabor active"
        elseif labormanager_enabled then
            return "labormanager active"
        else
            return dfhack.run_command_silent("autolabor") or "unknown"
        end
    end)
    
    if ok and result then
        if result:match("is enabled") or result:match("Running") then
            return "running"
        elseif result:match("is disabled") then
            return "disabled"
        end
    end
    return "unknown"
end

-------------------------------------------------------------------------------
-- Population Tracking (for status display)
-------------------------------------------------------------------------------

--- Count citizens by basic categories
local function categorize_population()
    local citizens = utils.get_citizens()
    local counts = {
        total = 0,
        idle = 0,
        busy = 0,
        military = 0
    }
    
    for _, unit in ipairs(citizens) do
        counts.total = counts.total + 1
        
        if unit.military.squad_id >= 0 then
            counts.military = counts.military + 1
        elseif not unit.job.current_job then
            counts.idle = counts.idle + 1
        else
            counts.busy = counts.busy + 1
        end
    end
    
    return counts
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Main update function
function update()
    if not config.get("labor.auto_assign", true) then
        return
    end
    
    local current_tick = df.global.cur_year_tick
    if current_tick - last_check < CHECK_INTERVAL then
        return
    end
    last_check = current_tick
    
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    -- Enable autolabor if not already done
    if not mgr_state.autolabor_checked then
        local status = get_autolabor_status()
        if status == "disabled" or status == "unknown" then
            enable_autolabor()
        elseif status == "running" then
            autolabor_enabled = true
            utils.log_debug("Autolabor already running", MANAGER_NAME)
        end
        mgr_state.autolabor_checked = true
    end
    
    -- Track population stats
    local counts = categorize_population()
    mgr_state.population = counts.total
    mgr_state.idle = counts.idle
    mgr_state.busy = counts.busy
    mgr_state.military = counts.military
    mgr_state.autolabor_running = autolabor_enabled or labormanager_enabled
    mgr_state.last_check = current_tick
    
    state.set_manager_state(MANAGER_NAME, mgr_state)
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    local pop = mgr_state.population or 0
    local idle = mgr_state.idle or 0
    
    local labor_mode = "manual"
    if mgr_state.autolabor_running then
        labor_mode = "autolabor"
    end
    
    return string.format("pop:%d idle:%d [%s]", pop, idle, labor_mode)
end

return _ENV
