-- df-autopilot/managers/construction.lua
-- Automatic construction of workshops, stockpiles, and zones
-- Places buildings when resources and space are available

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")
local planner = nil  -- Loaded lazily

local MANAGER_NAME = "construction"
local last_check = 0
local CHECK_INTERVAL = 2000 -- Check less frequently, construction is expensive

-- Try to load planner
local function get_planner()
    if planner then return planner end
    local ok, p = pcall(function()
        return reqscript("df-autopilot/fortress_planner")
    end)
    if ok and p then
        planner = p
    end
    return planner
end

-------------------------------------------------------------------------------
-- Required Workshops
-------------------------------------------------------------------------------

local ESSENTIAL_WORKSHOPS = {
    -- Priority 1: Critical for basic survival
    { type = df.workshop_type.Carpenters, name = "Carpenter", size = 3, priority = 1 },
    { type = df.workshop_type.Masons, name = "Mason", size = 3, priority = 1 },
    { type = df.workshop_type.Still, name = "Still", size = 3, priority = 1 },
    
    -- Priority 2: Core functionality 
    { type = df.workshop_type.Craftsdwarfs, name = "Craftsdwarf", size = 3, priority = 2 },
    { type = df.workshop_type.Mechanics, name = "Mechanic", size = 3, priority = 2 },
    { type = df.workshop_type.Kitchen, name = "Kitchen", size = 3, priority = 2 },
    { type = df.workshop_type.Butchers, name = "Butcher", size = 3, priority = 2 },
    { type = df.workshop_type.Tanners, name = "Tanner", size = 3, priority = 2 },
    
    -- Priority 3: Industry
    { type = df.workshop_type.Farmers, name = "Farmer", size = 3, priority = 3 },
    { type = df.workshop_type.Fishery, name = "Fishery", size = 3, priority = 3 },
    { type = df.workshop_type.Loom, name = "Loom", size = 3, priority = 3 },
    { type = df.workshop_type.Clothiers, name = "Clothier", size = 3, priority = 3 },
    { type = df.workshop_type.Leatherworks, name = "Leatherworks", size = 3, priority = 3 },
    
    -- Priority 4: Metal and military  
    { type = df.workshop_type.Jewelers, name = "Jeweler", size = 3, priority = 4 },
    { type = df.workshop_type.Bowyers, name = "Bowyer", size = 3, priority = 4 },
    
    -- Priority 5: Specialized
    { type = df.workshop_type.Dyers, name = "Dyer", size = 3, priority = 5 },
    { type = df.workshop_type.Ashery, name = "Ashery", size = 3, priority = 5 },
    { type = df.workshop_type.Siege, name = "Siege Workshop", size = 5, priority = 5 },
}

-------------------------------------------------------------------------------
-- Location Finding
-------------------------------------------------------------------------------

--- Get the fortress main level from mining state
local function get_main_level()
    local mining_state = state.get_manager_state("mining")
    if mining_state and mining_state.main_z then
        return mining_state.center_x, mining_state.center_y, mining_state.main_z
    end
    return nil, nil, nil
end

--- Check if a tile is a floor (buildable) and clear of obstructions
local function is_buildable_floor(x, y, z)
    local ttype = utils.get_tile_type(x, y, z)
    if not ttype then return false end
    
    local ok, result = pcall(function()
        local attrs = df.tiletype.attrs[ttype]
        
        -- Must be a floor
        if attrs.shape ~= df.tiletype_shape.FLOOR then
            return false
        end
        
        -- Check for trees/shrubs (material check)
        local material = attrs.material
        if material == df.tiletype_material.TREE or
           material == df.tiletype_material.MUSHROOM then
            return false
        end
        
        return true
    end)
    
    if not ok or not result then return false end
    return true
end

--- Check if a tile has items that would block construction
local function has_blocking_items(x, y, z)
    -- Check for items at this location
    local ok, result = pcall(function()
        local block = dfhack.maps.getTileBlock(x, y, z)
        if not block then return false end
        
        -- Check tile occupancy flags
        local occ = block.occupancy[x % 16][y % 16]
        if occ.item then
            -- There are items here - check if they're boulders or large
            for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
                if item.pos.x == x and item.pos.y == y and item.pos.z == z then
                    local item_type = item:getType()
                    -- Skip boulders and large blocking items
                    if item_type == df.item_type.BOULDER or
                       item_type == df.item_type.WOOD or
                       item_type == df.item_type.CORPSE or
                       item_type == df.item_type.CORPSEPIECE then
                        return true
                    end
                end
            end
        end
        return false
    end)
    
    if ok then return result end
    return false
