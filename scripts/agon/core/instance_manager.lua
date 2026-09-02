-- WP2/WP3：创建、索引、场景切换和销毁 Instance；只有本模块推进主生命周期。

local Instance = require("agon/core/instance")
local Participant = require("agon/core/participant")
local RulePolicy = require("agon/core/rule_policy")
local CommonServiceRegistry = require("agon/services/common_service_registry")

local InstanceManager = {}
InstanceManager.SCHEMA_VERSION = 1
InstanceManager.RESTART_POLICY = "ABORT_ON_RESTART"

InstanceManager.ERROR_CODES =
{
    CORE_NOT_READY = "CORE_NOT_READY",
    INVALID_MODE = "INVALID_MODE",
    PARTICIPANTS_NOT_SUPPORTED = "PARTICIPANTS_NOT_SUPPORTED",
    INVALID_USERID = "INVALID_PARTICIPANT_USERID",
    PARTICIPANT_ALREADY_ACTIVE = "PARTICIPANT_ALREADY_ACTIVE",
    PARTICIPANT_NOT_FOUND = "PARTICIPANT_NOT_FOUND",
    PARTICIPANT_INSTANCE_MISMATCH = "PARTICIPANT_INSTANCE_MISMATCH",
    NO_FREE_ZONE = "NO_FREE_ZONE",
    INSTANCE_CREATE_FAILED = "INSTANCE_CREATE_FAILED",
    INSTANCE_NOT_FOUND = "INSTANCE_NOT_FOUND",
    INSTANCE_ALREADY_DESTROYED = "ALREADY_DESTROYED",
    INSTANCE_DESTROY_FAILED = "INSTANCE_DESTROY_FAILED",
    INVALID_INSTANCE_SNAPSHOT = "INVALID_INSTANCE_SNAPSHOT",
    INVALID_SEQUENCE = "INVALID_SEQUENCE",
    INSTANCE_INVARIANT_FAILED = "INSTANCE_INVARIANT_FAILED",
    SCENE_APPLY_FAILED = "SCENE_APPLY_FAILED",
    SCENE_RESET_FAILED = "SCENE_RESET_FAILED",
}

local function IsInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function AttachMethods(manager)
    manager.Get = InstanceManager.Get
    manager.List = InstanceManager.List
    manager.Count = InstanceManager.Count
    manager.Create = InstanceManager.Create
    manager.Start = InstanceManager.Start
    manager.ApplyScene = InstanceManager.ApplyScene
    manager.Transition = InstanceManager.Transition
    manager.Fail = InstanceManager.Fail
    manager.Destroy = InstanceManager.Destroy
    manager.GetSummary = InstanceManager.GetSummary
    manager.GetSnapshot = InstanceManager.GetSnapshot
    manager.OnLoad = InstanceManager.OnLoad
    manager.Validate = InstanceManager.Validate
    manager.GetDebugLines = InstanceManager.GetDebugLines
    manager.GetInstanceDebugData = InstanceManager.GetInstanceDebugData
    manager.GetParticipant = InstanceManager.GetParticipant
    manager.GetParticipantInstanceId = InstanceManager.GetParticipantInstanceId
    manager.AddParticipant = InstanceManager.AddParticipant
    manager.AttachPlayer = InstanceManager.AttachPlayer
    manager.MarkDisconnected = InstanceManager.MarkDisconnected
    manager.RemoveParticipant = InstanceManager.RemoveParticipant
    manager.ResolveInstance = InstanceManager.ResolveInstance
    manager.ResolveRootOwner = InstanceManager.ResolveRootOwner
    manager.CanInteract = InstanceManager.CanInteract
    return manager
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

