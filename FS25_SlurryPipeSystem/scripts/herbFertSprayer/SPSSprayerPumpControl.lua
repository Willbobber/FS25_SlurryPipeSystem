-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4

-- SPSSprayerPumpControl.lua
-- Outside control node activatable for sprayer vehicles.
-- Handles the full interaction sequence:
--   1. X (SPS_TOGGLE_ANIMATION_SPRAYER) — open/close cover (if loadAnimation defined)
--   2. R (ACTIVATE_OBJECT)              — connect / disconnect pipe
--   3. B (SPS_TOGGLE_PUMP)             — start / stop flow (valve toggle)
--   4. Y (SPS_TOGGLE_DIRECTION)        — set load / set unload direction

SPSSprayerPumpControl = {}
SPSSprayerPumpControl.__index = SPSSprayerPumpControl

-- [SPS] Per-file debug toggle. Set true to enable [SPS SPR CTRL] trace logging.
local DEBUG = false
local function log(fmt, ...)
    if not DEBUG then return end
    if select("#", ...) > 0 then
        print("[SPS SPR CTRL] " .. string.format(fmt, ...))
    else
        print("[SPS SPR CTRL] " .. tostring(fmt))
    end
end

function SPSSprayerPumpControl.new(object, node, radius)
    local self      = setmetatable({}, SPSSprayerPumpControl)
    self.object     = object
    self.node       = node
    self.radius     = radius or 1.5
    self.activateText = ""
    self._eventIds  = {}
    return self
end

function SPSSprayerPumpControl:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

-- ---------------------------------------------------------------------------
-- ActivatableObjectsSystem interface
-- ---------------------------------------------------------------------------
function SPSSprayerPumpControl:getIsActivatable()
    if g_localPlayer == nil then return false end
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return false end
    if g_slurryPipeManager == nil or not g_slurryPipeManager:isSprayerVehicleRegistered(self.object) then
        if self._dbgReason ~= "notRegistered" then
            self._dbgReason = "notRegistered"
            log("getIsActivatable: FALSE — sprayer not registered (%s)", tostring(self.object and self.object.configFileName))
        end
        return false
    end

    -- AI guard: hide activatable when the sprayer's root is AI-driven.
    if SlurryPipeSystemOverride ~= nil and SlurryPipeSystemOverride.isAIControlled(self.object) then
        if self._dbgReason ~= "ai" then self._dbgReason = "ai"; log("getIsActivatable: FALSE — AI controlled") end
        return false
    end

    -- Block when player is in cab
    local root = self.object:getRootVehicle()
    if root ~= nil and root:getIsActiveForInput(true) then
        if self._dbgReason ~= "inCab" then self._dbgReason = "inCab"; log("getIsActivatable: FALSE — player in cab") end
        return false
    end

    -- Within radius
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(self.node)
    local dist = MathUtil.vector3Length(px - cx, py - cy, pz - cz)
    if dist > self.radius then
        if self._dbgReason ~= "radius" then
            self._dbgReason = "radius"
            log("getIsActivatable: FALSE — out of radius dist=%.2f radius=%.2f", dist, self.radius)
        end
        return false
    end

    -- Activatable when arcs overlap OR pipe already connected
    local coupling = self:_getCoupling()
    if coupling == nil then
        if self._dbgReason ~= "noCoupling" then self._dbgReason = "noCoupling"; log("getIsActivatable: FALSE — no coupling") end
        return false
    end
    if coupling.isConnected then
        if self._dbgReason ~= "connected" then
            self._dbgReason = "connected"
            log("getIsActivatable: TRUE — connected (dist=%.2f id=%s)", dist, tostring(coupling.id))
        end
        return true
    end
    local overlap = g_slurryPipeManager:findOverlappingSprayerCoupler(coupling)
    if self._dbgReason ~= ("overlap=" .. tostring(overlap ~= nil)) then
        self._dbgReason = "overlap=" .. tostring(overlap ~= nil)
        log("getIsActivatable: overlap=%s dist=%.2f radius=%.2f couplingId=%s",
            tostring(overlap ~= nil), dist, self.radius, tostring(coupling.id))
    end
    return overlap ~= nil
