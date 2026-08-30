# 《天地为炉（The Agon）》Base Implementation Plan

> **用途**：把 `docs/base-design.md` 转换为可直接交付给其他 AI Agent 执行的工程计划。
>
> **目标读者**：项目维护者，以及负责单个实施阶段的 AI Agent（例如 GPT-5.6 Luna Max）。
>
> **当前仓库状态**：撰写本计划时，仓库只有设计文档，没有 Mod 代码；因此按绿地项目实施。
>
> **权威设计**：`docs/base-design.md`。本文件负责实施顺序和验收，不得改变其中已确认的产品边界。

---

## 1. 如何使用本计划

本计划不是要求一个 Agent 一次完成整个 Base。每次只执行一个 Work Package（WP），完成验证和交付报告后再进入下一项。

优先级：

```text
用户当前明确指令
→ D:\OneDrive\DST\.codex\AGENTS.md
→ docs/base-design.md
→ docs/base-implementation-plan.md
→ 当前 Work Package 内的实现细节
```

如果实现过程中发现本计划与 `base-design.md` 冲突：

1. 停止扩大修改；
2. 保留已完成且不冲突的最小改动；
3. 报告冲突位置、影响和建议；
4. 不得自行改变核心设计以“让代码跑起来”。

### 1.1 每个 Agent 开始前必须执行

1. 阅读 `D:\OneDrive\DST\.codex\AGENTS.md`。
2. 阅读 `docs/base-design.md` 与本文件中当前 WP 的全部内容。
3. 在 `D:\OneDrive\DST\the-agon` 内执行 `git status --short`。
4. 识别用户已有的未提交和未跟踪文件；不得覆盖、删除或纳入无关修改。
5. 用 `rg` 检查当前仓库是否已经存在本 WP 的部分实现，不得假设仍是绿地状态。
6. 涉及 DST API、Prefab、Component、Brain、StateGraph、RPC、网络、世界生成和保存时，先查 `D:\OneDrive\DST\scripts` 官方源码。
7. 在修改前写出本次的：目标、涉及文件、验证方法和仍缺少的输入。

### 1.2 每个 Agent 完成后必须报告

- 实现了什么；
- 修改或新增了哪些文件；
- 查阅了哪些官方源码及其用途；
- 执行了哪些静态和运行时验证；
- 哪些行为尚未验证，以及原因；
- 当前 `git status --short`；
- 一条中文 Conventional Commit 信息；
- 下一 WP 是否满足进入条件。

除非用户明确要求，不执行 `git commit`、`git push`、分支切换、历史修改或清理用户文件。

### 1.3 通用停止条件

出现以下任一情况，Agent 必须停止当前危险路径并向用户说明，而不是猜测：

- 正式 WorldLayout 坐标或地图大小尚未提供；
- 官方源码中找不到计划依赖的 API，或实际签名与设计假设不一致；
- 需要修改 `D:\OneDrive\DST\scripts`；
- 需要全局安装软件或依赖；
- 需要无条件修改全局 `TUNING`、Prefab、Brain 或 StateGraph；
- 需要绕过 PlayerSandbox 才能继续；
- 需要删除或覆盖未知来源的未提交修改；
- 需要把某个 Mode 的具体玩法规则写入 Core；
- 动态 Tile、网络 Replica 或技能树恢复没有可靠验证方法，却准备宣称已完成。

---

## 2. 总体交付策略

Base 采用三个层级：

```text
Core
├── Shard gate、WorldLayout、Zone、Instance
├── Participant、ParticipantGroup
├── HierarchicalResourceScope、EntityRegistry
├── SceneService、SpawnService、InstanceRng
├── Isolation、AudienceStateChannel
├── PlayerSandbox、Spectator、DeathPolicy
└── Persistence、Diagnostics

Common Services（Mode 按需启用）
├── PhaseService
├── ClockService
├── DecisionService
├── EffectService
├── EntityProfileService
└── ScoreLedger

GameMode Plugins
├── test_mode
├── feast
├── arena
├── pvp
└── fishing
```

实施原则：

- Core 负责归属、安全、权限、事务和清理。
- Common Services 提供完整可复用机制，不定义玩法语义。
- Mode 只提供规则、配置、handler、Profile、ScenePlan 和展示数据。
- `test_mode` 从最早阶段开始存在，贯穿全部 WP；它是 Base 验收载体，不是正式玩法。
- 每个 WP 都必须有可观察结果，不能只创建一批没有调用路径的抽象类。

### 2.1 里程碑

| 里程碑 | 覆盖 WP | 可验证结果 |
| --- | --- | --- |
| M0：可加载骨架 | WP0 | Mod 能加载；关闭开关时零业务副作用 |
| M1：专用世界 | WP1 | 只生成大厅和 Portal，其余为虚空；Layout 校验有效 |
| M2：空 Instance | WP2 | TestMode 能创建、租用和销毁空 Zone |
| M3：场景垂直切片 | WP3 | 两个 Test Instance 独立构建、Patch、清空场地 |
| M4：隔离与通用服务 | WP4–WP5 | Group、阶段、投票、Effect、Score 和 audience 不串局 |
| M5：实体定制 | WP6 | 同名怪物/物品在不同 Instance 使用不同 Profile |
| M6：玩家闭环 | WP7–WP8 | 玩家安全进入、死亡/观战、恢复并回大厅 |
| M7：异常闭环 | WP9 | 重启中止、恢复队列、幂等结算和网络权限有效 |
| M8：Base Release Gate | WP10 | 全部跨系统验收通过，可以开始正式 Mode |

依赖关系：

```text
WP0
└── WP1
    └── WP2
        └── WP3
            └── WP4
                ├── WP5 ──→ WP6 ──┐
                └── WP7 ──→ WP8 ──┴──→ WP9 ──→ WP10
```

WP5/WP6 与 WP7/WP8 在 WP4 稳定后可以分支开发；WP9 必须等待 WP6 和 WP8 都完成，合并验证仍按 WP10 的完整顺序执行。

---

## 3. 实施前仍需用户提供的输入

以下值不能从设计文档中安全推断。Agent 可以先实现 schema、验证器和开发占位接口，但不得把结构示例当生产值。

### G1：正式 WorldLayout

