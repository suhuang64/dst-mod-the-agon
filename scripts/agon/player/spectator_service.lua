-- WP8：Instance-aware 只读观战关系、玩家可逆保护和观战残影。

local LayoutService = require("agon/world/layout_service")

local SpectatorService = {}
SpectatorService.SCHEMA_VERSION = 1
SpectatorService.SERVICE_ID = "spectator"
SpectatorService.SERVICE_VERSION = 1

SpectatorService.STATES =
{
    SPECTATING = "SPECTATING",
}

SpectatorService.ACTIONS =
{
    ENTER = "SPECTATOR_ENTER",
    EXIT = "SPECTATOR_EXIT",
    TARGET = "SPECTATOR_TARGET",
}

SpectatorService.ALLOWED_ACTIONS =
{
    SPECTATOR_ENTER = true,
    SPECTATOR_EXIT = true,
    SPECTATOR_TARGET = true,
}

SpectatorService.ERROR_CODES =
{
    INVALID_SERVICE = "SPECTATOR_SERVICE_INVALID",
    INVALID_PLAYER = "SPECTATOR_PLAYER_INVALID",
    INVALID_INSTANCE = "SPECTATOR_INSTANCE_INVALID",
    INSTANCE_NOT_RUNNING = "SPECTATOR_INSTANCE_NOT_RUNNING",
    PARTICIPANT_FORBIDDEN = "SPECTATOR_PARTICIPANT_FORBIDDEN",
    SESSION_NOT_FOUND = "SPECTATOR_SESSION_NOT_FOUND",
    ALREADY_SPECTATING = "SPECTATOR_ALREADY_SPECTATING",
    NO_ANCHOR = "SPECTATOR_ANCHOR_UNAVAILABLE",
    INVALID_ANCHOR = "SPECTATOR_ANCHOR_INVALID",
    ECHO_CREATE_FAILED = "SPECTATOR_ECHO_CREATE_FAILED",
    ECHO_REMOVE_FAILED = "SPECTATOR_ECHO_REMOVE_FAILED",
    PLAYER_GUARD_FAILED = "SPECTATOR_PLAYER_GUARD_FAILED",
    CROSS_INSTANCE = "SPECTATOR_CROSS_INSTANCE_FORBIDDEN",
    ACTION_FORBIDDEN = "SPECTATOR_ACTION_FORBIDDEN",
    TARGET_NOT_FOUND = "SPECTATOR_TARGET_NOT_FOUND",
}

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
    return type(value) == "table"
        and IsInteger(value.x)
        and IsInteger(value.z)
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

local function GetNow(self)
    if type(self.now_fn) == "function" then
        return self.now_fn()
    end
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

local function GetUserid(value)
    if type(value) == "table" and IsNonEmptyString(value.userid) then
        return value.userid
    end
    if IsNonEmptyString(value) then
        return value
    end
    return nil
end

local function IsValidPlayer(player)
    if type(player) ~= "table" or not IsNonEmptyString(player.userid) then
        return false
    end
    if type(player.IsValid) == "function" then
        local ok, valid = ProtectedCall(player.IsValid, player)
        return ok and valid == true
    end
    return true
end

local function GetPlayerPosition(player)
    if type(player) ~= "table" then
        return nil
    end
    if type(player.agon_spectator_position) == "table"
        and IsFiniteNumber(player.agon_spectator_position.x)
        and IsFiniteNumber(player.agon_spectator_position.z) then
        return CopyValue(player.agon_spectator_position)
    end
    if player.Transform ~= nil
        and type(player.Transform.GetWorldPosition) == "function" then
        local ok, x, y, z = ProtectedCall(
            player.Transform.GetWorldPosition,
            player.Transform
        )
        if ok and IsFiniteNumber(x) and IsFiniteNumber(z) then
            return { x = x, y = y or 0, z = z }
        end
    end
    return nil
end

