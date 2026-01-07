-- df-autopilot/managers/noble.lua
-- Noble room requirements and satisfaction tracking

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "noble"
local last_check = 0
local CHECK_INTERVAL = 2000

-------------------------------------------------------------------------------
-- Noble Position Data
-------------------------------------------------------------------------------

-- Room requirements for noble positions (minimum values)
local ROOM_REQUIREMENTS = {
    expedition_leader = { bedroom = 1, office = 1, dining = 1 },
    mayor = { bedroom = 2, office = 2, dining = 2 },
    baron = { bedroom = 3, office = 2, dining = 2, tomb = 2 },
    count = { bedroom = 4, office = 3, dining = 3, tomb = 3 },
    duke = { bedroom = 5, office = 4, dining = 4, tomb = 4 },
    monarch = { bedroom = 6, office = 5, dining = 5, tomb = 5 },
    broker = { office = 1 },
    manager = { office = 1 },
    bookkeeper = { office = 1 },
    chief_medical_dwarf = { office = 1 },
    captain_of_the_guard = { office = 1, bedroom = 2 },
    militia_commander = { office = 1 },
    hammerer = { office = 1 },
}

-------------------------------------------------------------------------------
-- Noble Detection
-------------------------------------------------------------------------------

--- Get list of active noble positions
local function get_nobles()
    local nobles = {}
    
    local ok, _ = pcall(function()
        -- Use UI civ_id to get the fortress entity safely
        local civ_id = df.global.ui.civ_id
        local civ = df.historical_entity.find(civ_id)
        if not civ then return end
        
        for _, position in pairs(civ.positions.assignments) do
            if position.histfig ~= -1 then
                local pos_id = position.position_id
                local pos_info = nil
                
                for _, p in pairs(civ.positions.own) do
                    if p.id == pos_id then
                        pos_info = p
                        break
                    end
                end
                
                if pos_info then
                    local histfig = df.historical_figure.find(position.histfig)
                    local unit = nil
                    if histfig then
                        unit = df.unit.find(histfig.unit_id)
                    end
                    
                    table.insert(nobles, {
                        position_name = pos_info.name[0] or "Unknown",
                        position_code = pos_info.code or "unknown",
                        histfig_id = position.histfig,
                        unit = unit
                    })
                end
            end
        end
    end)
    
    return nobles
end

--- Check if a unit has an assigned room of type
local function unit_has_room(unit, room_type)
    if not unit then return false end
    
    local ok, result = pcall(function()
        for _, owned_building in pairs(unit.owned_buildings) do
            local building = df.building.find(owned_building.id)
            if building then
                local btype = building:getType()
                
                if room_type == "bedroom" and btype == df.building_type.Bed then
                    return true
                elseif room_type == "office" and btype == df.building_type.Chair then
                    return true
                elseif room_type == "dining" and btype == df.building_type.Table then
                    return true
                elseif room_type == "tomb" and btype == df.building_type.Coffin then
                    return true
                end
            end
        end
        return false
    end)
    
    return ok and result
end

--- Check noble room satisfaction
local function check_noble_satisfaction()
    local results = {
        total_nobles = 0,
        satisfied = 0,
        unsatisfied = {},
        needs = {}
    }
    
    local ok, _ = pcall(function()
        local nobles = get_nobles()
        results.total_nobles = #nobles
        
        for _, noble in ipairs(nobles) do
            local code = noble.position_code:lower()
            local reqs = ROOM_REQUIREMENTS[code]
            local is_satisfied = true
            
            if reqs and noble.unit then
                for room_type, _ in pairs(reqs) do
                    if not unit_has_room(noble.unit, room_type) then
                        is_satisfied = false
                        table.insert(results.needs, {
                            noble = noble.position_name,
                            room = room_type
                        })
                    end
                end
            end
            
            if is_satisfied then
                results.satisfied = results.satisfied + 1
            else
                table.insert(results.unsatisfied, noble.position_name)
            end
        end
    end)
    
    return results
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
    
    -- Check noble satisfaction
    local satisfaction = check_noble_satisfaction()
    mgr_state.total_nobles = satisfaction.total_nobles
    mgr_state.satisfied = satisfaction.satisfied
    mgr_state.unsatisfied_count = #satisfaction.unsatisfied
    mgr_state.needs = satisfaction.needs
    
    -- Warn about unsatisfied nobles
    if #satisfaction.unsatisfied > 0 and not mgr_state.warned then
        for _, name in ipairs(satisfaction.unsatisfied) do
            utils.log_warn("Noble needs rooms: " .. name)
        end
        mgr_state.warned = true
    elseif #satisfaction.unsatisfied == 0 then
        mgr_state.warned = false
    end
    
    mgr_state.last_check = current_tick
    state.set_manager_state(MANAGER_NAME, mgr_state)
end

function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state or not mgr_state.total_nobles then
        return "waiting"
    end
    
    if mgr_state.total_nobles == 0 then
        return "no nobles"
    end
    
    local status = string.format("nobles: %d/%d satisfied",
        mgr_state.satisfied or 0,
        mgr_state.total_nobles or 0
    )
    
    if mgr_state.unsatisfied_count and mgr_state.unsatisfied_count > 0 then
        status = status .. " [" .. mgr_state.unsatisfied_count .. " need rooms]"
    end
    
    return status
end

return _ENV
