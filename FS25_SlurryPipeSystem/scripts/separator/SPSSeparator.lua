-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9.35
--
-- SPSSeparator.lua
-- ---------------------------------------------------------------------------
-- Fixed (placeable) slurry separator — screw-press model.
--
-- The separator IS the pump: while switched on it pulls whole slurry through
-- its IN coupling, removes a fraction of the dry matter as solid MANURE into
-- its own manure bunker (the placeable is type="manureHeap"), and pushes the
-- thinner liquid fraction back out through its OUT coupling to any connected
-- slurry receiver (store, tanker, anything SPS can resolve).
--
-- Model (all per-machine XML tunables, see readConfig):
--   intake L/s        = ratedLitersPerHour/3600 * throughputMult(tightness)
--                       * source thickness flow multiplier
--   captureEff        = lerp(captureEffMin, captureEffMax, tightness)
--   removed DM litres = intake * sourceDM * captureEff
--   manure litres     = removed DM / solidsDryMatter   (solids extrude ~28% DM)
--   return litres     = intake - manure litres, at reduced DM
--
-- Store draw is WHOLE-SLURRY (bias 1.0), unlike normal pumping's
-- DM_REMOVAL_LIQUID_BIAS 1.6 preferential-liquid draw: the screw press eats
-- the mixture as-is, so the store's DM falls over time instead of rising.
-- A store already at/below DM_FRESH keeps dropping — the solids pool has no
-- floor and the thickness gauge simply clamps at 0 (see SPSM_Consistency).
--
-- Integration: ZERO core-file edits. This file wraps four manager seams at
-- load time (registerPlaceable, update, sendFullStateToConnection,
-- saveCouplingConnections/loadCouplingConnections) and registers a placeable
-- detach handler ("Separator") for sell/delete teardown, exactly as the
-- 1.0.0.9.3 detach-handler registry was designed for.
--
-- MP: server-authoritative. Toggle/tightness requests go client->server via
-- SPSSeparatorEvent, the server applies and broadcasts STATE. JIP joiners get
-- a STATE event appended to the manager's join dump via the wrap below.
--
-- Manure drop VISUAL effect: implemented (1.0.0.9.27) as a manually built
-- ShaderPlaneEffect on the i3d stream shape under SPS_dropNode, with the
-- material flow verified against ShaderPlaneEffect.lua / EffectManager.lua.
-- The MATERIAL side is separate and complete: manure litres go into the
-- placeable's own ManureHeap via setFillLevel (drops physical heap material
-- across the tip area over time and MP-syncs — ManureHeap.lua, verified).
-- ---------------------------------------------------------------------------

print("[SPS BUILD] SPSSeparator 1.0.0.9.35 loaded")

SPSSeparator = {}

