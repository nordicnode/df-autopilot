-- df-autopilot/state.lua
-- State management and persistence

--@ module = true

local json = require("json")

local GLOBAL_KEY = "df-autopilot"

-- In-memory state
local state_data = {}
local dirty = false

--- Check if we can use persistent storage (requires loaded map)
local function can_persist()
    return dfhack.isMapLoaded() and df.global.gamemode == df.game_mode.DWARF
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Get a value from state
-- @param key The key to retrieve
-- @param default Default value if key doesn't exist
-- @return The value or default
function get(key, default)
    if state_data[key] ~= nil then
        return state_data[key]
    end
    return default
end

--- Set a value in state
-- @param key The key to set
-- @param value The value to store
function set(key, value)
    state_data[key] = value
    dirty = true
end

--- Update nested state (merges tables)
-- @param key The key to update
-- @param updates Table of updates to merge
function update(key, updates)
    local current = state_data[key] or {}
    if type(current) ~= "table" then
        current = {}
    end
    for k, v in pairs(updates) do
        current[k] = v
    end
    state_data[key] = current
    dirty = true
end

--- Increment a numeric counter
-- @param key The counter key (can be nested like "stats.ticks")
-- @param amount Amount to increment (default 1)
function increment(key, amount)
    amount = amount or 1
    
    -- Handle nested keys like "stats.ticks"
    local parts = {}
    for part in string.gmatch(key, "[^.]+") do
        table.insert(parts, part)
    end
    
    if #parts == 1 then
        state_data[key] = (state_data[key] or 0) + amount
    elseif #parts == 2 then
        local parent = parts[1]
        local child = parts[2]
        if not state_data[parent] then
            state_data[parent] = {}
        end
        state_data[parent][child] = (state_data[parent][child] or 0) + amount
    end
    
    dirty = true
end

--- Load state from persistent storage
function load()
    if not can_persist() then
        -- Initialize defaults without loading from storage
        state_data = {}
        dirty = false
        if not state_data.stats then
            state_data.stats = {
                ticks = 0,
                orders_created = 0,
                designations = 0,
                buildings_queued = 0
            }
        end
        if not state_data.managers then
            state_data.managers = {}
        end
        return
    end
    
    local persisted = dfhack.persistent.getSiteData(GLOBAL_KEY, {})
    
    -- Detect new embark by checking site ID (safer than world_id)
    local current_site_id = 0
    pcall(function()
        if df.global.plotinfo then
            current_site_id = df.global.plotinfo.site_id or 0
        end
    end)
    
    local stored_site_id = persisted.site_id or -1
    
    if stored_site_id ~= current_site_id then
        -- New embark detected! Clear all manager state
        print("[df-autopilot] New embark detected - clearing old state")
        persisted = {
            site_id = current_site_id
        }
        dirty = true
    end
    
    state_data = persisted
    state_data.site_id = current_site_id
    
    -- Initialize default structure if needed
    if not state_data.stats then
        state_data.stats = {
            ticks = 0,
            orders_created = 0,
            designations = 0,
            buildings_queued = 0
        }
    end
    
    if not state_data.managers then
        state_data.managers = {}
    end
    
    if dirty then
        save()
    end
end

--- Save state to persistent storage
function save()
    if not dirty then return end
    if not can_persist() then return end
    
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state_data)
    dirty = false
end

--- Force save regardless of dirty flag
function force_save()
    if not can_persist() then return end
    
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state_data)
    dirty = false
end

--- Clear all state
function clear()
    state_data = {}
    dirty = true
    if can_persist() then
        save()
    end
end

--- Get manager-specific state
-- @param manager_name Name of the manager
-- @return Table of manager state
function get_manager_state(manager_name)
    if not state_data.managers then
        state_data.managers = {}
    end
    if not state_data.managers[manager_name] then
        state_data.managers[manager_name] = {}
    end
    return state_data.managers[manager_name]
end

--- Set manager-specific state
-- @param manager_name Name of the manager
-- @param data Table of state data
function set_manager_state(manager_name, data)
    if not state_data.managers then
        state_data.managers = {}
    end
    state_data.managers[manager_name] = data
    dirty = true
end

--- Debug: print all state
function debug_print()
    print("=== df-autopilot State ===")
    for k, v in pairs(state_data) do
        if type(v) == "table" then
            print(k .. ":")
            for k2, v2 in pairs(v) do
                print("  " .. tostring(k2) .. " = " .. tostring(v2))
            end
        else
            print(k .. " = " .. tostring(v))
        end
    end
end

return _ENV
