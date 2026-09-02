-- WP3：串联 ScenePlan、TerrainService、SpawnService 和 Instance 场景 revision。

local Diagnostics = require("agon/debug/diagnostics")
local ResourceScope = require("agon/core/resource_scope")
local ScenePlan = require("agon/world/scene_plan")
local TerrainService = require("agon/world/terrain_service")
local SpawnService = require("agon/world/spawn_service")

local SceneService = {}
SceneService.SCHEMA_VERSION = 1

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

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function GetInstanceId(instance)
    if instance == nil then
        return nil
    end
    if type(instance.GetId) == "function" then
        return instance:GetId()
    end
    return instance.instance_id
end

local function GetSceneScope(instance)
    return instance.scene_scope or instance.root_scope
end

local function GetZone(instance)
    return instance.zone
end

local function GetImpassableTile()
    if type(WORLD_TILES) == "table" and WORLD_TILES.IMPASSABLE ~= nil then
        return WORLD_TILES.IMPASSABLE
    end
    if type(GROUND) == "table" and GROUND.IMPASSABLE ~= nil then
        return GROUND.IMPASSABLE
    end
    return 1
end

local function IsInsideBounds(point, bounds)
    return IsPoint(point) and IsBounds(bounds)
        and point.x >= bounds.min.x
        and point.x <= bounds.max.x
        and point.z >= bounds.min.z
        and point.z <= bounds.max.z
end

local function GetGuid(entity)
    if entity == nil then
        return nil
    end
    if entity.GUID ~= nil then
        return tostring(entity.GUID)
    end
    if entity.entity ~= nil and type(entity.entity.GetGUID) == "function" then
        local ok, guid = ProtectedCall(entity.entity.GetGUID, entity.entity)
        if ok and guid ~= nil then
            return tostring(guid)
        end
    end
    return nil
end

local function GetEntityPosition(entity)
    if entity == nil or entity.Transform == nil
        or type(entity.Transform.GetWorldPosition) ~= "function" then
        return nil
    end
    local ok, x, y, z = ProtectedCall(entity.Transform.GetWorldPosition, entity.Transform)
    if not ok then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function IsValidEntity(entity)
    if entity == nil or type(entity.IsValid) ~= "function" then
        return false
    end
    local ok, valid = ProtectedCall(entity.IsValid, entity)
    return ok and valid == true
end

local function HasTag(entity, tag)
    if entity == nil or type(entity.HasTag) ~= "function" then
        return false
    end
    local ok, result = ProtectedCall(entity.HasTag, entity, tag)
    return ok and result == true
end

local function IsPlayerEntity(entity)
    if entity == nil then
        return false
    end
    if IsNonEmptyString(entity.userid) or HasTag(entity, "player") then
        return true
    end
    return entity.components ~= nil and entity.components.playercontroller ~= nil
end

local function RemoveEntity(entity)
    if not IsValidEntity(entity) then
        return true
    end
    if type(entity.Remove) ~= "function" then
        return false
    end
    local ok = ProtectedCall(entity.Remove, entity)
    return ok
end

local function GetTileSet(plan, terrain)
    local doomed = {}
    local changes = {}
    for index = 1, #plan.tiles do
        local tile_change = plan.tiles[index]
        local after_tile, tile_code = terrain:ResolveTileId(
            tile_change.tile or tile_change.tile_name
        )
        if after_tile == nil then
            return nil, tile_code
        end
        local before_tile, before_code = terrain:GetTile(tile_change.x, tile_change.z)
        if before_tile == nil then
            return nil, before_code
        end
        local key = tostring(tile_change.x) .. ":" .. tostring(tile_change.z)
        changes[key] =
        {
            tile_x = tile_change.x,
            tile_z = tile_change.z,
            before_tile = before_tile,
            after_tile = after_tile,
        }
        if after_tile == GetImpassableTile() and before_tile ~= after_tile then
            doomed[key] = true
        end
    end
    return changes, doomed
end

local function ValidateAnchorPoint(service, point, bounds, require_walkable)
    if not IsInsideBounds(point, bounds) then
        return false, Diagnostics.ERROR_CODES.SCENE_VALIDATION_FAILED
    end
    if require_walkable then
        local walkable, walk_code = service.terrain:IsTileWalkable(point.x, point.z)
        if not walkable then
            return false, walk_code or Diagnostics.ERROR_CODES.SCENE_VALIDATION_FAILED
        end
    end
    return true
end

