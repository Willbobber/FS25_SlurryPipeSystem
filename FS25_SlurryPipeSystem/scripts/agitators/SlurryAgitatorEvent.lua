-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.8

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
        g_server:broadcastEvent(self, false, connection, self.vehicle, nil, nil, true)
    end
    -- [SPS MP 1.0.1.8] Apply now, or (client) defer until the vehicle registers.
    if self.vehicle ~= nil and g_slurryPipeManager ~= nil then
        local isRunning = self.isRunning
        g_slurryPipeManager:applyOrDeferVehicleState(self.vehicle, "AgitatorEvent", function(entry, state)
            entry.agitatorIsActive = isRunning
        end)
    end
end

function SlurryAgitatorEvent.sendEvent(vehicle, isRunning, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryAgitatorEvent.new(vehicle, isRunning), nil, nil, vehicle, nil, nil, true)
            return
        end
        g_client:getServerConnection():sendEvent(SlurryAgitatorEvent.new(vehicle, isRunning))
    end
end