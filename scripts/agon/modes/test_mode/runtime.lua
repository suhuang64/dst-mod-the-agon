-- WP3：通过 ScenePlan 驱动最小场景、实体和地形事务的 TestMode runtime。

local ScenePlans = require("agon/modes/test_mode/scene_plans")
local TestModeDecisions = require("agon/modes/test_mode/decisions")
local TestModeEffects = require("agon/modes/test_mode/effects")
local PlayerProfile = require("agon/player/player_profile")
local PlayerUtil = require("agon/player/adapters/util")
local DeathPolicy = require("agon/player/death_policy")

local TestModeRuntime = {}
TestModeRuntime.SCHEMA_VERSION = 1

local TEST_PLAYER_PROFILE = PlayerProfile.New(
{
    profile_id = "TEST_MODE_PLAYER",
    version = 1,
    mode_id = "TEST_MODE",
    appearance_policy = PlayerProfile.APPEARANCE_POLICIES.PRESERVE,
    base_stats =
    {
        max_health = 150,
        health = 150,
        max_hunger = 150,
        hunger = 150,
        max_sanity = 200,
        sanity = 200,
        temperature = 25,
        moisture = 0,
    },
    movement_speed = 1.25,
    starting_items =
    {
        { prefab = "test_mode_token", count = 1, slot = 1 },
    },
    skills = { "test_mode_unified_skill" },
    skill_points = 0,
    allowed_abilities = { "test_mode_unified_ability" },
    disabled_abilities = { "original_character_ability" },
    temporary_components = { "test_mode_rules" },
    metadata = { schema_version = 1, purpose = "wp7_sandbox_diagnostics" },
})

local function MakeLivePlayerProfile()
    local profile = PlayerProfile.Copy(TEST_PLAYER_PROFILE)

    -- 真实玩家使用独立的公平状态；原角色状态仍由各适配器快照并在离场时恢复。
    profile.starting_items = {}
    profile.skills = {}
    profile.skill_points = nil
    profile.skill_xp = nil
    profile.skilltree_data = nil
    profile.movement_speed = nil
    profile.allowed_abilities = {}
    profile.disabled_abilities = {}
    profile.temporary_components = {}
    profile.fair_mode =
    {
        enabled = true,
        disable_character_traits = true,
        disable_skilltree = true,
        movement =
        {
            walk_speed = 4,
            run_speed = 6,
        },
    }
    profile.metadata =
    {
        schema_version = 1,
        purpose = "wp10_live_character_adapter",
        source_profile = "TEST_MODE_PLAYER",
    }
    return profile
end

local function AttachMethods(runtime)
    runtime.OnPrepare = TestModeRuntime.OnPrepare
    runtime.OnStart = TestModeRuntime.OnStart
    runtime.OnFinish = TestModeRuntime.OnFinish
    runtime.OnDestroy = TestModeRuntime.OnDestroy
    runtime.CreateScenePlan = TestModeRuntime.CreateScenePlan
    runtime.CreateGroupVote = TestModeRuntime.CreateGroupVote
    runtime.GetService = TestModeRuntime.GetService
    runtime.GetGroup = TestModeRuntime.GetGroup
    runtime.GetPhase = TestModeRuntime.GetPhase
    runtime.GetPlayerProfile = TestModeRuntime.GetPlayerProfile
    runtime.GetDeathMode = TestModeRuntime.GetDeathMode
    runtime.CreateDeathPolicy = TestModeRuntime.CreateDeathPolicy
    runtime.OnSave = TestModeRuntime.OnSave
    return runtime
end

local function ResolveDeathMode(instance)
    if type(instance) ~= "table" then
        return DeathPolicy.MODES.GHOST
    end
    if instance.death_mode ~= nil then
        return instance.death_mode
    end
    return DeathPolicy.MODES.GHOST
end

function TestModeRuntime.New(instance, services)
    if type(instance) ~= "table"
        or type(instance.instance_id) ~= "string"
        or instance.instance_id == "" then
        return nil, "INVALID_INSTANCE"
    end

    return AttachMethods(
    {
        schema_version = TestModeRuntime.SCHEMA_VERSION,
        mode_id = "TEST_MODE",
        mode_version = 1,
        instance_id = instance.instance_id,
        instance = instance,
        services = services or {},
        death_mode = ResolveDeathMode(instance),
        state = "CREATED",
        group = nil,
        phase = nil,
        effect_apply_count = 0,
        effect_remove_count = 0,
        effect_handler_registered = false,
    })
end

function TestModeRuntime.GetService(self, service_id)
    return self.services[service_id]
end

function TestModeRuntime.GetGroup(self)
    return self.group
end

function TestModeRuntime.GetPhase(self)
    return self.phase
