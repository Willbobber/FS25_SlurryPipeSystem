-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.8

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
        -- [SPS MP 1.0.1.8] Apply now, or (client) defer until the vehicle registers.
        local object, nodeIndex, blocked = self.object, self.nodeIndex, self.blocked
        g_slurryPipeManager:applyOrDeferVehicleState(object, "BlockageEvent", function(entry, state)
            g_slurryPipeManager:applyBlockageByIndex(object, nodeIndex, blocked)
        end)
        -- Relay from a client to the rest via the server.
        if not connection:getIsServer() then
            g_server:broadcastEvent(SPSBlockageEvent.new(self.object, self.nodeIndex, self.blocked), nil, connection, self.object, nil, nil, true)
        end
    end
end

function SPSBlockageEvent.sendEvent(object, nodeIndex, blocked, noEventSend)
    if noEventSend == nil or not noEventSend then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSBlockageEvent.new(object, nodeIndex, blocked), nil, nil, object, nil, nil, true)
        else
            g_client:getServerConnection():sendEvent(SPSBlockageEvent.new(object, nodeIndex, blocked))
        end
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.6] SPSBlockageClearAnimEvent — replicates the CLEARING-sequence
-- animation (mechanism open / close-or-windback) so every peer sees a player's
-- clearing attempt. Pure visual: the authoritative blocked/cleared state still
-- travels via SPSBlockageEvent when the clear completes. Node addressed by the
-- same 1-based blockageEntries index as SPSBlockageEvent.
-- ---------------------------------------------------------------------------
SPSBlockageClearAnimEvent = {}
SPSBlockageClearAnimEvent_mt = Class(SPSBlockageClearAnimEvent, Event)
InitEventClass(SPSBlockageClearAnimEvent, "SPSBlockageClearAnimEvent")

function SPSBlockageClearAnimEvent.emptyNew()
    local self = Event.new(SPSBlockageClearAnimEvent_mt)
    return self
end

function SPSBlockageClearAnimEvent.new(object, nodeIndex, forward)
    local self = SPSBlockageClearAnimEvent.emptyNew()
    self.object    = object
    self.nodeIndex = nodeIndex
    self.forward   = forward == true
    return self
end

function SPSBlockageClearAnimEvent:readStream(streamId, connection)
    self.object    = NetworkUtil.readNodeObject(streamId)
    self.nodeIndex = streamReadUInt8(streamId)
    self.forward   = streamReadBool(streamId)
    self:run(connection)
end

function SPSBlockageClearAnimEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUInt8(streamId, self.nodeIndex)
    streamWriteBool(streamId, self.forward)
end

function SPSBlockageClearAnimEvent:run(connection)
    if self.object ~= nil and g_slurryPipeManager ~= nil then
        g_slurryPipeManager:playBlockageClearAnimByIndex(self.object, self.nodeIndex, self.forward)
        if not connection:getIsServer() then
            g_server:broadcastEvent(SPSBlockageClearAnimEvent.new(self.object, self.nodeIndex, self.forward), nil, connection, self.object, nil, nil, true)
        end
    end
end

function SPSBlockageClearAnimEvent.sendEvent(object, nodeIndex, forward, noEventSend)
    if noEventSend == nil or not noEventSend then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSBlockageClearAnimEvent.new(object, nodeIndex, forward), nil, nil, object, nil, nil, true)
        else
            g_client:getServerConnection():sendEvent(SPSBlockageClearAnimEvent.new(object, nodeIndex, forward))
        end
    end
end
