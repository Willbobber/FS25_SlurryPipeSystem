-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.10.3

-- SPSM_Stores.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: multi-store fill planes on one placeable.
--
-- WHY THIS EXISTS
-- ---------------
-- Before this module a placeable could declare exactly ONE <fillPlane>, and that
-- plane was only accepted on spec_silo / spec_husbandry / spec_siloExtension —
-- the placeable types whose Storage the ENGINE drives a fill plane for. A
-- production point (BGA) was excluded: its <fillPlane> produced no sourceEntry at
-- all, which also destroyed the coupling-only fallback that would otherwise have
-- worked. See registerPlaceable.
--
-- Two things had to change:
--   1. Production points get a plane. Nothing drives it, so SPS drives it here:
--      local Y = minY + (level / capacity) * (maxY - minY), every tick, on server
--      AND client (storage levels are synced by vanilla, so both sides agree).
--      SlurryNodeUtil.getSurfaceWorldY reads the plane node's world Y for a
--      STORAGE_PLANE source, so once the node moves, arm submersion detection,
--      agitator bounds tests and crust all work unchanged.
--   2. More than one store per placeable. A BGA holds LIQUIDMANURE and DIGESTATE
--      in ONE Storage object with separate capacities; each wants its own lagoon,
--      its own plane, its own crust. <slurryStores> declares them; each store
--      binds one fillType (or a declared pool of types) to one plane node.
--
-- COMPATIBILITY
-- -------------
-- The legacy singular <fillPlane> block is untouched and still parsed by
-- registerPlaceable. When <slurryStores> is present, store 1 becomes the
-- placeable's PRIMARY sourceEntry (pEntry.sourceEntry), so every existing lookup,
-- save path and HUD read keeps working with no knowledge of stores at all. The
-- extra stores live in pEntry.storeSources alongside it, and the four per-tick
-- store loops in SlurryPipeManager:update iterate getStoreSources(pEntry), which
-- returns { pEntry.sourceEntry } for every legacy placeable. Behaviour for a
-- single-store or plane-less placeable is byte-for-byte what it was.
--
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSM_Stores 1.0.0.10.3 loaded") end


-- ---------------------------------------------------------------------------
-- Debug channel
-- ---------------------------------------------------------------------------
-- Registered in SPSDebugConfig as "SPSM_Stores"; applyAll pushes the channel
-- value into SPSM_Stores.DEBUG, and the console toggle (spsDebug SPSM_Stores on)
-- re-runs applyAll, so this takes effect live with no reload. Ships false.
--
-- Namespace table, declared here so applyAll has a target even though this file
-- otherwise only extends SlurryPipeManager.
SPSM_Stores = SPSM_Stores or {}
SPSM_Stores.DEBUG = false

-- Trace print. Gated. Never use for errors or warnings — those stay unconditional
-- so a broken config is visible in a player log with no channels enabled.
function SPSM_Stores.log(fmt, ...)
    if not SPSM_Stores.DEBUG then return end
    if select("#", ...) > 0 then
        print("[SPS STORES] " .. string.format(fmt, ...))
    else
        print("[SPS STORES] " .. tostring(fmt))
    end
end


-- ---------------------------------------------------------------------------
-- Node resolution, scoped to one store's subtree
-- ---------------------------------------------------------------------------
-- registerPlaceable's findLinkedNode searches linkedNodes and then the WHOLE
-- placeable component tree by name, first match wins. That is fine for one store
-- but breaks the moment a second store reuses the same child names (the natural
-- authoring style: duplicate the slurryStore group in the nodeTree, rename only
-- the group). Store child nodes therefore resolve from the store node DOWN, so
-- slurryStore01/crust_fillPlane and slurryStore02/crust_fillPlane stay distinct
-- even if an author forgets to suffix them.
function SlurryPipeManager.findNodeInSubtree(root, name)
    if root == nil or root == 0 or name == nil or name == "" then return nil end
    if getName(root) == name then return root end
    for i = 0, getNumOfChildren(root) - 1 do
        local found = SlurryPipeManager.findNodeInSubtree(getChildAt(root, i), name)
        if found ~= nil then return found end
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- Fill type set parsing
-- ---------------------------------------------------------------------------
-- A store's POOL is the set of fill types whose levels are treated as one body of
-- slurry for the dry-matter model and for driving the plane. Default is just the
-- store's declared #fillType. baseTank's behaviour (slurry + digestate in one pit,
-- one plane, one crust) is expressed by declaring both in #poolFillTypes.
--
-- This set is what stops _getStoreTotalFill summing every type in the Storage: on
-- a BGA that sum includes 102000 l of SILAGE, which would read as slurry and crust
-- over an empty lagoon.
function SlurryPipeManager.parseFillTypeSet(str, fallbackFillType)
    local set   = {}
    local count = 0
    if str ~= nil and str ~= "" then
        for name in str:gmatch("%S+") do
            local ft = g_fillTypeManager:getFillTypeIndexByName(name)
            if ft ~= nil then
                set[ft] = true
                count   = count + 1
            else
                print("[SPS WARNING] slurryStore: unknown fillType '" .. tostring(name) .. "' in poolFillTypes — ignored")
            end
        end
    end
    if count == 0 and fallbackFillType ~= nil then
        set[fallbackFillType] = true
        count = 1
    end
    if count == 0 then return nil end
    return set
