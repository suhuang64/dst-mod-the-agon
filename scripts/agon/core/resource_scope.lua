-- WP3：统一管理 Instance 内的任务、监听器、实体和清理回调。

local ResourceScope = {}
ResourceScope.SCHEMA_VERSION = 1

ResourceScope.STATES =
{
    OPEN = "OPEN",
    CLOSING = "CLOSING",
    CLOSED = "CLOSED",
}

ResourceScope.POLICIES =
{
    DESTROY = "DESTROY",
    RETAIN_IN_PARENT_SCOPE = "RETAIN_IN_PARENT_SCOPE",
    TRANSFER_TO_SCOPE = "TRANSFER_TO_SCOPE",
    MODE_RESOLVE = "MODE_RESOLVE",
}

ResourceScope.ERROR_CODES =
{
    INVALID_SCOPE = "INVALID_SCOPE",
    SCOPE_CLOSED = "SCOPE_CLOSED",
    SCOPE_INSTANCE_MISMATCH = "SCOPE_INSTANCE_MISMATCH",
    SCOPE_TRANSFER_INVALID = "SCOPE_TRANSFER_INVALID",
    SCOPE_RESOURCE_INVALID = "SCOPE_RESOURCE_INVALID",
    RESOURCE_CLEANUP_FAILED = "RESOURCE_CLEANUP_FAILED",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsInteger(value)
    return type(value) == "number" and value == math.floor(value)
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

local function NormalizePolicy(policy)
    if policy == nil then
        return ResourceScope.POLICIES.DESTROY
    end
    if ResourceScope.POLICIES[policy] == policy then
        return policy
    end
    return nil
end

local function IsOpen(self)
    return self.state == ResourceScope.STATES.OPEN
end

local function RemoveResourceFromOrder(self, resource_id)
    for index = 1, #self.resource_order do
        if self.resource_order[index] == resource_id then
            table.remove(self.resource_order, index)
            return
        end
    end
end

local function AdoptResource(self, resource)
    self.next_resource_id = self.next_resource_id + 1
    resource.id = self.next_resource_id
    resource.scope_id = self.scope_id
    resource.cleanup_policy = ResourceScope.POLICIES.DESTROY
    self.resources_by_id[resource.id] = resource
    table.insert(self.resource_order, resource.id)
    return resource.id
end

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function DestroyResource(self, resource)
    if resource == nil then
        return true
    end

    if resource.kind == "task" then
        local task = resource.handle
        if task ~= nil and type(task.Cancel) == "function" then
            local ok = ProtectedCall(task.Cancel, task)
            return ok
        end
        return true
    elseif resource.kind == "event" then
        local listener = resource.listener
        if listener ~= nil and type(listener.RemoveEventCallback) == "function" then
            local ok = ProtectedCall(
                listener.RemoveEventCallback,
                listener,
                resource.event,
                resource.callback,
                resource.source
            )
            return ok
        end
        return true
    elseif resource.kind == "entity" then
        local entity = resource.entity
        if entity == nil or type(entity.IsValid) ~= "function" then
            return true
        end
        local valid_ok, valid = ProtectedCall(entity.IsValid, entity)
        if not valid_ok or not valid then
            return true
        end
        if type(entity.Remove) ~= "function" then
            return false
        end
        local remove_ok = ProtectedCall(entity.Remove, entity)
        return remove_ok
    elseif resource.kind == "cleanup" then
        if type(resource.callback) ~= "function" then
            return true
        end
        local ok, result = ProtectedCall(resource.callback, resource)
        return ok and result ~= false
    end

    if type(resource.callback) == "function" then
        local ok, result = ProtectedCall(resource.callback, resource)
        return ok and result ~= false
    end
    return true
end

local function TransferResource(self, resource, target_scope)
    if target_scope == nil
        or target_scope.instance_id ~= self.instance_id
        or not IsOpen(target_scope)
        or target_scope == self then
        return false, ResourceScope.ERROR_CODES.SCOPE_TRANSFER_INVALID
    end

    self.resources_by_id[resource.id] = nil
    RemoveResourceFromOrder(self, resource.id)
    AdoptResource(target_scope, resource)
    return true
end

function ResourceScope.GetId(self)
    return self.scope_id
end

function ResourceScope.GetInstanceId(self)
    return self.instance_id
end

function ResourceScope.GetParent(self)
    return self.parent
end

function ResourceScope.GetGeneration(self)
    return self.generation
end

function ResourceScope.GetState(self)
    return self.state
end

function ResourceScope.IsOpen(self)
    return IsOpen(self)
end

function ResourceScope.IsClosed(self)
    return self.state == ResourceScope.STATES.CLOSED
end

function ResourceScope.IsGenerationCurrent(self, generation)
    return IsOpen(self) and generation == self.generation
end

function ResourceScope.CreateChild(self, name)
    if not IsOpen(self) then
        return nil, ResourceScope.ERROR_CODES.SCOPE_CLOSED
    end
    if not IsNonEmptyString(name) then
        return nil, ResourceScope.ERROR_CODES.INVALID_SCOPE
    end

    self.next_child_sequence = self.next_child_sequence + 1
    local child_id = self.scope_id .. ":" .. name .. ":" .. tostring(self.next_child_sequence)
    local child = ResourceScope.New(
    {
        instance_id = self.instance_id,
        scope_id = child_id,
        parent = self,
    })
    if child == nil then
        return nil, ResourceScope.ERROR_CODES.INVALID_SCOPE
    end
    self.children_by_id[child_id] = child
    table.insert(self.child_order, child_id)
    return child
end

function ResourceScope.Register(self, kind, options)
    if not IsOpen(self) then
        return nil, ResourceScope.ERROR_CODES.SCOPE_CLOSED
    end
    if not IsNonEmptyString(kind) or type(options) ~= "table" then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end

    local policy = NormalizePolicy(options.cleanup_policy)
    if policy == nil then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end

    self.next_resource_id = self.next_resource_id + 1
    local resource =
    {
        id = self.next_resource_id,
        kind = kind,
        scope_id = self.scope_id,
        cleanup_policy = policy,
        label = options.label,
        handle = options.handle,
        entity = options.entity,
        listener = options.listener,
        source = options.source,
        event = options.event,
        callback = options.callback,
        resolver = options.resolver,
        target_scope = options.target_scope,
        metadata = CopyValue(options.metadata),
    }
    self.resources_by_id[resource.id] = resource
    table.insert(self.resource_order, resource.id)
    return resource.id
end

function ResourceScope.RegisterTask(self, task, cleanup_policy, label)
    if task == nil then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    return self:Register(
        "task",
        {
            handle = task,
            cleanup_policy = cleanup_policy,
            label = label,
        }
    )
end

function ResourceScope.RegisterEvent(self, listener, event, callback, source, cleanup_policy, label)
    if listener == nil or not IsNonEmptyString(event) or type(callback) ~= "function"
        or type(listener.RemoveEventCallback) ~= "function" then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    return self:Register(
        "event",
        {
            listener = listener,
            event = event,
            callback = callback,
            source = source or listener,
            cleanup_policy = cleanup_policy,
            label = label,
        }
    )
end

function ResourceScope.RegisterEntity(self, entity, cleanup_policy, label, metadata)
    if entity == nil then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    return self:Register(
        "entity",
        {
            entity = entity,
            cleanup_policy = cleanup_policy,
            label = label,
            metadata = metadata,
        }
    )
end

function ResourceScope.RegisterCleanup(self, callback, cleanup_policy, label, target_scope, resolver)
    if type(callback) ~= "function" then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    return self:Register(
        "cleanup",
        {
            callback = callback,
            cleanup_policy = cleanup_policy,
            label = label,
            target_scope = target_scope,
            resolver = resolver,
        }
    )
end

function ResourceScope.ReleaseResource(self, resource_id)
    local resource = self.resources_by_id[resource_id]
    if resource == nil then
        return false, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    self.resources_by_id[resource_id] = nil
    RemoveResourceFromOrder(self, resource_id)
    return true
end

function ResourceScope.GetResourceCount(self)
    return #self.resource_order
end

function ResourceScope.TransferResource(self, resource_id, target_scope)
    if not IsOpen(self) then
        return false, ResourceScope.ERROR_CODES.SCOPE_CLOSED
    end
    local resource = self.resources_by_id[resource_id]
    if resource == nil then
        return false, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    return TransferResource(self, resource, target_scope)
end

function ResourceScope.DoTaskInTime(self, owner, time, callback, ...)
    if not IsOpen(self) then
        return nil, ResourceScope.ERROR_CODES.SCOPE_CLOSED
    end
    if owner == nil or type(owner.DoTaskInTime) ~= "function"
        or type(callback) ~= "function" then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end

    local generation = self.generation
    local function guarded_callback(task_owner, ...)
        if not self:IsGenerationCurrent(generation) then
            return
        end
        local ok, result = ProtectedCall(callback, task_owner, ...)
        if ok then
            return result
        end
    end

    local ok, task = ProtectedCall(owner.DoTaskInTime, owner, time, guarded_callback, ...)
    if not ok or task == nil then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    local resource_id, register_code = self:RegisterTask(task, nil, "timed_task")
    if resource_id == nil then
        if type(task.Cancel) == "function" then
            ProtectedCall(task.Cancel, task)
        end
        return nil, register_code
    end
    return task, nil, resource_id
end

function ResourceScope.DoPeriodicTask(self, owner, period, callback, initial_delay, ...)
    if not IsOpen(self) then
        return nil, ResourceScope.ERROR_CODES.SCOPE_CLOSED
    end
    if owner == nil or type(owner.DoPeriodicTask) ~= "function"
        or type(callback) ~= "function" then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end

    local generation = self.generation
    local function guarded_callback(task_owner, ...)
        if not self:IsGenerationCurrent(generation) then
            return
        end
        local ok, result = ProtectedCall(callback, task_owner, ...)
        if ok then
            return result
        end
    end

    local ok, task = ProtectedCall(
        owner.DoPeriodicTask,
        owner,
        period,
        guarded_callback,
        initial_delay,
        ...
    )
    if not ok or task == nil then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end
    local resource_id, register_code = self:RegisterTask(task, nil, "periodic_task")
    if resource_id == nil then
        if type(task.Cancel) == "function" then
            ProtectedCall(task.Cancel, task)
        end
        return nil, register_code
    end
    return task, nil, resource_id
end

function ResourceScope.ListenForEvent(self, listener, event, callback, source, cleanup_policy, label)
    if not IsOpen(self) then
        return nil, ResourceScope.ERROR_CODES.SCOPE_CLOSED
    end
    if listener == nil or type(listener.ListenForEvent) ~= "function"
        or not IsNonEmptyString(event) or type(callback) ~= "function" then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end

    local generation = self.generation
    local function guarded_callback(...)
        if not self:IsGenerationCurrent(generation) then
            return
        end
        local ok, result = ProtectedCall(callback, ...)
        if ok then
            return result
        end
    end

    local event_source = source or listener
    local ok = ProtectedCall(
        listener.ListenForEvent,
        listener,
        event,
        guarded_callback,
        event_source
    )
    if not ok then
        return nil, ResourceScope.ERROR_CODES.SCOPE_RESOURCE_INVALID
    end

    local resource_id, register_code = self:RegisterEvent(
        listener,
        event,
        guarded_callback,
        event_source,
        cleanup_policy,
        label
    )
    if resource_id == nil then
        if type(listener.RemoveEventCallback) == "function" then
            ProtectedCall(
                listener.RemoveEventCallback,
                listener,
                event,
                guarded_callback,
                event_source
            )
        end
        return nil, register_code
    end
    return resource_id
end

function ResourceScope.Close(self, reason)
    if self.state == ResourceScope.STATES.CLOSED then
        return true, "ALREADY_CLOSED"
    end
    if self.state == ResourceScope.STATES.CLOSING then
        return false, ResourceScope.ERROR_CODES.SCOPE_CLOSED
    end

    self.state = ResourceScope.STATES.CLOSING
    self.generation = self.generation + 1
    self.close_reason = reason ~= nil and tostring(reason) or nil
    local all_clean = true

    for index = #self.child_order, 1, -1 do
        local child_id = self.child_order[index]
        local child = self.children_by_id[child_id]
        if child ~= nil then
            local closed = child:Close(reason or "parent_closed")
            if not closed then
                all_clean = false
            end
            self.children_by_id[child_id] = nil
        end
    end
    self.child_order = {}

    for index = #self.resource_order, 1, -1 do
        local resource_id = self.resource_order[index]
        local resource = self.resources_by_id[resource_id]
        if resource ~= nil then
            local policy = resource.cleanup_policy
            local handled = false
            local transferred = false

            if policy == ResourceScope.POLICIES.RETAIN_IN_PARENT_SCOPE then
                if self.parent ~= nil and IsOpen(self.parent) then
                    local transfer_ok = TransferResource(self, resource, self.parent)
                    transferred = transfer_ok
                    handled = transfer_ok
                end
            elseif policy == ResourceScope.POLICIES.TRANSFER_TO_SCOPE then
                local transfer_ok = TransferResource(self, resource, resource.target_scope)
                transferred = transfer_ok
                handled = transfer_ok
            elseif policy == ResourceScope.POLICIES.MODE_RESOLVE
                and type(resource.resolver) == "function" then
                local resolve_ok, resolved = ProtectedCall(resource.resolver, resource)
                handled = resolve_ok and resolved ~= false
                if handled then
                    self.resources_by_id[resource_id] = nil
                    RemoveResourceFromOrder(self, resource_id)
                end
            end

            if not handled and not transferred then
                if not DestroyResource(self, resource) then
                    all_clean = false
                end
                self.resources_by_id[resource_id] = nil
                RemoveResourceFromOrder(self, resource_id)
            end
        end
    end

    self.state = ResourceScope.STATES.CLOSED
    if all_clean then
        return true
    end
    return false, ResourceScope.ERROR_CODES.RESOURCE_CLEANUP_FAILED
end

function ResourceScope.GetSnapshot(self)
    local resources = {}
    for index = 1, #self.resource_order do
        local resource = self.resources_by_id[self.resource_order[index]]
        if resource ~= nil then
            table.insert(
                resources,
                {
                    id = resource.id,
                    kind = resource.kind,
                    scope_id = self.scope_id,
                    cleanup_policy = resource.cleanup_policy,
                    label = resource.label,
                    metadata = CopyValue(resource.metadata),
                }
            )
        end
    end

    local children = {}
    for index = 1, #self.child_order do
        local child = self.children_by_id[self.child_order[index]]
        if child ~= nil then
            table.insert(children, child:GetSnapshot())
        end
    end

    return
    {
        schema_version = ResourceScope.SCHEMA_VERSION,
        instance_id = self.instance_id,
        scope_id = self.scope_id,
        parent_scope_id = self.parent ~= nil and self.parent.scope_id or nil,
        state = self.state,
        generation = self.generation,
        resources = resources,
        children = children,
    }
end

function ResourceScope.GetDebugLines(self)
    local lines =
    {
        string.format(
            "scope_id=%s instance_id=%s state=%s generation=%d resources=%d children=%d",
            tostring(self.scope_id),
            tostring(self.instance_id),
            tostring(self.state),
            self.generation,
            #self.resource_order,
            #self.child_order
        ),
    }
    for index = 1, #self.child_order do
        local child = self.children_by_id[self.child_order[index]]
        if child ~= nil then
            local child_lines = child:GetDebugLines()
            for child_index = 1, #child_lines do
                table.insert(lines, child_lines[child_index])
            end
        end
    end
    return lines
end

local function AttachMethods(scope)
    scope.GetId = ResourceScope.GetId
    scope.GetInstanceId = ResourceScope.GetInstanceId
    scope.GetParent = ResourceScope.GetParent
    scope.GetGeneration = ResourceScope.GetGeneration
    scope.GetState = ResourceScope.GetState
    scope.IsOpen = ResourceScope.IsOpen
    scope.IsClosed = ResourceScope.IsClosed
    scope.IsGenerationCurrent = ResourceScope.IsGenerationCurrent
    scope.CreateChild = ResourceScope.CreateChild
    scope.Register = ResourceScope.Register
    scope.RegisterTask = ResourceScope.RegisterTask
    scope.RegisterEvent = ResourceScope.RegisterEvent
    scope.RegisterEntity = ResourceScope.RegisterEntity
    scope.RegisterCleanup = ResourceScope.RegisterCleanup
    scope.ReleaseResource = ResourceScope.ReleaseResource
    scope.GetResourceCount = ResourceScope.GetResourceCount
    scope.TransferResource = ResourceScope.TransferResource
    scope.DoTaskInTime = ResourceScope.DoTaskInTime
    scope.DoPeriodicTask = ResourceScope.DoPeriodicTask
    scope.ListenForEvent = ResourceScope.ListenForEvent
    scope.Close = ResourceScope.Close
    scope.GetSnapshot = ResourceScope.GetSnapshot
    scope.GetDebugLines = ResourceScope.GetDebugLines
    return scope
end

function ResourceScope.New(options)
    if type(options) ~= "table"
        or not IsNonEmptyString(options.instance_id)
        or not IsNonEmptyString(options.scope_id) then
        return nil, ResourceScope.ERROR_CODES.INVALID_SCOPE
    end
    if options.parent ~= nil
        and (options.parent.instance_id ~= options.instance_id or not IsOpen(options.parent)) then
        return nil, ResourceScope.ERROR_CODES.SCOPE_INSTANCE_MISMATCH
    end

    return AttachMethods(
    {
        schema_version = ResourceScope.SCHEMA_VERSION,
        instance_id = options.instance_id,
        scope_id = options.scope_id,
        parent = options.parent,
        state = ResourceScope.STATES.OPEN,
        generation = 1,
        next_child_sequence = 0,
        next_resource_id = 0,
        children_by_id = {},
        child_order = {},
        resources_by_id = {},
        resource_order = {},
    })
end

return ResourceScope
