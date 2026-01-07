-- df-autopilot/managers/animal.lua
-- Animal management - integrates with DFHack autobutcher

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "animal"
local last_check = 0
local CHECK_INTERVAL = 1000

-------------------------------------------------------------------------------
-- Animal Counting
-------------------------------------------------------------------------------

--- Count animals by category
local function count_animals()
    local counts = {
        total = 0,
        tame = 0,
        wild = 0,
        livestock = 0,
        pets = 0,
        for_slaughter = 0
    }
    
    local ok, _ = pcall(function()
        for _, unit in pairs(df.global.world.units.active) do
            if dfhack.units.isAnimal(unit) and dfhack.units.isAlive(unit) then
                counts.total = counts.total + 1
                
                if dfhack.units.isTame(unit) then
                    counts.tame = counts.tame + 1
                    
                    if dfhack.units.isPet(unit) then
                        counts.pets = counts.pets + 1
                    else
                        counts.livestock = counts.livestock + 1
                    end
                else
                    counts.wild = counts.wild + 1
                end
                
                -- Check if marked for slaughter
                if unit.flags2.slaughter then
                    counts.for_slaughter = counts.for_slaughter + 1
                end
            end
        end
    end)
    
    return counts
end

--- Get animals by type for status
local function get_animal_summary()
    local types = {}
    
    local ok, _ = pcall(function()
        for _, unit in pairs(df.global.world.units.active) do
            if dfhack.units.isAnimal(unit) and dfhack.units.isAlive(unit) and dfhack.units.isTame(unit) then
                local race_name = df.global.world.raws.creatures.all[unit.race].creature_id
                types[race_name] = (types[race_name] or 0) + 1
            end
        end
    end)
    
    return types
end

-------------------------------------------------------------------------------
-- Autobutcher Integration
-------------------------------------------------------------------------------

--- Check if autobutcher is running
local function is_autobutcher_active()
    local ok, result = pcall(function()
        local output = dfhack.run_command_silent("autobutcher status")
        return output and output:find("Running") ~= nil
    end)
    
    return ok and result
end

--- Configure autobutcher for a specific race
local function configure_autobutcher_race(race, fk, mk, fa, ma)
    -- fk = female kids, mk = male kids, fa = female adults, ma = male adults
    local ok, _ = pcall(function()
        dfhack.run_command_silent(string.format(
            "autobutcher target %d %d %d %d %s",
            fk, mk, fa, ma, race
        ))
    end)
    return ok
end

--- Apply sensible defaults for common animals
local function apply_default_targets()
    local defaults = {
        -- Breeding pairs + some extras
        { race = "DOG", fk = 2, mk = 2, fa = 2, ma = 2 },
        { race = "CAT", fk = 1, mk = 1, fa = 2, ma = 1 },
        { race = "PIG", fk = 2, mk = 2, fa = 3, ma = 1 },
        { race = "COW", fk = 2, mk = 2, fa = 3, ma = 1 },
        { race = "SHEEP", fk = 2, mk = 2, fa = 4, ma = 1 },
        { race = "CHICKEN", fk = 3, mk = 0, fa = 5, ma = 1 },
        { race = "TURKEY", fk = 3, mk = 0, fa = 5, ma = 1 },
        { race = "GOOSE", fk = 3, mk = 0, fa = 5, ma = 1 },
        { race = "DUCK", fk = 3, mk = 0, fa = 5, ma = 1 },
    }
    
    for _, cfg in ipairs(defaults) do
        configure_autobutcher_race(cfg.race, cfg.fk, cfg.mk, cfg.fa, cfg.ma)
    end
    
    utils.log_action(MANAGER_NAME, "Applied autobutcher defaults", #defaults .. " races configured")
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
    
    -- Count animals
    local counts = count_animals()
    mgr_state.total = counts.total
    mgr_state.tame = counts.tame
    mgr_state.livestock = counts.livestock
    mgr_state.pets = counts.pets
    mgr_state.for_slaughter = counts.for_slaughter
    
    -- Check autobutcher status
    mgr_state.autobutcher_active = is_autobutcher_active()
    
    -- Apply defaults if first run
    if not mgr_state.defaults_applied and mgr_state.autobutcher_active then
        if config.get("animal.apply_defaults", true) then
            apply_default_targets()
            mgr_state.defaults_applied = true
        end
    end
    
    mgr_state.last_check = current_tick
    state.set_manager_state(MANAGER_NAME, mgr_state)
end

function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state or not mgr_state.total then
        return "waiting"
    end
    
    local status = string.format("animals: %d (%d tame, %d livestock)",
        mgr_state.total or 0,
        mgr_state.tame or 0,
        mgr_state.livestock or 0
    )
    
    if mgr_state.for_slaughter and mgr_state.for_slaughter > 0 then
        status = status .. ", " .. mgr_state.for_slaughter .. " for slaughter"
    end
    
    return status
end

return _ENV
