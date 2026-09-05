-- WP7：保存技能树 XP、技能点、已激活技能和编码数据，并把握手作为硬门。

local Util = require("agon/player/adapters/util")

local SkillTreeAdapter = {}
SkillTreeAdapter.adapter_id = "skilltree"
SkillTreeAdapter.version = 1
SkillTreeAdapter.order = 30
SkillTreeAdapter.dependencies = { "survival_stats" }

SkillTreeAdapter.ERROR_CODES =
{
    PLAYER_INVALID = "SKILLTREE_PLAYER_INVALID",
    COMPONENT_MISSING = "SKILLTREE_COMPONENT_MISSING",
    HANDSHAKE_REQUIRED = "SKILLTREE_HANDSHAKE_REQUIRED",
    SNAPSHOT_INVALID = "SKILLTREE_SNAPSHOT_INVALID",
    PROFILE_UNSUPPORTED = "SKILLTREE_LIVE_PROFILE_UNSUPPORTED",
    CLEAN_FAILED = "SKILLTREE_CLEAN_FAILED",
    APPLY_FAILED = "SKILLTREE_APPLY_FAILED",
    RESTORE_FAILED = "SKILLTREE_RESTORE_FAILED",
    RESTORE_MISMATCH = "SKILLTREE_RESTORE_MISMATCH",
}

local function IsNumber(value)
    return type(value) == "number" and value == value and value >= 0
end

local function ValidateState(data)
    return type(data) == "table"
        and data.handshake_complete == true
        and IsNumber(data.xp)
        and IsNumber(data.points)
        and type(data.activated_skills) == "table"
        and (data.encoded_data == nil or type(data.encoded_data) == "string")
        and (data.character_prefab == nil or type(data.character_prefab) == "string")
end

local function MakeDefaultState(player)
    return
    {
        handshake_complete = true,
        xp = 0,
        points = 0,
        activated_skills = {},
        selection = {},
        encoded_data = "",
        character_prefab = Util.GetCharacterPrefab(player),
    }
end

local function HasOfficialHandshake(player)
    return type(player) == "table"
        and type(POSTACTIVATEHANDSHAKE) == "table"
        and player._PostActivateHandshakeState_Server
            == POSTACTIVATEHANDSHAKE.READY
end

local function HasLiveHandshake(player, updater)
    return type(player) == "table"
        and HasOfficialHandshake(player)
end

local FAIR_GUARDED_METHODS =
{
    "ActivateSkill",
    "ActivateSkill_Server",
    "ActivateSkill_Client",
    "AddSkillXP",
    "AddSkillXP_Server",
    "AddSkillXP_Client",
    "SetPlayerSkillSelection",
}

local function IsFairProfile(profile)
    return type(profile) == "table"
        and type(profile.fair_mode) == "table"
        and profile.fair_mode.enabled == true
        and profile.fair_mode.disable_skilltree == true
end

local function InstallFairGuard(player, context, profile)
    if not IsFairProfile(profile) then
        return true
    end
    local components = Util.GetComponents(player)
    local updater = components ~= nil and components.skilltreeupdater or nil
    if updater == nil then
        return false
    end
    local guard = context.skilltree_fair_guard
    if guard ~= nil and guard.applied == true then
        return true
    end
    guard = { updater = updater, methods = {}, applied = true }
    context.skilltree_fair_guard = guard
    for index = 1, #FAIR_GUARDED_METHODS do
        local method = FAIR_GUARDED_METHODS[index]
        if type(updater[method]) == "function" then
            table.insert(
                guard.methods,
                {
                    name = method,
                    original = updater[method],
                }
            )
            local ok = pcall(function()
                updater[method] = function()
                    return false
                end
            end)
            if not ok then
                guard.applied = false
                return false
            end
        end
    end
    -- 官方 SkillTreeUpdater 至少应有 ActivateSkill 和 SetPlayerSkillSelection；
    -- 如果接线环境没有任何可拦截入口，宁可拒绝进入也不放过技能树。
    if #guard.methods == 0 then
        guard.applied = false
        return false
    end
    return true
end

local function RemoveFairGuard(context)
    local guard = context.skilltree_fair_guard
    if guard == nil then
        return true
    end
    for index = #guard.methods, 1, -1 do
        local entry = guard.methods[index]
        local ok = pcall(function()
            guard.updater[entry.name] = entry.original
        end)
        if not ok then
            return false
        end
    end
    guard.applied = false
    return true
end

