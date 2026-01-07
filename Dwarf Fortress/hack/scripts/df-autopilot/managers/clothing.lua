-- df-autopilot/managers/clothing.lua
-- Clothing management - integrates with DFHack tailor

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "clothing"
local last_check = 0
local CHECK_INTERVAL = 1000

-------------------------------------------------------------------------------
-- Clothing Analysis
-------------------------------------------------------------------------------

--- Count clothing items by condition
local function analyze_clothing()
    local stats = {
        total = 0,
        worn = 0,  -- In use by dwarves
        available = 0,  -- In stockpiles
        tattered = 0,  -- >50% wear
        ragged = 0  -- Badly worn
    }
    
    local ok, _ = pcall(function()
        local lists = {
            df.items_other_id.ARMOR,
            df.items_other_id.SHOES,
            df.items_other_id.HELM,
            df.items_other_id.GLOVES,
            df.items_other_id.PANTS
        }

        for _, list_id in ipairs(lists) do
            for _, item in pairs(df.global.world.items.other[list_id]) do
                if utils.is_valid_item(item) then
                    stats.total = stats.total + 1
                    
                    if item.flags.in_inventory then
                        stats.worn = stats.worn + 1
                    else
                        stats.available = stats.available + 1
                    end
                    
                    -- Check wear level
                    local wear = item.wear
                    if wear >= 2 then
                        stats.ragged = stats.ragged + 1
                    elseif wear >= 1 then
                        stats.tattered = stats.tattered + 1
                    end
                end
            end
        end
    end)
    
    return stats
end

--- Count naked/underdressed dwarves
local function count_underdressed_dwarves()
    local count = 0
    
    local ok, _ = pcall(function()
        local citizens = utils.get_citizens()
        
        for _, unit in ipairs(citizens) do
            local has_shirt = false
            local has_pants = false
            local has_shoes = false
            
            -- Check inventory for clothing
            for _, inv_item in pairs(unit.inventory) do
                if inv_item.mode == df.unit_inventory_item.T_mode.Worn then
                    local item = inv_item.item
                    local itype = item:getType()
                    
                    if itype == df.item_type.ARMOR then has_shirt = true end
                    if itype == df.item_type.PANTS then has_pants = true end
                    if itype == df.item_type.SHOES then has_shoes = true end
                end
            end
            
            if not has_shirt or not has_pants or not has_shoes then
                count = count + 1
            end
        end
    end)
    
    return count
end

-------------------------------------------------------------------------------
-- Tailor Integration
-------------------------------------------------------------------------------

--- Check if tailor is running
local function is_tailor_active()
    local ok, result = pcall(function()
        local output = dfhack.run_command_silent("tailor status")
        return output and (output:find("enabled") ~= nil or output:find("Running") ~= nil)
    end)
    
    return ok and result
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
    
    -- Analyze clothing
    local stats = analyze_clothing()
    mgr_state.total = stats.total
    mgr_state.worn = stats.worn
    mgr_state.available = stats.available
    mgr_state.tattered = stats.tattered
    mgr_state.ragged = stats.ragged
    
    -- Count underdressed
    mgr_state.underdressed = count_underdressed_dwarves()
    
    -- Check tailor status
    mgr_state.tailor_active = is_tailor_active()
    
    -- Warn if dwarves underdressed and tailor not active
    if mgr_state.underdressed > 0 and not mgr_state.tailor_active then
        if not mgr_state.warned_underdressed then
            utils.log_warn(mgr_state.underdressed .. " dwarves need clothing - enable tailor!")
            mgr_state.warned_underdressed = true
        end
    else
        mgr_state.warned_underdressed = false
    end
    
    mgr_state.last_check = current_tick
    state.set_manager_state(MANAGER_NAME, mgr_state)
end

function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state or not mgr_state.total then
        return "waiting"
    end
    
    local status = string.format("clothing: %d (%d available)",
        mgr_state.total or 0,
        mgr_state.available or 0
    )
    
    if mgr_state.underdressed and mgr_state.underdressed > 0 then
        status = status .. ", " .. mgr_state.underdressed .. " need clothes"
    end
    
    if mgr_state.ragged and mgr_state.ragged > 0 then
        status = status .. ", " .. mgr_state.ragged .. " ragged"
    end
    
    return status
end

return _ENV
