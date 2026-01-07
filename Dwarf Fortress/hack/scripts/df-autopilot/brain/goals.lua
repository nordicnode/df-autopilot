-- df-autopilot/brain/goals.lua
-- Fortress goals and phase management

--@ module = true

local utils = reqscript("df-autopilot/utils")
local state = reqscript("df-autopilot/state")

-------------------------------------------------------------------------------
-- Fortress Phases
-------------------------------------------------------------------------------

PHASES = {
    EMBARK = 1,
    ESTABLISHING = 2,
    STABLE = 3,
    EXPANDING = 4,
    CRISIS = 5,
    THRIVING = 6
}

PHASE_NAMES = {
    [1] = "EMBARK",
    [2] = "ESTABLISHING", 
    [3] = "STABLE",
    [4] = "EXPANDING",
    [5] = "CRISIS",
    [6] = "THRIVING"
}

--- Get phase name
function get_phase_name(phase)
    return PHASE_NAMES[phase] or "UNKNOWN"
end

--- Determine current fortress phase
function determine_phase()
    local population = utils.get_population()
    
    -- Crisis check first
    local threat_state = state.get_manager_state("threat")
    if threat_state and threat_state.total_threats and threat_state.total_threats > 0 then
        return PHASES.CRISIS
    end
    
    local mood_state = state.get_manager_state("mood")
    if mood_state and mood_state.tantrum_risk then
        return PHASES.CRISIS
    end
    
    -- Check for basic infrastructure
    local mining_state = state.get_manager_state("mining")
    local has_dug = mining_state and mining_state.starter_layout_complete
    
    local zone_state = state.get_manager_state("zone")
    local has_zones = zone_state and zone_state.meeting_area
    
    -- Phase determination
    if population <= 7 and not has_dug then
        return PHASES.EMBARK
    elseif not has_dug or not has_zones then
        return PHASES.ESTABLISHING
    elseif population < 20 then
        return PHASES.STABLE
    elseif population < 80 then
        return PHASES.EXPANDING
    else
        return PHASES.THRIVING
    end
end

-------------------------------------------------------------------------------
-- Fortress Goals
-------------------------------------------------------------------------------

FORTRESS_GOALS = {
    {id = "shelter", name = "Establish Shelter", priority = 10, 
     check = function() 
         local m = state.get_manager_state("mining")
         return m and m.starter_layout_complete 
     end},
    {id = "food_supply", name = "Stable Food Supply", priority = 9,
     check = function() return (utils.count_items(df.item_type.FOOD, nil) or 0) >= 50 end},
    {id = "drink_supply", name = "Stable Drink Supply", priority = 9,
     check = function() return (utils.count_items(df.item_type.DRINK, nil) or 0) >= 50 end},
    {id = "military", name = "Form Military", priority = 7,
     check = function() 
         local m = state.get_manager_state("military")
         return m and m.squads_created
     end},
    {id = "hospital", name = "Hospital Ready", priority = 6,
     check = function()
         local z = state.get_manager_state("zone")
         return z and z.hospital
     end},
    {id = "workshops", name = "Essential Workshops", priority = 8,
     check = function()
         local count = 0
         for _, b in pairs(df.global.world.buildings.all) do
             if b:getType() == df.building_type.Workshop then
                 count = count + 1
             end
         end
         return count >= 5
     end},
    {id = "metalworking", name = "Metal Industry", priority = 5,
     check = function()
         return (utils.count_items(df.item_type.BAR, nil) or 0) >= 20
     end},
    {id = "bedrooms", name = "Individual Bedrooms", priority = 4,
     check = function()
         local beds = 0
         for _, b in pairs(df.global.world.buildings.all) do
             if b:getType() == df.building_type.Bed then beds = beds + 1 end
         end
         return beds >= utils.get_population()
     end},
    {id = "tavern", name = "Tavern Established", priority = 3,
     check = function()
         local z = state.get_manager_state("zone")
         return z and z.tavern
     end},
    {id = "temple", name = "Temple Established", priority = 3,
     check = function()
         local z = state.get_manager_state("zone")
         return z and z.temple
     end}
}

--- Check fortress goals and return progress
function check_goals()
    local brain_state = state.get("brain") or {}
    local goals_status = {}
    local completed = 0
    local next_goal = nil
    
    for _, goal in ipairs(FORTRESS_GOALS) do
        local ok, achieved = pcall(goal.check)
        achieved = ok and achieved or false
        
        goals_status[goal.id] = {
            name = goal.name,
            priority = goal.priority,
            achieved = achieved
        }
        
        if achieved then
            completed = completed + 1
        elseif not next_goal or goal.priority > next_goal.priority then
            next_goal = goal
        end
    end
    
    brain_state.goals = goals_status
    brain_state.goals_completed = completed
    brain_state.goals_total = #FORTRESS_GOALS
    brain_state.next_goal = next_goal and next_goal.name or "All goals complete"
    
    if brain_state.last_goals_completed ~= completed then
        utils.log(string.format("Goals: %d/%d complete. Next: %s",
            completed, #FORTRESS_GOALS, brain_state.next_goal), "brain")
        brain_state.last_goals_completed = completed
    end
    
    state.set("brain", brain_state)
    return goals_status, next_goal
end

--- Get recommended actions based on current state
function get_recommendations(problems)
    local phase = determine_phase()
    local recommendations = {}
    
    if phase == PHASES.EMBARK then
        table.insert(recommendations, {action = "dig_fortress", priority = 10, reason = "Need shelter"})
        table.insert(recommendations, {action = "create_stockpiles", priority = 8, reason = "Organize supplies"})
    elseif phase == PHASES.ESTABLISHING then
        table.insert(recommendations, {action = "build_workshops", priority = 9, reason = "Enable crafting"})
    elseif phase == PHASES.CRISIS then
        table.insert(recommendations, {action = "activate_burrow", priority = 10, reason = "Protect civilians"})
        table.insert(recommendations, {action = "mobilize_military", priority = 10, reason = "Respond to threats"})
    end
    
    if problems then
        for i = 1, math.min(3, #problems) do
            local p = problems[i]
            table.insert(recommendations, {
                action = "solve_" .. p.type:lower(),
                priority = p.urgency,
                reason = p.message
            })
        end
    end
    
    table.sort(recommendations, function(a, b) return a.priority > b.priority end)
    return recommendations
end

return _ENV
