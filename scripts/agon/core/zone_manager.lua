-- WP2：按 Zone 类别管理可租用的物理空间池。

local Zone = require("agon/core/zone")

local ZoneManager = {}
ZoneManager.SCHEMA_VERSION = 1

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function IsValidCategory(category)
    return Zone.VALID_CATEGORIES[category] == true
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
        and value.min.x <= value.max.x
        and value.min.z <= value.max.z
end

local function SamePoint(left, right)
    return IsPoint(left) and IsPoint(right)
        and left.x == right.x and left.z == right.z
end

local function SameBounds(left, right)
    return IsBounds(left) and IsBounds(right)
        and SamePoint(left.min, right.min)
        and SamePoint(left.max, right.max)
end

local function AttachMethods(manager)
    manager.Get = ZoneManager.Get
    manager.List = ZoneManager.List
    manager.Count = ZoneManager.Count
    manager.GetFreeCount = ZoneManager.GetFreeCount
    manager.Reserve = ZoneManager.Reserve
    manager.ReleaseReservation = ZoneManager.ReleaseReservation
    manager.BeginBuilding = ZoneManager.BeginBuilding
    manager.Activate = ZoneManager.Activate
    manager.BeginResetting = ZoneManager.BeginResetting
    manager.BeginQuarantinedRecovery = ZoneManager.BeginQuarantinedRecovery
    manager.Release = ZoneManager.Release
    manager.Quarantine = ZoneManager.Quarantine
    manager.QuarantineRecovered = ZoneManager.QuarantineRecovered
    manager.ReleaseRecovered = ZoneManager.ReleaseRecovered
    manager.GetSummary = ZoneManager.GetSummary
    manager.GetSnapshot = ZoneManager.GetSnapshot
    manager.OnLoad = ZoneManager.OnLoad
    manager.Validate = ZoneManager.Validate
    manager.GetDebugLines = ZoneManager.GetDebugLines
    return manager
end

function ZoneManager.New(resolved_layout)
    if type(resolved_layout) ~= "table"
        or type(resolved_layout.zones) ~= "table" then
        return nil, "INVALID_LAYOUT"
    end

    local manager = AttachMethods(
    {
        schema_version = ZoneManager.SCHEMA_VERSION,
        layout_version = resolved_layout.layout_version,
        zones_by_id = {},
        zone_order = {},
    })

    for index = 1, #resolved_layout.zones do
        local zone, code = Zone.New(resolved_layout.zones[index])
        if zone == nil then
            return nil, code
        end
        if manager.zones_by_id[zone.zone_id] ~= nil then
            return nil, "DUPLICATE_ZONE_ID"
        end
        manager.zones_by_id[zone.zone_id] = zone
        table.insert(manager.zone_order, zone.zone_id)
    end

    if #manager.zone_order == 0 then
        return nil, "NO_ZONES"
    end

    local valid, validation_code = manager:Validate()
    if not valid then
        return nil, validation_code
    end
    return manager
end

function ZoneManager.Get(self, zone_id)
    if not IsNonEmptyString(zone_id) then
        return nil
    end
    return self.zones_by_id[zone_id]
end

function ZoneManager.List(self)
    local zones = {}
    for index = 1, #self.zone_order do
        table.insert(zones, self.zones_by_id[self.zone_order[index]])
    end
    return zones
end

function ZoneManager.Count(self)
    return #self.zone_order
end

function ZoneManager.GetFreeCount(self, category)
    if not IsValidCategory(category) then
        return nil, "ZONE_CATEGORY_MISMATCH"
    end

    local count = 0
    for index = 1, #self.zone_order do
        local zone = self.zones_by_id[self.zone_order[index]]
        if zone.zone_category == category and zone:IsFree() then
            count = count + 1
        end
    end
    return count
end

function ZoneManager.Reserve(self, category, instance_id)
    if not IsValidCategory(category) then
        return nil, "ZONE_CATEGORY_MISMATCH"
    end
    if not IsNonEmptyString(instance_id) then
        return nil, "INVALID_INSTANCE_ID"
    end

    for index = 1, #self.zone_order do
        local zone = self.zones_by_id[self.zone_order[index]]
        if zone.zone_category == category and zone:IsFree() then
            local reserved, code = zone:Reserve(instance_id)
            if reserved then
                return zone
            end
            return nil, code
        end
    end
    return nil, "NO_FREE_ZONE"
