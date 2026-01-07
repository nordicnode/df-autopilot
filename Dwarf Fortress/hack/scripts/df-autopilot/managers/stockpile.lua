-- df-autopilot/managers/stockpile.lua
-- Stockpile management
-- Monitors stockpile usage and provides recommendations

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "stockpile"
local last_check = 0
local CHECK_INTERVAL = 1000

-------------------------------------------------------------------------------
-- Stockpile Types
-------------------------------------------------------------------------------

local STOCKPILE_TYPES = {
    "Food",
    "Furniture",
    "Corpses", 
    "Refuse",
    "Stone",
    "Wood",
    "Gems",
    "Bars/Blocks",
    "Cloth",
    "Leather",
    "Ammo",
    "Coins",
    "Finished Goods",
    "Weapons",
    "Armor",
    "Animals"
}

-------------------------------------------------------------------------------
-- Stockpile Analysis
-------------------------------------------------------------------------------

--- Get all stockpiles
local function get_stockpiles()
    local stockpiles = {}
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Stockpile then
            table.insert(stockpiles, building)
        end
    end
    return stockpiles
end

--- Count stockpiles by rough category
local function count_stockpile_types()
    local counts = {
        food = 0,
        furniture = 0,
        stone = 0,
        wood = 0,
        bars = 0,
        cloth = 0,
        leather = 0,
        finished = 0,
        weapons = 0,
        armor = 0,
        refuse = 0,
        corpses = 0,
        animals = 0,
        gems = 0,
        ammo = 0,
        coins = 0,
        other = 0,
        total = 0
    }
    
    local stockpiles = get_stockpiles()
    counts.total = #stockpiles
    
    for _, sp in ipairs(stockpiles) do
        -- Try to determine stockpile type from settings
        local ok, _ = pcall(function()
            local settings = sp.settings
            if settings then
                -- Check various flags to categorize
                if settings.flags.food then counts.food = counts.food + 1
                elseif settings.flags.furniture then counts.furniture = counts.furniture + 1
                elseif settings.flags.stone then counts.stone = counts.stone + 1
                elseif settings.flags.wood then counts.wood = counts.wood + 1
                elseif settings.flags.bars_blocks then counts.bars = counts.bars + 1
                elseif settings.flags.cloth then counts.cloth = counts.cloth + 1
                elseif settings.flags.leather then counts.leather = counts.leather + 1
                elseif settings.flags.finished_goods then counts.finished = counts.finished + 1
                elseif settings.flags.weapons then counts.weapons = counts.weapons + 1
                elseif settings.flags.armor then counts.armor = counts.armor + 1
                elseif settings.flags.refuse then counts.refuse = counts.refuse + 1
                elseif settings.flags.corpses then counts.corpses = counts.corpses + 1
                elseif settings.flags.animals then counts.animals = counts.animals + 1
                elseif settings.flags.gems then counts.gems = counts.gems + 1
                elseif settings.flags.ammo then counts.ammo = counts.ammo + 1
                elseif settings.flags.coins then counts.coins = counts.coins + 1
                else counts.other = counts.other + 1
                end
            end
        end)
        
        if not ok then
            counts.other = counts.other + 1
        end
    end
    
    return counts
end

--- Get recommended stockpiles that are missing
local function get_missing_stockpiles()
    local counts = count_stockpile_types()
    local missing = {}
    
    -- Essential stockpiles
    if counts.food == 0 then
        table.insert(missing, "Food stockpile (for food/drinks)")
    end
    if counts.furniture == 0 then
        table.insert(missing, "Furniture stockpile (for beds, tables, etc.)")
    end
    if counts.stone == 0 then
        table.insert(missing, "Stone stockpile (for masons)")
    end
    if counts.wood == 0 then
        table.insert(missing, "Wood stockpile (for carpenters)")
    end
    if counts.bars == 0 then
        table.insert(missing, "Bars/Blocks stockpile (for metalsmithing)")
    end
    if counts.finished == 0 then
        table.insert(missing, "Finished Goods stockpile (for crafts)")
    end
    if counts.refuse == 0 then
        table.insert(missing, "Refuse stockpile (OUTSIDE for bones/shells)")
    end
    
    return missing
end

--- Calculate approximate stockpile fullness
local function estimate_stockpile_usage()
    -- This is a rough estimate based on item counts
    local items_in_stockpiles = 0
    local total_items = 0
    
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if utils.is_valid_item(item) then
            total_items = total_items + 1
            -- Items in stockpiles typically have certain flags
            if not item.flags.on_ground then
                items_in_stockpiles = items_in_stockpiles + 1
            end
        end
    end
    
    return items_in_stockpiles, total_items
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
    
    -- Count stockpiles
    local counts = count_stockpile_types()
    mgr_state.stockpile_counts = counts
    
    -- Get missing recommendations
    local missing = get_missing_stockpiles()
    mgr_state.missing_stockpiles = missing
    
    -- Estimate usage
    local in_stockpiles, total = estimate_stockpile_usage()
    mgr_state.items_in_stockpiles = in_stockpiles
    mgr_state.total_items = total
    
    mgr_state.last_check = current_tick
    
    state.set_manager_state(MANAGER_NAME, mgr_state)
    
    -- Log recommendations occasionally
    if #missing > 0 then
        if not mgr_state.last_warning_tick or
           current_tick - mgr_state.last_warning_tick > 20000 then
            utils.log_debug("Missing stockpiles:")
            for _, m in ipairs(missing) do
                utils.log_debug("  - " .. m)
            end
            mgr_state.last_warning_tick = current_tick
            state.set_manager_state(MANAGER_NAME, mgr_state)
        end
    end
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state.stockpile_counts then
        return "waiting"
    end
    
    local counts = mgr_state.stockpile_counts
    local total = counts.total or 0
    local missing = mgr_state.missing_stockpiles or {}
    
    if #missing > 0 then
        return string.format("total: %d [missing %d types]", total, #missing)
    end
    
    return string.format("total: %d stockpiles", total)
end

return _ENV
