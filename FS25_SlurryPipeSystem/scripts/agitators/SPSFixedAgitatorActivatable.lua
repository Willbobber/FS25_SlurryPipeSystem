-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4
--
-- SPSFixedAgitatorActivatable.lua
-- ---------------------------------------------------------------------------
-- Walk-up connect/disconnect for a placeable fixed agitator. Mirrors
-- SPSPumpControlActivatable. Shown when the player is near the PTO node AND
-- either already connected (offer disconnect) or a correctly-parked tractor is
-- present (offer connect). The connect itself is server-authoritative via
-- SPSFixedAgitator.requestConnect.
--
-- Uses InputAction.SPS_TOGGLE_AGITATOR. If that binding is absent from
-- modDesc the registration returns nil and the prompt simply never shows
-- (fail-safe, no error).
-- ---------------------------------------------------------------------------

SPSFixedAgitatorActivatable = {}
SPSFixedAgitatorActivatable.__index = SPSFixedAgitatorActivatable

function SPSFixedAgitatorActivatable.new(pEntry, radius)
    local self        = setmetatable({}, SPSFixedAgitatorActivatable)
    self.pEntry       = pEntry
    self.radius       = radius or 3.0
    self.activateText = ""
    self._eventIds    = {}
    return self
end

function SPSFixedAgitatorActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

local function getFA(self)
    return self.pEntry ~= nil and self.pEntry.fixedAgitator or nil
end

local function getProxNode(fa)
    if fa == nil then return nil end
    return fa.inputNode or fa.distanceNode
end

function SPSFixedAgitatorActivatable:getIsActivatable()
    if g_localPlayer == nil then return false end
    local fa = getFA(self)
    if fa == nil then return false end
    local node = getProxNode(fa)
    if node == nil or node == 0 or not entityExists(node) then return false end

    -- Proximity.
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(node)
    if MathUtil.vector3Length(px - cx, py - cy, pz - cz) > self.radius then return false end

    -- Connected -> always offer disconnect. Not connected -> only when a valid
    -- candidate is parked in range.
    if fa.connectedVehicle ~= nil then return true end
    local cand = SPSFixedAgitator.pickCandidate(fa)
    return cand ~= nil
end

function SPSFixedAgitatorActivatable:getDistance(posX, posY, posZ)
    local fa = getFA(self)
    local node = getProxNode(fa)
    if node == nil or node == 0 or not entityExists(node) then return math.huge end
    local cx, cy, cz = getWorldTranslation(node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSFixedAgitatorActivatable:activate()
    self.activateText = ""
end

function SPSFixedAgitatorActivatable:deactivate()
end

function SPSFixedAgitatorActivatable:update(dt)
    if self._eventIds == nil then return end
    if self._eventIds.toggle ~= nil then
        g_inputBinding:setActionEventText(self._eventIds.toggle, self:_buildText())
    end
end

function SPSFixedAgitatorActivatable:run()
end

function SPSFixedAgitatorActivatable:registerCustomInput(inputContext)
    self._eventIds = {}
    if InputAction.SPS_TOGGLE_AGITATOR == nil then return end

    local _, id = g_inputBinding:registerActionEvent(
        InputAction.SPS_TOGGLE_AGITATOR, self,
        function(target, actionName, inputValue, callbackState, isAnalog)
            if inputValue > 0 then target:_onToggle() end
        end,
        false, true, false, true, nil, true, false)
    if id ~= nil then
        g_inputBinding:setActionEventText(id, self:_buildText())
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(id, true)
        self._eventIds.toggle = id
    end
end

function SPSFixedAgitatorActivatable:removeCustomInput()
    if self._eventIds ~= nil then
        for _, id in pairs(self._eventIds) do
            g_inputBinding:removeActionEvent(id)
        end
        self._eventIds = {}
    end
end

function SPSFixedAgitatorActivatable:_onToggle()
    local fa = getFA(self)
    if fa == nil then return end
    if fa.connectedVehicle ~= nil then
        SPSFixedAgitator.requestDisconnect(self.pEntry.placeable)
    else
        local cand = SPSFixedAgitator.pickCandidate(fa)
        if cand ~= nil then
            SPSFixedAgitator.requestConnect(self.pEntry.placeable, cand)
        end
    end
end

function SPSFixedAgitatorActivatable:_buildText()
    local fa = getFA(self)
    if fa ~= nil and fa.connectedVehicle ~= nil then
        return g_i18n:getText("action_spsAgitatorDisconnect")
    end
    return g_i18n:getText("action_spsAgitatorConnect")
end