local function ValidateAnchorPoints(service, points, bounds, require_walkable)
    if type(points) ~= "table" then
        return false, Diagnostics.ERROR_CODES.SCENE_VALIDATION_FAILED
    end
    for index = 1, #points do
        local valid, code = ValidateAnchorPoint(service, points[index], bounds, require_walkable)
        if not valid then
            return false, code
        end
    end
    return true
end

local function ValidateCameraBounds(service, bounds, build_bounds)
    if not IsBounds(bounds) or not IsInsideBounds(bounds.min, build_bounds)
        or not IsInsideBounds(bounds.max, build_bounds) then
        return false, Diagnostics.ERROR_CODES.SCENE_VALIDATION_FAILED
    end
    for tile_x = bounds.min.x, bounds.max.x do
        for tile_z = bounds.min.z, bounds.max.z do
            local walkable, walk_code = service.terrain:IsTileWalkable(tile_x, tile_z)
            if not walkable then
                return false, walk_code or Diagnostics.ERROR_CODES.SCENE_VALIDATION_FAILED
            end
        end
    end
    return true
end

function SceneService.AttachInstance(self, instance)
    local instance_id = GetInstanceId(instance)
    if not IsNonEmptyString(instance_id)
        or type(instance.root_scope) ~= "table"
        or type(instance.entity_registry) ~= "table" then
        return false, Diagnostics.ERROR_CODES.SCENE_APPLY_FAILED
    end
    if self.instances_by_id[instance_id] ~= nil then
        return true
    end
    local scene_scope, scope_code = instance.root_scope:CreateChild("scene")
    if scene_scope == nil then
        return false, scope_code or Diagnostics.ERROR_CODES.SCOPE_INVALID
    end
    local spawn_service, spawn_code = SpawnService.New(
    {
        instance_id = instance_id,
        world = self.world,
        entity_registry = instance.entity_registry,
        root_scope = instance.root_scope,
    })
    if spawn_service == nil then
        scene_scope:Close("spawn_service_failed")
        return false, spawn_code or Diagnostics.ERROR_CODES.SPAWN_CONTEXT_FAILED
    end
    instance.scene_scope = scene_scope
    instance.spawn_service = spawn_service
    instance.scene_service = self
    self.instances_by_id[instance_id] =
    {
        instance = instance,
        scene_scope = scene_scope,
        spawn_service = spawn_service,
    }
    return true
end

function SceneService.DetachInstance(self, instance)
    local instance_id = GetInstanceId(instance)
    local context = instance_id ~= nil and self.instances_by_id[instance_id] or nil
    if context == nil then
        return true
    end
    if context.spawn_service ~= nil then
        context.spawn_service:Close()
    end
    if context.scene_scope ~= nil and not context.scene_scope:IsClosed() then
        context.scene_scope:Close("instance_detach")
    end
    self.instances_by_id[instance_id] = nil
    instance.scene_scope = nil
    instance.spawn_service = nil
    instance.scene_service = nil
    return true
end

function SceneService.BuildPlan(self, instance, kind, reason)
    if instance == nil or instance.mode_runtime == nil
        or type(instance.mode_runtime.CreateScenePlan) ~= "function" then
        return nil, Diagnostics.ERROR_CODES.SCENE_PLAN_MISSING
    end
    local zone = GetZone(instance)
    if zone == nil then
        return nil, Diagnostics.ERROR_CODES.SCENE_APPLY_FAILED
    end
    local context =
    {
        instance = instance,
        instance_id = GetInstanceId(instance),
        zone = zone,
        kind = kind or "INITIAL",
        reason = reason,
        execution_mode = kind == "LIVE_PATCH" and "LIVE_PATCH" or "BLOCKING",
        expected_scene_revision = instance.scene_revision,
        current_scene_revision = instance.scene_revision,
        current_plan = instance.scene_plan,
    }
    local ok, raw_plan, callback_code = ProtectedCall(
        instance.mode_runtime.CreateScenePlan,
        instance.mode_runtime,
        context
    )
    if not ok or raw_plan == nil then
        return nil, callback_code or Diagnostics.ERROR_CODES.SCENE_PLAN_MISSING
    end
    local plan, plan_code = ScenePlan.New(raw_plan)
    if plan == nil then
        return nil, plan_code or Diagnostics.ERROR_CODES.SCENE_PLAN_INVALID
    end
    return plan
end

