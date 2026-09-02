local Diagnostics = require("agon/debug/diagnostics")
local WorldLayout = require("agon/config/world_layout")
local LayoutService = require("agon/world/layout_service")
local LobbyService = require("agon/world/lobby_service")
local ZoneManager = require("agon/core/zone_manager")
local InstanceManager = require("agon/core/instance_manager")
local ModeRegistry = require("agon/modes/mode_registry")
local TestModeDefinition = require("agon/modes/test_mode/definition")
local SceneService = require("agon/world/scene_service")
local AudienceStateChannel = require("agon/net/audience_state_channel")
local Rpc = require("agon/net/rpc")
local Classified = require("agon/net/classified")
local Wp4Diagnostics = require("agon/modes/test_mode/wp4_diagnostics")

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

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
    self.core_status = "PENDING"
    self.core_failure_code = nil
    self.zone_manager = nil
    self.mode_registry = nil
    self.scene_service = nil
    self.instance_manager = nil
    self.audience_state_channel = nil
    self.rpc = nil
    self.player_classifieds = {}
    self.player_classified_players = {}
    self.player_lifecycle_listeners_registered = false
    self._agon_on_player_joined = function(_, player)
        self:OnPlayerAdded(player)
    end
    self._agon_on_player_left = function(_, player)
        self:OnPlayerRemoved(player)
    end
    self.saved_core = nil
end)

function AgonRuntime:OnSave()
    local snapshot = Diagnostics.MakeSnapshot(self)
    snapshot.layout_version = self.layout_version
    snapshot.layout_status = self.layout_status
    if self.layout ~= nil then
        snapshot.layout = LayoutService.CopyPureData(self.layout)
    end
    if self.zone_manager ~= nil and self.instance_manager ~= nil then
        snapshot.core =
        {
            schema_version = 1,
            core_status = self.core_status,
            zone_manager = self.zone_manager:GetSnapshot(),
            instance_manager = self.instance_manager:GetSnapshot(),
            audience_state_channel = self.audience_state_channel ~= nil
                and self.audience_state_channel:GetSnapshot()
                or nil,
            rpc = self.rpc ~= nil and self.rpc:GetSnapshot() or nil,
        }
    elseif self.saved_core ~= nil then
        snapshot.core = LayoutService.CopyPureData(self.saved_core)
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

    if data.core ~= nil then
        if type(data.core) ~= "table" then
            RecordLoadError(self, Diagnostics.ERROR_CODES.INVALID_INSTANCE_SNAPSHOT)
            return
        end
        self.saved_core = LayoutService.CopyPureData(data.core)
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

function AgonRuntime:FailCore(code, message, context)
    if self.core_status == "FAILED" then
        return false
    end
    self.core_status = "FAILED"
    self.core_failure_code = code
    self.zone_manager = nil
    self.mode_registry = nil
    self.scene_service = nil
    self.instance_manager = nil
    self.audience_state_channel = nil
    self.rpc = nil
    Diagnostics.Record(self.diagnostics, code, message)
    Diagnostics.Log(code, AddLayoutContext(self, context), message)
    return false
end

function AgonRuntime:InitializeCore()
    if self.core_status == "READY" then
        return true
    end
    if self.core_status == "FAILED" then
        return false
    end
    if self.layout_status ~= "READY" or self.layout == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_NOT_READY,
            "cannot initialize core before WorldLayout is ready"
        )
    end

    local zone_manager, zone_code = ZoneManager.New(self.layout)
    if zone_manager == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "ZoneManager initialization failed: " .. tostring(zone_code)
        )
    end

    local mode_registry = ModeRegistry.New()
    local mode_registered, mode_code = mode_registry:Register(TestModeDefinition)
    if not mode_registered then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "TestMode registration failed: " .. tostring(mode_code)
        )
    end

    local scene_service, scene_code = SceneService.New(
    {
        world = self.inst,
        map = GetMap(self),
        layout = self.layout,
        minimap = self.inst.minimap,
    })
    if scene_service == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "SceneService initialization failed: " .. tostring(scene_code)
        )
    end

    local instance_manager, instance_code = InstanceManager.New(
    {
        shard_id = self.shard_id,
        zone_manager = zone_manager,
        mode_registry = mode_registry,
        scene_service = scene_service,
        world = self.inst,
    })
    if instance_manager == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "InstanceManager initialization failed: " .. tostring(instance_code)
        )
    end

    local audience_state_channel = AudienceStateChannel.New(
    {
        resolve_instance_for_userid = function(userid)
            return instance_manager:GetParticipantInstanceId(userid)
        end,
    })
    local rpc, rpc_code = Rpc.New(
    {
        runtime = self,
        instance_manager = instance_manager,
        rule_policy = instance_manager.rule_policy,
    })
    if audience_state_channel == nil or rpc == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "WP4 network boundary initialization failed: " .. tostring(rpc_code)
        )
    end
    instance_manager.audience_state_channel = audience_state_channel

    if self.saved_core ~= nil then
        local loaded, load_code = instance_manager:OnLoad(self.saved_core.instance_manager)
        if not loaded then
            return self:FailCore(
                Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
                "saved Instance state rejected: " .. tostring(load_code),
                { operation = "core_load" }
            )
        end
    end

    self.zone_manager = zone_manager
    self.mode_registry = mode_registry
    self.scene_service = scene_service
    self.instance_manager = instance_manager
    self.audience_state_channel = audience_state_channel
    self.rpc = rpc
    self.core_status = "READY"
    self.core_failure_code = nil
    self:InitializePlayerTracking()

    local zone_summary = self.zone_manager:GetSummary()
    local instance_summary = self.instance_manager:GetSummary()
    Diagnostics.Log(
        Diagnostics.RESULTS.CORE_READY,
        {
            shard_id = self.shard_id,
            operation = "core_init",
            layout_version = self.layout_version,
            layout_status = self.layout_status,
            core_status = self.core_status,
            zone_count = zone_summary.total,
            free_zone_count = zone_summary.free,
            instance_count = instance_summary.instance_count,
            aborted_instance_count = instance_summary.restart_aborted_count,
        },
        "ZoneManager, InstanceManager, isolation and TestMode scene services ready"
    )
    return true
