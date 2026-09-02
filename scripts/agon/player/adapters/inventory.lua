-- WP7：保存并恢复背包、装备、鼠标物品以及物品容器边界。

local Util = require("agon/player/adapters/util")

local InventoryAdapter = {}
InventoryAdapter.adapter_id = "inventory"
InventoryAdapter.version = 1
InventoryAdapter.order = 10
InventoryAdapter.dependencies = {}

InventoryAdapter.ERROR_CODES =
{
    PLAYER_INVALID = "INVENTORY_PLAYER_INVALID",
    COMPONENT_MISSING = "INVENTORY_COMPONENT_MISSING",
    SNAPSHOT_INVALID = "INVENTORY_SNAPSHOT_INVALID",
    ITEM_INVALID = "INVENTORY_ITEM_INVALID",
    CLEAN_FAILED = "INVENTORY_CLEAN_FAILED",
    PROFILE_ITEMS_UNSUPPORTED = "INVENTORY_LIVE_PROFILE_ITEMS_UNSUPPORTED",
    RESTORE_ITEM_INVALID = "INVENTORY_RESTORE_ITEM_INVALID",
    RESTORE_FAILED = "INVENTORY_RESTORE_FAILED",
    RESTORE_MISMATCH = "INVENTORY_RESTORE_MISMATCH",
}

local function IsValidObject(value)
    if value == nil then
        return false
    end
    if type(value.IsValid) ~= "function" then
        return true
    end
    local ok, valid = pcall(value.IsValid, value)
    return ok and valid == true
end

local function GetContainer(item)
    if item == nil or type(item) ~= "table" or type(item.components) ~= "table" then
        return nil
    end
    return item.components.container or item.components.inventory
end

local function CaptureItem(item, synthetic)
    if item == nil then
        return nil
    end
    if synthetic then
        return Util.CopyData(item)
    end

    local descriptor =
    {
        prefab = Util.GetItemPrefab(item),
        save_record = Util.GetSaveRecord(item),
        runtime_ref = item,
    }
    local container = GetContainer(item)
    if container ~= nil and type(container.GetNumSlots) == "function"
        and type(container.GetItemInSlot) == "function" then
        descriptor.contents = {}
        local ok, slot_count = pcall(container.GetNumSlots, container)
        if not ok or type(slot_count) ~= "number" then
            return nil
        end
        for slot = 1, slot_count do
            local item_ok, nested = pcall(container.GetItemInSlot, container, slot)
            if not item_ok then
                return nil
            end
            descriptor.contents[slot] = CaptureItem(nested, false)
        end
    end
    return descriptor
end

local function ValidateItemDescriptor(item, synthetic, seen)
    if item == nil then
        return true
    end
    if type(item) ~= "table" then
        return false
    end
    seen = seen or {}
    if seen[item] then
        return false
    end
    seen[item] = true
    if synthetic then
        if type(item.prefab) ~= "string" or item.prefab == "" then
            seen[item] = nil
            return false
        end
    else
        if not IsValidObject(item.runtime_ref)
            or (item.prefab ~= nil and type(item.prefab) ~= "string") then
            seen[item] = nil
            return false
        end
    end
    if item.contents ~= nil then
        if type(item.contents) ~= "table" then
            seen[item] = nil
            return false
        end
        for slot = 1, #item.contents do
            if not ValidateItemDescriptor(item.contents[slot], synthetic, seen) then
                seen[item] = nil
                return false
            end
        end
    end
    seen[item] = nil
    return true
end

local function ValidateState(data, synthetic)
    if type(data) ~= "table"
        or type(data.slots) ~= "table"
        or type(data.equipment) ~= "table" then
        return false
    end
    for _, item in pairs(data.slots) do
        if not ValidateItemDescriptor(item, synthetic) then
            return false
        end
    end
    for _, item in pairs(data.equipment) do
        if not ValidateItemDescriptor(item, synthetic) then
            return false
        end
    end
    if not ValidateItemDescriptor(data.active_item, synthetic) then
        return false
    end
    if data.containers ~= nil and type(data.containers) ~= "table" then
        return false
    end
    return true
end

local function CaptureSynthetic(player)
    local state = Util.GetTestState(player)
    if state == nil then
        return nil, InventoryAdapter.ERROR_CODES.PLAYER_INVALID
    end
    state.inventory = state.inventory or
    {
        slots = {},
        equipment = {},
        active_item = nil,
        containers = {},
    }
    local data = Util.CopyData(state.inventory)
    if data.activeitem ~= nil and data.active_item == nil then
        data.active_item = data.activeitem
        data.activeitem = nil
    end
    data.slots = data.slots or {}
    data.equipment = data.equipment or {}
    data.containers = data.containers or {}
    if not ValidateState(data, true) then
        return nil, InventoryAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

