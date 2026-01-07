-- df-autopilot/managers/brain.lua
-- Central decision engine - coordinates all brain submodules
-- Slimmed down core that imports specialized modules

--@ module = true

local utils = reqscript("df-autopilot/utils")
local state = reqscript("df-autopilot/state")

-- Import brain submodules
local events = reqscript("df-autopilot/brain/events")
local goals = reqscript("df-autopilot/brain/goals")
local economy = reqscript("df-autopilot/brain/economy")
local wellbeing = reqscript("df-autopilot/brain/wellbeing")
local analysis = reqscript("df-autopilot/brain/analysis")
local history = reqscript("df-autopilot/brain/history")

-------------------------------------------------------------------------------
-- Manager Registry
-------------------------------------------------------------------------------

local loaded_managers = {}

local function get_manager(name)
    if loaded_managers[name] then return loaded_managers[name] end
    local ok, mgr = pcall(function() return reqscript("df-autopilot/managers/" .. name) end)
    if ok and mgr then loaded_managers[name] = mgr end
    return mgr
end

-- Pass manager loader to events module
events.set_manager_loader(get_manager)

-------------------------------------------------------------------------------
-- Problem Detection (Core)
-------------------------------------------------------------------------------

function detect_problems()
    local problems = {}
    local population = utils.get_population()
    local food_count = utils.count_items(df.item_type.FOOD, nil) or 0
    local drink_count = utils.count_items(df.item_type.DRINK, nil) or 0
    
    -- Food/drink
    if food_count < population * 2 then
        table.insert(problems, {type = "NO_FOOD", urgency = food_count < 10 and 10 or 7, message = "Low food: " .. food_count, handler = "food", action = "ensure_food_production"})
    end
    if drink_count < population * 2 then
        table.insert(problems, {type = "NO_DRINK", urgency = drink_count < 10 and 10 or 7, message = "Low drink: " .. drink_count, handler = "food", action = "ensure_drink_production"})
    end
    
    -- Threats
    local threat_state = state.get_manager_state("threat")
    if threat_state and threat_state.total_threats and threat_state.total_threats > 0 then
        table.insert(problems, {type = "THREATS", urgency = 10, message = "Active threats: " .. threat_state.total_threats, handler = "emergency"})
    end
    
    -- Beds
    local bed_count = 0
    for _, b in pairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Bed then bed_count = bed_count + 1 end
    end
    if bed_count < population then
        table.insert(problems, {type = "NO_BEDS", urgency = 5, message = "Need beds: " .. bed_count .. "/" .. population, handler = "building"})
    end
    
    -- Workshops
    local workshop_count = 0
    for _, b in pairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Workshop then workshop_count = workshop_count + 1 end
    end
    if workshop_count < 3 then
        table.insert(problems, {type = "NO_WORKSHOPS", urgency = 8, message = "Need workshops: " .. workshop_count .. "/3", handler = "workshop"})
    end
    
    -- Farms
    local farm_count = 0
    for _, b in pairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.FarmPlot then farm_count = farm_count + 1 end
    end
    if farm_count < 1 then
        table.insert(problems, {type = "NO_FARMS", urgency = 7, message = "No farm plots", handler = "food"})
    end
    
    -- Mining
    local mining_state = state.get_manager_state("mining")
    if not mining_state or not mining_state.starter_layout_complete then
        table.insert(problems, {type = "NO_DIG", urgency = 8, message = "Initial layout not dug", handler = "mining"})
    end
    
    -- Military
    local military_state = state.get_manager_state("military")
    if (not military_state or not military_state.squads_created) and population >= 10 then
        table.insert(problems, {type = "NO_MILITARY", urgency = 5, message = "No military squads", handler = "military"})
    end
    
    table.sort(problems, function(a, b) return a.urgency > b.urgency end)
    return problems
end

-------------------------------------------------------------------------------
-- Solution Execution
-------------------------------------------------------------------------------

