-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.0

-- SPSSprayerPipeVisual.lua
-- FS25_SlurryPipeSystem

SPSSprayerPipeVisual = {}
SPSSprayerPipeVisual.__index = SPSSprayerPipeVisual

-- [SPS] Per-file debug toggle. Set true to enable [SPS SSPV] trace logging.
-- Hard failure prints (load ERROR, createPipe ERROR) remain unconditional — they
-- signal genuine problems, not trace noise.
local DEBUG = false
local function log(fmt, ...)
    if not DEBUG then return end
    if select("#", ...) > 0 then
        print("[SPS SSPV] " .. string.format(fmt, ...))
    else
        print("[SPS SSPV] " .. tostring(fmt))
    end
end

-- i3d layout (sprayerPipe = pipeRoot, 33 direct children, indices 0-32):
--   child 0      = hose1                 (skinned mesh, Bone1-Bone16 bound)
--   child 1      = hose2                 (skinned mesh, Bone17-Bone32 bound)
--   child 2      = sprayerStartConnector → child 0=sprayerStartTarget, child 1=Bone1
--   child 3      = sprayerEndConnector   → child 0=sprayerEndTarget,   child 1=Bone32
--   child 4..18  = Bone2..Bone16         (direct children of pipeRoot)
--   Bone17       = child 0 of Bone16     (NESTED — not a direct pipeRoot child)
--   child 19..32 = Bone18..Bone31        (direct children of pipeRoot)
--
-- Interior bones driven by bezier: Bone2..Bone31 (30 total).
-- Bone17 must be fetched as getChildAt(Bone16, 0) — not from pipeRoot directly.

SPSSprayerPipeVisual.NUM_INTERIOR_BONES = 29
SPSSprayerPipeVisual.TENSION_FACTOR     = 0.4
SPSSprayerPipeVisual.SAG_FACTOR         = 0.08

function SPSSprayerPipeVisual.new(modDirectory)
    local self = setmetatable({}, SPSSprayerPipeVisual)
    self.modDirectory = modDirectory
    self._isLoaded    = false
    return self
end

function SPSSprayerPipeVisual:load()
    local pipePath = self.modDirectory .. "i3d/pipes/sprayerPipe.i3d"
    if fileExists(pipePath) then
        self._isLoaded = true
        log("load: OK %s", pipePath)
    else
        print("[SPS SSPV] load: ERROR not found " .. pipePath)
    end
end

function SPSSprayerPipeVisual:delete()
    self._isLoaded = false
end

function SPSSprayerPipeVisual:isReady()
    return self._isLoaded
end

-- ---------------------------------------------------------------------------
-- createPipe
-- nodeA: source coupler mountNode  — pipeRoot snaps here.
-- nodeB: destination coupler mountNode — endConnectors snaps here.
-- ---------------------------------------------------------------------------
function SPSSprayerPipeVisual:createPipe(nodeA, nodeB)
    if not self._isLoaded then
        print("[SPS SSPV] createPipe: ERROR not loaded")
        return nil
    end

    local pipePath = self.modDirectory .. "i3d/pipes/sprayerPipe.i3d"
    local i3dRoot = loadI3DFile(pipePath)
    if i3dRoot == nil or i3dRoot == 0 then
        print("[SPS SSPV] createPipe: ERROR loadI3DFile failed")
        return nil
    end
    link(getRootNode(), i3dRoot)

    local pipeRoot = getChildAt(i3dRoot, 0)
    if pipeRoot == nil or pipeRoot == 0 then
        print("[SPS SSPV] createPipe: ERROR pipeRoot not found")
        delete(i3dRoot)
        return nil
    end

    local startConnectors = getChildAt(pipeRoot, 2)
    local endConnectors   = getChildAt(pipeRoot, 3)
    if startConnectors == nil or startConnectors == 0
    or endConnectors   == nil or endConnectors   == 0 then
        print("[SPS SSPV] createPipe: ERROR connector nodes not found")
        delete(i3dRoot)
        return nil
    end

    -- Bone1 and Bone32 are the bezier endpoints — they follow their parent
    -- connectors and their world positions are read after the parent snaps.
    local bone1  = getChildAt(startConnectors, 1)
    local bone32 = getChildAt(endConnectors, 1)
    if bone1 == nil or bone1 == 0 or bone32 == nil or bone32 == 0 then
        print("[SPS SSPV] createPipe: ERROR Bone1 or Bone32 not found")
        delete(i3dRoot)
        return nil
    end

    -- Interior bones driven by bezier:
    -- Bone2..Bone16 at pipeRoot children 4..18 (15 bones)
    -- Bone18..Bone31 at pipeRoot children 19..32 (14 bones)
    -- Bone17 is a child of Bone16 and moves with it automatically — not driven here.
    local bones = {}
    for i = 1, 15 do
        local boneNode = getChildAt(pipeRoot, 3 + i)  -- children 4..18
        if boneNode == nil or boneNode == 0 then
            print("[SPS SSPV] createPipe: ERROR Bone" .. (i + 1) .. " not found at pipeRoot child " .. (3 + i))
            delete(i3dRoot)
            return nil
        end
        bones[i] = boneNode
    end
    for i = 1, 14 do
        local boneNode = getChildAt(pipeRoot, 18 + i)  -- children 19..32
        if boneNode == nil or boneNode == 0 then
            print("[SPS SSPV] createPipe: ERROR Bone" .. (17 + i) .. " not found at pipeRoot child " .. (18 + i))
            delete(i3dRoot)
            return nil
        end
        bones[15 + i] = boneNode  -- slots 16..29
    end

    local inst = {
        i3dRoot         = i3dRoot,
        pipeRoot        = pipeRoot,
        startConnectors = startConnectors,
        endConnectors   = endConnectors,
        bone1           = bone1,
        bone32          = bone32,
        bones           = bones,
        nodeA           = nodeA,
        nodeB           = nodeB,
    }

    -- Link pipeRoot to nodeA in local space — pipe start follows source coupler.
    link(nodeA, pipeRoot)
    setTranslation(pipeRoot, 0, 0, 0)
    setRotation(pipeRoot, 0, 0, 0)

    -- Link endConnectors to nodeB using sprayerEndTarget (child 0) as the snap point.
    -- sprayerEndTarget is the physical connection tip — offset endConnectors so it
    -- lands at nodeB, not the endConnectors origin.
    local sprayerEndTarget = getChildAt(endConnectors, 0)
    local etx, ety, etz   = getTranslation(sprayerEndTarget)
    link(nodeB, endConnectors)
    setTranslation(endConnectors, -etx, -ety, -etz)
    setRotation(endConnectors, 0, 0, 0)

    self:updatePipe(inst)
    log("createPipe: OK nodeA=%s nodeB=%s", tostring(nodeA), tostring(nodeB))
    return inst
