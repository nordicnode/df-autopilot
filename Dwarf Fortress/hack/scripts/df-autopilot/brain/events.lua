-- df-autopilot/brain/events.lua
-- Emergent event detection and response system
-- Handles: sieges, beasts, tantrums, starvation, moods, etc.

--@ module = true

local utils = reqscript("df-autopilot/utils")
local state = reqscript("df-autopilot/state")

-------------------------------------------------------------------------------
-- Event Type Definitions
-------------------------------------------------------------------------------

EVENT_TYPES = {
    -- Immediate dangers
    SIEGE = {severity = 10, response = "lockdown"},
    FORGOTTEN_BEAST = {severity = 10, response = "military"},
    MEGABEAST = {severity = 10, response = "military"},
    WEREBEAST = {severity = 9, response = "lockdown"},
    VAMPIRE = {severity = 7, response = "investigation"},
    NECROMANCER_SIEGE = {severity = 10, response = "lockdown"},
    
    -- Environmental hazards
    CAVE_IN = {severity = 8, response = "rescue"},
    FLOOD = {severity = 9, response = "drainage"},
    MAGMA_BREACH = {severity = 10, response = "evacuation"},
    FIRE = {severity = 8, response = "evacuation"},
    
    -- Social crises
    TANTRUM_SPIRAL = {severity = 8, response = "happiness"},
    STRANGE_MOOD = {severity = 5, response = "materials"},
    MOOD_FAILURE = {severity = 6, response = "containment"},
    INSANITY = {severity = 7, response = "containment"},
    
    -- Administrative
    NOBLE_DEMAND = {severity = 3, response = "production"},
    MANDATE = {severity = 4, response = "production"},
    KING_ARRIVAL = {severity = 2, response = "preparation"},
    
    -- Economic
    STARVATION = {severity = 10, response = "food_emergency"},
    DEHYDRATION = {severity = 10, response = "drink_emergency"},
    
    -- Military
    AMBUSH = {severity = 9, response = "military"},
    THIEF = {severity = 4, response = "military"}
}

-------------------------------------------------------------------------------
-- Event Detection
-------------------------------------------------------------------------------

