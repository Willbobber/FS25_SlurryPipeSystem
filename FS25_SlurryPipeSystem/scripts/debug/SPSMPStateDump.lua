-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSMPStateDump.lua
-- Console command `spsMpState`: writes every registered vehicle / placeable coupling
-- and the per-vehicle runtime state (pump / valve / direction) to log.txt, plus the
-- MP pending queues and, for the local player, whether they stand inside each
-- coupling's arc and which coupler (if any) overlaps it.
--
-- Purpose: multiplayer divergence evidence. Run it on the machine that shows the
-- wrong prompt/state (a guest, or the host/dedi console) and compare the lines.
-- Read-only; safe on server, host and client.

SPSMPStateDump = {}

local function objName(obj)
    if obj == nil then return "nil" end
    if obj.getFullName ~= nil then
        local ok, n = pcall(obj.getFullName, obj)
        if ok and n ~= nil then return tostring(n) end
    end
    if obj.getName ~= nil then
        local ok, n = pcall(obj.getName, obj)
        if ok and n ~= nil then return tostring(n) end
    end
    return tostring(obj.configFileName or obj)
end

local function netId(obj)
    if obj == nil or NetworkUtil == nil or NetworkUtil.getObjectId == nil then return "-" end
    return tostring(NetworkUtil.getObjectId(obj))
end

local function b(v) return v and "Y" or "n" end

function SPSMPStateDump.describeCoupling(m, c, px, pz)
    local partner = c.connectedPartnerCoupling
    local pv, pp = nil, nil
    if partner ~= nil then pv, pp = m:_findCouplingOwner(partner) end
    local apex = m:_getCouplingArcNodes(c)
    local inArc, overlap = "-", "-"
    if px ~= nil then
        inArc = b(m:isPointInCouplingArc(c, px, pz))
        local o = nil
        if not c.isConnected then o = m:findOverlappingCoupler(c) end
        if o ~= nil then
            local ov, op = m:_findCouplingOwner(o)
            overlap = string.format("id=%s@%s", tostring(o.id), objName(ov or op))
        else
            overlap = "none"
        end
    end
    local mx, mz, dist = 0, 0, "-"
    if c.mountNode ~= nil and c.mountNode ~= 0 and entityExists(c.mountNode) then
        local x, _, z = getWorldTranslation(c.mountNode)
        mx, mz = x, z
        if px ~= nil then dist = string.format("%.1f", math.sqrt((px - x)^2 + (pz - z)^2)) end
    end
    return string.format(
        "    coupling id=%s mount=%s arcs=%s conn=%s partner=%s%s valveOpen=%s valveType=%s rearCtl=%s chainStart=%s chainTerm=%s deployable=%s deployed=%s | playerDist=%s inArc=%s overlap=%s | pos=(%.1f,%.1f)",
        tostring(c.id),
        b(c.mountNode ~= nil and c.mountNode ~= 0 and entityExists(c.mountNode)),
        b(apex ~= nil),
        b(c.isConnected),
        partner ~= nil and tostring(partner.id) or "-",
        partner ~= nil and ("@" .. objName(pv or pp)) or "",
        b(c.valveOpen), tostring(c.valveType), b(c.valveFromRearControl),
        b(c.isChainStart), b(c.isChainTerminus), b(c.deployable), b(c.isDeployed),
        dist, inArc, overlap, mx, mz)
end

