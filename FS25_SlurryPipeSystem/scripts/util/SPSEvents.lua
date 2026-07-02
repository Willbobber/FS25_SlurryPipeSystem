-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.4

-- SPSEvents.lua
-- FS25_SlurryPipeSystem


-- Safe client send helper. During savegame shutdown/leave-game, g_client or
-- its server connection can already be nil while late SPS cleanup code still
-- asks an event to send. In that state there is nobody left to send to, so
-- silently skip instead of crashing on g_client:getServerConnection().
local function spsSendEventToServer(event)
    if g_client ~= nil and g_client.getServerConnection ~= nil then
        local connection = g_client:getServerConnection()
        if connection ~= nil then
            connection:sendEvent(event)
            return true
        end
    end
    return false
end

-- [SPS MP RX] Unconditional receive-path logging helper (NOT gated by DEBUG).
-- Temporary instrumentation to trace why the join-dump connect/valve/pump
-- events do not take effect on the guest. Prints a safe object id or "nil".
local function spsRxId(obj)
    if obj == nil then return "nil" end
    local ok, id = pcall(NetworkUtil.getObjectId, obj)
    if ok and id ~= nil then return tostring(id) end
    return "noId"
end

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
    print(string.format("[SPS MP RX] FlowStateEvent:run isServer=%s vehicle=%s isFlowOpen=%s synced=%s",
        tostring(connection:getIsServer()), spsRxId(self.vehicle), tostring(self.isFlowOpen),
        tostring(self.vehicle ~= nil and self.vehicle:getIsSynchronized())))
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
        spsSendEventToServer(SlurryFlowStateEvent.new(vehicle, isFlowOpen))
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
    print(string.format("[SPS MP RX] FlowDirectionEvent:run isServer=%s vehicle=%s direction=%s synced=%s",
        tostring(connection:getIsServer()), spsRxId(self.vehicle), tostring(self.direction),
        tostring(self.vehicle ~= nil and self.vehicle:getIsSynchronized())))
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle)
    end
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() then
        if g_slurryPipeManager ~= nil then
            local state = g_slurryPipeManager:getVehicleState(self.vehicle)
            if state ~= nil then
                g_slurryPipeManager:applyDirectionAndPurge(self.vehicle, self.direction)
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
        spsSendEventToServer(SlurryFlowDirectionEvent.new(vehicle, direction))
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
    print(string.format("[SPS MP RX] ConnectEvent:readStream vehicleA=%s targetObject=%s targetType=%s idA=%s idB=%s isServer=%s",
        spsRxId(self.vehicleA), spsRxId(self.targetObject), tostring(self.targetType),
        tostring(self.couplingIdA), tostring(self.couplingIdB), tostring(connection:getIsServer())))
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
    print(string.format("[SPS MP RX] ConnectEvent:run isServer=%s vehicleA=%s target=%s",
        tostring(connection:getIsServer()), spsRxId(self.vehicleA), spsRxId(self.targetObject)))
    if not connection:getIsServer() then
        -- Include the originating client (ignoreConnection = nil): the partner coupling
        -- is resolved server-side, so the sender cannot apply optimistically and must
        -- receive the echo to render the pipe locally.
        g_server:broadcastEvent(self, false, nil, self.vehicleA)
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:applyConnect(self.vehicleA, self.targetObject, self.targetType, self.couplingIdA, self.couplingIdB)
    else
        print("[SPS MP RX] ConnectEvent:run g_slurryPipeManager is nil")
    end
end

function SlurryPipeConnectEvent.sendEvent(vehicleA, targetObject, targetType, couplingIdA, couplingIdB, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryPipeConnectEvent.new(vehicleA, targetObject, targetType, couplingIdA, couplingIdB), nil, nil, vehicleA)
            return
        end
        spsSendEventToServer(SlurryPipeConnectEvent.new(vehicleA, targetObject, targetType, couplingIdA, couplingIdB))
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
        -- Include the originating client so it removes the pipe locally.
        g_server:broadcastEvent(self, false, nil, self.vehicleA)
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:applyDisconnect(self.vehicleA, self.couplingIdA)
    end
end

function SlurryPipeDisconnectEvent.sendEvent(vehicleA, couplingIdA, noEventSend)
    if noEventSend == true then return end

    if g_server ~= nil then
        g_server:broadcastEvent(SlurryPipeDisconnectEvent.new(vehicleA, couplingIdA), nil, nil, vehicleA)
        return
    end

    -- During quit/delete the client connection can already be nil.
    if g_client ~= nil and g_client.getServerConnection ~= nil then
        local connection = g_client:getServerConnection()
        if connection ~= nil then
            connection:sendEvent(SlurryPipeDisconnectEvent.new(vehicleA, couplingIdA))
        end
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

