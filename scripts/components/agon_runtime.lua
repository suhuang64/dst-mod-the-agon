local Diagnostics = require("agon/debug/diagnostics")

local function GetShardId()
    if TheShard ~= nil and type(TheShard.GetShardId) == "function" then
        local shard_id = TheShard:GetShardId()
        if shard_id ~= nil then
            return tostring(shard_id)
        end
    end
    return "unknown"
end

local function RecordLoadError(self, code)
    local message = "runtime save data rejected"
    Diagnostics.Record(self.diagnostics, code, message)
    Diagnostics.Log(code, { shard_id = self.shard_id, operation = "runtime_load" }, message)
end

local AgonRuntime = Class(function(self, inst)
    self.inst = inst
    -- schema_version 标识快照格式；WP0 只接受当前版本，便于后续演进时拒绝未知数据。
    self.schema_version = Diagnostics.SCHEMA_VERSION
    self.shard_id = GetShardId()
    -- boot_generation 从 1 开始；每次成功加载有效快照时递增，用于区分启动代次。
    self.boot_generation = 1
    self.diagnostics = Diagnostics.NewState()
end)

function AgonRuntime:OnSave()
    return Diagnostics.MakeSnapshot(self)
end

function AgonRuntime:OnLoad(data)
    if data == nil then
        return
    end

    -- 只恢复经过校验的纯数据快照；拒绝的数据不会污染当前运行态，并会记录诊断。
    local valid, code = Diagnostics.ValidateSnapshot(data)
    if not valid then
        RecordLoadError(self, code)
        return
    end

    self.schema_version = data.schema_version
    self.shard_id = data.shard_id
    -- 加载保存数据代表上一启动代，本次恢复后进入下一启动代。
    self.boot_generation = data.boot_generation + 1
    self.diagnostics = Diagnostics.CopyState(data.diagnostics)
end

function AgonRuntime:GetSnapshot()
    return Diagnostics.MakeSnapshot(self)
end

function AgonRuntime:ValidateSnapshot()
    return Diagnostics.ValidateSnapshot(self:GetSnapshot())
end

function AgonRuntime:GetDebugString()
    local error_count = self.diagnostics ~= nil and self.diagnostics.error_count or 0
    return string.format(
        "schema=%d shard=%s boot=%d errors=%d",
        self.schema_version,
        self.shard_id,
        self.boot_generation,
        error_count
    )
end

return AgonRuntime
