-- WP7：官方角色适配器。
--
-- 角色适配器不把“未知状态”当成空状态。每个角色都必须有明确的
-- 捕获、清理、恢复契约；遇到不能安全拆分的瞬时实体状态时，直接拒绝
-- 进入沙箱，避免把原世界状态静默丢失。

local Util = require("agon/player/adapters/util")
local FairState = require("agon/player/adapters/characters/fair_state")

local CharacterAdapter = {}
CharacterAdapter.adapter_id = "character:default"
-- 保持适配器版本不变；Wilson/Wathgrithr 的已有恢复快照仍可继续读取。
CharacterAdapter.version = 1
CharacterAdapter.order = 40
CharacterAdapter.dependencies = { "skilltree" }
CharacterAdapter.character_prefab = "*"

CharacterAdapter.ERROR_CODES =
{
    PLAYER_INVALID = "CHARACTER_PLAYER_INVALID",
    PREFAB_MISSING = "CHARACTER_PREFAB_MISSING",
    STATE_UNSUPPORTED = "CHARACTER_LIVE_STATE_UNSUPPORTED",
    SNAPSHOT_INVALID = "CHARACTER_SNAPSHOT_INVALID",
    CLEAN_FAILED = "CHARACTER_CLEAN_FAILED",
    APPLY_FAILED = "CHARACTER_APPLY_FAILED",
    RESTORE_MISMATCH = "CHARACTER_RESTORE_MISMATCH",
}

local ERROR_CODES = CharacterAdapter.ERROR_CODES

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value < math.huge
        and value > -math.huge
end

local function HasEntries(value)
    return type(value) == "table" and next(value) ~= nil
end

local function IsPureValue(value, seen)
    if value == nil or type(value) == "boolean" or type(value) == "string" then
        return true
    end
    if type(value) == "number" then
        return IsFiniteNumber(value)
    end
    if type(value) ~= "table" then
        return false
    end
    seen = seen or {}
    if seen[value] then
        return false
    end
    seen[value] = true
    for key, item in pairs(value) do
        if (type(key) ~= "string" and type(key) ~= "number")
            or not IsPureValue(item, seen) then
            seen[value] = nil
            return false
        end
    end
    seen[value] = nil
    return true
end

local function CopyOfficialSave(component)
    if type(component) ~= "table" or type(component.OnSave) ~= "function" then
        return nil
    end
    local ok, saved = pcall(component.OnSave, component)
    if not ok then
        return nil
    end
    if saved == nil then
        return {}
    end
    if type(saved) ~= "table" or not IsPureValue(saved) then
        return nil
    end
    local copied = Util.CopyPureData(saved)
    return type(copied) == "table" and copied or nil
end

local function CopyOfficialSaveOrEmpty(component)
    return CopyOfficialSave(component) or {}
end

local function Call(object, method, ...)
    if object == nil or type(object[method]) ~= "function" then
        return false
    end
    local ok = pcall(object[method], object, ...)
    return ok
end

local function CallResult(object, method, ...)
    if object == nil or type(object[method]) ~= "function" then
        return false, nil
    end
    return pcall(object[method], object, ...)
end

local function CancelTask(task)
    if task == nil then
        return true
    end
    return Call(task, "Cancel")
end

local function GetTaskRemainingSafe(task)
    if task == nil or type(GetTaskRemaining) ~= "function" then
        return nil
    end
    local ok, remaining = pcall(GetTaskRemaining, task)
    return ok and IsFiniteNumber(remaining) and math.max(0, remaining) or nil
end

local function SetNetValue(object, field, value)
    if object == nil or object[field] == nil
        or type(object[field].set) ~= "function" then
        return false
    end
    local ok = pcall(object[field].set, object[field], value)
    return ok
end

local function IsValidEntity(entity)
    if entity == nil then
        return false
    end
    if type(entity.IsValid) ~= "function" then
        return true
    end
    local ok, valid = pcall(entity.IsValid, entity)
    return ok and valid == true
end

local function HasEntityTag(entity, tag)
    if entity == nil or type(entity.HasTag) ~= "function" then
        return false
    end
    local ok, result = pcall(entity.HasTag, entity, tag)
    return ok and result == true
end

local function IsInLimbo(entity)
    return entity ~= nil
        and (entity.inlimbo == true or HasEntityTag(entity, "INLIMBO"))
end

local function GetWorldPosition(entity)
    if entity == nil or entity.Transform == nil
        or type(entity.Transform.GetWorldPosition) ~= "function" then
        return nil
    end
    local ok, x, y, z = pcall(entity.Transform.GetWorldPosition, entity.Transform)
    if not ok or not IsFiniteNumber(x) or not IsFiniteNumber(y)
        or not IsFiniteNumber(z) then
        return nil
    end
    return x, y, z
end

local function GetRotation(entity)
    if entity == nil or entity.Transform == nil
        or type(entity.Transform.GetRotation) ~= "function" then
        return nil
    end
    local ok, rotation = pcall(entity.Transform.GetRotation, entity.Transform)
    return ok and IsFiniteNumber(rotation) and rotation or nil
end

local function NumberIsValid(value, minimum, maximum)
    return IsFiniteNumber(value)
        and (minimum == nil or value >= minimum)
        and (maximum == nil or value <= maximum)
end

local function NumbersClose(left, right, tolerance)
    if left == right then
        return true
    end
    return IsFiniteNumber(left) and IsFiniteNumber(right)
        and math.abs(left - right) <= (tolerance or 0.75)
end

local function ValidateState(data)
    return type(data) == "table"
        and type(data.prefab) == "string"
        and data.prefab ~= ""
        and type(data.appearance) == "table"
        and type(data.resources) == "table"
        and type(data.followers) == "table"
        and type(data.pets) == "table"
        and type(data.summoned) == "table"
        and type(data.components) == "table"
        and type(data.abilities) == "table"
        and (data.movement_speed == nil or IsFiniteNumber(data.movement_speed))
        and (data.runtime == nil or type(data.runtime) == "boolean")
end

local function ValidateBeardResources(resources)
    local beard = type(resources) == "table" and resources.beard or nil
    if type(beard) ~= "table" or not IsPureValue(beard) then
        return false
    end
    return (beard.growth == nil or NumberIsValid(beard.growth, 0))
        and (beard.growthaccumulator == nil
            or NumberIsValid(beard.growthaccumulator, 0))
        and (beard.bits == nil or NumberIsValid(beard.bits, 0))
        and (beard.skinname == nil or type(beard.skinname) == "string")
end

local function ValidateWathgrithrResources(resources)
    if type(resources) ~= "table"
        or type(resources.singinginspiration) ~= "table"
        or type(resources.battleborn) ~= "table" then
        return false
    end
    local inspiration = resources.singinginspiration
    local battleborn = resources.battleborn
    if not IsPureValue(inspiration) or not IsPureValue(battleborn)
        or not NumberIsValid(inspiration.current, 0)
        or not NumberIsValid(battleborn.value, 0)
        or not NumberIsValid(battleborn.time, 0) then
        return false
    end
    if inspiration.active_songs ~= nil then
        if type(inspiration.active_songs) ~= "table" then
            return false
        end
        for _, song in ipairs(inspiration.active_songs) do
            if type(song) ~= "string" or song == "" then
                return false
            end
        end
    end
    return true
