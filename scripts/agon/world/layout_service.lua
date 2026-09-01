-- WorldLayout 的唯一解析、坐标转换和边界校验入口。

local LayoutService = {}

LayoutService.ERROR_CODES =
{
    INVALID_DEFINITION = "LAYOUT_INVALID_DEFINITION",
    INVALID_MAP_SIZE = "LAYOUT_INVALID_MAP_SIZE",
    INVALID_PORTAL_TILE = "LAYOUT_INVALID_PORTAL_TILE",
    PORTAL_NOT_FOUND = "PORTAL_NOT_FOUND",
    PORTAL_NOT_UNIQUE = "PORTAL_NOT_UNIQUE",
    TILE_SCALE_UNAVAILABLE = "TILE_SCALE_UNAVAILABLE",
    MAP_API_UNAVAILABLE = "MAP_API_UNAVAILABLE",
    RESOLVED_LAYOUT_INVALID = "RESOLVED_LAYOUT_INVALID",
}

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function IsInteger(value)
    return IsFiniteNumber(value) and math.floor(value) == value
end

local function IsOddInteger(value)
    return IsInteger(value) and value > 0 and value % 2 == 1
end

local function IsPoint(point)
    return type(point) == "table"
        and IsInteger(point.x)
        and IsInteger(point.z)
end

local function IsSize(size)
    return type(size) == "table"
        and IsOddInteger(size.width)
        and IsOddInteger(size.height)
end

