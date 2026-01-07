-- df-autopilot/managers/military.lua
-- Military and defense management
-- Handles squad creation, training, and threat response

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "military"
local last_check = 0
local CHECK_INTERVAL = 500

-------------------------------------------------------------------------------
-- Internal Functions
-------------------------------------------------------------------------------

--- Count existing military squads
local function count_squads()
    local count = 0
    for _, squad in pairs(df.global.world.squads.all) do
        if squad.entity_id == df.global.plotinfo.group_id then
            count = count + 1
        end
    end
    return count
end

--- Count soldiers in all squads
local function count_soldiers()
    local count = 0
    for _, squad in pairs(df.global.world.squads.all) do
        if squad.entity_id == df.global.plotinfo.group_id then
            for _, position in pairs(squad.positions) do
                if position.occupant ~= -1 then
                    count = count + 1
                end
            end
        end
    end
    return count
end

--- Get all squads for our fortress
local function get_squads()
    local squads = {}
    for _, squad in pairs(df.global.world.squads.all) do
        if squad.entity_id == df.global.plotinfo.group_id then
            table.insert(squads, squad)
        end
    end
    return squads
end

--- Check if a dwarf is already in a squad
local function is_in_squad(unit)
    return unit.military.squad_id ~= -1
end

--- Get dwarves suitable for military duty
local function get_potential_soldiers()
    local candidates = {}
    local citizens = utils.get_citizens()
    
    for _, unit in ipairs(citizens) do
        -- Skip children, nobles, and those already in military
        if not dfhack.units.isChild(unit) and 
           not dfhack.units.isBaby(unit) and
           not is_in_squad(unit) then
            -- Check if they have combat skills or are just healthy adults
            table.insert(candidates, unit)
        end
    end
    
    return candidates
end

--- Calculate desired military size
local function get_target_military_size()
    local population = utils.get_population()
    local ratio = config.get("military.military_ratio", 0.2)
    local min_size = config.get("military.min_squad_size", 4)
    
    return math.max(min_size, math.floor(population * ratio))
end

--- Order weapon production
local function ensure_weapons()
    -- Check if we have enough weapons
    local weapon_count = utils.count_items(df.item_type.WEAPON, nil)
    local soldiers = count_soldiers()
    
    if weapon_count < soldiers + 5 then
        -- Queue weapon production
        if not utils.order_exists(df.job_type.MakeWeapon, 0) then
            if utils.has_metal_bars(5) then
                -- Make metal weapons if we have bars
                utils.create_order(df.job_type.MakeWeapon, 5)
            else
                -- Fallback: wooden training weapons
                -- Note: MakeWeapon usually defaults to metal at forge, wood at carpenter
                -- We assume standard manager order logic here, or specialized auto-job
                -- For now, we trust the manager to pick available materials or stall safely
                -- But logging a warning is good.
                utils.log_debug("No metal bars for weapons, skipping order", MANAGER_NAME)
            end
        end
    end
end

--- Order armor production  
local function ensure_armor()
    local armor_count = utils.count_items(df.item_type.ARMOR, nil)
    local soldiers = count_soldiers()
    
    if armor_count < soldiers then
        if not utils.order_exists(df.job_type.MakeArmor, 0) then
             if utils.has_metal_bars(5) then
                utils.create_order(df.job_type.MakeArmor, 3)
             else
                utils.log_debug("No metal bars for armor, skipping order", MANAGER_NAME)
             end
        end
    end
end

-------------------------------------------------------------------------------
-- Threat Detection
-------------------------------------------------------------------------------

--- Check for hostile units on the map
local function detect_threats()
    local threats = {}
    
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isAlive(unit) and 
           not dfhack.units.isCitizen(unit) and
           not dfhack.units.isTame(unit) then
            -- Check if hostile
            local civ = dfhack.units.getCivId(unit)
            if dfhack.units.isInvader(unit) or 
               dfhack.units.isOpponent(unit) then
                table.insert(threats, unit)
            end
        end
    end
    
    return threats
end

