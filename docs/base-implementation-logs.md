# 《天地为炉（The Agon）》Base Implementation Logs

> 本文件是 The Agon 跨任务、跨 AI Agent 的持续执行日志。
>
> 权威路径固定为 `docs/base-implementation-logs.md`。此前文件名拼写有误，本次已纠正；不要另建一个同义日志文件。
>
> 规则：本文件只允许在末尾追加；新 Agent 开始工作前必须读取本文件，并用当前仓库、官方源码和运行环境复核历史结论。日志中的测试证据不等同于尚未执行的验证。

---

## 0. 日志记录格式与长期约束

后续每个实施、调试、验证、修复或文档任务都必须在本文件末尾追加一条记录。每条记录至少包含：

- 日期和任务/WP；
- 任务目标、范围、关键假设和用户明确延后的事项；
- 开始时 Git 状态和保护用户已有修改的说明；
- 查阅的设计/计划、官方源码及其用途；
- 修改或新增文件；
- 静态检查、服务端运行、真实客户端、跨 shard 验证分别得到的结果；
- 错误原文、根因、修复和仍然存在的风险；
- 未验证项及原因；
- 运行测试使用的 Cluster/World、游戏版本、端口、进程和存档影响；
- 结束时 Git 状态、后续行动和建议中文 Conventional Commit。

不得覆盖、删除或重写旧记录；如果历史结论过期，追加一条更正记录并保留原记录。日志不得保存密码、Token 或其他秘密。官方 `D:\OneDrive\DST\scripts` 目录只读。

---

## 1. 2026-09-01：WP1 延后项确认与 WP2 实施验收

### 1.1 任务背景与用户决定

- 工作仓库为 `D:\OneDrive\DST\the-agon`，它是 `D:\OneDrive\DST` 下的独立嵌套 Git 仓库；`D:\OneDrive\DST\scripts` 是 DST 官方源码参考目录，禁止修改。
- 先前任务是 The Agon 的 WP1：专用虚空世界、大厅、Portal 和 Zone 几何校验。之后用户指出官方源码中确实存在 `assert`，并询问是否可以使用 `GLOBAL.assert`；随后报告了两个官方 manager 错误。
- 用户明确决定本轮不处理这两个官方 manager 错误，但要求把它们记入 plan，然后开始 WP2。该决定已经写入 `docs/base-implementation-plan.md` 的“WP1 延后项”。
- 本次用户进一步要求：以后所有任务都必须把执行中需要关注的细节持续保存到本日志，并把该规则写入 design 与 plan。于是本文件、`docs/base-design.md` 和 `docs/base-implementation-plan.md` 同时建立/更新了该长期规则。

### 1.2 当前项目基线

- `enable_agon` 是业务硬门；只有配置打开且当前 World 为服务端权威模拟时才启动 Agon runtime。不能用 Master/Secondary shard 名称替代该判断。
- WP1 的 WorldLayout 使用唯一运行时 `multiplayer_portal` 的实际 Tile 作为坐标锚点，不假设世界 `(0,0)` 是 Portal；当前地图为 `400x400` Tile。
- 大厅是唯一陆地区域，其余初始地图为 `WORLD_TILES.IMPASSABLE`；Zone 只保存相对 Portal 的中心偏移和三层边界，不在 WP1 生成场地。
- 当前配置有 10 个 Zone：`SMALL` 4 个、`MEDIUM` 4 个、`LARGE` 2 个。`SMALL` 的 Zone 为 `small_01` 至 `small_04`。
- WP1 已有的主要实现文件包括：`modinfo.lua`、`modmain.lua`、`modworldgenmain.lua`、`scripts/agon/bootstrap.lua`、`scripts/agon/config/world_layout.lua`、`scripts/agon/world/layout_service.lua`、`scripts/agon/world/lobby_service.lua`、`scripts/agon/debug/diagnostics.lua`、`scripts/components/agon_runtime.lua`。

### 1.3 `assert`、`GLOBAL` 与 DST Lua 环境的最终结论

- 官方 `scripts` 中可以直接看到 `assert`/`pcall`，但这不代表 Mod 的 `modmain.lua` 沙盒环境提供裸 `assert`/`pcall`。`scripts/mods.lua` 的 `CreateEnvironment` 只注入了受限白名单，包含 `pairs`、`ipairs`、`print`、`math`、`table`、`type`、`string`、`tostring`、`require`、`Class`、运行时常量以及 `GLOBAL = _G`，没有把所有 Lua 标准全局函数都暴露出来。
- 在 `modmain.lua` 中，`GLOBAL.assert` 这种方式可以访问官方全局函数；`GLOBAL.COMMAND_PERMISSION` 和 `GLOBAL.TheWorld` 也用于当前已实现的管理命令入口。
- 但通过 `require` 加载的核心模块在本次运行中实际遇到过：`variable 'GLOBAL' is not declared`。因此不能把 `GLOBAL` 访问方式机械地复制到所有 required module。核心模块改为使用其实际可用的官方 `pcall` 和 `GetTime`，并通过 DST 实服创建 Instance 验证。
- 当前新增核心代码中，`GLOBAL` 只保留在有意使用 Mod 环境桥接的 `modmain.lua`；`instance.lua` 使用直接 `pcall` 保护 Mode callback，`instance.lua`/`instance_manager.lua` 使用直接 `GetTime`（不存在时回退为 0）。
- `assert` 不是 WP2 的必要依赖；Zone、Mode、Instance 采用显式返回 `success, error_code`，避免用断言代替运行时错误处理。

### 1.4 WP1 两个官方 manager 告警：原因、影响和延后策略

运行 WP1 的纯虚空地图时，服务端出现以下两条错误：

```text
ERROR: hermitcrab_relocation_manager expected to be able to calculate the set piece angle using monkeyqueen and monkeyportal but found neither of these.
ERROR: wagpunk_arena_manager expected to be able to calculate the set piece angle using hermitcrab_marker and beebox_hermit but found neither of these.
```

