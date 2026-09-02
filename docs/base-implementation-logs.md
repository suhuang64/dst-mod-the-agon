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

### 1.19 2026-09-02：WP5 ParticipantGroup 与 Common Services

#### 开始前核对、范围与保护

- 本次继续 WP5 前先读取了 `D:/OneDrive/DST/.codex/AGENTS.md`、`docs/base-design.md`、`docs/base-implementation-plan.md` 和本日志；同时读取了关联任务 `The Agon Mod Development` 的近期历史，再以当前工作树和官方运行结果为准。
- 当前 nested repository 为 `D:/OneDrive/DST/the-agon`，基线 HEAD 为 `3083d66 feat(isolation): 增加实例归属隔离与定向状态同步`。已有 WP4 未提交修改全部保留，本次没有重置、切分支、commit、push 或清理用户文件。
- 本次目标是完成 WP5 的 ParticipantGroup、可选 Common Services、TestMode 诊断和官方 `Test/World01` 验收；不提前实现 WP6–WP10 的完整实体定制、玩家恢复或后端能力。
- 本次修改前确认官方源码目录 `D:/OneDrive/DST/scripts` 只读；没有修改其中任何文件，也没有全局安装 Lua、Python 包或其他工具。日志文件沿用已纠正的 `docs/base-implementation-logs.md` 路径。

#### 实现内容

- `scripts/agon/core/participant.lua`：增加 Participant 的 group ID 查询、加入、移除和成员判断。
- `scripts/agon/core/participant_group.lua`：新增 Instance 内 ParticipantGroup；校验 member 必须属于同一 Instance，支持 group type、ACTIVE/CLOSED 生命周期、leader、成员元数据、可序列化 snapshot，以及同步 Participant group IDs；跨 Instance 返回 `GROUP_PARTICIPANT_INSTANCE_MISMATCH`。
- `scripts/agon/services/common_service_registry.lua`：新增稳定 service name/version/dependency 声明校验、未知服务/重复服务/版本不合法/缺失依赖拒绝、拓扑创建顺序和统一关闭；未声明的 service 不创建对应状态、task、listener、RPC 或保存数据。
- `scripts/agon/services/phase_service.lua`：实现 PREPARING、ACTIVE、RESOLVING、TRANSITIONING、ENDED，phase revision、子 PhaseScope、scope task/listener 注册和关闭清理。
- `scripts/agon/services/clock_service.lua`：保存 semantic deadline/duration，支持仅针对目标 service/Instance/Phase 的 pause/resume，并随 phase revision 记录和导出状态。
- `scripts/agon/services/decision_service.lua`：实现 `PLAYER_PRIVATE`、`GROUP_VOTE`、`GROUP_LEADER`、`INSTANCE_VOTE`、`SERVER_AUTO`，包含 `ABSTAIN`、eligible voters、重复 request/vote 拒绝、expected revision/phase revision 校验、deadline、冻结和幂等 resolve；`PLURALITY_RANDOM_TIE` 使用 Instance 的命名 `decision` RNG stream，弃权时从全部候选选择。
- `scripts/agon/services/effect_service.lua`：实现 source、target、scope、handler、priority、stack policy、Apply/Remove 和 scope cleanup；增加 stale phase revision 拒绝。Test handler 只操作 TestMode 私有计数，不定义攻击或料理属性。
- `scripts/agon/services/score_ledger.lua`：使用唯一 `event_id`，按 Participant/Group/Instance 汇总，重复 event 拒绝，freeze 后拒绝新增。
- `scripts/agon/core/instance.lua`、`scripts/agon/core/instance_manager.lua`：接入 service/group 的创建、查询、snapshot、关闭和失败回收；Instance 销毁时按 service/group/root scope/Zone 顺序清理，失败 Zone 进入隔离路径。
- `scripts/agon/modes/mode_registry.lua`：注册 Mode 时复用 CommonServiceRegistry 校验 service declaration 和依赖。
- `scripts/agon/modes/test_mode/definition.lua`、`runtime.lua`、`decisions.lua`、`effects.lua`、`wp5_diagnostics.lua`：声明 Phase/Clock/Decision/Effect/Score，创建 `COOP_TEST` group，运行两阶段、Group vote、Effect 和多条 ScoreEvent，并覆盖隔离、scope 清理、时钟、平票 RNG、声明校验、重复诊断和收口。
- `scripts/components/agon_runtime.lua`、`scripts/agon/debug/diagnostics.lua`、`modmain.lua`：接入 Common Services、GROUP audience resolver、WP5 diagnostic 入口和结果导出；没有新增未经官方 API 核对的网络端点。
- `scripts/agon/core/instance_manager.lua` 另整理了已确认的 root scope cleanup 缩进，不改变行为。

#### 官方 API 核对

- 修改前核对 `D:/OneDrive/DST/scripts/entityscript.lua`：`EntityScript:ListenForEvent`（约 1188 行）、`RemoveEventCallback`（约 1223 行）、`DoPeriodicTask`（约 1512 行）和 `DoTaskInTime`（约 1522 行），确认 PhaseScope 使用的 listener/task 注册和移除签名及官方时间调度路径。
- 核对 `D:/OneDrive/DST/scripts/usercommands.lua`：`RunTextUserCommand`（约 418 行）、serverfn 执行路径（约 339–343、468–474 行）和 `AddUserCommand`（约 516 行）；诊断入口沿用正式服务器命令/远程控制路径。
- 核对 `D:/OneDrive/DST/scripts/networkclientrpc.lua`：`AddModRPCHandler`（约 1834 行）和 `SendModRPCToServer`（约 1881 行）。WP5 未新增 RPC 业务接口，沿用 WP4 已核对的 sender、membership、revision 和 request ID 边界。
- 未修改官方源码，未依赖 `GLOBAL.assert` 绕过运行时问题；服务声明和业务失败均使用显式错误码返回。

#### 首次诊断失败及修复

- 第一次官方 WP5 诊断运行已成功加载地图，但诊断在 `wp5_diagnostics.lua:327` 失败，原文为：

  ```text
  [TheAgon] [WP5 diagnostic exception: ...]:327: attempt to index field 'ERROR_CODES' (a nil value)
  ```

- 原因是诊断脚本把模块级 `DecisionService.ERROR_CODES` 当成 service 实例字段读取；这不是官方 `assert` 缺失，也不是服务实现的运行时错误。修复为显式 require `decision_service.lua`/`score_ledger.lua` 模块并读取模块常量。
- 随后的诊断修正了 Effect 计数期望值（scope cleanup 后应为 1）和 tie RNG counter 断言（比较诊断前后 `decision` stream counter +1），并给 EffectService 增加 stale phase revision 检查。入口可在同一服务器重复执行。

#### 官方 Test/World01 环境

- 官方游戏 build：`747465`。
- 官方专服可执行文件：

  ```text
  D:/SteamLibrary/steamapps/common/Don't Starve Together/bin64/dontstarve_dedicated_server_nullrenderer_x64.exe
  ```

- 启动参数：

  ```text
  -persistent_storage_root d:/OneDrive/DST/klei -conf_dir DoNotStarveTogether -cluster Test -shard World01
  ```

- `D:/SteamLibrary/steamapps/common/Don't Starve Together/mods/the-agon` 已确认指向 `D:/OneDrive/DST/the-agon`；Master 使用 server port `12000`、shard port `11889`。
- 服务器必须从官方 `bin64` 工作目录启动；从 `D:/OneDrive/DST` 启动会因相对资源路径缺失而立即失败，本次后续运行均使用官方 bin64 工作目录。

#### WP5 诊断与两局隔离

- 修复首次诊断错误后，官方 Test/World01 运行连续完成两次 WP5 diagnostics，均输出：

  ```text
  [TheAgon] [WP5_TEST_PASS] ... WP5 diagnostics passed
  ```

- 诊断覆盖两局 Instance 的 service/group 隔离、Phase/Clock、GROUP audience、Group vote eligibility/idempotency、过期 revision、Effect handler/scope 清理、Score 重复 event/freeze、PhaseScope task/listener 清理、命名 RNG tie 复现且不消耗 loot/scene stream，以及 CommonServiceRegistry 的未知 service、重复 service、缺失依赖和非法 version 拒绝。
- 多次重复运行后的正式收口输出为：

  ```text
  WP5_CLEANUP 0 10 10 true nil
  ```

  即没有活动 Instance、10 个 Zone 全部可用、`ValidateCore=true`、无 cleanup 错误。