end

--- Check if a tile has plants/trees/shrubs
local function has_vegetation(x, y, z)
    local ok, result = pcall(function()
        -- Check for plants at this location
        for _, plant in pairs(df.global.world.plants.all) do
            if plant.pos.x == x and plant.pos.y == y and plant.pos.z == z then
                return true
            end
        end
        return false
    end)
    
    if ok then return result end
    return false
end

--- Check if area is clear for building (no buildings, items, trees, plants)
local function is_area_clear(x, y, z, width, height)
    for dx = 0, width - 1 do
        for dy = 0, height - 1 do
            local tx, ty = x + dx, y + dy
            
            -- Check if it's a buildable floor
            if not is_buildable_floor(tx, ty, z) then
                return false
            end
            
            -- Check if there's already a building there
            local building = dfhack.buildings.findAtTile(tx, ty, z)
            if building then
                return false
            end
            
            -- Check for blocking items (boulders, logs, etc.)
            if has_blocking_items(tx, ty, z) then
                return false
            end
            
            -- Check for vegetation (trees, shrubs)
            if has_vegetation(tx, ty, z) then
                return false
            end
        end
    end
    return true
end

--- Find a clear spot for a building near a location
local function find_building_spot(cx, cy, z, width, height, max_radius)
    max_radius = max_radius or 20
    
    -- Spiral outward from center
    for radius = 1, max_radius do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local x, y = cx + dx, cy + dy
                    if is_area_clear(x, y, z, width, height) then
                        return x, y
                    end
                end
            end
        end
    end
    
    return nil, nil
end

-------------------------------------------------------------------------------
-- Workshop Construction
-------------------------------------------------------------------------------

--- Get missing workshops
local function get_missing_workshops()
    local missing = {}
    
    for _, ws_def in ipairs(ESSENTIAL_WORKSHOPS) do
        local count = utils.count_workshops(ws_def.type)
        if count == 0 then
            table.insert(missing, ws_def)
        end
    end
    
    -- Sort by priority
    table.sort(missing, function(a, b) return a.priority < b.priority end)
    
    return missing
end

--- Check if we have materials for a workshop
local function has_workshop_materials()
    -- Most workshops need rock or wood
    local rocks = utils.count_items(df.item_type.BOULDER, nil)
    local logs = utils.count_items(df.item_type.WOOD, nil)
    
    return rocks > 0 or logs > 0
end

--- Create a workshop building
local function build_workshop(ws_type, x, y, z)
    -- Use DFHack's building creation
    local ok, result = pcall(function()
        local bld = dfhack.buildings.constructBuilding({
            type = df.building_type.Workshop,
            subtype = ws_type,
            pos = {x = x, y = y, z = z},
        })
        return bld
    end)
    
    if ok and result then
        return result
    end
    
    return nil
end

--- Try to build a missing workshop
local function build_missing_workshop()
    local missing = get_missing_workshops()
    if #missing == 0 then
        return false
    end
    
    -- Check materials
    if not has_workshop_materials() then
        utils.log_debug("No materials for workshop construction", MANAGER_NAME)
        return false
    end
    
    -- Try to build the highest priority missing workshop
    local ws_def = missing[1]
    
    local x, y, z = nil, nil, nil
    
    -- First try planner workshop hall positions
    local fp = get_planner()
    if fp then
        local positions = fp.get_workshop_placement_positions()
        for _, pos in ipairs(positions) do
            -- Check if this position is clear for a 3x3 workshop
            local clear = true
            for dx = -1, 1 do
                for dy = -1, 1 do
                    local bld = dfhack.buildings.findAtTile(pos.x + dx, pos.y + dy, pos.z)
                    if bld then
                        clear = false
                        break
                    end
                end
                if not clear then break end
            end
            
            if clear then
                x, y, z = pos.x, pos.y, pos.z
                break
            end
        end
    end
    
    -- Fallback to mining state location
    if not x then
        local mining_state = state.get_manager_state("mining")
        if not mining_state or not mining_state.center_x then
            utils.log_debug("No main level found for workshop placement (waiting for mining)", MANAGER_NAME)
            return false
        end
        
        local cx = mining_state.center_x
        local cy = mining_state.center_y
        z = mining_state.entry_z
        
        x, y = find_building_spot(cx, cy, z, ws_def.size, ws_def.size, 25)
    end
    
    if not x then
        utils.log_debug("No clear spot for " .. ws_def.name .. " workshop", MANAGER_NAME)
        return false
    end
    
    local building = build_workshop(ws_def.type, x, y, z)
    if building then
        utils.log_action(MANAGER_NAME, "Placed workshop", 
            ws_def.name .. " at (" .. x .. ", " .. y .. ", " .. z .. ")")
        return true
    else
        utils.log_debug("Failed to place " .. ws_def.name .. " workshop", MANAGER_NAME)
        return false
    end