end

local function ValidateMightiness(resources)
    return type(resources) == "table"
        and type(resources.mightiness) == "table"
        and IsPureValue(resources.mightiness)
        and NumberIsValid(resources.mightiness.mightiness, 0)
end

local function ValidateWereness(data)
    return type(data) == "table"
        and IsPureValue(data)
        and (data.current == nil or NumberIsValid(data.current, 0, 100))
        and (data.mode == nil or type(data.mode) == "string")
end

local function ValidateWereEater(data)
    return type(data) == "table"
        and IsPureValue(data)
        and (data.monster_count == nil
            or NumberIsValid(data.monster_count, 0, 4))
        and (data.task_left == nil or NumberIsValid(data.task_left, 0))
end

local function ValidateFoodMemory(data)
    if type(data) ~= "table" or not IsPureValue(data) then
        return false
    end
    local foods = data.foods
    if foods == nil then
        return true
    end
    if type(foods) ~= "table" then
        return false
    end
    for prefab, record in pairs(foods) do
        if type(prefab) ~= "string" or type(record) ~= "table"
            or not NumberIsValid(record.count, 1)
            or (record.t ~= nil and not NumberIsValid(record.t, 0)) then
            return false
        end
    end
    return true
end

local function ValidateBloomness(data)
    if type(data) ~= "table" or not IsPureValue(data) then
        return false
    end
    return (data.level == nil or NumberIsValid(data.level, 0, 3))
        and (data.timer == nil or NumberIsValid(data.timer, 0))
        and (data.rate == nil or NumberIsValid(data.rate, 0))
        and (data.fertilizer == nil or NumberIsValid(data.fertilizer, 0))
        and (data.is_blooming == nil or type(data.is_blooming) == "boolean")
end

local function ValidatePositionalWarp(data)
    if type(data) ~= "table" or not IsPureValue(data) then
        return false
    end
    for _, name in ipairs({ "history_x", "history_y", "history_z" }) do
        if type(data[name]) ~= "table" then
            return false
        end
        for _, value in pairs(data[name]) do
            if not NumberIsValid(value) then
                return false
            end
        end
    end
    return NumberIsValid(data.cur, 0)
        and NumberIsValid(data.back, 0)
end

local function ValidateGhostlyBond(data)
    return type(data) == "table"
        and IsPureValue(data)
        and NumberIsValid(data.bondlevel, 1, 3)
        and (data.elapsedtime == nil or NumberIsValid(data.elapsedtime, 0))
        and data.ghost_in_limbo == true
end

local function ValidateDataAnalyzer(data)
    return type(data) == "table"
        and IsPureValue(data)
        and (data.datahistory == nil or type(data.datahistory) == "table")
end

local function ValidateWX78(resources)
    if type(resources) ~= "table"
        or not NumberIsValid(resources.gears_eaten, 0)
        or not NumberIsValid(resources.charge_level, 0)
        or not NumberIsValid(resources.max_charge, 1)
        or not NumberIsValid(resources.shield, 0)
        or not ValidateDataAnalyzer(resources.dataanalyzer) then
        return false
    end
    return IsPureValue(resources)
end

local function ValidateWortox(resources)
    return type(resources) == "table"
        and IsPureValue(resources)
        and NumberIsValid(resources.freehops, 0, 7)
        and NumberIsValid(resources.soulhopcost, 0)
end

local function ValidateWobyCommands(data)
    if type(data) ~= "table" or not IsPureValue(data) then
        return false
    end
    for _, name in ipairs(
        { "sit", "pickup", "foraging", "working", "sprinting",
          "shadowdash", "bagunlock" }
    ) do
        if data[name] ~= nil and type(data[name]) ~= "boolean" then
            return false
        end
    end
    return true
end

local function ValidateWalter(resources)
    local woby = type(resources) == "table" and resources.woby or nil
    if type(woby) ~= "table" or not IsPureValue(resources)
        or type(woby.prefab) ~= "string" or woby.prefab == ""
        or not NumberIsValid(woby.x)
        or not NumberIsValid(woby.y)
        or not NumberIsValid(woby.z)
        or not NumberIsValid(woby.rotation)
        or not NumberIsValid(woby.hunger, 0)
        or not NumberIsValid(woby.hunger_max, 1)
        or not ValidateWobyCommands(woby.commands)
        or type(woby.courier) ~= "table"
        or not IsPureValue(woby.courier)
        or not NumberIsValid(woby.buckdamage, 0) then
        return false
    end
    return woby.hunger <= woby.hunger_max
end

local function ValidateWinona(resources)
    return type(resources) == "table"
        and type(resources.inspectacles) == "table"
        and type(resources.rose) == "table"
        and IsPureValue(resources)
        and (resources.charlie_vinesave == nil
            or type(resources.charlie_vinesave) == "boolean"
            or IsFiniteNumber(resources.charlie_vinesave))
end

local function ValidateWoodie(resources)
    return type(resources) == "table"
        and ValidateBeardResources({ beard = resources.beard })
        and ValidateWereness(resources.wereness)
        and ValidateWereEater(resources.wereeater)
        and (resources.fullmoontriggered == nil
            or type(resources.fullmoontriggered) == "boolean")
        and IsPureValue(resources)
end

local function ValidateWormwood(resources)
    return type(resources) == "table"
        and ValidateBloomness(resources.bloomness)
        and IsPureValue(resources)
end

local function ValidateWanda(resources)
    return type(resources) == "table"
        and ValidatePositionalWarp(resources.positionalwarp)
        and NumberIsValid(resources.year_timer, 0, 1)
        and IsPureValue(resources)
end

local function Noop()
    return true
end

local STATIC_HANDLER =
{
    Capture = function()
        return {}
    end,
    Validate = function(_, resources)
        return type(resources) == "table" and not HasEntries(resources)
    end,
    Clean = Noop,
    Remove = Noop,
    Restore = Noop,
    Match = function(actual, expected)
        return Util.DeepEqual(actual, expected)
    end,
}

local BEARD_HANDLER =
{
    Capture = function(_, components)
        local beard = CopyOfficialSave(components.beard)
        return beard ~= nil and { beard = beard } or nil,
            beard ~= nil and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Validate = function(_, resources)
        return ValidateBeardResources(resources)
    end,
    Clean = Noop,
    Remove = Noop,
    Restore = function(_, components, resources)
        local beard = components.beard
        if beard == nil or type(beard.OnLoad) ~= "function" then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = pcall(beard.OnLoad, beard, Util.CopyData(resources.beard))
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        return Util.DeepEqual(actual, expected)
    end,
}

