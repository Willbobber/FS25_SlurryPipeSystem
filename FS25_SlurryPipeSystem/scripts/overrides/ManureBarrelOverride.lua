-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.0

-- ManureBarrelOverride.lua
-- FS25_SlurryPipeSystem
--
-- Overrides applied to manureBarrel and manureTrailer vehicle types.

SlurryPipeSystemOverride = {}

-- ---------------------------------------------------------------------------
-- isPTOConnected / isHydraulicsConnected
-- Uses MA's own vehicle methods when present.
-- Both return true when the vehicle has no such connection type,
-- so vanilla (no MA loaded) always passes through unchanged.
-- ---------------------------------------------------------------------------
function SlurryPipeSystemOverride.isPTOConnected(vehicle)
    if vehicle.isPtoAttached ~= nil then
        return vehicle:isPtoAttached()
    end
    return true
end

function SlurryPipeSystemOverride.isHydraulicsConnected(vehicle)
    if vehicle.isHoseAttached ~= nil then
        return vehicle:isHoseAttached()
    end
    return true
end

-- ---------------------------------------------------------------------------
-- isAIControlled — [SPS AI GATE]
-- Returns true when the vehicle (or its root) is being driven by ANY AI:
--   1. Vanilla AI worker — AIJobVehicle:getIsAIActive() is true while a job is
--      assigned (spec_aiJobVehicle.job ~= nil), synced via AIJobVehicleStateEvent.
--   2. Courseplay — runs through the Giants job system: CpAIWorker:getIsCpActive()
--      = getIsAIActive() and job:is_a(CpAIJob), so the getIsAIActive() check
--      already covers CP (verified against CpAIWorker.lua).
--   3. AutoDrive — AD OVERWRITES getIsAIActive on every vehicle to additionally
--      return true while ad.stateModule:isActive() (verified against AD
--      Specialization.lua line 56 / 1770), so the getIsAIActive() check already
--      covers AD too.
-- Direct CP/AD checks are kept below as belt-and-braces in case a future version
-- of either mod stops reporting through getIsAIActive. Both APIs verified
-- against current source.
--
-- Used by the activatables (hide player walk-up triggers), by every overwritten
-- function in this file (full vanilla pass-through while AI drives), and by
-- SlurryPipeManager:updateAIGate (per-tick suspend/resume transitions).
-- ---------------------------------------------------------------------------
function SlurryPipeSystemOverride.isAIControlled(vehicle)
    if vehicle == nil then return false end
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if root == nil then return false end
    if root.getIsAIActive ~= nil and root:getIsAIActive() then
        return true
    end
    -- Courseplay (belt-and-braces — see header)
    if root.getIsCpActive ~= nil and root:getIsCpActive() then
        return true
    end
    -- AutoDrive (belt-and-braces — see header)
    if root.ad ~= nil and root.ad.stateModule ~= nil
       and root.ad.stateModule.isActive ~= nil and root.ad.stateModule:isActive() then
        return true
    end
    return false
end

-- Returns fill level for one fill unit when known, otherwise total fill level across
-- the vehicle. Used to stop SPS work/discharge effects when the tanker is empty
-- even if the pump and spreader valve are still on.
function SlurryPipeSystemOverride.getSPSFillLevel(vehicle, fillUnitIndex)
    if vehicle == nil or vehicle.getFillUnitFillLevel == nil then
        return 0
    end

    if fillUnitIndex ~= nil then
        return vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
    end

    local total = 0
    if vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits ~= nil then
        for index, _ in pairs(vehicle.spec_fillUnit.fillUnits) do
            total = total + (vehicle:getFillUnitFillLevel(index) or 0)
        end
        return total
    end

    return vehicle:getFillUnitFillLevel(1) or 0
end