local function CopyValue(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    for key, child in pairs(value) do
        -- Layout 快照只允许纯数据；函数和实体对象不进入存档。
        if type(child) ~= "function" and type(child) ~= "userdata" then
            copied[CopyValue(key)] = CopyValue(child)
        end
    end
    return copied
end

local function GetTileScale()
    if not IsFiniteNumber(TILE_SCALE) or TILE_SCALE <= 0 then
        return nil
    end
    return TILE_SCALE
end

local function IsMapSizeValid(width, height)
    return IsInteger(width) and width > 0 and IsInteger(height) and height > 0
end

local function IsTileInMap(tile_x, tile_z, width, height)
    return IsInteger(tile_x)
        and IsInteger(tile_z)
        and tile_x >= 0
        and tile_x < width
        and tile_z >= 0
        and tile_z < height
end

local function ValidateRegionSizes(region, label)
    if type(region) ~= "table"
        or not IsPoint(region.center_offset)
        or not IsSize(region.safe_size)
        or not IsSize(region.build_size)
        or not IsSize(region.hard_size) then
        return false, label .. "_SIZE_OR_CENTER_INVALID"
    end

    if region.safe_size.width >= region.build_size.width
        or region.safe_size.height >= region.build_size.height
        or region.build_size.width >= region.hard_size.width
        or region.build_size.height >= region.hard_size.height then
        return false, label .. "_BOUNDARY_ORDER_INVALID"
    end

    return true
end

local function BuildBounds(center, size)
    local half_width = math.floor(size.width / 2)
    local half_height = math.floor(size.height / 2)
    return
    {
        min = { x = center.x - half_width, z = center.z - half_height },
        max = { x = center.x + half_width, z = center.z + half_height },
        size = { width = size.width, height = size.height },
    }
end

local function BoundsContain(outer, inner, strict)
    if type(outer) ~= "table" or type(inner) ~= "table"
        or type(outer.min) ~= "table" or type(outer.max) ~= "table"
        or type(inner.min) ~= "table" or type(inner.max) ~= "table" then
        return false
    end

    local contains = outer.min.x <= inner.min.x
        and outer.max.x >= inner.max.x
        and outer.min.z <= inner.min.z
        and outer.max.z >= inner.max.z
    if not contains then
        return false
    end

    if strict then
        return outer.min.x < inner.min.x
            and outer.max.x > inner.max.x
            and outer.min.z < inner.min.z
            and outer.max.z > inner.max.z
    end
    return true
end

local function AxisGap(min_a, max_a, min_b, max_b)
    if max_a < min_b then
        return min_b - max_a - 1
    elseif max_b < min_a then
        return min_a - max_b - 1
    end
    return 0
end

local function BoundsGap(first, second)
    local x_gap = AxisGap(first.min.x, first.max.x, second.min.x, second.max.x)
    local z_gap = AxisGap(first.min.z, first.max.z, second.min.z, second.max.z)
    return math.sqrt(x_gap * x_gap + z_gap * z_gap)
end

local function BoundsWithinMap(bounds, width, height, margin)
    return bounds.min.x >= margin
        and bounds.min.z >= margin
        and bounds.max.x < width - margin
        and bounds.max.z < height - margin
end

local function BoundsEqual(first, second)
    return type(first) == "table"
        and type(second) == "table"
        and type(first.min) == "table"
        and type(first.max) == "table"
        and type(second.min) == "table"
        and type(second.max) == "table"
        and first.min.x == second.min.x
        and first.min.z == second.min.z
        and first.max.x == second.max.x
        and first.max.z == second.max.z
        and type(first.size) == "table"
        and type(second.size) == "table"
        and first.size.width == second.size.width
        and first.size.height == second.size.height
end

local function MakeRegion(region_id, category, center_offset, sizes, portal_tile)
    local center =
    {
        x = portal_tile.x + center_offset.x,
        z = portal_tile.z + center_offset.z,
    }

    return
    {
        zone_id = region_id,
        zone_category = category,
        center_offset = CopyValue(center_offset),
        center = center,
        safe_bounds = BuildBounds(center, sizes.safe_size),
        build_bounds = BuildBounds(center, sizes.build_size),
        hard_bounds = BuildBounds(center, sizes.hard_size),
    }
end

local function AttachWorldCenter(region, map_width, map_height)
    local world_x, world_z = LayoutService.TileToWorld(
        region.center.x,
        region.center.z,
        map_width,
        map_height
    )
    if world_x == nil then
        return false
    end
    region.center_world = { x = world_x, z = world_z }
    return true
end

local function GetStaticRegions(definition)
    local regions =
    {
        {
            zone_id = "lobby",
            zone_category = "LOBBY",
            center_offset = definition.lobby.center_offset,
            safe_size = definition.lobby.safe_size,
            build_size = definition.lobby.build_size,
            hard_size = definition.lobby.hard_size,
        },
    }

    for index = 1, #definition.zones do
        local zone = definition.zones[index]
        local sizes = definition.zone_sizes[zone.zone_category]
        table.insert(regions,
        {
            zone_id = zone.zone_id,
            zone_category = zone.zone_category,
            center_offset = zone.center_offset,
            safe_size = sizes.safe_size,
            build_size = sizes.build_size,
            hard_size = sizes.hard_size,
        })
    end

    return regions
end

local function GetRelativeFootprint(definition)
    local regions = GetStaticRegions(definition)
    local min_x, min_z = math.huge, math.huge
    local max_x, max_z = -math.huge, -math.huge

    for index = 1, #regions do
        local region = regions[index]
        local half_width = math.floor(region.hard_size.width / 2)
        local half_height = math.floor(region.hard_size.height / 2)
        min_x = math.min(min_x, region.center_offset.x - half_width)
        max_x = math.max(max_x, region.center_offset.x + half_width)
        min_z = math.min(min_z, region.center_offset.z - half_height)
        max_z = math.max(max_z, region.center_offset.z + half_height)
    end

    return { min_x = min_x, max_x = max_x, min_z = min_z, max_z = max_z }
end

local EXPECTED_ZONE_SIZES =
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
}

