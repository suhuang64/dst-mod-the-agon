# WP10 Base Release Gate：Test/World01 客户端验收脚本

本文是 WP10 的维护者操作脚本。它把服务端已经完成的 WP4–WP9 证据与必须由真实客户端完成的项目分开记录；没有真实客户端结果时，WP10 只能标记为 `WAITING_MAINTAINER`，不能标记为 `Base Ready`。

每次执行都必须把环境、步骤、结果和日志范围追加到 `docs/base-implementation-logs.md`，不得覆盖旧记录。只允许使用 `D:\OneDrive\DST\klei\DoNotStarveTogether\Test\World01`；不要删除或改写其他 Cluster、shard、Mod 或用户存档。

## 1. 当前前置状态

- 官方专服版本：`747465`，Build `4239`。
- Cluster/shard：`Test/World01`；World01 端口 `12000`，Master shard 端口 `11889`。
- Mod 配置：`D:\OneDrive\DST\klei\DoNotStarveTogether\Test\World01\modoverrides.lua` 中 `the-agon.enabled = true` 且 `enable_agon = true`。
- 启动命令（工作目录为 DST `bin64`）：

  ```powershell
  & 'D:\SteamLibrary\steamapps\common\Don''t Starve Together\bin64\dontstarve_dedicated_server_nullrenderer_x64.exe' -persistent_storage_root d:/OneDrive/DST/klei -conf_dir DoNotStarveTogether -cluster Test -shard World01
  ```

- 启动前记录 `D:\OneDrive\DST\klei\DoNotStarveTogether\Test\World01\server_log.txt` 的当前行数和时间；本轮证据只能引用该位置之后的日志。
- 启动后先确认 `LAYOUT_READY`、`CORE_READY`，再确认 Lobby、唯一 `multiplayer_portal`、10 个空闲 Zone 和正常天数增长。
- `hermitcrab_relocation_manager` 与 `wagpunk_arena_manager` 的两条官方 set-piece angle 错误属于已知延后项；本轮记录但不修改官方源码。

## 2. 服务端预检

专服的 `RemoteCommandInput` 会把输入当作 Lua 源码执行；直接输入 `agon.test.wp4` 或 `/agon.test.wp4` 并不会调用 `AddUserCommand` 注册的命令，实测会得到 `attempt to call a nil value`。因此，服务端控制台使用下面的已验证 Runtime 表达式；客户端 UserCommand 菜单若由维护者操作，则按游戏界面实际显示的 `/agon.test.*` 入口执行。不要把前述 nil 报错算作代码回归。

在专服控制台按顺序执行以下表达式，并把每条结果及时间写入记录：

```text
c_announce((function() local ok, code = TheWorld.components.agon_runtime:RunWP4Diagnostics() return "WP10_WP4:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:RunWP5Diagnostics() return "WP10_WP5:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:RunWP6Diagnostics() return "WP10_WP6:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:RunWP7Diagnostics() return "WP10_WP7:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:RunWP8Diagnostics() return "WP10_WP8:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:RunWP9Diagnostics() return "WP10_WP9:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local runtime = TheWorld.components.agon_runtime local ok, code = runtime:ValidateCore() return "WP10_VALIDATE:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local runtime = TheWorld.components.agon_runtime runtime:DebugInstances() runtime:DebugZones() runtime:DebugRecovery() return "WP10_DEBUG:" .. runtime:GetDebugString() end)())
```

预检通过条件：

- 得到 `WP4_TEST_PASS` 至 `WP9_TEST_PASS`；
- `ValidateCore=true`；
- 没有活动测试 Instance 时，`agon.instances` 显示 `0`，`agon.zones` 显示全部 `10/10` 可用；
- 没有新的 `LUA ERROR`、`stack traceback`、`bad argument`、`attempt to call` 或 `nil value`。

这些命令只证明服务端合成路径，不替代下面的真实客户端项目。

## 3. 真实玩家验收开关

