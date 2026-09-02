-- WP4：The Agon Client -> Server RPC 的统一授权、幂等和速率边界。

local Diagnostics = require("agon/debug/diagnostics")

local Rpc = {}

Rpc.SCHEMA_VERSION = 1
Rpc.NAMESPACE = "AGON"
Rpc.REQUEST_NAME = "request"
Rpc.DEFAULT_WINDOW_SECONDS = 1
Rpc.DEFAULT_MAX_REQUESTS = 20
Rpc.MAX_REQUEST_ID_LENGTH = 96

Rpc.ERROR_CODES =
{
    INVALID_REQUEST = "RPC_INVALID_REQUEST",
    INVALID_SENDER = "RPC_INVALID_SENDER",
    SENDER_USERID_MISMATCH = "RPC_SENDER_USERID_MISMATCH",
    INSTANCE_NOT_FOUND = "RPC_INSTANCE_NOT_FOUND",
    PARTICIPANT_NOT_FOUND = "RPC_PARTICIPANT_NOT_FOUND",
    LIFECYCLE_FORBIDDEN = "RPC_LIFECYCLE_FORBIDDEN",
    GENERATION_STALE = "RPC_GENERATION_STALE",
    SCENE_REVISION_STALE = "RPC_SCENE_REVISION_STALE",
    OWNERSHIP_FORBIDDEN = "RPC_OWNERSHIP_FORBIDDEN",
    DUPLICATE_REQUEST = "RPC_DUPLICATE_REQUEST",
    RATE_LIMITED = "RPC_RATE_LIMITED",
    DISPATCH_FAILED = "RPC_DISPATCH_FAILED",
    NOT_REGISTERED = "RPC_NOT_REGISTERED",
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

local function IsPositiveInteger(value)
    return IsInteger(value) and value >= 1
end

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
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

local function GetSenderUserid(sender)
    if type(sender) == "table" and IsNonEmptyString(sender.userid) then
        return sender.userid
    end
    return nil
end

local function IsValidSender(sender)
    if type(sender) ~= "table" then
        return false
    end
    if type(sender.IsValid) == "function" then
        local ok, valid = ProtectedCall(sender.IsValid, sender)
        return ok and valid == true
    end
    return IsNonEmptyString(sender.userid)
end

local function GetEntityByGuid(guid)
    if not IsNonEmptyString(guid) or type(Ents) ~= "table" then
        return nil
    end
    local entity = Ents[guid]
    if entity ~= nil then
        return entity
    end
    local numeric_guid = tonumber(guid)
    return numeric_guid ~= nil and Ents[numeric_guid] or nil
end

local function IsAllowedLifecycle(instance, request)
    if request.allowed_lifecycle ~= nil then
        return instance.lifecycle_state == request.allowed_lifecycle
    end
    return instance.lifecycle_state == "RUNNING"
end

function Rpc.GetInstance(self, instance_id)
    if self.instance_manager == nil
        or type(self.instance_manager.Get) ~= "function" then
        return nil
    end
    return self.instance_manager:Get(instance_id)
end

function Rpc.IsDuplicate(self, userid, request_id)
    local requests = self.seen_requests[userid]
    return requests ~= nil
        and requests.by_id ~= nil
        and requests.by_id[request_id] ~= nil
end

function Rpc.RememberRequest(self, userid, request_id, timestamp)
    local requests = self.seen_requests[userid]
    if requests == nil then
        requests = { order = {}, by_id = {} }
        self.seen_requests[userid] = requests
    end
    if requests.by_id[request_id] == nil then
        table.insert(requests.order, request_id)
    end
    requests.by_id[request_id] = timestamp
    while #requests.order > self.max_remembered_requests do
        local expired_id = table.remove(requests.order, 1)
        requests.by_id[expired_id] = nil
    end
end

function Rpc.CheckRate(self, userid, now)
    local bucket = self.rate_buckets[userid]
    if bucket == nil or now >= bucket.started_at + self.window_seconds then
        bucket = { started_at = now, count = 0 }
        self.rate_buckets[userid] = bucket
    end
    if bucket.count >= self.max_requests_per_window then
        return false
    end
    bucket.count = bucket.count + 1
    return true
end

function Rpc.ResolveTarget(self, request)
    if request.target ~= nil then
        return request.target
    end
    return GetEntityByGuid(request.target_guid)
end

function Rpc.ValidateRequest(self, sender, request)
    if not IsValidSender(sender) then
        return false, Rpc.ERROR_CODES.INVALID_SENDER
    end
    if type(request) ~= "table"
        or not IsNonEmptyString(request.instance_id)
        or not IsPositiveInteger(request.generation)
        or not IsInteger(request.scene_revision)
        or request.scene_revision < 0
        or not IsNonEmptyString(request.request_id)
        or #request.request_id > Rpc.MAX_REQUEST_ID_LENGTH
        or not IsNonEmptyString(request.action) then
        return false, Rpc.ERROR_CODES.INVALID_REQUEST
    end

    local userid = GetSenderUserid(sender)
    if userid == nil then
        return false, Rpc.ERROR_CODES.INVALID_SENDER
    end
    if request.userid ~= nil and request.userid ~= userid then
        return false, Rpc.ERROR_CODES.SENDER_USERID_MISMATCH
    end
    if self:IsDuplicate(userid, request.request_id) then
        return false, Rpc.ERROR_CODES.DUPLICATE_REQUEST
    end
    local now = GetNow(self)
    if not self:CheckRate(userid, now) then
        return false, Rpc.ERROR_CODES.RATE_LIMITED
    end

    local instance = self:GetInstance(request.instance_id)
    if instance == nil then
        return false, Rpc.ERROR_CODES.INSTANCE_NOT_FOUND
    end
    if not IsAllowedLifecycle(instance, request) then
        return false, Rpc.ERROR_CODES.LIFECYCLE_FORBIDDEN
    end
    if instance.generation ~= request.generation then
        return false, Rpc.ERROR_CODES.GENERATION_STALE
    end
    if instance.scene_revision ~= request.scene_revision then
        return false, Rpc.ERROR_CODES.SCENE_REVISION_STALE
    end

    local participant = type(self.instance_manager.GetParticipant) == "function"
        and self.instance_manager:GetParticipant(userid)
        or nil
    if participant == nil or participant.instance_id ~= instance.instance_id
        or not participant:IsActive() then
        return false, Rpc.ERROR_CODES.PARTICIPANT_NOT_FOUND
    end

    local target = self:ResolveTarget(request)
    if target ~= nil then
        local allowed, ownership_code = self.rule_policy:CanInteract(
            request.action,
            sender,
            target,
            { instance_id = instance.instance_id }
        )
        if not allowed then
            return false, ownership_code or Rpc.ERROR_CODES.OWNERSHIP_FORBIDDEN
        end
    else
        local sender_instance_id = self.rule_policy:ResolveInstance(sender)
        if sender_instance_id ~= instance.instance_id then
            return false, Rpc.ERROR_CODES.OWNERSHIP_FORBIDDEN
        end
    end

    return true, nil,
        {
            userid = userid,
            instance = instance,
            participant = participant,
            target = target,
            now = now,
        }
end

function Rpc.Handle(self, sender, request)
    local valid, code, context = self:ValidateRequest(sender, request)
    if not valid then
        return false, code
    end

    if type(self.dispatch_fn) == "function" then
        local ok, result, dispatch_code = ProtectedCall(
            self.dispatch_fn,
            context,
            request
        )
        if not ok or result == false then
            return false, dispatch_code or Rpc.ERROR_CODES.DISPATCH_FAILED
        end
    end

    self:RememberRequest(context.userid, request.request_id, context.now)
    return true, nil, context
end

function Rpc.GetSnapshot(self)
    local seen_requests = {}
    for userid, requests in pairs(self.seen_requests) do
        seen_requests[userid] = {}
        for index = 1, #requests.order do
            local request_id = requests.order[index]
            table.insert(seen_requests[userid],
            {
                request_id = request_id,
                timestamp = requests.by_id[request_id],
            })
        end
    end
    return
    {
        schema_version = Rpc.SCHEMA_VERSION,
        window_seconds = self.window_seconds,
        max_requests_per_window = self.max_requests_per_window,
        seen_requests = seen_requests,
    }
end

function Rpc.GetDebugString(self)
    local rate_user_count = 0
    for _ in pairs(self.rate_buckets) do
        rate_user_count = rate_user_count + 1
    end
    return string.format(
        "rpc namespace=%s rate_users=%d remembered_users=%d",
        Rpc.NAMESPACE,
        rate_user_count,
        (function()
            local count = 0
            for _ in pairs(self.seen_requests) do
                count = count + 1
            end
            return count
        end)()
    )
end

local function AttachMethods(rpc)
    rpc.GetInstance = Rpc.GetInstance
    rpc.IsDuplicate = Rpc.IsDuplicate
    rpc.RememberRequest = Rpc.RememberRequest
    rpc.CheckRate = Rpc.CheckRate
    rpc.ResolveTarget = Rpc.ResolveTarget
    rpc.ValidateRequest = Rpc.ValidateRequest
    rpc.Handle = Rpc.Handle
    rpc.GetSnapshot = Rpc.GetSnapshot
    rpc.GetDebugString = Rpc.GetDebugString
    return rpc
end

function Rpc.New(options)
    options = type(options) == "table" and options or {}
    if type(options.instance_manager) ~= "table"
        or type(options.rule_policy) ~= "table" then
        return nil, Rpc.ERROR_CODES.INVALID_REQUEST
    end
    local window_seconds = options.window_seconds or Rpc.DEFAULT_WINDOW_SECONDS
    local max_requests = options.max_requests_per_window or Rpc.DEFAULT_MAX_REQUESTS
    if not IsFiniteNumber(window_seconds) or window_seconds <= 0
        or not IsPositiveInteger(max_requests) then
        return nil, Rpc.ERROR_CODES.INVALID_REQUEST
    end
    return AttachMethods(
    {
        schema_version = Rpc.SCHEMA_VERSION,
        runtime = options.runtime,
        instance_manager = options.instance_manager,
        rule_policy = options.rule_policy,
        now_fn = options.now_fn,
        window_seconds = window_seconds,
        max_requests_per_window = max_requests,
        max_remembered_requests = options.max_remembered_requests or 128,
        rate_buckets = {},
        seen_requests = {},
        dispatch_fn = options.dispatch_fn,
    })
end

local registered = false

function Rpc.Register()
    if registered then
        return true
    end
    if type(AddModRPCHandler) ~= "function" then
        return false, Rpc.ERROR_CODES.NOT_REGISTERED
    end

    AddModRPCHandler(Rpc.NAMESPACE, Rpc.REQUEST_NAME,
    function(sender, instance_id, generation, scene_revision, request_id, action, target_guid)
        local world
        if type(GLOBAL) == "table" then
            world = GLOBAL.TheWorld
        else
            world = TheWorld
        end
        local runtime = world ~= nil
            and world.components ~= nil
            and world.components.agon_runtime
            or nil
        if runtime == nil or runtime.rpc == nil then
            Diagnostics.Log(
                Diagnostics.ERROR_CODES.CORE_NOT_READY,
                { operation = "rpc_request" },
                "Agon runtime is not available for RPC"
            )
            return
        end
        local accepted, code = runtime.rpc:Handle(sender,
        {
            instance_id = instance_id,
            generation = generation,
            scene_revision = scene_revision,
            request_id = request_id,
            action = action,
            target_guid = target_guid,
        })
        if not accepted then
            Diagnostics.Log(
                code,
                {
                    operation = "rpc_request",
                    instance_id = instance_id,
                    userid = sender ~= nil and sender.userid or nil,
                    generation = generation,
                    scene_revision = scene_revision,
                },
                "Agon RPC request rejected"
            )
        end
    end)
    registered = true
    return true
end

function Rpc.SendRequest(instance_id, generation, scene_revision, request_id, action, target_guid)
    if type(SendModRPCToServer) ~= "function"
        or type(GetModRPC) ~= "function" then
        return false, Rpc.ERROR_CODES.NOT_REGISTERED
    end
    local request_rpc = GetModRPC(Rpc.NAMESPACE, Rpc.REQUEST_NAME)
    if request_rpc == nil then
        return false, Rpc.ERROR_CODES.NOT_REGISTERED
    end
    SendModRPCToServer(
        request_rpc,
        instance_id,
        generation,
        scene_revision,
        request_id,
        action,
        target_guid
    )
    return true
end

return Rpc
