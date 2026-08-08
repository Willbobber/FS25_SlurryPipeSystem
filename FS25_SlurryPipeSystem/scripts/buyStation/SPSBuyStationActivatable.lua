-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.3
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
--
-- [SPS 1.0.1.2] Shared between BOTH station kinds via systemId (0 = slurry
-- entry from registeredPlaceables, 1 = sprayer entry from
-- registeredSprayerPlaceables — constructed in registerSprayerPlaceable). The
-- entry tables differ only in placeable field naming (pEntry.placeable vs
-- entry.object) and coupler list naming (storeCouplings vs couplings); both
-- are handled below so one class serves both.
--
-- [SPS 1.0.1.2] Reverse cycling: holding SHIFT while activating steps the
-- config-declared order BACKWARDS (overshoot recovery on long cycles). Uses
-- the engine-level Input.isKeyPressed built-in (engine API, not a vanilla
-- script) behind nil-guards — if the engine ever drops it, behaviour
-- degrades to forward-only instead of erroring. The prompt text flips live
-- to "switch to <previous>" while Shift is held (getIsActivatable/update
-- rebuild the text every frame).
-- ---------------------------------------------------------------------------

print("[SPS BUILD] SPSBuyStationActivatable 1.0.1.3 loaded")

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

function SPSBuyStationActivatable.new(pEntry, switchNode, radius, systemId)
    local self        = setmetatable({}, SPSBuyStationActivatable)
    self.pEntry       = pEntry
    self.switchNode   = switchNode
    self.radius       = radius or 3.0
    -- [SPS 1.0.1.2] 0 = slurry station, 1 = sprayer station; nil (legacy
    -- slurry construction site in registerPlaceable) = 0.
    self.systemId     = systemId or 0
    self.activateText = ""
    return self
end

-- [SPS 1.0.1.2] True while either Shift key is held. Engine built-in behind
-- nil-guards; any missing symbol = false (forward-only cycling).
local function isShiftDown()
    if Input == nil or Input.isKeyPressed == nil then return false end
    if Input.KEY_lshift ~= nil and Input.isKeyPressed(Input.KEY_lshift) then return true end
    if Input.KEY_rshift ~= nil and Input.isKeyPressed(Input.KEY_rshift) then return true end
    return false
end

function SPSBuyStationActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

local function getAnchorNode(self)
    local node = self.switchNode
    if node ~= nil and node ~= 0 and entityExists(node) then return node end
    -- Fallback: first store coupler mount. [SPS 1.0.1.2] Sprayer entries hold
    -- their couplers in .couplings (registerSprayerPlaceable) — same shape.
    local pEntry = self.pEntry
    if pEntry ~= nil and pEntry.storeCouplings ~= nil then
        local sc = pEntry.storeCouplings[1]
        if sc ~= nil and sc.mountNode ~= nil and sc.mountNode ~= 0
        and entityExists(sc.mountNode) then
            return sc.mountNode
        end
    end
    if pEntry ~= nil and pEntry.couplings ~= nil then
        local sc = pEntry.couplings[1]
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
    -- [SPS 1.0.1.3] Sprayer station held-type lock: a PART-FULL connected
    -- sprayer dedicates the station to its held liquid — hide the switch
    -- prompt entirely (the server refuses the switch anyway; hiding keeps the
    -- prompt honest). Connection state + fill levels are client-synced, so
    -- this reads correctly on every machine.
    if self.systemId == 1 then
        local mgr = g_slurryPipeManager
        local pEntry = self.pEntry
        local placeable = pEntry ~= nil and (pEntry.placeable or pEntry.object) or nil
        if mgr ~= nil and mgr.getSprayerBuyStationHeldType ~= nil and placeable ~= nil then
            if mgr:getSprayerBuyStationHeldType(placeable) ~= nil then return false end
        end
    end
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
    if pEntry == nil then return end
    -- [SPS 1.0.1.2] Slurry entries key the placeable as .placeable, sprayer
    -- entries as .object.
    local placeable = pEntry.placeable or pEntry.object
    if placeable == nil then return end
    local mgr = g_slurryPipeManager
    if mgr == nil or mgr.requestBuyStationTypeToggle == nil then return end
    local backwards = isShiftDown()
    log("run: toggle requested for %s (system=%s backwards=%s)",
        tostring(placeable.configFileName), tostring(self.systemId), tostring(backwards))
    mgr:requestBuyStationTypeToggle(placeable, self.systemId, backwards)
end

-- "Buying: <current> - switch to <next>"
-- [SPS 1.0.1.2] While Shift is held the target shown (and stepped to on
-- activate) is the PREVIOUS type in the cycle — same l10n key, second
-- argument swapped, so no new translations are needed.
function SPSBuyStationActivatable:_buildText(se)
    local cur     = se.fillType
    local curIdx  = 1
    for i, ft in ipairs(se.fillTypes) do
        if ft == cur then curIdx = i break end
    end
    local n = #se.fillTypes
    local nextFt
    if isShiftDown() then
        nextFt = se.fillTypes[((curIdx - 2) % n) + 1]
    else
        nextFt = se.fillTypes[(curIdx % n) + 1]
    end
    local curTitle  = g_fillTypeManager:getFillTypeTitleByIndex(cur)    or "?"
    local nextTitle = g_fillTypeManager:getFillTypeTitleByIndex(nextFt) or "?"
    return string.format(g_i18n:getText("action_spsBuyStationSwitch"), curTitle, nextTitle)
end
