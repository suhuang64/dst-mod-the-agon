local Diagnostics = require("agon/debug/diagnostics")
local WorldLayout = require("agon/config/world_layout")
local LayoutService = require("agon/world/layout_service")
local LobbyService = require("agon/world/lobby_service")
local SpectatorService = require("agon/player/spectator_service")
local ZoneManager = require("agon/core/zone_manager")
local InstanceManager = require("agon/core/instance_manager")
local ModeRegistry = require("agon/modes/mode_registry")
local CommonServiceRegistry = require("agon/services/common_service_registry")
local EntityProfileRegistry = require("agon/services/entity_profile_registry")
local TestModeDefinition = require("agon/modes/test_mode/definition")
local SceneService = require("agon/world/scene_service")
local AudienceStateChannel = require("agon/net/audience_state_channel")
local Rpc = require("agon/net/rpc")
local Classified = require("agon/net/classified")
local PersistenceSchema = require("agon/persistence/schema")
local PersistenceMigrations = require("agon/persistence/migrations")
local RestoreQueue = require("agon/player/restore_queue")
local BackendAdapter = require("agon/backend/backend_adapter")
local Wp4Diagnostics = require("agon/modes/test_mode/wp4_diagnostics")
local Wp5Diagnostics = require("agon/modes/test_mode/wp5_diagnostics")
local Wp6Diagnostics = require("agon/modes/test_mode/wp6_diagnostics")
local Wp7Diagnostics = require("agon/modes/test_mode/wp7_diagnostics")
local Wp8Diagnostics = require("agon/modes/test_mode/wp8_diagnostics")
local Wp9Diagnostics = require("agon/modes/test_mode/wp9_diagnostics")

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

local function IsInsideBounds(point, bounds)
    return type(point) == "table"
        and type(bounds) == "table"
        and type(bounds.min) == "table"
        and type(bounds.max) == "table"
        and point.x >= bounds.min.x
        and point.x <= bounds.max.x
        and point.z >= bounds.min.z
        and point.z <= bounds.max.z
end

local function GetPlayerPosition(player)
    if player == nil or player.Transform == nil
        or type(player.Transform.GetWorldPosition) ~= "function" then
        return nil
    end
    local ok, x, y, z = pcall(player.Transform.GetWorldPosition, player.Transform)
    if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function MakeRecoverySummary()
    return
    {
        aborted = 0,
        recovered = 0,
        quarantined = 0,
        restore_transactions = 0,
    }
end

