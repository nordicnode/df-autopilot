-- df-autopilot/managers/threat.lua
-- Unified threat detection for autonomous play
-- Handles: forgotten beasts, werecreatures, vampires, necromancers, etc.

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "threat"
local last_check = 0
local CHECK_INTERVAL = 200  -- Check frequently for threats

-------------------------------------------------------------------------------
-- Threat Categories
-------------------------------------------------------------------------------

local THREAT_TYPES = {
    FORGOTTEN_BEAST = "forgotten_beast",
    MEGABEAST = "megabeast",
    WERECREATURE = "werecreature",
    VAMPIRE = "vampire",
    NECROMANCER = "necromancer",
    UNDEAD = "undead",
    INVADER = "invader",
    TITAN = "titan",
    DEMON = "demon"
}

-------------------------------------------------------------------------------
-- Detection Functions
-------------------------------------------------------------------------------

--- Check if unit is a forgotten beast
local function is_forgotten_beast(unit)
    if not unit or not unit.enemy then return false end
    local caste = df.creature_raw.find(unit.race)
    if caste and caste.flags.GENERATED then
        -- Generated creatures include FBs
        return true
    end
    return false
end

--- Check if unit is a megabeast
local function is_megabeast(unit)
    if not unit then return false end
    local creature = df.creature_raw.find(unit.race)
    if creature then
        return creature.flags.MEGABEAST
    end
    return false
end

--- Check if unit is a titan
local function is_titan(unit)
    if not unit then return false end
    local creature = df.creature_raw.find(unit.race)
    if creature then
        return creature.flags.TITAN
    end
    return false
end

--- Check if unit is a werecreature
local function is_werecreature(unit)
    if not unit then return false end
    -- Check for werebeast syndrome
    for _, syndrome in pairs(unit.syndromes.active) do
        local syn_raw = df.syndrome.find(syndrome.type)
        if syn_raw and syn_raw.syn_name:lower():find("were") then
            return true
        end
    end
    -- Also check creature type
    local creature = df.creature_raw.find(unit.race)
    if creature and creature.creature_id:lower():find("were") then
        return true
    end
    return false
end

--- Check if unit is a vampire
local function is_vampire(unit)
    if not unit then return false end
    -- Check for vampire curse
    for _, syndrome in pairs(unit.syndromes.active) do
        local syn_raw = df.syndrome.find(syndrome.type)
        if syn_raw and (syn_raw.syn_name:lower():find("vampire") or
                        syn_raw.syn_name:lower():find("blood drinker")) then
            return true
        end
    end
    -- Check history for vampire info
    local hf = dfhack.units.getHistoricalFigure(unit)
    if hf then
        for _, info in pairs(hf.info.skills) do
            -- Vampires often have unusual attributes
        end
    end
    return false
end

--- Check if unit is undead
local function is_undead(unit)
    if not unit then return false end
    return unit.flags1.zombie or unit.flags1.skeleton or 
           unit.flags3.ghostly
end

--- Check if unit is a necromancer
local function is_necromancer(unit)
    if not unit then return false end
    -- Check for necromancer syndrome/trait
    for _, syndrome in pairs(unit.syndromes.active) do
        local syn_raw = df.syndrome.find(syndrome.type)
        if syn_raw and syn_raw.syn_name:lower():find("secret") then
            return true
        end
    end
    return false
end

--- Scan all units for threats
local function scan_for_threats()
    local threats = {
        forgotten_beasts = {},
        megabeasts = {},
        titans = {},
        werecreatures = {},
        vampires = {},
        undead = {},
        necromancers = {},
        invaders = {},
        total = 0
    }
    
    local ok, _ = pcall(function()
        for _, unit in pairs(df.global.world.units.active) do
            if dfhack.units.isAlive(unit) then
                local pos = {x = unit.pos.x, y = unit.pos.y, z = unit.pos.z}
                
                -- Check various threat types
                if is_forgotten_beast(unit) then
                    table.insert(threats.forgotten_beasts, {unit = unit, pos = pos})
                    threats.total = threats.total + 1
                elseif is_megabeast(unit) then
                    table.insert(threats.megabeasts, {unit = unit, pos = pos})
                    threats.total = threats.total + 1
                elseif is_titan(unit) then
                    table.insert(threats.titans, {unit = unit, pos = pos})
                    threats.total = threats.total + 1
                elseif is_werecreature(unit) then
                    table.insert(threats.werecreatures, {unit = unit, pos = pos})
                    threats.total = threats.total + 1
                elseif is_vampire(unit) then
                    -- Only count hostile vampires or vampire citizens
                    if dfhack.units.isCitizen(unit) then
                        table.insert(threats.vampires, {unit = unit, pos = pos, citizen = true})
                        threats.total = threats.total + 1
                    end
                elseif is_undead(unit) then
                    if not dfhack.units.isCitizen(unit) then
                        table.insert(threats.undead, {unit = unit, pos = pos})
                        threats.total = threats.total + 1
                    end
                elseif is_necromancer(unit) then
                    if unit.flags1.marauder or unit.flags1.active_invader then
                        table.insert(threats.necromancers, {unit = unit, pos = pos})
                        threats.total = threats.total + 1
                    end
                end
                
                -- General invader check
                if unit.flags1.active_invader or unit.flags1.marauder then
                    if not is_forgotten_beast(unit) and not is_megabeast(unit) then
                        table.insert(threats.invaders, {unit = unit, pos = pos})
                        threats.total = threats.total + 1
                    end
                end
            end
        end
    end)
    
    return threats
