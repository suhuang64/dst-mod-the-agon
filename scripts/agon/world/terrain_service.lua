-- WP3：Instance 地形事务的唯一执行入口。

local Diagnostics = require("agon/debug/diagnostics")
local LayoutService = require("agon/world/layout_service")

local TerrainService = {}
TerrainService.SCHEMA_VERSION = 1

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function IsInteger(value)
    return IsFiniteNumber(value) and value == math.floor(value)
end

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
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

local function GetInvalidTile()
    if type(WORLD_TILES) == "table" and WORLD_TILES.INVALID ~= nil then
        return WORLD_TILES.INVALID
    end
    if type(GROUND) == "table" and GROUND.INVALID ~= nil then
        return GROUND.INVALID
    end
    return 65535
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

local function GetTileScale()
    if type(TILE_SCALE) == "number" and TILE_SCALE > 0 then
        return TILE_SCALE
    end
    return 4
end

local function TileKey(tile_x, tile_z)
    return tostring(tile_x) .. ":" .. tostring(tile_z)
end

local function IsInsideBounds(point, bounds)
    return IsPoint(point) and IsBounds(bounds)
        and point.x >= bounds.min.x
        and point.x <= bounds.max.x
        and point.z >= bounds.min.z
        and point.z <= bounds.max.z
end

local function GetEntityPosition(entity)
    if entity == nil or entity.Transform == nil
        or type(entity.Transform.GetWorldPosition) ~= "function" then
        return nil
    end
    local ok, x, y, z = ProtectedCall(entity.Transform.GetWorldPosition, entity.Transform)
    if not ok or not IsFiniteNumber(x) or not IsFiniteNumber(y) or not IsFiniteNumber(z) then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function HasTag(entity, tag)
    if entity == nil or type(entity.HasTag) ~= "function" then
        return false
    end
    local ok, has_tag = ProtectedCall(entity.HasTag, entity, tag)
    return ok and has_tag == true
end

local function IsValidEntity(entity)
    if entity == nil or type(entity.IsValid) ~= "function" then
        return false
    end
    local ok, valid = ProtectedCall(entity.IsValid, entity)
    return ok and valid == true
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

local function GetWorldMap(self)
    return self.map or (self.world ~= nil and self.world.Map or nil)
end

function TerrainService.ResolveTileId(self, tile_or_name)
    if type(tile_or_name) == "number" and IsInteger(tile_or_name)
        and tile_or_name ~= GetInvalidTile() then
        return tile_or_name
    end
    if type(tile_or_name) == "string" then
        local name = string.upper(tile_or_name)
        if type(WORLD_TILES) == "table" and WORLD_TILES[name] ~= nil then
            return WORLD_TILES[name]
        end
        if type(GROUND) == "table" and GROUND[name] ~= nil then
            return GROUND[name]
        end
    end
    return nil, Diagnostics.ERROR_CODES.TILE_INVALID
end

function TerrainService.GetWorldPosition(self, tile_x, tile_z)
    if not IsInteger(tile_x) or not IsInteger(tile_z)
        or tile_x < 0 or tile_x >= self.map_width
        or tile_z < 0 or tile_z >= self.map_height then
        return nil, Diagnostics.ERROR_CODES.TERRAIN_OUT_OF_BOUNDS
    end
    local world_x, world_z = LayoutService.TileToWorld(
        tile_x,
        tile_z,
        self.map_width,
        self.map_height
    )
    if world_x == nil then
        return nil, Diagnostics.ERROR_CODES.TERRAIN_OUT_OF_BOUNDS
    end
    return { x = world_x, y = 0, z = world_z }
end

function TerrainService.GetTile(self, tile_x, tile_z)
    local position, position_code = self:GetWorldPosition(tile_x, tile_z)
    if position == nil then
        return nil, position_code
    end
    local map = GetWorldMap(self)
    if map == nil or type(map.GetTileAtPoint) ~= "function" then
        return nil, Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end
    local ok, tile = ProtectedCall(
        map.GetTileAtPoint,
        map,
        position.x,
        position.y,
        position.z
    )
    if not ok or type(tile) ~= "number" or tile == GetInvalidTile() then
        return nil, Diagnostics.ERROR_CODES.TILE_INVALID
    end
    return tile