local WATHGRITHR_HANDLER =
{
    Capture = function(_, components)
        local inspiration = CopyOfficialSave(components.singinginspiration)
        local battleborn = components.battleborn
        local value = battleborn ~= nil and battleborn.battleborn or nil
        local time = battleborn ~= nil and battleborn.battleborn_time or nil
        if inspiration == nil or battleborn == nil
            or not NumberIsValid(value, 0)
            or not NumberIsValid(time, 0)
            or value ~= 0
            or HasEntries(inspiration.active_songs) then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        -- 保持旧快照字段名，保证已有恢复队列仍可读取。
        return
        {
            singinginspiration = inspiration,
            battleborn = { value = value, time = time },
        }
    end,
    Validate = function(_, resources)
        return ValidateWathgrithrResources(resources)
    end,
    Clean = function(_, components)
        local inspiration = components.singinginspiration
        local battleborn = components.battleborn
        if inspiration == nil or battleborn == nil
            or type(inspiration.SetInspiration) ~= "function" then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        battleborn.battleborn = 0
        battleborn.battleborn_time = 0
        local ok = pcall(inspiration.SetInspiration, inspiration, 0)
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WATHGRITHR_HANDLER.Clean(player, components, context)
    end,
    Restore = function(_, components, resources)
        local inspiration = components.singinginspiration
        local battleborn = components.battleborn
        if inspiration == nil or battleborn == nil
            or type(inspiration.OnLoad) ~= "function" then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = pcall(
            inspiration.OnLoad,
            inspiration,
            Util.CopyData(resources.singinginspiration)
        )
        if ok then
            ok = pcall(function()
                battleborn.battleborn = resources.battleborn.value
                battleborn.battleborn_time = resources.battleborn.time
            end)
        end
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        return Util.DeepEqual(actual, expected)
    end,
}

local WOLFGANG_HANDLER =
{
    Capture = function(_, components)
        local mightiness = CopyOfficialSave(components.mightiness)
        local lifter = components.dumbbelllifter
        local strongman = components.strongman
        local coach = components.coach
        local lifting = false
        if lifter ~= nil and type(lifter.IsLiftingAny) == "function" then
            local ok, result = pcall(lifter.IsLiftingAny, lifter)
            lifting = ok and result == true
        end
        if mightiness == nil
            or lifting
            or (strongman ~= nil and strongman.gym ~= nil)
            or (coach ~= nil and coach.inspiretask ~= nil) then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        return { mightiness = mightiness }
    end,
    Validate = function(_, resources)
        return ValidateMightiness(resources)
    end,
    Clean = function(_, components)
        local mightiness = components.mightiness
        if mightiness == nil then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = true
        if components.dumbbelllifter ~= nil
            and components.dumbbelllifter.dumbbell ~= nil then
            ok = pcall(
                components.dumbbelllifter.StopLifting,
                components.dumbbelllifter
            )
        end
        if ok and components.strongman ~= nil
            and components.strongman.gym ~= nil then
            ok = pcall(
                components.strongman.StopWorkout,
                components.strongman
            )
        end
        if ok and components.coach ~= nil
            and components.coach.inspiretask ~= nil then
            ok = pcall(components.coach.StopInspiring, components.coach)
        end
        if ok and type(mightiness.Pause) == "function" then
            ok = pcall(mightiness.Pause, mightiness)
        end
        if ok and type(mightiness.SetPercent) == "function" then
            ok = pcall(mightiness.SetPercent, mightiness, 0.5, true)
        end
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WOLFGANG_HANDLER.Clean(player, components, context)
    end,
    Restore = function(_, components, resources)
        local mightiness = components.mightiness
        if mightiness == nil or type(mightiness.OnLoad) ~= "function" then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = pcall(
            mightiness.OnLoad,
            mightiness,
            Util.CopyData(resources.mightiness)
        )
        if ok and type(mightiness.Resume) == "function" then
            ok = pcall(mightiness.Resume, mightiness)
        end
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        local left = actual ~= nil and actual.mightiness or nil
        local right = expected ~= nil and expected.mightiness or nil
        return type(actual) == "table"
            and type(expected) == "table"
            and NumbersClose(
                left ~= nil and left.mightiness or nil,
                right ~= nil and right.mightiness or nil
            )
    end,
}

local WOODIE_HANDLER =
{
    Capture = function(player, components)
        if HasEntityTag(player, "wereplayer")
            or (components.wereness ~= nil
                and components.wereness.weremode ~= nil
                and NumberIsValid(components.wereness.current, 0)
                and components.wereness.current > 0) then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        local beard = CopyOfficialSave(components.beard)
        local wereness = CopyOfficialSaveOrEmpty(components.wereness)
        local wereeater = CopyOfficialSaveOrEmpty(components.wereeater)
        if beard == nil then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        return
        {
            beard = beard,
            wereness = wereness,
            wereeater = wereeater,
            fullmoontriggered = player.fullmoontriggered,
        }
    end,
    Validate = function(_, resources)
        return ValidateWoodie(resources)
    end,
    Clean = function(player, components)
        local ok = true
        if components.wereness ~= nil then
            if type(components.wereness.SetWereMode) == "function" then
                ok = pcall(components.wereness.SetWereMode, components.wereness, nil)
            end
            if ok and type(components.wereness.SetPercent) == "function" then
                ok = pcall(components.wereness.SetPercent, components.wereness, 0, true)
            end
            if ok and type(components.wereness.StopDraining) == "function" then
                ok = pcall(components.wereness.StopDraining, components.wereness)
            end
        end
        if ok and components.wereeater ~= nil
            and type(components.wereeater.ResetFoodMemory) == "function" then
            ok = pcall(
                components.wereeater.ResetFoodMemory,
                components.wereeater
            )
        end
        if ok then
            player.fullmoontriggered = nil
        end
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WOODIE_HANDLER.Clean(player, components, context)
    end,
    Restore = function(player, components, resources)
        local ok = true
        if components.beard ~= nil
            and type(components.beard.OnLoad) == "function" then
            ok = pcall(
                components.beard.OnLoad,
                components.beard,
                Util.CopyData(resources.beard)
            )
        end
        if ok and components.wereness ~= nil
            and type(components.wereness.OnLoad) == "function" then
            ok = pcall(
                components.wereness.OnLoad,
                components.wereness,
                Util.CopyData(resources.wereness)
            )
        end
        if ok and components.wereeater ~= nil
            and type(components.wereeater.OnLoad) == "function" then
            ok = pcall(
                components.wereeater.OnLoad,
                components.wereeater,
                Util.CopyData(resources.wereeater)
            )
        end
        if ok then
            player.fullmoontriggered = resources.fullmoontriggered
        end
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        if type(actual) ~= "table" or type(expected) ~= "table"
            or not Util.DeepEqual(actual.beard, expected.beard)
            or actual.fullmoontriggered ~= expected.fullmoontriggered then
            return false
        end
        local aw = actual.wereness or {}
        local ew = expected.wereness or {}
        local ae = actual.wereeater or {}
        local ee = expected.wereeater or {}
        return NumbersClose(aw.current, ew.current)
            and aw.mode == ew.mode
            and ae.monster_count == ee.monster_count
            and NumbersClose(ae.task_left, ee.task_left)
    end,
}

