-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9.26

-- SPSM_Couplers.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: coupler arcs, connect/disconnect, valves, pipe-visual retry.
-- PURE RELOCATION from scripts/manager/SlurryPipeManager.lua (V1.0.0.8 tag):
-- every function body in this file is byte-identical to the baseline.
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSM_Couplers 1.0.0.9.29 loaded") end


-- Applies saved coupler animation time/direction to a registered coupling.
-- This is deliberately position-based because pipeCoupling id values repeat between
-- vehicles, placeables and chain ends.
function SlurryPipeManager:_applyPendingCouplerAnimation(coupling)
    -- SlurryPipeManager.log("_applyPendingCouplerAnimation: couplingId=%s", tostring(coupling and coupling.id))  -- [SPS] silenced: per-frame spam
    if coupling == nil or coupling.mountNode == nil or coupling.mountNode == 0 then return false end
    if self._pendingCouplerAnims == nil or SPSCouplerAnimator == nil then return false end
    if not entityExists(coupling.mountNode) then return false end

    local cx, cy, cz = getWorldTranslation(coupling.mountNode)
    local TOLERANCE_SQ = 0.1 * 0.1

    for _, entry in ipairs(self._pendingCouplerAnims) do
        if not entry.applied and entry.id == coupling.id then
            local dx, dy, dz = cx - (entry.x or 0), cy - (entry.y or 0), cz - (entry.z or 0)
            if dx*dx + dy*dy + dz*dz <= TOLERANCE_SQ then
                local function restore(slotName, inst)
                    if inst == nil then return end
                    local obj = entry.objects ~= nil and entry.objects[slotName] or nil
                    if obj ~= nil and SPSCouplerAnimator.restoreState ~= nil then
                        SPSCouplerAnimator.restoreState(inst, obj.time or 0, obj.direction or 0, obj.playing == true)
                    elseif slotName == "connector" and entry.legacyConnected ~= nil then
                        if entry.legacyConnected and SPSCouplerAnimator.setEnd ~= nil then
                            SPSCouplerAnimator.setEnd(inst)
                        elseif SPSCouplerAnimator.setStart ~= nil then
                            SPSCouplerAnimator.setStart(inst)
                        end
                    end
                end

                restore("connector", coupling.connectorAnim)
                restore("valve", coupling.valveAnim)
                entry.applied = true
                return true
            end
        end
    end
    return false
end


-- ---------------------------------------------------------------------------
-- Chain management
-- ---------------------------------------------------------------------------

-- Called by anchor SPSChainActivatable when player presses R with no pipe ahead.
-- Creates a new chain for this coupling if one doesn't exist, then lays first segment.
-- ---------------------------------------------------------------------------
-- Deployable coupling management
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onCouplingDeploy(coupling)
    SlurryPipeManager.log("onCouplingDeploy: couplingId=%s deployable=%s isDeployed=%s", tostring(coupling and coupling.id), tostring(coupling and coupling.deployable), tostring(coupling and coupling.isDeployed))
    if coupling == nil or not coupling.deployable or coupling.isDeployed then return end
    if g_server ~= nil then
        self:applyCouplingDeployState(coupling.placeable, coupling.id, true)
        SPSCouplingDeployEvent.sendEvent(coupling.placeable, coupling.id, true)
    else
        -- MP CLIENT: the server's rebroadcast excludes the originating connection
        -- (Server:broadcastEvent ignoreConnection, Server.lua), so this client would
        -- never receive its own deploy back. Apply optimistically here for immediate,
        -- correct local state; applyCouplingDeployState is client-safe (it is the same
        -- function the broadcast invokes on every receiving client).
        SlurryPipeManager.logMP(string.format("[SPS] onCouplingDeploy: client optimistic apply (placeable=%s id=%s)", tostring(coupling.placeable), tostring(coupling.id)))
        self:applyCouplingDeployState(coupling.placeable, coupling.id, true)
        SPSCouplingDeployEvent.sendEvent(coupling.placeable, coupling.id, true)
    end
    -- [SPS 1.0.0.9.29] Lid-linked coupler: open the lid alongside the deploy.
    -- Called once, on the originating machine only — vanilla setDirection routes
    -- MP (client -> AnimatedObjectEvent to server; server ticks + syncs time).
    self:_driveCouplingLid(coupling, 1)
end

function SlurryPipeManager:onCouplingUndeploy(coupling)
    SlurryPipeManager.log("onCouplingUndeploy: couplingId=%s", tostring(coupling and coupling.id))
    if coupling == nil or not coupling.deployable or not coupling.isDeployed then return end
    if coupling.isConnected then return end
    if coupling.chainActivatable ~= nil and coupling.chainActivatable.chain ~= nil then return end
    if g_server ~= nil then
        self:applyCouplingDeployState(coupling.placeable, coupling.id, false)
        SPSCouplingDeployEvent.sendEvent(coupling.placeable, coupling.id, false)
    else
        -- MP CLIENT: same sender-exclusion as onCouplingDeploy — apply optimistically.
        SlurryPipeManager.logMP(string.format("[SPS] onCouplingUndeploy: client optimistic apply (placeable=%s id=%s)", tostring(coupling.placeable), tostring(coupling.id)))
        self:applyCouplingDeployState(coupling.placeable, coupling.id, false)
        SPSCouplingDeployEvent.sendEvent(coupling.placeable, coupling.id, false)
    end
    -- [SPS 1.0.0.9.29] Lid-linked coupler: close the lid on undeploy, but only
    -- once no OTHER coupler sharing the same lid is still deployed or connected
    -- (two couplers under one lid = one shared open state).
    if not self:_lidGroupHasActive(coupling) then
        self:_driveCouplingLid(coupling, -1)
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.29] Lid-linked deployable couplers
-- A store coupling may declare deployAnimatedObjectSaveId, naming a vanilla
-- AnimatedObject in the SAME placeable's <animatedObjects> section. SPS then:
--   * drives that object open on deploy / closed on undeploy via the vanilla
--     AnimatedObject:setDirection API (client call auto-sends AnimatedObjectEvent
--     to the server; server ticks and dirty-flags time to every client — no SPS
--     sync events needed),
--   * gates connect availability on the lid being fully open (time >= threshold),
--   * locks the lid's walk-up trigger (getCanBeTriggered chain-wrap, the same
--     pattern vanilla PlaceableAnimatedObjects uses for dependencies) while any
--     linked coupler is deployed or connected.
-- Couplings without the attribute are completely unaffected.
-- ---------------------------------------------------------------------------

SPS_LID_OPEN_TIME_MIN   = 0.99  -- animation.time at/above which the lid counts as open
SPS_LID_CLOSED_TIME_MAX = 0.01  -- animation.time at/below which the lid counts as closed

-- Lazily resolves (and caches) the linked AnimatedObject for a coupling.
-- Installs the walk-up trigger lockout wrap exactly once per object.
function SlurryPipeManager:getCouplingLidObject(coupling)
    if coupling == nil or coupling.deployAnimObjectSaveId == nil then return nil end
    if coupling.deployAnimObject ~= nil then return coupling.deployAnimObject end
    if coupling.deployAnimObjectMissing then return nil end
    local placeable = coupling.placeable
    if placeable == nil or placeable.getAnimatedObjectBySaveId == nil then
        coupling.deployAnimObjectMissing = true
        return nil
    end
    local ao = placeable:getAnimatedObjectBySaveId(coupling.deployAnimObjectSaveId)
    if ao == nil then
        coupling.deployAnimObjectMissing = true
        Logging.warning("[SPS] pipeCoupling id=%s: deployAnimatedObjectSaveId '%s' not found on placeable — lid link disabled for this coupler",
            tostring(coupling.id), tostring(coupling.deployAnimObjectSaveId))
        return nil
    end
    coupling.deployAnimObject = ao
    SlurryPipeManager.log("getCouplingLidObject: resolved lid saveId=%s for couplingId=%s",
        tostring(coupling.deployAnimObjectSaveId), tostring(coupling.id))
    if not ao.spsLidLockInstalled then
        ao.spsLidLockInstalled = true
        local mgr = self
        ao.getCanBeTriggered = Utils.overwrittenFunction(ao.getCanBeTriggered, function(_, superFunc)
            if not superFunc(ao) then
                return false
            end
            -- Lid owned by SPS while any linked coupler is deployed or connected:
            -- the player must not be able to shut it on a live pipe.
            if mgr:_lidLockedByCouplings(ao) then
                return false
            end
            return true
        end)
    end
    return ao
