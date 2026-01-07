-- df-autopilot/managers/workshop.lua
-- Workshop management and essential item production

--@ module = true

local utils = reqscript("df-autopilot/utils")
local config = reqscript("df-autopilot/config")
local state = reqscript("df-autopilot/state")

local MANAGER_NAME = "workshop"
local last_check = 0

-------------------------------------------------------------------------------
-- Internal Functions
-------------------------------------------------------------------------------

--- Count empty bins
local function count_empty_bins()
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if item:getType() == df.item_type.BIN and utils.is_valid_item(item) then
            -- A bin is empty if it has no contained items
            local is_empty = true
            for _, ref in pairs(item.general_refs) do
                if ref:getType() == df.general_ref_type.CONTAINS_ITEM then
                    is_empty = false
                    break
                end
            end
            if is_empty and not item.flags.in_building then
                count = count + 1
            end
        end
    end
    return count
end

--- Count empty barrels/pots
local function count_empty_barrels()
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        local item_type = item:getType()
        if item_type == df.item_type.BARREL and utils.is_valid_item(item) then
            -- Check if empty
            local is_empty = true
            for _, ref in pairs(item.general_refs) do
                if ref:getType() == df.general_ref_type.CONTAINS_ITEM then
                    is_empty = false
                    break
                end
            end
            if is_empty and not item.flags.in_building then
                count = count + 1
            end
        end
    end
    return count
end

--- Count unassigned beds
local function count_available_beds()
    local count = 0
    for _, item in pairs(df.global.world.items.other[df.items_other_id.IN_PLAY]) do
        if item:getType() == df.item_type.BED and utils.is_valid_item(item) then
            if not item.flags.in_building then
                count = count + 1
            end
        end
    end
    return count
end

--- Count mechanisms
local function count_mechanisms()
    return utils.count_items(df.item_type.TRAPPARTS, nil)
end

--- Check if we have a carpenter's workshop
local function has_carpenter()
    return utils.count_workshops(df.workshop_type.Carpenters) > 0
end

--- Check if we have a craftsdwarf's workshop
local function has_craftshop()
    return utils.count_workshops(df.workshop_type.Craftsdwarfs) > 0
end

--- Check if we have a mechanic's workshop
local function has_mechanic()
    return utils.count_workshops(df.workshop_type.Mechanics) > 0
end

