-- TestMode 真实玩家公平状态。
-- 这里保存的是运行时引用，不进入事务快照；退出时必须完整撤销所有覆盖。

local Util = require("agon/player/adapters/util")
local TechTree = require("techtree")

local FairState = {}

FairState.ERROR_CODES =
{
    APPLY_FAILED = "CHARACTER_FAIR_STATE_APPLY_FAILED",
    RESTORE_FAILED = "CHARACTER_FAIR_STATE_RESTORE_FAILED",
}

-- 这些标签代表官方角色差异。bearded 是外观标签，保留它；其保暖效果
-- 由 temperature 的公平字段统一处理，避免公平模式改变角色外观。
local ROLE_TAGS =
{
    "scientist",
    "pyromaniac", "expertchef", "bernieowner", "heatresistant",
    "bernie_reviver", "quagmire_shopper",
    "strongman", "mightiness_normal", "mightiness_mighty",
    "ghostlyfriend", "ghostfriend_summoned", "ghostfriend_notsummoned",
    "elixirbrewer",
    "electricdamageimmune", "batteryuser", "chessfriend", "HASHEATER",
    "soulless", "upgrademoduleowner", "wx78_shield",
    "insomniac", "bookbuilder", "reader",
    "woodcutter", "polite", "werehuman", "werebeaver", "weremoose",
    "weregoose", "mime", "balloonomancer",
    "shadowmagic", "dappereffects", "magician",
    "valkyrie", "battlesinger",
    "spiderwhisperer", "playermonster", "monster", "dualsoul",
    "eatsrawmeat", "strongstomach",
    "handyperson", "fastbuilder", "hungrybuilder",
    "masterchef", "professionalchef",
    "soulstealer", "souleater", "plantkin", "self_fertilizable",
    "playermerm", "merm", "mermguard", "mermfluent", "merm_builder",
    "wet", "stronggrip", "aspiring_bookworm",
    "pebblemaker", "pinetreepioneer", "allergictobees",
    "slingshot_sharpshooter", "dogrider", "nowormholesanityloss",
    "storyteller", "clockmaker", "pocketwatchcaster", "health_as_oldage",
    "slowbuilder",
    "wonkey", "monkey",
    "meat_eater", "goodies_eater", "vegetarian_eater", "preparedfood_eater",
    "pre-preparedfood_eater", "raw_eater", "gears_eater", "nitre_eater",
    "horrible_eater", "OMNI_eater",
}

local function IsEnabled(profile)
    return type(profile) == "table"
        and type(profile.fair_mode) == "table"
        and profile.fair_mode.enabled == true
        and profile.fair_mode.disable_character_traits == true
end

local function IsLivePlayer(player)
    return Util.IsValidPlayer(player) and not Util.IsSyntheticPlayer(player)
end

local function IsFunction(object, method)
    return object ~= nil and type(object[method]) == "function"
end

local function Call(object, method, ...)
    if not IsFunction(object, method) then
        return true
    end
    local ok = pcall(object[method], object, ...)
    return ok
end

local function SetNetValue(object, field, value)
    if object == nil then
        return true
    end
    local netvar = object[field]
    if netvar == nil or type(netvar.set) ~= "function" then
        return true
    end
    return pcall(netvar.set, netvar, value)
end

local function SaveField(state, object, field)
    if object == nil then
        return true
    end
    table.insert(state.fields, { object = object, field = field, value = object[field] })
    return true
end

local function SetField(state, object, field, value)
    if object == nil then
        return true
    end
    SaveField(state, object, field)
    local ok = pcall(function()
        object[field] = value
    end)
    return ok
end

local function AddWrapper(state, object, method, replacement)
    if not IsFunction(object, method) then
        return true
    end
    local entry =
    {
        object = object,
        method = method,
        original = object[method],
        had_value = object[method] ~= nil,
    }
    table.insert(state.wrappers, entry)
    local ok = pcall(function()
        object[method] = replacement
    end)
    return ok
end

local function RemoveCurrentRoleTags(player)
    if type(player.HasTag) ~= "function" or type(player.RemoveTag) ~= "function" then
        return true
    end
    for index = 1, #ROLE_TAGS do
        local tag = ROLE_TAGS[index]
        local has_tag = false
        local ok = pcall(function()
            has_tag = player:HasTag(tag)
        end)
        if not ok then
            return false
        end
        if has_tag then
            local removed = pcall(player.RemoveTag, player, tag)
            if not removed then
                return false
            end
        end
    end
    return true