end

-------------------------------------------------------------------------------
-- Furnace Construction
-------------------------------------------------------------------------------

local ESSENTIAL_FURNACES = {
    { type = df.furnace_type.WoodFurnace, name = "Wood Furnace", size = 3, priority = 2 },
    { type = df.furnace_type.Smelter, name = "Smelter", size = 3, priority = 2 },
    { type = df.furnace_type.MagmaSmelter, name = "Magma Smelter", size = 3, priority = 5 },
    { type = df.furnace_type.MetalsmithsForge, name = "Metalsmith's Forge", size = 3, priority = 3 },
    { type = df.furnace_type.MagmaForge, name = "Magma Forge", size = 3, priority = 5 },
    { type = df.furnace_type.GlassFurnace, name = "Glass Furnace", size = 3, priority = 4 },
    { type = df.furnace_type.Kiln, name = "Kiln", size = 3, priority = 4 },
}

local function get_missing_furnaces()
    local missing = {}
    
    for _, fn_def in ipairs(ESSENTIAL_FURNACES) do
        local found = false
        for _, building in pairs(df.global.world.buildings.all) do
            if building:getType() == df.building_type.Furnace then
                local ok, ftype = pcall(function() return building:getSubtype() end)
                if ok and ftype == fn_def.type then
                    found = true
                    break
                end
            end
        end
        if not found and fn_def.priority <= 3 then -- Only build non-magma early
            table.insert(missing, fn_def)
        end
    end
    
    table.sort(missing, function(a, b) return a.priority < b.priority end)
    return missing
end

local function build_furnace(fn_type, x, y, z)
    local ok, result = pcall(function()
        return dfhack.buildings.constructBuilding({
            type = df.building_type.Furnace,
            subtype = fn_type,
            pos = {x = x, y = y, z = z},
        })
    end)
    
    if ok and result then
        return result
    end
    return nil
end

local function build_missing_furnace()
    local missing = get_missing_furnaces()
    if #missing == 0 then
        return false
    end
    
    local fn_def = missing[1]
    
    local mining_state = state.get_manager_state("mining")
    if not mining_state or not mining_state.center_x then
        return false
    end
    
    local cx = mining_state.center_x
    local cy = mining_state.center_y
    local z = mining_state.entry_z
    
    local x, y = find_building_spot(cx, cy, z, fn_def.size, fn_def.size, 30)
    
    if not x then
        utils.log_debug("No clear spot for " .. fn_def.name, MANAGER_NAME)
        return false
    end
    
    local building = build_furnace(fn_def.type, x, y, z)
    if building then
        utils.log_action(MANAGER_NAME, "Placed furnace", 
            fn_def.name .. " at (" .. x .. ", " .. y .. ", " .. z .. ")")
        return true
    else
        utils.log_debug("Failed to place " .. fn_def.name, MANAGER_NAME)
        return false
    end
end

-------------------------------------------------------------------------------
-- Trade Depot Construction
-------------------------------------------------------------------------------

--- Check if trade depot exists
local function has_trade_depot()
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.TradeDepot then
            return true
        end
    end
    return false
end

