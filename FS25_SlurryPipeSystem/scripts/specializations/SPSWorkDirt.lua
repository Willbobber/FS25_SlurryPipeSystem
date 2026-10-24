-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSWorkDirt.lua
-- [SPS 1.0.1.8] Dirt + wear while a STATIONARY machine works (William 2026-10-23: the tower mixer and the PTO slurry
-- pump "are used more static than moving"). Both types inherit washable + wearable from implement, but vanilla
-- Washable:getDirtMultiplier / Wearable:getWearMultiplier return 0 below 1 km/h and turnOnVehicle adds nothing, so a
-- mixer or pump running in one spot never got dirty or worn. Same pattern as the game's stationary machines
-- (WoodCrusher:getDirtMultiplier / getWearMultiplier): while turned on, ADD the washable / wearable workMultiplier
-- (vehicle XML <washable workMultiplier/> default 4, <wearable workMultiplier/> default 20). Moving keeps the
-- vanilla rule. Damage, repair, rain and the pressure washer are untouched vanilla. List AFTER turnOnVehicle.

SPSWorkDirt = {}

function SPSWorkDirt.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Washable, specializations)
        and SpecializationUtil.hasSpecialization(Wearable, specializations)
        and SpecializationUtil.hasSpecialization(TurnOnVehicle, specializations)
end

function SPSWorkDirt.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getDirtMultiplier", SPSWorkDirt.getDirtMultiplier)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getWearMultiplier", SPSWorkDirt.getWearMultiplier)
end

function SPSWorkDirt:getDirtMultiplier(superFunc)
    local m = superFunc(self)
    if self:getIsTurnedOn() then
        m = m + self:getWorkDirtMultiplier()
    end
    return m
end

function SPSWorkDirt:getWearMultiplier(superFunc, nodeData)
    local m = superFunc(self, nodeData)
    if self:getIsTurnedOn() then
        m = m + self:getWorkWearMultiplier()
    end
    return m
end