真实玩家接入前，必须由管理员在客户端执行：

```text
/agon.test.player_sandbox status
/agon.test.player_sandbox on
```

该命令使用官方 `ADMIN` 权限。服务端还会校验：专服、权威模拟、当前 Test
Cluster 的名称/描述指纹和 `TheShard:GetShardId() == 1`；任一条件不满足都会返回
`PLAYER_SANDBOX_TEST_CONTEXT_REQUIRED`。DST 官方 Lua 没有暴露 Cluster 路径，所以
当前 `Test/cluster.ini` 的 `cluster_name = 󰀎荒野求生测试档󰀏`、`cluster_description = 测试`
是资格指纹的一部分，修改它以后开关会拒绝，不能通过改名绕过。

`on` 只影响之后新建的 `TEST_MODE` Instance；请在第 5 节创建 Instance 之前执行。
测试结束并确认玩家已恢复、Instance 已销毁后执行：

```text
/agon.test.player_sandbox off
/agon.test.player_sandbox status
```

`off` 会撤销现有 Instance 的 live 测试权限，服务器重启也会自动回到
`enabled=false`。RemoteCommandInput 不是 UserCommand 解析器；如果只操作服务端
控制台，使用下面的已验证 Runtime 表达式，不要直接输入 `/agon.test.player_sandbox on`：

```text
c_announce((function() local runtime = TheWorld.components.agon_runtime local ok, code = runtime:SetLivePlayerTestEnabled(true) return "WP10_PLAYER_TEST_ON:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local runtime = TheWorld.components.agon_runtime local status = runtime:GetLivePlayerTestStatus() return "WP10_PLAYER_TEST_STATUS:enabled=" .. tostring(status.enabled) .. " eligible=" .. tostring(status.eligible) .. " code=" .. tostring(status.code) end)())
c_announce((function() local runtime = TheWorld.components.agon_runtime local ok, code = runtime:SetLivePlayerTestEnabled(false) return "WP10_PLAYER_TEST_OFF:" .. tostring(ok) .. ":" .. tostring(code) end)())
```

以上服务端表达式只能证明当前专服 Runtime 的开关状态；管理员命令的真实客户端
菜单显示、真实玩家绑定和逐字段恢复仍必须按后续项目人工执行。

## 4. 记录真实客户端身份

维护者启动两个真实客户端，分别称为客户端 A、客户端 B，让两者加入同一个 `Test/World01`。在两者都进入后，在服务端控制台执行：

```text
c_announce((function()
    local result = {}
    for _, player in ipairs(AllPlayers) do
        table.insert(result, player.userid)
    end
    return "WP10_PLAYERS:" .. table.concat(result, ",")
end)())
```

把输出中的两个真实 `userid` 记为 `A_USERID`、`B_USERID`。不要把合成玩家的 userid 或客户端显示名当作证据。客户端 A/B 需要各自记录：加入时间、角色 prefab、是否位于 Lobby、Portal 相对位置、是否看到对方，以及客户端自己的异常/控制台信息。

加入后必须等待官方 SkillTree `PostActivateHandshake` 完成。服务端应为每个真实玩家
输出一次 `SKILLTREE_HANDSHAKE_COMPLETE`，并且只读诊断应显示
`_PostActivateHandshakeState_Server=POSTACTIVATEHANDSHAKE.READY`（当前官方值为 `3`）、
`agon_handshake=true`。Runtime 使用官方组件同型的 `TheWorld` + 玩家 source 监听，并由
`playeractivated`/`ms_playerjoined` 生命周期保证接线时序；该状态来自官方
`ms_skilltreeinitialized` 事件。`skilltree.save_enabled=false` 本身是官方客户端激活
期间的正常状态，不能据此判断握手失败或手工改成 `true`。若握手尚未完成，不得进入
下一节创建/绑定 Instance。

## 5. 真实 Instance 绑定脚本

