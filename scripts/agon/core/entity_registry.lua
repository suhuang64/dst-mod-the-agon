-- WP3：维护 Instance 内实体的归属、代次、清理策略和生成来源。

local Diagnostics = require("agon/debug/diagnostics")
local ResourceScope = require("agon/core/resource_scope")

local EntityRegistry = {}
EntityRegistry.SCHEMA_VERSION = 1

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

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function GetGuid(entity)
    if entity == nil then
        return nil
    end
    if entity.GUID ~= nil then
        return tostring(entity.GUID)
    end
    if entity.entity ~= nil and type(entity.entity.GetGUID) == "function" then
        local ok, guid = ProtectedCall(entity.entity.GetGUID, entity.entity)
        if ok and guid ~= nil then
            return tostring(guid)
        end
    end
    return nil
end

local function IsValidEntity(entity)
    if entity == nil or type(entity.IsValid) ~= "function" then
        return false
    end
    local ok, valid = ProtectedCall(entity.IsValid, entity)
    return ok and valid == true
end

local function GetScopeId(scope)
    if scope == nil then
        return nil
    end
    if type(scope.GetId) == "function" then
        return scope:GetId()
    end
    return scope.scope_id
end

local function GetScopeInstanceId(scope)
    if scope == nil then
        return nil
    end
    if type(scope.GetInstanceId) == "function" then
        return scope:GetInstanceId()
    end
    return scope.instance_id
end

local function GetScopeGeneration(scope)
    if scope == nil then
        return nil
    end
    if type(scope.GetGeneration) == "function" then
        return scope:GetGeneration()
    end
    return scope.generation
end

local function IsScopeOpen(scope)
    return scope ~= nil and type(scope.IsOpen) == "function" and scope:IsOpen()
end

local function SetManagedFields(entity, record)
    entity._agon_instance_id = record.instance_id
    entity._agon_scope_id = record.scope_id
    entity._agon_generation = record.generation
    entity._agon_profile_id = record.profile_id
    entity._agon_profile_version = record.profile_version
    entity._agon_parent_entity_id = record.parent_entity_id
    entity._agon_root_owner = record.root_owner_entity
    if type(entity.AddTag) == "function" then
        local ok = ProtectedCall(entity.AddTag, entity, "agon_managed")
        if not ok then
            return false
        end
    end
    return true
end

local function ClearManagedFields(entity, instance_id)
    if entity == nil then
        return
    end
    if entity._agon_instance_id == instance_id then
        entity._agon_instance_id = nil
        entity._agon_scope_id = nil
        entity._agon_generation = nil
        entity._agon_profile_id = nil
        entity._agon_profile_version = nil
        entity._agon_parent_entity_id = nil
        entity._agon_root_owner = nil
        if type(entity.RemoveTag) == "function" then
            ProtectedCall(entity.RemoveTag, entity, "agon_managed")
        end
    end
end

local function SetMemberComponent(entity, record)
    if type(entity.AddComponent) ~= "function" then
        return false, "COMPONENT_API_UNAVAILABLE"
    end

    local member = entity.components ~= nil and entity.components.agon_instance_member or nil
    if member == nil then
        local added = ProtectedCall(entity.AddComponent, entity, "agon_instance_member")
        if not added then
            return false, "COMPONENT_ADD_FAILED"
        end
        member = entity.components ~= nil and entity.components.agon_instance_member or nil
    end
    if member == nil or type(member.SetMembership) ~= "function" then
        return false, "COMPONENT_INVALID"
    end

    if type(member.GetInstanceId) == "function" then
        local old_instance_id = member:GetInstanceId()
        if old_instance_id ~= nil and old_instance_id ~= record.instance_id then
            return false, "COMPONENT_OWNER_MISMATCH"
        end
    end
    local ok = member:SetMembership(
        record.instance_id,
        record.scope_id,
        record.generation,
        record
    )
    if ok == false then
        return false, "COMPONENT_MEMBERSHIP_FAILED"
    end
    return true
end

local function ClearMemberComponent(entity, instance_id)
    if entity == nil or entity.components == nil then
        return
    end
    local member = entity.components.agon_instance_member
    if member == nil or type(member.GetInstanceId) ~= "function"
        or member:GetInstanceId() ~= instance_id then
        return
    end
    if type(member.ClearMembership) == "function" then
        ProtectedCall(member.ClearMembership, member)
    end
end

function EntityRegistry.GetInstanceId(self)
    return self.instance_id
end

function EntityRegistry.Count(self)
    return #self.entity_order
end

function EntityRegistry.Get(self, guid)
    if guid == nil then
        return nil
    end
    return self.records_by_guid[tostring(guid)]
end

function EntityRegistry.GetByEntity(self, entity)
    return self:Get(GetGuid(entity))
end