end

local function RunZoneOperation(self, zone_id, instance_id, method_name, ...)
    local zone = self:Get(zone_id)
    if zone == nil then
        return false, "ZONE_NOT_FOUND"
    end
    local method = zone[method_name]
    if type(method) ~= "function" then
        return false, "ZONE_OPERATION_UNAVAILABLE"
    end
    return method(zone, instance_id, ...)
end

function ZoneManager.ReleaseReservation(self, zone_id, instance_id)
    return RunZoneOperation(self, zone_id, instance_id, "ReleaseReservation")
end

function ZoneManager.BeginBuilding(self, zone_id, instance_id)
    return RunZoneOperation(self, zone_id, instance_id, "BeginBuilding")
end

function ZoneManager.Activate(self, zone_id, instance_id)
    return RunZoneOperation(self, zone_id, instance_id, "Activate")
end

function ZoneManager.BeginResetting(self, zone_id, instance_id, reason)
    return RunZoneOperation(self, zone_id, instance_id, "BeginResetting", reason)
end

function ZoneManager.BeginQuarantinedRecovery(self, zone_id, instance_id, reason)
    return RunZoneOperation(
        self,
        zone_id,
        instance_id,
        "BeginQuarantinedRecovery",
        reason
    )
end

function ZoneManager.Release(self, zone_id, instance_id)
    return RunZoneOperation(self, zone_id, instance_id, "Release")
end

function ZoneManager.Quarantine(self, zone_id, instance_id, reason)
    return RunZoneOperation(self, zone_id, instance_id, "Quarantine", reason)
end

function ZoneManager.QuarantineRecovered(self, zone_id, instance_id, reason)
    local zone = self:Get(zone_id)
    if zone == nil then
        return false, "ZONE_NOT_FOUND"
    end
    if zone.state == Zone.STATES.QUARANTINED then
        return true, "ALREADY_QUARANTINED"
    end
    if not IsNonEmptyString(instance_id) then
        return false, "INVALID_INSTANCE_ID"
    end
    if zone.state == Zone.STATES.FREE then
        local reserved, reserve_code = zone:Reserve(instance_id)
        if not reserved then
            return false, reserve_code
        end
    elseif zone.reserved_instance_id ~= instance_id then
        return false, Zone.ERROR_CODES.ZONE_OWNER_MISMATCH
    end
    return zone:Quarantine(instance_id, reason or "restart_recovery_failed")
end

function ZoneManager.ReleaseRecovered(self, zone_id, instance_id)
    local zone = self:Get(zone_id)
    if zone == nil then
        return false, "ZONE_NOT_FOUND"
    end
    if zone.state == Zone.STATES.FREE then
        return true, "ALREADY_FREE"
    end
    if zone.reserved_instance_id ~= instance_id then
        return false, Zone.ERROR_CODES.ZONE_OWNER_MISMATCH
    end
    if zone.state == Zone.STATES.QUARANTINED then
        local resetting, resetting_code = zone:BeginQuarantinedRecovery(
            instance_id,
            "restart_recovery_cleaned"
        )
        if not resetting then
            return false, resetting_code
        end
        return zone:Release(instance_id)
    elseif zone.state == Zone.STATES.RESERVED then
        return zone:ReleaseReservation(instance_id)
    elseif zone.state == Zone.STATES.BUILDING or zone.state == Zone.STATES.ACTIVE then
        local resetting, resetting_code = zone:BeginResetting(
            instance_id,
            "restart_recovery_cleaned"
        )
        if not resetting then
            return false, resetting_code
        end
        return zone:Release(instance_id)
    elseif zone.state == Zone.STATES.RESETTING then
        return zone:Release(instance_id)
    end
    return false, Zone.ERROR_CODES.ZONE_STATE_INVALID
end

function ZoneManager.GetSummary(self)
    local summary =
    {
        schema_version = self.schema_version,
        layout_version = self.layout_version,
        total = #self.zone_order,
        free = 0,
        by_category = {},
        by_state = {},
    }

    for index = 1, #self.zone_order do
        local zone = self.zones_by_id[self.zone_order[index]]
        summary.by_category[zone.zone_category] =
            (summary.by_category[zone.zone_category] or 0) + 1
        summary.by_state[zone.state] = (summary.by_state[zone.state] or 0) + 1
        if zone:IsFree() then
            summary.free = summary.free + 1
        end
    end
    return summary
