-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSM_PhysPipes.lua
-- [SPS 1.0.1.8] SlurryPipeManager module: connections made with the BOUGHT PHYSICAL pipes
-- (vehicles of type spsHose, spec SPSHoseItem). PHYSICAL pipe mode only.
--
-- Controls (SPSHoseItemHands.lua): left mouse = pick up / drop (vanilla hands); right mouse while
-- holding = connect the free end in range; right mouse with empty hands near a plugged end = unplug
-- and carry; left mouse aiming at a plugged pipe = unplug, it falls.
-- Model: a physical pipe has two ends (hoseStart on its first body, hoseEnd on its last). An end is
-- PLUGGED into a coupling (vehicle coupling or store coupling): the pipe end's body goes kinematic
-- and rides the coupling node (SPSHoseItem:spsPlaceEnd, server), the coupling remembers the pipe
-- (coupling.physPipe / physPipeEnd). When BOTH ends of one pipe are plugged in, the two couplings
-- are connected through the ORIGINAL model (applyConnectCouplings): valves, pump, flow, HUD and the
-- coupler prompt (valve open/close, disconnect) all work unchanged - the only difference is that no
-- hose is drawn, because the pipe IS the hose (_createCouplerVisual returns nil for a physPipe
-- coupling). Disconnecting a coupling (applyDisconnect) frees the pipe end plugged into it.
-- Gender rule: coupling.connectorType is the hose end the coupling wants ("male" default on vehicle
-- couplings, "female" default on store couplings); the pipe end's gender must match.
-- MP: server-authoritative; SPSPhysPipeConnectEvent / SPSPhysPipeDisconnectEvent (SPSEvents.lua)
-- carry pipe + end index (+ target object / coupling id); the server applies and echoes to all.
-- 80 mm LANES (WATER / MILK hoses, 2026-10-16): the barn couplers (<animalWaterSystem> / <milkPipeSystem>)
-- and the vehicle liquid connector (<liquidPipeSystem>) live in the LIQUID-LANE registries
-- (SPSM_LiquidLanes), not the slurry ones. A "water" pipe end searches those too; the coupling's
-- `isLiquidLane` flag says which system applies: connect = applyLiquidLaneConnect (vehicle side <->
-- barn side, lane = the barn coupler's), disconnect = applyLiquidLaneDisconnect, flow / valve = the
-- lane's own B prompt at the vehicle's control node (SPSLiquidLaneControl, allowed in physical mode
-- only while a pipe is plugged in). The WATER and MILK hoses are the SAME pipe with the same 80 mm
-- fitting at both ends - they only look different (William 2026-10-16): either plugs into any lane
-- coupler; what may flow is decided by the lane and the tank (SPSM_LiquidLanes _llEvaluate: a water tank
-- cannot take milk and vice versa), never by the pipe.
-- SAVE / LOAD (2026-10-16): each pipe saves its two ends itself (SPSHoseItem:saveToXMLFile: owner unique id +
-- coupling id + system, and / or the joined pipe's unique id + end). On load the server queues them here
-- (physQueueRestore) and _physTryResolveRestores re-plugs / re-joins them as soon as the owner (vehicle or
-- placeable, by g_currentMission:getObjectByUniqueId) has registered its couplings; the chain evaluation then
-- re-makes the flow connection (valves closed). The original systems do NOT save these connections (slurry:
-- no pipeId without a drawn hose; lanes: physPipe couplings skipped in _saveLiquidLaneConnections).
-- [SPS 1.0.1.9] FERT / HERB (William 2026-10-26): the WATER hose also plugs into the SPRAYER system's couplers
-- (sprayers <sprayerPipeSystem>, fert / herb silos, IBCs, phyto buying stations - registeredSprayerVehicles /
-- registeredSprayerPlaceables, coupling.isSprayerCoupling). A chain with both ends on sprayer couplers connects
-- through applySprayerConnect (B at the sprayer = flow, Y = load / unload, no hose drawn); applySprayerDisconnect
-- frees the end like the slurry path. Hose rule: WATER hose = water, milk AND fert / herb; MILK hose = milk
-- fittings only (a chain holding a milk hose connects milk fittings only). Original mode is untouched.
-- Not yet: a TANKER's liquid connector into a fert silo (the lane SPRAYER bridge); MP late-join dump of plugged ends.

SlurryPipeManager.PHYS_CONNECT_RADIUS = 0.6   -- metres: pipe end to coupling node / mating pipe end (1.6 -> 2.0 on 2026-10-15; 0.6 on
                                              -- 2026-10-18, William: "the connection range to connect is far too far")

-- [SPS 1.0.1.9] quiet log: routine pipe lines (plug / join / restore / stow) only with `spsDebug Info on`;
-- physWarn stays in every log (config errors: a coupling / holder id that does not exist).
local function physLog(fmt, ...)
    if spsInfoOn ~= nil and spsInfoOn() then print("[SPS PHYS] " .. string.format(fmt, ...)) end
end
local function physWarn(fmt, ...)
    print("[SPS PHYS] WARNING: " .. string.format(fmt, ...))
end

local function nodeOk(n) return n ~= nil and n ~= 0 and entityExists(n) end

-- Is this coupling free for a physical pipe end of this gender?
-- [SPS 1.0.1.9] Does this 80 mm lane fitting take the MILK hose? Barn side: the fitting's own lane; vehicle side: the
-- connector's lane set (the fill unit accepts milk).
function SlurryPipeManager.physLaneCouplingTakesMilk(c)
    if c == nil then return false end
    if c.isVehicleSide then return c.lanes == nil or c.lanes.MILK == true end
    return c.lane ~= nil and c.lane.key == "MILK"
end

function SlurryPipeManager:_physCouplingFree(c, gender, hoseKey)
    if c == nil or not nodeOk(c.mountNode) then return false, "no node" end
    if c.isConnected then return false, "connected" end
    if c.physPipe ~= nil then return false, "pipe already plugged in" end
    local isMilkHose = hoseKey == "MILK"
    if c.isLiquidLane then
        if gender ~= "water" then
            return false, string.format("80 mm lane coupler wants a water hose end, this end is %s", tostring(gender))
        end
        -- [SPS 1.0.1.9] William 2026-10-26: the MILK hose is for milk only; the WATER hose goes on any 80 mm fitting
        if isMilkHose and not SlurryPipeManager.physLaneCouplingTakesMilk(c) then
            return false, "the milk hose only plugs into a milk fitting"
        end
        return true, nil
    end
    if c.isSprayerCoupling then
        -- [SPS 1.0.1.9] fert / herb coupler (sprayer, silo, IBC, buying station): the WATER hose only
        if gender ~= "water" then
            return false, string.format("sprayer coupler wants a water hose end, this end is %s", tostring(gender))
        end
        if isMilkHose then return false, "the milk hose does not plug into a sprayer coupler" end
        if c.loadAnimationName ~= nil and not c.loadAnimPlayed then return false, "cover closed - open it first (X)" end
        return true, nil
    end
    if c.deployable and not c.isDeployed then return false, "not deployed" end
    if c.isChainTerminus or c.isChainStart then return false, "chain coupling" end
    local want = c.connectorType or "male"
    if gender ~= nil and want ~= gender then
        return false, string.format("wants a %s hose end, this end is %s", want, tostring(gender))
    end
    return true, nil
end

-- Nearest free, gender-matching coupling to the point (x,y,z) within radius. hoseKey (WATER / MILK / FM ...) picks the
-- fittings an 80 mm end may use: MILK = milk fittings only, WATER = water, milk and sprayer couplers.
-- Returns coupling, owner (vehicle or placeable), isPlaceable, distance, nearMissReason.
function SlurryPipeManager:findCouplingForPhysPipeEnd(x, y, z, gender, radius, hoseKey)
    radius = radius or SlurryPipeManager.PHYS_CONNECT_RADIUS
    local best, bestD, bestOwner, bestIsPlaceable = nil, radius, nil, false
    local nearMiss = nil
    local function consider(c, owner, isPlaceable)
        local node = c.inNode or c.mountNode
        if not nodeOk(node) then return end
        -- [SPS 1.0.1.8] a docking station riding on a vehicle's frame takes no pipe (SPSDockingStation:spsDsStow)
        if owner ~= nil and owner.spsDsIsStowed ~= nil and owner:spsDsIsStowed() then return end
        local cx, cy, cz = getWorldTranslation(node)
        local d = MathUtil.vector3Length(x - cx, y - cy, z - cz)
        if d >= radius then return end
        local ok, reason = self:_physCouplingFree(c, gender, hoseKey)
        if not ok then
            if nearMiss == nil then nearMiss = string.format("coupling %s: %s", tostring(c.id), tostring(reason)) end
            return
        end
        if d < bestD then best, bestD, bestOwner, bestIsPlaceable = c, d, owner, isPlaceable end
    end
    for _, vEntry in ipairs(self.registeredVehicles or {}) do
        local aiDriven = SlurryPipeSystemOverride ~= nil and SlurryPipeSystemOverride.isAIControlled ~= nil
            and SlurryPipeSystemOverride.isAIControlled(vEntry.vehicle)
        if not aiDriven then
            for _, c in ipairs(vEntry.couplingEntries or {}) do consider(c, vEntry.vehicle, false) end
        end
    end
    for _, pEntry in ipairs(self.registeredPlaceables or {}) do
        for _, c in ipairs(pEntry.storeCouplings or {}) do consider(c, pEntry.placeable, true) end
    end
    if gender == "water" then
        for _, vEntry in ipairs(self.registeredLiquidLaneVehicles or {}) do
            for _, c in ipairs(vEntry.couplings or {}) do consider(c, vEntry.object, false) end
        end
        for _, pEntry in ipairs(self.registeredLiquidLanePlaceables or {}) do
            for _, c in ipairs(pEntry.couplings or {}) do consider(c, pEntry.object, true) end
        end
    end
    if gender == "water" and hoseKey ~= "MILK" then
        -- [SPS 1.0.1.9] FERT / HERB: the sprayer system's couplers (sprayers; fert / herb silos, IBCs and phyto buying
        -- stations live in registeredSprayerPlaceables, IBC pallets included - c.placeable says which are placeables)
        for _, sEntry in ipairs(self.registeredSprayerVehicles or {}) do
            local aiDriven = SlurryPipeSystemOverride ~= nil and SlurryPipeSystemOverride.isAIControlled ~= nil
                and SlurryPipeSystemOverride.isAIControlled(sEntry.object)
            if not sEntry.isLiquidLaneBridge and not aiDriven then
                for _, c in ipairs(sEntry.couplings or {}) do consider(c, sEntry.object, false) end
            end
        end
        for _, pEntry in ipairs(self.registeredSprayerPlaceables or {}) do
            for _, c in ipairs(pEntry.couplings or {}) do consider(c, pEntry.object, c.placeable ~= nil) end
        end
    end
    return best, bestOwner, bestIsPlaceable, bestD, nearMiss
end

-- Owner of a coupling of either system: vehicle, placeable.
function SlurryPipeManager:_physCouplingOwner(c)
    if c == nil then return nil, nil end
    if c.isLiquidLane then
        if c.isVehicleSide then return c.object, nil end
        return nil, c.placeable
    end
    if c.isSprayerCoupling then
        if c.placeable ~= nil then return nil, c.placeable end
        return c.object, nil
    end
    return self:_findCouplingOwner(c)
end

-- [SPS 1.0.1.9] Sprayer-system coupling by owner + id (sprayer vehicles and sprayer placeables / IBC pallets).
function SlurryPipeManager:_physFindSprayerCouplingById(object, couplingId)
    if object == nil then return nil end
    for _, sEntry in ipairs(self.registeredSprayerVehicles or {}) do
        if sEntry.object == object and not sEntry.isLiquidLaneBridge then
            for _, c in ipairs(sEntry.couplings or {}) do
                if c.id == couplingId then return c end
            end
        end
    end
    for _, pEntry in ipairs(self.registeredSprayerPlaceables or {}) do
        if pEntry.object == object then
            for _, c in ipairs(pEntry.couplings or {}) do
                if c.id == couplingId then return c end
            end
        end
    end
    return nil
end

-- Coupling of either system by owner + id (the connect event carries which system).
function SlurryPipeManager:_physFindCouplingById(object, couplingId, isPlaceable, isLane, isSprayer)
    if isSprayer then return self:_physFindSprayerCouplingById(object, couplingId) end
    if isLane then
        return self._findLiquidLaneCouplingById ~= nil and self:_findLiquidLaneCouplingById(object, couplingId) or nil
    end
    return self:_findCouplingById(object, couplingId, isPlaceable == true)
end

-- Break the flow connection of a coupling of either system (local apply, as the callers are echoes).
function SlurryPipeManager:_physApplyDisconnect(coupling)
    if coupling.isSprayerCoupling then
        -- [SPS 1.0.1.9] sprayer system: frees the end through its _physFreeCoupling hook (as the slurry path does)
        self:applySprayerDisconnect(coupling.placeable == nil and coupling.object or nil, coupling.id, coupling)
        return
    end
    if coupling.isLiquidLane then
        self:applyLiquidLaneDisconnect(coupling.isVehicleSide and coupling.object or nil, coupling.id, coupling)
    else
        local vehicle, _ = self:_findCouplingOwner(coupling)
        self:applyDisconnect(vehicle, coupling.id, coupling)
    end
end

-- ---------------------------------------------------------------------------
-- Entry points (any side). Server: apply + broadcast. Client: request; the server echoes to all.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:physPipeConnect(pipe, endIdx, object, isPlaceable, couplingId, isLane, isSprayer)
    if pipe == nil or object == nil or couplingId == nil then return end
    if g_server ~= nil then
        self:applyPhysPipeConnect(pipe, endIdx, object, isPlaceable, couplingId, isLane, isSprayer)
    end
    if SPSPhysPipeConnectEvent ~= nil then
        SPSPhysPipeConnectEvent.sendEvent(pipe, endIdx, object, isPlaceable, couplingId, isLane, isSprayer)
    end
end

-- [SPS 1.0.1.8] William 2026-10-18: on a water / milk fitting the pipe cannot be unplugged until its valve is
-- closed. William 2026-10-20: the same at a SLURRY coupler - its own valve (coupling.valveOpen; in physical mode
-- every coupler valve is independent, like the water valves) must be closed first. Coupler ends only: a pipe-to-pipe
-- join is not a coupling and never comes through here. Player-initiated unplugs (mouse) are gated; forced ones
-- (overstretch, delete, pipe-mode switch) pass force=true.
function SlurryPipeManager:physPipeCanDisconnect(pipe, endIdx)
    if pipe == nil or pipe.spsGetEnd == nil then return true end
    local e = pipe:spsGetEnd(endIdx)
    local c = e ~= nil and e.coupling or nil
    if c == nil then return true end
    if c.isLiquidLane then
        if c.ballValveOpen then return false, "warning_spsCloseValveFirst" end
        return true
    end
    if c.valveType == SPS_VALVE_TYPE_HYDRAULIC then
        -- a hydraulic coupler's valve is its vehicle's cab valve; its own flag only mirrors the partner's valve
        local ownerV = self:_findCouplingOwner(c)
        local st = ownerV ~= nil and self:getVehicleState(ownerV) or nil
        if st ~= nil and st.valveOpen == true then return false, "warning_spsCloseValveFirst" end
        return true
    end
    -- slurry coupler with its own valve, or a sprayer coupler (B = flow; valveOpen mirrors the sprayer state)
    if c.valveOpen then return false, "warning_spsCloseValveFirst" end
    return true
end

function SlurryPipeManager:physPipeDisconnect(pipe, endIdx, force)
    if pipe == nil then return end
    if not force then
        local ok, warnKey = self:physPipeCanDisconnect(pipe, endIdx)
        if not ok then
            if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                g_currentMission:showBlinkingWarning(g_i18n:getText(warnKey), 2500)
            end
            physLog("unplug of end %d refused: the coupler's valve is still open", endIdx)
            return false
        end
    end
    if g_server ~= nil then
        self:applyPhysPipeDisconnect(pipe, endIdx)
    end
    if SPSPhysPipeDisconnectEvent ~= nil then
        SPSPhysPipeDisconnectEvent.sendEvent(pipe, endIdx)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Apply (runs on every peer)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:applyPhysPipeConnect(pipe, endIdx, object, isPlaceable, couplingId, isLane, isSprayer, isRetry)
    if pipe == nil or pipe.spsGetEnd == nil then return false end
    local coupling = self:_physFindCouplingById(object, couplingId, isPlaceable, isLane, isSprayer)
    if coupling == nil then
        -- [SPS 1.0.1.9] late-joining client: the object exists but has not registered its couplings yet -> retry later
        if g_server == nil and object ~= nil and not object.isDeleted then
            if isRetry then return false, true end
            if self:_physDefer("connect", { pipe, endIdx, object, isPlaceable, couplingId, isLane, isSprayer },
                string.format("coupling id=%s of %s not registered yet", tostring(couplingId), tostring(object.configFileName))) then
                return false
            end
        end
        physWarn("connect: coupling id=%s not found on %s (placeable=%s, lane=%s, sprayer=%s)", tostring(couplingId),
            tostring(object and object.configFileName), tostring(isPlaceable), tostring(isLane), tostring(isSprayer))
        return false
    end
    local e = pipe:spsGetEnd(endIdx)
    if e == nil then
        -- [SPS 1.0.1.9] late-joining client: the pipe's own ends are not loaded yet -> retry later
        if g_server == nil and not pipe.isDeleted then
            if isRetry then return false, true end
            if self:_physDefer("connect", { pipe, endIdx, object, isPlaceable, couplingId, isLane, isSprayer }, "pipe ends not loaded yet") then
                return false
            end
        end
        return false
    end
    if e.coupling == coupling then return true end            -- echo of our own connect
    if e.coupling ~= nil then
        physLog("connect: pipe end %d is already plugged in elsewhere", endIdx)
        return false
    end
    if coupling.isConnected or (coupling.physPipe ~= nil and coupling.physPipe ~= pipe) then
        physLog("connect: coupling id=%s is busy", tostring(couplingId))
        return false
    end
    pipe:spsAttachEnd(endIdx, coupling, object, isPlaceable == true)
    physLog("end %d (%s) plugged into %scoupling id=%s of %s", endIdx, tostring(e.gender),
        coupling.isLiquidLane and (coupling.isVehicleSide and "liquid connector " or (coupling.lane and coupling.lane.key .. " lane ") or "lane ")
            or (coupling.isSprayerCoupling and "sprayer " or ""),
        tostring(coupling.id), tostring(object and object.configFileName))

    -- Does the chain this pipe belongs to now reach a coupling at both ends? -> flow connection.
    self:_physEvaluateChain(pipe)
    return true
end

-- ---------------------------------------------------------------------------
-- PIPE-TO-PIPE (F/F, M/M, extensions): a free end joins another pipe's free end of the opposite gender
-- (water<->water for the 80 mm hoses). The pipes form a CHAIN; when the chain's two outer ends are
-- plugged into couplings, those two couplings are connected through the original model exactly like a
-- single pipe. Breaking the chain anywhere (unjoin, or unplug at a coupling) breaks the flow connection.
-- ---------------------------------------------------------------------------
local function gendersMate(a, b)
    if a == "water" or b == "water" then return a == b end
    return (a == "male" and b == "female") or (a == "female" and b == "male")
end

-- Nearest free, mating end of ANOTHER pipe to the point (x,y,z) within radius.
function SlurryPipeManager:findPipeEndForPhysPipeEnd(x, y, z, gender, excludePipe, radius)
    radius = radius or SlurryPipeManager.PHYS_CONNECT_RADIUS
    local best, bestIdx, bestD = nil, nil, radius
    for other, _ in pairs(self.physPipes or {}) do
        if other ~= excludePipe and other.spsGetEnd ~= nil and nodeOk(other.rootNode) then
            for idx = 1, 2 do
                local e = other:spsGetEnd(idx)
                if e ~= nil and e.coupling == nil and e.joinedTo == nil and nodeOk(e.node) and gendersMate(gender, e.gender) then
                    local ex, ey, ez = getWorldTranslation(e.node)
                    local d = MathUtil.vector3Length(x - ex, y - ey, z - ez)
                    if d < bestD then best, bestIdx, bestD = other, idx, d end
                end
            end
        end
    end
    return best, bestIdx, bestD
end

function SlurryPipeManager:physPipeJoin(pipe, endIdx, otherPipe, otherIdx)
    if pipe == nil or otherPipe == nil then return end
    if g_server ~= nil then
        self:applyPhysPipeJoin(pipe, endIdx, otherPipe, otherIdx)
    end
    if SPSPhysPipeJoinEvent ~= nil then
        SPSPhysPipeJoinEvent.sendEvent(pipe, endIdx, otherPipe, otherIdx)
    end
end

function SlurryPipeManager:applyPhysPipeJoin(pipe, endIdx, otherPipe, otherIdx, isRetry)
    if pipe == nil or otherPipe == nil or pipe == otherPipe or pipe.spsGetEnd == nil or otherPipe.spsGetEnd == nil then return false end
    local e, oe = pipe:spsGetEnd(endIdx), otherPipe:spsGetEnd(otherIdx)
    if e == nil or oe == nil then
        -- [SPS 1.0.1.9] late-joining client: one of the pipes has not loaded its ends yet -> retry later
        if g_server == nil and not pipe.isDeleted and not otherPipe.isDeleted then
            if isRetry then return false, true end
            if self:_physDefer("join", { pipe, endIdx, otherPipe, otherIdx }, "pipe ends not loaded yet") then return false end
        end
        return false
    end
    if e.joinedTo ~= nil and e.joinedTo.pipe == otherPipe then return true end     -- echo
    if e.coupling ~= nil or e.joinedTo ~= nil or oe.coupling ~= nil or oe.joinedTo ~= nil then
        physLog("join: an end is busy"); return false
    end
    if not gendersMate(e.gender, oe.gender) then
        physLog("join: ends do not mate (%s / %s)", tostring(e.gender), tostring(oe.gender)); return false
    end
    pipe:spsJoinEnd(endIdx, otherPipe, otherIdx, true)       -- mover: snaps on + makes the joint
    otherPipe:spsJoinEnd(otherIdx, pipe, endIdx, false)
    physLog("joined %s end %d (%s) to %s end %d (%s)", tostring(pipe:spsGetHoseKey()), endIdx, e.gender,
        tostring(otherPipe:spsGetHoseKey()), otherIdx, oe.gender)
    self:_physEvaluateChain(pipe)
    return true
end

-- Walk out of `pipe` through end `idx` across pipe-to-pipe joints; returns the coupling at the far
-- end of the chain (or nil), plus the last pipe / end reached.
function SlurryPipeManager:_physWalkChain(pipe, idx)
    local visited = { [pipe] = true }
    local p, i = pipe, idx
    while true do
        local e = p:spsGetEnd(i)
        if e == nil then return nil, p, i end
        if e.coupling ~= nil then return e.coupling, p, i end
        if e.joinedTo == nil or e.joinedTo.pipe == nil or e.joinedTo.pipe.spsGetEnd == nil then return nil, p, i end
        local np = e.joinedTo.pipe
        if visited[np] then return nil, p, i end        -- a loop of pipes
        visited[np] = true
        p, i = np, (e.joinedTo.idx == 1) and 2 or 1      -- enter at joinedTo.idx, leave through the other end
    end
end

function SlurryPipeManager:_physChainTerminals(pipe)
    local cA = self:_physWalkChain(pipe, 1)
    local cB = self:_physWalkChain(pipe, 2)
    return cA, cB
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] FREE END IN THE WATER (William 2026-10-20: two pipes joined, one end on the profi2
-- slurry coupler, the other end lying in a lake - no valve prompt). A chain only "connects" when
-- both outer ends sit on couplings, so a water intake never did. The original strap pipe had this
-- case (SPSM_Flow resolveExternalSource: "strap pipe free end for water"); this is the physical
-- pipe equivalent. The slurry coupling that holds the plugged end is treated as connected to an
-- infinite WATER source while the chain's other end lies free in a water plane at (or below) the
-- surface. Evaluated live, so pulling the end out of the water ends it at once.
-- Slurry couplings only: an 80 mm lane fitting is a different system (SPSM_LiquidLanes).
-- ---------------------------------------------------------------------------
SlurryPipeManager.PHYS_WATER_END_MAX_ABOVE = 0.25   -- m the free end may sit above the surface and still draw

