-- WP2/WP3：创建、索引、场景切换和销毁 Instance；只有本模块推进主生命周期。

local Instance = require("agon/core/instance")
local Participant = require("agon/core/participant")
local RulePolicy = require("agon/core/rule_policy")
local CommonServiceRegistry = require("agon/services/common_service_registry")
local Schema = require("agon/persistence/schema")
local SandboxService = require("agon/player/sandbox_service")

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
    PARTICIPANT_SPAWN_POINT_UNAVAILABLE = "PARTICIPANT_SPAWN_POINT_UNAVAILABLE",
    PARTICIPANT_SPAWN_FAILED = "PARTICIPANT_SPAWN_FAILED",
    PARTICIPANT_LOBBY_RETURN_FAILED = "PARTICIPANT_LOBBY_RETURN_FAILED",
    RECOVERY_FAILED = "RECOVERY_FAILED",
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
    manager.RecoverOrphanedZone = InstanceManager.RecoverOrphanedZone
    manager.AddParticipant = InstanceManager.AddParticipant
    manager.AttachPlayer = InstanceManager.AttachPlayer
    manager.PositionParticipant = InstanceManager.PositionParticipant
    manager.PositionParticipants = InstanceManager.PositionParticipants
    manager.MarkDisconnected = InstanceManager.MarkDisconnected
    manager.RemoveParticipant = InstanceManager.RemoveParticipant
    manager.RecoverOnRestart = InstanceManager.RecoverOnRestart
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

local function EnqueueRestore(self, transaction, participant)
    if type(self.restore_enqueue_fn) ~= "function" then
        return false, InstanceManager.ERROR_CODES.RECOVERY_FAILED
    end
    local ok, queued, code = pcall(
        self.restore_enqueue_fn,
        transaction,
        participant
    )
    if not ok or queued == false then
        return false, code or InstanceManager.ERROR_CODES.RECOVERY_FAILED
    end
    return true, code
end

local function QueueInstanceSandboxTransactions(self, instance)
    local sandbox = instance ~= nil and instance:GetService("player_sandbox") or nil
    if sandbox == nil or type(sandbox.ListTransactions) ~= "function" then
        return true
    end
    local transactions = sandbox:ListTransactions()
    for index = 1, #transactions do
        local transaction = transactions[index]
        if transaction ~= nil
            and transaction.state ~= "COMMITTED"
            and transaction.state ~= "CAPTURE_FAILED" then
            local participant = instance:GetParticipant(transaction.userid)
            local queued, queue_code = EnqueueRestore(self, transaction, participant)
            if not queued then
                return false, queue_code
            end
        end
    end
    return true
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
        lobby_service = options.lobby_service,
        now_fn = options.now_fn,
        common_service_registry = options.common_service_registry
            or CommonServiceRegistry.New(),
        profile_registry = options.profile_registry,
        spectator_service = options.spectator_service,
        instances_by_id = {},
        instance_order = {},
        destroyed_ids = {},
        restart_aborted_count = 0,
        pending_recovery = {},
        recovery_failures = {},
        participants_by_userid = {},
        restore_enqueue_fn = options.restore_enqueue_fn,
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

local function HasPlayerTransform(player)
    return type(player) == "table"
        and player.Transform ~= nil
        and type(player.Transform.SetPosition) == "function"
end

local function GetParticipantSpawnIndex(instance, userid)
    if instance == nil or not IsNonEmptyString(userid)
        or type(instance.participant_order) ~= "table" then
        return nil
    end
    for index = 1, #instance.participant_order do
        if instance.participant_order[index] == userid then
            return index
        end
    end
    return nil
end

