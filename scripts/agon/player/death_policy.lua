-- WP8：Instance-aware 玩家死亡策略。死亡 Participant 不会自动转成 Spectator。

local Participant = require("agon/core/participant")

local DeathPolicy = {}
DeathPolicy.SCHEMA_VERSION = 1
DeathPolicy.SERVICE_ID = "death_policy"
DeathPolicy.SERVICE_VERSION = 1

DeathPolicy.MODES =
{
    GHOST = "GHOST",
    REVIVABLE_CORPSE = "REVIVABLE_CORPSE",
}

DeathPolicy.ERROR_CODES =
{
    INVALID_POLICY = "DEATH_POLICY_INVALID",
    INVALID_MODE = "DEATH_POLICY_MODE_INVALID",
    INVALID_PARTICIPANT = "DEATH_POLICY_PARTICIPANT_INVALID",
    PARTICIPANT_NOT_FOUND = "DEATH_POLICY_PARTICIPANT_NOT_FOUND",
    PARTICIPANT_NOT_ACTIVE = "DEATH_POLICY_PARTICIPANT_NOT_ACTIVE",
    ALREADY_DEAD = "DEATH_POLICY_ALREADY_DEAD",
    NOT_GHOST = "DEATH_POLICY_NOT_GHOST",
    GHOST_MOVE_FORBIDDEN = "DEATH_POLICY_GHOST_MOVE_FORBIDDEN",
    NOT_CORPSE = "DEATH_POLICY_NOT_CORPSE",
    REVIVE_FORBIDDEN = "DEATH_POLICY_REVIVE_FORBIDDEN",
    REVIVE_IN_PROGRESS = "DEATH_POLICY_REVIVE_IN_PROGRESS",
    REVIVE_NOT_FOUND = "DEATH_POLICY_REVIVE_NOT_FOUND",
    REVIVE_FAILED = "DEATH_POLICY_REVIVE_FAILED",
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

local function GetPlayerGuard(player)
    if type(player) ~= "table" then
        return nil
    end
    local guard =
    {
        physics_active = true,
        controller_enabled = true,
        health_invincible = false,
        health_canheal = nil,
        had_notarget = HasTag(player, "notarget"),
    }
    if player.Physics ~= nil and type(player.Physics.IsActive) == "function" then
        local ok, active = ProtectedCall(player.Physics.IsActive, player.Physics)
        if ok and type(active) == "boolean" then
            guard.physics_active = active
        end
    end
    local controller = type(player.components) == "table"
        and player.components.playercontroller
        or nil
    if controller ~= nil and controller.classified ~= nil
        and controller.classified.iscontrollerenabled ~= nil
        and type(controller.classified.iscontrollerenabled.value) == "function" then
        local ok, enabled = ProtectedCall(
            controller.classified.iscontrollerenabled.value,
            controller.classified.iscontrollerenabled
        )
        if ok and type(enabled) == "boolean" then
            guard.controller_enabled = enabled
        end
    end
    local health = type(player.components) == "table"
        and player.components.health
        or nil
    if health ~= nil then
        if type(health.invincible) == "boolean" then
            guard.health_invincible = health.invincible
        end
        if type(health.canheal) == "boolean" then
            guard.health_canheal = health.canheal
        end
    end
    return guard
end

local function ApplyCorpseGuard(player, guard)
    if type(player) ~= "table" then
        return true
    end
    player.agon_death_guard = guard
    if not AddTag(player, "agon_corpse")
        or not AddTag(player, "notarget") then
        return false
    end
    if player.Physics ~= nil and type(player.Physics.SetActive) == "function" then
        local ok = ProtectedCall(player.Physics.SetActive, player.Physics, false)
        if not ok then
            return false
        end
    end
    local locomotor = type(player.components) == "table"
        and player.components.locomotor
        or nil
    if locomotor ~= nil and type(locomotor.Stop) == "function" then
        local ok = ProtectedCall(locomotor.Stop, locomotor)
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
    if health ~= nil then
        if type(health.SetInvincible) == "function" then
            local ok = ProtectedCall(health.SetInvincible, health, true)
            if not ok then
                return false
            end
        end
        health.canheal = false
    end
    player.agon_death_guard_applied = true
    return true
end

local function RestoreCorpseGuard(player)
    if type(player) ~= "table" then
        return true
    end
    local guard = player.agon_death_guard
    if type(guard) ~= "table" then
        return true
    end
    local restored = true
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
    if health ~= nil then
        if type(health.SetInvincible) == "function" then
            restored = ProtectedCall(
                health.SetInvincible,
                health,
                guard.health_invincible == true
            ) and restored
        end
        if guard.health_canheal ~= nil then
            health.canheal = guard.health_canheal
        end
    end
    if not guard.had_notarget then
        restored = RemoveTag(player, "notarget") and restored
    end
    restored = RemoveTag(player, "agon_corpse") and restored
    player.agon_death_guard = nil
    player.agon_death_guard_applied = nil
    return restored
end

local function ClearPlayerDeathState(player, state)
    if type(player) ~= "table" then
        return true
    end
    local cleared = true
    if state == DeathPolicy.MODES.REVIVABLE_CORPSE
        and type(player.components) == "table"
        and player.components.revivablecorpse ~= nil
        and type(player.components.revivablecorpse.SetCorpse) == "function" then
        cleared = ProtectedCall(
            player.components.revivablecorpse.SetCorpse,
            player.components.revivablecorpse,
            false
        ) and cleared
    end
    if state == DeathPolicy.MODES.REVIVABLE_CORPSE then
        cleared = RestoreCorpseGuard(player) and cleared
    elseif state == DeathPolicy.MODES.GHOST then
        cleared = RemoveTag(player, "agon_ghost") and cleared
    end
    player.agon_death_state = nil
    player.agon_death_policy = nil
    return cleared
end

local function AttachMethods(policy)
    policy.GetDeathMode = DeathPolicy.GetDeathMode
    policy.GetRecord = DeathPolicy.GetRecord
    policy.OnPlayerDeath = DeathPolicy.OnPlayerDeath
    policy.OnPlayerRevived = DeathPolicy.OnPlayerRevived
    policy.OnPlayerAttached = DeathPolicy.OnPlayerAttached
    policy.CanGhostMove = DeathPolicy.CanGhostMove
    policy.MoveGhost = DeathPolicy.MoveGhost
    policy.CanRevive = DeathPolicy.CanRevive
    policy.BeginRevive = DeathPolicy.BeginRevive
    policy.CompleteRevive = DeathPolicy.CompleteRevive
    policy.CancelRevive = DeathPolicy.CancelRevive
    policy.OnParticipantLeave = DeathPolicy.OnParticipantLeave
    policy.OnInstanceDestroy = DeathPolicy.OnInstanceDestroy
    policy.OnSave = DeathPolicy.OnSave
    policy.GetSnapshot = DeathPolicy.GetSnapshot
    policy.Validate = DeathPolicy.Validate
    policy.GetDebugString = DeathPolicy.GetDebugString
    return policy
end

function DeathPolicy.New(instance, options)
    options = type(options) == "table" and options or {}
    if type(instance) ~= "table"
        or type(instance.instance_id) ~= "string"
        or instance.instance_id == ""
        or type(instance.zone) ~= "table" then
        return nil, DeathPolicy.ERROR_CODES.INVALID_POLICY
    end
    local mode = options.mode or DeathPolicy.MODES.GHOST
    if mode ~= DeathPolicy.MODES.GHOST
        and mode ~= DeathPolicy.MODES.REVIVABLE_CORPSE then
        return nil, DeathPolicy.ERROR_CODES.INVALID_MODE
    end
    return AttachMethods(
    {
        schema_version = DeathPolicy.SCHEMA_VERSION,
        service_id = DeathPolicy.SERVICE_ID,
        service_version = DeathPolicy.SERVICE_VERSION,
        instance = instance,
        instance_id = instance.instance_id,
        mode = mode,
        now_fn = options.now_fn or instance.now_fn,
        records_by_userid = {},
        revive_session = nil,
        next_revive_sequence = 0,
        closed = false,
    })
end

function DeathPolicy.GetDeathMode(self)
    return self.mode
end

function DeathPolicy.GetRecord(self, player_or_userid)
    local userid = GetUserid(player_or_userid)
    return userid ~= nil and self.records_by_userid[userid] or nil
end

local function ResolveParticipant(self, value)
    if type(value) == "table"
        and IsNonEmptyString(value.userid)
        and value.instance_id == self.instance_id then
        return value
    end
    local userid = GetUserid(value)
    if userid == nil or self.instance == nil
        or type(self.instance.GetParticipant) ~= "function" then
        return nil
    end
    return self.instance:GetParticipant(userid)
end

local function ResolvePlayer(participant, supplied)
    if supplied ~= nil then
        return supplied
    end
    if participant ~= nil and type(participant.GetPlayer) == "function" then
        return participant:GetPlayer()
    end
    return participant ~= nil and participant.player_ref or nil
end

local function IsActiveParticipant(participant)
    return participant ~= nil
        and type(participant.IsActive) == "function"
        and participant:IsActive()
end

local function IsAliveParticipant(participant)
    if not IsActiveParticipant(participant) then
        return false
    end
    local state = type(participant.GetState) == "function"
        and participant:GetState()
        or participant.state
    if state ~= Participant.STATES.READY
        and state ~= Participant.STATES.PLAYING then
        return false
    end
    local death_state = participant.death_state
    return death_state == nil
        and state ~= Participant.STATES.GHOST
        and state ~= Participant.STATES.CORPSE
        or death_state == Participant.DEATH_STATES.ALIVE
            and state ~= Participant.STATES.GHOST
            and state ~= Participant.STATES.CORPSE
end

local function IsInsideBounds(point, bounds)
    return IsPoint(point)
        and type(bounds) == "table"
        and IsPoint(bounds.min)
        and IsPoint(bounds.max)
        and point.x >= bounds.min.x
        and point.x <= bounds.max.x
        and point.z >= bounds.min.z
        and point.z <= bounds.max.z
end

function DeathPolicy.OnPlayerDeath(self, participant_or_userid, player, data)
    if self.closed then
        return nil, DeathPolicy.ERROR_CODES.INVALID_POLICY
    end
    local participant = ResolveParticipant(self, participant_or_userid)
    if not IsActiveParticipant(participant) then
        return nil, DeathPolicy.ERROR_CODES.PARTICIPANT_NOT_ACTIVE
    end
    local userid = participant.userid
    local existing = self.records_by_userid[userid]
    if existing ~= nil then
        return existing, DeathPolicy.ERROR_CODES.ALREADY_DEAD
    end
    local resolved_player = ResolvePlayer(participant, player)
    local death_state = self.mode == DeathPolicy.MODES.GHOST
        and Participant.DEATH_STATES.GHOST
        or Participant.DEATH_STATES.CORPSE
    local changed, change_code = participant:SetDeathState(
        death_state,
        self.instance.generation,
        GetNow(self)
    )
    if not changed then
        return nil, change_code or DeathPolicy.ERROR_CODES.INVALID_PARTICIPANT
    end
    local record =
    {
        schema_version = DeathPolicy.SCHEMA_VERSION,
        userid = userid,
        instance_id = self.instance_id,
        mode = self.mode,
        death_state = death_state,
        entered_at = GetNow(self),
        cause = type(data) == "table" and data.cause or nil,
        player = resolved_player,
    }
    self.records_by_userid[userid] = record
    if resolved_player ~= nil then
        resolved_player.agon_death_state = death_state
        resolved_player.agon_death_policy = self.mode
        if self.mode == DeathPolicy.MODES.GHOST then
            local tagged = AddTag(resolved_player, "agon_ghost")
            if not tagged then
                self.records_by_userid[userid] = nil
                participant:SetDeathState(Participant.DEATH_STATES.ALIVE)
                return nil, DeathPolicy.ERROR_CODES.INVALID_POLICY
            end
        else
            local guard = GetPlayerGuard(resolved_player)
            if not ApplyCorpseGuard(resolved_player, guard) then
                ClearPlayerDeathState(resolved_player, self.mode)
                self.records_by_userid[userid] = nil
                participant:SetDeathState(Participant.DEATH_STATES.ALIVE)
                return nil, DeathPolicy.ERROR_CODES.INVALID_POLICY
            end
            local corpse = type(resolved_player.components) == "table"
                and resolved_player.components.revivablecorpse
                or nil
            if corpse ~= nil and type(corpse.SetCorpse) == "function" then
                ProtectedCall(corpse.SetCorpse, corpse, true)
                if type(corpse.SetCanBeRevivedByFn) == "function" then
                    corpse:SetCanBeRevivedByFn(function(_, reviver)
                        return self:CanRevive(reviver, participant)
                    end)
                end
            end
        end
    end
    return record
end

function DeathPolicy.OnPlayerRevived(self, player_or_userid, source)
    local participant = ResolveParticipant(self, player_or_userid)
    if participant == nil then
        return false, DeathPolicy.ERROR_CODES.PARTICIPANT_NOT_FOUND
    end
    local record = self.records_by_userid[participant.userid]
    if record == nil then
        return true, "ALREADY_ALIVE"
    end
    if self.mode == DeathPolicy.MODES.REVIVABLE_CORPSE then
        if source == nil then
            return false, DeathPolicy.ERROR_CODES.REVIVE_FORBIDDEN
        end
        local allowed = self:CanRevive(source, participant)
        if not allowed then
            return false, DeathPolicy.ERROR_CODES.REVIVE_FORBIDDEN
        end
    end
    local player = ResolvePlayer(participant, type(player_or_userid) == "table"
        and player_or_userid or nil)
    local changed, change_code = participant:SetDeathState(
        Participant.DEATH_STATES.ALIVE,
        self.instance.generation,
        GetNow(self)
    )
    if not changed then
        return false, change_code or DeathPolicy.ERROR_CODES.REVIVE_FAILED
    end
    self.records_by_userid[participant.userid] = nil
    if self.revive_session ~= nil
        and self.revive_session.corpse_userid == participant.userid then
        self.revive_session = nil
    end
    if not ClearPlayerDeathState(player, record.mode) then
        return false, DeathPolicy.ERROR_CODES.REVIVE_FAILED
    end
    return true
end

function DeathPolicy.OnPlayerAttached(self, participant, player)
    local record = self:GetRecord(participant)
    if record == nil and participant ~= nil
        and participant.death_state ~= Participant.DEATH_STATES.ALIVE then
        record =
        {
            schema_version = DeathPolicy.SCHEMA_VERSION,
            userid = participant.userid,
            instance_id = self.instance_id,
            mode = self.mode,
            death_state = participant.death_state,
            entered_at = GetNow(self),
            player = player,
        }
        self.records_by_userid[participant.userid] = record
    elseif record ~= nil then
        record.player = player
    end
    if record == nil or player == nil then
        return true
    end
    player.agon_death_state = record.death_state
    player.agon_death_policy = record.mode
    if record.mode == DeathPolicy.MODES.GHOST then
        return AddTag(player, "agon_ghost")
    end
    local applied = ApplyCorpseGuard(player, GetPlayerGuard(player))
    if not applied then
        RestoreCorpseGuard(player)
    end
    return applied
end

function DeathPolicy.CanGhostMove(self, participant_or_userid, player, position)
    local participant = ResolveParticipant(self, participant_or_userid)
    local record = participant ~= nil and self.records_by_userid[participant.userid] or nil
    if self.mode ~= DeathPolicy.MODES.GHOST
        or record == nil
        or record.death_state ~= Participant.DEATH_STATES.GHOST
        or not IsPoint(position)
        or not IsInsideBounds(position, self.instance.zone.safe_bounds) then
        return false, DeathPolicy.ERROR_CODES.GHOST_MOVE_FORBIDDEN
    end
    return true
end

function DeathPolicy.MoveGhost(self, participant_or_userid, player, position)
    local allowed, code = self:CanGhostMove(participant_or_userid, player, position)
    if not allowed then
        return false, code
    end
    if type(player) == "table" and player.Transform ~= nil
        and type(player.Transform.SetPosition) == "function" then
        local ok = ProtectedCall(
            player.Transform.SetPosition,
            player.Transform,
            position.x,
            position.y or 0,
            position.z
        )
        if not ok then
            return false, DeathPolicy.ERROR_CODES.GHOST_MOVE_FORBIDDEN
        end
    end
    if type(player) == "table" then
        player.agon_ghost_position = CopyValue(position)
    end
    return true
end

local function IsRevivePairValid(self, reviver, corpse)
    return self.mode == DeathPolicy.MODES.REVIVABLE_CORPSE
        and IsActiveParticipant(reviver)
        and IsActiveParticipant(corpse)
        and reviver.userid ~= corpse.userid
        and IsAliveParticipant(reviver)
        and corpse.death_state == Participant.DEATH_STATES.CORPSE
        and self.records_by_userid[corpse.userid] ~= nil
end

function DeathPolicy.CanRevive(self, reviver_or_userid, corpse_or_userid)
    if self.mode ~= DeathPolicy.MODES.REVIVABLE_CORPSE
        or self.revive_session ~= nil then
        return false, DeathPolicy.ERROR_CODES.REVIVE_FORBIDDEN
    end
    local reviver = ResolveParticipant(self, reviver_or_userid)
    local corpse = ResolveParticipant(self, corpse_or_userid)
    if not IsRevivePairValid(self, reviver, corpse) then
        return false, DeathPolicy.ERROR_CODES.REVIVE_FORBIDDEN
    end
    return true
end

function DeathPolicy.BeginRevive(self, reviver_or_userid, corpse_or_userid)
    local allowed, code = self:CanRevive(reviver_or_userid, corpse_or_userid)
    if not allowed then
        return nil, code
    end
    local reviver = ResolveParticipant(self, reviver_or_userid)
    local corpse = ResolveParticipant(self, corpse_or_userid)
    self.next_revive_sequence = self.next_revive_sequence + 1
    self.revive_session =
    {
        schema_version = DeathPolicy.SCHEMA_VERSION,
        revive_id = self.instance_id .. ":revive:" .. tostring(self.next_revive_sequence),
        instance_id = self.instance_id,
        reviver_userid = reviver.userid,
        corpse_userid = corpse.userid,
        started_at = GetNow(self),
        state = "IN_PROGRESS",
    }
    return self.revive_session
end

local function ResolveReviveSession(self, value, corpse_or_userid)
    if type(value) == "table"
        and value.revive_id ~= nil
        and value.instance_id == self.instance_id then
        if self.revive_session ~= nil
            and self.revive_session.revive_id == value.revive_id then
            return self.revive_session
        end
        return nil
    end
    local reviver = GetUserid(value)
    local corpse = GetUserid(corpse_or_userid)
    if self.revive_session ~= nil
        and (reviver == nil or self.revive_session.reviver_userid == reviver)
        and (corpse == nil or self.revive_session.corpse_userid == corpse) then
        return self.revive_session
    end
    return nil
end

function DeathPolicy.CompleteRevive(self, revive_or_reviver, corpse_or_userid)
    local session = ResolveReviveSession(self, revive_or_reviver, corpse_or_userid)
    if session == nil then
        return false, DeathPolicy.ERROR_CODES.REVIVE_NOT_FOUND
    end
    local reviver = ResolveParticipant(self, session.reviver_userid)
    local corpse = ResolveParticipant(self, session.corpse_userid)
    if not IsRevivePairValid(self, reviver, corpse) then
        return false, DeathPolicy.ERROR_CODES.REVIVE_FAILED
    end
    local corpse_player = ResolvePlayer(corpse)
    local reviver_player = ResolvePlayer(reviver)
    if corpse_player ~= nil
        and type(corpse_player.components) == "table"
        and corpse_player.components.revivablecorpse ~= nil
        and type(corpse_player.components.revivablecorpse.Revive) == "function"
        and reviver_player ~= nil then
        local ok = ProtectedCall(
            corpse_player.components.revivablecorpse.Revive,
            corpse_player.components.revivablecorpse,
            reviver_player
        )
        if not ok then
            return false, DeathPolicy.ERROR_CODES.REVIVE_FAILED
        end
    end
    local changed, change_code = corpse:SetDeathState(
        Participant.DEATH_STATES.ALIVE,
        self.instance.generation,
        GetNow(self)
    )
    if not changed then
        return false, change_code or DeathPolicy.ERROR_CODES.REVIVE_FAILED
    end
    self.records_by_userid[corpse.userid] = nil
    self.revive_session = nil
    if not ClearPlayerDeathState(corpse_player, DeathPolicy.MODES.REVIVABLE_CORPSE) then
        return false, DeathPolicy.ERROR_CODES.REVIVE_FAILED
    end
    return true
end

function DeathPolicy.CancelRevive(self, revive_or_reviver, corpse_or_userid, reason)
    local session = ResolveReviveSession(self, revive_or_reviver, corpse_or_userid)
    if session == nil then
        return false, DeathPolicy.ERROR_CODES.REVIVE_NOT_FOUND
    end
    session.state = "CANCELLED"
    session.cancel_reason = reason ~= nil and tostring(reason) or nil
    self.revive_session = nil
    return true
end

function DeathPolicy.OnParticipantLeave(self, participant_or_userid, reason)
    local userid = GetUserid(participant_or_userid)
    if userid == nil then
        return false, DeathPolicy.ERROR_CODES.INVALID_PARTICIPANT
    end
    if self.revive_session ~= nil
        and (self.revive_session.corpse_userid == userid
            or self.revive_session.reviver_userid == userid) then
        self:CancelRevive(self.revive_session, nil, reason or "participant_leave")
    end
    local record = self.records_by_userid[userid]
    if record ~= nil then
        local cleared = ClearPlayerDeathState(record.player, record.mode)
        self.records_by_userid[userid] = nil
        if not cleared then
            return false, DeathPolicy.ERROR_CODES.REVIVE_FAILED
        end
    end
    return true
end

function DeathPolicy.OnInstanceDestroy(self, reason)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    local all_cleared = true
    local userids = {}
    for userid in pairs(self.records_by_userid) do
        table.insert(userids, userid)
    end
    for index = 1, #userids do
        local userid = userids[index]
        local record = self.records_by_userid[userid]
        local cleared = ClearPlayerDeathState(record.player, record.mode)
        if not cleared then
            all_cleared = false
        end
        if cleared and self.records_by_userid[userid] == record then
            self.records_by_userid[userid] = nil
        end
    end
    self.revive_session = nil
    if all_cleared then
        self.closed = true
        return true
    end
    return false, DeathPolicy.ERROR_CODES.REVIVE_FAILED
end

function DeathPolicy.GetSnapshot(self)
    local records = {}
    for userid, record in pairs(self.records_by_userid) do
        records[userid] =
        {
            schema_version = record.schema_version,
            userid = record.userid,
            instance_id = record.instance_id,
            mode = record.mode,
            death_state = record.death_state,
            entered_at = record.entered_at,
            cause = record.cause,
        }
    end
    return
    {
        schema_version = self.schema_version,
        service_id = self.service_id,
        service_version = self.service_version,
        instance_id = self.instance_id,
        mode = self.mode,
        closed = self.closed,
        records = records,
        revive_session = CopyValue(self.revive_session),
    }
end

function DeathPolicy.OnSave(self)
    return self:GetSnapshot()
end

function DeathPolicy.Validate(self)
    if self.instance == nil
        or self.instance.instance_id ~= self.instance_id
        or (self.mode ~= DeathPolicy.MODES.GHOST
            and self.mode ~= DeathPolicy.MODES.REVIVABLE_CORPSE) then
        return false, DeathPolicy.ERROR_CODES.INVALID_POLICY
    end
    for userid, record in pairs(self.records_by_userid) do
        local participant = self.instance:GetParticipant(userid)
        if participant == nil
            or record.userid ~= userid
            or record.instance_id ~= self.instance_id
            or record.mode ~= self.mode
            or participant.death_state ~= record.death_state then
            return false, DeathPolicy.ERROR_CODES.INVALID_POLICY
        end
    end
    if self.revive_session ~= nil then
        local revive = self.revive_session
        if revive.instance_id ~= self.instance_id
            or self.records_by_userid[revive.corpse_userid] == nil
            or self.instance:GetParticipant(revive.reviver_userid) == nil
            or self.instance:GetParticipant(revive.corpse_userid) == nil then
            return false, DeathPolicy.ERROR_CODES.INVALID_POLICY
        end
    end
    return true
end

function DeathPolicy.GetDebugString(self)
    local count = 0
    for _ in pairs(self.records_by_userid) do
        count = count + 1
    end
    return string.format(
        "death_policy instance=%s mode=%s records=%d revive=%s closed=%s",
        tostring(self.instance_id),
        tostring(self.mode),
        count,
        tostring(self.revive_session ~= nil),
        tostring(self.closed)
    )
end

return DeathPolicy