end

function TerrainService.GetTileAtWorld(self, world_x, world_y, world_z)
    local map = GetWorldMap(self)
    if map == nil or type(map.GetTileCoordsAtPoint) ~= "function"
        or not IsFiniteNumber(world_x)
        or not IsFiniteNumber(world_y)
        or not IsFiniteNumber(world_z) then
        return nil, nil, Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end
    local ok, tile_x, tile_z = ProtectedCall(
        map.GetTileCoordsAtPoint,
        map,
        world_x,
        world_y,
        world_z
    )
    if not ok or not IsInteger(tile_x) or not IsInteger(tile_z)
        or tile_x < 0 or tile_x >= self.map_width
        or tile_z < 0 or tile_z >= self.map_height then
        return nil, nil, Diagnostics.ERROR_CODES.TERRAIN_OUT_OF_BOUNDS
    end
    return tile_x, tile_z
end

local function RebuildLayer(map, tile, tile_x, tile_z)
    if type(map.RebuildLayer) ~= "function" then
        return true
    end
    local ok = ProtectedCall(map.RebuildLayer, map, tile, tile_x, tile_z)
    return ok
end

local function RebuildMinimap(self, tile, tile_x, tile_z)
    local minimap = self.minimap
    if minimap == nil and self.world ~= nil then
        minimap = self.world.minimap
    end
    local mini_map = minimap ~= nil and minimap.MiniMap or nil
    if mini_map == nil or type(mini_map.RebuildLayer) ~= "function" then
        return true
    end
    return ProtectedCall(mini_map.RebuildLayer, mini_map, tile, tile_x, tile_z)
end

local function ChangeTile(self, tile_x, tile_z, tile)
    local map = GetWorldMap(self)
    if map == nil or type(map.SetTile) ~= "function" then
        return false, Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end
    local before_tile, before_code = self:GetTile(tile_x, tile_z)
    if before_tile == nil then
        return false, before_code
    end
    if before_tile == tile then
        return true, before_tile
    end
    local ok = ProtectedCall(map.SetTile, map, tile_x, tile_z, tile)
    if not ok then
        return false, Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    if not RebuildLayer(map, before_tile, tile_x, tile_z)
        or not RebuildLayer(map, tile, tile_x, tile_z)
        or not RebuildMinimap(self, before_tile, tile_x, tile_z)
        or not RebuildMinimap(self, tile, tile_x, tile_z) then
        return false, Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    return true, before_tile
end

function TerrainService.BeginTransaction(self, data)
    data = type(data) == "table" and data or {}
    if not IsNonEmptyString(data.instance_id)
        or not IsNonEmptyString(data.zone_id)
        or not IsNonEmptyString(data.scope_id)
        or not IsInteger(data.scene_revision)
        or data.scene_revision < 0
        or not IsNonEmptyString(data.execution_mode) then
        return nil, Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    self.next_transaction_sequence = self.next_transaction_sequence + 1
    local transaction_id = data.transaction_id
        or (data.instance_id .. ":terrain:" .. tostring(self.next_transaction_sequence))
    return
    {
        schema_version = TerrainService.SCHEMA_VERSION,
        transaction_id = transaction_id,
        instance_id = data.instance_id,
        zone_id = data.zone_id,
        scope_id = data.scope_id,
        scene_revision = data.scene_revision,
        execution_mode = data.execution_mode,
        rollback_policy = data.rollback_policy,
        rollback_state = "NOT_STARTED",
        state = "PREPARED",
        tile_changes = {},
        change_keys = {},
        applied_count = 0,
        allow_hard_bounds = data.allow_hard_bounds == true,
    }
end

