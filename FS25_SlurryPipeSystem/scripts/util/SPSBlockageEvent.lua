-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.4

-- SPSBlockageEvent.lua
-- FS25_SlurryPipeSystem
--
-- Syncs a single spreader blockage node's blocked/cleared state to all clients.
-- The node is identified by its 1-based index within the vehicle's blockageEntries
-- list (the same order they are parsed from <blockageNodes> in fillPoints.xml), so
-- both ends must share the same config. Mirrors the SPSSprayerEvents pattern.

SPSBlockageEvent = {}
SPSBlockageEvent_mt = Class(SPSBlockageEvent, Event)
InitEventClass(SPSBlockageEvent, "SPSBlockageEvent")

function SPSBlockageEvent.emptyNew()
    local self = Event.new(SPSBlockageEvent_mt)
    return self
end

function SPSBlockageEvent.new(object, nodeIndex, blocked)
    local self = SPSBlockageEvent.emptyNew()
    self.object    = object
    self.nodeIndex = nodeIndex
    self.blocked   = blocked
    return self
end

function SPSBlockageEvent:readStream(streamId, connection)
    self.object    = NetworkUtil.readNodeObject(streamId)
    self.nodeIndex = streamReadUInt8(streamId)
    self.blocked   = streamReadBool(streamId)
    self:run(connection)
end

function SPSBlockageEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUInt8(streamId, self.nodeIndex)
    streamWriteBool(streamId, self.blocked)
end

function SPSBlockageEvent:run(connection)
    if self.object ~= nil and g_slurryPipeManager ~= nil then
        g_slurryPipeManager:applyBlockageByIndex(self.object, self.nodeIndex, self.blocked)
        -- Relay from a client to the rest via the server.
        if not connection:getIsServer() then
            g_server:broadcastEvent(SPSBlockageEvent.new(self.object, self.nodeIndex, self.blocked), nil, connection, self.object)
        end
    end
end

function SPSBlockageEvent.sendEvent(object, nodeIndex, blocked, noEventSend)
    if noEventSend == nil or not noEventSend then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSBlockageEvent.new(object, nodeIndex, blocked), nil, nil, object)
        else
            g_client:getServerConnection():sendEvent(SPSBlockageEvent.new(object, nodeIndex, blocked))
        end
    end
end