function LayoutService.ValidateDefinition(definition)
    if type(definition) ~= "table" then
        return false, LayoutService.ERROR_CODES.INVALID_DEFINITION
    end
    if definition.layout_version ~= 1 then
        return false, "LAYOUT_VERSION_UNSUPPORTED"
    end
    if type(definition.world_size_tiles) ~= "table"
        or definition.world_size_tiles.width ~= 400
        or definition.world_size_tiles.height ~= 400 then
        return false, "LAYOUT_WORLD_SIZE_INVALID"
    end
    if definition.coordinate_unit ~= "TILE_OFFSET_FROM_PORTAL" then
        return false, "LAYOUT_COORDINATE_UNIT_INVALID"
    end
    if type(definition.constraints) ~= "table"
        or definition.constraints.minimum_zone_gap_tiles ~= 24
        or definition.constraints.minimum_map_edge_margin_tiles ~= 36 then
        return false, "LAYOUT_CONSTRAINTS_INVALID"
    end

    local lobby_ok, lobby_code = ValidateRegionSizes(definition.lobby, "LOBBY")
    if not lobby_ok then
        return false, lobby_code
    end
    if definition.lobby.center_offset.x ~= 0 or definition.lobby.center_offset.z ~= 0
        or definition.lobby.portal_prefab ~= "multiplayer_portal"
        or definition.lobby.terrain_layout ~= "MAXWELL_RITUAL_HALL_V1" then
        return false, "LOBBY_ANCHOR_OR_TERRAIN_INVALID"
    end

    if type(definition.zone_sizes) ~= "table" then
        return false, "LAYOUT_ZONE_SIZES_MISSING"
    end

    local expected_categories = { SMALL = 4, MEDIUM = 4, LARGE = 2 }
    for category, _ in pairs(expected_categories) do
        local sizes = definition.zone_sizes[category]
        if type(sizes) ~= "table" then
            return false, category .. "_SIZE_DEFINITION_INVALID"
        end
        local size_ok, size_code = ValidateRegionSizes(
            {
                center_offset = { x = 0, z = 0 },
                safe_size = sizes.safe_size,
                build_size = sizes.build_size,
                hard_size = sizes.hard_size,
            },
            category
        )
        if not size_ok then
            return false, size_code
        end
        local expected_sizes = EXPECTED_ZONE_SIZES[category]
        if sizes.safe_size.width ~= expected_sizes.safe_size.width
            or sizes.safe_size.height ~= expected_sizes.safe_size.height
            or sizes.build_size.width ~= expected_sizes.build_size.width
            or sizes.build_size.height ~= expected_sizes.build_size.height
            or sizes.hard_size.width ~= expected_sizes.hard_size.width
            or sizes.hard_size.height ~= expected_sizes.hard_size.height then
            return false, category .. "_SIZE_VALUE_INVALID"
        end
        if category == "LARGE" and sizes.safe_size.width <= sizes.safe_size.height then
            return false, "LARGE_ZONE_NOT_HORIZONTAL"
        end
        expected_categories[category] = 0
    end

    if type(definition.zones) ~= "table" or #definition.zones ~= 10 then
        return false, "LAYOUT_ZONE_COUNT_INVALID"
    end

    local zone_ids = {}
    for index = 1, #definition.zones do
        local zone = definition.zones[index]
        if type(zone) ~= "table"
            or type(zone.zone_id) ~= "string"
            or zone.zone_id == ""
            or zone_ids[zone.zone_id]
            or expected_categories[zone.zone_category] == nil
            or type(definition.zone_sizes[zone.zone_category]) ~= "table"
            or not IsPoint(zone.center_offset) then
            return false, "LAYOUT_ZONE_DEFINITION_INVALID"
        end
        zone_ids[zone.zone_id] = true
        expected_categories[zone.zone_category] = expected_categories[zone.zone_category] + 1
    end

    if expected_categories.SMALL ~= 4
        or expected_categories.MEDIUM ~= 4
        or expected_categories.LARGE ~= 2 then
        return false, "LAYOUT_ZONE_CATEGORY_COUNT_INVALID"
    end

    local static_regions = GetStaticRegions(definition)

    local spawn_points = definition.lobby.spawn_and_return_points
    if type(spawn_points) ~= "table" or #spawn_points ~= 8 then
        return false, "LOBBY_SPAWN_POINT_COUNT_INVALID"
    end
    local spawn_ids = {}
    for index = 1, #spawn_points do
        local point = spawn_points[index]
        local key = IsPoint(point) and tostring(point.x) .. ":" .. tostring(point.z) or "invalid"
        if not IsPoint(point) or spawn_ids[key]
            or math.abs(point.x) > math.floor(definition.lobby.safe_size.width / 2)
            or math.abs(point.z) > math.floor(definition.lobby.safe_size.height / 2) then
            return false, "LOBBY_SPAWN_POINT_INVALID"
        end
        spawn_ids[key] = true
    end

    for first_index = 1, #static_regions do
        local first = static_regions[first_index]
        local first_bounds = BuildBounds({ x = first.center_offset.x, z = first.center_offset.z }, first.hard_size)
        for second_index = first_index + 1, #static_regions do
            local second = static_regions[second_index]
            local second_bounds = BuildBounds({ x = second.center_offset.x, z = second.center_offset.z }, second.hard_size)
            if BoundsGap(first_bounds, second_bounds) < definition.constraints.minimum_zone_gap_tiles then
                return false, "LAYOUT_ZONE_GAP_INVALID"
            end
        end
    end

    local footprint = GetRelativeFootprint(definition)
    local margin = definition.constraints.minimum_map_edge_margin_tiles
    local center_x = math.floor(definition.world_size_tiles.width / 2)
    local center_z = math.floor(definition.world_size_tiles.height / 2)
    if center_x + footprint.min_x < margin
        or center_x + footprint.max_x >= definition.world_size_tiles.width - margin
        or center_z + footprint.min_z < margin
        or center_z + footprint.max_z >= definition.world_size_tiles.height - margin then
        return false, "LAYOUT_WORLD_EDGE_MARGIN_INVALID"
    end

    return true
