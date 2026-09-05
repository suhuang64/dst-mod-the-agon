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
7. 在修改前写出本次的目标、涉及文件和验证方法；发现新的实质性不确定性时按停止条件处理，不重复询问本文已固定的配置。
8. 完整读取并核对 `docs/base-implementation-logs.md`；把相关历史结论当作待复核上下文，不得跳过当前代码、官方源码和运行环境检查。

### 1.2 每个 Agent 完成后必须报告

- 实现了什么；
- 修改或新增了哪些文件；
- 查阅了哪些官方源码及其用途；
- 执行了哪些静态和运行时验证；
- 哪些行为尚未验证，以及原因；
- 当前 `git status --short`；
- 一条中文 Conventional Commit 信息；
- 下一 WP 是否满足进入条件。

完成报告必须在 `docs/base-implementation-logs.md` 末尾追加同一任务的执行记录；没有代码修改时也要记录检查结果和未修改原因。

除非用户明确要求，不执行 `git commit`、`git push`、分支切换、历史修改或清理用户文件。

### 1.3 执行日志规则（强制）

`docs/base-implementation-logs.md` 是本项目跨 Agent 的持续执行日志，默认采用 append-only 的精简里程碑记录。任何实施、调试、验证、修复或文档任务都必须遵循以下顺序：

1. 开始前读取日志，并在本次工作记录中明确目标、范围、当前 Git 状态、关键假设、官方源码依据和验证计划。
2. 执行中记录重要运行事实、错误原文、修复原因、测试环境、端口/进程、存档影响和用户明确延后的事项。
3. 完成后追加日期、任务/WP、关键修改、最小验证证据、未验证项、风险、后续行动、Git 状态和建议中文 Conventional Commit。
4. 默认只能追加；如果维护者明确要求压缩，可删除重复的逐条回显并整理为关键摘要，但不得删除失败根因、修复、最终证据、未验证边界或用户明确的延后决定。压缩后后续仍只追加精简记录。
5. 日志中的运行证据必须标明属于静态检查、服务端、真实客户端还是跨 shard；缺失的验证不得宣称完成。相同结果的重复轮询和无新结论的中间回显不记录。
6. 不得写入密码、Token 等秘密；官方 `D:\OneDrive\DST\scripts` 仍然只读，日志规则不构成修改官方源码的授权。

### 1.4 通用停止条件

出现以下任一情况，Agent 必须停止当前危险路径并向用户说明，而不是猜测：

- 实际 DST API 或坐标换算结果使本文的正式 WorldLayout 无法成立；
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

## 3. 全局工程契约

### 3.1 Shard 与加载边界

- `modinfo.lua` 公开配置只保留 `enable_agon = true/false`。
- 所有 shard 的 Mod 都是 enabled；由各 shard 的 `modoverrides.lua` 单独决定 `enable_agon`。
- 客户端需要的 Prefab、classified、RPC 名称和 Replica 声明无条件注册。
- 只有 server runtime bootstrap 经过 `enable_agon` 与 `world.ismastersim` 硬门。
- `enable_agon = false` 时不得存在 manager、world listener、periodic task、Zone scan 或后端请求。
- 不用 shard 名称、master/secondary 身份推测 Agon 角色。

### 3.2 ID、generation 与 revision

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

### 3.3 错误模型

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

### 3.4 Lua 与模块约束

- 遵循 DST Lua 版本和官方代码可用语法；不要假设现代 Lua 特性存在。
- 不引入第三方依赖来完成基础表、ID、状态机或序列化。
- Module 不在 require 时产生世界副作用。
- Server-only module 不应被客户端执行服务端逻辑。
- 新增或修改代码中的自然语言注释统一使用中文；API、标识符、协议字段和必要专有名词可保留英文，工具/类型/诊断指令注释例外；注释应解释意图与约束，不复述代码，并保持适量。
- 不保存 function、task handle、entity reference 或 Brain object。
- Mode 不直接访问 manager 内部表；只拿到 facade。
- Mode 不直接调用 `change_tile()` 或裸 `SpawnPrefab()`。
- Mode 不无条件修改 `TUNING` 或所有同名 Prefab。

### 3.5 保存策略

第一版固定为 `ABORT_ON_RESTART`：

- 保存足以清理和恢复的数据；
- 不尝试恢复进行中的玩法；
- 不保存 Lua task handle；保存 semantic deadline；
- 每种 Core/Common/Mode 数据带 schema/version；
- 原 PlayerSandbox snapshot 在恢复验证成功前永不删除；
- settlement 和 score event 使用幂等 ID。

### 3.6 Debug 是交付内容

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

### 3.7 固定开发与运行验证环境

Base 的本地运行验证使用现有单 shard 测试环境：

```text
Cluster: D:\OneDrive\DST\klei\DoNotStarveTogether\Test
Shard:   World01（id = 1，is_master = true）
Mod:     D:\SteamLibrary\steamapps\common\Don't Starve Together\mods\the-agon
Target:  D:\OneDrive\DST\the-agon（现有 SymbolicLink）
Start:   D:\OneDrive\DST\start.sh
Server log: D:\OneDrive\DST\klei\DoNotStarveTogether\Test\World01\server_log.txt
Chat log:   D:\OneDrive\DST\klei\DoNotStarveTogether\Test\World01\server_chat_log.txt
```

在 PowerShell 中可直接使用与 `start.sh` 等价的命令，并保持终端会话以便查看输出和正常停服：

```powershell
& "D:\SteamLibrary\steamapps\common\Don't Starve Together\bin64\dontstarve_dedicated_server_nullrenderer_x64.exe" `
  -persistent_storage_root d:/OneDrive/DST/klei `
  -conf_dir DoNotStarveTogether `
  -cluster Test `
  -shard World01
```

- 实施 Agent 可以按当前 WP 修改 `Test/World01` 下的 `modoverrides.lua`、`server.ini`、`leveldataoverride.lua` 和该 shard 的测试存档，也可以启停该专服；
- `Test/World01` 明确是可丢弃测试存档，世界生成验收可以直接重建，不要求备份；
- 上述权限仅限 `Test/World01`，不得删除或改写其他 Cluster、shard、Mod 或用户数据；
- `modoverrides.lua` 中保持 Mod enabled，并为该 shard 设置 `enable_agon = true`；验证关闭硬门时临时切换为 false，完成后恢复 true；
- 当前环境只有 World01，因此可以验收 Agon shard 自身和 true/false 硬门，但不能声称已完成“普通 shard 跳转到 Agon shard”的跨 shard 集成验证；该项需未来有第二 shard 时补测；
- 需要真实客户端的步骤由维护者操作至少两个客户端。Agent 必须给出编号操作步骤并记录维护者返回的结果；未执行时标记为“等待人工运行验收”，不得用服务端假玩家或静态检查替代；
- 客户端发生异常时，由维护者提供客户端控制台输出或该客户端实际生成的日志；Agent 不得预设未经当前机器验证的客户端日志路径。

---

## 4. 目标文件结构

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

## 5. `test_mode` 总体规格

### 5.1 目的

`test_mode` 用于证明 Base 通用能力，不提供正式奖励、匹配入口或后端排名。它必须能在没有 FEAST 代码的情况下独立验证：

- Mode 注册和 service opt-in；
- `SMALL/MEDIUM/LARGE` 物理尺寸类别分配；
- 双 Instance 并发；
- ScenePlan、`BLOCKING`、`LIVE_PATCH`；
- Scope 创建、转移和关闭；
- ParticipantGroup；
- Phase、Clock、Decision、Effect、Score；
- EntityProfile 与 child ownership；
- PlayerSandbox；
- Spectator 与 DeathPolicy；
- destroy、restart abort 和 restore。

