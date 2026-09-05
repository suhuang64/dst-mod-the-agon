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
            disable_penalty = health.disable_penalty,
            saved = ReadSaved(health),
        },
        hunger =
        {
            current = hunger.current,
            max = hunger.max,
            rate = hunger.hungerrate,
            kill_rate = hunger.hurtrate,
            burning = hunger.burning,
            saved = ReadSaved(hunger),
        },
        sanity =
        {
            current = sanity.current,
            max = sanity.max,
            mode = sanity.mode,
            sane = sanity.sane,
            rate_modifier = sanity.rate_modifier,
            night_drain_mult = sanity.night_drain_mult,
            neg_aura_mult = sanity.neg_aura_mult,
            dapperness = sanity.dapperness,
            dapperness_mult = sanity.dapperness_mult,
            no_moisture_penalty = sanity.no_moisture_penalty,
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

local function IsFairProfile(profile)
    return type(profile) == "table"
        and type(profile.fair_mode) == "table"
        and profile.fair_mode.enabled == true
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
    if IsFairProfile(profile) then
        local health = components.health
        local hunger = components.hunger
        local sanity = components.sanity
        local temperature = components.temperature
        local moisture = components.moisture
        if health == nil or hunger == nil or sanity == nil
            or temperature == nil or moisture == nil then
            return false, SurvivalStatsAdapter.ERROR_CODES.COMPONENT_MISSING
        end
        local max_health = IsNumber(base_stats.max_health) and base_stats.max_health or 150
        local health_value = IsNumber(base_stats.health) and base_stats.health or max_health
        local max_hunger = IsNumber(base_stats.max_hunger) and base_stats.max_hunger or 150
        local hunger_value = IsNumber(base_stats.hunger) and base_stats.hunger or max_hunger
        local max_sanity = IsNumber(base_stats.max_sanity) and base_stats.max_sanity or 200
        local sanity_value = IsNumber(base_stats.sanity) and base_stats.sanity or max_sanity
        local temperature_value = IsNumber(base_stats.temperature) and base_stats.temperature or 25
        local moisture_value = IsNumber(base_stats.moisture) and base_stats.moisture or 0
        local hunger_rate = IsNumber(base_stats.hunger_rate)
            and base_stats.hunger_rate
            or (type(TUNING) == "table" and TUNING.WILSON_HUNGER_RATE or 1)
        local hunger_kill_rate = IsNumber(base_stats.hunger_kill_rate)
            and base_stats.hunger_kill_rate
            or (type(TUNING) == "table"
                and TUNING.WILSON_HEALTH / TUNING.STARVE_KILL_TIME
                or 1)
        local ok = pcall(health.SetMaxHealth, health, max_health)
        ok = ok and pcall(health.SetPenalty, health, 0)
        ok = ok and pcall(function() health.penalty = 0 end)
        ok = ok and pcall(health.SetInvincible, health, false)
        ok = ok and pcall(health.SetCurrentHealth, health, health_value)
        ok = ok and pcall(hunger.SetMax, hunger, max_hunger)
        ok = ok and pcall(hunger.SetRate, hunger, hunger_rate)
        ok = ok and pcall(hunger.SetKillRate, hunger, hunger_kill_rate)
        if ok then
            if hunger.burning == false then
                ok = pcall(hunger.Resume, hunger)
            end
        end
        ok = ok and pcall(hunger.SetCurrent, hunger, hunger_value, false)
        ok = ok and pcall(sanity.SetMax, sanity, max_sanity)
        ok = ok and pcall(function() sanity.penalty = 0 end)
        ok = ok and pcall(sanity.SetCurrent, sanity, sanity_value)
        if ok then
            ok = pcall(function()
                sanity.sane = true
                if SANITY_MODE_INSANITY ~= nil then
                    sanity.mode = SANITY_MODE_INSANITY
                end
            end)
        end
        ok = ok and pcall(temperature.SetTemperature, temperature, temperature_value)
        ok = ok and pcall(moisture.SetMoistureLevel, moisture, moisture_value)
        if not ok then
            return false, SurvivalStatsAdapter.ERROR_CODES.APPLY_FAILED
        end
        context.stats_profile_applied = true
        return true
    end
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
        if data.health.disable_penalty ~= nil then
            ok = pcall(function()
                components.health.disable_penalty = data.health.disable_penalty
            end)
        end
        if ok and data.health.max ~= nil then
            ok = pcall(components.health.SetMaxHealth, components.health, data.health.max)
        end
        if ok and data.health.penalty ~= nil then
            ok = pcall(components.health.SetPenalty, components.health, data.health.penalty)
        end
        if ok and data.health.invincible ~= nil then
            ok = pcall(components.health.SetInvincible, components.health, data.health.invincible)
        end
        if ok then
            ok = pcall(components.health.SetCurrentHealth, components.health, data.health.current)
        end
    end
    if ok and components.hunger ~= nil then
        if data.hunger.max ~= nil then
            ok = pcall(components.hunger.SetMax, components.hunger, data.hunger.max)
        end
        if ok and data.hunger.rate ~= nil then
            ok = pcall(components.hunger.SetRate, components.hunger, data.hunger.rate)
        end
        if ok and data.hunger.kill_rate ~= nil then
            ok = pcall(components.hunger.SetKillRate, components.hunger, data.hunger.kill_rate)
        end
        if ok and data.hunger.burning == false then
            ok = pcall(components.hunger.Pause, components.hunger)
        elseif ok and data.hunger.burning == true then
            ok = pcall(components.hunger.Resume, components.hunger)
        end
        if ok then
            ok = pcall(components.hunger.SetCurrent, components.hunger, data.hunger.current, false)
        end
    end
    if ok and components.sanity ~= nil then
        if data.sanity.max ~= nil then
            ok = pcall(components.sanity.SetMax, components.sanity, data.sanity.max)
        end
        if ok then
            ok = pcall(components.sanity.SetCurrent, components.sanity, data.sanity.current)
        end
        if ok then
            ok = pcall(function()
                if data.sanity.mode ~= nil then
                    components.sanity.mode = data.sanity.mode
                end
                if data.sanity.sane ~= nil then
                    components.sanity.sane = data.sanity.sane
                end
            end)
        end
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
        and (data.health.max == nil or components.health.maxhealth == data.health.max)
        and (data.health.penalty == nil or components.health.penalty == data.health.penalty)
        and (data.health.invincible == nil or components.health.invincible == data.health.invincible)
        and components.hunger ~= nil
        and components.hunger.current == data.hunger.current
        and (data.hunger.max == nil or components.hunger.max == data.hunger.max)
        and components.sanity ~= nil
        and components.sanity.current == data.sanity.current
        and (data.sanity.max == nil or components.sanity.max == data.sanity.max)
        and (data.sanity.mode == nil or components.sanity.mode == data.sanity.mode)
        and (data.sanity.sane == nil or components.sanity.sane == data.sanity.sane)
        and components.temperature ~= nil
        and components.temperature.current == data.temperature.current
        and components.moisture ~= nil
        and components.moisture.moisture == data.moisture.current
    return equal, equal and nil or SurvivalStatsAdapter.ERROR_CODES.RESTORE_MISMATCH
end

return SurvivalStatsAdapter
