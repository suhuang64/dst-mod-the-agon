-- WP9：持久化 schema、恢复队列、幂等后端边界和恢复快照的服务端合成验收。

local PersistenceSchema = require("agon/persistence/schema")
local PersistenceMigrations = require("agon/persistence/migrations")
local BackendAdapter = require("agon/backend/backend_adapter")
local RestoreQueue = require("agon/player/restore_queue")
local Util = require("agon/player/adapters/util")

local Wp9Diagnostics = {}

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function Require(condition, message)
    if not condition then
        return false, message
    end
    return true
end

local function MakeTestPlayer(userid)
    local state =
    {
        inventory =
        {
            slots = { [1] = { prefab = "wp9_original_food", count = 3 } },
            equipment = { body = { prefab = "wp9_original_backpack" } },
            active_item = { prefab = "wp9_original_active" },
            containers = {},
        },
        survival_stats =
        {
            health = { current = 73, max = 100, penalty = 0.1, invincible = false },
            hunger = { current = 61, max = 100 },
            sanity = { current = 42, max = 100, mode = 0, sane = true },
            temperature = { current = 18 },
            moisture = { current = 12, max = 100 },
            temporary = { wp9_original_buff = "original" },
        },
        skilltree =
        {
            handshake_complete = true,
            xp = 321,
            points = 2,
            activated_skills = { "wp9_original_skill" },
            selection = { 3, 5 },
            encoded_data = "wp9_original_skill_blob",
            character_prefab = "wilson",
        },
        character =
        {
            prefab = "wilson",
            appearance = { skin = "wp9_test_skin", build = "wp9_test_build" },
            resources = { character_meter = 8 },
            followers = {},
            pets = {},
            summoned = {},
            components = { character_component = "original" },
            abilities = { "original_character_ability" },
            movement_speed = 1,
        },
        movement_speed = 1,
    }
    local player =
    {
        userid = userid,
        prefab = "wilson",
        agon_sandbox_test = true,
        agon_sandbox_state = state,
    }
    function player:IsValid()
        return true
    end
    return player, Util.CopyData(state)
end

local function Cleanup(runtime, instances)
    local clean = true
    for index = #instances, 1, -1 do
        local instance = instances[index]
        if instance ~= nil
            and runtime.instance_manager:Get(instance.instance_id) ~= nil then
            local destroyed = runtime:DestroyInstance(
                instance.instance_id,
                "wp9_diagnostics_cleanup"
            )
            if not destroyed then
                clean = false
            end
        end
    end
    return clean
end

