-- WP7：默认角色适配器，保存角色资源、召唤关系、临时组件和外观策略。

local Util = require("agon/player/adapters/util")

local CharacterAdapter = {}
CharacterAdapter.adapter_id = "character:default"
CharacterAdapter.version = 1
CharacterAdapter.order = 40
CharacterAdapter.dependencies = { "skilltree" }
CharacterAdapter.character_prefab = "*"

-- 真实玩家只在有明确官方组件读写契约的角色上启用适配。
-- 未覆盖的角色继续拒绝进入，不能用空表伪造“已保存”。
local LIVE_SUPPORTED_PREFABS =
{
    wilson = true,
    wathgrithr = true,
}

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

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value
end

local function HasEntries(value)
    return type(value) == "table" and next(value) ~= nil
end

local function CopyOfficialSave(component)
    if type(component) ~= "table" or type(component.OnSave) ~= "function" then
        return nil
    end
    local ok, saved = pcall(component.OnSave, component)
    if not ok or type(saved) ~= "table" then
        return nil
    end
    local copied = Util.CopyPureData(saved)
    return type(copied) == "table" and copied or nil
end

local function HasUnsupportedRelationships(components)
    local leader = components.leader
    if leader ~= nil
        and (HasEntries(leader.followers) or HasEntries(leader.itemfollowers)) then
        return true
    end

    local petleash = components.petleash
    if petleash ~= nil
        and (HasEntries(petleash.pets) or petleash.pet ~= nil) then
        return true
    end

    local ghostlybond = components.ghostlybond
    if ghostlybond ~= nil and ghostlybond.ghost ~= nil then
        return true
    end

    return false
end

local function ValidateLiveResources(prefab, resources)
    if type(resources) ~= "table" then
        return false
    end

    if prefab == "wilson" then
        local beard = resources.beard
        return type(beard) == "table"
            and (beard.growth == nil or IsFiniteNumber(beard.growth))
            and (beard.growthaccumulator == nil
                or IsFiniteNumber(beard.growthaccumulator))
            and (beard.bits == nil or IsFiniteNumber(beard.bits))
            and (beard.skinname == nil or type(beard.skinname) == "string")
    elseif prefab == "wathgrithr" then
        local inspiration = resources.singinginspiration
        if type(inspiration) ~= "table"
            or not IsFiniteNumber(inspiration.current)
            or inspiration.current < 0 then
            return false
        end
        if inspiration.active_songs ~= nil then
            if type(inspiration.active_songs) ~= "table" then
                return false
            end
            for _, song in ipairs(inspiration.active_songs) do
                if type(song) ~= "string" or song == "" then
                    return false
                end
            end
        end
        local battleborn = resources.battleborn
        return type(battleborn) == "table"
            and IsFiniteNumber(battleborn.value)
            and battleborn.value >= 0
            and IsFiniteNumber(battleborn.time)
    end

    return false
end

local function ValidateLiveState(data)
    return ValidateState(data)
        and LIVE_SUPPORTED_PREFABS[data.prefab] == true
        and ValidateLiveResources(data.prefab, data.resources)
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
    if not LIVE_SUPPORTED_PREFABS[prefab] then
        return nil, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
    end

    local components = Util.GetComponents(player)
    if components == nil or HasUnsupportedRelationships(components) then
        return nil, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
    end

    local data =
    {
        prefab = prefab,
        appearance = {},
        resources = {},
        followers = {},
        pets = {},
        summoned = {},
        components = {},
        abilities = {},
        movement_speed = nil,
        runtime = true,
    }

    if prefab == "wilson" then
        data.resources.beard = CopyOfficialSave(components.beard)
        if data.resources.beard == nil then
            return nil, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
        end
    elseif prefab == "wathgrithr" then
        data.resources.singinginspiration =
            CopyOfficialSave(components.singinginspiration)
        local battleborn = components.battleborn
        local battleborn_value = battleborn ~= nil and battleborn.battleborn or nil
        local battleborn_time = battleborn ~= nil and battleborn.battleborn_time or nil
        data.resources.battleborn =
        {
            value = battleborn_value,
            time = battleborn_time,
        }
        if data.resources.singinginspiration == nil
            or battleborn == nil
            or not IsFiniteNumber(battleborn_value)
            or battleborn_value ~= 0
            or not IsFiniteNumber(battleborn_time)
            or HasEntries(data.resources.singinginspiration.active_songs) then
            return nil, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
        end
    end

    if not ValidateLiveState(data) then
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
    if not Util.IsSyntheticPlayer(player) and not ValidateLiveState(data) then
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
    local prefab = Util.GetCharacterPrefab(player)
    if not LIVE_SUPPORTED_PREFABS[prefab] then
        return false, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
    end

    -- 先复用捕获校验，确保不会在无法完整恢复的状态上做破坏性清理。
    local _, capture_code = CaptureLive(player)
    if capture_code ~= nil then
        return false, capture_code
    end

    if prefab == "wilson" then
        -- Beard 属于外观；当前 TestMode 的外观策略为 PRESERVE，不清零。
        return true
    end

    local components = Util.GetComponents(player)
    local inspiration = components ~= nil and components.singinginspiration or nil
    local battleborn = components ~= nil and components.battleborn or nil
    if inspiration == nil or battleborn == nil then
        return false, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
    end
    if battleborn ~= nil then
        -- battleborn 没有官方 OnSave/OnLoad；字段名来自官方组件，清理时显式归零，
        -- 避免玩家在沙箱内攻击后把临时累积值带回原世界。
        battleborn.battleborn = 0
        battleborn.battleborn_time = 0
    end
    local ok = pcall(inspiration.SetInspiration, inspiration, 0)
    return ok, ok and nil or CharacterAdapter.ERROR_CODES.CLEAN_FAILED
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
    local prefab = Util.GetCharacterPrefab(player)
    if prefab ~= data.prefab or not ValidateLiveState(data) then
        return false, CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
    end

    local components = Util.GetComponents(player)
    local ok
    if prefab == "wilson" then
        local beard = components ~= nil and components.beard or nil
        ok = beard ~= nil and type(beard.OnLoad) == "function"
        if ok then
            ok = pcall(beard.OnLoad, beard, Util.CopyData(data.resources.beard))
        end
    elseif prefab == "wathgrithr" then
        local inspiration =
            components ~= nil and components.singinginspiration or nil
        local battleborn = components ~= nil and components.battleborn or nil
        ok = inspiration ~= nil and type(inspiration.OnLoad) == "function"
            and battleborn ~= nil
            and type(battleborn.battleborn) == "number"
            and not HasEntries(inspiration.active_songs)
        if ok then
            ok = pcall(
                inspiration.OnLoad,
                inspiration,
                Util.CopyData(data.resources.singinginspiration)
            )
        end
        if ok then
            ok = pcall(function()
                battleborn.battleborn = data.resources.battleborn.value
                battleborn.battleborn_time = data.resources.battleborn.time
            end)
        end
    end
    return ok, ok and nil or CharacterAdapter.ERROR_CODES.STATE_UNSUPPORTED
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
        local code
        actual, code = CaptureLive(player)
        if actual == nil then
            return false, code or CharacterAdapter.ERROR_CODES.RESTORE_MISMATCH
        end
    end
    local equal = Util.DeepEqual(actual, data)
    return equal, equal and nil or CharacterAdapter.ERROR_CODES.RESTORE_MISMATCH
end

return CharacterAdapter
