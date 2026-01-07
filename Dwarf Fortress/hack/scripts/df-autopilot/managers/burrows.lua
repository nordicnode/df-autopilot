-- df-autopilot/managers/burrows.lua
-- Emergency Burrow Management
-- Keeps civilians safe during sieges

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")
local planner = reqscript("df-autopilot/fortress_planner")

local MANAGER_NAME = "burrows"
local last_check = 0
local CHECK_INTERVAL = 50  -- Check very frequently for siege status
local BURROW_NAME = "Siege Safe"

-------------------------------------------------------------------------------
-- Internal Logic
-------------------------------------------------------------------------------

--- Check for siege/ambush announcements
local function check_siege_status()
    -- Check recent announcements
    local reports = df.global.world.status.reports
    if #reports > 0 then
        local start_idx = math.max(0, #reports - 20)
        for i = start_idx, #reports - 1 do
            local report = reports[i]
            if report and report.text then
                local text = dfhack.df2utf(report.text):lower()
                if text:find("siege") or text:find("ambush") or 
                   text:find("vile force") or text:find("curse") then
                    return true
                end
            end
        end
    end
    
    -- Also check for active invaders on map
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isInvader(unit) and not dfhack.units.isDead(unit) and not dfhack.units.isCaged(unit) then
            return true
        end
    end
    
    return false
end

--- Get or create the safety burrow
local function get_safe_burrow()
    -- Check existing burrows
    for _, burrow in pairs(df.global.world.burrows.all) do
        if burrow.name == BURROW_NAME then
             return burrow
        end
    end
    
    -- Create new burrow
    local burrow = df.burrow:new()
    burrow.id = df.global.burrow_next_id
    df.global.burrow_next_id = df.global.burrow_next_id + 1
    burrow.name = BURROW_NAME
    burrow.tile = 35 -- ASCII symbol (hash or similar)
    burrow.fg_color = 4 -- Red
    burrow.bg_color = 0
    
    df.global.world.burrows.all:insert('#', burrow)
    utils.log_action(MANAGER_NAME, "Created Burrow", "Created '" .. BURROW_NAME .. "' burrow")
    return burrow
end

--- Define the burrow extend (Z-levels)
local function update_burrow_extent(burrow)
    -- Add safe rooms (Bedrooms, Dining) to burrow
    -- We assume these are safe deep levels
    local safe_rooms = planner.get_rooms_by_type_from_state("bedroom")
    local dining = planner.get_rooms_by_type_from_state("dining")
    
    -- Add dining rooms too
    for _, r in pairs(dining) do table.insert(safe_rooms, r) end
    
    -- Use dfhack.burrows.setAssignedTile(burrow, x, y, z, boolean)
    -- Need to map room rects
    
    for _, room in pairs(safe_rooms) do
        if planner.is_room_dug(room) then
             for x = room.x, room.x + room.width - 1 do
                 for y = room.y, room.y + room.height - 1 do
                     dfhack.burrows.setAssignedTile(burrow, x, y, room.z, true)
                 end
             end
        end
    end
end

--- Assign citizens to burrow
local function assign_civilians(burrow, enable)
    local citizens = utils.get_citizens()
    for _, unit in pairs(citizens) do
        -- Skip military (they need to fight)
        local is_military = false
        if unit.military_squad_id ~= -1 then is_military = true end
        
        -- Special case: babies/children are civilians
        
        if not is_military then
            dfhack.burrows.setUnitMask(burrow, unit.id, enable)
        end
    end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function update()
    local current_tick = df.global.cur_year_tick
    if current_tick - last_check < CHECK_INTERVAL then return end
    last_check = current_tick
    
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    local siege_active = check_siege_status()
    
    -- Log state change
    if siege_active ~= mgr_state.siege_active then
        if siege_active then
            utils.log_warn("Siege Detected! Activating Emergency Burrow.", MANAGER_NAME)
        else
            utils.log_action(MANAGER_NAME, "All Clear", "Siege ended. Releasing civilians.")
        end
        mgr_state.siege_active = siege_active
    end
    
    if siege_active then
        local burrow = get_safe_burrow()
        update_burrow_extent(burrow) -- Update size in case of expansion
        assign_civilians(burrow, true) -- Add to burrow
        
        -- Enforce burrow?
        -- DF burrow restriction is usually automatic if they are assigned.
    else
        -- If we have the burrow, empty it
        local burrow = get_safe_burrow()
        -- Clearing mask: setUnitMask(burrow, unit.id, false)
        assign_civilians(burrow, false)
    end
    
    state.set_manager_state(MANAGER_NAME, mgr_state)
end

function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    return string.format("Alert: %s", mgr_state.siege_active and "SIEGE" or "None")
end

return _ENV
