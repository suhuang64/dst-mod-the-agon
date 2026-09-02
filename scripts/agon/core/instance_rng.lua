-- WP4：Instance 独立、可保存且可复现的命名随机流。
--
-- 使用 Park-Miller 算法而不是 math.random，避免共享全局随机状态让 UI、
-- 场景和掉落相互消耗随机序列。所有状态均为安全整数，适用于 Lua 5.1。

local InstanceRng = {}

InstanceRng.SCHEMA_VERSION = 1
InstanceRng.MODULUS = 2147483647
InstanceRng.MULTIPLIER = 48271

InstanceRng.ERROR_CODES =
{
    INVALID_SEED = "INVALID_RNG_SEED",
    INVALID_STREAM = "INVALID_RNG_STREAM",
    INVALID_RANGE = "INVALID_RNG_RANGE",
    INVALID_SNAPSHOT = "INVALID_RNG_SNAPSHOT",
}

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function IsPositiveInteger(value)
    return IsFiniteNumber(value) and value == math.floor(value) and value >= 1
end

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function HashString(value)
    local hash = 17
    for index = 1, #value do
        hash = (hash * 131 + string.byte(value, index)) % InstanceRng.MODULUS
    end
    return hash
end

local function NormalizeSeed(seed)
    local numeric_seed
    if IsFiniteNumber(seed) then
        numeric_seed = math.floor(seed)
    elseif type(seed) == "string" and seed ~= "" then
        numeric_seed = HashString(seed)
    else
        return nil
    end

    numeric_seed = numeric_seed % (InstanceRng.MODULUS - 1)
    return numeric_seed + 1
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

local function DeriveStreamSeed(seed, name)
    local hash = HashString(tostring(seed) .. ":" .. name)
    return (hash + seed) % (InstanceRng.MODULUS - 1) + 1
end

local function AttachStreamMethods(rng, stream)
    stream.Next = function()
        return rng:Next(stream.name)
    end
    stream.Random = stream.Next
    stream.RandomInt = function(_, minimum, maximum)
        return rng:RandomInt(stream.name, minimum, maximum)
    end
    stream.Choice = function(_, values)
        return rng:Choice(stream.name, values)
    end
    return stream
end

function InstanceRng.GetSeed(self)
    return self.seed
end

function InstanceRng.GetStream(self, name)
    if not IsNonEmptyString(name) then
        return nil, InstanceRng.ERROR_CODES.INVALID_STREAM
    end
    local stream = self.streams[name]
    if stream == nil then
        stream =
        {
            name = name,
            seed = DeriveStreamSeed(self.seed, name),
            state = DeriveStreamSeed(self.seed, name),
            counter = 0,
        }
        self.streams[name] = AttachStreamMethods(self, stream)
        table.insert(self.stream_order, name)
    end
    return stream
end

function InstanceRng.Next(self, name)
    local stream, stream_code = self:GetStream(name or "default")
    if stream == nil then
        return nil, stream_code
    end
    stream.state = (stream.state * InstanceRng.MULTIPLIER) % InstanceRng.MODULUS
    stream.counter = stream.counter + 1
    return stream.state / InstanceRng.MODULUS
end

function InstanceRng.Random(self, name)
    return self:Next(name or "default")
end

function InstanceRng.RandomInt(self, name, minimum, maximum)
    if not IsFiniteNumber(minimum) or not IsFiniteNumber(maximum)
        or minimum ~= math.floor(minimum)
        or maximum ~= math.floor(maximum)
        or minimum > maximum then
        return nil, InstanceRng.ERROR_CODES.INVALID_RANGE
    end
    local value, value_code = self:Next(name or "default")
    if value == nil then
        return nil, value_code
    end
    return minimum + math.floor(value * (maximum - minimum + 1))
end

function InstanceRng.Choice(self, name, values)
    if type(values) ~= "table" or #values < 1 then
        return nil, InstanceRng.ERROR_CODES.INVALID_RANGE
    end
    local index, index_code = self:RandomInt(name or "default", 1, #values)
    if index == nil then
        return nil, index_code
    end
    return values[index], index
end

function InstanceRng.GetStreamCounter(self, name)
    local stream = self.streams[name]
    return stream ~= nil and stream.counter or 0
end

function InstanceRng.GetSnapshot(self)
    local streams = {}
    for index = 1, #self.stream_order do
        local name = self.stream_order[index]
        local stream = self.streams[name]
        if stream ~= nil then
            table.insert(streams,
            {
                name = stream.name,
                seed = stream.seed,
                state = stream.state,
                counter = stream.counter,
            })
        end
    end
    return
    {
        schema_version = InstanceRng.SCHEMA_VERSION,
        seed = self.seed,
        streams = streams,
    }
end

function InstanceRng.OnLoad(self, snapshot)
    if type(snapshot) ~= "table"
        or snapshot.schema_version ~= InstanceRng.SCHEMA_VERSION
        or not IsPositiveInteger(snapshot.seed)
        or type(snapshot.streams) ~= "table" then
        return false, InstanceRng.ERROR_CODES.INVALID_SNAPSHOT
    end

    if snapshot.seed > InstanceRng.MODULUS then
        return false, InstanceRng.ERROR_CODES.INVALID_SNAPSHOT
    end

    self.seed = snapshot.seed
    self.streams = {}
    self.stream_order = {}
    for index = 1, #snapshot.streams do
        local saved = snapshot.streams[index]
        if type(saved) ~= "table"
            or not IsNonEmptyString(saved.name)
            or not IsPositiveInteger(saved.seed)
            or not IsPositiveInteger(saved.state)
            or not IsFiniteNumber(saved.counter)
            or saved.counter < 0
            or saved.counter ~= math.floor(saved.counter)
            or self.streams[saved.name] ~= nil then
            return false, InstanceRng.ERROR_CODES.INVALID_SNAPSHOT
        end
        if saved.seed > InstanceRng.MODULUS or saved.state > InstanceRng.MODULUS then
            return false, InstanceRng.ERROR_CODES.INVALID_SNAPSHOT
        end
        local stream =
        {
            name = saved.name,
            seed = saved.seed,
            state = saved.state,
            counter = saved.counter,
        }
        self.streams[saved.name] = AttachStreamMethods(self, stream)
        table.insert(self.stream_order, saved.name)
    end
    return true
end

local function AttachMethods(rng)
    rng.GetSeed = InstanceRng.GetSeed
    rng.GetStream = InstanceRng.GetStream
    rng.Next = InstanceRng.Next
    rng.Random = InstanceRng.Random
    rng.RandomInt = InstanceRng.RandomInt
    rng.Choice = InstanceRng.Choice
    rng.GetStreamCounter = InstanceRng.GetStreamCounter
    rng.GetSnapshot = InstanceRng.GetSnapshot
    rng.OnLoad = InstanceRng.OnLoad
    return rng
end

function InstanceRng.New(seed)
    local normalized_seed = NormalizeSeed(seed)
    if normalized_seed == nil then
        return nil, InstanceRng.ERROR_CODES.INVALID_SEED
    end
    return AttachMethods(
    {
        schema_version = InstanceRng.SCHEMA_VERSION,
        seed = normalized_seed,
        streams = {},
        stream_order = {},
    })
end

function InstanceRng.FromSnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return nil, InstanceRng.ERROR_CODES.INVALID_SNAPSHOT
    end
    local rng, rng_code = InstanceRng.New(snapshot.seed)
    if rng == nil then
        return nil, rng_code
    end
    local loaded, load_code = rng:OnLoad(snapshot)
    if not loaded then
        return nil, load_code
    end
    return rng
end

return InstanceRng
