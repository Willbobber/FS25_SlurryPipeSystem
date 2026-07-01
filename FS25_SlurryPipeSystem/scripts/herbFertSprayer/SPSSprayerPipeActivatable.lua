-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.0

-- SPSSprayerPipeActivatable.lua
-- FS25_SlurryPipeSystem

SPSSprayerPipeActivatable = {}
SPSSprayerPipeActivatable.__index = SPSSprayerPipeActivatable

-- [SPS] Per-file debug toggle. Set true to enable [SPS SPR ACT] trace logging.
-- NOTE: this class is currently NOT instantiated anywhere (SPSSprayerPipeActivatable.new
-- is never called — SPSSprayerPumpControl is the only active sprayer control). If these
-- logs never appear with DEBUG=true, that confirms the file is dormant.
local DEBUG = false
local function log(fmt, ...)
    if not DEBUG then return end
    if select("#", ...) > 0 then
        print("[SPS SPR ACT] " .. string.format(fmt, ...))
    else
        print("[SPS SPR ACT] " .. tostring(fmt))
    end
end

SPSSprayerPipeActivatable.ACTIVATE_RADIUS = 1.8  -- metres

function SPSSprayerPipeActivatable.new(object, coupling)
    local self = setmetatable({}, SPSSprayerPipeActivatable)
    self.object   = object    -- vehicle (or nil for placeable couplings)
    self.coupling = coupling
    self.activateText  = ""
    self._actionEventId = nil
    log(".new: instantiated (object=%s couplingId=%s) — NOTE: normally never called",
        tostring(object and object.configFileName), tostring(coupling and coupling.id))
    return self
end

function SPSSprayerPipeActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

-- ---------------------------------------------------------------------------
-- ActivatableObjectsSystem interface
-- ---------------------------------------------------------------------------
function SPSSprayerPipeActivatable:getIsActivatable()
    if g_localPlayer == nil then return false end
    if self.coupling.mountNode == nil or not entityExists(self.coupling.mountNode) then return false end

    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(self.coupling.mountNode)
    local dist = MathUtil.vector3Length(px - cx, py - cy, pz - cz)
    if dist > SPSSprayerPipeActivatable.ACTIVATE_RADIUS then return false end

    return self:_getState() ~= nil
end

function SPSSprayerPipeActivatable:getDistance(posX, posY, posZ)
    if self.coupling.mountNode == nil or not entityExists(self.coupling.mountNode) then return math.huge end
    local cx, cy, cz = getWorldTranslation(self.coupling.mountNode)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSSprayerPipeActivatable:activate()
    self.activateText = self:_buildActivateText()
end

function SPSSprayerPipeActivatable:deactivate()
end

function SPSSprayerPipeActivatable:update(dt)
    self.activateText = self:_buildActivateText()
    if self._actionEventId ~= nil then
        g_inputBinding:setActionEventText(self._actionEventId, self.activateText)
    end
end

function SPSSprayerPipeActivatable:run()
    self:_onActivate()
end

function SPSSprayerPipeActivatable:registerCustomInput(inputContext)
    local _, id = g_inputBinding:registerActionEvent(
        InputAction.ACTIVATE_OBJECT,
        self,
        function(target, actionName, inputValue, callbackState, isAnalog)
            if inputValue > 0 then
                target:_onActivate()
            end
        end,
        false, true, false, true, nil, true, false
    )
    if id ~= nil then
        g_inputBinding:setActionEventText(id, self:_buildActivateText())
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(id, true)
        self._actionEventId = id
    end
end

function SPSSprayerPipeActivatable:removeCustomInput()
    if self._actionEventId ~= nil then
        g_inputBinding:removeActionEvent(self._actionEventId)
        self._actionEventId = nil
    end
end

-- ---------------------------------------------------------------------------
-- Internal
-- ---------------------------------------------------------------------------
function SPSSprayerPipeActivatable:_onActivate()
    local state = self:_getState()
    log("_onActivate: state=%s", tostring(state))
    if state == "connect" then
        if g_slurryPipeManager ~= nil then
            -- Manager finds the overlapping coupler internally
            g_slurryPipeManager:onSprayerCouplerConnect(self.object, self.coupling)
        end
    elseif state == "disconnect" then
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onSprayerCouplerDisconnect(self.object, self.coupling)
        end
    end
end

function SPSSprayerPipeActivatable:_getState()
    if not self.coupling.isConnected then
        if g_slurryPipeManager ~= nil then
            local other = g_slurryPipeManager:findOverlappingSprayerCoupler(self.coupling)
            if other ~= nil then
                return "connect"
            end
        end
        return nil
    else
        return "disconnect"
    end
end

function SPSSprayerPipeActivatable:_buildActivateText()
    local state = self:_getState()
    if state == "connect" then
        return g_i18n:getText("action_spsConnectPipe")
    elseif state == "disconnect" then
        return g_i18n:getText("action_spsDisconnectPipe")
    end
    return ""
end