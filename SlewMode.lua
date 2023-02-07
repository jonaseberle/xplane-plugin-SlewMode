--[[
    Author: flightwusel
    Tested with: XP 12.03r1
    Kudos to teleport.lua by shryft for all things placement and rotation
    Thanks to apn, philipp and KarlL in https://forums.x-plane.org/index.php?/forums/topic/267531-how-to-probe-a-mesh-slope-with-xplmprobeterrainxyz/ for how to rotate the plane to align with terrain
]]

local settings = {
    forward = {
        axis = 1,
        max_mPerS = 2000,
        inputAccel = 1000,
    },
    sideways = {
        axis = 2,
        max_mPerS = 2000,
        inputAccel = 1000,
    },
    turn = {
        axis = 3,
        max_radPerS = math.rad(300),
        inputAccel = 400,
    },
}

local isEnabled = false
local isFollowGround = false
local dAltitude_mPerS = 0.
local aircraftGearPitch_deg = 0.
local aircraftGearAgl_m = 0.

local x_dataref = XPLMFindDataRef("sim/flightmodel/position/local_x")
local y_dataref = XPLMFindDataRef("sim/flightmodel/position/local_y")
local z_dataref = XPLMFindDataRef("sim/flightmodel/position/local_z")
local pitch_dataref = XPLMFindDataRef("sim/flightmodel/position/theta")
local roll_dataref = XPLMFindDataRef("sim/flightmodel/position/phi")
local hdg_dataref = XPLMFindDataRef("sim/flightmodel/position/psi")
local q_dataref = XPLMFindDataRef("sim/flightmodel/position/q")
local groundNormal_dataref = XPLMFindDataRef("sim/flightmodel/ground/plugin_ground_slope_normal")
local agl_dataref = XPLMFindDataRef("sim/flightmodel/position/y_agl")
local period_s_dataref = XPLMFindDataRef("sim/operation/misc/frame_rate_period")
local axii_dataref = XPLMFindDataRef("sim/joystick/joy_mapped_axis_value")

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
    local fileName = filePath:match("[^/\\]*.lua$")
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

-- @return pitch_deg, roll_deg
local function levelWithGround(hdg_rad)
    -- https://forums.x-plane.org/index.php?/forums/topic/267531-how-to-probe-a-mesh-slope-with-xplmprobeterrainxyz/
    local groundNormal = XPLMGetDatavf(groundNormal_dataref, 0, 3)

    local thetaNorth = math.atan2(groundNormal[2], groundNormal[1])
    local phiNorth = math.asin(groundNormal[0])

    -- rotate to plane heading
    local theta = thetaNorth * math.cos(hdg_rad) - phiNorth * math.sin(hdg_rad)
    local phi = thetaNorth * math.sin(hdg_rad) + phiNorth * math.cos(hdg_rad)

    return math.deg(theta), math.deg(phi)
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

    local dForward = accelerate(axii[settings['forward']['axis']], settings['forward']['inputAccel'])
    local dForward_mPerS = dForward * settings['forward']['max_mPerS']
    local dx = -math.sin(hdg_rad) * dForward_mPerS * period_s
    x = x + dx
    local dz = math.cos(hdg_rad) * dForward_mPerS * period_s
    z = z + dz

    local dSideways = accelerate(axii[settings['sideways']['axis']], settings['turn']['inputAccel'])
    local dSideways_mPerS = dSideways * settings['sideways']['max_mPerS']
    local dx = -math.sin(hdg_rad - math.pi / 2) * dSideways_mPerS * period_s
    x = x + dx
    local dz = math.cos(hdg_rad - math.pi / 2) * dSideways_mPerS * period_s
    z = z + dz

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
            -- kill all momentum
            set("sim/flightmodel/position/local_vx", 0.)
            set("sim/flightmodel/position/local_vy", 0.)
            set("sim/flightmodel/position/local_vz", 0.)
            set("sim/flightmodel/position/Prad", 0.)
            set("sim/flightmodel/position/Qrad", 0.)
            set("sim/flightmodel/position/Rrad", 0.)

        end
    end

    -- plant on ground if isFollowGround
    if isFollowGround then
        y = y - agl + aircraftGearAgl_m

        local groundPitch_deg, groundRoll_deg = levelWithGround(hdg_rad)
        local _pitch_deg = groundPitch_deg + aircraftGearPitch_deg
        local _roll_deg = groundRoll_deg
        -- smooth 1/4s attack
        XPLMSetDataf(pitch_dataref, pitch_deg + (_pitch_deg - pitch_deg) * period_s * 4)
        XPLMSetDataf(roll_dataref, roll_deg + (_roll_deg - roll_deg) * period_s * 4)
    end

    XPLMSetDatad(x_dataref, x)
    XPLMSetDatad(y_dataref, y)
    XPLMSetDatad(z_dataref, z)

    --[[ rotation ]]

    local dTurn = accelerate(axii[settings['turn']['axis']], settings['turn']['inputAccel'])
    local dHdg_radPerS = dTurn * settings['turn']['max_radPerS']
    hdg_rad = hdg_rad + dHdg_radPerS * period_s

    XPLMSetDataf(hdg_dataref, math.deg(hdg_rad))

    -- I haven't understood yet why for q 360° are 1 PI (not 2) but here we go...
    -- @see https://developer.x-plane.com/article/movingtheplane/
    local q = eulerToQuaternion(hdg_rad / 2, pitch_rad / 2, roll_rad / 2)
    XPLMSetDatavf(q_dataref, q, 0, 4)
