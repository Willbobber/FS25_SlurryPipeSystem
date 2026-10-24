-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9.21
--
-- SPSSeparatorActivatable.lua
-- ---------------------------------------------------------------------------
-- Walk-up control point for a fixed slurry separator. Mirrors
-- SPSFixedAgitatorActivatable. Shown when the player is within interactRadius
-- of the separator's panel node (falls back to the IN coupling mount).
--
--   SPS_TOGGLE_SEPARATOR    -> start / stop
--   SPS_SEPARATOR_TIGHTNESS -> cycle screw tightness 0/25/50/75/100 %
--
-- If either binding is absent from modDesc the registration returns nil and
-- that prompt simply never shows (fail-safe, no error). The proper control
-- panel with live readouts replaces/extends this later; the state it needs
-- (statIntakeLph, statManureLph, tightness, blockReason) is already synced.
-- ---------------------------------------------------------------------------

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSSeparatorActivatable 1.0.0.9.21 loaded") end

SPSSeparatorActivatable = {}
SPSSeparatorActivatable.__index = SPSSeparatorActivatable

-- Debug: central registry channel "SPSSeparatorActivatable" (SPSDebugConfig).
-- Class field pushed by applyAll(); call-time isOn() gives instant toggling.
-- Ships false.
SPSSeparatorActivatable.DEBUG = false
local function log(fmt, ...)
    if not (SPSSeparatorActivatable.DEBUG
        or (SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSSeparatorActivatable"))) then
        return
    end
    if select("#", ...) > 0 then
        print("[SPS SEP ACT] " .. string.format(fmt, ...))
    else
        print("[SPS SEP ACT] " .. tostring(fmt))
    end
end

function SPSSeparatorActivatable.new(sep, radius)
    local self        = setmetatable({}, SPSSeparatorActivatable)
    self.sep          = sep
    self.radius       = radius or 4.0
    self.activateText = ""
    self._eventIds    = {}
    return self
end

function SPSSeparatorActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

local function getPanelNode(self)
    local sep = self.sep
    if sep == nil then return nil end
    local node = sep.panelNode
    if node == nil or node == 0 or not entityExists(node) then return nil end
    return node
end

function SPSSeparatorActivatable:getIsActivatable()
    if SPSAccess ~= nil and not SPSAccess.localCanUse(self.sep) then return false end   -- [SPS 1.0.1.8] farm permission
    if g_localPlayer == nil then return false end
    local node = getPanelNode(self)
    if node == nil then return false end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(node)
    return MathUtil.vector3Length(px - cx, py - cy, pz - cz) <= self.radius
end

function SPSSeparatorActivatable:getDistance(posX, posY, posZ)
    local node = getPanelNode(self)
    if node == nil then return math.huge end
    local cx, cy, cz = getWorldTranslation(node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSSeparatorActivatable:activate()
    self.activateText = ""
end

function SPSSeparatorActivatable:deactivate()
end

function SPSSeparatorActivatable:update(dt)
    if self._eventIds == nil then return end
    if self._eventIds.toggle ~= nil then
        g_inputBinding:setActionEventText(self._eventIds.toggle, self:_buildToggleText())
    end
    if self._eventIds.tightness ~= nil then
        g_inputBinding:setActionEventText(self._eventIds.tightness, self:_buildTightnessText())
    end
end

function SPSSeparatorActivatable:run()
end

function SPSSeparatorActivatable:registerCustomInput(inputContext)
    self._eventIds = {}

    if InputAction.SPS_TOGGLE_SEPARATOR ~= nil then
        local _, id = g_inputBinding:registerActionEvent(
            InputAction.SPS_TOGGLE_SEPARATOR, self,
            function(target, actionName, inputValue, callbackState, isAnalog)
                if inputValue > 0 then target:_onToggle() end
            end,
            false, true, false, true, nil, true, false)
        if id ~= nil then
            g_inputBinding:setActionEventText(id, self:_buildToggleText())
            g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
            g_inputBinding:setActionEventTextVisibility(id, true)
            self._eventIds.toggle = id
        end
    end

    if InputAction.SPS_SEPARATOR_TIGHTNESS ~= nil then
        local _, id = g_inputBinding:registerActionEvent(
            InputAction.SPS_SEPARATOR_TIGHTNESS, self,
            function(target, actionName, inputValue, callbackState, isAnalog)
                if inputValue > 0 then target:_onTightness() end
            end,
            false, true, false, true, nil, true, false)
        if id ~= nil then
            g_inputBinding:setActionEventText(id, self:_buildTightnessText())
            g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
            g_inputBinding:setActionEventTextVisibility(id, true)
            self._eventIds.tightness = id
        end
    end
end

function SPSSeparatorActivatable:removeCustomInput()
    if self._eventIds ~= nil then
        for _, id in pairs(self._eventIds) do
            g_inputBinding:removeActionEvent(id)
        end
        self._eventIds = {}
    end
end

function SPSSeparatorActivatable:_onToggle()
    if self.sep ~= nil and SPSSeparator ~= nil then
        log("toggle pressed (currently on=%s)", tostring(self.sep.isOn))
        SPSSeparator.requestToggle(self.sep)
    end
end

function SPSSeparatorActivatable:_onTightness()
    if self.sep ~= nil and SPSSeparator ~= nil then
        log("tightness pressed (currently %.2f)", self.sep.tightness)
        SPSSeparator.requestCycleTightness(self.sep)
    end
end

function SPSSeparatorActivatable:_buildToggleText()
    if self.sep ~= nil and self.sep.isOn then
        return g_i18n:getText("action_spsSeparatorOff")
    end
    return g_i18n:getText("action_spsSeparatorOn")
end

function SPSSeparatorActivatable:_buildTightnessText()
    local pct = 0
    if self.sep ~= nil then
        pct = math.floor(self.sep.tightness * 100 + 0.5)
    end
    return string.format(g_i18n:getText("action_spsSeparatorTightness"), pct)
end