-- Immediately stops any already-running discharge pipe effects for a discharge node.
-- Returning false from getIsDischargeNodeActive blocks future updates, but this also
-- forces the visual effect off as soon as the tank reaches empty.
function SlurryPipeSystemOverride.stopSPSDischargeEffect(vehicle, dischargeNode)
    if vehicle == nil or dischargeNode == nil then
        return
    end

    if vehicle.setDischargeEffectActive ~= nil then
        vehicle:setDischargeEffectActive(dischargeNode, false, true)
    end

    if vehicle.setDischargeEffectDistance ~= nil then
        dischargeNode.dischargeDistance = 0
        vehicle:setDischargeEffectDistance(dischargeNode, 0)
    end

    if Dischargeable ~= nil and vehicle.setDischargeState ~= nil and vehicle.spec_dischargeable ~= nil then
        if vehicle.spec_dischargeable.currentDischargeState ~= Dischargeable.DISCHARGE_STATE_OFF then
            vehicle:setDischargeState(Dischargeable.DISCHARGE_STATE_OFF, true)
        end
    end
end

-- Applied to non-tanker implements (sprayer, fertilizingCultivator etc.) that are
-- attached to an SPS registered vehicle. Blocks their own discharge unless the
-- SPS spreader valve is open AND pump is running.
-- Applied to all vehicle types with WorkArea spec.
-- When attached to an SPS registered tanker, spreading is only allowed when
-- the tanker pump is running AND the spreader valve is open.
function SlurryPipeSystemOverride.getIsWorkAreaActiveAttached(self, superFunc, workArea)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, workArea)
    end
    if g_slurryPipeManager ~= nil and self.getAttacherVehicle ~= nil then
        local attacher = self:getAttacherVehicle()
        if attacher ~= nil and g_slurryPipeManager:isRegistered(attacher) then
            local state = g_slurryPipeManager:getVehicleState(attacher)
            if state ~= nil then
                -- Section bands replace the original full-width sprayer area. Once any
                -- band exists on this implement, the original is never sprayed (the bands
                -- own the ground); otherwise a blocked outlet could not leave a stripe
                -- because the full-width area would still cover it.
                if workArea._spsOriginalSprayArea == true and self._spsHasSectionBands == true then
                    return false
                end

                local fillLevel = SlurryPipeSystemOverride.getSPSFillLevel(attacher)
                local allowed = g_slurryPipeManager:isSpreaderDischargeActive(attacher) and state.spreaderValveOpen == true and fillLevel > 0
                if allowed and g_slurryPipeManager:isMaceratorBlocked(self) then allowed = false end

                -- Per-section band: also inactive when its own outlet is clogged, so the
                -- ground under that band is never modified -> a real unsprayed stripe.
                if allowed and workArea._spsBlockageEntry ~= nil and workArea._spsBlockageEntry.blocked == true then
                    allowed = false
                end

                -- Log transitions per work AREA (the toggle is stored on the work area,
                -- not the vehicle, so multiple bands don't thrash a single flag and we
                -- never print every tick).
                if workArea._spsLastActive ~= allowed then
                    local tag = workArea._spsSectionName or (workArea._spsOriginalSprayArea and "original" or "area")
                    --print("[SPS WORKAREA ATTACHED] '" .. tostring(tag) .. "' -> " .. tostring(allowed) .. " spreaderValveOpen=" .. tostring(state.spreaderValveOpen) .. " fillLevel=" .. tostring(fillLevel) .. " vehicle=" .. tostring(self.configFileName))
                    workArea._spsLastActive = allowed
                end

                if not allowed then
                    return false
                end
                -- SPS now fully governs whether this area is active (the pressure gate
                -- above). Clear the vanilla turnOn requirement on this work area so
                -- TurnOnVehicle.getIsWorkAreaActive (downstream of superFunc) does not
                -- veto it once the PTO is off — stored pressure keeps spreading.
                workArea.needsSetIsTurnedOn = false
            end
        end
    end
    return superFunc(self, workArea)
end

