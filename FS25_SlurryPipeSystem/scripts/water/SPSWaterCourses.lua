--[[
  SPSWaterCourses.lua  -  [SPS 1.0.1.8] player-drawn water courses

  A "water course" is a ring of XZ points the player drew round a lake / river in the
  building screen (Landscaping > SPS Water > Draw water course) plus the water surface
  height taken from the first click on the water. It is stored per MAP on this PC
  (modSettings/FS25_SlurryPipeSystem/waterCourses/<mapId>.xml), never in the savegame, so a
  new career on the same map sees the same courses. At load every course becomes one more
  polygon water plane in g_waterPlaneManager.waterPlanes - the fill arm, flow and the
  infinite water source need no change (SPSWaterPlaneManager runs on polygons already).

  Design: 05_PROJECT_DOCS/SPS_WATER_COURSE_DESIGN.md. Debug channel "SPSWaterCourses".

  Multiplayer (step 4, 2026-10-20): the SERVER (listen host / dedicated) owns the list and the
  file. A joined client never reads its own file; it gets the server's courses through
  SPSWaterCourseEvent (join dump pass 14 + live ADD / REMOVE). Brushes and console commands on
  any peer go through requestAdd / requestRemove: on the server they apply + broadcast, on a
  client they ask the server (landscaping permission checked there) and wait for the broadcast.
]]

SPSWaterCourses = {}
SPSWaterCourses.VERSION      = 1
SPSWaterCourses.MIN_POINTS   = 3
SPSWaterCourses.MAX_POINTS   = 256
SPSWaterCourses.MIN_EDGE     = 0.5     -- m between two markers
SPSWaterCourses.MIN_AREA     = 10.0    -- m2
SPSWaterCourses.CLOSE_RADIUS = 1.5     -- m: clicking this close to the first marker closes the ring
SPSWaterCourses.courses      = {}      -- id -> course { id, name, waterY, points = {x1,z1,x2,z2,...}, plane }
SPSWaterCourses.order        = {}      -- ids in file order
SPSWaterCourses.nextId       = 1
SPSWaterCourses.loadedMapId  = nil

local function wcLog(fmt, ...)
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSWaterCourses") then
        print("[SPS WC] " .. string.format(fmt, ...))
    end
end
SPSWaterCourses.log = wcLog

