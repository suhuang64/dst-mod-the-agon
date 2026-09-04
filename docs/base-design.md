# 《天地为炉（The Agon）》Base Design

> **定位**：The Agon 公共底座的最终基础设计。
>
> **本阶段包含**：指定 shard 激活、专用世界生成、大厅与 Zone、Instance、Participant、ParticipantGroup、Spectator、玩家状态沙箱、死亡策略、分层资源作用域、动态场景事务、可选通用玩法服务、实体定制、隔离、保存恢复、网络和后端适配边界。
>
> **本阶段不包含**：具体匹配算法和 UI、FEAST 关卡、PVE 怪物与 Wave、BR 的具体 PvP 实现、奖励数值、Flask API 细节。

---

## 0. 工程执行记录与日志

除产品边界外，本项目还必须保留可供后续维护者和 AI Agent 读取的执行上下文。权威执行日志固定为 `docs/base-implementation-logs.md`；不得另起同义日志文件分散记录。

以下规则适用于后续所有实施、调试、验证、修复和文档变更任务：

1. 开始任务前完整读取 `D:\OneDrive\DST\.codex\AGENTS.md`、本设计、实施计划和执行日志，并以当前仓库与当前运行证据复核历史结论。
2. 修改前记录本次任务目标、范围、涉及文件、关键假设、官方源码依据和验证方法；发现会实质影响实现的不确定性时先停止危险路径。
3. 任务结束后必须在执行日志末尾追加一条记录，至少包含时间、任务/WP、修改内容、验证命令或运行证据、未验证项、风险、遗留决定、Git 状态和建议 Commit 信息。没有代码修改也要记录原因与验证结果。
4. 执行日志是 append-only 证据，不得覆盖、重写或删除既有记录；历史记录与当前代码冲突时，保留冲突并记录重新核验结果，不得静默改写历史。
5. 日志必须区分静态检查、服务端运行验证、真实客户端验证、跨 shard 验证和未验证内容；不能用其中一种验证替代另一种，也不能把计划目标写成已完成事实。
6. 记录服务端测试时必须写明 Cluster/World、游戏版本、端口、存档影响和进程收尾情况；涉及用户已有服务或存档时，只能操作已确认属于本次测试的目标。
7. 日志不保存密码、Token 或其他秘密；路径、错误信息、ID 和必要的诊断输出可以记录。

---

## 1. 已确定的产品形态

The Agon 是 Cluster 中一个独立的专用 shard。玩家从其他 shard 跳转进来，在大厅选择模式并匹配；匹配成功后，同一批玩家被送入某个 Zone，创建一局独立的 Instance。游戏结束后，玩家恢复进入比赛前的状态并回到大厅。

同一个 The Agon shard 可以同时运行多个 Instance：

```text
大厅
├── Zone A → FEAST Instance #101
├── Zone B → DUNGEON Instance #102
└── Zone C → 未来其他模式 Instance #103
```

服务器天数、时钟和正常世界更新持续运行。Instance 不能暂停世界，也不能为了某一局修改全世界季节、时间或其他全局规则。

### 1.1 三个核心概念

- `GameMode`：玩什么。它是规则插件，例如 `FEAST`、`DUNGEON`、`BATTLE_ROYALE`。
- `Instance`：哪一局。它拥有这一局的玩家、状态、实体、任务、结果和生命周期。
- `Zone`：在哪里玩。它是固定坐标范围内可反复租用的物理空间。

三者必须始终分离：

```text
GameMode Definition 1 ─┬─ Instance A ── Zone A
                       └─ Instance B ── Zone B
```

同一种 GameMode 可以同时创建多局。Zone 通过 `zone_category` 表示物理尺寸级别，固定为 `SMALL`、`MEDIUM` 或 `LARGE`；GameMode 只声明自己需要的尺寸，不把 `FEAST`、`PVP` 等玩法名称写成 Zone 类别。

### 1.2 强制红线

1. GameMode 只能改变自己的 Instance 和 Zone，不能直接控制整个 `TheWorld` 的玩法状态。
2. Zone、Instance、GameMode 的职责、生命周期和保存数据不得混用。
3. 新模式不得自行重做玩家沙箱、实体登记、作用域清理、动态场景事务、死亡框架、RPC 校验和结算接口；通用服务必须优先复用公共实现。
4. 一局结束只销毁该 Instance，不执行 World Reset。
5. 一个 `userid` 同时最多属于一个 active Instance。
6. 一个 Zone 同时最多租给一个 Instance。
7. 所有受管实体、任务、监听器、效果、决策和地形修改都必须能解析到唯一 Instance 和 ResourceScope。
8. Mode 可以按需启用 Common Services，但不得绕过公共服务的权限、归属和清理边界。

---

## 2. Shard 激活

### 2.1 Mod 配置

`modinfo.lua` 只需要一个布尔配置：

```lua
enable_agon = false
```

Mod 在所有 shard 中均保持 `enabled = true`，仅在目标 shard 的 `modoverrides.lua` 中配置：

```lua
configuration_options = {
    enable_agon = true,
}
```

DST 会为各 shard 分别读取 `modoverrides.lua` 的 `configuration_options`。运行时使用 `GetModConfigData("enable_agon")` 读取当前 shard 的值。

### 2.2 启动硬门

`modmain.lua` 中客户端需要的 prefab、classified 和 RPC 定义应无条件注册；只有服务器业务 bootstrap 才经过硬门：

```lua
local function StartAgonServerRuntime(world)
    if not GetModConfigData("enable_agon") or not world.ismastersim then
        return
    end

    world:AddComponent("agon_runtime")
end
```

`ismastersim` 表示当前 shard 的服务端权威模拟，不表示 `Cluster` 的 `Master shard`；`Master/Secondary` 身份不得作为 Agon 启用条件。

不要在这些共享注册完成前从 `modmain.lua` 顶层提前返回，否则目标 shard 的客户端功能可能缺失。`modworldgenmain.lua` 也必须读取同一个开关，避免改变其他 shard 的地图生成。

`enable_agon = false` 的 shard 不得创建：

- `AgonRuntime`；
- `InstanceManager`、`ZoneManager`；
- 世界事件监听和周期任务；
- Zone 扫描和 GameMode 运行时；
- 后端请求。

不要用 `TheWorld.ismastershard`、`TheShard:IsSecondary()` 或 shard 名称猜测是否为 Agon 世界。业务角色只由 `enable_agon` 决定；`TheShard:GetShardId()` 仅用于日志、ID 命名空间和后端记录。

---

## 3. 专用世界与地图生成

### 3.1 地图形态

The Agon 使用专门的世界生成方案：

- 大厅是固定陆地区域；
- 除大厅外，整张地图初始均为 `WORLD_TILES.IMPASSABLE`，即不可通行虚空，不是海洋；
- Zone 只在配置中预留中心和边界，世界生成时不生成 Zone 地面；
- Instance 创建时才在所选 Zone 内用 `change_tile()` 构建场地；
- Instance 结束后删除场地实体，并把 Zone 内 Tile 全部恢复为 `WORLD_TILES.IMPASSABLE`；
- 地图尺寸必须足够容纳大厅、所有预留 Zone 和它们之间的安全间隔；
- 所有配置坐标必须落在生成地图的有效 Tile 范围内。

```text
┌──────────────────── WORLD MAP ────────────────────┐
│                 IMPASSABLE VOID                   │
│       ┈ Zone A ┈              ┈ Zone B ┈          │
│       （预留槽位）             （预留槽位）          │
│                                                   │
│                    ┌────────┐                     │
│                    │ Lobby  │                     │
│                    │ Portal │                     │
│                    └────────┘                     │
└───────────────────────────────────────────────────┘
```

只有大厅和 Portal 是世界生成结果。Zone 的位置存在于配置和 ZoneManager 中，但空闲时在地图上只是虚空，不应存在残留地面、实体或小地图图层。

### 3.2 Layout 配置

正式静态定义使用“相对 Portal 实际 Tile 的偏移坐标”。世界生成不假设地图中心的世界坐标是 `(0, 0)`；运行时先读取唯一 Portal 的实际 Tile 坐标，再解析 Lobby 和所有 Zone 的实际中心。世界坐标由统一转换器使用 `TILE_SCALE` 转换，Mode 和 Service 不得各自换算：

