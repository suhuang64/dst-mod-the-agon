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