end

local function CaptureAndRemoveRoleTags(player, state)
    if type(player.HasTag) ~= "function" or type(player.RemoveTag) ~= "function" then
        return true
    end
    for index = 1, #ROLE_TAGS do
        local tag = ROLE_TAGS[index]
        local has_tag = false
        local ok = pcall(function()
            has_tag = player:HasTag(tag)
        end)
        if not ok then
            return false
        end
        if has_tag then
            state.tags[tag] = true
            local removed = pcall(player.RemoveTag, player, tag)
            if not removed then
                return false
            end
        end
    end
    return true
end

local function RestoreRoleTags(player, state)
    if type(player.AddTag) ~= "function" or type(player.RemoveTag) ~= "function" then
        return true
    end
    if not RemoveCurrentRoleTags(player) then
        return false
    end
    for tag in pairs(state.tags) do
        local ok = pcall(player.AddTag, player, tag)
        if not ok then
            return false
        end
    end
    return true
end

local function RestoreFields(state)
    for index = #state.fields, 1, -1 do
        local entry = state.fields[index]
        local ok = pcall(function()
            entry.object[entry.field] = entry.value
        end)
        if not ok then
            return false
        end
    end
    return true
end

local function RestoreWrappers(state)
    for index = #state.wrappers, 1, -1 do
        local entry = state.wrappers[index]
        local ok = pcall(function()
            entry.object[entry.method] = entry.original
        end)
        if not ok then
            return false
        end
    end
    return true
end

local function NormalizeSanitySources(player, sanity, prefab, state)
    state.sanity_sources = { prefab = prefab }
    if prefab == "wendy" then
        state.sanity_sources.wendy_ghost = true
        if not Call(sanity, "RemoveSanityAuraImmunity", "ghost", player)
            or not Call(sanity, "SetPlayerGhostImmunity", false, player) then
            return false
        end
    elseif prefab == "walter" then
        state.sanity_sources.walter = true
        if not Call(sanity, "SetNegativeAuraImmunity", false, player)
            or not Call(sanity, "SetPlayerGhostImmunity", false, player)
            or not Call(sanity, "SetLightDrainImmune", false, player) then
            return false
        end
    end
    return true
end

local function RestoreSanitySources(player, sanity, state)
    local sources = state.sanity_sources or {}
    if sources.wendy_ghost then
        if not Call(sanity, "AddSanityAuraImmunity", "ghost", player)
            or not Call(sanity, "SetPlayerGhostImmunity", true, player) then
            return false
        end
    elseif sources.walter then
        if not Call(sanity, "SetNegativeAuraImmunity", true, player)
            or not Call(sanity, "SetPlayerGhostImmunity", true, player)
            or not Call(sanity, "SetLightDrainImmune", true, player) then
            return false
        end
    end
    return true
end

local function NormalizeEater(state, eater)
    if eater == nil then
        return true
    end
    SaveField(state, eater, "caneat")
    SaveField(state, eater, "preferseating")
    SaveField(state, eater, "preferseatingtags")
    SaveField(state, eater, "oneatfn")
    SaveField(state, eater, "healthabsorption")
    SaveField(state, eater, "hungerabsorption")
    SaveField(state, eater, "sanityabsorption")
    SaveField(state, eater, "strongstomach")
    SaveField(state, eater, "eatsrawmeat")
    SaveField(state, eater, "ignoresspoilage")
    SaveField(state, eater, "nospoiledfood")
    SaveField(state, eater, "stale_hunger")
    SaveField(state, eater, "stale_health")

    local omni = type(FOODGROUP) == "table" and FOODGROUP.OMNI or nil
    if omni ~= nil and not Call(eater, "SetDiet", { omni }, { omni }) then
        return false
    end
    if not Call(eater, "SetOnEatFn", nil)
        or not Call(eater, "SetAbsorptionModifiers", 1, 1, 1)
        or not Call(eater, "SetStrongStomach", false)
        or not Call(eater, "SetCanEatRawMeat", false)
        or not Call(eater, "SetIgnoresSpoilage", false)
        or not Call(eater, "SetRefusesSpoiledFood", false) then
        return false
    end
    if not SetField(state, eater, "preferseatingtags", nil)
        or not SetField(state, eater, "stale_hunger", nil)
        or not SetField(state, eater, "stale_health", nil) then
        return false
    end
    return true
