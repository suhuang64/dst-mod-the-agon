local Diagnostics = require("agon/debug/diagnostics")
local WorldLayout = require("agon/config/world_layout")
local LayoutService = require("agon/world/layout_service")
local LobbyService = require("agon/world/lobby_service")

local function GetShardId()
    if TheShard ~= nil and type(TheShard.GetShardId) == "function" then
        local shard_id = TheShard:GetShardId()
        if shard_id ~= nil then
            return tostring(shard_id)
        end
    end
    return "unknown"
end

local function RecordLoadError(self, code)
    local message = "runtime save data rejected"
    Diagnostics.Record(self.diagnostics, code, message)
    Diagnostics.Log(code,
        {
            shard_id = self.shard_id,
            operation = "runtime_load",
            layout_version = self.layout_version,
            layout_status = self.layout_status,
        },
        message
    )
end

local function GetMap(runtime)
    local world = runtime.inst or TheWorld
    return world ~= nil and world.Map or nil
end

local function AddLayoutContext(runtime, context)
    context = context or {}
    context.shard_id = runtime.shard_id
    context.operation = context.operation or "layout_init"
    context.layout_version = runtime.layout_version
    context.layout_status = runtime.layout_status
    return context
end

local AgonRuntime = Class(function(self, inst)
    self.inst = inst
    -- schema_version 标识快照格式；WP0 只接受当前版本，便于后续演进时拒绝未知数据。
    self.schema_version = Diagnostics.SCHEMA_VERSION
    self.shard_id = GetShardId()
    -- boot_generation 从 1 开始；每次成功加载有效快照时递增，用于区分启动代次。
    self.boot_generation = 1
    self.diagnostics = Diagnostics.NewState()
    self.layout_version = WorldLayout.layout_version
    self.layout_status = "PENDING"
    self.layout = nil
    self.saved_layout = nil
    self.failure_code = nil
end)

function AgonRuntime:OnSave()
    local snapshot = Diagnostics.MakeSnapshot(self)
    snapshot.layout_version = self.layout_version
    snapshot.layout_status = self.layout_status
    if self.layout ~= nil then
        snapshot.layout = LayoutService.CopyPureData(self.layout)
    end
    return snapshot
end

function AgonRuntime:OnLoad(data)
    if data == nil then
        return
    end

    -- 只恢复经过校验的纯数据快照；拒绝的数据不会污染当前运行态，并会记录诊断。
    local valid, code = Diagnostics.ValidateSnapshot(data)
    if not valid then
        RecordLoadError(self, code)
        return
    end

    self.schema_version = data.schema_version
    self.shard_id = data.shard_id
    -- 加载保存数据代表上一启动代，本次恢复后进入下一启动代。
    self.boot_generation = data.boot_generation + 1
    self.diagnostics = Diagnostics.CopyState(data.diagnostics)

    if data.layout_version ~= nil and data.layout_version ~= WorldLayout.layout_version then
        self.layout_status = "FAILED"
        self.failure_code = Diagnostics.ERROR_CODES.LAYOUT_VERSION_MISMATCH
        RecordLoadError(self, self.failure_code)
        return
    end

    if data.layout ~= nil then
        local map_size = type(data.layout) == "table" and data.layout.map_size or nil
        local saved_valid, saved_code = LayoutService.ValidateResolvedLayout(
            WorldLayout,
            data.layout,
            type(map_size) == "table" and map_size.width or nil,
            type(map_size) == "table" and map_size.height or nil
        )
        if not saved_valid then
            self.layout_status = "FAILED"
            self.failure_code = Diagnostics.ERROR_CODES.LAYOUT_INVALID
            RecordLoadError(self, self.failure_code)
            Diagnostics.Log(
                self.failure_code,
                AddLayoutContext(self,
                {
                    operation = "runtime_load",
                }),
                "saved layout rejected: " .. tostring(saved_code)
            )
            return
        end
        self.saved_layout = LayoutService.CopyPureData(data.layout)
    end

    if data.layout_status == "FAILED" then
        self.layout_status = "FAILED"
    end
end

