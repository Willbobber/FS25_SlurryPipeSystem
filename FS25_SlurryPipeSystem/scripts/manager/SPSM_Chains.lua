-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9

-- SPSM_Chains.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: pipe-chain lay / rebuild / netId / anchor / terminus logic.
-- PURE RELOCATION from scripts/manager/SlurryPipeManager.lua (V1.0.0.8 tag):
-- every function body in this file is byte-identical to the baseline.
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSM_Chains 1.0.0.9.3 loaded") end


-- Called at the end of registerVehicle and registerPlaceable.
-- For each pending connection, checks if both mount nodes now exist.
-- Position match tolerance: 0.1m (positions stored as floats, no drift expected).
-- [SPS MP] Re-apply join-dump connect/valve events that were queued on a client
-- because the referenced vehicles had not registered their couplings yet. Called
-- from tryResolvePendingConnections() (which fires as each vehicle/placeable
-- registers). Connects are drained before valves so the valve's partner sync sees
-- the freshly-made connection. self._mpResolving guards against re-queuing while
-- draining. Entries that still cannot resolve are kept for the next register pass.
-- [SPS MP] Drain queued chain-state rebuilds whose anchor owner had not registered
-- when the dump arrived. For each entry whose anchor now resolves, discard the
-- free-standing copy (by netId) and rebuild the chain WITH the anchor so segment 1
-- re-links to its mount node (correct rotation) and the valve/removal link forms.
-- Entries whose owner is still absent stay queued for the next registration pass.
function SlurryPipeManager:_tryResolveChainAnchorRebinds()
    if self._pendingChainAnchorRebinds == nil then return end
    local resolved = nil
    for netId, e in pairs(self._pendingChainAnchorRebinds) do
        local anchorCoupling = self:_resolveAnchorCoupling(e.anchorObject, e.couplingId, e.isPlaceable)
        if anchorCoupling ~= nil then
            self._chainRebindResolving = true
            -- Drop the free-standing copy so the rebuild is clean (no skip, no dup).
            -- [SPS MP] Preserve any external terminus bonds already applied to the
            -- free-standing copy (join-order: a tanker can register and bond BEFORE
            -- the anchor vehicle registers and triggers this rebind). Without this
            -- the rebind's delete() severed the fresh bond — end bez vanished and
            -- the coupler reverted to "connect" on the guest.
            local preservedBonds = nil
            local existing = self._chainsByNetId[netId]
            if existing ~= nil then
                preservedBonds = self:_captureChainTerminusBonds(existing)
                for i, c in ipairs(self.pipeChains) do
                    if c == existing then table.remove(self.pipeChains, i) break end
                end
                existing:delete()
                self._chainsByNetId[netId] = nil
            end
            self:_rebuildChainFromState(netId, false, e.anchorObject, e.couplingId, e.isPlaceable, e.payload)
            if preservedBonds ~= nil then
                self:_reapplyChainTerminusBonds(self._chainsByNetId[netId], preservedBonds)
            end
            self._chainRebindResolving = false
            SlurryPipeManager.logMP(string.format(
                "[SPS MP] chain anchor rebind RESOLVED netId=%s", tostring(netId)))
            if resolved == nil then resolved = {} end
            table.insert(resolved, netId)
        end
    end
    if resolved ~= nil then
        for _, netId in ipairs(resolved) do
            self._pendingChainAnchorRebinds[netId] = nil
        end
    end
end

function SlurryPipeManager:onChainStartLaying(coupling, anchorActivatable)
    SlurryPipeManager.log("onChainStartLaying: couplingId=%s", tostring(coupling and coupling.id))
    if coupling == nil then return end
    --print("[SPS TRACE] ===== onChainStartLaying =====")
    self:_traceCoupling("onChainStartLaying.coupling", coupling)
    local chain = nil
    for _, c in ipairs(self.pipeChains) do
        if c.anchorCoupling == coupling then chain = c break end
    end
    if chain == nil then
        chain = SPSPipeChain.new(coupling, self.modDirectory)
        table.insert(self.pipeChains, chain)
    end
    if anchorActivatable ~= nil then
        anchorActivatable.chain = chain
    end

    -- [SPS] Chain first pipe links to the coupler's inNode (the pipe port for an
    -- incoming strap pipe). The parent mountNode (e.g. SPS_pipeCoupler01) is the
    -- proximity/arc anchor, not the pipe port — starting there put the first
    -- segment at the wrong node. Fall back to mountNode when no inNode is
    -- authored so legacy couplers without in/out children still work.
    local startNode = coupling.inNode or coupling.mountNode
    SlurryPipeManager.log("onChainStartLaying: startNode=%s (inNode=%s mountNode=%s)",
        tostring(startNode), tostring(coupling.inNode), tostring(coupling.mountNode))

    local mx, my, mz = getWorldTranslation(startNode)
    local fdx, _, fdz = localDirectionToWorld(startNode, 0, 0, -1)
    local mry = math.atan2(-fdx, -fdz)

    -- Vehicle coupling: start chain 3.5m ahead so the tanker can drive away
    -- and the chain stays independent. Player walks to that point.
    -- Placeable coupling: start chain directly at coupling (placeable never moves).
    local vehicle, _ = self:_findCouplingOwner(coupling)
    if vehicle ~= nil then
        local sx = mx + fdx * 3.5
        local sz = mz + fdz * 3.5
        local sy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, sx, 0, sz) + 0.05
        chain:startLaying(sx, sy, sz, mry)
    else
        chain:startLaying(mx, my, mz, mry, startNode)
    end

    -- Play connector animation forward on the anchor coupling (no-op if not bound).
    if SPSCouplerAnimator ~= nil and coupling.connectorAnim ~= nil then
        SPSCouplerAnimator.play(coupling.connectorAnim, 1)
    end
