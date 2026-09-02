-- WP4：Player-scoped classified 的最小网络字段和绑定辅助。

local Classified = {}

Classified.SCHEMA_VERSION = 1
Classified.PREFAB = "agon_player_classified"

Classified.NETWORK_FIELDS =
{
    INSTANCE_ID = "instance_id",
    MODE_ID = "mode_id",
    PARTICIPANT_STATE = "participant_state",
    GENERATION = "generation",
    STATE_PAYLOAD = "state_payload",
    SPECTATOR_STATE = "spectator_state",
}

local function Encode(value)
    if type(value) == "string" then
        return value
    end
    if type(json) == "table" and type(json.encode) == "function" then
        local ok, encoded = pcall(json.encode, value)
        if ok and type(encoded) == "string" then
            return encoded
        end
    end
    return ""
end

local function ReadNetValue(netvar, default)
    if netvar ~= nil and type(netvar.value) == "function" then
        local ok, value = pcall(netvar.value, netvar)
        if ok then
            return value
        end
    end
    return default
end

function Classified.Configure(inst)
    if inst == nil or inst.GUID == nil then
        return false
    end
    inst.agon_instance_id = net_string(
        inst.GUID,
        "agon_player_classified.instance_id",
        "agon_instance_dirty"
    )
    inst.agon_mode_id = net_string(
        inst.GUID,
        "agon_player_classified.mode_id",
        "agon_instance_dirty"
    )
    inst.agon_participant_state = net_string(
        inst.GUID,
        "agon_player_classified.participant_state",
        "agon_participant_dirty"
    )
    inst.agon_generation = net_uint(
        inst.GUID,
        "agon_player_classified.generation",
        "agon_participant_dirty"
    )
    inst.agon_state_payload = net_string(
        inst.GUID,
        "agon_player_classified.state_payload",
        "agon_state_dirty"
    )
    inst.agon_spectator_state = net_string(
        inst.GUID,
        "agon_player_classified.spectator_state",
        "agon_spectator_dirty"
    )
    return true
end

function Classified.SetParticipant(inst, participant, instance)
    if inst == nil or participant == nil then
        return false
    end
    if inst.agon_instance_id == nil
        or inst.agon_mode_id == nil
        or inst.agon_participant_state == nil
        or inst.agon_generation == nil then
        return false
    end
    inst.agon_instance_id:set(participant.instance_id or "")
    inst.agon_mode_id:set(
        (instance ~= nil and instance.mode_id) or participant.mode_id or ""
    )
    inst.agon_participant_state:set(participant.state or "")
    inst.agon_generation:set(participant.generation or 0)
    return true
end

function Classified.ClearParticipant(inst)
    if inst == nil or inst.agon_instance_id == nil then
        return false
    end
    inst.agon_instance_id:set("")
    inst.agon_mode_id:set("")
    inst.agon_participant_state:set("")
    inst.agon_generation:set(0)
    if inst.agon_state_payload ~= nil then
        inst.agon_state_payload:set("")
    end
    if inst.agon_spectator_state ~= nil then
        inst.agon_spectator_state:set("")
    end
    return true
end

function Classified.SetAudiencePayload(inst, payload)
    if inst == nil or inst.agon_state_payload == nil then
        return false
    end
    local encoded = Encode(payload)
    if #encoded > 60000 then
        return false
    end
    inst.agon_state_payload:set(encoded)
    return true
end

function Classified.SetSpectatorState(inst, state)
    if inst == nil or inst.agon_spectator_state == nil then
        return false
    end
    local encoded = Encode(state or {})
    if #encoded > 60000 then
        return false
    end
    inst.agon_spectator_state:set(encoded)
    return true
end

function Classified.GetClientState(inst)
    if inst == nil then
        return nil
    end
    return
    {
        schema_version = Classified.SCHEMA_VERSION,
        instance_id = ReadNetValue(inst.agon_instance_id, ""),
        mode_id = ReadNetValue(inst.agon_mode_id, ""),
        participant_state = ReadNetValue(inst.agon_participant_state, ""),
        generation = ReadNetValue(inst.agon_generation, 0),
        state_payload = ReadNetValue(inst.agon_state_payload, ""),
        spectator_state = ReadNetValue(inst.agon_spectator_state, ""),
    }
end

function Classified.AttachToPlayer(inst, player)
    if inst == nil or player == nil or player.entity == nil
        or inst.Network == nil or type(inst.Network.SetClassifiedTarget) ~= "function"
        or inst.entity == nil or type(inst.entity.SetParent) ~= "function" then
        return false
    end
    inst.Network:SetClassifiedTarget(player)
    inst.entity:SetParent(player.entity)
    inst._parent = player
    if player.agon_player_classified ~= nil
        and player.agon_player_classified ~= inst then
        return false
    end
    player.agon_player_classified = inst
    return true
end

function Classified.BindParent(inst)
    if inst == nil or inst.entity == nil
        or type(inst.entity.GetParent) ~= "function" then
        return nil
    end
    local parent = inst.entity:GetParent()
    if parent ~= nil then
        inst._parent = parent
        parent.agon_player_classified = inst
    end
    return parent
end

function Classified.UnbindParent(inst)
    local parent = inst ~= nil and inst._parent or nil
    if parent ~= nil and parent.agon_player_classified == inst then
        parent.agon_player_classified = nil
    end
    if inst ~= nil then
        inst._parent = nil
    end
end

return Classified