#### 跨重启存档验证

- 先在干净 Test/World01 中创建并启动活动 Instance，保存并正常关服；关键探针为：

  ```text
  WP5_RESTART_CREATED agon:1:1 INSTANCE_CREATED PREPARING true
  WP5_RESTART_STARTED true nil RUNNING phase_1 2 small_01
  WP5_ACTIVE_SCENE_TILE 1 4 4
  WP5_RESTART_SNAPSHOT ... 5 true true true true true RUNNING
  ```

  这确认了 5 个启用 service、活动 Phase 和 `small_01` Scene 状态进入存档。
- 第一次重启复核曾在 `VOID_TILE_MISMATCH tile_x=39 tile_z=259` 处失败。该坐标不是随机损坏：`small_01` 中心为 `(45,265)`、build size 为 13，边界最小点正是 `(39,259)`；TestMode 的合法 initial scene 会把该区域写成 DIRT，而旧逻辑在已有保存布局重启时仍执行首次世界生成用的全图 IMPASSABLE void 基线扫描，因此误把合法持久化场景判为错误。
- 已修正 `AgonRuntime:InitializeLayout`：仅在没有 `saved_layout` 的首次世界生成执行全图 void 基线扫描；重启仍校验 Portal、大厅和保存布局兼容性，并将日志信息区分为 `hall and void validation passed` 与 `hall and saved layout validation passed`。这是针对保存场景地形的边界修复，不是放宽首次生成保护。
- 修复后的活动存档重启输出为：

  ```text
  CORE_READY ... instance_count=0 ... aborted_instance_count=1
  WP5_RESTART_RECOVERED 0 1 10 10 READY READY
  WP5_RESTART_VALIDATE true nil
  ```

  即 `ABORT_ON_RESTART` 能识别并中止 active Instance，重启后没有活动局、10 个 Zone 可用且 Core 校验通过。
- 该次重启后专门继续执行 WP5 diagnostics，暴露出后续边界而非隐藏失败：

  ```text
  [TheAgon] [WP5 diagnostic cleanup failed] ...
  WP5_AFTER_RESTART_DIAG 1 9 10 true nil 1
  WP5_RESTART_CLEANUP_RETRY false SCENE_RESET_FAILED
  ```

  原因是当前 `ABORT_ON_RESTART` 已中止并丢弃运行时 Instance 对象，但尚未实现 WP9 要求的持久化活动 Scene entity、Scope、SceneTransaction 和 Zone Tile 全量清理；旧场景实体/地形仍存在时，新诊断局清理失败，Zone 被 `QUARANTINED`。这不是 WP5 通过项，已写入 plan 的 WP9 step 4，后续必须在那里完成。
- 为避免把失败场景留在 Test 存档中，按项目规则仅对 `Test/World01` 使用 `c_regenerateworld()` 重建测试世界；重建前保留了 `D:/OneDrive/DST/klei/DoNotStarveTogether/Test/World01/backup/wp5-cross-restart-before-regenerate-20260902` 备份。命令曾报告打开文件导致的 `DelDirectory ... FAILED`，但随后成功生成新的 clean session；没有删除该备份或其他用户数据。
- 重建后的干净世界中重新运行 WP5 diagnostics 两次，均通过；随后 `c_shutdown()` 正常保存并退出。最终追加启动复核（最终 source 分支）输出：

  ```text
  [TheAgon] [LAYOUT_READY] ... WorldLayout resolved; hall and saved layout validation passed
  [TheAgon] [CORE_READY] ... instance_count=0 zone_count=10 free_zone_count=10 aborted_instance_count=0
  WP5_FINAL_RELOAD READY READY 0 0 10 10 true nil
  ```

  最终关服完成两次 world serialization，目标专服进程已不存在，端口 `12000`/`11889` 均无监听。

#### 已知官方警告与错误扫描

- 以下两条官方 set-piece angle 警告仍会出现，按用户决定和既有 plan 延后，不在 WP5 伪造实体或修改官方 manager：

  ```text
  ERROR: hermitcrab_relocation_manager expected to be able to calculate the set piece angle using monkeyqueen and monkeyportal but found neither of these.
  ERROR: wagpunk_arena_manager expected to be able to calculate the set piece angle using hermitcrab_marker and beebox_hermit but found neither of these.
  ```

- 日志中已保留首次诊断的 `ERROR_CODES` nil 错误和跨重启 `SCENE_RESET_FAILED` 边界；它们分别已修复或明确归入 WP9。最终 clean reload 未新增 `attempt to`、`nil value`、`bad argument`、`LUA ERROR` 或 `stack traceback`；除上述两条既有官方 set-piece warning 外，服务加载、诊断和关服均正常。

#### 验证、文档与交付状态

- `git diff --check` 通过；仅有 Git 关于工作树 LF/CRLF 转换的提示，没有 whitespace error。
- PATH 中没有 `lua`/`luac`，因此未进行独立 Lua parser 检查，也没有为此全局安装工具；官方专服成功加载全部新增模块并完成运行诊断，承担了 Lua 模块加载和 DST API 兼容验证。
- `docs/base-implementation-plan.md` 已增加 WP5 完成状态、覆盖范围、跨重启证据、WP9 清理边界和未覆盖项；WP1 set-piece warnings 继续保持延后记录。
- 未覆盖：真实双客户端和客户端 UI/复制视觉链路、跨 shard 运行、正式玩法、完整 entity/Scene/Zone cleanup、在线/离线玩家恢复、完整恢复队列和后端 settlement。这些不应被本次 TestMode service diagnostics 冒充完成；活动 Scene 的完整清理和真实恢复仍等待 WP9。
- 本次没有 commit、push、分支操作，也没有修改官方源码。当前工作树同时包含保留的 WP4 修改与本次 WP5 修改，建议中文 Conventional Commit：

  ```text
  feat(services): 增加 ParticipantGroup 与通用玩法服务
  ```

- 进入条件：WP5 验收项和官方 Test/World01 的服务隔离、诊断、清洁重启复核已完成；可以进入 WP6/WP7 的后续开发，但 WP9 必须接收并重新验收本日志记录的活动 Scene 持久化清理边界，WP10 仍需真实客户端和完整跨系统验收。

### 1.20 2026-09-02：未覆盖验收的执行时序决定

- 针对 WP5 完成报告中“真实双客户端/UI、跨 shard、完整 WP9 恢复清理”尚未覆盖的项目，依据当前依赖关系确认：本轮不重复做完整验收，后续在对应能力实现完成后集中测试。
- 真实双客户端/UI：等待 WP7–WP8 的 PlayerSandbox、玩家进入/死亡/观战、classified/Replica 和 UI 链路完成，再按 WP10 的编号客户端脚本由维护者操作至少两个真实客户端；当前 WP5 只有服务端 TestMode 诊断，不能用假玩家替代客户端验收。
- 跨 shard：等待可用的第二 shard 测试环境；当前 Test Cluster 只有 World01，只能验证本地 Agon shard 和 `enable_agon` 硬门，不能声称完成普通 shard ↔ Agon shard 迁移、断线和迁移失败恢复。
- 完整 WP9 恢复清理：等待 WP6 与 WP8 完成后，在 WP9 实现 entity、Scope、SceneTransaction、Zone Tile、玩家恢复队列和幂等 restore/destroy，再按 PREPARING、RUNNING、TRANSITION、FINISHING 分阶段重启复测。WP5 已提前完成 active Instance 的 `ABORT_ON_RESTART` 探针，并保留了 `SCENE_RESET_FAILED` 证据作为 WP9 的明确待办。
- 本次只是计划决策和文档记录，没有新增代码、没有启动服务器、没有修改存档，也没有 commit/push。

### 1.21 2026-09-02：WP6 EntityProfileService 实现与官方 Test/World01 验收

#### 任务范围与执行规则

- 按当前 `docs/base-design.md`、`docs/base-implementation-plan.md` 进入 WP6；本条记录遵守项目约定，完整保存实现、调试、运行验证、清理和未覆盖边界，后续 Agent 必须先读本日志再继续。
- 本轮只处理实例级 EntityProfile，不处理用户已决定延后的两条官方 set-piece angle 错误，不改官方源码，不安装全局工具，不执行 commit/push。

#### 实现内容

