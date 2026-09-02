-- WP4：TestMode 的服务端隔离/随机/网络边界验收。
-- 该模块只使用临时 TestMode Instance，完成后一定销毁并释放 Zone。

local Diagnostics = require("agon/debug/diagnostics")
local InstanceRng = require("agon/core/instance_rng")
local AudienceStateChannel = require("agon/net/audience_state_channel")
local RulePolicy = require("agon/core/rule_policy")
local Rpc = require("agon/net/rpc")

local Wp4Diagnostics = {}

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function FirstEntity(instance)
    local records = instance.entity_registry:List()
    return records[1] ~= nil and records[1].entity or nil
end

local function HasState(records, state_id)
    for index = 1, #records do
        if records[index].state_id == state_id then
            return true
        end
    end
    return false
end

local function MakeTestPlayer(userid)
    local state =
    {
        inventory =
        {
            slots = {},
            equipment = {},
            active_item = nil,
            containers = {},
        },
        survival_stats =
        {
            health = { current = 100, max = 100, penalty = 0, invincible = false },
            hunger = { current = 100, max = 100 },
            sanity = { current = 100, max = 100, mode = 0, sane = true },
            temperature = { current = 25 },
            moisture = { current = 0, max = 100 },
            temporary = {},
        },
        skilltree =
        {
            handshake_complete = true,
            xp = 0,
            points = 0,
            activated_skills = {},
            selection = {},
            encoded_data = "",
            character_prefab = "wilson",
        },
        character =
        {
            prefab = "wilson",
            appearance = {},
            resources = {},
            followers = {},
            pets = {},
            summoned = {},
            components = {},
            abilities = {},
            movement_speed = 1,
        },
        movement_speed = 1,
    }
    return
    {
        userid = userid,
        agon_sandbox_test = true,
        agon_sandbox_state = state,
        IsValid = function()
            return true
        end,
    }
end

local function Cleanup(runtime, instances)
    for index = #instances, 1, -1 do
        local instance = instances[index]
        if instance ~= nil
            and runtime.instance_manager:Get(instance.instance_id) ~= nil then
            runtime.instance_manager:Destroy(
                instance.instance_id,
                "wp4_diagnostics_cleanup"
            )
        end
    end
end

local function Require(condition, message)
    if not condition then
        return false, message
    end
    return true
end