end

local function NormalizeBuilder(state, builder)
    if builder == nil then
        return true
    end
    if not SetField(state, builder, "ingredientmod", 1)
        or not SetField(state, builder, "mashturfcrafting_bonus", 0)
        or not SetField(state, builder, "freebuildmode", false) then
        return false
    end
    if type(TechTree) == "table" and type(TechTree.BONUS_TECH) == "table" then
        for _, tech in ipairs(TechTree.BONUS_TECH) do
            local normal_name = (type(TechTree.AVAILABLE_TECH_BONUS) == "table"
                and TechTree.AVAILABLE_TECH_BONUS[tech])
                or string.lower(tech).."_bonus"
            local temp_name = (type(TechTree.AVAILABLE_TECH_TEMPBONUS) == "table"
                and TechTree.AVAILABLE_TECH_TEMPBONUS[tech])
                or string.lower(tech).."_tempbonus"
            if not SetField(state, builder, normal_name, 0)
                or not SetField(state, builder, temp_name, 0) then
                return false
            end
        end
    end
    return true
end

local function NormalizeLocomotor(state, locomotor, fair_mode)
    if locomotor == nil then
        return true
    end
    local movement = type(fair_mode.movement) == "table" and fair_mode.movement or {}
    local walk_speed = movement.walk_speed or (type(TUNING) == "table" and TUNING.WILSON_WALK_SPEED) or 4
    local run_speed = movement.run_speed or (type(TUNING) == "table" and TUNING.WILSON_RUN_SPEED) or 6
    if not SetField(state, locomotor, "walkspeed", walk_speed)
        or not SetField(state, locomotor, "runspeed", run_speed)
        or not SetField(state, locomotor, "fasteroncreep", false)
        or not SetField(state, locomotor, "triggerscreep", true)
        or not SetField(state, locomotor, "groundspeedmultiplier", 1)
        or not SetField(state, locomotor, "enablegroundspeedmultiplier", true)
        or not SetField(state, locomotor, "externalspeedmultiplier", 1) then
        return false
    end

    state.faster_on_tiles = {}
    for tile, enabled in pairs(locomotor.faster_on_tiles or {}) do
        state.faster_on_tiles[tile] = enabled
        if enabled and not Call(locomotor, "SetFasterOnGroundTile", tile, false) then
            return false
        end
    end
    if not SetField(state, locomotor, "faster_on_tiles", {}) then
        return false
    end

    if not AddWrapper(state, locomotor, "ExternalSpeedMultiplier", function()
        return 1
    end)
        or not AddWrapper(state, locomotor, "GetExternalSpeedMultiplier", function()
            return 1
        end)
        or not AddWrapper(state, locomotor, "SetExternalSpeedMultiplier", function()
            return nil
        end)
        or not AddWrapper(state, locomotor, "FasterOnCreep", function()
            return false
        end)
        or not AddWrapper(state, locomotor, "IsFasterOnGroundTile", function()
            return false
        end) then
        return false
    end
    return true
end

local function NormalizeFreezable(state, freezable)
    if freezable == nil then
        return true
    end
    if not SetField(state, freezable, "resistance", 1)
        or not SetField(state, freezable, "extraresist", 0)
        or not SetField(state, freezable, "redirectfn", nil)
        or not AddWrapper(state, freezable, "SetResistance", function()
            return nil
        end)
        or not AddWrapper(state, freezable, "SetRedirectFn", function()
            return nil
        end) then
        return false
    end
    return true
end

local function NormalizeFuelMaster(state, fuelmaster)
    if fuelmaster == nil then
        return true
    end
    if not SetField(state, fuelmaster, "bonusmult", 1)
        or not SetField(state, fuelmaster, "bonusfn", nil)
        or not AddWrapper(state, fuelmaster, "GetBonusMult", function()
            return 1
        end)
        or not AddWrapper(state, fuelmaster, "SetBonusMult", function()
            return nil
        end)
        or not AddWrapper(state, fuelmaster, "SetBonusFn", function()
            return nil
        end) then
        return false
    end
    return true
end

