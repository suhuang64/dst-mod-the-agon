-- WP6：记录可用于 Instance 实体的 Profile 定义，不修改全局 Prefab。

local EntityProfileRegistry = {}
EntityProfileRegistry.SCHEMA_VERSION = 1

EntityProfileRegistry.APPLY_MODES =
{
    SPAWN_ONLY = "SPAWN_ONLY",
    BLOCKING_ONLY = "BLOCKING_ONLY",
    LIVE_SAFE = "LIVE_SAFE",
}

EntityProfileRegistry.REPLICATION_MODES =
{
    SERVER_ONLY = "SERVER_ONLY",
    REPLICATED = "REPLICATED",
}

EntityProfileRegistry.ERROR_CODES =
{
    INVALID_PROFILE = "INVALID_ENTITY_PROFILE",
    DUPLICATE_PROFILE = "DUPLICATE_ENTITY_PROFILE",
    INVALID_PROFILE_ID = "INVALID_ENTITY_PROFILE_ID",
    INVALID_PROFILE_VERSION = "INVALID_ENTITY_PROFILE_VERSION",
    INVALID_PREFAB_CONSTRAINT = "INVALID_ENTITY_PROFILE_PREFAB",
    INVALID_APPLY_MODE = "INVALID_ENTITY_PROFILE_APPLY_MODE",
    INVALID_REPLICATION_MODE = "INVALID_ENTITY_PROFILE_REPLICATION_MODE",
    INVALID_ADAPTER = "INVALID_ENTITY_PROFILE_ADAPTER",
    CLIENT_CONTRACT_REQUIRED = "ENTITY_PROFILE_CLIENT_CONTRACT_REQUIRED",
    INVALID_CLIENT_CONTRACT = "INVALID_ENTITY_PROFILE_CLIENT_CONTRACT",
    INVALID_CHILD_POLICY = "INVALID_ENTITY_PROFILE_CHILD_POLICY",
    UNKNOWN_PROFILE = "UNKNOWN_ENTITY_PROFILE",
    VERSION_MISMATCH = "ENTITY_PROFILE_VERSION_MISMATCH",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= 1
end

local function CopyData(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    for key, item in pairs(value) do
        if type(key) ~= "function" and type(key) ~= "userdata"
            and type(item) ~= "function" and type(item) ~= "userdata" then
            copied[CopyData(key)] = CopyData(item)
        end
    end
    return copied
end

local function NormalizePrefabList(profile)
    local values = {}
    local seen = {}

    local function AddPrefab(prefab)
        if not IsNonEmptyString(prefab) then
            return false
        end
        if seen[prefab] then
            return true
        end
        seen[prefab] = true
        table.insert(values, prefab)
        return true
    end

    if profile.prefab ~= nil and not AddPrefab(profile.prefab) then
        return nil
    end
    if profile.prefabs ~= nil then
        if type(profile.prefabs) ~= "table" then
            return nil
        end
        for index = 1, #profile.prefabs do
            if not AddPrefab(profile.prefabs[index]) then
                return nil
            end
        end
        for prefab, enabled in pairs(profile.prefabs) do
            if type(prefab) == "string" and enabled == true
                and not AddPrefab(prefab) then
                return nil
            end
        end
    end

    if #values == 0 then
        return nil
    end
    return values
end

local function ValidateClientContract(contract)
    if type(contract) ~= "table"
        or not IsNonEmptyString(contract.contract_id)
        or not IsPositiveInteger(contract.version)
        or type(contract.fields) ~= "table" then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_CLIENT_CONTRACT
    end

    local seen = {}
    for index = 1, #contract.fields do
        local field = contract.fields[index]
        if not IsNonEmptyString(field) or seen[field] then
            return false, EntityProfileRegistry.ERROR_CODES.INVALID_CLIENT_CONTRACT
        end
        seen[field] = true
    end
    return true
end

local function ValidateChildPolicy(policy)
    if policy == nil then
        return true
    end
    if type(policy) ~= "table" then
        return false
    end
    for key, value in pairs(policy) do
        if type(key) ~= "string" then
            return false
        end
        if type(value) == "string" then
            if value == "" then
                return false
            end
        elseif type(value) == "table" then
            if not IsNonEmptyString(value.profile_id)
                or (value.profile_version ~= nil
                    and not IsPositiveInteger(value.profile_version)) then
                return false
            end
        else
            return false
        end
    end
    return true
end

local function CopyProfile(profile, prefabs)
    local copied =
    {
        profile_id = profile.profile_id,
        version = profile.version,
        prefab = prefabs[1],
        prefabs = CopyData(prefabs),
        apply_mode = profile.apply_mode,
        replication_mode = profile.replication_mode,
        adapter = profile.adapter,
        client_contract = CopyData(profile.client_contract),
        child_profiles = CopyData(profile.child_profiles),
        metadata = CopyData(profile.metadata),
    }
    return copied
end

function EntityProfileRegistry.ValidateProfile(profile)
    if type(profile) ~= "table" then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_PROFILE
    end
    if not IsNonEmptyString(profile.profile_id) then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_PROFILE_ID
    end
    if not IsPositiveInteger(profile.version) then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_PROFILE_VERSION
    end

    local prefabs = NormalizePrefabList(profile)
    if prefabs == nil then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_PREFAB_CONSTRAINT
    end
    if EntityProfileRegistry.APPLY_MODES[profile.apply_mode]
        ~= profile.apply_mode then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_APPLY_MODE
    end
    if EntityProfileRegistry.REPLICATION_MODES[profile.replication_mode]
        ~= profile.replication_mode then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_REPLICATION_MODE
    end
    if type(profile.adapter) ~= "table"
        or type(profile.adapter.Apply) ~= "function" then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_ADAPTER
    end
    if profile.replication_mode == EntityProfileRegistry.REPLICATION_MODES.REPLICATED then
        if profile.client_contract == nil then
            return false, EntityProfileRegistry.ERROR_CODES.CLIENT_CONTRACT_REQUIRED
        end
        local contract_valid, contract_code = ValidateClientContract(profile.client_contract)
        if not contract_valid then
            return false, contract_code
        end
    elseif profile.client_contract ~= nil then
        local contract_valid, contract_code = ValidateClientContract(profile.client_contract)
        if not contract_valid then
            return false, contract_code
        end
    end
    if not ValidateChildPolicy(profile.child_profiles) then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_CHILD_POLICY
    end
    return true
end

function EntityProfileRegistry.Register(self, profile)
    local valid, code = EntityProfileRegistry.ValidateProfile(profile)
    if not valid then
        return false, code
    end
    if self.profiles_by_id[profile.profile_id] ~= nil then
        return false, EntityProfileRegistry.ERROR_CODES.DUPLICATE_PROFILE
    end

    local prefabs = NormalizePrefabList(profile)
    local copied = CopyProfile(profile, prefabs)
    self.profiles_by_id[copied.profile_id] = copied
    table.insert(self.profile_order, copied.profile_id)
    return true
end

function EntityProfileRegistry.RegisterMany(self, profiles)
    if type(profiles) ~= "table" then
        return false, EntityProfileRegistry.ERROR_CODES.INVALID_PROFILE
    end
    local registered = {}
    for index = 1, #profiles do
        local ok, code = self:Register(profiles[index])
        if not ok then
            for rollback_index = #registered, 1, -1 do
                self:Unregister(registered[rollback_index])
            end
            return false, code
        end
        table.insert(registered, profiles[index].profile_id)
    end
    return true
end

function EntityProfileRegistry.Unregister(self, profile_id)
    if not IsNonEmptyString(profile_id)
        or self.profiles_by_id[profile_id] == nil then
        return false, EntityProfileRegistry.ERROR_CODES.UNKNOWN_PROFILE
    end
    self.profiles_by_id[profile_id] = nil
    for index = 1, #self.profile_order do
        if self.profile_order[index] == profile_id then
            table.remove(self.profile_order, index)
            break
        end
    end
    return true
end

function EntityProfileRegistry.Get(self, profile_id, version)
    if not IsNonEmptyString(profile_id) then
        return nil, EntityProfileRegistry.ERROR_CODES.UNKNOWN_PROFILE
    end
    local profile = self.profiles_by_id[profile_id]
    if profile == nil then
        return nil, EntityProfileRegistry.ERROR_CODES.UNKNOWN_PROFILE
    end
    if version ~= nil and version ~= profile.version then
        return nil, EntityProfileRegistry.ERROR_CODES.VERSION_MISMATCH
    end
    return profile
end

function EntityProfileRegistry.Has(self, profile_id, version)
    local profile = self:Get(profile_id, version)
    return profile ~= nil
end

function EntityProfileRegistry.MatchesPrefab(self, profile, prefab)
    if type(profile) ~= "table" or not IsNonEmptyString(prefab) then
        return false
    end
    for index = 1, #(profile.prefabs or {}) do
        if profile.prefabs[index] == prefab then
            return true
        end
    end
    return false
end

function EntityProfileRegistry.List(self)
    local profiles = {}
    for index = 1, #self.profile_order do
        local profile = self.profiles_by_id[self.profile_order[index]]
        if profile ~= nil then
            table.insert(
                profiles,
                {
                    profile_id = profile.profile_id,
                    version = profile.version,
                    prefab = profile.prefab,
                    prefabs = CopyData(profile.prefabs),
                    apply_mode = profile.apply_mode,
                    replication_mode = profile.replication_mode,
                    client_contract = CopyData(profile.client_contract),
                    child_profiles = CopyData(profile.child_profiles),
                    metadata = CopyData(profile.metadata),
                }
            )
        end
    end
    return profiles
end

function EntityProfileRegistry.Count(self)
    return #self.profile_order
end

function EntityProfileRegistry.Validate(self)
    local seen = {}
    for index = 1, #self.profile_order do
        local profile_id = self.profile_order[index]
        local profile = self.profiles_by_id[profile_id]
        if not IsNonEmptyString(profile_id) or profile == nil or seen[profile_id] then
            return false, EntityProfileRegistry.ERROR_CODES.INVALID_PROFILE
        end
        seen[profile_id] = true
        local valid, code = EntityProfileRegistry.ValidateProfile(profile)
        if not valid then
            return false, code
        end
    end
    return true
end

function EntityProfileRegistry.GetSnapshot(self)
    return
    {
        schema_version = EntityProfileRegistry.SCHEMA_VERSION,
        count = self:Count(),
        profiles = self:List(),
    }
end

function EntityProfileRegistry.GetDebugString(self)
    local names = {}
    for index = 1, #self.profile_order do
        local profile = self.profiles_by_id[self.profile_order[index]]
        if profile ~= nil then
            table.insert(names, profile.profile_id .. "@" .. tostring(profile.version))
        end
    end
    return "entity_profile_registry profiles=" .. table.concat(names, ",")
end

local function AttachMethods(registry)
    registry.Register = EntityProfileRegistry.Register
    registry.RegisterMany = EntityProfileRegistry.RegisterMany
    registry.Unregister = EntityProfileRegistry.Unregister
    registry.Get = EntityProfileRegistry.Get
    registry.Has = EntityProfileRegistry.Has
    registry.MatchesPrefab = EntityProfileRegistry.MatchesPrefab
    registry.List = EntityProfileRegistry.List
    registry.Count = EntityProfileRegistry.Count
    registry.Validate = EntityProfileRegistry.Validate
    registry.GetSnapshot = EntityProfileRegistry.GetSnapshot
    registry.GetDebugString = EntityProfileRegistry.GetDebugString
    return registry
end

function EntityProfileRegistry.New()
    return AttachMethods(
    {
        schema_version = EntityProfileRegistry.SCHEMA_VERSION,
        profiles_by_id = {},
        profile_order = {},
    })
end

return EntityProfileRegistry
