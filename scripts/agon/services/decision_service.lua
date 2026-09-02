-- WP5：提供 Instance 内的投票、弃权、结果冻结和幂等 resolve。

local DecisionService = {}

DecisionService.SCHEMA_VERSION = 1
DecisionService.ABSTAIN = "ABSTAIN"

DecisionService.TYPES =
{
    PLAYER_PRIVATE = "PLAYER_PRIVATE",
    GROUP_VOTE = "GROUP_VOTE",
    GROUP_LEADER = "GROUP_LEADER",
    INSTANCE_VOTE = "INSTANCE_VOTE",
    SERVER_AUTO = "SERVER_AUTO",
}

DecisionService.STATES =
{
    OPEN = "OPEN",
    RESOLVED = "RESOLVED",
    CANCELLED = "CANCELLED",
}

DecisionService.AGGREGATIONS =
{
    PLURALITY_RANDOM_TIE = "PLURALITY_RANDOM_TIE",
}

DecisionService.ERROR_CODES =
{
    INVALID_DECISION = "INVALID_DECISION",
    INVALID_DECISION_ID = "INVALID_DECISION_ID",
    DUPLICATE_DECISION = "DUPLICATE_DECISION",
    DECISION_NOT_FOUND = "DECISION_NOT_FOUND",
    DECISION_CLOSED = "DECISION_CLOSED",
    INVALID_TYPE = "DECISION_TYPE_INVALID",
    INVALID_CANDIDATES = "DECISION_CANDIDATES_INVALID",
    INVALID_VOTER = "DECISION_VOTER_INVALID",
    VOTER_NOT_ELIGIBLE = "DECISION_VOTER_NOT_ELIGIBLE",
    INVALID_OPTION = "DECISION_OPTION_INVALID",
    DUPLICATE_VOTE = "DUPLICATE_VOTE",
    DUPLICATE_REQUEST = "DUPLICATE_VOTE_REQUEST",
    STALE_REVISION = "STALE_DECISION_REVISION",
    STALE_PHASE_REVISION = "DECISION_STALE_PHASE_REVISION",
    INVALID_GROUP = "DECISION_GROUP_INVALID",
    INVALID_DEADLINE = "DECISION_DEADLINE_INVALID",
    INVALID_SCOPE = "DECISION_SCOPE_INVALID",
    RNG_FAILED = "DECISION_RNG_FAILED",
    SERVICE_CLOSED = "DECISION_SERVICE_CLOSED",
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
    if self.instance ~= nil and type(self.instance.now_fn) == "function" then
        return self.instance.now_fn()
    end
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

local function GetPhaseRevision(self)
    if self.phase_service ~= nil
        and type(self.phase_service.GetCurrentRevision) == "function" then
        return self.phase_service:GetCurrentRevision()
    end
    return nil
end

local function GetPhaseScope(self)
    if self.phase_service ~= nil
        and type(self.phase_service.GetCurrentScope) == "function" then
        return self.phase_service:GetCurrentScope()
    end
    return nil
end

local function NormalizeCandidates(candidates)
    if type(candidates) ~= "table" or #candidates < 1 then
        return nil
    end
    local normalized = {}
    local seen = {}
    for index = 1, #candidates do
        local candidate = candidates[index]
        if not IsNonEmptyString(candidate) or seen[candidate] then
            return nil
        end
        seen[candidate] = true
        table.insert(normalized, candidate)
    end
    return normalized
end

local function GetUserid(participant)
    if participant == nil then
        return nil
    end
    if type(participant.GetUserid) == "function" then
        return participant:GetUserid()
    end
    return participant.userid
end

local function IsParticipantUsable(participant, instance_id)
    if participant == nil or participant.instance_id ~= instance_id then
        return false
    end
    if type(participant.IsActive) == "function" then
        return participant:IsActive()
    end
    return participant.state ~= "LEFT"
end

local function ResolveEligibleVoters(self, decision_type, options)
    local eligible = options.eligible_voters
    if eligible ~= nil then
        if type(eligible) ~= "table" then
            return nil, DecisionService.ERROR_CODES.INVALID_VOTER
        end
        local normalized = {}
        local seen = {}
        for index = 1, #eligible do
            local userid = eligible[index]
            if not IsNonEmptyString(userid) or seen[userid]
                or not IsParticipantUsable(
                    self.instance:GetParticipant(userid),
                    self.instance.instance_id
                ) then
                return nil, DecisionService.ERROR_CODES.INVALID_VOTER
            end
            seen[userid] = true
            table.insert(normalized, userid)
        end
        return normalized
    end

    if decision_type == DecisionService.TYPES.PLAYER_PRIVATE then
        if not IsNonEmptyString(options.userid)
            or not IsParticipantUsable(
                self.instance:GetParticipant(options.userid),
                self.instance.instance_id
            ) then
            return nil, DecisionService.ERROR_CODES.INVALID_VOTER
        end
        return { options.userid }
    elseif decision_type == DecisionService.TYPES.GROUP_VOTE
        or decision_type == DecisionService.TYPES.GROUP_LEADER then
        local group = self.instance:GetGroup(options.group_id)
        if group == nil or group:IsClosed() then
            return nil, DecisionService.ERROR_CODES.INVALID_GROUP
        end
        if decision_type == DecisionService.TYPES.GROUP_LEADER then
            local leader = group:GetLeaderUserid()
            return leader ~= nil and { leader } or {}, nil
        end
        return group:ListUserids(), nil
    elseif decision_type == DecisionService.TYPES.INSTANCE_VOTE then
        local participants = self.instance:ListParticipants()
        local normalized = {}
        for index = 1, #participants do
            local userid = GetUserid(participants[index])
            if IsParticipantUsable(participants[index], self.instance.instance_id) then
                table.insert(normalized, userid)
            end
        end
        return normalized, nil
    end
    return {}, nil
end

local function IsCandidate(self, decision, option_id)
    if option_id == DecisionService.ABSTAIN then
        return true
    end
    for index = 1, #decision.candidates do
        if decision.candidates[index] == option_id then
            return true
        end
    end
    return false
end

local function RemoveRecord(self, decision_id)
    if self.decisions_by_id[decision_id] == nil then
        return false, DecisionService.ERROR_CODES.DECISION_NOT_FOUND
    end
    self.decisions_by_id[decision_id] = nil
    for index = 1, #self.decision_order do
        if self.decision_order[index] == decision_id then
            table.remove(self.decision_order, index)
            break
        end
    end
    return true
end

function DecisionService.Get(self, decision_id)
    if not IsNonEmptyString(decision_id) then
        return nil
    end
    return self.decisions_by_id[decision_id]
end

function DecisionService.Create(self, options)
    if self.closed then
        return nil, DecisionService.ERROR_CODES.SERVICE_CLOSED
    end
    if type(options) ~= "table" then
        return nil, DecisionService.ERROR_CODES.INVALID_DECISION
    end
    local decision_id = options.decision_id
    if not IsNonEmptyString(decision_id) then
        return nil, DecisionService.ERROR_CODES.INVALID_DECISION_ID
    end
    if self.decisions_by_id[decision_id] ~= nil then
        return nil, DecisionService.ERROR_CODES.DUPLICATE_DECISION
    end

    local decision_type = options.decision_type or options.type
    if DecisionService.TYPES[decision_type] ~= decision_type then
        return nil, DecisionService.ERROR_CODES.INVALID_TYPE
    end
    local candidates = NormalizeCandidates(options.candidates)
    if candidates == nil then
        return nil, DecisionService.ERROR_CODES.INVALID_CANDIDATES
    end
    if options.deadline ~= nil and not IsFiniteNumber(options.deadline) then
        return nil, DecisionService.ERROR_CODES.INVALID_DEADLINE
    end
    if options.instance_id ~= nil and options.instance_id ~= self.instance.instance_id then
        return nil, DecisionService.ERROR_CODES.INVALID_DECISION
    end
    if (decision_type == DecisionService.TYPES.GROUP_VOTE
        or decision_type == DecisionService.TYPES.GROUP_LEADER)
        and (not IsNonEmptyString(options.group_id)
            or self.instance:GetGroup(options.group_id) == nil) then
        return nil, DecisionService.ERROR_CODES.INVALID_GROUP
    end

    local expected_phase_revision = options.phase_revision
    if expected_phase_revision ~= nil
        and GetPhaseRevision(self) ~= expected_phase_revision then
        return nil, DecisionService.ERROR_CODES.STALE_PHASE_REVISION
    end
    local eligible, eligible_code = ResolveEligibleVoters(self, decision_type, options)
    if eligible == nil then
        return nil, eligible_code
    end
    local aggregation = options.aggregation
        or DecisionService.AGGREGATIONS.PLURALITY_RANDOM_TIE
    if aggregation ~= DecisionService.AGGREGATIONS.PLURALITY_RANDOM_TIE then
        return nil, DecisionService.ERROR_CODES.INVALID_DECISION
    end

    local scope = options.scope or GetPhaseScope(self) or self.instance.root_scope
    if scope == nil or type(scope.IsOpen) ~= "function"
        or not scope:IsOpen()
        or scope.instance_id ~= self.instance.instance_id then
        return nil, DecisionService.ERROR_CODES.INVALID_SCOPE
    end

    local now = options.created_at ~= nil and options.created_at or GetNow(self)
    local decision =
    {
        schema_version = DecisionService.SCHEMA_VERSION,
        decision_id = decision_id,
        instance_id = self.instance.instance_id,
        decision_type = decision_type,
        group_id = options.group_id,
        userid = options.userid,
        candidates = candidates,
        eligible_voters = eligible,
        allow_change_vote = options.allow_change_vote == true,
        deadline = options.deadline,
        aggregation = aggregation,
        audience = CopyValue(options.audience),
        phase_revision = expected_phase_revision or GetPhaseRevision(self),
        state = DecisionService.STATES.OPEN,
        revision = 1,
        created_at = now,
        updated_at = now,
        votes_by_userid = {},
        vote_order = {},
        request_ids = {},
        result = nil,
        scope = scope,
        scope_id = scope:GetId(),
        scope_resource_id = nil,
    }
    self.decisions_by_id[decision_id] = decision
    table.insert(self.decision_order, decision_id)
    local resource_id, resource_code = scope:RegisterCleanup(
        function()
            RemoveRecord(self, decision_id)
            return true
        end,
        nil,
        "decision:" .. decision_id
    )
    if resource_id == nil then
        RemoveRecord(self, decision_id)
        return nil, resource_code or DecisionService.ERROR_CODES.INVALID_SCOPE
    end
    decision.scope_resource_id = resource_id
    return decision
end

function DecisionService.Vote(self, decision_id, userid, option_id, options)
    if self.closed then
        return false, DecisionService.ERROR_CODES.SERVICE_CLOSED
    end
    local decision = self:Get(decision_id)
    if decision == nil then
        return false, DecisionService.ERROR_CODES.DECISION_NOT_FOUND
    end
    if decision.state ~= DecisionService.STATES.OPEN then
        return false, DecisionService.ERROR_CODES.DECISION_CLOSED
    end
    if not IsNonEmptyString(userid) or not decision.eligible_voters[1] then
        return false, DecisionService.ERROR_CODES.INVALID_VOTER
    end
    local eligible = false
    for index = 1, #decision.eligible_voters do
        if decision.eligible_voters[index] == userid then
            eligible = true
            break
        end
    end
    if not eligible then
        return false, DecisionService.ERROR_CODES.VOTER_NOT_ELIGIBLE
    end
    if not IsNonEmptyString(option_id) or not IsCandidate(self, decision, option_id) then
        return false, DecisionService.ERROR_CODES.INVALID_OPTION
    end
    options = type(options) == "table" and options or {}
    if options.expected_revision ~= nil
        and options.expected_revision ~= decision.revision then
        return false, DecisionService.ERROR_CODES.STALE_REVISION
    end
    if options.phase_revision ~= nil
        and GetPhaseRevision(self) ~= options.phase_revision then
        return false, DecisionService.ERROR_CODES.STALE_PHASE_REVISION
    end
    local request_id = options.request_id
    if request_id ~= nil then
        if not IsNonEmptyString(request_id) then
            return false, DecisionService.ERROR_CODES.INVALID_DECISION
        end
        if decision.request_ids[request_id] then
            return false, DecisionService.ERROR_CODES.DUPLICATE_REQUEST
        end
    end
    if decision.votes_by_userid[userid] ~= nil and not decision.allow_change_vote then
        return false, DecisionService.ERROR_CODES.DUPLICATE_VOTE
    end
    if decision.votes_by_userid[userid] == nil then
        table.insert(decision.vote_order, userid)
    end
    decision.votes_by_userid[userid] = option_id
    if request_id ~= nil then
        decision.request_ids[request_id] = true
    end
    decision.revision = decision.revision + 1
    decision.updated_at = GetNow(self)
    return true
end

local function GetVoteCounts(decision)
    local counts = {}
    for index = 1, #decision.candidates do
        counts[decision.candidates[index]] = 0
    end
    for index = 1, #decision.vote_order do
        local option_id = decision.votes_by_userid[decision.vote_order[index]]
        if counts[option_id] ~= nil then
            counts[option_id] = counts[option_id] + 1
        end
    end
    return counts
end

function DecisionService.Resolve(self, decision_id, options)
    if self.closed then
        return false, nil, DecisionService.ERROR_CODES.SERVICE_CLOSED
    end
    local decision = self:Get(decision_id)
    if decision == nil then
        return false, nil, DecisionService.ERROR_CODES.DECISION_NOT_FOUND
    end
    if decision.state == DecisionService.STATES.RESOLVED then
        return true, CopyValue(decision.result), "ALREADY_RESOLVED"
    end
    if decision.state ~= DecisionService.STATES.OPEN then
        return false, nil, DecisionService.ERROR_CODES.DECISION_CLOSED
    end
    options = type(options) == "table" and options or {}
    if options.expected_revision ~= nil
        and options.expected_revision ~= decision.revision then
        return false, nil, DecisionService.ERROR_CODES.STALE_REVISION
    end
    if options.phase_revision ~= nil
        and GetPhaseRevision(self) ~= options.phase_revision then
        return false, nil, DecisionService.ERROR_CODES.STALE_PHASE_REVISION
    end

    local counts = GetVoteCounts(decision)
    local highest = -1
    for index = 1, #decision.candidates do
        local count = counts[decision.candidates[index]]
        if count > highest then
            highest = count
        end
    end
    local winners = {}
    for index = 1, #decision.candidates do
        local candidate = decision.candidates[index]
        if counts[candidate] == highest then
            table.insert(winners, candidate)
        end
    end
    if #winners == 0 then
        for index = 1, #decision.candidates do
            table.insert(winners, decision.candidates[index])
        end
    end

    local selected, selected_code
    if #winners == 1 then
        selected = winners[1]
    else
        selected, selected_code = self.instance:GetRng():Choice("decision", winners)
        if selected == nil then
            return false, nil, selected_code or DecisionService.ERROR_CODES.RNG_FAILED
        end
    end

    decision.result =
    {
        option_id = selected,
        counts = counts,
        winners = winners,
        resolved_at = GetNow(self),
        reason = options.reason ~= nil and tostring(options.reason) or nil,
    }
    decision.state = DecisionService.STATES.RESOLVED
    decision.revision = decision.revision + 1
    decision.updated_at = decision.result.resolved_at
    self.resolved_count = self.resolved_count + 1
    return true, CopyValue(decision.result)
end

function DecisionService.Cancel(self, decision_id, reason, skip_scope_release)
    local decision = self:Get(decision_id)
    if decision == nil then
        return false, DecisionService.ERROR_CODES.DECISION_NOT_FOUND
    end
    local removed, code = RemoveRecord(self, decision_id)
    if removed and not skip_scope_release
        and decision.scope ~= nil and decision.scope_resource_id ~= nil
        and type(decision.scope.IsOpen) == "function" and decision.scope:IsOpen() then
        decision.scope:ReleaseResource(decision.scope_resource_id)
    end
    return removed, code
end

function DecisionService.Count(self)
    return #self.decision_order
end

function DecisionService.List(self)
    local decisions = {}
    for index = 1, #self.decision_order do
        local decision = self.decisions_by_id[self.decision_order[index]]
        if decision ~= nil then
            table.insert(decisions, decision)
        end
    end
    return decisions
end

function DecisionService.Now(self)
    return GetNow(self)
end

function DecisionService.Close(self)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    for index = #self.decision_order, 1, -1 do
        local decision_id = self.decision_order[index]
        if self.decisions_by_id[decision_id] ~= nil then
            self:Cancel(decision_id, "decision_service_closed")
        end
    end
    self.closed = true
    return true
end

function DecisionService.GetSnapshot(self)
    local decisions = {}
    for index = 1, #self.decision_order do
        local decision = self.decisions_by_id[self.decision_order[index]]
        if decision ~= nil then
            local copied =
            {
                schema_version = DecisionService.SCHEMA_VERSION,
                decision_id = decision.decision_id,
                instance_id = decision.instance_id,
                decision_type = decision.decision_type,
                group_id = decision.group_id,
                userid = decision.userid,
                candidates = CopyValue(decision.candidates),
                eligible_voters = CopyValue(decision.eligible_voters),
                allow_change_vote = decision.allow_change_vote,
                deadline = decision.deadline,
                aggregation = decision.aggregation,
                audience = CopyValue(decision.audience),
                phase_revision = decision.phase_revision,
                state = decision.state,
                revision = decision.revision,
                created_at = decision.created_at,
                updated_at = decision.updated_at,
                votes = {},
                result = CopyValue(decision.result),
                scope_id = decision.scope_id,
            }
            for vote_index = 1, #decision.vote_order do
                local voter = decision.vote_order[vote_index]
                copied.votes[voter] = decision.votes_by_userid[voter]
            end
            table.insert(decisions, copied)
        end
    end
    return
    {
        schema_version = DecisionService.SCHEMA_VERSION,
        decisions = decisions,
    }
end

function DecisionService.GetDebugString(self)
    return string.format(
        "decision_service decisions=%d resolved=%d",
        #self.decision_order,
        self.resolved_count or 0
    )
end

local function AttachMethods(service)
    service.Get = DecisionService.Get
    service.Create = DecisionService.Create
    service.Vote = DecisionService.Vote
    service.Resolve = DecisionService.Resolve
    service.Cancel = DecisionService.Cancel
    service.Count = DecisionService.Count
    service.List = DecisionService.List
    service.Now = DecisionService.Now
    service.Close = DecisionService.Close
    service.GetSnapshot = DecisionService.GetSnapshot
    service.GetDebugString = DecisionService.GetDebugString
    return service
end

function DecisionService.New(instance, services, options)
    if type(instance) ~= "table" or type(instance.instance_id) ~= "string"
        or type(instance.GetGroup) ~= "function" then
        return nil, DecisionService.ERROR_CODES.INVALID_DECISION
    end
    options = type(options) == "table" and options or {}
    return AttachMethods(
    {
        schema_version = DecisionService.SCHEMA_VERSION,
        service_id = "decision",
        service_version = 1,
        instance = instance,
        services = services or {},
        phase_service = services ~= nil and services.phase or nil,
        now_fn = options.now_fn,
        decisions_by_id = {},
        decision_order = {},
        resolved_count = 0,
        closed = false,
    })
end

return DecisionService
