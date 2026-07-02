-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.4

-- SlurryNodeUtil.lua
-- FS25_SlurryPipeSystem

SlurryNodeUtil = {}

SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME   = "FILL_VOLUME"
SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE = "STORAGE_PLANE"

function SlurryNodeUtil.buildFillVolumeSource(vehicle, fillUnitIndex)
    if vehicle.spec_fillVolume == nil then
        SlurryDebug.log("buildFillVolumeSource: no spec_fillVolume on " .. tostring(vehicle.configFileName))
        return nil
    end

    local spec       = vehicle.spec_fillVolume
    local fillVolume = nil

    local mapping = spec.fillUnitFillVolumeMapping[fillUnitIndex]
    if mapping ~= nil and #mapping.fillVolumes > 0 then
        fillVolume = mapping.fillVolumes[1]
    else
        for _, v in ipairs(spec.volumes) do
            if v.fillUnitIndex == fillUnitIndex then fillVolume = v break end
        end
        if fillVolume == nil and #spec.volumes > 0 then
            fillVolume = spec.volumes[1]
        end
    end

    if fillVolume == nil then
        local volCount = spec.volumes and #spec.volumes or 0
        local mapCount = 0
        if spec.fillUnitFillVolumeMapping then
            for _ in pairs(spec.fillUnitFillVolumeMapping) do mapCount = mapCount + 1 end
        end
        return nil
    end

    if fillVolume.volume == nil then
        SlurryDebug.log("buildFillVolumeSource: fillVolume.volume is nil")
        return nil
    end

    return {
        type          = SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME,
        vehicle       = vehicle,
        fillVolume    = fillVolume,
        baseNode      = fillVolume.baseNode,
        volumeNode    = fillVolume.volume,
        heightOffset  = fillVolume.heightOffset,
        fillUnitIndex = fillUnitIndex,
        -- Store a short label for debug output
        debugLabel    = tostring(vehicle.configFileName):match("([^/]+)%.xml$") or "vehicle",
    }
end

function SlurryNodeUtil.buildStoragePlaneSource(placeable, fillPlaneNode, minY, maxY, fillType, planeBounds)
    if fillPlaneNode == nil or fillPlaneNode == 0 then
        SlurryDebug.log("buildStoragePlaneSource: invalid fillPlaneNode")
        return nil
    end

    -- Try to find the storage object that manages this fill type.
    -- Supports spec_silo (baseTank), spec_husbandry (cow shed etc.), spec_siloExtension, spec_productionPoint (BGA).
    -- If no storage is found, surface detection still works but flow will be inactive.
    local storage = nil

    if placeable.spec_silo ~= nil then
        for _, s in ipairs(placeable.spec_silo.storages) do
            if s:getFillLevel(fillType) ~= nil or s:getFreeCapacity(fillType) ~= nil then
                storage = s
                break
            end
        end
    end

    if storage == nil and placeable.spec_husbandry ~= nil then
        local sh = placeable.spec_husbandry
        -- Try common paths for husbandry storage
        if sh.husbandry ~= nil and sh.husbandry.storage ~= nil
        and type(sh.husbandry.storage.getFillLevel) == "function" then
            storage = sh.husbandry.storage
        elseif sh.storage ~= nil and type(sh.storage.getFillLevel) == "function" then
            storage = sh.storage
        else
            -- Iterate spec_husbandry fields for any storage-like object
            for _, v in pairs(sh) do
                if type(v) == "table" and type(v.getFillLevel) == "function" then
                    storage = v
                    break
                end
            end
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
        SlurryDebug.log("buildStoragePlaneSource: no storage found — surface detection only")
    end

    SlurryDebug.log("SlurryNodeUtil.buildStoragePlaneSource: built STORAGE_PLANE source")
    return {
        type          = SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE,
        placeable     = placeable,
        storage       = storage,
        fillPlaneNode = fillPlaneNode,
        minY          = minY,
        maxY          = maxY,
        fillType      = fillType,
        planeBounds   = planeBounds,
        debugLabel    = tostring(placeable.configFileName):match("([^/]+)%.xml$") or "placeable",
    }
end

