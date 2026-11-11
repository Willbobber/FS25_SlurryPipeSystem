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
    local coupling = self:_getCoupling()
    if coupling == nil then return false end
    -- [SPS 2026-11-10] a pipe of this vehicle in the LOCAL player's hands: the control (and its X = put back) goes with them,
    -- anywhere. A second X event of our own was refused by the engine (InputBinding:registerActionEvent: one event per
    -- action + trigger), so the control's own X is the only X there is.
    if self:_localHolds() ~= nil then return true end
    -- [SPS 1.0.2.0] a BARE fitting (pipe mode, nothing plugged): its valve is reachable only right at the fitting itself,
    -- not across the whole control radius - on the TSA the control node sits 0.6 m from the spout's X prompt and the
    -- nearest prompt wins, so the valve was hiding the spout swing (William 2026-11-03)
    -- [SPS 2026-11-09] not on a GENERATOR vehicle (550 bowser): B starts the engine from the control node, pipe or no pipe
    local llEntry = g_slurryPipeManager:getLiquidLaneVehicleEntry(self.object)
    if g_slurryPipeManager.physicalPipesEnabled == true and coupling.physPipe == nil and not coupling.isConnected
    and (llEntry == nil or llEntry.generator == nil) then
        local fn = coupling.inNode or coupling.mountNode
        if fn == nil or fn == 0 or not entityExists(fn) then return false end
        local fx, fy, fz = getWorldTranslation(fn)
        return MathUtil.vector3Length(px - fx, py - fy, pz - fz) <= SPSLiquidLaneControl.BARE_FITTING_RADIUS
    end
    local cx, cy, cz = getWorldTranslation(self.node)
    if MathUtil.vector3Length(px - cx, py - cy, pz - cz) > self.radius then
        -- [SPS 2026-11-10] original mode: standing in one of this vehicle's coupling ARCS is enough, as at every tanker's
        -- slurry coupler (William: "I need to be sat on top of the node for the R to take effect")
        if g_slurryPipeManager.physicalPipesEnabled == true or not self:_playerInAnyArc(px, pz) then return false end
    end
    -- [SPS 1.0.1.8] pipe mode PHYSICAL: no hose matching here; the prompt (flow B / direction Y) only
    -- while a bought pipe is plugged in and the lane connected through it (SPSM_PhysPipes). Always at the
    -- control node (William 2026-10-17: the node is placed in GE where the pump should be worked from).
    if g_slurryPipeManager.physicalPipesEnabled == true then
        -- R = this fitting's valve at ANY time (pipe or no pipe - William 2026-11-02); B / Y once the lane is connected.
        -- With "Pipe leakage" on an open valve leaks the tank (SPSM_Leaks)
        return true
    end
    if coupling.isConnected then return true end
    if llEntry ~= nil and llEntry.generator ~= nil then return true end   -- [2026-11-09] 550 bowser: engine / suction / wash prompts
    -- [SPS MKS8 2026-11-10] a door to open or a tank to pick: the node works with nothing in range
    if llEntry ~= nil and (llEntry.state.loadAnimName ~= nil or coupling.tanks ~= nil) then return true end
    local overlap, lane = g_slurryPipeManager:findOverlappingLiquidLaneCoupler(coupling)
    if self._dbgOverlap ~= (overlap ~= nil) then
        self._dbgOverlap = overlap ~= nil
        log("getIsActivatable: overlap=%s lane=%s coupling id=%s", tostring(overlap ~= nil),
            tostring(lane and lane.key), tostring(coupling.id))
    end
    return overlap ~= nil
end

SPSLiquidLaneControl.BARE_FITTING_RADIUS = 1.5   -- m: reach of the valve prompt at a fitting with no pipe
SPSLiquidLaneControl.BARE_FITTING_BIAS   = 0.5   -- m: added to its distance so any other prompt at the same spot wins

-- [SPS 2026-11-10] the original-mode pipe of this vehicle in the LOCAL player's hands: coupling, kind (2 = wash hose, 1 = carried
-- suction end), else nil
function SPSLiquidLaneControl:_localHolds()
    if g_slurryPipeManager == nil or g_currentMission == nil then return nil end
    local me = g_currentMission.playerUserId
    if me == nil or me < 0 then return nil end
    local entry = g_slurryPipeManager:getLiquidLaneVehicleEntry(self.object)
    for _, c in ipairs(entry ~= nil and entry.couplings or {}) do
        if c.origWash ~= nil and c.origWash.userId == me then return c, 2 end
        if c.origSuction ~= nil and c.origSuction.carried and c.origSuction.userId == me then return c, 1 end
    end
    return nil
