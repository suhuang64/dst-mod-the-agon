-- WP5：Instance 内的通用 Participant 分组，不写死具体玩法队伍语义。

local ParticipantGroup = {}

ParticipantGroup.SCHEMA_VERSION = 1

ParticipantGroup.STATES =
{
    ACTIVE = "ACTIVE",
    CLOSED = "CLOSED",
}

ParticipantGroup.ERROR_CODES =
{
    INVALID_GROUP = "INVALID_GROUP",
    INVALID_GROUP_ID = "INVALID_GROUP_ID",
    INVALID_GROUP_TYPE = "INVALID_GROUP_TYPE",
    GROUP_CLOSED = "GROUP_CLOSED",
    PARTICIPANT_NOT_FOUND = "GROUP_PARTICIPANT_NOT_FOUND",
    PARTICIPANT_INSTANCE_MISMATCH = "GROUP_PARTICIPANT_INSTANCE_MISMATCH",
    PARTICIPANT_LEFT = "GROUP_PARTICIPANT_LEFT",
    MEMBER_ALREADY_EXISTS = "GROUP_MEMBER_ALREADY_EXISTS",
    MEMBER_NOT_FOUND = "GROUP_MEMBER_NOT_FOUND",
    INVALID_METADATA = "GROUP_INVALID_METADATA",
    INVALID_LEADER = "GROUP_INVALID_LEADER",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function CopySerializable(value, seen)
    local value_type = type(value)
    if value == nil or value_type == "boolean" or value_type == "string" then
        return value
    end
    if value_type == "number" then
        if IsFiniteNumber(value) then
            return value
        end
        return nil, true
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

local function GetInstanceId(instance)
    if instance == nil then
        return nil
    end
    if type(instance.GetId) == "function" then
        return instance:GetId()
    end
    return instance.instance_id
end

local function GetParticipantUserid(participant)
    if participant == nil then
        return nil
    end
    if type(participant.GetUserid) == "function" then
        return participant:GetUserid()
    end
    return participant.userid
end

local function GetParticipantInstanceId(participant)
    if participant == nil then
        return nil
    end
    if type(participant.GetInstanceId) == "function" then
        return participant:GetInstanceId()
    end
    return participant.instance_id
end

local function IsParticipantLeft(participant)
    if participant == nil then
        return true
    end
    if type(participant.IsActive) == "function" then
        return not participant:IsActive()
    end
    return participant.state == "LEFT"
end

local function ResolveParticipant(self, member)
    if type(member) == "string" then
        if self.instance ~= nil and type(self.instance.GetParticipant) == "function" then
            return self.instance:GetParticipant(member)
        end
        return nil
    end
    if type(member) == "table" then
        return member
    end
    return nil
end

function ParticipantGroup.GetId(self)
    return self.group_id
end

function ParticipantGroup.GetInstanceId(self)
    return self.instance_id
end

function ParticipantGroup.GetType(self)
    return self.group_type
end

function ParticipantGroup.GetState(self)
    return self.state
end

function ParticipantGroup.GetGeneration(self)
    return self.generation
end

function ParticipantGroup.IsClosed(self)
    return self.state == ParticipantGroup.STATES.CLOSED
end

function ParticipantGroup.HasMember(self, userid)
    return IsNonEmptyString(userid) and self.members_by_userid[userid] ~= nil
end

function ParticipantGroup.AddMember(self, member)
    if self:IsClosed() then
        return false, ParticipantGroup.ERROR_CODES.GROUP_CLOSED
    end

    local participant = ResolveParticipant(self, member)
    local userid = GetParticipantUserid(participant)
    if not IsNonEmptyString(userid) then
        return false, ParticipantGroup.ERROR_CODES.PARTICIPANT_NOT_FOUND
    end
    if GetParticipantInstanceId(participant) ~= self.instance_id then
        return false, ParticipantGroup.ERROR_CODES.PARTICIPANT_INSTANCE_MISMATCH
    end
    if IsParticipantLeft(participant) then
        return false, ParticipantGroup.ERROR_CODES.PARTICIPANT_LEFT
    end
    if self.members_by_userid[userid] ~= nil then
        return false, ParticipantGroup.ERROR_CODES.MEMBER_ALREADY_EXISTS
    end

    self.members_by_userid[userid] = participant
    table.insert(self.member_order, userid)
    if type(participant.AddGroupId) == "function" then
        local added, add_code = participant:AddGroupId(self.group_id)
        if not added then
            self.members_by_userid[userid] = nil
            table.remove(self.member_order)
            return false, add_code or ParticipantGroup.ERROR_CODES.INVALID_GROUP
        end
    end
    self.revision = self.revision + 1
    if self.leader_userid == nil then
        self.leader_userid = userid
    end
    return true
end

function ParticipantGroup.RemoveMember(self, userid)
    if self:IsClosed() then
        return false, ParticipantGroup.ERROR_CODES.GROUP_CLOSED
    end
    if not self:HasMember(userid) then
        return false, ParticipantGroup.ERROR_CODES.MEMBER_NOT_FOUND
    end

    local participant = self.members_by_userid[userid]
    self.members_by_userid[userid] = nil
    for index = 1, #self.member_order do
        if self.member_order[index] == userid then
            table.remove(self.member_order, index)
            break
        end
    end
    if participant ~= nil and type(participant.RemoveGroupId) == "function" then
        participant:RemoveGroupId(self.group_id)
    end
    if self.leader_userid == userid then
        self.leader_userid = self.member_order[1]
    end
    self.revision = self.revision + 1
    return true
end

function ParticipantGroup.SetLeader(self, userid)
    if self:IsClosed() then
        return false, ParticipantGroup.ERROR_CODES.GROUP_CLOSED
    end
    if not self:HasMember(userid) then
        return false, ParticipantGroup.ERROR_CODES.INVALID_LEADER
    end
    self.leader_userid = userid
    self.revision = self.revision + 1
    return true
end

function ParticipantGroup.GetLeaderUserid(self)
    return self.leader_userid
end

function ParticipantGroup.GetLeader(self)
    if self.leader_userid == nil then
        return nil
    end
    return self.members_by_userid[self.leader_userid]
end

function ParticipantGroup.GetMember(self, userid)
    if not IsNonEmptyString(userid) then
        return nil
    end
    return self.members_by_userid[userid]
end

function ParticipantGroup.ListUserids(self)
    local userids = {}
    for index = 1, #self.member_order do
        if self.members_by_userid[self.member_order[index]] ~= nil then
            table.insert(userids, self.member_order[index])
        end
    end
    return userids
end

function ParticipantGroup.ListMembers(self)
    local members = {}
    for index = 1, #self.member_order do
        local participant = self.members_by_userid[self.member_order[index]]
        if participant ~= nil then
            table.insert(members, participant)
        end
    end
    return members
end

function ParticipantGroup.GetMetadata(self)
    return CopySerializable(self.metadata)
end

function ParticipantGroup.Close(self, reason)
    if self:IsClosed() then
        return true, "ALREADY_CLOSED"
    end
    local userids = self:ListUserids()
    for index = #userids, 1, -1 do
        self:RemoveMember(userids[index])
    end
    self.state = ParticipantGroup.STATES.CLOSED
    self.close_reason = reason ~= nil and tostring(reason) or nil
    self.revision = self.revision + 1
    return true
end

function ParticipantGroup.GetSnapshot(self)
    return
    {
        schema_version = ParticipantGroup.SCHEMA_VERSION,
        group_id = self.group_id,
        instance_id = self.instance_id,
        group_type = self.group_type,
        state = self.state,
        generation = self.generation,
        revision = self.revision,
        leader_userid = self.leader_userid,
        members = self:ListUserids(),
        metadata = CopySerializable(self.metadata),
        close_reason = self.close_reason,
    }
end

function ParticipantGroup.GetDebugString(self)
    return string.format(
        "group_id=%s instance_id=%s type=%s state=%s revision=%d members=%d leader=%s",
        tostring(self.group_id),
        tostring(self.instance_id),
        tostring(self.group_type),
        tostring(self.state),
        self.revision,
        #self.member_order,
        tostring(self.leader_userid)
    )
end

local function AttachMethods(group)
    group.GetId = ParticipantGroup.GetId
    group.GetInstanceId = ParticipantGroup.GetInstanceId
    group.GetType = ParticipantGroup.GetType
    group.GetState = ParticipantGroup.GetState
    group.GetGeneration = ParticipantGroup.GetGeneration
    group.IsClosed = ParticipantGroup.IsClosed
    group.HasMember = ParticipantGroup.HasMember
    group.AddMember = ParticipantGroup.AddMember
    group.RemoveMember = ParticipantGroup.RemoveMember
    group.SetLeader = ParticipantGroup.SetLeader
    group.GetLeaderUserid = ParticipantGroup.GetLeaderUserid
    group.GetLeader = ParticipantGroup.GetLeader
    group.GetMember = ParticipantGroup.GetMember
    group.ListUserids = ParticipantGroup.ListUserids
    group.ListMembers = ParticipantGroup.ListMembers
    group.GetMetadata = ParticipantGroup.GetMetadata
    group.Close = ParticipantGroup.Close
    group.GetSnapshot = ParticipantGroup.GetSnapshot
    group.GetDebugString = ParticipantGroup.GetDebugString
    return group
end

function ParticipantGroup.New(instance, group_id, group_type, options)
    local instance_id = GetInstanceId(instance)
    if instance == nil or not IsNonEmptyString(instance_id) then
        return nil, ParticipantGroup.ERROR_CODES.INVALID_GROUP
    end
    if not IsNonEmptyString(group_id) then
        return nil, ParticipantGroup.ERROR_CODES.INVALID_GROUP_ID
    end
    if not IsNonEmptyString(group_type) then
        return nil, ParticipantGroup.ERROR_CODES.INVALID_GROUP_TYPE
    end

    options = type(options) == "table" and options or {}
    local metadata = options.metadata
    if metadata == nil then
        metadata = {}
    end
    if type(metadata) ~= "table" then
        return nil, ParticipantGroup.ERROR_CODES.INVALID_METADATA
    end
    local copied_metadata, metadata_invalid = CopySerializable(metadata)
    if metadata_invalid then
        return nil, ParticipantGroup.ERROR_CODES.INVALID_METADATA
    end

    local generation = options.generation or 1
    if type(generation) ~= "number" or generation < 1 or generation ~= math.floor(generation) then
        return nil, ParticipantGroup.ERROR_CODES.INVALID_GROUP
    end

    local group = AttachMethods(
    {
        schema_version = ParticipantGroup.SCHEMA_VERSION,
        group_id = group_id,
        instance_id = instance_id,
        group_type = group_type,
        state = ParticipantGroup.STATES.ACTIVE,
        generation = generation,
        revision = 0,
        instance = instance,
        members_by_userid = {},
        member_order = {},
        leader_userid = nil,
        metadata = copied_metadata,
        close_reason = nil,
    })

    local members = options.members or {}
    if type(members) ~= "table" then
        return nil, ParticipantGroup.ERROR_CODES.INVALID_GROUP
    end
    for index = 1, #members do
        local added, add_code = group:AddMember(members[index])
        if not added then
            group:Close("group_create_failed")
            return nil, add_code
        end
    end
    if options.leader_userid ~= nil then
        local leader_set, leader_code = group:SetLeader(options.leader_userid)
        if not leader_set then
            group:Close("group_create_failed")
            return nil, leader_code
        end
    end
    return group
end

return ParticipantGroup
