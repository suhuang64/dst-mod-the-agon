-- WP7：默认角色适配器，保存角色资源、召唤关系、临时组件和外观策略。

local Util = require("agon/player/adapters/util")

local CharacterAdapter = {}
CharacterAdapter.adapter_id = "character:default"
CharacterAdapter.version = 1
CharacterAdapter.order = 40
CharacterAdapter.dependencies = { "skilltree" }
CharacterAdapter.character_prefab = "*"

CharacterAdapter.ERROR_CODES =
{
    PLAYER_INVALID = "CHARACTER_PLAYER_INVALID",
    PREFAB_MISSING = "CHARACTER_PREFAB_MISSING",
    STATE_UNSUPPORTED = "CHARACTER_LIVE_STATE_UNSUPPORTED",
    SNAPSHOT_INVALID = "CHARACTER_SNAPSHOT_INVALID",
    CLEAN_FAILED = "CHARACTER_CLEAN_FAILED",
    APPLY_FAILED = "CHARACTER_APPLY_FAILED",
    RESTORE_MISMATCH = "CHARACTER_RESTORE_MISMATCH",
}

local function MakeDefaultState(player)
    local prefab = Util.GetCharacterPrefab(player) or "unknown"
    return
    {
        prefab = prefab,
        appearance = {},
        resources = {},
        followers = {},
        pets = {},
        summoned = {},
        components = {},
        abilities = {},
        movement_speed = 1,
    }
end

local function ValidateState(data)
    return type(data) == "table"
        and type(data.prefab) == "string"
        and data.prefab ~= ""
        and type(data.appearance) == "table"
        and type(data.resources) == "table"
        and type(data.followers) == "table"
        and type(data.pets) == "table"
        and type(data.summoned) == "table"
        and type(data.components) == "table"
        and type(data.abilities) == "table"
        and (data.movement_speed == nil or type(data.movement_speed) == "number")
end

local function CaptureSynthetic(player)
    local state = Util.GetTestState(player)
    if state == nil then
        return nil, CharacterAdapter.ERROR_CODES.PLAYER_INVALID
    end
    state.character = state.character or MakeDefaultState(player)
    local data = Util.CopyData(state.character)
    data.prefab = data.prefab or Util.GetCharacterPrefab(player)
    data.appearance = data.appearance or {}
    data.resources = data.resources or {}
    data.followers = data.followers or {}
    data.pets = data.pets or {}
    data.summoned = data.summoned or {}
    data.components = data.components or {}
    data.abilities = data.abilities or {}
    if not ValidateState(data) then
        return nil, CharacterAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

local function CaptureLive(player)
    local prefab = Util.GetCharacterPrefab(player)
    if prefab == nil then
        return nil, CharacterAdapter.ERROR_CODES.PREFAB_MISSING
    end
    -- 角色特有资源必须由角色自己提供纯数据快照；未知组件不能猜测恢复方式。
    if type(player.agon_sandbox_character_state) ~= "table" then
        return nil, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
    end
    local data = Util.CopyData(player.agon_sandbox_character_state)
    data.prefab = data.prefab or prefab
    data.appearance = data.appearance or {}
    data.resources = data.resources or {}
    data.followers = data.followers or {}
    data.pets = data.pets or {}
    data.summoned = data.summoned or {}
    data.components = data.components or {}
    data.abilities = data.abilities or {}
    data.movement_speed = data.movement_speed or 1
    if not ValidateState(data) then
        return nil, CharacterAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

function CharacterAdapter.Capture(player)
    if not Util.IsValidPlayer(player) then
        return nil, CharacterAdapter.ERROR_CODES.PLAYER_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        return CaptureSynthetic(player)
    end
    return CaptureLive(player)
end

function CharacterAdapter.ValidateCapture(player, data)
    if not Util.IsValidPlayer(player) or not ValidateState(data) then
        return false, CharacterAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return true
end

function CharacterAdapter.EnterCleanState(player)
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local old = state.character or MakeDefaultState(player)
        state.character =
        {
            prefab = old.prefab,
            appearance = Util.CopyData(old.appearance or {}),
            resources = {},
            followers = {},
            pets = {},
            summoned = {},
            components = {},
            abilities = {},
            movement_speed = old.movement_speed,
        }
        return true
    end
    if type(player.agon_sandbox_character_state) ~= "table" then
        return false, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
    end
    player.agon_sandbox_character_state.resources = {}
    player.agon_sandbox_character_state.followers = {}
    player.agon_sandbox_character_state.pets = {}
    player.agon_sandbox_character_state.summoned = {}
    player.agon_sandbox_character_state.components = {}
    player.agon_sandbox_character_state.abilities = {}
    return true
end

function CharacterAdapter.ApplyOverrides(player, context, sandbox)
    context = context or {}
    if context.character_profile_applied then
        return true
    end
    local profile = sandbox ~= nil and sandbox.profile or context.profile
    if profile == nil then
        return false, CharacterAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local character = state.character or MakeDefaultState(player)
        character.abilities =
        {
            allowed = Util.CopyData(profile.allowed_abilities or {}),
            disabled = Util.CopyData(profile.disabled_abilities or {}),
        }
        character.components = Util.CopyData(profile.temporary_components or {})
        if profile.movement_speed ~= nil then
            state.movement_speed = profile.movement_speed
            character.movement_speed = profile.movement_speed
        end
        if profile.appearance_policy == "REPLACE" then
            character.appearance = Util.CopyData(profile.appearance or {})
        end
        state.character = character
        context.character_profile_applied = true
        return true
    end
    if profile.movement_speed ~= nil
        or #(profile.allowed_abilities or {}) > 0
        or #(profile.disabled_abilities or {}) > 0
        or #(profile.temporary_components or {}) > 0
        or profile.appearance_policy == "REPLACE" then
        return false, CharacterAdapter.ERROR_CODES.APPLY_FAILED
    end
    context.character_profile_applied = true
    return true
end

function CharacterAdapter.RemoveOverrides(player, context)
    context = context or {}
    if context.character_overrides_removed then
        return true
    end
    local cleaned, code = CharacterAdapter.EnterCleanState(player)
    if cleaned then
        context.character_overrides_removed = true
    end
    return cleaned, code
end

function CharacterAdapter.Restore(player, data)
    if not ValidateState(data) then
        return false, CharacterAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        state.character = Util.CopyData(data)
        state.movement_speed = data.movement_speed
        return true
    end
    if type(player.agon_sandbox_character_state) ~= "table" then
        return false, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
    end
    player.agon_sandbox_character_state = Util.CopyData(data)
    return true
end

function CharacterAdapter.ValidateRestore(player, data)
    if not ValidateState(data) then
        return false, CharacterAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    local actual
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        actual = state ~= nil and state.character or nil
    else
        actual = player.agon_sandbox_character_state
    end
    local equal = Util.DeepEqual(actual, data)
    return equal, equal and nil or CharacterAdapter.ERROR_CODES.RESTORE_MISMATCH
end

return CharacterAdapter
