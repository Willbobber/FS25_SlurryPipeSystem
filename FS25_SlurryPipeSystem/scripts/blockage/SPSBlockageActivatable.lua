-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.8

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
    if SPSAccess ~= nil and not SPSAccess.localCanUse(self.vehicle) then return false end   -- [SPS 1.0.1.8] farm permission
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
    if self._isHolding and not self._fired then self:_abortClearing() end
    self._isHolding = false
    self._holdTime  = 0
    self._fired     = false
    self._warned    = false
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.6] Clearing phase machine (William's confirmed spec).
-- A blockage shows NOTHING when it happens. Holding R runs, strictly in order:
--   Phase "fwd"  — blockageAnimation plays FORWARD (mechanism opens)
--   Phase "work" — the clearing time (HOLD_THRESHOLD, unchanged fallback X)
--   Phase "rev"  — animation plays back to the start (mechanism closes)
-- and only THEN is the blockage cleared. Total hold = animLen + X + animLen.
-- Releasing R (or the gate failing: pump on / spreader valve open / pressure
-- not vented) at ANY point aborts: the animation winds back to the start,
-- the blockage stays, and the next attempt starts from scratch.
-- No animation authored (the fallback) -> "fwd"/"rev" are zero-length and the
-- behaviour is exactly the old plain X-second hold.
-- MP: the local player drives the phases; every play/wind-back is replicated
-- via SPSBlockageClearAnimEvent so all peers watch the attempt.
-- ---------------------------------------------------------------------------
function SPSBlockageActivatable:_clearAnimName()
    local b = self.blockageEntry
    local v = self.vehicle
    if b == nil or v == nil then return nil end
    local name = b.blockageAnimation
    if name == nil or name == "" then return nil end
    if v.getAnimationExists == nil or not v:getAnimationExists(name) then return nil end
    return name
end

function SPSBlockageActivatable:_animPlay(forward)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:playBlockageClearAnimation(self.vehicle, self.blockageEntry, forward)
    if SPSBlockageClearAnimEvent ~= nil then
        local idx = g_slurryPipeManager:getBlockageNodeIndex(self.vehicle, self.blockageEntry)
        if idx ~= nil then
            SPSBlockageClearAnimEvent.sendEvent(self.vehicle, idx, forward)
        end
    end
end

function SPSBlockageActivatable:_animTime()
    local name = self:_clearAnimName()
    if name == nil then return nil end
    if self.vehicle.getAnimationTime == nil then return nil end
    return self.vehicle:getAnimationTime(name) or 0
end

-- Abort from any phase: wind the mechanism back and reset all progress.
function SPSBlockageActivatable:_abortClearing()
    if self._phase == "fwd" or self._phase == "work" then
        -- Mechanism is (partly) open: wind it back. From "rev" it is already
        -- closing, so just let it finish.
        if self:_clearAnimName() ~= nil then
            self:_animPlay(false)
        end
    end
    self._phase    = nil
    self._workTime = 0
    self._holdTime = 0
end

function SPSBlockageActivatable:update(dt)
    self.activateText = self:_buildActivateText()
    if self._actionEventId ~= nil then
        g_inputBinding:setActionEventText(self._actionEventId, self.activateText)
    end

    if self._isHolding and not self._fired then
        if self:_canClear() then
            local hasAnim = self:_clearAnimName() ~= nil
            if self._phase == nil then
                -- Sequence start.
                self._workTime = 0
                if hasAnim then
                    self._phase = "fwd"
                    self:_animPlay(true)
                else
                    self._phase = "work"
                end
            elseif self._phase == "fwd" then
                local t = self:_animTime()
                if t == nil or t >= 0.999 then
                    self._phase    = "work"
                    self._workTime = 0
                end
            elseif self._phase == "work" then
                self._workTime = self._workTime + dt * 0.001
                if self._workTime >= SPSBlockageActivatable.HOLD_THRESHOLD then
                    if hasAnim then
                        self._phase = "rev"
                        self:_animPlay(false)
                    else
                        self._fired = true
                        self._phase = nil
                        if g_slurryPipeManager ~= nil then
                            g_slurryPipeManager:onClearBlockage(self.vehicle, self.blockageEntry)
                        end
                    end
                end
            elseif self._phase == "rev" then
                local t = self:_animTime()
                if t == nil or t <= 0.001 then
                    self._fired = true
                    self._phase = nil
                    if g_slurryPipeManager ~= nil then
                        g_slurryPipeManager:onClearBlockage(self.vehicle, self.blockageEntry)
                    end
                end
            end
        else
            -- Can't clear a live bar (pump on / spreader valve open / pressure
            -- not vented) — abort any progress; nudge once.
            self:_abortClearing()
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
        self._phase     = nil
        self._workTime  = 0
    else
        -- [SPS 1.0.1.6] Released mid-sequence: abort — wind the mechanism back,
        -- keep the blockage, next attempt starts from scratch.
        if self._isHolding and not self._fired then
            self:_abortClearing()
        end
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