- 新增 `scripts/agon/services/entity_profile_registry.lua`：定义并校验 profile ID/version、Prefab constraint、`SPAWN_ONLY`/`BLOCKING_ONLY`/`LIVE_SAFE`、`SERVER_ONLY`/`REPLICATED`、客户端 contract、adapter 和 child policy；拒绝未知、重复、版本不匹配和缺少 REPLICATED contract 的 Profile。
- 新增 `scripts/agon/services/entity_profile_service.lua`：每个 Instance 独立创建 service，限制 entity 必须属于当前 Instance，拒绝 GLOBAL/Lobby/其他 Instance；支持 spawn/inherited/live apply、remove/restore、display state、client contract、adapter cleanup 和 Scope resource cleanup。
- 新增 `scripts/agon/modes/test_mode/profiles.lua`：注册 6 个 TestMode Profile：flower 普通 Profile、flower REPLICATED display Profile、spider 属性强化 Profile、spider BLOCKING_ONLY brain/defensive Profile、torch 强化 Profile、torch 弱化/燃料速率 Profile。
- `EntityRegistry` 增加 profile membership、external claim、global entity 标记、`UpdateProfile` 和注销前 Profile cleanup；`SpawnService`、`SceneService`、`InstanceManager`、`CommonServiceRegistry`、`ModeRegistry`、`AgonRuntime` 接入 Profile registry/service；TestMode 增加 WP6 诊断入口和 admin command `agon.test.wp6`。
- 未使用全局 `TUNING`、全局 Prefab 改写或无条件 PostInit Hook；Profile 只在已登记的 Instance entity 上产生效果。

#### 官方源码核对

- 核对了官方 `scripts/prefabs/spider.lua`、`scripts/brains/spiderbrain.lua`、`scripts/components/health.lua`、`scripts/components/combat.lua` 的组件、`SetBrain`/`StopBrain`/`RestartBrain` 和 `defensive` 路径。
- 核对了官方 `scripts/prefabs/torch.lua`、`scripts/components/weapon.lua`、`scripts/components/fueled.lua` 的 weapon damage、fuel rate 和实体组件接口。
- 实测发现原版 `spider` 构造会产生不止一个 EntityRegistry record；因此 Profile service 不能按“一个 Spawn 只返回一个 record”实现，也不能把父 Profile 盲目应用到 Prefab/约束不匹配的同步 child。

#### 官方服务器环境

- Mod 挂载：`D:/SteamLibrary/steamapps/common/Don't Starve Together/mods/the-agon` 指向 `D:/OneDrive/DST/the-agon`。
- 服务器：`D:/SteamLibrary/steamapps/common/Don't Starve Together/bin64/dontstarve_dedicated_server_nullrenderer_x64.exe`。
- 工作目录必须是官方 `bin64`；启动参数：

  ```text
  -persistent_storage_root d:/OneDrive/DST/klei -conf_dir DoNotStarveTogether -cluster Test -shard World01
  ```

- 本轮启动时 `[LAYOUT_READY]`、`[CORE_READY]` 正常；World01 为 400×400、10 个 Zone，服务端端口 `12000`、shard 端口 `11889`。

#### 调试过程与修复

- 第一次 WP6 运行失败：`same named monster Profiles were not applied independently`。直接探针显示真实 spider 返回多个记录，父 Profile 被错误应用到不匹配的同步 child；修正 child profile resolution，只有明确 child policy 或 Prefab constraint 匹配时才继承，其他 child 保留 Instance ownership 但不套用父 Profile。
- 第二次运行失败：`same named item Profiles did not provide different behavior`。直接探针已确认物品 Profile 正常：`TEST_TORCH_POWER` 的 damage 为 `34`、fuel rate 为 `0.5`，`TEST_TORCH_LIGHT` 的 damage 为 `8.5`、fuel rate 为 `2`；失败原因只是诊断错误假设 torch 记录数必须等于 1。改为验证至少一个有效 record。
- 第三次运行暴露诊断时序问题：在 Instance 仍为 `PREPARING` 时就断言延迟 `BLOCKING_ONLY` 必须拒绝，因此该断言不成立。增加两个 Instance 的正式 `StartInstance`，确认进入 `RUNNING` 后再验证延迟 BLOCKING spawn；同时修正成功 Start 返回码应为 `nil` 的诊断断言。

#### 最终运行结果

- 官方控制台命令：

  ```text
  TheWorld.components.agon_runtime:RunWP6Diagnostics()
  TheWorld.components.agon_runtime:RunWP5Diagnostics()
  ```

- WP6 最终输出：

  ```text
  [TheAgon] [WP6_TEST_PASS] shard_id=1 operation=wp6_diagnostics core_status=READY WP6 entity profile diagnostics passed
  ```

- WP6 覆盖：A/B 两个 Instance 的同名 spider 差异化属性、同名 torch 差异化 damage/fuel 行为、`SPAWN_ONLY` 运行中重配拒绝、`BLOCKING_ONLY` 在 RUNNING 阶段拒绝、跨 Instance ownership 拒绝、原始 child entity 的 Profile/Scope 继承、REPLICATED display state/client contract、INSTANCE Audience 可见性以及 child Scope 关闭后的 Profile/entity 清理。
- WP5 回归输出：

  ```text
  [TheAgon] [WP5_TEST_PASS] shard_id=1 operation=wp5_diagnostics core_status=READY WP5 common services diagnostics passed
  ```

- 最终收口探针：

  ```text
  WP6_CLEANUP instances=0 free_zones=10 total_zones=10 profiles=6 valid=true code=nil
  ```

- 使用 `c_shutdown()` 正常关闭，完成两次 world serialization；随后确认 dedicated server 进程不存在，端口 `12000`/`11889` 无监听。
- 服务器日志仍出现两条已知官方 set-piece angle 错误：`hermitcrab_relocation_manager` 缺少 `monkeyqueen`/`monkeyportal`，`wagpunk_arena_manager` 缺少 `hermitcrab_marker`/`beebox_hermit`；按用户决定和 plan 保持延后，未伪造实体或修改官方 manager。

#### 验证与边界

- 官方专服成功加载全部新增 Lua 模块并完成 WP6/WP5 运行诊断；`ValidateCore=true`。`git diff --check` 后续需再次执行，PATH 没有 `lua`/`luac` 时不额外全局安装 parser。
- 已验证的是服务端 Profile/adapter/ownership/Scope/Audience contract；未冒充完成真实双客户端 Replica/UI/动作视觉、第二 shard、跨 shard 迁移、异步技能 child 实际生成和 WP9 的活动 Scene entity/Scope/SceneTransaction/Zone Tile 跨重启全量恢复清理。
- WP6 当前代码未提交；建议中文 Conventional Commit：

  ```text
  feat(profile): 增加实例级实体与物品定制框架
  ```

- 下一步：按依赖进入 WP7 PlayerSandbox；真实双客户端/UI 和跨 shard 继续在 WP7–WP10 的对应验收阶段执行，WP9 必须重新处理并验证 WP5 已记录的活动 Scene 清理边界。

### 1.22 2026-09-02：WP6 最终边界修正后的复测收口

- 在 1.21 记录之后又完成两项小范围安全修正：child policy 的显式 `false` 改为按 key 存在性读取；`GetProfile` 与 `GetDisplayState` 统一经过当前 Instance 的 EntityRegistry ownership/scope 校验。
- 为防止修正后只做静态判断，重新从官方 `bin64` 启动 `Test/World01`，执行：

  ```text
  TheWorld.components.agon_runtime:RunWP6Diagnostics()
  TheWorld.components.agon_runtime:RunWP5Diagnostics()
  ```

- 最终运行结果再次为：

  ```text
  [TheAgon] [WP6_TEST_PASS] shard_id=1 operation=wp6_diagnostics core_status=READY WP6 entity profile diagnostics passed
  [TheAgon] [WP5_TEST_PASS] shard_id=1 operation=wp5_diagnostics core_status=READY WP5 common services diagnostics passed
  WP6_CLEANUP_FINAL instances=0 free_zones=10 total_zones=10 profiles=6 valid=true code=nil
  ```

- 随后执行 `c_shutdown()`，World01 完成两次序列化并正常退出；复核 `PROCESS_REMAINS=False`、`PORTS_REMAINS=False`。最终日志未新增 `LUA ERROR`、`stack traceback`、`bad argument` 或 `attempt to`。
- `git diff --check` 通过；仅有 Git 关于工作树 LF/CRLF 转换的提示。PATH 中 `lua`/`luac` 均缺失，未全局安装 parser；Lua 模块加载和 API 兼容性由官方专服承担运行验证。
- 1.21 和本条记录均为 append-only；前述 WP6 实测失败及其原因没有覆盖或删除，后续 Agent 应优先参考这些已记录的真实错误。

