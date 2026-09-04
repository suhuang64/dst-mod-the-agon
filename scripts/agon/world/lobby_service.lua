-- WP1 大厅固定图案的 worldgen 写入和运行时逐 Tile 校验。

local LayoutService = require("agon/world/layout_service")

local LobbyService = {}
LobbyService.SCHEMA_VERSION = 1
LobbyService.SERVICE_ID = "lobby"
LobbyService.SERVICE_VERSION = 1
local HALL_RADIUS = 5

LobbyService.STATES =
{
    LOBBY = "LOBBY",
    SPECTATOR_RETURN = "SPECTATOR_RETURN",
}

LobbyService.ERROR_CODES =
{
    INVALID_SERVICE = "LOBBY_SERVICE_INVALID",
    INVALID_LAYOUT = "LOBBY_LAYOUT_INVALID",
    INVALID_PLAYER = "LOBBY_PLAYER_INVALID",
    INVALID_POINT = "LOBBY_POINT_INVALID",
    POINT_NOT_SAFE = "LOBBY_POINT_NOT_SAFE",
    NO_FREE_POINT = "LOBBY_NO_FREE_POINT",
    PLAYER_ALREADY_TRACKED = "LOBBY_PLAYER_ALREADY_TRACKED",
    SESSION_NOT_FOUND = "LOBBY_SESSION_NOT_FOUND",
}

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

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function IsPoint(value)
    return type(value) == "table"
        and IsInteger(value.x)
        and IsInteger(value.z)
end

local function CopyValue(value)
    if type(value) ~= "table" then
        return value
    end
    local copied = {}
    for key, item in pairs(value) do
        if type(key) ~= "function" and type(key) ~= "userdata"
            and type(item) ~= "function" and type(item) ~= "userdata" then
            copied[CopyValue(key)] = CopyValue(item)
        end
    end
    return copied
end

local function ProtectedCall(callback, ...)
    return pcall(callback, ...)
end

local function GetNow(self)
    if type(self.now_fn) == "function" then
        return self.now_fn()
    end
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

local function GetUserid(player)
    return type(player) == "table"
        and IsNonEmptyString(player.userid)
        and player.userid
        or nil
end

local function PointKey(point)
    return tostring(point.x) .. ":" .. tostring(point.z)
end

local function IsInsideBounds(point, bounds)
    return IsPoint(point)
        and type(bounds) == "table"
        and IsPoint(bounds.min)
        and IsPoint(bounds.max)
        and point.x >= bounds.min.x
        and point.x <= bounds.max.x
        and point.z >= bounds.min.z
        and point.z <= bounds.max.z
end

local function GetMapSize(self)
    return self.layout ~= nil and self.layout.map_size or nil
end

local function ResolveTileWorld(self, tile)
    local map_size = GetMapSize(self)
    if not IsPoint(tile) or type(map_size) ~= "table" then
        return nil
    end
    local world_x, world_z = LayoutService.TileToWorld(
        tile.x,
        tile.z,
        map_size.width,
        map_size.height
    )
    if world_x == nil then
        return nil
    end
    return { x = world_x, y = 0, z = world_z }
end

local function GetWorldPosition(player)
    if type(player) ~= "table" then
        return nil
    end
    if type(player.agon_lobby_position) == "table"
        and IsFiniteNumber(player.agon_lobby_position.x)
        and IsFiniteNumber(player.agon_lobby_position.z) then
        return CopyValue(player.agon_lobby_position)
    end
    if player.Transform ~= nil
        and type(player.Transform.GetWorldPosition) == "function" then
        local ok, x, y, z = ProtectedCall(
            player.Transform.GetWorldPosition,
            player.Transform
        )
        if ok and IsFiniteNumber(x) and IsFiniteNumber(z) then
            return { x = x, y = y or 0, z = z }
        end
    end
    return nil
end

local function SetWorldPosition(player, position)
    if type(player) ~= "table" or type(position) ~= "table" then
        return false
    end
    if player.Transform ~= nil
        and type(player.Transform.SetPosition) == "function" then
        local ok = ProtectedCall(
            player.Transform.SetPosition,
            player.Transform,
            position.x,
            position.y or 0,
            position.z
        )
        if not ok then
            return false
        end
    end
    player.agon_lobby_position = CopyValue(position)
    return true
end

