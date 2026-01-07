-- df-autopilot/managers/emergency.lua
-- Emergency and crisis response
-- Handles sieges, forgotten beasts, floods, and other emergencies

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "emergency"
local last_check = 0
local CHECK_INTERVAL = 100  -- Check frequently for emergencies

-------------------------------------------------------------------------------
-- Emergency Detection
-------------------------------------------------------------------------------

--- Check for invaders on the map
local function detect_invaders()
    local invaders = {}
    
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isAlive(unit) then
            local ok, is_invader = pcall(dfhack.units.isInvader, unit)
            if ok and is_invader then
                table.insert(invaders, unit)
            end
        end
    end
    
    return invaders
end

--- Check for dangerous creatures (forgotten beasts, titans, etc.)
local function detect_megabeasts()
    local beasts = {}
    
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isAlive(unit) and not dfhack.units.isCitizen(unit) then
            local caste = dfhack.units.getCasteRaw(unit)
            if caste then
                -- Check for megabeast/semimegabeast flags
                if caste.flags.MEGABEAST or 
                   caste.flags.SEMIMEGABEAST or
                   caste.flags.FEATURE_BEAST then
                    table.insert(beasts, unit)
                end
            end
        end
    end
    
    return beasts
end

--- Check for fire on the map
local function detect_fire()
    -- Check for fire-related flows
    local fires = 0
    
    -- Simple check: look for units on fire
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isAlive(unit) and dfhack.units.isCitizen(unit) then
            if unit.flags2.calculated_nerves and unit.body.blood_count <= 0 then
                -- This is a rough proxy, not actual fire detection
            end
        end
    end
    
    return fires
end

