-- SPSEvents.lua
-- FS25_SlurryPipeSystem

-- ---------------------------------------------------------------------------
-- SlurryFlowStateEvent
-- ---------------------------------------------------------------------------
SlurryFlowStateEvent = {}
local SlurryFlowStateEvent_mt = Class(SlurryFlowStateEvent, Event)
InitEventClass(SlurryFlowStateEvent, "SlurryFlowStateEvent")

function SlurryFlowStateEvent.emptyNew()
    local self = Event.new(SlurryFlowStateEvent_mt)
    return self
end

function SlurryFlowStateEvent.new(vehicle, isFlowOpen)
    local self = SlurryFlowStateEvent.emptyNew()
    self.vehicle    = vehicle
    self.isFlowOpen = isFlowOpen
    return self
end

function SlurryFlowStateEvent:readStream(streamId, connection)
    self.vehicle    = NetworkUtil.readNodeObject(streamId)
    self.isFlowOpen = streamReadBool(streamId)
    self:run(connection)
end

function SlurryFlowStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.isFlowOpen)
end

function SlurryFlowStateEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle)
    end
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() then
        if g_slurryPipeManager ~= nil then
            local state = g_slurryPipeManager:getVehicleState(self.vehicle)
            if state ~= nil then
                state.valveOpen = self.isFlowOpen
                g_slurryPipeManager:updateActionEventTexts(self.vehicle)
            end
        end
    end
end

function SlurryFlowStateEvent.sendEvent(vehicle, isFlowOpen, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryFlowStateEvent.new(vehicle, isFlowOpen), nil, nil, vehicle)
            return
        end
        g_client:getServerConnection():sendEvent(SlurryFlowStateEvent.new(vehicle, isFlowOpen))
    end
end

-- ---------------------------------------------------------------------------
-- SlurryFlowDirectionEvent
-- ---------------------------------------------------------------------------
SlurryFlowDirectionEvent = {}
local SlurryFlowDirectionEvent_mt = Class(SlurryFlowDirectionEvent, Event)
InitEventClass(SlurryFlowDirectionEvent, "SlurryFlowDirectionEvent")

function SlurryFlowDirectionEvent.emptyNew()
    local self = Event.new(SlurryFlowDirectionEvent_mt)
    return self
end

function SlurryFlowDirectionEvent.new(vehicle, direction)
    local self = SlurryFlowDirectionEvent.emptyNew()
    self.vehicle   = vehicle
    self.direction = direction
    return self
end

function SlurryFlowDirectionEvent:readStream(streamId, connection)
    self.vehicle   = NetworkUtil.readNodeObject(streamId)
    self.direction = streamReadUIntN(streamId, 1)
    self:run(connection)
end

function SlurryFlowDirectionEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUIntN(streamId, self.direction, 1)
end

function SlurryFlowDirectionEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle)
    end
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() then
        if g_slurryPipeManager ~= nil then
            local state = g_slurryPipeManager:getVehicleState(self.vehicle)
            if state ~= nil then
                state.direction = self.direction
                g_slurryPipeManager:updateActionEventTexts(self.vehicle)
            end
        end
    end
end

function SlurryFlowDirectionEvent.sendEvent(vehicle, direction, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryFlowDirectionEvent.new(vehicle, direction), nil, nil, vehicle)
            return
        end
        g_client:getServerConnection():sendEvent(SlurryFlowDirectionEvent.new(vehicle, direction))
    end
end

-- ---------------------------------------------------------------------------
-- SlurryPipeConnectEvent
-- Syncs pipe connection to all clients so they create the visual.
-- targetType: 0 = vehicle, 1 = placeable
-- ---------------------------------------------------------------------------
SlurryPipeConnectEvent = {}
local SlurryPipeConnectEvent_mt = Class(SlurryPipeConnectEvent, Event)
InitEventClass(SlurryPipeConnectEvent, "SlurryPipeConnectEvent")

SlurryPipeConnectEvent.TARGET_TYPE_VEHICLE   = 0
SlurryPipeConnectEvent.TARGET_TYPE_PLACEABLE = 1

function SlurryPipeConnectEvent.emptyNew()
    local self = Event.new(SlurryPipeConnectEvent_mt)
    return self
end

function SlurryPipeConnectEvent.new(vehicleA, targetObject, targetType, couplingIdA, couplingIdB)
    local self = SlurryPipeConnectEvent.emptyNew()
    self.vehicleA     = vehicleA
    self.targetObject = targetObject
    self.targetType   = targetType
    self.couplingIdA  = couplingIdA
    self.couplingIdB  = couplingIdB
    return self
end

function SlurryPipeConnectEvent:readStream(streamId, connection)
    self.vehicleA     = NetworkUtil.readNodeObject(streamId)
    self.targetObject = NetworkUtil.readNodeObject(streamId)
    self.targetType   = streamReadUIntN(streamId, 1)
    self.couplingIdA  = streamReadUIntN(streamId, 4)
    self.couplingIdB  = streamReadUIntN(streamId, 4)
    self:run(connection)
end

function SlurryPipeConnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicleA)
    NetworkUtil.writeNodeObject(streamId, self.targetObject)
    streamWriteUIntN(streamId, self.targetType, 1)
    streamWriteUIntN(streamId, self.couplingIdA, 4)
    streamWriteUIntN(streamId, self.couplingIdB, 4)
end

function SlurryPipeConnectEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicleA)
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:applyConnect(self.vehicleA, self.targetObject, self.targetType, self.couplingIdA, self.couplingIdB)
    end