-- Debug: wired to the central registry (SPSDebugConfig channel "SPSSeparator").
-- The class field is pushed by SPSDebugConfig.applyAll(); the call-time isOn()
-- consult makes `spsDebug SPSSeparator on|off` take effect instantly as well.
-- Ships false. Never true in a release.
SPSSeparator.DEBUG = false
local function log(fmt, ...)
    if not (SPSSeparator.DEBUG
        or (SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSSeparator"))) then
        return
    end
    if select("#", ...) > 0 then
        print("[SPS SEPARATOR] " .. string.format(fmt, ...))
    else
        print("[SPS SEPARATOR] " .. tostring(fmt))
    end
end
SPSSeparator.log = log

-- ---------------------------------------------------------------------------
-- Block reasons (UIntN 4 on the wire). NONE while processing normally.
-- ---------------------------------------------------------------------------
SPSSeparator.REASON_NONE          = 0
SPSSeparator.REASON_NO_PIPES      = 1
SPSSeparator.REASON_NO_IN_PIPE    = 2
SPSSeparator.REASON_NO_OUT_PIPE   = 3
SPSSeparator.REASON_SOURCE_EMPTY  = 4
SPSSeparator.REASON_SOURCE_THICK  = 5
SPSSeparator.REASON_OUTPUT_FULL   = 6
SPSSeparator.REASON_RETURN_FULL   = 7
SPSSeparator.REASON_NO_SOURCE     = 8
SPSSeparator.REASON_NO_RETURN     = 9
SPSSeparator.REASON_NO_DM         = 10

SPSSeparator.REASON_L10N = {
    [SPSSeparator.REASON_NO_PIPES]     = "warning_spsSepNoPipes",
    [SPSSeparator.REASON_NO_IN_PIPE]   = "warning_spsSepNoInPipe",
    [SPSSeparator.REASON_NO_OUT_PIPE]  = "warning_spsSepNoOutPipe",
    [SPSSeparator.REASON_SOURCE_EMPTY] = "warning_spsSepSourceEmpty",
    [SPSSeparator.REASON_SOURCE_THICK] = "warning_spsSepSourceThick",
    [SPSSeparator.REASON_OUTPUT_FULL]  = "warning_spsSepOutputFull",
    [SPSSeparator.REASON_RETURN_FULL]  = "warning_spsSepReturnFull",
    [SPSSeparator.REASON_NO_SOURCE]    = "warning_spsSepNoInPipe",
    [SPSSeparator.REASON_NO_RETURN]    = "warning_spsSepNoOutPipe",
    [SPSSeparator.REASON_NO_DM]        = "warning_spsSepNoDm",
}

-- Tightness cycles through these steps on the tightness key.
SPSSeparator.TIGHTNESS_STEPS = { 0.0, 0.25, 0.5, 0.75, 1.0 }

-- Placeable TYPE that activates the separator. Declared in modDesc as
-- <type name="manureHeapSeparator" parent="manureHeap" .../> — it behaves as
-- a manure heap (inherits the manureHeap specialization = the bunker) and
-- this script attaches the separator behaviour to every placeable of the
-- type. Mod types are namespaced at runtime ("FS25_SlurryPipeSystem.
-- manureHeapSeparator" — observed in the field log), hence the suffix match.
SPSSeparator.TYPE_NAME = "manureHeapSeparator"

function SPSSeparator.isSeparatorPlaceableType(placeable)
    if placeable == nil then return false end
    local tn = placeable.typeName
    if type(tn) ~= "string" and placeable.type ~= nil then
        tn = placeable.type.name
    end
    if type(tn) ~= "string" then return false end
    if tn == SPSSeparator.TYPE_NAME then return true end
    local suffix = "." .. SPSSeparator.TYPE_NAME
    return tn:sub(-#suffix) == suffix
end

-- Warn-blink range for auto-halt messages (metres from the machine).
SPSSeparator.WARNING_RANGE = 20.0

-- Money type for the running cost, registered lazily on first server charge
-- (MoneyType.register pattern verified against PF Subsidies.lua).
SPSSeparator.moneyType = nil

-- Pending savegame state keyed by rounded world position, applied when the
-- matching placeable registers (same pattern as the manager's _pendingThickness).
SPSSeparator._pendingStates = {}

-- ---------------------------------------------------------------------------
-- readConfig — parse <placeable.slurryPipeSystem.separator> off a FRESH owned
-- XML handle (never placeable.xmlFile — its C handle may already be dead).
-- The TYPE activates the separator, the XML block only tunes it: when the
-- block is absent every value falls back to its default below.
-- ---------------------------------------------------------------------------
function SPSSeparator.readConfig(xmlFile, kp)
    kp = kp or ""
    local base = kp .. "slurryPipeSystem.separator"

    local cfg = {}
    -- Rated intake at tightness 0 (fully loose), litres per hour. Float so
    -- every machine version can carry its own value.
    cfg.ratedLitersPerHour     = xmlFile:getFloat(base .. "#ratedLitersPerHour", 30000.0)
    -- Money cost per hour of ACTIVE separating (no charge while blocked/idle).
    cfg.costPerHour            = xmlFile:getFloat(base .. "#costPerHour", 0.0)
    -- Dry-matter fraction of the extruded solids (screw presses hold ~0.25-0.30
    -- regardless of feed).
    cfg.solidsDryMatter        = xmlFile:getFloat(base .. "#solidsDryMatter", 0.28)
    -- Fraction of incoming DM captured at tightness 0 / tightness 1.
    cfg.captureEffMin          = xmlFile:getFloat(base .. "#captureEffMin", 0.15)
    cfg.captureEffMax          = xmlFile:getFloat(base .. "#captureEffMax", 0.40)
    -- Throughput multiplier at FULL tightness (1.0 at fully loose).
    cfg.tightMinThroughputMult = xmlFile:getFloat(base .. "#tightMinThroughputMult", 0.5)
    -- Which pipeCoupling ids are the suction/return sides. When absent, the
    -- couplings' own flowDirection="IN"/"OUT" attributes resolve them.
    cfg.inCouplingId           = xmlFile:getInt(base .. "#inCouplingId")
    cfg.outCouplingId          = xmlFile:getInt(base .. "#outCouplingId")
    -- Walk-up control point. Falls back to the IN coupling's mount node.
    cfg.panelNodeName          = xmlFile:getString(base .. "#panelNodeName", "SPS_separatorPanel")
    cfg.interactRadius         = xmlFile:getFloat(base .. "#interactRadius", 4.0)
    -- Manure drop-effect node (visual seam — see header note).
    cfg.dropNodeName           = xmlFile:getString(base .. "#dropNodeName", "SPS_dropNode")
    -- Below this source dry-matter fraction the separator halts (nothing left
    -- worth pressing); auto-resumes when fresh slurry raises the DM again.
    cfg.minSourceDM            = xmlFile:getFloat(base .. "#minSourceDM", 0.005)
    -- Physical-fullness detection: when the bunker's undropped queue
    -- (ManureHeap.manureToDrop — what the tip area physically refused) exceeds
    -- this many litres, the bunker is treated as full; auto-resumes when the
    -- heap drains the queue after manure is moved.
    cfg.maxDropBacklog         = xmlFile:getFloat(base .. "#maxDropBacklog", 500.0)
    -- Drop-effect shader tuning (nil = keep shader defaults). Parameters
    -- verified against grainUnloadingShader.xml — it has NO uv-scale
    -- parameter (texture tiling is controlled by the mesh's UV island scale;
    -- islands may extend beyond 0..1 to tile), so no such knob exists here.
    -- uvSpeed  -> "uvSpeedMult"  : flow rate, lower = slower (default 1.0)
    -- fadeScale-> "fadeScale"    : vertex swell while fading (default -0.025)
    -- shapeScale -> "shapeScaleSpread": x=width scaler, y=height scaler,
    --              z=spread at end (defaults 1 1 0; shader "pipe" group — may
    --              only bite on the pipe variation, safe to experiment)
    cfg.dropEffectUvSpeed      = xmlFile:getFloat(base .. "#dropEffectUvSpeed")
    cfg.dropEffectFadeScale    = xmlFile:getFloat(base .. "#dropEffectFadeScale")
    local shapeStr             = xmlFile:getString(base .. "#dropEffectShapeScale")
    cfg.dropEffectShapeScale   = nil
    if shapeStr ~= nil then
        local sx, sy, sz = shapeStr:match("([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
        sx, sy, sz = tonumber(sx), tonumber(sy), tonumber(sz)
        if sx ~= nil and sy ~= nil and sz ~= nil then
            cfg.dropEffectShapeScale = { sx, sy, sz }
        else
            print(string.format("[SPS SEPARATOR] dropEffectShapeScale '%s' invalid — expected three numbers 'x y z'", shapeStr))
        end
    end
    -- controlPoint.x = the UV span the fade math expects along the flow
    -- (shader: mUV = uv0 / controlPoint.x, default 10). Set this to the same
    -- factor the mesh's UV maps are scaled by (e.g. UVs tiled x4 -> "4.0"),
    -- which is how texture density is increased without breaking the fade.
    cfg.dropEffectControlPoint = xmlFile:getFloat(base .. "#dropEffectControlPoint")
    -- Chunk particles (manure-spreader style). Needs only a small emitter
    -- SHAPE in the i3d (its geometry defines the spawn area); the particle
    -- system itself is cloned from the game's shared registry at runtime.
    cfg.dropParticlesNodeName  = xmlFile:getString(base .. "#dropParticlesNodeName", "SPS_dropParticles")
    cfg.dropParticleType       = xmlFile:getString(base .. "#dropParticleType", "unloading")
    cfg.dropParticleEmitScale  = xmlFile:getFloat(base .. "#dropParticleEmitScale", 1.0)
    -- Motion-path chunk drop (spreader-style lumps on a custom trajectory
    -- texture). Texture path is relative to the MOD directory; nil = off.
    -- numRows/rowLength must match BOTH the generated texture AND one of the
    -- effect meshes registered for the effect type (manureEffects.xml:
    -- 28x46, 22x24, 28x24, 54x24).
    cfg.dropChunksTexture      = xmlFile:getString(base .. "#dropChunksTexture")
    cfg.dropChunksNumRows      = xmlFile:getInt(base .. "#dropChunksNumRows", 54)
    cfg.dropChunksRowLength    = xmlFile:getInt(base .. "#dropChunksRowLength", 24)
    cfg.dropChunksEffectType   = xmlFile:getString(base .. "#dropChunksEffectType", "MANURE_SPREADER")
    cfg.dropChunksSpeedScale   = xmlFile:getFloat(base .. "#dropChunksSpeedScale")
    cfg.dropChunksDensity      = xmlFile:getFloat(base .. "#dropChunksDensity", 1.0)
    -- Chunk size over the fall: "sizeAtStart sizeAtEnd" (shader sizeScale
    -- x/y; the spreader default grows 0.75->3.75, a drop wants ~constant).
    local sizeStr              = xmlFile:getString(base .. "#dropChunksSizeScale")
    cfg.dropChunksSizeScale    = nil
    if sizeStr ~= nil then
        local a, b = sizeStr:match("([%-%d%.]+)%s+([%-%d%.]+)")
        a, b = tonumber(a), tonumber(b)
        if a ~= nil and b ~= nil then
            cfg.dropChunksSizeScale = { a, b }
        else
            print(string.format("[SPS SEPARATOR] dropChunksSizeScale '%s' invalid — expected two numbers 'start end'", sizeStr))
        end
    end

    -- Sanity clamps so a bad XML can never divide by zero or invert the model.
    if cfg.solidsDryMatter <= 0.01 then cfg.solidsDryMatter = 0.28 end
    cfg.captureEffMin = math.max(0.0, math.min(cfg.captureEffMin, 0.95))
    cfg.captureEffMax = math.max(cfg.captureEffMin, math.min(cfg.captureEffMax, 0.95))
    cfg.tightMinThroughputMult = math.max(0.05, math.min(cfg.tightMinThroughputMult, 1.0))
    return cfg
end

-- ---------------------------------------------------------------------------
-- Node search helper — placeable component tree by name (embedded style).
-- ---------------------------------------------------------------------------
local function findComponentNode(placeable, name)
    if name == nil or name == "" or placeable == nil or placeable.components == nil then return nil end
    local function search(node)
        if node == nil or node == 0 then return nil end
        if getName(node) == name then return node end
        for i = 0, getNumOfChildren(node) - 1 do
            local found = search(getChildAt(node, i))
            if found ~= nil then return found end
        end
        return nil
    end
    for _, comp in ipairs(placeable.components) do
        if comp ~= nil and comp.node ~= nil and comp.node ~= 0 then
            local hit = search(comp.node)
            if hit ~= nil then return hit end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Defaults used when a manureHeapSeparator-typed placeable ships without a
-- <slurryPipeSystem><separator> block. Same values as readConfig's defaults.
-- ---------------------------------------------------------------------------
function SPSSeparator.getDefaultConfig()
    return {
        ratedLitersPerHour     = 30000.0,
        costPerHour            = 0.0,
        solidsDryMatter        = 0.28,
        captureEffMin          = 0.15,
        captureEffMax          = 0.40,
        tightMinThroughputMult = 0.5,
        inCouplingId           = nil,
        outCouplingId          = nil,
        panelNodeName          = "SPS_separatorPanel",
        interactRadius         = 4.0,
        dropNodeName           = "SPS_dropNode",
        minSourceDM            = 0.005,
        maxDropBacklog         = 500.0,
        dropEffectUvSpeed      = nil,
        dropEffectFadeScale    = nil,
        dropEffectShapeScale   = nil,
        dropEffectControlPoint = nil,
        dropParticlesNodeName  = "SPS_dropParticles",
        dropParticleType       = "unloading",
        dropParticleEmitScale  = 1.0,
        dropChunksTexture      = nil,
        dropChunksNumRows      = 54,
        dropChunksRowLength    = 24,
        dropChunksEffectType   = "MANURE_SPREADER",
        dropChunksSpeedScale   = nil,
        dropChunksDensity      = 1.0,
        dropChunksSizeScale    = nil,
    }
end

-- ---------------------------------------------------------------------------
-- tryInitForPlaceable — called from the registerPlaceable wrap after the
-- manager has fully built pEntry (couplings included). Idempotent.
-- Activation is TYPE-driven: every placeable of type manureHeapSeparator gets
-- the separator, with or without a <separator> tuning block in its XML.
-- ---------------------------------------------------------------------------
function SPSSeparator.tryInitForPlaceable(manager, placeable)
    if manager == nil or placeable == nil then return end
    if not SPSSeparator.isSeparatorPlaceableType(placeable) then return end
    local pEntry = nil
    for _, e in ipairs(manager.registeredPlaceables) do
        if e.placeable == placeable then pEntry = e break end
    end
    if pEntry == nil or pEntry.separator ~= nil then return end
    if placeable.configFileName == nil then return end

    -- Fresh owned handle, queried and deleted immediately (project rule).
    local cfg = nil
    local xmlFile = XMLFile.loadIfExists("spsSeparatorConfig", placeable.configFileName, nil)
    if xmlFile ~= nil then
        cfg = SPSSeparator.readConfig(xmlFile, "placeable.")
        xmlFile:delete()
    end
    if cfg == nil then
        log("no <separator> block in %s — using defaults", tostring(placeable.configFileName))
        cfg = SPSSeparator.getDefaultConfig()
    end

    local sep = {
        placeable       = placeable,
        pEntry          = pEntry,
        cfg             = cfg,
        isOn            = false,
        tightness       = 0.5,
        blockReason     = SPSSeparator.REASON_NO_PIPES,
        lifetimeManure  = 0.0,
        -- 1-second accumulation windows for the panel L/h displays.
        _manurePending  = 0.0,
        _accIntake      = 0.0,
        _accManure      = 0.0,
        _accMs          = 0.0,
        statIntakeLph   = 0.0,
        statManureLph   = 0.0,
        _costAccum      = 0.0,
        _syncTimerMs    = 0.0,
        _lastWarnReason = SPSSeparator.REASON_NONE,
        inCoupling      = nil,
        outCoupling     = nil,
        panelNode       = nil,
        dropNode        = nil,
        dropEffects     = nil,   -- visual seam, see header
        _effectsOn      = false,
        activatable     = nil,
    }

    -- Resolve IN/OUT couplings: explicit ids first, then flowDirection strings
    -- (the manager already parses #flowDirection onto every store coupling).
    if pEntry.storeCouplings ~= nil then
        for _, sc in ipairs(pEntry.storeCouplings) do
            if cfg.inCouplingId ~= nil and sc.id == cfg.inCouplingId then
                sep.inCoupling = sc
            elseif cfg.outCouplingId ~= nil and sc.id == cfg.outCouplingId then
                sep.outCoupling = sc
            end
        end
        for _, sc in ipairs(pEntry.storeCouplings) do
            if sep.inCoupling == nil and sc.flowDirection == "IN" then sep.inCoupling = sc end
            if sep.outCoupling == nil and sc.flowDirection == "OUT" then sep.outCoupling = sc end
        end
    end
    if sep.inCoupling == nil or sep.outCoupling == nil then
        print(string.format("[SPS SEPARATOR] %s declares <separator> but IN/OUT couplings could not be resolved (in=%s out=%s) — separator disabled",
            tostring(placeable.configFileName), tostring(sep.inCoupling ~= nil), tostring(sep.outCoupling ~= nil)))
        return
    end

    -- Panel node (walk-up point). Fallback: IN coupling mount.
    sep.panelNode = findComponentNode(placeable, cfg.panelNodeName) or sep.inCoupling.mountNode
    -- Drop node for the manure stream visual.
    sep.dropNode  = findComponentNode(placeable, cfg.dropNodeName)
    if sep.dropNode == nil then
        print(string.format("[SPS SEPARATOR] drop node '%s' not found in %s — manure drop effect disabled",
            tostring(cfg.dropNodeName), tostring(placeable.configFileName)))
    else
        log("drop node '%s' resolved (%d child shape(s))",
            tostring(cfg.dropNodeName), getNumOfChildren(sep.dropNode))
    end
    -- Optional particle emitter shape (chunk particles). Absent = no particles.
    sep.dropParticlesNode = findComponentNode(placeable, cfg.dropParticlesNodeName)
    if sep.dropParticlesNode ~= nil then
        log("particle emitter '%s' resolved", tostring(cfg.dropParticlesNodeName))
    end

    -- Manure bunker: the placeable's own ManureHeap (type="manureHeap").
    local heap = placeable.spec_manureHeap ~= nil and placeable.spec_manureHeap.manureHeap or nil
    if heap == nil then
        print(string.format("[SPS SEPARATOR] %s is type manureHeapSeparator but has no spec_manureHeap.manureHeap (type must parent 'manureHeap') — separator disabled",
            tostring(placeable.configFileName)))
        return
    end
    sep.heap = heap

    pEntry.separator = sep

    -- Apply any savegame state pending for this world position.
    SPSSeparator._applyPendingState(sep)

    -- Walk-up control activatable (on/off + tightness).
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil
    and SPSSeparatorActivatable ~= nil then
        sep.activatable = SPSSeparatorActivatable.new(sep, cfg.interactRadius)
        g_currentMission.activatableObjectsSystem:addActivatable(sep.activatable)
    end

    log("initialised for %s (rated=%.0f L/h capture=%.2f..%.2f solidsDM=%.2f cost=%.2f/h)",
        tostring(placeable.configFileName), cfg.ratedLitersPerHour,
        cfg.captureEffMin, cfg.captureEffMax, cfg.solidsDryMatter, cfg.costPerHour)
end

function SPSSeparator._applyPendingState(sep)
    if sep.placeable == nil or sep.placeable.components == nil
    or sep.placeable.components[1] == nil then return end
    local wx, wy, wz = getWorldTranslation(sep.placeable.components[1].node)
    for i, p in ipairs(SPSSeparator._pendingStates) do
        if math.abs(p.px - wx) < 0.5 and math.abs(p.py - wy) < 0.5 and math.abs(p.pz - wz) < 0.5 then
            sep.isOn           = p.isOn
            sep.tightness      = math.max(0.0, math.min(1.0, p.tightness or 0.5))
            sep.lifetimeManure = p.lifetimeManure or 0.0
            table.remove(SPSSeparator._pendingStates, i)
            log("savegame state applied (on=%s tightness=%.2f lifetime=%.0f)",
                tostring(sep.isOn), sep.tightness, sep.lifetimeManure)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Coupling / partner helpers
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Pipe endpoint resolution. A separator coupling reaches its partner three
-- ways, and only the first two set isConnected:
--   1. Direct coupling bond            -> isConnected + connectedPartnerCoupling
--   2. A laid chain's END terminus was
--      connected TO this coupling      -> same (applyConnectCouplings both sides)
--   3. The chain was STARTED here      -> this coupling is chain.anchorCoupling,
--      isConnected stays FALSE (established pass-B learning: chain-anchored
--      termini use anchorCoupling, not isConnected). Field log 16:20: player
--      walked pipes FROM both sep couplers -> both were anchors -> the old
--      isConnected-only gate reported NO_PIPES with pipes visibly attached.
-- Case 3 resolves the chain's far END terminus's real partner coupler and then
-- that coupler's owner, mirroring resolveSourceForCouplingPartner's own
-- anchor-walk (SPSM_Flow) and _getState's anchorsMatch (SPSChainActivatable).
-- ---------------------------------------------------------------------------
local function couplingsMatch(a, b)
    if a == b then return a ~= nil end
    if a == nil or b == nil then return false end
    return a.placeable ~= nil and a.placeable == b.placeable and a.id == b.id
end

function SPSSeparator.findAnchoredChain(mgr, sc)
    if mgr == nil or mgr.pipeChains == nil or sc == nil then return nil end
    local best = nil
    for _, c in ipairs(mgr.pipeChains) do
        if couplingsMatch(c.anchorCoupling, sc) then
            -- Prefer the network-addressable generation (same rule as _getState).
            if best == nil or (best.netId == nil and c.netId ~= nil) then
                best = c
            end
        end
    end
    return best
end

-- Resolve the source entry of the vessel that OWNS a real coupler (mirrors the
-- anchor-resolution loops in SPSM_Flow.resolveSourceForCouplingPartner).
function SPSSeparator.resolveCouplerOwnerSource(mgr, coupler)
    if coupler == nil then return nil end
    for _, pEntry in ipairs(mgr.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, c in ipairs(pEntry.storeCouplings) do
                if c == coupler then
                    return mgr:_restrictSourceToCoupling(pEntry.sourceEntry, c)
                end
            end
        end
    end
    for _, vEntry in ipairs(mgr.registeredVehicles) do
        for _, c in ipairs(vEntry.couplingEntries) do
            if c == coupler then
                return mgr:resolveVehicleSource(vEntry.vehicle)
            end
        end
    end
    return nil
end

-- Returns hasPipe (both ends of a complete pipe run exist), sourceEntry.
function SPSSeparator.resolveEndpoint(mgr, sc)
    if sc == nil then return false, nil end
    -- Cases 1 + 2: bonded coupling; the manager's own resolver walks chains
    -- entered via a terminus partner.
    if sc.isConnected == true and sc.connectedPartnerCoupling ~= nil then
        return true, mgr:resolveSourceForCouplingPartner(sc)
    end
    -- Case 3: chain anchored at this coupling.
    local chain = SPSSeparator.findAnchoredChain(mgr, sc)
    if chain ~= nil and chain.segments ~= nil then
        local lastSeg = chain.segments[#chain.segments]
        local endTerm = lastSeg ~= nil and lastSeg.chainCoupling or nil
        if endTerm ~= nil and endTerm.isConnected == true
        and endTerm.connectedPartnerCoupling ~= nil
        and not endTerm.connectedPartnerCoupling.isChainTerminus then
            local src = SPSSeparator.resolveCouplerOwnerSource(mgr, endTerm.connectedPartnerCoupling)
            return true, src
        end
        -- Chain laid from here but its far end is not bonded yet: no complete pipe.
        return false, nil
    end
    return false, nil
end

function SPSSeparator.findSeparatorByPlaceable(manager, placeable)
    if manager == nil or placeable == nil then return nil end
    for _, e in ipairs(manager.registeredPlaceables) do
        if e.placeable == placeable then return e.separator end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Derived model values
-- ---------------------------------------------------------------------------
function SPSSeparator.getThroughputMult(sep)
    local c = sep.cfg
    return 1.0 - sep.tightness * (1.0 - c.tightMinThroughputMult)
end

function SPSSeparator.getCaptureEff(sep)
    local c = sep.cfg
    return c.captureEffMin + sep.tightness * (c.captureEffMax - c.captureEffMin)
end

-- Source dry-matter fraction (0..1) for any resolvable source entry.
-- Stores use the true pool DM; tankers convert their carried thickness gauge
-- back to DM; anything else (water plane etc.) reads 0.
local function getSourceDM(mgr, srcEntry)
    if srcEntry == nil then return 0 end
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if srcEntry.thickeningEnabled then
            return mgr:getStoreDM(srcEntry)
        end
        -- Store outside the thickness model: assume fresh slurry.
        return SlurryPipeManager.DM_FRESH or 0.06
    end
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or srcEntry.type == "FILL_UNIT_ONLY" then
        if srcEntry.vehicle ~= nil then
            return mgr:gaugeToDM(mgr:getTankerThickness(srcEntry.vehicle))
        end
    end
    return 0
end

-- Source too thick for the screw to pull? Mirrors the pump rule: DM-driven
-- gauge >= 0.9 is unpumpable and only water fixes it (agitation cannot lower
-- DM — SPSM_Consistency.applyAgitation).
local function isSourceTooThick(mgr, srcEntry)
    if srcEntry == nil then return false end
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if not srcEntry.thickeningEnabled then return false end
        return mgr:dmToGauge(mgr:getStoreDM(srcEntry)) >= 0.9
    end
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or srcEntry.type == "FILL_UNIT_ONLY" then
        if srcEntry.vehicle ~= nil then
            return (mgr:getTankerThickness(srcEntry.vehicle) or 0) >= 0.9
        end
    end
    return false
end

-- Thickness flow multiplier for the intake (same curves the pumps use).
local function getIntakeFlowMult(mgr, srcEntry)
    if srcEntry == nil then return 1.0 end
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        return mgr:getFlowRateMultiplier(srcEntry)
    end
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or srcEntry.type == "FILL_UNIT_ONLY" then
        if srcEntry.vehicle ~= nil then
            return mgr:getTankerThicknessMultiplier(srcEntry.vehicle)
        end
    end
    return 1.0
end

-- ---------------------------------------------------------------------------
-- Whole-slurry withdraw from a storage-plane source (bias 1.0). This is the
-- separator's own intake path — deliberately NOT removeFromSource, whose
-- DM_REMOVAL_LIQUID_BIAS 1.6 draw would starve the screw of dry matter.
-- Mirrors the storage branch of removeFromSource with dm-proportional solids.
-- Returns litres actually removed.
-- ---------------------------------------------------------------------------
local function withdrawWholeSlurry(mgr, srcEntry, amount, fillType)
    if srcEntry == nil or amount <= 0 then return 0 end

    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        local storage = srcEntry.storage
        if storage == nil then return 0 end
        local oldLevel = storage:getFillLevel(fillType) or 0
        local removed  = math.min(amount, oldLevel)
        if removed <= 0 then return 0 end
        if srcEntry.thickeningEnabled then
            mgr:_ensureStorePools(srcEntry)
            local total  = mgr:_getStoreTotalFill(srcEntry)
            local solids = srcEntry.solids or 0
            local dm     = total > 0 and (solids / total) or 0
            -- Whole-slurry draw: solids leave exactly at their share.
            srcEntry.solids = math.max(0, solids - removed * dm)
            -- Settled crust IS dry matter: the screw eats lumps along with the
            -- liquid, so existing settle shrinks by the same fraction as the
            -- solids pool. (Field fault: store stripped to ~0% DM still showed
            -- 25% settle/thickness.) Liquid-bias PUMPING is untouched — pumps
            -- draw below the crust by design.
            if solids > 0 then
                srcEntry.settle = (srcEntry.settle or 0) * (srcEntry.solids / solids)
            else
                srcEntry.settle = 0
            end
        end
        storage:setFillLevel(math.max(0, oldLevel - removed), fillType)
        if srcEntry.thickeningEnabled then
            srcEntry._lastTotal = mgr:_getStoreTotalFill(srcEntry)
        end
        return removed
    end

    -- Vehicle source: the carried mixture is uniform, so a plain draw neither
    -- concentrates nor thins it — removeFromSource's vehicle branch is exact.
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or srcEntry.type == "FILL_UNIT_ONLY" then
        local v = srcEntry.vehicle
        if v == nil then return 0 end
        local before = v:getFillUnitFillLevel(srcEntry.fillUnitIndex) or 0
        local take   = math.min(amount, before)
        if take <= 0 then return 0 end
        mgr:removeFromSource(srcEntry, take, fillType, nil)
        local after = v:getFillUnitFillLevel(srcEntry.fillUnitIndex) or 0
        return math.max(0, before - after)
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Deposit the return liquid at a KNOWN dm fraction. Store deposits mirror the
-- addToSource storage branch but add the exact returned solids instead of
-- inferring them from a tanker gauge; vehicle deposits use addToSource for
-- the litres and then volume-blend the carried thickness.
-- ---------------------------------------------------------------------------
local function depositReturn(mgr, dstEntry, amount, fillType, returnDM)
    if dstEntry == nil or amount <= 0 then return 0 end

    if dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        local storage = dstEntry.storage
        if storage == nil then return 0 end
        local depFt = mgr:resolveStoreDepositFillType(dstEntry, fillType)
        local free  = storage:getFreeCapacity(depFt) or 0
        local toAdd = math.min(amount, free)
        if toAdd <= 0 then return 0 end
        if dstEntry.thickeningEnabled then
            mgr:_ensureStorePools(dstEntry)
            dstEntry.solids = (dstEntry.solids or 0) + toAdd * math.max(0, returnDM or 0)
        end
        storage:setFillLevel((storage:getFillLevel(depFt) or 0) + toAdd, depFt)
        if dstEntry.thickeningEnabled then
            dstEntry._lastTotal = mgr:_getStoreTotalFill(dstEntry)
        end
        return toAdd
    end

    if dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or dstEntry.type == "FILL_UNIT_ONLY" then
        local v = dstEntry.vehicle
        if v == nil then return 0 end
        local oldLevel = v:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0
        mgr:addToSource(dstEntry, amount, fillType, nil)
        local newLevel = v:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0
        local added    = math.max(0, newLevel - oldLevel)
        if added > 0 then
            mgr:applyFillThicknessBlend(v, oldLevel, added, mgr:dmToGauge(math.max(0, returnDM or 0)))
        end
        return added
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- evaluateBlockReason — connection and capacity gates, cheap enough per tick.
-- Returns reason, srcEntry, dstEntry, fillType.
-- ---------------------------------------------------------------------------
function SPSSeparator.evaluateBlockReason(mgr, sep)
    local inHas,  srcEntry = SPSSeparator.resolveEndpoint(mgr, sep.inCoupling)
    local outHas, dstEntry = SPSSeparator.resolveEndpoint(mgr, sep.outCoupling)
    if not inHas and not outHas then return SPSSeparator.REASON_NO_PIPES end
    if not inHas  then return SPSSeparator.REASON_NO_IN_PIPE end
    if not outHas then return SPSSeparator.REASON_NO_OUT_PIPE end

    if srcEntry == nil then return SPSSeparator.REASON_NO_SOURCE end
    if dstEntry == nil then return SPSSeparator.REASON_NO_RETURN end

    local fillType = mgr:_resolveSourceFillType(srcEntry)
    if fillType == nil then return SPSSeparator.REASON_SOURCE_EMPTY, srcEntry, dstEntry end
    local avail = mgr:_equaliseSourceLevel(srcEntry, fillType)
    if avail <= 1.0 then return SPSSeparator.REASON_SOURCE_EMPTY, srcEntry, dstEntry, fillType end

    if isSourceTooThick(mgr, srcEntry) then
        return SPSSeparator.REASON_SOURCE_THICK, srcEntry, dstEntry, fillType
    end

    -- Nothing left worth pressing: thickening stores stripped below the
    -- minimum DM halt here and auto-resume when fresh slurry raises it.
    -- (Tanker sources are excluded — their gauge floors at DM_FRESH.)
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE
    and srcEntry.thickeningEnabled
    and mgr:getStoreDM(srcEntry) < (sep.cfg.minSourceDM or 0) then
        return SPSSeparator.REASON_NO_DM, srcEntry, dstEntry, fillType
    end

    -- Bunker full: by registered capacity, OR PHYSICALLY — the heap's
    -- undropped queue only persists when the tip area (walls) refuses
    -- material, exactly like a trailer stopping mid-tip. Clears itself once
    -- manure is moved and the heap drains the queue.
    local manureFree = (sep.heap:getFreeCapacity(sep.heap.fillTypeIndex) or 0)
        - (sep._manurePending or 0)
    if manureFree <= 1.0
    or (sep.heap.manureToDrop or 0) > (sep.cfg.maxDropBacklog or 500.0) then
        return SPSSeparator.REASON_OUTPUT_FULL, srcEntry, dstEntry, fillType
    end

    -- Return-full: skipped when source and destination are the same storage
    -- (the withdraw itself frees more room than the return needs).
    local sameStorage = srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE
        and dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE
        and srcEntry.storage ~= nil and srcEntry.storage == dstEntry.storage
    local sameVehicle = srcEntry.vehicle ~= nil and srcEntry.vehicle == dstEntry.vehicle
    if not sameStorage and not sameVehicle then
        local destFree = mgr:_equaliseDestFree(dstEntry, fillType)
        if destFree <= 1.0 then
            return SPSSeparator.REASON_RETURN_FULL, srcEntry, dstEntry, fillType
        end
    end

    return SPSSeparator.REASON_NONE, srcEntry, dstEntry, fillType
end

-- ---------------------------------------------------------------------------
-- flushManure — push accumulated solids into the bunker in slugs big enough
-- to survive ManureHeap:setFillLevel's `0.1 < absDelta` discard guard.
-- Normal flushes wait for >= 1 L; force (stop/toggle-off) pushes any residual
-- above 0.15 L so at most a fraction of a litre is ever carried over.
-- Uses the heap's own fillTypeIndex field (vanilla PlaceableManureHeap reads
-- levels the same way).
-- ---------------------------------------------------------------------------
function SPSSeparator.flushManure(sep, force)
    local pending = sep._manurePending or 0
    local threshold = force and 0.15 or 1.0
    if pending < threshold then return end
    local heap = sep.heap
    if heap == nil then return end
    -- Backpressure: while the tip area is physically refusing material
    -- (undropped queue above the configured backlog) hold our pending litres
    -- back instead of piling the queue higher.
    if not force and (heap.manureToDrop or 0) > (sep.cfg.maxDropBacklog or 500.0) then
        return
    end
    local ft     = heap.fillTypeIndex
    local level  = heap:getFillLevel(ft) or 0
    local cap    = heap:getCapacity(ft) or 0
    local target = math.min(level + pending, cap)
    if target - level <= 0.1 then return end
    heap:setFillLevel(target, ft)
    sep._manurePending = pending - (target - level)
end

-- ---------------------------------------------------------------------------
-- processTick — server-side material pass for one separator.
-- ---------------------------------------------------------------------------
function SPSSeparator.processTick(mgr, sep, dt)
    local reason, srcEntry, dstEntry, fillType = SPSSeparator.evaluateBlockReason(mgr, sep)
    if reason ~= sep.blockReason then
        sep.blockReason = reason
        SPSSeparator.onReasonChanged(sep)
        if SPSSeparatorEvent ~= nil then
            SPSSeparatorEvent.sendState(sep)
        end
    end
    if reason ~= SPSSeparator.REASON_NONE then return end

    local dtSec   = dt * 0.001
    local cfg     = sep.cfg
    local srcDM   = getSourceDM(mgr, srcEntry)
    local capture = SPSSeparator.getCaptureEff(sep)
    -- k = manure litres per intake litre. Always well below 1 in practice
    -- (e.g. 0.06 * 0.40 / 0.28 = 0.086); clamped defensively anyway.
    local k = math.min(0.95, srcDM * capture / cfg.solidsDryMatter)

    local rate = cfg.ratedLitersPerHour / 3600.0
        * SPSSeparator.getThroughputMult(sep)
        * getIntakeFlowMult(mgr, srcEntry)
    local intake = rate * dtSec

    -- Clamp by source, manure bunker and (different-vessel) return space.
    intake = math.min(intake, mgr:_equaliseSourceLevel(srcEntry, fillType))
    local manureFree = (sep.heap:getFreeCapacity(sep.heap.fillTypeIndex) or 0)
        - (sep._manurePending or 0)
    if k > 0 then
        intake = math.min(intake, manureFree / k)
    end
    local sameStorage = srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE
        and dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE
        and srcEntry.storage ~= nil and srcEntry.storage == dstEntry.storage
    local sameVehicle = srcEntry.vehicle ~= nil and srcEntry.vehicle == dstEntry.vehicle
    if not sameStorage and not sameVehicle then
        local destFree = mgr:_equaliseDestFree(dstEntry, fillType)
        if (1 - k) > 0 then
            intake = math.min(intake, destFree / (1 - k))
        end
    end
    if intake <= 0.001 then return end

    -- 1) Pull whole slurry in.
    local pulled = withdrawWholeSlurry(mgr, srcEntry, intake, fillType)
    if pulled <= 0 then return end

    -- 2) Split. removedDM litres of dry matter leave as solids at solidsDryMatter.
    local dmIn      = pulled * srcDM
    local removedDM = dmIn * capture
    local manureL   = removedDM / cfg.solidsDryMatter
    local returnL   = math.max(0, pulled - manureL)
    local returnDM  = returnL > 0 and ((dmIn - removedDM) / returnL) or 0

    -- 3) Solids into the bunker (server; ManureHeap self-syncs and physically
    -- drops the material over its tip area — ManureHeap:update, verified).
    -- ManureHeap:setFillLevel SILENTLY DISCARDS deltas of 0.1 L or less
    -- (verified in source: `if 0.1 < absDelta then`), and one tick's manure is
    -- ~0.006 L — so per-tick pushes all vanished (field report: litres moved,
    -- heap stayed empty). Accumulate and flush in >= 1 L slugs instead.
    if manureL > 0 then
        sep._manurePending = (sep._manurePending or 0) + manureL
        sep.lifetimeManure = sep.lifetimeManure + manureL
    end
    SPSSeparator.flushManure(sep, false)

    -- 4) Liquid fraction back out.
    if returnL > 0 then
        depositReturn(mgr, dstEntry, returnL, fillType, returnDM)
    end

    -- 5) Stats + running cost.
    sep._accIntake = sep._accIntake + pulled
    sep._accManure = sep._accManure + manureL
    if cfg.costPerHour > 0 then
        -- Real-time hours, deliberately NOT timeScale-scaled: the litres above
        -- flow on the real-time clock too, so cost-per-litre stays constant at
        -- any game speed.
        sep._costAccum = sep._costAccum + cfg.costPerHour * (dtSec / 3600.0)
        if sep._costAccum >= 1.0 then
            local charge = math.floor(sep._costAccum)
            sep._costAccum = sep._costAccum - charge
            if SPSSeparator.moneyType == nil and MoneyType ~= nil and MoneyType.register ~= nil then
                SPSSeparator.moneyType = MoneyType.register("other", "info_spsSeparatorRunning", "FS25_SlurryPipeSystem")
            end
            if g_currentMission ~= nil and SPSSeparator.moneyType ~= nil then
                local farmId = sep.placeable.getOwnerFarmId ~= nil and sep.placeable:getOwnerFarmId() or 1
                g_currentMission:addMoney(-charge, farmId, SPSSeparator.moneyType, true)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- onReasonChanged — local warning blink when a nearby player should know.
-- Runs on every peer (state event calls it too), so guests get the message.
-- ---------------------------------------------------------------------------
function SPSSeparator.onReasonChanged(sep)
    if not sep.isOn then return end
    local reason = sep.blockReason
    if reason == SPSSeparator.REASON_NONE then return end
    if reason == sep._lastWarnReason then return end
    sep._lastWarnReason = reason
    if g_localPlayer == nil or g_currentMission == nil or sep.panelNode == nil then return end
    if not entityExists(sep.panelNode) then return end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(sep.panelNode)
    if MathUtil.vector3Length(px - cx, py - cy, pz - cz) > SPSSeparator.WARNING_RANGE then return end
    local key = SPSSeparator.REASON_L10N[reason]
    if key ~= nil then
        g_currentMission:showBlinkingWarning(g_i18n:getText(key), 3000)
    end
end

-- ---------------------------------------------------------------------------
-- Toggle / tightness — request (any peer) + apply (server or from event).
-- ---------------------------------------------------------------------------
function SPSSeparator.requestToggle(sep)
    local newOn = not sep.isOn
    if g_server ~= nil then
        SPSSeparator.applyToggle(sep, newOn)
    elseif SPSSeparatorEvent ~= nil then
        SPSSeparatorEvent.sendToggleRequest(sep.placeable, newOn)
    end
    -- Immediate local feedback when switching ON while blocked.
    if newOn and sep.blockReason ~= SPSSeparator.REASON_NONE then
        local key = SPSSeparator.REASON_L10N[sep.blockReason]
        if key ~= nil and g_currentMission ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText(key), 3000)
        end
    end
end

function SPSSeparator.applyToggle(sep, isOn)
    if sep.isOn == isOn then return end
    sep.isOn = isOn
    sep._lastWarnReason = SPSSeparator.REASON_NONE
    if not isOn then
        sep.statIntakeLph, sep.statManureLph = 0.0, 0.0
        sep._accIntake, sep._accManure, sep._accMs = 0.0, 0.0, 0.0
        -- Push any residual solids so stopping never strands the last slug.
        if g_server ~= nil then
            SPSSeparator.flushManure(sep, true)
        end
    end
    SPSSeparator.updateDropEffects(sep)
    if g_server ~= nil and SPSSeparatorEvent ~= nil then
        SPSSeparatorEvent.sendState(sep)
    end
    log("toggle -> %s (%s)", tostring(isOn), tostring(sep.placeable.configFileName))
end

function SPSSeparator.requestCycleTightness(sep)
    local steps = SPSSeparator.TIGHTNESS_STEPS
    local nextT = steps[1]
    for i, s in ipairs(steps) do
        if math.abs(sep.tightness - s) < 0.01 then
            nextT = steps[i % #steps + 1]
            break
        end
    end
    if g_server ~= nil then
        SPSSeparator.applyTightness(sep, nextT)
    elseif SPSSeparatorEvent ~= nil then
        SPSSeparatorEvent.sendTightnessRequest(sep.placeable, nextT)
    end
end

function SPSSeparator.applyTightness(sep, tightness)
    sep.tightness = math.max(0.0, math.min(1.0, tightness or 0))
    if g_server ~= nil and SPSSeparatorEvent ~= nil then
        SPSSeparatorEvent.sendState(sep)
    end
end

-- Applied by SPSSeparatorEvent STATE on clients (and re-broadcast path).
function SPSSeparator.applyState(placeable, isOn, tightness, reason, lifetime, lphIn, lphOut)
    local mgr = g_slurryPipeManager
    if mgr == nil then return end
    local sep = SPSSeparator.findSeparatorByPlaceable(mgr, placeable)
    if sep == nil then return end
    sep.isOn           = isOn
    sep.tightness      = tightness
    sep.lifetimeManure = lifetime or sep.lifetimeManure
    sep.statIntakeLph  = lphIn or sep.statIntakeLph
    sep.statManureLph  = lphOut or sep.statManureLph
    if reason ~= sep.blockReason then
        sep.blockReason = reason
        SPSSeparator.onReasonChanged(sep)
    end
    SPSSeparator.updateDropEffects(sep)
end

-- ---------------------------------------------------------------------------
-- Drop effect — manure stream from the press outlet into the bunker.
-- Manual ShaderPlaneEffect construction (the mod's proven pattern from the
-- coupler pipe-effect build), with the material path taken verbatim from
-- ShaderPlaneEffect:loadEffectAttributes: the authored mesh material is
-- REPLACED by the material manager's base "unloading" material, whose
-- grainUnloadingShader triggers the fill-type texture-array path; the manure
-- look then arrives via setEffectTypeInfo(FillType.MANURE) -> fillTypeId
-- shader parameter + g_materialManager:getMaterial(MANURE, "unloading", 1).
-- i3d contract: SPS_dropNode with the stream Shape as child 0 (single
-- material slot — multiple materials hard-fail in vanilla too) and an
-- OPTIONAL smoke/dust plane as child 1.
-- Client-only; the server runs no visuals.
-- ---------------------------------------------------------------------------
local function buildOneDropEffect(sep, node, isSmoke)
    if node == nil or node == 0 or not entityExists(node) then return nil end
    if getNumOfMaterials(node) > 1 then
        print(string.format("[SPS SEPARATOR] drop effect node '%s' has multiple materials — effect skipped (assign one material)", getName(node)))
        return nil
    end

    local se = ShaderPlaneEffect.new()
    se.parent           = sep.placeable
    se.baseDirectory    = sep.placeable.baseDirectory
    se.rootNodes        = sep.dropNode
    se.node             = node
    se.materialType     = isSmoke and "unloadingSmoke" or "unloading"
    se.materialTypeId   = 1
    se.dynamicFillType  = true
    se.defaultFillType  = FillType.MANURE
    se.hasValidMaterial = false
    se.useBaseMaterial  = false
    se.lastFillTypeIndex = nil
    se.fadeInTime       = 1000
    se.fadeOutTime      = 1000
    se.planeFadeTime    = 1000
    se.startDelay       = isSmoke and 100 or 0
    se.stopDelay        = isSmoke and 100 or 0
    se.currentDelay     = se.startDelay
    se.state            = ShaderPlaneEffect.STATE_OFF
    se.fadeCur          = { -1, 1 }
    se.fadeDir          = { 1, 1 }
    se.fadeX            = { -1, 1 }
    se.fadeY            = { -1, 1 }
    se.alwaysVisibile   = false
    se.showOnFirstUse   = false
    se.alignToWorldY    = isSmoke
    se.alignXAxisToWorldY = false
    se.offset           = 0
    se.prio             = 0
    se.deleteListeners  = {}
    se.startRestriction = {}
    se.allowUpdate      = true
    se.lastUpdateTime   = 0
    if not isSmoke then
        -- Pushed into the shader by setEffectTypeInfo ("uvSpeedMult" /
        -- "fadeScale", verified in ShaderPlaneEffect source). nil keeps
        -- defaults.
        se.uvSpeed   = sep.cfg.dropEffectUvSpeed
        se.fadeScale = sep.cfg.dropEffectFadeScale
    end

    -- Material assignment, mirroring loadEffectAttributes exactly.
    local effectMaterial = g_materialManager:getBaseMaterialByName(se.materialType)
    if effectMaterial ~= nil then
        setMaterial(node, effectMaterial, 0)
        local shaderFilename = getMaterialCustomShaderFilename(effectMaterial)
        local useArrays = shaderFilename ~= nil and (
            shaderFilename:contains("grainUnloadingSmokeShader")
            or shaderFilename:contains("grainUnloadingBeltShader")
            or shaderFilename:contains("grainUnloadingShader")
            or shaderFilename:contains("levelerShader"))
        se.useFillTypeTextureArrays = useArrays
        if useArrays then
            if isSmoke and shaderFilename:find("grainUnloadingSmokeShader") ~= nil then
                -- Smoke branch (source early-return path): base material kept,
                -- terrain texture arrays diffuse-only, type set once.
                g_fillTypeManager:assignFillTypeTextureArraysFromTerrain(node, g_terrainNode, true, false, false)
                se.useBaseMaterial  = true
                se.hasValidMaterial = true
            else
                g_fillTypeManager:assignFillTypeTextureArraysFromTerrain(node, g_terrainNode, true, true, true)
                -- 1.0.0.9.29: with the grainUnloadingShader the LOOK comes from
                -- the texture array via the fillTypeId shader parameter (set in
                -- setEffectTypeInfo) — the per-filltype material lookup is the
                -- legacy path and has NO MANURE "unloading" entry (field log:
                -- hasValidMaterial=false kept the mesh invisible). Keep the base
                -- material and skip the lookup, exactly as the smoke branch does:
                -- useBaseMaterial=true makes setEffectTypeInfo bypass it.
                se.useBaseMaterial  = true
                se.hasValidMaterial = true
            end
        end
    else
        print(string.format("[SPS SEPARATOR] base material '%s' not found — drop effect skipped", tostring(se.materialType)))
        return nil
    end

    setShaderParameter(node, "fadeProgress", -1, 1, 0, 0, false)
    if not isSmoke and sep.cfg.dropEffectShapeScale ~= nil then
        local sc = sep.cfg.dropEffectShapeScale
        setShaderParameter(node, "shapeScaleSpread", sc[1], sc[2], sc[3], 0.0, false)
    end
    if not isSmoke and sep.cfg.dropEffectControlPoint ~= nil then
        -- y=bending, z/w: shader defaults (0, 1, 0) preserved.
        setShaderParameter(node, "controlPoint", sep.cfg.dropEffectControlPoint, 0.0, 1.0, 0.0, false)
    end
    setVisibility(node, false)
    g_effectManager:setUpdateDistance({ se }, math.huge)
    return se
end

-- Chunk-particle effect: manual ParticleEffect build, source-verified against
-- ParticleEffect.lua — no particle system needed in the i3d; setFillType
-- clones the shared system for cfg.dropParticleType from
-- g_particleSystemManager and applies the fill-type material. The node is the
-- emitter shape (spawn area). Field set mirrors loadEffectAttributes defaults.
local function buildParticleEffect(sep, node)
    if node == nil or node == 0 or not entityExists(node) then return nil end
    if ParticleEffect == nil or g_particleSystemManager == nil then return nil end
    local pe = ParticleEffect.new()
    pe.parent            = sep.placeable
    pe.baseDirectory     = sep.placeable.baseDirectory
    pe.rootNodes         = sep.dropNode
    pe.node              = node
    pe.emitterShape      = node
    pe.emitCountScale    = sep.cfg.dropParticleEmitScale or 1.0
    pe.particleType      = sep.cfg.dropParticleType or "unloading"
    pe.materialType      = "unloading"
    pe.useFruitColor     = false
    pe.worldSpace        = true
    pe.delay             = 0
    pe.startTime         = 0
    pe.startTimeMs       = 0
    pe.stopTime          = 0
    pe.stopTimeMs        = 0
    pe.lifespan          = nil
    pe.extraDistance     = 0.5
    pe.ignoreDistanceLifeSpan = false
    pe.alphaScale        = 1
    pe.velocityScale     = nil
    pe.spriteScale       = 1
    pe.spriteGainScale   = 1
    pe.realStartTime     = math.huge
    pe.realStopTime      = math.huge
    pe.useCuttingWidth   = false
    pe.lastEmitterScale  = 1
    pe.currentEmitCountScale = 1
    pe.particleSystem    = nil
    pe.prio              = 0
    pe.deleteListeners   = {}
    pe.startRestriction  = {}
    pe.allowUpdate       = true
    pe.lastUpdateTime    = 0
    pe.offset            = 0
    g_effectManager:setUpdateDistance({ pe }, math.huge)
    return pe
end

-- Motion-path chunk drop: manual TypedMotionPathEffect build, verified
-- against MotionPathEffect.lua / TypedMotionPathEffect.lua /
-- MotionPathEffectManager.lua. The SHARED chunk meshes (manure quad clouds,
-- $data/effects/manure/manure.i3d, registered in manureEffects.xml) are
-- cloned under the drop node by loadSharedMotionPathEffect at first start();
-- our custom trajectory texture is applied to them as the "shapeArray"
-- custom map by applyEffectConfiguration. Matching: effectType against the
-- registry (strict-then-alternative retry covers registry entries without
-- fill/growth conditions), mesh by exact numRows x rowLength.
-- Animation drive: base update() only advances the path when
-- useVehicleSpeed is set and parent:getLastSpeed() reports movement, so the
-- placeable hands in a stand-in parent reporting full reference speed —
-- effective chunk speed is then speedScale alone.
local function buildMotionPathDrop(sep)
    local cfg = sep.cfg
    if cfg.dropChunksTexture == nil then return nil end
    if TypedMotionPathEffect == nil or g_motionPathEffectManager == nil then
        log("chunk drop: TypedMotionPathEffect/g_motionPathEffectManager unavailable")
        return nil
    end
    if sep.dropNode == nil or not entityExists(sep.dropNode) then
        log("chunk drop: dropNode missing")
        return nil
    end

    local filename = Utils.getFilename(cfg.dropChunksTexture, sep.placeable.baseDirectory)
    local texture = createMaterialTextureFromFile(filename, true, false)
    if texture == nil or texture == 0 then
        print(string.format("[SPS SEPARATOR] chunk drop texture '%s' could not be loaded — chunk effect disabled", tostring(filename)))
        return nil
    end

    local mp = TypedMotionPathEffect.new()
    -- Stand-in parent: reports full reference speed so the path always runs
    -- at speedScale while the effect is on (real drive = start/stop).
    mp.parent = { getLastSpeed = function() return mp.maxReferenceVehicleSpeed end }
    mp.baseDirectory    = sep.placeable.baseDirectory
    mp.rootNodes        = sep.dropNode
    mp.node             = sep.dropNode
    mp.prio             = 0
    mp.deleteListeners  = {}
    mp.startRestriction = {}
    mp.allowUpdate      = true
    mp.lastUpdateTime   = 0
    mp.offset           = 0

    -- MotionPathEffect load-time fields (mirroring loadEffectAttributes).
    mp.linkNodes        = { sep.dropNode }
    mp.effectNode       = sep.dropNode
    mp.effectType       = string.upper(cfg.dropChunksEffectType or "MANURE_SPREADER")
    mp.textureFilename  = filename
    mp.texture          = texture
    mp.textureRealWidth = nil
    mp.numRows          = cfg.dropChunksNumRows
    mp.rowLength        = cfg.dropChunksRowLength
    mp.useVehicleSpeed  = true
    mp.maxReferenceVehicleSpeed = 10
    mp.speedScale       = cfg.dropChunksSpeedScale   -- nil -> registry value
    mp.effectSpeedScale = mp.speedScale or 1
    mp.effectSpeedScaleOrig = mp.effectSpeedScale
    mp.verticalOffset   = nil
    if cfg.dropChunksSizeScale ~= nil then
        mp.shapeScale    = cfg.dropChunksSizeScale[1]
        mp.maxShapeScale = cfg.dropChunksSizeScale[2]
    end
    mp.fadeOutScale     = 1
    mp.minFade          = 0
    mp.inversedFadeOut  = false
    mp.scrollLength     = 1
    mp.startDelay       = 0
    mp.stopDelay        = 0
    mp.currentStartDelay = 0
    mp.currentStopDelay  = 0
    mp.effectDensityScaleSetting = cfg.dropChunksDensity or 1
    mp.densityMask      = nil
    mp.speedReferenceAnimation = nil
    mp.speedReferenceAnimationOffset = 0
    mp.visibilityX      = { 50, -50 }
    mp.visibilityY      = { 50, -50 }
    mp.visibilityZ      = { 50, -50 }
    mp.fadeIn           = 0
    mp.fadeOut          = 0
    mp.fadeVisibilityMin = 1
    mp.fadeVisibilityMax = 0
    mp.speedFunc        = nil

    -- TypedMotionPathEffect specifics: pin the fill type to manure.
    mp.meshType         = nil
    mp.materialType     = nil
    mp.fillTypeIndex    = FillType.MANURE

    g_effectManager:setUpdateDistance({ mp }, math.huge)
    return mp
end

function SPSSeparator.buildDropEffects(sep)
    if g_client == nil then return nil end
    if ShaderPlaneEffect == nil or g_materialManager == nil or g_effectManager == nil then
        log("buildDropEffects: effect classes/managers unavailable (SPE=%s matMgr=%s fxMgr=%s)",
            tostring(ShaderPlaneEffect ~= nil), tostring(g_materialManager ~= nil), tostring(g_effectManager ~= nil))
        return nil
    end
    if sep.dropNode == nil or not entityExists(sep.dropNode) then
        log("buildDropEffects: dropNode missing/dead")
        return nil
    end

    -- Three independent layers; any subset may be present:
    --   child 0 of dropNode  = shader-plane stream mesh (optional)
    --   child 1 of dropNode  = smoke/dust plane (optional)
    --   SPS_dropParticles    = chunk particle emitter (optional)
    --   dropChunksTexture    = motion-path chunk drop (optional)
    local effects = {}
    local numChildren = getNumOfChildren(sep.dropNode)
    if numChildren > 0 then
        local stream = buildOneDropEffect(sep, getChildAt(sep.dropNode, 0), false)
        if stream ~= nil then table.insert(effects, stream) end
    else
        log("dropNode has no child shape — no stream layer (chunk/particle layers unaffected)")
    end
    if numChildren > 1 then
        local smoke = buildOneDropEffect(sep, getChildAt(sep.dropNode, 1), true)
        if smoke ~= nil then table.insert(effects, smoke) end
    end
    if sep.dropParticlesNode ~= nil then
        local pe = buildParticleEffect(sep, sep.dropParticlesNode)
        if pe ~= nil then
            table.insert(effects, pe)
            log("chunk particle effect added (type=%s)", tostring(sep.cfg.dropParticleType))
        end
    end
    local mp = buildMotionPathDrop(sep)
    if mp ~= nil then
        table.insert(effects, mp)
        log("motion-path chunk drop added (%s, %dx%d, tex=%s)",
            tostring(sep.cfg.dropChunksEffectType), sep.cfg.dropChunksNumRows,
            sep.cfg.dropChunksRowLength, tostring(sep.cfg.dropChunksTexture))
    end
    if #effects == 0 then return nil end
    log("drop effects built (%d node(s))", #effects)
    return effects
end

function SPSSeparator.updateDropEffects(sep)
    local shouldRun = sep.isOn and sep.blockReason == SPSSeparator.REASON_NONE
    if shouldRun == sep._effectsOn then return end
    sep._effectsOn = shouldRun
    if sep.dropEffects == nil and shouldRun then
        sep.dropEffects = SPSSeparator.buildDropEffects(sep)
    end
    if sep.dropEffects == nil then
        log("updateDropEffects: no effects built (shouldRun=%s)", tostring(shouldRun))
        return
    end
    if shouldRun then
        g_effectManager:setEffectTypeInfo(sep.dropEffects, FillType.MANURE)
        for i, effect in ipairs(sep.dropEffects) do
            -- hasValidMaterial=false means the MaterialManager lookup for
            -- (MANURE, materialType, 1) failed — vanilla then keeps the mesh
            -- invisible by design. Surface it.
            log("effect %d: materialType=%s hasValidMaterial=%s useArrays=%s",
                i, tostring(effect.materialType), tostring(effect.hasValidMaterial),
                tostring(effect.useFillTypeTextureArrays))
            g_effectManager:startEffect(effect, true)
        end
    else
        g_effectManager:stopEffects(sep.dropEffects)
    end
end

-- ---------------------------------------------------------------------------
-- updateAll — per-tick driver, called from the manager-update wrap.
-- ---------------------------------------------------------------------------
function SPSSeparator.updateAll(mgr, dt)
    for _, pEntry in ipairs(mgr.registeredPlaceables) do
        local sep = pEntry.separator
        if sep ~= nil then
            if g_server ~= nil and sep.isOn then
                SPSSeparator.processTick(mgr, sep, dt)

                -- Roll the 1-second L/h windows for the panel readouts.
                sep._accMs = sep._accMs + dt
                if sep._accMs >= 1000.0 then
                    local hours = sep._accMs / 3600000.0
                    sep.statIntakeLph = sep._accIntake / hours
                    sep.statManureLph = sep._accManure / hours
                    sep._accIntake, sep._accManure, sep._accMs = 0.0, 0.0, 0.0
                end

                -- Periodic stats sync for remote panels (5 s, only while on).
                sep._syncTimerMs = sep._syncTimerMs + dt
                if sep._syncTimerMs >= 5000.0 then
                    sep._syncTimerMs = 0.0
                    if SPSSeparatorEvent ~= nil then
                        SPSSeparatorEvent.sendState(sep)
                    end
                end
            end
            -- Effects follow state on every peer (server included for listen).
            SPSSeparator.updateDropEffects(sep)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Save / load — own file next to the manager's, position-keyed like the
-- manager's thickness entries. Wraps below feed these.
-- ---------------------------------------------------------------------------
function SPSSeparator.saveAll(mgr, directory)
    if directory == nil then return end
    local path = directory .. "/FS25_SPS_Separators.xml"
    local xmlFile = XMLFile.create("spsSeparatorSave", path, "spsSeparators")
    if xmlFile == nil then return end
    local idx = 0
    for _, pEntry in ipairs(mgr.registeredPlaceables) do
        local sep = pEntry.separator
        if sep ~= nil and sep.placeable ~= nil and sep.placeable.components ~= nil
        and sep.placeable.components[1] ~= nil then
            local wx, wy, wz = getWorldTranslation(sep.placeable.components[1].node)
            local base = string.format("spsSeparators.separator(%d)", idx)
            xmlFile:setFloat(base .. "#px", wx)
            xmlFile:setFloat(base .. "#py", wy)
            xmlFile:setFloat(base .. "#pz", wz)
            xmlFile:setBool (base .. "#isOn",           sep.isOn)
            xmlFile:setFloat(base .. "#tightness",      sep.tightness)
            xmlFile:setFloat(base .. "#lifetimeManure", sep.lifetimeManure)
            idx = idx + 1
        end
    end
    xmlFile:save()
    xmlFile:delete()
    log("saved %d separator(s)", idx)
end

function SPSSeparator.loadAll(directory)
    if directory == nil then return end
    local path = directory .. "/FS25_SPS_Separators.xml"
    local xmlFile = XMLFile.loadIfExists("spsSeparatorLoad", path)
    if xmlFile == nil then return end
    SPSSeparator._pendingStates = {}
    local idx = 0
    while true do
        local base = string.format("spsSeparators.separator(%d)", idx)
        if not xmlFile:hasProperty(base) then break end
        table.insert(SPSSeparator._pendingStates, {
            px             = xmlFile:getFloat(base .. "#px", 0),
            py             = xmlFile:getFloat(base .. "#py", 0),
            pz             = xmlFile:getFloat(base .. "#pz", 0),
            isOn           = xmlFile:getBool (base .. "#isOn", false),
            tightness      = xmlFile:getFloat(base .. "#tightness", 0.5),
            lifetimeManure = xmlFile:getFloat(base .. "#lifetimeManure", 0),
        })
        idx = idx + 1
    end
    xmlFile:delete()
    log("loaded %d pending separator state(s)", idx)
end

-- ---------------------------------------------------------------------------
-- Detach handler — sell/delete teardown (registry from 1.0.0.9.3).
-- Idempotent; errors contained by the registry's pcall.
-- ---------------------------------------------------------------------------
SlurryPipeManager.registerPlaceableDetachHandler("Separator", function(mgr, placeable)
    for _, pEntry in ipairs(mgr.registeredPlaceables) do
        if pEntry.placeable == placeable and pEntry.separator ~= nil then
            local sep = pEntry.separator
            if sep.dropEffects ~= nil then
                g_effectManager:stopEffects(sep.dropEffects)
                g_effectManager:deleteEffects(sep.dropEffects)
                sep.dropEffects = nil
            end
            if sep.activatable ~= nil then
                sep.activatable:delete()
                sep.activatable = nil
            end
            sep.isOn = false
            pEntry.separator = nil
            SPSSeparator.log("detached from %s", tostring(placeable.configFileName))
            return
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Manager seams — additive function wraps, installed once at file load.
-- This file loads AFTER the manager + domain modules (modDesc order), so all
-- wrapped functions exist. Every wrap calls the original FIRST and contains
-- its own work in pcall so a separator fault can never break core SPS.
-- ---------------------------------------------------------------------------

-- 1) Per-placeable init after full registration.
local origRegisterPlaceable = SlurryPipeManager.registerPlaceable
function SlurryPipeManager:registerPlaceable(placeable)
    origRegisterPlaceable(self, placeable)
    local ok, err = pcall(SPSSeparator.tryInitForPlaceable, self, placeable)
    if not ok then
        print("[SPS SEPARATOR] ERROR in tryInitForPlaceable: " .. tostring(err))
    end
end

-- 2) Per-tick drive.
local origUpdate = SlurryPipeManager.update
function SlurryPipeManager:update(dt)
    origUpdate(self, dt)
    local ok, err = pcall(SPSSeparator.updateAll, self, dt)
    if not ok then
        if not SPSSeparator._updateErrLogged then
            SPSSeparator._updateErrLogged = true
            print("[SPS SEPARATOR] ERROR in updateAll (further errors suppressed): " .. tostring(err))
        end
    end
end

-- 3) JIP: append separator STATE to the manager's join dump.
local origSendFullState = SlurryPipeManager.sendFullStateToConnection
function SlurryPipeManager:sendFullStateToConnection(connection)
    origSendFullState(self, connection)
    local ok, err = pcall(function()
        if SPSSeparatorEvent == nil then return end
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.separator ~= nil then
                connection:sendEvent(SPSSeparatorEvent.newState(pEntry.separator))
            end
        end
    end)
    if not ok then
        print("[SPS SEPARATOR] ERROR in join dump: " .. tostring(err))
    end
end

-- 4) Save/load piggyback on the manager's savegame file calls; both receive
-- the full path of FS25_SlurryPipeSystem.xml, from which the directory is cut.
local function dirOf(savePath)
    if savePath == nil then return nil end
    return savePath:match("^(.*)[/\\][^/\\]+$")
end

local origSaveConnections = SlurryPipeManager.saveCouplingConnections
function SlurryPipeManager:saveCouplingConnections(savePath)
    origSaveConnections(self, savePath)
    local ok, err = pcall(SPSSeparator.saveAll, self, dirOf(savePath))
    if not ok then
        print("[SPS SEPARATOR] ERROR in saveAll: " .. tostring(err))
    end
end

local origLoadConnections = SlurryPipeManager.loadCouplingConnections
function SlurryPipeManager:loadCouplingConnections(savePath)
    local ok, err = pcall(SPSSeparator.loadAll, dirOf(savePath))
    if not ok then
        print("[SPS SEPARATOR] ERROR in loadAll: " .. tostring(err))
    end
    origLoadConnections(self, savePath)
end

-- 5) Registration gate widening. init.lua's Placeable.finalizePlacement /
-- Placeable.delete wraps only register placeables carrying spec_silo,
-- spec_husbandry, spec_siloExtension or spec_productionPoint — a separator
-- has none of those, so it was never handed to registerPlaceable at all
-- (field log 21:27: i3d placed, zero registerPlaceable lines, no couplers).
-- Chain our own wraps here, gated on the manureHeapSeparator TYPE.
-- Verified from vanilla source that finalizePlacement fires on ALL paths:
-- savegame load (Placeable.lua:494), buy placement, and MP client
-- postReadStream (:676).
-- Load order: this file loads BEFORE init.lua, so init.lua wraps OUR
-- function — both gates run, dedupe via getPlaceableEntry, registerPlaceable
-- itself also carries a duplicate-suppression latch (1.0.0.9.2).
local origPlaceableFinalizeSep = Placeable.finalizePlacement
function Placeable:finalizePlacement()
    origPlaceableFinalizeSep(self)
    if g_slurryPipeManager ~= nil and SPSSeparator.isSeparatorPlaceableType(self) then
        local ok, err = pcall(function()
            if g_slurryPipeManager:getPlaceableEntry(self) == nil then
                g_slurryPipeManager:registerPlaceable(self)
            end
        end)
        if not ok then
            print("[SPS SEPARATOR] ERROR registering separator placeable: " .. tostring(err))
        end
    end