--- Check for flooding (water in living areas)
local function detect_flooding()
    -- This would require checking tile flow values
    -- Simplified: just check announcements
    local reports = df.global.world.status.reports
    if #reports > 0 then
        local start_idx = math.max(0, #reports - 20)
        for i = start_idx, #reports - 1 do
            local report = reports[i]
            if report and report.text then
                local text = dfhack.df2utf(report.text):lower()
                if text:find("flood") or text:find("drowned") then
                    return true
                end
            end
        end
    end
    return false
end

--- Check recent announcements for emergency keywords
local function check_announcements()
    local emergencies = {}
    local reports = df.global.world.status.reports
    
    if #reports == 0 then
        return emergencies
    end
    
    local start_idx = math.max(0, #reports - 30)
    local current_year = df.global.cur_year
    local current_tick = df.global.cur_year_tick
    
    for i = start_idx, #reports - 1 do
        local report = reports[i]
        if report and report.text then
            -- Only check recent reports (within last season)
            if report.year == current_year then
                local text = dfhack.df2utf(report.text):lower()
                
                if text:find("siege") then
                    table.insert(emergencies, {type = "siege", text = text})
                elseif text:find("ambush") then
                    table.insert(emergencies, {type = "ambush", text = text})
                elseif text:find("thief") then
                    table.insert(emergencies, {type = "thief", text = text})
                elseif text:find("snatcher") then
                    table.insert(emergencies, {type = "snatcher", text = text})
                elseif text:find("forgotten beast") then
                    table.insert(emergencies, {type = "forgotten_beast", text = text})
                elseif text:find("titan") then
                    table.insert(emergencies, {type = "titan", text = text})
                elseif text:find("dragon") then
                    table.insert(emergencies, {type = "dragon", text = text})
                elseif text:find("undead") or text:find("risen") then
                    table.insert(emergencies, {type = "undead", text = text})
                end
            end
        end
    end
    
    return emergencies
end

-------------------------------------------------------------------------------
-- Emergency Response
-------------------------------------------------------------------------------

--- Check if a door is likely an exterior door
local function is_exterior_door(building)
    local ok, result = pcall(function()
        local x, y, z = building.x1, building.y1, building.z
        local map_x, map_y, map_z = dfhack.maps.getTileSize()
        
        -- Door on surface level (z >= surface level)
        local surface_z = df.global.world.map.region_z
        if z >= surface_z - 2 then
            return true
        end
        
        -- Door near map edge (within 10 tiles)
        if x < 10 or x > map_x - 10 or y < 10 or y > map_y - 10 then
            return true
        end
        
        -- Check if connected to outside tiles
        -- (simplified: if on a z-level with open sky nearby)
        local block = dfhack.maps.getTileBlock(x, y, z)
        if block then
            for dx = -3, 3 do
                for dy = -3, 3 do
                    local tx, ty = x + dx, y + dy
                    if tx >= 0 and ty >= 0 and tx < map_x and ty < map_y then
                        local designation = dfhack.maps.getTileFlags(tx, ty, z)
                        if designation and designation.outside then
                            return true
                        end
                    end
                end
            end
        end
        
        return false
    end)
    
    return ok and result
end

-- Track locked doors for proper unlocking
local locked_doors = {}

--- Lock exterior doors only (to avoid trapping dwarves)
local function lockdown_fortress()
    local doors_locked = 0
    locked_doors = {}
    
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Door then
            -- Only lock exterior doors
            if is_exterior_door(building) then
                building.door_flags.forbidden = true
                table.insert(locked_doors, building.id)
                doors_locked = doors_locked + 1
            end
        end
    end
    
    if doors_locked > 0 then
        utils.log_warn("LOCKDOWN: Locked " .. doors_locked .. " exterior doors")
    else
        utils.log_debug("Lockdown: No exterior doors found to lock", MANAGER_NAME)
    end
    
    return doors_locked
end

--- Unlock only the doors we locked
local function unlock_fortress()
    local doors_unlocked = 0
    
    -- If we tracked which doors we locked, only unlock those
    if #locked_doors > 0 then
        for _, building in pairs(df.global.world.buildings.all) do
            if building:getType() == df.building_type.Door then
                for _, locked_id in ipairs(locked_doors) do
                    if building.id == locked_id then
                        building.door_flags.forbidden = false
                        doors_unlocked = doors_unlocked + 1
                        break
                    end
                end
            end
        end
        locked_doors = {}
    else
        -- Fallback: unlock all doors (but log warning)
        for _, building in pairs(df.global.world.buildings.all) do
            if building:getType() == df.building_type.Door then
                if building.door_flags.forbidden then
                    building.door_flags.forbidden = false
                    doors_unlocked = doors_unlocked + 1
                end
            end
        end
    end
    
    if doors_unlocked > 0 then
        utils.log("Lockdown ended: Unlocked " .. doors_unlocked .. " doors")
    end
    
    return doors_unlocked
end

--- Get or create a safety burrow for emergencies
local function get_or_create_safety_burrow()
    local ok, result = pcall(function()
        -- Look for existing safety burrow
        for _, burrow in pairs(df.global.world.burrows.all) do
            if burrow.name == "AI Safety Zone" then
                return burrow
            end
        end
        
        -- Create new safety burrow
        local burrow = df.burrow:new()
        burrow.id = df.global.world.burrows.next_id
        df.global.world.burrows.next_id = df.global.world.burrows.next_id + 1
        burrow.name = "AI Safety Zone"
        
        -- Add burrow to list
        df.global.world.burrows.all:insert('#', burrow)
        
        utils.log_action(MANAGER_NAME, "Created safety burrow", "ID: " .. burrow.id)
        return burrow
    end)
    
    if ok then return result end
    return nil
end

--- Add fortress interior tiles to the safety burrow
local function setup_safety_burrow_tiles(burrow)
    if not burrow then return end
    
    local ok, _ = pcall(function()
        local mining_state = state.get_manager_state("mining")
        if not mining_state or not mining_state.main_z then return end
        
        local cx, cy, z = mining_state.center_x, mining_state.center_y, mining_state.main_z
        
        -- Add tiles around fortress center (main level)
        for dx = -15, 15 do
            for dy = -15, 15 do
                local tx, ty = cx + dx, cy + dy
                local block = dfhack.maps.getTileBlock(tx, ty, z)
                if block then
                    local mask = burrow:getTilemask(block, true)
                    if mask then
                        local lx = tx % 16
                        local ly = ty % 16
                        mask.data[lx] = bit32.bor(mask.data[lx], bit32.lshift(1, ly))
                    end
                end
            end
        end
    end)
end

--- Assign all civilians to safety burrow
local function assign_civilians_to_burrow(burrow)
    if not burrow then return 0 end
    
    local assigned = 0
    local ok, _ = pcall(function()
        local citizens = utils.get_citizens()
        
        for _, unit in ipairs(citizens) do
            -- Skip military (they need to fight)
            if unit.military.squad_id == -1 then
                -- Check if already assigned
                local already_assigned = false
                for _, link in pairs(unit.burrows) do
                    if link.id == burrow.id then
                        already_assigned = true
                        break
                    end
                end
                
                if not already_assigned then
                    -- Create burrow link
                    local link = df.unit_burrow_assignee:new()
                    link.id = burrow.id
                    unit.burrows:insert('#', link)
                    assigned = assigned + 1
                end
            end
        end
    end)
    
    return assigned
end

--- Clear burrow assignments for civilians
local function clear_burrow_assignments(burrow)
    if not burrow then return 0 end
    
    local cleared = 0
    local ok, _ = pcall(function()
        local citizens = utils.get_citizens()
        
        for _, unit in ipairs(citizens) do
            -- Remove burrow links for this burrow
            local i = 0
            while i < #unit.burrows do
                if unit.burrows[i].id == burrow.id then
                    unit.burrows:erase(i)
                    cleared = cleared + 1
                else
                    i = i + 1
                end
            end
        end
    end)
    
    return cleared
end

--- Trigger burrow alert (move citizens to safety)
local function activate_burrow_alert()
    local burrow = get_or_create_safety_burrow()
    if not burrow then
        utils.log_warn("ALERT: Could not create safety burrow!")
        return false
    end
    
    -- Setup burrow tiles if first time
    setup_safety_burrow_tiles(burrow)
    
    -- Assign civilians
    local assigned = assign_civilians_to_burrow(burrow)
    
    utils.log_warn("BURROW ALERT: " .. assigned .. " civilians assigned to safety zone")
    return true
end

--- Deactivate burrow alert
local function deactivate_burrow_alert()
    local ok, _ = pcall(function()
        for _, burrow in pairs(df.global.world.burrows.all) do
            if burrow.name == "AI Safety Zone" then
                local cleared = clear_burrow_assignments(burrow)
                if cleared > 0 then
                    utils.log("Burrow alert ended: " .. cleared .. " civilians released")
                end
                return
            end
        end
    end)
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
    local was_emergency = mgr_state.in_emergency or false
    
    -- Detect various emergencies
    local invaders = detect_invaders()
    local megabeasts = detect_megabeasts()
    local announcements = check_announcements()
    local is_flooding = detect_flooding()
    
    local total_threats = #invaders + #megabeasts
    local is_emergency = total_threats > 0 or is_flooding or #announcements > 0
    
    -- Update state
    mgr_state.invader_count = #invaders
    mgr_state.megabeast_count = #megabeasts
    mgr_state.is_flooding = is_flooding
    mgr_state.announcement_count = #announcements
    mgr_state.in_emergency = is_emergency
    mgr_state.last_check = current_tick
    
    -- Emergency response
    if is_emergency and not was_emergency then
        -- New emergency!
        utils.log_warn("=== EMERGENCY DETECTED ===")
        
        if #invaders > 0 then
            utils.log_warn("Invaders: " .. #invaders)
        end
        if #megabeasts > 0 then
            utils.log_warn("Megabeasts: " .. #megabeasts)
        end
        if is_flooding then
            utils.log_warn("Flooding detected!")
        end
        
        -- Lockdown if enabled
        if config.get("emergency.lockdown_on_siege", true) then
            lockdown_fortress()
        end
        
        -- Activate burrow alert if enabled
        if config.get("emergency.use_burrows", true) then
            activate_burrow_alert()
            mgr_state.burrow_active = true
        end
        
        mgr_state.lockdown_active = true
        
    elseif not is_emergency and was_emergency then
        -- Emergency resolved
        utils.log("=== EMERGENCY RESOLVED ===")
        
        if mgr_state.lockdown_active then
            unlock_fortress()
            mgr_state.lockdown_active = false
        end
        
        -- Deactivate burrow alert
        if mgr_state.burrow_active then
            deactivate_burrow_alert()
            mgr_state.burrow_active = false
        end
    end
    
    state.set_manager_state(MANAGER_NAME, mgr_state)
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    if mgr_state.in_emergency then
        local threats = (mgr_state.invader_count or 0) + (mgr_state.megabeast_count or 0)
        return string.format("EMERGENCY! threats: %d", threats)
    end
    
    return "all clear"
end

return _ENV