必须由用户确认：

- 世界 Tile 尺寸；
- `lobby.center`；
- 大厅 bounds、terrain layout、spawn points、return points；
- Portal 使用 `multiplayer_portal` 还是 `multiplayer_portal_moonrock`；
- 每个 Zone 的 `zone_id`、`zone_category`、center、bounds、safe bounds；
- Participant spawn points；
- spectator anchors 和 camera bounds；
- Zone 之间、Zone 与 Lobby 之间的最小安全距离；
- 是否在正式 Layout 中保留两个仅管理员可用的 `TEST` Zone。

在 G1 未完成前：

- 可以完成配置类型、边界验证、坐标转换和错误报告；
- 可以使用明确标注为 `DEV_ONLY` 的测试 Layout 做本地验证；
- 不得把 DEV Layout 宣称为最终世界配置；
- 不得把 `base-design.md` 中的 `x = 1000` 当作正式坐标。

### G2：运行时测试环境

进入首次专服验证前，需要知道：

- DST Dedicated Server 的启动方式；
- 测试 Cluster 和目标 shard；
- Mod 如何挂载到该测试环境；
- 服务端、客户端和崩溃日志位置；
- 是否允许使用测试存档重建世界；
- 至少两个客户端如何加入并执行并发测试。

没有 G2 时，Agent 只能声明静态验证完成。

---

## 4. 全局工程契约

### 4.1 Shard 与加载边界

- `modinfo.lua` 公开配置只保留 `enable_agon = true/false`。
- 所有 shard 的 Mod 都是 enabled；由各 shard 的 `modoverrides.lua` 单独决定 `enable_agon`。
- 客户端需要的 Prefab、classified、RPC 名称和 Replica 声明无条件注册。
- 只有 server runtime bootstrap 经过 `enable_agon` 与 `world.ismastersim` 硬门。
- `enable_agon = false` 时不得存在 manager、world listener、periodic task、Zone scan 或后端请求。
- 不用 shard 名称、master/secondary 身份推测 Agon 角色。

### 4.2 ID、generation 与 revision

统一使用不可变稳定 ID：

```text
instance_id       agon:<shard_id>:<persistent_sequence>
scope_id          <instance_id>:scope:<sequence>
group_id          <instance_id>:group:<sequence>
decision_id       Mode 提供业务键，Instance 内唯一
transaction_id    对应 Scene/Sandbox/Settlement 的唯一事务键
event_id          ScoreLedger 幂等键
```

- GUID 只用于当前运行时引用，不能作为保存后的业务 ID。
- 异步回调必须携带 Instance generation 与 Scope generation。
- Phase 回调还要校验 phase revision。
- ScenePlan 必须声明 expected scene revision。
- 旧 generation/revision 的回调和 RPC 只能被拒绝，不能“尽量继续”。

### 4.3 错误模型

公共接口不得依赖随意字符串和静默 `nil`。实现阶段应建立集中错误码，例如：

```text
AGON_DISABLED
INVALID_MODE
UNKNOWN_SERVICE
SERVICE_DEPENDENCY_MISSING
NO_FREE_ZONE
ZONE_CATEGORY_MISMATCH
STALE_GENERATION
STALE_SCENE_REVISION
OUT_OF_ZONE_BOUNDS
SCOPE_CLOSED
CROSS_INSTANCE_DENIED
PROFILE_NOT_ALLOWED
RESTORE_PENDING
RESTORE_BLOCKED
```

错误至少记录：`shard_id`、`instance_id`、`zone_id`、`mode_id`、`userid`、lifecycle、operation 和 error code。

### 4.4 Lua 与模块约束

- 遵循 DST Lua 版本和官方代码可用语法；不要假设现代 Lua 特性存在。
- 不引入第三方依赖来完成基础表、ID、状态机或序列化。
- Module 不在 require 时产生世界副作用。
- Server-only module 不应被客户端执行服务端逻辑。
- 不保存 function、task handle、entity reference 或 Brain object。
- Mode 不直接访问 manager 内部表；只拿到 facade。
- Mode 不直接调用 `change_tile()` 或裸 `SpawnPrefab()`。
- Mode 不无条件修改 `TUNING` 或所有同名 Prefab。

### 4.5 保存策略

第一版固定为 `ABORT_ON_RESTART`：

- 保存足以清理和恢复的数据；
- 不尝试恢复进行中的玩法；
- 不保存 Lua task handle；保存 semantic deadline；
- 每种 Core/Common/Mode 数据带 schema/version；
- 原 PlayerSandbox snapshot 在恢复验证成功前永不删除；
- settlement 和 score event 使用幂等 ID。

### 4.6 Debug 是交付内容

至少逐步实现：

```text
agon.status
agon.instances
agon.instance <id>
agon.zones
agon.zone <id>
agon.groups <instance_id>
agon.scopes <instance_id>
agon.scene <instance_id>
agon.services <instance_id>
agon.decisions <instance_id>
agon.effects <instance_id>
agon.score <instance_id>
agon.player <userid>
agon.entity <GUID>
agon.validate_instance <id>
agon.validate_zone <id>
agon.destroy_instance <id>
agon.cleanup_zone <id>
agon.restore.inspect <userid>
agon.restore.retry <userid>
agon.restore.export <userid>
```

Debug 命令必须 server-only、管理员可用、参数校验完整，并调用正式公共 pipeline；不得建立绕过生命周期的“快捷修复”。

---

## 5. 目标文件结构

每个 WP 只创建当前需要的文件；不要一次生成全部空文件。

