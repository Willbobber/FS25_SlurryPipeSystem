-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSBootDeform.lua
-- [SPS 1.0.1.8] Skinned rubber boot driver, FOLLOW version (William 2026-10-18): the boot's rim rides on the fill arm.
--
-- The station mesh is skinned to a BASE bone at the bottom of the boot (Bone01) and a RIM bone (Bone02) that lives
-- INSIDE a follow node (fillarmConnectNode). The port's lower / upper nodes never move: they are the docking window
-- and the rest reference. Rule:
--   * CAPTURE - a rubber-boot arm tip comes into the boot (detectArmConnection notes it: within REACH_XZ of the boot
--     axis, from REACH_ABOVE over the rim down to REACH_BELOW under the lower node) AND gets within CAPTURE_DIST of the
--     follow node's rest point (or is already below it on the axis) - the boot never lifts to meet the arm. The follow
--     node then LOCKS onto the tip: same place, and the node's Y axis follows the tip node's Y axis (convention: a fill-arm tip node's
--     green / Y axis points UP the suction head, README 01) so the boot tilts to the head's real angle (Samson pgII28:
--     the flange is not square to the floor). The boot's own spin is kept: a round boot has no visible yaw, and tip
--     nodes from other authors may have any yaw.
--   * LOCKED - the node goes wherever the tip goes, including BELOW its rest height: the arm squeezes the rim toward
--     the base. The arm is never moved by the station.
--   * RELEASE - the locked node rises RELEASE_UP above the LOWER node (rest = where the i3d puts it, 0.20 m on the
--     docking station) or drifts RELEASE_XZ off the boot axis, or the tip node dies. The node then eases back to rest.
--   * BASE - the base bone follows BASE_FOLLOW of the rim's sideways displacement; 0 (default) = base dead still.
-- Purely visual, every peer: arm nodes are network-synced, the boot nodes are not and need not be.

SPSBootDeform = {}
SPSBootDeform.REACH_XZ     = 0.25   -- capture: tip within this radius of the boot axis ...
SPSBootDeform.REACH_ABOVE  = 0.05   -- ... from this far above the upper node ...
SPSBootDeform.REACH_BELOW  = 0.25   -- ... down to this far below the lower node
SPSBootDeform.CAPTURE_DIST = 0.08   -- lock only when the tip is this close to the follow node's REST point (or already below it on the axis);
                                    -- William 2026-10-18: the boot must not lift to meet the arm - "when the nodes are a small distance from each other they connect"
SPSBootDeform.RELEASE_UP   = 0.30   -- release: locked node this far above the LOWER node (William 2026-10-18: 0.50 "too much"; 0.30 keeps "a bit of suction")
SPSBootDeform.RELEASE_XZ   = 0.30   -- release: locked node this far off the boot axis
SPSBootDeform.LOCK_RATE    = 25     -- 1/s: easing onto the tip after capture (fast, no pop)
SPSBootDeform.RELEASE_RATE = 10     -- 1/s: easing back to rest after release
SPSBootDeform.BASE_FOLLOW  = 0      -- base bone share of the rim's sideways displacement. 0: on the docking station Bone01 carries the WHOLE post (everything below the boot is weighted to it), so any follow moved the station (William 2026-10-18)
SPSBootDeform.HOLD_MS      = 300    -- a noted tip is trusted this long for CAPTURE (detection runs every 3rd tick)

local function say(fmt, ...) print("[SPS BOOT] " .. string.format(fmt, ...)) end
local function sayInfo(fmt, ...) if spsInfoOn ~= nil and spsInfoOn() then say(fmt, ...) end end   -- [SPS 1.0.1.8] routine lines: channel Info

local function findByName(node, name)
    if node == nil or node == 0 then return nil end
    if getName(node) == name then return node end
    for i = 0, getNumOfChildren(node) - 1 do
        local hit = findByName(getChildAt(node, i), name)
        if hit ~= nil then return hit end
    end
    return nil
end

local function alive(n) return n ~= nil and n ~= 0 and entityExists(n) end

local function normalize(x, y, z)
    local l = math.sqrt(x * x + y * y + z * z)
    if l < 1e-6 then return 0, 1, 0, 0 end
    return x / l, y / l, z / l, l
end

