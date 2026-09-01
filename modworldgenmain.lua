-- WP1 为世界生成复用同一配置硬门。
local AGON_WORLDGEN_ENABLED = GetModConfigData("enable_agon") == true

if not AGON_WORLDGEN_ENABLED then
    return
end

local WorldLayout = require("agon/config/world_layout")
local LayoutService = require("agon/world/layout_service")
local LobbyService = require("agon/world/lobby_service")

local valid, validation_code = LayoutService.ValidateDefinition(WorldLayout)
GLOBAL.assert(valid, "[TheAgon] invalid WorldLayout: " .. tostring(validation_code))

local AGON_WORLDGEN_START_ROOM = "TheAgonWorldgenStart"
local AGON_WORLDGEN_TASK = "TheAgonWorldgenTask"
local AGON_WORLDGEN_TASKSET = "the_agon_worldgen_taskset"
local AGON_WORLDGEN_START_LOCATION = "the_agon_worldgen_start"

local function GenerateAgonHall(id, entities, data)
    local map_width = data ~= nil and data.width or nil
    local map_height = data ~= nil and data.height or nil
    local anchor_tile, anchor_code = LayoutService.SelectWorldgenAnchor(
        WorldLayout,
        map_width,
        map_height
    )
    GLOBAL.assert(anchor_tile ~= nil,
        "[TheAgon] cannot select worldgen anchor: " .. tostring(anchor_code))

    local worldsim = GLOBAL ~= nil and GLOBAL.WorldSim or nil
    local generated, generated_code = LobbyService.GenerateWorldgen(
        worldsim,
        entities,
        map_width,
        map_height,
        anchor_tile,
        WorldLayout.lobby.portal_prefab
    )
    GLOBAL.assert(generated, "[TheAgon] cannot generate hall: " .. tostring(generated_code))
end

-- 通过官方 custom_tiles 回调在地图中央附近写入唯一大厅；其他节点保持 IMPASSABLE。
AddRoom(AGON_WORLDGEN_START_ROOM,
{
    value = WORLD_TILES.IMPASSABLE,
    colour = { r = 0.4, g = 0.1, b = 0.6, a = 1 },
    contents = {},
    custom_tiles =
    {
        GeneratorFunction = GenerateAgonHall,
        data = {},
    },
})

AddTask(AGON_WORLDGEN_TASK,
{
    locks = {},
    keys_given = {},
    room_choices =
    {
        ["Blank"] = 1,
    },
    background_room = "Blank",
    room_bg = WORLD_TILES.IMPASSABLE,
    cove_room_chance = 0,
    cove_room_max_edges = 0,
    colour = { r = 0.4, g = 0.1, b = 0.6, a = 1 },
})

AddTaskSet(AGON_WORLDGEN_TASKSET,
{
    location = "forest",
    tasks =
    {
        AGON_WORLDGEN_TASK,
    },
    valid_start_tasks =
    {
        AGON_WORLDGEN_TASK,
    },
    set_pieces = {},
})

AddStartLocation(AGON_WORLDGEN_START_LOCATION,
{
    name = "The Agon 大厅",
    location = "forest",
    start_node = AGON_WORLDGEN_START_ROOM,
})

-- 所有正式入口最终都落到 forest_map 的纯虚空参数；关闭配置时本文件不注册任何钩子。
AddLevelPreInitAny(function(level)
    level.location = "forest"
    -- LevelPreInitAny 在 ChooseTasks 取出 task set 后执行，因此同时覆盖实际任务列表。
    level.tasks =
    {
        AGON_WORLDGEN_TASK,
    }
    level.valid_start_tasks =
    {
        AGON_WORLDGEN_TASK,
    }
    level.numoptionaltasks = 0
    level.optionaltasks = nil
    level.set_pieces = nil
    level.background_node_range = { 0, 0 }
    level.required_prefabs = nil
    level.required_setpieces = nil
    level.numrandom_set_pieces = 0
    level.random_set_pieces = nil
    level.ocean_population = nil
    level.ocean_population_setpieces = nil
    level.ocean_prefill_setpieces = nil
    level.ordered_story_setpieces = nil
    level.substitutes = {}
    level.overrides =
    {
        task_set = AGON_WORLDGEN_TASKSET,
        start_location = AGON_WORLDGEN_START_LOCATION,
        world_size = "medium",
        keep_disconnected_tiles = true,
        no_joining_islands = true,
        has_ocean = false,
        roads = "never",
        layout_mode = "RestrictNodesByKey",
        boons = "never",
        traps = "never",
        poi = "never",
        protected = "never",
        touchstone = "never",
    }
end)
