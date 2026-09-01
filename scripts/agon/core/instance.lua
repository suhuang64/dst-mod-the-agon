-- WP2：单局 Instance 的生命周期和最小可保存状态。

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
    }

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
    instance.GetLifecycleState = Instance.GetLifecycleState
    instance.GetGeneration = Instance.GetGeneration
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
        lifecycle_state = Instance.STATES.CREATED,
        created_at = now,
        state_entered_at = now,
        generation = 1,
        participants = {},
        participant_groups = {},
        services = {},
        scene_revision = 0,
        result = nil,
        failure_reason = nil,
        definition = definition,
        mode_runtime = nil,
        finish_called = false,
        destroy_called = false,
        now_fn = options.now_fn,
    }
    return AttachMethods(instance)
end

return Instance
