-- WP3 TestMode：用最小场景计划覆盖初始构建、BLOCKING 和 LIVE_PATCH。

local ScenePlan = require("agon/world/scene_plan")

local TestModeScenePlans = {}

local function CopyPoint(point)
    return { x = point.x, z = point.z }
end

local function AddTiles(plan, bounds, tile_name)
    for tile_x = bounds.min.x, bounds.max.x do
        for tile_z = bounds.min.z, bounds.max.z do
            table.insert(
                plan.tiles,
                { x = tile_x, z = tile_z, tile_name = tile_name }
            )
        end
    end
end

local function GetCenter(context)
    return context.zone.center
end

local function GetExpectedRevision(context)
    return context.expected_scene_revision or context.current_scene_revision or 0
end

local function InheritAnchors()
    return
    {
        participant_spawn_points = ScenePlan.ANCHOR_POLICIES.INHERIT,
        spectator_anchors = ScenePlan.ANCHOR_POLICIES.INHERIT,
        spectator_camera_bounds = ScenePlan.ANCHOR_POLICIES.INHERIT,
        emergency_safe_points = ScenePlan.ANCHOR_POLICIES.INHERIT,
    }
end

local function BuildInitial(context)
    local center = GetCenter(context)
    local zone = context.zone
    local plan =
    {
        schema_version = ScenePlan.SCHEMA_VERSION,
        kind = "INITIAL",
        execution_mode = ScenePlan.EXECUTION_MODES.BLOCKING,
        expected_scene_revision = GetExpectedRevision(context),
        tiles = {},
        participant_spawn_points =
        {
            { x = center.x - 3, z = center.z },
            { x = center.x + 3, z = center.z },
        },
        spectator_anchors =
        {
            { x = center.x, z = center.z - 3 },
            { x = center.x, z = center.z + 3 },
        },
        spectator_camera_bounds =
        {
            min = CopyPoint(zone.safe_bounds.min),
            max = CopyPoint(zone.safe_bounds.max),
        },
        emergency_safe_points =
        {
            { x = center.x + 4, z = center.z },
            { x = center.x - 4, z = center.z },
        },
        spawn_entities =
        {
            {
                prefab = "flower",
                position = { x = center.x, z = center.z },
                category = "TEST_DECOR",
                profile_id = "TEST_FLOWER",
                profile_version = 1,
                spawn_source = "test_mode:initial_flower",
            },
        },
        remove_entity_ids = {},
    }
    AddTiles(plan, zone.build_bounds, "DIRT")
    return plan
end

local function BuildBlockingPatch(context)
    local center = GetCenter(context)
    return
    {
        schema_version = ScenePlan.SCHEMA_VERSION,
        kind = "BLOCKING_PATCH",
        execution_mode = ScenePlan.EXECUTION_MODES.BLOCKING,
        expected_scene_revision = GetExpectedRevision(context),
        tiles =
        {
            { x = center.x + 1, z = center.z, tile_name = "WOODFLOOR" },
        },
        anchor_policy = InheritAnchors(),
        spawn_entities = {},
        remove_entity_ids = {},
    }
end

local function BuildLivePatch(context, operation, tile_name, occupant_policy)
    local center = GetCenter(context)
    local point =
    {
        x = operation == "LIVE_PATCH_EMPTY" and center.x + 2 or center.x,
        z = operation == "LIVE_PATCH_EMPTY" and center.z + 2 or center.z,
    }
    local anchor_policy = InheritAnchors()
    local spectator_camera_bounds = nil
    if occupant_policy == ScenePlan.OCCUPANT_POLICIES.MOVE_TO_SAFE_POINT then
        -- 该测试会把花所在的中心 Tile 改为 IMPASSABLE；相机边界必须避开它，
        -- 以便 SceneService 的最终锚点可行走性校验仍然有明确的安全区域。
        anchor_policy.spectator_camera_bounds = ScenePlan.ANCHOR_POLICIES.REPLACE
        spectator_camera_bounds =
        {
            min = { x = center.x - 5, z = center.z - 5 },
            max = { x = center.x - 5, z = center.z - 5 },
        }
    end
    return
    {
        schema_version = ScenePlan.SCHEMA_VERSION,
        kind = "LIVE_PATCH",
        execution_mode = ScenePlan.EXECUTION_MODES.LIVE_PATCH,
        expected_scene_revision = GetExpectedRevision(context),
        affected_bounds =
        {
            min = CopyPoint(point),
            max = CopyPoint(point),
        },
        occupant_policy = occupant_policy,
        rollback_policy = ScenePlan.ROLLBACK_POLICIES.ROLLBACK,
        emergency_safe_points =
        {
            { x = center.x + 4, z = center.z },
            { x = center.x - 4, z = center.z },
        },
        anchor_policy = anchor_policy,
        spectator_camera_bounds = spectator_camera_bounds,
        tiles =
        {
            { x = point.x, z = point.z, tile_name = tile_name },
        },
        spawn_entities = {},
        remove_entity_ids = {},
    }
end

function TestModeScenePlans.Create(context)
    if type(context) ~= "table" or context.zone == nil then
        return nil, "INVALID_SCENE_CONTEXT"
    end
    if context.kind == "INITIAL" then
        return BuildInitial(context)
    elseif context.kind == "BLOCKING_PATCH" then
        return BuildBlockingPatch(context)
    elseif context.kind == "LIVE_PATCH_EMPTY" then
        return BuildLivePatch(
            context,
            "LIVE_PATCH_EMPTY",
            "CHECKER",
            ScenePlan.OCCUPANT_POLICIES.REJECT_IF_OCCUPIED
        )
    elseif context.kind == "LIVE_PATCH_OCCUPIED_REJECT" then
        return BuildLivePatch(
            context,
            "LIVE_PATCH_OCCUPIED_REJECT",
            "IMPASSABLE",
            ScenePlan.OCCUPANT_POLICIES.REJECT_IF_OCCUPIED
        )
    elseif context.kind == "LIVE_PATCH_OCCUPIED_MOVE" then
        return BuildLivePatch(
            context,
            "LIVE_PATCH_OCCUPIED_MOVE",
            "IMPASSABLE",
            ScenePlan.OCCUPANT_POLICIES.MOVE_TO_SAFE_POINT
        )
    end
    return nil, "UNKNOWN_TEST_SCENE_OPERATION"
end

return TestModeScenePlans