-- Same override for manureBarrel/manureTrailer types that have their own built-in
-- sprayer (e.g. Cobra) — checks the vehicle's own SPS state.
function SlurryPipeSystemOverride.getIsWorkAreaActiveSelf(self, superFunc, workArea)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, workArea)
    end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager:isRegistered(self) then
        local state = g_slurryPipeManager:getVehicleState(self)
        if state ~= nil then
            -- Section bands replace the original full-width sprayer area (built-in
            -- spreader case). Same rule as the attached path.
            if workArea._spsOriginalSprayArea == true and self._spsHasSectionBands == true then
                return false
            end

            local fillLevel = SlurryPipeSystemOverride.getSPSFillLevel(self)
            local allowed = g_slurryPipeManager:isSpreaderDischargeActive(self) and state.spreaderValveOpen == true and fillLevel > 0
            if allowed and g_slurryPipeManager:isMaceratorBlocked(self) then allowed = false end

            -- Per-section band: inactive when its own outlet is clogged -> stripe.
            if allowed and workArea._spsBlockageEntry ~= nil and workArea._spsBlockageEntry.blocked == true then
                allowed = false
            end

            if workArea._spsLastActive ~= allowed then
                local tag = workArea._spsSectionName or (workArea._spsOriginalSprayArea and "original" or "area")
                --print("[SPS WORKAREA SELF] '" .. tostring(tag) .. "' -> " .. tostring(allowed) .. " spreaderValveOpen=" .. tostring(state.spreaderValveOpen) .. " fillLevel=" .. tostring(fillLevel) .. " vehicle=" .. tostring(self.configFileName))
                workArea._spsLastActive = allowed
            end

            if not allowed then
                return false
            end
            -- SPS now fully governs whether this area is active (the pressure gate
            -- above). Clear the vanilla turnOn requirement on this work area so
            -- TurnOnVehicle.getIsWorkAreaActive (downstream of superFunc) does not
            -- veto it once the PTO is off — stored pressure keeps spreading.
            workArea.needsSetIsTurnedOn = false
        end
    end
    return superFunc(self, workArea)
end

-- Keeps the tanker's (activatable) slurry fill unit ACTIVE while SPS pressure-driven
-- discharge is in progress, even after the pump (TurnOnVehicle) is switched off.
--
-- Why: a manure barrel's slurry fill unit is an activatable fill unit
-- (vehicle.turnOnVehicle.activatableFillUnits). TurnOnVehicle.getIsFillUnitActive
-- returns false for such a unit whenever the vehicle is not turned on. On pump-off
-- SPS calls setIsTurnedOn(false) for the PTO sound, which would deactivate the fill
-- unit. An attached dribble bar resolves its spray source via
-- Sprayer.onStartWorkAreaProcessing -> source:getIsFillUnitActive(); a deactivated
-- unit means no source, sprayFillLevel = 0, and spreading stops dead instead of
-- tapering with the stored pressure.
--
-- While isSpreaderDischargeActive (Set to Pressure + pressure >= minThreshold) and the
-- spreader valve is open, force the unit active so the bar keeps drawing slurry. Once
-- pressure drains below the threshold this falls through to vanilla and the unit
-- deactivates — so the spray tapers off and stops cleanly. Exempt endpoints (open-top
-- FRC, fert/herb) fall back to pump state inside the helper and so behave as vanilla.
function SlurryPipeSystemOverride.getIsFillUnitActive(self, superFunc, fillUnitIndex)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, fillUnitIndex)
    end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager:isRegistered(self)
       and not g_slurryPipeManager:isSpreaderImplement(self) then
        if g_slurryPipeManager:vehicleHasSpreader(self) then
            local state = g_slurryPipeManager:getVehicleState(self)
            if state ~= nil and state.spreaderValveOpen == true
               and g_slurryPipeManager:isSpreaderDischargeActive(self) then
                return true
            end
        end
    end
    return superFunc(self, fillUnitIndex)
end

function SlurryPipeSystemOverride.getIsDischargeNodeActiveAttached(self, superFunc, dischargeNode)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, dischargeNode)
    end
    if g_slurryPipeManager ~= nil and self.getAttacherVehicle ~= nil then
        local attacher = self:getAttacherVehicle()
        if attacher ~= nil and g_slurryPipeManager:isRegistered(attacher) then
            local state = g_slurryPipeManager:getVehicleState(attacher)
            if state ~= nil then
                local fillLevel = SlurryPipeSystemOverride.getSPSFillLevel(attacher)
                local active = g_slurryPipeManager:isSpreaderDischargeActive(attacher) and state.spreaderValveOpen == true and fillLevel > 0
                if fillLevel <= 0 then
                    SlurryPipeSystemOverride.stopSPSDischargeEffect(self, dischargeNode)
                end
                if self._spsAttachedDischargeActive ~= active then
                    --print("[SPS ATTACHED DISCHARGE] getIsDischargeNodeActiveAttached -> " .. tostring(active) .. " pressure=" .. tostring(state.pressure) .. " spreaderValveOpen=" .. tostring(state.spreaderValveOpen) .. " fillLevel=" .. tostring(fillLevel) .. " vehicle=" .. tostring(self.configFileName))
                    self._spsAttachedDischargeActive = active
                end
                if not active then
                    return false
                end
            end
        end
    end
    return superFunc(self, dischargeNode)
