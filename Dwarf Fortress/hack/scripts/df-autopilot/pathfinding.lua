-- df-autopilot/pathfinding.lua
-- A* Pathfinding for Dwarf Fortress Autopilot
-- Used for complex ramp generation and mining paths

--@ module = true

local utils = reqscript("df-autopilot/utils")

-------------------------------------------------------------------------------
-- Priority Queue Implementation
-------------------------------------------------------------------------------

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

function PriorityQueue.new()
    return setmetatable({items = {}}, PriorityQueue)
end

function PriorityQueue:push(item, priority)
    table.insert(self.items, {item = item, priority = priority})
    table.sort(self.items, function(a, b) return a.priority < b.priority end)
end

function PriorityQueue:pop()
    if #self.items == 0 then return nil end
    return table.remove(self.items, 1).item -- Remove lowest priority (min-heap behavior equivalent)
end

function PriorityQueue:empty()
    return #self.items == 0
end

-------------------------------------------------------------------------------
-- A* Algorithm
-------------------------------------------------------------------------------

--- A* Pathfinding in 3D space
-- @param start_node: {x, y, z}
-- @param goal_node: {x, y, z}
-- @param callbacks: {
--    cost = function(curr, next) -> number,
--    heuristic = function(node, goal) -> number,
--    neighbors = function(node) -> list of nodes,
--    is_valid = function(node) -> boolean
-- }
function find_path(start_node, goal_node, callbacks)
    local frontier = PriorityQueue.new()
    frontier:push(start_node, 0)
    
    local came_from = {}
    local cost_so_far = {}
    
    local start_key = string.format("%d,%d,%d", start_node.x, start_node.y, start_node.z)
    came_from[start_key] = nil
    cost_so_far[start_key] = 0
    
    local nodes_explored = 0
    local MAX_Explore = 5000 -- Limit to prevent freezing
    
    while not frontier:empty() do
        local current = frontier:pop()
        nodes_explored = nodes_explored + 1
        
        if nodes_explored > MAX_Explore then
            utils.log_error("Pathfinding limit reached!", "pathfinding")
            return nil
        end
        
        -- Check goal (approximate matching if needed, but exact here)
        if current.x == goal_node.x and current.y == goal_node.y and current.z == goal_node.z then
            -- Reconstruct path
            local path = {}
            local curr_key = string.format("%d,%d,%d", current.x, current.y, current.z)
            while curr_key do
                local node_data = nil
                -- We need to store node object or reconstruct it
                -- Simplified: re-parse key or store in separate table.
                -- Better: came_from stores the node object.
                local prev = came_from[curr_key]
                
                -- Parse key to node
                local x, y, z = curr_key:match("(-?%d+),(-?%d+),(-?%d+)")
                table.insert(path, 1, {x=tonumber(x), y=tonumber(y), z=tonumber(z)})
                
                if not prev then break end
                curr_key = string.format("%d,%d,%d", prev.x, prev.y, prev.z)
                if curr_key == start_key then
                    table.insert(path, 1, start_node)
                    break 
                end
            end
            return path
        end
        
        local neighbors = callbacks.neighbors(current)
        for _, next_node in ipairs(neighbors) do
            if callbacks.is_valid(next_node) then
                local new_cost = cost_so_far[start_key] + callbacks.cost(current, next_node) -- Bug here: should be cost_so_far[current_key]
                -- Correcting bug:
                local current_key = string.format("%d,%d,%d", current.x, current.y, current.z)
                new_cost = cost_so_far[current_key] + callbacks.cost(current, next_node)
                
                local next_key = string.format("%d,%d,%d", next_node.x, next_node.y, next_node.z)
                
                if not cost_so_far[next_key] or new_cost < cost_so_far[next_key] then
                    cost_so_far[next_key] = new_cost
                    local priority = new_cost + callbacks.heuristic(next_node, goal_node)
                    frontier:push(next_node, priority)
                    came_from[next_key] = current
                end
            end
        end
    end
    
    return nil -- No path found
end

-------------------------------------------------------------------------------
-- Helper for Ramp Pathfinding
-------------------------------------------------------------------------------

--- Default Manhattan Heuristic
function heuristic_manhattan(a, b)
    return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z) * 2 -- Z is more expensive
end

return _ENV