当前仓库没有正式 TestMode UI，也没有把 `agon.test.create` 做成带玩家参数的产品入口。下面的控制台片段只用于 WP10 的受控服务端绑定证据，不代表正式客户端 UI；把 `A_USERID`、`B_USERID` 替换为第 3 节记录的值后再执行：

```text
c_announce((function()
    local runtime = TheWorld.components.agon_runtime
    local a = "A_USERID"
    local b = "B_USERID"
    local function find_player(userid)
        for _, player in ipairs(AllPlayers) do
            if player.userid == userid then
                return player
            end
        end
        return nil
    end
    local instance, create_code = runtime:CreateInstance("TEST_MODE", { a, b })
    if instance == nil then
        return "WP10_INSTANCE_CREATE:FAIL:" .. tostring(create_code)
    end
    local attached_a, attach_code_a = runtime.instance_manager:AttachPlayer(
        instance.instance_id, a, find_player(a)
    )
    local attached_b, attach_code_b = runtime.instance_manager:AttachPlayer(
        instance.instance_id, b, find_player(b)
    )
    return "WP10_INSTANCE_CREATE:"
        .. instance.instance_id .. ":" .. instance.zone_id
        .. ":A=" .. tostring(attached_a) .. ":" .. tostring(attach_code_a)
        .. ":B=" .. tostring(attached_b) .. ":" .. tostring(attach_code_b)
end)())
```

未执行第 3 节 `on` 或资格门不满足时，真实玩家预期会看到 `PLAYER_SANDBOX_LIVE_MUTATION_DISABLED`；这不是通过。执行开关后若两名玩家都能成功绑定，才执行：

```text
c_announce((function() local runtime = TheWorld.components.agon_runtime local ok, code = runtime:StartInstance("INSTANCE_ID", "wp10_start") return "WP10_START:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local runtime = TheWorld.components.agon_runtime runtime:DebugInstances() runtime:DebugZones() return "WP10_DEBUG:" .. runtime:GetDebugString() end)())
```

`INSTANCE_ID` 必须替换为实际创建结果中的 Instance ID。

记录 `instance_id`、`zone_id`、`generation`、`scene_revision`、`seed`、两个 participant 状态及服务端日志范围。

## 6. 双 Instance 与 Scene 用例

为验证 A 销毁不影响 B，分别为客户端 A、B 创建两个 Instance，记录为 `INSTANCE_A`、`INSTANCE_B`，再分别启动。RemoteCommandInput 中用下面的表达式代替直接输入 `agon.test.start`、`agon.test.scene` 和 `agon.destroy_instance`；每个用例都要记录动作前后两局的 Instance/Zone/scene revision。

```text
c_announce((function() local ok, code = TheWorld.components.agon_runtime:StartInstance("INSTANCE_A", "wp10_start") return "WP10_START_A:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:StartInstance("INSTANCE_B", "wp10_start") return "WP10_START_B:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:ApplyScene("INSTANCE_A", "BLOCKING_PATCH", "wp10_scene") return "WP10_SCENE_A:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:ApplyScene("INSTANCE_A", "LIVE_PATCH_EMPTY", "wp10_scene") return "WP10_SCENE_A:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:ApplyScene("INSTANCE_A", "LIVE_PATCH_OCCUPIED_REJECT", "wp10_scene") return "WP10_SCENE_A:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:ApplyScene("INSTANCE_A", "LIVE_PATCH_OCCUPIED_MOVE", "wp10_scene") return "WP10_SCENE_A:" .. tostring(ok) .. ":" .. tostring(code) end)())
c_announce((function() local ok, code = TheWorld.components.agon_runtime:DestroyInstance("INSTANCE_A", "wp10_destroy") return "WP10_DESTROY_A:" .. tostring(ok) .. ":" .. tostring(code) end)())
```

`INSTANCE_A`、`INSTANCE_B` 只是占位符，必须替换为实际返回的 ID；不要把这段表达式直接连同占位符执行。