end

function SlurryPipeSystemOverride.getCanToggleDischargeToGround(self, superFunc)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self)
    end
    if g_slurryPipeManager ~= nil then
        if g_slurryPipeManager:isRegistered(self) then return false end
        if g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil then return false end
    end
    return superFunc(self)
end

function SlurryPipeSystemOverride.getCanToggleDischargeToObject(self, superFunc)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self)
    end
    if g_slurryPipeManager ~= nil then
        if g_slurryPipeManager:isRegistered(self) then return false end
        if g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil then return false end
    end
    return superFunc(self)
end


function SlurryPipeSystemOverride.getAllowLoadTriggerActivation(self, superFunc, rootVehicle)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, rootVehicle)
    end
    if g_slurryPipeManager ~= nil then
        if g_slurryPipeManager:isRegistered(self) then return false end
        if g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil then return false end
    end
    return superFunc(self, rootVehicle)
end

function SlurryPipeSystemOverride.getDrawFirstFillText(self, superFunc)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self)
    end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager:isRegistered(self) then
        return false
    end
    return superFunc(self)
end

function SlurryPipeSystemOverride.getCanToggleTurnedOn(self, superFunc)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self)
    end
    if g_slurryPipeManager ~= nil then
        -- Sprayer-config-registered vehicles (and their attached implements) use
        -- a separate control flow (SPSSprayerPumpControl); never intercept their
        -- vanilla turn-on/B-key chain.
        if g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil then
            return superFunc(self)
        end
        if self.getAttacherVehicle ~= nil then
            local att = self:getAttacherVehicle()
            if att ~= nil and g_slurryPipeManager:findSprayerVehicleConfigForVehicle(att) ~= nil then
                return superFunc(self)
            end
        end
        -- Agitator-only mixers (mulchers etc.) are not tankers — keep their normal
        -- vanilla turn-on so the mixer can be switched on/off as usual.
        if g_slurryPipeManager:isVehicleAgitatorOnly(self) then
            return superFunc(self)
        end
        -- Block I key on the SPS tanker itself
        if g_slurryPipeManager:isRegistered(self) then
            return false
        end
        -- Block I key on attached spreader implements when tanker pump is running
        if self.getAttacherVehicle ~= nil then
            local attacher = self:getAttacherVehicle()
            if attacher ~= nil and g_slurryPipeManager:isRegistered(attacher) then
                return false
            end
        end
    end
    return superFunc(self)
end

function SlurryPipeSystemOverride.getIsDischargeNodeActive(self, superFunc, dischargeNode)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, dischargeNode)
    end
    -- A spreader implement (dribble bar) is driven via the ATTACHED override against its
    -- tanker's state, not its own — fall through so it isn't gated on a phantom self state.
    if g_slurryPipeManager == nil or not g_slurryPipeManager:isRegistered(self)
       or g_slurryPipeManager:isSpreaderImplement(self) then
        return superFunc(self, dischargeNode)
    end
    local state = g_slurryPipeManager:getVehicleState(self)
    if state == nil then return false end
    -- Discharge is driven by stored pressure (set to Pressure + pressure >= threshold),
    -- not by the PTO. Exempt endpoints fall back to pump state inside the helper.
    -- Also check fill level — effect must stop when the tank is empty.
    local fillUnitIndex = dischargeNode ~= nil and dischargeNode.fillUnitIndex or nil
    local fillLevel = SlurryPipeSystemOverride.getSPSFillLevel(self, fillUnitIndex)
    local active = g_slurryPipeManager:isSpreaderDischargeActive(self) and state.spreaderValveOpen == true and fillLevel > 0
    if fillLevel <= 0 then
        SlurryPipeSystemOverride.stopSPSDischargeEffect(self, dischargeNode)
    end
    if self._spsDischargeActive ~= active then
        --print("[SPS DISCHARGE] getIsDischargeNodeActive -> " .. tostring(active) .. " pressure=" .. tostring(state.pressure) .. " spreaderValveOpen=" .. tostring(state.spreaderValveOpen) .. " fillLevel=" .. tostring(fillLevel))
        self._spsDischargeActive = active
    end
    return active