local function NormalizeMightiness(state, mightiness)
    if mightiness == nil then
        return true
    end
    local max = type(mightiness.max) == "number" and mightiness.max or 0
    if not SetField(state, mightiness, "current", max * 0.5)
        or not SetField(state, mightiness, "state", "normal")
        or not SetField(state, mightiness, "draining", false)
        or not SetField(state, mightiness, "rate", 0)
        or not SetField(state, mightiness, "drain_multiplier", 1)
        or not AddWrapper(state, mightiness, "DoDelta", function()
            return nil
        end)
        or not AddWrapper(state, mightiness, "DoDec", function()
            return nil
        end)
        or not AddWrapper(state, mightiness, "SetPercent", function()
            return nil
        end)
        or not AddWrapper(state, mightiness, "SetMax", function()
            return nil
        end)
        or not AddWrapper(state, mightiness, "SetRate", function()
            return nil
        end)
        or not AddWrapper(state, mightiness, "BecomeState", function()
            return nil
        end)
        or not AddWrapper(state, mightiness, "Resume", function()
            return nil
        end)
        or not AddWrapper(state, mightiness, "GetState", function()
            return "normal"
        end)
        or not AddWrapper(state, mightiness, "IsMighty", function()
            return false
        end)
        or not AddWrapper(state, mightiness, "IsNormal", function()
            return true
        end)
        or not AddWrapper(state, mightiness, "IsWimpy", function()
            return false
        end)
        or not AddWrapper(state, mightiness, "GetScale", function()
            return 1
        end)
        or not AddWrapper(state, mightiness, "GetPercent", function()
            return 0.5
        end)
        or not AddWrapper(state, mightiness, "GetCurrent", function(self)
            return (self.max or 0) * 0.5
        end) then
        return false
    end
    return true
end

local function NormalizeBloomness(player, state, bloomness)
    if bloomness == nil then
        return true
    end
    if not SetField(state, bloomness, "level", 0)
        or not SetField(state, bloomness, "timer", 0)
        or not SetField(state, bloomness, "rate", 1)
        or not SetField(state, bloomness, "is_blooming", false)
        or not SetField(state, bloomness, "fertilizer", 0)
        or not SetField(state, bloomness, "onlevelchangedfn", nil)
        or not SetField(state, bloomness, "calcratefn", nil)
        or not SetField(state, bloomness, "calcfullbloomdurationfn", nil)
        or not Call(player, "StopUpdatingComponent", bloomness)
        or not AddWrapper(state, bloomness, "SetLevel", function()
            return nil
        end)
        or not AddWrapper(state, bloomness, "Fertilize", function()
            return nil
        end)
        or not AddWrapper(state, bloomness, "UpdateRate", function()
            return nil
        end)
        or not AddWrapper(state, bloomness, "OnUpdate", function()
            return nil
        end)
        or not AddWrapper(state, bloomness, "LongUpdate", function()
            return nil
        end)
        or not AddWrapper(state, bloomness, "GetLevel", function()
            return 0
        end) then
        return false
    end
    return true
end

local function NormalizeOldAger(player, state, oldager)
    if oldager == nil then
        return true
    end
    if not SetField(state, oldager, "rate", 0)
        or not SetField(state, oldager, "damage_remaining", 0)
        or not SetField(state, oldager, "damage_per_second", 0)
        or not AddWrapper(state, oldager, "OnTakeDamage", function()
            return true
        end)
        or not AddWrapper(state, oldager, "OnUpdate", function()
            return nil
        end)
        or not AddWrapper(state, oldager, "LongUpdate", function()
            return nil
        end)
        or not AddWrapper(state, oldager, "FastForwardDamageOverTime", function()
            return nil
        end) then
        return false
    end
    return true
end

local function NormalizeFoodMemory(state, foodmemory)
    if foodmemory == nil then
        return true
    end
    if not SetField(state, foodmemory, "foods", {})
        or not AddWrapper(state, foodmemory, "RememberFood", function()
            return nil
        end)
        or not AddWrapper(state, foodmemory, "GetMemoryCount", function()
            return 0
        end)
        or not AddWrapper(state, foodmemory, "GetFoodMultiplier", function()
            return 1
        end) then
        return false
    end
    return true
end

