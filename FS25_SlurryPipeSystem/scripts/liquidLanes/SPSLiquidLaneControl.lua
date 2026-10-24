-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSLiquidLaneControl.lua — walk-up control node activatable for a vehicle's
-- generic LIQUID connector (<liquidPipeSystem>). The prompt set is the SPRAYER's
-- (William: the trailer works the same at every connection):
--   R (ACTIVATE_OBJECT)     — connect / disconnect the hose; names the lane it
--                             would connect to (Water / Milk / Sprayer source)
--                             PHYSICAL pipe mode (1.0.1.8): Open valve / Close valve of
--                             this vehicle's plugged fitting (the barn fitting keeps its
--                             own walk-up prompt, SPSLaneValveActivatable)
--   B (SPS_TOGGLE_PUMP)     — Start Flow | Stop Flow  ("Flow: RUNNING/STOPPED")
--   Y (SPS_TOGGLE_DIRECTION)— Load | Unload            ("Direction: LOAD/UNLOAD")
-- On the SPRAYER lane B and Y are the sprayer's own toggles (bridge). On a barn
-- lane the direction is fixed by the lane (water = Unload, milk = Load); Y then
-- only shows a "direction is fixed" note.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSLiquidLaneControl 1.0.1.8 loaded") end

SPSLiquidLaneControl = {}
SPSLiquidLaneControl.__index = SPSLiquidLaneControl

