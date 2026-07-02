-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4

-- SPSCrustVegetation.lua
-- Manages procedural vegetation on slurry fill planes.
-- Each i3d contains exactly one stage of one plant — no shape hiding needed.
-- Stage is declared per plant in fillPoints.xml.
-- All pools share a global exclusion zone so no two instances overlap.

SPSCrustVegetation = {}

SPSCrustVegetation.THRESH = { [1] = 0.4, [2] = 0.6, [3] = 0.8 }

-- ---------------------------------------------------------------------------
-- readConfig
-- ---------------------------------------------------------------------------
function SPSCrustVegetation.readConfig(xmlFile)
    if not xmlFile:hasProperty("slurryPipeSystem.crust") then return nil end
    local density = xmlFile:getFloat("slurryPipeSystem.crust#density", 0.3)
    local plants  = {}
    local idx = 0
    while true do
        local pKey = string.format("slurryPipeSystem.crust.plant(%d)", idx)
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
    local planeNode = xmlFile:getString("slurryPipeSystem.crust#planeNode", nil)
    -- Dedicated foliage anchor plane (child of the crust mesh). When set, foliage
    -- attaches here only; nothing is placed on the crust mesh or slurry plane.
    local foliageNode = xmlFile:getString("slurryPipeSystem.crust#foliageNode", nil)
    -- Keep foliage this many metres clear of the plane edge (and inside the plane
    -- area). 0.1 = 100 mm. Default 0 = sample right up to the edge.
    local edgeMargin = xmlFile:getFloat("slurryPipeSystem.crust#edgeMargin", 0)

    -- Read maxRise defensively and log exactly what was found, so a value that
    -- silently falls back to the default can be diagnosed from the log.
    local hasMaxRise = xmlFile:hasProperty("slurryPipeSystem.crust#maxRise")
    local rawMaxRise = xmlFile:getString("slurryPipeSystem.crust#maxRise", nil)
    local maxRise    = xmlFile:getFloat("slurryPipeSystem.crust#maxRise", -1)
    if maxRise < 0 then
        -- getFloat failed/defaulted: try parsing the raw string ourselves, accepting
        -- a comma decimal separator (locale), then fall back to 0.1.
        local parsed = nil
        if rawMaxRise ~= nil then
            parsed = tonumber((tostring(rawMaxRise):gsub(",", ".")))
        end
        maxRise = parsed or 0.1
    end
    print("[SPS Crust] readConfig file='" .. tostring(xmlFile.filename)
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
function SPSCrustVegetation.initForPlaceable(pEntry, modDirectory)
    local cfg         = pEntry.crustConfig
    local sourceEntry = pEntry.sourceEntry
    print("[SPS CrustVeg] initForPlaceable: " .. tostring(pEntry.placeable ~= nil and pEntry.placeable.configFileName or "nil")
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
    print("[SPS CrustVeg] foliage attach node = "
        .. tostring(attachNode == sourceEntry.crustFoliageNode and "crustFoliage" or "slurryPlane")
        .. " (" .. tostring(attachNode) .. ")")

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

    pEntry.crustInstances = { [1] = {}, [2] = {}, [3] = {} }

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
        local lx, _, lz = worldToLocal(attachNode, wx, 0, wz)
        link(attachNode, plantRoot)
        setTranslation(plantRoot, lx, 0, lz)
        setRotation(plantRoot, 0, math.random() * 2 * math.pi, 0)
        local s = 0.8 + math.random() * 0.4
        setScale(plantRoot, s, s, s)
        setVisibility(plantRoot, false)
        return { rootNode = plantRoot }
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
                        table.insert(pEntry.crustInstances[stage], inst)
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

    local total = #pEntry.crustInstances[1] + #pEntry.crustInstances[2] + #pEntry.crustInstances[3]
    SlurryDebug.log("[SPS CrustVeg] placed " .. total .. " instances on " .. tostring(pEntry.placeable.configFileName))

    SPSCrustVegetation.updateVisibility(pEntry)
end

-- ---------------------------------------------------------------------------
-- updateVisibility
-- ---------------------------------------------------------------------------
function SPSCrustVegetation.updateVisibility(pEntry)
    if pEntry.crustInstances == nil then return end
    -- Crust is a mandatory realism feature: when the master is off, hide all of it
    -- (kept in memory, not deleted, so it returns instantly when re-enabled).
    local masterOn = g_slurryPipeManager == nil or g_slurryPipeManager:isFeatureEnabled()
    local t = (g_slurryPipeManager ~= nil and pEntry.sourceEntry ~= nil)
        and g_slurryPipeManager:getApparentThickness(pEntry.sourceEntry) or 0
    for stage = 1, 3 do
        local visible = masterOn and (t >= SPSCrustVegetation.THRESH[stage])
        for _, inst in ipairs(pEntry.crustInstances[stage]) do
            setVisibility(inst.rootNode, visible)
        end
    end
end

-- ---------------------------------------------------------------------------
-- deleteForPlaceable
-- ---------------------------------------------------------------------------
function SPSCrustVegetation.deleteForPlaceable(pEntry)
    if pEntry.crustInstances == nil then return end
    -- On leave-game the engine deletes the placeable's i3d subtree (including the
    -- fillPlane / crustFoliage parent these clones are linked to) BEFORE
    -- unregisterPlaceable runs. By the time we get here the clones may already be
    -- freed, so delete() would throw "Unknown entity id". Guard with entityExists,
    -- matching every other delete path in the mod.
    local deleted, skipped = 0, 0
    for stage = 1, 3 do
        for _, inst in ipairs(pEntry.crustInstances[stage]) do
            if inst.rootNode ~= nil and inst.rootNode ~= 0 and entityExists(inst.rootNode) then
                delete(inst.rootNode)
                deleted = deleted + 1
            else
                skipped = skipped + 1
            end
        end
    end
    print("[SPS CrustVeg] deleteForPlaceable: deleted=" .. tostring(deleted)
        .. " skipped(stale)=" .. tostring(skipped)
        .. " on " .. tostring(pEntry.placeable ~= nil and pEntry.placeable.configFileName or "nil"))
    pEntry.crustInstances = nil
end