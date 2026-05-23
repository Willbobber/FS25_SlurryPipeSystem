-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.0

-- init.lua
-- FS25_SlurryPipeSystem

local SPS_MOD_DIRECTORY = g_currentModDirectory
local SPS_MOD_NAME      = "FS25_SlurryPipeSystem"

SlurryDebug.enabled = true  -- hardcoded during development

source(SPS_MOD_DIRECTORY .. "scripts/settings/SPSSettingsMenuExtension.lua")
source(SPS_MOD_DIRECTORY .. "scripts/util/SPSConduitHUDExtension.lua")

-- ---------------------------------------------------------------------------
-- InputHelpDisplay overrides for SPSConduitHUDExtension
--
-- addInfoExtension gates on getVisible() — the panel is collapsed by default
-- so the extension never gets inserted.  We bypass the gate for objects
-- flagged isSPSExtension = true.
--
-- draw() returns early when not visible after drawVehicleSchema.  We intercept
-- that path to render any pending SPS extensions below the schema strip.
-- ---------------------------------------------------------------------------
do
    local origAddInfoExt = InputHelpDisplay.addInfoExtension
    InputHelpDisplay.addInfoExtension = function(self, extension)
        if extension ~= nil and extension.isSPSExtension then
            table.addElement(self.infoExtensions, extension)
            return
        end
        origAddInfoExt(self, extension)
    end

    local origInputHelpDraw = InputHelpDisplay.draw
    InputHelpDisplay.draw = function(self, offsetX, offsetY)
        if not self:getVisible() then
            -- Check for SPS extensions that need rendering
            local hasSPS = false
            for _, ext in ipairs(self.infoExtensions) do
                if ext ~= nil and ext.isSPSExtension then
                    hasSPS = true
                    break
                end
            end
            if hasSPS then
                local posX, posY = self:getPosition()
                posX = posX + (offsetX or 0)
                posY = posY + (offsetY or 0)
                -- drawVehicleSchema renders the short schema strip and returns
                -- the adjusted posY (already subtracts lineOffsetY internally)
                posY = self:drawVehicleSchema(posX, posY, true)
                for k, ext in pairs(self.infoExtensions) do
                    if ext ~= nil and ext.isSPSExtension then
                        local newPosY = ext:draw(self, posX, posY)
                        if newPosY ~= posY then
                            posY = newPosY - self.lineOffsetY
                        end
                        self.infoExtensions[k] = nil
                    end
                end
                return
            end
        end
        origInputHelpDraw(self, offsetX, offsetY)
    end
end