```lua
WorldLayoutDefinition = {
    layout_version = 1,
    world_size_tiles = { width = 400, height = 400 },
    coordinate_unit = "TILE_OFFSET_FROM_PORTAL",

    lobby = {
        center_offset = { x = 0, z = 0 },
        safe_size = { width = 9, height = 9 },
        build_size = { width = 11, height = 11 },
        hard_size = { width = 15, height = 15 },
        portal_prefab = "multiplayer_portal",
        spawn_and_return_points = {
            { x = 3, z = 0 }, { x = -3, z = 0 },
            { x = 0, z = 3 }, { x = 0, z = -3 },
            { x = 2, z = 2 }, { x = 2, z = -2 },
            { x = -2, z = 2 }, { x = -2, z = -2 },
        },
        terrain_layout = "MAXWELL_RITUAL_HALL_V1",
    },

    zone_sizes = {
        SMALL = {
            safe_size = { width = 11, height = 11 },
            build_size = { width = 13, height = 13 },
            hard_size = { width = 17, height = 17 },
        },
        MEDIUM = {
            safe_size = { width = 29, height = 29 },
            build_size = { width = 31, height = 31 },
            hard_size = { width = 35, height = 35 },
        },
        LARGE = {
            safe_size = { width = 121, height = 61 },
            build_size = { width = 123, height = 63 },
            hard_size = { width = 127, height = 67 },
        },
    },

    zones = {
        -- SMALL：安全 11x11，构建 13x13，硬边界 17x17
        { zone_id = "small_01", zone_category = "SMALL", center_offset = { x = -155, z =  65 } },
        { zone_id = "small_02", zone_category = "SMALL", center_offset = { x =  155, z =  65 } },
        { zone_id = "small_03", zone_category = "SMALL", center_offset = { x = -155, z = -65 } },
        { zone_id = "small_04", zone_category = "SMALL", center_offset = { x =  155, z = -65 } },

        -- MEDIUM：安全 29x29，构建 31x31，硬边界 35x35
        { zone_id = "medium_01", zone_category = "MEDIUM", center_offset = { x = -105, z =  65 } },
        { zone_id = "medium_02", zone_category = "MEDIUM", center_offset = { x =  105, z =  65 } },
        { zone_id = "medium_03", zone_category = "MEDIUM", center_offset = { x = -105, z = -65 } },
        { zone_id = "medium_04", zone_category = "MEDIUM", center_offset = { x =  105, z = -65 } },

        -- LARGE 横向：安全 121x61，构建 123x63，硬边界 127x67
        { zone_id = "large_01", zone_category = "LARGE", center_offset = { x = 0, z =  130 } },
        { zone_id = "large_02", zone_category = "LARGE", center_offset = { x = 0, z = -130 } },
    },
}
```

- 上述世界尺寸、坐标、数量和三层尺寸是正式值，不是示例；
- `zone_category` 只表示物理尺寸，固定为 `SMALL`、`MEDIUM`、`LARGE`；
- GameMode definition 声明自己需要哪个 `zone_category`；
- ZoneManager 只从相同类别的空闲 Zone 中分配；
- 类别只用于场地选择，不把关卡、胜负、Wave 等玩法状态写入 Zone；
- `safe_bounds` 是当前场景允许玩家正常活动的区域；
- `build_bounds` 是 ScenePlan 可以铺地和布置场景的区域；
- `hard_bounds` 是任何地形事务、实体生成、回滚和清理都不得越过的绝对边界；
- 三层边界必须满足 `safe_bounds ⊂ build_bounds ⊂ hard_bounds`，并由类别尺寸和解析后的 Zone 中心计算，不在每个 Zone 重复手写；
- Lobby 与所有 Zone 的三层宽高均为奇数，center 必须落在唯一中心 Tile 上；每层边界相对中心 Tile 四向严格对称，不允许半 Tile 中心或单侧多一格；
- 所有 LARGE Zone 固定为横向，宽度沿 x 轴、高度沿 z 轴。
- Lobby center 与 Portal 实际 Tile 完全一致，二者不要求位于世界坐标 `(0, 0)`。Zone 的 `center_offset` 使用上表正式值；最外侧布局相对 Portal 的最大硬边缘偏移为 `±163.5` Tile，相邻 SMALL/MEDIUM 的硬边缘间距为 24 Tile。
- 以轴对齐矩形边缘计算，任意两个 `hard_bounds` 的最短欧氏距离不得小于 24 Tile；解析后的任意 `hard_bounds` 到实际地图有效 Tile 边界不得小于 36 Tile。当前布局相对 Portal 的最大硬边缘偏移为 163.5 Tile，因此 Portal Tile 到地图四侧有效边界都必须至少有 `163.5 + 36 = 199.5` Tile 空间。Portal 必须由 worldgen 放在满足该条件的地图中央附近合法 Tile；不能根据世界坐标 `(0, 0)` 推断位置，也不能在未解析 Portal 坐标前宣称边距有效。

Zone 不设置能力标签集合，也不保存固定 Participant 出生点、spectator anchor 或 camera bounds。每个 ScenePlan revision 必须根据当时实际地形声明这些动态锚点；SceneService 在提交场景前验证它们位于有效地面和对应边界内。WorldLayout 静态配置只提供 Zone 中心偏移和三层物理尺寸，运行时再解析实际中心与边界。锚点变更失败时保留最后一个已提交 revision；若不存在可用的已提交锚点，则中止 Instance 并把 Participant/Spectator 安全送回大厅，绝不把 Zone 中心当作落点，因为空闲 Zone 中心是虚空。

大厅的 `MAXWELL_RITUAL_HALL_V1` 是以 Portal 实际 Tile 为中心的固定 11×11 Tile 对称图案，按以下顺序铺设，后写层覆盖先写层：

1. 全部 11×11 使用 `WORLD_TILES.CARPET2`；
2. 从唯一中心 Tile 向四边铺设 3 Tile 宽的十字通道，使用 `WORLD_TILES.WOODFLOOR`；
3. 中央 5×5 使用 `WORLD_TILES.CHECKER`；
4. 最外侧 1 Tile 环使用 `WORLD_TILES.BRICK_GLOW`。

`multiplayer_portal` 位于大厅唯一中心 Tile；其实际 Tile 坐标是整个 Layout 的运行时锚点。大厅出生/返回点是相对 Portal 的 Tile 偏移，按配置顺序循环选择可用点；点位被占用或不安全时，只能在解析后的 `safe_bounds` 内做有界最近安全点搜索，绝不能把玩家放入虚空。Spectator 退出时优先返回其大厅残影位置，失效时再使用该回退列表。

### 3.3 Portal 位置

世界生成必须保证唯一 `multiplayer_portal` 位于大厅图案的唯一中心 Tile。Portal 不要求使用世界坐标 `(0, 0)`；它的实际 Tile 坐标在 world 启动后成为 Lobby 与全部 Zone 的坐标锚点。

推荐流程：

1. worldgen 在地图中央附近选择能够容纳完整相对布局及边缘安全距离的合法 Tile；
2. 以该 Tile 为 static layout anchor，同时生成大厅地面和中心 Portal；
3. world 启动时查找唯一 Portal，读取其实际 world 坐标并转换为 Portal Tile 坐标；
4. 用 `portal_tile + center_offset` 解析 Lobby 和全部 Zone 的实际中心与三层边界；
5. 校验 Portal Prefab、唯一性、Portal 位于大厅中心、Zone 间距及所有解析边界的地图边距；
6. 校验失败时停止 Agon runtime，并输出可定位错误；不得静默选择另一个 Portal、把世界原点当作 Portal，或临时平移个别 Zone。

Portal 同时用于 shard 迁移和整个 Agon Layout 的坐标锚点。静态配置只保存相对偏移；运行时解析结果必须由 `WorldLayoutService` 统一持有，Mode 不得自行读取 Portal 后重复换算。

### 3.4 运行时场景构建、变更与清理

Zone 初始和空闲状态固定为虚空。GameMode 不直接改 Tile 或随意生成场景实体，而是返回通用 `ScenePlan`，由 `SceneService` 在 Instance `PREPARING`、Phase 过渡或运行中事件里执行：

```text
GameMode runtime
  → CreateScenePlan(context)
  → SceneService:ApplyPlan(instance, zone, plan, scope)
  → ZoneTerrainService 执行 Tile transaction
  → SpawnService 执行实体变更
  → Validate and commit scene revision
```

`ScenePlan` 可以描述全场重建或局部 Patch：

- Tile 的新增、替换和清除；
- 场景实体的生成、保留、迁移和销毁；
- 区域的激活、关闭和边界变化；
- 出生点、安全点和 spectator camera bounds 更新；
- 受影响玩家、物品、怪物和容器的处理策略；
- 执行模式、预期 scene revision 和失败回滚信息。

执行模式：

- `BLOCKING`：Instance 进入受控过渡，冻结玩法输入，完成场景事务和校验后恢复；
- `LIVE_PATCH`：Instance 继续运行，只修改声明的 affected bounds，适用于缩圈、塌陷、机关或局部地形事件。

`LIVE_PATCH` 必须显式提供 affected bounds、occupant policy、safe points 和 rollback policy。即将把有玩家或关键实体占用的 Tile 变成虚空时，只允许 `REJECT_IF_OCCUPIED`、`MOVE_TO_SAFE_POINT` 或已注册的 `MODE_RESOLVE`，不得静默删除、遗留或把对象投入虚空。第一版必须同时实现并验证 `BLOCKING` 和 `LIVE_PATCH`。

实现可以基于：

```lua
TheWorld.Map:GetTileCoordsAtPoint(...)
TheWorld.Map:GetTileAtPoint(...)
TheWorld.Map:SetTile(...)
TheWorld.Map:RebuildLayer(...)
TheWorld.minimap.MiniMap:RebuildLayer(...)
```

`change_tile()` 只允许由 `ZoneTerrainService` 调用。每次构建或运行中修改都必须记录 `instance_id`、`zone_id`、`scope_id`、scene revision、transaction ID、Tile 坐标、修改前后类型、执行模式和回滚状态。

释放 Zone 的固定流程：

```text
Stop gameplay
→ Close child Scopes and cancel tasks/listeners/effects
→ Remove all Instance-owned entities
→ Set every tile in Zone hard_bounds to WORLD_TILES.IMPASSABLE
→ Rebuild world/minimap layers
→ Validate no ground and no managed entity remain
→ FREE
```

限制：

- 只能修改当前 Instance 租用 Zone 的 `hard_bounds` 内 Tile；普通场景内容还必须限制在 `build_bounds`；
- ScenePlan 必须基于当前 scene revision，过期计划不得覆盖新场景；
- `LIVE_PATCH` 只能影响声明的 affected bounds，不能借机扫描或修改整个 Zone；
- `GetTileAtPoint()` 返回无效值时必须失败，不得向地图边界外扩张；
- 构建失败必须立即清回虚空，不能把半成品 Zone 标记为 FREE；
- Zone 释放前必须验证所有 Tile 已恢复为 `WORLD_TILES.IMPASSABLE`；
- 服务器重启中止 Instance 时，也必须把所有已占用 Zone 清回虚空；
- 海陆切换对寻路、船、平台、物理、小地图和客户端同步仍需实服专项验证。