end


-- ---------------------------------------------------------------------------
-- parseSlurryStores
-- ---------------------------------------------------------------------------
-- Reads <slurryStores><slurryStore .../></slurryStores> and returns an ordered
-- array of STORAGE_PLANE sourceEntries, or nil when the block is absent (the
-- legacy <fillPlane> path then runs untouched in registerPlaceable).
--
-- Each store entry carries, on top of the normal STORAGE_PLANE fields:
--   storeId        - author-declared id, used by <pipeCoupling #storeId>
--   storeNode      - the store's root TransformGroup (subtree scope + Y frame)
--   drivePlane     - true when SPS must move the plane itself (see updateStorePlanes)
--   planeBaseX/Z   - the plane's authored local X/Z, preserved when Y is driven
--   poolFillTypes  - set of fill types treated as one body (see parseFillTypeSet)
--   hideWhenEmpty  - hide the plane mesh at zero level rather than leaving a film
--                    of slurry lying on the pit floor
--   crustCfg       - per-store crust node names (plane/foliage/maxRise)
--   thickeningEnabled - per-store agitator/crust participation
function SlurryPipeManager:parseSlurryStores(placeable, xmlFile, kp, findLinkedNode)
    kp = kp or ""
    local baseKey = kp .. "slurryPipeSystem.slurryStores"
    if not xmlFile:hasProperty(baseKey) then return nil end

    -- Resolve the placeable's Storage once. Every store on one placeable shares it
    -- (a BGA's LIQUIDMANURE and DIGESTATE live in the SAME Storage object with
    -- separate per-type capacities — see bga250kw.xml <storage><capacity/>), so the
    -- stores differ by fill type and plane, not by storage handle.
    local storage = nil
    if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
        storage = placeable.spec_silo.storages[1]
    end
    if storage == nil and placeable.spec_husbandry ~= nil then
        local sh = placeable.spec_husbandry
        if sh.husbandry ~= nil and sh.husbandry.storage ~= nil
        and type(sh.husbandry.storage.getFillLevel) == "function" then
            storage = sh.husbandry.storage
        elseif sh.storage ~= nil and type(sh.storage.getFillLevel) == "function" then
            storage = sh.storage
        end
    end
    if storage == nil and placeable.spec_siloExtension ~= nil
    and placeable.spec_siloExtension.storage ~= nil then
        storage = placeable.spec_siloExtension.storage
    end
    if storage == nil and placeable.spec_productionPoint ~= nil
    and placeable.spec_productionPoint.productionPoint ~= nil
    and placeable.spec_productionPoint.productionPoint.storage ~= nil then
        storage = placeable.spec_productionPoint.productionPoint.storage
    end

    if storage == nil then
        print("[SPS WARNING] slurryStores declared on " .. tostring(placeable.configFileName)
            .. " but no Storage object was found — stores skipped")
        return nil
    end

    -- A production point never has an engine-driven fill plane: nothing in vanilla
    -- links its Storage levels to a plane node, so SPS drives the plane itself.
    -- A silo DOES have one, so leave the engine in charge there and do not fight it.
    -- [SPS 1.0.1.8] Per-store rule instead of per-placeable-type: ask the Storage.
    -- Vanilla keeps every plane it will move in storage.fillPlanes[fillType]
    -- (Storage.lua:119-137, verified). No entry for this store's type = nothing in
    -- vanilla ever moves the node, so SPS must (husbandry barns with a decorative
    -- or purely virtual surface, e.g. The Mechet fattening shed). An entry = the
    -- engine owns it, exactly as before. Production points stay always-driven.
    local function spsMustDrivePlane(ft)
        if placeable.spec_productionPoint ~= nil and placeable.spec_silo == nil then return true end
        local planes = storage.fillPlanes
        return planes == nil or ft == nil or planes[ft] == nil
    end

    local stores = {}
    local idx    = 0
    while true do
        local sKey = string.format("%s.slurryStore(%d)", baseKey, idx)
        if not xmlFile:hasProperty(sKey) then break end
        idx = idx + 1

        local storeId       = xmlFile:getInt(sKey .. "#id", idx)
        local storeNodeName = xmlFile:getString(sKey .. "#node", nil)
        local storeNode     = findLinkedNode(storeNodeName)

        if storeNode == nil or storeNode == 0 then
            print("[SPS WARNING] slurryStore id=" .. tostring(storeId) .. " node '"
                .. tostring(storeNodeName) .. "' not found — store skipped")
        else
            -- All child lookups below are scoped to this store's subtree.
            local function resolve(name)
                return SlurryPipeManager.findNodeInSubtree(storeNode, name)
            end

            local fillTypeName = xmlFile:getString(sKey .. "#fillType", "LIQUIDMANURE")
            local fillType     = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
            if fillType == nil then
                print("[SPS WARNING] slurryStore id=" .. tostring(storeId) .. " unknown fillType '"
                    .. tostring(fillTypeName) .. "' — falling back to LIQUIDMANURE")
                fillType = FillType.LIQUIDMANURE
            end

            local planeName = xmlFile:getString(sKey .. "#fillPlaneNode", nil)
            local planeNode = resolve(planeName)
            if planeNode == nil or planeNode == 0 then
                print("[SPS WARNING] slurryStore id=" .. tostring(storeId) .. " fillPlaneNode '"
                    .. tostring(planeName) .. "' not found under '" .. tostring(storeNodeName) .. "'")
            end

            local minY = xmlFile:getFloat(sKey .. "#minY", 0)
            local maxY = xmlFile:getFloat(sKey .. "#maxY", 1)

            -- XZ detection bounds, same two shapes registerPlaceable supports for
            -- <fillPlane>. Nodes resolve inside the store subtree first, then fall
            -- back to the placeable-wide search so bounds nodes authored outside the
            -- store group (as on bga250kw, where they sit beside the couplers) still
            -- resolve. Y of these nodes is irrelevant — only XZ is used.
            local function resolveBounds(name)
                if name == nil or name == "" then return nil end
                local n = resolve(name)
                if n == nil then n = findLinkedNode(name) end
                return n
            end

            local planeBounds = nil
            local shape       = xmlFile:getString(sKey .. "#shape", nil)
            local centreNode  = resolveBounds(xmlFile:getString(sKey .. "#centreNodeName", nil))
            if shape == "round" then
                local edgeNode = resolveBounds(xmlFile:getString(sKey .. "#edgeNodeName", nil))
                if centreNode ~= nil and edgeNode ~= nil then
                    local cx, _, cz = getWorldTranslation(centreNode)
                    local ex, _, ez = getWorldTranslation(edgeNode)
                    local radius = math.sqrt((cx - ex) * (cx - ex) + (cz - ez) * (cz - ez))
                    planeBounds = { shape = "round", centreNode = centreNode, radius = radius }
                else
                    print("[SPS WARNING] slurryStore id=" .. tostring(storeId)
                        .. " shape=round but centre/edge node missing — no arm detection on this store")
                end
            elseif shape == "rectangle" then
                local c1 = resolveBounds(xmlFile:getString(sKey .. "#corner1NodeName", nil))
                local c2 = resolveBounds(xmlFile:getString(sKey .. "#corner2NodeName", nil))
                if centreNode ~= nil and c1 ~= nil and c2 ~= nil then
                    local c1x, c1y, c1z = getWorldTranslation(c1)
                    local c2x, c2y, c2z = getWorldTranslation(c2)
                    local lx1, _, lz1 = worldToLocal(centreNode, c1x, c1y, c1z)
                    local lx2, _, lz2 = worldToLocal(centreNode, c2x, c2y, c2z)
                    planeBounds = {
                        shape      = "rectangle",
                        centreNode = centreNode,
                        minX       = math.min(lx1, lx2),
                        maxX       = math.max(lx1, lx2),
                        minZ       = math.min(lz1, lz2),
                        maxZ       = math.max(lz1, lz2),
                    }
                else
                    print("[SPS WARNING] slurryStore id=" .. tostring(storeId)
                        .. " shape=rectangle but centre/corner node missing — no arm detection on this store")
                end
            end

            local poolSet   = SlurryPipeManager.parseFillTypeSet(
                                  xmlFile:getString(sKey .. "#poolFillTypes", nil), fillType)
            local poolCount = 0
            if poolSet ~= nil then
                for _ in pairs(poolSet) do poolCount = poolCount + 1 end
            end

            local se = {
                type          = SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE,
                placeable     = placeable,
                storage       = storage,
                fillPlaneNode = planeNode,
                minY          = minY,
                maxY          = maxY,
                fillType      = fillType,
                planeBounds   = planeBounds,
                debugLabel    = (tostring(placeable.configFileName):match("([^/]+)%.xml$") or "placeable")
                                .. "#store" .. tostring(storeId),

                storeId       = storeId,
                storeNode     = storeNode,
                storeIndex    = #stores + 1,
                poolFillTypes = poolSet,
                hideWhenEmpty = xmlFile:getBool(sKey .. "#hideWhenEmpty", true),
                drivePlane    = spsMustDrivePlane(fillType) and planeNode ~= nil and planeNode ~= 0,
                -- Per-store, NOT per-placeable: a slurry lagoon crusts and takes an
                -- agitator; a digestate lagoon beside it need not.
                thickeningEnabled = xmlFile:getBool(sKey .. "#agitator", false),
            }

            -- Preserve the plane's authored local X/Z; only Y is driven.
            if se.drivePlane then
                local px, _, pz = getTranslation(planeNode)
                se.planeBaseX, se.planeBaseZ = px, pz
            end

            -- Per-store crust node names. The plant list and density stay at
            -- placeable level (<crust density><plant/></crust>) since every lagoon on
            -- one placeable grows the same flora; only the nodes differ.
            if xmlFile:hasProperty(sKey .. ".crust") then
                se.crustCfg = {
                    planeNodeName   = xmlFile:getString(sKey .. ".crust#planeNode", nil),
                    foliageNodeName = xmlFile:getString(sKey .. ".crust#foliageNode", nil),
                    maxRise         = xmlFile:getFloat(sKey .. ".crust#maxRise", 0.1),
                }
            end

            table.insert(stores, se)
            SPSM_Stores.log("parsed store id=%s idx=%d fillType=%s plane=%s minY=%.3f maxY=%.3f drive=%s bounds=%s agitator=%s pool=%d",
                tostring(storeId), se.storeIndex, tostring(fillTypeName), tostring(planeNode), minY, maxY,
                tostring(se.drivePlane), tostring(planeBounds ~= nil and planeBounds.shape or "none"),
                tostring(se.thickeningEnabled), poolCount)
        end
    end

    if #stores == 0 then return nil end
    return stores
