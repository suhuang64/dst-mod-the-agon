-- WP6 TestMode：只通过 Instance-owned entity 应用 Profile，不写全局 TUNING。

local EntityProfileRegistry = require("agon/services/entity_profile_registry")

local TestModeProfiles = {}

local function AddTag(entity, tag)
    if entity ~= nil and type(entity.AddTag) == "function" then
        pcall(entity.AddTag, entity, tag)
    end
end

local function RemoveTag(entity, tag)
    if entity ~= nil and type(entity.RemoveTag) == "function" then
        pcall(entity.RemoveTag, entity, tag)
    end
end

local function GetComponent(entity, name)
    if entity == nil or entity.components == nil then
        return nil
    end
    return entity.components[name]
end

local function ApplyFlower(entity, context)
    AddTag(entity, "agon_test_flower_profile")
    entity._agon_test_profile_display = context.profile.profile_id
    return { tag = "agon_test_flower_profile" }
end

local function RemoveFlower(entity)
    RemoveTag(entity, "agon_test_flower_profile")
    entity._agon_test_profile_display = nil
end

local function ApplyFlowerDisplay(entity, context)
    AddTag(entity, "agon_test_replicated_profile")
    entity._agon_test_profile_display = context.profile.metadata.display_name
    entity._agon_test_profile_accent = context.profile.metadata.accent
    return { tag = "agon_test_replicated_profile" }
end

local function RemoveFlowerDisplay(entity)
    RemoveTag(entity, "agon_test_replicated_profile")
    entity._agon_test_profile_display = nil
    entity._agon_test_profile_accent = nil
end

local function ApplySpiderPower(entity)
    local health = GetComponent(entity, "health")
    local combat = GetComponent(entity, "combat")
    local state =
    {
        maxhealth = health ~= nil and health.maxhealth or nil,
        currenthealth = health ~= nil and health.currenthealth or nil,
        damage = combat ~= nil and combat.defaultdamage or nil,
    }
    if health ~= nil and type(health.SetMaxHealth) == "function"
        and type(state.maxhealth) == "number" then
        health:SetMaxHealth(state.maxhealth * 2)
        if type(health.SetCurrentHealth) == "function"
            and type(state.currenthealth) == "number" then
            health:SetCurrentHealth(state.currenthealth)
        end
    end
    if combat ~= nil and type(combat.SetDefaultDamage) == "function"
        and type(state.damage) == "number" then
        combat:SetDefaultDamage(state.damage * 2)
    end
    AddTag(entity, "agon_test_power_profile")
    return state
end

local function RemoveSpiderPower(entity, _, state)
    local health = GetComponent(entity, "health")
    local combat = GetComponent(entity, "combat")
    if health ~= nil and type(health.SetMaxHealth) == "function"
        and type(state) == "table" and type(state.maxhealth) == "number" then
        health:SetMaxHealth(state.maxhealth)
        if type(health.SetCurrentHealth) == "function"
            and type(state.currenthealth) == "number" then
            health:SetCurrentHealth(math.min(state.currenthealth, state.maxhealth))
        end
    end
    if combat ~= nil and type(combat.SetDefaultDamage) == "function"
        and type(state) == "table" and type(state.damage) == "number" then
        combat:SetDefaultDamage(state.damage)
    end
    RemoveTag(entity, "agon_test_power_profile")
end

local function RefreshSpiderBrain(entity)
    if entity ~= nil and type(entity.StopBrain) == "function"
        and type(entity.RestartBrain) == "function" then
        entity:StopBrain("agon_test_profile")
        entity:RestartBrain("agon_test_profile")
    end
end

local function ApplySpiderGuard(entity)
    local state = { defensive = entity.defensive }
    entity.defensive = true
    AddTag(entity, "agon_test_guard_profile")
    RefreshSpiderBrain(entity)
    return state
end

local function RemoveSpiderGuard(entity, _, state)
    entity.defensive = type(state) == "table" and state.defensive or nil
    RemoveTag(entity, "agon_test_guard_profile")
    RefreshSpiderBrain(entity)
end

local function ApplyTorchPower(entity)
    local weapon = GetComponent(entity, "weapon")
    local fueled = GetComponent(entity, "fueled")
    local state =
    {
        damage = weapon ~= nil and weapon.damage or nil,
        fuel_rate_mult = entity._fuelratemult,
    }
    if weapon ~= nil and type(weapon.SetDamage) == "function"
        and type(state.damage) == "number" then
        weapon:SetDamage(state.damage * 2)
    end
    if type(entity.SetFuelRateMult) == "function" and fueled ~= nil then
        entity:SetFuelRateMult(.5)
    end
    AddTag(entity, "agon_test_power_item")
    return state
end

