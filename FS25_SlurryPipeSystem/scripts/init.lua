-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.0

-- init.lua
-- FS25_SlurryPipeSystem

local SPS_MOD_DIRECTORY = g_currentModDirectory
local SPS_MOD_NAME      = "FS25_SlurryPipeSystem"

SlurryDebug.enabled = false  -- hardcoded during development

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
-- [SPS] Universal LoadTrigger block.
--
-- The per-vehicle-type getAllowLoadTriggerActivation override only blocks R/I
-- when vanilla actually CALLS it. LoadTrigger:getAllowsActivation short-circuits
-- with `return true` when self.requiresActiveVehicle is false — and
-- requiresActiveVehicle is derived from the global Platform.gameplay.automaticFilling
-- setting (LoadTrigger.load), NOT from placeable XML. So with automatic filling
-- ON, the vanilla path never consults our override and R/auto-fill work on any
-- store/IBC/tank regardless of type. This is why some players see the fill and
-- others (auto-fill OFF) do not.
--
-- Hooking the LoadTrigger CLASS method once catches every load path (manual R via
-- getIsFillableObjectAvailable, and automaticFilling via onFillTypeSelection) for
-- every fillable, independent of type or settings. When the fillable (or its root
-- vehicle) is SPS-registered — slurry OR sprayer — activation is denied so SPS's
-- own pipe/arm flow is the only way to load. AI/Courseplay/AutoDrive fall through
-- to vanilla via the same isAIControlled gate used by the type-level overrides.
-- ---------------------------------------------------------------------------
do
    local DEBUG = false  -- set true for [SPS LT] per-call trace
    local function spsBlocksFillable(fillableObject)
        if fillableObject == nil then return false end
        if g_slurryPipeManager == nil then return false end
        -- AI in control: do not interfere (mirror of SlurryPipeSystemOverride.getAllowLoadTriggerActivation).
        if SlurryPipeSystemOverride ~= nil
        and SlurryPipeSystemOverride.isAIControlled ~= nil
        and SlurryPipeSystemOverride.isAIControlled(fillableObject) then
            return false
        end
        -- Direct match on the fillable itself.
        if g_slurryPipeManager:isRegistered(fillableObject) then return true end
        if g_slurryPipeManager:isSprayerVehicleRegistered(fillableObject) then return true end
        if g_slurryPipeManager:findSprayerVehicleConfigForVehicle(fillableObject) ~= nil then return true end
        -- Match on the root vehicle (fillableObject may be a trailed implement whose
        -- fill collider entered the trigger; SPS registers the root tanker/sprayer).
        if fillableObject.getRootVehicle ~= nil then
            local root = fillableObject:getRootVehicle()
            if root ~= nil and root ~= fillableObject then
                if g_slurryPipeManager:isRegistered(root) then return true end
                if g_slurryPipeManager:isSprayerVehicleRegistered(root) then return true end
                if g_slurryPipeManager:findSprayerVehicleConfigForVehicle(root) ~= nil then return true end
            end
        end
        return false
    end

    if LoadTrigger ~= nil and LoadTrigger.getAllowsActivation ~= nil then
        local origGetAllowsActivation = LoadTrigger.getAllowsActivation
        LoadTrigger.getAllowsActivation = function(self, fillableObject)
            local blocked = spsBlocksFillable(fillableObject)
            if DEBUG then
                print(string.format("[SPS LT] getAllowsActivation fillable=%s blocked=%s",
                    tostring(fillableObject and fillableObject.configFileName), tostring(blocked)))
            end
            if blocked then
                return false
            end
            return origGetAllowsActivation(self, fillableObject)
        end

        -- Belt-and-braces: even if some path reaches startLoading directly (e.g. an
        -- automaticFilling toggle that bypassed the activation gate), refuse to begin
        -- a load for an SPS fillable.
        if LoadTrigger.startLoading ~= nil then
            local origStartLoading = LoadTrigger.startLoading
            LoadTrigger.startLoading = function(self, fillType, fillableObject, fillUnitIndex)
                if spsBlocksFillable(fillableObject) then
                    if DEBUG then
                        print(string.format("[SPS LT] startLoading BLOCKED fillable=%s",
                            tostring(fillableObject and fillableObject.configFileName)))
                    end
                    return
                end
                return origStartLoading(self, fillType, fillableObject, fillUnitIndex)
            end
        end

        -- Positive confirmation the hook installed (always printed, once, at source time).
        print("[SPS INIT] LoadTrigger.getAllowsActivation hook INSTALLED")
    else
        print("[SPS INIT] WARNING: LoadTrigger.getAllowsActivation not available — universal R/I block not installed")
    end

    -- -----------------------------------------------------------------------
    -- [SPS] Vehicle-side FillTrigger block.
    --
    -- Separate from LoadTrigger. FillTriggerVehicle:onLoad unconditionally creates
    -- FillTrigger.new(triggerNode, self, ...) whenever a vehicle XML defines
    -- vehicle.fillTriggerVehicle#triggerNode. When such a vehicle enters a map fill
    -- source's trigger, FillTrigger:fillTriggerCallback registers it via
    -- FillUnit:addFillUnitTrigger, which (a) adds the FillActivatable (the vanilla
    -- R/refill prompt) and (b) lets FillUnit:update pump liters each tick through
    -- trigger:fillVehicle. An SPS sprayer/tanker saved parked in a fill zone therefore
    -- gets a brief vanilla fill at spawn that the LoadTrigger hook above never sees
    -- (confirmed: the [SPS LT] trace shows the sprayer blocked=true throughout, yet R
    -- still flashed once on load-in).
    --
    -- FillUnit consults exactly two FillTrigger methods, so gate both on the same
    -- spsBlocksFillable recognition (slurry OR sprayer registered / has sprayer config)
    -- with AI passthrough, mirroring the LoadTrigger getAllowsActivation + startLoading
    -- pair:
    --   * getIsActivatable(vehicle) — FillActivatable:getIsActivatable (prompt) and
    --     FillUnit:setFillUnitIsFilling (currentTrigger selection). False => no prompt,
    --     cannot be picked to fill.
    --   * fillVehicle(vehicle, delta, dt) — the per-tick liter pump (FillUnit:update).
    --     0 => no liters, belt-and-braces.
    -- -----------------------------------------------------------------------
    if FillTrigger ~= nil and FillTrigger.getIsActivatable ~= nil then
        local origFTGetIsActivatable = FillTrigger.getIsActivatable
        FillTrigger.getIsActivatable = function(self, vehicle)
            if spsBlocksFillable(vehicle) then
                if DEBUG then
                    print(string.format("[SPS FT] getIsActivatable BLOCKED vehicle=%s",
                        tostring(vehicle and vehicle.configFileName)))
                end
                return false
            end
            return origFTGetIsActivatable(self, vehicle)
        end

        if FillTrigger.fillVehicle ~= nil then
            local origFTFillVehicle = FillTrigger.fillVehicle
            FillTrigger.fillVehicle = function(self, vehicle, delta, dt)
                if spsBlocksFillable(vehicle) then
                    if DEBUG then
                        print(string.format("[SPS FT] fillVehicle BLOCKED vehicle=%s",
                            tostring(vehicle and vehicle.configFileName)))
                    end
                    return 0
                end
                return origFTFillVehicle(self, vehicle, delta, dt)
            end
        end

        print("[SPS INIT] FillTrigger.getIsActivatable/fillVehicle hook INSTALLED")
    else
        print("[SPS INIT] WARNING: FillTrigger.getIsActivatable not available — vehicle-side fill block not installed")
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
        -- -------------------------------------------------------------------
        -- Sprayer types (sprayer / selfPropelledSprayer) — block vanilla
        -- R and I in the cab. Mirrors the manureBarrel block above.
        -- -------------------------------------------------------------------
        if baseName == "sprayer" or baseName == "selfPropelledSprayer" then
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
                "getAllowLoadTriggerActivation",
                SlurryPipeSystemOverride.getAllowLoadTriggerActivation
            )
        end
        -- Register getCanBeTurnedOn and getCanToggleTurnedOn on ALL types that have
        -- the turnOnVehicle spec — this prevents fold state or spreader state from
        -- auto-turning off SPS pump via the turnOffIfNotAllowed mechanism.
        -- Also register getIsDischargeNodeActive on all types with dischargeable spec
        -- so attached spreader implements can't discharge without SPS spreaderValveOpen.
        if typeEntry.specializations ~= nil then
            local hasTurnOn = false
            local hasDischargeable = false
            local hasFillUnit = false
            local hasSprayer = false
            for _, spec in ipairs(typeEntry.specializations) do
                if spec.className == "TurnOnVehicle" then hasTurnOn = true end
                if spec.className == "Dischargeable" then hasDischargeable = true end
                if spec.className == "FillUnit" then hasFillUnit = true end
                if spec.className == "Sprayer" then hasSprayer = true end
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
                -- Keep the (activatable) slurry fill unit active while pressure-driven
                -- discharge is in progress so an attached spreader implement can keep
                -- drawing slurry after the pump/PTO is switched off (taper instead of
                -- stop). Registered on ALL turnOn source types — covers both the
                -- manureBarrel tanker (Samson) and self-propelled sources (Oxbo).
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "getIsFillUnitActive",
                    SlurryPipeSystemOverride.getIsFillUnitActive
                )
                -- Block the vanilla turn-on driver from playing the SPS-managed
                -- spreader animation; SPS drives it from discharge instead.
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "getIsTurnedOnAnimationActive",
                    SlurryPipeSystemOverride.getIsTurnedOnAnimationActive
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
            -- For any type with a fill unit: append stored SPS pressure to the
            -- fill-levels HUD bar (after the fill type name, e.g. "(+1.2 Bar)").
            -- The override self-guards on isRegistered + getPressureInfoText, so it
            -- is a no-op for non-SPS vehicles and unregistered states.
            if hasFillUnit then
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "getFillLevelInformation",
                    SlurryPipeSystemOverride.getFillLevelInformation
                )
                -- On-foot info box (bottom-right): append the SPS pressure / pump-rate
                -- reading so a player stood beside the tanker sees the same gauge as
                -- the in-cab fill bar. Self-guards on isRegistered + getPressureInfoText,
                -- so it is a no-op for non-SPS vehicles and gauge-less tankers.
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "showInfo",
                    SlurryPipeSystemOverride.showInfo
                )
            end
            -- For any spreader (Sprayer spec): hold the implement's working-speed
            -- limit while the SPS spreader valve is open, so turning the PTO off at
            -- the headland (which releases the vanilla turnOn-gated speed cap) does
            -- not let the vehicle speed up while stored pressure is still spreading.
            -- The override self-guards on SPS state, so it is a no-op otherwise.
            if hasSprayer then
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "doCheckSpeedLimit",
                    SlurryPipeSystemOverride.doCheckSpeedLimit
                )
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "getRawSpeedLimit",
                    SlurryPipeSystemOverride.getRawSpeedLimit
                )
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry,
                    "getSprayerUsage",
                    SlurryPipeSystemOverride.getSprayerUsage
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

    -- Load SPS pipe effect material holder — provides "pipe" (slurry) and "spsWaterPipe" (water) materials.
    -- Scene order: child 0 = unload_materialHolder, child 1 = unloadSmoke_materialHolder,
    --              child 2 = unloadPipe_materialHolder (slurry), child 3 = unloadWaterPipe_materialHolder (water)
    g_spsSlurryMaterial     = nil
    g_spsSlurryMaterialNode = nil
    g_spsWaterMaterial      = nil
    local matHolderPath = SPS_MOD_DIRECTORY .. "i3d/materials/unloadMeshes_materialHolder.i3d"
    local matNode = loadI3DFile(matHolderPath)
    if matNode ~= nil and matNode ~= 0 then
        local pipeMatShape  = getChildAt(matNode, 2)
        if pipeMatShape ~= nil and pipeMatShape ~= 0 then
            g_spsSlurryMaterial = getMaterial(pipeMatShape, 0)
        else
            print("[SPS INIT] WARNING: unloadPipe_materialHolder shape not found at child index 2")
        end
        local waterMatShape = getChildAt(matNode, 3)
        if waterMatShape ~= nil and waterMatShape ~= 0 then
            g_spsWaterMaterial = getMaterial(waterMatShape, 0)
        else
            print("[SPS INIT] WARNING: unloadWaterPipe_materialHolder shape not found at child index 3")
        end
        link(getRootNode(), matNode)
        setVisibility(matNode, false)
        g_spsSlurryMaterialNode = matNode
    else
        print("[SPS INIT] WARNING: unloadMeshes_materialHolder.i3d not found at " .. matHolderPath)
    end

    g_slurryPipeManager = SlurryPipeManager.new()

    -- [SPS MP] When a client finishes joining, the server sends it the full current
    -- SPS state (chains, connections, valves, pump/flow). Event replication only
    -- covers changes made while connected, so without this a late joiner sees none
    -- of the setup that happened before they joined.
    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.PLAYER_CREATED ~= nil then
        g_messageCenter:subscribe(MessageType.PLAYER_CREATED,
            g_slurryPipeManager.onPlayerJoined, g_slurryPipeManager)
    end

    g_slurryPipeManager:loadPipeColors(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadVehicleConfigs(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadPlaceableConfigs(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadSprayerVehicleConfigs(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadSprayerPlaceableConfigs(SPS_MOD_DIRECTORY)

    -- Top-centre spreader HUD (DB icon + section cells + slurry details)
    g_spsSpreaderHUD = SPSSpreaderHUD.new(SPS_MOD_DIRECTORY)

    -- Sprayer pipe visual
    if g_spsSprayerPipeVisual ~= nil then
        g_spsSprayerPipeVisual:delete()
        g_spsSprayerPipeVisual = nil
    end
    g_spsSprayerPipeVisual = SPSSprayerPipeVisual.new(SPS_MOD_DIRECTORY)
    g_spsSprayerPipeVisual:load()

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
                g_slurryPipeManager:registerSprayerPlaceable(placeable)
            end
        end
        -- Map-embedded (preplaced) placeables
        if ps.uniqueIdToReplacedPlaceableData ~= nil then
            for _, data in pairs(ps.uniqueIdToReplacedPlaceableData) do
                local placeable = data.placeable
                if placeable ~= nil and (placeable.spec_silo ~= nil or placeable.spec_husbandry ~= nil or placeable.spec_siloExtension ~= nil or placeable.spec_productionPoint ~= nil) then
                    g_slurryPipeManager:registerPlaceable(placeable)
                    g_slurryPipeManager:registerSprayerPlaceable(placeable)
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
        g_spsWaterMaterial  = nil
    end
    if g_spsPipeVisual ~= nil then
        g_spsPipeVisual:delete()
        g_spsPipeVisual = nil
    end
    if g_spsSprayerPipeVisual ~= nil then
        g_spsSprayerPipeVisual:delete()
        g_spsSprayerPipeVisual = nil
    end
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:delete()
        g_slurryPipeManager = nil
    end

    if g_spsSpreaderHUD ~= nil then
        if g_spsSpreaderHUD:isEditMode() then SPSMod:exitHudEdit() end
        g_spsSpreaderHUD:delete()
        g_spsSpreaderHUD = nil
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

function SPSMod:draw()
    if g_spsSpreaderHUD ~= nil then
        g_spsSpreaderHUD:draw()
    end
end

function SPSMod:mouseEvent(posX, posY, isDown, isUp, button)
    if g_spsSpreaderHUD == nil or not g_spsSpreaderHUD:isEditMode() then return end
    -- scroll wheel scales
    if isDown and button == Input.MOUSE_BUTTON_WHEEL_UP then
        g_spsSpreaderHUD:applyScroll(0.05)
    elseif isDown and button == Input.MOUSE_BUTTON_WHEEL_DOWN then
        g_spsSpreaderHUD:applyScroll(-0.05)
    end
    -- hold left button to drag the panel
    if button == Input.MOUSE_BUTTON_LEFT then
        if isDown then SPSMod._hudDragging = true
        elseif isUp then SPSMod._hudDragging = false end
    end
    if SPSMod._hudDragging then
        g_spsSpreaderHUD:applyMouseMove(posX, posY)
    end
end

SPSMod.HUD_EDIT_CONTEXT = "SPS_HUD_EDIT_CONTEXT"

-- Enter edit mode: switch to a fresh input context so the vehicle camera / driving
-- actions go inactive (the camera no longer reads the mouse axis), show the cursor, and
-- register the exit toggle inside that context so the same key locks it again.
function SPSMod:enterHudEdit()
    if g_spsSpreaderHUD == nil or g_spsSpreaderHUD:isEditMode() then return end
    if g_inputBinding == nil then return end
    g_spsSpreaderHUD:setEditMode(true)
    SPSMod._hudDragging = false
    g_inputBinding:setContext(SPSMod.HUD_EDIT_CONTEXT, true, false)
    local _, exitId = g_inputBinding:registerActionEvent(
        InputAction.SPS_HUD_EDIT, SPSMod, SPSMod.onHudEditExitInput,
        false, true, false, true, nil)
    SPSMod._hudEditExitId = exitId
    if exitId ~= nil and exitId ~= "" then
        g_inputBinding:setActionEventText(exitId, g_i18n:getText("action_spsHudEdit"))
        g_inputBinding:setActionEventTextVisibility(exitId, true)
        g_inputBinding:setActionEventTextPriority(exitId, GS_PRIO_VERY_HIGH)
    end
    g_inputBinding:setShowMouseCursor(true)
    print("[SPS HUD] edit mode ON (context switched, camera frozen)")
end

-- Exit edit mode: revert the context (re-enabling camera / driving) and hide the cursor.
function SPSMod:exitHudEdit()
    if g_inputBinding == nil then return end
    if g_spsSpreaderHUD ~= nil then g_spsSpreaderHUD:setEditMode(false) end
    SPSMod._hudDragging = false
    if SPSMod._hudEditExitId ~= nil and SPSMod._hudEditExitId ~= "" then
        g_inputBinding:removeActionEvent(SPSMod._hudEditExitId)
        SPSMod._hudEditExitId = nil
    end
    g_inputBinding:setShowMouseCursor(false)
    if g_inputBinding:getContextName() == SPSMod.HUD_EDIT_CONTEXT then
        g_inputBinding:revertContext(true)
    end
    print("[SPS HUD] edit mode OFF (context reverted; position/scale persist on save)")
end

function SPSMod:onHudEditExitInput(actionName, inputValue, callbackState, isAnalog)
    SPSMod:exitHudEdit()
end

function SPSMod:update(dt)
    if g_slurryPipeManager ~= nil then
        g_slurryPipeManager:update(dt)
        g_slurryPipeManager:updateSprayers(dt)
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

    -- Slurry registration
    local config = g_slurryPipeManager:findVehicleConfigForVehicle(self)
    if config ~= nil then
        g_slurryPipeManager:registerVehicle(self)
    end

    -- Sprayer registration (independent of slurry — a vehicle may have either or both)
    local sprayerConfig = g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self)
    if sprayerConfig ~= nil then
        g_slurryPipeManager:registerSprayerVehicle(self)
    end

    -- Samson-specific patch and action events only apply to slurry-registered vehicles
    if not g_slurryPipeManager:isRegistered(self) then return end
    -- A blockage-only spreader implement (dribble bar) is SPS-registered for its
    -- blockage nodes only; it must NOT get tanker patches/controls — its tanker drives it.
    if g_slurryPipeManager:isSpreaderImplement(self) then return end


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
    if not self.isClient then return end
    if not self:getIsActiveForInput(true) then return end

    -- ---------------------------------------------------------------------------
    -- SPRAYER safety net: if any R/I events slipped past the type-level override,
    -- remove them here. Uses findSprayerVehicleConfigForVehicle (needs only
    -- configFileName) so it works regardless of registration timing.
    -- ---------------------------------------------------------------------------
    if g_slurryPipeManager:isSprayerVehicleRegistered(self)
    or g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil then
        local specD = self.spec_dischargeable
        if specD ~= nil and specD.actionEvents ~= nil then
            local evTip = specD.actionEvents[InputAction.TOGGLE_TIPSTATE]
            if evTip ~= nil then
                g_inputBinding:removeActionEvent(evTip.actionEventId)
                specD.actionEvents[InputAction.TOGGLE_TIPSTATE] = nil
                print("[SPS INIT] sprayer cab: removed TOGGLE_TIPSTATE (I)")
            end
            local evGround = specD.actionEvents[InputAction.TOGGLE_TIPSTATE_GROUND]
            if evGround ~= nil then
                g_inputBinding:removeActionEvent(evGround.actionEventId)
                specD.actionEvents[InputAction.TOGGLE_TIPSTATE_GROUND] = nil
                print("[SPS INIT] sprayer cab: removed TOGGLE_TIPSTATE_GROUND (R)")
            end
        end
        -- FillUnit's <unloading> XML element causes it to register InputAction.UNLOAD
        -- (the "I — UNLOAD" pallet-spawn action) when the implement is unfolded /
        -- active for input. Re-registration happens on fold/unfold, so this hook
        -- catches each register cycle and strips it.
        local specFU = self.spec_fillUnit
        if specFU ~= nil and specFU.actionEvents ~= nil then
            local evUnload = specFU.actionEvents[InputAction.UNLOAD]
            if evUnload ~= nil then
                g_inputBinding:removeActionEvent(evUnload.actionEventId)
                specFU.actionEvents[InputAction.UNLOAD] = nil
                specFU.unloadActionEventId = nil
                print("[SPS INIT] sprayer cab: removed UNLOAD (I — pallet spawn)")
            end
        end
    end

    -- ---------------------------------------------------------------------------
    -- SLURRY block — skip for sprayer-registered vehicles (sprayer controls
    -- are outside only via SPSSprayerPumpControl, not in the cab).
    -- ---------------------------------------------------------------------------
    if not g_slurryPipeManager:isRegistered(self) then return end
    if g_slurryPipeManager:isSpreaderImplement(self) then return end
    if g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil then return end
    if self.spec_turnOnVehicle == nil then return end

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
    -- Cab PTO/pump toggle now routes through the shared manager method so the
    -- outside ptoControl node and the cab do the identical thing.
    local pumpCallback = function(vehicle, actionName, inputValue, callbackState, isAnalog)
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:togglePump(vehicle)
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
        -- HVP tankers drive a high-volume pump rather than building tank vacuum, so the
        -- prompt names the HVP; vacuum/conduit keep the existing pump wording.
        local pumpType = g_slurryPipeManager:getPumpType(self)
        local pumpTextOff, pumpTextOn
        if pumpType == "HVP" then
            pumpTextOff = g_i18n:getText("action_spsHVPOff")
            pumpTextOn  = g_i18n:getText("action_spsHVPOn")
        else
            pumpTextOff = g_i18n:getText("action_slurryPumpOff")
            pumpTextOn  = g_i18n:getText("action_slurryPumpOn")
        end
        g_inputBinding:setActionEventText(pid, pumpOn and pumpTextOff or pumpTextOn)
        g_inputBinding:setActionEventTextPriority(pid, GS_PRIO_VERY_HIGH)
        pumpEventId = pid
    end

    -- SPS_HUD_EDIT: enter spreader-HUD edit mode (camera frozen via context switch).
    -- Default bind is middle mouse (rebindable in Controls). Exiting is handled by a
    -- second binding registered inside the edit context (see SPSMod:enterHudEdit).
    local _, hudEditId = self:addActionEvent(
        spsEvents, InputAction.SPS_HUD_EDIT, self,
        function(vehicle, actionName, inputValue, callbackState, isAnalog)
            SPSMod:enterHudEdit()
        end,
        false, true, false, true, nil)
    if hudEditId ~= nil then
        g_inputBinding:setActionEventText(hudEditId, g_i18n:getText("action_spsHudEdit"))
        g_inputBinding:setActionEventTextPriority(hudEditId, GS_PRIO_LOW)
    end
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
            local isConduit    = g_slurryPipeManager:isVehicleConduit(self)
            local flowOpenKey  = isConduit and "action_spsConduitFlowOpen"  or "action_slurryFlowOpen"
            local flowCloseKey = isConduit and "action_spsConduitFlowClose" or "action_slurryFlowClose"
            local flowTxt = (state and state.valveOpen)
                and g_i18n:getText(flowCloseKey)
                or  g_i18n:getText(flowOpenKey)
            g_inputBinding:setActionEventText(id, flowTxt)
            g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
            flowEventId = id
        end
    end

    -- SPS_TOGGLE_DIRECTION
    -- Suppressed in the cab when the tanker carries an outside <directionControl>
    -- node — in that case direction is set only at the node.
    local dirEventId = nil
    if not (g_slurryPipeManager ~= nil and g_slurryPipeManager:vehicleHasOutsideDirectionControl(self)) then
        local _, dirId = self:addActionEvent(
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
        if dirId ~= nil then
            local state = g_slurryPipeManager:getVehicleState(self)
            local isConduit = g_slurryPipeManager:isVehicleConduit(self)
            local pumpType  = g_slurryPipeManager:getPumpType(self)
            local dirTxt
            if isConduit then
                dirTxt = (state and state.direction == SPS_DIRECTION_FILL)
                    and g_i18n:getText("action_spsConduitDirBtoA")
                    or  g_i18n:getText("action_spsConduitDirAtoB")
            elseif pumpType == "HVP" then
                dirTxt = (state and state.direction == SPS_DIRECTION_FILL)
                    and g_i18n:getText("action_spsHVPDirDischarge")
                    or  g_i18n:getText("action_spsHVPDirFill")
            else
                dirTxt = (state and state.direction == SPS_DIRECTION_FILL)
                    and g_i18n:getText("action_slurryDirectionDischarge")
                    or  g_i18n:getText("action_slurryDirectionFill")
            end
            g_inputBinding:setActionEventText(dirId, dirTxt)
            g_inputBinding:setActionEventTextPriority(dirId, GS_PRIO_VERY_HIGH)
            dirEventId = dirId
        end
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
        if g_slurryPipeManager:isSprayerVehicleRegistered(self) then
            g_slurryPipeManager:unregisterSprayerVehicle(self)
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
        if g_slurryPipeManager:getSprayerPlaceableEntry(self) == nil then
            g_slurryPipeManager:registerSprayerPlaceable(self)
        end
    end
end

local origPlaceableDelete = Placeable.delete
function Placeable:delete(immediate)
    if g_slurryPipeManager ~= nil and (self.spec_silo ~= nil or self.spec_husbandry ~= nil or self.spec_siloExtension ~= nil or self.spec_productionPoint ~= nil) then
        g_slurryPipeManager:unregisterPlaceable(self)
        g_slurryPipeManager:unregisterSprayerPlaceable(self)
    end
    if origPlaceableDelete ~= nil then
        origPlaceableDelete(self, immediate)
    end
end