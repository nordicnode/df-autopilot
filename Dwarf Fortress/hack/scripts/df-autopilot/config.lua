-- df-autopilot/config.lua
-- Configuration management

--@ module = true

local json = require("json")

local CONFIG_PATH = "dfhack-config/df-autopilot/settings.json"

-- Default configuration
local defaults = {
    -- General settings
    tick_interval = 100,           -- How often to run the main loop (in game ticks)
    log_level = "info",            -- "debug", "info", "warn", "error"
    
    -- Food settings
    food = {
        min_drinks = 50,           -- Minimum drinks before brewing more
        min_food = 50,             -- Minimum prepared food before cooking
        drinks_per_dwarf = 3,      -- Target drinks per dwarf
        food_per_dwarf = 2,        -- Target food per dwarf
        max_plants_to_brew = 30,   -- Max brewing jobs to queue at once
        max_food_to_cook = 20,     -- Max cooking jobs to queue at once
    },
    
    -- Workshop settings
    workshop = {
        min_bins = 20,             -- Minimum empty bins
        min_barrels = 20,          -- Minimum empty barrels
        min_beds = 5,              -- Minimum unassigned beds
        min_mechanisms = 10,       -- Minimum mechanisms for traps/bridges
        check_interval = 500,      -- How often to check workshop needs (ticks)
    },
    
    -- Mining settings
    mining = {
        auto_expand = true,        -- Automatically expand fortress
        expansion_threshold = 0.8, -- Expand when storage is X% full
        min_z_levels = 3,          -- Minimum z-levels to dig
    },
    
    -- Labor settings
    labor = {
        auto_assign = true,        -- Automatically assign labors
        hauler_ratio = 0.3,        -- Ratio of dwarves for hauling
        military_ratio = 0.2,      -- Ratio of dwarves for military
    },
    
    -- Military settings
    military = {
        min_squad_size = 4,        -- Minimum soldiers per squad
        max_squads = 3,            -- Maximum number of squads
        training_months = 6,       -- Months of training before active duty
        auto_draft = true,         -- Automatically draft soldiers
    },
    
    -- Zone settings
    zone = {
        bedroom_size = 4,          -- Width/height of bedrooms (4x4)
        dining_min_value = 1000,   -- Minimum dining room value
        hospital_beds = 5,         -- Number of hospital beds
    },
    
    -- Trade settings
    trade = {
        auto_trade = true,         -- Automatically handle trade
        export_threshold = 100,    -- Export items worth less than this
        import_priority = {        -- Items to prioritize importing
            "steel",
            "iron",
            "coal"
        },
    },
    
    -- Emergency settings
    emergency = {
        lockdown_on_siege = true,  -- Lock doors during siege
        alert_military = true,     -- Alert military on threats
        seal_breaches = true,      -- Auto-seal cavern breaches
    },
}

-- Current configuration (merged with defaults)
local config = nil

-------------------------------------------------------------------------------
-- Internal Functions
-------------------------------------------------------------------------------

local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = deep_copy(v)
    end
    return copy
end

local function deep_merge(base, overlay)
    if type(base) ~= "table" or type(overlay) ~= "table" then
        return overlay
    end
    
    local result = deep_copy(base)
    for k, v in pairs(overlay) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = deep_merge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

local function load_config_file()
    local file = io.open(CONFIG_PATH, "r")
    if not file then
        return nil
    end
    
    local content = file:read("*all")
    file:close()
    
    local ok, data = pcall(json.decode, content)
    if not ok then
        dfhack.printerr("[df-autopilot] Failed to parse config file: " .. tostring(data))
        return nil
    end
    
    return data
end

local function save_config_file()
    local content = json.encode(config)
    
    local file = io.open(CONFIG_PATH, "w")
    if not file then
        dfhack.printerr("[df-autopilot] Failed to write config file")
        return false
    end
    
    file:write(content)
    file:close()
    return true
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Initialize configuration (loads from file or uses defaults)
function init()
    local user_config = load_config_file()
    if user_config then
        config = deep_merge(defaults, user_config)
    else
        config = deep_copy(defaults)
        -- Create default config file
        save_config_file()
    end
end

--- Get a configuration value
-- @param key The key to retrieve (supports dot notation like "food.min_drinks")
-- @param default Default value if not found
-- @return The configuration value
function get(key, default)
    if not config then init() end
    
    -- Handle dot notation
    local parts = {}
    for part in string.gmatch(key, "[^.]+") do
        table.insert(parts, part)
    end
    
    local current = config
    for _, part in ipairs(parts) do
        if type(current) ~= "table" then
            return default
        end
        current = current[part]
        if current == nil then
            return default
        end
    end
    
    return current
end

--- Set a configuration value
-- @param key The key to set
-- @param value The value to store
function set(key, value)
    if not config then init() end
    
    local parts = {}
    for part in string.gmatch(key, "[^.]+") do
        table.insert(parts, part)
    end
    
    if #parts == 1 then
        config[key] = value
    else
        local current = config
        for i = 1, #parts - 1 do
            if type(current[parts[i]]) ~= "table" then
                current[parts[i]] = {}
            end
            current = current[parts[i]]
        end
        current[parts[#parts]] = value
    end
    
    save_config_file()
end

--- Reload configuration from file
function reload()
    config = nil
    init()
end

--- Get all defaults
function get_defaults()
    return deep_copy(defaults)
end

--- Reset to defaults
function reset()
    config = deep_copy(defaults)
    save_config_file()
end

-- Auto-initialize when required
init()

return _ENV