-- Accepts either:
--   (vehicleA, couplingObjOrId, isOpen)        — preferred, object form
--   (vehicleA, couplingId, isOpen)             — legacy id form (still works)
-- When given a coupling object, the event also transmits the placeable owner
-- reference (if any) so the receiving machine can scope its lookup to that
-- placeable's storeCouplings — avoiding id collisions across multiple
-- placeables that share coupling ids.
function SlurryValveStateEvent.new(vehicleA, couplingArg, isOpen)
    local self = SlurryValveStateEvent.emptyNew()
    self.vehicleA   = vehicleA
    self.isOpen     = isOpen
    if type(couplingArg) == "table" then
        self.couplingId        = couplingArg.id
        self.placeableOwner    = couplingArg.placeable   -- nil for vehicle/chain couplings
    else
        self.couplingId        = couplingArg
        self.placeableOwner    = nil
    end
    return self
end

function SlurryValveStateEvent:readStream(streamId, connection)
    self.vehicleA       = NetworkUtil.readNodeObject(streamId)
    self.couplingId     = streamReadIntN(streamId, 5)   -- signed: chain start = -2
    self.isOpen         = streamReadBool(streamId)
    local hasOwner      = streamReadBool(streamId)
    if hasOwner then
        self.placeableOwner = NetworkUtil.readNodeObject(streamId)
    else
        self.placeableOwner = nil
    end
    print(string.format("[SPS MP RX] ValveEvent:readStream vehicleA=%s couplingId=%s isOpen=%s placeableOwner=%s isServer=%s",
        spsRxId(self.vehicleA), tostring(self.couplingId), tostring(self.isOpen),
        spsRxId(self.placeableOwner), tostring(connection:getIsServer())))
    self:run(connection)
end

function SlurryValveStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicleA)
    streamWriteIntN(streamId, self.couplingId or 0, 5)
    streamWriteBool(streamId, self.isOpen)
    streamWriteBool(streamId, self.placeableOwner ~= nil)
    if self.placeableOwner ~= nil then
        NetworkUtil.writeNodeObject(streamId, self.placeableOwner)
    end
end

function SlurryValveStateEvent:run(connection)
    if not connection:getIsServer() then
        -- Include the originating client so it applies the coupling valve state locally.
        g_server:broadcastEvent(self, false, nil, self.vehicleA)
    end
    if g_slurryPipeManager ~= nil then
        -- If a placeable owner was transmitted, narrow the lookup to that
        -- specific placeable's couplings before falling back to global search.
        local couplingObj = nil
        if self.placeableOwner ~= nil then
            for _, pEntry in ipairs(g_slurryPipeManager.registeredPlaceables) do
                if pEntry.placeable == self.placeableOwner and pEntry.storeCouplings ~= nil then
                    for _, sc in ipairs(pEntry.storeCouplings) do
                        if sc.id == self.couplingId then couplingObj = sc break end
                    end
                    break
                end
            end
        end
        g_slurryPipeManager:applyValveState(self.vehicleA, self.couplingId, self.isOpen, couplingObj)
        print(string.format("[SPS MP RX] ValveEvent:run applied couplingId=%s isOpen=%s couplingObjResolved=%s",
            tostring(self.couplingId), tostring(self.isOpen), tostring(couplingObj ~= nil)))
    end
end

function SlurryValveStateEvent.sendEvent(vehicleA, couplingArg, isOpen, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryValveStateEvent.new(vehicleA, couplingArg, isOpen), nil, nil, vehicleA)
            return
        end
        spsSendEventToServer(SlurryValveStateEvent.new(vehicleA, couplingArg, isOpen))
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
        spsSendEventToServer(SPSCouplingDeployEvent.new(placeable, couplingId, isDeployed))
    end
end

-- ---------------------------------------------------------------------------
-- SPSSelfPumpStateEvent
-- Syncs selfPowered vehicle pump on/off state to all clients.
-- ---------------------------------------------------------------------------
SPSSelfPumpStateEvent = {}
local SPSSelfPumpStateEvent_mt = Class(SPSSelfPumpStateEvent, Event)
InitEventClass(SPSSelfPumpStateEvent, "SPSSelfPumpStateEvent")

function SPSSelfPumpStateEvent.emptyNew()
    local self = Event.new(SPSSelfPumpStateEvent_mt)
    return self
end

function SPSSelfPumpStateEvent.new(vehicle, pumpRunning)
    local self = SPSSelfPumpStateEvent.emptyNew()
    self.vehicle     = vehicle
    self.pumpRunning = pumpRunning
    return self
end

function SPSSelfPumpStateEvent:readStream(streamId, connection)
    self.vehicle     = NetworkUtil.readNodeObject(streamId)
    self.pumpRunning = streamReadBool(streamId)
    self:run(connection)
end

function SPSSelfPumpStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.pumpRunning)
end