function Wp9Diagnostics.Run(runtime)
    if runtime == nil or not runtime:IsReady()
        or runtime.restore_queue == nil
        or runtime.backend_adapter == nil then
        return false, "WP9 runtime services are not ready"
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
        runtime.wp9_diagnostic_run = (runtime.wp9_diagnostic_run or 0) + 1
        local suffix = tostring(runtime.boot_generation)
            .. "_" .. tostring(runtime.wp9_diagnostic_run)
        local userid = "__agon_wp9_restore_" .. suffix

        local saved = runtime:OnSave()
        local saved_valid, saved_code = PersistenceSchema.ValidateSnapshot(saved)
        Check(saved_valid, "Runtime OnSave produced a non-pure snapshot: " .. tostring(saved_code))
        if not result then
            return
        end

        local legacy = PersistenceSchema.CopyPure(saved)
        legacy.persistence = nil
        local migrated, migration_code = PersistenceMigrations.Migrate(legacy)
        Check(migrated ~= nil and migration_code == nil
            and migrated.persistence ~= nil
            and migrated.persistence.restart_policy == "ABORT_ON_RESTART",
            "v1 persistence migration failed: " .. tostring(migration_code))
        local unknown = PersistenceSchema.CopyPure(saved)
        unknown.persistence.schema_version = 99
        local rejected = PersistenceMigrations.Migrate(unknown)
        Check(rejected == nil, "unknown persistence schema was accepted")

        local instance, create_code = runtime:CreateInstance(
            "TEST_MODE",
            { userid }
        )
        Check(instance ~= nil, "WP9 restore fixture creation failed: " .. tostring(create_code))
        if instance == nil then
            return
        end
        table.insert(instances, instance)
        local started, start_code = runtime:StartInstance(
            instance.instance_id,
            "wp9_diagnostics"
        )
        Check(started, "WP9 restore fixture start failed: " .. tostring(start_code))
        if not result then
            return
        end

        local player, original = MakeTestPlayer(userid)
        local participant = instance:GetParticipant(userid)
        local attached, attach_code = runtime.instance_manager:AttachPlayer(
            instance.instance_id,
            userid,
            player
        )
        Check(attached, "WP9 synthetic player attach failed: " .. tostring(attach_code))
        if not result then
            return
        end
        local sandbox = instance:GetService("player_sandbox")
        local transaction = sandbox ~= nil and sandbox:GetTransaction(participant) or nil
        Check(transaction ~= nil and transaction.state == "SANDBOXED"
            and transaction.snapshot_serializable == true,
            "WP9 sandbox transaction was not exportable")
        if not result then
            return
        end

        local enqueued, enqueue_code = runtime.restore_queue:Enqueue(transaction, participant)
        Check(enqueued and enqueue_code == RestoreQueue.STATES.RESTORE_PENDING,
            "restore transaction was not enqueued: " .. tostring(enqueue_code))
        player.agon_sandbox_state.inventory = { slots = {}, equipment = {}, containers = {} }
        local restored, restore_code = runtime.restore_queue:TryRestore(player)
        Check(restored, "restore queue could not restore synthetic player: " .. tostring(restore_code))
        Check(Util.DeepEqual(player.agon_sandbox_state, original),
            "restore queue did not restore the original synthetic state")

        local queue_snapshot = runtime.restore_queue:GetSnapshot()
        local loaded_queue = RestoreQueue.New()
        local queue_loaded, queue_load_code = loaded_queue:OnLoad(queue_snapshot)
        Check(queue_loaded and loaded_queue:Validate(),
            "restore queue snapshot reload failed: " .. tostring(queue_load_code))

        local result_id = "wp9-result-" .. suffix
        local game_result =
        {
            game_result_id = result_id,
            instance_id = instance.instance_id,
            mode_id = "TEST_MODE",
            payload = { score = 7 },
        }
        local submitted, submit_code = runtime:SubmitGameResult(game_result)
        Check(not submitted and submit_code == BackendAdapter.ERROR_CODES.NOT_CONFIGURED,
            "unconfigured game result did not remain pending: " .. tostring(submit_code))
        local duplicate, duplicate_code = runtime:SubmitGameResult(game_result)
        Check(not duplicate and duplicate_code == BackendAdapter.ERROR_CODES.NOT_CONFIGURED,
            "pending game result retry changed its boundary: " .. tostring(duplicate_code))
        local changed = PersistenceSchema.CopyPure(game_result)
        changed.payload.score = 8
        local changed_ok, changed_code = runtime:SubmitGameResult(changed)
        Check(not changed_ok
            and changed_code == BackendAdapter.ERROR_CODES.RESULT_IMMUTABLE_MISMATCH,
            "immutable game result was accepted: " .. tostring(changed_code))

        local settlement =
        {
            settlement_id = "wp9-settlement-" .. suffix,
            game_result_id = result_id,
            rewards = { coins = 10 },
        }
        local settled, settlement_code = runtime:SubmitSettlement(settlement)
        Check(not settled and settlement_code == BackendAdapter.ERROR_CODES.NOT_CONFIGURED,
            "unconfigured settlement did not remain pending: " .. tostring(settlement_code))
        local settlement_changed = PersistenceSchema.CopyPure(settlement)
        settlement_changed.rewards.coins = 11
        local settlement_ok, settlement_changed_code = runtime:SubmitSettlement(settlement_changed)
        Check(not settlement_ok
            and settlement_changed_code == BackendAdapter.ERROR_CODES.SETTLEMENT_IMMUTABLE_MISMATCH,
            "immutable settlement was accepted: " .. tostring(settlement_changed_code))

        local calls = 0
        local fake_transport =
        {
            SubmitGameResult = function()
                calls = calls + 1
                return true
            end,
            SubmitSettlement = function()
                calls = calls + 1
                return true
            end,
        }
        local fake_backend = BackendAdapter.New({ transport = fake_transport })
        local fake_ok = fake_backend:SubmitGameResult(
        {
            game_result_id = "wp9-fake-result-" .. suffix,
            payload = { score = 1 },
        })
        local fake_duplicate, fake_duplicate_code = fake_backend:SubmitGameResult(
        {
            game_result_id = "wp9-fake-result-" .. suffix,
            payload = { score = 1 },
        })
        Check(fake_ok and fake_duplicate and fake_duplicate_code == "ALREADY_SUBMITTED"
            and calls == 1,
            "configured backend duplicate was not idempotent")
        Check(fake_backend:Validate(), "configured backend snapshot is invalid")
    end)

    local cleaned = Cleanup(runtime, instances)
    if not ok then
        result = false
        failure = "WP9 diagnostic exception: " .. tostring(execution_error)
    elseif not cleaned then
        result = false
        failure = failure or "WP9 diagnostic cleanup failed"
    end
    if not result then
        return false, failure
    end
    local valid, valid_code = runtime:ValidateCore()
    if not valid then
        return false, "core invalid after WP9 diagnostics: " .. tostring(valid_code)
    end
    return true
end

return Wp9Diagnostics