end


-- ---------------------------------------------------------------------------
-- getStoreSources
-- ---------------------------------------------------------------------------
-- The single accessor every per-tick store loop uses. Returns the full store list
-- for a multi-store placeable, or a one-element list holding the legacy primary
-- sourceEntry for everything else. Never returns nil.
-- [SPS PERF] Called from 6+ per-tick loops per placeable; the legacy single-entry
-- list is memoised on the pEntry (rebuilt if sourceEntry is ever swapped) and the
-- empty result is a shared constant, so this no longer allocates per call. Callers
-- only iterate the result — never mutate it.
local SPS_EMPTY_SOURCES = {}

function SlurryPipeManager:getStoreSources(pEntry)
    if pEntry == nil then return SPS_EMPTY_SOURCES end
    if pEntry.storeSources ~= nil and #pEntry.storeSources > 0 then
        return pEntry.storeSources
    end
    local se = pEntry.sourceEntry
    if se ~= nil then
        local cached = pEntry._singleSourceList
        if cached ~= nil and cached[1] == se then
            return cached
        end
        cached = { se }
        pEntry._singleSourceList = cached
        return cached
    end
    return SPS_EMPTY_SOURCES
end


-- Returns the store sourceEntry a coupling should read/write, honouring the
-- coupling's #storeId, then its #fillType, then falling back to the primary.
function SlurryPipeManager:getStoreSourceForCoupling(pEntry, storeId, fillType)
    local sources = self:getStoreSources(pEntry)
    if #sources == 0 then return nil end
    if storeId ~= nil then
        for _, se in ipairs(sources) do
            if se.storeId == storeId then return se end
        end
        print("[SPS WARNING] pipeCoupling references storeId=" .. tostring(storeId)
            .. " which does not exist — falling back to the primary store")
    end
    if fillType ~= nil then
        for _, se in ipairs(sources) do
            if se.poolFillTypes ~= nil and se.poolFillTypes[fillType] then return se end
        end
    end
    return sources[1]
