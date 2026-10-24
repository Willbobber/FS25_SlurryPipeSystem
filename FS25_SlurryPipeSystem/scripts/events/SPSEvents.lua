if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSEvents 1.0.0.9.31 loaded") end
-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.9.2

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
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP RX] FlowStateEvent:run isServer=%s vehicle=%s isFlowOpen=%s synced=%s",
        tostring(connection:getIsServer()), spsRxId(self.vehicle), tostring(self.isFlowOpen),
        tostring(self.vehicle ~= nil and self.vehicle:getIsSynchronized())))
        end
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle, nil, nil, true)
    end
    -- [SPS MP 1.0.1.8] Apply now, or (client) defer until the vehicle registers:
    -- the join dump lands before delayed-loaded vehicles exist on the joiner.
    if self.vehicle ~= nil and g_slurryPipeManager ~= nil then
        local vehicle, isFlowOpen = self.vehicle, self.isFlowOpen
        g_slurryPipeManager:applyOrDeferVehicleState(vehicle, "FlowStateEvent", function(entry, state)
            state.valveOpen = isFlowOpen
            g_slurryPipeManager:updateActionEventTexts(vehicle)
        end)
    end
end

function SlurryFlowStateEvent.sendEvent(vehicle, isFlowOpen, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryFlowStateEvent.new(vehicle, isFlowOpen), nil, nil, vehicle, nil, nil, true)
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
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP RX] FlowDirectionEvent:run isServer=%s vehicle=%s direction=%s synced=%s",
        tostring(connection:getIsServer()), spsRxId(self.vehicle), tostring(self.direction),
        tostring(self.vehicle ~= nil and self.vehicle:getIsSynchronized())))
        end
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle, nil, nil, true)
    end
    if self.vehicle ~= nil and g_slurryPipeManager ~= nil then
        local vehicle, direction = self.vehicle, self.direction
        g_slurryPipeManager:applyOrDeferVehicleState(vehicle, "FlowDirectionEvent", function(entry, state)
            g_slurryPipeManager:applyDirectionAndPurge(vehicle, direction)
            g_slurryPipeManager:updateActionEventTexts(vehicle)
        end)
    end
end

function SlurryFlowDirectionEvent.sendEvent(vehicle, direction, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryFlowDirectionEvent.new(vehicle, direction), nil, nil, vehicle, nil, nil, true)
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
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP RX] ConnectEvent:readStream vehicleA=%s targetObject=%s targetType=%s idA=%s idB=%s isServer=%s",
        spsRxId(self.vehicleA), spsRxId(self.targetObject), tostring(self.targetType),
        tostring(self.couplingIdA), tostring(self.couplingIdB), tostring(connection:getIsServer())))
        end
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
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP RX] ConnectEvent:run isServer=%s vehicleA=%s target=%s",
        tostring(connection:getIsServer()), spsRxId(self.vehicleA), spsRxId(self.targetObject)))
        end
    if not connection:getIsServer() then
        -- Include the originating client (ignoreConnection = nil): the partner coupling
        -- is resolved server-side, so the sender cannot apply optimistically and must
        -- receive the echo to render the pipe locally.
        g_server:broadcastEvent(self, false, nil, self.vehicleA, nil, nil, true)
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
            g_server:broadcastEvent(SlurryPipeConnectEvent.new(vehicleA, targetObject, targetType, couplingIdA, couplingIdB), nil, nil, vehicleA, nil, nil, true)
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

function SlurryPipeDisconnectEvent.new(vehicleA, couplingIdA, couplingObj)
    local self = SlurryPipeDisconnectEvent.emptyNew()
    self.vehicleA    = vehicleA
    self.couplingIdA = couplingIdA
    -- [SPS MP 1.0.0.9.2] Placeable-owner keying, mirroring SlurryValveStateEvent:
    -- a placeable-side disconnect used to travel as (vehicle=nil, 4-bit id) and the
    -- receiver's fallback grabbed the FIRST id match across ALL stores — on
    -- multi-store maps the wrong coupling was disconnected (or none), so the pipe
    -- stayed attached on every other machine until auto-disconnect distance fired
    -- (dedi report: "friend detaches, still attached on my end until he drives off").
    self.placeableOwner = nil
    if type(couplingObj) == "table" then
        self.placeableOwner = couplingObj.placeable   -- nil for vehicle/chain couplings
    end
    -- [SPS MP] Chain-terminus keying: raw terminus ids (segment index, -2 for the
    -- chain start) are not resolvable on a remote machine — they collide with
    -- vehicle/placeable coupling ids and never appear in those lists. When the
    -- initiator has the coupling object and it is a chain terminus on a netId'd
    -- chain, transmit (netId + role) so the receiver resolves the EXACT coupling.
    self.chainNetId = nil
    self.chainRole  = nil
    if type(couplingObj) == "table" and couplingObj.isChainTerminus
    and couplingObj.chain ~= nil and couplingObj.chain.netId ~= nil
    and g_slurryPipeManager ~= nil and g_slurryPipeManager._getChainTerminusRole ~= nil then
        local role = g_slurryPipeManager:_getChainTerminusRole(couplingObj.chain, couplingObj)
        if role ~= nil then
            self.chainNetId = couplingObj.chain.netId
            self.chainRole  = role
        end
    end
    -- The id travels as a 4-bit uint; chain-start ids are negative. Sanitize the
    -- streamed value (the chain keying above carries the real identity).
    if self.couplingIdA == nil or self.couplingIdA < 0 or self.couplingIdA > 15 then
        self.couplingIdA = 0
    end
    return self
end

