-- WP4：一个 userid 与一个 Instance 之间的生命周期关系。

local Participant = {}

Participant.SCHEMA_VERSION = 1

Participant.STATES =
{
    JOINING = "JOINING",
    READY = "READY",
    PLAYING = "PLAYING",
    LEAVING = "LEAVING",
    LEFT = "LEFT",
    DISCONNECTED = "DISCONNECTED",
    GHOST = "GHOST",
    CORPSE = "CORPSE",
}

Participant.DEATH_STATES =
{
    ALIVE = "ALIVE",
    GHOST = "GHOST",
    CORPSE = "CORPSE",
}

Participant.ERROR_CODES =
{
    INVALID_PARTICIPANT = "INVALID_PARTICIPANT",
    INVALID_USERID = "INVALID_USERID",
    INVALID_INSTANCE_ID = "INVALID_INSTANCE_ID",
    INVALID_STATE = "INVALID_PARTICIPANT_STATE",
    INVALID_TRANSITION = "INVALID_PARTICIPANT_TRANSITION",
    PLAYER_USERID_MISMATCH = "PLAYER_USERID_MISMATCH",
    PARTICIPANT_LEFT = "PARTICIPANT_LEFT",
}

Participant.TRANSITIONS =
{
    JOINING =
    {
        READY = true,
        DISCONNECTED = true,
        LEAVING = true,
        LEFT = true,
    },
    READY =
    {
        PLAYING = true,
        DISCONNECTED = true,
        LEAVING = true,
        LEFT = true,
    },
    PLAYING =
    {
        DISCONNECTED = true,
        GHOST = true,
        CORPSE = true,
        LEAVING = true,
    },
    DISCONNECTED =
    {
        READY = true,
        PLAYING = true,
        GHOST = true,
        CORPSE = true,
        LEAVING = true,
        LEFT = true,
    },
    GHOST =
    {
        READY = true,
        PLAYING = true,
        DISCONNECTED = true,
        LEAVING = true,
        LEFT = true,
    },
    CORPSE =
    {
        READY = true,
        PLAYING = true,
        DISCONNECTED = true,
        LEAVING = true,
        LEFT = true,
    },
    LEAVING = { LEFT = true },
    LEFT = {},
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number" and value == math.floor(value) and value >= 1
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

local function GetNow(self)
    if type(self.now_fn) == "function" then
        return self.now_fn()
    end
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

function Participant.GetUserid(self)
    return self.userid
end

function Participant.GetInstanceId(self)
    return self.instance_id
end

function Participant.GetState(self)
    return self.state
end

function Participant.GetGeneration(self)
    return self.generation
end

function Participant.GetPlayer(self)
    return self.player_ref
end

function Participant.IsActive(self)
    return self.state ~= Participant.STATES.LEFT
end

function Participant.CanTransition(self, next_state)
    local transitions = Participant.TRANSITIONS[self.state]
    return transitions ~= nil and transitions[next_state] == true
end

function Participant.SetInstanceGeneration(self, generation)
    if not IsPositiveInteger(generation) then
        return false, Participant.ERROR_CODES.INVALID_PARTICIPANT
    end
    self.generation = generation
    return true
end

function Participant.TransitionTo(self, next_state, reason, generation, now)
    if not IsNonEmptyString(next_state)
        or Participant.TRANSITIONS[next_state] == nil then
        return false, Participant.ERROR_CODES.INVALID_STATE
    end
    if self.state == next_state then
        return true, "ALREADY_IN_STATE"
    end
    if not self:CanTransition(next_state) then
        return false, Participant.ERROR_CODES.INVALID_TRANSITION
    end

    self.state = next_state
    self.revision = self.revision + 1
    if IsPositiveInteger(generation) then
        self.generation = generation
    end
    self.state_entered_at = now ~= nil and now or GetNow(self)
    self.last_transition_reason = reason ~= nil and tostring(reason) or nil

    if next_state == Participant.STATES.GHOST then
        self.death_state = Participant.DEATH_STATES.GHOST
    elseif next_state == Participant.STATES.CORPSE then
        self.death_state = Participant.DEATH_STATES.CORPSE
    elseif next_state == Participant.STATES.PLAYING
        or next_state == Participant.STATES.READY then
        self.death_state = Participant.DEATH_STATES.ALIVE
    end
    return true
end

function Participant.AttachPlayer(self, player, generation, now)
    if player == nil or not IsNonEmptyString(player.userid)
        or player.userid ~= self.userid then
        return false, Participant.ERROR_CODES.PLAYER_USERID_MISMATCH
    end
    if self.state == Participant.STATES.LEFT then
        return false, Participant.ERROR_CODES.PARTICIPANT_LEFT
    end

    self.player_ref = player
    self.disconnected_at = nil
    if self.state == Participant.STATES.DISCONNECTED then
        return self:TransitionTo(
            Participant.STATES.READY,
            "player_reconnected",
            generation,
            now
        )
    end
    if self.state == Participant.STATES.JOINING then
        return self:TransitionTo(
            Participant.STATES.READY,
            "player_ready",
            generation,
            now
        )
    end
    if IsPositiveInteger(generation) then
        self.generation = generation
    end
    return true
end

function Participant.MarkDisconnected(self, reason, generation, now)
    self.player_ref = nil
    self.disconnected_at = now ~= nil and now or GetNow(self)
    if self.state == Participant.STATES.LEFT
        or self.state == Participant.STATES.LEAVING
        or self.state == Participant.STATES.DISCONNECTED then
        if IsPositiveInteger(generation) then
            self.generation = generation
        end
        return true
    end
    return self:TransitionTo(
        Participant.STATES.DISCONNECTED,
        reason or "player_disconnected",
        generation,
        now
    )
end

function Participant.MarkLeaving(self, reason, generation, now)
    if self.state == Participant.STATES.LEFT then
        return true, "ALREADY_LEFT"
    end
    if self.state == Participant.STATES.LEAVING then
        return true, "ALREADY_LEAVING"
    end
    return self:TransitionTo(
        Participant.STATES.LEAVING,
        reason or "participant_leaving",
        generation,
        now
    )
end

function Participant.MarkLeft(self, reason, generation, now)
    if self.state == Participant.STATES.LEFT then
        return true, "ALREADY_LEFT"
    end
    if self.state ~= Participant.STATES.LEAVING then
        local leaving, leaving_code = self:MarkLeaving(
            reason or "participant_left",
            generation,
            now
        )
        if not leaving then
            return false, leaving_code
        end
    end
    return self:TransitionTo(
        Participant.STATES.LEFT,
        reason or "participant_left",
        generation,
        now
    )
end

function Participant.SetDeathState(self, death_state, generation, now)
    if death_state == Participant.DEATH_STATES.ALIVE then
        if self.state == Participant.STATES.GHOST
            or self.state == Participant.STATES.CORPSE then
            return self:TransitionTo(
                Participant.STATES.PLAYING,
                "death_state_cleared",
                generation,
                now
            )
        end
        return true
    elseif death_state == Participant.DEATH_STATES.GHOST then
        return self:TransitionTo(
            Participant.STATES.GHOST,
            "death_state_ghost",
            generation,
            now
        )
    elseif death_state == Participant.DEATH_STATES.CORPSE then
        return self:TransitionTo(
            Participant.STATES.CORPSE,
            "death_state_corpse",
            generation,
            now
        )
    end
    return false, Participant.ERROR_CODES.INVALID_STATE
end

function Participant.GetSnapshot(self)
    return
    {
        schema_version = Participant.SCHEMA_VERSION,
        userid = self.userid,
        instance_id = self.instance_id,
        state = self.state,
        joined_at = self.joined_at,
        disconnected_at = self.disconnected_at,
        group_ids = CopyValue(self.group_ids),
        role = self.role,
        sandbox_transaction_id = self.sandbox_transaction_id,
        death_state = self.death_state,
        generation = self.generation,
        revision = self.revision,
        state_entered_at = self.state_entered_at,
        last_transition_reason = self.last_transition_reason,
    }
end

local function AttachMethods(participant)
    participant.GetUserid = Participant.GetUserid
    participant.GetInstanceId = Participant.GetInstanceId
    participant.GetState = Participant.GetState
    participant.GetGeneration = Participant.GetGeneration
    participant.GetPlayer = Participant.GetPlayer
    participant.IsActive = Participant.IsActive
    participant.CanTransition = Participant.CanTransition
    participant.SetInstanceGeneration = Participant.SetInstanceGeneration
    participant.TransitionTo = Participant.TransitionTo
    participant.AttachPlayer = Participant.AttachPlayer
    participant.MarkDisconnected = Participant.MarkDisconnected
    participant.MarkLeaving = Participant.MarkLeaving
    participant.MarkLeft = Participant.MarkLeft
    participant.SetDeathState = Participant.SetDeathState
    participant.GetSnapshot = Participant.GetSnapshot
    return participant
end

function Participant.New(userid, instance_id, options)
    if not IsNonEmptyString(userid) then
        return nil, Participant.ERROR_CODES.INVALID_USERID
    end
    if not IsNonEmptyString(instance_id) then
        return nil, Participant.ERROR_CODES.INVALID_INSTANCE_ID
    end

    options = type(options) == "table" and options or {}
    local generation = options.generation or 1
    if not IsPositiveInteger(generation) then
        return nil, Participant.ERROR_CODES.INVALID_PARTICIPANT
    end

    local state = options.state or Participant.STATES.JOINING
    if Participant.TRANSITIONS[state] == nil then
        return nil, Participant.ERROR_CODES.INVALID_STATE
    end

    return AttachMethods(
    {
        schema_version = Participant.SCHEMA_VERSION,
        userid = userid,
        instance_id = instance_id,
        state = state,
        player_ref = options.player_ref,
        joined_at = options.joined_at or 0,
        disconnected_at = options.disconnected_at,
        group_ids = CopyValue(options.group_ids or {}),
        role = options.role,
        sandbox_transaction_id = options.sandbox_transaction_id,
        death_state = options.death_state or Participant.DEATH_STATES.ALIVE,
        generation = generation,
        revision = options.revision or 0,
        state_entered_at = options.state_entered_at or options.joined_at or 0,
        last_transition_reason = options.last_transition_reason,
        now_fn = options.now_fn,
    })
end

return Participant
