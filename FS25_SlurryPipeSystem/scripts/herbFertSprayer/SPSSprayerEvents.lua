-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.0

-- SPSSprayerEvents.lua
-- FS25_SlurryPipeSystem

-- [SPS] Per-file debug toggle. Set true to enable [SPS SPR EVT] trace logging.
local DEBUG = false
local function log(fmt, ...)
    if not DEBUG then return end
    if select("#", ...) > 0 then
        print("[SPS SPR EVT] " .. string.format(fmt, ...))
    else
        print("[SPS SPR EVT] " .. tostring(fmt))
    end
end

-- ---------------------------------------------------------------------------
-- SPSSprayerPumpStateEvent
-- Syncs sprayer pump on/off state
-- ---------------------------------------------------------------------------
SPSSprayerPumpStateEvent = {}
SPSSprayerPumpStateEvent_mt = Class(SPSSprayerPumpStateEvent, Event)
InitEventClass(SPSSprayerPumpStateEvent, "SPSSprayerPumpStateEvent")

function SPSSprayerPumpStateEvent.emptyNew()
    local self = Event.new(SPSSprayerPumpStateEvent_mt)
    return self
end

function SPSSprayerPumpStateEvent.new(object, pumpOn)
    local self = SPSSprayerPumpStateEvent.emptyNew()
    self.object = object
    self.pumpOn = pumpOn
    return self
end

function SPSSprayerPumpStateEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.pumpOn = streamReadBool(streamId)
    self:run(connection)
end

function SPSSprayerPumpStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteBool(streamId, self.pumpOn)
end

function SPSSprayerPumpStateEvent:run(connection)
    log("PumpStateEvent:run pumpOn=%s obj=%s", tostring(self.pumpOn), tostring(self.object and self.object.configFileName))
    if self.object ~= nil and g_slurryPipeManager ~= nil then
        local state = g_slurryPipeManager:getSprayerObjectState(self.object)
        if state ~= nil then
            state.pumpRunning = self.pumpOn
            if not connection:getIsServer() then
                g_server:broadcastEvent(SPSSprayerPumpStateEvent.new(self.object, self.pumpOn), nil, connection, self.object)
            end
        end
    end
end

function SPSSprayerPumpStateEvent.sendEvent(object, pumpOn, noEventSend)
    if noEventSend == nil or not noEventSend then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSSprayerPumpStateEvent.new(object, pumpOn), nil, nil, object)
        else
            g_client:getServerConnection():sendEvent(SPSSprayerPumpStateEvent.new(object, pumpOn))
        end
    end
end

-- ---------------------------------------------------------------------------
-- SPSSprayerValveStateEvent
-- Syncs sprayer valve open/close state
-- ---------------------------------------------------------------------------
SPSSprayerValveStateEvent = {}
SPSSprayerValveStateEvent_mt = Class(SPSSprayerValveStateEvent, Event)
InitEventClass(SPSSprayerValveStateEvent, "SPSSprayerValveStateEvent")

function SPSSprayerValveStateEvent.emptyNew()
    local self = Event.new(SPSSprayerValveStateEvent_mt)
    return self
end

function SPSSprayerValveStateEvent.new(object, valveOpen)
    local self = SPSSprayerValveStateEvent.emptyNew()
    self.object    = object
    self.valveOpen = valveOpen
    return self
end

function SPSSprayerValveStateEvent:readStream(streamId, connection)
    self.object    = NetworkUtil.readNodeObject(streamId)
    self.valveOpen = streamReadBool(streamId)
    self:run(connection)
end

function SPSSprayerValveStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteBool(streamId, self.valveOpen)
end

