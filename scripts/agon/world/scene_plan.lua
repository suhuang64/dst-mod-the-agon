-- WP3：声明式场景计划；Mode 只能返回计划，不能直接修改地图或生成实体。

local Diagnostics = require("agon/debug/diagnostics")

local ScenePlan = {}
ScenePlan.SCHEMA_VERSION = 1

ScenePlan.EXECUTION_MODES =
{
    BLOCKING = "BLOCKING",
    LIVE_PATCH = "LIVE_PATCH",
}

ScenePlan.OCCUPANT_POLICIES =
{
    REJECT_IF_OCCUPIED = "REJECT_IF_OCCUPIED",
    MOVE_TO_SAFE_POINT = "MOVE_TO_SAFE_POINT",
    MODE_RESOLVE = "MODE_RESOLVE",
}

ScenePlan.ANCHOR_POLICIES =
{
    INHERIT = "INHERIT",
    REPLACE = "REPLACE",
}

ScenePlan.ROLLBACK_POLICIES =
{
    ROLLBACK = "ROLLBACK",
    QUARANTINE_ON_FAILURE = "QUARANTINE_ON_FAILURE",
}

ScenePlan.ERROR_CODES =
{
    INVALID_PLAN = "SCENE_PLAN_INVALID",
    MISSING_PLAN = "SCENE_PLAN_MISSING",
    STALE_REVISION = "SCENE_REVISION_STALE",
    ANCHOR_POLICY_REQUIRED = "SCENE_ANCHOR_POLICY_REQUIRED",
    ANCHOR_INVALID = "SCENE_ANCHOR_INVALID",
    AFFECTED_BOUNDS_REQUIRED = "SCENE_AFFECTED_BOUNDS_REQUIRED",
    OCCUPANT_POLICY_REQUIRED = "SCENE_OCCUPANT_POLICY_REQUIRED",
    ROLLBACK_POLICY_REQUIRED = "SCENE_ROLLBACK_POLICY_REQUIRED",
    TILE_OUT_OF_BOUNDS = "SCENE_TILE_OUT_OF_BOUNDS",
}