local function GetTileAtWorld(self, position)
    if self.map == nil
        or type(self.map.GetTileCoordsAtPoint) ~= "function"
        or not IsFiniteNumber(position.x)
        or not IsFiniteNumber(position.z) then
        return nil
    end
    local ok, tile_x, tile_z = ProtectedCall(
        self.map.GetTileCoordsAtPoint,
        self.map,
        position.x,
        position.y or 0,
        position.z
    )
    if ok and IsInteger(tile_x) and IsInteger(tile_z) then
        return { x = tile_x, z = tile_z }
    end
    return nil
end

local function IsWalkable(self, tile)
    if self.synthetic or self.map == nil
        or type(self.map.GetTileAtPoint) ~= "function" then
        return true
    end
    local world_position = ResolveTileWorld(self, tile)
    if world_position == nil then
        return false
    end
    local ok, tile_id = ProtectedCall(
        self.map.GetTileAtPoint,
        self.map,
        world_position.x,
        world_position.y,
        world_position.z
    )
    if not ok then
        return false
    end
    return WORLD_TILES == nil
        or WORLD_TILES.IMPASSABLE == nil
        or tile_id ~= WORLD_TILES.IMPASSABLE
end

local function ResolveSpawnPoint(self, relative_point, index)
    local lobby = self.layout ~= nil and self.layout.lobby or nil
    if lobby == nil or not IsPoint(relative_point)
        or not IsPoint(lobby.center) then
        return nil
    end
    local tile =
    {
        x = lobby.center.x + relative_point.x,
        z = lobby.center.z + relative_point.z,
    }
    if not IsInsideBounds(tile, lobby.safe_bounds) or not IsWalkable(self, tile) then
        return nil
    end
    local world_position = ResolveTileWorld(self, tile)
    if world_position == nil then
        return nil
    end
    return
    {
        index = index,
        relative = CopyValue(relative_point),
        tile = tile,
        world = world_position,
    }
end

local function IsCurrentPositionInLobby(self, position)
    local lobby = self.layout ~= nil and self.layout.lobby or nil
    if lobby == nil or type(position) ~= "table" then
        return false
    end
    local tile = GetTileAtWorld(self, position)
    if tile ~= nil then
        return IsInsideBounds(tile, lobby.safe_bounds)
    end
    if type(lobby.center_world) ~= "table" then
        return false
    end
    local min_world = ResolveTileWorld(self, lobby.safe_bounds.min)
    local max_world = ResolveTileWorld(self, lobby.safe_bounds.max)
    return min_world ~= nil and max_world ~= nil
        and position.x >= math.min(min_world.x, max_world.x) - 1
        and position.x <= math.max(min_world.x, max_world.x) + 1
        and position.z >= math.min(min_world.z, max_world.z) - 1
        and position.z <= math.max(min_world.z, max_world.z) + 1
end

local function AttachMethods(service)
    service.GetSpawnPoints = LobbyService.GetSpawnPoints
    service.GetSafePoint = LobbyService.GetSafePoint
    service.GetSession = LobbyService.GetSession
    service.Enter = LobbyService.Enter
    service.MarkSpectatorReturn = LobbyService.MarkSpectatorReturn
    service.Return = LobbyService.Return
    service.OnPlayerRemoved = LobbyService.OnPlayerRemoved
    service.GetSnapshot = LobbyService.GetSnapshot
    service.Validate = LobbyService.Validate
    service.Close = LobbyService.Close
    service.GetDebugString = LobbyService.GetDebugString
    return service
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

-- WP8：运行时大厅只管理玩家位置和返回会话；不把大厅玩家登记为 Participant。
function LobbyService.New(options)
    options = type(options) == "table" and options or {}
    local layout = options.layout
    if type(layout) ~= "table"
        or type(layout.map_size) ~= "table"
        or type(layout.lobby) ~= "table"
        or not IsPoint(layout.lobby.center)
        or type(layout.lobby.safe_bounds) ~= "table" then
        return nil, LobbyService.ERROR_CODES.INVALID_LAYOUT
    end
    if type(options.spawn_points) ~= "table" or #options.spawn_points == 0 then
        return nil, LobbyService.ERROR_CODES.INVALID_LAYOUT
    end
    local service =
    {
        schema_version = LobbyService.SCHEMA_VERSION,
        service_id = LobbyService.SERVICE_ID,
        service_version = LobbyService.SERVICE_VERSION,
        world = options.world,
        map = options.map,
        layout = layout,
        spawn_points = CopyValue(options.spawn_points),
        synthetic = options.synthetic == true,
        now_fn = options.now_fn,
        sessions_by_userid = {},
        players_by_userid = {},
        occupied_points = {},
        next_point_index = 1,
        closed = false,
    }
    return AttachMethods(service)
