-- FS25_SlurryPipeSystem init.lua
-- All SPS behaviour is driven from here and the manager.
-- No specialization files. We hook directly into vanilla vehicle types.

local SPS_MOD_DIRECTORY = g_currentModDirectory
local SPS_MOD_NAME      = "FS25_SlurryPipeSystem"

SlurryDebug.enabled = true  -- hardcoded during development

print("[SPS] init.lua loaded")

-- ---------------------------------------------------------------------------
-- registerOverrides
-- Called from loadMap() after TypeManager:finalizeTypes() has completed.
-- ---------------------------------------------------------------------------
local function registerOverrides()
    if g_vehicleTypeManager == nil then
        print("[SPS] ERROR: g_vehicleTypeManager nil in registerOverrides")
        return
    end

    local types = g_vehicleTypeManager:getTypes()
    local count = 0

    for typeName, typeEntry in pairs(types) do
        local baseName = typeName:match("%.?([^%.]+)$") or typeName
        if baseName == "manureBarrel" or baseName == "manureTrailer" then
            SpecializationUtil.registerOverwrittenFunction(
                typeEntry,
                "getAllowLoadTriggerActivation",
                SlurryPipeSystemOverride.getAllowLoadTriggerActivation
            )
            SpecializationUtil.registerOverwrittenFunction(
                typeEntry,
                "getIsDischargeNodeActive",
                SlurryPipeSystemOverride.getIsDischargeNodeActive
            )
            SpecializationUtil.registerOverwrittenFunction(
                typeEntry,
                "getCanBeTurnedOn",
                SlurryPipeSystemOverride.getCanBeTurnedOn
            )
            SpecializationUtil.registerOverwrittenFunction(
                typeEntry,
                "getDrawFirstFillText",
                SlurryPipeSystemOverride.getDrawFirstFillText
            )
            count = count + 1
            print("[SPS] Registered overrides on type: " .. tostring(typeName))
        end
    end

    print("[SPS] registerOverrides complete, " .. count .. " types patched")
end

-- ---------------------------------------------------------------------------
-- Mod event listener
-- ---------------------------------------------------------------------------
local SPSMod = {}

