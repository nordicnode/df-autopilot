-- df-autopilot/brain/analysis.lua
-- Skills, patterns, predictions, and strategic assessment

--@ module = true

local utils = reqscript("df-autopilot/utils")
local state = reqscript("df-autopilot/state")

-------------------------------------------------------------------------------
-- Skill Gap Analysis
-------------------------------------------------------------------------------

function analyze_skills()
    local brain_state = state.get("brain") or {}
    local skills = {}
    
    -- Use skill names that are guaranteed to exist
    local critical_skills = {}
    
    -- Safely add skills with nil checks
    local function add_skill(skill_enum, name)
        if skill_enum then
            table.insert(critical_skills, {id = skill_enum, name = name})
        end
    end
    
    add_skill(df.job_skill.MINING, "Mining")
    add_skill(df.job_skill.CARPENTRY, "Carpentry")
    add_skill(df.job_skill.MASONRY, "Masonry")
    add_skill(df.job_skill.COOKING, "Cooking")
    add_skill(df.job_skill.BREWING, "Brewing")
    add_skill(df.job_skill.PLANT, "Farming")
    add_skill(df.job_skill.DIAGNOSE, "Diagnosis")
    add_skill(df.job_skill.METALCRAFT, "Metalcraft")
    add_skill(df.job_skill.SMELT, "Smelting")
    add_skill(df.job_skill.FORGE_ARMOR, "Armorsmithing")
    
    for _, skill_def in ipairs(critical_skills) do
        if skill_def.id then
            skills[skill_def.id] = {name = skill_def.name, count = 0, max_level = 0}
        end
    end
    
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) and unit.status.current_soul then
            for _, skill in pairs(unit.status.current_soul.skills) do
                if skill.id and skills[skill.id] and skill.rating > 0 then
                    skills[skill.id].count = skills[skill.id].count + 1
                    if skill.rating > skills[skill.id].max_level then
                        skills[skill.id].max_level = skill.rating
                    end
                end
            end
        end
    end
    
    local gaps = {}
    for skill_id, data in pairs(skills) do
        if data.count == 0 then
            table.insert(gaps, {skill = data.name, severity = "critical", message = "No dwarf has " .. data.name})
        elseif data.count == 1 then
            table.insert(gaps, {skill = data.name, severity = "warning", message = "Only 1 " .. data.name})
        end
    end
    
    brain_state.skills = skills
    brain_state.skill_gaps = gaps
    state.set("brain", brain_state)
    return skills, gaps
end

-------------------------------------------------------------------------------
-- Predictive Planning
-------------------------------------------------------------------------------

function predict_problems()
    local predictions = {}
    local brain_state = state.get("brain") or {}
    local population = utils.get_population()
    
    local food_count = utils.count_items(df.item_type.FOOD, nil) or 0
    local drink_count = utils.count_items(df.item_type.DRINK, nil) or 0
    local consumption = population * 3
    
    if food_count < consumption * 2 then
        table.insert(predictions, {type = "FOOD_SHORTAGE", certainty = math.min(100, 100 - (food_count / consumption * 50)), message = "Food will run low"})
    end
    if drink_count < consumption * 2 then
        table.insert(predictions, {type = "DRINK_SHORTAGE", certainty = math.min(100, 100 - (drink_count / consumption * 50)), message = "Drink will run low"})
    end
    
    local stressed = brain_state.dwarf_health and brain_state.dwarf_health.stressed or 0
    if stressed >= 2 then
        table.insert(predictions, {type = "TANTRUM_RISK", certainty = stressed * 20, message = stressed .. " stressed dwarves may tantrum"})
    end
    
    brain_state.predictions = predictions
    state.set("brain", brain_state)
    return predictions
end

-------------------------------------------------------------------------------
-- Pattern Analysis
-------------------------------------------------------------------------------

function analyze_patterns()
    local brain_state = state.get("brain") or {}
    local problem_counts = brain_state.problem_history or {}
    local patterns = {}
    
    for ptype, data in pairs(problem_counts) do
        if data.occurrences and data.occurrences >= 5 then
            table.insert(patterns, {type = ptype, frequency = data.occurrences, message = ptype .. " is chronic"})
        end
    end
    
    brain_state.patterns = patterns
    state.set("brain", brain_state)
    return patterns
end

-------------------------------------------------------------------------------
-- Learning System
-------------------------------------------------------------------------------

