local Diagnostics = {}

Diagnostics.PREFIX = "[TheAgon]"
Diagnostics.SCHEMA_VERSION = 1

-- WP0 保持错误码集合小而稳定。后续 WP 如需扩展领域错误码，应在不改变
-- 本模块快照结构的前提下增量加入。
Diagnostics.ERROR_CODES =
{
    INVALID_WORLD = "INVALID_WORLD",
    INVALID_SNAPSHOT = "INVALID_SNAPSHOT",
    NOT_SERVER_AUTHORITY = "NOT_SERVER_AUTHORITY",
    LAYOUT_INVALID = "LAYOUT_INVALID",
    LAYOUT_VERSION_MISMATCH = "LAYOUT_VERSION_MISMATCH",
    LAYOUT_SAVE_MISMATCH = "LAYOUT_SAVE_MISMATCH",
    MAP_SIZE_MISMATCH = "MAP_SIZE_MISMATCH",
    PORTAL_NOT_FOUND = "PORTAL_NOT_FOUND",
    PORTAL_NOT_UNIQUE = "PORTAL_NOT_UNIQUE",
    PORTAL_ANCHOR_INVALID = "PORTAL_ANCHOR_INVALID",
    HALL_TILE_MISMATCH = "HALL_TILE_MISMATCH",
    VOID_TILE_MISMATCH = "VOID_TILE_MISMATCH",
    CORE_NOT_READY = "CORE_NOT_READY",
    CORE_INIT_FAILED = "CORE_INIT_FAILED",
    INVALID_ZONE = "INVALID_ZONE",
    ZONE_NOT_FOUND = "ZONE_NOT_FOUND",
    ZONE_STATE_INVALID = "ZONE_STATE_INVALID",
    ZONE_OWNER_MISMATCH = "ZONE_OWNER_MISMATCH",
    ZONE_CATEGORY_MISMATCH = "ZONE_CATEGORY_MISMATCH",
    ZONE_NOT_FREE = "ZONE_NOT_FREE",
    ZONE_QUARANTINED = "ZONE_QUARANTINED",
    NO_FREE_ZONE = "NO_FREE_ZONE",
    INVALID_MODE = "INVALID_MODE",
    DUPLICATE_MODE_ID = "DUPLICATE_MODE_ID",
    INVALID_MODE_VERSION = "INVALID_MODE_VERSION",
    UNKNOWN_SERVICE = "UNKNOWN_SERVICE",
    DUPLICATE_SERVICE = "DUPLICATE_SERVICE",
    INVALID_SERVICE_VERSION = "INVALID_SERVICE_VERSION",
    SERVICE_DEPENDENCY_MISSING = "SERVICE_DEPENDENCY_MISSING",
    INVALID_MODE_FACTORY = "INVALID_MODE_FACTORY",
    PARTICIPANTS_NOT_SUPPORTED = "PARTICIPANTS_NOT_SUPPORTED",
    INSTANCE_NOT_FOUND = "INSTANCE_NOT_FOUND",
    INVALID_INSTANCE_SNAPSHOT = "INVALID_INSTANCE_SNAPSHOT",
    INVALID_SEQUENCE = "INVALID_SEQUENCE",
    INSTANCE_INVARIANT_FAILED = "INSTANCE_INVARIANT_FAILED",
    INSTANCE_CREATE_FAILED = "INSTANCE_CREATE_FAILED",
    INSTANCE_DESTROY_FAILED = "INSTANCE_DESTROY_FAILED",
    LIFECYCLE_TRANSITION_INVALID = "LIFECYCLE_TRANSITION_INVALID",
    MODE_RUNTIME_FAILED = "MODE_RUNTIME_FAILED",
    SCOPE_INVALID = "SCOPE_INVALID",
    SCOPE_CLOSED = "SCOPE_CLOSED",
    SCOPE_INSTANCE_MISMATCH = "SCOPE_INSTANCE_MISMATCH",
    SCOPE_TRANSFER_INVALID = "SCOPE_TRANSFER_INVALID",
    SCOPE_RESOURCE_CLEANUP_FAILED = "SCOPE_RESOURCE_CLEANUP_FAILED",
    ENTITY_REGISTRATION_FAILED = "ENTITY_REGISTRATION_FAILED",
    ENTITY_NOT_FOUND = "ENTITY_NOT_FOUND",
    ENTITY_OWNER_MISMATCH = "ENTITY_OWNER_MISMATCH",
    ENTITY_REMOVE_FAILED = "ENTITY_REMOVE_FAILED",
    SPAWN_INVALID = "SPAWN_INVALID",
    SPAWN_FAILED = "SPAWN_FAILED",
    SPAWN_CONTEXT_FAILED = "SPAWN_CONTEXT_FAILED",
    SCENE_PLAN_INVALID = "SCENE_PLAN_INVALID",
    SCENE_PLAN_MISSING = "SCENE_PLAN_MISSING",
    SCENE_REVISION_STALE = "SCENE_REVISION_STALE",
    SCENE_APPLY_FAILED = "SCENE_APPLY_FAILED",
    SCENE_VALIDATION_FAILED = "SCENE_VALIDATION_FAILED",
    TERRAIN_API_UNAVAILABLE = "TERRAIN_API_UNAVAILABLE",
    TERRAIN_OUT_OF_BOUNDS = "TERRAIN_OUT_OF_BOUNDS",
    TILE_INVALID = "TILE_INVALID",
    TILE_TRANSACTION_FAILED = "TILE_TRANSACTION_FAILED",
    TILE_ROLLBACK_FAILED = "TILE_ROLLBACK_FAILED",
    OCCUPIED_TILE = "OCCUPIED_TILE",
    OCCUPANT_MOVE_FAILED = "OCCUPANT_MOVE_FAILED",
    MODE_RESOLVE_UNSUPPORTED = "MODE_RESOLVE_UNSUPPORTED",
    ZONE_NOT_EMPTY = "ZONE_NOT_EMPTY",
    PARTICIPANT_INVALID = "PARTICIPANT_INVALID",
    PARTICIPANT_ALREADY_ACTIVE = "PARTICIPANT_ALREADY_ACTIVE",
    PARTICIPANT_NOT_FOUND = "PARTICIPANT_NOT_FOUND",
    RNG_INVALID = "RNG_INVALID",
    AUDIENCE_INVALID = "AUDIENCE_INVALID",
    RPC_INVALID = "RPC_INVALID",
    PLAYER_SANDBOX_INVALID = "PLAYER_SANDBOX_INVALID",
    PLAYER_SANDBOX_RESTORE_PENDING = "PLAYER_SANDBOX_RESTORE_PENDING",
    PLAYER_SANDBOX_RESTORE_BLOCKED = "PLAYER_SANDBOX_RESTORE_BLOCKED",
}