### 5.2 目录

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

### 5.3 最终注册契约

```lua
ModeRegistry:Register({
    mode_id = "TEST_MODE",
    mode_version = 1,
    zone_category = "SMALL",
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

### 5.4 最终测试流程

```text
Create Instance
→ Initial ScenePlan 构建简单陆地、Participant 出生点、spectator anchors 与 camera bounds
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

### 5.5 TestMode 不得做的事

- 不直接访问其他 Mode；
- 不直接写 manager 私有状态；
- 不直接调用 `TheWorld.Map:SetTile()`；
- 不直接调用裸 `SpawnPrefab()`；
- 不修改全局 `TUNING`；
- 不包含 FEAST 料理、角斗场战斗或钓鱼比赛规则；
- 不新增 `TEST` 类别或专用测试 Zone；使用正式 SMALL 池并遵守同一分配、构建和清理路径；
- 不为测试通过而跳过 ownership、Scope、RPC 或 restore 校验；
- 不在非 Agon shard 启动。

### 5.6 管理入口

第一版不做正式 UI。TestMode 不进入玩家匹配列表，只能通过 server admin Debug API 驱动：

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

## 6. Work Packages

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

### 目标

世界首次生成时只创建大厅陆地与唯一 Portal，其余区域保持 `WORLD_TILES.IMPASSABLE`；Zone 只存在于配置中。

### 正式 WorldLayout 参数

坐标统一使用“相对唯一 Portal 实际 Tile 的偏移”。世界生成不假设地图中心的世界坐标为 `(0,0)`；world 启动后先解析 Portal 实际 Tile，再由唯一坐标转换器生成 Lobby/Zone 的实际 Tile 与 world 坐标。配置、日志和 Debug 输出必须区分 `offset_tile`、`resolved_tile` 与 world 坐标，禁止混用。

```lua
world_size_tiles = { width = 400, height = 400 }
coordinate_unit = "TILE_OFFSET_FROM_PORTAL"

lobby = {
    center_offset = { x = 0, z = 0 },
    safe_size = { width = 9, height = 9 },
    build_size = { width = 11, height = 11 },
    hard_size = { width = 15, height = 15 },
    portal_prefab = "multiplayer_portal",
}
```

Zone 共 10 个。类别只表示物理尺寸，不表示玩法：

| 类别 | 数量 | `safe_bounds` | `build_bounds` | `hard_bounds` | 相对 Portal 的中心偏移 `(x, z)` |
| --- | ---: | ---: | ---: | ---: | --- |
| SMALL | 4 | 11×11 | 13×13 | 17×17 | `(-155,65)`、`(155,65)`、`(-155,-65)`、`(155,-65)` |
| MEDIUM | 4 | 29×29 | 31×31 | 35×35 | `(-105,65)`、`(105,65)`、`(-105,-65)`、`(105,-65)` |
| LARGE | 2 | 121×61 | 123×63 | 127×67 | `(0,130)`、`(0,-130)` |

Lobby 的 `center_offset = (0,0)` 表示其实际中心就是 Portal 实际 Tile，并不表示 Portal 的世界坐标为 `(0,0)`。Zone 使用上表相对偏移：最外侧布局相对 Portal 的最大硬边缘偏移为 `±163.5` Tile，相邻 SMALL/MEDIUM 的硬边缘间距为 24 Tile。

LARGE 固定横向，即宽度沿 x 轴、高度沿 z 轴。Zone ID 按表顺序固定为 `small_01..04`、`medium_01..04`、`large_01..02`。运行时三层矩形都以解析后的 Zone center 为几何中心，并满足：

```text
safe_bounds ⊂ build_bounds ⊂ hard_bounds
```

Lobby 与所有 Zone 的三层宽高均为奇数；每个 center 必须落在唯一中心 Tile 上，边界相对该 Tile 四向严格对称，不允许半 Tile 中心或单侧多一格。

按轴对齐矩形边缘计算，任意两个 `hard_bounds` 的最短欧氏距离至少为 24 Tile。当前布局相对 Portal 的最大硬边缘偏移为 163.5 Tile，因此 Portal Tile 到地图四侧实际有效边界都必须至少有 `163.5 + 36 = 199.5` Tile 空间。Validator 必须读取实际地图边界与 Portal Tile 后计算，不能假设边界是 `±200`、Portal 是 `(0,0)`，也不能只比较中心距。

- `safe_bounds`：当前场景允许玩家正常活动的区域；
- `build_bounds`：ScenePlan 可以铺地和布置场景的区域；
- `hard_bounds`：地形事务、实体生成、回滚、扫描和最终清理的绝对边界。

大厅固定使用 `MAXWELL_RITUAL_HALL_V1` 11×11 Tile 图案，以 Portal 实际 Tile 为唯一中心，按下列优先级执行，后者覆盖前者：

1. 11×11 基底：`WORLD_TILES.CARPET2`；
2. 从唯一中心 Tile 通向四边的 3 Tile 宽十字通道：`WORLD_TILES.WOODFLOOR`；
3. 中央 5×5：`WORLD_TILES.CHECKER`；
4. 最外侧 1 Tile 环：`WORLD_TILES.BRICK_GLOW`。

`multiplayer_portal` 位于大厅唯一中心 Tile。大厅出生点和通用返回点共用以下相对 Portal 的有序 Tile 偏移：

```text
(3,0), (-3,0), (0,3), (0,-3),
(2,2), (2,-2), (-2,2), (-2,-2)
```

LobbyService 按安全、未占用和 round-robin 选择；全部占用时只在 `safe_bounds` 内执行有界最近安全点搜索，不得落入虚空。Spectator 返回优先使用其原大厅残影位置，失效时才使用该候选列表。

### 预计文件

```text
modworldgenmain.lua
scripts/agon/config/world_layout.lua
scripts/agon/world/layout_service.lua
scripts/agon/world/lobby_service.lua
scripts/components/agon_runtime.lua
```

### 实施步骤

1. 把上述正式值写入可序列化 `WorldLayoutDefinition`，初始 `layout_version = 1`；不得另建 DEV Layout 取代正式配置。
2. 实现唯一的 Portal-anchor Tile/world 坐标转换器和奇数尺寸中心矩形构造器；验证 center 对应唯一中心 Tile、实际宽高与四向对称边界，防止 off-by-one。
3. 实现配置静态验证和 Portal 解析后的运行时验证：世界尺寸、坐标单位、三层 bounds 包含关系、24 Tile Zone 间距、实际地图 36 Tile 边距、zone_id 唯一、类别与尺寸匹配、大厅点位位于 `safe_bounds`。
4. 查询 `lavaarena`、`quagmire` 地图任务及官方 layout API，使用 400×400 Tile 世界生成纯虚空地图，并在地图中央附近选择能容纳完整相对布局的合法 anchor。
5. `modworldgenmain.lua` 使用同一个 `enable_agon` 开关；关闭时不改变其他 shard worldgen。
6. 以同一个 worldgen anchor 生成大厅 Tile 图案和中心唯一 `multiplayer_portal`，不生成 Zone 地面或玩法实体。
7. world runtime 启动后查找 Portal，读取实际 world/Tile 坐标，用 `portal_tile + center_offset` 解析 Lobby 与 10 个 Zone 的实际中心和边界。
8. 校验 Portal Prefab、唯一性、Portal 位于大厅中心、Zone 间距和解析后的地图边距；失败时停止 Agon runtime，不能回退到世界原点、自动选另一个 Portal 或单独平移 Zone。
9. OnSave/OnLoad 保存 layout version，避免重启重复生成。