end

function LobbyService.GetSpawnPoints(self)
    local points = {}
    for index = 1, #self.spawn_points do
        local point = ResolveSpawnPoint(self, self.spawn_points[index], index)
        if point ~= nil then
            table.insert(points, point)
        end
    end
    return points
end

function LobbyService.GetSafePoint(self, preferred_index)
    local points = self:GetSpawnPoints()
    if #points == 0 then
        return nil, LobbyService.ERROR_CODES.NO_FREE_POINT
    end

    local start_index = IsInteger(preferred_index) and preferred_index or self.next_point_index
    if start_index < 1 or start_index > #points then
        start_index = 1
    end
    for offset = 0, #points - 1 do
        local point_index = ((start_index + offset - 1) % #points) + 1
        local point = points[point_index]
        local key = PointKey(point.tile)
        if not self.occupied_points[key] then
            self.next_point_index = (point_index % #points) + 1
            return CopyValue(point)
        end
    end
    return nil, LobbyService.ERROR_CODES.NO_FREE_POINT
end

function LobbyService.GetSession(self, userid)
    if not IsNonEmptyString(userid) then
        return nil
    end
    return self.sessions_by_userid[userid]
end

function LobbyService.Enter(self, player, options)
    options = type(options) == "table" and options or {}
    local userid = GetUserid(player)
    if self.closed then
        return nil, LobbyService.ERROR_CODES.INVALID_SERVICE
    end
    if userid == nil then
        return nil, LobbyService.ERROR_CODES.INVALID_PLAYER
    end
    local existing = self.sessions_by_userid[userid]
    if existing ~= nil then
        return existing, "ALREADY_IN_LOBBY"
    end

    local selected = nil
    local current_position = options.return_position or GetWorldPosition(player)
    local current_tile = current_position ~= nil
        and GetTileAtWorld(self, current_position)
        or nil
    if current_position ~= nil
        and IsCurrentPositionInLobby(self, current_position)
        and current_tile ~= nil then
        local points = self:GetSpawnPoints()
        for index = 1, #points do
            local point = points[index]
            local point_key = PointKey(point.tile)
            if PointKey(current_tile) == point_key
                and self.occupied_points[point_key] == nil then
                selected = CopyValue(point)
                selected.world = CopyValue(current_position)
                break
            end
        end
    end
    if selected == nil then
        selected = self:GetSafePoint(options.point_index)
    end
    if selected == nil then
        return nil, LobbyService.ERROR_CODES.NO_FREE_POINT
    end

    local return_position = CopyValue(selected.world)
    local session =
    {
        schema_version = LobbyService.SCHEMA_VERSION,
        userid = userid,
        state = LobbyService.STATES.LOBBY,
        point_index = selected.index,
        tile = CopyValue(selected.tile),
        return_position = return_position,
        entered_at = GetNow(self),
    }
    self.sessions_by_userid[userid] = session
    self.players_by_userid[userid] = player
    if selected.tile ~= nil then
        self.occupied_points[PointKey(selected.tile)] = userid
    end
    if options.move ~= false and not SetWorldPosition(player, selected.world) then
        self.sessions_by_userid[userid] = nil
        self.players_by_userid[userid] = nil
        if selected.tile ~= nil then
            self.occupied_points[PointKey(selected.tile)] = nil
        end
        return nil, LobbyService.ERROR_CODES.INVALID_PLAYER
    end
    player.agon_lobby_state = LobbyService.STATES.LOBBY
    player.agon_lobby_session_id = userid
    return session
end

function LobbyService.MarkSpectatorReturn(self, player_or_userid)
    local userid = GetUserid(player_or_userid) or player_or_userid
    local session = self:GetSession(userid)
    if session == nil then
        return false, LobbyService.ERROR_CODES.SESSION_NOT_FOUND
    end
    session.state = LobbyService.STATES.SPECTATOR_RETURN
    local player = self.players_by_userid[userid]
    if player ~= nil then
        player.agon_lobby_state = LobbyService.STATES.SPECTATOR_RETURN
    end
    return true
end

function LobbyService.Return(self, player_or_userid, position, reason)
    local userid = GetUserid(player_or_userid) or player_or_userid
    local session = self:GetSession(userid)
    if session == nil then
        return false, LobbyService.ERROR_CODES.SESSION_NOT_FOUND
    end
    local player = type(player_or_userid) == "table"
        and player_or_userid
        or self.players_by_userid[userid]
    local target_position = position or session.return_position
    if target_position == nil then
        local point, point_code = self:GetSafePoint()
        if point == nil then
            return false, point_code
        end
        target_position = point.world
        session.tile = CopyValue(point.tile)
        session.point_index = point.index
    end
    if player ~= nil and not SetWorldPosition(player, target_position) then
        return false, LobbyService.ERROR_CODES.INVALID_PLAYER
    end
    session.state = LobbyService.STATES.LOBBY
    session.return_position = CopyValue(target_position)
    session.return_reason = reason ~= nil and tostring(reason) or nil
    if player ~= nil then
        self.players_by_userid[userid] = player
        player.agon_lobby_state = LobbyService.STATES.LOBBY
        player.agon_lobby_session_id = userid
    end
    return true
end

function LobbyService.OnPlayerRemoved(self, player_or_userid)
    local userid = GetUserid(player_or_userid) or player_or_userid
    if not IsNonEmptyString(userid) then
        return false
    end
    local session = self.sessions_by_userid[userid]
    if session ~= nil and session.tile ~= nil then
        self.occupied_points[PointKey(session.tile)] = nil
    end
    self.sessions_by_userid[userid] = nil
    self.players_by_userid[userid] = nil
    if type(player_or_userid) == "table" then
        player_or_userid.agon_lobby_state = nil
        player_or_userid.agon_lobby_session_id = nil
    end
    return true
end

function LobbyService.GetSnapshot(self)
    local sessions = {}
    for userid, session in pairs(self.sessions_by_userid) do
        sessions[userid] = CopyValue(session)
    end
    return
    {
        schema_version = self.schema_version,
        service_id = self.service_id,
        service_version = self.service_version,
        closed = self.closed,
        sessions = sessions,
    }
end

function LobbyService.Validate(self)
    if type(self.layout) ~= "table"
        or type(self.layout.lobby) ~= "table"
        or type(self.sessions_by_userid) ~= "table" then
        return false, LobbyService.ERROR_CODES.INVALID_SERVICE
    end
    local points = self:GetSpawnPoints()
    if #points == 0 then
        return false, LobbyService.ERROR_CODES.NO_FREE_POINT
    end
    local seen = {}
    for userid, session in pairs(self.sessions_by_userid) do
        if not IsNonEmptyString(userid)
            or type(session) ~= "table"
            or session.userid ~= userid
            or (session.state ~= LobbyService.STATES.LOBBY
                and session.state ~= LobbyService.STATES.SPECTATOR_RETURN)
            or type(session.return_position) ~= "table"
            or not IsFiniteNumber(session.return_position.x)
            or not IsFiniteNumber(session.return_position.z) then
            return false, LobbyService.ERROR_CODES.INVALID_SERVICE
        end
        if session.tile ~= nil then
            local key = PointKey(session.tile)
            if seen[key] then
                return false, LobbyService.ERROR_CODES.INVALID_SERVICE
            end
            seen[key] = true
        end
    end
    return true
end

function LobbyService.Close(self, reason)
    if self.closed then
        return true, "ALREADY_CLOSED"
    end
    for userid, player in pairs(self.players_by_userid) do
        if player ~= nil then
            player.agon_lobby_state = nil
            player.agon_lobby_session_id = nil
        end
        self.players_by_userid[userid] = nil
    end
    self.sessions_by_userid = {}
    self.occupied_points = {}
    self.closed = true
    return true
end

function LobbyService.GetDebugString(self)
    local count = 0
    for _ in pairs(self.sessions_by_userid) do
        count = count + 1
    end
    return string.format(
        "lobby service=%s version=%d sessions=%d closed=%s",
        self.service_id,
        self.service_version,
        count,
        tostring(self.closed)
    )
end

return LobbyService