local function HasWX78Modules(owner)
    if owner == nil then
        return false
    end
    if type(owner.module_bars) ~= "table" then
        return true
    end
    for _, modules in pairs(owner.module_bars) do
        if HasEntries(modules) then
            return true
        end
    end
    return false
end

local WX78_HANDLER =
{
    Capture = function(player, components)
        local owner = components.upgrademoduleowner
        local cooldowns = components.wx78_abilitycooldowns
        local drones = components.wx78_dronescouttracker
        local analyzer = CopyOfficialSave(components.dataanalyzer)
        local shield = components.wx78_shield
        if owner == nil or analyzer == nil or shield == nil
            or HasWX78Modules(owner)
            or (cooldowns ~= nil and HasEntries(cooldowns.cooldowns))
            or (drones ~= nil and HasEntries(drones.drones)) then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        return
        {
            gears_eaten = player._gears_eaten or 0,
            dataanalyzer = analyzer,
            shield = shield.currentshield or 0,
            charge_level = owner.charge_level or 0,
            max_charge = owner.max_charge or 0,
        }
    end,
    Validate = function(_, resources)
        return ValidateWX78(resources)
    end,
    Clean = function(player, components)
        local ok = true
        local owner = components.upgrademoduleowner
        if owner ~= nil and type(owner.PopAllModules) == "function" then
            ok = pcall(owner.PopAllModules, owner)
        end
        local cooldowns = components.wx78_abilitycooldowns
        if ok and cooldowns ~= nil
            and type(cooldowns.StopAbilityCooldown) == "function" then
            for ability in pairs(cooldowns.cooldowns or {}) do
                ok = pcall(cooldowns.StopAbilityCooldown, cooldowns, ability)
                if not ok then
                    break
                end
            end
        end
        local drones = components.wx78_dronescouttracker
        if ok and drones ~= nil and type(drones.ReleaseAllDrones) == "function" then
            ok = pcall(drones.ReleaseAllDrones, drones)
        end
        if ok then
            player._gears_eaten = 0
            if components.dataanalyzer ~= nil then
                components.dataanalyzer.datahistory = {}
            end
            if components.wx78_shield ~= nil
                and type(components.wx78_shield.SetCurrent) == "function" then
                ok = pcall(
                    components.wx78_shield.SetCurrent,
                    components.wx78_shield,
                    0
                )
            end
        end
        if ok and owner ~= nil and type(owner.SetChargeLevel) == "function" then
            ok = pcall(owner.SetChargeLevel, owner, 0)
        end
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WX78_HANDLER.Clean(player, components, context)
    end,
    Restore = function(player, components, resources)
        local owner = components.upgrademoduleowner
        local analyzer = components.dataanalyzer
        local shield = components.wx78_shield
        local ok = owner ~= nil and analyzer ~= nil and shield ~= nil
        if ok and type(analyzer.OnLoad) == "function" then
            ok = pcall(
                analyzer.OnLoad,
                analyzer,
                Util.CopyData(resources.dataanalyzer)
            )
        end
        if ok and type(owner.SetMaxCharge) == "function" then
            ok = pcall(owner.SetMaxCharge, owner, resources.max_charge)
        end
        if ok and type(owner.SetChargeLevel) == "function" then
            ok = pcall(owner.SetChargeLevel, owner, resources.charge_level)
        end
        if ok and type(shield.SetCurrent) == "function" then
            ok = pcall(shield.SetCurrent, shield, resources.shield)
        end
        if ok then
            player._gears_eaten = resources.gears_eaten
        end
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        return type(actual) == "table"
            and type(expected) == "table"
            and actual.gears_eaten == expected.gears_eaten
            and Util.DeepEqual(actual.dataanalyzer, expected.dataanalyzer)
            and NumbersClose(actual.shield, expected.shield)
            and NumbersClose(actual.charge_level, expected.charge_level)
            and actual.max_charge == expected.max_charge
    end,
}

local function IsAllowedAbigail(player, follower)
    local bond = player.components ~= nil and player.components.ghostlybond or nil
    return bond ~= nil and follower ~= nil
        and follower == bond.ghost
        and HasEntityTag(follower, "abigail")
end

local WENDY_HANDLER =
{
    IsAllowedFollower = IsAllowedAbigail,
    Capture = function(player, components)
        local bond = components.ghostlybond
        local ghost = bond ~= nil and bond.ghost or nil
        if bond == nil or not IsValidEntity(ghost)
            or not HasEntityTag(ghost, "abigail")
            or not IsInLimbo(ghost)
            or bond.summoned == true
            or player.questghost ~= nil then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        return
        {
            bondlevel = bond.bondlevel,
            elapsedtime = bond.bondleveltimer,
            ghost_in_limbo = true,
        }
    end,
    Validate = function(_, resources)
        return ValidateGhostlyBond(resources)
    end,
    Clean = function(_, components)
        local bond = components.ghostlybond
        if bond == nil or bond.ghost == nil then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = true
        if type(bond.PauseBonding) == "function" then
            ok = pcall(bond.PauseBonding, bond)
        end
        if ok and type(bond.RecallComplete) == "function" then
            ok = pcall(bond.RecallComplete, bond)
        end
        return ok and IsInLimbo(bond.ghost),
            ok and IsInLimbo(bond.ghost) and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WENDY_HANDLER.Clean(player, components, context)
    end,
    Restore = function(_, components, resources)
        local bond = components.ghostlybond
        if bond == nil or bond.ghost == nil
            or not IsValidEntity(bond.ghost)
            or not HasEntityTag(bond.ghost, "abigail") then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = pcall(
            bond.SetBondLevel,
            bond,
            resources.bondlevel,
            resources.elapsedtime,
            true
        )
        if ok then
            ok = pcall(bond.RecallComplete, bond)
        end
        if ok and type(bond.ResumeBonding) == "function" then
            ok = pcall(bond.ResumeBonding, bond)
        end
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        return type(actual) == "table"
            and type(expected) == "table"
            and actual.bondlevel == expected.bondlevel
            and NumbersClose(actual.elapsedtime, expected.elapsedtime)
            and actual.ghost_in_limbo == expected.ghost_in_limbo
    end,
}

local function AbortStory(components)
    local storyteller = components ~= nil and components.storyteller or nil
    if storyteller ~= nil and storyteller.story ~= nil
        and type(storyteller.AbortStory) == "function" then
        return Call(storyteller, "AbortStory")
    end
    return true
end

local WAXWELL_HANDLER =
{
    Capture = function(_, components)
        local magician = components.magician
        if magician ~= nil
            and (magician.item ~= nil or magician.held ~= nil
                or magician.equip ~= nil) then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        return {}
    end,
    Validate = function(_, resources)
        return type(resources) == "table" and not HasEntries(resources)
    end,
    Clean = function(_, components)
        local ok = true
        if components.magician ~= nil
            and type(components.magician.StopUsing) == "function" then
            ok = pcall(components.magician.StopUsing, components.magician)
        end
        if ok then
            ok = AbortStory(components)
        end
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WAXWELL_HANDLER.Clean(player, components, context)
    end,
    Restore = Noop,
    Match = function(actual, expected)
        return Util.DeepEqual(actual, expected)
    end,
}

