-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSPumpMixerControl.lua  -  [SPS 1.0.1.8] valve button for a pump mixer (tower mixer).
--
-- SPS gives its keys only to tanker-like vehicles, registered on the ROOT vehicle (init.lua root pass), and skips
-- agitatorOnly vehicles - so a pump mixer had no valve key at all (William 2026-10-22: "I have no open hydr valve
-- command"; the lever-08 valve in its own control group was rejected). This registers the mixer's own valve action
-- (SPS_PUMPMIXER_VALVE, Left Alt + B - the tanker valve key X is the vanilla fold key on the mixer) through the
-- vanilla onRegisterActionEvents path, so it shows while standing on the mixer and from the tractor with the mixer
-- selected. The press goes to SlurryPipeManager:onActionToggleFlow:
-- same checks (hydraulic hoses connected, motor running), same state (state.valveOpen), same MP event
-- (SlurryFlowStateEvent). The pump mixer flow (SPSM_Flow) pumps while that valve is open and the blades run.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSPumpMixerControl 1.0.1.8 loaded") end

SPSPumpMixerControl = {}
SPSPumpMixerControl.SPEC_NAME = string.format("spec_%s.spsPumpMixerControl", g_currentModName)

function SPSPumpMixerControl.prerequisitesPresent(specializations)
    return true
end

function SPSPumpMixerControl.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad",                 SPSPumpMixerControl)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", SPSPumpMixerControl)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate",               SPSPumpMixerControl)
end

function SPSPumpMixerControl:onLoad(savegame)
    local spec = {}
    self[SPSPumpMixerControl.SPEC_NAME] = spec
    spec.actionEvents = {}
    spec.eventId = nil
    spec.shownOpen = nil
end

local function isPumpMixer(vehicle)
    return g_slurryPipeManager ~= nil and g_slurryPipeManager.isVehiclePumpMixer ~= nil
       and g_slurryPipeManager:isVehiclePumpMixer(vehicle)
end

local function updateText(vehicle, spec)
    if spec.eventId == nil or g_slurryPipeManager == nil then return end
    local state = g_slurryPipeManager:getVehicleState(vehicle)
    local open = state ~= nil and state.valveOpen == true
    if spec.shownOpen ~= open then
        spec.shownOpen = open
        g_inputBinding:setActionEventText(spec.eventId,
            g_i18n:getText(open and "action_spsConduitFlowClose" or "action_spsConduitFlowOpen"))
    end
end

function SPSPumpMixerControl:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if not self.isClient then return end
    local spec = self[SPSPumpMixerControl.SPEC_NAME]
    if spec == nil then return end
    self:clearActionEventsTable(spec.actionEvents)
    spec.eventId, spec.shownOpen = nil, nil
    -- registration can run before SPS has registered the vehicle; then the next action-event refresh adds it
    if isActiveForInputIgnoreSelection and InputAction.SPS_PUMPMIXER_VALVE ~= nil and isPumpMixer(self) then
        local _, id = self:addActionEvent(spec.actionEvents, InputAction.SPS_PUMPMIXER_VALVE, self,
            SPSPumpMixerControl.actionEventToggleValve, false, true, false, true, nil)
        if id ~= nil and id ~= "" then
            spec.eventId = id
            g_inputBinding:setActionEventTextPriority(id, GS_PRIO_HIGH)
            updateText(self, spec)
        end
    end
end

function SPSPumpMixerControl.actionEventToggleValve(self, actionName, inputValue, callbackState, isAnalog)
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:onActionToggleFlow(self)
    end
end

function SPSPumpMixerControl:onUpdate(dt)
    local spec = self[SPSPumpMixerControl.SPEC_NAME]
    if spec ~= nil and spec.eventId ~= nil then updateText(self, spec) end
end
