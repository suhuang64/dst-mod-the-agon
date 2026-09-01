-- WP2：不生成地形和实体的最小 TestMode runtime。

local TestModeRuntime = {}
TestModeRuntime.SCHEMA_VERSION = 1

local function AttachMethods(runtime)
    runtime.OnPrepare = TestModeRuntime.OnPrepare
    runtime.OnStart = TestModeRuntime.OnStart
    runtime.OnFinish = TestModeRuntime.OnFinish
    runtime.OnDestroy = TestModeRuntime.OnDestroy
    runtime.OnSave = TestModeRuntime.OnSave
    return runtime
end

function TestModeRuntime.New(instance, services)
    if type(instance) ~= "table"
        or type(instance.instance_id) ~= "string"
        or instance.instance_id == "" then
        return nil, "INVALID_INSTANCE"
    end

    return AttachMethods(
    {
        schema_version = TestModeRuntime.SCHEMA_VERSION,
        mode_id = "TEST_MODE",
        mode_version = 1,
        instance_id = instance.instance_id,
        services = services or {},
        state = "CREATED",
    })
end

function TestModeRuntime.OnPrepare(self)
    if self.state == "PREPARING" or self.state == "READY" then
        return true
    end
    if self.state ~= "CREATED" then
        return false, "TEST_MODE_INVALID_PREPARE_STATE"
    end
    self.state = "READY"
    return true
end

function TestModeRuntime.OnStart(self)
    if self.state == "RUNNING" then
        return true
    end
    if self.state ~= "READY" then
        return false, "TEST_MODE_NOT_PREPARED"
    end
    self.state = "RUNNING"
    return true
end

function TestModeRuntime.OnFinish(self)
    if self.state == "FINISHED" then
        return true
    end
    if self.state ~= "READY" and self.state ~= "RUNNING" then
        return false, "TEST_MODE_INVALID_FINISH_STATE"
    end
    self.state = "FINISHED"
    return true
end

function TestModeRuntime.OnDestroy(self)
    if self.state == "DESTROYED" then
        return true
    end
    self.state = "DESTROYED"
    return true
end

function TestModeRuntime.OnSave(self)
    return
    {
        schema_version = self.schema_version,
        mode_id = self.mode_id,
        mode_version = self.mode_version,
        instance_id = self.instance_id,
        state = self.state,
    }
end

return TestModeRuntime