核对官方源码后的结论：

- 官方 `forest` Prefab 无条件挂载 `hermitcrab_relocation_manager` 与 `wagpunk_arena_manager`。
- `hermitcrab_relocation_manager` 初始化时需要 `monkeyqueen` 与 `monkeyisland_portal`/日志中简称的 `monkeyportal` 定位官方 set piece 角度。
- `wagpunk_arena_manager` 初始化时需要 `hermitcrab_marker` 与 `beebox_hermit` 定位官方 set piece 角度。
- WP1 刻意清空官方 set piece，只保留 The Agon 的大厅和 Portal，所以这些定位实体不存在，告警是预期的兼容性告警，不是 The Agon Layout/Portal/IMPASSABLE 生成失败。
- 已观察到告警之后地图仍然完成生成，`LAYOUT_READY` 也通过；当前 WP1/WP2 不加入伪造定位实体，也不擅自修改官方 manager。
- 后续生产集成时再根据是否需要这些官方玩法，二选一：针对 The Agon 跳过 manager 初始化，或保留完整官方 set piece。该决定必须在有明确玩法需求和验证证据后追加到日志。

### 1.5 WP2 实现内容

#### Zone 与 ZoneManager

- `scripts/agon/core/zone.lua`：实现 `FREE → RESERVED → BUILDING → ACTIVE → RESETTING → FREE`，失败可进入 `QUARANTINED`；校验 owner、类别、状态和 reservation generation；以普通 table 加方法的方式实现，避免依赖受限环境中可能不存在的 `setmetatable`。
- `scripts/agon/core/zone_manager.lua`：从已解析的 WorldLayout 建立 Zone 池，按配置顺序选择相同 `zone_category` 的 FREE Zone；不跨类别分配；没有可用 Zone 返回 `NO_FREE_ZONE`；维护 Zone 摘要、快照、验证和 Debug 行。

#### Instance 与 InstanceManager

- `scripts/agon/core/instance.lua`：实现 `CREATED → PREPARING → RUNNING → TRANSITION → RUNNING → FINISHING → DESTROYING → DESTROYED`，失败路径进入 `FAILED`；非法状态转移拒绝；Mode callback 使用受保护调用；保存内容只包含纯数据。
- `scripts/agon/core/instance_manager.lua`：实现稳定 ID `agon:<shard_id>:<persistent_sequence>`，创建失败也不复用已经暴露过的序列；管理 Instance 索引、创建、启动、失败、过渡、销毁、验证、Debug 和快照。
- 创建流程先按 Mode 类别 reservation，再创建空 Instance 和 TestMode runtime；任一步失败时释放尚未构建的 reservation。
- 启动流程已修正为 Zone `RESERVED → BUILDING → ACTIVE` 与 Instance `PREPARING → RUNNING` 同步；Mode 启动失败时 Zone 进入 `QUARANTINED`，不冒险复用不确定的空间。
- Destroy 对 `RESERVED` 释放 reservation；对 `BUILDING/ACTIVE` 执行 `RESETTING → FREE`；清理或 finalize 失败时隔离 Zone；重复 Destroy 返回 `ALREADY_DESTROYED` 且不产生第二次副作用。
- 保存策略为 `ABORT_ON_RESTART`：保存 `next_sequence` 和活跃 Instance 的纯快照；重启时不恢复正在进行的玩法，只记录被中止数量，并从安全的 FREE Zone 池重新开始。WP2 不包含地形、实体、玩家或 Scope 清理，因此完整重启恢复仍需后续 WP 验证。

#### ModeRegistry 与 TestMode

- `scripts/agon/modes/mode_registry.lua`：校验 `mode_id`、正整数 `mode_version`、`SMALL/MEDIUM/LARGE` 类别、services 和 factory；拒绝重复 Mode ID 和未知/重复 service。
- `scripts/agon/modes/test_mode/definition.lua`：注册 `TEST_MODE`，version 1，请求 `SMALL` Zone，services 为空。
- `scripts/agon/modes/test_mode/runtime.lua`：只维护最小 runtime 状态；不生成 Tile、不生成实体、不加入玩家、不启用 Common Services，不假装场景功能完成。

#### Runtime、诊断与管理入口

- `scripts/components/agon_runtime.lua`：在 WP1 Layout READY 后初始化 ZoneManager、ModeRegistry、InstanceManager；提供创建/启动/销毁/验证/Debug 接口，并保存 core 快照。
- `scripts/agon/debug/diagnostics.lua`：扩展 WP2 错误码、结果码和上下文字段，统一携带 shard、Instance、Zone、Mode、lifecycle 等诊断信息。
- `modmain.lua`：通过官方 `AddUserCommand` 提供管理员入口 `agon.instances`、`agon.zones`、`agon.test.create`、`agon.test.start <instance_id>`、`agon.destroy_instance <instance_id>`；仅在 `enable_agon = true` 时注册。
- `docs/base-implementation-plan.md`：保留 WP1 延后项，并在计划前置契约、Agent 模板和完成报告要求中加入本日志的读取/追加规则。
- `docs/base-design.md`：新增工程执行记录章节，规定日志路径、append-only、验证类型区分、测试进程/存档记录和秘密信息禁止写入。

### 1.6 实施中遇到的问题与修复

1. 首次在已加载的测试服直接调用 `CreateInstance("TEST_MODE")` 时出现：

   ```text
   [string "../mods/the-agon/scripts/agon/core/instance..."]:80: variable 'GLOBAL' is not declared
   ```

   根因不是 `assert` 缺失，而是 required core module 的全局环境与 `modmain.lua` 的 Mod 环境不同。删除核心模块对 `GLOBAL.GetTime`/`GLOBAL.pcall` 的依赖，改用直接 `GetTime`/`pcall` 后，重启服务端并成功创建 Instance。

