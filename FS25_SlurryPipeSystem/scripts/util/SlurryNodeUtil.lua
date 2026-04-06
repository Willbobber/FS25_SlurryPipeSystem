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
        print("[SPS] buildFillVolumeSource FAIL: volumes=" .. volCount .. " mappings=" .. mapCount .. " for " .. tostring(vehicle.configFileName))
        return nil
    end

    print("[SPS] buildFillVolumeSource OK: baseNode=" .. tostring(fillVolume.baseNode) .. " volume=" .. tostring(fillVolume.volume))

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
    -- Supports spec_silo (baseTank), spec_husbandry (cow shed etc.), spec_siloExtension.
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

    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
        local volumeNode = sourceEntry.volumeNode
        local baseNode   = sourceEntry.baseNode
        if volumeNode == nil or baseNode == nil then return -math.huge end

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
