--[[
    Author: flightwusel
    See notes on https://github.com/jonaseberle/xplane-plugin-SlewMode

    Kudos to teleport.lua by shryft for all things placement and rotation
    Thanks to apn, philipp and KarlL in https://forums.x-plane.org/index.php?/forums/topic/267531-how-to-probe-a-mesh-slope-with-xplmprobeterrainxyz/ for how to rotate the plane to align with terrain
]]

-- adapt these settings to your needs:
local settings = {
    modifierKeyCode = 32, -- 32 is space
    move = {
        forward = {
            axis = 1, -- X-Plane joystick mapped axis number
            onlyWhenModifier = false, -- this function is active when the modifier key is in this state
            max_mPerS = 2000, -- maximum velocity m/s
            inputAccel = 1000, -- the higher this value the finer the control around the center
        },
        sideways = {
            axis = 2,
            onlyWhenModifier = false,
            max_mPerS = 2000,
            inputAccel = 400,
        },
    },
    rotate = {
        pitch = {
            axis = 1,
            onlyWhenModifier = true,
            max_radPerS = math.rad(300), -- maximum angular velocity rad/s
            inputAccel = 400,
        },
        roll = {
            axis = 2,
            onlyWhenModifier = true,
            max_radPerS = math.rad(300),
            inputAccel = 400,
        },
        yaw = {
            axis = 3,
            max_radPerS = math.rad(300),
            inputAccel = 400,
        },
    },
    followGroundSmoothing = { -- when on the ground, plane pitch/roll changes are smoothed
        pitch = .2, -- x seconds attack
        roll = .2
    }
}

--[[ runtime variables ]]

local isFollowGround = false
local dAltitude_mPerS = 0.
local aircraftGearPitch_deg = 0.
local aircraftGearAgl_m = 0.
local isModifierKeyPressed = false
local dForwardFreeze_mPerS = 0.
local dSidewaysFreeze_mPerS = 0.
local doFreeze = false

local x_dataref = XPLMFindDataRef("sim/flightmodel/position/local_x")
local y_dataref = XPLMFindDataRef("sim/flightmodel/position/local_y")
local z_dataref = XPLMFindDataRef("sim/flightmodel/position/local_z")
local vx_dataref = XPLMFindDataRef("sim/flightmodel/position/local_vx")
local vy_dataref = XPLMFindDataRef("sim/flightmodel/position/local_vy")
local vz_dataref = XPLMFindDataRef("sim/flightmodel/position/local_vz")
local pitch_dataref = XPLMFindDataRef("sim/flightmodel/position/theta")
local roll_dataref = XPLMFindDataRef("sim/flightmodel/position/phi")
local hdg_dataref = XPLMFindDataRef("sim/flightmodel/position/psi")
local q_dataref = XPLMFindDataRef("sim/flightmodel/position/q")
local groundNormal_dataref = XPLMFindDataRef("sim/flightmodel/ground/plugin_ground_slope_normal")
local agl_dataref = XPLMFindDataRef("sim/flightmodel/position/y_agl")
local period_s_dataref = XPLMFindDataRef("sim/operation/misc/frame_rate_period")
local axii_dataref = XPLMFindDataRef("sim/joystick/joy_mapped_axis_value")
local overridePlanepath_dataref = XPLMFindDataRef("sim/operation/override/override_planepath")
local gearsOnGround_dataref = XPLMFindDataRef("sim/flightmodel2/gear/on_ground")
--[[ local ]]

local function log(msg, level)
    -- @see https://stackoverflow.com/questions/9168058/how-to-dump-a-table-to-console
    local function dump(o)
        if type(o) == 'table' then
            local s = '{ '
            for k,v in pairs(o) do
                if type(k) ~= 'number' then k = '"'..k..'"' end
                s = s .. '['..k..'] = ' .. dump(v) .. ','
            end
            return s .. '} '
        else
            return tostring(o)
        end
    end

    local msg = msg or ""
    local level = level or ""
    local filePath = debug.getinfo(2, "S").source
    local fileName = filePath:match("[^/\\]*[.]lua$")
    local functionName = debug.getinfo(2, "n").name
    logMsg(
        string.format(
            "%s::%s() %s%s",
            fileName,
            functionName,
            level,
            dump(msg)
        )
    )