function SPSSprayerValveStateEvent:run(connection)
    log("ValveStateEvent:run valveOpen=%s obj=%s", tostring(self.valveOpen), tostring(self.object and self.object.configFileName))
    if self.object ~= nil and g_slurryPipeManager ~= nil then
        local state = g_slurryPipeManager:getSprayerObjectState(self.object)
        if state ~= nil then
            state.valveOpen = self.valveOpen
            -- Also mirror onto couplings on remote clients
            local vEntry = g_slurryPipeManager:getSprayerVehicleEntry(self.object)
            if vEntry ~= nil then
                for _, c in ipairs(vEntry.couplings) do
                    if c.isConnected then
                        c.valveOpen = self.valveOpen
                        if c.connectedPartnerCoupling ~= nil then
                            c.connectedPartnerCoupling.valveOpen = self.valveOpen
                        end
                    end
                end
            end
            if not connection:getIsServer() then
                g_server:broadcastEvent(SPSSprayerValveStateEvent.new(self.object, self.valveOpen), nil, connection, self.object)
            end
        end
    end
end

function SPSSprayerValveStateEvent.sendEvent(object, valveOpen, noEventSend)
    if noEventSend == nil or not noEventSend then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSSprayerValveStateEvent.new(object, valveOpen), nil, nil, object)
        else
            g_client:getServerConnection():sendEvent(SPSSprayerValveStateEvent.new(object, valveOpen))
        end
    end
end

-- ---------------------------------------------------------------------------
-- SPSSprayerDirectionEvent
-- Syncs sprayer flow direction
-- ---------------------------------------------------------------------------
SPSSprayerDirectionEvent = {}
SPSSprayerDirectionEvent_mt = Class(SPSSprayerDirectionEvent, Event)
InitEventClass(SPSSprayerDirectionEvent, "SPSSprayerDirectionEvent")

function SPSSprayerDirectionEvent.emptyNew()
    local self = Event.new(SPSSprayerDirectionEvent_mt)
    return self
end

function SPSSprayerDirectionEvent.new(object, direction)
    local self = SPSSprayerDirectionEvent.emptyNew()
    self.object    = object
    self.direction = direction
    return self
end

function SPSSprayerDirectionEvent:readStream(streamId, connection)
    self.object    = NetworkUtil.readNodeObject(streamId)
    self.direction = streamReadInt8(streamId)
    self:run(connection)
end

function SPSSprayerDirectionEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteInt8(streamId, self.direction)
end

function SPSSprayerDirectionEvent:run(connection)
    log("DirectionEvent:run direction=%s obj=%s", tostring(self.direction), tostring(self.object and self.object.configFileName))
    if self.object ~= nil and g_slurryPipeManager ~= nil then
        local state = g_slurryPipeManager:getSprayerObjectState(self.object)
        if state ~= nil then
            state.direction = self.direction
            if not connection:getIsServer() then
                g_server:broadcastEvent(SPSSprayerDirectionEvent.new(self.object, self.direction), nil, connection, self.object)
            end
        end
    end
end

function SPSSprayerDirectionEvent.sendEvent(object, direction, noEventSend)
    if noEventSend == nil or not noEventSend then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSSprayerDirectionEvent.new(object, direction), nil, nil, object)
        else
            g_client:getServerConnection():sendEvent(SPSSprayerDirectionEvent.new(object, direction))
        end
    end
end

-- ---------------------------------------------------------------------------
-- SPSSprayerConnectEvent
-- Syncs sprayer pipe connection between two couplings
-- ---------------------------------------------------------------------------
SPSSprayerConnectEvent = {}
SPSSprayerConnectEvent_mt = Class(SPSSprayerConnectEvent, Event)
InitEventClass(SPSSprayerConnectEvent, "SPSSprayerConnectEvent")

function SPSSprayerConnectEvent.emptyNew()
    local self = Event.new(SPSSprayerConnectEvent_mt)
    return self
end

function SPSSprayerConnectEvent.new(object, couplingId, targetObject, targetCouplingId)
    local self = SPSSprayerConnectEvent.emptyNew()
    self.object          = object
    self.couplingId      = couplingId
    self.targetObject    = targetObject
    self.targetCouplingId = targetCouplingId
    return self
end