--- Build trade depot
local function build_trade_depot()
    if has_trade_depot() then
        return false
    end
    
    -- Check materials (needs 3 logs or equivalent)
    local logs = utils.count_items(df.item_type.WOOD, nil)
    if logs < 3 then
        return false
    end
    
    local cx, cy, z = get_main_level()
    if not cx then return false end
    
    -- Trade depot is 5x5
    local x, y = find_building_spot(cx - 15, cy, z, 5, 5, 10)
    if not x then return false end
    
    local ok, result = pcall(function()
        return dfhack.buildings.constructBuilding({
            type = df.building_type.TradeDepot,
            pos = {x = x, y = y, z = z},
        })
    end)
    
    if ok and result then
        utils.log_action(MANAGER_NAME, "Placed trade depot", 
            "at (" .. x .. ", " .. y .. ", " .. z .. ")")
        return true
    end
    
    return false
end

-------------------------------------------------------------------------------
-- Stockpile Creation
-------------------------------------------------------------------------------

-- Stockpile types we need
local ESSENTIAL_STOCKPILES = {
    { name = "Food", settings_key = "food", priority = 1, size = 5 },
    { name = "Furniture", settings_key = "furniture", priority = 2, size = 4 },
    { name = "Stone", settings_key = "stone", priority = 2, size = 6 },
    { name = "Wood", settings_key = "wood", priority = 2, size = 4 },
    { name = "Bars/Blocks", settings_key = "bars_blocks", priority = 3, size = 4 },
    { name = "Finished Goods", settings_key = "finished_goods", priority = 3, size = 4 },
    { name = "Cloth", settings_key = "cloth", priority = 3, size = 3 },
    { name = "Leather", settings_key = "leather", priority = 3, size = 3 },
    { name = "Gems", settings_key = "gems", priority = 4, size = 2 },
    { name = "Weapons", settings_key = "weapons", priority = 4, size = 3 },
    { name = "Armor", settings_key = "armor", priority = 4, size = 3 },
    { name = "Ammo", settings_key = "ammo", priority = 4, size = 2 },
}

--- Count stockpiles by type
local function get_stockpile_coverage()
    local coverage = {}
    for _, sp_def in ipairs(ESSENTIAL_STOCKPILES) do
        coverage[sp_def.settings_key] = 0
    end
    
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Stockpile then
            local ok, _ = pcall(function()
                local settings = building.settings
                if settings then
                    if settings.flags.food then coverage.food = (coverage.food or 0) + 1 end
                    if settings.flags.furniture then coverage.furniture = (coverage.furniture or 0) + 1 end
                    if settings.flags.stone then coverage.stone = (coverage.stone or 0) + 1 end
                    if settings.flags.wood then coverage.wood = (coverage.wood or 0) + 1 end
                    if settings.flags.bars_blocks then coverage.bars_blocks = (coverage.bars_blocks or 0) + 1 end
                    if settings.flags.finished_goods then coverage.finished_goods = (coverage.finished_goods or 0) + 1 end
                end
            end)
        end
    end
    
    return coverage
end

--- Get missing stockpile types
local function get_missing_stockpiles()
    local coverage = get_stockpile_coverage()
    local missing = {}
    
    for _, sp_def in ipairs(ESSENTIAL_STOCKPILES) do
        if (coverage[sp_def.settings_key] or 0) == 0 then
            table.insert(missing, sp_def)
        end
    end
    
    -- Sort by priority
    table.sort(missing, function(a, b) return a.priority < b.priority end)
    
    return missing
end

--- Create a stockpile
local function create_stockpile(x, y, z, width, height, settings_key)
    local ok, result = pcall(function()
        -- Create the stockpile building
        local sp = dfhack.buildings.constructBuilding({
            type = df.building_type.Stockpile,
            pos = {x = x, y = y, z = z},
            width = width,
            height = height
        })
        
        if sp and sp.settings then
            -- Disable all flags first
            sp.settings.flags.animals = false
            sp.settings.flags.food = false
            sp.settings.flags.furniture = false
            sp.settings.flags.refuse = false
            sp.settings.flags.stone = false
            sp.settings.flags.wood = false
            sp.settings.flags.gems = false
            sp.settings.flags.bars_blocks = false
            sp.settings.flags.cloth = false
            sp.settings.flags.leather = false
            sp.settings.flags.ammo = false
            sp.settings.flags.coins = false
            sp.settings.flags.finished_goods = false
            sp.settings.flags.weapons = false
            sp.settings.flags.armor = false
            
            -- Enable only the one we want
            if settings_key == "food" then
                sp.settings.flags.food = true
            elseif settings_key == "furniture" then
                sp.settings.flags.furniture = true
            elseif settings_key == "stone" then
                sp.settings.flags.stone = true
            elseif settings_key == "wood" then
                sp.settings.flags.wood = true
            elseif settings_key == "bars_blocks" then
                sp.settings.flags.bars_blocks = true
            elseif settings_key == "finished_goods" then
                sp.settings.flags.finished_goods = true
            end
        end
        
        return sp
    end)
    
    if ok and result then
        return result
    end
    return nil