end

function SlurryPipeConnectEvent.sendEvent(vehicleA, targetObject, targetType, couplingIdA, couplingIdB, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryPipeConnectEvent.new(vehicleA, targetObject, targetType, couplingIdA, couplingIdB), nil, nil, vehicleA)
            return
        end
        g_client:getServerConnection():sendEvent(SlurryPipeConnectEvent.new(vehicleA, targetObject, targetType, couplingIdA, couplingIdB))
    end
end

-- ---------------------------------------------------------------------------
-- SlurryPipeDisconnectEvent
-- ---------------------------------------------------------------------------
SlurryPipeDisconnectEvent = {}
local SlurryPipeDisconnectEvent_mt = Class(SlurryPipeDisconnectEvent, Event)
InitEventClass(SlurryPipeDisconnectEvent, "SlurryPipeDisconnectEvent")

function SlurryPipeDisconnectEvent.emptyNew()
    local self = Event.new(SlurryPipeDisconnectEvent_mt)
    return self
end

function SlurryPipeDisconnectEvent.new(vehicleA, couplingIdA)
    local self = SlurryPipeDisconnectEvent.emptyNew()
    self.vehicleA    = vehicleA
    self.couplingIdA = couplingIdA
    return self
end

function SlurryPipeDisconnectEvent:readStream(streamId, connection)
    self.vehicleA    = NetworkUtil.readNodeObject(streamId)
    self.couplingIdA = streamReadUIntN(streamId, 4)
    self:run(connection)
end

function SlurryPipeDisconnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicleA)
    streamWriteUIntN(streamId, self.couplingIdA, 4)
end

function SlurryPipeDisconnectEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicleA)
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:applyDisconnect(self.vehicleA, self.couplingIdA)
    end
end

function SlurryPipeDisconnectEvent.sendEvent(vehicleA, couplingIdA, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryPipeDisconnectEvent.new(vehicleA, couplingIdA), nil, nil, vehicleA)
            return
        end
        g_client:getServerConnection():sendEvent(SlurryPipeDisconnectEvent.new(vehicleA, couplingIdA))
    end
end

-- ---------------------------------------------------------------------------
-- SlurryValveStateEvent
-- Syncs manual coupling valve open/close to all clients.
-- ---------------------------------------------------------------------------
SlurryValveStateEvent = {}
local SlurryValveStateEvent_mt = Class(SlurryValveStateEvent, Event)
InitEventClass(SlurryValveStateEvent, "SlurryValveStateEvent")

function SlurryValveStateEvent.emptyNew()
    local self = Event.new(SlurryValveStateEvent_mt)
    return self
end

function SlurryValveStateEvent.new(vehicleA, couplingId, isOpen)
    local self = SlurryValveStateEvent.emptyNew()
    self.vehicleA   = vehicleA
    self.couplingId = couplingId
    self.isOpen     = isOpen
    return self
end

function SlurryValveStateEvent:readStream(streamId, connection)
    self.vehicleA   = NetworkUtil.readNodeObject(streamId)
    self.couplingId = streamReadUIntN(streamId, 4)
    self.isOpen     = streamReadBool(streamId)
    self:run(connection)
end

function SlurryValveStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicleA)
    streamWriteUIntN(streamId, self.couplingId, 4)
    streamWriteBool(streamId, self.isOpen)
end

function SlurryValveStateEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicleA)
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:applyValveState(self.vehicleA, self.couplingId, self.isOpen)
    end
end

function SlurryValveStateEvent.sendEvent(vehicleA, couplingId, isOpen, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryValveStateEvent.new(vehicleA, couplingId, isOpen), nil, nil, vehicleA)
            return
        end
        g_client:getServerConnection():sendEvent(SlurryValveStateEvent.new(vehicleA, couplingId, isOpen))
    end
end
-- ---------------------------------------------------------------------------
-- SPSCouplingDeployEvent
-- Syncs deployable coupling deploy/undeploy to all clients.
-- ---------------------------------------------------------------------------
SPSCouplingDeployEvent = {}
local SPSCouplingDeployEvent_mt = Class(SPSCouplingDeployEvent, Event)
InitEventClass(SPSCouplingDeployEvent, "SPSCouplingDeployEvent")

function SPSCouplingDeployEvent.emptyNew()
    local self = Event.new(SPSCouplingDeployEvent_mt)
    return self
end

function SPSCouplingDeployEvent.new(placeable, couplingId, isDeployed)
    local self = SPSCouplingDeployEvent.emptyNew()
    self.placeable  = placeable
    self.couplingId = couplingId
    self.isDeployed = isDeployed
    return self
end

function SPSCouplingDeployEvent:readStream(streamId, connection)
    self.placeable  = NetworkUtil.readNodeObject(streamId)
    self.couplingId = streamReadUIntN(streamId, 4)
    self.isDeployed = streamReadBool(streamId)
    self:run(connection)
end

function SPSCouplingDeployEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteUIntN(streamId, self.couplingId, 4)
    streamWriteBool(streamId, self.isDeployed)
end

function SPSCouplingDeployEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.placeable)
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:applyCouplingDeployState(self.placeable, self.couplingId, self.isDeployed)
    end
end

function SPSCouplingDeployEvent.sendEvent(placeable, couplingId, isDeployed, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSCouplingDeployEvent.new(placeable, couplingId, isDeployed), nil, nil, placeable)
            return
        end
        g_client:getServerConnection():sendEvent(SPSCouplingDeployEvent.new(placeable, couplingId, isDeployed))
    end
end