-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.4

-- SPSPipeChain.lua
-- FS25_SlurryPipeSystem

SPSPipeChain = {}
SPSPipeChain.__index = SPSPipeChain

SPSPipeChain.PIPE_LENGTH   = 4.0
SPSPipeChain.PLAYER_OFFSET = 0.75
SPSPipeChain.NUM_BONES         = 14
SPSPipeChain.PIPE_FLOOR_RADIUS = 0.08    -- measured: bone centre to pipe bottom

-- ---------------------------------------------------------------------------
-- Debug logging
-- Flip SPSPipeChain.DEBUG to true to print [SPS PC] trace lines from every key
-- part of this script; set it to false to silence all logging from this file.
--
-- SPSPipeChain.log(fmt, ...) checks the flag BEFORE doing any string.format
-- work, and callers pass the format + arguments through (they do not pre-format
-- the string). That means when DEBUG is false there is no string allocation, so
-- the helper is safe to call from per-tick code. Any per-tick / per-bone call
-- sites are additionally wrapped in `if SPSPipeChain.DEBUG then ... end` so the
-- loop body itself is skipped entirely when logging is off.
-- ---------------------------------------------------------------------------
SPSPipeChain.DEBUG = false

function SPSPipeChain.log(fmt, ...)
    if not SPSPipeChain.DEBUG then return end
    if select("#", ...) > 0 then
        print("[SPS PC] " .. string.format(fmt, ...))
    else
        print("[SPS PC] " .. tostring(fmt))
    end
end

function SPSPipeChain.new(anchorCoupling, modDirectory)
    local self            = setmetatable({}, SPSPipeChain)
    self.anchorCoupling   = anchorCoupling
    self.modDirectory     = modDirectory
    self.segments         = {}
    self.liveSegment      = nil
    self.dockingStation   = nil
    self.localStart       = false
    self.localStartNode   = nil
    SPSPipeChain.log("new: chain created — anchorId=%s placeable=%s",
        tostring(anchorCoupling ~= nil and anchorCoupling.id or "nil"),
        tostring(anchorCoupling ~= nil and anchorCoupling.placeable ~= nil))
    return self
end