end

function ZoneManager.GetSnapshot(self)
    local zones = {}
    for index = 1, #self.zone_order do
        local zone = self.zones_by_id[self.zone_order[index]]
        table.insert(zones, zone:GetSnapshot())
    end
    return
    {
        schema_version = self.schema_version,
        layout_version = self.layout_version,
        zones = zones,
    }
end

function ZoneManager.OnLoad(self, data)
    if data == nil then
        return true
    end
    if type(data) ~= "table"
        or data.schema_version ~= self.schema_version
        or (data.zones ~= nil and type(data.zones) ~= "table") then
        return false, "INVALID_ZONE_SNAPSHOT"
    end
    if data.layout_version ~= nil and data.layout_version ~= self.layout_version then
        return false, "ZONE_LAYOUT_VERSION_MISMATCH"
    end

    local seen = {}
    for index = 1, #(data.zones or {}) do
        local saved = data.zones[index]
        local saved_id = type(saved) == "table" and saved.zone_id or nil
        local zone = saved_id ~= nil and self:Get(saved_id) or nil
        if zone == nil or seen[saved_id]
            or saved.zone_category ~= zone.zone_category
            or not SamePoint(saved.center_offset, zone.center_offset)
            or not SamePoint(saved.center, zone.center)
            or not SameBounds(saved.safe_bounds, zone.safe_bounds)
            or not SameBounds(saved.build_bounds, zone.build_bounds)
            or not SameBounds(saved.hard_bounds, zone.hard_bounds)
            or not Zone.VALID_STATES[saved.state]
            or not IsInteger(saved.reservation_generation)
            or saved.reservation_generation < 0 then
            return false, "INVALID_ZONE_SNAPSHOT"
        end
        if saved.state ~= Zone.STATES.FREE
            and saved.state ~= Zone.STATES.QUARANTINED
            and not IsNonEmptyString(saved.reserved_instance_id) then
            return false, "INVALID_ZONE_SNAPSHOT"
        end
        if saved.state == Zone.STATES.FREE and saved.reserved_instance_id ~= nil then
            return false, "INVALID_ZONE_SNAPSHOT"
        end
        zone.state = saved.state
        zone.reserved_instance_id = saved.reserved_instance_id
        zone.reservation_generation = saved.reservation_generation
        zone.state_reason = saved.state_reason or "loaded"
        zone.quarantine_reason = saved.quarantine_reason
        seen[saved_id] = true
    end

    local valid, validation_code = self:Validate()
    if not valid then
        return false, validation_code or "INVALID_ZONE_SNAPSHOT"
    end
    return true
end

function ZoneManager.Validate(self)
    if type(self.zone_order) ~= "table" or #self.zone_order == 0 then
        return false, "NO_ZONES"
    end

    local seen = {}
    for index = 1, #self.zone_order do
        local zone_id = self.zone_order[index]
        local zone = self.zones_by_id[zone_id]
        if not IsNonEmptyString(zone_id) or zone == nil or seen[zone_id] then
            return false, "ZONE_INDEX_INVALID"
        end
        seen[zone_id] = true

        if not IsValidCategory(zone.zone_category)
            or not Zone.VALID_STATES[zone.state]
            or not IsInteger(zone.reservation_generation)
            or zone.reservation_generation < 0 then
            return false, "ZONE_STATE_INVALID"
        end

        if zone.state == Zone.STATES.FREE then
            if zone.reserved_instance_id ~= nil then
                return false, "FREE_ZONE_HAS_OWNER"
            end
        elseif zone.state ~= Zone.STATES.QUARANTINED
            and not IsNonEmptyString(zone.reserved_instance_id) then
            return false, "OCCUPIED_ZONE_HAS_NO_OWNER"
        end
    end
    return true
end

function ZoneManager.GetDebugLines(self)
    local lines = {}
    local summary = self:GetSummary()
    table.insert(
        lines,
        string.format(
            "zones total=%d free=%d layout_version=%s",
            summary.total,
            summary.free,
            tostring(summary.layout_version)
        )
    )
    for index = 1, #self.zone_order do
        local zone = self.zones_by_id[self.zone_order[index]]
        table.insert(lines, zone:GetDebugString())
    end
    return lines
end

return ZoneManager
