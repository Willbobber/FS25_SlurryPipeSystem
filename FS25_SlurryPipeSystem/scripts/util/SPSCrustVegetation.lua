-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.10.3

-- SPSCrustVegetation.lua
-- Manages procedural vegetation on slurry fill planes.
-- Each i3d contains exactly one stage of one plant — no shape hiding needed.
-- Stage is declared per plant in fillPoints.xml.
-- All pools share a global exclusion zone so no two instances overlap.

print("[SPS BUILD] SPSCrustVegetation 1.0.0.10.3 loaded")

SPSCrustVegetation = {}

-- [SPS 1.0.1.6] Channel-gated trace (registry channel "SPSCrustVegetation",
-- wired at last). These were raw print()s firing for every SPS store at map
-- load — 12 lines on one Witcombe load — against the ship-every-channel-false
-- discipline. Failure-grade lines (load/clone failures) stay always-on.
local function cvLog(msg)
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn ~= nil
    and SPSDebugConfig.isOn("SPSCrustVegetation") then
        print(msg)
    end
end

SPSCrustVegetation.THRESH = { [1] = 0.4, [2] = 0.6, [3] = 0.8 }

-- ---------------------------------------------------------------------------
-- readConfig
-- ---------------------------------------------------------------------------
function SPSCrustVegetation.readConfig(xmlFile, keyPrefix)
    -- keyPrefix ("" for a standalone fillPoints.xml whose root is <slurryPipeSystem>;
    -- non-empty when the <slurryPipeSystem> block is embedded inside a placeable xml,
    -- e.g. own-folder store tanks). Mirrors the kp pattern used everywhere else in
    -- registerPlaceable (fillPlane, couplings, etc.), so embedded configs resolve too.
    local kp = keyPrefix or ""
    if not xmlFile:hasProperty(kp .. "slurryPipeSystem.crust") then return nil end
    local density = xmlFile:getFloat(kp .. "slurryPipeSystem.crust#density", 0.3)
    local plants  = {}
    local idx = 0
    while true do
        local pKey = string.format(kp .. "slurryPipeSystem.crust.plant(%d)", idx)
        if not xmlFile:hasProperty(pKey) then break end
        local i3dRelPath = xmlFile:getString(pKey .. "#i3d")
        local stage      = xmlFile:getInt(pKey .. "#stage", 1)
        local weight     = xmlFile:getInt(pKey .. "#weight", 1)
        if i3dRelPath ~= nil then
            table.insert(plants, { i3dRelPath = i3dRelPath, stage = stage, weight = weight })
        end
        idx = idx + 1
    end
    if #plants == 0 then return nil end
    -- Optional crust plane mesh: when authored, the plane rises with the store's
    -- settle value and foliage is attached to it (so the plants ride the crust).
    -- maxRise is the height (m) above the slurry surface at full crust (settle=1).
    local planeNode = xmlFile:getString(kp .. "slurryPipeSystem.crust#planeNode", nil)
    -- Dedicated foliage anchor plane (child of the crust mesh). When set, foliage
    -- attaches here only; nothing is placed on the crust mesh or slurry plane.
    local foliageNode = xmlFile:getString(kp .. "slurryPipeSystem.crust#foliageNode", nil)
    -- Keep foliage this many metres clear of the plane edge (and inside the plane
    -- area). 0.1 = 100 mm. Default 0 = sample right up to the edge.
    local edgeMargin = xmlFile:getFloat(kp .. "slurryPipeSystem.crust#edgeMargin", 0)

    -- Read maxRise defensively and log exactly what was found, so a value that
    -- silently falls back to the default can be diagnosed from the log.
    local hasMaxRise = xmlFile:hasProperty(kp .. "slurryPipeSystem.crust#maxRise")
    local rawMaxRise = xmlFile:getString(kp .. "slurryPipeSystem.crust#maxRise", nil)
    local maxRise    = xmlFile:getFloat(kp .. "slurryPipeSystem.crust#maxRise", -1)
    if maxRise < 0 then
        -- getFloat failed/defaulted: try parsing the raw string ourselves, accepting
        -- a comma decimal separator (locale), then fall back to 0.1.
        local parsed = nil
        if rawMaxRise ~= nil then
            parsed = tonumber((tostring(rawMaxRise):gsub(",", ".")))
        end
        maxRise = parsed or 0.1
    end
    cvLog("[SPS Crust] readConfig file='" .. tostring(xmlFile.filename)
        .. "' hasMaxRise=" .. tostring(hasMaxRise)
        .. " rawMaxRise='" .. tostring(rawMaxRise) .. "'"
        .. " -> maxRise=" .. tostring(maxRise)
        .. " density=" .. tostring(density)
        .. " planeNode=" .. tostring(planeNode)
        .. " foliageNode=" .. tostring(foliageNode))

    return { density = density, plants = plants, planeNode = planeNode,
             maxRise = maxRise, foliageNode = foliageNode, edgeMargin = edgeMargin }