local function CaptureLive(player)
    local components = Util.GetComponents(player)
    local inventory = components ~= nil and components.inventory or nil
    if inventory == nil
        or type(inventory.GetNumSlots) ~= "function"
        or type(inventory.GetItemInSlot) ~= "function"
        or type(inventory.GetEquippedItem) ~= "function"
        or type(inventory.GetActiveItem) ~= "function" then
        return nil, InventoryAdapter.ERROR_CODES.COMPONENT_MISSING
    end

    local data =
    {
        slots = {},
        equipment = {},
        active_item = nil,
        containers = {},
        runtime = true,
    }
    local ok, slot_count = pcall(inventory.GetNumSlots, inventory)
    if not ok or type(slot_count) ~= "number" then
        return nil, InventoryAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    for slot = 1, slot_count do
        local item_ok, item = pcall(inventory.GetItemInSlot, inventory, slot)
        if not item_ok then
            return nil, InventoryAdapter.ERROR_CODES.SNAPSHOT_INVALID
        end
        data.slots[slot] = CaptureItem(item, false)
    end
    for equipment_slot, item in pairs(inventory.equipslots or {}) do
        data.equipment[equipment_slot] = CaptureItem(item, false)
    end
    local active_ok, active_item = pcall(inventory.GetActiveItem, inventory)
    if not active_ok then
        return nil, InventoryAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    data.active_item = CaptureItem(active_item, false)

    if not ValidateState(data, false) then
        return nil, InventoryAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

function InventoryAdapter.Capture(player)
    if not Util.IsValidPlayer(player) then
        return nil, InventoryAdapter.ERROR_CODES.PLAYER_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        return CaptureSynthetic(player)
    end
    return CaptureLive(player)
end

function InventoryAdapter.ValidateCapture(player, data)
    if not Util.IsValidPlayer(player) then
        return false, InventoryAdapter.ERROR_CODES.PLAYER_INVALID
    end
    local synthetic = Util.IsSyntheticPlayer(player)
    if not ValidateState(data, synthetic) then
        return false, InventoryAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return true
end

local function CloseOpenContainers(player, inventory)
    for container_inst in pairs(inventory.opencontainers or {}) do
        local container = container_inst.components ~= nil
            and (container_inst.components.container or container_inst.components.inventory)
            or nil
        if container ~= nil and type(container.Close) == "function" then
            local ok = pcall(container.Close, container, player)
            if not ok then
                return false
            end
        end
    end
    return true
end

local function ClearLiveInventory(player, inventory)
    if not CloseOpenContainers(player, inventory) then
        return false, InventoryAdapter.ERROR_CODES.CLEAN_FAILED
    end
    local active = inventory:GetActiveItem()
    if active ~= nil then
        local ok = pcall(inventory.SetActiveItem, inventory, nil)
        if not ok then
            return false, InventoryAdapter.ERROR_CODES.CLEAN_FAILED
        end
    end
    local slot_count = inventory:GetNumSlots()
    for slot = 1, slot_count do
        local item = inventory:GetItemInSlot(slot)
        if item ~= nil then
            local removed = inventory:RemoveItemBySlot(slot, true)
            if removed == nil then
                return false, InventoryAdapter.ERROR_CODES.CLEAN_FAILED
            end
        end
    end
    local equipped = {}
    for equipment_slot, item in pairs(inventory.equipslots or {}) do
        if item ~= nil then
            equipped[equipment_slot] = true
        end
    end
    for equipment_slot in pairs(equipped) do
        local removed = inventory:Unequip(equipment_slot, nil, true)
        if removed == nil then
            return false, InventoryAdapter.ERROR_CODES.CLEAN_FAILED
        end
    end
    return true
end

function InventoryAdapter.EnterCleanState(player)
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        state.inventory =
        {
            slots = {},
            equipment = {},
            active_item = nil,
            containers = {},
        }
        return true
    end
    local components = Util.GetComponents(player)
    local inventory = components ~= nil and components.inventory or nil
    if inventory == nil then
        return false, InventoryAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    return ClearLiveInventory(player, inventory)
end

local function AddProfileItem(inventory, item, next_slot)
    local descriptor = type(item) == "string" and { prefab = item } or Util.CopyData(item)
    local count = descriptor.count or 1
    descriptor.count = count
    if descriptor.active == true then
        inventory.active_item = descriptor
    elseif descriptor.equipment_slot ~= nil then
        inventory.equipment[descriptor.equipment_slot] = descriptor
    else
        local slot = descriptor.slot or next_slot
        while inventory.slots[slot] ~= nil do
            slot = slot + 1
        end
        descriptor.slot = slot
        inventory.slots[slot] = descriptor
    end
    return math.max(next_slot, (descriptor.slot or next_slot) + 1)
end