| 编号 | 操作 | 通过条件 |
| --- | --- | --- |
| B1 | A、B 分属不同 Instance；在 A 执行 `ApplyScene(INSTANCE_A, BLOCKING_PATCH)` | A 进入 BLOCKING；B 的 phase、Zone、实体、classified 和画面不变化 |
| B2 | A 执行 `ApplyScene(INSTANCE_A, LIVE_PATCH_EMPTY)` | A 的 revision 增加；B 的 revision 不变；无跨 Zone 地形/实体变化 |
| B3 | 在 A 的 Scene 占用后执行 `LIVE_PATCH_OCCUPIED_REJECT` | A 得到明确拒绝码；原 Scene 保持完整；B 无副作用 |
| B4 | 在 A 的 Scene 占用后执行 `LIVE_PATCH_OCCUPIED_MOVE` | A 只在同一 Zone 的允许安全路径移动；B 无副作用 |
| B5 | 执行 `DestroyInstance(INSTANCE_A)` | B 继续 RUNNING；A 的 Zone 回到可复用；A 的实体、Scope、terrain 和 classified 清理完成 |
| B6 | 用 A 重新创建 Instance | 重新得到新 `instance_id`/generation；不能复用旧运行态或旧 scene revision |

客户端必须额外确认：A/B 是否仍能看见正确的玩家和实体、相机是否越过 `camera_bounds`、Scene 变化后是否出现重复实体、残留地皮或 minimap layer。普通构建不得越过 `build_bounds`，任何修改不得越过 `hard_bounds`。

## 7. 玩家、观战与死亡用例

以下项目只有在真实玩家绑定成功后才可执行。没有正式 UI 时，维护者可以使用已经存在的官方游戏操作，但不得用合成玩家替代客户端画面、StateGraph 或网络可见性证据。

默认 Character Adapter 已登记官方 19 个角色；真实玩家路径已接入逐角色 Capture/Clean/Restore 安全门，并在通过后给所有角色应用可撤销的公平覆盖：生命/饥饿 `150/150`、理智 `200/200`、温度 `25`、潮湿 `0`、移动 `4/6`，角色外观保留，角色专属标签/被动倍率/特殊回调/专属组件效果和 SkillTree 激活、经验、选择入口禁用。活动歌曲、非零 `battleborn`、高风险变身/模块/宠物/运输状态或其他已召唤实体存在时仍应明确拒绝，不得用空表继续。19 个角色的真实客户端逐一切换、场内公平字段和退出恢复仍需按下表实测，不能由服务端注册表结果替代。

1. 客户端 A、B 作为两个 Participant 进入同一个 TestMode，分别修改背包、Stats、技能树、角色资源和外观；销毁 Instance 或断线后重连，逐项确认原始状态恢复，记录恢复前后物品 prefab/count、Stats、技能节点、资源值和角色 prefab。
2. 客户端 A 进入 Spectator，确认它没有目标 Instance 的 Participant 或 PlayerSandbox transaction；只能看到白名单目标，不能执行 gameplay action；退出后回到 Lobby 的动态安全点。
3. 触发 GHOST 策略，确认死亡者仍属于原 Instance，只能在该 Zone 安全边界内移动；不能写入另一个 Instance。
4. 触发 REVIVABLE_CORPSE 策略，确认尸体不可移动，且只有同一 Instance 的合法活跃 Participant 可以救援；Ghost、Corpse 和 Spectator 不能互相冒充。
5. 观察 `agon_player_classified` 的 `instance_id`、`generation`、`audience`、`spectator` 和死亡状态在客户端 A/B 上是否一致；记录客户端 UI/StateGraph/相机异常。

## 8. 失败注入与重启矩阵

每一项失败都必须记录错误码、局部隔离结果、重试/管理终态和清理后的 Zone 状态。当前没有公开的正式故障注入 UI；如果需要临时控制台片段，必须把片段和结果一并放入日志，不得只记“已测”。