local function NormalizeSoulEater(state, souleater)
    if souleater == nil then
        return true
    end
    if not SetField(state, souleater, "oneatsoulfn", nil)
        or not AddWrapper(state, souleater, "EatSoul", function()
            return false
        end)
        or not AddWrapper(state, souleater, "SetOnEatSoulFn", function()
            return nil
        end) then
        return false
    end
    return true
end

local function NormalizeGhostlyBond(state, ghostlybond)
    if ghostlybond == nil then
        return true
    end
    if not SetField(state, ghostlybond, "pause", true)
        or not SetField(state, ghostlybond, "summoned", false)
        or not SetField(state, ghostlybond, "notsummoned", true)
        or not SetField(state, ghostlybond, "onbondlevelchangefn", nil)
        or not SetField(state, ghostlybond, "onsummonfn", nil)
        or not SetField(state, ghostlybond, "onrecallfn", nil)
        or not SetField(state, ghostlybond, "onsummoncompletefn", nil)
        or not SetField(state, ghostlybond, "changebehaviourfn", nil)
        or not AddWrapper(state, ghostlybond, "Summon", function()
            return false
        end)
        or not AddWrapper(state, ghostlybond, "SummonComplete", function()
            return nil
        end)
        or not AddWrapper(state, ghostlybond, "SpawnGhost", function()
            return nil
        end)
        or not AddWrapper(state, ghostlybond, "SetBondLevel", function()
            return nil
        end)
        or not AddWrapper(state, ghostlybond, "ResumeBonding", function()
            return nil
        end)
        or not AddWrapper(state, ghostlybond, "ChangeBehaviour", function()
            return false
        end)
        or not AddWrapper(state, ghostlybond, "SetBondTimeMultiplier", function()
            return nil
        end) then
        return false
    end
    return true
end

local function NormalizeStoryteller(state, storyteller)
    if storyteller == nil then
        return true
    end
    if not SetField(state, storyteller, "story", nil)
        or not AddWrapper(state, storyteller, "TellStory", function()
            return false
        end)
        or not AddWrapper(state, storyteller, "OnStoryTick", function()
            return nil
        end)
        or not AddWrapper(state, storyteller, "IsTellingStory", function()
            return false
        end)
        or not AddWrapper(state, storyteller, "SetStoryToTellFn", function()
            return nil
        end)
        or not AddWrapper(state, storyteller, "SetOnStoryBeginFn", function()
            return nil
        end)
        or not AddWrapper(state, storyteller, "SetOnStoryOverFn", function()
            return nil
        end) then
        return false
    end
    return true
end

local function NormalizeSingingInspiration(player, state, inspiration)
    if inspiration == nil then
        return true
    end

    if not SetField(state, inspiration, "current", 0)
        or not SetField(state, inspiration, "active_songs", {})
        or not SetField(state, inspiration, "available_slots", 0)
        or not SetField(state, inspiration, "is_draining", false)
        or not SetField(state, inspiration, "last_attack_time", nil)
        or not SetField(state, inspiration, "display_fx_count", nil)
        or not SetField(state, inspiration, "validvictimfn", nil) then
        return false
    end

    local classified = player ~= nil and player.player_classified or nil
    if not SetNetValue(classified, "currentinspiration", 0)
        or not SetNetValue(classified, "inspirationdraining", false)
        or not SetNetValue(classified, "hasinspirationbuff", false) then
        return false
    end
    if classified ~= nil and type(classified.inspirationsongs) == "table" then
        for index = 1, #classified.inspirationsongs do
            if not SetNetValue(classified.inspirationsongs, index, 0) then
                return false
            end
        end
    end

    if not AddWrapper(state, player, "GetInspiration", function()
        return 0
    end)
        or not AddWrapper(state, player, "GetInspirationSong", function()
            return nil
        end)
        or not AddWrapper(state, player, "CalcAvailableSlotsForInspiration", function()
            return 0
        end)
        or not AddWrapper(state, inspiration, "SetCalcAvailableSlotsForInspirationFn", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "SetMaxInspiration", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "SetInspiration", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "SetPercent", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "GetMaxInspiration", function()
            return 0
        end)
        or not AddWrapper(state, inspiration, "GetPercent", function()
            return 0
        end)
        or not AddWrapper(state, inspiration, "GetDetachRadius", function()
            return 0
        end)
        or not AddWrapper(state, inspiration, "IsSongActive", function()
            return false
        end)
        or not AddWrapper(state, inspiration, "GetActiveSong", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "IsSinging", function()
            return false
        end)
        or not AddWrapper(state, inspiration, "OnAttacked", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "OnHitOther", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "OnRidingTick", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "DoDelta", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "CanAddSong", function()
            return false
        end)
        or not AddWrapper(state, inspiration, "DisplayFx", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "OnAddInstantSong", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "AddSong", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "PopSong", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "FindFriendlyTargetsToInspire", function()
            return {}
        end)
        or not AddWrapper(state, inspiration, "InstantInspire", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "Inspire", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "SetValidVictimFn", function()
            return nil
        end)
        or not AddWrapper(state, inspiration, "OnUpdate", function()
            return nil
        end) then
        return false
    end
    return true