function SlurryPipeDisconnectEvent:readStream(streamId, connection)
    self.vehicleA    = NetworkUtil.readNodeObject(streamId)
    self.couplingIdA = streamReadUIntN(streamId, 4)
    -- [SPS MP 1.0.0.9.2] Optional placeable owner (see new()).
    if streamReadBool(streamId) then
        self.placeableOwner = NetworkUtil.readNodeObject(streamId)
    else
        self.placeableOwner = nil
    end
    -- [SPS MP] Optional chain-terminus keying (netId + role), appended fields.
    if streamReadBool(streamId) then
        self.chainNetId = streamReadUIntN(streamId, 12)
        self.chainRole  = streamReadUIntN(streamId, 8)
    else
        self.chainNetId = nil
        self.chainRole  = nil
    end
    self:run(connection)
end

function SlurryPipeDisconnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicleA)
    streamWriteUIntN(streamId, self.couplingIdA, 4)
    streamWriteBool(streamId, self.placeableOwner ~= nil)
    if self.placeableOwner ~= nil then
        NetworkUtil.writeNodeObject(streamId, self.placeableOwner)
    end
    streamWriteBool(streamId, self.chainNetId ~= nil)
    if self.chainNetId ~= nil then
        streamWriteUIntN(streamId, self.chainNetId, 12)
        streamWriteUIntN(streamId, self.chainRole or 0, 8)
    end
end

function SlurryPipeDisconnectEvent:run(connection)
    if not connection:getIsServer() then
        -- Include the originating client so it removes the pipe locally.
        g_server:broadcastEvent(self, false, nil, self.vehicleA, nil, nil, true)
    end
    if g_slurryPipeManager ~= nil then
        -- [SPS MP] Resolve the exact chain-terminus coupling from (netId + role)
        -- when transmitted. Without this, applyDisconnect's id fallback cannot see
        -- chainTerminusEntries at all and the disconnect silently no-ops on every
        -- machine except the initiator (guest removes, host keeps the pipe).
        local couplingObj = nil
        -- [SPS MP 1.0.0.9.2] If a placeable owner was transmitted, narrow the
        -- lookup to that placeable's couplings first (mirrors SlurryValveStateEvent).
        if self.placeableOwner ~= nil then
            for _, pEntry in ipairs(g_slurryPipeManager.registeredPlaceables) do
                if pEntry.placeable == self.placeableOwner and pEntry.storeCouplings ~= nil then
                    for _, sc in ipairs(pEntry.storeCouplings) do
                        if sc.id == self.couplingIdA then couplingObj = sc break end
                    end
                    break
                end
            end
        end
        if couplingObj == nil and self.chainNetId ~= nil and g_slurryPipeManager._chainsByNetId ~= nil then
            local chain = g_slurryPipeManager._chainsByNetId[self.chainNetId]
            if chain ~= nil and g_slurryPipeManager._resolveChainTerminus ~= nil then
                couplingObj = g_slurryPipeManager:_resolveChainTerminus(chain, self.chainRole or 0)
            end
        end
        SlurryPipeManager.logMP(string.format(
            "[SPS MP RX] DisconnectEvent vehicleA=%s couplingId=%s placeableOwner=%s chainNetId=%s couplingObjResolved=%s",
            tostring(self.vehicleA ~= nil and self.vehicleA.rootNode or nil), tostring(self.couplingIdA),
            tostring(self.placeableOwner ~= nil), tostring(self.chainNetId),
            tostring(couplingObj ~= nil)))
        g_slurryPipeManager:applyDisconnect(self.vehicleA, self.couplingIdA, couplingObj)
    end
end

function SlurryPipeDisconnectEvent.sendEvent(vehicleA, couplingIdA, noEventSend, couplingObj)
    if noEventSend == true then return end

    if g_server ~= nil then
        g_server:broadcastEvent(SlurryPipeDisconnectEvent.new(vehicleA, couplingIdA, couplingObj), nil, nil, vehicleA, nil, nil, true)
        return
    end

    -- During quit/delete the client connection can already be nil.
    if g_client ~= nil and g_client.getServerConnection ~= nil then
        local connection = g_client:getServerConnection()
        if connection ~= nil then
            connection:sendEvent(SlurryPipeDisconnectEvent.new(vehicleA, couplingIdA, couplingObj))
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
        -- [SPS MP] Chain-terminus keying (netId + role): raw terminus ids are not
        -- resolvable remotely (they collide with vehicle/placeable ids and live only
        -- in chainTerminusEntries). Mirrors SlurryPipeDisconnectEvent.
        self.chainNetId = nil
        self.chainRole  = nil
        if couplingArg.isChainTerminus and couplingArg.chain ~= nil
        and couplingArg.chain.netId ~= nil
        and g_slurryPipeManager ~= nil and g_slurryPipeManager._getChainTerminusRole ~= nil then
            local role = g_slurryPipeManager:_getChainTerminusRole(couplingArg.chain, couplingArg)
            if role ~= nil then
                self.chainNetId = couplingArg.chain.netId
                self.chainRole  = role
            end
        end
    else
        self.couplingId        = couplingArg
        self.placeableOwner    = nil
        self.chainNetId        = nil
        self.chainRole         = nil
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
    -- [SPS MP] Optional chain-terminus keying (netId + role), appended fields.
    if streamReadBool(streamId) then
        self.chainNetId = streamReadUIntN(streamId, 12)
        self.chainRole  = streamReadUIntN(streamId, 8)
    else
        self.chainNetId = nil
        self.chainRole  = nil
    end
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP RX] ValveEvent:readStream vehicleA=%s couplingId=%s isOpen=%s placeableOwner=%s isServer=%s",
        spsRxId(self.vehicleA), tostring(self.couplingId), tostring(self.isOpen),
        spsRxId(self.placeableOwner), tostring(connection:getIsServer())))
        end
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
    streamWriteBool(streamId, self.chainNetId ~= nil)
    if self.chainNetId ~= nil then
        streamWriteUIntN(streamId, self.chainNetId, 12)
        streamWriteUIntN(streamId, self.chainRole or 0, 8)
    end
end

