-- WP5：TestMode 的分组、阶段、时钟、Decision、Effect 和 Score 验收。
-- 该模块只使用临时 TestMode Instance，完成后一定销毁并释放 Zone。

local InstanceRng = require("agon/core/instance_rng")
local AudienceStateChannel = require("agon/net/audience_state_channel")
local CommonServiceRegistry = require("agon/services/common_service_registry")
local DecisionService = require("agon/services/decision_service")
local ScoreLedger = require("agon/services/score_ledger")

local Wp5Diagnostics = {}

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function MakeTestPlayer(userid)
    return
    {
        userid = userid,
        agon_sandbox_test = true,
        agon_sandbox_state =
        {
            inventory =
            {
                slots =
                {
                    [1] = { prefab = "test_original_food", count = 3 },
                    [2] =
                    {
                        prefab = "test_original_bag",
                        contents = { [1] = { prefab = "test_nested_item", count = 2 } },
                    },
                },
                equipment =
                {
                    body = { prefab = "test_original_backpack" },
                    hands = { prefab = "test_original_tool" },
                },
                active_item = { prefab = "test_original_active" },
                containers = { test_container = { slots = { [1] = { prefab = "test_container_item" } } } },
            },
            survival_stats =
            {
                health = { current = 73, max = 100, penalty = 0.1, invincible = false },
                hunger = { current = 61, max = 100 },
                sanity = { current = 42, max = 100, mode = 0, sane = true },
                temperature = { current = 18 },
                moisture = { current = 12, max = 100 },
                temporary = { buff = "test_buff" },
            },
            skilltree =
            {
                handshake_complete = true,
                xp = 321,
                points = 2,
                activated_skills = { "original_skill_a", "original_skill_b" },
                selection = { 3, 5 },
                encoded_data = "original_skill_blob",
                character_prefab = "wilson",
            },
            character =
            {
                prefab = "wilson",
                appearance = { skin = "test_skin", build = "test_build" },
                resources = { sanity_boost = 4, character_meter = 8 },
                followers = { "test_follower" },
                pets = { "test_pet" },
                summoned = { "test_summoned" },
                components = { character_component = "original" },
                abilities = { "original_character_ability" },
                movement_speed = 1,
            },
            movement_speed = 1,
        },
        IsValid = function()
            return true
        end,
    }
end

local function Cleanup(runtime, instances)
    local all_clean = true
    for index = #instances, 1, -1 do
        local instance = instances[index]
        if instance ~= nil
            and runtime.instance_manager:Get(instance.instance_id) ~= nil then
            local destroyed = runtime.instance_manager:Destroy(
                instance.instance_id,
                "wp5_diagnostics_cleanup"
            )
            if not destroyed then
                all_clean = false
            end
        end
    end
    return all_clean
end

local function HasState(records, state_id)
    for index = 1, #records do
        if records[index].state_id == state_id then
            return true
        end
    end
    return false
end

local function Require(condition, message)
    if not condition then
        return false, message
    end
    return true
end

local function CountServices(instance)
    local services = instance:ListServices()
    local found = {}
    for index = 1, #services do
        found[services[index]] = true
    end
    return found, #services
end