end

function AgonRuntime:InitializePlayerTracking()
    if self.player_lifecycle_listeners_registered then
        return true
    end
    if self.inst ~= nil and type(self.inst.ListenForEvent) == "function" then
        self.inst:ListenForEvent("ms_playerjoined", self._agon_on_player_joined)
        self.inst:ListenForEvent("ms_playerleft", self._agon_on_player_left)
    end
    self.player_lifecycle_listeners_registered = true
    if type(AllPlayers) == "table" then
        for _, player in ipairs(AllPlayers) do
            self:OnPlayerAdded(player)
        end
    end
    return true
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
    if not self:InitializeLayout() then
        return false
    end
    return self:InitializeCore()
end

function AgonRuntime:IsReady()
    return self.layout_status == "READY" and self.core_status == "READY"
end

function AgonRuntime:RefreshPlayerClassified(player)
    if player == nil or not IsNonEmptyString(player.userid)
        or self.instance_manager == nil
        or self.audience_state_channel == nil then
        return false
    end
    local classified = player.agon_player_classified
        or self.player_classifieds[player.userid]
    if classified == nil then
        return false
    end

    local participant = self.instance_manager:GetParticipant(player.userid)
    local instance = participant ~= nil
        and self.instance_manager:Get(participant.instance_id)
        or nil
    if participant ~= nil and instance ~= nil then
        Classified.SetParticipant(classified, participant, instance)
    else
        Classified.ClearParticipant(classified)
    end

    local payload = self.audience_state_channel:ReadPayload(
        player.userid,
        {
            instance_id = instance ~= nil and instance.instance_id or nil,
        }
    )
    Classified.SetAudiencePayload(classified, payload or {})
    return true
end

function AgonRuntime:RefreshAllPlayerClassifieds()
    for _, player in pairs(self.player_classified_players or {}) do
        self:RefreshPlayerClassified(player)
    end
    return true
end

function AgonRuntime:OnPlayerAdded(player)
    if not self:IsReady() or player == nil or not IsNonEmptyString(player.userid) then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    if type(SpawnPrefab) ~= "function" then
        return false, Diagnostics.ERROR_CODES.INVALID_WORLD
    end

    self.player_classified_players = self.player_classified_players or {}
    local classified = player.agon_player_classified
    if classified == nil then
        classified = SpawnPrefab(Classified.PREFAB)
        if classified == nil or type(classified.AttachToPlayer) ~= "function"
            or not classified:AttachToPlayer(player) then
            return false, Diagnostics.ERROR_CODES.INVALID_WORLD
        end
    end
    self.player_classifieds[player.userid] = classified
    self.player_classified_players[player.userid] = player

    local participant = self.instance_manager:GetParticipant(player.userid)
    if participant ~= nil then
        local attached, attach_code = self.instance_manager:AttachPlayer(
            participant.instance_id,
            player.userid,
            player
        )
        if not attached then
            Diagnostics.Log(
                attach_code,
                {
                    shard_id = self.shard_id,
                    operation = "player_attach",
                    userid = player.userid,
                    instance_id = participant.instance_id,
                },
                "Participant player attachment failed"
            )
        end
    end

    if type(player.ListenForEvent) == "function"
        and player._agon_player_connection_hook ~= true then
        player._agon_player_connection_hook = true
        player:ListenForEvent("onremove", function()
            self:OnPlayerRemoved(player)
        end)
    end
    self:RefreshPlayerClassified(player)
    return true
end

function AgonRuntime:OnPlayerRemoved(player)
    if player == nil or not IsNonEmptyString(player.userid) then
        return false
    end
    if self.player_classified_players ~= nil then
        self.player_classified_players[player.userid] = nil
    end
    if self.player_classifieds ~= nil then
        self.player_classifieds[player.userid] = nil
    end
    if self.instance_manager ~= nil then
        self.instance_manager:MarkDisconnected(player.userid, "player_removed")
    end
    return true
