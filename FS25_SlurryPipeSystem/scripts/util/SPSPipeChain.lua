-- SPSPipeChain.lua
-- FS25_SlurryPipeSystem
--
-- Pipe laying system. Each segment loads slurryPipe.i3d.
-- pipeRoot snaps to previous endConnectors at 0 0 0.
-- For chained segments startLaying derives position and rotation from previous
-- segment geometry — new pipe always departs straight out of last connector.
-- While live: endConnectors tracks player direction at PIPE_LENGTH distance.
--   Holds startRY direction until player moves beyond PLAYER_OFFSET.
-- On lock: endConnectors frozen, detection nodes active for arc detection.
-- Docking station: endConnectors of last segment is moved to dockingTarget
--   world position so the segment pipe reaches the DS inlet directly.
--   Original endConnectors position is saved and restored on DS removal.
--
-- i3d node indices (slurryPipe children):
--   0  = hose (skinned mesh)
--   1  = slurryPipeConnector
--          child 0 = componentJoint1 > Bone1
--          child 1 = componentJoint2 > Bone2
--          child 2 = bezierStart              (not driven)
--   2-14 = componentJoint3-15 > Bone3-15      (bezier driven, midBones[1-13])
--   15 = endConnectors
--          child 0 = slurryPipeConnectorMale
--          child 1 = slurryPipeConnectorFemale
--          child 2 = componentJoint16 > Bone16
--          child 3 = componentJoint17 > Bone17
--          child 4 = bezierEnd                (not driven)
--          child 5 = detectionNode01
--                      child 0 = detectionNode02
--                      child 1 = detectionNode03
--          child 6 = endFloorLevel

SPSPipeChain = {}
SPSPipeChain.__index = SPSPipeChain

SPSPipeChain.PIPE_LENGTH   = 4.0
SPSPipeChain.PLAYER_OFFSET = 0.75

function SPSPipeChain.new(anchorCoupling, modDirectory)
    local self            = setmetatable({}, SPSPipeChain)
    self.anchorCoupling   = anchorCoupling
    self.modDirectory     = modDirectory
    self.segments         = {}
    self.liveSegment      = nil
    self.dockingStation   = nil
    return self
end

function SPSPipeChain:delete()
    self:_removeDockingStation()
    if self.liveSegment ~= nil then
        self:_destroySegmentNodes(self.liveSegment)
        self.liveSegment = nil
    end
    for i = #self.segments, 1, -1 do
        self:_destroySegmentNodes(self.segments[i])
    end
    self.segments = {}
end