function record_failure(problem_type, reason)
    local brain_state = state.get("brain") or {}
    local failures = brain_state.failures or {}
    failures[problem_type] = failures[problem_type] or {count = 0, reasons = {}}
    failures[problem_type].count = failures[problem_type].count + 1
    failures[problem_type].last_tick = df.global.cur_year_tick
    if reason then table.insert(failures[problem_type].reasons, reason) end
    brain_state.failures = failures
    state.set("brain", brain_state)
end

function record_success(problem_type)
    local brain_state = state.get("brain") or {}
    local successes = brain_state.successes or {}
    successes[problem_type] = (successes[problem_type] or 0) + 1
    brain_state.successes = successes
    state.set("brain", brain_state)
end

function get_failure_penalty(problem_type)
    local brain_state = state.get("brain") or {}
    local failures = brain_state.failures or {}
    if failures[problem_type] then
        return math.min(3, failures[problem_type].count * 0.5)
    end
    return 0
end

function get_adaptive_urgency(problem)
    local base = problem.urgency or 5
    local modifier = -get_failure_penalty(problem.type)
    local brain_state = state.get("brain") or {}
    local history = brain_state.problem_history or {}
    if history[problem.type] and history[problem.type].occurrences and history[problem.type].occurrences >= 3 then
        modifier = modifier + 1
    end
    return math.max(1, math.min(10, base + modifier))
end

-------------------------------------------------------------------------------
-- Strategic Assessment
-------------------------------------------------------------------------------

function strategic_assessment()
    local brain_state = state.get("brain") or {}
    
    local scores = {
        economic = brain_state.economic_health or 0,
        defense = brain_state.defense_score or 0,
        wellbeing = brain_state.wellbeing and brain_state.wellbeing.score or 0,
        goals = math.floor((brain_state.goals_completed or 0) / (brain_state.goals_total or 10) * 100)
    }
    
    local overall = math.floor((scores.economic + scores.defense + scores.wellbeing + scores.goals) / 4)
    
    local status = "STABLE"
    if overall >= 80 then status = "THRIVING"
    elseif overall >= 60 then status = "STABLE"
    elseif overall >= 40 then status = "DEVELOPING"
    elseif overall >= 20 then status = "STRUGGLING"
    else status = "CRITICAL" end
    
    brain_state.assessment = {overall_status = status, overall_score = overall, scores = scores}
    state.set("brain", brain_state)
    return brain_state.assessment
end

-------------------------------------------------------------------------------
-- Resource Trend Tracking
-------------------------------------------------------------------------------

