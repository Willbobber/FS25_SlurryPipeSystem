-- ============================================================================
-- SPSM_FrontMount.lua — Front-mount pass-through fill arm support
-- FS25_SlurryPipeSystem — Author: Oscar Mods
-- ============================================================================
-- Phase 1 (this file's current scope): RECEIVER DETECTION ONLY.
--
-- A "front mount" is a pass-through pump unit: capacity-0 own fill unit, an HVP
-- pump, a fill arm and a coupler. It never stores liquid — every flow session it
-- runs has some OTHER endpoint on the tank side. The tank side is the vehicle
-- its Giants connection hoses are physically attached to (the "receiver"),
-- e.g. the Claas Saddle Trac rear-mount barrel or the semi-trailed tanker.
--
-- Receiver resolution is DERIVED, never synced: connection hoses connect and
-- disconnect deterministically on server and clients from vanilla-synced attach
-- state (ConnectionHoses:onPostAttach/onPreDetach), so every peer computes the
-- same receiver from the same hose state. No SPS events are needed.
--
-- Vanilla state read (all field names traced from FS25 ConnectionHoses.lua):
--   * front.spec_connectionHoses.updateableHoses     — currently connected hoses;
--     each entry carries .type/.specType (loadHoseNode), .connectedObject and
--     .targetHose (set in connectHose when the hose plugs into a target).
--   * bridge.spec_connectionHoses.targetNodeToToolConnection[targetIndex]
--     — maps a target node to its tool connection ("bridge" = the vehicle whose
--     target the hose plugged into, normally the tractor; TOP_RIGHT tool
--     connectors are auto-registered on it by vanilla
--     registerAdditionalToolConnectionHoses).
--   * toolConnection.connected == true               — both ends bridged
--     (set in updateToolConnectionHose, cleared on disconnect).
--   * bridge.spec_connectionHoses.targetNodes[otherIndex].connectedObject
--     — the implement plugged into the OTHER end of the tool connection:
--     that vehicle is the receiver candidate.
--
-- Which hoses count as the slurry circuit is CONFIG-DRIVEN, never hardcoded:
-- the front mount's config declares the qualifying hoses on two attributes:
--   <frontMount enabled="true"
--               hoseSpecTypes="saddleTracSlurryTanker saddleTracSlurryTankerSemi"
--               hoseTypes="TOOL_CONNECTOR_TOP_RIGHT"/>
-- hoseSpecTypes matches specType'd hoses (xerion pairings); hoseTypes matches
-- hoses WITHOUT a specType by their plain type (normal tractors' carriers).
-- Any pack's hose naming works without Lua changes.
--
-- A resolved receiver must be SPS-registered and expose at least one fill unit
-- with capacity > 0 that accepts a pumpable liquid (LIQUIDMANURE, DIGESTATE or
-- WATER — SPS pumps water too; the eventual flow session validates the actual
-- session fill type, this phase only proves a plausible tank exists).
--
-- Debug: channel "SPSM_FrontMount" (spsDebug SPSM_FrontMount on). Traces print
-- only when the resolution RESULT CHANGES, never per tick.
-- ============================================================================

print("[SPS BUILD] SPSM_FrontMount 1.0.0.7 loaded")

-- Fill types a receiver tank must plausibly accept for detection to call it a
-- receiver. Kept local + name-resolved at first use (FillType indices are not
-- guaranteed populated at source() time).
local function getPumpableFillTypes()
    if SlurryPipeManager._fmPumpableFillTypes == nil then
        local list = {}
        for _, name in ipairs({ "LIQUIDMANURE", "DIGESTATE", "WATER" }) do
            local ft = FillType[name]
            if ft ~= nil then
                table.insert(list, ft)
            end
        end
        SlurryPipeManager._fmPumpableFillTypes = list
    end
    return SlurryPipeManager._fmPumpableFillTypes
end

-- ---------------------------------------------------------------------------
-- isFrontMountVehicle: true when the vehicle's SPS config declared
-- <frontMount enabled="true"/>.
-- ---------------------------------------------------------------------------
-- ===========================================================================
-- [SPS 1.0.0.7] FRONT-MOUNT PASS-THROUGH CASCADE
-- ===========================================================================
-- The front mount is a pass-through pump with TWO tank-side outlets, resolved
-- fresh every tick in strict priority order:
--   1. Its own pipe coupling(s): connected AND manual valve open. Far side
--      resolved through resolveSourceForCouplingPartner, so vehicles, chained
--      pipes (via the chain anchor) and placeable stores all work. A
--      connected pipe with the valve CLOSED is inert by design — the cab
--      hydraulic valve gates the arm path, the coupling's own manual valve
--      gates the coupler path, so neither bypasses the other.
--   2. The hose-bridged rear receiver (tool-connector bridge).
-- Filling: liquid goes to the FIRST target with free capacity; unloading:
-- drawn from the FIRST target with content. Because the pick re-evaluates
-- every tick, the whole cascade emerges from that one rule: the bez-pipe
-- tanker fills first, overflow goes to the rear tanker, and if the bez-pipe
-- tanker is drawn down mid-fill the flow switches back to top it up, then
-- resumes — and the mirror of all of that when unloading.
-- MP: reads only replicated state (coupling isConnected/valveOpen are event-
-- synced, the receiver derives from vanilla-synced hose state), transfers go
-- through the existing server-gated removeFromSource/addToSource/transferFill
-- paths — no new sync events needed.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- getFrontMountTankTargets: ordered tank-side target list for this tick.
-- Partner flowDirection restriction semantics (same reading as tickFlow's
-- coupling branch): partner "DISCHARGE" = you may only discharge INTO that
-- port; partner "FILL" = you may only fill FROM it; nil/"BOTH" = both.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:getFrontMountTankTargets(vehicle)
    local targets = {}
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil or entry.frontMount == nil then return targets end
    for _, c in ipairs(entry.couplingEntries or {}) do
        if c.isConnected == true and c.valveOpen == true and c.connectedPartnerCoupling ~= nil then
            local partner = c.connectedPartnerCoupling
            local effectivePartner = partner
            local intact = true
            if partner.isChainTerminus and partner.chain ~= nil then
                effectivePartner = partner.chain.anchorCoupling or partner
                -- Near-end bez removed mid-chain kills the target (conduit-
                -- branch pattern: vehicle-anchored chains only).
                local anchor = partner.chain.anchorCoupling
                if anchor ~= nil and anchor.placeable == nil then
                    local seg1 = partner.chain.segments and partner.chain.segments[1]
                    if seg1 ~= nil and seg1.chainStartCoupling ~= nil
                       and not seg1.chainStartCoupling.isConnected then
                        intact = false
                    end
                end
            end
            if intact then
                local srcEntry = self:resolveSourceForCouplingPartner(c)
                if srcEntry ~= nil then
                    local pd = effectivePartner ~= nil and effectivePartner.flowDirection or nil
                    table.insert(targets, {
                        kind        = "coupler",
                        coupling    = c,
                        srcEntry    = srcEntry,
                        canDeposit  = (pd == nil or pd == "BOTH" or pd == "DISCHARGE"),
                        canWithdraw = (pd == nil or pd == "BOTH" or pd == "FILL"),
                    })
                end
            end
        end
    end
    local receiver, _, fui = self:getFrontMountReceiver(vehicle)
    if receiver ~= nil and fui ~= nil then
        table.insert(targets, {
            kind = "receiver", vehicle = receiver, fillUnitIndex = fui,
            canDeposit = true, canWithdraw = true,
        })
    end
    return targets
end

-- ---------------------------------------------------------------------------
-- spsFMTargetLevelAndFree: level and free capacity of a cascade target for a
-- given fill type (level/free reads mirror tickFlow's conduit branch).
-- ---------------------------------------------------------------------------
function SlurryPipeManager:spsFMTargetLevelAndFree(target, fillType)
    if target.kind == "receiver" then
        local v   = target.vehicle
        local cap = v:getFillUnitCapacity(target.fillUnitIndex) or 0
        local lvl = v:getFillUnitFillLevel(target.fillUnitIndex) or 0
        return lvl, cap - lvl
    end
    local e = target.srcEntry
    if e.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or e.type == "FILL_UNIT_ONLY" then
        if e.vehicle ~= nil then
            local cap = e.vehicle:getFillUnitCapacity(e.fillUnitIndex) or 0
            local lvl = e.vehicle:getFillUnitFillLevel(e.fillUnitIndex) or 0
            return lvl, cap - lvl
        end
    elseif e.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if e.storage ~= nil then
            local lvl  = fillType ~= nil and (e.storage:getFillLevel(fillType) or 0) or 0
            local free = fillType ~= nil
                and (e.storage:getFreeCapacity(self:resolveStoreDepositFillType(e, fillType)) or 0) or 0
            return lvl, free
        end
    end
    return 0, 0
end

-- ---------------------------------------------------------------------------
-- spsFMExternalLevelAndFree: level and free capacity of the arm's EXTERNAL
-- endpoint (boot vehicle, store, or water plane). Water (type 3) is an
-- infinite source and never a destination.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:spsFMExternalLevelAndFree(extEntry, fillType)
    if extEntry == nil then return 0, 0 end
    if extEntry.type == 3 then   -- SPSWaterPlaneManager.SOURCE_TYPE_WATER
        return math.huge, 0
    end
    if extEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extEntry.type == "FILL_UNIT_ONLY" then
        if extEntry.vehicle ~= nil then
            local cap = extEntry.vehicle:getFillUnitCapacity(extEntry.fillUnitIndex) or 0
            local lvl = extEntry.vehicle:getFillUnitFillLevel(extEntry.fillUnitIndex) or 0
            return lvl, cap - lvl
        end
    elseif extEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if extEntry.storage ~= nil then
            local lvl  = fillType ~= nil and (extEntry.storage:getFillLevel(fillType) or 0) or 0
            local free = fillType ~= nil
                and (extEntry.storage:getFreeCapacity(self:resolveStoreDepositFillType(extEntry, fillType)) or 0) or 0
            return lvl, free
        end
    end
    return 0, 0
end

-- ---------------------------------------------------------------------------
-- tickFrontMountArmCascade: the front-mount arm session tick. Called from
-- tickFlow (SPSM_Flow 1.0.1.8) INSTEAD of the legacy single-tank arm path
-- when the session vehicle is a front mount with the cab valve open. The
-- receiver target reuses the proven transferFill/transferDischarge path
-- (thickness/crust blends included); coupler targets transfer conduit-style
-- (clamped removeFromSource/addToSource), exactly the pattern of tickFlow's
-- conduit branch. All transfer helpers are server-gated internally, so this
-- runs on every peer and mutates only on the server (established model).
-- ---------------------------------------------------------------------------
function SlurryPipeManager:tickFrontMountArmCascade(session, state, pumpRunning, dt, preFillType)
    local vehicle = session.vehicle
    local targets = session.fmTargets
    if targets == nil or #targets == 0 then return end

    local function fmTrace(tag)
        if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSM_FrontMount")
           and session._fmCascade ~= tag then
            session._fmCascade = tag
            print(string.format("[SPS FM] cascade: %s %s", tostring(vehicle.configFileName), tostring(tag)))
        end
    end

    -- Aggregate tank-side content for the pressure model: any withdrawable
    -- target with content counts (drives discharge viability / backflow).
    local hasContent = false
    for _, t in ipairs(targets) do
        if t.canWithdraw then
            local ft = nil
            if t.kind == "coupler" then ft = self:_resolveSourceFillType(t.srcEntry) end
            local lvl = self:spsFMTargetLevelAndFree(t, ft)
            if t.kind == "receiver" then
                lvl = t.vehicle:getFillUnitFillLevel(t.fillUnitIndex) or 0
            end
            if (lvl or 0) > 0 then hasContent = true break end
        end
    end

    local flowDir, scalar = self:resolveCouplingFlow(vehicle, state, pumpRunning, hasContent)
    if flowDir == nil or (scalar or 0) <= 0 then
        fmTrace("no_flow_dir")
        return
    end

    local rateBase = (flowDir == SPS_DIRECTION_FILL)
        and (session.baseFillLitersPerSecond  or session.baseLitersPerSecond)
        or  (session.baseEmptyLitersPerSecond or session.baseLitersPerSecond)
    local rate = rateBase * dt * 0.001 * scalar
    rate = rate * self:getPipeLengthFalloff(vehicle)
    if rate <= 0 then return end

    if flowDir == SPS_DIRECTION_FILL then
        -- Arm draws from the external endpoint into the first depositable
        -- target with free space.
        local extSrc = self:resolveExternalSource(vehicle)
        if extSrc == nil then fmTrace("fill_no_ext_source") return end
        local fillType = self:_resolveSourceFillType(extSrc) or preFillType
        if extSrc.type == 3 then fillType = FillType.WATER end
        if fillType == nil then fmTrace("fill_no_filltype") return end
        local mult = self:getFlowRateMultiplier(extSrc)
        if mult <= 0 then
            if self:_warningIsRelevant(vehicle) then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
            end
            return
        end
        rate = rate * mult
        if rate <= 0 then return end
        for _, t in ipairs(targets) do
            if t.canDeposit then
                if t.kind == "receiver" then
                    local oldLevel = t.vehicle:getFillUnitFillLevel(t.fillUnitIndex) or 0
                    local cap      = t.vehicle:getFillUnitCapacity(t.fillUnitIndex) or 0
                    if cap - oldLevel > 0 then
                        session.tankVehicle     = t.vehicle
                        session.vehicleFillUnit = t.fillUnitIndex
                        self:transferFill(vehicle, session, rate, fillType)
                        local added = (t.vehicle:getFillUnitFillLevel(t.fillUnitIndex) or 0) - oldLevel
                        if added > 0 then
                            self:applyFillThicknessBlend(t.vehicle, oldLevel, added, self:getSourceThickness(extSrc))
                            self:applyFillCrustBlend(t.vehicle, oldLevel, added, self:getSourceCrust(extSrc))
                        end
                        fmTrace("fill->receiver")
                        return
                    end
                else
                    if self:_destAcceptsFillType(t.srcEntry, fillType) then
                        local _, free = self:spsFMTargetLevelAndFree(t, fillType)
                        if (free or 0) > 0 then
                            local srcLevel = self:spsFMExternalLevelAndFree(extSrc, fillType)
                            local amount = math.min(rate, srcLevel or 0, free)
                            if amount > 0 then
                                -- Water is an infinite source: nothing to remove.
                                if extSrc.type ~= 3 then
                                    self:removeFromSource(extSrc, amount, fillType, vehicle)
                                end
                                self:addToSource(t.srcEntry, amount, fillType, vehicle)
                                session.totalTransferred = (session.totalTransferred or 0) + amount
                                fmTrace("fill->coupler")
                                return
                            end
                        end
                    end
                end
            end
        end
        fmTrace("fill_all_targets_full")
    else
        -- Unloading: draw from the first withdrawable target with content and
        -- push out through the arm into the external endpoint.
        local extDst = self:resolveExternalSource(vehicle)
        if extDst == nil then fmTrace("empty_no_ext_dest") return end
        if extDst.type == 3 then fmTrace("empty_dest_is_water") return end
        for _, t in ipairs(targets) do
            if t.canWithdraw then
                if t.kind == "receiver" then
                    local lvl = t.vehicle:getFillUnitFillLevel(t.fillUnitIndex) or 0
                    if lvl > 0 then
                        local ft = t.vehicle:getFillUnitFillType(t.fillUnitIndex)
                        if ft ~= nil and ft ~= FillType.UNKNOWN then
                            session.tankVehicle     = t.vehicle
                            session.vehicleFillUnit = t.fillUnitIndex
                            local r = rate * self:getTankerThicknessMultiplier(t.vehicle)
                            if r > 0 then
                                self:transferDischarge(vehicle, session, r, ft)
                                fmTrace("empty<-receiver")
                                return
                            end
                        end
                    end
                else
                    local ft = self:_resolveSourceFillType(t.srcEntry)
                    if ft ~= nil then
                        local lvl = self:spsFMTargetLevelAndFree(t, ft)
                        if (lvl or 0) > 0 and self:_destAcceptsFillType(extDst, ft) then
                            local mult
                            if t.srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                                mult = self:getFlowRateMultiplier(t.srcEntry)
                            elseif t.srcEntry.vehicle ~= nil then
                                mult = self:thicknessToFlowMultiplier(self:getTankerThickness(t.srcEntry.vehicle))
                            else
                                mult = 1.0
                            end
                            if mult <= 0 then
                                if self:_warningIsRelevant(vehicle) then
                                    g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
                                end
                                return
                            end
                            local _, dstFree = self:spsFMExternalLevelAndFree(extDst, ft)
                            local amount = math.min(rate * mult, lvl, dstFree or 0)
                            if amount > 0 then
                                self:removeFromSource(t.srcEntry, amount, ft, vehicle)
                                self:addToSource(extDst, amount, ft, vehicle)
                                session.totalTransferred = (session.totalTransferred or 0) + amount
                                fmTrace("empty<-coupler")
                                return
                            end
                        end
                    end
                end
            end
        end
        fmTrace("empty_all_targets_empty")
    end
end

-- ---------------------------------------------------------------------------
-- findReceiverFillUnit: first fill unit on `vehicle` with capacity > 0 that
-- accepts any pumpable liquid. Returns fillUnitIndex or nil.
-- ---------------------------------------------------------------------------
local function findReceiverFillUnit(vehicle)
    if vehicle == nil or vehicle.spec_fillUnit == nil
       or vehicle.spec_fillUnit.fillUnits == nil
       or vehicle.getFillUnitAllowsFillType == nil then
        return nil
    end
    for i, fu in ipairs(vehicle.spec_fillUnit.fillUnits) do
        if fu.capacity ~= nil and fu.capacity > 0 then
            for _, ft in ipairs(getPumpableFillTypes()) do
                if vehicle:getFillUnitAllowsFillType(i, ft) then
                    return i
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- resolveFrontMountReceiver: walk the front mount's connected hoses for one
-- whose specType is in the configured slurry-circuit set AND whose tool
-- connection is bridged, then return the implement on the other end.
--
-- Returns: receiverVehicle|nil, reasonString, receiverFillUnitIndex|nil
-- Reasons: "ok", "not_front_mount", "no_hose_spec", "no_connected_circuit",
--          "receiver_not_registered", "receiver_no_tank"
-- ---------------------------------------------------------------------------
function SlurryPipeManager:resolveFrontMountReceiver(frontVehicle)
    local entry = self:getVehicleEntry(frontVehicle)
    if entry == nil or entry.frontMount == nil then
        return nil, "not_front_mount", nil
    end

    local fmSpec = frontVehicle.spec_connectionHoses
    if fmSpec == nil or fmSpec.updateableHoses == nil then
        return nil, "no_hose_spec", nil
    end

    local sawUnregistered, sawNoTank = nil, nil

    for _, hose in ipairs(fmSpec.updateableHoses) do
        -- [SPS 1.0.0.2] Two disjoint circuits, mirroring vanilla's matching:
        --   * hose HAS a specType  -> slurry circuit iff listed in hoseSpecTypes
        --     (xerion pairings: saddleTracSlurryTanker/...Semi)
        --   * hose has NO specType -> slurry circuit iff its plain type is
        --     listed in hoseTypes (normal tractors' side carriers:
        --     TOOL_CONNECTOR_TOP_RIGHT)
        -- A specType'd hose can never qualify through hoseTypes and vice versa.
        local isCircuit
        if hose.specType ~= nil then
            isCircuit = entry.frontMount.hoseSpecTypes[hose.specType] == true
        else
            isCircuit = hose.type ~= nil and entry.frontMount.hoseTypes ~= nil
                and entry.frontMount.hoseTypes[hose.type] == true
        end
        if isCircuit
           and hose.connectedObject ~= nil and hose.targetHose ~= nil then
            local bridge     = hose.connectedObject
            local bridgeSpec = bridge.spec_connectionHoses
            if bridgeSpec ~= nil
               and bridgeSpec.targetNodeToToolConnection ~= nil
               and bridgeSpec.targetNodes ~= nil
               and hose.targetHose.index ~= nil then
                local tc = bridgeSpec.targetNodeToToolConnection[hose.targetHose.index]
                if tc ~= nil and tc.connected == true then
                    local otherIndex = tc.startTargetNodeIndex
                    if otherIndex == hose.targetHose.index then
                        otherIndex = tc.endTargetNodeIndex
                    end
                    local otherTarget = bridgeSpec.targetNodes[otherIndex]
                    local receiver = otherTarget ~= nil and otherTarget.connectedObject or nil
                    if receiver ~= nil and receiver ~= frontVehicle then
                        if self:getVehicleEntry(receiver) == nil then
                            sawUnregistered = receiver
                        else
                            local fui = findReceiverFillUnit(receiver)
                            if fui ~= nil then
                                return receiver, "ok", fui
                            end
                            sawNoTank = receiver
                        end
                    end
                end
            end
        end
    end

    if sawUnregistered ~= nil then return nil, "receiver_not_registered", nil end
    if sawNoTank       ~= nil then return nil, "receiver_no_tank",       nil end
    return nil, "no_connected_circuit", nil
end

-- ---------------------------------------------------------------------------
-- getFrontMountReceiver: cached accessor for flow-phase consumers. Returns the
-- last update's resolution without re-walking hose state.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:getFrontMountReceiver(frontVehicle)
    local entry = self:getVehicleEntry(frontVehicle)
    if entry == nil or entry.frontMount == nil then return nil, "not_front_mount", nil end
    local fm = entry.frontMount
    return fm.receiver, fm.receiverReason or "unresolved", fm.receiverFillUnitIndex
end

-- ===========================================================================
-- [SPS 1.0.0.3] INJECTED GIANTS CONNECTION HOSES — normal-tractor pairing
-- ===========================================================================
-- The front mount's own (vanilla, untouchable) XML only carries specType'd
-- hoses (saddleTracSlurryTanker / ...Semi). Vanilla matching is strict
-- equality (ConnectionHoses:getConnectionTarget: node.specType == specType),
-- so those hoses can never plug a normal tractor's plain
-- TOOL_CONNECTOR_TOP_RIGHT carrier targets — and a plain hose can never plug
-- the Xerion's specType'd targets. SPS therefore injects PLAIN-type hoses at
-- registration, built with the exact field set vanilla
-- ConnectionHoses:loadHoseNode produces (every field traced from FS25
-- ConnectionHoses.lua lines 753-898), so all downstream vanilla code
-- (connectHose, tool-connection bridging, updateConnectionHose per-frame
-- moves, onPreDetach cleanup) treats them as native hoses:
--
--   * FRONT MOUNT hose  — declared <frontMount><hose .../></frontMount>.
--     NOT entered in spec.hoseNodesByInputAttacher, because vanilla
--     onPostAttach auto-connect must never touch it: the Xerion's front joint
--     (2) ALSO carries a plain TOOL_CONNECTOR_TOP_RIGHT carrier target
--     (rightPipe_frontConnector, xerion4000.xml), so auto-connect would put a
--     duplicate hose next to the vanilla specType pairing. Instead
--     updateFrontMounts connects it — once per attach — and ONLY when the
--     attached tractor offers NO specType'd circuit for the attach joint
--     (spsTractorOffersSpecTypeCircuit). Detach cleanup needs no SPS code:
--     vanilla onPreDetach walks spec.updateableHoses (disconnects any hose
--     whose connectedObject is the detaching tractor) and clears
--     delayedMounting entries whose sourceObject is this vehicle.
--
--   * RECEIVER hose — declared <tractorMountFillArms><hose .../> on the
--     tanker. Entered in spec.hoseNodesByInputAttacher, so vanilla
--     onPostAttach connects it exactly like an authored hose. If the tanker
--     was already attached when SPS registered it (savegame load ordering),
--     spsInjectConfiguredHoses re-runs the vanilla connect — idempotent, as
--     connectHosesToAttacherVehicle skips hoses that are already used
--     (getIsConnectionHoseUsed).
--
-- Bridging then happens entirely in vanilla: front hose plugs the tractor's
-- front carrier connector (delayedMounting until the other side exists),
-- receiver hose plugs the rear connector, updateToolConnectionHose sets
-- toolConnection.connected = true, shows the tractor's side pipe, and
-- connects both hose visuals. resolveFrontMountReceiver (above) already
-- recognises the pair through its plain-type path (frontMount#hoseTypes) —
-- no change needed there.
--
-- Optional <objectChange node=".." visibilityActive=".." visibilityInactive=".."/>
-- children mirror vanilla intent: a static mesh switched with the hose's
-- connection state. Driven here on TRANSITIONS only (never per-tick sets), and
-- never touched while the hose has never connected — so on the Xerion, where
-- the injected hose stays dormant, vanilla's own objectChange on the specType
-- hoses keeps sole ownership of the mesh.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- spsTractorOffersSpecTypeCircuit: true when `tractor` exposes at least one
-- connection target of `hoseType` whose specType is in `specTypeSet`,
-- reachable from attacher joint `jointDescIndex`. Tool-connector start/end
-- targets are included: vanilla loadToolConnectorHoseNode routes them through
-- addHoseTargetNodes, which registers every target in targetNodesByType with
-- its specType preserved. This is the Xerion detector — config-driven, no
-- vehicle names in Lua.
-- ---------------------------------------------------------------------------
local function spsTractorOffersSpecTypeCircuit(tractor, jointDescIndex, hoseType, specTypeSet)
    if specTypeSet == nil then return false end
    local spec = tractor.spec_connectionHoses
    if spec == nil or spec.targetNodesByType == nil then return false end
    local nodes = spec.targetNodesByType[hoseType]
    if nodes == nil then return false end
    for _, node in ipairs(nodes) do
        if node.specType ~= nil and specTypeSet[node.specType] == true
           and node.attacherJointIndices ~= nil
           and node.attacherJointIndices[jointDescIndex] ~= nil then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- spsBuildInjectedHose: build one live hose entry inside the vehicle's own
-- spec_connectionHoses. Field-for-field replica of what vanilla
-- ConnectionHoses:loadHoseNode(xmlFile, hoseKey, entry, true) produces for a
-- hose with no specType, no socket, no adapters and no centre-point offsets
-- (the shape of every plain TOOL_CONNECTOR_TOP_RIGHT hose in vanilla vehicle
-- XMLs, e.g. saddleTracTankerFront.xml).
--
-- def = {
--   node                    -- resolved node id the hose hangs from,
--   nodeName                -- for log messages,
--   type                    -- e.g. "TOOL_CONNECTOR_TOP_RIGHT",
--   length, diameter,       -- metres,
--   isTwoPointHose,         -- bool,
--   inputAttacherJointIndex -- the vehicle's OWN input joint (1-based),
-- }
-- registerForVanillaConnect: true  -> also entered in hoseNodesByInputAttacher
--                                     (vanilla onPostAttach connects it);
--                            false -> SPS-managed connect only.
-- Returns hoseEntry|nil, reasonString.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.6] isFrontMountVehicle: true when the vehicle is registered with
-- a <frontMount> block. Used by init.lua to withhold the spreader-valve
-- keybind from front mounts: they carry spec_dischargeable (manureBarrel
-- type) so vehicleHasSpreader passes, but a front mount is a pump/arm unit,
-- never a spreader. With the toggle withheld, spreaderValveOpen can never
-- become true on a front mount, so every downstream spreader-gated branch
-- stays inert without further changes.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:isFrontMountVehicle(vehicle)
    if self.registeredVehicles == nil or vehicle == nil then return false end
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            return entry.frontMount ~= nil
        end
    end
    return false
end

function SlurryPipeManager:spsBuildInjectedHose(vehicle, def, registerForVanillaConnect)
    local spec = vehicle.spec_connectionHoses
    if spec == nil or spec.hoseNodes == nil or spec.numHosesByType == nil then
        return nil, "no_connectionHoses_spec"
    end
    if g_connectionHoseManager == nil then
        return nil, "no_hose_manager"
    end

    -- Client-only caveat: vanilla onPostLoad removes the onUpdateInterpolation
    -- listener when a vehicle loaded with NO hoses/targets/localHoses/skipNodes
    -- at all. A hose injected into such a vehicle would connect but never have
    -- its bend curve updated. All current SPS targets (front mount, Profi2)
    -- ship vanilla hoses, so warn loudly rather than half-fix.
    if vehicle.isClient and #spec.hoseNodes == 0
       and spec.targetNodes ~= nil and #spec.targetNodes == 0
       and spec.hoseSkipNodes ~= nil and #spec.hoseSkipNodes == 0
       and spec.localHoseNodes ~= nil and #spec.localHoseNodes == 0 then
        print(string.format(
            "[SPS] WARNING: injecting a connection hose into '%s' which loaded with no vanilla hoses/targets — vanilla removed its hose update listener; the hose may not animate",
            tostring(vehicle.configFileName)))
    end

    -- Visual clone — identical call to vanilla loadHoseNode: hoseType name
    -- "DEFAULT", no vehicleMaterial (nil keeps the hose type's own material).
    local hose, startStraightening, endStraightening, minCenterPointAngle =
        g_connectionHoseManager:getClonedHoseNode(def.type, "DEFAULT", def.length, def.diameter, nil, vehicle.customEnvironment)
    if hose == nil then
        return nil, "hose_clone_failed"
    end

    local hoseEntry = {
        spsInjected           = true,   -- SPS marker; unused by vanilla
        type                  = def.type,
        specType              = nil,    -- PLAIN hose by design (normal-tractor circuit)
        hoseType              = "DEFAULT",
        node                  = def.node,
        isTwoPointHose        = def.isTwoPointHose == true,
        isWorldSpaceHose      = true,   -- vanilla default (#isWorldSpaceHose, true)
        component             = vehicle:getParentComponent(def.node),
        lastVelY              = 0,
        lastVelZ              = 0,
        dampingRange          = 0.05,   -- vanilla defaults
        dampingFactor         = 50,
        length                = def.length,
        dynamicLength         = false,
        diameter              = def.diameter,
        straighteningFactor   = def.straighteningFactor or 1,
        centerPointDropFactor = 1,
        centerPointTension    = 0,
        minCenterPointAngle   = minCenterPointAngle,
        minDeltaY             = math.huge,
        material              = nil,
        adapterMaterial       = nil,
        adapterName           = nil,    -- nil -> connectHose uses the TARGET's adapter (vanilla path)
        outgoingAdapter       = nil,
        socket                = nil,
        hoseNode              = hose,
        visibilityNode        = hose,
        -- [SPS 1.0.0.5] vanilla loadHoseNode:883 — base straightening from
        -- the cloned hose type, multiplied by the config's straighteningFactor.
        startStraightening    = startStraightening * (def.straighteningFactor or 1),
        endStraightening      = endStraightening,
        endStraighteningBase  = endStraightening,
        endStraighteningDirectionBase = { 0, 0, 1 },
        objectChanges         = {},     -- SPS drives its own objectChange (transition-gated)
    }
    hoseEntry.endStraighteningDirection = hoseEntry.endStraighteningDirectionBase
    hoseEntry.minDeltaYComponent        = hoseEntry.component
    hoseEntry.inputAttacherJointIndices = { [def.inputAttacherJointIndex] = def.inputAttacherJointIndex }

    -- Link + park hidden, exactly as vanilla does at load (no socket, no
    -- outgoing adapter -> outgoingNode is the hose node itself, rotation 0).
    link(def.node, hose)
    setTranslation(hose, 0, 0, 0)
    setRotation(hose, 0, 0, 0)
    setVisibility(hoseEntry.visibilityNode, false)

    -- Bookkeeping identical to vanilla's isBaseHose path: typedIndex counts
    -- per type..(specType or "") — plain hose -> plain key. typedIndex is what
    -- addHoseToDelayedMountings matches against the tool connection's own
    -- typedIndex on re-mount edge cases.
    local typeKey = hoseEntry.type
    if spec.numHosesByType[typeKey] == nil then
        spec.numHosesByType[typeKey] = 0
    end
    spec.numHosesByType[typeKey] = spec.numHosesByType[typeKey] + 1
    hoseEntry.typedIndex = spec.numHosesByType[typeKey]

    table.insert(spec.hoseNodes, hoseEntry)
    hoseEntry.index = #spec.hoseNodes
    spec.hoseNodesAvailable = true

    if registerForVanillaConnect == true then
        local idx = def.inputAttacherJointIndex
        if spec.hoseNodesByInputAttacher[idx] == nil then
            spec.hoseNodesByInputAttacher[idx] = {}
        end
        table.insert(spec.hoseNodesByInputAttacher[idx], hoseEntry)
    end

    return hoseEntry, "ok"
end

-- ---------------------------------------------------------------------------
-- spsInjectConfiguredHoses: registration-time entry point, called from
-- SlurryPipeManager:registerVehicle after the hose defs were parsed and their
-- nodes resolved. Builds the front-mount hose (SPS-managed) and/or the
-- receiver hose (vanilla-managed), and covers the already-attached-at-
-- registration ordering for the receiver.
-- ---------------------------------------------------------------------------
local function spsMakeObjectChangeState(def, hoseEntry)
    if def.objectChange == nil then return nil end
    -- [SPS 1.0.0.4] initialState="inactive" in the config applies the
    -- inactive visibility ONCE here at injection time, for SPS-owned meshes
    -- that load visible in the nodeTree (Profi2/Samson coupler must be hidden
    -- before the first connect). Without the attribute the node is untouched
    -- until the first connect transition, preserving load-time state owned by
    -- the vehicle's own vanilla objectChanges (front mount hydraulicHoses).
    -- Runs BEFORE spsInjectConfiguredHoses' already-attached reconnect, so a
    -- savegame that loads connected hides then shows on the first tick
    -- transition - correct end state either way.
    if def.objectChange.applyInitialInactive == true and def.objectChange.node ~= nil then
        setVisibility(def.objectChange.node, def.objectChange.visibilityInactive)
    end
    return {
        hose               = hoseEntry,
        node               = def.objectChange.node,
        visibilityActive   = def.objectChange.visibilityActive,
        visibilityInactive = def.objectChange.visibilityInactive,
        lastConnected      = false,   -- hose starts disconnected; first SET happens on first connect
    }
end

function SlurryPipeManager:spsInjectConfiguredHoses(vehicle, entry)
    -- Front mount: plain hose, SPS-managed connect (see header block).
    if entry.frontMount ~= nil and entry.frontMount.hoseDef ~= nil then
        local hoseEntry, reason = self:spsBuildInjectedHose(vehicle, entry.frontMount.hoseDef, false)
        if hoseEntry ~= nil then
            entry.frontMount.injectedHose     = hoseEntry
            entry.frontMount.hosePendingOn    = nil   -- tractor we last issued a connect for
            entry.frontMount.hoseSuppressedOn = nil   -- tractor whose specType circuit owns this joint
            entry.frontMount.hoseRetryTimer   = nil   -- ms since a dead connect attempt (see self-heal)
            entry.frontMount.hoseObjectChange = spsMakeObjectChangeState(entry.frontMount.hoseDef, hoseEntry)
            print(string.format("[SPS] frontMount hose injected on '%s' (node='%s' type=%s)",
                tostring(vehicle.configFileName), tostring(entry.frontMount.hoseDef.nodeName),
                tostring(hoseEntry.type)))
        else
            print(string.format("[SPS] WARNING: frontMount hose injection FAILED on '%s' (%s)",
                tostring(vehicle.configFileName), tostring(reason)))
        end
    end

    -- Receiver tanker: plain hose, vanilla-managed connect.
    if entry.receiverHoseDef ~= nil then
        local hoseEntry, reason = self:spsBuildInjectedHose(vehicle, entry.receiverHoseDef, true)
        if hoseEntry ~= nil then
            entry.receiverHose             = hoseEntry
            entry.receiverHoseObjectChange = spsMakeObjectChangeState(entry.receiverHoseDef, hoseEntry)
            print(string.format("[SPS] tractorMountFillArms receiver hose injected on '%s' (node='%s' type=%s)",
                tostring(vehicle.configFileName), tostring(entry.receiverHoseDef.nodeName),
                tostring(hoseEntry.type)))
            -- Already attached when SPS registered (savegame ordering): vanilla
            -- onPostAttach ran before this hose existed, so re-run the vanilla
            -- connect for the current attach. Idempotent for every other hose.
            if vehicle.getAttacherVehicle ~= nil and vehicle.connectHosesToAttacherVehicle ~= nil
               and vehicle.getActiveInputAttacherJointDescIndex ~= nil then
                local av = vehicle:getAttacherVehicle()
                if av ~= nil and av.getAttacherJointIndexFromObject ~= nil then
                    local inputIdx = vehicle:getActiveInputAttacherJointDescIndex()
                    local jointIdx = av:getAttacherJointIndexFromObject(vehicle)
                    if inputIdx ~= nil and jointIdx ~= nil then
                        vehicle:connectHosesToAttacherVehicle(av, inputIdx, jointIdx)
                    end
                end
            end
        else
            print(string.format("[SPS] WARNING: tractorMountFillArms hose injection FAILED on '%s' (%s)",
                tostring(vehicle.configFileName), tostring(reason)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- spsFrontHoseIsParked: true when `hose` is sitting in one of the tractor's
-- tool connections as a delayedMounting — vanilla's "waiting for the other
-- side" state (ConnectionHoses:addHoseToDelayedMountings). Vanilla owns the
-- hose from here: it bridges automatically the moment the receiver appears,
-- so SPS must not re-issue a connect while this holds.
-- ---------------------------------------------------------------------------
local function spsFrontHoseIsParked(av, hose)
    local spec = av.spec_connectionHoses
    if spec == nil or spec.toolConnectorHoses == nil then return false end
    for _, toolConnector in pairs(spec.toolConnectorHoses) do
        local dm = toolConnector.delayedMounting
        if dm ~= nil and dm.sourceHose == hose then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- spsUpdateManagedFrontHose: per-tick management of the front mount's injected
-- plain hose. Issues ONE connect request per attach, then hands off to vanilla
-- (bridging, detach cleanup, delayed re-mount when the tanker cycles).
-- Deterministic on every peer: it reads only vanilla-synced attach state and
-- local hose state, so server and clients converge without SPS events — same
-- principle as receiver resolution.
--
-- [SPS 1.0.1.4] Self-healing connect latch. The front-mount hose is
-- deliberately NOT in hoseNodesByInputAttacher (see header block), so vanilla
-- onPostAttach never re-connects it — this function is its ONLY connect path.
-- The old latch released solely on observing av == nil, so any event that
-- dropped the hose without a tick seeing the arm detached left it dead until
-- the player manually re-attached. A dedicated-server log showed exactly that:
-- a panel vehicle move ("Moved 3 vehicles to coordinates ...") disconnected the
-- circuit within 10 ms, and every pump attempt for the next several minutes
-- logged "no_targets:no_connected_circuit". The receiver hose recovered by
-- itself (it IS vanilla-auto-connected); the front hose could not.
-- Now the latch is released whenever the hose is neither connected nor parked
-- as a vanilla delayedMounting — i.e. the attempt genuinely died — throttled so
-- a tractor with no matching target costs one retry per second, not one per
-- tick. Xerion suppression keeps its own permanent latch: it is a static
-- property of the tractor's targets and must never be retried.
-- ---------------------------------------------------------------------------
local FRONT_HOSE_RETRY_INTERVAL_MS = 1000

local function spsUpdateManagedFrontHose(self, entry, dt)
    local fm = entry.frontMount
    if fm == nil or fm.injectedHose == nil then return end
    local vehicle = entry.vehicle
    if vehicle == nil or vehicle.getAttacherVehicle == nil then return end

    local av = vehicle:getAttacherVehicle()
    if av == nil then
        -- Detached: vanilla already disconnected/cleaned the hose
        -- (onPreDetach). Release the latches so the next attach re-evaluates.
        fm.hosePendingOn    = nil
        fm.hoseSuppressedOn = nil
        fm.hoseRetryTimer   = nil
        return
    end

    local hose = fm.injectedHose
    if hose.connectedObject ~= nil then              -- live and bridged
        fm.hoseRetryTimer = nil
        return
    end
    if fm.hoseSuppressedOn == av then return end     -- specType circuit owns this joint

    if fm.hosePendingOn == av then
        -- A connect was already issued for this tractor. Vanilla still owns the
        -- hose while it is parked awaiting the other side — leave it alone.
        if spsFrontHoseIsParked(av, hose) then
            fm.hoseRetryTimer = nil
            return
        end
        -- Neither connected nor parked: the attempt is dead. Re-arm on a
        -- throttle so a transient failure heals without per-tick churn.
        fm.hoseRetryTimer = (fm.hoseRetryTimer or 0) + (dt or 0)
        if fm.hoseRetryTimer < FRONT_HOSE_RETRY_INTERVAL_MS then return end
        fm.hoseRetryTimer = 0
        fm.hosePendingOn  = nil
        if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSM_FrontMount") then
            print(string.format("[SPS FM] plain hose dropped on '%s' (tractor '%s') — re-arming connect",
                tostring(vehicle.configFileName), tostring(av.configFileName)))
        end
    end

    if av.spec_connectionHoses == nil or av.iterateConnectionTargets == nil
       or av.getAttacherJointIndexFromObject == nil then
        return
    end
    local jointIdx = av:getAttacherJointIndexFromObject(vehicle)
    if jointIdx == nil then return end

    -- Xerion-style suppression: the tractor pairs through specType'd targets
    -- for this joint, so the vanilla specType hoses own the circuit; the plain
    -- hose must stay dormant or it would duplicate on the tractor's plain
    -- carrier connector (rightPipe_frontConnector also serves joint 2 on the
    -- xerion4000).
    if spsTractorOffersSpecTypeCircuit(av, jointIdx, hose.type, fm.hoseSpecTypes) then
        fm.hoseSuppressedOn = av   -- latch: static targets, no point re-checking per tick
        if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSM_FrontMount") then
            print(string.format("[SPS FM] plain hose suppressed on '%s': tractor '%s' offers specType circuit at joint %d",
                tostring(vehicle.configFileName), tostring(av.configFileName), jointIdx))
        end
        return
    end

    fm.hosePendingOn = av
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSM_FrontMount") then
        print(string.format("[SPS FM] plain hose connect request on '%s' -> tractor '%s' joint %d",
            tostring(vehicle.configFileName), tostring(av.configFileName), jointIdx))
    end
    -- Vanilla connect pattern, restricted to this one hose (mirrors
    -- connectHosesToAttacherVehicle's iterate/connect loop; specType nil ->
    -- only plain targets match). connectHose returns true when connected,
    -- false/nil when parked as the tool connection's delayedMounting — in
    -- which case vanilla bridges it automatically the moment the receiver
    -- side appears.
    av:iterateConnectionTargets(function(target, isSkipNode)
        if not vehicle:getIsConnectionHoseUsed(hose) then
            if not isSkipNode then
                if vehicle:connectHose(hose, av, target) then
                    return false
                end
            end
            return true
        end
        return false
    end, jointIdx, hose.type, nil)
end

-- ---------------------------------------------------------------------------
-- spsUpdateInjectedHoseObjectChange: transition-gated static-mesh switch for
-- an injected hose. Never fires while the hose has never connected (initial
-- lastConnected=false), so vanilla's own objectChanges keep sole ownership of
-- shared meshes on the specType (Xerion) path.
-- ---------------------------------------------------------------------------
local function spsUpdateInjectedHoseObjectChange(state)
    if state == nil or state.node == nil then return end
    local connected = state.hose.connectedObject ~= nil
    if connected ~= state.lastConnected then
        state.lastConnected = connected
        if connected then
            setVisibility(state.node, state.visibilityActive)
        else
            setVisibility(state.node, state.visibilityInactive)
        end
    end
end

-- ---------------------------------------------------------------------------
-- updateFrontMounts: per-tick refresh of the cached resolution for every
-- front-mount entry, plus [SPS 1.0.0.3] managed connect of the injected
-- front-mount hose and transition-gated objectChange driving for BOTH
-- injected hoses (front mount and receiver tankers — hence the loop now also
-- touches entries without a frontMount block when they carry a receiver
-- hose). Cheap: a handful of vehicles, small hose tables. Traces
-- (channel-gated) only when the result changes.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:updateFrontMounts(dt)
    if self.registeredVehicles == nil then return end
    for _, entry in ipairs(self.registeredVehicles) do
        -- [SPS 1.0.0.3] Injected-hose management (independent of frontMount
        -- resolution so receiver-only tankers are covered too).
        if entry.vehicle ~= nil then
            spsUpdateManagedFrontHose(self, entry, dt)
            if entry.frontMount ~= nil then
                spsUpdateInjectedHoseObjectChange(entry.frontMount.hoseObjectChange)
            end
            spsUpdateInjectedHoseObjectChange(entry.receiverHoseObjectChange)
        end
        local fm = entry.frontMount
        if fm ~= nil and entry.vehicle ~= nil then
            local receiver, reason, fui = self:resolveFrontMountReceiver(entry.vehicle)
            if receiver ~= fm.receiver or reason ~= fm.receiverReason then
                if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSM_FrontMount") then
                    local recvName = receiver ~= nil and tostring(receiver.configFileName) or "nil"
                    print(string.format(
                        "[SPS FM] receiver change: front=%s receiver=%s reason=%s fillUnit=%s",
                        tostring(entry.vehicle.configFileName), recvName,
                        tostring(reason), tostring(fui)))
                end
                fm.receiver = receiver
                fm.receiverReason = reason
                fm.receiverFillUnitIndex = fui
            end
        end
    end
end
