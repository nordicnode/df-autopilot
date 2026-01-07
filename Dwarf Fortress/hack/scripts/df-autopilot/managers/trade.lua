-- df-autopilot/managers/trade.lua
-- Trade and diplomacy management
-- Handles caravan detection and trade preparation

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "trade"
local last_check = 0
local CHECK_INTERVAL = 500

-------------------------------------------------------------------------------
-- Caravan Detection
-------------------------------------------------------------------------------

--- Check if a trade depot exists
local function has_trade_depot()
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.TradeDepot then
            return true, building
        end
    end
    return false, nil
end

--- Check if caravan is present by looking for merchant units
local function is_caravan_present()
    -- Check for merchant units
    for _, unit in pairs(df.global.world.units.active) do
        local ok, is_merchant = pcall(dfhack.units.isMerchant, unit)
        if ok and is_merchant and dfhack.units.isAlive(unit) then
            return true
        end
    end
    
    return false
end

--- Get caravan info from announcements
local function get_caravan_info()
    local info = {
        human = false,
        dwarven = false,
        elven = false,
        present = false
    }
    
    local reports = df.global.world.status.reports
    if #reports > 0 then
        local start_idx = math.max(0, #reports - 50)
        for i = start_idx, #reports - 1 do
            local report = reports[i]
            if report and report.text then
                local text = dfhack.df2utf(report.text):lower()
                if text:find("caravan") or text:find("merchants") then
                    info.present = true
                    if text:find("human") then info.human = true end
                    if text:find("dwarven") or text:find("dwarf") then info.dwarven = true end
                    if text:find("elven") or text:find("elf") then info.elven = true end
                end
            end
        end
    end
    
    return info
end

-------------------------------------------------------------------------------
-- Trade Goods Management  
-------------------------------------------------------------------------------

--- Count craftable trade goods
local function count_trade_goods()
    local count = 0
    
    -- Count crafts using the items list
    local ok, _ = pcall(function()
        for _, item in pairs(df.global.world.items.other[df.items_other_id.ANY_CRAFTS]) do
            if utils.is_valid_item(item) and not item.flags.foreign then
                count = count + 1
            end
        end
    end)
    
    -- Fallback: count by iterating all items
    if not ok then
        for _, item in pairs(df.global.world.items.all) do
            if utils.is_valid_item(item) then
                local itype = item:getType()
                if itype == df.item_type.FIGURINE or
                   itype == df.item_type.AMULET or
                   itype == df.item_type.SCEPTER or
                   itype == df.item_type.CROWN or
                   itype == df.item_type.RING or
                   itype == df.item_type.EARRING or
                   itype == df.item_type.BRACELET then
                    count = count + 1
                end
            end
        end
    end
    
    return count
end

--- Queue craft production for trade
local function ensure_trade_goods()
    local goods = count_trade_goods()
    
    -- Keep at least 50 crafts on hand for trading
    local min_goods = 50
    local needed = min_goods - goods
    
    if needed > 0 then
        -- Queue rock crafts (most common material)
        if not utils.order_exists(df.job_type.MakeCrafts, 0) then
            local to_make = math.min(needed, 20)
            utils.create_order(df.job_type.MakeCrafts, to_make)
            state.increment("stats.orders_created")
            return to_make
        end
    end
    
    return 0
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Main update function
function update()
    if not config.get("trade.auto_trade", true) then
        return
    end
    
    local current_tick = df.global.cur_year_tick
    if current_tick - last_check < CHECK_INTERVAL then
        return
    end
    last_check = current_tick
    
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    -- Check trade depot
    local depot_exists, depot = has_trade_depot()
    mgr_state.has_depot = depot_exists
    
    -- Check for caravan
    local caravan_present = is_caravan_present()
    local caravan_info = get_caravan_info()
    
    mgr_state.caravan_present = caravan_present or caravan_info.present
    mgr_state.caravan_info = caravan_info
    
    -- Count trade goods
    local trade_goods = count_trade_goods()
    mgr_state.trade_goods = trade_goods
    
    mgr_state.last_check = current_tick
    
    state.set_manager_state(MANAGER_NAME, mgr_state)
    
    -- Alert if caravan arrived
    if mgr_state.caravan_present and not mgr_state.last_caravan_alert then
        utils.log("CARAVAN ARRIVED - Traders are at the depot")
        mgr_state.last_caravan_alert = true
        
        if not depot_exists then
            utils.log_warn("WARNING: No trade depot! Build one to trade.")
        end
        
        state.set_manager_state(MANAGER_NAME, mgr_state)
    elseif not mgr_state.caravan_present and mgr_state.last_caravan_alert then
        mgr_state.last_caravan_alert = false
        state.set_manager_state(MANAGER_NAME, mgr_state)
    end
    
    -- Ensure we have trade goods ready
    ensure_trade_goods()
    
    -- Log if no depot (occasionally)
    if not depot_exists and not mgr_state.depot_warned then
        utils.log_debug("Recommendation: Build a trade depot for caravans")
        mgr_state.depot_warned = true
        state.set_manager_state(MANAGER_NAME, mgr_state)
    end
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state.has_depot then
        return "no depot"
    end
    
    if mgr_state.caravan_present then
        return string.format("CARAVAN! goods: %d", mgr_state.trade_goods or 0)
    end
    
    return string.format("goods: %d", mgr_state.trade_goods or 0)
end

return _ENV