function SceneService.ValidatePlan(self, instance, plan)
    local zone = GetZone(instance)
    if zone == nil then
        return false, Diagnostics.ERROR_CODES.SCENE_APPLY_FAILED
    end
    return ScenePlan.Validate(
        plan,
        {
            zone = zone,
            current_scene_revision = instance.scene_revision,
            build_bounds = zone.build_bounds,
            hard_bounds = zone.hard_bounds,
        }
    )
end

local function ResolveEffectivePlan(self, instance, plan)
    if plan.kind == "INITIAL" then
        return ScenePlan.Copy(plan)
    end
    if instance.scene_plan == nil then
        return nil, Diagnostics.ERROR_CODES.SCENE_PLAN_MISSING
    end
    local anchors, anchor_code = ScenePlan.ResolveAnchors(instance.scene_plan, plan)
    if anchors == nil then
        return nil, anchor_code
    end
    local effective = ScenePlan.Copy(plan)
    effective.participant_spawn_points = anchors.participant_spawn_points
    effective.spectator_anchors = anchors.spectator_anchors
    effective.spectator_camera_bounds = anchors.spectator_camera_bounds
    effective.emergency_safe_points = anchors.emergency_safe_points
    return effective
end

local function ValidateEffectiveAnchors(self, instance, plan)
    local zone = GetZone(instance)
    local valid, code = ValidateAnchorPoints(
        self,
        plan.participant_spawn_points,
        zone.safe_bounds,
        true
    )
    if not valid then
        return false, code
    end
    valid, code = ValidateAnchorPoints(self, plan.spectator_anchors, zone.safe_bounds, true)
    if not valid then
        return false, code
    end
    valid, code = ValidateAnchorPoints(self, plan.emergency_safe_points, zone.safe_bounds, true)
    if not valid then
        return false, code
    end
    return ValidateCameraBounds(self, plan.spectator_camera_bounds, zone.build_bounds)
end

local function ValidateAnchorBounds(instance, plan)
    local zone = GetZone(instance)
    local function PointsInBounds(points, bounds)
        if type(points) ~= "table" then
            return false
        end
        for index = 1, #points do
            if not IsInsideBounds(points[index], bounds) then
                return false
            end
        end
        return true
    end
    return PointsInBounds(plan.participant_spawn_points, zone.safe_bounds)
        and PointsInBounds(plan.spectator_anchors, zone.safe_bounds)
        and PointsInBounds(plan.emergency_safe_points, zone.safe_bounds)
        and IsBounds(plan.spectator_camera_bounds)
        and IsInsideBounds(plan.spectator_camera_bounds.min, zone.build_bounds)
        and IsInsideBounds(plan.spectator_camera_bounds.max, zone.build_bounds)
end

local function FindSafePoint(self, effective_plan, occupied_keys, used_safe_points)
    for index = 1, #effective_plan.emergency_safe_points do
        local point = effective_plan.emergency_safe_points[index]
        local key = tostring(point.x) .. ":" .. tostring(point.z)
        if not occupied_keys[key] and not used_safe_points[key] then
            local walkable = self.terrain:IsTileWalkable(point.x, point.z)
            if walkable then
                used_safe_points[key] = true
                return point
            end
        end
    end
    return nil
end

local function MoveOccupants(self, effective_plan, occupants, doomed)
    local occupied_keys = {}
    for index = 1, #occupants do
        local occupant = occupants[index]
        local key = tostring(occupant.tile.x) .. ":" .. tostring(occupant.tile.z)
        occupied_keys[key] = true
    end
    local used_safe_points = {}
    local moved = {}
    for index = 1, #occupants do
        local occupant = occupants[index]
        local destination = FindSafePoint(self, effective_plan, occupied_keys, used_safe_points)
        if destination == nil then
            return false, Diagnostics.ERROR_CODES.OCCUPANT_MOVE_FAILED, moved
        end
        local moved_ok, move_code = self.terrain:MoveEntityToTile(
            occupant.entity,
            destination.x,
            destination.z
        )
        if not moved_ok then
            return false, move_code or Diagnostics.ERROR_CODES.OCCUPANT_MOVE_FAILED, moved
        end
        local entity_guid = GetGuid(occupant.entity)
        table.insert(
            moved,
            {
                guid = entity_guid,
                entity = occupant.entity,
                before_position = occupant.position,
                after_tile = CopyValue(destination),
            }
        )
        occupied_keys[tostring(destination.x) .. ":" .. tostring(destination.z)] = true
    end
    return true, nil, moved
end