function InstanceManager.PositionParticipant(self, instance_id, userid)
    local instance = self:Get(instance_id)
    local participant = self:GetParticipant(userid)
    if instance == nil or participant == nil
        or participant.instance_id ~= instance_id then
        return false, InstanceManager.ERROR_CODES.PARTICIPANT_NOT_FOUND
    end

    local player = type(participant.GetPlayer) == "function"
        and participant:GetPlayer()
        or participant.player_ref
    -- 合成诊断玩家没有 Transform；它们只验证状态管线，不参与真实出生点移动。
    if not HasPlayerTransform(player) then
        return true, "POSITION_SKIPPED"
    end

    local plan = instance.scene_plan
    local points = plan ~= nil and plan.participant_spawn_points or nil
    local spawn_index = GetParticipantSpawnIndex(instance, userid)
    local point = spawn_index ~= nil and type(points) == "table"
        and points[spawn_index]
        or nil
    if type(point) ~= "table"
        or type(point.x) ~= "number"
        or type(point.z) ~= "number" then
        return false, InstanceManager.ERROR_CODES.PARTICIPANT_SPAWN_POINT_UNAVAILABLE
    end

    local terrain = self.scene_service ~= nil and self.scene_service.terrain or nil
    if terrain == nil or type(terrain.MoveEntityToTile) ~= "function" then
        return false, InstanceManager.ERROR_CODES.PARTICIPANT_SPAWN_FAILED
    end
    local moved, move_code = terrain:MoveEntityToTile(player, point.x, point.z)
    if not moved then
        return false, move_code or InstanceManager.ERROR_CODES.PARTICIPANT_SPAWN_FAILED
    end
    player.agon_instance_spawn_tile =
    {
        x = point.x,
        z = point.z,
    }
    return true
end

function InstanceManager.PositionParticipants(self, instance)
    if instance == nil then
        return false, InstanceManager.ERROR_CODES.INSTANCE_NOT_FOUND
    end
    for index = 1, #(instance.participant_order or {}) do
        local userid = instance.participant_order[index]
        local positioned, position_code = self:PositionParticipant(
            instance.instance_id,
            userid
        )
        if not positioned then
            return false, position_code
        end
    end
    return true
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

