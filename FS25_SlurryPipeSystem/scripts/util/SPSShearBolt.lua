-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4
--
-- SPSShearBolt.lua
-- FS25_SlurryPipeSystem
--
-- Shear bolt on the PTO drive of a vacuum tanker. Using the PTO through repeated
-- hard turns wears the bolt; once it snaps the pump is disconnected, so the tank no
-- longer builds or holds vacuum/pressure. The PTO request stays on (engine revs
-- unchanged); only the pump effect dies. The spread continues off stored pressure
-- until it runs out or the valve is closed.
--
-- The bolt is replaced on foot at the outside-control node by holding the rebindable
-- SPS_REPAIR_SHEARBOLT action for REPAIR_SECONDS, but only with the tractor PTO off
-- and the engine stopped (see SlurryPipeManager:canRepairShearBolt).
--
-- VISUAL: the connecting PTO shaft's spinners live on the tanker's
-- spec_powerTakeOffs.inputPowerTakeOffs[i].animationNodes (the long visible shaft —
-- on the stock walterscheidP that is rotationPart01..04 plus the four ShakeAnimation
-- nodes), and the implement-side spinners on .localAnimationNodes. On a snap we STOP
-- THE WHOLE SHAFT — every node. We prefer g_animationManager:stopAnimation (the same
-- call vanilla PowerTakeOffs uses to turn a shaft off): ShakeAnimation fades its
-- "shaking" shader to 0, RotationAnimation winds its speed down. Animation classes that
-- implement reset() but not stop() fall back to resetAnimation, so this never calls a
-- nil method and can't break the snap/repair path. The stop is re-asserted every tick
-- while snapped. The tractor's own output spinner (connectedOutput.localAnimationNodes)
-- is left to vanilla — it belongs to the tractor, not the detachable shaft.
--
-- Do NOT plain-resetAnimation a ShakeAnimation to stop it: reset() drops it from the
-- running set and only zeroes Lua state, so its "shaking" shader sticks at the last
-- value and the node jiggles forever. stop() is what actually halts it.
--
-- All state is server-authoritative. Wear accrues on the server only; snap/repair
-- sync to clients via SPSShearBoltEvent, which calls applyState so the visual
-- freeze/restore happens on every peer.

SPSShearBolt = {}

-- ===========================================================================
-- DEBUG LOGGING — flip this to false (or delete this block + the dbg() calls)
-- to remove all shear-bolt logging. SPSShearBoltEvent and SPSShearBoltActivatable
-- read this same switch.
-- ===========================================================================
SPSShearBolt.DEBUG = false

local function dbg(msg)
    if SPSShearBolt.DEBUG then
        -- Direct print so this switch is self-contained and does NOT depend on
        -- SlurryDebug.enabled (which is false in release and would swallow these).
        print("[SPS Shear] " .. tostring(msg))
    end
end
SPSShearBolt.dbg = dbg   -- shared with the event / activatable files

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
-- How far the wheel must be turned (|axisSide|, 0..1) before the bolt takes any
-- strain. Gentle/short corrections below this add no wear.
SPSShearBolt.TURN_DEADZONE   = 0.55
-- Seconds of sustained FULL lock, under PTO load and moving, to go 0 -> snapped.
-- Partial lock scales linearly: half-past-the-deadzone wears at half rate.
SPSShearBolt.SNAP_SECONDS    = 40.0
-- Minimum ground speed (km/h) for a turn to count as a working headland turn.
SPSShearBolt.MIN_SPEED_KMH   = 1.0