```text
the-agon/
├── modinfo.lua
├── modmain.lua
├── modworldgenmain.lua
├── scripts/
│   ├── components/
│   │   ├── agon_runtime.lua
│   │   └── agon_instance_member.lua
│   ├── agon/
│   │   ├── bootstrap.lua
│   │   ├── config/
│   │   │   └── world_layout.lua
│   │   ├── core/
│   │   │   ├── instance.lua
│   │   │   ├── instance_manager.lua
│   │   │   ├── zone.lua
│   │   │   ├── zone_manager.lua
│   │   │   ├── participant.lua
│   │   │   ├── participant_group.lua
│   │   │   ├── entity_registry.lua
│   │   │   ├── resource_scope.lua
│   │   │   ├── instance_rng.lua
│   │   │   └── rule_policy.lua
│   │   ├── world/
│   │   │   ├── layout_service.lua
│   │   │   ├── lobby_service.lua
│   │   │   ├── scene_service.lua
│   │   │   ├── scene_plan.lua
│   │   │   ├── spawn_service.lua
│   │   │   └── terrain_service.lua
│   │   ├── player/
│   │   │   ├── sandbox_service.lua
│   │   │   ├── player_profile.lua
│   │   │   ├── state_adapter_registry.lua
│   │   │   ├── spectator_service.lua
│   │   │   ├── death_policy.lua
│   │   │   └── adapters/
│   │   ├── services/
│   │   │   ├── common_service_registry.lua
│   │   │   ├── phase_service.lua
│   │   │   ├── clock_service.lua
│   │   │   ├── decision_service.lua
│   │   │   ├── effect_service.lua
│   │   │   ├── entity_profile_service.lua
│   │   │   ├── entity_profile_registry.lua
│   │   │   └── score_ledger.lua
│   │   ├── modes/
│   │   │   ├── mode_registry.lua
│   │   │   └── test_mode/
│   │   ├── net/
│   │   │   ├── rpc.lua
│   │   │   ├── audience_state_channel.lua
│   │   │   └── classified.lua
│   │   ├── persistence/
│   │   │   ├── schema.lua
│   │   │   └── migrations.lua
│   │   ├── backend/
│   │   │   └── backend_adapter.lua
│   │   └── debug/
│   │       └── diagnostics.lua
│   └── prefabs/
│       ├── agon_player_classified.lua
│       └── agon_spectator_echo.lua
└── docs/
    ├── base-design.md
    └── base-implementation-plan.md
```

---

## 6. `test_mode` 总体规格

### 6.1 目的

`test_mode` 用于证明 Base 通用能力，不提供正式奖励、匹配入口或后端排名。它必须能在没有 FEAST 代码的情况下独立验证：

- Mode 注册和 service opt-in；
- Zone category 分配；
- 双 Instance 并发；
- ScenePlan、`BLOCKING`、`LIVE_PATCH`；
- Scope 创建、转移和关闭；
- ParticipantGroup；
- Phase、Clock、Decision、Effect、Score；
- EntityProfile 与 child ownership；
- PlayerSandbox；
- Spectator 与 DeathPolicy；
- destroy、restart abort 和 restore。

### 6.2 目录

按实现进度逐步增加：

```text
scripts/agon/modes/test_mode/
├── definition.lua
├── runtime.lua
├── config.lua
├── scene_plans.lua
├── profiles.lua
├── effects.lua
├── decisions.lua
└── client.lua
```

不要创建没有使用者的空模块。

### 6.3 最终注册契约

```lua
ModeRegistry:Register({
    mode_id = "TEST_MODE",
    mode_version = 1,
    zone_category = "TEST",
    services = {
        "phase",
        "clock",
        "decision",
        "effects",
        "entity_profiles",
        "score",
    },
    CreateRuntime = function(instance, services)
        return TestModeRuntime(instance, services)
    end,
})
```

早期 WP 可以只声明已经实现的服务；注册表必须拒绝未知服务，不能静默忽略。

### 6.4 最终测试流程

```text
Create Instance
→ Initial ScenePlan 构建简单陆地与出生点
→ 创建一个 ParticipantGroup
→ Phase 1 ACTIVE
→ 记录测试 ScoreEvent
→ 发起 GROUP_VOTE
→ 票数最高者胜；平票使用 decision RNG stream
→ BLOCKING ScenePlan 改变部分地皮与实体布局
→ Phase 2 ACTIVE
→ LIVE_PATCH 测试空区域
→ LIVE_PATCH 测试 occupied Tile 的 REJECT/MOVE 策略
→ 生成带 EntityProfile 的怪物和物品
→ 应用并撤销一个测试 Effect
→ 触发选定 DeathPolicy
→ FINISHING
→ 玩家恢复并回大厅
→ Zone 全部清回 IMPASSABLE
→ Validate and FREE
```

### 6.5 TestMode 不得做的事

- 不直接访问其他 Mode；
- 不直接写 manager 私有状态；
- 不直接调用 `TheWorld.Map:SetTile()`；
- 不直接调用裸 `SpawnPrefab()`；
- 不修改全局 `TUNING`；
- 不包含 FEAST 料理、角斗场战斗或钓鱼比赛规则；
- 不为测试通过而跳过 ownership、Scope、RPC 或 restore 校验；
- 不在非 Agon shard 启动。

### 6.6 管理入口

第一版不做正式 UI。通过 server admin Debug API 驱动：

```text
agon.test.create <userid...>
agon.test.start <instance_id>
agon.test.blocking_patch <instance_id>
agon.test.live_patch <instance_id> <scenario>
agon.test.vote <instance_id> <userid> <option_id>
agon.test.spawn_profile <instance_id> <profile_id>
agon.test.finish <instance_id>
agon.test.fail <instance_id> <reason>
```

命令名是设计目标；实现前需按 DST Console/remote command 能力选择安全入口并查官方源码，不得照抄成未经验证的全局函数。

---

## 7. Work Packages

## WP0：Mod 骨架、配置硬门与静态验证

### 目标

创建最小可加载 Mod，证明共享声明和 server runtime gate 分离正确。

### 预计文件

```text
modinfo.lua
modmain.lua
modworldgenmain.lua
scripts/agon/bootstrap.lua
scripts/components/agon_runtime.lua
scripts/agon/debug/diagnostics.lua
```

### 实施步骤

1. 创建 DST-compatible `modinfo.lua`，只暴露布尔 `enable_agon`。
2. 在 `modmain.lua` 预留无条件客户端/共享注册区，不在文件顶部因开关提前 return。
3. 使用 `AddSimPostInit`、`AddPrefabPostInit("world", ...)` 或其他实际合适入口前，先查官方 `modutil.lua` 和现有 Mod 用法；选择能保证 world entity 已存在且 server/client 边界明确的方案。
4. `bootstrap.lua` 提供幂等 `StartServerRuntime(world)`。
5. `enable_agon = false` 或非 mastersim 时不添加 runtime component。
6. `agon_runtime` 第一版只保存 schema、shard ID、boot generation 和 diagnostics；不提前创建尚未实现的 manager。
7. 建立统一日志前缀和错误码模块的最小位置；不要过早实现复杂 logger。