function SPSSelfPumpStateEvent:run(connection)
    print(string.format("[SPS MP RX] SelfPumpStateEvent:run isServer=%s vehicle=%s pumpRunning=%s synced=%s",
        tostring(connection:getIsServer()), spsRxId(self.vehicle), tostring(self.pumpRunning),
        tostring(self.vehicle ~= nil and self.vehicle:getIsSynchronized())))
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle)
    end
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() then
        if g_slurryPipeManager ~= nil then
            local state = g_slurryPipeManager:getVehicleState(self.vehicle)
            if state ~= nil then
                state.pumpRunning = self.pumpRunning
                g_slurryPipeManager:updateActionEventTexts(self.vehicle)
            end
        end
    end
end

function SPSSelfPumpStateEvent.sendEvent(vehicle, pumpRunning, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSSelfPumpStateEvent.new(vehicle, pumpRunning), nil, nil, vehicle)
            return
        end
        spsSendEventToServer(SPSSelfPumpStateEvent.new(vehicle, pumpRunning))
    end
end
-- ---------------------------------------------------------------------------
-- SPSPressureStateEvent
-- Server-authoritative, server -> client only. Pressure is computed solely on
-- the server (updatePressure runs only when g_server ~= nil), so clients never
-- recompute it; they just receive the current stored value here so the HUD /
-- fill-level gauge (which read getVehicleState(vehicle).pressure) reflect it.
-- Throttled by the server: only broadcast when the value moves by the log/sync
-- quantum (>= 0.1 bar), so this is roughly 1-2 events/sec per active vac tank.
-- ---------------------------------------------------------------------------
SPSPressureStateEvent = {}
local SPSPressureStateEvent_mt = Class(SPSPressureStateEvent, Event)
InitEventClass(SPSPressureStateEvent, "SPSPressureStateEvent")

function SPSPressureStateEvent.emptyNew()
    local self = Event.new(SPSPressureStateEvent_mt)
    return self
end

function SPSPressureStateEvent.new(vehicle, pressure)
    local self = SPSPressureStateEvent.emptyNew()
    self.vehicle  = vehicle
    self.pressure = pressure
    return self
end

function SPSPressureStateEvent:readStream(streamId, connection)
    self.vehicle  = NetworkUtil.readNodeObject(streamId)
    self.pressure = streamReadFloat32(streamId)
    self:run(connection)
end

function SPSPressureStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteFloat32(streamId, self.pressure or 0)
end

function SPSPressureStateEvent:run(connection)
    -- server -> client only; no rebroadcast (clients never originate pressure).
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() then
        if g_slurryPipeManager ~= nil then
            local state = g_slurryPipeManager:getVehicleState(self.vehicle)
            if state ~= nil then
                state.pressure = self.pressure
            end
        end
    end
end

function SPSPressureStateEvent.sendEvent(vehicle, pressure)
    -- Server only. Scoped to the vehicle ghost so only connections that already
    -- know the vehicle receive it.
    if g_server ~= nil then
        g_server:broadcastEvent(SPSPressureStateEvent.new(vehicle, pressure), nil, nil, vehicle)
    end
end
-- ---------------------------------------------------------------------------
-- SPSSpreaderValveEvent
-- Syncs spreader valve open/close state to all clients.
-- ---------------------------------------------------------------------------
SPSSpreaderValveEvent = {}
local SPSSpreaderValveEvent_mt = Class(SPSSpreaderValveEvent, Event)
InitEventClass(SPSSpreaderValveEvent, "SPSSpreaderValveEvent")

function SPSSpreaderValveEvent.emptyNew()
    local self = Event.new(SPSSpreaderValveEvent_mt)
    return self
end

function SPSSpreaderValveEvent.new(vehicle, isOpen)
    local self = SPSSpreaderValveEvent.emptyNew()
    self.vehicle = vehicle
    self.isOpen  = isOpen
    return self
end

function SPSSpreaderValveEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.isOpen  = streamReadBool(streamId)
    self:run(connection)
end

function SPSSpreaderValveEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.isOpen)
end

function SPSSpreaderValveEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle)
    end
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() then
        if g_slurryPipeManager ~= nil then
            local state = g_slurryPipeManager:getVehicleState(self.vehicle)
            if state ~= nil then
                state.spreaderValveOpen = self.isOpen
                g_slurryPipeManager:updateActionEventTexts(self.vehicle)
            end
        end
    end
end

function SPSSpreaderValveEvent.sendEvent(vehicle, isOpen, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSSpreaderValveEvent.new(vehicle, isOpen), nil, nil, vehicle)
            return
        end
        spsSendEventToServer(SPSSpreaderValveEvent.new(vehicle, isOpen))
    end
end