end

local function NormalizeBattleborn(state, battleborn)
    if battleborn == nil then
        return true
    end
    if not SetField(state, battleborn, "battleborn", 0)
        or not SetField(state, battleborn, "battleborn_time", 0)
        or not SetField(state, battleborn, "battleborn_bonus", 0)
        or not SetField(state, battleborn, "health_enabled", false)
        or not SetField(state, battleborn, "sanity_enabled", false)
        or not SetField(state, battleborn, "ontriggerfn", nil)
        or not SetField(state, battleborn, "validvictimfn", nil) then
        return false
    end
    if not AddWrapper(state, battleborn, "SetTriggerThreshold", function()
        return nil
    end)
        or not AddWrapper(state, battleborn, "SetDecayTime", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "SetStoreTime", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "SetOnTriggerFn", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "SetBattlebornBonus", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "SetSanityEnabled", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "SetHealthEnabled", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "SetClampMin", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "SetClampMax", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "SetValidVictimFn", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "OnAttack", function()
            return nil
        end)
        or not AddWrapper(state, battleborn, "OnDeath", function()
            return nil
        end) then
        return false
    end
    return true
end

local function NormalizeWandaState(player, state, components)
    if not SetField(state, player, "age_state", "normal")
        or not SetField(state, player, "overrideskinmode", nil)
        or not SetField(state, player, "resurrect_multiplier", 1)
        or not SetField(state, player, "_no_healing", false)
        or not NormalizeOldAger(player, state, components.oldager) then
        return false
    end
    local inventory = components.inventory
    if inventory ~= nil and not SetField(state, inventory, "noheavylifting", false) then
        return false
    end
    local positionalwarp = components.positionalwarp
    if positionalwarp ~= nil
        and (not SetField(state, positionalwarp, "showmarker", false)
            or not AddWrapper(state, positionalwarp, "SetWarpBackDist", function()
                return nil
            end)
            or not AddWrapper(state, positionalwarp, "EnableMarker", function()
                return nil
            end)
            or not AddWrapper(state, positionalwarp, "GetHistoryPosition", function()
                return nil
            end)) then
        return false
    end
    return true
end

local function NormalizeRoleComponents(player, state, components)
    if not NormalizeFreezable(state, components.freezable)
        or not NormalizeFuelMaster(state, components.fuelmaster)
        or not NormalizeMightiness(state, components.mightiness)
        or not NormalizeBloomness(player, state, components.bloomness)
        or not NormalizeFoodMemory(state, components.foodmemory)
        or not NormalizeSoulEater(state, components.souleater)
        or not NormalizeGhostlyBond(state, components.ghostlybond)
        or not NormalizeStoryteller(state, components.storyteller)
        or not NormalizeSingingInspiration(player, state, components.singinginspiration)
        or not NormalizeBattleborn(state, components.battleborn) then
        return false
    end
    if components.oldager ~= nil and components.positionalwarp ~= nil then
        if not NormalizeWandaState(player, state, components) then
            return false
        end
    elseif components.oldager ~= nil and not NormalizeOldAger(
        player,
        state,
        components.oldager
    ) then
        return false
    end
    -- 部分官方组件 setter 会重新生成角色标签。统一化完成后再次移除这些
    -- 标签；只有进入场地前捕获到的标签才会在退出时恢复。
    if not RemoveCurrentRoleTags(player) then
        return false
    end
    return true
end