function EntityRegistry.GetBySpawnSource(self, spawn_source)
    local records = {}
    if spawn_source == nil then
        return records
    end
    for index = 1, #self.entity_order do
        local record = self.records_by_guid[self.entity_order[index]]
        if record ~= nil and record.spawn_source == spawn_source then
            table.insert(records, record)
        end
    end
    return records
end

function EntityRegistry.List(self, category)
    local records = {}
    for index = 1, #self.entity_order do
        local record = self.records_by_guid[self.entity_order[index]]
        if record ~= nil and (category == nil or record.category == category) then
            table.insert(records, record)
        end
    end
    return records
end

function EntityRegistry.Register(self, entity, data)
    data = type(data) == "table" and data or {}
    if not IsValidEntity(entity) then
        return nil, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end

    local guid = GetGuid(entity)
    if guid == nil then
        return nil, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end
    local existing = self.records_by_guid[guid]
    if existing ~= nil then
        if existing.entity == entity then
            return existing, nil
        end
        return nil, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end

    local scope = data.scope
    if not IsScopeOpen(scope)
        or GetScopeInstanceId(scope) ~= self.instance_id then
        return nil, Diagnostics.ERROR_CODES.SCOPE_INSTANCE_MISMATCH
    end
    local scope_id = GetScopeId(scope)
    local generation = data.generation or GetScopeGeneration(scope)
    if not IsNonEmptyString(scope_id) or not IsPositiveInteger(generation) then
        return nil, Diagnostics.ERROR_CODES.SCOPE_INVALID
    end
    if type(scope.IsGenerationCurrent) == "function"
        and not scope:IsGenerationCurrent(generation) then
        return nil, Diagnostics.ERROR_CODES.SCOPE_CLOSED
    end

    local record =
    {
        guid = guid,
        instance_id = self.instance_id,
        scope_id = scope_id,
        scope = scope,
        generation = generation,
        entity = entity,
        prefab = data.prefab or entity.prefab,
        category = data.category or "GENERIC",
        cleanup_policy = data.cleanup_policy or ResourceScope.POLICIES.DESTROY,
        profile_id = data.profile_id,
        profile_version = data.profile_version,
        parent_entity_id = data.parent_entity_id,
        root_owner_entity = data.root_owner_entity,
        spawn_source = data.spawn_source,
        persistent_key = data.persistent_key,
        metadata = CopyValue(data.metadata),
        external_claim = data.external_claim == true,
        global_entity = data.global_entity == true,
        onremove_fn = nil,
        scope_resource_id = nil,
        removing = false,
    }

    if not SetManagedFields(entity, record) then
        return nil, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end
    local member_ok = SetMemberComponent(entity, record)
    if not member_ok then
        ClearManagedFields(entity, self.instance_id)
        return nil, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end

    local onremove_fn
    onremove_fn = function()
        self:Unregister(guid, true)
    end
    if type(entity.ListenForEvent) ~= "function" then
        ClearMemberComponent(entity, self.instance_id)
        ClearManagedFields(entity, self.instance_id)
        return nil, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end
    local listen_ok = ProtectedCall(entity.ListenForEvent, entity, "onremove", onremove_fn)
    if not listen_ok then
        ClearMemberComponent(entity, self.instance_id)
        ClearManagedFields(entity, self.instance_id)
        return nil, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end
    record.onremove_fn = onremove_fn

    local resource_id, scope_code = scope:RegisterEntity(
        entity,
        record.cleanup_policy,
        "entity:" .. guid,
        {
            guid = guid,
            instance_id = self.instance_id,
            category = record.category,
            spawn_source = record.spawn_source,
        }
    )
    if resource_id == nil then
        ProtectedCall(entity.RemoveEventCallback, entity, "onremove", onremove_fn)
        ClearMemberComponent(entity, self.instance_id)
        ClearManagedFields(entity, self.instance_id)
        return nil, scope_code or Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end
    record.scope_resource_id = resource_id
    self.records_by_guid[guid] = record
    table.insert(self.entity_order, guid)
    return record
end

function EntityRegistry.Claim(self, entity, data)
    data = type(data) == "table" and data or {}
    data.external_claim = true
    return self:Register(entity, data)
end

