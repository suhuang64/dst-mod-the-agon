-- WP0：The Agon 公共底座 Mod 骨架
--
-- 共享/客户端声明区必须位于服务端硬门之前，并且始终注册。WP4 在这里
-- 注册 classified Prefab 与 RPC；真正的 Instance-aware 行为仍由服务端 runtime 控制。

PrefabFiles =
{
    "agon_player_classified",
    "agon_spectator_echo",
}

-- WP4：RPC 定义和 classified 必须在客户端/服务端共享注册区无条件加载；
-- 具体请求仍由服务端 runtime 再做 Instance-aware 校验。
local AgonRpc = require("agon/net/rpc")
AgonRpc.Register()

-- WP10：物品、装备、容器和物品拾取的全局组件入口必须在服务端统一拒绝；
-- hook 本身在普通玩家上透传官方实现，只对 is_spectator 生效。
local SpectatorInventoryGuard = require("agon/player/spectator_inventory_guard")
if type(AddComponentPostInit) == "function"
    and SpectatorInventoryGuard ~= nil then
    AddComponentPostInit(
        "inventoryitem",
        SpectatorInventoryGuard.InstallInventoryItem
    )
    AddComponentPostInit(
        "equippable",
        SpectatorInventoryGuard.InstallEquippable
    )
    AddComponentPostInit(
        "container",
        SpectatorInventoryGuard.InstallContainer
    )
end

-- WP10：PlayerController 在官方 Enable(false) 状态下会跳过镜头控制；
-- 观战只替换客户端 DoCameraControl，保留服务端对移动和交互的封锁。
local SpectatorInput = require("agon/player/spectator_input")
if type(AddClassPostConstruct) == "function"
    and SpectatorInput ~= nil
    and type(SpectatorInput.Install) == "function" then
    AddClassPostConstruct("components/playercontroller", SpectatorInput.Install)
end

-- WP10：客户端物品栏/装备栏/鼠标携带物品/制作栏只在本地 Spectator 期间隐藏；
-- 服务器 guard 仍是最终权限边界，不能依赖 UI 拦截。
local SpectatorHud = require("agon/player/spectator_hud")
if type(AddClassPostConstruct) == "function"
    and SpectatorHud ~= nil
    and type(SpectatorHud.Install) == "function" then
    AddClassPostConstruct("screens/playerhud", SpectatorHud.Install)
end

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

-- `AddPrefabPostInit("world", ...)` 负责在存档读写前创建组件；真正依赖 Portal、
-- 地图尺寸和已完成 world populate 的布局/核心初始化必须放到官方 SimPostInit。
-- 服务器侧 SimPostInit 会在 TheWorld:PostInit() 前执行，且回调参数在 dedicated
-- server 上为 nil，因此从 GLOBAL.TheWorld 读取 world。重复调用由 runtime 自身幂等保护。
if type(AddSimPostInit) == "function" then
    AddSimPostInit(function()
        local world = GLOBAL.TheWorld
        if world == nil or world.ismastersim ~= true
            or GetModConfigData("enable_agon") ~= true then
            return
        end
        local runtime = world.components ~= nil
            and world.components.agon_runtime
            or nil
        if runtime == nil then
            runtime = StartAgonServerRuntime(world)
        end
        if runtime ~= nil and type(runtime.OnPostInit) == "function" then
            runtime:OnPostInit()
        end
    end)
end

-- WP4：把自定义 classified 绑定到玩家。没有启用 The Agon 的 shard 不会创建
-- server runtime，因此这里不会产生任何额外的实体或监听器。
AddPlayerPostInit(function(player)
    local world = GLOBAL.TheWorld
    local runtime = world ~= nil
        and world.ismastersim == true
        and world.components ~= nil
        and world.components.agon_runtime
        or nil
    if runtime ~= nil then
        runtime:OnPlayerAdded(player)
    end
end)

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