### 官方源码核对

- `scripts/map/tasks/lavaarena.lua`
- `scripts/map/tasks/quagmire.lua`
- `scripts/map/forest_map.lua` 的世界尺寸设置路径
- `scripts/constants.lua` 的 `TILE_SCALE`
- `scripts/tiledefs.lua` 的正式 Tile 名称
- `scripts/prefabs/multiplayer_portal.lua`
- `scripts/map/` 下实际使用的 static layout 和任务 API
- `scripts/modutil.lua` 的 worldgen Mod API

### 验收

- `enable_agon = false` 的 shard 地图生成不受影响。
- Agon shard 只有大厅为陆地，其余均为 IMPASSABLE，不是海洋。
- 大厅四种 Tile 的范围、覆盖优先级和 11×11 尺寸逐 Tile 正确；中央 5×5、3 Tile 宽通道和外环都相对 Portal 中心 Tile 对称。
- Portal 唯一、Prefab 为 `multiplayer_portal` 且位于大厅唯一中心 Tile；不要求其 world 坐标为 `(0,0)`。
- 10 个 Zone 的类别、相对偏移和三层尺寸与上表一致；解析后的所有 `hard_bounds` 落在实际地图内、边距至少 36 Tile且初始无地面。
- 大厅候选点均在安全地面；占用回退搜索不会越过 `safe_bounds`。
- 保存/重启不重复放置 Portal 或大厅对象。
- 错误 Layout 会在启动前给出可定位错误。

### 完成定义

在可直接重建的 `Test/World01` 中完成首次生成，使用截图、逐 Tile/边界 Debug 检查和服务端日志证明实际地图结果。只有静态检查时必须注明 WP1 尚未完成，不能进入依赖真实地图的 WP。

### 建议 Commit

```text
feat(world): 实现专用虚空世界与大厅布局校验
```

### WP1 延后项

- 当前纯虚空地图会让官方 `hermitcrab_relocation_manager` 找不到
  `monkeyqueen` 与 `monkeyisland_portal`，并让官方 `wagpunk_arena_manager`
  找不到 `hermitcrab_marker` 与 `beebox_hermit`。
- 这是官方 `forest` Prefab 无条件挂载 DLC manager，而 WP1 刻意移除官方
  set piece 的兼容性告警；已验证不阻止大厅、Portal 和 IMPASSABLE 地图生成。
- WP1/WP2 暂不加入伪造定位实体；后续确定 The Agon 是否需要这些官方玩法后，
  再在生产集成阶段选择针对性跳过 manager 初始化，或保留完整官方 set piece。

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
6. 建立最小 TestMode，请求 `SMALL` Zone；此时不启用 Common Services。
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
7. 实现 ScenePlan schema 和严格 validation。每个完整 ScenePlan revision 必须声明 Participant spawn points、spectator anchors、camera bounds 和 emergency safe points；局部 Patch 必须明确继承或替换哪些锚点。
8. TerrainService 封装 `GetTileCoordsAtPoint`、`GetTileAtPoint`、`SetTile`、world/minimap rebuild；唯一内部 `change_tile()` 位于此处。
9. SceneTransaction 记录修改前后 Tile、scope、scene revision、execution mode 和 rollback state。
10. 实现 `BLOCKING`：只冻结目标 Instance，应用、验证、commit 或 rollback。
11. 实现 `LIVE_PATCH`：限定 affected bounds，支持 `REJECT_IF_OCCUPIED` 与 `MOVE_TO_SAFE_POINT`；`MODE_RESOLVE` 只预留注册接口，不写玩法规则。Patch 后重新验证仍在使用的动态锚点没有落入虚空或越界。
12. 动态锚点事务失败时保持最后一个已提交 ScenePlan revision；没有可用旧 revision 时中止 Instance，并通过正式恢复/返回流程把 Participant 和 Spectator 送回大厅。不得使用 Zone center 作为紧急落点。
13. TestMode 提供 initial plan、blocking patch、live empty patch、live occupied reject、live occupied move。
14. Destroy pipeline 关闭 Scope、删除实体、把 Zone `hard_bounds` 全部清回 IMPASSABLE、验证后 FREE；失败则 QUARANTINED。

### 官方源码核对

- 地图 Tile 与 minimap rebuild 的官方调用点；
- `SpawnPrefab`、entity lifecycle 和 `OnRemoveEntity`；
- `TheSim:FindEntities` 的范围和 tag 用法；
- 寻路、Physics、平台和 Tile 改变相关调用。

### 验收

#### 单 Instance

- 从纯虚空构建 TestMode 初始陆地。
- ScenePlan 提供的 Participant spawn points、spectator anchors 和 camera bounds 全部落在当前 revision 的有效地面及对应 `safe_bounds`/`build_bounds` 内。
- BLOCKING 或 LIVE_PATCH 改变布局后，旧锚点被明确继承或替换，不会继续指向已经变成虚空的 Tile。
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

### WP5 当前状态（2026-09-02）

- 状态：已完成；ParticipantGroup、Common Services、TestMode 诊断和官方 Test/World01 运行验证已完成。
- 已覆盖：两局服务隔离；Phase/Clock/Decision/Effect/Score；GROUP audience；PhaseScope 清理；RNG 平票选择；服务声明验证；重复运行和干净世界收口。
- 跨重启：已验证活动 Instance 存档可被 `ABORT_ON_RESTART` 识别并中止，重启后 `instance_count=0`、`aborted_instance_count=1`、10 个 Zone 可用且 `ValidateCore=true`；为允许持久化 Zone 场景地形，重启时不重复执行首次世界生成的全图 void 基线扫描，仍校验 Portal、大厅和保存布局。
- 边界：活动 Scene 的实体/地形清理在当前跨重启后仍会使新实例清理进入 `SCENE_RESET_FAILED`/`QUARANTINED`，属于 WP9 的 entity/Scope/SceneTransaction/Zone Tile cleanup；完整恢复和真实玩家恢复不在 WP5。
- 未覆盖：真实双客户端/UI、跨 shard、正式玩法；WP1 set-piece warnings 继续按既有计划延后。

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

### WP6 当前状态（2026-09-02）

- 状态：Base 服务端实现和官方 Test/World01 运行验收已完成。EntityProfileRegistry、按 Instance 隔离的 EntityProfileService、Profile adapter、EntityRegistry membership、child Scope 清理和 TestMode profiles 已接入。
- 官方专服 `WP6_TEST_PASS` 已通过：两个 Instance 的同名 spider/torch 使用不同 Profile；`SPAWN_ONLY` 运行中重配和 `BLOCKING_ONLY` 非安全阶段生成均被拒绝；跨 Instance ownership 被拒绝；原始 child entity 的继承、`REPLICATED` display contract、Audience 可见性和 Scope 关闭清理均通过。
- 回归：`WP5_TEST_PASS` 通过；收口为 `instances=0`、`free_zones=10/10`、`profiles=6`、`ValidateCore=true`。
- 诊断中发现并修正真实 Prefab 的同步 child 会增加 EntityRegistry 记录、物品 Profile 记录数不一定为 1，以及测试未推进 `RUNNING` 就断言 `BLOCKING_ONLY` 的问题；未修改官方 Prefab、全局 `TUNING` 或官方 manager。
- 边界：本 WP 已验证服务端 Profile 与 Audience contract，但尚未覆盖真实双客户端的 Replica/UI/动作显示、第二 shard、异步技能 child 的实际生成链路和 WP9 的跨重启活动 Scene 全量恢复清理；这些仍按 WP7–WP10/WP9 计划执行。WP1 两条 set-piece angle 错误继续按既有决定延后。

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
5. SkillTree Adapter 核对官方 `PostActivateHandshake` 的服务端 `READY` 状态和
   `ms_skilltreeinitialized` 事件，保存 XP、点数、已选技能和编码数据；不得以
   `skilltree.save_enabled` 代替握手证明。