-- Historical resource snapshots
function track_resource_trends()
    local brain_state = state.get("brain") or {}
    local trends = brain_state.resource_trends or {}
    local current_tick = df.global.cur_year_tick
    
    -- Take snapshot
    local snapshot = {
        tick = current_tick,
        food = utils.count_items(df.item_type.FOOD, nil) or 0,
        drink = utils.count_items(df.item_type.DRINK, nil) or 0,
        wood = utils.count_items(df.item_type.WOOD, nil) or 0,
        bars = utils.count_items(df.item_type.BAR, nil) or 0
    }
    
    trends.snapshots = trends.snapshots or {}
    table.insert(trends.snapshots, snapshot)
    
    -- Keep only last 10 snapshots
    while #trends.snapshots > 10 do
        table.remove(trends.snapshots, 1)
    end
    
    -- Calculate consumption rates if we have enough data
    if #trends.snapshots >= 3 then
        local first = trends.snapshots[1]
        local last = trends.snapshots[#trends.snapshots]
        local tick_diff = last.tick - first.tick
        
        if tick_diff > 0 then
            trends.consumption = {
                food = (first.food - last.food) / (tick_diff / 1000),
                drink = (first.drink - last.drink) / (tick_diff / 1000),
                wood = (first.wood - last.wood) / (tick_diff / 1000)
            }
            
            -- Calculate days until depletion
            trends.depletion = {}
            for resource, rate in pairs(trends.consumption) do
                if rate > 0 then
                    local current = last[resource] or 0
                    trends.depletion[resource] = math.floor(current / rate)
                end
            end
        end
    end
    
    brain_state.resource_trends = trends
    state.set("brain", brain_state)
    
    -- Warn on rapid depletion
    if trends.depletion then
        for resource, days in pairs(trends.depletion) do
            if days < 5 then
                utils.log_warn(resource .. " depleting in ~" .. days .. " days!", "brain")
            end
        end
    end
    
    return trends
end

-------------------------------------------------------------------------------
-- Dwarf Personality Analysis
-------------------------------------------------------------------------------

-- Trait categories for decision making
local TRAIT_CATEGORIES = {
    combat = {"AGILITY", "STRENGTH", "ENDURANCE", "TOUGHNESS", "RECUPERATION"},
    social = {"EMPATHY", "SOCIAL_AWARENESS", "LINGUISTIC_ABILITY"},
    crafting = {"FOCUS", "PATIENCE", "CREATIVITY", "ANALYTICAL_ABILITY"},
    leadership = {"WILLPOWER", "ASSERTIVENESS", "LEADERSHIP"}
}

function analyze_personalities()
    local brain_state = state.get("brain") or {}
    local personalities = {}
    local aptitudes = {combat = {}, social = {}, crafting = {}, leadership = {}}
    
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) then
            -- Get name safely
            local name = "Unknown"
            local ok, visible_name = pcall(function() return dfhack.units.getVisibleName(unit) end)
            if ok and visible_name then
                local ok2, translated = pcall(function() return dfhack.TranslateName(visible_name) end)
                if ok2 and translated then name = translated end
            end
            local soul = unit.status.current_soul
            
            if soul then
                local profile = {
                    id = unit.id,
                    name = name,
                    stress = soul.personality and soul.personality.stress or 0,
                    combat_apt = 0,
                    social_apt = 0,
                    craft_apt = 0,
                    leader_apt = 0
                }
                
                -- Use physical attrs for combat aptitude (they're on unit body, not soul)
                local body = unit.body
                if body and body.physical_attrs then
                    local phys = body.physical_attrs
                    local function safe_attr(attr)
                        return attr and attr.value or 500
                    end
                    profile.combat_apt = (safe_attr(phys.AGILITY) + safe_attr(phys.STRENGTH) + safe_attr(phys.ENDURANCE)) / 3
                end
                
                -- Use mental attrs from soul for other aptitudes
                if soul.mental_attrs then
                    local ment = soul.mental_attrs
                    local function safe_attr(attr)
                        return attr and attr.value or 500
                    end
                    profile.social_apt = (safe_attr(ment.EMPATHY) + safe_attr(ment.SOCIAL_AWARENESS)) / 2
                    profile.craft_apt = (safe_attr(ment.FOCUS) + safe_attr(ment.PATIENCE) + safe_attr(ment.CREATIVITY)) / 3
                    profile.leader_apt = (safe_attr(ment.WILLPOWER)) -- LEADERSHIP may not exist
                end
                
                personalities[unit.id] = profile
                
                -- Track top candidates (1500+ is above average)
                if profile.combat_apt > 1200 then table.insert(aptitudes.combat, unit.id) end
                if profile.social_apt > 1200 then table.insert(aptitudes.social, unit.id) end
                if profile.craft_apt > 1200 then table.insert(aptitudes.crafting, unit.id) end
                if profile.leader_apt > 1200 then table.insert(aptitudes.leadership, unit.id) end
            end
        end
    end
    
    brain_state.personalities = personalities
    brain_state.aptitudes = aptitudes
    state.set("brain", brain_state)
    return personalities, aptitudes
end

-------------------------------------------------------------------------------
-- Threat Priority Targeting
-------------------------------------------------------------------------------

-- Threat danger rankings
local THREAT_DANGER = {
    forgotten_beast = 100,
    megabeast = 95,
    titan = 95,
    demon = 90,
    necromancer = 85,
    werebeast = 80,
    invader_leader = 75,
    invader = 50,
    undead = 40,
    thief = 20,
    wildlife = 10
}

function prioritize_threats()
    local brain_state = state.get("brain") or {}
    local threats = {}
    
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isAlive(unit) and not dfhack.units.isCitizen(unit) then
            local threat_type = nil
            local danger = 0
            
            -- Classify threat
            if unit.flags1.marauder or unit.flags1.invader_origin then
                threat_type = "invader"
                danger = THREAT_DANGER.invader
            end
            if unit.flags1.forest or unit.flags2.visitor then
                -- Not a threat
            elseif dfhack.units.isMegabeast(unit) then
                threat_type = "megabeast"
                danger = THREAT_DANGER.megabeast
            elseif dfhack.units.isUndead(unit) then
                threat_type = "undead"
                danger = THREAT_DANGER.undead
            end
            
            if threat_type and danger > 0 then
                local pos = {x = unit.pos.x, y = unit.pos.y, z = unit.pos.z}
                local threat_name = "Unknown"
                pcall(function()
                    local vn = dfhack.units.getVisibleName(unit)
                    if vn then threat_name = dfhack.TranslateName(vn) or "Unknown" end
                end)
                table.insert(threats, {
                    id = unit.id,
                    type = threat_type,
                    danger = danger,
                    pos = pos,
                    name = threat_name
                })
            end
        end
    end
    
    -- Sort by danger (highest first)
    table.sort(threats, function(a, b) return a.danger > b.danger end)
    
    brain_state.threat_priorities = threats
    brain_state.primary_threat = threats[1]
    state.set("brain", brain_state)
    
    if #threats > 0 then
        utils.log_debug("Priority threat: " .. (threats[1].name or threats[1].type), "brain")
    end
    
    return threats
end

-------------------------------------------------------------------------------
-- Workshop Efficiency Monitoring
-------------------------------------------------------------------------------

function analyze_workshop_efficiency()
    local brain_state = state.get("brain") or {}
    local workshops = {}
    local efficiency = {active = 0, idle = 0, total = 0}
    
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Workshop then
            local ws = {
                id = building.id,
                type = building:getSubtype(),
                has_job = false,
                worker = nil
            }
            
            -- Check for active jobs
            if building.jobs and #building.jobs > 0 then
                ws.has_job = true
                efficiency.active = efficiency.active + 1
                pcall(function()
                    if building.jobs[0] and building.jobs[0].holder then
                        ws.worker = building.jobs[0].holder.id
                    end
                end)
            else
                efficiency.idle = efficiency.idle + 1
            end
            
            efficiency.total = efficiency.total + 1
            workshops[building.id] = ws
        end
    end
    
    -- Calculate efficiency percentage
    efficiency.percentage = efficiency.total > 0 and 
        math.floor(efficiency.active / efficiency.total * 100) or 0
    
    brain_state.workshops = workshops
    brain_state.workshop_efficiency = efficiency
    state.set("brain", brain_state)
    
    if efficiency.percentage < 30 and efficiency.total >= 3 then
        utils.log_debug("Low workshop efficiency: " .. efficiency.percentage .. "%", "brain")
    end
    
    return workshops, efficiency
end

-------------------------------------------------------------------------------
-- Situation Awareness
-------------------------------------------------------------------------------

function generate_situation_report()
    local brain_state = state.get("brain") or {}
    local population = utils.get_population()
    
    local report = {
        timestamp = df.global.cur_year_tick,
        year = df.global.cur_year,
        population = population,
        phase = brain_state.last_phase or 0,
        
        -- Status summaries
        threats_active = brain_state.threat_priorities and #brain_state.threat_priorities or 0,
        problems_count = brain_state.problem_count or 0,
        events_active = brain_state.event_count or 0,
        
        -- Health indicators
        wellbeing = brain_state.wellbeing and brain_state.wellbeing.score or 0,
        economic = brain_state.economic_health or 0,
        defense = brain_state.defense_score or 0,
        
        -- Predictions
        food_days = brain_state.resource_trends and brain_state.resource_trends.depletion and 
                    brain_state.resource_trends.depletion.food or nil,
        drink_days = brain_state.resource_trends and brain_state.resource_trends.depletion and 
                     brain_state.resource_trends.depletion.drink or nil,
        
        -- Goals
        goals_progress = string.format("%d/%d", brain_state.goals_completed or 0, brain_state.goals_total or 10),
        next_goal = brain_state.next_goal or "Unknown"
    }
    
    -- Determine overall situation
    if report.threats_active > 0 then
        report.situation = "UNDER ATTACK"
    elseif report.wellbeing < 30 then
        report.situation = "CRISIS"
    elseif report.problems_count > 5 then
        report.situation = "STRUGGLING"
    elseif report.economic < 40 then
        report.situation = "DEVELOPING"
    else
        report.situation = "STABLE"
    end
    
    brain_state.situation_report = report
    state.set("brain", brain_state)
    return report
end

-------------------------------------------------------------------------------
-- Decision Confidence
-------------------------------------------------------------------------------

function calculate_decision_confidence(problem)
    local brain_state = state.get("brain") or {}
    local confidence = 50  -- Base confidence
    
    -- Increase based on past success
    local successes = brain_state.successes or {}
    if successes[problem.type] then
        confidence = confidence + math.min(30, successes[problem.type] * 5)
    end
    
    -- Decrease based on past failures
    local failures = brain_state.failures or {}
    if failures[problem.type] then
        confidence = confidence - math.min(40, failures[problem.type].count * 10)
    end
    
    -- Increase if we have resources
    if problem.handler == "workshop" or problem.handler == "building" then
        local resources = brain_state.resources or {}
        if (resources.wood or 0) > 20 and (resources.bars or 0) > 10 then
            confidence = confidence + 10
        end
    end
    
    return math.max(0, math.min(100, confidence))
end

return _ENV

