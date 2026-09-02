-- WP9：Runtime 持久化只允许有限的 Lua 纯数据；拒绝函数、实体引用和循环表。

local Schema = {}

Schema.SCHEMA_VERSION = 1
Schema.RESTART_POLICY = "ABORT_ON_RESTART"

Schema.ERROR_CODES =
{
    INVALID_SNAPSHOT = "PERSISTENCE_INVALID_SNAPSHOT",
    INVALID_SCHEMA = "PERSISTENCE_INVALID_SCHEMA",
    UNKNOWN_SCHEMA = "PERSISTENCE_UNKNOWN_SCHEMA",
    NON_SERIALIZABLE = "PERSISTENCE_NON_SERIALIZABLE",
    CYCLIC_DATA = "PERSISTENCE_CYCLIC_DATA",
    INVALID_NUMBER = "PERSISTENCE_INVALID_NUMBER",
}

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function CopyPureValue(value, seen, path)
    local value_type = type(value)
    if value == nil or value_type == "string" or value_type == "boolean" then
        return value
    end
    if value_type == "number" then
        if not IsFiniteNumber(value) then
            return nil, Schema.ERROR_CODES.INVALID_NUMBER, path
        end
        return value
    end
    if value_type ~= "table" then
        return nil, Schema.ERROR_CODES.NON_SERIALIZABLE, path
    end

    seen = seen or {}
    path = path or "$"
    if seen[value] then
        return nil, Schema.ERROR_CODES.CYCLIC_DATA, path
    end
    seen[value] = true

    local copied = {}
    for key, item in pairs(value) do
        local key_type = type(key)
        if key_type ~= "string" and key_type ~= "number" then
            seen[value] = nil
            return nil, Schema.ERROR_CODES.NON_SERIALIZABLE, path
        end
        if key_type == "number" and not IsFiniteNumber(key) then
            seen[value] = nil
            return nil, Schema.ERROR_CODES.INVALID_NUMBER, path
        end
        local child_path = path .. "." .. tostring(key)
        local copied_item, code, failed_path = CopyPureValue(item, seen, child_path)
        if code ~= nil then
            seen[value] = nil
            return nil, code, failed_path
        end
        copied[key] = copied_item
    end

    seen[value] = nil
    return copied
end

function Schema.CopyPure(value)
    return CopyPureValue(value)
end

function Schema.IsPure(value)
    local _, code, path = CopyPureValue(value)
    return code == nil, code, path
end

local function DeepEqual(left, right, seen)
    if left == right then
        return true
    end
    if type(left) ~= type(right) or type(left) ~= "table" then
        return false
    end

    seen = seen or {}
    seen[left] = seen[left] or {}
    if seen[left][right] then
        return true
    end
    seen[left][right] = true

    for key, value in pairs(left) do
        if not DeepEqual(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

function Schema.DeepEqual(left, right)
    return DeepEqual(left, right)
end

function Schema.ValidateSnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return false, Schema.ERROR_CODES.INVALID_SNAPSHOT
    end
    if snapshot.schema_version ~= Schema.SCHEMA_VERSION then
        return false, Schema.ERROR_CODES.INVALID_SCHEMA
    end
    if snapshot.persistence ~= nil then
        if type(snapshot.persistence) ~= "table"
            or snapshot.persistence.schema_version ~= Schema.SCHEMA_VERSION then
            return false, Schema.ERROR_CODES.UNKNOWN_SCHEMA
        end
        if snapshot.persistence.restart_policy ~= nil
            and snapshot.persistence.restart_policy ~= Schema.RESTART_POLICY then
            return false, Schema.ERROR_CODES.INVALID_SCHEMA
        end
    end
    local pure, code = Schema.IsPure(snapshot)
    if not pure then
        return false, code or Schema.ERROR_CODES.NON_SERIALIZABLE
    end
    return true
end

return Schema
