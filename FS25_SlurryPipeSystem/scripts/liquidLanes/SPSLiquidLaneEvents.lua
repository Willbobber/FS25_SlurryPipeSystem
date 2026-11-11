-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSLiquidLaneEvents.lua — MP events for the FARM LIQUID LANES (animal water in,
-- milk out, sprayer sources through the bridge). Three events, addressed to the
-- liquid-lane registries only.
--
--   SPSLiquidLaneConnectEvent    object + couplingId + target + targetCouplingId + laneId
--   SPSLiquidLaneDisconnectEvent object + couplingId
--   SPSLiquidLaneValveStateEvent object + valveOpen          (barn lanes only; the
--                                SPRAYER lane uses the sprayer's own events)
--
-- laneId (UIntN 2): 0 = "resolve by arc on the server" (client-originated), else
-- the lane the server resolved — needed because the far coupler of the SPRAYER
-- lane lives in the sprayer registry, not the liquid-lane one.
-- Client -> server: the server applies and rebroadcasts. Connect and disconnect
-- rebroadcasts INCLUDE the originator (it applied nothing locally). Valve: the
-- client applies locally before sending, so the rebroadcast excludes the sender.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSLiquidLaneEvents 1.0.1.8 loaded") end

local function log(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("SPSLiquidLaneEvent") then return end
    if select("#", ...) > 0 then
        print("[SPS LL EVT] " .. string.format(fmt, ...))
    else
        print("[SPS LL EVT] " .. tostring(fmt))
    end
end

-- ---------------------------------------------------------------------------
-- SPSLiquidLaneConnectEvent
-- ---------------------------------------------------------------------------
SPSLiquidLaneConnectEvent = {}
SPSLiquidLaneConnectEvent_mt = Class(SPSLiquidLaneConnectEvent, Event)
InitEventClass(SPSLiquidLaneConnectEvent, "SPSLiquidLaneConnectEvent")

function SPSLiquidLaneConnectEvent.emptyNew()
    return Event.new(SPSLiquidLaneConnectEvent_mt)
end

function SPSLiquidLaneConnectEvent.new(object, couplingId, targetObject, targetCouplingId, laneId)
    local self = SPSLiquidLaneConnectEvent.emptyNew()
    self.object           = object
    self.couplingId       = couplingId or 0
    self.targetObject     = targetObject
    self.targetCouplingId = targetCouplingId or 0
    self.laneId           = laneId or 0
    return self
end

function SPSLiquidLaneConnectEvent:readStream(streamId, connection)
    self.object           = NetworkUtil.readNodeObject(streamId)
    self.couplingId       = streamReadUIntN(streamId, 8)
    self.targetObject     = NetworkUtil.readNodeObject(streamId)
    self.targetCouplingId = streamReadUIntN(streamId, 8)
    self.laneId           = streamReadUIntN(streamId, 3)   -- [SPS 1.0.1.8] 4 lanes (TRANSFER = 4)
    self:run(connection)
end

function SPSLiquidLaneConnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUIntN(streamId, self.couplingId, 8)
    NetworkUtil.writeNodeObject(streamId, self.targetObject)
    streamWriteUIntN(streamId, self.targetCouplingId, 8)
    streamWriteUIntN(streamId, self.laneId, 3)
end

function SPSLiquidLaneConnectEvent:run(connection)
    log("ConnectEvent:run idA=%s idB=%s lane=%s", tostring(self.couplingId), tostring(self.targetCouplingId), tostring(self.laneId))
    if g_slurryPipeManager == nil or g_slurryPipeManager.applyLiquidLaneConnectById == nil then return end
    g_slurryPipeManager:applyLiquidLaneConnectById(self.object, self.couplingId, self.targetObject, self.targetCouplingId, self.laneId)
    if not connection:getIsServer() then
        -- Resolve the pair on the server and rebroadcast BOTH ids + the lane to
        -- everyone, originator included (it applied nothing locally).
        local cV = g_slurryPipeManager:_findLiquidLaneCouplingById(self.object, self.couplingId)
        local tObj, tId, lane = self.targetObject, self.targetCouplingId, self.laneId
        if cV ~= nil and cV.isConnected and cV.connectedPartnerCoupling ~= nil then
            local cP = cV.connectedPartnerCoupling
            tObj = cP.placeable or cP.object
            tId  = cP.id
            lane = cV.activeLane ~= nil and cV.activeLane.id or lane
        end
        g_server:broadcastEvent(SPSLiquidLaneConnectEvent.new(self.object, self.couplingId, tObj, tId, lane),
            nil, nil, self.object, nil, nil, true)
    end
end

function SPSLiquidLaneConnectEvent.sendEvent(object, couplingId, targetObject, targetCouplingId, laneId)
    if g_server ~= nil then
        g_server:broadcastEvent(SPSLiquidLaneConnectEvent.new(object, couplingId, targetObject, targetCouplingId, laneId),
            nil, nil, object, nil, nil, true)
    else
        g_client:getServerConnection():sendEvent(SPSLiquidLaneConnectEvent.new(object, couplingId, targetObject, targetCouplingId, laneId))
    end
end

-- ---------------------------------------------------------------------------
-- SPSLiquidLaneDisconnectEvent
-- ---------------------------------------------------------------------------
SPSLiquidLaneDisconnectEvent = {}
SPSLiquidLaneDisconnectEvent_mt = Class(SPSLiquidLaneDisconnectEvent, Event)
InitEventClass(SPSLiquidLaneDisconnectEvent, "SPSLiquidLaneDisconnectEvent")

function SPSLiquidLaneDisconnectEvent.emptyNew()
    return Event.new(SPSLiquidLaneDisconnectEvent_mt)
end

function SPSLiquidLaneDisconnectEvent.new(object, couplingId)
    local self = SPSLiquidLaneDisconnectEvent.emptyNew()
    self.object     = object
    self.couplingId = couplingId or 0
    return self
end

function SPSLiquidLaneDisconnectEvent:readStream(streamId, connection)
    self.object     = NetworkUtil.readNodeObject(streamId)
    self.couplingId = streamReadUIntN(streamId, 8)
    self:run(connection)
end

function SPSLiquidLaneDisconnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUIntN(streamId, self.couplingId, 8)
end

function SPSLiquidLaneDisconnectEvent:run(connection)
    log("DisconnectEvent:run id=%s", tostring(self.couplingId))
    if g_slurryPipeManager == nil or g_slurryPipeManager.applyLiquidLaneDisconnect == nil then return end
    g_slurryPipeManager:applyLiquidLaneDisconnect(self.object, self.couplingId, nil)
    if not connection:getIsServer() then
        g_server:broadcastEvent(SPSLiquidLaneDisconnectEvent.new(self.object, self.couplingId),
            nil, nil, self.object, nil, nil, true)
    end
end

function SPSLiquidLaneDisconnectEvent.sendEvent(object, couplingId)
    if g_server ~= nil then
        g_server:broadcastEvent(SPSLiquidLaneDisconnectEvent.new(object, couplingId), nil, nil, object, nil, nil, true)
    else
        g_client:getServerConnection():sendEvent(SPSLiquidLaneDisconnectEvent.new(object, couplingId))
    end
end

-- ---------------------------------------------------------------------------
-- SPSLiquidLaneValveStateEvent (barn lanes)
-- ---------------------------------------------------------------------------
SPSLiquidLaneValveStateEvent = {}
SPSLiquidLaneValveStateEvent_mt = Class(SPSLiquidLaneValveStateEvent, Event)
InitEventClass(SPSLiquidLaneValveStateEvent, "SPSLiquidLaneValveStateEvent")

function SPSLiquidLaneValveStateEvent.emptyNew()
    return Event.new(SPSLiquidLaneValveStateEvent_mt)
end

function SPSLiquidLaneValveStateEvent.new(object, valveOpen)
    local self = SPSLiquidLaneValveStateEvent.emptyNew()
    self.object    = object
    self.valveOpen = valveOpen == true
    return self
end

function SPSLiquidLaneValveStateEvent:readStream(streamId, connection)
    self.object    = NetworkUtil.readNodeObject(streamId)
    self.valveOpen = streamReadBool(streamId)
    self:run(connection)
end

function SPSLiquidLaneValveStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteBool(streamId, self.valveOpen)
end

function SPSLiquidLaneValveStateEvent:run(connection)
    log("ValveStateEvent:run open=%s", tostring(self.valveOpen))
    if g_slurryPipeManager == nil or g_slurryPipeManager.applyLiquidLaneValveState == nil then return end
    g_slurryPipeManager:applyLiquidLaneValveState(self.object, self.valveOpen)
    if not connection:getIsServer() then
        -- Sender already applied locally: exclude it from the rebroadcast.
        g_server:broadcastEvent(SPSLiquidLaneValveStateEvent.new(self.object, self.valveOpen),
            nil, connection, self.object, nil, nil, true)
    end
end

function SPSLiquidLaneValveStateEvent.sendEvent(object, valveOpen)
    if g_server ~= nil then
        g_server:broadcastEvent(SPSLiquidLaneValveStateEvent.new(object, valveOpen), nil, nil, object, nil, nil, true)
    else
        g_client:getServerConnection():sendEvent(SPSLiquidLaneValveStateEvent.new(object, valveOpen))
    end
end


-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Fitting ball valve (PHYSICAL pipes): R at a lane fitting. Coupling = owner object + id
-- (vehicle liquid connector or barn coupler). Client requests, the server applies and echoes to everyone.
-- ---------------------------------------------------------------------------
SPSLaneFittingValveEvent = {}
SPSLaneFittingValveEvent_mt = Class(SPSLaneFittingValveEvent, Event)
InitEventClass(SPSLaneFittingValveEvent, "SPSLaneFittingValveEvent")

function SPSLaneFittingValveEvent.emptyNew()
    return Event.new(SPSLaneFittingValveEvent_mt)
end

function SPSLaneFittingValveEvent.new(object, couplingId, open)
    local self = SPSLaneFittingValveEvent.emptyNew()
    self.object     = object
    self.couplingId = couplingId or 0
    self.open       = open == true
    return self
end

function SPSLaneFittingValveEvent:readStream(streamId, connection)
    self.object     = NetworkUtil.readNodeObject(streamId)
    self.couplingId = streamReadUIntN(streamId, 8)
    self.open       = streamReadBool(streamId)
    self:run(connection)
end

function SPSLaneFittingValveEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUIntN(streamId, self.couplingId, 8)
    streamWriteBool(streamId, self.open)
end

function SPSLaneFittingValveEvent:run(connection)
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyLaneFittingValveById ~= nil then
        g_slurryPipeManager:applyLaneFittingValveById(self.object, self.couplingId, self.open)
    end
    if not connection:getIsServer() then
        -- the sender did NOT apply locally: echo to everyone including it
        g_server:broadcastEvent(SPSLaneFittingValveEvent.new(self.object, self.couplingId, self.open), nil, nil, self.object, nil, nil, true)
    end
end

function SPSLaneFittingValveEvent.sendEvent(object, couplingId, open)
    if g_server ~= nil then
        g_server:broadcastEvent(SPSLaneFittingValveEvent.new(object, couplingId, open), nil, nil, object, nil, nil, true)
    else
        g_client:getServerConnection():sendEvent(SPSLaneFittingValveEvent.new(object, couplingId, open))
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] TRANSFER lane (tanker to tanker): Y at a tanker's control node = Load (into it) / Unload.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- [SPS 2026-11-09] ORIGINAL-MODE bowser pipes (550 Water/Chem Bowser): kind 1 = the suction pipe laid to a point (R in
-- the bowser's arc), kind 2 = the wash hose taken into a player's hands (X at the pump; userId = whose hands). on=false
-- takes it back. Server applies + broadcasts; a client asks.
-- ---------------------------------------------------------------------------
SPSLiquidLaneOrigPipeEvent = {}
SPSLiquidLaneOrigPipeEvent_mt = Class(SPSLiquidLaneOrigPipeEvent, Event)
InitEventClass(SPSLiquidLaneOrigPipeEvent, "SPSLiquidLaneOrigPipeEvent")

function SPSLiquidLaneOrigPipeEvent.emptyNew()
    return Event.new(SPSLiquidLaneOrigPipeEvent_mt)
end

function SPSLiquidLaneOrigPipeEvent.new(object, couplingId, kind, on, x, y, z, userId)
    local self = SPSLiquidLaneOrigPipeEvent.emptyNew()
    self.object, self.couplingId, self.kind, self.on = object, couplingId, kind, on == true
    self.x, self.y, self.z, self.userId = x or 0, y or 0, z or 0, userId or -1
    return self
end

function SPSLiquidLaneOrigPipeEvent:readStream(streamId, connection)
    self.object     = NetworkUtil.readNodeObject(streamId)
    self.couplingId = streamReadUIntN(streamId, 6)
    self.kind       = streamReadUIntN(streamId, 3)   -- [2026-11-10] 3 bits: kind 4 = lay the carried suction end
    self.on         = streamReadBool(streamId)
    self.x, self.y, self.z = streamReadFloat32(streamId), streamReadFloat32(streamId), streamReadFloat32(streamId)
    self.userId     = streamReadInt32(streamId)
    self:run(connection)
end

function SPSLiquidLaneOrigPipeEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUIntN(streamId, self.couplingId or 1, 6)
    streamWriteUIntN(streamId, self.kind or 1, 3)
    streamWriteBool(streamId, self.on)
    streamWriteFloat32(streamId, self.x); streamWriteFloat32(streamId, self.y); streamWriteFloat32(streamId, self.z)
    streamWriteInt32(streamId, self.userId or -1)
end

function SPSLiquidLaneOrigPipeEvent:run(connection)
    log("OrigPipeEvent:run kind=%s on=%s", tostring(self.kind), tostring(self.on))
    if g_slurryPipeManager == nil or g_slurryPipeManager.applyLiquidLaneOrigPipe == nil then return end
    g_slurryPipeManager:applyLiquidLaneOrigPipe(self.object, self.couplingId, self.kind, self.on, self.x, self.y, self.z, self.userId)
    if not connection:getIsServer() then
        g_server:broadcastEvent(SPSLiquidLaneOrigPipeEvent.new(self.object, self.couplingId, self.kind, self.on, self.x, self.y, self.z, self.userId),
            nil, connection, self.object, nil, nil, true)
    end
end

function SPSLiquidLaneOrigPipeEvent.sendEvent(object, couplingId, kind, on, x, y, z, userId)
    if g_server ~= nil then
        g_server:broadcastEvent(SPSLiquidLaneOrigPipeEvent.new(object, couplingId, kind, on, x, y, z, userId), nil, nil, object, nil, nil, true)
    else
        g_client:getServerConnection():sendEvent(SPSLiquidLaneOrigPipeEvent.new(object, couplingId, kind, on, x, y, z, userId))
    end
end

SPSLiquidLaneTransferDirectionEvent = {}
SPSLiquidLaneTransferDirectionEvent_mt = Class(SPSLiquidLaneTransferDirectionEvent, Event)
InitEventClass(SPSLiquidLaneTransferDirectionEvent, "SPSLiquidLaneTransferDirectionEvent")

function SPSLiquidLaneTransferDirectionEvent.emptyNew()
    return Event.new(SPSLiquidLaneTransferDirectionEvent_mt)
end

function SPSLiquidLaneTransferDirectionEvent.new(object, direction)
    local self = SPSLiquidLaneTransferDirectionEvent.emptyNew()
    self.object    = object
    self.direction = direction or 0
    return self
end

function SPSLiquidLaneTransferDirectionEvent:readStream(streamId, connection)
    self.object    = NetworkUtil.readNodeObject(streamId)
    self.direction = streamReadUIntN(streamId, 1)
    self:run(connection)
end

function SPSLiquidLaneTransferDirectionEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUIntN(streamId, self.direction, 1)
end

function SPSLiquidLaneTransferDirectionEvent:run(connection)
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyLiquidLaneTransferDirection ~= nil then
        g_slurryPipeManager:applyLiquidLaneTransferDirection(self.object, self.direction)
    end
    if not connection:getIsServer() then
        g_server:broadcastEvent(SPSLiquidLaneTransferDirectionEvent.new(self.object, self.direction), nil, nil, self.object, nil, nil, true)
    end
end

function SPSLiquidLaneTransferDirectionEvent.sendEvent(object, direction)
    if g_server ~= nil then
        g_server:broadcastEvent(SPSLiquidLaneTransferDirectionEvent.new(object, direction), nil, nil, object, nil, nil, true)
    else
        g_client:getServerConnection():sendEvent(SPSLiquidLaneTransferDirectionEvent.new(object, direction))
    end
end

-- ---------------------------------------------------------------------------
-- [SPS MKS8 2026-11-10] selected tank of a multi-tank fitting (a client's request is applied on the server first)
-- ---------------------------------------------------------------------------
SPSLiquidLaneTankSelectEvent = {}
SPSLiquidLaneTankSelectEvent_mt = Class(SPSLiquidLaneTankSelectEvent, Event)
InitEventClass(SPSLiquidLaneTankSelectEvent, "SPSLiquidLaneTankSelectEvent")

function SPSLiquidLaneTankSelectEvent.emptyNew()
    return Event.new(SPSLiquidLaneTankSelectEvent_mt)
end

function SPSLiquidLaneTankSelectEvent.new(object, couplingId, tankIdx)
    local self = SPSLiquidLaneTankSelectEvent.emptyNew()
    self.object     = object
    self.couplingId = couplingId or 1
    self.tankIdx    = tankIdx or 1
    return self
end

function SPSLiquidLaneTankSelectEvent:readStream(streamId, connection)
    self.object     = NetworkUtil.readNodeObject(streamId)
    self.couplingId = streamReadUIntN(streamId, 8)
    self.tankIdx    = streamReadUIntN(streamId, 8)
    self:run(connection)
end

function SPSLiquidLaneTankSelectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUIntN(streamId, self.couplingId or 1, 8)
    streamWriteUIntN(streamId, self.tankIdx or 1, 8)
end

function SPSLiquidLaneTankSelectEvent:run(connection)
    local ok = false
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyLiquidLaneTankSelect ~= nil then
        ok = g_slurryPipeManager:applyLiquidLaneTankSelect(self.object, self.couplingId, self.tankIdx)
    end
    if not connection:getIsServer() and ok then
        g_server:broadcastEvent(SPSLiquidLaneTankSelectEvent.new(self.object, self.couplingId, self.tankIdx), nil, nil, self.object, nil, nil, true)
    end
end

function SPSLiquidLaneTankSelectEvent.sendEvent(object, couplingId, tankIdx)
    if g_server ~= nil then
        g_server:broadcastEvent(SPSLiquidLaneTankSelectEvent.new(object, couplingId, tankIdx), nil, nil, object, nil, nil, true)
    else
        g_client:getServerConnection():sendEvent(SPSLiquidLaneTankSelectEvent.new(object, couplingId, tankIdx))
    end
end

-- ---------------------------------------------------------------------------
-- [SPS MKS8 2026-11-10] the door (loadAnimation) of a lane vehicle: open / closed
-- ---------------------------------------------------------------------------
SPSLiquidLaneDoorEvent = {}
SPSLiquidLaneDoorEvent_mt = Class(SPSLiquidLaneDoorEvent, Event)
InitEventClass(SPSLiquidLaneDoorEvent, "SPSLiquidLaneDoorEvent")

function SPSLiquidLaneDoorEvent.emptyNew()
    return Event.new(SPSLiquidLaneDoorEvent_mt)
end

function SPSLiquidLaneDoorEvent.new(object, open)
    local self = SPSLiquidLaneDoorEvent.emptyNew()
    self.object = object
    self.open   = open == true
    return self
end

function SPSLiquidLaneDoorEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.open   = streamReadBool(streamId)
    self:run(connection)
end

function SPSLiquidLaneDoorEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteBool(streamId, self.open == true)
end

function SPSLiquidLaneDoorEvent:run(connection)
    local ok = false
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyLiquidLaneDoor ~= nil then
        if connection:getIsServer() or self.open or g_slurryPipeManager.llDoorCanClose == nil or g_slurryPipeManager:llDoorCanClose(self.object) then
            ok = g_slurryPipeManager:applyLiquidLaneDoor(self.object, self.open)
        end
    end
    if not connection:getIsServer() and ok then
        g_server:broadcastEvent(SPSLiquidLaneDoorEvent.new(self.object, self.open), nil, nil, self.object, nil, nil, true)
    end
end

function SPSLiquidLaneDoorEvent.sendEvent(object, open)
    if g_server ~= nil then
        g_server:broadcastEvent(SPSLiquidLaneDoorEvent.new(object, open), nil, nil, object, nil, nil, true)
    else
        g_client:getServerConnection():sendEvent(SPSLiquidLaneDoorEvent.new(object, open))
    end
end