local function NormalizeComponents(player, state, profile)
    local components = Util.GetComponents(player)
    if components == nil then
        return false
    end
    local fair_mode = profile.fair_mode or {}
    local prefab = state.prefab
    local health = components.health
    if health ~= nil then
        if not SetField(state, health, "fire_damage_scale", 1)
            or not SetField(state, health, "redirect", nil)
            or not SetField(state, health, "deltamodifierfn", nil)
            or not SetField(state, health, "absorb", 0)
            or not SetField(state, health, "playerabsorb", 0)
            or not SetField(state, health, "canmurder", true)
            or not SetField(state, health, "canheal", true)
            or not SetField(state, health, "disable_penalty", not (type(TUNING) == "table" and TUNING.HEALTH_PENALTY_ENABLED)) then
            return false
        end
    end

    local sanity = components.sanity
    if sanity ~= nil then
        if not NormalizeSanitySources(player, sanity, prefab, state)
            or not SetField(state, sanity, "custom_rate_fn", nil)
            or not SetField(state, sanity, "rate_modifier", 1)
            or not SetField(state, sanity, "night_drain_mult", 1)
            or not SetField(state, sanity, "neg_aura_mult", 1)
            or not SetField(state, sanity, "neg_aura_absorb", 0)
            or not SetField(state, sanity, "dapperness", 0)
            or not SetField(state, sanity, "dapperness_mult", 1)
            or not SetField(state, sanity, "get_equippable_dappernessfn", nil)
            or not SetField(state, sanity, "only_magic_dapperness", false)
            or not SetField(state, sanity, "no_moisture_penalty", false)
            or not SetField(state, sanity, "sanity_penalties", {})
            or not SetField(state, sanity, "penalty", 0)
            or not SetField(state, sanity, "inducedinsanity", nil)
            or not SetField(state, sanity, "inducedlunacy", nil)
            or not SetField(state, sanity, "inducedinsanity_sources", nil)
            or not SetField(state, sanity, "inducedlunacy_sources", nil)
            or not SetField(state, sanity, "sane", true) then
            return false
        end
        if SANITY_MODE_INSANITY ~= nil
            and not SetField(state, sanity, "mode", SANITY_MODE_INSANITY) then
            return false
        end
        if not AddWrapper(state, sanity, "EnableLunacy", function()
            return nil
        end)
            or not AddWrapper(state, sanity, "SetInducedInsanity", function()
                return nil
            end)
            or not AddWrapper(state, sanity, "SetInducedLunacy", function()
                return nil
            end) then
            return false
        end
    end

    local temperature = components.temperature
    if temperature ~= nil then
        local freeze_rate = type(TUNING) == "table"
            and TUNING.WILSON_HEALTH / TUNING.FREEZING_KILL_TIME
            or nil
        if not SetField(state, temperature, "inherentinsulation", 0)
            or not SetField(state, temperature, "inherentsummerinsulation", 0)
            or (freeze_rate ~= nil and not SetField(state, temperature, "hurtrate", freeze_rate))
            or not SetField(state, temperature, "overheathurtrate", nil) then
            return false
        end
    end

    local combat = components.combat
    if combat ~= nil then
        if not SetField(state, combat, "damagemultiplier", 1)
            or not SetField(state, combat, "customdamagemultfn", nil)
            or not SetField(state, combat, "customspdamagemultfn", nil)
            or not SetField(state, combat, "onhitotherfn", nil) then
            return false
        end
    end

    if not NormalizeLocomotor(state, components.locomotor, fair_mode)
        or not NormalizeBuilder(state, components.builder)
        or not NormalizeEater(state, components.eater) then
        return false
    end

    local workmultiplier = components.workmultiplier
    if workmultiplier ~= nil then
        if not AddWrapper(state, workmultiplier, "GetMultiplier", function()
            return 1
        end)
            or not AddWrapper(state, workmultiplier, "ResolveSpecialWorkAmount", function(_, _, _, _, numworks)
                return numworks
            end) then
            return false
        end
    end
    local efficientuser = components.efficientuser
    if efficientuser ~= nil and not AddWrapper(state, efficientuser, "GetMultiplier", function()
        return 1
    end) then
        return false
    end
    local foodaffinity = components.foodaffinity
    if foodaffinity ~= nil then
        if not AddWrapper(state, foodaffinity, "HasAffinity", function()
            return false
        end)
            or not AddWrapper(state, foodaffinity, "HasPrefabAffinity", function()
                return false
            end)
            or not AddWrapper(state, foodaffinity, "GetAffinity", function()
                return nil
            end) then
            return false
        end
    end

    local sleepingbaguser = components.sleepingbaguser
    if sleepingbaguser ~= nil then
        if not SetField(state, sleepingbaguser, "hunger_bonus_mult", 1)
            or not SetField(state, sleepingbaguser, "health_bonus_mult", 1)
            or not SetField(state, sleepingbaguser, "sanity_bonus_mult", 1)
            or not SetField(state, sleepingbaguser, "cansleepfn", nil) then
            return false
        end
    end
    local preserver = components.preserver
    if preserver ~= nil then
        if not SetField(state, preserver, "perish_rate_multiplier", 1)
            or not SetField(state, preserver, "temperature_rate_multiplier", 1) then
            return false
        end
    end
    local staffsanity = components.staffsanity
    if staffsanity ~= nil and not SetField(state, staffsanity, "multiplier", 1) then
        return false
    end
    local grue = components.grue
    if grue ~= nil and not SetField(state, grue, "resistance", 0) then
        return false
    end
    local lightning = components.playerlightningtarget
    if lightning ~= nil then
        local chance = type(TUNING) == "table" and TUNING.PLAYER_LIGHTNING_TARGET_CHANCE or 0
        if not SetField(state, lightning, "hitchance", chance)
            or not SetField(state, lightning, "onstrikefn", nil) then
            return false
        end
    end
    local aura_adjuster = components.sanityauraadjuster
    if aura_adjuster ~= nil then
        local was_running = aura_adjuster.sanityAuraAdjuster_task ~= nil
        state.sanity_aura_adjuster_was_running = was_running
        if not SetField(state, aura_adjuster, "adjustmentfn", nil)
            or not Call(aura_adjuster, "StopTask") then
            return false
        end
    end

    if not NormalizeRoleComponents(player, state, components) then
        return false
    end

    return true