local function RestoreMoved(self, moved)
    local restored = true
    for index = #moved, 1, -1 do
        local item = moved[index]
        local position = item.before_position
        if IsValidEntity(item.entity) and position ~= nil
            and item.entity.Transform ~= nil
            and type(item.entity.Transform.SetPosition) == "function" then
            local ok = ProtectedCall(
                item.entity.Transform.SetPosition,
                item.entity.Transform,
                position.x,
                position.y or 0,
                position.z
            )
            if not ok then
                restored = false
            end
        else
            restored = false
        end
    end
    return restored
end

local function ResolveModeOccupants(self, instance, effective_plan, occupants)
    if instance.mode_runtime == nil
        or type(instance.mode_runtime.ResolveSceneOccupants) ~= "function" then
        return false, Diagnostics.ERROR_CODES.MODE_RESOLVE_UNSUPPORTED
    end
    local ok, result, callback_code = ProtectedCall(
        instance.mode_runtime.ResolveSceneOccupants,
        instance.mode_runtime,
        {
            instance = instance,
            plan = effective_plan,
            occupants = occupants,
        }
    )
    if not ok or result == false then
        return false, callback_code or Diagnostics.ERROR_CODES.OCCUPANT_MOVE_FAILED
    end
    return true
end

local function RegisterTransactionCleanup(self, transaction, scene_scope)
    local cleanup_callback = function()
        if transaction.state == "APPLIED" then
            local rolled_back = self.terrain:RollbackTransaction(transaction.terrain_transaction)
            if not rolled_back then
                transaction.rollback_state = "FAILED"
                return false
            end
            transaction.state = "ROLLED_BACK"
        end
        return true
    end
    local resource_id, code = scene_scope:RegisterCleanup(
        cleanup_callback,
        ResourceScope.POLICIES.DESTROY,
        "scene_transaction:" .. tostring(transaction.transaction_id)
    )
    if resource_id == nil then
        return nil, code
    end
    transaction.scope_resource_id = resource_id
    return resource_id
end

local function ReleaseTransactionCleanup(transaction, scene_scope)
    if transaction.scope_resource_id ~= nil
        and type(scene_scope.ReleaseResource) == "function" then
        scene_scope:ReleaseResource(transaction.scope_resource_id)
        transaction.scope_resource_id = nil
    end
end

local function RollbackSceneTransaction(self, instance, transaction, scene_scope)
    local rollback_ok = true
    if transaction.created_entity_guids ~= nil then
        local removed = instance.entity_registry:RemoveGuids(transaction.created_entity_guids)
        if not removed then
            rollback_ok = false
        end
    end
    if transaction.moved_entities ~= nil and not RestoreMoved(self, transaction.moved_entities) then
        rollback_ok = false
    end
    if transaction.terrain_transaction ~= nil
        and transaction.terrain_transaction.state ~= "ROLLED_BACK" then
        local terrain_rolled_back = self.terrain:RollbackTransaction(transaction.terrain_transaction)
        if not terrain_rolled_back then
            rollback_ok = false
        end
    end
    transaction.rollback_state = rollback_ok and "ROLLED_BACK" or "FAILED"
    transaction.state = rollback_ok and "ROLLED_BACK" or "FAILED"
    ReleaseTransactionCleanup(transaction, scene_scope)
    return rollback_ok
end

local function GetTransactionSnapshot(transaction)
    if type(transaction) ~= "table" then
        return nil
    end
    local snapshot =
    {
        schema_version = transaction.schema_version,
        transaction_id = transaction.transaction_id,
        instance_id = transaction.instance_id,
        zone_id = transaction.zone_id,
        scope_id = transaction.scope_id,
        scene_revision = transaction.scene_revision,
        execution_mode = transaction.execution_mode,
        rollback_state = transaction.rollback_state,
        state = transaction.state,
        created_entity_guids = CopyValue(transaction.created_entity_guids),
        removed_entity_guids = CopyValue(transaction.removed_entity_guids),
        moved_entities = {},
        plan = ScenePlan.Copy(transaction.plan),
    }
    for index = 1, #(transaction.moved_entities or {}) do
        local moved = transaction.moved_entities[index]
        table.insert(
            snapshot.moved_entities,
            {
                guid = moved.guid,
                before_position = CopyValue(moved.before_position),
                after_tile = CopyValue(moved.after_tile),
            }
        )
    end
    if transaction.terrain_transaction ~= nil then
        local terrain_snapshot =
        {
            schema_version = transaction.terrain_transaction.schema_version,
            transaction_id = transaction.terrain_transaction.transaction_id,
            instance_id = transaction.terrain_transaction.instance_id,
            zone_id = transaction.terrain_transaction.zone_id,
            scope_id = transaction.terrain_transaction.scope_id,
            scene_revision = transaction.terrain_transaction.scene_revision,
            execution_mode = transaction.terrain_transaction.execution_mode,
            rollback_policy = transaction.terrain_transaction.rollback_policy,
            rollback_state = transaction.terrain_transaction.rollback_state,
            state = transaction.terrain_transaction.state,
            tile_changes = {},
        }
        for index = 1, #(transaction.terrain_transaction.tile_changes or {}) do
            local tile_change = transaction.terrain_transaction.tile_changes[index]
            table.insert(
                terrain_snapshot.tile_changes,
                {
                    tile_x = tile_change.tile_x,
                    tile_z = tile_change.tile_z,
                    before_tile = tile_change.before_tile,
                    after_tile = tile_change.after_tile,
                }
            )
        end
        snapshot.terrain_transaction = terrain_snapshot
    end
    return snapshot