function InstanceManager.New(options)
    if type(options) ~= "table"
        or type(options.zone_manager) ~= "table"
        or type(options.mode_registry) ~= "table" then
        return nil, InstanceManager.ERROR_CODES.CORE_NOT_READY
    end

    local shard_id = options.shard_id
    if not IsNonEmptyString(shard_id) then
        shard_id = "unknown"
    end

    local next_sequence = options.next_sequence or 0
    if not IsInteger(next_sequence) or next_sequence < 0 then
        return nil, InstanceManager.ERROR_CODES.INVALID_SEQUENCE
    end

    local manager =
    {
        schema_version = InstanceManager.SCHEMA_VERSION,
        restart_policy = InstanceManager.RESTART_POLICY,
        shard_id = shard_id,
        next_sequence = next_sequence,
        zone_manager = options.zone_manager,
        mode_registry = options.mode_registry,
        scene_service = options.scene_service,
        world = options.world,
        now_fn = options.now_fn,
        common_service_registry = options.common_service_registry
            or CommonServiceRegistry.New(),
        instances_by_id = {},
        instance_order = {},
        destroyed_ids = {},
        restart_aborted_count = 0,
        participants_by_userid = {},
    }
    manager.rule_policy = RulePolicy.New(
    {
        participant_index = manager.participants_by_userid,
        instance_lookup = function(instance_id)
            return manager.instances_by_id[instance_id]
        end,
    })
    return AttachMethods(manager)
end

function InstanceManager.Get(self, instance_id)
    if not IsNonEmptyString(instance_id) then
        return nil
    end
    return self.instances_by_id[instance_id]
end

function InstanceManager.List(self)
    local instances = {}
    for index = 1, #self.instance_order do
        local instance = self.instances_by_id[self.instance_order[index]]
        if instance ~= nil then
            table.insert(instances, instance)
        end
    end
    return instances
end

function InstanceManager.Count(self)
    local count = 0
    for index = 1, #self.instance_order do
        if self.instances_by_id[self.instance_order[index]] ~= nil then
            count = count + 1
        end
    end
    return count
end

function InstanceManager.GetParticipant(self, userid)
    if not IsNonEmptyString(userid) then
        return nil
    end
    return self.participants_by_userid[userid]
end

function InstanceManager.GetParticipantInstanceId(self, userid)
    local participant = self:GetParticipant(userid)
    return participant ~= nil and participant.instance_id or nil
end

function InstanceManager.AddParticipant(self, instance_id, userid, options)
    if not IsNonEmptyString(instance_id) or not IsNonEmptyString(userid) then
        return nil, InstanceManager.ERROR_CODES.INVALID_USERID
    end
    local instance = self:Get(instance_id)
    if instance == nil then
        return nil, InstanceManager.ERROR_CODES.INSTANCE_NOT_FOUND
    end
    if instance:IsDestroyed() or instance.lifecycle_state == Instance.STATES.FAILED then
        return nil, InstanceManager.ERROR_CODES.PARTICIPANT_INSTANCE_MISMATCH
    end

    local existing = self.participants_by_userid[userid]
    if existing ~= nil then
        return nil, InstanceManager.ERROR_CODES.PARTICIPANT_ALREADY_ACTIVE
    end
    if instance.participants[userid] ~= nil then
        return nil, InstanceManager.ERROR_CODES.PARTICIPANT_ALREADY_ACTIVE
    end

    options = type(options) == "table" and options or {}
    local participant, participant_code = Participant.New(
        userid,
        instance_id,
        {
            generation = instance.generation,
            joined_at = options.joined_at or GetNow(self),
            now_fn = self.now_fn,
            role = options.role,
            group_ids = options.group_ids,
            player_ref = options.player_ref,
        }
    )
    if participant == nil then
        return nil, participant_code or InstanceManager.ERROR_CODES.INVALID_USERID
    end
    instance.participants[userid] = participant
    table.insert(instance.participant_order, userid)
    self.participants_by_userid[userid] = participant
    return participant
end