function SlurryPipeManager:physFreeEndWaterPlane(coupling)
    if coupling == nil or coupling.physPipe == nil or coupling.isConnected or coupling.isLiquidLane then return nil end
    if self.physicalPipesEnabled ~= true or g_waterPlaneManager == nil then return nil end
    local pipe, plugged = coupling.physPipe, coupling.physPipeEnd
    if pipe == nil or pipe.spsGetEnd == nil or plugged == nil then return nil end
    local farCoupling, farPipe, farIdx = self:_physWalkChain(pipe, (plugged == 1) and 2 or 1)
    if farCoupling ~= nil or farPipe == nil then return nil end           -- the far end sits on a coupling
    local e = farPipe:spsGetEnd(farIdx)
    if e == nil or farPipe.components == nil then return nil end
    local comp = farPipe.components[e.comp]
    if comp == nil or comp.node == nil or comp.node == 0 or not entityExists(comp.node) then return nil end
    local x, y, z = getWorldTranslation(comp.node)
    local plane = g_waterPlaneManager:findWaterPlaneAtPosition(x, z)
    if plane == nil then return nil end
    if plane.waterY ~= nil and y > plane.waterY + SlurryPipeManager.PHYS_WATER_END_MAX_ABOVE then return nil end
    return plane
end

function SlurryPipeManager:physCouplingIsWaterFed(coupling)
    return self:physFreeEndWaterPlane(coupling) ~= nil