function Wp4Diagnostics.Run(runtime)
    if runtime == nil or not runtime:IsReady()
        or runtime.instance_manager == nil
        or runtime.audience_state_channel == nil
        or runtime.rpc == nil then
        return false, "WP4 runtime services are not ready"
    end

    local instances = {}
    local result = true
    local failure = nil
    local function Check(condition, message)
        if result then
            result, failure = Require(condition, message)
        end
    end

    local ok, execution_error = ProtectedCall(function()
        runtime.wp4_diagnostic_run = (runtime.wp4_diagnostic_run or 0) + 1
        local suffix = tostring(runtime.boot_generation)
            .. "_"
            .. tostring(runtime.wp4_diagnostic_run)
        local userid_a = "__agon_wp4_a_" .. suffix
        local userid_b = "__agon_wp4_b_" .. suffix
        local instance_a, create_a_code = runtime:CreateInstance(
            "TEST_MODE",
            { userid_a }
        )
        Check(instance_a ~= nil, "create instance A failed: " .. tostring(create_a_code))
        if not result then
            return
        end
        table.insert(instances, instance_a)

        local instance_b, create_b_code = runtime:CreateInstance(
            "TEST_MODE",
            { userid_b }
        )
        Check(instance_b ~= nil, "create instance B failed: " .. tostring(create_b_code))
        if not result then
            return
        end
        table.insert(instances, instance_b)

        Check(instance_a.instance_id ~= instance_b.instance_id,
            "concurrent instance IDs collided")
        local started_a, start_a_code = runtime:StartInstance(instance_a.instance_id, "wp4_diagnostics")
        Check(started_a, "start instance A failed: " .. tostring(start_a_code))
        local started_b, start_b_code = runtime:StartInstance(instance_b.instance_id, "wp4_diagnostics")
        Check(started_b, "start instance B failed: " .. tostring(start_b_code))
        if not result then
            return
        end

        local player_a = MakeTestPlayer(userid_a)
        local player_b = MakeTestPlayer(userid_b)
        local attached_a, attached_a_code = runtime.instance_manager:AttachPlayer(
            instance_a.instance_id,
            userid_a,
            player_a
        )
        local attached_b, attached_b_code = runtime.instance_manager:AttachPlayer(
            instance_b.instance_id,
            userid_b,
            player_b
        )
        Check(attached_a, "attach player A failed: " .. tostring(attached_a_code))
        Check(attached_b, "attach player B failed: " .. tostring(attached_b_code))
        if not result then
            return
        end

        local participant_a = runtime.instance_manager:GetParticipant(userid_a)
        local participant_b = runtime.instance_manager:GetParticipant(userid_b)
        participant_a:TransitionTo("PLAYING", "wp4_diagnostics", instance_a.generation)
        participant_b:TransitionTo("PLAYING", "wp4_diagnostics", instance_b.generation)
        Check(runtime.instance_manager:GetParticipantInstanceId(userid_a) == instance_a.instance_id,
            "userid A index did not resolve to instance A")
        local duplicate_instance = runtime:CreateInstance(
            "TEST_MODE",
            { userid_a }
        )
        Check(duplicate_instance == nil,
            "same userid was accepted into a second Instance")

        local entity_a = FirstEntity(instance_a)
        local entity_b = FirstEntity(instance_b)
        Check(entity_a ~= nil and entity_b ~= nil,
            "diagnostic entities were not spawned")
        if not result then
            return
        end

        local resolved_a = runtime.instance_manager:ResolveInstance(player_a)
        local resolved_entity_a = runtime.instance_manager:ResolveInstance(entity_a)
        Check(resolved_a == instance_a.instance_id
            and resolved_entity_a == instance_a.instance_id,
            "ResolveInstance did not follow participant/entity membership")
        local root_owner = runtime.instance_manager:ResolveRootOwner(entity_a)
        Check(root_owner == entity_a, "root entity did not resolve to itself")

        local child =
        {
            IsValid = function()
                return true
            end,
            AddTag = function() end,
        }
        local propagated, propagate_code = runtime.instance_manager.rule_policy:PropagateMembership(
            child,
            entity_a,
            { register = false, category = "PROJECTILE" }
        )
        Check(propagated, "membership propagation failed: " .. tostring(propagate_code))
        local projectile_root =
        {
            owner = child,
        }
        local propagated_instance = runtime.instance_manager:ResolveInstance(projectile_root)
        local propagated_root = runtime.instance_manager:ResolveRootOwner(projectile_root)
        Check(propagated_instance == instance_a.instance_id
            and propagated_root == entity_a,
            "projectile/root owner membership did not propagate")

        local allowed_same = runtime.instance_manager:CanInteract(
            RulePolicy.ACTIONS.TARGET,
            player_a,
            entity_a,
            { instance_id = instance_a.instance_id }
        )
        local allowed_cross, cross_code = runtime.instance_manager:CanInteract(
            RulePolicy.ACTIONS.DAMAGE,
            player_a,
            entity_b,
            { instance_id = instance_a.instance_id }
        )
        local unowned, unowned_code = runtime.instance_manager:CanInteract(
            RulePolicy.ACTIONS.PICKUP,
            player_a,
            {},
            { instance_id = instance_a.instance_id }
        )
        Check(allowed_same == true,
            "same Instance interaction was rejected")
        Check(allowed_cross == false and cross_code == RulePolicy.ERROR_CODES.CROSS_INSTANCE,
            "cross Instance interaction was not rejected")
        Check(unowned == false and unowned_code == RulePolicy.ERROR_CODES.UNOWNED_ENTITY,
            "unowned entity was accepted")

        local rng_a = InstanceRng.New("wp4-repro-seed")
        local rng_b = InstanceRng.New("wp4-repro-seed")
        local rng_same = true
        for index = 1, 8 do
            local value_a = rng_a:RandomInt("loot", 1, 100000)
            local value_b = rng_b:RandomInt("loot", 1, 100000)
            rng_same = rng_same and value_a == value_b
        end
        local baseline = InstanceRng.New("wp4-stream-seed")
        local baseline_first = baseline:Random("loot")
        local baseline_second = baseline:Random("loot")
        local independent = InstanceRng.New("wp4-stream-seed")
        independent:Random("scene")
        independent:Random("scene")
        local independent_first = independent:Random("loot")
        local independent_second = independent:Random("loot")
        Check(rng_same and baseline_first == independent_first
            and baseline_second == independent_second,
            "InstanceRng stream sequence was not reproducible/independent")

        local channel = runtime.audience_state_channel
        local private_id = "wp4.private." .. suffix
        local state_a_id = "wp4.instance.a." .. suffix
        local state_b_id = "wp4.instance.b." .. suffix
        channel:Publish(
            private_id,
            AudienceStateChannel.Private(userid_a),
            { private_value = "A" },
            { instance_id = instance_a.instance_id }
        )
        channel:Publish(
            state_a_id,
            AudienceStateChannel.Instance(instance_a.instance_id),
            { instance_value = "A" },
            { instance_id = instance_a.instance_id }
        )
        channel:Publish(
            state_b_id,
            AudienceStateChannel.Instance(instance_b.instance_id),
            { instance_value = "B" },
            { instance_id = instance_b.instance_id }
        )
        local visible_a = channel:ReadFor(userid_a)
        local visible_b = channel:ReadFor(userid_b)
        Check(HasState(visible_a, private_id)
            and HasState(visible_a, state_a_id)
            and not HasState(visible_a, state_b_id),
            "PRIVATE/INSTANCE visibility leaked to player A")
        Check(not HasState(visible_b, private_id)
            and not HasState(visible_b, state_a_id)
            and HasState(visible_b, state_b_id),
            "PRIVATE/INSTANCE visibility leaked to player B")

        local request =
        {
            instance_id = instance_a.instance_id,
            generation = instance_a.generation,
            scene_revision = instance_a.scene_revision,
            request_id = "wp4-request-" .. suffix,
            action = RulePolicy.ACTIONS.TARGET,
            target_guid = tostring(entity_a.GUID),
        }
        local request_ok, request_code = runtime.rpc:Handle(player_a, request)
        local duplicate_ok, duplicate_code = runtime.rpc:Handle(player_a, request)
        local cross_request =
        {
            instance_id = instance_a.instance_id,
            generation = instance_a.generation,
            scene_revision = instance_a.scene_revision,
            request_id = "wp4-cross-request-" .. suffix,
            action = RulePolicy.ACTIONS.DAMAGE,
            target_guid = tostring(entity_b.GUID),
        }
        local cross_request_ok, cross_request_code = runtime.rpc:Handle(
            player_a,
            cross_request
        )
        Check(request_ok == true,
            "valid RPC request was rejected: " .. tostring(request_code))
        Check(duplicate_ok == false
            and duplicate_code == Rpc.ERROR_CODES.DUPLICATE_REQUEST,
            "duplicate RPC request was not rejected idempotently")
        Check(cross_request_ok == false
            and cross_request_code == RulePolicy.ERROR_CODES.CROSS_INSTANCE,
            "RPC ownership validation allowed a cross Instance target")
    end)

    Cleanup(runtime, instances)
    if not ok then
        result = false
        failure = "WP4 diagnostic exception: " .. tostring(execution_error)
    end
    if not result then
        return false, failure
    end
    local valid, valid_code = runtime:ValidateCore()
    if not valid then
        return false, "core invalid after WP4 diagnostics: " .. tostring(valid_code)
    end
    return true
end

return Wp4Diagnostics