大量 Tile 不应无节制地逐 Tile 重建相同 layer；正式实现前需要进行批处理与性能实验。

---

## 4. 总体架构

```text
TheWorld
└── AgonRuntime
    ├── WorldLayoutService
    ├── LobbyService
    ├── MatchmakingGateway
    ├── ZoneManager
    │   └── Zone Pool
    ├── InstanceManager
    │   └── Active Instances
    ├── ModeRegistry
    ├── SceneService
    │   ├── ZoneTerrainService
    │   └── SpawnService
    ├── PlayerSandboxService
    │   └── PlayerStateAdapterRegistry
    ├── SpectatorService
    ├── InstanceIsolationService
    ├── AudienceStateChannel
    ├── CommonServiceRegistry
    │   ├── PhaseService
    │   ├── ClockService
    │   ├── DecisionService
    │   ├── EffectService
    │   ├── EntityProfileService
    │   └── ScoreLedger
    ├── BackendAdapter
    └── Diagnostics
```

公共代码分为三层：

```text
Core                 所有 Mode 强制遵守的安全与归属边界
Common Services      同一个 Mod 内按 Mode 声明启用的完整通用实现
GameMode Plugins     FEAST、角斗场、PVP、钓鱼等具体规则和内容
```

Common Services 不是只留空接口让 Mode 从零实现。框架提供可运行的生命周期、网络、清理和持久化机制；Mode 只注册策略、handler、配置和展示数据。未启用的服务不创建监听器、task、classified 数据或保存状态。

### 4.1 TheWorld 级对象

只保存公共管理器和全局索引：

- Layout、Lobby、Zone 注册表；
- InstanceManager 和 ModeRegistry；
- SceneService 和 CommonServiceRegistry；
- `userid → instance_id` Participant 索引；
- `userid → spectating_instance_id` Spectator 索引；
- 玩家沙箱恢复事务；
- Debug、日志和后端适配器。

禁止写入 `TheWorld.current_stage`、`TheWorld.current_wave`、`TheWorld.current_recipe` 等具体玩法状态。

### 4.2 Instance 级对象

每个 Instance 独占：

- `instance_id`、`mode_id`、`zone_id`；
- 生命周期、Participant 和 ParticipantGroup；
- Mode runtime；
- EntityRegistry、root ResourceScope、RulePolicy；
- Scene revision 和 SceneTransaction；
- InstanceRng；
- Mode 声明启用的 Common Services；
- PlayerDeathPolicy；
- 结果与结算状态。

### 4.3 Zone 级对象

Zone 只描述预留虚空槽位：类别、中心、边界、安全边界、玩家和观战锚点、当前 reservation 和状态。

Zone 不保存第几关、刷什么怪、谁获胜等玩法字段。

---

## 5. 核心领域模型

### 5.1 AgonRuntime

```lua
AgonRuntime = {
    schema_version,
    shard_id,
    boot_generation,
    next_instance_seq,

    layout_service,
    lobby_service,
    zone_manager,
    instance_manager,
    mode_registry,
    scene_service,
    common_service_registry,
    audience_state_channel,
    sandbox_service,
    spectator_service,
    isolation_service,
    backend_adapter,
}
```

它挂载在 world server entity 上，并通过 component 的 `OnSave`/`OnLoad` 保存公共状态。

### 5.2 Zone

```lua
Zone = {
    zone_id,
    zone_category,
    center_offset,   -- 静态配置：相对 Portal Tile
    resolved_center, -- 运行时：Portal Tile + center_offset
    safe_bounds,
    build_bounds,
    hard_bounds,

    state,
    reserved_instance_id,
}
```

Zone 状态：

```text
FREE → RESERVED → BUILDING → ACTIVE → RESETTING → FREE
                    └──────────┴───────────────→ QUARANTINED
```

- `FREE`：可以分配；
- `RESERVED`：已分配给 Instance，但尚未开始构建；
- `BUILDING`：正在把虚空构建为本局场地；
- `ACTIVE`：构建验证通过，可供 Instance 使用；
- `RESETTING`：正在清理实体、资源和地形；
- `QUARANTINED`：验证失败，不再自动分配。

`zone_category` 是 Zone 的物理尺寸类别。比如 `zone_category = "LARGE"` 的 Zone 只分配给声明需要 LARGE 场地的 GameMode。它不等于玩法名称、某一局或能力集合，也不保存具体玩法状态。`center_offset` 可以保存，`resolved_center` 必须由当前世界的 Portal 实际 Tile 解析，不能跨存档硬编码复用。Participant 出生点、spectator anchor 和 camera bounds 属于当前 ScenePlan revision，不属于 Zone 静态定义。

### 5.3 Instance

```lua
Instance = {
    instance_id,
    mode_id,
    mode_version,
    zone_id,

    lifecycle_state,
    created_at,
    state_entered_at,
    generation,

    participants,
    participant_groups,
    mode_runtime,
    entity_registry,
    root_scope,
    rule_policy,
    death_policy,
    scene_revision,
    scene_transactions,
    rng,
    services,

    result,
    settlement_state,
}
```

`instance_id` 推荐使用 `agon:<shard_id>:<persistent_sequence>`。创建后不可修改，序列号必须保存，重启后继续递增。

### 5.4 Participant

Participant 表示一个 `userid` 与一局比赛的关系，不等于 Player Entity：

```lua
Participant = {
    userid,
    instance_id,
    state,
    player_ref,
    joined_at,
    disconnected_at,
    group_ids,
    role,
    sandbox_transaction_id,
    death_state,
    generation,
}
```

推荐状态：

```text
JOINING → READY → PLAYING → LEAVING → LEFT
                    ├────→ DISCONNECTED
                    ├────→ GHOST
                    └────→ CORPSE
```

`GHOST` 和 `CORPSE` 仍是 Participant；它们不是 Spectator。

### 5.5 ParticipantGroup

ParticipantGroup 是 Instance 内的通用逻辑分组，不写死“合作队伍”含义：

```lua
ParticipantGroup = {
    group_id,
    instance_id,
    group_type,
    members,
    generation,
    metadata,
}
```

它可以表示合作队伍、PVP 阵营、单人竞争组或 Mode 自定义分组。Decision、Effect、Score、网络 audience、胜负结果和观战权限都可以指向 Group。`metadata` 只能保存可序列化、带 schema 的 Mode 数据，不能放 function 或 entity reference。

一个 Participant 可以按 Mode 规则加入一个或多个不同类型的 Group，但所有 Group 必须属于同一 Instance。跨 Instance Group 和全世界共享玩法队伍均禁止。

### 5.6 GameMode

GameMode definition 是无共享可变状态的规则工厂：

```lua
GameModeDefinition = {
    mode_id,
    mode_version,
    zone_category,
    services,
    CreateRuntime,
}
```

`zone_category` 决定从哪类 Zone 池分配；`services` 声明按需启用的 Common Services。每个 Instance 单独创建 `mode_runtime = definition:CreateRuntime(instance, services)`，只有 mode runtime 才能保存具体阶段、Wave、目标、得分公式和临时规则。

GameMode 插件都位于同一个 Mod 的 `scripts/agon/modes/<mode_id>/` 下。它们只能通过稳定公共接口访问 Base，不得直接改写 manager 内部表、其他 Mode runtime 或全局 `TUNING`。

Mode runtime 可实现以下可选策略入口：

```lua
mode_runtime:CreateScenePlan(context)
mode_runtime:GetPlayerProfile(participant)
mode_runtime:CreateGroups(participants)
mode_runtime:CreateRulePolicy()
mode_runtime:CreateDeathPolicy()
```

具体料理、战斗、钓鱼、胜负、关卡内容、效果类型和数值不属于 Base。

### 5.7 EntityRegistry

所有 Mode 创建或认领的 gameplay entity 必须登记：

```lua
EntityRecord = {
    guid,
    instance_id,
    scope_id,
    prefab,
    category,
    cleanup_policy,
    profile_id,
    profile_version,
    parent_entity_id,
    spawn_source,
    persistent_key,
    generation,
}
```

运行时实体可带：

```lua
entity._agon_instance_id = instance_id
entity:AddTag("agon_managed")
```

需要跨重启的实体使用 `agon_instance_member` component 保存稳定 membership。GUID 只在当前运行时有效，不能作为跨重启业务 ID。Projectile、召唤物、陷阱、掉落物和子物品必须传播 Instance、scope 和 spawn lineage；需要差异化能力时再解析 child profile policy。

### 5.8 HierarchicalResourceScope

Mode 创建的所有资源都必须经 Instance 包装接口登记：

```lua
instance:DoTaskInTime(...)
instance:DoPeriodicTask(...)
instance:ListenForEvent(...)
instance:Spawn(...)
```

每个 Instance 拥有 root scope，并可创建任意命名的子作用域：

```text
InstanceRootScope
├── PhaseScope
├── ParticipantScope
└── Mode-defined ChildScope
```

Scope 统一登记 task、event subscription、entity、SceneTransaction、Effect、Decision、临时回调和清理函数。关闭子 Scope 时，每项资源必须使用确定策略：

```text
DESTROY
RETAIN_IN_PARENT_SCOPE
TRANSFER_TO_SCOPE
MODE_RESOLVE
```