end

-- [SPS 1.0.1.9] Does the chain this pipe belongs to hold a pipe of this hose key (MILK: the milk-only rule)?
function SlurryPipeManager:_physChainHasHose(pipe, hoseKey)
    if pipe == nil or pipe.spsGetEnd == nil then return false end
    if pipe.spsGetHoseKey ~= nil and pipe:spsGetHoseKey() == hoseKey then return true end
    local visited = { [pipe] = true }
    for idx = 1, 2 do
        local p, i = pipe, idx
        while true do
            local e = p:spsGetEnd(i)
            if e == nil or e.joinedTo == nil or e.joinedTo.pipe == nil or e.joinedTo.pipe.spsGetEnd == nil then break end
            local np = e.joinedTo.pipe
            if visited[np] then break end
            visited[np] = true
            if np.spsGetHoseKey ~= nil and np:spsGetHoseKey() == hoseKey then return true end
            p, i = np, (e.joinedTo.idx == 1) and 2 or 1
        end
    end
    return false
end

local function physSystemName(c)
    if c.isSprayerCoupling then return "sprayer coupler" end
    if c.isLiquidLane then return "80 mm lane coupler" end
    return "slurry coupling"
end

-- Both outer ends of the chain on couplings and neither connected yet -> connect them.
function SlurryPipeManager:_physEvaluateChain(pipe)
    local cA, cB = self:_physChainTerminals(pipe)
    if cA == nil or cB == nil or cA == cB then return false end
    if cA.isConnected or cB.isConnected then return false end
    -- [SPS 1.0.1.9] both ends on ONE machine (William's log 2026-10-26 20:40: a pipe plugged into the Borger's IN and
    -- OUT couplers connected the separator to itself) - a loop is never a connection
    do
        local vA, pA = self:_physCouplingOwner(cA)
        local vB, pB = self:_physCouplingOwner(cB)
        local oA, oB = vA or pA, vB or pB
        if oA ~= nil and oA == oB then
            physLog("chain joins two couplings of the same %s (id=%s and id=%s) - a loop is not a connection",
                tostring(oA.configFileName), tostring(cA.id), tostring(cB.id))
            return false
        end
    end
    local milkChain = self:_physChainHasHose(pipe, "MILK")
    if cA.isSprayerCoupling or cB.isSprayerCoupling then
        -- [SPS 1.0.1.9] FERT / HERB: both ends on sprayer-system couplers (sprayer <-> silo / IBC / buying station,
        -- or sprayer <-> sprayer) -> the sprayer system's own connection; B at the sprayer = flow, Y = load / unload.
        if not (cA.isSprayerCoupling and cB.isSprayerCoupling) then
            physLog("chain spans two systems (%s + %s) - no connection", physSystemName(cA), physSystemName(cB)); return false
        end
        if milkChain then
            physLog("chain holds a milk hose - fert / herb needs water hoses only"); return false
        end
        local oA = cA.placeable or cA.object
        local oB = cB.placeable or cB.object
        self:applySprayerConnect(cA, cB, oA, oB)
        physLog("chain complete: sprayer coupler id=%s of %s <-> id=%s of %s connected (B at the sprayer = flow, Y = load / unload)",
            tostring(cA.id), tostring(oA and oA.configFileName), tostring(cB.id), tostring(oB and oB.configFileName))
        return true
    end
    if cA.isLiquidLane or cB.isLiquidLane then
        -- 80 mm lane: one end on a vehicle's liquid connector, the other on a barn's lane coupler.
        if not (cA.isLiquidLane and cB.isLiquidLane) then
            physLog("chain spans two systems (%s + %s) - no connection", physSystemName(cA), physSystemName(cB)); return false
        end
        if cA.isVehicleSide and cB.isVehicleSide then
            -- [SPS 1.0.1.8] TRANSFER: tanker to tanker (William 2026-10-17). Both connectors must take water or milk.
            local lane = SPS_LIQUID_LANES ~= nil and SPS_LIQUID_LANES.TRANSFER or nil
            -- a connector that serves WATER or MILK can transfer it (lanes="WATER" on the profi2 refused this, 2026-10-18 test)
            local function servesLiquid(cc)
                return cc.lanes == nil or cc.lanes.WATER or cc.lanes.MILK or cc.lanes.TRANSFER
            end
            local serves = lane ~= nil and servesLiquid(cA) and servesLiquid(cB)
            if not serves then
                physLog("chain joins two liquid connectors but one of them takes neither water nor milk [%s] / [%s]",
                    tostring(cA.laneNames), tostring(cB.laneNames)); return false
            end
            -- [SPS 1.0.1.9] a chain holding a milk hose only carries milk: both connectors must take milk
            if milkChain and not (SlurryPipeManager.physLaneCouplingTakesMilk(cA) and SlurryPipeManager.physLaneCouplingTakesMilk(cB)) then
                physLog("chain holds a milk hose but a connector does not take milk [%s] / [%s]",
                    tostring(cA.laneNames), tostring(cB.laneNames)); return false
            end
            self:applyLiquidLaneConnect(cA, cB, cA.object, cB.object, lane)
            physLog("chain complete: liquid connector id=%s of %s <-> id=%s of %s (tanker to tanker: R at the fittings = valves, B = pump, Y = direction)",
                tostring(cA.id), tostring(cA.object and cA.object.configFileName), tostring(cB.id), tostring(cB.object and cB.object.configFileName))
            return true
        end
        local cV = cA.isVehicleSide and cA or (cB.isVehicleSide and cB or nil)
        local cP = (not cA.isVehicleSide) and cA or ((not cB.isVehicleSide) and cB or nil)
        if cV == nil or cP == nil then
            physLog("chain joins two barn couplers - a lane needs a tanker at one end"); return false
        end
        local lane = cP.lane
        if lane == nil then return false end
        if milkChain and lane.key ~= "MILK" then
            physLog("chain holds a milk hose but ends on the %s lane - milk hoses carry milk only", tostring(lane.key)); return false
        end
        if cV.lanes ~= nil and not cV.lanes[lane.key] then
            physLog("chain complete but %s's liquid connector does not serve the %s lane [%s]",
                tostring(cV.object and cV.object.configFileName), tostring(lane.key), tostring(cV.laneNames)); return false
        end
        self:applyLiquidLaneConnect(cV, cP, cV.object, cP.placeable, lane)
        physLog("chain complete: liquid connector id=%s <-> %s lane coupler id=%s connected (R at both fittings = valves, B at the tanker = pump)",
            tostring(cV.id), tostring(lane.key), tostring(cP.id))
        return true
    end
    local vA, pA = self:_findCouplingOwner(cA)
    local vB, pB = self:_findCouplingOwner(cB)
    self:applyConnectCouplings(cA, cB, vA or pA, vB or pB)
    physLog("chain complete: coupling id=%s <-> id=%s connected (valve / pump / flow as the original system)",
        tostring(cA.id), tostring(cB.id))
    return true
