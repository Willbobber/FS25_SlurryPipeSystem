-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4

-- SPSOutsideControlActivatable.lua
-- FS25_SlurryPipeSystem
--
-- Single outside-cab control node that can host BOTH the PTO/pump toggle and the
-- fill/empty direction control, each enabled per-item via fillPoints flags:
--
--     <outsideControls>
--         <outsideControl mountNodeName="pumpControl01" pto="true" direction="true"/>
--     </outsideControls>
--
-- Because it is ONE activatable, there is no second node to compete with, so the
-- two controls can never fight over the activation slot.
--
--   pto=true        Registers SPS_TOGGLE_PUMP, but only when the attached tractor
--                   is allowed outside PTO (SlurryTractorCapability). Cab PTO is
--                   unaffected. Capability is cached and only re-read when the
--                   resolved tractor changes (no per-frame disk I/O).
--   direction=true  Registers SPS_TOGGLE_DIRECTION here and suppresses it in the
--                   cab (see init.lua / vehicleHasOutsideDirectionControl).
--
-- Both actions call the exact same shared handlers the cab uses
-- (SlurryPipeManager:togglePump and :onActionToggleDirection), so behaviour is
-- identical in and out of the cab.

SPSOutsideControlActivatable = {}
SPSOutsideControlActivatable.__index = SPSOutsideControlActivatable

function SPSOutsideControlActivatable.new(vehicle, node, radius, allowPto, allowDirection)
    local self          = setmetatable({}, SPSOutsideControlActivatable)
    self.vehicle        = vehicle
    self.node           = node
    self.radius         = radius or 1.5
    self.allowPto       = allowPto == true
    self.allowDirection = allowDirection == true
    self.activateText   = ""
    self._eventIds      = {}
    self._capsTractor   = nil
    self._capsPTO       = false
    return self
end

function SPSOutsideControlActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

-- Resolve and cache outside-PTO capability for the currently attached tractor.
function SPSOutsideControlActivatable:_isPTOAllowed()
    if not self.allowPto then return false end
    if SlurryTractorCapability == nil then return false end
    local tractor = SlurryTractorCapability.resolveTractor(self.vehicle)
    if tractor ~= self._capsTractor then
        self._capsTractor = tractor
        self._capsPTO     = SlurryTractorCapability.hasOutsidePTO(self.vehicle)
    end
    return self._capsPTO == true
end

-- ---------------------------------------------------------------------------
-- ActivatableObjectsSystem interface
-- ---------------------------------------------------------------------------
function SPSOutsideControlActivatable:getIsActivatable()
    if g_localPlayer == nil then return false end
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return false end
    if g_slurryPipeManager == nil or not g_slurryPipeManager:isRegistered(self.vehicle) then return false end
    if SlurryPipeSystemOverride ~= nil and SlurryPipeSystemOverride.isAIControlled(self.vehicle) then
        return false
    end
    -- Nothing to offer? (PTO not allowed by tractor and no direction control)
    if not self.allowDirection and not self:_isPTOAllowed() then return false end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(self.node)
    return MathUtil.vector3Length(px - cx, py - cy, pz - cz) <= self.radius
end