local function CaptureSynthetic(player)
    local state = Util.GetTestState(player)
    if state == nil then
        return nil, SkillTreeAdapter.ERROR_CODES.PLAYER_INVALID
    end
    state.skilltree = state.skilltree or MakeDefaultState(player)
    local data = Util.CopyData(state.skilltree)
    data.handshake_complete = data.handshake_complete == true
    data.activated_skills = data.activated_skills or {}
    data.selection = data.selection or {}
    data.encoded_data = data.encoded_data or ""
    data.character_prefab = data.character_prefab or Util.GetCharacterPrefab(player)
    if not ValidateState(data) then
        return nil, SkillTreeAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

local function CaptureLive(player)
    local components = Util.GetComponents(player)
    local updater = components ~= nil and components.skilltreeupdater or nil
    if updater == nil or updater.skilltree == nil
        or type(updater.GetSkillXP) ~= "function"
        or type(updater.GetAvailableSkillPoints) ~= "function"
        or type(updater.GetActivatedSkills) ~= "function" then
        return nil, SkillTreeAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    if not HasLiveHandshake(player, updater) then
        return nil, SkillTreeAdapter.ERROR_CODES.HANDSHAKE_REQUIRED
    end
    local ok_xp, xp = pcall(updater.GetSkillXP, updater)
    local ok_points, points = pcall(updater.GetAvailableSkillPoints, updater)
    local ok_skills, skills = pcall(updater.GetActivatedSkills, updater)
    if not ok_xp or not ok_points or not ok_skills then
        return nil, SkillTreeAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    local selection = {}
    if type(updater.GetPlayerSkillSelection) == "function" then
        local selection_ok, selected = pcall(updater.GetPlayerSkillSelection, updater)
        if selection_ok and type(selected) == "table" then
            selection = Util.CopyData(selected)
        end
    end
    local encoded_data = nil
    if type(updater.skilltree.EncodeSkillTreeData) == "function" then
        local encoded_ok, encoded = pcall(
            updater.skilltree.EncodeSkillTreeData,
            updater.skilltree,
            player.prefab
        )
        if encoded_ok and type(encoded) == "string" then
            encoded_data = encoded
        end
    end
    local data =
    {
        handshake_complete = true,
        xp = xp,
        points = points,
        activated_skills = Util.CopyData(skills or {}),
        selection = selection,
        encoded_data = encoded_data,
        character_prefab = Util.GetCharacterPrefab(player),
        runtime = true,
    }
    if not ValidateState(data) then
        return nil, SkillTreeAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

function SkillTreeAdapter.Capture(player)
    if not Util.IsValidPlayer(player) then
        return nil, SkillTreeAdapter.ERROR_CODES.PLAYER_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        return CaptureSynthetic(player)
    end
    return CaptureLive(player)
end

function SkillTreeAdapter.ValidateCapture(player, data)
    if not Util.IsValidPlayer(player) or not ValidateState(data) then
        return false, SkillTreeAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if not Util.IsSyntheticPlayer(player) and data.handshake_complete ~= true then
        return false, SkillTreeAdapter.ERROR_CODES.HANDSHAKE_REQUIRED
    end
    return true
end

function SkillTreeAdapter.EnterCleanState(player)
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local clean = MakeDefaultState(player)
        clean.handshake_complete = true
        state.skilltree = clean
        return true
    end
    local components = Util.GetComponents(player)
    local updater = components ~= nil and components.skilltreeupdater or nil
    if updater == nil or not HasLiveHandshake(player, updater) then
        return false, SkillTreeAdapter.ERROR_CODES.HANDSHAKE_REQUIRED
    end
    if type(updater.GetActivatedSkills) ~= "function"
        or type(updater.DeactivateSkill) ~= "function" then
        return false, SkillTreeAdapter.ERROR_CODES.CLEAN_FAILED
    end
    local ok, skills = pcall(updater.GetActivatedSkills, updater)
    if not ok then
        return false, SkillTreeAdapter.ERROR_CODES.CLEAN_FAILED
    end
    updater:SetSilent(true)
    updater:SetSkipValidation(true)
    for skill in pairs(skills or {}) do
        local deactivated = pcall(updater.DeactivateSkill, updater, skill)
        if not deactivated then
            updater:SetSkipValidation(false)
            updater:SetSilent(false)
            return false, SkillTreeAdapter.ERROR_CODES.CLEAN_FAILED
        end
    end
    if updater.skilltree ~= nil and updater.skilltree.skillxp ~= nil then
        updater.skilltree.skillxp[player.prefab] = 0
    end
    updater:SetSkipValidation(false)
    updater:SetSilent(false)
    return true