local function ApplyTorchLight(entity)
    local weapon = GetComponent(entity, "weapon")
    local fueled = GetComponent(entity, "fueled")
    local state =
    {
        damage = weapon ~= nil and weapon.damage or nil,
        fuel_rate_mult = entity._fuelratemult,
    }
    if weapon ~= nil and type(weapon.SetDamage) == "function"
        and type(state.damage) == "number" then
        weapon:SetDamage(state.damage * .5)
    end
    if type(entity.SetFuelRateMult) == "function" and fueled ~= nil then
        entity:SetFuelRateMult(2)
    end
    AddTag(entity, "agon_test_light_item")
    return state
end

local function RemoveTorch(entity, _, state)
    local weapon = GetComponent(entity, "weapon")
    if weapon ~= nil and type(weapon.SetDamage) == "function"
        and type(state) == "table" and type(state.damage) == "number" then
        weapon:SetDamage(state.damage)
    end
    if type(entity.SetFuelRateMult) == "function" then
        local fuel_rate_mult = type(state) == "table" and state.fuel_rate_mult or nil
        entity:SetFuelRateMult(fuel_rate_mult or 1)
    end
    RemoveTag(entity, "agon_test_power_item")
    RemoveTag(entity, "agon_test_light_item")
end

local PROFILES =
{
    {
        profile_id = "TEST_FLOWER",
        version = 1,
        prefab = "flower",
        apply_mode = EntityProfileRegistry.APPLY_MODES.SPAWN_ONLY,
        replication_mode = EntityProfileRegistry.REPLICATION_MODES.SERVER_ONLY,
        adapter =
        {
            Apply = ApplyFlower,
            Remove = RemoveFlower,
        },
        metadata =
        {
            display_name = "Test Flower",
            accent = "white",
        },
    },
    {
        profile_id = "TEST_FLOWER_DISPLAY",
        version = 1,
        prefab = "flower",
        apply_mode = EntityProfileRegistry.APPLY_MODES.SPAWN_ONLY,
        replication_mode = EntityProfileRegistry.REPLICATION_MODES.REPLICATED,
        client_contract =
        {
            contract_id = "agon.test.entity_profile_display",
            version = 1,
            fields = { "profile_id", "profile_version", "display_name", "accent" },
        },
        adapter =
        {
            Apply = ApplyFlowerDisplay,
            Remove = RemoveFlowerDisplay,
        },
        metadata =
        {
            display_name = "Replicated Flower",
            accent = "gold",
        },
    },
    {
        profile_id = "TEST_SPIDER_POWER",
        version = 1,
        prefab = "spider",
        apply_mode = EntityProfileRegistry.APPLY_MODES.SPAWN_ONLY,
        replication_mode = EntityProfileRegistry.REPLICATION_MODES.SERVER_ONLY,
        adapter =
        {
            Apply = ApplySpiderPower,
            Remove = RemoveSpiderPower,
        },
        metadata =
        {
            display_name = "Double Spider",
            behavior = "power",
        },
    },
    {
        profile_id = "TEST_SPIDER_GUARD",
        version = 1,
        prefab = "spider",
        apply_mode = EntityProfileRegistry.APPLY_MODES.BLOCKING_ONLY,
        replication_mode = EntityProfileRegistry.REPLICATION_MODES.SERVER_ONLY,
        adapter =
        {
            Apply = ApplySpiderGuard,
            Remove = RemoveSpiderGuard,
        },
        metadata =
        {
            display_name = "Defensive Spider",
            behavior = "defensive_follow",
        },
    },
    {
        profile_id = "TEST_TORCH_POWER",
        version = 1,
        prefab = "torch",
        apply_mode = EntityProfileRegistry.APPLY_MODES.SPAWN_ONLY,
        replication_mode = EntityProfileRegistry.REPLICATION_MODES.SERVER_ONLY,
        adapter =
        {
            Apply = ApplyTorchPower,
            Remove = RemoveTorch,
        },
        metadata =
        {
            display_name = "Power Torch",
            behavior = "double_damage_half_fuel_rate",
        },
    },
    {
        profile_id = "TEST_TORCH_LIGHT",
        version = 1,
        prefab = "torch",
        apply_mode = EntityProfileRegistry.APPLY_MODES.SPAWN_ONLY,
        replication_mode = EntityProfileRegistry.REPLICATION_MODES.SERVER_ONLY,
        adapter =
        {
            Apply = ApplyTorchLight,
            Remove = RemoveTorch,
        },
        metadata =
        {
            display_name = "Light Torch",
            behavior = "half_damage_double_fuel_rate",
        },
    },
}

TestModeProfiles.PROFILES = PROFILES
TestModeProfiles.PROFILE_IDS = {}
for index = 1, #PROFILES do
    table.insert(TestModeProfiles.PROFILE_IDS, PROFILES[index].profile_id)
end

function TestModeProfiles.Register(registry)
    if type(registry) ~= "table" or type(registry.RegisterMany) ~= "function" then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_PROFILE
    end
    return registry:RegisterMany(PROFILES)
end

return TestModeProfiles