### 官方源码核对

- `D:\OneDrive\DST\scripts\modutil.lua`
- `D:\OneDrive\DST\scripts\prefabs\world.lua`
- `D:\OneDrive\DST\scripts\prefabs\world_network.lua`
- 本工作区其他 Mod 的 `modmain.lua` 只能作为实现参考，不作为产品需求来源。

### 验收

- `modinfo.lua` 配置结构能被 DST 识别。
- 关闭配置时，没有 `agon_runtime`、listener、periodic task 或 manager。
- 开启配置且 mastersim 时，runtime 只初始化一次。
- 客户端加载路径不执行 server-only 逻辑。
- 重复 bootstrap 返回稳定结果。
- Lua 语法检查可用时通过；否则明确未验证。
- `git diff --check` 通过。

### 完成定义

只达到“能安全加载”，不宣称世界生成或玩法可用。

### 建议 Commit

```text
feat(base): 建立模组骨架与世界运行时硬门
```

---

## WP1：WorldLayout、专用世界生成与 Portal 校验

### 前置

- WP0 完成。
- 正式运行验收需要 G1、G2；缺少时只能使用明确的 DEV Layout。

### 目标

世界首次生成时只创建大厅陆地与唯一 Portal，其余区域保持 `WORLD_TILES.IMPASSABLE`；Zone 只存在于配置中。

### 预计文件

```text
modworldgenmain.lua
scripts/agon/config/world_layout.lua
scripts/agon/world/layout_service.lua
scripts/agon/world/lobby_service.lua
scripts/components/agon_runtime.lua
```

### 实施步骤

1. 定义可序列化 `WorldLayoutDefinition` 和 `layout_version`。
2. 实现启动前静态验证：坐标、bounds 包含关系、Zone 不重叠、安全间距、spawn/anchor 在合法区域、zone_id 唯一。
3. 查询 `lavaarena`、`quagmire` 地图任务及官方 layout API，确定生成纯虚空地图和放置 Portal 的可行路径。
4. `modworldgenmain.lua` 使用同一个 `enable_agon` 开关；关闭时不改变其他 shard worldgen。
5. 首次生成大厅 Tile 和 Portal，不生成 Zone 地面或玩法实体。
6. world runtime 启动后查找 Portal，校验 Prefab、唯一性和与 `lobby.center` 的误差。
7. Portal 校验失败时停止 Agon runtime；不能自动选另一个 Portal 或修改配置中心。
8. OnSave/OnLoad 保存 layout version，避免重启重复生成。

### 官方源码核对

- `scripts/map/tasks/lavaarena.lua`
- `scripts/map/tasks/quagmire.lua`
- `scripts/prefabs/multiplayer_portal.lua`
- `scripts/map/` 下实际使用的 static layout 和任务 API
- `scripts/modutil.lua` 的 worldgen Mod API

### 验收

- `enable_agon = false` 的 shard 地图生成不受影响。
- Agon shard 只有大厅为陆地，其余均为 IMPASSABLE，不是海洋。
- Portal 唯一且坐标与配置一致。
- 所有 Zone bounds 落在有效地图范围且初始无地面。
- 保存/重启不重复放置 Portal 或大厅对象。
- 错误 Layout 会在启动前给出可定位错误。

### 完成定义

需要截图、Tile 检查或服务端日志证明实际地图结果；只有静态检查时必须注明未完成运行验收。

### 建议 Commit

```text
feat(world): 实现专用虚空世界与大厅布局校验
```

---

## WP2：Zone、Instance、ModeRegistry 与空 TestMode

### 目标

实现不含玩家沙箱和场景地面的最小 Instance 生命周期。

### 预计文件

```text
scripts/agon/core/zone.lua
scripts/agon/core/zone_manager.lua
scripts/agon/core/instance.lua
scripts/agon/core/instance_manager.lua
scripts/agon/modes/mode_registry.lua
scripts/agon/modes/test_mode/definition.lua
scripts/agon/modes/test_mode/runtime.lua
scripts/components/agon_runtime.lua
scripts/agon/debug/diagnostics.lua
```

### 实施步骤

1. 实现 Zone 状态机：`FREE → RESERVED → BUILDING → ACTIVE → RESETTING → FREE`，失败进入 `QUARANTINED`。
2. ZoneManager 只按相同 `zone_category` 分配 FREE Zone。
3. 实现保存递增序列和稳定 `instance_id`。
4. 实现 Instance 主生命周期及合法转移表。
5. ModeRegistry 校验 `mode_id`、version、zone category、services 和工厂函数；禁止重复 mode_id。
6. 建立最小 TestMode，仅请求 `TEST` Zone，不启用 Common Services。
7. 创建/销毁任一步失败都回滚 reservation。
8. 增加 `agon.instances`、`agon.zones`、`agon.destroy_instance` 的最小诊断能力。

### 验收

- 两次创建得到不同且稳定的 instance_id。
- 同一 Zone 不会同时分配给两局。
- category 不匹配时返回明确错误。
- 无可用 Zone 时返回 `NO_FREE_ZONE`，不破坏已有 Instance。
- 非法生命周期转移被拒绝。
- Destroy 重复调用幂等。
- 一个 Instance 失败不影响另一个。

### 完成定义

TestMode 只能创建空 Instance；尚未构建 Tile，不得假装场景功能完成。

### 建议 Commit

```text
feat(instance): 实现区域分配与基础实例生命周期
```

---

## WP3：ResourceScope、EntityRegistry、SpawnService 与 SceneService

### 目标

完成第一个真正的垂直切片：TestMode 能安全构建、动态修改和清空场地，并支持双 Instance 并发。

### 预计文件

```text
scripts/agon/core/resource_scope.lua
scripts/agon/core/entity_registry.lua
scripts/agon/world/scene_plan.lua
scripts/agon/world/scene_service.lua
scripts/agon/world/terrain_service.lua
scripts/agon/world/spawn_service.lua
scripts/components/agon_instance_member.lua
scripts/agon/modes/test_mode/scene_plans.lua
scripts/agon/modes/test_mode/runtime.lua
scripts/agon/debug/diagnostics.lua
```