function SlurryNodeUtil.getSurfaceWorldY(sourceEntry, worldX, worldZ)
    if sourceEntry == nil then return -math.huge end
    -- [SPS NU] Nil-coordinate guard. A caller can derive worldX/worldZ from a
    -- detection node whose getWorldTranslation returns nil for a frame (node
    -- unlinked / mid-rebuild). The nil then reaches worldToLocal as a coordinate
    -- ("Argument 1 Expected: Float, Actual: Nil") or getFillPlaneHeightAtLocalPos.
    -- Bail cleanly so a single bad-coordinate frame does not spam script errors.
    if worldX == nil or worldZ == nil then return -math.huge end

    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
        local volumeNode = sourceEntry.volumeNode
        local baseNode   = sourceEntry.baseNode
        if volumeNode == nil or volumeNode == 0 then return -math.huge end
        if baseNode == nil or baseNode == 0 then return -math.huge end
        -- [SPS NU] Dead-handle guard. A FillVolume can be rebuilt or its vehicle
        -- reloaded after this source was registered, leaving baseNode/volumeNode as
        -- freed handles: non-nil and non-zero, so the checks above pass, but the
        -- entity no longer exists. worldToLocal / getFillPlaneHeightAtLocalPos then
        -- error with "Argument 1 wrong type: Nil". entityExists catches the dead
        -- handle so we bail cleanly instead of spamming script warnings.
        if not entityExists(baseNode) or not entityExists(volumeNode) then return -math.huge end

        -- Convert world XZ into fill volume local space
        local localX, _, localZ = worldToLocal(baseNode, worldX, 0, worldZ)

        -- Get fill plane height in local space of the volume shape.
        -- This returns the raw local Y of the current slurry surface.
        -- We do NOT subtract heightOffset here -- heightOffset is for
        -- FillVolume's own height-node animation system (height above
        -- empty baseline) not for world space surface detection.
        local rawLocalY = getFillPlaneHeightAtLocalPos(volumeNode, localX, localZ)

        if MathUtil.isNan(rawLocalY) then return -math.huge end

        -- Convert local surface Y back to world Y
        local _, surfaceWorldY, _ = localToWorld(baseNode, localX, rawLocalY, localZ)
        return surfaceWorldY

    elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        local fillPlaneNode = sourceEntry.fillPlaneNode
        if fillPlaneNode == nil then return -math.huge end
        -- [SPS NU] Dead-handle guard (see FILL_VOLUME note above): a freed plane
        -- node is non-nil but errors in getWorldTranslation. Bail cleanly.
        if fillPlaneNode == 0 or not entityExists(fillPlaneNode) then return -math.huge end
        -- Engine manages the fill plane node Y position directly
        local _, surfaceWorldY, _ = getWorldTranslation(fillPlaneNode)
        return surfaceWorldY
    end

    return -math.huge
end

-- isNodeInTriggerBox: not used in current detection flow.
-- getWorldBoundingBox does not exist in FS25 -- stubbed safely.
function SlurryNodeUtil.isNodeInTriggerBox(testNode, triggerNode)
    return false
end

-- Returns true if testNode's XZ world position is inside the given planeBounds.
-- planeBounds is the struct built in registerPlaceable:
--   round:     { shape="round",     centreNode, radius }
--   rectangle: { shape="rectangle", centreNode, minX, maxX, minZ, maxZ }
-- Returns false if planeBounds is nil (coupling-only placeable with no authored bounds).
function SlurryNodeUtil.isNodeInPlaneBounds(testNode, planeBounds)
    if testNode == nil or planeBounds == nil then return false end
    local wx, wy, wz = getWorldTranslation(testNode)
    if planeBounds.shape == "round" then
        local bx, _, bz = getWorldTranslation(planeBounds.centreNode)
        local dx, dz    = wx - bx, wz - bz
        return (dx * dx + dz * dz) <= (planeBounds.radius * planeBounds.radius)
    elseif planeBounds.shape == "rectangle" then
        local lx, _, lz = worldToLocal(planeBounds.centreNode, wx, wy, wz)
        return lx >= planeBounds.minX and lx <= planeBounds.maxX
            and lz >= planeBounds.minZ and lz <= planeBounds.maxZ
    end
    return false
end

function SlurryNodeUtil.getDistanceBetweenNodes(nodeA, nodeB)
    if nodeA == nil or nodeB == nil then return math.huge end
    local ax, ay, az = getWorldTranslation(nodeA)
    local bx, by, bz = getWorldTranslation(nodeB)
    return MathUtil.vector3Length(ax - bx, ay - by, az - bz)
end

function SlurryNodeUtil.getAngleBetweenNodes(nozzleNode, receiverNode)
    if nozzleNode == nil or receiverNode == nil then return 180 end
    local nx, ny, nz = getWorldTranslation(nozzleNode)
    local rx, ry, rz = getWorldTranslation(receiverNode)
    local dx, dy, dz = rx - nx, ry - ny, rz - nz
    local len = MathUtil.vector3Length(dx, dy, dz)
    if len < 0.0001 then return 0 end
    dx, dy, dz = dx / len, dy / len, dz / len
    local fx, fy, fz = localDirectionToWorld(nozzleNode, 0, 0, -1)
    local dot = math.clamp(dx * fx + dy * fy + dz * fz, -1, 1)
    return math.deg(math.acos(dot))
end

function SlurryNodeUtil.injectTransformNode(parentNode, localX, localY, localZ, name)
    if parentNode == nil then
        SlurryDebug.log("injectTransformNode: parentNode is nil for '" .. tostring(name) .. "'")
        return nil
    end
    local nodeName = name or "sps_node"
    local newNode  = createTransformGroup(nodeName)
    link(parentNode, newNode)
    setTranslation(newNode, localX, localY, localZ)
    SlurryDebug.log("injectTransformNode: created '" .. nodeName .. "' at local " .. localX .. " " .. localY .. " " .. localZ)
    return newNode
end

function SlurryNodeUtil.deleteInjectedNode(nodeId)
    if nodeId ~= nil and nodeId ~= 0 then delete(nodeId) end
end