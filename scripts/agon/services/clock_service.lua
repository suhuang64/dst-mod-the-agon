-- WP5：Instance/Phase 级语义时钟；不暂停世界天数、昼夜或其他 Instance。

local ClockService = {}

ClockService.SCHEMA_VERSION = 1

ClockService.ERROR_CODES =
{
    INVALID_CLOCK = "INVALID_CLOCK",
    INVALID_CLOCK_ID = "INVALID_CLOCK_ID",
    DUPLICATE_CLOCK = "DUPLICATE_CLOCK",
    CLOCK_NOT_FOUND = "CLOCK_NOT_FOUND",
    CLOCK_CLOSED = "CLOCK_CLOSED",
    INVALID_DEADLINE = "INVALID_CLOCK_DEADLINE",
    STALE_PHASE_REVISION = "CLOCK_STALE_PHASE_REVISION",
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

local function GetPhaseRevision(self)
    if self.phase_service ~= nil
        and type(self.phase_service.GetCurrentRevision) == "function" then
        return self.phase_service:GetCurrentRevision()
    end
    return nil
end

local function ValidateExpectedPhaseRevision(self, expected_revision)
    if expected_revision == nil then
        return true
    end
    return GetPhaseRevision(self) == expected_revision
end

function ClockService.Get(self, clock_id)
    if not IsNonEmptyString(clock_id) then
        return nil
    end
    return self.clocks_by_id[clock_id]
end

function ClockService.Create(self, clock_id, options)
    if self.closed then
        return nil, ClockService.ERROR_CODES.CLOCK_CLOSED
    end
    if not IsNonEmptyString(clock_id) then
        return nil, ClockService.ERROR_CODES.INVALID_CLOCK_ID
    end
    if self.clocks_by_id[clock_id] ~= nil then
        return nil, ClockService.ERROR_CODES.DUPLICATE_CLOCK
    end
    options = type(options) == "table" and options or {}
    if options.deadline ~= nil and not IsFiniteNumber(options.deadline) then
        return nil, ClockService.ERROR_CODES.INVALID_DEADLINE
    end
    if options.duration ~= nil
        and (not IsFiniteNumber(options.duration) or options.duration < 0) then
        return nil, ClockService.ERROR_CODES.INVALID_DEADLINE
    end
    if not ValidateExpectedPhaseRevision(self, options.phase_revision) then
        return nil, ClockService.ERROR_CODES.STALE_PHASE_REVISION
    end

    local now = options.started_at ~= nil and options.started_at or GetNow(self)
    local deadline = options.deadline
    if deadline == nil and options.duration ~= nil then
        deadline = now + options.duration
    end
    local phase_id = options.phase_id
    if phase_id == nil and self.phase_service ~= nil then
        phase_id = self.phase_service:GetCurrentPhaseId()
    end
    local phase_revision = options.phase_revision or GetPhaseRevision(self)
    local clock =
    {
        schema_version = ClockService.SCHEMA_VERSION,
        clock_id = clock_id,
        instance_id = self.instance.instance_id,
        phase_id = phase_id,
        phase_revision = phase_revision,
        started_at = now,
        updated_at = now,
        deadline = deadline,
        paused = options.paused == true,
        paused_at = nil,
        remaining = nil,
        revision = 1,
        metadata = CopyValue(options.metadata or {}),
    }
    if clock.paused and clock.deadline ~= nil then
        clock.remaining = math.max(0, clock.deadline - now)
    end
    self.clocks_by_id[clock_id] = clock
    table.insert(self.clock_order, clock_id)
    return clock
end

ClockService.Start = ClockService.Create

function ClockService.SetDeadline(self, clock_id, deadline, phase_revision)
    local clock = self:Get(clock_id)
    if clock == nil then
        return false, ClockService.ERROR_CODES.CLOCK_NOT_FOUND
    end
    if not IsFiniteNumber(deadline) then
        return false, ClockService.ERROR_CODES.INVALID_DEADLINE
    end
    if not ValidateExpectedPhaseRevision(self, phase_revision) then
        return false, ClockService.ERROR_CODES.STALE_PHASE_REVISION
    end
    clock.deadline = deadline
    clock.phase_revision = phase_revision or clock.phase_revision
    clock.updated_at = GetNow(self)
    clock.revision = clock.revision + 1
    if clock.paused then
        clock.remaining = math.max(0, deadline - clock.updated_at)
    end
    return true
end

function ClockService.GetRemaining(self, clock_id, now)
    local clock = self:Get(clock_id)
    if clock == nil then
        return nil, ClockService.ERROR_CODES.CLOCK_NOT_FOUND
    end
    if clock.deadline == nil and clock.remaining == nil then
        return nil
    end
    if clock.paused then
        return math.max(0, clock.remaining or 0)
    end
    return math.max(0, (clock.deadline or 0) - (now ~= nil and now or GetNow(self)))
end

function ClockService.IsExpired(self, clock_id, now)
    local remaining, code = self:GetRemaining(clock_id, now)
    if remaining == nil then
        return false, code
    end
    return remaining <= 0
end

function ClockService.IsPaused(self, clock_id)
    local clock = self:Get(clock_id)
    return clock ~= nil and clock.paused
end

function ClockService.Pause(self, clock_id, now, phase_revision)
    local clock = self:Get(clock_id)
    if clock == nil then
        return false, ClockService.ERROR_CODES.CLOCK_NOT_FOUND
    end
    if not ValidateExpectedPhaseRevision(self, phase_revision) then
        return false, ClockService.ERROR_CODES.STALE_PHASE_REVISION
    end
    if clock.paused then
        return true, "ALREADY_PAUSED"
    end
    now = now ~= nil and now or GetNow(self)
    if clock.deadline ~= nil then
        clock.remaining = math.max(0, clock.deadline - now)
    end
    clock.paused = true
    clock.paused_at = now
    clock.updated_at = now
    clock.revision = clock.revision + 1
    return true
end

function ClockService.Resume(self, clock_id, now, phase_revision)
    local clock = self:Get(clock_id)
    if clock == nil then
        return false, ClockService.ERROR_CODES.CLOCK_NOT_FOUND
    end
    if not ValidateExpectedPhaseRevision(self, phase_revision) then
        return false, ClockService.ERROR_CODES.STALE_PHASE_REVISION
    end
    if not clock.paused then
        return true, "ALREADY_RUNNING"
    end
    now = now ~= nil and now or GetNow(self)
    if clock.remaining ~= nil then
        clock.deadline = now + clock.remaining
    end
    clock.paused = false
    clock.paused_at = nil
    clock.updated_at = now
    clock.revision = clock.revision + 1
    return true
end

function ClockService.Remove(self, clock_id)
    if self.clocks_by_id[clock_id] == nil then
        return false, ClockService.ERROR_CODES.CLOCK_NOT_FOUND
    end
    self.clocks_by_id[clock_id] = nil
    for index = 1, #self.clock_order do
        if self.clock_order[index] == clock_id then
            table.remove(self.clock_order, index)
            break
        end
    end
    return true
end

function ClockService.Close(self)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    self.closed = true
    self.clocks_by_id = {}
    self.clock_order = {}
    return true
end

function ClockService.GetSnapshot(self)
    local clocks = {}
    for index = 1, #self.clock_order do
        local clock = self.clocks_by_id[self.clock_order[index]]
        if clock ~= nil then
            table.insert(clocks, CopyValue(clock))
        end
    end
    return
    {
        schema_version = ClockService.SCHEMA_VERSION,
        clocks = clocks,
    }
end

function ClockService.GetDebugString(self)
    local paused = 0
    for index = 1, #self.clock_order do
        local clock = self.clocks_by_id[self.clock_order[index]]
        if clock ~= nil and clock.paused then
            paused = paused + 1
        end
    end
    return string.format(
        "clock_service clocks=%d paused=%d",
        #self.clock_order,
        paused
    )
end

local function AttachMethods(service)
    service.Get = ClockService.Get
    service.Create = ClockService.Create
    service.Start = ClockService.Start
    service.SetDeadline = ClockService.SetDeadline
    service.GetRemaining = ClockService.GetRemaining
    service.IsExpired = ClockService.IsExpired
    service.IsPaused = ClockService.IsPaused
    service.Pause = ClockService.Pause
    service.Resume = ClockService.Resume
    service.Remove = ClockService.Remove
    service.Close = ClockService.Close
    service.GetSnapshot = ClockService.GetSnapshot
    service.GetDebugString = ClockService.GetDebugString
    return service
end

function ClockService.New(instance, services, options)
    if type(instance) ~= "table" or type(instance.instance_id) ~= "string" then
        return nil, ClockService.ERROR_CODES.INVALID_CLOCK
    end
    options = type(options) == "table" and options or {}
    return AttachMethods(
    {
        schema_version = ClockService.SCHEMA_VERSION,
        service_id = "clock",
        service_version = 1,
        instance = instance,
        services = services or {},
        phase_service = services ~= nil and services.phase or nil,
        now_fn = options.now_fn,
        clocks_by_id = {},
        clock_order = {},
        closed = false,
    })
end

return ClockService
