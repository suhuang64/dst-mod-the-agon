-- WP3：Instance 范围内唯一的实体生成入口，并捕获构造期间产生的同步子实体。

local Diagnostics = require("agon/debug/diagnostics")

local SpawnService = {}
SpawnService.SCHEMA_VERSION = 1

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
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

local function GetGuid(entity)
    if entity == nil then
        return nil
    end
    if entity.GUID ~= nil then
        return tostring(entity.GUID)
    end
    if entity.entity ~= nil and type(entity.entity.GetGUID) == "function" then
        local ok, guid = ProtectedCall(entity.entity.GetGUID, entity.entity)
        if ok and guid ~= nil then
            return tostring(guid)
        end
    end
    return nil
end

local function IsValidEntity(entity)
    if entity == nil or type(entity.IsValid) ~= "function" then
        return false
    end
    local ok, valid = ProtectedCall(entity.IsValid, entity)
    return ok and valid == true
end

local function GetScopeInstanceId(scope)
    if scope == nil then
        return nil
    end
    if type(scope.GetInstanceId) == "function" then
        return scope:GetInstanceId()
    end
    return scope.instance_id
end

local function IsScopeOpen(scope)
    return scope ~= nil and type(scope.IsOpen) == "function" and scope:IsOpen()
end

local function GetParentEntity(entity)
    if entity == nil then
        return nil
    end
    if entity.parent ~= nil then
        return entity.parent
    end
    if entity.entity ~= nil and type(entity.entity.GetParent) == "function" then
        local ok, parent = ProtectedCall(entity.entity.GetParent, entity.entity)
        if ok then
            return parent
        end
    end
    return nil
end

local function IsPoint(point)
    return type(point) == "table"
        and IsFiniteNumber(point.x)
        and IsFiniteNumber(point.z)
        and (point.y == nil or IsFiniteNumber(point.y))
end

local function RemoveUnregistered(entities)
    for index = #entities, 1, -1 do
        local entity = entities[index]
        if IsValidEntity(entity) and type(entity.Remove) == "function" then
            ProtectedCall(entity.Remove, entity)
        end
    end
end

local function AddCaptured(context, entity)
    if not IsValidEntity(entity) then
        return
    end
    local guid = GetGuid(entity)
    if guid == nil or context.seen[guid] then
        return
    end
    context.seen[guid] = true
    table.insert(context.entities, entity)
end