-- ---------------------------------------------------------------------------
-- Start laying a new live pipe.
-- First pipe uses caller sx/sy/sz/sry (anchorCoupling position).
-- Chained pipes derive position and rotation from previous segment geometry.
-- ---------------------------------------------------------------------------
function SPSPipeChain:startLaying(sx, sy, sz, sry)
    if self.liveSegment ~= nil then return end

    if #self.segments > 0 then
        local prevSeg     = self.segments[#self.segments]
        local prx, _, prz = getWorldTranslation(prevSeg.pipeRoot)
        sx, sy, sz        = getWorldTranslation(prevSeg.endConnectors)
        local ddx  = sx - prx
        local ddz  = sz - prz
        local dlen = math.sqrt(ddx * ddx + ddz * ddz)
        if dlen > 0.01 then
            sry = math.atan2(-ddx / dlen, -ddz / dlen)
        end
    end

    local seg = self:_loadPipe(sx, sy, sz, sry or 0)
    if seg == nil then return end
    self.liveSegment = seg
    print("[SPS] SPSPipeChain: started laying")
end

-- ---------------------------------------------------------------------------
-- Lock the current live pipe in place
-- ---------------------------------------------------------------------------
function SPSPipeChain:lockLivePipe()
    if self.liveSegment == nil then return end
    local seg = self.liveSegment
    self.liveSegment = nil
    table.insert(self.segments, seg)

    if g_slurryPipeManager ~= nil then
        table.insert(g_slurryPipeManager.chainTerminusEntries, seg.chainCoupling)
    end

    local activatable = SPSChainActivatable.new(self, #self.segments)
    g_currentMission.activatableObjectsSystem:addActivatable(activatable)
    seg.activatable = activatable

    print("[SPS] SPSPipeChain: locked segment " .. #self.segments)
end

-- ---------------------------------------------------------------------------
-- Cancel (remove) the current live pipe without locking
-- ---------------------------------------------------------------------------
function SPSPipeChain:cancelLivePipe()
    if self.liveSegment == nil then return end
    self:_destroySegmentNodes(self.liveSegment)
    self.liveSegment = nil
    print("[SPS] SPSPipeChain: cancelled live pipe")
end

-- ---------------------------------------------------------------------------
-- Remove locked segments from fromIndex to end
-- ---------------------------------------------------------------------------
function SPSPipeChain:removeFromIndex(fromIndex)
    if fromIndex < 1 then fromIndex = 1 end
    if self.dockingStation ~= nil then self:_removeDockingStation() end
    for i = #self.segments, fromIndex, -1 do
        self:_destroySegmentNodes(self.segments[i])
        table.remove(self.segments, i)
    end
    print("[SPS] SPSPipeChain: removed segments from index " .. fromIndex)
end

-- ---------------------------------------------------------------------------
-- Load a pipe i3d, link to world root, position at startX/Y/Z with startRY
-- ---------------------------------------------------------------------------
function SPSPipeChain:_loadPipe(startX, startY, startZ, startRY)
    local pipePath = self.modDirectory .. "i3d/pipes/slurryPipe.i3d"
    local i3dRoot  = loadI3DFile(pipePath)
    if i3dRoot == nil or i3dRoot == 0 then
        print("[SPS] SPSPipeChain: failed to load slurryPipe.i3d")
        return nil
    end

    local pipeRoot      = getChildAt(i3dRoot, 0)
    local endConnectors = getChildAt(pipeRoot, 15)
    local detNode01     = getChildAt(endConnectors, 5)
    local endFloorLevel = getChildAt(endConnectors, 6)
    local maleConn      = getChildAt(endConnectors, 0)
    local femaleConn    = getChildAt(endConnectors, 1)

    local midBones = {}
    for i = 2, 14 do
        local cj   = getChildAt(pipeRoot, i)
        local bone = getChildAt(cj, 0)
        midBones[i - 1] = bone
    end

    link(getRootNode(), pipeRoot)
    setWorldTranslation(pipeRoot, startX, startY, startZ)
    setWorldRotation(pipeRoot, 0, startRY, 0)
    delete(i3dRoot)

    if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn,   true)  end
    if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, false) end

    local chainCoupling = {
        id                       = #self.segments + 1,
        mountNode                = detNode01,
        arcNode                  = nil,
        isConnected              = false,
        valveOpen                = false,
        connectedTarget          = nil,
        connectedPartnerCoupling = nil,
        pipeId                   = nil,
        isChainTerminus          = true,
        chain                    = self,
        segmentIndex             = #self.segments + 1,
        sourceEntry              = self.anchorCoupling.sourceEntry,
        placeable                = self.anchorCoupling.placeable,
    }

    return {
        pipeRoot      = pipeRoot,
        endConnectors = endConnectors,
        detNode01     = detNode01,
        endFloorLevel = endFloorLevel,
        midBones      = midBones,
        chainCoupling = chainCoupling,
        activatable   = nil,
        startX        = startX,
        startY        = startY,
        startZ        = startZ,
        startRY       = startRY,
    }
end

-- ---------------------------------------------------------------------------
-- Update — called each tick from manager
-- ---------------------------------------------------------------------------
function SPSPipeChain:update(dt)
    if self.liveSegment == nil then return end
    if g_localPlayer == nil then return end

    local seg = self.liveSegment

    local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
    local sx, sy, sz = seg.startX, seg.startY, seg.startZ
    local dx = px - sx
    local dz = pz - sz
    local dist = math.sqrt(dx * dx + dz * dz)

    local dirX, dirZ
    if dist > SPSPipeChain.PLAYER_OFFSET then
        dirX = dx / dist
        dirZ = dz / dist
    else
        local ry = seg.startRY or 0
        dirX = -math.sin(ry)
        dirZ = -math.cos(ry)
    end

    local ex = sx + dirX * SPSPipeChain.PIPE_LENGTH
    local ez = sz + dirZ * SPSPipeChain.PIPE_LENGTH
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    local ey = sy
    if terrain ~= nil then
        ey = getTerrainHeightAtWorldPos(terrain, ex, 0, ez)
    end
    local _, floorOffset, _ = getTranslation(seg.endFloorLevel)

    setWorldTranslation(seg.endConnectors, ex, ey - floorOffset, ez)
    setWorldRotation(seg.endConnectors, 0, math.atan2(dirX, dirZ) + math.pi, 0)

    self:_updateBezierBones(seg)
end

-- ---------------------------------------------------------------------------
-- Bezier: P0 = pipeRoot, P3 = endConnectors
-- ---------------------------------------------------------------------------
function SPSPipeChain:_updateBezierBones(seg)
    local p0x, p0y, p0z = getWorldTranslation(seg.pipeRoot)
    local p3x, p3y, p3z = getWorldTranslation(seg.endConnectors)

    local span = math.sqrt((p3x-p0x)^2 + (p3y-p0y)^2 + (p3z-p0z)^2)
    if span < 0.01 then return end

    local t1x, t1y, t1z = localDirectionToWorld(seg.pipeRoot, 0, 0, -1)

    local ecFwdX, ecFwdY, ecFwdZ = localDirectionToWorld(seg.endConnectors, 0, 0, -1)
    local backX, backY, backZ = -ecFwdX, -ecFwdY, -ecFwdZ

    local tension = math.max(span, 2.0) * 0.5

    local p1x = p0x + t1x * tension
    local p1y = p0y + t1y * tension
    local p1z = p0z + t1z * tension
    local p2x = p3x + backX * tension
    local p2y = p3y + backY * tension
    local p2z = p3z + backZ * tension

    local NUM = 13
    for i = 1, NUM do
        local bone = seg.midBones[i]
        if bone ~= nil and bone ~= 0 then
            local t   = i / (NUM + 1)
            local mt  = 1 - t
            local mt2 = mt * mt
            local mt3 = mt2 * mt
            local t2  = t * t
            local t3  = t2 * t

            local bx = mt3*p0x + 3*mt2*t*p1x + 3*mt*t2*p2x + t3*p3x
            local by = mt3*p0y + 3*mt2*t*p1y + 3*mt*t2*p2y + t3*p3y
            local bz = mt3*p0z + 3*mt2*t*p1z + 3*mt*t2*p2z + t3*p3z

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

            setWorldTranslation(bone, bx, by, bz)
            setWorldRotation(bone, rx, ry, 0)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Destroy all scene nodes for a segment
-- ---------------------------------------------------------------------------
function SPSPipeChain:_destroySegmentNodes(seg)
    if seg == nil then return end

    if g_slurryPipeManager ~= nil and seg.chainCoupling ~= nil then
        local entries = g_slurryPipeManager.chainTerminusEntries
        for i, e in ipairs(entries) do
            if e == seg.chainCoupling then table.remove(entries, i) break end
        end
        if seg.chainCoupling.isConnected then
            g_slurryPipeManager:applyDisconnect(nil, seg.chainCoupling.id, seg.chainCoupling)
        end
    end

    if seg.activatable ~= nil then
        seg.activatable:delete()
        seg.activatable = nil
    end

    if seg.pipeRoot ~= nil and seg.pipeRoot ~= 0 then
        delete(seg.pipeRoot)
        seg.pipeRoot      = nil
        seg.endConnectors = nil
        seg.detNode01     = nil
        seg.endFloorLevel = nil
    end
end

-- ---------------------------------------------------------------------------
-- Docking station
-- ---------------------------------------------------------------------------
function SPSPipeChain:addDockingStation()
    if #self.segments == 0 then return end
    if self.dockingStation ~= nil then return end

    local lastSeg = self.segments[#self.segments]

    local dsPath  = self.modDirectory .. "i3d/dockingStation/dockingStation.i3d"
    local i3dRoot = loadI3DFile(dsPath)
    if i3dRoot == nil or i3dRoot == 0 then
        print("[SPS] SPSPipeChain: failed to load dockingStation.i3d")
        return
    end

    local dsNode        = getChildAt(i3dRoot, 0)
    local visShape      = getChildAt(dsNode, 0)
    local lowerNode     = getChildAt(visShape, 0)
    local upperNode     = getChildAt(visShape, 1)
    local dockingTarget = getChildAt(dsNode, 2)

    local ex, ey, ez = getWorldTranslation(lastSeg.endConnectors)
    local rx, ry, rz = getWorldRotation(lastSeg.endConnectors)
    local terrain  = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    local terrainY = (terrain ~= nil) and getTerrainHeightAtWorldPos(terrain, ex, 0, ez) or ey

    link(getRootNode(), dsNode)
    setWorldTranslation(dsNode, ex, terrainY, ez)
    setWorldRotation(dsNode, rx, ry, rz)
    delete(i3dRoot)

    -- Save endConnectors position before moving it, so it can be restored if DS is removed
    local origEx, origEy, origEz       = getWorldTranslation(lastSeg.endConnectors)
    local origErx, origEry, origErz    = getWorldRotation(lastSeg.endConnectors)

    -- Move lastSeg endConnectors to dockingTarget world position so the segment
    -- pipe naturally ends at the DS inlet. Keep original rotation for the bezier
    -- arrival tangent.
    local dtx, dty, dtz = getWorldTranslation(dockingTarget)
    setWorldTranslation(lastSeg.endConnectors, dtx, dty, dtz)
    self:_updateBezierBones(lastSeg)

    local rbpEntry = {
        vehicle   = nil,
        lowerNode = lowerNode,
        upperNode = upperNode,
        valveType = SPS_VALVE_TYPE_NONE,
        valveOpen = true,
        isChain   = true,
        chain     = self,
    }
    if g_slurryPipeManager ~= nil then
        table.insert(g_slurryPipeManager.rubberBootPortEntries, rbpEntry)
    end

    self._dsSaveX  = ex      ; self._dsSaveY  = terrainY ; self._dsSaveZ  = ez
    self._dsSaveRX = rx      ; self._dsSaveRY = ry        ; self._dsSaveRZ = rz

    self.dockingStation = {
        dsNode        = dsNode,
        dockingTarget = dockingTarget,
        rbpEntry      = rbpEntry,
        lastSeg       = lastSeg,
        origEndX      = origEx,  origEndY  = origEy,  origEndZ  = origEz,
        origEndRX     = origErx, origEndRY = origEry, origEndRZ = origErz,
    }

    if self.anchorCoupling ~= nil then
        self.anchorCoupling.valveOpen = true
    end

    print("[SPS] SPSPipeChain: docking station added")
end

function SPSPipeChain:removeDockingStation()
    self:_removeDockingStation()
end

function SPSPipeChain:_removeDockingStation()
    if self.dockingStation == nil then return end

    if g_slurryPipeManager ~= nil then
        local entries = g_slurryPipeManager.rubberBootPortEntries
        for i, e in ipairs(entries) do
            if e == self.dockingStation.rbpEntry then table.remove(entries, i) break end
        end
    end

    -- Restore last segment's endConnectors to its pre-DS position
    local ds = self.dockingStation
    if ds.lastSeg ~= nil and ds.lastSeg.endConnectors ~= nil and ds.origEndX ~= nil then
        setWorldTranslation(ds.lastSeg.endConnectors, ds.origEndX,  ds.origEndY,  ds.origEndZ)
        setWorldRotation(ds.lastSeg.endConnectors,    ds.origEndRX, ds.origEndRY, ds.origEndRZ)
        self:_updateBezierBones(ds.lastSeg)
    end

    if ds.dsNode ~= nil and ds.dsNode ~= 0 then
        delete(ds.dsNode)
    end

    self.dockingStation = nil
    self._dsSaveX = nil ; self._dsSaveY = nil ; self._dsSaveZ = nil
    self._dsSaveRX = nil ; self._dsSaveRY = nil ; self._dsSaveRZ = nil

    if self.anchorCoupling ~= nil then
        self.anchorCoupling.valveOpen = false
    end
    print("[SPS] SPSPipeChain: docking station removed")
end

-- ---------------------------------------------------------------------------
-- Save / Restore
-- ---------------------------------------------------------------------------
function SPSPipeChain:getSaveData()
    local data = {
        anchorX           = 0,
        anchorY           = 0,
        anchorZ           = 0,
        hasDockingStation = self.dockingStation ~= nil,
        dsSaveX           = self._dsSaveX  or 0,
        dsSaveY           = self._dsSaveY  or 0,
        dsSaveZ           = self._dsSaveZ  or 0,
        dsSaveRX          = self._dsSaveRX or 0,
        dsSaveRY          = self._dsSaveRY or 0,
        dsSaveRZ          = self._dsSaveRZ or 0,
        segments          = {},
    }
    if self.anchorCoupling.mountNode ~= nil then
        data.anchorX, data.anchorY, data.anchorZ =
            getWorldTranslation(self.anchorCoupling.mountNode)
    end
    for i, seg in ipairs(self.segments) do
        -- If DS is present, save the original (pre-DS-move) endConnectors position
        -- so that on restore the segment is rebuilt correctly before DS reattaches
        local wx, wy, wz, rx, ry, rz
        if self.dockingStation ~= nil and i == #self.segments
        and self.dockingStation.origEndX ~= nil then
            wx = self.dockingStation.origEndX ; wy = self.dockingStation.origEndY
            wz = self.dockingStation.origEndZ
            rx = self.dockingStation.origEndRX ; ry = self.dockingStation.origEndRY
            rz = self.dockingStation.origEndRZ
        else
            if seg.endConnectors ~= nil and seg.endConnectors ~= 0 then
                wx, wy, wz = getWorldTranslation(seg.endConnectors)
                rx, ry, rz = getWorldRotation(seg.endConnectors)
            end
        end
        if wx ~= nil then
            table.insert(data.segments, { x=wx, y=wy, z=wz, rx=rx, ry=ry, rz=rz })
        end
    end
    return data
end

function SPSPipeChain:restoreFromSaveData(data)
    local nextX, nextY, nextZ, nextRY
    nextX, nextY, nextZ = getWorldTranslation(self.anchorCoupling.mountNode)
    local _, ry, _ = getWorldRotation(self.anchorCoupling.mountNode)
    nextRY = ry

    for i, segData in ipairs(data.segments) do
        local seg = self:_loadPipe(nextX, nextY, nextZ, nextRY)
        if seg == nil then break end
        setWorldTranslation(seg.endConnectors, segData.x, segData.y, segData.z)
        setWorldRotation(seg.endConnectors, segData.rx, segData.ry, segData.rz)
        self:_updateBezierBones(seg)
        table.insert(self.segments, seg)
        if g_slurryPipeManager ~= nil then
            table.insert(g_slurryPipeManager.chainTerminusEntries, seg.chainCoupling)
        end
        local activatable = SPSChainActivatable.new(self, #self.segments)
        g_currentMission.activatableObjectsSystem:addActivatable(activatable)
        seg.activatable = activatable
        nextX, nextY, nextZ = segData.x, segData.y, segData.z
        nextRY = segData.ry
    end
    if data.hasDockingStation then
        self:_restoreDockingStation(data)
    end
    print("[SPS] SPSPipeChain: restored " .. #self.segments .. " segments")
end

function SPSPipeChain:_restoreDockingStation(data)
    if #self.segments == 0 then return end
    local lastSeg = self.segments[#self.segments]

    local dsPath  = self.modDirectory .. "i3d/dockingStation/dockingStation.i3d"
    local i3dRoot = loadI3DFile(dsPath)
    if i3dRoot == nil or i3dRoot == 0 then return end

    local dsNode        = getChildAt(i3dRoot, 0)
    local visShape      = getChildAt(dsNode, 0)
    local lowerNode     = getChildAt(visShape, 0)
    local upperNode     = getChildAt(visShape, 1)
    local dockingTarget = getChildAt(dsNode, 2)

    link(getRootNode(), dsNode)
    setWorldTranslation(dsNode, data.dsSaveX, data.dsSaveY, data.dsSaveZ)
    setWorldRotation(dsNode, data.dsSaveRX, data.dsSaveRY, data.dsSaveRZ)
    delete(i3dRoot)

    -- Save original endConnectors pos then move to dockingTarget
    local origEx, origEy, origEz    = getWorldTranslation(lastSeg.endConnectors)
    local origErx, origEry, origErz = getWorldRotation(lastSeg.endConnectors)

    local dtx, dty, dtz = getWorldTranslation(dockingTarget)
    setWorldTranslation(lastSeg.endConnectors, dtx, dty, dtz)
    self:_updateBezierBones(lastSeg)

    local rbpEntry = {
        vehicle   = nil,
        lowerNode = lowerNode,
        upperNode = upperNode,
        valveType = SPS_VALVE_TYPE_NONE,
        valveOpen = true,
        isChain   = true,
        chain     = self,
    }
    if g_slurryPipeManager ~= nil then
        table.insert(g_slurryPipeManager.rubberBootPortEntries, rbpEntry)
    end

    self._dsSaveX  = data.dsSaveX  ; self._dsSaveY  = data.dsSaveY  ; self._dsSaveZ  = data.dsSaveZ
    self._dsSaveRX = data.dsSaveRX ; self._dsSaveRY = data.dsSaveRY ; self._dsSaveRZ = data.dsSaveRZ

    self.dockingStation = {
        dsNode        = dsNode,
        dockingTarget = dockingTarget,
        rbpEntry      = rbpEntry,
        lastSeg       = lastSeg,
        origEndX      = origEx,  origEndY  = origEy,  origEndZ  = origEz,
        origEndRX     = origErx, origEndRY = origEry, origEndRZ = origErz,
    }
    if self.anchorCoupling ~= nil then
        self.anchorCoupling.valveOpen = true
    end
end