function SlurryValveStateEvent:run(connection)
    if not connection:getIsServer() then
        -- Include the originating client so it applies the coupling valve state locally.
        g_server:broadcastEvent(self, false, nil, self.vehicleA, nil, nil, true)
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
        -- [SPS MP] Chain-terminus resolution from (netId + role) — exact coupling,
        -- no id ambiguity. Without this a guest's valve toggle at a chain coupling
        -- resolved to nothing (or the wrong coupling) on the server.
        if couplingObj == nil and self.chainNetId ~= nil
        and g_slurryPipeManager._chainsByNetId ~= nil then
            local chain = g_slurryPipeManager._chainsByNetId[self.chainNetId]
            if chain ~= nil and g_slurryPipeManager._resolveChainTerminus ~= nil then
                couplingObj = g_slurryPipeManager:_resolveChainTerminus(chain, self.chainRole or 0)
            end
        end
        g_slurryPipeManager:applyValveState(self.vehicleA, self.couplingId, self.isOpen, couplingObj)
        -- [SPS MP] Server-side chain propagation for CLIENT-initiated valve events.
        -- The host path (onValveOpen/Close) walks the chain to the far terminus via
        -- _propagateValveState and broadcasts the far-end state; the event path only
        -- ever applied the near coupling, so a guest's toggle never reached the far
        -- end (or the flow gate) on the server. Mirror the host path here.
        if not connection:getIsServer() and g_server ~= nil
        and g_slurryPipeManager._propagateValveState ~= nil then
            local propCoupling = couplingObj
            if propCoupling == nil then
                propCoupling = g_slurryPipeManager:_findCouplingById(self.vehicleA, self.couplingId, false)
            end
            if propCoupling ~= nil then
                g_slurryPipeManager:_propagateValveState(propCoupling, self.isOpen)
            end
        end
        if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
        print(string.format("[SPS MP RX] ValveEvent:run applied couplingId=%s isOpen=%s couplingObjResolved=%s",
            tostring(self.couplingId), tostring(self.isOpen), tostring(couplingObj ~= nil)))
            end
    end
end

function SlurryValveStateEvent.sendEvent(vehicleA, couplingArg, isOpen, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SlurryValveStateEvent.new(vehicleA, couplingArg, isOpen), nil, nil, vehicleA, nil, nil, true)
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
        g_server:broadcastEvent(self, false, connection, self.placeable, nil, nil, true)
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:applyCouplingDeployState(self.placeable, self.couplingId, self.isDeployed)
    end
end

function SPSCouplingDeployEvent.sendEvent(placeable, couplingId, isDeployed, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSCouplingDeployEvent.new(placeable, couplingId, isDeployed), nil, nil, placeable, nil, nil, true)
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
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP RX] SelfPumpStateEvent:run isServer=%s vehicle=%s pumpRunning=%s synced=%s",
        tostring(connection:getIsServer()), spsRxId(self.vehicle), tostring(self.pumpRunning),
        tostring(self.vehicle ~= nil and self.vehicle:getIsSynchronized())))
        end
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle, nil, nil, true)
    end
    if self.vehicle ~= nil and g_slurryPipeManager ~= nil then
        local vehicle, pumpRunning = self.vehicle, self.pumpRunning
        g_slurryPipeManager:applyOrDeferVehicleState(vehicle, "SelfPumpStateEvent", function(entry, state)
            do
                state.pumpRunning = pumpRunning
                -- [SPS MP] Drive the pump engine loop on receiving machines. The
                -- toggle only plays/stops it on the initiator, so remote peers
                -- (host included, for guest toggles) stayed silent.
                if g_slurryPipeManager.applyPumpSound ~= nil then
                    g_slurryPipeManager:applyPumpSound(vehicle, pumpRunning)
                end
                -- [SPS MP] When the SERVER applies a CLIENT's spreader-pump request it
                -- must also drive the vanilla turned-on state (PTO engage / engine load).
                -- togglePump only calls setIsTurnedOn on the initiating peer, so a guest
                -- toggle would otherwise set the SPS flag without ever engaging the PTO.
                -- Server-only; vanilla TurnOnVehicle then streams turnedOn to every
                -- client. Non-spreader pumps use vanilla TurnOnVehicleEvent directly and
                -- need nothing here. run() only executes on the server for client-sent
                -- events, so this never double-fires a server-originated toggle.
                if g_server ~= nil and vehicle.setIsTurnedOn ~= nil
                and g_slurryPipeManager.vehicleHasSpreader ~= nil
                and g_slurryPipeManager:vehicleHasSpreader(vehicle) then
                    vehicle:setIsTurnedOn(pumpRunning == true)
                end
                g_slurryPipeManager:updateActionEventTexts(vehicle)
            end
        end)
    end
end

function SPSSelfPumpStateEvent.sendEvent(vehicle, pumpRunning, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSSelfPumpStateEvent.new(vehicle, pumpRunning), nil, nil, vehicle, nil, nil, true)
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
    if self.vehicle ~= nil and g_slurryPipeManager ~= nil then
        local pressure = self.pressure
        g_slurryPipeManager:applyOrDeferVehicleState(self.vehicle, "PressureStateEvent", function(entry, state)
            state.pressure = pressure
        end)
    end
end

function SPSPressureStateEvent.sendEvent(vehicle, pressure)
    -- Server only. Scoped to the vehicle ghost so only connections that already
    -- know the vehicle receive it.
    if g_server ~= nil then
        g_server:broadcastEvent(SPSPressureStateEvent.new(vehicle, pressure), nil, nil, vehicle, nil, nil, true)
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
        g_server:broadcastEvent(self, false, connection, self.vehicle, nil, nil, true)
    end
    if self.vehicle ~= nil and g_slurryPipeManager ~= nil then
        local vehicle, isOpen = self.vehicle, self.isOpen
        g_slurryPipeManager:applyOrDeferVehicleState(vehicle, "SpreaderValveEvent", function(entry, state)
            state.spreaderValveOpen = isOpen
            g_slurryPipeManager:updateActionEventTexts(vehicle)
            -- [SPS 1.0.1.6] Rear-valve animation on remote peers (this run()
            -- also carries the JIP full-state resend, so late joiners see
            -- an already-open valve animate to its open pose).
            g_slurryPipeManager:updateSpreaderValveAnimation(vehicle, false)
        end)
    end
