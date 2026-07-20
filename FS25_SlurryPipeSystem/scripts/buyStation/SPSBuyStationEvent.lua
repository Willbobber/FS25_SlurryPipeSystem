-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9.27
--
-- SPSBuyStationEvent.lua
-- ---------------------------------------------------------------------------
-- Syncs the selected sold fillType of a buying-station placeable (the single
-- switchable coupler). Mirrors SPSSeparatorEvent.
--   reqType 0 = set-type request   (client -> server)
--   reqType 1 = authoritative state (server -> clients)
-- Fill type travels as its NAME (streamWriteString / streamReadString —
-- verified vanilla primitives, PlaceableNameEvent.lua) so no bit-width
-- assumption about fillType indices is needed.
-- Also sent per station in the JIP join dump (SlurryPipeManager:
-- sendFullStateToConnection pass 12).
-- ---------------------------------------------------------------------------

print("[SPS BUILD] SPSBuyStationEvent 1.0.0.9.27 loaded")

SPSBuyStationEvent = {}

-- Debug: central registry channel "SPSBuyStationEvent" (SPSDebugConfig).
-- Class field pushed by applyAll(); call-time isOn() gives instant toggling.
-- Ships false.
SPSBuyStationEvent.DEBUG = false
local function log(fmt, ...)
    if not (SPSBuyStationEvent.DEBUG
        or (SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSBuyStationEvent"))) then
        return
    end
    if select("#", ...) > 0 then
        print("[SPS BUY EVT] " .. string.format(fmt, ...))
    else
        print("[SPS BUY EVT] " .. tostring(fmt))
    end
end

local SPSBuyStationEvent_mt = Class(SPSBuyStationEvent, Event)
InitEventClass(SPSBuyStationEvent, "SPSBuyStationEvent")

SPSBuyStationEvent.REQ_SETTYPE = 0
SPSBuyStationEvent.STATE       = 1

function SPSBuyStationEvent.emptyNew()
    return Event.new(SPSBuyStationEvent_mt)
end

function SPSBuyStationEvent.new(reqType, placeable, fillTypeName)
    local self         = SPSBuyStationEvent.emptyNew()
    self.reqType       = reqType
    self.placeable     = placeable
    self.fillTypeName  = fillTypeName or ""
    return self
end

function SPSBuyStationEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.reqType, 1)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteString(streamId, self.fillTypeName)
end

function SPSBuyStationEvent:readStream(streamId, connection)
    self.reqType      = streamReadUIntN(streamId, 1)
    self.placeable    = NetworkUtil.readNodeObject(streamId)
    self.fillTypeName = streamReadString(streamId)
    self:run(connection)
end

function SPSBuyStationEvent:run(connection)
    if self.placeable == nil or not self.placeable:getIsSynchronized() then return end
    local mgr = g_slurryPipeManager
    if mgr == nil or mgr.applyBuyStationType == nil then return end
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(self.fillTypeName)
    if fillTypeIndex == nil then return end

    log("run: reqType=%d fillType=%s (server=%s)",
        self.reqType, tostring(self.fillTypeName), tostring(g_server ~= nil))

    if self.reqType == SPSBuyStationEvent.STATE then
        -- Server -> client authoritative state: apply, never re-broadcast.
        mgr:applyBuyStationType(self.placeable, fillTypeIndex, false)
    elseif self.reqType == SPSBuyStationEvent.REQ_SETTYPE then
        if not connection:getIsServer() then
            -- We are the server: apply (validated inside) and broadcast STATE.
            mgr:applyBuyStationType(self.placeable, fillTypeIndex, true)
        end
    end
end

-- Client -> server request.
function SPSBuyStationEvent.sendTypeRequest(placeable, fillTypeName)
    if g_client ~= nil and g_server == nil then
        g_client:getServerConnection():sendEvent(
            SPSBuyStationEvent.new(SPSBuyStationEvent.REQ_SETTYPE, placeable, fillTypeName))
    end
end

-- Server -> all clients: authoritative state.
function SPSBuyStationEvent.sendState(placeable, fillTypeIndex)
    if g_server ~= nil and placeable ~= nil then
        local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
        if name == nil then return end
        log("sendState: %s -> %s", tostring(placeable.configFileName), tostring(name))
        g_server:broadcastEvent(
            SPSBuyStationEvent.new(SPSBuyStationEvent.STATE, placeable, name),
            nil, nil, placeable)
    end
end
