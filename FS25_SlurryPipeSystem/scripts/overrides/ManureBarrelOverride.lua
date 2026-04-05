-- ManureBarrelOverride.lua
-- FS25_SlurryPipeSystem
--
-- Overrides applied to manureBarrel and manureTrailer vehicle types.
-- All functions confirmed from FS25 source before use.
--
-- WHAT WE BLOCK AND WHY (source confirmed):
--
-- getAllowLoadTriggerActivation  (ManureBarrel/FillUnit chain)
--   Called by LoadingStation when a vehicle enters its trigger volume.
--   Returning false prevents the drive-in fill from activating.
--   Source: LoadingStation.lua -> vehicle:getAllowLoadTriggerActivation()
--
-- getDrawFirstFillText  (FillTriggerVehicle.lua)
--   Returns true when fillLevel=0, which shows the "Press R to fill" HUD prompt.
--   Source: FillTriggerVehicle.lua line ~55 getDrawFirstFillText
--   Returning false removes the prompt entirely for SPS vehicles.
--
-- getIsDischargeNodeActive  (Dischargeable.lua)
--   Controls whether the vanilla discharge node is active.
--   We block it unless pump+valve+DISCHARGE are all set via SPS.
--   Source: Dischargeable.lua -> getIsDischargeNodeActive
--
-- getCanBeTurnedOn  (Sprayer.lua)
--   Sprayer blocks PTO when tank is empty. SPS pumps must run on empty
--   tanks to suck slurry in. We always return true for SPS vehicles.
--   Source: Sprayer.lua -> getCanBeTurnedOn checks fill level

SlurryPipeSystemOverride = {}

function SlurryPipeSystemOverride.getAllowLoadTriggerActivation(self, superFunc, rootVehicle)
    if g_slurryPipeManager ~= nil and g_slurryPipeManager:isRegistered(self) then
        return false
    end
    return superFunc(self, rootVehicle)
end

function SlurryPipeSystemOverride.getDrawFirstFillText(self, superFunc)
    if g_slurryPipeManager ~= nil and g_slurryPipeManager:isRegistered(self) then
        return false
    end
    return superFunc(self)
end

function SlurryPipeSystemOverride.getIsDischargeNodeActive(self, superFunc, dischargeNode)
    if g_slurryPipeManager == nil or not g_slurryPipeManager:isRegistered(self) then
        return superFunc(self, dischargeNode)
    end
    local state = g_slurryPipeManager:getVehicleState(self)
    if state == nil then return false end
    return state.pumpRunning
       and state.valveOpen
       and state.direction == SPS_DIRECTION_DISCHARGE
end

function SlurryPipeSystemOverride.getCanBeTurnedOn(self, superFunc)
    if g_slurryPipeManager ~= nil and g_slurryPipeManager:isRegistered(self) then
        local root = self:getRootVehicle()
        if root ~= nil and root.getIsMotorStarted ~= nil then
            return root:getIsMotorStarted()
        end
        return true
    end
    return superFunc(self)
end