end

function SceneService.ApplyPlan(self, instance, raw_plan)
    if instance == nil or GetInstanceId(instance) == nil then
        return false, Diagnostics.ERROR_CODES.SCENE_APPLY_FAILED
    end
    local context = self.instances_by_id[GetInstanceId(instance)]
    if context == nil then
        return false, Diagnostics.ERROR_CODES.SCENE_APPLY_FAILED
    end
    local plan, plan_code = ScenePlan.New(raw_plan)
    if plan == nil then
        return false, plan_code or Diagnostics.ERROR_CODES.SCENE_PLAN_INVALID
    end
    local plan_valid, valid_code = self:ValidatePlan(instance, plan)
    if not plan_valid then
        return false, valid_code
    end
    local effective_plan, effective_code = ResolveEffectivePlan(self, instance, plan)
    if effective_plan == nil then
        return false, effective_code
    end
    local effective_valid, effective_valid_code = ScenePlan.Validate(
        effective_plan,
        {
            zone = instance.zone,
            current_scene_revision = instance.scene_revision,
            build_bounds = instance.zone.build_bounds,
            hard_bounds = instance.zone.hard_bounds,
        }
    )
    if not effective_valid then
        return false, effective_valid_code
    end

    if not ValidateAnchorBounds(instance, effective_plan) then
        return false, Diagnostics.ERROR_CODES.SCENE_VALIDATION_FAILED
    end

    local tile_changes, doomed = GetTileSet(effective_plan, self.terrain)
    if tile_changes == nil then
        return false, doomed
    end
    if effective_plan.execution_mode == ScenePlan.EXECUTION_MODES.LIVE_PATCH then
        for key in pairs(tile_changes) do
            if not IsInsideBounds(
                { x = tile_changes[key].tile_x, z = tile_changes[key].tile_z },
                effective_plan.affected_bounds
            ) then
                return false, Diagnostics.ERROR_CODES.TERRAIN_OUT_OF_BOUNDS
            end
        end
    end

    local occupants = {}
    if effective_plan.execution_mode == ScenePlan.EXECUTION_MODES.LIVE_PATCH
        and next(doomed) ~= nil then
        local found, occupant_code = self.terrain:FindOccupants(effective_plan.affected_bounds)
        if found == nil then
            return false, occupant_code
        end
        for index = 1, #found do
            local key = tostring(found[index].tile.x) .. ":" .. tostring(found[index].tile.z)
            if doomed[key] then
                table.insert(occupants, found[index])
            end
        end
        if #occupants > 0 and effective_plan.occupant_policy == ScenePlan.OCCUPANT_POLICIES.REJECT_IF_OCCUPIED then
            return false, Diagnostics.ERROR_CODES.OCCUPIED_TILE
        end
    end

    local next_revision = instance.scene_revision + 1
    local scene_scope = context.scene_scope
    local transaction =
    {
        schema_version = SceneService.SCHEMA_VERSION,
        transaction_id = effective_plan.transaction_id
            or (GetInstanceId(instance) .. ":scene:" .. tostring(next_revision)),
        instance_id = GetInstanceId(instance),
        zone_id = instance.zone_id,
        scope_id = scene_scope:GetId(),
        scene_revision = next_revision,
        execution_mode = effective_plan.execution_mode,
        rollback_state = "NOT_STARTED",
        state = "PREPARED",
        moved_entities = {},
        created_entity_guids = {},
        removed_entity_guids = {},
        plan = ScenePlan.Copy(effective_plan),
    }
    transaction.terrain_transaction = self.terrain:BeginTransaction(
    {
        instance_id = transaction.instance_id,
        zone_id = transaction.zone_id,
        scope_id = transaction.scope_id,
        scene_revision = next_revision,
        execution_mode = effective_plan.execution_mode,
        rollback_policy = effective_plan.rollback_policy,
        transaction_id = transaction.transaction_id,
    })
    if transaction.terrain_transaction == nil then
        return false, Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    for _, change in pairs(tile_changes) do
        local added, add_code = self.terrain:AddTileChange(
            transaction.terrain_transaction,
            {
                x = change.tile_x,
                z = change.tile_z,
                tile = change.after_tile,
            },
            instance.zone
        )
        if not added then
            return false, add_code
        end
    end

    local registered_cleanup, cleanup_code = RegisterTransactionCleanup(self, transaction, scene_scope)
    if registered_cleanup == nil then
        return false, cleanup_code or Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end

    if #occupants > 0 then
        if effective_plan.occupant_policy == ScenePlan.OCCUPANT_POLICIES.MOVE_TO_SAFE_POINT then
            local moved, move_code, moved_entities = MoveOccupants(
                self,
                effective_plan,
                occupants,
                doomed
            )
            transaction.moved_entities = moved_entities or {}
            if not moved then
                RollbackSceneTransaction(self, instance, transaction, scene_scope)
                return false, move_code
            end
        elseif effective_plan.occupant_policy == ScenePlan.OCCUPANT_POLICIES.MODE_RESOLVE then
            local resolved, resolve_code = ResolveModeOccupants(
                self,
                instance,
                effective_plan,
                occupants
            )
            if not resolved then
                RollbackSceneTransaction(self, instance, transaction, scene_scope)
                return false, resolve_code
            end
            local remaining = self.terrain:FindOccupants(effective_plan.affected_bounds)
            if remaining == nil then
                RollbackSceneTransaction(self, instance, transaction, scene_scope)
                return false, Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
            end
            for index = 1, #remaining do
                local key = tostring(remaining[index].tile.x) .. ":" .. tostring(remaining[index].tile.z)
                if doomed[key] then
                    RollbackSceneTransaction(self, instance, transaction, scene_scope)
                    return false, Diagnostics.ERROR_CODES.OCCUPIED_TILE
                end
            end
        end
    end

    local applied, apply_code = self.terrain:ApplyTransaction(transaction.terrain_transaction)
    if not applied then
        RollbackSceneTransaction(self, instance, transaction, scene_scope)
        return false, apply_code
    end
    transaction.state = "APPLIED"
    transaction.rollback_state = "NOT_REQUIRED"

    for index = 1, #effective_plan.spawn_entities do
        local spawn_spec = ScenePlan.Copy(effective_plan.spawn_entities[index])
        local position, position_code = self.terrain:GetWorldPosition(
            spawn_spec.position.x,
            spawn_spec.position.z
        )
        if position == nil then
            RollbackSceneTransaction(self, instance, transaction, scene_scope)
            return false, position_code
        end
        spawn_spec.position = position
        spawn_spec.execution_mode = effective_plan.execution_mode
        spawn_spec.spawn_source = spawn_spec.spawn_source
            or (transaction.transaction_id .. ":spawn:" .. tostring(index))
        local entity, spawn_code, records = context.spawn_service:Spawn(
            instance,
            spawn_spec,
            scene_scope
        )
        if entity == nil then
            RollbackSceneTransaction(self, instance, transaction, scene_scope)
            return false, spawn_code or Diagnostics.ERROR_CODES.SPAWN_FAILED
        end
        if type(records) == "table" then
            for record_index = 1, #records do
                table.insert(transaction.created_entity_guids, records[record_index].guid)
            end
        else
            local guid = GetGuid(entity)
            if guid ~= nil then
                table.insert(transaction.created_entity_guids, guid)
            end
        end
    end

    local final_anchor_valid, final_anchor_code = ValidateEffectiveAnchors(self, instance, effective_plan)
    if not final_anchor_valid then
        RollbackSceneTransaction(self, instance, transaction, scene_scope)
        return false, final_anchor_code
    end

    for index = 1, #effective_plan.remove_entity_ids do
        local guid = tostring(effective_plan.remove_entity_ids[index])
        local record = self.entity_registry:Get(guid)
        if record == nil then
            RollbackSceneTransaction(self, instance, transaction, scene_scope)
            return false, Diagnostics.ERROR_CODES.ENTITY_NOT_FOUND
        end
        if not IsValidEntity(record.entity) then
            RollbackSceneTransaction(self, instance, transaction, scene_scope)
            return false, Diagnostics.ERROR_CODES.ENTITY_REMOVE_FAILED
        end
    end
    for index = 1, #effective_plan.remove_entity_ids do
        local guid = tostring(effective_plan.remove_entity_ids[index])
        local removed, remove_code = self.entity_registry:Remove(guid)
        if not removed then
            transaction.rollback_state = "FAILED"
            transaction.state = "FAILED"
            ReleaseTransactionCleanup(transaction, scene_scope)
            return false, remove_code or Diagnostics.ERROR_CODES.ENTITY_REMOVE_FAILED
        end
        table.insert(transaction.removed_entity_guids, guid)
    end
    local committed, commit_code = self.terrain:CommitTransaction(transaction.terrain_transaction)
    if not committed then
        RollbackSceneTransaction(self, instance, transaction, scene_scope)
        return false, commit_code
    end
    transaction.state = "COMMITTED"
    transaction.rollback_state = "COMMITTED"
    ReleaseTransactionCleanup(transaction, scene_scope)

    effective_plan.scene_revision = next_revision
    instance.scene_revision = next_revision
    instance.scene_plan = ScenePlan.Copy(effective_plan)
    instance.scene_transactions = instance.scene_transactions or {}
    table.insert(instance.scene_transactions, transaction)
    return true, nil, transaction
