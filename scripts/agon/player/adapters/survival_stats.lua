-- WP7：保存并恢复生命、饥饿、理智、温度、潮湿及明确登记的临时状态。

local Util = require("agon/player/adapters/util")

local SurvivalStatsAdapter = {}
SurvivalStatsAdapter.adapter_id = "survival_stats"
SurvivalStatsAdapter.version = 1
SurvivalStatsAdapter.order = 20
SurvivalStatsAdapter.dependencies = { "inventory" }

SurvivalStatsAdapter.ERROR_CODES =
{
    PLAYER_INVALID = "SURVIVAL_STATS_PLAYER_INVALID",
    COMPONENT_MISSING = "SURVIVAL_STATS_COMPONENT_MISSING",
    SNAPSHOT_INVALID = "SURVIVAL_STATS_SNAPSHOT_INVALID",
    CLEAN_FAILED = "SURVIVAL_STATS_CLEAN_FAILED",
    APPLY_FAILED = "SURVIVAL_STATS_APPLY_FAILED",
    RESTORE_FAILED = "SURVIVAL_STATS_RESTORE_FAILED",
    RESTORE_MISMATCH = "SURVIVAL_STATS_RESTORE_MISMATCH",
}

local STAT_NAMES =
{
    "health",
    "hunger",
    "sanity",
    "temperature",
    "moisture",
}

local function IsNumber(value)
    return type(value) == "number" and value == value
end

local function MakeDefaultState()
    return
    {
        health = { current = 100, max = 100, penalty = 0, invincible = false },
        hunger = { current = 100, max = 100 },
        sanity = { current = 100, max = 100, mode = 0, sane = true },
        temperature = { current = 25 },
        moisture = { current = 0, max = 100 },
        temporary = {},
    }
end

local function ValidateState(data)
    if type(data) ~= "table" then
        return false
    end
    if type(data.temporary) ~= "table" then
        return false
    end
    for index = 1, #STAT_NAMES do
        local name = STAT_NAMES[index]
        if type(data[name]) ~= "table" or not IsNumber(data[name].current) then
            return false
        end
        if data[name].max ~= nil and not IsNumber(data[name].max) then
            return false
        end
    end
    return true
end

local function ReadSaved(component)
    if component == nil then
        return nil
    end
    if type(component.OnSave) == "function" then
        local ok, saved = pcall(component.OnSave, component)
        if ok and type(saved) == "table" then
            return Util.CopyData(saved)
        end
    end
    return {}
end

local function CaptureSynthetic(player)
    local state = Util.GetTestState(player)
    if state == nil then
        return nil, SurvivalStatsAdapter.ERROR_CODES.PLAYER_INVALID
    end
    state.survival_stats = state.survival_stats or MakeDefaultState()
    local data = Util.CopyData(state.survival_stats)
    data.temporary = data.temporary or {}
    if not ValidateState(data) then
        return nil, SurvivalStatsAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

local function CaptureLive(player)
    local components = Util.GetComponents(player)
    if components == nil
        or components.health == nil
        or components.hunger == nil
        or components.sanity == nil
        or components.temperature == nil
        or components.moisture == nil then
        return nil, SurvivalStatsAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    local health = components.health
    local hunger = components.hunger
    local sanity = components.sanity
    local temperature = components.temperature
    local moisture = components.moisture
    local data =
    {
        health =
        {
            current = health.currenthealth,
            max = health.maxhealth,
            penalty = health.penalty,
            invincible = health.invincible,
            saved = ReadSaved(health),
        },
        hunger =
        {
            current = hunger.current,
            max = hunger.max,
            saved = ReadSaved(hunger),
        },
        sanity =
        {
            current = sanity.current,
            max = sanity.max,
            mode = sanity.mode,
            sane = sanity.sane,
            saved = ReadSaved(sanity),
        },
        temperature =
        {
            current = temperature.current,
            saved = ReadSaved(temperature),
        },
        moisture =
        {
            current = moisture.moisture,
            max = moisture.maxmoisture,
            saved = ReadSaved(moisture),
        },
        temporary = {},
        runtime = true,
    }
    if not ValidateState(data) then
        return nil, SurvivalStatsAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return data
