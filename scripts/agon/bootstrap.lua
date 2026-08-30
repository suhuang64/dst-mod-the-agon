local Diagnostics = require("agon/debug/diagnostics")

local Bootstrap = {}

function Bootstrap.StartServerRuntime(world)
    if world == nil then
        return nil, Diagnostics.ERROR_CODES.INVALID_WORLD
    end

    -- 这是每个 shard 的服务端权威模拟硬门，不是 Master/Secondary shard 判断。
    -- 配置硬门已由 modmain 先行处理，因此只有服务端路径才会加载本模块。
    if world.ismastersim ~= true then
        return nil, Diagnostics.ERROR_CODES.NOT_SERVER_AUTHORITY
    end

    if type(world.AddComponent) ~= "function" then
        Diagnostics.Log(
            Diagnostics.ERROR_CODES.INVALID_WORLD,
            { operation = "start_server_runtime" },
            "world has no AddComponent method"
        )
        return nil, Diagnostics.ERROR_CODES.INVALID_WORLD
    end

    -- 已存在 runtime 时直接返回同一实例，保证重复启动不重复添加组件或输出成功日志。
    if world.components ~= nil and world.components.agon_runtime ~= nil then
        return world.components.agon_runtime, Diagnostics.RESULTS.ALREADY_STARTED
    end

    local runtime = world:AddComponent("agon_runtime")
    if runtime == nil then
        Diagnostics.Log(
            Diagnostics.ERROR_CODES.INVALID_WORLD,
            { operation = "start_server_runtime" },
            "agon_runtime component was not created"
        )
        return nil, Diagnostics.ERROR_CODES.INVALID_WORLD
    end

    Diagnostics.Log(
        Diagnostics.RESULTS.STARTED,
        {
            shard_id = runtime.shard_id,
            operation = "start_server_runtime",
            schema_version = runtime.schema_version,
            boot_generation = runtime.boot_generation,
        },
        "server runtime started"
    )

    return runtime, Diagnostics.RESULTS.STARTED
end

return Bootstrap
