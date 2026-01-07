-- df-autopilot/terrain.lua
-- Intelligent terrain analysis for safe mining
-- Detects water, magma, aquifers, and hazards before digging

--@ module = true

local utils = reqscript("df-autopilot/utils")

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local HAZARD_TYPES = {
    NONE = 0,
    WATER = 1,
    MAGMA = 2,
    AQUIFER = 3,
    EDGE = 4,
    OPEN_SPACE = 5,
    CAVERN = 6
}

local SAFETY_THRESHOLDS = {
    MIN_DISTANCE_FROM_WATER = 3,
    MIN_DISTANCE_FROM_EDGE = 5,
    SCAN_RADIUS = 20,
    SAFE_SCORE_THRESHOLD = 70
}

-------------------------------------------------------------------------------
-- Tile Analysis
-------------------------------------------------------------------------------

--- Get liquid level at a tile (0-7)
--- @return level, liquid_type (0=water, 1=magma)
function get_liquid_info(x, y, z)
    if not utils.is_valid_pos(x, y, z) then
        return 0, nil
    end
    
    local ok, result = pcall(function()
        local block = dfhack.maps.getTileBlock(x, y, z)
        if not block then return 0, nil end
        
        local lx, ly = x % 16, y % 16
        local des = block.designation[lx][ly]
        
        if not des then return 0, nil end
        
        local flow = des.flow_size or 0
        local liquid_type = des.liquid_type -- 0 = water, 1 = magma
        
        return flow, liquid_type
    end)
    
    if ok then return result end
    return 0, nil
end

--- Check if tile has water
function has_water(x, y, z)
    local flow, ltype = get_liquid_info(x, y, z)
    return flow > 0 and (ltype == 0 or ltype == nil)
end

--- Check if tile has magma
function has_magma(x, y, z)
    local flow, ltype = get_liquid_info(x, y, z)
    return flow > 0 and ltype == 1
end

--- Check if tile is in an aquifer
function is_aquifer(x, y, z)
    if not utils.is_valid_pos(x, y, z) then
        return false
    end
    
    local ok, result = pcall(function()
        local block = dfhack.maps.getTileBlock(x, y, z)
        if not block then return false end
        
        local lx, ly = x % 16, y % 16
        local des = block.designation[lx][ly]
        
        if not des then return false end
        
        -- Check water_table flag (aquifer indicator)
        return des.water_table == true
    end)
    
    if ok then return result end
    return false
end

--- Check if tile is open space (not solid)
function is_open_space(x, y, z)
    if not utils.is_valid_pos(x, y, z) then
        return false
    end
    
    local ttype = utils.get_tile_type(x, y, z)
    if not ttype then return false end
    
    local ok, shape = pcall(function()
        return df.tiletype.attrs[ttype].shape
    end)
    
    if not ok then return false end
    
    return shape == df.tiletype_shape.EMPTY or
           shape == df.tiletype_shape.FLOOR or
           shape == df.tiletype_shape.RAMP or
           shape == df.tiletype_shape.STAIR_UP or
           shape == df.tiletype_shape.STAIR_DOWN or
           shape == df.tiletype_shape.STAIR_UPDOWN
end

--- Check if tile is solid wall (diggable rock/soil)
function is_solid_wall(x, y, z)
    if not utils.is_valid_pos(x, y, z) then
        return false
    end
    
    local ttype = utils.get_tile_type(x, y, z)
    if not ttype then return false end
    
    local ok, shape = pcall(function()
        return df.tiletype.attrs[ttype].shape
    end)
    
    if not ok then return false end
    
    return shape == df.tiletype_shape.WALL
end

--- Check if a position is truly enclosed underground
--- Returns true if the tile is solid AND has solid rock above
function is_enclosed_underground(x, y, z)
    -- The tile itself should be diggable wall
    if not is_solid_wall(x, y, z) then
        return false
    end
    
    -- Check that there's solid rock above (not open to sky)
    -- We check upwards until we hit the surface or find solid above
    for check_z = z + 1, z + 10 do
        if is_solid_wall(x, y, check_z) then
            -- Found solid rock above - we're enclosed
            return true
        elseif is_open_space(x, y, check_z) then
            -- There's open space above us - check if it's outdoor
            local ttype = utils.get_tile_type(x, y, check_z)
            if ttype then
                local ok, class = pcall(function()
                    return df.tiletype.attrs[ttype].material
                end)
                -- If it's GRASS, SOIL_OCEAN, etc. we might be exposed
                if ok and class == df.tiletype_material.GRASS then
                    return false -- Exposed to surface
                end
            end
            -- Continue checking upward
        end
    end
    
    -- If we checked 10 levels up without finding definitive answer, assume enclosed
    return true
end