end

function SurvivalStatsAdapter.Capture(player)
    if not Util.IsValidPlayer(player) then
        return nil, SurvivalStatsAdapter.ERROR_CODES.PLAYER_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        return CaptureSynthetic(player)
    end
    return CaptureLive(player)
end

function SurvivalStatsAdapter.ValidateCapture(player, data)
    if not Util.IsValidPlayer(player) or not ValidateState(data) then
        return false, SurvivalStatsAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    return true
end

function SurvivalStatsAdapter.EnterCleanState(player)
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local clean = MakeDefaultState()
        if state.survival_stats ~= nil then
            clean.health.max = state.survival_stats.health.max
            clean.health.current = clean.health.max
            clean.hunger.max = state.survival_stats.hunger.max
            clean.hunger.current = clean.hunger.max
            clean.sanity.max = state.survival_stats.sanity.max
            clean.sanity.current = clean.sanity.max
            clean.temperature.current = state.survival_stats.temperature.current
            clean.moisture.max = state.survival_stats.moisture.max
        end
        state.survival_stats = clean
        return true
    end
    local components = Util.GetComponents(player)
    if components == nil
        or components.health == nil
        or components.hunger == nil
        or components.sanity == nil
        or components.temperature == nil
        or components.moisture == nil then
        return false, SurvivalStatsAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    local ok = pcall(components.health.SetPercent, components.health, 1, false, "agon_sandbox_clean")
    ok = ok and pcall(components.hunger.SetPercent, components.hunger, 1, false)
    ok = ok and pcall(components.sanity.SetPercent, components.sanity, 1, false)
    ok = ok and pcall(components.temperature.SetTemperature, components.temperature, components.temperature.current)
    ok = ok and pcall(components.moisture.SetMoistureLevel, components.moisture, 0)
    return ok, ok and nil or SurvivalStatsAdapter.ERROR_CODES.CLEAN_FAILED
end

local function ApplySyntheticProfile(state, base_stats)
    base_stats = type(base_stats) == "table" and base_stats or {}
    local function ApplyStat(name, current_key, percent_key, max_key)
        local target = state[name]
        if target == nil then
            return
        end
        if base_stats[max_key] ~= nil and IsNumber(base_stats[max_key]) then
            target.max = base_stats[max_key]
        end
        if base_stats[current_key] ~= nil and IsNumber(base_stats[current_key]) then
            target.current = base_stats[current_key]
        elseif base_stats[percent_key] ~= nil and IsNumber(base_stats[percent_key])
            and IsNumber(target.max) then
            target.current = target.max * base_stats[percent_key]
        end
    end
    ApplyStat("health", "health", "health_percent", "max_health")
    ApplyStat("hunger", "hunger", "hunger_percent", "max_hunger")
    ApplyStat("sanity", "sanity", "sanity_percent", "max_sanity")
    ApplyStat("temperature", "temperature", "temperature_percent", "max_temperature")
    ApplyStat("moisture", "moisture", "moisture_percent", "max_moisture")
end

