-- WP4：只按授权 audience 暴露可序列化状态的公共网络边界。

local AudienceStateChannel = {}

AudienceStateChannel.SCHEMA_VERSION = 1
AudienceStateChannel.MAX_PAYLOAD_BYTES = 60000

AudienceStateChannel.KINDS =
{
    PRIVATE = "PRIVATE",
    GROUP = "GROUP",
    INSTANCE = "INSTANCE",
    SPECTATOR = "SPECTATOR",
    PUBLIC = "PUBLIC",
}

AudienceStateChannel.ERROR_CODES =
{
    INVALID_STATE_ID = "INVALID_AUDIENCE_STATE_ID",
    INVALID_AUDIENCE = "INVALID_AUDIENCE",
    INVALID_VALUE = "INVALID_AUDIENCE_VALUE",
    PAYLOAD_TOO_LARGE = "AUDIENCE_PAYLOAD_TOO_LARGE",
    GROUP_RESOLVER_UNAVAILABLE = "AUDIENCE_GROUP_RESOLVER_UNAVAILABLE",
    SPECTATOR_RESOLVER_UNAVAILABLE = "AUDIENCE_SPECTATOR_RESOLVER_UNAVAILABLE",
}

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function CopySerializable(value, seen)
    local value_type = type(value)
    if value == nil or value_type == "boolean" or value_type == "string" then
        return value
    end
    if value_type == "number" then
        return IsFiniteNumber(value) and value or nil, not IsFiniteNumber(value)
    end
    if value_type ~= "table" then
        return nil, true
    end

    seen = seen or {}
    if seen[value] then
        return nil, true
    end
    seen[value] = true
    local copied = {}
    for key, item in pairs(value) do
        local key_type = type(key)
        if key_type ~= "string" and key_type ~= "number" then
            seen[value] = nil
            return nil, true
        end
        local copied_item, invalid = CopySerializable(item, seen)
        if invalid then
            seen[value] = nil
            return nil, true
        end
        copied[key] = copied_item
    end
    seen[value] = nil
    return copied
end

local function NormalizeAudience(audience)
    if type(audience) == "string" then
        audience = { kind = audience }
    end
    if type(audience) ~= "table"
        or not IsNonEmptyString(audience.kind)
        or AudienceStateChannel.KINDS[audience.kind] ~= audience.kind then
        return nil, AudienceStateChannel.ERROR_CODES.INVALID_AUDIENCE
    end

    local normalized = { kind = audience.kind }
    if audience.kind == AudienceStateChannel.KINDS.PRIVATE then
        if not IsNonEmptyString(audience.userid) then
            return nil, AudienceStateChannel.ERROR_CODES.INVALID_AUDIENCE
        end
        normalized.userid = audience.userid
    elseif audience.kind == AudienceStateChannel.KINDS.GROUP then
        if not IsNonEmptyString(audience.group_id) then
            return nil, AudienceStateChannel.ERROR_CODES.INVALID_AUDIENCE
        end
        normalized.group_id = audience.group_id
    elseif audience.kind == AudienceStateChannel.KINDS.INSTANCE
        or audience.kind == AudienceStateChannel.KINDS.SPECTATOR then
        if not IsNonEmptyString(audience.instance_id) then
            return nil, AudienceStateChannel.ERROR_CODES.INVALID_AUDIENCE
        end
        normalized.instance_id = audience.instance_id
    end
    return normalized
end

function AudienceStateChannel.Private(userid)
    return { kind = AudienceStateChannel.KINDS.PRIVATE, userid = userid }
end

function AudienceStateChannel.Group(group_id)
    return { kind = AudienceStateChannel.KINDS.GROUP, group_id = group_id }
end

function AudienceStateChannel.Instance(instance_id)
    return { kind = AudienceStateChannel.KINDS.INSTANCE, instance_id = instance_id }
end

function AudienceStateChannel.Spectator(instance_id)
    return { kind = AudienceStateChannel.KINDS.SPECTATOR, instance_id = instance_id }
end

function AudienceStateChannel.Public()
    return { kind = AudienceStateChannel.KINDS.PUBLIC }
end

