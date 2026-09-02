-- WP9：保存格式迁移入口。当前版本只兼容既有 WP0/WP8 的 v1 快照。

local Schema = require("agon/persistence/schema")

local Migrations = {}
Migrations.CURRENT_VERSION = Schema.SCHEMA_VERSION

Migrations.ERROR_CODES =
{
    INVALID_SNAPSHOT = "PERSISTENCE_MIGRATION_INVALID_SNAPSHOT",
    UNKNOWN_SCHEMA = "PERSISTENCE_MIGRATION_UNKNOWN_SCHEMA",
    FAILED = "PERSISTENCE_MIGRATION_FAILED",
}

function Migrations.Migrate(data)
    local copied, copy_code = Schema.CopyPure(data)
    if type(copied) ~= "table" then
        return nil, copy_code or Migrations.ERROR_CODES.INVALID_SNAPSHOT
    end
    if copied.schema_version ~= Migrations.CURRENT_VERSION then
        return nil, Migrations.ERROR_CODES.UNKNOWN_SCHEMA
    end

    -- v1 快照在 WP9 前没有 persistence envelope；这是唯一的 v1 补字段迁移。
    if copied.persistence == nil then
        copied.persistence =
        {
            schema_version = Migrations.CURRENT_VERSION,
            restart_policy = Schema.RESTART_POLICY,
        }
    elseif type(copied.persistence) ~= "table"
        or copied.persistence.schema_version ~= Migrations.CURRENT_VERSION then
        return nil, Migrations.ERROR_CODES.UNKNOWN_SCHEMA
    elseif copied.persistence.restart_policy == nil then
        copied.persistence.restart_policy = Schema.RESTART_POLICY
    elseif copied.persistence.restart_policy ~= Schema.RESTART_POLICY then
        return nil, Migrations.ERROR_CODES.FAILED
    end

    local valid, valid_code = Schema.ValidateSnapshot(copied)
    if not valid then
        return nil, valid_code or Migrations.ERROR_CODES.FAILED
    end
    return copied
end

return Migrations