-- ---------------------------------------------------------------------------
-- registerOverrides
-- Called from loadMap() after TypeManager:finalizeTypes() has completed.
-- ---------------------------------------------------------------------------
local function registerOverrides()
    if g_vehicleTypeManager == nil then
        print("[SPS INIT] ERROR: g_vehicleTypeManager nil in registerOverrides")
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
                "getCanToggleDischargeToGround",
                SlurryPipeSystemOverride.getCanToggleDischargeToGround
            )
            SpecializationUtil.registerOverwrittenFunction(
                typeEntry,
                "getCanToggleDischargeToObject",
                SlurryPipeSystemOverride.getCanToggleDischargeToObject
            )
            SpecializationUtil.registerOverwrittenFunction(
                typeEntry,
                "getDrawFirstFillText",
                SlurryPipeSystemOverride.getDrawFirstFillText
            )
            SpecializationUtil.registerOverwrittenFunction(
                typeEntry,
                "setIsTurnedOn",
                SlurryPipeSystemOverride.setIsTurnedOn
            )
            -- Gate built-in sprayer work areas on SPS spreader valve
            SpecializationUtil.registerOverwrittenFunction(
                typeEntry,
                "getIsWorkAreaActive",
                SlurryPipeSystemOverride.getIsWorkAreaActiveSelf
            )


            count = count + 1
        end
        -- Register getCanBeTurnedOn and getCanToggleTurnedOn on ALL types that have
        -- the turnOnVehicle spec — this prevents fold state or spreader state from
        -- auto-turning off SPS pump via the turnOffIfNotAllowed mechanism.
        -- Also register getIsDischargeNodeActive on all types with dischargeable spec
        -- so attached spreader implements can't discharge without SPS spreaderValveOpen.
        if typeEntry.specializations ~= nil then
            local hasTurnOn = false
            local hasDischargeable = false
            for _, spec in ipairs(typeEntry.specializations) do
                if spec.className == "TurnOnVehicle" then hasTurnOn = true end
                if spec.className == "Dischargeable" then hasDischargeable = true end
            end
            if hasTurnOn then
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "getCanBeTurnedOn",
                    SlurryPipeSystemOverride.getCanBeTurnedOn
                )
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "getCanToggleTurnedOn",
                    SlurryPipeSystemOverride.getCanToggleTurnedOn
                )
            end
            -- For non-tanker types with dischargeable: gate discharge on SPS spreaderValveOpen
            if hasDischargeable and baseName ~= "manureBarrel" and baseName ~= "manureTrailer" then
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "getIsDischargeNodeActive",
                    SlurryPipeSystemOverride.getIsDischargeNodeActiveAttached
                )
            end
            -- For non-tanker types with WorkArea: gate work area processing on SPS spreaderValveOpen
            local hasWorkArea = false
            for _, spec in ipairs(typeEntry.specializations) do
                if spec.className == "WorkArea" then hasWorkArea = true end
            end
            if hasWorkArea and baseName ~= "manureBarrel" and baseName ~= "manureTrailer" then
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "getIsWorkAreaActive",
                    SlurryPipeSystemOverride.getIsWorkAreaActiveAttached
                )
            end
        end
    end

    -- Register updateInfo override on all placeable types with PlaceableInfoTrigger.
    -- Appends slurry thickness row for agitator-enabled placeables.
    if g_placeableTypeManager ~= nil then
        for _, pTypeEntry in pairs(g_placeableTypeManager:getTypes()) do
            if pTypeEntry.specializations ~= nil then
                for _, spec in ipairs(pTypeEntry.specializations) do
                    if spec == PlaceableInfoTrigger then
                        -- Only register if SPSPlaceableOverride.updateInfo exists
                        if SPSPlaceableOverride ~= nil and SPSPlaceableOverride.updateInfo ~= nil then
                            SpecializationUtil.registerOverwrittenFunction(
                                pTypeEntry,
                                "updateInfo",
                                SPSPlaceableOverride.updateInfo
                            )
                        else
                            print("[SPS INIT] WARNING: SPSPlaceableOverride.updateInfo not available")
                        end
                        break
                    end
                end
            end
        end
    end

end

-- ---------------------------------------------------------------------------
-- Mod event listener
-- ---------------------------------------------------------------------------
local SPSMod = {}