function SPSMPStateDump.consoleDump(_, arg)
    local m = g_slurryPipeManager
    if m == nil then return "[SPS MPSTATE] manager not ready" end
    local px, pz = nil, nil
    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        local x, _, z = getWorldTranslation(g_localPlayer.rootNode)
        px, pz = x, z
    end
    local n = 0
    local function out(line) print(line); n = n + 1 end

    out(string.format("[SPS MPSTATE] side=%s vehicles=%d placeables=%d chains=%d termini=%d | pendingMP conn=%d valve=%d chainBond=%d crust=%d vstate=%d pipeVisuals=%d",
        (g_server ~= nil) and ((g_dedicatedServer ~= nil) and "DEDI" or "HOST") or "CLIENT",
        #m.registeredVehicles, #m.registeredPlaceables, #(m.pipeChains or {}), #(m.chainTerminusEntries or {}),
        #(m._pendingMPConnections or {}), #(m._pendingMPValves or {}), #(m._pendingMPChainBonds or {}),
        #(m._pendingMPStoreCrust or {}), #(m._pendingMPVehicleState or {}), #(m._pendingPipeVisuals or {})))

    for _, vEntry in ipairs(m.registeredVehicles) do
        local v, st = vEntry.vehicle, vEntry.state or {}
        out(string.format("[SPS MPSTATE] VEHICLE %s netId=%s sync=%s pump=%s valveOpen=%s dir=%s pressure=%.2f spreaderValve=%s agit=%s couplings=%d pipeActs=%d pumpCtl=%d",
            objName(v), netId(v), b(v.getIsSynchronized ~= nil and v:getIsSynchronized()),
            b(st.pumpRunning), b(st.valveOpen), tostring(st.direction), tonumber(st.pressure) or 0,
            b(st.spreaderValveOpen), b(vEntry.agitatorIsActive),
            #(vEntry.couplingEntries or {}), #(vEntry.pipeActivatables or {}), #(vEntry.pumpControlActivatables or {})))
        for _, c in ipairs(vEntry.couplingEntries or {}) do
            out("[SPS MPSTATE]" .. SPSMPStateDump.describeCoupling(m, c, px, pz))
        end
    end

    for _, pEntry in ipairs(m.registeredPlaceables) do
        local p = pEntry.placeable
        out(string.format("[SPS MPSTATE] PLACEABLE %s netId=%s storeCouplings=%d",
            objName(p), netId(p), #(pEntry.storeCouplings or {})))
        for _, sc in ipairs(pEntry.storeCouplings or {}) do
            out("[SPS MPSTATE]" .. SPSMPStateDump.describeCoupling(m, sc, px, pz))
        end
    end

    for i, chain in ipairs(m.pipeChains or {}) do
        local av, ap = nil, nil
        if chain.anchorCoupling ~= nil then av, ap = m:_findCouplingOwner(chain.anchorCoupling) end
        out(string.format("[SPS MPSTATE] CHAIN #%d netId=%s segments=%d anchorCoupling=%s@%s remoteLive=%s",
            i, tostring(chain.netId), #(chain.segments or {}),
            chain.anchorCoupling ~= nil and tostring(chain.anchorCoupling.id) or "-",
            objName(av or ap), b(chain.isRemoteLive)))
    end
    for _, ct in ipairs(m.chainTerminusEntries or {}) do
        out("[SPS MPSTATE] TERMINUS" .. SPSMPStateDump.describeCoupling(m, ct, px, pz))
    end

    -- [SPS 1.0.1.8] player-drawn water courses held on this peer (a client's set comes from the host)
    if SPSWaterCourses ~= nil then
        out(string.format("[SPS MPSTATE] WATERCOURSES held=%d planesLoaded=%s", #(SPSWaterCourses.order or {}),
            b(g_waterPlaneManager ~= nil and g_waterPlaneManager.planesLoaded)))
        for _, id in ipairs(SPSWaterCourses.order or {}) do
            local c = SPSWaterCourses.courses[id]
            if c ~= nil then
                out(string.format("[SPS MPSTATE]   course %d '%s' points=%d waterY=%.2f live=%s",
                    c.id, tostring(c.name), #c.points / 2, c.waterY, b(c.plane ~= nil)))
            end
        end
    end

    return string.format("[SPS MPSTATE] %d line(s) written to log.txt", n)
end

if addConsoleCommand ~= nil then
    addConsoleCommand("spsMpState", "Dump SPS multiplayer coupling/vehicle state to log.txt",
        "consoleDump", SPSMPStateDump)
end

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSMPStateDump 1.0.1.8 loaded") end