end

-- ---------------------------------------------------------------------------
-- updatePipe
-- Called every tick. pipeRoot and endConnectors are linked to their
-- respective nodes in local space (done in createPipe) so they follow
-- automatically. Only the bezier bones need updating each tick.
-- ---------------------------------------------------------------------------
function SPSSprayerPipeVisual:updatePipe(inst)
    if inst == nil then return end

    local nodeA = inst.nodeA
    local nodeB = inst.nodeB
    if nodeA == nil or nodeB == nil then return end
    if not entityExists(nodeA) or not entityExists(nodeB) then return end

    local ax, ay, az    = getWorldTranslation(nodeA)
    local bx, by, bz    = getWorldTranslation(nodeB)
    local arx, ary, arz = getWorldRotation(nodeA)
    local brx, bry, brz = getWorldRotation(nodeB)

    if ax == nil or bx == nil or arx == nil or brx == nil then return end

    -- Read Bone1 and Bone32 world positions — these are the true bezier
    -- endpoints and match the skin bind positions exactly.
    if not entityExists(inst.bone1) or not entityExists(inst.bone32) then return end
    local p0x, p0y, p0z = getWorldTranslation(inst.bone1)
    local p3x, p3y, p3z = getWorldTranslation(inst.bone32)

    local dx   = p3x - p0x
    local dy   = p3y - p0y
    local dz   = p3z - p0z
    local span = math.sqrt(dx*dx + dy*dy + dz*dz)
    if span < 0.001 then return end

    local adx, ady, adz = localDirectionToWorld(nodeA, 0, 0, 1)
    local bdx, bdy, bdz = localDirectionToWorld(nodeB, 0, 0, 1)

    local tension = span * SPSSprayerPipeVisual.TENSION_FACTOR
    local sag     = span * SPSSprayerPipeVisual.SAG_FACTOR

    local p1x = p0x + adx * tension
    local p1y = p0y + ady * tension - sag
    local p1z = p0z + adz * tension

    local p2x = p3x - bdx * tension
    local p2y = p3y - bdy * tension - sag
    local p2z = p3z - bdz * tension

    local NUM   = SPSSprayerPipeVisual.NUM_INTERIOR_BONES
    local TOTAL = NUM + 1
    for i = 1, NUM do
        local t = i / TOTAL
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

        -- Terrain clamp: lift bone if below terrain + pipe radius offset
        if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
            local ty = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, px, 0, pz)
            local minY = ty + SPSSprayerPipeVisual.SAG_FACTOR
            if py < minY then
                py = minY
            end
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
function SPSSprayerPipeVisual:destroyPipe(inst)
    if inst == nil then return end
    log("destroyPipe: tearing down instance")

    -- During savegame quit/delete, FS25 may already have deleted linked parent
    -- nodes. Never link/delete a node unless the entity still exists.
    local i3dRootExists = inst.i3dRoot ~= nil and inst.i3dRoot ~= 0 and entityExists(inst.i3dRoot)

    if inst.pipeRoot ~= nil and inst.pipeRoot ~= 0 and entityExists(inst.pipeRoot) then
        link(getRootNode(), inst.pipeRoot)
    end

    if inst.endConnectors ~= nil and inst.endConnectors ~= 0 and entityExists(inst.endConnectors) then
        link(getRootNode(), inst.endConnectors)
    end

    if i3dRootExists then
        delete(inst.i3dRoot)
    end

    inst.i3dRoot = nil
    inst.pipeRoot = nil
    inst.startConnectors = nil
    inst.endConnectors = nil
    inst.bone1 = nil
    inst.bone32 = nil
    inst.bones = nil
end