6. Character Adapter 处理角色特有资源、召唤物、宠物、跟随者和组件。
7. PlayerProfile 支持统一基础三维、移动速度、初始物品、技能、允许/禁用能力和外观保留。
8. TestMode 使用“只保留外观、统一能力”的 Profile。
9. Restore 按 Adapter 逆序或明确依赖顺序执行；每步幂等。
10. ValidateRestore 成功前不删除 snapshot。
11. 失败进入 RESTORE_PENDING；确定性失败进入 RESTORE_BLOCKED，提供 inspect/retry/export。

### 官方源码核对

- player inventory、active item 和 equip 保存路径；
- skilltree、classified、官方 `PostActivateHandshake` 状态与客户端确认；
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

### WP7 当前状态（2026-09-02）

- 状态：PlayerSandbox、PlayerProfile、StateAdapterRegistry 及 Inventory/SurvivalStats/SkillTree/Character adapters 已实现，并已接入 Participant、InstanceManager、Common Services 和 TestMode 诊断；默认 Character adapter 仅绑定官方已知角色，其他角色必须显式注册适配器。
- 官方专服 `Test/World01` 已通过 `WP7_TEST_PASS`：合成测试玩家的背包/装备/鼠标物品/容器、Stats、技能树、角色资源与外观、统一 Profile、正常恢复、重复恢复、恢复失败后的同 transaction 重试、失败玩家隔离和 Instance 清理均通过。
- 回归：同一专服的 `WP5_TEST_PASS`、`WP6_TEST_PASS` 和 `ValidateCore=true` 均通过；`c_shutdown()` 完成序列化并正常退出，端口和进程均已清理。
- 安全边界：真实玩家 live mutation 默认关闭；未完成明确的客户端/服务端握手、角色恢复适配或人工安全开关时拒绝进入。2026-09-04 已在官方 `Test/World01` 用两名真实客户端完成限定范围的 `wilson`/`wathgrithr` Capture、进入沙箱、退出恢复和 Instance 清理；仍尚未覆盖真实客户端 UI/StateGraph/网络可见性、跨 shard、断线后重新绑定玩家对象、完整重启中止时的真实玩家存档恢复和未列入白名单的角色，这些仍需 WP8–WP10/WP9 对应阶段补测。
- 2026-09-04 真实绑定首次触发 `CHARACTER_LIVE_STATE_UNSUPPORTED`：SkillTree 官方握手已 READY，但原默认 Character Adapter 没有合法的 live 角色快照来源，因此按安全门拒绝，未清空玩家状态。根据维护者选择，本轮只实现 `wilson`/`wathgrithr`：分别接入官方 `beard`、`singinginspiration` 的纯数据 `OnSave/OnLoad`，并对活动歌曲、非零 `battleborn`、跟随者/宠物/已召唤实体拒绝进入。
- TestMode 的真实玩家 Profile 已明确收敛为 live-safe 子集：真实玩家不应用尚未具备 live mutation 契约的初始物品、技能、能力、临时组件和移动速度；合成 WP7 诊断仍使用完整统一 Profile。该调整用于验证真实 Capture/Clean/Restore，不得写成“真实统一能力已通过”。
- 记录：执行细节、两次测试诊断问题及修正原因见 `docs/base-implementation-logs.md` 的 1.23–1.25；WP1 两条 set-piece angle 错误继续按既有决定延后。

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
4. 真实玩家移到目标 Zone spectator anchor，隐藏实体、阴影和地图标记，禁用 gameplay action、碰撞、受击、装备/技能影响；补齐 `notarget/noattack/invisible/noplayertarget/NOCLICK` 等目标边界和组件级伤害/交互 guard，确保 A 不是“只隐藏画面”，而是不能被怪物、伤害、治疗、交易、喂食、诅咒、溺水、点火、冻结、雷击或其他普通/直接 gameplay 入口作用。
5. `FOLLOW` 由服务端每帧同步隐藏玩家 A 的真实 Transform 到目标 Participant B；客户端只保留本地 A 的旋转/缩放输入，不切换 `TheCamera` 或 `TheFocalPoint` target。
6. 服务端只接受观战白名单 RPC。
7. Echo 仅复制只读外观和显示名，无 gameplay component，`persists = false`。
8. 退出、断线、目标 Instance 结束、异常清理和服务器关闭都移除 Echo 并解除 guard。
9. PlayerDeathPolicy 支持 GHOST 与 REVIVABLE_CORPSE；死亡者仍是 Participant，不转 Spectator。
10. TestMode 可通过配置选择两种死亡模式，并测试两个并发 Instance 使用不同策略。

### 官方源码核对

- `components/spectatorcorpse.lua`
- `components/revivablecorpse.lua`
- `components/focalpoint.lua`（仅核对官方相机语义，不接管 target）
- `components/playercontroller.lua`
- Player StateGraph 和官方特殊活动的观战/尸体流程

### 验收

- Spectator 原物品、技能树和持久状态不被改写。
- Spectator 无法攻击、拾取、施法、发光、提供光环或影响 AI；同时怪物、伤害/死亡/治疗、交易、喂食、诅咒和环境效果均不能作用到 A，包含绕过无敌的直接 Health 入口。
- Echo 唯一、无碰撞、无 AI 影响，并在所有退出路径移除。
- 观战者不能看到或切换到其他 Instance。
- GHOST 可移动但受 Zone 边界限制。
- REVIVABLE_CORPSE 不能移动，只有合法同局 Participant 可救。
- Instance 结束后死亡玩家仍通过 PlayerSandbox 恢复。
- 远距离网络实体可见性和 camera bounds 必须实服压测；不得硬编码未经验证的“17 格”。

### WP8 当前状态（2026-09-02）

