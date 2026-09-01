-- WP2：描述一个可重复租用的物理 Zone 槽位。

local Zone = {}

Zone.STATES =
{
    FREE = "FREE",
    RESERVED = "RESERVED",
    BUILDING = "BUILDING",
    ACTIVE = "ACTIVE",
    RESETTING = "RESETTING",
    QUARANTINED = "QUARANTINED",
}

Zone.VALID_STATES =
{
    FREE = true,
    RESERVED = true,
    BUILDING = true,
    ACTIVE = true,
    RESETTING = true,
    QUARANTINED = true,
}

Zone.VALID_CATEGORIES =
{
    SMALL = true,
    MEDIUM = true,
    LARGE = true,
}

-- RESERVED → FREE 是“尚未开始构建时回滚 reservation”的受控例外。
Zone.TRANSITIONS =
{
    FREE = { RESERVED = true },
    RESERVED = { FREE = true, BUILDING = true, QUARANTINED = true },
    BUILDING = { ACTIVE = true, RESETTING = true, QUARANTINED = true },
    ACTIVE = { RESETTING = true, QUARANTINED = true },
    RESETTING = { FREE = true, QUARANTINED = true },
    QUARANTINED = {},
}

Zone.ERROR_CODES =
{
    INVALID_ZONE = "INVALID_ZONE",
    ZONE_CATEGORY_MISMATCH = "ZONE_CATEGORY_MISMATCH",
    ZONE_STATE_INVALID = "ZONE_STATE_INVALID",
    ZONE_OWNER_MISMATCH = "ZONE_OWNER_MISMATCH",
    ZONE_NOT_FREE = "ZONE_NOT_FREE",
    ZONE_NOT_RESERVED = "ZONE_NOT_RESERVED",
    ZONE_QUARANTINED = "ZONE_QUARANTINED",
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

local function IsPoint(value)
    return type(value) == "table"
        and IsInteger(value.x)
        and IsInteger(value.z)
end

local function IsBounds(value)
    return type(value) == "table"
        and IsPoint(value.min)
        and IsPoint(value.max)
        and type(value.size) == "table"
        and IsInteger(value.size.width)
        and IsInteger(value.size.height)
end

function Zone.GetId(self)
    return self.zone_id
end

function Zone.GetCategory(self)
    return self.zone_category
end

function Zone.GetState(self)
    return self.state
end

function Zone.IsFree(self)
    return self.state == Zone.STATES.FREE
end

function Zone.IsQuarantined(self)
    return self.state == Zone.STATES.QUARANTINED
end

function Zone.GetOwner(self)
    return self.reserved_instance_id
end

function Zone.GetReservationGeneration(self)
    return self.reservation_generation
end

function Zone.OwnerMatches(self, instance_id)
    return IsNonEmptyString(instance_id)
        and self.reserved_instance_id == instance_id
end

function Zone.CanTransition(self, next_state)
    local transitions = Zone.TRANSITIONS[self.state]
    return transitions ~= nil and transitions[next_state] == true
end

local function RequireOwner(self, instance_id)
    if not self:OwnerMatches(instance_id) then
        return false, Zone.ERROR_CODES.ZONE_OWNER_MISMATCH
    end
    return true
end

local function TransitionOwned(self, next_state, instance_id, reason)
    local owner_valid, owner_code = RequireOwner(self, instance_id)
    if not owner_valid then
        return false, owner_code
    end
    if not self:CanTransition(next_state) then
        return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
    end

    self.state = next_state
    self.state_reason = reason ~= nil and tostring(reason) or nil
    return true
end

function Zone.Reserve(self, instance_id)
    if not IsNonEmptyString(instance_id) then
        return false, Zone.ERROR_CODES.INVALID_ZONE
    end
    if self.state == Zone.STATES.QUARANTINED then
        return false, Zone.ERROR_CODES.ZONE_QUARANTINED
    end
    if self.state ~= Zone.STATES.FREE then
        return false, Zone.ERROR_CODES.ZONE_NOT_FREE
    end
    if not self:CanTransition(Zone.STATES.RESERVED) then
        return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
    end

    self.state = Zone.STATES.RESERVED
    self.reserved_instance_id = instance_id
    self.reservation_generation = self.reservation_generation + 1
    self.state_reason = "reserved"
    self.quarantine_reason = nil
    return true
end

function Zone.BeginBuilding(self, instance_id)
    return TransitionOwned(self, Zone.STATES.BUILDING, instance_id, "building")
end

function Zone.Activate(self, instance_id)
    return TransitionOwned(self, Zone.STATES.ACTIVE, instance_id, "active")
end

function Zone.BeginResetting(self, instance_id, reason)
    return TransitionOwned(self, Zone.STATES.RESETTING, instance_id, reason or "resetting")
end

function Zone.ReleaseReservation(self, instance_id)
    local owner_valid, owner_code = RequireOwner(self, instance_id)
    if not owner_valid then
        return false, owner_code
    end
    if self.state ~= Zone.STATES.RESERVED then
        return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
    end
    if not self:CanTransition(Zone.STATES.FREE) then
        return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
    end

    self.state = Zone.STATES.FREE
    self.reserved_instance_id = nil
    self.state_reason = "reservation_rollback"
    return true
end

function Zone.Release(self, instance_id)
    local owner_valid, owner_code = RequireOwner(self, instance_id)
    if not owner_valid then
        return false, owner_code
    end
    if self.state ~= Zone.STATES.RESETTING then
        return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
    end
    if not self:CanTransition(Zone.STATES.FREE) then
        return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
    end

    self.state = Zone.STATES.FREE
    self.reserved_instance_id = nil
    self.state_reason = "released"
    return true
end

function Zone.Quarantine(self, instance_id, reason)
    if self.state == Zone.STATES.FREE then
        return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
    end
    if self.reserved_instance_id ~= nil and self.reserved_instance_id ~= instance_id then
        return false, Zone.ERROR_CODES.ZONE_OWNER_MISMATCH
    end
    if not self:CanTransition(Zone.STATES.QUARANTINED) then
        return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
    end

    self.state = Zone.STATES.QUARANTINED
    self.state_reason = "quarantined"
    self.quarantine_reason = reason ~= nil and tostring(reason) or "unspecified"
    return true
end

function Zone.TransitionTo(self, next_state, instance_id, reason)
    if not Zone.VALID_STATES[next_state] then
        return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
    end
    if next_state == Zone.STATES.RESERVED then
        return self:Reserve(instance_id)
    elseif next_state == Zone.STATES.BUILDING then
        return self:BeginBuilding(instance_id)
    elseif next_state == Zone.STATES.ACTIVE then
        return self:Activate(instance_id)
    elseif next_state == Zone.STATES.RESETTING then
        return self:BeginResetting(instance_id, reason)
    elseif next_state == Zone.STATES.QUARANTINED then
        return self:Quarantine(instance_id, reason)
    elseif next_state == Zone.STATES.FREE then
        if self.state == Zone.STATES.RESERVED then
            return self:ReleaseReservation(instance_id)
        elseif self.state == Zone.STATES.RESETTING then
            return self:Release(instance_id)
        elseif self.state == Zone.STATES.FREE then
            return true
        end
    end
    return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
end

function Zone.GetSnapshot(self)
    return
    {
        zone_id = self.zone_id,
        zone_category = self.zone_category,
        center_offset = CopyValue(self.center_offset),
        center = CopyValue(self.center),
        center_world = CopyValue(self.center_world),
        safe_bounds = CopyValue(self.safe_bounds),
        build_bounds = CopyValue(self.build_bounds),
        hard_bounds = CopyValue(self.hard_bounds),
        state = self.state,
        reserved_instance_id = self.reserved_instance_id,
        reservation_generation = self.reservation_generation,
        state_reason = self.state_reason,
        quarantine_reason = self.quarantine_reason,
    }
end

function Zone.GetDebugString(self)
    return string.format(
        "zone_id=%s category=%s state=%s owner=%s reservation_generation=%d",
        tostring(self.zone_id),
        tostring(self.zone_category),
        tostring(self.state),
        tostring(self.reserved_instance_id),
        self.reservation_generation
    )
end

local function AttachMethods(zone)
    zone.GetId = Zone.GetId
    zone.GetCategory = Zone.GetCategory
    zone.GetState = Zone.GetState
    zone.IsFree = Zone.IsFree
    zone.IsQuarantined = Zone.IsQuarantined
    zone.GetOwner = Zone.GetOwner
    zone.GetReservationGeneration = Zone.GetReservationGeneration
    zone.OwnerMatches = Zone.OwnerMatches
    zone.CanTransition = Zone.CanTransition
    zone.Reserve = Zone.Reserve
    zone.BeginBuilding = Zone.BeginBuilding
    zone.Activate = Zone.Activate
    zone.BeginResetting = Zone.BeginResetting
    zone.ReleaseReservation = Zone.ReleaseReservation
    zone.Release = Zone.Release
    zone.Quarantine = Zone.Quarantine
    zone.TransitionTo = Zone.TransitionTo
    zone.GetSnapshot = Zone.GetSnapshot
    zone.GetDebugString = Zone.GetDebugString
    return zone
end

function Zone.New(data)
    if type(data) ~= "table"
        or not IsNonEmptyString(data.zone_id)
        or not Zone.VALID_CATEGORIES[data.zone_category]
        or not IsPoint(data.center_offset)
        or not IsPoint(data.center)
        or not IsBounds(data.safe_bounds)
        or not IsBounds(data.build_bounds)
        or not IsBounds(data.hard_bounds) then
        return nil, Zone.ERROR_CODES.INVALID_ZONE
    end

    return AttachMethods(
    {
        zone_id = data.zone_id,
        zone_category = data.zone_category,
        center_offset = CopyValue(data.center_offset),
        center = CopyValue(data.center),
        center_world = CopyValue(data.center_world),
        safe_bounds = CopyValue(data.safe_bounds),
        build_bounds = CopyValue(data.build_bounds),
        hard_bounds = CopyValue(data.hard_bounds),
        state = Zone.STATES.FREE,
        reserved_instance_id = nil,
        reservation_generation = 0,
        state_reason = "initial",
        quarantine_reason = nil,
    })
end

return Zone