end

function SlurryPipeSystemOverride.setIsTurnedOn(self, superFunc, isTurnedOn, noEventSend)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, isTurnedOn, noEventSend)
    end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager:isRegistered(self)
       and not g_slurryPipeManager:isSpreaderImplement(self) then
        if g_slurryPipeManager:vehicleHasSpreader(self) then
            local state = g_slurryPipeManager:getVehicleState(self)
            if state ~= nil then
                -- The desired turn state is decided by SPS discharge state, not by
                -- the pump press alone: on while pumping, OR while a spreader valve is
                -- open and stored pressure is still discharging. A call that doesn't
                -- match that intent is an external one (fold cascade, vanilla
                -- turnOffIfNotAllowed) trying to fight SPS — block it. The update()
                -- turn-state driver only ever calls with the matching value.
                local wantOn = g_slurryPipeManager:shouldSpreaderBeOn(self)
                if isTurnedOn ~= wantOn then
                    -- Resync HUD to reflect true pump state
                    g_slurryPipeManager:updateActionEventTexts(self)
                    return
                end
            end
        end
    end

    -- [SPS #2] Seamless rear-effect across the PTO-off transition.
    -- Turning off raises onTurnedOff, and under PF that calls stopEffects on the spray
    -- effect — halting particle EMISSION for an instant, which leaves a visible break in
    -- the stream that no restart-after can hide. So we PREVENT the stop: while we are
    -- entering / in a stored-pressure taper, make getIsTurnedOn() report true for the
    -- DURATION of superFunc only. PF's onTurnedOff then recomputes the effect as "on" and
    -- never stops it. The real turn state is still set false and synced inside superFunc,
    -- so the green icon, PTO and pump sound turn off exactly as before — only the spray
    -- effect is kept alive. No-op without PF or when not tapering.
    local keepEffect = false
    if isTurnedOn == false and g_slurryPipeManager ~= nil
       and self.getIsPrecisionSprayingRequired ~= nil
       and g_slurryPipeManager:isRegistered(self)
       and not g_slurryPipeManager:isSpreaderImplement(self)
       and g_slurryPipeManager:vehicleHasSpreader(self)
       and not g_slurryPipeManager:isShearBoltSnapped(self) then   -- never interfere with the snap/repair path
        local tState = g_slurryPipeManager:getVehicleState(self)
        if tState ~= nil and tState.spreaderValveOpen == true
           and g_slurryPipeManager:isSpreaderDischargeActive(self) then
            keepEffect = true
        end
    end

    if keepEffect then
        local saved = rawget(self, "getIsTurnedOn")
        rawset(self, "getIsTurnedOn", function() return true end)
        superFunc(self, isTurnedOn, noEventSend)
        rawset(self, "getIsTurnedOn", saved)
        self._spsPfEffectOn = true   -- effect kept alive; manager update() maintains/stops it
    else
        superFunc(self, isTurnedOn, noEventSend)
    end
end

function SlurryPipeSystemOverride.getCanBeTurnedOn(self, superFunc)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self)
    end
    if g_slurryPipeManager ~= nil then
        -- Sprayer-config-registered vehicles (and their attached implements) use
        -- a separate control flow (SPSSprayerPumpControl); never intercept their
        -- vanilla turn-on/B-key chain.
        if g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil then
            return superFunc(self)
        end
        if self.getAttacherVehicle ~= nil then
            local att = self:getAttacherVehicle()
            if att ~= nil and g_slurryPipeManager:findSprayerVehicleConfigForVehicle(att) ~= nil then
                return superFunc(self)
            end
        end
        if g_slurryPipeManager:isVehicleAgitatorOnly(self) then
            return superFunc(self)
        end
        if g_slurryPipeManager:isRegistered(self) and not g_slurryPipeManager:isSpreaderImplement(self) then
            -- selfPowered vehicles have their own power supply — always allow
            if g_slurryPipeManager:isVehicleSelfPowered(self) then
                return true
            end
            -- Motor must be running
            local root = self:getRootVehicle()
            if root ~= nil and root.getIsMotorStarted ~= nil then
                if not root:getIsMotorStarted() then
                    return false
                end
            end
            -- PTO must be connected (MA: isPtoAttached, vanilla: always true)
            if not SlurryPipeSystemOverride.isPTOConnected(self) then
                return false
            end
            return true
        end
        -- Non-registered vehicle attached to an SPS tanker (e.g. dribble bar).
        -- Its turn state is actively driven by the manager's turn-state driver
        -- (shouldSpreaderBeOn). Return true whenever that driver wants discharge,
        -- so vanilla TurnOnVehicle.onUpdateTick's turnOffIfNotAllowed cannot fight
        -- it off mid-discharge (including the stored-pressure taper after PTO off).
        -- When the tanker no longer wants discharge this falls through to superFunc
        -- and the bar is allowed to turn off normally.
        if self.getAttacherVehicle ~= nil then
            local attacher = self:getAttacherVehicle()
            if attacher ~= nil and g_slurryPipeManager:isRegistered(attacher) then
                if g_slurryPipeManager:shouldSpreaderBeOn(attacher) then
                    return true
                end
            end
        end
    end
    return superFunc(self)
