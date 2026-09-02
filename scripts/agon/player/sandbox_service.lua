-- WP7：每个 Instance 独立的玩家沙箱事务；快照在验证恢复前始终保留。

local PlayerProfile = require("agon/player/player_profile")
local StateAdapterRegistry = require("agon/player/state_adapter_registry")
local Util = require("agon/player/adapters/util")

local SandboxService = {}
SandboxService.SCHEMA_VERSION = 1
SandboxService.SERVICE_ID = "player_sandbox"
SandboxService.SERVICE_VERSION = 1

SandboxService.STATES =
{
    NEW = "NEW",
    CAPTURED = "CAPTURED",
    SANDBOXED = "SANDBOXED",
    RESTORING = "RESTORING",
    RESTORED = "RESTORED",
    COMMITTED = "COMMITTED",
    CAPTURE_FAILED = "CAPTURE_FAILED",
    RESTORE_PENDING = "RESTORE_PENDING",
    RESTORE_BLOCKED = "RESTORE_BLOCKED",
}

SandboxService.ERROR_CODES =
{
    INVALID_INSTANCE = "PLAYER_SANDBOX_INVALID_INSTANCE",
    SERVICE_CLOSED = "PLAYER_SANDBOX_SERVICE_CLOSED",
    INVALID_PARTICIPANT = "PLAYER_SANDBOX_INVALID_PARTICIPANT",
    PLAYER_INVALID = "PLAYER_SANDBOX_PLAYER_INVALID",
    PLAYER_USERID_MISMATCH = "PLAYER_SANDBOX_PLAYER_USERID_MISMATCH",
    LIVE_MUTATION_DISABLED = "PLAYER_SANDBOX_LIVE_MUTATION_DISABLED",
    PROFILE_INVALID = "PLAYER_SANDBOX_PROFILE_INVALID",
    TRANSACTION_NOT_FOUND = "PLAYER_SANDBOX_TRANSACTION_NOT_FOUND",
    TRANSACTION_TERMINAL = "PLAYER_SANDBOX_TRANSACTION_TERMINAL",
    INVALID_STATE = "PLAYER_SANDBOX_INVALID_STATE",
    CAPTURE_FAILED = "PLAYER_SANDBOX_CAPTURE_FAILED",
    CAPTURE_VALIDATION_FAILED = "PLAYER_SANDBOX_CAPTURE_VALIDATION_FAILED",
    CLEAN_FAILED = "PLAYER_SANDBOX_CLEAN_FAILED",
    APPLY_FAILED = "PLAYER_SANDBOX_APPLY_FAILED",
    PLAYER_DISCONNECTED = "PLAYER_SANDBOX_PLAYER_DISCONNECTED",
    RESTORE_FAILED = "PLAYER_SANDBOX_RESTORE_FAILED",
    RESTORE_PENDING = "PLAYER_SANDBOX_RESTORE_PENDING",
    RESTORE_BLOCKED = "PLAYER_SANDBOX_RESTORE_BLOCKED",
    RESTORE_VALIDATION_FAILED = "PLAYER_SANDBOX_RESTORE_VALIDATION_FAILED",
    INVALID_SNAPSHOT = "PLAYER_SANDBOX_INVALID_SNAPSHOT",
}

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPositiveInteger(value)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= 1
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

local function GetUserid(participant)
    if participant == nil then
        return nil
    end
    if type(participant.GetUserid) == "function" then
        return participant:GetUserid()
    end
    return participant.userid
end

local function GetInstanceId(participant)
    if participant == nil then
        return nil
    end
    if type(participant.GetInstanceId) == "function" then
        return participant:GetInstanceId()
    end
    return participant.instance_id
end

local function GetParticipantTransactionId(participant)
    if participant == nil then
        return nil
    end
    if type(participant.GetSandboxTransactionId) == "function" then
        return participant:GetSandboxTransactionId()
    end
    return participant.sandbox_transaction_id
end