function execute_solution(problem)
    if not problem or not problem.handler then return false, "Invalid problem" end
    
    local brain_state = state.get("brain") or {}
    brain_state.solutions_attempted = (brain_state.solutions_attempted or 0) + 1
    
    local last_solved = brain_state.last_solved or {}
    local current_tick = df.global.cur_year_tick
    if last_solved[problem.type] and current_tick - last_solved[problem.type] < 500 then
        return false, "Rate limited"
    end
    
    utils.log(string.format("Executing: %s (%s)", problem.action or problem.type, problem.handler), "brain")
    
    local manager = get_manager(problem.handler)
    if not manager then return false, "Manager not found: " .. problem.handler end
    
    local ok, err = pcall(function() if manager.update then manager.update() end end)
    if ok then
        last_solved[problem.type] = current_tick
        brain_state.last_solved = last_solved
        brain_state.solutions_succeeded = (brain_state.solutions_succeeded or 0) + 1
        state.set("brain", brain_state)
        return true, "Solution executed"
    else
        utils.log_warn("Solution failed: " .. tostring(err), "brain")
        analysis.record_failure(problem.type, err)
        state.set("brain", brain_state)
        return false, err
    end
end

-------------------------------------------------------------------------------
-- Decision Making (Core Think Loop)
-------------------------------------------------------------------------------

function think()
    local brain_state = state.get("brain") or {}
    
    -- Phase detection (from goals module)
    local current_phase = goals.determine_phase()
    if brain_state.last_phase ~= current_phase then
        utils.log(string.format("Phase: %s -> %s", goals.get_phase_name(brain_state.last_phase or 0), goals.get_phase_name(current_phase)), "brain")
        brain_state.last_phase = current_phase
    end
    
    -- Detect problems
    local problems = detect_problems()
    brain_state.problem_count = #problems
    
    -- EMERGENT EVENTS first (from events module)
    local emergent = events.detect_emergent_events()
    brain_state.event_count = #emergent
    
    if #emergent > 0 then
        table.sort(emergent, function(a, b) return a.severity > b.severity end)
        if emergent[1].severity >= 8 then
            events.respond_to_event(emergent[1])
        end
    end
    
    -- Handle regular problems
    if #problems > 0 and problems[1].urgency >= 7 then
        execute_solution(problems[1])
    end
    
    state.set("brain", brain_state)
    return {phase = current_phase, phase_name = goals.get_phase_name(current_phase), problems = problems, events = emergent}
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function update()
    local brain_state = state.get("brain") or {}
    local current_tick = df.global.cur_year_tick
    
    if not brain_state.last_think or current_tick - brain_state.last_think > 200 then
        think()
        brain_state.last_think = current_tick
        
        -- Economic checks (less frequent)
        if not brain_state.last_economic_check or current_tick - brain_state.last_economic_check > 1000 then
            economy.check_production_chains()
            economy.check_caravan_status()
            economy.calculate_economic_health()
            economy.check_immigration()
            economy.check_military_readiness()
            brain_state.last_economic_check = current_tick
        end
        
        -- Comprehensive analysis (even less frequent)
        if not brain_state.last_prediction or current_tick - brain_state.last_prediction > 2000 then
            analysis.predict_problems()
            analysis.analyze_patterns()
            analysis.analyze_skills()
            analysis.track_resource_trends()
            analysis.analyze_personalities()
            analysis.prioritize_threats()
            analysis.analyze_workshop_efficiency()
            analysis.generate_situation_report()
            analysis.strategic_assessment()
            economy.detect_bottlenecks()
            goals.check_goals()
            wellbeing.check_dwarf_wellbeing()
            wellbeing.check_defense_infrastructure()
            wellbeing.check_mood_materials()
            history.seasonal_planning()
            history.track_history()
            brain_state.last_prediction = current_tick
            
            -- Log comprehensive status
            local report = brain_state.situation_report or {}
            local eff = brain_state.workshop_efficiency or {}
            utils.log_debug(string.format("Brain: %s | WS: %d%% | Goals: %d/%d", 
                report.situation or "?", eff.percentage or 0, 
                brain_state.goals_completed or 0, brain_state.goals_total or 10), "brain")
        end
        
        state.set("brain", brain_state)
    end
end

function get_status()
    local phase = goals.determine_phase()
    local problems = detect_problems()
    return string.format("%s, %d issues", goals.get_phase_name(phase), #problems)
end

-- Re-export submodule functions for external access
PHASES = goals.PHASES
FORTRESS_GOALS = goals.FORTRESS_GOALS
EVENT_TYPES = events.EVENT_TYPES

return _ENV