local WARLY_HANDLER =
{
    Capture = function(_, components)
        return
        {
            foodmemory = CopyOfficialSaveOrEmpty(components.foodmemory),
        }
    end,
    Validate = function(_, resources)
        return type(resources) == "table"
            and ValidateFoodMemory(resources.foodmemory)
            and IsPureValue(resources)
    end,
    Clean = function(_, components)
        local foodmemory = components.foodmemory
        if foodmemory == nil then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = true
        for _, record in pairs(foodmemory.foods or {}) do
            if record.task ~= nil then
                ok = CancelTask(record.task)
                if not ok then
                    break
                end
            end
        end
        if ok then
            foodmemory.foods = {}
        end
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WARLY_HANDLER.Clean(player, components, context)
    end,
    Restore = function(_, components, resources)
        local foodmemory = components.foodmemory
        if foodmemory == nil or type(foodmemory.OnLoad) ~= "function" then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = pcall(
            foodmemory.OnLoad,
            foodmemory,
            Util.CopyData(resources.foodmemory)
        )
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        local af = actual ~= nil and actual.foodmemory or nil
        local ef = expected ~= nil and expected.foodmemory or nil
        if type(af) ~= "table" or type(ef) ~= "table" then
            return false
        end
        local afoods = af.foods or {}
        local efoods = ef.foods or {}
        for prefab, record in pairs(afoods) do
            local expected_record = efoods[prefab]
            if expected_record == nil
                or record.count ~= expected_record.count
                or not NumbersClose(record.t, expected_record.t) then
                return false
            end
        end
        for prefab in pairs(efoods) do
            if afoods[prefab] == nil then
                return false
            end
        end
        return true
    end,
}

local WORTOX_HANDLER =
{
    Capture = function(player)
        if player.finishportalhoptask ~= nil then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        return
        {
            freehops = player._freesoulhop_counter or 0,
            soulhopcost = player._soulhop_cost or 0,
        }
    end,
    Validate = function(_, resources)
        return ValidateWortox(resources)
    end,
    Clean = function(player)
        if player.finishportalhoptask ~= nil
            and not CancelTask(player.finishportalhoptask) then
            return false, ERROR_CODES.CLEAN_FAILED
        end
        player.finishportalhoptask = nil
        player.finishportalhoptaskmaxtime = nil
        player._freesoulhop_counter = 0
        player._soulhop_cost = 0
        if player.player_classified ~= nil
            and not SetNetValue(player.player_classified, "freesoulhops", 0) then
            return false, ERROR_CODES.CLEAN_FAILED
        end
        return true
    end,
    Remove = function(player, components, context)
        return WORTOX_HANDLER.Clean(player, components, context)
    end,
    Restore = function(player, _, resources)
        player._freesoulhop_counter = resources.freehops
        player._soulhop_cost = resources.soulhopcost
        if player.player_classified ~= nil
            and not SetNetValue(
                player.player_classified,
                "freesoulhops",
                resources.freehops
            ) then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        return true
    end,
    Match = function(actual, expected)
        return Util.DeepEqual(actual, expected)
    end,
}

local WORMWOOD_HANDLER =
{
    Capture = function(_, components)
        return
        {
            bloomness = CopyOfficialSaveOrEmpty(components.bloomness),
        }
    end,
    Validate = function(_, resources)
        return type(resources) == "table"
            and ValidateBloomness(resources.bloomness)
            and IsPureValue(resources)
    end,
    Clean = function(_, components)
        local bloomness = components.bloomness
        if bloomness == nil or type(bloomness.SetLevel) ~= "function" then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = pcall(bloomness.SetLevel, bloomness, 0)
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WORMWOOD_HANDLER.Clean(player, components, context)
    end,
    Restore = function(_, components, resources)
        local bloomness = components.bloomness
        if bloomness == nil or type(bloomness.OnLoad) ~= "function" then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = pcall(
            bloomness.OnLoad,
            bloomness,
            Util.CopyData(resources.bloomness)
        )
        if ok and type(bloomness.UpdateRate) == "function" then
            ok = pcall(bloomness.UpdateRate, bloomness)
        end
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        local ab = actual ~= nil and actual.bloomness or nil
        local eb = expected ~= nil and expected.bloomness or nil
        if type(ab) ~= "table" or type(eb) ~= "table" then
            return false
        end
        return ab.level == eb.level
            and NumbersClose(ab.timer, eb.timer)
            and NumbersClose(ab.rate, eb.rate)
            and ab.is_blooming == eb.is_blooming
            and NumbersClose(ab.fertilizer, eb.fertilizer)
    end,
}

local WINONA_HANDLER =
{
    Capture = function(player, components)
        local inspectacles = components.inspectaclesparticipant
        local rose = components.roseinspectableuser
        if inspectacles == nil or rose == nil
            or inspectacles.game ~= nil
            or inspectacles.box ~= nil
            or rose.target ~= nil
            or rose.point ~= nil
            or rose.residue ~= nil then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        return
        {
            inspectacles = CopyOfficialSaveOrEmpty(inspectacles),
            rose = CopyOfficialSaveOrEmpty(rose),
            charlie_vinesave = player.charlie_vinesave,
        }
    end,
    Validate = function(_, resources)
        return ValidateWinona(resources)
    end,
    Clean = function(player, components)
        local inspectacles = components.inspectaclesparticipant
        local rose = components.roseinspectableuser
        local ok = true
        if inspectacles ~= nil then
            ok = CancelTask(inspectacles.cooldowntask)
            inspectacles.cooldowntask = nil
            if ok and inspectacles.game ~= nil
                and type(inspectacles.SetCurrentGame) == "function" then
                ok = pcall(inspectacles.SetCurrentGame, inspectacles, nil)
            end
            if ok and inspectacles.box ~= nil
                and IsValidEntity(inspectacles.box) then
                ok = Call(inspectacles.box, "Remove")
            end
            inspectacles.box = nil
        end
        if ok and rose ~= nil then
            ok = CancelTask(rose.cooldowntask)
            rose.cooldowntask = nil
            if ok and type(rose.ForceDecayResidue) == "function" then
                ok = pcall(rose.ForceDecayResidue, rose)
            end
            rose.target = nil
            rose.point = nil
            rose.residue = nil
        end
        if ok then
            player.charlie_vinesave = nil
        end
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WINONA_HANDLER.Clean(player, components, context)
    end,
    Restore = function(player, components, resources)
        local inspectacles = components.inspectaclesparticipant
        local rose = components.roseinspectableuser
        local ok = inspectacles ~= nil and rose ~= nil
        if ok and type(inspectacles.OnLoad) == "function" then
            ok = pcall(
                inspectacles.OnLoad,
                inspectacles,
                Util.CopyData(resources.inspectacles)
            )
        end
        if ok and type(rose.OnLoad) == "function" then
            ok = pcall(rose.OnLoad, rose, Util.CopyData(resources.rose))
        end
        if ok then
            player.charlie_vinesave = resources.charlie_vinesave
        end
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        if type(actual) ~= "table" or type(expected) ~= "table"
            or actual.charlie_vinesave ~= expected.charlie_vinesave then
            return false
        end
        local ai = actual.inspectacles or {}
        local ei = expected.inspectacles or {}
        local ar = actual.rose or {}
        local er = expected.rose or {}
        return NumbersClose(ai.cooldown, ei.cooldown)
            and NumbersClose(ar.cooldown, er.cooldown)
    end,
}

