-- ===========================================================================
-- FS25_SlurryPipeSystem - SPSM_Drawbar.lua  (SlurryPipeManager extension)
-- [SPS 1.0.2.0] DRAWBAR SUSPENSION (William 2026-11-03, Supercis 800 SPS): "when the tanker is moving the front acts
-- like a suspension - the drawbar goes up and down / rotates on its X axis, which moves the hydraulic cylinder and
-- its punch; a little when empty, more when full".
--
-- XML (inside <slurryPipeSystem>):
--   <drawbarSuspension node="drawbarNode" cylinderNode="drawbarHydrCylin" punchNode="drawbarHydrPunch"
--                      punchRefNode="drawbarHydrPunchRef" cylinderAxis="y|z"
--                      loadAngle="1.0" maxAngle="2.5" emptyScale="0.35" fullScale="1.0" bumpGain="3.0" accelGain="0.6"
--                      spring="40" damper="7"/>
--   node        : the drawbar pivot (rotated on its LOCAL X, rest rotation from the i3d; the eye sits at +Z of it, so
--                 a POSITIVE angle drops the eye and pushes the punch into the cylinder)
--   bodyNode    : (optional) the tank body group with its origin on the AXLE line; with hookNode (default attacherJoint)
--                 the body pitches about the axle and the drawbar swings about the hook (William's model, see parse)
--   loadAngle   : static dip (degrees) at a full tank, scaled by fill level - the weight on the hitch
--   cylinderNode: the hydraulic cylinder, a child of the drawbar; cylinderAxis = which of its local axes runs along
--                 the ram (Blender-made parts have Y, GIANTS-made parts have Z). It is aimed at punchRefNode every
--                 frame and punchNode (its child) slides along that axis so the ram meets the reference.
--   bumpGain    : angle per m/s of vertical hitch movement; accelGain: angle per m/s^2 of fore-aft acceleration
--   spring / damper: the angle follows its target through a spring-damper (per second), so it bounces a little.
--
-- Every peer runs it from its own observed motion (world position of the pivot + the vehicle's synced speed), so no
-- events: visual only, deterministic enough. Detached (on the support) the drawbar goes back to rest.
-- ===========================================================================
local function nodeOk(n) return n ~= nil and n ~= 0 and entityExists(n) end

function SlurryPipeManager:parseDrawbarSuspension(entry, xmlFile, kp, findLinkedNode)
    local key = kp .. "slurryPipeSystem.drawbarSuspension"
    if xmlFile == nil or not xmlFile:hasProperty(key) then return end
    local node = findLinkedNode(xmlFile:getString(key .. "#node"))
    if not nodeOk(node) then
        print(string.format("[SPS] WARNING: drawbarSuspension on %s skipped - node '%s' not found",
            tostring(entry.vehicle and entry.vehicle.configFileName), tostring(xmlFile:getString(key .. "#node"))))
        return
    end
    local d = {
        node       = node,
        -- [SPS 1.0.2.0] bodyNode (optional): the TANK BODY group (everything except the drawbar and the wheels), with its
        -- origin at the drawbar pivot. When given, the drawbar stays put (the eye stays on the hook) and the BODY pitches
        -- the other way about the pivot - the real mechanism (William: "the attacher joint is fixed, the front of the
        -- tanker dips"). Without it the drawbar itself rotates about the pivot.
        body       = findLinkedNode(xmlFile:getString(key .. "#bodyNode")),
        cylinder   = findLinkedNode(xmlFile:getString(key .. "#cylinderNode")),
        punch      = findLinkedNode(xmlFile:getString(key .. "#punchNode")),
        punchRef   = findLinkedNode(xmlFile:getString(key .. "#punchRefNode")),
        axis       = string.lower(xmlFile:getString(key .. "#cylinderAxis", "z")),
        loadAngle  = math.rad(xmlFile:getFloat(key .. "#loadAngle", 0)),   -- static droop at a full tank (eye down = -X)
        maxAngle   = math.rad(xmlFile:getFloat(key .. "#maxAngle", 2.5)),
        emptyScale = xmlFile:getFloat(key .. "#emptyScale", 0.35),
        fullScale  = xmlFile:getFloat(key .. "#fullScale", 1.0),
        bumpGain   = math.rad(xmlFile:getFloat(key .. "#bumpGain", 3.0)),
        accelGain  = math.rad(xmlFile:getFloat(key .. "#accelGain", 0.6)),
        spring     = xmlFile:getFloat(key .. "#spring", 40),
        damper     = xmlFile:getFloat(key .. "#damper", 7),
        fillUnitIndex = xmlFile:getInt(key .. "#fillUnitIndex", 1),
        angle = 0, vel = 0, lastY = nil, lastSpeed = nil,
    }
    d.restRx, d.restRy, d.restRz = getRotation(node)
    d.restTx, d.restTy, d.restTz = getTranslation(node)
    if nodeOk(d.body) then
        d.bodyRx, d.bodyRy, d.bodyRz = getRotation(d.body)
        -- [SPS 1.0.2.0] William's model (2026-11-03): the HOOK is fixed by the tractor, the AXLE is fixed to the body, the
        -- body pitches about the axle, the drawbar pivot on the body drops with the nose and the drawbar beam swings
        -- about the hook to follow it. Needs: the axle = bodyNode's origin (tankBody sits at the wheel centre line), the
        -- hook = hookNode (default "attacherJoint") in the drawbar's own frame, all in the drawbar's PARENT frame.
        d.hook = findLinkedNode(xmlFile:getString(key .. "#hookNode", "attacherJoint"))
        local parent = getParent(node)
        if nodeOk(d.hook) and nodeOk(parent) then
            d.hookEx, d.hookEy, d.hookEz = getTranslation(d.hook)                       -- hook in the drawbar's frame
            local hx, hy, hz = getWorldTranslation(d.hook)
            d.hx, d.hy, d.hz = worldToLocal(parent, hx, hy, hz)                           -- hook in the parent frame
            local ax, ay, az = getWorldTranslation(d.body)
            d.ax, d.ay, d.az = worldToLocal(parent, ax, ay, az)                           -- axle in the parent frame
        else
            print(string.format("[SPS] WARNING: drawbarSuspension on %s: hookNode '%s' not found - body pitch without the hook lock",
                tostring(entry.vehicle and entry.vehicle.configFileName), tostring(xmlFile:getString(key .. "#hookNode", "attacherJoint"))))
            d.hook = nil
        end
    else
        d.body = nil
    end
    if nodeOk(d.cylinder) and nodeOk(d.punch) and nodeOk(d.punchRef) then
        d.punchX, d.punchY, d.punchZ = getTranslation(d.punch)
        local cx, cy, cz = getWorldTranslation(d.cylinder)
        local rx, ry, rz = getWorldTranslation(d.punchRef)
        d.restLen = MathUtil.vector3Length(rx - cx, ry - cy, rz - cz)
    else
        d.cylinder, d.punch, d.punchRef = nil, nil, nil
    end
    entry.drawbar = d
    print(string.format("[SPS] drawbarSuspension on %s: node '%s'%s, cylinder %s, max %.1f deg",
        tostring(entry.vehicle and entry.vehicle.configFileName), tostring(getName(node)),
        d.body ~= nil and (" (body '" .. tostring(getName(d.body)) .. "' pitches, drawbar fixed)") or " (drawbar rotates)",
        d.cylinder ~= nil and ("'" .. tostring(getName(d.cylinder)) .. "' axis " .. d.axis) or "none", math.deg(d.maxAngle)))
end

-- aim the cylinder at the reference along its configured axis and slide the punch to meet it
local function updateCylinder(d)
    if d.cylinder == nil then return end
    local cx, cy, cz = getWorldTranslation(d.cylinder)
    local rx, ry, rz = getWorldTranslation(d.punchRef)
    local dx, dy, dz = rx - cx, ry - cy, rz - cz
    local len = MathUtil.vector3Length(dx, dy, dz)
    if len < 1e-4 then return end
    dx, dy, dz = dx / len, dy / len, dz / len
    if d.axis == "y" then
        -- local +Y must point at the ref: setDirection fixes Z, so give it a Z perpendicular to the ram and "up" = ram
        local zx, zy, zz = localDirectionToWorld(d.cylinder, 0, 0, 1)
        local dot = zx * dx + zy * dy + zz * dz
        zx, zy, zz = zx - dx * dot, zy - dy * dot, zz - dz * dot
        local zl = MathUtil.vector3Length(zx, zy, zz)
        if zl < 1e-4 then zx, zy, zz = 1, 0, 0; dot = dx; zx, zy, zz = zx - dx * dot, zy - dy * dot, zz - dz * dot; zl = MathUtil.vector3Length(zx, zy, zz) end
        zx, zy, zz = zx / zl, zy / zl, zz / zl
        local lzx, lzy, lzz = worldDirectionToLocal(getParent(d.cylinder), zx, zy, zz)
        local lux, luy, luz = worldDirectionToLocal(getParent(d.cylinder), dx, dy, dz)
        setDirection(d.cylinder, lzx, lzy, lzz, lux, luy, luz)
        setTranslation(d.punch, d.punchX, d.punchY + (len - d.restLen), d.punchZ)
    else
        local lzx, lzy, lzz = worldDirectionToLocal(getParent(d.cylinder), dx, dy, dz)
        local lux, luy, luz = worldDirectionToLocal(getParent(d.cylinder), 0, 1, 0)
        setDirection(d.cylinder, lzx, lzy, lzz, lux, luy, luz)
        setTranslation(d.punch, d.punchX, d.punchY, d.punchZ + (len - d.restLen))
    end
end

function SlurryPipeManager:tickDrawbarSuspension(dt)
    if dt == nil or dt <= 0 then return end
    local s = dt * 0.001
    for _, entry in ipairs(self.registeredVehicles) do
        local d = entry.drawbar
        local vehicle = entry.vehicle
        if d ~= nil and vehicle ~= nil and nodeOk(d.node) then
            local attached = vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() ~= nil
            local target = 0
            if attached then
                local fill = 0
                if vehicle.getFillUnitFillLevelPercentage ~= nil then fill = vehicle:getFillUnitFillLevelPercentage(d.fillUnitIndex) or 0 end
                local scale = d.emptyScale + (d.fullScale - d.emptyScale) * math.max(0, math.min(1, fill))
                -- vertical movement of the pivot (bumps) and fore-aft acceleration (braking dips the nose)
                local _, y, _ = getWorldTranslation(d.node)
                local vy = 0
                if d.lastY ~= nil then vy = (y - d.lastY) / s end
                d.lastY = y
                local speed = (vehicle.lastSpeedReal or 0) * 1000 * (vehicle.movingDirection or 1)   -- m/s, signed
                local ax = 0
                if d.lastSpeed ~= nil then ax = (speed - d.lastSpeed) / s end
                d.lastSpeed = speed
                if math.abs(vy) > 8 then vy = 0 end          -- teleport / reset: ignore the jump
                if math.abs(ax) > 20 then ax = 0 end
                -- angle convention: POSITIVE = dip (standard X rotation takes +Z toward -Y: nose / eye down). The weight
                -- on the hitch dips the nose at a full tank (pushes the punch INTO the cylinder, William 2026-11-03);
                -- the chassis rising against the hitch (vy > 0) and braking (ax < 0) dip it too; the ride rocks about that
                target = d.loadAngle * math.max(0, math.min(1, fill)) + (d.bumpGain * vy - d.accelGain * ax) * scale
                target = math.max(-d.maxAngle, math.min(d.maxAngle + d.loadAngle, target))
            else
                d.lastY, d.lastSpeed = nil, nil
            end
            -- spring-damper toward the target
            local acc = d.spring * (target - d.angle) - d.damper * d.vel
            d.vel = d.vel + acc * s
            d.angle = d.angle + d.vel * s
            local lim = (d.maxAngle + d.loadAngle) * 1.5
            if math.abs(d.angle) > lim then d.angle = (d.angle > 0 and 1 or -1) * lim; d.vel = 0 end
            if math.abs(d.angle) < 1e-5 and math.abs(d.vel) < 1e-5 and target == 0 then d.angle, d.vel = 0, 0 end
            if d.body ~= nil then
                -- body pitches about the AXLE (nose down = negative X); the drawbar swings about the HOOK so its chassis
                -- end lands on the body's pivot, the hook end never moves
                local th = d.angle
                setRotation(d.body, d.bodyRx + th, d.bodyRy, d.bodyRz)
                if d.hook ~= nil then
                    local c, s_ = math.cos(th), math.sin(th)
                    -- the pivot after the body pitch: a + R(th) (p - a)
                    local py, pz = d.restTy - d.ay, d.restTz - d.az
                    local npy, npz = d.ay + (py * c - pz * s_), d.az + (py * s_ + pz * c)
                    -- swing of the beam about the hook: from (p - h) to (p' - h), about X
                    local vy, vz = d.restTy - d.hy, d.restTz - d.hz
                    local wy, wz = npy - d.hy, npz - d.hz
                    local phi = math.atan2(vy, vz) - math.atan2(wy, wz)   -- R_x(phi) lowers atan2(y, z) by phi
                    local cp, sp = math.cos(phi), math.sin(phi)
                    -- drawbar origin = hook - R(phi) * hookOffset  (hook offset lives in the drawbar's own frame)
                    local ey, ez = d.hookEy * cp - d.hookEz * sp, d.hookEy * sp + d.hookEz * cp
                    setRotation(d.node, d.restRx + phi, d.restRy, d.restRz)
                    setTranslation(d.node, d.hx - d.hookEx, d.hy - ey, d.hz - ez)
                end
            else
                setRotation(d.node, d.restRx + d.angle, d.restRy, d.restRz)
            end
            updateCylinder(d)
        end
    end
end