end

function TestModeRuntime.GetPlayerProfile(self, participant)
    if participant == nil or TEST_PLAYER_PROFILE == nil then
        return nil
    end
    local player = type(participant.GetPlayer) == "function"
        and participant:GetPlayer()
        or nil
    if player ~= nil and not PlayerUtil.IsSyntheticPlayer(player) then
        return MakeLivePlayerProfile()
    end
    return PlayerProfile.Copy(TEST_PLAYER_PROFILE)
end

function TestModeRuntime.GetDeathMode(self)
    return self.death_mode
end

function TestModeRuntime.CreateDeathPolicy(self)
    return DeathPolicy.New(
        self.instance,
        {
            mode = self.death_mode,
            now_fn = self.instance.now_fn,
        }
    )
end

function TestModeRuntime.CreateGroupVote(self, decision_id, candidates, options)
    return TestModeDecisions.CreateGroupVote(
        self,
        decision_id,
        candidates,
        options
    )
end

function TestModeRuntime.CreateScenePlan(self, context)
    return ScenePlans.Create(context)
end

function TestModeRuntime.OnPrepare(self)
    if self.state == "PREPARING" or self.state == "READY" then
        return true
    end
    if self.state ~= "CREATED" then
        return false, "TEST_MODE_INVALID_PREPARE_STATE"
    end
    local participants = self.instance:ListParticipants()
    local group, group_code = self.instance:CreateGroup(
        "COOP_TEST",
        participants,
        {
            metadata =
            {
                schema_version = 1,
                mode_id = self.mode_id,
            },
        }
    )
    if group == nil then
        return false, group_code or "TEST_MODE_GROUP_CREATE_FAILED"
    end
    self.group = group

    local effects = self:GetService("effects")
    if effects ~= nil and not self.effect_handler_registered then
        local registered, register_code = effects:RegisterHandler(
            "test_counter",
            TestModeEffects.CreateCounterHandler(self),
            { version = 1 }
        )
        if not registered then
            return false, register_code or "TEST_MODE_EFFECT_HANDLER_FAILED"
        end
        self.effect_handler_registered = true
    end
    self.state = "READY"
    return true
end

function TestModeRuntime.OnStart(self)
    if self.state == "RUNNING" then
        return true
    end
    if self.state ~= "READY" then
        return false, "TEST_MODE_NOT_PREPARED"
    end
    local phases = self:GetService("phase")
    if phases == nil then
        return false, "TEST_MODE_PHASE_SERVICE_UNAVAILABLE"
    end
    local phase, phase_code = phases:Begin(
        "phase_1",
        {
            metadata =
            {
                schema_version = 1,
                mode_id = self.mode_id,
            },
        }
    )
    if phase == nil then
        return false, phase_code or "TEST_MODE_PHASE_CREATE_FAILED"
    end
    local active, active_code = phases:Transition("ACTIVE", "test_mode_start")
    if not active then
        return false, active_code or "TEST_MODE_PHASE_START_FAILED"
    end
    self.phase = phase
    self.state = "RUNNING"
    return true
end

function TestModeRuntime.OnFinish(self)
    if self.state == "FINISHED" then
        return true
    end
    if self.state ~= "READY" and self.state ~= "RUNNING" then
        return false, "TEST_MODE_INVALID_FINISH_STATE"
    end
    local phases = self:GetService("phase")
    if phases ~= nil and phases:GetCurrentPhase() ~= nil then
        local current = phases:GetCurrentPhase()
        if current.state == "ACTIVE" then
            phases:Transition("RESOLVING", "test_mode_finish")
        end
        if current.state == "RESOLVING" then
            phases:Transition("TRANSITIONING", "test_mode_finish")
        end
        if current.state == "TRANSITIONING" or current.state == "PREPARING" then
            phases:Transition("ENDED", "test_mode_finish")
        end
    end
    local score = self:GetService("score")
    if score ~= nil then
        score:Freeze("test_mode_finish")
    end
    self.state = "FINISHED"
    return true
end

function TestModeRuntime.OnDestroy(self)
    if self.state == "DESTROYED" then
        return true
    end
    self.state = "DESTROYED"
    return true
end

function TestModeRuntime.OnSave(self)
    return
    {
        schema_version = self.schema_version,
        mode_id = self.mode_id,
        mode_version = self.mode_version,
        instance_id = self.instance_id,
        state = self.state,
        death_mode = self.death_mode,
        group_id = self.group ~= nil and self.group:GetId() or nil,
        phase_id = self.phase ~= nil and self.phase.phase_id or nil,
        effect_apply_count = self.effect_apply_count,
        effect_remove_count = self.effect_remove_count,
    }
end

return TestModeRuntime
