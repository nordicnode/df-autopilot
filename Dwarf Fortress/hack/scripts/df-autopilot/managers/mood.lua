-- df-autopilot/managers/mood.lua
-- Mood and happiness management
-- Monitors dwarf stress and ensures needs fulfillment

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "mood"
local last_check = 0
local CHECK_INTERVAL = 500

-------------------------------------------------------------------------------
-- Stress Levels
-------------------------------------------------------------------------------

-- Stress thresholds (approximate values from game)
local STRESS_LEVELS = {
    ECSTATIC = -100000,
    JOYOUS = -50000,
    CONTENT = 0,
    FINE = 25000,
    STRESSED = 50000,
    UNHAPPY = 100000,
    VERY_UNHAPPY = 150000,
    MISERABLE = 200000,
    -- Beyond 250k is tantrum territory
}

--- Get stress level category for a unit
local function get_stress_category(unit)
    if not unit.status or not unit.status.current_soul then
        return "UNKNOWN", 0
    end
    
    local stress = unit.status.current_soul.personality.stress
    
    if stress <= STRESS_LEVELS.ECSTATIC then
        return "ECSTATIC", stress
    elseif stress <= STRESS_LEVELS.JOYOUS then
        return "JOYOUS", stress
    elseif stress <= STRESS_LEVELS.CONTENT then
        return "CONTENT", stress
    elseif stress <= STRESS_LEVELS.FINE then
        return "FINE", stress
    elseif stress <= STRESS_LEVELS.STRESSED then
        return "STRESSED", stress
    elseif stress <= STRESS_LEVELS.UNHAPPY then
        return "UNHAPPY", stress
    elseif stress <= STRESS_LEVELS.VERY_UNHAPPY then
        return "VERY_UNHAPPY", stress
    else
        return "MISERABLE", stress
    end
end

--- Count dwarves at each stress level
local function count_stress_levels()
    local counts = {
        happy = 0,      -- ECSTATIC, JOYOUS, CONTENT
        neutral = 0,    -- FINE
        stressed = 0,   -- STRESSED
        unhappy = 0,    -- UNHAPPY, VERY_UNHAPPY
        critical = 0    -- MISERABLE (tantrum risk)
    }
    
    local citizens = utils.get_citizens()
    for _, unit in ipairs(citizens) do
        local category, _ = get_stress_category(unit)
        
        if category == "ECSTATIC" or category == "JOYOUS" or category == "CONTENT" then
            counts.happy = counts.happy + 1
        elseif category == "FINE" then
            counts.neutral = counts.neutral + 1
        elseif category == "STRESSED" then
            counts.stressed = counts.stressed + 1
        elseif category == "UNHAPPY" or category == "VERY_UNHAPPY" then
            counts.unhappy = counts.unhappy + 1
        elseif category == "MISERABLE" then
            counts.critical = counts.critical + 1
        end
    end
    
    return counts
end

--- Get the most stressed dwarves
local function get_stressed_dwarves()
    local stressed = {}
    local citizens = utils.get_citizens()
    
    for _, unit in ipairs(citizens) do
        local category, stress = get_stress_category(unit)
        if category == "UNHAPPY" or category == "VERY_UNHAPPY" or category == "MISERABLE" then
            table.insert(stressed, {
                unit = unit,
                category = category,
                stress = stress,
                name = dfhack.units.getReadableName(unit)
            })
        end
    end
    
    -- Sort by stress (highest first)
    table.sort(stressed, function(a, b) return a.stress > b.stress end)
    
    return stressed
end

-------------------------------------------------------------------------------
-- Needs Checking (v50+ compatible)
-------------------------------------------------------------------------------

--- Check if zone of a specific type exists
local function has_zone_type(target_type)
    local ok, result = pcall(function()
        for _, zone in pairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if zone.type == target_type then
                return true
            end
        end
        return false
    end)
    
    if ok then return result end
    return false
end

--- Check if temple exists
local function has_temple()
    return has_zone_type(df.civzone_type.Temple)
end

--- Check if tavern exists
local function has_tavern()
    return has_zone_type(df.civzone_type.Tavern) or 
           has_zone_type(df.civzone_type.Inn)
end

--- Check if library exists
local function has_library()
    return has_zone_type(df.civzone_type.Library)
end

--- Get needs recommendations
local function get_needs_recommendations()
    local recommendations = {}
    
    if not has_temple() then
        table.insert(recommendations, "Create a temple zone for spiritual needs")
    end
    
    if not has_tavern() then
        table.insert(recommendations, "Create a tavern for socialization")
    end
    
    if not has_library() then
        table.insert(recommendations, "Create a library for scholarly dwarves")
    end
    
    return recommendations
end

-------------------------------------------------------------------------------
-- Tantrum Spiral Detection
-------------------------------------------------------------------------------

--- Check for tantrum spiral risk
local function check_tantrum_risk()
    local counts = count_stress_levels()
    local population = utils.get_population()
    
    if population == 0 then return false, 0 end
    
    local crisis_ratio = (counts.critical + counts.unhappy) / population
    
    -- If more than 20% of population is unhappy, we have a problem
    if crisis_ratio > 0.2 then
        return true, crisis_ratio
    end
    
    -- If any dwarves are at critical stress, warn
    if counts.critical > 0 then
        return true, crisis_ratio
    end
    
    return false, crisis_ratio
end

-------------------------------------------------------------------------------
-- Strange Mood Detection
-------------------------------------------------------------------------------

