-- WP2/WP3：单局 Instance 的生命周期、资源隔离和场景状态。

local ResourceScope = require("agon/core/resource_scope")
local EntityRegistry = require("agon/core/entity_registry")
local InstanceRng = require("agon/core/instance_rng")
local ParticipantGroup = require("agon/core/participant_group")

local Instance = {}

Instance.SCHEMA_VERSION = 1

Instance.STATES =
{
    CREATED = "CREATED",
    PREPARING = "PREPARING",
    RUNNING = "RUNNING",
    TRANSITION = "TRANSITION",
    FINISHING = "FINISHING",
    DESTROYING = "DESTROYING",
    DESTROYED = "DESTROYED",
    FAILED = "FAILED",
    RECOVERING = "RECOVERING",
}

Instance.TRANSITIONS =
{
    CREATED = { PREPARING = true, FAILED = true, DESTROYING = true },
    PREPARING = { RUNNING = true, FINISHING = true, FAILED = true, DESTROYING = true },
    RUNNING = { TRANSITION = true, FINISHING = true, FAILED = true },
    TRANSITION = { RUNNING = true, FINISHING = true, FAILED = true },
    FINISHING = { DESTROYING = true, FAILED = true },
    DESTROYING = { DESTROYED = true },
    DESTROYED = {},
    FAILED = { DESTROYING = true },
    RECOVERING = { DESTROYING = true, FAILED = true },
}

Instance.ERROR_CODES =
{
    INVALID_INSTANCE = "INVALID_INSTANCE",
    INVALID_INSTANCE_ID = "INVALID_INSTANCE_ID",
    INVALID_MODE = "INVALID_MODE",
    LIFECYCLE_TRANSITION_INVALID = "LIFECYCLE_TRANSITION_INVALID",
    MODE_RUNTIME_FAILED = "MODE_RUNTIME_FAILED",
    MODE_RUNTIME_REJECTED = "MODE_RUNTIME_REJECTED",
    ALREADY_DESTROYED = "ALREADY_DESTROYED",
    SCOPE_NOT_READY = "SCOPE_NOT_READY",
    SCENE_SERVICE_NOT_READY = "SCENE_SERVICE_NOT_READY",
}