-- ---------------------------------------------------------------------------
--  brush registration (sources the brush files into this mod's environment)
-- ---------------------------------------------------------------------------
if g_constructionBrushTypeManager ~= nil and g_constructionBrushTypeManager.addBrushType ~= nil then
    local dir = g_currentModDirectory
    g_constructionBrushTypeManager:addBrushType("spsWaterDraw",   "ConstructionBrushSPSWaterDraw",   dir .. "scripts/water/ConstructionBrushSPSWaterDraw.lua")
    g_constructionBrushTypeManager:addBrushType("spsWaterRemove", "ConstructionBrushSPSWaterRemove", dir .. "scripts/water/ConstructionBrushSPSWaterRemove.lua")
end

-- ---------------------------------------------------------------------------
--  file location
-- ---------------------------------------------------------------------------
function SPSWaterCourses.getDir()
    if getUserProfileAppPath == nil then return nil end
    return getUserProfileAppPath() .. "modSettings/FS25_SlurryPipeSystem/waterCourses/"
end

function SPSWaterCourses.getMapId()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if info == nil then return nil end
    local id = info.mapId
    if id == nil or id == "" then id = info.mapTitle end
    if id == nil or id == "" then return nil end
    return (tostring(id):gsub("[^%w%._%-]", "_"))
end

function SPSWaterCourses.getFilePath()
    local dir, mapId = SPSWaterCourses.getDir(), SPSWaterCourses.getMapId()
    if dir == nil or mapId == nil then return nil end
    return dir .. mapId .. ".xml"
end

-- ---------------------------------------------------------------------------
--  geometry
-- ---------------------------------------------------------------------------
function SPSWaterCourses.polygonArea(points)
    local n = #points / 2
    if n < 3 then return 0 end
    local a = 0
    for i = 1, n do
        local j = (i % n) + 1
        a = a + points[2 * i - 1] * points[2 * j] - points[2 * j - 1] * points[2 * i]
    end
    return math.abs(a) * 0.5
end

-- true when segment (ax,az)-(bx,bz) crosses any existing edge of the open ring, ignoring the
-- edges that share an endpoint with it (lastIndex = index of the point the segment starts at)
function SPSWaterCourses.segmentCrossesRing(points, ax, az, bx, bz, skipFirstEdge, skipLastEdge)
    local n = #points / 2
    for i = 1, n - 1 do
        if not (skipLastEdge and i == n - 1) and not (skipFirstEdge and i == 1) then
            local hit = MathUtil.getLineSegmentsIntersection(ax, az, bx, bz,
                points[2 * i - 1], points[2 * i], points[2 * i + 1], points[2 * i + 2])
            if hit then return true end
        end
    end
    return false
end

-- full check of a ring that is about to be closed: returns ok, l10n reason key
function SPSWaterCourses.validateRing(points)
    local n = #points / 2
    if n < SPSWaterCourses.MIN_POINTS then return false, "sps_waterCourse_tooFewPoints" end
    if n > SPSWaterCourses.MAX_POINTS then return false, "sps_waterCourse_tooManyPoints" end
    for i = 1, n do
        local j = (i % n) + 1
        local dx, dz = points[2 * j - 1] - points[2 * i - 1], points[2 * j] - points[2 * i]
        if math.sqrt(dx * dx + dz * dz) < SPSWaterCourses.MIN_EDGE then return false, "sps_waterCourse_edgeTooShort" end
    end
    if SPSWaterCourses.polygonArea(points) < SPSWaterCourses.MIN_AREA then return false, "sps_waterCourse_tooSmall" end
    -- closing edge against the ring body (open-ring edges 1..n-1; skip the two that touch it)
    if n >= 4 and SPSWaterCourses.segmentCrossesRing(points, points[2 * n - 1], points[2 * n], points[1], points[2], true, true) then
        return false, "sps_waterCourse_crossing"
    end
    return true, nil
end

function SPSWaterCourses.isPointInRing(px, pz, points)
    local n = #points / 2
    if n < 3 then return false end
    local inside = false
    local j = n
    for i = 1, n do
        local xi, zi = points[2 * i - 1], points[2 * i]
        local xj, zj = points[2 * j - 1], points[2 * j]
        if ((zi > pz) ~= (zj > pz)) and (px < (xj - xi) * (pz - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- water surface height at XZ, nil when there is no water there
function SPSWaterCourses.sampleWaterY(x, z)
    local eas = g_currentMission ~= nil and g_currentMission.environmentAreaSystem or nil
    if eas == nil or eas.getWaterYAtWorldPosition == nil then return nil end
    local ty = 0
    if g_terrainNode ~= nil and getTerrainHeightAtWorldPos ~= nil then
        ty = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) or 0
    end
    return eas:getWaterYAtWorldPosition(x, ty, z)
end

-- ---------------------------------------------------------------------------
--  runtime registration into the water plane manager
-- ---------------------------------------------------------------------------
local function computeBounds(points)
    local b = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
    for i = 1, #points, 2 do
        b.minX = math.min(b.minX, points[i]);     b.maxX = math.max(b.maxX, points[i])
        b.minZ = math.min(b.minZ, points[i + 1]); b.maxZ = math.max(b.maxZ, points[i + 1])
    end
    return b
end

function SPSWaterCourses.registerCourse(course)
    if g_waterPlaneManager == nil or g_waterPlaneManager.waterPlanes == nil then return false end
    if course.plane ~= nil then return true end
    local verts = {}
    for i = 1, #course.points do verts[i] = course.points[i] end
    local plane = {
        node   = nil,
        name   = string.format("drawn_%d", course.id),
        waterY = course.waterY,
        quads  = { { name = course.name, vertices = verts, bounds = computeBounds(verts), isDrawn = true, courseId = course.id } },
        isDrawnCourse = true,
        courseId = course.id,
    }
    table.insert(g_waterPlaneManager.waterPlanes, plane)
    course.plane = plane
    wcLog("registered course %d '%s' (%d points, waterY %.2f)", course.id, tostring(course.name), #verts / 2, course.waterY)
    return true
end

function SPSWaterCourses.unregisterCourse(course)
    if course.plane == nil or g_waterPlaneManager == nil then return end
    local list = g_waterPlaneManager.waterPlanes
    for i = #list, 1, -1 do
        if list[i] == course.plane then table.remove(list, i) end
    end
    course.plane = nil
end

-- ---------------------------------------------------------------------------
--  load / save
-- ---------------------------------------------------------------------------
function SPSWaterCourses.reset()
    for _, c in pairs(SPSWaterCourses.courses) do SPSWaterCourses.unregisterCourse(c) end
    SPSWaterCourses.courses = {}
    SPSWaterCourses.order = {}
    SPSWaterCourses.nextId = 1
    SPSWaterCourses.loadedMapId = nil
end

-- true on the listen host and the dedicated server, false on a joined client
function SPSWaterCourses.isAuthority()
    return g_server ~= nil
end

-- Called once the water plane manager has loaded the map's own planes (init.lua).
function SPSWaterCourses.loadForMap()
    SPSWaterCourses.loadedMapId = SPSWaterCourses.getMapId()
    if not SPSWaterCourses.isAuthority() then
        -- joined game: the host's courses arrive by SPSWaterCourseEvent (join dump); this PC's own
        -- file is NOT used. Courses that arrived before the planes were ready get their plane now.
        local n = 0
        for _, id in ipairs(SPSWaterCourses.order) do
            local c = SPSWaterCourses.courses[id]
            if c ~= nil and c.plane == nil and SPSWaterCourses.registerCourse(c) then n = n + 1 end
        end
        print(string.format("[SPS WC] joined game - water courses come from the host (%d held, %d registered now)",
            #SPSWaterCourses.order, n))
        return
    end
    SPSWaterCourses.reset()
    local path = SPSWaterCourses.getFilePath()
    SPSWaterCourses.loadedMapId = SPSWaterCourses.getMapId()
    if path == nil then
        print("[SPS WC] no map id / profile path - water courses disabled")
        return
    end
    if fileExists == nil or not fileExists(path) then
        wcLog("no water course file for this map (%s)", tostring(path))
        return
    end
    local xml = XMLFile.load("spsWaterCourses", path)
    if xml == nil then
        print("[SPS WC] could not read " .. path)
        return
    end
    local n = 0
    xml:iterate("spsWaterCourses.course", function(_, key)
        local id     = xml:getInt(key .. "#id")
        local name   = xml:getString(key .. "#name") or ""
        local waterY = xml:getFloat(key .. "#waterY")
        local points = {}
        xml:iterate(key .. ".point", function(_, pKey)
            local x, z = xml:getFloat(pKey .. "#x"), xml:getFloat(pKey .. "#z")
            if x ~= nil and z ~= nil then
                points[#points + 1] = x
                points[#points + 1] = z
            end
        end)
        if id ~= nil and waterY ~= nil and #points >= 2 * SPSWaterCourses.MIN_POINTS then
            local course = { id = id, name = name, waterY = waterY, points = points }
            SPSWaterCourses.courses[id] = course
            table.insert(SPSWaterCourses.order, id)
            SPSWaterCourses.nextId = math.max(SPSWaterCourses.nextId, id + 1)
            SPSWaterCourses.registerCourse(course)
            n = n + 1
        else
            print(string.format("[SPS WC] skipped a broken course entry in %s (%s)", path, key))
        end
    end)
    xml:delete()
    spsInfo(string.format("[SPS WC] loaded %d player-drawn water course(s) for map '%s'", n, tostring(SPSWaterCourses.loadedMapId)))
end

function SPSWaterCourses.save()
    local path, dir = SPSWaterCourses.getFilePath(), SPSWaterCourses.getDir()
    if path == nil then return false end
    if createFolder ~= nil then
        createFolder(getUserProfileAppPath() .. "modSettings/")
        createFolder(getUserProfileAppPath() .. "modSettings/FS25_SlurryPipeSystem/")
        createFolder(dir)
    end
    local xml = XMLFile.create("spsWaterCourses", path, "spsWaterCourses")
    if xml == nil then
        print("[SPS WC] could not write " .. path)
        return false
    end
    xml:setString("spsWaterCourses#mapId", tostring(SPSWaterCourses.getMapId()))
    xml:setString("spsWaterCourses#mapTitle", tostring(g_currentMission.missionInfo.mapTitle or ""))
    xml:setInt("spsWaterCourses#version", SPSWaterCourses.VERSION)
    local i = 0
    for _, id in ipairs(SPSWaterCourses.order) do
        local c = SPSWaterCourses.courses[id]
        if c ~= nil then
            local key = string.format("spsWaterCourses.course(%d)", i)
            xml:setInt(key .. "#id", c.id)
            xml:setString(key .. "#name", c.name or "")
            xml:setFloat(key .. "#waterY", c.waterY)
            if c.created ~= nil then xml:setString(key .. "#created", c.created) end
            for p = 1, #c.points / 2 do
                local pKey = string.format("%s.point(%d)", key, p - 1)
                xml:setFloat(pKey .. "#x", c.points[2 * p - 1])
                xml:setFloat(pKey .. "#z", c.points[2 * p])
            end
            i = i + 1
        end
    end
    xml:save(false, true)
    xml:delete()
    wcLog("saved %d course(s) to %s", i, path)
    return true
end

-- ---------------------------------------------------------------------------
--  add / remove / query
-- ---------------------------------------------------------------------------
function SPSWaterCourses.defaultName()
    return string.format(g_i18n:getText("sps_waterCourse_defaultName"), SPSWaterCourses.nextId)
end

function SPSWaterCourses.addCourse(points, waterY, name)
    local ok, reason = SPSWaterCourses.validateRing(points)
    if not ok then return nil, reason end
    local copy = {}
    for i = 1, #points do copy[i] = points[i] end
    local course = {
        id      = SPSWaterCourses.nextId,
        name    = (name ~= nil and name ~= "") and name or SPSWaterCourses.defaultName(),
        waterY  = waterY,
        points  = copy,
        created = getDate ~= nil and getDate("%Y-%m-%d %H:%M") or nil,
    }
    SPSWaterCourses.nextId = SPSWaterCourses.nextId + 1
    SPSWaterCourses.courses[course.id] = course
    table.insert(SPSWaterCourses.order, course.id)
    SPSWaterCourses.registerCourse(course)
    SPSWaterCourses.save()
    print(string.format("[SPS WC] added water course %d '%s': %d points, surface %.2f m", course.id, course.name, #copy / 2, waterY))
    return course, nil
end

function SPSWaterCourses.removeCourse(id)
    local course = SPSWaterCourses.courses[id]
    if course == nil then return false end
    SPSWaterCourses.unregisterCourse(course)
    SPSWaterCourses.courses[id] = nil
    for i = #SPSWaterCourses.order, 1, -1 do
        if SPSWaterCourses.order[i] == id then table.remove(SPSWaterCourses.order, i) end
    end
    SPSWaterCourses.save()
    print(string.format("[SPS WC] removed water course %d '%s'", id, tostring(course.name)))
    return true
end

-- ---------------------------------------------------------------------------
--  MP entry points (SP / host / dedicated apply directly; a client asks the server)
-- ---------------------------------------------------------------------------
-- Brushes + console use these. Returns course (server) or nil, reason; on a client the reason is
-- "sent" and the course appears when the server's broadcast comes back.
function SPSWaterCourses.requestAdd(points, waterY, name)
    if SPSWaterCourses.isAuthority() then
        local course, reason = SPSWaterCourses.addCourse(points, waterY, name)
        if course ~= nil and SPSWaterCourseEvent ~= nil and g_server.broadcastEvent ~= nil then
            g_server:broadcastEvent(SPSWaterCourseEvent.newAdd(course), false)
        end
        return course, reason
    end
    local ok, reason = SPSWaterCourses.validateRing(points)
    if not ok then return nil, reason end
    if SPSWaterCourseEvent == nil then return nil, "sps_waterCourse_crossing" end
    local copy = {}
    for i = 1, #points do copy[i] = points[i] end
    SPSWaterCourseEvent.sendToServer(SPSWaterCourseEvent.new(SPSWaterCourseEvent.ADD, 0, name or "", waterY, copy))
    wcLog("ADD request sent to the server (%d points, waterY %.2f)", #copy / 2, waterY)
    return nil, "sent"
end

function SPSWaterCourses.requestRemove(id)
    if SPSWaterCourses.isAuthority() then
        local ok = SPSWaterCourses.removeCourse(id)
        if ok and SPSWaterCourseEvent ~= nil and g_server.broadcastEvent ~= nil then
            g_server:broadcastEvent(SPSWaterCourseEvent.newRemove(id), false)
        end
        return ok
    end
    if SPSWaterCourseEvent == nil or SPSWaterCourses.courses[id] == nil then return false end
    SPSWaterCourseEvent.sendToServer(SPSWaterCourseEvent.newRemove(id))
    wcLog("REMOVE request for course %d sent to the server", id)
    return true
end

-- Client side: the server's result. No file, no validation; an existing id is replaced.
function SPSWaterCourses.applyNetAdd(id, name, waterY, points)
    if id == nil or waterY == nil or points == nil or #points < 2 * SPSWaterCourses.MIN_POINTS then
        print("[SPS WC] ignored a broken water course from the server")
        return nil
    end
    local old = SPSWaterCourses.courses[id]
    if old ~= nil then SPSWaterCourses.unregisterCourse(old) end
    local copy = {}
    for i = 1, #points do copy[i] = points[i] end
    local course = { id = id, name = name or "", waterY = waterY, points = copy }
    SPSWaterCourses.courses[id] = course
    if old == nil then table.insert(SPSWaterCourses.order, id) end
    SPSWaterCourses.nextId = math.max(SPSWaterCourses.nextId, id + 1)   -- keeps the name-box prefill sensible
    SPSWaterCourses.registerCourse(course)
    print(string.format("[SPS WC] water course %d '%s' received from the host (%d points, surface %.2f m)",
        id, course.name, #copy / 2, waterY))
    return course
end

function SPSWaterCourses.applyNetRemove(id)
    local course = SPSWaterCourses.courses[id]
    if course == nil then return false end
    SPSWaterCourses.unregisterCourse(course)
    SPSWaterCourses.courses[id] = nil
    for i = #SPSWaterCourses.order, 1, -1 do
        if SPSWaterCourses.order[i] == id then table.remove(SPSWaterCourses.order, i) end
    end
    print(string.format("[SPS WC] water course %d '%s' removed by the host", id, tostring(course.name)))
    return true
end

function SPSWaterCourses.findCourseAt(x, z)
    for _, id in ipairs(SPSWaterCourses.order) do
        local c = SPSWaterCourses.courses[id]
        if c ~= nil and SPSWaterCourses.isPointInRing(x, z, c.points) then return c end
    end
    return nil
end

-- ---------------------------------------------------------------------------
--  drawing (debug lines, only while a brush is active)
-- ---------------------------------------------------------------------------
SPSWaterCourses.POST_HEIGHT = 1.0

function SPSWaterCourses.drawRing(points, y, r, g, b, closed, postHeight)
    local n = #points / 2
    local ph = postHeight or SPSWaterCourses.POST_HEIGHT
    for i = 1, n do
        local x, z = points[2 * i - 1], points[2 * i]
        drawDebugLine(x, y, z, r, g, b, x, y + ph, z, r, g, b)
        if i < n or closed then
            local j = (i % n) + 1
            local x2, z2 = points[2 * j - 1], points[2 * j]
            drawDebugLine(x, y + ph, z, r, g, b, x2, y + ph, z2, r, g, b)
            drawDebugLine(x, y, z, r, g, b, x2, y, z2, r, g, b)
        end
    end
end

function SPSWaterCourses.drawCourse(course, r, g, b)
    SPSWaterCourses.drawRing(course.points, course.waterY + 0.05, r, g, b, true, 0.6)
end

-- ---------------------------------------------------------------------------
--  console
-- ---------------------------------------------------------------------------
function SPSWaterCourses.consoleList()
    local lines = { string.format("[SPS WC] map '%s', %s", tostring(SPSWaterCourses.loadedMapId),
        SPSWaterCourses.isAuthority() and ("file " .. tostring(SPSWaterCourses.getFilePath())) or "joined game (courses from the host, no local file)") }
    for _, id in ipairs(SPSWaterCourses.order) do
        local c = SPSWaterCourses.courses[id]
        if c ~= nil then
            table.insert(lines, string.format("   id %d  '%s'  %d points  waterY %.2f  area %.0f m2", c.id, c.name, #c.points / 2, c.waterY, SPSWaterCourses.polygonArea(c.points)))
        end
    end
    if #SPSWaterCourses.order == 0 then table.insert(lines, "   (none)") end
    return table.concat(lines, "\n")
end

function SPSWaterCourses.consoleRemove(_, idStr)
    local id = tonumber(idStr)
    if id == nil then return "usage: spsWaterCourseRemove <id>  (spsWaterCourses lists them)" end
    if SPSWaterCourses.courses[id] == nil then return "[SPS WC] no course with id " .. id end
    if SPSWaterCourses.requestRemove(id) then
        return SPSWaterCourses.isAuthority() and ("[SPS WC] removed " .. id) or ("[SPS WC] remove of " .. id .. " sent to the host")
    end
    return "[SPS WC] could not remove " .. id
end

-- dev aid: a square of the given half size round the player, water level from the player's position
function SPSWaterCourses.consoleAddHere(_, sizeStr)
    local half = tonumber(sizeStr) or 10
    if g_localPlayer == nil or g_localPlayer.getPosition == nil then return "[SPS WC] no local player" end
    local x, _, z = g_localPlayer:getPosition()
    local wy = SPSWaterCourses.sampleWaterY(x, z)
    if wy == nil then return "[SPS WC] no water at the player position - stand in / over the water" end
    local pts = { x - half, z - half, x + half, z - half, x + half, z + half, x - half, z + half }
    local c, reason = SPSWaterCourses.requestAdd(pts, wy, nil)
    if c == nil and reason == "sent" then return string.format("[SPS WC] test course at %.1f / %.1f sent to the host", x, z) end
    if c == nil then return "[SPS WC] rejected: " .. tostring(reason) end
    return string.format("[SPS WC] added test course %d at %.1f / %.1f, water %.2f", c.id, x, z, wy)
end

if addConsoleCommand ~= nil then
    addConsoleCommand("spsWaterCourses",       "List the player-drawn water courses of this map",            "consoleList",    SPSWaterCourses)
    addConsoleCommand("spsWaterCourseRemove",  "Remove a player-drawn water course: spsWaterCourseRemove <id>", "consoleRemove",  SPSWaterCourses)
end

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSWaterCourses 1.0.1.8 loaded (player-drawn water courses)") end