### 实施步骤

1. 实现 Instance root scope、子 Scope、generation 和关闭状态。
2. Scope 包装 `DoTaskInTime`、`DoPeriodicTask`、`ListenForEvent`、entity 和 cleanup registration。
3. 实现 `DESTROY`、`RETAIN_IN_PARENT_SCOPE`、`TRANSFER_TO_SCOPE`、注册式 `MODE_RESOLVE`；默认未处理资源销毁。
4. EntityRegistry 保存 Instance、Scope、category、generation、profile、parent 和 spawn source。
5. 实现 SpawnService；Mode 不得调用裸 `SpawnPrefab()`。
6. SpawnService 在 Prefab constructor 前压入 spawn context，并用受保护调用保证异常后弹出；同步 child entity 继承 Instance/Scope。
7. 实现 ScenePlan schema 和严格 validation。
8. TerrainService 封装 `GetTileCoordsAtPoint`、`GetTileAtPoint`、`SetTile`、world/minimap rebuild；唯一内部 `change_tile()` 位于此处。
9. SceneTransaction 记录修改前后 Tile、scope、scene revision、execution mode 和 rollback state。
10. 实现 `BLOCKING`：只冻结目标 Instance，应用、验证、commit 或 rollback。
11. 实现 `LIVE_PATCH`：限定 affected bounds，支持 `REJECT_IF_OCCUPIED` 与 `MOVE_TO_SAFE_POINT`；`MODE_RESOLVE` 只预留注册接口，不写玩法规则。
12. TestMode 提供 initial plan、blocking patch、live empty patch、live occupied reject、live occupied move。
13. Destroy pipeline 关闭 Scope、删除实体、把整个 Zone 清回 IMPASSABLE、验证后 FREE；失败则 QUARANTINED。

### 官方源码核对

- 地图 Tile 与 minimap rebuild 的官方调用点；
- `SpawnPrefab`、entity lifecycle 和 `OnRemoveEntity`；
- `TheSim:FindEntities` 的范围和 tag 用法；
- 寻路、Physics、平台和 Tile 改变相关调用。

### 验收

#### 单 Instance

- 从纯虚空构建 TestMode 初始陆地。
- 过期 scene revision 被拒绝。
- BLOCKING 期间该局输入被冻结，其他局不受影响。
- LIVE_PATCH 不修改 affected bounds 外 Tile。
- occupied Tile 的 REJECT 不产生部分修改。
- MOVE 后玩家/实体位于合法 safe point。
- 构建中注入异常可回滚；无法确认干净时 Zone 进入 QUARANTINED。

#### 双 Instance

- A、B 同时使用不同 Zone。
- A Patch 不改变 B Tile、entity、task 或 scene revision。
- 销毁 A 后 B 继续运行。
- A 清回虚空后可再次分配。

#### Scope

- 旧 generation task 不执行。
- Scope 关闭后不再接受资源。
- Transfer 不能跨 Instance。
- Root scope 关闭后无 managed task/listener/entity 残留。

### 完成定义

这是进入 Common Services 前的硬门。没有双 Instance 和动态 Tile 运行证据，不进入 WP4。

### 建议 Commit

```text
feat(scene): 实现场景事务与实例资源作用域
```

---

## WP4：隔离、Participant、InstanceRng 与 AudienceStateChannel

### 目标

建立所有后续玩法共享的归属、交互和网络可见性边界。

### 预计文件

```text
scripts/agon/core/participant.lua
scripts/agon/core/rule_policy.lua
scripts/agon/core/instance_rng.lua
scripts/agon/net/audience_state_channel.lua
scripts/agon/net/classified.lua
scripts/agon/net/rpc.lua
scripts/prefabs/agon_player_classified.lua
scripts/components/agon_instance_member.lua
```

### 实施步骤

1. 建立 `userid → active instance_id` 索引；一个 userid 最多属于一局。
2. 实现 `ResolveInstance(player/entity)` 和 `ResolveRootOwner(entity)`。
3. 传播 projectile、weapon、drop、minion、trap、container item 的 membership。
4. 默认拒绝跨 Instance 伤害、治疗、拾取、容器、目标选择和投射物。
5. Lobby entity 与 Instance entity 默认隔离。
6. 建立确定性 InstanceRng 和命名 stream；禁止 Mode 直接用共享随机流处理需要复现的业务。
7. AudienceStateChannel 实现 PRIVATE、GROUP、INSTANCE、SPECTATOR、PUBLIC audience；本 WP 可先实现 PRIVATE/INSTANCE，GROUP 在 WP5 接入。
8. RPC 统一验证 sender、Instance、lifecycle、generation、scene revision、ownership、request ID 和速率。

### 验收

- 同一玩家不能加入两个 Instance。
- 两个相邻 Zone 也不能跨局攻击、拾取或访问容器。
- projectile/drop 正确继承 root owner Instance。
- 无归属实体默认不能被 Mode 控制。
- 同 seed 同 stream 可复现；不同 stream 不互相消耗。
- PRIVATE 状态不会发给其他玩家，INSTANCE 状态不会发给其他 Instance。
- 重复 request ID 不产生第二次副作用。

### 建议 Commit

```text
feat(isolation): 增加实例归属隔离与定向状态同步
```

---

## WP5：ParticipantGroup 与 Common Services

### 目标

提供按需启用、可独立清理的通用玩法机制，不写任何 FEAST 专属语义。

### 预计文件

```text
scripts/agon/core/participant_group.lua
scripts/agon/services/common_service_registry.lua
scripts/agon/services/phase_service.lua
scripts/agon/services/clock_service.lua
scripts/agon/services/decision_service.lua
scripts/agon/services/effect_service.lua
scripts/agon/services/score_ledger.lua
scripts/agon/modes/test_mode/decisions.lua
scripts/agon/modes/test_mode/effects.lua
scripts/agon/modes/test_mode/runtime.lua
```

### 实施步骤