function EntityRegistry.Inherit(self, child, parent, data)
    data = type(data) == "table" and data or {}
    if not IsValidEntity(child) or not IsValidEntity(parent) or child == parent then
        return nil, Diagnostics.ERROR_CODES.ENTITY_OWNER_MISMATCH
    end

    local parent_record = self:GetByEntity(parent)
    if parent_record == nil or parent_record.instance_id ~= self.instance_id
        or not IsScopeOpen(parent_record.scope) then
        return nil, Diagnostics.ERROR_CODES.ENTITY_OWNER_MISMATCH
    end

    local child_guid = GetGuid(child)
    if child_guid == nil then
        return nil, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end
    local existing = self.records_by_guid[child_guid]
    if existing ~= nil then
        if existing.entity == child and existing.instance_id == self.instance_id then
            return existing
        end
        return nil, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end

    local root_owner = data.root_owner_entity or parent_record.root_owner_entity or parent
    local record, register_code = self:Register(
        child,
        {
            scope = data.scope or parent_record.scope,
            generation = data.generation or parent_record.generation,
            prefab = data.prefab or child.prefab,
            category = data.category or "CHILD",
            cleanup_policy = data.cleanup_policy or parent_record.cleanup_policy,
            profile_id = data.profile_id or parent_record.profile_id,
            profile_version = data.profile_version or parent_record.profile_version,
            parent_entity_id = parent_record.guid,
            root_owner_entity = root_owner,
            spawn_source = data.spawn_source or parent_record.spawn_source,
            persistent_key = data.persistent_key,
            metadata = data.metadata,
        }
    )
    if record == nil then
        return nil, register_code or Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end
    child._agon_parent_entity = parent
    child._agon_root_owner = root_owner
    return record
end

function EntityRegistry.Unregister(self, guid_or_entity, from_onremove)
    local guid = type(guid_or_entity) == "table"
        and GetGuid(guid_or_entity)
        or (guid_or_entity ~= nil and tostring(guid_or_entity) or nil)
    if guid == nil then
        return false, Diagnostics.ERROR_CODES.ENTITY_NOT_FOUND
    end
    local record = self.records_by_guid[guid]
    if record == nil then
        return false, Diagnostics.ERROR_CODES.ENTITY_NOT_FOUND
    end

    if self.profile_service ~= nil
        and type(self.profile_service.OnEntityUnregistered) == "function" then
        ProtectedCall(
            self.profile_service.OnEntityUnregistered,
            self.profile_service,
            record
        )
    end

    self.records_by_guid[guid] = nil
    for index = 1, #self.entity_order do
        if self.entity_order[index] == guid then
            table.remove(self.entity_order, index)
            break
        end
    end

    if record.scope ~= nil and record.scope_resource_id ~= nil
        and type(record.scope.ReleaseResource) == "function" then
        record.scope:ReleaseResource(record.scope_resource_id)
    end
    if not from_onremove and IsValidEntity(record.entity)
        and type(record.entity.RemoveEventCallback) == "function"
        and record.onremove_fn ~= nil then
        ProtectedCall(record.entity.RemoveEventCallback, record.entity, "onremove", record.onremove_fn)
    end
    ClearMemberComponent(record.entity, self.instance_id)
    ClearManagedFields(record.entity, self.instance_id)
    return true
end

function EntityRegistry.UpdateProfile(self, guid_or_entity, profile_id, profile_version)
    local record = type(guid_or_entity) == "table"
        and self:GetByEntity(guid_or_entity)
        or self:Get(guid_or_entity)
    if record == nil then
        return false, Diagnostics.ERROR_CODES.ENTITY_NOT_FOUND
    end
    if profile_id ~= nil and not IsNonEmptyString(profile_id) then
        return false, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end
    if profile_version ~= nil and not IsPositiveInteger(profile_version) then
        return false, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
    end
    record.profile_id = profile_id
    record.profile_version = profile_version
    if record.entity ~= nil then
        record.entity._agon_profile_id = profile_id
        record.entity._agon_profile_version = profile_version
    end
    local member = record.entity ~= nil and record.entity.components ~= nil
        and record.entity.components.agon_instance_member or nil
    if member ~= nil and type(member.SetMembership) == "function" then
        local ok = member:SetMembership(
            record.instance_id,
            record.scope_id,
            record.generation,
            record
        )
        if ok == false then
            return false, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
        end
    end
    return true, record
end

function EntityRegistry.Remove(self, guid_or_entity)
    local record = type(guid_or_entity) == "table"
        and self:GetByEntity(guid_or_entity)
        or self:Get(guid_or_entity)
    if record == nil then
        return false, Diagnostics.ERROR_CODES.ENTITY_NOT_FOUND
    end
    if not IsValidEntity(record.entity) then
        self:Unregister(record.guid, true)
        return true
    end
    if type(record.entity.Remove) ~= "function" then
        return false, Diagnostics.ERROR_CODES.ENTITY_REMOVE_FAILED
    end

    record.removing = true
    local ok = ProtectedCall(record.entity.Remove, record.entity)
    if not ok then
        record.removing = false
        return false, Diagnostics.ERROR_CODES.ENTITY_REMOVE_FAILED
    end
    if self.records_by_guid[record.guid] ~= nil then
        self:Unregister(record.guid, true)
    end
    return true
end