function AudienceStateChannel.GetState(self, state_id)
    return self.states_by_id[state_id]
end

function AudienceStateChannel.Publish(self, state_id, audience, value, options)
    if not IsNonEmptyString(state_id) then
        return nil, AudienceStateChannel.ERROR_CODES.INVALID_STATE_ID
    end
    local normalized_audience, audience_code = NormalizeAudience(audience)
    if normalized_audience == nil then
        return nil, audience_code
    end

    local copied_value, invalid = CopySerializable(value)
    if invalid then
        return nil, AudienceStateChannel.ERROR_CODES.INVALID_VALUE
    end

    options = type(options) == "table" and options or {}
    local encoded_size
    if type(json) == "table" and type(json.encode) == "function" then
        local ok, encoded = pcall(json.encode, copied_value)
        if ok and type(encoded) == "string" then
            encoded_size = #encoded
        end
    end
    if encoded_size ~= nil and encoded_size > self.max_payload_bytes then
        return nil, AudienceStateChannel.ERROR_CODES.PAYLOAD_TOO_LARGE
    end

    local record = self.states_by_id[state_id]
    if record == nil then
        record =
        {
            state_id = state_id,
            created_at = options.created_at or self:Now(),
            version = 0,
        }
        self.states_by_id[state_id] = record
        table.insert(self.state_order, state_id)
    end
    self.next_version = self.next_version + 1
    record.version = self.next_version
    record.updated_at = options.updated_at or self:Now()
    record.audience = normalized_audience
    record.value = copied_value
    record.instance_id = options.instance_id
    record.mode_id = options.mode_id
    return self:CopyRecord(record)
end

function AudienceStateChannel.CopyRecord(self, record)
    if type(record) ~= "table" then
        return nil
    end
    return
    {
        schema_version = AudienceStateChannel.SCHEMA_VERSION,
        state_id = record.state_id,
        version = record.version,
        created_at = record.created_at,
        updated_at = record.updated_at,
        audience = CopySerializable(record.audience),
        value = CopySerializable(record.value),
        instance_id = record.instance_id,
        mode_id = record.mode_id,
    }
end

local function ContainsValue(values, expected)
    if type(values) ~= "table" then
        return false
    end
    for index = 1, #values do
        if values[index] == expected then
            return true
        end
    end
    return false
end

function AudienceStateChannel.IsVisible(self, record, userid, context)
    if record == nil or type(userid) ~= "string" then
        return false
    end
    context = type(context) == "table" and context or {}
    local audience = record.audience
    if audience.kind == AudienceStateChannel.KINDS.PUBLIC then
        return true
    elseif audience.kind == AudienceStateChannel.KINDS.PRIVATE then
        return audience.userid == userid
    elseif audience.kind == AudienceStateChannel.KINDS.INSTANCE then
        local current_instance_id = context.instance_id
        if current_instance_id == nil and type(self.resolve_instance_for_userid) == "function" then
            current_instance_id = self.resolve_instance_for_userid(userid)
        end
        return current_instance_id == audience.instance_id
    elseif audience.kind == AudienceStateChannel.KINDS.GROUP then
        local groups = context.group_ids
        if groups == nil and type(self.resolve_groups_for_userid) == "function" then
            groups = self.resolve_groups_for_userid(userid)
        end
        return ContainsValue(groups, audience.group_id)
    elseif audience.kind == AudienceStateChannel.KINDS.SPECTATOR then
        local spectating_instance_id = context.spectating_instance_id
        if spectating_instance_id == nil
            and type(self.resolve_spectating_instance_for_userid) == "function" then
            spectating_instance_id = self.resolve_spectating_instance_for_userid(userid)
        end
        return spectating_instance_id == audience.instance_id
    end
    return false
end

function AudienceStateChannel.ReadFor(self, userid, context)
    if not IsNonEmptyString(userid) then
        return {}
    end
    local visible = {}
    for index = 1, #self.state_order do
        local record = self.states_by_id[self.state_order[index]]
        if record ~= nil and self:IsVisible(record, userid, context) then
            table.insert(visible, self:CopyRecord(record))
        end
    end
    return visible
