-- WP6：在单个 Instance 内应用和清理 EntityProfile；不改变全局 TUNING/Prefab。

local Diagnostics = require("agon/debug/diagnostics")
local ResourceScope = require("agon/core/resource_scope")
local EntityProfileRegistry = require("agon/services/entity_profile_registry")

local EntityProfileService = {}
EntityProfileService.SCHEMA_VERSION = 1
EntityProfileService.SERVICE_ID = "entity_profiles"
EntityProfileService.SERVICE_VERSION = 1

EntityProfileService.ERROR_CODES =
{
    SERVICE_CLOSED = "ENTITY_PROFILE_SERVICE_CLOSED",
    REGISTRY_UNAVAILABLE = "ENTITY_PROFILE_REGISTRY_UNAVAILABLE",
    UNKNOWN_PROFILE = EntityProfileRegistry.ERROR_CODES.UNKNOWN_PROFILE,
    PROFILE_VERSION_MISMATCH = EntityProfileRegistry.ERROR_CODES.VERSION_MISMATCH,
    PREFAB_MISMATCH = "ENTITY_PROFILE_PREFAB_MISMATCH",
    ENTITY_NOT_OWNED = "ENTITY_PROFILE_ENTITY_NOT_OWNED",
    ENTITY_INVALID = "ENTITY_PROFILE_ENTITY_INVALID",
    SCOPE_INVALID = "ENTITY_PROFILE_SCOPE_INVALID",
    PROFILE_RECONFIGURE_NOT_ALLOWED = "ENTITY_PROFILE_RECONFIGURE_NOT_ALLOWED",
    APPLY_MODE_BLOCKING_ONLY = "ENTITY_PROFILE_BLOCKING_ONLY",
    APPLY_MODE_SPAWN_ONLY = "ENTITY_PROFILE_SPAWN_ONLY",
    BLOCKING_STATE_REQUIRED = "ENTITY_PROFILE_BLOCKING_STATE_REQUIRED",
    ADAPTER_APPLY_FAILED = "ENTITY_PROFILE_ADAPTER_APPLY_FAILED",
    ADAPTER_REMOVE_FAILED = "ENTITY_PROFILE_ADAPTER_REMOVE_FAILED",
    IN_PLACE_CAPTURE_REQUIRED = "ENTITY_PROFILE_CAPTURE_RESTORE_REQUIRED",
    SCOPE_RESOURCE_FAILED = "ENTITY_PROFILE_SCOPE_RESOURCE_FAILED",
    REGISTRY_UPDATE_FAILED = "ENTITY_PROFILE_REGISTRY_UPDATE_FAILED",
    INVALID_PROFILE_REFERENCE = "ENTITY_PROFILE_REFERENCE_INVALID",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= 1
end

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function CopyData(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    for key, item in pairs(value) do
        if type(key) ~= "function" and type(key) ~= "userdata"
            and type(item) ~= "function" and type(item) ~= "userdata" then
            copied[CopyData(key)] = CopyData(item)
        end
    end
    return copied
end

local function GetInstanceId(instance)
    if instance == nil then
        return nil
    end
    if type(instance.GetId) == "function" then
        return instance:GetId()
    end
    return instance.instance_id
end

local function GetLifecycleState(instance)
    if instance == nil then
        return nil
    end
    if type(instance.GetLifecycleState) == "function" then
        return instance:GetLifecycleState()
    end
    return instance.lifecycle_state
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

local function IsScopeOpen(scope)
    return scope ~= nil and type(scope.IsOpen) == "function" and scope:IsOpen()
end

local function IsSafeBlockingState(state)
    return state == "PREPARING" or state == "TRANSITION"
end

local function ResolveTarget(self, target)
    if type(target) == "table" and target.guid ~= nil then
        return self.entity_registry:Get(target.guid)
    end
    if type(target) == "table" and target.entity ~= nil and target.guid ~= nil then
        return self.entity_registry:Get(target.guid)
    end
    if type(target) == "table" and target.entity ~= nil
        and target.instance_id ~= nil then
        return target
    end
    return self.entity_registry:GetByEntity(target)
end

local function NormalizeProfileReference(profile_id, profile_version)
    if type(profile_id) == "table" then
        profile_version = profile_id.version or profile_id.profile_version
        profile_id = profile_id.profile_id or profile_id.id
    end
    if not IsNonEmptyString(profile_id) then
        return nil, nil, EntityProfileService.ERROR_CODES.INVALID_PROFILE_REFERENCE
    end
    if profile_version ~= nil and not IsPositiveInteger(profile_version) then
        return nil, nil, EntityProfileService.ERROR_CODES.INVALID_PROFILE_REFERENCE
    end
    return profile_id, profile_version
end

local function RemoveFromOrder(self, guid)
    for index = 1, #self.applied_order do
        if self.applied_order[index] == guid then
            table.remove(self.applied_order, index)
            return
        end
    end
end

local function GetPolicyValue(policy, record)
    if type(policy) ~= "table" then
        return policy
    end
    local value = policy[record.category]
    if value ~= nil then
        return value
    end
    value = policy[record.prefab]
    if value ~= nil then
        return value
    end
    return policy.default
end

local function NormalizeChildReference(value, fallback_version)
    if value == nil then
        return nil, fallback_version
    end
    if type(value) == "string" then
        return value, fallback_version
    end
    if type(value) == "table" then
        return value.profile_id or value.id, value.profile_version or value.version or fallback_version
    end
    return nil, nil
end

function EntityProfileService.ResolveChildProfile(self, parent_profile, record, policy)
    if parent_profile == nil then
        return nil, nil
    end
    local selected_policy = policy
    if selected_policy == nil then
        selected_policy = parent_profile.child_profiles
    end
    local selected = GetPolicyValue(selected_policy, record)
    if selected == false then
        return nil, nil
    end
    if selected == nil then
        if self.profile_registry:MatchesPrefab(parent_profile, record.prefab) then
            return parent_profile.profile_id, parent_profile.version
        end
        return nil, nil
    end
    local profile_id, profile_version = NormalizeChildReference(
        selected,
        parent_profile.version
    )
    if profile_id == nil then
        return parent_profile.profile_id, parent_profile.version
    end
    return profile_id, profile_version
end

function EntityProfileService.Resolve(self, profile_id, profile_version)
    if self.profile_registry == nil
        or type(self.profile_registry.Get) ~= "function" then
        return nil, EntityProfileService.ERROR_CODES.REGISTRY_UNAVAILABLE
    end
    local normalized_id, normalized_version, reference_code = NormalizeProfileReference(
        profile_id,
        profile_version
    )
    if normalized_id == nil then
        return nil, reference_code
    end
    local profile, profile_code = self.profile_registry:Get(
        normalized_id,
        normalized_version
    )
    if profile == nil then
        if profile_code == EntityProfileRegistry.ERROR_CODES.VERSION_MISMATCH then
            return nil, EntityProfileService.ERROR_CODES.PROFILE_VERSION_MISMATCH
        end
        return nil, EntityProfileService.ERROR_CODES.UNKNOWN_PROFILE
    end
    return profile
end

function EntityProfileService.ValidateTarget(self, target)
    local record = ResolveTarget(self, target)
    if record == nil then
        return nil, EntityProfileService.ERROR_CODES.ENTITY_NOT_OWNED
    end
    if record.guid == nil or self.entity_registry:Get(record.guid) ~= record then
        return nil, EntityProfileService.ERROR_CODES.ENTITY_NOT_OWNED
    end
    if record.instance_id ~= self.instance_id
        or not IsValidEntity(record.entity) then
        return nil, EntityProfileService.ERROR_CODES.ENTITY_NOT_OWNED
    end
    if record.category == "GLOBAL" or record.category == "LOBBY"
        or record.global_entity == true then
        return nil, EntityProfileService.ERROR_CODES.ENTITY_NOT_OWNED
    end
    if not IsScopeOpen(record.scope)
        or record.scope.instance_id ~= self.instance_id then
        return nil, EntityProfileService.ERROR_CODES.SCOPE_INVALID
    end
    if record.entity._agon_instance_id ~= nil
        and record.entity._agon_instance_id ~= self.instance_id then
        return nil, EntityProfileService.ERROR_CODES.ENTITY_NOT_OWNED
    end
    return record
end

local function ValidateApplyMode(self, profile, runtime, options)
    options = options or {}
    local operation = options.operation or "live"
    local execution_mode = options.execution_mode or "LIVE"
    local state = GetLifecycleState(self.instance)

    if runtime ~= nil and runtime.profile_id == profile.profile_id
        and runtime.profile_version == profile.version then
        return true
    end

    if profile.apply_mode == EntityProfileRegistry.APPLY_MODES.SPAWN_ONLY then
        if operation ~= "spawn" then
            return false, EntityProfileService.ERROR_CODES.APPLY_MODE_SPAWN_ONLY
        end
        return true
    end
    if profile.apply_mode == EntityProfileRegistry.APPLY_MODES.BLOCKING_ONLY then
        if execution_mode ~= "BLOCKING" then
            return false, EntityProfileService.ERROR_CODES.APPLY_MODE_BLOCKING_ONLY
        end
        if not IsSafeBlockingState(state) then
            return false, EntityProfileService.ERROR_CODES.BLOCKING_STATE_REQUIRED
        end
        return true
    end
    if profile.apply_mode == EntityProfileRegistry.APPLY_MODES.LIVE_SAFE then
        return true
    end
    return false, EntityProfileRegistry.ERROR_CODES.INVALID_APPLY_MODE
end

local function CallAdapterCleanup(runtime, context)
    local adapter = runtime.profile.adapter
    local cleanup_result
    if runtime.external_claim and type(adapter.Restore) == "function" then
        local ok, result = ProtectedCall(
            adapter.Restore,
            runtime.entity,
            context,
            runtime.capture_state,
            runtime.apply_state
        )
        if not ok then
            return false, EntityProfileService.ERROR_CODES.ADAPTER_REMOVE_FAILED
        end
        cleanup_result = result
    elseif type(adapter.Remove) == "function" then
        local ok, result = ProtectedCall(
            adapter.Remove,
            runtime.entity,
            context,
            runtime.apply_state
        )
        if not ok then
            return false, EntityProfileService.ERROR_CODES.ADAPTER_REMOVE_FAILED
        end
        cleanup_result = result
    elseif type(runtime.cleanup) == "function" then
        local ok, result = ProtectedCall(runtime.cleanup, runtime.entity, context)
        if not ok then
            return false, EntityProfileService.ERROR_CODES.ADAPTER_REMOVE_FAILED
        end
        cleanup_result = result
    end
    if cleanup_result == false then
        return false, EntityProfileService.ERROR_CODES.ADAPTER_REMOVE_FAILED
    end
    return true
end

function EntityProfileService.RemoveRuntime(self, guid, options)
    options = type(options) == "table" and options or {}
    local runtime = self.applied_by_guid[guid]
    if runtime == nil then
        return true
    end
    if runtime.removing then
        return true
    end
    runtime.removing = true
    local context =
    {
        instance = self.instance,
        profile = runtime.profile,
        record = runtime.record,
        reason = options.reason or "profile_removed",
        operation = "remove",
    }
    local cleaned, cleanup_code = CallAdapterCleanup(runtime, context)
    if runtime.scope_resource_id ~= nil and not options.from_scope
        and runtime.record.scope ~= nil
        and type(runtime.record.scope.ReleaseResource) == "function" then
        runtime.record.scope:ReleaseResource(runtime.scope_resource_id)
    end
    runtime.scope_resource_id = nil
    self.applied_by_guid[guid] = nil
    RemoveFromOrder(self, guid)

    if options.update_registry ~= false
        and self.entity_registry:Get(guid) ~= nil
        and type(self.entity_registry.UpdateProfile) == "function" then
        local updated = self.entity_registry:UpdateProfile(guid, nil, nil)
        if not updated then
            cleaned = false
            cleanup_code = cleanup_code
                or EntityProfileService.ERROR_CODES.REGISTRY_UPDATE_FAILED
        end
    end
    runtime.removing = false
    if not cleaned then
        return false, cleanup_code or EntityProfileService.ERROR_CODES.ADAPTER_REMOVE_FAILED
    end
    return true
end

function EntityProfileService.OnEntityUnregistered(self, record)
    if type(record) ~= "table" or record.guid == nil then
        return true
    end
    return self:RemoveRuntime(
        tostring(record.guid),
        {
            from_entity = true,
            from_scope = true,
            update_registry = false,
            reason = "entity_unregistered",
        }
    )
end

function EntityProfileService.Remove(self, target, options)
    local record, target_code = self:ValidateTarget(target)
    if record == nil then
        return false, target_code
    end
    return self:RemoveRuntime(record.guid, options)
end

function EntityProfileService.Apply(self, target, profile_id, profile_version, options)
    if self.closed then
        return nil, EntityProfileService.ERROR_CODES.SERVICE_CLOSED
    end
    local record, target_code = self:ValidateTarget(target)
    if record == nil then
        return nil, target_code
    end
    local profile, profile_code = self:Resolve(profile_id, profile_version)
    if profile == nil then
        return nil, profile_code
    end
    if self.profile_registry:MatchesPrefab(profile, record.prefab) ~= true then
        return nil, EntityProfileService.ERROR_CODES.PREFAB_MISMATCH
    end

    local guid = tostring(record.guid)
    local runtime = self.applied_by_guid[guid]
    if runtime ~= nil and runtime.profile_id == profile.profile_id
        and runtime.profile_version == profile.version then
        return record
    end

    options = type(options) == "table" and options or {}
    local mode_valid, mode_code = ValidateApplyMode(self, profile, runtime, options)
    if not mode_valid then
        return nil, mode_code
    end
    if runtime ~= nil then
        if options.replace ~= true
            or runtime.profile.apply_mode ~= EntityProfileRegistry.APPLY_MODES.LIVE_SAFE
            or profile.apply_mode ~= EntityProfileRegistry.APPLY_MODES.LIVE_SAFE then
            return nil, EntityProfileService.ERROR_CODES.PROFILE_RECONFIGURE_NOT_ALLOWED
        end
        local removed, remove_code = self:RemoveRuntime(
            guid,
            { reason = "profile_replace" }
        )
        if not removed then
            return nil, remove_code
        end
    end

    local external_claim = record.external_claim == true
    local capture_state = nil
    if external_claim then
        if type(profile.adapter.Capture) ~= "function"
            or type(profile.adapter.Restore) ~= "function" then
            return nil, EntityProfileService.ERROR_CODES.IN_PLACE_CAPTURE_REQUIRED
        end
        local captured, capture_code = ProtectedCall(
            profile.adapter.Capture,
            record.entity,
            {
                instance = self.instance,
                profile = profile,
                record = record,
                operation = options.operation or "live",
            }
        )
        if not captured then
            return nil, EntityProfileService.ERROR_CODES.ADAPTER_APPLY_FAILED
        end
        capture_state = capture_code
    end

    local apply_context =
    {
        instance = self.instance,
        profile = profile,
        record = record,
        operation = options.operation or "live",
        execution_mode = options.execution_mode or "LIVE",
        child = options.child == true,
        parent_entity_id = record.parent_entity_id,
        captured_state = capture_state,
    }
    local ok, adapter_result = ProtectedCall(
        profile.adapter.Apply,
        record.entity,
        apply_context
    )
    if not ok or adapter_result == false then
        return nil, EntityProfileService.ERROR_CODES.ADAPTER_APPLY_FAILED
    end

    local apply_state = adapter_result
    local cleanup = nil
    if type(adapter_result) == "table" and adapter_result.state ~= nil then
        apply_state = adapter_result.state
        cleanup = adapter_result.cleanup
    end
    local runtime_record =
    {
        guid = guid,
        entity = record.entity,
        record = record,
        profile = profile,
        profile_id = profile.profile_id,
        profile_version = profile.version,
        replication_mode = profile.replication_mode,
        external_claim = external_claim,
        capture_state = capture_state,
        apply_state = apply_state,
        cleanup = cleanup,
        scope_resource_id = nil,
        removing = false,
    }

    local resource_id, resource_code = record.scope:RegisterCleanup(
        function()
            return self:RemoveRuntime(
                guid,
                {
                    from_scope = true,
                    reason = "profile_scope_closed",
                }
            )
        end,
        ResourceScope.POLICIES.DESTROY,
        "entity_profile:" .. guid
    )
    if resource_id == nil then
        CallAdapterCleanup(runtime_record,
        {
            instance = self.instance,
            profile = profile,
            record = record,
            reason = "profile_registration_failed",
            operation = "remove",
        })
        return nil, resource_code or EntityProfileService.ERROR_CODES.SCOPE_RESOURCE_FAILED
    end
    runtime_record.scope_resource_id = resource_id

    if type(self.entity_registry.UpdateProfile) ~= "function"
        or not self.entity_registry:UpdateProfile(
            record.guid,
            profile.profile_id,
            profile.version
        ) then
        record.scope:ReleaseResource(resource_id)
        CallAdapterCleanup(runtime_record,
        {
            instance = self.instance,
            profile = profile,
            record = record,
            reason = "profile_registry_update_failed",
            operation = "remove",
        })
        return nil, EntityProfileService.ERROR_CODES.REGISTRY_UPDATE_FAILED
    end

    self.applied_by_guid[guid] = runtime_record
    table.insert(self.applied_order, guid)
    return record
end

function EntityProfileService.ApplySpawn(self, instance, records, spec)
    if self.closed then
        return false, EntityProfileService.ERROR_CODES.SERVICE_CLOSED
    end
    if GetInstanceId(instance) ~= self.instance_id
        or type(records) ~= "table" then
        return false, EntityProfileService.ERROR_CODES.ENTITY_NOT_OWNED
    end
    spec = type(spec) == "table" and spec or {}
    local parent_profile, parent_code = nil, nil
    if spec.profile_id ~= nil then
        parent_profile, parent_code = self:Resolve(
            spec.profile_id,
            spec.profile_version
        )
        if parent_profile == nil then
            return false, parent_code
        end
    end

    local applied = {}
    for index = 1, #records do
        local record = records[index]
        local selected_id = spec.profile_id
        local selected_version = spec.profile_version
        local child = index > 1
        if child and parent_profile ~= nil then
            selected_id, selected_version = self:ResolveChildProfile(
                parent_profile,
                record,
                spec.child_profile_policy
            )
        end
        if selected_id ~= nil then
            local applied_record, apply_code = self:Apply(
                record,
                selected_id,
                selected_version,
                {
                    operation = "spawn",
                    execution_mode = spec.execution_mode or "BLOCKING",
                    child = child,
                }
            )
            if applied_record == nil then
                for rollback_index = #applied, 1, -1 do
                    self:RemoveRuntime(
                        tostring(applied[rollback_index].guid),
                        { reason = "spawn_profile_rollback" }
                    )
                end
                return false, apply_code
            end
            table.insert(applied, applied_record)
        elseif record.profile_id ~= nil
            and type(self.entity_registry.UpdateProfile) == "function" then
            self.entity_registry:UpdateProfile(record.guid, nil, nil)
        end
    end
    return true
end

function EntityProfileService.ApplyInherited(self, record, parent_record, options)
    if record == nil or parent_record == nil then
        return nil, EntityProfileService.ERROR_CODES.ENTITY_NOT_OWNED
    end
    options = type(options) == "table" and options or {}
    local profile_id = options.profile_id or record.profile_id or parent_record.profile_id
    local profile_version = options.profile_version
        or record.profile_version
        or parent_record.profile_version
    if profile_id == nil then
        return record
    end
    return self:Apply(
        record,
        profile_id,
        profile_version,
        {
            operation = options.operation or "spawn",
            execution_mode = options.execution_mode or "LIVE_SAFE",
            child = true,
        }
    )
end

function EntityProfileService.GetProfile(self, target)
    local record = self:ValidateTarget(target)
    if record == nil then
        return nil
    end
    local runtime = self.applied_by_guid[tostring(record.guid)]
    if runtime ~= nil then
        return runtime.profile
    end
    if record.profile_id ~= nil then
        return self:Resolve(record.profile_id, record.profile_version)
    end
    return nil
end

function EntityProfileService.GetClientContract(self, profile_id, profile_version)
    local profile, code = self:Resolve(profile_id, profile_version)
    if profile == nil then
        return nil, code
    end
    return CopyData(profile.client_contract)
end

function EntityProfileService.GetDisplayState(self, target)
    local record, record_code = self:ValidateTarget(target)
    if record == nil then
        return nil, record_code
    end
    local profile = self:GetProfile(record)
    if profile == nil then
        return nil, EntityProfileService.ERROR_CODES.UNKNOWN_PROFILE
    end
    return
    {
        entity_guid = tostring(record.guid),
        instance_id = self.instance_id,
        prefab = record.prefab,
        profile_id = profile.profile_id,
        profile_version = profile.version,
        replication_mode = profile.replication_mode,
        client_contract = CopyData(profile.client_contract),
        metadata = CopyData(profile.metadata),
    }
end

function EntityProfileService.GetSnapshot(self)
    local profiles = {}
    for index = 1, #self.applied_order do
        local runtime = self.applied_by_guid[self.applied_order[index]]
        if runtime ~= nil then
            table.insert(
                profiles,
                {
                    entity_guid = runtime.guid,
                    instance_id = self.instance_id,
                    scope_id = runtime.record.scope_id,
                    prefab = runtime.record.prefab,
                    profile_id = runtime.profile_id,
                    profile_version = runtime.profile_version,
                    apply_mode = runtime.profile.apply_mode,
                    replication_mode = runtime.replication_mode,
                    client_contract = CopyData(runtime.profile.client_contract),
                    parent_entity_id = runtime.record.parent_entity_id,
                }
            )
        end
    end
    return
    {
        schema_version = EntityProfileService.SCHEMA_VERSION,
        instance_id = self.instance_id,
        count = #profiles,
        profiles = profiles,
    }
end

function EntityProfileService.Close(self)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    local all_closed = true
    for index = #self.applied_order, 1, -1 do
        local guid = self.applied_order[index]
        local removed, remove_code = self:RemoveRuntime(
            guid,
            { reason = "profile_service_closed" }
        )
        if not removed then
            all_closed = false
            self.last_close_code = remove_code
        end
    end
    self.closed = true
    if self.entity_registry ~= nil
        and self.entity_registry.profile_service == self then
        self.entity_registry.profile_service = nil
    end
    if all_closed then
        return true
    end
    return false, self.last_close_code or EntityProfileService.ERROR_CODES.ADAPTER_REMOVE_FAILED
end

function EntityProfileService.GetDebugString(self)
    return string.format(
        "entity_profile_service instance=%s closed=%s profiles=%d",
        tostring(self.instance_id),
        tostring(self.closed),
        #self.applied_order
    )
end

local function AttachMethods(service)
    service.Resolve = EntityProfileService.Resolve
    service.ResolveChildProfile = EntityProfileService.ResolveChildProfile
    service.ValidateTarget = EntityProfileService.ValidateTarget
    service.Apply = EntityProfileService.Apply
    service.ApplySpawn = EntityProfileService.ApplySpawn
    service.ApplyInherited = EntityProfileService.ApplyInherited
    service.Remove = EntityProfileService.Remove
    service.RemoveRuntime = EntityProfileService.RemoveRuntime
    service.OnEntityUnregistered = EntityProfileService.OnEntityUnregistered
    service.GetProfile = EntityProfileService.GetProfile
    service.GetClientContract = EntityProfileService.GetClientContract
    service.GetDisplayState = EntityProfileService.GetDisplayState
    service.GetSnapshot = EntityProfileService.GetSnapshot
    service.Close = EntityProfileService.Close
    service.GetDebugString = EntityProfileService.GetDebugString
    return service
end

function EntityProfileService.New(instance, services, options)
    options = type(options) == "table" and options or {}
    local instance_id = GetInstanceId(instance)
    if not IsNonEmptyString(instance_id)
        or type(instance) ~= "table"
        or type(instance.entity_registry) ~= "table"
        or type(options.profile_registry) ~= "table" then
        return nil, EntityProfileService.ERROR_CODES.REGISTRY_UNAVAILABLE
    end
    local service = AttachMethods(
    {
        schema_version = EntityProfileService.SCHEMA_VERSION,
        service_id = EntityProfileService.SERVICE_ID,
        service_version = EntityProfileService.SERVICE_VERSION,
        instance = instance,
        instance_id = instance_id,
        services = services or {},
        ERROR_CODES = EntityProfileService.ERROR_CODES,
        profile_registry = options.profile_registry,
        entity_registry = instance.entity_registry,
        applied_by_guid = {},
        applied_order = {},
        closed = false,
        last_close_code = nil,
    })
    instance.entity_registry.profile_service = service
    return service
end

return EntityProfileService
