-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.2.0

-- SPSAnimationControlActivatable.lua
-- [SPS 1.0.2.0] Walk-up control that plays ONE of the vehicle's own <animations> forward / backward
-- (Kotte TSA: "rotate spout" at the rear - the spout swings out by hand, X at the node).
--
--     <animationControls>
--         <animationControl id="1" nodeName="SPS_spoutControlNode" radius="1.5" animation="spoutRotate"
--                           textForward="action_spsSpoutOut" textBackward="action_spsSpoutBack"/>
--     </animationControls>
--
--   nodeName      transform the player walks up to (found by name on the vehicle, like pumpControls)
--   animation     name in the vehicle's <animations>; time 0 = rest pose, 1 = moved pose
--   textForward   prompt shown while the animation is at rest (l10n key or plain text); default "SPS: animation"
--   textBackward  prompt shown while it is moved (l10n key or plain text)
--
-- The action is SPS_TOGGLE_ANIMATION (X by default). playAnimation is called WITH the vanilla event
-- (noEventSend nil) so AnimatedVehicleStartEvent keeps every peer in step; no SPS event needed. The
-- pose is saved with the pump state (SlurryPipeManager pumpStates #animControls) and snapped back on load.

SPSAnimationControlActivatable = {}
SPSAnimationControlActivatable.__index = SPSAnimationControlActivatable

local function resolveText(key, default)
    if key == nil or key == "" then return default end
    local k = key:gsub("^%$l10n_", "")
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(k) then return g_i18n:getText(k) end
    return key
end

function SPSAnimationControlActivatable.new(vehicle, node, radius, animName, textForward, textBackward)
    local self        = setmetatable({}, SPSAnimationControlActivatable)
    self.vehicle      = vehicle
    self.node         = node
    self.radius       = radius or 1.5
    self.animName     = animName
    self.textForward  = resolveText(textForward,  "SPS: animation")
    self.textBackward = resolveText(textBackward, self.textForward)
    self.activateText = ""
    self._eventIds    = {}
    self._warned      = false
    return self
end

function SPSAnimationControlActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

function SPSAnimationControlActivatable:_hasAnimation()
    local v = self.vehicle
    if v == nil or v.getAnimationExists == nil or self.animName == nil then return false end
    if not v:getAnimationExists(self.animName) then
        if not self._warned then
            self._warned = true
            print(string.format("[SPS] WARNING: animationControl animation '%s' not found in the animations of %s",
                tostring(self.animName), tostring(v.configFileName)))
        end
        return false
    end
    return true
end

-- true while the animation sits at (or is heading to) its moved pose
function SPSAnimationControlActivatable:_isOut()
    local v = self.vehicle
    if v == nil or v.getAnimationTime == nil then return false end
    if v.getIsAnimationPlaying ~= nil and v:getIsAnimationPlaying(self.animName) and v.getAnimationSpeed ~= nil then
        local s = v:getAnimationSpeed(self.animName)
        if s ~= nil and s ~= 0 then return s > 0 end
    end
    return (v:getAnimationTime(self.animName) or 0) > 0.5
end

-- ---------------------------------------------------------------------------
-- ActivatableObjectsSystem interface
-- ---------------------------------------------------------------------------
function SPSAnimationControlActivatable:getIsActivatable()
    if SPSAccess ~= nil and not SPSAccess.localCanUse(self.vehicle) then return false end
    if g_localPlayer == nil then return false end
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return false end
    -- [SPS 1.0.2.0] slurry vehicles OR sprayers (the sprayer registry is separate)
    if g_slurryPipeManager == nil then return false end
    if not g_slurryPipeManager:isRegistered(self.vehicle)
    and not (g_slurryPipeManager.isSprayerVehicleRegistered ~= nil and g_slurryPipeManager:isSprayerVehicleRegistered(self.vehicle)) then
        return false
    end
    if SlurryPipeSystemOverride ~= nil and SlurryPipeSystemOverride.isAIControlled(self.vehicle) then return false end
    if not self:_hasAnimation() then return false end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(self.node)
    return MathUtil.vector3Length(px - cx, py - cy, pz - cz) <= self.radius
end

function SPSAnimationControlActivatable:getDistance(posX, posY, posZ)
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return math.huge end
    local cx, cy, cz = getWorldTranslation(self.node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSAnimationControlActivatable:activate()
    self.activateText = ""
end

function SPSAnimationControlActivatable:deactivate()
end

function SPSAnimationControlActivatable:update(dt)
    if self._eventIds ~= nil and self._eventIds.anim ~= nil then
        g_inputBinding:setActionEventText(self._eventIds.anim, self:_buildText())
    end
end

function SPSAnimationControlActivatable:run()
end

function SPSAnimationControlActivatable:registerCustomInput(inputContext)
    self._eventIds = {}
    local _, animId = g_inputBinding:registerActionEvent(
        InputAction.SPS_TOGGLE_ANIMATION, self,
        function(target, actionName, inputValue, callbackState, isAnalog)
            if inputValue > 0 then target:_onToggle() end
        end,
        false, true, false, true, nil, true, false)
    if animId ~= nil then
        g_inputBinding:setActionEventText(animId, self:_buildText())
        g_inputBinding:setActionEventTextPriority(animId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(animId, true)
        self._eventIds.anim = animId
    end
end

function SPSAnimationControlActivatable:removeCustomInput()
    if self._eventIds ~= nil then
        for _, id in pairs(self._eventIds) do
            g_inputBinding:removeActionEvent(id)
        end
        self._eventIds = {}
    end
end

-- ---------------------------------------------------------------------------
function SPSAnimationControlActivatable:_onToggle()
    local v = self.vehicle
    if v == nil or v.playAnimation == nil or not self:_hasAnimation() then return end
    -- [SPS 1.0.2.0] lockLoadAnimation (UX5201 chem bowl, behind the door): it may only come OUT while the
    -- sprayer's loadAnimation (door) is fully open. Putting it away is always allowed. The reverse rule
    -- (door cannot close while this is out) lives in SPSSprayerPumpControl:_onAnimToggle.
    if self.locksLoadAnimation and not self:_isOut() and g_slurryPipeManager ~= nil then
        local vEntry = g_slurryPipeManager.getSprayerVehicleEntry ~= nil and g_slurryPipeManager:getSprayerVehicleEntry(v) or nil
        local door = vEntry ~= nil and vEntry.state ~= nil and vEntry.state.loadAnimName or nil
        if door ~= nil and v:getAnimationExists(door) then
            local playingShut = v.getIsAnimationPlaying ~= nil and v:getIsAnimationPlaying(door)
                and v.getAnimationSpeed ~= nil and (v:getAnimationSpeed(door) or 0) < 0
            if playingShut or (v:getAnimationTime(door) or 0) < 0.99 then
                local txt = g_i18n:hasText("warning_spsOpenDoorFirst") and g_i18n:getText("warning_spsOpenDoorFirst") or "Open the door first"
                g_currentMission:showBlinkingWarning(txt, 2000)
                return
            end
        end
    end
    -- vanilla event (noEventSend nil): server broadcasts / client sends, all peers swing together
    v:playAnimation(self.animName, self:_isOut() and -1 or 1, nil, false)
end

function SPSAnimationControlActivatable:_buildText()
    return self:_isOut() and self.textBackward or self.textForward
end
