-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9

-- SPSM_Pressure.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: signed pressure model, purge, pressure HUD text.
-- PURE RELOCATION from scripts/manager/SlurryPipeManager.lua (V1.0.0.8 tag):
-- every function body in this file is byte-identical to the baseline.
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

print("[SPS BUILD] SPSM_Pressure 1.0.0.9.2 loaded")


-- Single chokepoint for the vacuum/pump split. Returns true only for a tanker that
-- runs the stored-pressure model (pumpType "vacuum"); false for every pump-gated or
-- passive endpoint (HVP, conduit, openTop, no <pressure> block) and for fert/herb
-- sprayers. When false, the caller uses the legacy pump gate (PTO on = flow). Accepts
-- either a vehicle or an already-resolved entry.
function SlurryPipeManager:usesPressureModel(vehicleOrEntry)
    local entry, vehicle
    if vehicleOrEntry ~= nil and vehicleOrEntry.armEntries ~= nil then
        -- A registered entry (entries always carry an armEntries table).
        entry   = vehicleOrEntry
        vehicle = entry.vehicle
    else
        vehicle = vehicleOrEntry
        entry   = self:getVehicleEntry(vehicle)
    end
    if entry == nil then return false end
    local cfg = entry.pressure
    if cfg == nil or cfg.openTop == true then return false end
    if entry.pumpType ~= nil and entry.pumpType ~= "vacuum" then return false end
    if vehicle ~= nil and vehicle.spec_sprayer ~= nil
       and vehicle.spec_sprayer.isFertilizerSprayer == true then
        return false
    end
    return true
end

-- Returns a short HUD string for the stored pressure, e.g. "+1.2 Bar", "-0.8 Bar",
-- or "0.0 Bar" at rest. Returns nil only when this vehicle has no pressure system at
-- all (not registered, open-top/exempt, or a fert/herb sprayer). Used by the
-- fill-levels HUD override to append the reading after the fill type name. Sign
-- convention matches the model: + = pressure (discharge side), - = vacuum (fill
-- side); zero is shown unsigned.
-- Returns a short HUD string for the per-tanker working gauge, appended after the
-- fill type name in the fill-levels HUD.
--   * vacuum tanker  -> stored pressure, e.g. "+1.2 Bar" / "-0.8 Bar" / "0.0 Bar".
--   * HVP tanker     -> effective flow rate, e.g. "▸ 695 L/s" (discharge) / "◂ 695 L/s"
--                       (fill), scaled by slurry thickness so thick slurry shows a lower
--                       number; nil while the pump is off.
--   * conduit / openTop / fert-herb / unregistered -> nil (no per-tanker gauge here).
function SlurryPipeManager:getPressureInfoText(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return nil end
    local cfg = entry.pressure
    if cfg == nil or cfg.openTop == true then return nil end
    if vehicle.spec_sprayer ~= nil and vehicle.spec_sprayer.isFertilizerSprayer == true then
        return nil
    end

    -- HVP: show the pump's working effort as a percentage rather than a litre rate.
    -- 100% = clean slurry pumping at full rate; the figure falls as slurry thickens
    -- (20% thick -> ~80%, 50% -> ~50%, blocked -> 0%), conveying "the pump is only
    -- working at this fraction of full efficiency". Always visible (parity with the
    -- vacuum bar gauge), and reads 0% whenever nothing is flowing (pump off). ">>" =
    -- pumping out (discharge), "<<" = pumping in (fill). ASCII only (no font glyphs).
    -- HVP: show the effective (thickness-adjusted) flow rate in litres/second.
    -- baseRate is the tanker's own <flow litersPerSecond>; the thickness multiplier
    -- scales it down as slurry thickens (clean = full rate, thicker = less, blocked = 0).
    -- Always visible (parity with the vacuum bar gauge), including empty and pump-off,
    -- and reads 0 L/s when nothing is flowing. ">>" = pumping out, "<<" = pumping in.
    if entry.pumpType == "HVP" then
        local state = entry.state
        if state == nil or state.pumpRunning ~= true then
            return "0 L/s"
        end
        local discharging = (state.direction == SPS_DIRECTION_DISCHARGE)
        local baseRate = discharging and self:getEmptyRate(vehicle) or self:getFillRate(vehicle)
        local mult     = self:thicknessToFlowMultiplier(self:getTankerThickness(vehicle))
        local rate     = baseRate * mult
        local marker   = discharging and "-" or "+"
        return string.format("%s %d L/s", marker, MathUtil.round(rate))
    end

    -- Conduit pumps have their own HUD; no per-tanker gauge here.
    if entry.pumpType == "conduit" then return nil end

    -- vacuum (and any other pressure-model tanker): stored ±bar gauge.
    local p = (entry.state ~= nil and entry.state.pressure) or 0
    local sign = ""
    if p >= 0.05 then
        sign = "+"
    elseif p <= -0.05 then
        sign = "-"
    end
    return string.format("%s%.1f Bar", sign, math.abs(p))