end

function SPSLiquidLaneControl:getDistance(posX, posY, posZ)
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return math.huge end
    if self:_localHolds() ~= nil then return 0 end   -- [2026-11-10] pipe in hand: this control is always the nearest
    -- [SPS 1.0.2.0] bare fitting: measured from the fitting, pushed back so co-located prompts (spout X) come first
    local coupling = self:_getCoupling()
    if coupling ~= nil and g_slurryPipeManager ~= nil and g_slurryPipeManager.physicalPipesEnabled == true
       and coupling.physPipe == nil and not coupling.isConnected then
        local fn = coupling.inNode or coupling.mountNode
        if fn ~= nil and fn ~= 0 and entityExists(fn) then
            local fx, fy, fz = getWorldTranslation(fn)
            return MathUtil.vector3Length(posX - fx, posY - fy, posZ - fz) + SPSLiquidLaneControl.BARE_FITTING_BIAS
        end
    end
    local cx, cy, cz = getWorldTranslation(self.node)
    local d = MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
    -- [SPS 2026-11-10] original mode: the nearest of the pump node and the fittings, so the prompt wins where the player stands
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.physicalPipesEnabled ~= true then
        local entry = g_slurryPipeManager:getLiquidLaneVehicleEntry(self.object)
        for _, c in ipairs(entry ~= nil and entry.couplings or {}) do
            local n = c.mountNode
            if n ~= nil and n ~= 0 and entityExists(n) then
                local mx, my, mz = getWorldTranslation(n)
                d = math.min(d, MathUtil.vector3Length(posX - mx, posY - my, posZ - mz))
            end
        end
    end
    return d
end

-- [SPS 2026-11-10] the LOCAL player holds a pipe of this vehicle but stands AWAY from the pump node and every arc: only "put
-- back" is offered there (William: "once I walk away from the node I shouldn't get take a hose")
function SPSLiquidLaneControl:_awayWithPipe()
    if self:_localHolds() == nil or g_localPlayer == nil then return false end
    if self.node == nil or self.node == 0 or not entityExists(self.node) then return true end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(self.node)
    if MathUtil.vector3Length(px - cx, py - cy, pz - cz) <= self.radius then return false end
    return not self:_playerInAnyArc(px, pz)
end

-- [SPS 2026-11-10] true when (px,pz) lies inside the arc triangle of any coupling of this vehicle
function SPSLiquidLaneControl:_playerInAnyArc(px, pz)
    if g_slurryPipeManager == nil or g_slurryPipeManager.isPointInCouplingArc == nil then return false end
    local entry = g_slurryPipeManager:getLiquidLaneVehicleEntry(self.object)
    for _, c in ipairs(entry ~= nil and entry.couplings or {}) do
        if g_slurryPipeManager:isPointInCouplingArc(c, px, pz) then return true end
    end
    return false
end

function SPSLiquidLaneControl:activate() end
function SPSLiquidLaneControl:deactivate() end
function SPSLiquidLaneControl:run() end

-- [SPS 2026-11-10] a bowser (generator / own pipes) on either side of a Transfer: "Bowser to tanker" at the bowser, "Tanker to
-- bowser" at the tanker (William: never "Tanker to tanker" for the 550)
local function isBowserEntry(entry)
    if entry == nil then return false end
    if entry.generator ~= nil then return true end
    for _, c in ipairs(entry.couplings or {}) do
        if c.waterSourceKey ~= nil or c.washOutletKey ~= nil then return true end
    end
    return false
end

local function laneSuffix(lane, selfEntry, partner)
    if lane == nil or g_slurryPipeManager == nil or g_slurryPipeManager.getLiquidLaneTitle == nil then return "" end
    local t = g_slurryPipeManager:getLiquidLaneTitle(lane)
    if lane.key == "TRANSFER" and partner ~= nil then
        local pEntry = partner.isVehicleSide and g_slurryPipeManager:getLiquidLaneVehicleEntry(partner.object) or nil
        local selfBowser, partnerBowser = isBowserEntry(selfEntry), isBowserEntry(pEntry)
        if selfBowser and not partnerBowser then t = g_i18n:getText("sps_laneBowserToTanker")
        elseif partnerBowser and not selfBowser then t = g_i18n:getText("sps_laneTankerToBowser") end
    end
    if t == nil or t == "" then return "" end
    return " (" .. t .. ")"