end

function SceneService.ApplyModePlan(self, instance, kind, reason)
    local plan, plan_code = self:BuildPlan(instance, kind, reason)
    if plan == nil then
        return false, plan_code
    end
    return self:ApplyPlan(instance, plan)
end

function SceneService.Reset(self, instance, reason)
    local instance_id = GetInstanceId(instance)
    local context = instance_id ~= nil and self.instances_by_id[instance_id] or nil
    if context == nil then
        return false, Diagnostics.ERROR_CODES.SCENE_APPLY_FAILED
    end
    local removed, remove_code = instance.entity_registry:RemoveAll()
    if not removed then
        return false, remove_code or Diagnostics.ERROR_CODES.ENTITY_REMOVE_FAILED
    end
    local cleared, clear_code = self.terrain:ClearZone(
        instance_id,
        instance.zone,
        instance.root_scope:GetId(),
        instance.scene_revision
    )
    if not cleared then
        return false, clear_code or Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    local valid, valid_code = self.terrain:ValidateZoneCleared(instance.zone)
    if not valid then
        return false, valid_code
    end
    self:DetachInstance(instance)
    if instance.root_scope ~= nil and not instance.root_scope:IsClosed() then
        local scope_closed, scope_code = instance.root_scope:Close(reason or "scene_reset")
        if not scope_closed then
            return false, scope_code or Diagnostics.ERROR_CODES.SCOPE_RESOURCE_CLEANUP_FAILED
        end
    end
    return true