local function SetParticipantTransactionId(participant, transaction_id)
    if participant == nil then
        return false
    end
    if type(participant.SetSandboxTransactionId) == "function" then
        return participant:SetSandboxTransactionId(transaction_id)
    end
    participant.sandbox_transaction_id = transaction_id
    return true
end

local function SetError(transaction, code, message)
    transaction.last_error_code = code
    transaction.last_error_message = message ~= nil and tostring(message) or nil
    transaction.updated_at = transaction.updated_at or 0
end

local function IsTerminal(state)
    return state == SandboxService.STATES.COMMITTED
end

local function IsRestorable(state)
    return state == SandboxService.STATES.CAPTURED
        or state == SandboxService.STATES.SANDBOXED
        or state == SandboxService.STATES.RESTORING
        or state == SandboxService.STATES.RESTORE_PENDING
        or state == SandboxService.STATES.RESTORE_BLOCKED
end

local function MakeSnapshot(transaction)
    return
    {
        schema_version = SandboxService.SCHEMA_VERSION,
        transaction_id = transaction.transaction_id,
        instance_id = transaction.instance_id,
        userid = transaction.userid,
        character_prefab = transaction.character_prefab,
        captured_at = transaction.created_at,
        adapters = {},
    }
end

local function ExportTransaction(transaction)
    return
    {
        schema_version = SandboxService.SCHEMA_VERSION,
        transaction_id = transaction.transaction_id,
        instance_id = transaction.instance_id,
        userid = transaction.userid,
        state = transaction.state,
        profile = Util.CopyPureData(transaction.profile),
        snapshot = Util.CopyPureData(transaction.snapshot),
        snapshot_serializable = transaction.snapshot_serializable ~= false,
        character_prefab = transaction.character_prefab,
        adapter_ids = transaction.context ~= nil
            and Util.CopyPureData(transaction.context.adapter_ids)
            or nil,
        clean_entered = transaction.clean_entered == true,
        created_at = transaction.created_at,
        captured_at = transaction.captured_at,
        sandboxed_at = transaction.sandboxed_at,
        restoring_at = transaction.restoring_at,
        restored_at = transaction.restored_at,
        committed_at = transaction.committed_at,
        restore_attempts = transaction.restore_attempts,
        updated_at = transaction.updated_at,
        last_error_code = transaction.last_error_code,
        last_error_message = transaction.last_error_message,
    }
end

local function GetTransaction(self, subject)
    if type(subject) == "string" then
        return self.transactions_by_id[subject]
            or self.transactions_by_userid[subject]
    end
    if type(subject) ~= "table" then
        return nil
    end
    local transaction_id = GetParticipantTransactionId(subject)
    if transaction_id ~= nil then
        return self.transactions_by_id[transaction_id]
    end
    if IsNonEmptyString(subject.userid) then
        return self.transactions_by_userid[subject.userid]
    end
    return nil
end

local function EnsurePlayer(self, participant, player)
    local userid = GetUserid(participant)
    if not IsNonEmptyString(userid) then
        return false, SandboxService.ERROR_CODES.INVALID_PARTICIPANT
    end
    if GetInstanceId(participant) ~= self.instance_id then
        return false, SandboxService.ERROR_CODES.INVALID_PARTICIPANT
    end
    if not Util.IsValidPlayer(player) then
        return false, SandboxService.ERROR_CODES.PLAYER_INVALID
    end
    if player.userid ~= userid then
        return false, SandboxService.ERROR_CODES.PLAYER_USERID_MISMATCH
    end
    return true
end

local function IsLiveMutationAllowed(self, player)
    return Util.IsSyntheticPlayer(player) or self.allow_live_mutation == true
end

