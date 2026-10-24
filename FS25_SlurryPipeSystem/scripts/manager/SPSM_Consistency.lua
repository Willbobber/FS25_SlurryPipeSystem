-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.5

-- SPSM_Consistency.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: dry matter, thickness, crust, store pools, agitation blending.
-- PURE RELOCATION from scripts/manager/SlurryPipeManager.lua (V1.0.0.8 tag):
-- every function body in this file is byte-identical to the baseline.
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSM_Consistency 1.0.1.5 loaded") end

-- [SPS 1.0.1.5] Litres below which a store counts as EMPTY for the thickness
-- model. dm = solids/total mathematically diverges as total -> 0 whenever the
-- draw bias exceeds 1 (solids shrink slower than volume by construction), so on
-- the last litres the solids clamp can pin solids == total, DM reads 100% and a
-- visually empty store demands water. Inside this dead-band the pile is treated
-- as clean: gauge 0, pools zeroed, full flow — the store drains to true zero.
-- Defined here (this module loads after the core manager) so only two files
-- change; guarded so a future manager-side definition wins.
if SlurryPipeManager.STORE_EMPTY_EPS == nil then
    SlurryPipeManager.STORE_EMPTY_EPS = 25.0
end


-- [SPS MP] Apply a replicated store crust/thickness state on a client. Sets the two
-- pool values, raises the crust plane (settle * maxRise) and refreshes crust foliage
-- visibility (which also feeds the thickness/crust HUD via getApparentThickness). The
-- store placeable, crust plane and foliage instances all exist on the client already;
-- only the server-computed values were missing, so nothing is created here.
-- Returns true when applied. If the store has not registered on this client yet (join
-- burst arrives before the placeable finishes SPS-registration), the value is queued
-- and retried by _tryResolveMPPending as placeables register — without this the join
-- dump was dropped and the store only corrected on the next live change.
-- [SPS 1.0.1.8] storeIndex (1-based, getStoreSources order) picks WHICH store of a multi-store placeable the value
-- belongs to - it was sent by the server but ignored here, so every store's crust landed on the primary one.
function SlurryPipeManager:applyStoreCrustState(placeable, solids, settle, fromDrain, storeIndex)
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.placeable == placeable and pEntry.sourceEntry ~= nil then
            local se = self:getStoreSourceByIndex(pEntry, storeIndex) or pEntry.sourceEntry
            se.solids = solids
            se.settle = settle
            if se.crustPlaneNode ~= nil and se.crustPlaneNode ~= 0 then
                setTranslation(se.crustPlaneNode, 0, settle * (se.crustMaxRise or 0), 0)
            end
            if SPSCrustVegetation ~= nil then
                SPSCrustVegetation.updateVisibility(pEntry)
            end
            return true
        end
    end
    if not fromDrain then
        self:_queuePendingStoreCrust(placeable, solids, settle, storeIndex)
    end
    return false
end