end

local function err(msg)
    return log(msg, "[ERROR] ")
end

local function addMacroAndCommand(cmdRef, title, eval, evalContinue, evalEnd)
    local evalContinue = evalContinue or ""
    local evalEnd = evalEnd or ""
    log(
        string.format(
            "Adding command %s and macro '%s'",
            cmdRef,
            title
        )
    )
    create_command(cmdRef, title, eval, evalContinue, evalEnd)
    add_macro(title, eval)
end

local function addToggleMacroAndCommand(cmdRef, titlePrefix, activateCallbackName, globalStateVariableName)
    local macroActivated = loadstring("return " .. globalStateVariableName)() and 'activate' or 'deactivate'
    local cmdRefToggle = cmdRef .. "Toggle"
    local cmdRefActivate = cmdRef .. "Activate"
    local cmdRefDeactivate = cmdRef .. "Deactivate"
    local macroTitle = titlePrefix .. "Activate/De-Activate (Toggle)"
    log(
        string.format(
            "Adding commands %s, %s, %s and macro '%s' (activated: %s)",
            cmdRefToggle,
            cmdRefActivate,
            cmdRefDeactivate,
            macroTitle,
            macroActivated
        )
    )

    create_command(cmdRefToggle, titlePrefix .. "Toggle", activateCallbackName .. "(not " .. globalStateVariableName .. ")", "", "")
    create_command(cmdRefActivate, titlePrefix .. "Activate", activateCallbackName .. "(true)", "", "")
    create_command(cmdRefDeactivate, titlePrefix .. "De-Activate", activateCallbackName .. "(false)", "", "")
    add_macro(macroTitle, activateCallbackName .. "(true)", activateCallbackName .. "(false)", macroActivated)
end

-- a symmetric "ease-in" function passing through (-1/-1), (0/0) and (1/1)
local function accelerate(x, accel)
    return accel * x^3 / (accel + 1) + x / (accel + 1)
end

local function eulerToQuaternion(hdg_rad, pitch_rad, roll_rad)
    return {
        [0] = math.cos(hdg_rad) * math.cos(pitch_rad) * math.cos(roll_rad) + math.sin(hdg_rad) * math.sin(pitch_rad) * math.sin(roll_rad),
        [1] = math.cos(hdg_rad) * math.cos(pitch_rad) * math.sin(roll_rad) - math.sin(hdg_rad) * math.sin(pitch_rad) * math.cos(roll_rad),
        [2] = math.cos(hdg_rad) * math.sin(pitch_rad) * math.cos(roll_rad) + math.sin(hdg_rad) * math.cos(pitch_rad) * math.sin(roll_rad),
        [3] = -math.cos(hdg_rad) * math.sin(pitch_rad) * math.sin(roll_rad) + math.sin(hdg_rad) * math.cos(pitch_rad) * math.cos(roll_rad)
    }
end

-- @return pitch_rad, roll_rad
local function levelWithGround(hdg_rad)
    -- https://forums.x-plane.org/index.php?/forums/topic/267531-how-to-probe-a-mesh-slope-with-xplmprobeterrainxyz/
    local groundNormal = XPLMGetDatavf(groundNormal_dataref, 0, 3)

    local thetaNorth = math.atan2(groundNormal[2], groundNormal[1])
    local phiNorth = math.asin(groundNormal[0])

    -- rotate to plane heading
    local theta = thetaNorth * math.cos(hdg_rad) - phiNorth * math.sin(hdg_rad)
    local phi = thetaNorth * math.sin(hdg_rad) + phiNorth * math.cos(hdg_rad)

    return theta, phi
end

