-- WP10：Spectator 客户端只保留镜头，不显示或操作物品/制作界面。

local SpectatorHud = {}

local function IsLocalSpectator(player)
    if player == nil or player ~= ThePlayer then
        return false
    end
    local classified = player.agon_player_classified
    if classified == nil or classified.agon_spectator_active == nil
        or type(classified.agon_spectator_active.value) ~= "function" then
        return false
    end
    local ok, active = pcall(
        classified.agon_spectator_active.value,
        classified.agon_spectator_active
    )
    return ok and active == true
end

local function IsLocalFairPlayer(player)
    if player == nil or player ~= ThePlayer then
        return false
    end
    local classified = player.agon_player_classified
    if classified == nil or classified.agon_fair_mode == nil
        or type(classified.agon_fair_mode.value) ~= "function" then
        return false
    end
    local ok, active = pcall(
        classified.agon_fair_mode.value,
        classified.agon_fair_mode
    )
    return ok and active == true
end

local function ProtectedCall(callback, ...)
    if type(callback) ~= "function" then
        return false
    end
    return pcall(callback, ...)
end

local function KillWidget(widget)
    if widget ~= nil and type(widget.Kill) == "function" then
        ProtectedCall(widget.Kill, widget)
    end
end

local function HideSpectatorInventory(self)
    local controls = self ~= nil and self.controls or nil
    if controls == nil then
        return
    end

    -- 官方方法负责关闭 controller focus、容器 widget 和 dark overlay；即使
    -- craftingandinventoryshown 已经是 false，也继续执行下面的强制隐藏。
    if type(controls.HideCraftingAndInventory) == "function" then
        ProtectedCall(controls.HideCraftingAndInventory, controls)
    end
    controls.craftingandinventoryshown = false
    controls.craftingshown = false

    local inventory_widget = controls.inv
    if inventory_widget ~= nil then
        if type(inventory_widget.CloseControllerInventory) == "function" then
            ProtectedCall(
                inventory_widget.CloseControllerInventory,
                inventory_widget
            )
        end
        KillWidget(inventory_widget.hovertile)
        KillWidget(inventory_widget.cursortile)
        inventory_widget.hovertile = nil
        inventory_widget.cursortile = nil
        if type(inventory_widget.Hide) == "function" then
            ProtectedCall(inventory_widget.Hide, inventory_widget)
        end
        if type(inventory_widget.Disable) == "function" then
            ProtectedCall(inventory_widget.Disable, inventory_widget)
        end
    end

    local crafting = controls.craftingmenu
    if crafting ~= nil then
        if type(crafting.Close) == "function" then
            ProtectedCall(crafting.Close, crafting)
        end
        if type(crafting.Hide) == "function" then
            ProtectedCall(crafting.Hide, crafting)
        end
        if type(crafting.Disable) == "function" then
            ProtectedCall(crafting.Disable, crafting)
        end
    end

    local hide_widgets =
    {
        controls.containerroot_under,
        controls.containerroot,
        controls.containerroot_over,
        controls.containerroot_side,
        controls.containerroot_side_behind,
        controls.secondary_status ~= nil
            and controls.secondary_status.side_inv or nil,
    }
    for index = 1, #hide_widgets do
        local widget = hide_widgets[index]
        if widget ~= nil and type(widget.Hide) == "function" then
            ProtectedCall(widget.Hide, widget)
        end
    end
    for _, widget in pairs(controls.containers or {}) do
        if widget ~= nil and type(widget.Hide) == "function" then
            ProtectedCall(widget.Hide, widget)
        end
    end
end

local function RestoreInventoryBar(self)
    local controls = self ~= nil and self.controls or nil
    if controls == nil then
        return
    end
    -- HideSpectatorInventory 把 craftingshown 和 craftingmenu 一起禁用；
    -- 只调用 ShowCraftingAndInventory 不会恢复 craftingshown=false 的分支，
    -- 因而建造栏会保持隐藏。先恢复官方显示标志，再显式启用制作 widget。
    controls.craftingshown = true
    if type(controls.ShowCrafting) == "function" then
        ProtectedCall(controls.ShowCrafting, controls)
    end
    if type(controls.ShowCraftingAndInventory) == "function" then
        ProtectedCall(controls.ShowCraftingAndInventory, controls)
    end
    if controls.inv ~= nil then
        if type(controls.inv.Enable) == "function" then
            ProtectedCall(controls.inv.Enable, controls.inv)
        end
        if type(controls.inv.Show) == "function" then
            ProtectedCall(controls.inv.Show, controls.inv)
        end
    end
    local crafting = controls.craftingmenu
    if crafting ~= nil then
        if type(crafting.Enable) == "function" then
            ProtectedCall(crafting.Enable, crafting)
        end
        if type(crafting.Show) == "function" then
            ProtectedCall(crafting.Show, crafting)
        end
    end
end