end

--- Build a missing stockpile
local function build_missing_stockpile()
    local missing = get_missing_stockpiles()
    if #missing == 0 then
        return false
    end
    
    local sp_def = missing[1]
    local x, y, z = nil, nil, nil
    
    -- First try planner storage rooms
    local fp = get_planner()
    if fp then
        local storage_rooms = fp.get_storage_rooms()
        for _, room in ipairs(storage_rooms) do
            -- Find a clear spot within this storage room
            for dy = 0, room.height - sp_def.size do
                for dx = 0, room.width - sp_def.size do
                    local test_x = room.x + dx
                    local test_y = room.y + dy
                    local clear = true
                    
                    -- Check if this area is clear
                    for sx = 0, sp_def.size - 1 do
                        for sy = 0, sp_def.size - 1 do
                            local bld = dfhack.buildings.findAtTile(test_x + sx, test_y + sy, room.z)
                            if bld then
                                clear = false
                                break
                            end
                        end
                        if not clear then break end
                    end
                    
                    if clear then
                        x, y, z = test_x, test_y, room.z
                        break
                    end
                end
                if x then break end
            end
            if x then break end
        end
    end
    
    -- Fallback to mining state storage level
    if not x then
        local mining_state = state.get_manager_state("mining")
        local cx, cy
        if mining_state and mining_state.storage_z then
            cx = mining_state.center_x
            cy = mining_state.center_y
            z = mining_state.storage_z
        else
            cx, cy, z = get_main_level()
        end
        
        if cx then
            x, y = find_building_spot(cx, cy, z, sp_def.size, sp_def.size, 30)
        end
    end
    
    if not x then
        utils.log_debug("No clear spot for " .. sp_def.name .. " stockpile", MANAGER_NAME)
        return false
    end
    
    local stockpile = create_stockpile(x, y, z, sp_def.size, sp_def.size, sp_def.settings_key)
    if stockpile then
        utils.log_action(MANAGER_NAME, "Created stockpile",
            sp_def.name .. " (" .. sp_def.size .. "x" .. sp_def.size .. ") at (" .. x .. ", " .. y .. ", " .. z .. ")")
        return true
    end
    
    return false
end

-------------------------------------------------------------------------------
-- Farm Plot Creation
-------------------------------------------------------------------------------

--- Count existing farm plots
local function count_farm_plots()
    local count = 0
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.FarmPlot then
            count = count + 1
        end
    end
    return count
end

--- Check if tile is suitable for farming (mud, soil, or subterranean)
local function is_farmable_tile(x, y, z)
    local ttype = utils.get_tile_type(x, y, z)
    if not ttype then return false end
    
    local ok, result = pcall(function()
        local attrs = df.tiletype.attrs[ttype]
        if attrs.shape ~= df.tiletype_shape.FLOOR then
            return false
        end
        
        -- Check material - we want mud, soil, or muddy stone
        local material = attrs.material
        return material == df.tiletype_material.SOIL or
               material == df.tiletype_material.GRASS_LIGHT or
               material == df.tiletype_material.GRASS_DARK or
               material == df.tiletype_material.MUD
    end)
    
    if ok then return result end
    return false
end

