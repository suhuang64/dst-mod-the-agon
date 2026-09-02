-- WP7：验证 PlayerSandbox 的快照、统一 Profile、恢复、重试和故障隔离。

local Util = require("agon/player/adapters/util")
local SandboxService = require("agon/player/sandbox_service")
local StateAdapterRegistry = require("agon/player/state_adapter_registry")

local Wp7Diagnostics = {}

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function Require(condition, message)
    if not condition then
        return false, message
    end
    return true
end

local function MakeTestPlayer(userid, invalid_skilltree)
    local state =
    {
        inventory =
        {
            slots =
            {
                [1] = { prefab = "wp7_original_food", count = 3 },
                [2] =
                {
                    prefab = "wp7_original_container",
                    contents = { [1] = { prefab = "wp7_nested_item", count = 2 } },
                },
            },
            equipment =
            {
                body = { prefab = "wp7_original_backpack" },
                hands = { prefab = "wp7_original_tool" },
            },
            active_item = { prefab = "wp7_original_active" },
            containers =
            {
                external = { slots = { [1] = { prefab = "wp7_external_item" } } },
            },
        },
        survival_stats =
        {
            health = { current = 73, max = 100, penalty = 0.1, invincible = false },
            hunger = { current = 61, max = 100 },
            sanity = { current = 42, max = 100, mode = 0, sane = true },
            temperature = { current = 18 },
            moisture = { current = 12, max = 100 },
            temporary = { wp7_buff = "original" },
        },
        skilltree =
        {
            handshake_complete = not invalid_skilltree,
            xp = 321,
            points = 2,
            activated_skills = { "wp7_original_skill_a", "wp7_original_skill_b" },
            selection = { 3, 5 },
            encoded_data = "wp7_original_skill_blob",
            character_prefab = "wilson",
        },
        character =
        {
            prefab = "wilson",
            appearance = { skin = "wp7_test_skin", build = "wp7_test_build" },
            resources = { character_meter = 8, sanity_boost = 4 },
            followers = { "wp7_follower" },
            pets = { "wp7_pet" },
            summoned = { "wp7_summoned" },
            components = { character_component = "original" },
            abilities = { "original_character_ability" },
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
    }, Util.CopyData(state)
end

local function Cleanup(runtime, instances)
    local all_clean = true
    for index = #instances, 1, -1 do
        local instance = instances[index]
        if instance ~= nil
            and runtime.instance_manager:Get(instance.instance_id) ~= nil then
            local destroyed = runtime.instance_manager:Destroy(
                instance.instance_id,
                "wp7_diagnostics_cleanup"
            )
            if not destroyed then
                all_clean = false
            end
        end
    end
    return all_clean
end

local function HasOnlySkill(skills, expected)
    return type(skills) == "table"
        and #skills == 1
        and skills[1] == expected
end

function Wp7Diagnostics.Run(runtime)
    if runtime == nil or not runtime:IsReady()
        or runtime.instance_manager == nil then
        return false, "WP7 runtime services are not ready"
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
        runtime.wp7_diagnostic_run = (runtime.wp7_diagnostic_run or 0) + 1
        local suffix = tostring(runtime.boot_generation)
            .. "_"
            .. tostring(runtime.wp7_diagnostic_run)
        local userid_a = "__agon_wp7_a_" .. suffix
        local userid_b = "__agon_wp7_b_" .. suffix
        local userid_c = "__agon_wp7_c_" .. suffix
        local userid_invalid = "__agon_wp7_invalid_" .. suffix
        local userid_unknown = "__agon_wp7_unknown_" .. suffix

        local instance_a, create_a_code = runtime:CreateInstance(
            "TEST_MODE",
            { userid_a, userid_b, userid_c }
        )
        Check(instance_a ~= nil, "create sandbox instance failed: " .. tostring(create_a_code))
        if instance_a == nil then
            return
        end
        table.insert(instances, instance_a)

        local started, start_code = runtime:StartInstance(
            instance_a.instance_id,
            "wp7_diagnostics"
        )
        Check(started and start_code == nil, "start sandbox instance failed: " .. tostring(start_code))
        if not result then
            return
        end

        local sandbox = instance_a:GetService("player_sandbox")
        Check(sandbox ~= nil
            and sandbox.service_id == SandboxService.SERVICE_ID
            and sandbox.adapter_registry ~= nil,
            "PlayerSandbox service was not created per Instance")
        Check(sandbox ~= nil and sandbox:Validate(), "PlayerSandbox adapter registry is invalid")
        if not result then
            return
        end

        local participant_a = instance_a:GetParticipant(userid_a)
        local participant_b = instance_a:GetParticipant(userid_b)
        local participant_c = instance_a:GetParticipant(userid_c)
        local player_a, original_a = MakeTestPlayer(userid_a)
        local player_b, original_b = MakeTestPlayer(userid_b)
        local player_c = MakeTestPlayer(userid_c)

        local attached_a, attach_a_code = runtime.instance_manager:AttachPlayer(
            instance_a.instance_id,
            userid_a,
            player_a
        )
        local attached_b, attach_b_code = runtime.instance_manager:AttachPlayer(
            instance_a.instance_id,
            userid_b,
            player_b
        )
        local attached_c, attach_c_code = runtime.instance_manager:AttachPlayer(
            instance_a.instance_id,
            userid_c,
            player_c
        )
        Check(attached_a and attached_b and attached_c,
            "sandbox players could not attach: "
                .. tostring(attach_a_code) .. "/"
                .. tostring(attach_b_code) .. "/"
                .. tostring(attach_c_code))
        if not result then
            return
        end

        local transaction_a = sandbox:GetTransactionObject(participant_a)
        local transaction_b = sandbox:GetTransactionObject(participant_b)
        local transaction_c = sandbox:GetTransactionObject(participant_c)
        Check(transaction_a ~= nil and transaction_a.state == SandboxService.STATES.SANDBOXED
            and transaction_b ~= nil and transaction_b.state == SandboxService.STATES.SANDBOXED
            and transaction_c ~= nil and transaction_c.state == SandboxService.STATES.SANDBOXED,
            "participants did not enter SANDBOXED state")
        Check(participant_a:GetSandboxTransactionId() == transaction_a.transaction_id
            and participant_b:GetSandboxTransactionId() == transaction_b.transaction_id
            and participant_c:GetSandboxTransactionId() == transaction_c.transaction_id
            and transaction_a.transaction_id ~= transaction_b.transaction_id,
            "sandbox transaction IDs were not stable and unique")

        local sandbox_state_a = player_a.agon_sandbox_state
        Check(sandbox_state_a.inventory.slots[1].prefab == "test_mode_token"
            and sandbox_state_a.inventory.equipment.body == nil
            and sandbox_state_a.inventory.active_item == nil,
            "unified inventory Profile was not applied")
        Check(sandbox_state_a.survival_stats.health.current == 150
            and sandbox_state_a.survival_stats.health.max == 150
            and sandbox_state_a.survival_stats.hunger.current == 150
            and sandbox_state_a.survival_stats.sanity.current == 200
            and sandbox_state_a.survival_stats.temperature.current == 25
            and sandbox_state_a.survival_stats.moisture.current == 0,
            "unified survival Stats Profile was not applied")
        Check(HasOnlySkill(
            sandbox_state_a.skilltree.activated_skills,
            "test_mode_unified_skill"
        ) and sandbox_state_a.skilltree.xp == 0,
            "original skill tree leaked into sandbox")
        Check(sandbox_state_a.character.appearance.skin == "wp7_test_skin"
            and sandbox_state_a.character.abilities.allowed[1] == "test_mode_unified_ability"
            and sandbox_state_a.character.abilities.disabled[1] == "original_character_ability"
            and player_a.agon_sandbox_state.movement_speed == 1.25,
            "character Profile did not preserve appearance and apply abilities")

        local restored_a, restore_a_code = sandbox:RestoreOriginal(
            participant_a,
            nil,
            "wp7_normal_exit"
        )
        Check(restored_a and restore_a_code == nil,
            "normal sandbox restore failed: " .. tostring(restore_a_code))
        Check(transaction_a.state == SandboxService.STATES.COMMITTED
            and Util.DeepEqual(player_a.agon_sandbox_state, original_a),
            "normal restore did not recover the complete original player state")
        local repeated_a, repeated_a_code = sandbox:RestoreOriginal(
            participant_a,
            nil,
            "wp7_idempotent_exit"
        )
        Check(repeated_a and repeated_a_code == "ALREADY_COMMITTED"
            and Util.DeepEqual(player_a.agon_sandbox_state, original_a),
            "repeated restore was not idempotent")

        local transaction_b_id = transaction_b.transaction_id
        player_b.agon_sandbox_test = false
        player_b.agon_sandbox_state = nil
        local failed_b, failed_b_code = sandbox:RestoreOriginal(
            participant_b,
            nil,
            "wp7_injected_restore_failure"
        )
        Check(not failed_b and transaction_b.state == SandboxService.STATES.RESTORE_BLOCKED
            and failed_b_code ~= nil,
            "injected restore failure did not remain inspectable")
        player_b.agon_sandbox_test = true
        player_b.agon_sandbox_state = Util.CopyData(original_b)
        local retried_b, retried_b_code = sandbox:RetryRestore(participant_b, player_b)
        local retry_state_equal = Util.DeepEqual(player_b.agon_sandbox_state, original_b)
        local retry_inventory_equal = Util.DeepEqual(
            player_b.agon_sandbox_state.inventory,
            original_b.inventory
        )
        local retry_stats_equal = Util.DeepEqual(
            player_b.agon_sandbox_state.survival_stats,
            original_b.survival_stats
        )
        local retry_skilltree_equal = Util.DeepEqual(
            player_b.agon_sandbox_state.skilltree,
            original_b.skilltree
        )
        local retry_character_equal = Util.DeepEqual(
            player_b.agon_sandbox_state.character,
            original_b.character
        )
        local retry_speed_equal = player_b.agon_sandbox_state.movement_speed
            == original_b.movement_speed
        Check(retried_b and retried_b_code == nil
            and transaction_b.state == SandboxService.STATES.COMMITTED
            and transaction_b.transaction_id == transaction_b_id
            and transaction_b.restore_attempts == 2
            and retry_state_equal,
            "same transaction restore retry was not idempotent result="
                .. tostring(retried_b)
                .. " code=" .. tostring(retried_b_code)
                .. " state=" .. tostring(transaction_b.state)
                .. " attempts=" .. tostring(transaction_b.restore_attempts)
                .. " equal=" .. tostring(retry_state_equal)
                .. " inventory=" .. tostring(retry_inventory_equal)
                .. " stats=" .. tostring(retry_stats_equal)
                .. " skilltree=" .. tostring(retry_skilltree_equal)
                .. " character=" .. tostring(retry_character_equal)
                .. " speed=" .. tostring(retry_speed_equal))
        Check(player_b.agon_sandbox_state.inventory.slots[1].prefab == "wp7_original_food"
            and player_b.agon_sandbox_state.inventory.slots[1].prefab ~= "test_mode_token",
            "restore retry duplicated a temporary item")

        -- C 玩家故意在 Instance 销毁前失去可恢复状态，验证失败不会阻塞 Zone 清理。
        player_c.agon_sandbox_test = false
        player_c.agon_sandbox_state = nil
        local destroyed_a, destroyed_a_code = runtime:DestroyInstance(
            instance_a.instance_id,
            "wp7_failure_isolation"
        )
        Check(destroyed_a and destroyed_a_code == "INSTANCE_DESTROYED",
            "one player restore failure blocked Instance cleanup: " .. tostring(destroyed_a_code))
        local transaction_c_after = sandbox:GetTransactionObject(participant_c)
        Check(transaction_c_after ~= nil
            and transaction_c_after.state == SandboxService.STATES.RESTORE_BLOCKED
            and runtime.instance_manager:Get(instance_a.instance_id) == nil,
            "failed player transaction was not retained independently of Zone cleanup")

        local instance_b, create_b_code = runtime:CreateInstance(
            "TEST_MODE",
            { userid_invalid }
        )
        Check(instance_b ~= nil, "create invalid snapshot instance failed: " .. tostring(create_b_code))
        if instance_b == nil then
            return
        end
        table.insert(instances, instance_b)
        local started_b, started_b_code = runtime:StartInstance(
            instance_b.instance_id,
            "wp7_invalid_snapshot"
        )
        Check(started_b and started_b_code == nil, "start invalid snapshot instance failed")
        if not result then
            return
        end
        local invalid_player, invalid_original = MakeTestPlayer(userid_invalid, true)
        local invalid_participant = instance_b:GetParticipant(userid_invalid)
        local invalid_attached, invalid_attach_code = runtime.instance_manager:AttachPlayer(
            instance_b.instance_id,
            userid_invalid,
            invalid_player
        )
        Check(not invalid_attached
            and invalid_attach_code == "SKILLTREE_SNAPSHOT_INVALID"
            and invalid_participant:GetState() == "DISCONNECTED"
            and Util.DeepEqual(invalid_player.agon_sandbox_state, invalid_original),
            "invalid skilltree snapshot was not rejected before clean state")
        local removed_invalid, removed_invalid_code = runtime.instance_manager:RemoveParticipant(
            instance_b.instance_id,
            userid_invalid,
            "wp7_invalid_snapshot_rejected"
        )
        Check(removed_invalid and removed_invalid_code == nil,
            "rejected participant could not leave cleanly")

        local unknown_participant, unknown_add_code = runtime.instance_manager:AddParticipant(
            instance_b.instance_id,
            userid_unknown
        )
        Check(unknown_participant ~= nil,
            "unknown character participant could not be added: " .. tostring(unknown_add_code))
        if unknown_participant == nil then
            return
        end
        local unknown_player, unknown_original = MakeTestPlayer(userid_unknown)
        unknown_player.agon_sandbox_state.character.prefab = "wp7_unknown_character"
        unknown_original.character.prefab = "wp7_unknown_character"
        local unknown_attached, unknown_attach_code = runtime.instance_manager:AttachPlayer(
            instance_b.instance_id,
            userid_unknown,
            unknown_player
        )
        Check(not unknown_attached
            and unknown_attach_code == StateAdapterRegistry.ERROR_CODES.INVALID_CHARACTER
            and unknown_participant:GetState() == "DISCONNECTED"
            and Util.DeepEqual(unknown_player.agon_sandbox_state, unknown_original),
            "unknown character was not rejected before clean state: "
                .. tostring(unknown_attach_code))
        local removed_unknown, removed_unknown_code = runtime.instance_manager:RemoveParticipant(
            instance_b.instance_id,
            userid_unknown,
            "wp7_unknown_character_rejected"
        )
        Check(removed_unknown and removed_unknown_code == nil,
            "rejected unknown character participant could not leave cleanly")
    end)

    local cleaned = Cleanup(runtime, instances)
    if not ok then
        result = false
        failure = "WP7 diagnostic exception: " .. tostring(execution_error)
    elseif not cleaned then
        result = false
        failure = failure or "WP7 diagnostic cleanup failed"
    end
    if not result then
        return false, failure
    end
    local valid, valid_code = runtime:ValidateCore()
    if not valid then
        return false, "core invalid after WP7 diagnostics: " .. tostring(valid_code)
    end
    return true
end

return Wp7Diagnostics