function InstanceManager.RecoverOrphanedZone(self, zone_id, instance_id, reason)
    if not IsNonEmptyString(zone_id) or not IsNonEmptyString(instance_id) then
        return false, InstanceManager.ERROR_CODES.INVALID_INSTANCE_SNAPSHOT
    end
    local zone = self.zone_manager:Get(zone_id)
    if zone == nil then
        return false, "ZONE_NOT_FOUND"
    end
    if zone.state ~= "QUARANTINED"
        or zone.reserved_instance_id ~= instance_id then
        return false, "ZONE_QUARANTINE_OWNER_MISMATCH"
    end
    if self:Get(instance_id) ~= nil then
        return false, "INSTANCE_STILL_ACTIVE"
    end
    for index = 1, #self.instance_order do
        local active_instance = self.instances_by_id[self.instance_order[index]]
        if active_instance ~= nil and active_instance.zone_id == zone_id then
            return false, "INSTANCE_STILL_ACTIVE"
        end
    end
    if self.scene_service == nil
        or type(self.scene_service.RecoverSnapshot) ~= "function" then
        return false, InstanceManager.ERROR_CODES.RECOVERY_FAILED
    end

    -- 没有可恢复的 Instance 快照时仍不直接改 FREE；复用场景恢复流程，
    -- 先拒绝 Zone 内玩家、清理非玩家实体、清回 IMPASSABLE 并验证为空。
    local snapshot =
    {
        instance_id = instance_id,
        scene =
        {
            scope =
            {
                scope_id = instance_id .. ":orphan_recovery",
            },
            scene_revision = 0,
        },
    }
    local cleaned, clean_code = self.scene_service:RecoverSnapshot(
        snapshot,
        zone,
        reason or "orphan_quarantine_recovery"
    )
    if not cleaned then
        return false, clean_code or InstanceManager.ERROR_CODES.RECOVERY_FAILED
    end
    local released, release_code = self.zone_manager:ReleaseRecovered(
        zone_id,
        instance_id
    )
    if not released then
        return false, release_code or InstanceManager.ERROR_CODES.RECOVERY_FAILED
    end
    return true, "ZONE_RECOVERED"
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
            sandbox_transaction_id = options.sandbox_transaction_id,
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
    local reconnecting = participant.state == Participant.STATES.DISCONNECTED
    local attached, attach_code = participant:AttachPlayer(
        player,
        instance.generation,
        GetNow(self)
    )
    if not attached then
        return false, attach_code
    end
    local sandbox = instance:GetService("player_sandbox")
    if sandbox ~= nil then
        local mode_runtime = instance.mode_runtime
        local profile = mode_runtime ~= nil
            and type(mode_runtime.GetPlayerProfile) == "function"
            and mode_runtime:GetPlayerProfile(participant)
            or nil
        if profile == nil then
            participant:MarkDisconnected(
                "player_profile_unavailable",
                instance.generation,
                GetNow(self)
            )
            return false, "PLAYER_PROFILE_UNAVAILABLE"
        end
        local transaction = type(sandbox.GetTransactionObject) == "function"
            and sandbox:GetTransactionObject(participant)
            or nil
        local entered, sandbox_code
        if reconnecting
            and transaction ~= nil
            and transaction.state == SandboxService.STATES.RESTORE_PENDING
            and transaction.last_error_code
                == SandboxService.ERROR_CODES.PLAYER_DISCONNECTED
            and type(sandbox.RebindPlayer) == "function" then
            entered, sandbox_code = sandbox:RebindPlayer(
                participant,
                player,
                profile
            )
        else
            entered, sandbox_code = sandbox:Enter(participant, player, profile)
        end
        if not entered then
            participant:MarkDisconnected(
                "player_sandbox_enter_failed",
                instance.generation,
                GetNow(self)
            )
            return false, sandbox_code or "PLAYER_SANDBOX_ENTER_FAILED"
        end
    end
    local death_policy = instance:GetDeathPolicy()
    if death_policy ~= nil and type(death_policy.OnPlayerAttached) == "function" then
        local attached_death, death_code = death_policy:OnPlayerAttached(participant, player)
        if not attached_death then
            if sandbox ~= nil then
                sandbox:RestoreOriginal(participant, player, "death_policy_attach_failed")
            end
            participant:MarkDisconnected(
                "death_policy_attach_failed",
                instance.generation,
                GetNow(self)
            )
            return false, death_code or "DEATH_POLICY_ATTACH_FAILED"
        end
    end

    if instance.lifecycle_state == Instance.STATES.RUNNING then
        local positioned, position_code = self:PositionParticipant(
            instance_id,
            userid
        )
        if not positioned then
            if sandbox ~= nil then
                sandbox:RestoreOriginal(
                    participant,
                    player,
                    "participant_spawn_failed"
                )
            end
            participant:MarkDisconnected(
                "participant_spawn_failed",
                instance.generation,
                GetNow(self)
            )
            return false, position_code
        end
    end

    if self.lobby_service ~= nil
        and type(self.lobby_service.OnPlayerRemoved) == "function" then
        self.lobby_service:OnPlayerRemoved(player)
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
    if instance ~= nil then
        local sandbox = instance:GetService("player_sandbox")
        if sandbox ~= nil then
            sandbox:MarkDisconnected(participant, reason or "player_disconnected")
        end
    end
    return participant:MarkDisconnected(reason, generation, GetNow(self))
end

function InstanceManager.RemoveParticipant(self, instance_id, userid, reason)
    local instance = self:Get(instance_id)
    local participant = self:GetParticipant(userid)
    if instance == nil or participant == nil
        or participant.instance_id ~= instance_id then
        return false, InstanceManager.ERROR_CODES.PARTICIPANT_NOT_FOUND
    end
    local restore_pending_code = nil
    local death_policy = instance:GetDeathPolicy()
    if death_policy ~= nil and type(death_policy.OnParticipantLeave) == "function" then
        local death_clean, death_code = death_policy:OnParticipantLeave(
            participant,
            reason or "participant_removed"
        )
        if not death_clean then
            restore_pending_code = death_code
        end
    end
    local sandbox = instance:GetService("player_sandbox")
    if sandbox ~= nil then
        local restored, restore_code = sandbox:RestoreOriginal(
            participant,
            nil,
            reason or "participant_removed"
        )
        if not restored then
            -- 玩家恢复失败不能阻塞其他 Participant 的索引和 Instance 清理；
            -- SandboxService 会保留同一 transaction 供 inspect/retry。
            restore_pending_code = restore_pending_code or restore_code
            local transaction = sandbox:GetTransaction(participant)
            local queued, queue_code = EnqueueRestore(self, transaction, participant)
            if not queued then
                restore_pending_code = restore_pending_code or queue_code
            end
        end
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
    return true, restore_pending_code
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

