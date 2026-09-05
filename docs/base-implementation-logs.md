# 《天地为炉（The Agon）》Base Implementation Logs（精简关键版）

> 本文件是跨任务、跨 AI Agent 的执行上下文摘要。维护者于 2026-09-05 明确要求压缩历史日志；此前重复的逐条控制台回显已合并，保留关键决策、根因、修复、验收证据和未完成边界。
>
> 权威路径固定为 `docs/base-implementation-logs.md`。旧文件名 `base-implemtation-logs.md` 已纠正，不要新建同义日志文件。

---

## 0. 长期规则与固定决策

- 工作仓库是 `D:\OneDrive\DST\the-agon` 的独立嵌套 Git 仓库；`D:\OneDrive\DST\scripts` 只读，只用于核对官方 DST API，不得修改。
- 每个任务开始前读取 `.codex/AGENTS.md`、`docs/base-design.md`、`docs/base-implementation-plan.md` 和本文件，并以当前 Git、官方源码和运行环境复核历史结论。
- 后续日志只追加“关键里程碑”：目标/决定、根因/修复、最小验证证据、未验证风险、环境/存档影响、Git 状态和建议 Commit。相同结果的轮询、重复命令回显和无新结论的等待不记录。维护者明确要求压缩时可以整理旧记录，但不得删除关键失败根因、修复、最终证据或延后决定。
- 静态检查、服务端运行、真实客户端、跨 shard 验证必须分开标注；未执行的验证不能写成通过。
- 不全局安装软件或包；没有可用 Lua parser 时不安装，只记录 DST 服务端加载结果。除非维护者明确要求，不执行 commit、push、分支切换、历史改写或清理用户数据。
- 发送给 DST 控制台的命令必须是一行；优先用已验证的 `c_announce((function() ... end)())` Runtime 表达式，不把 `agon.*` 文本直接送入 `RemoteCommandInput`。
- 不记录密码、Cluster Token 或其他秘密。测试允许操作的存档仅为 `Test/World01`；涉及玩家物品和存档时必须保留原状态并走正式恢复/清理流程。

### 已确认的产品/工程决策

- WorldLayout 必须以运行时唯一 `multiplayer_portal` 的实际 Tile 为坐标锚点，不能假设世界坐标 `(0,0)` 是 Portal。当前正式测试布局为 `400×400`，Portal-relative Portal Tile 为 `(200,200)`。
- Agon 世界只有大厅为陆地，其他区域为 `IMPASSABLE`；当前 Zone 池为 `SMALL×4`、`MEDIUM×4`、`LARGE×2`。
- 两条官方 set-piece angle 告警暂不处理，也不伪造定位实体：
  - `hermitcrab_relocation_manager` 找不到 `monkeyqueen/monkeyportal`；
  - `wagpunk_arena_manager` 找不到 `hermitcrab_marker/beebox_hermit`。
  它们不阻止地图生成、`LAYOUT_READY` 或 `CORE_READY`，属于已确认的兼容性告警。
- 官方源码可见裸 `assert`/`pcall`，但 Mod 环境不是完整 Lua 全局环境；`GLOBAL.assert` 只适合 Mod 入口的显式桥接。required core module 曾因 `GLOBAL` 未声明报错，因此核心模块使用实际可用的直接 `pcall`/`GetTime`，不机械依赖 `GLOBAL`。

---

## 1. 实现状态总览

| 范围 | 关键实现与状态 |
| --- | --- |
| WP0/WP1 | Mod 硬门、专用虚空世界、Portal-relative WorldLayout、大厅、10 个 Zone 配置和启动校验已完成。 |
| WP2 | Zone/Instance 生命周期、分配、稳定 ID、启动/销毁、`ABORT_ON_RESTART` 和核心 Debug/Validate 已完成并通过服务端及跨重启验证。 |
| WP3 | ResourceScope、EntityRegistry、SpawnService、ScenePlan、Terrain/Scene 事务、占用拒绝/安全移动和实例场景隔离已完成并通过双 Instance 服务端验证。 |
| WP4 | Participant、Instance 归属、InstanceRng、RulePolicy、Audience、classified、RPC 幂等和跨局交互拒绝已完成；真实跨 shard 仍未验证。 |
| WP5 | ParticipantGroup、Common Services 注册/生命周期和服务端诊断已完成。 |
| WP6 | EntityProfileRegistry/Service、Prefab/Profile 约束、子实体归属、显示状态和清理已完成。 |
| WP7 | PlayerSandbox、统一 Profile、Inventory/SurvivalStats/SkillTree/Character adapters、恢复事务和失败隔离已完成；真实 live-safe 角色当前只覆盖 `wilson`/`wathgrithr`。 |
| WP8 | Lobby、Spectator、FOLLOW、Echo、死亡策略和客户端观战输入边界已完成；真实双客户端已验证主要链路。 |
| WP9 | 纯数据 schema/migration、恢复队列、重启中止、Zone quarantine、RPC/Audience 快照收口和 BackendAdapter pending/幂等边界已完成。 |
| WP10 | 主要目标是集成验收和缺陷修复，不新增正式玩法架构；单 shard Test/World01 的主要安全链路已通过，完整 Base Release Gate 仍有下方未覆盖项。 |