function InventoryAdapter.ApplyOverrides(player, context, sandbox)
    context = context or {}
    local profile = sandbox ~= nil and sandbox.profile or context.profile
    if profile == nil then
        return false, InventoryAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if context.inventory_profile_applied then
        return true
    end
    if not Util.IsSyntheticPlayer(player) then
        if #(profile.starting_items or {}) > 0 then
            return false, InventoryAdapter.ERROR_CODES.PROFILE_ITEMS_UNSUPPORTED
        end
        context.inventory_profile_applied = true
        return true
    end

    local state = Util.GetTestState(player)
    state.inventory = state.inventory or { slots = {}, equipment = {}, active_item = nil, containers = {} }
    state.inventory.slots = state.inventory.slots or {}
    state.inventory.equipment = state.inventory.equipment or {}
    state.inventory.containers = state.inventory.containers or {}
    local next_slot = 1
    for index = 1, #(profile.starting_items or {}) do
        next_slot = AddProfileItem(state.inventory, profile.starting_items[index], next_slot)
    end
    context.inventory_profile_applied = true
    return true
end

function InventoryAdapter.RemoveOverrides(player, context)
    context = context or {}
    if context.inventory_overrides_removed then
        return true
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        state.inventory =
        {
            slots = {},
            equipment = {},
            active_item = nil,
            containers = {},
        }
        context.inventory_overrides_removed = true
        return true
    end
    local components = Util.GetComponents(player)
    local inventory = components ~= nil and components.inventory or nil
    if inventory == nil then
        return false, InventoryAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    local cleared, code = ClearLiveInventory(player, inventory)
    if cleared then
        context.inventory_overrides_removed = true
    end
    return cleared, code
end

local function RestoreLive(player, data)
    local components = Util.GetComponents(player)
    local inventory = components ~= nil and components.inventory or nil
    if inventory == nil then
        return false, InventoryAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    local cleared, clear_code = ClearLiveInventory(player, inventory)
    if not cleared then
        return false, clear_code
    end
    for slot, descriptor in pairs(data.slots or {}) do
        if descriptor ~= nil then
            if not IsValidObject(descriptor.runtime_ref) then
                return false, InventoryAdapter.ERROR_CODES.RESTORE_ITEM_INVALID
            end
            inventory:GiveItem(descriptor.runtime_ref, slot)
        end
    end
    for equipment_slot, descriptor in pairs(data.equipment or {}) do
        if descriptor ~= nil then
            if not IsValidObject(descriptor.runtime_ref) then
                return false, InventoryAdapter.ERROR_CODES.RESTORE_ITEM_INVALID
            end
            inventory:Equip(descriptor.runtime_ref, nil, true, true)
        end
    end
    if data.active_item ~= nil then
        if not IsValidObject(data.active_item.runtime_ref) then
            return false, InventoryAdapter.ERROR_CODES.RESTORE_ITEM_INVALID
        end
        inventory:GiveActiveItem(data.active_item.runtime_ref)
    end
    return true
end

function InventoryAdapter.Restore(player, data)
    if not ValidateState(data, Util.IsSyntheticPlayer(player)) then
        return false, InventoryAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        state.inventory = Util.CopyData(data)
        return true
    end
    return RestoreLive(player, data)
end

local function ValidateLiveRestore(player, data)
    local components = Util.GetComponents(player)
    local inventory = components ~= nil and components.inventory or nil
    if inventory == nil then
        return false, InventoryAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    for slot, descriptor in pairs(data.slots or {}) do
        local actual = inventory:GetItemInSlot(slot)
        if descriptor == nil and actual ~= nil then
            return false, InventoryAdapter.ERROR_CODES.RESTORE_MISMATCH
        end
        if descriptor ~= nil and actual ~= descriptor.runtime_ref then
            return false, InventoryAdapter.ERROR_CODES.RESTORE_MISMATCH
        end
    end
    for equipment_slot, descriptor in pairs(data.equipment or {}) do
        local actual = inventory:GetEquippedItem(equipment_slot)
        if descriptor == nil and actual ~= nil then
            return false, InventoryAdapter.ERROR_CODES.RESTORE_MISMATCH
        end
        if descriptor ~= nil and actual ~= descriptor.runtime_ref then
            return false, InventoryAdapter.ERROR_CODES.RESTORE_MISMATCH
        end
    end
    local active = inventory:GetActiveItem()
    if data.active_item == nil and active ~= nil then
        return false, InventoryAdapter.ERROR_CODES.RESTORE_MISMATCH
    end
    if data.active_item ~= nil and active ~= data.active_item.runtime_ref then
        return false, InventoryAdapter.ERROR_CODES.RESTORE_MISMATCH
    end
    return true
end

function InventoryAdapter.ValidateRestore(player, data)
    if not ValidateState(data, Util.IsSyntheticPlayer(player)) then
        return false, InventoryAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local actual = state ~= nil and state.inventory or nil
        return Util.DeepEqual(actual, data),
            Util.DeepEqual(actual, data) and nil or InventoryAdapter.ERROR_CODES.RESTORE_MISMATCH
    end
    return ValidateLiveRestore(player, data)
end

return InventoryAdapter
