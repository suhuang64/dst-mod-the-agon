-- WP5：只管理 Effect 生命周期和作用域，不定义任何具体玩法属性。

local EffectService = {}

EffectService.SCHEMA_VERSION = 1

EffectService.TARGETS =
{
    PARTICIPANT = "PARTICIPANT",
    GROUP = "GROUP",
    INSTANCE = "INSTANCE",
    ENTITY = "ENTITY",
}

EffectService.STACK_POLICIES =
{
    STACK = "STACK",
    REPLACE = "REPLACE",
    IGNORE = "IGNORE",
}

EffectService.ERROR_CODES =
{
    INVALID_EFFECT = "INVALID_EFFECT",
    INVALID_EFFECT_ID = "INVALID_EFFECT_ID",
    EFFECT_NOT_FOUND = "EFFECT_NOT_FOUND",
    EFFECT_CLOSED = "EFFECT_SERVICE_CLOSED",
    DUPLICATE_EFFECT = "DUPLICATE_EFFECT",
    INVALID_HANDLER = "INVALID_EFFECT_HANDLER",
    HANDLER_NOT_FOUND = "EFFECT_HANDLER_NOT_FOUND",
    HANDLER_FAILED = "EFFECT_HANDLER_FAILED",
    INVALID_SCOPE = "EFFECT_SCOPE_INVALID",
    INVALID_TARGET = "EFFECT_TARGET_INVALID",
    INSTANCE_MISMATCH = "EFFECT_INSTANCE_MISMATCH",
    INVALID_STACK_POLICY = "EFFECT_STACK_POLICY_INVALID",
    STALE_PHASE_REVISION = "EFFECT_STALE_PHASE_REVISION",
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

local function GetScope(self, requested_scope)
    local scope = requested_scope
    if scope == nil and self.phase_service ~= nil then
        scope = self.phase_service:GetCurrentScope()
    end
    if scope == nil then
        scope = self.instance.root_scope
    end
    if scope == nil or type(scope.IsOpen) ~= "function"
        or not scope:IsOpen()
        or scope.instance_id ~= self.instance.instance_id then
        return nil
    end
    return scope
end

local function GetTargetId(target_type, target, target_id, instance)
    if target_id == nil and target ~= nil then
        if target_type == EffectService.TARGETS.PARTICIPANT
            and type(target.GetUserid) == "function" then
            target_id = target:GetUserid()
        elseif target_type == EffectService.TARGETS.GROUP
            and type(target.GetId) == "function" then
            target_id = target:GetId()
        elseif target_type == EffectService.TARGETS.ENTITY then
            target_id = target.GUID ~= nil and tostring(target.GUID) or nil
        end
    end
    if target_type == EffectService.TARGETS.INSTANCE then
        target_id = instance.instance_id
    end
    return target_id
end

function EffectService.Get(self, effect_id)
    if not IsNonEmptyString(effect_id) then
        return nil
    end
    return self.effects_by_id[effect_id]
end

function EffectService.GetHandler(self, handler_id)
    if not IsNonEmptyString(handler_id) then
        return nil
    end
    return self.handlers_by_id[handler_id]
end

function EffectService.RegisterHandler(self, handler_id, handler, options)
    if self.closed then
        return false, EffectService.ERROR_CODES.EFFECT_CLOSED
    end
    if not IsNonEmptyString(handler_id)
        or type(handler) ~= "table"
        or type(handler.Apply) ~= "function"
        or type(handler.Remove) ~= "function" then
        return false, EffectService.ERROR_CODES.INVALID_HANDLER
    end
    if self.handlers_by_id[handler_id] ~= nil then
        return false, EffectService.ERROR_CODES.INVALID_HANDLER
    end
    options = type(options) == "table" and options or {}
    self.handlers_by_id[handler_id] =
    {
        handler_id = handler_id,
        handler_version = options.version or 1,
        handler = handler,
        metadata = CopyValue(options.metadata or {}),
    }
    table.insert(self.handler_order, handler_id)
    return true
end

local function RemoveRecord(self, effect_id, reason, skip_scope_release)
    local effect = self.effects_by_id[effect_id]
    if effect == nil then
        return false, EffectService.ERROR_CODES.EFFECT_NOT_FOUND
    end

    self.effects_by_id[effect_id] = nil
    for index = 1, #self.effect_order do
        if self.effect_order[index] == effect_id then
            table.remove(self.effect_order, index)
            break
        end
    end
    if self.stack_index[effect.stack_key] == effect_id then
        self.stack_index[effect.stack_key] = nil
    end
    local handler_record = self.handlers_by_id[effect.handler_id]
    local handler_ok = true
    if handler_record ~= nil and type(handler_record.handler.Remove) == "function" then
        local ok, result = pcall(
            handler_record.handler.Remove,
            handler_record.handler,
            effect,
            self,
            reason
        )
        handler_ok = ok and result ~= false
    end
    if not skip_scope_release and effect.scope ~= nil
        and effect.scope_resource_id ~= nil
        and type(effect.scope.ReleaseResource) == "function"
        and type(effect.scope.IsOpen) == "function"
        and effect.scope:IsOpen() then
        effect.scope:ReleaseResource(effect.scope_resource_id)
    end
    if not handler_ok then
        return false, EffectService.ERROR_CODES.HANDLER_FAILED
    end
    return true
end

function EffectService.Apply(self, effect_id, options)
    if self.closed then
        return nil, EffectService.ERROR_CODES.EFFECT_CLOSED
    end
    if not IsNonEmptyString(effect_id) then
        return nil, EffectService.ERROR_CODES.INVALID_EFFECT_ID
    end
    if self.effects_by_id[effect_id] ~= nil then
        return nil, EffectService.ERROR_CODES.DUPLICATE_EFFECT
    end
    options = type(options) == "table" and options or {}
    local handler_id = options.handler_id
    local handler_record = self.handlers_by_id[handler_id]
    if handler_record == nil then
        return nil, EffectService.ERROR_CODES.HANDLER_NOT_FOUND
    end
    if options.instance_id ~= nil and options.instance_id ~= self.instance.instance_id then
        return nil, EffectService.ERROR_CODES.INSTANCE_MISMATCH
    end
    if options.phase_revision ~= nil
        and self.phase_service ~= nil
        and self.phase_service:GetCurrentRevision() ~= options.phase_revision then
        return nil, EffectService.ERROR_CODES.STALE_PHASE_REVISION
    end

    local target_type = options.target_type or EffectService.TARGETS.INSTANCE
    if EffectService.TARGETS[target_type] ~= target_type then
        return nil, EffectService.ERROR_CODES.INVALID_TARGET
    end
    local target_id = GetTargetId(
        target_type,
        options.target,
        options.target_id,
        self.instance
    )
    if not IsNonEmptyString(target_id) then
        return nil, EffectService.ERROR_CODES.INVALID_TARGET
    end
    if target_type == EffectService.TARGETS.PARTICIPANT
        and self.instance:GetParticipant(target_id) == nil then
        return nil, EffectService.ERROR_CODES.INVALID_TARGET
    end
    if target_type == EffectService.TARGETS.GROUP
        and self.instance:GetGroup(target_id) == nil then
        return nil, EffectService.ERROR_CODES.INVALID_TARGET
    end

    local stack_policy = options.stack_policy or EffectService.STACK_POLICIES.STACK
    if EffectService.STACK_POLICIES[stack_policy] ~= stack_policy then
        return nil, EffectService.ERROR_CODES.INVALID_STACK_POLICY
    end
    local stack_key = options.stack_key
        or handler_id .. ":" .. target_type .. ":" .. target_id
    local existing_id = self.stack_index[stack_key]
    if existing_id ~= nil then
        if stack_policy == EffectService.STACK_POLICIES.IGNORE then
            return self:Get(existing_id), "ALREADY_ACTIVE"
        elseif stack_policy == EffectService.STACK_POLICIES.REPLACE then
            local replaced, replace_code = RemoveRecord(self, existing_id, "effect_replaced")
            if not replaced then
                return nil, replace_code
            end
        end
    end

    local scope = GetScope(self, options.scope)
    if scope == nil then
        return nil, EffectService.ERROR_CODES.INVALID_SCOPE
    end
    local effect =
    {
        schema_version = EffectService.SCHEMA_VERSION,
        effect_id = effect_id,
        instance_id = self.instance.instance_id,
        handler_id = handler_id,
        handler_version = handler_record.handler_version,
        source_id = options.source_id ~= nil and tostring(options.source_id) or nil,
        target_type = target_type,
        target_id = target_id,
        priority = options.priority or 0,
        stack_policy = stack_policy,
        stack_key = stack_key,
        scope = scope,
        scope_id = scope:GetId(),
        scope_generation = scope:GetGeneration(),
        scope_resource_id = nil,
        created_at = options.created_at ~= nil and options.created_at or self:Now(),
        metadata = CopyValue(options.metadata or {}),
    }
    self.effects_by_id[effect_id] = effect
    table.insert(self.effect_order, effect_id)
    self.stack_index[stack_key] = effect_id

    local resource_id, resource_code = scope:RegisterCleanup(
        function()
            RemoveRecord(self, effect_id, "scope_closed", true)
            return true
        end,
        nil,
        "effect:" .. effect_id
    )
    if resource_id == nil then
        RemoveRecord(self, effect_id, "effect_scope_registration_failed", true)
        return nil, resource_code or EffectService.ERROR_CODES.INVALID_SCOPE
    end
    effect.scope_resource_id = resource_id

    local ok, applied, apply_code = pcall(
        handler_record.handler.Apply,
        handler_record.handler,
        effect,
        self
    )
    if not ok or applied == false then
        RemoveRecord(self, effect_id, "effect_apply_failed", false)
        return nil, (not ok and EffectService.ERROR_CODES.HANDLER_FAILED)
            or apply_code
            or EffectService.ERROR_CODES.HANDLER_FAILED
    end
    return effect
end

function EffectService.Remove(self, effect_id, reason, skip_scope_release)
    return RemoveRecord(self, effect_id, reason or "effect_removed", skip_scope_release == true)
end

function EffectService.Count(self)
    return #self.effect_order
end

function EffectService.List(self)
    local effects = {}
    for index = 1, #self.effect_order do
        local effect = self.effects_by_id[self.effect_order[index]]
        if effect ~= nil then
            table.insert(effects, effect)
        end
    end
    return effects
end

function EffectService.Now(self)
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

function EffectService.Close(self, reason)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    for index = #self.effect_order, 1, -1 do
        local effect_id = self.effect_order[index]
        if self.effects_by_id[effect_id] ~= nil then
            RemoveRecord(self, effect_id, reason or "effect_service_closed", false)
        end
    end
    self.closed = true
    self.handlers_by_id = {}
    self.handler_order = {}
    self.stack_index = {}
    return true
end

function EffectService.GetSnapshot(self)
    local effects = {}
    for index = 1, #self.effect_order do
        local effect = self.effects_by_id[self.effect_order[index]]
        if effect ~= nil then
            table.insert(
                effects,
                {
                    schema_version = EffectService.SCHEMA_VERSION,
                    effect_id = effect.effect_id,
                    instance_id = effect.instance_id,
                    handler_id = effect.handler_id,
                    handler_version = effect.handler_version,
                    source_id = effect.source_id,
                    target_type = effect.target_type,
                    target_id = effect.target_id,
                    priority = effect.priority,
                    stack_policy = effect.stack_policy,
                    stack_key = effect.stack_key,
                    scope_id = effect.scope_id,
                    scope_generation = effect.scope_generation,
                    created_at = effect.created_at,
                    metadata = CopyValue(effect.metadata),
                }
            )
        end
    end
    return
    {
        schema_version = EffectService.SCHEMA_VERSION,
        instance_id = self.instance.instance_id,
        effects = effects,
    }
end

function EffectService.GetDebugString(self)
    return string.format(
        "effect_service handlers=%d effects=%d",
        #self.handler_order,
        #self.effect_order
    )
end

local function AttachMethods(service)
    service.Get = EffectService.Get
    service.GetHandler = EffectService.GetHandler
    service.RegisterHandler = EffectService.RegisterHandler
    service.Apply = EffectService.Apply
    service.Remove = EffectService.Remove
    service.Count = EffectService.Count
    service.List = EffectService.List
    service.Now = EffectService.Now
    service.Close = EffectService.Close
    service.GetSnapshot = EffectService.GetSnapshot
    service.GetDebugString = EffectService.GetDebugString
    return service
end

function EffectService.New(instance, services, options)
    if type(instance) ~= "table" or type(instance.instance_id) ~= "string" then
        return nil, EffectService.ERROR_CODES.INVALID_EFFECT
    end
    options = type(options) == "table" and options or {}
    return AttachMethods(
    {
        schema_version = EffectService.SCHEMA_VERSION,
        service_id = "effects",
        service_version = 1,
        instance = instance,
        services = services or {},
        phase_service = services ~= nil and services.phase or nil,
        now_fn = options.now_fn,
        handlers_by_id = {},
        handler_order = {},
        effects_by_id = {},
        effect_order = {},
        stack_index = {},
        closed = false,
    })
end

return EffectService
