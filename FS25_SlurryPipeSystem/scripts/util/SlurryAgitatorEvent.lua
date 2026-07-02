-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4

-- SlurryAgitatorEvent.lua

SlurryAgitatorEvent = {}
local SlurryAgitatorEvent_mt = Class(SlurryAgitatorEvent, Event)
InitEventClass(SlurryAgitatorEvent, "SlurryAgitatorEvent")

function SlurryAgitatorEvent.emptyNew()
    local self = Event.new(SlurryAgitatorEvent_mt)
    return self
end

function SlurryAgitatorEvent.new(vehicle, isRunning)
    local self      = SlurryAgitatorEvent.emptyNew()
    self.vehicle    = vehicle
    self.isRunning  = isRunning
    return self
end

function SlurryAgitatorEvent:readStream(streamId, connection)
    self.vehicle   = NetworkUtil.readNodeObject(streamId)
    self.isRunning = streamReadBool(streamId)
    self:run(connection)
end

function SlurryAgitatorEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.isRunning)
end

function SlurryAgitatorEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle)
    end
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() then
        local vEntry = g_slurryPipeManager ~= nil and g_slurryPipeManager:getVehicleEntry(self.vehicle) or nil
        if vEntry ~= nil then
            vEntry.agitatorIsActive = self.isRunning
        end
    end
end

function SlurryAgitatorEvent.sendEvent(vehicle, isRunning, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryAgitatorEvent.new(vehicle, isRunning), nil, nil, vehicle)
            return
        end
        g_client:getServerConnection():sendEvent(SlurryAgitatorEvent.new(vehicle, isRunning))
    end
end