end


-- ---------------------------------------------------------------------------
-- updateStorePlanes
-- ---------------------------------------------------------------------------
-- Drive each SPS-owned fill plane's local Y from the store's real level. Runs on
-- server AND client, unconditionally of the realism master toggle: this is the
-- visual representation of a vanilla storage level, not a realism feature, and
-- vanilla syncs those levels to clients itself (fillLevelSyncThreshold in the
-- placeable xml), so both sides compute the same Y from the same input.
--
-- Level is the POOL total, capacity the pool total capacity, so a store declaring
-- two pooled types shows their combined body. With the default single-type pool
-- this is exactly the level shown on the production point's own display.
function SlurryPipeManager:updateStorePlanes()
    for _, pEntry in ipairs(self.registeredPlaceables) do
        local sources = self:getStoreSources(pEntry)
        for _, se in ipairs(sources) do
            if se.drivePlane and se.fillPlaneNode ~= nil and se.fillPlaneNode ~= 0
            and entityExists(se.fillPlaneNode) and se.storage ~= nil then
                local level, capacity = 0, 0
                if se.poolFillTypes ~= nil then
                    for ft, _ in pairs(se.poolFillTypes) do
                        level    = level    + (se.storage:getFillLevel(ft) or 0)
                        capacity = capacity + (se.storage:getCapacity(ft) or 0)
                    end
                else
                    level    = se.storage:getFillLevel(se.fillType) or 0
                    capacity = se.storage:getCapacity(se.fillType) or 0
                end

                local ratio = 0
                if capacity > 0 then
                    ratio = math.clamp(level / capacity, 0, 1)
                end
                local y = se.minY + ratio * (se.maxY - se.minY)

                -- Only touch the node when it actually moved. setTranslation every
                -- frame on an unchanged value is wasted work on a store that sits
                -- full for a whole season.
                if se._lastPlaneY == nil or math.abs(y - se._lastPlaneY) > 0.0005 then
                    se._lastPlaneY = y
                    setTranslation(se.fillPlaneNode, se.planeBaseX or 0, y, se.planeBaseZ or 0)
                end

                -- Throttled trace: the plane is driven every frame on every machine, so
                -- an ungated print here would flood a dedicated server log. Only report
                -- when the height actually stepped, and only on the channel.
                if SPSM_Stores.DEBUG and se._tracedPlaneY ~= se._lastPlaneY then
                    se._tracedPlaneY = se._lastPlaneY
                    SPSM_Stores.log("plane store=%s side=%s level=%.0f cap=%.0f ratio=%.3f y=%.3f",
                        tostring(se.storeId), (g_server ~= nil) and "server" or "client",
                        level, capacity, ratio, y)
                end

                if se.hideWhenEmpty then
                    local visible = ratio > 0.0005
                    if se._planeVisible ~= visible then
                        se._planeVisible = visible
                        setVisibility(se.fillPlaneNode, visible)
                    end
                end
            end
        end
    end
