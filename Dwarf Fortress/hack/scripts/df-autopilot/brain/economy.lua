-- df-autopilot/brain/economy.lua
-- Economic management: production chains, trade, resources

--@ module = true

local utils = reqscript("df-autopilot/utils")
local state = reqscript("df-autopilot/state")

-------------------------------------------------------------------------------
-- Production Chains
-------------------------------------------------------------------------------

PRODUCTION_CHAINS = {
    {name = "wood_to_charcoal", input = {item = df.item_type.WOOD, min = 20}, 
     output = {item = df.item_type.BAR, min = 5}, workshop = "WoodFurnace"},
    {name = "plant_to_meal", input = {item = df.item_type.PLANT, min = 30},
     output = {item = df.item_type.FOOD, min = 20}, workshop = "Kitchen"},
    {name = "plant_to_drink", input = {item = df.item_type.PLANT, min = 20},
     output = {item = df.item_type.DRINK, min = 30}, workshop = "Still"},
    {name = "thread_to_cloth", input = {item = df.item_type.THREAD, min = 10},
     output = {item = df.item_type.CLOTH, min = 5}, workshop = "Loom"},
    {name = "ore_to_bars", input = {item = df.item_type.BOULDER, min = 10},
     output = {item = df.item_type.BAR, min = 10}, workshop = "Smelter"}
}

function check_production_chains()
    local chain_status = {}
    for _, chain in ipairs(PRODUCTION_CHAINS) do
        local input_count = utils.count_items(chain.input.item, nil) or 0
        local output_count = utils.count_items(chain.output.item, nil) or 0
        local needs_production = output_count < chain.output.min and input_count >= chain.input.min
        chain_status[chain.name] = {input = input_count, output = output_count, needs_production = needs_production}
        if needs_production then
            utils.log_debug(string.format("Chain %s: need production", chain.name), "brain")
        end
    end
    return chain_status
end

-------------------------------------------------------------------------------
-- Caravan & Trade
-------------------------------------------------------------------------------

function check_caravan_status()
    local current_season = df.global.cur_season
    local caravans = {
        dwarven = {season = 2, name = "Dwarven"},
        human = {season = 1, name = "Human"},
        elven = {season = 0, name = "Elven"}
    }
    
    local brain_state = state.get("brain") or {}
    local caravan_state = brain_state.caravan or {}
    
    for id, caravan in pairs(caravans) do
        local seasons_until = (caravan.season - current_season) % 4
        caravan_state[id] = {seasons_until = seasons_until, arriving_soon = seasons_until <= 1}
        
        if seasons_until == 1 and not caravan_state[id .. "_warned"] then
            utils.log(caravan.name .. " caravan arriving next season!", "brain")
            caravan_state[id .. "_warned"] = true
        elseif seasons_until > 1 then
            caravan_state[id .. "_warned"] = false
        end
    end
    
    brain_state.caravan = caravan_state
    state.set("brain", brain_state)
    return caravan_state
end

-------------------------------------------------------------------------------
-- Economic Health
-------------------------------------------------------------------------------

function calculate_economic_health()
    local brain_state = state.get("brain") or {}
    local population = utils.get_population()
    
    local resources = {
        food = utils.count_items(df.item_type.FOOD, nil) or 0,
        drink = utils.count_items(df.item_type.DRINK, nil) or 0,
        wood = utils.count_items(df.item_type.WOOD, nil) or 0,
        bars = utils.count_items(df.item_type.BAR, nil) or 0,
        cloth = utils.count_items(df.item_type.CLOTH, nil) or 0,
        leather = utils.count_items(df.item_type.SKIN_TANNED, nil) or 0
    }
    
    local health = 0
    health = health + math.min(20, (resources.food / math.max(1, population)) * 2)
    health = health + math.min(20, (resources.drink / math.max(1, population)) * 2)
    health = health + math.min(15, resources.wood / 5)
    health = health + math.min(15, resources.bars / 3)
    health = health + math.min(15, resources.cloth / 2)
    health = health + math.min(15, resources.leather / 2)
    
    brain_state.economic_health = math.floor(health)
    brain_state.resources = resources
    state.set("brain", brain_state)
    return health, resources
end

-------------------------------------------------------------------------------
-- Bottleneck Detection
-------------------------------------------------------------------------------

function detect_bottlenecks()
    local brain_state = state.get("brain") or {}
    local bottlenecks = {}
    
    local checks = {
        {name = "No wood for carpentry", input = df.item_type.WOOD, input_min = 5},
        {name = "No stone for masonry", input = df.item_type.BOULDER, input_min = 10},
        {name = "No metal for smithing", input = df.item_type.BAR, input_min = 5},
        {name = "No plants for brewing", input = df.item_type.PLANT, input_min = 10},
        {name = "No thread for weaving", input = df.item_type.THREAD, input_min = 5},
        {name = "No leather for crafting", input = df.item_type.SKIN_TANNED, input_min = 5}
    }
    
    for _, check in ipairs(checks) do
        local count = utils.count_items(check.input, nil) or 0
        if count < check.input_min then
            table.insert(bottlenecks, {name = check.name, current = count, needed = check.input_min, severity = count == 0 and 10 or 5})
        end
    end
    
    table.sort(bottlenecks, function(a, b) return a.severity > b.severity end)
    brain_state.bottlenecks = bottlenecks
    state.set("brain", brain_state)
    return bottlenecks
end

-------------------------------------------------------------------------------
-- Immigration & Military
-------------------------------------------------------------------------------