转移只能发生在同一 Instance 的有效 Scope 之间，并重新校验 ownership、generation 和目标 Scope 状态。`MODE_RESOLVE` 必须调用已注册、可诊断的 resolver；不得保存匿名 Lua function。销毁单局时禁止调用针对整个 `TheWorld` 的粗暴清理。

### 5.9 Common Services

以下服务均由 Base 提供完整通用实现，由 Mode 按需启用。

每个 Service 声明稳定名称、版本、依赖和 facade。Mode 注册时若漏掉依赖、请求未知版本或重复注册 handler，必须立即失败；框架不得静默启动未声明服务，也不得让 Mode 从内部 manager 偷取等价能力。

#### PhaseService 与 ClockService

Phase 是通用执行阶段，不等于 FEAST 关卡。角斗场可把它叫 Round，PVP 可用于准备/战斗/结算，单阶段模式也可以不用 PhaseService。

```text
PREPARING → ACTIVE → RESOLVING → TRANSITIONING → ENDED
```

PhaseService 负责合法转移、phase revision、PhaseScope、旧回调失效和异常清理；Mode 决定阶段数量、名称、下一阶段、超时和结束含义。ClockService 提供 Instance/Phase semantic deadline、暂停和恢复，只影响目标 Instance，不暂停世界天数、昼夜或其他 Instance。

#### DecisionService

DecisionService 支持 `PLAYER_PRIVATE`、`GROUP_VOTE`、`GROUP_LEADER`、`INSTANCE_VOTE` 和 `SERVER_AUTO`。它负责候选 ID、eligible voters、deadline、弃权、重复投票、服务端聚合、结果冻结和 audience-scoped 同步。

标准相对多数策略为：超时未投票视为 `ABSTAIN`；票数最高选项获胜；最高票并列时使用 InstanceRng 从并列项中选择。若所有人弃权，则所有候选同为零票并列。是否允许改票和其他聚合策略由创建 Decision 时声明。

#### EffectService

EffectService 只管理 effect 的来源、目标、Scope、handler、优先级、叠加、重连重施加和自动撤销，不定义攻击、采集、料理、腐烂、钓鱼等具体属性。Mode 注册具体 handler；Effect 目标可以是 Participant、ParticipantGroup、Instance 或 Entity。

#### EntityProfileService

EntityProfileService 负责 Instance 内怪物、Boss、物品和其他实体的模式化版本。Profile 可以通过已注册 Adapter 修改组件、属性、标签、技能、Loot、Brain、StateGraph 和物品行为，但具体改法属于 Mode。

```text
Vanilla Prefab → EntityProfile → Runtime Effects
```

- `EntityProfile` 表示实体在本模式中“是什么”；
- `Effect` 表示运行中临时附加了“什么变化”。

Profile Adapter 必须声明 `SPAWN_ONLY`、`BLOCKING_ONLY` 或 `LIVE_SAFE`。深度修改默认只允许作用于 `Instance:Spawn()`、PlayerSandbox 临时物品或明确登记的 Instance-owned entity。Lobby、Portal、其他 Instance 和 GLOBAL entity 禁止修改。确需认领外部实体时优先克隆；原地修改必须有完整 capture/restore Adapter。

无条件修改 `TUNING`、全局 Brain 或同名 Prefab 被禁止。确实需要 `AddPrefabPostInit`、`AddBrainPostInit` 或 `AddStategraphPostInit` 时，只能安装默认无效果的路由层；只有实体已解析出当前 Instance 和 `profile_id` 后才启用对应行为。

Profile 可声明 minion、projectile、trap、loot 等 child profile policy。Base 负责子实体 ownership 和 Scope 传播；Mode 决定具体子 Profile。

所有受管实体必须通过 SpawnService 创建，Mode 禁止直接调用裸 `SpawnPrefab()`。SpawnService 在调用原版 Prefab constructor 前压入短生命周期 spawn context，使 constructor 内同步创建的 child entity 也能继承 Instance、Scope 和 child profile policy，并必须在成功或异常后成对弹出。之后由 Brain、技能或组件异步生成的子实体，再通过 parent/root owner 和注册的路由解析归属。

Profile Adapter 还必须声明 `SERVER_ONLY` 或 `REPLICATED`。凡是会改变客户端动作、Replica、StateGraph 表现、物品 UI 或可见 netvar 的修改，都必须注册对应客户端契约；不能假设服务端改了组件字段，客户端就一定得到正确表现。客户端声明仍需无条件加载，但只有实体 membership 和 Profile 匹配时启用。

#### ScoreLedger

ScoreLedger 提供带唯一 `event_id` 的幂等记分、Participant/Group/Instance 汇总、原因记录和最终冻结。Base 不定义得分公式、目标系统或通关门槛；Mode 计算分值并提交账本事件。

### 5.10 Core runtime utilities

InstanceRng 和 AudienceStateChannel 属于 Core，不需要 Mode 声明启用。每个 Instance 创建一个确定性 RNG，并按名称分流，例如 `scene`、`decision`、`loot` 和 `mode`。保存 seed 和 stream state/counter，避免 UI 平票随机改变刷怪或掉落序列。

AudienceStateChannel 是公共网络边界，支持 `PRIVATE(userid)`、`GROUP(group_id)`、`INSTANCE(instance_id)`、`SPECTATOR(instance_id)` 和 `PUBLIC`。服务只同步声明 audience 可见的可序列化状态；客户端不能借此获得服务端私有判定数据。

---

## 6. 大厅、观战与玩家状态沙箱

三者必须分开：

| 状态                | 玩家实体                   | 原物资/状态            | 可执行操作           | Instance 归属 |
| ------------------- | -------------------------- | ---------------------- | -------------------- | ------------- |
| `LOBBY`           | 可见                       | 保持正常               | 大厅移动、聊天、UI   | 无            |
| `SPECTATING`      | 真实实体隐藏，大厅留下残影 | 不捕获、不清空、不替换 | 仅观战相机和观战 UI  | 只读观战关系  |
| `PLAYING`         | 可见                       | 原状态已安全暂存       | 当前 Mode 允许的操作 | Participant   |
| `RESTORE_PENDING` | 隐藏并受保护               | 等待恢复               | 无                   | 恢复事务决定  |

世界时钟和天数在以上状态下都正常增长。

### 6.1 Lobby

玩家从其他 shard 进入后，在 `lobby.spawn_and_return_points` 中选择安全点生成。

大厅负责：模式选择、组队和匹配 UI、玩家社交、进入/退出观战、比赛结束返回、状态恢复安全区和 shard Portal。

大厅与所有 Zone 由大范围 `IMPASSABLE` 虚空隔开。大厅玩家不能通过正常移动、传送或特殊角色能力进入 Zone。

### 6.2 Spectator

Spectator 是独立的只读观察关系，不是 Participant，也不是玩家死亡状态。

```lua
SpectatorRecord = {
    userid,
    instance_id,
    anchor_id,
    camera_mode,
    lobby_return_position,
    echo_guid,
    entered_at,
}
```

强制要求：

- 不保存、清空、替换或重建玩家物品；
- 不保存或重置技能树；
- 不创建 PlayerSandbox snapshot；
- 不改写玩家持久化生存状态；
- 只施加可逆的运行时显示、保护与控制锁；
- 离开观战时直接解除锁并回大厅。

进入观战时 `SpectatorService`：

1. 记录玩家在大厅的原位置和目标 Instance；
2. 在该位置生成一个 `agon_spectator_echo` 人物残影；
3. 把真实玩家放到目标 Instance 当前 ScenePlan revision 声明并验证通过的安全 spectator anchor；
4. 隐藏真实实体、阴影和地图图标；
5. 禁用物理、碰撞、受击、被选中和所有 gameplay action；
6. 暂停玩家自身生命、饥饿、理智、温度等数值变化，但不改写现有数值；
7. 阻止装备、技能、光源、光环、跟随者等对比赛产生效果；
8. 客户端只开放观战相机和观战 UI；
9. 服务端拒绝 Spectator 的动作、物品和玩法 RPC。

上述保护是运行时 guard，不是状态快照。任何保护项都必须成对撤销，并保持幂等。

#### Spectator Echo

`agon_spectator_echo` 是大厅中的纯展示 Prefab，用来表现“玩家灵魂离体去观战了”，让后来进入大厅的人可以直观看到当前有哪些玩家正在观战。

残影应复制观战开始时的人物外观：

- 角色 Prefab 和基础动画 build；
- 当前皮肤、服装和颜色信息；
- 玩家显示名；
- 一个明确但不刺眼的半透明/灵魂效果；
- 可选的“正在观战”标记；是否展示目标 Mode 由隐私策略决定。

残影不是 Player Entity，也不是 Participant、Spectator 或 Instance entity。它必须满足：

- 没有 inventory、combat、health、locomotor、brain 和 gameplay component；
- 没有物理碰撞、阴影、光源、光环和角色技能；
- 不能被攻击、治疗、推动、拾取、附身或作为技能目标；
- 不能触发大厅机关、计数、AI 仇恨和玩家查询；
- 只允许检查名称/观战状态，不提供 gameplay action；
- 由 `LobbyService` 管理，而不是由被观看的 Instance 管理；
- `persists = false`，不进入世界存档。

每个 `userid` 同时最多存在一个残影。创建前必须清理该 userid 遗留的旧残影，防止重复进入观战产生复制体。

残影生命周期与 Spectator session 严格绑定：

```text
EnterSpectating
→ CreateEcho(lobby position, appearance)
→ MoveAndHideRealPlayer
→ Spectating
→ ReturnRealPlayerToLobby
→ RemoveEcho
→ RemoveRuntimeGuard
```

