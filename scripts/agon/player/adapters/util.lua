-- WP7：适配器共享的小工具；这里不依赖 DST 专有的全局断言函数。

local Util = {}

local function IsScalar(value)
    local value_type = type(value)
    return value == nil
        or value_type == "string"
        or value_type == "number"
        or value_type == "boolean"
end

function Util.CopyData(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return nil
    end
    seen[value] = true
    local copied = {}
    for key, item in pairs(value) do
        local copied_key = type(key) == "table"
            and Util.CopyData(key, seen)
            or key
        local copied_item = type(item) == "table"
            and Util.CopyData(item, seen)
            or item
        if copied_key ~= nil and copied_item ~= nil then
            copied[copied_key] = copied_item
        elseif copied_key ~= nil and item == nil then
            copied[copied_key] = nil
        end
    end
    seen[value] = nil
    return copied
end

function Util.CopyPureData(value, seen)
    if IsScalar(value) then
        return value
    end
    if type(value) ~= "table" then
        return nil
    end
    seen = seen or {}
    if seen[value] then
        return nil
    end
    seen[value] = true
    local copied = {}
    for key, item in pairs(value) do
        local key_type = type(key)
        if key_type == "string" or key_type == "number" then
            local copied_item = Util.CopyPureData(item, seen)
            if copied_item ~= nil or item == nil then
                copied[key] = copied_item
            end
        end
    end
    seen[value] = nil
    return copied
end

function Util.DeepEqual(left, right, seen)
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
        if not Util.DeepEqual(value, right[key], seen) then
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

function Util.ProtectedCall(callback, ...)
    if type(callback) ~= "function" then
        return false, "CALLBACK_UNAVAILABLE"
    end
    return pcall(callback, ...)
end

function Util.IsValidPlayer(player)
    if type(player) ~= "table" or type(player.userid) ~= "string"
        or player.userid == "" then
        return false
    end
    if type(player.IsValid) ~= "function" then
        return true
    end
    local ok, valid = pcall(player.IsValid, player)
    return ok and valid == true
end

function Util.IsSyntheticPlayer(player)
    return type(player) == "table"
        and (player.agon_sandbox_test == true
            or type(player.agon_sandbox_state) == "table")
end

function Util.GetTestState(player)
    if not Util.IsSyntheticPlayer(player) then
        return nil
    end
    player.agon_sandbox_state = player.agon_sandbox_state or {}
    return player.agon_sandbox_state
end

function Util.GetComponents(player)
    return type(player) == "table" and type(player.components) == "table"
        and player.components or nil
end

function Util.GetCharacterPrefab(player)
    if type(player) ~= "table" then
        return nil
    end
    if type(player.prefab) == "string" and player.prefab ~= "" then
        return player.prefab
    end
    local state = Util.GetTestState(player)
    return state ~= nil and state.character ~= nil
        and state.character.prefab or nil
end

function Util.GetItemPrefab(item)
    if item == nil then
        return nil
    end
    if type(item.prefab) == "string" and item.prefab ~= "" then
        return item.prefab
    end
    if type(item.GetPrefabName) == "function" then
        local ok, prefab = pcall(item.GetPrefabName, item)
        if ok and type(prefab) == "string" and prefab ~= "" then
            return prefab
        end
    end
    return nil
end

function Util.GetSaveRecord(item)
    if item == nil or type(item.GetSaveRecord) ~= "function" then
        return nil
    end
    local ok, record = pcall(item.GetSaveRecord, item)
    return ok and Util.CopyPureData(record) or nil
end

return Util