1. ParticipantGroup 支持 Instance 内多组和多 group type；禁止跨 Instance member。
2. CommonServiceRegistry 校验稳定名称、version、依赖、重复 handler 和 Mode 声明。
3. 未启用服务不创建状态、task、listener、RPC 或保存数据。
4. PhaseService 实现 revision、PhaseScope 和状态机。
5. ClockService 保存 semantic deadline；只暂停目标 Instance/Phase 的业务时钟。
6. DecisionService 支持 PRIVATE、GROUP_VOTE、GROUP_LEADER、INSTANCE_VOTE、SERVER_AUTO。
7. 实现 `ABSTAIN`、eligible voters、可配置是否改票、deadline、结果冻结和幂等 resolve。
8. 实现 `PLURALITY_RANDOM_TIE`：最高票获胜；并列从最高票项使用 `decision` RNG stream 选择；全员弃权时从全部候选选择。
9. EffectService 只管理 source、target、scope、handler、priority、stack policy、apply/remove；测试 handler 可以只操作 TestMode 私有计数，不定义攻击或料理属性。
10. ScoreLedger 使用唯一 event_id，按 Participant/Group/Instance 汇总；冻结后拒绝新增。
11. TestMode 创建一个 COOP_TEST Group，运行两阶段、一次 Group 投票、一次 Effect 和多条 ScoreEvent。

### 验收

- 两局 Phase、Clock、Decision、Effect、Score 状态完全隔离。
- 关闭 PhaseScope 会取消本阶段 Decision、Effect、task 和 listener。
- 世界天数和另一 Instance Clock 不受暂停影响。
- 非 eligible voter、过期 revision 和重复 vote request 被拒绝。
- 平票随机可由 seed 重现，且不改变 loot/scene stream。
- 重复 score event 不重复加分。
- Mode 声明未知服务或漏依赖时注册失败。

### 建议 Commit

```text
feat(services): 实现分组与可选通用玩法服务
```

---

## WP6：EntityProfileService

### 目标

允许不同 Instance 对原版怪物、Boss 和物品应用不同模式 Profile，而不污染全局 Prefab。

### 预计文件

```text
scripts/agon/services/entity_profile_registry.lua
scripts/agon/services/entity_profile_service.lua
scripts/agon/modes/test_mode/profiles.lua
scripts/agon/world/spawn_service.lua
scripts/agon/core/entity_registry.lua
scripts/agon/net/audience_state_channel.lua
```

### 实施步骤

1. Registry 校验 profile_id、version、prefab constraint、apply mode 和 replication mode。
2. 支持 `SPAWN_ONLY`、`BLOCKING_ONLY`、`LIVE_SAFE`。
3. 支持 `SERVER_ONLY`、`REPLICATED`；REPLICATED Profile 必须声明客户端 contract。
4. Adapter 可以修改组件、数值、标签、技能、Loot、Brain、StateGraph 和物品行为，但 Base 不定义具体属性。
5. Profile 只能应用到 Instance-owned entity；GLOBAL、Lobby、其他 Instance 一律拒绝。
6. 外部 entity 默认克隆；若原地认领，必须注册 capture/restore Adapter。
7. child profile policy 覆盖 minion、projectile、trap、loot 等类别。
8. 禁止无条件全局 `TUNING` 或 PostInit 修改；确需全局 Hook 时只能安装 membership/profile 不匹配时无效果的路由。
9. TestMode 至少实现：一个怪物属性 Profile、一个物品 Profile、一个 Brain/StateGraph 或技能行为 Profile，以及一个 REPLICATED 展示 Profile。

### 官方源码核对

- 选定测试怪物 Prefab、组件、Brain、StateGraph；
- `SetBrain`、`SetStateGraph`、`StopBrain`、`RestartBrain` 的实际使用；
- 选定测试物品的 weapon/finiteuses/armor/inventoryitem 等组件；
- Replica、netvar 和客户端动作显示路径。

不要在未核对 Prefab 构造顺序和网络行为前选择测试对象。

### 验收

- A 局同名怪物强化，B 局保持原版，互不影响。
- 同名物品在不同 Instance 有不同属性/功能。
- SPAWN_ONLY 不能运行中重配；BLOCKING_ONLY 只能在安全过渡中执行。
- REPLICATED Profile 的客户端显示、动作和服务端判定一致。
- 同步 constructor child 与异步技能 child 都继承正确 Profile/Scope。
- Entity 销毁或 Scope 关闭后无 handler/listener 残留。

### 建议 Commit

```text
feat(profile): 增加实例级实体与物品定制框架
```

---

## WP7：PlayerSandbox 与 PlayerProfile

### 目标

安全保存玩家原状态，进入统一临时人物规格，并在所有退出路径完整恢复。

### 风险等级

本 WP 涉及真实玩家存档，属于最高风险。必须先使用专门测试账号和测试存档，不在唯一生产角色上首测。

### 预计文件

```text
scripts/agon/player/sandbox_service.lua
scripts/agon/player/player_profile.lua
scripts/agon/player/state_adapter_registry.lua
scripts/agon/player/adapters/inventory.lua
scripts/agon/player/adapters/survival_stats.lua
scripts/agon/player/adapters/skilltree.lua
scripts/agon/player/adapters/characters/
scripts/agon/core/participant.lua
scripts/agon/modes/test_mode/runtime.lua
```

### 实施步骤

1. 实现事务：`NEW → CAPTURED → SANDBOXED → RESTORING → RESTORED → COMMITTED`。
2. Capture 后先 Validate；未通过前绝不清空玩家。
3. Inventory Adapter 覆盖背包、装备、鼠标物品和容器边界。
4. Stats Adapter 覆盖生命、饥饿、理智、温度、潮湿和明确可恢复状态。
5. SkillTree Adapter 核对服务端/客户端握手，保存 XP、点数、已选技能和编码数据。
6. Character Adapter 处理角色特有资源、召唤物、宠物、跟随者和组件。
7. PlayerProfile 支持统一基础三维、移动速度、初始物品、技能、允许/禁用能力和外观保留。
8. TestMode 使用“只保留外观、统一能力”的 Profile。
9. Restore 按 Adapter 逆序或明确依赖顺序执行；每步幂等。
10. ValidateRestore 成功前不删除 snapshot。
11. 失败进入 RESTORE_PENDING；确定性失败进入 RESTORE_BLOCKED，提供 inspect/retry/export。

