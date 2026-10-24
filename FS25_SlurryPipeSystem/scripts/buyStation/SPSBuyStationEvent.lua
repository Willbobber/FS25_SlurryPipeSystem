-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.2
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
-- [SPS 1.0.1.2] +1 bit systemId: 0 = slurry buy station (registeredPlaceables),
-- 1 = sprayer buy station (registeredSprayerPlaceables) — one placeable can
-- carry both systems, so the event must address exactly one. Every legacy
-- caller/constructor without the argument defaults to 0 (slurry).
-- Also sent per station in the JIP join dump (SlurryPipeManager:
-- sendFullStateToConnection pass 12).
-- ---------------------------------------------------------------------------

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSBuyStationEvent 1.0.1.2 loaded") end

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

function SPSBuyStationEvent.new(reqType, placeable, fillTypeName, systemId)
    local self         = SPSBuyStationEvent.emptyNew()
    self.reqType       = reqType
    self.placeable     = placeable
    self.fillTypeName  = fillTypeName or ""
    -- [SPS 1.0.1.2] 0 = slurry, 1 = sprayer; nil (legacy callers) = slurry.
    self.systemId      = systemId or 0
    return self
end

function SPSBuyStationEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.reqType, 1)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteString(streamId, self.fillTypeName)
    -- [SPS 1.0.1.2] Target system (0 slurry / 1 sprayer).
    streamWriteUIntN(streamId, self.systemId or 0, 1)
end

function SPSBuyStationEvent:readStream(streamId, connection)
    self.reqType      = streamReadUIntN(streamId, 1)
    self.placeable    = NetworkUtil.readNodeObject(streamId)
    self.fillTypeName = streamReadString(streamId)
    -- [SPS 1.0.1.2] Target system (0 slurry / 1 sprayer).
    self.systemId     = streamReadUIntN(streamId, 1)
    self:run(connection)
end

function SPSBuyStationEvent:run(connection)
    if self.placeable == nil or not self.placeable:getIsSynchronized() then return end
    local mgr = g_slurryPipeManager
    if mgr == nil or mgr.applyBuyStationType == nil then return end
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(self.fillTypeName)
    if fillTypeIndex == nil then return end

    log("run: reqType=%d fillType=%s systemId=%s (server=%s)",
        self.reqType, tostring(self.fillTypeName), tostring(self.systemId), tostring(g_server ~= nil))

    if self.reqType == SPSBuyStationEvent.STATE then
        -- Server -> client authoritative state: apply, never re-broadcast.
        mgr:applyBuyStationType(self.placeable, fillTypeIndex, false, self.systemId)
    elseif self.reqType == SPSBuyStationEvent.REQ_SETTYPE then
        if not connection:getIsServer() then
            -- We are the server: apply (validated inside) and broadcast STATE.
            mgr:applyBuyStationType(self.placeable, fillTypeIndex, true, self.systemId)
        end
    end
end

-- Client -> server request.
function SPSBuyStationEvent.sendTypeRequest(placeable, fillTypeName, systemId)
    if g_client ~= nil and g_server == nil then
        g_client:getServerConnection():sendEvent(
            SPSBuyStationEvent.new(SPSBuyStationEvent.REQ_SETTYPE, placeable, fillTypeName, systemId))
    end
end

-- Server -> all clients: authoritative state.
function SPSBuyStationEvent.sendState(placeable, fillTypeIndex, systemId)
    if g_server ~= nil and placeable ~= nil then
        local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
        if name == nil then return end
        log("sendState: %s [system=%s] -> %s", tostring(placeable.configFileName),
            tostring(systemId or 0), tostring(name))
        g_server:broadcastEvent(
            SPSBuyStationEvent.new(SPSBuyStationEvent.STATE, placeable, name, systemId),
            nil, nil, placeable, nil, nil, true)
    end
end
