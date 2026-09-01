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
    manager.Release = ZoneManager.Release
    manager.Quarantine = ZoneManager.Quarantine
    manager.GetSummary = ZoneManager.GetSummary
    manager.GetSnapshot = ZoneManager.GetSnapshot
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

function ZoneManager.Release(self, zone_id, instance_id)
    return RunZoneOperation(self, zone_id, instance_id, "Release")
end

function ZoneManager.Quarantine(self, zone_id, instance_id, reason)
    return RunZoneOperation(self, zone_id, instance_id, "Quarantine", reason)
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
