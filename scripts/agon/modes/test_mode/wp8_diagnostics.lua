-- WP8：Lobby、Spectator 和 Instance-aware DeathPolicy 的服务端合成验收。

local Util = require("agon/player/adapters/util")
local DeathPolicy = require("agon/player/death_policy")
local Participant = require("agon/core/participant")

local Wp8Diagnostics = {}

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function Require(condition, message)
    if not condition then
        return false, message
    end
    return true
end

local function MakeTestPlayer(userid, name)
    local state =
    {
        inventory =
        {
            slots =
            {
                [1] = { prefab = "wp8_original_food", count = 3 },
                [2] =
                {
                    prefab = "wp8_original_container",
                    contents = { [1] = { prefab = "wp8_nested_item", count = 2 } },
                },
            },
            equipment =
            {
                body = { prefab = "wp8_original_backpack" },
                hands = { prefab = "wp8_original_tool" },
            },
            active_item = { prefab = "wp8_original_active" },
            containers =
            {
                external = { slots = { [1] = { prefab = "wp8_external_item" } } },
            },
        },
        survival_stats =
        {
            health = { current = 73, max = 100, penalty = 0.1, invincible = false },
            hunger = { current = 61, max = 100 },
            sanity = { current = 42, max = 100, mode = 0, sane = true },
            temperature = { current = 18 },
            moisture = { current = 12, max = 100 },
            temporary = { wp8_buff = "original" },
        },
        skilltree =
        {
            handshake_complete = true,
            xp = 321,
            points = 2,
            activated_skills = { "wp8_original_skill_a", "wp8_original_skill_b" },
            selection = { 3, 5 },
            encoded_data = "wp8_original_skill_blob",
            character_prefab = "wilson",
        },
        character =
        {
            prefab = "wilson",
            appearance = { skin = "wp8_test_skin", build = "wp8_test_build" },
            resources = { character_meter = 8, sanity_boost = 4 },
            followers = { "wp8_follower" },
            pets = { "wp8_pet" },
            summoned = { "wp8_summoned" },
            components = { character_component = "original" },
            abilities = { "original_character_ability" },
            movement_speed = 1,
        },
        movement_speed = 1,
    }
    local player =
    {
        userid = userid,
        name = name or userid,
        prefab = "wilson",
        agon_sandbox_test = true,
        agon_sandbox_state = state,
        tags = {},
    }
    function player:IsValid()
        return true
    end
    function player:AddTag(tag)
        self.tags[tag] = true
    end
    function player:RemoveTag(tag)
        self.tags[tag] = nil
    end
    function player:HasTag(tag)
        return self.tags[tag] == true
    end
    function player:GetDisplayName()
        return self.name
    end
    return player, Util.CopyData(state)
end

local function Cleanup(runtime, instances, spectators)
    local all_clean = true
    for index = #(spectators or {}), 1, -1 do
        local player = spectators[index]
        if player ~= nil and runtime.spectator_service:GetSession(player.userid) ~= nil then
            local exited = runtime:ExitSpectator(player, "wp8_diagnostics_cleanup")
            if not exited then
                all_clean = false
            end
        end
    end
    for index = #instances, 1, -1 do
        local instance = instances[index]
        if instance ~= nil
            and runtime.instance_manager:Get(instance.instance_id) ~= nil then
            local destroyed = runtime:DestroyInstance(
                instance.instance_id,
                "wp8_diagnostics_cleanup"
            )
            if not destroyed then
                all_clean = false
            end
        end
    end
    return all_clean
end