function InstanceManager.Create(self, mode_id, userids, options)
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
    options = type(options) == "table" and options or {}
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
            death_mode = options.death_mode,
        }
    )
    if instance == nil then
        self.zone_manager:ReleaseReservation(zone.zone_id, instance_id)
        return nil, instance_code or InstanceManager.ERROR_CODES.INSTANCE_CREATE_FAILED
    end

    local services_initialized, services_code = instance:InitializeServices(
        self.common_service_registry,
        definition.services,
        {
            now_fn = self.now_fn,
            profile_registry = self.profile_registry,
            allow_live_player_test = mode_id == "TEST_MODE"
                and options.allow_live_player_test == true,
        }
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
            instance:CloseDeathPolicy("participant_create_failed")
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
            instance:CloseDeathPolicy("scene_attach_failed")
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
        instance:CloseDeathPolicy("prepare_failed")
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

    local positioned, position_code = self:PositionParticipants(instance)
    if not positioned then
        instance:Fail("participant_spawn_failed")
        if self.scene_service ~= nil and not self.scene_service:Reset(
            instance,
            "participant_spawn_failed"
        ) then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "participant_spawn_reset_failed:" .. tostring(position_code)
            )
        else
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "participant_spawn_failed:" .. tostring(position_code)
            )
        end
        return false, position_code
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
        if instance.lifecycle_state ~= Instance.STATES.DESTROYING
            or zone.reserved_instance_id ~= instance.instance_id
            or type(self.zone_manager.BeginQuarantinedRecovery) ~= "function" then
            return false, "ZONE_QUARANTINED"
        end
        local resetting, resetting_code = self.zone_manager:BeginQuarantinedRecovery(
            zone.zone_id,
            instance.instance_id,
            "destroy_retry_after_validation"
        )
        if not resetting then
            return false, resetting_code
        end
        return self.zone_manager:Release(zone.zone_id, instance.instance_id)
    end
    return false, "ZONE_STATE_INVALID"
end

local function ReturnParticipantPlayersToLobby(self, instance, reason)
    if self.lobby_service == nil
        or type(self.lobby_service.Enter) ~= "function" then
        return true
    end

    for index = 1, #(instance.participant_order or {}) do
        local userid = instance.participant_order[index]
        local participant = instance:GetParticipant(userid)
        local player = participant ~= nil
            and type(participant.GetPlayer) == "function"
            and participant:GetPlayer()
            or participant ~= nil and participant.player_ref
            or nil

        -- 断线玩家没有有效实体；其恢复证据已由 RestoreQueue 保留，
        -- 不应为了回大厅再次伪造一个玩家实体。
        if HasPlayerTransform(player) then
            local session = type(self.lobby_service.GetSession) == "function"
                and self.lobby_service:GetSession(userid)
                or nil
            local returned = nil
            local return_code = nil
            if session ~= nil and type(self.lobby_service.Return) == "function" then
                returned, return_code = self.lobby_service:Return(
                    player,
                    nil,
                    reason or "instance_destroy"
                )
            else
                session, return_code = self.lobby_service:Enter(player)
                returned = session ~= nil
            end
            if not returned then
                return false,
                    return_code or InstanceManager.ERROR_CODES.PARTICIPANT_LOBBY_RETURN_FAILED
            end
            player.agon_instance_spawn_tile = nil
        end
    end
    return true
end

