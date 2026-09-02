-- WP5：提供 Instance 内幂等记分与 Participant/Group/Instance 汇总。

local ScoreLedger = {}

ScoreLedger.SCHEMA_VERSION = 1

ScoreLedger.TARGETS =
{
    PARTICIPANT = "PARTICIPANT",
    GROUP = "GROUP",
    INSTANCE = "INSTANCE",
}

ScoreLedger.ERROR_CODES =
{
    INVALID_EVENT = "INVALID_SCORE_EVENT",
    INVALID_EVENT_ID = "INVALID_SCORE_EVENT_ID",
    DUPLICATE_EVENT = "DUPLICATE_SCORE_EVENT",
    LEDGER_FROZEN = "SCORE_LEDGER_FROZEN",
    LEDGER_CLOSED = "SCORE_LEDGER_CLOSED",
    INSTANCE_MISMATCH = "SCORE_INSTANCE_MISMATCH",
    TARGET_INVALID = "INVALID_SCORE_TARGET",
    SCORE_INVALID = "INVALID_SCORE_VALUE",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
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

function ScoreLedger.Get(self, event_id)
    if not IsNonEmptyString(event_id) then
        return nil
    end
    return self.events_by_id[event_id]
end

function ScoreLedger.Append(self, event)
    if self.closed then
        return nil, ScoreLedger.ERROR_CODES.LEDGER_CLOSED
    end
    if self.frozen then
        return nil, ScoreLedger.ERROR_CODES.LEDGER_FROZEN
    end
    if type(event) ~= "table" then
        return nil, ScoreLedger.ERROR_CODES.INVALID_EVENT
    end
    local event_id = event.event_id
    if not IsNonEmptyString(event_id) then
        return nil, ScoreLedger.ERROR_CODES.INVALID_EVENT_ID
    end
    if self.events_by_id[event_id] ~= nil then
        return nil, ScoreLedger.ERROR_CODES.DUPLICATE_EVENT
    end
    if event.instance_id ~= nil and event.instance_id ~= self.instance.instance_id then
        return nil, ScoreLedger.ERROR_CODES.INSTANCE_MISMATCH
    end
    if not IsFiniteNumber(event.points) then
        return nil, ScoreLedger.ERROR_CODES.SCORE_INVALID
    end

    local target_type = event.target_type
    if target_type == nil then
        if event.participant_id ~= nil then
            target_type = ScoreLedger.TARGETS.PARTICIPANT
        elseif event.group_id ~= nil then
            target_type = ScoreLedger.TARGETS.GROUP
        else
            target_type = ScoreLedger.TARGETS.INSTANCE
        end
    end
    if target_type ~= ScoreLedger.TARGETS.PARTICIPANT
        and target_type ~= ScoreLedger.TARGETS.GROUP
        and target_type ~= ScoreLedger.TARGETS.INSTANCE then
        return nil, ScoreLedger.ERROR_CODES.TARGET_INVALID
    end

    local target_id = event.target_id
    if target_type == ScoreLedger.TARGETS.PARTICIPANT then
        target_id = target_id or event.participant_id
        if not IsNonEmptyString(target_id) then
            return nil, ScoreLedger.ERROR_CODES.TARGET_INVALID
        end
        local participant = self.instance:GetParticipant(target_id)
        if participant == nil or participant.instance_id ~= self.instance.instance_id then
            return nil, ScoreLedger.ERROR_CODES.TARGET_INVALID
        end
    elseif target_type == ScoreLedger.TARGETS.GROUP then
        target_id = target_id or event.group_id
        if not IsNonEmptyString(target_id)
            or self.instance:GetGroup(target_id) == nil then
            return nil, ScoreLedger.ERROR_CODES.TARGET_INVALID
        end
    else
        target_id = self.instance.instance_id
    end

    local record =
    {
        schema_version = ScoreLedger.SCHEMA_VERSION,
        event_id = event_id,
        instance_id = self.instance.instance_id,
        target_type = target_type,
        target_id = target_id,
        points = event.points,
        reason = event.reason ~= nil and tostring(event.reason) or nil,
        created_at = event.created_at ~= nil and event.created_at or self:Now(),
        metadata = CopyValue(event.metadata or {}),
    }
    self.events_by_id[event_id] = record
    table.insert(self.event_order, event_id)
    self.instance_total = self.instance_total + event.points
    if target_type == ScoreLedger.TARGETS.PARTICIPANT then
        self.participant_totals[target_id] = (self.participant_totals[target_id] or 0) + event.points
    elseif target_type == ScoreLedger.TARGETS.GROUP then
        self.group_totals[target_id] = (self.group_totals[target_id] or 0) + event.points
    end
    return CopyValue(record)
end

ScoreLedger.Record = ScoreLedger.Append

function ScoreLedger.Freeze(self, reason)
    if self.frozen then
        return true, "ALREADY_FROZEN"
    end
    self.frozen = true
    self.freeze_reason = reason ~= nil and tostring(reason) or nil
    self.frozen_at = self:Now()
    return true
end

function ScoreLedger.IsFrozen(self)
    return self.frozen
end

function ScoreLedger.GetTotal(self, target_type, target_id)
    if target_type == ScoreLedger.TARGETS.PARTICIPANT then
        return self.participant_totals[target_id] or 0
    elseif target_type == ScoreLedger.TARGETS.GROUP then
        return self.group_totals[target_id] or 0
    end
    return self.instance_total
end

function ScoreLedger.Now(self)
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

function ScoreLedger.Close(self, reason)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    if not self.frozen then
        self:Freeze(reason or "ledger_closed")
    end
    self.closed = true
    return true
end

function ScoreLedger.GetSnapshot(self)
    local events = {}
    for index = 1, #self.event_order do
        local event = self.events_by_id[self.event_order[index]]
        if event ~= nil then
            table.insert(events, CopyValue(event))
        end
    end
    return
    {
        schema_version = ScoreLedger.SCHEMA_VERSION,
        instance_id = self.instance.instance_id,
        frozen = self.frozen,
        freeze_reason = self.freeze_reason,
        frozen_at = self.frozen_at,
        instance_total = self.instance_total,
        participant_totals = CopyValue(self.participant_totals),
        group_totals = CopyValue(self.group_totals),
        events = events,
    }
end

function ScoreLedger.GetDebugString(self)
    return string.format(
        "score_ledger events=%d instance_total=%s frozen=%s",
        #self.event_order,
        tostring(self.instance_total),
        tostring(self.frozen)
    )
end

local function AttachMethods(service)
    service.Get = ScoreLedger.Get
    service.Append = ScoreLedger.Append
    service.Record = ScoreLedger.Record
    service.Freeze = ScoreLedger.Freeze
    service.IsFrozen = ScoreLedger.IsFrozen
    service.GetTotal = ScoreLedger.GetTotal
    service.Now = ScoreLedger.Now
    service.Close = ScoreLedger.Close
    service.GetSnapshot = ScoreLedger.GetSnapshot
    service.GetDebugString = ScoreLedger.GetDebugString
    return service
end

function ScoreLedger.New(instance, services, options)
    if type(instance) ~= "table" or type(instance.instance_id) ~= "string" then
        return nil, ScoreLedger.ERROR_CODES.INVALID_EVENT
    end
    options = type(options) == "table" and options or {}
    return AttachMethods(
    {
        schema_version = ScoreLedger.SCHEMA_VERSION,
        service_id = "score",
        service_version = 1,
        instance = instance,
        services = services or {},
        now_fn = options.now_fn,
        events_by_id = {},
        event_order = {},
        participant_totals = {},
        group_totals = {},
        instance_total = 0,
        frozen = false,
        freeze_reason = nil,
        frozen_at = nil,
        closed = false,
    })
end

return ScoreLedger