正常退出观战、目标 Instance 结束、玩家断线、shard 迁移失败、服务器关闭和异常清理都必须移除残影。真实玩家返回时优先使用原大厅位置（即残影所在的位置）；位置失效或不安全时使用 `lobby.spawn_and_return_points`。

外观复制必须使用独立的只读 appearance data，不得把真实玩家的 inventory item、组件或 child entity 挂到残影上。换装、Mod 皮肤和重连行为需在实现阶段验证。

仅调用 `PlayerController:Enable(false)` 不够，因为原版相机旋转/缩放也会检查 controller enabled。客户端需要专门的 spectator input layer：禁止行动输入，但保留旋转、缩放、切换目标和受限自由相机。

观战相机支持：

- 跟随当前 Instance 中允许观看的 Participant；
- 在当前 ScenePlan revision 的 `spectator_camera_bounds` 内自由移动；
- 不允许跨 Zone 查看另一个 Instance；
- GameMode 可配置是否允许观战、观战人数、团队视角和延迟策略。

为了获得远端 Zone 的网络实体，隐藏玩家需要始终位于需要观察的视野的中央。

索引：

```lua
participant_index[userid] -- 最多一个 active Instance
spectator_index[userid]   -- 最多一个被观看 Instance
```

玩家不能同时参加 A 又观战 B。服务器重启后不恢复观战会话，玩家重新进入大厅。

### 6.3 PlayerSandbox

只有 Participant 进入比赛时才创建沙箱事务。

```text
CaptureOriginal
→ ValidateSnapshot
→ EnterCleanState
→ ApplyCharacterDefaults
→ ApplyModeOverrides
→ PLAYING
→ RemoveModeOverrides
→ RestoreOriginal
→ ValidateRestore
→ CommitRestore
```

原始快照至少覆盖：

- 背包、装备、鼠标物品；
- 生命、饥饿、理智、温度、潮湿；
- Debuff 和可恢复的临时状态；
- 骑乘、跟随者、宠物和召唤物处理信息；
- 技能 XP/技能点、已激活技能和技能树编码数据；
- 角色特有资源。

进入干净状态后：

- 清空原物品并进入模式临时物品环境；
- 技能 XP/可用技能点归零；
- 取消所有原技能；
- 再由 Character Adapter 按 Mode 的 PlayerProfile 应用统一或差异化临时能力。

技能树涉及客户端/服务端握手。必须验证临时清零不会覆盖玩家在其他 shard 使用的长期技能配置；验证完成前不能删除原快照。

### 6.4 PlayerStateAdapterRegistry

统一适配器链：

```text
BaseStateAdapter
├── InventoryAdapter
├── SurvivalStatsAdapter
├── SkillTreeAdapter
├── CharacterAdapter[character_prefab]
└── ModePlayerOverrides[mode_id]
```

公共契约：

```lua
adapter:Capture(player, snapshot)
adapter:ValidateCapture(player, snapshot)
adapter:EnterCleanState(player, context)
adapter:ApplyOverrides(player, context, sandbox)
adapter:RemoveOverrides(player, context)
adapter:Restore(player, snapshot)
adapter:ValidateRestore(player, snapshot)
```

Mode 只能通过 sandbox facade 做临时修改：

```lua
local profile = mode_runtime:GetPlayerProfile(participant)
sandbox:ApplyPlayerProfile(player, profile)
```

PlayerProfile 可以声明基础三维、移动速度、初始装备、技能树、允许/禁用的角色能力、临时组件和外观保留策略。它是通用玩家规格，不绑定 FEAST：某个 Mode 可以只保留人物外观并统一所有能力，另一个 Mode 也可以通过 Character Adapter 保留白名单能力。

例如给予临时装备、设置本局生命上限或激活指定技能。Mode 不得直接改写 original snapshot，也不得绕过 Character Adapter 直接拆除无法恢复的角色组件。

尚未适配且无法保证恢复的角色，可以停留在大厅，但必须拒绝其进入匹配。

#### 6.3.1 当前真实角色适配范围

WP10 的真实玩家验收先采用显式、可审计的角色白名单，不把未知角色转换成空快照：

- 当前只接入官方 `wilson` 和 `wathgrithr`；两者之外的真实角色继续返回不支持并停留在大厅。
- `wilson` 通过官方 `beard:OnSave/OnLoad` 保存胡须资源；本轮 Profile 的外观策略为 `PRESERVE`，清理阶段不清零外观。
- `wathgrithr` 通过官方 `singinginspiration:OnSave/OnLoad` 保存灵感值；存在活动歌曲或非零 `battleborn` 时，因为外部效果/临时值尚未有完整清理契约，直接拒绝进入。
- 角色存在非空 `leader.followers`、虚拟 `itemfollowers`、`petleash.pets` 或已召唤的 `ghostlybond.ghost` 时直接拒绝；不序列化实体引用，也不猜测如何重建关系。
- TestMode 的合成诊断 Profile 仍保留完整统一规格；真实玩家本轮只使用已经由 live adapters 支持的安全子集，暂不宣称真实客户端已应用统一临时物品、技能、能力或移动速度。

该范围是安全的增量接线，而不是关闭 Character Adapter 安全门。新增角色或扩大真实 Profile 前，必须先补齐官方组件的 capture、clean、restore 和逐字段验证证据。

#### WP10 真实玩家验收开关

PlayerSandbox 的真实玩家 live mutation 默认必须关闭。WP10 允许通过一个只用于
验收的临时开关验证真实客户端，但这个开关不是正式玩法能力，也不新增
`modinfo.lua` 配置项；公开配置仍只有 `enable_agon`。

- 只有官方 `ADMIN` UserCommand `/agon.test.player_sandbox on|off|status` 能请求切换；服务端 Runtime 仍会再次校验，不能依赖客户端菜单权限。
- `on` 只接受当前专服、权威模拟、当前 Test Cluster 的固定 `cluster_name`/`cluster_description` 指纹及 `TheShard:GetShardId() == 1`（对应本仓库的 `Test/World01`）。DST 官方 Lua 没有暴露 Cluster 路径，因此名称和描述变更时必须同步更新测试资格指纹；不匹配时返回 `PLAYER_SANDBOX_TEST_CONTEXT_REQUIRED`。
- 开关只存在于当前进程内，默认关闭，不写入 Runtime/Instance/PlayerSandbox snapshot；重启后必须再次由管理员开启。
- 开启只给之后新建的 `TEST_MODE` Instance 注入显式 `allow_live_player_test`；其他 Mode、合成玩家规则和重启恢复路径不继承该权限。关闭时立即撤销现有 Instance 的 live 测试权限。
- 真实玩家仍必须通过正常 Participant、PlayerSandbox Capture/Validate/Restore pipeline；该开关只解除环境测试门，不跳过状态校验、恢复或清理。
- SkillTree 握手必须复用官方 `PostActivateHandshake` 生命周期：服务端仅在玩家的
  `_PostActivateHandshakeState_Server == POSTACTIVATEHANDSHAKE.READY` 且收到官方
  `ms_skilltreeinitialized` 事件后，设置进程内的
  `agon_skilltree_handshake_complete` 标志。接线采用官方组件使用的
  `TheWorld:ListenForEvent("ms_skilltreeinitialized", callback, player)` 形式，并在
  `playeractivated`/`ms_playerjoined` 生命周期中确保监听及时注册；不能只依赖玩家实体
  上的监听。`skilltree.save_enabled` 是官方客户端保存状态控制字段，不能作为服务端
  握手完成证明，也不能被 Mod 强行改写。
- `SkillTreeAdapter` 的真实玩家硬门必须核对官方服务端 `READY` 状态；上述进程内标志
  仅用于诊断和触发恢复重试，不能单独绕过官方硬门。握手完成前不得 Capture、清空、
  应用 Profile 或 Restore。若玩家重连时恢复队列曾因握手未完成而阻塞，官方事件到达
  后可以按原 transaction 进行一次受控 Retry，快照不能被删除。

---

## 7. 玩家死亡底层接口

Instance 内死亡绝不自动进入 Spectator。

公共框架提供 `PlayerDeathPolicy`，具体 Mode 选择并配置死亡形态。第一阶段支持：

```text
GHOST              鬼魂，可移动，但仍受 Zone 边界和交互限制
REVIVABLE_CORPSE   可复活尸体，不能移动，可由队友按模式规则救援
```

接口建议：

```lua
PlayerDeathPolicy = {
    GetDeathMode,
    OnPlayerDeath,
    CanGhostMove,
    CanRevive,
    BeginRevive,
    CompleteRevive,
    CancelRevive,
    OnParticipantLeave,
    OnInstanceDestroy,
    OnSave,
    OnLoad,
}
```

框架负责：

- 维护 Participant 的 `ALIVE/GHOST/CORPSE` 状态；
- 将 ghost/corpse 归属到原 Instance；
- 限制边界、跨局交互和非法复活；
- 登记尸体、复活任务和事件监听；
- Instance 销毁时统一清理；
- 最终退出时恢复比赛前 PlayerSandbox。

GameMode 负责：

- 选择死亡模式；
- 是否允许复活；
- 谁能救、救援耗时和代价；
- 死亡是否影响胜负；
- 复活后的临时数值和装备。

熔炉式尸体可以参考官方 `revivablecorpse` 和 `spectatorcorpse` 的事件流程，但 The Agon 不能依赖全世界 GameMode property，因为同一 shard 中不同 Instance 可能采用不同死亡策略。需要实现 Instance-aware 的公共组件或等价适配层，并实服验证 Player StateGraph 与客户端表现。

---

## 8. Instance 生命周期