### 1.23 2026-09-02：WP7 PlayerSandbox 实施启动记录

#### 任务范围与当前状态

- 进入 WP7 PlayerSandbox 与 PlayerProfile；目标是为 Participant 建立 `NEW → CAPTURED → SANDBOXED → RESTORING → RESTORED → COMMITTED` 事务，并在快照验证成功前禁止清空原状态。
- 当前仓库为 `D:\OneDrive\DST\the-agon`；开始检查时 `git status --short` 无输出，当前 HEAD 为 `dd01264 feat(profile): 增加实例级实体与物品定制框架`。本轮不执行 commit、push、分支切换或历史改写。
- 本轮预计新增 `scripts/agon/player/` 下的 PlayerProfile、StateAdapterRegistry、Inventory/SurvivalStats/SkillTree/Character adapters、SandboxService，并把 `player_sandbox` 接入 Instance Common Services、Participant、TestMode 和 WP7 admin diagnostics；同步保留 WP5/WP6 回归路径。

#### 官方源码依据与安全边界

- 已核对只读官方源码 `D:\OneDrive\DST\scripts\components\inventory.lua`：`OnSave` 覆盖 `items/equip/activeitem`，且通过 `GetSaveRecord` 返回实体引用；`OnLoad` 使用 `SpawnSaveRecord` 后再 `GiveItem/Equip`，不能把一个暂存表直接当作安全的在线恢复方案。
- 已核对 `health.lua`、`hunger.lua`、`sanity.lua`、`temperature.lua`、`moisture.lua` 的保存字段和恢复 setter；已核对 `skilltreeupdater.lua` 的 `save_enabled`、技能选择、XP、编码数据和 client/server activation 逻辑，技能树在握手完成前不能覆盖长期客户端状态。
- 已核对 `player_common.lua`、`petleash.lua`、`locomotor.lua` 的角色保存、宠物/跟随者和速度相关边界。真实玩家 live mutation 默认需要显式安全开关且适配器必须声明可恢复；未达到条件时拒绝进入，而不是清空后“尝试运行”。
- TestMode 采用带完整合成状态的测试玩家验证库存（背包/装备/鼠标物品/容器）、Stats、技能树、角色资源/外观、统一 Profile、退出恢复、同 transaction 重试幂等、恢复失败隔离和 Instance 清理；真实双客户端/UI、跨 shard、重启期间玩家存档恢复仍不在本次冒充完成范围。

#### 验证计划

- 先做 `rg`、`git diff --check` 和可用的静态 Lua 模块检查；PATH 没有 `lua`/`luac` 时不全局安装工具。
- 再使用官方 `Test/World01`、World01 专服端口 `12000`/`11889` 运行 `agon.test.wp7`，并回归 `agon.test.wp5`、`agon.test.wp6`、`ValidateCore` 和实例/Zone 清理；记录 Cluster/World、存档影响、进程收尾和已知官方 set-piece warnings。

### 1.24 2026-09-02：WP7 诊断失败定位与测试修正

- 第一次执行 WP7 时，预期注入的恢复失败没有进入可 inspect 状态。原因是诊断玩家仍带有 `agon_sandbox_test=true`，服务继续走合成玩家路径，不会触发缺少 live component 的确定性失败；诊断已在注入故障前显式切换为非合成玩家并清除状态，恢复重试前再还原合成测试标记。
- 第二次执行 WP7 时出现 `same transaction restore retry was not idempotent result=true code=nil state=COMMITTED attempts=2 equal=false inventory=false stats=false skilltree=false character=false speed=false`。原因不是恢复事务复制物品，而是 `MakeTestPlayer` 返回的“原始基线”与玩家当前状态共用同一个 table；进入沙箱时适配器清理直接改写了基线，比较对象已不是进入前状态。
- 已将 WP7 测试基线改为 `Util.CopyData(state)` 的独立深拷贝。该修正仅影响诊断基线，不改变正式玩家状态适配器的事务语义；随后重启专服进行完整复测。
- 本条为 append-only 记录；没有执行 commit、push 或历史改写。

### 1.25 2026-09-02：WP7 官方 Test/World01 完整验收

#### 实现范围

- 新增 `scripts/agon/player/player_profile.lua`、`sandbox_service.lua`、`state_adapter_registry.lua` 及 `adapters/` 下的 Inventory、SurvivalStats、SkillTree、默认 Character 适配器和共享工具。
- `player_sandbox` 已接入 Common Service Registry；Participant 新增 sandbox transaction ID；InstanceManager 在玩家附加、断线、移除和 Instance 清理时接入 Capture/Validate/Clean/Apply/Restore pipeline；TestMode 提供统一 PlayerProfile 和 WP7 admin/runtime diagnostics。
- SandboxService 状态包括 `NEW`、`CAPTURED`、`SANDBOXED`、`RESTORING`、`RESTORED`、`COMMITTED`、`RESTORE_PENDING` 和 `RESTORE_BLOCKED`；真实玩家 live mutation 默认关闭，SkillTree handshake 和角色恢复能力是硬门。

#### 官方专服证据

- 启动命令使用官方 `dontstarve_dedicated_server_nullrenderer_x64.exe`，Cluster=`Test`、Shard/World=`World01`，游戏版本 `747465`、Build `4239`；服务端口 `12000`，Master shard 端口 `11889`。日志出现 `CORE_READY`、`layout_status=READY`、`core_status=READY`。
- `TheWorld.components.agon_runtime:RunWP7Diagnostics()` 输出：`[TheAgon] [WP7_TEST_PASS] ... WP7 player sandbox diagnostics passed`。
- 同一进程回归 `RunWP5Diagnostics()` 输出 `WP5_TEST_PASS`，回归 `RunWP6Diagnostics()` 输出 `WP6_TEST_PASS`；`print(...ValidateCore())` 输出 `WP7_VALIDATE_CORE=true`。
- WP7 诊断实际覆盖：背包/装备/鼠标物品/嵌套容器、生命/饥饿/理智/温度/潮湿、技能 XP/点数/已激活技能/编码数据、角色资源/跟随者/宠物/召唤物/组件/外观、统一 Profile、正常恢复、重复恢复、同 transaction 失败重试、失败玩家隔离、无效技能树在清理前拒绝和 Instance/Zone 清理。

#### 收尾与边界

- 执行 `c_shutdown()` 后 World01 完成序列化快照 `#23` 和 `#24`，服务器正常退出；复核 `dontstarve_dedicated_server_nullrenderer_x64` 进程不存在，`12000/11889` 无监听端口。
- 日志只保留官方已知的两条 set-piece angle 错误（`hermitcrab_relocation_manager`、`wagpunk_arena_manager`），仍按既有决定延后；本次未修改官方源码或这些 warning 的触发条件。未发现新的 `LUA ERROR`、`stack traceback`、`bad argument` 或 `attempt to`。
- 该验收仍是无真实客户端的服务端合成状态测试；真实双客户端/UI、第二 shard、断线后重新绑定真实玩家对象及重启中止时的真实玩家存档恢复未完成，必须在 WP8–WP10/WP9 对应阶段补测。WP7 不因此冒充 Base Release Gate。
- `git diff --check` 通过；PATH 中 `lua`、`luac`、`stylua` 均缺失，未全局安装解析器；Lua 模块加载、API 兼容性和本次运行路径由官方专服验证。当前仍不执行 commit、push。

### 1.26 2026-09-02：WP7 未适配角色硬门与最终复测

- 末次代码审查发现默认 `character:*` 通配注册会让未适配角色绕过 Character adapter 选择。已改为从官方运行时 `DST_CHARACTERLIST`（无该全局时使用与当前官方源码一致的 19 个角色回退列表）逐项绑定默认 Character adapter；额外角色只能通过 `options.character_adapters` 显式注册，未知角色在 Capture 阶段返回 `INVALID_PLAYER_CHARACTER_ADAPTER`，不会进入清理状态。
- WP7 诊断新增未知角色用例：附加失败、Participant 进入 `DISCONNECTED`、玩家原始合成状态保持不变，并能独立移除；这与无效 SkillTree 的“验证失败前不清理”用例同时覆盖。
- 修改后重新启动官方专服 `Test/World01`（版本 `747465`、Build `4239`，端口 `12000`、Master shard `11889`），日志确认 `LAYOUT_READY` 和 `CORE_READY`，并输出 `WP7_TEST_PASS`、`WP5_TEST_PASS`、`WP6_TEST_PASS` 以及 `WP7_VALIDATE_CORE=true`。
- 末次 `c_shutdown()` 正常完成序列化快照 `#25`、`#26` 并退出；复核无 `dontstarve_dedicated_server_nullrenderer_x64` 进程、无 `12000/11889` 监听端口。末次日志仍只有既知的 `hermitcrab_relocation_manager` 与 `wagpunk_arena_manager` set-piece angle 错误，没有新增 Lua/runtime 错误。
- `git diff --check` 通过；没有全局安装 Lua 工具。当前仍不执行 commit、push；本条继续遵守 append-only 记录规则。

