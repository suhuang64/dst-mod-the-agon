-- WP10：Spectator 物品、装备、容器和制作的服务端权威保护。
--
-- 这里不删除玩家物品，也不把临时清空后的背包写回存档。进入观战时先
-- 保存 InventoryAdapter 的运行时引用和官方 OnSave 返回值，再清理当前
-- gameplay 状态；退出时恢复原始方法并把同一批运行时物品放回原位置。

local InventoryAdapter = require("agon/player/adapters/inventory")
local Util = require("agon/player/adapters/util")

local Guard = {}

Guard.ERROR_CODES =
{
    PLAYER_INVALID = "SPECTATOR_INVENTORY_PLAYER_INVALID",
    CAPTURE_FAILED = "SPECTATOR_INVENTORY_CAPTURE_FAILED",
    SAVE_CAPTURE_FAILED = "SPECTATOR_INVENTORY_SAVE_CAPTURE_FAILED",
    CLEAN_FAILED = "SPECTATOR_INVENTORY_CLEAN_FAILED",
    RESTORE_FAILED = "SPECTATOR_INVENTORY_RESTORE_FAILED",
}

local function IsTable(value)
    return type(value) == "table"
end

local function IsSpectator(player)
    return IsTable(player) and player.is_spectator == true
end

local function IsGuardCleanup(player)
    return IsTable(player)
        and player._agon_spectator_guard_cleanup == true
end

local function GetComponents(inst)
    return IsTable(inst) and IsTable(inst.components)
        and inst.components or nil
end

local function GetGrandOwner(inst)
    if not IsTable(inst) then
        return nil
    end
    local components = GetComponents(inst)
    local inventoryitem = components ~= nil and components.inventoryitem or nil
    if inventoryitem == nil then
        return nil
    end
    if type(inventoryitem.GetGrandOwner) == "function" then
        local ok, owner = pcall(inventoryitem.GetGrandOwner, inventoryitem)
        if ok and owner ~= nil then
            return owner
        end
    end
    return inventoryitem.owner
end

-- 进入观战后物品会暂时脱离 Inventory，不能只依赖 inventoryitem.owner；
-- 用弱引用记录本次快照的运行时物品，既能覆盖脱离后的效果读取，也不会
-- 把玩家对象或临时标记写入物品存档。
local spectator_guard_item_owners = setmetatable({}, { __mode = "k" })

local function IsGuardTrackedItem(inst)
    return IsTable(inst)
        and IsSpectator(spectator_guard_item_owners[inst])
end

local function IsOwnedBySpectator(inst)
    return IsSpectator(inst) or IsSpectator(GetGrandOwner(inst))
        or IsGuardTrackedItem(inst)
end

local function IsGuardCleanupOwner(owner)
    return IsGuardCleanup(owner)
        or IsGuardCleanup(GetGrandOwner(owner))
end