local function CreateTransaction(self, participant, player, profile)
    local userid = GetUserid(participant)
    self.next_sequence = self.next_sequence + 1
    local transaction_id = self.instance_id .. ":sandbox:" .. tostring(self.next_sequence)
    local transaction =
    {
        schema_version = SandboxService.SCHEMA_VERSION,
        transaction_id = transaction_id,
        instance_id = self.instance_id,
        userid = userid,
        state = SandboxService.STATES.NEW,
        profile = profile,
        snapshot = nil,
        character_prefab = Util.GetCharacterPrefab(player),
        participant_ref = participant,
        player_ref = player,
        context =
        {
            profile = profile,
            sandbox = { profile = profile, transaction_id = transaction_id },
        },
        created_at = GetNow(self),
        restore_attempts = 0,
    }
    self.transactions_by_id[transaction_id] = transaction
    self.transactions_by_userid[userid] = transaction
    table.insert(self.transaction_order, transaction_id)
    SetParticipantTransactionId(participant, transaction_id)
    return transaction
end

local function MakeExistingTransactionCurrent(self, transaction, participant, player)
    transaction.participant_ref = participant
    transaction.player_ref = player
    transaction.context.sandbox = transaction.context.sandbox or
        { profile = transaction.profile, transaction_id = transaction.transaction_id }
    transaction.context.profile = transaction.profile
    self.transactions_by_userid[transaction.userid] = transaction
    SetParticipantTransactionId(participant, transaction.transaction_id)
end

local function SaveState(self, transaction, state)
    transaction.state = state
    transaction.updated_at = GetNow(self)
end

function SandboxService.GetTransaction(self, subject)
    local transaction = GetTransaction(self, subject)
    return transaction ~= nil and ExportTransaction(transaction) or nil
end

function SandboxService.GetTransactionObject(self, subject)
    return GetTransaction(self, subject)
end

function SandboxService.ListTransactions(self)
    local transactions = {}
    for index = 1, #self.transaction_order do
        local transaction = self.transactions_by_id[self.transaction_order[index]]
        if transaction ~= nil then
            table.insert(transactions, ExportTransaction(transaction))
        end
    end
    return transactions
end

function SandboxService.CaptureOriginal(self, participant, player, profile)
    if self.closed then
        return nil, SandboxService.ERROR_CODES.SERVICE_CLOSED
    end
    local player_valid, player_code = EnsurePlayer(self, participant, player)
    if not player_valid then
        return nil, player_code
    end
    if not IsLiveMutationAllowed(self, player) then
        return nil, SandboxService.ERROR_CODES.LIVE_MUTATION_DISABLED
    end
    local normalized, profile_code = PlayerProfile.Normalize(profile)
    if normalized == nil then
        return nil, profile_code or SandboxService.ERROR_CODES.PROFILE_INVALID
    end

    local existing = GetTransaction(self, participant)
    if existing ~= nil then
        if existing.state == SandboxService.STATES.SANDBOXED
            and existing.player_ref == player then
            return existing, "ALREADY_SANDBOXED"
        end
        if existing.state == SandboxService.STATES.COMMITTED then
            return nil, SandboxService.ERROR_CODES.TRANSACTION_TERMINAL
        end
        if existing.profile.profile_id ~= normalized.profile_id
            or existing.profile.version ~= normalized.version then
            return nil, SandboxService.ERROR_CODES.TRANSACTION_TERMINAL
        end
        MakeExistingTransactionCurrent(self, existing, participant, player)
        return existing
    end

    local transaction = CreateTransaction(self, participant, player, normalized)
    transaction.snapshot = MakeSnapshot(transaction)
    local captured, capture_code, adapter_id = self.adapter_registry:Capture(
        player,
        transaction.snapshot,
        transaction.context
    )
    if not captured then
        SaveState(self, transaction, SandboxService.STATES.CAPTURE_FAILED)
        SetError(transaction, capture_code or SandboxService.ERROR_CODES.CAPTURE_FAILED, adapter_id)
        return nil, capture_code or SandboxService.ERROR_CODES.CAPTURE_FAILED
    end
    local validated, validate_code = self.adapter_registry:ValidateCapture(
        player,
        transaction.snapshot,
        transaction.context
    )
    if not validated then
        SaveState(self, transaction, SandboxService.STATES.CAPTURE_FAILED)
        SetError(transaction, validate_code or SandboxService.ERROR_CODES.CAPTURE_VALIDATION_FAILED)
        return nil, validate_code or SandboxService.ERROR_CODES.CAPTURE_VALIDATION_FAILED
    end
    transaction.captured_at = GetNow(self)
    transaction.snapshot_serializable = true
    SaveState(self, transaction, SandboxService.STATES.CAPTURED)
    return transaction