end


-- ---------------------------------------------------------------------------
-- initStoreCrust
-- ---------------------------------------------------------------------------
-- Per-store version of the crust setup registerPlaceable performs for the legacy
-- single plane: parent the crust mesh onto the slurry plane so it tracks the
-- surface for free, snap it to the restored settle height, bind the foliage
-- anchor, then scatter vegetation for that store.
--
-- Only runs for stores parsed from <slurryStores>; the legacy <fillPlane> crust
-- block in registerPlaceable is untouched and still owns the single-plane case.
function SlurryPipeManager:initStoreCrust(pEntry)
    if pEntry == nil or pEntry.storeSources == nil then return end

    for _, se in ipairs(pEntry.storeSources) do
        local cc = se.crustCfg
        if cc ~= nil and se.fillPlaneNode ~= nil and se.fillPlaneNode ~= 0 then
            if cc.planeNodeName ~= nil and cc.planeNodeName ~= "" then
                local crustPlaneNode = SlurryPipeManager.findNodeInSubtree(se.storeNode, cc.planeNodeName)
                if crustPlaneNode ~= nil and crustPlaneNode ~= 0 then
                    if getParent(crustPlaneNode) ~= se.fillPlaneNode then
                        link(se.fillPlaneNode, crustPlaneNode)
                        setRotation(crustPlaneNode, 0, 0, 0)
                        SPSM_Stores.log("re-parented crust plane '%s' onto store %s fill plane",
                            tostring(cc.planeNodeName), tostring(se.storeId))
                    end
                    se.crustPlaneNode = crustPlaneNode; se._crustPlaneY = nil
                    se.crustMaxRise   = cc.maxRise or 0.1
                    local settle0 = se.settle or se._migratedSettle or 0
                    setTranslation(crustPlaneNode, 0, settle0 * se.crustMaxRise, 0)
                else
                    print("[SPS WARNING] slurryStore id=" .. tostring(se.storeId) .. " crust planeNode '"
                        .. tostring(cc.planeNodeName) .. "' not found under the store node")
                end
            end

            if cc.foliageNodeName ~= nil and cc.foliageNodeName ~= "" then
                local anchor = SlurryPipeManager.findNodeInSubtree(se.storeNode, cc.foliageNodeName)
                if anchor ~= nil and anchor ~= 0 then
                    se.crustFoliageNode = anchor
                else
                    print("[SPS WARNING] slurryStore id=" .. tostring(se.storeId) .. " crust foliageNode '"
                        .. tostring(cc.foliageNodeName) .. "' not found under the store node")
                end
            end
        end

        -- Scatter this store's own vegetation. Instances are held on the store
        -- sourceEntry, not the placeable, so two lagoons keep separate plant sets.
        if pEntry.crustConfig ~= nil and SPSCrustVegetation ~= nil and se.crustCfg ~= nil then
            SPSCrustVegetation.initForPlaceable(pEntry, self.modDirectory, se)
        end
    end