end

function LayoutService.BuildBounds(center, size)
    if not IsPoint(center) or not IsSize(size) then
        return nil, LayoutService.ERROR_CODES.INVALID_DEFINITION
    end
    return BuildBounds(center, size)
end

function LayoutService.TileToWorld(tile_x, tile_z, map_width, map_height)
    if not IsMapSizeValid(map_width, map_height)
        or not IsTileInMap(tile_x, tile_z, map_width, map_height) then
        return nil, LayoutService.ERROR_CODES.INVALID_MAP_SIZE
    end

    local tile_scale = GetTileScale()
    if tile_scale == nil then
        return nil, LayoutService.ERROR_CODES.TILE_SCALE_UNAVAILABLE
    end

    -- 与官方 forest_map.lua / ShowDebug 使用同一套 Tile 中心坐标公式。
    local world_x = (tile_x - map_width / 2.0) * tile_scale
    local world_z = (tile_z - map_height / 2.0) * tile_scale
    return world_x, world_z
end

function LayoutService.WorldToTile(map, world_x, world_y, world_z)
    if map == nil or type(map.GetTileCoordsAtPoint) ~= "function" then
        return nil, nil, LayoutService.ERROR_CODES.MAP_API_UNAVAILABLE
    end
    if not IsFiniteNumber(world_x) or not IsFiniteNumber(world_y)
        or not IsFiniteNumber(world_z) then
        return nil, nil, LayoutService.ERROR_CODES.INVALID_PORTAL_TILE
    end

    local tile_x, tile_z = map:GetTileCoordsAtPoint(world_x, world_y, world_z)
    if not IsInteger(tile_x) or not IsInteger(tile_z) then
        return nil, nil, LayoutService.ERROR_CODES.INVALID_PORTAL_TILE
    end
    return tile_x, tile_z
end

