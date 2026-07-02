-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.4

-- SPSPumpControlActivatable.lua
-- FS25_SlurryPipeSystem

SPSPumpControlActivatable = {}
SPSPumpControlActivatable.__index = SPSPumpControlActivatable

function SPSPumpControlActivatable.new(vehicle, node, radius)
    local self        = setmetatable({}, SPSPumpControlActivatable)
    self.vehicle      = vehicle
    self.node         = node
    self.radius       = radius or 1.5
    self.activateText = ""
    self._eventIds    = {}
    return self
end

function SPSPumpControlActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

-- ---------------------------------------------------------------------------
-- ActivatableObjectsSystem interface
-- ---------------------------------------------------------------------------
function SPSPumpControlActivatable:getIsActivatable()
    if g_localPlayer == nil then return false end
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return false end
    if g_slurryPipeManager == nil or not g_slurryPipeManager:isRegistered(self.vehicle) then return false end
    -- AI guard: hide activatable when the vehicle's root is AI-driven.
    if SlurryPipeSystemOverride ~= nil and SlurryPipeSystemOverride.isAIControlled(self.vehicle) then
        return false
    end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(self.node)
    return MathUtil.vector3Length(px - cx, py - cy, pz - cz) <= self.radius
end

function SPSPumpControlActivatable:getDistance(posX, posY, posZ)
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return math.huge end
    local cx, cy, cz = getWorldTranslation(self.node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSPumpControlActivatable:activate()
    self.activateText = ""
end

function SPSPumpControlActivatable:deactivate()
end

function SPSPumpControlActivatable:update(dt)
    if self._eventIds == nil then return end
    if self._eventIds.pump ~= nil then
        g_inputBinding:setActionEventText(self._eventIds.pump, self:_buildPumpText())
    end
    if self._eventIds.flow ~= nil then
        g_inputBinding:setActionEventText(self._eventIds.flow, self:_buildValveText())
    end
    if self._eventIds.dir ~= nil then
        local vState = g_slurryPipeManager ~= nil and g_slurryPipeManager:getVehicleState(self.vehicle) or nil
        local dirTxt = (vState and vState.direction == SPS_DIRECTION_FILL)
            and g_i18n:getText("action_slurryDirectionDischarge")
            or  g_i18n:getText("action_slurryDirectionFill")
        g_inputBinding:setActionEventText(self._eventIds.dir, dirTxt)
    end
end

function SPSPumpControlActivatable:run()
end

function SPSPumpControlActivatable:registerCustomInput(inputContext)
    self._eventIds = {}

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

    local _, flowId = g_inputBinding:registerActionEvent(
        InputAction.SPS_TOGGLE_FLOW, self,
        function(target, actionName, inputValue, callbackState, isAnalog)
            if inputValue > 0 then target:_onValve() end
        end,
        false, true, false, true, nil, true, false)
    if flowId ~= nil then
        g_inputBinding:setActionEventText(flowId, self:_buildValveText())
        g_inputBinding:setActionEventTextPriority(flowId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(flowId, true)
        self._eventIds.flow = flowId
    end

    local _, dirId = g_inputBinding:registerActionEvent(
        InputAction.SPS_TOGGLE_DIRECTION, self,
        function(target, actionName, inputValue, callbackState, isAnalog)
            if inputValue > 0 then target:_onDirection() end
        end,
        false, true, false, true, nil, true, false)
    if dirId ~= nil then
        local vState = g_slurryPipeManager ~= nil and g_slurryPipeManager:getVehicleState(self.vehicle) or nil
        local dirTxt = (vState and vState.direction == SPS_DIRECTION_FILL)
            and g_i18n:getText("action_slurryDirectionDischarge")
            or  g_i18n:getText("action_slurryDirectionFill")
        g_inputBinding:setActionEventText(dirId, dirTxt)
        g_inputBinding:setActionEventTextPriority(dirId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(dirId, true)
        self._eventIds.dir = dirId
    end
end

function SPSPumpControlActivatable:removeCustomInput()
    if self._eventIds ~= nil then
        for _, id in pairs(self._eventIds) do
            g_inputBinding:removeActionEvent(id)
        end
        self._eventIds = {}
    end
end

-- ---------------------------------------------------------------------------
-- Action handlers
-- ---------------------------------------------------------------------------
function SPSPumpControlActivatable:_onPump()
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:onSelfPumpToggle(self.vehicle)
    end
end

function SPSPumpControlActivatable:_onValve()
    if g_slurryPipeManager == nil then return end
    local vState = g_slurryPipeManager:getVehicleState(self.vehicle)
    if vState == nil then return end
    local newOpen = not vState.valveOpen
    if g_server ~= nil then
        vState.valveOpen = newOpen
        SlurryFlowStateEvent.sendEvent(self.vehicle, newOpen)
        g_slurryPipeManager:updateActionEventTexts(self.vehicle)
    else
        SlurryFlowStateEvent.sendEvent(self.vehicle, newOpen)
    end
    -- Sync to all connected couplings marked valveFromRearControl so
    -- hasActiveCouplingConnection returns true and flow can start.
    local entry = g_slurryPipeManager:getVehicleEntry(self.vehicle)
    if entry ~= nil then
        for _, coupling in ipairs(entry.couplingEntries) do
            if coupling.valveFromRearControl and coupling.isConnected then
                if newOpen then
                    g_slurryPipeManager:onValveOpen(self.vehicle, coupling)
                else
                    g_slurryPipeManager:onValveClose(self.vehicle, coupling)
                end
            end
        end
    end
end

function SPSPumpControlActivatable:_onDirection()
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:onActionToggleDirection(self.vehicle)
    end
end

-- ---------------------------------------------------------------------------
-- Text builders
-- ---------------------------------------------------------------------------
function SPSPumpControlActivatable:_buildPumpText()
    local vState = g_slurryPipeManager ~= nil and g_slurryPipeManager:getVehicleState(self.vehicle) or nil
    local pumpOn = vState ~= nil and vState.pumpRunning == true
    return pumpOn
        and g_i18n:getText("action_slurryPumpOff")
        or  g_i18n:getText("action_slurryPumpOn")
end

function SPSPumpControlActivatable:_buildValveText()
    local vState = g_slurryPipeManager ~= nil and g_slurryPipeManager:getVehicleState(self.vehicle) or nil
    return (vState and vState.valveOpen)
        and g_i18n:getText("action_spsRearValveClose")
        or  g_i18n:getText("action_spsRearValveOpen")
end