2. 初版 `InstanceManager:Start` 只推进 Instance，没有推进 Zone，实测会留下 `Instance=RUNNING`、`Zone=RESERVED`。这是不符合 WP2 Zone 状态机的实现缺陷。随后补充 `BeginBuilding`、Mode start、`Activate` 顺序，并对启动失败执行 Zone 隔离。修复后实测为 `RUNNING:ACTIVE`。

### 1.7 DST 服务端运行验证

测试环境和收尾：

- 游戏版本/build：DST `747465`。
- Cluster/World：`Test/World01`，WorldLayout version 1。
- 原默认端口 `12000` 当时由 PID `10664` 占用，未确认其归属，不得为了测试杀掉它；本次使用 `-port 12001`。
- 使用的测试命令为：

  ```powershell
  .\dontstarve_dedicated_server_nullrenderer_x64.exe -port 12001 -persistent_storage_root d:/OneDrive/DST/klei -conf_dir DoNotStarveTogether -cluster Test -shard World01
  ```

- 隔离测试服先后确认端口后停止了本次测试进程 PID `19600`、`21912`、`6972`；结束时端口 `12001` 已无监听。
- 最初默认端口失败尝试遗留 PID `18292` 的同名服务端进程；无法从当前权限可靠确认其命令行归属，本次没有擅自停止，后续 Agent 清理前必须重新确认。
- 测试服务器显示 `EnableAutosaver: false`；没有执行 `c_save()`，避免把临时测试 Instance 写入已有 `Test/World01` 存档。跨重启保存恢复因此只完成代码路径检查，未完成实服存档验收。

启动日志关键证据：

```text
[TheAgon] [STARTED] shard_id=1 schema_version=1 boot_generation=1 operation=start_server_runtime server runtime started
[TheAgon] [LAYOUT_READY] ... layout_status=READY ... map_width=400 map_height=400 ... hall and void validation passed
[TheAgon] [CORE_READY] shard_id=1 ... core_status=READY instance_count=0 zone_count=10 free_zone_count=10 aborted_instance_count=0 ...
```

第一次修复后的运行时验证结果：

| 操作 | 结果 |
| --- | --- |
| 创建第一个 TestMode | `CREATED:agon:1:1:small_01:PREPARING` |
| 启动 `agon:1:1` | `STARTED:nil:RUNNING:ACTIVE` |
| 再创建 4 次 | `agon:1:2:small_02`、`agon:1:3:small_03`、`agon:1:4:small_04`、`ERR:NO_FREE_ZONE` |
| 非法生命周期/类别请求 | `false:LIFECYCLE_TRANSITION_INVALID`、`nil:ZONE_CATEGORY_MISMATCH` |
| 启动 `agon:1:2` | `RUNNING:ACTIVE` |
| Destroy `agon:1:1` 两次 | 第一次 `true:INSTANCE_DESTROYED`，第二次 `true:ALREADY_DESTROYED`，`small_01=FREE` |
| 失败 Instance 清理 | `agon:1:3` 失败后销毁成功，`small_03=FREE`；`agon:1:2` 仍为 `RUNNING:ACTIVE` |
| 核心验证和 Zone 复用 | `ValidateCore:true`；释放后新 ID 为 `agon:1:6`，复用 `small_01` |
| Debug | 3 个未销毁 Instance、`next_sequence=6`、7 个 FREE Zone；Instance/Zone Debug 均正常输出 |

服务器日志在上述命令后没有新的 The Agon Lua stack traceback 或 `attempt to call` 错误；仍存在的两条 hermitcrab/wagpunk 官方告警属于 1.4 的明确延后项。

### 1.8 静态验证、未验证项与风险

已完成：

- 用 `git -c safe.directory=D:/OneDrive/DST/the-agon -C D:/OneDrive/DST/the-agon diff --check` 检查，未发现 whitespace error；Git 仅提示 LF/CRLF 转换警告。
- 系统 PATH 中没有可用的 `lua`/`luac`；没有全局安装任何工具。新增模块已由 DST 747465 服务端加载，且实际执行了创建、启动、销毁和 Debug 调用。
- `rg` 检查确认新增核心模块没有错误使用 `GLOBAL`；当前 `GLOBAL` 的保留位置是 `modmain.lua` 的显式 Mod 环境桥接。
- 没有修改官方 `D:\OneDrive\DST\scripts`，没有 commit、push、分支切换或清理用户代码。

尚未完成：

- 没有真实客户端加入、两个真实客户端并发、玩家加入/恢复、网络可见性或跨 shard 验证；这些属于后续 WP 的实服人工验收。
- 没有执行 `c_save()` + 重启的 `ABORT_ON_RESTART` 实服存档验证，以保护已有 `Test/World01` 存档不被临时测试状态污染；WP9/WP10 必须重新建立专用可重建存档并记录完整证据。
- 没有实现 WP3 的 ResourceScope、EntityRegistry、SpawnService、TerrainService、ScenePlan 或动态 Tile；TestMode 仍然是空场地。
- 官方两个 manager 告警未处理，原因和未来选择见 1.4。

### 1.9 任务结束时 Git 状态与后续行动

本次日志任务结束时，`the-agon` 预期状态为：

```text
 M docs/base-design.md
 M docs/base-implementation-plan.md
 M modmain.lua
 M scripts/agon/debug/diagnostics.lua
 M scripts/components/agon_runtime.lua
   ?? docs/base-implementation-logs.md
?? scripts/agon/core/
?? scripts/agon/modes/
```

后续 Agent 开始任何任务前，必须先读取本文件、设计和计划，确认当前 WP 与上述未提交修改的边界；WP1 两个官方 manager 告警继续保持延后，除非用户明确要求处理或后续设计做出正式决策。

建议 Commit（本条记录与 WP2 代码一起提交时）：

```text
feat(instance): 实现区域分配与基础实例生命周期
```