### 官方源码核对

- player inventory、active item 和 equip 保存路径；
- skilltree、classified 与客户端确认；
- 各测试角色的特有组件和保存函数；
- shard migration 和 player save/load 顺序。

### 验收

- 原背包、装备、鼠标物品逐项恢复。
- 原 Stats 和技能树逐项恢复。
- TestMode 内所有测试角色使用统一能力，原角色技能不残留。
- 主动退出、正常结束、异常销毁、断线后结束、重启中止均进入同一恢复 pipeline。
- 中途注入崩溃/错误后使用同一 transaction ID 重试不复制物品。
- 一个玩家恢复失败不阻塞其他玩家和 Zone 清理。
- 未适配角色被拒绝进入，不在已知不安全状态下“尝试运行”。

### 建议 Commit

```text
feat(sandbox): 实现玩家状态沙箱与幂等恢复事务
```

---

## WP8：Lobby、Spectator 与 PlayerDeathPolicy

### 目标

完成大厅返回、只读观战、残影和 Instance-aware 死亡形态。

### 预计文件

```text
scripts/agon/world/lobby_service.lua
scripts/agon/player/spectator_service.lua
scripts/agon/player/death_policy.lua
scripts/prefabs/agon_spectator_echo.lua
scripts/agon/net/rpc.lua
scripts/agon/modes/test_mode/runtime.lua
```

### 实施步骤

1. LobbyService 管理进入、return point 和安全恢复点。
2. Spectator 与 Participant 分离，不创建 PlayerSandbox snapshot。
3. 进入观战时记录 lobby return position，在大厅生成唯一 `agon_spectator_echo`。
4. 真实玩家移到目标 Zone spectator anchor，隐藏实体、阴影和地图标记，禁用 gameplay action、碰撞、受击、装备/技能影响。
5. 客户端 spectator input layer 保留旋转、缩放、目标切换和受限自由相机。
6. 服务端只接受观战白名单 RPC。
7. Echo 仅复制只读外观和显示名，无 gameplay component，`persists = false`。
8. 退出、断线、目标 Instance 结束、异常清理和服务器关闭都移除 Echo 并解除 guard。
9. PlayerDeathPolicy 支持 GHOST 与 REVIVABLE_CORPSE；死亡者仍是 Participant，不转 Spectator。
10. TestMode 可通过配置选择两种死亡模式，并测试两个并发 Instance 使用不同策略。

### 官方源码核对

- `components/spectatorcorpse.lua`
- `components/revivablecorpse.lua`
- `components/focalpoint.lua`
- `components/playercontroller.lua`
- Player StateGraph 和官方特殊活动的观战/尸体流程

### 验收

- Spectator 原物品、技能树和持久状态不被改写。
- Spectator 无法攻击、拾取、施法、发光、提供光环或影响 AI。
- Echo 唯一、无碰撞、无 AI 影响，并在所有退出路径移除。
- 观战者不能看到或切换到其他 Instance。
- GHOST 可移动但受 Zone 边界限制。
- REVIVABLE_CORPSE 不能移动，只有合法同局 Participant 可救。
- Instance 结束后死亡玩家仍通过 PlayerSandbox 恢复。
- 远距离网络实体可见性和 camera bounds 必须实服压测；不得硬编码未经验证的“17 格”。

### 建议 Commit

```text
feat(player): 实现大厅观战与实例死亡策略
```

---

## WP9：保存、重启中止、网络收口与后端边界

### 目标

让正常、崩溃、断线、重启和重复请求最终都进入可诊断的安全状态。

### 预计文件

```text
scripts/components/agon_runtime.lua
scripts/agon/persistence/schema.lua
scripts/agon/persistence/migrations.lua
scripts/agon/net/rpc.lua
scripts/agon/net/audience_state_channel.lua
scripts/agon/backend/backend_adapter.lua
scripts/agon/debug/diagnostics.lua
```

### 实施步骤

1. 为 Runtime、Instance、Scope、Scene、Group、Common Service、RNG、Profile membership、Sandbox 和 settlement 定义 schema/version。
2. OnSave 不保存 function、entity reference、task handle、Spectator session 或 UI 状态。
3. OnLoad 发现 active Instance 时统一 `RECOVERING → DESTROYING`，不恢复玩法。
4. 清理 entity、Scope、SceneTransaction 和 Zone Tile；失败 Zone 进入 QUARANTINED。
5. 在线玩家立即恢复；离线玩家重连时先恢复再进入大厅。
6. RPC 收口全部 operation 的 lifecycle、generation、revision、audience、membership、request ID 和 rate limit。
7. BackendAdapter 第一版只定义 `SubmitGameResult`、`SubmitSettlement`；未配置 transport 时返回明确的 `NOT_CONFIGURED` 并保留 pending，或使用仅记录、不返回成功的测试 adapter，不能伪造提交成功。
8. settlement_id 唯一，后端不可用时保存 pending，重试不重复奖励。
9. 增加完整 diagnostics 和 export，不包含认证秘密。

### 验收

- 在 PREPARING、RUNNING、TRANSITION、FINISHING 人工重启，全部中止并清回虚空。
- 玩家在各阶段断线后重连，恢复顺序正确。
- 重复 restore、destroy、rollback、score、decision 和 settlement 请求幂等。
- 损坏或未知 schema 不静默加载；给出可定位错误和安全降级。
- QUARANTINED Zone 不再自动分配，但其他 Zone 正常工作。
- 无权限客户端无法读取其他 audience 或调用管理员接口。

### 建议 Commit

```text
feat(recovery): 完成重启中止与幂等恢复结算
```

---

## WP10：Base Release Gate 与 TestMode 全链验收

### 目标

不再新增架构功能，只修复集成验证发现的问题，证明 Base 可以承载正式 Mode。

### 完整验收矩阵

#### A. Shard Gate

- 非 Agon shard 无 manager、listener、task、worldgen 变化和后端请求。
- Agon shard 客户端/服务端模块边界正确。

#### B. 双 Instance

- A、B 使用不同 Zone 和独立 services。
- A 的 Scene、Scope、Group、Decision、Effect、Profile、Score 和死亡策略不影响 B。
- A Destroy 后 B 继续，A Zone 可复用。

