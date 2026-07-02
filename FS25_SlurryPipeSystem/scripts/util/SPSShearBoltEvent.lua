-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4
--
-- SPSShearBoltEvent.lua
-- FS25_SlurryPipeSystem
--
-- Syncs a vacuum tanker's shear-bolt snapped/repaired state to all peers. The
-- receiving side calls SPSShearBolt.applyState via the manager, which sets the flag
-- and freezes/restores the PTO shaft visual. Mirrors the SPSBlockageEvent pattern.

SPSShearBoltEvent = {}
SPSShearBoltEvent_mt = Class(SPSShearBoltEvent, Event)
InitEventClass(SPSShearBoltEvent, "SPSShearBoltEvent")

function SPSShearBoltEvent.emptyNew()
    local self = Event.new(SPSShearBoltEvent_mt)
    return self
end

function SPSShearBoltEvent.new(object, snapped)
    local self = SPSShearBoltEvent.emptyNew()
    self.object  = object
    self.snapped = snapped
    return self
end

function SPSShearBoltEvent:readStream(streamId, connection)
    self.object  = NetworkUtil.readNodeObject(streamId)
    self.snapped = streamReadBool(streamId)
    self:run(connection)
end

function SPSShearBoltEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteBool(streamId, self.snapped)
end

function SPSShearBoltEvent:run(connection)
    if self.object ~= nil and g_slurryPipeManager ~= nil then
        if SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil then
            SPSShearBolt.dbg("event received: snapped=" .. tostring(self.snapped))
        end
        g_slurryPipeManager:applyShearBoltState(self.object, self.snapped)
        -- Relay from a client to the rest via the server.
        if not connection:getIsServer() then
            g_server:broadcastEvent(SPSShearBoltEvent.new(self.object, self.snapped), nil, connection, self.object)
        end
    end
end

function SPSShearBoltEvent.sendEvent(object, snapped, noEventSend)
    if noEventSend == nil or not noEventSend then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSShearBoltEvent.new(object, snapped), nil, nil, object)
        else
            g_client:getServerConnection():sendEvent(SPSShearBoltEvent.new(object, snapped))
        end
    end
end