end

-- True when the coupling either has no lid link, or its lid is fully open.
-- This is the connect/lay availability gate; safe to call for ANY coupling
-- (vehicle couplings and legacy store couplings always return true).
function SlurryPipeManager:getCouplingLidOpen(coupling)
    local ao = self:getCouplingLidObject(coupling)
    if ao == nil or ao.animation == nil then return true end
    return ao.animation.time >= SPS_LID_OPEN_TIME_MIN
end

-- Drives the lid open (dir=1) or closed (dir=-1) on the machine this is called
-- from. Vanilla setDirection handles MP routing: server raises active and ticks;
-- a client sends AnimatedObjectEvent to the server. Idempotent — driving an
-- already-open lid open again is clamped by AnimatedObject:update.
function SlurryPipeManager:_driveCouplingLid(coupling, dir)
    local ao = self:getCouplingLidObject(coupling)
    if ao == nil then return end
    SlurryPipeManager.log("_driveCouplingLid: couplingId=%s dir=%s time=%.3f",
        tostring(coupling.id), tostring(dir), ao.animation ~= nil and ao.animation.time or -1)
    ao:setDirection(dir)
end

-- True when any OTHER store coupling on the same placeable shares this
-- coupling's lid saveId and is still deployed or connected.
function SlurryPipeManager:_lidGroupHasActive(coupling)
    if coupling == nil or coupling.deployAnimObjectSaveId == nil then return false end
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.placeable == coupling.placeable and pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc ~= coupling
                and sc.deployAnimObjectSaveId == coupling.deployAnimObjectSaveId
                and (sc.isDeployed or sc.isConnected) then
                    return true
                end
            end
        end
    end
    return false
end

-- True when the given AnimatedObject is currently owned by SPS: any registered
-- store coupling resolved to it is deployed or connected. Used by the
-- getCanBeTriggered wrap to lock the walk-up trigger.
function SlurryPipeManager:_lidLockedByCouplings(ao)
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc.deployAnimObject == ao and (sc.isDeployed or sc.isConnected) then
                    return true
                end
            end
        end
    end
    return false
end

function SlurryPipeManager:applyCouplingDeployState(placeable, couplingId, isDeployed)
    SlurryPipeManager.log("applyCouplingDeployState: couplingId=%s isDeployed=%s", tostring(couplingId), tostring(isDeployed))
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.placeable == placeable then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc.id == couplingId then
                    sc.isDeployed = isDeployed
                    setVisibility(sc.mountNode, isDeployed)
                    if isDeployed then
                        addToPhysics(sc.mountNode)
                    else
                        removeFromPhysics(sc.mountNode)
                    end
                    -- Swap undeployedVisibleNodes — visible when NOT deployed
                    if sc.undeployedVisibleNodes ~= nil then
                        for _, n in ipairs(sc.undeployedVisibleNodes) do
                            setVisibility(n, not isDeployed)
                        end
                    end
                    -- On undeploy: reset anim node once so Giants animation can take back control
                    if not isDeployed and pEntry.pipeAnimNode ~= nil and pEntry.pipeAnimNode ~= 0 then
                        setRotation(pEntry.pipeAnimNode, 0, 0, 0)
                    end
                    return
                end
            end
        end
    end
end

-- [SPS MP] Apply a replicated live docking-station add/remove. Resolves the chain
-- by netId and calls the chain's own add/remove, which are deterministic from the
-- chain's synced nodes and idempotent (add: ignores if already present / no
-- segments; remove: ignores if none present). The rubberBootPort is created on
-- every peer, so a DS added on any machine becomes visible AND usable everywhere.
function SlurryPipeManager:applyDockingStationState(chainNetId, isAdd)
    local chain = self._chainsByNetId[chainNetId]
    SlurryPipeManager.logMP(string.format("[SPS MP] applyDockingStationState netId=%s isAdd=%s chain=%s",
        tostring(chainNetId), tostring(isAdd), tostring(chain ~= nil)))
    if chain == nil then return end
    if isAdd then
        chain:addDockingStation()
    else
        chain:removeDockingStation()
    end
end

function SlurryPipeManager:hasActiveCouplingConnection(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            for _, c in ipairs(entry.couplingEntries) do
                if c.isConnected and c.valveOpen then return true end
                -- [SPS 1.0.1.8] physical pipe with its far end lying in the water = water intake
                if c.valveOpen and c.physPipe ~= nil and self.physCouplingIsWaterFed ~= nil
                   and self:physCouplingIsWaterFed(c) then return true end
            end
            return false
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Arc overlap detection
-- Coupling node structure: mountNode -> child(0) = ArcsNode -> child(0) = Arc01, child(1) = Arc02
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_getCouplingArcNodes(coupling)
    -- Chain terminus: detNode01 IS the apex, its children are arc02/arc03
    if coupling.isChainTerminus then
        local apexNode = coupling.mountNode
        if apexNode == nil or apexNode == 0 or not entityExists(apexNode) then return nil, nil, nil end
        if getNumOfChildren(apexNode) < 2 then return nil, nil, nil end
        local arc1 = getChildAt(apexNode, 0)
        local arc2 = getChildAt(apexNode, 1)
        if arc1 == nil or arc1 == 0 or arc2 == nil or arc2 == 0 then return nil, nil, nil end
        if not entityExists(arc1) or not entityExists(arc2) then return nil, nil, nil end
        return apexNode, arc1, arc2
    end
    local baseNode = coupling.arcNode or coupling.mountNode
    if baseNode == nil or baseNode == 0 or not entityExists(baseNode) then return nil, nil, nil end
    if getNumOfChildren(baseNode) == 0 then return nil, nil, nil end
    -- [SPS 1.0.1.6] Prefer a DIRECT child whose name ends in "Arcs" over the
    -- positional child(0). The child(0) contract silently breaks the moment a
    -- modder nests anything else under the mount node first — field case: the
    -- Abbey 3000 added its coupler animation visuals (clamp/handle transforms)
    -- as the first children, pushing SPS_pipeCoupler01Arcs to the END of the
    -- list; connect-by-overlap died while pipe laying kept working. Name-first
    -- is order-proof; child(0) remains the fallback so every existing config
    -- (arcs at index 0, named "*Arcs" or not) resolves exactly as before.
    local arcsNode = nil
    for i = 0, getNumOfChildren(baseNode) - 1 do
        local ch = getChildAt(baseNode, i)
        local nm = ch ~= nil and ch ~= 0 and getName(ch) or nil
        if nm ~= nil and nm:sub(-4) == "Arcs" then arcsNode = ch break end
    end
    if arcsNode == nil then arcsNode = getChildAt(baseNode, 0) end
    if arcsNode == nil or arcsNode == 0 or not entityExists(arcsNode) then return nil, nil, nil end
    if getNumOfChildren(arcsNode) < 2 then return nil, nil, nil end
    local arc1 = getChildAt(arcsNode, 0)
    local arc2 = getChildAt(arcsNode, 1)
    if arc1 == nil or arc1 == 0 or arc2 == nil or arc2 == 0 then return nil, nil, nil end
    if not entityExists(arc1) or not entityExists(arc2) then return nil, nil, nil end
    return arcsNode, arc1, arc2
end

-- Returns true if the world-space point (px,pz) lies inside this coupling's own
-- arc triangle (apex, arc1, arc2). Used so the player must physically stand
-- inside a coupling's arc for that coupling to become the selected one.
-- Returns false when the coupling has no resolvable arc geometry — callers then
-- fall back to a proximity radius.
function SlurryPipeManager:isPointInCouplingArc(coupling, px, pz)
    if coupling == nil then return false end
    local apex, arc1, arc2 = self:_getCouplingArcNodes(coupling)
    if apex == nil or arc1 == nil or arc2 == nil then return false end
    if not entityExists(apex) or not entityExists(arc1) or not entityExists(arc2) then return false end
    local ax, _, az   = getWorldTranslation(apex)
    local b1x, _, b1z = getWorldTranslation(arc1)
    local b2x, _, b2z = getWorldTranslation(arc2)
    -- Same point-in-triangle test used by _arcsOverlap, triangle = (apex, arc1, arc2)
    local d1 = (px - b1x) * (az - b1z)  - (ax - b1x)  * (pz - b1z)
    local d2 = (px - b2x) * (b1z - b2z) - (b1x - b2x) * (pz - b2z)
    local d3 = (px - ax)  * (b2z - az)  - (b2x - ax)  * (pz - az)
    local hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    local hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (hasNeg and hasPos)
end

function SlurryPipeManager:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B)
    -- Validate all nodes exist before accessing them
    if not entityExists(apexA) or not entityExists(arc1A) or not entityExists(arc2A) then return false end
    if not entityExists(apexB) or not entityExists(arc1B) or not entityExists(arc2B) then return false end
    
    local function pointInTri(px, pz, ax, az, bx, bz, cx, cz)
        local d1 = (px-bx)*(az-bz) - (ax-bx)*(pz-bz)
        local d2 = (px-cx)*(bz-cz) - (bx-cx)*(pz-cz)
        local d3 = (px-ax)*(cz-az) - (cx-ax)*(pz-az)
        local hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0)
        local hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0)
        return not (hasNeg and hasPos)
    end
    local function segmentsIntersect(ax, az, bx, bz, cx, cz, dx, dz)
        local d1x, d1z = bx - ax, bz - az
        local d2x, d2z = dx - cx, dz - cz
        local cross = d1x * d2z - d1z * d2x
        if math.abs(cross) < 1e-8 then return false end
        local tx = ((cx - ax) * d2z - (cz - az) * d2x) / cross
        local ux = ((cx - ax) * d1z - (cz - az) * d1x) / cross
        return tx >= 0 and tx <= 1 and ux >= 0 and ux <= 1
    end
    local aax, _, aaz = getWorldTranslation(apexA)
    local a1x, _, a1z = getWorldTranslation(arc1A)
    local a2x, _, a2z = getWorldTranslation(arc2A)
    local abx, _, abz = getWorldTranslation(apexB)
    local b1x, _, b1z = getWorldTranslation(arc1B)
    local b2x, _, b2z = getWorldTranslation(arc2B)
    local bInA = pointInTri(abx,abz,aax,aaz,a1x,a1z,a2x,a2z)
             or  pointInTri(b1x,b1z,aax,aaz,a1x,a1z,a2x,a2z)
             or  pointInTri(b2x,b2z,aax,aaz,a1x,a1z,a2x,a2z)
    local aInB = pointInTri(aax,aaz,abx,abz,b1x,b1z,b2x,b2z)
             or  pointInTri(a1x,a1z,abx,abz,b1x,b1z,b2x,b2z)
             or  pointInTri(a2x,a2z,abx,abz,b1x,b1z,b2x,b2z)
    if bInA or aInB then return true end
    local edgesA = {{aax,aaz,a1x,a1z},{aax,aaz,a2x,a2z},{a1x,a1z,a2x,a2z}}
    local edgesB = {{abx,abz,b1x,b1z},{abx,abz,b2x,b2z},{b1x,b1z,b2x,b2z}}
    for _, ea in ipairs(edgesA) do
        for _, eb in ipairs(edgesB) do
            if segmentsIntersect(ea[1],ea[2],ea[3],ea[4],eb[1],eb[2],eb[3],eb[4]) then
                return true
            end
        end
    end
    return false