### 1.27 2026-09-02：WP8 Lobby、Spectator 与 PlayerDeathPolicy 启动

#### 任务范围与当前状态

- 本轮目标：开始实现 WP8 的 Lobby 返回点、安全恢复点、只读 Spectator、唯一 `agon_spectator_echo`、服务端观战 RPC 白名单，以及 Instance-aware 的 GHOST / REVIVABLE_CORPSE 死亡策略。
- 当前基线：WP7 已在 `86092dc feat(sandbox): 实现玩家状态沙箱与幂等恢复事务` 收口；开始本轮前 `the-agon` 工作树无未提交修改，WP1–WP7 文档和代码作为既有基线保留。
- 已核对现有代码：`LobbyService` 当前仅负责 Portal-relative 大厅 worldgen 和逐 Tile 校验；`LayoutService` 已解析 `layout.lobby` 的 Portal-relative `safe_bounds/build_bounds/hard_bounds`，但尚无运行时大厅会话；`ScenePlan/SceneService` 已提供 `spectator_anchors`、`spectator_camera_bounds`、`emergency_safe_points`；`Participant` 已有 `GHOST/CORPSE` 状态和 `death_state`，但尚无死亡策略实现。

#### 官方源码依据与设计边界

- 已核对只读官方源码：`components/revivablecorpse.lua` 通过 `corpse` 标签、`SetCanBeRevivedByFn` 和 `CanBeRevivedBy` 提供尸体救援接口；`components/spectatorcorpse.lua` 的职责是本地相机焦点，不应被当作服务端实例隔离层；`components/playercontroller.lua` 支持服务端 `Enable(false)`；官方玩家实体使用 `Physics:SetActive(false/true)`、`DynamicShadow:Enable(false/true)`、`MiniMapEntity:SetEnabled(false/true)` 和实体 Hide/Show 进行可逆保护。
- 观战者保持 Lobby/无 Participant 身份，不进入目标 Instance 的 PlayerSandbox；目标 Instance、scene revision、anchor 和 return position 全部显式记录；不硬编码“17 格”或假定世界原点。服务端拒绝跨 Instance 的 gameplay/观战目标；Echo 不添加 gameplay、AI、碰撞或持久化能力。
- `PlayerDeathPolicy` 是每个 Instance 的策略对象，死亡者仍留在 Participant 索引中；GHOST 只允许在该 Instance Zone 的安全边界内移动；REVIVABLE_CORPSE 禁止移动且救援者必须是同一 Instance 的合法活跃 Participant。WP8 首先覆盖可确定的服务端策略和合成玩家；官方全局 GameMode/StateGraph 事件链不在此处伪造，真实客户端死亡动画、观战输入、远距离网络实体可见性与 camera bounds 压测必须实服补测。

#### 验证计划

- 新增 WP8 合成 diagnostics，覆盖两个并发 Instance 使用不同死亡策略、Portal-relative Lobby 点、Spectator 无 Sandbox/唯一 Echo/退出清理、规则拒绝、Ghost 边界、Corpse 同局救援、实例销毁和 WP5–WP7 回归。
- 随后使用官方 `Test/World01` 启动、执行诊断、`ValidateCore()`、`c_shutdown()`，并确认进程和端口清理；WP1 两条已知 set-piece angle 错误继续按既有决定延后。

### 1.28 2026-09-02：WP8 第一版实现与接线

- 已新增 `scripts/agon/player/spectator_service.lua`、`death_policy.lua`、`scripts/prefabs/agon_spectator_echo.lua` 和 `scripts/agon/modes/test_mode/wp8_diagnostics.lua`；LobbyService 在既有 Portal-relative worldgen/校验上增加运行时大厅会话、有限安全点、return position、观战返回状态和清理接口。
- `AgonRuntime` 已统一创建 Lobby/Spectator；`InstanceManager` 在 Instance 销毁、Participant 移除和玩家附加时接入死亡策略；TestMode 支持通过 `CreateInstance(..., { death_mode = ... })` 选择 `GHOST` 或 `REVIVABLE_CORPSE`。死亡者继续保留在 Participant，不转成 Spectator。
- 观战者不进入 PlayerSandbox；真实玩家只施加可逆的隐藏、阴影/小地图/物理/控制器/受击保护，残影是无 gameplay、AI、碰撞和持久化能力的独立 Prefab；classified 增加 spectator state 字段，RPC 对观战 Enter/Exit/Target 单独执行目标 Instance 与会话校验。
- 修正 `agon_spectator_echo` 的官方初始化顺序：`net_string` 必须在 `SetPristine()` 前注册；同时禁止同一观战会话通过一次 Enter 请求直接切换到另一 Instance。
- 当前尚未宣称实测通过；下一步是官方 `Test/World01` 加载与 WP8 合成诊断，并回归 WP5–WP7、`ValidateCore`、`c_shutdown()`、进程/端口清理。已知两条 set-piece angle 错误仍按既有决定延后。

### 1.29 2026-09-02：WP8 第一次官方诊断失败与修正

- 官方 `Test/World01` 已成功加载新的 `agon_spectator_echo` Prefab、`CORE_READY` 和 Lobby/Spectator 服务；WP8 合成诊断完成并发 Instance、Lobby/观战进入退出、Echo 隔离、跨 Instance 访问拒绝、GHOST 边界和同局尸体救援后，在重复调用 `CompleteRevive` 的幂等断言处失败。
- 失败原因：`DeathPolicy.ResolveReviveSession` 对外部传入的旧 session table 只检查 `revive_id/instance_id`，没有确认它仍是当前 `self.revive_session`；首次完成后再次提交旧对象会继续进入配对校验并返回 `REVIVE_FAILED`，没有稳定返回 `REVIVE_NOT_FOUND`。
- 已收紧为只接受当前活动 session 的同一 `revive_id`；活动 session 已清空后，旧 session 会按不存在处理。该修正没有放宽救援权限，也没有修改玩家物品/技能状态。
- 本轮第一次服务端进程尚未收尾；修正后将重启同一官方 `Test/World01`，再执行 WP8 及 WP5–WP7 回归和完整关闭检查。

### 1.30 2026-09-02：WP8 回归暴露的 WP4 合成玩家修正

- WP8 第二次官方诊断及 WP5、WP6、WP7 回归已通过，但 WP4 在附加合成玩家时返回 `PLAYER_SANDBOX_LIVE_MUTATION_DISABLED`。原因是 WP7 引入了真实玩家 live mutation 硬门，而 WP4 旧诊断的 `MakeTestPlayer` 只有 `userid/IsValid`，没有声明 `agon_sandbox_test` 和完整 `agon_sandbox_state`；这是诊断夹具过时，不是 WP8 观战或死亡策略故障。
- 已为 `scripts/agon/modes/test_mode/wp4_diagnostics.lua` 的两个合成玩家补齐显式沙箱标记和合法的 Inventory、SurvivalStats、SkillTree、Character、movement_speed 状态，保持真实玩家默认拒绝 live mutation 的安全策略不变。
- 已对修正前的官方专服执行 `c_shutdown()`；World01 正常保存并退出，复核 `dontstarve_dedicated_server_nullrenderer_x64` 进程不存在、`12000/11889` 无监听端口。待下一次重启后重新执行 WP4–WP8 全套回归。
- 本条继续遵守 append-only 记录规则；没有执行 commit、push 或历史改写。

### 1.31 2026-09-02：WP8 官方 Test/World01 完整复测通过

#### 实现与诊断修正

