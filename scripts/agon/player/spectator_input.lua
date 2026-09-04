-- WP10：观战客户端只接管镜头输入，不重新开放玩家移动或交互。

local SpectatorInput = {}

local ROT_REPEAT = 0.25
local ZOOM_REPEAT = 0.1

local function GetTimeNow()
    if type(GetStaticTime) == "function" then
        return GetStaticTime()
    end
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

local function GetInvertRotation()
    if Profile ~= nil and type(Profile.GetInvertCameraRotation) == "function" then
        return Profile:GetInvertCameraRotation()
    end
    return false
end

local function RemapValue(value, input_min, input_max, output_min, output_max)
    if type(Remap) == "function" then
        return Remap(
            value,
            input_min,
            input_max,
            output_min,
            output_max
        )
    end
    if input_max == input_min then
        return output_min
    end
    return output_min
        + (value - input_min) * (output_max - output_min)
            / (input_max - input_min)
end

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

local function DoSpectatorCameraControl(self)
    if TheCamera == nil or type(TheCamera.CanControl) ~= "function"
        or not TheCamera:CanControl() then
        return
    end
    if TheInput == nil then
        return
    end

    local can_zoom = true
    local time = GetTimeNow()
    local invert_rotation = GetInvertRotation()
    local supports_controller = type(TheInput.SupportsControllerFreeCamera) == "function"
        and TheInput:SupportsControllerFreeCamera()

    if supports_controller then
        local xdir = TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_CAMERA_ROTATE_RIGHT)
            - TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_CAMERA_ROTATE_LEFT)
        local ydir = TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_CAMERA_ZOOM_IN)
            - TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_CAMERA_ZOOM_OUT)
        local absxdir = math.abs(xdir)
        local absydir = math.abs(ydir)
        local deadzone = TUNING.CONTROLLER_DEADZONE_RADIUS
        if absxdir >= deadzone and absxdir > absydir * 1.3 then
            local right = xdir > 0
            if invert_rotation then
                right = not right
            end
            local speed = RemapValue(
                math.min(1, absxdir),
                deadzone,
                1,
                2,
                3
            )
            if right then
                self:RotRight(speed)
            else
                self:RotLeft(speed)
            end
            self.lastrottime = time
        elseif can_zoom and absydir > deadzone then
            local delta = RemapValue(
                math.min(1, absydir),
                deadzone,
                1,
                0,
                0.65
            )
            TheCamera:ContinuousZoomDelta(ydir > 0 and -delta or delta)
            self.lastzoomtime = time
        end
        return
    end

    if self.lastrottime == nil or time - self.lastrottime > ROT_REPEAT then
        if TheInput:IsControlPressed(
            invert_rotation and CONTROL_ROTATE_RIGHT or CONTROL_ROTATE_LEFT
        ) then
            self:RotLeft()
            self.lastrottime = time
        elseif TheInput:IsControlPressed(
            invert_rotation and CONTROL_ROTATE_LEFT or CONTROL_ROTATE_RIGHT
        ) then
            self:RotRight()
            self.lastrottime = time
        end
    end

    if can_zoom and (self.lastzoomtime == nil
        or time - self.lastzoomtime > ZOOM_REPEAT) then
        if TheInput:IsControlPressed(CONTROL_ZOOM_IN) then
            if not self.zoomin_same_as_scrollup
                or (self.inst.HUD ~= nil
                    and self.inst.HUD.controls ~= nil
                    and not self.inst.HUD.controls.craftingmenu.focus) then
                TheCamera:ZoomIn()
                self.lastzoomtime = time
            end
        elseif TheInput:IsControlPressed(CONTROL_ZOOM_OUT) then
            if not self.zoomout_same_as_scrolldown
                or (self.inst.HUD ~= nil
                    and self.inst.HUD.controls ~= nil
                    and not self.inst.HUD.controls.craftingmenu.focus) then
                TheCamera:ZoomOut()
                self.lastzoomtime = time
            end
        end
    end
end

function SpectatorInput.Install(controller)
    if controller == nil or controller._agon_spectator_input_installed == true
        or type(controller.DoCameraControl) ~= "function" then
        return
    end
    local original = controller.DoCameraControl
    controller.DoCameraControl = function(self, ...)
        if self.ismastersim ~= true and IsLocalSpectator(self.inst) then
            DoSpectatorCameraControl(self)
            return
        end
        return original(self, ...)
    end
    controller._agon_spectator_input_installed = true
end

return SpectatorInput