end


-- ---------------------------------------------------------------------------
-- Store lookup by index (multiplayer)
-- ---------------------------------------------------------------------------
-- SPSStoreCrustEvent carries a 1-based store index alongside the placeable so a
-- multi-store placeable's lagoons stay independent across the wire. Index 1 is
-- the primary sourceEntry, which is what every single-store placeable uses.
function SlurryPipeManager:getStoreSourceByIndex(pEntry, storeIndex)
    local sources = self:getStoreSources(pEntry)
    if #sources == 0 then return nil end
    local se = sources[storeIndex or 1]
    if se == nil then
        -- Index out of range means the two machines disagree about how many stores
        -- this placeable has — a genuine config/version mismatch, not a race. Warn
        -- unconditionally and fall back to the primary so the crust still lands
        -- somewhere sensible rather than being silently dropped.
        print("[SPS WARNING] store crust addressed index " .. tostring(storeIndex)
            .. " but this machine has " .. tostring(#sources)
            .. " store(s) on " .. tostring(pEntry.placeable ~= nil and pEntry.placeable.configFileName or "?")
            .. " — server and client may be running different builds or configs")
        return sources[1]
    end
    return se
end


-- ---------------------------------------------------------------------------
-- logStoreMPState
-- ---------------------------------------------------------------------------
-- One-line-per-store dump of everything that has to agree across the wire. Called
-- from the JIP full-state pass so a join can be diffed against the server's view.
-- Levels come from vanilla storage sync, solids/settle from SPSStoreCrustEvent;
-- if those disagree after a join, this line says which of the two drifted.
function SlurryPipeManager:logStoreMPState(tag)
    if not SPSM_Stores.DEBUG then return end
    for _, pEntry in ipairs(self.registeredPlaceables) do
        local sources = self:getStoreSources(pEntry)
        for i, se in ipairs(sources) do
            if se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                local lvl = 0
                if se.storage ~= nil and se.poolFillTypes ~= nil then
                    for ft, _ in pairs(se.poolFillTypes) do
                        lvl = lvl + (se.storage:getFillLevel(ft) or 0)
                    end
                end
                SPSM_Stores.log("%s idx=%d id=%s level=%.0f solids=%.1f settle=%.3f plane=%s",
                    tostring(tag), i, tostring(se.storeId), lvl,
                    se.solids or 0, se.settle or 0,
                    (se.drivePlane and string.format("%.3f", se._lastPlaneY or 0)) or "engine")
            end
        end
    end
end