end

function SPSSpreaderValveEvent.sendEvent(vehicle, isOpen, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(SPSSpreaderValveEvent.new(vehicle, isOpen), nil, nil, vehicle, nil, nil, true)
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
        -- [SPS MP] Full chain-start rotation (rx/rz). getSaveData now captures the
        -- complete pipeRoot rotation; without streaming it a joining/receiving peer
        -- rebuilds vehicle-anchored segment 1 yaw-only and shows the 180-degree
        -- twist the savegame fix removed on the host.
        streamWriteBool(streamId, p.chainStartRX ~= nil)
        if p.chainStartRX ~= nil then
            streamWriteFloat32(streamId, p.chainStartRX or 0)
            streamWriteFloat32(streamId, p.chainStartRZ or 0)
        end
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
            -- [SPS MP] Optional full chain-start rotation (see writeStream).
            if streamReadBool(streamId) then
                p.chainStartRX = streamReadFloat32(streamId)
                p.chainStartRZ = streamReadFloat32(streamId)
            end
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
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP] StateEvent.run RECV netId=%s removed=%s fromServer=%s",
        tostring(self.netId), tostring(self.removed), tostring(connection:getIsServer())))
        end
    -- State events are authoritative and only ever travel server -> clients.
    -- If a server somehow receives one from a client, relay defensively (but do
    -- not include the sender, who is the authority for nothing here).
    if not connection:getIsServer() then
        if g_server ~= nil then
            g_server:broadcastEvent(self, false, connection, self.anchorObject, nil, nil, true)
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
        nil, nil, anchorObject, nil, nil, true)
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
        -- [SPS MP] Full chain-start rotation (rx/rz). getSaveData now captures the
        -- complete pipeRoot rotation; without streaming it a joining/receiving peer
        -- rebuilds vehicle-anchored segment 1 yaw-only and shows the 180-degree
        -- twist the savegame fix removed on the host.
        streamWriteBool(streamId, p.chainStartRX ~= nil)
        if p.chainStartRX ~= nil then
            streamWriteFloat32(streamId, p.chainStartRX or 0)
            streamWriteFloat32(streamId, p.chainStartRZ or 0)
        end
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
            -- [SPS MP] Optional full chain-start rotation (see writeStream).
            if streamReadBool(streamId) then
                p.chainStartRX = streamReadFloat32(streamId)
                p.chainStartRZ = streamReadFloat32(streamId)
            end
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
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP] RequestEvent.run RECV netId=%s removed=%s server=%s",
        tostring(self.netId), tostring(self.removed), tostring(g_server ~= nil)))
        end
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
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP] ChainConnectEvent.run RECV netId=%s seg=%s connected=%s fromServer=%s",
        tostring(self.chainNetId), tostring(self.terminusSegIndex),
        tostring(self.connected), tostring(connection:getIsServer())))
        end
    -- If the server received this from a client, relay to the other clients
    -- (excluding the sender, who applied optimistically).
    if not connection:getIsServer() then
        if g_server ~= nil then
            g_server:broadcastEvent(self, false, connection, self.anchorObject, nil, nil, true)
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
        g_server:broadcastEvent(ev, nil, nil, anchorObject, nil, nil, true)
        return
    end
    spsSendEventToServer(ev)
end


-- ===========================================================================
-- SPSDockingStationEvent
-- ---------------------------------------------------------------------------
-- Syncs a LIVE docking-station add/remove on a chain. Chains are addressed by
-- netId (same scheme as SPSChainConnectEvent). Chain add/removeDockingStation
-- are deterministic from the chain's own already-synced nodes and idempotent, so
-- each peer reproduces the DS identically — including its rubberBootPort, so the
-- DS is usable on every peer. Without this, a host-added DS never reached the
-- guest (and vice-versa); only the JIP/savegame path carried hasDockingStation.
-- ===========================================================================
SPSDockingStationEvent = {}
local SPSDockingStationEvent_mt = Class(SPSDockingStationEvent, Event)
InitEventClass(SPSDockingStationEvent, "SPSDockingStationEvent")

function SPSDockingStationEvent.emptyNew()
    local self = Event.new(SPSDockingStationEvent_mt)
    return self
end

function SPSDockingStationEvent.new(chainNetId, isAdd)
    local self = SPSDockingStationEvent.emptyNew()
    self.chainNetId = chainNetId or 0
    self.isAdd      = isAdd == true
    return self
end

function SPSDockingStationEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.chainNetId, 12)
    streamWriteBool(streamId, self.isAdd)
end

function SPSDockingStationEvent:readStream(streamId, connection)
    self.chainNetId = streamReadUIntN(streamId, 12)
    self.isAdd      = streamReadBool(streamId)
    self:run(connection)
end

function SPSDockingStationEvent:run(connection)
    if SlurryPipeManager ~= nil and SlurryPipeManager.MP_DEBUG then
    print(string.format("[SPS MP] DockingStationEvent.run RECV netId=%s isAdd=%s fromServer=%s",
        tostring(self.chainNetId), tostring(self.isAdd), tostring(connection:getIsServer())))
        end
    -- Server relays a client's change to the other clients (the sender applied
    -- optimistically, so it is excluded from the rebroadcast).
    if not connection:getIsServer() then
        if g_server ~= nil then
            g_server:broadcastEvent(self, false, connection, nil)
        end
    end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyDockingStationState ~= nil then
        g_slurryPipeManager:applyDockingStationState(self.chainNetId, self.isAdd)
    end
end