本次没有执行 commit 或 push。

### 1.10 本次日志规则落地检查

- 已在 `docs/base-design.md` 新增“工程执行记录与日志”章节；已在 `docs/base-implementation-plan.md` 的 Agent 开始前、完成报告、强制日志规则和任务模板中加入读取/追加要求。
- 已用 `rg` 交叉确认 design、plan 和本文件均引用同一权威路径 `docs/base-implementation-logs.md`。
- 已执行 `git -c safe.directory=D:/OneDrive/DST/the-agon -C D:/OneDrive/DST/the-agon diff --check`，未发现 whitespace error；仅有 Git 关于 LF/CRLF 转换的提示。
- 已执行 `git status --short`，当前未提交范围与 1.9 列出的文件一致；没有执行 commit、push、分支操作或官方源码修改。

### 1.11 2026-09-01：Git 状态复核更正

- 在本次文档规则落地后的复核中发现，WP2 代码已经存在于当前分支 HEAD：`e55bd01930f8b0512a980fb14078b4defef125e6`，提交信息为 `feat(instance): 实现区域分配与基础实例生命周期`，Commit 时间为 `2026-09-01 19:10:41 +0800`，作者为 Pepper。
- 本次 Agent 没有执行该 commit；此前 1.9 记录的是 WP2 完成时观察到的未提交状态。该外部/后续提交不回滚、不改写，作为当前仓库事实保留。
- 当前工作树实际状态为：

  ```text
   M docs/base-design.md
   M docs/base-implementation-plan.md
  ?? docs/base-implementation-logs.md
  ```

- 当前文档任务尚未提交。若单独提交本次文档变更，建议使用：

  ```text
  docs(base): 建立跨 Agent 执行日志规范
  ```

### 1.12 关于 1.10 状态描述的更正

1.10 中“当前未提交范围与 1.9 列出的文件一致”是基于 WP2 提交前状态的记录，不能作为当前 Git 状态依据；该表述由 1.11 的 `HEAD=e55bd01` 和实际 `git status --short` 结果 supersede。后续 Agent 以最近的更正记录和当前命令输出为准。

### 1.13 2026-09-01：WP2 跨重启存档恢复实服验证

#### 目标与隔离范围

- 本次专门补测此前未完成的 `c_save()` + 停止服务端 + 使用同一存档重启，以验证 WP2 的 `ABORT_ON_RESTART`、序号持久化、旧实例终止和 Zone 回收。
- 开始时 `the-agon` 的 Git 基线为 `b6f339307154ffeea9032927410f6c55a62edd53`（`docs(base): 建立跨 Agent 执行日志规范`），工作树干净。
- 为保护原 `D:/OneDrive/DST/klei/DoNotStarveTogether/Test/World01`，使用隔离临时根目录：

  ```text
  D:/OneDrive/DST/wp2-restart-test-20260901/DoNotStarveTogether/WP2Restart/World01
  ```

- 临时服务端使用游戏端口 `12002`、Master 端口 `11890`、Steam master 端口 `28020`、Steam authentication 端口 `9770`；只复制 Cluster 配置、权限文件和 `World01` 的 `server.ini`、`modoverrides.lua`、`leveldataoverride.lua`，没有复制原存档，也没有修改官方 `D:/OneDrive/DST/scripts`。
- 原 `Test/World01` 服务端端口 `12000` 全程未停止、未复用；清理时仍可观察到端口 `12000` 由同名 DST 服务端监听（PID `18292`），本次没有操作该进程。

#### 第一次启动、实例创建与保存

- 临时服务端首次启动成功，服务端进程 PID `16452`；The Agon 输出 `LAYOUT_READY`（`400x400`）和 `CORE_READY`（`instance_count=0`、`zone_count=10`、`free_zone_count=10`）。
- 官方仍输出两条既有 set-piece angle 告警：`hermitcrab_relocation_manager` 缺少 `monkeyqueen/monkeyportal`，以及 `wagpunk_arena_manager` 缺少 `hermitcrab_marker/beebox_hermit`；按 1.4 决策继续延后，不在本次处理。
- 通过服务端控制台执行并记录：

  ```text
  CREATED:agon:1:1:small_01:PREPARING
  START:true:nil:RUNNING:ACTIVE
  ```

- 执行 `c_save()` 成功，服务端输出 `Serializing world: session/094170EC991ECCB4/0000000003`。保存文件为：

  ```text
  D:/OneDrive/DST/wp2-restart-test-20260901/DoNotStarveTogether/WP2Restart/World01/save/session/094170EC991ECCB4/0000000003
  ```

  文件大小为 `1729589` bytes；对二进制文件做有界字符串检查，确认出现 `agon:1:1`、`next_sequence` 和 `ABORT_ON_RESTART`。这证明第一个运行中的实例以及重启策略确实写入了本次隔离存档。

#### 停止、重启与恢复验证

- 先确认 PID `16452` 的完整路径为 DST 的 `dontstarve_dedicated_server_nullrenderer_x64.exe`，再停止该精确 PID；端口 `12002` 随后释放。
- 使用完全相同的临时根目录、Cluster、Shard 和端口第二次启动，服务端进程 PID `19120`，日志确认加载 `session/094170EC991ECCB4/0000000003`。
- 第二次启动输出 `CORE_READY`：`instance_count=0`、`zone_count=10`、`free_zone_count=10`、`aborted_instance_count=1`。服务端控制台综合校验结果：

  ```text
  AFTER_RESTART:2:0:1:1:FREE:OLD=false:VALIDATE=true:nil
  ```

  字段含义依次为：`boot_generation=2`、当前实例数 `0`、下一序号 `1`、重启时中止的活动实例数 `1`、`small_01=FREE`、旧 ID `agon:1:1` 不存在、`ValidateCore=true`。