end

-- Returns (scalar, usesPressure) for a vehicle's flow rate.
--   usesPressure = true  -> a real tanker: flow is gated/scaled by stored pressure,
--                           NOT by the PTO. scalar = |pressure|/maxPressure, or 0
--                           when |pressure| < minThreshold (no flow).
--   usesPressure = false -> exempt endpoint (open-top FRC, fert/herb sprayer, or no
--                           <pressure> block, e.g. conduit pump): scalar = 1.0 and the
--                           caller keeps its normal pump gate. Behaviour unchanged.
function SlurryPipeManager:getPressureFlowScalar(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return 1.0, false end
    local cfg = entry.pressure
    if not self:usesPressureModel(entry) then return 1.0, false end
    local maxP = cfg.maxPressure
    if maxP <= 0 then maxP = SlurryPipeManager.DEFAULT_MAX_PRESSURE end
    local p = math.abs((entry.state ~= nil and entry.state.pressure) or 0)
    if p < cfg.minThreshold then return 0.0, true end
    return math.min(1.0, p / maxP), true
end

-- [SPS 1.0.0.9.1] Direction-aware pressure flow scalar. Field report: a tank
-- at -2 bar with the pump flipped to Pressure discharged INSTANTLY at full
-- rate — the sign-blind |pressure| scalar above plus resolveCouplingFlow's
-- `return state.direction, pScalar` let stored VACUUM drive a DISCHARGE.
-- The stored pressure may only ever drive flow in the direction it was BUILT:
--   * DISCHARGE flows only while p >= +minThreshold (positive pressure pushes out)
--   * FILL      flows only while p <= -minThreshold (vacuum draws in)
--   * Anything else (sign mismatch, or the ±minThreshold dead band) -> 0.0:
--     the level HOLDS while the purge vents -2 -> 0 and the pump rebuilds the
--     other way; in the dead band with pumps off, head equalisation
--     (SPSM_Flow) owns any levelling between the two sources, exactly as
--     the spreader gate (SPSM_Spreader, signed since day one) already works.
-- Exempt endpoints (usesPressure=false) are unchanged: (1.0, false), caller
-- keeps its legacy pump gate. The sign convention matches the pressure tick:
-- DISCHARGE builds toward +maxPressure, FILL toward -maxPressure.
function SlurryPipeManager:getDirectionalPressureFlowScalar(vehicle, flowDirection)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return 1.0, false end
    local cfg = entry.pressure
    if not self:usesPressureModel(entry) then return 1.0, false end
    local maxP = cfg.maxPressure
    if maxP <= 0 then maxP = SlurryPipeManager.DEFAULT_MAX_PRESSURE end
    local p = (entry.state ~= nil and entry.state.pressure) or 0
    if flowDirection == SPS_DIRECTION_DISCHARGE then
        if p < cfg.minThreshold then return 0.0, true end
        return math.min(1.0, p / maxP), true
    end
    -- FILL (and any nil/other direction): only stored vacuum drives it.
    if p > -cfg.minThreshold then return 0.0, true end
    return math.min(1.0, -p / maxP), true
end

-- True if any connected+open coupling partner of this vehicle is a pressure-model
-- tanker that is currently building or holding usable pressure/vacuum (pump on, or
-- |pressure| >= minThreshold). Used to suppress this vehicle's one-way gravity
-- backflow over a coupling: while the partner is pumping, flow must wait for that
-- partner's pressure to reach threshold rather than dribbling out by gravity.
-- Arm connections do not populate couplingEntries, so arms are unaffected; a
-- coupling to a placeable store resolves no vehicle entry and is ignored.
function SlurryPipeManager:_couplingPartnerIsPressurising(vehicle)
    local vEntry = self:getVehicleEntry(vehicle)
    if vEntry == nil or vEntry.couplingEntries == nil then return false end
    for _, c in ipairs(vEntry.couplingEntries) do
        if c.isConnected and c.valveOpen then
            -- Resolve the partner vehicle (direct connectedTarget, or the far end
            -- of a chain via the source resolver) so this works for both layouts.
            local partnerVehicle = c.connectedTarget
            if partnerVehicle == nil or self:getVehicleEntry(partnerVehicle) == nil then
                local ps = self:resolveSourceForCouplingPartner(c)
                partnerVehicle = ps ~= nil and ps.vehicle or partnerVehicle
            end
            if partnerVehicle ~= nil then
                local pe = self:getVehicleEntry(partnerVehicle)
                if pe ~= nil and pe.state ~= nil then
                    if self:_isPumpOn(partnerVehicle) then return true end
                    if self:usesPressureModel(pe) then
                        local minT = (pe.pressure ~= nil and pe.pressure.minThreshold)
                            or SlurryPipeManager.DEFAULT_MIN_THRESHOLD
                        if math.abs(pe.state.pressure or 0) >= minT then return true end
                    end
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Pressure engine (server-authoritative)
-- Pressure is a STORED signed value (-maxPressure .. +maxPressure). It changes
-- only by priority each tick:
--   1. PURGE — direction flipped against stored pressure -> 0 at purgeRate
--   2. BUILD — PTO on -> toward ±max at buildRate (build wins over drain, so the
--              PTO holds pressure at max while fluid flows)
--   3. DRAIN — PTO off + any valve open -> toward 0; slow (fallTimeWorking) while
--              fluid is present/transferring, fast (fallTimeEmpty) when venting
--   4. HOLD  — PTO off + valves closed -> unchanged (pressure is stored)
-- Build time scales with poo fill ratio: full = minBuildTime, empty = maxBuildTime.
-- Open-top passive vessels (FRC) and fert/herb sprayers are skipped entirely.
--
-- Flow rate (Phase 3) scales with |pressure| / maxPressure.
-- ---------------------------------------------------------------------------

-- Moves 'current' toward 'target' by at most 'step' (signed bar values).
function SlurryPipeManager:_movePressureToward(current, target, step)
    if step <= 0 then return current end
    if current < target then
        return math.min(target, current + step)
    elseif current > target then
        return math.max(target, current - step)
    end
    return current
end

-- Returns the tank fill ratio (0..1) and absolute fill level for the vehicle's
-- primary fill unit (first arm, else first coupling, else unit 1).
function SlurryPipeManager:getPressureFillRatio(vehicle, vEntry)
    if vehicle == nil or vehicle.getFillUnitFillLevel == nil then
        return 0, nil
    end
    local fillUnitIndex = 1
    if vEntry ~= nil then
        if vEntry.armEntries ~= nil and #vEntry.armEntries > 0 then
            fillUnitIndex = vEntry.armEntries[1].fillUnitIndex
        elseif vEntry.couplingEntries ~= nil and #vEntry.couplingEntries > 0 then
            fillUnitIndex = vEntry.couplingEntries[1].fillUnitIndex
        end
    end
    local level = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
    local cap   = vehicle.getFillUnitCapacity ~= nil and (vehicle:getFillUnitCapacity(fillUnitIndex) or 0) or 0
    if cap <= 0 then
        return 0, level
    end
    return math.min(1, math.max(0, level / cap)), level
end

-- True if any flow path is open on this vehicle: the fill-arm cab valve, the
-- spreader valve, or any connected coupling's manual valve. An open valve means
-- pressure is being spent (priority 3) unless the PTO is replenishing it.
function SlurryPipeManager:isAnyValveOpen(vEntry, state)
    if state.valveOpen or state.spreaderValveOpen then return true end
    if vEntry.couplingEntries ~= nil then
        for _, c in ipairs(vEntry.couplingEntries) do
            if c.isConnected and c.valveOpen then return true end
        end
    end
    return false
end

function SlurryPipeManager:updatePressure(dt)
    local dtSec = dt * 0.001

    -- Shear bolt for non-vacuum slurry pumps (HVP / conduit). The vacuum path runs
    -- inside the pressure block below (usesPressureModel == true), so this loop only
    -- covers slurry vehicles that do NOT use the pressure model, to avoid double
    -- processing. Per-vehicle opt-in via <shearBolt bolt="true"/>; fert/herb sprayers
    -- are excluded here (sprayer-side shear bolts are handled separately). Vehicles
    -- with no spec_drivable (e.g. a stationary conduit station) simply accrue no wear
    -- inside SPSShearBolt.update, so this is a safe no-op for them.
    if SPSShearBolt ~= nil then
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.shearBolt == true then
                local v = vEntry.vehicle
                local isFert = v ~= nil and v.spec_sprayer ~= nil
                    and v.spec_sprayer.isFertilizerSprayer == true
                -- [SPS AI GATE] no shear wear while AI drives
                -- [SPS 1.0.0.9.2] shearBoltEnabled: settings-menu master switch
                -- (server-authoritative, synced via SPSSettingsSyncEvent).
                if not isFert and not self:usesPressureModel(vEntry)
                   and not self:isAIControlled(v)
                   and self.shearBoltEnabled ~= false then
                    SPSShearBolt.update(self, vEntry, dt)
                end
            end
        end
    end

    for _, vEntry in ipairs(self.registeredVehicles) do
        local vehicle = vEntry.vehicle
        local state   = vEntry.state
        local cfg     = vEntry.pressure
        -- [SPS AI GATE] AI in control: hold pressure exactly where it is and
        -- accrue no shear wear — the overrides pass everything through to
        -- vanilla, so nothing reads pressure while AI drives. Resumes from the
        -- held value when the player takes back over.
        if vehicle ~= nil and self:isAIControlled(vehicle) then
            continue
        end
        -- Pressure is slurry/water only. A vehicle carrying the sprayer spec may
        -- be a slurry spreader (poo — pressure applies) OR a fert/herb sprayer
        -- (must be shielded). Vanilla Sprayer classifies this at load:
        -- isFertilizerSprayer = not slurry/digestate and not manure. Shield those.
        if vehicle ~= nil and vehicle.spec_sprayer ~= nil
        and vehicle.spec_sprayer.isFertilizerSprayer == true then
            vehicle = nil
        end
        -- Open-top passive vessels (FRC), HVP and conduit pumps, and fert/herb
        -- sprayers do not run the stored-pressure model. They are still valid flow
        -- sources/sinks, just never pressurised. usesPressureModel is the single
        -- chokepoint for that decision (it already shields fert/herb above, but the
        -- guard there stays for clarity).
        if vehicle ~= nil and not self:usesPressureModel(vEntry) then
            if state ~= nil then state.pressure = 0; state.purging = false end
            vehicle = nil
        end
        if vehicle ~= nil and state ~= nil and cfg ~= nil then
            local maxP = cfg.maxPressure
            if maxP <= 0 then maxP = SlurryPipeManager.DEFAULT_MAX_PRESSURE end

            local fillRatio, fillLevel = self:getPressureFillRatio(vehicle, vEntry)

            -- Build time scales with poo fill ratio: full = minBuildTime (fast),
            -- empty = maxBuildTime (slow). Symmetric for vacuum and pressure.
            local buildTime = cfg.maxBuildTime - fillRatio * (cfg.maxBuildTime - cfg.minBuildTime)
            if buildTime <= 0 then buildTime = cfg.minBuildTime end
            if buildTime <= 0 then buildTime = SlurryPipeManager.DEFAULT_MIN_BUILD_TIME end

            local buildRate   = maxP / buildTime                                                    -- bar/sec
            local purgeRate   = (cfg.purgeTime       > 0) and (maxP / cfg.purgeTime)       or maxP   -- bar/sec
            local fallWorking = (cfg.fallTimeWorking > 0) and (maxP / cfg.fallTimeWorking) or maxP   -- bar/sec (slow)
            local fallEmpty   = (cfg.fallTimeEmpty   > 0) and (maxP / cfg.fallTimeEmpty)   or maxP   -- bar/sec (fast)

            local p           = state.pressure or 0
            local valveOpen   = self:isAnyValveOpen(vEntry, state)
            local hasContent  = (fillLevel ~= nil and fillLevel > 0)

            -- An empty tank carries no slurry, so it carries no thickness or crust.
            if not hasContent then
                if (state.thickness or 0) > 0 then state.thickness = 0 end
                if (state.crust or 0) > 0 then state.crust = 0 end
            end

            -- Stored-pressure model, evaluated by priority each tick:
            --   1. PURGE  — direction flipped against stored pressure -> 0 (fast, purgeRate)
            --   2. BUILD  — PTO on -> toward ±max at buildRate (overrides drain: PTO holds at max while flowing)
            --   3. DRAIN  — PTO off + a valve open -> toward 0
            --                working (fluid present) = slow; venting (empty) = fast
            --   4. HOLD   — PTO off + valves closed -> unchanged (pressure is stored)
            -- [SPS] Pump-on detector must match tickFlow: self-powered tankers use
            -- state.pumpRunning, towed PTO tankers (vac) use getIsTurnedOn(). The
            -- build branch previously read state.pumpRunning directly, so towed vac
            -- tanks never built pressure (state.pumpRunning is never set for them) and
            -- flow stayed below the minimum-pressure threshold — no litres moved.
            local pumpOn = self:_isPumpOn(vehicle)
            if state.purging then
                p = self:_movePressureToward(p, 0, purgeRate * dtSec)
                if p == 0 then state.purging = false end
            elseif pumpOn and not state.shearSnapped then
                -- Shear bolt intact: PTO drives the pump, build/hold pressure.
                -- If the bolt has snapped the pump is disconnected, so we fall
                -- through to DRAIN (valve open) / HOLD even with the PTO on.
                local target = (state.direction == SPS_DIRECTION_DISCHARGE) and maxP or -maxP
                p = self:_movePressureToward(p, target, buildRate * dtSec)
            elseif valveOpen then
                local rate = hasContent and fallWorking or fallEmpty
                p = self:_movePressureToward(p, 0, rate * dtSec)
            end
            -- else: HOLD — no change.

            state.pressure = p

            -- Shear bolt: accrue wear from hard turning under PTO load, snap when
            -- worn out, and keep the snapped shaft frozen (vac tanks only — this
            -- block is gated by usesPressureModel above). Per-vehicle opt-in via
            -- <shearBolt bolt="true"/>. Non-vacuum slurry pumps (HVP/conduit) are
            -- handled by the dedicated loop at the top of updatePressure.
            if SPSShearBolt ~= nil and vEntry.shearBolt == true
            and self.shearBoltEnabled ~= false then
                SPSShearBolt.update(self, vEntry, dt)
            end
            if math.abs((state._lastLoggedPressure or 999) - p) >= 0.1 then
                state._lastLoggedPressure = p
                -- [SPS MP] Sync the new pressure to clients so their HUD/gauge (which
                -- read state.pressure) reflect it. Server-only; gated to the same
                -- 0.1 bar quantum as the log so it stays cheap.
                if g_server ~= nil and SPSPressureStateEvent ~= nil then
                    SPSPressureStateEvent.sendEvent(vehicle, p)
                end
                SlurryPipeManager.logMP(string.format("[SPS MP] pressure %s p=%.2f dir=%s pumpOn=%s ptoOn=%s pumpRunning=%s valve=%s content=%s",
                    tostring(vehicle.configFileName), p, tostring(state.direction),
                    tostring(pumpOn),
                    tostring(vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn()),
                    tostring(state.pumpRunning), tostring(valveOpen), tostring(hasContent)))
                SlurryPipeManager.log("pressure: %s p=%.2f dir=%s pump=%s purge=%s valve=%s content=%s ratio=%.2f",
                    tostring(vehicle.configFileName), p,
                    tostring(state.direction), tostring(state.pumpRunning),
                    tostring(state.purging), tostring(valveOpen),
                    tostring(hasContent), fillRatio)
                --SlurryDebug.log(string.format("[SPS PRESSURE] %s p=%.2f dir=%s pump=%s purge=%s valve=%s content=%s ratio=%.2f",
                --    tostring(vehicle.configFileName), p,
                --    tostring(state.direction), tostring(state.pumpRunning),
                --    tostring(state.purging), tostring(valveOpen),
                --    tostring(hasContent), fillRatio))
            end
        end
    end
end