function SPSSprayerConnectEvent:readStream(streamId, connection)
    self.object           = NetworkUtil.readNodeObject(streamId)
    self.couplingId       = streamReadUIntN(streamId, 8)
    self.targetObject     = NetworkUtil.readNodeObject(streamId)
    self.targetCouplingId = streamReadUIntN(streamId, 8)
    self:run(connection)
end

function SPSSprayerConnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUIntN(streamId, self.couplingId, 8)
    NetworkUtil.writeNodeObject(streamId, self.targetObject)
    streamWriteUIntN(streamId, self.targetCouplingId, 8)
end

function SPSSprayerConnectEvent:run(connection)
    log("ConnectEvent:run couplingId=%s targetCouplingId=%s", tostring(self.couplingId), tostring(self.targetCouplingId))
    if g_slurryPipeManager ~= nil then
        -- applySprayerConnectById handles targetCouplingId==0 (client→server) by
        -- calling findOverlappingSprayerCoupler to locate the other side.
        g_slurryPipeManager:applySprayerConnectById(
            self.object, self.couplingId,
            self.targetObject, self.targetCouplingId
        )
        if not connection:getIsServer() then
            -- Re-broadcast to all clients INCLUDING the originator (ignoreConnection = nil).
            -- The sender did not apply locally; it resolves the partner via
            -- findOverlappingSprayerCoupler on receipt, same as every other client.
            g_server:broadcastEvent(
                SPSSprayerConnectEvent.new(self.object, self.couplingId, self.targetObject, self.targetCouplingId),
                nil, nil, self.object
            )
        end
    end
end

function SPSSprayerConnectEvent.sendEvent(object, couplingId, targetObject, targetCouplingId)
    if g_server ~= nil then
        g_server:broadcastEvent(
            SPSSprayerConnectEvent.new(object, couplingId, targetObject, targetCouplingId),
            nil, nil, object
        )
    else
        g_client:getServerConnection():sendEvent(
            SPSSprayerConnectEvent.new(object, couplingId, targetObject, targetCouplingId)
        )
    end
end

-- ---------------------------------------------------------------------------
-- SPSSprayerDisconnectEvent
-- Syncs sprayer pipe disconnection
-- ---------------------------------------------------------------------------
SPSSprayerDisconnectEvent = {}
SPSSprayerDisconnectEvent_mt = Class(SPSSprayerDisconnectEvent, Event)
InitEventClass(SPSSprayerDisconnectEvent, "SPSSprayerDisconnectEvent")

function SPSSprayerDisconnectEvent.emptyNew()
    local self = Event.new(SPSSprayerDisconnectEvent_mt)
    return self
end

function SPSSprayerDisconnectEvent.new(object, couplingId)
    local self = SPSSprayerDisconnectEvent.emptyNew()
    self.object     = object
    self.couplingId = couplingId
    return self
end

function SPSSprayerDisconnectEvent:readStream(streamId, connection)
    self.object     = NetworkUtil.readNodeObject(streamId)
    self.couplingId = streamReadUIntN(streamId, 8)
    self:run(connection)
end

function SPSSprayerDisconnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteUIntN(streamId, self.couplingId, 8)
end

function SPSSprayerDisconnectEvent:run(connection)
    log("DisconnectEvent:run couplingId=%s", tostring(self.couplingId))
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:applySprayerDisconnect(self.object, self.couplingId, nil)
        if not connection:getIsServer() then
            -- Include the originator so it removes the sprayer pipe locally.
            g_server:broadcastEvent(
                SPSSprayerDisconnectEvent.new(self.object, self.couplingId),
                nil, nil, self.object
            )
        end
    end
end

function SPSSprayerDisconnectEvent.sendEvent(object, couplingId)
    if g_server ~= nil then
        g_server:broadcastEvent(SPSSprayerDisconnectEvent.new(object, couplingId), nil, nil, object)
    else
        g_client:getServerConnection():sendEvent(SPSSprayerDisconnectEvent.new(object, couplingId))
    end
end