function SPSPipeChain:delete()
    SPSPipeChain.log("delete: tearing down chain — segments=%d live=%s ds=%s",
        #self.segments, tostring(self.liveSegment ~= nil), tostring(self.dockingStation ~= nil))
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
function SPSPipeChain:startLaying(sx, sy, sz, sry, localStartNode)
    if self.liveSegment ~= nil then
        SPSPipeChain.log("startLaying: ignored — a live segment already exists")
        return
    end

    -- Placeable anchors can pass their real mount node here.  Segment 1 is then
    -- linked to that node and set to local 0,0,0 / 0,0,0, matching the vehicle
    -- coupler behaviour at the actual connector node instead of rebuilding from
    -- world yaw only.
    local useLocalStart = #self.segments == 0 and localStartNode ~= nil and localStartNode ~= 0
    if useLocalStart and entityExists ~= nil and not entityExists(localStartNode) then
        useLocalStart = false
    end

    SPSPipeChain.log("startLaying: segments=%d useLocalStart=%s pos=(%.2f,%.2f,%.2f) ry=%.3f",
        #self.segments, tostring(useLocalStart), sx, sy, sz, sry or 0)

    local seg = self:_loadPipe(sx, sy, sz, sry or 0, nil, nil, nil, useLocalStart and localStartNode or nil)
    if seg == nil then
        SPSPipeChain.log("startLaying: ABORT — _loadPipe returned nil")
        return
    end

    if useLocalStart then
        self.localStart = true
        self.localStartNode = localStartNode
    end

    if #self.segments > 0 then
        local prevSeg = self.segments[#self.segments]
        if prevSeg.endConnectors ~= nil and prevSeg.endConnectors ~= 0 then
            link(prevSeg.endConnectors, seg.pipeRoot)
            setTranslation(seg.pipeRoot, 0, 0, 0)
            setRotation(seg.pipeRoot, 0, 0, 0)
        end
    end

    self.liveSegment = seg
    SPSPipeChain.log("startLaying: live segment created (will become segment %d)", #self.segments + 1)

    -- [SPS MP] Announce the new live segment so peers spawn/extend the preview.
    -- Remote previews never originate this (guarded in onChainLiveSegmentStarted).
    if not self.isRemoteLive and g_slurryPipeManager ~= nil
    and g_slurryPipeManager.onChainLiveSegmentStarted ~= nil then
        g_slurryPipeManager:onChainLiveSegmentStarted(self)
    end
end

-- ---------------------------------------------------------------------------
-- Finalize placement: convert visual to real bez pipe, create chain start coupling, begin chain laying
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Lock the current live pipe in place
-- ---------------------------------------------------------------------------
function SPSPipeChain:lockLivePipe()
    if self.liveSegment == nil then
        SPSPipeChain.log("lockLivePipe: ignored — no live segment")
        return
    end
    local seg = self.liveSegment
    self.liveSegment = nil

    -- The previous last segment is no longer the end — remove its end activatable
    if #self.segments > 0 then
        local prevLast = self.segments[#self.segments]
        if prevLast.endActivatable ~= nil then
            prevLast.endActivatable:delete()
            prevLast.endActivatable = nil
        end
    end

    table.insert(self.segments, seg)

    if g_slurryPipeManager ~= nil then
        table.insert(g_slurryPipeManager.chainTerminusEntries, seg.chainCoupling)
    end

    -- Segment 1 only: register detNode01 (start of pipe) as a chain start
    -- detection coupling so vehicles can arc-detect the start end and connect
    -- a bez pipe to it.
    if #self.segments == 1 and g_slurryPipeManager ~= nil then
        local detNode01 = seg.detNode01
        if detNode01 ~= nil and detNode01 ~= 0 then
            local startCoupling = {
                id                       = -2,
                mountNode                = detNode01,
                arcNode                  = nil,
                isConnected              = false,
                valveOpen                = false,
                connectedTarget          = nil,
                connectedPartnerCoupling = nil,
                pipeId                   = nil,
                isChainTerminus          = true,
                chain                    = self,
                segmentIndex             = 0,
                sourceEntry              = self.anchorCoupling.sourceEntry,
                placeable                = self.anchorCoupling.placeable,
                isChainStart             = true,
            }
            seg.chainStartCoupling = startCoupling
            table.insert(g_slurryPipeManager.chainTerminusEntries, startCoupling)
            SPSPipeChain.log("lockLivePipe: chain start detection coupling registered on detNode01")

            -- Vehicle anchor: auto-connect bez pipe between vehicle coupler and chain start.
            -- The anchor coupling is a vehicle coupling if it has no placeable.
            -- This bez is removable/reconnectable independently of the chain segments.
            if self.anchorCoupling.placeable == nil and not self.anchorCoupling.isConnected then
                local vehicle, _ = g_slurryPipeManager:_findCouplingOwner(self.anchorCoupling)
                if vehicle ~= nil then
                    local ownerA = vehicle
                    g_slurryPipeManager:applyConnectCouplings(
                        self.anchorCoupling, startCoupling, ownerA, nil)
                    SlurryPipeConnectEvent.sendEvent(
                        vehicle, nil,
                        SlurryPipeConnectEvent.TARGET_TYPE_PLACEABLE,
                        self.anchorCoupling.id, startCoupling.id, true)  -- [SPS MP] noEventSend: bez replicated via SPSChainStateEvent
                    SPSPipeChain.log("lockLivePipe: auto-connected bez from vehicle coupler to chain start")
                end
            elseif self.anchorCoupling.placeable ~= nil then
                -- Placeable anchor: do NOT mark the anchor isConnected (would break the
                -- activatable's state machine and create a phantom bez pipe visual).
                -- Instead, link startCoupling -> anchor as a one-way "logical" pair so
                -- _propagateValveState can walk from the chain back to the placeable's
                -- valve handle when the tanker's valve is toggled at the far end.
                startCoupling.isConnected              = true
                startCoupling.connectedPartnerCoupling = self.anchorCoupling
                startCoupling.connectedTarget          = self.anchorCoupling.placeable
                SPSPipeChain.log("lockLivePipe: linked chain start to placeable anchor for valve propagation")
            end
        end
    elseif #self.segments == 1 and self.chainStartCoupling ~= nil then
        -- Chain start coupling already exists from finalizePlacement
        seg.chainStartCoupling = self.chainStartCoupling
        SPSPipeChain.log("lockLivePipe: using existing chain start coupling from placement")
    end

    -- Terrain clamp: run once at lock time so the pipe drapes over ground
    -- contours without cutting through. Never runs again after this.
    self:_terrainClampBones(seg)

    -- Primary activatable at pipeRoot (start of segment): offers "remove from here"
    local activatable = SPSChainActivatable.new(self, #self.segments)
    g_currentMission.activatableObjectsSystem:addActivatable(activatable)
    seg.activatable = activatable

    -- End activatable at detNode04 (end of segment): offers "lay more" / docking station
    local endActivatable = SPSChainActivatable.new(self, #self.segments)
    endActivatable.isEndActivatable = true
    g_currentMission.activatableObjectsSystem:addActivatable(endActivatable)
    seg.endActivatable = endActivatable

    SPSPipeChain.log("locked segment %d — primary@pipeRoot end@endConnectors", #self.segments)

    -- [SPS MP] Replicate the committed chain to all peers (server applies +
    -- broadcasts; client sends a request the server applies authoritatively).
    print(string.format("[SPS MP] lockLivePipe DONE netId=%s segs=%d", tostring(self.netId), #self.segments))
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.commitChainState ~= nil then
        g_slurryPipeManager:commitChainState(self)
    end
end

-- ---------------------------------------------------------------------------
-- Cancel (remove) the current live pipe without locking
-- ---------------------------------------------------------------------------
function SPSPipeChain:cancelLivePipe()
    if self.liveSegment == nil then return end
    -- [SPS MP] Remove the preview on remote peers (only the originator broadcasts).
    if self.netId ~= nil and not self.isRemoteLive and SPSChainLiveEvent ~= nil then
        SPSChainLiveEvent.sendCancel(self.netId)
    end
    self:_destroySegmentNodes(self.liveSegment)
    self.liveSegment = nil
    SPSPipeChain.log("cancelled live pipe")
end

-- ---------------------------------------------------------------------------
-- Remove locked segments from fromIndex to end
-- ---------------------------------------------------------------------------
function SPSPipeChain:removeFromIndex(fromIndex)
    if fromIndex < 1 then fromIndex = 1 end
    SPSPipeChain.log("removeFromIndex(%d): start — current segments=%d ds=%s",
        fromIndex, #self.segments, tostring(self.dockingStation ~= nil))
    if self.dockingStation ~= nil then self:_removeDockingStation() end
    for i = #self.segments, fromIndex, -1 do
        self:_destroySegmentNodes(self.segments[i])
        table.remove(self.segments, i)
    end
    SPSPipeChain.log("removeFromIndex(%d): segments remaining: %d", fromIndex, #self.segments)

    -- The new last segment lost its endActivatable when the next segment was locked.
    -- Recreate it so the player can continue laying or add a docking station.
    if #self.segments > 0 then
        local newLast = self.segments[#self.segments]
        if newLast.endActivatable == nil then
            local endAct = SPSChainActivatable.new(self, #self.segments)
            endAct.isEndActivatable = true
            g_currentMission.activatableObjectsSystem:addActivatable(endAct)
            newLast.endActivatable = endAct
        end
    end

    -- [SPS MP] If segments remain this is a state update (fewer segments).
    -- A full removal (0 segments) is replicated by onChainEmpty/commitChainRemoval.
    if #self.segments > 0 and g_slurryPipeManager ~= nil and g_slurryPipeManager.commitChainState ~= nil then
        g_slurryPipeManager:commitChainState(self)
    end
end

-- ---------------------------------------------------------------------------
-- Load a pipe i3d, link to world root, position at startX/Y/Z with startRY
--
-- New i3d layout (slurryPipe = pipeRoot):
--   child 0  = hose            (skinned mesh)
--   child 1  = startConnectors  → child 0=female01, 1=male01, 2=detectionNode01, 3=Bone1, 4=startFloorLevel
--   child 2  = endConnectors    → child 0=female02, 1=male02, 2=detectionNode04, 3=Bone16, 4=endFloorLevel
--                                 (carries baked rotation 0,180,0)
--   child 3..18 = Bone2 .. Bone15 (flat children of pipeRoot)
--
-- Variable naming follows the i3d node names:
--   detNode01 = detection node at START of pipe (male side)
--   detNode04 = detection node at END   of pipe (female side, where next segment plugs in)
-- ---------------------------------------------------------------------------
function SPSPipeChain:_loadPipe(startX, startY, startZ, startRY, colorR, colorG, colorB, localStartNode, skipFloorOffset)
    SPSPipeChain.log("_loadPipe: enter — pos=(%.2f,%.2f,%.2f) ry=%.3f localStart=%s restore=%s",
        startX, startY, startZ, startRY,
        tostring(localStartNode ~= nil and localStartNode ~= 0), tostring(skipFloorOffset == true))
    local pipePath = self.modDirectory .. "i3d/pipes/slurryPipe.i3d"
    local i3dRoot  = loadI3DFile(pipePath)
    if i3dRoot == nil or i3dRoot == 0 then
        SPSPipeChain.log("_loadPipe: ERROR failed to load slurryPipe.i3d")
        return nil
    end

    local pipeRoot        = getChildAt(i3dRoot, 0)
    local startConnectors = getChildAt(pipeRoot, 1)
    local endConnectors   = getChildAt(pipeRoot, 2)

    -- startConnectors children: 0=female01, 1=male01, 2=detectionNode01, 3=Bone1, 4=startFloorLevel
    local femaleStart     = getChildAt(startConnectors, 0)
    local maleStart       = getChildAt(startConnectors, 1)
    local detNode01       = getChildAt(startConnectors, 2)
    local bone1           = getChildAt(startConnectors, 3)
    local startFloorLevel = getChildAt(startConnectors, 4)

    -- endConnectors children: 0=female02, 1=male02, 2=detectionNode04,
    --                         3=Bone16, 4=endFloorLevel
    local femaleConn     = getChildAt(endConnectors, 0)
    local maleConn       = getChildAt(endConnectors, 1)
    local detNode04      = getChildAt(endConnectors, 2)
    local bone16         = getChildAt(endConnectors, 3)
    local endFloorLevel  = getChildAt(endConnectors, 4)

    if bone1 == nil or bone1 == 0 or bone16 == nil or bone16 == 0 then
        SPSPipeChain.log("_loadPipe: ERROR Bone1 or Bone16 not found")
        delete(i3dRoot)
        return nil
    end

    -- Interior bones: Bone2..Bone15 at pipeRoot children 3..16.
    local allBones = {}
    for i = 1, SPSPipeChain.NUM_BONES do
        allBones[i] = getChildAt(pipeRoot, 2 + i)
    end

    if localStartNode ~= nil and localStartNode ~= 0
    and (entityExists == nil or entityExists(localStartNode)) then
        link(localStartNode, pipeRoot)
        setTranslation(pipeRoot, 0, 0, 0)
        setRotation(pipeRoot, 0, 0, 0)
    else
        link(getRootNode(), pipeRoot)
        local adjustedY = startY
        -- Apply startFloorLevel offset only when laying new pipes (not during restore)
        if not skipFloorOffset and startFloorLevel ~= nil and startFloorLevel ~= 0 then
            local _, floorOffset, _ = getTranslation(startFloorLevel)
            adjustedY = startY - floorOffset
        end
        setWorldTranslation(pipeRoot, startX, adjustedY, startZ)
        setWorldRotation(pipeRoot, 0, startRY, 0)
    end
    delete(i3dRoot)

    if femaleStart ~= nil and femaleStart ~= 0 then setVisibility(femaleStart, false) end
    if maleStart   ~= nil and maleStart   ~= 0 then setVisibility(maleStart,   true)  end
    if femaleConn  ~= nil and femaleConn  ~= 0 then setVisibility(femaleConn,  true)  end
    if maleConn    ~= nil and maleConn    ~= 0 then setVisibility(maleConn,    false) end

    local cr = colorR or (g_slurryPipeManager and g_slurryPipeManager.currentPipeColor.r or 0)
    local cg = colorG or (g_slurryPipeManager and g_slurryPipeManager.currentPipeColor.g or 0.05)
    local cb = colorB or (g_slurryPipeManager and g_slurryPipeManager.currentPipeColor.b or 0)
    local hoseNode = getChildAt(pipeRoot, 0)
    if hoseNode ~= nil and hoseNode ~= 0 then
        setShaderParameter(hoseNode, "colorScale", cr, cg, cb, 0, false)
    else
        SPSPipeChain.log("_loadPipe: WARNING hoseNode nil — colour not applied")
    end

    -- [SPS PC] anchorCoupling can legitimately be nil here: SlurryPipeManager
    -- :applyDisconnect (freeChainBindingIfNeeded) clears it when a chain's bez
    -- binding is broken, leaving the chain as a free-standing world entity. In
    -- that state the player can still lay more pipe, so dereferencing
    -- self.anchorCoupling unconditionally crashed _loadPipe. Guard it and fall
    -- back to nil source/placeable; the flow source is re-resolved from
    -- anchorCoupling on reconnect, so a free-standing terminus needs no source.
    local anchorSourceEntry = (self.anchorCoupling ~= nil) and self.anchorCoupling.sourceEntry or nil
    local anchorPlaceable   = (self.anchorCoupling ~= nil) and self.anchorCoupling.placeable   or nil
    if self.anchorCoupling == nil then
        SPSPipeChain.log("_loadPipe: anchorCoupling nil (free-standing chain) — chainCoupling source/placeable set nil")
    end

    local chainCoupling = {
        id                       = #self.segments + 1,
        mountNode                = detNode04,
        arcNode                  = nil,
        isConnected              = false,
        valveOpen                = false,
        connectedTarget          = nil,
        connectedPartnerCoupling = nil,
        pipeId                   = nil,
        isChainTerminus          = true,
        chain                    = self,
        segmentIndex             = #self.segments + 1,
        sourceEntry              = anchorSourceEntry,
        placeable                = anchorPlaceable,
    }

    -- Segment loaded successfully (detailed position logging removed for cleaner logs)

    return {
        pipeRoot         = pipeRoot,
        startConnectors  = startConnectors,
        endConnectors    = endConnectors,
        bone1            = bone1,
        bone16           = bone16,
        detNode01        = detNode01,
        detNode04        = detNode04,
        startFloorLevel  = startFloorLevel,
        endFloorLevel    = endFloorLevel,
        allBones         = allBones,
        chainCoupling    = chainCoupling,
        activatable      = nil,
        startX           = startX,
        startY           = startY,
        startZ           = startZ,
        startRY         = startRY,
        colorR          = cr,
        colorG          = cg,
        colorB          = cb,
        _hasLogged      = false,
    }
end

-- ---------------------------------------------------------------------------
-- Update — called each tick from manager
-- ---------------------------------------------------------------------------
function SPSPipeChain:update(dt)
    if self.liveSegment == nil then return end
    -- [SPS MP] Remote preview chains are driven by SPSChainLiveEvent POS updates,
    -- not by this peer's local player. Interpolate toward the last target instead.
    if self.isRemoteLive then
        self:_updateRemoteLive(dt)
        return
    end
    if g_localPlayer == nil then return end

    local seg = self.liveSegment

    if SPSPipeChain.DEBUG and not seg._loggedUpdate then
        seg._loggedUpdate = true
        SPSPipeChain.log("update: tracking live segment end to player (PIPE_LENGTH=%.2f PLAYER_OFFSET=%.2f)",
            SPSPipeChain.PIPE_LENGTH, SPSPipeChain.PLAYER_OFFSET)
    end

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

    -- [SPS MP] Replicate the live end position to other peers (throttled).
    if self.netId ~= nil then
        self:_maybeSendLivePos(dt, ex, ey - floorOffset, ez)
    end
end

-- [SPS MP] Throttled live-position replication: at most every 100 ms, and only
-- once the end has moved more than ~0.3 m, to keep bandwidth negligible.
function SPSPipeChain:_maybeSendLivePos(dt, ex, ey, ez)
    self._liveAccum = (self._liveAccum or 0) + (dt or 0)
    local last  = self._liveLastSent
    local moved = (last == nil)
        or ((ex - last.x) ^ 2 + (ey - last.y) ^ 2 + (ez - last.z) ^ 2) > 0.0025
    if self._liveAccum >= 80 and moved then
        self._liveAccum = 0
        self._liveLastSent = { x = ex, y = ey, z = ez }
        if SPSChainLiveEvent ~= nil then
            SPSChainLiveEvent.sendPos(self.netId, ex, ey, ez)
        end
    end
end

-- [SPS MP] Place a remote preview segment's end immediately (snap).
function SPSPipeChain:setRemoteLiveEnd(ex, ey, ez)
    local seg = self.liveSegment
    if seg == nil or seg.endConnectors == nil then return end
    local dx = ex - (seg.startX or ex)
    local dz = ez - (seg.startZ or ez)
    setWorldTranslation(seg.endConnectors, ex, ey, ez)
    setWorldRotation(seg.endConnectors, 0, math.atan2(dx, dz) + math.pi, 0)
    self:_updateBezierBones(seg)
end

-- [SPS MP] Set the interpolation target for a remote preview. First update snaps
-- (avoids a long sweep from the spawn position); later updates are smoothed in
-- _updateRemoteLive.
function SPSPipeChain:setRemoteLiveTarget(ex, ey, ez)
    if self._liveTargetX == nil then
        self:setRemoteLiveEnd(ex, ey, ez)
    end
    self._liveTargetX, self._liveTargetY, self._liveTargetZ = ex, ey, ez
end

-- [SPS MP] Per-frame smoothing of a remote preview toward its last target.
function SPSPipeChain:_updateRemoteLive(dt)
    local seg = self.liveSegment
    if seg == nil or seg.endConnectors == nil or self._liveTargetX == nil then return end
    local cx, cy, cz = getWorldTranslation(seg.endConnectors)
    local t = (dt or 16) / 100
    if t > 1 then t = 1 end
    local nx = cx + (self._liveTargetX - cx) * t
    local ny = cy + (self._liveTargetY - cy) * t
    local nz = cz + (self._liveTargetZ - cz) * t
    local dx = nx - (seg.startX or nx)
    local dz = nz - (seg.startZ or nz)
    setWorldTranslation(seg.endConnectors, nx, ny, nz)
    setWorldRotation(seg.endConnectors, 0, math.atan2(dx, dz) + math.pi, 0)
    self:_updateBezierBones(seg)
end

-- ---------------------------------------------------------------------------
-- _terrainClampBones
-- Called once at lock time. Samples terrain at every other interior bone,
-- pushes bones up if below terrain + pipe radius, interpolates non-sampled
-- bones from their neighbours, then recomputes rotations from the adjusted
-- positions. 7 terrain queries total — negligible CPU cost.
-- ---------------------------------------------------------------------------
function SPSPipeChain:_terrainClampBones(seg)
    local terrain = g_currentMission and g_currentMission.terrainRootNode or nil
    if terrain == nil then
        SPSPipeChain.log("_terrainClampBones: skipped — no terrain root node")
        return
    end

    SPSPipeChain.log("_terrainClampBones: enter — clamping pipe bones to terrain")

    local NUM    = SPSPipeChain.NUM_BONES
    local RADIUS = SPSPipeChain.PIPE_FLOOR_RADIUS
    local SAG    = 0.03   -- 30mm max reduction at centre

    -- Collect world positions for all 16 bones.
    -- Index 0 = Bone1 (endpoint), 1..NUM = interior, NUM+1 = Bone16 (endpoint).
    local pos = {}
    local b1x,  b1y,  b1z  = getWorldTranslation(seg.bone1)
    local b16x, b16y, b16z = getWorldTranslation(seg.bone16)
    pos[0]       = { b1x,  b1y,  b1z  }
    pos[NUM + 1] = { b16x, b16y, b16z }
    for i = 1, NUM do
        local bone = seg.allBones[i]
        if bone ~= nil and bone ~= 0 then
            local x, y, z = getWorldTranslation(bone)
            pos[i] = { x, y, z }
        end
    end

    -- Sample terrain at every other interior bone (1,3,5,7,9,11,13 = 7 queries).
    local terrainMinY = {}   -- stores terrain+radius floor for each sampled bone
    local anyClamped = false
    for i = 1, NUM, 2 do
        if pos[i] ~= nil then
            local ty = getTerrainHeightAtWorldPos(terrain, pos[i][1], 0, pos[i][3])
            local minY = ty + RADIUS
            terrainMinY[i] = minY
            if pos[i][2] < minY then
                pos[i][2] = minY
                anyClamped = true
            end
        end
    end

    -- Interpolate non-sampled bones (2,4,6,8,10,12,14) from their sampled neighbours.
    for i = 2, NUM, 2 do
        if pos[i] ~= nil then
            local prevY = pos[i - 1] and pos[i - 1][2] or pos[i][2]
            local nextY = pos[i + 1] and pos[i + 1][2] or pos[i][2]
            local interp = (prevY + nextY) * 0.5
            if interp > pos[i][2] then
                pos[i][2] = interp
                anyClamped = true
            end
        end
    end

    -- Apply sine-shaped sag reduction: max SAG at centre tapering to 0 at endpoints.
    -- Re-clamp sampled bones against terrain so sag never pushes below ground.
    for i = 1, NUM do
        if pos[i] ~= nil then
            local t = i / (NUM + 1)
            local reduction = SAG * math.sin(t * math.pi)
            pos[i][2] = pos[i][2] - reduction
            -- Re-clamp sampled bones against stored terrain floor.
            local floor = terrainMinY[i]
            if floor ~= nil and pos[i][2] < floor then
                pos[i][2] = floor
            end
        end
    end

    -- Smoothing pass: blend each bone with its neighbours to remove the
    -- zigzag caused by alternating sample/interpolate heights.
    for i = 1, NUM do
        if pos[i] ~= nil then
            local prevY = pos[i - 1] and pos[i - 1][2] or pos[i][2]
            local nextY = pos[i + 1] and pos[i + 1][2] or pos[i][2]
            pos[i][2] = 0.25 * prevY + 0.5 * pos[i][2] + 0.25 * nextY
        end
    end

    -- Apply corrected positions and recompute rotation from adjusted path.
    for i = 1, NUM do
        local bone = seg.allBones[i]
        if bone ~= nil and bone ~= 0 and pos[i] ~= nil then
            setWorldTranslation(bone, pos[i][1], pos[i][2], pos[i][3])

            -- Tangent: central difference from prev to next bone.
            local prev = pos[i - 1] or pos[i]
            local next = pos[i + 1] or pos[i]
            local tdx = next[1] - prev[1]
            local tdy = next[2] - prev[2]
            local tdz = next[3] - prev[3]
            local tlen = math.sqrt(tdx*tdx + tdy*tdy + tdz*tdz)
            if tlen > 0.0001 then
                tdx = tdx / tlen
                tdy = tdy / tlen
                tdz = tdz / tlen
                local ry = math.atan2(-tdx, -tdz)
                local rx = math.atan2(tdy, math.sqrt(tdx*tdx + tdz*tdz))
                setWorldRotation(bone, rx, ry, 0)
            end
        end
    end

    SPSPipeChain.log("_terrainClampBones: done — anyClamped=%s", tostring(anyClamped))
end

-- ---------------------------------------------------------------------------
-- Bezier: P0 = Bone1 world pos, P3 = Bone16 world pos.
-- P1 exits in pipeRoot's local direction (natural exit from coupler).
-- P2 uses chord direction so it arrives at P3 from the correct side.
-- ---------------------------------------------------------------------------
function SPSPipeChain:_updateBezierBones(seg)
    if seg == nil or seg.bone1 == nil or seg.bone16 == nil
    or seg.bone1 == 0 or seg.bone16 == 0 then
        return
    end
    if entityExists ~= nil and (not entityExists(seg.bone1) or not entityExists(seg.bone16)) then
        return
    end

    if SPSPipeChain.DEBUG and not seg._loggedBezier then
        seg._loggedBezier = true
        SPSPipeChain.log("_updateBezierBones: first bezier solve for this segment")
    end

    local p0x, p0y, p0z = getWorldTranslation(seg.bone1)
    local p3x, p3y, p3z = getWorldTranslation(seg.bone16)

    local span = math.sqrt((p3x-p0x)^2 + (p3y-p0y)^2 + (p3z-p0z)^2)
    if span < 0.01 then return end

    -- Chord direction: straight from P0 to P3.
    local cdx = (p3x-p0x) / span
    local cdy = (p3y-p0y) / span
    local cdz = (p3z-p0z) / span

    -- P1: exits from P0 in pipeRoot's natural direction.
    local t1x, t1y, t1z = localDirectionToWorld(seg.pipeRoot, 0, 0, -1)

    local tension = span * 0.4
    local sag     = span * 0.04

    local p1x = p0x + t1x * tension
    local p1y = p0y + t1y * tension - sag
    local p1z = p0z + t1z * tension
    -- P2: approaches P3 from chord direction (not from endConnectors facing).
    local p2x = p3x - cdx * tension
    local p2y = p3y - cdy * tension - sag
    local p2z = p3z - cdz * tension

    -- Bezier calculation (logged once per segment via _hasLogged flag removed for cleaner logs)

    local NUM   = SPSPipeChain.NUM_BONES
    local TOTAL = NUM + 1

    for i = 1, NUM do
        local bone = seg.allBones[i]
        if bone ~= nil and bone ~= 0 then
            local t   = i / TOTAL
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

            local ry = math.atan2(-tdx, -tdz)
            local rx =  math.atan2( tdy, math.sqrt(tdx*tdx + tdz*tdz))

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

    SPSPipeChain.log("_destroySegmentNodes: tearing down segment — hasChainCoupling=%s hasChainStart=%s connected=%s",
        tostring(seg.chainCoupling ~= nil), tostring(seg.chainStartCoupling ~= nil),
        tostring(seg.chainCoupling ~= nil and seg.chainCoupling.isConnected == true))

    if g_slurryPipeManager ~= nil and seg.chainCoupling ~= nil then
        local entries = g_slurryPipeManager.chainTerminusEntries
        for i, e in ipairs(entries) do
            if e == seg.chainCoupling then table.remove(entries, i) break end
        end
        if seg.chainCoupling.isConnected then
            g_slurryPipeManager:applyDisconnect(nil, seg.chainCoupling.id, seg.chainCoupling)
        end
    end

    -- Clean up chain start detection coupling if present (segment 1 only)
    if g_slurryPipeManager ~= nil and seg.chainStartCoupling ~= nil then
        local entries = g_slurryPipeManager.chainTerminusEntries
        for i, e in ipairs(entries) do
            if e == seg.chainStartCoupling then table.remove(entries, i) break end
        end
        if seg.chainStartCoupling.isConnected then
            g_slurryPipeManager:applyDisconnect(nil, seg.chainStartCoupling.id, seg.chainStartCoupling)
        end
        seg.chainStartCoupling = nil
    end

    if seg.activatable ~= nil then
        seg.activatable:delete()
        seg.activatable = nil
    end

    if seg.endActivatable ~= nil then
        seg.endActivatable:delete()
        seg.endActivatable = nil
    end

    if seg.pipeRoot ~= nil and seg.pipeRoot ~= 0 then
        delete(seg.pipeRoot)
        seg.pipeRoot         = nil
        seg.startConnectors  = nil
        seg.endConnectors    = nil
        seg.detNode01        = nil
        seg.detNode04        = nil
        seg.startFloorLevel  = nil
        seg.endFloorLevel    = nil
        seg.nextPipeTarget   = nil
    end
end

-- ---------------------------------------------------------------------------
-- Docking station
-- ---------------------------------------------------------------------------
function SPSPipeChain:addDockingStation()
    if #self.segments == 0 then
        SPSPipeChain.log("addDockingStation: ignored — no segments")
        return
    end
    if self.dockingStation ~= nil then
        SPSPipeChain.log("addDockingStation: ignored — docking station already present")
        return
    end

    SPSPipeChain.log("addDockingStation: enter — segments=%d", #self.segments)

    local lastSeg = self.segments[#self.segments]

    local dsPath  = self.modDirectory .. "i3d/dockingStation/dockingStation.i3d"
    local i3dRoot = loadI3DFile(dsPath)
    if i3dRoot == nil or i3dRoot == 0 then
        SPSPipeChain.log("addDockingStation: ERROR failed to load dockingStation.i3d")
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

    removeFromPhysics(dsNode)
    link(getRootNode(), dsNode)
    setWorldTranslation(dsNode, ex, terrainY, ez)
    setWorldRotation(dsNode, rx, ry, rz)
    addToPhysics(dsNode)
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
    self._dsSaveRX = rx      ; self._dsSaveRY = ry ; self._dsSaveRZ = rz

    self.dockingStation = {
        dsNode        = dsNode,
        dockingTarget = dockingTarget,
        rbpEntry      = rbpEntry,
        lastSeg       = lastSeg,
        origEndX      = origEx,  origEndY  = origEy,  origEndZ  = origEz,
        origEndRX     = origErx, origEndRY = origEry, origEndRZ = origErz,
    }

    if self.anchorCoupling ~= nil then
        -- Open the anchor valve via the manager API so:
        --   * valveAnim plays forward (handle rotates open)
        --   * partner valve syncs (chain propagation)
        --   * SlurryValveStateEvent broadcasts to MP clients
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:applyValveState(nil, self.anchorCoupling.id, true, self.anchorCoupling)
            local ownerVehicle, _ = g_slurryPipeManager:_findCouplingOwner(self.anchorCoupling)
            SlurryValveStateEvent.sendEvent(ownerVehicle, self.anchorCoupling, true)
        else
            self.anchorCoupling.valveOpen = true
        end
    end

    SPSPipeChain.log("addDockingStation: docking station added at (%.2f,%.2f,%.2f)", ex, terrainY, ez)
end

function SPSPipeChain:removeDockingStation()
    self:_removeDockingStation()
end

function SPSPipeChain:_removeDockingStation()
    if self.dockingStation == nil then
        SPSPipeChain.log("_removeDockingStation: ignored — no docking station present")
        return
    end

    SPSPipeChain.log("_removeDockingStation: enter — removing docking station")

    -- Close the anchor valve via the manager API before teardown so:
    --   * valveAnim plays reverse (handle rotates back to closed)
    --   * partner valve syncs
    --   * SlurryValveStateEvent broadcasts
    if self.anchorCoupling ~= nil and g_slurryPipeManager ~= nil and self.anchorCoupling.valveOpen then
        g_slurryPipeManager:applyValveState(nil, self.anchorCoupling.id, false, self.anchorCoupling)
        local ownerVehicle, _ = g_slurryPipeManager:_findCouplingOwner(self.anchorCoupling)
        SlurryValveStateEvent.sendEvent(ownerVehicle, self.anchorCoupling, false)
    end

    if g_slurryPipeManager ~= nil then
        local entries = g_slurryPipeManager.rubberBootPortEntries
        for i, e in ipairs(entries) do
            if e == self.dockingStation.rbpEntry then table.remove(entries, i) break end
        end
    end

    -- Restore last segment's endConnectors to its pre-DS position. During map quit
    -- FS25 may already have deleted some nodes, so every node call is guarded.
    local ds = self.dockingStation
    if ds.lastSeg ~= nil and ds.lastSeg.endConnectors ~= nil and ds.lastSeg.endConnectors ~= 0
    and ds.origEndX ~= nil and (entityExists == nil or entityExists(ds.lastSeg.endConnectors)) then
        setWorldTranslation(ds.lastSeg.endConnectors, ds.origEndX,  ds.origEndY,  ds.origEndZ)
        setWorldRotation(ds.lastSeg.endConnectors,    ds.origEndRX, ds.origEndRY, ds.origEndRZ)
        self:_updateBezierBones(ds.lastSeg)
    end

    if ds.dsNode ~= nil and ds.dsNode ~= 0 and (entityExists == nil or entityExists(ds.dsNode)) then
        delete(ds.dsNode)
    end

    self.dockingStation = nil
    self._dsSaveX = nil ; self._dsSaveY = nil ; self._dsSaveZ = nil
    self._dsSaveRX = nil ; self._dsSaveRY = nil ; self._dsSaveRZ = nil

    if self.anchorCoupling ~= nil then
        self.anchorCoupling.valveOpen = false
    end
    SPSPipeChain.log("_removeDockingStation: docking station removed")
end

-- ---------------------------------------------------------------------------
-- Save / Restore
-- ---------------------------------------------------------------------------
function SPSPipeChain:getSaveData()
    SPSPipeChain.log("getSaveData: enter — segments=%d hasDS=%s anchorCoupling=%s",
        #self.segments, tostring(self.dockingStation ~= nil), tostring(self.anchorCoupling ~= nil))

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
        localStart        = self.localStart == true,
        segments          = {},
    }
    if self.anchorCoupling ~= nil
    and self.anchorCoupling.mountNode ~= nil and self.anchorCoupling.mountNode ~= 0 then
        if entityExists == nil or entityExists(self.anchorCoupling.mountNode) then
            data.anchorX, data.anchorY, data.anchorZ =
                getWorldTranslation(self.anchorCoupling.mountNode)
        end
    elseif self.anchorX ~= nil then
        -- Free-standing chain (bez was disconnected and binding freed). Use the
        -- world position cached by SlurryPipeManager:applyDisconnect so the chain
        -- still saves correctly as a world entity.
        data.anchorX, data.anchorY, data.anchorZ = self.anchorX, self.anchorY, self.anchorZ
        SPSPipeChain.log("getSaveData: using cached anchor (%.2f,%.2f,%.2f) — chain is free-standing",
            data.anchorX, data.anchorY, data.anchorZ)
    end
    -- Save pipeRoot of first segment so vehicle chains restore from the correct start position.
    -- Placeable-local chains do not use this on reload; they relink segment 1 to the
    -- anchor mount node and set local 0,0,0 / 0,0,0 again.
    if not data.localStart and #self.segments > 0 and self.segments[1].pipeRoot ~= nil
    and self.segments[1].pipeRoot ~= 0 and (entityExists == nil or entityExists(self.segments[1].pipeRoot)) then
        data.chainStartX, data.chainStartY, data.chainStartZ =
            getWorldTranslation(self.segments[1].pipeRoot)
        local _, chainStartRY, _ = getWorldRotation(self.segments[1].pipeRoot)
        data.chainStartRY = chainStartRY
    end
    for i, seg in ipairs(self.segments) do
        -- If DS is present, save the original (pre-DS-move) endConnectors position
        -- so that on restore the segment is rebuilt correctly before DS reattaches
        local wx, wy, wz, rx, ry, rz
        if self.dockingStation ~= nil and i == #self.segments
        and self.dockingStation.origEndX ~= nil then
            wx = self.dockingStation.origEndX ; wy = self.dockingStation.origEndY
            wz = self.dockingStation.origEndZ
            rx, ry, rz = 0, self.dockingStation.origEndRY or 0, 0
        else
            if seg.endConnectors ~= nil and seg.endConnectors ~= 0 then
                wx, wy, wz = getWorldTranslation(seg.endConnectors)
                local _, savedRY, _ = getWorldRotation(seg.endConnectors)
                rx, ry, rz = 0, savedRY, 0
            end
        end
        if wx ~= nil then
            table.insert(data.segments, { x=wx, y=wy, z=wz, rx=rx, ry=ry, rz=rz,
                colorR=seg.colorR, colorG=seg.colorG, colorB=seg.colorB })
        end
    end
    SPSPipeChain.log("getSaveData: done — saved %d segment(s) hasDS=%s",
        #data.segments, tostring(data.hasDockingStation))
    return data
end

function SPSPipeChain:restoreFromSaveData(data)
    SPSPipeChain.log("restoreFromSaveData: enter — %d segment(s) to restore localStart=%s hasDS=%s",
        (data.segments ~= nil) and #data.segments or 0,
        tostring(data.localStart == true), tostring(data.hasDockingStation == true))

    self.localStart = data.localStart == true
    self.localStartNode = (self.localStart and self.anchorCoupling ~= nil)
        and self.anchorCoupling.mountNode or nil

    local nextX, nextY, nextZ, nextRY
    if self.localStart and self.localStartNode ~= nil and self.localStartNode ~= 0
    and (entityExists == nil or entityExists(self.localStartNode)) then
        nextX, nextY, nextZ = getWorldTranslation(self.localStartNode)
        local _, ry, _ = getWorldRotation(self.localStartNode)
        nextRY = ry
    elseif data.chainStartX ~= nil then
        nextX, nextY, nextZ = data.chainStartX, data.chainStartY, data.chainStartZ
        -- chainStartRY is saved as getWorldRotation(segments[1].pipeRoot) — use it directly
        -- so the bezier tangent at the coupler end matches the original pipe layout.
        nextRY = data.chainStartRY or 0
    elseif self.anchorCoupling ~= nil and self.anchorCoupling.mountNode ~= nil then
        nextX, nextY, nextZ = getWorldTranslation(self.anchorCoupling.mountNode)
        local _, ry, _ = getWorldRotation(self.anchorCoupling.mountNode)
        nextRY = ry
    else
        -- Free-standing chain with no resolvable anchor: fall back to cached anchor pos.
        nextX, nextY, nextZ = data.anchorX or 0, data.anchorY or 0, data.anchorZ or 0
        nextRY = 0
    end

    for i, segData in ipairs(data.segments) do
        local localNode = (i == 1 and self.localStart) and self.localStartNode or nil
        local seg = self:_loadPipe(nextX, nextY, nextZ, nextRY,
            segData.colorR, segData.colorG, segData.colorB, localNode, true)
        if seg == nil then break end
        -- Calculate rotation for endConnectors to face from end back to start
        local p0x, p0y, p0z = getWorldTranslation(seg.pipeRoot)
        local dx = segData.x - p0x
        local dz = segData.z - p0z
        local len = math.sqrt(dx*dx + dz*dz)
        local cleanRY = len > 0.001 and math.atan2(dx / len, dz / len) + math.pi or 0
        setWorldTranslation(seg.endConnectors, segData.x, segData.y, segData.z)
        setWorldRotation(seg.endConnectors, 0, cleanRY, 0)
        self:_updateBezierBones(seg)
        self:_terrainClampBones(seg)
        table.insert(self.segments, seg)
        if g_slurryPipeManager ~= nil then
            table.insert(g_slurryPipeManager.chainTerminusEntries, seg.chainCoupling)
        end

        -- Segment 1 only: recreate chainStartCoupling at detNode01 (start of pipe)
        -- so the saved bez connection can be restored by tryResolvePendingConnections.
        -- Do NOT auto-connect here — the saved connection handles that.
        if i == 1 and g_slurryPipeManager ~= nil then
            local detNode01 = seg.detNode01
            if detNode01 ~= nil and detNode01 ~= 0 then
                local startCoupling = {
                    id                       = -2,
                    mountNode                = detNode01,
                    arcNode                  = nil,
                    isConnected              = false,
                    valveOpen                = false,
                    connectedTarget          = nil,
                    connectedPartnerCoupling = nil,
                    pipeId                   = nil,
                    isChainTerminus          = true,
                    chain                    = self,
                    segmentIndex             = 0,
                    sourceEntry              = self.anchorCoupling and self.anchorCoupling.sourceEntry or nil,
                    placeable                = self.anchorCoupling and self.anchorCoupling.placeable or nil,
                    isChainStart             = true,
                }
                seg.chainStartCoupling = startCoupling
                table.insert(g_slurryPipeManager.chainTerminusEntries, startCoupling)
            end
        end

        -- Primary activatable at pipeRoot (remove from here)
        local activatable = SPSChainActivatable.new(self, #self.segments)
        g_currentMission.activatableObjectsSystem:addActivatable(activatable)
        seg.activatable = activatable
        -- End activatable at detNode04 (lay more / DS) — only for the last segment
        local endActivatable = SPSChainActivatable.new(self, #self.segments)
        endActivatable.isEndActivatable = true
        g_currentMission.activatableObjectsSystem:addActivatable(endActivatable)
        seg.endActivatable = endActivatable
        nextX, nextY, nextZ = segData.x, segData.y, segData.z
        local ndx = segData.x - p0x
        local ndz = segData.z - p0z
        local nlen = math.sqrt(ndx*ndx + ndz*ndz)
        nextRY = nlen > 0.001 and math.atan2(-ndx / nlen, -ndz / nlen) or nextRY

        if i < #data.segments then
            if seg.endActivatable ~= nil then
                seg.endActivatable:delete()
                seg.endActivatable = nil
            end
        end
    end
    if data.hasDockingStation then
        self:_restoreDockingStation(data)
    end
    SPSPipeChain.log("restoreFromSaveData: done — restored %d segment(s) ds=%s",
        #self.segments, tostring(self.dockingStation ~= nil))
end

function SPSPipeChain:_restoreDockingStation(data)
    if #self.segments == 0 then
        SPSPipeChain.log("_restoreDockingStation: ignored — no segments")
        return
    end
    local lastSeg = self.segments[#self.segments]

    SPSPipeChain.log("_restoreDockingStation: enter — restoring DS at (%.2f,%.2f,%.2f)",
        data.dsSaveX or 0, data.dsSaveY or 0, data.dsSaveZ or 0)

    local dsPath  = self.modDirectory .. "i3d/dockingStation/dockingStation.i3d"
    local i3dRoot = loadI3DFile(dsPath)
    if i3dRoot == nil or i3dRoot == 0 then
        SPSPipeChain.log("_restoreDockingStation: ERROR failed to load dockingStation.i3d")
        return
    end

    local dsNode        = getChildAt(i3dRoot, 0)
    local visShape      = getChildAt(dsNode, 0)
    local lowerNode     = getChildAt(visShape, 0)
    local upperNode     = getChildAt(visShape, 1)
    local dockingTarget = getChildAt(dsNode, 2)

    removeFromPhysics(dsNode)
    link(getRootNode(), dsNode)
    setWorldTranslation(dsNode, data.dsSaveX, data.dsSaveY, data.dsSaveZ)
    setWorldRotation(dsNode, data.dsSaveRX, data.dsSaveRY, data.dsSaveRZ)
    addToPhysics(dsNode)
    delete(i3dRoot)

    -- Save original endConnectors pos then move to dockingTarget
    local origEx, origEy, origEz    = getWorldTranslation(lastSeg.endConnectors)
    local origErx, origEry, origErz = getWorldRotation(lastSeg.endConnectors)

    local dtx, dty, dtz = getWorldTranslation(dockingTarget)
    setWorldTranslation(lastSeg.endConnectors, dtx, dty, dtz)
    self:_updateBezierBones(lastSeg)
    self:_terrainClampBones(lastSeg)

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
        -- Restore the DS-open valve state through the manager so the real
        -- anchor coupler handle is opened as well as the flow bool. Do not
        -- send a network event here; this is savegame reconstruction and the
        -- manager's coupler-animation restore pass will snap to saved time
        -- afterwards if an animation state was saved.
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:applyValveState(nil, self.anchorCoupling.id, true, self.anchorCoupling)
        else
            self.anchorCoupling.valveOpen = true
            if SPSCouplerAnimator ~= nil and self.anchorCoupling.valveAnim ~= nil then
                SPSCouplerAnimator.play(self.anchorCoupling.valveAnim, 1)
            end
        end
    end

    SPSPipeChain.log("_restoreDockingStation: done — docking station restored")
end