local function log(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("SPSLiquidLaneControl") then return end
    if select("#", ...) > 0 then
        print("[SPS LL CTRL] " .. string.format(fmt, ...))
    else
        print("[SPS LL CTRL] " .. tostring(fmt))
    end
end

function SPSLiquidLaneControl.new(object, node, radius)
    local self        = setmetatable({}, SPSLiquidLaneControl)
    self.object       = object
    self.node         = node
    self.radius       = radius or 1.5
    self.activateText = ""
    self._eventIds    = {}
    return self
end

function SPSLiquidLaneControl:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

-- ---------------------------------------------------------------------------
-- ActivatableObjectsSystem interface
-- ---------------------------------------------------------------------------
function SPSLiquidLaneControl:getIsActivatable()
    if SPSAccess ~= nil and not SPSAccess.localCanUse(self.object) then return false end   -- [SPS 1.0.1.8] farm permission
    if g_localPlayer == nil then return false end
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return false end
    if g_slurryPipeManager == nil or not g_slurryPipeManager:isLiquidLaneVehicleRegistered(self.object) then
        return false
    end
    if SlurryPipeSystemOverride ~= nil and SlurryPipeSystemOverride.isAIControlled(self.object) then
        return false
    end
    local root = self.object.getRootVehicle ~= nil and self.object:getRootVehicle() or nil
    if root ~= nil and root:getIsActiveForInput(true) then
        return false -- player in the cab
    end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(self.node)
    if MathUtil.vector3Length(px - cx, py - cy, pz - cz) > self.radius then
        return false
    end
    local coupling = self:_getCoupling()
    if coupling == nil then return false end
    -- [SPS 1.0.1.8] pipe mode PHYSICAL: no hose matching here; the prompt (flow B / direction Y) only
    -- while a bought pipe is plugged in and the lane connected through it (SPSM_PhysPipes). Always at the
    -- control node (William 2026-10-17: the node is placed in GE where the pump should be worked from).
    if g_slurryPipeManager.physicalPipesEnabled == true then
        return coupling.physPipe ~= nil   -- a pipe on the fitting: R = valve; B / Y once the lane is connected
    end
    if coupling.isConnected then return true end
    local overlap, lane = g_slurryPipeManager:findOverlappingLiquidLaneCoupler(coupling)
    if self._dbgOverlap ~= (overlap ~= nil) then
        self._dbgOverlap = overlap ~= nil
        log("getIsActivatable: overlap=%s lane=%s coupling id=%s", tostring(overlap ~= nil),
            tostring(lane and lane.key), tostring(coupling.id))
    end
    return overlap ~= nil
end

function SPSLiquidLaneControl:getDistance(posX, posY, posZ)
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return math.huge end
    local cx, cy, cz = getWorldTranslation(self.node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSLiquidLaneControl:activate() end
function SPSLiquidLaneControl:deactivate() end
function SPSLiquidLaneControl:run() end

local function laneSuffix(lane)
    if lane == nil or g_slurryPipeManager == nil or g_slurryPipeManager.getLiquidLaneTitle == nil then return "" end
    local t = g_slurryPipeManager:getLiquidLaneTitle(lane)
    if t == nil or t == "" then return "" end
    return " (" .. t .. ")"
end

function SPSLiquidLaneControl:update(dt)
    if self._eventIds == nil then return end
    local coupling = self:_getCoupling()
    if coupling == nil then return end
    local connected = coupling.isConnected

    -- R: connect / disconnect, prompt names the lane (PHYSICAL pipe mode: never - the pipe is plugged
    -- and unplugged with the mouse, SPSHoseItemHands)
    local physical = g_slurryPipeManager.physicalPipesEnabled == true
    if self._eventIds.activate ~= nil then
        if physical then
            -- [SPS 1.0.1.8] R = this fitting's ball valve while a pipe is plugged in (William 2026-10-17)
            local visible = coupling.physPipe ~= nil
            g_inputBinding:setActionEventTextVisibility(self._eventIds.activate, visible)
            if visible then
                g_inputBinding:setActionEventText(self._eventIds.activate,
                    g_i18n:getText(coupling.ballValveOpen and "action_spsFittingValveClose" or "action_spsFittingValveOpen"))
            end
        else
            local overlap, overlapLane = nil, nil
            if not connected then overlap, overlapLane = g_slurryPipeManager:findOverlappingLiquidLaneCoupler(coupling) end
            local visible = connected or overlap ~= nil
            g_inputBinding:setActionEventTextVisibility(self._eventIds.activate, visible)
            if visible then
                local lane = connected and coupling.activeLane or overlapLane
                local base = g_i18n:getText(connected and "action_spsDisconnectPipe" or "action_spsConnectPipe")
                g_inputBinding:setActionEventText(self._eventIds.activate, base .. laneSuffix(lane))
            end
        end
    end

    -- B / Y: sprayer texts, only while connected
    local valveOpen, direction = false, SPS_SPRAYER_DIRECTION_FILL
    if connected then
        valveOpen, direction = g_slurryPipeManager:getLiquidLaneDisplayState(self.object)
    end
    if self._eventIds.pump ~= nil then
        g_inputBinding:setActionEventTextVisibility(self._eventIds.pump, connected)
        if connected then
            g_inputBinding:setActionEventText(self._eventIds.pump,
                g_i18n:getText(valveOpen and "action_sprayerFlowOn" or "action_sprayerFlowOff"))
        end
    end
    if self._eventIds.dir ~= nil then
        g_inputBinding:setActionEventTextVisibility(self._eventIds.dir, connected)
        if connected then
            g_inputBinding:setActionEventText(self._eventIds.dir,
                g_i18n:getText(direction == SPS_SPRAYER_DIRECTION_FILL and "action_sprayerDirLoad" or "action_sprayerDirUnload"))
        end
    end
end

function SPSLiquidLaneControl:registerCustomInput(inputContext)
    self._eventIds = {}

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

function SPSLiquidLaneControl:removeCustomInput()
    if self._eventIds ~= nil then
        for _, id in pairs(self._eventIds) do
            g_inputBinding:removeActionEvent(id)
        end
        self._eventIds = {}
    end
end

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------
function SPSLiquidLaneControl:_onActivate()
    local coupling = self:_getCoupling()
    if coupling == nil or g_slurryPipeManager == nil then return end
    if g_slurryPipeManager.physicalPipesEnabled == true then
        -- [SPS 1.0.1.8] physical pipes: plug / unplug is the mouse; R here = the plugged fitting's valve
        if coupling.physPipe ~= nil and g_slurryPipeManager.onLaneFittingValveToggle ~= nil then
            log("_onActivate: fitting valve toggle id=%s", tostring(coupling.id))
            g_slurryPipeManager:onLaneFittingValveToggle(coupling)
        end
        return
    end
    if coupling.isConnected then
        log("_onActivate: disconnect id=%s", tostring(coupling.id))
        g_slurryPipeManager:onLiquidLaneDisconnect(self.object, coupling)
    else
        log("_onActivate: connect id=%s", tostring(coupling.id))
        g_slurryPipeManager:onLiquidLaneConnect(self.object, coupling)
    end
end

function SPSLiquidLaneControl:_onFlow()
    if g_slurryPipeManager == nil then return end
    log("_onFlow: toggle")
    g_slurryPipeManager:onLiquidLaneToggleValve(self.object)
end

function SPSLiquidLaneControl:_onDirection()
    if g_slurryPipeManager == nil or g_slurryPipeManager.onLiquidLaneToggleDirection == nil then return end
    log("_onDirection: toggle")
    g_slurryPipeManager:onLiquidLaneToggleDirection(self.object)
end

-- The control drives the vehicle's first connected connector, else (physical mode) the first one with a
-- pipe plugged in, else couplings[1].
function SPSLiquidLaneControl:_getCoupling()
    if g_slurryPipeManager == nil then return nil end
    local entry = g_slurryPipeManager:getLiquidLaneVehicleEntry(self.object)
    if entry == nil or #entry.couplings == 0 then return nil end
    for _, c in ipairs(entry.couplings) do
        if c.isConnected then return c end
    end
    for _, c in ipairs(entry.couplings) do
        if c.physPipe ~= nil then return c end
    end
    return entry.couplings[1]
end