end

local origPlaceableDeleteSep = Placeable.delete
function Placeable:delete(immediate)
    if g_slurryPipeManager ~= nil and SPSSeparator.isSeparatorPlaceableType(self) then
        pcall(function() g_slurryPipeManager:unregisterPlaceable(self) end)
    end
    origPlaceableDeleteSep(self, immediate)
end

-- 6) Chain valve-prompt suppression on separator lines. Chain termini carry
-- their OWN manual valve; SPSChainActivatable._getState exposes the toggle for
-- every non-hydraulic partner regardless of anyone's valveType (verified in
-- source — only SPS_VALVE_TYPE_HYDRAULIC partners and conduit vehicles are
-- suppressed). The separator drives its own flow and ignores valve state
-- entirely, so on any chain touching a separator the valve half of the prompt
-- is remapped away while the useful halves are kept:
--   end arcs   : valve states -> "connectedHydraulicValve" (disconnect prompt
--                only — the exact state a hydraulic partner produces)
--   anchor arc : valve states -> "removePipeChain" (the exact fallback the
--                anchor-arc code path returns when exposeValve is false)
local function couplingBelongsToSeparator(mgr, c)
    if mgr == nil or c == nil or c.placeable == nil then return false end
    return SPSSeparator.findSeparatorByPlaceable(mgr, c.placeable) ~= nil
