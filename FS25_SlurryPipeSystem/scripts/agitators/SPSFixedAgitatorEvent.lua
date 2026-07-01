-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.0
--
-- SPSFixedAgitatorEvent.lua
-- ---------------------------------------------------------------------------
-- Syncs fixed-agitator state.
--   reqType 0 = connect/disconnect request (client -> server)
--   reqType 1 = PTO engage/disengage request (client -> server)
--   reqType 2 = authoritative state broadcast (server -> clients):
--               {placeable, vehicle, running, engaged}
-- The server applies requests via SPSFixedAgitator and broadcasts the result.
-- ---------------------------------------------------------------------------

SPSFixedAgitatorEvent = {}
local SPSFixedAgitatorEvent_mt = Class(SPSFixedAgitatorEvent, Event)
InitEventClass(SPSFixedAgitatorEvent, "SPSFixedAgitatorEvent")

SPSFixedAgitatorEvent.REQ_CONNECT = 0
SPSFixedAgitatorEvent.REQ_ENGAGE  = 1
SPSFixedAgitatorEvent.STATE       = 2

function SPSFixedAgitatorEvent.emptyNew()
    return Event.new(SPSFixedAgitatorEvent_mt)
end

function SPSFixedAgitatorEvent.new(reqType, placeable, vehicle, flag, running, engaged)
    local self     = SPSFixedAgitatorEvent.emptyNew()
    self.reqType   = reqType
    self.placeable = placeable
    self.vehicle   = vehicle
    self.flag      = flag == true       -- connect (REQ_CONNECT) or engage (REQ_ENGAGE)
    self.running   = running == true
    self.engaged   = engaged == true
    return self
end

function SPSFixedAgitatorEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.reqType, 2)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    local hasVehicle = self.vehicle ~= nil
    streamWriteBool(streamId, hasVehicle)
    if hasVehicle then
        NetworkUtil.writeNodeObject(streamId, self.vehicle)
    end
    streamWriteBool(streamId, self.flag)
    streamWriteBool(streamId, self.running)
    streamWriteBool(streamId, self.engaged)
end

function SPSFixedAgitatorEvent:readStream(streamId, connection)
    self.reqType   = streamReadUIntN(streamId, 2)
    self.placeable = NetworkUtil.readNodeObject(streamId)
    if streamReadBool(streamId) then
        self.vehicle = NetworkUtil.readNodeObject(streamId)
    else
        self.vehicle = nil
    end
    self.flag    = streamReadBool(streamId)
    self.running = streamReadBool(streamId)
    self.engaged = streamReadBool(streamId)
    self:run(connection)
end

function SPSFixedAgitatorEvent:run(connection)
    if self.placeable == nil or not self.placeable:getIsSynchronized() then return end
    if SPSFixedAgitator == nil then return end

    if self.reqType == SPSFixedAgitatorEvent.STATE then
        if not connection:getIsServer() then
            g_server:broadcastEvent(self, false, connection, self.placeable)
        end
        SPSFixedAgitator.applyState(self.placeable, self.vehicle, self.running, self.engaged)
    elseif self.reqType == SPSFixedAgitatorEvent.REQ_CONNECT then
        if not connection:getIsServer() then
            SPSFixedAgitator.applyConnect(self.placeable, self.vehicle, self.flag)
        end
    elseif self.reqType == SPSFixedAgitatorEvent.REQ_ENGAGE then
        if not connection:getIsServer() then
            SPSFixedAgitator.applyEngage(self.placeable, self.flag)
        end
    end
end

-- Client -> server requests.
function SPSFixedAgitatorEvent.sendRequest(placeable, vehicle, connect)
    if g_client ~= nil and g_server == nil then
        g_client:getServerConnection():sendEvent(
            SPSFixedAgitatorEvent.new(SPSFixedAgitatorEvent.REQ_CONNECT, placeable, vehicle, connect, false, false))
    end
end

function SPSFixedAgitatorEvent.sendEngageRequest(placeable, engaged)
    if g_client ~= nil and g_server == nil then
        g_client:getServerConnection():sendEvent(
            SPSFixedAgitatorEvent.new(SPSFixedAgitatorEvent.REQ_ENGAGE, placeable, nil, engaged, false, false))
    end
end

-- Server -> all clients: authoritative state.
function SPSFixedAgitatorEvent.sendState(placeable, vehicle, running, engaged)
    if g_server ~= nil then
        g_server:broadcastEvent(
            SPSFixedAgitatorEvent.new(SPSFixedAgitatorEvent.STATE, placeable, vehicle, vehicle ~= nil, running, engaged),
            nil, nil, placeable)
    end
end