end

-- Returns the first coupling whose arc overlaps with the given coupling.
-- Checks both vehicle couplings and placeable store couplings.
-- ---------------------------------------------------------------------------
-- Check if any coupling exists within specified distance (simple presence check)
-- Used for extended zone checks when starting chain laying
-- ---------------------------------------------------------------------------
function SlurryPipeManager:hasNearbyCoupling(coupling, maxDistance)
    if coupling == nil then return false end
    
    local apexA = coupling.mountNode
    if apexA == nil or not entityExists(apexA) then return false end
    
    local ax, ay, az = getWorldTranslation(apexA)
    
    -- Check vehicle couplings.
    -- Skip the vehicle that owns `coupling` entirely. A tanker's own couplers
    -- (and any duplicate-registered couplers sharing a mount node on the same
    -- vehicle, e.g. config-gated entries that both resolved) sit within the
    -- radius of each other and must never block that vehicle from laying.
    for _, vEntry in ipairs(self.registeredVehicles) do
        local ownsCoupling = false
        for _, vc in ipairs(vEntry.couplingEntries) do
            if vc == coupling then ownsCoupling = true break end
        end
        if not ownsCoupling then
            for _, vc in ipairs(vEntry.couplingEntries) do
                local apexB = vc.mountNode
                if apexB ~= nil and entityExists(apexB) then
                    local bx, by, bz = getWorldTranslation(apexB)
                    local dist = MathUtil.vector3Length(ax-bx, ay-by, az-bz)
                    if dist <= maxDistance then
                        SlurryDebug.log(string.format(
                            "hasNearbyCoupling: coupling id=%s blocked by foreign vehicle coupler id=%s dist=%.2f",
                            tostring(coupling.id), tostring(vc.id), dist))
                        return true
                    end
                end
            end
        end
    end
    
    -- Check placeable couplings
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc ~= coupling and (coupling.placeable == nil or sc.placeable ~= coupling.placeable) then
                    local apexB = sc.mountNode
                    if apexB ~= nil and entityExists(apexB) then
                        local bx, by, bz = getWorldTranslation(apexB)
                        local dist = MathUtil.vector3Length(ax-bx, ay-by, az-bz)
                        if dist <= maxDistance then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    -- Check chain terminus couplings
    for _, ct in ipairs(self.chainTerminusEntries) do
        if ct ~= coupling then
            local apexB = ct.mountNode
            if apexB ~= nil and entityExists(apexB) then
                local bx, by, bz = getWorldTranslation(apexB)
                local dist = MathUtil.vector3Length(ax-bx, ay-by, az-bz)
                if dist <= maxDistance then
                    return true
                end
            end
        end
    end
    
    return false
end

