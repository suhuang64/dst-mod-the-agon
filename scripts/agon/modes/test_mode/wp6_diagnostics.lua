-- WP6：TestMode 的 EntityProfile 注册、应用、隔离、继承和清理验收。

local AudienceStateChannel = require("agon/net/audience_state_channel")
local EntityProfileRegistry = require("agon/services/entity_profile_registry")
local TestModeProfiles = require("agon/modes/test_mode/profiles")

local Wp6Diagnostics = {}

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function Require(condition, message)
    if not condition then
        return false, message
    end
    return true
end

local function Cleanup(runtime, instances)
    local all_clean = true
    for index = #instances, 1, -1 do
        local instance = instances[index]
        if instance ~= nil
            and runtime.instance_manager:Get(instance.instance_id) ~= nil then
            local destroyed = runtime.instance_manager:Destroy(
                instance.instance_id,
                "wp6_diagnostics_cleanup"
            )
            if not destroyed then
                all_clean = false
            end
        end
    end
    return all_clean
end

local function GetSpawnPosition(runtime, instance, offset_x, offset_z)
    local center = instance.zone.center
    return runtime.scene_service.terrain:GetWorldPosition(
        center.x + offset_x,
        center.z + offset_z
    )
end

local function HasTag(entity, tag)
    if entity == nil or type(entity.HasTag) ~= "function" then
        return false
    end
    local ok, result = ProtectedCall(entity.HasTag, entity, tag)
    return ok and result == true
end

local function ContainsState(records, state_id)
    for index = 1, #records do
        if records[index].state_id == state_id then
            return true
        end
    end
    return false
end

