-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.5

-- SPSM_Flow.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: pump & flow actions, equalise, flow sessions, fill transfer & sources.
-- PURE RELOCATION from scripts/manager/SlurryPipeManager.lua (V1.0.0.8 tag):
-- every function body in this file is byte-identical to the baseline.
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

print("[SPS BUILD] SPSM_Flow 1.0.1.8 loaded")


function SlurryPipeManager:connectionIsFillArm(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            for _, arm in ipairs(entry.armEntries) do if arm.isConnected then return true end end
            return false
        end
    end
    return false
end

function SlurryPipeManager:vehicleHasFillArms(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            return #entry.armEntries > 0
        end
    end
    return false
end

-- [SPS] Returns sourceEntry, or a shallow-copied view of it carrying
-- restrictFillType when the specific coupling this connection resolved through
-- declares its own #fillType (e.g. BGA500's separate LIQUIDMANURE / DIGESTATE
-- couplers sharing one storage). _resolveSourceFillType/_destAcceptsFillType/
-- resolveStoreDepositFillType all honour restrictFillType. Coupling with no
-- declared fillType (nil) leaves sourceEntry untouched — unrestricted, legacy
-- behaviour.
function SlurryPipeManager:_restrictSourceToCoupling(sourceEntry, coupling)
    if sourceEntry == nil or coupling == nil or coupling.fillType == nil then
        return sourceEntry
    end
    local restricted = {}
    for k, v in pairs(sourceEntry) do restricted[k] = v end
    restricted.restrictFillType = coupling.fillType
    return restricted
end

-- Returns the source entry on the far side of a coupling's connection.
-- Used by conduit pump to find what to pull from / push into.
function SlurryPipeManager:resolveSourceForCouplingPartner(coupling)
    if not coupling.isConnected then return nil end
    local partner = coupling.connectedPartnerCoupling
    if partner == nil then return nil end
    -- Chain terminus: use stored sourceEntry if available, else walk to anchor
    if partner.isChainTerminus then
        if partner.sourceEntry ~= nil then
            if partner._lastSrcLog ~= "stored" then
                partner._lastSrcLog = "stored"
                SlurryPipeManager.logMP(string.format("[SPS MP] resolveSrc(chainTerminus id=%s): stored sourceEntry -> %s",
                    tostring(partner.id), tostring(partner.sourceEntry.vehicle and partner.sourceEntry.vehicle.configFileName or "?")))
            end
            return partner.sourceEntry
        end
        -- sourceEntry not set at chain creation — resolve from anchor on demand
        if partner.chain ~= nil and partner.chain.anchorCoupling ~= nil then
            local anchor = partner.chain.anchorCoupling
            -- [SPS] A chain bridges TWO real endpoints: its anchor (bonded to the
            -- START terminus) and the coupling bonded to its free END terminus.
            -- resolveSourceForCouplingPartner is asked for the source on the OTHER
            -- side of `coupling`. If `coupling` entered via the START terminus then
            -- the anchor IS `coupling` itself (partner_is_self) — the real source is
            -- the FAR end. Only the END-terminus case should resolve to the anchor.
            -- Store-anchored chains are unaffected: the store never pumps through
            -- this path, so only their END terminus is ever resolved.
            local chainObj  = partner.chain
            local segs      = chainObj.segments
            local startTerm = segs and segs[1] and segs[1].chainStartCoupling or nil
            local endTerm   = segs and segs[#segs] and segs[#segs].chainCoupling or nil
            if partner == startTerm and endTerm ~= nil and endTerm.connectedPartnerCoupling ~= nil then
                anchor = endTerm.connectedPartnerCoupling
                if partner._lastSrcLog2 ~= "farend" then
                    partner._lastSrcLog2 = "farend"
                    SlurryPipeManager.logMP(string.format("[SPS MP] resolveSrc(chainTerminus id=%s): START terminus -> resolving FAR end instead of anchor(self)",
                        tostring(partner.id)))
                end
            end
            for _, pEntry in ipairs(self.registeredPlaceables) do
                if pEntry.storeCouplings ~= nil then
                    for _, sc in ipairs(pEntry.storeCouplings) do
                        if sc == anchor then
                            if partner._lastSrcLog ~= "placeable" then
                                partner._lastSrcLog = "placeable"
                                SlurryPipeManager.logMP(string.format("[SPS MP] resolveSrc(chainTerminus id=%s): anchor->placeable store", tostring(partner.id)))
                            end
                            return self:_restrictSourceToCoupling(pEntry.sourceEntry, sc)
                        end
                    end
                end
            end
            for _, vEntry in ipairs(self.registeredVehicles) do
                for _, c in ipairs(vEntry.couplingEntries) do
                    if c == anchor then
                        if partner._lastSrcLog ~= "vehicle" then
                            partner._lastSrcLog = "vehicle"
                            SlurryPipeManager.logMP(string.format("[SPS MP] resolveSrc(chainTerminus id=%s): anchor->vehicle %s",
                                tostring(partner.id), tostring(vEntry.vehicle and vEntry.vehicle.configFileName)))
                        end
                        return self:resolveVehicleSource(vEntry.vehicle)
                    end
                end
            end
        end
        if partner._lastSrcLog ~= "nil" then
            partner._lastSrcLog = "nil"
            SlurryPipeManager.logMP(string.format("[SPS MP] resolveSrc(chainTerminus id=%s): UNRESOLVED (chain=%s anchor=%s)",
                tostring(partner.id), tostring(partner.chain ~= nil),
                tostring(partner.chain ~= nil and partner.chain.anchorCoupling ~= nil)))
        end
        return nil
    end
    -- Partner on a placeable
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc == partner then return self:_restrictSourceToCoupling(pEntry.sourceEntry, sc) end
            end
        end
    end
    -- Partner on a vehicle — resolve that vehicle's fill source
    local target = coupling.connectedTarget
    if target ~= nil then
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.vehicle == target then
                return self:resolveVehicleSource(vEntry.vehicle)
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Arm/coupling callbacks (stubs kept for future coupling re-addition)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onPumpStateChanged(vehicle, isPumpRunning)
    SlurryPipeManager.log("onPumpStateChanged: %s -> pumpRunning=%s", tostring(vehicle and vehicle.configFileName), tostring(isPumpRunning))
    local state = self:getVehicleState(vehicle)
    if state ~= nil then
        state.pumpRunning = isPumpRunning == true
    end
end

function SlurryPipeManager:onSelfPumpToggle(vehicle)
    SlurryPipeManager.log("onSelfPumpToggle: %s", tostring(vehicle and vehicle.configFileName))
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local newRunning = not (state.pumpRunning == true)
    if g_server ~= nil then
        state.pumpRunning = newRunning
        SPSSelfPumpStateEvent.sendEvent(vehicle, newRunning)
        self:updateActionEventTexts(vehicle)
    else
        -- MP CLIENT: apply locally (server rebroadcast excludes the sender).
        state.pumpRunning = newRunning
        SPSSelfPumpStateEvent.sendEvent(vehicle, newRunning)
        self:updateActionEventTexts(vehicle)
    end
    if vehicle.isClient then
        local entry = self:getVehicleEntry(vehicle)
        if entry ~= nil and entry.engineLoopSample ~= nil then
            if newRunning then
                g_soundManager:playSample(entry.engineLoopSample)
            else
                g_soundManager:stopSample(entry.engineLoopSample)
            end
        end
    end
end

-- Shared PTO/pump toggle used by BOTH the cab action event and the outside
-- ptoControl node, so behaviour is identical in and out of the cab. This is the
-- exact logic that previously lived inline in init.lua's cab pumpCallback.
function SlurryPipeManager:togglePump(vehicle)
    SlurryPipeManager.log("togglePump: %s", tostring(vehicle and vehicle.configFileName))
    if vehicle == nil then return end
    if self:vehicleHasSpreader(vehicle) then
        local root = vehicle:getRootVehicle()
        if root ~= nil and root.getIsMotorStarted ~= nil and not root:getIsMotorStarted() then
            local warning = vehicle:getTurnedOnNotAllowedWarning()
            if warning ~= nil and vehicle.isClient then
                g_currentMission:showBlinkingWarning(warning, 2000)
            end
            --print("[SPS PUMP] spreader vehicle pump blocked — motor not started")
            return
        end
        if not SlurryPipeSystemOverride.isPTOConnected(vehicle) then
            --print("[SPS PUMP] spreader vehicle pump blocked — PTO not connected")
            return
        end
        local state = self:getVehicleState(vehicle)
        if state == nil then return end
        local newPump = not state.pumpRunning
        --print("[SPS PUMP] spreader vehicle pump -> " .. tostring(newPump) .. " spreaderValveOpen=" .. tostring(state.spreaderValveOpen))
        if g_server ~= nil then
            state.pumpRunning = newPump
            SPSSelfPumpStateEvent.sendEvent(vehicle, newPump)
            if newPump then
                vehicle:setIsTurnedOn(true)
            else
                vehicle:setIsTurnedOn(false)
            end
            self:updateActionEventTexts(vehicle)
        else
            -- MP CLIENT: apply SPS pump state locally (server rebroadcast excludes the
            -- sender). setIsTurnedOn is left to the server — vanilla TurnOnVehicle syncs
            -- the turned-on state back to this client on its own stream.
            state.pumpRunning = newPump
            SPSSelfPumpStateEvent.sendEvent(vehicle, newPump)
            self:updateActionEventTexts(vehicle)
        end
    else
        if not vehicle:getIsTurnedOn() and not vehicle:getCanBeTurnedOn() then
            local warning = vehicle:getTurnedOnNotAllowedWarning()
            if warning ~= nil and vehicle.isClient then
                g_currentMission:showBlinkingWarning(warning, 2000)
            end
            return
        end
        --print("[SPS PUMP] non-spreader setIsTurnedOn -> " .. tostring(not vehicle:getIsTurnedOn()))
        vehicle:setIsTurnedOn(not vehicle:getIsTurnedOn())
        self:updateActionEventTexts(vehicle)
    end
end

-- True when the tanker carries an outside <directionControl> node; used by
-- init.lua to suppress the cab direction control so it lives only at the node.
function SlurryPipeManager:vehicleHasOutsideDirectionControl(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil or entry.outsideControlEntries == nil then return false end
    for _, oc in ipairs(entry.outsideControlEntries) do
        if oc.direction == true then return true end
    end
    return false
end

function SlurryPipeManager:onArmConnected(vehicle, arm) end
function SlurryPipeManager:onArmDisconnected(vehicle, arm) self:stopFlow(vehicle) end

-- ---------------------------------------------------------------------------
-- Action handlers
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onActionToggleFlow(vehicle)
    SlurryPipeManager.log("onActionToggleFlow: %s", tostring(vehicle and vehicle.configFileName))
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    -- MA: hydraulic hoses must be connected to open the valve
    if not state.valveOpen then
        if not SlurryPipeSystemOverride.isHydraulicsConnected(vehicle) then
            if vehicle.isClient then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsConnectHydraulics"), 2000)
            end
            return
        end
    end
    -- Block opening the hydraulic valve when engine is off
    if not state.valveOpen then
        local root = vehicle:getRootVehicle()
        if root ~= nil and root.getIsMotorStarted ~= nil and not root:getIsMotorStarted() then
            if vehicle.isClient then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_slurryEngineOff"), 2000)
            end
            return
        end
    end
    if g_server ~= nil then
        local newOpen = not state.valveOpen
        state.valveOpen = newOpen
        SlurryFlowStateEvent.sendEvent(vehicle, newOpen)
        self:updateActionEventTexts(vehicle)
    else
        -- MP CLIENT: apply locally (server rebroadcast excludes the sender), else the
        -- next toggle recomputes from stale valveOpen and the valve gets stuck.
        local newOpen = not state.valveOpen
        state.valveOpen = newOpen
        SlurryFlowStateEvent.sendEvent(vehicle, newOpen)
        self:updateActionEventTexts(vehicle)
    end
end

-- Sets the target direction. Server-side, arms a purge when the existing
-- pressure opposes the new direction: the engine then vents to 0 (at purgeTime)
-- before building the new way. If pressure is 0 or already toward the new
-- target, no purge is needed and any in-progress purge is cleared.
-- Routed through here from both onActionToggleDirection (host) and
-- SlurryFlowDirectionEvent:run (dedicated server / client direction sync).
function SlurryPipeManager:applyDirectionAndPurge(vehicle, newDir)
    SlurryPipeManager.log("applyDirectionAndPurge: %s newDir=%s", tostring(vehicle and vehicle.configFileName), tostring(newDir))
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    state.direction = newDir
    if g_server ~= nil then
        local targetSign = (newDir == SPS_DIRECTION_DISCHARGE) and 1 or -1
        local p = state.pressure or 0
        state.purging = (p * targetSign < 0)
    end
end

function SlurryPipeManager:onActionToggleDirection(vehicle)
    SlurryPipeManager.log("onActionToggleDirection: %s", tostring(vehicle and vehicle.configFileName))
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    if state.valveOpen then
        if vehicle.isClient then g_currentMission:showBlinkingWarning(g_i18n:getText("warning_slurryCloseFlowFirst"), 2000) end
        return
    end
    -- MA/Bayern: when direction is set from the CAB (no outside <directionControl>
    -- node), hoses must be connected to change it — same gate as the valves. Vehicles
    -- with an outside direction control reach this handler only via the outside
    -- activatable (SPSPumpControlActivatable / SPSOutsideControlActivatable) and are
    -- intentionally left ungated, so direction can be set at the node with or without
    -- pipes. vehicleHasOutsideDirectionControl is the exact split: it is false only for
    -- cab-controlled tankers, which are the only ones the cab action is registered for.
    if not self:vehicleHasOutsideDirectionControl(vehicle) then
        if not SlurryPipeSystemOverride.isHydraulicsConnected(vehicle) then
            if vehicle.isClient then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsConnectHydraulics"), 2000)
            end
            return
        end
    end
    local newDir = (state.direction == SPS_DIRECTION_FILL) and SPS_DIRECTION_DISCHARGE or SPS_DIRECTION_FILL
    if g_server ~= nil then
        self:applyDirectionAndPurge(vehicle, newDir)
        SlurryFlowDirectionEvent.sendEvent(vehicle, newDir)
        self:updateActionEventTexts(vehicle)
    else
        -- MP CLIENT: apply locally (server rebroadcast excludes the sender). The purge
        -- arming inside applyDirectionAndPurge is server-gated, so the client only
        -- updates state.direction here.
        self:applyDirectionAndPurge(vehicle, newDir)
        SlurryFlowDirectionEvent.sendEvent(vehicle, newDir)
        self:updateActionEventTexts(vehicle)
    end
end

function SlurryPipeManager:updateActionEventTexts(vehicle)
    if not vehicle.isClient then return end
    if vehicle.spsActionEvents == nil then return end
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local pumpType = self:getPumpType(vehicle)
    local pumpId = vehicle.spsActionEvents.pumpEventId
    if pumpId ~= nil then
        local pumpOn
        if self:isVehicleSelfPowered(vehicle) or self:vehicleHasSpreader(vehicle) then
            pumpOn = state.pumpRunning == true
        else
            pumpOn = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn()
        end
        local offKey = (pumpType == "HVP") and "action_spsHVPOff" or "action_slurryPumpOff"
        local onKey  = (pumpType == "HVP") and "action_spsHVPOn"  or "action_slurryPumpOn"
        g_inputBinding:setActionEventText(pumpId, pumpOn
            and g_i18n:getText(offKey)
            or  g_i18n:getText(onKey))
    end
    local flowId = vehicle.spsActionEvents.flowEventId
    if flowId ~= nil then
        local flowOpenKey  = self:isVehicleConduit(vehicle) and "action_spsConduitFlowOpen"  or "action_slurryFlowOpen"
        local flowCloseKey = self:isVehicleConduit(vehicle) and "action_spsConduitFlowClose" or "action_slurryFlowClose"
        g_inputBinding:setActionEventText(flowId, state.valveOpen and g_i18n:getText(flowCloseKey) or g_i18n:getText(flowOpenKey))
        g_inputBinding:setActionEventActive(flowId, true)
    end
    local dirId = vehicle.spsActionEvents.dirEventId
    if dirId ~= nil then
        local dirTxt
        if self:isVehicleConduit(vehicle) then
            dirTxt = (state.direction == SPS_DIRECTION_FILL)
                and g_i18n:getText("action_spsConduitDirBtoA")
                or  g_i18n:getText("action_spsConduitDirAtoB")
        elseif pumpType == "HVP" then
            dirTxt = (state.direction == SPS_DIRECTION_FILL)
                and g_i18n:getText("action_spsHVPDirDischarge")
                or  g_i18n:getText("action_spsHVPDirFill")
        else
            dirTxt = (state.direction == SPS_DIRECTION_FILL)
                and g_i18n:getText("action_slurryDirectionDischarge")
                or  g_i18n:getText("action_slurryDirectionFill")
        end
        g_inputBinding:setActionEventText(dirId, dirTxt)
        g_inputBinding:setActionEventActive(dirId, not state.valveOpen)
    end
    local spreaderId = vehicle.spsActionEvents.spreaderEventId
    if spreaderId ~= nil then
        g_inputBinding:setActionEventText(spreaderId, state.spreaderValveOpen
            and g_i18n:getText("action_spsSpreaderClose")
            or  g_i18n:getText("action_spsSpreaderOpen"))
    end
end

-- ---------------------------------------------------------------------------
-- Flow session
-- ---------------------------------------------------------------------------
function SlurryPipeManager:startFlow(vehicle)
    SlurryPipeManager.log("startFlow: %s", tostring(vehicle and vehicle.configFileName))
    if self.activeFlows[vehicle] ~= nil then return end
    local session = self:buildFlowSession(vehicle)
    if session ~= nil then
        self.activeFlows[vehicle] = session
        SlurryDebug.log("startFlow - session started for " .. tostring(vehicle.configFileName))
    end
end

function SlurryPipeManager:stopFlow(vehicle)
    SlurryPipeManager.log("stopFlow: %s", tostring(vehicle and vehicle.configFileName))
    if self.activeFlows[vehicle] ~= nil then
        self.activeFlows[vehicle] = nil
    end
end

-- Returns the resolved drive model for a vehicle: "vacuum" | "HVP" | "conduit" |
-- "openTop", or nil if unregistered.
function SlurryPipeManager:getPumpType(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return nil end
    return entry.pumpType
end

-- Fill (suck-in) rate, litres/second, for this vehicle.
function SlurryPipeManager:getFillRate(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return SlurryPipeManager.DEFAULT_LITERS_PER_SECOND end
    return entry.fillLitersPerSecond or entry.litersPerSecond or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
end

-- Empty (push-out / spread) rate, litres/second, for this vehicle.
function SlurryPipeManager:getEmptyRate(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return SlurryPipeManager.DEFAULT_LITERS_PER_SECOND end
    return entry.emptyLitersPerSecond or entry.litersPerSecond or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
end

-- Vacuum pump sound: slurry01 (filling) until the tank is full, then slurry02
-- (full, higher/dull) for as long as it stays full and the pump runs, and back to
-- slurry01 when emptying. Plays only while the pump is running, only on vacuum
-- tanks, driven by the same fill ratio the pressure model uses.
function SlurryPipeManager:updatePumpSounds(dt)
    for _, entry in ipairs(self.registeredVehicles) do
        local vehicle = entry.vehicle
        if (entry.vacPumpFilling ~= nil or entry.vacPumpFull ~= nil)
           and vehicle ~= nil and vehicle.isClient then
            -- Is the pump running? (same signal the pump action-text uses.)
            local state  = entry.state
            local pumpOn
            if self:isVehicleSelfPowered(vehicle) or self:vehicleHasSpreader(vehicle) then
                pumpOn = state ~= nil and state.pumpRunning == true
            else
                pumpOn = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn()
            end

            local desired = "off"
            if pumpOn then
                local fillRatio = self:getPressureFillRatio(vehicle, entry) or 0
                if fillRatio >= (entry.vacFullThreshold or 0.99) then
                    desired = "full"
                else
                    desired = "filling"
                end
            end

            if desired ~= entry._vacSoundState then
                if entry.vacPumpFilling ~= nil and g_soundManager:getIsSamplePlaying(entry.vacPumpFilling) then
                    g_soundManager:stopSample(entry.vacPumpFilling)
                end
                if entry.vacPumpFull ~= nil and g_soundManager:getIsSamplePlaying(entry.vacPumpFull) then
                    g_soundManager:stopSample(entry.vacPumpFull)
                end
                if desired == "filling" and entry.vacPumpFilling ~= nil then
                    g_soundManager:playSample(entry.vacPumpFilling)
                elseif desired == "full" and entry.vacPumpFull ~= nil then
                    g_soundManager:playSample(entry.vacPumpFull)
                end
                entry._vacSoundState = desired
                --print("[SPS SND] vac pump sound -> " .. desired)
            end
        end
    end
end

-- Resolves the effective pipe/arm flow for a tanker once its valve is confirmed open.
-- Returns (flowDir, scalar):
--   flowDir = SPS_DIRECTION_FILL or SPS_DIRECTION_DISCHARGE, or nil for no flow
--   scalar  = rate multiplier applied to baseLitersPerSecond
--
-- The core of the pressure system: stored pressure drives flow in its built direction
-- whenever |pressure| >= minThreshold, PTO on or off.
--   * FILL: a vacuum at/above minThreshold draws slurry IN. You must build the vacuum to
--     min before any fill starts (so opening the valve + starting the PTO from zero does
--     nothing until min is reached), but once the vacuum exists it fills on its own —
--     including stored vacuum with the PTO already off (taper).
--   * DISCHARGE: pressure at/above minThreshold pushes slurry OUT, likewise on stored
--     pressure after the PTO is off (taper).
--   * Exempt endpoint (conduit pump / open-top FRC / fert sprayer, usesPressure=false):
--     legacy pump gate — flows in state.direction at full rate only while the PTO runs.
--   * GRAVITY / BACKFLOW: once the PTO is off AND the stored pressure has bled below
--     minThreshold, a tanker that still holds slurry drains OUT by gravity (DISCHARGE) at
--     gravityFlowScalar until the valve is closed by hand or the tank empties. After a
--     FILL this is the "vacuum falls to nothing, then it flows backwards and empties"
--     behaviour; after a DISCHARGE it continues the drain past the pressure taper.
function SlurryPipeManager:resolveCouplingFlow(vehicle, state, pumpRunning, hasContent)
    -- [SPS 1.0.0.9.20] Direction-aware scalar (see getDirectionalPressureFlowScalar,
    -- SPSM_Pressure 1.0.0.9.1): stored pressure only drives flow in the direction
    -- it was BUILT. Flipping a -2 bar vac tank to Pressure now HOLDS the level
    -- while the purge vents to 0 and the pump builds past +minThreshold, instead
    -- of instantly discharging on the sign-blind |pressure| scalar.
    local pScalar, usesPressure = self:getDirectionalPressureFlowScalar(vehicle, state.direction)

    if not usesPressure then
        if pumpRunning then return state.direction, 1.0 end
        return nil, 0.0
    end

    -- Stored pressure/vacuum at or above threshold drives flow in its built direction.
    if pScalar > 0 then
        return state.direction, pScalar
    end

    -- Pressure spent (|pressure| < minThreshold) and the PTO is not replenishing it:
    -- gravity backflow OUT while slurry remains.
    if not pumpRunning and hasContent then
        -- [SPS 1.0.0.9.20] A stored vacuum at/above minThreshold SEALS the tank —
        -- contents are held in, not gravity-drained. Without this, flipping to
        -- Pressure with the pump off on a -2 bar tank fell through the (now
        -- direction-gated) scalar into gravity drain and leaked the level anyway.
        do
            local vEntryG = self:getVehicleEntry(vehicle)
            if vEntryG ~= nil and vEntryG.pressure ~= nil and vEntryG.state ~= nil then
                local minTG = vEntryG.pressure.minThreshold or SlurryPipeManager.DEFAULT_MIN_THRESHOLD
                if (vEntryG.state.pressure or 0) <= -minTG then return nil, 0.0 end
            end
        end
        -- Head equalisation owns this vehicle this window: defer the one-way
        -- gravity drain so the two mechanisms never move the same slurry.
        if state ~= nil and state._equaliseActive then return nil, 0.0 end
        -- A coupling partner is building/holding pressure or vacuum: flow must wait
        -- for that partner to reach minThreshold, so suppress gravity backflow.
        -- (This is the "press B on the vac tank -> nothing moves until vacuum is
        -- built" behaviour; without it the pump-off partner dribbles out by gravity.)
        if self:_couplingPartnerIsPressurising(vehicle) then
            if SlurryPipeManager.DEBUG and state ~= nil and state._eqGravSuppressed ~= true then
                state._eqGravSuppressed = true
                SlurryPipeManager.log("resolveCouplingFlow: gravity suppressed on %s (coupling partner pressurising)",
                    tostring(vehicle and vehicle.configFileName))
            end
            return nil, 0.0
        end
        if state ~= nil then state._eqGravSuppressed = false end
        local entry = self:getVehicleEntry(vehicle)
        local g = SlurryPipeManager.DEFAULT_GRAVITY_FLOW_SCALAR
        if entry ~= nil and entry.pressure ~= nil and entry.pressure.gravityFlowScalar ~= nil then
            g = entry.pressure.gravityFlowScalar
        end
        if g > 0 then
            return SPS_DIRECTION_DISCHARGE, g
        end
    end

    return nil, 0.0
end

-- ---------------------------------------------------------------------------
-- Hydraulic head equalisation between two directly-coupled tankers
--
-- When two tankers (or a tanker and a passive open-top vessel) are joined by a
-- direct/strap coupling, BOTH coupling valves are open, and NEITHER side is
-- building or holding pressure/vacuum (pumps off, |pressure| < minThreshold),
-- slurry runs from the higher surface to the lower surface under gravity until
-- both surfaces sit at the same WORLD height. Because the driving signal is
-- surface Y (head), two tanks of different capacity settle at equal head, not
-- equal litres. The same path moves water (WATER<->WATER) unchanged.
--
-- The instant either side builds vacuum (pull) or pressure (push), this stands
-- down: the existing pressure model in resolveCouplingFlow then owns the flow,
-- so a vacuum drains the partner past equilibrium and pressure pushes it back.
--
-- Server-authoritative and THROTTLED (a fixed cadence, not every frame), so it
-- never spikes the main thread. Fill-unit levels replicate to clients via the
-- vanilla FillUnit sync, exactly like the conduit transfer path it mirrors.
--
-- Scope: direct vehicle<->vehicle couplings only. Chain-pipe layouts are
-- deferred until chain server-sync exists (chain isConnected stays client-local
-- server-side, so no flow could be authoritative over a chain yet).
-- ---------------------------------------------------------------------------
SlurryPipeManager.EQUALISE_INTERVAL_MS   = 150      -- throttle cadence (ms)
SlurryPipeManager.EQUALISE_HEAD_DEADBAND = 0.0015   -- m (~1.5 mm): level, stop
SlurryPipeManager.EQUALISE_TAPER_HEAD    = 0.30     -- m: head over which rate -> full

-- Surface world-Y for a FILL_VOLUME or STORAGE_PLANE source, or nil when the
-- source carries no readable surface (e.g. a bare FILL_UNIT_ONLY tank).
function SlurryPipeManager:_equaliseSampleSurfaceY(srcEntry)
    if srcEntry == nil then return nil end
    local node
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
        node = srcEntry.baseNode or srcEntry.volumeNode
    elseif srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        node = srcEntry.fillPlaneNode
    else
        return nil
    end
    if node == nil or node == 0 or not entityExists(node) then return nil end
    local wx, _, wz = getWorldTranslation(node)
    local y = SlurryNodeUtil.getSurfaceWorldY(srcEntry, wx, wz)
    if y == -math.huge then return nil end
    return y
end

-- A side is "neutral" (gravity may move its contents) when it is NOT actively
-- building/holding usable pressure or vacuum. Pressure-model vehicles are neutral
-- only with the pump off, not purging, and stored pressure below threshold.
-- Non-pressure sides (open-top FRC, conduit) are always neutral.
-- Is this vehicle's pump actually running? Mirrors tickFlow's detection exactly:
-- a self-powered tanker uses state.pumpRunning; a TOWED tanker (tractor PTO) uses
-- the engine turn-on state. Checking only state.pumpRunning misses towed tankers,
-- which is why a towed vac tanker would start moving fluid the instant the PTO
-- engaged instead of waiting for pressure to build.
function SlurryPipeManager:_isPumpOn(vehicle)
    if vehicle == nil then return false end
    if self:isVehicleSelfPowered(vehicle) then
        local state = self:getVehicleState(vehicle)
        return state ~= nil and state.pumpRunning == true
    end
    return vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() == true
end

function SlurryPipeManager:_equaliseSideIsNeutral(vehicle)
    if vehicle == nil then return true end
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return true end
    local state = entry.state

    -- [SPS 1.0.0.9.21] Pressure-model (vacuum) side FIRST, and gated on stored
    -- pressure ALONE. A vacuum pump acts on the AIR in the tank, not the
    -- liquid — liquid only moves under a pressure differential. So while
    -- |pressure| < minThreshold the liquid is free to find its level, EVEN
    -- while the pump is running the purge/build through the dead band. This
    -- is the full flip sequence: -2 bar tank flipped to Pressure -> level
    -- holds while the purge vents -2 -> -min (directional scalar owns it),
    -- equalises with the coupled source across the -min..+min dead band, and
    -- pressure takes over pushing OUT once +min is reached. The previous
    -- pump-on / purging early-outs kept equalisation dead for the whole
    -- transit, so the level froze from -min to +min instead of levelling.
    if self:usesPressureModel(entry) then
        if state == nil then return true end
        local cfg  = entry.pressure
        local minT = (cfg ~= nil and cfg.minThreshold) or SlurryPipeManager.DEFAULT_MIN_THRESHOLD
        return math.abs(state.pressure or 0) < minT
    end

    -- [SPS EQ] Non-pressure pumped side (HVP, conduit): the pump moves the
    -- LIQUID directly, so a running pump of any type owns the flow and level
    -- equalisation must never fight it. Open-top FRC / passive vessels have
    -- no pump and fall through to neutral.
    if self:_isPumpOn(vehicle) then return false end

    -- [SPS FM 1.0.1.7] Front-mount proxy: the pump that acts on this tank may
    -- live on a front mount whose hose-connected receiver is THIS vehicle. The
    -- receiver's own state stays neutral (pump/direction belong to the front),
    -- which previously let equalisation fight the front's pumped push — the
    -- observed 43–44% level oscillation on FRC <-> semi. A front mount with
    -- its pump running owns its receiver's level exactly as an onboard pump
    -- would, so the receiver is non-neutral for equalisation purposes.
    for _, fmEntry in ipairs(self.registeredVehicles) do
        if fmEntry.frontMount ~= nil and fmEntry.frontMount.receiver == vehicle then
            if self:_isPumpOn(fmEntry.vehicle) then return false end
        end
    end

    return true
end

-- Current fill level held in a source for the given type.
function SlurryPipeManager:_equaliseSourceLevel(srcEntry, fillType)
    if srcEntry == nil then return 0 end
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or srcEntry.type == "FILL_UNIT_ONLY" then
        if srcEntry.vehicle ~= nil then
            return srcEntry.vehicle:getFillUnitFillLevel(srcEntry.fillUnitIndex) or 0
        end
    elseif srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if srcEntry.storage ~= nil then
            return srcEntry.storage:getFillLevel(fillType) or 0
        end
    end
    return 0
end

-- Free capacity in a destination for the given type.
function SlurryPipeManager:_equaliseDestFree(dstEntry, fillType)
    if dstEntry == nil then return 0 end
    if dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or dstEntry.type == "FILL_UNIT_ONLY" then
        if dstEntry.vehicle ~= nil then
            local cap   = dstEntry.vehicle:getFillUnitCapacity(dstEntry.fillUnitIndex) or 0
            local level = dstEntry.vehicle:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0
            return cap - level
        end
    elseif dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if dstEntry.storage ~= nil then
            return dstEntry.storage:getFreeCapacity(fillType) or 0
        end
    end
    return 0
end

-- Returns a FILL_VOLUME source for head reads, building one on demand. The cached
-- source from resolveVehicleSource may be FILL_UNIT_ONLY (e.g. it resolved before
-- the fill-volume was ready and the result is cached permanently). For head
-- equalisation we need a real fill plane, so if the cache is not a FILL_VOLUME we
-- try to build one fresh and remember it on the entry. Returns nil if the vehicle
-- genuinely has no usable fill volume.
function SlurryPipeManager:_equaliseHeadSource(vehicle, cached)
    if cached ~= nil and cached.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
        return cached
    end
    local e = self:getVehicleEntry(vehicle)
    if e ~= nil and e._eqHeadSource ~= nil then
        return e._eqHeadSource
    end
    if vehicle ~= nil and vehicle.spec_fillVolume ~= nil then
        local fui = (cached ~= nil and cached.fillUnitIndex) or 1
        local fv  = SlurryNodeUtil.buildFillVolumeSource(vehicle, fui)
        if fv ~= nil then
            if e ~= nil then e._eqHeadSource = fv end
            SlurryPipeManager.log("equalise: built on-demand FILL_VOLUME head source for %s (fui=%d)",
                tostring(vehicle.configFileName), fui)
            return fv
        end
    end
    return nil
end

-- World-Y of the slurry surface for a vehicle, for head equalisation.
-- Priority:
--   1) authored surfaceRef (empty/full nodes): lerp(emptyY, fullY, level/capacity).
--      Works for opaque tanks (no fill volume) and is valid server-side. Both
--      sides of a coupling use this when both have a ref, so heads compare cleanly.
--   2) a real fill volume (FRC65 etc. with one) via getSurfaceWorldY.
-- Returns nil if neither is available.
function SlurryPipeManager:_equaliseSurfaceWorldY(vehicle, srcEntry)
    local entry = self:getVehicleEntry(vehicle)
    if entry ~= nil and entry.surfaceRef ~= nil then
        local sr = entry.surfaceRef
        if sr.emptyNode ~= nil and sr.fullNode ~= nil
        and entityExists(sr.emptyNode) and entityExists(sr.fullNode)
        and vehicle ~= nil and vehicle.getFillUnitCapacity ~= nil then
            local fui = (srcEntry ~= nil and srcEntry.fillUnitIndex) or 1
            local cap = vehicle:getFillUnitCapacity(fui) or 0
            local lvl = vehicle:getFillUnitFillLevel(fui) or 0
            local frac = (cap > 0) and math.clamp(lvl / cap, 0, 1) or 0
            local _, eY, _ = getWorldTranslation(sr.emptyNode)
            local _, fY, _ = getWorldTranslation(sr.fullNode)
            return eY + (fY - eY) * frac
        end
    end
    -- Fallback: real fill volume (build on demand if the cache is FILL_UNIT_ONLY).
    local headSrc = self:_equaliseHeadSource(vehicle, srcEntry)
    if headSrc ~= nil then
        return self:_equaliseSampleSurfaceY(headSrc)
    end
    return nil
end

-- Equalise one coupled pair for this pass. Marks both sides _equaliseActive so
-- resolveCouplingFlow defers its one-way gravity drain to us this window.
--
-- DIAGNOSTICS: every early-return reports a reason, change-gated on entryA.state
-- so it prints when the reason changes (not every 150 ms pass). Watch the log key
-- "[SPS PM] equalise" — the eval line shows yA/yB/dY and both fill levels so a
-- collapsed dY (surfaces read equal) or a silent gate is immediately visible.
function SlurryPipeManager:_equalisePair(entryA, couplingA, entryB, couplingB, passSec)
    local vehA, vehB = entryA.vehicle, entryB.vehicle

    -- Change-gated reason logger: prints once when the bail reason changes.
    local function bail(reason)
        if SlurryPipeManager.DEBUG and entryA.state ~= nil and entryA.state._eqLastReason ~= reason then
            entryA.state._eqLastReason = reason
            SlurryPipeManager.log("equalise.skip: %s <-> %s reason=%s",
                tostring(vehA and vehA.configFileName), tostring(vehB and vehB.configFileName), reason)
        end
    end

    -- Both sides must be neutral; otherwise the pressure model owns the flow.
    if not self:_equaliseSideIsNeutral(vehA) then return bail("A_not_neutral") end
    if not self:_equaliseSideIsNeutral(vehB) then return bail("B_not_neutral") end

    local srcA = self:resolveVehicleSource(vehA)
    local srcB = self:resolveVehicleSource(vehB)
    if srcA == nil then return bail("A_src_nil") end
    if srcB == nil then return bail("B_src_nil") end

    -- Head via authored surfaceRef (preferred) or a real fill volume.
    local yA = self:_equaliseSurfaceWorldY(vehA, srcA)
    local yB = self:_equaliseSurfaceWorldY(vehB, srcB)
    if yA == nil then return bail("A_surfaceY_nil(noRef&noVolume)") end
    if yB == nil then return bail("B_surfaceY_nil(noRef&noVolume)") end

    -- Own the pair this window (suppresses gravity backflow on both sides).
    if entryA.state ~= nil then entryA.state._equaliseActive = true end
    if entryB.state ~= nil then entryB.state._equaliseActive = true end

    -- Levels for diagnostics (both sides, raw fill-unit level).
    local lvlA = vehA and vehA.getFillUnitFillLevel and (vehA:getFillUnitFillLevel(srcA.fillUnitIndex) or 0) or -1
    local lvlB = vehB and vehB.getFillUnitFillLevel and (vehB:getFillUnitFillLevel(srcB.fillUnitIndex) or 0) or -1
    local dY = math.abs(yA - yB)

    -- Eval line, change-gated on a coarse signature so it prints on meaningful
    -- change (every ~5 mm of head or ~50 L of level), never every pass.
    if SlurryPipeManager.DEBUG and entryA.state ~= nil then
        local sig = string.format("%.0f|%.0f|%.0f", dY * 200, lvlA / 50, lvlB / 50)
        if entryA.state._eqLastSig ~= sig then
            entryA.state._eqLastSig = sig
            SlurryPipeManager.log("equalise.eval: %s yA=%.3f lvlA=%.0f | %s yB=%.3f lvlB=%.0f | dY=%.3fm (deadband=%.4fm)",
                tostring(vehA and vehA.configFileName), yA, lvlA,
                tostring(vehB and vehB.configFileName), yB, lvlB,
                dY, SlurryPipeManager.EQUALISE_HEAD_DEADBAND)
        end
    end

    if dY <= SlurryPipeManager.EQUALISE_HEAD_DEADBAND then
        -- Surfaces level. Log the settle once on the moving->settled transition.
        if (entryA.state ~= nil and entryA.state._eqWasMoving)
        or (entryB.state ~= nil and entryB.state._eqWasMoving) then
            SlurryPipeManager.log("equalise: settled dY=%.1fmm lvlA=%.0f lvlB=%.0f", dY * 1000, lvlA, lvlB)
        end
        if entryA.state ~= nil then entryA.state._eqWasMoving = false end
        if entryB.state ~= nil then entryB.state._eqWasMoving = false end
        return
    end

    -- Orient high -> low.
    local hiEntry, loEntry, hiSrc, loSrc, hiCoupling, loCoupling
    if yA > yB then
        hiEntry, loEntry       = entryA, entryB
        hiSrc,   loSrc         = srcA,   srcB
        hiCoupling, loCoupling = couplingA, couplingB
    else
        hiEntry, loEntry       = entryB, entryA
        hiSrc,   loSrc         = srcB,   srcA
        hiCoupling, loCoupling = couplingB, couplingA
    end

    -- Honour coupling flowDirection restrictions against the resolved direction.
    if hiCoupling.flowDirection == "FILL" then return bail("hi_flowDir_FILL_only") end
    if loCoupling.flowDirection == "DISCHARGE" then return bail("lo_flowDir_DISCHARGE_only") end

    -- [SPS 1.0.0.9.22] Optional per-coupler hydraulic head gate. A coupler may
    -- declare headHeightNodeName at the highest point of its pipe run; gravity
    -- cannot beat that crest (no siphon for slurry), so flow only runs while
    -- the DRIVING (high) surface is above the crest of BOTH couplers involved.
    -- Node absent = nil = no gate = behaviour unchanged (all existing configs).
    local drivingY = math.max(yA, yB)
    if hiCoupling.headHeightNode ~= nil and entityExists(hiCoupling.headHeightNode) then
        local _, hy, _ = getWorldTranslation(hiCoupling.headHeightNode)
        if drivingY <= hy then return bail("driving_below_hi_headNode") end
    end
    if loCoupling.headHeightNode ~= nil and entityExists(loCoupling.headHeightNode) then
        local _, hy, _ = getWorldTranslation(loCoupling.headHeightNode)
        if drivingY <= hy then return bail("driving_below_lo_headNode") end
    end

    -- fillType comes from the high (source) side; the low side must accept it so
    -- slurry and water never equalise into each other.
    local fillType = self:_resolveSourceFillType(hiSrc)
    if fillType == nil then return bail("hi_fillType_nil(srcLevel<=0?)") end
    if not self:_destAcceptsFillType(loSrc, fillType) then return bail("lo_rejects_fillType=" .. tostring(fillType)) end

    local sourceLevel = self:_equaliseSourceLevel(hiSrc, fillType)
    local destFree    = self:_equaliseDestFree(loSrc, fillType)
    if sourceLevel <= 0 then return bail("hi_sourceLevel<=0") end
    if destFree <= 0 then return bail("lo_destFree<=0") end
    if entryA.state ~= nil then entryA.state._eqLastReason = nil end

    -- Tapered rate: full configured rate beyond TAPER_HEAD, scaling to zero as the
    -- surfaces converge. Taper + dead-band prevent overshoot for any tank geometry.
    local outRate = hiEntry.emptyLitersPerSecond or hiEntry.litersPerSecond or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local inRate  = loEntry.fillLitersPerSecond  or loEntry.litersPerSecond  or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local rate    = math.min(outRate, inRate)
    local taper   = math.min(1.0, dY / SlurryPipeManager.EQUALISE_TAPER_HEAD)

    local amount = rate * passSec * taper
    amount = math.min(amount, sourceLevel, destFree)
    if amount <= 0 then return bail("amount<=0") end

    -- Log the start once on the settled->moving transition.
    if (hiEntry.state ~= nil and not hiEntry.state._eqWasMoving) then
        SlurryPipeManager.log("equalise: start hi=%s lo=%s dY=%.3fm fillType=%d",
            tostring(hiEntry.vehicle and hiEntry.vehicle.configFileName),
            tostring(loEntry.vehicle and loEntry.vehicle.configFileName), dY, fillType)
    end
    if hiEntry.state ~= nil then hiEntry.state._eqWasMoving = true end
    if loEntry.state ~= nil then loEntry.state._eqWasMoving = true end

    self:removeFromSource(hiSrc, amount, fillType, hiEntry.vehicle)
    self:addToSource(loSrc, amount, fillType, loEntry.vehicle)
end

-- [SPS 1.0.0.9.22] Resolve the STORE coupling at the far end of a vehicle
-- coupling, for vehicle<->store head equalisation. Direct bez/strap bond:
-- the partner coupling itself (carries .placeable + .sourceEntry). Chain run:
-- the chain's anchor coupling when that anchor is a store coupler. Returns
-- nil for vehicle partners, unresolvable chains, or anything else.
function SlurryPipeManager:_equaliseResolveStoreCoupling(coupling)
    local partner = coupling.connectedPartnerCoupling
    if partner == nil then return nil end
    if partner.placeable ~= nil and partner.sourceEntry ~= nil then return partner end
    if (partner.isChainTerminus or partner.isChainStart) and partner.chain ~= nil then
        local anchor = partner.chain.anchorCoupling
        if anchor ~= nil and anchor.placeable ~= nil and anchor.sourceEntry ~= nil then
            return anchor
        end
    end
    return nil
end

-- [SPS 1.0.0.9.22] Head equalisation between a vehicle and a placeable STORE,
-- opt-in per store coupler: the store coupling MUST declare headHeightNodeName
-- (the highest point of its internal pipe run) or the pair is skipped exactly
-- as all stores were before. Rule, both directions through the coupler: the
-- DRIVING surface must be above the store's head node (a tower riser crest is
-- unbeatable by gravity — no siphon), above the vehicle coupler's own head
-- node when one is declared, and above the receiving surface (equilibrium).
-- Mirrors _equalisePair's maths: same dead band, same taper, same fillType
-- gating; store side reads/writes through the shared source helpers so DM
-- pools, thickness, and deposit fillType conversion all apply as normal.
-- Store rates: the vehicle's configured rates bound the transfer.
function SlurryPipeManager:_equalisePairStore(entryA, couplingA, sc, passSec)
    local vehA = entryA.vehicle

    local function bail(reason)
        if SlurryPipeManager.DEBUG and entryA.state ~= nil and entryA.state._eqLastReason ~= reason then
            entryA.state._eqLastReason = reason
            SlurryPipeManager.log("equalise.skip: %s <-> store(%s) reason=%s",
                tostring(vehA and vehA.configFileName),
                tostring(sc.placeable and sc.placeable.configFileName), reason)
        end
    end

    -- Vehicle side must be neutral (pressure model / pump gates as usual); a
    -- store has no pump and is always neutral.
    if not self:_equaliseSideIsNeutral(vehA) then return bail("A_not_neutral") end

    if sc.headHeightNode == nil or not entityExists(sc.headHeightNode) then
        return bail("store_headNode_missing")
    end

    local srcA = self:resolveVehicleSource(vehA)
    if srcA == nil then return bail("A_src_nil") end
    -- Store source, honouring a per-coupler fillType restriction (BGA-style).
    local srcS = self:_restrictSourceToCoupling(sc.sourceEntry, sc)
    if srcS == nil or srcS.fillPlaneNode == nil or not entityExists(srcS.fillPlaneNode) then
        return bail("store_src_nil")
    end

    local yA = self:_equaliseSurfaceWorldY(vehA, srcA)
    if yA == nil then return bail("A_surfaceY_nil(noRef&noVolume)") end
    local px, _, pz = getWorldTranslation(srcS.fillPlaneNode)
    local yS = SlurryNodeUtil.getSurfaceWorldY(srcS, px, pz)
    if yS == nil or yS == -math.huge then return bail("store_surfaceY_nil") end

    -- Own the vehicle side this window (suppresses its gravity backflow).
    if entryA.state ~= nil then entryA.state._equaliseActive = true end

    local dY = math.abs(yA - yS)
    if dY <= SlurryPipeManager.EQUALISE_HEAD_DEADBAND then
        if entryA.state ~= nil and entryA.state._eqWasMoving then
            SlurryPipeManager.log("equalise(store): settled dY=%.1fmm", dY * 1000)
            entryA.state._eqWasMoving = false
        end
        return
    end

    -- Orient high -> low and gate on flowDirection restrictions.
    local vehicleIsHigh = yA > yS
    local hiSrc, loSrc
    if vehicleIsHigh then
        hiSrc, loSrc = srcA, srcS
        if couplingA.flowDirection == "FILL" then return bail("veh_flowDir_FILL_only") end
        if sc.flowDirection == "DISCHARGE" then return bail("store_flowDir_DISCHARGE_only") end
    else
        hiSrc, loSrc = srcS, srcA
        if sc.flowDirection == "FILL" then return bail("store_flowDir_FILL_only") end
        if couplingA.flowDirection == "DISCHARGE" then return bail("veh_flowDir_DISCHARGE_only") end
    end

    -- Hydraulic head gates: driving surface must clear the store's crest, and
    -- the vehicle coupler's own crest when it declares one.
    local drivingY = math.max(yA, yS)
    local _, storeHeadY, _ = getWorldTranslation(sc.headHeightNode)
    if drivingY <= storeHeadY then return bail("driving_below_store_headNode") end
    if couplingA.headHeightNode ~= nil and entityExists(couplingA.headHeightNode) then
        local _, vhy, _ = getWorldTranslation(couplingA.headHeightNode)
        if drivingY <= vhy then return bail("driving_below_veh_headNode") end
    end

    -- fillType from the high (source) side; the low side must accept it.
    local fillType = self:_resolveSourceFillType(hiSrc)
    if fillType == nil then return bail("hi_fillType_nil(srcLevel<=0?)") end
    if not self:_destAcceptsFillType(loSrc, fillType) then return bail("lo_rejects_fillType=" .. tostring(fillType)) end

    local sourceLevel = self:_equaliseSourceLevel(hiSrc, fillType)
    local destFree    = self:_equaliseDestFree(loSrc, fillType)
    if sourceLevel <= 0 then return bail("hi_sourceLevel<=0") end
    if destFree <= 0 then return bail("lo_destFree<=0") end
    if entryA.state ~= nil then entryA.state._eqLastReason = nil end

    -- Tapered rate, bounded by the vehicle's configured rates (a store has none).
    local outRate = entryA.emptyLitersPerSecond or entryA.litersPerSecond or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local inRate  = entryA.fillLitersPerSecond  or entryA.litersPerSecond  or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local rate    = math.min(outRate, inRate)
    local taper   = math.min(1.0, dY / SlurryPipeManager.EQUALISE_TAPER_HEAD)

    local amount = rate * passSec * taper
    amount = math.min(amount, sourceLevel, destFree)
    if amount <= 0 then return bail("amount<=0") end

    if entryA.state ~= nil and not entryA.state._eqWasMoving then
        SlurryPipeManager.log("equalise(store): start %s %s store dY=%.3fm fillType=%d",
            tostring(vehA and vehA.configFileName), vehicleIsHigh and "->" or "<-", dY, fillType)
        entryA.state._eqWasMoving = true
    end

    self:removeFromSource(hiSrc, amount, fillType, vehA)
    self:addToSource(loSrc, amount, fillType, vehA)
end

-- Server-only, throttled driver. Discovers directly-coupled vehicle pairs whose
-- valves are both open and equalises each by head.
function SlurryPipeManager:updateLevelEqualise(dt)
    if g_server == nil then return end

    self._equaliseAccum = (self._equaliseAccum or 0) + dt
    if self._equaliseAccum < SlurryPipeManager.EQUALISE_INTERVAL_MS then return end
    local passSec = self._equaliseAccum * 0.001
    self._equaliseAccum = 0

    -- Clear the per-vehicle equalise flag, then set it below for vehicles whose
    -- coupling is currently equalising. resolveCouplingFlow reads it to suppress
    -- the one-way gravity drain so the two mechanisms never move the same slurry.
    for _, vEntry in ipairs(self.registeredVehicles) do
        if vEntry.state ~= nil then vEntry.state._equaliseActive = false end
    end

    -- Reusable visited set (cleared, not reallocated). Keyed by an unordered
    -- vehicle-id pair so a pair joined by two couplings (or both ends of a chain)
    -- is processed once per pass.
    local visited = self._equaliseVisited
    if visited == nil then
        visited = {}
        self._equaliseVisited = visited
    else
        for k in pairs(visited) do visited[k] = nil end
    end

    local pairCount = 0
    local connOpenCount = 0   -- connected couplings with valve open (diagnostic)
    for _, vEntry in ipairs(self.registeredVehicles) do
        local vehA = vEntry.vehicle
        for _, c in ipairs(vEntry.couplingEntries) do
            if c.isConnected and c.valveOpen then
                connOpenCount = connOpenCount + 1
                -- Resolve the far-end source for this coupling. This walks a chain
                -- to its anchor when the partner is a chain terminus, so the same
                -- path covers direct couplings AND chain-pipe layouts. (In MP this
                -- needs the chain connection visible server-side; single-player is
                -- fine. Returns nil server-side on a dedicated server for chains.)
                local partnerSrc = self:resolveSourceForCouplingPartner(c)
                local partnerVehicle = partnerSrc ~= nil and partnerSrc.vehicle or nil
                local skip = nil
                if partnerSrc == nil then
                    skip = "partner_src_nil(chain not resolvable / not connected server-side)"
                elseif partnerVehicle == nil then
                    -- [SPS 1.0.0.9.22] Vehicle <-> STORE equalisation, opt-in per
                    -- store coupler: only a store coupling that declares
                    -- headHeightNodeName takes part; every other store coupler is
                    -- ignored here exactly as all stores were before.
                    local storeCpl = self:_equaliseResolveStoreCoupling(c)
                    if storeCpl == nil then
                        skip = "partner_not_vehicle(store/unknown)"
                    elseif storeCpl.headHeightNode == nil then
                        skip = "store_no_headHeightNode(ignored)"
                    else
                        local idA = vehA.id or 0
                        local key = idA .. ":store:" .. tostring(storeCpl)
                        if not visited[key] then
                            visited[key] = true
                            pairCount = pairCount + 1
                            self:_equalisePairStore(vEntry, c, storeCpl, passSec)
                        end
                    end
                elseif partnerVehicle == vehA then
                    skip = "partner_is_self"
                else
                    local entryB = self:getVehicleEntry(partnerVehicle)
                    if entryB == nil then
                        skip = "partner_not_registered"
                    else
                        local idA = vehA.id or 0
                        local idB = partnerVehicle.id or 0
                        local key = (idA < idB) and (idA .. ":" .. idB) or (idB .. ":" .. idA)
                        if not visited[key] then
                            visited[key] = true
                            pairCount = pairCount + 1
                            -- couplingB (partner) is used only for flowDirection; the
                            -- connectedPartnerCoupling is the partner coupling (direct)
                            -- or the chain terminus (chain) — either is fine.
                            self:_equalisePair(vEntry, c, entryB, c.connectedPartnerCoupling, passSec)
                        end
                    end
                end
                if skip ~= nil and c._eqDiscReason ~= skip then
                    c._eqDiscReason = skip
                    SlurryPipeManager.logMP(string.format("[SPS MP] equalise NOT paired couplingId=%s on %s — %s",
                        tostring(c.id), tostring(vehA and vehA.configFileName), skip))
                end
            end
        end
    end

    -- Change-gated so we see when equalise pairs appear/disappear, never per pass.
    if (self._eqLastPairCount ~= pairCount or self._eqLastConnOpen ~= connOpenCount) then
        self._eqLastPairCount = pairCount
        self._eqLastConnOpen  = connOpenCount
        SlurryPipeManager.logMP(string.format("[SPS MP] equalise openCouplings=%d activePairs=%d", connOpenCount, pairCount))
    end
end

function SlurryPipeManager:buildFlowSession(vehicle)
    SlurryPipeManager.log("buildFlowSession: %s", tostring(vehicle and vehicle.configFileName))
    local fillLPS  = SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local emptyLPS = SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local vehicleFillUnit = 1
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            fillLPS  = entry.fillLitersPerSecond  or entry.litersPerSecond or fillLPS
            emptyLPS = entry.emptyLitersPerSecond or entry.litersPerSecond or emptyLPS
            if #entry.armEntries > 0 then
                vehicleFillUnit = entry.armEntries[1].fillUnitIndex
            elseif #entry.couplingEntries > 0 then
                vehicleFillUnit = entry.couplingEntries[1].fillUnitIndex
            end
            break
        end
    end
    local session = {
        vehicle               = vehicle,
        vehicleFillUnit       = vehicleFillUnit,
        baseLitersPerSecond   = emptyLPS,   -- legacy field = empty rate
        baseFillLitersPerSecond  = fillLPS,
        baseEmptyLitersPerSecond = emptyLPS,
    }
    -- [SPS FM 1.0.1.7] Front mount: the tank side of the session is the
    -- hose-connected receiver, never the front's own capacity-0 unit. Seeded
    -- here and revalidated EVERY tick in tickFlow (the receiver can change or
    -- vanish mid-session with attach/hose state).
    local fmEntry = self:getVehicleEntry(vehicle)
    if fmEntry ~= nil and fmEntry.frontMount ~= nil then
        local receiver, _, fui = self:getFrontMountReceiver(vehicle)
        session.isFrontMount = true
        session.tankVehicle = receiver
        if fui ~= nil then session.vehicleFillUnit = fui end
    end
    return session
end

-- ---------------------------------------------------------------------------
-- Arm detection
-- ---------------------------------------------------------------------------
function SlurryPipeManager:detectArmConnection(vehicle, entry, arm)
    -- If any pipe coupling on this vehicle is connected, the pipe governs.
    -- Arm detection is blocked completely to prevent cab valve from bypassing
    -- the manual valve on the pipe connection.
    -- [SPS 1.0.1.8] FRONT-MOUNT EXCEPTION: a front mount is a pass-through
    -- pump whose arm and coupler are BOTH live by design (the coupler-first
    -- cascade in tickFrontMountArmCascade). No valve bypass is created: the
    -- cab hydraulic valve still gates the arm path, and the coupling's own
    -- manual valve still gates the coupler path independently.
    if entry.frontMount == nil then
        for _, c in ipairs(entry.couplingEntries) do
            if c.isConnected then
                if arm.isConnected then
                    arm.isConnected    = false
                    arm.connectedSource   = nil
                    arm.connectedBootPort = nil
                end
                return
            end
        end
    end

    local state     = entry.state
    local direction = state and state.direction or SPS_DIRECTION_FILL
    local tipType   = arm.tipType or SPS_TIP_TYPE_OPEN_PIT

    -- [SPS ARMDIAG] throttled, read-only. Logs only while the cab valve is open.
    arm._spsDiagN = (arm._spsDiagN or 0) + 1
    --local diagOn  = (state ~= nil and state.valveOpen == true) and (arm._spsDiagN % 10 == 0)
	local diagOn  = false
	
    local newConnected    = false
    local foundSource     = nil
    local foundBootPort   = nil

    -- Rubber boot detection
    local supportsRubberBoot = (tipType == SPS_TIP_TYPE_RUBBER_BOOT) or (tipType == SPS_TIP_TYPE_RUBBER_BOOT_PIT)
    if supportsRubberBoot and arm.tipNode ~= nil and entityExists(arm.tipNode) then
        local tx, ty, tz   = getWorldTranslation(arm.tipNode)
        local XZ_TOLERANCE = 0.15
        for _, rbpEntry in ipairs(self.rubberBootPortEntries) do
            if rbpEntry.vehicle ~= vehicle and rbpEntry.lowerNode ~= nil and rbpEntry.upperNode ~= nil then
                if entityExists(rbpEntry.lowerNode) and entityExists(rbpEntry.upperNode) then
                    local lx, lowerY, lz = getWorldTranslation(rbpEntry.lowerNode)
                    local _,  upperY, _  = getWorldTranslation(rbpEntry.upperNode)
                    if lowerY > upperY then lowerY, upperY = upperY, lowerY end
                    local xzDist = math.sqrt((tx - lx) * (tx - lx) + (tz - lz) * (tz - lz))
                    if ty >= lowerY and ty <= upperY and xzDist <= XZ_TOLERANCE then
                        newConnected  = true
                        foundBootPort = rbpEntry
                        break
                    end
                end
            end
        end
    end

    -- Open pit detection
    local supportsOpenPit = (tipType == SPS_TIP_TYPE_OPEN_PIT) or (tipType == SPS_TIP_TYPE_RUBBER_BOOT_PIT)
    if supportsOpenPit and not newConnected and arm.centreNode ~= nil then
        local THRESHOLD   = 0.08
        local centreX, centreY, centreZ = getWorldTranslation(arm.centreNode)

        for _, sourceEntry in ipairs(self.sourceEntries) do
            if sourceEntry.vehicle == vehicle then continue end

            -- XZ check: shape-based bounds for STORAGE_PLANE, fixed radius for FILL_VOLUME.
            local xzOk = false
            if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                local bounds = sourceEntry.planeBounds
                if bounds == nil then continue end
                if bounds.shape == "round" then
                    local bx, _, bz = getWorldTranslation(bounds.centreNode)
                    local dx = centreX - bx
                    local dz = centreZ - bz
                    xzOk = (dx * dx + dz * dz) <= (bounds.radius * bounds.radius)
                elseif bounds.shape == "rectangle" then
                    local lx, _, lz = worldToLocal(bounds.centreNode, centreX, centreY, centreZ)
                    xzOk = lx >= bounds.minX and lx <= bounds.maxX and lz >= bounds.minZ and lz <= bounds.maxZ
                end
            elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
                local bx, _, bz = getWorldTranslation(sourceEntry.baseNode)
                local dx = centreX - bx
                local dz = centreZ - bz
                local r = SlurryPipeManager.FILL_VOLUME_SEARCH_RADIUS
                xzOk = (dx * dx + dz * dz) <= (r * r)
            end
            if not xzOk then continue end

            local surfaceY = SlurryNodeUtil.getSurfaceWorldY(sourceEntry, centreX, centreZ)
            if surfaceY == -math.huge then continue end

            local valid = false
            if direction == SPS_DIRECTION_FILL then
                -- Centre node must be below the surface: nozzle is submerged
                valid = surfaceY > centreY + THRESHOLD
            else
                -- Centre node must be above the surface: nozzle is over the liquid
                valid = centreY > surfaceY + THRESHOLD
            end

            if valid then
                newConnected = true
                foundSource  = sourceEntry
                break
            end
        end
    end

    -- Water plane detection (only if not already connected)
    if supportsOpenPit and not newConnected and arm.centreNode ~= nil and g_waterPlaneManager ~= nil then
        local THRESHOLD = 0.08
        local centreX, centreY, centreZ = getWorldTranslation(arm.centreNode)
        
        -- Find water plane at this position
        local waterPlane = g_waterPlaneManager:findWaterPlaneAtPosition(centreX, centreZ)
        
        if waterPlane ~= nil then
            local valid = false
            
            if direction == SPS_DIRECTION_FILL then
                -- Fill: centre node must be below water surface (submerged)
                valid = centreY < waterPlane.waterY - THRESHOLD
            else
                -- Discharge: centre node must be above water surface
                valid = centreY > waterPlane.waterY + THRESHOLD
            end
            
            if valid then
                -- Create infinite water source
                local waterSource = g_waterPlaneManager:createWaterSource(waterPlane)
                newConnected = true
                foundSource = waterSource
            end
        end
    end

    if diagOn then
        local cx, cy, cz = 0, 0, 0
        if arm.centreNode ~= nil and entityExists(arm.centreNode) then
            cx, cy, cz = getWorldTranslation(arm.centreNode)
        end
        -- Evaluate the REAL xz-bounds test + surface check per source (mirrors detection).
        local parts = {}
        for si, se in ipairs(self.sourceEntries) do
            if se.vehicle ~= vehicle then
                local xzOk = false
                if se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                    local b = se.planeBounds
                    if b ~= nil then
                        if b.shape == "round" and b.centreNode ~= nil then
                            local bx, _, bz = getWorldTranslation(b.centreNode)
                            local dx, dz = cx - bx, cz - bz
                            xzOk = (dx*dx + dz*dz) <= (b.radius * b.radius)
                        elseif b.shape == "rectangle" and b.centreNode ~= nil then
                            local lx, _, lz = worldToLocal(b.centreNode, cx, cy, cz)
                            xzOk = lx >= b.minX and lx <= b.maxX and lz >= b.minZ and lz <= b.maxZ
                        end
                    end
                elseif se.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME and se.baseNode ~= nil then
                    local bx, _, bz = getWorldTranslation(se.baseNode)
                    local dx, dz = cx - bx, cz - bz
                    local r = SlurryPipeManager.FILL_VOLUME_SEARCH_RADIUS
                    xzOk = (dx*dx + dz*dz) <= (r*r)
                end
                local sy = SlurryNodeUtil.getSurfaceWorldY(se, cx, cz)
                local submerged = (sy ~= -math.huge) and (sy > cy + 0.08)
                parts[#parts+1] = string.format("#%d[%s xz=%s surfY=%.2f sub=%s]",
                    si, tostring(se.type), tostring(xzOk), sy, tostring(submerged))
            end
        end
        --print(string.format(
        --    "[SPS ARMDIAG] arm id=%s tip=%s dir=%s centre=(%.2f,%.2f,%.2f) sources=%d boots=%d %s -> connected=%s",
        --    tostring(arm.id), tostring(tipType), tostring(direction), cx, cy, cz,
        --    #self.sourceEntries, #self.rubberBootPortEntries,
        --    table.concat(parts, " "), tostring(newConnected)))
    end

    local prevConnected   = arm.isConnected
    arm.isConnected       = newConnected
    arm.connectedSource   = foundSource
    arm.connectedBootPort = foundBootPort

    -- [SPS FRCDIAG] Crash-proof, change-gated diagnostic for "arm won't suck from FRC".
    -- Validates every node with entityExists BEFORE any engine call (getSurfaceWorldY
    -- can hard-error on a source whose volume/base node is nil), and reports node
    -- validity so a source registered with a missing node is immediately visible.
    do
        local function nodeOk(n) return n ~= nil and n ~= 0 and entityExists(n) end
        local cx, cy, cz = 0, 0, 0
        if nodeOk(arm.centreNode) then cx, cy, cz = getWorldTranslation(arm.centreNode) end
        local tpx, tpy, tpz = cx, cy, cz
        if nodeOk(arm.tipNode) then tpx, tpy, tpz = getWorldTranslation(arm.tipNode) end
        local srcParts = {}
        for _, se in ipairs(self.sourceEntries) do
            if se.vehicle ~= vehicle and (se.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME
                                          or se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE) then
                local label = tostring(se.debugLabel or se.type)
                if se.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
                    local baseOk = nodeOk(se.baseNode)
                    local volOk  = nodeOk(se.volumeNode)
                    local xz, surfY, sub = -1, nil, "n/a"
                    if baseOk then
                        local bx, _, bz = getWorldTranslation(se.baseNode)
                        xz = math.sqrt((cx - bx) * (cx - bx) + (cz - bz) * (cz - bz))
                    end
                    if baseOk and volOk then
                        surfY = SlurryNodeUtil.getSurfaceWorldY(se, cx, cz)
                        sub = tostring(surfY ~= -math.huge and surfY > cy + 0.08)
                    end
                    srcParts[#srcParts+1] = string.format("[%s FV base=%s vol=%s xz=%.2f surfY=%s cY=%.2f sub=%s]",
                        label, tostring(baseOk), tostring(volOk), xz, tostring(surfY), cy, sub)
                else
                    local planeOk = nodeOk(se.fillPlaneNode)
                    srcParts[#srcParts+1] = string.format("[%s STORE plane=%s]", label, tostring(planeOk))
                end
            end
        end
        local bootParts = {}
        for _, rbp in ipairs(self.rubberBootPortEntries) do
            if rbp.vehicle ~= vehicle and nodeOk(rbp.lowerNode) and nodeOk(rbp.upperNode) then
                local lx, lY, lz = getWorldTranslation(rbp.lowerNode)
                local _,  uY, _  = getWorldTranslation(rbp.upperNode)
                if lY > uY then lY, uY = uY, lY end
                local xz = math.sqrt((tpx - lx) * (tpx - lx) + (tpz - lz) * (tpz - lz))
                local ok = (tpy >= lY and tpy <= uY and xz <= 0.15)
                bootParts[#bootParts+1] = string.format("[chain=%s tipY=%.2f band=%.2f..%.2f xz=%.2f ok=%s]",
                    tostring(rbp.isChain == true), tpy, lY, uY, xz, tostring(ok))
            end
        end
        local sig = string.format("%s|s=%d|b=%d|c=%s", tostring(tipType), #srcParts, #bootParts, tostring(newConnected))
        if arm._frcDiagSig ~= sig then
            arm._frcDiagSig = sig
            SlurryPipeManager.logMP(string.format("[SPS FRCDIAG] %s tip=%s dir=%s connected=%s | sources: %s | boots: %s",
                tostring(vehicle and vehicle.configFileName), tostring(tipType), tostring(direction),
                tostring(newConnected),
                (#srcParts > 0 and table.concat(srcParts, " ") or "none"),
                (#bootParts > 0 and table.concat(bootParts, " ") or "none")))
        end
    end

    if prevConnected ~= newConnected then
        SlurryPipeManager.log("detectArmConnection: %s arm %s -> %s",
            tostring(vehicle and vehicle.configFileName), tostring(prevConnected),
            newConnected and "CONNECTED" or "DISCONNECTED")
        if newConnected then
            self:onArmConnected(vehicle, arm)
        else
            self:onArmDisconnected(vehicle, arm)
        end
    end

    -- Prefer this arm's own effect set (per-arm embedded effects); fall back to the
    -- legacy single shared effect for nodeTree / single-effect embedded configs.
    local armEffects = arm.pipeEffects or entry.pipeEffects
    if armEffects ~= nil then
        local valveOpen   = state ~= nil and state.valveOpen or false
        local fillLevel   = vehicle.getFillUnitFillLevel ~= nil and vehicle:getFillUnitFillLevel(arm.fillUnitIndex) or 0
        -- The stream follows actual flow, which is pressure-driven (not the PTO),
        -- and shows in BOTH directions: a discharge stream out, or a suction
        -- stream while filling. For an exempt endpoint the scalar is 1.0 so it
        -- behaves as a simple on/off with the valve.
        -- [SPS 1.0.0.9.20] Direction-aware: no stream during the hold window
        -- (stored pressure opposing the selected direction) — visuals now match
        -- the gated flow instead of showing a discharge driven by a vacuum.
        local pScalar     = self:getDirectionalPressureFlowScalar(vehicle,
            state ~= nil and state.direction or nil)
        local isDischarge = state ~= nil and state.direction == SPS_DIRECTION_DISCHARGE or false
        local hasFlowContent
        if isDischarge then
            hasFlowContent = fillLevel > 0      -- discharging: slurry must be in the tank
        else
            hasFlowContent = foundSource ~= nil -- filling: a source must be present to draw from
        end
        local shouldPlay  = arm.isConnected and valveOpen and pScalar > 0 and hasFlowContent
        if shouldPlay then
            if not arm.effectPlaying then
                local effectFillType = vehicle:getFillUnitFillType(arm.fillUnitIndex)
                if effectFillType == nil or effectFillType == FillType.UNKNOWN then
                    effectFillType = FillType.LIQUIDMANURE
                end
                -- Apply material matching the current fluid before starting effects
                local pe = armEffects[1]
                if pe ~= nil then
                    if effectFillType == FillType.WATER and g_spsWaterMaterial ~= nil then
                        setMaterial(pe.node, g_spsWaterMaterial, 0)
                    elseif g_spsSlurryMaterial ~= nil then
                        setMaterial(pe.node, g_spsSlurryMaterial, 0)
                    end
                    pe.hasValidMaterial = true
                    pe.useBaseMaterial  = true
                end
                g_effectManager:setEffectTypeInfo(armEffects, effectFillType)
                g_effectManager:startEffects(armEffects)
                arm.effectPlaying = true
            end
            -- Update stream distance: nozzle to slurry surface
            if arm.centreNode ~= nil and foundSource ~= nil then
                local _, nozzleY, _ = getWorldTranslation(arm.centreNode)
                local surfY = SlurryNodeUtil.getSurfaceWorldY(foundSource, centreX, centreZ)
                if surfY ~= -math.huge then
                    local dist = math.abs(nozzleY - surfY)
                    local pipeEffect = armEffects[1]
                    if pipeEffect ~= nil and pipeEffect.setDistance ~= nil then
                        pipeEffect:setDistance(dist)
                        setVisibility(pipeEffect.node, dist > 0.05)
                    end
                end
            end
        else
            if arm.effectPlaying then g_effectManager:stopEffects(armEffects) arm.effectPlaying = false end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Flow tick
-- ---------------------------------------------------------------------------
function SlurryPipeManager:tickFlow(session, dt)
    local vehicle = session.vehicle
    local state   = self:getVehicleState(vehicle)
    if state == nil then return end

    -- -----------------------------------------------------------------------
    -- [SPS FM 1.0.1.7] Front-mount tank side. Revalidated EVERY tick: the
    -- receiver is derived from live hose state and can vanish mid-session
    -- (detach) — flow must stop instantly while the pump keeps running.
    -- tankVehicle is the vehicle whose fill unit the session reads/writes;
    -- for everything except a front mount it is the session vehicle itself.
    -- fmBail: channel-gated, change-deduped bail tracing for front-mount
    -- sessions ONLY — closes the "silent early return" observability hole.
    -- -----------------------------------------------------------------------
    local function fmBail(tag)
        if session.isFrontMount == true
           and SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSM_FrontMount")
           and session._fmBail ~= tag then
            session._fmBail = tag
            print(string.format("[SPS FM] tickFlow bail: %s reason=%s",
                tostring(vehicle.configFileName), tostring(tag)))
        end
    end
    if session.isFrontMount == true then
        -- [SPS 1.0.1.8] Tank side is now a PRIORITY LIST (coupler targets
        -- first, receiver second), resolved fresh every tick by
        -- getFrontMountTankTargets. The receiver, when present, still seeds
        -- tankVehicle for the legacy paths (coupler->receiver mode, HUD);
        -- but a missing receiver no longer bails the session as long as an
        -- open, connected coupler target exists (pure pass-through: tractor
        -- with front mount only, bez pipe to a free-standing tanker/store).
        session.fmTargets = self:getFrontMountTankTargets(vehicle)
        local receiver, fmReason, fui = self:getFrontMountReceiver(vehicle)
        if receiver ~= nil and fui ~= nil then
            session.tankVehicle     = receiver
            session.vehicleFillUnit = fui
        else
            session.tankVehicle = nil
        end
        if session.fmTargets == nil or #session.fmTargets == 0 then
            fmBail("no_targets:" .. tostring(fmReason))
            return
        end
    end
    local tankVehicle = session.tankVehicle or vehicle

    local pumpRunning
    if self:isVehicleSelfPowered(vehicle) then
        pumpRunning = state.pumpRunning == true
    else
        pumpRunning = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() or false
    end

    -- Conduit pump: direct source-to-source transfer, no vehicle fill unit involved
    if self:isVehicleConduit(vehicle) then
        if not state.valveOpen then return end
        if not pumpRunning then return end
        local c1, c2
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.vehicle == vehicle then
                for _, c in ipairs(vEntry.couplingEntries) do
                    if     c.id == 1 then c1 = c
                    elseif c.id == 2 then c2 = c end
                end
                break
            end
        end
        if c1 == nil or c2 == nil or not c1.isConnected or not c2.isConnected then return end

        -- Stop flow if the near-end bez pipe has been physically removed on either side.
        -- For vehicle-anchored chains the near-end bez is chainStartCoupling on segment 1.
        local function chainIntact(pumpCoupling)
            local partner = pumpCoupling.connectedPartnerCoupling
            if partner == nil or not partner.isChainTerminus then return true end
            local chain = partner.chain
            if chain == nil then return true end
            local anchor = chain.anchorCoupling
            if anchor == nil or anchor.placeable ~= nil then return true end
            local seg1 = chain.segments and chain.segments[1]
            if seg1 ~= nil and seg1.chainStartCoupling ~= nil then
                if not seg1.chainStartCoupling.isConnected then return false end
            end
            return true
        end
        if not chainIntact(c1) or not chainIntact(c2) then return end
        local srcCoupling = (state.direction == SPS_DIRECTION_DISCHARGE) and c1 or c2
        local dstCoupling = (state.direction == SPS_DIRECTION_DISCHARGE) and c2 or c1

        -- Check flowDirection on the real partner couplings (may be behind chain terminus)
        local function resolvePartnerFlowDirection(pumpCoupling)
            local partner = pumpCoupling.connectedPartnerCoupling
            if partner == nil then return nil end
            if partner.isChainTerminus and partner.chain ~= nil then
                partner = partner.chain.anchorCoupling
            end
            return partner and partner.flowDirection or nil
        end
        local srcPartnerDir = resolvePartnerFlowDirection(srcCoupling)
        local dstPartnerDir = resolvePartnerFlowDirection(dstCoupling)
        if srcPartnerDir == "DISCHARGE" then return end
        if dstPartnerDir == "FILL" then return end
        local srcEntry = self:resolveSourceForCouplingPartner(srcCoupling)
        local dstEntry = self:resolveSourceForCouplingPartner(dstCoupling)
        if srcEntry == nil or dstEntry == nil then return end

        -- Resolve fillType from what the source actually holds (LIQUIDMANURE,
        -- DIGESTATE, etc.). If source is empty, nothing to transfer.
        local fillType = self:_resolveSourceFillType(srcEntry)
        if fillType == nil then return end

        -- Verify destination accepts this fillType (right category + free space).
        if not self:_destAcceptsFillType(dstEntry, fillType) then
            if not session._loggedTypeMismatch then
                session._loggedTypeMismatch = true
            end
            return
        end

        local sourceLevel = 0
        if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or srcEntry.type == "FILL_UNIT_ONLY" then
            if srcEntry.vehicle ~= nil then
                sourceLevel = srcEntry.vehicle:getFillUnitFillLevel(srcEntry.fillUnitIndex) or 0
            end
        elseif srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            if srcEntry.storage ~= nil then
                sourceLevel = srcEntry.storage:getFillLevel(fillType) or 0
            end
        end
        if sourceLevel <= 0 then return end
        local freeCapacity = 0
        if dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or dstEntry.type == "FILL_UNIT_ONLY" then
            if dstEntry.vehicle ~= nil then
                local cap   = dstEntry.vehicle:getFillUnitCapacity(dstEntry.fillUnitIndex) or 0
                local level = dstEntry.vehicle:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0
                freeCapacity = cap - level
            end
        elseif dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            if dstEntry.storage ~= nil then
                freeCapacity = dstEntry.storage:getFreeCapacity(self:resolveStoreDepositFillType(dstEntry, fillType)) or 0
            end
        end
        if freeCapacity <= 0 then return end
        local rateBase = (state.direction == SPS_DIRECTION_DISCHARGE)
            and (session.baseEmptyLitersPerSecond or session.baseLitersPerSecond)
            or  (session.baseFillLitersPerSecond  or session.baseLitersPerSecond)
        local amount = math.min(rateBase * dt * 0.001, sourceLevel, freeCapacity)
        -- [SPS 1.0.1.5] Nothing to move (source empty or destination full) must
        -- return BEFORE the thickness gate below: the tooThick blinking warning
        -- sat after this min() but before any amount check, so a drained source
        -- could blink "add water" forever with zero litres in play.
        if amount <= 0 then return end
        -- Apply thickness slowdown based on what the SOURCE carries. A placeable
        -- store uses its apparent (DM) thickness; a tanker source uses the thickness
        -- it is carrying (state.thickness). Either way thick slurry slows the transfer
        -- and a jammed source (mult <= 0) stops it with the same warning.
        local mult = 1.0
        if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            mult = self:getFlowRateMultiplier(srcEntry)
        elseif (srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME
                or srcEntry.type == "FILL_UNIT_ONLY")
               and srcEntry.vehicle ~= nil then
            mult = self:thicknessToFlowMultiplier(self:getTankerThickness(srcEntry.vehicle))
        end
        if mult <= 0 then
            if self:_warningIsRelevant(vehicle) then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
            end
            return
        end
        amount = amount * mult
        if amount <= 0 then return end
        if SlurryPipeManager.DEBUG and session._lastConduitDir ~= state.direction then
            session._lastConduitDir = state.direction
            SlurryPipeManager.log("tickFlow[conduit]: %s dir=%s srcLevel=%.0f free=%.0f",
                tostring(vehicle.configFileName), tostring(state.direction), sourceLevel or 0, freeCapacity or 0)
        end
        self:removeFromSource(srcEntry, amount, fillType, vehicle)
        self:addToSource(dstEntry, amount, fillType, vehicle)
        session.totalTransferred = (session.totalTransferred or 0) + amount
        return
    end

    local isArmActive     = self:connectionIsFillArm(vehicle)
    local hasCouplingFlow = self:hasActiveCouplingConnection(vehicle)

    if not isArmActive and not hasCouplingFlow then
        fmBail("no_arm_no_coupling")
        return
    end
    session._fmBail = nil

    -- [SPS FM 1.0.1.7] Fill type / content are TANK-side facts: read from
    -- tankVehicle (the receiver for a front mount, the vehicle itself otherwise).
    local fillType = tankVehicle:getFillUnitFillType(session.vehicleFillUnit)
    if fillType == nil or fillType == FillType.UNKNOWN then
        -- [SPS] Tank is empty (UNKNOWN fill type). Do NOT assume LIQUIDMANURE — that
        -- silently blocks loading DIGESTATE (or any other type) into an empty tanker,
        -- because transferFill/removeFromSource then read the source's level for the
        -- wrong fill type and see 0. Resolve from what the connected source actually
        -- holds when filling; only fall back to LIQUIDMANURE if that can't be resolved.
        local resolvedEmptyFillType = nil
        if state.direction == SPS_DIRECTION_FILL then
            local extSrcForType = self:resolveExternalSource(vehicle)
            if extSrcForType ~= nil then
                resolvedEmptyFillType = self:_resolveSourceFillType(extSrcForType)
            end
        end
        fillType = resolvedEmptyFillType or FillType.LIQUIDMANURE
        if SlurryPipeManager.DEBUG and session._lastEmptyFillTypeResolved ~= fillType then
            session._lastEmptyFillTypeResolved = fillType
            SlurryPipeManager.log("tickFlow: empty tank %s resolved fillType=%s (from source)",
                tostring(vehicle.configFileName), tostring(fillType))
        end
    end
    
    -- If connected to water source via arm, override fillType to WATER
    if isArmActive and state.direction == SPS_DIRECTION_FILL then
        local extSrc = self:resolveExternalSource(vehicle)
        if extSrc ~= nil and extSrc.type == 3 then  -- SPSWaterPlaneManager.SOURCE_TYPE_WATER
            fillType = FillType.WATER
        end
    end

    local hasContent = (tankVehicle.getFillUnitFillLevel ~= nil
        and (tankVehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0) > 0)

    if isArmActive then
        -- Fill arm requires the cab hydraulic valve open. The effective flow is then
        -- resolved by the pressure model (resolveCouplingFlow): stored pressure/vacuum
        -- at/above minThreshold drives flow in its built direction, and a spent tank
        -- backflows out by gravity.
        if not state.valveOpen then
            fmBail("valve_closed")
            return
        end
        -- [SPS 1.0.1.8] Front mount: the whole arm session runs through the
        -- coupler-first cascade (SPSM_FrontMount.tickFrontMountArmCascade),
        -- which resolves its own flow direction, targets, rates, thickness
        -- and transfers. The legacy single-tank path below stays untouched
        -- for every other vehicle.
        if session.isFrontMount == true and session.fmTargets ~= nil then
            self:tickFrontMountArmCascade(session, state, pumpRunning, dt, fillType)
            return
        end
        local flowDir, scalar = self:resolveCouplingFlow(vehicle, state, pumpRunning, hasContent)
        if SlurryPipeManager.DEBUG and session._lastArmFlowDir ~= flowDir then
            session._lastArmFlowDir = flowDir
            SlurryPipeManager.log("tickFlow[arm]: %s flowDir=%s scalar=%.2f pump=%s",
                tostring(vehicle.configFileName), tostring(flowDir), scalar or 0, tostring(pumpRunning))
        end
        if flowDir == nil or scalar <= 0 then
            fmBail("no_flow_dir")
            return
        end
        session._fmBail = nil
        local rateBase = (flowDir == SPS_DIRECTION_FILL)
            and (session.baseFillLitersPerSecond or session.baseLitersPerSecond)
            or  (session.baseEmptyLitersPerSecond or session.baseLitersPerSecond)
        local rate = rateBase * dt * 0.001 * scalar
        rate = rate * self:getPipeLengthFalloff(vehicle)   -- 1.0 for a rigid arm
        if flowDir == SPS_DIRECTION_FILL then
            local extSrc = self:resolveExternalSource(vehicle)
            if extSrc ~= nil then
                local mult = self:getFlowRateMultiplier(extSrc)   -- source (store) thickness slows the suck
                if mult <= 0 then
                    if self:_warningIsRelevant(vehicle) then
                        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
                    end
                    return
                end
                rate = rate * mult
            end
            -- [SPS FM 1.0.1.7] Tank-side level reads and consistency blends on
            -- tankVehicle: the receiver's tank is what fills for a front mount.
            local oldLevel = tankVehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0
            self:transferFill(vehicle, session, rate, fillType)
            -- Inherit the source's thickness into the tank for whatever was added.
            local added = (tankVehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0) - oldLevel
            if added > 0 then
                self:applyFillThicknessBlend(tankVehicle, oldLevel, added, self:getSourceThickness(extSrc))
                self:applyFillCrustBlend(tankVehicle, oldLevel, added, self:getSourceCrust(extSrc))
            end
        else
            rate = rate * self:getTankerThicknessMultiplier(tankVehicle)   -- carried thickness slows the push-out
            self:transferDischarge(vehicle, session, rate, fillType)
        end
    else
        -- Pipe coupling. Resolve the effective flow from the pressure model first
        -- (stored pressure/vacuum at/above minThreshold drives flow in its built
        -- direction; a spent tank backflows out by gravity), then honour any partner
        -- coupling flow-direction restriction against that EFFECTIVE direction.
        local flowDir, scalar = self:resolveCouplingFlow(vehicle, state, pumpRunning, hasContent)
        if SlurryPipeManager.DEBUG and session._lastCplFlowDir ~= flowDir then
            session._lastCplFlowDir = flowDir
            SlurryPipeManager.log("tickFlow[coupling]: %s flowDir=%s scalar=%.2f pump=%s",
                tostring(vehicle.configFileName), tostring(flowDir), scalar or 0, tostring(pumpRunning))
        end
        if flowDir == nil or scalar <= 0 then return end

        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.vehicle == vehicle then
                for _, c in ipairs(vEntry.couplingEntries) do
                    if c.isConnected and c.connectedPartnerCoupling ~= nil then
                        -- Direct partner or chain terminus partner
                        local partner = c.connectedPartnerCoupling
                        local effectivePartner = partner
                        if partner.isChainTerminus and partner.chain ~= nil then
                            effectivePartner = partner.chain.anchorCoupling or partner
                        end
                        local partnerDir = effectivePartner.flowDirection
                        if partnerDir ~= nil and partnerDir ~= "BOTH" then
                            if partnerDir == "DISCHARGE" and flowDir == SPS_DIRECTION_FILL then
                                return
                            elseif partnerDir == "FILL" and flowDir == SPS_DIRECTION_DISCHARGE then
                                return
                            end
                        end
                    end
                end
                break
            end
        end

        local rateBase = (flowDir == SPS_DIRECTION_FILL)
            and (session.baseFillLitersPerSecond or session.baseLitersPerSecond)
            or  (session.baseEmptyLitersPerSecond or session.baseLitersPerSecond)
        local rate = rateBase * dt * 0.001 * scalar
        rate = rate * self:getPipeLengthFalloff(vehicle)   -- strap pipe stretch falloff
        if flowDir == SPS_DIRECTION_FILL then
            local extSrc = self:resolveExternalSource(vehicle)
            -- [SPS 1.0.0.9.26] Buying-station source: handled whole here and
            -- returned BEFORE the store thickness/crust helpers below, which
            -- only know FILL_VOLUME / STORAGE_PLANE sources. The vanilla
            -- BuyingStation does fill + per-litre charge + money HUD in one
            -- server call — see transferFillFromBuyingStation.
            if extSrc ~= nil and extSrc.type == SPS_SOURCE_TYPE_BUYING_STATION then
                self:transferFillFromBuyingStation(vehicle, session, rate, fillType, extSrc)
                return
            end
            if extSrc ~= nil then
                local mult = self:getFlowRateMultiplier(extSrc)   -- source (store) thickness slows the suck
                if mult <= 0 then
                    if self:_warningIsRelevant(vehicle) then
                        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
                    end
                    return
                end
                rate = rate * mult
            end
            -- [SPS FM 1.0.1.7] Tank-side level reads and consistency blends on
            -- tankVehicle: the receiver's tank is what fills for a front mount.
            local oldLevel = tankVehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0
            self:transferFill(vehicle, session, rate, fillType)
            local added = (tankVehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0) - oldLevel
            if added > 0 then
                self:applyFillThicknessBlend(tankVehicle, oldLevel, added, self:getSourceThickness(extSrc))
                self:applyFillCrustBlend(tankVehicle, oldLevel, added, self:getSourceCrust(extSrc))
            end
        else
            rate = rate * self:getTankerThicknessMultiplier(tankVehicle)   -- carried thickness slows the push-out
            self:transferDischarge(vehicle, session, rate, fillType)
        end
    end
end

-- Flow falloff over the length of a connected strap pipe: full rate when the couplers
-- are close, dropping linearly to a floor as the live distance approaches maxPipeLength.
-- Returns 1.0 for a fill arm (rigid, no pipe) or when no connected coupling is found.
-- Direct coupling connections only; chain falloff (summed segments) is a later addition.
function SlurryPipeManager:getPipeLengthFalloff(vehicle)
    if not self:isFeatureEnabled("lengthFalloff") then return 1.0 end
    if self:connectionIsFillArm(vehicle) then return 1.0 end
    for _, vEntry in ipairs(self.registeredVehicles) do
        if vEntry.vehicle == vehicle then
            for _, c in ipairs(vEntry.couplingEntries) do
                if c.isConnected and c.valveOpen
                and c.mountNode ~= nil
                and c.connectedPartnerCoupling ~= nil
                and c.connectedPartnerCoupling.mountNode ~= nil then
                    local ax, ay, az = getWorldTranslation(c.mountNode)
                    local bx, by, bz = getWorldTranslation(c.connectedPartnerCoupling.mountNode)
                    local dist   = MathUtil.vector3Length(ax - bx, ay - by, az - bz)
                    local maxLen = c.maxPipeLength or 6.0
                    if maxLen <= 0 then return 1.0 end
                    local floor = SlurryPipeManager.DEFAULT_LENGTH_FALLOFF_FLOOR
                    local frac  = math.min(1.0, math.max(0.0, dist / maxLen))
                    return math.max(floor, 1.0 - (1.0 - floor) * frac)
                end
            end
            break
        end
    end
    return 1.0
end

-- ---------------------------------------------------------------------------
-- Transfer functions (existing)
-- ---------------------------------------------------------------------------

-- Returns the fillType currently held by a sourceEntry, or nil if empty.
-- [SPS 1.0.0.9.19] Pumpable-liquid gate for UNRESTRICTED store fillType
-- resolution. Field report (UKStyle cow shed): a husbandry Storage is a
-- single multi-type object holding STRAW alongside LIQUIDMANURE. The
-- unrestricted first-non-zero pairs() walk below could therefore select
-- STRAW as the draw type — pairs() iteration order over a hash table is
-- machine/session dependent AND can flip mid-session when a deposit adds a
-- new fillType key (table rehash), which is why one player drained straw
-- (both gauges falling together as the order alternated) while the author
-- could not reproduce. Only these liquids may ever be selected by an
-- unrestricted walk; per-coupler restrictFillType (BGA) is unaffected.
function SlurryPipeManager:_isPumpableSourceFillType(ft)
    if ft == nil then return false end
    if self._pumpableSourceFillTypes == nil then
        self._pumpableSourceFillTypes = {
            [FillType.LIQUIDMANURE] = true,
            [FillType.DIGESTATE]    = true,
            [FillType.WATER]        = true,
        }
    end
    return self._pumpableSourceFillTypes[ft] == true
end

-- For vehicle fill units → reads the vehicle's runtime fill type.
-- For storage planes → walks the storage's fillType list and returns the
-- first type with level > 0 (multi-type storages are rare; in practice
-- one type at a time).
function SlurryPipeManager:_resolveSourceFillType(srcEntry)
    if srcEntry == nil then return nil end
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or srcEntry.type == "FILL_UNIT_ONLY" then
        if srcEntry.vehicle == nil then return nil end
        local ft = srcEntry.vehicle:getFillUnitFillType(srcEntry.fillUnitIndex)
        if ft == nil or ft == FillType.UNKNOWN then return nil end
        local level = srcEntry.vehicle:getFillUnitFillLevel(srcEntry.fillUnitIndex) or 0
        if level <= 0 then return nil end
        return ft
    elseif srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if srcEntry.storage == nil or srcEntry.storage.fillTypes == nil then return nil end
        -- [SPS] This draw is going through a specific coupler that declares its own
        -- fillType (e.g. BGA500's LIQUIDMANURE-only coupler). Only offer that exact
        -- type from the shared store — do not fall back to whatever else it holds.
        if srcEntry.restrictFillType ~= nil then
            local lvl = srcEntry.storage:getFillLevel(srcEntry.restrictFillType) or 0
            if lvl > 0 then return srcEntry.restrictFillType end
            return nil
        end
        -- [SPS 1.0.0.9.19] Unrestricted draw: prefer the fillPlane-declared type
        -- (srcEntry.fillType, set by SlurryNodeUtil.buildStoragePlaneSource from
        -- fillPlane#fillType — every shipped config declares it) before any walk,
        -- so a barn whose storage also holds STRAW deterministically offers
        -- LIQUIDMANURE. Deposit behaviour is untouched — water/digestate IN
        -- still convert via resolveStoreDepositFillType.
        local declared = srcEntry.fillType
        if declared ~= nil then
            local declaredLvl = srcEntry.storage:getFillLevel(declared) or 0
            if declaredLvl > 0 then return declared end
        end
        for ft, _ in pairs(srcEntry.storage.fillTypes) do
            local lvl = srcEntry.storage:getFillLevel(ft) or 0
            -- [SPS 1.0.0.9.19] Walk may only ever select a pumpable liquid.
            if lvl > 0 and self:_isPumpableSourceFillType(ft) then return ft end
        end
        return nil
    elseif srcEntry.type == SPS_SOURCE_TYPE_BUYING_STATION then
        -- [SPS 1.0.0.9.26] Infinite source, no level walk: offer the
        -- coupler-restricted type, else the config-declared type — provided the
        -- station actually sells it. [SPS 1.0.0.9.28] Sold set now includes
        -- SPS-extra types (e.g. WATER) via buyStationSellsFillType.
        local want = srcEntry.restrictFillType or srcEntry.fillType
        if want ~= nil and self:buyStationSellsFillType(srcEntry, want) then return want end
        return nil
    end
    return nil
end

-- Returns true if the destination entry can accept the given fillType right now
-- (has free capacity for that specific type).
function SlurryPipeManager:_destAcceptsFillType(dstEntry, fillType)
    if dstEntry == nil or fillType == nil then return false end
    -- [SPS] This deposit is going through a specific coupler that declares its own
    -- fillType — reject anything else even if the shared store would otherwise take it.
    if dstEntry.restrictFillType ~= nil and fillType ~= dstEntry.restrictFillType then return false end
    if dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or dstEntry.type == "FILL_UNIT_ONLY" then
        if dstEntry.vehicle == nil then return false end
        if dstEntry.vehicle.getFillUnitAllowsFillType ~= nil then
            if not dstEntry.vehicle:getFillUnitAllowsFillType(dstEntry.fillUnitIndex, fillType) then return false end
        end
        local cap   = dstEntry.vehicle:getFillUnitCapacity(dstEntry.fillUnitIndex) or 0
        local level = dstEntry.vehicle:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0
        return (cap - level) > 0
    elseif dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if dstEntry.storage == nil then return false end
        -- [SPS] A store converts an unsupported incoming type (e.g. WATER) to its
        -- content/native type on deposit (resolveStoreDepositFillType). Query free
        -- capacity for that RESOLVED deposit type, not the raw incoming type, so a
        -- water push through the conduit (PTO) pump is not falsely rejected here —
        -- mirrors the freeCapacity calc in tickFlow[conduit] and transferDischarge,
        -- which already convert before calling getFreeCapacity. Without this, a
        -- slurry store returns 0 free capacity for WATER and the conduit bails every
        -- tick, even though the fill-arm / bez-pipe paths accept water fine.
        local depositType = self:resolveStoreDepositFillType(dstEntry, fillType)
        local free = dstEntry.storage:getFreeCapacity(depositType) or 0
        return free > 0
    elseif dstEntry.type == SPS_SOURCE_TYPE_BUYING_STATION then
        -- [SPS 1.0.0.9.26] FILL-only source — never accepts a deposit.
        return false
    end
    return false
end

function SlurryPipeManager:transferFill(vehicle, session, delta, fillType)
    local extSource = self:resolveExternalSource(vehicle)
    if extSource == nil then return end

    -- [SPS 1.0.0.9.26] Buying-station source routed to its own transfer path
    -- (defensive — tickFlow already branches before reaching here; any other
    -- caller resolving a buy-station source gets the correct paid fill too).
    if extSource.type == SPS_SOURCE_TYPE_BUYING_STATION then
        self:transferFillFromBuyingStation(vehicle, session, delta, fillType, extSource)
        return
    end
    
    -- Force fillType to WATER when filling from water source
    if extSource.type == 3 then
        fillType = FillType.WATER
    end

    local sourceLevel = 0
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extSource.type == "FILL_UNIT_ONLY" then
        if extSource.vehicle ~= nil then
            sourceLevel = extSource.vehicle:getFillUnitFillLevel(extSource.fillUnitIndex) or 0
        end
    elseif extSource.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if extSource.storage ~= nil then
            -- [SPS] Honour a per-coupler fillType restriction: this draw is going
            -- through a coupler that only permits its declared type. Force that type
            -- so the store level is read for it (and it is what gets added), no matter
            -- what the tanker previously held. A wrong-type load is then blocked
            -- naturally: if the store holds none of the restricted type, sourceLevel is
            -- 0 and nothing transfers; if the tank already holds a different type,
            -- addFillUnitFillLevel rejects the mismatched add. Mirrors the sprayer
            -- side (tickSprayerFlow). Untagged couplers (restrictFillType nil) are
            -- unchanged.
            if extSource.restrictFillType ~= nil then
                fillType = extSource.restrictFillType
            end
            sourceLevel = extSource.storage:getFillLevel(fillType) or 0
        end
    elseif extSource.type == 3 then  -- Water source (infinite)
        sourceLevel = 999999  -- Infinite water source
    end

    if sourceLevel <= 0 then return end

    delta = math.min(delta, sourceLevel)

    -- [SPS FM 1.0.1.7] The add lands on the session's tank vehicle: the
    -- hose-connected receiver for a front mount, the session vehicle otherwise.
    -- The external (arm/pipe) side above stays resolved against `vehicle`.
    local tank = session.tankVehicle or vehicle
    local applied = tank:addFillUnitFillLevel(tank:getOwnerFarmId(), session.vehicleFillUnit, delta, fillType, ToolType.TRIGGER, nil)
    if applied <= 0 then return end
    self:removeFromSource(extSource, applied, fillType, vehicle)
end

function SlurryPipeManager:transferDischarge(vehicle, session, delta, fillType)
    local extDest = self:resolveExternalSource(vehicle)
    if extDest == nil then return end

    -- [SPS] Honour a per-coupler fillType restriction on discharge: a coupler that
    -- declares its own type only accepts that exact type. If the tanker is pushing a
    -- different fillType, deny the transfer (mirrors the sprayer side's held-type
    -- check in tickSprayerFlow). Untagged couplers (restrictFillType nil) are
    -- unchanged. Water is exempt (a store converts incoming water to its content type
    -- via resolveStoreDepositFillType, so a water push is never a wrong-type deposit).
    if extDest.restrictFillType ~= nil
    and fillType ~= extDest.restrictFillType
    and fillType ~= FillType.WATER then
        if not session._loggedDischargeFillTypeBlock then
            session._loggedDischargeFillTypeBlock = true
            SlurryPipeManager.log("transferDischarge: coupler only permits fillType=%s; tanker holds fillType=%s — discharge denied",
                tostring(extDest.restrictFillType), tostring(fillType))
        end
        return
    end
    session._loggedDischargeFillTypeBlock = nil

    local freeCapacity = 0
    if extDest.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extDest.type == "FILL_UNIT_ONLY" then
        if extDest.vehicle ~= nil then
            local cap   = extDest.vehicle:getFillUnitCapacity(extDest.fillUnitIndex) or 0
            local level = extDest.vehicle:getFillUnitFillLevel(extDest.fillUnitIndex) or 0
            freeCapacity = cap - level
        end
    elseif extDest.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if extDest.storage ~= nil then
            freeCapacity = extDest.storage:getFreeCapacity(self:resolveStoreDepositFillType(extDest, fillType)) or 0
        end
    elseif extDest.type == 3 then  -- Water source (infinite capacity)
        freeCapacity = 999999  -- Infinite capacity
    end

    if freeCapacity <= 0 then return end

    delta = math.min(delta, freeCapacity)

    -- [SPS FM 1.0.1.7] The draw comes from the session's tank vehicle: the
    -- hose-connected receiver for a front mount, the session vehicle otherwise.
    -- The external (arm/pipe) side above stays resolved against `vehicle`.
    local tank = session.tankVehicle or vehicle
    local applied = tank:addFillUnitFillLevel(tank:getOwnerFarmId(), session.vehicleFillUnit, -delta, fillType, ToolType.TRIGGER, nil)
    if applied >= 0 then return end
    self:addToSource(extDest, math.abs(applied), fillType, vehicle)
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.26] Buying-station fill
-- ---------------------------------------------------------------------------
-- Fill a tanker from a buying-station placeable (vanilla placeable type
-- "buyingStation" — PlaceableBuyingStation.lua / BuyingStation.lua, verified
-- source). The station is an infinite PAID source:
-- BuyingStation:addFillLevelToFillableObject performs the whole purchase
-- server-side — farm money gate (getMoney > 0), addFillUnitFillLevel, the
-- per-litre charge at getEffectiveFillTypePrice (priceScale x
-- fillType.pricePerLiter x economy multiplier) via g_currentMission:addMoney,
-- and the delayed money-change HUD. SPS reimplements NONE of it.
--   * Rate is the tanker's own SPS fill LPS (already pressure-scaled and
--     pipe-length-faded by the tickFlow caller); the station's own
--     fillLitersPerSecond is deliberately ignored.
--   * No source decrement exists (infinite supply) — removeFromSource has a
--     matching no-op branch.
--   * applied <= 0 means the farm is broke or the fill unit rejected the add:
--     treated as stalled flow (pump stays on), same as a drained store.
--   * Server-only by construction: tickFlow sits behind the g_server guard in
--     SlurryPipeManager:update, matching LoadTrigger:update's isServer gate
--     around the same vanilla call.
function SlurryPipeManager:transferFillFromBuyingStation(vehicle, session, delta, fillType, extSource)
    if delta == nil or delta <= 0 then return end
    local station = extSource ~= nil and extSource.station or nil
    if station == nil then return end
    -- Per-coupler fillType restriction wins (separate LIQUIDMANURE / DIGESTATE
    -- couplers on one station); an empty tanker falls back to the
    -- config-declared station type. A part-full tanker keeps its held type.
    if extSource.restrictFillType ~= nil then
        fillType = extSource.restrictFillType
    elseif fillType == nil or fillType == FillType.UNKNOWN then
        fillType = extSource.fillType
    end
    -- The station must actually sell this type: vanilla-provided
    -- (BuyingStation.providedFillTypes) or SPS-extra (bundled config).
    local sold, isExtra = self:buyStationSellsFillType(extSource, fillType)
    if fillType == nil or not sold then
        if not session._loggedBuyStationTypeBlock then
            session._loggedBuyStationTypeBlock = true
            SlurryPipeManager.log("transferFillFromBuyingStation: station does not provide fillType=%s — fill denied",
                tostring(fillType))
        end
        return
    end
    session._loggedBuyStationTypeBlock = nil
    -- [SPS FM 1.0.1.7] Purchases land on the session's tank vehicle: the
    -- hose-connected receiver for a front mount, the session vehicle otherwise.
    -- The receiver's farm pays, matching whose tank fills.
    local tank = session.tankVehicle or vehicle
    local oldLevel = tank:getFillUnitFillLevel(session.vehicleFillUnit) or 0
    local applied
    if isExtra then
        -- [SPS 1.0.0.9.28] SPS-side purchase for a type the vanilla station does
        -- NOT declare (its getEffectiveFillTypePrice would index a nil
        -- priceScale — verified source — so the vanilla call must not be used).
        -- Mirrors BuyingStation:addFillLevelToFillableObject byte-for-byte in
        -- behaviour: farm money gate (>0), fill, then charge at
        -- priceScale x fillType.pricePerLiter x EconomyManager.getPriceMultiplier
        -- via g_currentMission:addMoney with the station's own moneyChangeType.
        -- priceScale 0 in the config = free (no addMoney call).
        local farmId = tank:getOwnerFarmId()
        if not (0 < g_currentMission:getMoney(farmId)) then
            applied = 0
        else
            applied = tank:addFillUnitFillLevel(farmId, session.vehicleFillUnit,
                delta, fillType, ToolType.TRIGGER, nil)
            if applied ~= nil and applied > 0 then
                local scale        = extSource.extraPriceScales[fillType] or 1.0
                local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillType)
                local pricePerLiter = scale * (fillTypeDesc ~= nil and fillTypeDesc.pricePerLiter or 0)
                    * EconomyManager.getPriceMultiplier(fillType)
                local price = pricePerLiter * applied
                if price > 0 and extSource.station ~= nil then
                    g_currentMission:addMoney(-price, farmId, extSource.station.moneyChangeType, true)
                end
            end
        end
    else
        applied = station:addFillLevelToFillableObject(tank, session.vehicleFillUnit,
            fillType, delta, nil, ToolType.TRIGGER)
    end
    if applied == nil or applied <= 0 then
        -- Farm out of money (vanilla gate) or fill unit refused — stalled flow.
        if SlurryPipeManager.DEBUG and session._lastBuyStationStall ~= true then
            session._lastBuyStationStall = true
            SlurryPipeManager.log("transferFillFromBuyingStation: %s applied=0 (no money or fill rejected)",
                tostring(vehicle.configFileName))
        end
        return
    end
    session._lastBuyStationStall = nil
    -- Optional authored consistency for bought slurry: blends run ONLY when the
    -- bundled config declares values; undeclared leaves the tank's blended
    -- average untouched. [SPS 1.0.0.9.28] Exception: a WATER fill always blends
    -- thickness/crust toward 0 — water dilutes, mirroring the store-side rule
    -- ("water adds volume but no dry matter").
    if fillType == FillType.WATER then
        if self.applyFillThicknessBlend ~= nil then
            self:applyFillThicknessBlend(tank, oldLevel, applied, 0)
        end
        if self.applyFillCrustBlend ~= nil then
            self:applyFillCrustBlend(tank, oldLevel, applied, 0)
        end
    else
        if extSource.thickness ~= nil and self.applyFillThicknessBlend ~= nil then
            self:applyFillThicknessBlend(tank, oldLevel, applied, extSource.thickness)
        end
        if extSource.crust ~= nil and self.applyFillCrustBlend ~= nil then
            self:applyFillCrustBlend(tank, oldLevel, applied, extSource.crust)
        end
    end
    session.totalTransferred = (session.totalTransferred or 0) + applied
end

-- ---------------------------------------------------------------------------
-- Source resolution
-- ---------------------------------------------------------------------------
function SlurryPipeManager:resolveVehicleSource(vehicle)
    -- -----------------------------------------------------------------------
    -- [SPS FM 1.0.1.6] Front-mount pass-through substitution. A front mount
    -- (entry.frontMount ~= nil) never has a tank of its own — its capacity-0
    -- fill unit exists only to satisfy vanilla. Its tank-side endpoint is
    -- ALWAYS the hose-connected receiver resolved by SPSM_FrontMount
    -- (updateFrontMounts refreshes the cache every tick on all peers).
    --
    -- Every flow path — arm sessions, coupling sessions, equalise, chain
    -- resolution via resolveSourceForCouplingPartner — funnels through this
    -- function per evaluation, so this one substitution routes them all and a
    -- receiver detached mid-flow returns nil on the next evaluation: flow
    -- stops, pump keeps running (universal rule).
    --
    -- No receiver -> nil: pump on + valve open moves nothing because the
    -- liquid has nowhere to go. (Mode C, arm<->coupler bridging with no
    -- receiver, is a later phase and does not pass through here.)
    --
    -- A receiver that is itself a front mount is a config error, not a
    -- supported topology — refuse it rather than recurse.
    -- -----------------------------------------------------------------------
    do
        local fmEntry = self:getVehicleEntry(vehicle)
        if fmEntry ~= nil and fmEntry.frontMount ~= nil then
            local receiver = fmEntry.frontMount.receiver
            if receiver ~= nil and receiver ~= vehicle then
                local rEntry = self:getVehicleEntry(receiver)
                if rEntry ~= nil and rEntry.frontMount == nil then
                    return self:resolveVehicleSource(receiver)
                end
            end
            return nil
        end
    end

    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            if entry.sourceEntry == nil then
                local fillUnitIndex = 1
                if #entry.armEntries > 0 then
                    fillUnitIndex = entry.armEntries[1].fillUnitIndex
                end

                local sourceEntry = nil

                if vehicle.spec_fillVolume ~= nil then
                    sourceEntry = SlurryNodeUtil.buildFillVolumeSource(vehicle, fillUnitIndex)
                end

                if sourceEntry == nil and vehicle.spec_fillUnit ~= nil and vehicle.addFillUnitFillLevel ~= nil then
                    local fillUnit = vehicle.spec_fillUnit.fillUnits ~= nil and vehicle.spec_fillUnit.fillUnits[fillUnitIndex] or nil
                    if fillUnit ~= nil then
                        sourceEntry = {
                            type          = "FILL_UNIT_ONLY",
                            vehicle       = vehicle,
                            fillUnitIndex = fillUnitIndex,
                        }
--                        print("[SPS] resolveVehicleSource FALLBACK FILL_UNIT_ONLY: " .. tostring(vehicle.configFileName))
                    end
                end

                if sourceEntry ~= nil then
                    entry.sourceEntry = sourceEntry
                    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
                        table.insert(self.sourceEntries, sourceEntry)
                    end
                else
                    if not entry.sourceResolvePrinted then
                        entry.sourceResolvePrinted = true
                    end
                end

                -- One-shot diagnostic: why FILL_VOLUME was or was not built. A tanker
                -- that resolves to FILL_UNIT_ONLY has no engine fill plane, so head
                -- equalisation cannot read a surface from it.
                if SlurryPipeManager.DEBUG and not entry._srcResolveLogged then
                    entry._srcResolveLogged = true
                    local spec = vehicle.spec_fillVolume
                    local nVol = (spec ~= nil and spec.volumes ~= nil) and #spec.volumes or -1
                    local nMap = 0
                    if spec ~= nil and spec.fillUnitFillVolumeMapping ~= nil then
                        for _ in pairs(spec.fillUnitFillVolumeMapping) do nMap = nMap + 1 end
                    end
                    SlurryPipeManager.log("resolveVehicleSource: %s fui=%d hasFillVolumeSpec=%s volumes=%d mappings=%d -> type=%s",
                        tostring(vehicle.configFileName), fillUnitIndex, tostring(spec ~= nil),
                        nVol, nMap, tostring(sourceEntry and sourceEntry.type))
                end
            end
            return entry.sourceEntry
        end
    end
    return nil
end

function SlurryPipeManager:resolveExternalSource(vehicle)
    local entry = nil
    for _, e in ipairs(self.registeredVehicles) do if e.vehicle == vehicle then entry = e break end end
    if entry == nil then return nil end

    -- Fill arm path
    for _, arm in ipairs(entry.armEntries) do
        if arm.isConnected then
            if arm.connectedBootPort ~= nil then
                if arm.connectedBootPort.isChain and arm.connectedBootPort.chain ~= nil then
                    local chain  = arm.connectedBootPort.chain
                    local anchor = chain.anchorCoupling
                    -- Preferred: the anchor coupling's own sourceEntry.
                    if anchor ~= nil and anchor.sourceEntry ~= nil then
                        return anchor.sourceEntry
                    end
                    -- [SPS DS] Fallback: anchor.sourceEntry can be nil when a chain was
                    -- re-anchored onto a vehicle coupling whose source was not populated
                    -- at registration. Resolve from the anchor's OWNER the same way the
                    -- non-chain boot-port branch does, so a docking-station draw reaches
                    -- the anchored tanker's (or store's) tank regardless. resolveVehicleSource
                    -- rebuilds the fill-volume source on demand.
                    if anchor ~= nil then
                        local ownerVehicle, ownerPlaceable = self:_findCouplingOwner(anchor)
                        if ownerVehicle ~= nil then
                            local vsrc = self:resolveVehicleSource(ownerVehicle)
                            if vsrc ~= nil then return vsrc end
                        elseif ownerPlaceable ~= nil then
                            for _, pEntry in ipairs(self.registeredPlaceables) do
                                if pEntry.placeable == ownerPlaceable and pEntry.sourceEntry ~= nil then
                                    return pEntry.sourceEntry
                                end
                            end
                        end
                    end
                else
                    return self:resolveVehicleSource(arm.connectedBootPort.vehicle)
                end
            end
            if arm.connectedSource ~= nil then return arm.connectedSource end
        end
    end

    -- Coupling path (pipe connected and valve open)
    for _, coupling in ipairs(entry.couplingEntries) do
        if coupling.isConnected and coupling.valveOpen then
            local partner = coupling.connectedPartnerCoupling
            if partner ~= nil and partner.isChainTerminus then
                if partner.isChainStart then
                    -- Vehicle-anchored chain: the near-end sourceEntry is the vehicle's own fill
                    -- volume — wrong for external source resolution. Traverse to the far end of
                    -- the chain and return whatever the last chainCoupling is connected to.
                    local chain = partner.chain
                    if chain ~= nil and #chain.segments > 0 then
                        local farCoupling = chain.segments[#chain.segments].chainCoupling
                        if farCoupling ~= nil then
                            -- Check if far end is connected to something
                            if farCoupling.connectedPartnerCoupling ~= nil then
                                local farPartner = farCoupling.connectedPartnerCoupling
                                for _, pEntry in ipairs(self.registeredPlaceables) do
                                    if pEntry.storeCouplings ~= nil then
                                        for _, sc in ipairs(pEntry.storeCouplings) do
                                            if sc == farPartner then return self:_restrictSourceToCoupling(pEntry.sourceEntry, sc) end
                                        end
                                    end
                                end
                                for _, vEntry in ipairs(self.registeredVehicles) do
                                    for _, vc in ipairs(vEntry.couplingEntries) do
                                        if vc == farPartner then
                                            return self:resolveVehicleSource(vEntry.vehicle)
                                        end
                                    end
                                end
                            else
                                -- Far end not connected to anything - check if it's in water
                                if farCoupling.mountNode ~= nil and entityExists(farCoupling.mountNode) then
                                    local fx, fy, fz = getWorldTranslation(farCoupling.mountNode)
                                    if g_waterPlaneManager ~= nil then
                                        local waterPlane = g_waterPlaneManager:findWaterPlaneAtPosition(fx, fz)
                                        if waterPlane ~= nil then
                                            return {
                                                type = 3,
                                                storage = waterPlane,
                                                waterPlane = waterPlane
                                            }
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                if not partner.isChainStart and partner.chain ~= nil
                   and partner.chain.anchorCoupling ~= nil then
                    -- END terminus of a vehicle-anchored chain: the far end is the
                    -- chain's anchor coupling (what the START terminus is bonded to).
                    -- partner.sourceEntry is nil for a tanker-anchored chain's free
                    -- end, so without this the tanker bonded here (e.g. the pump-side
                    -- vac) resolves NO source/sink and cannot pump. Mirror of the
                    -- isChainStart walk above. Store-anchored chains resolve the same
                    -- store source they did via partner.sourceEntry, just one step
                    -- earlier.
                    local anchor = partner.chain.anchorCoupling
                    for _, pEntry in ipairs(self.registeredPlaceables) do
                        if pEntry.storeCouplings ~= nil then
                            for _, sc in ipairs(pEntry.storeCouplings) do
                                if sc == anchor then return self:_restrictSourceToCoupling(pEntry.sourceEntry, sc) end
                            end
                        end
                    end
                    for _, vEntry in ipairs(self.registeredVehicles) do
                        for _, vc in ipairs(vEntry.couplingEntries) do
                            if vc == anchor then
                                if partner._lastExtLog ~= "endvehicle" then
                                    partner._lastExtLog = "endvehicle"
                                    SlurryPipeManager.logMP(string.format("[SPS MP] resolveExternalSource(END terminus id=%s) -> anchor vehicle %s",
                                        tostring(partner.id), tostring(vEntry.vehicle and vEntry.vehicle.configFileName)))
                                end
                                return self:resolveVehicleSource(vEntry.vehicle)
                            end
                        end
                    end
                end
                if partner.sourceEntry ~= nil then return self:_restrictSourceToCoupling(partner.sourceEntry, partner) end
            end
            if coupling.connectedTarget ~= nil then
                local target = coupling.connectedTarget
                -- [SPS] Restrict the shared store source by the specific store coupler
                -- this tanker coupling is bonded to, so a coupler declaring #fillType
                -- only draws its own type (e.g. BGA500 LIQUIDMANURE vs DIGESTATE ports
                -- on one shared storage). Every other branch in this resolver already
                -- wraps with _restrictSourceToCoupling; this direct (non-chain) branch
                -- was the one spot returning the raw source, so the coupler tag was
                -- ignored and any type loaded. connectedPartnerCoupling is set on a
                -- direct connect (see connectCouplings). Partner nil / untagged =>
                -- unrestricted, unchanged legacy behaviour.
                local partner = coupling.connectedPartnerCoupling
                for _, pEntry in ipairs(self.registeredPlaceables) do
                    if pEntry.placeable == target then
                        return self:_restrictSourceToCoupling(pEntry.sourceEntry, partner)
                    end
                end
                for _, vEntry in ipairs(self.registeredVehicles) do
                    if vEntry.vehicle == target then return self:resolveVehicleSource(vEntry.vehicle) end
                end
            end
        end
    end
    
    -- Check strap pipe free end for water (before declaring no source found)
    for _, coupling in ipairs(entry.couplingEntries) do
        if coupling.pipeId ~= nil and coupling.valveOpen then
            local pipeData = self.activePipes[coupling.pipeId]
            if pipeData ~= nil then
                -- Determine which end is the free end
                local freeEndCoupling = nil
                
                -- Check if coupling A is from this vehicle
                local aIsThisVehicle = false
                for _, vEntry in ipairs(self.registeredVehicles) do
                    if vEntry.vehicle == vehicle then
                        for _, vc in ipairs(vEntry.couplingEntries) do
                            if vc == pipeData.couplingA then
                                aIsThisVehicle = true
                                break
                            end
                        end
                        break
                    end
                end
                
                -- If A is this vehicle's coupling, then B is the free end
                if aIsThisVehicle then
                    freeEndCoupling = pipeData.couplingB
                else
                    freeEndCoupling = pipeData.couplingA
                end
                
                -- Check if free end is in water
                if freeEndCoupling ~= nil then
                    if freeEndCoupling.mountNode ~= nil and entityExists(freeEndCoupling.mountNode) then
                        local fx, fy, fz = getWorldTranslation(freeEndCoupling.mountNode)
                        
                        if g_waterPlaneManager ~= nil then
                            local waterPlane = g_waterPlaneManager:findWaterPlaneAtPosition(fx, fz)
                            if waterPlane ~= nil then
                                return {
                                    type = 3,
                                    storage = waterPlane,
                                    waterPlane = waterPlane
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- No source found - this is normal when pump runs without valid connection
    return nil
end

function SlurryPipeManager:removeFromSource(sourceEntry, amount, fillType, farmVehicle)
    if sourceEntry == nil then return end
    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or sourceEntry.type == "FILL_UNIT_ONLY" then
        local srcVehicle = sourceEntry.vehicle
        if srcVehicle ~= nil and srcVehicle.addFillUnitFillLevel ~= nil then
            local fui    = sourceEntry.fillUnitIndex
            local applied = srcVehicle:addFillUnitFillLevel(srcVehicle:getOwnerFarmId(), fui, -amount, fillType, ToolType.TRIGGER, nil)

            -- BYPASS PATH (mirrors addToSource): vanilla returned 0 but the unit
            -- actually has the requested fillType at a level we can draw from. The
            -- shadowed getFillUnitSupportsToolType blocks both add and remove. Fall
            -- back to direct mutation when the vanilla path silently fails.
            if amount > 0 and (applied == nil or applied == 0)
            and srcVehicle.spec_fillUnit ~= nil
            and srcVehicle.spec_fillUnit.fillUnits ~= nil then
                local spec = srcVehicle.spec_fillUnit
                local fu   = spec.fillUnits[fui]
                if fu ~= nil and (fu.fillLevel or 0) > 0 and fu.fillType == fillType then
                    local oldFillLevel = fu.fillLevel
                    fu.fillLevel = math.max(0, oldFillLevel - amount)
                    local delta = fu.fillLevel - oldFillLevel  -- negative
                    if fu.fillLevel <= 0 then
                        -- Unit emptied: clear fillType per vanilla convention (line 1218-1228)
                        if SpecializationUtil ~= nil and SpecializationUtil.raiseEvent ~= nil then
                            SpecializationUtil.raiseEvent(srcVehicle, "onChangedFillType", fui, FillType.UNKNOWN, fu.fillType)
                        end
                        fu.fillType = FillType.UNKNOWN
                        -- Same root-vehicle state change as the fill side, so cab specs refresh
                        if srcVehicle.rootVehicle ~= nil and srcVehicle.rootVehicle.raiseStateChange ~= nil
                        and VehicleStateChange ~= nil and VehicleStateChange.FILLTYPE_CHANGE ~= nil then
                            srcVehicle.rootVehicle:raiseStateChange(VehicleStateChange.FILLTYPE_CHANGE)
                        end
                    end
                    spec.isInfoDirty = true
                    if srcVehicle.isServer and spec.dirtyFlag ~= nil and srcVehicle.raiseDirtyFlags ~= nil then
                        srcVehicle:raiseDirtyFlags(spec.dirtyFlag)
                    end
                    if SpecializationUtil ~= nil and SpecializationUtil.raiseEvent ~= nil then
                        SpecializationUtil.raiseEvent(srcVehicle, "onFillUnitFillLevelChanged",
                            fui, -amount, fillType, ToolType.TRIGGER, nil, delta)
                    end
                    if not srcVehicle._spsBypassRemoveLogged then
                        srcVehicle._spsBypassRemoveLogged = true
                    end
                end
            end
        end
    elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        local storage = sourceEntry.storage
        if storage ~= nil then
            local oldLevel = storage:getFillLevel(fillType) or 0
            local removed  = math.min(amount, oldLevel)
            -- Preferential-liquid draw: when pumping slurry out, more of what leaves is
            -- liquid than its plain share, so the dry matter left behind concentrates.
            -- As liquid runs low the draw is forced to be solids and DM races up, until
            -- the store jams (>=90% gauge) and the only fix is adding water.
            if sourceEntry.thickeningEnabled and removed > 0 and fillType ~= FillType.WATER then
                self:_ensureStorePools(sourceEntry)
                local total  = self:_getStoreTotalFill(sourceEntry)   -- slurry+digestate pile
                local solids = sourceEntry.solids or 0
                local liquid = math.max(0, total - solids)
                local dm     = total > 0 and (solids / total) or 0
                -- [SPS 1.0.0.10.4] Preferential-liquid draw re-derived onto the SOLIDS share.
                --
                -- Previous form:
                --   liquidOut = min(removed * (1 - dm) * DM_REMOVAL_LIQUID_BIAS, liquid, removed)
                --   solidsOut = min(removed - liquidOut, solids)
                --
                -- dm here is a TRUE dry-matter fraction, not the 0..1 gauge: DM_FRESH 0.06
                -- to DM_JAMMED 0.15. So (1 - dm) * 1.6 was never below 1.36, the first term
                -- always exceeded `removed`, liquidOut always clamped to `removed`, and
                -- solidsOut was therefore ZERO on every single draw. The solids pool became
                -- a one-way ratchet: pumping out removed volume but no dry matter, so the
                -- instant the total fell back to its pre-dilution level the DM fraction
                -- returned to exactly where it started. Net effect for the player: adding
                -- water only ever bought back the litres of water added, no matter how much
                -- was added or how long the store was agitated.
                --
                -- The bias now scales the solids share DOWN instead of scaling the liquid
                -- share UP: solids leave at dm/bias per litre, i.e. still less than their
                -- plain proportional share (so the store concentrates as it empties, which
                -- is the intended behaviour), but never zero, so dilution genuinely wins
                -- back slurry. bias = 1 remains exactly neutral.
                -- [SPS 1.0.1.4] Bias scaled by SETTLE. The liquid-first draw models a
                -- pump pulling runny liquid from beneath SETTLED sludge — but a fresh
                -- or freshly-agitated store (settle 0) is a homogeneous mixture with
                -- nothing settled to pull from under, and the unconditional 1.6 bias
                -- made even a brand-new 500,000 L store ratchet itself to a 90% jam
                -- with ~51,000 L still in it, unreachable by any finite water dosing.
                --
                -- Effective bias = 1 + (DM_REMOVAL_LIQUID_BIAS - 1) * settle:
                --   settle 0.0 (fresh / fully mixed)  -> bias 1.0: solids leave at their
                --       plain share, DM is CONSTANT while pumping, store drains to zero.
                --   settle 1.0 (fully crusted)        -> full 1.6 bias: concentrates as
                --       it empties, jams, needs water and/or mixing — unchanged.
                --   in between                        -> proportional.
                -- Agitating before pumping therefore has a real second job: it turns a
                -- concentrating draw into an honest one. Water remains the only remedy
                -- once DM itself is past the jam line.
                local settle    = math.max(0.0, math.min(1.0, sourceEntry.settle or 0))
                local biasMax   = math.max(1.0, SlurryPipeManager.DM_REMOVAL_LIQUID_BIAS or 1.0)
                local bias      = 1.0 + (biasMax - 1.0) * settle
                local solidsOut = math.min(removed * (dm / bias), solids)
                local liquidOut = math.min(removed - solidsOut, liquid)
                -- Liquid exhausted: the balance of this draw has to come out as solids.
                solidsOut       = math.min(removed - liquidOut, solids)
                sourceEntry.solids = math.max(0, solids - solidsOut)
                -- Solids can never exceed what is left in the pile. On the last litres this
                -- forces the residue solid, which is what jams a store at the very bottom.
                sourceEntry.solids = math.min(sourceEntry.solids, math.max(0, total - removed))
            end
            storage:setFillLevel(math.max(0, oldLevel - removed), fillType)
            if sourceEntry.thickeningEnabled then
                sourceEntry._lastTotal = self:_getStoreTotalFill(sourceEntry)
            end
        end
    elseif sourceEntry.type == 3 then  -- Water source (infinite)
        -- Water planes have infinite capacity, no removal needed
        -- Visual/sound effects could be added here
    elseif sourceEntry.type == SPS_SOURCE_TYPE_BUYING_STATION then
        -- [SPS 1.0.0.9.26] Infinite paid source — nothing to decrement; the
        -- per-litre charge already happened inside the vanilla
        -- addFillLevelToFillableObject call (transferFillFromBuyingStation).
    end
end

function SlurryPipeManager:addToSource(sourceEntry, amount, fillType, farmVehicle)
    if sourceEntry == nil then return end
    
    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or sourceEntry.type == "FILL_UNIT_ONLY" then
        local destVehicle = sourceEntry.vehicle
        if destVehicle ~= nil and destVehicle.addFillUnitFillLevel ~= nil then
            local farmId = destVehicle:getOwnerFarmId()
            local fui    = sourceEntry.fillUnitIndex

            -- Lazy inject ToolType.TRIGGER into the fillUnit's supportedToolTypes,
            -- with verbose first-call-per-vehicle diagnostics to see exactly which gate
            -- (if any) silently fails. Flag prevents log spam after first attempt.
            if not destVehicle._spsTriggerInjectAttempted then
                destVehicle._spsTriggerInjectAttempted = true
                local hasTT      = ToolType ~= nil
                local hasTTTrig  = hasTT and ToolType.TRIGGER ~= nil
                local hasSpec    = destVehicle.spec_fillUnit ~= nil
                local hasFUList  = hasSpec and destVehicle.spec_fillUnit.fillUnits ~= nil
                local fu         = hasFUList and destVehicle.spec_fillUnit.fillUnits[fui] or nil
                local hasSTT     = fu ~= nil and fu.supportedToolTypes ~= nil
                local sttBefore  = hasSTT and fu.supportedToolTypes[hasTTTrig and ToolType.TRIGGER or 0] or nil
                if hasTTTrig and hasSTT then
                    fu.supportedToolTypes[ToolType.TRIGGER] = true
                    local sttAfter      = fu.supportedToolTypes[ToolType.TRIGGER]
                    local getterTool    = destVehicle:getFillUnitSupportsToolType(fui, ToolType.TRIGGER)
                    local getterFill    = destVehicle:getFillUnitSupportsFillType(fui, fillType)
                    local getterCombo   = destVehicle:getFillUnitSupportsToolTypeAndFillType(fui, ToolType.TRIGGER, fillType)
                    -- Dump function refs to detect overwrites
                    -- Dump every toolType key present in the table
                    local keys = {}
                    for k, v in pairs(fu.supportedToolTypes) do
                        keys[#keys + 1] = tostring(k) .. "=" .. tostring(v)
                    end
                    -- Dump all ToolType constants we can see
                    if ToolType ~= nil then
                        local tt = {}
                        for k, v in pairs(ToolType) do
                            if type(v) == "number" then
                                tt[#tt + 1] = tostring(k) .. "=" .. tostring(v)
                            end
                        end
                    end
                else
                end
            end

            local applied = destVehicle:addFillUnitFillLevel(farmId, fui, amount, fillType, ToolType.TRIGGER, nil)

            -- [SPS 1.0.0.9.17] EMPTY-FILL STALL DIAGNOSTIC (dedi field report:
            -- empty tanks refuse to fill until 1 l is seeded by EDC, then flow
            -- normally). Fires ONCE per vehicle per session and ONLY when the
            -- stall condition actually holds, so healthy play prints nothing.
            -- Captures every gate the vanilla call and the bypass depend on —
            -- the next report log names the failing gate byte-for-byte.
            if amount > 0 and (applied == nil or applied == 0)
            and (destVehicle:getFillUnitFillLevel(fui) or 0) <= 0.001
            and not destVehicle._spsEmptyFillStallLogged then
                destVehicle._spsEmptyFillStallLogged = true
                local fuT = destVehicle.spec_fillUnit ~= nil and destVehicle.spec_fillUnit.fillUnits ~= nil
                    and destVehicle.spec_fillUnit.fillUnits[fui] or nil
                print(string.format(
                    "[SPS FILLSTALL] %s fui=%d fillType=%s amount=%.2f | allows=%s supportsFT=%s supportsTT+FT=%s | unit.fillType=%s level=%.2f cap=%s farmId=%s isServer=%s",
                    tostring(destVehicle.configFileName), fui,
                    tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType) or fillType), amount,
                    tostring(destVehicle.getFillUnitAllowsFillType ~= nil and destVehicle:getFillUnitAllowsFillType(fui, fillType)),
                    tostring(destVehicle.getFillUnitSupportsFillType ~= nil and destVehicle:getFillUnitSupportsFillType(fui, fillType)),
                    tostring(destVehicle.getFillUnitSupportsToolTypeAndFillType ~= nil and destVehicle:getFillUnitSupportsToolTypeAndFillType(fui, ToolType.TRIGGER, fillType)),
                    tostring(fuT ~= nil and g_fillTypeManager:getFillTypeNameByIndex(fuT.fillType) or "?"),
                    destVehicle:getFillUnitFillLevel(fui) or -1,
                    tostring(fuT ~= nil and fuT.capacity or "?"),
                    tostring(farmId), tostring(destVehicle.isServer)))
            end

            -- BYPASS PATH: vanilla returned 0 but the fillUnit is legitimately fillable
            -- (allowsFillType=true, freeCapacity>0). A spec override in the vehicle's
            -- type chain is shadowing getFillUnitSupportsToolType and returning false
            -- despite supportedToolTypes containing all tool types. Replicate what
            -- vanilla addFillUnitFillLevel does AFTER its gate. Only fires when the
            -- vanilla call genuinely failed, so unaffected for slurry tankers / cobra.
            -- [SPS 1.0.0.9.18] ROOT CAUSE (FillUnit.lua, verified):
            --   * getFillUnitAllowsFillType (835-846) = supportedFillTypes[ft]
            --     AND (same type OR level/capacity <= fillTypeChangeThreshold)
            --     -> an EMPTY unit auto-passes for every SUPPORTED type. Vanilla
            --     itself never blocks empty units.
            --   * addFillUnitFillLevel's same-type fast path (1176-1177) skips
            --     the allows check entirely — which is why seeding 1 l with EDC
            --     "fixed" it in the field: with the type set, the poisoned
            --     getter is never consulted again.
            --   => the dedi empty-fill stall is a vehicle spec OVERRIDING the
            --     allows/supports getters to refuse while empty. This bypass
            --     was gated on that same overridable getter, so it never fired
            --     for exactly the vehicles that needed it. Gate now mirrors
            --     vanilla's RAW acceptance: the supportedFillTypes table read
            --     (FillUnit.lua line 802) — un-poisonable.
            local rawSupportsFT = false
            if destVehicle.spec_fillUnit ~= nil and destVehicle.spec_fillUnit.fillUnits ~= nil then
                local fuChk = destVehicle.spec_fillUnit.fillUnits[fui]
                rawSupportsFT = fuChk ~= nil and fuChk.supportedFillTypes ~= nil
                    and fuChk.supportedFillTypes[fillType] == true
            end
            if amount > 0 and (applied == nil or applied == 0)
            and rawSupportsFT
            and destVehicle.spec_fillUnit ~= nil
            and destVehicle.spec_fillUnit.fillUnits ~= nil then
                local spec = destVehicle.spec_fillUnit
                local fu   = spec.fillUnits[fui]
                if fu ~= nil then
                    -- Vanilla mass-limit parity (FillUnit.lua 1174-1186): hard
                    -- stop at max component mass, then clamp the delta by the
                    -- remaining mass budget.
                    if not fu.ignoreFillLimit and g_currentMission ~= nil
                    and g_currentMission.missionInfo ~= nil
                    and g_currentMission.missionInfo.trailerFillLimit then
                        if destVehicle.getMaxComponentMassReached ~= nil
                        and destVehicle:getMaxComponentMassReached() then
                            return
                        end
                        if destVehicle.isServer and destVehicle.getAvailableComponentMass ~= nil then
                            local maxMassToApply = destVehicle:getAvailableComponentMass()
                            local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillType)
                            if fillTypeDesc ~= nil and fillTypeDesc.massPerLiter ~= 0 then
                                amount = math.min(amount, maxMassToApply / fillTypeDesc.massPerLiter)
                            end
                        end
                    end
                    local oldFillLevel = fu.fillLevel or 0
                    local capacity     = (fu.capacity ~= nil and fu.capacity > 0) and fu.capacity or math.huge
                    local fillTypeChanged = false
                    -- Change fillType if differs and unit is empty (mirrors vanilla line 1193-1213)
                    if fu.fillType ~= fillType and oldFillLevel <= 0 then
                        fu.fillType = fillType
                        fillTypeChanged = true
                    end
                    fu.fillLevel = math.max(0, math.min(capacity, oldFillLevel + amount))
                    if fu.fillLevel > 0 then
                        fu.lastValidFillType = fu.fillType
                    end
                    applied = fu.fillLevel - oldFillLevel
                    spec.isInfoDirty = true
                    -- Mark dirty for multiplayer sync
                    if destVehicle.isServer and spec.dirtyFlag ~= nil and destVehicle.raiseDirtyFlags ~= nil then
                        destVehicle:raiseDirtyFlags(spec.dirtyFlag)
                    end
                    -- On fillType change: raise FILLTYPE_CHANGE state on root vehicle (vanilla
                    -- line 1209) and per-spec onChangedFillType (line 1210). Without these,
                    -- downstream specs (e.g. TurnOnVehicle, Sprayer) don't refresh their cab
                    -- action events, so vanilla 'Turn on sprayer' (B) stays hidden after fill.
                    if fillTypeChanged then
                        if destVehicle.rootVehicle ~= nil and destVehicle.rootVehicle.raiseStateChange ~= nil
                        and VehicleStateChange ~= nil and VehicleStateChange.FILLTYPE_CHANGE ~= nil then
                            destVehicle.rootVehicle:raiseStateChange(VehicleStateChange.FILLTYPE_CHANGE)
                        end
                        if SpecializationUtil ~= nil and SpecializationUtil.raiseEvent ~= nil then
                            SpecializationUtil.raiseEvent(destVehicle, "onChangedFillType",
                                fui, fillType, FillType.UNKNOWN)
                        end
                    end
                    -- Raise the standard fill change event so UI/sound/dashboards update
                    if SpecializationUtil ~= nil and SpecializationUtil.raiseEvent ~= nil then
                        SpecializationUtil.raiseEvent(destVehicle, "onFillUnitFillLevelChanged",
                            fui, amount, fillType, ToolType.TRIGGER, nil, applied)
                    end
                    if not destVehicle._spsBypassLogged then
                        destVehicle._spsBypassLogged = true
                    end
                end
            end
            -- DIAGNOSTIC: fire once per second per vehicle if applied=0 despite a positive request
            if amount > 0 and (applied == nil or applied == 0) then
                local nowMs = g_time or 0
                destVehicle._spsDiagLastMs = destVehicle._spsDiagLastMs or 0
                if nowMs - destVehicle._spsDiagLastMs >= 1000 then
                    destVehicle._spsDiagLastMs = nowMs
                    local spec       = destVehicle.spec_fillUnit
                    local fu         = spec and spec.fillUnits and spec.fillUnits[fui] or nil
                    local sToolTrig  = destVehicle:getFillUnitSupportsToolType(fui, ToolType.TRIGGER)
                    local sFillType  = destVehicle:getFillUnitSupportsFillType(fui, fillType)
                    local allowFT    = destVehicle:getFillUnitAllowsFillType(fui, fillType)
                end
            end

            -- [SPS SPRAY] Deposit trace — only for sprayer-registered destinations,
            -- throttled to once/sec/vehicle. Shows whether vanilla addFillUnitFillLevel
            -- landed, whether the cover-bypass had to fire, the tool/fill-type gate
            -- getters, cover state, and the resulting level/type on the sprayer unit.
            if SlurryPipeManager.SPRAYER_TRACE
            and g_slurryPipeManager ~= nil
            and g_slurryPipeManager:isSprayerVehicleRegistered(destVehicle) then
                local nowMs = g_time or 0
                destVehicle._spsSprayDepLastMs = destVehicle._spsSprayDepLastMs or 0
                if nowMs - destVehicle._spsSprayDepLastMs >= 1000 then
                    destVehicle._spsSprayDepLastMs = nowMs
                    local spec       = destVehicle.spec_fillUnit
                    local fu         = spec and spec.fillUnits and spec.fillUnits[fui] or nil
                    local sToolTrig  = destVehicle:getFillUnitSupportsToolType(fui, ToolType.TRIGGER)
                    local sFillType  = destVehicle:getFillUnitSupportsFillType(fui, fillType)
                    local allowFT    = destVehicle:getFillUnitAllowsFillType(fui, fillType)
                    local coverState = destVehicle.spec_cover ~= nil and destVehicle.spec_cover.state or "no-cover"
                    SlurryPipeManager.sprayTrace(
                        "addToSource[%s] fui=%s req=%.2f applied=%s | supportsTrigger=%s supportsFill=%s allowsFill=%s cover=%s | level=%s type=%s",
                        tostring(destVehicle.configFileName), tostring(fui), amount, tostring(applied),
                        tostring(sToolTrig), tostring(sFillType), tostring(allowFT), tostring(coverState),
                        fu ~= nil and tostring(fu.fillLevel) or "?", fu ~= nil and tostring(fu.fillType) or "?")
                end
            end
        end
    elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        local storage = sourceEntry.storage
        if storage ~= nil then
            -- Convert an unsupported incoming type (e.g. WATER) to the store's native
            -- slurry/digestate type as it enters.
            local depositFillType = self:resolveStoreDepositFillType(sourceEntry, fillType)
            local free  = storage:getFreeCapacity(depositFillType) or 0
            local toAdd = math.min(amount, free)
            if toAdd > 0 then
                -- Re-blend the store's dry matter: slurry/digestate adds solids at the
                -- tanker's carried DM; water adds volume but no dry matter, so it dilutes
                -- the store (the only lever that lowers DM).
                if sourceEntry.thickeningEnabled then
                    self:_ensureStorePools(sourceEntry)
                    local solidsIn = 0
                    if fillType ~= FillType.WATER and farmVehicle ~= nil then
                        solidsIn = toAdd * self:gaugeToDM(self:getTankerThickness(farmVehicle))
                    end
                    sourceEntry.solids = (sourceEntry.solids or 0) + solidsIn
                end
                storage:setFillLevel((storage:getFillLevel(depositFillType) or 0) + toAdd, depositFillType)
                if sourceEntry.thickeningEnabled then
                    sourceEntry._lastTotal = self:_getStoreTotalFill(sourceEntry)
                end
            end
        end
    elseif sourceEntry.type == 3 then  -- Water source (infinite capacity)
        -- Water returns to water plane (infinite capacity, no action needed)
    elseif sourceEntry.type == SPS_SOURCE_TYPE_BUYING_STATION then
        -- [SPS 1.0.0.9.26] A buying station is a FILL-only source, never a
        -- destination (its couplers ship flowDirection="FILL", which blocks
        -- discharge upstream in tickFlow). Unreachable by design — hard no-op
        -- so a mis-authored config can never dump slurry into thin air paid
        -- or unpaid.
        if not (self._loggedBuyStationDepositBlock == true) then
            self._loggedBuyStationDepositBlock = true
            SlurryPipeManager.log("addToSource: deposit into buying station blocked (FILL-only source)")
        end
    end
end

-- [SPS MP] Remote engine-sound application. The pump/valve toggles play the
-- engine loop sample only on the initiating machine; the state events carried
-- the flag but never touched sound, so the other machine's keybind text updated
-- while staying silent. Called from the event run() bodies. Safe on a dedicated
-- server: isClient is false there, and g_soundManager is guarded.
function SlurryPipeManager:applyPumpSound(vehicle, running)
    if vehicle == nil or not vehicle.isClient or g_soundManager == nil then return end
    local entry = self:getVehicleEntry(vehicle)
    if entry ~= nil and entry.engineLoopSample ~= nil then
        if running then
            g_soundManager:playSample(entry.engineLoopSample)
        else
            g_soundManager:stopSample(entry.engineLoopSample)
        end
    end
end