local FAIR_ROLE_STATUS_FIELDS =
{
    "inspirationbadge",
    "mightybadge",
    "wereness",
    "avengingghostbadge",
    "pethealthbadge",
    "pethungerbadge",
}

local function HideFairRoleStatus(self)
    local controls = self ~= nil and self.controls or nil
    local status = controls ~= nil and controls.status or nil
    if status == nil then
        return
    end
    self._agon_fair_role_status_visibility = self._agon_fair_role_status_visibility or {}
    for index = 1, #FAIR_ROLE_STATUS_FIELDS do
        local field = FAIR_ROLE_STATUS_FIELDS[index]
        local widget = status[field]
        if widget ~= nil then
            if self._agon_fair_role_status_visibility[field] == nil then
                local ok, visible = ProtectedCall(widget.IsVisible, widget)
                self._agon_fair_role_status_visibility[field] = ok and visible == true
            end
            if type(widget.Hide) == "function" then
                ProtectedCall(widget.Hide, widget)
            end
        end
    end
end

local function RestoreFairRoleStatus(self)
    local controls = self ~= nil and self.controls or nil
    local status = controls ~= nil and controls.status or nil
    local saved = self ~= nil and self._agon_fair_role_status_visibility or nil
    if status == nil or saved == nil then
        return
    end
    local ghost = status.isghostmode == true
    for index = 1, #FAIR_ROLE_STATUS_FIELDS do
        local field = FAIR_ROLE_STATUS_FIELDS[index]
        local widget = status[field]
        if widget ~= nil then
            if saved[field] == true and not ghost then
                if type(widget.Show) == "function" then
                    ProtectedCall(widget.Show, widget)
                end
            elseif type(widget.Hide) == "function" then
                ProtectedCall(widget.Hide, widget)
            end
        end
    end
    self._agon_fair_role_status_visibility = nil
end

local function IsBlockedControl(control)
    local function InRange(first, last)
        return type(control) == "number"
            and type(first) == "number"
            and type(last) == "number"
            and control >= first
            and control <= last
    end
    return control == CONTROL_OPEN_CRAFTING
        or control == CONTROL_OPEN_INVENTORY
        or control == CONTROL_CRAFTING_PINLEFT
        or control == CONTROL_CRAFTING_PINRIGHT
        or InRange(CONTROL_INV_1, CONTROL_INV_10)
        or InRange(CONTROL_INV_11, CONTROL_INV_15)
end

function SpectatorHud.Install(hud)
    if hud == nil or hud._agon_spectator_hud_installed == true then
        return
    end

    if type(hud.OnUpdate) == "function" then
        local original_update = hud.OnUpdate
        hud.OnUpdate = function(self, ...)
            local active = IsLocalSpectator(self.owner)
            local fair = IsLocalFairPlayer(self.owner)
            if active then
                HideSpectatorInventory(self)
            end
            if fair then
                HideFairRoleStatus(self)
            end
            local result = original_update(self, ...)
            if active then
                HideSpectatorInventory(self)
            elseif self._agon_spectator_hud_was_active then
                RestoreInventoryBar(self)
            end
            if fair then
                HideFairRoleStatus(self)
            elseif self._agon_fair_hud_was_active then
                RestoreFairRoleStatus(self)
            end
            self._agon_spectator_hud_was_active = active
            self._agon_fair_hud_was_active = fair
            return result
        end
    end

    if type(hud.OpenControllerInventory) == "function" then
        local original_open_inventory = hud.OpenControllerInventory
        hud.OpenControllerInventory = function(self, ...)
            if IsLocalSpectator(self.owner) then
                HideSpectatorInventory(self)
                return true
            end
            return original_open_inventory(self, ...)
        end
    end

    if type(hud.OpenCrafting) == "function" then
        local original_open_crafting = hud.OpenCrafting
        hud.OpenCrafting = function(self, ...)
            if IsLocalSpectator(self.owner) then
                HideSpectatorInventory(self)
                return true
            end
            return original_open_crafting(self, ...)
        end
    end

    if type(hud.OpenContainer) == "function" then
        local original_open_container = hud.OpenContainer
        hud.OpenContainer = function(self, ...)
            if IsLocalSpectator(self.owner) then
                HideSpectatorInventory(self)
                return true
            end
            return original_open_container(self, ...)
        end
    end

    if type(hud.OpenSpellWheel) == "function" then
        local original_open_spell_wheel = hud.OpenSpellWheel
        hud.OpenSpellWheel = function(self, ...)
            if IsLocalSpectator(self.owner) then
                HideSpectatorInventory(self)
                return true
            end
            return original_open_spell_wheel(self, ...)
        end
    end

    if type(hud.OnControl) == "function" then
        local original_control = hud.OnControl
        hud.OnControl = function(self, control, down, ...)
            if IsLocalSpectator(self.owner) and IsBlockedControl(control) then
                HideSpectatorInventory(self)
                return true
            end
            return original_control(self, control, down, ...)
        end
    end

    hud._agon_spectator_hud_installed = true
end

return SpectatorHud
