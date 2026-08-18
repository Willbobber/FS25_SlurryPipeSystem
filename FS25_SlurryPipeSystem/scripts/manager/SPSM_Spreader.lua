-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.10.4

-- SPSM_Spreader.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: spreader animations, dribble bars, blockages, shear bolt.
-- PURE RELOCATION from scripts/manager/SlurryPipeManager.lua (V1.0.0.8 tag):
-- every function body in this file is byte-identical to the baseline.
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

print("[SPS BUILD] SPSM_Spreader 1.0.0.10.4 loaded")


function SlurryPipeManager:vehicleHasSpreader(vehicle)
    -- Check the tanker itself (e.g. Cobra with built-in spreader)
    if vehicle.spec_dischargeable ~= nil then return true end
    -- Check attached implements (e.g. Samson with detachable rear dribble bar).
    -- Only count NON-motorized children: a motorized vehicle in the same root
    -- group is the tractor pulling/carrying the unit, never a spreader. Some mod
    -- tractors (e.g. the Fendt 800 mod) carry their own spec_dischargeable, which
    -- would otherwise bleed a bogus spreader valve onto an attached pump.
    local root = vehicle:getRootVehicle()
    if root ~= nil and root.getChildVehicles ~= nil then
        for _, v in ipairs(root:getChildVehicles()) do
            if v ~= vehicle and v.spec_dischargeable ~= nil and v.spec_motorized == nil then
                return true
            end
        end
    end
    return false
end

-- Returns all child vehicles attached to the same root that are NOT SPS-registered
-- and have a TurnOnVehicle spec — i.e. rear dribble bars / spreader attachments.
-- The SPS spreader valve drives their TurnOnVehicle state: open -> setIsTurnedOn(true),
-- close -> auto-off via getCanBeTurnedOn / TurnOnVehicle.turnOffIfNotAllowed.
function SlurryPipeManager:findAttachedDribbleBars(vehicle)
    local bars = {}
    local root = vehicle:getRootVehicle()
    if root == nil or root.getChildVehicles == nil then return bars end
    for _, v in ipairs(root:getChildVehicles()) do
        -- A child counts as a controllable dribble bar if it is a turn-on implement
        -- that is NOT itself a slurry tanker. A bar registered only for blockage nodes
        -- (isSpreaderImplement) is allowed through — being SPS-registered for blockages
        -- must not hide it from its controlling tanker.
        if v ~= vehicle and v.spec_turnOnVehicle ~= nil then
            local vEntry = self:getVehicleEntry(v)
            local isTanker = (vEntry ~= nil) and (vEntry.isSpreaderImplement ~= true)
            if not isTanker then
                table.insert(bars, v)
            end
        end
    end
    return bars
end

function SlurryPipeManager:onActionToggleSpreader(vehicle)
    SlurryPipeManager.log("onActionToggleSpreader: %s", tostring(vehicle and vehicle.configFileName))
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local newOpen = not state.spreaderValveOpen
    -- MA/Bayern: hydraulic hoses must be connected to open the spreader valve
    -- (same gate the fill-arm flow valve uses in onActionToggleFlow).
    if newOpen then
        if not SlurryPipeSystemOverride.isHydraulicsConnected(vehicle) then
            if vehicle.isClient then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsConnectHydraulics"), 2000)
            end
            return
        end
    end
    -- The spreader can only discharge, so it may only open when the pump is set to
    -- Pressure (DISCHARGE). Pump state is irrelevant — stored pressure drives the
    -- spread. (The fill arm, by contrast, may open in either direction.)
    if newOpen and state.direction ~= SPS_DIRECTION_DISCHARGE then
        if vehicle.isClient then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSetToPressure"), 2000)
        end
        return
    end
    if g_server ~= nil then
        state.spreaderValveOpen = newOpen
        SPSSpreaderValveEvent.sendEvent(vehicle, newOpen)
        self:updateActionEventTexts(vehicle)
    else
        -- MP CLIENT: apply locally (server rebroadcast excludes the sender), else the
        -- next toggle recomputes from stale state and the action gets stuck.
        state.spreaderValveOpen = newOpen
        SPSSpreaderValveEvent.sendEvent(vehicle, newOpen)
        self:updateActionEventTexts(vehicle)
    end
