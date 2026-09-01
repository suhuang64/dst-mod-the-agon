-- WP2：GameMode 定义注册表。

local ModeRegistry = {}
ModeRegistry.SCHEMA_VERSION = 1

ModeRegistry.VALID_ZONE_CATEGORIES =
{
    SMALL = true,
    MEDIUM = true,
    LARGE = true,
}

-- WP2 尚未实现 Common Services，因此这里只允许空 services 列表。
-- 后续 WP 实现服务后再通过代码增量开放对应名称。
ModeRegistry.SUPPORTED_SERVICES = {}

ModeRegistry.ERROR_CODES =
{
    INVALID_MODE = "INVALID_MODE",
    DUPLICATE_MODE_ID = "DUPLICATE_MODE_ID",
    INVALID_MODE_VERSION = "INVALID_MODE_VERSION",
    ZONE_CATEGORY_MISMATCH = "ZONE_CATEGORY_MISMATCH",
    UNKNOWN_SERVICE = "UNKNOWN_SERVICE",
    DUPLICATE_SERVICE = "DUPLICATE_SERVICE",
    INVALID_MODE_FACTORY = "INVALID_MODE_FACTORY",
}

local function IsInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function CopyDefinition(definition)
    local copied =
    {
        mode_id = definition.mode_id,
        mode_version = definition.mode_version,
        zone_category = definition.zone_category,
        services = {},
        CreateRuntime = definition.CreateRuntime,
    }
    for index = 1, #definition.services do
        table.insert(copied.services, definition.services[index])
    end
    return copied
end

function ModeRegistry.ValidateDefinition(definition)
    if type(definition) ~= "table"
        or not IsNonEmptyString(definition.mode_id) then
        return false, ModeRegistry.ERROR_CODES.INVALID_MODE
    end
    if not IsInteger(definition.mode_version)
        or definition.mode_version < 1 then
        return false, ModeRegistry.ERROR_CODES.INVALID_MODE_VERSION
    end
    if not ModeRegistry.VALID_ZONE_CATEGORIES[definition.zone_category] then
        return false, ModeRegistry.ERROR_CODES.ZONE_CATEGORY_MISMATCH
    end
    if type(definition.CreateRuntime) ~= "function" then
        return false, ModeRegistry.ERROR_CODES.INVALID_MODE_FACTORY
    end

    local services = definition.services
    if services == nil then
        services = {}
    end
    if type(services) ~= "table" then
        return false, ModeRegistry.ERROR_CODES.INVALID_MODE
    end

    local seen_services = {}
    for index = 1, #services do
        local service = services[index]
        if not IsNonEmptyString(service) then
            return false, ModeRegistry.ERROR_CODES.UNKNOWN_SERVICE
        end
        if seen_services[service] then
            return false, ModeRegistry.ERROR_CODES.DUPLICATE_SERVICE
        end
        if not ModeRegistry.SUPPORTED_SERVICES[service] then
            return false, ModeRegistry.ERROR_CODES.UNKNOWN_SERVICE
        end
        seen_services[service] = true
    end
    return true
end

function ModeRegistry.New()
    local registry =
    {
        schema_version = ModeRegistry.SCHEMA_VERSION,
        definitions_by_id = {},
        definition_order = {},
    }
    registry.Register = ModeRegistry.Register
    registry.Get = ModeRegistry.Get
    registry.Has = ModeRegistry.Has
    registry.List = ModeRegistry.List
    registry.Count = ModeRegistry.Count
    registry.Validate = ModeRegistry.Validate
    return registry
end

function ModeRegistry.Register(self, definition)
    local valid, code = ModeRegistry.ValidateDefinition(definition)
    if not valid then
        return false, code
    end
    if self.definitions_by_id[definition.mode_id] ~= nil then
        return false, ModeRegistry.ERROR_CODES.DUPLICATE_MODE_ID
    end

    local copied = CopyDefinition(
    {
        mode_id = definition.mode_id,
        mode_version = definition.mode_version,
        zone_category = definition.zone_category,
        services = definition.services or {},
        CreateRuntime = definition.CreateRuntime,
    })
    self.definitions_by_id[copied.mode_id] = copied
    table.insert(self.definition_order, copied.mode_id)
    return true
end

function ModeRegistry.Get(self, mode_id)
    if not IsNonEmptyString(mode_id) then
        return nil
    end
    return self.definitions_by_id[mode_id]
end

function ModeRegistry.Has(self, mode_id)
    return self:Get(mode_id) ~= nil
end

function ModeRegistry.List(self)
    local definitions = {}
    for index = 1, #self.definition_order do
        local definition = self.definitions_by_id[self.definition_order[index]]
        local summary =
        {
            mode_id = definition.mode_id,
            mode_version = definition.mode_version,
            zone_category = definition.zone_category,
            services = {},
        }
        for service_index = 1, #definition.services do
            table.insert(summary.services, definition.services[service_index])
        end
        table.insert(definitions, summary)
    end
    return definitions
end

function ModeRegistry.Count(self)
    return #self.definition_order
end

function ModeRegistry.Validate(self)
    local seen = {}
    for index = 1, #self.definition_order do
        local mode_id = self.definition_order[index]
        local definition = self.definitions_by_id[mode_id]
        if not IsNonEmptyString(mode_id) or definition == nil or seen[mode_id] then
            return false, ModeRegistry.ERROR_CODES.INVALID_MODE
        end
        seen[mode_id] = true
        local valid, code = ModeRegistry.ValidateDefinition(definition)
        if not valid then
            return false, code
        end
    end
    return true
end

return ModeRegistry
