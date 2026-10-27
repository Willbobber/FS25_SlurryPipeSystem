--[[
================================================================================
  FS25_SlurryPipeSystem — Water Plane Manager
================================================================================
  Manages water plane detection and validation using node-based geometry.
  
  Water planes are defined in map i3d:
    /SPS_waterNodes/
      ├─ waterPlaneLake01/        ← Parent node (Y = water surface)
      │   ├─ waterPlaneLake01_01  ← Quad group: node1..node4 corners
      │   ├─ waterPlaneLake01_02
      │   ├─ shoreline            ← OR a closed spline traced round the water (1.0.1.8)
      │   └─ ...
      └─ mainWaterPlane/
          └─ ...

  System:
  - Load all water planes on map load
  - Quads: four corner nodes; spline loops: sampled ~1 vertex/m into one polygon
  - Runtime: XZ bounds pre-filter, then ray-cast point-in-polygon (any polygon = in water)
  - Infinite water sources (no depletion)

  Author: Oscar Mods
  -- Version: 1.0.0.8
================================================================================
]]

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSWaterPlaneManager 1.0.1.8 loaded (quads + spline loops)") end

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
    
    spsInfo("[SPS WPM] Starting water plane load, terrainRootNode available")
    
    local rootNode = getChild(g_currentMission.terrainRootNode, "SPS_waterNodes")
    local loadedFromExternal = false
    
    -- If not found in map scenegraph, try loading external i3d
    if rootNode == nil or not entityExists(rootNode) then
        -- [SPS 1.0.0.9.25] The direct terrain-root getChild was the only map-embedded
        -- lookup, but GE does not allow authoring children under the terrain node, so
        -- the "map-embedded" path documented in the README was impossible to use.
        -- Two new sources, tried in order before the SPS-bundled manifest:
        --   1. Deep search of the map's own scenegraph — g_currentMission.maps holds
        --      every map i3d root node (BaseMission.lua:65/:346, linked to getRootNode()
        --      at :347). The mapper may parent SPS_waterNodes anywhere in their map.
        --   2. Map-shipped external i3d — SPS_waterNodes.i3d in the map mod's own
        --      folder root (g_currentMission.loadedMapBaseDirectory, set at
        --      BaseMission.lua:297 and never cleared). No SPS edit, no manifest.
        rootNode = self:_findWaterNodesInMapScenegraph()
        if rootNode ~= nil then
            if spsInfo ~= nil then spsInfo("[SPS WPM] Found SPS_waterNodes in map scenegraph (deep search)") end
        end
        if rootNode == nil then
            rootNode = self:_loadMapFolderWaterNodes()
            if rootNode ~= nil then
                loadedFromExternal = true
            end
        end
        if rootNode == nil then
            if spsInfo ~= nil then spsInfo("[SPS WPM] No SPS_waterNodes in map scenegraph, checking for external i3d...") end
            rootNode = self:_loadExternalWaterNodes()
            if rootNode ~= nil then
                loadedFromExternal = true
            end
        end
    else
        if spsInfo ~= nil then spsInfo("[SPS WPM] Found SPS_waterNodes in map scenegraph") end
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
        <!-- optional per entry: titles="Name A;Name B"  titleContains="witcombe"
             (case-insensitive; mapFolder is a folder INSIDE this mod's water/
             directory — player renames of the map's mod folder never matter) -->
    </spsWaterManifest>
  
  Process:
  1. Load water/spsWaterManifest.xml
  2. Match current map by title (exact string match)
  3. Get mapFolder from matched entry
  4. Load: water/{mapFolder}/SPS_waterNodes.i3d
  
  Returns root node or nil if not found.
]]