--- Find a truly underground z-level that is fully enclosed and safe laterally
--- Scans center and corners of a region to verify solid rock
function find_enclosed_z_level(center_x, center_y, surface_z, width, height)
    width = width or 20
    height = height or 20
    
    local x = center_x - math.floor(width/2)
    local y = center_y - math.floor(height/2)
    
    -- Start checking from surface_z - 3 and go deeper
    for z = surface_z - 3, surface_z - 20, -1 do
        local safe_vertical = true
        
        -- Check vertical enclosure (solid roof)
        local check_points = {
            {center_x, center_y},
            {x, y},
            {x + width - 1, y},
            {x, y + height - 1},
            {x + width - 1, y + height - 1},
        }
        
        for _, point in ipairs(check_points) do
            if not is_enclosed_underground(point[1], point[2], z) then
                safe_vertical = false
                break
            end
        end
        
        if safe_vertical then
            -- Check lateral safety (walls are not cliffs)
            if check_area_safety(x, y, z, width, height) then
                return z
            end
        end
    end
    
    -- Fallback: return a deeper level as it's safer
    return surface_z - 10
end

-------------------------------------------------------------------------------
-- Neighbor Hazard Checks
-------------------------------------------------------------------------------

--- Check 6 cardinal directions for water
--- @return bool, count of water tiles adjacent
function is_water_adjacent(x, y, z)
    local water_count = 0
    local directions = {
        {0, 0, 1}, {0, 0, -1},  -- up, down
        {1, 0, 0}, {-1, 0, 0},  -- east, west
        {0, 1, 0}, {0, -1, 0}   -- south, north
    }
    
    for _, dir in ipairs(directions) do
        if has_water(x + dir[1], y + dir[2], z + dir[3]) then
            water_count = water_count + 1
        end
    end
    
    return water_count > 0, water_count
end

--- Check 6 cardinal directions for magma
function is_magma_adjacent(x, y, z)
    local magma_count = 0
    local directions = {
        {0, 0, 1}, {0, 0, -1},
        {1, 0, 0}, {-1, 0, 0},
        {0, 1, 0}, {0, -1, 0}
    }
    
    for _, dir in ipairs(directions) do
        if has_magma(x + dir[1], y + dir[2], z + dir[3]) then
            magma_count = magma_count + 1
        end
    end
    
    return magma_count > 0, magma_count
end

--- Check if near map edge
function is_near_edge(x, y, z, min_distance)
    min_distance = min_distance or SAFETY_THRESHOLDS.MIN_DISTANCE_FROM_EDGE
    local x_max, y_max, z_max = utils.get_map_size()
    
    return x < min_distance or x >= (x_max - min_distance) or
           y < min_distance or y >= (y_max - min_distance)
end

--- Check if a specific tile is safe to dig (not adjacent to hazards)
function is_safe_to_dig(x, y, z)
    -- 1. Check if it's currently water or magma (unsafe to dig if it flows)
    -- Also avoid digging directly into an aquifer
    if has_water(x, y, z) or has_magma(x, y, z) then return false end
    if is_aquifer(x, y, z) then return false end
    
    -- 2. Check for adjacent water/magma
    local water_near = is_water_adjacent(x, y, z)
    if water_near then return false end
    
    local magma_near = is_magma_adjacent(x, y, z)
    if magma_near then return false end
    
    -- 3. Check for lateral exposure to open space (cliff side)
    -- If any neighbor is OPEN_SPACE or RAMP (outdoors), we breach the wall
    local directions = {
        {1, 0, 0}, {-1, 0, 0},
        {0, 1, 0}, {0, -1, 0}
    }
    
    for _, dir in ipairs(directions) do
        local nx, ny = x + dir[1], y + dir[2]
        if is_open_space(nx, ny, z) then
            -- Check if neighbor is truly 'outdoors' or just an empty indoor tile?
            -- It's hard to distinguish perfectly, but for safety: 
            -- if we are digging into fresh rock, ANY adjacent open space suggests a breach
            return false
        end
    end
    
    return true
end

--- Verify if a rectangular area is safe to dig
--- Checks every tile in the area for solid ground and no adjacent hazards
function check_area_safety(x, y, z, width, height)
    -- First check corners and center (optimization)
    local corners = {
        {x, y},
        {x + width - 1, y},
        {x, y + height - 1},
        {x + width - 1, y + height - 1},
        {x + math.floor(width/2), y + math.floor(height/2)}
    }
    
    for _, p in ipairs(corners) do
        if not is_safe_to_dig(p[1], p[2], z) or not is_solid_wall(p[1], p[2], z) then
            return false
        end
    end
    
    -- Thorough check of perimeter (most likely place to breach)
    for dx = 0, width - 1 do
        if not is_safe_to_dig(x + dx, y, z) then return false end
        if not is_safe_to_dig(x + dx, y + height - 1, z) then return false end
    end
    
    for dy = 0, height - 1 do
        if not is_safe_to_dig(x, y + dy, z) then return false end
        if not is_safe_to_dig(x + width - 1, y + dy, z) then return false end
    end
    
    return true
