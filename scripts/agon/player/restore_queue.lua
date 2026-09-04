-- WP9：跨 Instance/重启的玩家恢复队列。未验证恢复前永不丢弃原始快照。

local Schema = require("agon/persistence/schema")
local StateAdapterRegistry = require("agon/player/state_adapter_registry")
local Util = require("agon/player/adapters/util")

local RestoreQueue = {}
RestoreQueue.SCHEMA_VERSION = 1
RestoreQueue.SERVICE_ID = "player_restore_queue"
RestoreQueue.SERVICE_VERSION = 1

RestoreQueue.STATES =
{
    RESTORE_PENDING = "RESTORE_PENDING",
    RESTORING = "RESTORING",
    RESTORED = "RESTORED",
    RESTORE_BLOCKED = "RESTORE_BLOCKED",
}

RestoreQueue.ERROR_CODES =
{
    INVALID_ENTRY = "RESTORE_QUEUE_INVALID_ENTRY",
    DUPLICATE_USER = "RESTORE_QUEUE_DUPLICATE_USER",
    TRANSACTION_CONFLICT = "RESTORE_QUEUE_TRANSACTION_CONFLICT",
    NOT_FOUND = "RESTORE_QUEUE_NOT_FOUND",
    PLAYER_INVALID = "RESTORE_QUEUE_PLAYER_INVALID",
    PLAYER_USERID_MISMATCH = "RESTORE_QUEUE_PLAYER_USERID_MISMATCH",
    NOT_SERIALIZABLE = "RESTORE_QUEUE_NON_SERIALIZABLE",
    RESTORE_FAILED = "RESTORE_QUEUE_RESTORE_FAILED",
    RESTORE_VALIDATION_FAILED = "RESTORE_QUEUE_RESTORE_VALIDATION_FAILED",
    RESTORE_BLOCKED = "RESTORE_QUEUE_RESTORE_BLOCKED",
    INVALID_SNAPSHOT = "RESTORE_QUEUE_INVALID_SNAPSHOT",
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

local function IsTerminal(state)
    return state == RestoreQueue.STATES.RESTORED
end

local function IsValidPlayer(player)
    return Util.IsValidPlayer(player)
end

local function CopyPureOrNil(value)
    local copied, code = Schema.CopyPure(value)
    if value == nil then
        return nil
    end
    if copied == nil and code ~= nil then
        return nil, code
    end
    return copied
end

local function GetAdapterIds(transaction)
    if type(transaction.adapter_ids) == "table" then
        return CopyPureOrNil(transaction.adapter_ids)
    end
    if type(transaction.context) == "table"
        and type(transaction.context.adapter_ids) == "table" then
        return CopyPureOrNil(transaction.context.adapter_ids)
    end
    return nil
end

local function GetParticipantSnapshot(participant)
    if participant == nil then
        return nil
    end
    if type(participant.GetSnapshot) == "function" then
        local ok, snapshot = pcall(participant.GetSnapshot, participant)
        if ok then
            return CopyPureOrNil(snapshot)
        end
    end
    return CopyPureOrNil(participant)
end

local function IsValidAdapterIds(adapter_ids)
    if adapter_ids == nil then
        return true
    end
    if type(adapter_ids) ~= "table" then
        return false
    end
    for index = 1, #adapter_ids do
        if not IsNonEmptyString(adapter_ids[index]) then
            return false
        end
    end
    return true
end

local function ValidateEntrySnapshot(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.adapters) ~= "table" then
        return false, RestoreQueue.ERROR_CODES.INVALID_SNAPSHOT
    end
    local pure, pure_code = Schema.IsPure(snapshot)
    if not pure then
        return false, pure_code or RestoreQueue.ERROR_CODES.INVALID_SNAPSHOT
    end
    return true
end

local function MakeContext(entry)
    local context =
    {
        profile = entry.profile,
        adapter_ids = entry.adapter_ids,
        sandbox =
        {
            profile = entry.profile,
            transaction_id = entry.transaction_id,
        },
    }
    return context
end

local function SetPlayerGuard(player, state, transaction_id)
    if type(player) ~= "table" then
        return
    end
    if state == nil or state == RestoreQueue.STATES.RESTORED then
        player.agon_restore_state = nil
        player.agon_restore_transaction_id = nil
    else
        player.agon_restore_state = state
        player.agon_restore_transaction_id = transaction_id
    end
end

local function MakeEntry(transaction, participant)
    if type(transaction) ~= "table"
        or not IsNonEmptyString(transaction.transaction_id)
        or not IsNonEmptyString(transaction.instance_id)
        or not IsNonEmptyString(transaction.userid)
        or type(transaction.snapshot) ~= "table"
        or type(transaction.profile) ~= "table" then
        return nil, RestoreQueue.ERROR_CODES.INVALID_ENTRY
    end

    local profile, profile_code = CopyPureOrNil(transaction.profile)
    local snapshot, snapshot_code = CopyPureOrNil(transaction.snapshot)
    if profile == nil or snapshot == nil then
        return nil, profile_code or snapshot_code or RestoreQueue.ERROR_CODES.NOT_SERIALIZABLE
    end
    local snapshot_valid, valid_snapshot_code = ValidateEntrySnapshot(snapshot)
    if not snapshot_valid then
        return nil, valid_snapshot_code
    end

    local adapter_ids, adapter_code = GetAdapterIds(transaction)
    if adapter_code ~= nil then
        return nil, adapter_code
    end

    local participant_snapshot = GetParticipantSnapshot(participant)
    if participant ~= nil and participant_snapshot == nil then
        return nil, RestoreQueue.ERROR_CODES.NOT_SERIALIZABLE
    end

    local source_state = transaction.state
    local entry_state = source_state == "RESTORE_BLOCKED"
        and RestoreQueue.STATES.RESTORE_BLOCKED
        or RestoreQueue.STATES.RESTORE_PENDING
    return
    {
        schema_version = RestoreQueue.SCHEMA_VERSION,
        transaction_id = transaction.transaction_id,
        instance_id = transaction.instance_id,
        userid = transaction.userid,
        source_state = source_state,
        state = entry_state,
        profile = profile,
        snapshot = snapshot,
        snapshot_serializable = transaction.snapshot_serializable ~= false,
        character_prefab = transaction.character_prefab,
        adapter_ids = adapter_ids,
        participant = participant_snapshot,
        created_at = transaction.created_at,
        captured_at = transaction.captured_at,
        restore_attempts = transaction.restore_attempts or 0,
        last_error_code = transaction.last_error_code,
        last_error_message = transaction.last_error_message,
    }
end

local function RemoveEntryIndex(self, entry)
    if self.entries_by_transaction_id[entry.transaction_id] == entry then
        self.entries_by_transaction_id[entry.transaction_id] = nil
    end
    if self.entries_by_userid[entry.userid] == entry then
        self.entries_by_userid[entry.userid] = nil
    end
    for index = 1, #self.entry_order do
        if self.entry_order[index] == entry.transaction_id then
            table.remove(self.entry_order, index)
            break
        end
    end
end

function RestoreQueue.Enqueue(self, transaction, participant)
    if type(transaction) == "table" and transaction.transaction ~= nil then
        participant = transaction.participant or participant
        transaction = transaction.transaction
    end
    if type(transaction) ~= "table"
        or not IsNonEmptyString(transaction.transaction_id)
        or not IsNonEmptyString(transaction.userid) then
        return false, RestoreQueue.ERROR_CODES.INVALID_ENTRY
    end
    if transaction.state == "COMMITTED" or transaction.state == "CAPTURE_FAILED" then
        return true, "NO_RESTORE_REQUIRED"
    end

    local existing = self.entries_by_transaction_id[transaction.transaction_id]
    if existing ~= nil then
        if existing.userid ~= transaction.userid
            or existing.instance_id ~= transaction.instance_id then
            return false, RestoreQueue.ERROR_CODES.TRANSACTION_CONFLICT
        end
        return true, "ALREADY_ENQUEUED"
    end
    local user_existing = self.entries_by_userid[transaction.userid]
    if user_existing ~= nil then
        if user_existing.transaction_id == transaction.transaction_id then
            return true, "ALREADY_ENQUEUED"
        end
        if user_existing.state == RestoreQueue.STATES.RESTORED then
            -- 已验证完成的历史事务不应阻塞同一玩家后续新 Instance 的
            -- transaction；保留 pending/blocked 记录的重复用户保护。
            RemoveEntryIndex(self, user_existing)
        else
            return false, RestoreQueue.ERROR_CODES.DUPLICATE_USER
        end
    end

    local entry, entry_code = MakeEntry(transaction, participant)
    if entry == nil then
        return false, entry_code
    end
    self.entries_by_transaction_id[entry.transaction_id] = entry
    self.entries_by_userid[entry.userid] = entry
    table.insert(self.entry_order, entry.transaction_id)
    return true, entry.state
end

function RestoreQueue.Get(self, subject)
    if type(subject) == "string" then
        return self.entries_by_transaction_id[subject]
            or self.entries_by_userid[subject]
    end
    if type(subject) == "table" then
        return self.entries_by_transaction_id[subject.transaction_id]
            or self.entries_by_userid[subject.userid]
    end
    return nil
end

function RestoreQueue.List(self)
    local entries = {}
    for index = 1, #self.entry_order do
        local entry = self.entries_by_transaction_id[self.entry_order[index]]
        if entry ~= nil then
            local copied = Schema.CopyPure(entry)
            if copied ~= nil then
                table.insert(entries, copied)
            end
        end
    end
    return entries
end

function RestoreQueue.MarkDisconnected(self, userid, reason)
    local entry = self:Get(userid)
    if entry == nil then
        return false, RestoreQueue.ERROR_CODES.NOT_FOUND
    end
    if not IsTerminal(entry.state) then
        entry.state = RestoreQueue.STATES.RESTORE_PENDING
        entry.last_error_code = "PLAYER_DISCONNECTED"
        entry.last_error_message = reason ~= nil and tostring(reason) or nil
    end
    return true
end

local function RestoreEntry(self, entry, player, reason)
    if entry.state == RestoreQueue.STATES.RESTORED then
        SetPlayerGuard(player, entry.state, entry.transaction_id)
        return true, "ALREADY_RESTORED"
    end
    if entry.state == RestoreQueue.STATES.RESTORE_BLOCKED then
        SetPlayerGuard(player, entry.state, entry.transaction_id)
        return false, entry.last_error_code or RestoreQueue.ERROR_CODES.RESTORE_BLOCKED
    end
    if not IsValidPlayer(player) then
        entry.state = RestoreQueue.STATES.RESTORE_PENDING
        entry.last_error_code = RestoreQueue.ERROR_CODES.PLAYER_INVALID
        entry.last_error_message = reason ~= nil and tostring(reason) or nil
        return false, entry.last_error_code
    end
    if player.userid ~= entry.userid then
        return false, RestoreQueue.ERROR_CODES.PLAYER_USERID_MISMATCH
    end
    if entry.snapshot_serializable ~= true then
        entry.state = RestoreQueue.STATES.RESTORE_BLOCKED
        entry.last_error_code = RestoreQueue.ERROR_CODES.NOT_SERIALIZABLE
        entry.last_error_message = "snapshot contains non-serializable state"
        SetPlayerGuard(player, entry.state, entry.transaction_id)
        return false, entry.last_error_code
    end

    local registry, registry_code = StateAdapterRegistry.New()
    if registry == nil then
        entry.state = RestoreQueue.STATES.RESTORE_BLOCKED
        entry.last_error_code = registry_code or RestoreQueue.ERROR_CODES.RESTORE_FAILED
        SetPlayerGuard(player, entry.state, entry.transaction_id)
        return false, entry.last_error_code
    end
    local context = MakeContext(entry)
    entry.restore_attempts = (entry.restore_attempts or 0) + 1
    entry.state = RestoreQueue.STATES.RESTORING
    entry.last_attempt_at = GetNow(self)
    SetPlayerGuard(player, entry.state, entry.transaction_id)

    local restore_call_ok, restore_result, restore_code, restore_error = pcall(
        registry.Restore,
        registry,
        player,
        entry.snapshot,
        context
    )
    local restored = restore_result
    if not restore_call_ok then
        restored = false
        restore_code = RestoreQueue.ERROR_CODES.RESTORE_FAILED
        restore_error = tostring(restore_result)
    end
    if not restored then
        entry.state = RestoreQueue.STATES.RESTORE_BLOCKED
        entry.last_error_code = restore_code or RestoreQueue.ERROR_CODES.RESTORE_FAILED
        entry.last_error_message = restore_error
            or (reason ~= nil and tostring(reason) or nil)
        SetPlayerGuard(player, entry.state, entry.transaction_id)
        return false, entry.last_error_code
    end
    local validate_call_ok, validate_result, validate_code, validate_error = pcall(
        registry.ValidateRestore,
        registry,
        player,
        entry.snapshot,
        context
    )
    local valid = validate_result
    if not validate_call_ok then
        valid = false
        validate_code = RestoreQueue.ERROR_CODES.RESTORE_VALIDATION_FAILED
        validate_error = tostring(validate_result)
    end
    if not valid then
        entry.state = RestoreQueue.STATES.RESTORE_BLOCKED
        entry.last_error_code = validate_code or RestoreQueue.ERROR_CODES.RESTORE_VALIDATION_FAILED
        entry.last_error_message = validate_error
            or (reason ~= nil and tostring(reason) or nil)
        SetPlayerGuard(player, entry.state, entry.transaction_id)
        return false, entry.last_error_code
    end

    entry.state = RestoreQueue.STATES.RESTORED
    entry.restored_at = GetNow(self)
    entry.last_error_code = nil
    entry.last_error_message = nil
    SetPlayerGuard(player, entry.state, entry.transaction_id)
    return true
end

function RestoreQueue.TryRestore(self, player)
    if not IsValidPlayer(player) then
        return false, RestoreQueue.ERROR_CODES.PLAYER_INVALID
    end
    local entry = self.entries_by_userid[player.userid]
    if entry == nil then
        return false, RestoreQueue.ERROR_CODES.NOT_FOUND
    end
    return RestoreEntry(self, entry, player, "reconnect_restore")
end

function RestoreQueue.Retry(self, subject, player)
    local entry = self:Get(subject)
    if entry == nil then
        return false, RestoreQueue.ERROR_CODES.NOT_FOUND
    end
    if player ~= nil and (not IsValidPlayer(player) or player.userid ~= entry.userid) then
        return false, RestoreQueue.ERROR_CODES.PLAYER_USERID_MISMATCH
    end
    if entry.state == RestoreQueue.STATES.RESTORE_BLOCKED then
        entry.state = RestoreQueue.STATES.RESTORE_PENDING
    end
    return RestoreEntry(self, entry, player, "admin_retry_restore")
end

function RestoreQueue.GetSnapshot(self)
    return
    {
        schema_version = self.schema_version,
        service_id = self.service_id,
        service_version = self.service_version,
        entries = self:List(),
    }
end

function RestoreQueue.OnLoad(self, data)
    if data == nil then
        return true
    end
    local copied, copy_code = Schema.CopyPure(data)
    if type(copied) ~= "table"
        or copied.schema_version ~= self.schema_version
        or (copied.entries ~= nil and type(copied.entries) ~= "table") then
        return false, copy_code or RestoreQueue.ERROR_CODES.INVALID_SNAPSHOT
    end
    self.entries_by_transaction_id = {}
    self.entries_by_userid = {}
    self.entry_order = {}
    for index = 1, #(copied.entries or {}) do
        local entry = copied.entries[index]
        if type(entry) ~= "table"
            or not IsNonEmptyString(entry.transaction_id)
            or not IsNonEmptyString(entry.instance_id)
            or not IsNonEmptyString(entry.userid)
            or type(entry.profile) ~= "table"
            or type(entry.snapshot) ~= "table"
            or type(entry.snapshot.adapters) ~= "table"
            or not IsValidAdapterIds(entry.adapter_ids)
            or (entry.state ~= RestoreQueue.STATES.RESTORE_PENDING
                and entry.state ~= RestoreQueue.STATES.RESTORING
                and entry.state ~= RestoreQueue.STATES.RESTORED
                and entry.state ~= RestoreQueue.STATES.RESTORE_BLOCKED) then
            return false, RestoreQueue.ERROR_CODES.INVALID_SNAPSHOT
        end
        if self.entries_by_transaction_id[entry.transaction_id] ~= nil
            or self.entries_by_userid[entry.userid] ~= nil then
            return false, RestoreQueue.ERROR_CODES.INVALID_SNAPSHOT
        end
        if entry.state == RestoreQueue.STATES.RESTORING then
            entry.state = RestoreQueue.STATES.RESTORE_PENDING
            entry.last_error_code = "RESTORE_INTERRUPTED_BY_RESTART"
        end
        self.entries_by_transaction_id[entry.transaction_id] = entry
        self.entries_by_userid[entry.userid] = entry
        table.insert(self.entry_order, entry.transaction_id)
    end
    return true
end

function RestoreQueue.Validate(self)
    local seen_users = {}
    for index = 1, #self.entry_order do
        local transaction_id = self.entry_order[index]
        local entry = self.entries_by_transaction_id[transaction_id]
        if entry == nil
            or entry.transaction_id ~= transaction_id
            or not IsNonEmptyString(entry.userid)
            or seen_users[entry.userid]
            or self.entries_by_userid[entry.userid] ~= entry
            or type(entry.profile) ~= "table"
            or type(entry.snapshot) ~= "table" then
            return false, RestoreQueue.ERROR_CODES.INVALID_SNAPSHOT
        end
        seen_users[entry.userid] = true
        local pure, pure_code = Schema.IsPure(entry.profile)
        if not pure then
            return false, pure_code or RestoreQueue.ERROR_CODES.INVALID_SNAPSHOT
        end
        local snapshot_valid, snapshot_code = ValidateEntrySnapshot(entry.snapshot)
        if not snapshot_valid then
            return false, snapshot_code
        end
    end
    return true
end

function RestoreQueue.GetPendingCount(self)
    local count = 0
    for index = 1, #self.entry_order do
        local entry = self.entries_by_transaction_id[self.entry_order[index]]
        if entry ~= nil and not IsTerminal(entry.state) then
            count = count + 1
        end
    end
    return count
end

function RestoreQueue.GetDebugString(self)
    local blocked = 0
    for index = 1, #self.entry_order do
        local entry = self.entries_by_transaction_id[self.entry_order[index]]
        if entry ~= nil and entry.state == RestoreQueue.STATES.RESTORE_BLOCKED then
            blocked = blocked + 1
        end
    end
    return string.format(
        "restore_queue entries=%d pending=%d blocked=%d",
        #self.entry_order,
        self:GetPendingCount(),
        blocked
    )
end

local function AttachMethods(queue)
    queue.Enqueue = RestoreQueue.Enqueue
    queue.Get = RestoreQueue.Get
    queue.List = RestoreQueue.List
    queue.MarkDisconnected = RestoreQueue.MarkDisconnected
    queue.TryRestore = RestoreQueue.TryRestore
    queue.Retry = RestoreQueue.Retry
    queue.GetSnapshot = RestoreQueue.GetSnapshot
    queue.OnLoad = RestoreQueue.OnLoad
    queue.Validate = RestoreQueue.Validate
    queue.GetPendingCount = RestoreQueue.GetPendingCount
    queue.GetDebugString = RestoreQueue.GetDebugString
    return queue
end

function RestoreQueue.New(options)
    options = type(options) == "table" and options or {}
    return AttachMethods(
    {
        schema_version = RestoreQueue.SCHEMA_VERSION,
        service_id = RestoreQueue.SERVICE_ID,
        service_version = RestoreQueue.SERVICE_VERSION,
        now_fn = options.now_fn,
        entries_by_transaction_id = {},
        entries_by_userid = {},
        entry_order = {},
    })
end

return RestoreQueue