function TerrainService.AddTileChange(self, transaction, tile_change, zone)
    if type(transaction) ~= "table"
        or transaction.state ~= "PREPARED"
        or type(tile_change) ~= "table"
        or not IsPoint(tile_change) then
        return false, Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    local bounds = transaction.allow_hard_bounds and zone.hard_bounds or zone.build_bounds
    if not IsInsideBounds(tile_change, bounds) then
        return false, Diagnostics.ERROR_CODES.TERRAIN_OUT_OF_BOUNDS
    end
    local desired_tile, tile_code = self:ResolveTileId(tile_change.tile or tile_change.tile_name)
    if desired_tile == nil then
        return false, tile_code
    end
    local key = TileKey(tile_change.x, tile_change.z)
    transaction.change_keys = transaction.change_keys or {}
    if transaction.change_keys[key] then
        return false, Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    transaction.change_keys[key] = true
    table.insert(
        transaction.tile_changes,
        {
            tile_x = tile_change.x,
            tile_z = tile_change.z,
            after_tile = desired_tile,
        }
    )
    return true
end

function TerrainService.ApplyTransaction(self, transaction)
    if type(transaction) ~= "table" or transaction.state ~= "PREPARED" then
        return false, Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    transaction.rollback_state = "NOT_STARTED"
    for index = 1, #transaction.tile_changes do
        local change = transaction.tile_changes[index]
        local before_tile, before_code = self:GetTile(change.tile_x, change.tile_z)
        if before_tile == nil then
            transaction.state = "FAILED"
            self:RollbackTransaction(transaction)
            return false, before_code
        end
        change.before_tile = before_tile
        if before_tile ~= change.after_tile then
            transaction.applied_count = index
            local changed, change_code = ChangeTile(
                self,
                change.tile_x,
                change.tile_z,
                change.after_tile
            )
            if not changed then
                transaction.state = "FAILED"
                self:RollbackTransaction(transaction)
                return false, change_code
            end
        end
    end
    transaction.rollback_state = "NOT_REQUIRED"
    transaction.state = "APPLIED"
    return true
end

function TerrainService.RollbackTransaction(self, transaction)
    if type(transaction) ~= "table"
        or (transaction.state ~= "APPLIED" and transaction.state ~= "FAILED") then
        return false, Diagnostics.ERROR_CODES.TILE_ROLLBACK_FAILED
    end
    transaction.rollback_state = "IN_PROGRESS"
    local rollback_ok = true
    local last_code = nil
    local upper = transaction.applied_count or #transaction.tile_changes
    for index = upper, 1, -1 do
        local change = transaction.tile_changes[index]
        if change.before_tile ~= nil and change.before_tile ~= change.after_tile then
            local restored, restore_code = ChangeTile(
                self,
                change.tile_x,
                change.tile_z,
                change.before_tile
            )
            if not restored then
                rollback_ok = false
                last_code = restore_code
            end
        end
    end
    if rollback_ok then
        transaction.rollback_state = "ROLLED_BACK"
        transaction.state = "ROLLED_BACK"
        return true
    end
    transaction.rollback_state = "FAILED"
    transaction.state = "FAILED"
    return false, last_code or Diagnostics.ERROR_CODES.TILE_ROLLBACK_FAILED
end

function TerrainService.CommitTransaction(self, transaction)
    if type(transaction) ~= "table" or transaction.state ~= "APPLIED" then
        return false, Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    transaction.state = "COMMITTED"
    transaction.rollback_state = "COMMITTED"
    return true
end