local function SetPlayerPosition(player, position)
    if not IsValidPlayer(player) or type(position) ~= "table"
        or not IsFiniteNumber(position.x) or not IsFiniteNumber(position.z) then
        return false
    end
    if player.Transform ~= nil
        and type(player.Transform.SetPosition) == "function" then
        local ok = ProtectedCall(
            player.Transform.SetPosition,
            player.Transform,
            position.x,
            position.y or 0,
            position.z
        )
        if not ok then
            return false
        end
    end
    player.agon_spectator_position = CopyValue(position)
    return true
end

local function HasTag(player, tag)
    if type(player) ~= "table" or type(player.HasTag) ~= "function" then
        return false
    end
    local ok, result = ProtectedCall(player.HasTag, player, tag)
    return ok and result == true
end

local function AddTag(player, tag)
    if type(player) == "table" and type(player.AddTag) == "function" then
        return ProtectedCall(player.AddTag, player, tag)
    end
    return true
end

local function RemoveTag(player, tag)
    if type(player) == "table" and type(player.RemoveTag) == "function" then
        return ProtectedCall(player.RemoveTag, player, tag)
    end
    return true
end

local function GetNetBoolean(value, default)
    if value ~= nil and type(value.value) == "function" then
        local ok, result = ProtectedCall(value.value, value)
        if ok and type(result) == "boolean" then
            return result
        end
    end
    return default
end

local function CapturePlayerGuard(player)
    local guard =
    {
        visible = true,
        shadow_enabled = true,
        minimap_enabled = true,
        physics_active = true,
        controller_enabled = true,
        health_invincible = false,
        had_notarget = HasTag(player, "notarget"),
    }
    if player.entity ~= nil and type(player.entity.IsVisible) == "function" then
        local ok, visible = ProtectedCall(player.entity.IsVisible, player.entity)
        if ok and type(visible) == "boolean" then
            guard.visible = visible
        end
    end
    if player.Physics ~= nil and type(player.Physics.IsActive) == "function" then
        local ok, active = ProtectedCall(player.Physics.IsActive, player.Physics)
        if ok and type(active) == "boolean" then
            guard.physics_active = active
        end
    end
    local controller = type(player.components) == "table"
        and player.components.playercontroller
        or nil
    if controller ~= nil and controller.classified ~= nil then
        guard.controller_enabled = GetNetBoolean(
            controller.classified.iscontrollerenabled,
            true
        )
    elseif controller ~= nil and type(controller.IsEnabled) == "function" then
        local ok, enabled = ProtectedCall(controller.IsEnabled, controller)
        if ok and type(enabled) == "boolean" then
            guard.controller_enabled = enabled
        end
    end
    local health = type(player.components) == "table"
        and player.components.health
        or nil
    if health ~= nil and type(health.invincible) == "boolean" then
        guard.health_invincible = health.invincible
    end
    return guard
end

local function HidePlayer(player)
    if player.entity ~= nil and type(player.entity.Hide) == "function" then
        local ok = ProtectedCall(player.entity.Hide, player.entity)
        if not ok then
            return false
        end
    end
    return true
end

local function ShowPlayer(player, visible)
    if player.entity == nil then
        return true
    end
    local method = visible and player.entity.Show or player.entity.Hide
    if type(method) ~= "function" then
        return true
    end
    local ok = ProtectedCall(method, player.entity)
    return ok
end

local function CreateSyntheticEcho(echo_id)
    local echo =
    {
        echo_id = echo_id,
        display_name = "",
        appearance = {},
        persists = false,
        gameplay = false,
        ai = false,
        collision = false,
        removed = false,
    }
    function echo:SetDisplayName(display_name)
        self.display_name = type(display_name) == "string" and display_name or ""
        return true
    end
    function echo:SetAppearance(appearance)
        self.appearance = CopyValue(appearance)
        return true
    end
    function echo:GetSnapshot()
        return
        {
            echo_id = self.echo_id,
            display_name = self.display_name,
            appearance = CopyValue(self.appearance),
            persists = false,
            gameplay = false,
            ai = false,
            collision = false,
        }
    end
    function echo:Remove()
        self.removed = true
        return true
    end
    function echo:IsValid()
        return not self.removed
    end
    return echo