function InstanceManager.AttachPlayer(self, instance_id, userid, player)
    if not IsNonEmptyString(instance_id) or not IsNonEmptyString(userid) then
        return false, InstanceManager.ERROR_CODES.INVALID_USERID
    end
    local instance = self:Get(instance_id)
    local participant = self:GetParticipant(userid)
    if instance == nil or participant == nil
        or participant.instance_id ~= instance_id then
        return false, InstanceManager.ERROR_CODES.PARTICIPANT_NOT_FOUND
    end
    local attached, attach_code = participant:AttachPlayer(
        player,
        instance.generation,
        GetNow(self)
    )
    if not attached then
        return false, attach_code
    end
    return true
end

function InstanceManager.MarkDisconnected(self, userid, reason)
    local participant = self:GetParticipant(userid)
    if participant == nil then
        return false, InstanceManager.ERROR_CODES.PARTICIPANT_NOT_FOUND
    end
    local instance = self:Get(participant.instance_id)
    local generation = instance ~= nil and instance.generation or participant.generation
    return participant:MarkDisconnected(reason, generation, GetNow(self))
end

function InstanceManager.RemoveParticipant(self, instance_id, userid, reason)
    local instance = self:Get(instance_id)
    local participant = self:GetParticipant(userid)
    if instance == nil or participant == nil
        or participant.instance_id ~= instance_id then
        return false, InstanceManager.ERROR_CODES.PARTICIPANT_NOT_FOUND
    end
    local left, left_code = participant:MarkLeft(
        reason or "participant_removed",
        instance.generation,
        GetNow(self)
    )
    if not left then
        return false, left_code
    end
    instance.participants[userid] = nil
    for index = 1, #instance.participant_order do
        if instance.participant_order[index] == userid then
            table.remove(instance.participant_order, index)
            break
        end
    end
    if self.participants_by_userid[userid] == participant then
        self.participants_by_userid[userid] = nil
    end
    return true
end

function InstanceManager.ResolveInstance(self, subject)
    return self.rule_policy:ResolveInstance(subject)
end

function InstanceManager.ResolveRootOwner(self, entity)
    return self.rule_policy:ResolveRootOwner(entity)
end

function InstanceManager.CanInteract(self, action, source, target, options)
    return self.rule_policy:CanInteract(action, source, target, options)
end

local function RemoveFromOrder(self, instance_id)
    for index = 1, #self.instance_order do
        if self.instance_order[index] == instance_id then
            table.remove(self.instance_order, index)
            return
        end
    end
end

local function NormalizeUserids(userids)
    if userids == nil then
        return {}
    end
    if type(userids) ~= "table" then
        return nil, InstanceManager.ERROR_CODES.PARTICIPANTS_NOT_SUPPORTED
    end

    local normalized = {}
    local seen = {}
    for index = 1, #userids do
        local userid = userids[index]
        if not IsNonEmptyString(userid) then
            return nil, InstanceManager.ERROR_CODES.INVALID_USERID
        end
        if seen[userid] then
            return nil, InstanceManager.ERROR_CODES.PARTICIPANT_ALREADY_ACTIVE
        end
        seen[userid] = true
        table.insert(normalized, userid)
    end
    return normalized
end

local function RemoveInstanceParticipants(self, instance)
    local userids = {}
    for index = 1, #instance.participant_order do
        userids[index] = instance.participant_order[index]
    end
    for index = #userids, 1, -1 do
        self:RemoveParticipant(instance.instance_id, userids[index], "instance_create_rollback")
    end
end