-- [SPS MP] Queue a store crust value whose placeable is not registered yet. Only the
-- latest value per placeable AND store is kept (crust is absolute state, not a delta).
function SlurryPipeManager:_queuePendingStoreCrust(placeable, solids, settle, storeIndex)
    if self._pendingMPStoreCrust == nil then self._pendingMPStoreCrust = {} end
    storeIndex = storeIndex or 1
    for _, e in ipairs(self._pendingMPStoreCrust) do
        if e.placeable == placeable and (e.storeIndex or 1) == storeIndex then
            e.solids = solids
            e.settle = settle
            return
        end
    end
    table.insert(self._pendingMPStoreCrust, { placeable = placeable, solids = solids, settle = settle, storeIndex = storeIndex })
    SlurryPipeManager.logMP(string.format("[SPS MP] queued pending store crust (pending=%d)", #self._pendingMPStoreCrust))
end

-- ---------------------------------------------------------------------------
-- Slurry thickness
-- ---------------------------------------------------------------------------

-- Returns a 0.0-1.0 multiplier for flow rate based on sourceEntry thickness.
-- thickness 0.0-0.8 : linear reduction (0% thick = full flow, 80% thick = 20% flow)
-- thickness >= 0.9  : no flow
-- ---------------------------------------------------------------------------
-- Two-pool dry-matter model (stores)
-- ---------------------------------------------------------------------------

-- Map a true dry-matter fraction (solids/total) to the 0..1 thickness gauge.
function SlurryPipeManager:dmToGauge(dm)
    local lo, hi = SlurryPipeManager.DM_FRESH, SlurryPipeManager.DM_JAMMED
    if hi <= lo then return 0.0 end
    return math.max(0.0, math.min(1.0, ((dm or 0) - lo) / (hi - lo)))
end

-- Inverse: a 0..1 gauge value back to a dry-matter fraction. Used when a tanker
-- (which carries a gauge value) discharges into a store and we need real solids.
function SlurryPipeManager:gaugeToDM(gauge)
    local lo, hi = SlurryPipeManager.DM_FRESH, SlurryPipeManager.DM_JAMMED
    return lo + math.max(0.0, math.min(1.0, gauge or 0)) * (hi - lo)
end

-- Total slurry held by a store, summed across every fill type it tracks. Slurry and
-- digestate share one fillPlane and are treated as a single pile, so the dry-matter
-- maths must see the combined level rather than a single fillType's level.
function SlurryPipeManager:_getStoreTotalFill(se)
    if se == nil or se.storage == nil then return 0 end
    local levels = se.storage.getFillLevels ~= nil and se.storage:getFillLevels() or se.storage.fillLevels
    if levels ~= nil then
        -- [SPS 1.0.1.8] Sum only the store's OWN body of slurry. A husbandry Storage also
        -- holds MILK / STRAW / MANURE and (on maps without automatic water supply) the
        -- animals' drinking WATER; a BGA's holds SILAGE. Summing everything inflated the
        -- dry-matter total, so DM read low and a rise in an unrelated type was reconciled
        -- as fresh slurry. Rule: the store's declared #poolFillTypes when it has one
        -- (<slurryStores>), else the slurry-class pumpable types (LIQUIDMANURE / DIGESTATE
        -- plus the declared fillType, so a WATER-declared store still counts its water) with
        -- WATER otherwise excluded — on a slurry store a WATER level only ever exists
        -- as its own level on a store where it is drinking water, not pit volume; water
        -- pumped INTO a pit is merged into the held slurry type on deposit and so is
        -- already counted there.
        local pool  = se.poolFillTypes
        local total = 0
        for ft, lvl in pairs(levels) do
            local counts
            if pool ~= nil then
                counts = pool[ft] == true
            else
                counts = ft == se.fillType
                    or (ft ~= FillType.WATER and self:_isPumpableSourceFillType(ft))
            end
            if counts then total = total + (lvl or 0) end
        end
        return total
    end
    return (se.fillType ~= nil and (se.storage:getFillLevel(se.fillType) or 0)) or 0
end

-- Lazily initialise the two-pool fields on a storage sourceEntry. solids = litres of
-- dry matter; settle = 0..1 settling offset removed by agitation. Liquid is derived
-- live as (totalFill - solids).
function SlurryPipeManager:_ensureStorePools(se)
    if se == nil then return end
    if se.solids == nil then
        se.solids = self:_getStoreTotalFill(se) * SlurryPipeManager.DM_FRESH
    end
    if se.settle == nil then
        se.settle = se._migratedSettle or 0
        se._migratedSettle = nil
    end
    if se._lastTotal == nil then
        se._lastTotal = self:_getStoreTotalFill(se)
    end
end

-- Reconcile the dry-matter pool against the store's real total. A rise since we last
-- looked came from outside SPS (vanilla fill, AI, map, console) and is treated as fresh
-- slurry at DM_FRESH; a fall is a proportional draw. SPS transfers update _lastTotal as
-- they go, so their changes show no delta here and are not re-counted.
function SlurryPipeManager:_reconcileStorePools(se)
    if se == nil or se.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return end
    if not se.thickeningEnabled then return end
    self:_ensureStorePools(se)
    local total = self:_getStoreTotalFill(se)
    -- [SPS 1.0.0.10.4] One-shot repair of a pre-fix dry-matter pool. Set by the
    -- savegame restore in registerPlaceable when the save's #poolModelVersion is
    -- behind the current model. Runs HERE rather than at restore because this loop
    -- is server-gated and ticks well after the mission has finished loading, so the
    -- storage fill level behind _getStoreTotalFill is guaranteed live — no dependence
    -- on placeable registration order.
    --
    -- The old draw removed volume but never any solids, so the saved figure is the
    -- accumulated dry matter of every litre the store has ever held and has no upper
    -- bound. There is no history to reconstruct it from, so it is clamped to the
    -- highest value the model itself can legitimately reach: total * DM_JAMMED, i.e.
    -- a full-but-honest 100% on the gauge. Nothing is gifted (a genuinely neglected
    -- lagoon still reads jammed and still needs water) and no slurry volume is
    -- touched — but water now buys back a permanent reduction instead of evaporating
    -- the moment the level drops back.
    --
    -- Fires once per store per savegame: the flag is cleared unconditionally, and the
    -- next save writes the current #poolModelVersion so it never fires again.
    if se._spsSolidsMigrate then
        se._spsSolidsMigrate = nil
        local cap = total * SlurryPipeManager.DM_JAMMED
        local had = se.solids or 0
        if had > cap then
            se.solids = cap
            print(string.format("[SPS] repaired store dry-matter pool: solids %.0f -> %.0f L (total %.0f L, DM %.3f -> %.3f)",
                had, cap, total, total > 0 and (had / total) or 0, SlurryPipeManager.DM_JAMMED))
        end
    end
    local last  = se._lastTotal or total
    if total > last + 0.001 then
        se.solids = (se.solids or 0) + (total - last) * SlurryPipeManager.DM_FRESH
    elseif total < last - 0.001 then
        local dm = last > 0 and ((se.solids or 0) / last) or 0
        se.solids = math.max(0, (se.solids or 0) - (last - total) * dm)
    end
    se.solids   = math.max(0, math.min(se.solids or 0, total))
    se._lastTotal = total
    -- An empty store holds no slurry, so it holds no crust.
    if total <= 0 and (se.settle or 0) > 0 then se.settle = 0 end
    -- [SPS 1.0.1.5] Same rule for the near-empty dead-band: residual litres below
    -- STORE_EMPTY_EPS cannot carry a meaningful dry-matter or crust state, and
    -- leaving the pinned solids in place is what showed "add water" on an empty
    -- store. Zeroed here (server tick) so every consumer sees a clean store.
    if total < (SlurryPipeManager.STORE_EMPTY_EPS or 0) then
        se.solids = 0
        if (se.settle or 0) > 0 then se.settle = 0 end
    end
end

-- A flow warning should only blink when the player is actually working this rig:
-- sitting in its cab (active for input on the root vehicle) or stood next to it on
-- foot, within WARNING_RANGE. Without this a connected pump left running would spam
-- the warning across the whole map. Mirrors the cab guard and on-foot proximity test
-- used by the pump-control activatables.
function SlurryPipeManager:_warningIsRelevant(vehicle)
    if vehicle == nil or not vehicle.isClient then return false end
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if root ~= nil and root.getIsActiveForInput ~= nil and root:getIsActiveForInput(true) then
        return true
    end
    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        local vx, vy, vz
        if vehicle.rootNode ~= nil then
            vx, vy, vz = getWorldTranslation(vehicle.rootNode)
        elseif vehicle.components ~= nil and vehicle.components[1] ~= nil then
            vx, vy, vz = getWorldTranslation(vehicle.components[1].node)
        end
        if vx ~= nil then
            local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
            local dx, dy, dz = px - vx, py - vy, pz - vz
            local r = SlurryPipeManager.WARNING_RANGE
            if (dx*dx + dy*dy + dz*dz) <= r * r then return true end
        end
    end
    return false
end

-- True dry-matter fraction of a store right now (0..1) = solids / total.
function SlurryPipeManager:getStoreDM(se)
    if se == nil or se.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return 0 end
    self:_ensureStorePools(se)
    local total = self:_getStoreTotalFill(se)
    if total <= 0 then return 0 end
    -- [SPS 1.0.1.5] Near-empty dead-band: reconcile zeroes the pools below this
    -- on the server tick, but this getter can be read before that happens (and
    -- on a client between crust syncs). Same rule applied here so no consumer
    -- ever sees the divergent last-litres DM.
    if total < (SlurryPipeManager.STORE_EMPTY_EPS or 0) then return 0 end
    return math.max(0.0, math.min(1.0, (se.solids or 0) / total))
end

-- The player-facing thickness gauge (0..1) = gauge(DM) + settling offset, clamped.
-- Every flow / warning / display consumer reads this. Returns 0 for stores that do
-- not participate in the thickness model.
function SlurryPipeManager:getApparentThickness(se)
    if se == nil or se.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return 0 end
    if not se.thickeningEnabled then return 0 end
    self:_ensureStorePools(se)
    -- [SPS 1.0.1.5] Dead-band twin of the getStoreDM guard: a near-empty store
    -- reads gauge 0 outright, so neither residual solids nor a stale settle can
    -- surface a warning or throttle flow on the last litres.
    if self:_getStoreTotalFill(se) < (SlurryPipeManager.STORE_EMPTY_EPS or 0) then return 0 end
    local dmGauge = self:dmToGauge(self:getStoreDM(se))
    return math.max(0.0, math.min(1.0, dmGauge + (se.settle or 0)))
end

-- For depositing into a storage-plane store: returns the fillType to actually use
-- against the storage object. A slurry store is configured for slurryTank only and
-- does NOT accept WATER, so water piped or fill-armed in is converted to the store's
-- current content type (or, if empty, its configured fillPlane type) as it enters —
-- it becomes slurry or digestate. Returns just the deposit fillType.
function SlurryPipeManager:resolveStoreDepositFillType(se, incomingFillType)
    if se == nil or se.storage == nil then return incomingFillType end
    -- [SPS] This deposit is going through a specific coupler that declares its own
    -- fillType (e.g. BGA500's DIGESTATE-only coupler) — that IS the deposit type,
    -- overriding the "whatever the store already holds" guess below.
    if se.restrictFillType ~= nil then return se.restrictFillType end
    local levels = se.storage.getFillLevels ~= nil and se.storage:getFillLevels() or se.storage.fillLevels
    -- [SPS 1.0.0.9.2] Content-merge rule (field report, baseTank): a store's
    -- Storage declares the whole slurryTank CATEGORY, so levels[DIGESTATE]
    -- exists as a key (at 0) and the natively-accepts check below deposited
    -- digestate as a SECOND pool alongside the slurry instead of merging —
    -- while WATER (no key in the category) fell through to conversion and
    -- merged fine. The store's content type is whatever slurry-class liquid
    -- it already holds: any incoming pumpable liquid (slurry, digestate,
    -- water) merges into that held type. Held type = the non-water pumpable
    -- liquid with the highest level; the fillPlane-declared type wins ties
    -- for determinism. Empty store: rule inert — the first liquid in defines
    -- the content type, and vice versa (digestate first => slurry merges in).
    -- BGA is unaffected: its couplers return via restrictFillType above.
    local heldType, heldLvl = nil, 0
    if levels ~= nil then
        for ft, lvl in pairs(levels) do
            lvl = lvl or 0
            if lvl > 0 and ft ~= FillType.WATER and self:_isPumpableSourceFillType(ft) then
                if lvl > heldLvl or (lvl == heldLvl and ft == se.fillType) then
                    heldType, heldLvl = ft, lvl
                end
            end
        end
    end
    if heldType ~= nil and incomingFillType ~= heldType
    and self:_isPumpableSourceFillType(incomingFillType) then
        return heldType
    end
    if levels ~= nil and levels[incomingFillType] ~= nil then
        return incomingFillType   -- store natively accepts this type
    end
    -- Not accepted: prefer the type the store currently holds, else its native type.
    local native = se.fillType
    if levels ~= nil then
        for ft, lvl in pairs(levels) do
            -- [SPS 1.0.0.9.1] Deposit-side twin of the UKStyle cow shed straw bug:
            -- a husbandry Storage also holds STRAW, and pairs() order can put it
            -- first — an incoming type the store doesn't natively hold (e.g.
            -- DIGESTATE) would then CONVERT TO STRAW on deposit. The held-type
            -- override may only ever pick a pumpable liquid; otherwise the
            -- fillPlane-declared native type (se.fillType) stands.
            -- [SPS 1.0.0.9.2] WATER excluded too: a husbandry store natively
            -- holds drinking WATER — without this, digestate pumped into a shed
            -- whose slurry channel is empty would convert to WATER (the trough)
            -- instead of the declared LIQUIDMANURE.
            if (lvl or 0) > 0 and ft ~= FillType.WATER
            and self:_isPumpableSourceFillType(ft) then native = ft break end
        end
    end
    return native
end

function SlurryPipeManager:getFlowRateMultiplier(sourceEntry)
    if not self:isFeatureEnabled("thicknessFlow") then return 1.0 end
    if sourceEntry == nil then return 1.0 end
    if sourceEntry.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return 1.0 end
    local t = self:getApparentThickness(sourceEntry)
    if t >= 0.9 then return 0.0 end
    -- Linear: each 10% thickness = 10% flow reduction, capped at 80%
    return math.max(0.0, 1.0 - math.min(t, 0.8))
end

-- Same thickness->flow curve as getFlowRateMultiplier, but for a raw thickness value
-- (0..1). Used for the thickness a tanker CARRIES (state.thickness) so pipe-discharge
-- and (Pass 2) spreading slow down with thick slurry, exactly as filling from a thick
-- store already does.
function SlurryPipeManager:thicknessToFlowMultiplier(t)
    if not self:isFeatureEnabled("thicknessFlow") then return 1.0 end
    t = t or 0
    if t >= 0.9 then return 0.0 end
    return math.max(0.0, 1.0 - math.min(t, 0.8))
end

-- The thickness a tanker is carrying right now (0..1), or 0 if none/unknown.
function SlurryPipeManager:getTankerThickness(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return 0 end
    return state.thickness or 0
end

-- The crust/lumpiness a tanker is carrying right now (0..1). Inherited from the store's
-- un-mixed level at fill time; this is what drives spreader blockages. 0 if none/unknown.
function SlurryPipeManager:getTankerCrust(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return 0 end
    return state.crust or 0
end

-- The crust an external source carries, for inheritance on fill:
--   storage plane -> its stored crust (settle)
--   another tanker -> that tanker's carried crust
--   water / anything else -> 0 (clean)
function SlurryPipeManager:getSourceCrust(extSource)
    if extSource == nil then return 0 end
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        self:_ensureStorePools(extSource)
        return extSource.settle or 0
    end
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extSource.type == "FILL_UNIT_ONLY" then
        if extSource.vehicle ~= nil then
            return self:getTankerCrust(extSource.vehicle)
        end
    end
    return 0
end

-- Volume-weighted blend of inherited crust into a tanker as it fills (mirrors
-- applyFillThicknessBlend). Loading from a freshly-mixed store thins the carried crust;
-- loading from a long-unmixed store raises it.
function SlurryPipeManager:applyFillCrustBlend(vehicle, oldLevel, addedVol, srcCrust)
    if addedVol <= 0 then return end
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local oldC  = state.crust or 0
    local denom = (oldLevel or 0) + addedVol
    if denom <= 0 then
        state.crust = srcCrust or 0
    else
        state.crust = ((oldLevel or 0) * oldC + addedVol * (srcCrust or 0)) / denom
    end
end

-- Flow multiplier from the thickness a tanker CARRIES (used on the pipe-discharge side).
function SlurryPipeManager:getTankerThicknessMultiplier(vehicle)
    return self:thicknessToFlowMultiplier(self:getTankerThickness(vehicle))
end

-- The thickness of whatever an external source is holding, for inheritance on fill:
--   storage plane -> its stored thickness
--   another tanker (fill volume / fill unit) -> that tanker's carried thickness
--   water (type 3) / anything else -> 0 (water is never thick)
function SlurryPipeManager:getSourceThickness(extSource)
    if extSource == nil then return 0 end
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        -- A pump draws mixed slurry from below any surface crust, so the tanker inherits
        -- the store's true dry-matter level (gauge of DM), not the settled surface gauge.
        return self:dmToGauge(self:getStoreDM(extSource))
    end
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extSource.type == "FILL_UNIT_ONLY" then
        if extSource.vehicle ~= nil then
            return self:getTankerThickness(extSource.vehicle)
        end
    end
    return 0
end

-- Blends inherited thickness into a tanker as it fills. New carried thickness is the
-- volume-weighted average of what was already in the tank and what just came in:
--   new = (oldLevel*oldThk + addedVol*srcThk) / (oldLevel + addedVol)
-- so topping up from a thinner source thins the load and vice-versa. oldLevel is the
-- tank level BEFORE this tick's add.
function SlurryPipeManager:applyFillThicknessBlend(vehicle, oldLevel, addedVol, srcThk)
    if addedVol <= 0 then return end
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local oldThk = state.thickness or 0
    local denom  = (oldLevel or 0) + addedVol
    if denom <= 0 then
        state.thickness = srcThk or 0
    else
        state.thickness = ((oldLevel or 0) * oldThk + addedVol * (srcThk or 0)) / denom
    end
end

-- Returns a warning level string for the given sourceEntry thickness.
-- "none", "thickening", "thickeningWater", "needsMix", "tooThick"
function SlurryPipeManager:getThicknessWarning(sourceEntry)
    if not self:isFeatureEnabled() then return "none" end
    if sourceEntry == nil then return "none" end
    if sourceEntry.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return "none" end
    if not sourceEntry.thickeningEnabled then return "none" end
    local apparent = self:getApparentThickness(sourceEntry)
    local dmGauge  = self:dmToGauge(self:getStoreDM(sourceEntry))
    -- Jammed on dry matter alone -> mixing can't help, water needed.
    if dmGauge >= 0.9 then return "tooThick" end
    -- Jammed by settling but dry matter is fine -> agitation will free it.
    if apparent >= 0.9 then return "needsMix" end
    if apparent >= 0.8 then
        -- [SPS 1.0.1.4] The 80% band now names the remedy that actually works.
        -- apparent = gauge(DM) + settle, so the cause splits cleanly:
        --   dmGauge >= 0.8 -> the dry matter ALONE puts the store in the warning
        --       band. Mixing removes only settle and can never bring the gauge
        --       below dmGauge, so "agitation advised" was a dead end here (field
        --       report: a fresh, unsettled store concentrated by pumping showed
        --       this text and mixing did nothing). Water is the remedy.
        --   dmGauge < 0.8  -> settling is what pushed it over; mixing genuinely
        --       clears it. The original advice stands.
        if dmGauge >= 0.8 then return "thickeningWater" end
        return "thickening"
    end
    return "none"
end

-- [SPS CRUST v1.0.0.10.2] Called by every mixing source each tick while actively
-- stirring: the tractor-mounted PTO agitator (SlurryPipeManager.update) and the
-- fixed tank-mounted PTO agitator (SPSFixedAgitator.updateAll).
--
--   gameHours: game hours elapsed since this agitator last mixed, taken from the
--              shared monotonic clock via SlurryPipeManager:consumeGameHours. NOT a
--              dt-derived value -- see the clock helpers for why.
--   crustMix:  that agitator's XML speed multiplier (crustMix="2" mixes twice as
--              fast, i.e. clears a full crust in half CRUST_MIX_HOURS). nil -> 1.0.
--
-- Rate is now ABSOLUTE: a full 100% -> 0% clear takes CRUST_MIX_HOURS game hours at
-- crustMix="1", on every save regardless of daysPerPeriod. Two agitators working the
-- same store each call in with their own hours and multiplier, so their effect stacks
-- additively -- which is the intended behaviour for a second mixer.
--
-- The separator is deliberately NOT a caller here. It lowers crust by physically
-- REMOVING dry matter (SPSSeparator scales settle down in proportion to the shrinking
-- solids pool), which is a different mechanism from re-suspension and must not be
-- double-counted against the mixing clock.
function SlurryPipeManager:applyAgitation(sourceEntry, gameHours, crustMix)
    if not self:isFeatureEnabled() then return end
    if sourceEntry == nil then return end
    if sourceEntry.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return end
    if type(gameHours) ~= "number" or gameHours <= 0 then return end
    self:_ensureStorePools(sourceEntry)
    -- Mixing re-suspends settled solids: it only removes the settling offset. It can
    -- never lower the dry-matter fraction, so a store whose DM is already jammed stays
    -- jammed no matter how long it is stirred (the player must add water instead).
    if (sourceEntry.settle or 0) <= 0 then return end
    local mixHours = SlurryPipeManager.CRUST_MIX_HOURS or 2.0
    if mixHours <= 0 then return end
    local mult      = SlurryPipeManager.clampCrustMult(crustMix)
    local reduction = (gameHours / mixHours) * mult
    sourceEntry.settle = math.max(0.0, (sourceEntry.settle or 0) - reduction)
    --SlurryDebug.log("[SPS Agitation] gauge now " .. string.format("%.2f", self:getApparentThickness(sourceEntry) * 100) .. "%")
    -- Update vegetation visibility for the matching placeable. Resolved through
    -- getStoreSources so a secondary lagoon on a multi-store placeable refreshes its
    -- own crust foliage too; the old identity test against pEntry.sourceEntry only
    -- ever matched the primary store and left the others visually stale.
    -- [SPS PERF] Agitation runs every tick, and updateVisibility walks every
    -- scattered plant — refresh only when settle has moved >= 0.002 since the last
    -- foliage refresh (same quantum as the growth path and SPSStoreCrustEvent).
    if SPSCrustVegetation ~= nil
    and math.abs((sourceEntry.settle or 0) - (sourceEntry._foliageSettle or -1)) >= 0.002 then
        sourceEntry._foliageSettle = sourceEntry.settle or 0
        for _, pEntry in ipairs(self.registeredPlaceables) do
            local matched = false
            if self.getStoreSources ~= nil then
                for _, se in ipairs(self:getStoreSources(pEntry)) do
                    if se == sourceEntry then matched = true break end
                end
            elseif pEntry.sourceEntry == sourceEntry then
                matched = true
            end
            if matched then
                SPSCrustVegetation.updateVisibility(pEntry, sourceEntry)
                break
            end
        end
    end
end