#### C. Scene

- initial、BLOCKING、LIVE_PATCH、rollback、stale revision、occupied policy 全覆盖。
- Zone bounds 外 Tile 从未被修改。
- 结束后无地面、实体或 minimap layer 残留。

#### D. EntityProfile

- 同名怪物和物品跨 Instance 差异化。
- Brain/StateGraph、物品功能和 Replica 至少各有一个运行验证。
- child ownership 和 profile 传播正确。

#### E. Player

- 两个以上角色完成沙箱进入/恢复。
- 物品、Stats、技能树和角色资源一致。
- Spectator 不进入 sandbox，Participant 必须进入。
- Ghost/Corpse 与 Spectator 明确分离。

#### F. Failure Injection

- Scene 构建中错误；
- Scope resolver 错误；
- Profile Adapter 错误；
- Player Adapter capture/restore 错误；
- Decision 重复 resolve；
- 后端不可用；
- 服务器在不同生命周期重启。

每种错误都必须得到：明确错误码、局部隔离、无跨局副作用、可重试或可管理的终态。

#### G. 性能与观察

- Tile batch/rebuild 成本；
- EntityRegistry 查询与边界检查成本；
- spectator 网络可见范围和客户端实体数量；
- 两个以上并发 Instance 的 task、entity 和 netvar 数量；
- 日志足够定位但不过量刷屏。

### Base Ready 判定

只有同时满足以下条件，才可以开始 FEAST 正式实现：

1. M0–M7 的完成定义全部满足；
2. TestMode 全流程至少在专服和真实客户端跑通一次；
3. 双 Instance 并发通过；
4. PlayerSandbox 没有已知数据丢失路径；
5. BLOCKING 和 LIVE_PATCH 都有运行证据；
6. EntityProfile 跨 Instance 不污染；
7. 重启中止与恢复通过；
8. 所有未验证项已明确记录，不把关键安全行为留作“以后再测”。

### 建议 Commit

```text
test(base): 完成通用底座全链路集成验收
```

---

## 8. 每个 WP 的通用验证命令

根据仓库实际工具选择；不得为文档要求而全局安装新工具。

```powershell
git -c safe.directory='D:/OneDrive/DST/the-agon' status --short
git -c safe.directory='D:/OneDrive/DST/the-agon' diff --check
rg -n "ZoneCapabilities|required_zone_capabilities|GetArenaBlueprint|team_id" .
rg -n "SpawnPrefab\(|SetTile\(|TUNING\." scripts
```

最后两项不是要求零结果：

- `SpawnPrefab()` 只允许出现在 SpawnService 或经审核的 Base 路由内部；
- `SetTile()` 只允许出现在 TerrainService；
- `TUNING` 可以读取，但 Mode 不得全局改写；
- 旧术语应为零结果。

如果系统存在兼容的 Lua 语法检查工具，可以对新增 Lua 执行语法检查；没有则不要全局安装，必须在交付中说明。

运行时验证至少保存：

- 服务端日志关键片段；
- 客户端异常或无异常说明；
- Debug command 输出；
- Instance、Zone、Scope 和 restore 的最终状态；
- 测试使用的 Layout version、Mode version 和 seed。

---

## 9. 可直接交给其他 AI Agent 的任务模板

复制以下模板，只替换 `<WP>`：

```text
请在 D:\OneDrive\DST\the-agon 中只实施 docs/base-implementation-plan.md 的 <WP>。

开始前必须完整阅读：
1. D:\OneDrive\DST\.codex\AGENTS.md
2. docs/base-design.md
3. docs/base-implementation-plan.md 中的全局工程契约、test_mode 总体规格和 <WP>

先检查 Git 状态并保护用户已有修改。涉及 DST API、Prefab、Component、Brain、StateGraph、RPC、网络、世界生成或保存时，先查询 D:\OneDrive\DST\scripts，禁止修改该目录。

不要提前实现后续 WP，不要添加当前 WP 没有调用路径的空抽象，不要把任何具体 Mode 规则写入 Core。所有代码必须通过当前 WP 的验收项；无法运行验证时，明确列出未验证内容和风险，不得声称已经完成运行验证。

完成后报告：修改内容、文件、官方源码依据、静态/运行验证、未验证项、Git 状态、建议中文 Conventional Commit，以及能否进入下一 WP。不要 commit 或 push。
```

对于涉及 G1/G2 的 WP，在缺少输入时把能安全完成的 schema、校验和静态部分做完，然后停止在运行时边界并向用户请求具体输入，不得自行编造生产配置。

---

## 10. 明确不属于 Base 实施的内容

以下内容不得因为 TestMode 或 FEAST 需求被顺手加入 Base：

- 匹配算法和正式匹配 UI；
- FEAST 食谱、火候、宴席、献祭、构筑和得分公式；
- 角斗场怪物组合、Wave 和奖励；
- PVP 武器平衡、伤害公式、缩圈和胜负；
- 钓鱼比赛鱼池、重量和计分规则；
- 具体 Effect 类型和 Profile 数值；
- 各 Mode 的死亡/复活数值；
- Flask 路由、认证、金币字段和排行榜；
- `RESUME_IF_SUPPORTED`。

Base 的完成标准不是“已经预先实现所有玩法”，而是正式 Mode 不需要重新实现以下能力：

```text
Instance 和 Zone 生命周期
资源作用域与自动清理
动态场景事务
归属和跨局隔离
Group 和 audience
阶段、时钟、投票、Effect 生命周期、计分账本
实体与物品 Profile
玩家沙箱、观战和死亡接口
保存、恢复、幂等与诊断
```

---

## 11. 当前推荐的立即行动

当前可以立刻把 WP0 交给一个 Agent 执行；它不依赖正式地图坐标，也不会触碰玩家数据。

与此同时，项目维护者准备 G1 和 G2：

```text
Agent：完成 WP0 的 Mod 骨架和 shard gate
维护者：确定正式 WorldLayout 与专服测试方式
双方完成
→ 进入 WP1
```

不要把多个 WP 合并成一次“大而全”的首次提交。第一批代码的合理边界是：Mod 可以安全加载、配置硬门正确、runtime 幂等创建、关闭配置时零副作用。完成该边界后再开始世界生成。