-- ===========================================================================
-- SPSChainStateEvent
-- ---------------------------------------------------------------------------
-- Full-state replication of a free-standing / laid pipe chain.
--
-- A chain's scene-graph node handles cannot be replicated across peers, but the
-- mod already serialises a chain to compact data (SPSPipeChain:getSaveData) and
-- rebuilds it deterministically (SPSPipeChain:restoreFromSaveData) — the exact
-- savegame-load path. This event reuses that: the server is authoritative and
-- broadcasts the whole chain state (keyed by a network-stable netId) on every
-- committed mutation. Each peer tears its copy down and rebuilds from the
-- payload. Works identically for anchored and free-standing chains because the
-- key is the netId, not the anchor.
--
-- Direction: server -> all clients only. Client-side mutation requests travel on
-- SPSChainRequestEvent (added in a later phase); the server applies them and
-- then emits this state event.
--
-- Wire format carries only the fields restoreFromSaveData consumes (verified:
-- per-segment rotation is recomputed from positions on rebuild, so only x/y/z +
-- colour are sent per segment).
-- ===========================================================================
SPSChainStateEvent = {}
local SPSChainStateEvent_mt = Class(SPSChainStateEvent, Event)
InitEventClass(SPSChainStateEvent, "SPSChainStateEvent")

function SPSChainStateEvent.emptyNew()
    local self = Event.new(SPSChainStateEvent_mt)
    return self
end

-- netId        : network-stable chain id (server-assigned)
-- removed      : true => peer deletes the chain and ignores payload
-- anchorObject : vehicle or placeable the chain is anchored to (nil = free-standing)
-- couplingId   : anchor coupling id on that object
-- isPlaceable  : true => anchorObject is a placeable
-- payload      : table from SlurryPipeManager:_serializeChain(chain)
function SPSChainStateEvent.new(netId, removed, anchorObject, couplingId, isPlaceable, payload)
    local self = SPSChainStateEvent.emptyNew()
    self.netId        = netId
    self.removed      = removed == true
    self.anchorObject = anchorObject
    self.couplingId   = couplingId or 0
    self.isPlaceable  = isPlaceable == true
    self.payload      = payload
    return self
end

function SPSChainStateEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.netId, 12)
    streamWriteBool(streamId, self.removed)
    if self.removed then
        return
    end

    local hasAnchor = self.anchorObject ~= nil
    streamWriteBool(streamId, hasAnchor)
    if hasAnchor then
        NetworkUtil.writeNodeObject(streamId, self.anchorObject)
        streamWriteUIntN(streamId, self.couplingId, 4)
        streamWriteBool(streamId, self.isPlaceable)
    end

    local p = self.payload or {}
    streamWriteBool(streamId, p.localStart == true)
    streamWriteFloat32(streamId, p.anchorX or 0)
    streamWriteFloat32(streamId, p.anchorY or 0)
    streamWriteFloat32(streamId, p.anchorZ or 0)

    local hasChainStart = p.chainStartX ~= nil
    streamWriteBool(streamId, hasChainStart)
    if hasChainStart then
        streamWriteFloat32(streamId, p.chainStartX or 0)
        streamWriteFloat32(streamId, p.chainStartY or 0)
        streamWriteFloat32(streamId, p.chainStartZ or 0)
        streamWriteFloat32(streamId, p.chainStartRY or 0)
    end

    streamWriteBool(streamId, p.hasDockingStation == true)
    if p.hasDockingStation == true then
        streamWriteFloat32(streamId, p.dsSaveX  or 0)
        streamWriteFloat32(streamId, p.dsSaveY  or 0)
        streamWriteFloat32(streamId, p.dsSaveZ  or 0)
        streamWriteFloat32(streamId, p.dsSaveRX or 0)
        streamWriteFloat32(streamId, p.dsSaveRY or 0)
        streamWriteFloat32(streamId, p.dsSaveRZ or 0)
    end

    local segs = p.segments or {}
    streamWriteUIntN(streamId, #segs, 8)
    for _, s in ipairs(segs) do
        streamWriteFloat32(streamId, s.x or 0)
        streamWriteFloat32(streamId, s.y or 0)
        streamWriteFloat32(streamId, s.z or 0)
        streamWriteFloat32(streamId, s.colorR or 0)
        streamWriteFloat32(streamId, s.colorG or 0)
        streamWriteFloat32(streamId, s.colorB or 0)
    end
end

function SPSChainStateEvent:readStream(streamId, connection)
    self.netId   = streamReadUIntN(streamId, 12)
    self.removed = streamReadBool(streamId)
    if not self.removed then
        local hasAnchor = streamReadBool(streamId)
        if hasAnchor then
            self.anchorObject = NetworkUtil.readNodeObject(streamId)
            self.couplingId   = streamReadUIntN(streamId, 4)
            self.isPlaceable  = streamReadBool(streamId)
        else
            self.anchorObject = nil
            self.couplingId   = 0
            self.isPlaceable  = false
        end

        local p = {}
        p.localStart = streamReadBool(streamId)
        p.anchorX    = streamReadFloat32(streamId)
        p.anchorY    = streamReadFloat32(streamId)
        p.anchorZ    = streamReadFloat32(streamId)

        local hasChainStart = streamReadBool(streamId)
        if hasChainStart then
            p.chainStartX  = streamReadFloat32(streamId)
            p.chainStartY  = streamReadFloat32(streamId)
            p.chainStartZ  = streamReadFloat32(streamId)
            p.chainStartRY = streamReadFloat32(streamId)
        end

        p.hasDockingStation = streamReadBool(streamId)
        if p.hasDockingStation then
            p.dsSaveX  = streamReadFloat32(streamId)
            p.dsSaveY  = streamReadFloat32(streamId)
            p.dsSaveZ  = streamReadFloat32(streamId)
            p.dsSaveRX = streamReadFloat32(streamId)
            p.dsSaveRY = streamReadFloat32(streamId)
            p.dsSaveRZ = streamReadFloat32(streamId)
        end

        p.segments = {}
        local n = streamReadUIntN(streamId, 8)
        for i = 1, n do
            local s = {}
            s.x      = streamReadFloat32(streamId)
            s.y      = streamReadFloat32(streamId)
            s.z      = streamReadFloat32(streamId)
            s.colorR = streamReadFloat32(streamId)
            s.colorG = streamReadFloat32(streamId)
            s.colorB = streamReadFloat32(streamId)
            p.segments[i] = s
        end
        self.payload = p
    end

    self:run(connection)
end

function SPSChainStateEvent:run(connection)
    print(string.format("[SPS MP] StateEvent.run RECV netId=%s removed=%s fromServer=%s",
        tostring(self.netId), tostring(self.removed), tostring(connection:getIsServer())))
    -- State events are authoritative and only ever travel server -> clients.
    -- If a server somehow receives one from a client, relay defensively (but do
    -- not include the sender, who is the authority for nothing here).
    if not connection:getIsServer() then
        if g_server ~= nil then
            g_server:broadcastEvent(self, false, connection, self.anchorObject)
        end
    end

    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyChainState ~= nil then
        g_slurryPipeManager:applyChainState(
            self.netId, self.removed,
            self.anchorObject, self.couplingId, self.isPlaceable,
            self.payload)
    end
end

-- Server-only broadcaster. Build via SlurryPipeManager:_broadcastChainState.
function SPSChainStateEvent.sendEvent(netId, removed, anchorObject, couplingId, isPlaceable, payload)
    if g_server == nil then
        return
    end
    g_server:broadcastEvent(
        SPSChainStateEvent.new(netId, removed, anchorObject, couplingId, isPlaceable, payload),
        nil, nil, anchorObject)
end


-- ===========================================================================
-- SPSChainRequestEvent
-- ---------------------------------------------------------------------------
-- Client -> server request to commit a chain mutation. The client cannot
-- broadcast, so it sends the resulting committed snapshot (same payload as
-- SPSChainStateEvent) to the server. The server applies it authoritatively
-- (SlurryPipeManager:applyChainRequest), assigning a netId for a brand-new
-- chain, and then broadcasts SPSChainStateEvent to every peer.
--
-- Field order mirrors SPSChainStateEvent; the two are independent channels
-- (request is client->server, state is server->clients) so each only needs
-- internal write/read consistency.
-- ===========================================================================
SPSChainRequestEvent = {}
local SPSChainRequestEvent_mt = Class(SPSChainRequestEvent, Event)
InitEventClass(SPSChainRequestEvent, "SPSChainRequestEvent")

function SPSChainRequestEvent.emptyNew()
    local self = Event.new(SPSChainRequestEvent_mt)
    return self
end

function SPSChainRequestEvent.new(netId, removed, anchorObject, couplingId, isPlaceable, payload)
    local self = SPSChainRequestEvent.emptyNew()
    self.netId        = netId or 0
    self.removed      = removed == true
    self.anchorObject = anchorObject
    self.couplingId   = couplingId or 0
    self.isPlaceable  = isPlaceable == true
    self.payload      = payload
    return self
end

function SPSChainRequestEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.netId, 12)
    streamWriteBool(streamId, self.removed)
    if self.removed then
        return
    end

    local hasAnchor = self.anchorObject ~= nil
    streamWriteBool(streamId, hasAnchor)
    if hasAnchor then
        NetworkUtil.writeNodeObject(streamId, self.anchorObject)
        streamWriteUIntN(streamId, self.couplingId, 4)
        streamWriteBool(streamId, self.isPlaceable)
    end

    local p = self.payload or {}
    streamWriteBool(streamId, p.localStart == true)
    streamWriteFloat32(streamId, p.anchorX or 0)
    streamWriteFloat32(streamId, p.anchorY or 0)
    streamWriteFloat32(streamId, p.anchorZ or 0)

    local hasChainStart = p.chainStartX ~= nil
    streamWriteBool(streamId, hasChainStart)
    if hasChainStart then
        streamWriteFloat32(streamId, p.chainStartX or 0)
        streamWriteFloat32(streamId, p.chainStartY or 0)
        streamWriteFloat32(streamId, p.chainStartZ or 0)
        streamWriteFloat32(streamId, p.chainStartRY or 0)
    end

    streamWriteBool(streamId, p.hasDockingStation == true)
    if p.hasDockingStation == true then
        streamWriteFloat32(streamId, p.dsSaveX  or 0)
        streamWriteFloat32(streamId, p.dsSaveY  or 0)
        streamWriteFloat32(streamId, p.dsSaveZ  or 0)
        streamWriteFloat32(streamId, p.dsSaveRX or 0)
        streamWriteFloat32(streamId, p.dsSaveRY or 0)
        streamWriteFloat32(streamId, p.dsSaveRZ or 0)
    end

    local segs = p.segments or {}
    streamWriteUIntN(streamId, #segs, 8)
    for _, s in ipairs(segs) do
        streamWriteFloat32(streamId, s.x or 0)
        streamWriteFloat32(streamId, s.y or 0)
        streamWriteFloat32(streamId, s.z or 0)
        streamWriteFloat32(streamId, s.colorR or 0)
        streamWriteFloat32(streamId, s.colorG or 0)
        streamWriteFloat32(streamId, s.colorB or 0)
    end
end

function SPSChainRequestEvent:readStream(streamId, connection)
    self.netId   = streamReadUIntN(streamId, 12)
    self.removed = streamReadBool(streamId)
    if not self.removed then
        local hasAnchor = streamReadBool(streamId)
        if hasAnchor then
            self.anchorObject = NetworkUtil.readNodeObject(streamId)
            self.couplingId   = streamReadUIntN(streamId, 4)
            self.isPlaceable  = streamReadBool(streamId)
        else
            self.anchorObject = nil
            self.couplingId   = 0
            self.isPlaceable  = false
        end

        local p = {}
        p.localStart = streamReadBool(streamId)
        p.anchorX    = streamReadFloat32(streamId)
        p.anchorY    = streamReadFloat32(streamId)
        p.anchorZ    = streamReadFloat32(streamId)

        local hasChainStart = streamReadBool(streamId)
        if hasChainStart then
            p.chainStartX  = streamReadFloat32(streamId)
            p.chainStartY  = streamReadFloat32(streamId)
            p.chainStartZ  = streamReadFloat32(streamId)
            p.chainStartRY = streamReadFloat32(streamId)
        end

        p.hasDockingStation = streamReadBool(streamId)
        if p.hasDockingStation then
            p.dsSaveX  = streamReadFloat32(streamId)
            p.dsSaveY  = streamReadFloat32(streamId)
            p.dsSaveZ  = streamReadFloat32(streamId)
            p.dsSaveRX = streamReadFloat32(streamId)
            p.dsSaveRY = streamReadFloat32(streamId)
            p.dsSaveRZ = streamReadFloat32(streamId)
        end

        p.segments = {}
        local n = streamReadUIntN(streamId, 8)
        for i = 1, n do
            local s = {}
            s.x      = streamReadFloat32(streamId)
            s.y      = streamReadFloat32(streamId)
            s.z      = streamReadFloat32(streamId)
            s.colorR = streamReadFloat32(streamId)
            s.colorG = streamReadFloat32(streamId)
            s.colorB = streamReadFloat32(streamId)
            p.segments[i] = s
        end
        self.payload = p
    end

    self:run(connection)
end

function SPSChainRequestEvent:run(connection)
    print(string.format("[SPS MP] RequestEvent.run RECV netId=%s removed=%s server=%s",
        tostring(self.netId), tostring(self.removed), tostring(g_server ~= nil)))
    -- Client -> server only. Apply authoritatively on the server (which itself
    -- broadcasts SPSChainStateEvent). No-op if somehow received on a client.
    if g_server ~= nil and g_slurryPipeManager ~= nil
    and g_slurryPipeManager.applyChainRequest ~= nil then
        g_slurryPipeManager:applyChainRequest(
            self.netId, self.removed,
            self.anchorObject, self.couplingId, self.isPlaceable,
            self.payload)
    end
end

function SPSChainRequestEvent.sendEvent(netId, removed, anchorObject, couplingId, isPlaceable, payload)
    if g_server ~= nil then
        -- Server never sends a request to itself; it commits directly.
        return
    end
    spsSendEventToServer(
        SPSChainRequestEvent.new(netId, removed, anchorObject, couplingId, isPlaceable, payload))
end


-- ===========================================================================
-- SPSChainConnectEvent
-- ---------------------------------------------------------------------------
-- Replicates a coupler<->chain-terminus bond (connect or disconnect). This is
-- the ONLY correct way to sync a connection that involves a chain end, because
-- chain-terminus couplings are not registered vehicle/placeable couplers and
-- their ids (e.g. the chain-start id of -2) cannot be addressed by the normal
-- SlurryPipeConnectEvent. The chain end is addressed by (chain netId + terminus
-- role): role 0 = chain start (segment 1), role k = segment k's chainCoupling.
--
-- Covers the anchor bez (vehicle coupler <-> chain start) and, later, connecting
-- a tanker to a laid chain terminus. Disconnect of the bez also works through
-- the existing SlurryPipeDisconnectEvent (vehicle-id only), but routing connect
-- here is what was missing.
-- ===========================================================================
SPSChainConnectEvent = {}
local SPSChainConnectEvent_mt = Class(SPSChainConnectEvent, Event)
InitEventClass(SPSChainConnectEvent, "SPSChainConnectEvent")

function SPSChainConnectEvent.emptyNew()
    local self = Event.new(SPSChainConnectEvent_mt)
    return self
end

-- anchorObject     : vehicle or placeable owning the real coupler
-- isPlaceable      : true => anchorObject is a placeable
-- vehicleCouplingId: the real coupler's id (small positive)
-- chainNetId       : the chain being bonded to
-- terminusSegIndex : 0 = chain start, k = segment k's chainCoupling
-- connected        : true = connect, false = disconnect
function SPSChainConnectEvent.new(anchorObject, isPlaceable, vehicleCouplingId, chainNetId, terminusSegIndex, connected)
    local self = SPSChainConnectEvent.emptyNew()
    self.anchorObject      = anchorObject
    self.isPlaceable       = isPlaceable == true
    self.vehicleCouplingId = vehicleCouplingId or 0
    self.chainNetId        = chainNetId or 0
    self.terminusSegIndex  = terminusSegIndex or 0
    self.connected         = connected == true
    return self
end

function SPSChainConnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.anchorObject)
    streamWriteBool(streamId, self.isPlaceable)
    streamWriteUIntN(streamId, self.vehicleCouplingId, 4)
    streamWriteUIntN(streamId, self.chainNetId, 12)
    streamWriteUIntN(streamId, self.terminusSegIndex, 8)
    streamWriteBool(streamId, self.connected)