end

function SPSLiquidLaneControl:update(dt)
    if self._eventIds == nil then return end
    local coupling = self:_getCoupling()
    if coupling == nil then return end
    local connected = coupling.isConnected
    -- [SPS 2026-11-09] 550 bowser: B = the engine / pump at any time on a generator vehicle; otherwise a pipe lying in the
    -- water / a wash hose lying free makes it pumpable without a partner (no Y)
    local llEntry = g_slurryPipeManager:getLiquidLaneVehicleEntry(self.object)
    local pumpable = connected or (llEntry ~= nil and llEntry.generator ~= nil)
    if not pumpable and llEntry ~= nil and g_slurryPipeManager._llSpecialMode ~= nil then
        for _, cc in ipairs(llEntry.couplings) do
            if g_slurryPipeManager:_llSpecialMode(cc) ~= nil then pumpable = true break end
        end
    end
    local engineText = llEntry ~= nil and llEntry.generator ~= nil

    -- R: connect / disconnect, prompt names the lane (PHYSICAL pipe mode: never - the pipe is plugged
    -- and unplugged with the mouse, SPSHoseItemHands)
    local physical = g_slurryPipeManager.physicalPipesEnabled == true
    if self._eventIds.activate ~= nil then
        if physical then
            -- [SPS 1.0.1.8] R = this fitting's ball valve while a pipe is plugged in (William 2026-10-17)
            -- [SPS 1.0.2.0] ...and with no pipe (William 2026-11-02: valves work at any time in pipe mode)
            local visible = coupling.hasValve ~= false   -- [SPS MKS8] a fitting without a valve has no R
            g_inputBinding:setActionEventTextVisibility(self._eventIds.activate, visible)
            if visible then
                g_inputBinding:setActionEventText(self._eventIds.activate,
                    g_i18n:getText(coupling.ballValveOpen and "action_spsFittingValveClose" or "action_spsFittingValveOpen"))
            end
        else
            local overlap, overlapLane = nil, nil
            if not connected then overlap, overlapLane = g_slurryPipeManager:findOverlappingLiquidLaneCoupler(coupling) end
            local visible = connected or overlap ~= nil
            -- [SPS 2026-11-09] 550 bowser, nothing to connect to: R lays the suction pipe where the player stands / takes it up
            local suction = coupling.waterSourceKey ~= nil and (coupling.origSuction ~= nil or (not connected and overlap == nil))
            -- [SPS 2026-11-10] away from the node with a pipe in hand: no R (take / connect), only H = put back
            g_inputBinding:setActionEventTextVisibility(self._eventIds.activate, (visible or suction) and not self:_awayWithPipe())
            if visible then
                local lane = connected and coupling.activeLane or overlapLane
                local partner = connected and coupling.connectedPartnerCoupling or overlap
                local base = g_i18n:getText(connected and "action_spsDisconnectPipe" or "action_spsConnectPipe")
                g_inputBinding:setActionEventText(self._eventIds.activate, base .. laneSuffix(lane, llEntry, partner))
            elseif suction then
                -- [SPS 2026-11-10] in hand: R = "Release suction pipe" (lays the end where it is); laid: "Remove suction pipe"
                -- (back on the bowser); on the bowser: "Take suction pipe" (William)
                local key = "action_spsTakeSuction"
                if coupling.origSuction ~= nil then
                    key = coupling.origSuction.carried and "action_spsReleaseSuction" or "action_spsPickupSuction"
                end
                g_inputBinding:setActionEventText(self._eventIds.activate, g_i18n:getText(key))
            end
        end
    end
    -- X: the wash hose (original mode only - in pipe mode the bought hose is carried by hand)
    if self._eventIds.wash ~= nil then
        local wc = self:_getWashCoupling()
        local heldC, heldKind = self:_localHolds()
        local show = not physical and (wc ~= nil or heldC ~= nil)
        g_inputBinding:setActionEventTextVisibility(self._eventIds.wash, show)
        if show then
            -- [SPS 2026-11-10] X puts back whatever is in hand (the carried suction end too)
            local key = "action_spsTakeWash"
            if heldKind == 1 then key = "action_spsReturnSuction"
            elseif wc ~= nil and wc.origWash ~= nil then key = "action_spsReturnWash" end
            g_inputBinding:setActionEventText(self._eventIds.wash, g_i18n:getText(key))
        end
    end

    -- B / Y: sprayer texts, only while connected
    local valveOpen, direction = false, SPS_SPRAYER_DIRECTION_FILL
    if pumpable then
        valveOpen, direction = g_slurryPipeManager:getLiquidLaneDisplayState(self.object)
    end
    if self._eventIds.pump ~= nil then
        pumpable = pumpable and not self:_awayWithPipe()   -- [2026-11-10] B / Y at the pump only
        g_inputBinding:setActionEventTextVisibility(self._eventIds.pump, pumpable)
        if pumpable then
            local onKey  = engineText and "action_spsEngineOff" or "action_sprayerFlowOn"
            local offKey = engineText and "action_spsEngineOn"  or "action_sprayerFlowOff"
            g_inputBinding:setActionEventText(self._eventIds.pump, g_i18n:getText(valveOpen and onKey or offKey))
        end
    end
    -- [SPS MKS8 2026-11-11] Y = the direction only, the same "Load" / "Unload" text as every other vehicle (William: the
    -- "Load rear tank" wording read like a second tank bind). Shift+Y below picks the tank.
    if self._eventIds.dir ~= nil then
        connected = connected and not self:_awayWithPipe()
        g_inputBinding:setActionEventTextVisibility(self._eventIds.dir, connected)
        if connected then
            g_inputBinding:setActionEventText(self._eventIds.dir,
                g_i18n:getText(direction == SPS_SPRAYER_DIRECTION_FILL and "action_sprayerDirLoad" or "action_sprayerDirUnload"))
        end
    end
    local tankLabel = g_slurryPipeManager.llTankLabel ~= nil and g_slurryPipeManager:llTankLabel(self.object, coupling) or nil
    if self._eventIds.tank ~= nil then
        local show = tankLabel ~= nil and not self:_awayWithPipe()
        g_inputBinding:setActionEventTextVisibility(self._eventIds.tank, show)
        if show then
            g_inputBinding:setActionEventText(self._eventIds.tank, string.format(g_i18n:getText("action_spsLaneTank"), tankLabel))
        end
    end
    -- [SPS MKS8 2026-11-10] N: the door (loadAnimation) - open / close, at the node only
    if self._eventIds.door ~= nil then
        local hasDoor = llEntry ~= nil and llEntry.state.loadAnimName ~= nil
        local show = hasDoor and not self:_awayWithPipe()
        g_inputBinding:setActionEventTextVisibility(self._eventIds.door, show)
        if show then
            local open = coupling.loadAnimPlayed == true
            local txt = SlurryPipeManager.llConfigText ~= nil and SlurryPipeManager.llConfigText(open and llEntry.doorTextClose or llEntry.doorTextOpen) or nil
            if txt == nil or txt == "" then txt = g_i18n:getText(open and "action_spsLaneDoorClose" or "action_spsLaneDoorOpen") end
            g_inputBinding:setActionEventText(self._eventIds.door, txt)
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

    -- [SPS MKS8 2026-11-10] N: the door (loadAnimation), the sprayer's key for its cover
    if InputAction.SPS_TOGGLE_ANIMATION_SPRAYER ~= nil then
        local _, doorId = g_inputBinding:registerActionEvent(
            InputAction.SPS_TOGGLE_ANIMATION_SPRAYER, self,
            function(target, actionName, inputValue, callbackState, isAnalog)
                if inputValue > 0 then target:_onDoor() end
            end,
            false, true, false, true, nil, true, false
        )
        if doorId ~= nil then
            g_inputBinding:setActionEventText(doorId, g_i18n:getText("action_spsLaneDoorOpen"))
            g_inputBinding:setActionEventTextPriority(doorId, GS_PRIO_VERY_HIGH)
            g_inputBinding:setActionEventTextVisibility(doorId, false)
            self._eventIds.door = doorId
        end
    end

    -- [SPS MKS8 2026-11-11] Shift+Y: the next tank of a multi-tank fitting (modDesc SPS_SELECT_TANK)
    if InputAction.SPS_SELECT_TANK ~= nil then
        local _, tankId = g_inputBinding:registerActionEvent(
            InputAction.SPS_SELECT_TANK, self,
            function(target, actionName, inputValue, callbackState, isAnalog)
                if inputValue > 0 then target:_onTank() end
            end,
            false, true, false, true, nil, true, false
        )
        if tankId ~= nil then
            g_inputBinding:setActionEventText(tankId, g_i18n:getText("input_SPS_SELECT_TANK"))
            g_inputBinding:setActionEventTextPriority(tankId, GS_PRIO_VERY_HIGH)
            g_inputBinding:setActionEventTextVisibility(tankId, false)
            self._eventIds.tank = tankId
        end
    end

    -- [SPS 2026-11-09] take / return the bowser's wash hose (original mode)
    -- [SPS 2026-11-10] on its OWN key, H (modDesc SPS_BOWSER_HOSE): X is also the hands' secondary action in William's
    -- bindings, which carries the right-mouse pour (William: "change the key bind")
    local washAction = InputAction.SPS_BOWSER_HOSE or InputAction.SPS_TOGGLE_ANIMATION
    if washAction ~= nil then
        local _, washId = g_inputBinding:registerActionEvent(
            washAction, self,
            function(target, actionName, inputValue, callbackState, isAnalog)
                if inputValue > 0 then target:_onWash() end
            end,
            false, true, false, true, nil, true, false
        )
        if washId ~= nil then
            g_inputBinding:setActionEventText(washId, g_i18n:getText("action_spsTakeWash"))
            g_inputBinding:setActionEventTextPriority(washId, GS_PRIO_VERY_HIGH)
            g_inputBinding:setActionEventTextVisibility(washId, false)
            self._eventIds.wash = washId
        end
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
    if self:_awayWithPipe() then return end   -- [2026-11-10] away from the node with a pipe in hand: only H = put back
    if g_slurryPipeManager.physicalPipesEnabled == true then
        -- [SPS 1.0.1.8] physical pipes: plug / unplug is the mouse; R here = the plugged fitting's valve
        -- [SPS 1.0.2.0] (or the bare fitting's valve - pipe or no pipe)
        if coupling.hasValve == false then return end   -- [SPS MKS8] nothing to turn
        if g_slurryPipeManager.onLaneFittingValveToggle ~= nil then
            log("_onActivate: fitting valve toggle id=%s", tostring(coupling.id))
            g_slurryPipeManager:onLaneFittingValveToggle(coupling)
        end
        return
    end
    if coupling.isConnected then
        log("_onActivate: disconnect id=%s", tostring(coupling.id))
        g_slurryPipeManager:onLiquidLaneDisconnect(self.object, coupling)
    elseif coupling.origSuction ~= nil and coupling.origSuction.carried then
        -- [SPS 2026-11-10] R with the suction end in hand = release it where it is (the same lay as the right mouse)
        log("_onActivate: release suction id=%s", tostring(coupling.id))
        if SlurryPipeManager._llOrigLanceAction ~= nil then SlurryPipeManager._llOrigLanceAction(coupling, "ACTIVATE_OBJECT", 1) end
    elseif coupling.origSuction ~= nil then
        -- [SPS 2026-11-09] take the laid suction pipe up (back on the bowser)
        log("_onActivate: remove suction id=%s", tostring(coupling.id))
        if g_server ~= nil then g_slurryPipeManager:applyLiquidLaneOrigPipe(self.object, coupling.id, 1, false, 0, 0, 0, -1) end
        SPSLiquidLaneOrigPipeEvent.sendEvent(self.object, coupling.id, 1, false, 0, 0, 0, -1)
    else
        local overlap = g_slurryPipeManager:findOverlappingLiquidLaneCoupler(coupling)
        if overlap == nil and coupling.waterSourceKey ~= nil then
            -- [SPS 2026-11-09] nothing to connect to: lay the suction pipe to where the player stands (within the pipe's reach)
            local fn = coupling.inNode or coupling.mountNode
            local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
            local fx, fy, fz = getWorldTranslation(fn)
            -- [SPS 2026-11-10] reach = the suction pipe's own length (7.75 m), not the fitting's 80 mm-capped 4 m
            local reach = g_slurryPipeManager.llOrigPipeReach ~= nil and g_slurryPipeManager:llOrigPipeReach(coupling, 1) or (coupling.maxPipeLength or 7.5)
            if MathUtil.vector3Length(px - fx, py - fy, pz - fz) > reach then
                if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                    g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSuctionReach"), 2500)
                end
                return
            end
            -- [SPS 2026-11-10] ...into the player's hands (the end follows, right mouse lays it), like the wash hose
            local userId = g_currentMission ~= nil and g_currentMission.playerUserId or -1
            log("_onActivate: take suction id=%s", tostring(coupling.id))
            if g_server ~= nil then g_slurryPipeManager:applyLiquidLaneOrigPipe(self.object, coupling.id, 1, true, px, py + 0.9, pz, userId) end
            SPSLiquidLaneOrigPipeEvent.sendEvent(self.object, coupling.id, 1, true, px, py + 0.9, pz, userId)
            return
        end
        log("_onActivate: connect id=%s", tostring(coupling.id))
        g_slurryPipeManager:onLiquidLaneConnect(self.object, coupling)
    end
end

-- [SPS 2026-11-09] the fitting that takes the wash hose (washOutlet), or nil
function SPSLiquidLaneControl:_getWashCoupling()
    if g_slurryPipeManager == nil then return nil end
    local entry = g_slurryPipeManager:getLiquidLaneVehicleEntry(self.object)
    for _, c in ipairs(entry ~= nil and entry.couplings or {}) do
        if c.washOutletKey ~= nil then return c end
    end
    return nil
end

function SPSLiquidLaneControl:_onWash()
    if g_slurryPipeManager == nil or g_slurryPipeManager.physicalPipesEnabled == true then return end
    -- [SPS 2026-11-10] the carried suction end: X puts it back on the rack (anywhere)
    local heldC, heldKind = self:_localHolds()
    if heldC ~= nil and heldKind == 1 then
        log("_onWash: put the carried suction pipe back id=%s", tostring(heldC.id))
        if g_server ~= nil then g_slurryPipeManager:applyLiquidLaneOrigPipe(self.object, heldC.id, 1, false, 0, 0, 0, -1) end
        SPSLiquidLaneOrigPipeEvent.sendEvent(self.object, heldC.id, 1, false, 0, 0, 0, -1)
        return
    end
    local wc = self:_getWashCoupling()
    if wc == nil then return end
    local on = wc.origWash == nil
    if on and self:_awayWithPipe() then return end   -- [2026-11-10] taking happens at the bowser only
    -- [SPS 2026-11-10] the wash hose cannot be taken before the engine runs (William: "refuse to pick up unless the engine is
    -- running") - B first, then H; the pour then only needs the right mouse
    if on then
        local entry = g_slurryPipeManager:getLiquidLaneVehicleEntry(self.object)
        local gen = entry ~= nil and entry.generator or nil
        if gen ~= nil and (not entry.state.valveOpen or gen.phase ~= "run") then
            if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsWashEngineFirst"), 2500)
            end
            log("_onWash: refused - engine not running")
            return
        end
    end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local userId = g_currentMission ~= nil and g_currentMission.playerUserId or -1
    log("_onWash: %s", on and "take" or "return")
    if g_server ~= nil then g_slurryPipeManager:applyLiquidLaneOrigPipe(self.object, wc.id, 2, on, px, py + 0.9, pz, userId) end
    SPSLiquidLaneOrigPipeEvent.sendEvent(self.object, wc.id, 2, on, px, py + 0.9, pz, userId)
end

-- [SPS MKS8 2026-11-10] N: open / close the door
function SPSLiquidLaneControl:_onDoor()
    if g_slurryPipeManager == nil or g_slurryPipeManager.onLiquidLaneToggleDoor == nil then return end
    if self:_awayWithPipe() then return end
    log("_onDoor: toggle")
    g_slurryPipeManager:onLiquidLaneToggleDoor(self.object)
end

function SPSLiquidLaneControl:_onFlow()
    if g_slurryPipeManager == nil then return end
    if self:_awayWithPipe() then return end   -- [2026-11-10] B at the pump only
    log("_onFlow: toggle")
    g_slurryPipeManager:onLiquidLaneToggleValve(self.object)
end

-- [SPS MKS8 2026-11-11] Shift+Y: next tank
function SPSLiquidLaneControl:_onTank()
    if g_slurryPipeManager == nil or g_slurryPipeManager.onLiquidLaneNextTank == nil then return end
    if self:_awayWithPipe() then return end
    log("_onTank: next")
    g_slurryPipeManager:onLiquidLaneNextTank(self.object)
end

function SPSLiquidLaneControl:_onDirection()
    if g_slurryPipeManager == nil or g_slurryPipeManager.onLiquidLaneToggleDirection == nil then return end
    if self:_awayWithPipe() then return end   -- [2026-11-10] Y at the pump only  ([SPS MKS8] unconnected: picks the tank)
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
    -- [SPS 2026-11-09] never the wash outlet (550 bowser: it has no valve) - R always works the inlet valve
    for _, c in ipairs(entry.couplings) do
        if c.physPipe ~= nil and c.washOutletKey == nil then return c end
    end
    for _, c in ipairs(entry.couplings) do
        if c.washOutletKey == nil then return c end
    end
    return entry.couplings[1]
end
