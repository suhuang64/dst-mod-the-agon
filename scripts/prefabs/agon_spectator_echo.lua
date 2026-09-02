-- WP8：只读观战残影。该实体没有 gameplay、AI、碰撞或持久化能力。

local MAX_DISPLAY_NAME_LENGTH = 96

local function TrimString(value)
    if type(value) ~= "string" then
        return ""
    end
    if #value > MAX_DISPLAY_NAME_LENGTH then
        return string.sub(value, 1, MAX_DISPLAY_NAME_LENGTH)
    end
    return value
end

local function SetDisplayName(inst, display_name)
    local value = TrimString(display_name)
    inst.display_name = value
    if inst.agon_display_name ~= nil then
        inst.agon_display_name:set(value)
    end
    return true
end

local function SetAppearance(inst, appearance)
    if type(appearance) ~= "table" then
        return false
    end
    inst.appearance =
    {
        prefab = type(appearance.prefab) == "string" and appearance.prefab or nil,
        bank = appearance.bank,
        build = type(appearance.build) == "string" and appearance.build or nil,
    }
    if inst.AnimState ~= nil then
        if appearance.bank ~= nil and type(inst.AnimState.SetBank) == "function" then
            pcall(inst.AnimState.SetBank, inst.AnimState, appearance.bank)
        end
        if inst.appearance.build ~= nil
            and type(inst.AnimState.SetBuild) == "function" then
            pcall(inst.AnimState.SetBuild, inst.AnimState, inst.appearance.build)
        end
        if type(inst.AnimState.PlayAnimation) == "function" then
            pcall(inst.AnimState.PlayAnimation, inst.AnimState, "idle", true)
        end
    end
    return true
end

local function GetSnapshot(inst)
    return
    {
        echo_id = inst.echo_id,
        display_name = inst.display_name,
        appearance = inst.appearance,
        persists = false,
        gameplay = false,
        ai = false,
        collision = false,
    }
end

local function OnRemoveEntity(inst)
    inst.removed = true
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    -- 使用现有 Wilson 资源作为安全默认外观；服务端仍会复制只读外观字段。
    inst.AnimState:SetBank("wilson")
    inst.AnimState:SetBuild("wilson")
    inst.AnimState:PlayAnimation("idle", true)

    inst:AddTag("agon_spectator_echo")
    inst:AddTag("FX")
    inst:AddTag("NOCLICK")
    inst.agon_display_name = net_string(
        inst.GUID,
        "agon_spectator_echo.display_name",
        "agon_spectator_echo_name_dirty"
    )
    inst.entity:SetPristine()

    inst.display_name = ""
    inst.appearance = {}
    inst.removed = false
    inst.OnRemoveEntity = OnRemoveEntity

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false
    inst.SetDisplayName = SetDisplayName
    inst.SetAppearance = SetAppearance
    inst.GetSnapshot = GetSnapshot
    return inst
end

return Prefab("agon_spectator_echo", fn)
