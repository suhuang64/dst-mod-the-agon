-- WP4：只对绑定玩家可见的 The Agon 状态 classified。

local Classified = require("agon/net/classified")

local function OnRemoveEntity(inst)
    Classified.UnbindParent(inst)
end

local function BindParent(inst)
    Classified.BindParent(inst)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddNetwork()
    inst.entity:Hide()
    inst:AddTag("CLASSIFIED")
    inst:AddTag("NOCLICK")

    Classified.Configure(inst)
    inst.entity:SetPristine()

    inst._parent = nil
    inst.OnRemoveEntity = OnRemoveEntity

    if not TheWorld.ismastersim then
        inst:DoTaskInTime(0, BindParent)
        inst.OnEntityReplicated = BindParent
        return inst
    end

    inst.persists = false
    inst.AttachToPlayer = Classified.AttachToPlayer
    inst.SetParticipant = Classified.SetParticipant
    inst.ClearParticipant = Classified.ClearParticipant
    inst.SetAudiencePayload = Classified.SetAudiencePayload
    return inst
end

return Prefab("agon_player_classified", fn)