function Wp6Diagnostics.Run(runtime)
    if runtime == nil or not runtime:IsReady()
        or runtime.instance_manager == nil
        or runtime.scene_service == nil
        or runtime.entity_profile_registry == nil then
        return false, "WP6 runtime services are not ready"
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
        runtime.wp6_diagnostic_run = (runtime.wp6_diagnostic_run or 0) + 1
        local suffix = tostring(runtime.boot_generation)
            .. "_"
            .. tostring(runtime.wp6_diagnostic_run)
        local userid_a = "__agon_wp6_a_" .. suffix
        local userid_b = "__agon_wp6_b_" .. suffix

        local invalid_replicated, invalid_replicated_code =
            EntityProfileRegistry.ValidateProfile(
            {
                profile_id = "WP6_INVALID_REPLICATED",
                version = 1,
                prefab = "flower",
                apply_mode = EntityProfileRegistry.APPLY_MODES.SPAWN_ONLY,
                replication_mode = EntityProfileRegistry.REPLICATION_MODES.REPLICATED,
                adapter = { Apply = function() return true end },
            })
        local probe_registry = EntityProfileRegistry.New()
        local probe_profile =
        {
            profile_id = "WP6_PROBE",
            version = 1,
            prefab = "flower",
            apply_mode = EntityProfileRegistry.APPLY_MODES.SPAWN_ONLY,
            replication_mode = EntityProfileRegistry.REPLICATION_MODES.SERVER_ONLY,
            adapter = { Apply = function() return true end },
        }
        local probe_registered, probe_register_code = probe_registry:Register(probe_profile)
        local probe_duplicate, probe_duplicate_code = probe_registry:Register(probe_profile)
        Check(invalid_replicated == false
            and invalid_replicated_code == EntityProfileRegistry.ERROR_CODES.CLIENT_CONTRACT_REQUIRED,
            "REPLICATED profile without client contract was accepted")
        Check(probe_registered and probe_register_code == nil
            and probe_duplicate == false
            and probe_duplicate_code == EntityProfileRegistry.ERROR_CODES.DUPLICATE_PROFILE,
            "EntityProfileRegistry did not reject duplicate profile")
        Check(runtime.entity_profile_registry:Count() == #TestModeProfiles.PROFILES,
            "TestMode profile registry count is incomplete")
        for index = 1, #TestModeProfiles.PROFILE_IDS do
            Check(runtime.entity_profile_registry:Has(TestModeProfiles.PROFILE_IDS[index], 1),
                "TestMode profile is missing: " .. TestModeProfiles.PROFILE_IDS[index])
        end
        if not result then
            return
        end

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

        local profile_service_a = instance_a:GetService("entity_profiles")
        local profile_service_b = instance_b:GetService("entity_profiles")
        Check(profile_service_a ~= nil and profile_service_b ~= nil
            and profile_service_a ~= profile_service_b,
            "EntityProfileService was not created per Instance")
        if not result then
            return
        end

        local child_policy_profile =
        {
            profile_id = "WP6_CHILD_POLICY",
            version = 1,
            prefab = "flower",
            apply_mode = EntityProfileRegistry.APPLY_MODES.SPAWN_ONLY,
            replication_mode = EntityProfileRegistry.REPLICATION_MODES.SERVER_ONLY,
            child_profiles = { CHILD = false },
            adapter = { Apply = function() return true end },
        }
        local child_policy_id = profile_service_a:ResolveChildProfile(
            child_policy_profile,
            { category = "CHILD", prefab = "flower" }
        )
        Check(child_policy_id == nil,
            "child policy false was not preserved")
        if not result then
            return
        end

        local scope_a, scope_a_code = instance_a:CreateScope("wp6")
        local scope_b, scope_b_code = instance_b:CreateScope("wp6")
        Check(scope_a ~= nil and scope_b ~= nil,
            "diagnostic child Scope creation failed: "
                .. tostring(scope_a_code) .. "/" .. tostring(scope_b_code))
        if not result then
            return
        end

        local spider_position_a, spider_position_a_code =
            GetSpawnPosition(runtime, instance_a, 1, 0)
        local spider_a, spider_a_code, spider_records_a = instance_a:Spawn(
        {
            prefab = "spider",
            position = spider_position_a,
            category = "MONSTER",
            profile_id = "TEST_SPIDER_POWER",
            profile_version = 1,
            execution_mode = "BLOCKING",
            spawn_source = "wp6:spider:power:" .. suffix,
        },
            scope_a
        )
        local spider_position_b, spider_position_b_code =
            GetSpawnPosition(runtime, instance_b, 1, 0)
        local spider_b, spider_b_code, spider_records_b = instance_b:Spawn(
        {
            prefab = "spider",
            position = spider_position_b,
            category = "MONSTER",
            profile_id = "TEST_SPIDER_GUARD",
            profile_version = 1,
            execution_mode = "BLOCKING",
            spawn_source = "wp6:spider:guard:" .. suffix,
        },
            scope_b
        )
        Check(spider_a ~= nil and spider_a_code == nil
            and spider_position_a ~= nil and spider_position_a_code == nil
            and spider_b ~= nil and spider_b_code == nil
            and spider_position_b ~= nil and spider_position_b_code == nil
            and #spider_records_a >= 1 and #spider_records_b >= 1
            and HasTag(spider_a, "agon_test_power_profile")
            and HasTag(spider_b, "agon_test_guard_profile")
            and spider_a.defensive ~= true
            and spider_b.defensive == true,
            "same named monster Profiles were not applied independently")
        if not result then
            return
        end

        local power_health = spider_a.components.health
        local guard_health = spider_b.components.health
        local power_combat = spider_a.components.combat
        local guard_combat = spider_b.components.combat
        Check(power_health ~= nil and guard_health ~= nil
            and power_combat ~= nil and guard_combat ~= nil
            and type(power_health.maxhealth) == "number"
            and type(guard_health.maxhealth) == "number"
            and power_health.maxhealth == guard_health.maxhealth * 2
            and type(power_combat.defaultdamage) == "number"
            and type(guard_combat.defaultdamage) == "number"
            and power_combat.defaultdamage == guard_combat.defaultdamage * 2,
            "monster attribute Profile did not change only its Instance entity")

        local torch_position_a, torch_position_a_code =
            GetSpawnPosition(runtime, instance_a, -1, 0)
        local torch_a, torch_a_code, torch_records_a = instance_a:Spawn(
        {
            prefab = "torch",
            position = torch_position_a,
            category = "ITEM",
            profile_id = "TEST_TORCH_POWER",
            profile_version = 1,
            execution_mode = "BLOCKING",
            spawn_source = "wp6:torch:power:" .. suffix,
        },
            scope_a
        )
        local torch_position_b, torch_position_b_code =
            GetSpawnPosition(runtime, instance_b, -1, 0)
        local torch_b, torch_b_code, torch_records_b = instance_b:Spawn(
        {
            prefab = "torch",
            position = torch_position_b,
            category = "ITEM",
            profile_id = "TEST_TORCH_LIGHT",
            profile_version = 1,
            execution_mode = "BLOCKING",
            spawn_source = "wp6:torch:light:" .. suffix,
        },
            scope_b
        )
        Check(torch_a ~= nil and torch_a_code == nil
            and torch_position_a ~= nil and torch_position_a_code == nil
            and torch_b ~= nil and torch_b_code == nil
            and torch_position_b ~= nil and torch_position_b_code == nil
            and #torch_records_a >= 1 and #torch_records_b >= 1
            and torch_a.components.weapon ~= nil
            and torch_b.components.weapon ~= nil
            and type(torch_a.components.weapon.damage) == "number"
            and type(torch_b.components.weapon.damage) == "number"
            and torch_a.components.weapon.damage == torch_b.components.weapon.damage * 4
            and torch_a._fuelratemult == .5
            and torch_b._fuelratemult == 2,
            "same named item Profiles did not provide different behavior")
        if not result then
            return
        end

        local started_a, started_a_code = runtime:StartInstance(
            instance_a.instance_id,
            "wp6_diagnostics"
        )
        local started_b, started_b_code = runtime:StartInstance(
            instance_b.instance_id,
            "wp6_diagnostics"
        )
        Check(started_a and started_a_code == nil
            and started_b and started_b_code == nil
            and instance_a.lifecycle_state == "RUNNING"
            and instance_b.lifecycle_state == "RUNNING",
            "diagnostic Instances could not enter RUNNING")
        if not result then
            return
        end

        local invalid_live, invalid_live_code = profile_service_a:Apply(
            torch_a,
            "TEST_TORCH_LIGHT",
            1,
            {
                operation = "live",
                execution_mode = "LIVE",
                replace = true,
            }
        )
        Check(invalid_live == nil
            and invalid_live_code == profile_service_a.ERROR_CODES.APPLY_MODE_SPAWN_ONLY,
            "SPAWN_ONLY profile was reconfigured during live execution")

        local late_guard, late_guard_code = instance_b:Spawn(
        {
            prefab = "spider",
            position = spider_position_b,
            category = "MONSTER",
            profile_id = "TEST_SPIDER_GUARD",
            profile_version = 1,
            execution_mode = "BLOCKING",
            spawn_source = "wp6:spider:late_guard:" .. suffix,
        },
            scope_b
        )
        Check(late_guard == nil
            and late_guard_code == profile_service_b.ERROR_CODES.BLOCKING_STATE_REQUIRED,
            "BLOCKING_ONLY profile was accepted outside a safe transition")

        local foreign_apply, foreign_apply_code = profile_service_a:Apply(
            spider_b,
            "TEST_SPIDER_POWER",
            1,
            { operation = "live", execution_mode = "LIVE" }
        )
        Check(foreign_apply == nil
            and foreign_apply_code == profile_service_a.ERROR_CODES.ENTITY_NOT_OWNED,
            "Profile service accepted an entity owned by another Instance")

        local child_ok, child_entity = ProtectedCall(SpawnPrefab, "flower")
        Check(child_ok and child_entity ~= nil,
            "raw child entity could not be created for inheritance test")
        if not result then
            return
        end
        local child_record, child_code = instance_a:InheritEntity(
            child_entity,
            spider_a,
            {
                scope = scope_a,
                category = "CHILD_FLOWER",
                profile_id = "TEST_FLOWER_DISPLAY",
                profile_version = 1,
                spawn_source = "wp6:child:display:" .. suffix,
            }
        )
        Check(child_record ~= nil and child_code == nil
            and HasTag(child_entity, "agon_test_replicated_profile"),
            "child entity did not inherit the Instance Profile and Scope")
        if not result then
            return
        end

        local display_state, display_code = profile_service_a:GetDisplayState(child_entity)
        local display_contract, display_contract_code = profile_service_a:GetClientContract(
            "TEST_FLOWER_DISPLAY",
            1
        )
        Check(display_state ~= nil and display_code == nil
            and display_state.instance_id == instance_a.instance_id
            and display_state.profile_id == "TEST_FLOWER_DISPLAY"
            and display_contract ~= nil and display_contract_code == nil
            and display_contract.contract_id == "agon.test.entity_profile_display",
            "REPLICATED Profile display state or client contract is incomplete")

        local audience_state, audience_code = runtime:PublishAudienceState(
            "wp6.profile.display." .. suffix,
            AudienceStateChannel.Instance(instance_a.instance_id),
            display_state,
            {
                instance_id = instance_a.instance_id,
                mode_id = instance_a.mode_id,
            }
        )
        local visible_states = runtime.audience_state_channel:ReadFor(
            userid_a,
            { instance_id = instance_a.instance_id }
        )
        Check(audience_state ~= nil and audience_code == nil
            and ContainsState(visible_states, "wp6.profile.display." .. suffix),
            "REPLICATED Profile state was not visible through the audience channel")

        local snapshot_a = profile_service_a:GetSnapshot()
        local snapshot_b = profile_service_b:GetSnapshot()
        Check(snapshot_a.count == 4 and snapshot_b.count == 3,
            "EntityProfileService snapshot did not track Instance-owned entities")

        local scope_a_closed, scope_a_close_code = scope_a:Close("wp6_scope_cleanup")
        local scope_b_closed, scope_b_close_code = scope_b:Close("wp6_scope_cleanup")
        Check(scope_a_closed and scope_b_closed,
            "diagnostic Scope cleanup failed: "
                .. tostring(scope_a_close_code) .. "/" .. tostring(scope_b_close_code))
        Check(profile_service_a:GetSnapshot().count == 1
            and profile_service_b:GetSnapshot().count == 1
            and instance_a.entity_registry:Count() == 1
            and instance_b.entity_registry:Count() == 1,
            "closing a child Scope left Profile or entity registrations behind")
    end)

    local cleaned = Cleanup(runtime, instances)
    if not ok then
        result = false
        failure = "WP6 diagnostic exception: " .. tostring(execution_error)
    elseif not cleaned then
        result = false
        failure = failure or "WP6 diagnostic cleanup failed"
    end
    if not result then
        return false, failure
    end
    local valid, valid_code = runtime:ValidateCore()
    if not valid then
        return false, "core invalid after WP6 diagnostics: " .. tostring(valid_code)
    end
    return true
end

return Wp6Diagnostics
