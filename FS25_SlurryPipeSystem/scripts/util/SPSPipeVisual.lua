-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.4

-- SPSPipeVisual.lua
-- FS25_SlurryPipeSystem

SPSPipeVisual = {}
SPSPipeVisual.__index = SPSPipeVisual

-- i3d layout (slurryPipe = pipeRoot):
--   child 0  = hose                  (skinned mesh, 16 skin-bound bones)
--   child 1  = startConnectors       → child 0=female01, 1=male01,
--                                       2=detectionNode01, 3=Bone1
--   child 2  = endConnectors         → rotation (0,180,0) — blue arrow OUT
--                                       child 0=female02, 1=male02,
--                                       2=detectionNode04, 3=Bone16,
--                                       4=endFloorLevel, 5=nextPipeTarget
--   child 3..16 = Bone2..Bone15      (14 interior bones, flat children)
--
-- Bezier runs from Bone1's world position to Bone16's world position.
-- These are read after pipeRoot and endConnectors are snapped, so they
-- already reflect the correct world positions. Interior bones sample evenly
-- between them, matching the skin bind spacing exactly.

SPSPipeVisual.NUM_INTERIOR_BONES = 14
SPSPipeVisual.TENSION_FACTOR     = 0.4
SPSPipeVisual.SAG_FACTOR         = 0.08

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
        print("[SPS SPPV] load: OK " .. pipePath)
    else
        print("[SPS SPPV] load: ERROR not found " .. pipePath)
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
-- nodeA: source coupler mountNode  — pipeRoot snaps here.
-- nodeB: destination coupler mountNode — endConnectors snaps here.
-- startConnectorType: "male" (default) or "female"
-- endConnectorType:   "male" or "female" (default)
-- ---------------------------------------------------------------------------
function SPSPipeVisual:createPipe(nodeA, nodeB, startConnectorType, endConnectorType, endFlip, startFlip)
    if not self._isLoaded then
        print("[SPS SPPV] createPipe: ERROR not loaded")
        return nil
    end

    local pipePath = self.modDirectory .. "i3d/pipes/slurryPipe.i3d"
    local i3dRoot = loadI3DFile(pipePath)
    if i3dRoot == nil or i3dRoot == 0 then
        print("[SPS SPPV] createPipe: ERROR loadI3DFile failed")
        return nil
    end
    link(getRootNode(), i3dRoot)

    local pipeRoot = getChildAt(i3dRoot, 0)
    if pipeRoot == nil or pipeRoot == 0 then
        print("[SPS SPPV] createPipe: ERROR pipeRoot not found")
        delete(i3dRoot)
        return nil
    end

    local startConnectors = getChildAt(pipeRoot, 1)
    local endConnectors   = getChildAt(pipeRoot, 2)
    if startConnectors == nil or startConnectors == 0
    or endConnectors   == nil or endConnectors   == 0 then
        print("[SPS SPPV] createPipe: ERROR connector nodes not found")
        delete(i3dRoot)
        return nil
    end

    -- Bone1 and Bone16 are the bezier endpoints — they follow their parent
    -- connectors and their world positions are read after the parent snaps.
    local bone1  = getChildAt(startConnectors, 3)
    local bone16 = getChildAt(endConnectors, 3)
    if bone1 == nil or bone1 == 0 or bone16 == nil or bone16 == 0 then
        print("[SPS SPPV] createPipe: ERROR Bone1 or Bone16 not found")
        delete(i3dRoot)
        return nil
    end

    local nextPipeTarget = nil  -- removed from i3d

    -- Interior bones: Bone2..Bone15 at pipeRoot children 3..16.
    local bones = {}
    for i = 1, SPSPipeVisual.NUM_INTERIOR_BONES do
        local boneNode = getChildAt(pipeRoot, 2 + i)
        if boneNode == nil or boneNode == 0 then
            print("[SPS SPPV] createPipe: ERROR interior bone " .. i .. " not found at pipeRoot child " .. (2+i))
            delete(i3dRoot)
            return nil
        end
        bones[i] = boneNode
    end

    -- Pipe created successfully (detailed node ID logging removed for cleaner logs)

    -- Start connector visibility: female01 (child 0) or male01 (child 1)
    local femaleStart = getChildAt(startConnectors, 0)
    local maleStart   = getChildAt(startConnectors, 1)
    if startConnectorType == "female" then
        if femaleStart ~= nil and femaleStart ~= 0 then setVisibility(femaleStart, true) end
        if maleStart   ~= nil and maleStart   ~= 0 then setVisibility(maleStart, false) end
    else
        if femaleStart ~= nil and femaleStart ~= 0 then setVisibility(femaleStart, false) end
        if maleStart   ~= nil and maleStart   ~= 0 then setVisibility(maleStart, true) end
    end

    -- End connector visibility: female02 (child 0) or male02 (child 1)
    local femaleEnd = getChildAt(endConnectors, 0)
    local maleEnd   = getChildAt(endConnectors, 1)
    if endConnectorType == "male" then
        if femaleEnd ~= nil and femaleEnd ~= 0 then setVisibility(femaleEnd, false) end
        if maleEnd   ~= nil and maleEnd   ~= 0 then setVisibility(maleEnd, true) end
    else
        if femaleEnd ~= nil and femaleEnd ~= 0 then setVisibility(femaleEnd, true) end
        if maleEnd   ~= nil and maleEnd   ~= 0 then setVisibility(maleEnd, false) end
    end

    local inst = {
        i3dRoot         = i3dRoot,
        pipeRoot        = pipeRoot,
        startConnectors = startConnectors,
        endConnectors   = endConnectors,
        bone1           = bone1,
        bone16          = bone16,
        nextPipeTarget  = nextPipeTarget,
        bones           = bones,
        nodeA           = nodeA,
        nodeB           = nodeB,
        _hasLogged      = false,
    }

    -- [SPS TRACE] log the nodes this pipe is being built on, BEFORE linking
    local function traceN(label, n)
        if n == nil or n == 0 or not entityExists(n) then
            --print("[SPS TRACE]   createPipe " .. label .. " = nil/invalid"); return
        end
        local x, y, z = getWorldTranslation(n)
        local rx, ry, rz = getWorldRotation(n)
        --print(string.format("[SPS TRACE]   createPipe %s id=%s name='%s' pos=(%.3f,%.3f,%.3f) rotY=%.1fdeg",
            --label, tostring(n), tostring(getName(n)), x or 0, y or 0, z or 0, math.deg(ry or 0)))
    end
    --print("[SPS TRACE] ===== createPipe =====")
    traceN("nodeA(pipe START -> pipeRoot)", nodeA)
    traceN("nodeB(pipe END   -> endConnectors)", nodeB)

    -- Link pipeRoot to nodeA in local space — pipe start follows source coupler.
    link(nodeA, pipeRoot)
    setTranslation(pipeRoot, 0, 0, 0)
    setRotation(pipeRoot, 0, 0, 0)

    -- Link endConnectors to nodeB in local space — pipe end follows target coupler.
    link(nodeB, endConnectors)
    setTranslation(endConnectors, 0, 0, 0)
    setRotation(endConnectors, 0, 0, 0)

    -- [SPS TRACE] resulting world orientation of each pipe end after snapping.
    -- The -Z of each end is the bezier tangent direction; this is what determines
    -- which way the connector "faces".
    do
        local function traceDir(label, n)
            if n == nil or n == 0 or not entityExists(n) then return end
            local dx, dy, dz = localDirectionToWorld(n, 0, 0, -1)
            local rx, ry, rz = getWorldRotation(n)
            --print(string.format("[SPS TRACE]   createPipe %s -Z dir=(%.2f,%.2f,%.2f) rotY=%.1fdeg",
                --label, dx or 0, dy or 0, dz or 0, math.deg(ry or 0)))
        end
        traceDir("pipeRoot(START) after snap", pipeRoot)
        traceDir("endConnectors(END) after snap", endConnectors)
    end

    self:updatePipe(inst)
    return inst