-- ---------------------------------------------------------------------------
-- Find first overlapping coupling within connection distance
-- ---------------------------------------------------------------------------
function SlurryPipeManager:findOverlappingCoupler(coupling)
    -- SlurryPipeManager.log("findOverlappingCoupler: from couplingId=%s", tostring(coupling and coupling.id))  -- [SPS] silenced: per-frame spam
    -- Already connected — no new connection possible
    if coupling.isConnected then return nil end
    local apexA, arc1A, arc2A = self:_getCouplingArcNodes(coupling)
    if apexA == nil or not entityExists(apexA) then return nil end

    local apexAx, apexAy, apexAz = getWorldTranslation(apexA)

    -- Multiple couplers on the same vehicle/placeable can have overlapping arcs
    -- (e.g. two store couplers ~0.8m apart with deep arc triangles). Returning the
    -- first overlap in registration order biases every connection to the lowest id.
    -- Instead, among all arc-overlapping couplers within range, pick the one whose
    -- apex is closest to this coupling's apex — that is the coupler the player
    -- physically aligned with. Category priority is preserved: an overlapping
    -- vehicle coupler wins over a placeable coupler, which wins over a chain
    -- terminus (matching the original ordering of these blocks).
    local bestVc     = nil
    local bestVcDist = math.huge
    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, vc in ipairs(vEntry.couplingEntries) do
            if vc ~= coupling and not vc.isConnected then
                -- Skip if this coupling is a chain anchor with active segments
                local hasChain = false
                for _, chain in ipairs(self.pipeChains) do
                    if chain.anchorCoupling == vc and #chain.segments > 0 then
                        hasChain = true
                        break
                    end
                end
                if not hasChain then
                    local apexB, arc1B, arc2B = self:_getCouplingArcNodes(vc)
                    if apexB ~= nil and entityExists(apexB) then
                        local bx, by, bz = getWorldTranslation(apexB)
                        local d = MathUtil.vector3Length(apexAx-bx, apexAy-by, apexAz-bz)
                        if d <= SPS_MAX_CONNECT_DIST then
                            if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                                if d < bestVcDist then
                                    bestVcDist = d
                                    bestVc     = vc
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if bestVc ~= nil then return bestVc end

    local bestSc     = nil
    local bestScDist = math.huge
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc ~= coupling
                and (coupling.placeable == nil or sc.placeable ~= coupling.placeable)
                and not sc.isConnected
                and (not sc.deployable or sc.isDeployed)
                -- [SPS 1.0.0.9.29] Lid-linked coupler is only connectable while
                -- its lid is fully open (no lid link = always true).
                and self:getCouplingLidOpen(sc) then
                    -- Skip if this coupling is a chain anchor with active segments
                    local hasChain = false
                    for _, chain in ipairs(self.pipeChains) do
                        if chain.anchorCoupling == sc and #chain.segments > 0 then
                            hasChain = true
                            break
                        end
                    end
                    if not hasChain then
                        local apexB, arc1B, arc2B = self:_getCouplingArcNodes(sc)
                        if apexB ~= nil and entityExists(apexB) then
                            local bx, by, bz = getWorldTranslation(apexB)
                            local d = MathUtil.vector3Length(apexAx-bx, apexAy-by, apexAz-bz)
                            if d <= SPS_MAX_CONNECT_DIST then
                                if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                                    if d < bestScDist then
                                        bestScDist = d
                                        bestSc     = sc
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if bestSc ~= nil then return bestSc end

    -- Chain terminus arcs — laid pipe ends a vehicle can connect to
    -- Pick the closest overlapping terminus within maxPipeLength
    local bestCt   = nil
    local bestDist = math.huge
    local apexAx, _, apexAz = getWorldTranslation(apexA)
    for _, ct in ipairs(self.chainTerminusEntries) do
        if ct ~= coupling and not ct.isConnected then
            local isOwnChain
            if ct.isChainStart then
                if ct.chain ~= nil and ct.chain.anchorCoupling == coupling then
                    -- This coupling is the current anchor — block if already connected
                    -- or if it's a placeable (placeables don't reconnect)
                    isOwnChain = coupling.placeable ~= nil or ct.isConnected
                elseif ct.chain ~= nil and ct.chain.anchorCoupling ~= nil then
                    -- 1.0.0.9.26: chain is anchored elsewhere — it is IN SERVICE.
                    -- Anchoring never sets isConnected on the start terminus, so
                    -- without this it reads as free, attracts connections, and
                    -- suppresses nearby anchors' lay prompts (field report: could
                    -- not start the sep OUT pipe beside the anchored IN chain).
                    -- Free-standing chains (anchorCoupling == nil) keep the
                    -- pick-up behaviour in the branch below, unchanged.
                    isOwnChain = true
                else
                    -- Chain start is disconnected — any vehicle coupling may pick it up.
                    -- Only block placeable couplings from connecting to a chain start.
                    isOwnChain = coupling.placeable ~= nil
                end
            else
                -- chainEnd: skip if caller is the own chain anchor
                isOwnChain = ct.chain ~= nil and ct.chain.anchorCoupling == coupling
                -- 1.0.0.9.26: only the FINAL segment's terminus is a valid connect
                -- target ("laid pipe ends a vehicle can connect to"); mid-chain
                -- joints must neither attract connections nor suppress nearby lay
                -- prompts when their arcs overlap.
                if not isOwnChain and ct.chain ~= nil and ct.chain.segments ~= nil then
                    local lastSeg = ct.chain.segments[#ct.chain.segments]
                    local lastCc  = lastSeg ~= nil and lastSeg.chainCoupling or nil
                    if lastCc ~= nil and lastCc ~= ct then
                        isOwnChain = true
                    end
                end
            end
            if not isOwnChain then
                local apexB, arc1B, arc2B = self:_getCouplingArcNodes(ct)
                if apexB ~= nil and entityExists(apexB) then
                    if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                        local bx, _, bz = getWorldTranslation(apexB)
                        local d = MathUtil.vector3Length(apexAx - bx, 0, apexAz - bz)
                        if d < bestDist then
                            bestDist = d
                            bestCt   = ct
                        end
                    end
                end
            end
        end
    end
    if bestCt ~= nil then return bestCt end

    return nil
end

function SlurryPipeManager:_findCouplingOwner(coupling)
    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, c in ipairs(vEntry.couplingEntries) do
            if c == coupling then return vEntry.vehicle, nil end
        end
    end
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc == coupling then return nil, pEntry.placeable end
            end
        end
    end
    return nil, nil
end

function SlurryPipeManager:_findCouplingById(vehicleOrPlaceable, couplingId, isPlaceable)
    if not isPlaceable then
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.vehicle == vehicleOrPlaceable then
                for _, c in ipairs(vEntry.couplingEntries) do
                    if c.id == couplingId then return c end
                end
            end
        end
    else
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.placeable == vehicleOrPlaceable then
                if pEntry.storeCouplings ~= nil then
                    for _, sc in ipairs(pEntry.storeCouplings) do
                        if sc.id == couplingId then return sc end
                    end
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Coupling connect / disconnect / valve handlers
-- Called from SPSPipeActivatable. Authority check here.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onCouplerConnect(vehicle, coupling)
    SlurryPipeManager.log("onCouplerConnect: %s couplingId=%s server=%s", tostring(vehicle and vehicle.configFileName), tostring(coupling and coupling.id), tostring(g_server ~= nil))
    if g_server == nil then
        local otherCoupling = self:findOverlappingCoupler(coupling)
        if otherCoupling == nil then return end
        if coupling.isConnected or otherCoupling.isConnected then return end
        -- [SPS MP] Chain terminus: address by (netId + role), not raw id.
        if otherCoupling.isChainTerminus and otherCoupling.chain ~= nil then
            self:_handleChainTerminusConnect(coupling, otherCoupling, vehicle)
            return
        end
        local ownerA = vehicle or coupling.placeable
        local tVeh, tPl = self:_findCouplingOwner(otherCoupling)
        local ownerB = tVeh or tPl
        local targetType = tVeh ~= nil
            and SlurryPipeConnectEvent.TARGET_TYPE_VEHICLE
            or  SlurryPipeConnectEvent.TARGET_TYPE_PLACEABLE
        self:applyConnectCouplings(coupling, otherCoupling, ownerA, ownerB)
        SlurryPipeConnectEvent.sendEvent(vehicle or ownerA, ownerB, targetType, coupling.id, otherCoupling.id)
        return
    end

    local otherCoupling = self:findOverlappingCoupler(coupling)
    if otherCoupling == nil then
        return
    end

--    print("[SPS TRACE] ===== onCouplerConnect (player activated) =====")
    self:_traceCoupling("onCouplerConnect.coupling(activated)", coupling)
    self:_traceCoupling("onCouplerConnect.otherCoupling(found)", otherCoupling)

    -- Both couplers must be free to connect
    if coupling.isConnected then
        return
    end
    if otherCoupling.isConnected then
        return
    end

    -- [SPS MP] Chain terminus: address by (netId + role), not raw id.
    if otherCoupling.isChainTerminus and otherCoupling.chain ~= nil then
        self:_handleChainTerminusConnect(coupling, otherCoupling, vehicle)
        return
    end

    -- Determine owners — vehicle is nil when coupling is on a placeable
    local ownerA = vehicle or coupling.placeable
    local targetVehicle, targetPlaceable = self:_findCouplingOwner(otherCoupling)
    local ownerB = targetVehicle or targetPlaceable

    local targetType = targetVehicle ~= nil
        and SlurryPipeConnectEvent.TARGET_TYPE_VEHICLE
        or  SlurryPipeConnectEvent.TARGET_TYPE_PLACEABLE

    -- Apply directly using coupling objects — no ID lookup needed on this machine
    self:applyConnectCouplings(coupling, otherCoupling, ownerA, ownerB)

    -- Broadcast for MP (vehicle may be nil for placeable-initiated connections)
    SlurryPipeConnectEvent.sendEvent(vehicle or ownerA, ownerB, targetType, coupling.id, otherCoupling.id)
end

-- [SPS HOSE step 2b/3] The one place that decides which visual draws a coupler-to-coupler
-- hose. New physical hoses (SPSHoseVisual) when the live switch is on and the class is
-- loaded - chain termini included (step 3): a chain end node (old mesh or new proxy) has the
-- same axis convention as a coupler outNode and a chain start the same as an inNode, and the
-- end-piece visibility fix-ups after creation read inst.endConnectors, which a hose instance
-- does not have. Otherwise the old SPSPipeVisual exactly as before. Hose instances carry
-- isHose, so the shared updatePipe/destroyPipe/applyColor calls in SlurryPipeManager delegate.
function SlurryPipeManager:_createCouplerVisual(nodeA, nodeB, startConnType, endConnType, leadCoupling, followCoupling)
    -- [SPS 1.0.1.8] A bought PHYSICAL pipe plugged into either coupling IS the hose: draw nothing.
    if (leadCoupling ~= nil and leadCoupling.physPipe ~= nil) or (followCoupling ~= nil and followCoupling.physPipe ~= nil) then
        return nil
    end
    local chainInvolved = (leadCoupling ~= nil and (leadCoupling.isChainTerminus or leadCoupling.isChainStart))
                       or (followCoupling ~= nil and (followCoupling.isChainTerminus or followCoupling.isChainStart))
    local reason = nil
    if SPSHoseVisual == nil then reason = "hose class missing"
    elseif not SPSHoseVisual.LIVE then reason = "spsHoseLive is OFF"
    elseif g_spsHoseVisual == nil or not g_spsHoseVisual:isReady() then reason = "hose class not ready yet"
    end
    if reason == nil then
        local inst = g_spsHoseVisual:createSlurryHose(nodeA, nodeB, startConnType, endConnType)
        if inst ~= nil then return inst end
        reason = "createSlurryHose failed (see the [SPS HOSE] error above)"
    end
    -- Always logged (not channel-gated), the counterpart of the "[SPS HOSE] LIVE:" line, so the
    -- log always says which visual a coupler connection got and why (William 2026-10-13).
    print(string.format("[SPS HOSE] OLD bez pipe used for coupler connection A.id=%s B.id=%s (chain involved=%s): %s",
        tostring(leadCoupling and leadCoupling.id), tostring(followCoupling and followCoupling.id), tostring(chainInvolved), reason))
    return g_spsPipeVisual:createPipe(nodeA, nodeB, startConnType, endConnType, false, false)
end

-- applyConnectCouplings — called locally with the actual coupling objects.
-- Avoids the ID lookup ambiguity that breaks placeable-initiated connections.
function SlurryPipeManager:applyConnectCouplings(couplingA, couplingB, ownerA, ownerB)
    SlurryPipeManager.log("applyConnectCouplings: A.id=%s B.id=%s", tostring(couplingA and couplingA.id), tostring(couplingB and couplingB.id))
    SlurryPipeManager.logMP(string.format("[SPS MP] applyConnectCouplings ENTER A.id=%s B.id=%s server=%s pipeVisual=%s pipeReady=%s",
        tostring(couplingA and couplingA.id), tostring(couplingB and couplingB.id), tostring(g_server ~= nil),
        tostring(g_spsPipeVisual ~= nil),
        tostring(g_spsPipeVisual ~= nil and g_spsPipeVisual:isReady())))
--    print("[SPS TRACE] ===== applyConnectCouplings =====")
    self:_traceCoupling("applyConnect.couplingA", couplingA)
    self:_traceCoupling("applyConnect.couplingB", couplingB)
    couplingA.isConnected              = true
    couplingA.connectedTarget          = ownerB
    couplingA.connectedPartnerCoupling = couplingB

    couplingB.isConnected              = true
    couplingB.connectedTarget          = ownerA
    couplingB.connectedPartnerCoupling = couplingA

    -- If a vehicle coupling is connecting to a chainStartCoupling, re-anchor the chain
    -- to the new vehicle coupling so any coupling on the tanker can own the chain.
    local function reAnchorIfNeeded(vehicleCoupling, chainStartCoupling)
        if chainStartCoupling == nil or not chainStartCoupling.isChainStart then return end
        if chainStartCoupling.chain == nil then return end
        local chain = chainStartCoupling.chain
        local oldAnchor = chain.anchorCoupling
        if oldAnchor == vehicleCoupling then return end
        if oldAnchor ~= nil and oldAnchor.chainActivatable ~= nil then
            oldAnchor.chainActivatable.chain = nil
        end
        chain.anchorCoupling = vehicleCoupling
        if vehicleCoupling.chainActivatable ~= nil then
            vehicleCoupling.chainActivatable.chain = chain
        end
        --print("[SPS] applyConnectCouplings: chain re-anchored from coupling id="
            --.. tostring(oldAnchor and oldAnchor.id) .. " to id=" .. tostring(vehicleCoupling.id))
    end
    reAnchorIfNeeded(couplingA, couplingB)
    reAnchorIfNeeded(couplingB, couplingA)

    if g_spsPipeVisual ~= nil and g_spsPipeVisual:isReady() then
        -- Determine which coupling is the lead (start of bez pipe).
        -- Default: couplingA is lead unless couplingB is a chain terminus.
        -- Chain terminus connections: chain terminus is always the lead.
        local leadCoupling, followCoupling = couplingA, couplingB
        local swapped = false
        
        -- If B is a chain terminus (not chain start), swap so chain is lead
        if couplingB.isChainTerminus and not couplingB.isChainStart then
            leadCoupling, followCoupling = couplingB, couplingA
            swapped = true
        end
        
        -- Determine connection nodes: lead uses inNode, follow uses outNode
        local nodeA = leadCoupling.inNode or leadCoupling.mountNode
        local nodeB = followCoupling.outNode or followCoupling.mountNode
        
        -- Chain segment overrides
        if leadCoupling.isChainTerminus and leadCoupling.chain ~= nil and not leadCoupling.isChainStart then
            local segs = leadCoupling.chain.segments
            if #segs > 0 then nodeA = segs[#segs].endConnectors end
        elseif leadCoupling.isChainStart and leadCoupling.chain ~= nil then
            local segs = leadCoupling.chain.segments
            if #segs > 0 then nodeA = segs[1].pipeRoot end
        end
        
        if followCoupling.isChainTerminus and followCoupling.chain ~= nil and not followCoupling.isChainStart then
            local segs = followCoupling.chain.segments
            if #segs > 0 then nodeB = segs[#segs].endConnectors end
        elseif followCoupling.isChainStart and followCoupling.chain ~= nil then
            local segs = followCoupling.chain.segments
            if #segs > 0 then nodeB = segs[1].pipeRoot end
        end
        
        local startConnType = (leadCoupling.connectorType ~= nil) and leadCoupling.connectorType or "male"
        local endConnType   = (followCoupling.connectorType ~= nil) and followCoupling.connectorType or "female"
        
        --print(string.format("[SPS] applyConnectCouplings: swapped=%s lead.isChainTerminus=%s follow.isChainTerminus=%s lead.isChainStart=%s follow.isChainStart=%s",
        --    tostring(swapped),
        --    tostring(leadCoupling.isChainTerminus), tostring(followCoupling.isChainTerminus),
        --    tostring(leadCoupling.isChainStart),    tostring(followCoupling.isChainStart)))

        -- [SPS TRACE] Which coupling ended up lead/follow, and the EXACT nodes the
        -- bez pipe will use. nodeA = pipe START (pipeRoot), nodeB = pipe END (endConnectors).
--        print(string.format("[SPS TRACE] applyConnect: LEAD id=%s (inNode used=%s) | FOLLOW id=%s (outNode used=%s)",
--            tostring(leadCoupling.id),   tostring(leadCoupling.inNode ~= nil and not (leadCoupling.isChainTerminus and leadCoupling.chain ~= nil)),
--            tostring(followCoupling.id), tostring(followCoupling.outNode ~= nil and not (followCoupling.isChainTerminus and followCoupling.chain ~= nil))))
        self:_traceNode("applyConnect.nodeA(pipe START)", nodeA)
        self:_traceNode("applyConnect.nodeB(pipe END)",   nodeB)
--        print("[SPS TRACE] applyConnect: startConnType=" .. tostring(startConnType) .. " endConnType=" .. tostring(endConnType))

        local inst = self:_createCouplerVisual(nodeA, nodeB, startConnType, endConnType, leadCoupling, followCoupling)
        SlurryPipeManager.logMP(string.format("[SPS MP] applyConnectCouplings createPipe nodeA=%s nodeB=%s inst=%s",
            tostring(nodeA), tostring(nodeB), tostring(inst ~= nil)))
        if inst ~= nil then
            local pipeId = self._nextPipeId
            self._nextPipeId = self._nextPipeId + 1
            local cr = self.currentPipeColor.r
            local cg = self.currentPipeColor.g
            local cb = self.currentPipeColor.b
            g_spsPipeVisual:applyColor(inst, cr, cg, cb)
            -- Bez pipe end connector visibility based on lead/follow
            if followCoupling.isChainStart and inst.endConnectors ~= nil then
                inst.connectorEndFlipped = true
                local femaleConn = getChildAt(inst.endConnectors, 0)
                local maleConn   = getChildAt(inst.endConnectors, 1)
                if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, true) end
                if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, false) end
            elseif followCoupling.isChainTerminus and not followCoupling.isChainStart and inst.endConnectors ~= nil then
                local femaleConn = getChildAt(inst.endConnectors, 0)
                local maleConn   = getChildAt(inst.endConnectors, 1)
                if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, false) end
                if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, true) end
            elseif leadCoupling.isChainStart and inst.startConnectors ~= nil then
                local femaleConn = getChildAt(inst.startConnectors, 0)
                local maleConn   = getChildAt(inst.startConnectors, 1)
                if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, true) end
                if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, false) end
            end
            self.activePipes[pipeId] = { inst = inst, couplingA = couplingA, couplingB = couplingB, colorR = cr, colorG = cg, colorB = cb }
            couplingA.pipeId = pipeId
            couplingB.pipeId = pipeId
        else
        end
    else
        SlurryPipeManager.logMP(string.format("[SPS MP] applyConnectCouplings: pipe visual NOT ready (visual=%s) — couplings marked connected but NO bez pipe created",
            tostring(g_spsPipeVisual ~= nil)))
        -- [SPS MP] Retry instead of dropping: queue the pair and create the visual
        -- from update() as soon as the pipe visual finishes loading.
        if self._pendingPipeVisuals == nil then self._pendingPipeVisuals = {} end
        table.insert(self._pendingPipeVisuals, { couplingA = couplingA, couplingB = couplingB })
        SlurryPipeManager.logMP(string.format("[SPS MP] applyConnectCouplings: visual QUEUED for retry (pending=%d)",
            #self._pendingPipeVisuals))
    end

    -- Play connector animations forward on both ends (no-op if not bound).
    if SPSCouplerAnimator ~= nil then
        if couplingA.connectorAnim ~= nil then SPSCouplerAnimator.play(couplingA.connectorAnim, 1) end
        if couplingB.connectorAnim ~= nil then SPSCouplerAnimator.play(couplingB.connectorAnim, 1) end
    end

end

-- [SPS MP] Create bez visuals for connect pairs that arrived before g_spsPipeVisual
-- finished its async load. Mirrors the visual-creation block in applyConnectCouplings
-- exactly (lead/follow selection, node choice, connector visibility). Entries whose
-- couplings are no longer connected to each other (disconnected in the meantime) or
-- that already gained a pipeId are dropped without creating anything.
function SlurryPipeManager:_drainPendingPipeVisuals()
    if self._pendingPipeVisuals == nil or #self._pendingPipeVisuals == 0 then return end
    if g_spsPipeVisual == nil or not g_spsPipeVisual:isReady() then return end
    local queue = self._pendingPipeVisuals
    self._pendingPipeVisuals = {}
    for _, e in ipairs(queue) do
        local couplingA, couplingB = e.couplingA, e.couplingB
        if couplingA ~= nil and couplingB ~= nil
        and couplingA.isConnected and couplingB.isConnected
        and couplingA.connectedPartnerCoupling == couplingB
        and couplingA.pipeId == nil and couplingB.pipeId == nil then
            local leadCoupling, followCoupling = couplingA, couplingB
            if couplingB.isChainTerminus and not couplingB.isChainStart then
                leadCoupling, followCoupling = couplingB, couplingA
            end
            local nodeA = leadCoupling.inNode
            if leadCoupling.isChainTerminus and leadCoupling.chain ~= nil and not leadCoupling.isChainStart then
                local segs = leadCoupling.chain.segments
                if #segs > 0 then nodeA = segs[#segs].endConnectors end
            elseif leadCoupling.isChainStart and leadCoupling.chain ~= nil then
                local segs = leadCoupling.chain.segments
                if #segs > 0 then nodeA = segs[1].pipeRoot end
            end
            local nodeB = followCoupling.outNode
            if followCoupling.isChainTerminus and followCoupling.chain ~= nil and not followCoupling.isChainStart then
                local segs = followCoupling.chain.segments
                if #segs > 0 then nodeB = segs[#segs].endConnectors end
            elseif followCoupling.isChainStart and followCoupling.chain ~= nil then
                local segs = followCoupling.chain.segments
                if #segs > 0 then nodeB = segs[1].pipeRoot end
            end
            local startConnType = (leadCoupling.connectorType ~= nil) and leadCoupling.connectorType or "male"
            local endConnType   = (followCoupling.connectorType ~= nil) and followCoupling.connectorType or "female"
            local inst = self:_createCouplerVisual(nodeA, nodeB, startConnType, endConnType, leadCoupling, followCoupling)
            SlurryPipeManager.logMP(string.format("[SPS MP] _drainPendingPipeVisuals: createPipe A.id=%s B.id=%s inst=%s",
                tostring(couplingA.id), tostring(couplingB.id), tostring(inst ~= nil)))
            if inst ~= nil then
                local pipeId = self._nextPipeId
                self._nextPipeId = self._nextPipeId + 1
                local cr = self.currentPipeColor.r
                local cg = self.currentPipeColor.g
                local cb = self.currentPipeColor.b
                g_spsPipeVisual:applyColor(inst, cr, cg, cb)
                if followCoupling.isChainStart and inst.endConnectors ~= nil then
                    inst.connectorEndFlipped = true
                    local femaleConn = getChildAt(inst.endConnectors, 0)
                    local maleConn   = getChildAt(inst.endConnectors, 1)
                    if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, true) end
                    if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, false) end
                elseif followCoupling.isChainTerminus and not followCoupling.isChainStart and inst.endConnectors ~= nil then
                    local femaleConn = getChildAt(inst.endConnectors, 0)
                    local maleConn   = getChildAt(inst.endConnectors, 1)
                    if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, false) end
                    if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, true) end
                elseif leadCoupling.isChainStart and inst.startConnectors ~= nil then
                    local femaleConn = getChildAt(inst.startConnectors, 0)
                    local maleConn   = getChildAt(inst.startConnectors, 1)
                    if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, true) end
                    if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, false) end
                end
                self.activePipes[pipeId] = { inst = inst, couplingA = couplingA, couplingB = couplingB, colorR = cr, colorG = cg, colorB = cb }
                couplingA.pipeId = pipeId
                couplingB.pipeId = pipeId
            end
        end
    end