- 重启后再次创建 TestMode，结果为：

  ```text
  NEXT_CREATE:agon:1:2:small_01:PREPARING
  ```

  证明 `next_sequence` 没有回退，且已被中止实例占用的 `small_01` 可安全复用。随后启动并销毁该验证实例，结果为：

  ```text
  CLEANUP_INSTANCE:START=true:nil:DESTROY=true:INSTANCE_DESTROYED:COUNT=0:ZONE=FREE
  ```

- 对第二次启动的 `server_log.txt` 检查，没有新的 The Agon Lua stack traceback、`attempt to call` 或未声明变量错误；两条官方 manager 告警仍存在，属于已登记的延后项。

#### 清理、结果与限制

- 测试结论：**通过**。WP2 当前实现能够在跨进程重启后识别并中止存档中的活动实例、延续实例序号、释放 Zone，并通过核心一致性校验。
- 测试服务端 PID `19120` 已在确认完整路径后停止；端口 `12002`、`11890`、`9770` 均已无监听。
- 已删除精确临时目录 `D:/OneDrive/DST/wp2-restart-test-20260901`；其中只有本次可重建的临时配置、日志和存档，不影响原 `Test/World01` 存档。原端口 `12000` 仍保持运行。
- 本次没有真实客户端加入、双客户端并发、玩家恢复、跨 shard RPC 或地形/实体动态内容验证；这些仍需后续 WP 的人工/实服验收。
- 执行中首次使用 `New-Item -LiteralPath` 遇到当前 PowerShell 不支持该参数，立即改为等价的 `-Path` 创建临时目录；不影响仓库和原存档。
- 本次只追加本日志，没有修改 WP2 源码，没有 commit、push、分支切换或官方源码修改。测试完成后应再次执行 `git status --short` 和 `git diff --check`；若日志仍未提交，建议 Commit：

  ```text
  test(instance): 验证跨重启实例存档恢复
  ```

### 1.14 2026-09-01：修正执行日志文件名

- 用户指出执行日志文件名中的 `implemtation` 拼写错误，要求统一改为 `implementation`。
- 开始时仓库 HEAD 为 `b6f339307154ffeea9032927410f6c55a62edd53`，此前跨重启测试留下的未提交修改仅为旧日志文件本身；先读取 `.codex/AGENTS.md` 和完整日志，确认需要保留全部历史记录。
- 将日志文件从旧文件名重命名为 `docs/base-implementation-logs.md`，并同步修正 `docs/base-design.md`、`docs/base-implementation-plan.md` 以及日志文件内的权威路径引用；没有改动历史结论、WP 实现或官方源码。
- 用 `rg` 确认仓库内只保留正确的 `base-implementation-logs.md` 引用；`git diff --check` 未发现 whitespace error，仅有 Git 的 LF/CRLF 转换提示。
- 结束时未执行 commit、push 或分支操作。预期 Git 状态为：

  ```text
   M docs/base-design.md
   M docs/base-implementation-plan.md
   D docs/[旧日志文件名]
  ?? docs/base-implementation-logs.md
  ```

- 建议 Commit：

```text
docs(base): 修正执行日志文件名
```

### 1.15 2026-09-01：WP3 场景计划、地形事务与实体资源隔离

#### 执行范围与基线

- 本次开始前已读取 `.codex/AGENTS.md`、`docs/base-design.md`、`docs/base-implementation-plan.md` 和本文件；以后仍按同一规则先读后改，并在本文件末尾追加记录。
- 当前 `the-agon` HEAD 为 `e238d05ffea60535d39b61d6259c8dc88572009c`；开始 WP3 时工作树为此前 WP2 基线，结束时仅有本条 WP3 代码/文档变更，未执行 commit、push、分支切换或官方源码修改。
- 本次按用户要求改用正式存档：`D:/OneDrive/DST/klei/DoNotStarveTogether/Test`，Shard 为 `World01`，服务端端口 `12000`，Master 端口 `11889`。启动参数为：

  ```text
  -persistent_storage_root d:/OneDrive/DST/klei -conf_dir DoNotStarveTogether -cluster Test -shard World01
  ```

- 为使专服同时读取仓库中的官方脚本和游戏资源，启动工作目录使用了临时资源链接目录；持久化根始终是正式 `klei/Test`，没有复制或替换正式存档配置，也没有记录或暴露 Cluster Token。测试结束后临时目录已删除。

#### WP3 实现内容

- 新增 `ResourceScope`：统一管理 Task、Event、Entity、Cleanup 资源，支持关闭状态、generation、子 Scope、资源转移和快照。
- 新增 `EntityRegistry` 与 `agon_instance_member`：为实例实体登记 Instance/Scope/generation、分类、Profile、父实体和 spawn source，并把外部 `onremove` 纳入资源回收。
- 新增 `SpawnService`：集中使用 DST `SpawnPrefab`，通过 `entity_spawned` 事件捕获构造期间产生的子实体，再登记到实例 EntityRegistry。
- 新增 `ScenePlan`、`TerrainService`、`SceneService`：场景计划声明式校验、Portal-relative Zone 边界校验、Tile 事务、Map/MiniMap layer rebuild、实体占用检测、移动/拒绝策略、提交/回滚、场景 revision 和销毁清场。
- `TestMode` 新增初始场景、`BLOCKING_PATCH`、空地 `LIVE_PATCH`、占用拒绝和占用移动计划；增加 `agon.test.scene <instance_id> <operation>` 管理入口。
- Instance/InstanceManager/AgonRuntime 已接入场景服务；销毁流程先清实体与地形，再释放 Scene/Root Scope 和 Zone。

#### 官方 API 核对