--- Find a spot for a farm plot
local function find_farm_spot(cx, cy, z, width, height, max_radius)
    max_radius = max_radius or 25
    
    for radius = 1, max_radius do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local x, y = cx + dx, cy + dy
                    
                    -- Check if all tiles in the area are farmable
                    local all_farmable = true
                    for fx = 0, width - 1 do
                        for fy = 0, height - 1 do
                            if not is_farmable_tile(x + fx, y + fy, z) then
                                all_farmable = false
                                break
                            end
                            -- Also check no building exists
                            local bld = dfhack.buildings.findAtTile(x + fx, y + fy, z)
                            if bld then
                                all_farmable = false
                                break
                            end
                        end
                        if not all_farmable then break end
                    end
                    
                    if all_farmable then
                        return x, y
                    end
                end
            end
        end
    end
    
    return nil, nil
end

--- Create a farm plot
local function create_farm_plot(x, y, z, width, height)
    local ok, result = pcall(function()
        return dfhack.buildings.constructBuilding({
            type = df.building_type.FarmPlot,
            pos = {x = x, y = y, z = z},
            width = width,
            height = height
        })
    end)
    
    if ok and result then
        return result
    end
    return nil
end

--- Build farm plots if needed
local function build_farm_plots()
    local population = utils.get_population()
    local current_farms = count_farm_plots()
    
    -- Aim for 1 farm per 3-4 dwarves, minimum of 2 farms
    local target_farms = math.max(2, math.floor(population / 3))
    
    if current_farms >= target_farms then
        return false
    end
    
    -- Try to find a suitable location on main or storage level
    local cx, cy, z = get_main_level()
    if not cx then return false end
    
    -- Look for farmable tiles
    local farm_width = 3
    local farm_height = 3
    
    local x, y = find_farm_spot(cx, cy, z, farm_width, farm_height, 30)
    
    if not x then
        -- Try storage level
        local mining_state = state.get_manager_state("mining")
        if mining_state and mining_state.storage_z then
            x, y = find_farm_spot(cx, cy, mining_state.storage_z, farm_width, farm_height, 30)
            if x then z = mining_state.storage_z end
        end
    end
    
    if not x then
        utils.log_debug("No farmable spot found for farm plot", MANAGER_NAME)
        return false
    end
    
    local farm = create_farm_plot(x, y, z, farm_width, farm_height)
    if farm then
        utils.log_action(MANAGER_NAME, "Created farm plot",
            farm_width .. "x" .. farm_height .. " at (" .. x .. ", " .. y .. ", " .. z .. ")")
        return true
    end
    
    return false
end

-------------------------------------------------------------------------------
-- Bed Placement
-------------------------------------------------------------------------------

--- Count placed beds (as buildings)
local function count_placed_beds()
    local count = 0
    for _, building in pairs(df.global.world.buildings.all) do
        if building:getType() == df.building_type.Bed then
            count = count + 1
        end
    end
    return count
end

--- Count available bed items (not yet placed)
local function count_available_beds()
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if item:getType() == df.item_type.BED and utils.is_valid_item(item) then
            -- Check if not already used in a building
            local in_building = false
            for _, ref in pairs(item.general_refs) do
                if ref:getType() == df.general_ref_type.BUILDING_HOLDER then
                    in_building = true
                    break
                end
            end
            if not in_building then
                count = count + 1
            end
        end
    end
    return count
end

--- Place a bed
local function place_bed(x, y, z)
    -- Find an available bed item
    local bed_item = nil
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if item:getType() == df.item_type.BED and utils.is_valid_item(item) then
            local in_building = false
            for _, ref in pairs(item.general_refs) do
                if ref:getType() == df.general_ref_type.BUILDING_HOLDER then
                    in_building = true
                    break
                end
            end
            if not in_building then
                bed_item = item
                break
            end
        end
    end
    
    if not bed_item then
        return nil
    end
    
    local ok, result = pcall(function()
        return dfhack.buildings.constructBuilding({
            type = df.building_type.Bed,
            pos = {x = x, y = y, z = z},
            items = {bed_item}
        })
    end)
    
    if ok and result then
        return result
    end
    return nil
end