```text
CREATED
  → PREPARING
  → RUNNING
  → TRANSITION ──→ RUNNING
  → FINISHING
  → DESTROYING
  → DESTROYED

异常加载：RECOVERING → DESTROYING
运行失败：任意活动状态 → FAILED → DESTROYING
```

只有 InstanceManager 可以改变 Instance 生命周期。GameMode 只能请求转移。启用 PhaseService 时，Phase 生命周期嵌套在 `RUNNING/TRANSITION` 内，不得用 Phase state 替代 Instance state。

### 8.1 创建

```text
Validate mode
→ Reserve FREE Zone with matching zone_category
→ Create Instance
→ Create root scope, InstanceRng and requested Common Services
→ Create mode_runtime with stable service facades
→ Request initial ScenePlan
→ Apply and validate initial scene
→ Invite/attach Participants
```

任何一步失败都必须回滚已完成步骤。

### 8.2 玩家加入

```text
Validate userid and membership
→ Create Participant
→ Capture PlayerSandbox
→ Validate snapshot
→ Enter clean state
→ Resolve and apply Mode PlayerProfile
→ Teleport to Zone spawn
→ READY
```

在 snapshot 验证成功前，不得清空玩家状态。

### 8.3 开始与过渡

- 所有必要 Participant READY 后才能 RUNNING；
- GameMode 的 task、spawn、listener、effect、decision 和 scene request 全部通过 Instance 或 service facade；
- 启用 PhaseService 时，由它创建 PhaseScope 并驱动 `PREPARING → ACTIVE → RESOLVING → TRANSITIONING → ENDED`；
- `TRANSITION` 承载需要冻结整局的 `BLOCKING` ScenePlan；`LIVE_PATCH` 不改变 Instance 主生命周期，但使用独立 scene revision 和 transaction；
- 每个 SceneTransaction、EntityProfile、Effect 和 Decision 必须明确属于当前 Scope；
- 关闭 PhaseScope 前，Mode 必须为需要保留或迁移的资源选择显式策略，未处理项默认销毁；
- ClockService 只暂停目标 Instance/Phase 的业务时钟，世界天数和其他 Instance 正常运行。

### 8.4 结束和销毁顺序

```text
Freeze mode result
→ Stop accepting gameplay RPC
→ Freeze enabled ScoreLedger and unresolved Decisions
→ Close child ResourceScopes
→ Cancel mode tasks/listeners/effects
→ Resolve death state
→ Remove mode overrides
→ Restore Participants
→ Return restored players to Lobby
→ Remove Instance entities
→ Clear all Zone tiles to IMPASSABLE
→ Validate Zone is empty void
→ Release Zone
→ Remove indexes
→ DESTROYED
```

玩家恢复失败时不能阻塞其他人的恢复，也不能让 Zone 永久保持 RESERVED。失败玩家转入独立恢复队列；Zone 清理继续执行。

### 8.5 主动离开、断线与重连

主动离开比赛默认执行完整恢复并回大厅。Mode 可以判负，但不能跳过恢复。

断线：

- Participant 和原始 snapshot 保留；
- Instance 仍在运行时，重连者返回原 Instance；
- ParticipantGroup membership、PlayerProfile、有效 Effect 和私有 audience state 重新绑定；
- Instance 已结束时，重连者先恢复再进入大厅；
- 断线超时如何影响胜负由 Mode 决定。

### 8.6 服务器重启

采用 `ABORT_ON_RESTART`：

1. 加载 Runtime、Instance 和恢复事务；
2. 不恢复正在进行的玩法；
3. 所有 Instance 进入 `RECOVERING` 后转 `DESTROYING`；
4. 按保存的 Scope、SceneTransaction 和 membership 清理实体、任务、效果和地形；
5. 把所有占用过的 Zone 清为 `IMPASSABLE` 并验证；
6. 在线或之后重连的玩家恢复原状态并回大厅；
7. 未提交结算根据幂等状态继续处理。

---

## 9. 隔离策略

### 9.1 空间隔离

- Zone 之间由虚空分隔；
- Participant、Ghost、Corpse 和 Spectator 都有各自边界规则；
- 特殊移动、传送、跳跃和角色能力仍必须做逻辑拦截；
- 越界时回到当前 Zone 安全点，而不是任意世界坐标；
- GameMode 不能修改另一个 Zone。

### 9.2 归属解析

```lua
ResolveInstance(player)
ResolveInstance(entity)
ResolveRootOwner(entity)
```

优先级：

1. Participant index；
2. entity membership component；
3. `_agon_instance_id` 快速字段；
4. projectile/weapon/drop 的 root owner；
5. 无法解析则视为 unowned。

所有跨 Instance 行为默认拒绝。不能因为双方距离很近就认为属于同一局。

### 9.3 实体 ownership 传播

- Mob：由 `Instance:Spawn()` 登记；
- Projectile：继承 attacker/weapon 的 Instance；
- Drop：继承生成源 Instance；
- Minion、Trap 和其他子实体：继承父实体的 Instance、Scope 和 spawn lineage，并按 child profile policy 解析 Profile；
- 临时物品：由 PlayerSandbox 或 Instance 创建并登记；
- 外部实体进入 Zone：必须显式 `ClaimEntity`，否则 Mode 不得控制；
- GLOBAL world entity 不能被普通 Instance 删除。

### 9.4 交互策略

`RulePolicy` 的默认规则：

- 跨 Instance 伤害、治疗、拾取、容器、投射物和目标选择一律拒绝；
- Spectator 所有 gameplay 行为一律拒绝；
- Lobby 玩家不能影响 Instance entity；
- 同一 Instance 内再委托给 GameMode policy；
- Group 关系只能影响同一 Instance 内的规则判定，不能覆盖跨 Instance 默认拒绝；
- 客户端结果永远不能替代服务端判定。

BR 的局部 PvP 只在公共层预留 policy 和网络状态；具体目标选择、武器白名单及客户端 combat replica 适配留到 BR 设计阶段。

### 9.5 查询与性能

- 优先查 EntityRegistry，不做每帧全世界 `TheSim:FindEntities`；
- 必须扫描时限定 Zone 中心、半径和 tags；
- 边界检查采用低频 task 或事件触发，不给每个实体添加独立高频 Update；
- Spectator camera 和可见实体数量需要压测；
- `AddPrefabPostInitAny` 只用于极少数无法在 spawn path 解决的归属传播。
- EntityProfile 的昂贵解析应在 spawn/reconfigure 时完成，不在每帧重复查表；
- `LIVE_PATCH` 的 occupant 查询必须限定 affected bounds 和 tags。

---

## 10. 保存、恢复与失败保护

### 10.1 保存内容

Runtime 保存：

- schema/layout version；
- next instance sequence；
- active Instance records；
- Zone reservation/state；
- root/child Scope metadata 和未完成清理状态；
- scene revision、SceneTransaction 和 rollback 状态；
- Participant metadata；
- ParticipantGroup membership；
- 已启用 Common Services 的 schema/version 与必要语义状态；
- InstanceRng seed 和 stream state/counter；
- EntityProfile ID/version 和稳定 entity membership；
- PlayerSandbox transactions；
- ScoreLedger、immutable result 和 settlement state；

不保存 Lua function、entity reference、task handle、Spectator 会话、Mode definition、Effect handler 和客户端 UI 状态。Task/Clock 应保存 semantic deadline 和业务状态，而不是 handle。由于采用 `ABORT_ON_RESTART`，这些记录主要用于可验证清理、玩家恢复和幂等结算，不代表恢复正在进行的玩法。

### 10.2 PlayerSandbox 事务

```text
NEW → CAPTURED → SANDBOXED → RESTORING → RESTORED → COMMITTED
```

原始 snapshot 只在 `ValidateRestore()` 成功后删除。每个事务使用唯一 `sandbox_transaction_id`，所有 capture、restore 和 retry 必须幂等。

### 10.3 RESTORE_PENDING

可能原因：

- Mod 更新造成 schema/adapter 不兼容；
- 物品 Prefab 删除或改名；
- Character Adapter 报错；
- 恢复中服务器崩溃或玩家断线；
- snapshot 缺失、损坏或校验失败；
- 技能树客户端确认未完成；
- 重复事务或部分恢复。

处理闭环：

1. 保留原始 snapshot；
2. 玩家隐藏并冻结在大厅恢复点；
3. 禁止匹配、观战、物品操作和 shard 迁移；
4. 使用同一 transaction ID 自动幂等重试；
5. 确定性失败转为 `RESTORE_BLOCKED`，停止无限重试；
6. 输出失败 adapter、Prefab 和字段；
7. 提供管理员 inspect、retry、export 命令；
8. 只有验证通过才解除保护。

禁止恢复失败后自动丢弃 snapshot 或用默认物品覆盖。

### 10.4 Zone 清理失败

Zone 清空验证失败时进入 `RESETTING → QUARANTINED`。它不再参与自动分配，但其他 Zone 和 Instance 继续运行。管理员修复后必须重新执行“实体清理 + Tile 清回 `IMPASSABLE` + validation”，不能直接标记 FREE。

---

## 11. 网络与服务端权威

### 11.1 客户端最小同步

玩家只需要收到：

- 自己是否位于 Lobby、Participant、Spectator 或 RestorePending；
- 自己的 `instance_id`、`mode_id`、Participant state；
- 当前观战 Instance 和允许的 camera bounds；
- AudienceStateChannel 明确授权给 `PRIVATE`、`GROUP`、`INSTANCE`、`SPECTATOR` 或 `PUBLIC` audience 的状态；
- 自己参与的 Decision、允许看到的票数/结果、Clock 和 Score 摘要；
- 匹配和恢复错误码。