end

-- ---------------------------------------------------------------------------
-- Spreader speed control
--
-- resolveSpreadController(self) returns (controller, mult) when this vehicle's
-- working speed should be governed by SPS spreading, else nil. The controller is
-- the tanker whose SPS state drives the spread: the vehicle itself for a built-in
-- spreader, or its attacher for an attached dribble bar. mult is the slurry-thickness
-- flow multiplier (1.0 = clean, lower = thicker, floored/blocked per the curve).
--
-- "Governed" means: registered controller, spreader valve open, and discharge
-- actually active (isSpreaderDischargeActive — pressure >= threshold for a vacuum
-- tanker, pumpRunning for an HVP). So the working-speed cap is held only while
-- slurry is actually going out, and released otherwise (an HVP releases the moment
-- the PTO stops; a vacuum tanker holds through the stored-pressure taper).
-- Sprayer-config (fert/herb) vehicles use the separate sprayer control flow and are
-- never governed here.
local function resolveSpreadController(self)
    if g_slurryPipeManager == nil then return nil end
    if g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil then return nil end
    if self.getAttacherVehicle ~= nil then
        local att = self:getAttacherVehicle()
        if att ~= nil and g_slurryPipeManager:findSprayerVehicleConfigForVehicle(att) ~= nil then
            return nil
        end
    end

    local function controllerActive(controller)
        if controller == nil or not g_slurryPipeManager:isRegistered(controller) then return false end
        local state = g_slurryPipeManager:getVehicleState(controller)
        if state == nil or state.spreaderValveOpen ~= true then return false end
        return g_slurryPipeManager:isSpreaderDischargeActive(controller)
    end

    -- Built-in spreader tanker (e.g. Joskin) — governs itself.
    if not g_slurryPipeManager:isSpreaderImplement(self)
       and g_slurryPipeManager:vehicleHasSpreader(self)
       and controllerActive(self) then
        local mult  = g_slurryPipeManager:thicknessToFlowMultiplier(g_slurryPipeManager:getTankerThickness(self))
        local isHVP = (g_slurryPipeManager:getPumpType(self) == "HVP")
        return self, mult, isHVP
    end

    -- Attached spreader implement (e.g. Samson dribble bar) — governed by its tanker.
    if self.getAttacherVehicle ~= nil then
        local attacher = self:getAttacherVehicle()
        if controllerActive(attacher) then
            local mult  = g_slurryPipeManager:thicknessToFlowMultiplier(g_slurryPipeManager:getTankerThickness(attacher))
            local isHVP = (g_slurryPipeManager:getPumpType(attacher) == "HVP")
            return attacher, mult, isHVP
        end
    end

    return nil
end

-- doCheckSpeedLimit — apply the implement's working-speed cap whenever SPS spreading
-- is active, even after the PTO is off on a vacuum tanker (stored-pressure taper).
-- Without this, vanilla Sprayer.doCheckSpeedLimit drops the cap as soon as turnOn
-- goes false and the vehicle speeds up mid-discharge. Applies to both pump types.
function SlurryPipeSystemOverride.doCheckSpeedLimit(self, superFunc)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self)
    end
    local controller = resolveSpreadController(self)
    if controller ~= nil then
        return true
    end
    return superFunc(self)