function LayoutService.SelectWorldgenAnchor(definition, map_width, map_height)
    local valid, code = LayoutService.ValidateDefinition(definition)
    if not valid then
        return nil, code
    end
    if not IsMapSizeValid(map_width, map_height) then
        return nil, LayoutService.ERROR_CODES.INVALID_MAP_SIZE
    end

    local footprint = GetRelativeFootprint(definition)
    local margin = definition.constraints.minimum_map_edge_margin_tiles
    local min_x = margin - footprint.min_x
    local max_x = map_width - margin - 1 - footprint.max_x
    local min_z = margin - footprint.min_z
    local max_z = map_height - margin - 1 - footprint.max_z
    if min_x > max_x or min_z > max_z then
        return nil, "LAYOUT_NO_VALID_WORLDGEN_ANCHOR"
    end

    local center_x = math.floor(map_width / 2)
    local center_z = math.floor(map_height / 2)
    return
    {
        x = math.max(min_x, math.min(max_x, center_x)),
        z = math.max(min_z, math.min(max_z, center_z)),
    }
end

function LayoutService.Resolve(definition, portal_tile, map_width, map_height)
    local valid, code = LayoutService.ValidateDefinition(definition)
    if not valid then
        return nil, code
    end
    if not IsMapSizeValid(map_width, map_height) then
        return nil, LayoutService.ERROR_CODES.INVALID_MAP_SIZE
    end
    if not IsTileInMap(portal_tile ~= nil and portal_tile.x or nil,
        portal_tile ~= nil and portal_tile.z or nil, map_width, map_height) then
        return nil, LayoutService.ERROR_CODES.INVALID_PORTAL_TILE
    end

    local resolved =
    {
        layout_version = definition.layout_version,
        coordinate_unit = definition.coordinate_unit,
        map_size = { width = map_width, height = map_height },
        portal_tile = { x = portal_tile.x, z = portal_tile.z },
        lobby = MakeRegion(
            "lobby",
            "LOBBY",
            definition.lobby.center_offset,
            {
                safe_size = definition.lobby.safe_size,
                build_size = definition.lobby.build_size,
                hard_size = definition.lobby.hard_size,
            },
            portal_tile
        ),
        zones = {},
    }

    if not AttachWorldCenter(resolved.lobby, map_width, map_height) then
        return nil, LayoutService.ERROR_CODES.TILE_SCALE_UNAVAILABLE
    end

    local world_x, world_z = LayoutService.TileToWorld(portal_tile.x, portal_tile.z, map_width, map_height)
    if world_x ~= nil then
        resolved.portal_world = { x = world_x, z = world_z }
    end

    for index = 1, #definition.zones do
        local zone = definition.zones[index]
        local resolved_zone = MakeRegion(
                zone.zone_id,
                zone.zone_category,
                zone.center_offset,
                definition.zone_sizes[zone.zone_category],
                portal_tile
            )
        if not AttachWorldCenter(resolved_zone, map_width, map_height) then
            return nil, LayoutService.ERROR_CODES.TILE_SCALE_UNAVAILABLE
        end
        table.insert(resolved.zones, resolved_zone)
    end

    local resolved_valid, resolved_code = LayoutService.ValidateResolvedLayout(
        definition,
        resolved,
        map_width,
        map_height
    )
    if not resolved_valid then
        return nil, resolved_code
    end
    return resolved
end