- `scripts/agon/modes/test_mode/wp4_diagnostics.lua` 已为旧 WP4 合成玩家补齐 `agon_sandbox_test=true` 和完整合法 `agon_sandbox_state`；该修正只更新测试夹具，使其符合 WP7 的真实玩家 live mutation 硬门。
- WP8 的 Lobby、Spectator、Echo、Spectator RPC 白名单、GHOST 和 REVIVABLE_CORPSE 代码沿用 1.28–1.29 的实现与幂等修正；没有放宽跨 Instance 访问或真实玩家状态修改权限。

#### 官方专服证据

- 使用官方 `D:\SteamLibrary\steamapps\common\Don't Starve Together\bin64\dontstarve_dedicated_server_nullrenderer_x64.exe`，参数为 `-persistent_storage_root d:/OneDrive/DST/klei -conf_dir DoNotStarveTogether -cluster Test -shard World01`；版本 `747465`、Build `4239`，World01 端口 `12000`、Master shard 端口 `11889`。
- 新进程日志确认 `LAYOUT_READY`、`CORE_READY` 和 `agon_spectator_echo` Prefab 正常注册；通过 Runtime 正式诊断入口依次得到：`WP4_TEST_PASS`、`WP5_TEST_PASS`、`WP6_TEST_PASS`、`WP7_TEST_PASS`、`WP8_TEST_PASS`；随后 `TheWorld.components.agon_runtime:ValidateCore()` 输出 `WP8_VALIDATE_CORE=true`。
- WP8 诊断实际覆盖并发 Instance、Portal-relative Lobby 点、安全 return point、Spectator 不进入 Participant/Sandbox、唯一 Echo、跨 Instance 观战和 gameplay 拒绝、退出/Instance 清理、GHOST 边界、Corpse 同局救援、重复 `CompleteRevive` 幂等和死亡玩家恢复链路。

#### 日志与收尾

- 本次 `c_shutdown()` 正常完成 World01 序列化快照 `#31`、`#32` 并退出；复核 `dontstarve_dedicated_server_nullrenderer_x64` 进程不存在，`12000/11889` 无监听端口。
- `server_log.txt` 的本次错误扫描没有新的 `LUA ERROR`、`stack traceback`、`bad argument`、`attempt to` 或 `nil value`；仅有既有两条 set-piece angle 错误：`wagpunk_arena_manager` 找不到 `hermitcrab_marker/beebox_hermit`，`hermitcrab_relocation_manager` 找不到 `monkeyqueen/monkeyportal`。按既有计划继续延后，不处理官方源码。
- `git diff --check` 通过；PATH 仍没有 `lua`、`luac`、`stylua`，未全局安装任何工具。没有执行 commit、push、分支切换或历史改写；当前 WP8 代码和文档保持未提交，建议 Commit：

  ```text
  feat(player): 实现大厅观战与实例死亡策略
  ```

#### 尚未覆盖

- 仍未完成真实双客户端/UI 与 StateGraph 动画、跨 shard 网络路径、远距离网络实体可见性和 camera bounds 压测、真实玩家断线重绑定，以及 WP9 的重启中止/完整玩家恢复清理；这些不由本次无客户端合成诊断冒充完成。

### 1.32 2026-09-02：WP9 保存、重启中止、网络收口与后端边界启动

#### 开始前状态与执行边界

- 本轮承接 WP8，目标是落实 WP9：持久化 schema/migration、`ABORT_ON_RESTART` 恢复清理、玩家恢复队列、失败 Zone 隔离、RPC/Audience 快照收口，以及仅服务端可调用且幂等的 BackendAdapter 边界。
- 开始前 `the-agon` 工作树已有 WP8 代码和文档未提交修改；本轮保留这些修改，不执行 commit、push、分支切换或历史改写。官方 `D:\OneDrive\DST\scripts` 继续只读使用。
- 现有风险已明确：`InstanceManager:OnLoad()` 只记录并中止活动 Instance，尚未恢复 Zone/Scene；`SceneService` 尚无重启后清理入口；Sandbox 的 `RESTORE_PENDING` 尚未进入独立持久化队列；Runtime 尚未持久化恢复队列/后端 pending 状态；RPC/Audience 尚无受限 OnLoad；Instance 销毁前可能丢失未完成 restore transaction。

#### 本轮实现与验证计划

- 先补严格纯数据 schema、迁移、恢复队列和 BackendAdapter，再接入 Runtime/InstanceManager/ZoneManager/SceneService/RPC/Audience；保存内容不得包含函数、实体引用、task handle、观战会话或 UI 状态，恢复失败必须保留原始快照并进入 `RESTORE_PENDING/RESTORE_BLOCKED`，不得默认覆盖。
- `ABORT_ON_RESTART` 不恢复可玩 Instance：启动时将保存的活动 Instance 标为恢复中止，先把可恢复玩家事务加入队列，再清理 scene scope、实体和 terrain；成功清理的 Zone 释放，清理失败的 Zone 进入 `QUARANTINED` 且不可复用。
- 先运行静态差异/`git diff --check`，随后使用官方 `klei\Test\World01` 执行 WP4–WP9 回归、`ValidateCore()`、`c_shutdown()` 和进程/端口检查；另外创建一个真实保存的活动 Instance，重启同一官方专服，验证 `RECOVERY_COMPLETE/PARTIAL`、活动 Instance 不恢复、Zone 清理/隔离及 pending 快照不丢失。既有两条官方 set-piece angle 错误仍按计划延后。

### 1.33 2026-09-02：WP9 实现、官方专服回归与跨重启恢复验收

#### 实现收口与中途修正

- 新增 `scripts/agon/persistence/schema.lua`、`scripts/agon/persistence/migrations.lua`、`scripts/agon/player/restore_queue.lua`、`scripts/agon/backend/backend_adapter.lua` 和 `scripts/agon/modes/test_mode/wp9_diagnostics.lua`；Runtime、InstanceManager、ZoneManager、SceneService、RPC、Audience、Sandbox 和 diagnostics 已接入对应保存/恢复边界。
- 持久化 schema 只接受有限 Lua 纯数据，拒绝 function、实体引用、task handle、循环表、非法数字和未知 schema；v1 旧快照仅补 `persistence` envelope，不静默接受未知版本。恢复策略固定为 `ABORT_ON_RESTART`：活动 Instance 不续跑，先排队可恢复 Sandbox snapshot，再清理 Scene/Scope/entity/terrain，成功释放 Zone，失败隔离为 `QUARANTINED`。
- 恢复队列保存 transaction/profile/adapter IDs/原始 adapter snapshot 和状态；`RESTORING` 在重启加载时回到 `RESTORE_PENDING`，恢复失败进入 `RESTORE_BLOCKED`，snapshot 在验证成功前不删除。RPC/Audience 的旧 Instance、Group、Spectator 状态不恢复为有效成员；BackendAdapter 仅允许服务端提交 `game_result`/`settlement`，无 transport 时保留 `PENDING`，相同 ID 的数据不可变且重复成功提交幂等。
- 静态复核发现恢复队列原先只检查 snapshot 是 table，已补 `snapshot.adapters`、adapter ID 形状和纯数据校验，并用 protected call 包住 restore/validate；同时补充 Runtime 恢复摘要校验和 OnSave 的 core 子快照安全保留，避免可选字段异常时丢失活动 Instance 清理所需数据。

#### 官方 `klei/Test/World01` 证据

- 使用官方 `D:\SteamLibrary\steamapps\common\Don't Starve Together\bin64\dontstarve_dedicated_server_nullrenderer_x64.exe`，参数为 `-persistent_storage_root d:/OneDrive/DST/klei -conf_dir DoNotStarveTogether -cluster Test -shard World01`；版本 `747465`、Build `4239`，World01 端口 `12000`、Master shard 端口 `11889`。启动时从 WP8 的干净快照 `#32` 载入，首次 `RECOVERY_COMPLETE`/`CORE_READY` 均正常。
- 首次启动依次执行 `RunWP9Diagnostics()`、`RunWP4Diagnostics()` 至 `RunWP8Diagnostics()`，全部输出 `WP9_TEST_PASS`、`WP4_TEST_PASS`、`WP5_TEST_PASS`、`WP6_TEST_PASS`、`WP7_TEST_PASS`、`WP8_TEST_PASS`；随后 `ValidateCore()` 输出 `WP9_VALIDATE:true`。WP9 合成诊断覆盖纯数据保存/迁移/未知 schema 拒绝、恢复队列状态与重载、后端 pending/不可变/幂等边界和正式清理。
- 通过官方控制台创建并启动真实运行态 TestMode Instance：`START:true:nil:agon:1:77`。执行 `c_save()` 写入快照 `#33`，`c_shutdown()` 完成快照 `#34`、`#35` 后退出；进程和 `12000/11889` 端口均释放。
- 使用同一 Cluster/Shard/存档再次启动，日志加载快照 `#35` 并输出 `RECOVERY_COMPLETE ... aborted_instance_count=1 pending_restore_count=1 quarantined_zone_count=0`。控制台校验输出：

  ```text
  AFTER_WP9_RESTART:0:1:10:10:1:true
  ```

  字段依次表示：活动 Instance 数 `0`、中止活动 Instance 数 `1`、FREE Zone `10/10`、恢复队列 pending `1`、`ValidateCore=true`。这证明活动 Instance 未续跑、Zone 已清场，断线玩家的原始快照仍保留在恢复队列。
