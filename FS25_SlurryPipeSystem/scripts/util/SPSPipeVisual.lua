-- SPSPipeVisual.lua
-- FS25_SlurryPipeSystem
--
-- Bezier pipe visual between two coupling mount nodes.
-- No physics -- pure visual positioning.
--
-- i3d structure (pipeRoot children) — matches SPSPipeChain layout:
--   0  = hose (skinned mesh)
--   1  = slurryPipeConnector — IS the start anchor, snapped to nodeA
--          child 0 = componentJoint1 > Bone1
--          child 1 = componentJoint2 > Bone2
--          child 2 = bezierStart (unused)
--   2-14 = componentJoint3-15
--          child 0 = Bone3-Bone15
--   15 = endConnectors — IS the end anchor, snapped to nodeB
--          child 0 = slurryPipeConnectorMale  (hidden for F-F connection)
--          child 1 = slurryPipeConnectorFemale
--          child 2 = componentJoint16 > Bone16
--          child 3 = componentJoint17 > Bone17
--          child 4 = bezierEnd (unused)
--          child 5 = detectionNode01 (unused)
--          child 6 = endFloorLevel (unused)

SPSPipeVisual = {}
SPSPipeVisual.__index = SPSPipeVisual

SPSPipeVisual.NUM_BONES      = 17
SPSPipeVisual.TENSION_FACTOR = 0.4
SPSPipeVisual.SAG_FACTOR     = 0.04

function SPSPipeVisual.new(modDirectory)
    local self = setmetatable({}, SPSPipeVisual)
    self.modDirectory = modDirectory
    self._isLoaded    = false
    return self
end

function SPSPipeVisual:load()
    local pipePath = self.modDirectory .. "i3d/pipes/slurryPipe.i3d"
    if fileExists(pipePath) then
        self._isLoaded = true
        print("[SPS] SPSPipeVisual: ready")
    else
        print("[SPS] SPSPipeVisual: slurryPipe.i3d not found at " .. pipePath)
    end
end

function SPSPipeVisual:delete()
    self._isLoaded = false
end

function SPSPipeVisual:isReady()
    return self._isLoaded
end

-- ---------------------------------------------------------------------------
-- createPipe
-- nodeA and nodeB are world nodes — their position and rotation drive the bezier.
-- ---------------------------------------------------------------------------
function SPSPipeVisual:createPipe(nodeA, nodeB)
    if not self._isLoaded then return nil end

    local pipePath = self.modDirectory .. "i3d/pipes/slurryPipe.i3d"
    local i3dRoot = loadI3DFile(pipePath)
    if i3dRoot == nil or i3dRoot == 0 then
        print("[SPS] SPSPipeVisual:createPipe - loadI3DFile failed")
        return nil
    end
    link(getRootNode(), i3dRoot)

    local pipeRoot = getChildAt(i3dRoot, 0)

    -- Start anchor: slurryPipeConnector (pipeRoot child 1), snapped to nodeA
    local connectorStart = getChildAt(pipeRoot, 1)

    -- Bone1: connectorStart child 0 child 0
    -- Bone2: connectorStart child 1 child 0
    local bones = {}
    bones[1] = getChildAt(getChildAt(connectorStart, 0), 0)
    bones[2] = getChildAt(getChildAt(connectorStart, 1), 0)

    -- Bones 3-15: pipeRoot children 2-14, each child 0
    for i = 3, 15 do
        local cj = getChildAt(pipeRoot, i - 1)
        bones[i] = getChildAt(cj, 0)
        if bones[i] == nil or bones[i] == 0 then
            print("[SPS] SPSPipeVisual:createPipe - bone " .. i .. " not found")
            delete(i3dRoot)
            return nil
        end
    end

    -- End anchor: endConnectors (pipeRoot child 15), snapped to nodeB
    local connectorEnd = getChildAt(pipeRoot, 15)

    -- Bone16: endConnectors child 2 child 0
    -- Bone17: endConnectors child 3 child 0
    bones[16] = getChildAt(getChildAt(connectorEnd, 2), 0)
    bones[17] = getChildAt(getChildAt(connectorEnd, 3), 0)

    if bones[1]  == nil or bones[1]  == 0
    or bones[17] == nil or bones[17] == 0 then
        print("[SPS] SPSPipeVisual:createPipe - Bone1 or Bone17 not found")
        delete(i3dRoot)
        return nil
    end

    -- F-F connection: hide male connector (endConnectors child 0)
    local maleConn = getChildAt(connectorEnd, 0)
    if maleConn ~= nil and maleConn ~= 0 then
        setVisibility(maleConn, false)
    end

    local inst = {
        i3dRoot        = i3dRoot,
        pipeRoot       = pipeRoot,
        connectorStart = connectorStart,
        connectorEnd   = connectorEnd,
        bones          = bones,
        nodeA          = nodeA,
        nodeB          = nodeB,
    }

    self:updatePipe(inst)
    print("[SPS] SPSPipeVisual: pipe created")
    return inst
