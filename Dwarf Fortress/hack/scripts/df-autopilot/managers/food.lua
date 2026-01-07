-- df-autopilot/managers/food.lua
-- Food and drink production management

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "food"
local last_check = 0
local CHECK_INTERVAL = 200 -- ticks between checks

-------------------------------------------------------------------------------
-- Internal Functions
-------------------------------------------------------------------------------

--- Count all available drinks
local function count_drinks()
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if item:getType() == df.item_type.DRINK and utils.is_valid_item(item) then
            count = count + item:getStackSize()
        end
    end
    return count
end

--- Count all prepared food
local function count_food()
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        local item_type = item:getType()
        if utils.is_valid_item(item) then
            if item_type == df.item_type.FOOD or 
               item_type == df.item_type.FISH or
               item_type == df.item_type.MEAT or
               item_type == df.item_type.CHEESE or
               item_type == df.item_type.EGG then
                count = count + item:getStackSize()
            end
        end
    end
    return count
end

--- Count brewable plants
local function count_brewable_plants()
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if item:getType() == df.item_type.PLANT and utils.is_valid_item(item) then
            -- Check if plant is brewable
            local ok, plant_raw = pcall(function()
                return df.global.world.raws.plants.all[item.mat_index]
            end)
            if ok and plant_raw then
                for _, material in pairs(plant_raw.material) do
                    if material.flags.ALCOHOL_PLANT then
                        count = count + item:getStackSize()
                        break
                    end
                end
            end
        end
    end
    return count
end

--- Count cookable items
local function count_cookable_items()
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if utils.is_valid_item(item) then
            local item_type = item:getType()
            -- Cookable types
            if item_type == df.item_type.FISH_RAW or
               item_type == df.item_type.MEAT or
               item_type == df.item_type.PLANT or
               item_type == df.item_type.PLANT_GROWTH or
               item_type == df.item_type.EGG then
                count = count + item:getStackSize()
            end
        end
    end
    return count
end

--- Count seeds by type
local function count_seeds()
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.SEEDS]) do
        if utils.is_valid_item(item) then
            count = count + item:getStackSize()
        end
    end
    return count
end

-------------------------------------------------------------------------------
-- Farm Management
-------------------------------------------------------------------------------

--- Get all farm plots
local function get_farm_plots()
    local farms = {}
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.FarmPlot then
            table.insert(farms, building)
        end
    end
    return farms
end

--- Check if a farm has plants assigned for current season
local function farm_has_plant_for_season(farm, season)
    local ok, result = pcall(function()
        -- farm.plant_id is an array indexed by season
        local plant_id = farm.plant_id[season]
        return plant_id and plant_id >= 0
    end)
    return ok and result
end

--- Get current season
local function get_current_season()
    return df.global.cur_season
end

--- Find the best crop for a season (with seasonal check)
local function find_best_crop_for_season(farm, season)
    local best_plant = -1
    local best_priority = 0  -- Higher = better
    
    local ok, _ = pcall(function()
        for idx, plant in pairs(df.global.world.raws.plants.all) do
            -- Check if this plant can be grown underground
            if plant.flags.BIOME_SUBTERRANEAN_WATER then
                local priority = 0
                local is_valid = false
                
                -- Check seasonal validity via growth[season] flags
                -- For underground plants, season often doesn't matter
                local growth_ok = true
                if plant.growths and #plant.growths > 0 then
                    -- Verify this plant grows in current season
                    for _, growth in pairs(plant.growths) do
                        if growth.timing_1 >= 0 then
                            growth_ok = true
                            break
                        end
                    end
                end
                
                if growth_ok then
                    for _, material in pairs(plant.material) do
                        -- Prioritize: brewable > edible > other
                        if material.flags.ALCOHOL_PLANT then
                            priority = priority + 10
                            is_valid = true
                        end
                        if material.flags.EDIBLE_RAW or material.flags.EDIBLE_COOKED then
                            priority = priority + 5
                            is_valid = true
                        end
                    end
                    
                    -- Bonus for plump helmet (most versatile)
                    if plant.id:lower():find("plump") then
                        priority = priority + 20
                    end
                end
                
                if is_valid and priority > best_priority then
                    best_priority = priority
                    best_plant = idx
                end
            end
        end
    end)
    
    return best_plant
end

--- Set plant for farm plot
local function set_farm_plant(farm, season, plant_id)
    local ok, _ = pcall(function()
        farm.plant_id[season] = plant_id
    end)
    return ok
end

