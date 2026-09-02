-- WP4：Instance 归属解析与默认交互策略。

local RulePolicy = {}

RulePolicy.SCHEMA_VERSION = 1

RulePolicy.ACTIONS =
{
    DAMAGE = "DAMAGE",
    HEAL = "HEAL",
    PICKUP = "PICKUP",
    CONTAINER = "CONTAINER",
    PROJECTILE = "PROJECTILE",
    TARGET = "TARGET",
    CONTROL = "CONTROL",
}

RulePolicy.ERROR_CODES =
{
    INVALID_SUBJECT = "INVALID_RULE_SUBJECT",
    UNOWNED_ENTITY = "UNOWNED_ENTITY",
    CROSS_INSTANCE = "CROSS_INSTANCE",
    SPECTATOR_FORBIDDEN = "SPECTATOR_GAMEPLAY_FORBIDDEN",
    INSTANCE_NOT_FOUND = "RULE_INSTANCE_NOT_FOUND",
    MEMBERSHIP_PROPAGATION_FAILED = "MEMBERSHIP_PROPAGATION_FAILED",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number" and value == math.floor(value) and value >= 1
end

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
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

local function GetMemberComponent(entity)
    if entity == nil or type(entity.components) ~= "table" then
        return nil
    end
    return entity.components.agon_instance_member
end

local function GetComponentInstanceId(entity)
    local member = GetMemberComponent(entity)
    if member ~= nil and type(member.GetInstanceId) == "function" then
        local ok, instance_id = ProtectedCall(member.GetInstanceId, member)
        if ok and IsNonEmptyString(instance_id) then
            return instance_id
        end
    end
    return nil
end

local function GetComponentScopeId(entity)
    local member = GetMemberComponent(entity)
    if member ~= nil and type(member.GetScopeId) == "function" then
        local ok, scope_id = ProtectedCall(member.GetScopeId, member)
        if ok and IsNonEmptyString(scope_id) then
            return scope_id
        end
    end
    return nil
end

local function GetComponentGeneration(entity)
    local member = GetMemberComponent(entity)
    if member ~= nil and type(member.GetGeneration) == "function" then
        local ok, generation = ProtectedCall(member.GetGeneration, member)
        if ok and IsPositiveInteger(generation) then
            return generation
        end
    end
    return nil
end

local function SetMembershipComponent(entity, instance_id, scope_id, generation, data)
    if type(entity.components) ~= "table" then
        return false, "COMPONENT_API_UNAVAILABLE"
    end
    local member = entity.components.agon_instance_member
    if member == nil then
        if type(entity.AddComponent) ~= "function" then
            return false, "COMPONENT_API_UNAVAILABLE"
        end
        local ok = ProtectedCall(entity.AddComponent, entity, "agon_instance_member")
        if not ok then
            return false, "COMPONENT_ADD_FAILED"
        end
        member = entity.components.agon_instance_member
    end
    if member == nil or type(member.SetMembership) ~= "function" then
        return false, "COMPONENT_INVALID"
    end
    if type(member.GetInstanceId) == "function" then
        local ok, old_instance_id = ProtectedCall(member.GetInstanceId, member)
        if ok and old_instance_id ~= nil and old_instance_id ~= instance_id then
            return false, "COMPONENT_OWNER_MISMATCH"
        end
    end
    local ok, result = ProtectedCall(
        member.SetMembership,
        member,
        instance_id,
        scope_id,
        generation,
        data
    )
    if not ok or result == false then
        return false, "COMPONENT_MEMBERSHIP_FAILED"
    end
    return true
end

local function GetOwnerFromComponents(entity)
    if entity == nil or type(entity.components) ~= "table" then
        return nil
    end

    local projectile = entity.components.projectile
    if projectile ~= nil and type(projectile.owner) == "table" then
        return projectile.owner
    end

    local complex_projectile = entity.components.complexprojectile
    if complex_projectile ~= nil then
        if type(complex_projectile.owner) == "table" then
            return complex_projectile.owner
        end
        if type(complex_projectile.attacker) == "table" then
            return complex_projectile.attacker
        end
    end

    local inventory_item = entity.components.inventoryitem
    if inventory_item ~= nil and type(inventory_item.GetGrandOwner) == "function" then
        local ok, owner = ProtectedCall(inventory_item.GetGrandOwner, inventory_item)
        if ok and type(owner) == "table" then
            return owner
        end
    end

    local follower = entity.components.follower
    if follower ~= nil and type(follower.leader) == "table" then
        return follower.leader
    end
    return nil
end

local function GetExplicitOwner(entity)
    if entity == nil then
        return nil
    end

    local explicit_fields =
    {
        "_agon_root_owner",
        "_agon_parent_entity",
        "parent_entity",
        "owner",
        "attacker",
        "source",
        "dropper",
        "creator",
        "weapon",
    }
    for index = 1, #explicit_fields do
        local candidate = entity[explicit_fields[index]]
        if type(candidate) == "table" and candidate ~= entity then
            return candidate
        end
    end
    return GetOwnerFromComponents(entity)
end

local function GetUserId(subject)
    if type(subject) == "table" and IsNonEmptyString(subject.userid) then
        return subject.userid
    end
    if IsNonEmptyString(subject) then
        return subject
    end
    return nil
end

function RulePolicy.GetEntityInstanceId(self, entity)
    if entity == nil then
        return nil
    end
    return GetComponentInstanceId(entity) or entity._agon_instance_id
end

function RulePolicy.ResolveRootOwner(self, entity)
    if type(entity) ~= "table" then
        return nil
    end

    local current = entity
    local seen = {}
    while type(current) == "table" and not seen[current] do
        seen[current] = true
        local next_owner = GetExplicitOwner(current)
        if type(next_owner) ~= "table" or next_owner == current then
            return current
        end
        current = next_owner
    end
    return entity
end

local function ResolveInstanceId(self, subject, seen)
    if IsNonEmptyString(subject) then
        local participant = self.participant_index[subject]
        if participant ~= nil and IsNonEmptyString(participant.instance_id) then
            return participant.instance_id
        end
        return nil
    end
    if type(subject) ~= "table" then
        return nil
    end
    if seen[subject] then
        return nil
    end
    seen[subject] = true

    local userid = GetUserId(subject)
    if userid ~= nil then
        local participant = self.participant_index[userid]
        if participant ~= nil and IsNonEmptyString(participant.instance_id) then
            return participant.instance_id
        end
    end

    local instance_id = GetComponentInstanceId(subject)
        or subject._agon_instance_id
    if IsNonEmptyString(instance_id) then
        return instance_id
    end

    if IsNonEmptyString(subject.instance_id)
        and self.instance_lookup(subject.instance_id) ~= nil then
        return subject.instance_id
    end

    local root_owner = self:ResolveRootOwner(subject)
    if root_owner ~= subject then
        return ResolveInstanceId(self, root_owner, seen)
    end
    return nil
end

function RulePolicy.ResolveInstance(self, subject)
    local instance_id = ResolveInstanceId(self, subject, {})
    if not IsNonEmptyString(instance_id) then
        return nil
    end
    local instance = self.instance_lookup(instance_id)
    if instance == nil then
        return nil
    end
    return instance_id, instance
end

local function IsSpectator(subject)
    if type(subject) ~= "table" then
        return false
    end
    if subject.is_spectator == true or subject.spectating_instance_id ~= nil then
        return true
    end
    if type(subject.HasTag) == "function" then
        local ok, has_tag = ProtectedCall(subject.HasTag, subject, "agon_spectator")
        return ok and has_tag == true
    end
    return false
end

function RulePolicy.SameInstance(self, left, right, expected_instance_id)
    local left_id = self:ResolveInstance(left)
    local right_id = self:ResolveInstance(right)
    if not IsNonEmptyString(left_id) or not IsNonEmptyString(right_id) then
        return false, RulePolicy.ERROR_CODES.UNOWNED_ENTITY
    end
    if expected_instance_id ~= nil and left_id ~= expected_instance_id then
        return false, RulePolicy.ERROR_CODES.CROSS_INSTANCE
    end
    if left_id ~= right_id then
        return false, RulePolicy.ERROR_CODES.CROSS_INSTANCE
    end
    return true
end

function RulePolicy.CanInteract(self, action, source, target, options)
    options = type(options) == "table" and options or {}
    if not IsNonEmptyString(action)
        or source == nil
        or target == nil then
        return false, RulePolicy.ERROR_CODES.INVALID_SUBJECT
    end
    if IsSpectator(source) or IsSpectator(target) then
        return false, RulePolicy.ERROR_CODES.SPECTATOR_FORBIDDEN
    end

    local allowed, code = self:SameInstance(
        source,
        target,
        options.instance_id
    )
    if not allowed then
        return false, code
    end

    local instance_id, instance = self:ResolveInstance(source)
    if instance == nil then
        return false, RulePolicy.ERROR_CODES.INSTANCE_NOT_FOUND
    end
    local mode_policy = options.mode_policy
        or (instance.rule_policy ~= self and instance.rule_policy)
    if type(mode_policy) == "function" then
        local ok, result, mode_code = ProtectedCall(
            mode_policy,
            instance,
            action,
            source,
            target,
            options
        )
        if not ok or result == false then
            return false, mode_code or RulePolicy.ERROR_CODES.CROSS_INSTANCE
        end
    end
    return true, nil, instance_id
end

function RulePolicy.CanControl(self, controller, target, options)
    options = type(options) == "table" and options or {}
    local controller_id = self:ResolveInstance(controller)
    local target_id = self:ResolveInstance(target)
    if not IsNonEmptyString(controller_id) or not IsNonEmptyString(target_id) then
        return false, RulePolicy.ERROR_CODES.UNOWNED_ENTITY
    end
    if controller_id ~= target_id
        or (options.instance_id ~= nil and options.instance_id ~= controller_id) then
        return false, RulePolicy.ERROR_CODES.CROSS_INSTANCE
    end
    if IsSpectator(controller) or IsSpectator(target) then
        return false, RulePolicy.ERROR_CODES.SPECTATOR_FORBIDDEN
    end
    return true, nil, controller_id
end

function RulePolicy.CanDamage(self, source, target, options)
    return self:CanInteract(RulePolicy.ACTIONS.DAMAGE, source, target, options)
end

function RulePolicy.CanHeal(self, source, target, options)
    return self:CanInteract(RulePolicy.ACTIONS.HEAL, source, target, options)
end

function RulePolicy.CanPickup(self, source, target, options)
    return self:CanInteract(RulePolicy.ACTIONS.PICKUP, source, target, options)
end

function RulePolicy.CanOpenContainer(self, source, target, options)
    return self:CanInteract(RulePolicy.ACTIONS.CONTAINER, source, target, options)
end

function RulePolicy.CanUseProjectile(self, source, target, options)
    return self:CanInteract(RulePolicy.ACTIONS.PROJECTILE, source, target, options)
end

function RulePolicy.CanSelectTarget(self, source, target, options)
    return self:CanInteract(RulePolicy.ACTIONS.TARGET, source, target, options)
end

function RulePolicy.PropagateMembership(self, child, parent, options)
    if type(child) ~= "table" or type(parent) ~= "table" or child == parent then
        return false, RulePolicy.ERROR_CODES.INVALID_SUBJECT
    end
    options = type(options) == "table" and options or {}

    local instance_id = self:ResolveInstance(parent)
    if not IsNonEmptyString(instance_id) then
        return false, RulePolicy.ERROR_CODES.UNOWNED_ENTITY
    end
    local instance = self.instance_lookup(instance_id)
    if instance == nil then
        return false, RulePolicy.ERROR_CODES.INSTANCE_NOT_FOUND
    end

    local root_owner = self:ResolveRootOwner(parent)
    local registry = instance.entity_registry
    if options.register ~= false and registry ~= nil
        and type(registry.Inherit) == "function" then
        local registered, register_code = registry:Inherit(
            child,
            parent,
            options
        )
        if registered == nil then
            return false, register_code or RulePolicy.ERROR_CODES.MEMBERSHIP_PROPAGATION_FAILED
        end
    else
        local scope_id = GetComponentScopeId(parent) or parent._agon_scope_id
        local generation = GetComponentGeneration(parent) or parent._agon_generation
        if not IsNonEmptyString(scope_id) or not IsPositiveInteger(generation) then
            return false, RulePolicy.ERROR_CODES.MEMBERSHIP_PROPAGATION_FAILED
        end
        local component_ok, component_code = SetMembershipComponent(
            child,
            instance_id,
            scope_id,
            generation,
            {
                instance_id = instance_id,
                scope_id = scope_id,
                generation = generation,
                category = options.category or "CHILD",
                parent_entity_id = GetGuid(parent),
                spawn_source = options.spawn_source,
            }
        )
        if not component_ok and component_code ~= "COMPONENT_API_UNAVAILABLE" then
            return false, RulePolicy.ERROR_CODES.MEMBERSHIP_PROPAGATION_FAILED
        end
        child._agon_instance_id = instance_id
        child._agon_scope_id = scope_id
        child._agon_generation = generation
        if type(child.AddTag) == "function" then
            ProtectedCall(child.AddTag, child, "agon_managed")
        end
    end

    child._agon_root_owner = root_owner
    child._agon_parent_entity = parent
    return true, nil, instance_id, root_owner
end

function RulePolicy.GetDebugString(self)
    local participant_count = 0
    for _ in pairs(self.participant_index) do
        participant_count = participant_count + 1
    end
    return string.format(
        "rule_policy participants=%d",
        participant_count
    )
end

local function AttachMethods(policy)
    policy.GetEntityInstanceId = RulePolicy.GetEntityInstanceId
    policy.ResolveRootOwner = RulePolicy.ResolveRootOwner
    policy.ResolveInstance = RulePolicy.ResolveInstance
    policy.SameInstance = RulePolicy.SameInstance
    policy.CanInteract = RulePolicy.CanInteract
    policy.CanControl = RulePolicy.CanControl
    policy.CanDamage = RulePolicy.CanDamage
    policy.CanHeal = RulePolicy.CanHeal
    policy.CanPickup = RulePolicy.CanPickup
    policy.CanOpenContainer = RulePolicy.CanOpenContainer
    policy.CanUseProjectile = RulePolicy.CanUseProjectile
    policy.CanSelectTarget = RulePolicy.CanSelectTarget
    policy.PropagateMembership = RulePolicy.PropagateMembership
    policy.GetDebugString = RulePolicy.GetDebugString
    return policy
end

function RulePolicy.New(options)
    options = type(options) == "table" and options or {}
    local participant_index = options.participant_index or {}
    local instance_lookup = options.instance_lookup
    if type(instance_lookup) ~= "function" then
        instance_lookup = function()
            return nil
        end
    end
    return AttachMethods(
    {
        schema_version = RulePolicy.SCHEMA_VERSION,
        participant_index = participant_index,
        instance_lookup = instance_lookup,
    })
end

return RulePolicy