function SPSDockingStationEvent.sendEvent(chainNetId, isAdd)
    local ev = SPSDockingStationEvent.new(chainNetId, isAdd)
    if g_server ~= nil then
        g_server:broadcastEvent(ev, nil, nil, nil)
        return
    end
    spsSendEventToServer(ev)
end


-- ===========================================================================
-- SPSStoreCrustEvent
-- ---------------------------------------------------------------------------
-- Server -> clients. Replicates a slurry store's two authoritative pool values
-- (solids = litres dry matter, settle = 0..1 crust). Store aging, mixing and fill
-- are all server-authoritative, so this is one-directional — a client never
-- originates a crust change. On the client applyStoreCrustState raises the crust
-- plane (settle * maxRise) and refreshes the crust foliage + thickness/crust HUD;
-- the store, crust plane and foliage all already exist on the client (registration
-- is symmetric), only the values were missing.
-- ===========================================================================
SPSStoreCrustEvent = {}
local SPSStoreCrustEvent_mt = Class(SPSStoreCrustEvent, Event)
InitEventClass(SPSStoreCrustEvent, "SPSStoreCrustEvent")

function SPSStoreCrustEvent.emptyNew()
    local self = Event.new(SPSStoreCrustEvent_mt)
    return self
end

-- [SPS 1.0.0.9.31] storeIndex identifies WHICH lagoon on the placeable this value
-- belongs to (1-based, matching getStoreSources order). A placeable with a single
-- store always sends 1, which resolves to its primary sourceEntry — so the wire
-- shape gained one byte and nothing else about the behaviour changed.
function SPSStoreCrustEvent.new(placeable, solids, settle, storeIndex)
    local self = SPSStoreCrustEvent.emptyNew()
    self.placeable  = placeable
    self.solids     = solids or 0
    self.settle     = settle or 0
    self.storeIndex = storeIndex or 1
    return self
end

function SPSStoreCrustEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteFloat32(streamId, self.solids)
    streamWriteFloat32(streamId, self.settle)
    streamWriteUInt8(streamId, self.storeIndex or 1)
end

function SPSStoreCrustEvent:readStream(streamId, connection)
    self.placeable  = NetworkUtil.readNodeObject(streamId)
    self.solids     = streamReadFloat32(streamId)
    self.settle     = streamReadFloat32(streamId)
    self.storeIndex = streamReadUInt8(streamId)
    self:run(connection)
end

function SPSStoreCrustEvent:run(connection)
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyStoreCrustState ~= nil then
        g_slurryPipeManager:applyStoreCrustState(self.placeable, self.solids, self.settle, false, self.storeIndex)
    end
end

function SPSStoreCrustEvent.sendEvent(placeable, solids, settle, storeIndex)
    if g_server == nil then return end
    g_server:broadcastEvent(SPSStoreCrustEvent.new(placeable, solids, settle, storeIndex), nil, nil, placeable, nil, nil, true)
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
            g_server:broadcastEvent(self, false, nil, self.anchorObject, nil, nil, true)
        else
            g_server:broadcastEvent(self, false, connection, self.anchorObject, nil, nil, true)
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
        g_server:broadcastEvent(ev, false, nil, anchorObject, nil, nil, true)
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
-- ===========================================================================
-- SPSSettingsSyncEvent
-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.5] Server-authoritative sync of the gameplay settings rows
-- (realism master, thickness flow, blockages, length falloff, shear bolt
-- master, IBC persistence). Flow:
--   * an admin on a CLIENT changes a row -> requestGameplaySettings applies
--     locally (optimistic) and sends this event to the server,
--   * the server applies authoritatively and rebroadcasts to the other
--     clients (sender excluded — it already applied),
--   * the SERVER/host changing a row applies + broadcasts to everyone,
--   * late joiners receive the current set in the manager's join dump.
-- HUD settings are deliberately NOT in this event — they are per-player and
-- persist in each player's own user file (see saveUserSettings).
-- ---------------------------------------------------------------------------
SPSSettingsSyncEvent = {}
local SPSSettingsSyncEvent_mt = Class(SPSSettingsSyncEvent, Event)
InitEventClass(SPSSettingsSyncEvent, "SPSSettingsSyncEvent")

function SPSSettingsSyncEvent.emptyNew()
    local self = Event.new(SPSSettingsSyncEvent_mt)
    return self
end

function SPSSettingsSyncEvent.new(realismEnabled, thicknessFlow, blockages, lengthFalloff, shearBoltEnabled, ibcPersistWhenEmpty, physicalPipesEnabled)
    local self = SPSSettingsSyncEvent.emptyNew()
    self.realismEnabled      = realismEnabled ~= false
    self.thicknessFlow       = thicknessFlow ~= false
    self.blockages           = blockages ~= false
    self.lengthFalloff       = lengthFalloff ~= false
    self.shearBoltEnabled    = shearBoltEnabled ~= false
    self.ibcPersistWhenEmpty = ibcPersistWhenEmpty == true
    self.physicalPipesEnabled = physicalPipesEnabled == true   -- [SPS 1.0.1.8] pipe mode
    return self
end

function SPSSettingsSyncEvent:readStream(streamId, connection)
    self.realismEnabled      = streamReadBool(streamId)
    self.thicknessFlow       = streamReadBool(streamId)
    self.blockages           = streamReadBool(streamId)
    self.lengthFalloff       = streamReadBool(streamId)
    self.shearBoltEnabled    = streamReadBool(streamId)
    self.ibcPersistWhenEmpty = streamReadBool(streamId)
    self.physicalPipesEnabled = streamReadBool(streamId)
    self:run(connection)
end

function SPSSettingsSyncEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.realismEnabled)
    streamWriteBool(streamId, self.thicknessFlow)
    streamWriteBool(streamId, self.blockages)
    streamWriteBool(streamId, self.lengthFalloff)
    streamWriteBool(streamId, self.shearBoltEnabled)
    streamWriteBool(streamId, self.ibcPersistWhenEmpty)
    streamWriteBool(streamId, self.physicalPipesEnabled)