function AgonRuntime:FailLayout(code, message, context)
    if self.layout_status == "FAILED" then
        return false
    end
    self.layout_status = "FAILED"
    self.failure_code = code
    self.layout = nil
    Diagnostics.Record(self.diagnostics, code, message)
    Diagnostics.Log(code, AddLayoutContext(self, context), message)
    return false
end

function AgonRuntime:InitializeLayout()
    if self.layout_status == "READY" then
        return true
    end
    if self.layout_status == "FAILED" then
        return false
    end

    local definition_valid, definition_code = LayoutService.ValidateDefinition(WorldLayout)
    if not definition_valid then
        return self:FailLayout(
            Diagnostics.ERROR_CODES.LAYOUT_INVALID,
            "WorldLayout definition rejected: " .. tostring(definition_code)
        )
    end

    local map = GetMap(self)
    if map == nil or type(map.GetSize) ~= "function" then
        return self:FailLayout(
            Diagnostics.ERROR_CODES.MAP_SIZE_MISMATCH,
            "world map is unavailable"
        )
    end

    local map_width, map_height = map:GetSize()
    if map_width ~= WorldLayout.world_size_tiles.width
        or map_height ~= WorldLayout.world_size_tiles.height then
        return self:FailLayout(
            Diagnostics.ERROR_CODES.MAP_SIZE_MISMATCH,
            string.format("unexpected map size %sx%s", tostring(map_width), tostring(map_height)),
            {
                map_width = map_width,
                map_height = map_height,
            }
        )
    end

    local portal, portal_count, portal_code = LayoutService.FindPortal(
        Ents,
        WorldLayout.lobby.portal_prefab
    )
    if portal == nil then
        local code = portal_code == LayoutService.ERROR_CODES.PORTAL_NOT_UNIQUE
            and Diagnostics.ERROR_CODES.PORTAL_NOT_UNIQUE
            or Diagnostics.ERROR_CODES.PORTAL_NOT_FOUND
        return self:FailLayout(
            code,
            string.format("expected exactly one %s, found %d", WorldLayout.lobby.portal_prefab, portal_count),
            {
                map_width = map_width,
                map_height = map_height,
            }
        )
    end
    if portal.Transform == nil or type(portal.Transform.GetWorldPosition) ~= "function" then
        return self:FailLayout(
            Diagnostics.ERROR_CODES.PORTAL_ANCHOR_INVALID,
            "Portal has no world transform"
        )
    end

    local portal_world_x, portal_world_y, portal_world_z = portal.Transform:GetWorldPosition()
    local portal_tile_x, portal_tile_z, tile_code = LayoutService.WorldToTile(
        map,
        portal_world_x,
        portal_world_y,
        portal_world_z
    )
    if portal_tile_x == nil then
        return self:FailLayout(
            Diagnostics.ERROR_CODES.PORTAL_ANCHOR_INVALID,
            "Portal world position cannot be converted to a Tile: " .. tostring(tile_code),
            {
                map_width = map_width,
                map_height = map_height,
                portal_world_x = portal_world_x,
                portal_world_z = portal_world_z,
            }
        )
    end

    local resolved, resolve_code = LayoutService.Resolve(
        WorldLayout,
        { x = portal_tile_x, z = portal_tile_z },
        map_width,
        map_height
    )
    if resolved == nil then
        return self:FailLayout(
            Diagnostics.ERROR_CODES.LAYOUT_INVALID,
            "resolved layout rejected: " .. tostring(resolve_code),
            {
                map_width = map_width,
                map_height = map_height,
                portal_tile_x = portal_tile_x,
                portal_tile_z = portal_tile_z,
                portal_world_x = portal_world_x,
                portal_world_z = portal_world_z,
            }
        )
    end

    local expected_world_x, expected_world_z = LayoutService.TileToWorld(
        portal_tile_x,
        portal_tile_z,
        map_width,
        map_height
    )
    if expected_world_x == nil
        or math.abs(portal_world_x - expected_world_x) > 0.01
        or math.abs(portal_world_z - expected_world_z) > 0.01 then
        return self:FailLayout(
            Diagnostics.ERROR_CODES.PORTAL_ANCHOR_INVALID,
            "Portal is not at the center of its resolved Tile",
            {
                map_width = map_width,
                map_height = map_height,
                portal_tile_x = portal_tile_x,
                portal_tile_z = portal_tile_z,
            }
        )
    end

    local hall_valid, hall_code, hall_context = LobbyService.ValidateHallTiles(
        map,
        map_width,
        map_height,
        { x = portal_tile_x, z = portal_tile_z }
    )
    if not hall_valid then
        hall_context = hall_context or {}
        hall_context.map_width = map_width
        hall_context.map_height = map_height
        hall_context.portal_tile_x = portal_tile_x
        hall_context.portal_tile_z = portal_tile_z
        return self:FailLayout(
            Diagnostics.ERROR_CODES.HALL_TILE_MISMATCH,
            "hall Tile validation failed: " .. tostring(hall_code),
            hall_context
        )
    end

    local void_valid, void_code, void_context = LobbyService.ValidateVoidTiles(
        map,
        map_width,
        map_height,
        { x = portal_tile_x, z = portal_tile_z }
    )
    if not void_valid then
        void_context = void_context or {}
        void_context.map_width = map_width
        void_context.map_height = map_height
        void_context.portal_tile_x = portal_tile_x
        void_context.portal_tile_z = portal_tile_z
        return self:FailLayout(
            Diagnostics.ERROR_CODES.VOID_TILE_MISMATCH,
            "void Tile validation failed: " .. tostring(void_code),
            void_context
        )
    end

    if self.saved_layout ~= nil
        and not LayoutService.AreResolvedLayoutsCompatible(self.saved_layout, resolved) then
        return self:FailLayout(
            Diagnostics.ERROR_CODES.LAYOUT_SAVE_MISMATCH,
            "saved layout does not match the current Portal anchor",
            {
                map_width = map_width,
                map_height = map_height,
                portal_tile_x = portal_tile_x,
                portal_tile_z = portal_tile_z,
            }
        )
    end

    self.layout = resolved
    self.layout_status = "READY"
    self.failure_code = nil
    Diagnostics.Log(
        Diagnostics.RESULTS.LAYOUT_READY,
        {
            shard_id = self.shard_id,
            operation = "layout_init",
            layout_version = self.layout_version,
            layout_status = self.layout_status,
            portal_tile_x = portal_tile_x,
            portal_tile_z = portal_tile_z,
            offset_tile_x = WorldLayout.lobby.center_offset.x,
            offset_tile_z = WorldLayout.lobby.center_offset.z,
            resolved_tile_x = portal_tile_x,
            resolved_tile_z = portal_tile_z,
            world_x = portal_world_x,
            world_z = portal_world_z,
            portal_world_x = portal_world_x,
            portal_world_z = portal_world_z,
            map_width = map_width,
            map_height = map_height,
        },
        "WorldLayout resolved; hall and void validation passed"
    )
    return true
