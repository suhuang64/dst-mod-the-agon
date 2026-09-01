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

-- WP2：通过官方 UserCommand 接口提供最小 server-admin 诊断入口。
-- 配置关闭时不注册 Agon 命令，避免在其他 shard 暴露无效管理入口。
local Diagnostics = require("agon/debug/diagnostics")
local ADMIN_PERMISSION = GLOBAL.COMMAND_PERMISSION ~= nil
    and GLOBAL.COMMAND_PERMISSION.ADMIN
    or "ADMIN"

local function GetAgonRuntime()
    local world = GLOBAL.TheWorld
    if world == nil or world.ismastersim ~= true then
        return nil, Diagnostics.ERROR_CODES.NOT_SERVER_AUTHORITY
    end
    if world.components == nil or world.components.agon_runtime == nil then
        return nil, Diagnostics.ERROR_CODES.CORE_NOT_READY
    end
    return world.components.agon_runtime
end

local function RegisterAgonAdminCommand(name, params, description, handler)
    if type(AddUserCommand) ~= "function" then
        return
    end

    AddUserCommand(name,
    {
        prettyname = name,
        desc = description,
        permission = ADMIN_PERMISSION,
        slash = true,
        usermenu = false,
        servermenu = true,
        params = params,
        vote = false,
        hasaccessfn = function()
            return GetModConfigData("enable_agon") == true
        end,
        serverfn = function(command_params)
            local runtime, runtime_code = GetAgonRuntime()
            if runtime == nil then
                Diagnostics.Log(
                    runtime_code,
                    { operation = name },
                    "Agon runtime is not available"
                )
                return
            end
            handler(runtime, command_params)
        end,
    })
end

if GetModConfigData("enable_agon") == true then
    RegisterAgonAdminCommand(
        "agon.instances",
        {},
        "显示当前 The Agon Instance 状态。",
        function(runtime)
            runtime:DebugInstances()
        end
    )

    RegisterAgonAdminCommand(
        "agon.zones",
        {},
        "显示当前 The Agon Zone 状态。",
        function(runtime)
            runtime:DebugZones()
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.create",
        {},
        "创建一个不构建地形的空 TestMode Instance。",
        function(runtime)
            local instance, code = runtime:CreateInstance("TEST_MODE")
            if instance == nil then
                Diagnostics.Log(
                    code,
                    { shard_id = runtime.shard_id, operation = "test_create" },
                    "empty TestMode creation failed"
                )
                return
            end
            Diagnostics.Log(
                Diagnostics.RESULTS.INSTANCE_CREATED,
                {
                    shard_id = runtime.shard_id,
                    operation = "test_create",
                    instance_id = instance.instance_id,
                    mode_id = instance.mode_id,
                    mode_version = instance.mode_version,
                    zone_id = instance.zone_id,
                    lifecycle_state = instance.lifecycle_state,
                    lifecycle = instance.lifecycle_state,
                },
                "empty TestMode instance created"
            )
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.start",
        { "instance_id" },
        "启动一个已经创建的空 TestMode Instance。",
        function(runtime, params)
            local started, code = runtime:StartInstance(params.instance_id, "test_start")
            if not started then
                Diagnostics.Log(
                    code,
                    {
                        shard_id = runtime.shard_id,
                        operation = "test_start",
                        instance_id = params.instance_id,
                    },
                    "TestMode start failed"
                )
                return
            end
            Diagnostics.Log(
                Diagnostics.RESULTS.INSTANCE_STARTED,
                {
                    shard_id = runtime.shard_id,
                    operation = "test_start",
                    instance_id = params.instance_id,
                    lifecycle = "RUNNING",
                },
                code == "ALREADY_STARTED" and "TestMode instance already running"
                    or "TestMode instance started"
            )
        end
    )

    RegisterAgonAdminCommand(
        "agon.destroy_instance",
        { "instance_id" },
        "按正式销毁 pipeline 销毁一个 The Agon Instance。",
        function(runtime, params)
            local destroyed, code = runtime:DestroyInstance(
                params.instance_id,
                "admin_destroy"
            )
            Diagnostics.Log(
                destroyed and Diagnostics.RESULTS.INSTANCE_DESTROYED or code,
                {
                    shard_id = runtime.shard_id,
                    operation = "destroy_instance",
                    instance_id = params.instance_id,
                },
                destroyed and "Instance destroyed" or "Instance destroy failed"
            )
        end
    )
end