end

function SPSSettingsSyncEvent:run(connection)
    if not connection:getIsServer() then
        -- [SPS 1.0.1.8] Server: only an admin (master user) may change the gameplay settings - switching the pipe mode
        -- deletes every farm's pipes and docking stations (removeAllPhysicalPipes / removeAllOriginalPipes). The menu
        -- was admin-gated, the event was not (any client's console could send it). Same check as the game's own
        -- admin events (SaveEvent, KickBanEvent). A refused client gets the real settings back: it applied its
        -- request optimistically on send.
        local um = g_currentMission ~= nil and g_currentMission.userManager or nil
        if um == nil or not um:getIsConnectionMasterUser(connection) then
            print("[SPS] settings change refused: the request did not come from an admin")
            SPSSettingsSyncEvent.sendCurrent(connection)
            return
        end
        -- Server received an admin client's request: rebroadcast to the other
        -- clients (sender excluded — it applied optimistically on send).
        g_server:broadcastEvent(self, false, connection)
    end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyGameplaySettings ~= nil then
        g_slurryPipeManager:applyGameplaySettings({
            realismEnabled      = self.realismEnabled,
            thicknessFlow       = self.thicknessFlow,
            blockages           = self.blockages,
            lengthFalloff       = self.lengthFalloff,
            shearBoltEnabled    = self.shearBoltEnabled,
            ibcPersistWhenEmpty = self.ibcPersistWhenEmpty,
            physicalPipesEnabled = self.physicalPipesEnabled,
        })
    end
end

function SPSSettingsSyncEvent.sendCurrent(connection)
    -- Join-dump helper: send the manager's current gameplay settings to one
    -- freshly joined connection. Server-side only.
    local mgr = g_slurryPipeManager
    if mgr == nil or connection == nil then return end
    local ft = mgr.featureToggles or {}
    connection:sendEvent(SPSSettingsSyncEvent.new(
        mgr.realismEnabled, ft.thicknessFlow, ft.blockages, ft.lengthFalloff,
        mgr.shearBoltEnabled, mgr.ibcPersistWhenEmpty, mgr.physicalPipesEnabled))
end

function SPSSettingsSyncEvent.sendRequest()
    -- Client-side helper: send the manager's current (optimistically applied)
    -- gameplay settings to the server. Uses the file-local server-connection
    -- wrapper, which the manager cannot reach directly.
    local mgr = g_slurryPipeManager
    if mgr == nil then return end
    local ft = mgr.featureToggles or {}
    spsSendEventToServer(SPSSettingsSyncEvent.new(
        mgr.realismEnabled, ft.thicknessFlow, ft.blockages, ft.lengthFalloff,
        mgr.shearBoltEnabled, mgr.ibcPersistWhenEmpty, mgr.physicalPipesEnabled))
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Physical pipe (bought pipe) connect / disconnect. Server-authoritative:
-- a client sends its request, the server applies and echoes to EVERY peer (sender included -
-- the coupling is resolved server-side). Mirrors SlurryPipeConnectEvent.
-- ---------------------------------------------------------------------------
SPSPhysPipeConnectEvent = {}
local SPSPhysPipeConnectEvent_mt = Class(SPSPhysPipeConnectEvent, Event)
InitEventClass(SPSPhysPipeConnectEvent, "SPSPhysPipeConnectEvent")

function SPSPhysPipeConnectEvent.emptyNew()
    return Event.new(SPSPhysPipeConnectEvent_mt)
end

function SPSPhysPipeConnectEvent.new(pipe, endIdx, object, isPlaceable, couplingId, isLane)
    local self = SPSPhysPipeConnectEvent.emptyNew()
    self.pipe        = pipe
    self.endIdx      = endIdx
    self.object      = object
    self.isPlaceable = isPlaceable == true
    self.couplingId  = couplingId
    self.isLane      = isLane == true      -- [SPS 1.0.1.8] 80 mm lane coupler (liquid-lane registry) vs slurry coupling
    return self
end

function SPSPhysPipeConnectEvent:readStream(streamId, connection)
    self.pipe        = NetworkUtil.readNodeObject(streamId)
    self.endIdx      = streamReadUIntN(streamId, 2)
    self.object      = NetworkUtil.readNodeObject(streamId)
    self.isPlaceable = streamReadBool(streamId)
    self.couplingId  = streamReadUIntN(streamId, 8)
    self.isLane      = streamReadBool(streamId)
    self:run(connection)
end

function SPSPhysPipeConnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.pipe)
    streamWriteUIntN(streamId, self.endIdx or 1, 2)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteBool(streamId, self.isPlaceable == true)
    streamWriteUIntN(streamId, self.couplingId or 0, 8)
    streamWriteBool(streamId, self.isLane == true)
end

function SPSPhysPipeConnectEvent:run(connection)
    -- [SPS 1.0.1.8 MP] a client's request is APPLIED on the server first and rebroadcast only when it took; a
    -- refused request (busy coupling, taken slot, stale client) never reaches the other clients
    local ok = false
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyPhysPipeConnect ~= nil then
        ok = g_slurryPipeManager:applyPhysPipeConnect(self.pipe, self.endIdx, self.object, self.isPlaceable, self.couplingId, self.isLane)
    end
    if not connection:getIsServer() and ok then
        g_server:broadcastEvent(self, false, nil, self.pipe, nil, nil, true)
    end
end

function SPSPhysPipeConnectEvent.sendEvent(pipe, endIdx, object, isPlaceable, couplingId, isLane, noEventSend)
    if noEventSend == true then return end
    if g_server ~= nil then
        g_server:broadcastEvent(SPSPhysPipeConnectEvent.new(pipe, endIdx, object, isPlaceable, couplingId, isLane), nil, nil, pipe, nil, nil, true)
        return
    end
    spsSendEventToServer(SPSPhysPipeConnectEvent.new(pipe, endIdx, object, isPlaceable, couplingId, isLane))