local function RegisterAgonAdminCommand(name, params, description, handler, accessfn)
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
        hasaccessfn = function(command, caller, targetid)
            if GetModConfigData("enable_agon") ~= true then
                return false
            end
            return accessfn == nil or accessfn(command, caller, targetid)
        end,
        serverfn = function(command_params, caller)
            local runtime, runtime_code = GetAgonRuntime()
            if runtime == nil then
                Diagnostics.Log(
                    runtime_code,
                    { operation = name },
                    "Agon runtime is not available"
                )
                return
            end
            handler(runtime, command_params, caller)
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
        "创建一个尚未启动的 TestMode Instance。",
        function(runtime)
            local instance, code = runtime:CreateInstance("TEST_MODE")
            if instance == nil then
                Diagnostics.Log(
                    code,
                    { shard_id = runtime.shard_id, operation = "test_create" },
                    "TestMode creation failed"
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
                "TestMode instance created"
            )
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.start",
        { "instance_id" },
        "构建并启动一个已经创建的 TestMode Instance。",
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
        "agon.test.scene",
        { "instance_id", "operation" },
        "对 TestMode 执行场景计划：BLOCKING_PATCH、LIVE_PATCH_EMPTY、LIVE_PATCH_OCCUPIED_REJECT 或 LIVE_PATCH_OCCUPIED_MOVE。",
        function(runtime, params)
            local applied, code = runtime:ApplyScene(
                params.instance_id,
                params.operation,
                "test_scene"
            )
            Diagnostics.Log(
                applied and Diagnostics.RESULTS.SCENE_APPLIED or code,
                {
                    shard_id = runtime.shard_id,
                    operation = "test_scene",
                    instance_id = params.instance_id,
                    scene_operation = params.operation,
                },
                applied and "TestMode scene plan applied" or "TestMode scene plan failed"
            )
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.wp4",
        {},
        "运行 The Agon WP4 的实例隔离、随机流、定向状态和 RPC 幂等诊断。",
        function(runtime)
            runtime:RunWP4Diagnostics()
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.wp5",
        {},
        "运行 The Agon WP5 的分组、阶段、时钟、投票、Effect 和 Score 诊断。",
        function(runtime)
            runtime:RunWP5Diagnostics()
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.wp6",
        {},
        "运行 The Agon WP6 的实体与物品 Profile、应用模式、继承和清理诊断。",
        function(runtime)
            runtime:RunWP6Diagnostics()
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.wp7",
        {},
        "运行 The Agon WP7 的玩家沙箱、统一 Profile、恢复、重试和故障隔离诊断。",
        function(runtime)
            runtime:RunWP7Diagnostics()
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.wp8",
        {},
        "运行 The Agon WP8 的大厅、观战残影、观战隔离和死亡策略诊断。",
        function(runtime)
            runtime:RunWP8Diagnostics()
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.wp9",
        {},
        "运行 The Agon WP9 的持久化、重启恢复队列和后端幂等边界诊断。",
        function(runtime)
            runtime:RunWP9Diagnostics()
        end
    )

    RegisterAgonAdminCommand(
        "agon.test.player_sandbox",
        { "action" },
        "仅在 Test/World01 临时允许真实玩家进入 PlayerSandbox；action 使用 on、off 或 status。",
        function(runtime, params, caller)
            local action = type(params.action) == "string"
                and string.lower(params.action)
                or ""
            local caller_userid = caller ~= nil and caller.userid or "server"
            if action == "on" or action == "off" then
                local enabled, code = runtime:SetLivePlayerTestEnabled(action == "on")
                Diagnostics.Log(
                    code,
                    {
                        shard_id = runtime.shard_id,
                        operation = "live_player_test_" .. action,
                        userid = caller_userid,
                    },
                    enabled
                        and (action == "on"
                            and "Live player sandbox test enabled for new TestMode instances"
                            or "Live player sandbox test disabled")
                        or "Live player sandbox test switch rejected"
                )
                return
            end
            if action == "status" then
                local status = runtime:GetLivePlayerTestStatus()
                Diagnostics.Log(
                    Diagnostics.RESULTS.PLAYER_TEST_STATUS,
                    {
                        shard_id = runtime.shard_id,
                        operation = "live_player_test_status",
                        userid = caller_userid,
                    },
                    "enabled=" .. tostring(status.enabled)
                        .. " eligible=" .. tostring(status.eligible)
                        .. " code=" .. tostring(status.code)
                )
                return
            end
            Diagnostics.Log(
                Diagnostics.ERROR_CODES.PLAYER_SANDBOX_TEST_ACTION_INVALID,
                {
                    shard_id = runtime.shard_id,
                    operation = "live_player_test_invalid_action",
                    userid = caller_userid,
                },
                "Use action on, off or status"
            )
        end,
        function()
            -- 客户端需要看见这个管理员入口；真正执行时仍由服务端
            -- Runtime 再次检查 Test/World01 指纹，不能依赖客户端判断。
            local world = GLOBAL.TheWorld
            if world == nil or world.ismastersim ~= true then
                return true
            end
            local runtime = GetAgonRuntime()
            return runtime ~= nil and runtime:CanUseLivePlayerTest()
        end
    )

    RegisterAgonAdminCommand(
        "agon.recovery",
        {},
        "显示 The Agon 重启恢复、玩家恢复队列和后端 pending 状态。",
        function(runtime)
            runtime:DebugRecovery()
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