Diagnostics.RESULTS =
{
    STARTED = "STARTED",
    ALREADY_STARTED = "ALREADY_STARTED",
    LAYOUT_READY = "LAYOUT_READY",
    CORE_READY = "CORE_READY",
    INSTANCE_CREATED = "INSTANCE_CREATED",
    INSTANCE_STARTED = "INSTANCE_STARTED",
    INSTANCE_DESTROYED = "INSTANCE_DESTROYED",
    SCENE_APPLIED = "SCENE_APPLIED",
    WP4_TEST_PASS = "WP4_TEST_PASS",
    WP5_TEST_PASS = "WP5_TEST_PASS",
    WP6_TEST_PASS = "WP6_TEST_PASS",
    WP7_TEST_PASS = "WP7_TEST_PASS",
    INSTANCE_LIST = "INSTANCE_LIST",
    ZONE_LIST = "ZONE_LIST",
}

local CONTEXT_FIELDS =
{
    "shard_id",
    "schema_version",
    "boot_generation",
    "instance_id",
    "zone_id",
    "zone_category",
    "zone_state",
    "scope_id",
    "scope_generation",
    "mode_id",
    "mode_version",
    "service_id",
    "service_version",
    "userid",
    "group_id",
    "group_type",
    "phase_id",
    "phase_revision",
    "clock_id",
    "decision_id",
    "decision_revision",
    "effect_id",
    "score_event_id",
    "lifecycle",
    "lifecycle_state",
    "from_lifecycle",
    "to_lifecycle",
    "operation",
    "reason",
    "layout_version",
    "layout_status",
    "portal_tile_x",
    "portal_tile_z",
    "offset_tile_x",
    "offset_tile_z",
    "resolved_tile_x",
    "resolved_tile_z",
    "world_x",
    "world_z",
    "portal_world_x",
    "portal_world_z",
    "map_width",
    "map_height",
    "tile_x",
    "tile_z",
    "core_status",
    "sequence",
    "scene_revision",
    "expected_scene_revision",
    "transaction_id",
    "execution_mode",
    "rollback_state",
    "profile_id",
    "profile_version",
    "parent_entity_id",
    "spawn_source",
    "instance_count",
    "zone_count",
    "free_zone_count",
    "mode_count",
    "aborted_instance_count",
}