end

function SlurryPipeManager:onCouplerDisconnect(vehicle, coupling)
    SlurryPipeManager.log("onCouplerDisconnect: %s couplingId=%s valveOpen=%s", tostring(vehicle and vehicle.configFileName), tostring(coupling and coupling.id), tostring(coupling and coupling.valveOpen))
    -- Valve must be closed
    if coupling.valveOpen then
        if g_currentMission ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_slurryCloseValveFirst"), 2000)
        end
        return
    end


    if g_server == nil then
        self:applyDisconnect(vehicle, coupling.id, coupling)
        SlurryPipeDisconnectEvent.sendEvent(vehicle, coupling.id, nil, coupling)  -- [SPS MP] pass object for chain netId keying
        return
    end

    -- Pass the coupling object directly to avoid id-ambiguity with multiple
    -- identical placeable instances that share the same coupling id numbers.
    self:applyDisconnect(vehicle, coupling.id, coupling)
    SlurryPipeDisconnectEvent.sendEvent(vehicle, coupling.id, nil, coupling)  -- [SPS MP] pass object for chain netId keying
end

-- applyDisconnect: couplingObj is the actual coupling table when available (local path).
-- The network event path passes only vehicle+couplingId, which falls back to id search.
function SlurryPipeManager:applyDisconnect(vehicle, couplingId, couplingObj)
    SlurryPipeManager.log("applyDisconnect: %s couplingId=%s", tostring(vehicle and vehicle.configFileName), tostring(couplingId))
    local coupling = couplingObj
    if coupling == nil then
        coupling = self:_findCouplingById(vehicle, couplingId, false)
        if coupling == nil then
            -- Try placeable — note: ambiguous with multiple identical placeables,
            -- but this path is only hit from the network event on remote clients.
            for _, pEntry in ipairs(self.registeredPlaceables) do
                if pEntry.storeCouplings ~= nil then
                    for _, sc in ipairs(pEntry.storeCouplings) do
                        if sc.id == couplingId then coupling = sc break end
                    end
                end
                if coupling ~= nil then break end
            end
        end
    end
    if coupling == nil then
        return
    end

    local partner = coupling.connectedPartnerCoupling

    -- [SPS 1.0.1.8] Physical pipe plugged into THIS coupling: let its end go (the partner side's
    -- end, if any, stays plugged in - one end was disconnected, not the pipe).
    if coupling.physPipe ~= nil and self._physFreeCoupling ~= nil then
        self:_physFreeCoupling(coupling)
    end

    -- Destroy pipe visual
    if coupling.pipeId ~= nil then
        local pipeData = self.activePipes[coupling.pipeId]
        if pipeData ~= nil and g_spsPipeVisual ~= nil then
            g_spsPipeVisual:destroyPipe(pipeData.inst)
            self.activePipes[coupling.pipeId] = nil
        else
        end
        coupling.pipeId = nil
        if partner ~= nil then partner.pipeId = nil end
    else
    end

    -- Stop any active flow
    if coupling.connectedTarget ~= nil and vehicle ~= nil then
        self:stopFlow(vehicle)
    end

    -- Capture valveOpen state before clearing so we know whether to play valveAnim reverse
    local wasValveOpen = (coupling.valveOpen == true) or (partner ~= nil and partner.valveOpen == true)

    -- Clear state on both ends
    coupling.isConnected             = false
    coupling.valveOpen               = false
    coupling.connectedTarget         = nil
    coupling.connectedPartnerCoupling = nil

    if partner ~= nil then
        partner.isConnected              = false
        partner.valveOpen                = false
        partner.connectedTarget          = nil
        partner.connectedPartnerCoupling = nil
        local partnerVehicle, _ = self:_findCouplingOwner(partner)
        if partnerVehicle ~= nil then self:stopFlow(partnerVehicle) end
    else
    end

    -- Free chain binding: if this disconnect breaks a vehicle/placeable coupling
    -- ↔ chainStart bez, the chain becomes a free-standing world entity. The
    -- coupling is no longer "owned by" the chain, so it can immediately lay a
    -- new first pipe or accept a new connection. Reconnect re-binds via
    -- reAnchorIfNeeded in applyConnectCouplings (handles oldAnchor == nil).
    local function freeChainBindingIfNeeded(c, p)
        if c == nil or p == nil then return end
        if not p.isChainStart then return end
        if p.chain == nil then return end
        local chain = p.chain
        if chain.anchorCoupling ~= c then return end
        -- Cache the world position so the chain saves correctly without an
        -- anchorCoupling reference (SPSPipeChain:getSaveData falls back to it).
        if c.mountNode ~= nil and c.mountNode ~= 0 and entityExists(c.mountNode) then
            chain.anchorX, chain.anchorY, chain.anchorZ = getWorldTranslation(c.mountNode)
        end
        chain.anchorCoupling = nil
        if c.chainActivatable ~= nil then c.chainActivatable.chain = nil end
    end
    freeChainBindingIfNeeded(coupling, partner)
    freeChainBindingIfNeeded(partner, coupling)

    -- Play connector animations reverse on both ends (no-op if not bound).
    -- Also play valve animations reverse if the valve was open at disconnect time —
    -- so the valve handle returns to closed regardless of which side initiates removal.
    if SPSCouplerAnimator ~= nil then
        if coupling.connectorAnim ~= nil then SPSCouplerAnimator.play(coupling.connectorAnim, -1) end
        if partner ~= nil and partner.connectorAnim ~= nil then SPSCouplerAnimator.play(partner.connectorAnim, -1) end
        if wasValveOpen then
            if coupling.valveAnim ~= nil then SPSCouplerAnimator.play(coupling.valveAnim, -1) end
            if partner ~= nil and partner.valveAnim ~= nil then SPSCouplerAnimator.play(partner.valveAnim, -1) end
        end
    end

