-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.2.0

-- SPSM_ActivatableGate.lua — [SPS GATE 2026-10-28]
--
-- ActivatableObjectsSystem:updateObjects polls EVERY registered object EVERY frame
-- (getIsActivatable, getHasAccess, getDistance - all Lua). The base game only
-- registers an activatable while the player stands in its trigger, so its list is
-- a handful of objects. SPS registered every coupler, control node, chain end,
-- blockage and buy-station activatable for the life of the vehicle or placeable,
-- so the whole map's worth was polled at 60 Hz (profiler 2026-09-11:
-- system ActivatableObjectsSystem:update 2.4 ms/frame with the full mod list).
--
-- The gate keeps an SPS activatable OUT of the system until the player is within
-- GATE_IN_M of it, checked every GATE_PERIOD_MS with the object's own
-- getDistance(), and takes it out again past GATE_OUT_M (hysteresis so a node on
-- the edge does not flap). Player position is the system's own posX/Y/Z, fed by
-- PlayerOnFootStateMachine / Enterable. No position known (dedicated server,
-- menus, loading) = everything registered, i.e. the old behaviour.
--
-- Registration sites call SlurryPipeManager.gateAdd(act) instead of
-- g_currentMission.activatableObjectsSystem:addActivatable(act). Deletion is
-- unchanged: every activatable's delete() still calls removeActivatable(self), and
-- the appended hook below drops it from the gate so it is never re-added.
-- Trigger-driven activatables (SPSSprayerTankSwitchActivatable) do not go through
-- the gate - they already register only while the player is in their trigger.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSM_ActivatableGate 1.0.2.0 loaded") end

SlurryPipeManager.GATE_IN_M      = 20     -- registered once the player is this close
SlurryPipeManager.GATE_OUT_M     = 25     -- unregistered again past this
SlurryPipeManager.GATE_PERIOD_MS = 250    -- distance pass cadence (4 Hz instead of the system's 60 Hz)

local function glog(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("SPSM_ActivatableGate") then return end
    if select("#", ...) > 0 then
        print("[SPS GATE] " .. string.format(fmt, ...))
    else
        print("[SPS GATE] " .. tostring(fmt))
    end
end

local function gateSystem()
    if g_currentMission == nil then return nil end
    return g_currentMission.activatableObjectsSystem
end

-- Static entry point for every registration site (manager methods and free
-- classes alike). Falls back to a plain add if the manager is not up yet.
function SlurryPipeManager.gateAdd(act)
    local m = g_slurryPipeManager
    if m ~= nil and m.gateActivatable ~= nil then
        m:gateActivatable(act)
        return
    end
    local sys = gateSystem()
    if sys ~= nil and act ~= nil then
        sys:addActivatable(act)
    end
end

function SlurryPipeManager:_gateState()
    if self._gate == nil then
        self._gate = { list = {}, index = {}, timer = 0, inside = 0 }
    end
    return self._gate
end

-- Distance from the player to the activatable, by the object's own rule. An
-- object without getDistance cannot be placed, so it stays registered (0).
-- pcall: getDistance reads a node that a mid-delete object may no longer have.
function SlurryPipeManager:_gateDistance(act, px, py, pz)
    if act.getDistance == nil then return 0 end
    local ok, d = pcall(act.getDistance, act, px, py, pz)
    if not ok or type(d) ~= "number" then return 0 end
    return d
end

function SlurryPipeManager:gateActivatable(act)
    if act == nil then return end
    local sys = gateSystem()
    if sys == nil then return end
    local g = self:_gateState()
    if g.index[act] ~= nil then return end
    local e = { act = act, inside = false }
    g.index[act] = e
    table.insert(g.list, e)
    -- settle it now rather than waiting up to one period: near (or no player
    -- position) = in straight away, the old behaviour
    local px, py, pz = sys.posX, sys.posY, sys.posZ
    if px == nil or self:_gateDistance(act, px, py, pz) <= SlurryPipeManager.GATE_IN_M then
        e.inside = true
        g.inside = g.inside + 1
        sys:addActivatable(act)
    end
    glog("gate add %s (inside=%s) gated=%d registered=%d", tostring(act.activateText), tostring(e.inside), #g.list, g.inside)
end

-- Called from the removeActivatable hook when an activatable is deleted.
function SlurryPipeManager:ungateActivatable(act)
    local g = self._gate
    if g == nil or act == nil then return end
    local e = g.index[act]
    if e == nil then return end
    g.index[act] = nil
    for i = #g.list, 1, -1 do
        if g.list[i] == e then
            table.remove(g.list, i)
            break
        end
    end
    if e.inside then g.inside = g.inside - 1 end
    glog("gate drop %s gated=%d registered=%d", tostring(act.activateText), #g.list, g.inside)
end

-- Ticked from SlurryPipeManager:update. One getDistance per gated object every
-- GATE_PERIOD_MS; nothing else runs between passes.
function SlurryPipeManager:updateActivatableGate(dt)
    local g = self._gate
    if g == nil or #g.list == 0 then return end
    g.timer = g.timer + (dt or 0)
    if g.timer < SlurryPipeManager.GATE_PERIOD_MS then return end
    g.timer = 0
    local sys = gateSystem()
    if sys == nil then return end
    local px, py, pz = sys.posX, sys.posY, sys.posZ
    local inM, outM = SlurryPipeManager.GATE_IN_M, SlurryPipeManager.GATE_OUT_M
    local added, removed = 0, 0
    for i = 1, #g.list do
        local e = g.list[i]
        local want
        if px == nil then
            want = true
        else
            local d = self:_gateDistance(e.act, px, py, pz)
            if e.inside then
                want = d <= outM
            else
                want = d <= inM
            end
        end
        if want ~= e.inside then
            e.inside = want
            if want then
                g.inside = g.inside + 1
                added = added + 1
                sys:addActivatable(e.act)
            else
                g.inside = g.inside - 1
                removed = removed + 1
                self._gateRemoving = true
                sys:removeActivatable(e.act)
                self._gateRemoving = false
            end
        end
    end
    if added > 0 or removed > 0 then
        glog("gate pass: +%d -%d -> registered %d of %d gated", added, removed, g.inside, #g.list)
    end
end

-- Any removeActivatable that is not the gate's own (i.e. the object's delete())
-- drops the object from the gate so a later pass cannot re-add a dead object.
if ActivatableObjectsSystem ~= nil and not SlurryPipeManager._gateRemoveHooked then
    SlurryPipeManager._gateRemoveHooked = true
    ActivatableObjectsSystem.removeActivatable = Utils.appendedFunction(ActivatableObjectsSystem.removeActivatable,
        function(sys, object)
            local m = g_slurryPipeManager
            if m ~= nil and object ~= nil and not m._gateRemoving and m.ungateActivatable ~= nil then
                m:ungateActivatable(object)
            end
        end)
end