- 为清理本轮只用于测试的 pending 记录，确认目标为本轮新生成的快照后执行官方 `c_rollback(3)`，明确回滚并删除 `#33`–`#35`，恢复到测试前的干净 `#32`；回滚后的启动再次输出 `aborted_instance_count=0`、`pending_restore_count=0`、`free_zone_count=10`。最终控制台输出：

  ```text
  WP9_FINAL_CLEAN:0:10:10:0:0:true
  ```

  最终执行 `c_shutdown()` 完成快照 `#33`、`#34` 并正常退出；复核 `dontstarve_dedicated_server_nullrenderer_x64` 进程不存在，`12000/11889` 无监听端口。

#### 结果与边界

- 本轮 WP9 的模块加载、WP4–WP9 服务端合成回归、活动 Instance 保存/跨进程重启中止、Scene/Zone 清理、pending snapshot 保留、回滚清理和核心一致性验证通过。最新两份官方 `server_log` 未发现新的 `LUA ERROR`、`stack traceback`、`bad argument`、`attempt to call` 或 `nil value`。
- 两条既有官方 set-piece angle 错误仍出现：`hermitcrab_relocation_manager` 缺少 `monkeyqueen/monkeyportal`，`wagpunk_arena_manager` 缺少 `hermitcrab_marker/beebox_hermit`；按用户已确定的计划继续只记录、不处理官方源码。
- 尚未覆盖：真实双客户端/UI 和 StateGraph 动画、真实在线玩家各阶段断线重连后的实际物品/Stats/SkillTree 恢复、PREPARING/RUNNING/TRANSITION/FINISHING 四阶段人工重启矩阵、故障注入后的 QUARANTINED 修复、第二 shard/cross-shard、配置真实 Backend transport 的重复奖励联调，以及完整 WP10 Release Gate。服务端合成玩家和 TestMode 诊断不替代这些验收。
- `git diff --check` 通过；PATH 中没有 `lua`、`luac`、`stylua`，未全局安装解析器。没有执行 commit、push、分支操作，也没有修改官方源码；建议 Commit：

  ```text
  feat(recovery): 完成重启中止与幂等恢复结算
  ```

### 1.34 2026-09-02：WP10 Base Release Gate 验收脚本与真实玩家安全边界

#### 本轮范围

- 承接 WP9，开始进入 WP10 Base Release Gate；只处理验收编排、证据边界和维护者操作入口，不新增正式玩法架构，不改动官方 `D:\OneDrive\DST\scripts`，不执行 commit、push、分支操作或历史改写。
- 核对了当前 WP10 计划、`modmain.lua` 管理员命令、Runtime/Instance/PlayerSandbox/Spectator/Scene 接线和 `Test/World01` 的 `modoverrides.lua`。当前已有 `agon.test.wp4`–`agon.test.wp9`、`agon.instances`、`agon.zones`、`agon.recovery` 和 `agon.destroy_instance`；没有正式 TestMode 玩家 UI/匹配入口。
- 新增 `docs/wp10-client-acceptance.md`，把服务端预检、真实客户端 A/B 身份、受控 Instance 绑定、双 Instance/Scene、PlayerSandbox/观战/死亡、四阶段重启、故障注入、`enable_agon=false` 硬门和结果表写成编号脚本；后续真实执行结果仍必须追加到本日志。

#### 当前阻塞与安全判定

- `SandboxService` 的 `allow_live_mutation` 默认关闭，真实玩家进入时会返回 `PLAYER_SANDBOX_LIVE_MUTATION_DISABLED`；只有显式合成玩家才允许 WP7 诊断修改状态。本轮没有通过内部字段、管理员命令或配置绕过该门，也没有把合成玩家结果写成真实玩家通过。
- 因此 WP10 当前状态固定为“等待人工运行验收”，不能判定 `Base Ready`。是否增加严格限制在 `Test/World01`、默认关闭的真实玩家测试开关，属于会改变安全边界的单独实现决定，待确认后再做。
- 已知 `hermitcrab_relocation_manager`/`wagpunk_arena_manager` 两条官方 set-piece angle 错误继续只记录、不处理；第二 shard/cross-shard、真实 UI/StateGraph、真实玩家逐字段恢复、四阶段重启矩阵和完整故障注入仍未验证。

#### 本轮验证

- 只完成文档/代码路径核对，未启动专服、未修改 Test/World01 存档，未产生新的运行证据；WP9 的官方专服证据继续以 1.33 为准。
- 需要由维护者按 `docs/wp10-client-acceptance.md` 操作两个真实客户端并返回每项的时间、日志范围、Instance/Zone/revision/seed、客户端异常和结果；收到结果后再更新本节，不提前结论。

### 1.35 2026-09-02：WP10 服务端硬门预检、控制台入口修正与干净收口

#### `enable_agon` 硬门

- 只对 `D:\OneDrive\DST\klei\DoNotStarveTogether\Test\World01\modoverrides.lua` 临时设置 `enable_agon=false`，Mod 仍保持 `enabled=true`；使用官方 `dontstarve_dedicated_server_nullrenderer_x64.exe`、Cluster=`Test`、Shard=`World01` 启动。
- 日志在本轮启动时间 `20:30:15` 之后确认读取 `enable_agon=false`，普通世界完成加载、World01 `12000` 和 Master `11889` 正常启动；从该次启动位置没有新的 `LAYOUT_READY`、`CORE_READY`、Agon runtime 初始化或 BackendAdapter 请求。只出现既有两条官方 set-piece angle 错误；随后 `c_shutdown()` 正常完成快照 `#35`、`#36`，进程退出。
- 配置已恢复为 `enable_agon=true`，没有留下 false 状态。

#### true 配置回归与入口问题

- true 配置重启成功加载既有快照 `#36`，输出 `LAYOUT_READY`、`CORE_READY` 和 `free_zone_count=10`。用 `c_announce((function() ... runtime:RunWP4Diagnostics() ... end)())` 形式调用 Runtime，得到 `WP4_TEST_PASS`、`WP5_TEST_PASS`、`WP6_TEST_PASS`、`WP7_TEST_PASS`、`WP8_TEST_PASS`、`WP9_TEST_PASS`；随后得到 `WP10_VALIDATE:true:nil`。
- 直接把 `agon.test.wp4`–`agon.test.wp9`、`agon.instances`、`agon.zones`、`agon.recovery` 输给专服 `RemoteCommandInput`，以及加 `/` 的变体，均被当作 Lua 源码而不是 UserCommand，产生 `attempt to call a nil value`。这是本轮发现的控制台入口格式错误，不是 Agon 代码路径错误；验收脚本已改为已验证的 Runtime 表达式，并明确禁止继续使用直输格式。
- true 配置下 Runtime Debug 输出为 `schema=1 shard=1 boot=1 layout=READY v=1 core=READY offset=0,0 resolved=200,200 world=0,0 instances=0 zones=10 restores=1 backend_pending=2 errors=0`；这些 pending 是 WP9 诊断故意留下的内存测试记录，不作为干净收口证据。

#### 回滚与最终收口

- `c_shutdown()` 会把本次诊断写成快照 `#37`、`#38`；随后在同一官方专服内执行 `c_rollback(2)`，明确移除 `#37`、`#38` 并重新载入 `#36`。回滚后的日志输出 `RECOVERY_COMPLETE ... aborted_instance_count=0 pending_restore_count=0 quarantined_zone_count=0`、`CORE_READY ... instance_count=0 zone_count=10 free_zone_count=10`。
- 最终 Runtime 探针输出：

  ```text
  WP10_FINAL:schema=1 shard=1 boot=1 layout=READY v=1 core=READY offset=0,0 resolved=200,200 world=0,0 instances=0 zones=10 restores=0 backend_pending=0 errors=0:valid=true:nil
  ```