end

-- ---------------------------------------------------------------------------
-- Blockage system (dribble bar / spreader)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:getBlockageEntries(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return {} end
    return entry.blockageEntries or {}
end

function SlurryPipeManager:isMaceratorBlocked(vehicle)
    for _, b in ipairs(self:getBlockageEntries(vehicle)) do
        if b.isMacerator and b.blocked then return true end
    end
    return false
end

function SlurryPipeManager:getBlockageFlowFraction(vehicle)
    if not self:isFeatureEnabled("blockages") then return 1.0 end
    local list = self:getBlockageEntries(vehicle)
    if #list == 0 then return 1.0 end
    if self:isMaceratorBlocked(vehicle) then return 0.0 end
    local outlets, open = 0, 0
    for _, b in ipairs(list) do
        if not b.isMacerator then
            outlets = outlets + 1
            if not b.blocked then open = open + 1 end
        end
    end
    if outlets == 0 then return 1.0 end
    return open / outlets
end

-- The tanker whose spread state controls a node-bearing implement (walk up attachers).
function SlurryPipeManager:getBlockageController(nodeOwner)
    local v, guard = nodeOwner, 0
    while v ~= nil and guard < 8 do
        if self:vehicleHasSpreader(v) and not self:isSpreaderImplement(v) then return v end
        if v.getAttacherVehicle == nil then break end
        local up = v:getAttacherVehicle()
        if up == nil or up == v then break end
        v = up; guard = guard + 1
    end
    return nodeOwner
end

function SlurryPipeManager:updateBlockages(dt)
    if g_server == nil then return end
    if not self:isFeatureEnabled("blockages") then return end
    for _, entry in ipairs(self.registeredVehicles) do
        local vehicle = entry.vehicle
        local list    = entry.blockageEntries
        if list ~= nil and #list > 0 then
            local controller = self:getBlockageController(vehicle)
            local cstate     = self:getVehicleState(controller)
            -- Only roll for blockages while ACTUALLY spreading: discharge active (pump/
            -- pressure) AND the spreader valve open. isSpreaderDischargeActive alone is
            -- true for an HVP tanker whenever the pump runs and for a vacuum tanker
            -- whenever pressure is built in the discharge direction — both of which can
            -- hold during a FILL (spreader valve shut), which previously popped the
            -- blockage warning while nothing was being spread. The valve gate fixes that.
            -- [SPS AI GATE] never roll blockages while AI drives — vanilla spreading.
            if self:isSpreaderDischargeActive(controller)
               and cstate ~= nil and cstate.spreaderValveOpen == true
               and not self:isAIControlled(controller) then
                entry.blockageRollTimer = (entry.blockageRollTimer or 0) + dt
                if entry.blockageRollTimer >= SlurryPipeManager.BLOCKAGE_ROLL_INTERVAL then
                    entry.blockageRollTimer = 0
                    -- [SPS BLOCKAGE v1.0.0.10.4] Blockages are driven by the CRUST
                    -- (un-mixed lumpiness) the tanker carries, since mixing the store is
                    -- what clears it. Dry matter is only a mild amplifier -- its real job
                    -- is slowing the pump (getFlowRateMultiplier), not clogging the bar.
                    --
                    -- The macerator is a lump smasher with a finite capacity, so the two
                    -- rows now have SEPARATE crust thresholds:
                    --   macerator: exposed from BLOCKAGE_MACERATOR_CRUST_MIN upward -- it
                    --              is the part taking the punishment.
                    --   outlets:   protected until BLOCKAGE_OUTLET_CRUST_MIN, the point at
                    --              which lumps start getting past the macerator. A bar with
                    --              NO macerator node gets no protection and uses the lower
                    --              BLOCKAGE_OUTLET_CRUST_MIN_RAW instead.
                    --
                    -- Any of these may be overridden per vehicle via entry.blockageTuning
                    -- (attributes on the <blockageNodes> container); nil falls back to the
                    -- global default.
                    local tune = entry.blockageTuning or {}
                    local baseChance  = tune.baseChance        or SlurryPipeManager.BLOCKAGE_BASE_CHANCE
                    local macCrustMin = tune.maceratorCrustMin or SlurryPipeManager.BLOCKAGE_MACERATOR_CRUST_MIN
                    local macSlope    = tune.maceratorChance   or SlurryPipeManager.BLOCKAGE_MACERATOR_CHANCE
                    local outSlope    = tune.outletChance      or SlurryPipeManager.BLOCKAGE_OUTLET_CHANCE
                    local dmBonus     = tune.dmBonus           or SlurryPipeManager.BLOCKAGE_DM_BONUS

                    -- Is a macerator actually fitted to THIS bar? Drives which outlet
                    -- threshold applies and whether the macerator row is rolled at all.
                    local hasMacerator = false
                    for _, b in ipairs(list) do
                        if b.isMacerator then hasMacerator = true break end
                    end
                    local outCrustMin
                    if hasMacerator then
                        outCrustMin = tune.outletCrustMin    or SlurryPipeManager.BLOCKAGE_OUTLET_CRUST_MIN
                    else
                        outCrustMin = tune.outletCrustMinRaw or SlurryPipeManager.BLOCKAGE_OUTLET_CRUST_MIN_RAW
                    end

                    local crust = self:getTankerCrust(controller)
                    -- 0 at the threshold, 1 at fully crusted.
                    -- [SPS 1.0.1.4] nil minCrust is treated as "no crust-driven
                    -- risk" (base chance only) rather than crashing. This runs
                    -- inside update(), so a nil here spammed the log every roll
                    -- interval (issue #26). The global fallbacks in
                    -- SlurryPipeManager now cover every attribute, so this is
                    -- belt-and-braces for third-party configs only.
                    local function crustRamp(minCrust)
                        if minCrust == nil then return 0.0 end
                        if crust <= minCrust then return 0.0 end
                        local span = 1.0 - minCrust
                        if span <= 0 then return 1.0 end
                        return math.min(1.0, math.max(0.0, (crust - minCrust) / span))
                    end

                    local dmSpan  = SlurryPipeManager.DM_JAMMED - SlurryPipeManager.DM_FRESH
                    local dmFac   = dmSpan > 0 and ((self:gaugeToDM(self:getTankerThickness(controller)) - SlurryPipeManager.DM_FRESH) / dmSpan) or 0
                    dmFac         = math.min(1.0, math.max(0.0, dmFac))
                    local dmMult  = 1.0 + dmBonus * dmFac

                    -- [SPS 1.0.1.4] Only meaningful when a macerator is fitted;
                    -- the roll below is already gated on hasMacerator, so a bar
                    -- without one no longer evaluates a threshold it has no
                    -- reason to define (issue #26).
                    local maceratorChance = 0.0
                    if hasMacerator then
                        maceratorChance = (baseChance + macSlope * crustRamp(macCrustMin)) * dmMult
                    end
                    local outletChance    = (baseChance + outSlope * crustRamp(outCrustMin)) * dmMult

                    -- A blocked macerator already stops the whole bar, so nothing is
                    -- flowing and neither row is rolled while it stands.
                    if not self:isMaceratorBlocked(vehicle) then
                        -- The two rows now roll INDEPENDENTLY. Previously the outlets were
                        -- only rolled on ticks where the macerator did not block, which
                        -- perversely gave the outlets FEWER chances the worse the slurry got.
                        if hasMacerator and math.random() < maceratorChance then
                            for _, b in ipairs(list) do
                                if b.isMacerator then self:setBlockageState(vehicle, b, true) end
                            end
                        end

                        -- ONE roll for the bar, then a random still-open outlet takes it.
                        -- Rolling per outlet made a wide bar inherently more clog-prone than
                        -- a narrow one purely for having more nodes: at the old per-outlet
                        -- base chance a 12-outlet bar suffered a foreign-object clog on
                        -- roughly 6 loads in 10 of perfectly clean, freshly mixed slurry.
                        local open = {}
                        for _, b in ipairs(list) do
                            if not b.isMacerator and not b.blocked then
                                open[#open + 1] = b
                            end
                        end
                        if #open > 0 and math.random() < outletChance then
                            self:setBlockageState(vehicle, open[math.random(#open)], true)
                        end
                    end
                end
            else
                entry.blockageRollTimer = 0
            end
        end
    end
end

function SlurryPipeManager:getBlockageNodeIndex(vehicle, blockageEntry)
    local list = self:getBlockageEntries(vehicle)
    for i, b in ipairs(list) do if b == blockageEntry then return i end end
    return nil
end

function SlurryPipeManager:setBlockageState(vehicle, blockageEntry, blocked, noEventSend)
    SlurryPipeManager.log("setBlockageState: %s blocked=%s", tostring(vehicle and vehicle.configFileName), tostring(blocked))
    if blockageEntry == nil or blockageEntry.blocked == blocked then return end
    blockageEntry.blocked = blocked
    self:playBlockageAnimation(vehicle, blockageEntry, blocked)
    if blocked and vehicle.isClient then
        -- Name what blocked so the player knows whether it's the whole-bar macerator
        -- (everything stops) or a single outlet section (only that strip stops).
        local msg
        if blockageEntry.isMacerator then
            msg = g_i18n:getText("warning_spsBlockageMacerator")
        else
            -- Friendly label from the node name, e.g. SPS_blockageNodeLeft01 -> "Left 01".
            local label = tostring(blockageEntry.name or "")
            label = label:gsub("^SPS_blockageNode", "")
            label = label:gsub("(%a)(%d)", "%1 %2")
            if label == "" then label = "outlet" end
            msg = string.format(g_i18n:getText("warning_spsBlockageSection"), label)
        end
        g_currentMission:showBlinkingWarning(msg, 2500)
    end
    if not noEventSend and SPSBlockageEvent ~= nil then
        local idx = self:getBlockageNodeIndex(vehicle, blockageEntry)
        if idx ~= nil then SPSBlockageEvent.sendEvent(vehicle, idx, blocked) end
    end
end

function SlurryPipeManager:applyBlockageByIndex(vehicle, index, blocked)
    local b = self:getBlockageEntries(vehicle)[index]
    if b ~= nil then self:setBlockageState(vehicle, b, blocked, true) end
end

function SlurryPipeManager:playBlockageAnimation(vehicle, blockageEntry, blocked)
    local animName = blockageEntry.blockageAnimation
    if animName == nil or animName == "" then return end
    if vehicle.playAnimation == nil or not vehicle.isClient then return end
    vehicle:playAnimation(animName, blocked and 1 or -1, nil, true)
end

function SlurryPipeManager:clearAllBlockages(vehicle)
    SlurryPipeManager.log("clearAllBlockages: %s", tostring(vehicle and vehicle.configFileName))
    local n = 0
    for _, b in ipairs(self:getBlockageEntries(vehicle)) do
        if b.blocked then self:setBlockageState(vehicle, b, false); n = n + 1 end
    end
    return n
end

function SlurryPipeManager:clearNearestBlockage(vehicle, px, py, pz)
    SlurryPipeManager.log("clearNearestBlockage: %s at (%.2f,%.2f,%.2f)", tostring(vehicle and vehicle.configFileName), px or 0, py or 0, pz or 0)
    local best, bestDist = nil, SlurryPipeManager.BLOCKAGE_CLEAR_RADIUS
    for _, b in ipairs(self:getBlockageEntries(vehicle)) do
        if b.blocked and b.node ~= nil then
            local nx, ny, nz = getWorldTranslation(b.node)
            local d = MathUtil.vector3Length(nx - px, ny - py, nz - pz)
            if d <= bestDist then best, bestDist = b, d end
        end
    end
    if best ~= nil then self:setBlockageState(vehicle, best, false) end
    return best
end

-- Pressure (bar) below which a vacuum line counts as "vented" for clearing.
SlurryPipeManager.BLOCKAGE_CLEAR_PRESSURE_EPS = 0.05

-- Whether a blockage on this spreader may be cleared right now. Gated on the bar being
-- stopped, which differs by the controlling tanker's drive model: a vacuum tanker must
-- have vented back to ~0 bar; an HVP / pump-gated tanker must have its pump off. (You
-- cannot unclog a live, pressurised bar.)
function SlurryPipeManager:canClearBlockage(vehicle)
    local controller = self:getBlockageController(vehicle)
    if controller == nil then return false end
    local state = self:getVehicleState(controller)
    if state == nil then return false end
    if self:usesPressureModel(controller) then
        return math.abs(state.pressure or 0) <= SlurryPipeManager.BLOCKAGE_CLEAR_PRESSURE_EPS
    end
    return state.pumpRunning ~= true
end

-- Player-initiated clear of one specific blockage node (from its walk-up activatable).
-- Re-checks the stop gate, then clears + syncs via setBlockageState (SPSBlockageEvent).
function SlurryPipeManager:onClearBlockage(vehicle, blockageEntry)
    SlurryPipeManager.log("onClearBlockage: %s", tostring(vehicle and vehicle.configFileName))
    if blockageEntry == nil or blockageEntry.blocked ~= true then return end
    if not self:canClearBlockage(vehicle) then return end
    self:setBlockageState(vehicle, blockageEntry, false)
end

-- Spreader discharge is driven by stored pressure, not the PTO. For a pressure
-- tanker it is active when set to Pressure (DISCHARGE) and pressure is at/above
-- the flow threshold; for exempt endpoints (HVP / open-top FRC / conduit / fert-herb
-- sprayer / no <pressure> block) it falls back to the pump state. Used by the spreader
-- discharge / work-area gates in ManureBarrelOverride.
function SlurryPipeManager:isSpreaderDischargeActive(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil or entry.state == nil then return false end
    local state = entry.state
    local cfg   = entry.pressure
    if not self:usesPressureModel(entry) then
        return state.pumpRunning == true
    end
    if state.direction ~= SPS_DIRECTION_DISCHARGE then return false end
    return (state.pressure or 0) >= cfg.minThreshold
end

-- True when the spreader's spraying component should be TURNED ON. Discharge is
-- driven by SPS state, not by the pump press or fold: it should be on while the
-- pump is running (building/holding), OR while a spreader valve is open and stored
-- pressure is still discharging (isSpreaderDischargeActive). Used by the turn-state
-- driver in update() and by the setIsTurnedOn guard so vanilla fold/turn calls can't
-- fight it.
function SlurryPipeManager:getSpreaderAnimationName(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    return entry ~= nil and entry.spreaderAnimationName or nil
end

-- Drives the SPS-managed spreader animation from actual discharge. Plays as soon
-- as the valve is open AND slurry is flowing. When flow stops, it does NOT cut the
-- animation immediately — it runs a tail-off (spreaderAnimationStopDelay) so the
-- boom keeps moving while the last of the slurry drains out, matching the discharge
-- effect's fade. If flow resumes during the tail, the stop is cancelled.
function SlurryPipeManager:updateSpreaderAnimations(dt)
    for _, entry in ipairs(self.registeredVehicles) do
        local vehicle = entry.vehicle
        if entry.spreaderAnimationName ~= nil and vehicle ~= nil
           and vehicle.isClient and vehicle.playAnimation ~= nil then
            local controller = self:getBlockageController(vehicle)
            local cstate     = self:getVehicleState(controller)
            -- "Poo is actually being spread" requires slurry in the controlling tank.
            -- Without this, a vacuum tank with the valve open and stored pressure still
            -- above minThreshold would animate the boom on an empty tank. When the tank
            -- drains to 0 mid-spread this goes false and the tail-off below stops it.
            local centry     = self:getVehicleEntry(controller)
            local _, clevel  = self:getPressureFillRatio(controller, centry)
            local hasSlurry  = (clevel ~= nil and clevel > 0)
            local active = self:isSpreaderDischargeActive(controller)
                and cstate ~= nil and cstate.spreaderValveOpen == true
                and hasSlurry

            if active then
                -- Flowing: cancel any pending stop, start the clip if not already running.
                -- Self-healing: vanilla Sprayer:onTurnedOff unconditionally stops/reverses
                -- its own named animations when SPS issues setIsTurnedOn(false) at PTO-off;
                -- if the vehicle names this same clip there, our running clip gets killed
                -- externally. So re-assert whenever the clip is not actually playing.
                entry._spreadAnimTail = nil
                local playing = vehicle.getIsAnimationPlaying == nil
                    or vehicle:getIsAnimationPlaying(entry.spreaderAnimationName)
                if entry._spreadAnimOn ~= true then
                    entry._spreadAnimOn = true
                    vehicle:playAnimation(entry.spreaderAnimationName, 1,
                        vehicle:getAnimationTime(entry.spreaderAnimationName), true)
                elseif not playing then
                    vehicle:playAnimation(entry.spreaderAnimationName, 1,
                        vehicle:getAnimationTime(entry.spreaderAnimationName), true)
                end
            elseif entry._spreadAnimOn == true then
                -- Flow stopped: run the tail-off, then stop once it expires.
                -- Keep the clip alive through the tail if something stops it externally.
                if entry._spreadAnimTail == nil then
                    entry._spreadAnimTail = entry.spreaderAnimationStopDelay or 2000
                end
                entry._spreadAnimTail = entry._spreadAnimTail - dt
                if entry._spreadAnimTail <= 0 then
                    entry._spreadAnimTail = nil
                    entry._spreadAnimOn = false
                    vehicle:stopAnimation(entry.spreaderAnimationName, true)
                else
                    local playing = vehicle.getIsAnimationPlaying == nil
                        or vehicle:getIsAnimationPlaying(entry.spreaderAnimationName)
                    if not playing then
                        vehicle:playAnimation(entry.spreaderAnimationName, 1,
                            vehicle:getAnimationTime(entry.spreaderAnimationName), true)
                    end
                end
            end
        end
    end
end

function SlurryPipeManager:shouldSpreaderBeOn(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return false end
    -- The TURN-ON state (green icon, PTO spin, PTO power load / working engine
    -- sound) follows the pump button ONLY. Pressing PTO off at the headland must
    -- immediately whiten the tanker icon, disengage the PTO and drop the working
    -- sound — even though the spreader valve stays open and stored pressure keeps
    -- pumping slurry out. The discharge itself is NOT driven from here: it runs off
    -- the stored-pressure gate in the work-area / discharge overrides (which no
    -- longer require turnOn), so spreading continues to taper while this is false.
    return state.pumpRunning == true
end

-- ---------------------------------------------------------------------------
-- Shear bolt: state query, repair gate, repair, and MP apply
-- ---------------------------------------------------------------------------
function SlurryPipeManager:isShearBoltSnapped(vehicle)
    local state = self:getVehicleState(vehicle)
    return state ~= nil and state.shearSnapped == true
end

-- Repair is allowed only with the tractor PTO off AND the engine stopped.
function SlurryPipeManager:canRepairShearBolt(vehicle)
    if not self:isShearBoltSnapped(vehicle) then return false end
    -- PTO off (the tanker is not turned on).
    if vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() then return false end
    local state = self:getVehicleState(vehicle)
    if state ~= nil and state.pumpRunning == true then return false end
    -- Engine stopped.
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if root ~= nil and root.getIsMotorStarted ~= nil and root:getIsMotorStarted() then
        return false
    end
    return true
end

function SlurryPipeManager:repairShearBolt(vehicle)
    if SPSShearBolt == nil then return end
    if not self:canRepairShearBolt(vehicle) then return end
    SPSShearBolt.repair(self, vehicle)
end

-- Called by SPSShearBoltEvent on receiving peers (and directly on the trigger peer).
function SlurryPipeManager:applyShearBoltState(vehicle, snapped)
    if SPSShearBolt == nil then return end
    SPSShearBolt.applyState(self, vehicle, snapped)
end