end

function AudienceStateChannel.ReadPayload(self, userid, context)
    local records = self:ReadFor(userid, context)
    local payload =
    {
        schema_version = AudienceStateChannel.SCHEMA_VERSION,
        states = records,
    }
    if type(json) == "table" and type(json.encode) == "function" then
        local ok, encoded = pcall(json.encode, payload)
        if ok and type(encoded) == "string" then
            if #encoded > self.max_payload_bytes then
                return nil, AudienceStateChannel.ERROR_CODES.PAYLOAD_TOO_LARGE
            end
            return encoded
        end
    end
    return payload
end

function AudienceStateChannel.Remove(self, state_id)
    if self.states_by_id[state_id] == nil then
        return false
    end
    self.states_by_id[state_id] = nil
    for index = 1, #self.state_order do
        if self.state_order[index] == state_id then
            table.remove(self.state_order, index)
            break
        end
    end
    return true
end

function AudienceStateChannel.ClearInstance(self, instance_id)
    if not IsNonEmptyString(instance_id) then
        return 0
    end
    local state_ids = {}
    for index = 1, #self.state_order do
        local record = self.states_by_id[self.state_order[index]]
        if record ~= nil and record.instance_id == instance_id then
            table.insert(state_ids, record.state_id)
        elseif record ~= nil and record.audience ~= nil
            and (record.audience.kind == AudienceStateChannel.KINDS.INSTANCE
                or record.audience.kind == AudienceStateChannel.KINDS.SPECTATOR)
            and record.audience.instance_id == instance_id then
            table.insert(state_ids, record.state_id)
        end
    end
    for index = 1, #state_ids do
        self:Remove(state_ids[index])
    end
    return #state_ids
end

function AudienceStateChannel.GetSnapshot(self)
    local states = {}
    for index = 1, #self.state_order do
        local record = self.states_by_id[self.state_order[index]]
        if record ~= nil then
            table.insert(states, self:CopyRecord(record))
        end
    end
    return
    {
        schema_version = AudienceStateChannel.SCHEMA_VERSION,
        next_version = self.next_version,
        states = states,
    }
end

function AudienceStateChannel.Now(self)
    if type(self.now_fn) == "function" then
        return self.now_fn()
    end
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

function AudienceStateChannel.GetDebugString(self)
    return string.format(
        "audience_state_channel states=%d next_version=%d",
        #self.state_order,
        self.next_version
    )
end

local function AttachMethods(channel)
    channel.GetState = AudienceStateChannel.GetState
    channel.Publish = AudienceStateChannel.Publish
    channel.CopyRecord = AudienceStateChannel.CopyRecord
    channel.IsVisible = AudienceStateChannel.IsVisible
    channel.ReadFor = AudienceStateChannel.ReadFor
    channel.ReadPayload = AudienceStateChannel.ReadPayload
    channel.Remove = AudienceStateChannel.Remove
    channel.ClearInstance = AudienceStateChannel.ClearInstance
    channel.GetSnapshot = AudienceStateChannel.GetSnapshot
    channel.Now = AudienceStateChannel.Now
    channel.GetDebugString = AudienceStateChannel.GetDebugString
    return channel
end

function AudienceStateChannel.New(options)
    options = type(options) == "table" and options or {}
    local max_payload_bytes = options.max_payload_bytes or AudienceStateChannel.MAX_PAYLOAD_BYTES
    if type(max_payload_bytes) ~= "number" or max_payload_bytes < 1 then
        max_payload_bytes = AudienceStateChannel.MAX_PAYLOAD_BYTES
    end
    return AttachMethods(
    {
        schema_version = AudienceStateChannel.SCHEMA_VERSION,
        max_payload_bytes = math.floor(max_payload_bytes),
        states_by_id = {},
        state_order = {},
        next_version = 0,
        now_fn = options.now_fn,
        resolve_instance_for_userid = options.resolve_instance_for_userid,
        resolve_groups_for_userid = options.resolve_groups_for_userid,
        resolve_spectating_instance_for_userid = options.resolve_spectating_instance_for_userid,
    })
end

return AudienceStateChannel