local function OnWorldEntitySpawned(self, _, entity)
    if #self.context_stack == 0 then
        return
    end
    local context = self.context_stack[#self.context_stack]
    if context ~= nil then
        AddCaptured(context, entity)
    end
end

function SpawnService.Spawn(self, instance, spec, scope)
    if self.closed then
        return nil, Diagnostics.ERROR_CODES.SCOPE_CLOSED
    end
    if GetInstanceId(instance) ~= self.instance_id then
        return nil, Diagnostics.ERROR_CODES.SCOPE_INSTANCE_MISMATCH
    end
    if type(spec) ~= "table" or not IsNonEmptyString(spec.prefab) then
        return nil, Diagnostics.ERROR_CODES.SPAWN_INVALID
    end
    scope = scope or self.root_scope
    if not IsScopeOpen(scope) or GetScopeInstanceId(scope) ~= self.instance_id then
        return nil, Diagnostics.ERROR_CODES.SCOPE_INSTANCE_MISMATCH
    end
    if spec.position ~= nil and not IsPoint(spec.position) then
        return nil, Diagnostics.ERROR_CODES.SPAWN_INVALID
    end
    if type(SpawnPrefab) ~= "function" then
        return nil, Diagnostics.ERROR_CODES.SPAWN_FAILED
    end

    local context =
    {
        instance = instance,
        scope = scope,
        spec = spec,
        entities = {},
        seen = {},
    }
    table.insert(self.context_stack, context)
    local ok, root = ProtectedCall(
        SpawnPrefab,
        spec.prefab,
        spec.skin,
        spec.skin_id,
        spec.creator,
        spec.skin_custom
    )
    table.remove(self.context_stack)

    if not ok or not IsValidEntity(root) then
        RemoveUnregistered(context.entities)
        return nil, Diagnostics.ERROR_CODES.SPAWN_FAILED
    end
    AddCaptured(context, root)

    if spec.position ~= nil then
        if root.Transform == nil or type(root.Transform.SetPosition) ~= "function" then
            RemoveUnregistered(context.entities)
            return nil, Diagnostics.ERROR_CODES.SPAWN_FAILED
        end
        local set_ok = ProtectedCall(
            root.Transform.SetPosition,
            root.Transform,
            spec.position.x,
            spec.position.y or 0,
            spec.position.z
        )
        if not set_ok then
            RemoveUnregistered(context.entities)
            return nil, Diagnostics.ERROR_CODES.SPAWN_FAILED
        end
    end

    local root_guid = GetGuid(root)
    local ordered_entities = { root }
    for index = 1, #context.entities do
        local entity = context.entities[index]
        if entity ~= root then
            table.insert(ordered_entities, entity)
        end
    end

    local registered = {}
    local registered_records = {}
    local spawn_source = spec.spawn_source or ("spawn:" .. tostring(root_guid))
    for index = 1, #ordered_entities do
        local entity = ordered_entities[index]
        local guid = GetGuid(entity)
        if guid == nil or self.entity_registry:Get(guid) ~= nil then
            self.entity_registry:RemoveGuids(registered)
            RemoveUnregistered(context.entities)
            return nil, Diagnostics.ERROR_CODES.SPAWN_FAILED
        end

        local parent_entity = GetParentEntity(entity)
        local parent_entity_id = GetGuid(parent_entity)
        if parent_entity_id == nil and entity ~= root then
            parent_entity_id = root_guid
        end
        local record, register_code = self.entity_registry:Register(
            entity,
            {
                scope = scope,
                generation = scope:GetGeneration(),
                prefab = entity.prefab or spec.prefab,
                category = spec.category or "GENERIC",
                cleanup_policy = spec.cleanup_policy,
                profile_id = spec.profile_id,
                profile_version = spec.profile_version,
                parent_entity_id = parent_entity_id,
                spawn_source = spawn_source,
                persistent_key = spec.persistent_key,
                metadata = spec.metadata,
            }
        )
        if record == nil then
            self.entity_registry:RemoveGuids(registered)
            RemoveUnregistered(context.entities)
            return nil, register_code or Diagnostics.ERROR_CODES.SPAWN_FAILED
        end
        table.insert(registered, guid)
        table.insert(registered_records, record)
    end

    return root, nil, registered_records
end

function SpawnService.Claim(self, instance, entity, data, scope)
    if self.closed then
        return nil, Diagnostics.ERROR_CODES.SCOPE_CLOSED
    end
    if GetInstanceId(instance) ~= self.instance_id or not IsValidEntity(entity) then
        return nil, Diagnostics.ERROR_CODES.ENTITY_OWNER_MISMATCH
    end
    scope = scope or self.root_scope
    if not IsScopeOpen(scope) or GetScopeInstanceId(scope) ~= self.instance_id then
        return nil, Diagnostics.ERROR_CODES.SCOPE_INSTANCE_MISMATCH
    end
    data = type(data) == "table" and data or {}
    data.scope = scope
    data.generation = data.generation or scope:GetGeneration()
    return self.entity_registry:Claim(entity, data)
end

function SpawnService.Close(self)
    self.closed = true
end

function SpawnService.GetDebugString(self)
    return string.format(
        "spawn_service instance=%s closed=%s contexts=%d entities=%d",
        tostring(self.instance_id),
        tostring(self.closed),
        #self.context_stack,
        self.entity_registry:Count()
    )
end

local function AttachMethods(service)
    service.Spawn = SpawnService.Spawn
    service.Claim = SpawnService.Claim
    service.Close = SpawnService.Close
    service.GetDebugString = SpawnService.GetDebugString
    return service
end

function SpawnService.New(options)
    if type(options) ~= "table"
        or not IsNonEmptyString(options.instance_id)
        or options.entity_registry == nil
        or not IsScopeOpen(options.root_scope)
        or options.world == nil
        or type(options.world.ListenForEvent) ~= "function" then
        return nil, Diagnostics.ERROR_CODES.SPAWN_INVALID
    end

    local service = AttachMethods(
    {
        schema_version = SpawnService.SCHEMA_VERSION,
        instance_id = options.instance_id,
        world = options.world,
        root_scope = options.root_scope,
        entity_registry = options.entity_registry,
        context_stack = {},
        closed = false,
        listener_resource_id = nil,
    })
    local listener_resource_id, listener_code = options.root_scope:ListenForEvent(
        options.world,
        "entity_spawned",
        function(source, entity)
            OnWorldEntitySpawned(service, source, entity)
        end,
        options.world,
        nil,
        "spawn_context_listener"
    )
    if listener_resource_id == nil then
        return nil, listener_code or Diagnostics.ERROR_CODES.SPAWN_CONTEXT_FAILED
    end
    service.listener_resource_id = listener_resource_id
    return service
end

return SpawnService