function InstanceManager.Create(self, mode_id, userids)
    if type(self.zone_manager) ~= "table"
        or type(self.mode_registry) ~= "table" then
        return nil, InstanceManager.ERROR_CODES.CORE_NOT_READY
    end
    if not IsNonEmptyString(mode_id) then
        return nil, InstanceManager.ERROR_CODES.INVALID_MODE
    end
    local requested_userids, userids_code = NormalizeUserids(userids)
    if requested_userids == nil then
        return nil, userids_code
    end
    for index = 1, #requested_userids do
        if self.participants_by_userid[requested_userids[index]] ~= nil then
            return nil, InstanceManager.ERROR_CODES.PARTICIPANT_ALREADY_ACTIVE
        end
    end

    local definition = self.mode_registry:Get(mode_id)
    if definition == nil then
        return nil, InstanceManager.ERROR_CODES.INVALID_MODE
    end

    -- 先消耗序列再尝试 reservation，失败的创建也不会复用已经暴露过的 ID。
    self.next_sequence = self.next_sequence + 1
    local instance_id = "agon:" .. self.shard_id .. ":" .. tostring(self.next_sequence)
    local zone, zone_code = self.zone_manager:Reserve(
        definition.zone_category,
        instance_id
    )
    if zone == nil then
        return nil, zone_code or InstanceManager.ERROR_CODES.NO_FREE_ZONE
    end

    local instance, instance_code = Instance.New(
        instance_id,
        definition,
        zone,
        {
            now = GetNow(self),
            now_fn = self.now_fn,
            owner = self.world,
            participant_manager = self,
            rule_policy = self.rule_policy,
        }
    )
    if instance == nil then
        self.zone_manager:ReleaseReservation(zone.zone_id, instance_id)
        return nil, instance_code or InstanceManager.ERROR_CODES.INSTANCE_CREATE_FAILED
    end

    local services_initialized, services_code = instance:InitializeServices(
        self.common_service_registry,
        definition.services,
        { now_fn = self.now_fn }
    )
    if not services_initialized then
        if instance.root_scope ~= nil and not instance.root_scope:IsClosed() then
            instance.root_scope:Close("service_create_failed")
        end
        self.zone_manager:ReleaseReservation(zone.zone_id, instance_id)
        return nil, services_code or InstanceManager.ERROR_CODES.INSTANCE_CREATE_FAILED
    end

    self.instances_by_id[instance_id] = instance
    table.insert(self.instance_order, instance_id)

    for index = 1, #requested_userids do
        local participant, participant_code = self:AddParticipant(
            instance_id,
            requested_userids[index]
        )
        if participant == nil then
            RemoveInstanceParticipants(self, instance)
            self.instances_by_id[instance_id] = nil
            RemoveFromOrder(self, instance_id)
            instance:CloseServices("participant_create_failed")
            instance:CloseGroups("participant_create_failed")
            instance.root_scope:Close("participant_create_failed")
            self.zone_manager:ReleaseReservation(zone.zone_id, instance_id)
            return nil, participant_code or InstanceManager.ERROR_CODES.INSTANCE_CREATE_FAILED
        end
    end

    if self.scene_service ~= nil then
        local attached, attach_code = self.scene_service:AttachInstance(instance)
        if not attached then
            RemoveInstanceParticipants(self, instance)
            self.instances_by_id[instance_id] = nil
            RemoveFromOrder(self, instance_id)
            instance:CloseServices("scene_attach_failed")
            instance:CloseGroups("scene_attach_failed")
            instance.root_scope:Close("scene_attach_failed")
            self.zone_manager:ReleaseReservation(zone.zone_id, instance_id)
            return nil, attach_code or InstanceManager.ERROR_CODES.INSTANCE_CREATE_FAILED
        end
    end

    local prepared, prepare_code = instance:Prepare("create")
    if not prepared then
        RemoveInstanceParticipants(self, instance)
        self.instances_by_id[instance_id] = nil
        RemoveFromOrder(self, instance_id)
        instance:CloseServices("prepare_failed")
        instance:CloseGroups("prepare_failed")
        if self.scene_service ~= nil then
            self.scene_service:DetachInstance(instance)
        end
        if instance.root_scope ~= nil and not instance.root_scope:IsClosed() then
            instance.root_scope:Close("prepare_failed")
        end
        local released, release_code = self.zone_manager:ReleaseReservation(
            zone.zone_id,
            instance_id
        )
        if not released then
            return nil, InstanceManager.ERROR_CODES.INSTANCE_CREATE_FAILED
                .. ":" .. tostring(release_code)
        end
        return nil, prepare_code or InstanceManager.ERROR_CODES.INSTANCE_CREATE_FAILED
    end

    return instance, "INSTANCE_CREATED"