--- Try to place beds for dwarves without them
local function place_beds_for_population()
    local population = utils.get_population()
    local placed = count_placed_beds()
    local available = count_available_beds()
    
    -- Need more beds placed?
    local needed = population - placed
    if needed <= 0 or available <= 0 then
        return 0
    end
    
    local cx, cy, z = get_main_level()
    if not cx then return 0 end
    
    -- Place beds in a bedroom area (offset from main area)
    local beds_placed = 0
    local bedroom_offset_x = 20
    local bedroom_offset_y = -10
    
    for i = 1, math.min(needed, available, 3) do -- Max 3 per cycle
        local x, y = find_building_spot(cx + bedroom_offset_x, cy + bedroom_offset_y + (i * 3), z, 1, 1, 15)
        if x then
            local bed = place_bed(x, y, z)
            if bed then
                beds_placed = beds_placed + 1
                utils.log_action(MANAGER_NAME, "Placed bed", 
                    "at (" .. x .. ", " .. y .. ", " .. z .. ")")
            end
        end
    end
    
    return beds_placed
end

-------------------------------------------------------------------------------
-- Planner-based Room Furniture
-------------------------------------------------------------------------------

-- Map furniture names to building types
local FURNITURE_BUILDING_TYPES = {
    bed = df.building_type.Bed,
    table = df.building_type.Table,
    chair = df.building_type.Chair,
    cabinet = df.building_type.Cabinet,
    chest = df.building_type.Box,
    statue = df.building_type.Statue,
    coffin = df.building_type.Coffin,
    weapon_rack = df.building_type.Weaponrack,
    armor_stand = df.building_type.Armorstand,
    bookcase = df.building_type.Bookcase,
    cage = df.building_type.Cage,
    chain = df.building_type.Chain,
}

-- Find available furniture item
local function find_furniture_item(furniture_type)
    local item_types = {
        bed = df.item_type.BED,
        table = df.item_type.TABLE,
        chair = df.item_type.CHAIR,
        cabinet = df.item_type.CABINET,
        chest = df.item_type.BOX,
        statue = df.item_type.STATUE,
        coffin = df.item_type.COFFIN,
        weapon_rack = df.item_type.WEAPONRACK,
        armor_stand = df.item_type.ARMORSTAND,
        bookcase = df.item_type.BOOKCASE,
        cage = df.item_type.CAGE,
        chain = df.item_type.CHAIN,
    }
    
    local item_type = item_types[furniture_type]
    if not item_type then return nil end
    
    for _, item in ipairs(df.global.world.items.all) do
        local ok, result = pcall(function()
            if item:getType() ~= item_type then return nil end
            if item.flags.in_job then return nil end
            if item.flags.forbid then return nil end
            if item.flags.in_building then return nil end
            if item.flags.construction then return nil end
            return item
        end)
        
        if ok and result then
            return result
        end
    end
    
    return nil
end

-- Place furniture in a room
local function place_furniture_in_room(room, furniture_type, pos_index)
    local building_type = FURNITURE_BUILDING_TYPES[furniture_type]
    if not building_type then
        return false
    end
    
    -- Find available item
    local item = find_furniture_item(furniture_type)
    if not item then
        utils.log_debug("No available " .. furniture_type .. " for " .. room.type_name, MANAGER_NAME)
        return false
    end
    
    -- Calculate position within room (grid pattern)
    local positions_per_row = math.floor(room.width / 2)
    if positions_per_row < 1 then positions_per_row = 1 end
    
    local row = math.floor(pos_index / positions_per_row)
    local col = pos_index % positions_per_row
    
    local x = room.x + 1 + col * 2
    local y = room.y + 1 + row * 2
    local z = room.z
    
    -- Make sure position is within room
    if x >= room.x + room.width - 1 then x = room.x + room.width - 2 end
    if y >= room.y + room.height - 1 then y = room.y + room.height - 2 end
    
    -- Check if position is clear
    local ttype = utils.get_tile_type(x, y, z)
    if not ttype then return false end
    
    local ok, shape = pcall(function()
        return df.tiletype.attrs[ttype].shape
    end)
    
    if not ok or shape ~= df.tiletype_shape.FLOOR then
        return false
    end
    
    -- Check for existing building
    local bld_at_pos = dfhack.buildings.findAtTile(x, y, z)
    if bld_at_pos then
        return false
    end
    
    -- Place the furniture
    local ok2, building = pcall(function()
        return dfhack.buildings.constructBuilding({
            type = building_type,
            pos = {x = x, y = y, z = z},
            items = {item},
        })
    end)
    
    if ok2 and building then
        utils.log_action(MANAGER_NAME, "Placed " .. furniture_type,
            "in " .. room.type_name .. " at (" .. x .. ", " .. y .. ", " .. z .. ")")
        return true
    end
    
    return false
