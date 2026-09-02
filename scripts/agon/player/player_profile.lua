-- WP7：描述一局玩法使用的临时玩家规格，不保存任何实体引用。

local PlayerProfile = {}

PlayerProfile.SCHEMA_VERSION = 1

PlayerProfile.APPEARANCE_POLICIES =
{
    PRESERVE = "PRESERVE",
    REPLACE = "REPLACE",
}

PlayerProfile.ERROR_CODES =
{
    INVALID_PROFILE = "INVALID_PLAYER_PROFILE",
    INVALID_PROFILE_ID = "INVALID_PLAYER_PROFILE_ID",
    INVALID_PROFILE_VERSION = "INVALID_PLAYER_PROFILE_VERSION",
    INVALID_APPEARANCE_POLICY = "INVALID_PLAYER_PROFILE_APPEARANCE_POLICY",
    INVALID_BASE_STATS = "INVALID_PLAYER_PROFILE_BASE_STATS",
    INVALID_MOVEMENT_SPEED = "INVALID_PLAYER_PROFILE_MOVEMENT_SPEED",
    INVALID_STARTING_ITEMS = "INVALID_PLAYER_PROFILE_STARTING_ITEMS",
    INVALID_ITEM = "INVALID_PLAYER_PROFILE_ITEM",
    INVALID_DATA = "INVALID_PLAYER_PROFILE_DATA",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= 1
end

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value
end

local function ValidatePureData(value, seen)
    local value_type = type(value)
    if value == nil or value_type == "string" or value_type == "boolean" then
        return true
    end
    if value_type == "number" then
        return IsFiniteNumber(value)
    end
    if value_type ~= "table" then
        return false
    end
    seen = seen or {}
    if seen[value] then
        return false
    end
    seen[value] = true
    for key, item in pairs(value) do
        local key_type = type(key)
        if (key_type ~= "string" and key_type ~= "number")
            or not ValidatePureData(item, seen) then
            seen[value] = nil
            return false
        end
    end
    seen[value] = nil
    return true
end

local function CopyValue(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    for key, item in pairs(value) do
        copied[CopyValue(key)] = CopyValue(item)
    end
    return copied
end

local function ValidateStartingItems(items)
    if items == nil then
        return true
    end
    if type(items) ~= "table" then
        return false, PlayerProfile.ERROR_CODES.INVALID_STARTING_ITEMS
    end
    for index = 1, #items do
        local item = items[index]
        if type(item) == "string" then
            if item == "" then
                return false, PlayerProfile.ERROR_CODES.INVALID_ITEM
            end
        elseif type(item) == "table" then
            if not IsNonEmptyString(item.prefab or item.item_id) then
                return false, PlayerProfile.ERROR_CODES.INVALID_ITEM
            end
            if item.count ~= nil
                and (not IsPositiveInteger(item.count)) then
                return false, PlayerProfile.ERROR_CODES.INVALID_ITEM
            end
            if item.slot ~= nil
                and (not IsPositiveInteger(item.slot)) then
                return false, PlayerProfile.ERROR_CODES.INVALID_ITEM
            end
            if item.active ~= nil and type(item.active) ~= "boolean" then
                return false, PlayerProfile.ERROR_CODES.INVALID_ITEM
            end
            if item.equipment_slot ~= nil
                and type(item.equipment_slot) ~= "string"
                and type(item.equipment_slot) ~= "number" then
                return false, PlayerProfile.ERROR_CODES.INVALID_ITEM
            end
        else
            return false, PlayerProfile.ERROR_CODES.INVALID_ITEM
        end
    end
    return true
end

function PlayerProfile.Validate(profile)
    if type(profile) ~= "table" then
        return false, PlayerProfile.ERROR_CODES.INVALID_PROFILE
    end
    if profile.schema_version ~= nil
        and profile.schema_version ~= PlayerProfile.SCHEMA_VERSION then
        return false, PlayerProfile.ERROR_CODES.INVALID_PROFILE
    end
    if not IsNonEmptyString(profile.profile_id) then
        return false, PlayerProfile.ERROR_CODES.INVALID_PROFILE_ID
    end
    local version = profile.version or profile.profile_version
    if not IsPositiveInteger(version) then
        return false, PlayerProfile.ERROR_CODES.INVALID_PROFILE_VERSION
    end

    local appearance_policy = profile.appearance_policy
    if appearance_policy == nil then
        appearance_policy = profile.preserve_appearance == false
            and PlayerProfile.APPEARANCE_POLICIES.REPLACE
            or PlayerProfile.APPEARANCE_POLICIES.PRESERVE
    end
    if appearance_policy ~= PlayerProfile.APPEARANCE_POLICIES.PRESERVE
        and appearance_policy ~= PlayerProfile.APPEARANCE_POLICIES.REPLACE then
        return false, PlayerProfile.ERROR_CODES.INVALID_APPEARANCE_POLICY
    end

    if profile.base_stats ~= nil and type(profile.base_stats) ~= "table" then
        return false, PlayerProfile.ERROR_CODES.INVALID_BASE_STATS
    end
    if profile.movement_speed ~= nil
        and (not IsFiniteNumber(profile.movement_speed) or profile.movement_speed <= 0) then
        return false, PlayerProfile.ERROR_CODES.INVALID_MOVEMENT_SPEED
    end

    local items_valid, items_code = ValidateStartingItems(profile.starting_items)
    if not items_valid then
        return false, items_code
    end
    if profile.character_adapter ~= nil
        and not IsNonEmptyString(profile.character_adapter) then
        return false, PlayerProfile.ERROR_CODES.INVALID_DATA
    end
    if not ValidatePureData(profile) then
        return false, PlayerProfile.ERROR_CODES.INVALID_DATA
    end
    return true
end

function PlayerProfile.Normalize(profile)
    local valid, code = PlayerProfile.Validate(profile)
    if not valid then
        return nil, code
    end
    local normalized = CopyValue(profile)
    normalized.schema_version = PlayerProfile.SCHEMA_VERSION
    normalized.version = profile.version or profile.profile_version
    normalized.profile_version = nil
    if normalized.appearance_policy == nil then
        normalized.appearance_policy = profile.preserve_appearance == false
            and PlayerProfile.APPEARANCE_POLICIES.REPLACE
            or PlayerProfile.APPEARANCE_POLICIES.PRESERVE
    end
    normalized.preserve_appearance = normalized.appearance_policy
        == PlayerProfile.APPEARANCE_POLICIES.PRESERVE
    normalized.base_stats = CopyValue(profile.base_stats or {})
    normalized.starting_items = CopyValue(profile.starting_items or {})
    normalized.skills = CopyValue(profile.skills or {})
    normalized.allowed_abilities = CopyValue(profile.allowed_abilities or {})
    normalized.disabled_abilities = CopyValue(profile.disabled_abilities or {})
    normalized.temporary_components = CopyValue(profile.temporary_components or {})
    normalized.metadata = CopyValue(profile.metadata or {})
    return normalized
end

function PlayerProfile.Copy(profile)
    local normalized, code = PlayerProfile.Normalize(profile)
    if normalized == nil then
        return nil, code
    end
    return CopyValue(normalized)
end

function PlayerProfile.GetSnapshot(self)
    return CopyValue(self)
end

function PlayerProfile.New(profile)
    local normalized, code = PlayerProfile.Normalize(profile)
    if normalized == nil then
        return nil, code
    end
    normalized.GetSnapshot = nil
    return normalized
end

return PlayerProfile