end

SPSPhysPipeDisconnectEvent = {}
local SPSPhysPipeDisconnectEvent_mt = Class(SPSPhysPipeDisconnectEvent, Event)
InitEventClass(SPSPhysPipeDisconnectEvent, "SPSPhysPipeDisconnectEvent")

function SPSPhysPipeDisconnectEvent.emptyNew()
    return Event.new(SPSPhysPipeDisconnectEvent_mt)
end

function SPSPhysPipeDisconnectEvent.new(pipe, endIdx)
    local self = SPSPhysPipeDisconnectEvent.emptyNew()
    self.pipe   = pipe
    self.endIdx = endIdx
    return self
end

function SPSPhysPipeDisconnectEvent:readStream(streamId, connection)
    self.pipe   = NetworkUtil.readNodeObject(streamId)
    self.endIdx = streamReadUIntN(streamId, 2)
    self:run(connection)
end

function SPSPhysPipeDisconnectEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.pipe)
    streamWriteUIntN(streamId, self.endIdx or 1, 2)
end

function SPSPhysPipeDisconnectEvent:run(connection)
    -- [SPS 1.0.1.8 MP] a client's request is APPLIED on the server first and rebroadcast only when it took; a
    -- refused request (busy coupling, taken slot, stale client) never reaches the other clients
    local ok = false
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyPhysPipeDisconnect ~= nil then
        ok = g_slurryPipeManager:applyPhysPipeDisconnect(self.pipe, self.endIdx)
    end
    if not connection:getIsServer() and ok then
        g_server:broadcastEvent(self, false, nil, self.pipe, nil, nil, true)
    end
end

function SPSPhysPipeDisconnectEvent.sendEvent(pipe, endIdx, noEventSend)
    if noEventSend == true then return end
    if g_server ~= nil then
        g_server:broadcastEvent(SPSPhysPipeDisconnectEvent.new(pipe, endIdx), nil, nil, pipe, nil, nil, true)
        return
    end
    spsSendEventToServer(SPSPhysPipeDisconnectEvent.new(pipe, endIdx))
end

-- [SPS 1.0.1.8] pipe-to-pipe join (physical pipes). Same shape as SPSPhysPipeConnectEvent.
SPSPhysPipeJoinEvent = {}
local SPSPhysPipeJoinEvent_mt = Class(SPSPhysPipeJoinEvent, Event)
InitEventClass(SPSPhysPipeJoinEvent, "SPSPhysPipeJoinEvent")

function SPSPhysPipeJoinEvent.emptyNew()
    return Event.new(SPSPhysPipeJoinEvent_mt)
end

function SPSPhysPipeJoinEvent.new(pipe, endIdx, otherPipe, otherIdx)
    local self = SPSPhysPipeJoinEvent.emptyNew()
    self.pipe, self.endIdx, self.otherPipe, self.otherIdx = pipe, endIdx, otherPipe, otherIdx
    return self
end

function SPSPhysPipeJoinEvent:readStream(streamId, connection)
    self.pipe      = NetworkUtil.readNodeObject(streamId)
    self.endIdx    = streamReadUIntN(streamId, 2)
    self.otherPipe = NetworkUtil.readNodeObject(streamId)
    self.otherIdx  = streamReadUIntN(streamId, 2)
    self:run(connection)
end

function SPSPhysPipeJoinEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.pipe)
    streamWriteUIntN(streamId, self.endIdx or 1, 2)
    NetworkUtil.writeNodeObject(streamId, self.otherPipe)
    streamWriteUIntN(streamId, self.otherIdx or 1, 2)
end

function SPSPhysPipeJoinEvent:run(connection)
    -- [SPS 1.0.1.8 MP] a client's request is APPLIED on the server first and rebroadcast only when it took; a
    -- refused request (busy coupling, taken slot, stale client) never reaches the other clients
    local ok = false
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyPhysPipeJoin ~= nil then
        ok = g_slurryPipeManager:applyPhysPipeJoin(self.pipe, self.endIdx, self.otherPipe, self.otherIdx)
    end
    if not connection:getIsServer() and ok then
        g_server:broadcastEvent(self, false, nil, self.pipe, nil, nil, true)
    end
end

function SPSPhysPipeJoinEvent.sendEvent(pipe, endIdx, otherPipe, otherIdx, noEventSend)
    if noEventSend == true then return end
    if g_server ~= nil then
        g_server:broadcastEvent(SPSPhysPipeJoinEvent.new(pipe, endIdx, otherPipe, otherIdx), nil, nil, pipe, nil, nil, true)
        return
    end
    spsSendEventToServer(SPSPhysPipeJoinEvent.new(pipe, endIdx, otherPipe, otherIdx))
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Physical pipe STOWED on / taken off a vehicle's pipe holder (SPSM_PhysPipes physPipeStow / Unstow).
-- stow=true: vehicle + holderId + slotName; stow=false: unstow (vehicle nil, holderId 0, slot "").
-- ---------------------------------------------------------------------------
SPSPhysPipeStowEvent = {}
local SPSPhysPipeStowEvent_mt = Class(SPSPhysPipeStowEvent, Event)
InitEventClass(SPSPhysPipeStowEvent, "SPSPhysPipeStowEvent")

function SPSPhysPipeStowEvent.emptyNew()
    return Event.new(SPSPhysPipeStowEvent_mt)
end

function SPSPhysPipeStowEvent.new(pipe, vehicle, holderId, slotName, stow)
    local self = SPSPhysPipeStowEvent.emptyNew()
    self.pipe     = pipe
    self.vehicle  = vehicle
    self.holderId = holderId or 0
    self.slotName = slotName or ""
    self.stow     = stow == true
    return self
end

function SPSPhysPipeStowEvent:readStream(streamId, connection)
    self.pipe     = NetworkUtil.readNodeObject(streamId)
    self.vehicle  = NetworkUtil.readNodeObject(streamId)
    self.holderId = streamReadUIntN(streamId, 8)
    self.slotName = streamReadString(streamId)
    self.stow     = streamReadBool(streamId)
    self:run(connection)