local ANCHOR_FIELDS =
{
    "participant_spawn_points",
    "spectator_anchors",
    "spectator_camera_bounds",
    "emergency_safe_points",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function IsPoint(value)
    return type(value) == "table" and IsInteger(value.x) and IsInteger(value.z)
end

local function IsBounds(value)
    return type(value) == "table"
        and IsPoint(value.min)
        and IsPoint(value.max)
        and value.min.x <= value.max.x
        and value.min.z <= value.max.z
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

local function IsInsideBounds(point, bounds)
    return IsPoint(point)
        and IsBounds(bounds)
        and point.x >= bounds.min.x
        and point.x <= bounds.max.x
        and point.z >= bounds.min.z
        and point.z <= bounds.max.z
end

local function BoundsInside(inner, outer)
    return IsBounds(inner) and IsBounds(outer)
        and inner.min.x >= outer.min.x
        and inner.max.x <= outer.max.x
        and inner.min.z >= outer.min.z
        and inner.max.z <= outer.max.z
end

local function ValidatePointList(points, required, code)
    if type(points) ~= "table" or (required and #points == 0) then
        return false, code
    end
    for index = 1, #points do
        local point = points[index]
        if not IsPoint(point) then
            return false, code
        end
    end
    return true
end

local function ValidateAnchorPolicies(plan)
    if plan.kind == "INITIAL" then
        return true
    end
    if type(plan.anchor_policy) ~= "table" then
        return false, ScenePlan.ERROR_CODES.ANCHOR_POLICY_REQUIRED
    end
    for index = 1, #ANCHOR_FIELDS do
        local field = ANCHOR_FIELDS[index]
        local policy = plan.anchor_policy[field]
        if policy ~= ScenePlan.ANCHOR_POLICIES.INHERIT
            and policy ~= ScenePlan.ANCHOR_POLICIES.REPLACE then
            return false, ScenePlan.ERROR_CODES.ANCHOR_POLICY_REQUIRED
        end
        if policy == ScenePlan.ANCHOR_POLICIES.REPLACE then
            if field == "spectator_camera_bounds" then
                if not IsBounds(plan[field]) then
                    return false, ScenePlan.ERROR_CODES.ANCHOR_INVALID
                end
            elseif not ValidatePointList(plan[field], true, ScenePlan.ERROR_CODES.ANCHOR_INVALID) then
                return false, ScenePlan.ERROR_CODES.ANCHOR_INVALID
            end
        end
    end
    return true
end

local function ValidateTileChange(tile_change)
    if type(tile_change) ~= "table" or not IsPoint(tile_change) then
        return false
    end
    local has_tile = tile_change.tile ~= nil
    local has_tile_name = IsNonEmptyString(tile_change.tile_name)
    if has_tile == has_tile_name then
        return false
    end
    if has_tile and type(tile_change.tile) ~= "number" then
        return false
    end
    if tile_change.tile_name ~= nil and not has_tile_name then
        return false
    end
    return true
end

local function ValidateSpawnSpec(spawn_spec)
    return type(spawn_spec) == "table"
        and IsNonEmptyString(spawn_spec.prefab)
        and IsPoint(spawn_spec.position)
end

local function ValidateEntityIds(entity_ids)
    if entity_ids == nil then
        return true
    end
    if type(entity_ids) ~= "table" then
        return false
    end
    for index = 1, #entity_ids do
        if not IsNonEmptyString(tostring(entity_ids[index])) then
            return false
        end
    end
    return true
end

local function ValidatePlanShape(plan)
    if type(plan) ~= "table"
        or plan.schema_version ~= ScenePlan.SCHEMA_VERSION
        or not IsNonEmptyString(plan.kind)
        or (plan.execution_mode ~= ScenePlan.EXECUTION_MODES.BLOCKING
            and plan.execution_mode ~= ScenePlan.EXECUTION_MODES.LIVE_PATCH)
        or not IsInteger(plan.expected_scene_revision)
        or plan.expected_scene_revision < 0 then
        return false, ScenePlan.ERROR_CODES.INVALID_PLAN
    end

    if plan.kind == "INITIAL" and plan.expected_scene_revision ~= 0 then
        return false, ScenePlan.ERROR_CODES.INVALID_PLAN
    end
    if plan.kind ~= "INITIAL" and plan.expected_scene_revision < 0 then
        return false, ScenePlan.ERROR_CODES.INVALID_PLAN
    end

    if type(plan.tiles) ~= "table" then
        return false, ScenePlan.ERROR_CODES.INVALID_PLAN
    end
    for index = 1, #plan.tiles do
        if not ValidateTileChange(plan.tiles[index]) then
            return false, ScenePlan.ERROR_CODES.INVALID_PLAN
        end
    end

    if plan.spawn_entities ~= nil then
        if type(plan.spawn_entities) ~= "table" then
            return false, ScenePlan.ERROR_CODES.INVALID_PLAN
        end
        for index = 1, #plan.spawn_entities do
            if not ValidateSpawnSpec(plan.spawn_entities[index]) then
                return false, ScenePlan.ERROR_CODES.INVALID_PLAN
            end
        end
    end
    if not ValidateEntityIds(plan.remove_entity_ids) then
        return false, ScenePlan.ERROR_CODES.INVALID_PLAN
    end

    if plan.kind == "INITIAL" then
        if not ValidatePointList(plan.participant_spawn_points, true, ScenePlan.ERROR_CODES.ANCHOR_INVALID)
            or not ValidatePointList(plan.spectator_anchors, true, ScenePlan.ERROR_CODES.ANCHOR_INVALID)
            or not IsBounds(plan.spectator_camera_bounds)
            or not ValidatePointList(plan.emergency_safe_points, true, ScenePlan.ERROR_CODES.ANCHOR_INVALID) then
            return false, ScenePlan.ERROR_CODES.ANCHOR_INVALID
        end
    else
        local policies_valid, policy_code = ValidateAnchorPolicies(plan)
        if not policies_valid then
            return false, policy_code
        end
    end

    if plan.execution_mode == ScenePlan.EXECUTION_MODES.LIVE_PATCH then
        if not IsBounds(plan.affected_bounds) then
            return false, ScenePlan.ERROR_CODES.AFFECTED_BOUNDS_REQUIRED
        end
        if ScenePlan.OCCUPANT_POLICIES[plan.occupant_policy] ~= plan.occupant_policy then
            return false, ScenePlan.ERROR_CODES.OCCUPANT_POLICY_REQUIRED
        end
        if ScenePlan.ROLLBACK_POLICIES[plan.rollback_policy] ~= plan.rollback_policy then
            return false, ScenePlan.ERROR_CODES.ROLLBACK_POLICY_REQUIRED
        end
        if not ValidatePointList(plan.emergency_safe_points, true, ScenePlan.ERROR_CODES.ANCHOR_INVALID) then
            return false, ScenePlan.ERROR_CODES.ANCHOR_INVALID
        end
    end
    return true
end

function ScenePlan.Validate(plan, context)
    local shape_valid, shape_code = ValidatePlanShape(plan)
    if not shape_valid then
        return false, shape_code
    end
    context = type(context) == "table" and context or {}
    if context.current_scene_revision ~= nil
        and plan.expected_scene_revision ~= context.current_scene_revision then
        return false, ScenePlan.ERROR_CODES.STALE_REVISION
    end

    local build_bounds = context.build_bounds
        or (context.zone ~= nil and context.zone.build_bounds or nil)
    local hard_bounds = context.hard_bounds
        or (context.zone ~= nil and context.zone.hard_bounds or nil)
    if build_bounds ~= nil and not BoundsInside(plan.affected_bounds or build_bounds, hard_bounds or build_bounds) then
        return false, ScenePlan.ERROR_CODES.TILE_OUT_OF_BOUNDS
    end

    for index = 1, #plan.tiles do
        local tile_change = plan.tiles[index]
        if build_bounds ~= nil and not IsInsideBounds(tile_change, build_bounds) then
            return false, ScenePlan.ERROR_CODES.TILE_OUT_OF_BOUNDS
        end
    end
    if plan.spawn_entities ~= nil then
        for index = 1, #plan.spawn_entities do
            if build_bounds ~= nil
                and not IsInsideBounds(plan.spawn_entities[index].position, build_bounds) then
                return false, ScenePlan.ERROR_CODES.TILE_OUT_OF_BOUNDS
            end
        end
    end

    local function ValidateProvidedPoints(points, bounds)
        if points == nil then
            return true
        end
        for index = 1, #points do
            if not IsInsideBounds(points[index], bounds) then
                return false
            end
        end
        return true
    end
    if build_bounds ~= nil then
        if not ValidateProvidedPoints(plan.participant_spawn_points, build_bounds)
            or not ValidateProvidedPoints(plan.spectator_anchors, build_bounds)
            or (plan.spectator_camera_bounds ~= nil
                and not BoundsInside(plan.spectator_camera_bounds, build_bounds))
            or not ValidateProvidedPoints(plan.emergency_safe_points, build_bounds) then
            return false, ScenePlan.ERROR_CODES.ANCHOR_INVALID
        end
    end
    return true
end

function ScenePlan.ResolveAnchors(current_plan, patch_plan)
    if type(current_plan) ~= "table" or type(patch_plan) ~= "table" then
        return nil, ScenePlan.ERROR_CODES.ANCHOR_INVALID
    end
    local resolved = {}
    for index = 1, #ANCHOR_FIELDS do
        local field = ANCHOR_FIELDS[index]
        local policy = patch_plan.anchor_policy ~= nil and patch_plan.anchor_policy[field] or nil
        if policy == ScenePlan.ANCHOR_POLICIES.REPLACE then
            resolved[field] = CopyValue(patch_plan[field])
        else
            resolved[field] = CopyValue(current_plan[field])
        end
    end
    return resolved
end

function ScenePlan.Copy(plan)
    return CopyValue(plan)
end

function ScenePlan.GetDebugString(plan)
    return string.format(
        "scene_plan kind=%s mode=%s expected_revision=%s tiles=%d spawns=%d",
        tostring(plan.kind),
        tostring(plan.execution_mode),
        tostring(plan.expected_scene_revision),
        type(plan.tiles) == "table" and #plan.tiles or 0,
        type(plan.spawn_entities) == "table" and #plan.spawn_entities or 0
    )
end

function ScenePlan.New(data)
    if type(data) ~= "table" then
        return nil, ScenePlan.ERROR_CODES.INVALID_PLAN
    end
    local plan = CopyValue(data)
    plan.schema_version = plan.schema_version or ScenePlan.SCHEMA_VERSION
    plan.expected_scene_revision = plan.expected_scene_revision or 0
    plan.tiles = plan.tiles or {}
    plan.spawn_entities = plan.spawn_entities or {}
    plan.remove_entity_ids = plan.remove_entity_ids or {}
    plan.kind = plan.kind or "INITIAL"
    plan.execution_mode = plan.execution_mode or ScenePlan.EXECUTION_MODES.BLOCKING
    if plan.execution_mode == ScenePlan.EXECUTION_MODES.LIVE_PATCH
        and plan.emergency_safe_points == nil
        and plan.safe_points ~= nil then
        plan.emergency_safe_points = plan.safe_points
    end
    local valid, code = ScenePlan.Validate(plan)
    if not valid then
        return nil, code
    end
    return plan
end

return ScenePlan