end

local function isOnGround()
    local gearsOnGround = XPLMGetDatavi(
        XPLMFindDataRef("sim/flightmodel2/gear/on_ground"),
        0,
        10
    )

    for i, v in ipairs(gearsOnGround) do
        if v == 1 then
            return true
        end
    end

    return false
end

local function activate(_isEnabled)
    if isEnabled == _isEnabled then
        return
    end
    isEnabled = _isEnabled

    log(
        string.format(
            "enabled: %s",
            isEnabled
        )
    )

    if isEnabled then
        -- init if we have been activated
        isFollowGround = isOnGround()
        if isFollowGround then
            -- let's capture the current pitch attitude if on the ground - saves us from calculating the gear "plane" from raw gear position values...
            local hdg_rad = math.rad(XPLMGetDataf(hdg_dataref))
            local pitchTerrain_deg, _ = levelWithGround(hdg_rad)
            aircraftGearPitch_deg = XPLMGetDataf(pitch_dataref) - pitchTerrain_deg
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
    end

    -- http://www.xsquawkbox.net/xpsdk/mediawiki/Sim/operation/override/override_planepath
    local overridePlanepath = {[0] = isEnabled and 1 or 0}
    XPLMSetDatavi(
        XPLMFindDataRef("sim/operation/override/override_planepath"),
        overridePlanepath,
        0,
        1
    )
end

local function init()
    addMacroAndCommand(
        "flightwusel/SlewMode/Toggle",
        "SlewMode: Activate/De-Activate (Toggle)",
        "slewMode_toggle_callback()"
    )
    addMacroAndCommand(
        "flightwusel/SlewMode/Activate",
        "SlewMode: Activate",
        "slewMode_activate_callback(true)"
    )
    addMacroAndCommand(
        "flightwusel/SlewMode/Deactivate",
        "SlewMode: De-Activate",
        "slewMode_activate_callback(false)"
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
    do_every_frame("slewMode_frame_callback()")
    do_every_draw("slewMode_draw_callback()")
end

init()

--[[ global ]]

function slewMode_toggle_callback()
    activate(not isEnabled)
end

function slewMode_activate_callback(_isEnabled)
    activate(_isEnabled)
end

function slewMode_altitudeChangeBy_callback(_dAltitude_mPerS)
    if not isEnabled then
        return
    end

    if isFollowGround and _dAltitude_mPerS > 0. then
        log("Entered the air domain.")
        isFollowGround = false
    end
    dAltitude_mPerS = _dAltitude_mPerS
end

function slewMode_frame_callback()
    if not isEnabled then
        return
    end

    do_slew()
end

function slewMode_draw_callback()
    if not isEnabled then
        return
    end

    big_bubble(
        -20,
        -20,
        "Slew active",
        isFollowGround and "Following terrain" or "Free"
    )
end