--- Get mood type name
local function get_mood_name(mood_type)
    local names = {
        [df.mood_type.Fey] = "Fey",
        [df.mood_type.Secretive] = "Secretive",
        [df.mood_type.Possessed] = "Possessed",
        [df.mood_type.Macabre] = "Macabre",
        [df.mood_type.Fell] = "Fell",
        [df.mood_type.Berserk] = "Berserk",
    }
    return names[mood_type] or "Unknown"
end

--- Find dwarves in strange moods
local function find_moody_dwarves()
    local moody = {}
    
    local ok, _ = pcall(function()
        local citizens = utils.get_citizens()
        
        for _, unit in ipairs(citizens) do
            if unit.mood >= 0 then
                local mood_info = {
                    unit = unit,
                    name = dfhack.units.getReadableName(unit),
                    mood_type = unit.mood,
                    mood_name = get_mood_name(unit.mood),
                    -- Check if claimed a workshop
                    has_workshop = unit.job.current_job ~= nil
                }
                table.insert(moody, mood_info)
            end
        end
    end)
    
    return moody
end

--- Check for dwarves stuck in mood (no workshop claimed)
local function check_stuck_moods()
    local stuck = {}
    local moody = find_moody_dwarves()
    
    for _, info in ipairs(moody) do
        if not info.has_workshop then
            -- Dwarf is in mood but hasn't claimed a workshop
            table.insert(stuck, info)
        end
    end
    
    return stuck
end

--- Get material recommendations for moods
local function get_mood_material_recommendations()
    local recommendations = {}
    
    -- Check for common mood materials
    local wood_count = utils.count_items(df.item_type.WOOD, nil)
    local stone_count = utils.count_items(df.item_type.BOULDER, nil)
    local bone_count = utils.count_items(df.item_type.BONE, nil)
    local gem_count = utils.count_items(df.item_type.SMALLGEM, nil)
    local bar_count = utils.count_items(df.item_type.BAR, nil)
    local cloth_count = utils.count_items(df.item_type.CLOTH, nil)
    local leather_count = utils.count_items(df.item_type.SKIN_TANNED, nil)
    
    if wood_count < 5 then
        table.insert(recommendations, "Need wood for moods - chop trees!")
    end
    if stone_count < 10 then
        table.insert(recommendations, "Need stone for moods - mine more!")
    end
    if gem_count < 3 then
        table.insert(recommendations, "Need gems for moods - explore deeper!")
    end
    if bar_count < 5 then
        table.insert(recommendations, "Need metal bars - smelt ores!")
    end
    if leather_count < 3 then
        table.insert(recommendations, "Need leather - butcher animals!")
    end
    if cloth_count < 3 then
        table.insert(recommendations, "Need cloth - weave thread!")
    end
    
    return recommendations
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
    
    local population = utils.get_population()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    -- Count stress levels
    local stress_counts = count_stress_levels()
    mgr_state.stress_counts = stress_counts
    
    -- Check needs infrastructure (wrapped in pcall for safety)
    local ok1, temple = pcall(has_temple)
    local ok2, tavern = pcall(has_tavern)
    local ok3, library = pcall(has_library)
    
    mgr_state.has_temple = ok1 and temple or false
    mgr_state.has_tavern = ok2 and tavern or false
    mgr_state.has_library = ok3 and library or false
    
    -- Check tantrum risk
    local tantrum_risk, crisis_ratio = check_tantrum_risk()
    mgr_state.tantrum_risk = tantrum_risk
    mgr_state.crisis_ratio = crisis_ratio
    
    mgr_state.population = population
    mgr_state.last_check = current_tick
    
    -- Alert on tantrum risk
    if tantrum_risk and not mgr_state.tantrum_warned then
        utils.log_warn("TANTRUM SPIRAL RISK DETECTED!")
        utils.log_warn(string.format("  Critical: %d, Unhappy: %d, Population: %d",
            stress_counts.critical, stress_counts.unhappy, population))
        
        local stressed = get_stressed_dwarves()
        for i = 1, math.min(3, #stressed) do
            local d = stressed[i]
            utils.log_warn(string.format("  - %s (%s)", d.name, d.category))
        end
        
        mgr_state.tantrum_warned = true
    elseif not tantrum_risk and mgr_state.tantrum_warned then
        utils.log("Tantrum risk has subsided")
        mgr_state.tantrum_warned = false
    end
    
    state.set_manager_state(MANAGER_NAME, mgr_state)
    
    -- Log recommendations (occasionally)
    if not mgr_state.last_recommendation_tick or
       current_tick - mgr_state.last_recommendation_tick > 10000 then
        local recommendations = get_needs_recommendations()
        if #recommendations > 0 then
            utils.log_debug("Mood/needs recommendations:")
            for _, rec in ipairs(recommendations) do
                utils.log_debug("  - " .. rec)
            end
        end
        mgr_state.last_recommendation_tick = current_tick
        state.set_manager_state(MANAGER_NAME, mgr_state)
    end
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state.stress_counts then
        return "waiting"
    end
    
    local counts = mgr_state.stress_counts
    
    if mgr_state.tantrum_risk then
        return string.format("RISK! critical: %d, unhappy: %d",
            counts.critical or 0,
            counts.unhappy or 0
        )
    end
    
    return string.format("happy: %d, stressed: %d",
        counts.happy or 0,
        (counts.stressed or 0) + (counts.unhappy or 0)
    )
end

return _ENV