local function HasEmptyContainer(container)
    if container == nil then
        return true
    end
    if type(container.IsEmpty) == "function" then
        local ok, empty = pcall(container.IsEmpty, container)
        return ok and empty == true
    end
    if type(container.GetNumSlots) ~= "function"
        or type(container.GetItemInSlot) ~= "function" then
        return false
    end
    local ok, count = pcall(container.GetNumSlots, container)
    if not ok or type(count) ~= "number" then
        return false
    end
    for slot = 1, count do
        local item_ok, item = pcall(container.GetItemInSlot, container, slot)
        if not item_ok or item ~= nil then
            return false
        end
    end
    return true
end

local function GetWobyContainer(woby)
    return woby ~= nil and woby.components ~= nil
        and woby.components.container or nil
end

local function GetWobyRackContainer(woby)
    local rack = woby ~= nil and woby.components ~= nil
        and woby.components.wobyrack or nil
    if rack ~= nil and type(rack.GetContainer) == "function" then
        local ok, container = pcall(rack.GetContainer, rack)
        return ok and container or nil
    end
    return nil
end

local function SetWobyCommand(commands, name, value)
    if commands == nil or commands[name] == nil
        or type(commands[name].set) ~= "function" then
        return false
    end
    return pcall(commands[name].set, commands[name], value)
end

local function IsWobyRidden(woby)
    local rideable = woby ~= nil and woby.components ~= nil
        and woby.components.rideable or nil
    if rideable == nil then
        return false
    end
    if type(rideable.GetRider) == "function" then
        local ok, rider = pcall(rideable.GetRider, rideable)
        return ok and rider ~= nil
    end
    if type(rideable.IsBeingRidden) == "function" then
        local ok, ridden = pcall(rideable.IsBeingRidden, rideable)
        return ok and ridden == true
    end
    return true
end

local function IsPlayerRiding(player, woby)
    local rider = player.components ~= nil and player.components.rider or nil
    if rider == nil or type(rider.IsRiding) ~= "function" then
        return false
    end
    local ok, riding = pcall(rider.IsRiding, rider)
    if not ok or not riding then
        return false
    end
    if type(rider.GetMount) == "function" then
        local mount_ok, mount = pcall(rider.GetMount, rider)
        return mount_ok and mount == woby
    end
    return true
end

local function IsWobySafe(player, woby, commands, courier)
    return IsValidEntity(woby)
        and HasEntityTag(woby, "woby")
        and not IsInLimbo(woby)
        and woby.transforming ~= true
        and not IsWobyRidden(woby)
        and not IsPlayerRiding(player, woby)
        and (commands == nil or commands._task == nil)
        and (commands == nil
            or type(commands.IsOutForDelivery) ~= "function"
            or not commands:IsOutForDelivery())
        and (courier == nil or courier.courierdata == nil)
        and HasEmptyContainer(GetWobyContainer(woby))
        and HasEmptyContainer(GetWobyRackContainer(woby))
end

local function IsAllowedWoby(player, follower)
    return follower ~= nil and follower == player.woby
end

local WALTER_HANDLER =
{
    IsAllowedFollower = IsAllowedWoby,
    Capture = function(player, components)
        local woby = player.woby
        local commands = player.woby_commands_classified
        local courier = components.wobycourier
        local x, y, z = GetWorldPosition(woby)
        local rotation = GetRotation(woby)
        local hunger = woby ~= nil and woby.components ~= nil
            and woby.components.hunger or nil
        if woby == nil or commands == nil or courier == nil
            or x == nil or rotation == nil or hunger == nil
            or not IsWobySafe(player, woby, commands, courier) then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        local command_data = CopyOfficialSave(commands)
        local courier_data = CopyOfficialSaveOrEmpty(courier)
        if command_data == nil or not NumberIsValid(hunger.current, 0)
            or not NumberIsValid(hunger.max, 1)
            or hunger.current > hunger.max then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        return
        {
            woby =
            {
                prefab = woby.prefab,
                x = x,
                y = y,
                z = z,
                rotation = rotation,
                hunger = hunger.current,
                hunger_max = hunger.max,
                commands = command_data,
                courier = courier_data,
                buckdamage = player._wobybuck_damage or 0,
            },
        }
    end,
    Validate = function(_, resources)
        return ValidateWalter(resources)
    end,
    Clean = function(player, components)
        local woby = player.woby
        local commands = player.woby_commands_classified
        if woby == nil or commands == nil then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = true
        for _, name in ipairs(
            { "sit", "pickup", "foraging", "working", "sprinting", "shadowdash" }
        ) do
            ok = SetWobyCommand(commands, name, false)
            if not ok then
                break
            end
        end
        if ok then
            ok = SetWobyCommand(commands, "baglock", true)
        end
        if ok and woby.entity ~= nil then
            ok = Call(woby, "RemoveFromScene")
        end
        if ok and woby.entity ~= nil then
            ok = Call(woby.entity, "SetParent", player.entity)
        end
        if ok and woby.Transform ~= nil then
            ok = Call(woby.Transform, "SetPosition", 0, 0, 0)
        end
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        local woby = player.woby
        if woby == nil or not IsValidEntity(woby) then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = true
        if woby.entity ~= nil then
            ok = Call(woby.entity, "SetParent", nil)
        end
        if ok and IsInLimbo(woby) then
            ok = Call(woby, "ReturnToScene")
        end
        if ok then
            ok = AbortStory(components)
        end
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Restore = function(player, components, resources)
        local saved = resources.woby
        local woby = player.woby
        if woby == nil or woby.prefab ~= saved.prefab
            or not IsValidEntity(woby) then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = true
        if woby.entity ~= nil then
            ok = Call(woby.entity, "SetParent", nil)
        end
        if ok and IsInLimbo(woby) then
            ok = Call(woby, "ReturnToScene")
        end
        if ok and woby.Transform ~= nil then
            ok = Call(woby.Transform, "SetPosition", saved.x, saved.y, saved.z)
        end
        if ok and woby.Transform ~= nil then
            ok = Call(woby.Transform, "SetRotation", saved.rotation)
        end
        if ok and woby.components ~= nil
            and woby.components.hunger ~= nil
            and type(woby.components.hunger.SetCurrent) == "function" then
            ok = pcall(
                woby.components.hunger.SetCurrent,
                woby.components.hunger,
                saved.hunger
            )
        end
        if ok and player.woby_commands_classified ~= nil
            and type(player.woby_commands_classified.OnLoad) == "function" then
            ok = pcall(
                player.woby_commands_classified.OnLoad,
                player.woby_commands_classified,
                Util.CopyData(saved.commands)
            )
        end
        if ok and components.wobycourier ~= nil
            and type(components.wobycourier.OnLoad) == "function" then
            ok = pcall(
                components.wobycourier.OnLoad,
                components.wobycourier,
                Util.CopyData(saved.courier)
            )
        end
        if ok then
            player._wobybuck_damage = saved.buckdamage
        end
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        if type(actual) ~= "table" or type(expected) ~= "table"
            or type(actual.woby) ~= "table"
            or type(expected.woby) ~= "table" then
            return false
        end
        local a = actual.woby
        local e = expected.woby
        return a.prefab == e.prefab
            and NumbersClose(a.x, e.x, 0.25)
            and NumbersClose(a.y, e.y, 0.25)
            and NumbersClose(a.z, e.z, 0.25)
            and NumbersClose(a.rotation, e.rotation, 0.25)
            and NumbersClose(a.hunger, e.hunger, 0.75)
            and a.hunger_max == e.hunger_max
            and Util.DeepEqual(a.commands, e.commands)
            and Util.DeepEqual(a.courier, e.courier)
            and a.buckdamage == e.buckdamage
    end,
}