end

function SPSSprayerPumpControl:getDistance(posX, posY, posZ)
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return math.huge end
    local cx, cy, cz = getWorldTranslation(self.node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSSprayerPumpControl:activate()
end

function SPSSprayerPumpControl:deactivate()
end

function SPSSprayerPumpControl:update(dt)
    if self._eventIds == nil then return end
    local coupling = self:_getCoupling()
    if coupling == nil then return end

    local connected   = coupling.isConnected
    local hasLoadAnim = coupling.loadAnimationName ~= nil
    local animPlayed  = coupling.loadAnimPlayed == true

    -- SPS_TOGGLE_ANIMATION_SPRAYER (X): only when NOT connected and has a load animation
    if self._eventIds.anim ~= nil then
        local visible = not connected and hasLoadAnim
        g_inputBinding:setActionEventTextVisibility(self._eventIds.anim, visible)
        if visible then
            local txt = animPlayed
                and g_i18n:getText("action_sprayerCoverOpen")
                or  g_i18n:getText("action_sprayerCoverClosed")
            g_inputBinding:setActionEventText(self._eventIds.anim, txt)
        end
    end

    -- ACTIVATE_OBJECT (R): connect when ready, disconnect when connected
    if self._eventIds.activate ~= nil then
        local canConnect = not connected
            and (not hasLoadAnim or animPlayed)
            and g_slurryPipeManager:findOverlappingSprayerCoupler(coupling) ~= nil
        local visible = canConnect or connected
        g_inputBinding:setActionEventTextVisibility(self._eventIds.activate, visible)
        if visible then
            local txt = connected
                and g_i18n:getText("action_spsDisconnectPipe")
                or  g_i18n:getText("action_spsConnectPipe")
            g_inputBinding:setActionEventText(self._eventIds.activate, txt)
        end
    end

    -- SPS_TOGGLE_PUMP (B): start/stop flow — only when connected
    if self._eventIds.pump ~= nil then
        g_inputBinding:setActionEventTextVisibility(self._eventIds.pump, connected)
        if connected then
            local state = g_slurryPipeManager:getSprayerObjectState(self.object)
            if state ~= nil then
                local txt = state.valveOpen
                    and g_i18n:getText("action_sprayerFlowOn")
                    or  g_i18n:getText("action_sprayerFlowOff")
                g_inputBinding:setActionEventText(self._eventIds.pump, txt)
            end
        end
    end

    -- SPS_TOGGLE_DIRECTION (Y): load/unload — only when connected
    if self._eventIds.dir ~= nil then
        g_inputBinding:setActionEventTextVisibility(self._eventIds.dir, connected)
        if connected then
            local state = g_slurryPipeManager:getSprayerObjectState(self.object)
            if state ~= nil then
                local txt = state.direction == SPS_SPRAYER_DIRECTION_FILL
                    and g_i18n:getText("action_sprayerDirLoad")
                    or  g_i18n:getText("action_sprayerDirUnload")
                g_inputBinding:setActionEventText(self._eventIds.dir, txt)
            end
        end
    end
end

function SPSSprayerPumpControl:run()
end

function SPSSprayerPumpControl:registerCustomInput(inputContext)
    self._eventIds = {}

    -- X — open / close cover animation
    local _, animId = g_inputBinding:registerActionEvent(
        InputAction.SPS_TOGGLE_ANIMATION_SPRAYER, self,
        function(target, actionName, inputValue, callbackState, isAnalog)
            if inputValue > 0 then target:_onAnimToggle() end
        end,
        false, true, false, true, nil, true, false
    )
    if animId ~= nil then
        g_inputBinding:setActionEventText(animId, g_i18n:getText("input_SPS_TOGGLE_ANIMATION_SPRAYER"))
        g_inputBinding:setActionEventTextPriority(animId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(animId, false)
        self._eventIds.anim = animId
    end

    -- R — connect / disconnect pipe
    local _, actId = g_inputBinding:registerActionEvent(
        InputAction.ACTIVATE_OBJECT, self,
        function(target, actionName, inputValue, callbackState, isAnalog)
            if inputValue > 0 then target:_onActivate() end
        end,
        false, true, false, true, nil, true, false
    )
    if actId ~= nil then
        g_inputBinding:setActionEventText(actId, g_i18n:getText("action_spsConnectPipe"))
        g_inputBinding:setActionEventTextPriority(actId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(actId, false)
        self._eventIds.activate = actId
    end

    -- B — start / stop flow
    local _, pumpId = g_inputBinding:registerActionEvent(
        InputAction.SPS_TOGGLE_PUMP, self,
        function(target, actionName, inputValue, callbackState, isAnalog)
            if inputValue > 0 then target:_onFlow() end
        end,
        false, true, false, true, nil, true, false
    )
    if pumpId ~= nil then
        g_inputBinding:setActionEventText(pumpId, g_i18n:getText("input_SPS_TOGGLE_PUMP_SPRAYER"))
        g_inputBinding:setActionEventTextPriority(pumpId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(pumpId, false)
        self._eventIds.pump = pumpId
    end

    -- Y — load / unload direction
    local _, dirId = g_inputBinding:registerActionEvent(
        InputAction.SPS_TOGGLE_DIRECTION, self,
        function(target, actionName, inputValue, callbackState, isAnalog)
            if inputValue > 0 then target:_onDirection() end
        end,
        false, true, false, true, nil, true, false
    )
    if dirId ~= nil then
        g_inputBinding:setActionEventText(dirId, g_i18n:getText("input_SPS_TOGGLE_DIRECTION_SPRAYER"))
        g_inputBinding:setActionEventTextPriority(dirId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(dirId, false)
        self._eventIds.dir = dirId
    end
end

function SPSSprayerPumpControl:removeCustomInput()
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
function SPSSprayerPumpControl:_onAnimToggle()
    local coupling = self:_getCoupling()
    if coupling == nil or coupling.loadAnimationName == nil then return end
    if coupling.isConnected then return end
    if self.object.playAnimation == nil then return end

    if not coupling.loadAnimPlayed then
        self.object:playAnimation(coupling.loadAnimationName, 1)
        coupling.loadAnimPlayed = true
        log("_onAnimToggle: open cover anim=%s", tostring(coupling.loadAnimationName))
    else
        self.object:playAnimation(coupling.loadAnimationName, -1)
        coupling.loadAnimPlayed = false
        log("_onAnimToggle: close cover anim=%s", tostring(coupling.loadAnimationName))
    end
end

function SPSSprayerPumpControl:_onActivate()
    local coupling = self:_getCoupling()
    if coupling == nil then log("_onActivate: no coupling"); return end

    if coupling.isConnected then
        log("_onActivate: disconnect id=%s", tostring(coupling.id))
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onSprayerCouplerDisconnect(self.object, coupling)
        end
    else
        -- Block connect if cover animation has not been played
        if coupling.loadAnimationName ~= nil and not coupling.loadAnimPlayed then
            log("_onActivate: cover not open, connect blocked")
            return
        end
        log("_onActivate: connect id=%s", tostring(coupling.id))
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onSprayerCouplerConnect(self.object, coupling)
        end
    end
end

function SPSSprayerPumpControl:_onFlow()
    log("_onFlow: toggle valve")
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:onSprayerToggleValve(self.object)
    end
end

function SPSSprayerPumpControl:_onDirection()
    log("_onDirection: toggle direction")
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:onSprayerToggleDirection(self.object)
    end
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------
function SPSSprayerPumpControl:_getCoupling()
    if g_slurryPipeManager == nil then return nil end
    local entry = g_slurryPipeManager:getSprayerVehicleEntry(self.object)
    if entry == nil or #entry.couplings == 0 then return nil end
    -- NOTE: only ever returns couplings[1]. If a sprayer defines >1 coupling,
    -- couplings 2..n are unreachable from this control. Logged once on change.
    if self._dbgCplCount ~= #entry.couplings then
        self._dbgCplCount = #entry.couplings
        log("_getCoupling: %d coupling(s) present; using couplings[1] (id=%s)",
            #entry.couplings, tostring(entry.couplings[1] and entry.couplings[1].id))
    end
    return entry.couplings[1]
end