-- WP5：管理 Instance 内的通用阶段、revision 和阶段资源作用域。

local PhaseService = {}

PhaseService.SCHEMA_VERSION = 1

PhaseService.STATES =
{
    PREPARING = "PREPARING",
    ACTIVE = "ACTIVE",
    RESOLVING = "RESOLVING",
    TRANSITIONING = "TRANSITIONING",
    ENDED = "ENDED",
}

PhaseService.TRANSITIONS =
{
    PREPARING = { ACTIVE = true, ENDED = true },
    ACTIVE = { RESOLVING = true, TRANSITIONING = true, ENDED = true },
    RESOLVING = { TRANSITIONING = true, ENDED = true },
    TRANSITIONING = { ENDED = true },
    ENDED = {},
}

PhaseService.ERROR_CODES =
{
    INVALID_PHASE = "INVALID_PHASE",
    INVALID_PHASE_ID = "INVALID_PHASE_ID",
    DUPLICATE_PHASE = "DUPLICATE_PHASE",
    PHASE_ACTIVE = "PHASE_ACTIVE",
    PHASE_NOT_FOUND = "PHASE_NOT_FOUND",
    PHASE_CLOSED = "PHASE_CLOSED",
    INVALID_PHASE_TRANSITION = "INVALID_PHASE_TRANSITION",
    STALE_PHASE_REVISION = "STALE_PHASE_REVISION",
    PHASE_SCOPE_FAILED = "PHASE_SCOPE_FAILED",
    SCOPE_RESOURCE_INVALID = "PHASE_SCOPE_RESOURCE_INVALID",
    SERVICE_CLOSED = "PHASE_SERVICE_CLOSED",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= 1
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

local function GetNow(self)
    if type(self.now_fn) == "function" then
        return self.now_fn()
    end
    if self.instance ~= nil and type(self.instance.now_fn) == "function" then
        return self.instance.now_fn()
    end
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

local function IsOpenScope(scope)
    return scope ~= nil and type(scope.IsOpen) == "function" and scope:IsOpen()
end

function PhaseService.GetCurrentPhase(self)
    return self.current_phase
end

function PhaseService.GetCurrentPhaseId(self)
    return self.current_phase ~= nil and self.current_phase.phase_id or nil
end

function PhaseService.GetCurrentRevision(self)
    return self.current_phase ~= nil and self.current_phase.revision or nil
end

function PhaseService.GetRevision(self)
    return self.revision
end

function PhaseService.GetPhase(self, phase_id)
    if not IsNonEmptyString(phase_id) then
        return nil
    end
    return self.phases_by_id[phase_id]
end

function PhaseService.IsRevisionCurrent(self, phase_revision)
    return self.current_phase ~= nil
        and IsPositiveInteger(phase_revision)
        and self.current_phase.revision == phase_revision
        and self.current_phase.state ~= PhaseService.STATES.ENDED
end

function PhaseService.GetCurrentScope(self)
    if self.current_phase == nil or not IsOpenScope(self.current_phase.scope) then
        return nil
    end
    return self.current_phase.scope
end

function PhaseService.Begin(self, phase_id, options)
    if self.closed then
        return nil, PhaseService.ERROR_CODES.SERVICE_CLOSED
    end
    if not IsNonEmptyString(phase_id) then
        return nil, PhaseService.ERROR_CODES.INVALID_PHASE_ID
    end
    if self.phases_by_id[phase_id] ~= nil then
        return nil, PhaseService.ERROR_CODES.DUPLICATE_PHASE
    end
    if self.current_phase ~= nil and self.current_phase.state ~= PhaseService.STATES.ENDED then
        return nil, PhaseService.ERROR_CODES.PHASE_ACTIVE
    end

    options = type(options) == "table" and options or {}
    self.next_sequence = self.next_sequence + 1
    local scope_name = "phase_" .. tostring(self.next_sequence)
    local scope, scope_code = self.instance.root_scope:CreateChild(scope_name)
    if scope == nil then
        return nil, scope_code or PhaseService.ERROR_CODES.PHASE_SCOPE_FAILED
    end

    self.revision = self.revision + 1
    local now = options.created_at ~= nil and options.created_at or GetNow(self)
    local phase =
    {
        schema_version = PhaseService.SCHEMA_VERSION,
        phase_id = phase_id,
        instance_id = self.instance.instance_id,
        state = PhaseService.STATES.PREPARING,
        revision = 1,
        service_revision = self.revision,
        created_at = now,
        state_entered_at = now,
        last_transition_reason = nil,
        metadata = CopyValue(options.metadata or {}),
        scope = scope,
        scope_id = scope:GetId(),
        scope_closed = false,
    }
    self.phases_by_id[phase_id] = phase
    table.insert(self.phase_order, phase_id)
    self.current_phase = phase
    return phase
end

PhaseService.Create = PhaseService.Begin

function PhaseService.Transition(self, next_state, reason, expected_revision)
    if self.closed then
        return false, PhaseService.ERROR_CODES.SERVICE_CLOSED
    end
    local phase = self.current_phase
    if phase == nil then
        return false, PhaseService.ERROR_CODES.PHASE_NOT_FOUND
    end
    if phase.state == PhaseService.STATES.ENDED then
        return true, "ALREADY_ENDED"
    end
    if expected_revision ~= nil and phase.revision ~= expected_revision then
        return false, PhaseService.ERROR_CODES.STALE_PHASE_REVISION
    end
    if not IsNonEmptyString(next_state)
        or PhaseService.TRANSITIONS[phase.state] == nil
        or not PhaseService.TRANSITIONS[phase.state][next_state] then
        return false, PhaseService.ERROR_CODES.INVALID_PHASE_TRANSITION
    end

    phase.state = next_state
    phase.revision = phase.revision + 1
    self.revision = self.revision + 1
    phase.service_revision = self.revision
    phase.state_entered_at = GetNow(self)
    phase.last_transition_reason = reason ~= nil and tostring(reason) or nil

    if next_state == PhaseService.STATES.ENDED then
        local closed, close_code = true, nil
        if phase.scope ~= nil and not phase.scope:IsClosed() then
            closed, close_code = phase.scope:Close(reason or "phase_ended")
        end
        phase.scope_closed = true
        if not closed then
            return false, close_code or PhaseService.ERROR_CODES.PHASE_CLOSED
        end
    end
    return true
end

function PhaseService.End(self, reason, expected_revision)
    return self:Transition(PhaseService.STATES.ENDED, reason or "phase_ended", expected_revision)
end

function PhaseService.RegisterCleanup(self, callback, cleanup_policy, label)
    local scope = self:GetCurrentScope()
    if scope == nil then
        return nil, PhaseService.ERROR_CODES.PHASE_NOT_FOUND
    end
    return scope:RegisterCleanup(callback, cleanup_policy, label)
end

function PhaseService.DoTaskInTime(self, time, callback, ...)
    local scope = self:GetCurrentScope()
    local owner = self.instance.resource_owner
    if scope == nil or owner == nil then
        return nil, PhaseService.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    return scope:DoTaskInTime(owner, time, callback, ...)
end

function PhaseService.DoPeriodicTask(self, period, callback, initial_delay, ...)
    local scope = self:GetCurrentScope()
    local owner = self.instance.resource_owner
    if scope == nil or owner == nil then
        return nil, PhaseService.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    return scope:DoPeriodicTask(owner, period, callback, initial_delay, ...)
end

function PhaseService.ListenForEvent(self, event, callback, source, cleanup_policy, label)
    local scope = self:GetCurrentScope()
    local listener = source or self.instance.resource_owner
    if scope == nil or listener == nil then
        return nil, PhaseService.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    return scope:ListenForEvent(
        listener,
        event,
        callback,
        source or listener,
        cleanup_policy,
        label
    )
end

function PhaseService.Close(self, reason)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    local all_clean = true
    for index = #self.phase_order, 1, -1 do
        local phase = self.phases_by_id[self.phase_order[index]]
        if phase ~= nil and phase.scope ~= nil and not phase.scope:IsClosed() then
            local closed = phase.scope:Close(reason or "phase_service_closed")
            phase.scope_closed = true
            phase.state = PhaseService.STATES.ENDED
            if not closed then
                all_clean = false
            end
        end
    end
    self.current_phase = nil
    self.closed = true
    if all_clean then
        return true
    end
    return false, PhaseService.ERROR_CODES.PHASE_CLOSED
end

function PhaseService.GetSnapshot(self)
    local phases = {}
    for index = 1, #self.phase_order do
        local phase = self.phases_by_id[self.phase_order[index]]
        if phase ~= nil then
            table.insert(
                phases,
                {
                    schema_version = PhaseService.SCHEMA_VERSION,
                    phase_id = phase.phase_id,
                    instance_id = phase.instance_id,
                    state = phase.state,
                    revision = phase.revision,
                    service_revision = phase.service_revision,
                    created_at = phase.created_at,
                    state_entered_at = phase.state_entered_at,
                    last_transition_reason = phase.last_transition_reason,
                    metadata = CopyValue(phase.metadata),
                    scope_id = phase.scope_id,
                    scope_closed = phase.scope_closed,
                }
            )
        end
    end
    return
    {
        schema_version = PhaseService.SCHEMA_VERSION,
        revision = self.revision,
        next_sequence = self.next_sequence,
        current_phase_id = self:GetCurrentPhaseId(),
        phases = phases,
    }
end

function PhaseService.GetDebugString(self)
    local phase = self.current_phase
    return string.format(
        "phase_service phases=%d revision=%d current=%s state=%s phase_revision=%s",
        #self.phase_order,
        self.revision,
        tostring(phase ~= nil and phase.phase_id or nil),
        tostring(phase ~= nil and phase.state or nil),
        tostring(phase ~= nil and phase.revision or nil)
    )
end

local function AttachMethods(service)
    service.GetCurrentPhase = PhaseService.GetCurrentPhase
    service.GetCurrentPhaseId = PhaseService.GetCurrentPhaseId
    service.GetCurrentRevision = PhaseService.GetCurrentRevision
    service.GetRevision = PhaseService.GetRevision
    service.GetPhase = PhaseService.GetPhase
    service.IsRevisionCurrent = PhaseService.IsRevisionCurrent
    service.GetCurrentScope = PhaseService.GetCurrentScope
    service.Begin = PhaseService.Begin
    service.Create = PhaseService.Create
    service.Transition = PhaseService.Transition
    service.End = PhaseService.End
    service.RegisterCleanup = PhaseService.RegisterCleanup
    service.DoTaskInTime = PhaseService.DoTaskInTime
    service.DoPeriodicTask = PhaseService.DoPeriodicTask
    service.ListenForEvent = PhaseService.ListenForEvent
    service.Close = PhaseService.Close
    service.GetSnapshot = PhaseService.GetSnapshot
    service.GetDebugString = PhaseService.GetDebugString
    return service
end

function PhaseService.New(instance, services, options)
    if type(instance) ~= "table"
        or type(instance.instance_id) ~= "string"
        or instance.root_scope == nil then
        return nil, PhaseService.ERROR_CODES.INVALID_PHASE
    end
    options = type(options) == "table" and options or {}
    return AttachMethods(
    {
        schema_version = PhaseService.SCHEMA_VERSION,
        service_id = "phase",
        service_version = 1,
        instance = instance,
        services = services or {},
        now_fn = options.now_fn,
        phases_by_id = {},
        phase_order = {},
        next_sequence = 0,
        revision = 0,
        current_phase = nil,
        closed = false,
    })
end

return PhaseService