-- ---------------------------------------------------------------------------
-- Per-tick wear / freeze (called from SlurryPipeManager:updatePressure, vac only)
-- ---------------------------------------------------------------------------
function SPSShearBolt.update(manager, vEntry, dt)
    if vEntry == nil then return end
    local vehicle = vEntry.vehicle
    local state   = vEntry.state
    if vehicle == nil or state == nil then return end

    -- Already snapped: re-assert the freeze on all peers (cheap; guards against
    -- vanilla restarting the nodes after a PTO edge). No logging on the re-assert.
    if state.shearSnapped == true then
        SPSShearBolt.setVisualFrozen(vehicle, true, false)
        return
    end

    -- Wear accrues on the server only.
    if g_server == nil then return end

    -- Only wears while the PTO is actually driving the pump.
    if state.pumpRunning ~= true then return end

    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if root == nil or root.spec_drivable == nil then return end

    -- Must be moving (a parked tractor steering on the spot does not load the bolt).
    local speed = (root.getLastSpeed ~= nil) and root:getLastSpeed() or 0
    if speed < SPSShearBolt.MIN_SPEED_KMH then return end

    local lock = math.abs(root.spec_drivable.axisSide or 0)
    if lock <= SPSShearBolt.TURN_DEADZONE then return end

    local dz     = SPSShearBolt.TURN_DEADZONE
    local factor = (lock - dz) / (1 - dz)               -- 0 at deadzone, 1 at full lock
    local perSec = (SPSShearBolt.SNAP_SECONDS > 0) and (1 / SPSShearBolt.SNAP_SECONDS) or 1
    local add    = factor * perSec * (dt * 0.001)

    local old = state.shearWear or 0
    state.shearWear = old + add

    -- Throttled wear log: only when crossing a 10% boundary (no per-tick spam).
    if SPSShearBolt.DEBUG and math.floor(state.shearWear * 10) > math.floor(old * 10) then
        dbg(string.format("wear %.0f%% (lock=%.2f speed=%.1f) %s",
            state.shearWear * 100, lock, speed, tostring(vehicle.configFileName)))
    end

    if state.shearWear >= 1.0 then
        state.shearWear = 1.0
        SPSShearBolt.snap(manager, vehicle)
    end
end

-- ---------------------------------------------------------------------------
-- Snap / repair (server triggers; both sync via SPSShearBoltEvent)
-- ---------------------------------------------------------------------------
function SPSShearBolt.snap(manager, vehicle)
    if vehicle == nil or manager == nil then return end
    local state = manager:getVehicleState(vehicle)
    if state == nil or state.shearSnapped == true then return end
    dbg("bolt SNAPPED on " .. tostring(vehicle.configFileName))
    SPSShearBolt.applyState(manager, vehicle, true)
    if SPSShearBoltEvent ~= nil then
        SPSShearBoltEvent.sendEvent(vehicle, true)
    end
end

function SPSShearBolt.repair(manager, vehicle)
    if vehicle == nil or manager == nil then return end
    local state = manager:getVehicleState(vehicle)
    if state == nil or state.shearSnapped ~= true then return end
    dbg("bolt REPAIRED on " .. tostring(vehicle.configFileName))
    SPSShearBolt.applyState(manager, vehicle, false)
    if SPSShearBoltEvent ~= nil then
        SPSShearBoltEvent.sendEvent(vehicle, false)
    end
end

-- Apply the snapped/cleared state locally (called directly on the triggering peer,
-- and by SPSShearBoltEvent:run on receiving peers).
function SPSShearBolt.applyState(manager, vehicle, snapped)
    if vehicle == nil or manager == nil then return end
    local state = manager:getVehicleState(vehicle)
    if state == nil then return end
    state.shearSnapped = snapped == true
    if snapped then
        state.shearWear = 1.0
        SPSShearBolt.setVisualFrozen(vehicle, true, true)   -- verbose freeze log
        if g_currentMission ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsShearBoltSnapped"), 4000)
        end
    else
        state.shearWear = 0
        -- PTO must be off to repair, so the nodes are already stopped and vanilla
        -- restarts them all on the next PTO turn-on. Only resume if still active.
        if vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() then
            SPSShearBolt.setVisualFrozen(vehicle, false, true)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Visual: freeze (instant, in place) / resume the PTO shaft animation nodes.