function SurvivalStatsAdapter.ApplyOverrides(player, context, sandbox)
    context = context or {}
    if context.stats_profile_applied then
        return true
    end
    local profile = sandbox ~= nil and sandbox.profile or context.profile
    if profile == nil then
        return false, SurvivalStatsAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        state.survival_stats = state.survival_stats or MakeDefaultState()
        ApplySyntheticProfile(state.survival_stats, profile.base_stats)
        context.stats_profile_applied = true
        return true
    end
    local components = Util.GetComponents(player)
    if components == nil then
        return false, SurvivalStatsAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    local base_stats = profile.base_stats or {}
    local ok = true
    if base_stats.health_percent ~= nil and components.health ~= nil then
        ok = pcall(components.health.SetPercent, components.health, base_stats.health_percent, false, "agon_sandbox_profile")
    end
    if ok and base_stats.hunger_percent ~= nil and components.hunger ~= nil then
        ok = pcall(components.hunger.SetPercent, components.hunger, base_stats.hunger_percent, false)
    end
    if ok and base_stats.sanity_percent ~= nil and components.sanity ~= nil then
        ok = pcall(components.sanity.SetPercent, components.sanity, base_stats.sanity_percent, false)
    end
    if ok and base_stats.temperature ~= nil and components.temperature ~= nil then
        ok = pcall(components.temperature.SetTemperature, components.temperature, base_stats.temperature)
    end
    if ok and base_stats.moisture ~= nil and components.moisture ~= nil then
        ok = pcall(components.moisture.SetMoistureLevel, components.moisture, base_stats.moisture)
    end
    if not ok then
        return false, SurvivalStatsAdapter.ERROR_CODES.APPLY_FAILED
    end
    context.stats_profile_applied = true
    return true
end

function SurvivalStatsAdapter.RemoveOverrides(player, context)
    context = context or {}
    if context.stats_overrides_removed then
        return true
    end
    local cleaned, code = SurvivalStatsAdapter.EnterCleanState(player)
    if cleaned then
        context.stats_overrides_removed = true
    end
    return cleaned, code
end

function SurvivalStatsAdapter.Restore(player, data)
    if not ValidateState(data) then
        return false, SurvivalStatsAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        state.survival_stats = Util.CopyData(data)
        return true
    end
    local components = Util.GetComponents(player)
    if components == nil then
        return false, SurvivalStatsAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    local ok = true
    if components.health ~= nil then
        ok = pcall(components.health.SetCurrentHealth, components.health, data.health.current)
    end
    if ok and components.hunger ~= nil then
        ok = pcall(components.hunger.SetCurrent, components.hunger, data.hunger.current, false)
    end
    if ok and components.sanity ~= nil then
        ok = pcall(components.sanity.SetPercent, components.sanity, data.sanity.current / data.sanity.max, false)
    end
    if ok and components.temperature ~= nil then
        ok = pcall(components.temperature.SetTemperature, components.temperature, data.temperature.current)
    end
    if ok and components.moisture ~= nil then
        ok = pcall(components.moisture.SetMoistureLevel, components.moisture, data.moisture.current)
    end
    return ok, ok and nil or SurvivalStatsAdapter.ERROR_CODES.RESTORE_FAILED
end

function SurvivalStatsAdapter.ValidateRestore(player, data)
    if not ValidateState(data) then
        return false, SurvivalStatsAdapter.ERROR_CODES.SNAPSHOT_INVALID
    end
    if Util.IsSyntheticPlayer(player) then
        local state = Util.GetTestState(player)
        local actual = state ~= nil and state.survival_stats or nil
        local equal = Util.DeepEqual(actual, data)
        return equal, equal and nil or SurvivalStatsAdapter.ERROR_CODES.RESTORE_MISMATCH
    end
    local components = Util.GetComponents(player)
    if components == nil then
        return false, SurvivalStatsAdapter.ERROR_CODES.COMPONENT_MISSING
    end
    local equal = components.health ~= nil
        and components.health.currenthealth == data.health.current
        and components.hunger ~= nil
        and components.hunger.current == data.hunger.current
        and components.sanity ~= nil
        and components.sanity.current == data.sanity.current
        and components.temperature ~= nil
        and components.temperature.current == data.temperature.current
        and components.moisture ~= nil
        and components.moisture.moisture == data.moisture.current
    return equal, equal and nil or SurvivalStatsAdapter.ERROR_CODES.RESTORE_MISMATCH
end

return SurvivalStatsAdapter
