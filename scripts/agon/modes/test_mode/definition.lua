-- WP2：使用 SMALL Zone 的空 TestMode 定义。

local TestModeRuntime = require("agon/modes/test_mode/runtime")

local TestModeDefinition =
{
    mode_id = "TEST_MODE",
    mode_version = 1,
    zone_category = "SMALL",
    services = {},
}

function TestModeDefinition.CreateRuntime(instance, services)
    return TestModeRuntime.New(instance, services)
end

return TestModeDefinition
