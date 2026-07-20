-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9.21
--
-- SPSSeparatorEvent.lua
-- ---------------------------------------------------------------------------
-- Syncs fixed-separator state (mirrors SPSFixedAgitatorEvent).
--   reqType 0 = on/off request           (client -> server)
--   reqType 1 = tightness request        (client -> server)
--   reqType 2 = authoritative state      (server -> clients):
--               {placeable, isOn, tightness, blockReason, lifetimeManure,
--                statIntakeLph, statManureLph}
-- The server applies requests via SPSSeparator and broadcasts the result.
-- Also sent per-separator in the JIP join dump (wrap in SPSSeparator.lua).
-- ---------------------------------------------------------------------------

print("[SPS BUILD] SPSSeparatorEvent 1.0.0.9.21 loaded")

SPSSeparatorEvent = {}

-- Debug: central registry channel "SPSSeparatorEvent" (SPSDebugConfig).
-- Class field pushed by applyAll(); call-time isOn() gives instant toggling.
-- Ships false.
SPSSeparatorEvent.DEBUG = false
local function log(fmt, ...)
    if not (SPSSeparatorEvent.DEBUG
        or (SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSSeparatorEvent"))) then
        return
    end
    if select("#", ...) > 0 then
        print("[SPS SEP EVT] " .. string.format(fmt, ...))
    else
        print("[SPS SEP EVT] " .. tostring(fmt))
    end
end

local SPSSeparatorEvent_mt = Class(SPSSeparatorEvent, Event)
InitEventClass(SPSSeparatorEvent, "SPSSeparatorEvent")

SPSSeparatorEvent.REQ_TOGGLE    = 0
SPSSeparatorEvent.REQ_TIGHTNESS = 1
SPSSeparatorEvent.STATE         = 2

function SPSSeparatorEvent.emptyNew()
    return Event.new(SPSSeparatorEvent_mt)
end

function SPSSeparatorEvent.new(reqType, placeable, isOn, tightness, reason, lifetime, lphIn, lphOut)
    local self      = SPSSeparatorEvent.emptyNew()
    self.reqType    = reqType
    self.placeable  = placeable
    self.isOn       = isOn == true
    self.tightness  = tightness or 0
    self.reason     = reason or 0
    self.lifetime   = lifetime or 0
    self.lphIn      = lphIn or 0
    self.lphOut     = lphOut or 0
    return self
end

-- Convenience: STATE event built straight from a live separator table.
function SPSSeparatorEvent.newState(sep)
    return SPSSeparatorEvent.new(SPSSeparatorEvent.STATE, sep.placeable,
        sep.isOn, sep.tightness, sep.blockReason, sep.lifetimeManure,
        sep.statIntakeLph, sep.statManureLph)
end

function SPSSeparatorEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.reqType, 2)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteBool(streamId, self.isOn)
    -- Tightness as whole percent 0..100.
    streamWriteUIntN(streamId, math.floor(self.tightness * 100 + 0.5), 7)
    streamWriteUIntN(streamId, self.reason, 4)
    streamWriteFloat32(streamId, self.lifetime)
    streamWriteFloat32(streamId, self.lphIn)
    streamWriteFloat32(streamId, self.lphOut)
end

function SPSSeparatorEvent:readStream(streamId, connection)
    self.reqType   = streamReadUIntN(streamId, 2)
    self.placeable = NetworkUtil.readNodeObject(streamId)
    self.isOn      = streamReadBool(streamId)
    self.tightness = streamReadUIntN(streamId, 7) / 100.0
    self.reason    = streamReadUIntN(streamId, 4)
    self.lifetime  = streamReadFloat32(streamId)
    self.lphIn     = streamReadFloat32(streamId)
    self.lphOut    = streamReadFloat32(streamId)
    self:run(connection)
end

function SPSSeparatorEvent:run(connection)
    if self.placeable == nil or not self.placeable:getIsSynchronized() then return end
    if SPSSeparator == nil then return end
    local mgr = g_slurryPipeManager
    if mgr == nil then return end
    local sep = SPSSeparator.findSeparatorByPlaceable(mgr, self.placeable)
    if sep == nil then return end

    log("run: reqType=%d isOn=%s tightness=%.2f reason=%d (server=%s)",
        self.reqType, tostring(self.isOn), self.tightness, self.reason,
        tostring(g_server ~= nil))
    if self.reqType == SPSSeparatorEvent.STATE then
        SPSSeparator.applyState(self.placeable, self.isOn, self.tightness,
            self.reason, self.lifetime, self.lphIn, self.lphOut)
    elseif self.reqType == SPSSeparatorEvent.REQ_TOGGLE then
        if not connection:getIsServer() then
            -- We are the server: apply (which broadcasts the resulting STATE).
            SPSSeparator.applyToggle(sep, self.isOn)
        end
    elseif self.reqType == SPSSeparatorEvent.REQ_TIGHTNESS then
        if not connection:getIsServer() then
            SPSSeparator.applyTightness(sep, self.tightness)
        end
    end
end

-- Client -> server requests.
function SPSSeparatorEvent.sendToggleRequest(placeable, isOn)
    if g_client ~= nil and g_server == nil then
        g_client:getServerConnection():sendEvent(
            SPSSeparatorEvent.new(SPSSeparatorEvent.REQ_TOGGLE, placeable, isOn, 0, 0, 0, 0, 0))
    end
end

function SPSSeparatorEvent.sendTightnessRequest(placeable, tightness)
    if g_client ~= nil and g_server == nil then
        g_client:getServerConnection():sendEvent(
            SPSSeparatorEvent.new(SPSSeparatorEvent.REQ_TIGHTNESS, placeable, false, tightness, 0, 0, 0, 0))
    end
end

-- Server -> all clients: authoritative state.
function SPSSeparatorEvent.sendState(sep)
    if g_server ~= nil and sep ~= nil and sep.placeable ~= nil then
        log("sendState: isOn=%s tightness=%.2f reason=%d lifetime=%.0f",
            tostring(sep.isOn), sep.tightness, sep.blockReason, sep.lifetimeManure)
        g_server:broadcastEvent(SPSSeparatorEvent.newState(sep), nil, nil, sep.placeable)
    end
end