end

-- WP9：重启采用 ABORT_ON_RESTART；此处只清理保存 Instance 的实体和地形，
-- 不重新构造 Mode、Scope、Group 或玩家 Participant。
function SceneService.RecoverSnapshot(self, snapshot, zone, reason)
    if type(snapshot) ~= "table"
        or not IsNonEmptyString(snapshot.instance_id)
        or type(zone) ~= "table"
        or not IsBounds(zone.hard_bounds) then
        return false, Diagnostics.ERROR_CODES.SCENE_APPLY_FAILED
    end

    local occupants, occupants_code = self.terrain:FindOccupants(zone.hard_bounds)
    if occupants == nil then
        return false, occupants_code or Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end
    for index = 1, #occupants do
        if IsPlayerEntity(occupants[index].entity) then
            return false, Diagnostics.ERROR_CODES.ZONE_NOT_EMPTY
        end
    end
    for index = #occupants, 1, -1 do
        if not RemoveEntity(occupants[index].entity) then
            return false, Diagnostics.ERROR_CODES.ENTITY_REMOVE_FAILED
        end
    end

    local remaining, remaining_code = self.terrain:FindOccupants(zone.hard_bounds)
    if remaining == nil then
        return false, remaining_code or Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end
    if #remaining > 0 then
        return false, Diagnostics.ERROR_CODES.ZONE_NOT_EMPTY
    end

    local scene_snapshot = snapshot.scene
    local scope_id = type(scene_snapshot) == "table"
        and type(scene_snapshot.scope) == "table"
        and scene_snapshot.scope.scope_id
        or snapshot.instance_id .. ":recovery"
    local scene_revision = type(scene_snapshot) == "table"
        and scene_snapshot.scene_revision
        or snapshot.scene_revision
        or 0
    local cleared, clear_code = self.terrain:ClearZone(
        snapshot.instance_id,
        zone,
        scope_id,
        scene_revision
    )
    if not cleared then
        return false, clear_code or Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    local valid, valid_code = self.terrain:ValidateZoneCleared(zone)
    if not valid then
        return false, valid_code or Diagnostics.ERROR_CODES.ZONE_NOT_EMPTY
    end
    return true