function LayoutService.ValidateResolvedLayout(definition, resolved, map_width, map_height)
    local valid, code = LayoutService.ValidateDefinition(definition)
    if not valid then
        return false, code
    end
    if type(resolved) ~= "table"
        or resolved.layout_version ~= definition.layout_version
        or resolved.coordinate_unit ~= definition.coordinate_unit
        or type(resolved.map_size) ~= "table"
        or resolved.map_size.width ~= map_width
        or resolved.map_size.height ~= map_height
        or not IsMapSizeValid(map_width, map_height)
        or type(resolved.portal_tile) ~= "table"
        or not IsTileInMap(resolved.portal_tile.x, resolved.portal_tile.z, map_width, map_height)
        or type(resolved.lobby) ~= "table"
        or type(resolved.lobby.center) ~= "table"
        or type(resolved.lobby.center_offset) ~= "table"
        or type(resolved.zones) ~= "table"
        or #resolved.zones ~= #definition.zones then
        return false, LayoutService.ERROR_CODES.RESOLVED_LAYOUT_INVALID
    end

    if resolved.lobby.zone_id ~= "lobby"
        or resolved.lobby.zone_category ~= "LOBBY" then
        return false, "RESOLVED_LOBBY_INVALID"
    end

    local regions = { resolved.lobby }
    if not IsInteger(resolved.lobby.center.x)
        or not IsInteger(resolved.lobby.center.z)
        or not IsInteger(resolved.lobby.center_offset.x)
        or not IsInteger(resolved.lobby.center_offset.z)
        or resolved.lobby.center.x ~= resolved.portal_tile.x
        or resolved.lobby.center.z ~= resolved.portal_tile.z
        or resolved.lobby.center_offset.x ~= 0
        or resolved.lobby.center_offset.z ~= 0 then
        return false, "LOBBY_PORTAL_CENTER_INVALID"
    end

    local zone_ids = {}
    table.insert(zone_ids, "lobby")
    for index = 1, #definition.zones do
        local expected = definition.zones[index]
        local actual = resolved.zones[index]
        if type(actual) ~= "table"
            or actual.zone_id ~= expected.zone_id
            or actual.zone_category ~= expected.zone_category
            or type(actual.center) ~= "table"
            or type(actual.center_offset) ~= "table"
            or actual.center_offset.x ~= expected.center_offset.x
            or actual.center_offset.z ~= expected.center_offset.z
            or actual.center.x ~= resolved.portal_tile.x + expected.center_offset.x
            or actual.center.z ~= resolved.portal_tile.z + expected.center_offset.z
            or zone_ids[actual.zone_id] then
            return false, "RESOLVED_ZONE_INVALID"
        end
        zone_ids[actual.zone_id] = true
        table.insert(regions, actual)
    end

    local margin = definition.constraints.minimum_map_edge_margin_tiles
    local expected_lobby = MakeRegion(
        "lobby",
        "LOBBY",
        definition.lobby.center_offset,
        {
            safe_size = definition.lobby.safe_size,
            build_size = definition.lobby.build_size,
            hard_size = definition.lobby.hard_size,
        },
        resolved.portal_tile
    )
    if not BoundsEqual(resolved.lobby.safe_bounds, expected_lobby.safe_bounds)
        or not BoundsEqual(resolved.lobby.build_bounds, expected_lobby.build_bounds)
        or not BoundsEqual(resolved.lobby.hard_bounds, expected_lobby.hard_bounds) then
        return false, "RESOLVED_LOBBY_BOUNDS_INVALID"
    end

    local function HasExpectedWorldCenter(region)
        if type(region.center_world) ~= "table"
            or not IsFiniteNumber(region.center_world.x)
            or not IsFiniteNumber(region.center_world.z) then
            return false
        end
        local expected_world_x, expected_world_z = LayoutService.TileToWorld(
            region.center.x,
            region.center.z,
            map_width,
            map_height
        )
        return expected_world_x ~= nil
            and math.abs(region.center_world.x - expected_world_x) <= 0.0001
            and math.abs(region.center_world.z - expected_world_z) <= 0.0001
    end

    if resolved.lobby.center_world ~= nil and not HasExpectedWorldCenter(resolved.lobby) then
        return false, "RESOLVED_LOBBY_WORLD_CENTER_INVALID"
    end

    for index = 1, #regions do
        local region = regions[index]
        local expected_region = nil
        if index > 1 then
            local definition_zone = definition.zones[index - 1]
            expected_region = MakeRegion(
                definition_zone.zone_id,
                definition_zone.zone_category,
                definition_zone.center_offset,
                definition.zone_sizes[definition_zone.zone_category],
                resolved.portal_tile
            )
        else
            expected_region = expected_lobby
        end
        if not BoundsEqual(region.safe_bounds, expected_region.safe_bounds)
            or not BoundsEqual(region.build_bounds, expected_region.build_bounds)
            or not BoundsEqual(region.hard_bounds, expected_region.hard_bounds) then
            return false, "RESOLVED_REGION_BOUNDS_INVALID"
        end
        if region.center_world ~= nil and not HasExpectedWorldCenter(region) then
            return false, "RESOLVED_REGION_WORLD_CENTER_INVALID"
        end
        if not BoundsContain(region.build_bounds, region.safe_bounds, true)
            or not BoundsContain(region.hard_bounds, region.build_bounds, true)
            or not BoundsWithinMap(region.hard_bounds, map_width, map_height, margin) then
            return false, "RESOLVED_REGION_BOUNDS_INVALID"
        end
    end

    for first_index = 1, #regions do
        for second_index = first_index + 1, #regions do
            if BoundsGap(regions[first_index].hard_bounds, regions[second_index].hard_bounds)
                < definition.constraints.minimum_zone_gap_tiles then
                return false, "RESOLVED_ZONE_GAP_INVALID"
            end
        end
    end

    for index = 1, #definition.lobby.spawn_and_return_points do
        local point = definition.lobby.spawn_and_return_points[index]
        if point.x < math.floor(definition.lobby.safe_size.width / 2) * -1
            or point.x > math.floor(definition.lobby.safe_size.width / 2)
            or point.z < math.floor(definition.lobby.safe_size.height / 2) * -1
            or point.z > math.floor(definition.lobby.safe_size.height / 2) then
            return false, "RESOLVED_LOBBY_SPAWN_POINT_INVALID"
        end
    end

    return true