function check_immigration()
    local brain_state = state.get("brain") or {}
    local population = utils.get_population()
    local last_pop = brain_state.last_population or 0
    
    if population > last_pop then
        utils.log(string.format("Immigration: %d new dwarves (pop: %d)", population - last_pop, population), "brain")
        brain_state.new_migrants = population - last_pop
    end
    
    brain_state.last_population = population
    state.set("brain", brain_state)
    return population
end

function check_military_readiness()
    local brain_state = state.get("brain") or {}
    local squad_count, soldier_count = 0, 0
    
    for _, squad in pairs(df.global.world.squads.all) do
        if squad.entity_id == df.global.plotinfo.civ_id then
            squad_count = squad_count + 1
            for _, pos in pairs(squad.positions) do
                if pos.occupant ~= -1 then soldier_count = soldier_count + 1 end
            end
        end
    end
    
    local population = utils.get_population()
    local target = math.max(2, math.floor(population * 0.15))
    
    brain_state.military = {squads = squad_count, soldiers = soldier_count, target = target, adequate = soldier_count >= target}
    state.set("brain", brain_state)
    return soldier_count >= target
end

-------------------------------------------------------------------------------
-- Trade Value Analysis
-------------------------------------------------------------------------------

-- Item types valuable for trade
local TRADE_GOODS = {
    {type = df.item_type.CRAFT, name = "crafts", base_value = 10},
    {type = df.item_type.GEM, name = "gems", base_value = 20},
    {type = df.item_type.SMALLGEM, name = "cut_gems", base_value = 30},
    {type = df.item_type.FIGURINE, name = "figurines", base_value = 25},
    {type = df.item_type.AMULET, name = "amulets", base_value = 20},
    {type = df.item_type.SCEPTER, name = "scepters", base_value = 30},
    {type = df.item_type.CROWN, name = "crowns", base_value = 50},
    {type = df.item_type.RING, name = "rings", base_value = 15},
    {type = df.item_type.EARRING, name = "earrings", base_value = 15},
    {type = df.item_type.BRACELET, name = "bracelets", base_value = 15}
}

function analyze_trade_goods()
    local brain_state = state.get("brain") or {}
    local trade = {goods = {}, total_value = 0, exportable = 0}
    
    for _, good in ipairs(TRADE_GOODS) do
        local count = utils.count_items(good.type, nil) or 0
        local value = count * good.base_value
        trade.goods[good.name] = {count = count, value = value}
        trade.total_value = trade.total_value + value
        trade.exportable = trade.exportable + count
    end
    
    brain_state.trade = trade
    state.set("brain", brain_state)
    return trade
end

--- Calculate what we should buy from caravans
function calculate_import_priorities()
    local brain_state = state.get("brain") or {}
    local resources = brain_state.resources or {}
    local population = utils.get_population()
    
    local priorities = {}
    
    -- Check what we're short on
    if (resources.food or 0) < population * 5 then
        table.insert(priorities, {item = "food", urgency = 8, reason = "Food shortage"})
    end
    if (resources.drink or 0) < population * 5 then
        table.insert(priorities, {item = "drink", urgency = 8, reason = "Drink shortage"})
    end
    if (resources.wood or 0) < 30 then
        table.insert(priorities, {item = "wood", urgency = 5, reason = "Low wood stock"})
    end
    if (resources.bars or 0) < 20 then
        table.insert(priorities, {item = "metal_bars", urgency = 6, reason = "Low metal stock"})
    end
    if (resources.cloth or 0) < 10 then
        table.insert(priorities, {item = "cloth", urgency = 4, reason = "Low cloth stock"})
    end
    
    -- Always want steel/iron
    table.insert(priorities, {item = "steel_bars", urgency = 3, reason = "Military upgrade"})
    table.insert(priorities, {item = "seeds", urgency = 3, reason = "Farm diversity"})
    
    table.sort(priorities, function(a, b) return a.urgency > b.urgency end)
    brain_state.import_priorities = priorities
    state.set("brain", brain_state)
    return priorities
end

-------------------------------------------------------------------------------
-- Wealth Tracking
-------------------------------------------------------------------------------

function track_fortress_wealth()
    local brain_state = state.get("brain") or {}
    
    -- Simple wealth estimation (full calculation is expensive)
    local wealth = 0
    
    -- Count valuable items
    wealth = wealth + (utils.count_items(df.item_type.BAR, nil) or 0) * 30
    wealth = wealth + (utils.count_items(df.item_type.GEM, nil) or 0) * 50
    wealth = wealth + (utils.count_items(df.item_type.CRAFT, nil) or 0) * 15
    wealth = wealth + (utils.count_items(df.item_type.WEAPON, nil) or 0) * 100
    wealth = wealth + (utils.count_items(df.item_type.ARMOR, nil) or 0) * 100
    
    -- Count buildings
    local building_count = 0
    for _ in pairs(df.global.world.buildings.all) do
        building_count = building_count + 1
    end
    wealth = wealth + building_count * 50
    
    -- Track wealth over time
    local wealth_history = brain_state.wealth_history or {}
    table.insert(wealth_history, {tick = df.global.cur_year_tick, value = wealth})
    while #wealth_history > 20 do table.remove(wealth_history, 1) end
    
    -- Calculate growth trend
    local growth = 0
    if #wealth_history >= 5 then
        local first = wealth_history[1].value
        growth = wealth - first
    end
    
    brain_state.wealth = wealth
    brain_state.wealth_growth = growth
    brain_state.wealth_history = wealth_history
    state.set("brain", brain_state)
    
    return wealth, growth
end

return _ENV