--[[
  [SPS 1.0.0.9.25] Deep search the map's own scenegraph for a node named
  "SPS_waterNodes". Source: BaseMission.lua:65 (self.maps = {}), :346
  (table.insert(self.maps, node) in loadMapFinished) — g_currentMission.maps
  holds the root node of every loaded map i3d. Walking only these roots scopes
  the search to the map tree, so the mapper may parent SPS_waterNodes anywhere
  in their map (e.g. under a "water" or "misc" group). Runs once at mission
  load. Returns the found node or nil. Nodes belong to the map — never deleted
  by SPS (waterNodesLoadedExternal stays false for this source).
]]
function SPSWaterPlaneManager:_findWaterNodesInMapScenegraph()
    if g_currentMission == nil or g_currentMission.maps == nil then
        return nil
    end

    local function search(node)
        if node == nil or node == 0 or not entityExists(node) then return nil end
        if getName(node) == "SPS_waterNodes" then return node end
        for i = 0, getNumOfChildren(node) - 1 do
            local found = search(getChildAt(node, i))
            if found ~= nil then return found end
        end
        return nil
    end

    for _, mapNode in pairs(g_currentMission.maps) do
        local found = search(mapNode)
        if found ~= nil then
            return found
        end
    end

    return nil
end

--[[
  [SPS 1.0.0.9.25] Map-shipped external i3d: the mapper drops a file named
  SPS_waterNodes.i3d in the ROOT of their own map mod folder. Source for the
  path: BaseMission.lua:293 (Utils.getModNameAndBaseDirectory(filename)) and
  :297 (self.loadedMapBaseDirectory = baseDirectory, set once at map load and
  never cleared). Loaded tree is linked under terrainRootNode exactly like the
  SPS-bundled manifest path so both external sources share one coordinate-space
  and cleanup model (waterNodesLoadedExternal -> delete on teardown).
  Returns the SPS_waterNodes root or nil if the map ships no such file.
]]
function SPSWaterPlaneManager:_loadMapFolderWaterNodes()
    if g_currentMission == nil then
        return nil
    end
    local mapDir = g_currentMission.loadedMapBaseDirectory
    if mapDir == nil or mapDir == "" then
        return nil
    end

    local i3dPath = mapDir .. "SPS_waterNodes.i3d"

    -- [SPS 1.0.0.9.26] fileExists guard (vanilla usage: FSBaseMission.lua:1968)
    -- — probing loadI3DFile on a missing path makes the ENGINE print
    -- "Error: i3d ... could not be found" in every log on every map that
    -- ships no such file. Check existence first; silent skip when absent.
    if not fileExists(i3dPath) then
        return nil
    end

    -- loadI3DFile returns nil/0 if the file doesn't exist — same probe pattern
    -- as the manifest loader below.
    local rootNode = loadI3DFile(i3dPath, false, false, false)
    if rootNode == nil or rootNode == 0 then
        return nil
    end

    -- Link to terrain root so nodes are in correct coordinate space
    link(g_currentMission.terrainRootNode, rootNode)

    -- The loaded i3d root should be named "SPS_waterNodes" or have it as first child
    local actualRoot = rootNode
    if getName(rootNode) ~= "SPS_waterNodes" then
        if getNumOfChildren(rootNode) > 0 then
            local firstChild = getChildAt(rootNode, 0)
            if getName(firstChild) == "SPS_waterNodes" then
                actualRoot = firstChild
            end
        end
    end

    SlurryDebug.log(string.format("[SPS WPM] Loaded map-shipped water nodes from: %s (root: %s)",
        i3dPath, getName(actualRoot)))

    return actualRoot