end

function InstanceManager.Start(self, instance_id, reason)
    local instance = self:Get(instance_id)
    if instance == nil then
        return false, InstanceManager.ERROR_CODES.INSTANCE_NOT_FOUND
    end
    if instance.lifecycle_state == Instance.STATES.RUNNING then
        return instance:Start(reason or "start")
    end
    if instance.lifecycle_state ~= Instance.STATES.PREPARING then
        return false, Instance.ERROR_CODES.LIFECYCLE_TRANSITION_INVALID
    end

    -- Instance 进入 RUNNING 前，Zone 必须按顺序经过 BUILDING 和 ACTIVE。
    -- 若 mode 启动失败，无法证明 Zone 干净，故隔离而不是复用它。
    local building, building_code = self.zone_manager:BeginBuilding(
        instance.zone_id,
        instance.instance_id
    )
    if not building then
        return false, building_code
    end

    if self.scene_service ~= nil then
        local scene_built, scene_code = self.scene_service:ApplyModePlan(
            instance,
            "INITIAL",
            reason or "start"
        )
        if not scene_built then
            instance:Fail("initial_scene_failed")
            if not self.scene_service:Reset(instance, "initial_scene_failed") then
                self.zone_manager:Quarantine(
                    instance.zone_id,
                    instance.instance_id,
                    "initial_scene_reset_failed:" .. tostring(scene_code)
                )
            else
                self.zone_manager:Quarantine(
                    instance.zone_id,
                    instance.instance_id,
                    "initial_scene_failed:" .. tostring(scene_code)
                )
            end
            return false, scene_code or InstanceManager.ERROR_CODES.SCENE_APPLY_FAILED
        end
    end

    local started, start_code = instance:Start(reason or "start")
    if not started then
        if self.scene_service ~= nil then
            self.scene_service:Reset(instance, "instance_start_failed")
        end
        self.zone_manager:Quarantine(
            instance.zone_id,
            instance.instance_id,
            "instance_start_failed:" .. tostring(start_code)
        )
        return false, start_code
    end

    local active, active_code = self.zone_manager:Activate(
        instance.zone_id,
        instance.instance_id
    )
    if not active then
        instance:Fail("zone_activate_failed")
        if self.scene_service ~= nil then
            self.scene_service:Reset(instance, "zone_activate_failed")
        end
        self.zone_manager:Quarantine(
            instance.zone_id,
            instance.instance_id,
            "zone_activate_failed:" .. tostring(active_code)
        )
        return false, active_code
    end
    return true, start_code
end

function InstanceManager.ApplyScene(self, instance_id, plan_or_kind, reason)
    local instance = self:Get(instance_id)
    if instance == nil then
        return false, InstanceManager.ERROR_CODES.INSTANCE_NOT_FOUND
    end
    if self.scene_service == nil then
        return false, InstanceManager.ERROR_CODES.SCENE_APPLY_FAILED
    end

    local plan = plan_or_kind
    if type(plan_or_kind) == "string" then
        local built, build_code = self.scene_service:BuildPlan(
            instance,
            plan_or_kind,
            reason or "scene_apply"
        )
        if built == nil then
            return false, build_code
        end
        plan = built
    end
    if type(plan) ~= "table" then
        return false, InstanceManager.ERROR_CODES.SCENE_APPLY_FAILED
    end

    local blocking = plan.execution_mode == "BLOCKING"
    local transitioned = false
    if blocking and instance.lifecycle_state == Instance.STATES.RUNNING then
        local began, begin_code = instance:BeginTransition(reason or "scene_blocking")
        if not began then
            return false, begin_code
        end
        transitioned = true
    end

    local applied, apply_code, transaction = self.scene_service:ApplyPlan(instance, plan)
    if not applied then
        if transitioned and instance.lifecycle_state == Instance.STATES.TRANSITION then
            instance:CompleteTransition("scene_rollback")
        end
        return false, apply_code
    end
    if transitioned then
        local completed, complete_code = instance:CompleteTransition(reason or "scene_complete")
        if not completed then
            return false, complete_code
        end
    end
    return true, nil, transaction
