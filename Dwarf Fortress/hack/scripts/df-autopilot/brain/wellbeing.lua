-- df-autopilot/brain/wellbeing.lua
-- Dwarf wellbeing, nobles, moods, and defense

--@ module = true

local utils = reqscript("df-autopilot/utils")
local state = reqscript("df-autopilot/state")

-------------------------------------------------------------------------------
-- Dwarf Wellbeing
-------------------------------------------------------------------------------

function check_dwarf_wellbeing()
    local brain_state = state.get("brain") or {}
    local wellbeing = {total = 0, happy = 0, content = 0, unhappy = 0, miserable = 0}
    local need_counts = {food = {met = 0, unmet = 0}, drink = {met = 0, unmet = 0}}
    
    for _, unit in pairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) then
            wellbeing.total = wellbeing.total + 1
            local stress = unit.status.current_soul and unit.status.current_soul.personality.stress or 0
            
            if stress < -50000 then wellbeing.happy = wellbeing.happy + 1
            elseif stress < 0 then wellbeing.content = wellbeing.content + 1
            elseif stress < 100000 then wellbeing.unhappy = wellbeing.unhappy + 1
            else wellbeing.miserable = wellbeing.miserable + 1 end
            
            local counters = unit.counters2
            if counters then
                if counters.hunger_timer and counters.hunger_timer < 10000 then
                    need_counts.food.met = need_counts.food.met + 1
                else need_counts.food.unmet = need_counts.food.unmet + 1 end
                if counters.thirst_timer and counters.thirst_timer < 10000 then
                    need_counts.drink.met = need_counts.drink.met + 1
                else need_counts.drink.unmet = need_counts.drink.unmet + 1 end
            end
        end
    end
    
    wellbeing.needs_met = need_counts
    local score = 50 + (wellbeing.happy * 3) + wellbeing.content - (wellbeing.unhappy * 2) - (wellbeing.miserable * 5)
    wellbeing.score = math.max(0, math.min(100, score))
    
    brain_state.wellbeing = wellbeing
    state.set("brain", brain_state)
    
    if wellbeing.score < 30 then
        utils.log_warn("Dwarf wellbeing critical: " .. wellbeing.score .. "/100", "brain")
    end
    return wellbeing
end

-------------------------------------------------------------------------------
-- Noble Management
-------------------------------------------------------------------------------

function check_noble_satisfaction()
    local nobles = {}
    local brain_state = state.get("brain") or {}
    
    for _, entity_pos in pairs(df.global.world.entities.all) do
        if entity_pos.id == df.global.plotinfo.civ_id then
            for _, position in pairs(entity_pos.positions.own) do
                local noble = {title = position.name[0] or "Unknown", filled = false, demands_met = true}
                for _, assignment in pairs(entity_pos.positions.assignments) do
                    if assignment.position_id == position.id and assignment.histfig ~= -1 then
                        noble.filled = true
                        break
                    end
                end
                table.insert(nobles, noble)
            end
            break
        end
    end
    
    brain_state.nobles = nobles
    brain_state.noble_count = #nobles
    state.set("brain", brain_state)
    return nobles
end

-------------------------------------------------------------------------------
-- Mood Materials
-------------------------------------------------------------------------------

function check_mood_materials()
    local brain_state = state.get("brain") or {}
    local mood_needs = {}
    
    local material_stocks = {
        wood = utils.count_items(df.item_type.WOOD, nil) or 0,
        stone = utils.count_items(df.item_type.BOULDER, nil) or 0,
        metal = utils.count_items(df.item_type.BAR, nil) or 0,
        cloth = utils.count_items(df.item_type.CLOTH, nil) or 0,
        leather = utils.count_items(df.item_type.SKIN_TANNED, nil) or 0,
        bone = utils.count_items(df.item_type.BONE, nil) or 0,
        gem = utils.count_items(df.item_type.SMALLGEM, nil) or 0
    }
    
    for mat, count in pairs(material_stocks) do
        if count < 5 then
            table.insert(mood_needs, {material = mat, current = count, needed = 5, urgent = count == 0})
        end
    end
    
    brain_state.mood_materials = material_stocks
    brain_state.mood_needs = mood_needs
    state.set("brain", brain_state)
    return mood_needs
end

-------------------------------------------------------------------------------
-- Defense Infrastructure
-------------------------------------------------------------------------------

function check_defense_infrastructure()
    local brain_state = state.get("brain") or {}
    local defense = {drawbridges = 0, traps = 0, doors = 0, military_equipment = 0}
    
    for _, building in pairs(df.global.world.buildings.all) do
        local btype = building:getType()
        if btype == df.building_type.Bridge then defense.drawbridges = defense.drawbridges + 1
        elseif btype == df.building_type.Trap then defense.traps = defense.traps + 1
        elseif btype == df.building_type.Door then defense.doors = defense.doors + 1 end
    end
    
    defense.military_equipment = 
        (utils.count_items(df.item_type.WEAPON, nil) or 0) +
        (utils.count_items(df.item_type.ARMOR, nil) or 0) +
        (utils.count_items(df.item_type.SHIELD, nil) or 0)
    
    local score = math.min(20, defense.drawbridges * 10) + math.min(30, defense.traps * 2) +
                  math.min(20, defense.doors * 2) + math.min(30, defense.military_equipment)
    
    brain_state.defense = defense
    brain_state.defense_score = score
    state.set("brain", brain_state)
    return defense, score
end

return _ENV