-- Hamilton product a*b (x,y,z,w): rotate by b first, then a.
local function qmul(ax, ay, az, aw, bx, by, bz, bw)
    return aw * bx + ax * bw + ay * bz - az * by,
           aw * by - ax * bz + ay * bw + az * bx,
           aw * bz + ax * by - ay * bx + az * bw,
           aw * bw - ax * bx - ay * by - az * bz
end

-- Quaternion taking unit vector a onto unit vector b (shortest arc).
local function qFromTo(ax, ay, az, bx, by, bz)
    local d = ax * bx + ay * by + az * bz
    if d > 0.999999 then return 0, 0, 0, 1 end
    if d < -0.999999 then
        -- 180 deg: any axis perpendicular to a
        local px, py, pz = normalize(-ay, ax, 0)
        if math.abs(ax) < 1e-3 and math.abs(ay) < 1e-3 then px, py, pz = 1, 0, 0 end
        return px, py, pz, 0
    end
    local cx, cy, cz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
    local w = 1 + d
    local x, y, z, l = normalize(cx, cy, cz)
    local s = math.sqrt(l * l + w * w)
    return cx / s, cy / s, cz / s, w / s
end

-- Bind a port's follow node (+ optional base bone). Rest pose = the nodes as loaded (parent-local).
function SPSBootDeform.attachNodes(rbpEntry, followNode, baseBone, label)
    if rbpEntry == nil or not alive(followNode) then return false end
    local parent = getParent(followNode)
    if parent == nil or parent == 0 then return false end
    if baseBone ~= nil and (not alive(baseBone) or getParent(baseBone) ~= parent) then
        say("attach %s: base bone must share the follow node's parent - base ignored", tostring(label))
        baseBone = nil
    end
    local tx, ty, tz = getTranslation(followNode)
    local qx, qy, qz, qw = getQuaternion(followNode)
    -- rest boot axis = the node's local Y, expressed in the parent's space
    local wx, wy, wz = localDirectionToWorld(followNode, 0, 1, 0)
    local ax, ay, az = normalize(worldDirectionToLocal(parent, wx, wy, wz))
    local b = {
        follow = followNode, base = baseBone, parent = parent, label = tostring(label),
        tx = tx, ty = ty, tz = tz, qx = qx, qy = qy, qz = qz, qw = qw, ax = ax, ay = ay, az = az,
        cx = tx, cy = ty, cz = tz, cax = ax, cay = ay, caz = az,     -- current (eased) translation / axis
        locked = false, tipNode = nil, tipTime = -math.huge, atRest = true,
    }
    if baseBone ~= nil then b.bx, b.by, b.bz = getTranslation(baseBone) end
    rbpEntry.boot = b
    sayInfo("attach %s: follow=%s base=%s rest=(%.3f %.3f %.3f)", b.label, getName(followNode),
        baseBone ~= nil and getName(baseBone) or "-", tx, ty, tz)
    return true
end

-- Same, nodes found by name under searchRoot (chain docking station).
function SPSBootDeform.attach(rbpEntry, searchRoot, followName, baseName, label)
    return SPSBootDeform.attachNodes(rbpEntry, findByName(searchRoot, followName), findByName(searchRoot, baseName), label)
end

