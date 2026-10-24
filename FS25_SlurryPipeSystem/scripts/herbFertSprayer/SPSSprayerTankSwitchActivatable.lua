-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSSprayerTankSwitchActivatable.lua
-- FS25_SlurryPipeSystem
--
-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Walk-up tank switch for a MULTI-TANK sprayer-source coupler
-- (a <sprayerPipeCoupling> with <tank> children, README 03 §9C).
--
-- One object per multi-tank coupler. The player picks which physical tank
-- the single connection routes to:
--   * preferred: a player trigger cube (`switchTriggerNode`, shape with
--     trigger=true, group TRIGGER 0x20000000, mask PLAYER 0x100000 — the
--     same flags as a vanilla infoTrigger). The activatable is added to the
--     activatable system on trigger ENTER and removed on LEAVE, exactly like
--     PlaceableInfoTrigger — zero per-frame distance polling.
--   * fallback: `switchNodeName` + `switchRadius` (distance poll, the
--     buying-station switch model), or the coupler mount when neither is given.
-- Activation uses the vanilla activate key (R by default); holding Shift
-- steps backwards (same engine-level Input.isKeyPressed read as the buying
-- station switch). The prompt hides while liquid is flowing through the
-- coupler (SlurryPipeManager:isSprayerCouplerFlowing) — the server refuses
-- the switch in that state anyway, hiding keeps the prompt honest.
--
-- Optional marker: `switchMarkerNode` + `switchMarkerIcon` (default the
-- vanilla question-mark marker) loaded through g_i3DManager and registered
-- with g_currentMission:addTriggerMarker, so it obeys the "show trigger
-- markers" game setting like every vanilla marker.
--
-- Selection state is server-authoritative: run() asks the manager, which
-- applies locally on the server or sends SPSSprayerTankSelectEvent.REQ from a
-- client; the STATE broadcast updates every peer's prompt.
-- ---------------------------------------------------------------------------

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSSprayerTankSwitchActivatable 1.0.1.8 loaded") end

SPSSprayerTankSwitchActivatable = {}
SPSSprayerTankSwitchActivatable.__index = SPSSprayerTankSwitchActivatable

