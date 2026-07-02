-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4

-- SPSBlockageActivatable.lua
-- FS25_SlurryPipeSystem
--
-- Walk-up, hold-to-clear activatable for a single spreader blockage node. It appears
-- on foot within range of a BLOCKED node; holding ACTIVATE_OBJECT for HOLD_THRESHOLD
-- clears that node — but only while the bar is stopped (vacuum: line vented to ~0 bar;
-- HVP / pump-gated: pump off), per the controlling tanker's drive model. Clearing is
-- routed through SlurryPipeManager:onClearBlockage, which re-checks the stop gate and
-- syncs via SPSBlockageEvent. Mirrors the press/hold handling of SPSPipeActivatable.

SPSBlockageActivatable = {}
SPSBlockageActivatable.__index = SPSBlockageActivatable

SPSBlockageActivatable.ACTIVATE_RADIUS = 2.0   -- metres, player must be within this of the node
SPSBlockageActivatable.HOLD_THRESHOLD  = 1.0   -- seconds of hold to clear

function SPSBlockageActivatable.new(vehicle, blockageEntry)
    local self          = setmetatable({}, SPSBlockageActivatable)
    self.vehicle        = vehicle          -- the spreader implement carrying the node
    self.blockageEntry  = blockageEntry
    self.activateText   = ""
    self._holdTime      = 0
    self._isHolding     = false
    self._fired         = false
    self._warned        = false
    self._actionEventId = nil
    return self
end

function SPSBlockageActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

-- ---------------------------------------------------------------------------
-- ActivatableObjectsSystem interface
-- ---------------------------------------------------------------------------
function SPSBlockageActivatable:getIsActivatable(dirX, dirY, dirZ)
    if g_localPlayer == nil then return false end
    local b = self.blockageEntry
    if b == nil or b.blocked ~= true then return false end                 -- only when blocked
    if b.node == nil or not entityExists(b.node) then return false end
    -- AI guard: hide when the owning vehicle's root is AI-driven.
    if self.vehicle ~= nil
    and SlurryPipeSystemOverride ~= nil
    and SlurryPipeSystemOverride.isAIControlled(self.vehicle) then
        return false
    end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local nx, ny, nz = getWorldTranslation(b.node)
    local dist = MathUtil.vector3Length(px - nx, py - ny, pz - nz)
    return dist <= SPSBlockageActivatable.ACTIVATE_RADIUS
end

function SPSBlockageActivatable:getDistance(posX, posY, posZ)
    local b = self.blockageEntry
    if b == nil or b.node == nil or not entityExists(b.node) then return math.huge end
    local nx, ny, nz = getWorldTranslation(b.node)
    return MathUtil.vector3Length(posX - nx, posY - ny, posZ - nz)
end

function SPSBlockageActivatable:activate()
    self._holdTime    = 0
    self._isHolding   = false
    self._fired       = false
    self._warned      = false
    self.activateText = self:_buildActivateText()
end

function SPSBlockageActivatable:deactivate()
    self._isHolding = false
    self._holdTime  = 0
    self._fired     = false
    self._warned    = false
end

function SPSBlockageActivatable:update(dt)
    self.activateText = self:_buildActivateText()
    if self._actionEventId ~= nil then
        g_inputBinding:setActionEventText(self._actionEventId, self.activateText)
    end

    if self._isHolding and not self._fired then
        if self:_canClear() then
            self._holdTime = self._holdTime + dt * 0.001
            if self._holdTime >= SPSBlockageActivatable.HOLD_THRESHOLD then
                self._fired = true
                if g_slurryPipeManager ~= nil then
                    g_slurryPipeManager:onClearBlockage(self.vehicle, self.blockageEntry)
                end
            end
        else
            -- Can't clear a live/pressurised bar — hold makes no progress; nudge once.
            self._holdTime = 0
            if not self._warned then
                self._warned = true
                if g_currentMission ~= nil then
                    g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsClearBlocked"), 2000)
                end
            end
        end
    end
end

function SPSBlockageActivatable:run()
    -- Custom input is always used; this is only a fallback.
end

function SPSBlockageActivatable:registerCustomInput(inputContext)
    self._holdTime  = 0
    self._isHolding = false
    self._fired     = false
    self._warned    = false

    -- ActivatableObjectsSystem:registerInput already wraps this in
    -- begin/endActionEventsModification — do NOT call them here.
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

function SPSBlockageActivatable:removeCustomInput()
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
function SPSBlockageActivatable:_onActivateInput(actionName, inputValue, callbackState, isAnalog)
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

function SPSBlockageActivatable:_canClear()
    if g_slurryPipeManager == nil then return false end
    return g_slurryPipeManager:canClearBlockage(self.vehicle) == true
end

-- Friendly label: macerator -> localised "Macerator"; outlets -> e.g. "Left 01".
function SPSBlockageActivatable:_label()
    local b = self.blockageEntry
    if b ~= nil and b.isMacerator then
        return g_i18n:getText("sps_blockageMacerator")
    end
    local n = tostring(b and b.name or "")
    n = n:gsub("^SPS_blockageNode", "")
    n = n:gsub("(%a)(%d)", "%1 %2")
    if n == "" then n = "outlet" end
    return n
end

function SPSBlockageActivatable:_buildActivateText()
    local label = self:_label()
    if self:_canClear() then
        return string.format(g_i18n:getText("action_spsClearBlockage"), label)
    end
    return string.format(g_i18n:getText("action_spsClearBlockageWait"), label)
end