function InstanceManager.Destroy(self, instance_id, reason)
    if self.destroyed_ids[instance_id] then
        return true, InstanceManager.ERROR_CODES.INSTANCE_ALREADY_DESTROYED
    end

    local instance = self:Get(instance_id)
    if instance == nil then
        return false, InstanceManager.ERROR_CODES.INSTANCE_NOT_FOUND
    end

    if self.spectator_service ~= nil
        and type(self.spectator_service.OnInstanceDestroy) == "function" then
        local spectators_clean, spectator_code = self.spectator_service:OnInstanceDestroy(
            instance_id,
            reason or "destroy"
        )
        if not spectators_clean then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "spectator_cleanup_failed:" .. tostring(spectator_code)
            )
            return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
        end
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

    local death_policy_closed, death_policy_code = instance:CloseDeathPolicy(
        reason or "destroy"
    )
    if not death_policy_closed then
        self.zone_manager:Quarantine(
            instance.zone_id,
            instance.instance_id,
            "death_policy_cleanup_failed:" .. tostring(death_policy_code)
        )
        return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
    end

    if self.scene_service ~= nil then
        local services_closed, services_code = instance:CloseServices(reason or "destroy")
        if not services_closed then
            QueueInstanceSandboxTransactions(self, instance)
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "service_cleanup_failed:" .. tostring(services_code)
            )
            return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
        end
        local queued, queue_code = QueueInstanceSandboxTransactions(self, instance)
        if not queued then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "restore_queue_failed:" .. tostring(queue_code)
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
        local returned, return_code = ReturnParticipantPlayersToLobby(
            self,
            instance,
            reason or "destroy"
        )
        if not returned then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "lobby_return_failed:" .. tostring(return_code)
            )
            return false, InstanceManager.ERROR_CODES.PARTICIPANT_LOBBY_RETURN_FAILED
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
            QueueInstanceSandboxTransactions(self, instance)
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "service_cleanup_failed:" .. tostring(services_code)
            )
            return false, InstanceManager.ERROR_CODES.INSTANCE_DESTROY_FAILED
        end
        local queued, queue_code = QueueInstanceSandboxTransactions(self, instance)
        if not queued then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "restore_queue_failed:" .. tostring(queue_code)
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
        local returned, return_code = ReturnParticipantPlayersToLobby(
            self,
            instance,
            reason or "destroy"
        )
        if not returned then
            self.zone_manager:Quarantine(
                instance.zone_id,
                instance.instance_id,
                "lobby_return_failed:" .. tostring(return_code)
            )
            return false, InstanceManager.ERROR_CODES.PARTICIPANT_LOBBY_RETURN_FAILED
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
        recovery_pending_count = #(self.pending_recovery or {}),
        recovery_failure_count = #(self.recovery_failures or {}),
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
        recovery_failures = Schema.CopyPure(self.recovery_failures) or {},
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

    local copied_instances, copy_code = Schema.CopyPure(data.instances or {})
    if type(copied_instances) ~= "table" then
        return false, copy_code or InstanceManager.ERROR_CODES.INVALID_INSTANCE_SNAPSHOT
    end

    if data.next_sequence > self.next_sequence then
        self.next_sequence = data.next_sequence
    end

    -- 当前仍采用 ABORT_ON_RESTART；Participant 索引不从活动实例快照恢复，
    -- 避免把已经断开的连接伪造为活动玩家。实际清场在 OnPostInit 之后执行。
    self.participants_by_userid = {}
    self.rule_policy.participant_index = self.participants_by_userid
    self.pending_recovery = copied_instances
    self.recovery_failures = type(data.recovery_failures) == "table"
        and Schema.CopyPure(data.recovery_failures)
        or {}
    self.restart_aborted_count = #self.pending_recovery
    return true, self.restart_aborted_count > 0 and "ACTIVE_INSTANCES_ABORTED" or nil
end

local function QueueSavedSandboxTransactions(self, saved_instance)
    local services = saved_instance.services
    local sandbox = type(services) == "table" and services.player_sandbox or nil
    local transactions = type(sandbox) == "table" and sandbox.transactions or nil
    if transactions == nil then
        return true
    end
    if type(transactions) ~= "table" then
        return false, InstanceManager.ERROR_CODES.INVALID_INSTANCE_SNAPSHOT
    end

    local participants = {}
    for index = 1, #(saved_instance.participants or {}) do
        local participant = saved_instance.participants[index]
        if type(participant) == "table" and IsNonEmptyString(participant.userid) then
            participants[participant.userid] = participant
        end
    end
    for index = 1, #transactions do
        local transaction = transactions[index]
        if type(transaction) ~= "table" then
            return false, InstanceManager.ERROR_CODES.INVALID_INSTANCE_SNAPSHOT
        end
        if transaction.state ~= "COMMITTED"
            and transaction.state ~= "CAPTURE_FAILED" then
            local queued, queue_code = EnqueueRestore(
                self,
                transaction,
                participants[transaction.userid]
            )
            if not queued then
                return false, queue_code
            end
        end
    end
    return true