local function setRotation(hdg_rad, pitch_rad, roll_rad)
    -- I haven't understood yet why for q 360° are 1 PI (not 2) but here we go...
    -- @see https://developer.x-plane.com/article/movingtheplane/
    local q = eulerToQuaternion(hdg_rad / 2, pitch_rad / 2, roll_rad / 2)
    -- I think we actually only have to update when leaving override_planepath but whatever...
    XPLMSetDatavf(q_dataref, q, 0, 4)

    XPLMSetDataf(hdg_dataref, math.deg(hdg_rad))
    XPLMSetDataf(pitch_dataref, math.deg(pitch_rad))
    XPLMSetDataf(roll_dataref, math.deg(roll_rad))
end

local function arrestAngularMomentum()
    set("sim/flightmodel/position/Prad", 0.)
    set("sim/flightmodel/position/Qrad", 0.)
    set("sim/flightmodel/position/Rrad", 0.)
end

local function do_slew()
    local period_s = XPLMGetDataf(period_s_dataref)

    local x = XPLMGetDataf(x_dataref)
    local y = XPLMGetDataf(y_dataref)
    local z = XPLMGetDataf(z_dataref)

    local agl = XPLMGetDataf(agl_dataref)

    local hdg_rad = math.rad(XPLMGetDataf(hdg_dataref))
    local pitch_deg = XPLMGetDataf(pitch_dataref)
    local pitch_rad = math.rad(pitch_deg)
    local roll_deg = XPLMGetDataf(roll_dataref)
    local roll_rad = math.rad(roll_deg)

    local axii = XPLMGetDatavf(axii_dataref, 0, 4)

    --[[ position ]]

    -- forward
    local functionSettings = settings['move']['forward']
    if functionSettings['onlyWhenModifier'] == null or functionSettings['onlyWhenModifier'] == isModifierKeyPressed then
        local dForward = accelerate(axii[functionSettings['axis']], functionSettings['inputAccel'])
        local dForward_mPerS = dForward * functionSettings['max_mPerS']
        if doFreeze then
            dForwardFreeze_mPerS = dForward_mPerS
        end
        local dForward_mPerS = dForward_mPerS + dForwardFreeze_mPerS
        local dx = -math.sin(hdg_rad) * dForward_mPerS * period_s
        x = x + dx
        local dz = math.cos(hdg_rad) * dForward_mPerS * period_s
        z = z + dz
    end

    -- sideways
    local functionSettings = settings['move']['sideways']
    if functionSettings['onlyWhenModifier'] == null or functionSettings['onlyWhenModifier'] == isModifierKeyPressed then
        local dSideways = accelerate(axii[functionSettings['axis']], functionSettings['inputAccel'])
        local dSideways_mPerS = dSideways * functionSettings['max_mPerS']
        if doFreeze then
            dSidewaysFreeze_mPerS = dSideways_mPerS
        end
        local dSideways_mPerS = dSideways_mPerS + dSidewaysFreeze_mPerS
        local dx = -math.sin(hdg_rad - math.pi / 2) * dSideways_mPerS * period_s
        x = x + dx
        local dz = math.cos(hdg_rad - math.pi / 2) * dSideways_mPerS * period_s
        z = z + dz
    end
    -- stop freeze capturing
    doFreeze = false

    -- adjust altitude
    local dy = dAltitude_mPerS * period_s
    y = y + dy
    agl = agl + dy
    -- reset after
    dAltitude_mPerS = 0.

    if agl < aircraftGearAgl_m then
        if not isFollowGround then
            log("Entered the ground domain. Killing all momentum.")
            isFollowGround = true
            XPLMSetDataf(vx_dataref, 0.)
            XPLMSetDataf(vy_dataref, 0.)
            XPLMSetDataf(vz_dataref, 0.)
            arrestAngularMomentum()
        end
    end

    -- plant on ground if isFollowGround
    if isFollowGround then
        y = y - agl + aircraftGearAgl_m

        local groundPitch_rad, groundRoll_rad = levelWithGround(hdg_rad)
        -- smooth 1/x seconds attack
        local pitchTarget_rad = groundPitch_rad + math.rad(aircraftGearPitch_deg)
        local dPitchTarget_rad = pitchTarget_rad - pitch_rad
        local dPitch_rad = dPitchTarget_rad / settings['followGroundSmoothing']['pitch'] * period_s
        pitch_rad = pitch_rad + dPitch_rad

        local rollTarget_rad = groundRoll_rad
        local dRollTarget_rad = rollTarget_rad - roll_rad
        local dRoll_rad = dRollTarget_rad / settings['followGroundSmoothing']['roll'] * period_s
        roll_rad = roll_rad + dRoll_rad
    end

    --[[ rotation ]]
    local functionSettings = settings['rotate']['pitch']
    if functionSettings['onlyWhenModifier'] == null or functionSettings['onlyWhenModifier'] == isModifierKeyPressed then
        local _d = accelerate(axii[functionSettings['axis']], functionSettings['inputAccel'])
        local _d_radPerS = _d * functionSettings['max_radPerS']
        pitch_rad = pitch_rad + _d_radPerS * period_s
    end

    local functionSettings = settings['rotate']['roll']
    if functionSettings['onlyWhenModifier'] == null or functionSettings['onlyWhenModifier'] == isModifierKeyPressed then
        local _d = accelerate(axii[functionSettings['axis']], functionSettings['inputAccel'])
        local _d_radPerS = _d * functionSettings['max_radPerS']
        roll_rad = roll_rad + _d_radPerS * period_s
    end

    local functionSettings = settings['rotate']['yaw']
    if functionSettings['onlyWhenModifier'] == null or functionSettings['onlyWhenModifier'] == isModifierKeyPressed then
        local _d = accelerate(axii[functionSettings['axis']], functionSettings['inputAccel'])
        local _d_radPerS = _d * functionSettings['max_radPerS']
        hdg_rad = hdg_rad + _d_radPerS * period_s
    end

    --[[ write ]]
    XPLMSetDatad(x_dataref, x)
    XPLMSetDatad(y_dataref, y)
    XPLMSetDatad(z_dataref, z)
    setRotation(hdg_rad, pitch_rad, roll_rad)