local WANDA_HANDLER =
{
    Capture = function(_, components)
        local oldager = components.oldager
        local positionalwarp = CopyOfficialSave(components.positionalwarp)
        if oldager == nil or positionalwarp == nil
            or not NumberIsValid(oldager.damage_remaining)
            or oldager.damage_remaining ~= 0
            or not NumberIsValid(oldager.damage_per_second)
            or oldager.damage_per_second ~= 0 then
            return nil, ERROR_CODES.STATE_UNSUPPORTED
        end
        return
        {
            positionalwarp = positionalwarp,
            year_timer = oldager.year_timer or 0,
        }
    end,
    Validate = function(_, resources)
        return ValidateWanda(resources)
    end,
    Clean = function(_, components)
        local oldager = components.oldager
        local positionalwarp = components.positionalwarp
        if oldager == nil or positionalwarp == nil then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = true
        if type(oldager.StopDamageOverTime) == "function" then
            ok = pcall(oldager.StopDamageOverTime, oldager)
        end
        if ok and type(positionalwarp.Reset) == "function" then
            ok = pcall(positionalwarp.Reset, positionalwarp)
        end
        return ok, ok and nil or ERROR_CODES.CLEAN_FAILED
    end,
    Remove = function(player, components, context)
        return WANDA_HANDLER.Clean(player, components, context)
    end,
    Restore = function(player, components, resources)
        local positionalwarp = components.positionalwarp
        local oldager = components.oldager
        if positionalwarp == nil or oldager == nil
            or type(positionalwarp.OnLoad) ~= "function" then
            return false, ERROR_CODES.STATE_UNSUPPORTED
        end
        local ok = pcall(
            positionalwarp.OnLoad,
            positionalwarp,
            Util.CopyData(resources.positionalwarp)
        )
        if ok and type(positionalwarp.UpdateMarker) == "function" then
            ok = pcall(positionalwarp.UpdateMarker, positionalwarp)
        end
        if ok then
            oldager.year_timer = resources.year_timer
            if player.player_classified ~= nil then
                SetNetValue(
                    player.player_classified,
                    "oldager_yearpercent",
                    resources.year_timer
                )
            end
        end
        return ok, ok and nil or ERROR_CODES.STATE_UNSUPPORTED
    end,
    Match = function(actual, expected)
        return type(actual) == "table"
            and type(expected) == "table"
            and Util.DeepEqual(actual.positionalwarp, expected.positionalwarp)
            and NumbersClose(actual.year_timer, expected.year_timer, 0.05)
    end,
}

local HANDLERS =
{
    wilson = BEARD_HANDLER,
    willow = STATIC_HANDLER,
    wolfgang = WOLFGANG_HANDLER,
    wendy = WENDY_HANDLER,
    wx78 = WX78_HANDLER,
    wickerbottom = STATIC_HANDLER,
    woodie = WOODIE_HANDLER,
    wes = STATIC_HANDLER,
    waxwell = WAXWELL_HANDLER,
    wathgrithr = WATHGRITHR_HANDLER,
    webber = BEARD_HANDLER,
    winona = WINONA_HANDLER,
    warly = WARLY_HANDLER,
    wortox = WORTOX_HANDLER,
    wormwood = WORMWOOD_HANDLER,
    wurt = STATIC_HANDLER,
    walter = WALTER_HANDLER,
    wanda = WANDA_HANDLER,
    wonkey = STATIC_HANDLER,
}

local LIVE_SUPPORTED_PREFABS = {}
for prefab in pairs(HANDLERS) do
    LIVE_SUPPORTED_PREFABS[prefab] = true
end

local function MakeDefaultState(player)
    local prefab = Util.GetCharacterPrefab(player) or "unknown"
    return
    {
        prefab = prefab,
        appearance = {},
        resources = {},
        followers = {},
        pets = {},
        summoned = {},
        components = {},
        abilities = {},
        movement_speed = 1,
    }
end

local function GetHandler(prefab)
    return prefab ~= nil and HANDLERS[prefab] or nil
end

local function HasActiveStory(components)
    local storyteller = components ~= nil and components.storyteller or nil
    if storyteller == nil or type(storyteller.IsTellingStory) ~= "function" then
        return false
    end
    local ok, active = pcall(storyteller.IsTellingStory, storyteller)
    return ok and active == true
end

local function ValidateLiveRelationships(player, components, handler)
    local leader = components.leader
    if leader ~= nil then
        for follower in pairs(leader.followers or {}) do
            if type(handler.IsAllowedFollower) ~= "function"
                or not handler.IsAllowedFollower(player, follower) then
                return false
            end
        end
        if HasEntries(leader.itemfollowers) then
            return false
        end
    end
    local petleash = components.petleash
    if petleash ~= nil
        and (HasEntries(petleash.pets) or petleash.pet ~= nil) then
        return false
    end
    local ghostlybond = components.ghostlybond
    if ghostlybond ~= nil and ghostlybond.ghost ~= nil
        and type(handler.IsAllowedFollower) ~= "function" then
        return false
    end
    return true
end

local function CaptureSynthetic(player)
    local state = Util.GetTestState(player)
    if state == nil then
        return nil, ERROR_CODES.PLAYER_INVALID
    end
    state.character = state.character or MakeDefaultState(player)
    local data = Util.CopyData(state.character)
    data.prefab = data.prefab or Util.GetCharacterPrefab(player)
    data.appearance = data.appearance or {}
    data.resources = data.resources or {}
    data.followers = data.followers or {}
    data.pets = data.pets or {}
    data.summoned = data.summoned or {}
    data.components = data.components or {}
    data.abilities = data.abilities or {}
    if not ValidateState(data) then
        return nil, ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