end

-- The chain is about to be broken in the MIDDLE (a pipe-to-pipe joint goes): drop the flow connection
-- between its outer couplings but leave both plugged-in ends where they are.
function SlurryPipeManager:_physBreakChainFlow(pipe)
    local cA, cB = self:_physChainTerminals(pipe)
    if cA == nil or cB == nil or not cA.isConnected or cA.connectedPartnerCoupling ~= cB then return false end
    cA._physKeepEnd = true
    self:_physApplyDisconnect(cA)
    cA._physKeepEnd = nil
    self:_physResyncConnectorAnim(cA); self:_physResyncConnectorAnim(cB)
    physLog("chain broken: coupling id=%s <-> id=%s disconnected (ends stay plugged in)", tostring(cA.id), tostring(cB.id))
    return true
end

-- The disconnect paths of both systems play the connector animation BACK on both couplings; a coupling that
-- still has a pipe end plugged in must stay closed (clamps shut, ball valve open).
function SlurryPipeManager:_physResyncConnectorAnim(c)
    if c == nil or c.physPipe == nil or SPSCouplerAnimator == nil then return end
    if c.isLiquidLane then
        -- 80 mm fitting: the handle is the VALVE (player-driven) - it only ever shows ballValveOpen
        local anim = c.valveAnim or c.connectorAnim
        if anim ~= nil then SPSCouplerAnimator.play(anim, c.ballValveOpen and 1 or -1) end
        return
    end
    if c.connectorAnim ~= nil then SPSCouplerAnimator.play(c.connectorAnim, 1) end
end