end

-------------------------------------------------------------------------------
-- Response Functions
-------------------------------------------------------------------------------

--- Log detected threats
local function report_threats(threats)
    if #threats.forgotten_beasts > 0 then
        utils.log_warn("THREAT: " .. #threats.forgotten_beasts .. " Forgotten Beast(s) detected!", MANAGER_NAME)
    end
    if #threats.megabeasts > 0 then
        utils.log_warn("THREAT: " .. #threats.megabeasts .. " Megabeast(s) detected!", MANAGER_NAME)
    end
    if #threats.titans > 0 then
        utils.log_warn("THREAT: " .. #threats.titans .. " Titan(s) detected!", MANAGER_NAME)
    end
    if #threats.werecreatures > 0 then
        utils.log_warn("THREAT: " .. #threats.werecreatures .. " Werecreature(s) detected!", MANAGER_NAME)
    end
    if #threats.vampires > 0 then
        utils.log_warn("WARNING: " .. #threats.vampires .. " Vampire citizen(s) detected!", MANAGER_NAME)
    end
    if #threats.undead > 0 then
        utils.log_warn("THREAT: " .. #threats.undead .. " Undead detected!", MANAGER_NAME)
    end
    if #threats.necromancers > 0 then
        utils.log_warn("THREAT: " .. #threats.necromancers .. " Necromancer(s) detected!", MANAGER_NAME)
    end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function update()
    local current_tick = df.global.cur_year_tick
    if current_tick - last_check < CHECK_INTERVAL then
        return
    end
    last_check = current_tick
    
    local mgr_state = state.get_manager_state(MANAGER_NAME) or {}
    
    -- Scan for threats
    local threats = scan_for_threats()
    
    -- Store threat counts
    mgr_state.forgotten_beasts = #threats.forgotten_beasts
    mgr_state.megabeasts = #threats.megabeasts
    mgr_state.titans = #threats.titans
    mgr_state.werecreatures = #threats.werecreatures
    mgr_state.vampires = #threats.vampires
    mgr_state.undead = #threats.undead
    mgr_state.necromancers = #threats.necromancers
    mgr_state.invaders = #threats.invaders
    mgr_state.total_threats = threats.total
    
    -- Report new threats
    local was_threat = mgr_state.had_threats or false
    local has_threat = threats.total > 0
    
    if has_threat and not was_threat then
        report_threats(threats)
    end
    
    mgr_state.had_threats = has_threat
    mgr_state.last_check = current_tick
    state.set_manager_state(MANAGER_NAME, mgr_state)
    
    -- Return threats for emergency manager
    return threats
end

function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state or mgr_state.total_threats == nil then
        return "scanning"
    end
    
    if mgr_state.total_threats == 0 then
        return "all clear"
    end
    
    local parts = {}
    if mgr_state.forgotten_beasts > 0 then table.insert(parts, mgr_state.forgotten_beasts .. " FB") end
    if mgr_state.megabeasts > 0 then table.insert(parts, mgr_state.megabeasts .. " mega") end
    if mgr_state.titans > 0 then table.insert(parts, mgr_state.titans .. " titan") end
    if mgr_state.werecreatures > 0 then table.insert(parts, mgr_state.werecreatures .. " were") end
    if mgr_state.vampires > 0 then table.insert(parts, mgr_state.vampires .. " vamp") end
    if mgr_state.undead > 0 then table.insert(parts, mgr_state.undead .. " undead") end
    if mgr_state.invaders > 0 then table.insert(parts, mgr_state.invaders .. " inv") end
    
    return "THREATS: " .. table.concat(parts, ", ")
end

return _ENV