local function NormalizeRecoverySummary(value)
    if value == nil then
        return MakeRecoverySummary()
    end
    local copied, copy_code = PersistenceSchema.CopyPure(value)
    if type(copied) ~= "table" then
        return nil, copy_code or Diagnostics.ERROR_CODES.PERSISTENCE_INVALID_SNAPSHOT
    end

    local normalized = MakeRecoverySummary()
    for field in pairs(normalized) do
        if copied[field] ~= nil then
            if type(copied[field]) ~= "number"
                or copied[field] ~= math.floor(copied[field])
                or copied[field] < 0 then
                return nil, Diagnostics.ERROR_CODES.PERSISTENCE_INVALID_SNAPSHOT
            end
            normalized[field] = copied[field]
        end
    end
    return normalized
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
    self.common_service_registry = nil
    self.entity_profile_registry = nil
    self.scene_service = nil
    self.lobby_service = nil
    self.spectator_service = nil
    self.instance_manager = nil
    self.audience_state_channel = nil
    self.rpc = nil
    self.restore_queue = nil
    self.backend_adapter = nil
    self.recovery_summary =
    {
        aborted = 0,
        recovered = 0,
        quarantined = 0,
        restore_transactions = 0,
    }
    self.saved_restore_queue = nil
    self.saved_backend = nil
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
    snapshot.persistence =
    {
        schema_version = PersistenceSchema.SCHEMA_VERSION,
        restart_policy = PersistenceSchema.RESTART_POLICY,
    }
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
            entity_profile_registry = self.entity_profile_registry ~= nil
                and self.entity_profile_registry:GetSnapshot()
                or nil,
            audience_state_channel = self.audience_state_channel ~= nil
                and self.audience_state_channel:GetSnapshot()
                or nil,
            rpc = self.rpc ~= nil and self.rpc:GetSnapshot() or nil,
        }
    elseif self.saved_core ~= nil then
        snapshot.core = LayoutService.CopyPureData(self.saved_core)
    end
    snapshot.restore_queue = self.restore_queue ~= nil
        and self.restore_queue:GetSnapshot()
        or PersistenceSchema.CopyPure(self.saved_restore_queue)
    snapshot.backend = self.backend_adapter ~= nil
        and self.backend_adapter:GetSnapshot()
        or PersistenceSchema.CopyPure(self.saved_backend)
    snapshot.recovery = PersistenceSchema.CopyPure(self.recovery_summary)

    local valid, valid_code = PersistenceSchema.ValidateSnapshot(snapshot)
    if not valid then
        Diagnostics.Record(
            self.diagnostics,
            Diagnostics.ERROR_CODES.PERSISTENCE_NON_SERIALIZABLE,
            tostring(valid_code)
        )
        Diagnostics.Log(
            Diagnostics.ERROR_CODES.PERSISTENCE_NON_SERIALIZABLE,
            {
                shard_id = self.shard_id,
                operation = "runtime_save",
                boot_generation = self.boot_generation,
            },
            "Runtime snapshot rejected by pure-data schema: " .. tostring(valid_code)
        )
        -- 即使某个可选扩展字段异常，也返回官方存档接口可接受的安全最小快照。
        local safe = Diagnostics.MakeSnapshot(self)
        safe.persistence = PersistenceSchema.CopyPure(snapshot.persistence)
        safe.layout_version = self.layout_version
        safe.layout_status = self.layout_status
        if self.layout ~= nil then
            safe.layout = LayoutService.CopyPureData(self.layout)
        end

        -- 尽量保留恢复所需的 core 子快照；单个可选字段异常时不能把活动
        -- Instance/Zone 整体丢掉，否则下一次启动无法执行 ABORT_ON_RESTART。
        local core_source = snapshot.core or self.saved_core
        if type(core_source) == "table" then
            local safe_core =
            {
                schema_version = core_source.schema_version or 1,
                core_status = core_source.core_status or self.core_status,
            }
            for _, field in ipairs(
                {
                    "zone_manager",
                    "instance_manager",
                    "entity_profile_registry",
                    "audience_state_channel",
                    "rpc",
                }
            ) do
                local copied_field = PersistenceSchema.CopyPure(core_source[field])
                if copied_field ~= nil then
                    safe_core[field] = copied_field
                end
            end
            safe.core = PersistenceSchema.CopyPure(safe_core)
        end

        local restore_source = self.restore_queue ~= nil
            and self.restore_queue:GetSnapshot()
            or self.saved_restore_queue
        local copied_restore = PersistenceSchema.CopyPure(restore_source)
        if copied_restore ~= nil then
            safe.restore_queue = copied_restore
        end
        local backend_source = self.backend_adapter ~= nil
            and self.backend_adapter:GetSnapshot()
            or self.saved_backend
        local copied_backend = PersistenceSchema.CopyPure(backend_source)
        if copied_backend ~= nil then
            safe.backend = copied_backend
        end
        local copied_recovery = PersistenceSchema.CopyPure(self.recovery_summary)
        if copied_recovery ~= nil then
            safe.recovery = copied_recovery
        end
        return safe
    end
    return snapshot
end