end

local function isOnGround()
    -- gearsOnGround_dataref won't work while physics off
    local isOverridePlanepath = XPLMGetDatavi(overridePlanepath_dataref, 0, 1)[0]
    if isOverridePlanepath == 1 then
        return false
    end

    local gearsOnGround = XPLMGetDatavi(gearsOnGround_dataref, 0, 10)
    for i, v in ipairs(gearsOnGround) do
        if v == 1 then
            return true
        end
    end

    return false
end

local function activate(isEnabled)
    slewMode_isEnabled = isEnabled

    log(
        string.format(
            "enabled: %s",
            slewMode_isEnabled
        )
    )

    if slewMode_isEnabled then
        -- init if we have been activated
        isFollowGround = isOnGround()
        if isFollowGround then
            -- let's capture the current pitch attitude if on the ground - saves us from calculating the gear "plane" from raw gear position values...
            local hdg_rad = math.rad(XPLMGetDataf(hdg_dataref))
            local pitchTerrain_rad, _ = levelWithGround(hdg_rad)
            aircraftGearPitch_deg = XPLMGetDataf(pitch_dataref) - math.deg(pitchTerrain_rad)
            aircraftGearAgl_m = XPLMGetDataf(agl_dataref)
        end

        log(
            string.format(
                "Entered the %s domain. Default gear plane pitch angle: %.2f°, agl: %.2fm",
                isFollowGround and "ground" or "air",
                aircraftGearPitch_deg,
                aircraftGearAgl_m
            )
        )
    else
        -- align velicity vector with rotation
        local vx = XPLMGetDataf(vx_dataref)
        local vy = XPLMGetDataf(vy_dataref)
        local vz = XPLMGetDataf(vz_dataref)
        local speed_local = math.sqrt(vx^2 + vy^2 + vz^2)

        local hdg_rad = math.rad(XPLMGetDataf(hdg_dataref))
        local pitch_rad = math.rad(XPLMGetDataf(pitch_dataref))

        local vx = math.sin(hdg_rad) * math.cos(pitch_rad) * speed_local
        local vy = math.sin(pitch_rad) * speed_local
        local vz = -math.cos(hdg_rad) * math.cos(pitch_rad) * speed_local

        XPLMSetDataf(vx_dataref, vx)
        XPLMSetDataf(vy_dataref, vy)
        XPLMSetDataf(vz_dataref, vz)

        -- unset freeze mode
        dForwardFreeze_mPerS = 0.
        dSidewaysFreeze_mPerS = 0.
        doFreeze = false
    end

    -- http://www.xsquawkbox.net/xpsdk/mediawiki/Sim/operation/override/override_planepath
    local overridePlanepath = {[0] = slewMode_isEnabled and 1 or 0}
    XPLMSetDatavi(
        overridePlanepath_dataref,
        overridePlanepath,
        0,
        1
    )