function SPSOutsideControlActivatable:getDistance(posX, posY, posZ)
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return math.huge end
    local cx, cy, cz = getWorldTranslation(self.node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSOutsideControlActivatable:activate()
    self.activateText = ""
end

function SPSOutsideControlActivatable:deactivate()
end

function SPSOutsideControlActivatable:update(dt)
    if self._eventIds == nil then return end
    if self._eventIds.pump ~= nil then
        g_inputBinding:setActionEventText(self._eventIds.pump, self:_buildPumpText())
    end
    if self._eventIds.dir ~= nil then
        g_inputBinding:setActionEventText(self._eventIds.dir, self:_buildDirText())
    end
end

function SPSOutsideControlActivatable:run()
end

function SPSOutsideControlActivatable:registerCustomInput(inputContext)
    self._eventIds = {}

    if self:_isPTOAllowed() then
        local _, pumpId = g_inputBinding:registerActionEvent(
            InputAction.SPS_TOGGLE_PUMP, self,
            function(target, actionName, inputValue, callbackState, isAnalog)
                if inputValue > 0 then target:_onPump() end
            end,
            false, true, false, true, nil, true, false)
        if pumpId ~= nil then
            g_inputBinding:setActionEventText(pumpId, self:_buildPumpText())
            g_inputBinding:setActionEventTextPriority(pumpId, GS_PRIO_VERY_HIGH)
            g_inputBinding:setActionEventTextVisibility(pumpId, true)
            self._eventIds.pump = pumpId
        end
    end

    if self.allowDirection then
        local _, dirId = g_inputBinding:registerActionEvent(
            InputAction.SPS_TOGGLE_DIRECTION, self,
            function(target, actionName, inputValue, callbackState, isAnalog)
                if inputValue > 0 then target:_onDirection() end
            end,
            false, true, false, true, nil, true, false)
        if dirId ~= nil then
            g_inputBinding:setActionEventText(dirId, self:_buildDirText())
            g_inputBinding:setActionEventTextPriority(dirId, GS_PRIO_VERY_HIGH)
            g_inputBinding:setActionEventTextVisibility(dirId, true)
            self._eventIds.dir = dirId
        end
    end
end

function SPSOutsideControlActivatable:removeCustomInput()
    if self._eventIds ~= nil then
        for _, id in pairs(self._eventIds) do
            g_inputBinding:removeActionEvent(id)
        end
        self._eventIds = {}
    end
end

-- ---------------------------------------------------------------------------
-- Action handlers — identical to the cab toggles (shared methods)
-- ---------------------------------------------------------------------------
function SPSOutsideControlActivatable:_onPump()
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:togglePump(self.vehicle)
    end
end

function SPSOutsideControlActivatable:_onDirection()
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:onActionToggleDirection(self.vehicle)
    end
end

-- ---------------------------------------------------------------------------
-- Text builders — mirror the cab wording
-- ---------------------------------------------------------------------------
function SPSOutsideControlActivatable:_buildPumpText()
    if g_slurryPipeManager == nil then return "" end
    local state = g_slurryPipeManager:getVehicleState(self.vehicle)
    local pumpOn
    if g_slurryPipeManager:isVehicleSelfPowered(self.vehicle) or g_slurryPipeManager:vehicleHasSpreader(self.vehicle) then
        pumpOn = state ~= nil and state.pumpRunning == true
    else
        pumpOn = self.vehicle.getIsTurnedOn ~= nil and self.vehicle:getIsTurnedOn()
    end
    local pumpType = g_slurryPipeManager:getPumpType(self.vehicle)
    local offKey = (pumpType == "HVP") and "action_spsHVPOff" or "action_slurryPumpOff"
    local onKey  = (pumpType == "HVP") and "action_spsHVPOn"  or "action_slurryPumpOn"
    return pumpOn and g_i18n:getText(offKey) or g_i18n:getText(onKey)
end

function SPSOutsideControlActivatable:_buildDirText()
    if g_slurryPipeManager == nil then return "" end
    local state     = g_slurryPipeManager:getVehicleState(self.vehicle)
    local isFill    = state ~= nil and state.direction == SPS_DIRECTION_FILL
    local isConduit = g_slurryPipeManager:isVehicleConduit(self.vehicle)
    local pumpType  = g_slurryPipeManager:getPumpType(self.vehicle)
    if isConduit then
        return isFill and g_i18n:getText("action_spsConduitDirBtoA") or g_i18n:getText("action_spsConduitDirAtoB")
    elseif pumpType == "HVP" then
        return isFill and g_i18n:getText("action_spsHVPDirDischarge") or g_i18n:getText("action_spsHVPDirFill")
    else
        return isFill and g_i18n:getText("action_slurryDirectionDischarge") or g_i18n:getText("action_slurryDirectionFill")
    end
end