### 主要代码边界

- Core：`zone.lua`、`zone_manager.lua`、`instance.lua`、`instance_manager.lua`、`participant.lua`、`participant_group.lua`、`instance_rng.lua`、`rule_policy.lua`、`entity_registry.lua`、`resource_scope.lua`。
- World：`layout_service.lua`、`lobby_service.lua`、`scene_plan.lua`、`scene_service.lua`、`terrain_service.lua`、`spawn_service.lua`。
- Player：`player_profile.lua`、`sandbox_service.lua`、`state_adapter_registry.lua`、Inventory/SurvivalStats/SkillTree/Character adapters、`spectator_service.lua`、`spectator_input.lua`、`spectator_hud.lua`、`spectator_inventory_guard.lua`、`death_policy.lua`。
- Persistence/Network/Backend：schema、migration、restore queue、RPC、classified、Audience channel、BackendAdapter。
- Prefab/入口：`modmain.lua`、`modworldgenmain.lua`、`agon_player_classified.lua`、`agon_spectator_echo.lua`、`agon_runtime`。

---

## 2. 关键问题、根因与修复

### 运行环境与底座

- **`GLOBAL` 未声明**：required module 误用 Mod 环境桥接；改为直接可用的官方函数和受保护调用。之后服务端可正常加载、创建和销毁 Instance。
- **Zone 状态未随 Instance 启动推进**：初版出现 `RUNNING + RESERVED`；补齐 `RESERVED → BUILDING → ACTIVE` 与失败 quarantine 顺序，实测改为 `RUNNING + ACTIVE`。
- **WP7 诊断基线被自身清理改写**：合成玩家原始状态与比较对象共用 table；改为深拷贝，恢复幂等诊断通过。

### 保存、恢复与清理

- **恢复必须保守**：活动 Instance 固定采用 `ABORT_ON_RESTART`，不续跑玩法；玩家快照先进入 `RESTORE_PENDING/RESTORE_BLOCKED`，验证成功前不删除或覆盖。
- **握手门**：真实玩家重连可能先报 `SKILLTREE_HANDSHAKE_REQUIRED`；官方 SkillTree 完成 `handshake_state=3` 后才允许恢复。曾出现 `SURVIVAL_STATS_RESTORE_MISMATCH`，原因是等待期间生存值自然漂移；受保护重试可按保存值恢复，不静默放行错误状态。
- **重复恢复用户/隔离 Zone**：恢复队列重复 userid 会进入 `QUARANTINED`，不能复用 Zone；修正恢复队列终态替换和 Zone 受控恢复入口后，孤立 Zone 可恢复为 `FREE`。
- **场景重置失败**：旧失败 Instance 中残留 `meat`、`turf_cave`、护符、背包和 `skeleton_player` 等实体导致 `ZONE_NOT_EMPTY`；清理逻辑改为区分真实玩家/尸体与普通非玩家占用，补齐受控清理和 orphan Zone recovery。失败不伪造成功，必要时保持 quarantine。
- **持久化非法数字**：早期探针曾记录 `PERSISTENCE_NON_SERIALIZABLE/PERSISTENCE_INVALID_NUMBER`；schema 现拒绝非法数值，后续最终回归 `errors=0`。旧诊断计数不能当作当前活动错误。

### SkillTree、角色与玩家沙箱