其他 Instance 的私有状态不广播。

### 11.2 RPC

所有 Client → Server RPC 必须验证：

- sender 与 userid 一致；
- 当前 shard 已激活；
- 玩家状态允许该操作；
- Instance、Zone 和 Mode 匹配；
- ParticipantGroup、audience、Decision eligibility 和目标 EntityProfile 匹配；
- lifecycle 允许；
- phase/scene revision 与请求声明一致；
- 参数范围、实体有效性和 ownership；
- request ID 未重复；
- 权限与速率限制。

Spectator 的服务端白名单只包含观战目标切换、相机模式和退出观战。相机本地移动不能产生服务端 gameplay action。

### 11.3 后端边界

本阶段只定义：

```lua
BackendAdapter:SubmitGameResult(result)
BackendAdapter:SubmitSettlement(settlement)
```

要求：server-only；`game_result` 完成后不可变；`settlement_id` 唯一并用于后端幂等；后端不可用时保存待提交状态；重试不能重复发金币；认证信息不下发客户端。

Flask 路由、认证、金币字段和排行榜另行设计。

---

## 12. 推荐文件树

```text
the-agon/
├── modinfo.lua
├── modmain.lua
├── modworldgenmain.lua
│
├── scripts/
│   ├── components/
│   │   ├── agon_runtime.lua
│   │   └── agon_instance_member.lua
│   ├── agon/
│   │   ├── bootstrap.lua
│   │   ├── config/world_layout.lua
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
│   │   │       ├── inventory.lua
│   │   │       ├── survival_stats.lua
│   │   │       ├── skilltree.lua
│   │   │       └── characters/
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
│   │   │   ├── game_mode_base.lua
│   │   │   ├── mode_registry.lua
│   │   │   ├── test_mode/
│   │   │   ├── feast/
│   │   │   ├── arena/
│   │   │   ├── pvp/
│   │   │   └── fishing/
│   │   ├── net/
│   │   │   ├── rpc.lua
│   │   │   ├── audience_state_channel.lua
│   │   │   └── classified.lua
│   │   ├── persistence/
│   │   │   ├── schema.lua
│   │   │   └── migrations.lua
│   │   ├── backend/backend_adapter.lua
│   │   └── debug/diagnostics.lua
│   └── prefabs/
│       ├── agon_player_classified.lua
│       └── agon_spectator_echo.lua
└── docs/base-design.md
```

加载边界：

- `modworldgenmain.lua`：仅世界生成，生成足够大的虚空地图、大厅和 Portal；不生成 Zone 地面；
- `modmain.lua`：共享入口，服务器业务受 `enable_agon` 硬门保护；
- runtime、manager、sandbox、death、backend：server-only；
- GameMode 插件与 Common Services 位于同一个 Mod，但 Mode 只能依赖公共 facade；
- classified、观战相机、UI/RPC sender：客户端加载；
- Mode rule 和结果判定：server authority；
- Mode 可提供纯展示数据给客户端，但不能下发私有判定状态。

---

## 13. 公共接口草案

### 13.1 注册 Mode

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

Mode 目录可以拥有自己的配置、Profile Adapter、Effect Handler、客户端展示和 runtime，但不能绕过注册表访问其他 Mode 的内部模块。

### 13.2 创建 Instance

```lua
function InstanceManager:Create(mode_id, userids)
    local def = self.mode_registry:Get(mode_id)
    local zone = self.zone_manager:Reserve(def.zone_category)
    local instance = Instance(self:NextId(), def, zone)
    instance:CreateRootScope()
    instance:CreateRng()
    instance:EnableDeclaredServices(def.services)
    instance:CreateModeRuntime()
    instance:ApplyInitialScenePlan()
    instance:Prepare() -- 任一步失败都关闭 Scope、清回虚空并回滚 reservation
    return instance
end
```

### 13.3 Player 加入

```lua
function Instance:AddPlayer(player)
    self:AssertJoinAllowed(player)
    local participant = self:CreateParticipant(player.userid)
    self.sandbox_service:Enter(player, self, participant)
    self:TeleportToSpawn(player)
    return participant
end
```

### 13.4 观战

```lua
function SpectatorService:Enter(player, instance_id)
    self:AssertNotParticipant(player.userid)
    self:AssertSpectatingAllowed(player, instance_id)
    self:ApplyRuntimeGuard(player)
    self:AttachCamera(player, instance_id)
end
```

这里不调用 PlayerSandbox，不改物品和技能树。

### 13.5 死亡

```lua
function Instance:OnPlayerDeath(participant, data)
    local death_mode = self.death_policy:GetDeathMode(participant, data)
    self.death_policy:OnPlayerDeath(participant, death_mode, data)
end
```

### 13.6 场景变更

```lua
local plan = mode_runtime:CreateScenePlan({
    reason = "PHASE_TRANSITION",
    execution_mode = "BLOCKING",
    expected_scene_revision = instance.scene_revision,
})

instance.scene_service:ApplyPlan(instance, plan, phase_scope)
```

`LIVE_PATCH` 使用同一接口，但还必须包含 affected bounds、occupant policy、safe points 和 rollback policy。Mode 只能提交声明式计划，不能直接调用 `change_tile()`。

### 13.7 Group 与 Decision

```lua
local group = instance.groups:Create("COOP_TEAM", participants)

instance.services.decision:Create({
    decision_id = "group_choice:phase:3",
    audience = { type = "GROUP", id = group.group_id },
    eligible_voters = group.members,
    options = { "A", "B", "C" },
    deadline = deadline,
    timeout_vote = "ABSTAIN",
    aggregation = "PLURALITY_RANDOM_TIE",
})
```

这是通用投票示例，不代表 Base 内置“祝福”。零票并列时从全部候选中使用 `decision` RNG stream 选择。

### 13.8 实体生成、Profile 与 Effect

```lua
function Instance:Spawn(spec, scope)
    return self.spawn_service:SpawnOwned(self, spec, scope)
end

instance.services.effects:Add({
    effect_id = "mode_specific_effect",
    source_id = source_id,
    target = { type = "ENTITY", id = entity.GUID },
    scope_id = phase_scope.scope_id,
    handler_id = "registered_mode_handler",
    payload = { ... },
})
```

Profile 先定义实体的模式版本，Effect 再叠加运行时临时变化。具体属性和 handler 均由 Mode 提供。

### 13.9 销毁

```lua

function InstanceManager:Destroy(instance_id, reason)
    local instance = self:Get(instance_id)
    if instance == nil or instance:IsDestroyed() then
        return "ALREADY_DESTROYED"
    end
    return instance:RunDestroyPipeline(reason)
end
```

这些是契约示意，不是可直接复制的完整实现。

---

## 14. 可靠性与安全要求

- 生命周期转移必须校验，重复调用返回稳定结果；
- destroy、restore、SceneTransaction rollback、Decision resolution、score append 和 settlement retry 必须幂等；
- 异步回调携带 Instance/Scope generation 和必要的 phase/scene revision，旧回调不得作用于新局或新阶段；
- entity reference 使用前检查有效性、membership 和 generation；
- Common Service 未声明启用时不得创建状态、监听或接受 RPC；
- Mode 不能直接调用 `change_tile()`、全局修改 `TUNING`，或无条件修改同名 Prefab/Brain/StateGraph；
- `LIVE_PATCH` 必须先处理 affected bounds 内的玩家和实体，失败时回滚或隔离，不能伪造成功；
- Effect、Decision、EntityProfile、ScoreEvent 和 audience payload 均验证 Instance、Group、Scope 和 schema；
- Mode 异常不能跳过玩家恢复和 Zone 清理；
- PlayerSandbox 原快照不能被 Mode 读取或修改；
- Spectator 只有视角权限，没有隐含 gameplay 权限；
- 管理员强制销毁也必须走正常 pipeline；
- Core、Common Service、Mode、EntityProfile 和保存数据分别带 schema/version；
- 清理失败采用隔离降级，不伪造成功；
- 日志统一携带 `shard_id`、`instance_id`、`zone_id`、`mode_id`、`userid`、lifecycle 和 event。

推荐 Debug 能力：

```text
agon.status
agon.instances
agon.instance <id>
agon.zones
agon.zone <id>
agon.player <userid>
agon.entity <GUID>
agon.groups <instance_id>
agon.scopes <instance_id>
agon.scene <instance_id>
agon.services <instance_id>
agon.decisions <instance_id>
agon.effects <instance_id>
agon.score <instance_id>
agon.validate_instance <id>
agon.validate_zone <id>
agon.restore.inspect <userid>
agon.restore.retry <userid>
agon.restore.export <userid>
agon.destroy_instance <id>
agon.cleanup_zone <id>
```

---

## 15. 最小验收清单

### 15.1 Shard 与世界

- `enable_agon = false` 时无 Agon manager、监听、周期任务和扫描；
- 目标 shard 只生成大厅和 Portal，其余区域均为 `IMPASSABLE`；
- 所有 Zone 配置槽位在无 Instance 时保持纯虚空；
- Portal 唯一且与大厅中心一致；
- 世界保存/重启后不重复生成地图；
- 天数和时钟正常增长。

### 15.2 双 Instance 并发

场景：Zone A 中 2 人运行 Instance A；Zone B 中 3 人运行 Instance B；两局使用不同测试实体、定时器和状态。

验证：

- Participant、Group、实体、任务、事件、Effect、Decision、掉落、容器和伤害不串局；
- A 结束时 B 继续运行；
- A 的玩家恢复原物品、状态和技能树并回大厅；
- A 的 Zone 清回纯虚空后可创建新局；
- Destroy 重复调用不产生额外副作用。