- 复核 `D:/OneDrive/DST/scripts/mainfunctions.lua` 中 `SpawnPrefab`/`SpawnPrefabFromSim` 的构造和 `entity_spawned` 事件行为。
- 复核 `D:/OneDrive/DST/scripts/entityscript.lua` 中 `ListenForEvent`、`RemoveEventCallback`、Task、`Remove` 和 `IsValid` 的调用约定。
- 复核 `D:/OneDrive/DST/scripts/components/map.lua` 的 Tile API，并参考现有 `trade-system/scripts/arena/arena_mechanism.lua` 的 `SetTile`、Map/MiniMap `RebuildLayer` 顺序；运行时地皮写入集中在 `TerrainService`。
- 运行时 Portal 解析结果为 `portal_tile=(200,200)`、`400x400` 地图；Zone 中心使用 Portal-relative 偏移，例如 `small_01=(45,265)`、`small_02=(355,265)`。

#### 发现并修复的实现问题

- 首轮占用移动失败路径发现 `RollbackSceneTransaction` 错误引用不存在的 `SceneService.entity_registry`；已改为显式使用事务所属 Instance 的 EntityRegistry，并验证失败回滚能恢复中心 Tile 和实体位置。
- 首轮占用移动计划继承整个安全区相机边界，而目标中心 Tile 会被改为 `IMPASSABLE`；最终锚点校验因此正确拒绝该计划。已仅调整 TestMode 的移动测试计划，使替换后的相机边界避开被封锁中心 Tile，保留最终可行走性约束。
- 首轮全局校验发现已提交 ScenePlan 的 `expected_scene_revision` 是应用前置条件，不能在当前计划自检时当作过期条件；已让 `SceneService.Validate` 对当前计划执行结构/边界校验，而 `ApplyPlan` 仍严格校验 expected revision。

#### 正式 Test/World01 最终实服证据

- 启动日志输出 `LAYOUT_READY`：Portal Tile `(200,200)`、`map_width=400`、`map_height=400`；随后 `CORE_READY`：`instance_count=0`、`zone_count=10`、`free_zone_count=10`。
- 双实例初始构建通过：`agon:1:1 -> small_01`、`agon:1:2 -> small_02`，两者均 `RUNNING`、`scene_revision=1`、EntityRegistry 各有 1 个测试花实体。
- A 执行 `BLOCKING_PATCH` 成功：A revision `2`、目标 Tile 为 `10`（WOODFLOOR）；B revision 仍为 `1`、对应 Tile 为 `4`（DIRT），证明实例场景隔离。
- A 执行空地 `LIVE_PATCH` 成功：revision `3`、目标 Tile 为 `12`（CHECKER），实体数仍为 `1`。
- A 执行占用拒绝策略返回 `false:OCCUPIED_TILE`：revision 保持 `3`、中心 Tile 保持 `4`、实体仍为 `1`，证明拒绝路径不产生部分地形提交。
- A 执行占用移动策略成功：返回 `true`，revision `4`，中心 Tile 为 `1`（IMPASSABLE），花实体被移动到 Tile `(49,265)`（中心 `x+4`），实体数仍为 `1`。
- 两实例活动状态下 `ValidateCore()` 返回 `true:nil`。
- 销毁 A 成功：A Zone 为 `FREE` 且 `ValidateZoneCleared=true`；B 仍存在且为 `RUNNING`、revision `1`、中心 Tile 为 `4`；销毁后再次 `ValidateCore()` 返回 `true:nil`。
- 创建第三个实例后复用已释放槽位：`agon:1:3 -> small_01`；随后销毁 B/C，最终 `zones_free=10/10`、`instance_count=0`、`ValidateCore=true:nil`。

#### 跨重启验证

- 在正式 `Test/World01` 完成上述实例清场后停止精确测试进程，再用相同 Cluster/Shard/持久化根重启。
- 重启后控制台结果为：

  ```text
  FINAL3_RESTART instances=0:zones_free=10/10:validate=true:nil
  ```

- 这证明本轮测试结束时没有残留活动 Instance，正式 Test 重启后 Zone 池从 `FREE` 开始，底座校验仍通过。此前 WP2 专门的活动实例 `c_save()` 跨重启恢复/中止测试仍以 1.13 为准；本条是 WP3 直接正式 Test 的重启复核。

#### 静态检查、限制与清理

- `git diff --check` 通过；输出仅为 Git 的 LF/CRLF 转换提示。
- `scripts/agon` 和 `scripts/components` 中未发现 `GLOBAL`；运行时 `SpawnPrefab` 仅位于 `SpawnService`，`SetTile` 仅位于 `TerrainService`（另有既有 `lobby_service` 的初始化地形写入）。
- 本次是无真实玩家客户端的专服运行验证，未覆盖真实双客户端加入、玩家状态恢复、跨 shard RPC 和 FEAST 玩法；这些按计划留给后续 WP/人工验收。
- 两条官方 set-piece angle 报错仍出现：`hermitcrab_relocation_manager` 找不到 `monkeyqueen/monkeyportal`，`wagpunk_arena_manager` 找不到 `hermitcrab_marker/beebox_hermit`。按既有决定只记录、不在 WP3 处理。
- 已停止本轮正式 Test 服务端，确认没有 `dontstarve_dedicated_server_nullrenderer_x64` 进程，端口 `12000`/`11889` 已释放；已删除本轮创建的临时启动目录，未触碰其指向的游戏资源。正式 `Test/World01` 的服务端日志按正常运行被更新保留。
- 建议 WP3 Commit：

  ```text
  feat(scene): 实现实例场景事务与资源隔离
  ```

### 1.16 2026-09-02：WP4 隔离、Participant、InstanceRng 与定向状态通道

#### 执行范围与基线

- 本次开始前重新读取 `.codex/AGENTS.md`、`docs/base-design.md`、`docs/base-implementation-plan.md` 和本文件，并按约定把本轮过程、证据、限制和清理结果追加到本文件末尾。日志的权威文件名为 `docs/base-implementation-logs.md`；以后每个 WP 仍遵守“先读文档、再改代码、最后追加日志”的规则。
- 开始时 `the-agon` 的 Git `HEAD` 为 `a124f3c773054f34286fed5730ba1a7441f175c7`（WP3 场景事务与资源隔离提交）；工作树中没有覆盖式回滚、分支切换或 push。本次 WP4 代码保持未提交，用户已有修改未被清理。
- 按用户要求，运行验证使用正式 `D:/OneDrive/DST/klei/DoNotStarveTogether/Test/World01`，没有改用其他临时 Cluster；没有修改 `D:/OneDrive/DST/scripts` 官方源码。