end

local function init()
    addToggleMacroAndCommand(
        "flightwusel/SlewMode/",
        "SlewMode: ",
        "slewMode_activate_callback",
        "slewMode_isEnabled"
    )
    addMacroAndCommand(
        "flightwusel/SlewMode/Altitude_increase_lots",
        "SlewMode: Altitude ++",
        "slewMode_altitudeChangeBy_callback(100.)",
        "slewMode_altitudeChangeBy_callback(200.)"
    )
    addMacroAndCommand(
        "flightwusel/SlewMode/Altitude_increase",
        "SlewMode: Altitude +",
        "slewMode_altitudeChangeBy_callback(10.)",
        "slewMode_altitudeChangeBy_callback(20.)"
    )
    addMacroAndCommand(
        "flightwusel/SlewMode/Altitude_decrease",
        "SlewMode: Altitude -",
        "slewMode_altitudeChangeBy_callback(-10.)",
        "slewMode_altitudeChangeBy_callback(-20.)"
    )
    addMacroAndCommand(
        "flightwusel/SlewMode/Altitude_decrease_lots",
        "SlewMode: Altitude --",
        "slewMode_altitudeChangeBy_callback(-100.)",
        "slewMode_altitudeChangeBy_callback(-200.)"
    )
    addMacroAndCommand(
        "flightwusel/SlewMode/Level",
        "SlewMode: Level roll and pitch",
        "slewMode_setLevel_callback()"
    )
    do_every_frame("slewMode_frame_callback()")
    do_every_draw("slewMode_draw_callback()")
    do_on_keystroke("slewmode_keystroke_callback()")
end

--[[ global ]]

slewMode_isEnabled = false

function slewMode_activate_callback(isEnabled)
    if slewMode_isEnabled == isEnabled then
        return
    end

    activate(isEnabled)
end

function slewMode_altitudeChangeBy_callback(_dAltitude_mPerS)
    if not slewMode_isEnabled then
        return
    end

    if isFollowGround and _dAltitude_mPerS > 0. then
        log("Entered the air domain.")
        isFollowGround = false
    end
    dAltitude_mPerS = _dAltitude_mPerS
end

function slewMode_setLevel_callback()
    if not slewMode_isEnabled then
        return
    end

    -- this function can be used to reset a wrong gear plane
    if isFollowGround then
        aircraftGearPitch_deg = 0.
        aircraftGearAgl_m = 0.
    end
    --arrestAngularMomentum()

    XPLMSetDataf(pitch_dataref, 0.)
    XPLMSetDataf(roll_dataref, 0.)
end

function slewMode_frame_callback()
    if not slewMode_isEnabled then
        return
    end

    do_slew()
end

function slewMode_draw_callback()
    if not slewMode_isEnabled then
        return
    end

    big_bubble(
        -20,
        -20,
        "Slew active",
        isFollowGround and "Following terrain" or "Free"
    )
end

function slewmode_keystroke_callback()
    if not slewMode_isEnabled then
        return
    end

    if VKEY == settings['modifierKeyCode'] and SHIFT_KEY then
        -- freeze inputs on next frame if modifier + SHIFT
        doFreeze = true
        log("Freezing movement vector.")
    elseif VKEY == settings['modifierKeyCode'] then
        isModifierKeyPressed = KEY_ACTION == "pressed"
        log(
            string.format(
                "modifier enabled: %s",
                isModifierKeyPressed
            )
        )
    end

    -- RESUME_KEY
end

init()