--- Ensure all farm plots have plants assigned
local function manage_farm_plots()
    local farms = get_farm_plots()
    local season = get_current_season()
    local farms_updated = 0
    
    for _, farm in ipairs(farms) do
        if not farm_has_plant_for_season(farm, season) then
            local crop = find_best_crop_for_season(farm, season)
            if crop >= 0 then
                if set_farm_plant(farm, season, crop) then
                    farms_updated = farms_updated + 1
                end
            end
        end
    end
    
    if farms_updated > 0 then
        utils.log("Set crops for " .. farms_updated .. " farm plots")
    end
    
    return farms_updated, #farms
end

-------------------------------------------------------------------------------
-- Workshop Checks
-------------------------------------------------------------------------------

--- Check if a still exists
local function has_still()
    return utils.count_workshops(df.workshop_type.Still) > 0
end

--- Check if a kitchen exists
local function has_kitchen()
    return utils.count_workshops(df.workshop_type.Kitchen) > 0
end

--- Check if there's an existing brew order
local function has_pending_brew_order()
    return utils.order_exists(df.job_type.BrewDrink, 0)
end

--- Check if there's an existing cook order
local function has_pending_cook_order()
    return utils.order_exists(df.job_type.PrepareMeal, 0)
end

--- Queue brewing jobs
local function queue_brewing(amount)
    if not has_still() then
        utils.log_debug("No still available, skipping brewing")
        return false
    end
    
    if has_pending_brew_order() then
        utils.log_debug("Brew order already pending")
        return false
    end
    
    local max_amount = config.get("food.max_plants_to_brew", 30)
    amount = math.min(amount, max_amount)
    
    if amount <= 0 then
        return false
    end
    
    local order = utils.create_order(df.job_type.BrewDrink, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Queue cooking jobs
local function queue_cooking(amount)
    if not has_kitchen() then
        utils.log_debug("No kitchen available, skipping cooking")
        return false
    end
    
    if has_pending_cook_order() then
        utils.log_debug("Cook order already pending")
        return false
    end
    
    local max_amount = config.get("food.max_food_to_cook", 20)
    amount = math.min(amount, max_amount)
    
    if amount <= 0 then
        return false
    end
    
    local order = utils.create_order(df.job_type.PrepareMeal, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Main update function called by the orchestrator
function update()
    -- Throttle checks
    local current_tick = df.global.cur_year_tick
    if current_tick - last_check < CHECK_INTERVAL then
        return
    end
    last_check = current_tick
    
    state.increment("stats.ticks")
    
    local population = utils.get_population()
    if population == 0 then
        return
    end
    
    -- Get current counts
    local drinks = count_drinks()
    local food = count_food()
    local brewable = count_brewable_plants()
    local cookable = count_cookable_items()
    local seeds = count_seeds()
    
    -- Calculate targets
    local drinks_per_dwarf = config.get("food.drinks_per_dwarf", 3)
    local food_per_dwarf = config.get("food.food_per_dwarf", 2)
    local min_drinks = config.get("food.min_drinks", 50)
    local min_food = config.get("food.min_food", 50)
    
    local target_drinks = math.max(min_drinks, population * drinks_per_dwarf)
    local target_food = math.max(min_food, population * food_per_dwarf)
    
    -- Manage farm plots
    local farms_updated, farm_count = manage_farm_plots()
    
    -- Update manager state for status display
    state.set_manager_state(MANAGER_NAME, {
        drinks = drinks,
        target_drinks = target_drinks,
        food = food,
        target_food = target_food,
        brewable = brewable,
        cookable = cookable,
        seeds = seeds,
        farm_count = farm_count,
        last_check = current_tick
    })
    
    -- Check if we need drinks
    if drinks < target_drinks then
        local needed = target_drinks - drinks
        local to_brew = math.min(needed, brewable)
        
        if to_brew > 0 then
            utils.log_debug(string.format(
                "Drinks: %d/%d (need %d, have %d brewable plants)",
                drinks, target_drinks, needed, brewable
            ))
            queue_brewing(to_brew)
        elseif brewable == 0 and drinks < min_drinks then
            utils.log_warn("Running low on drinks with no brewable plants!")
        end
    end
    
    -- Check if we need food
    if food < target_food then
        local needed = target_food - food
        local to_cook = math.min(needed, cookable)
        
        if to_cook > 0 then
            utils.log_debug(string.format(
                "Food: %d/%d (need %d, have %d cookable)",
                food, target_food, needed, cookable
            ))
            queue_cooking(to_cook)
        end
    end
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state or not mgr_state.drinks then
        return "waiting"
    end
    
    return string.format("drinks: %d/%d, food: %d/%d, farms: %d",
        mgr_state.drinks or 0,
        mgr_state.target_drinks or 0,
        mgr_state.food or 0,
        mgr_state.target_food or 0,
        mgr_state.farm_count or 0
    )
end

return _ENV