--- Queue bin construction
local function queue_bins(amount)
    if not has_carpenter() then
        utils.log_debug("No carpenter's workshop, can't make bins")
        return false
    end
    
    if utils.order_exists(df.job_type.ConstructBin, 0) then
        return false
    end
    
    local order = utils.create_order(df.job_type.ConstructBin, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Queue barrel construction
local function queue_barrels(amount)
    if not has_carpenter() then
        utils.log_debug("No carpenter's workshop, can't make barrels")
        return false
    end
    
    if utils.order_exists(df.job_type.MakeBarrel, 0) then
        return false
    end
    
    local order = utils.create_order(df.job_type.MakeBarrel, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Queue bed construction
local function queue_beds(amount)
    if not has_carpenter() then
        utils.log_debug("No carpenter's workshop, can't make beds")
        return false
    end
    
    if utils.order_exists(df.job_type.ConstructBed, 0) then
        return false
    end
    
    local order = utils.create_order(df.job_type.ConstructBed, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Queue mechanism construction
local function queue_mechanisms(amount)
    if not has_mechanic() then
        utils.log_debug("No mechanic's workshop, can't make mechanisms")
        return false
    end
    
    if utils.order_exists(df.job_type.ConstructMechanisms, 0) then
        return false
    end
    
    local order = utils.create_order(df.job_type.ConstructMechanisms, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Hospital Supplies
-------------------------------------------------------------------------------

--- Count thread
local function count_thread()
    return utils.count_items(df.item_type.THREAD, nil)
end

--- Count cloth
local function count_cloth()
    return utils.count_items(df.item_type.CLOTH, nil)
end

--- Count soap
local function count_soap()
    -- Soap is a BAR item with no specific subtype but material type SOAP
    -- However, utils.count_items checks subtype, not material
    -- We'll just count bars for now, or improve count_items to check material
    return utils.count_items(df.item_type.BAR, nil)
end

--- Count splints
local function count_splints()
    return utils.count_items(df.item_type.SPLINT, nil)
end

--- Count crutches
local function count_crutches()
    return utils.count_items(df.item_type.CRUTCH, nil)
end

--- Count buckets
local function count_buckets()
    return utils.count_items(df.item_type.BUCKET, nil)
end

--- Has a loom
local function has_loom()
    return utils.count_workshops(df.workshop_type.Loom) > 0
end

--- Has a soap maker
local function has_soap_maker()
    return utils.count_workshops(df.workshop_type.SoapMaker) > 0
end

--- Queue thread production
local function queue_thread(amount)
    if not has_loom() then return false end
    if utils.order_exists(df.job_type.SpinThread, 0) then return false end
    
    local order = utils.create_order(df.job_type.SpinThread, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Queue cloth production
local function queue_cloth(amount)
    if not has_loom() then return false end
    if utils.order_exists(df.job_type.WeaveCloth, 0) then return false end
    
    local order = utils.create_order(df.job_type.WeaveCloth, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Queue soap production
local function queue_soap(amount)
    if not has_soap_maker() then return false end
    if utils.order_exists(df.job_type.MakeSoap, 0) then return false end
    
    local order = utils.create_order(df.job_type.MakeSoap, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Queue splint production
local function queue_splints(amount)
    if not has_carpenter() then return false end
    if utils.order_exists(df.job_type.ConstructSplint, 0) then return false end
    
    local order = utils.create_order(df.job_type.ConstructSplint, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Queue crutch production
local function queue_crutches(amount)
    if not has_carpenter() then return false end
    if utils.order_exists(df.job_type.ConstructCrutch, 0) then return false end
    
    local order = utils.create_order(df.job_type.ConstructCrutch, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Queue bucket production
local function queue_buckets(amount)
    if not has_carpenter() then return false end
    if utils.order_exists(df.job_type.MakeBucket, 0) then return false end
    
    local order = utils.create_order(df.job_type.MakeBucket, amount)
    if order then
        state.increment("stats.orders_created")
        return true
    end
    return false
end

--- Ensure hospital supplies are stocked
local function ensure_hospital_supplies()
    local min_thread = config.get("workshop.min_thread", 20)
    local min_cloth = config.get("workshop.min_cloth", 10)
    local min_soap = config.get("workshop.min_soap", 10)
    local min_splints = config.get("workshop.min_splints", 5)
    local min_crutches = config.get("workshop.min_crutches", 3)
    local min_buckets = config.get("workshop.min_buckets", 5)
    
    local thread = count_thread()
    local cloth = count_cloth()
    local soap = count_soap()
    local splints = count_splints()
    local crutches = count_crutches()
    local buckets = count_buckets()
    
    if thread < min_thread then
        queue_thread(math.min(min_thread - thread, 10))
    end
    
    if cloth < min_cloth and thread >= 5 then
        queue_cloth(math.min(min_cloth - cloth, 5))
    end
    
    if soap < min_soap then
        queue_soap(math.min(min_soap - soap, 5))
    end
    
    if splints < min_splints then
        queue_splints(math.min(min_splints - splints, 3))
    end
    
    if crutches < min_crutches then
        queue_crutches(math.min(min_crutches - crutches, 2))
    end
    
    if buckets < min_buckets then
        queue_buckets(math.min(min_buckets - buckets, 3))
    end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Main update function
function update()
    local check_interval = config.get("workshop.check_interval", 500)
    local current_tick = df.global.cur_year_tick
    if current_tick - last_check < check_interval then
        return
    end
    last_check = current_tick
    
    -- Get current counts
    local bins = count_empty_bins()
    local barrels = count_empty_barrels()
    local beds = count_available_beds()
    local mechanisms = count_mechanisms()
    
    -- Get thresholds
    local min_bins = config.get("workshop.min_bins", 20)
    local min_barrels = config.get("workshop.min_barrels", 20)
    local min_beds = config.get("workshop.min_beds", 5)
    local min_mechanisms = config.get("workshop.min_mechanisms", 10)
    
    -- Update state for status display
    state.set_manager_state(MANAGER_NAME, {
        bins = bins,
        min_bins = min_bins,
        barrels = barrels,
        min_barrels = min_barrels,
        beds = beds,
        min_beds = min_beds,
        mechanisms = mechanisms,
        min_mechanisms = min_mechanisms,
        last_check = current_tick
    })
    
    -- Queue production as needed
    if bins < min_bins then
        local needed = min_bins - bins
        queue_bins(math.min(needed, 10))
    end
    
    if barrels < min_barrels then
        local needed = min_barrels - barrels
        queue_barrels(math.min(needed, 10))
    end
    
    if beds < min_beds then
        local needed = min_beds - beds
        queue_beds(math.min(needed, 5))
    end
    
    if mechanisms < min_mechanisms then
        local needed = min_mechanisms - mechanisms
        queue_mechanisms(math.min(needed, 5))
    end
    
    -- Ensure hospital supplies
    if config.get("workshop.hospital_supplies", true) then
        ensure_hospital_supplies()
    end
end

--- Get status for display
function get_status()
    local mgr_state = state.get_manager_state(MANAGER_NAME)
    if not mgr_state or mgr_state.bins == nil then
        return "waiting"
    end
    
    return string.format("bins: %d/%d, barrels: %d/%d, beds: %d",
        mgr_state.bins or 0,
        mgr_state.min_bins or 0,
        mgr_state.barrels or 0,
        mgr_state.min_barrels or 0,
        mgr_state.beds or 0
    )
end

return _ENV