- 状态：LobbyService、SpectatorService、PlayerDeathPolicy、`agon_spectator_echo`、classified spectator state、Spectator RPC 白名单及 TestMode WP8 diagnostics 已实现并接入 Runtime、InstanceManager、Participant 和 Common Services；GHOST 与 REVIVABLE_CORPSE 按 Instance 独立配置。
- 官方专服 `Test/World01`（版本 `747465`、Build `4239`，端口 `12000`、Master shard `11889`）已通过 `WP8_TEST_PASS` 和 `WP8_VALIDATE_CORE=true`；同一进程的 `WP4_TEST_PASS`、`WP5_TEST_PASS`、`WP6_TEST_PASS`、`WP7_TEST_PASS` 也全部通过。WP4 旧诊断夹具已补齐显式合成沙箱状态，避免被 WP7 的 live mutation 硬门误判。
- 本次服务端覆盖：Lobby return point/safe point、Spectator 无 Participant/Sandbox、唯一 Echo、跨 Instance 观战和 gameplay 拒绝、退出/Instance 清理、GHOST 边界、Corpse 同局救援与重复完成幂等；`c_shutdown()` 完成序列化并正常退出，进程和 `12000/11889` 端口均已清理。
- 尚未完成：真实双客户端/UI 与 StateGraph 动画、跨 shard 网络路径、远距离实体可见性和 camera bounds 压测、真实玩家断线重绑定，以及 WP9 的重启中止/完整玩家恢复清理。这些仍是后续 WP9/WP10 的实服边界，不把合成诊断当作 Base Release Gate。
- 两条官方 `hermitcrab_relocation_manager` / `wagpunk_arena_manager` set-piece angle 错误继续按既有决定只记录、不处理。

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
scripts/agon/player/restore_queue.lua
scripts/agon/debug/diagnostics.lua
scripts/agon/modes/test_mode/wp9_diagnostics.lua
```

### 实施步骤

1. 为 Runtime、Instance、Scope、Scene、Group、Common Service、RNG、Profile membership、Sandbox 和 settlement 定义 schema/version。
2. OnSave 不保存 function、entity reference、task handle、Spectator session 或 UI 状态。
3. OnLoad 发现 active Instance 时统一 `RECOVERING → DESTROYING`，不恢复玩法。
4. 清理 entity、Scope、SceneTransaction 和 Zone Tile；失败 Zone 进入 QUARANTINED。

   WP5 官方跨重启验证已暴露活动 Scene 的持久化实体/地形清理边界：`ABORT_ON_RESTART` 本身可完成，但后续新实例销毁旧场景时可能返回 `SCENE_RESET_FAILED` 并隔离 Zone。本项必须在 WP9 实现完整清理后重新验收。
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

### 当前状态（2026-09-02）

- WP9 的持久化 schema/migration、`ABORT_ON_RESTART` 活动 Instance 中止、Scene/Zone 清理、Sandbox 恢复队列、RPC/Audience 保存收口和 BackendAdapter 已实现；官方 `klei/Test/World01` 已完成 WP4–WP9 回归。
- 已完成一次真实活动 Instance 的 `c_save()`、`c_shutdown()`、同存档重启和恢复校验：活动 Instance 不续跑，`free_zone_count=10/10`，恢复队列 pending snapshot 保留，`ValidateCore=true`；随后回滚到测试前快照并完成干净关服。
- 尚未达到 WP10 Base Release Gate：真实双客户端/UI、四个生命周期阶段的人工重启矩阵、真实玩家断线重连状态恢复、第二 shard/cross-shard、真实 Backend transport 和完整故障注入/QUARANTINED 修复仍需后续验收。WP9 的完成状态是“实现与单 shard 服务端合成/跨重启验证完成”，不是全链路发布完成。

### 建议 Commit

```text
feat(recovery): 完成重启中止与幂等恢复结算
```

---

## WP10：Base Release Gate 与 TestMode 全链验收

### 目标

不再新增架构功能，只修复集成验证发现的问题，证明 Base 可以承载正式 Mode。

### 执行方式

1. 只使用 3.7 节定义的 `Test/World01`，先记录 `server_log.txt` 的起始时间或行号，避免把旧日志当成本次证据。
2. 在 `World01/modoverrides.lua` 中启用本 Mod，并设置 `enable_agon = true`；TestMode 仍只允许管理员入口，不加入正式模式列表。
3. 直接重建 World01 测试存档，启动专服，先完成大厅、Portal、10 个虚空 Zone 槽位和正常天数增长验收。
4. Agent 给维护者一份编号客户端脚本，明确“客户端 A/B 分别加入、执行哪个动作、应看到什么、失败时返回什么信息”；维护者操作至少两个真实客户端。
5. 每个测试用例记录：时间、客户端身份、instance_id、zone_id、scene revision、seed、Debug 输出、服务端日志范围和观察结果。
6. 需要验证关闭硬门时，把 `enable_agon` 临时改为 false 并重启 World01；验证结束后恢复 true。false 状态下不得为了测试方便创建 Agon manager。
7. 运行中发现错误时先保留日志和状态，再通过正式 destroy/restore/cleanup pipeline 收口；只有 Test/World01 存档可以直接重建，不能清理其他路径。
8. 真实客户端步骤未执行时，WP10 状态只能是“等待人工运行验收”，不能判定 Base Ready。

### 完整验收矩阵

#### A. Shard Gate

- 同一 World01 在 `enable_agon = false` 时无 manager、listener、task、worldgen hook 副作用和后端请求。
- Agon shard 客户端/服务端模块边界正确。

#### B. 双 Instance

- A、B 使用不同 Zone 和独立 services。
- A 的 Scene、Scope、Group、Decision、Effect、Profile、Score 和死亡策略不影响 B。
- A Destroy 后 B 继续，A Zone 可复用。

#### C. Scene

- initial、BLOCKING、LIVE_PATCH、rollback、stale revision、occupied policy 全覆盖。
- Zone `hard_bounds` 外 Tile 从未被修改；普通构建内容未越过 `build_bounds`。
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
8. 当前单 shard 范围内的关键安全行为全部有运行证据；“普通 shard → Agon shard”的实际迁移明确标记为生产前集成测试，不冒充已验证。

当前 `Test` Cluster 只有 World01。通过本 WP 代表 Base 在专用 Agon shard 内达到可开发正式 Mode 的条件，不代表跨 shard 迁移已通过；增加第二 shard 后必须补测：普通世界保持 `enable_agon = false`、Agon 世界为 true、玩家往返迁移、断线与迁移失败恢复。

### WP10 当前状态（2026-09-02）

- 状态：`等待人工运行验收`，尚未宣称 `Base Ready`。
- WP9 已完成官方 `Test/World01` 的 WP4–WP9 服务端回归、活动 Instance 跨重启中止、Scene/Zone 清理、pending restore snapshot 保留和 `ValidateCore=true`；这些证据不替代真实客户端发布门。
- 本轮已在官方 `Test/World01` 完成一次 WP10 服务端预检：`enable_agon=false` 时世界正常启动但没有新的 `LAYOUT_READY`/`CORE_READY`；恢复 true 后 `WP4_TEST_PASS`–`WP9_TEST_PASS`、`WP10_VALIDATE:true` 和 `instances=0/zones=10/restores=0/backend_pending=0/errors=0` 均通过。直接把 `agon.test.*` 输进 `RemoteCommandInput` 会产生入口格式错误，验收脚本已改为已验证的 Runtime 表达式。
- 已新增 [WP10 客户端验收脚本](wp10-client-acceptance.md)，包含真实 A/B 身份记录、双 Instance、Scene、PlayerSandbox、Spectator、死亡策略、四阶段重启、`enable_agon=false` 和故障注入结果表。维护者每次执行后的结果必须继续追加到 `docs/base-implementation-logs.md`。
- 已实现仅限当前 Test/World01 的真实玩家验收开关：不新增公开配置项；官方 `ADMIN` 命令 `/agon.test.player_sandbox on|off|status` 只在专服、权威模拟、固定 Cluster 名称/描述和 `TheShard:GetShardId() == 1` 同时满足时允许开启。开关只存在内存、默认关闭；开启只传给后续新建的 `TEST_MODE` Instance，关闭会撤销现有 Instance 的 live 测试权限，重启不会继承。
- 官方运行时已验证资格状态 `enabled=false eligible=true`、命令已注册且 `permission=ADMIN`，并验证关闭态 Instance 为 `allow_live_mutation=false`、开启后新 Instance 为 `true`；这只是安全门传播证据，不替代真实客户端/UI/StateGraph/逐字段恢复结果。
- 已补做跨重启安全证据：开关开启后停服生成 snapshot `#47/#48`，同一 `Test/World01` 重启加载 `#48` 后 Runtime 输出 `enabled=false eligible=true`、`live_player_test=off`；说明开关不进入存档。服务端安全开关证据已完成，但在真实双客户端/UI、真实玩家逐字段恢复、四阶段重启矩阵和维护者结果返回前，WP10 仍不得进入 Base Ready。
- 2026-09-04 真实双客户端首次绑定时发现 SkillTree 硬门缺少官方握手接线：两个玩家的 `skilltreeupdater`/`skilltree` 存在，但 `save_enabled=false` 且项目握手标志为 false，均被正确拒绝。修复方案固定为监听官方 `ms_skilltreeinitialized` 并核对服务端 `POSTACTIVATEHANDSHAKE.READY`；修复后的真实客户端回归仍需在 `Test/World01` 重新执行。
- 2026-09-04 修复回归进一步确认两个玩家的官方状态均为 `state=3:ready=true`，但项目标志仍为 false，说明原玩家实体监听未实际接到官方事件。Runtime 已改为官方组件同型的 `TheWorld` + 玩家 source 监听，并增加 `playeractivated` 时序兜底；重启后必须再次观察 `SKILLTREE_HANDSHAKE_COMPLETE`，再继续真实 Instance 绑定。
- 2026-09-04 真实绑定在 Character Adapter 安全门处拒绝后，已按维护者选择开始实现两角色 live adapter；代码和静态检查完成后，必须先销毁残留 `agon:1:1`，重启 `Test/World01`，重新开启 live test，再按 A=`wilson`、B=`wathgrithr` 分步验证 Capture、进入沙箱、退出恢复和逐字段一致性。当前尚未把该实现计为运行 PASS。
- 2026-09-04 两角色真实沙箱回归已完成：A=`wilson`、B=`wathgrithr` 均进入 `SANDBOXED`，官方角色快照存在，A/B 的 `RemoveParticipant` 即时恢复均返回成功，Instance 清理后 `ValidateCore=true`、`instances=0`、`zones=10/free=10`、`restores=0`、`backend_pending=0`、`errors=0`。A 的延迟恢复校验失败已证实为回到大厅后的饥饿/理智/温度自然漂移，不是恢复丢失；最终 Debug 显示 live test 开关仍开启，必须先关闭再结束本轮。
- 2026-09-04 安全收尾完成：管理员关闭 live player test 后得到 `PLAYER_TEST_DISABLED` 和 `PLAYER_TEST_STATUS ... enabled=false eligible=true code=nil`。两角色 Character Adapter 的真实沙箱回归可记为限定范围 PASS，但 WP10 仍不能判定 Base Ready；真实 UI/StateGraph/网络可见性、完整 live Profile mutation、断线重绑定、四阶段重启矩阵和跨 shard 仍待验收。