| 阶段 | 触发时机 | 重启后必须观察 |
| --- | --- | --- |
| PREPARING | `CreateInstance` 成功、`StartInstance` 之前 | Instance 不续跑；未污染其他 Zone；可复用槽位保持一致 |
| RUNNING | Instance 已进入 RUNNING 且有 Scene/Player transaction | `ABORT_ON_RESTART`；活动 Instance 中止；Scene/Zone 清理；玩家快照进入 pending 队列 |
| TRANSITION | Scene revision 或 phase 正在变更时 | 不接受旧 generation/revision；无半套 Scene；失败 Zone 隔离而非复用 |
| FINISHING | Finish 已开始但 Destroy 未完成 | 不重复结算；restore 快照仍可验证；重复清理幂等 |

每个阶段都执行：保存或停服、记录重启前日志位置、用同一 `Test/World01` 重启、执行 `agon.recovery`/`agon.instances`/`agon.zones`，重新加入客户端并验证恢复或安全拒绝。任何真正的玩家状态恢复都要保留客户端 A/B 的逐字段结果。

## 9. enable_agon=false 硬门

1. 停止 World01，保存本轮 true 状态的日志行号。
2. 只把 `World01/modoverrides.lua` 的 `enable_agon=true` 临时改为 `enable_agon=false`，保持 Mod 本身 `enabled=true`。
3. 用同一启动命令启动 World01。此状态不得执行 `agon.test.*`、不得手工创建 runtime，也不得为了让命令可用而改代码。
4. 检查从本次启动位置开始没有 `LAYOUT_READY`、`CORE_READY`、Agon manager/listener/task/Zone scan 或 BackendAdapter 请求；其他 shard/worldgen 行为不能被改变。
5. 停服后恢复 `enable_agon=true`，再次启动并完成第 2 节预检，确认硬门恢复后没有残留 false 状态。

## 10. 结果表与判定

每行使用 `PASS`、`FAIL` 或 `WAITING_MAINTAINER`，不得用“理论通过”。

| 项目 | 状态 | 时间/日志范围 | A/B | Instance/Zone/revision/seed | 备注 |
| --- | --- | --- | --- | --- | --- |
| 服务端预检 WP4–WP9 |  |  |  |  |  |
| Lobby/Portal/10 Zone/天数 |  |  |  |  |  |
| false 硬门 |  |  |  |  |  |
| Test/World01 真实玩家开关 |  |  |  |  |  |
| 双 Instance 隔离 |  |  |  |  |  |
| BLOCKING/LIVE_PATCH |  |  |  |  |  |
| EntityProfile/Replica/UI |  |  |  |  |  |
| PlayerSandbox 字段恢复 |  |  |  |  |  |
| Spectator/Camera/网络可见性 |  |  |  |  |  |
| GHOST/Corpse |  |  |  |  |  |
| 四阶段重启 |  |  |  |  |  |
| 故障注入/QUARANTINED 修复 |  |  |  |  |  |

WP10 只有在所有必需行都有真实运行证据、没有已知数据丢失路径，并且同一单 shard 范围内的安全行为全部通过时，才能判定 `Base Ready`。第二 shard、普通世界到 Agon shard 的迁移、真实 Backend transport 和生产 UI 仍需另行集成验收。

## 11. 当前明确阻塞

- 当前 TestMode 没有正式玩家 UI/匹配入口；`agon.test.create` 是无玩家的管理员诊断入口。
- `PlayerSandbox` 对真实玩家默认返回 `PLAYER_SANDBOX_LIVE_MUTATION_DISABLED`；已实现的测试开关只允许管理员在固定 Test/World01 指纹下、按当前进程临时开启，不改变正式默认安全边界。
- 当前环境只有 World01，不能声称第二 shard/cross-shard 已通过。
- 没有真实客户端结果以前，WP10 状态固定为 `WAITING_MAINTAINER`。