end

function SandboxService.ValidateSnapshot(self, subject, player)
    local transaction = GetTransaction(self, subject)
    if transaction == nil or transaction.snapshot == nil then
        return false, SandboxService.ERROR_CODES.TRANSACTION_NOT_FOUND
    end
    player = player or transaction.player_ref
    if not Util.IsValidPlayer(player) then
        return false, SandboxService.ERROR_CODES.PLAYER_INVALID
    end
    local valid, code = self.adapter_registry:ValidateCapture(
        player,
        transaction.snapshot,
        transaction.context
    )
    if not valid then
        SetError(transaction, code or SandboxService.ERROR_CODES.CAPTURE_VALIDATION_FAILED)
        return false, code or SandboxService.ERROR_CODES.CAPTURE_VALIDATION_FAILED
    end
    return true
end

function SandboxService.EnterCleanState(self, subject, player)
    local transaction = GetTransaction(self, subject)
    if transaction == nil then
        return false, SandboxService.ERROR_CODES.TRANSACTION_NOT_FOUND
    end
    if transaction.state == SandboxService.STATES.SANDBOXED then
        return true, "ALREADY_CLEAN"
    end
    if transaction.state ~= SandboxService.STATES.CAPTURED then
        return false, SandboxService.ERROR_CODES.INVALID_STATE
    end
    player = player or transaction.player_ref
    if not Util.IsValidPlayer(player) then
        return false, SandboxService.ERROR_CODES.PLAYER_INVALID
    end
    local cleaned, code, adapter_id = self.adapter_registry:EnterCleanState(
        player,
        transaction.context
    )
    if not cleaned then
        SetError(transaction, code or SandboxService.ERROR_CODES.CLEAN_FAILED, adapter_id)
        return false, code or SandboxService.ERROR_CODES.CLEAN_FAILED
    end
    transaction.clean_entered = true
    return true
end

function SandboxService.ApplyPlayerProfile(self, player, profile, participant)
    local transaction = GetTransaction(self, participant or player)
    if transaction == nil then
        if participant == nil then
            return false, SandboxService.ERROR_CODES.TRANSACTION_NOT_FOUND
        end
        local entered, entered_code = self:Enter(participant, player, profile)
        return entered, entered_code
    end
    if transaction.state == SandboxService.STATES.SANDBOXED then
        return true, "ALREADY_APPLIED"
    end
    if transaction.state ~= SandboxService.STATES.CAPTURED then
        return false, SandboxService.ERROR_CODES.INVALID_STATE
    end
    local normalized, profile_code = PlayerProfile.Normalize(profile or transaction.profile)
    if normalized == nil then
        return false, profile_code or SandboxService.ERROR_CODES.PROFILE_INVALID
    end
    if normalized.profile_id ~= transaction.profile.profile_id
        or normalized.version ~= transaction.profile.version then
        return false, SandboxService.ERROR_CODES.PROFILE_INVALID
    end
    transaction.context.profile = normalized
    transaction.context.sandbox.profile = normalized
    local applied, code, adapter_id = self.adapter_registry:ApplyOverrides(
        player,
        transaction.context
    )
    if not applied then
        SetError(transaction, code or SandboxService.ERROR_CODES.APPLY_FAILED, adapter_id)
        return false, code or SandboxService.ERROR_CODES.APPLY_FAILED
    end
    transaction.profile = normalized
    return true
end

local function ClassifyRestoreFailure(code)
    if code == SandboxService.ERROR_CODES.PLAYER_DISCONNECTED
        or code == SandboxService.ERROR_CODES.PLAYER_INVALID then
        return SandboxService.STATES.RESTORE_PENDING
    end
    return SandboxService.STATES.RESTORE_BLOCKED
end

