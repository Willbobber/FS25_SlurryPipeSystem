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