end

local function RestoreLocomotor(player, state)
    local locomotor = Util.GetComponents(player).locomotor
    if locomotor == nil then
        return true
    end
    if not SetField(state, locomotor, "faster_on_tiles", {}) then
        return false
    end
    for tile, enabled in pairs(state.faster_on_tiles or {}) do
        if not Call(locomotor, "SetFasterOnGroundTile", tile, enabled) then
            return false
        end
    end
    return true
end

local function RestoreOptionalComponents(player, state)
    local components = Util.GetComponents(player)
    if components == nil then
        return false
    end
    local aura_adjuster = components.sanityauraadjuster
    if aura_adjuster ~= nil and state.sanity_aura_adjuster_was_running
        and not Call(aura_adjuster, "StartTask") then
        return false
    end
    return RestoreSanitySources(player, components.sanity, state)
end

function FairState.Apply(player, context, profile)
    if not IsLivePlayer(player) or not IsEnabled(profile) then
        return true
    end
    context = context or {}
    local existing = context.fair_character_state
    if existing ~= nil and existing.applied == true then
        return true
    end
    local state = existing or
    {
        prefab = Util.GetCharacterPrefab(player),
        fields = {},
        wrappers = {},
        tags = {},
        applied = true,
    }
    context.fair_character_state = state
    if existing == nil and not CaptureAndRemoveRoleTags(player, state) then
        return false, FairState.ERROR_CODES.APPLY_FAILED
    end
    if not NormalizeComponents(player, state, profile) then
        return false, FairState.ERROR_CODES.APPLY_FAILED
    end
    state.applied = true
    context.fair_character_profile_applied = true
    return true
end

function FairState.Remove(player, context)
    context = context or {}
    local state = context.fair_character_state
    if state == nil or state.applied ~= true then
        return true
    end
    if not IsLivePlayer(player) then
        return false, FairState.ERROR_CODES.RESTORE_FAILED
    end
    local restored = RestoreFields(state)
    restored = restored and RestoreLocomotor(player, state)
    restored = restored and RestoreOptionalComponents(player, state)
    restored = restored and RestoreRoleTags(player, state)
    restored = restored and RestoreWrappers(state)
    if not restored then
        return false, FairState.ERROR_CODES.RESTORE_FAILED
    end
    state.applied = false
    context.fair_character_profile_removed = true
    return true
end

return FairState