- 初始真实绑定因没有官方 live 角色快照安全来源返回 `CHARACTER_LIVE_STATE_UNSUPPORTED`；当前仅为 `wilson`/`wathgrithr` 接入官方可验证数据，并拒绝未注册角色、活动歌曲、非零 battleborn、跟随者/宠物/召唤实体等未知 live 状态。
- 官方 SkillTree 握手接线经过修正；真实 A/B 均已出现 `SKILLTREE_HANDSHAKE_COMPLETE` 且 `handshake_state=3`。
- 角色沙箱 Capture/Clean/Restore 不删除物品、不覆盖进入前快照；服务端故障时保留原引用并进入可重试状态。

### Lobby、Scene 与断线

- 两名恢复玩家共用大厅 point 曾导致 `HALL_TILE_MISMATCH`/占用冲突；Lobby 改为按占用登记和安全点选择，重连大厅 Tile 冲突已验证修复。
- 双 Instance 场景修改只影响所属 Instance；BLOCKING、空地 LIVE_PATCH、占用拒绝和占用移动均有服务端证据。
- 真实玩家断线后：A 被标记 `DISCONNECTED`、保留恢复事务；重连完成握手后出现 `PLAYER_RECONNECTED`，A/B 状态和 Sandbox transaction 正常复用，最终 Instance/Zone 清理通过。

### Spectator 硬隔离与客户端

- **FOLLOW 方案**：A 的真实玩家 Transform 由服务端周期同步到 B；A 的客户端只保留旋转/缩放相机输入，不切换全局 Camera target。A 的实体隐藏、禁用物理和控制器，并用标签、ActionPicker、Combat、Health、环境、交易、进食、Debuff、Inventory/Builder/Container 等边界阻断 gameplay。
- **物品绕过漏洞**：右键装备被阻断但鼠标拖拽仍可把魔光护符/懒人护符装备；已改为客户端隐藏禁用物品栏、装备栏、鼠标携带物品和制作栏，服务端统一拒绝装备/卸下/拖拽/丢弃/拾取/使用/制作，并将已装备物品效果中和。
- **Inventory wrapper 重入**：连续观战会让旧 wrapper 嵌套，造成真实物品无法清理；改为组件级持久包装和官方方法基线，恢复时不丢物品。
- **脱离 Inventory 的效果缺口**：物品清空后 `inventoryitem.owner` 可能为空，导致速度等效果仍读取原值；新增按快照 `runtime_ref` 登记的弱键运行时归属表，观战期间护符效果保持中性，退出后解除登记。
- **建造栏恢复**：隐藏流程把 `craftingshown=false` 且禁用了 `craftingmenu`，原恢复只恢复 Inventory；`spectator_hud.lua` 现恢复 `craftingshown`，调用官方 `ShowCrafting`/`ShowCraftingAndInventory`，并显式 `Enable`/`Show` 制作 widget。真实客户端已确认恢复。
- **Echo 坐标错误**：`agon_spectator_echo` 默认显示 Wilson 且带 `NOCLICK`，旧代码把它放到场地 spectator anchor，表现为场地内不可点击的 A/Wilson；现优先放到 A 的大厅 `lobby_return_position`。真实客户端已确认场地无额外 Wilson，残影只在大厅。

---

## 3. 关键验收结果

### 静态与服务端

- 官方 DST 版本/build：`747465` / Build `4239`；专服：`Test/World01`；游戏端口 `12000`；Master shard 端口 `11889`。
- `git diff --check` 历次均无 whitespace error，仅有 LF/CRLF 转换提示；PATH 没有 `lua`、`luac`、`stylua`，未全局安装解析器。
- 未修改官方 `D:\OneDrive\DST\scripts`。`enable_agon=false` 时没有 Agon Runtime、Layout、Zone、listener、task 或 Backend 副作用；恢复 true 后正常启动。
- 干净服务端多次输出 `LOADING LUA SUCCESS`、`LAYOUT_READY`、`RECOVERY_COMPLETE`、`CORE_READY`；主要回归结果均为 `WP4=true:nil` 至 `WP9=true:nil`、`ValidateCore=true:nil`。
- WP2 跨进程重启：活动 Instance 被中止、序号不回退、Zone 全部释放、旧 Instance 不恢复。
- WP9 跨进程重启：活动 Instance 不续跑；恢复快照进入 pending；Scene/Zone 清理或 quarantine 按结果处理；回滚测试快照后可回到 `instances=0/zones=10/restores=0/backend_pending=0`。

### 真实双客户端