end

function SPSChainConnectEvent:readStream(streamId, connection)
    self.anchorObject      = NetworkUtil.readNodeObject(streamId)
    self.isPlaceable       = streamReadBool(streamId)
    self.vehicleCouplingId = streamReadUIntN(streamId, 4)
    self.chainNetId        = streamReadUIntN(streamId, 12)
    self.terminusSegIndex  = streamReadUIntN(streamId, 8)
    self.connected         = streamReadBool(streamId)
    self:run(connection)
end

function SPSChainConnectEvent:run(connection)
    print(string.format("[SPS MP] ChainConnectEvent.run RECV netId=%s seg=%s connected=%s fromServer=%s",
        tostring(self.chainNetId), tostring(self.terminusSegIndex),
        tostring(self.connected), tostring(connection:getIsServer())))
    -- If the server received this from a client, relay to the other clients
    -- (excluding the sender, who applied optimistically).
    if not connection:getIsServer() then
        if g_server ~= nil then
            g_server:broadcastEvent(self, false, connection, self.anchorObject)
        end
    end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyChainConnect ~= nil then
        g_slurryPipeManager:applyChainConnect(
            self.anchorObject, self.isPlaceable, self.vehicleCouplingId,
            self.chainNetId, self.terminusSegIndex, self.connected)
    end
