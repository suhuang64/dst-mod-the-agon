-- WP3：记录实体所属的 Instance、Scope 和生成代次。

local AgonInstanceMember = Class(function(self, inst)
    self.inst = inst
    self.schema_version = 1
    self.instance_id = nil
    self.scope_id = nil
    self.generation = nil
    self.prefab = nil
    self.category = nil
    self.cleanup_policy = nil
    self.profile_id = nil
    self.profile_version = nil
    self.parent_entity_id = nil
    self.spawn_source = nil
    self.persistent_key = nil
end)

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number" and value == math.floor(value) and value >= 1
end

local function CopyValue(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    for key, item in pairs(value) do
        if type(key) ~= "function" and type(key) ~= "userdata"
            and type(item) ~= "function" and type(item) ~= "userdata" then
            copied[CopyValue(key)] = CopyValue(item)
        end
    end
    return copied
end

local function GetEntityGuid(inst)
    if inst == nil then
        return nil
    end
    if inst.GUID ~= nil then
        return tostring(inst.GUID)
    end
    if inst.entity ~= nil and type(inst.entity.GetGUID) == "function" then
        local ok, guid = pcall(inst.entity.GetGUID, inst.entity)
        if ok and guid ~= nil then
            return tostring(guid)
        end
    end
    return nil
end

function AgonInstanceMember:SetMembership(instance_id, scope_id, generation, data)
    if not IsNonEmptyString(instance_id) or not IsNonEmptyString(scope_id)
        or not IsPositiveInteger(generation) then
        return false, "INVALID_MEMBERSHIP"
    end

    data = type(data) == "table" and data or {}
    self.instance_id = instance_id
    self.scope_id = scope_id
    self.generation = generation
    self.prefab = data.prefab
    self.category = data.category
    self.cleanup_policy = data.cleanup_policy
    self.profile_id = data.profile_id
    self.profile_version = data.profile_version
    self.parent_entity_id = data.parent_entity_id
    self.spawn_source = data.spawn_source
    self.persistent_key = data.persistent_key
    return true
end

function AgonInstanceMember:ClearMembership()
    self.instance_id = nil
    self.scope_id = nil
    self.generation = nil
    self.prefab = nil
    self.category = nil
    self.cleanup_policy = nil
    self.profile_id = nil
    self.profile_version = nil
    self.parent_entity_id = nil
    self.spawn_source = nil
    self.persistent_key = nil
    if self.inst ~= nil and type(self.inst.RemoveTag) == "function" then
        self.inst:RemoveTag("agon_managed")
    end
end

function AgonInstanceMember:GetInstanceId()
    return self.instance_id
end

function AgonInstanceMember:GetScopeId()
    return self.scope_id
end

function AgonInstanceMember:GetGeneration()
    return self.generation
end

function AgonInstanceMember:GetSnapshot()
    if self.instance_id == nil then
        return nil
    end
    return
    {
        schema_version = self.schema_version,
        entity_guid = GetEntityGuid(self.inst),
        instance_id = self.instance_id,
        scope_id = self.scope_id,
        generation = self.generation,
        prefab = self.prefab,
        category = self.category,
        cleanup_policy = self.cleanup_policy,
        profile_id = self.profile_id,
        profile_version = self.profile_version,
        parent_entity_id = self.parent_entity_id,
        spawn_source = self.spawn_source,
        persistent_key = self.persistent_key,
    }
end

function AgonInstanceMember:OnSave()
    return self:GetSnapshot()
end

function AgonInstanceMember:OnLoad(data)
    if type(data) ~= "table" or data.schema_version ~= self.schema_version
        or not IsNonEmptyString(data.instance_id)
        or not IsNonEmptyString(data.scope_id)
        or not IsPositiveInteger(data.generation) then
        return
    end

    self:SetMembership(data.instance_id, data.scope_id, data.generation, data)
end

function AgonInstanceMember:GetDebugString()
    return string.format(
        "instance=%s scope=%s generation=%s prefab=%s category=%s",
        tostring(self.instance_id),
        tostring(self.scope_id),
        tostring(self.generation),
        tostring(self.prefab),
        tostring(self.category)
    )
end

return AgonInstanceMember