end

function SPSSeparator.chainTouchesSeparator(mgr, chain, selfCoupling)
    if mgr == nil then return false end
    if couplingBelongsToSeparator(mgr, selfCoupling) then return true end
    if chain == nil then return false end
    if couplingBelongsToSeparator(mgr, chain.anchorCoupling) then return true end
    local segs = chain.segments
    if segs ~= nil then
        local first = segs[1]
        if first ~= nil and first.chainStartCoupling ~= nil
        and couplingBelongsToSeparator(mgr, first.chainStartCoupling.connectedPartnerCoupling) then
            return true
        end
        local last = segs[#segs]
        if last ~= nil and last.chainCoupling ~= nil
        and couplingBelongsToSeparator(mgr, last.chainCoupling.connectedPartnerCoupling) then
            return true
        end
    end
    return false
end

if SPSChainActivatable ~= nil and SPSChainActivatable._getState ~= nil then
    local origChainGetState = SPSChainActivatable._getState
    function SPSChainActivatable:_getState()
        local state = origChainGetState(self)
        if state == "connectedValveOpen" or state == "connectedValveClosed" then
            local ok, touches = pcall(SPSSeparator.chainTouchesSeparator,
                g_slurryPipeManager, self.chain, self.coupling)
            if ok and touches then
                if self.arcIndex == 0 then
                    return "removePipeChain"
                end
                return "connectedHydraulicValve"
            end
        end
        return state
    end
else
    print("[SPS SEPARATOR] WARNING: SPSChainActivatable not loaded before SPSSeparator — valve prompt suppression inactive")
end
