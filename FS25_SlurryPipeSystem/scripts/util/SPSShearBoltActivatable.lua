-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4
--
-- SPSShearBoltActivatable.lua
-- FS25_SlurryPipeSystem
--
-- Walk-up, hold-to-repair activatable for a snapped PTO shear bolt. It is hosted on
-- the tanker's outside-control node (the same node used for outside PTO/direction),
-- and only appears when the bolt is SNAPPED. Holding the rebindable
-- SPS_REPAIR_SHEARBOLT action for REPAIR_SECONDS replaces the bolt — but only with
-- the tractor PTO off and engine stopped (SlurryPipeManager:canRepairShearBolt).
-- Mirrors the press/hold handling of SPSBlockageActivatable.

SPSShearBoltActivatable = {}
SPSShearBoltActivatable.__index = SPSShearBoltActivatable

SPSShearBoltActivatable.REPAIR_SECONDS = 3.0    -- seconds of hold to replace the bolt

function SPSShearBoltActivatable.new(vehicle, node, radius)
    local self          = setmetatable({}, SPSShearBoltActivatable)
    self.vehicle        = vehicle
    self.node           = node
    self.radius         = radius or 2.0
    self.activateText   = ""
    self._holdTime      = 0
    self._isHolding     = false
    self._fired         = false
    self._warned        = false
    self._actionEventId = nil
    self._lastEval      = nil
    return self
end

function SPSShearBoltActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

-- ---------------------------------------------------------------------------
-- ActivatableObjectsSystem interface
-- ---------------------------------------------------------------------------
function SPSShearBoltActivatable:getIsActivatable()
    local result, reason = self:_evalActivatable()
    if SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil and result ~= self._lastEval then
        SPSShearBolt.dbg("repair activatable -> " .. tostring(result) .. " (" .. tostring(reason) .. ")")
        self._lastEval = result
    end
    return result
end

function SPSShearBoltActivatable:_evalActivatable()
    if g_localPlayer == nil then return false, "no localPlayer" end
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return false, "no node" end
    if g_slurryPipeManager == nil or not g_slurryPipeManager:isRegistered(self.vehicle) then return false, "not registered" end
    if not g_slurryPipeManager:isShearBoltSnapped(self.vehicle) then return false, "not snapped" end
    if SlurryPipeSystemOverride ~= nil and SlurryPipeSystemOverride.isAIControlled(self.vehicle) then
        return false, "AI"
    end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(self.node)
    local dist = MathUtil.vector3Length(px - cx, py - cy, pz - cz)
    if dist > self.radius then return false, string.format("out of range %.1f>%.1f", dist, self.radius) end
    return true, "in range, snapped"
end

function SPSShearBoltActivatable:getDistance(posX, posY, posZ)
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return math.huge end
    local cx, cy, cz = getWorldTranslation(self.node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSShearBoltActivatable:activate()
    self._holdTime    = 0
    self._isHolding   = false
    self._fired       = false
    self._warned      = false
    self.activateText = self:_buildActivateText()
end

function SPSShearBoltActivatable:deactivate()
    self._isHolding = false
    self._holdTime  = 0
    self._fired     = false
    self._warned    = false
end

function SPSShearBoltActivatable:update(dt)
    -- DIAGNOSTIC: confirm the ActivatableObjectsSystem actually ticks this object.
    if SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil and not self._updateLogged then
        self._updateLogged = true
        SPSShearBolt.dbg("update() IS being called on the repair activatable")
    end

    self.activateText = self:_buildActivateText()
    if self._actionEventId ~= nil then
        g_inputBinding:setActionEventText(self._actionEventId, self.activateText)
    end

    if self._isHolding and not self._fired then
        if self:_canRepair() then
            self._holdTime = self._holdTime + dt * 0.001
            -- DIAGNOSTIC: throttled progress (~2/sec) so the log shows accumulation.
            if SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil then
                self._dbgAccum = (self._dbgAccum or 0) + dt
                if self._dbgAccum >= 500 then
                    self._dbgAccum = 0
                    SPSShearBolt.dbg(string.format("holding: %.1f / %.1f s (canRepair=true)",
                        self._holdTime, SPSShearBoltActivatable.REPAIR_SECONDS))
                end
            end
            if self._holdTime >= SPSShearBoltActivatable.REPAIR_SECONDS then
                self._fired = true
                if SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil then
                    SPSShearBolt.dbg("repair hold complete -> repairShearBolt")
                end
                if g_slurryPipeManager ~= nil then
                    g_slurryPipeManager:repairShearBolt(self.vehicle)
                end
            end
        else
            -- PTO/engine still running — hold makes no progress; nudge once.
            self._holdTime = 0
            if not self._warned then
                self._warned = true
                if SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil then
                    SPSShearBolt.dbg("hold blocked: canRepair=false (PTO/engine still on)")
                end
                if g_currentMission ~= nil then
                    g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsShearRepairBlocked"), 2000)
                end
            end
        end
    end
end

function SPSShearBoltActivatable:run()
end

function SPSShearBoltActivatable:registerCustomInput(inputContext)
    self._holdTime  = 0
    self._isHolding = false
    self._fired     = false
    self._warned    = false

    -- ActivatableObjectsSystem:registerInput already wraps this in
    -- begin/endActionEventsModification — do NOT call them here.
    local _, id = g_inputBinding:registerActionEvent(
        InputAction.SPS_REPAIR_SHEARBOLT,
        self,
        self._onRepairInput,
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
        if SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil then
            SPSShearBolt.dbg("repair input registered (id ok) canRepair=" .. tostring(self:_canRepair()))
        end
    elseif SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil then
        SPSShearBolt.dbg("repair input register FAILED — is SPS_REPAIR_SHEARBOLT declared in modDesc <actions>?")
    end
end

function SPSShearBoltActivatable:removeCustomInput()
    if self._actionEventId ~= nil then
        g_inputBinding:removeActionEvent(self._actionEventId)
        self._actionEventId = nil
    end
    self._isHolding = false
    self._holdTime  = 0
    self._fired     = false
    self._warned    = false
end

-- ---------------------------------------------------------------------------
-- Internal
-- ---------------------------------------------------------------------------
function SPSShearBoltActivatable:_onRepairInput(actionName, inputValue, callbackState, isAnalog)
    if SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil then
        SPSShearBolt.dbg(string.format("_onRepairInput fired: value=%.2f", inputValue or -1))
    end
    if inputValue > 0 then
        self._isHolding = true
        self._holdTime  = 0
        self._fired     = false
        self._warned    = false
    else
        self._isHolding = false
        self._holdTime  = 0
        self._fired     = false
        self._warned    = false
    end
end

function SPSShearBoltActivatable:_canRepair()
    if g_slurryPipeManager == nil then return false end
    return g_slurryPipeManager:canRepairShearBolt(self.vehicle) == true
end

function SPSShearBoltActivatable:_buildActivateText()
    if self:_canRepair() then
        return g_i18n:getText("action_spsRepairShearBolt")
    end
    return g_i18n:getText("action_spsRepairShearBoltWait")
end