- 最后执行 `c_shutdown()` 正常生成快照 `#37`、`#38` 并退出；确认没有 `dontstarve_dedicated_server_nullrenderer_x64` 进程、`12000/11889` 无监听。Test/World01 的配置保持 `enable_agon=true`。本轮没有真实客户端加入，没有宣称 WP10 完整通过。

#### 文档与边界

- 修正 `docs/wp10-client-acceptance.md`：服务端专服控制台统一使用 Runtime 表达式，场景/启动/销毁示例不再要求直接输入未验证的 `agon.*` 字符串；明确当前真实玩家 `PLAYER_SANDBOX_LIVE_MUTATION_DISABLED` 安全边界。
- `git diff --check` 和 Markdown code fence 检查通过；未修改官方源码，未全局安装工具，未执行 commit、push、分支切换或历史改写。
- WP10 仍为“等待人工运行验收”：真实双客户端/UI、真实玩家逐字段恢复、四阶段重启矩阵、故障注入/QUARANTINED 修复、第二 shard/cross-shard、真实 Backend transport 和生产 UI 尚未完成。

### 1.36 2026-09-02：WP10 Test/World01 真实玩家验收开关实现与跨重启安全验证

#### 实现范围与安全边界

- 按已确认的测试范围实现真实玩家验收开关：只允许官方 `Test/World01` 专服、默认关闭、仅官方 `ADMIN` UserCommand 暴露给管理员；没有新增 `modinfo.lua` 公共配置，没有修改正式玩法开关，也没有修改官方参考源 `D:\OneDrive\DST\scripts` 或服务器安装目录内的官方源码。
- 新增 `scripts/agon/debug/test_gate.lua`，基于官方运行时可见的 `TheNet:IsDedicated()`、`TheNet:GetServerName()`、`TheNet:GetServerDescription()` 和 `TheShard:GetShardId()` 做资格门；当前 Test 集群指纹为 `cluster_name=󰀎荒野求生测试档󰀏`、`cluster_description=测试`、`shard_id=1`。官方 Lua 未暴露 Cluster 路径名接口，因此文档明确记录这是运行时指纹而非路径伪造。
- `AgonRuntime` 的开关只存在进程内，初始化默认 `false`，不进入 snapshot；`on` 只影响随后创建的 `TEST_MODE` Instance，生产 Mode、合成诊断、恢复队列和重启加载均不继承；`off` 会立即撤销已创建但尚未绑定玩家的 PlayerSandbox live 权限。正常 Participant/PlayerSandbox 权限链仍是必需条件。
- `modmain.lua` 新增 `/agon.test.player_sandbox status|on|off`，使用官方 `ADMIN` 权限、服务端二次资格校验和诊断结果码；客户端显示入口不等于服务端授权，非符合条件的服务端不能开启。
- 修改文件：`modmain.lua`、`scripts/agon/core/instance_manager.lua`、`scripts/agon/debug/diagnostics.lua`、`scripts/agon/debug/test_gate.lua`、`scripts/agon/player/sandbox_service.lua`、`scripts/components/agon_runtime.lua`、`docs/base-design.md`、`docs/base-implementation-plan.md`、`docs/wp10-client-acceptance.md`；本日志按规则追加本次执行记录。没有执行 commit、push、分支切换或历史改写。

#### 官方 `klei/Test/World01` 运行证据

- 约 `21:40–21:44` 使用官方 `D:\SteamLibrary\steamapps\common\Don't Starve Together\bin64\dontstarve_dedicated_server_nullrenderer_x64.exe`，参数为 `-persistent_storage_root d:/OneDrive/DST/klei -conf_dir DoNotStarveTogether -cluster Test -shard World01`；版本 `747465`、Build `4239`，World01 端口 `12000`、Master shard 端口 `11889`，`modoverrides.lua` 的 `enable_agon=true`。
- 最新代码启动后，官方控制台确认 `PLAYER_TEST_RESTART_ON_TEST:enabled=false eligible=true code=nil`，同时 Runtime Debug 为 `boot=6 ... instances=0 zones=10 restores=0 backend_pending=0 errors=0 live_player_test=off test_context=eligible`；说明干净启动默认关闭且资格门正确识别 Test/World01。
- 已验证管理员入口注册为 `registered=true permission=ADMIN params=action server_context_access=true`；开关传播回归输出 `PLAYER_TEST_PROPAGATION_FINAL2:off=false on=true disable=true:PLAYER_TEST_DISABLED existing_after_off=false destroy=true:true final=false/true`，证明开启只放行新 Instance，关闭会撤销既有服务权限并可清理。
- 再次执行 WP4–WP9 官方服务端合成回归，输出 `WP10_GATE_REGRESSION_FINAL:wp4=true:nil wp5=true:nil wp6=true:nil wp7=true:nil wp8=true:nil wp9=true:nil validate=true:nil gate=false/true`；测试产生的 Instance、恢复记录和 Backend pending 已清理，`WP10_TEST_ARTIFACT_CLEANUP` 最终为 `instances=0 zones=10 restores=0 backend_pending=0 errors=0`。
- 跨重启验证：先在当前 Runtime 执行 `SetLivePlayerTestEnabled(true)`，得到 `PLAYER_TEST_RESTART_PREPARE_ON:ok=true code=PLAYER_TEST_ENABLED enabled=true eligible=true`，随后正常停服生成 snapshot `#47/#48`；重新启动同一 `Test/World01` 并加载 snapshot `#48` 后，得到 `PLAYER_TEST_CROSS_RESTART:enabled=false eligible=true code=nil`，Runtime Debug 为 `boot=7 ... instances=0 zones=10 restores=0 backend_pending=0 errors=0 live_player_test=off test_context=eligible`。因此 `on` 没有随存档恢复，重启后的默认关闭得到运行时证据而非仅依赖代码推断。
- 最终 `c_shutdown()` 正常生成 snapshot `#49/#50` 并退出；复核 `dontstarve_dedicated_server_nullrenderer_x64` 进程不存在，`12000/11889` 无监听端口，Test/World01 配置仍为 `enable_agon=true`。
- 本轮仍只出现已知官方 set-piece angle 错误：`hermitcrab_relocation_manager` 缺少 `monkeyqueen/monkeyportal`，`wagpunk_arena_manager` 缺少 `hermitcrab_marker/beebox_hermit`；没有因此修改官方源码，也未发现本轮新增 Lua 错误。

#### 结果与未覆盖项

- WP10 的服务端安全开关、资格门、管理员入口、开关传播、默认关闭和跨重启不继承已完成并有官方 Test/World01 证据；WP10 仍不能标记为 `Base Ready`，因为真实玩家尚未实际接入。
- 尚未覆盖：真实双客户端/UI 与 StateGraph 动画、真实玩家逐字段恢复和断线重连、PREPARING/RUNNING/TRANSITION/FINISHING 四阶段人工重启矩阵、故障注入后的 `QUARANTINED` 修复、第二 shard/cross-shard、真实 Backend transport 重复奖励联调，以及最终生产 UI。合成诊断和 Runtime 控制台证据不替代这些人工验收。
- `git diff --check`、Markdown code fence、配置值和官方源码边界检查随后执行；PATH 中仍没有 `lua`、`luac`、`stylua`，未全局安装解析器。建议 Commit：

  ```text
  feat(wp10): 增加 Test/World01 真实玩家验收安全开关
  ```

### 1.37 2026-09-02：真实客户端窗口检查受 Windows 捕获接口限制

- 在完成 Test/World01 服务端验证后检查本机现有 DST 客户端：检测到一个 `dontstarve_steam_x64` 进程和一个标题为 `Don't Starve Together` 的窗口；没有关闭、重启或修改这个用户现有客户端。
- 尝试读取该窗口状态时，Windows Computer Use 的窗口激活/捕获连续返回 `SetIsBorderRequired failed: 不支持此接口 (0x80004002)`。按 UI 控制规范停止后续点击、键盘输入和登录操作，因此没有执行客户端 UserCommand、没有传输账号/密码，也没有把客户端窗口发现记作真实玩家验收通过。
- 结论：WP10 服务端安全门和跨重启证据仍以 1.36 为准；真实双客户端/UI、管理员菜单显示、真实玩家绑定和逐字段恢复仍为 `WAITING_MAINTAINER`，需要在可用的客户端窗口捕获环境中由维护者继续按 `docs/wp10-client-acceptance.md` 执行。
