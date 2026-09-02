-- WP5：校验并按需创建 Instance 级 Common Services。

local PhaseService = require("agon/services/phase_service")
local ClockService = require("agon/services/clock_service")
local DecisionService = require("agon/services/decision_service")
local EffectService = require("agon/services/effect_service")
local ScoreLedger = require("agon/services/score_ledger")

local CommonServiceRegistry = {}

CommonServiceRegistry.SCHEMA_VERSION = 1

CommonServiceRegistry.ERROR_CODES =
{
    INVALID_DECLARATION = "INVALID_SERVICE_DECLARATION",
    UNKNOWN_SERVICE = "UNKNOWN_SERVICE",
    DUPLICATE_SERVICE = "DUPLICATE_SERVICE",
    INVALID_VERSION = "INVALID_SERVICE_VERSION",
    SERVICE_DEPENDENCY_MISSING = "SERVICE_DEPENDENCY_MISSING",
    SERVICE_FACTORY_FAILED = "SERVICE_FACTORY_FAILED",
    SERVICE_CLOSE_FAILED = "SERVICE_CLOSE_FAILED",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= 1
end

local SERVICE_DEFINITIONS =
{
    phase =
    {
        service_id = "phase",
        version = 1,
        dependencies = {},
        Create = function(instance, services, options)
            return PhaseService.New(instance, services, options)
        end,
    },
    clock =
    {
        service_id = "clock",
        version = 1,
        dependencies = {},
        Create = function(instance, services, options)
            return ClockService.New(instance, services, options)
        end,
    },
    decision =
    {
        service_id = "decision",
        version = 1,
        dependencies = { "phase" },
        Create = function(instance, services, options)
            return DecisionService.New(instance, services, options)
        end,
    },
    effects =
    {
        service_id = "effects",
        version = 1,
        dependencies = { "phase" },
        Create = function(instance, services, options)
            return EffectService.New(instance, services, options)
        end,
    },
    score =
    {
        service_id = "score",
        version = 1,
        dependencies = {},
        Create = function(instance, services, options)
            return ScoreLedger.New(instance, services, options)
        end,
    },
}

CommonServiceRegistry.SERVICE_DEFINITIONS = SERVICE_DEFINITIONS
CommonServiceRegistry.SUPPORTED_SERVICES = {}
for service_id, definition in pairs(SERVICE_DEFINITIONS) do
    CommonServiceRegistry.SUPPORTED_SERVICES[service_id] = definition.version
end

local function NormalizeDeclaration(declaration)
    local service_id
    local version
    if type(declaration) == "string" then
        service_id = declaration
    elseif type(declaration) == "table" then
        service_id = declaration.service_id or declaration.name
        version = declaration.version
    else
        return nil, CommonServiceRegistry.ERROR_CODES.INVALID_DECLARATION
    end
    if not IsNonEmptyString(service_id) then
        return nil, CommonServiceRegistry.ERROR_CODES.INVALID_DECLARATION
    end
    local definition = SERVICE_DEFINITIONS[service_id]
    if definition == nil then
        return nil, CommonServiceRegistry.ERROR_CODES.UNKNOWN_SERVICE
    end
    if version ~= nil
        and (not IsPositiveInteger(version) or version ~= definition.version) then
        return nil, CommonServiceRegistry.ERROR_CODES.INVALID_VERSION
    end
    return
    {
        service_id = service_id,
        version = definition.version,
    }
end

function CommonServiceRegistry.ValidateDeclarations(declarations)
    if declarations == nil then
        declarations = {}
    end
    if type(declarations) ~= "table" then
        return nil, CommonServiceRegistry.ERROR_CODES.INVALID_DECLARATION
    end

    local normalized = {}
    local declared = {}
    for index = 1, #declarations do
        local declaration, declaration_code = NormalizeDeclaration(declarations[index])
        if declaration == nil then
            return nil, declaration_code
        end
        if declared[declaration.service_id] then
            return nil, CommonServiceRegistry.ERROR_CODES.DUPLICATE_SERVICE
        end
        declared[declaration.service_id] = true
        table.insert(normalized, declaration)
    end

    for index = 1, #normalized do
        local definition = SERVICE_DEFINITIONS[normalized[index].service_id]
        for dependency_index = 1, #definition.dependencies do
            local dependency = definition.dependencies[dependency_index]
            if not declared[dependency] then
                return nil, CommonServiceRegistry.ERROR_CODES.SERVICE_DEPENDENCY_MISSING
            end
        end
    end
    return normalized
end

function CommonServiceRegistry.GetDefinition(service_id)
    return SERVICE_DEFINITIONS[service_id]
end

local function CloseCreatedServices(services, order)
    local all_closed = true
    for index = #order, 1, -1 do
        local service = services[order[index]]
        if service ~= nil and type(service.Close) == "function" then
            local ok, closed = pcall(service.Close, service, "service_create_failed")
            if not ok or closed == false then
                all_closed = false
            end
        end
    end
    return all_closed
end

function CommonServiceRegistry.CreateForInstance(self, instance, declarations, options)
    local normalized, declaration_code = CommonServiceRegistry.ValidateDeclarations(declarations)
    if normalized == nil then
        return nil, declaration_code
    end
    local services = {}
    local service_order = {}
    local service_versions = {}
    local pending = {}
    for index = 1, #normalized do
        pending[normalized[index].service_id] = normalized[index]
    end

    while next(pending) ~= nil do
        local progressed = false
        for index = 1, #normalized do
            local declaration = normalized[index]
            if pending[declaration.service_id] ~= nil then
                local definition = SERVICE_DEFINITIONS[declaration.service_id]
                local dependencies_ready = true
                for dependency_index = 1, #definition.dependencies do
                    if services[definition.dependencies[dependency_index]] == nil then
                        dependencies_ready = false
                        break
                    end
                end
                if dependencies_ready then
                    local ok, service, service_code = pcall(
                        definition.Create,
                        instance,
                        services,
                        options or {}
                    )
                    if not ok or service == nil then
                        CloseCreatedServices(services, service_order)
                        return nil, (not ok and CommonServiceRegistry.ERROR_CODES.SERVICE_FACTORY_FAILED)
                            or service_code
                            or CommonServiceRegistry.ERROR_CODES.SERVICE_FACTORY_FAILED
                    end
                    services[declaration.service_id] = service
                    service_versions[declaration.service_id] = declaration.version
                    table.insert(service_order, declaration.service_id)
                    pending[declaration.service_id] = nil
                    progressed = true
                end
            end
        end
        if not progressed then
            CloseCreatedServices(services, service_order)
            return nil, CommonServiceRegistry.ERROR_CODES.SERVICE_DEPENDENCY_MISSING
        end
    end
    return services, service_order, service_versions
end

function CommonServiceRegistry.GetDeclaredNames(self, declarations)
    local normalized, code = CommonServiceRegistry.ValidateDeclarations(declarations)
    if normalized == nil then
        return nil, code
    end
    local names = {}
    for index = 1, #normalized do
        table.insert(names, normalized[index].service_id)
    end
    return names
end

function CommonServiceRegistry.GetDebugString(self)
    local names = {}
    for service_id, definition in pairs(self.definitions) do
        table.insert(names, service_id .. "@" .. tostring(definition.version))
    end
    table.sort(names)
    return "common_service_registry supported=" .. table.concat(names, ",")
end

local function AttachMethods(registry)
    registry.ValidateDeclarations = function(_, declarations)
        return CommonServiceRegistry.ValidateDeclarations(declarations)
    end
    registry.CreateForInstance = CommonServiceRegistry.CreateForInstance
    registry.GetDeclaredNames = CommonServiceRegistry.GetDeclaredNames
    registry.GetDebugString = CommonServiceRegistry.GetDebugString
    return registry
end

function CommonServiceRegistry.New()
    return AttachMethods(
    {
        schema_version = CommonServiceRegistry.SCHEMA_VERSION,
        definitions = SERVICE_DEFINITIONS,
    })
end

return CommonServiceRegistry