end

-- ---------------------------------------------------------------------------
-- updatePipe
-- Called every tick. Snaps connectorStart to nodeA, connectorEnd to nodeB,
-- then positions all 17 bones along the bezier curve.
-- ---------------------------------------------------------------------------
function SPSPipeVisual:updatePipe(inst)
    if inst == nil then return end

    local nodeA = inst.nodeA
    local nodeB = inst.nodeB
    if nodeA == nil or nodeB == nil then return end

    local ax, ay, az    = getWorldTranslation(nodeA)
    local bx, by, bz    = getWorldTranslation(nodeB)
    local arx, ary, arz = getWorldRotation(nodeA)
    local brx, bry, brz = getWorldRotation(nodeB)

    setWorldTranslation(inst.connectorStart, ax, ay, az)
    setWorldRotation(inst.connectorStart, arx, ary, arz)

    setWorldTranslation(inst.connectorEnd, bx, by, bz)
    setWorldRotation(inst.connectorEnd, brx, bry, brz)

    local dx   = bx - ax
    local dy   = by - ay
    local dz   = bz - az
    local span = math.sqrt(dx*dx + dy*dy + dz*dz)
    if span < 0.001 then return end

    local adx, ady, adz = localDirectionToWorld(nodeA, 0, 0, -1)
    local bdx, bdy, bdz = localDirectionToWorld(nodeB, 0, 0, -1)

    local tension = span * SPSPipeVisual.TENSION_FACTOR
    local sag     = span * SPSPipeVisual.SAG_FACTOR

    local p0x, p0y, p0z = ax, ay, az
    local p3x, p3y, p3z = bx, by, bz
    local p1x = p0x + adx * tension
    local p1y = p0y + ady * tension - sag
    local p1z = p0z + adz * tension
    local p2x = p3x + bdx * tension
    local p2y = p3y + bdy * tension - sag
    local p2z = p3z + bdz * tension

    setWorldTranslation(inst.pipeRoot, (ax+bx)*0.5, (ay+by)*0.5, (az+bz)*0.5)

    local NUM = SPSPipeVisual.NUM_BONES

    for i = 1, NUM do
        local t   = (i - 1) / (NUM - 1)
        local mt  = 1 - t
        local mt2 = mt * mt
        local mt3 = mt2 * mt
        local t2  = t * t
        local t3  = t2 * t

        local px = mt3*p0x + 3*mt2*t*p1x + 3*mt*t2*p2x + t3*p3x
        local py = mt3*p0y + 3*mt2*t*p1y + 3*mt*t2*p2y + t3*p3y
        local pz = mt3*p0z + 3*mt2*t*p1z + 3*mt*t2*p2z + t3*p3z

        local tdx = 3*mt2*(p1x-p0x) + 6*mt*t*(p2x-p1x) + 3*t2*(p3x-p2x)
        local tdy = 3*mt2*(p1y-p0y) + 6*mt*t*(p2y-p1y) + 3*t2*(p3y-p2y)
        local tdz = 3*mt2*(p1z-p0z) + 6*mt*t*(p2z-p1z) + 3*t2*(p3z-p2z)

        local tlen = math.sqrt(tdx*tdx + tdy*tdy + tdz*tdz)
        if tlen > 0.0001 then
            tdx = tdx / tlen
            tdy = tdy / tlen
            tdz = tdz / tlen
        end

        local ry = math.atan2(tdx, tdz)
        local rx = -math.atan2(tdy, math.sqrt(tdx*tdx + tdz*tdz))

        setWorldTranslation(inst.bones[i], px, py, pz)
        setWorldRotation(inst.bones[i], rx, ry, 0)
    end
end

-- ---------------------------------------------------------------------------
-- destroyPipe
-- ---------------------------------------------------------------------------
function SPSPipeVisual:destroyPipe(inst)
    if inst == nil then return end
    if inst.i3dRoot ~= nil and inst.i3dRoot ~= 0 then
        delete(inst.i3dRoot)
        inst.i3dRoot = nil
    end
    print("[SPS] SPSPipeVisual: pipe destroyed")
end