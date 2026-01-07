-- df-autopilot/brain/history.lua
-- Seasonal planning and fortress history/timeline

--@ module = true

local utils = reqscript("df-autopilot/utils")
local state = reqscript("df-autopilot/state")

-------------------------------------------------------------------------------
-- Seasonal Planning
-------------------------------------------------------------------------------

SEASONS = {"Spring", "Summer", "Autumn", "Winter"}

function seasonal_planning()
    local brain_state = state.get("brain") or {}
    local current_season = df.global.cur_season
    local season_name = SEASONS[current_season + 1] or "Unknown"
    local season_tick = df.global.cur_season_tick
    
    local plan = {season = season_name, season_progress = math.floor(season_tick / 33600 * 100), tasks = {}, warnings = {}}
    
    if current_season == 0 then  -- Spring
        table.insert(plan.tasks, "Plant surface crops")
        if season_tick > 25000 then table.insert(plan.warnings, "Elven caravan soon") end
    elseif current_season == 1 then  -- Summer
        table.insert(plan.tasks, "Harvest surface crops")
        if season_tick > 25000 then table.insert(plan.warnings, "Human caravan soon") end
    elseif current_season == 2 then  -- Autumn
        table.insert(plan.tasks, "Prepare for winter")
        if season_tick > 25000 then table.insert(plan.warnings, "Dwarven caravan soon") end
    elseif current_season == 3 then  -- Winter
        table.insert(plan.tasks, "Underground focus")
    end
    
    if brain_state.last_season ~= current_season then
        utils.log("Season: " .. season_name, "brain")
        brain_state.last_season = current_season
    end
    
    brain_state.season = plan
    state.set("brain", brain_state)
    return plan
end

-------------------------------------------------------------------------------
-- Fortress History & Milestones
-------------------------------------------------------------------------------

function track_history()
    local brain_state = state.get("brain") or {}
    local history = brain_state.history or {
        founded = {year = df.global.cur_year, tick = df.global.cur_year_tick},
        milestones = {}, deaths = 0, births = 0, immigrants = 0, artifacts = 0, sieges = 0
    }
    
    local current_year = df.global.cur_year
    local population = utils.get_population()
    
    local pop_milestones = {10, 25, 50, 100, 150, 200}
    for _, milestone in ipairs(pop_milestones) do
        local key = "pop_" .. milestone
        if population >= milestone and not history[key] then
            history[key] = current_year
            table.insert(history.milestones, {year = current_year, event = "Population " .. milestone})
            utils.log("MILESTONE: Population " .. milestone, "brain")
        end
    end
    
    local goals_completed = brain_state.goals_completed or 0
    for _, milestone in ipairs({3, 5, 7, 10}) do
        local key = "goals_" .. milestone
        if goals_completed >= milestone and not history[key] then
            history[key] = current_year
            table.insert(history.milestones, {year = current_year, event = "Goals " .. milestone})
        end
    end
    
    history.age_years = current_year - history.founded.year
    brain_state.history = history
    state.set("brain", brain_state)
    return history
end

-------------------------------------------------------------------------------
-- Expansion Needs
-------------------------------------------------------------------------------

function check_expansion_needs()
    local population = utils.get_population()
    local needs = {}
    
    local bed_count = 0
    for _, b in pairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Bed then bed_count = bed_count + 1 end
    end
    if bed_count < population + 5 then
        table.insert(needs, {type = "bedrooms", current = bed_count, target = population + 10, priority = 6})
    end
    
    local chair_count = 0
    for _, b in pairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Chair then chair_count = chair_count + 1 end
    end
    if chair_count < population then
        table.insert(needs, {type = "dining", current = chair_count, target = population + 5, priority = 4})
    end
    
    return needs
end

return _ENV