end

function SPSChainConnectEvent.sendEvent(anchorObject, isPlaceable, vehicleCouplingId, chainNetId, terminusSegIndex, connected)
    local ev = SPSChainConnectEvent.new(anchorObject, isPlaceable, vehicleCouplingId, chainNetId, terminusSegIndex, connected)
    if g_server ~= nil then
        g_server:broadcastEvent(ev, nil, nil, anchorObject)
        return
    end
    spsSendEventToServer(ev)
end


-- ===========================================================================
-- SPSChainLiveEvent
-- ---------------------------------------------------------------------------
-- Real-time preview of a pipe being laid (the "live" segment that tracks the
-- laying player before lock). Three actions:
--   START  : create a preview segment on remote peers at the start point.
--            Sent to ALL peers (incl the originator) so the originator's chain
--            adopts the server-assigned netId. A client sends netId=0 and the
--            server allocates one before relaying.
--   POS    : stream the current end position (throttled). Relayed to everyone
--            except the sender (who already shows it locally).
--   CANCEL : remove the preview (laying aborted). Lock is handled separately by
--            the committed-state event, which replaces the preview.
-- The preview is keyed by netId. Remote previews are flagged isRemoteLive so
-- they are driven by POS events rather than local-player tracking.
-- ===========================================================================
SPSChainLiveEvent = {}
local SPSChainLiveEvent_mt = Class(SPSChainLiveEvent, Event)
InitEventClass(SPSChainLiveEvent, "SPSChainLiveEvent")

SPSChainLiveEvent.ACTION_START  = 0
SPSChainLiveEvent.ACTION_POS    = 1
SPSChainLiveEvent.ACTION_CANCEL = 2

function SPSChainLiveEvent.emptyNew()
    return Event.new(SPSChainLiveEvent_mt)
end

function SPSChainLiveEvent.new(action, netId, anchorObject, couplingId, isPlaceable, sx, sy, sz, sry, ex, ey, ez)
    local self = SPSChainLiveEvent.emptyNew()
    self.action       = action
    self.netId        = netId or 0
    self.anchorObject = anchorObject
    self.couplingId   = couplingId or 0
    self.isPlaceable  = isPlaceable == true
    self.sx, self.sy, self.sz, self.sry = sx or 0, sy or 0, sz or 0, sry or 0
    self.ex, self.ey, self.ez = ex or 0, ey or 0, ez or 0
    return self