end

--- Scan area for aquifer presence
--- @return bool true if aquifer found in area
function scan_for_aquifer(x, y, z, width, height)
    -- Check corners and center first
    local points = {
        {x, y},
        {x + width - 1, y},
        {x, y + height - 1},
        {x + width - 1, y + height - 1},
        {x + math.floor(width/2), y + math.floor(height/2)}
    }
    
    for _, p in ipairs(points) do
        if is_aquifer(p[1], p[2], z) then return true end
    end
    
    -- Check center cross
    for dx = 0, width - 1 do
        if is_aquifer(x + dx, y + math.floor(height/2), z) then return true end
    end
    for dy = 0, height - 1 do
        if is_aquifer(x + math.floor(width/2), y + dy, z) then return true end
    end
    
    return false
end

-------------------------------------------------------------------------------
-- Extended Hazard Scanning
-------------------------------------------------------------------------------

--- Scan area for water tiles
--- @return count, closest_distance, closest_direction
function scan_for_water(cx, cy, cz, radius)
    radius = radius or SAFETY_THRESHOLDS.SCAN_RADIUS
    local water_count = 0
    local closest_dist = radius + 1
    local closest_dir = nil
    
    for dx = -radius, radius do
        for dy = -radius, radius do
            local x, y = cx + dx, cy + dy
            if has_water(x, y, cz) then
                water_count = water_count + 1
                local dist = math.abs(dx) + math.abs(dy)
                if dist < closest_dist then
                    closest_dist = dist
                    -- Determine general direction
                    if math.abs(dx) > math.abs(dy) then
                        closest_dir = dx > 0 and "east" or "west"
                    else
                        closest_dir = dy > 0 and "south" or "north"
                    end
                end
            end
        end
    end
    
    return water_count, closest_dist, closest_dir
end

--- Scan area for aquifer tiles
function scan_for_aquifer(cx, cy, cz, radius)
    radius = radius or SAFETY_THRESHOLDS.SCAN_RADIUS
    local aquifer_count = 0
    
    for dx = -radius, radius do
        for dy = -radius, radius do
            if is_aquifer(cx + dx, cy + dy, cz) then
                aquifer_count = aquifer_count + 1
            end
        end
    end
    
    return aquifer_count
end

-------------------------------------------------------------------------------
-- Comprehensive Tile Analysis
-------------------------------------------------------------------------------

--- Analyze a single tile for all hazards
--- @return table with hazard info and safety score
function analyze_tile(x, y, z)
    local result = {
        x = x, y = y, z = z,
        hazards = {},
        safety_score = 100,
        safe = true,
        reason = nil
    }
    
    -- Check water
    if has_water(x, y, z) then
        table.insert(result.hazards, HAZARD_TYPES.WATER)
        result.safety_score = 0
        result.safe = false
        result.reason = "tile has water"
        return result
    end
    
    -- Check magma
    if has_magma(x, y, z) then
        table.insert(result.hazards, HAZARD_TYPES.MAGMA)
        result.safety_score = 0
        result.safe = false
        result.reason = "tile has magma"
        return result
    end
    
    -- Check aquifer
    if is_aquifer(x, y, z) then
        table.insert(result.hazards, HAZARD_TYPES.AQUIFER)
        result.safety_score = result.safety_score - 50
        result.safe = false
        result.reason = "tile is aquifer"
        return result
    end
    
    -- Check adjacent water
    local water_adj, water_count = is_water_adjacent(x, y, z)
    if water_adj then
        table.insert(result.hazards, HAZARD_TYPES.WATER)
        result.safety_score = result.safety_score - (water_count * 20)
        if water_count >= 2 then
            result.safe = false
            result.reason = "adjacent to " .. water_count .. " water tiles"
        end
    end
    
    -- Check adjacent magma
    local magma_adj, magma_count = is_magma_adjacent(x, y, z)
    if magma_adj then
        table.insert(result.hazards, HAZARD_TYPES.MAGMA)
        result.safety_score = result.safety_score - (magma_count * 30)
        if magma_count >= 1 then
            result.safe = false
            result.reason = "adjacent to magma"
        end
    end
    
    -- Check map edge
    if is_near_edge(x, y, z) then
        table.insert(result.hazards, HAZARD_TYPES.EDGE)
        result.safety_score = result.safety_score - 20
    end
    
    -- Final safety determination
    if result.safety_score < SAFETY_THRESHOLDS.SAFE_SCORE_THRESHOLD then
        result.safe = false
        if not result.reason then
            result.reason = "safety score too low: " .. result.safety_score
        end
    end
    
    return result