-- On a snap the WHOLE shaft freezes — every connecting-shaft node and every
-- implement-side local node. Nothing is kept spinning.
-- verbose = log what was found/frozen (used once on snap, not on per-tick re-assert)
-- ---------------------------------------------------------------------------
function SPSShearBolt.setVisualFrozen(vehicle, frozen, verbose)
    if vehicle == nil or g_animationManager == nil then return end
    local spec = vehicle.spec_powerTakeOffs
    if spec == nil then
        if verbose then dbg("freeze: vehicle has no spec_powerTakeOffs") end
        return
    end
    if spec.inputPowerTakeOffs == nil then
        if verbose then dbg("freeze: no inputPowerTakeOffs") end
        return
    end

    -- Freeze (or resume) an entire animation-node array — no exclusions.
    local function apply(nodes)
        local n = 0
        if nodes == nil then return 0 end
        for i = 1, #nodes do
            local anim = nodes[i]
            if anim ~= nil then
                if frozen then
                    -- stop() is the canonical "turn this shaft off" call (the same one
                    -- vanilla PowerTakeOffs uses): ShakeAnimation fades its "shaking"
                    -- shader to 0, RotationAnimation winds its speed down. But a few
                    -- animation classes implement reset() and NOT stop(); calling a nil
                    -- stop() throws (AnimationManager:stopAnimation calls anim:stop()
                    -- even after printing a callstack). So only stop() the ones that
                    -- actually have it, and fall back to reset() for the rest — this can
                    -- never call a nil method, so it can't break the snap path.
                    if type(anim.stop) == "function" then
                        g_animationManager:stopAnimation(anim)
                    else
                        g_animationManager:resetAnimation(anim)
                    end
                else
                    g_animationManager:startAnimation(anim)
                end
                n = n + 1
            end
        end
        return n
    end

    local inputCount, shaftFrozen, localFrozen = 0, 0, 0
    for _, input in ipairs(spec.inputPowerTakeOffs) do
        local an  = input.animationNodes
        local lan = input.localAnimationNodes
        local outLan = input.connectedOutput ~= nil and input.connectedOutput.localAnimationNodes or nil
        if (an ~= nil and #an > 0) or (lan ~= nil and #lan > 0) then
            inputCount = inputCount + 1
            if verbose then
                dbg(string.format("freeze: input nodeSets shaft=%d localImpl=%d localOutput=%d connected=%s",
                    an and #an or 0, lan and #lan or 0, outLan and #outLan or 0,
                    tostring(input.connectedVehicle ~= nil)))
                -- One-time per-node breakdown: which class, and does it support stop()?
                -- Tells us the spin node's type without needing RotationAnimation.lua.
                if an ~= nil then
                    for i = 1, #an do
                        local a = an[i]
                        if a ~= nil then
                            local isShake = ShakeAnimation ~= nil and a.isa ~= nil and a:isa(ShakeAnimation)
                            dbg(string.format("  shaft[%d]: hasStop=%s isShake=%s hasReset=%s",
                                i, tostring(type(a.stop) == "function"),
                                tostring(isShake), tostring(type(a.reset) == "function")))
                        end
                    end
                end
            end
            -- Connecting shaft (the long visible PTO) — freeze every node.
            shaftFrozen = shaftFrozen + apply(an)
            -- Implement-side local spinners stop fully (they are on the pump side).
            localFrozen = localFrozen + apply(lan)
            -- NOTE: connectedOutput.localAnimationNodes are on the TRACTOR side and
            -- are left to vanilla (the tractor keeps driving; vanilla restarts them on
            -- the next PTO turn-on). Freeze them here too only if the tractor-end cap
            -- is seen still spinning after a snap.
        end
    end
    if verbose then
        dbg(string.format("freeze=%s -> shaftNodes=%d localNodes=%d across %d input PTO(s)",
            tostring(frozen), shaftFrozen, localFrozen, inputCount))
    end
end