- 多轮测试使用过不同临时 userid；最近一轮为 A=`KU_0vPtVpg3`（Wilson）、B=`KU_aUxMQjy7`（Wathgrithr）。两人均完成官方 SkillTree `handshake_state=3`。
- B-only Instance 创建、Attach、Start 成功；B 在场地内作为 Participant，A 在大厅进入 Spectator 并跟随 B。B 不会因 A 观战而变成大厅玩家。
- A 的真实位置实时跟随 B；A 可旋转/缩放相机，但不能移动、攻击、拾取、采集、制作、装备或触发动作动画。怪物不能将 A 作为目标，伤害/环境/交易/进食等入口被拒绝。
- A 的物品栏、装备栏和制作栏在观战期间隐藏且不可打开；退出后建造栏和物品 UI 恢复，原物品槽位、装备槽位、owner 和效果状态恢复。
- A 断线/重连后握手门和 Participant/Sandbox 状态可恢复；Instance 销毁、Zone 释放和 Core 校验通过。
- 双 Instance/Scene 测试确认实例内地形/实体修改不跨局；占用 Tile 返回 `OCCUPIED_TILE`，安全移动和独立销毁不影响另一局。
- 最新 Echo 修复实测：服务端 `echo_prefab=agon_spectator_echo`、`echo_pos=0,-12` 与 `lobby_pos=0,-12` 一致，而场地 anchor 为 `-620,248`；维护者确认场地无额外 A/Wilson。最终 `WP10_ECHO_FIX_FINAL:true:nil`，Instance `0`、Zone `10/10 FREE`、`errors=0`。

### 最新清理状态

- 最近一次正式测试清理结果：`WP10_ECHO_FIX_EXIT:true:nil`、`WP10_ECHO_FIX_INSTANCE_CLEANUP:true:INSTANCE_DESTROYED`、`WP10_ECHO_FIX_TEST_OFF:true:PLAYER_TEST_DISABLED`。
- 最近一次 Debug：`instances=0`、`zones=10`、`ValidateCore=true`、`errors=0`；`pending_restore_count=2`、`backend_pending_count=4` 属于 WP9 未配置 transport 的诊断记录，不是活动 Instance 或 Zone 泄漏。

---

## 4. 仍未完成或需要明确标注的边界

- 当前测试 Cluster 只有 `World01`：普通 shard ↔ Agon shard 的真实跨 shard 迁移、断线和迁移失败恢复尚未验证。
- 尚未完成完整 PREPARING/RUNNING/TRANSITION/FINISHING 四阶段真实玩家重启矩阵，以及所有故障注入下的真实客户端恢复清理。
- Backend transport 尚未配置；已验证 pending、不可变记录和幂等边界，未验证真实网络提交、重复奖励/结算联调。
- 尚未系统压测远距离网络实体可见性、camera bounds、多个 Instance 的网络/Task 数量和性能；StateGraph/完整动画覆盖也有限。
- 真实 live Character adapter 当前只支持 `wilson`/`wathgrithr` 的明确安全子集；其他角色必须先有官方快照和恢复契约。
- 两条官方 set-piece angle 告警仍按维护者决定只记录、不处理；不要为了消除日志伪造 `monkeyqueen`、`monkeyportal`、`hermitcrab_marker` 或 `beebox_hermit`。

---

## 5. 当前环境快照与后续记录格式

- 最新记录时间：2026-09-05。最近一次 Echo 修复测试在 `Test/World01` 完成；服务端最后保持运行时 `CORE_READY`、无活动 Instance、10 个 Zone FREE、live player test 已关闭。
- 代码修改优先查看当前 Git，不以历史日志中的旧 commit/status 代替现状。最近检查时 Echo 源码已在当前 `HEAD`，未提交变化主要是本日志、计划和设计文档。
- 建议提交信息示例：`fix(spectator): 将观战残影固定在大厅返回位置`；日志压缩建议：`docs(base): 精简跨 Agent 执行日志`。不代表已执行 commit。

以后每项任务只追加如下格式，控制在能表达关键事实的长度：

```markdown
### YYYY-MM-DD：任务/WP——结果

- 决策/范围：只写本轮关键目标和用户明确延后项。
- 根因/修改：写失败原因、修复方式和文件；没有修改也写明原因。
- 验证：分别写静态、服务端、真实客户端、跨 shard 的最小证据；重复结果不展开。
- 未验证/风险：只列会影响后续决策的边界。
- 环境/收尾：Cluster/World、版本、存档影响、Instance/Zone/进程状态、Git 状态和建议 Commit。
```

### 2026-09-05：维护者要求精简执行日志