function Wp8Diagnostics.Run(runtime)
    if runtime == nil or not runtime:IsReady()
        or runtime.instance_manager == nil
        or runtime.lobby_service == nil
        or runtime.spectator_service == nil then
        return false, "WP8 runtime services are not ready"
    end

    local instances = {}
    local spectators = {}
    local result = true
    local failure = nil
    local function Check(condition, message)
        if result then
            result, failure = Require(condition, message)
        end
    end

    local ok, execution_error = ProtectedCall(function()
        runtime.wp8_diagnostic_run = (runtime.wp8_diagnostic_run or 0) + 1
        local suffix = tostring(runtime.boot_generation)
            .. "_" .. tostring(runtime.wp8_diagnostic_run)
        local ghost_userid = "__agon_wp8_ghost_" .. suffix
        local corpse_userid = "__agon_wp8_corpse_" .. suffix
        local reviver_userid = "__agon_wp8_reviver_" .. suffix
        local observer_userid = "__agon_wp8_observer_" .. suffix
        local observer_two_userid = "__agon_wp8_observer_two_" .. suffix

        local instance_a, create_a_code = runtime:CreateInstance(
            "TEST_MODE",
            { ghost_userid },
            { death_mode = DeathPolicy.MODES.GHOST }
        )
        local instance_b, create_b_code = runtime:CreateInstance(
            "TEST_MODE",
            { corpse_userid, reviver_userid },
            { death_mode = DeathPolicy.MODES.REVIVABLE_CORPSE }
        )
        Check(instance_a ~= nil and instance_b ~= nil,
            "create concurrent WP8 instances failed: "
                .. tostring(create_a_code) .. "/" .. tostring(create_b_code))
        if instance_a == nil or instance_b == nil then
            return
        end
        table.insert(instances, instance_a)
        table.insert(instances, instance_b)

        local started_a, start_a_code = runtime:StartInstance(
            instance_a.instance_id,
            "wp8_diagnostics_ghost"
        )
        local started_b, start_b_code = runtime:StartInstance(
            instance_b.instance_id,
            "wp8_diagnostics_corpse"
        )
        Check(started_a and started_b,
            "start concurrent WP8 instances failed: "
                .. tostring(start_a_code) .. "/" .. tostring(start_b_code))
        if not result then
            return
        end

        local ghost_player, ghost_original = MakeTestPlayer(ghost_userid, "WP8 Ghost")
        local corpse_player, corpse_original = MakeTestPlayer(corpse_userid, "WP8 Corpse")
        local reviver_player, reviver_original = MakeTestPlayer(reviver_userid, "WP8 Reviver")
        local observer, observer_original = MakeTestPlayer(observer_userid, "WP8 Observer")
        local observer_two = MakeTestPlayer(observer_two_userid, "WP8 Observer Two")
        table.insert(spectators, observer)
        table.insert(spectators, observer_two)

        local ghost_participant = instance_a:GetParticipant(ghost_userid)
        local corpse_participant = instance_b:GetParticipant(corpse_userid)
        local reviver_participant = instance_b:GetParticipant(reviver_userid)
        local attached_ghost = runtime.instance_manager:AttachPlayer(
            instance_a.instance_id,
            ghost_userid,
            ghost_player
        )
        local attached_corpse = runtime.instance_manager:AttachPlayer(
            instance_b.instance_id,
            corpse_userid,
            corpse_player
        )
        local attached_reviver = runtime.instance_manager:AttachPlayer(
            instance_b.instance_id,
            reviver_userid,
            reviver_player
        )
        Check(attached_ghost and attached_corpse and attached_reviver,
            "WP8 synthetic participants could not attach")
        if not result then
            return
        end
        ghost_participant:TransitionTo(
            Participant.STATES.PLAYING,
            "wp8_diagnostics",
            instance_a.generation
        )
        corpse_participant:TransitionTo(
            Participant.STATES.PLAYING,
            "wp8_diagnostics",
            instance_b.generation
        )
        reviver_participant:TransitionTo(
            Participant.STATES.PLAYING,
            "wp8_diagnostics",
            instance_b.generation
        )

        local ghost_policy = instance_a:GetDeathPolicy()
        local corpse_policy = instance_b:GetDeathPolicy()
        Check(ghost_policy ~= nil
            and corpse_policy ~= nil
            and ghost_policy:GetDeathMode() == DeathPolicy.MODES.GHOST
            and corpse_policy:GetDeathMode() == DeathPolicy.MODES.REVIVABLE_CORPSE,
            "concurrent instances did not retain independent death policies")

        local lobby_session, lobby_code = runtime:EnterLobby(observer)
        local lobby_session_two, lobby_two_code = runtime:EnterLobby(observer_two)
        Check(lobby_session ~= nil and lobby_session_two ~= nil,
            "synthetic observers could not enter Portal-relative lobby: "
                .. tostring(lobby_code) .. "/" .. tostring(lobby_two_code))
        if not result then
            return
        end
        Check(runtime.instance_manager:GetParticipant(observer.userid) == nil
            and not Util.DeepEqual(observer.agon_sandbox_state, nil)
            and Util.DeepEqual(observer.agon_sandbox_state, observer_original),
            "lobby observer unexpectedly entered Participant/Sandbox state")

        local spectator_session, spectator_code = runtime:EnterSpectator(
            observer,
            instance_a.instance_id
        )
        local spectator_session_two, spectator_two_code = runtime:EnterSpectator(
            observer_two,
            instance_a.instance_id
        )
        Check(spectator_session ~= nil and spectator_session_two ~= nil,
            "spectator entry failed: "
                .. tostring(spectator_code) .. "/" .. tostring(spectator_two_code))
        if not result then
            return
        end
        local echo = spectator_session.echo
        local echo_two = spectator_session_two.echo
        Check(spectator_session.echo_id ~= spectator_session_two.echo_id,
            "spectator echoes were not unique")
        Check(observer.agon_lobby_state == "SPECTATOR_RETURN"
            and observer.is_spectator == true
            and observer.spectating_instance_id == instance_a.instance_id
            and runtime.instance_manager:GetParticipant(observer.userid) == nil,
            "spectator was not separated from Participant/Lobby state")
        local echo_snapshot = spectator_session.echo:GetSnapshot()
        Check(echo_snapshot ~= nil
            and echo_snapshot.echo_id == spectator_session.echo_id
            and echo_snapshot.persists == false
            and echo_snapshot.gameplay == false
            and echo_snapshot.ai == false
            and echo_snapshot.collision == false,
            "spectator echo exposed gameplay capability")
        Check(runtime:CanViewSpectator(observer, instance_a.instance_id)
            and not runtime:CanViewSpectator(observer, instance_b.instance_id),
            "spectator cross-instance view was not rejected")
        local targeted, target_code = runtime.spectator_service:SetTarget(
            observer,
            ghost_player
        )
        local cross_targeted, cross_target_code = runtime.spectator_service:SetTarget(
            observer,
            corpse_player
        )
        Check(targeted and not cross_targeted,
            "spectator target isolation failed: "
                .. tostring(target_code) .. "/" .. tostring(cross_target_code))
        local interaction_allowed, interaction_code = runtime.instance_manager:CanInteract(
            "DAMAGE",
            observer,
            ghost_player,
            { instance_id = instance_a.instance_id }
        )
        Check(not interaction_allowed and interaction_code == "SPECTATOR_GAMEPLAY_FORBIDDEN",
            "spectator gameplay interaction was not rejected")
        Check(Util.DeepEqual(observer.agon_sandbox_state, observer_original),
            "spectator entry modified original player state")

        local exited_two, exited_two_code = runtime:ExitSpectator(
            observer_two,
            "wp8_diagnostics_echo_cleanup"
        )
        Check(exited_two and exited_two_code == nil
            and echo_two.removed == true,
            "second spectator echo did not clean up")
        local exited, exited_code = runtime:ExitSpectator(
            observer,
            "wp8_diagnostics_lobby_return"
        )
        Check(exited and exited_code == nil
            and echo.removed == true
            and observer.is_spectator == nil
            and observer.agon_lobby_state == "LOBBY"
            and Util.DeepEqual(observer.agon_sandbox_state, observer_original),
            "spectator exit did not restore lobby guard/state: " .. tostring(exited_code))

        local ghost_sandbox_before_death = Util.CopyData(ghost_player.agon_sandbox_state)
        local corpse_sandbox_before_death = Util.CopyData(corpse_player.agon_sandbox_state)
        local reviver_sandbox_before_death = Util.CopyData(reviver_player.agon_sandbox_state)

        local ghost_record, ghost_code = ghost_policy:OnPlayerDeath(
            ghost_participant,
            ghost_player,
            { cause = "wp8_diagnostic_ghost" }
        )
        Check(ghost_record ~= nil and ghost_code == nil
            and ghost_participant:GetState() == Participant.STATES.GHOST
            and ghost_participant.death_state == Participant.DEATH_STATES.GHOST
            and ghost_player.agon_death_policy == DeathPolicy.MODES.GHOST,
            "GHOST death policy did not retain Participant death state: "
                .. tostring(ghost_code))
        local ghost_center = instance_a.zone.safe_bounds.min
        local ghost_move_allowed = ghost_policy:CanGhostMove(
            ghost_participant,
            ghost_player,
            ghost_center
        )
        local ghost_moved, ghost_move_code = ghost_policy:MoveGhost(
            ghost_participant,
            ghost_player,
            ghost_center
        )
        local ghost_outside =
        {
            x = instance_a.zone.hard_bounds.max.x + 1,
            z = instance_a.zone.hard_bounds.max.z + 1,
        }
        local ghost_outside_allowed = ghost_policy:CanGhostMove(
            ghost_participant,
            ghost_player,
            ghost_outside
        )
        local ghost_revive_allowed = corpse_policy:CanRevive(
            reviver_participant,
            ghost_participant
        )
        Check(ghost_move_allowed and ghost_moved and ghost_move_code == nil
            and not ghost_outside_allowed
            and not ghost_revive_allowed,
            "GHOST movement/revive boundary failed")

        local corpse_record, corpse_code = corpse_policy:OnPlayerDeath(
            corpse_participant,
            corpse_player,
            { cause = "wp8_diagnostic_corpse" }
        )
        Check(corpse_record ~= nil and corpse_code == nil
            and corpse_participant:GetState() == Participant.STATES.CORPSE
            and corpse_participant.death_state == Participant.DEATH_STATES.CORPSE
            and corpse_player.agon_death_policy == DeathPolicy.MODES.REVIVABLE_CORPSE
            and corpse_player:HasTag("agon_corpse"),
            "REVIVABLE_CORPSE policy did not immobilize a same-instance Participant")
        local corpse_ghost_move = corpse_policy:CanGhostMove(
            corpse_participant,
            corpse_player,
            instance_b.zone.safe_bounds.min
        )
        local can_revive, can_revive_code = corpse_policy:CanRevive(
            reviver_participant,
            corpse_participant
        )
        local cross_revive, cross_revive_code = corpse_policy:CanRevive(
            ghost_participant,
            corpse_participant
        )
        Check(not corpse_ghost_move and can_revive and can_revive_code == nil
            and not cross_revive,
            "REVIVABLE_CORPSE movement/cross-instance revive boundary failed: "
                .. tostring(cross_revive_code))
        local revive_session, begin_code = corpse_policy:BeginRevive(
            reviver_participant,
            corpse_participant
        )
        local revived, complete_code = corpse_policy:CompleteRevive(revive_session)
        Check(revive_session ~= nil and begin_code == nil
            and revived and complete_code == nil
            and corpse_participant:GetState() == Participant.STATES.PLAYING
            and corpse_participant.death_state == Participant.DEATH_STATES.ALIVE
            and corpse_player.agon_death_state == nil
            and not corpse_player:HasTag("agon_corpse"),
            "same-instance corpse revive did not complete: " .. tostring(complete_code))
        local duplicate_revive = corpse_policy:CanRevive(
            reviver_participant,
            corpse_participant
        )
        local repeated_complete, repeated_complete_code = corpse_policy:CompleteRevive(
            revive_session
        )
        Check(not duplicate_revive and not repeated_complete
            and repeated_complete_code == "DEATH_POLICY_REVIVE_NOT_FOUND",
            "corpse revive was not idempotently closed")
        Check(Util.DeepEqual(ghost_player.agon_sandbox_state, ghost_sandbox_before_death)
            and Util.DeepEqual(corpse_player.agon_sandbox_state, corpse_sandbox_before_death)
            and Util.DeepEqual(reviver_player.agon_sandbox_state, reviver_sandbox_before_death),
            "death policy changed sandbox state unexpectedly")

        local destroyed_a, destroyed_a_code = runtime:DestroyInstance(
            instance_a.instance_id,
            "wp8_diagnostics_destroy_ghost"
        )
        local destroyed_b, destroyed_b_code = runtime:DestroyInstance(
            instance_b.instance_id,
            "wp8_diagnostics_destroy_corpse"
        )
        Check(destroyed_a and destroyed_b
            and destroyed_a_code == "INSTANCE_DESTROYED"
            and destroyed_b_code == "INSTANCE_DESTROYED",
            "WP8 Instance cleanup failed: "
                .. tostring(destroyed_a_code) .. "/" .. tostring(destroyed_b_code))
        local ghost_transaction = instance_a:GetService("player_sandbox")
            :GetTransactionObject(ghost_participant)
        local corpse_transaction = instance_b:GetService("player_sandbox")
            :GetTransactionObject(corpse_participant)
        local reviver_transaction = instance_b:GetService("player_sandbox")
            :GetTransactionObject(reviver_participant)
        Check(ghost_transaction ~= nil
            and corpse_transaction ~= nil
            and reviver_transaction ~= nil
            and ghost_transaction.state == "COMMITTED"
            and corpse_transaction.state == "COMMITTED"
            and reviver_transaction.state == "COMMITTED"
            and Util.DeepEqual(ghost_player.agon_sandbox_state, ghost_original)
            and Util.DeepEqual(corpse_player.agon_sandbox_state, corpse_original)
            and Util.DeepEqual(reviver_player.agon_sandbox_state, reviver_original),
            "Instance destroy did not restore every death-policy player sandbox")
    end)

    local cleaned = Cleanup(runtime, instances, spectators)
    if not ok then
        result = false
        failure = "WP8 diagnostic exception: " .. tostring(execution_error)
    elseif not cleaned then
        result = false
        failure = failure or "WP8 diagnostic cleanup failed"
    end
    if not result then
        return false, failure
    end
    local valid, valid_code = runtime:ValidateCore()
    if not valid then
        return false, "core invalid after WP8 diagnostics: " .. tostring(valid_code)
    end
    return true
end

return Wp8Diagnostics
