-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9.27
--
-- SPSBuyStationActivatable.lua
-- ---------------------------------------------------------------------------
-- Walk-up type switch for a buying-station placeable: cycles the sold
-- fillType of the single switchable coupler (e.g. LIQUIDMANURE <->
-- DIGESTATE). Standard IActivatable contract (activateText + run on the
-- default activate input) — same pattern as SPSPipeActivatable's "Connect
-- pipe" prompt, so NO new modDesc <action> is required.
--
-- Anchored on the config-declared switch node (switchNodeName in the bundled
-- fillPoints.xml — the panel by the electrical box); falls back to the first
-- store coupler mount if none is declared. Only shown when the station sells
-- more than one type.
--
-- Server-authoritative: run() routes through
-- SlurryPipeManager:requestBuyStationTypeToggle (server applies directly;
-- a client sends SPSBuyStationEvent.REQ_SETTYPE and the prompt text updates
-- when the STATE broadcast lands).
-- ---------------------------------------------------------------------------

print("[SPS BUILD] SPSBuyStationActivatable 1.0.0.9.27 loaded")

SPSBuyStationActivatable = {}
SPSBuyStationActivatable.__index = SPSBuyStationActivatable

-- Debug: central registry channel "SPSBuyStationActivatable" (SPSDebugConfig).
-- Class field pushed by applyAll(); call-time isOn() gives instant toggling.
-- Ships false.
SPSBuyStationActivatable.DEBUG = false
local function log(fmt, ...)
    if not (SPSBuyStationActivatable.DEBUG
        or (SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSBuyStationActivatable"))) then
        return
    end
    if select("#", ...) > 0 then
        print("[SPS BUY ACT] " .. string.format(fmt, ...))
    else
        print("[SPS BUY ACT] " .. tostring(fmt))
    end
end

function SPSBuyStationActivatable.new(pEntry, switchNode, radius)
    local self        = setmetatable({}, SPSBuyStationActivatable)
    self.pEntry       = pEntry
    self.switchNode   = switchNode
    self.radius       = radius or 3.0
    self.activateText = ""
    return self
end

function SPSBuyStationActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

local function getAnchorNode(self)
    local node = self.switchNode
    if node ~= nil and node ~= 0 and entityExists(node) then return node end
    -- Fallback: first store coupler mount.
    local pEntry = self.pEntry
    if pEntry ~= nil and pEntry.storeCouplings ~= nil then
        local sc = pEntry.storeCouplings[1]
        if sc ~= nil and sc.mountNode ~= nil and sc.mountNode ~= 0
        and entityExists(sc.mountNode) then
            return sc.mountNode
        end
    end
    return nil
end

local function getSourceEntry(self)
    local pEntry = self.pEntry
    if pEntry == nil then return nil end
    local se = pEntry.sourceEntry
    if se == nil or se.type ~= SPS_SOURCE_TYPE_BUYING_STATION then return nil end
    return se
end

function SPSBuyStationActivatable:getIsActivatable()
    if g_localPlayer == nil then return false end
    local se = getSourceEntry(self)
    -- Nothing to switch with a single sold type.
    if se == nil or se.fillTypes == nil or #se.fillTypes < 2 then return false end
    local node = getAnchorNode(self)
    if node == nil then return false end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(node)
    if MathUtil.vector3Length(px - cx, py - cy, pz - cz) > self.radius then
        return false
    end
    self.activateText = self:_buildText(se)
    return true
end

function SPSBuyStationActivatable:getDistance(posX, posY, posZ)
    local node = getAnchorNode(self)
    if node == nil then return math.huge end
    local cx, cy, cz = getWorldTranslation(node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSBuyStationActivatable:activate()
end

function SPSBuyStationActivatable:deactivate()
end

function SPSBuyStationActivatable:update(dt)
    local se = getSourceEntry(self)
    if se ~= nil then
        self.activateText = self:_buildText(se)
    end
end

function SPSBuyStationActivatable:run()
    local pEntry = self.pEntry
    if pEntry == nil or pEntry.placeable == nil then return end
    local mgr = g_slurryPipeManager
    if mgr == nil or mgr.requestBuyStationTypeToggle == nil then return end
    log("run: toggle requested for %s", tostring(pEntry.placeable.configFileName))
    mgr:requestBuyStationTypeToggle(pEntry.placeable)
end

-- "Buying: <current> - switch to <next>"
function SPSBuyStationActivatable:_buildText(se)
    local cur     = se.fillType
    local curIdx  = 1
    for i, ft in ipairs(se.fillTypes) do
        if ft == cur then curIdx = i break end
    end
    local nextFt    = se.fillTypes[(curIdx % #se.fillTypes) + 1]
    local curTitle  = g_fillTypeManager:getFillTypeTitleByIndex(cur)    or "?"
    local nextTitle = g_fillTypeManager:getFillTypeTitleByIndex(nextFt) or "?"
    return string.format(g_i18n:getText("action_spsBuyStationSwitch"), curTitle, nextTitle)
end