end

function SlurryPipeManager:onValveOpen(vehicle, coupling)
    SlurryPipeManager.log("onValveOpen: %s couplingId=%s", tostring(vehicle and vehicle.configFileName), tostring(coupling and coupling.id))
    -- [SPS 1.0.1.8] a physical pipe lying free in the water counts as connected (water intake)
    if not (coupling.isConnected or (self.physCouplingIsWaterFed ~= nil and self:physCouplingIsWaterFed(coupling))) then return end
    if coupling.valveOpen then return end


    if g_server == nil then
        SlurryValveStateEvent.sendEvent(vehicle, coupling, true)
        return
    end

    self:applyValveState(vehicle, coupling.id, true, coupling)
    SlurryValveStateEvent.sendEvent(vehicle, coupling, true)

    -- Propagate through chain: if the connected partner is a chain terminus,
    -- walk to the far end and open that coupling too.
    self:_propagateValveState(coupling, true)
end

function SlurryPipeManager:onValveClose(vehicle, coupling)
    SlurryPipeManager.log("onValveClose: %s couplingId=%s", tostring(vehicle and vehicle.configFileName), tostring(coupling and coupling.id))
    -- [SPS 1.0.1.8] closing must work on a water-fed physical pipe as well (and on a stale open valve)
    if not (coupling.isConnected or coupling.physPipe ~= nil) then return end
    if not coupling.valveOpen then return end

    if g_server == nil then
        SlurryValveStateEvent.sendEvent(vehicle, coupling, false)
        return
    end

    self:applyValveState(vehicle, coupling.id, false, coupling)
    SlurryValveStateEvent.sendEvent(vehicle, coupling, false)

    -- Propagate through chain: if the connected partner is a chain terminus,
    -- walk to the far end and close that coupling too.
    self:_propagateValveState(coupling, false)
