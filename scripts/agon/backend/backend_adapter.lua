-- WP9：只定义服务端结果/结算提交边界；具体 Flask/HTTP transport 不在 Base 内实现。

local Schema = require("agon/persistence/schema")

local BackendAdapter = {}
BackendAdapter.SCHEMA_VERSION = 1
BackendAdapter.SERVICE_ID = "backend_adapter"
BackendAdapter.SERVICE_VERSION = 1

BackendAdapter.ERROR_CODES =
{
    NOT_SERVER_AUTHORITY = "BACKEND_NOT_SERVER_AUTHORITY",
    INVALID_RESULT = "BACKEND_INVALID_RESULT",
    INVALID_SETTLEMENT = "BACKEND_INVALID_SETTLEMENT",
    NOT_CONFIGURED = "BACKEND_NOT_CONFIGURED",
    TRANSPORT_FAILED = "BACKEND_TRANSPORT_FAILED",
    RESULT_IMMUTABLE_MISMATCH = "BACKEND_RESULT_IMMUTABLE_MISMATCH",
    SETTLEMENT_IMMUTABLE_MISMATCH = "BACKEND_SETTLEMENT_IMMUTABLE_MISMATCH",
    NOT_FOUND = "BACKEND_PENDING_NOT_FOUND",
    INVALID_SNAPSHOT = "BACKEND_INVALID_SNAPSHOT",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function GetNow(self)
    if type(self.now_fn) == "function" then
        return self.now_fn()
    end
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

local function CountPending(self)
    local count = 0
    for index = 1, #self.record_order do
        local record = self.records_by_key[self.record_order[index]]
        if record ~= nil and record.state == "PENDING" then
            count = count + 1
        end
    end
    return count
end

local function NormalizeData(data, id_field, invalid_code)
    if type(data) ~= "table" then
        return nil, invalid_code
    end
    local identifier = data[id_field]
    if not IsNonEmptyString(identifier) and id_field == "game_result_id" then
        identifier = data.result_id
    end
    if not IsNonEmptyString(identifier) then
        return nil, invalid_code
    end
    local copied, copy_code = Schema.CopyPure(data)
    if type(copied) ~= "table" then
        return nil, copy_code or invalid_code
    end
    copied[id_field] = identifier
    return copied
end

local function TransportCall(self, kind, data)
    if self.transport == nil then
        return false, BackendAdapter.ERROR_CODES.NOT_CONFIGURED
    end
    local method_name = kind == "GAME_RESULT"
        and "SubmitGameResult"
        or "SubmitSettlement"
    local callback = self.transport[method_name]
    if type(callback) ~= "function" then
        return false, BackendAdapter.ERROR_CODES.NOT_CONFIGURED
    end
    local ok, accepted, code = pcall(callback, self.transport, data)
    if not ok then
        return false, BackendAdapter.ERROR_CODES.TRANSPORT_FAILED
    end
    if accepted == true then
        return true
    end
    return false, code or BackendAdapter.ERROR_CODES.TRANSPORT_FAILED
end

local function SubmitRecord(self, kind, data, identifier, mismatch_code)
    if self.server_authority ~= true then
        return false, BackendAdapter.ERROR_CODES.NOT_SERVER_AUTHORITY
    end

    local key = kind .. ":" .. identifier
    local record = self.records_by_key[key]
    if record ~= nil then
        if not Schema.DeepEqual(record.data, data) then
            return false, mismatch_code
        end
        if record.state == "SUBMITTED" then
            return true, "ALREADY_SUBMITTED"
        end
    else
        record =
        {
            kind = kind,
            identifier = identifier,
            data = data,
            state = "PENDING",
            attempts = 0,
            created_at = GetNow(self),
        }
        self.records_by_key[key] = record
        table.insert(self.record_order, key)
    end

    record.attempts = (record.attempts or 0) + 1
    record.last_attempt_at = GetNow(self)
    local submitted, submit_code = TransportCall(self, kind, data)
    if submitted then
        record.state = "SUBMITTED"
        record.submitted_at = GetNow(self)
        record.last_error_code = nil
        return true
    end
    record.state = "PENDING"
    record.last_error_code = submit_code
    return false, submit_code
end

function BackendAdapter.SubmitGameResult(self, result)
    local data, code = NormalizeData(
        result,
        "game_result_id",
        BackendAdapter.ERROR_CODES.INVALID_RESULT
    )
    if data == nil then
        return false, code
    end
    return SubmitRecord(
        self,
        "GAME_RESULT",
        data,
        data.game_result_id,
        BackendAdapter.ERROR_CODES.RESULT_IMMUTABLE_MISMATCH
    )
end

function BackendAdapter.SubmitSettlement(self, settlement)
    local data, code = NormalizeData(
        settlement,
        "settlement_id",
        BackendAdapter.ERROR_CODES.INVALID_SETTLEMENT
    )
    if data == nil then
        return false, code
    end
    return SubmitRecord(
        self,
        "SETTLEMENT",
        data,
        data.settlement_id,
        BackendAdapter.ERROR_CODES.SETTLEMENT_IMMUTABLE_MISMATCH
    )
end

local function FindRecord(self, identifier)
    if not IsNonEmptyString(identifier) then
        return nil
    end
    local direct = self.records_by_key[identifier]
    if direct ~= nil then
        return direct
    end
    for index = 1, #self.record_order do
        local record = self.records_by_key[self.record_order[index]]
        if record ~= nil and record.identifier == identifier then
            return record
        end
    end
    return nil
end

function BackendAdapter.RetryPending(self, identifier)
    if self.server_authority ~= true then
        return false, BackendAdapter.ERROR_CODES.NOT_SERVER_AUTHORITY
    end
    local record = FindRecord(self, identifier)
    if record == nil then
        return false, BackendAdapter.ERROR_CODES.NOT_FOUND
    end
    if record.state == "SUBMITTED" then
        return true, "ALREADY_SUBMITTED"
    end
    record.attempts = (record.attempts or 0) + 1
    record.last_attempt_at = GetNow(self)
    local submitted, submit_code = TransportCall(self, record.kind, record.data)
    if submitted then
        record.state = "SUBMITTED"
        record.submitted_at = GetNow(self)
        record.last_error_code = nil
        return true
    end
    record.state = "PENDING"
    record.last_error_code = submit_code
    return false, submit_code
end

function BackendAdapter.GetPendingCount(self)
    return CountPending(self)
end

function BackendAdapter.GetSnapshot(self)
    local records = {}
    for index = 1, #self.record_order do
        local record = self.records_by_key[self.record_order[index]]
        if record ~= nil then
            local copied = Schema.CopyPure(record)
            if copied ~= nil then
                table.insert(records, copied)
            end
        end
    end
    return
    {
        schema_version = self.schema_version,
        service_id = self.service_id,
        service_version = self.service_version,
        records = records,
    }
end

function BackendAdapter.OnLoad(self, data)
    if data == nil then
        return true
    end
    local copied, copy_code = Schema.CopyPure(data)
    if type(copied) ~= "table"
        or copied.schema_version ~= self.schema_version
        or (copied.records ~= nil and type(copied.records) ~= "table") then
        return false, copy_code or BackendAdapter.ERROR_CODES.INVALID_SNAPSHOT
    end
    self.records_by_key = {}
    self.record_order = {}
    for index = 1, #(copied.records or {}) do
        local source = copied.records[index]
        if type(source) ~= "table"
            or (source.kind ~= "GAME_RESULT" and source.kind ~= "SETTLEMENT")
            or not IsNonEmptyString(source.identifier)
            or type(source.data) ~= "table"
            or (source.state ~= "PENDING" and source.state ~= "SUBMITTED") then
            return false, BackendAdapter.ERROR_CODES.INVALID_SNAPSHOT
        end
        local key = source.kind .. ":" .. source.identifier
        if self.records_by_key[key] ~= nil then
            return false, BackendAdapter.ERROR_CODES.INVALID_SNAPSHOT
        end
        self.records_by_key[key] = source
        table.insert(self.record_order, key)
    end
    return true
end

function BackendAdapter.Validate(self)
    for index = 1, #self.record_order do
        local key = self.record_order[index]
        local record = self.records_by_key[key]
        if record == nil
            or key ~= record.kind .. ":" .. tostring(record.identifier)
            or (record.kind ~= "GAME_RESULT" and record.kind ~= "SETTLEMENT")
            or not IsNonEmptyString(record.identifier)
            or type(record.data) ~= "table"
            or (record.state ~= "PENDING" and record.state ~= "SUBMITTED") then
            return false, BackendAdapter.ERROR_CODES.INVALID_SNAPSHOT
        end
        local pure, pure_code = Schema.IsPure(record.data)
        if not pure then
            return false, pure_code or BackendAdapter.ERROR_CODES.INVALID_SNAPSHOT
        end
    end
    return true
end

function BackendAdapter.GetDebugString(self)
    local submitted = #self.record_order - CountPending(self)
    return string.format(
        "backend_adapter records=%d pending=%d submitted=%d transport=%s",
        #self.record_order,
        CountPending(self),
        submitted,
        self.transport ~= nil and "configured" or "not_configured"
    )
end

local function AttachMethods(adapter)
    adapter.SubmitGameResult = BackendAdapter.SubmitGameResult
    adapter.SubmitSettlement = BackendAdapter.SubmitSettlement
    adapter.RetryPending = BackendAdapter.RetryPending
    adapter.GetPendingCount = BackendAdapter.GetPendingCount
    adapter.GetSnapshot = BackendAdapter.GetSnapshot
    adapter.OnLoad = BackendAdapter.OnLoad
    adapter.Validate = BackendAdapter.Validate
    adapter.GetDebugString = BackendAdapter.GetDebugString
    return adapter
end

function BackendAdapter.New(options)
    options = type(options) == "table" and options or {}
    return AttachMethods(
    {
        schema_version = BackendAdapter.SCHEMA_VERSION,
        service_id = BackendAdapter.SERVICE_ID,
        service_version = BackendAdapter.SERVICE_VERSION,
        server_authority = options.server_authority ~= false,
        transport = options.transport,
        now_fn = options.now_fn,
        records_by_key = {},
        record_order = {},
    })
end

return BackendAdapter