end

function InstanceManager.Transition(self, instance_id, next_state, reason)
    local instance = self:Get(instance_id)
    if instance == nil then
        return false, InstanceManager.ERROR_CODES.INSTANCE_NOT_FOUND
    end
    return instance:TransitionTo(next_state, reason or "manager_transition")
end

function InstanceManager.Fail(self, instance_id, reason)
    local instance = self:Get(instance_id)
    if instance == nil then
        return false, InstanceManager.ERROR_CODES.INSTANCE_NOT_FOUND
    end
    return instance:Fail(reason or "manager_failure")
end

local function CleanupZone(self, instance)
    local zone = self.zone_manager:Get(instance.zone_id)
    if zone == nil then
        return false, "ZONE_NOT_FOUND"
    end
    if zone.reserved_instance_id ~= instance.instance_id then
        return false, "ZONE_OWNER_MISMATCH"
    end

    if zone.state == "RESERVED" then
        return self.zone_manager:ReleaseReservation(zone.zone_id, instance.instance_id)
    elseif zone.state == "BUILDING" or zone.state == "ACTIVE" then
        local resetting, resetting_code = self.zone_manager:BeginResetting(
            zone.zone_id,
            instance.instance_id,
            "instance_destroy"
        )
        if not resetting then
            return false, resetting_code
        end
        return self.zone_manager:Release(zone.zone_id, instance.instance_id)
    elseif zone.state == "RESETTING" then
        return self.zone_manager:Release(zone.zone_id, instance.instance_id)
    elseif zone.state == "QUARANTINED" then
        return false, "ZONE_QUARANTINED"
    end
    return false, "ZONE_STATE_INVALID"
end

function InstanceManager.Destroy(self, instance_id, reason)
    if self.destroyed_ids[instance_id] then
        return true, InstanceManager.ERROR_CODES.INSTANCE_ALREADY_DESTROYED
    end

    local instance = self:Get(instance_id)
    if instance == nil then
        return false, InstanceManager.ERROR_CODES.INSTANCE_NOT_FOUND
    end

    local destroying, destroying_code = instance:BeginDestroy(reason or "destroy")
    if not destroying then
        self.zone_manager:Quarantine(
            instance.zone_id,
            instance.instance_id,
            "mode_destroy_failed:" .. tostring(destroying_code)
        )
        return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
    end

    if self.scene_service ~= nil then
        local services_closed, services_code = instance:CloseServices(reason or "destroy")
        if not services_closed then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "service_cleanup_failed:" .. tostring(services_code)
            )
            return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
        end
        local groups_closed, groups_code = instance:CloseGroups(reason or "destroy")
        if not groups_closed then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "group_cleanup_failed:" .. tostring(groups_code)
            )
            return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
        end
        local reset, reset_code = self.scene_service:Reset(instance, reason or "destroy")
        if not reset then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "scene_reset_failed:" .. tostring(reset_code)
            )
            return false, InstanceManager.ERROR_CODES.SCENE_RESET_FAILED
        end
    else
        local services_closed, services_code = instance:CloseServices(reason or "destroy")
        if not services_closed then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "service_cleanup_failed:" .. tostring(services_code)
            )
            return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
        end
        local groups_closed, groups_code = instance:CloseGroups(reason or "destroy")
        if not groups_closed then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "group_cleanup_failed:" .. tostring(groups_code)
            )
            return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
        end
        if instance.root_scope ~= nil and not instance.root_scope:IsClosed() then
            local scope_closed, scope_code = instance.root_scope:Close(reason or "destroy")
            if not scope_closed then
                self.zone_manager:Quarantine(
                    instance.zone_id,
                    instance.instance_id,
                    "scope_cleanup_failed:" .. tostring(scope_code)
                )
                return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
            end
        end
    end

    local released, release_code = CleanupZone(self, instance)
    if not released then
        self.zone_manager:Quarantine(
            instance.zone_id,
            instance.instance_id,
            "zone_cleanup_failed:" .. tostring(release_code)
        )
        return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
    end

    local finalized, finalize_code = instance:FinalizeDestroy(reason or "destroyed")
    if not finalized then
        self.zone_manager:Quarantine(
            instance.zone_id,
            instance.instance_id,
            "instance_finalize_failed:" .. tostring(finalize_code)
        )
        return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
    end

    RemoveInstanceParticipants(self, instance)
    if self.audience_state_channel ~= nil
        and type(self.audience_state_channel.ClearInstance) == "function" then
        self.audience_state_channel:ClearInstance(instance_id)
    end
    self.instances_by_id[instance_id] = nil
    self.destroyed_ids[instance_id] = true
    RemoveFromOrder(self, instance_id)
    return true, "INSTANCE_DESTROYED"