end

-------------------------------------------------------------------------------
-- Direction Safety Scoring
-------------------------------------------------------------------------------

--- Score a direction for digging safety (0-100)
--- Higher score = safer
function score_direction(start_x, start_y, start_z, direction, distance)
    distance = distance or 15
    local score = 100
    local hazards_found = {}
    
    -- Direction vectors
    local vectors = {
        north = {0, -1},
        south = {0, 1},
        east = {1, 0},
        west = {-1, 0}
    }
    
    local vec = vectors[direction]
    if not vec then return 0, {"invalid direction"} end
    
    -- Check tiles along the path
    for i = 1, distance do
        local x = start_x + (vec[1] * i)
        local y = start_y + (vec[2] * i)
        
        -- Check surface and below
        for z_offset = 0, -3, -1 do
            local z = start_z + z_offset
            local analysis = analyze_tile(x, y, z)
            
            if not analysis.safe then
                score = score - (10 / (i + 1))  -- Closer hazards penalize more
                table.insert(hazards_found, 
                    direction .. " at (" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z) .. "): " .. (analysis.reason or "unknown")
                )
            end
            
            -- Heavy penalty for actual water/magma
            if has_water(x, y, z) then
                score = score - 30
            end
            if has_magma(x, y, z) then
                score = score - 40
            end
        end
    end
    
    -- Check map boundaries
    local end_x = start_x + (vec[1] * distance)
    local end_y = start_y + (vec[2] * distance)
    if is_near_edge(end_x, end_y, start_z, 10) then
        score = score - 15
        table.insert(hazards_found, "near map edge")
    end
    
    return math.max(0, score), hazards_found
end

--- Find the safest direction to dig from a starting point
--- @return direction, score, hazards
function find_safest_direction(start_x, start_y, start_z)
    local directions = {"north", "south", "east", "west"}
    local best_dir = nil
    local best_score = -1
    local best_hazards = {}
    local all_scores = {}
    
    for _, dir in ipairs(directions) do
        local score, hazards = score_direction(start_x, start_y, start_z, dir, 20)
        all_scores[dir] = score
        
        if score > best_score then
            best_score = score
            best_dir = dir
            best_hazards = hazards
        end
    end
    
    utils.log_debug(
        "Direction scores: N=" .. tostring(math.floor(all_scores["north"] or 0)) ..
        ", S=" .. tostring(math.floor(all_scores["south"] or 0)) ..
        ", E=" .. tostring(math.floor(all_scores["east"] or 0)) ..
        ", W=" .. tostring(math.floor(all_scores["west"] or 0)) ..
        " -> Best: " .. tostring(best_dir or "none"),
        "terrain"
    )
    
    return best_dir, best_score, best_hazards, all_scores
end

-------------------------------------------------------------------------------
-- Safe Path Validation
-------------------------------------------------------------------------------

--- Validate that an entire corridor path is safe
--- @return bool, first_unsafe_tile, reason
function validate_corridor_path(x1, y1, z, x2, y2)
    local min_x = math.min(x1, x2)
    local max_x = math.max(x1, x2)
    local min_y = math.min(y1, y2)
    local max_y = math.max(y1, y2)
    
    for x = min_x, max_x do
        for y = min_y, max_y do
            local analysis = analyze_tile(x, y, z)
            if not analysis.safe then
                return false, {x = x, y = y, z = z}, analysis.reason
            end
        end
    end
    
    return true, nil, nil
end

--- Find a safe zone for fortress construction
--- @return x, y, z, score or nil if none found
function find_safe_dig_zone(center_x, center_y, center_z, search_radius)
    search_radius = search_radius or 30
    
    -- First find safest direction
    local best_dir, score, hazards = find_safest_direction(center_x, center_y, center_z)
    
    if not best_dir then
        utils.log_warn("No safe direction found from center", "terrain")
        return nil
    end
    
    if score < SAFETY_THRESHOLDS.SAFE_SCORE_THRESHOLD then
        utils.log_warn(string.format(
            "Best direction %s has low safety score: %d",
            best_dir, score
        ), "terrain")
    end
    
    -- Calculate target position
    local vectors = {
        north = {0, -1},
        south = {0, 1},
        east = {1, 0},
        west = {-1, 0}
    }
    
    local vec = vectors[best_dir]
    local target_x = center_x + (vec[1] * 10)
    local target_y = center_y + (vec[2] * 10)
    
    utils.log("Found safe zone: " .. best_dir .. " from wagon (score: " .. score .. ")", "terrain")
    
    return target_x, target_y, center_z, best_dir, score
end

return _ENV
