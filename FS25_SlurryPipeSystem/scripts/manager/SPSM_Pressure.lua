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

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSM_Pressure 1.0.0.9.5 loaded") end


-- [SPS 1.0.0.9.5] Fert/herb sprayer exemption, decided by SPS's own registration
-- path instead of vanilla's classification alone.
--
-- Vanilla Sprayer.lua classifies at load: sprayer#fillUnitIndex defaults to 1 and
-- isFertilizerSprayer = "that fill unit allows none of LIQUIDMANURE / DIGESTATE /
-- MANURE". On self-propelled types the Sprayer spec comes from the TYPE with no
-- <sprayer> block in the vehicle XML, so the default index 1 lands on the DIESEL
-- tank and a genuine slurry vehicle is misclassified as a fertiliser sprayer
-- (field case: Vervaet Hydro Trike XL, type selfPropelledManureBarrel) — which
-- silenced the HVP/pressure HUD gauge through the raw isFertilizerSprayer gates.
--
-- The SPS config block IS the declaration of what a vehicle is:
--   * <slurryPipeSystem> (embedded or manifest)  -> slurry vehicle. Never
--     fert-exempt unless it ALSO has a sprayer-side config (dual-registered
--     fert/herb sprayers, e.g. ux5201Super) or declares the role explicitly.
--   * <sprayerPipeSystem> config                 -> sprayer-side vehicle;
--     vanilla's fert classification is trusted for these.
-- Optional explicit override for edge cases, on the slurry block root:
--   <slurryPipeSystem vehicleRole="slurry">      -> never fert-exempt
--   <slurryPipeSystem vehicleRole="fertiliser">  -> always fert-exempt
--
-- Cheap for per-tick use: findSprayerVehicleConfigForVehicle is cached per
-- configFileName, getVehicleEntry is a short list scan.
function SlurryPipeManager:isFertExemptVehicle(vehicle)
    if vehicle == nil or vehicle.spec_sprayer == nil then return false end
    if vehicle.spec_sprayer.isFertilizerSprayer ~= true then return false end
    local entry = self:getVehicleEntry(vehicle)
    if entry ~= nil then
        if entry.vehicleRole == "slurry" then return false end
        if entry.vehicleRole == "fertiliser" then return true end
    end
    return self:findSprayerVehicleConfigForVehicle(vehicle) ~= nil
end

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
    -- [SPS 1.0.0.9.5] Registration-aware fert exemption (see isFertExemptVehicle).
    if vehicle ~= nil and self:isFertExemptVehicle(vehicle) then
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
    -- [SPS HUD TRACE 1.0.0.9.4] One-shot per vehicle, gated behind the
    -- SPSM_Pressure debug channel (spsDebug SPSM_Pressure on): prints every
    -- nil-gate this function can take, so a missing HUD gauge names its exact
    -- cause in one line. Remove once the Hydro Trike XL gauge issue is resolved.
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSM_Pressure")
       and vehicle ~= nil and vehicle._spsHudTraceGates ~= true then
        vehicle._spsHudTraceGates = true
        local sp = vehicle.spec_sprayer
        print(string.format(
            "[SPS HUD TRACE] getPressureInfoText gates: %s entry=%s pressureCfg=%s openTop=%s spec_sprayer=%s isFertilizerSprayer=%s pumpType=%s",
            tostring(vehicle.configFileName),
            tostring(entry ~= nil),
            tostring(entry ~= nil and entry.pressure ~= nil),
            tostring(entry ~= nil and entry.pressure ~= nil and entry.pressure.openTop),
            tostring(sp ~= nil),
            tostring(sp ~= nil and sp.isFertilizerSprayer),
            tostring(entry ~= nil and entry.pumpType)))
    end
    if entry == nil then return nil end
    local cfg = entry.pressure
    if cfg == nil or cfg.openTop == true then return nil end
    -- [SPS 1.0.0.9.5] Registration-aware fert exemption (see isFertExemptVehicle).
    if self:isFertExemptVehicle(vehicle) then
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
-- [SPS 1.0.2.0] Pressure side vs vacuum side limits. vac = true -> the vacuum value (positive magnitude), falling back to
-- the pressure one, then to the global default.
function SlurryPipeManager.pcfgMax(cfg, vac)
    local m = vac and cfg.maxVacuum or cfg.maxPressure
    if m == nil or m <= 0 then m = cfg.maxPressure end
    if m == nil or m <= 0 then m = SlurryPipeManager.DEFAULT_MAX_PRESSURE end
    return m