end

function SPSChainLiveEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.action, 2)
    streamWriteUIntN(streamId, self.netId, 12)
    if self.action == SPSChainLiveEvent.ACTION_START then
        local hasAnchor = self.anchorObject ~= nil
        streamWriteBool(streamId, hasAnchor)
        if hasAnchor then
            NetworkUtil.writeNodeObject(streamId, self.anchorObject)
            streamWriteUIntN(streamId, self.couplingId, 4)
            streamWriteBool(streamId, self.isPlaceable)
        end
        streamWriteFloat32(streamId, self.sx)
        streamWriteFloat32(streamId, self.sy)
        streamWriteFloat32(streamId, self.sz)
        streamWriteFloat32(streamId, self.sry)
    elseif self.action == SPSChainLiveEvent.ACTION_POS then
        streamWriteFloat32(streamId, self.ex)
        streamWriteFloat32(streamId, self.ey)
        streamWriteFloat32(streamId, self.ez)
    end
end

function SPSChainLiveEvent:readStream(streamId, connection)
    self.action = streamReadUIntN(streamId, 2)
    self.netId  = streamReadUIntN(streamId, 12)
    if self.action == SPSChainLiveEvent.ACTION_START then
        local hasAnchor = streamReadBool(streamId)
        if hasAnchor then
            self.anchorObject = NetworkUtil.readNodeObject(streamId)
            self.couplingId   = streamReadUIntN(streamId, 4)
            self.isPlaceable  = streamReadBool(streamId)
        end
        self.sx = streamReadFloat32(streamId)
        self.sy = streamReadFloat32(streamId)
        self.sz = streamReadFloat32(streamId)
        self.sry = streamReadFloat32(streamId)
    elseif self.action == SPSChainLiveEvent.ACTION_POS then
        self.ex = streamReadFloat32(streamId)
        self.ey = streamReadFloat32(streamId)
        self.ez = streamReadFloat32(streamId)
    end
    self:run(connection)
end

function SPSChainLiveEvent:run(connection)
    local fromServer = connection:getIsServer()
    -- Server received from a client: for START with no id, allocate one first.
    if not fromServer and g_server ~= nil then
        if self.action == SPSChainLiveEvent.ACTION_START and self.netId == 0
        and g_slurryPipeManager ~= nil then
            self.netId = g_slurryPipeManager:_allocChainNetId()
        end
        -- START must reach everyone (incl the originator, to learn the netId);
        -- POS/CANCEL exclude the sender (who already shows it locally).
        if self.action == SPSChainLiveEvent.ACTION_START then
            g_server:broadcastEvent(self, false, nil, self.anchorObject)
        else
            g_server:broadcastEvent(self, false, connection, self.anchorObject)
        end
    end

    if g_slurryPipeManager == nil then return end
    if self.action == SPSChainLiveEvent.ACTION_START then
        if g_slurryPipeManager.applyChainLiveStart ~= nil then
            g_slurryPipeManager:applyChainLiveStart(self.netId, self.anchorObject,
                self.couplingId, self.isPlaceable, self.sx, self.sy, self.sz, self.sry)
        end
    elseif self.action == SPSChainLiveEvent.ACTION_POS then
        if g_slurryPipeManager.applyChainLivePos ~= nil then
            g_slurryPipeManager:applyChainLivePos(self.netId, self.ex, self.ey, self.ez)
        end
    elseif self.action == SPSChainLiveEvent.ACTION_CANCEL then
        if g_slurryPipeManager.applyChainLiveCancel ~= nil then
            g_slurryPipeManager:applyChainLiveCancel(self.netId)
        end
    end
end

function SPSChainLiveEvent.sendStart(netId, anchorObject, couplingId, isPlaceable, sx, sy, sz, sry)
    local ev = SPSChainLiveEvent.new(SPSChainLiveEvent.ACTION_START, netId, anchorObject, couplingId, isPlaceable, sx, sy, sz, sry)
    if g_server ~= nil then
        g_server:broadcastEvent(ev, false, nil, anchorObject)
        return
    end
    spsSendEventToServer(ev)
end

function SPSChainLiveEvent.sendPos(netId, ex, ey, ez)
    local ev = SPSChainLiveEvent.new(SPSChainLiveEvent.ACTION_POS, netId, nil, 0, false, 0, 0, 0, 0, ex, ey, ez)
    if g_server ~= nil then
        g_server:broadcastEvent(ev, false, nil, nil)
        return
    end
    spsSendEventToServer(ev)
end

function SPSChainLiveEvent.sendCancel(netId)
    local ev = SPSChainLiveEvent.new(SPSChainLiveEvent.ACTION_CANCEL, netId)
    if g_server ~= nil then
        g_server:broadcastEvent(ev, false, nil, nil)
        return
    end
    spsSendEventToServer(ev)
end