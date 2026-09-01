-- WP1 大厅固定图案的 worldgen 写入和运行时逐 Tile 校验。

local LayoutService = require("agon/world/layout_service")

local LobbyService = {}
local HALL_RADIUS = 5

local function GetHallTileName(relative_x, relative_z)
    if math.abs(relative_x) > HALL_RADIUS or math.abs(relative_z) > HALL_RADIUS then
        return nil
    end

    -- 按正式顺序覆盖：CARPET2 -> WOODFLOOR -> CHECKER -> BRICK_GLOW。
    local tile_name = "CARPET2"
    if math.abs(relative_x) <= 1 or math.abs(relative_z) <= 1 then
        tile_name = "WOODFLOOR"
    end
    if math.abs(relative_x) <= 2 and math.abs(relative_z) <= 2 then
        tile_name = "CHECKER"
    end
    if math.abs(relative_x) == HALL_RADIUS or math.abs(relative_z) == HALL_RADIUS then
        tile_name = "BRICK_GLOW"
    end
    return tile_name
end

local function GetHallTileId(tile_name)
    if WORLD_TILES == nil then
        return nil
    end
    return WORLD_TILES[tile_name]
end

local function IsInteger(value)
    return type(value) == "number" and math.floor(value) == value
end

function LobbyService.GetHallTileName(relative_x, relative_z)
    return GetHallTileName(relative_x, relative_z)
end

function LobbyService.GetHallTile(relative_x, relative_z)
    local tile_name = GetHallTileName(relative_x, relative_z)
    if tile_name == nil then
        return nil
    end
    return GetHallTileId(tile_name), tile_name
end

function LobbyService.GenerateWorldgen(worldsim, entities, map_width, map_height, anchor_tile, portal_prefab)
    if worldsim == nil or type(worldsim.SetTile) ~= "function"
        or type(entities) ~= "table"
        or not IsInteger(map_width)
        or not IsInteger(map_height)
        or type(anchor_tile) ~= "table"
        or not IsInteger(anchor_tile.x)
        or not IsInteger(anchor_tile.z) then
        return false, "WORLDGEN_ARGUMENT_INVALID"
    end

    local portal_world_x, portal_world_z = LayoutService.TileToWorld(
        anchor_tile.x,
        anchor_tile.z,
        map_width,
        map_height
    )
    if portal_world_x == nil then
        return false, "WORLDGEN_ANCHOR_INVALID"
    end

    for relative_z = -HALL_RADIUS, HALL_RADIUS do
        for relative_x = -HALL_RADIUS, HALL_RADIUS do
            local tile_id, tile_name = LobbyService.GetHallTile(relative_x, relative_z)
            if tile_id == nil then
                return false, "WORLDGEN_TILE_UNAVAILABLE_" .. tostring(tile_name)
            end
            worldsim:SetTile(anchor_tile.x + relative_x, anchor_tile.z + relative_z, tile_id)
        end
    end

    local prefab = portal_prefab or "multiplayer_portal"
    if entities[prefab] == nil then
        entities[prefab] = {}
    end
    -- 不清理已有记录；若其他内容额外生成 Portal，运行时唯一性校验必须失败。
    table.insert(entities[prefab], { x = portal_world_x, z = portal_world_z })

    print(string.format(
        "[TheAgon] worldgen hall layout=%s anchor_tile=(%d,%d) portal_world=(%.2f,%.2f)",
        "MAXWELL_RITUAL_HALL_V1",
        anchor_tile.x,
        anchor_tile.z,
        portal_world_x,
        portal_world_z
    ))
    return true
end

local function IsHallTile(anchor_tile, tile_x, tile_z)
    return math.abs(tile_x - anchor_tile.x) <= HALL_RADIUS
        and math.abs(tile_z - anchor_tile.z) <= HALL_RADIUS
end

function LobbyService.ValidateHallTiles(map, map_width, map_height, anchor_tile)
    if map == nil or type(map.GetTileAtPoint) ~= "function" then
        return false, "MAP_API_UNAVAILABLE"
    end

    for relative_z = -HALL_RADIUS, HALL_RADIUS do
        for relative_x = -HALL_RADIUS, HALL_RADIUS do
            local expected_tile, expected_name = LobbyService.GetHallTile(relative_x, relative_z)
            local world_x, world_z = LayoutService.TileToWorld(
                anchor_tile.x + relative_x,
                anchor_tile.z + relative_z,
                map_width,
                map_height
            )
            if expected_tile == nil or world_x == nil then
                return false, "HALL_EXPECTED_TILE_INVALID", {
                    relative_x = relative_x,
                    relative_z = relative_z,
                    expected_name = expected_name,
                }
            end
            local actual_tile = map:GetTileAtPoint(world_x, 0, world_z)
            if actual_tile ~= expected_tile then
                return false, "HALL_TILE_MISMATCH", {
                    tile_x = anchor_tile.x + relative_x,
                    tile_z = anchor_tile.z + relative_z,
                    expected_tile = expected_tile,
                    actual_tile = actual_tile,
                    expected_name = expected_name,
                }
            end
        end
    end
    return true
end

function LobbyService.ValidateVoidTiles(map, map_width, map_height, anchor_tile)
    if map == nil or type(map.GetTileAtPoint) ~= "function" then
        return false, "MAP_API_UNAVAILABLE"
    end
    if WORLD_TILES == nil or WORLD_TILES.IMPASSABLE == nil then
        return false, "IMPASSABLE_TILE_UNAVAILABLE"
    end

    local checked = 0
    for tile_z = 0, map_height - 1 do
        for tile_x = 0, map_width - 1 do
            if not IsHallTile(anchor_tile, tile_x, tile_z) then
                local world_x, world_z = LayoutService.TileToWorld(tile_x, tile_z, map_width, map_height)
                if world_x == nil then
                    return false, "VOID_EXPECTED_TILE_INVALID", {
                        tile_x = tile_x,
                        tile_z = tile_z,
                        checked_tiles = checked,
                    }
                end
                local actual_tile = map:GetTileAtPoint(world_x, 0, world_z)
                checked = checked + 1
                if actual_tile ~= WORLD_TILES.IMPASSABLE then
                    return false, "VOID_TILE_MISMATCH", {
                        tile_x = tile_x,
                        tile_z = tile_z,
                        actual_tile = actual_tile,
                        checked_tiles = checked,
                    }
                end
            end
        end
    end
    return true, nil, { checked_tiles = checked }
end

return LobbyService