function SPSMod:loadMap(filename)
    print("[SPS] SPSMod:loadMap fired")

    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:delete()
    end
    if g_spsPipeVisual ~= nil then
        g_spsPipeVisual:delete()
        g_spsPipeVisual = nil
    end

    g_spsPipeVisual = SPSPipeVisual.new(SPS_MOD_DIRECTORY)
    g_spsPipeVisual:load()

    g_slurryPipeManager = SlurryPipeManager.new()
    g_slurryPipeManager:loadVehicleConfigs(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadPlaceableConfigs(SPS_MOD_DIRECTORY)

    -- Load saved coupling connections before vehicles/placeables register.
    -- tryResolvePendingConnections is called at end of each register call.
    local savePath = SlurryPipeManager.getSavePath()
    if savePath ~= nil then
        g_slurryPipeManager:loadCouplingConnections(savePath)
    end

    registerOverrides()

    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        local ps = g_currentMission.placeableSystem
        local placeables = ps.placeables or ps.objects or {}
        local count = 0
        for _, placeable in ipairs(placeables) do
            if placeable ~= nil and (placeable.spec_silo ~= nil or placeable.spec_husbandry ~= nil) then
                g_slurryPipeManager:registerPlaceable(placeable)
                count = count + 1
            end
        end
        print("[SPS] Scanned " .. count .. " existing silo placeables")
    end

    print("[SPS] Manager ready")
end

function SPSMod:saveMap(filename)
end

local origSaveToXMLFile = FSCareerMissionInfo.saveToXMLFile
function FSCareerMissionInfo:saveToXMLFile()
    if origSaveToXMLFile ~= nil then
        origSaveToXMLFile(self)
    end
    if g_slurryPipeManager == nil then return end
    if self.savegameDirectory == nil then return end
    local savePath = self.savegameDirectory .. "/FS25_SlurryPipeSystem.xml"
    g_slurryPipeManager:saveCouplingConnections(savePath)
end


function SPSMod:deleteMap()
    if g_spsPipeVisual ~= nil then
        g_spsPipeVisual:delete()
        g_spsPipeVisual = nil
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:delete()
        g_slurryPipeManager = nil
    end
    print("[SPS] Manager destroyed")
end

function SPSMod:update(dt)
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:update(dt)
    end
end

addModEventListener(SPSMod)

-- ---------------------------------------------------------------------------
-- Vehicle:onFinishedLoading hook
-- ---------------------------------------------------------------------------
local origOnFinishedLoading = Vehicle.onFinishedLoading
function Vehicle:onFinishedLoading()
    if origOnFinishedLoading ~= nil then
        origOnFinishedLoading(self)
    end

    if g_slurryPipeManager == nil then return end

    local config = g_slurryPipeManager:findVehicleConfigForVehicle(self)
    if config == nil then return end

    print("[SPS] onFinishedLoading: " .. tostring(self.configFileName))

    g_slurryPipeManager:registerVehicle(self)

    if not g_slurryPipeManager:isRegistered(self) then return end

    print("[SPS] Vehicle registered: " .. tostring(self.configFileName))

    -- ---------------------------------------------------------------------------
    -- Samson PG II 28 Genesis: patch turretSAP2Arm02 rotationBasedLimits.
    -- ---------------------------------------------------------------------------
    if self.configFileName ~= nil and self.configFileName:find("pgII28Genesis", 1, true) then
        if self.spec_cylindered ~= nil and self.spec_cylindered.movingTools ~= nil then
            for _, tool in pairs(self.spec_cylindered.movingTools) do
                if tool.node ~= nil and getName(tool.node) == "turretSAP2Arm01" then
                    if tool.dependentMovingTools ~= nil then
                        for _, depTool in pairs(tool.dependentMovingTools) do
                            if depTool.movingTool ~= nil and depTool.movingTool.node ~= nil
                            and getName(depTool.movingTool.node) == "turretSAP2Arm02"
                            and depTool.rotationBasedLimits ~= nil then
                                local newCurve = AnimCurve.new(Cylindered.limitInterpolator)
                                newCurve:addKeyframe({ time = 0.1176, rotMin = math.rad(-150), rotMax = math.rad(0)    })
                                newCurve:addKeyframe({ time = 1.0,    rotMin = math.rad(-150), rotMax = math.rad(-70) })
                                depTool.rotationBasedLimits = newCurve
                                print("[SPS] Patched turretSAP2Arm02 rotationBasedLimits")
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Vehicle:registerActionEvents hook
-- Registers all three SPS actions using our own custom input actions so they
-- appear in the controls menu and are rebindable. The vanilla spec_turnOnVehicle
-- action event is removed after origRegisterActionEvents to prevent a duplicate
-- HUD entry for the pump key.
-- ---------------------------------------------------------------------------
local origRegisterActionEvents = Vehicle.registerActionEvents
function Vehicle:registerActionEvents(excludedVehicle)
    if origRegisterActionEvents ~= nil then
        origRegisterActionEvents(self, excludedVehicle)
    end

    if g_slurryPipeManager == nil then return end
    if not g_slurryPipeManager:isRegistered(self) then return end
    if self.spec_turnOnVehicle == nil then return end
    if not self.isClient then return end
    if not self:getIsActiveForInput(true) then return end

    -- Remove the vanilla spec_turnOnVehicle action event so the pump key does not
    -- appear twice in the HUD. origRegisterActionEvents already registered it on
    -- spec.toggleTurnOnInputBinding (defaults to IMPLEMENT_EXTRA). We replace it
    -- with SPS_TOGGLE_PUMP below.
    local specTOV = self.spec_turnOnVehicle
    if specTOV.actionEvents ~= nil and specTOV.toggleTurnOnInputBinding ~= nil then
        local vanillaEvent = specTOV.actionEvents[specTOV.toggleTurnOnInputBinding]
        if vanillaEvent ~= nil then
            g_inputBinding:removeActionEvent(vanillaEvent.actionEventId)
            specTOV.actionEvents[specTOV.toggleTurnOnInputBinding] = nil
        end
    end

    print("[SPS] registerActionEvents: adding SPS actions to " .. tostring(self.configFileName))

    local spsEvents = {}
    local pumpEventId = nil
    local flowEventId = nil

    -- SPS_TOGGLE_PUMP: replaces the vanilla spec_turnOnVehicle binding.
    -- Calls setIsTurnedOn directly, same as TurnOnVehicle.actionEventTurnOn.
    local _, pid = self:addPoweredActionEvent(
        spsEvents,
        InputAction.SPS_TOGGLE_PUMP,
        self,
        function(vehicle, actionName, inputValue, callbackState, isAnalog)
            vehicle:setIsTurnedOn(not vehicle:getIsTurnedOn())
        end,
        false, true, false, true, nil
    )
    if pid ~= nil then
        local pumpTxt = self:getIsTurnedOn()
            and g_i18n:getText("action_slurryPumpOff")
            or  g_i18n:getText("action_slurryPumpOn")
        g_inputBinding:setActionEventText(pid, pumpTxt)
        g_inputBinding:setActionEventTextPriority(pid, GS_PRIO_NORMAL)
        pumpEventId = pid
    end

    -- SPS_TOGGLE_FLOW: only shown for vehicles with fill arms.
    -- Pipe coupling valve is operated on foot, not from the cab.
    if g_slurryPipeManager:vehicleHasFillArms(self) then
        local _, id = self:addPoweredActionEvent(
            spsEvents,
            InputAction.SPS_TOGGLE_FLOW,
            self,
            function(vehicle, actionName, inputValue, callbackState, isAnalog)
                if g_slurryPipeManager ~= nil then
                    g_slurryPipeManager:onActionToggleFlow(vehicle)
                end
            end,
            false, true, false, true, nil
        )
        if id ~= nil then
            local state   = g_slurryPipeManager:getVehicleState(self)
            local flowTxt = (state and state.valveOpen)
                and g_i18n:getText("action_slurryFlowClose")
                or  g_i18n:getText("action_slurryFlowOpen")
            g_inputBinding:setActionEventText(id, flowTxt)
            g_inputBinding:setActionEventTextPriority(id, GS_PRIO_NORMAL)
            flowEventId = id
        end
    end

    -- SPS_TOGGLE_DIRECTION
    local _, dirEventId = self:addPoweredActionEvent(
        spsEvents,
        InputAction.SPS_TOGGLE_DIRECTION,
        self,
        function(vehicle, actionName, inputValue, callbackState, isAnalog)
            if g_slurryPipeManager ~= nil then
                g_slurryPipeManager:onActionToggleDirection(vehicle)
            end
        end,
        false, true, false, true, nil
    )
    if dirEventId ~= nil then
        local state = g_slurryPipeManager:getVehicleState(self)
        local dirTxt = (state and state.direction == SPS_DIRECTION_FILL)
            and g_i18n:getText("action_slurryDirectionDischarge")
            or  g_i18n:getText("action_slurryDirectionFill")
        g_inputBinding:setActionEventText(dirEventId, dirTxt)
        g_inputBinding:setActionEventTextPriority(dirEventId, GS_PRIO_NORMAL)
    end

    self.spsActionEvents = { pumpEventId = pumpEventId, flowEventId = flowEventId, dirEventId = dirEventId }
end

-- ---------------------------------------------------------------------------
-- Vehicle:delete hook
-- ---------------------------------------------------------------------------
local origVehicleDelete = Vehicle.delete
function Vehicle:delete(immediate)
    if g_slurryPipeManager ~= nil then
        if g_slurryPipeManager:isRegistered(self) then
            g_slurryPipeManager:unregisterVehicle(self)
        end
    end
    if origVehicleDelete ~= nil then
        origVehicleDelete(self, immediate)
    end
end

-- ---------------------------------------------------------------------------
-- Placeable hooks
-- ---------------------------------------------------------------------------
local origPlaceableFinalize = Placeable.finalizePlacement
function Placeable:finalizePlacement()
    if origPlaceableFinalize ~= nil then
        origPlaceableFinalize(self)
    end
    if g_slurryPipeManager ~= nil and (self.spec_silo ~= nil or self.spec_husbandry ~= nil) then
        print("[SPS] finalizePlacement: registering silo " .. tostring(self.configFileName))
        g_slurryPipeManager:registerPlaceable(self)
    end
end

local origPlaceableDelete = Placeable.delete
function Placeable:delete(immediate)
    if g_slurryPipeManager ~= nil and (self.spec_silo ~= nil or self.spec_husbandry ~= nil) then
        g_slurryPipeManager:unregisterPlaceable(self)
    end
    if origPlaceableDelete ~= nil then
        origPlaceableDelete(self, immediate)
    end
end