#### WP4 实现内容

- 新增 `Participant`：维护 userid 与 Instance 的唯一归属、JOINING/READY/PLAYING/LEAVING/LEFT/DISCONNECTED/GHOST/CORPSE 生命周期、generation、死亡状态和可序列化快照。
- `InstanceManager` 增加 `userid → active instance_id` 索引、重复加入拒绝、玩家绑定/断线/移除、Instance 与 root owner 解析，以及统一 `RulePolicy` 入口；`Instance` 快照增加 participant 顺序和 RNG 状态。
- 新增 `RulePolicy`：按 Participant index、membership、快速归属字段和 projectile/weapon/drop/minion/trap/container 的 root owner 解析 Instance；默认拒绝无归属实体和跨 Instance 的 DAMAGE、HEAL、PICKUP、CONTAINER、PROJECTILE、TARGET、CONTROL 交互，并提供 child ownership 传播。
- 新增 `InstanceRng`：每个 Instance 使用独立 seed 和独立命名 stream 的 Park-Miller 随机流；不调用共享 `math.random`，支持 seed、stream counter 和快照。
- 新增 `AudienceStateChannel`：实现 PRIVATE、GROUP、INSTANCE、SPECTATOR、PUBLIC audience 的授权读取和 payload 可序列化/大小校验；本 WP 先实际接入 PRIVATE/INSTANCE，GROUP resolver 留待 WP5。
- 新增 `rpc.lua`、`classified.lua` 和 `agon_player_classified` Prefab：统一校验 sender、userid、Participant、Instance 生命周期、generation、scene revision、target ownership、request ID 幂等和请求速率；classified 使用官方 Network classified target、parent entity、net_uint/net_string 模式。
- Runtime 接入 player classified、audience channel、RPC 和官方 `ms_playerjoined/ms_playerleft` 生命周期监听，并兼容 Core ready 前已经存在于 `AllPlayers` 的玩家；`agon.test.wp4` 可从官方 UserCommand 路径调用诊断。
- `EntityRegistry`/`SpawnService` 扩展 parent/root owner 元数据和继承注册；`diagnostics.lua` 增加 WP4 结果码；新增 `wp4_diagnostics.lua` 覆盖两个临时 TestMode Instance 的隔离、归属、RNG、audience 和 RPC 幂等。

#### 官方 API 核对与修复

- 修改前核对了 `D:/OneDrive/DST/scripts/networkclientrpc.lua` 的 `AddModRPCHandler`、`SendModRPCToServer` 和 handler 签名，`prefabs/attunable_classified.lua` 的 classified target/parent 生命周期，`components/projectile.lua` 的 owner，`components/inventoryitem.lua` 的 `GetGrandOwner`，`net_string`/`net_uint`，`usercommands.lua` 的 UserCommand 执行路径，以及 `ms_playerjoined/ms_playerleft` 的官方监听方式。
- 首次实服诊断发现重复 RPC 未命中：请求记录写入 `requests.by_id`，重复检查却读了错误层级。已修正为检查 `requests.by_id[request_id]`，修复后重复 request ID 不再触发第二次副作用。
- 同一服务器重复运行诊断时发现临时 request/state ID 会复用；已为每次诊断加入 boot/run 递增后缀，入口可重复执行。
- 真实玩家探针发现玩家可能在 runtime Core ready 前加入，单靠 `AddPlayerPostInit` 会漏掉 classified 绑定；已补上官方玩家加入/离开监听，并在 Core ready 时扫描已有 `AllPlayers`。重启后的 hook 探针输出为 `WP4_PLAYER_HOOK true`。

#### 正式 Test/World01 实服验证

- 服务端使用官方可执行文件：

  ```text
  D:/SteamLibrary/steamapps/common/Don't Starve Together/bin64/dontstarve_dedicated_server_nullrenderer_x64.exe
  ```

- 启动参数：

  ```text
  -persistent_storage_root d:/OneDrive/DST/klei -conf_dir DoNotStarveTogether -cluster Test -shard World01
  ```

- 服务端成功加载 WP4，日志输出：

  ```text
  [TheAgon] [LAYOUT_READY] ... portal_tile_x=200 portal_tile_z=200 ... map_width=400 map_height=400
  [TheAgon] [CORE_READY] ... instance_count=0 zone_count=10 free_zone_count=10 aborted_instance_count=0
  WP4_PLAYER_HOOK true
  [TheAgon] [WP4_TEST_PASS] shard_id=1 operation=wp4_diagnostics core_status=READY WP4 isolation diagnostics passed
  ```

- 诊断覆盖：同一 userid 不能进入两个 Instance；两个相邻 Zone 的同局交互允许、跨局 DAMAGE 拒绝、无归属 PICKUP 拒绝；child/projectile root owner 解析；同 seed 同命名 stream 可复现且不同 stream 不互相消耗；PRIVATE/INSTANCE 状态可见性；有效 RPC 接受、重复 request ID 拒绝、跨局 target 拒绝。此前还通过了 `usercommands.RunTextUserCommand("agon.test.wp4", ...)` 的正式管理命令路径和 `WP4_COMMAND_REGISTERED true` 探针。
- 首次真实玩家 classified 探针曾因加入时序得到未绑定结果，随后用手动 `OnPlayerAdded` 验证了 Prefab/net 字段创建，再加入生命周期监听修复。修复后的最新启动已验证 hook 注册和 WP4 诊断；该次启动没有真实客户端在线（`WP4_PLAYERS 0`），因此客户端实际复制到 UI 的完整视觉链路和修复后真实玩家自动绑定仍未完成端到端验证。
- 本次服务端运行结束前执行 `c_shutdown()`，服务端完成两次存档序列化并正常退出；随后检查不到目标服务端进程，端口 `12000`/`11889` 无监听。`server_log.txt` 的最后扫描只有 The Agon 的 STARTED、LAYOUT_READY、CORE_READY、WP4_TEST_PASS，以及下述两条既有官方警告，没有新的 Lua traceback、`attempt to call`、`nil value` 或 `bad argument`。