-- Called from detectArmConnection for every rubber-boot arm tip near a port (ty / lowerY / upperY world, xzDist m).
function SPSBootDeform.noteTip(rbpEntry, tipNode, ty, lowerY, upperY, xzDist)
    local b = rbpEntry.boot
    if b == nil or tipNode == nil or b.locked then return end
    if xzDist > SPSBootDeform.REACH_XZ or ty > upperY + SPSBootDeform.REACH_ABOVE or ty < lowerY - SPSBootDeform.REACH_BELOW then return end
    -- close enough to the rest point? (xzDist is measured from the lower node = the boot axis = the rest point's XZ)
    if not alive(b.parent) then return end
    local _, restY, _ = localToWorld(b.parent, b.tx, b.ty, b.tz)
    local dy = ty - restY
    local near = (xzDist * xzDist + dy * dy) <= SPSBootDeform.CAPTURE_DIST * SPSBootDeform.CAPTURE_DIST
    local below = dy <= 0 and xzDist <= SPSBootDeform.CAPTURE_DIST
    if near or below then
        b.tipNode = tipNode
        b.tipTime = g_time or 0
    end
end

local function setLock(b, locked, why)
    if b.locked == locked then return end
    b.locked = locked
    if not locked then b.tipNode = nil end
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSBootDeform") then
        sayInfo("%s: %s (%s)", b.label, locked and "LOCKED onto arm tip" or "released", tostring(why))
    end
end

-- Per frame.
function SPSBootDeform.tick(rbpEntry, dt)
    local b = rbpEntry.boot
    if b == nil then return end
    if not (alive(b.follow) and alive(b.parent) and alive(rbpEntry.lowerNode)) then return end

    local now = g_time or 0
    local lx, ly, lz = getWorldTranslation(rbpEntry.lowerNode)

    -- lock state
    if b.locked then
        if not alive(b.tipNode) then
            setLock(b, false, "tip node gone")
        else
            local wx, wy, wz = getWorldTranslation(b.tipNode)
            local dx, dz = wx - lx, wz - lz
            if wy - ly > SPSBootDeform.RELEASE_UP then
                setLock(b, false, string.format("%.2f m above the lower node", wy - ly))
            elseif math.sqrt(dx * dx + dz * dz) > SPSBootDeform.RELEASE_XZ then
                setLock(b, false, "off the boot axis")
            end
        end
    elseif b.tipNode ~= nil then
        if (now - b.tipTime) <= SPSBootDeform.HOLD_MS and alive(b.tipNode) then
            setLock(b, true, getName(b.tipNode))
        else
            b.tipNode = nil
        end
    end

    -- target (parent space)
    local ttx, tty, ttz, tax, tay, taz, rate
    if b.locked then
        local wx, wy, wz = getWorldTranslation(b.tipNode)
        ttx, tty, ttz = worldToLocal(b.parent, wx, wy, wz)
        local dx, dy, dz = localDirectionToWorld(b.tipNode, 0, 1, 0)
        tax, tay, taz = normalize(worldDirectionToLocal(b.parent, dx, dy, dz))
        rate = SPSBootDeform.LOCK_RATE
    else
        ttx, tty, ttz, tax, tay, taz = b.tx, b.ty, b.tz, b.ax, b.ay, b.az
        rate = SPSBootDeform.RELEASE_RATE
        if b.atRest then return end
    end

    -- ease
    local k = 1 - math.exp(-rate * (dt or 16) / 1000)
    b.cx = b.cx + (ttx - b.cx) * k
    b.cy = b.cy + (tty - b.cy) * k
    b.cz = b.cz + (ttz - b.cz) * k
    b.cax, b.cay, b.caz = normalize(b.cax + (tax - b.cax) * k, b.cay + (tay - b.cay) * k, b.caz + (taz - b.caz) * k)

    -- settled back at rest: snap exactly once, then stop touching the nodes
    if not b.locked then
        local ex, ey, ez = b.cx - b.tx, b.cy - b.ty, b.cz - b.tz
        local ad = b.cax * b.ax + b.cay * b.ay + b.caz * b.az
        if ex * ex + ey * ey + ez * ez < 1e-6 and ad > 0.99999 then
            setTranslation(b.follow, b.tx, b.ty, b.tz)
            setQuaternion(b.follow, b.qx, b.qy, b.qz, b.qw)
            if b.base ~= nil and alive(b.base) then setTranslation(b.base, b.bx, b.by, b.bz) end
            b.cx, b.cy, b.cz, b.cax, b.cay, b.caz = b.tx, b.ty, b.tz, b.ax, b.ay, b.az
            b.atRest = true
            return
        end
    end
    b.atRest = false

    -- apply: translation, and rest rotation re-aimed from the rest axis onto the current axis
    setTranslation(b.follow, b.cx, b.cy, b.cz)
    local dx, dy, dz, dw = qFromTo(b.ax, b.ay, b.az, b.cax, b.cay, b.caz)
    local rx, ry, rz, rw = qmul(dx, dy, dz, dw, b.qx, b.qy, b.qz, b.qw)
    setQuaternion(b.follow, rx, ry, rz, rw)

    if b.base ~= nil and alive(b.base) and SPSBootDeform.BASE_FOLLOW > 0 then
        -- sideways displacement of the rim = displacement from rest minus its part along the rest axis
        local ex, ey, ez = b.cx - b.tx, b.cy - b.ty, b.cz - b.tz
        local along = ex * b.ax + ey * b.ay + ez * b.az
        local f = SPSBootDeform.BASE_FOLLOW
        setTranslation(b.base, b.bx + (ex - along * b.ax) * f, b.by + (ey - along * b.ay) * f, b.bz + (ez - along * b.az) * f)
    end
end

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSBootDeform 1.0.1.8 loaded (follow)") end
