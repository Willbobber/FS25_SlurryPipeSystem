-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

--[[
  SPSWaterCourseEvent.lua  -  [SPS 1.0.1.8] MP sync of the player-drawn water courses
  (step 4 of 05_PROJECT_DOCS/SPS_WATER_COURSE_DESIGN.md).

  ONE event, two modes:
    ADD     id + name + waterY + ring points   (id 0 in a client request = "server assigns")
    REMOVE  id

  Authority: the SERVER (listen host or dedicated) owns the course list and its per-map file.
    client brush / console  -> request to the server (SPSWaterCourses.requestAdd / requestRemove)
    server                  -> applies through SPSWaterCourses.addCourse / removeCourse (validate,
                               save, register the live water plane) and broadcasts the RESULT to
                               every client, the sender included (it applied nothing locally).
    client receiving        -> SPSWaterCourses.applyNetAdd / applyNetRemove (no file, no validation).
  A client request is refused (nothing broadcast) when the sending player lacks the LANDSCAPING
  permission or the ring fails the server's checks - the same apply-then-rebroadcast rule as the
  physical pipe events (2026-10-19 MP review).

  Late join: SlurryPipeManager.sendFullStateToConnection pass 14 sends one ADD per course.

  Stream layout (readStream / writeStream are kept symmetric by hand - check both when editing):
    mode    UIntN 1
    id      UIntN 16
    ADD only: name String, waterY Float32, nPoints UIntN 9 (<= SPSWaterCourses.MAX_POINTS 256),
              then nPoints x (x Float32, z Float32)
]]

SPSWaterCourseEvent = {}
local SPSWaterCourseEvent_mt = Class(SPSWaterCourseEvent, Event)
InitEventClass(SPSWaterCourseEvent, "SPSWaterCourseEvent")

SPSWaterCourseEvent.ADD    = 0
SPSWaterCourseEvent.REMOVE = 1

local function wcEvtLog(fmt, ...)
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSWaterCourses") then
        print("[SPS WC EVT] " .. string.format(fmt, ...))
    end
end

function SPSWaterCourseEvent.emptyNew()
    return Event.new(SPSWaterCourseEvent_mt)
end

-- points = flat {x1,z1,x2,z2,...}; the table is referenced, not copied (callers pass a fresh copy)
function SPSWaterCourseEvent.new(mode, id, name, waterY, points)
    local self = SPSWaterCourseEvent.emptyNew()
    self.mode   = mode or SPSWaterCourseEvent.ADD
    self.id     = id or 0
    self.name   = name or ""
    self.waterY = waterY or 0
    self.points = points or {}
    return self
end

function SPSWaterCourseEvent.newAdd(course)
    return SPSWaterCourseEvent.new(SPSWaterCourseEvent.ADD, course.id, course.name, course.waterY, course.points)
end

function SPSWaterCourseEvent.newRemove(id)
    return SPSWaterCourseEvent.new(SPSWaterCourseEvent.REMOVE, id, nil, nil, nil)
end

function SPSWaterCourseEvent:readStream(streamId, connection)
    self.mode = streamReadUIntN(streamId, 1)
    self.id   = streamReadUIntN(streamId, 16)
    if self.mode == SPSWaterCourseEvent.ADD then
        self.name   = streamReadString(streamId)
        self.waterY = streamReadFloat32(streamId)
        local n = streamReadUIntN(streamId, 9)
        local pts = {}
        for i = 1, n do
            pts[2 * i - 1] = streamReadFloat32(streamId)
            pts[2 * i]     = streamReadFloat32(streamId)
        end
        self.points = pts
    else
        self.name, self.waterY, self.points = "", 0, {}
    end
    self:run(connection)
end

function SPSWaterCourseEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.mode or SPSWaterCourseEvent.ADD, 1)
    streamWriteUIntN(streamId, math.max(0, math.min(65535, self.id or 0)), 16)
    if self.mode == SPSWaterCourseEvent.ADD then
        streamWriteString(streamId, self.name or "")
        streamWriteFloat32(streamId, self.waterY or 0)
        local pts = self.points or {}
        local n = math.min(math.floor(#pts / 2), SPSWaterCourses ~= nil and SPSWaterCourses.MAX_POINTS or 256)
        streamWriteUIntN(streamId, n, 9)
        for i = 1, n do
            streamWriteFloat32(streamId, pts[2 * i - 1] or 0)
            streamWriteFloat32(streamId, pts[2 * i] or 0)
        end
    end
end

function SPSWaterCourseEvent:run(connection)
    if SPSWaterCourses == nil then return end

    if not connection:getIsServer() then
        -- we are the server; a client asked for a change
        if g_server == nil then return end
        if g_currentMission ~= nil and g_currentMission.getHasPlayerPermission ~= nil
        and not g_currentMission:getHasPlayerPermission(Farm.PERMISSION.LANDSCAPING, connection) then
            print("[SPS WC] refused a water course request: the player has no landscaping permission")
            return
        end
        if self.mode == SPSWaterCourseEvent.ADD then
            local course, reason = SPSWaterCourses.addCourse(self.points, self.waterY, self.name)
            if course == nil then
                print(string.format("[SPS WC] refused a client's water course (%s)", tostring(reason)))
                return
            end
            -- the result carries the server's id and final name
            g_server:broadcastEvent(SPSWaterCourseEvent.newAdd(course), false)
            wcEvtLog("client ADD applied as course %d, broadcast", course.id)
        else
            if not SPSWaterCourses.removeCourse(self.id) then
                print(string.format("[SPS WC] refused a client's remove: no course with id %d", self.id))
                return
            end
            g_server:broadcastEvent(SPSWaterCourseEvent.newRemove(self.id), false)
            wcEvtLog("client REMOVE %d applied, broadcast", self.id)
        end
        return
    end

    -- we are a client; the server tells us the result
    if self.mode == SPSWaterCourseEvent.ADD then
        SPSWaterCourses.applyNetAdd(self.id, self.name, self.waterY, self.points)
    else
        SPSWaterCourses.applyNetRemove(self.id)
    end
end

-- Client -> server request (no-op on the server; callers use SPSWaterCourses.requestAdd / requestRemove)
function SPSWaterCourseEvent.sendToServer(event)
    if g_client ~= nil and g_client.getServerConnection ~= nil then
        local connection = g_client:getServerConnection()
        if connection ~= nil then
            connection:sendEvent(event)
            return true
        end
    end
    return false
end

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSWaterCourseEvent 1.0.1.8 loaded (water course MP sync)") end