local function CopyState(state)
    local copied =
    {
        error_count = 0,
        last_error_code = nil,
        last_message = nil,
    }

    if type(state) ~= "table" then
        return copied
    end

    if type(state.error_count) == "number" and state.error_count >= 0 then
        copied.error_count = state.error_count
    end
    if type(state.last_error_code) == "string" then
        copied.last_error_code = state.last_error_code
    end
    if type(state.last_message) == "string" then
        copied.last_message = state.last_message
    end

    return copied
end

function Diagnostics.NewState()
    return CopyState(nil)
end

function Diagnostics.CopyState(state)
    return CopyState(state)
end

function Diagnostics.Record(state, code, message)
    if type(state) ~= "table" then
        return
    end

    state.error_count = (type(state.error_count) == "number" and state.error_count or 0) + 1
    state.last_error_code = code or Diagnostics.ERROR_CODES.INVALID_SNAPSHOT
    state.last_message = message ~= nil and tostring(message) or nil
end

function Diagnostics.FormatContext(context)
    if type(context) ~= "table" then
        return ""
    end

    local fields = {}
    for i = 1, #CONTEXT_FIELDS do
        local key = CONTEXT_FIELDS[i]
        local value = context[key]
        if value ~= nil then
            table.insert(fields, key .. "=" .. tostring(value))
        end
    end
    return table.concat(fields, " ")
end

function Diagnostics.Format(code, context, message)
    local result = Diagnostics.PREFIX .. " [" .. tostring(code) .. "]"
    local context_text = Diagnostics.FormatContext(context)
    if context_text ~= "" then
        result = result .. " " .. context_text
    end
    if message ~= nil then
        result = result .. " " .. tostring(message)
    end
    return result
end

function Diagnostics.Log(code, context, message)
    print(Diagnostics.Format(code, context, message))
end

function Diagnostics.MakeSnapshot(runtime)
    return
    {
        schema_version = runtime.schema_version,
        shard_id = runtime.shard_id,
        boot_generation = runtime.boot_generation,
        diagnostics = CopyState(runtime.diagnostics),
    }
end

function Diagnostics.ValidateSnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return false, Diagnostics.ERROR_CODES.INVALID_SNAPSHOT
    end
    if snapshot.schema_version ~= Diagnostics.SCHEMA_VERSION then
        return false, Diagnostics.ERROR_CODES.INVALID_SNAPSHOT
    end
    if type(snapshot.shard_id) ~= "string" or snapshot.shard_id == "" then
        return false, Diagnostics.ERROR_CODES.INVALID_SNAPSHOT
    end
    if type(snapshot.boot_generation) ~= "number" or snapshot.boot_generation < 1 then
        return false, Diagnostics.ERROR_CODES.INVALID_SNAPSHOT
    end

    if snapshot.diagnostics ~= nil then
        if type(snapshot.diagnostics) ~= "table" then
            return false, Diagnostics.ERROR_CODES.INVALID_SNAPSHOT
        end
        if type(snapshot.diagnostics.error_count) ~= "number"
            or snapshot.diagnostics.error_count < 0 then
            return false, Diagnostics.ERROR_CODES.INVALID_SNAPSHOT
        end
        if snapshot.diagnostics.last_error_code ~= nil
            and type(snapshot.diagnostics.last_error_code) ~= "string" then
            return false, Diagnostics.ERROR_CODES.INVALID_SNAPSHOT
        end
        if snapshot.diagnostics.last_message ~= nil
            and type(snapshot.diagnostics.last_message) ~= "string" then
            return false, Diagnostics.ERROR_CODES.INVALID_SNAPSHOT
        end
    end

    return true
end

return Diagnostics