end

function AgonRuntime:AddParticipant(instance_id, userid, options)
    if not self:IsReady() then
        return nil, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local participant, code = self.instance_manager:AddParticipant(
        instance_id,
        userid,
        options
    )
    if participant ~= nil and self.player_classified_players ~= nil then
        local player = self.player_classified_players[userid]
        if player ~= nil then
            self:RefreshPlayerClassified(player)
        end
    end
    return participant, code
end

function AgonRuntime:RemoveParticipant(instance_id, userid, reason)
    if self.instance_manager == nil then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local removed, code = self.instance_manager:RemoveParticipant(
        instance_id,
        userid,
        reason
    )
    if removed and self.player_classified_players ~= nil then
        local player = self.player_classified_players[userid]
        if player ~= nil then
            self:RefreshPlayerClassified(player)
        end
    end
    return removed, code
end

function AgonRuntime:PublishAudienceState(state_id, audience, value, options)
    if not self:IsReady() or self.audience_state_channel == nil then
        return nil, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local record, code = self.audience_state_channel:Publish(
        state_id,
        audience,
        value,
        options
    )
    if record ~= nil then
        self:RefreshAllPlayerClassifieds()
    end
    return record, code
end

function AgonRuntime:RunWP4Diagnostics()
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local passed, code = Wp4Diagnostics.Run(self)
    Diagnostics.Log(
        passed and Diagnostics.RESULTS.WP4_TEST_PASS or code,
        {
            shard_id = self.shard_id,
            operation = "wp4_diagnostics",
            core_status = self.core_status,
        },
        passed and "WP4 isolation diagnostics passed" or tostring(code)
    )
    return passed, code
end

function AgonRuntime:CreateInstance(mode_id, userids)
    if not self:IsReady() then
        return nil, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    return self.instance_manager:Create(mode_id, userids)
end

function AgonRuntime:StartInstance(instance_id, reason)
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    return self.instance_manager:Start(instance_id, reason)
end

function AgonRuntime:DestroyInstance(instance_id, reason)
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    return self.instance_manager:Destroy(instance_id, reason)
end

function AgonRuntime:ApplyScene(instance_id, operation, reason)
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    return self.instance_manager:ApplyScene(instance_id, operation, reason)
end

function AgonRuntime:GetInstanceDebugData(instance_id)
    if not self:IsReady() then
        return nil, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    return self.instance_manager:GetInstanceDebugData(instance_id)
end

function AgonRuntime:ValidateCore()
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local zones_valid, zones_code = self.zone_manager:Validate()
    if not zones_valid then
        return false, zones_code
    end
    return self.instance_manager:Validate()
end

function AgonRuntime:DebugInstances()
    if not self:IsReady() then
        Diagnostics.Log(
            Diagnostics.ERROR_CODES.CORE_NOT_READY,
            { shard_id = self.shard_id, operation = "debug_instances", core_status = self.core_status },
            "InstanceManager is not ready"
        )
        return false
    end
    for _, line in ipairs(self.instance_manager:GetDebugLines()) do
        Diagnostics.Log(
            Diagnostics.RESULTS.INSTANCE_LIST,
            { shard_id = self.shard_id, operation = "debug_instances", core_status = self.core_status },
            line
        )
    end
    return true
end

function AgonRuntime:DebugZones()
    if not self:IsReady() then
        Diagnostics.Log(
            Diagnostics.ERROR_CODES.CORE_NOT_READY,
            { shard_id = self.shard_id, operation = "debug_zones", core_status = self.core_status },
            "ZoneManager is not ready"
        )
        return false
    end
    for _, line in ipairs(self.zone_manager:GetDebugLines()) do
        Diagnostics.Log(
            Diagnostics.RESULTS.ZONE_LIST,
            { shard_id = self.shard_id, operation = "debug_zones", core_status = self.core_status },
            line
        )
    end
    return true
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
    local instance_count = self.instance_manager ~= nil
        and self.instance_manager:Count()
        or 0
    local zone_count = self.zone_manager ~= nil
        and self.zone_manager:Count()
        or 0
    return string.format(
        "schema=%d shard=%s boot=%d layout=%s v=%d core=%s offset=%s,%s resolved=%s,%s world=%s,%s instances=%d zones=%d errors=%d",
        self.schema_version,
        self.shard_id,
        self.boot_generation,
        tostring(self.layout_status),
        self.layout_version,
        tostring(self.core_status),
        tostring(offset_tile_x),
        tostring(offset_tile_z),
        tostring(resolved_tile_x),
        tostring(resolved_tile_z),
        portal_world ~= nil and tostring(portal_world.x) or "nil",
        portal_world ~= nil and tostring(portal_world.z) or "nil",
        instance_count,
        zone_count,
        error_count
    )
end

return AgonRuntime