end

function LayoutService.FindPortal(entities, portal_prefab)
    local portal = nil
    local count = 0
    if type(entities) ~= "table" then
        return nil, 0, LayoutService.ERROR_CODES.PORTAL_NOT_FOUND
    end

    for _, entity in pairs(entities) do
        if entity ~= nil and entity.prefab == portal_prefab then
            count = count + 1
            portal = entity
        end
    end

    if count == 0 then
        return nil, count, LayoutService.ERROR_CODES.PORTAL_NOT_FOUND
    end
    if count ~= 1 then
        return nil, count, LayoutService.ERROR_CODES.PORTAL_NOT_UNIQUE
    end
    return portal, count
end

function LayoutService.AreResolvedLayoutsCompatible(saved_layout, current_layout)
    if type(saved_layout) ~= "table" or type(current_layout) ~= "table"
        or saved_layout.layout_version ~= current_layout.layout_version
        or saved_layout.coordinate_unit ~= current_layout.coordinate_unit
        or type(saved_layout.map_size) ~= "table"
        or type(current_layout.map_size) ~= "table"
        or saved_layout.map_size.width ~= current_layout.map_size.width
        or saved_layout.map_size.height ~= current_layout.map_size.height
        or type(saved_layout.portal_tile) ~= "table"
        or type(current_layout.portal_tile) ~= "table"
        or saved_layout.portal_tile.x ~= current_layout.portal_tile.x
        or saved_layout.portal_tile.z ~= current_layout.portal_tile.z
        or type(saved_layout.zones) ~= "table"
        or type(current_layout.zones) ~= "table"
        or #saved_layout.zones ~= #current_layout.zones then
        return false
    end

    for index = 1, #current_layout.zones do
        local saved_zone = saved_layout.zones[index]
        local current_zone = current_layout.zones[index]
        if type(saved_zone) ~= "table"
            or type(current_zone) ~= "table"
            or saved_zone.zone_id ~= current_zone.zone_id
            or saved_zone.center.x ~= current_zone.center.x
            or saved_zone.center.z ~= current_zone.center.z then
            return false
        end
    end
    return true
end

function LayoutService.CopyPureData(value)
    return CopyValue(value)
end

return LayoutService