end

-- ---------------------------------------------------------------------------
-- updatePipe
-- Called every tick. pipeRoot and endConnectors are linked to their
-- respective nodes in local space (done in createPipe) so they follow
-- automatically. Only the bezier bones need updating each tick.
-- ---------------------------------------------------------------------------
function SPSPipeVisual:updatePipe(inst)
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

    -- 3) Read Bone1 and Bone16 world positions — these are the true bezier
    --    endpoints and match the skin bind positions exactly.
    if not entityExists(inst.bone1) or not entityExists(inst.bone16) then return end
    local p0x, p0y, p0z = getWorldTranslation(inst.bone1)
    local p3x, p3y, p3z = getWorldTranslation(inst.bone16)

    local dx   = p3x - p0x
    local dy   = p3y - p0y
    local dz   = p3z - p0z
    local span = math.sqrt(dx*dx + dy*dy + dz*dz)
    if span < 0.001 then return end

    local adx, ady, adz = localDirectionToWorld(nodeA, 0, 0, -1)
    local bdx, bdy, bdz = localDirectionToWorld(nodeB, 0, 0, -1)

    local tension = span * SPSPipeVisual.TENSION_FACTOR
    local sag     = span * SPSPipeVisual.SAG_FACTOR

    local p1x = p0x + adx * tension
    local p1y = p0y + ady * tension - sag
    local p1z = p0z + adz * tension

    local p2x = p3x - bdx * tension
    local p2y = p3y - bdy * tension - sag
    local p2z = p3z - bdz * tension

    -- Bezier bone calculation (detailed logging removed for cleaner logs)

    local NUM   = SPSPipeVisual.NUM_INTERIOR_BONES
    local TOTAL = NUM + 1
    for i = 1, NUM do
        local t   = i / TOTAL
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
            local minY = ty + SPSPipeVisual.SAG_FACTOR
            if py < minY then
                py = minY
            end
        end

        local ry = math.atan2(-tdx, -tdz)
        local rx =  math.atan2( tdy, math.sqrt(tdx*tdx + tdz*tdz))

        setWorldTranslation(inst.bones[i], px, py, pz)
        setWorldRotation(inst.bones[i], rx, ry, 0)
    end
end

-- ---------------------------------------------------------------------------
-- applyColor
-- ---------------------------------------------------------------------------
function SPSPipeVisual:applyColor(inst, r, g, b)
    if inst == nil or inst.pipeRoot == nil then
        print("[SPS SPPV] applyColor: ERROR inst or pipeRoot nil")
        return
    end
    local hoseNode = getChildAt(inst.pipeRoot, 0)
    if hoseNode ~= nil and hoseNode ~= 0 then
        setShaderParameter(hoseNode, "colorScale", r, g, b, 0, false)
    else
        print("[SPS SPPV] applyColor: ERROR hoseNode nil")
    end
end

-- ---------------------------------------------------------------------------
-- destroyPipe
-- ---------------------------------------------------------------------------
function SPSPipeVisual:destroyPipe(inst)
    if inst == nil then return end

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
    inst.bone16 = nil
    inst.bones = nil
end