--- Check for siege announcement
local function is_under_siege()
    -- Check recent announcements for siege-related text
    -- This is a simplified check
    local reports = df.global.world.status.reports
    if #reports > 0 then
        -- Check last few reports
        local start_idx = math.max(0, #reports - 10)
        for i = start_idx, #reports - 1 do
            local report = reports[i]
            if report and report.text then
                local text = dfhack.df2utf(report.text):lower()
                if text:find("siege") or text:find("ambush") or 
                   text:find("invaders") or text:find("attack") then
                    return true
                end
            end
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Squad Creation (v53.08 compatible)
-------------------------------------------------------------------------------

--- Create a new military squad
local function create_squad()
    local ok, result = pcall(function()
        -- Use dfhack.military.makeSquad if available
        local make_squad_ok, squad = pcall(function()
            return dfhack.military.makeSquad(df.global.plotinfo.group_id)
        end)
        
        if make_squad_ok and squad then
            utils.log_action(MANAGER_NAME, "Created new squad", 
                "Squad ID: " .. squad.id)
            return squad
        end
        
        -- Fallback: Manual squad creation
        local squad = df.squad:new()
        
        squad.id = df.global.squad_next_id
        df.global.squad_next_id = df.global.squad_next_id + 1
        
        squad.entity_id = df.global.plotinfo.group_id
        squad.leader_position = -1
        squad.leader_assignment = -1
        squad.name.first_name = "Militia"
        squad.name.nickname = "Defenders"
        squad.alias = "Militia Squad"
        
        -- Initialize positions (10 slots)
        for i = 0, 9 do
            local position = df.squad_position:new()
            position.occupant = -1
            position.flags.whole = 0
            squad.positions:insert('#', position)
        end
        
        -- Add to world squads
        df.global.world.squads.all:insert('#', squad)
        
        -- Link to entity
        local entity = df.global.world.entities.all[df.global.plotinfo.group_id]
        if entity then
            entity.squads:insert('#', squad.id)
        end
        
        utils.log_action(MANAGER_NAME, "Created new squad (manual)", 
            "Squad ID: " .. squad.id)
        return squad
    end)
    
    if ok and result then
        return result
    end
    return nil
end

--- Assign a unit to a squad
local function assign_to_squad(unit, squad)
    if not unit or not squad then return false end
    if is_in_squad(unit) then return false end
    
    local ok, result = pcall(function()
        -- Get unit identifier (hist_figure_id if available, else use unit.id)
        local occupant_id = unit.hist_figure_id
        if not occupant_id or occupant_id == -1 then
            -- Fallback: create/get historical figure or use unit id
            local hf = dfhack.units.getHistoricalFigure(unit)
            if hf then
                occupant_id = hf.id
            else
                utils.log_debug("Unit has no historical figure, cannot assign to squad", MANAGER_NAME)
                return false
            end
        end
        
        -- Find first empty position
        for i, position in ipairs(squad.positions) do
            if position.occupant == -1 then
                position.occupant = occupant_id
                unit.military.squad_id = squad.id
                unit.military.squad_position = i
                
                utils.log_action(MANAGER_NAME, "Assigned soldier",
                    dfhack.units.getReadableName(unit) .. " to squad " .. squad.id)
                return true
            end
        end
        return false
    end)
    
    if ok then return result end
    return false
end

--- Build up the military
local function recruit_soldiers()
    local target = get_target_military_size()
    local current = count_soldiers()
    
    if current >= target then
        return -- Already have enough
    end
    
    -- Get or create a squad
    local squads = get_squads()
    local squad = squads[1]
    
    if not squad then
        squad = create_squad()
        if not squad then
            utils.log_debug("Failed to create squad", MANAGER_NAME)
            return
        end
    end
    
    -- Get candidates
    local candidates = get_potential_soldiers()
    if #candidates == 0 then
        return
    end
    
    -- Sort candidates by combat skills and physical attributes
    table.sort(candidates, function(a, b)
        local a_score = 0
        local b_score = 0
        
        local function get_score(unit)
            local score = 0
            -- Skills
            if unit.status and unit.status.current_soul then
                for _, skill in pairs(unit.status.current_soul.skills) do
                    if (skill.id >= df.job_skill.AXE and skill.id <= df.job_skill.THROW) or
                       skill.id == df.job_skill.ARMOR or skill.id == df.job_skill.SHIELD or
                       skill.id == df.job_skill.DODGING or skill.id == df.job_skill.FIGHTER then
                        score = score + skill.rating * 10
                    end
                end
            end
            
            -- Attributes (Strength, Toughness, Agility) - vital for survival
            if unit.body then
                 if unit.body.physical_attrs.STRENGTH then
                    score = score + (unit.body.physical_attrs.STRENGTH.value / 100)
                 end
                 if unit.body.physical_attrs.TOUGHNESS then
                    score = score + (unit.body.physical_attrs.TOUGHNESS.value / 100)
                 end
                 if unit.body.physical_attrs.AGILITY then
                    score = score + (unit.body.physical_attrs.AGILITY.value / 100)
                 end
                 -- Recuperation is good too
                 if unit.body.physical_attrs.RECUPERATION then
                    score = score + (unit.body.physical_attrs.RECUPERATION.value / 100)
                 end
            end
            return score
        end
        
        pcall(function()
            a_score = get_score(a)
            b_score = get_score(b)
        end)
        
        return a_score > b_score
    end)
    
    -- Assign up to (target - current) soldiers
    local to_assign = math.min(#candidates, target - current, 2) -- Max 2 per cycle
    
    for i = 1, to_assign do
        assign_to_squad(candidates[i], squad)
    end
end

--- Set all squads to active/training
local function set_squads_active(active)
    local squads = get_squads()
    
    for _, squad in ipairs(squads) do
        -- Set squad to active/training
        pcall(function()
            if active then
                -- Remove all inactive months
                squad.activity = 0  -- Clear inactive orders
            end
        end)
    end
    
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    mgr_state.squads_active = active
    state.set_manager_state(MANAGER_NAME, mgr_state)
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
    
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    -- Count current military
    local squad_count = count_squads()
    local soldier_count = count_soldiers()
    local target_size = get_target_military_size()
    
    -- Update state
    mgr_state.squad_count = squad_count
    mgr_state.soldier_count = soldier_count
    mgr_state.target_size = target_size
    mgr_state.last_check = current_tick
    
    -- Check for threats
    local threats = {}
    local ok, result = pcall(detect_threats)
    if ok then
        threats = result or {}
    end
    local under_siege = is_under_siege()
    
    mgr_state.threat_count = #threats
    mgr_state.under_siege = under_siege
    
    state.set_manager_state(MANAGER_NAME, mgr_state)
    
    -- Alert if threats detected
    if #threats > 0 and not mgr_state.threat_alerted then
        utils.log_warn("THREATS DETECTED: " .. #threats .. " hostile units!")
        mgr_state.threat_alerted = true
        set_squads_active(true)
        state.set_manager_state(MANAGER_NAME, mgr_state)
    elseif #threats == 0 and mgr_state.threat_alerted then
        utils.log("Threats cleared")
        mgr_state.threat_alerted = false
        state.set_manager_state(MANAGER_NAME, mgr_state)
    end
    
    -- Ensure equipment production
    if soldier_count > 0 then
        ensure_weapons()
        ensure_armor()
    end
    
    -- Auto-recruit soldiers if enabled
    if config.get("military.auto_recruit", true) then
        pcall(recruit_soldiers)
    end
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state.squad_count then
        return "waiting"
    end
    
    local status = string.format("squads: %d, soldiers: %d/%d",
        mgr_state.squad_count or 0,
        mgr_state.soldier_count or 0,
        mgr_state.target_size or 0
    )
    
    if mgr_state.threat_count and mgr_state.threat_count > 0 then
        status = status .. " [THREATS: " .. mgr_state.threat_count .. "]"
    end
    
    if mgr_state.under_siege then
        status = status .. " [SIEGE!]"
    end
    
    return status
end

return _ENV