local function RestoreInternal(self, transaction, player, reason)
    if transaction.state == SandboxService.STATES.COMMITTED then
        return true, "ALREADY_COMMITTED"
    end
    if transaction.state == SandboxService.STATES.RESTORED then
        SaveState(self, transaction, SandboxService.STATES.COMMITTED)
        transaction.committed_at = GetNow(self)
        return true
    end
    if transaction.state == SandboxService.STATES.CAPTURE_FAILED then
        SaveState(self, transaction, SandboxService.STATES.COMMITTED)
        transaction.committed_at = GetNow(self)
        return true, "CAPTURE_FAILED_NO_MUTATION"
    end
    if not IsRestorable(transaction.state) then
        return false, SandboxService.ERROR_CODES.INVALID_STATE
    end
    player = player or transaction.player_ref
    if not Util.IsValidPlayer(player) then
        SaveState(self, transaction, SandboxService.STATES.RESTORE_PENDING)
        SetError(transaction, SandboxService.ERROR_CODES.PLAYER_DISCONNECTED, reason)
        return false, SandboxService.ERROR_CODES.PLAYER_DISCONNECTED
    end

    transaction.player_ref = player
    transaction.restoring_at = GetNow(self)
    transaction.restore_attempts = (transaction.restore_attempts or 0) + 1
    local had_clean_state = transaction.clean_entered == true
    SaveState(self, transaction, SandboxService.STATES.RESTORING)

    local first_error = nil
    if had_clean_state then
        local removed, remove_code = self.adapter_registry:RemoveOverrides(
            player,
            transaction.context
        )
        if not removed then
            first_error = remove_code or SandboxService.ERROR_CODES.RESTORE_FAILED
        end
    end
    local restored, restore_code, adapter_id = self.adapter_registry:Restore(
        player,
        transaction.snapshot,
        transaction.context
    )
    if not restored then
        first_error = first_error or restore_code or SandboxService.ERROR_CODES.RESTORE_FAILED
        SaveState(self, transaction, ClassifyRestoreFailure(first_error))
        SetError(transaction, first_error, adapter_id or reason)
        return false, first_error
    end
    local valid, validate_code, validate_adapter_id = self.adapter_registry:ValidateRestore(
        player,
        transaction.snapshot,
        transaction.context
    )
    if not valid then
        first_error = first_error or validate_code or SandboxService.ERROR_CODES.RESTORE_VALIDATION_FAILED
        SaveState(self, transaction, ClassifyRestoreFailure(first_error))
        SetError(transaction, first_error, validate_adapter_id or reason)
        return false, first_error
    end
    transaction.restored_at = GetNow(self)
    SaveState(self, transaction, SandboxService.STATES.RESTORED)
    transaction.committed_at = GetNow(self)
    SaveState(self, transaction, SandboxService.STATES.COMMITTED)
    return true
end

function SandboxService.RestoreOriginal(self, subject, player, reason)
    local transaction = GetTransaction(self, subject)
    if transaction == nil then
        return false, SandboxService.ERROR_CODES.TRANSACTION_NOT_FOUND
    end
    return RestoreInternal(self, transaction, player, reason or "restore")
end

function SandboxService.ValidateRestore(self, subject, player)
    local transaction = GetTransaction(self, subject)
    if transaction == nil or transaction.snapshot == nil then
        return false, SandboxService.ERROR_CODES.TRANSACTION_NOT_FOUND
    end
    player = player or transaction.player_ref
    if not Util.IsValidPlayer(player) then
        return false, SandboxService.ERROR_CODES.PLAYER_DISCONNECTED
    end
    return self.adapter_registry:ValidateRestore(
        player,
        transaction.snapshot,
        transaction.context
    )
end