end

function SPSPhysPipeStowEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.pipe)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUIntN(streamId, self.holderId or 0, 8)
    streamWriteString(streamId, self.slotName or "")
    streamWriteBool(streamId, self.stow == true)
end

function SPSPhysPipeStowEvent:run(connection)
    -- [SPS 1.0.1.8 MP] a client's request is APPLIED on the server first and rebroadcast only when it took; a
    -- refused request (busy coupling, taken slot, stale client) never reaches the other clients
    local ok = false
    if g_slurryPipeManager ~= nil then
        if self.stow then
            if g_slurryPipeManager.applyPhysPipeStow ~= nil then
                ok = g_slurryPipeManager:applyPhysPipeStow(self.pipe, self.vehicle, self.holderId, self.slotName)
            end
        elseif g_slurryPipeManager.applyPhysPipeUnstow ~= nil then
            ok = g_slurryPipeManager:applyPhysPipeUnstow(self.pipe)
        end
    end
    if not connection:getIsServer() and ok then
        g_server:broadcastEvent(self, false, nil, self.pipe, nil, nil, true)
    end
end

function SPSPhysPipeStowEvent.sendEvent(pipe, vehicle, holderId, slotName, stow, noEventSend)
    if noEventSend == true then return end
    if g_server ~= nil then
        g_server:broadcastEvent(SPSPhysPipeStowEvent.new(pipe, vehicle, holderId, slotName, stow), nil, nil, pipe, nil, nil, true)
        return
    end
    spsSendEventToServer(SPSPhysPipeStowEvent.new(pipe, vehicle, holderId, slotName, stow))
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] "Free stuck pipe": client -> server only. The server lets the held pipe ignore vehicles until it is
-- let go (SPSHoseItem.spsFreeHeldPipe); collision lives on the server, so nothing is rebroadcast.
-- ---------------------------------------------------------------------------
SPSPhysPipeFreeEvent = {}
local SPSPhysPipeFreeEvent_mt = Class(SPSPhysPipeFreeEvent, Event)
InitEventClass(SPSPhysPipeFreeEvent, "SPSPhysPipeFreeEvent")

function SPSPhysPipeFreeEvent.emptyNew()
    return Event.new(SPSPhysPipeFreeEvent_mt)
end

function SPSPhysPipeFreeEvent.new(pipe)
    local self = SPSPhysPipeFreeEvent.emptyNew()
    self.pipe = pipe
    return self
end

function SPSPhysPipeFreeEvent:readStream(streamId, connection)
    self.pipe = NetworkUtil.readNodeObject(streamId)
    self:run(connection)
end

function SPSPhysPipeFreeEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.pipe)
end

function SPSPhysPipeFreeEvent:run(connection)
    if connection:getIsServer() or self.pipe == nil or g_currentMission == nil then return end   -- server-bound only
    local mission = g_currentMission
    if mission.accessHandler ~= nil and not mission.accessHandler:canFarmAccess(mission:getFarmId(connection), self.pipe) then
        return
    end
    SPSHoseItem.spsFreeHeldPipe(self.pipe)
end

function SPSPhysPipeFreeEvent.sendEvent(pipe)
    spsSendEventToServer(SPSPhysPipeFreeEvent.new(pipe))
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] SPS Docking Station placed on / taken off a vehicle's docking station holder (SPSM_PhysPipes
-- dsStow / dsUnstow). stow=true: vehicle + holderId; stow=false: off (vehicle nil, holderId 0).
-- ---------------------------------------------------------------------------
SPSDsStowEvent = {}
local SPSDsStowEvent_mt = Class(SPSDsStowEvent, Event)
InitEventClass(SPSDsStowEvent, "SPSDsStowEvent")

function SPSDsStowEvent.emptyNew()
    return Event.new(SPSDsStowEvent_mt)
end

function SPSDsStowEvent.new(station, vehicle, holderId, stow)
    local self = SPSDsStowEvent.emptyNew()
    self.station  = station
    self.vehicle  = vehicle
    self.holderId = holderId or 0
    self.stow     = stow == true
    return self
end

function SPSDsStowEvent:readStream(streamId, connection)
    self.station  = NetworkUtil.readNodeObject(streamId)
    self.vehicle  = NetworkUtil.readNodeObject(streamId)
    self.holderId = streamReadUIntN(streamId, 8)
    self.stow     = streamReadBool(streamId)
    self:run(connection)
end

function SPSDsStowEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.station)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUIntN(streamId, self.holderId or 0, 8)
    streamWriteBool(streamId, self.stow == true)
end

function SPSDsStowEvent:run(connection)
    -- [SPS 1.0.1.8 MP] a client's request is APPLIED on the server first and rebroadcast only when it took; a
    -- refused request (busy coupling, taken slot, stale client) never reaches the other clients
    local ok = false
    if g_slurryPipeManager ~= nil then
        if self.stow then
            if g_slurryPipeManager.applyDsStow ~= nil then
                ok = g_slurryPipeManager:applyDsStow(self.station, self.vehicle, self.holderId)
            end
        elseif g_slurryPipeManager.applyDsUnstow ~= nil then
            ok = g_slurryPipeManager:applyDsUnstow(self.station)
        end
    end
    if not connection:getIsServer() and ok then
        g_server:broadcastEvent(self, false, nil, self.station, nil, nil, true)
    end
end

function SPSDsStowEvent.sendEvent(station, vehicle, holderId, stow, noEventSend)
    if noEventSend == true then return end
    if g_server ~= nil then
        g_server:broadcastEvent(SPSDsStowEvent.new(station, vehicle, holderId, stow), nil, nil, station, nil, nil, true)
        return
    end
    spsSendEventToServer(SPSDsStowEvent.new(station, vehicle, holderId, stow))
end