#### 静态检查、限制与清理

- `git diff --check` 通过，输出仅为 Git 的 LF/CRLF 转换提示；新增代码中的自然语言注释已统一为中文。没有可用的 PATH Lua/Luac 语法检查器，因此没有全局安装工具；本次正式专服加载和诊断同时承担 Lua 模块加载/API 兼容验证。
- 本次没有真实双客户端并发、跨 shard RPC、客户端视觉 UI、正式玩法、ParticipantSandbox、ParticipantGroup、Common Services、Profile 或完整玩家恢复验证；这些按 WP 边界留给后续 WP。WP4 自身不恢复带玩法的 active Instance，恢复逻辑仍由 WP9 的 `ABORT_ON_RESTART`/restore 流程负责。
- 关于此前“暂未单独执行跨重启存档恢复测试”的标注：WP2 已在 1.13 用隔离存档完成 active Instance 的 `c_save()`、停止、同存档重启、中止、序号延续和 Zone 回收；WP3 已在 1.15 对正式 `Test/World01` 完成清场后的重启复核。WP4 本身没有重复伪造一套 active Instance restore 测试，因为它没有新增恢复实现；后续 WP9 仍需针对网络/Participant 恢复队列做专门验证。
- 两条官方 set-piece angle 警告仍为：`hermitcrab_relocation_manager` 找不到 `monkeyqueen/monkeyportal`，`wagpunk_arena_manager` 找不到 `hermitcrab_marker/beebox_hermit`。按既有计划只记录、不处理。
- 本次没有 commit、push、分支操作，也没有修改官方源码。当前 WP4 代码处于未提交工作树，建议 Commit：

  ```text
  feat(isolation): 增加实例归属隔离与定向状态同步
  ```

### 1.17 2026-09-02：WP4 验收项逐项覆盖度复核

- 本次根据 `scripts/agon/modes/test_mode/wp4_diagnostics.lua`、`scripts/agon/core/rule_policy.lua`、`scripts/agon/net/rpc.lua` 和 1.16 实服记录复核验收项；本次只读审计，没有修改代码、启动服务器或改变存档。
- 同一玩家不能加入两个 Instance：**已验证**。诊断创建两个临时 Instance 并绑定两个 userid，再用已占用 userid 创建第二个 Instance，结果被拒绝。
- 两个相邻 Zone 不能跨局攻击、拾取或访问容器：**部分验证**。已在正式 Test shard 运行跨 Instance `DAMAGE` 拒绝；另验证了无归属实体的 `PICKUP` 拒绝，但没有在诊断中分别运行“跨 Instance PICKUP”和“跨 Instance CONTAINER”的目标实体案例。`RulePolicy` 已提供通用 `CanPickup`/`CanOpenContainer` 别名和相同 Instance 检查，但这两条仍需补运行证据。
- projectile/drop 继承 root owner Instance：**部分验证**。诊断使用 synthetic child/projectile owner 验证 membership 和 root owner 解析；`EntityRegistry`/`SpawnService` 已实现继承字段，但尚未用真实 DST projectile、drop 或 container item Prefab 完成运行时案例。
- 无归属实体默认不能被 Mode 控制：**部分验证**。已验证无归属 `PICKUP` 被拒绝，且 `CanControl` 在策略代码中默认要求同 Instance；尚未在 TestMode 诊断中直接执行 `CONTROL` action 的无归属案例。
- 同 seed 同 stream 可复现、不同 stream 不互相消耗：**已验证**。诊断比较相同 seed/`loot` stream 的八个结果，并在消耗 `scene` stream 后确认 `loot` 序列不变。
- PRIVATE 不发给其他玩家、INSTANCE 不发给其他 Instance：**服务端 audience 可见性已验证**。诊断用两个 Participant 的 `ReadFor` 检查 PRIVATE 和 INSTANCE 均不泄漏；最新启动没有真实客户端，因此客户端网络复制和 UI 展示仍未完成端到端验证。
- 重复 request ID 不产生第二次副作用：**重复请求拦截已验证，实际副作用计数尚未验证**。诊断确认第二次 `Rpc:Handle` 返回 `RPC_DUPLICATE_REQUEST`；当前诊断 RPC 没有配置实际 `dispatch_fn`/副作用计数器，所以未直接观测“业务副作用只执行一次”。代码路径在 dispatch 成功后才记录 request，重复检查发生在 dispatch 前。
- 结论：1.16 的日志已如实记录了已运行的 DAMAGE、unowned PICKUP、server-side audience 和 duplicate rejection；本条补充了不能冒充完整验收的缺口。WP4 在进入 Base Ready 前仍应补充跨局 PICKUP/CONTAINER、CONTROL、真实 projectile/drop 和带 dispatch counter 的 RPC 诊断，并安排真实客户端 classified 复制测试。

### 1.18 2026-09-02：WP4 当前 Git 状态核对

- 本次复核读取 Git 时确认 WP4 代码及 1.16 执行记录已位于 `ba7a6cf feat(isolation): 增加实例归属隔离与定向状态同步`；本次验收项复核没有执行 commit、push 或代码修改。
- 当前工作树只包含本次新增的 1.17/1.18 日志复核内容；后续 Agent 应以 `ba7a6cf` 作为 WP4 已提交基线，并继续补齐 1.17 列出的未覆盖运行验收。