function SandboxService.Enter(self, participant, player, profile)
    local transaction, capture_code = self:CaptureOriginal(
        participant,
        player,
        profile
    )
    if transaction == nil then
        return false, capture_code
    end
    if transaction.state == SandboxService.STATES.SANDBOXED then
        return true, "ALREADY_SANDBOXED"
    end
    local snapshot_valid, snapshot_code = self:ValidateSnapshot(transaction, player)
    if not snapshot_valid then
        SaveState(self, transaction, SandboxService.STATES.CAPTURE_FAILED)
        SetError(transaction, snapshot_code)
        return false, snapshot_code
    end
    local cleaned, clean_code = self:EnterCleanState(transaction, player)
    if not cleaned then
        local restored = RestoreInternal(self, transaction, player, "clean_failed")
        if not restored then
            return false, clean_code or SandboxService.ERROR_CODES.CLEAN_FAILED
        end
        return false, clean_code or SandboxService.ERROR_CODES.CLEAN_FAILED
    end
    local applied, apply_code = self:ApplyPlayerProfile(player, transaction.profile, participant)
    if not applied then
        local restored = RestoreInternal(self, transaction, player, "apply_failed")
        if not restored then
            return false, apply_code or SandboxService.ERROR_CODES.APPLY_FAILED
        end
        return false, apply_code or SandboxService.ERROR_CODES.APPLY_FAILED
    end
    transaction.player_ref = player
    transaction.sandboxed_at = GetNow(self)
    SaveState(self, transaction, SandboxService.STATES.SANDBOXED)
    return true, transaction.transaction_id
end

function SandboxService.RetryRestore(self, subject, player)
    local transaction = GetTransaction(self, subject)
    if transaction == nil then
        return false, SandboxService.ERROR_CODES.TRANSACTION_NOT_FOUND
    end
    if player ~= nil then
        local valid, code = EnsurePlayer(self, transaction.participant_ref, player)
        if not valid then
            return false, code
        end
        transaction.player_ref = player
    end
    return RestoreInternal(self, transaction, player, "retry_restore")
end

function SandboxService.MarkDisconnected(self, participant, reason)
    local transaction = GetTransaction(self, participant)
    if transaction == nil then
        return true, "NO_SANDBOX_TRANSACTION"
    end
    transaction.player_ref = nil
    if transaction.state == SandboxService.STATES.SANDBOXED
        or transaction.state == SandboxService.STATES.CAPTURED
        or transaction.state == SandboxService.STATES.RESTORING then
        SaveState(self, transaction, SandboxService.STATES.RESTORE_PENDING)
    end
    SetError(transaction, SandboxService.ERROR_CODES.PLAYER_DISCONNECTED, reason)
    return true
end

function SandboxService.GetSnapshot(self)
    local transactions = {}
    for index = 1, #self.transaction_order do
        local transaction = self.transactions_by_id[self.transaction_order[index]]
        if transaction ~= nil then
            table.insert(transactions, ExportTransaction(transaction))
        end
    end
    return
    {
        schema_version = self.schema_version,
        service_id = self.service_id,
        service_version = self.service_version,
        instance_id = self.instance_id,
        next_sequence = self.next_sequence,
        transactions = transactions,
        adapter_registry = self.adapter_registry:GetSnapshot(),
    }
end

function SandboxService.Validate(self)
    local adapters_valid, adapters_code = self.adapter_registry:Validate()
    if not adapters_valid then
        return false, adapters_code
    end
    for index = 1, #self.transaction_order do
        local transaction_id = self.transaction_order[index]
        local transaction = self.transactions_by_id[transaction_id]
        if transaction == nil
            or transaction.transaction_id ~= transaction_id
            or transaction.instance_id ~= self.instance_id
            or not IsNonEmptyString(transaction.userid)
            or not IsNonEmptyString(transaction.state)
            or transaction.snapshot == nil and transaction.state ~= SandboxService.STATES.NEW then
            return false, SandboxService.ERROR_CODES.INVALID_SNAPSHOT
        end
        if self.transactions_by_userid[transaction.userid] ~= transaction
            and not IsTerminal(transaction.state) then
            return false, SandboxService.ERROR_CODES.INVALID_SNAPSHOT
        end
    end
    return true
end