### 15.3 PlayerSandbox

- 背包、装备、鼠标物品完整恢复；
- 生命、饥饿、理智等恢复一致；
- 进入比赛后技能点为零，Mode 临时技能生效；
- 统一 PlayerProfile 下不同角色只保留允许的外观与能力，未授权角色能力不残留；
- 退出后原技能 XP、选择和效果恢复；
- 各角色 Adapter 独立验收；
- capture 或 restore 中断后可幂等继续；
- 确定性失败进入 `RESTORE_BLOCKED`，原 snapshot 仍在。

### 15.4 Spectator

- 观战不创建 sandbox snapshot；
- 物品、技能树和持久状态不被替换；
- 实体不可见、不可碰撞、不可被攻击；
- 进入观战时在原大厅位置生成唯一人物残影；
- 残影正确显示角色外观、玩家名称和观战状态；
- 残影没有碰撞、组件副作用、AI 仇恨或 gameplay action；
- 只能旋转、缩放、切换目标和在当前 Zone 范围内移动视角；
- 所有动作和恶意 RPC 被服务端拒绝；
- 观战者装备、技能、光环和跟随者不影响比赛；
- 不能看到非目标 Instance；
- 退出观战后回大厅且运行时 guard 全部解除；
- 退出、断线、Instance 结束和异常清理后残影均被移除；
- 重复进入观战不会为同一 userid 留下多个残影；
- 服务器重启后回大厅，不恢复观战会话。

### 15.5 死亡策略

- GHOST 可移动但不能越界或跨局交互；
- REVIVABLE_CORPSE 不能移动，只有合法队友能救；
- 两个并发 Instance 可以使用不同死亡策略；
- 死亡不会自动进入 Spectator；
- Instance 结束后无论死亡形态都能恢复原 PlayerSandbox。

### 15.6 Scene、Scope 与恢复

- 场地构建和 SceneTransaction 不能修改 Zone 外 Tile；
- A 的地形变化不影响 B；
- 创建 Instance 时能从虚空完整构建所需 `SMALL/MEDIUM/LARGE` 尺寸的场地；
- `BLOCKING` 能冻结单个 Instance、完成全场或局部重构并安全恢复；
- `LIVE_PATCH` 只修改 affected bounds，正确处理占用 Tile 的玩家、物品、怪物和容器；
- 过期 scene revision 被拒绝，失败 Patch 能回滚或使 Zone 进入 QUARANTINED；
- 关闭 PhaseScope 时 `DESTROY`、`RETAIN_IN_PARENT_SCOPE`、`TRANSFER_TO_SCOPE` 和 `MODE_RESOLVE` 均按声明执行；
- Scope 转移不能跨 Instance，也不能把副本临时物品带入 Lobby；
- 正常结束、异常销毁和服务器重启都能清回 `IMPASSABLE`；
- 残留地面、实体或图层时 validation 失败并进入 QUARANTINED；
- 动态海陆切换完成专用客户端、寻路、船和存档测试。

### 15.7 Common Services

- 未声明的服务完全不启动；同一 Mode 的两个 Instance 拥有独立服务状态；
- Phase revision 能使上一阶段的 task、listener 和 RPC 失效；
- Clock 只影响目标 Instance/Phase，世界天数和其他 Instance 正常增长；
- 私人 Decision 只对目标玩家可见，Group 投票只接受 eligible voters；
- 超时弃权、相对多数、平票 RNG 和全员零票均得到唯一幂等结果；
- 同一 seed 和 stream 状态产生相同随机序列，不同命名 stream 互不干扰；
- Effect 随 Scope 自动撤销，断线重连后只重施加仍有效的 Effect；
- ScoreLedger 拒绝重复 event ID，冻结后拒绝新增分数；
- AudienceStateChannel 不向无权限玩家或其他 Instance 泄露状态。

### 15.8 EntityProfile

- 同名 Prefab 在两个并发 Instance 中可使用不同 Profile，原版和其他 Instance 不受影响；
- 怪物属性、技能、Brain、StateGraph 和 Loot Adapter 按 apply mode 正确执行；
- 物品属性、耐久、装备效果和主动功能只在所属 Instance 生效；
- `SPAWN_ONLY` 和 `BLOCKING_ONLY` Profile 不能被非法热切换；
- minion、projectile、trap 和 loot 继承 Instance、Scope 与正确 child profile；
- Prefab constructor 内同步生成和运行中异步生成的子实体均能正确传播 ownership；
- `REPLICATED` Profile 的客户端动作、Replica、StateGraph 表现和 UI 与服务端一致；
- GLOBAL、Lobby 和其他 Instance entity 不能被 Profile 修改；
- Instance 销毁后所有 Profile 实体和运行时 Effect 均被清理。

---

## 16. 分阶段实施

### Phase 0：激活与专用世界

- `enable_agon` shard gate；
- 自定义 worldgen；
- Lobby、Portal 和 Zone 虚空槽位坐标校验；
- layout version。

### Phase 1：Zone 与 Instance 骨架

- ZoneManager、InstanceManager；
- `SMALL/MEDIUM/LARGE` 尺寸分配、初始 ScenePlan 构建/清空；
- reservation、状态机和 TestMode；
- 双 Instance 并发。

### Phase 2：Scope、Scene 与隔离

- EntityRegistry、HierarchicalResourceScope；
- SceneService、scene revision 和 SceneTransaction；
- `BLOCKING` 与 `LIVE_PATCH`；
- InstanceRng、AudienceStateChannel；
- ownership 传播；
- damage、pickup、container、projectile 和 boundary policy。

### Phase 3：ParticipantGroup 与 Common Services

- ParticipantGroup；
- CommonServiceRegistry 和 opt-in 启动；
- PhaseService、ClockService；
- DecisionService；
- EffectService、ScoreLedger；
- 服务依赖、schema 和 disabled 行为验证。

### Phase 4：EntityProfile

- EntityProfileRegistry 和 Adapter contract；
- 怪物/Boss 属性、Brain、StateGraph 测试 Profile；
- 物品属性与功能测试 Profile；
- child profile 和 ownership 传播；
- `SPAWN_ONLY`、`BLOCKING_ONLY`、`LIVE_SAFE` 验证；
- `SERVER_ONLY`、`REPLICATED` 与客户端契约验证。

### Phase 5：PlayerSandbox

- 原状态事务；
- Inventory、Stats、SkillTree adapters；
- Character AdapterRegistry；
- 通用 PlayerProfile 与统一角色规格测试；
- RestorePending/Blocked。

### Phase 6：大厅与观战

- Lobby 状态；
- Spectator runtime guard；
- 跟随相机和受限自由相机；
- 远距离网络可见性压测。

### Phase 7：死亡策略

- GHOST；
- Instance-aware REVIVABLE_CORPSE；
- 复活接口和并发验证。

### Phase 8：持久化与重启中止

- schema/migration；
- `ABORT_ON_RESTART`；
- Scope/Scene rollback；
- Common Service、RNG、Profile membership 的清理所需状态；
- player restore queue。

### Phase 9：网络与后端适配

- audience-scoped classified/state channel、RPC validation；
- immutable result；
- settlement idempotency。

### Phase 10：正式 GameMode

在 `scripts/agon/modes/<mode_id>/` 中依次接入 FEAST、角斗场、PVP、钓鱼或其他正式模式。接入前必须用 TestMode 证明动态场景、Scope、Group 和 Common Services 可以组合使用；具体玩法不得反向污染公共层。

---

## 17. 明确后置的设计

以下内容不进入本阶段：

- 匹配算法、具体分组规则和完整 UI；
- FEAST 食谱、采集、关卡和评分；
- DUNGEON Wave、怪物、Boss、Buff 和掉落；
- BR 缩圈、局部 PvP、武器白名单和淘汰规则；
- 角斗场、钓鱼比赛等 Mode 的具体场景、Profile、Effect 和得分公式；
- 各 Mode 的具体死亡与复活数值；
- 后端认证、金币字段、排行榜和 Flask transport；
- `RESUME_IF_SUPPORTED` 的断点续玩。

---

## 18. 最终结论

The Agon 的公共底座是：

```text
一个专用 shard
+ 一个固定大厅
+ 多个预配置的虚空 Zone 槽位
+ 多个逻辑隔离 Instance
+ 同一个 Mod 内的 GameMode 插件目录
+ 分层 ResourceScope 与动态 ScenePlan
+ ParticipantGroup
+ 按需启用的 Common Services
+ Instance 级 EntityProfile 与 Effect 扩展点
+ Participant 状态沙箱
+ 独立 Spectator 观察层
+ 可插拔 PlayerDeathPolicy
```

必须长期保持的核心不变量：

```text
GameMode 只拥有规则。
Instance 拥有一局。
Zone 只提供空间。
Core 统一保证归属、安全和清理。
Common Services 提供可复用机制，但不定义玩法语义。
ParticipantGroup 只表达 Instance 内分组，不等于固定队伍规则。
EntityProfile 定义实体的模式版本，Effect 定义运行时临时变化。
Participant 才进入状态沙箱。
Spectator 只观察，不改变物资与持久状态。
Ghost/Corpse 仍属于原 Participant，不等于 Spectator。
TheWorld 只管理公共框架。
```

只要这些边界不被破坏，未来增加料理闯关、角斗场、PVP、钓鱼比赛、PVE、BR、塔防、竞速或其他玩法，都只需要增加新的 GameMode、配置和领域 Adapter，而不需要重新实现阶段、场景事务、投票、效果生命周期、实体定制、计分、网络 audience 和清理底座。