### WP10 进度核对（2026-09-04）

- 真实双玩家断线重绑定已补测并通过：A=`KU_UR8pbyho` 单独断线后，在官方 SkillTree `handshake_state=3` 完成时自动输出 `PLAYER_RECONNECTED`，A 回到 `READY/SANDBOXED` 并复用原 transaction；B=`KU_aUxMQjy7` 和活动 Instance 保持正常；最终 Instance、Zone、恢复队列、Backend 队列均已清理。
- 因此，WP10 当前不再把“真实玩家断线重绑定”列为未完成项；WP10 仍保持 `WAITING_MAINTAINER`，不能宣称 `Base Ready`。
- 下一优先级为真实客户端 Spectator、GHOST、REVIVABLE_CORPSE，以及 `agon_player_classified` 的 audience/instance/generation/spectator/death 状态、StateGraph、网络可见性和相机边界观察；完成后再执行四阶段人工重启矩阵。
- 2026-09-04 真实 Spectator 首轮发现客户端输入失败：A 已获服务端 `SPECTATING`/classified 状态，但 `playercontroller:Enable(false)` 使官方相机输入路径提前返回，当前 `agon_spectator_input_layer` 还没有客户端实现；必须先补安全的“保留旋转/缩放、继续屏蔽 gameplay input”接线并复测。
- 同轮确认当前临时绑定脚本直接调用 `instance_manager:AttachPlayer()`，只完成 Participant/Sandbox 绑定，`InstanceManager:Start()` 也未移动真实 Participant 到 ScenePlan 出生点；因此 B 留在大厅是当前代码行为，但不是最终 Instance 场景验收通过，需单独补 Participant 出生/传送接线并验证大厅/Zone 边界。
- 2026-09-04 已补齐上述两条接线：客户端 Spectator 通过 classified `agon_spectator_active` 绕过官方 `DoCameraControl()` 的 disabled 早退但不恢复 gameplay input；InstanceManager 在初始启动和运行中重连时按 `ScenePlan.participant_spawn_points` 移动真实 Participant，并由 Attach 清理大厅会话。重启后的真实双客户端验证仍未完成。
- 2026-09-04 真实客户端复测确认：A 不能操作人物、相机旋转/缩放正常；初版 `camera=FOLLOW` 未实现 A 的位置持续同步到目标 B。上一版临时 classified/FocalPoint 相机接线已撤销，改为服务端 SpectatorService 周期性同步 A 的真实 Transform 到 B，静态检查和真实重启后的双客户端复测仍待完成。
- 2026-09-05 根据维护者明确要求强化 Spectator 语义：A 不是“只隐藏的视觉对象”，必须对怪物目标、普通/绕过无敌的伤害、碰撞、拾取/交易/喂食/施法、诅咒、溺水、燃烧、冻结和生存值变化均无效。已在运行时 guard 增加官方排除标签、组件级阻断包装、ActionFilter、周期性保护重置；退出时恢复原组件方法、属性、标签和显示状态，真实服务端/双客户端验证待执行。
- 2026-09-05 `RecoverOrphanedZone("small_01", "agon:1:1", ...)` 返回 `ZONE_NOT_EMPTY` 后，真实服务端只读枚举确认残留为 `flower`、`wintersfeastfuel` 和带 B userid 的 `skeleton_player`。官方 `skeleton_player` 是死亡尸体而非在线玩家；已修正 SceneService 的占用保护判定，仅以 `player` 标签或 `playercontroller` 组件拦截活跃玩家，使受控恢复可清理尸体而不会误删在线玩家。
- 2026-09-05 修复加载后，受控孤立 Zone 恢复返回 `WP10_ORPHAN_ZONE_RECOVERY_AFTER_FIX:true:ZONE_RECOVERED`；`small_01` 已安全回到 FREE。恢复基线最终只读核验通过后，继续 WP10 Spectator 硬隔离真实双客户端验收。
- 2026-09-05 恢复基线核验通过：`ValidateCore=true`、`instances=0`、10 个 Zone 全部 FREE、`pending_restore_count=0`、`backend_pending=0`、`core=READY`；`errors=2` 为历史诊断记录。继续执行 live player test 开关和新的双玩家 Spectator 硬隔离验收。
- 2026-09-05 管理员客户端重新开启 live player test，服务端返回 `PLAYER_TEST_ENABLED`；当前开始新的 B-only Instance 测试，仍按 Attach → Start → A 观战 → 硬隔离/跟随验收顺序执行。
- 2026-09-05 A=`KU_UR8pbyho` 已进入 B=`KU_aUxMQjy7` 所在的 `agon:1:2` FOLLOW 观战；服务端确认 `participant=false`、硬隔离 guard 生效、目标排除标签全为 true，初始 A/B Transform `delta=0,0`。官方 Physics 无 `IsActive()` 读接口，不能以诊断字段 nil 判定碰撞状态；下一步进行真实 B 移动后的 FOLLOW 验收。
- 2026-09-05 Spectator 最终销毁发现 `SceneService.Reset` 未清理 entity registry 之外的非玩家残留，`meat`、`turf_cave`、`yellowamulet` 和 `backpack` 导致 `SCENE_RESET_FAILED`。已将“拒绝活玩家占用 → 移除非玩家残留 → 再次确认 Zone 为空”的安全流程抽取并复用于正常 Reset 与 RecoverSnapshot；需重新加载后重新执行 Spectator 完整销毁验收。
- 2026-09-05 维护者反馈 Spectator 仍可通过鼠标左键拖拽物品绕过右键装备拦截，把物品放入装备栏并触发魔光/懒人护符等效果。后续必须补齐服务端装备、卸下、拖拽转移、丢弃、拾取、使用和制作拒绝，并在客户端隐藏/禁用物品栏、装备栏、鼠标携带物品和制作栏；即使物品已进入装备栏，所有主动/被动效果也必须无效，退出观战时恢复原状态。当前已进入实现和验证阶段。
- 2026-09-05 已加入 Spectator 物品硬隔离：Inventory、Builder、Container、InventoryItem 和 Equippable 的服务端入口按 Spectator 状态拒绝，装备效果读取返回中性值，进入观战清理当前物品并保留运行时引用/官方 OnSave 返回值，退出时恢复；客户端 PlayerHud 强制隐藏/禁用物品栏、装备栏、容器、制作栏和法术轮。真实客户端拖拽、物品效果旁路、保存不改写和退出恢复仍需在可启动的 Test 世界完成验收。
- 2026-09-05 启动新 Test/World01 时发现只输出 `STARTED` 而没有自动进入 `LAYOUT_READY/CORE_READY`；核对官方 `modutil.lua` 与 `gamelogic.lua` 后确认 `AddSimPostInit` 是在 world populate 完成、`TheWorld:PostInit()` 前执行的合适入口。已保留 `AddPrefabPostInit("world", ...)` 用于早期创建 runtime，并新增服务端 `AddSimPostInit` 调用 `runtime:OnPostInit()`，让布局/核心初始化自动接线且保持幂等。
- 2026-09-05 代码复核移除装备槽/active item 清理失败时的强制置空，避免物品孤立或遗失；清理失败时依靠中性效果 hook 与服务端入口拒绝保持安全，退出时保留重试恢复路径。当前真实验证被 Test/World01 已保存的 `HALL_TILE_MISMATCH` 阻断，未经维护者授权不得重生成地图或替换存档。
- 2026-09-05 最新代码第二次启动输出 `LOADING LUA SUCCESS`，但现有 Test/World01 仍为 `layout=FAILED:core=PENDING`；内存级 `OnPostInit` 重试返回 `HALL_TILE_MISMATCH`。已安全停服，等待是否授权在 Test/World01 重生成有效测试地图后继续 WP10 物品/装备/制作真实验收。
- 2026-09-05 已获授权重生成 Test/World01，`LAYOUT_READY/CORE_READY` 恢复且 WP4/5/6/7/9 回归通过；WP8 暴露 synthetic inventory 被 `EnterCleanState` 临时改写的问题。已改为 synthetic guard 不改底层原始 inventory，并补齐退出时方法恢复。
- 2026-09-05 重启加载修正后的代码，WP4/5/6/7/8/9 全部返回 `true:nil`，最终 `ValidateCore=true`、Instance=0、10 个 Zone 全部 FREE、`errors=0`；下一步进入真实客户端物品/装备/制作硬隔离验收。
- 2026-09-05 已接线真实 A=`KU_0vPtVpg3` 与 B=`KU_aUxMQjy7`：B 作为 Instance Participant，A 作为 Spectator 跟随 B；服务端确认 guard 已应用且 A 的 inventory `open=false/visible=false`、槽位/装备槽为空、坐标与 B 一致。下一步等待 A 客户端 UI 和输入路径确认。
- 2026-09-05 真实装备夹具再次进入观战暴露旧 Inventory wrapper 残留，返回 `SPECTATOR_PLAYER_GUARD_FAILED/INVENTORY_CLEAN_FAILED`；已改为按组件弱引用保存官方 Inventory/Builder 方法基线，避免恢复旧 wrapper 或重复套包装，需重启复测。
- 2026-09-05 已安全销毁失败测试实例、停服并重启当前修复；`LOADING LUA SUCCESS`、`LAYOUT_READY`、`RECOVERY_COMPLETE`、`CORE_READY` 全部正常。当前等待两名客户端完成重新加入，再复测真实装备夹具。
- 2026-09-05 稳定方法基线的首次实服复测仍在真实 `yellowamulet`/`orangeamulet` 装备状态下返回 `SPECTATOR_PLAYER_GUARD_FAILED`；失败后仍可观察到 Inventory wrapper 残留，不能将真实装备重入标记为通过。
- 2026-09-05 已把 Inventory/Builder 官方方法基线提前到 `Guard.Capture`，并在 `InventoryAdapter.Capture` 和 live clean 前恢复基线，同时捕获官方 `OnSave`；该修复不删除物品、不改写持久化快照。源码静态 diff 检查通过；本机没有 Lua 解释器，语法验证需依赖专服加载。
- 2026-09-05 当前新进程已重新输出 `LOADING LUA SUCCESS`、`LAYOUT_READY`、`RECOVERY_COMPLETE`、`CORE_READY`；在线查询暂只发现 A=`KU_0vPtVpg3`，需 B=`KU_aUxMQjy7` 重新进入后继续真实装备重入、服务端硬隔离、客户端 UI 和退出恢复验收。
- 2026-09-04 出生点接线首轮销毁测试暴露 `SCENE_RESET_FAILED`：真实 Participant 已位于 Zone 内，但销毁前没有统一返回 Lobby，导致 `ValidateZoneCleared()` 仍发现玩家占据 Zone；已按设计顺序补充 `Restore → Return to Lobby → Scene Reset`，需重启后复测。
- 2026-09-04 手动移回 Lobby 后销毁重试仍被第一次失败留下的 `QUARANTINED` Zone 拦截；已补充仅在 Scene Reset/空 Zone validation 完成后，允许同一 owner 受控 `QUARANTINED → RESETTING → FREE` 的 Destroy retry 与 restart recovery 路径，需重启加载并复测。
- 2026-09-04 重启后发现该失败实例快照已不存在但 `small_01` 仍为匹配 owner 的孤立 `QUARANTINED`；已补充显式孤立 Zone 恢复入口，必须先执行 RecoverSnapshot 风格的实体/Tile 清理和空 Zone validation，不能直接改 FREE。
- 2026-09-05 已将 Inventory、Builder、`OnSave` 改为持久组件级包装，并以 cleanup 标记放行内部官方清理/恢复；已重新启动新代码服务器，`CORE_READY` 正常。当前 `AllPlayers` 查询为空，必须等待 A/B 客户端回连后，才能继续真实装备重入和客户端验收，暂不能标记 WP10 物品隔离通过。
- 2026-09-05 真实硬隔离复测确认直接 `Equippable:Equip` 已返回 `false`，但物品清理后 `inventoryitem.owner` 脱离 A，导致 `GetWalkSpeedMult()` 仍返回原值；已增加按快照 `runtime_ref` 登记的弱键物品归属表，恢复成功后解除。补丁已重启加载并通过 `CORE_READY`，当前等待 A/B 回连后复测效果读取、客户端 UI 与退出恢复。
- 2026-09-05 弱键物品归属修复后的真实服务端复测通过：直接装备/Inventory/制作均被拒绝，效果读取为中性，黄护符光源和橙护符周期任务均未启动，`OnSave` 仍返回进入前捕获的数据与引用。当前仅剩 A 客户端确认物品栏、装备栏、制作栏确实隐藏且不可打开，随后执行退出恢复和最终清理。
- 2026-09-05 维护者确认 A 客户端物品栏/装备栏/制作栏隐藏且不可打开；退出后 `yellowamulet`/`orangeamulet`/`beard_sack_1` 的原槽位、装备槽和 A 归属恢复，Instance 销毁、10 个 Zone 释放、`ValidateCore=true`、`live_player_test=off`。Spectator 物品硬隔离子项完成真实双客户端验收；WP10 总 Gate 仍保留第二 shard、完整重启矩阵、真实 Backend transport 等集成未完成项。
- 2026-09-05 维护者补报退出观战后建造栏未恢复；根因是客户端隐藏时将 `craftingshown=false` 并禁用 `craftingmenu`，旧恢复路径只恢复 Inventory。已修正 `spectator_hud.lua` 的退出顺序和制作 widget 的 `Enable/Show`，需重启客户端进行回归，未将建造栏修复标记为通过。
- 2026-09-05 维护者补报观战场地出现不可交互的 A/Wilson 残影；根因是 `CreateEcho()` 把 `agon_spectator_echo` 放到了场地 spectator anchor。已修正为优先使用大厅 `lobby_return_position`，真实双客户端复测确认场地无残影、残影位于大厅，退出观战和 Instance 清理正常。
- 2026-09-05 已完成真实跨重启物品恢复复测：`agon:1:26` 按 `ABORT_ON_RESTART` 中止后，A=`KU_q87X36VY`、B=`KU_aUxMQjy7` 重连并在官方 SkillTree `handshake_state=3` 后恢复；两人队列均为 `RESTORED`，B 的 `spear_wathgrithr`、`wathgrithrhat`、`spoiled_food` 实际回到物品栏，`ValidateCore=true:nil`，随后 `c_save()` 无新增持久化错误。`EntityProfileService` 已补齐 `service_id`，活动实例校验通过；跨 shard、真实 Backend transport 和完整重启矩阵仍未完成。
- 2026-09-05 已补测真实 GHOST 行为：A=`KU_q87X36VY` 可在场地安全范围内移动，B=`KU_aUxMQjy7` 不受影响；服务端记录 `GHOST` 策略、复活和清理均正常。当前 ENDLESS 测试世界真实玩家无 `revivablecorpse` 组件，因此 REVIVABLE_CORPSE 仅计合成 WP8 诊断通过。
- 2026-09-05 已补测空 Instance 的重启矩阵：`PREPARING`、`TRANSITION`、`FINISHING` 分别保存后重启，均按 `ABORT_ON_RESTART` 中止，`aborted_on_load=1`、`instances=0`、10 个 Zone FREE、`ValidateCore=true:nil`、无新增错误；这三项是生命周期持久化边界证据，不替代带真实玩家/Scene 的完整阶段矩阵。跨 shard、真实 Backend transport 和完整故障注入仍未完成。
- 2026-09-05 已补测带真实 A=`KU_q87X36VY`、B=`KU_aUxMQjy7` 的 `TRANSITION`/`FINISHING` 重启恢复：`agon:1:33` 与 `agon:1:34` 均在官方 `handshake_state=3` 后完成玩家恢复，Instance 按 `ABORT_ON_RESTART` 中止，10 个 Zone 释放，`ValidateCore=true:nil`、无新增错误。该证据补足真实玩家阶段，但不替代第二 shard、真实 Backend transport、生产 UI 和完整故障注入验收。
- 第二 shard/cross-shard、真实 Backend transport、正式匹配/UI 和完整 live Profile mutation 仍属于未完成的集成或产品范围，不在本轮用 TestMode 结果替代。