function SandboxService.Close(self, reason)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    for index = #self.transaction_order, 1, -1 do
        local transaction = self.transactions_by_id[self.transaction_order[index]]
        if transaction ~= nil and IsRestorable(transaction.state) then
            local restored = RestoreInternal(self, transaction, transaction.player_ref, reason or "service_close")
            if not restored and transaction.player_ref == nil then
                SaveState(self, transaction, SandboxService.STATES.RESTORE_PENDING)
            end
        end
    end
    -- 玩家失败只保留 pending 证据，不阻塞其他 Instance 的 Zone/Scene 清理。
    self.closed = true
    self.last_close_reason = reason
    return true
end

function SandboxService.GetDebugString(self)
    local counts = {}
    for index = 1, #self.transaction_order do
        local transaction = self.transactions_by_id[self.transaction_order[index]]
        if transaction ~= nil then
            counts[transaction.state] = (counts[transaction.state] or 0) + 1
        end
    end
    return string.format(
        "player_sandbox instance=%s transactions=%d committed=%d pending=%d blocked=%d",
        tostring(self.instance_id),
        #self.transaction_order,
        counts[SandboxService.STATES.COMMITTED] or 0,
        counts[SandboxService.STATES.RESTORE_PENDING] or 0,
        counts[SandboxService.STATES.RESTORE_BLOCKED] or 0
    )
end

function SandboxService.SetLivePlayerTestEnabled(self, enabled)
    if type(enabled) ~= "boolean" then
        return false, SandboxService.ERROR_CODES.INVALID_SNAPSHOT
    end
    self.allow_live_mutation = enabled
    return true
end

local function AttachMethods(service)
    service.GetTransaction = SandboxService.GetTransaction
    service.GetTransactionObject = SandboxService.GetTransactionObject
    service.ListTransactions = SandboxService.ListTransactions
    service.CaptureOriginal = SandboxService.CaptureOriginal
    service.ValidateSnapshot = SandboxService.ValidateSnapshot
    service.EnterCleanState = SandboxService.EnterCleanState
    service.ApplyPlayerProfile = SandboxService.ApplyPlayerProfile
    service.RestoreOriginal = SandboxService.RestoreOriginal
    service.ValidateRestore = SandboxService.ValidateRestore
    service.Enter = SandboxService.Enter
    service.RetryRestore = SandboxService.RetryRestore
    service.MarkDisconnected = SandboxService.MarkDisconnected
    service.GetSnapshot = SandboxService.GetSnapshot
    service.Validate = SandboxService.Validate
    service.Close = SandboxService.Close
    service.GetDebugString = SandboxService.GetDebugString
    service.SetLivePlayerTestEnabled = SandboxService.SetLivePlayerTestEnabled
    return service
end

function SandboxService.New(instance, services, options)
    if type(instance) ~= "table"
        or not IsNonEmptyString(instance.instance_id) then
        return nil, SandboxService.ERROR_CODES.INVALID_INSTANCE
    end
    options = type(options) == "table" and options or {}
    local adapter_registry = options.adapter_registry or StateAdapterRegistry.New()
    if adapter_registry == nil or type(adapter_registry.Validate) ~= "function" then
        return nil, SandboxService.ERROR_CODES.INVALID_SNAPSHOT
    end
    local valid, code = adapter_registry:Validate()
    if not valid then
        return nil, code or SandboxService.ERROR_CODES.INVALID_SNAPSHOT
    end
    return AttachMethods(
    {
        schema_version = SandboxService.SCHEMA_VERSION,
        service_id = SandboxService.SERVICE_ID,
        service_version = SandboxService.SERVICE_VERSION,
        instance = instance,
        instance_id = instance.instance_id,
        services = services or {},
        now_fn = options.now_fn,
        -- 真实玩家只允许由 Test/World01 的内存态验收开关放行；合成玩家
        -- 仍由 IsLiveMutationAllowed 单独允许，不能通过任意 service option 绕过。
        allow_live_mutation = options.allow_live_player_test == true,
        adapter_registry = adapter_registry,
        transactions_by_id = {},
        transactions_by_userid = {},
        transaction_order = {},
        next_sequence = 0,
        closed = false,
    })
end

return SandboxService
