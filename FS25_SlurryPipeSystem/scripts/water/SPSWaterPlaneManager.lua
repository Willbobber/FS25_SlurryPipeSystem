--[[
================================================================================
  FS25_SlurryPipeSystem — Water Plane Manager
================================================================================
  Manages water plane detection and validation using node-based geometry.
  
  Water planes are defined in map i3d:
    /SPS_waterNodes/
      ├─ waterPlaneLake01/        ← Parent node (Y = water surface)
      │   ├─ waterPlaneLake01_01  ← Edge nodes (perimeter markers)
      │   ├─ waterPlaneLake01_02
      │   └─ ...
      └─ mainWaterPlane/
          └─ ...
  
  System:
  - Load all water planes on map load
  - Auto-order edge nodes by angle around parent (forms perimeter ring)
  - Runtime: triangle validation to check if point is in water
  - Infinite water sources (no depletion)
  
  Author: Oscar Mods
  Version: 1.0.0.0
================================================================================
]]

SPSWaterPlaneManager = {}
local SPSWaterPlaneManager_mt = Class(SPSWaterPlaneManager)

SPSWaterPlaneManager.SOURCE_TYPE_WATER = 3  -- Source type constant for water

function SPSWaterPlaneManager.new(modDir)
    local self = setmetatable({}, SPSWaterPlaneManager_mt)
    self.modDir = modDir or ""         -- Mod directory path (required for loading external water nodes)
    self.waterPlanes = {}              -- Loaded water plane data
    self.waterNodesRoot = nil          -- Root node of water planes (for cleanup)
    self.waterNodesLoadedExternal = false  -- True if loaded from external i3d
    self.planesLoaded = false          -- Flag to prevent multiple load attempts
    SlurryDebug.log("[SPS WPM] SPSWaterPlaneManager created")
    return self
end

function SPSWaterPlaneManager:delete()
    -- Delete externally loaded water nodes i3d
    if self.waterNodesLoadedExternal and self.waterNodesRoot ~= nil then
        if entityExists(self.waterNodesRoot) then
            delete(self.waterNodesRoot)
            SlurryDebug.log("[SPS WPM] Deleted external water nodes i3d")
        end
    end
    
    self.waterPlanes = {}
    self.waterNodesRoot = nil
    self.waterNodesLoadedExternal = false
    SlurryDebug.log("[SPS WPM] SPSWaterPlaneManager deleted")
end

--[[
  Load all water planes from the map's SPS_waterNodes tree.
  Called on mission load after map is fully loaded.
  
  Two loading modes:
  1. Map-embedded: SPS_waterNodes exists in map's own scenegraph (mapper added them)
  2. External i3d: Load from mod's water/[mapName]/SPS_waterNodes.i3d (mod provides pre-made nodes)
]]
function SPSWaterPlaneManager:loadWaterPlanes()
    -- Check if terrain root is available
    if g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        print("[SPS WPM] terrainRootNode not available yet, water system disabled")
        return
    end
    
    print("[SPS WPM] Starting water plane load, terrainRootNode available")
    
    local rootNode = getChild(g_currentMission.terrainRootNode, "SPS_waterNodes")
    local loadedFromExternal = false
    
    -- If not found in map scenegraph, try loading external i3d
    if rootNode == nil or not entityExists(rootNode) then
        print("[SPS WPM] No SPS_waterNodes in map scenegraph, checking for external i3d...")
        rootNode = self:_loadExternalWaterNodes()
        if rootNode ~= nil then
            loadedFromExternal = true
        end
    else
        print("[SPS WPM] Found SPS_waterNodes in map scenegraph")
    end
    
    if rootNode == nil or not entityExists(rootNode) then
        print("[SPS WPM] No water nodes found (map-embedded or external) - water system disabled")
        return
    end
    
    SlurryDebug.log(string.format("[SPS WPM] Loading water planes from %s SPS_waterNodes...",
        loadedFromExternal and "external i3d" or "map scenegraph"))
    
    -- Store the root node for cleanup later
    self.waterNodesRoot = rootNode
    self.waterNodesLoadedExternal = loadedFromExternal
    
    local numPlanes = getNumOfChildren(rootNode)
    local loadedCount = 0
    
    for i = 0, numPlanes - 1 do
        local planeNode = getChildAt(rootNode, i)
        local planeName = getName(planeNode)
        
        -- Load this water plane
        local waterPlane = self:_loadSingleWaterPlane(planeNode, planeName)
        
        if waterPlane ~= nil then
            table.insert(self.waterPlanes, waterPlane)
            loadedCount = loadedCount + 1
        else
            print(string.format("[SPS WPM] WARNING: Failed to load water plane '%s'", planeName))
        end
    end
    
    SlurryDebug.log(string.format("[SPS WPM] Loaded %d water plane(s)", loadedCount))