### 建议 Commit

```text
test(base): 完成通用底座全链路集成验收
```

---

## 7. 每个 WP 的通用验证命令

根据仓库实际工具选择；不得为文档要求而全局安装新工具。

```powershell
git -c safe.directory='D:/OneDrive/DST/the-agon' status --short
git -c safe.directory='D:/OneDrive/DST/the-agon' diff --check
rg -n "SpawnPrefab\(|SetTile\(|TUNING\." scripts
```

最后两项不是要求零结果：

- `SpawnPrefab()` 只允许出现在 SpawnService 或经审核的 Base 路由内部；
- `SetTile()` 只允许出现在 TerrainService；
- `TUNING` 可以读取，但 Mode 不得全局改写；

如果系统存在兼容的 Lua 语法检查工具，可以对新增 Lua 执行语法检查；没有则不要全局安装，必须在交付中说明。

运行时验证至少保存：

- 服务端日志关键片段；
- 客户端异常或无异常说明；
- Debug command 输出；
- Instance、Zone、Scope 和 restore 的最终状态；
- 测试使用的 Layout version、Mode version 和 seed。

---

## 8. 可直接交给其他 AI Agent 的任务模板

复制以下模板，只替换 `<WP>`：

```text
请在 D:\OneDrive\DST\the-agon 中只实施 docs/base-implementation-plan.md 的 <WP>。

开始前必须完整阅读：
1. D:\OneDrive\DST\.codex\AGENTS.md
2. docs/base-design.md
3. docs/base-implementation-plan.md 中的全局工程契约、test_mode 总体规格和 <WP>
4. docs/base-implementation-logs.md

先检查 Git 状态并保护用户已有修改。涉及 DST API、Prefab、Component、Brain、StateGraph、RPC、网络、世界生成或保存时，先查询 D:\OneDrive\DST\scripts，禁止修改该目录。

新增或修改代码的自然语言注释必须统一使用中文；API、标识符及必要专有名词可保留英文，工具/类型/诊断指令例外，注释应说明意图与约束并保持适量。

不要提前实现后续 WP，不要添加当前 WP 没有调用路径的空抽象，不要把任何具体 Mode 规则写入 Core。所有代码必须通过当前 WP 的验收项；无法运行验证时，明确列出未验证内容和风险，不得声称已经完成运行验证。

完成后报告：修改内容、文件、官方源码依据、静态/运行验证、未验证项、Git 状态、建议中文 Conventional Commit，以及能否进入下一 WP；随后把同样的信息追加到 docs/base-implementation-logs.md。不要 commit 或 push。
```

本文已经固定 WorldLayout 与本地测试环境。若实际官方 API、地图边界或运行结果与这些契约冲突，执行 Agent 应保留证据并停止相关危险路径，不得静默改写正式参数。

---

## 9. 明确不属于 Base 实施的内容

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

## 10. 当前推荐的立即行动

当前可以立刻把 WP0 交给一个 Agent 执行。WorldLayout、Mod 挂载、测试 shard、存档策略和双客户端协作方式均已写入各自的实施与验收章节。

不要把多个 WP 合并成一次“大而全”的首次提交。第一批代码的合理边界是：Mod 可以安全加载、配置硬门正确、runtime 幂等创建、关闭配置时零副作用。完成该边界后再开始世界生成。