end

-- ===========================================================================
-- [SPS MP] Live-laying preview replication
-- ===========================================================================

-- [SPS MP] Called by SPSPipeChain:startLaying whenever a NEW live segment begins
-- on this peer (first segment AND every lay-more). Allocates a netId on first use
-- (server) and broadcasts START so the new segment previews on all peers.
function SlurryPipeManager:onChainLiveSegmentStarted(chain)
    if chain == nil or chain.liveSegment == nil then return end
    if chain.isRemoteLive then return end  -- preview chains never originate START
    local seg = chain.liveSegment
    local anchorObject, acid, isPl = self:_getChainAnchorDescriptor(chain)
    if g_server ~= nil and chain.netId == nil then
        chain.netId = self:_allocChainNetId()
        self._chainsByNetId[chain.netId] = chain
    end
    SlurryPipeManager.logMP(string.format("[SPS MP] liveSegmentStarted START netId=%s server=%s segs=%d",
        tostring(chain.netId), tostring(g_server ~= nil), #chain.segments))
    SPSChainLiveEvent.sendStart(chain.netId or 0, anchorObject, acid, isPl,
        seg.startX, seg.startY, seg.startZ, seg.startRY or 0)
end

-- A peer receives START. The originator (its own local laying chain) just adopts
-- the netId. Every other peer adds a preview live segment: to a new chain for the
-- first segment, or to the existing chain (with committed segments) for lay-more.
function SlurryPipeManager:applyChainLiveStart(netId, anchorObject, couplingId, isPlaceable, sx, sy, sz, sry)
    local anchorCoupling = self:_resolveAnchorCoupling(anchorObject, couplingId, isPlaceable)
    -- Originator: local laying chain (has a live segment, not a remote preview).
    for _, c in ipairs(self.pipeChains) do
        if c.liveSegment ~= nil and not c.isRemoteLive and c.anchorCoupling == anchorCoupling then
            c.netId = netId
            self._chainsByNetId[netId] = c
            SlurryPipeManager.logMP(string.format("[SPS MP] applyChainLiveStart ADOPT netId=%s", tostring(netId)))
            return
        end
    end
    -- Remote peer: find the existing chain for this netId (lay-more) or create one.
    local chain = self._chainsByNetId[netId]
    if chain == nil then
        chain = SPSPipeChain.new(anchorCoupling, self.modDirectory)
        chain.netId = netId
        self._chainsByNetId[netId] = chain
        table.insert(self.pipeChains, chain)
    end
    -- If a preview live segment already exists for this chain, leave it.
    if chain.liveSegment ~= nil then return end
    chain.isRemoteLive = true
    -- startLaying links to the previous committed segment when #segments > 0
    -- (lay-more), or starts at sx/sy/sz for the first segment.
    -- [SPS MP] First-segment preview: pass the SAME anchor start node the layer
    -- uses (inNode, mountNode fallback — mirrors onChainStartLaying). Without it
    -- the remote preview built free-standing, so the start coupler floated in a
    -- raised position on other machines until the finalise commit rebuilt the
    -- segment node-linked and it visibly snapped down.
    local localStartNode = nil
    if #chain.segments == 0 and anchorCoupling ~= nil then
        local n = anchorCoupling.inNode
        if n == nil or n == 0 or (entityExists ~= nil and not entityExists(n)) then
            n = anchorCoupling.mountNode
        end
        if n ~= nil and n ~= 0 and (entityExists == nil or entityExists(n)) then
            localStartNode = n
        end
    end
    chain:startLaying(sx, sy, sz, sry, localStartNode)
    SlurryPipeManager.logMP(string.format("[SPS MP] applyChainLiveStart PREVIEW netId=%s segs=%d", tostring(netId), #chain.segments))
end

-- A remote preview's end position update — sets an interpolation target; the
-- preview lerps toward it each frame in SPSPipeChain:update for smooth motion.
function SlurryPipeManager:applyChainLivePos(netId, ex, ey, ez)
    local chain = self._chainsByNetId[netId]
    if chain == nil or not chain.isRemoteLive then return end
    chain:setRemoteLiveTarget(ex, ey, ez)
end

-- Laying aborted: remove the remote preview (never a committed chain).
function SlurryPipeManager:applyChainLiveCancel(netId)
    local chain = self._chainsByNetId[netId]
    if chain == nil or not chain.isRemoteLive then return end
    for i, c in ipairs(self.pipeChains) do
        if c == chain then table.remove(self.pipeChains, i) break end
    end
    chain:delete()
    self._chainsByNetId[netId] = nil
    SlurryPipeManager.logMP(string.format("[SPS MP] applyChainLiveCancel removed preview netId=%s", tostring(netId)))
end

-- Keep old name as alias for compatibility
function SlurryPipeManager:onChainLayPipe(coupling, anchorActivatable)
    SlurryPipeManager.log("onChainLayPipe: couplingId=%s", tostring(coupling and coupling.id))
    self:onChainStartLaying(coupling, anchorActivatable)
end

-- Called by anchor SPSChainActivatable after all segments removed.
-- Removes the empty chain from the manager.
function SlurryPipeManager:onChainEmpty(chain, coupling)
    SlurryPipeManager.log("onChainEmpty: couplingId=%s", tostring(coupling and coupling.id))
    -- Play connector animation reverse on the anchor coupling (no-op if not bound).
    if SPSCouplerAnimator ~= nil and coupling ~= nil and coupling.connectorAnim ~= nil then
        SPSCouplerAnimator.play(coupling.connectorAnim, -1)
    end
    -- [SPS MP] capture netId before teardown so removal can be replicated.
    local netId = chain ~= nil and chain.netId or nil
    -- [SPS MP] Stale-pointer recovery: across JIP rebuild generations (anchor
    -- rebind, state echoes) an anchor activatable can end up holding a live chain
    -- OBJECT that is not the netId-mapped one (netId=nil). commitChainRemoval(nil)
    -- silently returns and the removal never reaches the server — the last
    -- placeable-laid segment stayed visible on every other machine. Recover the
    -- netId from the authoritative map: first by object identity, then by anchor
    -- coupling match. Any distinct mapped duplicate for that anchor is torn down
    -- too so no orphan object lingers.
    if netId == nil and self._chainsByNetId ~= nil then
        -- Match by table identity first, then by (placeable + coupling id):
        -- a placeable can register more than once, producing a second generation
        -- of coupling tables; identity comparison alone then finds nothing.
        local function anchorsMatch(a, b)
            if a == b then return a ~= nil end
            if a == nil or b == nil then return false end
            return a.placeable ~= nil and a.placeable == b.placeable and a.id == b.id
        end
        for id, c in pairs(self._chainsByNetId) do
            if c == chain then
                netId = id
                break
            end
        end
        if netId == nil and coupling ~= nil then
            for id, c in pairs(self._chainsByNetId) do
                if c ~= nil and anchorsMatch(c.anchorCoupling, coupling) then
                    netId = id
                    if c ~= chain then
                        -- Duplicate object for the same anchor: remove it as well.
                        for i, pc in ipairs(self.pipeChains) do
                            if pc == c then table.remove(self.pipeChains, i) break end
                        end
                        c:delete()
                    end
                    break
                end
            end
        end
        if netId == nil and coupling ~= nil and self.pipeChains ~= nil then
            -- Final fallback: the map can desync from pipeChains across rebuild
            -- generations; any netId-carrying chain anchored here is authoritative.
            for _, c in ipairs(self.pipeChains) do
                if c ~= chain and c.netId ~= nil and anchorsMatch(c.anchorCoupling, coupling) then
                    netId = c.netId
                    for i, pc in ipairs(self.pipeChains) do
                        if pc == c then table.remove(self.pipeChains, i) break end
                    end
                    if self._chainsByNetId ~= nil then self._chainsByNetId[c.netId] = nil end
                    c:delete()
                    break
                end
            end
        end
        SlurryPipeManager.logMP(string.format(
            "[SPS MP] onChainEmpty netId RECOVERED=%s (object netId was nil)", tostring(netId)))
    end
    SlurryPipeManager.logMP(string.format("[SPS MP] onChainEmpty capturedNetId=%s", tostring(netId)))
    for i, c in ipairs(self.pipeChains) do
        if c == chain then
            chain:delete()
            table.remove(self.pipeChains, i)
            if netId ~= nil then self._chainsByNetId[netId] = nil end
            self:commitChainRemoval(netId)
            return
        end
    end
    self:commitChainRemoval(netId)
end

-- ===========================================================================
-- [SPS MP] Chain state replication
-- ---------------------------------------------------------------------------
-- A laid/free-standing pipe chain is replicated as full state keyed by a
-- network-stable netId. The server is authoritative: it owns netId allocation
-- and is the only peer that broadcasts. A client commits a chain mutation by
-- sending SPSChainRequestEvent to the server; the server rebuilds its own
-- authoritative chain from the payload and broadcasts SPSChainStateEvent to all
-- peers (including the originator). Every peer rebuilds deterministically from
-- the payload using the same serialise/restore path as savegame load.
--
-- Live (being-walked) segments are never networked; only committed segments are.
-- ===========================================================================

function SlurryPipeManager:_countChainMap()
    local n = 0
    for _ in pairs(self._chainsByNetId) do n = n + 1 end
    return n
end

function SlurryPipeManager:_allocChainNetId()
    local id = self._nextChainNetId or 1
    self._nextChainNetId = id + 1
    return id
end

-- Build the network/save payload for a chain (reuses the savegame serialiser).
function SlurryPipeManager:_serializeChain(chain)
    if chain == nil or chain.getSaveData == nil then return nil end
    return chain:getSaveData()
end

-- Resolve the anchor descriptor (object + couplingId + isPlaceable) for a chain.
-- Returns nil object for a free-standing chain.
function SlurryPipeManager:_getChainAnchorDescriptor(chain)
    if chain == nil or chain.anchorCoupling == nil then
        return nil, 0, false
    end
    local coupling = chain.anchorCoupling
    local vehicle, placeable = self:_findCouplingOwner(coupling)
    if vehicle ~= nil then
        return vehicle, coupling.id or 0, false
    elseif placeable ~= nil then
        return placeable, coupling.id or 0, true
    end
    return nil, 0, false
end

-- Server-only: broadcast the current full state of a chain to all clients.
function SlurryPipeManager:_broadcastChainState(chain)
    if g_server == nil or chain == nil or chain.netId == nil then return end
    local payload = self:_serializeChain(chain)
    if payload == nil then return end
    local anchorObject, couplingId, isPlaceable = self:_getChainAnchorDescriptor(chain)
    SlurryPipeManager.log("_broadcastChainState: netId=%d segs=%d anchored=%s",
        chain.netId, payload.segments ~= nil and #payload.segments or 0,
        tostring(anchorObject ~= nil))
    SPSChainStateEvent.sendEvent(chain.netId, false, anchorObject, couplingId, isPlaceable, payload)
end

-- Called at every committed chain mutation by the chain itself (lock / lay-more /
-- remove-leaving-segments / docking-station). Routes through the server.
function SlurryPipeManager:commitChainState(chain)
    if chain == nil then return end
    SlurryPipeManager.logMP(string.format("[SPS MP] commitChainState server=%s chainNetId=%s segs=%d",
        tostring(g_server ~= nil), tostring(chain.netId), #chain.segments))
    if g_server ~= nil then
        if chain.netId == nil then
            chain.netId = self:_allocChainNetId()
            self._chainsByNetId[chain.netId] = chain
        end
        self:_broadcastChainState(chain)
    else
        -- Client: send the resulting snapshot to the server for authoritative apply.
        local payload = self:_serializeChain(chain)
        if payload == nil then return end
        local anchorObject, couplingId, isPlaceable = self:_getChainAnchorDescriptor(chain)
        SPSChainRequestEvent.sendEvent(chain.netId or 0, false,
            anchorObject, couplingId, isPlaceable, payload)
    end
end

-- Called when a chain is fully removed. netId may be nil if it never committed.
function SlurryPipeManager:commitChainRemoval(netId)
    SlurryPipeManager.logMP(string.format("[SPS MP] commitChainRemoval netId=%s server=%s",
        tostring(netId), tostring(g_server ~= nil)))
    if netId == nil then return end
    if g_server ~= nil then
        self._chainsByNetId[netId] = nil
        SPSChainStateEvent.sendEvent(netId, true, nil, 0, false, nil)
    else
        SPSChainRequestEvent.sendEvent(netId, true, nil, 0, false, nil)
    end
end

-- Find an existing chain by netId, or (for a not-yet-keyed chain) by its anchor.
function SlurryPipeManager:_findChainByNetIdOrAnchor(netId, anchorCoupling)
    if netId ~= nil and netId ~= 0 and self._chainsByNetId[netId] ~= nil then
        return self._chainsByNetId[netId]
    end
    if anchorCoupling ~= nil then
        for _, c in ipairs(self.pipeChains) do
            if c.anchorCoupling == anchorCoupling then return c end
        end
    end
    return nil
end

-- Resolve the local anchor coupling object from a network descriptor.
function SlurryPipeManager:_resolveAnchorCoupling(anchorObject, couplingId, isPlaceable)
    if anchorObject == nil then return nil end
    local c = self:_findCouplingById(anchorObject, couplingId, isPlaceable == true)
    SlurryPipeManager.logMP(string.format("[SPS MP] _resolveAnchorCoupling obj=%s couplingId=%s isPlaceable=%s -> %s",
        tostring(anchorObject ~= nil), tostring(couplingId), tostring(isPlaceable), tostring(c ~= nil)))
    return c
end

-- Re-establish the anchor<->chainStart link after a rebuild, mirroring lockLivePipe:
--   vehicle anchor  -> bez pipe via applyConnectCouplings (3.5m gap bridged)
--   placeable anchor-> logical link only (segment 1 is mounted at the coupling)
function SlurryPipeManager:_rebindChainAnchor(chain, anchorCoupling)
    if chain == nil or anchorCoupling == nil then return end
    if #chain.segments == 0 then return end
    local seg1 = chain.segments[1]
    local startCoupling = seg1 ~= nil and seg1.chainStartCoupling or nil
    if startCoupling == nil then return end

    if anchorCoupling.chainActivatable ~= nil then
        anchorCoupling.chainActivatable.chain = chain
    end

    local vehicle, placeable = self:_findCouplingOwner(anchorCoupling)
    if vehicle ~= nil then
        if not anchorCoupling.isConnected and not startCoupling.isConnected then
            self:applyConnectCouplings(anchorCoupling, startCoupling, vehicle, nil)
        end
    elseif placeable ~= nil then
        -- Logical link for valve propagation (no bez visual for placeable anchors).
        startCoupling.isConnected              = true
        startCoupling.connectedPartnerCoupling = anchorCoupling
        startCoupling.connectedTarget          = placeable
    end
end

-- Core rebuild used by both the broadcast-apply (clients/host) and the
-- request-apply (server) paths. Returns the chain (or nil if removed).
function SlurryPipeManager:_rebuildChainFromState(netId, removed, anchorObject, couplingId, isPlaceable, payload)
    -- Removal
    if removed == true then
        local chain = (netId ~= nil and netId ~= 0) and self._chainsByNetId[netId] or nil
        SlurryPipeManager.logMP(string.format("[SPS MP] rebuild REMOVE netId=%s foundInMap=%s mapSize=%d",
            tostring(netId), tostring(chain ~= nil), self:_countChainMap()))
        if chain ~= nil then
            for i, c in ipairs(self.pipeChains) do
                if c == chain then table.remove(self.pipeChains, i) break end
            end
            chain:delete()
            self._chainsByNetId[netId] = nil
        end
        -- [SPS MP] Drop any queued anchor-rebind for this netId so a late owner
        -- registration can't resurrect a chain that was removed while queued.
        if self._pendingChainAnchorRebinds ~= nil and netId ~= nil then
            self._pendingChainAnchorRebinds[netId] = nil
        end
        return nil
    end

    if payload == nil then return nil end

    local anchorCoupling = self:_resolveAnchorCoupling(anchorObject, couplingId, isPlaceable)

    -- [SPS MP] JIP anchor race: on a client the chain-state dump can arrive before
    -- the anchor's owner (especially a store placeable) has registered, so the
    -- anchor can't resolve here. The chain would then rebuild free-standing —
    -- segment 1 loses its anchor mount node, its rotation defaults to 0 (the
    -- one-ended twist) and the valve/removal link never forms (host/guest desync).
    -- Queue the full payload keyed by netId; _tryResolveChainAnchorRebinds() rebuilds
    -- it WITH the anchor once the owner registers. The free-standing chain is still
    -- built below so the pipe is visible during the gap, then replaced on resolve.
    if anchorObject ~= nil and anchorCoupling == nil and payload ~= nil
    and g_server == nil and not self._chainRebindResolving
    and netId ~= nil and netId ~= 0 then
        if self._pendingChainAnchorRebinds == nil then self._pendingChainAnchorRebinds = {} end
        self._pendingChainAnchorRebinds[netId] = {
            anchorObject = anchorObject,
            couplingId   = couplingId,
            isPlaceable  = isPlaceable,
            payload      = payload,
        }
        SlurryPipeManager.logMP(string.format(
            "[SPS MP] chain anchor rebind QUEUED netId=%s (anchor owner not registered yet)",
            tostring(netId)))
    end
    local chain = self:_findChainByNetIdOrAnchor(netId, anchorCoupling)
    local payloadSegCount = (payload.segments ~= nil) and #payload.segments or 0
    SlurryPipeManager.logMP(string.format("[SPS MP] rebuild STATE netId=%s anchorResolved=%s foundChain=%s payloadSegs=%d",
        tostring(netId), tostring(anchorCoupling ~= nil), tostring(chain ~= nil), payloadSegCount))

    -- [SPS MP] Originator skip: if this peer already holds a copy of this chain
    -- with the SAME committed shape (segment count + docking-station presence),
    -- keep its existing (correct, live-laid) geometry and only adopt the netId.
    -- This prevents the broadcast echo from tearing down good local geometry and
    -- re-placing it through the lower-fidelity restore path.
    if chain ~= nil and payloadSegCount > 0
    and #chain.segments == payloadSegCount
    and (chain.dockingStation ~= nil) == (payload.hasDockingStation == true) then
        if netId ~= nil and netId ~= 0 then
            if chain.netId ~= nil and chain.netId ~= netId then
                self._chainsByNetId[chain.netId] = nil
            end
            chain.netId = netId
            self._chainsByNetId[netId] = chain
        end
        SlurryPipeManager.logMP(string.format("[SPS MP] rebuild SKIP (adopt netId=%s, keep local geometry, segs=%d)",
            tostring(netId), payloadSegCount))
        return chain
    end

    if chain == nil then
        chain = SPSPipeChain.new(anchorCoupling, self.modDirectory)
        table.insert(self.pipeChains, chain)
    else
        -- Tear the existing copy down (prunes terminus entries, activatables,
        -- DS, scene nodes) then rebuild — keeps the object + netId stable.
        -- [SPS MP] Preserve external terminus bonds across the teardown: delete()
        -- applyDisconnects every connected terminus, which would sever bonds
        -- applied earlier in the same join burst (end bez vanishes, coupler
        -- reverts to "connect"). Captured here, re-applied after the rebuild.
        self._rebuildPreservedBonds = self:_captureChainTerminusBonds(chain)
        if chain.netId ~= nil and chain.netId ~= netId then
            self._chainsByNetId[chain.netId] = nil
        end
        chain:delete()
        chain.anchorCoupling = anchorCoupling
        chain.isRemoteLive = nil  -- [SPS MP] preview promoted to a committed chain
    end

    if netId ~= nil and netId ~= 0 then
        chain.netId = netId
        self._chainsByNetId[netId] = chain
    end

    chain:restoreFromSaveData(payload)
    self:_rebindChainAnchor(chain, anchorCoupling)
    -- [SPS MP] Re-bond preserved external couplers to the rebuilt termini.
    if self._rebuildPreservedBonds ~= nil then
        self:_reapplyChainTerminusBonds(chain, self._rebuildPreservedBonds)
        self._rebuildPreservedBonds = nil
    end
    return chain
end

-- Broadcast-apply: a peer receives authoritative state from the server.
function SlurryPipeManager:applyChainState(netId, removed, anchorObject, couplingId, isPlaceable, payload)
    SlurryPipeManager.logMP(string.format("[SPS MP] applyChainState netId=%s removed=%s", tostring(netId), tostring(removed)))
    self:_rebuildChainFromState(netId, removed, anchorObject, couplingId, isPlaceable, payload)
end

-- Request-apply: server receives a client's committed snapshot. Assigns a netId
-- for a brand-new chain, rebuilds its authoritative copy, then broadcasts to all.
function SlurryPipeManager:applyChainRequest(netId, removed, anchorObject, couplingId, isPlaceable, payload)
    SlurryPipeManager.logMP(string.format("[SPS MP] applyChainRequest IN netId=%s removed=%s server=%s",
        tostring(netId), tostring(removed), tostring(g_server ~= nil)))
    if g_server == nil then return end

    if removed == true then
        self:_rebuildChainFromState(netId, true, nil, 0, false, nil)
        if netId ~= nil and netId ~= 0 then
            SPSChainStateEvent.sendEvent(netId, true, nil, 0, false, nil)
        end
        return
    end

    -- Resolve / assign netId server-side (single source of truth).
    local useNetId = netId
    if useNetId == nil or useNetId == 0 then
        local anchorCoupling = self:_resolveAnchorCoupling(anchorObject, couplingId, isPlaceable)
        local existing = anchorCoupling ~= nil and self:_findChainByNetIdOrAnchor(0, anchorCoupling) or nil
        if existing ~= nil and existing.netId ~= nil then
            useNetId = existing.netId
        else
            useNetId = self:_allocChainNetId()
        end
    end

    local chain = self:_rebuildChainFromState(useNetId, false, anchorObject, couplingId, isPlaceable, payload)
    if chain ~= nil then
        self:_broadcastChainState(chain)
    end
end

-- [SPS MP] Terminus addressing: role 0 = chain start (segment 1), k = segment k.
function SlurryPipeManager:_getChainTerminusRole(chain, terminusCoupling)
    if chain == nil or terminusCoupling == nil then return nil end
    for i, seg in ipairs(chain.segments) do
        if seg.chainStartCoupling == terminusCoupling then return 0 end
        if seg.chainCoupling == terminusCoupling then return i end
    end
    return nil
end

function SlurryPipeManager:_resolveChainTerminus(chain, segIndex)
    if chain == nil then return nil end
    if segIndex == 0 then
        local seg1 = chain.segments[1]
        return seg1 ~= nil and seg1.chainStartCoupling or nil
    end
    local seg = chain.segments[segIndex]
    return seg ~= nil and seg.chainCoupling or nil
end

-- [SPS MP] Player bonded a real coupler to a chain terminus (the anchor bez, or
-- a tanker to a laid chain). Apply locally and replicate by (netId + role) so the
-- chain end is addressable on every peer (raw terminus ids like -2 are not).
function SlurryPipeManager:_handleChainTerminusConnect(vehicleCoupling, terminus, vehicle)
    local chain = terminus.chain
    local owner = vehicle or vehicleCoupling.placeable
    -- Local optimistic apply (skips internally if already connected).
    if not vehicleCoupling.isConnected and not terminus.isConnected then
        self:applyConnectCouplings(vehicleCoupling, terminus, owner, nil)
    end
    if chain == nil or chain.netId == nil then
        -- Chain not yet replicated (no netId) — cannot address it on peers.
        SlurryPipeManager.log("_handleChainTerminusConnect: chain has no netId, local-only")
        return
    end
    local segIndex = self:_getChainTerminusRole(chain, terminus) or 0
    SPSChainConnectEvent.sendEvent(owner, vehicle == nil, vehicleCoupling.id,
        chain.netId, segIndex, true)
end

-- [SPS MP] Capture the external coupler bonds on a chain's termini BEFORE the
-- chain is torn down for a rebuild. chain:delete() -> _destroySegmentNodes calls
-- applyDisconnect on every connected terminus, which disconnects the partner
-- coupler and destroys the end bez visual — so a rebuild (anchor rebind, state
-- re-broadcast) silently severed any bond applied earlier in the same join
-- (guest saw "connect pipe" at an end the host had connected). Returns a list of
-- { role, partner } where role addresses the terminus (0 = chain start, k =
-- segment k) and partner is the external vehicle/placeable coupler object, which
-- survives the chain teardown.
function SlurryPipeManager:_captureChainTerminusBonds(chain)
    if chain == nil or chain.segments == nil then return nil end
    local bonds = nil
    for i, seg in ipairs(chain.segments) do
        local function capture(term, role)
            if term ~= nil and term.isConnected
            and term.connectedPartnerCoupling ~= nil
            and not term.connectedPartnerCoupling.isChainTerminus then
                if bonds == nil then bonds = {} end
                table.insert(bonds, { role = role, partner = term.connectedPartnerCoupling })
            end
        end
        if i == 1 then capture(seg.chainStartCoupling, 0) end
        capture(seg.chainCoupling, i)
    end
    return bonds
end

-- [SPS MP] Re-apply captured terminus bonds to the REBUILT chain. Resolves each
-- terminus by role on the new chain and reconnects the surviving partner coupler
-- exactly the way applyChainConnect does. Idempotent: already-connected ends are
-- skipped.
function SlurryPipeManager:_reapplyChainTerminusBonds(chain, bonds)
    if chain == nil or bonds == nil then return end
    for _, b in ipairs(bonds) do
        local terminus = self:_resolveChainTerminus(chain, b.role)
        local partner  = b.partner
        if terminus ~= nil and partner ~= nil
        and not terminus.isConnected and not partner.isConnected then
            local vehicle, _ = self:_findCouplingOwner(partner)
            local owner = vehicle or partner.placeable
            self:applyConnectCouplings(partner, terminus, owner, nil)
            SlurryPipeManager.logMP(string.format(
                "[SPS MP] _reapplyChainTerminusBonds: rebonded role=%s partnerId=%s",
                tostring(b.role), tostring(partner.id)))
        end
    end
end

-- [SPS MP] Queue a chain-terminus bond that could not resolve yet (tanker coupler
-- or chain / terminus not registered on this client during the join burst). Drained
-- by _tryResolveMPPending() as each vehicle/placeable registers, mirroring the
-- direct-connect queue. Deduped so a re-received bond does not stack.
function SlurryPipeManager:_queuePendingChainBond(anchorObject, isPlaceable, vehicleCouplingId, chainNetId, terminusSegIndex)
    if self._pendingMPChainBonds == nil then self._pendingMPChainBonds = {} end
    for _, e in ipairs(self._pendingMPChainBonds) do
        if e.anchorObject == anchorObject and e.vehicleCouplingId == vehicleCouplingId
        and e.chainNetId == chainNetId and e.terminusSegIndex == terminusSegIndex then
            return
        end
    end
    table.insert(self._pendingMPChainBonds, {
        anchorObject      = anchorObject,
        isPlaceable       = isPlaceable == true,
        vehicleCouplingId = vehicleCouplingId,
        chainNetId        = chainNetId,
        terminusSegIndex  = terminusSegIndex,
    })
    SlurryPipeManager.logMP(string.format("[SPS MP] queued pending chain bond netId=%s seg=%s couplingId=%s (pending=%d)",
        tostring(chainNetId), tostring(terminusSegIndex), tostring(vehicleCouplingId), #self._pendingMPChainBonds))
end

-- [SPS MP] Apply a replicated coupler<->chain-terminus bond. Idempotent.
function SlurryPipeManager:applyChainConnect(anchorObject, isPlaceable, vehicleCouplingId, chainNetId, terminusSegIndex, connected)
    local vehicleCoupling = self:_findCouplingById(anchorObject, vehicleCouplingId, isPlaceable == true)
    local chain = self._chainsByNetId[chainNetId]
    SlurryPipeManager.logMP(string.format("[SPS MP] applyChainConnect netId=%s seg=%s connected=%s coupler=%s chain=%s",
        tostring(chainNetId), tostring(terminusSegIndex), tostring(connected),
        tostring(vehicleCoupling ~= nil), tostring(chain ~= nil)))
    if vehicleCoupling == nil or chain == nil then
        -- Not resolvable yet — queue for retry instead of dropping (join-order race).
        if connected == true then
            self:_queuePendingChainBond(anchorObject, isPlaceable, vehicleCouplingId, chainNetId, terminusSegIndex)
        end
        return
    end
    local terminus = self:_resolveChainTerminus(chain, terminusSegIndex)
    if terminus == nil then
        if connected == true then
            self:_queuePendingChainBond(anchorObject, isPlaceable, vehicleCouplingId, chainNetId, terminusSegIndex)
        end
        return
    end

    if connected then
        if not vehicleCoupling.isConnected and not terminus.isConnected then
            local owner = (not isPlaceable) and anchorObject or vehicleCoupling.placeable
            self:applyConnectCouplings(vehicleCoupling, terminus, owner, nil)
        end
    else
        if vehicleCoupling.isConnected then
            self:applyDisconnect(nil, vehicleCoupling.id, vehicleCoupling)
        end
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.3] Placeable detach handler — chains.
-- Fixes the sold-pen bug (MP test 21:12:43): a chain ANCHORED to a placeable
-- coupling (anchorCoupling), or with a terminus BONDED to one of its couplings,
-- does not set storeCoupling.isConnected, so the strap-coupling sell path never
-- saw it: no disconnect, no coupler close animation on either machine, chain
-- orphaned with a dead anchor. Route every such chain through the proven
-- removal path (applyChainRequest removed=true -> local teardown incl. terminus
-- applyDisconnect + animations + SPSChainStateEvent broadcast to all clients).
-- Server-only: clients tear down on the broadcast, exactly like a manual
-- chain removal. Chains never committed to the server (netId nil/0) are torn
-- down directly. Queued anchor rebinds referencing the placeable are purged on
-- every machine so a late resolve can't resurrect against a dead object.
-- ---------------------------------------------------------------------------
SlurryPipeManager.registerPlaceableDetachHandler("Chains", function(mgr, placeable)
    if mgr._pendingChainAnchorRebinds ~= nil then
        for nid, q in pairs(mgr._pendingChainAnchorRebinds) do
            if q.anchorObject == placeable then
                mgr._pendingChainAnchorRebinds[nid] = nil
                SlurryPipeManager.logMP(string.format(
                    "[SPS MP] detach: purged queued anchor rebind netId=%s (placeable removed)", tostring(nid)))
            end
        end
    end
    if g_server == nil or mgr.pipeChains == nil then return end
    local doomed = {}
    for _, chain in ipairs(mgr.pipeChains) do
        local hit = false
        local a = chain.anchorCoupling
        if a ~= nil and a.placeable == placeable then hit = true end
        if not hit and chain.segments ~= nil then
            for i, seg in ipairs(chain.segments) do
                local function bondedHere(term)
                    return term ~= nil and term.isConnected
                       and term.connectedPartnerCoupling ~= nil
                       and term.connectedPartnerCoupling.placeable == placeable
                end
                if bondedHere(seg.chainStartCoupling) or bondedHere(seg.chainCoupling) then
                    hit = true
                    break
                end
            end
        end
        if hit then table.insert(doomed, chain) end
    end
    for _, chain in ipairs(doomed) do
        SlurryPipeManager.logMP(string.format(
            "[SPS MP] detach: removing chain netId=%s (anchored/bonded to sold placeable)",
            tostring(chain.netId)))
        if chain.netId ~= nil and chain.netId ~= 0 then
            mgr:applyChainRequest(chain.netId, true, nil, 0, false, nil)
        else
            -- never committed server-side: direct local teardown
            for i, c in ipairs(mgr.pipeChains) do
                if c == chain then table.remove(mgr.pipeChains, i) break end
            end
            chain:delete()
        end
    end
end)
