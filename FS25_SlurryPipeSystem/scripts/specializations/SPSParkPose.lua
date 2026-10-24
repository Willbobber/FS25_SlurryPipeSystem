-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSParkPose.lua  -  [SPS 1.0.1.8] keep a saved machine's pose across save / reload when it uses an attachable
-- "support" animation as a bought / parked pose (tower mixer: bought pose != folded transport pose).
--
-- Vanilla Attachable plays the support animation (decoded Attachable.lua):
--   * at load, to its END (detached pose) - onPostLoad, or onPreInitComponentPlacement with delayedOnLoad (394-428)
--   * on attach, BACKWARDS to its start - instantly when the attach comes from the savegame (1224-1265)
-- The tower mixer's parkPose drives the same ladders / rotator / extension as its fold animation, so a machine saved
-- UNFOLDED and attached came back in the folded pose: the support animation overwrote what Foldable / Cylindered had
-- restored (William 2026-10-22: "all 3 back in the folded state after reload").
--
-- This spec: while the vehicle is loading (onLoad .. first onUpdate) getIsSupportAnimationAllowed returns false, so
-- vanilla touches nothing; Foldable and Cylindered restore the saved fold time and tool positions as usual. On the
-- first update the pose is decided ONCE from our own saved flag: parked (= was detached when saved, or a new / shop
-- vehicle) -> support animation set to its end instantly (bought pose); attached -> left alone. After that vanilla
-- runs the support animation normally on every live attach / detach.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSParkPose 1.0.1.8 loaded") end

SPSParkPose = {}
SPSParkPose.SPEC_NAME = string.format("spec_%s.spsParkPose", g_currentModName)
SPSParkPose.MOD_NAME  = g_currentModName   -- file-scope copy: initSpecialization runs after sourcing (see SPSHoseItem)

function SPSParkPose.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Attachable, specializations)
       and SpecializationUtil.hasSpecialization(AnimatedVehicle, specializations)
end

function SPSParkPose.initSpecialization()
    local sg = Vehicle.xmlSchemaSavegame
    if sg ~= nil then
        sg:register(XMLValueType.BOOL, string.format("vehicles.vehicle(?).%s.spsParkPose#parked", SPSParkPose.MOD_NAME),
            "Vehicle was detached (in its parked / bought pose) when saved")
    end
end

function SPSParkPose.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad",         SPSParkPose)
    SpecializationUtil.registerEventListener(vehicleType, "onLoadFinished", SPSParkPose)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate",       SPSParkPose)
end

function SPSParkPose.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getIsSupportAnimationAllowed", SPSParkPose.getIsSupportAnimationAllowed)
end

function SPSParkPose:onLoad(savegame)
    local spec = {}
    self[SPSParkPose.SPEC_NAME] = spec
    spec.loading = true
    spec.parked  = true    -- new and shop vehicles start in the bought pose
    spec.animName = self.xmlFile:getValue("vehicle.attachable.support(0)#animationName")
    if savegame ~= nil and savegame.xmlFile ~= nil and not savegame.resetVehicles then
        local v = savegame.xmlFile:getValue(savegame.key .. "." .. SPSParkPose.MOD_NAME .. ".spsParkPose#parked")
        if v ~= nil then spec.parked = v end
    end
end

function SPSParkPose:onLoadFinished(savegame)
    self:raiseActive()   -- make sure the first onUpdate comes even for a parked, inactive vehicle
end

function SPSParkPose:getIsSupportAnimationAllowed(superFunc, supportAnimation)
    local spec = self[SPSParkPose.SPEC_NAME]
    if spec ~= nil and spec.loading then return false end
    return superFunc(self, supportAnimation)
end

function SPSParkPose:onUpdate(dt)
    local spec = self[SPSParkPose.SPEC_NAME]
    if spec == nil or not spec.loading then return end
    spec.loading = false
    local attached = self.getAttacherVehicle ~= nil and self:getAttacherVehicle() ~= nil
    if spec.parked and not attached and spec.animName ~= nil and self.playAnimation ~= nil then
        self:playAnimation(spec.animName, 1, nil, true)
        AnimatedVehicle.updateAnimationByName(self, spec.animName, 9999999, true)
    end
end

function SPSParkPose:saveToXMLFile(xmlFile, key, usedModNames)
    local attached = self.getAttacherVehicle ~= nil and self:getAttacherVehicle() ~= nil
    xmlFile:setValue(key .. "#parked", not attached)
end