-- Frees ONE end. If that end's coupling is part of a flow connection the connection is broken
-- through applyDisconnect (which frees the end via the physPipe hook there); the pipe's other end
-- stays plugged into its coupling.
function SlurryPipeManager:applyPhysPipeDisconnect(pipe, endIdx)
    if pipe == nil or pipe.spsGetEnd == nil then return false end
    local e = pipe:spsGetEnd(endIdx)
    if e == nil then return false end
    if e.joinedTo ~= nil then
        -- pipe-to-pipe joint: flow off (ends on couplings stay), then split the two pipes
        self:_physBreakChainFlow(pipe)
        local other = e.joinedTo.pipe
        pipe:spsUnjoinEnd(endIdx)
        physLog("end %d unjoined from %s", endIdx, tostring(other and other.spsGetHoseKey and other:spsGetHoseKey()))
        return true
    end
    if e.coupling == nil then return false end
    local coupling = e.coupling
    local partner = coupling.connectedPartnerCoupling
    if coupling.isConnected then
        self:_physApplyDisconnect(coupling)
    end
    if e.coupling ~= nil then
        pipe:spsDetachEnd(endIdx)
    end
    self:_physResyncConnectorAnim(partner)   -- the far end is still plugged in
    physLog("end %d unplugged from coupling id=%s", endIdx, tostring(coupling.id))
    return true
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] PIPE MODE switch PHYSICAL -> ORIGINAL (William 2026-10-20: "switching will remove all phys pipes
-- and it should stop all parts of the phys side working"). The twin of removeAllOriginalPipes: every physical pipe
-- is force-unplugged / unjoined / unstowed and then DELETED like a shop sell (Vehicle:delete -> vehicleSystem:
-- removeVehicle, the path SellVehicleEvent:run uses; clients get the vanilla vehicle removal). The carriable SPS
-- Docking Station goes the same way (William 2026-10-21: in original mode a station is placed at a pipe end with
-- R, never bought - the store item is physical-mode only, PHYSICAL_PIPE_STORE_ITEMS).
-- ---------------------------------------------------------------------------
-- Counts for the warning dialog (every peer keeps physPipes / physStations: registered in onPostLoad everywhere).
function SlurryPipeManager:countPhysicalPipes()
    local nPipes, nPlugged, nStowed, nStations = 0, 0, 0, 0
    for pipe in pairs(self.physPipes or {}) do
        if pipe ~= nil and not pipe.isDeleted and pipe.spsGetEnd ~= nil then
            nPipes = nPipes + 1
            for idx = 1, 2 do
                local e = pipe:spsGetEnd(idx)
                if e ~= nil and e.coupling ~= nil then nPlugged = nPlugged + 1 end
            end
            if pipe.spsIsStowed ~= nil and pipe:spsIsStowed() then nStowed = nStowed + 1 end
        end
    end
    for st in pairs(self.physStations or {}) do
        if st ~= nil and not st.isDeleted then nStations = nStations + 1 end
    end
    return nPipes, nPlugged, nStowed, nStations
end

function SlurryPipeManager:removeAllPhysicalPipes()
    if g_server == nil then return 0, 0 end
    local pipes, stations = {}, {}
    for pipe in pairs(self.physPipes or {}) do
        if pipe ~= nil and not pipe.isDeleted and pipe.spsGetEnd ~= nil then pipes[#pipes + 1] = pipe end
    end
    for st in pairs(self.physStations or {}) do
        if st ~= nil and not st.isDeleted then stations[#stations + 1] = st end
    end
    local nPipes, nStations = 0, 0
    -- 1. every end off its coupling / join (forced: the valve gate does not apply), every pipe off its rack
    for _, pipe in ipairs(pipes) do
        for idx = 1, 2 do
            local e = pipe:spsGetEnd(idx)
            if e ~= nil and (e.coupling ~= nil or e.joinedTo ~= nil) then
                self:physPipeDisconnect(pipe, idx, true)
            end
        end
        if pipe.spsIsStowed ~= nil and pipe:spsIsStowed() then
            self:physPipeUnstow(pipe)
        end
        if self.physCancelRestore ~= nil then self:physCancelRestore(pipe) end
    end
    -- 2. stations off their frames, restores cancelled
    for _, st in ipairs(stations) do
        local spec = st[SPSDockingStation ~= nil and SPSDockingStation.SPEC_NAME or ""]
        if spec ~= nil and spec.stow ~= nil then self:dsUnstow(st) end
        if self.dsCancelRestore ~= nil then self:dsCancelRestore(st) end
    end
    -- 3. delete the pipe vehicles, then the stations (onDelete drops them from physPipes / physStations)
    for _, pipe in ipairs(pipes) do
        if not pipe.isDeleted then
            pipe:delete()
            nPipes = nPipes + 1
        end
    end
    for _, st in ipairs(stations) do
        if not st.isDeleted then
            st:delete()
            nStations = nStations + 1
        end
    end
    print(string.format("[SPS] pipe mode: switched to ORIGINAL - removed %d physical pipe(s) and %d docking station(s)",
        nPipes, nStations))
    return nPipes, nStations
end

-- ---------------------------------------------------------------------------
-- Save / load of plugged and joined ends (server). See the header.
-- ---------------------------------------------------------------------------
SPS_PHYS_RESTORE_TICKS = 3000   -- ~50 s at 60 Hz before a saved end is given up on (owner never appeared)

function SlurryPipeManager:physQueueRestore(pipe, data)
    if pipe == nil or data == nil then return end
    self._physRestores = self._physRestores or {}
    if data.stow ~= nil and data.stow.owner ~= nil then
        table.insert(self._physRestores, { pipe = pipe, stowOwner = data.stow.owner, stowHolder = data.stow.holderId or 1,
            stowSlot = data.stow.slotName, ticks = 0 })
        physLog("restore queued: %s stowed in slot '%s' of holder id=%s of %s", tostring(pipe:spsGetHoseKey()),
            tostring(data.stow.slotName), tostring(data.stow.holderId), tostring(data.stow.owner))
    end
    for idx = 1, 2 do
        local r = data[idx]
        if r ~= nil then
            table.insert(self._physRestores, { pipe = pipe, idx = idx, owner = r.owner, couplingId = r.couplingId,
                isPlaceable = r.isPlaceable == true, isLane = r.isLane == true, isSprayer = r.isSprayer == true,
                joinPipe = r.joinPipe, joinEnd = r.joinEnd, valveOpen = r.valveOpen == true, ticks = 0 })
            physLog("restore queued: %s end %d -> %s%s", tostring(pipe:spsGetHoseKey()), idx,
                r.owner ~= nil and string.format("coupling id=%s of %s%s", tostring(r.couplingId), tostring(r.owner), r.isLane and " (lane)" or "") or "",
                r.joinPipe ~= nil and string.format(" joined to %s end %s", tostring(r.joinPipe), tostring(r.joinEnd)) or "")
        end
    end
end

function SlurryPipeManager:physCancelRestore(pipe)
    if self._physRestores == nil then return end
    for i = #self._physRestores, 1, -1 do
        if self._physRestores[i].pipe == pipe then table.remove(self._physRestores, i) end
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.9] MP late join: the join dump (sendFullStateToConnection) goes out the moment the client connection is
-- ready for events, while that client is still loading its vehicles. A replayed plug / join / stow whose partner
-- object exists but has not registered its couplings / holders yet - or whose pipe has not loaded its ends yet - was
-- dropped ("connect: coupling id=N not found", server tester 2026-10-25 20:13: two pipes on the PTO pump looked
-- unplugged to him). A client now parks such applies here and retries them every update (the apply functions answer
-- `false, true` = "not yet" when called with isRetry) until they take or the savegame-restore give-up. Terminal
-- refusals (busy end, genders, taken slot) are never queued. The server never defers: its objects register first.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_physDefer(kind, args, why)
    if g_server ~= nil then return false end
    self._physDeferred = self._physDeferred or {}
    for _, d in ipairs(self._physDeferred) do
        if d.kind == kind and d.args[1] == args[1] and d.args[2] == args[2] and d.args[3] == args[3] then return true end
    end
    table.insert(self._physDeferred, { kind = kind, args = args, ticks = 0 })
    physLog("%s deferred on this client (%s) - retrying until it has registered", kind, tostring(why))
    return true
end

function SlurryPipeManager:_physTryResolveDeferred()
    local list = self._physDeferred
    if list == nil or #list == 0 then return end
    for i = #list, 1, -1 do
        local d, a = list[i], list[i].args
        local ok, again = false, false
        if a[1] ~= nil and not a[1].isDeleted then
            if d.kind == "connect" then ok, again = self:applyPhysPipeConnect(a[1], a[2], a[3], a[4], a[5], a[6], a[7], true)
            elseif d.kind == "join" then ok, again = self:applyPhysPipeJoin(a[1], a[2], a[3], a[4], true)
            elseif d.kind == "stow" then ok, again = self:applyPhysPipeStow(a[1], a[2], a[3], a[4], true)
            elseif d.kind == "dsStow" then ok, again = self:applyDsStow(a[1], a[2], a[3], true)
            end
        end
        local done = true
        if ok then
            physLog("%s retry succeeded on this client", d.kind)
        elseif again then
            d.ticks = d.ticks + 1
            done = d.ticks > SPS_PHYS_RESTORE_TICKS
            if done then physLog("%s retry gave up on this client (object never registered)", d.kind) end
        else
            physLog("%s retry dropped on this client (refused or object gone)", d.kind)
        end
        if done then table.remove(list, i) end
    end
end

function SlurryPipeManager:_physTryResolveRestores()
    local list = self._physRestores
    if list == nil or #list == 0 or g_currentMission == nil then return end
    for i = #list, 1, -1 do
        local r = list[i]
        local pipe = r.pipe
        local done = false
        if pipe == nil or pipe.spsGetEnd == nil or pipe.isDeleted or not nodeOk(pipe.rootNode) then
            done = true
        else
            local e = r.idx ~= nil and pipe:spsGetEnd(r.idx) or nil
            local plugDone = (r.owner == nil) or (e ~= nil and e.coupling ~= nil)
            local joinDone = (r.joinPipe == nil) or (e ~= nil and e.joinedTo ~= nil)
            local stowDone = (r.stowOwner == nil) or (pipe.spsIsStowed ~= nil and pipe:spsIsStowed())
            if not stowDone then
                local owner = g_currentMission:getObjectByUniqueId(r.stowOwner)
                if owner ~= nil and self:_physFindHolder(owner, r.stowHolder) ~= nil then
                    self:physPipeStow(pipe, owner, r.stowHolder, r.stowSlot)
                    stowDone = true
                end
            end
            if not plugDone then
                local owner = g_currentMission:getObjectByUniqueId(r.owner)
                if owner ~= nil then
                    local c = self:_physFindCouplingById(owner, r.couplingId, r.isPlaceable, r.isLane, r.isSprayer)
                    if c ~= nil then
                        -- [SPS 1.0.1.9] saves written before tonight carry the physical bonds as ORIGINAL connections
                        -- (SPSChainBondPersistence); restored first, they made the coupler "busy". In physical mode a
                        -- bond with no pipe on either side cannot be real: break it, then plug the saved end.
                        local partner = c.connectedPartnerCoupling
                        if self.physicalPipesEnabled == true and c.physPipe == nil and c.isConnected
                           and partner ~= nil and partner.physPipe == nil then
                            physLog("restore: coupling id=%s of %s holds a stale original bond (no pipe on either side) - broken for the saved pipe end",
                                tostring(r.couplingId), tostring(owner.configFileName))
                            self:_physApplyDisconnect(c)
                        end
                        if c.physPipe == nil and not c.isConnected then
                            self:physPipeConnect(pipe, r.idx, owner, r.isPlaceable, r.couplingId, r.isLane, r.isSprayer)
                            if r.valveOpen then
                                -- opened later by _physTryRestoreValves: a slurry coupler valve needs the whole chain
                                -- connected first, which only happens once every end of the chain is back
                                self._physValveRestores = self._physValveRestores or {}
                                table.insert(self._physValveRestores, { owner = owner, couplingId = r.couplingId,
                                    isPlaceable = r.isPlaceable, isLane = r.isLane, isSprayer = r.isSprayer, ticks = 0 })
                            end
                        else
                            physLog("restore: coupling id=%s of %s is busy - %s end %d left loose", tostring(r.couplingId),
                                tostring(owner.configFileName), tostring(pipe:spsGetHoseKey()), r.idx)
                        end
                        plugDone = true
                    end
                end
            end
            if not joinDone then
                local other = g_currentMission:getObjectByUniqueId(r.joinPipe)
                if other ~= nil and other.spsGetEnd ~= nil and other:spsGetEnd(r.joinEnd or 0) ~= nil
                and self.physPipes ~= nil and self.physPipes[other] then
                    local oe = other:spsGetEnd(r.joinEnd)
                    if oe.joinedTo ~= nil and oe.joinedTo.pipe == pipe then
                        joinDone = true                      -- the other pipe's restore already made the joint
                    elseif oe.joinedTo == nil and oe.coupling == nil then
                        self:physPipeJoin(pipe, r.idx, other, r.joinEnd)
                        joinDone = true
                    else
                        physLog("restore: %s end %d is busy - %s end %d left unjoined", tostring(other:spsGetHoseKey()), r.joinEnd,
                            tostring(pipe:spsGetHoseKey()), r.idx)
                        joinDone = true
                    end
                end
            end
            done = plugDone and joinDone and stowDone
            if not done then
                r.ticks = r.ticks + 1
                if r.ticks > SPS_PHYS_RESTORE_TICKS then
                    physLog("restore: gave up on %s end %s (owner %s / pipe %s / holder vehicle %s never registered)", tostring(pipe:spsGetHoseKey()),
                        tostring(r.idx), tostring(r.owner), tostring(r.joinPipe), tostring(r.stowOwner))
                    done = true
                end
            end
        end
        if done then table.remove(list, i) end
    end
end

-- [SPS 1.0.1.8] Re-open the valves that were open at save time on couplings a restored physical pipe end plugged
-- into. Lane fittings open at once (ball valve, no condition); a slurry coupler valve waits until its coupling is
-- connected (the chain's last end is back) - same server path as the player's R (applyValveState + chain
-- propagation). Server only, like the restore itself; joiners get the open valves from the join dump.
function SlurryPipeManager:_physTryRestoreValves()
    local list = self._physValveRestores
    if list == nil or #list == 0 or g_server == nil then return end
    for i = #list, 1, -1 do
        local v = list[i]
        local done = false
        local c = self:_physFindCouplingById(v.owner, v.couplingId, v.isPlaceable, v.isLane, v.isSprayer)
        if c == nil then
            done = true
        elseif v.isLane then
            self:applyLaneFittingValve(c, true)
            done = true
        elseif v.isSprayer then
            -- [SPS 1.0.1.9] sprayer flow (B) was on at save time: re-open once the chain has connected again. The
            -- sprayer vehicle is the coupling's owner or its partner's; onSprayerToggleValve is the B key (state +
            -- couplings + events + engine sound) and only opens while a pipe is connected.
            if c.isConnected then
                local veh = c.placeable == nil and c.object or nil
                local partner = c.connectedPartnerCoupling
                if (veh == nil or self:getSprayerVehicleEntry(veh) == nil) and partner ~= nil and partner.placeable == nil then veh = partner.object end
                local entry = veh ~= nil and self:getSprayerVehicleEntry(veh) or nil
                if entry ~= nil and not entry.state.valveOpen then
                    self:onSprayerToggleValve(veh)
                    physLog("restore: sprayer flow reopened on %s (coupling id=%s)", tostring(veh.configFileName), tostring(c.id))
                end
                done = true
            else
                v.ticks = v.ticks + 1
                if v.ticks > SPS_PHYS_RESTORE_TICKS then done = true end
            end
        elseif c.valveOpen or c.valveType == SPS_VALVE_TYPE_HYDRAULIC then
            done = true   -- hydraulic: the cab valve (vehicle state) is restored with the vehicle, never from the pipe end
        elseif c.isConnected then
            self:applyValveState(not v.isPlaceable and v.owner or nil, c.id, true, c)
            if self._propagateValveState ~= nil then self:_propagateValveState(c, true) end
            physLog("restore: valve reopened on coupling id=%s of %s", tostring(c.id), tostring(v.owner.configFileName))
            done = true
        else
            v.ticks = v.ticks + 1
            if v.ticks > SPS_PHYS_RESTORE_TICKS then
                physLog("restore: gave up reopening the valve of coupling id=%s of %s (never connected)",
                    tostring(c.id), tostring(v.owner.configFileName))
                done = true
            end
        end
        if done then table.remove(list, i) end
    end
end

-- Called from applyDisconnect for the coupling being disconnected (NOT its partner): free the
-- physical pipe end plugged into it, if any.
function SlurryPipeManager:_physFreeCoupling(coupling)
    if coupling == nil or coupling.physPipe == nil then return end
    if coupling._physKeepEnd then return end   -- middle-of-chain break: the end stays plugged in
    local pipe, idx = coupling.physPipe, coupling.physPipeEnd
    coupling.physPipe, coupling.physPipeEnd = nil, nil
    if pipe ~= nil and pipe.spsDetachEnd ~= nil then
        pipe:spsDetachEnd(idx)
    end
end

-- ---------------------------------------------------------------------------
-- STOW (William 2026-10-18/19): holders (<pipeHolders><pipeHolder nodeName radius/>) carry SLOTS - the placements a
-- modder captured in GIANTS Editor (placementPipes/SPS_PipePlacement.lua): child groups of the holder node named
-- slurryNN / waterNN with p01..pNN point transforms. Family-exclusive: once a holder holds a slurry pipe its water
-- slots are closed, and the other way round. First free slot of the family in node order fills first. The body
-- placement lives in SPSHoseItem:spsStow / spsPlaceStow; this is the model, the lookup, the MP wrapper, the apply.
-- ---------------------------------------------------------------------------
SlurryPipeManager.PHYS_FAMILY_PIPES = { slurry = { FM = true, FF = true, MM = true }, water = { WATER = true, MILK = true } }

function SlurryPipeManager.physFamilyOf(hoseKey)
    hoseKey = string.upper(tostring(hoseKey or ""))
    if SlurryPipeManager.PHYS_FAMILY_PIPES.water[hoseKey] then return "water" end
    return "slurry"
end

local function childByName(parent, name)
    if not nodeOk(parent) or name == nil then return nil end
    for i = 0, getNumOfChildren(parent) - 1 do
        local c = getChildAt(parent, i)
        if getName(c) == name then return c end
    end
    return nil
end

-- A slot from a placement group: its family (from pipes= or the name), the hose keys it takes, its points p01..pNN.
function SlurryPipeManager._physMakeSlot(name, node, pipesStr)
    local pipes, family = nil, nil
    if pipesStr ~= nil and pipesStr ~= "" then
        pipes = {}
        for k in string.gmatch(string.upper(pipesStr), "%S+") do pipes[k] = true end
        family = (pipes.WATER or pipes.MILK) and "water" or "slurry"
    else
        local lower = string.lower(name or "")
        family = (string.find(lower, "^water") or string.find(lower, "^milk")) and "water" or "slurry"
        pipes = SlurryPipeManager.PHYS_FAMILY_PIPES[family]
    end
    local pts = {}
    for i = 0, getNumOfChildren(node) - 1 do
        local c = getChildAt(node, i)
        local n = string.match(getName(c) or "", "^p(%d+)$")
        if n ~= nil then pts[#pts + 1] = { node = c, order = tonumber(n) } end
    end
    table.sort(pts, function(x, y) return x.order < y.order end)
    local points = {}
    for i, e in ipairs(pts) do points[i] = e.node end
    -- [SPS 1.0.1.8] chain length of the slot (the points are fixed children of the holder, so it never changes):
    -- the length rule in _physHolderSlotFor keeps a 6 m pipe off a slot captured with a 4 m pipe
    local length = 0
    for i = 2, #points do
        local ax, ay, az = getWorldTranslation(points[i - 1])
        local bx, by, bz = getWorldTranslation(points[i])
        length = length + MathUtil.vector3Length(bx - ax, by - ay, bz - az)
    end
    return { name = name, node = node, family = family, pipes = pipes, points = points, pipe = nil, length = length }
end

-- A slot's chain runs through the body centres, so it is a little shorter than the pipe it was captured with
-- (4.10 m pipe -> 3.82 m chain on the profi2). A slot FITS a pipe when chain >= PHYS_SLOT_FIT x the pipe's rest length.
SlurryPipeManager.PHYS_SLOT_FIT = 0.8

local function physRestLengthOf(pipe)
    local spec = (pipe ~= nil and SPSHoseItem ~= nil) and pipe[SPSHoseItem.SPEC_NAME] or nil
    return spec ~= nil and spec.restLength or nil
end

function SlurryPipeManager._physFindChildByName(parent, name) return childByName(parent, name) end

function SlurryPipeManager:_physFindHolder(vehicle, holderId)
    local entry = (vehicle ~= nil and self.getVehicleEntry ~= nil) and self:getVehicleEntry(vehicle) or nil
    for _, ph in ipairs(entry ~= nil and entry.pipeHolderEntries or {}) do
        if ph.id == holderId then return ph end
    end
    return nil
end

function SlurryPipeManager._physFindSlot(ph, slotName)
    for _, sl in ipairs(ph ~= nil and ph.slots or {}) do
        if sl.name == slotName then return sl end
    end
    return nil
end

-- [SPS 1.0.1.8] rack POSITION of a slot = the number its name ends in: slurry01 and slurryLong01 are the SAME place
-- on the slurry rail captured for two pipe lengths, water02 / waterLong02 the second water position. One pipe per
-- position (William 2026-10-19: "if a holder has a pipe then another cannot be added unless it's thinner pipes" -
-- the water rail has two positions, the slurry rail one). A slot without a number is position 1.
local function physSlotPosition(sl)
    return tonumber(string.match(sl.name or "", "(%d+)$")) or 1
end

-- the slot of the same family + position on this holder that holds a pipe (other than `slot` itself), or nil
function SlurryPipeManager._physSlotPositionTaken(ph, slot)
    local pos = physSlotPosition(slot)
    for _, o in ipairs(ph.slots or {}) do
        if o ~= slot and o.pipe ~= nil and o.family == slot.family and physSlotPosition(o) == pos then return o end
    end
    return nil
end

-- family currently locking the holder (any occupied slot), or nil
function SlurryPipeManager._physHolderLock(ph)
    for _, sl in ipairs(ph.slots or {}) do
        if sl.pipe ~= nil then return sl.family end
    end
    return nil
end

-- The free slot of this pipe's family that FITS the pipe, nil when the holder is locked to the other family or full.
-- [SPS 1.0.1.8 length rule, William 2026-10-19: "something must say this is a 6 m pipe so add it to the 6 m holder
-- and not the 4 m holder"] a slot fits when its chain is at least PHYS_SLOT_FIT x the pipe's rest length; of the
-- fitting free slots the SHORTEST chain wins (node order on a tie), so a 4 m pipe takes a 4 m slot while one is
-- free and a 6 m pipe only ever a 6 m slot. restLength nil = no length rule (first free slot, as before).
-- Also returns free / total of the FITTING slots of that family on the holder.
function SlurryPipeManager._physHolderSlotFor(ph, hoseKey, restLength)
    local family = SlurryPipeManager.physFamilyOf(hoseKey)
    local lock = SlurryPipeManager._physHolderLock(ph)
    local best, free, total = nil, 0, 0
    for _, sl in ipairs(ph.slots or {}) do
        if sl.family == family and sl.pipes[string.upper(tostring(hoseKey))]
           and (restLength == nil or sl.length == nil or sl.length >= restLength * SlurryPipeManager.PHYS_SLOT_FIT) then
            total = total + 1
            if sl.pipe == nil and SlurryPipeManager._physSlotPositionTaken(ph, sl) == nil then
                free = free + 1
                if best == nil or (sl.length or 0) < (best.length or 0) then best = sl end
            end
        end
    end
    if lock ~= nil and lock ~= family then return nil, 0, total end
    return best, free, total
end

-- Every holder in reach of a held FREE pipe that can take it: { holder, slot, dist, free, total }, nearest first.
function SlurryPipeManager:findPipeHoldersForPipe(pipe)
    local out = {}
    if pipe == nil or pipe.spsIsStowed == nil or pipe:spsIsStowed() then return out end
    if pipe:spsIsEndBusy(1) or pipe:spsIsEndBusy(2) then return out end
    local n = #pipe.components
    local comp = pipe.components[math.max(1, math.floor((n + 1) / 2))]
    if comp == nil or not nodeOk(comp.node) then return out end
    local x, y, z = getWorldTranslation(comp.node)
    local key = pipe.spsGetHoseKey ~= nil and pipe:spsGetHoseKey() or "FM"
    for _, ph in ipairs(self.pipeHolderEntries or {}) do
        if nodeOk(ph.node) then
            local hx, hy, hz = getWorldTranslation(ph.node)
            local d = MathUtil.vector3Length(x - hx, y - hy, z - hz)
            if d <= (ph.radius or 1.0) then
                local slot, free, total = SlurryPipeManager._physHolderSlotFor(ph, key, physRestLengthOf(pipe))
                if slot ~= nil then out[#out + 1] = { holder = ph, slot = slot, dist = d, free = free, total = total } end
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

function SlurryPipeManager:physPipeStow(pipe, vehicle, holderId, slotName)
    if pipe == nil or vehicle == nil or holderId == nil then return end
    if g_server ~= nil then self:applyPhysPipeStow(pipe, vehicle, holderId, slotName) end
    if SPSPhysPipeStowEvent ~= nil then SPSPhysPipeStowEvent.sendEvent(pipe, vehicle, holderId, slotName, true) end
end

function SlurryPipeManager:physPipeUnstow(pipe)
    if pipe == nil then return end
    if g_server ~= nil then self:applyPhysPipeUnstow(pipe) end
    if SPSPhysPipeStowEvent ~= nil then SPSPhysPipeStowEvent.sendEvent(pipe, nil, 0, "", false) end
end

function SlurryPipeManager:applyPhysPipeStow(pipe, vehicle, holderId, slotName, isRetry)
    if pipe == nil or pipe.spsStow == nil then return false end
    local ph = self:_physFindHolder(vehicle, holderId)
    if ph == nil then
        -- [SPS 1.0.1.9] late-joining client: the rack's vehicle has not registered its holders yet -> retry later
        if g_server == nil and vehicle ~= nil and not vehicle.isDeleted and not pipe.isDeleted then
            if isRetry then return false, true end
            if self:_physDefer("stow", { pipe, vehicle, holderId, slotName },
                string.format("holder id=%s of %s not registered yet", tostring(holderId), tostring(vehicle.configFileName))) then
                return false
            end
        end
        physWarn("stow: holder id=%s not found on %s", tostring(holderId), tostring(vehicle and vehicle.configFileName))
        return false
    end
    local key = pipe.spsGetHoseKey ~= nil and pipe:spsGetHoseKey() or "FM"
    local slot = (slotName ~= nil and slotName ~= "") and SlurryPipeManager._physFindSlot(ph, slotName) or nil
    local rest = physRestLengthOf(pipe)
    if slot ~= nil and rest ~= nil and slot.length ~= nil and slot.length < rest * SlurryPipeManager.PHYS_SLOT_FIT then
        -- a named slot (client request / savegame) that is too short for this pipe: pick a fitting one instead
        physLog("stow: slot '%s' (chain %.2f m) is too short for the %.2f m %s pipe - looking for a longer slot", tostring(slot.name), slot.length, rest, tostring(key))
        slot = nil
    end
    if slot == nil then slot = SlurryPipeManager._physHolderSlotFor(ph, key, rest) end
    if slot == nil then
        physLog("stow: holder id=%s of %s has no free slot long enough for a %s pipe (%.2f m)", tostring(holderId), tostring(vehicle.configFileName), tostring(key), rest or 0)
        return false
    end
    if slot.pipe ~= nil and slot.pipe ~= pipe then
        physLog("stow: slot '%s' of holder id=%s is taken", tostring(slot.name), tostring(holderId))
        return false
    end
    local blocker = SlurryPipeManager._physSlotPositionTaken(ph, slot)
    if blocker ~= nil and slot.pipe ~= pipe then
        physLog("stow: slot '%s' of holder id=%s shares its rack position with '%s', which holds a pipe", tostring(slot.name), tostring(holderId), tostring(blocker.name))
        return false
    end
    local lock = SlurryPipeManager._physHolderLock(ph)
    if lock ~= nil and lock ~= slot.family and slot.pipe ~= pipe then
        physLog("stow: holder id=%s holds %s pipes - no %s pipe", tostring(holderId), lock, slot.family)
        return false
    end
    if not pipe:spsStow(ph, slot) then
        physLog("stow: %s pipe refused slot '%s' (an end plugged / joined, or the slot has no points)", tostring(key), tostring(slot.name))
        return false
    end
    return true
end

function SlurryPipeManager:applyPhysPipeUnstow(pipe)
    if pipe == nil or pipe.spsUnstow == nil then return false end
    return pipe:spsUnstow()
end

-- ---------------------------------------------------------------------------
-- DOCKING STATION ON A VEHICLE FRAME (William 2026-10-19): <dockingStationHolders><dockingStationHolder id nodeName
-- radius/> on a vehicle (SlurryPipeManager registerVehicle -> dsHolderEntries). Holding the SPS Docking Station with
-- its base within radius of the holder node offers "place" (SPSHoseItemHands); the station rides the node
-- (SPSDockingStation:spsDsStow, one body kinematic, VEHICLE collision off). One station per holder. Grabbing it off
-- the frame releases it. Same shape as the pipe stow: model + lookup + MP wrapper + apply + save restore.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_dsFindHolder(vehicle, holderId)
    local entry = (vehicle ~= nil and self.getVehicleEntry ~= nil) and self:getVehicleEntry(vehicle) or nil
    for _, dh in ipairs(entry ~= nil and entry.dsHolderEntries or {}) do
        if dh.id == holderId then return dh end
    end
    return nil
end

-- Every FREE holder within reach of a held station's base: { holder, dist }, nearest first.
function SlurryPipeManager:findDsHoldersForStation(station)
    local out = {}
    if station == nil or station.spsDsIsStowed == nil or station:spsDsIsStowed() then return out end
    local comp = station.components ~= nil and station.components[1] or nil
    if comp == nil or not nodeOk(comp.node) then return out end
    local x, y, z = getWorldTranslation(comp.node)
    for _, dh in ipairs(self.dsHolderEntries or {}) do
        if dh.station == nil and nodeOk(dh.node) then
            local hx, hy, hz = getWorldTranslation(dh.node)
            local d = MathUtil.vector3Length(x - hx, y - hy, z - hz)
            if d <= (dh.radius or 1.5) then out[#out + 1] = { holder = dh, dist = d } end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

function SlurryPipeManager:dsStow(station, vehicle, holderId)
    if station == nil or vehicle == nil or holderId == nil then return end
    if g_server ~= nil then self:applyDsStow(station, vehicle, holderId) end
    if SPSDsStowEvent ~= nil then SPSDsStowEvent.sendEvent(station, vehicle, holderId, true) end
end

function SlurryPipeManager:dsUnstow(station)
    if station == nil then return end
    if g_server ~= nil then self:applyDsUnstow(station) end
    if SPSDsStowEvent ~= nil then SPSDsStowEvent.sendEvent(station, nil, 0, false) end
end

function SlurryPipeManager:applyDsStow(station, vehicle, holderId, isRetry)
    if station == nil or station.spsDsStow == nil then return false end
    local dh = self:_dsFindHolder(vehicle, holderId)
    if dh == nil then
        -- [SPS 1.0.1.9] late-joining client: the frame's vehicle has not registered its holder yet -> retry later
        if g_server == nil and vehicle ~= nil and not vehicle.isDeleted and not station.isDeleted then
            if isRetry then return false, true end
            if self:_physDefer("dsStow", { station, vehicle, holderId },
                string.format("docking station holder id=%s of %s not registered yet", tostring(holderId), tostring(vehicle.configFileName))) then
                return false
            end
        end
        physWarn("docking station: holder id=%s not found on %s", tostring(holderId), tostring(vehicle and vehicle.configFileName))
        return false
    end
    if dh.station ~= nil and dh.station ~= station then
        physLog("docking station: holder id=%s of %s is taken", tostring(holderId), tostring(vehicle.configFileName))
        return false
    end
    return station:spsDsStow(dh)
end

function SlurryPipeManager:applyDsUnstow(station)
    if station == nil or station.spsDsUnstow == nil then return false end
    return station:spsDsUnstow()
end

-- Savegame: the station rode a vehicle's frame - put it back once that vehicle has registered (same give-up as the pipes).
function SlurryPipeManager:dsQueueRestore(station, ownerId, holderId)
    if station == nil or ownerId == nil then return end
    self._dsRestores = self._dsRestores or {}
    table.insert(self._dsRestores, { station = station, owner = ownerId, holderId = holderId or 1, ticks = 0 })
    physLog("restore queued: docking station on holder id=%s of %s", tostring(holderId), tostring(ownerId))
end

function SlurryPipeManager:dsCancelRestore(station)
    if self._dsRestores == nil then return end
    for i = #self._dsRestores, 1, -1 do
        if self._dsRestores[i].station == station then table.remove(self._dsRestores, i) end
    end
end

function SlurryPipeManager:_dsTryResolveRestores()
    local list = self._dsRestores
    if list == nil or #list == 0 or g_currentMission == nil then return end
    for i = #list, 1, -1 do
        local r = list[i]
        local st = r.station
        local done = false
        if st == nil or st.spsDsStow == nil or st.isDeleted or not nodeOk(st.rootNode) or st:spsDsIsStowed() then
            done = true
        else
            local owner = g_currentMission:getObjectByUniqueId(r.owner)
            if owner ~= nil and self:_dsFindHolder(owner, r.holderId) ~= nil then
                self:dsStow(st, owner, r.holderId)
                done = true
            else
                r.ticks = r.ticks + 1
                if r.ticks > SPS_PHYS_RESTORE_TICKS then
                    physLog("restore: gave up on the docking station's holder (vehicle %s never registered) - it stays where it loaded", tostring(r.owner))
                    done = true
                end
            end
        end
        if done then table.remove(list, i) end
    end
end


-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] <physicalModeHide> (William 2026-10-22): nodes a config hides while PHYSICAL pipes are in use and shows
-- again in the original system - e.g. the Joskin Cobra's side pipe (Embout), whose rack takes the store-bought pipes in
-- physical mode. Inside <slurryPipeSystem> of a vehicle or placeable config, bundled or embedded:
--     <physicalModeHide>
--         <node name="Embout"/>
--     </physicalModeHide>
-- A name matches EVERY node of that name in the object's components: its own i3d and the SPS nodeTree nodes linked into
-- it. Visual by default (setVisibility); each node's own visibility at registration is what the original mode restores.
-- collision="true" on a <node> also switches collision off while hidden: every shape at or under the node gets its
-- collision filter group + mask saved and set to 0, and restored in the original mode (the game's own runtime switch,
-- setCollisionFilterGroup / -Mask - reversible live, unlike removeFromPhysics on a vehicle compound child). A shape
-- without collision is unaffected, so the whole subtree can be treated alike.
-- Applied when the object registers and on every pipe-mode change (applyPhysicalPipesSetting), on every peer - the
-- mode is synced by SPSSettingsSyncEvent, the nodes are not, so SP, host, client and dedicated server all agree.
-- ---------------------------------------------------------------------------
local function physHideCollect(node, name, out)
    if node == nil or node == 0 or not entityExists(node) then return end
    if getName(node) == name then table.insert(out, node) end
    for i = 0, getNumOfChildren(node) - 1 do
        physHideCollect(getChildAt(node, i), name, out)
    end
end

-- every shape at or under node, with its collision filter group + mask as loaded
local function physHideShapes(node, out)
    if node == nil or node == 0 or not entityExists(node) then return end
    if getHasClassId(node, ClassIds.SHAPE) then
        table.insert(out, { node = node, group = getCollisionFilterGroup(node), mask = getCollisionFilterMask(node) })
    end
    for i = 0, getNumOfChildren(node) - 1 do
        physHideShapes(getChildAt(node, i), out)
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Shared configuration gate - the same attributes and meaning as the fillArm / pipeCoupling gates
-- (README 01 §13), for any element at `key`:
--   #configType (default cylindered) + #cylinderedConfigIndex = 0-based active index list ("1,3")
--   #configType2 + #configIndex2 + #configMode2 (require | exclude) = optional second condition
-- No gate attributes = always passes. An object without that configuration type also passes (as the other gates).
-- Works for vehicles and placeables (both carry .configurations, 1-based).
-- ---------------------------------------------------------------------------
local function cfgActive(object, configType)
    local cfg = object ~= nil and object.configurations or nil
    local v = cfg ~= nil and cfg[configType or "cylindered"] or nil
    return v ~= nil and v - 1 or nil
end

local function cfgMatches(indexStr, active)
    if indexStr == nil or active == nil then return false end
    for token in string.gmatch(indexStr, "[^,%s]+") do
        if tonumber(token) == active then return true end
    end
    return false
end

function SlurryPipeManager:configGatePasses(object, xmlFile, key)
    local idx = xmlFile:getString(key .. "#cylinderedConfigIndex")
    if idx ~= nil then
        local active = cfgActive(object, xmlFile:getString(key .. "#configType", "cylindered"))
        if active ~= nil and not cfgMatches(idx, active) then return false end
    end
    local idx2 = xmlFile:getString(key .. "#configIndex2")
    if idx2 ~= nil then
        local active2 = cfgActive(object, xmlFile:getString(key .. "#configType2", "cylindered"))
        if active2 ~= nil then
            local m = cfgMatches(idx2, active2)
            if xmlFile:getString(key .. "#configMode2", "require") == "exclude" then
                if m then return false end
            elseif not m then
                return false
            end
        end
    end
    return true
end

function SlurryPipeManager:readPhysModeHide(xmlFile, kp, components, label, object)
    local list = {}
    local i = 0
    while true do
        local key = string.format("%sslurryPipeSystem.physicalModeHide.node(%d)", kp or "", i)
        if not xmlFile:hasProperty(key) then break end
        -- per-node config gate: hide only the parts of options this object was bought with
        local name = self:configGatePasses(object, xmlFile, key) and xmlFile:getString(key .. "#name") or nil
        local collision = xmlFile:getBool(key .. "#collision", false)
        if name ~= nil and name ~= "" then
            local found = {}
            for _, comp in ipairs(components or {}) do
                physHideCollect(comp.node, name, found)
            end
            for _, node in ipairs(found) do
                local h = { node = node, visible = getVisibility(node) }
                if collision then
                    h.shapes = {}
                    physHideShapes(node, h.shapes)
                end
                table.insert(list, h)
            end
            if #found == 0 then
                print(string.format("[SPS] WARNING: physicalModeHide node '%s' not found on %s", name, tostring(label)))
            end
        end
        i = i + 1
    end
    return #list > 0 and list or nil
end

function SlurryPipeManager:applyPhysModeHide(list)
    if list == nil then return end
    local physical = self.physicalPipesEnabled == true
    for _, h in ipairs(list) do
        if entityExists(h.node) then
            setVisibility(h.node, h.visible and not physical)
        end
        for _, sh in ipairs(h.shapes or {}) do
            if entityExists(sh.node) then
                setCollisionFilterGroup(sh.node, physical and 0 or sh.group)
                setCollisionFilterMask(sh.node, physical and 0 or sh.mask)
            end
        end
    end
end

function SlurryPipeManager:applyAllPhysModeHides()
    for _, e in ipairs(self.registeredVehicles or {}) do self:applyPhysModeHide(e.physModeHide) end
    for _, e in ipairs(self.registeredPlaceables or {}) do self:applyPhysModeHide(e.physModeHide) end
end


-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] A pipe holder / docking-station holder whose config gate fails does not exist - and the SPS nodeTree
-- visuals around it (a rack, the docking-station frame) must go too (William 2026-10-23: the Samson pgII20's frame
-- showed on every tanker, with or without the docking funnel station). From each gated holder node climb towards the
-- linked nodeTree node it hangs under, stopping below any ancestor that still holds an ACTIVE holder (one rack of two
-- on a shared "pipeHolder" group), and hide that branch. Only SPS-linked branches: a holder node that is not inside
-- one (found in the vehicle's own i3d) is hidden alone, never a vehicle part above it.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:hideGatedHolderBranches(entry)
    local gated = entry ~= nil and entry.gatedHolderNodes or nil
    if gated == nil or #gated == 0 then return end
    local keep = {}
    for _, ph in ipairs(entry.pipeHolderEntries or {}) do keep[#keep + 1] = ph.node end
    for _, dh in ipairs(entry.dsHolderEntries or {}) do keep[#keep + 1] = dh.node end
    local linked = {}
    for _, n in ipairs(entry.linkedNodes or {}) do linked[n] = true end
    local function isUnder(anc, node)
        local p = node
        while p ~= nil and p ~= 0 do
            if p == anc then return true end
            p = getParent(p)
        end
        return false
    end
    local function linkedRootOf(node)
        local p = node
        while p ~= nil and p ~= 0 do
            if linked[p] then return p end
            p = getParent(p)
        end
        return nil
    end
    for _, node in ipairs(gated) do
        if node ~= nil and node ~= 0 and entityExists(node) then
            local top = node
            if linkedRootOf(node) ~= nil then
                while not linked[top] do
                    local parent = getParent(top)
                    if parent == nil or parent == 0 then break end
                    local holdsActive = false
                    for _, k in ipairs(keep) do
                        if isUnder(parent, k) then holdsActive = true break end
                    end
                    if holdsActive then break end
                    top = parent
                end
            end
            setVisibility(top, false)
        end
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.9] DEV console: spawn a physical pipe 3 m in front of the player (William 2026-10-26: "how do I spawn a
-- pipe in front of me" - the shop delivers to the dealer). Same vehicle-loading call as the IBC spawn
-- (SPSM_IBC spawnAndConnectIBC). Server / single player only (VehicleLoadingData loads on the server).
--   spsSpawnPipe [slurry|water|milk] [4|6] [FM|FF|MM]      defaults: slurry 4 FM
-- ---------------------------------------------------------------------------
SPSPhysPipeConsole = {}

function SPSPhysPipeConsole.spawn(_, typeArg, lenArg, endsArg)
    local usage = "usage: spsSpawnPipe [slurry|water|milk] [4|6] [FM|FF|MM]"
    if g_server == nil then return "spsSpawnPipe: single player / server only" end
    if g_localPlayer == nil or g_currentMission == nil or g_currentMission.spsModDirectory == nil then return "spsSpawnPipe: no player / mod directory" end
    local typeIdx = ({ slurry = 1, water = 2, milk = 3 })[string.lower(tostring(typeArg or "slurry"))]
    if typeIdx == nil then return usage end
    local lenIdx = (tostring(lenArg or "4") == "6") and 2 or 1
    local endsIdx = ({ fm = 1, ff = 2, mm = 3 })[string.lower(tostring(endsArg or "FM"))]
    if endsIdx == nil then return usage end
    if typeIdx ~= 1 then endsIdx = 1 end
    local px, _, pz = g_localPlayer:getGraphicalPosition()
    local yaw = g_localPlayer:getGraphicalYaw() or 0
    local x, z = px + math.sin(yaw) * 3.0, pz + math.cos(yaw) * 3.0
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.4
    local xml = Utils.getFilename("vehicles/hoses/spsPipe.xml", g_currentMission.spsModDirectory)
    local farmId = g_localPlayer.farmId or (g_currentMission.getFarmId ~= nil and g_currentMission:getFarmId()) or 1
    local data = VehicleLoadingData.new()
    data:setFilename(xml)
    data:setPosition(x, y, z)
    data:setRotation(0, yaw + math.pi * 0.5, 0)   -- the pipe lies ACROSS in front of the player (its length runs along its +Z)
    data:setPropertyState(VehiclePropertyState.OWNED)
    data:setOwnerFarmId(farmId)
    data:setConfigurations({ spsPipeType = typeIdx, spsPipeLength = lenIdx, spsPipeEnds = endsIdx })
    data:load(SPSPhysPipeConsole.onSpawned, SPSPhysPipeConsole, nil)
    local note = (g_slurryPipeManager ~= nil and g_slurryPipeManager.physicalPipesEnabled ~= true) and " (NOTE: pipe mode is ORIGINAL - physical pipes do nothing until you switch)" or ""
    return string.format("spsSpawnPipe: %s %d m %s pipe 3 m ahead%s", ({ "slurry", "water", "milk" })[typeIdx], lenIdx == 2 and 6 or 4,
        ({ "F/M", "F/F", "M/M" })[endsIdx], note)
end

function SPSPhysPipeConsole.onSpawned(_, vehicles, loadState)
    if loadState ~= VehicleLoadingState.OK or vehicles == nil or vehicles[1] == nil then
        print("[SPS PHYS] spsSpawnPipe: spawn failed (state=" .. tostring(loadState) .. ")")
        return
    end
    local v = vehicles[1]
    print(string.format("[SPS PHYS] spsSpawnPipe: spawned %s", tostring(v.spsGetHoseKey ~= nil and v:spsGetHoseKey() or v.configFileName)))
end

if addConsoleCommand ~= nil then
    addConsoleCommand("spsSpawnPipe", "DEV: spawn a physical pipe 3 m in front of the player: spsSpawnPipe [slurry|water|milk] [4|6] [FM|FF|MM]", "spawn", SPSPhysPipeConsole)
end