function SPSMod:loadMap(filename)

    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:delete()
    end
    if g_spsPipeVisual ~= nil then
        g_spsPipeVisual:delete()
        g_spsPipeVisual = nil
    end

    g_spsPipeVisual = SPSPipeVisual.new(SPS_MOD_DIRECTORY)
    g_spsPipeVisual:load()

    -- Load SPS pipe effect material holder — provides "pipe" material via MaterialUtil.onCreateBaseMaterial
    g_spsSlurryMaterial     = nil
    g_spsSlurryMaterialNode = nil
    local matHolderPath = SPS_MOD_DIRECTORY .. "i3d/materials/unloadMeshes_materialHolder.i3d"
    local matNode = loadI3DFile(matHolderPath)
    if matNode ~= nil and matNode ~= 0 then
        -- Scene order: child 0 = unload_materialHolder, child 1 = unloadSmoke_materialHolder, child 2 = unloadPipe_materialHolder
        local pipeMatShape  = getChildAt(matNode, 2)
        if pipeMatShape ~= nil and pipeMatShape ~= 0 then
            g_spsSlurryMaterial = getMaterial(pipeMatShape, 0)
        else
            print("[SPS INIT] WARNING: unloadPipe_materialHolder shape not found at child index 2")
        end
        link(getRootNode(), matNode)
        setVisibility(matNode, false)
        g_spsSlurryMaterialNode = matNode
    else
        print("[SPS INIT] WARNING: unloadMeshes_materialHolder.i3d not found at " .. matHolderPath)
    end

    g_slurryPipeManager = SlurryPipeManager.new()
    g_slurryPipeManager:loadPipeColors(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadVehicleConfigs(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadPlaceableConfigs(SPS_MOD_DIRECTORY)

    -- Create water plane manager (but don't load planes yet - terrain not ready)
    g_waterPlaneManager = SPSWaterPlaneManager.new(SPS_MOD_DIRECTORY)

    local savePath = SlurryPipeManager.getSavePath()
    if savePath ~= nil then
        g_slurryPipeManager:loadCouplingConnections(savePath)
    end

    registerOverrides()

    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        local ps = g_currentMission.placeableSystem
        -- Bought/saved placeables
        local placeables = ps.placeables or {}
        for _, placeable in ipairs(placeables) do
            if placeable ~= nil and (placeable.spec_silo ~= nil or placeable.spec_husbandry ~= nil or placeable.spec_siloExtension ~= nil or placeable.spec_productionPoint ~= nil) then
                g_slurryPipeManager:registerPlaceable(placeable)
            end
        end
        -- Map-embedded (preplaced) placeables
        if ps.uniqueIdToReplacedPlaceableData ~= nil then
            for _, data in pairs(ps.uniqueIdToReplacedPlaceableData) do
                local placeable = data.placeable
                if placeable ~= nil and (placeable.spec_silo ~= nil or placeable.spec_husbandry ~= nil or placeable.spec_siloExtension ~= nil or placeable.spec_productionPoint ~= nil) then
                    g_slurryPipeManager:registerPlaceable(placeable)
                end
            end
        end
    end

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
    if g_spsSlurryMaterialNode ~= nil and g_spsSlurryMaterialNode ~= 0 then
        delete(g_spsSlurryMaterialNode)
        g_spsSlurryMaterialNode = nil
        g_spsSlurryMaterial = nil
    end
    if g_spsPipeVisual ~= nil then
        g_spsPipeVisual:delete()
        g_spsPipeVisual = nil
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:delete()
        g_slurryPipeManager = nil
    end

    -- Delete water pipe activatable
    if g_waterPipeActivatable ~= nil then
        g_waterPipeActivatable:delete()
        g_waterPipeActivatable = nil
    end

    -- Delete water plane manager
    if g_waterPlaneManager ~= nil then
        g_waterPlaneManager:delete()
        g_waterPlaneManager = nil
    end
end

function SPSMod:update(dt)
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:update(dt)
    end
    
    -- Deferred water plane loading (wait for terrain to be ready)
    if g_waterPlaneManager ~= nil and not g_waterPlaneManager.planesLoaded then
        if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
            print("[SPS INIT] Terrain ready, loading water planes now")
            g_waterPlaneManager:loadWaterPlanes()
            g_waterPlaneManager.planesLoaded = true
        end
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


    g_slurryPipeManager:registerVehicle(self)

    if not g_slurryPipeManager:isRegistered(self) then return end


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
-- Registers all three SPS custom actions. Removes the vanilla
-- spec_turnOnVehicle event to prevent a duplicate pump key in HUD.
-- selfPowered vehicles use addActionEvent (no tractor motor required).
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

    -- Agitator-only vehicles need no SPS action events — they use PTO directly
    if g_slurryPipeManager:isVehicleAgitatorOnly(self) then return end

    -- Prevent double-registration within the same tick (FS25 calls registerActionEvents
    -- multiple times per context switch). Allow re-registration on subsequent ticks
    -- (e.g. player re-enters the vehicle).
    local currentTime = g_currentMission and g_currentMission.time or 0
    if self._spsRegisterTime == currentTime then
        return
    end
    self._spsRegisterTime = currentTime
    self.spsActionEvents  = nil  -- clear so re-entry always gets fresh events

    -- Remove the vanilla spec_turnOnVehicle event so pump key doesn't appear twice.
    local specTOV = self.spec_turnOnVehicle
    if specTOV.actionEvents ~= nil and specTOV.toggleTurnOnInputBinding ~= nil then
        local vanillaEvent = specTOV.actionEvents[specTOV.toggleTurnOnInputBinding]
        if vanillaEvent ~= nil then
            g_inputBinding:removeActionEvent(vanillaEvent.actionEventId)
            specTOV.actionEvents[specTOV.toggleTurnOnInputBinding] = nil
        end
    end

    local isSelfPowered = g_slurryPipeManager:isVehicleSelfPowered(self)
    local spsEvents   = {}
    local pumpEventId = nil
    local flowEventId = nil

    local hasSpreader = g_slurryPipeManager:vehicleHasSpreader(self)

    -- SPS_TOGGLE_PUMP
    -- Spreader vehicles: use state.pumpRunning exclusively — never call setIsTurnedOn.
    --   setIsTurnedOn is reserved for when the spreader valve opens/closes.
    -- Non-spreader vehicles: call setIsTurnedOn which drives PTO sounds/animations.
    local pumpCallback
    if hasSpreader then
        pumpCallback = function(vehicle, actionName, inputValue, callbackState, isAnalog)
            if g_slurryPipeManager == nil then return end
            -- Check motor running and PTO (but NOT spreader valve or TurnOnVehicle state)
            local root = vehicle:getRootVehicle()
            if root ~= nil and root.getIsMotorStarted ~= nil and not root:getIsMotorStarted() then
                local warning = vehicle:getTurnedOnNotAllowedWarning()
                if warning ~= nil and vehicle.isClient then
                    g_currentMission:showBlinkingWarning(warning, 2000)
                end
                print("[SPS PUMP] spreader vehicle pump blocked — motor not started")
                return
            end
            if not SlurryPipeSystemOverride.isPTOConnected(vehicle) then
                print("[SPS PUMP] spreader vehicle pump blocked — PTO not connected")
                return
            end
            local state = g_slurryPipeManager:getVehicleState(vehicle)
            if state == nil then return end
            local newPump = not state.pumpRunning
            print("[SPS PUMP] spreader vehicle pump -> " .. tostring(newPump) .. " spreaderValveOpen=" .. tostring(state.spreaderValveOpen))
            if g_server ~= nil then
                state.pumpRunning = newPump
                SPSSelfPumpStateEvent.sendEvent(vehicle, newPump)
                -- Call setIsTurnedOn to drive PTO sounds and animations.
                -- Discharge still requires spreaderValveOpen via getIsDischargeNodeActive.
                if newPump then
                    vehicle:setIsTurnedOn(true)
                    print("[SPS PUMP] pump on — setIsTurnedOn(true) for PTO sounds")
                else
                    -- Turning off: close spreader valve too if open
                    if state.spreaderValveOpen then
                        state.spreaderValveOpen = false
                        SPSSpreaderValveEvent.sendEvent(vehicle, false)
                        print("[SPS PUMP] pump off — spreader valve closed")
                    end
                    vehicle:setIsTurnedOn(false)
                    print("[SPS PUMP] pump off — setIsTurnedOn(false)")
                end
                g_slurryPipeManager:updateActionEventTexts(vehicle)
            else
                SPSSelfPumpStateEvent.sendEvent(vehicle, newPump)
            end
        end
    else
        pumpCallback = function(vehicle, actionName, inputValue, callbackState, isAnalog)
            if not vehicle:getIsTurnedOn() and not vehicle:getCanBeTurnedOn() then
                local warning = vehicle:getTurnedOnNotAllowedWarning()
                if warning ~= nil and vehicle.isClient then
                    g_currentMission:showBlinkingWarning(warning, 2000)
                end
                print("[SPS PUMP] non-spreader pump blocked — getCanBeTurnedOn false")
                return
            end
            print("[SPS PUMP] non-spreader setIsTurnedOn -> " .. tostring(not vehicle:getIsTurnedOn()))
            vehicle:setIsTurnedOn(not vehicle:getIsTurnedOn())
            if g_slurryPipeManager ~= nil then
                g_slurryPipeManager:updateActionEventTexts(vehicle)
            end
        end
    end
    -- All SPS actions use addActionEvent (never addPoweredActionEvent) so fold state
    -- and implement power state never block them. Motor/PTO checks are done manually
    -- in the callbacks where needed. All registered at GS_PRIO_VERY_HIGH.
    local _, pid = self:addActionEvent(
        spsEvents, InputAction.SPS_TOGGLE_PUMP, self,
        pumpCallback, false, true, false, true, nil)
    if pid ~= nil then
        local state = g_slurryPipeManager:getVehicleState(self)
        local pumpOn = hasSpreader and (state and state.pumpRunning == true) or self:getIsTurnedOn()
        g_inputBinding:setActionEventText(pid, pumpOn
            and g_i18n:getText("action_slurryPumpOff")
            or  g_i18n:getText("action_slurryPumpOn"))
        g_inputBinding:setActionEventTextPriority(pid, GS_PRIO_VERY_HIGH)
        pumpEventId = pid
    end

    -- SPS_TOGGLE_FLOW: for vehicles with fill arms or conduit pumps
    if g_slurryPipeManager:vehicleHasFillArms(self) or g_slurryPipeManager:isVehicleConduit(self) then
        local _, id = self:addActionEvent(
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
            g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
            flowEventId = id
        end
    end

    -- SPS_TOGGLE_DIRECTION
    local _, dirEventId = self:addActionEvent(
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
        local isConduit = g_slurryPipeManager:isVehicleConduit(self)
        local dirTxt
        if isConduit then
            dirTxt = (state and state.direction == SPS_DIRECTION_FILL)
                and g_i18n:getText("action_spsConduitDirBtoA")
                or  g_i18n:getText("action_spsConduitDirAtoB")
        else
            dirTxt = (state and state.direction == SPS_DIRECTION_FILL)
                and g_i18n:getText("action_slurryDirectionDischarge")
                or  g_i18n:getText("action_slurryDirectionFill")
        end
        g_inputBinding:setActionEventText(dirEventId, dirTxt)
        g_inputBinding:setActionEventTextPriority(dirEventId, GS_PRIO_VERY_HIGH)
    end

    -- SPS_TOGGLE_SPREADER: only for vehicles with a spreader (spec_dischargeable)
    local spreaderEventId = nil
    if g_slurryPipeManager:vehicleHasSpreader(self) then
        local _, sid = self:addActionEvent(
            spsEvents,
            InputAction.SPS_TOGGLE_SPREADER,
            self,
            function(vehicle, actionName, inputValue, callbackState, isAnalog)
                if g_slurryPipeManager ~= nil then
                    g_slurryPipeManager:onActionToggleSpreader(vehicle)
                end
            end,
            false, true, false, true, nil
        )
        if sid ~= nil then
            local state = g_slurryPipeManager:getVehicleState(self)
            local spreaderTxt = (state and state.spreaderValveOpen)
                and g_i18n:getText("action_spsSpreaderClose")
                or  g_i18n:getText("action_spsSpreaderOpen")
            g_inputBinding:setActionEventText(sid, spreaderTxt)
            g_inputBinding:setActionEventTextPriority(sid, GS_PRIO_VERY_HIGH)
            spreaderEventId = sid
        end
    end

    self.spsActionEvents = { pumpEventId = pumpEventId, flowEventId = flowEventId, dirEventId = dirEventId, spreaderEventId = spreaderEventId }
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
    if g_slurryPipeManager ~= nil and (self.spec_silo ~= nil or self.spec_husbandry ~= nil or self.spec_siloExtension ~= nil or self.spec_productionPoint ~= nil) then
        -- Avoid double-registration for placeables already registered in loadMap
        if g_slurryPipeManager:getPlaceableEntry(self) == nil then
            g_slurryPipeManager:registerPlaceable(self)
        end
    end
end

local origPlaceableDelete = Placeable.delete
function Placeable:delete(immediate)
    if g_slurryPipeManager ~= nil and (self.spec_silo ~= nil or self.spec_husbandry ~= nil or self.spec_siloExtension ~= nil or self.spec_productionPoint ~= nil) then
        g_slurryPipeManager:unregisterPlaceable(self)
    end
    if origPlaceableDelete ~= nil then
        origPlaceableDelete(self, immediate)
    end
end