end

local function GetDisplayName(player)
    if type(player.GetDisplayName) == "function" then
        local ok, value = ProtectedCall(player.GetDisplayName, player)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return type(player.name) == "string" and player.name
        or tostring(player.userid)
end

local function GetAppearance(player)
    local appearance =
    {
        prefab = type(player.prefab) == "string" and player.prefab or nil,
    }
    if player.AnimState ~= nil
        and type(player.AnimState.GetBankHash) == "function" then
        local ok, bank = ProtectedCall(player.AnimState.GetBankHash, player.AnimState)
        if ok then
            appearance.bank = bank
        end
    end
    if type(player.agon_sandbox_state) == "table"
        and type(player.agon_sandbox_state.character) == "table"
        and type(player.agon_sandbox_state.character.appearance) == "table" then
        local saved_appearance = player.agon_sandbox_state.character.appearance
        appearance.build = saved_appearance.build
        appearance.skin = saved_appearance.skin
    elseif type(player.prefab) == "string" then
        appearance.build = player.prefab
    end
    return appearance
end

local function AttachMethods(service)
    service.GetSession = SpectatorService.GetSession
    service.GetClientState = SpectatorService.GetClientState
    service.GetSnapshot = SpectatorService.GetSnapshot
    service.GetDebugString = SpectatorService.GetDebugString
    service.Enter = SpectatorService.Enter
    service.Exit = SpectatorService.Exit
    service.SetTarget = SpectatorService.SetTarget
    service.CanView = SpectatorService.CanView
    service.HandleRpc = SpectatorService.HandleRpc
    service.OnInstanceDestroy = SpectatorService.OnInstanceDestroy
    service.OnPlayerRemoved = SpectatorService.OnPlayerRemoved
    service.Validate = SpectatorService.Validate
    service.Close = SpectatorService.Close
    return service
end

function SpectatorService.New(options)
    options = type(options) == "table" and options or {}
    if type(options.layout) ~= "table"
        or type(options.instance_manager) ~= "table"
        or type(options.lobby_service) ~= "table" then
        return nil, SpectatorService.ERROR_CODES.INVALID_SERVICE
    end
    local service =
    {
        schema_version = SpectatorService.SCHEMA_VERSION,
        service_id = SpectatorService.SERVICE_ID,
        service_version = SpectatorService.SERVICE_VERSION,
        runtime = options.runtime,
        world = options.world,
        layout = options.layout,
        instance_manager = options.instance_manager,
        scene_service = options.scene_service,
        lobby_service = options.lobby_service,
        now_fn = options.now_fn,
        synthetic = options.synthetic == true,
        spawn_echo_fn = options.spawn_echo_fn,
        sessions_by_userid = {},
        sessions_by_instance = {},
        players_by_userid = {},
        next_echo_sequence = 0,
        next_anchor_by_instance = {},
        closed = false,
    }
    return AttachMethods(service)
end

function SpectatorService.GetSession(self, player_or_userid)
    local userid = GetUserid(player_or_userid)
    return userid ~= nil and self.sessions_by_userid[userid] or nil
end

local function GetInstance(self, instance_id)
    if not IsNonEmptyString(instance_id)
        or type(self.instance_manager.Get) ~= "function" then
        return nil
    end
    return self.instance_manager:Get(instance_id)
end

local function IsRunning(instance)
    return instance ~= nil and instance.lifecycle_state == "RUNNING"
end