end

-- getRawSpeedLimit — scale the implement's working-speed cap by slurry thickness, so
-- the tractor slows to keep coverage (l/ha) correct as the drain rate falls. Applies
-- to every tanker (vacuum and HVP): thick slurry needs more power to push, so you
-- cannot drive as fast or it would under-spread. Skipped at a blocked-thickness
-- reading (mult 0) so the tractor isn't pinned to a zero speed limit (nothing spreads
-- at that point anyway).
function SlurryPipeSystemOverride.getRawSpeedLimit(self, superFunc)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self)
    end
    local base = superFunc(self)
    local controller, mult = resolveSpreadController(self)
    if controller ~= nil and mult ~= nil and mult > 0 and base ~= nil then
        return base * mult
    end
    return base
end

-- getSprayerUsage — spread at vanilla's METERED rate (spray-type litres/sec × working
-- width × working speed × dt), keeping the SPS slurry-thickness multiplier on top:
-- clean slurry spreads at the full vanilla rate, thicker slurry proportionally less,
-- and a blocked outlet (mult 0) stops it dead.
--
-- This is the FIELD-SPREAD rate and is deliberately kept SEPARATE from the tanker's
-- pipe/arm transfer rate. getEmptyRate (the tanker's configured empty l/s, e.g. 1390)
-- is the pump-out-into-a-pit/tank rate and is used only by the flow-session transfers,
-- NOT here — using it for spreading dumped a full tank in a single field pass. Spreading
-- through a dribble bar / built-in plate is metered by the Sprayer's own width×speed
-- calc (vanilla superFunc), exactly as an ordinary slurry bar behaves.
--
-- Falls through to plain vanilla for any vehicle SPS is not currently governing.
-- Shared "always turned on" stub for scoped Precision Farming compatibility shims.
local function spsAlwaysTurnedOn()
    return true
end

function SlurryPipeSystemOverride.getSprayerUsage(self, superFunc, fillType, dt)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, fillType, dt)
    end
    local controller, mult = resolveSpreadController(self)
    if controller == nil or mult == nil then
        -- Not governed by SPS spreading (fert/herb sprayer, or not discharging).
        return superFunc(self, fillType, dt)
    end

    -- Precision Farming compatibility / stored-pressure taper.
    -- PF's ExtendedSprayer:getSprayerUsage only applies its metered (nitrogen/pH-map) rate
    -- WHEN self:getIsTurnedOn() is true; turned off it returns the raw vanilla usage, which
    -- is ~10x larger. SPS deliberately spreads with the implement turned OFF during the
    -- stored-pressure taper (PTO off, green icon off, pressure still pushing slurry out), so
    -- without intervention PF would drain the tank ~10x too fast the instant the PTO dropped.
    -- We scope a getIsTurnedOn=true shim around ONLY this superFunc call, so PF meters as if
    -- turned on while the REAL turnOn state (and therefore the green icon, PTO engagement and
    -- sound) is left untouched. Vanilla getSprayerUsage never reads getIsTurnedOn, so this is
    -- a no-op without PF — behaviour is identical with or without Precision Farming.
    local base
    local realOn = (self.getIsTurnedOn ~= nil) and self:getIsTurnedOn()
    if not realOn then
        local saved = rawget(self, "getIsTurnedOn")
        rawset(self, "getIsTurnedOn", spsAlwaysTurnedOn)
        base = superFunc(self, fillType, dt)
        rawset(self, "getIsTurnedOn", saved)
    else
        base = superFunc(self, fillType, dt)
    end

    if base == nil then
        return base
    end
    return base * mult
end