local function CaptureLive(player)
    local prefab = Util.GetCharacterPrefab(player)
    local handler = GetHandler(prefab)
    if prefab == nil then
        return nil, ERROR_CODES.PREFAB_MISSING
    end
    if handler == nil then
        return nil, ERROR_CODES.STATE_UNSUPPORTED
    end
    local components = Util.GetComponents(player)
    if components == nil
        or not ValidateLiveRelationships(player, components, handler)
        or HasActiveStory(components) then
        return nil, ERROR_CODES.STATE_UNSUPPORTED
    end
    local resources, code = handler.Capture(player, components)
    if resources == nil then
        return nil, code or ERROR_CODES.STATE_UNSUPPORTED
    end
    local data =
    {
        prefab = prefab,
        appearance = {},
        resources = resources,
        followers = {},
        pets = {},
        summoned = {},
        components = {},
        abilities = {},
        movement_speed = nil,
        runtime = true,
    }
    if not handler.Validate(player, resources) or not ValidateState(data) then
        return nil, ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

function CharacterAdapter.Capture(player)
    if not Util.IsValidPlayer(player) then
        return nil, ERROR_CODES.PLAYER_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        return CaptureSynthetic(player)
    end
    return CaptureLive(player)
end

function CharacterAdapter.ValidateCapture(player, data)
    if not Util.IsValidPlayer(player) or not ValidateState(data) then
        return false, ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        return true
    end
    local prefab = Util.GetCharacterPrefab(player)
    local handler = GetHandler(prefab)
    return prefab == data.prefab
        and handler ~= nil
        and handler.Validate(player, data.resources)
        and LIVE_SUPPORTED_PREFABS[data.prefab] == true,
        ERROR_CODES.SNAPSHOT_INVALID
end

function CharacterAdapter.EnterCleanState(player, context)
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local old = state.character or MakeDefaultState(player)
        state.character =
        {
            prefab = old.prefab,
            appearance = Util.CopyData(old.appearance or {}),
            resources = {},
            followers = {},
            pets = {},
            summoned = {},
            components = {},
            abilities = {},
            movement_speed = old.movement_speed,
        }
        return true
    end
    local prefab = Util.GetCharacterPrefab(player)
    local handler = GetHandler(prefab)
    local components = Util.GetComponents(player)
    if handler == nil or components == nil then
        return false, ERROR_CODES.STATE_UNSUPPORTED
    end
    -- capture-first 是进入沙箱的安全门；不可完整恢复的状态绝不先清理。
    local _, capture_code = CaptureLive(player)
    if capture_code ~= nil then
        return false, capture_code
    end
    local ok, code = handler.Clean(player, components, context)
    if ok then
        context = context or {}
        context.character_clean_entered = true
    end
    return ok, code
end

function CharacterAdapter.ApplyOverrides(player, context, sandbox)
    context = context or {}
    if context.character_profile_applied then
        return true
    end
    local profile = sandbox ~= nil and sandbox.profile or context.profile
    if profile == nil then
        return false, ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local character = state.character or MakeDefaultState(player)
        character.abilities =
        {
            allowed = Util.CopyData(profile.allowed_abilities or {}),
            disabled = Util.CopyData(profile.disabled_abilities or {}),
        }
        character.components = Util.CopyData(profile.temporary_components or {})
        if profile.movement_speed ~= nil then
            state.movement_speed = profile.movement_speed
            character.movement_speed = profile.movement_speed
        end
        if profile.appearance_policy == "REPLACE" then
            character.appearance = Util.CopyData(profile.appearance or {})
        end
        state.character = character
        context.character_profile_applied = true
        return true
    end
    local allowed = profile.allowed_abilities
    local disabled = profile.disabled_abilities
    local temporary = profile.temporary_components
    if profile.movement_speed ~= nil
        or (allowed ~= nil and (type(allowed) ~= "table" or #allowed > 0))
        or (disabled ~= nil and (type(disabled) ~= "table" or #disabled > 0))
        or (temporary ~= nil and (type(temporary) ~= "table" or #temporary > 0))
        or profile.appearance_policy == "REPLACE" then
        return false, ERROR_CODES.APPLY_FAILED
    end
    local fair_applied, fair_code = FairState.Apply(player, context, profile)
    if not fair_applied then
        return false, fair_code or ERROR_CODES.APPLY_FAILED
    end
    context.character_profile_applied = true
    return true
end

function CharacterAdapter.RemoveOverrides(player, context)
    context = context or {}
    if context.character_overrides_removed then
        return true
    end
    if Util.IsSyntheticPlayer(player) then
        local cleaned, code = CharacterAdapter.EnterCleanState(player, context)
        if cleaned then
            context.character_overrides_removed = true
        end
        return cleaned, code
    end
    local handler = GetHandler(Util.GetCharacterPrefab(player))
    local components = Util.GetComponents(player)
    if handler == nil or components == nil then
        return false, ERROR_CODES.STATE_UNSUPPORTED
    end
    -- 退出时只清理沙箱内产生的状态，不重新 Capture；原始快照由 Restore 使用。
    local cleaned, code = handler.Remove(player, components, context)
    if not cleaned then
        return cleaned, code
    end
    local fair_removed, fair_code = FairState.Remove(player, context)
    if not fair_removed then
        return false, fair_code or ERROR_CODES.CLEAN_FAILED
    end
    context.character_overrides_removed = true
    return true
end

function CharacterAdapter.Restore(player, data)
    if not ValidateState(data) then
        return false, ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        state.character = Util.CopyData(data)
        state.movement_speed = data.movement_speed
        return true
    end
    local prefab = Util.GetCharacterPrefab(player)
    local handler = GetHandler(prefab)
    local components = Util.GetComponents(player)
    if prefab ~= data.prefab or handler == nil or components == nil
        or not handler.Validate(player, data.resources) then
        return false, ERROR_CODES.STATE_UNSUPPORTED
    end
    return handler.Restore(player, components, data.resources)
end

function CharacterAdapter.ValidateRestore(player, data)
    if not ValidateState(data) then
        return false, ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local actual = state ~= nil and state.character or nil
        local equal = Util.DeepEqual(actual, data)
        return equal, equal and nil or ERROR_CODES.RESTORE_MISMATCH
    end
    local actual, code = CaptureLive(player)
    if actual == nil then
        return false, code or ERROR_CODES.RESTORE_MISMATCH
    end
    if actual.prefab ~= data.prefab then
        return false, ERROR_CODES.RESTORE_MISMATCH
    end
    local handler = GetHandler(data.prefab)
    local matched = handler ~= nil
        and handler.Match(actual.resources, data.resources)
    return matched, matched and nil or ERROR_CODES.RESTORE_MISMATCH
end

function CharacterAdapter.GetLiveSupportedPrefabs()
    local result = {}
    for prefab in pairs(LIVE_SUPPORTED_PREFABS) do
        table.insert(result, prefab)
    end
    table.sort(result)
    return result
end

return CharacterAdapter
