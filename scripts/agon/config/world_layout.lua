-- The Agon WP1 的静态世界布局定义。
-- 所有坐标都是相对于运行时解析出的唯一 Portal Tile 的偏移。

local WorldLayout =
{
    layout_version = 1,
    world_size_tiles = { width = 400, height = 400 },
    coordinate_unit = "TILE_OFFSET_FROM_PORTAL",

    constraints =
    {
        minimum_zone_gap_tiles = 24,
        minimum_map_edge_margin_tiles = 36,
    },

    lobby =
    {
        center_offset = { x = 0, z = 0 },
        safe_size = { width = 9, height = 9 },
        build_size = { width = 11, height = 11 },
        hard_size = { width = 15, height = 15 },
        portal_prefab = "multiplayer_portal",
        spawn_and_return_points =
        {
            { x = 3, z = 0 },
            { x = -3, z = 0 },
            { x = 0, z = 3 },
            { x = 0, z = -3 },
            { x = 2, z = 2 },
            { x = 2, z = -2 },
            { x = -2, z = 2 },
            { x = -2, z = -2 },
        },
        terrain_layout = "MAXWELL_RITUAL_HALL_V1",
    },

    zone_sizes =
    {
        SMALL =
        {
            safe_size = { width = 11, height = 11 },
            build_size = { width = 13, height = 13 },
            hard_size = { width = 17, height = 17 },
        },
        MEDIUM =
        {
            safe_size = { width = 29, height = 29 },
            build_size = { width = 31, height = 31 },
            hard_size = { width = 35, height = 35 },
        },
        LARGE =
        {
            safe_size = { width = 121, height = 61 },
            build_size = { width = 123, height = 63 },
            hard_size = { width = 127, height = 67 },
        },
    },

    zones =
    {
        -- SMALL：安全 11x11，构建 13x13，硬边界 17x17。
        { zone_id = "small_01", zone_category = "SMALL", center_offset = { x = -155, z = 65 } },
        { zone_id = "small_02", zone_category = "SMALL", center_offset = { x = 155, z = 65 } },
        { zone_id = "small_03", zone_category = "SMALL", center_offset = { x = -155, z = -65 } },
        { zone_id = "small_04", zone_category = "SMALL", center_offset = { x = 155, z = -65 } },

        -- MEDIUM：安全 29x29，构建 31x31，硬边界 35x35。
        { zone_id = "medium_01", zone_category = "MEDIUM", center_offset = { x = -105, z = 65 } },
        { zone_id = "medium_02", zone_category = "MEDIUM", center_offset = { x = 105, z = 65 } },
        { zone_id = "medium_03", zone_category = "MEDIUM", center_offset = { x = -105, z = -65 } },
        { zone_id = "medium_04", zone_category = "MEDIUM", center_offset = { x = 105, z = -65 } },

        -- LARGE 横向：安全 121x61，构建 123x63，硬边界 127x67。
        { zone_id = "large_01", zone_category = "LARGE", center_offset = { x = 0, z = 130 } },
        { zone_id = "large_02", zone_category = "LARGE", center_offset = { x = 0, z = -130 } },
    },
}

return WorldLayout