end

-- Process rooms needing furniture
local function furnish_planner_rooms()
    local fp = get_planner()
    if not fp then
        return 0
    end
    
    local rooms = fp.get_rooms_from_state()
    if not rooms or #rooms == 0 then
        return 0
    end
    
    local furniture_placed = 0
    
    for _, room in ipairs(rooms) do
        -- Skip if already furnished or no zone yet
        if room.furniture_placed or not room.zone_created then
            goto continue
        end
        
        -- Get furniture requirements for this room type
        local needs = fp.get_room_furniture_needs(room.type_id)
        if not needs or not needs.required or #needs.required == 0 then
            -- No furniture needed, mark as done
            fp.mark_room_furniture_placed(room.id)
            goto continue
        end
        
        -- Try to place required furniture
        local all_placed = true
        for i, furn_type in ipairs(needs.required) do
            if place_furniture_in_room(room, furn_type, i - 1) then
                furniture_placed = furniture_placed + 1
            else
                all_placed = false
            end
        end
        
        -- Only try one room per cycle to spread out the work
        if furniture_placed > 0 then
            if all_placed then
                fp.mark_room_furniture_placed(room.id)
                utils.log_action(MANAGER_NAME, "Room fully furnished", room.type_name)
            end
            break
        end
        
        ::continue::
    end
    
    return furniture_placed
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
    
    -- Count things
    local missing_workshops = get_missing_workshops()
    mgr_state.missing_workshop_count = #missing_workshops
    mgr_state.has_trade_depot = has_trade_depot()
    mgr_state.beds_placed = count_placed_beds()
    mgr_state.beds_available = count_available_beds()
    mgr_state.population = utils.get_population()
    mgr_state.farm_count = count_farm_plots()
    mgr_state.target_farms = math.max(2, math.floor(mgr_state.population / 3))
    
    -- Try to build missing workshops (one per update cycle)
    if #missing_workshops > 0 then
        build_missing_workshop()
    end
    
    -- Try to build missing furnaces (smelters, forges, etc.)
    local missing_furnaces = get_missing_furnaces()
    mgr_state.missing_furnace_count = #missing_furnaces
    if #missing_furnaces > 0 then
        build_missing_furnace()
    end
    
    -- Try to build trade depot if missing
    if not mgr_state.has_trade_depot then
        build_trade_depot()
    end
    
    -- Try to build missing stockpiles
    local missing_stockpiles = get_missing_stockpiles()
    mgr_state.missing_stockpile_count = #missing_stockpiles
    if #missing_stockpiles > 0 then
        build_missing_stockpile()
    end
    
    -- Try to build farm plots if needed
    if mgr_state.farm_count < mgr_state.target_farms then
        build_farm_plots()
    end
    
    -- Try to place beds if we have available ones and need more
    if mgr_state.beds_available > 0 and mgr_state.beds_placed < mgr_state.population then
        place_beds_for_population()
    end
    
    -- Furnish planner rooms (bedrooms, dining, etc.)
    local ok_furn, furn_count = pcall(furnish_planner_rooms)
    if ok_furn and furn_count and furn_count > 0 then
        mgr_state.furniture_placed_this_cycle = furn_count
    end
    
    mgr_state.last_check = current_tick
    state.set_manager_state(MANAGER_NAME, mgr_state)
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    
    local ws_missing = mgr_state.missing_workshop_count or 0
    local sp_missing = mgr_state.missing_stockpile_count or 0
    local beds = mgr_state.beds_placed or 0
    local pop = mgr_state.population or 0
    local farms = mgr_state.farm_count or 0
    local target_farms = mgr_state.target_farms or 2
    
    local parts = {}
    
    if ws_missing > 0 then
        table.insert(parts, "ws:" .. ws_missing)
    else
        table.insert(parts, "ws:ok")
    end
    
    if sp_missing > 0 then
        table.insert(parts, "sp:" .. sp_missing)
    else
        table.insert(parts, "sp:ok")
    end
    
    table.insert(parts, "farms:" .. farms .. "/" .. target_farms)
    table.insert(parts, "beds:" .. beds .. "/" .. pop)
    
    return table.concat(parts, ", ")
end

return _ENV
