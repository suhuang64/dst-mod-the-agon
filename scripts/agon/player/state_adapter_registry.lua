-- WP7：统一编排玩家状态适配器，保证 Capture/清理/恢复使用同一组适配器。

local InventoryAdapter = require("agon/player/adapters/inventory")
local SurvivalStatsAdapter = require("agon/player/adapters/survival_stats")
local SkillTreeAdapter = require("agon/player/adapters/skilltree")
local DefaultCharacterAdapter = require("agon/player/adapters/characters/default")

local StateAdapterRegistry = {}
StateAdapterRegistry.SCHEMA_VERSION = 1

StateAdapterRegistry.ERROR_CODES =
{
    INVALID_REGISTRY = "INVALID_PLAYER_ADAPTER_REGISTRY",
    INVALID_ADAPTER = "INVALID_PLAYER_STATE_ADAPTER",
    DUPLICATE_ADAPTER = "DUPLICATE_PLAYER_STATE_ADAPTER",
    UNKNOWN_ADAPTER = "UNKNOWN_PLAYER_STATE_ADAPTER",
    INVALID_CHARACTER = "INVALID_PLAYER_CHARACTER_ADAPTER",
    CAPTURE_FAILED = "PLAYER_STATE_ADAPTER_CAPTURE_FAILED",
    VALIDATE_CAPTURE_FAILED = "PLAYER_STATE_ADAPTER_CAPTURE_VALIDATION_FAILED",
    CLEAN_FAILED = "PLAYER_STATE_ADAPTER_CLEAN_FAILED",
    APPLY_FAILED = "PLAYER_STATE_ADAPTER_APPLY_FAILED",
    REMOVE_FAILED = "PLAYER_STATE_ADAPTER_REMOVE_FAILED",
    RESTORE_FAILED = "PLAYER_STATE_ADAPTER_RESTORE_FAILED",
    VALIDATE_RESTORE_FAILED = "PLAYER_STATE_ADAPTER_RESTORE_VALIDATION_FAILED",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= 1
end

local DEFAULT_CHARACTER_PREFABS =
{
    "wilson",
    "willow",
    "wolfgang",
    "wendy",
    "wx78",
    "wickerbottom",
    "woodie",
    "wes",
    "waxwell",
    "wathgrithr",
    "webber",
    "winona",
    "warly",
    "wortox",
    "wormwood",
    "wurt",
    "walter",
    "wanda",
    "wonkey",
}

local REQUIRED_METHODS =
{
    "Capture",
    "ValidateCapture",
    "EnterCleanState",
    "ApplyOverrides",
    "RemoveOverrides",
    "Restore",
    "ValidateRestore",
}

local function ValidateAdapter(adapter)
    if type(adapter) ~= "table"
        or not IsNonEmptyString(adapter.adapter_id)
        or not IsPositiveInteger(adapter.version) then
        return false, StateAdapterRegistry.ERROR_CODES.INVALID_ADAPTER
    end
    for index = 1, #REQUIRED_METHODS do
        if type(adapter[REQUIRED_METHODS[index]]) ~= "function" then
            return false, StateAdapterRegistry.ERROR_CODES.INVALID_ADAPTER
        end
    end
    if adapter.order ~= nil
        and (type(adapter.order) ~= "number" or adapter.order ~= math.floor(adapter.order)) then
        return false, StateAdapterRegistry.ERROR_CODES.INVALID_ADAPTER
    end
    if adapter.dependencies ~= nil and type(adapter.dependencies) ~= "table" then
        return false, StateAdapterRegistry.ERROR_CODES.INVALID_ADAPTER
    end
    return true
end

local function InsertSorted(order, adapter_id, adapters)
    local adapter = adapters[adapter_id]
    local inserted = false
    for index = 1, #order do
        local current = adapters[order[index]]
        if (adapter.order or 1000) < (current.order or 1000) then
            table.insert(order, index, adapter_id)
            inserted = true
            break
        end
    end
    if not inserted then
        table.insert(order, adapter_id)
    end
end

local function GetCharacterPrefab(player)
    if type(player) ~= "table" then
        return nil
    end
    if type(player.prefab) == "string" and player.prefab ~= "" then
        return player.prefab
    end
    if type(player.agon_sandbox_state) == "table"
        and type(player.agon_sandbox_state.character) == "table" then
        return player.agon_sandbox_state.character.prefab
    end
    return nil
end

function StateAdapterRegistry.ValidateAdapter(adapter)
    return ValidateAdapter(adapter)
end

function StateAdapterRegistry.Register(self, adapter)
    local valid, code = ValidateAdapter(adapter)
    if not valid then
        return false, code
    end
    if self.adapters_by_id[adapter.adapter_id] ~= nil then
        return false, StateAdapterRegistry.ERROR_CODES.DUPLICATE_ADAPTER
    end
    self.adapters_by_id[adapter.adapter_id] = adapter
    InsertSorted(self.adapter_order, adapter.adapter_id, self.adapters_by_id)
    return true
end

function StateAdapterRegistry.RegisterCharacter(self, character_prefab, adapter)
    if not IsNonEmptyString(character_prefab) then
        return false, StateAdapterRegistry.ERROR_CODES.INVALID_CHARACTER
    end
    local valid, code = ValidateAdapter(adapter)
    if not valid then
        return false, code
    end
    if self.adapters_by_id[adapter.adapter_id] == nil then
        local registered, register_code = self:Register(adapter)
        if not registered then
            return false, register_code
        end
    end
    self.character_adapters[character_prefab] = adapter.adapter_id
    return true
end

function StateAdapterRegistry.Get(self, adapter_id)
    return IsNonEmptyString(adapter_id) and self.adapters_by_id[adapter_id] or nil
end

function StateAdapterRegistry.GetAdapters(self, player, context)
    context = type(context) == "table" and context or {}
    local adapters = {}
    if type(context.adapter_ids) == "table" then
        for index = 1, #context.adapter_ids do
            local adapter = self:Get(context.adapter_ids[index])
            if adapter == nil then
                return nil, StateAdapterRegistry.ERROR_CODES.UNKNOWN_ADAPTER
            end
            table.insert(adapters, adapter)
        end
        return adapters
    end

    for index = 1, #self.adapter_order do
        local adapter_id = self.adapter_order[index]
        if string.sub(adapter_id, 1, 10) ~= "character:" then
            table.insert(adapters, self.adapters_by_id[adapter_id])
        end
    end
    local character_prefab = GetCharacterPrefab(player)
    local character_id = character_prefab ~= nil
        and self.character_adapters[character_prefab]
        or nil
    if character_id == nil then
        return nil, StateAdapterRegistry.ERROR_CODES.INVALID_CHARACTER
    end
    local character_adapter = self:Get(character_id)
    if character_adapter == nil then
        return nil, StateAdapterRegistry.ERROR_CODES.UNKNOWN_ADAPTER
    end
    table.insert(adapters, character_adapter)
    return adapters
end

local function CallAdapter(adapter, method, ...)
    local ok, result, code = pcall(adapter[method], ...)
    if not ok then
        return false, StateAdapterRegistry.ERROR_CODES.INVALID_ADAPTER, tostring(result)
    end
    if result == false or result == nil then
        return false, code or StateAdapterRegistry.ERROR_CODES.INVALID_ADAPTER
    end
    return true, code
end

function StateAdapterRegistry.Capture(self, player, snapshot, context)
    if type(snapshot) ~= "table" then
        return false, StateAdapterRegistry.ERROR_CODES.CAPTURE_FAILED
    end
    snapshot.adapters = snapshot.adapters or {}
    local adapters, adapters_code = self:GetAdapters(player, context)
    if adapters == nil then
        return false, adapters_code
    end
    context = type(context) == "table" and context or {}
    context.adapter_ids = {}
    for index = 1, #adapters do
        local adapter = adapters[index]
        table.insert(context.adapter_ids, adapter.adapter_id)
        local ok, data, code = pcall(adapter.Capture, player, context)
        if not ok or data == nil then
            return false, code or StateAdapterRegistry.ERROR_CODES.CAPTURE_FAILED,
                adapter.adapter_id
        end
        snapshot.adapters[adapter.adapter_id] = data
    end
    return true
end

function StateAdapterRegistry.ValidateCapture(self, player, snapshot, context)
    if type(snapshot) ~= "table" or type(snapshot.adapters) ~= "table" then
        return false, StateAdapterRegistry.ERROR_CODES.VALIDATE_CAPTURE_FAILED
    end
    local adapters, adapters_code = self:GetAdapters(player, context)
    if adapters == nil then
        return false, adapters_code
    end
    for index = 1, #adapters do
        local adapter = adapters[index]
        local data = snapshot.adapters[adapter.adapter_id]
        local ok, valid, code = pcall(adapter.ValidateCapture, player, data, context)
        if not ok or valid ~= true then
            return false, code or StateAdapterRegistry.ERROR_CODES.VALIDATE_CAPTURE_FAILED,
                adapter.adapter_id
        end
    end
    return true
end

local function RunForward(self, method, player, context, failure_code)
    local adapters, adapters_code = self:GetAdapters(player, context)
    if adapters == nil then
        return false, adapters_code
    end
    for index = 1, #adapters do
        local adapter = adapters[index]
        local ok, code = CallAdapter(adapter, method, player, context, context.sandbox)
        if not ok then
            return false, code or failure_code, adapter.adapter_id
        end
    end
    return true
end

local function RunReverse(self, method, player, context, failure_code)
    local adapters, adapters_code = self:GetAdapters(player, context)
    if adapters == nil then
        return false, adapters_code
    end
    for index = #adapters, 1, -1 do
        local adapter = adapters[index]
        local ok, code = CallAdapter(adapter, method, player, context, context.sandbox)
        if not ok then
            return false, code or failure_code, adapter.adapter_id
        end
    end
    return true
end

function StateAdapterRegistry.EnterCleanState(self, player, context)
    return RunForward(
        self,
        "EnterCleanState",
        player,
        context,
        StateAdapterRegistry.ERROR_CODES.CLEAN_FAILED
    )
end

function StateAdapterRegistry.ApplyOverrides(self, player, context)
    return RunForward(
        self,
        "ApplyOverrides",
        player,
        context,
        StateAdapterRegistry.ERROR_CODES.APPLY_FAILED
    )
end

function StateAdapterRegistry.RemoveOverrides(self, player, context)
    return RunReverse(
        self,
        "RemoveOverrides",
        player,
        context,
        StateAdapterRegistry.ERROR_CODES.REMOVE_FAILED
    )
end

function StateAdapterRegistry.Restore(self, player, snapshot, context)
    local adapters, adapters_code = self:GetAdapters(player, context)
    if adapters == nil then
        return false, adapters_code
    end
    for index = #adapters, 1, -1 do
        local adapter = adapters[index]
        local ok, result, code = pcall(
            adapter.Restore,
            player,
            snapshot.adapters[adapter.adapter_id],
            context,
            context.sandbox
        )
        if not ok or result ~= true then
            return false, code or StateAdapterRegistry.ERROR_CODES.RESTORE_FAILED,
                adapter.adapter_id
        end
    end
    return true
end

function StateAdapterRegistry.ValidateRestore(self, player, snapshot, context)
    local adapters, adapters_code = self:GetAdapters(player, context)
    if adapters == nil then
        return false, adapters_code
    end
    for index = #adapters, 1, -1 do
        local adapter = adapters[index]
        local ok, valid, code = pcall(
            adapter.ValidateRestore,
            player,
            snapshot.adapters[adapter.adapter_id],
            context
        )
        if not ok or valid ~= true then
            return false, code or StateAdapterRegistry.ERROR_CODES.VALIDATE_RESTORE_FAILED,
                adapter.adapter_id
        end
    end
    return true
end

function StateAdapterRegistry.GetSnapshot(self)
    local adapters = {}
    for index = 1, #self.adapter_order do
        local adapter = self.adapters_by_id[self.adapter_order[index]]
        table.insert(
            adapters,
            {
                adapter_id = adapter.adapter_id,
                version = adapter.version,
                character_prefab = adapter.character_prefab,
            }
        )
    end
    local character_adapters = {}
    for character_prefab, adapter_id in pairs(self.character_adapters) do
        character_adapters[character_prefab] = adapter_id
    end
    return
    {
        schema_version = self.schema_version,
        adapters = adapters,
        character_adapters = character_adapters,
    }
end

function StateAdapterRegistry.Validate(self)
    for index = 1, #self.adapter_order do
        local adapter = self.adapters_by_id[self.adapter_order[index]]
        local valid, code = ValidateAdapter(adapter)
        if not valid then
            return false, code
        end
        for dependency_index = 1, #(adapter.dependencies or {}) do
            if self:Get(adapter.dependencies[dependency_index]) == nil then
                return false, StateAdapterRegistry.ERROR_CODES.UNKNOWN_ADAPTER
            end
        end
    end
    local character_count = 0
    for character_prefab, adapter_id in pairs(self.character_adapters) do
        if not IsNonEmptyString(character_prefab)
            or self:Get(adapter_id) == nil then
            return false, StateAdapterRegistry.ERROR_CODES.INVALID_CHARACTER
        end
        character_count = character_count + 1
    end
    if character_count == 0 then
        return false, StateAdapterRegistry.ERROR_CODES.INVALID_CHARACTER
    end
    return true
end

function StateAdapterRegistry.GetDebugString(self)
    return string.format(
        "player_adapter_registry adapters=%d characters=%d",
        #self.adapter_order,
        (function()
            local count = 0
            for _ in pairs(self.character_adapters) do
                count = count + 1
            end
            return count
        end)()
    )
end

local function AttachMethods(registry)
    registry.Register = StateAdapterRegistry.Register
    registry.RegisterCharacter = StateAdapterRegistry.RegisterCharacter
    registry.Get = StateAdapterRegistry.Get
    registry.GetAdapters = StateAdapterRegistry.GetAdapters
    registry.Capture = StateAdapterRegistry.Capture
    registry.ValidateCapture = StateAdapterRegistry.ValidateCapture
    registry.EnterCleanState = StateAdapterRegistry.EnterCleanState
    registry.ApplyOverrides = StateAdapterRegistry.ApplyOverrides
    registry.RemoveOverrides = StateAdapterRegistry.RemoveOverrides
    registry.Restore = StateAdapterRegistry.Restore
    registry.ValidateRestore = StateAdapterRegistry.ValidateRestore
    registry.GetSnapshot = StateAdapterRegistry.GetSnapshot
    registry.Validate = StateAdapterRegistry.Validate
    registry.GetDebugString = StateAdapterRegistry.GetDebugString
    return registry
end

function StateAdapterRegistry.New(options)
    options = type(options) == "table" and options or {}
    local registry = AttachMethods(
    {
        schema_version = StateAdapterRegistry.SCHEMA_VERSION,
        adapters_by_id = {},
        adapter_order = {},
        character_adapters = {},
    })
    local builtins =
    {
        InventoryAdapter,
        SurvivalStatsAdapter,
        SkillTreeAdapter,
        DefaultCharacterAdapter,
    }
    for index = 1, #builtins do
        local registered, code = registry:Register(builtins[index])
        if not registered then
            return nil, code
        end
    end
    local default_characters = type(DST_CHARACTERLIST) == "table"
        and DST_CHARACTERLIST
        or DEFAULT_CHARACTER_PREFABS
    local registered_characters = {}
    for index = 1, #default_characters do
        local character_prefab = default_characters[index]
        if not registered_characters[character_prefab] then
            local character_registered, character_code = registry:RegisterCharacter(
                character_prefab,
                DefaultCharacterAdapter
            )
            if not character_registered then
                return nil, character_code
            end
            registered_characters[character_prefab] = true
        end
    end
    for index = 1, #(options.adapters or {}) do
        local registered, code = registry:Register(options.adapters[index])
        if not registered then
            return nil, code
        end
    end
    if type(options.character_adapters) == "table" then
        for character_prefab, adapter_id in pairs(options.character_adapters) do
            local adapter = registry:Get(adapter_id)
            if adapter == nil then
                return nil, StateAdapterRegistry.ERROR_CODES.UNKNOWN_ADAPTER
            end
            local registered, code = registry:RegisterCharacter(
                character_prefab,
                adapter
            )
            if not registered then
                return nil, code
            end
        end
    end
    return registry
end

return StateAdapterRegistry