end

-- Walk a chain to find the coupling at the opposite end from the given coupling,
-- then apply and broadcast the valve state to it.
function SlurryPipeManager:_propagateValveState(coupling, open)
    SlurryPipeManager.log("_propagateValveState: couplingId=%s open=%s", tostring(coupling and coupling.id), tostring(open))
    local partner = coupling.connectedPartnerCoupling
    if partner == nil then
        return
    end


    -- Find the far-end coupling by walking: if partner is a chain terminus,
    -- get the chain, find the other terminus that is connected, open/close it.
    local farEnd = nil
    if partner.isChainTerminus and partner.chain ~= nil then
        local chain = partner.chain
        -- Walk all terminus entries for this chain looking for the connected far end
        for _, ct in ipairs(self.chainTerminusEntries) do
            if ct ~= partner and ct.chain == chain and ct.isConnected then
                farEnd = ct
                break
            end
        end
    elseif coupling.isChainTerminus and coupling.chain ~= nil then
        -- Coupling itself is a terminus — partner is the external coupler.
        -- Walk the chain from the other end.
        local chain = coupling.chain
        for _, ct in ipairs(self.chainTerminusEntries) do
            if ct ~= coupling and ct.chain == chain and ct.isConnected then
                -- ct is the far terminus — its partner is the external coupler at the other end
                if ct.connectedPartnerCoupling ~= nil then
                    farEnd = ct.connectedPartnerCoupling
                end
                break
            end
        end
    end

    if farEnd == nil then
        return
    end
    if farEnd.valveOpen == open then
        return
    end

    self:applyValveState(nil, farEnd.id, open, farEnd)
    local farVehicle, _ = self:_findCouplingOwner(farEnd)
    SlurryValveStateEvent.sendEvent(farVehicle, farEnd, open)
end

-- Force-disconnect regardless of valve state — used when vehicle is unregistered
-- or auto-disconnected by distance. Closes valve first then disconnects.
function SlurryPipeManager:_forceDisconnect(vehicle, coupling)
    SlurryPipeManager.log("_forceDisconnect: %s couplingId=%s", tostring(vehicle and vehicle.configFileName), tostring(coupling and coupling.id))
    if not coupling.isConnected then return end
    -- [SPS] Do NOT pre-close the valve here. applyDisconnect captures wasValveOpen
    -- from coupling/partner.valveOpen to decide whether to play the valve-close
    -- animation. Pre-clearing valveOpen made wasValveOpen false, so on auto-disconnect
    -- (driving beyond max pipe length) the valve handle never animated shut even
    -- though the pipe was removed — the manual walk-up disconnect, which does not
    -- pre-clear, still animated correctly. applyDisconnect already clears valveOpen on
    -- both ends and stops flow, and every guest runs the same applyDisconnect via
    -- SlurryPipeDisconnectEvent (their local valveOpen is still true), so server and
    -- clients now all animate the valve closed. This makes auto-disconnect match the
    -- manual path.
    self:applyDisconnect(vehicle, coupling.id, coupling)
    SlurryPipeDisconnectEvent.sendEvent(vehicle, coupling.id, nil, coupling)  -- [SPS MP] pass object for chain netId keying