local function HasSpectatorArgument(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if IsSpectator(value) or IsOwnedBySpectator(value) then
            return true
        end
    end
    return false
end

local function CaptureMethods(component, method_names)
    local state =
    {
        raw = {},
        original = {},
    }
    if not IsTable(component) then
        return state
    end
    for index = 1, #method_names do
        local name = method_names[index]
        state.raw[name] = rawget(component, name)
        state.original[name] = component[name]
    end
    return state
end

local function RestoreMethods(component, state)
    if not IsTable(component) or not IsTable(state)
        or not IsTable(state.raw) then
        return
    end
    for name, value in pairs(state.raw) do
        rawset(component, name, value)
    end
end

-- 组件级 hook 只安装一次；它们会一直调用官方原方法，只有当相关 owner
-- 处于 Spectator guard 时才返回阻断值。
local installed_component_methods = setmetatable({}, { __mode = "k" })
local stable_method_baselines = setmetatable({}, { __mode = "k" })

local function CaptureStableMethods(component, method_names)
    if not IsTable(component) then
        return CaptureMethods(component, method_names)
    end
    local baseline = stable_method_baselines[component]
    if baseline == nil then
        baseline = CaptureMethods(component, method_names)
        stable_method_baselines[component] = baseline
    end
    return baseline
end

local function RegisterDescriptorItems(descriptor, player)
    if not IsTable(descriptor) then
        return
    end
    local item = descriptor.runtime_ref
    if IsTable(item) then
        spectator_guard_item_owners[item] = player
    end
    if IsTable(descriptor.contents) then
        for _, nested in pairs(descriptor.contents) do
            RegisterDescriptorItems(nested, player)
        end
    end
end

local function RegisterGuardItems(data, player)
    if not IsTable(data) then
        return
    end
    if IsTable(data.slots) then
        for _, descriptor in pairs(data.slots) do
            RegisterDescriptorItems(descriptor, player)
        end
    end
    if IsTable(data.equipment) then
        for _, descriptor in pairs(data.equipment) do
            RegisterDescriptorItems(descriptor, player)
        end
    end
    RegisterDescriptorItems(data.active_item, player)
end

local function UnregisterDescriptorItems(descriptor, player)
    if not IsTable(descriptor) then
        return
    end
    local item = descriptor.runtime_ref
    if IsTable(item) and spectator_guard_item_owners[item] == player then
        spectator_guard_item_owners[item] = nil
    end
    if IsTable(descriptor.contents) then
        for _, nested in pairs(descriptor.contents) do
            UnregisterDescriptorItems(nested, player)
        end
    end
end

local function UnregisterGuardItems(data, player)
    if not IsTable(data) then
        return
    end
    if IsTable(data.slots) then
        for _, descriptor in pairs(data.slots) do
            UnregisterDescriptorItems(descriptor, player)
        end
    end
    if IsTable(data.equipment) then
        for _, descriptor in pairs(data.equipment) do
            UnregisterDescriptorItems(descriptor, player)
        end
    end
    UnregisterDescriptorItems(data.active_item, player)
end

local function InstallComponentMethod(component, name, blocked_result, predicate)
    if not IsTable(component) then
        return
    end
    local installed = installed_component_methods[component]
    if installed == nil then
        installed = {}
        installed_component_methods[component] = installed
    end
    if installed[name] then
        return
    end
    local original = component[name]
    if type(original) ~= "function" then
        return
    end
    installed[name] = true
    rawset(component, name, function(self, ...)
        if predicate(self, ...) then
            if type(blocked_result) == "function" then
                return blocked_result(self, ...)
            end
            return blocked_result
        end
        return original(self, ...)
    end)
end

local function InstallComponentMethods(component, method_names, blocked_result, predicate)
    for index = 1, #method_names do
        InstallComponentMethod(
            component,
            method_names[index],
            blocked_result,
            predicate
        )
    end
end

local INVENTORY_METHODS =
{
    "EnableDropOnDeath",
    "DisableDropOnDeath",
    "TransferInventory",
    "SwapEquipment",
    "DropActiveItem",
    "ReturnActiveActionItem",
    "ApplyDamage",
    "HasAnyEquipment",
    "IsWearingArmor",
    "ArmorHasTag",
    "EquipHasTag",
    "EquipHasSpDefenseForType",
    "IsHeavyLifting",
    "IsFloaterHeld",
    "IsInsulated",
    "GetActiveItem",
    "IsItemEquipped",
    "GetEquippedItem",
    "GetItemInSlot",
    "GetFirstItemInAnySlot",
    "GetOverflowContainer",
    "GetSpecializedContainers",
    "Has",
    "HasItemThatMatches",
    "HasItemWithTag",
    "GetItemsWithTag",
    "GetItemByName",
    "GetCraftingIngredient",
    "IsHolding",
    "FindItem",
    "FindItems",
    "ForEachItem",
    "ForEachWetableItem",
    "ForEachEquipment",
    "ForEachItemSlot",
    "GetEquippedMoistureRate",
    "GetWaterproofness",
    "IsWaterproof",
    "GetOpenContainerProxyFor",
    "CanAcceptCount",
    "AcceptsStacks",
    "IgnoresCanGoInContainer",
    "SelectActiveItemFromEquipSlot",
    "CombineActiveStackWithSlot",
    "SelectActiveItemFromSlot",
    "ReturnActiveItem",
    "RemoveItemBySlot",
    "DropItem",
    "GiveActiveItem",
    "GiveItem",
    "Unequip",
    "SetActiveItem",
    "Equip",
    "RemoveItem",
    "DropEverythingWithTag",
    "DropEverythingByFilter",
    "DropEverything",
    "DropEquipped",
    "DestroyContents",
    "ConsumeByName",
    "CanTakeItemInSlot",
    "CanAccessItem",
    "IsOpenedBy",
    "Show",
    "Open",
    "Hide",
    "Close",
    "CloseAllChestContainers",
    "PutOneOfActiveItemInSlot",
    "PutAllOfActiveItemInSlot",
    "TakeActiveItemFromHalfOfSlot",
    "TakeActiveItemFromCountOfSlot",
    "TakeActiveItemFromAllOfSlot",
    "AddOneOfActiveItemToSlot",
    "AddAllOfActiveItemToSlot",
    "SwapActiveItemWithSlot",
    "UseItemFromInvTile",
    "ControllerUseItemOnItemFromInvTile",
    "ControllerUseItemOnSelfFromInvTile",
    "ControllerUseItemOnSceneFromInvTile",
    "InspectItemFromInvTile",
    "DropItemFromInvTile",
    "CastSpellBookFromInv",
    "EquipActiveItem",
    "EquipActionItem",
    "SwapEquipWithActiveItem",
    "TakeActiveItemFromEquipSlot",
    "TakeActiveItemFromEquipSlotID",
    "MoveItemFromAllOfSlot",
    "MoveItemFromHalfOfSlot",
    "MoveItemFromCountOfSlot",
    "TransferComponent",
}

local INVENTORY_FALSE_METHODS =
{
    CanTakeItemInSlot = true,
    CanAccessItem = true,
    IsOpenedBy = true,
    ApplyDamage = true,
    HasAnyEquipment = true,
    IsWearingArmor = true,
    ArmorHasTag = true,
    EquipHasTag = true,
    EquipHasSpDefenseForType = true,
    IsHeavyLifting = true,
    IsFloaterHeld = true,
    IsInsulated = true,
    IsWaterproof = true,
    Has = true,
    HasItemThatMatches = true,
    HasItemWithTag = true,
    IsHolding = true,
    CanAcceptCount = true,
    AcceptsStacks = true,
    IgnoresCanGoInContainer = true,
    GiveActiveItem = true,
    GiveItem = true,
    RemoveItemBySlot = true,
    Equip = true,
    Unequip = true,
    RemoveItem = true,
    MoveItemFromAllOfSlot = true,
    MoveItemFromHalfOfSlot = true,
    MoveItemFromCountOfSlot = true,
    UseItemFromInvTile = true,
    ControllerUseItemOnItemFromInvTile = true,
    ControllerUseItemOnSelfFromInvTile = true,
    ControllerUseItemOnSceneFromInvTile = true,
    DropItemFromInvTile = true,
    EquipActiveItem = true,
    EquipActionItem = true,
    SwapEquipWithActiveItem = true,
    TakeActiveItemFromEquipSlot = true,
    TakeActiveItemFromEquipSlotID = true,
    CanTakeItemInSlot = true,
    CanAccessItem = true,
    IsOpenedBy = true,
}

local function GetBlockedInventoryResult(name)
    if name == "ApplyDamage" then
        return 0, nil
    elseif name == "CanAcceptCount" then
        return 0
    elseif name == "GetEquippedMoistureRate" then
        return 0, 0
    elseif name == "GetWaterproofness" then
        return 0
    elseif name == "GetItemsWithTag" or name == "FindItems" then
        return {}
    elseif name == "Has" or name == "HasItemThatMatches"
        or name == "HasItemWithTag" then
        return false, 0
    elseif name == "GetEquippedItem" or name == "GetItemInSlot"
        or name == "GetActiveItem" or name == "GetFirstItemInAnySlot"
        or name == "GetOverflowContainer" or name == "GetSpecializedContainers"
        or name == "GetItemByName" or name == "GetCraftingIngredient"
        or name == "FindItem" or name == "GetOpenContainerProxyFor"
        or name == "IsItemEquipped" then
        return nil
    elseif name == "ForEachItem" or name == "ForEachWetableItem"
        or name == "ForEachEquipment" or name == "ForEachItemSlot" then
        return nil
    end
    return INVENTORY_FALSE_METHODS[name] and false or nil
end

local BUILDER_METHODS =
{
    "IsBuildBuffered",
    "GetTechBonuses",
    "GetTempTechBonuses",
    "EvaluateTechTrees",
    "GetIngredients",
    "CheckIngredientsForMimic",
    "CheckDiscountEquipsForMimic",
    "HasCharacterIngredient",
    "HasTechIngredient",
    "KnowsRecipe",
    "HasIngredients",
    "CanBuild",
    "CanLearn",
    "ActivateCurrentResearchMachine",
    "GiveAllRecipes",
    "UnlockRecipesForTech",
    "GiveTempTechBonus",
    "ConsumeTempTechBonuses",
    "UsePrototyper",
    "AddRecipe",
    "RemoveRecipe",
    "UnlockRecipe",
    "RemoveIngredients",
    "MakeRecipe",
    "DoBuild",
    "MakeRecipeFromMenu",
    "MakeRecipeAtPoint",
    "SetBuildBuffered",
    "BufferBuild",
}

local function GetBlockedBuilderResult(name)
    if name == "GetTechBonuses" or name == "GetTempTechBonuses"
        or name == "GetIngredients" then
        return {}
    end
    return false
end

local CONTAINER_METHODS =
{
    "SetNumSlots",
    "DropItemBySlot",
    "DropEverythingWithTag",
    "DropEverythingByFilter",
    "DropEverything",
    "DropEverythingUpToMaxStacks",
    "DropItem",
    "DropOverstackedExcess",
    "DropItemAt",
    "CanTakeItemInSlot",
    "DestroyContents",
    "DestroyContentsConditionally",
    "CanAcceptCount",
    "GiveItem",
    "RemoveItemBySlot",
    "RemoveAllItems",
    "Open",
    "PutOneOfActiveItemInSlot",
    "PutAllOfActiveItemInSlot",
    "TakeActiveItemFromHalfOfSlot",
    "TakeActiveItemFromCountOfSlot",
    "TakeActiveItemFromAllOfSlot",
    "AddOneOfActiveItemToSlot",
    "AddAllOfActiveItemToSlot",
    "SwapActiveItemWithSlot",
    "SwapOneOfActiveItemWithSlot",
    "MoveItemFromAllOfSlot",
    "MoveItemFromHalfOfSlot",
    "MoveItemFromCountOfSlot",
    "ConsumeByName",
    "RemoveItem",
    "RemoveItem_Internal",
    "EnableInfiniteStackSize",
    "EnableReadOnlyContainer",
}

local function IsSpectatorContainer(container, ...)
    if not IsTable(container) then
        return false
    end
    return IsOwnedBySpectator(container.inst)
        or IsSpectator(container.currentuser)
        or IsSpectator(container.opener)
        or HasSpectatorArgument(...)
end

function Guard.InstallInventoryItem(component)
    if component == nil then
        return
    end
    InstallComponentMethod(
        component,
        "OnPutInInventory",
        false,
        function(self, owner)
            return IsOwnedBySpectator(owner) and not IsGuardCleanupOwner(owner)
        end
    )
    InstallComponentMethod(
        component,
        "OnRemoved",
        false,
        function(self)
            local owner = GetGrandOwner(self.inst)
            return IsSpectator(owner) and not IsGuardCleanupOwner(owner)
        end
    )
    InstallComponentMethod(
        component,
        "OnDropped",
        false,
        function(self)
            local owner = GetGrandOwner(self.inst)
            return IsSpectator(owner) and not IsGuardCleanupOwner(owner)
        end
    )
    InstallComponentMethod(
        component,
        "OnPickup",
        true,
        function(self, pickupguy)
            return (IsSpectator(pickupguy) and not IsGuardCleanupOwner(pickupguy))
                or (IsOwnedBySpectator(self.inst)
                    and not IsGuardCleanupOwner(GetGrandOwner(self.inst)))
        end
    )
    InstallComponentMethod(
        component,
        "RemoveFromOwner",
        false,
        function(self)
            local owner = GetGrandOwner(self.inst)
            return IsSpectator(owner) and not IsGuardCleanupOwner(owner)
        end
    )
end

function Guard.InstallEquippable(component)
    if component == nil then
        return
    end
    InstallComponentMethod(
        component,
        "Equip",
        false,
        function(self, owner)
            return (IsSpectator(owner) or IsOwnedBySpectator(self.inst))
                and not IsGuardCleanupOwner(owner)
                and not IsGuardCleanupOwner(GetGrandOwner(self.inst))
        end
    )
    InstallComponentMethod(
        component,
        "ToPocket",
        false,
        function(self, owner)
            return (IsSpectator(owner) or IsOwnedBySpectator(self.inst))
                and not IsGuardCleanupOwner(owner)
                and not IsGuardCleanupOwner(GetGrandOwner(self.inst))
        end
    )
    InstallComponentMethod(
        component,
        "Unequip",
        false,
        function(self, owner)
            return (IsSpectator(owner) or IsOwnedBySpectator(self.inst))
                and not IsGuardCleanupOwner(owner)
                and not IsGuardCleanupOwner(GetGrandOwner(self.inst))
        end
    )
    InstallComponentMethod(
        component,
        "IsEquipped",
        false,
        function(self)
            return IsOwnedBySpectator(self.inst)
        end
    )
    InstallComponentMethod(
        component,
        "IsInsulated",
        false,
        function(self)
            return IsOwnedBySpectator(self.inst)
        end
    )
    InstallComponentMethod(
        component,
        "GetWalkSpeedMult",
        1,
        function(self)
            return IsOwnedBySpectator(self.inst)
        end
    )
    InstallComponentMethod(
        component,
        "GetDapperness",
        0,
        function(self, owner)
            return IsSpectator(owner) or IsOwnedBySpectator(self.inst)
        end
    )
    InstallComponentMethod(
        component,
        "GetEquippedMoisture",
        function()
            return { moisture = 0, max = 0 }
        end,
        function(self)
            return IsOwnedBySpectator(self.inst)
        end
    )
    InstallComponentMethod(
        component,
        "ShouldPreventUnequipping",
        false,
        function(self)
            return IsOwnedBySpectator(self.inst)
        end
    )
    InstallComponentMethod(
        component,
        "SetPreventUnequipping",
        false,
        function(self)
            return IsOwnedBySpectator(self.inst)
        end
    )
end

function Guard.InstallContainer(component)
    if component == nil then
        return
    end
    for index = 1, #CONTAINER_METHODS do
        local name = CONTAINER_METHODS[index]
        if name ~= "Open" then
            InstallComponentMethod(
                component,
                name,
                false,
                IsSpectatorContainer
            )
        end
    end
    InstallComponentMethod(
        component,
        "Open",
        false,
        IsSpectatorContainer
    )
    InstallComponentMethod(
        component,
        "IsOpenedBy",
        false,
        IsSpectatorContainer
    )
    InstallComponentMethod(
        component,
        "IsOpenedByOthers",
        false,
        IsSpectatorContainer
    )
    InstallComponentMethod(
        component,
        "CanOpen",
        false,
        IsSpectatorContainer
    )
end

local function IsSpectatorInventory(self)
    return self ~= nil and IsSpectator(self.inst)
end

local function InstallPlayerInventoryMethods(state, inventory)
    state.methods = state.methods
        or CaptureStableMethods(inventory, state.method_names)
    for index = 1, #state.method_names do
        local name = state.method_names[index]
        local original = state.methods.original[name]
        if type(original) == "function" then
            rawset(inventory, name, function(self, ...)
                if IsSpectatorInventory(self)
                    and not IsGuardCleanup(self.inst) then
                    return GetBlockedInventoryResult(name)
                end
                return original(self, ...)
            end)
        end
    end

    local original_on_save = state.methods.original.OnSave
    if type(original_on_save) == "function"
        and state.save_captured then
        rawset(inventory, "OnSave", function(self, ...)
            if IsSpectatorInventory(self)
                and not IsGuardCleanup(self.inst) then
                return state.save_data, state.save_references
            end
            return original_on_save(self, ...)
        end)
    end
end

local function InstallPlayerBuilderMethods(state, builder)
    state.builder_methods = state.builder_methods
        or CaptureStableMethods(builder, BUILDER_METHODS)
    for index = 1, #BUILDER_METHODS do
        local name = BUILDER_METHODS[index]
        local original = state.builder_methods.original[name]
        if type(original) == "function" then
            rawset(builder, name, function(self, ...)
                if self ~= nil and IsSpectator(self.inst)
                    and not IsGuardCleanup(self.inst) then
                    return GetBlockedBuilderResult(name)
                end
                return original(self, ...)
            end)
        end
    end
end

local function GetInventoryComponent(player)
    local components = GetComponents(player)
    return components ~= nil and components.inventory or nil
end

function Guard.Capture(player)
    if not Util.IsValidPlayer(player) then
        return nil, Guard.ERROR_CODES.PLAYER_INVALID
    end

    local synthetic = Util.IsSyntheticPlayer(player)
    local inventory = GetInventoryComponent(player)
    if inventory == nil and not synthetic then
        return { available = false }, nil
    end

    local method_names = {}
    for index = 1, #INVENTORY_METHODS do
        method_names[index] = INVENTORY_METHODS[index]
    end
    table.insert(method_names, "OnSave")

    local components = GetComponents(player)
    local builder = components ~= nil and components.builder or nil
    local methods = CaptureStableMethods(inventory, method_names)
    local builder_methods = CaptureStableMethods(builder, BUILDER_METHODS)

    local data, capture_code = InventoryAdapter.Capture(player)
    if data == nil then
        return nil, capture_code or Guard.ERROR_CODES.CAPTURE_FAILED
    end

    local state =
    {
        available = true,
        synthetic = synthetic,
        data = data,
        applied = false,
        restored = false,
        inventory = inventory,
        isopen = inventory ~= nil and inventory.isopen or false,
        isvisible = inventory ~= nil and inventory.isvisible or false,
        method_names = method_names,
        methods = methods,
        builder = builder,
        builder_methods = builder_methods,
        save_captured = false,
        save_data = nil,
        save_references = nil,
    }

    local original_on_save = methods.original.OnSave
    if inventory ~= nil and type(original_on_save) == "function" then
        local ok, save_data, save_references = pcall(
            original_on_save,
            inventory
        )
        if not ok then
            return nil, Guard.ERROR_CODES.SAVE_CAPTURE_FAILED
        end
        state.save_captured = true
        state.save_data = save_data
        state.save_references = save_references
    end
    return state
end

function Guard.Apply(player, state)
    if not IsTable(state) or state.available ~= true then
        return true
    end
    if state.applied then
        return true
    end
    state.applied = true
    RegisterGuardItems(state.data, player)

    local cleaned, clean_code = true, nil
    if not state.synthetic then
        local cleanup_before = player._agon_spectator_guard_cleanup
        player._agon_spectator_guard_cleanup = true
        cleaned, clean_code = InventoryAdapter.EnterCleanState(player)
        player._agon_spectator_guard_cleanup = cleanup_before
    end
    if not cleaned then
        state.applied = true
        return false, clean_code or Guard.ERROR_CODES.CLEAN_FAILED
    end

    local inventory = GetInventoryComponent(player)
    if inventory ~= nil then
        inventory.isopen = false
        inventory.isvisible = false
        InstallPlayerInventoryMethods(state, inventory)
    end
    if state.builder ~= nil then
        InstallPlayerBuilderMethods(state, state.builder)
    end
    return true
end

local function RestoreLiveInventory(player, state)
    local inventory = GetInventoryComponent(player)
    if inventory == nil then
        return false, Guard.ERROR_CODES.RESTORE_FAILED
    end
    local old_spectator = player.is_spectator
    local old_cleanup = player._agon_spectator_guard_cleanup
    player.is_spectator = nil
    player._agon_spectator_guard_cleanup = true
    local ok, code = InventoryAdapter.Restore(player, state.data)
    player._agon_spectator_guard_cleanup = old_cleanup
    player.is_spectator = old_spectator
    if not ok then
        return false, code or Guard.ERROR_CODES.RESTORE_FAILED
    end
    inventory.isopen = state.isopen
    inventory.isvisible = state.isvisible
    return true
end

function Guard.Restore(player, state)
    if not IsTable(state) or state.available ~= true then
        return true
    end
    if not state.applied or state.restored then
        return true
    end
    local ok, code
    if state.synthetic then
        local old_spectator = player.is_spectator
        player.is_spectator = nil
        ok, code = InventoryAdapter.Restore(player, state.data)
        player.is_spectator = old_spectator
    else
        ok, code = RestoreLiveInventory(player, state)
    end
    state.restored = ok == true
    if state.restored then
        UnregisterGuardItems(state.data, player)
    end
    return ok, code
end

local function RemoveUnexpectedEquippedItems(player, state, inventory)
    local original_unequip = state.methods ~= nil
        and state.methods.original ~= nil
        and state.methods.original.Unequip
        or nil
    local success = true
    for slot, item in pairs(inventory.equipslots or {}) do
        if item ~= nil then
            local cleanup_before = player._agon_spectator_guard_cleanup
            player._agon_spectator_guard_cleanup = true
            local removed = original_unequip ~= nil
                and pcall(original_unequip, inventory, slot, nil, true)
                or false
            player._agon_spectator_guard_cleanup = cleanup_before
            if not removed or inventory.equipslots[slot] ~= nil then
                -- 官方 Unequip 可能拒绝处理被绕过的物品，不能手工清空槽位，
                -- 以免留下孤立物品；Equippable 的观战 hook 会继续中和效果。
                success = false
            end
        end
    end
    return success
end

function Guard.Maintain(player, state)
    if not IsTable(state) or state.available ~= true then
        return true
    end
    if not IsSpectator(player) then
        return false
    end
    local inventory = GetInventoryComponent(player)
    if inventory == nil then
        return true
    end

    inventory.isopen = false
    inventory.isvisible = false
    local clean = RemoveUnexpectedEquippedItems(player, state, inventory)

    if inventory.activeitem ~= nil then
        local active = inventory.activeitem
        local original_set_active = state.methods ~= nil
            and state.methods.original ~= nil
            and state.methods.original.SetActiveItem
            or nil
        if original_set_active ~= nil then
            local cleanup_before = player._agon_spectator_guard_cleanup
            player._agon_spectator_guard_cleanup = true
            local ok = pcall(original_set_active, inventory, nil)
            if active.components ~= nil and active.components.inventoryitem ~= nil
                and type(active.components.inventoryitem.OnRemoved) == "function" then
                pcall(active.components.inventoryitem.OnRemoved, active.components.inventoryitem)
            end
            player._agon_spectator_guard_cleanup = cleanup_before
            clean = ok and clean
        else
            -- 官方 setter 不存在时不手工清空 active item，避免留下孤立物品；
            -- guard 生效期间 Inventory 入口仍保持阻断。
            clean = false
        end
    end
    return clean
end

function Guard.Validate(player, state)
    if not IsTable(state) or state.available ~= true then
        return true
    end
    return IsSpectator(player) and state.applied == true
end

return Guard
