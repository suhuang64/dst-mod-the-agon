-- WP2：创建、索引和销毁 Instance；只有本模块推进 Instance 主生命周期。

local Instance = require("agon/core/instance")

local InstanceManager = {}
InstanceManager.SCHEMA_VERSION = 1
InstanceManager.RESTART_POLICY = "ABORT_ON_RESTART"

InstanceManager.ERROR_CODES =
{
    CORE_NOT_READY = "CORE_NOT_READY",
    INVALID_MODE = "INVALID_MODE",
    PARTICIPANTS_NOT_SUPPORTED = "PARTICIPANTS_NOT_SUPPORTED",
    NO_FREE_ZONE = "NO_FREE_ZONE",
    INSTANCE_CREATE_FAILED = "INSTANCE_CREATE_FAILED",
    INSTANCE_NOT_FOUND = "INSTANCE_NOT_FOUND",
    INSTANCE_ALREADY_DESTROYED = "ALREADY_DESTROYED",
    INSTANCE_DESTROY_FAILED = "INSTANCE_DESTROY_FAILED",
    INVALID_INSTANCE_SNAPSHOT = "INVALID_INSTANCE_SNAPSHOT",
    INVALID_SEQUENCE = "INVALID_SEQUENCE",
    INSTANCE_INVARIANT_FAILED = "INSTANCE_INVARIANT_FAILED",
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
    manager.Transition = InstanceManager.Transition
    manager.Fail = InstanceManager.Fail
    manager.Destroy = InstanceManager.Destroy
    manager.GetSummary = InstanceManager.GetSummary
    manager.GetSnapshot = InstanceManager.GetSnapshot
    manager.OnLoad = InstanceManager.OnLoad
    manager.Validate = InstanceManager.Validate
    manager.GetDebugLines = InstanceManager.GetDebugLines
    manager.GetInstanceDebugData = InstanceManager.GetInstanceDebugData
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

    return AttachMethods(
    {
        schema_version = InstanceManager.SCHEMA_VERSION,
        restart_policy = InstanceManager.RESTART_POLICY,
        shard_id = shard_id,
        next_sequence = next_sequence,
        zone_manager = options.zone_manager,
        mode_registry = options.mode_registry,
        now_fn = options.now_fn,
        instances_by_id = {},
        instance_order = {},
        destroyed_ids = {},
        restart_aborted_count = 0,
    })
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

local function RemoveFromOrder(self, instance_id)
    for index = 1, #self.instance_order do
        if self.instance_order[index] == instance_id then
            table.remove(self.instance_order, index)
            return
        end
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
    if userids ~= nil
        and type(userids) ~= "table" then
        return nil, InstanceManager.ERROR_CODES.PARTICIPANTS_NOT_SUPPORTED
    end
    if type(userids) == "table" and #userids > 0 then
        return nil, InstanceManager.ERROR_CODES.PARTICIPANTS_NOT_SUPPORTED
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
        }
    )
    if instance == nil then
        self.zone_manager:ReleaseReservation(zone.zone_id, instance_id)
        return nil, instance_code or InstanceManager.ERROR_CODES.INSTANCE_CREATE_FAILED
    end

    local prepared, prepare_code = instance:Prepare("create")
    if not prepared then
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

    self.instances_by_id[instance_id] = instance
    table.insert(self.instance_order, instance_id)
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

    local started, start_code = instance:Start(reason or "start")
    if not started then
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
        self.zone_manager:Quarantine(
            instance.zone_id,
            instance.instance_id,
            "zone_activate_failed:" .. tostring(active_code)
        )
        return false, active_code
    end
    return true, start_code
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

    -- WP2 不恢复正在运行的玩法；没有地形和玩家资源需要回收，新的 Zone 池从 FREE 开始。
    self.restart_aborted_count = data.instances ~= nil and #data.instances or 0
    return true, self.restart_aborted_count > 0 and "ACTIVE_INSTANCES_ABORTED" or nil
end

function InstanceManager.Validate(self)
    local zones_valid, zones_code = self.zone_manager:Validate()
    if not zones_valid then
        return false, zones_code
    end

    local seen_zones = {}
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
            table.insert(
                lines,
                string.format(
                    "instance_id=%s mode_id=%s mode_version=%s zone_id=%s zone_state=%s lifecycle=%s generation=%d",
                    tostring(instance.instance_id),
                    tostring(instance.mode_id),
                    tostring(instance.mode_version),
                    tostring(instance.zone_id),
                    tostring(zone ~= nil and zone.state or nil),
                    tostring(instance.lifecycle_state),
                    instance.generation
                )
            )
        end
    end
    return lines
end

return InstanceManager