function AgonRuntime:OnLoad(data)
    if data == nil then
        return
    end

    -- 先迁移并严格复制；拒绝的数据不会污染当前运行态，并会记录诊断。
    local migrated, migration_code = PersistenceMigrations.Migrate(data)
    if migrated == nil then
        RecordLoadError(self, migration_code)
        return
    end
    local valid, code = Diagnostics.ValidateSnapshot(migrated)
    if not valid then
        RecordLoadError(self, code)
        return
    end
    local persistence_valid, persistence_code = PersistenceSchema.ValidateSnapshot(migrated)
    if not persistence_valid then
        RecordLoadError(self, persistence_code)
        return
    end
    data = migrated

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
        local copied_core, core_code = PersistenceSchema.CopyPure(data.core)
        if copied_core == nil then
            RecordLoadError(
                self,
                core_code or Diagnostics.ERROR_CODES.PERSISTENCE_INVALID_SNAPSHOT
            )
            return
        end
        self.saved_core = copied_core
    end
    if data.restore_queue ~= nil then
        local copied_restore, restore_code = PersistenceSchema.CopyPure(data.restore_queue)
        if copied_restore == nil then
            RecordLoadError(
                self,
                restore_code or Diagnostics.ERROR_CODES.RESTORE_QUEUE_INVALID
            )
            return
        end
        self.saved_restore_queue = copied_restore
    end
    if data.backend ~= nil then
        local copied_backend, backend_code = PersistenceSchema.CopyPure(data.backend)
        if copied_backend == nil then
            RecordLoadError(
                self,
                backend_code or Diagnostics.ERROR_CODES.PERSISTENCE_INVALID_SNAPSHOT
            )
            return
        end
        self.saved_backend = copied_backend
    end
    if data.recovery ~= nil then
        local recovery, recovery_code = NormalizeRecoverySummary(data.recovery)
        if recovery == nil then
            RecordLoadError(
                self,
                recovery_code or Diagnostics.ERROR_CODES.PERSISTENCE_INVALID_SNAPSHOT
            )
            return
        end
        self.recovery_summary = recovery
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
    self.common_service_registry = nil
    self.entity_profile_registry = nil
    self.scene_service = nil
    self.lobby_service = nil
    self.spectator_service = nil
    self.instance_manager = nil
    self.audience_state_channel = nil
    self.rpc = nil
    self.restore_queue = nil
    self.backend_adapter = nil
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

    local entity_profile_registry = EntityProfileRegistry.New()
    local registered_mode = mode_registry:Get(TestModeDefinition.mode_id)
    if entity_profile_registry == nil or registered_mode == nil
        or type(registered_mode.RegisterProfiles) ~= "function" then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "EntityProfileRegistry initialization failed"
        )
    end
    local profiles_registered, profiles_code = registered_mode.RegisterProfiles(
        entity_profile_registry
    )
    if not profiles_registered then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "TestMode profile registration failed: " .. tostring(profiles_code)
        )
    end
    local profiles_valid, profiles_valid_code = entity_profile_registry:Validate()
    if not profiles_valid then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "EntityProfileRegistry validation failed: " .. tostring(profiles_valid_code)
        )
    end

    local common_service_registry = CommonServiceRegistry.New()
    if common_service_registry == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "CommonServiceRegistry initialization failed"
        )
    end

    local restore_queue = RestoreQueue.New({ now_fn = function()
        return self:Now()
    end })
    if restore_queue == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "RestoreQueue initialization failed"
        )
    end
    if self.saved_restore_queue ~= nil then
        local queue_loaded, queue_code = restore_queue:OnLoad(self.saved_restore_queue)
        if not queue_loaded then
            return self:FailCore(
                Diagnostics.ERROR_CODES.RESTORE_QUEUE_INVALID,
                "saved restore queue rejected: " .. tostring(queue_code),
                { operation = "core_load" }
            )
        end
    end

    local backend_adapter = BackendAdapter.New(
    {
        now_fn = function()
            return self:Now()
        end,
    })
    if backend_adapter == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "BackendAdapter initialization failed"
        )
    end
    if self.saved_backend ~= nil then
        local backend_loaded, backend_code = backend_adapter:OnLoad(self.saved_backend)
        if not backend_loaded then
            return self:FailCore(
                Diagnostics.ERROR_CODES.PERSISTENCE_INVALID_SNAPSHOT,
                "saved backend state rejected: " .. tostring(backend_code),
                { operation = "core_load" }
            )
        end
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

    local lobby_service, lobby_code = LobbyService.New(
    {
        world = self.inst,
        map = GetMap(self),
        layout = self.layout,
        spawn_points = WorldLayout.lobby.spawn_and_return_points,
    })
    if lobby_service == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "LobbyService initialization failed: " .. tostring(lobby_code)
        )
    end

    local instance_manager, instance_code = InstanceManager.New(
    {
        shard_id = self.shard_id,
        zone_manager = zone_manager,
        mode_registry = mode_registry,
        scene_service = scene_service,
        world = self.inst,
        common_service_registry = common_service_registry,
        profile_registry = entity_profile_registry,
        restore_enqueue_fn = function(transaction, participant)
            return restore_queue:Enqueue(transaction, participant)
        end,
    })
    if instance_manager == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "InstanceManager initialization failed: " .. tostring(instance_code)
        )
    end

    local spectator_service, spectator_code = SpectatorService.New(
    {
        runtime = self,
        world = self.inst,
        layout = self.layout,
        instance_manager = instance_manager,
        scene_service = scene_service,
        lobby_service = lobby_service,
    })
    if spectator_service == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "SpectatorService initialization failed: " .. tostring(spectator_code)
        )
    end
    instance_manager.spectator_service = spectator_service

    local audience_state_channel = AudienceStateChannel.New(
    {
        resolve_instance_for_userid = function(userid)
            local participant_instance_id = instance_manager:GetParticipantInstanceId(userid)
            if participant_instance_id ~= nil then
                return participant_instance_id
            end
            local session = spectator_service:GetSession(userid)
            return session ~= nil and session.instance_id or nil
        end,
        resolve_groups_for_userid = function(userid)
            local participant = instance_manager:GetParticipant(userid)
            if participant == nil then
                return {}
            end
            return participant:GetGroupIds()
        end,
        resolve_spectating_instance_for_userid = function(userid)
            local session = spectator_service:GetSession(userid)
            return session ~= nil and session.instance_id or nil
        end,
    })
    local rpc, rpc_code = Rpc.New(
    {
        runtime = self,
        instance_manager = instance_manager,
        rule_policy = instance_manager.rule_policy,
        spectator_service = spectator_service,
        dispatch_fn = function(context, request)
            return self:DispatchRpc(context, request)
        end,
    })
    if audience_state_channel == nil or rpc == nil then
        return self:FailCore(
            Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
            "WP4 network boundary initialization failed: " .. tostring(rpc_code)
        )
    end
    instance_manager.audience_state_channel = audience_state_channel

    if self.saved_core ~= nil then
        local zones_loaded, zones_code = zone_manager:OnLoad(self.saved_core.zone_manager)
        if not zones_loaded then
            return self:FailCore(
                Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
                "saved Zone state rejected: " .. tostring(zones_code),
                { operation = "core_load" }
            )
        end
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
    self.common_service_registry = common_service_registry
    self.entity_profile_registry = entity_profile_registry
    self.scene_service = scene_service
    self.lobby_service = lobby_service
    self.spectator_service = spectator_service
    self.instance_manager = instance_manager
    self.audience_state_channel = audience_state_channel
    self.rpc = rpc
    self.restore_queue = restore_queue
    self.backend_adapter = backend_adapter

    if self.saved_core ~= nil then
        local audience_loaded, audience_code = audience_state_channel:OnLoad(
            self.saved_core.audience_state_channel
        )
        if not audience_loaded then
            return self:FailCore(
                Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
                "saved audience state rejected: " .. tostring(audience_code),
                { operation = "core_load" }
            )
        end
        local rpc_loaded, rpc_code = rpc:OnLoad(self.saved_core.rpc)
        if not rpc_loaded then
            return self:FailCore(
                Diagnostics.ERROR_CODES.CORE_INIT_FAILED,
                "saved RPC state rejected: " .. tostring(rpc_code),
                { operation = "core_load" }
            )
        end
    end
    self.core_status = "READY"
    self.core_failure_code = nil

    self:PrepareRecoveryPlayers()
    local recovered, recovery_summary = instance_manager:RecoverOnRestart()
    if not recovered then
        return self:FailCore(
            Diagnostics.ERROR_CODES.RECOVERY_FAILED,
            "restart recovery failed: " .. tostring(recovery_summary),
            { operation = "restart_recovery" }
        )
    end
    self.recovery_summary = recovery_summary or self.recovery_summary
    Diagnostics.Log(
        self.recovery_summary.quarantined > 0
            and Diagnostics.RESULTS.RECOVERY_PARTIAL
            or Diagnostics.RESULTS.RECOVERY_COMPLETE,
        {
            shard_id = self.shard_id,
            operation = "restart_recovery",
            core_status = self.core_status,
            aborted_instance_count = self.recovery_summary.aborted,
            quarantined_zone_count = self.recovery_summary.quarantined,
            pending_restore_count = restore_queue:GetPendingCount(),
        },
        self.recovery_summary.quarantined > 0
            and "restart recovery completed with quarantined zones"
            or "restart recovery completed"
    )
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
        "ZoneManager, InstanceManager, Common Services, isolation and TestMode ready"
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

    -- 首次世界生成要求大厅之外保持 IMPASSABLE；重启时 Zone 场景可能已经
    -- 持久化写入合法地皮，因此只复核 Portal、大厅和保存布局兼容性。
    local void_validation_performed = self.saved_layout == nil
    if void_validation_performed then
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
        void_validation_performed
            and "WorldLayout resolved; hall and void validation passed"
            or "WorldLayout resolved; hall and saved layout validation passed"
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