-- ---------------------------------------------------------------------------
-- getFillLevelInformation
-- Appends the stored SPS pressure to the fill-levels HUD bar, rendered after the
-- fill type name in brackets (e.g. "Slurry  9527l (82%)" with the type shown as
-- "Slurry  (+1.2 Bar)"). FillLevelsDisplay already renders an "infoText" argument
-- in exactly that position (FillLevelsDisplay.drawFillLevel), so rather than touch
-- the vanilla HUD we intercept the display's addFillLevel call here and fold the
-- pressure into its infoText. Vanilla draw logic is left completely untouched.
--
-- The pressure is per-VEHICLE; addFillLevel is per-fill-UNIT. We tag only the first
-- SPS-pressurised fill type row (slurry/digestate/manure/water), preserving the two
-- spaces of separation by joining onto any existing infoText with ", ".
function SlurryPipeSystemOverride.getFillLevelInformation(self, superFunc, display)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, display)
    end
    if g_slurryPipeManager == nil or not g_slurryPipeManager:isRegistered(self) then
        return superFunc(self, display)
    end

    local pressureText = g_slurryPipeManager:getPressureInfoText(self)
    if pressureText == nil then
        return superFunc(self, display)
    end

    -- Fill types that carry SPS pressure (poo + water). Others (e.g. a fert tank on
    -- a multi-product sprayer) are left clean.
    local pressureFillTypes = {
        [FillType.LIQUIDMANURE] = true,
        [FillType.DIGESTATE]    = true,
        [FillType.MANURE]       = true,
        [FillType.WATER]        = true,
    }

    local tagged = false
    -- Proxy: forwards every call to the real display, but rewrites the infoText (and,
    -- when empty, the customFillTypeText) so the pressure gauge shows after the name.
    local proxy = setmetatable({}, {
        __index = function(_, key)
            local v = display[key]
            if type(v) == "function" then
                return function(_, ...) return v(display, ...) end
            end
            return v
        end,
    })

    function proxy:addFillLevel(fillType, fillLevel, capacity, precision, maxReached, typeId, customFillTypeText, infoText)
        if not tagged then
            -- Tag the slurry/water row, OR (when the tank is empty and the fill unit
            -- reports UNKNOWN) tag that empty row as the slurry row. The HUD only renders
            -- infoText when there is a fill-type NAME, so for the empty/UNKNOWN case we
            -- must also supply a customFillTypeText — otherwise the draw code skips the
            -- whole "(name) (infoText)" block and the gauge never appears until loaded.
            if pressureFillTypes[fillType] == true then
                tagged = true
                if infoText ~= nil and infoText ~= "" then
                    infoText = infoText .. ", " .. pressureText
                else
                    infoText = pressureText
                end
            elseif fillType == FillType.UNKNOWN then
                tagged = true
                -- Empty tanker: show ONLY the bar reading, no fill-type name. The HUD
                -- needs a non-nil fill-type text to render the "(infoText)" part, so use
                -- a single space as the name — it renders blank, leaving just "(0.0 Bar)".
                if customFillTypeText == nil or customFillTypeText == "" then
                    customFillTypeText = " "
                end
                if infoText ~= nil and infoText ~= "" then
                    infoText = infoText .. ", " .. pressureText
                else
                    infoText = pressureText
                end
            end
        end
        return display:addFillLevel(fillType, fillLevel, capacity, precision, maxReached, typeId, customFillTypeText, infoText)
    end

    return superFunc(self, proxy)
end
-- ---------------------------------------------------------------------------
-- getIsTurnedOnAnimationActive
-- Blocks the vanilla turn-on driver (TurnOnVehicle:onUpdate) from playing the
-- SPS-managed spreader animation, so the boom animates with ACTUAL discharge
-- (driven by SlurryPipeManager:updateSpreaderAnimations) rather than with the
-- PTO/turnOn state. Returns false only for the one clip this tanker declares via
-- <spreaderAnimation name="..."/>; every other animation and every non-SPS
-- vehicle falls straight through to vanilla. Registered on all TurnOnVehicle
-- types in init.lua's registerOverrides (the hasTurnOn block).
-- ---------------------------------------------------------------------------
function SlurryPipeSystemOverride.getIsTurnedOnAnimationActive(self, superFunc, turnedOnAnimation)
    -- [SPS AI GATE] AI worker / Courseplay / AutoDrive in control:
    -- full vanilla pass-through, SPS does not interfere.
    if SlurryPipeSystemOverride.isAIControlled(self) then
        return superFunc(self, turnedOnAnimation)
    end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager:isRegistered(self) then
        local managed = g_slurryPipeManager:getSpreaderAnimationName(self)
        if managed ~= nil and turnedOnAnimation ~= nil and turnedOnAnimation.name == managed then
            return false
        end
    end
    return superFunc(self, turnedOnAnimation)
end