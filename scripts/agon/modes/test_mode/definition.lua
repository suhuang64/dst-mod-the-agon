-- WP3：使用 SMALL Zone 并接入场景计划的 TestMode 定义。

local TestModeRuntime = require("agon/modes/test_mode/runtime")
local TestModeProfiles = require("agon/modes/test_mode/profiles")

local TestModeDefinition =
{
    mode_id = "TEST_MODE",
    mode_version = 1,
    zone_category = "SMALL",
    services =
    {
        "phase",
        "clock",
        "decision",
        "effects",
        "score",
        "entity_profiles",
        "player_sandbox",
    },
    profiles = TestModeProfiles.PROFILE_IDS,
    RegisterProfiles = TestModeProfiles.Register,
}

function TestModeDefinition.CreateRuntime(instance, services)
    return TestModeRuntime.New(instance, services)
end

return TestModeDefinition