local function IsInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function CopyValue(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    for key, item in pairs(value) do
        if type(item) ~= "function" then
            copied[key] = CopyValue(item)
        end
    end
    return copied
end

local function GetNow(self)
    if type(self.now_fn) == "function" then
        return self.now_fn()
    end
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

local function ProtectedCall(fn, ...)
    return pcall(fn, ...)
end

local function InvokeModeCallback(self, callback_name, ...)
    if self.mode_runtime == nil then
        return true
    end
    local callback = self.mode_runtime[callback_name]
    if type(callback) ~= "function" then
        return true
    end

    local ok, result, callback_code = ProtectedCall(callback, self.mode_runtime, ...)
    if not ok then
        return false, Instance.ERROR_CODES.MODE_RUNTIME_FAILED, tostring(result)
    end
    if result == false then
        return false,
            callback_code or Instance.ERROR_CODES.MODE_RUNTIME_REJECTED,
            "mode callback rejected: " .. callback_name
    end
    return true
end

function Instance.GetId(self)
    return self.instance_id
end

function Instance.GetModeId(self)
    return self.mode_id
end

function Instance.GetZoneId(self)
    return self.zone_id
end

function Instance.GetLifecycleState(self)
    return self.lifecycle_state
end

function Instance.GetGeneration(self)
    return self.generation
end

function Instance.GetZone(self)
    return self.zone
end

function Instance.GetRootScope(self)
    return self.root_scope
end

function Instance.GetEntityRegistry(self)
    return self.entity_registry
end

function Instance.GetRng(self)
    return self.rng
end

function Instance.GetRulePolicy(self)
    return self.rule_policy
end

function Instance.GetService(self, service_id)
    if type(service_id) ~= "string" or self.services == nil then
        return nil
    end
    return self.services[service_id]
end

function Instance.ListServices(self)
    local services = {}
    for index = 1, #(self.service_order or {}) do
        local service_id = self.service_order[index]
        if self.services[service_id] ~= nil then
            table.insert(services, service_id)
        end
    end
    return services
end

function Instance.InitializeServices(self, service_registry, declarations, options)
    if self.services_initialized then
        return true, "ALREADY_INITIALIZED"
    end
    if service_registry == nil or type(service_registry.CreateForInstance) ~= "function" then
        return false, Instance.ERROR_CODES.SCOPE_NOT_READY
    end
    local services, service_order, service_versions, service_code = service_registry:CreateForInstance(
        self,
        declarations,
        options
    )
    if services == nil then
        return false, service_code or service_order
    end
    self.service_registry = service_registry
    self.services = services
    self.service_order = service_order
    self.service_versions = service_versions
    self.services_initialized = true
    self.services_closed = false
    return true
end

function Instance.CloseServices(self, reason)
    if self.services_closed then
        return true, "ALREADY_CLOSED"
    end
    local all_closed = true
    for index = #(self.service_order or {}), 1, -1 do
        local service = self.services[self.service_order[index]]
        if service ~= nil and type(service.Close) == "function" then
            local ok, closed = pcall(service.Close, service, reason or "instance_services_closed")
            if not ok or closed == false then
                all_closed = false
            end
        end
    end
    self.services_closed = true
    if all_closed then
        return true
    end
    return false, Instance.ERROR_CODES.SCOPE_NOT_READY
end

function Instance.GetGroup(self, group_id)
    if type(group_id) ~= "string" then
        return nil
    end
    return self.participant_groups[group_id]
end

function Instance.ListGroups(self)
    local groups = {}
    for index = 1, #(self.participant_group_order or {}) do
        local group = self.participant_groups[self.participant_group_order[index]]
        if group ~= nil then
            table.insert(groups, group)
        end
    end
    return groups
end

function Instance.CreateGroup(self, group_type, members, options)
    if self.lifecycle_state == Instance.STATES.DESTROYED
        or self.lifecycle_state == Instance.STATES.FAILED then
        return nil, Instance.ERROR_CODES.LIFECYCLE_TRANSITION_INVALID
    end
    options = type(options) == "table" and options or {}
    self.next_group_sequence = self.next_group_sequence + 1
    local group_id = options.group_id
        or self.instance_id .. ":group:" .. tostring(self.next_group_sequence)
    if self.participant_groups[group_id] ~= nil then
        return nil, ParticipantGroup.ERROR_CODES.INVALID_GROUP_ID
    end
    local group_options = {}
    for key, value in pairs(options) do
        group_options[key] = value
    end
    group_options.members = members or options.members or {}
    group_options.generation = options.generation or self.generation
    local group, group_code = ParticipantGroup.New(
        self,
        group_id,
        group_type,
        group_options
    )
    if group == nil then
        return nil, group_code
    end
    self.participant_groups[group_id] = group
    table.insert(self.participant_group_order, group_id)
    return group
end

function Instance.RemoveGroup(self, group_id, reason)
    local group = self:GetGroup(group_id)
    if group == nil then
        return false, ParticipantGroup.ERROR_CODES.MEMBER_NOT_FOUND
    end
    local closed, close_code = group:Close(reason or "group_removed")
    if not closed then
        return false, close_code
    end
    self.participant_groups[group_id] = nil
    for index = 1, #self.participant_group_order do
        if self.participant_group_order[index] == group_id then
            table.remove(self.participant_group_order, index)
            break
        end
    end
    return true
end

function Instance.CloseGroups(self, reason)
    local all_closed = true
    for index = #self.participant_group_order, 1, -1 do
        local group_id = self.participant_group_order[index]
        local group = self.participant_groups[group_id]
        if group ~= nil then
            local closed = group:Close(reason or "instance_groups_closed")
            if not closed then
                all_closed = false
            end
            self.participant_groups[group_id] = nil
        end
    end
    self.participant_group_order = {}
    if all_closed then
        return true
    end
    return false, ParticipantGroup.ERROR_CODES.GROUP_CLOSED
end

function Instance.GetParticipant(self, userid)
    if userid == nil then
        return nil
    end
    return self.participants[tostring(userid)]
end

function Instance.ListParticipants(self)
    local participants = {}
    for index = 1, #self.participant_order do
        local participant = self.participants[self.participant_order[index]]
        if participant ~= nil then
            table.insert(participants, participant)
        end
    end
    return participants
end

function Instance.GetParticipantGroupIds(self, userid)
    local participant = self:GetParticipant(userid)
    if participant == nil then
        return {}
    end
    if type(participant.GetGroupIds) == "function" then
        return participant:GetGroupIds()
    end
    return participant.group_ids or {}
end

function Instance.InheritEntity(self, child, parent, options)
    if self.spawn_service ~= nil and type(self.spawn_service.Inherit) == "function" then
        return self.spawn_service:Inherit(self, child, parent, options)
    end
    if self.rule_policy ~= nil and type(self.rule_policy.PropagateMembership) == "function" then
        return self.rule_policy:PropagateMembership(child, parent, options)
    end
    return nil, Instance.ERROR_CODES.SCENE_SERVICE_NOT_READY
end

function Instance.CreateScope(self, name)
    if self.root_scope == nil then
        return nil, Instance.ERROR_CODES.SCOPE_NOT_READY
    end
    return self.root_scope:CreateChild(name)
end

function Instance.DoTaskInTime(self, time, callback, ...)
    if self.root_scope == nil or self.resource_owner == nil then
        return nil, Instance.ERROR_CODES.SCOPE_NOT_READY
    end
    return self.root_scope:DoTaskInTime(self.resource_owner, time, callback, ...)
end

function Instance.DoPeriodicTask(self, period, callback, initial_delay, ...)
    if self.root_scope == nil or self.resource_owner == nil then
        return nil, Instance.ERROR_CODES.SCOPE_NOT_READY
    end
    return self.root_scope:DoPeriodicTask(
        self.resource_owner,
        period,
        callback,
        initial_delay,
        ...
    )
end

function Instance.ListenForEvent(self, event, callback, source, cleanup_policy, label)
    if self.root_scope == nil or self.resource_owner == nil then
        return nil, Instance.ERROR_CODES.SCOPE_NOT_READY
    end
    return self.root_scope:ListenForEvent(
        self.resource_owner,
        event,
        callback,
        source,
        cleanup_policy,
        label
    )
end

function Instance.Spawn(self, spec, scope)
    if self.spawn_service == nil then
        return nil, Instance.ERROR_CODES.SCENE_SERVICE_NOT_READY
    end
    return self.spawn_service:Spawn(self, spec, scope)
end

function Instance.ApplyScenePlan(self, plan)
    if self.scene_service == nil then
        return false, Instance.ERROR_CODES.SCENE_SERVICE_NOT_READY
    end
    return self.scene_service:ApplyPlan(self, plan)
end

function Instance.Validate(self)
    if self.scene_service ~= nil then
        return self.scene_service:Validate(self)
    end
    return self.entity_registry:Validate()
end

function Instance.IsDestroyed(self)
    return self.lifecycle_state == Instance.STATES.DESTROYED
end

function Instance.IsFailed(self)
    return self.lifecycle_state == Instance.STATES.FAILED
end

function Instance.CanTransition(self, next_state)
    local transitions = Instance.TRANSITIONS[self.lifecycle_state]
    return transitions ~= nil and transitions[next_state] == true
end

function Instance.TransitionTo(self, next_state, reason, now)
    if self.lifecycle_state == next_state then
        return true, "ALREADY_IN_STATE"
    end
    if not Instance.TRANSITIONS[self.lifecycle_state]
        or not self:CanTransition(next_state) then
        return false, Instance.ERROR_CODES.LIFECYCLE_TRANSITION_INVALID
    end

    self.lifecycle_state = next_state
    self.generation = self.generation + 1
    self.state_entered_at = now ~= nil and now or GetNow(self)
    self.last_transition_reason = reason ~= nil and tostring(reason) or nil
    for index = 1, #self.participant_order do
        local participant = self.participants[self.participant_order[index]]
        if participant ~= nil and type(participant.SetInstanceGeneration) == "function" then
            participant:SetInstanceGeneration(self.generation)
        end
    end
    return true
end

function Instance.CreateModeRuntime(self)
    if self.mode_runtime ~= nil then
        return true
    end
    if self.definition == nil or type(self.definition.CreateRuntime) ~= "function" then
        return false, Instance.ERROR_CODES.INVALID_MODE
    end

    local ok, runtime, callback_code = ProtectedCall(
        self.definition.CreateRuntime,
        self,
        self.services
    )
    if not ok then
        return false, Instance.ERROR_CODES.MODE_RUNTIME_FAILED, tostring(runtime)
    end
    if runtime == nil then
        return false, callback_code or Instance.ERROR_CODES.MODE_RUNTIME_REJECTED
    end
    self.mode_runtime = runtime
    return true
end

function Instance.Prepare(self, reason)
    if self.lifecycle_state == Instance.STATES.PREPARING then
        return true
    end
    if self.lifecycle_state ~= Instance.STATES.CREATED then
        return false, Instance.ERROR_CODES.LIFECYCLE_TRANSITION_INVALID
    end

    local transitioned, transition_code = self:TransitionTo(
        Instance.STATES.PREPARING,
        reason or "prepare"
    )
    if not transitioned then
        return false, transition_code
    end

    local runtime_created, runtime_code = self:CreateModeRuntime()
    if not runtime_created then
        self:Fail("mode_runtime_create_failed")
        return false, runtime_code
    end

    local prepared, prepare_code = InvokeModeCallback(self, "OnPrepare", reason)
    if not prepared then
        self:Fail("mode_prepare_failed")
        return false, prepare_code
    end
    return true
end

function Instance.Start(self, reason)
    if self.lifecycle_state == Instance.STATES.RUNNING then
        return true, "ALREADY_STARTED"
    end
    if self.lifecycle_state ~= Instance.STATES.PREPARING then
        return false, Instance.ERROR_CODES.LIFECYCLE_TRANSITION_INVALID
    end

    local started, start_code = InvokeModeCallback(self, "OnStart", reason)
    if not started then
        self:Fail("mode_start_failed")
        return false, start_code
    end

    return self:TransitionTo(Instance.STATES.RUNNING, reason or "start")
end

function Instance.BeginTransition(self, reason)
    return self:TransitionTo(Instance.STATES.TRANSITION, reason or "transition")
end

function Instance.CompleteTransition(self, reason)
    return self:TransitionTo(Instance.STATES.RUNNING, reason or "transition_complete")
end

function Instance.Finish(self, reason)
    if self.lifecycle_state == Instance.STATES.FINISHING then
        return true
    end
    if self.lifecycle_state == Instance.STATES.DESTROYING
        or self.lifecycle_state == Instance.STATES.DESTROYED
        or self.lifecycle_state == Instance.STATES.FAILED then
        return true
    end
    if self.lifecycle_state ~= Instance.STATES.PREPARING
        and self.lifecycle_state ~= Instance.STATES.RUNNING
        and self.lifecycle_state ~= Instance.STATES.TRANSITION then
        return false, Instance.ERROR_CODES.LIFECYCLE_TRANSITION_INVALID
    end

    local transitioned, transition_code = self:TransitionTo(
        Instance.STATES.FINISHING,
        reason or "finish"
    )
    if not transitioned then
        return false, transition_code
    end

    local finished, finish_code = InvokeModeCallback(self, "OnFinish", reason)
    self.finish_called = true
    if not finished then
        self:Fail("mode_finish_failed")
        return false, finish_code
    end
    return true
end

function Instance.Fail(self, reason)
    if self.lifecycle_state == Instance.STATES.FAILED then
        return true
    end
    if self:IsDestroyed() or self.lifecycle_state == Instance.STATES.DESTROYING then
        return false, Instance.ERROR_CODES.LIFECYCLE_TRANSITION_INVALID
    end
    local transitioned, code = self:TransitionTo(
        Instance.STATES.FAILED,
        reason or "failed"
    )
    if transitioned then
        self.failure_reason = reason ~= nil and tostring(reason) or "unspecified"
    end
    return transitioned, code
end

function Instance.BeginDestroy(self, reason)
    if self:IsDestroyed() then
        return false, Instance.ERROR_CODES.ALREADY_DESTROYED
    end
    if self.lifecycle_state == Instance.STATES.DESTROYING then
        return true
    end

    if self.lifecycle_state ~= Instance.STATES.FAILED
        and self.lifecycle_state ~= Instance.STATES.FINISHING then
        local finished, finish_code = self:Finish(reason or "destroy")
        if not finished then
            self:Fail("destroy_finish_failed")
            if self.lifecycle_state ~= Instance.STATES.FAILED then
                return false, finish_code
            end
        end
    end

    local transitioned, transition_code = self:TransitionTo(
        Instance.STATES.DESTROYING,
        reason or "destroy"
    )
    if not transitioned then
        return false, transition_code
    end

    if not self.destroy_called then
        local destroyed, destroy_code = InvokeModeCallback(self, "OnDestroy", reason)
        self.destroy_called = true
        if not destroyed then
            return false, destroy_code
        end
    end
    return true
end

function Instance.FinalizeDestroy(self, reason)
    if self:IsDestroyed() then
        return true, Instance.ERROR_CODES.ALREADY_DESTROYED
    end
    if self.lifecycle_state ~= Instance.STATES.DESTROYING then
        return false, Instance.ERROR_CODES.LIFECYCLE_TRANSITION_INVALID
    end
    return self:TransitionTo(Instance.STATES.DESTROYED, reason or "destroyed")
end

function Instance.GetSnapshot(self)
    local snapshot =
    {
        schema_version = Instance.SCHEMA_VERSION,
        instance_id = self.instance_id,
        mode_id = self.mode_id,
        mode_version = self.mode_version,
        zone_id = self.zone_id,
        lifecycle_state = self.lifecycle_state,
        created_at = self.created_at,
        state_entered_at = self.state_entered_at,
        generation = self.generation,
        scene_revision = self.scene_revision,
        failure_reason = self.failure_reason,
        result = CopyValue(self.result),
        scene_plan = CopyValue(self.scene_plan),
        scene_transactions = {},
        participants = {},
        groups = {},
        services = {},
        service_order = CopyValue(self.service_order),
        service_versions = CopyValue(self.service_versions),
        rng = self.rng ~= nil and self.rng:GetSnapshot() or nil,
    }

    for index = 1, #self.participant_order do
        local participant = self.participants[self.participant_order[index]]
        if participant ~= nil then
            table.insert(snapshot.participants, participant:GetSnapshot())
        end
    end

    for index = 1, #(self.participant_group_order or {}) do
        local group = self.participant_groups[self.participant_group_order[index]]
        if group ~= nil then
            table.insert(snapshot.groups, group:GetSnapshot())
        end
    end

    for index = 1, #(self.service_order or {}) do
        local service_id = self.service_order[index]
        local service = self.services[service_id]
        if service ~= nil and type(service.GetSnapshot) == "function" then
            local ok, service_snapshot = pcall(service.GetSnapshot, service)
            if ok and type(service_snapshot) == "table" then
                snapshot.services[service_id] = service_snapshot
            end
        end
    end

    if self.scene_service ~= nil then
        local scene_snapshot = self.scene_service:GetSnapshot(self)
        if type(scene_snapshot) == "table" then
            snapshot.scene = scene_snapshot
        end
    else
        snapshot.scope = self.root_scope ~= nil and self.root_scope:GetSnapshot() or nil
        snapshot.entities = self.entity_registry ~= nil
            and self.entity_registry:GetSnapshot()
            or nil
    end

    if self.mode_runtime ~= nil and type(self.mode_runtime.OnSave) == "function" then
        local ok, mode_state = ProtectedCall(self.mode_runtime.OnSave, self.mode_runtime)
        if ok and type(mode_state) == "table" then
            snapshot.mode_state = CopyValue(mode_state)
        end
    end
    return snapshot
end

function Instance.GetDebugData(self, zone_state)
    local data = self:GetSnapshot()
    data.zone_state = zone_state
    return data
end

local function AttachMethods(instance)
    instance.GetId = Instance.GetId
    instance.GetModeId = Instance.GetModeId
    instance.GetZoneId = Instance.GetZoneId
    instance.GetZone = Instance.GetZone
    instance.GetLifecycleState = Instance.GetLifecycleState
    instance.GetGeneration = Instance.GetGeneration
    instance.GetRootScope = Instance.GetRootScope
    instance.GetEntityRegistry = Instance.GetEntityRegistry
    instance.GetRng = Instance.GetRng
    instance.GetRulePolicy = Instance.GetRulePolicy
    instance.GetService = Instance.GetService
    instance.ListServices = Instance.ListServices
    instance.InitializeServices = Instance.InitializeServices
    instance.CloseServices = Instance.CloseServices
    instance.GetGroup = Instance.GetGroup
    instance.ListGroups = Instance.ListGroups
    instance.CreateGroup = Instance.CreateGroup
    instance.RemoveGroup = Instance.RemoveGroup
    instance.CloseGroups = Instance.CloseGroups
    instance.GetParticipant = Instance.GetParticipant
    instance.ListParticipants = Instance.ListParticipants
    instance.GetParticipantGroupIds = Instance.GetParticipantGroupIds
    instance.InheritEntity = Instance.InheritEntity
    instance.CreateScope = Instance.CreateScope
    instance.DoTaskInTime = Instance.DoTaskInTime
    instance.DoPeriodicTask = Instance.DoPeriodicTask
    instance.ListenForEvent = Instance.ListenForEvent
    instance.Spawn = Instance.Spawn
    instance.ApplyScenePlan = Instance.ApplyScenePlan
    instance.Validate = Instance.Validate
    instance.IsDestroyed = Instance.IsDestroyed
    instance.IsFailed = Instance.IsFailed
    instance.CanTransition = Instance.CanTransition
    instance.TransitionTo = Instance.TransitionTo
    instance.CreateModeRuntime = Instance.CreateModeRuntime
    instance.Prepare = Instance.Prepare
    instance.Start = Instance.Start
    instance.BeginTransition = Instance.BeginTransition
    instance.CompleteTransition = Instance.CompleteTransition
    instance.Finish = Instance.Finish
    instance.Fail = Instance.Fail
    instance.BeginDestroy = Instance.BeginDestroy
    instance.FinalizeDestroy = Instance.FinalizeDestroy
    instance.GetSnapshot = Instance.GetSnapshot
    instance.GetDebugData = Instance.GetDebugData
    return instance
end

function Instance.New(instance_id, definition, zone, options)
    if not IsNonEmptyString(instance_id)
        or type(definition) ~= "table"
        or not IsNonEmptyString(definition.mode_id)
        or not IsInteger(definition.mode_version)
        or type(zone) ~= "table"
        or not IsNonEmptyString(zone.zone_id) then
        return nil, Instance.ERROR_CODES.INVALID_INSTANCE
    end

    options = type(options) == "table" and options or {}
    local now = type(options.now) == "number" and options.now or 0
    local instance =
    {
        schema_version = Instance.SCHEMA_VERSION,
        instance_id = instance_id,
        mode_id = definition.mode_id,
        mode_version = definition.mode_version,
        zone_id = zone.zone_id,
        zone = zone,
        lifecycle_state = Instance.STATES.CREATED,
        created_at = now,
        state_entered_at = now,
        generation = 1,
        participants = {},
        participant_order = {},
        participant_groups = {},
        participant_group_order = {},
        next_group_sequence = 0,
        services = {},
        service_order = {},
        service_versions = {},
        service_registry = nil,
        services_initialized = false,
        services_closed = false,
        scene_revision = 0,
        scene_plan = nil,
        scene_transactions = {},
        result = nil,
        failure_reason = nil,
        definition = definition,
        mode_runtime = nil,
        finish_called = false,
        destroy_called = false,
        now_fn = options.now_fn,
        resource_owner = options.owner,
        participant_manager = options.participant_manager,
        rule_policy = options.rule_policy,
    }
    local rng, rng_code = InstanceRng.New(options.seed or instance_id)
    if rng == nil then
        return nil, rng_code or Instance.ERROR_CODES.INVALID_INSTANCE
    end
    instance.rng = rng
    local root_scope, scope_code = ResourceScope.New(
    {
        instance_id = instance_id,
        scope_id = instance_id .. ":scope:root",
    })
    if root_scope == nil then
        return nil, scope_code or Instance.ERROR_CODES.SCOPE_NOT_READY
    end
    instance.root_scope = root_scope
    local entity_registry, registry_code = EntityRegistry.New(instance_id)
    if entity_registry == nil then
        root_scope:Close("entity_registry_failed")
        return nil, registry_code or Instance.ERROR_CODES.SCOPE_NOT_READY
    end
    instance.entity_registry = entity_registry
    return AttachMethods(instance)
end

return Instance
