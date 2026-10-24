-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSLaneValveActivatable.lua
-- [SPS 1.0.1.8] Walk-up prompt at a BARN's 80 mm lane fitting (water / milk coupler), PHYSICAL pipe mode only.
-- (The vehicle fitting's valve is R at the vehicle's control node, SPSLiquidLaneControl, since 2026-10-18 -
-- two activatables in one spot hide each other.) William 2026-10-17: water and milk work "the same as slurry" - a valve at
-- every fitting, the tanker is always the pump. R toggles THIS fitting's ball valve (coupling.ballValveOpen;
-- the coupling's valveAnimation is the handle). Liquid moves only while both fittings' valves are open AND
-- the pump runs (B at the tanker's control node, SPSLiquidLaneControl). Server-authoritative through
-- SPSLaneFittingValveEvent. Standard IActivatable contract (activateText + run), like SPSBuyStationActivatable.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSLaneValveActivatable 1.0.1.8 loaded") end

SPSLaneValveActivatable = {}
SPSLaneValveActivatable.__index = SPSLaneValveActivatable
SPSLaneValveActivatable.RADIUS = 2.0   -- metres from the fitting's inNode

local function anchorNode(c)
    if c == nil then return nil end
    local n = c.inNode or c.mountNode
    if n == nil or n == 0 or not entityExists(n) then return nil end
    return n
end

function SPSLaneValveActivatable.new(coupling)
    local self = setmetatable({}, SPSLaneValveActivatable)
    self.coupling     = coupling
    self.activateText = ""
    return self
end

function SPSLaneValveActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

function SPSLaneValveActivatable:getIsActivatable()
    if SPSAccess ~= nil and not SPSAccess.localCanUse(self.coupling) then return false end   -- [SPS 1.0.1.8] farm permission
    if g_localPlayer == nil or g_slurryPipeManager == nil then return false end
    if g_slurryPipeManager.physicalPipesEnabled ~= true then return false end
    local c = self.coupling
    if c == nil or c.physPipe == nil then return false end     -- the valve matters once a pipe is on the fitting
    local n = anchorNode(c)
    if n == nil then return false end
    if c.isVehicleSide and c.object ~= nil and c.object.getRootVehicle ~= nil then
        local root = c.object:getRootVehicle()
        if root ~= nil and root.getIsActiveForInput ~= nil and root:getIsActiveForInput(true) then return false end
    end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(n)
    if MathUtil.vector3Length(px - cx, py - cy, pz - cz) > SPSLaneValveActivatable.RADIUS then return false end
    self.activateText = g_i18n:getText(c.ballValveOpen and "action_spsFittingValveClose" or "action_spsFittingValveOpen")
    return true
end

function SPSLaneValveActivatable:getDistance(posX, posY, posZ)
    local n = anchorNode(self.coupling)
    if n == nil then return math.huge end
    local cx, cy, cz = getWorldTranslation(n)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSLaneValveActivatable:activate() end
function SPSLaneValveActivatable:deactivate() end
function SPSLaneValveActivatable:update(dt) end

function SPSLaneValveActivatable:run()
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.onLaneFittingValveToggle ~= nil then
        g_slurryPipeManager:onLaneFittingValveToggle(self.coupling)
    end
end
