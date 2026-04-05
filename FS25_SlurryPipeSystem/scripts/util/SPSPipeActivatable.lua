-- SPSPipeActivatable.lua
-- FS25_SlurryPipeSystem
--
-- Activatable object placed on each pipe coupling node.
-- Registered with ActivatableObjectsSystem permanently once the vehicle
-- is registered. getIsActivatable gates visibility by proximity and state.
--
-- State machine:
--   DISCONNECTED + arc overlap    : "Connect pipe"      short press R
--   CONNECTED + valve closed      : "Disconnect [R] | Open valve [hold R]"
--   CONNECTED + valve open        : "Close valve [hold R]"
--
-- All valve operation is manual (from outside cab only).
-- In-cab Action 2 (flow toggle) does NOT open/close manual coupling valves.

SPSPipeActivatable = {}
SPSPipeActivatable.__index = SPSPipeActivatable

SPSPipeActivatable.ACTIVATE_RADIUS = 1.8    -- metres, player must be within this distance
SPSPipeActivatable.HOLD_THRESHOLD  = 0.8    -- seconds for long-press valve toggle

function SPSPipeActivatable.new(vehicle, coupling)
    local self         = setmetatable({}, SPSPipeActivatable)
    self.vehicle       = vehicle    -- owning vehicle (nil for placeables)
    self.coupling      = coupling
    self.activateText  = ""
    self._holdTime     = 0
    self._isHolding    = false
    self._longFired    = false
    self._actionEventId = nil
    return self
end

function SPSPipeActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

-- ---------------------------------------------------------------------------
-- ActivatableObjectsSystem interface
-- ---------------------------------------------------------------------------
function SPSPipeActivatable:getIsActivatable(dirX, dirY, dirZ)
    if g_localPlayer == nil then return false end
    if self.coupling.mountNode == nil then return false end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(self.coupling.mountNode)
    local dist = MathUtil.vector3Length(px - cx, py - cy, pz - cz)
    if dist > SPSPipeActivatable.ACTIVATE_RADIUS then return false end
    return self:_getState() ~= nil
end

function SPSPipeActivatable:getDistance(posX, posY, posZ)
    if self.coupling.mountNode == nil then return math.huge end
    local cx, cy, cz = getWorldTranslation(self.coupling.mountNode)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSPipeActivatable:activate()
    self._holdTime  = 0
    self._isHolding = false
    self._longFired = false
    self.activateText = self:_buildActivateText()
end

function SPSPipeActivatable:deactivate()
    self._isHolding = false
    self._holdTime  = 0
    self._longFired = false
end

function SPSPipeActivatable:update(dt)
    -- Update display text each frame
    self.activateText = self:_buildActivateText()
    if self._actionEventId ~= nil then
        g_inputBinding:setActionEventText(self._actionEventId, self.activateText)
    end

    -- Hold timer for valve toggle
    if self._isHolding and not self._longFired then
        self._holdTime = self._holdTime + dt * 0.001
        if self._holdTime >= SPSPipeActivatable.HOLD_THRESHOLD then
            self._longFired = true
            self:_onLongPress()
        end
    end
end

-- Called by ActivatableObjectsSystem when player presses ACTIVATE_OBJECT
-- We use registerCustomInput to intercept so we can track press/release.
function SPSPipeActivatable:run()
    -- This is only called when registerCustomInput is NOT used.
    -- Since we always use registerCustomInput, this is a fallback.
    self:_onShortPress()
end

function SPSPipeActivatable:registerCustomInput(inputContext)
    self._holdTime  = 0
    self._isHolding = false
    self._longFired = false

    -- ActivatableObjectsSystem:registerInput already calls beginActionEventsModification
    -- before invoking this function and endActionEventsModification after it returns.
    -- Do NOT call begin/end here — doing so causes a double-wrap and crashes.
    local _, id = g_inputBinding:registerActionEvent(
        InputAction.ACTIVATE_OBJECT,
        self,
        self._onActivateInput,
        true,   -- triggerDown
        true,   -- triggerUp
        false,  -- triggerAlways
        true,   -- activeAlways
        nil,
        true,
        false
    )
    if id ~= nil then
        self._actionEventId = id
        g_inputBinding:setActionEventText(id, self:_buildActivateText())
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(id, true)
    end
end

function SPSPipeActivatable:removeCustomInput()
    if self._actionEventId ~= nil then
        g_inputBinding:removeActionEvent(self._actionEventId)
        self._actionEventId = nil
    end
    self._isHolding = false
    self._holdTime  = 0
    self._longFired = false
end

-- ---------------------------------------------------------------------------
-- Internal
-- ---------------------------------------------------------------------------
function SPSPipeActivatable:_onActivateInput(actionName, inputValue, callbackState, isAnalog)
    if inputValue > 0 then
        -- Press down
        self._isHolding = true
        self._holdTime  = 0
        self._longFired = false
    else
        -- Release
        if self._isHolding and not self._longFired then
            self:_onShortPress()
        end
        self._isHolding = false
        self._holdTime  = 0
        self._longFired = false
    end
end

function SPSPipeActivatable:_onShortPress()
    local state = self:_getState()
    if state == "connect" then
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onCouplerConnect(self.vehicle, self.coupling)
        end
    elseif state == "disconnectOrOpenValve" then
        -- Short press = disconnect (valve is closed, pipe is connected)
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onCouplerDisconnect(self.vehicle, self.coupling)
        end
    end
    -- In "closeValve" state, short press does nothing — only long press works
end

function SPSPipeActivatable:_onLongPress()
    local state = self:_getState()
    if state == "disconnectOrOpenValve" then
        -- Long press = open valve
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onValveOpen(self.vehicle, self.coupling)
        end
    elseif state == "closeValve" then
        -- Long press = close valve
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onValveClose(self.vehicle, self.coupling)
        end
    end
end

-- Returns the current logical state for this coupling, or nil if not activatable.
function SPSPipeActivatable:_getState()
    local coupling = self.coupling
    -- Deployable coupling not yet deployed — not activatable
    if coupling.deployable and not coupling.isDeployed then return nil end
    if not coupling.isConnected then
        -- Only activatable if another coupler arc is overlapping
        if g_slurryPipeManager ~= nil then
            local other = g_slurryPipeManager:findOverlappingCoupler(coupling)
            if other ~= nil then return "connect" end
        end
        return nil
    else
        -- Connected
        if coupling.valveOpen then
            return "closeValve"
        else
            return "disconnectOrOpenValve"
        end
    end
end

function SPSPipeActivatable:_buildActivateText()
    local state = self:_getState()
    if state == "connect" then
        return g_i18n:getText("action_spsConnectPipe")
    elseif state == "disconnectOrOpenValve" then
        return g_i18n:getText("action_spsDisconnectOrOpenValve")
    elseif state == "closeValve" then
        return g_i18n:getText("action_spsCloseValve")
    end
    return ""
end