function Wp5Diagnostics.Run(runtime)
    if runtime == nil or not runtime:IsReady()
        or runtime.instance_manager == nil
        or runtime.audience_state_channel == nil
        or runtime.common_service_registry == nil then
        return false, "WP5 runtime services are not ready"
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
        runtime.wp5_diagnostic_run = (runtime.wp5_diagnostic_run or 0) + 1
        local suffix = tostring(runtime.boot_generation)
            .. "_"
            .. tostring(runtime.wp5_diagnostic_run)
        local userid_a1 = "__agon_wp5_a1_" .. suffix
        local userid_a2 = "__agon_wp5_a2_" .. suffix
        local userid_b1 = "__agon_wp5_b1_" .. suffix
        local userid_b2 = "__agon_wp5_b2_" .. suffix

        local invalid_service, invalid_service_code =
            CommonServiceRegistry.ValidateDeclarations({ "missing_service" })
        local duplicate_service, duplicate_service_code =
            CommonServiceRegistry.ValidateDeclarations({ "phase", "phase" })
        local missing_dependency, missing_dependency_code =
            CommonServiceRegistry.ValidateDeclarations({ "decision" })
        local invalid_version, invalid_version_code =
            CommonServiceRegistry.ValidateDeclarations(
            {
                { service_id = "phase", version = 2 },
            })
        local valid_declarations, valid_declarations_code =
            CommonServiceRegistry.ValidateDeclarations({ "phase", "decision" })
        Check(invalid_service == nil
            and invalid_service_code == CommonServiceRegistry.ERROR_CODES.UNKNOWN_SERVICE,
            "unknown service declaration was accepted")
        Check(duplicate_service == nil
            and duplicate_service_code == CommonServiceRegistry.ERROR_CODES.DUPLICATE_SERVICE,
            "duplicate service declaration was accepted")
        Check(missing_dependency == nil
            and missing_dependency_code == CommonServiceRegistry.ERROR_CODES.SERVICE_DEPENDENCY_MISSING,
            "missing service dependency was accepted")
        Check(invalid_version == nil
            and invalid_version_code == CommonServiceRegistry.ERROR_CODES.INVALID_VERSION,
            "unknown service version was accepted")
        Check(valid_declarations ~= nil and valid_declarations_code == nil,
            "valid service declarations were rejected")

        local instance_a, create_a_code = runtime:CreateInstance(
            "TEST_MODE",
            { userid_a1, userid_a2 }
        )
        Check(instance_a ~= nil, "create instance A failed: " .. tostring(create_a_code))
        if not result then
            return
        end
        table.insert(instances, instance_a)

        local instance_b, create_b_code = runtime:CreateInstance(
            "TEST_MODE",
            { userid_b1, userid_b2 }
        )
        Check(instance_b ~= nil, "create instance B failed: " .. tostring(create_b_code))
        if not result then
            return
        end
        table.insert(instances, instance_b)

        local services_a, service_count_a = CountServices(instance_a)
        local services_b, service_count_b = CountServices(instance_b)
        Check(service_count_a == 7 and service_count_b == 7
            and services_a.phase and services_a.clock
            and services_a.decision and services_a.effects and services_a.score
            and services_a.entity_profiles and services_a.player_sandbox
            and services_b.phase and services_b.clock
            and services_b.decision and services_b.effects and services_b.score
            and services_b.entity_profiles and services_b.player_sandbox,
            "declared Common Services were not isolated per Instance")

        local started_a, start_a_code = runtime:StartInstance(
            instance_a.instance_id,
            "wp5_diagnostics"
        )
        local started_b, start_b_code = runtime:StartInstance(
            instance_b.instance_id,
            "wp5_diagnostics"
        )
        Check(started_a, "start instance A failed: " .. tostring(start_a_code))
        Check(started_b, "start instance B failed: " .. tostring(start_b_code))
        if not result then
            return
        end

        local participant_a1 = instance_a:GetParticipant(userid_a1)
        local participant_a2 = instance_a:GetParticipant(userid_a2)
        local participant_b1 = instance_b:GetParticipant(userid_b1)
        local participant_b2 = instance_b:GetParticipant(userid_b2)
        local attached_a1 = runtime.instance_manager:AttachPlayer(
            instance_a.instance_id,
            userid_a1,
            MakeTestPlayer(userid_a1)
        )
        local attached_a2 = runtime.instance_manager:AttachPlayer(
            instance_a.instance_id,
            userid_a2,
            MakeTestPlayer(userid_a2)
        )
        local attached_b1 = runtime.instance_manager:AttachPlayer(
            instance_b.instance_id,
            userid_b1,
            MakeTestPlayer(userid_b1)
        )
        local attached_b2 = runtime.instance_manager:AttachPlayer(
            instance_b.instance_id,
            userid_b2,
            MakeTestPlayer(userid_b2)
        )
        Check(attached_a1 and attached_a2 and attached_b1 and attached_b2,
            "TestMode participants could not attach")
        if not result then
            return
        end
        participant_a1:TransitionTo("PLAYING", "wp5_diagnostics", instance_a.generation)
        participant_a2:TransitionTo("PLAYING", "wp5_diagnostics", instance_a.generation)
        participant_b1:TransitionTo("PLAYING", "wp5_diagnostics", instance_b.generation)
        participant_b2:TransitionTo("PLAYING", "wp5_diagnostics", instance_b.generation)

        local group_a = instance_a.mode_runtime:GetGroup()
        local group_b = instance_b.mode_runtime:GetGroup()
        Check(group_a ~= nil and group_b ~= nil
            and group_a:GetType() == "COOP_TEST"
            and group_b:GetType() == "COOP_TEST"
            and group_a:HasMember(userid_a1)
            and group_a:HasMember(userid_a2)
            and group_b:HasMember(userid_b1),
            "TestMode Group was not created with Instance members")
        local cross_member, cross_member_code = group_a:AddMember(participant_b1)
        Check(cross_member == false
            and cross_member_code == "GROUP_PARTICIPANT_INSTANCE_MISMATCH",
            "cross Instance Group member was accepted")
        Check(participant_a1:HasGroup(group_a:GetId())
            and not participant_b1:HasGroup(group_a:GetId()),
            "Participant Group membership leaked across Instance")

        local phase_a = instance_a:GetService("phase")
        local phase_b = instance_b:GetService("phase")
        local current_phase_a = phase_a:GetCurrentPhase()
        local current_phase_b = phase_b:GetCurrentPhase()
        Check(current_phase_a ~= nil and current_phase_a.state == "ACTIVE"
            and current_phase_b ~= nil and current_phase_b.state == "ACTIVE",
            "TestMode phase did not enter ACTIVE")
        local phase_scope_a = phase_a:GetCurrentScope()
        local task_a, task_code_a = phase_a:DoTaskInTime(60, function() end)
        local event_a, event_code_a = phase_a:ListenForEvent(
            "ms_playerjoined",
            function() end
        )
        Check(task_a ~= nil and task_code_a == nil
            and event_a ~= nil and event_code_a == nil
            and phase_scope_a:GetResourceCount() >= 2,
            "Phase resources were not registered in PhaseScope")

        local clock_a = instance_a:GetService("clock")
        local clock_b = instance_b:GetService("clock")
        local timer_a, timer_a_code = clock_a:Create(
            "wp5.timer",
            {
                duration = 120,
                phase_revision = phase_a:GetCurrentRevision(),
            }
        )
        local timer_b, timer_b_code = clock_b:Create(
            "wp5.timer",
            {
                duration = 120,
                phase_revision = phase_b:GetCurrentRevision(),
            }
        )
        Check(timer_a ~= nil and timer_a_code == nil
            and timer_b ~= nil and timer_b_code == nil,
            "Instance Clock could not create semantic deadlines")
        local paused_a, paused_a_code = clock_a:Pause(
            "wp5.timer",
            nil,
            phase_a:GetCurrentRevision()
        )
        local remaining_b = clock_b:GetRemaining("wp5.timer")
        Check(paused_a and paused_a_code == nil
            and clock_a:IsPaused("wp5.timer")
            and not clock_b:IsPaused("wp5.timer")
            and remaining_b ~= nil and remaining_b > 0,
            "pausing Instance A Clock affected Instance B")

        local channel = runtime.audience_state_channel
        local group_state_id = "wp5.group." .. suffix
        local group_record, group_record_code = channel:Publish(
            group_state_id,
            AudienceStateChannel.Group(group_a:GetId()),
            { group_value = "A" },
            { instance_id = instance_a.instance_id }
        )
        local group_visible_a = channel:ReadFor(userid_a1)
        local group_visible_b = channel:ReadFor(userid_b1)
        Check(group_record ~= nil and group_record_code == nil
            and HasState(group_visible_a, group_state_id)
            and not HasState(group_visible_b, group_state_id),
            "GROUP audience state crossed Instance boundary")

        local decision_service_a = instance_a:GetService("decision")
        local decision_service_b = instance_b:GetService("decision")
        local decision_a, decision_a_code = instance_a.mode_runtime:CreateGroupVote(
            "wp5.vote." .. suffix,
            { "RED", "BLUE" },
            { phase_revision = phase_a:GetCurrentRevision() }
        )
        Check(decision_a ~= nil and decision_a_code == nil,
            "Group Decision could not be created")
        local vote_a1, vote_a1_code = decision_service_a:Vote(
            decision_a.decision_id,
            userid_a1,
            "RED",
            {
                request_id = "wp5.vote.request.a1." .. suffix,
                phase_revision = phase_a:GetCurrentRevision(),
            }
        )
        local vote_a2, vote_a2_code = decision_service_a:Vote(
            decision_a.decision_id,
            userid_a2,
            "BLUE",
            {
                request_id = "wp5.vote.request.a2." .. suffix,
                phase_revision = phase_a:GetCurrentRevision(),
            }
        )
        local ineligible_vote, ineligible_vote_code = decision_service_a:Vote(
            decision_a.decision_id,
            userid_b1,
            "RED",
            { request_id = "wp5.vote.request.b1." .. suffix }
        )
        local duplicate_request, duplicate_request_code = decision_service_a:Vote(
            decision_a.decision_id,
            userid_a1,
            "RED",
            { request_id = "wp5.vote.request.a1." .. suffix }
        )
        local duplicate_vote, duplicate_vote_code = decision_service_a:Vote(
            decision_a.decision_id,
            userid_a1,
            "BLUE",
            { request_id = "wp5.vote.request.a1.change." .. suffix }
        )
        Check(vote_a1 and vote_a1_code == nil and vote_a2 and vote_a2_code == nil
            and ineligible_vote == false
            and ineligible_vote_code == DecisionService.ERROR_CODES.VOTER_NOT_ELIGIBLE
            and duplicate_request == false
            and duplicate_request_code == DecisionService.ERROR_CODES.DUPLICATE_REQUEST
            and duplicate_vote == false
            and duplicate_vote_code == DecisionService.ERROR_CODES.DUPLICATE_VOTE,
            "Decision voter eligibility or idempotency validation failed")

        local tie_rng = InstanceRng.New("wp5-tie-seed-" .. suffix)
        local tie_rng_code = tie_rng == nil and "RNG_CREATE_FAILED" or nil
        Check(tie_rng ~= nil and tie_rng_code == nil,
            "tie RNG could not be created")
        if not result then
            return
        end
        tie_rng:Random("loot")
        tie_rng:Random("scene")
        instance_a.rng = tie_rng
        local tie_snapshot = tie_rng:GetSnapshot()
        local loot_counter_before = tie_rng:GetStreamCounter("loot")
        local scene_counter_before = tie_rng:GetStreamCounter("scene")
        local decision_counter_before = tie_rng:GetStreamCounter("decision")
        local tie_one, tie_one_code = instance_a.mode_runtime:CreateGroupVote(
            "wp5.tie.one." .. suffix,
            { "LEFT", "RIGHT" },
            { phase_revision = phase_a:GetCurrentRevision() }
        )
        local tie_one_a = decision_service_a:Vote(
            tie_one.decision_id,
            userid_a1,
            "LEFT",
            { request_id = "wp5.tie.one.a1." .. suffix }
        )
        local tie_one_b = decision_service_a:Vote(
            tie_one.decision_id,
            userid_a2,
            "RIGHT",
            { request_id = "wp5.tie.one.a2." .. suffix }
        )
        local resolved_one, result_one, resolved_one_code = decision_service_a:Resolve(
            tie_one.decision_id,
            { phase_revision = phase_a:GetCurrentRevision() }
        )
        Check(tie_one ~= nil and tie_one_code == nil
            and tie_one_a and tie_one_b
            and resolved_one and result_one ~= nil and resolved_one_code == nil,
            "tie Decision could not resolve")
        local loot_counter_after = instance_a.rng:GetStreamCounter("loot")
        local scene_counter_after = instance_a.rng:GetStreamCounter("scene")
        local decision_counter_after = instance_a.rng:GetStreamCounter("decision")
        instance_a.rng = InstanceRng.FromSnapshot(tie_snapshot)
        local tie_two, tie_two_code = instance_a.mode_runtime:CreateGroupVote(
            "wp5.tie.two." .. suffix,
            { "LEFT", "RIGHT" },
            { phase_revision = phase_a:GetCurrentRevision() }
        )
        decision_service_a:Vote(
            tie_two.decision_id,
            userid_a1,
            "LEFT",
            { request_id = "wp5.tie.two.a1." .. suffix }
        )
        decision_service_a:Vote(
            tie_two.decision_id,
            userid_a2,
            "RIGHT",
            { request_id = "wp5.tie.two.a2." .. suffix }
        )
        local resolved_two, result_two, resolved_two_code = decision_service_a:Resolve(
            tie_two.decision_id,
            { phase_revision = phase_a:GetCurrentRevision() }
        )
        Check(tie_two ~= nil and tie_two_code == nil
            and resolved_two and result_two ~= nil and resolved_two_code == nil
            and result_one.option_id == result_two.option_id
            and loot_counter_after == loot_counter_before
            and scene_counter_after == scene_counter_before
            and decision_counter_after == decision_counter_before + 1,
            "Decision tie RNG was not reproducible or consumed another stream")

        local effects_a = instance_a:GetService("effects")
        local effects_b = instance_b:GetService("effects")
        local effect_a, effect_a_code = effects_a:Apply(
            "wp5.effect.a." .. suffix,
            {
                handler_id = "test_counter",
                source_id = "wp5_source_a",
                target_type = "PARTICIPANT",
                target_id = userid_a1,
                phase_revision = phase_a:GetCurrentRevision(),
            }
        )
        local effect_b, effect_b_code = effects_b:Apply(
            "wp5.effect.b." .. suffix,
            {
                handler_id = "test_counter",
                source_id = "wp5_source_b",
                target_type = "PARTICIPANT",
                target_id = userid_b1,
                phase_revision = phase_b:GetCurrentRevision(),
            }
        )
        Check(effect_a ~= nil and effect_a_code == nil
            and effect_b ~= nil and effect_b_code == nil
            and effects_a:Count() == 1
            and effects_b:Count() == 1,
            "Effect state was not isolated or handler was not applied")

        local score_a = instance_a:GetService("score")
        local score_b = instance_b:GetService("score")
        local score_event_a, score_event_a_code = score_a:Append(
            {
                event_id = "wp5.score.a.participant." .. suffix,
                target_type = "PARTICIPANT",
                target_id = userid_a1,
                points = 3,
                reason = "test_participant_score",
            }
        )
        local score_event_group, score_event_group_code = score_a:Append(
            {
                event_id = "wp5.score.a.group." .. suffix,
                target_type = "GROUP",
                target_id = group_a:GetId(),
                points = 2,
                reason = "test_group_score",
            }
        )
        local duplicate_score, duplicate_score_code = score_a:Append(
            {
                event_id = "wp5.score.a.participant." .. suffix,
                target_type = "PARTICIPANT",
                target_id = userid_a1,
                points = 100,
            }
        )
        local score_b_event, score_b_event_code = score_b:Append(
            {
                event_id = "wp5.score.b." .. suffix,
                target_type = "INSTANCE",
                points = 7,
                reason = "test_instance_score",
            }
        )
        Check(score_event_a ~= nil and score_event_a_code == nil
            and score_event_group ~= nil and score_event_group_code == nil
            and score_b_event ~= nil and score_b_event_code == nil
            and duplicate_score == nil
            and duplicate_score_code == ScoreLedger.ERROR_CODES.DUPLICATE_EVENT
            and score_a:GetTotal("PARTICIPANT", userid_a1) == 3
            and score_a:GetTotal("GROUP", group_a:GetId()) == 2
            and score_b:GetTotal() == 7,
            "ScoreLedger did not aggregate or reject duplicate event correctly")
        local frozen_a, frozen_a_code = score_a:Freeze("wp5_diagnostics")
        local rejected_after_freeze, rejected_after_freeze_code = score_a:Append(
            {
                event_id = "wp5.score.a.after_freeze." .. suffix,
                target_type = "INSTANCE",
                points = 1,
            }
        )
        Check(frozen_a and frozen_a_code == nil
            and rejected_after_freeze == nil
            and rejected_after_freeze_code == ScoreLedger.ERROR_CODES.LEDGER_FROZEN,
            "ScoreLedger accepted an event after freeze")

        local open_decision_b, open_decision_b_code = instance_b.mode_runtime:CreateGroupVote(
            "wp5.open.b." .. suffix,
            { "KEEP", "CHANGE" },
            { phase_revision = phase_b:GetCurrentRevision() }
        )
        Check(open_decision_b ~= nil and open_decision_b_code == nil
            and decision_service_b:Count() == 1,
            "Instance B Decision was not created")

        local resolving_a, resolving_a_code = phase_a:Transition(
            "RESOLVING",
            "wp5_phase_cleanup"
        )
        local transitioning_a, transitioning_a_code = phase_a:Transition(
            "TRANSITIONING",
            "wp5_phase_cleanup"
        )
        local ended_a, ended_a_code = phase_a:Transition(
            "ENDED",
            "wp5_phase_cleanup"
        )
        Check(resolving_a and resolving_a_code == nil
            and transitioning_a and transitioning_a_code == nil
            and ended_a and ended_a_code == nil
            and phase_scope_a:IsClosed()
            and phase_scope_a:GetResourceCount() == 0
            and decision_service_a:Count() == 0
            and effects_a:Count() == 0
            and decision_service_b:Count() == 1
            and effects_b:Count() == 1
            and phase_b:GetCurrentPhase().state == "ACTIVE",
            "closing PhaseScope did not clean only Instance A services")

        local phase_two, phase_two_code = phase_a:Begin(
            "phase_2",
            { metadata = { schema_version = 1, test = "second_phase" } }
        )
        local phase_two_active, phase_two_active_code = phase_a:Transition(
            "ACTIVE",
            "wp5_second_phase"
        )
        Check(phase_two ~= nil and phase_two_code == nil
            and phase_two_active and phase_two_active_code == nil
            and phase_a:GetCurrentPhaseId() == "phase_2"
            and phase_a:GetCurrentRevision() ~= current_phase_a.revision,
            "PhaseService could not create an independent second phase")
    end)

    local cleaned = Cleanup(runtime, instances)
    if not ok then
        result = false
        failure = "WP5 diagnostic exception: " .. tostring(execution_error)
    elseif not cleaned then
        result = false
        failure = failure or "WP5 diagnostic cleanup failed"
    end
    if not result then
        return false, failure
    end
    local valid, valid_code = runtime:ValidateCore()
    if not valid then
        return false, "core invalid after WP5 diagnostics: " .. tostring(valid_code)
    end
    return true
end

return Wp5Diagnostics