- 已将原约 27 万字、2567 行的逐条执行记录整理为本关键摘要，保留长期约束、用户决策、WP 状态、重要失败根因与修复、最终验收和未完成边界。
- 已同步更新 `docs/base-design.md` 与 `docs/base-implementation-plan.md`：默认追加精简里程碑；维护者明确要求时允许压缩重复回显，但不得掩盖关键证据或风险。
- 本次仅整理文档，没有修改官方源码、玩家存档或测试配置；未执行 commit/push。

### 2026-09-05：WP10——跨重启物品恢复与活动实例校验复测

- 根因/修改：活动实例校验曾因 `EntityProfileService` 缺少 `service_id` 触发 `INSTANCE_INVARIANT_FAILED`；已补齐服务标识。Inventory 持久化修复保持快照中的 `prefab/save_record`，不写入运行时实体引用。
- 跨重启服务端证据：`Test/World01` 的实例 `agon:1:26` 按 `ABORT_ON_RESTART` 中止后，A=`KU_q87X36VY`、B=`KU_aUxMQjy7` 重连并完成官方 SkillTree `handshake_state=3`；两人的恢复队列均为 `RESTORED`、错误为 nil，B 实际恢复 `spear_wathgrithr`、`wathgrithrhat`、`spoiled_food`。
- 最终证据：`ValidateCore=true:nil`、`core=READY`、`instances=0`、10 个 Zone 全部 FREE；随后 `c_save()` 成功且没有新增持久化错误。本条补足此前未单独执行的真实跨重启存档恢复测试。
- 边界/收尾：仍有历史 `pending_restore_count=2` 和未配置 transport 的 `backend_pending_count=4`，不属于本次活动实例泄漏；当前服务器保持运行、两名客户端在线。跨 shard、真实 Backend transport 和完整重启矩阵仍未验证；当前 Git 工作区干净，建议 Commit：`fix(base): 修复活动实例校验与跨重启物品恢复`。

### 2026-09-05：WP10——死亡策略与四阶段重启矩阵补测

- GHOST：真实双客户端中 A=`KU_q87X36VY` 可在场地安全范围内活动，B=`KU_aUxMQjy7` 正常活动；服务端确认死亡记录和 `GHOST` 策略生效，复活及销毁后无 Instance/Zone 泄漏。真实 REVIVABLE_CORPSE 因当前 ENDLESS 测试世界的玩家没有 `revivablecorpse` 组件，仅保留 WP8 合成诊断通过，不冒充真实客户端通过。
- 重启矩阵：空 Instance 分别在 `PREPARING`（`agon:1:30`）、`TRANSITION`（`agon:1:31`）和 `FINISHING`（`agon:1:32`）保存并重启；每次均 `aborted_on_load=1`、活动 Instance 为 0、10 个 Zone 全部 `FREE`、`ValidateCore=true:nil`、无新增错误。RUNNING 阶段的真实双客户端跨重启恢复已由前条 `agon:1:26` 记录覆盖。
- 边界/收尾：本轮 TRANSITION/FINISHING 是无玩家的生命周期持久化边界测试，不等同于带真实 Scene/玩家的完整阶段矩阵；跨 shard、真实 Backend transport、完整故障注入和生产 UI 仍未验证。当前 `Test/World01` 服务端保持 `CORE_READY`，没有活动 Instance；重启使远端客户端断开，未确认其重新加入。

### 2026-09-05：WP10——真实玩家 TRANSITION/FINISHING 重启恢复

- `agon:1:33` 由 A=`KU_q87X36VY`、B=`KU_aUxMQjy7` 真实接入并进入 `TRANSITION`；重启后两人均完成官方 `handshake_state=3`，恢复队列正常回收，Instance 按 `ABORT_ON_RESTART` 中止且 Zone 释放。
- `agon:1:34` 由同一 A/B 真实接入并进入 `FINISHING`；重启后两人均完成握手和恢复，最终确认 `instances=0`、10 个 Zone 全部 `FREE`、`ValidateCore=true:nil`、无新增错误。
- 边界/收尾：这两项补足了带真实玩家的 TRANSITION/FINISHING 重启证据；仍未覆盖第二 shard、真实 Backend transport、生产 UI 和完整故障注入矩阵。当前 `Test/World01` 服务端保持 `CORE_READY`、无活动 Instance；本轮重启后 A/B 已恢复在线，live player test 按重启策略为关闭。