function TerrainService.FindOccupants(self, bounds)
    if not IsBounds(bounds) then
        return nil, Diagnostics.ERROR_CODES.TERRAIN_OUT_OF_BOUNDS
    end
    local sim = self.sim
    if sim == nil and type(TheSim) ~= "nil" then
        sim = TheSim
    end
    if sim == nil or type(sim.FindEntities) ~= "function" then
        return nil, Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end

    local center_x = (bounds.min.x + bounds.max.x) / 2
    local center_z = (bounds.min.z + bounds.max.z) / 2
    local center = self:GetWorldPosition(math.floor(center_x), math.floor(center_z))
    if center == nil then
        return nil, Diagnostics.ERROR_CODES.TERRAIN_OUT_OF_BOUNDS
    end
    local scale = GetTileScale()
    local half_x = (bounds.max.x - bounds.min.x + 1) * scale / 2
    local half_z = (bounds.max.z - bounds.min.z + 1) * scale / 2
    local radius = math.sqrt(half_x * half_x + half_z * half_z) + scale
    local ok, found = ProtectedCall(
        sim.FindEntities,
        sim,
        center.x,
        0,
        center.z,
        radius,
        nil,
        { "INLIMBO", "FX" }
    )
    if not ok or type(found) ~= "table" then
        return nil, Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end

    local occupants = {}
    local seen = {}
    for index = 1, #found do
        local entity = found[index]
        if entity ~= self.world and IsValidEntity(entity) and not HasTag(entity, "INLIMBO") then
            local position = GetEntityPosition(entity)
            if position ~= nil then
                local tile_x, tile_z = self:GetTileAtWorld(position.x, position.y, position.z)
                if tile_x ~= nil and IsInsideBounds({ x = tile_x, z = tile_z }, bounds) then
                    local guid = GetGuid(entity) or tostring(entity)
                    if not seen[guid] then
                        seen[guid] = true
                        table.insert(
                            occupants,
                            {
                                entity = entity,
                                guid = guid,
                                tile = { x = tile_x, z = tile_z },
                                position = position,
                            }
                        )
                    end
                end
            end
        end
    end
    return occupants
end

function TerrainService.IsTileWalkable(self, tile_x, tile_z)
    local tile, code = self:GetTile(tile_x, tile_z)
    if tile == nil then
        return false, code
    end
    return tile ~= GetImpassableTile()
end

function TerrainService.MoveEntityToTile(self, entity, tile_x, tile_z)
    local walkable, walk_code = self:IsTileWalkable(tile_x, tile_z)
    if not walkable then
        return false, walk_code or Diagnostics.ERROR_CODES.OCCUPANT_MOVE_FAILED
    end
    local position, position_code = self:GetWorldPosition(tile_x, tile_z)
    if position == nil then
        return false, position_code
    end
    if not IsValidEntity(entity) then
        return false, Diagnostics.ERROR_CODES.OCCUPANT_MOVE_FAILED
    end

    if entity.Physics ~= nil and type(entity.Physics.Teleport) == "function" then
        local ok = ProtectedCall(entity.Physics.Teleport, entity.Physics, position.x, 0, position.z)
        if ok then
            return true
        end
    end
    if entity.Transform == nil or type(entity.Transform.SetPosition) ~= "function" then
        return false, Diagnostics.ERROR_CODES.OCCUPANT_MOVE_FAILED
    end
    local ok = ProtectedCall(entity.Transform.SetPosition, entity.Transform, position.x, 0, position.z)
    if not ok then
        return false, Diagnostics.ERROR_CODES.OCCUPANT_MOVE_FAILED
    end
    return true
end

function TerrainService.ValidateZoneCleared(self, zone)
    if type(zone) ~= "table" or not IsBounds(zone.hard_bounds) then
        return false, Diagnostics.ERROR_CODES.TERRAIN_OUT_OF_BOUNDS
    end
    local impassable = GetImpassableTile()
    for tile_x = zone.hard_bounds.min.x, zone.hard_bounds.max.x do
        for tile_z = zone.hard_bounds.min.z, zone.hard_bounds.max.z do
            local tile, code = self:GetTile(tile_x, tile_z)
            if tile == nil then
                return false, code
            end
            if tile ~= impassable then
                return false, Diagnostics.ERROR_CODES.TERRAIN_OUT_OF_BOUNDS
            end
        end
    end
    local occupants, occupant_code = self:FindOccupants(zone.hard_bounds)
    if occupants == nil then
        return false, occupant_code
    end
    if #occupants > 0 then
        return false, Diagnostics.ERROR_CODES.ZONE_NOT_EMPTY
    end
    return true
end