end

function InstanceManager.GetSummary(self)
    local summary =
    {
        schema_version = self.schema_version,
        shard_id = self.shard_id,
        next_sequence = self.next_sequence,
        restart_policy = self.restart_policy,
        instance_count = 0,
        by_lifecycle = {},
        restart_aborted_count = self.restart_aborted_count,
    }
    for index = 1, #self.instance_order do
        local instance = self.instances_by_id[self.instance_order[index]]
        if instance ~= nil then
            summary.instance_count = summary.instance_count + 1
            local state = instance.lifecycle_state
            summary.by_lifecycle[state] = (summary.by_lifecycle[state] or 0) + 1
        end
    end
    return summary
end

function InstanceManager.GetSnapshot(self)
    local instances = {}
    for index = 1, #self.instance_order do
        local instance = self.instances_by_id[self.instance_order[index]]
        if instance ~= nil then
            table.insert(instances, instance:GetSnapshot())
        end
    end
    return
    {
        schema_version = self.schema_version,
        shard_id = self.shard_id,
        next_sequence = self.next_sequence,
        restart_policy = self.restart_policy,
        instances = instances,
    }
end

function InstanceManager.OnLoad(self, data)
    if data == nil then
        return true
    end
    if type(data) ~= "table"
        or data.schema_version ~= self.schema_version
        or not IsInteger(data.next_sequence)
        or data.next_sequence < 0
        or (data.instances ~= nil and type(data.instances) ~= "table") then
        return false, InstanceManager.ERROR_CODES.INVALID_INSTANCE_SNAPSHOT
    end
    if data.shard_id ~= nil and data.shard_id ~= self.shard_id then
        return false, InstanceManager.ERROR_CODES.INVALID_INSTANCE_SNAPSHOT
    end

    if data.next_sequence > self.next_sequence then
        self.next_sequence = data.next_sequence
    end

    -- 当前仍采用 ABORT_ON_RESTART；Participant 索引不从活动实例快照恢复，
    -- 避免把已经断开的连接伪造为活动玩家。
    self.participants_by_userid = {}
    self.rule_policy.participant_index = self.participants_by_userid
    -- WP2/WP4 不恢复正在运行的玩法；没有地形和玩家资源需要回收，新的 Zone 池从 FREE 开始。
    self.restart_aborted_count = data.instances ~= nil and #data.instances or 0
    return true, self.restart_aborted_count > 0 and "ACTIVE_INSTANCES_ABORTED" or nil
end