end
function SlurryPipeManager.pcfgThreshold(cfg, vac)
    local t = vac and cfg.minThresholdVacuum or cfg.minThreshold
    return t or cfg.minThreshold or SlurryPipeManager.DEFAULT_MIN_THRESHOLD
end

function SlurryPipeManager:getPressureFlowScalar(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return 1.0, false end
    local cfg = entry.pressure
    if not self:usesPressureModel(entry) then return 1.0, false end
    local p0  = (entry.state ~= nil and entry.state.pressure) or 0
    local vac = p0 < 0
    local maxP = SlurryPipeManager.pcfgMax(cfg, vac)
    local p = math.abs(p0)
    if p < SlurryPipeManager.pcfgThreshold(cfg, vac) then return 0.0, true end
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
    local maxP = SlurryPipeManager.pcfgMax(cfg, false)
    local maxV = SlurryPipeManager.pcfgMax(cfg, true)
    local p = (entry.state ~= nil and entry.state.pressure) or 0
    if flowDirection == SPS_DIRECTION_DISCHARGE then
        if p < SlurryPipeManager.pcfgThreshold(cfg, false) then return 0.0, true end
        return math.min(1.0, p / maxP), true
    end
    -- FILL (and any nil/other direction): only stored vacuum drives it (its own limit and threshold).
    if p > -SlurryPipeManager.pcfgThreshold(cfg, true) then return 0.0, true end
    return math.min(1.0, -p / maxV), true
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
                        local minT = pe.pressure ~= nil
                            and SlurryPipeManager.pcfgThreshold(pe.pressure, (pe.state.pressure or 0) < 0)
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

-- Returns the tank fill ratio (0..1), absolute fill level and [SPS 1.0.2.0 B1] the capacity for the vehicle's
-- primary fill unit (first arm, else first coupling, else unit 1).
function SlurryPipeManager:getPressureFillRatio(vehicle, vEntry)
    if vehicle == nil or vehicle.getFillUnitFillLevel == nil then
        return 0, nil, nil
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
        return 0, level, cap
    end
    return math.min(1, math.max(0, level / cap)), level, cap
end

-- [SPS 1.0.2.0 B1] VACUUM-HELD GRAVITY DRAIN, the air-space term (William 2026-11-04: "the more that leaves the bigger
-- the air space, the vacuum weakens, the pressure falls and the poo comes out faster and faster"; spec B1). Every litre
-- that leaves a tank under vacuum is replaced by air drawn in at atmospheric pressure through the open valve, so the
-- gauge value mixes toward 0: p = p x airOld / airNew with air = capacity - level. (Exactly the mixing model
-- (Pabs x airOld + litresOut) / airNew - 1, written on the gauge value.) The air space is floored at B1_AIR_FLOOR of
-- the capacity so a brim-full tank does not collapse its vacuum in one tick. No XML number. Vacuum side only (p < 0);
-- the positive side keeps its constant drain rate. Runs on top of whichever branch moved p this tick (drain, purge,
-- hold, build), so an open valve during a purge finishes the purge sooner.
SlurryPipeManager.B1_AIR_FLOOR = 0.02
-- [SPS 1.0.2.0] fix 2026-11-05 (William: "-2 bar and just opened a 6 to 8 inch hole, pressure would woosh through"): an
-- EMPTY tank with a coupling open to air (couplingSucksAir) loses its whole charge in this many seconds, instead of the
-- sealed-tank decay fallTimeEmpty (60 s on the Supercis). With slurry aboard the slurry is in the way: the charge still
-- goes at fallTimeWorking, which is what paces the vacuum-held gravity seep (B1, confirmed 2026-11-05).
SlurryPipeManager.HOLE_VENT_TIME = 1.5

function SlurryPipeManager:applyAirSpaceTerm(state, p, fillLevel, fillCap)
    local prev = state._b1Level
    state._b1Level = fillLevel
    if p >= 0 or prev == nil or fillLevel == nil or fillCap == nil or fillCap <= 0 then return p end
    if fillLevel >= prev then return p end                       -- nothing left the tank this tick
    local airFloor = fillCap * SlurryPipeManager.B1_AIR_FLOOR
    local airOld = math.max(fillCap - prev,      airFloor)
    local airNew = math.max(fillCap - fillLevel, airFloor)
    if airNew <= airOld then return p end
    return p * airOld / airNew
end

-- [SPS 1.0.2.0 B3] AIR-SUCK RULE (William 2026-11-04: "if a tanker tries to build pressure but the valve is open with
-- nothing to suck from it won't build"; PRESSURE_GAUGES_SPEC.md B3). A slurry coupling is open to AIR when its valve is
-- open to the outside (couplingHoleValveOpen, SPSM_Flow: the hole rule's own definition) and nothing on it reaches a
-- liquid: no pipe at all, a physical pipe whose chain's far end lies free NOT in a water plane (concrete, grass, held
-- in the hands), or a strap pipe whose free end is not in the water. A coupling that is connected (chain complete on
-- a coupler: store, pit, tanker) is a liquid path whatever the far valve does - the pump then works against the far
-- valve, not against air.
-- A free pipe end reaches a liquid in two ways: a water plane (physFreeEndWaterPlane, the 1.0.1.8 water-intake rule)
-- or, since 2026-11-05, a store's fill plane with the end UNDER the surface (physFreeEndSlurrySource, William: "a pipe
-- sucking from a slurry plane"). An end over an EMPTY pit is above its surface = air. Every other free end is air.
-- 80 mm lane fittings and sprayer couplers are other systems and never enter this rule.
function SlurryPipeManager:couplingSucksAir(vEntry, coupling)
    if coupling == nil or coupling.isConnected or coupling.isLiquidLane or coupling.isSprayerCoupling then return false end
    if not self:couplingHoleValveOpen(vEntry, coupling) then return false end
    if coupling.physPipe ~= nil and self.physFreeEndWaterPlane ~= nil
       and self:physFreeEndWaterPlane(coupling) ~= nil then
        return false                                          -- physical pipe, free end in the water: a source
    end
    if self.physCouplingIsSlurryFed ~= nil and self:physCouplingIsSlurryFed(coupling) then
        return false                 -- free pipe end (or a tanker's bare coupler mouth) under a pit's surface: a source
    end
    if coupling.pipeId ~= nil and self.strapPipeFreeEndWaterPlane ~= nil
       and self:strapPipeFreeEndWaterPlane(vEntry.vehicle, coupling) ~= nil then
        return false                                          -- strap pipe, free end in the water: a source
    end
    return true
end

-- [SPS 1.0.2.0 B3] The first coupling of this vehicle that is open to air (see couplingSucksAir), or nil.
function SlurryPipeManager:findAirCoupling(vEntry)
    if vEntry == nil or vEntry.couplingEntries == nil then return nil end
    for _, c in ipairs(vEntry.couplingEntries) do
        if self:couplingSucksAir(vEntry, c) then return c end
    end
    return nil
end

-- True if any flow path is open on this vehicle: the fill-arm cab valve, the
-- spreader valve, or any connected coupling's manual valve. An open valve means
-- pressure is being spent (priority 3) unless the PTO is replenishing it.
-- [SPS 1.0.2.0 B3] A coupling open to AIR (valve open, nothing on it, or a pipe end lying free) also counts: it vents
-- the stored charge. Before B3 a bare open coupler HELD a vacuum (log 2026-11-04 22:18:46, pipe pulled with the
-- handle still open), which no open hole can do.
function SlurryPipeManager:isAnyValveOpen(vEntry, state)
    if state.valveOpen or state.spreaderValveOpen then return true end
    if vEntry.couplingEntries ~= nil then
        for _, c in ipairs(vEntry.couplingEntries) do
            if c.isConnected and c.valveOpen then return true end
            if self:couplingSucksAir(vEntry, c) then return true end
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
                -- [SPS 1.0.0.9.5] Registration-aware fert exemption (see isFertExemptVehicle).
                local isFert = self:isFertExemptVehicle(v)
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
        -- (must be shielded). [SPS 1.0.0.9.5] Shield decision now registration-aware
        -- (see isFertExemptVehicle) so a slurry-registered vehicle misclassified by
        -- vanilla (sprayer#fillUnitIndex default landing on a fuel tank) keeps its
        -- pressure model.
        if vehicle ~= nil and self:isFertExemptVehicle(vehicle) then
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

            local fillRatio, fillLevel, fillCap = self:getPressureFillRatio(vehicle, vEntry)

            -- Build time scales with poo fill ratio: full = minBuildTime (fast),
            -- empty = maxBuildTime (slow). Symmetric for vacuum and pressure.
            -- [SPS 1.0.2.0] BUILD uses the limits of the side the pump is building toward (direction: discharge =
            -- pressure, fill = vacuum); PURGE / FALL use the side the stored charge is on (sign of the pressure now).
            local buildVac = state.direction ~= SPS_DIRECTION_DISCHARGE
            local maxB     = SlurryPipeManager.pcfgMax(cfg, buildVac)
            local minBT    = buildVac and cfg.minBuildTimeVacuum or cfg.minBuildTime
            local maxBT    = buildVac and cfg.maxBuildTimeVacuum or cfg.maxBuildTime
            local buildTime = maxBT - fillRatio * (maxBT - minBT)
            if buildTime <= 0 then buildTime = minBT end
            if buildTime <= 0 then buildTime = SlurryPipeManager.DEFAULT_MIN_BUILD_TIME end

            local sideVac = (state.pressure or 0) < 0
            local maxS    = SlurryPipeManager.pcfgMax(cfg, sideVac)
            local fwT     = sideVac and cfg.fallTimeWorkingVacuum or cfg.fallTimeWorking
            local feT     = sideVac and cfg.fallTimeEmptyVacuum or cfg.fallTimeEmpty

            local buildRate   = maxB / buildTime                                                    -- bar/sec
            local purgeRate   = (cfg.purgeTime > 0) and (maxS / cfg.purgeTime) or maxS               -- bar/sec
            local fallWorking = (fwT > 0) and (maxS / fwT) or maxS                                   -- bar/sec (slow)
            local fallEmpty   = (feT > 0) and (maxS / feT) or maxS                                   -- bar/sec (fast)

            local p           = state.pressure or 0
            local valveOpen   = self:isAnyValveOpen(vEntry, state)
            local hasContent  = (fillLevel ~= nil and fillLevel > 0)
            -- [SPS 1.0.2.0] open hole on an empty tank: the fast vent (HOLE_VENT_TIME) replaces fallEmpty below
            local fallHole = nil
            if not hasContent and p ~= 0 and self:findAirCoupling(vEntry) ~= nil then
                fallHole = maxS / SlurryPipeManager.HOLE_VENT_TIME
            end

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
            -- [SPS 1.0.2.0] LID OPEN (William 2026-11-05: the tanker's top fill is a lid - opened, any pressure or vacuum
            -- inside is gone within a second or so): the tank is open to atmosphere, so it vents at the hole rate and the
            -- pump builds nothing until the lid is shut again.
            local lidOpen = cfg.coverVents ~= false and vehicle.spec_cover ~= nil
                and vehicle.spec_cover.hasCovers == true and (vehicle.spec_cover.state or 0) > 0
            if lidOpen then
                p = self:_movePressureToward(p, 0, (maxS / SlurryPipeManager.HOLE_VENT_TIME) * dtSec)
                state.purging = false
            elseif state.purging then
                p = self:_movePressureToward(p, 0, purgeRate * dtSec)
                if p == 0 then state.purging = false end
            elseif pumpOn and not state.shearSnapped then
                -- Shear bolt intact: PTO drives the pump, build/hold pressure.
                -- If the bolt has snapped the pump is disconnected, so we fall
                -- through to DRAIN (valve open) / HOLD even with the PTO on.
                -- [SPS 1.0.1.6] Open-spreader-valve rules (William, field test):
                -- the pump only builds when it has slurry to work against.
                --   * VACUUM (-) never builds with the rear valve open -- an
                --     open port just sucks air; the valve must be closed to
                --     fill (no pumping-in and spreading at the same time).
                --   * PRESSURE (+) builds only while slurry is aboard -- the
                --     charge pushes on the slurry; an empty open tank cycles
                --     air and builds nothing.
                --   * When the pump cannot build, the stored charge drains
                --     instead (working rate with content, fast rate empty).
                local canBuild = true
                if state.spreaderValveOpen == true then
                    if state.direction ~= SPS_DIRECTION_DISCHARGE then
                        canBuild = false
                    elseif not hasContent then
                        canBuild = false
                    end
                end
                -- [SPS 1.0.2.0 B3] AIR-SUCK RULE: a coupling open to air (valve open with no pipe, or a pipe whose
                -- far end lies free and not in the water - couplingSucksAir) is the same thing as the open spreader
                -- valve: on FILL the pump only cycles air and never builds a vacuum; on DISCHARGE it builds only
                -- while slurry is aboard (the charge pushes the slurry out of the hole - the confirmed "hole wins"
                -- pour), an empty open tank cycles air. Cannot build -> the existing drain fallback below applies.
                -- Before B3 the build branch never looked at the couplings, so a bare open coupler built -2 bar.
                local airCoupling = nil
                if canBuild then
                    airCoupling = self:findAirCoupling(vEntry)
                    if airCoupling ~= nil then
                        if state.direction ~= SPS_DIRECTION_DISCHARGE then
                            canBuild = false
                        elseif not hasContent then
                            canBuild = false
                        end
                    end
                end
                local airTag = (airCoupling ~= nil and not canBuild) and tostring(airCoupling.id) or "none"
                if state._airSuckTag ~= airTag then
                    state._airSuckTag = airTag
                    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSM_Pressure") then
                        print(string.format("[SPS PRESSURE] air-suck %s coupler=%s dir=%s content=%s p=%.2f",
                            tostring(vehicle.configFileName), airTag, tostring(state.direction), tostring(hasContent), p))
                    end
                end
                if canBuild then
                    local target = (state.direction == SPS_DIRECTION_DISCHARGE) and maxB or -maxB
                    p = self:_movePressureToward(p, target, buildRate * dtSec)
                else
                    local rate = hasContent and fallWorking or (fallHole or fallEmpty)
                    p = self:_movePressureToward(p, 0, rate * dtSec)
                end
            elseif valveOpen or state.spreaderValveOpen == true then
                -- Pump off with either valve open: stored charge vents toward 0
                -- (working rate while content still moves, fast rate otherwise).
                -- [SPS 1.0.2.0 B1] plus the air-space term below: the litres that left this tick weaken the vacuum.
                local rate = hasContent and fallWorking or (fallHole or fallEmpty)
                p = self:_movePressureToward(p, 0, rate * dtSec)
            end
            -- else: HOLD — no change.

            -- [SPS 1.0.2.0 B1] Air drawn in behind the litres that left (vacuum side only, see applyAirSpaceTerm).
            p = self:applyAirSpaceTerm(state, p, fillLevel, fillCap)

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
            end
        end
    end

    -- [SPS 1.0.2.0 B2] HVP line suction per flow path (server only: updatePressure runs under g_server).
    self:tickLinePressure(dt)
end

-- =====================================================================================================================
-- [SPS 1.0.2.0 B2] HVP LINE SUCTION (William 2026-11-04: "The HVP starts to suck, that creates suction, when we reach a
-- certain suction it starts to fill. Pump off: the suction stays until the valve is closed, which purges the line";
-- PRESSURE_GAUGES_SPEC.md B2). HVP tankers run no stored TANK pressure (usesPressureModel false, state.pressure stays 0);
-- instead every flow PATH - pipe coupling or fill arm - carries its own `linePressure` (signed bar: FILL side builds
-- toward -maxP, DISCHARGE side toward +maxP). Server state, synced by SPSLinePressureEvent at the 0.1 bar quantum and
-- in the join-dump. Per path and tick:
--   no pipe / not connected          -> 0           (pipe pulled, nothing to hold)
--   valve closed                     -> purge to 0  (maxP / purgeTime)
--   pump on + a source at the far end -> build toward the target at maxP / minBuildTime
--   pump on, nothing at the far end  -> purge to 0  (the pump cycles air through the open end - the B3 idea on HVPs)
--   pump off                         -> HOLD
-- The flow (resolveCouplingFlow, non-pressure branch -> getLineFlowScalar) moves litres through an HVP only while an
-- open path's line is at or past minThreshold in the built direction, scalar |line| / maxP (the vac model's shape), so
-- the pit level starts dropping a moment after the pump starts, not at once. Outer gauges on HVPs read this value
-- (SPSM_Gauges). Numbers come from the vehicle's <pressure> block, which is read for every vehicle (defaults apply);
-- no new XML. Shear bolt stays vacuum-only. Conduit pumps, open-top vessels and sprayers are untouched.
-- =====================================================================================================================
SlurryPipeManager.LINE_PART_COUPLING = 0
SlurryPipeManager.LINE_PART_ARM      = 1
SlurryPipeManager.LINE_SYNC_QUANTUM  = 0.1

-- HVP tankers only (pumpType "HVP"), fert / herb sprayers excluded like the tank model. Accepts an entry or a vehicle.
function SlurryPipeManager:usesLinePressure(entryOrVehicle)
    local entry = entryOrVehicle
    if entry ~= nil and entry.armEntries == nil then entry = self:getVehicleEntry(entryOrVehicle) end
    if entry == nil or entry.pumpType ~= "HVP" or entry.pressure == nil then return false end
    if entry.vehicle ~= nil and self:isFertExemptVehicle(entry.vehicle) then return false end
    return true
end

-- The inputs of one path this tick: pipeOn (something plugged / docked), valveOpen (this end's valve - the coupler's
-- own handle, the owner's cab valve for HYDRAULIC and rear-panel couplers, always for a valve-less NONE coupler; the
-- cab valve for a fill arm), hasSource (the far end reaches a liquid: chain complete on a coupler / arm docked on a
-- source or boot port / free end in a water plane). The far end's own valve is NOT part of this: suction builds
-- against a closed far valve, and the both-ends gate in resolveExternalSource still stops the litres.
function SlurryPipeManager:_linePathInputs(entry, kind, part)
    local state = entry.state
    if kind == SlurryPipeManager.LINE_PART_ARM then
        local pipeOn = part.isConnected == true
        local hasSource = pipeOn and (part.connectedSource ~= nil or part.connectedBootPort ~= nil)
        return pipeOn, state ~= nil and state.valveOpen == true, hasSource
    end
    local pipeOn = part.isConnected == true or part.physPipe ~= nil or part.pipeId ~= nil
    local valveOpen = self:couplingHoleValveOpen(entry, part)
        or (part.valveType == SPS_VALVE_TYPE_HYDRAULIC and state ~= nil and state.valveOpen == true)
    local hasSource = part.isConnected == true
    if not hasSource and part.physPipe ~= nil and self.physFreeEndWaterPlane ~= nil
       and self:physFreeEndWaterPlane(part) ~= nil then
        hasSource = true
    end
    if not hasSource and valveOpen and self.physFreeEndSlurrySource ~= nil then
        -- free end in a store's fill plane: a draw needs it under the surface, a deposit only over the plane.
        -- [SPS 1.0.2.0] 2026-11-05: also a tanker's bare coupler mouth over a pit - the pit is then "on the line", so
        -- an HVP can build and push into it with no pipe fitted. Only asked with the valve open (a shut one purges).
        local se, _, submerged = self:physFreeEndSlurrySource(part)
        if se ~= nil then
            pipeOn = true
            if submerged or (state ~= nil and state.direction == SPS_DIRECTION_DISCHARGE) then hasSource = true end
        end
    end
    if not hasSource and part.pipeId ~= nil and self.strapPipeFreeEndWaterPlane ~= nil
       and self:strapPipeFreeEndWaterPlane(entry.vehicle, part) ~= nil then
        hasSource = true
    end
    return pipeOn, valveOpen, hasSource
end

-- Sync + trace at the quantum (and on the return to exactly 0).
function SlurryPipeManager:_lineSend(vehicle, kind, part, lp)
    local last = part._lineSent
    if last ~= nil and math.abs(lp - last) < SlurryPipeManager.LINE_SYNC_QUANTUM and not (lp == 0 and last ~= 0) then
        return
    end
    part._lineSent = lp
    if g_server ~= nil and SPSLinePressureEvent ~= nil then
        SPSLinePressureEvent.sendEvent(vehicle, kind, part.id, lp)
    end
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSM_Pressure") then
        print(string.format("[SPS PRESSURE] line %s %s id=%s lp=%.2f", tostring(vehicle.configFileName),
            (kind == SlurryPipeManager.LINE_PART_ARM) and "arm" or "coupler", tostring(part.id), lp))
    end
end

function SlurryPipeManager:_tickLinePart(entry, kind, part, pumpOn, target, buildStep, purgeStep)
    local lp = part.linePressure or 0
    local pipeOn, valveOpen, hasSource = self:_linePathInputs(entry, kind, part)
    if not pipeOn then
        lp = 0
    elseif not valveOpen then
        lp = self:_movePressureToward(lp, 0, purgeStep)
    elseif pumpOn then
        if hasSource then
            lp = self:_movePressureToward(lp, target, buildStep)
        else
            lp = self:_movePressureToward(lp, 0, purgeStep)
        end
    end
    -- pump off, valve open, pipe on: HOLD
    part.linePressure = lp
    self:_lineSend(entry.vehicle, kind, part, lp)
end

function SlurryPipeManager:tickLinePressure(dt)
    local dtSec = dt * 0.001
    for _, entry in ipairs(self.registeredVehicles) do
        local vehicle = entry.vehicle
        if vehicle ~= nil and entry.state ~= nil and self:usesLinePressure(entry) then
            local cfg  = entry.pressure
            local maxP = cfg.maxPressure
            if maxP == nil or maxP <= 0 then maxP = SlurryPipeManager.DEFAULT_MAX_PRESSURE end
            local lineVac = entry.state.direction ~= SPS_DIRECTION_DISCHARGE
            local maxB = SlurryPipeManager.pcfgMax(cfg, lineVac)
            local buildTime = lineVac and cfg.minBuildTimeVacuum or cfg.minBuildTime
            if buildTime == nil or buildTime <= 0 then buildTime = SlurryPipeManager.DEFAULT_MIN_BUILD_TIME end
            local purgeTime = cfg.purgeTime
            if purgeTime == nil or purgeTime <= 0 then purgeTime = SlurryPipeManager.DEFAULT_PURGE_TIME end
            local buildStep = maxB / buildTime * dtSec
            local purgeStep = maxP / purgeTime * dtSec
            local pumpOn = self:_isPumpOn(vehicle)
            local target = (entry.state.direction == SPS_DIRECTION_DISCHARGE) and maxB or -maxB
            if entry.couplingEntries ~= nil then
                for _, c in ipairs(entry.couplingEntries) do
                    if not c.isLiquidLane and not c.isSprayerCoupling then
                        self:_tickLinePart(entry, SlurryPipeManager.LINE_PART_COUPLING, c, pumpOn, target, buildStep, purgeStep)
                    end
                end
            end
            if entry.armEntries ~= nil then
                for _, a in ipairs(entry.armEntries) do
                    self:_tickLinePart(entry, SlurryPipeManager.LINE_PART_ARM, a, pumpOn, target, buildStep, purgeStep)
                end
            end
        end
    end
end

-- =====================================================================================================================
-- [SPS 1.0.2.0] HVP SPREADING BACK PRESSURE (William 2026-11-08: "a vac tank will only spread when the pressure is enough
-- to push the poo out the pipe and building pressure pushes faster; on a HVP the pump pushes the poo but the pump must
-- push which means it will get a back pressure - the more the pressure the more poo and faster").
-- state.spreadPressure (bar, >= 0) of an HVP: pump on + lever on DISCHARGE + spreader valve open + slurry aboard -> builds
-- toward the pressure-side limit (pcfgMax(cfg, false)) over minBuildTime; anything else (pump off, lever elsewhere, valve
-- shut, tank empty = air) -> purges to 0 over purgeTime. Consumers: getSpreaderPressureScalar (spread RATE and effect
-- density = max(gravity floor, spreadPressure / limit)), isSpreaderDischargeActive (pump-off taper while it drains), the
-- discharge + pump gauges (SPSM_Gauges). Ticked on EVERY machine from inputs that already sync (pumpRunning, direction,
-- spreaderValveOpen, fill level) - no event, no join dump; the server's value is the one that moves litres.
-- Vacuum tankers never come here (they keep the stored-pressure model).
-- =====================================================================================================================
function SlurryPipeManager:tickSpreadPressure(dt)
    if dt == nil or dt <= 0 then return end
    local s = dt * 0.001
    for _, entry in ipairs(self.registeredVehicles) do
        local state = entry.state
        if entry.vehicle ~= nil and state ~= nil and self:usesLinePressure(entry) then
            local cfg  = entry.pressure
            local maxP = cfg.maxPressure
            if maxP == nil or maxP <= 0 then maxP = SlurryPipeManager.DEFAULT_MAX_PRESSURE end
            local maxB = SlurryPipeManager.pcfgMax(cfg, false)
            local buildTime = cfg.minBuildTime
            if buildTime == nil or buildTime <= 0 then buildTime = SlurryPipeManager.DEFAULT_MIN_BUILD_TIME end
            local purgeTime = cfg.purgeTime
            if purgeTime == nil or purgeTime <= 0 then purgeTime = SlurryPipeManager.DEFAULT_PURGE_TIME end
            local ps = state.spreadPressure or 0
            local spreading = state.direction == SPS_DIRECTION_DISCHARGE and state.spreaderValveOpen == true
                and self:_isPumpOn(entry.vehicle)
            if spreading then
                local _, fillLevel = self:getPressureFillRatio(entry.vehicle, entry)
                if fillLevel == nil or fillLevel <= 0 then spreading = false end
            end
            if spreading then
                ps = self:_movePressureToward(ps, maxB, maxB / buildTime * s)
            else
                ps = self:_movePressureToward(ps, 0, maxP / purgeTime * s)
            end
            state.spreadPressure = ps
        elseif state ~= nil and state.spreadPressure ~= nil and state.spreadPressure ~= 0 then
            state.spreadPressure = 0
        end
    end
end

-- the HVP's spreading back pressure now (0 for anything that is not an HVP)
function SlurryPipeManager:getSpreadPressure(vehicleOrEntry)
    local entry = vehicleOrEntry
    if entry ~= nil and entry.armEntries == nil then entry = self:getVehicleEntry(vehicleOrEntry) end
    if entry == nil or entry.state == nil then return 0 end
    return entry.state.spreadPressure or 0
end

-- Flow scalar of an HVP this tick: the strongest OPEN path (pipe on + this end's valve open) whose line is at or past
-- minThreshold in the built direction, as |line| / maxP capped at 1; 0 while no path has built up yet.
function SlurryPipeManager:getLineFlowScalar(entry, state)
    local cfg  = entry.pressure
    local sign = (state ~= nil and state.direction == SPS_DIRECTION_DISCHARGE) and 1 or -1
    local maxP = SlurryPipeManager.pcfgMax(cfg, sign < 0)
    local minT = SlurryPipeManager.pcfgThreshold(cfg, sign < 0)
    local best = 0
    local function consider(kind, part)
        local pipeOn, valveOpen = self:_linePathInputs(entry, kind, part)
        if pipeOn and valveOpen then
            local lp = (part.linePressure or 0) * sign
            if lp >= minT then best = math.max(best, math.min(1, lp / maxP)) end
        end
    end
    if entry.couplingEntries ~= nil then
        for _, c in ipairs(entry.couplingEntries) do
            if not c.isLiquidLane and not c.isSprayerCoupling then consider(SlurryPipeManager.LINE_PART_COUPLING, c) end
        end
    end
    if entry.armEntries ~= nil then
        for _, a in ipairs(entry.armEntries) do consider(SlurryPipeManager.LINE_PART_ARM, a) end
    end
    return best
end