function TerrainService.ClearZone(self, instance_id, zone, scope_id, scene_revision)
    if type(zone) ~= "table" or not IsNonEmptyString(instance_id)
        or not IsNonEmptyString(scope_id) then
        return false, Diagnostics.ERROR_CODES.TILE_TRANSACTION_FAILED
    end
    local transaction, transaction_code = self:BeginTransaction(
    {
        instance_id = instance_id,
        zone_id = zone.zone_id,
        scope_id = scope_id,
        scene_revision = scene_revision or 0,
        execution_mode = "BLOCKING",
        rollback_policy = "QUARANTINE_ON_FAILURE",
        allow_hard_bounds = true,
    })
    if transaction == nil then
        return false, transaction_code
    end
    local impassable = GetImpassableTile()
    for tile_x = zone.hard_bounds.min.x, zone.hard_bounds.max.x do
        for tile_z = zone.hard_bounds.min.z, zone.hard_bounds.max.z do
            local added, add_code = self:AddTileChange(
                transaction,
                { x = tile_x, z = tile_z, tile = impassable },
                zone
            )
            if not added then
                return false, add_code
            end
        end
    end
    local applied, apply_code = self:ApplyTransaction(transaction)
    if not applied then
        return false, apply_code, transaction
    end
    local committed, commit_code = self:CommitTransaction(transaction)
    if not committed then
        return false, commit_code, transaction
    end
    local cleared, clear_code = self:ValidateZoneCleared(zone)
    if not cleared then
        return false, clear_code, transaction
    end
    return true, nil, transaction
end

function TerrainService.GetSnapshot(self)
    return
    {
        schema_version = TerrainService.SCHEMA_VERSION,
        map_size = { width = self.map_width, height = self.map_height },
        next_transaction_sequence = self.next_transaction_sequence,
    }
end

function TerrainService.GetDebugString(self)
    return string.format(
        "terrain_service map=%dx%d transactions=%d",
        self.map_width,
        self.map_height,
        self.next_transaction_sequence
    )
end

local function AttachMethods(service)
    service.ResolveTileId = TerrainService.ResolveTileId
    service.GetWorldPosition = TerrainService.GetWorldPosition
    service.GetTile = TerrainService.GetTile
    service.GetTileAtWorld = TerrainService.GetTileAtWorld
    service.BeginTransaction = TerrainService.BeginTransaction
    service.AddTileChange = TerrainService.AddTileChange
    service.ApplyTransaction = TerrainService.ApplyTransaction
    service.RollbackTransaction = TerrainService.RollbackTransaction
    service.CommitTransaction = TerrainService.CommitTransaction
    service.FindOccupants = TerrainService.FindOccupants
    service.IsTileWalkable = TerrainService.IsTileWalkable
    service.MoveEntityToTile = TerrainService.MoveEntityToTile
    service.ValidateZoneCleared = TerrainService.ValidateZoneCleared
    service.ClearZone = TerrainService.ClearZone
    service.GetSnapshot = TerrainService.GetSnapshot
    service.GetDebugString = TerrainService.GetDebugString
    return service
end

function TerrainService.New(options)
    if type(options) ~= "table" or options.map == nil or options.layout == nil
        or type(options.layout.map_size) ~= "table"
        or not IsInteger(options.layout.map_size.width)
        or not IsInteger(options.layout.map_size.height)
        or options.layout.map_size.width <= 0
        or options.layout.map_size.height <= 0 then
        return nil, Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end
    if type(options.map.GetTileAtPoint) ~= "function"
        or type(options.map.SetTile) ~= "function"
        or type(options.map.GetTileCoordsAtPoint) ~= "function" then
        return nil, Diagnostics.ERROR_CODES.TERRAIN_API_UNAVAILABLE
    end
    return AttachMethods(
    {
        schema_version = TerrainService.SCHEMA_VERSION,
        world = options.world,
        map = options.map,
        minimap = options.minimap,
        layout = options.layout,
        map_width = options.layout.map_size.width,
        map_height = options.layout.map_size.height,
        sim = options.sim,
        next_transaction_sequence = 0,
    })
end

return TerrainService