function InstanceManager.Validate(self)
    local zones_valid, zones_code = self.zone_manager:Validate()
    if not zones_valid then
        return false, zones_code
    end

    local seen_zones = {}
    local seen_participants = {}
    for userid, participant in pairs(self.participants_by_userid) do
        if participant == nil or participant.userid ~= userid
            or not IsNonEmptyString(participant.instance_id)
            or seen_participants[userid] then
            return false, InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
        end
        seen_participants[userid] = true
    end

    for index = 1, #self.instance_order do
        local instance_id = self.instance_order[index]
        local instance = self.instances_by_id[instance_id]
        if instance == nil or instance.instance_id ~= instance_id then
            return false, InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
        end
        if instance:IsDestroyed() or seen_zones[instance.zone_id] then
            return false, InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
        end
        local zone = self.zone_manager:Get(instance.zone_id)
        if zone == nil
            or zone.reserved_instance_id ~= instance.instance_id
            or zone.state == "FREE" then
            return false, InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
        end
        seen_zones[instance.zone_id] = true
        local participant_order_seen = {}
        for participant_index = 1, #instance.participant_order do
            local userid = instance.participant_order[participant_index]
            local participant = instance.participants[userid]
            if not IsNonEmptyString(userid)
                or participant == nil
                or participant.userid ~= userid
                or participant.instance_id ~= instance.instance_id
                or participant_order_seen[userid]
                or self.participants_by_userid[userid] ~= participant then
                return false, InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
            end
            participant_order_seen[userid] = true
        end
        for userid, participant in pairs(instance.participants) do
            if not participant_order_seen[userid] or participant == nil
                or self.participants_by_userid[userid] ~= participant then
                return false, InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
            end
        end
        local group_order_seen = {}
        for group_index = 1, #(instance.participant_group_order or {}) do
            local group_id = instance.participant_group_order[group_index]
            local group = instance.participant_groups[group_id]
            if not IsNonEmptyString(group_id)
                or group == nil
                or group.instance_id ~= instance.instance_id
                or group_order_seen[group_id] then
                return false, InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
            end
            group_order_seen[group_id] = true
        end
        for group_id, group in pairs(instance.participant_groups or {}) do
            if not group_order_seen[group_id]
                or group == nil
                or group.instance_id ~= instance.instance_id then
                return false, InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
            end
        end
        for service_index = 1, #(instance.service_order or {}) do
            local service_id = instance.service_order[service_index]
            local service = instance.services[service_id]
            if not IsNonEmptyString(service_id)
                or service == nil
                or service.service_id ~= service_id then
                return false, InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
            end
        end
        if self.scene_service ~= nil then
            local scene_valid, scene_code = self.scene_service:Validate(instance)
            if not scene_valid then
                return false, scene_code or InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
            end
        end
    end
    return true
end

function InstanceManager.GetInstanceDebugData(self, instance_id)
    local instance = self:Get(instance_id)
    if instance == nil then
        return nil, InstanceManager.ERROR_CODES.INSTANCE_NOT_FOUND
    end
    local zone = self.zone_manager:Get(instance.zone_id)
    return instance:GetDebugData(zone ~= nil and zone.state or nil)
end

function InstanceManager.GetDebugLines(self)
    local lines = {}
    local summary = self:GetSummary()
    table.insert(
        lines,
        string.format(
            "instances count=%d next_sequence=%d restart_policy=%s aborted_on_load=%d",
            summary.instance_count,
            summary.next_sequence,
            tostring(summary.restart_policy),
            summary.restart_aborted_count
        )
    )
    for index = 1, #self.instance_order do
        local instance = self.instances_by_id[self.instance_order[index]]
        if instance ~= nil then
            local zone = self.zone_manager:Get(instance.zone_id)
            local entity_count = instance.entity_registry ~= nil
                and instance.entity_registry:Count()
                or 0
            table.insert(
                lines,
                string.format(
                    "instance_id=%s mode_id=%s mode_version=%s zone_id=%s zone_state=%s lifecycle=%s generation=%d scene_revision=%d entities=%d",
                    tostring(instance.instance_id),
                    tostring(instance.mode_id),
                    tostring(instance.mode_version),
                    tostring(instance.zone_id),
                    tostring(zone ~= nil and zone.state or nil),
                    tostring(instance.lifecycle_state),
                    instance.generation,
                    instance.scene_revision,
                    entity_count
                )
            )
        end
    end
    return lines
end

return InstanceManager