end

function SceneService.Validate(self, instance)
    local context = self.instances_by_id[GetInstanceId(instance)]
    if context == nil then
        return false, Diagnostics.ERROR_CODES.SCENE_APPLY_FAILED
    end
    if instance.scene_plan ~= nil then
        local plan_valid, plan_code = ScenePlan.Validate(
            instance.scene_plan,
            {
                zone = instance.zone,
                build_bounds = instance.zone.build_bounds,
                hard_bounds = instance.zone.hard_bounds,
            }
        )
        if not plan_valid then
            return false, plan_code
        end
    end
    local registry_valid, registry_code = instance.entity_registry:Validate(
        function(scope_id)
            if instance.root_scope ~= nil and instance.root_scope:GetId() == scope_id then
                return instance.root_scope
            end
            if context.scene_scope ~= nil and context.scene_scope:GetId() == scope_id then
                return context.scene_scope
            end
            return nil
        end
    )
    if not registry_valid then
        return false, registry_code
    end
    return true
end

function SceneService.GetSnapshot(self, instance)
    local context = self.instances_by_id[GetInstanceId(instance)]
    local snapshot =
    {
        schema_version = SceneService.SCHEMA_VERSION,
        scene_revision = instance.scene_revision,
        scene_plan = ScenePlan.Copy(instance.scene_plan),
        scene_transactions = {},
        terrain = self.terrain:GetSnapshot(),
        scope = context ~= nil and context.scene_scope:GetSnapshot() or nil,
        entities = instance.entity_registry:GetSnapshot(),
    }
    for index = 1, #(instance.scene_transactions or {}) do
        local transaction = GetTransactionSnapshot(instance.scene_transactions[index])
        if transaction ~= nil then
            table.insert(snapshot.scene_transactions, transaction)
        end
    end
    return snapshot
end

function SceneService.GetDebugLines(self, instance)
    local lines =
    {
        string.format(
            "scene_service instance=%s revision=%s transactions=%d",
            tostring(GetInstanceId(instance)),
            tostring(instance.scene_revision),
            #(instance.scene_transactions or {})
        ),
    }
    local context = self.instances_by_id[GetInstanceId(instance)]
    if context ~= nil then
        table.insert(lines, context.spawn_service:GetDebugString())
        local scope_lines = context.scene_scope:GetDebugLines()
        for index = 1, #scope_lines do
            table.insert(lines, scope_lines[index])
        end
    end
    local entity_lines = instance.entity_registry:GetDebugLines()
    for index = 1, #entity_lines do
        table.insert(lines, entity_lines[index])
    end
    return lines
end

local function AttachMethods(service)
    service.AttachInstance = SceneService.AttachInstance
    service.DetachInstance = SceneService.DetachInstance
    service.BuildPlan = SceneService.BuildPlan
    service.ValidatePlan = SceneService.ValidatePlan
    service.ApplyPlan = SceneService.ApplyPlan
    service.ApplyModePlan = SceneService.ApplyModePlan
    service.Reset = SceneService.Reset
    service.RecoverSnapshot = SceneService.RecoverSnapshot
    service.Validate = SceneService.Validate
    service.GetSnapshot = SceneService.GetSnapshot
    service.GetDebugLines = SceneService.GetDebugLines
    return service
end

function SceneService.New(options)
    if type(options) ~= "table" or options.world == nil or options.map == nil
        or options.layout == nil then
        return nil, Diagnostics.ERROR_CODES.SCENE_APPLY_FAILED
    end
    local terrain, terrain_code = TerrainService.New(
    {
        world = options.world,
        map = options.map,
        minimap = options.minimap,
        layout = options.layout,
        sim = options.sim,
    })
    if terrain == nil then
        return nil, terrain_code or Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end
    return AttachMethods(
    {
        schema_version = SceneService.SCHEMA_VERSION,
        world = options.world,
        layout = options.layout,
        terrain = terrain,
        instances_by_id = {},
    })
end

return SceneService