end

local function GetProfileSkills(profile)
    if type(profile.skills) ~= "table" then
        return {}
    end
    return profile.skills
end

function SkillTreeAdapter.ApplyOverrides(player, context, sandbox)
    context = context or {}
    if context.skilltree_profile_applied then
        return true
    end
    local profile = sandbox ~= nil and sandbox.profile or context.profile
    if profile == nil then
        return false, SkillTreeAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        state.skilltree = state.skilltree or MakeDefaultState(player)
        state.skilltree.activated_skills = Util.CopyData(GetProfileSkills(profile))
        state.skilltree.points = profile.skill_points or 0
        state.skilltree.xp = profile.skill_xp or 0
        state.skilltree.encoded_data = profile.skilltree_data or ""
        state.skilltree.handshake_complete = true
        context.skilltree_profile_applied = true
        return true
    end
    if #(GetProfileSkills(profile)) > 0
        or profile.skill_points ~= nil
        or profile.skill_xp ~= nil
        or profile.skilltree_data ~= nil then
        return false, SkillTreeAdapter.ERROR_CODES.PROFILE_UNSUPPORTED
    end
    if not InstallFairGuard(player, context, profile) then
        return false, SkillTreeAdapter.ERROR_CODES.APPLY_FAILED
    end
    context.skilltree_profile_applied = true
    return true
end

function SkillTreeAdapter.RemoveOverrides(player, context)
    context = context or {}
    if context.skilltree_overrides_removed then
        return true
    end
    local cleaned, code = SkillTreeAdapter.EnterCleanState(player)
    if not cleaned then
        return cleaned, code
    end
    if not RemoveFairGuard(context) then
        return false, SkillTreeAdapter.ERROR_CODES.RESTORE_FAILED
    end
    context.skilltree_overrides_removed = true
    return true
end

function SkillTreeAdapter.Restore(player, data)
    if not ValidateState(data) then
        return false, SkillTreeAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        state.skilltree = Util.CopyData(data)
        return true
    end
    local components = Util.GetComponents(player)
    local updater = components ~= nil and components.skilltreeupdater or nil
    if updater == nil or not HasLiveHandshake(player, updater) then
        return false, SkillTreeAdapter.ERROR_CODES.HANDSHAKE_REQUIRED
    end
    local ok, current = pcall(updater.GetActivatedSkills, updater)
    if not ok then
        return false, SkillTreeAdapter.ERROR_CODES.RESTORE_FAILED
    end
    updater:SetSilent(true)
    updater:SetSkipValidation(true)
    for skill in pairs(current or {}) do
        local deactivated = pcall(updater.DeactivateSkill, updater, skill)
        if not deactivated then
            updater:SetSkipValidation(false)
            updater:SetSilent(false)
            return false, SkillTreeAdapter.ERROR_CODES.RESTORE_FAILED
        end
    end
    if updater.skilltree ~= nil and updater.skilltree.skillxp ~= nil then
        updater.skilltree.skillxp[player.prefab] = data.xp
    end
    if type(updater.SetPlayerSkillSelection) == "function" then
        local selected = pcall(updater.SetPlayerSkillSelection, updater, data.selection or {})
        if not selected then
            updater:SetSkipValidation(false)
            updater:SetSilent(false)
            return false, SkillTreeAdapter.ERROR_CODES.RESTORE_FAILED
        end
    end
    updater:SetSkipValidation(false)
    updater:SetSilent(false)
    return true
end

function SkillTreeAdapter.ValidateRestore(player, data)
    if not ValidateState(data) then
        return false, SkillTreeAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local actual = state ~= nil and state.skilltree or nil
        local equal = Util.DeepEqual(actual, data)
        return equal, equal and nil or SkillTreeAdapter.ERROR_CODES.RESTORE_MISMATCH
    end
    local components = Util.GetComponents(player)
    local updater = components ~= nil and components.skilltreeupdater or nil
    if updater == nil or not HasLiveHandshake(player, updater) then
        return false, SkillTreeAdapter.ERROR_CODES.HANDSHAKE_REQUIRED
    end
    local ok_xp, xp = pcall(updater.GetSkillXP, updater)
    local ok_skills, skills = pcall(updater.GetActivatedSkills, updater)
    local equal = ok_xp and ok_skills and xp == data.xp
        and Util.DeepEqual(skills or {}, data.activated_skills)
    return equal, equal and nil or SkillTreeAdapter.ERROR_CODES.RESTORE_MISMATCH
end

return SkillTreeAdapter