end

function InstanceManager.RecoverOnRestart(self)
    local summary =
    {
        aborted = #(self.pending_recovery or {}),
        recovered = 0,
        quarantined = 0,
        restore_transactions = 0,
    }
    local pending = self.pending_recovery or {}
    self.recovery_failures = self.recovery_failures or {}

    for index = 1, #pending do
        local saved = pending[index]
        local instance_id = type(saved) == "table" and saved.instance_id or nil
        local zone_id = type(saved) == "table" and saved.zone_id or nil
        local zone = zone_id ~= nil and self.zone_manager:Get(zone_id) or nil
        local failure_code = nil

        if type(saved) ~= "table"
            or not IsNonEmptyString(instance_id)
            or not IsNonEmptyString(zone_id)
            or zone == nil then
            failure_code = InstanceManager.ERROR_CODES.INVALID_INSTANCE_SNAPSHOT
        else
            local queued, queue_code = QueueSavedSandboxTransactions(self, saved)
            if not queued then
                failure_code = queue_code or InstanceManager.ERROR_CODES.RECOVERY_FAILED
            end
            if failure_code == nil then
                if zone:IsQuarantined()
                    and zone.reserved_instance_id ~= instance_id then
                    failure_code = "ZONE_QUARANTINED"
                elseif self.scene_service == nil
                    or type(self.scene_service.RecoverSnapshot) ~= "function" then
                    failure_code = InstanceManager.ERROR_CODES.RECOVERY_FAILED
                else
                    local cleaned, clean_code = self.scene_service:RecoverSnapshot(
                        saved,
                        zone,
                        "restart_recovery"
                    )
                    if not cleaned then
                        failure_code = clean_code or InstanceManager.ERROR_CODES.RECOVERY_FAILED
                    else
                        local released, release_code = self.zone_manager:ReleaseRecovered(
                            zone_id,
                            instance_id
                        )
                        if not released then
                            failure_code = release_code
                                or InstanceManager.ERROR_CODES.RECOVERY_FAILED
                        end
                    end
                end
            end
        end

        if failure_code == nil then
            summary.recovered = summary.recovered + 1
        else
            summary.quarantined = summary.quarantined + 1
            if zone ~= nil and self.zone_manager ~= nil
                and type(self.zone_manager.QuarantineRecovered) == "function" then
                self.zone_manager:QuarantineRecovered(
                    zone_id,
                    instance_id,
                    "restart_recovery_failed:" .. tostring(failure_code)
                )
            end
            table.insert(
                self.recovery_failures,
                {
                    instance_id = instance_id,
                    zone_id = zone_id,
                    code = failure_code,
                }
            )
        end
    end

    self.pending_recovery = {}
    return true, summary
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
        if instance.death_policy ~= nil
            and type(instance.death_policy.Validate) == "function" then
            local death_valid, death_code = instance.death_policy:Validate()
            if not death_valid then
                return false, death_code
                    or InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
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
            if type(service.Validate) == "function" then
                local service_valid, service_code = service:Validate()
                if not service_valid then
                    return false, service_code
                        or InstanceManager.ERROR_CODES.INSTANCE_INVARIANT_FAILED
                end
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
                    "instance_id=%s mode_id=%s mode_version=%s death_mode=%s zone_id=%s zone_state=%s lifecycle=%s generation=%d scene_revision=%d entities=%d",
                    tostring(instance.instance_id),
                    tostring(instance.mode_id),
                    tostring(instance.mode_version),
                    tostring(instance.death_policy ~= nil and instance.death_policy.mode or nil),
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