-- Debug: central registry channel "SPSSprayerTankSwitch" (SPSDebugConfig).
local function log(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("SPSSprayerTankSwitch") then return end
    if select("#", ...) > 0 then
        print("[SPS TANK SW] " .. string.format(fmt, ...))
    else
        print("[SPS TANK SW] " .. tostring(fmt))
    end
end

-- True while either Shift key is held. Engine built-in behind nil-guards;
-- any missing symbol = false (forward-only cycling).
local function isShiftDown()
    if Input == nil or Input.isKeyPressed == nil then return false end
    if Input.KEY_lshift ~= nil and Input.isKeyPressed(Input.KEY_lshift) then return true end
    if Input.KEY_rshift ~= nil and Input.isKeyPressed(Input.KEY_rshift) then return true end
    return false
end

local function nodeOk(node)
    return node ~= nil and node ~= 0 and entityExists(node)
end

function SPSSprayerTankSwitchActivatable.new(entry, sc)
    local self        = setmetatable({}, SPSSprayerTankSwitchActivatable)
    self.entry        = entry
    self.sc           = sc
    self.activateText = ""
    self.playerInside = false
    self.registered   = false
    self.deleted      = false

    -- Anchor: trigger cube (enter/leave), else node + radius poll.
    if nodeOk(sc.switchTriggerNode) then
        self.triggerNode = sc.switchTriggerNode
        addTrigger(self.triggerNode, "onSwitchTriggerCallback", self)
        self.triggerAdded = true
        log("new: %s coupler=%s trigger cube '%s'",
            tostring(entry.object and entry.object.configFileName), tostring(sc.id),
            tostring(getName(self.triggerNode)))
    else
        self.radius = sc.switchRadius or 3.0
        self:_register()
        log("new: %s coupler=%s radius %.1f m at '%s'",
            tostring(entry.object and entry.object.configFileName), tostring(sc.id), self.radius,
            tostring(nodeOk(self:_anchorNode()) and getName(self:_anchorNode()) or "?"))
    end

    -- Marker icon (vanilla trigger-marker system).
    if nodeOk(sc.switchMarkerNode) and g_i3DManager ~= nil and sc.switchMarkerIcon ~= nil
    and sc.switchMarkerIcon ~= "" then
        local baseDir = (g_currentMission ~= nil and g_currentMission.spsModDirectory) or ""
        local file = Utils.getFilename(sc.switchMarkerIcon, baseDir)
        if file ~= nil then
            self.markerLoadId = g_i3DManager:loadSharedI3DFileAsync(file, false, false,
                self.onMarkerLoaded, self, nil)
        end
    end
    return self
end

function SPSSprayerTankSwitchActivatable:onMarkerLoaded(i3dNode, failedReason, args)
    if i3dNode == nil or i3dNode == 0 then
        log("marker icon failed to load (%s)", tostring(failedReason))
        return
    end
    if self.deleted or not nodeOk(self.sc.switchMarkerNode) then
        delete(i3dNode)
        return
    end
    link(self.sc.switchMarkerNode, i3dNode)
    self.markerNode = i3dNode
    if g_currentMission ~= nil and g_currentMission.addTriggerMarker ~= nil then
        g_currentMission:addTriggerMarker(i3dNode)
    end
end

function SPSSprayerTankSwitchActivatable:_register()
    if self.registered or self.deleted then return end
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:addActivatable(self)
        self.registered = true
    end
end

function SPSSprayerTankSwitchActivatable:_unregister()
    if not self.registered then return end
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
    self.registered = false
end

-- Engine trigger callback (same signature as PlaceableInfoTrigger).
function SPSSprayerTankSwitchActivatable:onSwitchTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    if g_localPlayer == nil or otherId ~= g_localPlayer.rootNode then return end
    if onEnter then
        self.playerInside = true
        self:_register()
        log("player entered switch trigger (coupler=%s)", tostring(self.sc.id))
    elseif onLeave then
        self.playerInside = false
        self:_unregister()
        log("player left switch trigger (coupler=%s)", tostring(self.sc.id))
    end
end

function SPSSprayerTankSwitchActivatable:delete()
    self.deleted = true
    if self.triggerAdded and nodeOk(self.triggerNode) then
        removeTrigger(self.triggerNode)
    end
    self.triggerAdded = false
    self:_unregister()
    if self.markerNode ~= nil then
        if g_currentMission ~= nil and g_currentMission.removeTriggerMarker ~= nil then
            g_currentMission:removeTriggerMarker(self.markerNode)
        end
        self.markerNode = nil
    end
    if self.markerLoadId ~= nil and g_i3DManager ~= nil then
        g_i3DManager:releaseSharedI3DFile(self.markerLoadId)
        self.markerLoadId = nil
    end
end

function SPSSprayerTankSwitchActivatable:_anchorNode()
    local sc = self.sc
    if nodeOk(self.triggerNode) then return self.triggerNode end
    if nodeOk(sc.switchNode) then return sc.switchNode end
    if nodeOk(sc.mountNode) then return sc.mountNode end
    return nil
end

function SPSSprayerTankSwitchActivatable:getIsActivatable()
    if SPSAccess ~= nil and not SPSAccess.localCanUse(self.entry) then return false end   -- [SPS 1.0.1.8] farm permission
    if g_localPlayer == nil or self.deleted then return false end
    local sc = self.sc
    if sc.tanks == nil or #sc.tanks < 2 then return false end
    -- Never offer a switch while liquid is moving through this coupler.
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.isSprayerCouplerFlowing ~= nil
    and g_slurryPipeManager:isSprayerCouplerFlowing(sc) then
        return false
    end
    if self.triggerNode ~= nil then
        if not self.playerInside then return false end
    else
        local node = self:_anchorNode()
        if node == nil then return false end
        local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
        local cx, cy, cz = getWorldTranslation(node)
        if MathUtil.vector3Length(px - cx, py - cy, pz - cz) > (self.radius or 3.0) then
            return false
        end
    end
    self.activateText = self:_buildText()
    return true
end

function SPSSprayerTankSwitchActivatable:getDistance(posX, posY, posZ)
    local node = self:_anchorNode()
    if node == nil then return math.huge end
    local cx, cy, cz = getWorldTranslation(node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSSprayerTankSwitchActivatable:activate()
end

function SPSSprayerTankSwitchActivatable:deactivate()
end

function SPSSprayerTankSwitchActivatable:update(dt)
    self.activateText = self:_buildText()
end

function SPSSprayerTankSwitchActivatable:run()
    local entry = self.entry
    local placeable = entry ~= nil and entry.object or nil
    if placeable == nil or g_slurryPipeManager == nil
    or g_slurryPipeManager.requestSprayerTankToggle == nil then return end
    local backwards = isShiftDown()
    log("run: coupler=%s backwards=%s", tostring(self.sc.id), tostring(backwards))
    g_slurryPipeManager:requestSprayerTankToggle(placeable, self.sc.id, backwards)
end

-- "Tank 2 (Herbicide 12,000 l) - switch to tank 3 (Empty)"; Shift shows the
-- previous tank as the target, matching what run() will step to.
local function tankContents(t)
    if t == nil then return "?" end
    if t.dynFillType ~= nil and (t.dynLevel or 0) > 0 then
        local title = g_fillTypeManager:getFillTypeTitleByIndex(t.dynFillType) or "?"
        local vol
        if g_i18n ~= nil and g_i18n.formatVolume ~= nil then
            vol = g_i18n:formatVolume(t.dynLevel or 0, 0)
        else
            vol = string.format("%d l", math.floor((t.dynLevel or 0) + 0.5))
        end
        return string.format("%s %s", title, vol)
    end
    return g_i18n:getText("sps_infoTankEmpty")
end

function SPSSprayerTankSwitchActivatable:_buildText()
    local sc = self.sc
    if sc.tanks == nil or #sc.tanks == 0 then return "" end
    local n      = #sc.tanks
    local curIdx = sc.selectedTank or 1
    if curIdx < 1 or curIdx > n then curIdx = 1 end
    local nextIdx
    if isShiftDown() then
        nextIdx = ((curIdx - 2) % n) + 1
    else
        nextIdx = (curIdx % n) + 1
    end
    local cur, nxt = sc.tanks[curIdx], sc.tanks[nextIdx]
    return string.format(g_i18n:getText("action_spsTankSwitch"),
        tostring(cur and cur.id or curIdx), tankContents(cur),
        tostring(nxt and nxt.id or nextIdx), tankContents(nxt))
end