end

function SlurryPipeManager:applyConnect(vehicleA, targetObject, targetType, couplingIdA, couplingIdB)
    SlurryPipeManager.log("applyConnect: idA=%s idB=%s targetType=%s", tostring(couplingIdA), tostring(couplingIdB), tostring(targetType))
    -- Find couplingA — vehicle may be nil if the initiator was a placeable
    local couplingA
    if vehicleA ~= nil then
        couplingA = self:_findCouplingById(vehicleA, couplingIdA, false)
        if couplingA == nil then
            -- vehicleA might actually be a placeable passed as the owner
            couplingA = self:_findCouplingById(vehicleA, couplingIdA, true)
        end
    end
    if couplingA == nil then
        -- Fallback: search all placeable store couplings by id
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.storeCouplings ~= nil then
                for _, sc in ipairs(pEntry.storeCouplings) do
                    if sc.id == couplingIdA and not sc.isConnected then
                        couplingA = sc
                        break
                    end
                end
            end
            if couplingA ~= nil then break end
        end
    end

    local couplingB
    if targetType == SlurryPipeConnectEvent.TARGET_TYPE_VEHICLE then
        couplingB = self:_findCouplingById(targetObject, couplingIdB, false)
    else
        couplingB = self:_findCouplingById(targetObject, couplingIdB, true)
    end

    SlurryPipeManager.logMP(string.format("[SPS MP] applyConnect vehicleA=%s targetObject=%s idA=%s idB=%s couplingA=%s couplingB=%s server=%s",
        tostring(vehicleA ~= nil), tostring(targetObject ~= nil),
        tostring(couplingIdA), tostring(couplingIdB),
        tostring(couplingA ~= nil), tostring(couplingB ~= nil), tostring(g_server ~= nil)))

    -- [SPS MP] Race fix: on a client the join-dump connect event can arrive BEFORE
    -- the referenced vehicles finish loading (registerVehicle not run yet, so the
    -- couplings don't exist). Instead of discarding it, queue it and let
    -- tryResolvePendingConnections() (called as each vehicle/placeable registers)
    -- re-apply it. Mirrors the savegame pendingConnections pattern. Server is
    -- authoritative and never races, so it keeps the original bail.
    if (couplingA == nil or couplingB == nil) and g_server == nil and not self._mpResolving then
        if self._pendingMPConnections == nil then self._pendingMPConnections = {} end
        table.insert(self._pendingMPConnections, {
            vehicleA     = vehicleA,
            targetObject = targetObject,
            targetType   = targetType,
            couplingIdA  = couplingIdA,
            couplingIdB  = couplingIdB,
        })
        SlurryPipeManager.logMP(string.format("[SPS MP] applyConnect QUEUED (vehicles not registered yet) idA=%s idB=%s pending=%d",
            tostring(couplingIdA), tostring(couplingIdB), #self._pendingMPConnections))
        return
    end

    if couplingA == nil or couplingB == nil then
        SlurryPipeManager.logMP("[SPS MP] applyConnect BAIL: couplingA or couplingB nil — no visual, stays disconnected")
        return
    end

    -- [SPS MP] Already connected (e.g. duplicate/echo or re-drain) — do not build a
    -- second pipe over the same couplings.
    if couplingA.isConnected or couplingB.isConnected then
        return
    end

    local ownerA = vehicleA or (couplingA.placeable)
    local ownerB = targetObject
    self:applyConnectCouplings(couplingA, couplingB, ownerA, ownerB)
end

function SlurryPipeManager:applyValveState(vehicle, couplingId, isOpen, couplingObj)
    SlurryPipeManager.log("applyValveState: %s couplingId=%s isOpen=%s", tostring(vehicle and vehicle.configFileName), tostring(couplingId), tostring(isOpen))
    -- Object-first: when caller has the coupling table, use it directly to avoid
    -- id ambiguity across multiple placeables that share coupling ids.
    local coupling = couplingObj
    local foundIn = "objectArg"
    if coupling == nil then
        coupling = self:_findCouplingById(vehicle, couplingId, false)
        foundIn = "vehicle"
    end
    if coupling == nil then
        -- Try placeable
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.storeCouplings ~= nil then
                for _, sc in ipairs(pEntry.storeCouplings) do
                    if sc.id == couplingId then coupling = sc break end
                end
            end
            if coupling ~= nil then foundIn = "placeable" break end
        end
    end
    -- Try chain terminus entries (chain start couplings have id=-2, segment chain
    -- couplings use segment-index ids — neither lives in vehicle/placeable lists)
    if coupling == nil then
        for _, ct in ipairs(self.chainTerminusEntries) do
            if ct.id == couplingId then coupling = ct foundIn = "chainTerminus" break end
        end
    end
    SlurryPipeManager.logMP(string.format("[SPS MP] applyValveState couplingId=%s isOpen=%s foundIn=%s server=%s",
        tostring(couplingId), tostring(isOpen),
        tostring(coupling ~= nil and foundIn or "NOTFOUND"), tostring(g_server ~= nil)))
    -- [SPS MP] Race fix: on a client the join-dump valve event can arrive before the
    -- coupling is registered. Queue and re-apply via _tryResolveMPPending().
    if coupling == nil and g_server == nil and not self._mpResolving then
        if self._pendingMPValves == nil then self._pendingMPValves = {} end
        table.insert(self._pendingMPValves, {
            vehicle    = vehicle,
            couplingId = couplingId,
            isOpen     = isOpen,
        })
        SlurryPipeManager.logMP(string.format("[SPS MP] applyValveState QUEUED (coupling not registered yet) couplingId=%s pending=%d",
            tostring(couplingId), #self._pendingMPValves))
        return false
    end
    if coupling == nil then
        return
    end


    coupling.valveOpen = isOpen

    -- Also sync the partner coupling valve so both ends agree
    local partner = coupling.connectedPartnerCoupling
    -- Special case: chain start couplings are linked to the placeable anchor via
    -- the chain object, not via connectedPartnerCoupling. Use the chain anchor as
    -- the effective partner so the placeable's valve handle animation fires.
    if partner == nil and coupling.isChainStart and coupling.chain ~= nil then
        partner = coupling.chain.anchorCoupling
    end
    if partner ~= nil then
        partner.valveOpen = isOpen
    end

    -- If closing, stop any active flow on both sides
    if not isOpen then
        if vehicle ~= nil then self:stopFlow(vehicle) end
        if partner ~= nil then
            local partnerVehicle, _ = self:_findCouplingOwner(partner)
            if partnerVehicle ~= nil then self:stopFlow(partnerVehicle) end
        end
    end

    -- Play valve animations (no-op if not bound).
    if SPSCouplerAnimator ~= nil then
        local dir = isOpen and 1 or -1
        if coupling.valveAnim ~= nil then
            SPSCouplerAnimator.play(coupling.valveAnim, dir)
        end
        if partner ~= nil and partner.valveAnim ~= nil then
            SPSCouplerAnimator.play(partner.valveAnim, dir)
        end
    end

    return true
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.3] Placeable detach handler — connected strap couplings.
-- Relocated 1.0.0.9.2 pre-pass: broadcast owner-keyed disconnects for every
-- live isConnected bond on the sold placeable BEFORE local teardown, so every
-- machine resolves the EXACT coupling even with duplicate ids across stores or
-- stale-generation guests. Server-only; local teardown stays in
-- unregisterPlaceable and runs on every machine's own delete hook.
-- ---------------------------------------------------------------------------
SlurryPipeManager.registerPlaceableDetachHandler("Couplers", function(mgr, placeable)
    if g_server == nil then return end
    for _, pEntry in ipairs(mgr.registeredPlaceables) do
        if pEntry.placeable == placeable and pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc.isConnected then
                    SlurryPipeDisconnectEvent.sendEvent(nil, sc.id, nil, sc)
                end
            end
        end
    end
end)