function AgonRuntime:Now()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

function AgonRuntime:PrepareRecoveryPlayers()
    if self.instance_manager == nil or self.scene_service == nil
        or self.lobby_service == nil or type(AllPlayers) ~= "table" then
        return true
    end
    local terrain = self.scene_service.terrain
    if terrain == nil or type(terrain.GetTileAtWorld) ~= "function" then
        return false
    end
    local pending = self.instance_manager.pending_recovery or {}
    for _, player in ipairs(AllPlayers) do
        local position = GetPlayerPosition(player)
        if position ~= nil then
            local tile_x, tile_z = terrain:GetTileAtWorld(
                position.x,
                position.y,
                position.z
            )
            if tile_x ~= nil then
                for index = 1, #pending do
                    local saved = pending[index]
                    local zone = type(saved) == "table"
                        and self.zone_manager:Get(saved.zone_id)
                        or nil
                    if zone ~= nil and IsInsideBounds(
                        { x = tile_x, z = tile_z },
                        zone.hard_bounds
                    ) then
                        self.lobby_service:OnPlayerRemoved(player)
                        local entered, enter_code = self.lobby_service:Enter(player)
                        if entered == nil then
                            Diagnostics.Log(
                                Diagnostics.ERROR_CODES.RECOVERY_FAILED,
                                {
                                    shard_id = self.shard_id,
                                    operation = "restart_recovery_player_move",
                                    userid = player.userid,
                                    zone_id = zone.zone_id,
                                },
                                "player could not leave recovered Zone: " .. tostring(enter_code)
                            )
                        end
                        break
                    end
                end
            end
        end
    end
    return true
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
    local spectator_state = self.spectator_service ~= nil
        and self.spectator_service:GetClientState(player.userid)
        or nil
    if participant ~= nil and instance ~= nil then
        Classified.SetParticipant(classified, participant, instance)
    else
        Classified.ClearParticipant(classified)
    end

    local audience_instance_id = instance ~= nil and instance.instance_id or nil
    if spectator_state ~= nil then
        audience_instance_id = spectator_state.instance_id
    end
    local payload = self.audience_state_channel:ReadPayload(
        player.userid,
        {
            instance_id = audience_instance_id,
            spectating_instance_id = spectator_state ~= nil
                and spectator_state.instance_id
                or nil,
        }
    )
    Classified.SetAudiencePayload(classified, payload or {})
    if type(Classified.SetSpectatorState) == "function" then
        Classified.SetSpectatorState(classified, spectator_state or {})
    end
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

    local restore_entry = self.restore_queue ~= nil
        and self.restore_queue:Get(player.userid)
        or nil
    if restore_entry ~= nil
        and restore_entry.state ~= RestoreQueue.STATES.RESTORED then
        local restored, restore_code = self.restore_queue:TryRestore(player)
        Diagnostics.Log(
            restored and Diagnostics.RESULTS.RESTORE_COMPLETE or restore_code,
            {
                shard_id = self.shard_id,
                operation = "player_reconnect_restore",
                userid = player.userid,
                transaction_id = restore_entry.transaction_id,
                pending_restore_count = self.restore_queue:GetPendingCount(),
            },
            restored and "player restore completed"
                or "player restore remains guarded: " .. tostring(restore_code)
        )
    end

    local participant = self.instance_manager:GetParticipant(player.userid)
    if participant ~= nil then
        if self.lobby_service ~= nil
            and self.lobby_service:GetSession(player.userid) ~= nil then
            self.lobby_service:OnPlayerRemoved(player)
        end
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
    elseif self.lobby_service ~= nil then
        local lobby_session, lobby_code = self.lobby_service:Enter(player)
        if lobby_session == nil then
            Diagnostics.Log(
                lobby_code,
                {
                    shard_id = self.shard_id,
                    operation = "player_lobby_enter",
                    userid = player.userid,
                },
                "Lobby player entry failed"
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
    if type(player.ListenForEvent) == "function"
        and player._agon_death_policy_hooks ~= true then
        player._agon_death_policy_hooks = true
        player:ListenForEvent("death", function(_, data)
            self:OnPlayerDeath(player, data)
        end)
        player:ListenForEvent("respawnfromghost", function(_, data)
            self:OnPlayerRevived(player, data)
        end)
        player:ListenForEvent("respawnfromcorpse", function(_, data)
            self:OnPlayerRevived(player, data)
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
    if self.spectator_service ~= nil
        and type(self.spectator_service.OnPlayerRemoved) == "function" then
        self.spectator_service:OnPlayerRemoved(player)
    elseif self.lobby_service ~= nil then
        self.lobby_service:OnPlayerRemoved(player)
    end
    if self.instance_manager ~= nil then
        self.instance_manager:MarkDisconnected(player.userid, "player_removed")
    end
    if self.restore_queue ~= nil then
        self.restore_queue:MarkDisconnected(player.userid, "player_removed")
    end
    return true
end

function AgonRuntime:OnPlayerDeath(player, data)
    if player == nil or not IsNonEmptyString(player.userid)
        or self.instance_manager == nil then
        return false, Diagnostics.ERROR_CODES.INVALID_WORLD
    end
    local participant = self.instance_manager:GetParticipant(player.userid)
    if participant == nil then
        return false, "PARTICIPANT_NOT_FOUND"
    end
    local instance = self.instance_manager:Get(participant.instance_id)
    local policy = instance ~= nil and instance:GetDeathPolicy() or nil
    if policy == nil or type(policy.OnPlayerDeath) ~= "function" then
        return false, "DEATH_POLICY_UNAVAILABLE"
    end
    local record, code = policy:OnPlayerDeath(participant, player, data)
    self:RefreshPlayerClassified(player)
    if record == nil then
        return false, code
    end
    return true, code
end

function AgonRuntime:OnPlayerRevived(player, data)
    if player == nil or not IsNonEmptyString(player.userid)
        or self.instance_manager == nil then
        return false, Diagnostics.ERROR_CODES.INVALID_WORLD
    end
    local participant = self.instance_manager:GetParticipant(player.userid)
    if participant == nil then
        return false, "PARTICIPANT_NOT_FOUND"
    end
    local instance = self.instance_manager:Get(participant.instance_id)
    local policy = instance ~= nil and instance:GetDeathPolicy() or nil
    if policy == nil or type(policy.OnPlayerRevived) ~= "function" then
        return false, "DEATH_POLICY_UNAVAILABLE"
    end
    local source = type(data) == "table" and (data.user or data.source) or nil
    local revived, code = policy:OnPlayerRevived(player, source)
    self:RefreshPlayerClassified(player)
    return revived, code
end

function AgonRuntime:AddParticipant(instance_id, userid, options)
    if not self:IsReady() then
        return nil, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local restore_entry = self.restore_queue ~= nil
        and self.restore_queue:Get(userid)
        or nil
    if restore_entry ~= nil and restore_entry.state ~= RestoreQueue.STATES.RESTORED then
        return nil, Diagnostics.ERROR_CODES.RESTORE_QUEUE_PENDING
    end
    local participant, code = self.instance_manager:AddParticipant(
        instance_id,
        userid,
        options
    )
    if participant ~= nil and self.player_classified_players ~= nil then
        local player = self.player_classified_players[userid]
        if player ~= nil then
            if self.lobby_service ~= nil then
                self.lobby_service:OnPlayerRemoved(player)
            end
            self:RefreshPlayerClassified(player)
        end
    end
    return participant, code
end

function AgonRuntime:EnterLobby(player, options)
    if not self:IsReady() or self.lobby_service == nil then
        return nil, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local session, code = self.lobby_service:Enter(player, options)
    if session ~= nil and type(player) == "table" then
        self:RefreshPlayerClassified(player)
    end
    return session, code
end

function AgonRuntime:EnterSpectator(player, instance_id, options)
    if not self:IsReady() or self.spectator_service == nil then
        return nil, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local userid = type(player) == "table" and player.userid or player
    local restore_entry = self.restore_queue ~= nil
        and self.restore_queue:Get(userid)
        or nil
    if restore_entry ~= nil and restore_entry.state ~= RestoreQueue.STATES.RESTORED then
        return nil, Diagnostics.ERROR_CODES.RESTORE_QUEUE_PENDING
    end
    local session, code = self.spectator_service:Enter(player, instance_id, options)
    if session ~= nil and type(player) == "table" then
        self:RefreshPlayerClassified(player)
    end
    return session, code
end

function AgonRuntime:ExitSpectator(player_or_userid, reason, options)
    if not self:IsReady() or self.spectator_service == nil then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local exited, code = self.spectator_service:Exit(player_or_userid, reason, options)
    local player = type(player_or_userid) == "table"
        and player_or_userid
        or self.player_classified_players[player_or_userid]
    if exited and player ~= nil then
        self:RefreshPlayerClassified(player)
    end
    return exited, code
end

function AgonRuntime:CanViewSpectator(observer, target)
    if not self:IsReady() or self.spectator_service == nil then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    return self.spectator_service:CanView(observer, target)
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

function AgonRuntime:RunWP5Diagnostics()
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local passed, code = Wp5Diagnostics.Run(self)
    Diagnostics.Log(
        passed and Diagnostics.RESULTS.WP5_TEST_PASS or code,
        {
            shard_id = self.shard_id,
            operation = "wp5_diagnostics",
            core_status = self.core_status,
        },
        passed and "WP5 common services diagnostics passed" or tostring(code)
    )
    return passed, code
end

function AgonRuntime:RunWP6Diagnostics()
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local passed, code = Wp6Diagnostics.Run(self)
    Diagnostics.Log(
        passed and Diagnostics.RESULTS.WP6_TEST_PASS or code,
        {
            shard_id = self.shard_id,
            operation = "wp6_diagnostics",
            core_status = self.core_status,
        },
        passed and "WP6 entity profile diagnostics passed" or tostring(code)
    )
    return passed, code
end

function AgonRuntime:RunWP7Diagnostics()
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local passed, code = Wp7Diagnostics.Run(self)
    Diagnostics.Log(
        passed and Diagnostics.RESULTS.WP7_TEST_PASS or code,
        {
            shard_id = self.shard_id,
            operation = "wp7_diagnostics",
            core_status = self.core_status,
        },
        passed and "WP7 player sandbox diagnostics passed" or tostring(code)
    )
    return passed, code
end

function AgonRuntime:RunWP8Diagnostics()
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local passed, code = Wp8Diagnostics.Run(self)
    Diagnostics.Log(
        passed and Diagnostics.RESULTS.WP8_TEST_PASS or code,
        {
            shard_id = self.shard_id,
            operation = "wp8_diagnostics",
            core_status = self.core_status,
        },
        passed and "WP8 lobby, spectator and death policy diagnostics passed"
            or tostring(code)
    )
    return passed, code
end

function AgonRuntime:RunWP9Diagnostics()
    if not self:IsReady() then
        return false, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    local passed, code = Wp9Diagnostics.Run(self)
    Diagnostics.Log(
        passed and Diagnostics.RESULTS.WP9_TEST_PASS or code,
        {
            shard_id = self.shard_id,
            operation = "wp9_diagnostics",
            core_status = self.core_status,
            pending_restore_count = self.restore_queue ~= nil
                and self.restore_queue:GetPendingCount()
                or 0,
            backend_pending_count = self.backend_adapter ~= nil
                and self.backend_adapter:GetPendingCount()
                or 0,
        },
        passed and "WP9 persistence, recovery queue and backend diagnostics passed"
            or tostring(code)
    )
    return passed, code
end

function AgonRuntime:RetryRestore(subject, player)
    if self.restore_queue == nil then
        return false, Diagnostics.ERROR_CODES.RESTORE_QUEUE_INVALID
    end
    local restored, code = self.restore_queue:Retry(subject, player)
    if restored and type(player) == "table" then
        self:EnterLobby(player, { move = true })
        self:RefreshPlayerClassified(player)
    end
    return restored, code
end

function AgonRuntime:GetRestoreQueueSnapshot()
    return self.restore_queue ~= nil and self.restore_queue:GetSnapshot() or nil
end

function AgonRuntime:SubmitGameResult(result)
    if self.backend_adapter == nil then
        return false, Diagnostics.ERROR_CODES.BACKEND_NOT_CONFIGURED
    end
    return self.backend_adapter:SubmitGameResult(result)
end

function AgonRuntime:SubmitSettlement(settlement)
    if self.backend_adapter == nil then
        return false, Diagnostics.ERROR_CODES.BACKEND_NOT_CONFIGURED
    end
    return self.backend_adapter:SubmitSettlement(settlement)
end

function AgonRuntime:RetryBackend(identifier)
    if self.backend_adapter == nil then
        return false, Diagnostics.ERROR_CODES.BACKEND_NOT_CONFIGURED
    end
    return self.backend_adapter:RetryPending(identifier)
end

function AgonRuntime:DispatchRpc(context, request)
    local restore_entry = context ~= nil and self.restore_queue ~= nil
        and self.restore_queue:Get(context.userid)
        or nil
    if restore_entry ~= nil and restore_entry.state ~= RestoreQueue.STATES.RESTORED then
        return false, Diagnostics.ERROR_CODES.RESTORE_QUEUE_PENDING
    end
    if type(request) == "table" and Rpc.SPECTATOR_ACTIONS[request.action] then
        if self.spectator_service == nil then
            return false, SpectatorService.ERROR_CODES.INVALID_SERVICE
        end
        local result, code = self.spectator_service:HandleRpc(context, request)
        -- Enter 返回 session table，Exit/Target 返回 true；统一成 RPC 所需的布尔结果。
        return result ~= nil and result ~= false, code
    end
    -- 其他玩法动作仍由后续 Mode/Action router 处理；WP4 只负责通用校验。
    return true
end

function AgonRuntime:CreateInstance(mode_id, userids, options)
    if not self:IsReady() then
        return nil, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    return self.instance_manager:Create(mode_id, userids, options)
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
    if self.entity_profile_registry == nil
        or type(self.entity_profile_registry.Validate) ~= "function" then
        return false, Diagnostics.ERROR_CODES.CORE_INIT_FAILED
    end
    local profiles_valid, profiles_code = self.entity_profile_registry:Validate()
    if not profiles_valid then
        return false, profiles_code
    end
    if self.lobby_service == nil
        or type(self.lobby_service.Validate) ~= "function" then
        return false, Diagnostics.ERROR_CODES.CORE_INIT_FAILED
    end
    local lobby_valid, lobby_code = self.lobby_service:Validate()
    if not lobby_valid then
        return false, lobby_code
    end
    if self.spectator_service == nil
        or type(self.spectator_service.Validate) ~= "function" then
        return false, Diagnostics.ERROR_CODES.CORE_INIT_FAILED
    end
    local spectator_valid, spectator_code = self.spectator_service:Validate()
    if not spectator_valid then
        return false, spectator_code
    end
    if self.restore_queue == nil
        or type(self.restore_queue.Validate) ~= "function" then
        return false, Diagnostics.ERROR_CODES.RESTORE_QUEUE_INVALID
    end
    local queue_valid, queue_code = self.restore_queue:Validate()
    if not queue_valid then
        return false, queue_code or Diagnostics.ERROR_CODES.RESTORE_QUEUE_INVALID
    end
    if self.backend_adapter == nil
        or type(self.backend_adapter.Validate) ~= "function" then
        return false, Diagnostics.ERROR_CODES.PERSISTENCE_INVALID_SNAPSHOT
    end
    local backend_valid, backend_code = self.backend_adapter:Validate()
    if not backend_valid then
        return false, backend_code or Diagnostics.ERROR_CODES.PERSISTENCE_INVALID_SNAPSHOT
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

function AgonRuntime:DebugRecovery()
    if not self:IsReady() then
        return false
    end
    if self.restore_queue ~= nil then
        Diagnostics.Log(
            Diagnostics.RESULTS.RESTORE_COMPLETE,
            {
                shard_id = self.shard_id,
                operation = "debug_recovery",
                pending_restore_count = self.restore_queue:GetPendingCount(),
            },
            self.restore_queue:GetDebugString()
        )
    end
    if self.backend_adapter ~= nil then
        Diagnostics.Log(
            Diagnostics.RESULTS.BACKEND_PENDING,
            {
                shard_id = self.shard_id,
                operation = "debug_recovery",
                backend_pending_count = self.backend_adapter:GetPendingCount(),
            },
            self.backend_adapter:GetDebugString()
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
    local pending_restore_count = self.restore_queue ~= nil
        and self.restore_queue:GetPendingCount()
        or 0
    local backend_pending_count = self.backend_adapter ~= nil
        and self.backend_adapter:GetPendingCount()
        or 0
    return string.format(
        "schema=%d shard=%s boot=%d layout=%s v=%d core=%s offset=%s,%s resolved=%s,%s world=%s,%s instances=%d zones=%d restores=%d backend_pending=%d errors=%d",
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
        pending_restore_count,
        backend_pending_count,
        error_count
    )
end

return AgonRuntime