end

-- ---------------------------------------------------------------------------
-- initForPlaceable
-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.31] sourceEntry is now an explicit optional argument. A placeable
-- declaring <slurryStores> calls this once per store, passing that store's entry, and
-- the resulting plant instances are held on the STORE (sourceEntry.crustInstances)
-- rather than the placeable — two lagoons on one BGA keep separate plant sets, and
-- each follows its own crust plane. Omitting the argument selects the placeable's
-- primary source, which is exactly what every single-plane placeable did before.
function SPSCrustVegetation.initForPlaceable(pEntry, modDirectory, sourceEntry)
    local cfg         = pEntry.crustConfig
    sourceEntry       = sourceEntry or pEntry.sourceEntry
    cvLog("[SPS CrustVeg] initForPlaceable: " .. tostring(pEntry.placeable ~= nil and pEntry.placeable.configFileName or "nil")
        .. " cfg=" .. tostring(cfg ~= nil)
        .. " sourceEntry=" .. tostring(sourceEntry ~= nil)
        .. " fillPlaneNode=" .. tostring(sourceEntry ~= nil and sourceEntry.fillPlaneNode ~= nil or false)
        .. " planeBounds=" .. tostring(sourceEntry ~= nil and sourceEntry.planeBounds ~= nil or false))
    if cfg == nil then return end
    if sourceEntry == nil or sourceEntry.fillPlaneNode == nil then return end
    if sourceEntry.planeBounds == nil then return end

    local fillPlaneNode = sourceEntry.fillPlaneNode
    local bounds        = sourceEntry.planeBounds

    -- Attach foliage to the dedicated crustFoliage anchor when one is present, so
    -- the plants sit flat on it and ride the crust as it rises. If a store has no
    -- foliage anchor, fall back to the slurry plane (legacy behaviour). The crust
    -- mesh itself is never used as a foliage parent. XZ placement still uses the
    -- slurry-plane bounds; only the attach parent differs.
    local attachNode = (sourceEntry.crustFoliageNode ~= nil and sourceEntry.crustFoliageNode ~= 0)
        and sourceEntry.crustFoliageNode or fillPlaneNode
    cvLog("[SPS CrustVeg] foliage attach node = "
        .. tostring(attachNode == sourceEntry.crustFoliageNode and "crustFoliage" or "slurryPlane")
        .. " (" .. tostring(attachNode) .. ")")

    -- [SPS 1.0.0.10.3] Keep the attach node so updateVisibility can recompute each
    -- plant's world position from it LIVE. Clones are world-parented (1.0.0.9.15),
    -- so nothing about the slurry surface height reaches them automatically.
    sourceEntry.crustAttachNode = attachNode

    -- Does the attach node already sit under the crust plane? If so it inherits the
    -- settle rise through its parent and updateVisibility must NOT add it again.
    -- A store with no crust mesh falls back to the slurry plane, which carries the
    -- surface height but not the rise, so there the rise IS applied. Walked once
    -- here rather than assumed, because both authoring styles ship.
    sourceEntry.crustFoliageInheritsRise = false
    if sourceEntry.crustPlaneNode ~= nil and sourceEntry.crustPlaneNode ~= 0 then
        local n = attachNode
        while n ~= nil and n ~= 0 do
            if n == sourceEntry.crustPlaneNode then
                sourceEntry.crustFoliageInheritsRise = true
                break
            end
            n = getParent(n)
        end
    end
    cvLog("[SPS CrustVeg] foliage inherits crust rise = "
        .. tostring(sourceEntry.crustFoliageInheritsRise))

    local area
    if bounds.shape == "round" then
        area = math.pi * bounds.radius * bounds.radius
    else
        area = (bounds.maxX - bounds.minX) * (bounds.maxZ - bounds.minZ)
    end

    local totalCount = math.max(3, math.floor(area * cfg.density))
    local poolSize   = math.floor(totalCount / 3)
    local minDist    = math.max(0.5, 1.2 / math.sqrt(cfg.density + 0.001))

    -- Build per-stage weighted lists
    local byStage = { [1] = {}, [2] = {}, [3] = {} }
    for _, plant in ipairs(cfg.plants) do
        local s = plant.stage
        if byStage[s] ~= nil then
            for _ = 1, plant.weight do
                table.insert(byStage[s], plant)
            end
        end
    end

    sourceEntry.crustInstances = { [1] = {}, [2] = {}, [3] = {} }

    -- Load each unique i3d exactly once, cache the template node, then clone
    -- per instance. This avoids one loadI3DFile call (and one engine load-log
    -- line) per placed plant, which was spamming the log.
    local loaded = {}  -- fullPath -> { i3dRoot = id, template = node }

    local function getTemplate(fullPath)
        local cached = loaded[fullPath]
        if cached ~= nil then return cached.template end
        local i3dRoot = loadI3DFile(fullPath, false, false)
        if i3dRoot == nil or i3dRoot == 0 then
            print("[SPS CrustVeg] failed to load " .. tostring(fullPath))
            loaded[fullPath] = { i3dRoot = 0, template = nil }
            return nil
        end
        local template = getChildAt(i3dRoot, 0)
        if template == nil or template == 0 then
            print("[SPS CrustVeg] no root node in " .. tostring(fullPath))
            delete(i3dRoot)
            loaded[fullPath] = { i3dRoot = 0, template = nil }
            return nil
        end
        loaded[fullPath] = { i3dRoot = i3dRoot, template = template }
        return template
    end

    -- Global exclusion zone shared across all three stage pools
    local allPlaced = {}
    local cx, cy, cz = getWorldTranslation(bounds.centreNode)

    -- Keep plants clear of the plane edge. Shrinks the sampling region inward by
    -- this many metres so foliage stays on the plane and away from its rim.
    local margin = cfg.edgeMargin or 0

    local function pickPosition()
        for _ = 1, 30 do
            local wx, wz
            if bounds.shape == "round" then
                local maxR   = math.max(0, bounds.radius - margin)
                local angle  = math.random() * 2 * math.pi
                local radius = math.sqrt(math.random()) * maxR
                wx = cx + radius * math.cos(angle)
                wz = cz + radius * math.sin(angle)
            else
                local minX, maxX = bounds.minX + margin, bounds.maxX - margin
                local minZ, maxZ = bounds.minZ + margin, bounds.maxZ - margin
                if maxX < minX then minX = (bounds.minX + bounds.maxX) * 0.5; maxX = minX end
                if maxZ < minZ then minZ = (bounds.minZ + bounds.maxZ) * 0.5; maxZ = minZ end
                local lx = minX + math.random() * (maxX - minX)
                local lz = minZ + math.random() * (maxZ - minZ)
                wx, _, wz = localToWorld(bounds.centreNode, lx, 0, lz)
            end
            local ok = true
            for _, p in ipairs(allPlaced) do
                local dx, dz = wx - p[1], wz - p[2]
                if dx * dx + dz * dz < minDist * minDist then ok = false break end
            end
            if ok then return wx, wz end
        end
        return nil, nil
    end

    local function placeInstance(wx, wz, plant)
        local fullPath = modDirectory .. plant.i3dRelPath
        local template = getTemplate(fullPath)
        if template == nil then
            return nil
        end
        -- Clone the cached template rather than reloading the i3d each time
        local plantRoot = clone(template, false, false, false)
        if plantRoot == nil or plantRoot == 0 then
            print("[SPS CrustVeg] clone failed for " .. tostring(fullPath))
            return nil
        end
        -- [SPS 1.0.0.9.15] Clones are parented to the WORLD root, not the
        -- placeable subtree (same pattern as chain pipes). MP field logs showed
        -- why: on sell, the engine deleted the placeable's children (our 347
        -- clones) BEFORE our hook ran — SPS's registry went stale AND vanilla
        -- Placeable:setOverlayColor's construction-hover node list still held
        -- the dead ids, throwing three "Unknown entity id" shader stacks per
        -- sell. World-parented clones are never in the placeable's tree, so
        -- the overlay never lists them, the sell never kills them behind our
        -- back, and deleteForPlaceable now genuinely deletes. Height above the
        -- rising crust plane is followed in updateVisibility instead of being
        -- inherited from the old parent.
        local lx, _, lz = worldToLocal(attachNode, wx, 0, wz)
        local wpx, wpy, wpz = localToWorld(attachNode, lx, 0, lz)
        link(getRootNode(), plantRoot)
        setWorldTranslation(plantRoot, wpx, wpy, wpz)
        setRotation(plantRoot, 0, math.random() * 2 * math.pi, 0)
        local s = 0.8 + math.random() * 0.4
        setScale(plantRoot, s, s, s)
        setVisibility(plantRoot, false)
        -- [SPS 1.0.0.10.3] lx/lz are the plant's position ON the attach node and are
        -- what updateVisibility re-projects through the LIVE node every refresh.
        -- wx/wy/wz are kept only as the load-time fallback for the pre-1.0.0.10.3
        -- path (and so an instance restored without lx/lz still renders).
        return { rootNode = plantRoot, lx = lx, lz = lz, wx = wpx, wy = wpy, wz = wpz }
    end

    for stage = 1, 3 do
        local pool = byStage[stage]
        if #pool > 0 then
            for _ = 1, poolSize do
                local wx, wz = pickPosition()
                if wx ~= nil then
                    local plant = pool[math.random(1, #pool)]
                    local inst  = placeInstance(wx, wz, plant)
                    if inst ~= nil then
                        table.insert(allPlaced, { wx, wz })
                        table.insert(sourceEntry.crustInstances[stage], inst)
                    end
                end
            end
        end
    end

    -- All clones made; release the loaded i3d roots (clones are independent)
    for _, c in pairs(loaded) do
        if c.i3dRoot ~= nil and c.i3dRoot ~= 0 then
            delete(c.i3dRoot)
        end
    end

    local total = #sourceEntry.crustInstances[1] + #sourceEntry.crustInstances[2] + #sourceEntry.crustInstances[3]
    SlurryDebug.log("[SPS CrustVeg] placed " .. total .. " instances on "
        .. tostring(pEntry.placeable.configFileName)
        .. (sourceEntry.storeId ~= nil and (" store " .. tostring(sourceEntry.storeId)) or ""))

    SPSCrustVegetation.updateVisibility(pEntry, sourceEntry)
end

-- ---------------------------------------------------------------------------
-- updateVisibility
-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.31] Operates on ONE store. Called with an explicit sourceEntry by the
-- multi-store paths; called without one it falls back to the placeable's primary
-- source, which is the single-plane behaviour. Instances live on the store entry.
function SPSCrustVegetation.updateVisibility(pEntry, sourceEntry)
    sourceEntry = sourceEntry or pEntry.sourceEntry
    if sourceEntry == nil or sourceEntry.crustInstances == nil then return end
    -- Crust is a mandatory realism feature: when the master is off, hide all of it
    -- (kept in memory, not deleted, so it returns instantly when re-enabled).
    local masterOn = g_slurryPipeManager == nil or g_slurryPipeManager:isFeatureEnabled()
    -- [SPS 1.0.0.9.14] Foliage keys on the store's CRUST value, not thickness.
    -- It previously read getApparentThickness (the DM gauge), so ordinary
    -- slurry sitting mid-gauge grew stage-1 plants on a store whose crust read
    -- 0% (field report). Design rule restored: plants appear at crust >= 40%,
    -- fuller stages at 60% / 80% — the same value the HUD shows as crust.
    local t = 0
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.getSourceCrust ~= nil then
        t = g_slurryPipeManager:getSourceCrust(sourceEntry) or 0
    end
    -- [SPS 1.0.0.10.3] Height is now re-projected through the LIVE attach node every
    -- refresh instead of being added to a world Y frozen at registration.
    --
    -- The bug this fixes: clones are world-parented (1.0.0.9.15), so the only height
    -- they ever received was inst.wy (captured once, at whatever the surface height
    -- happened to be when the placeable registered) plus settle * crustMaxRise --
    -- 0.16 m at most on baseTank. The slurry surface itself travels the full
    -- minY..maxY of the fill plane, 0.763 m on that same tank. The crust MESH tracked
    -- it correctly because it is genuinely parented to the fill plane, but the plants
    -- could not: a pit near full simply swallowed them, while a part-full pit left
    -- them showing. Two identical tanks at different levels therefore looked like one
    -- had foliage and one had none.
    --
    -- The attach node is inside the fill-plane subtree, so re-projecting each plant's
    -- stored local XZ through it picks up the surface height for free, on server and
    -- client alike, with no extra state to sync.
    local attachNode = sourceEntry.crustAttachNode
    if attachNode ~= nil and (attachNode == 0 or not entityExists(attachNode)) then
        attachNode = nil
    end
    -- Only added when the attach node does NOT already inherit it through the crust
    -- plane; adding it in that case would double-count the rise.
    local rise = (sourceEntry.settle or 0) * (sourceEntry.crustMaxRise or 0)
    if sourceEntry.crustFoliageInheritsRise then rise = 0 end

    for stage = 1, 3 do
        local visible = masterOn and (t >= SPSCrustVegetation.THRESH[stage])
        for _, inst in ipairs(sourceEntry.crustInstances[stage]) do
            if inst.rootNode ~= nil and inst.rootNode ~= 0 and entityExists(inst.rootNode) then
                setVisibility(inst.rootNode, visible)
                if visible then
                    if attachNode ~= nil and inst.lx ~= nil and inst.lz ~= nil then
                        local wx, wy, wz = localToWorld(attachNode, inst.lx, 0, inst.lz)
                        setWorldTranslation(inst.rootNode, wx, wy + rise, wz)
                    elseif inst.wy ~= nil then
                        -- Fallback: no live attach node (dead handle) or an instance
                        -- with no stored local XZ. Pre-1.0.0.10.3 behaviour.
                        setWorldTranslation(inst.rootNode, inst.wx, inst.wy + rise, inst.wz)
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- deleteForPlaceable
-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.31] Deletes every store's plants, not just the primary's. Sources are
-- resolved through the manager so a multi-store placeable tears down all its lagoons;
-- if the manager is gone (shutdown ordering) it falls back to the primary entry.
function SPSCrustVegetation.deleteForPlaceable(pEntry)
    local sources = nil
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.getStoreSources ~= nil then
        sources = g_slurryPipeManager:getStoreSources(pEntry)
    end
    if sources == nil or #sources == 0 then
        sources = pEntry.sourceEntry ~= nil and { pEntry.sourceEntry } or {}
    end
    local hasAny = false
    for _, se in ipairs(sources) do
        if se.crustInstances ~= nil then hasAny = true break end
    end
    if not hasAny then return end
    -- Clones are world-parented (1.0.0.9.15), so neither sell nor leave-game
    -- deletes them behind our back any more — this is now the one true owner.
    -- The entityExists guard stays as cheap insurance, matching every other
    -- delete path in the mod.
    local deleted, skipped = 0, 0
    for _, se in ipairs(sources) do
        if se.crustInstances ~= nil then
            for stage = 1, 3 do
                for _, inst in ipairs(se.crustInstances[stage]) do
                    if inst.rootNode ~= nil and inst.rootNode ~= 0 and entityExists(inst.rootNode) then
                        delete(inst.rootNode)
                        deleted = deleted + 1
                    else
                        skipped = skipped + 1
                    end
                end
            end
            se.crustInstances = nil
        end
    end
    cvLog("[SPS CrustVeg] deleteForPlaceable: deleted=" .. tostring(deleted)
        .. " skipped(stale)=" .. tostring(skipped)
        .. " on " .. tostring(pEntry.placeable ~= nil and pEntry.placeable.configFileName or "nil"))
    pEntry.crustInstances = nil
end