--- Detect emergent events that require immediate attention
function detect_emergent_events()
    local events = {}
    local brain_state = state.get("brain") or {}
    
    -- Check dwarf stress levels
    local stressed_count = 0
    local tantrum_risk = 0
    local starving_count = 0
    local dehydrated_count = 0
    local injured_count = 0
    
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) then
            -- Check stress (higher = more stressed)
            local stress = unit.status.current_soul and 
                           unit.status.current_soul.personality.stress or 0
            
            if stress > 100000 then
                tantrum_risk = tantrum_risk + 1
            elseif stress > 50000 then
                stressed_count = stressed_count + 1
            end
            
            -- Check for hunger/thirst
            local counters = unit.counters2
            if counters then
                if counters.hunger_timer and counters.hunger_timer > 50000 then
                    starving_count = starving_count + 1
                end
                if counters.thirst_timer and counters.thirst_timer > 50000 then
                    dehydrated_count = dehydrated_count + 1
                end
            end
            
            -- Check for injuries
            if unit.body and unit.body.wounds and #unit.body.wounds > 0 then
                injured_count = injured_count + 1
            end
        end
    end
    
    -- Tantrum spiral risk
    if tantrum_risk >= 3 then
        table.insert(events, {
            type = "TANTRUM_SPIRAL",
            severity = EVENT_TYPES.TANTRUM_SPIRAL.severity,
            response = EVENT_TYPES.TANTRUM_SPIRAL.response,
            message = tantrum_risk .. " dwarves near tantrum!",
            data = {count = tantrum_risk}
        })
    end
    
    -- Starvation emergency
    if starving_count >= 2 then
        table.insert(events, {
            type = "STARVATION",
            severity = EVENT_TYPES.STARVATION.severity,
            response = EVENT_TYPES.STARVATION.response,
            message = starving_count .. " dwarves starving!",
            data = {count = starving_count}
        })
    end
    
    -- Dehydration emergency
    if dehydrated_count >= 2 then
        table.insert(events, {
            type = "DEHYDRATION",
            severity = EVENT_TYPES.DEHYDRATION.severity,
            response = EVENT_TYPES.DEHYDRATION.response,
            message = dehydrated_count .. " dwarves dehydrated!",
            data = {count = dehydrated_count}
        })
    end
    
    -- Check for strange moods
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) then
            local job = unit.job.current_job
            if job then
                local job_type = job.job_type
                if job_type == df.job_type.StrangeMoodCrafter or
                   job_type == df.job_type.StrangeMoodJeweller or
                   job_type == df.job_type.StrangeMoodForge or
                   job_type == df.job_type.StrangeMoodMagmaForge or
                   job_type == df.job_type.StrangeMoodBrooding or
                   job_type == df.job_type.StrangeMoodFell or
                   job_type == df.job_type.StrangeMoodMason or
                   job_type == df.job_type.StrangeMoodCarpenter then
                    local unit_name = "Unknown"
                    pcall(function()
                        local vn = dfhack.units.getVisibleName(unit)
                        if vn then unit_name = dfhack.TranslateName(vn) or "Unknown" end
                    end)
                    table.insert(events, {
                        type = "STRANGE_MOOD",
                        severity = EVENT_TYPES.STRANGE_MOOD.severity,
                        response = EVENT_TYPES.STRANGE_MOOD.response,
                        message = unit_name .. " in strange mood",
                        data = {unit_id = unit.id}
                    })
                end
            end
        end
    end
    
    -- Check threat manager for military threats
    local threat_state = state.get_manager_state("threat")
    if threat_state then
        if threat_state.forgotten_beasts and threat_state.forgotten_beasts > 0 then
            table.insert(events, {
                type = "FORGOTTEN_BEAST",
                severity = EVENT_TYPES.FORGOTTEN_BEAST.severity,
                response = EVENT_TYPES.FORGOTTEN_BEAST.response,
                message = "Forgotten beast detected!",
                data = {count = threat_state.forgotten_beasts}
            })
        end
        if threat_state.megabeasts and threat_state.megabeasts > 0 then
            table.insert(events, {
                type = "MEGABEAST",
                severity = EVENT_TYPES.MEGABEAST.severity,
                response = EVENT_TYPES.MEGABEAST.response,
                message = "Megabeast attack!",
                data = {count = threat_state.megabeasts}
            })
        end
        if threat_state.invaders and threat_state.invaders > 0 then
            table.insert(events, {
                type = "SIEGE",
                severity = EVENT_TYPES.SIEGE.severity,
                response = EVENT_TYPES.SIEGE.response,
                message = threat_state.invaders .. " invaders!",
                data = {count = threat_state.invaders}
            })
        end
        if threat_state.undead and threat_state.undead > 0 then
            table.insert(events, {
                type = "NECROMANCER_SIEGE",
                severity = EVENT_TYPES.NECROMANCER_SIEGE.severity,
                response = EVENT_TYPES.NECROMANCER_SIEGE.response,
                message = "Undead attack! " .. threat_state.undead .. " risen",
                data = {count = threat_state.undead}
            })
        end
    end
    
    -- Store events and stats
    brain_state.emergent_events = events
    brain_state.dwarf_health = {
        stressed = stressed_count,
        tantrum_risk = tantrum_risk,
        starving = starving_count,
        dehydrated = dehydrated_count,
        injured = injured_count
    }
    state.set("brain", brain_state)
    
    -- Log critical events
    for _, event in ipairs(events) do
        if event.severity >= 8 then
            utils.log_warn("EMERGENCY: " .. event.message, "brain")
        elseif event.severity >= 5 then
            utils.log("EVENT: " .. event.message, "brain")
        end
    end
    
    return events
end

-------------------------------------------------------------------------------
-- Event Response
-------------------------------------------------------------------------------

-- Manager loader (passed from brain core)
local manager_loader = nil

function set_manager_loader(loader)
    manager_loader = loader
end

--- Execute response to emergent event
function respond_to_event(event)
    if not event then return false end
    
    utils.log(string.format("Responding to %s: %s", event.type, event.response), "brain")
    
    local brain_state = state.get("brain") or {}
    brain_state.last_response = {
        type = event.type,
        tick = df.global.cur_year_tick,
        response = event.response
    }
    
    -- Response handlers
    local function get_manager(name)
        if manager_loader then
            return manager_loader(name)
        end
        return nil
    end
    
    if event.response == "lockdown" then
        local emergency_mgr = get_manager("emergency")
        if emergency_mgr and emergency_mgr.update then
            emergency_mgr.update()
        end
        
    elseif event.response == "military" then
        local military_mgr = get_manager("military")
        if military_mgr and military_mgr.update then
            military_mgr.update()
        end
        
    elseif event.response == "food_emergency" then
        local food_mgr = get_manager("food")
        if food_mgr and food_mgr.update then
            food_mgr.update()
        end
        
    elseif event.response == "drink_emergency" then
        local food_mgr = get_manager("food")
        if food_mgr and food_mgr.update then
            food_mgr.update()
        end
        
    elseif event.response == "happiness" then
        local zone_mgr = get_manager("zone")
        if zone_mgr and zone_mgr.update then
            zone_mgr.update()
        end
        
    elseif event.response == "materials" then
        local workshop_mgr = get_manager("workshop")
        if workshop_mgr and workshop_mgr.update then
            workshop_mgr.update()
        end
    end
    
    state.set("brain", brain_state)
    return true
end

return _ENV
