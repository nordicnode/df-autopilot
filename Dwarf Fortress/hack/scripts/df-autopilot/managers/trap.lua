-- df-autopilot/managers/trap.lua
-- Trap management: production and placement
-- Handles defense of the Trap Hall

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")
local planner = reqscript("df-autopilot/fortress_planner")

local MANAGER_NAME = "trap"
local last_check = 0
local CHECK_INTERVAL = 1000 -- Check fairly often for trap components

-------------------------------------------------------------------------------
-- Internal Logic
-------------------------------------------------------------------------------

--- Ensure mechanisms are produced
local function ensure_mechanisms()
    local count = utils.count_items(df.item_type.TRAPCOMP, df.item_type.TRAPCOMP_MECHANISM) -- Not exact enum, checking generic
    -- Actually trapcomp isn't mechanism. Mechanism is TRAPPARTS.
    local mech_count = 0
    for _, item in pairs(df.global.world.items.other.TRAPPARTS) do
        if not item.flags.forbid and not item.flags.dump then
            mech_count = mech_count + item:getStackSize()
        end
    end
    
    -- Target: 20 mechanisms (10 for traps, 10 for levers/bridges)
    if mech_count < 20 then
        if not utils.order_exists(df.job_type.ConstructMechanisms, 0) then
            utils.create_order(df.job_type.ConstructMechanisms, 5)
        end
    end
end

--- Ensure cages are produced (for cage traps)
local function ensure_cages()
    local cage_count = utils.count_items(df.item_type.CAGE, nil)
    
    if cage_count < 10 then
        -- Prefer wood cages if we have wood (cheaper)
        if not utils.order_exists(df.job_type.MakeCage, 0) then
             utils.create_order(df.job_type.MakeCage, 5)
        end
    end
end

--- Locate the Trap Hall
local function find_trap_hall()
    local rooms = planner.get_rooms_by_type_from_state("trap_hall")
    if #rooms > 0 then
        return rooms[1]
    end
    return nil
end

--- Place Traps in the Hall
local function place_traps(room)
    if not room or not planner.is_room_dug(room) then return end
    
    local trap_hall_z = room.z
    -- Available mechanisms?
    local mech_count = 0
    for _, item in pairs(df.global.world.items.other.TRAPPARTS) do
         if not item.flags.forbid and not item.flags.dump then mech_count = mech_count + 1 end
    end
    
    -- Keep a reserve of mechanisms for levers/bridges
    if mech_count < 5 then return end 
    
    local traps_placed_this_tick = 0
    
    -- Check for cages
    local cage_count = utils.count_items(df.item_type.CAGE, nil)
    
    for x = room.x, room.x + room.width - 1 do
        for y = room.y, room.y + room.height - 1 do
            if traps_placed_this_tick >= 2 then return end -- Limit placements per tick
            
            -- Check if spot is valid for a trap
            local ttype = utils.get_tile_type(x, y, trap_hall_z)
            if ttype then
                local shape = df.tiletype.attrs[ttype].shape
                
                if shape == df.tiletype_shape.FLOOR then
                     -- Check for existing building
                     local bld = dfhack.buildings.findAtTile(x, y, trap_hall_z)
                     if not bld then
                         -- Decide trap type
                         local trap_subtype = df.trap_type.StoneFallTrap
                         local trap_name = "Stone-Fall Trap"
                         
                         if cage_count > 0 then
                             trap_subtype = df.trap_type.CageTrap
                             trap_name = "Cage Trap"
                         end
                         
                         -- Place Trap
                         local ok, result = pcall(function()
                            return dfhack.buildings.constructBuilding({
                                type = df.building_type.Trap,
                                subtype = trap_subtype,
                                pos = {x = x, y = y, z = trap_hall_z},
                            })
                         end)
                         
                         if ok and result then
                             traps_placed_this_tick = traps_placed_this_tick + 1
                             utils.log("Designated " .. trap_name .. " at ("..x..","..y..","..trap_hall_z..")", MANAGER_NAME)
                             mech_count = mech_count - 1
                             
                             if trap_subtype == df.trap_type.CageTrap then
                                 cage_count = cage_count - 1
                             end
                             
                             if mech_count < 5 then return end
                         end
                     end
                end
            end
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
    
    ensure_mechanisms()
    ensure_cages()
    
    local trap_hall = find_trap_hall()
    if trap_hall then
        place_traps(trap_hall)
        
        if not mgr_state.hall_found then
            utils.log("Trap Hall detected at Z=" .. trap_hall.z, MANAGER_NAME)
            mgr_state.hall_found = true
            state.set_manager_state(MANAGER_NAME, mgr_state)
        end
    end
end

function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    local hall_status = mgr_state.hall_found and "Active" or "Searching"
    return string.format("Hooks ready. Hall: %s", hall_status)
end

return _ENV