end

function AgonRuntime:OnPostInit()
    -- PostInit 发生在官方 PopulateWorld 完成后，此时 worldgen 的 Portal 已在 Ents 中。
    return self:InitializeLayout()
end

function AgonRuntime:GetSnapshot()
    return self:OnSave()
end

function AgonRuntime:ValidateSnapshot()
    return Diagnostics.ValidateSnapshot(self:GetSnapshot())
end

function AgonRuntime:GetDebugString()
    local error_count = self.diagnostics ~= nil and self.diagnostics.error_count or 0
    local resolved_tile_x = self.layout ~= nil and self.layout.portal_tile.x or nil
    local resolved_tile_z = self.layout ~= nil and self.layout.portal_tile.z or nil
    local portal_world = self.layout ~= nil and self.layout.portal_world or nil
    local offset_tile_x = WorldLayout.lobby.center_offset.x
    local offset_tile_z = WorldLayout.lobby.center_offset.z
    return string.format(
        "schema=%d shard=%s boot=%d layout=%s v=%d offset=%s,%s resolved=%s,%s world=%s,%s errors=%d",
        self.schema_version,
        self.shard_id,
        self.boot_generation,
        tostring(self.layout_status),
        self.layout_version,
        tostring(offset_tile_x),
        tostring(offset_tile_z),
        tostring(resolved_tile_x),
        tostring(resolved_tile_z),
        portal_world ~= nil and tostring(portal_world.x) or "nil",
        portal_world ~= nil and tostring(portal_world.z) or "nil",
        error_count
    )
end

return AgonRuntime
