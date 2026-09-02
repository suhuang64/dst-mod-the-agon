-- WP10 真实玩家验收资格门。该模块只读取官方运行时身份，不保存任何状态。

local TestGate = {}

-- 当前 Test/cluster.ini 的 cluster_name，使用 UTF-8 数字转义避免源文件编码
-- 改写时破坏两个边界图标。Cluster 名称或描述变更时，必须同步更新这里。
local TEST_CLUSTER_NAME =
    "\243\176\128\142\232\141\146\233\135\142\230\177\130\231\148\159\230\181\139\232\175\149\230\161\163\243\176\128\143"
local TEST_CLUSTER_DESCRIPTION = "测试"
local TEST_SHARD_ID = "1"

TestGate.ERROR_CODES =
{
    CONTEXT_REQUIRED = "PLAYER_SANDBOX_TEST_CONTEXT_REQUIRED",
}

local function ReadMethod(target, method_name)
    if target == nil or type(target[method_name]) ~= "function" then
        return nil
    end
    local ok, value = pcall(target[method_name], target)
    return ok and value or nil
end

function TestGate.GetContext(world)
    local server_name = ReadMethod(TheNet, "GetServerName")
    local server_description = ReadMethod(TheNet, "GetServerDescription")
    local shard_id = ReadMethod(TheShard, "GetShardId")
    local context =
    {
        authority = world ~= nil and world.ismastersim == true,
        dedicated = ReadMethod(TheNet, "IsDedicated") == true,
        server_name = server_name ~= nil and tostring(server_name) or nil,
        server_description = server_description ~= nil and tostring(server_description) or nil,
        shard_id = shard_id ~= nil and tostring(shard_id) or nil,
    }
    context.cluster_name_matches = context.server_name == TEST_CLUSTER_NAME
    context.cluster_description_matches = context.server_description == TEST_CLUSTER_DESCRIPTION
    context.shard_matches = context.shard_id == TEST_SHARD_ID
    context.eligible = context.authority
        and context.dedicated
        and context.cluster_name_matches
        and context.cluster_description_matches
        and context.shard_matches
    return context
end

function TestGate.IsEligible(world)
    local context = TestGate.GetContext(world)
    if not context.eligible then
        return false, TestGate.ERROR_CODES.CONTEXT_REQUIRED, context
    end
    return true, nil, context
end

return TestGate