function EntityRegistry.RemoveGuids(self, guids)
    if type(guids) ~= "table" then
        return false, Diagnostics.ERROR_CODES.ENTITY_NOT_FOUND
    end
    local all_removed = true
    local last_code = nil
    for index = 1, #guids do
        local removed, code = self:Remove(guids[index])
        if not removed and code ~= Diagnostics.ERROR_CODES.ENTITY_NOT_FOUND then
            all_removed = false
            last_code = code
        end
    end
    return all_removed, last_code
end

function EntityRegistry.RemoveAll(self)
    local guids = {}
    for index = 1, #self.entity_order do
        guids[index] = self.entity_order[index]
    end
    return self:RemoveGuids(guids)
end

function EntityRegistry.Validate(self, scope_lookup)
    local seen = {}
    for index = 1, #self.entity_order do
        local guid = self.entity_order[index]
        if seen[guid] then
            return false, Diagnostics.ERROR_CODES.ENTITY_REGISTRATION_FAILED
        end
        seen[guid] = true

        local record = self.records_by_guid[guid]
        if record == nil or record.instance_id ~= self.instance_id
            or record.guid ~= guid or not IsValidEntity(record.entity) then
            return false, Diagnostics.ERROR_CODES.ENTITY_OWNER_MISMATCH
        end
        if type(scope_lookup) == "function" then
            local scope = scope_lookup(record.scope_id)
            if scope == nil or not IsScopeOpen(scope)
                or GetScopeInstanceId(scope) ~= self.instance_id then
                return false, Diagnostics.ERROR_CODES.SCOPE_INVALID
            end
        end
    end
    return true
end

function EntityRegistry.GetSnapshot(self)
    local entities = {}
    for index = 1, #self.entity_order do
        local record = self.records_by_guid[self.entity_order[index]]
        if record ~= nil then
            table.insert(
                entities,
                {
                    guid = record.guid,
                    instance_id = record.instance_id,
                    scope_id = record.scope_id,
                    generation = record.generation,
                    prefab = record.prefab,
                    category = record.category,
                    cleanup_policy = record.cleanup_policy,
                    profile_id = record.profile_id,
                    profile_version = record.profile_version,
                    external_claim = record.external_claim,
                    parent_entity_id = record.parent_entity_id,
                    root_owner_entity_id = GetGuid(record.root_owner_entity),
                    spawn_source = record.spawn_source,
                    persistent_key = record.persistent_key,
                    metadata = CopyValue(record.metadata),
                }
            )
        end
    end
    return
    {
        schema_version = EntityRegistry.SCHEMA_VERSION,
        instance_id = self.instance_id,
        count = #entities,
        entities = entities,
    }
end

function EntityRegistry.GetDebugLines(self)
    local lines =
    {
        string.format(
            "entity_registry instance=%s count=%d",
            tostring(self.instance_id),
            #self.entity_order
        ),
    }
    for index = 1, #self.entity_order do
        local record = self.records_by_guid[self.entity_order[index]]
        if record ~= nil then
            table.insert(
                lines,
                string.format(
                    "  guid=%s prefab=%s category=%s scope=%s generation=%s source=%s",
                    tostring(record.guid),
                    tostring(record.prefab),
                    tostring(record.category),
                    tostring(record.scope_id),
                    tostring(record.generation),
                    tostring(record.spawn_source)
                )
            )
        end
    end
    return lines
end

local function AttachMethods(registry)
    registry.GetInstanceId = EntityRegistry.GetInstanceId
    registry.Count = EntityRegistry.Count
    registry.Get = EntityRegistry.Get
    registry.GetByEntity = EntityRegistry.GetByEntity
    registry.GetBySpawnSource = EntityRegistry.GetBySpawnSource
    registry.List = EntityRegistry.List
    registry.Register = EntityRegistry.Register
    registry.Claim = EntityRegistry.Claim
    registry.Inherit = EntityRegistry.Inherit
    registry.UpdateProfile = EntityRegistry.UpdateProfile
    registry.Unregister = EntityRegistry.Unregister
    registry.Remove = EntityRegistry.Remove
    registry.RemoveGuids = EntityRegistry.RemoveGuids
    registry.RemoveAll = EntityRegistry.RemoveAll
    registry.Validate = EntityRegistry.Validate
    registry.GetSnapshot = EntityRegistry.GetSnapshot
    registry.GetDebugLines = EntityRegistry.GetDebugLines
    return registry
end

function EntityRegistry.New(instance_id)
    if not IsNonEmptyString(instance_id) then
        return nil, Diagnostics.ERROR_CODES.INVALID_INSTANCE_ID
    end
    return AttachMethods(
    {
        schema_version = EntityRegistry.SCHEMA_VERSION,
        instance_id = instance_id,
        records_by_guid = {},
        entity_order = {},
        profile_service = nil,
    })
end

return EntityRegistry