end

--[[
  Attempt to load water nodes from external i3d file using manifest.
  
  Manifest structure:
    <spsWaterManifest>
        <waterPlane title="Witcombe Park Farm" mapFolder="FS25_Witcombe"/>
    </spsWaterManifest>
  
  Process:
  1. Load water/spsWaterManifest.xml
  2. Match current map by title (exact string match)
  3. Get mapFolder from matched entry
  4. Load: water/{mapFolder}/SPS_waterNodes.i3d
  
  Returns root node or nil if not found.
]]
function SPSWaterPlaneManager:_loadExternalWaterNodes()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    
    local manifestPath = self.modDir .. "water/spsWaterManifest.xml"
    
    -- Load manifest (XMLFile.load will fail if file doesn't exist)
    local xmlFile = XMLFile.load("WaterManifest", manifestPath)
    if xmlFile == nil then
        SlurryDebug.log("[SPS WPM] No water manifest found at: " .. manifestPath)
        return nil
    end
    
    -- Get current map title for matching
    local mapTitle = g_currentMission.missionInfo.mapTitle or ""
    
    if mapTitle == "" then
        print("[SPS WPM] ERROR: Cannot determine map title")
        xmlFile:delete()
        return nil
    end
    
    SlurryDebug.log(string.format("[SPS WPM] Searching manifest for map title: '%s'", mapTitle))
    
    -- Scan manifest entries for title match
    local mapFolder = nil
    local entryIndex = 0
    
    while true do
        local entryKey = string.format("spsWaterManifest.waterPlane(%d)", entryIndex)
        
        if not xmlFile:hasProperty(entryKey) then
            break  -- No more entries
        end
        
        local entryTitle = xmlFile:getString(entryKey .. "#title")
        local entryFolder = xmlFile:getString(entryKey .. "#mapFolder")
        
        -- Exact title match
        if entryTitle == mapTitle and entryFolder ~= nil and entryFolder ~= "" then
            mapFolder = entryFolder
            SlurryDebug.log(string.format("[SPS WPM] Manifest match: title='%s' -> mapFolder='%s'",
                entryTitle, mapFolder))
            break
        end
        
        entryIndex = entryIndex + 1
    end
    
    xmlFile:delete()
    
    if mapFolder == nil then
        SlurryDebug.log(string.format("[SPS WPM] No manifest entry found for map '%s' (checked %d entries)",
            mapTitle, entryIndex))
        return nil
    end
    
    -- Construct path: water/{mapFolder}/SPS_waterNodes.i3d
    local i3dPath = self.modDir .. "water/" .. mapFolder .. "/SPS_waterNodes.i3d"
    
    SlurryDebug.log(string.format("[SPS WPM] Loading water nodes from: %s", i3dPath))
    
    -- Load the i3d file (loadI3DFile will return nil if file doesn't exist)
    local rootNode = loadI3DFile(i3dPath, false, false, false)
    
    if rootNode == nil or rootNode == 0 then
        print(string.format("[SPS WPM] ERROR: Failed to load i3d file: %s", i3dPath))
        return nil
    end
    
    -- Link to terrain root so nodes are in correct coordinate space
    link(g_currentMission.terrainRootNode, rootNode)
    
    -- The loaded i3d root should be named "SPS_waterNodes" or have it as first child
    local actualRoot = rootNode
    if getName(rootNode) ~= "SPS_waterNodes" then
        -- Check if first child is SPS_waterNodes
        if getNumOfChildren(rootNode) > 0 then
            local firstChild = getChildAt(rootNode, 0)
            if getName(firstChild) == "SPS_waterNodes" then
                actualRoot = firstChild
            end
        end
    end
    
    SlurryDebug.log(string.format("[SPS WPM] Successfully loaded water nodes for '%s' (root: %s)",
        mapFolder, getName(actualRoot)))
    
    return actualRoot
end

--[[
  Load a single water plane from a node.
  Parent node = water surface reference (Y)
  Children = edge nodes forming perimeter ring
]]
function SPSWaterPlaneManager:_loadSingleWaterPlane(planeNode, planeName)
    if not entityExists(planeNode) then
        return nil
    end
    
    -- Get parent world position (water surface level)
    local centreX, centreY, centreZ = getWorldTranslation(planeNode)
    
    -- Find all quad groups (children matching pattern waterPlaneLake_01, etc.)
    local quadGroups = {}
    
    I3DUtil.iterateRecursively(planeNode, function(node)
        local nodeName = getName(node)
        -- Match quad pattern: name ends with underscore + digits
        if nodeName:match("_(%d+)$") then
            table.insert(quadGroups, {node = node, name = nodeName})
        end
        return true  -- Continue iteration
    end)
    
    if #quadGroups == 0 then
        print(string.format("[SPS WPM] WARNING: Water plane '%s' has no quad groups", planeName))
        return nil
    end
    
    -- Load each quad's 4 corner nodes
    local quads = {}
    for _, quadGroup in ipairs(quadGroups) do
        local quad = self:_loadQuadVertices(quadGroup.node, quadGroup.name)
        if quad ~= nil then
            table.insert(quads, quad)
        end
    end
    
    if #quads == 0 then
        print(string.format("[SPS WPM] WARNING: Water plane '%s' loaded no valid quads", planeName))
        return nil
    end
    
    -- Store water plane data
    local waterPlane = {
        node = planeNode,
        name = planeName,
        waterY = centreY,      -- Water surface height = parent node Y
        quads = quads
    }
    
    SlurryDebug.log(string.format("[SPS WPM] Loaded water plane '%s' with %d quad(s) at Y=%.2f",
        planeName, #quads, centreY))
    
    return waterPlane
end

--[[
  Load a single quad's 4 corner nodes as flat vertex array.
  Returns {name, vertices} or nil if invalid.
]]
function SPSWaterPlaneManager:_loadQuadVertices(quadNode, quadName)
    if not entityExists(quadNode) then
        return nil
    end
    
    -- Find the 4 corner nodes: node1, node2, node3, node4
    local corners = {}
    for i = 1, 4 do
        local nodeName = "node" .. i
        local cornerNode = getChild(quadNode, nodeName)
        if cornerNode == nil or not entityExists(cornerNode) then
            print(string.format("[SPS WPM] WARNING: Quad '%s' missing '%s'", quadName, nodeName))
            return nil
        end
        
        local x, y, z = getWorldTranslation(cornerNode)
        corners[i] = {x = x, z = z}
    end
    
    -- Store as flat array: [x1, z1, x2, z2, x3, z3, x4, z4]
    local vertices = {
        corners[1].x, corners[1].z,
        corners[2].x, corners[2].z,
        corners[3].x, corners[3].z,
        corners[4].x, corners[4].z
    }
    
    return {
        name = quadName,
        vertices = vertices
    }
end

--[[
  Find which water plane (if any) contains the given XZ position.
  Returns waterPlane or nil.
]]
function SPSWaterPlaneManager:findWaterPlaneAtPosition(x, z)
    for _, waterPlane in ipairs(self.waterPlanes) do
        if self:_isPointInWaterPlane(x, z, waterPlane) then
            return waterPlane
        end
    end
    
    return nil
end

--[[
  Check if a 3D point is submerged in water.
  Returns true if:
    - XZ is inside water plane perimeter ring
    - Y is below water surface
]]
function SPSWaterPlaneManager:isPointSubmerged(x, y, z)
    local waterPlane = self:findWaterPlaneAtPosition(x, z)
    
    if waterPlane == nil then
        return false
    end
    
    -- Check if point Y is below water surface
    return y < waterPlane.waterY
end

--[[
  Check if XZ position is inside any quad of the water plane.
  Uses Giants' approach from Polygon2D.lua: ray casting with MathUtil.getLineSegmentsIntersection().
  
  Algorithm:
  - For each quad, cast horizontal ray from point to the right
  - Count intersections using MathUtil.getLineSegmentsIntersection()
  - Odd crossings = inside quad
]]
function SPSWaterPlaneManager:_isPointInWaterPlane(px, pz, waterPlane)
    -- Test against all quads (OR logic - inside any quad = inside water plane)
    for _, quad in ipairs(waterPlane.quads) do
        if self:_isPointInQuad(px, pz, quad.vertices) then
            return true
        end
    end
    
    return false
end

--[[
  Test if point is inside a 4-vertex quad using ray casting.
  Vertices stored as flat array: [x1, z1, x2, z2, x3, z3, x4, z4]
  Uses Giants' MathUtil.getLineSegmentsIntersection() like vanilla FS25.
]]
function SPSWaterPlaneManager:_isPointInQuad(px, pz, vertices)
    -- Quick bounding box check (cheap pre-filter)
    local minX, maxX = math.huge, -math.huge
    local minZ, maxZ = math.huge, -math.huge
    
    for i = 1, #vertices, 2 do
        minX = math.min(minX, vertices[i])
        maxX = math.max(maxX, vertices[i])
        minZ = math.min(minZ, vertices[i + 1])
        maxZ = math.max(maxZ, vertices[i + 1])
    end
    
    if px < minX or px > maxX or pz < minZ or pz > maxZ then
        return false
    end
    
    -- Ray casting: count intersections from (px, pz) to far right
    local intersectCount = 0
    local rayEndX = 100000  -- Far right point (Giants uses this value)
    
    for i = 1, #vertices, 2 do
        local edgeStartX = vertices[i]
        local edgeStartZ = vertices[i + 1]
        local edgeEndX = vertices[i + 2] or vertices[1]  -- Wrap to first vertex
        local edgeEndZ = vertices[i + 3] or vertices[2]
        
        -- Use Giants' line segment intersection (same as Polygon2D.lua)
        local hasIntersection, _ix, _iz = MathUtil.getLineSegmentsIntersection(
            px, pz,              -- Ray start
            rayEndX, pz,         -- Ray end (horizontal to right)
            edgeStartX, edgeStartZ,  -- Edge start
            edgeEndX, edgeEndZ       -- Edge end
        )
        
        if hasIntersection then
            intersectCount = intersectCount + 1
        end
    end
    
    -- Odd number of crossings = inside polygon
    return intersectCount % 2 ~= 0
end

--[[
  Create an infinite water source entry for flow operations.
  Water sources don't deplete - always return max fill level.
]]
function SPSWaterPlaneManager:createWaterSource(waterPlane)
    -- Create mock storage object with infinite capacity
    local infiniteStorage = {
        getFillLevel = function(self, fillType)
            if fillType == FillType.WATER then
                return 999999999  -- Infinite
            end
            return 0
        end,
        
        getFreeCapacity = function(self, fillType)
            if fillType == FillType.WATER then
                return 999999999  -- Infinite
            end
            return 0
        end,
        
        addFillLevel = function(self, farmId, deltaFillLevel, fillType, toolType, fillPositionData)
            -- Water sources don't deplete
            return deltaFillLevel
        end,
        
        getCapacity = function(self, fillType)
            if fillType == FillType.WATER then
                return 999999999
            end
            return 0
        end
    }
    
    local sourceEntry = {
        type          = SPSWaterPlaneManager.SOURCE_TYPE_WATER,
        storage       = infiniteStorage,
        fillPlaneNode = nil,
        minY          = waterPlane.waterY,
        maxY          = waterPlane.waterY,
        fillType      = FillType.WATER,
        planeBounds   = nil,
        isInfiniteSource = true,
        waterY        = waterPlane.waterY,
        waterPlane    = waterPlane,
        debugLabel    = string.format("water_%s", waterPlane.name)
    }
    
    return sourceEntry
end


SlurryDebug.log("[SPS WPM] SPSWaterPlaneManager.lua loaded")