local function ResolveAnchor(self, instance, preferred_index)
    local plan = instance ~= nil and instance.scene_plan or nil
    local anchors = plan ~= nil and plan.spectator_anchors or nil
    if type(anchors) ~= "table" or #anchors == 0 then
        return nil, SpectatorService.ERROR_CODES.NO_ANCHOR
    end
    local start = IsInteger(preferred_index)
        and preferred_index
        or (self.next_anchor_by_instance[instance.instance_id] or 1)
    if start < 1 or start > #anchors then
        start = 1
    end
    local anchor = nil
    local anchor_index = nil
    for offset = 0, #anchors - 1 do
        local index = ((start + offset - 1) % #anchors) + 1
        if IsPoint(anchors[index]) then
            anchor = anchors[index]
            anchor_index = index
            break
        end
    end
    if anchor == nil then
        return nil, SpectatorService.ERROR_CODES.INVALID_ANCHOR
    end
    local map_size = self.layout.map_size
    local world_x, world_z = LayoutService.TileToWorld(
        anchor.x,
        anchor.z,
        map_size.width,
        map_size.height
    )
    if world_x == nil then
        return nil, SpectatorService.ERROR_CODES.INVALID_ANCHOR
    end
    self.next_anchor_by_instance[instance.instance_id] = (anchor_index % #anchors) + 1
    return
    {
        index = anchor_index,
        tile = { x = anchor.x, z = anchor.z },
        world = { x = world_x, y = 0, z = world_z },
    }
end

local function CreateEcho(self, echo_id, player, session)
    local echo = nil
    if type(self.spawn_echo_fn) == "function" then
        local ok, result = ProtectedCall(
            self.spawn_echo_fn,
            echo_id,
            player,
            session
        )
        if ok then
            echo = result
        end
    elseif self.synthetic or player.entity == nil or type(SpawnPrefab) ~= "function" then
        echo = CreateSyntheticEcho(echo_id)
    else
        local ok, result = ProtectedCall(SpawnPrefab, "agon_spectator_echo")
        if ok then
            echo = result
        end
    end
    if echo == nil then
        return nil, SpectatorService.ERROR_CODES.ECHO_CREATE_FAILED
    end

    echo.echo_id = echo_id
    echo._agon_spectator_target_instance_id = session.instance_id
    if type(echo.SetDisplayName) == "function" then
        local ok = ProtectedCall(echo.SetDisplayName, echo, GetDisplayName(player))
        if not ok then
            return nil, SpectatorService.ERROR_CODES.ECHO_CREATE_FAILED
        end
    end
    if type(echo.SetAppearance) == "function" then
        local ok = ProtectedCall(echo.SetAppearance, echo, GetAppearance(player))
        if not ok then
            return nil, SpectatorService.ERROR_CODES.ECHO_CREATE_FAILED
        end
    end
    if echo.Transform ~= nil and type(echo.Transform.SetPosition) == "function" then
        local ok = ProtectedCall(
            echo.Transform.SetPosition,
            echo.Transform,
            session.anchor.world.x,
            session.anchor.world.y or 0,
            session.anchor.world.z
        )
        if not ok then
            return nil, SpectatorService.ERROR_CODES.ECHO_CREATE_FAILED
        end
    end
    return echo
end

local function RemoveEcho(echo)
    if echo == nil then
        return true
    end
    if type(echo.IsValid) == "function" then
        local ok, valid = ProtectedCall(echo.IsValid, echo)
        if ok and not valid then
            return true
        end
    end
    if type(echo.Remove) ~= "function" then
        return false
    end
    local ok = ProtectedCall(echo.Remove, echo)
    return ok
end

local function ApplyPlayerGuard(player, guard)
    player.is_spectator = true
    player.spectating_instance_id = guard.instance_id
    player.agon_spectator_guard = guard
    player.agon_spectator_input_layer =
    {
        rotation = true,
        zoom = true,
        target_switch = true,
        free_camera = false,
    }
    local notarget_added = AddTag(player, "notarget")
    if not notarget_added then
        return false
    end
    if type(player.ClearBufferedAction) == "function" then
        local ok = ProtectedCall(player.ClearBufferedAction, player)
        if not ok then
            return false
        end
    end
    if not HidePlayer(player) then
        return false
    end
    if player.DynamicShadow ~= nil
        and type(player.DynamicShadow.Enable) == "function" then
        local ok = ProtectedCall(player.DynamicShadow.Enable, player.DynamicShadow, false)
        if not ok then
            return false
        end
    end
    if player.MiniMapEntity ~= nil
        and type(player.MiniMapEntity.SetEnabled) == "function" then
        local ok = ProtectedCall(player.MiniMapEntity.SetEnabled, player.MiniMapEntity, false)
        if not ok then
            return false
        end
    end
    if player.Physics ~= nil
        and type(player.Physics.SetActive) == "function" then
        local ok = ProtectedCall(player.Physics.SetActive, player.Physics, false)
        if not ok then
            return false
        end
    end
    local controller = type(player.components) == "table"
        and player.components.playercontroller
        or nil
    if controller ~= nil and type(controller.Enable) == "function" then
        local ok = ProtectedCall(controller.Enable, controller, false)
        if not ok then
            return false
        end
    end
    local health = type(player.components) == "table"
        and player.components.health
        or nil
    if health ~= nil and type(health.SetInvincible) == "function" then
        local ok = ProtectedCall(health.SetInvincible, health, true)
        if not ok then
            return false
        end
    end
    player.agon_spectator_guard_applied = true
    return true
end

local function RestorePlayerGuard(player)
    if type(player) ~= "table" then
        return true
    end
    local guard = player.agon_spectator_guard
    if type(guard) ~= "table" then
        player.is_spectator = nil
        player.spectating_instance_id = nil
        player.agon_spectator_input_layer = nil
        return true
    end
    local restored = true
    restored = ShowPlayer(player, guard.visible) and restored
    if player.DynamicShadow ~= nil
        and type(player.DynamicShadow.Enable) == "function" then
        restored = ProtectedCall(
            player.DynamicShadow.Enable,
            player.DynamicShadow,
            guard.shadow_enabled ~= false
        ) and restored
    end
    if player.MiniMapEntity ~= nil
        and type(player.MiniMapEntity.SetEnabled) == "function" then
        restored = ProtectedCall(
            player.MiniMapEntity.SetEnabled,
            player.MiniMapEntity,
            guard.minimap_enabled ~= false
        ) and restored
    end
    if player.Physics ~= nil and type(player.Physics.SetActive) == "function" then
        restored = ProtectedCall(
            player.Physics.SetActive,
            player.Physics,
            guard.physics_active ~= false
        ) and restored
    end
    local controller = type(player.components) == "table"
        and player.components.playercontroller
        or nil
    if controller ~= nil and type(controller.Enable) == "function" then
        restored = ProtectedCall(
            controller.Enable,
            controller,
            guard.controller_enabled ~= false
        ) and restored
    end
    local health = type(player.components) == "table"
        and player.components.health
        or nil
    if health ~= nil and type(health.SetInvincible) == "function" then
        restored = ProtectedCall(
            health.SetInvincible,
            health,
            guard.health_invincible == true
        ) and restored
    end
    if not guard.had_notarget then
        restored = RemoveTag(player, "notarget") and restored
    end
    player.is_spectator = nil
    player.spectating_instance_id = nil
    player.agon_spectator_guard = nil
    player.agon_spectator_guard_applied = nil
    player.agon_spectator_input_layer = nil
    return restored
end

function SpectatorService.Enter(self, player, instance_id, options)
    options = type(options) == "table" and options or {}
    if self.closed then
        return nil, SpectatorService.ERROR_CODES.INVALID_SERVICE
    end
    if not IsValidPlayer(player) or not IsNonEmptyString(instance_id) then
        return nil, SpectatorService.ERROR_CODES.INVALID_PLAYER
    end
    local instance = GetInstance(self, instance_id)
    if instance == nil then
        return nil, SpectatorService.ERROR_CODES.INVALID_INSTANCE
    end
    if not IsRunning(instance) then
        return nil, SpectatorService.ERROR_CODES.INSTANCE_NOT_RUNNING
    end
    local userid = player.userid
    local current = self:GetSession(userid)
    if current ~= nil then
        if current.instance_id == instance_id then
            return current, SpectatorService.ERROR_CODES.ALREADY_SPECTATING
        end
        -- 观战关系一旦建立，目标 Instance 只能由显式退出后重新进入来改变；
        -- 不能通过一次 Enter 请求把只读关系直接切到另一个 Instance。
        return nil, SpectatorService.ERROR_CODES.CROSS_INSTANCE
    end
    if self.instance_manager:GetParticipant(userid) ~= nil then
        return nil, SpectatorService.ERROR_CODES.PARTICIPANT_FORBIDDEN
    end

    local lobby_session = self.lobby_service:GetSession(userid)
    if lobby_session == nil then
        local entered, lobby_code = self.lobby_service:Enter(player)
        if entered == nil then
            return nil, lobby_code
        end
        lobby_session = entered
    end
    local anchor, anchor_code = ResolveAnchor(self, instance, options.anchor_index)
    if anchor == nil then
        return nil, anchor_code
    end

    self.next_echo_sequence = self.next_echo_sequence + 1
    local echo_id = "agon:echo:" .. tostring(self.next_echo_sequence)
    local session =
    {
        schema_version = SpectatorService.SCHEMA_VERSION,
        state = SpectatorService.STATES.SPECTATING,
        userid = userid,
        instance_id = instance_id,
        generation = instance.generation,
        scene_revision = instance.scene_revision,
        anchor_id = tostring(anchor.index),
        anchor = anchor,
        camera_mode = options.camera_mode or "FOLLOW",
        camera_bounds = CopyValue(instance.scene_plan.spectator_camera_bounds),
        lobby_return_position = CopyValue(lobby_session.return_position),
        echo_id = echo_id,
        entered_at = GetNow(self),
        target_userid = options.target_userid,
        player = player,
    }
    local echo, echo_code = CreateEcho(self, echo_id, player, session)
    if echo == nil then
        return nil, echo_code
    end
    session.echo = echo

    if not SetPlayerPosition(player, anchor.world) then
        RemoveEcho(echo)
        return nil, SpectatorService.ERROR_CODES.PLAYER_GUARD_FAILED
    end
    local guard = CapturePlayerGuard(player)
    guard.instance_id = instance_id
    if not ApplyPlayerGuard(player, guard) then
        RestorePlayerGuard(player)
        RemoveEcho(echo)
        self.lobby_service:Return(player, session.lobby_return_position, "spectator_enter_failed")
        return nil, SpectatorService.ERROR_CODES.PLAYER_GUARD_FAILED
    end

    self.sessions_by_userid[userid] = session
    self.players_by_userid[userid] = player
    if self.sessions_by_instance[instance_id] == nil then
        self.sessions_by_instance[instance_id] = {}
    end
    self.sessions_by_instance[instance_id][userid] = session
    self.lobby_service:MarkSpectatorReturn(player)
    player.agon_spectator_session_id = echo_id
    player.agon_spectator_target_instance_id = instance_id
    if self.runtime ~= nil and type(self.runtime.RefreshPlayerClassified) == "function" then
        self.runtime:RefreshPlayerClassified(player)
    end
    return session
end

function SpectatorService.Exit(self, player_or_userid, reason, options)
    options = type(options) == "table" and options or {}
    local userid = GetUserid(player_or_userid)
    local session = userid ~= nil and self.sessions_by_userid[userid] or nil
    if session == nil then
        return false, SpectatorService.ERROR_CODES.SESSION_NOT_FOUND
    end
    local player = type(player_or_userid) == "table"
        and player_or_userid
        or self.players_by_userid[userid]
        or session.player
    self.sessions_by_userid[userid] = nil
    self.players_by_userid[userid] = nil
    if self.sessions_by_instance[session.instance_id] ~= nil then
        self.sessions_by_instance[session.instance_id][userid] = nil
        if next(self.sessions_by_instance[session.instance_id]) == nil then
            self.sessions_by_instance[session.instance_id] = nil
        end
    end

    local echo_removed = RemoveEcho(session.echo)
    local guard_restored = RestorePlayerGuard(player)
    local returned = true
    if not options.skip_return and self.lobby_service:GetSession(userid) ~= nil then
        returned = self.lobby_service:Return(
            player or userid,
            session.lobby_return_position,
            reason or "spectator_exit"
        )
    end
    if player ~= nil then
        player.agon_spectator_session_id = nil
        player.agon_spectator_target_instance_id = nil
        player.agon_spectator_position = nil
    end
    session.player = nil
    session.echo = nil
    session.exited_at = GetNow(self)
    session.exit_reason = reason ~= nil and tostring(reason) or nil
    if self.runtime ~= nil and player ~= nil
        and type(self.runtime.RefreshPlayerClassified) == "function" then
        self.runtime:RefreshPlayerClassified(player)
    end
    if not echo_removed then
        return false, SpectatorService.ERROR_CODES.ECHO_REMOVE_FAILED
    end
    if not guard_restored or returned == false then
        return false, SpectatorService.ERROR_CODES.PLAYER_GUARD_FAILED
    end
    return true
end

function SpectatorService.SetTarget(self, player_or_userid, target)
    local session = self:GetSession(player_or_userid)
    if session == nil then
        return false, SpectatorService.ERROR_CODES.SESSION_NOT_FOUND
    end
    if target == nil then
        session.target_userid = nil
        return true
    end
    local target_userid = GetUserid(target)
    local target_instance_id = nil
    if type(target) == "table" then
        target_instance_id = self.instance_manager:ResolveInstance(target)
    elseif target_userid ~= nil then
        target_instance_id = self.instance_manager:GetParticipantInstanceId(target_userid)
    end
    if target_userid == nil or target_instance_id ~= session.instance_id then
        return false, SpectatorService.CROSS_INSTANCE
    end
    local target_participant = self.instance_manager:GetParticipant(target_userid)
    local target_player = type(target) == "table"
        and target
        or (target_participant ~= nil
            and type(target_participant.GetPlayer) == "function"
            and target_participant:GetPlayer())
        or self.players_by_userid[target_userid]
    if target_player ~= nil and target_player.is_spectator == true then
        return false, SpectatorService.TARGET_NOT_FOUND
    end
    session.target_userid = target_userid
    return true
end

function SpectatorService.CanView(self, observer, target)
    local session = self:GetSession(observer)
    if session == nil then
        return false, SpectatorService.SESSION_NOT_FOUND
    end
    local target_instance_id = nil
    if IsNonEmptyString(target) then
        target_instance_id = target
    elseif type(target) == "table" then
        target_instance_id = self.instance_manager:ResolveInstance(target)
    end
    if target_instance_id ~= session.instance_id then
        return false, SpectatorService.CROSS_INSTANCE
    end
    return true
end

function SpectatorService.GetClientState(self, player_or_userid)
    local session = self:GetSession(player_or_userid)
    if session == nil then
        return nil
    end
    return
    {
        schema_version = SpectatorService.SCHEMA_VERSION,
        state = session.state,
        instance_id = session.instance_id,
        generation = session.generation,
        scene_revision = session.scene_revision,
        anchor_id = session.anchor_id,
        camera_mode = session.camera_mode,
        camera_bounds = CopyValue(session.camera_bounds),
        echo_id = session.echo_id,
        target_userid = session.target_userid,
        allowed_actions =
        {
            rotation = true,
            zoom = true,
            target_switch = true,
        },
    }
end

function SpectatorService.HandleRpc(self, context, request)
    if type(request) ~= "table"
        or not SpectatorService.ALLOWED_ACTIONS[request.action] then
        return false, SpectatorService.ERROR_CODES.ACTION_FORBIDDEN
    end
    local sender = context ~= nil and context.sender or nil
    if request.action == SpectatorService.ACTIONS.ENTER then
        return self:Enter(sender, request.target_instance_id or request.instance_id)
    elseif request.action == SpectatorService.ACTIONS.EXIT then
        return self:Exit(sender, "rpc_exit")
    elseif request.action == SpectatorService.ACTIONS.TARGET then
        return self:SetTarget(sender, context ~= nil and context.target or nil)
    end
    return false, SpectatorService.ERROR_CODES.ACTION_FORBIDDEN
end

function SpectatorService.OnInstanceDestroy(self, instance_id, reason)
    local sessions = self.sessions_by_instance[instance_id]
    if sessions == nil then
        return true
    end
    local userids = {}
    for userid in pairs(sessions) do
        table.insert(userids, userid)
    end
    local all_clean = true
    for index = 1, #userids do
        local exited = self:Exit(
            userids[index],
            reason or "instance_destroy",
            { skip_return = false }
        )
        if not exited then
            all_clean = false
        end
    end
    return all_clean
end

function SpectatorService.OnPlayerRemoved(self, player_or_userid)
    local userid = GetUserid(player_or_userid)
    if userid == nil then
        return false
    end
    local exited = true
    if self.sessions_by_userid[userid] ~= nil then
        exited = self:Exit(userid, "player_removed", { skip_return = true })
    end
    self.lobby_service:OnPlayerRemoved(player_or_userid)
    return exited ~= false
end

function SpectatorService.GetSnapshot(self)
    local sessions = {}
    for userid, session in pairs(self.sessions_by_userid) do
        sessions[userid] =
        {
            schema_version = session.schema_version,
            state = session.state,
            userid = session.userid,
            instance_id = session.instance_id,
            generation = session.generation,
            scene_revision = session.scene_revision,
            anchor_id = session.anchor_id,
            anchor = CopyValue(session.anchor),
            camera_mode = session.camera_mode,
            camera_bounds = CopyValue(session.camera_bounds),
            lobby_return_position = CopyValue(session.lobby_return_position),
            echo_id = session.echo_id,
            entered_at = session.entered_at,
            target_userid = session.target_userid,
        }
    end
    return
    {
        schema_version = self.schema_version,
        service_id = self.service_id,
        service_version = self.service_version,
        closed = self.closed,
        sessions = sessions,
    }
end

function SpectatorService.Validate(self)
    if type(self.sessions_by_userid) ~= "table"
        or type(self.sessions_by_instance) ~= "table" then
        return false, SpectatorService.ERROR_CODES.INVALID_SERVICE
    end
    local seen_echoes = {}
    for userid, session in pairs(self.sessions_by_userid) do
        local instance = GetInstance(self, session.instance_id)
        if not IsNonEmptyString(userid)
            or type(session) ~= "table"
            or session.userid ~= userid
            or session.state ~= SpectatorService.STATES.SPECTATING
            or not IsRunning(instance)
            or not IsNonEmptyString(session.echo_id)
            or seen_echoes[session.echo_id] then
            return false, SpectatorService.ERROR_CODES.INVALID_SERVICE
        end
        seen_echoes[session.echo_id] = true
        if self.sessions_by_instance[session.instance_id] == nil
            or self.sessions_by_instance[session.instance_id][userid] ~= session then
            return false, SpectatorService.ERROR_CODES.INVALID_SERVICE
        end
    end
    return true
end

function SpectatorService.Close(self, reason)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    local userids = {}
    for userid in pairs(self.sessions_by_userid) do
        table.insert(userids, userid)
    end
    local all_clean = true
    for index = 1, #userids do
        local exited = self:Exit(userids[index], reason or "server_shutdown")
        if not exited then
            all_clean = false
        end
    end
    self.closed = true
    if all_clean then
        return true
    end
    return false, SpectatorService.ERROR_CODES.PLAYER_GUARD_FAILED
end

function SpectatorService.GetDebugString(self)
    local count = 0
    for _ in pairs(self.sessions_by_userid) do
        count = count + 1
    end
    return string.format(
        "spectator service=%s version=%d sessions=%d echoes=%d closed=%s",
        self.service_id,
        self.service_version,
        count,
        self.next_echo_sequence,
        tostring(self.closed)
    )
end

return SpectatorService