end

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
        
        local entryTitle    = xmlFile:getString(entryKey .. "#title")
        local entryTitles   = xmlFile:getString(entryKey .. "#titles")        -- optional ;-list
        local entryContains = xmlFile:getString(entryKey .. "#titleContains") -- optional substring
        local entryFolder   = xmlFile:getString(entryKey .. "#mapFolder")

        -- [SPS 1.0.0.9.12] Tolerant matching. The mod FOLDER name was never part
        -- of this key (title-based, so player renames are already safe; mapFolder
        -- points inside SPS's own water/ dir), but exact title equality was
        -- brittle against localized titles and map-update title edits. Matching
        -- is now case-insensitive + trimmed, an entry may list alternatives
        -- (titles="A;B;C"), and titleContains="witcombe" opts into substring
        -- matching for authors who want it. First matching entry wins.
        local function norm(t)
            if t == nil then return nil end
            return t:lower():gsub("^%s+", ""):gsub("%s+$", "")
        end
        local wantedLower = norm(mapTitle)
        local matched = false
        if norm(entryTitle) == wantedLower then
            matched = true
        end
        if not matched and entryTitles ~= nil then
            for alt in string.gmatch(entryTitles, "[^;]+") do
                if norm(alt) == wantedLower then
                    matched = true
                    break
                end
            end
        end
        if not matched and entryContains ~= nil and entryContains ~= "" then
            if wantedLower ~= nil and wantedLower:find(norm(entryContains), 1, true) ~= nil then
                matched = true
            end
        end
        if matched and entryFolder ~= nil and entryFolder ~= "" then
            mapFolder = entryFolder
            SlurryDebug.log(string.format("[SPS WPM] Manifest match: map title '%s' -> mapFolder='%s'",
                tostring(mapTitle), mapFolder))
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
    
    -- Find all footprints under the plane node. Two authoring routes, mixable:
    --   * spline loop  — any spline shape (class test, name is free); a closed spline traced
    --                    round the shoreline is sampled into one polygon at load
    --   * quad group   — transform group whose name ends with underscore + digits, holding
    --                    node1..node4 (the original route)
    -- The spline test runs first so a spline named e.g. "lake_01" is not mistaken for a quad.
    local quadGroups  = {}
    local splineNodes = {}

    I3DUtil.iterateRecursively(planeNode, function(node)
        local nodeName = getName(node)
        if self:_getIsSplineNode(node) then
            table.insert(splineNodes, {node = node, name = nodeName})
        elseif nodeName:match("_(%d+)$") then
            -- Match quad pattern: name ends with underscore + digits
            table.insert(quadGroups, {node = node, name = nodeName})
        end
        return true  -- Continue iteration
    end)

    if #quadGroups == 0 and #splineNodes == 0 then
        print(string.format("[SPS WPM] WARNING: Water plane '%s' has no quad groups or spline loops", planeName))
        return nil
    end

    -- Load each quad's 4 corner nodes, then each spline loop. Both produce the same
    -- {name, vertices, bounds} polygon entry, so the runtime test does not care which it was.
    local quads = {}
    for _, quadGroup in ipairs(quadGroups) do
        local quad = self:_loadQuadVertices(quadGroup.node, quadGroup.name)
        if quad ~= nil then
            table.insert(quads, quad)
        end
    end
    local numQuads = #quads
    for _, splineEntry in ipairs(splineNodes) do
        local loop = self:_loadSplineLoop(splineEntry.node, splineEntry.name)
        if loop ~= nil then
            table.insert(quads, loop)
        end
    end
    local numLoops = #quads - numQuads

    if #quads == 0 then
        print(string.format("[SPS WPM] WARNING: Water plane '%s' loaded no valid quads or spline loops", planeName))
        return nil
    end

    -- Store water plane data
    local waterPlane = {
        node = planeNode,
        name = planeName,
        waterY = centreY,      -- Water surface height = parent node Y
        quads = quads          -- polygons: quads and sampled spline loops alike
    }

    SlurryDebug.log(string.format("[SPS WPM] Loaded water plane '%s' with %d quad(s) and %d spline loop(s) at Y=%.2f",
        planeName, numQuads, numLoops, centreY))

    return waterPlane
end

--[[
  True when the node is a spline shape. Mirrors the guard vanilla uses before every
  getSpline* call (PlaceableTrainSystem.lua:110, ShipSystem.lua:55):
  a SHAPE whose geometry carries ClassIds.SPLINE. (I3DUtil.getIsSpline is not used —
  the shipped version drops its return value and always answers false.)
]]
function SPSWaterPlaneManager:_getIsSplineNode(node)
    if node == nil or node == 0 or not entityExists(node) then
        return false
    end
    if not getHasClassId(node, ClassIds.SHAPE) then
        return false
    end
    local geometry = getGeometry(node)
    return geometry ~= 0 and getHasClassId(geometry, ClassIds.SPLINE)
end

--[[
  Axis-aligned XZ bounds of a flat vertex array, precomputed once at load so the
  runtime test can reject a far-away point without walking the polygon.
]]
function SPSWaterPlaneManager:_computeBounds(vertices)
    local minX, maxX = math.huge, -math.huge
    local minZ, maxZ = math.huge, -math.huge
    for i = 1, #vertices, 2 do
        minX = math.min(minX, vertices[i])
        maxX = math.max(maxX, vertices[i])
        minZ = math.min(minZ, vertices[i + 1])
        maxZ = math.max(maxZ, vertices[i + 1])
    end
    return {minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ}
end

-- Spline sampling: one vertex per SPLINE_SAMPLE_STEP metres of spline, clamped to
-- [SPLINE_MIN_SAMPLES, SPLINE_MAX_SAMPLES] vertices per loop.
SPSWaterPlaneManager.SPLINE_SAMPLE_STEP = 1.0
SPSWaterPlaneManager.SPLINE_MIN_SAMPLES = 8
SPSWaterPlaneManager.SPLINE_MAX_SAMPLES = 512
SPSWaterPlaneManager.SPLINE_MIN_LENGTH  = 3.0

--[[
  Sample a spline into a closed XZ polygon. The spline should be closed (a loop round the
  shoreline); an open spline is accepted with a warning and its two ends are joined by a
  straight edge. Only the XZ of each sample is used — the surface height comes from the
  plane node, exactly as for quads.

  Engine facts (02_FS25_GAME_REFERENCE): getSplineLength returns metres, getSplinePosition
  takes a normalised time 0..1 (data/maps/proceduralPlacements/paintTerrainBySplines.lua:40-47),
  getIsSplineClosed reports closure (SplineUtil.lua:54).
  Returns {name, vertices, bounds, isSpline} or nil if unusable.
]]
function SPSWaterPlaneManager:_loadSplineLoop(splineNode, splineName)
    local length = getSplineLength(splineNode)
    if length == nil or length < SPSWaterPlaneManager.SPLINE_MIN_LENGTH then
        print(string.format("[SPS WPM] WARNING: Spline '%s' is too short (%.2f m) - skipped",
            splineName, length or 0))
        return nil
    end

    if not getIsSplineClosed(splineNode) then
        print(string.format("[SPS WPM] WARNING: Spline '%s' is not closed - its ends are joined by a straight line. Close the spline in the editor to trace the shoreline exactly.",
            splineName))
    end

    local numSamples = math.floor(length / SPSWaterPlaneManager.SPLINE_SAMPLE_STEP)
    numSamples = math.max(SPSWaterPlaneManager.SPLINE_MIN_SAMPLES,
                 math.min(SPSWaterPlaneManager.SPLINE_MAX_SAMPLES, numSamples))

    -- Sample t in [0, 1) — t = 1 coincides with t = 0 on a closed spline and would only add
    -- a zero-length edge; on an open spline the final edge back to t = 0 is the implicit join.
    local vertices = {}
    for i = 0, numSamples - 1 do
        local t = i / numSamples
        local x, _, z = getSplinePosition(splineNode, t)
        vertices[#vertices + 1] = x
        vertices[#vertices + 1] = z
    end

    SlurryDebug.log(string.format("[SPS WPM] Spline loop '%s': %.1f m sampled into %d vertices",
        splineName, length, numSamples))

    return {
        name = splineName,
        vertices = vertices,
        bounds = self:_computeBounds(vertices),
        isSpline = true
    }
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
        vertices = vertices,
        bounds = self:_computeBounds(vertices)
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
    -- Test against all polygons (OR logic - inside any quad / spline loop = inside water plane)
    for _, quad in ipairs(waterPlane.quads) do
        local b = quad.bounds
        -- Precomputed bounds reject a far point before the polygon walk — matters for a
        -- spline loop with hundreds of vertices, free for a quad.
        if b == nil or (px >= b.minX and px <= b.maxX and pz >= b.minZ and pz <= b.maxZ) then
            if self:_isPointInQuad(px, pz, quad.vertices) then
                return true
            end
        end
    end

    return false
end

--[[
  Test if point is inside a polygon using ray casting.
  Vertices stored as flat array: [x1, z1, x2, z2, ..., xn, zn] — 4 for a quad, up to
  SPLINE_MAX_SAMPLES for a spline loop; the edge loop wraps to the first vertex.
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