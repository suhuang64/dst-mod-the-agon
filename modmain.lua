-- WP0：The Agon 公共底座 Mod 骨架
--
-- 共享/客户端声明区必须位于服务端硬门之前，并且始终注册。WP0 尚无需要
-- 注册的客户端 Prefab、classified 或 RPC。

local function StartAgonServerRuntime(world)
    -- world.ismastersim 表示当前 shard 持有权威模拟；这里不是 Master shard
    -- 判断，避免把服务端权威与 shard 拓扑角色混为一谈。
    if world == nil or world.ismastersim ~= true then
        return nil
    end

    if GetModConfigData("enable_agon") ~= true then
        return nil
    end

    -- 保持服务端模块与客户端路径隔离。只有配置硬门和权威模拟硬门都通过后，
    -- 才会执行这个 require。
    local bootstrap = require("agon/bootstrap")
    return bootstrap.StartServerRuntime(world)
end

-- world 回调无条件注册，避免通过顶层配置 return 跳过共享/客户端声明区。
AddPrefabPostInit("world", StartAgonServerRuntime)
