-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.9

-- init.lua
-- FS25_SlurryPipeSystem

local SPS_MOD_DIRECTORY = g_currentModDirectory
local SPS_MOD_NAME      = "FS25_SlurryPipeSystem"

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] init 1.0.0.9.37 loaded") end

SlurryDebug.enabled = false  -- boot default; controlled by SPSDebugConfig channel "SlurryDebug"

-- [SPS SPRAY] Sprayer-issue diagnostic trace for the action-event path. Logs,
-- once per vehicle per register cycle, whether a sprayer-config vehicle keeps
-- its vanilla turn-on (B) event or has R/I stripped. Prefixed [SPS SPRAY] to
-- match the manager/override traces.
-- Gate lives in scripts/SPSDebugConfig.lua (channel "Init.SprayerTrace").
local function sprayTrace(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("Init.SprayerTrace") then return end
    if select("#", ...) > 0 then
        print("[SPS SPRAY] " .. string.format(fmt, ...))
    else
        print("[SPS SPRAY] " .. tostring(fmt))
    end
end

source(SPS_MOD_DIRECTORY .. "scripts/settings/SPSSettingsMenuExtension.lua")
source(SPS_MOD_DIRECTORY .. "scripts/hud/SPSConduitHUDExtension.lua")

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
-- [SPS IBC] Vanilla liquid-tank (IBC) geometry redirect.
--
-- The basegame liquid tanks (fertilizer / herbicide, incl. Helm / Corteva brand
-- variants) all share ONE geometry file:
--     $data/objects/pallets/liquidTank/liquidTank.i3d
-- which Vehicle:load streams via g_i3DManager:loadSharedI3DFileAsync
-- (Vehicle.lua l.534 — that call passes the Vehicle itself as the async callback
-- object, and self.configFileName is already set by Vehicle:setFilename, l.402).
--
-- When SPS is loaded we transparently swap that geometry for the SPS copy, which
-- is node-for-node identical to vanilla (so the vanilla XML i3dMappings still
-- resolve) and additionally carries the sprayer-pipe coupler branch.
--
-- Selection is keyed on the loading vehicle's configFileName so different fill
-- types can point at different SPS i3ds. A liquid-tank config with no SPS mapping
-- is passed straight through to vanilla untouched; every non-liquid-tank i3d load
-- is likewise passed through unchanged. The wrapper forwards all six arguments to
-- the original unmodified, so no other load path is affected.
-- ---------------------------------------------------------------------------
local SPS_IBC_VANILLA_I3D_TAIL = "objects/pallets/liquidtank/liquidtank.i3d"

-- vehicle configFileName tail (lowercased, forward-slashed) -> SPS i3d file
-- (mod-relative). Add herbicide / further variants here as their SPS i3ds are
-- authored; unmapped liquid-tank configs stay on vanilla geometry.
local SPS_IBC_CONFIG_TO_I3D = {
    ["objects/pallets/liquidtank/fertilizertank.xml"]     = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["objects/pallets/liquidtank/fertilizertankhelm.xml"] = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    -- Herbicide tanks share the same vanilla liquidTank.i3d, so the SPS copy (which
    -- carries every config node plus the couplers) serves them too; the tank XML's
    -- objectChanges toggle the herbicide decals on the shared geometry.
    ["objects/pallets/liquidtank/herbicidetank.xml"]      = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["objects/pallets/liquidtank/herbicidetankhelm.xml"]  = "i3d/IBCs/fertilizerTank/liquidTank.i3d",

    -- [SPS +S&F] TheCodingDad Soil & Fertilizer liquid IBC tanks. All 12 parentFile the
    -- vanilla fertilizerTankHelm / herbicideTankHelm, so they stream the same shared
    -- liquidTank.i3d intercepted above and take the same SPS coupler-baked copy. Tail-keyed
    -- on the S&F config path, so install-location-independent; inert if S&F is not present.
    ["fs25_soilfertilizer/objects/liquidtank/uan32/liquidtank_uan32.xml"]                 = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/uan28/liquidtank_uan28.xml"]                 = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/anhydrous/liquidtank_anhydrous.xml"]         = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/starter/liquidtank_starter.xml"]             = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/liquid_urea/liquidtank_liquid_urea.xml"]     = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/liquid_ams/liquidtank_liquid_ams.xml"]       = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/liquid_map/liquidtank_liquid_map.xml"]       = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/liquid_dap/liquidtank_liquid_dap.xml"]       = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/liquid_potash/liquidtank_liquid_potash.xml"] = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/liquidlime/liquidtank_liquidlime.xml"]       = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/insecticide/liquidtank_insecticide.xml"]     = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
    ["fs25_soilfertilizer/objects/liquidtank/fungicide/liquidtank_fungicide.xml"]         = "i3d/IBCs/fertilizerTank/liquidTank.i3d",
}

do
    -- Debug gate lives in scripts/SPSDebugConfig.lua (channel "Init.IbcRedirect").
    -- NOTE: the old local flag shipped TRUE in 1.0.0.8; the registry default is
    -- false, so the per-redirect [SPS IBC] lines are now silent unless enabled.
    local function ibcDbg()
        return SPSDebugConfig ~= nil and SPSDebugConfig.isOn("Init.IbcRedirect")
    end

    local origLoadSharedI3DFileAsync = I3DManager.loadSharedI3DFileAsync
    I3DManager.loadSharedI3DFileAsync = function(self, filename, callOnCreate, addToPhysics,
                                                 asyncCallbackFunction, asyncCallbackObject, asyncCallbackArguments)
        if filename ~= nil then
            local fnLower = filename:lower():gsub("\\", "/")
            if fnLower:sub(-#SPS_IBC_VANILLA_I3D_TAIL) == SPS_IBC_VANILLA_I3D_TAIL then
                -- asyncCallbackObject is the loading Vehicle (Vehicle.lua l.534).
                local cfg = asyncCallbackObject ~= nil and asyncCallbackObject.configFileName or nil
                if cfg ~= nil then
                    local cfgLower = cfg:lower():gsub("\\", "/")
                    for cfgTail, spsRel in pairs(SPS_IBC_CONFIG_TO_I3D) do
                        if cfgLower:sub(-#cfgTail) == cfgTail then
                            local spsPath = SPS_MOD_DIRECTORY .. spsRel
                            if ibcDbg() then
                                print(string.format(
                                    "[SPS IBC] i3d redirect: '%s' -> '%s' (config '%s')",
                                    tostring(filename), tostring(spsPath), tostring(cfg)))
                            end
                            filename = spsPath
                            break
                        end
                    end
                end
            end
        end
        return origLoadSharedI3DFileAsync(self, filename, callOnCreate, addToPhysics,
                                          asyncCallbackFunction, asyncCallbackObject, asyncCallbackArguments)
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
    -- Debug gate lives in scripts/SPSDebugConfig.lua (channel "Init.LoadTrigger").
    local function ltDbg()
        return SPSDebugConfig ~= nil and SPSDebugConfig.isOn("Init.LoadTrigger")
    end
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
            if ltDbg() then
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
                    if ltDbg() then
                        print(string.format("[SPS LT] startLoading BLOCKED fillable=%s",
                            tostring(fillableObject and fillableObject.configFileName)))
                    end
                    return
                end
                return origStartLoading(self, fillType, fillableObject, fillUnitIndex)
            end
        end

        -- Positive confirmation the hook installed (always printed, once, at source time).
        spsInfo("[SPS INIT] LoadTrigger.getAllowsActivation hook INSTALLED")
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
                if ltDbg() then
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
                    if ltDbg() then
                        print(string.format("[SPS FT] fillVehicle BLOCKED vehicle=%s",
                            tostring(vehicle and vehicle.configFileName)))
                    end
                    return 0
                end
                return origFTFillVehicle(self, vehicle, delta, dt)
            end
        end

        spsInfo("[SPS INIT] FillTrigger.getIsActivatable/fillVehicle hook INSTALLED")
    else
        print("[SPS INIT] WARNING: FillTrigger.getIsActivatable not available — vehicle-side fill block not installed")
    end
end


-- ---------------------------------------------------------------------------
-- registerOverrides
-- Called from loadMap() after TypeManager:finalizeTypes() has completed.
-- ---------------------------------------------------------------------------

-- [SPS 1.0.1.4] Ancestry-aware type match.
--
-- The blocks below used to compare the type's BASE NAME by exact equality, so a
-- modder's derived type — declared in their modDesc as e.g.
--     <type name="abbey3000" parent="manureBarrel" className="Vehicle"
--           filename="$dataS/scripts/vehicles/Vehicle.lua"> ... </type>
-- — silently missed every tanker/sprayer override: the vehicle still registered
-- with SPS (capture is configFileName/embedded-XML based, type-agnostic), but
-- vanilla discharge, load-trigger and turn-on behaviour was never gated, which
-- breaks it in play.
--
-- TypeManager:addType stores the full PARENT TYPE ENTRY on every type
-- (`["parent"] = parent`, TypeManager.lua:60, source-verified), and this runs
-- after finalizeTypes when all mod types are loaded, so the chain is complete
-- here. Walking it makes any descendant of a matched base type match too.
-- Mod types are namespaced "FS25_ModName.typeName"; the base-name strip below
-- handles that at every level of the chain. Depth-capped defensively — vanilla
-- chains are short and a cycle would otherwise hang the loop.
--
-- NOTE the NEGATIVE checks further down ("attached implement, NOT a tanker")
-- must use this same predicate: with exact-name matching there, a derived
-- tanker would receive BOTH the tanker override and the attached-implement
-- override on the same function, and the two would chain unpredictably.
local function spsTypeIsa(typeEntry, wantedBaseNames)
    local entry, depth = typeEntry, 0
    while entry ~= nil and depth < 16 do
        local name = entry.name
        if name ~= nil then
            local base = name:match("%.?([^%.]+)$") or name
            if wantedBaseNames[base] then return true end
        end
        entry = entry.parent
        depth = depth + 1
    end
    return false
end

local SPS_TANKER_TYPES  = { manureBarrel = true, manureTrailer = true, selfPropelledManureBarrel = true }
local SPS_SPRAYER_TYPES = { sprayer = true, selfPropelledSprayer = true }

local function registerOverrides()
    if g_vehicleTypeManager == nil then
        print("[SPS INIT] ERROR: g_vehicleTypeManager nil in registerOverrides")
        return
    end

    local types = g_vehicleTypeManager:getTypes()
    local count = 0

    -- [SPS 1.0.1.5] Record which types received the TANKER override set, so
    -- registerVehicle can tell "this slurry-registered vehicle's type was never
    -- covered" and install the same overrides on the vehicle INSTANCE instead
    -- (SlurryPipeManager:applyInstanceTankerOverrides). That is the safety net
    -- for custom types that neither carry a vanilla tanker name nor descend
    -- from one (e.g. the LSFM tank pack: parent="sprayer"/"tractor" with an
    -- embedded <slurryPipeSystem> block).
    SlurryPipeSystemOverride.typeLevelTankerOverrides = {}

    for typeName, typeEntry in pairs(types) do
        local isTankerType = spsTypeIsa(typeEntry, SPS_TANKER_TYPES)
        if isTankerType then
            SlurryPipeSystemOverride.typeLevelTankerOverrides[typeEntry.name or typeName] = true
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
        -- NOT `spsTypeIsa(SPRAYER)` alone: vanilla manureBarrel/selfPropelledManureBarrel
        -- themselves DESCEND from the sprayer types (manureBarrel = sprayer +
        -- manureBarrel spec + fillTriggerVehicle, vehicleTypes.xml), so every tanker
        -- type also walks to "sprayer" and would collect this block's overrides a
        -- second time on top of the tanker set. The tanker set already contains all
        -- three functions below, so excluding tanker types loses nothing and keeps
        -- the slurry and fert/herb families cleanly apart.
        if not isTankerType and spsTypeIsa(typeEntry, SPS_SPRAYER_TYPES) then
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
            if hasDischargeable and not isTankerType then
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
            if hasWorkArea and not isTankerType then
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

    -- [SPS 1.0.0.9.24] Publish the mod directory on the mission object. The
    -- three SPSCouplerAnimator.ensureLoaded call sites in SPSM_Sprayers read
    -- g_currentMission.spsModDirectory, which was never assigned in 1.0.0.9 —
    -- whichever sprayer-config item registered first passed nil and latched an
    -- EMPTY animation library for the whole session (every later coupler bind
    -- then printed "not in library", savegame-order dependent).
    if g_currentMission ~= nil then
        g_currentMission.spsModDirectory = SPS_MOD_DIRECTORY
    end

    g_slurryPipeManager:loadPipeColors(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadVehicleConfigs(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadPlaceableConfigs(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadSprayerVehicleConfigs(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadSprayerPlaceableConfigs(SPS_MOD_DIRECTORY)
    g_slurryPipeManager:loadSprayerSourceVehicleConfigs(SPS_MOD_DIRECTORY)
    -- [SPS 1.0.1.8] Farm liquid lanes: animal water in / milk out (own registries, own XML blocks)
    if g_slurryPipeManager.loadLiquidLaneVehicleConfigs ~= nil then
        g_slurryPipeManager:loadLiquidLaneVehicleConfigs(SPS_MOD_DIRECTORY)
        g_slurryPipeManager:loadLiquidLanePlaceableConfigs(SPS_MOD_DIRECTORY)
    end

    -- Append " SPS" to the shop name of every SPS-compatible store item. Runs here,
    -- after all config maps (slurry + sprayer, vehicle + placeable) are populated,
    -- because store items are built by the base StoreManager before this loadMap.
    if g_slurryPipeManager.tagSPSStoreItems ~= nil then
        local okTag, errTag = pcall(function() g_slurryPipeManager:tagSPSStoreItems() end)
        if not okTag then
            print("[SPS INIT] tagSPSStoreItems error: " .. tostring(errTag))
        end
    end

    -- Top-centre spreader HUD (DB icon + section cells + slurry details)
    g_spsSpreaderHUD = SPSSpreaderHUD.new(SPS_MOD_DIRECTORY)

    -- Sprayer pipe visual
    if g_spsSprayerPipeVisual ~= nil then
        g_spsSprayerPipeVisual:delete()
        g_spsSprayerPipeVisual = nil
    end
    g_spsSprayerPipeVisual = SPSSprayerPipeVisual.new(SPS_MOD_DIRECTORY)
    g_spsSprayerPipeVisual:load()

    -- [SPS 1.0.1.8] Liquid-lane hose: a SECOND instance of the sprayer hose
    -- visual (same asset, own pipe list) so the two lanes never share state.
    if g_spsLiquidLanePipeVisual ~= nil then
        g_spsLiquidLanePipeVisual:delete()
        g_spsLiquidLanePipeVisual = nil
    end
    if g_spsHoseVisual ~= nil then
        g_spsHoseVisual:delete()
        g_spsHoseVisual = nil
    end
    g_spsLiquidLanePipeVisual = SPSSprayerPipeVisual.new(SPS_MOD_DIRECTORY)
    g_spsLiquidLanePipeVisual:load()

    -- [SPS 1.0.1.8] NEW physical hoses (proof build). Loads
    -- i3d/pipes/hoses.i3d once as an invisible template; nothing
    -- in the live mod draws with it yet - only the spsHoseProof* console commands.
    if g_spsHoseVisual ~= nil then
        g_spsHoseVisual:delete()
        g_spsHoseVisual = nil
    end
    if SPSHoseVisual ~= nil then
        g_spsHoseVisual = SPSHoseVisual.new(SPS_MOD_DIRECTORY)
        g_spsHoseVisual:load()
    end

    -- Create water plane manager (but don't load planes yet - terrain not ready)
    g_waterPlaneManager = SPSWaterPlaneManager.new(SPS_MOD_DIRECTORY)

    local savePath = SlurryPipeManager.getSavePath()
    if savePath ~= nil then
        g_slurryPipeManager:loadCouplingConnections(savePath)
    end
    -- [SPS 1.0.1.8] Pipe mode: hide / show the physical pipe shop items for the loaded (or default) mode;
    -- arm the one-off start-up choice dialog (shows only while pipeModeChosen is false, host only).
    g_slurryPipeManager:applyPhysicalPipesSetting()
    if SPSPipeModeDialog ~= nil then SPSPipeModeDialog.reset() end
    addConsoleCommand("spsPhysicalPipes", "Pipe mode: [on|off] - on = physical pipes only (original lay/connect prompts off), off = original system (physical pipes hidden in the shop)", "consolePhysicalPipes", g_slurryPipeManager)

    registerOverrides()

    -- [SPS] Fixed-agitator tractor overrides: installs the movement lock
    -- (updateVehiclePhysics) on all drivable types and registers the
    -- "spsAgitatorDebug" console command. Self-iterates types, so it is a single
    -- call here alongside registerOverrides() (same post-finalizeTypes timing).
    -- Without this the connected tractor is never held in place. Guarded so a
    -- missing agitator module can never break loadMap.
    if SPSFixedAgitator ~= nil and SPSFixedAgitator.registerOverrides ~= nil then
        local okAg, errAg = pcall(SPSFixedAgitator.registerOverrides)
        if not okAg then
            print("[SPS INIT] agitator registerOverrides error: " .. tostring(errAg))
        end
    end

    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        local ps = g_currentMission.placeableSystem
        -- Bought/saved placeables
        local placeables = ps.placeables or {}
        for _, placeable in ipairs(placeables) do
            if placeable ~= nil and (placeable.spec_silo ~= nil or placeable.spec_husbandry ~= nil or placeable.spec_siloExtension ~= nil or placeable.spec_productionPoint ~= nil or placeable.spec_buyingStation ~= nil) then
                g_slurryPipeManager:registerPlaceable(placeable)
                g_slurryPipeManager:registerSprayerPlaceable(placeable)
                if g_slurryPipeManager.registerLiquidLanePlaceable ~= nil then
                    g_slurryPipeManager:registerLiquidLanePlaceable(placeable)
                end
            end
        end
        -- Map-embedded (preplaced) placeables
        if ps.uniqueIdToReplacedPlaceableData ~= nil then
            for _, data in pairs(ps.uniqueIdToReplacedPlaceableData) do
                local placeable = data.placeable
                if placeable ~= nil and (placeable.spec_silo ~= nil or placeable.spec_husbandry ~= nil or placeable.spec_siloExtension ~= nil or placeable.spec_productionPoint ~= nil or placeable.spec_buyingStation ~= nil) then
                    g_slurryPipeManager:registerPlaceable(placeable)
                    g_slurryPipeManager:registerSprayerPlaceable(placeable)
                    if g_slurryPipeManager.registerLiquidLanePlaceable ~= nil then
                        g_slurryPipeManager:registerLiquidLanePlaceable(placeable)
                    end
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
    if g_spsLiquidLanePipeVisual ~= nil then
        g_spsLiquidLanePipeVisual:delete()
        g_spsLiquidLanePipeVisual = nil
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

    -- [SPS 1.0.1.8] drop the player-drawn water courses of this map (a joined client's set came from the host)
    if SPSWaterCourses ~= nil and SPSWaterCourses.reset ~= nil then
        SPSWaterCourses.reset()
    end

    -- Delete water plane manager
    if g_waterPlaneManager ~= nil then
        g_waterPlaneManager:delete()
        g_waterPlaneManager = nil
    end

    -- [SPS 1.0.1.8] unregister the console commands added in loadMap, so a second savegame load in the same game
    -- session re-adds them cleanly (the ones added at script load are left alone - they are only added once)
    if removeConsoleCommand ~= nil then
        removeConsoleCommand("spsPhysicalPipes")
        removeConsoleCommand("spsAgitatorDebug")
    end
    if SPSFixedAgitator ~= nil then
        SPSFixedAgitator._consoleRegistered = nil
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
    -- [SPS 1.0.0.9.29] Persist the dragged position / scrolled scale to the
    -- player's own user file (per-player HUD settings).
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.saveUserSettings ~= nil then
        g_slurryPipeManager:saveUserSettings()
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
        if g_slurryPipeManager.updateLiquidLanes ~= nil then
            g_slurryPipeManager:updateLiquidLanes(dt)
        end
    end
    -- [SPS 1.0.1.8] proof hoses follow their end nodes (no-op when none are laid)
    if g_spsHoseVisual ~= nil and g_spsHoseVisual.update ~= nil then
        g_spsHoseVisual:update(dt)
    end
    -- [SPS 1.0.1.8] pipe mode start-up choice (one-off per game, host only; no-op once answered)
    if SPSPipeModeDialog ~= nil then SPSPipeModeDialog.update(dt) end

    -- -----------------------------------------------------------------------
    -- [SPS 1.0.0.9.36] Drive-input watchdog. Background: vanilla's action
    -- event registration is order-fragile — checkEventCollision disables the
    -- NEWCOMER's colliding key binding, and the selected vehicle's pass calls
    -- resetActiveActionBindings() without replaying earlier conflicts, so
    -- with a multi-mod pass churn (Courseplay adds passes) the drive axes can
    -- end a G-press sequence registered but with dead bindings or inactive
    -- events: engine runs, no pedals, no errors. Intermittent by nature
    -- (depends on which vehicle's pass lands last), so this guard is
    -- ALWAYS ON, silent when healthy, and does two things when the broken
    -- signature is seen on the vehicle the player is sitting in:
    --   1. Prints an UNCONDITIONAL warning dump (the flight-recorder capture,
    --      no debug channel needed), and
    --   2. Self-heals with vehicle:requestActionEventUpdate() — a full
    --      vanilla re-registration, which reshuffles the order and in the
    --      observed cases restores the pedals.
    -- Safeguards: checks once per second; requires the broken signature on
    -- TWO consecutive checks (rules out mid-registration transients); only in
    -- the VEHICLE input context (menus/GUI switch context and would false-
    -- positive); only when entered, drivable, and not AI-driven; at most 3
    -- heal attempts per entered vehicle, counters reset on vehicle change or
    -- on a healthy check. All reads are proven InputBinding.lua APIs.
    -- -----------------------------------------------------------------------
    self.spsDriveWatchTimer = (self.spsDriveWatchTimer or 0) + dt
    if self.spsDriveWatchTimer >= 1000 then
        self.spsDriveWatchTimer = 0
        local vehicle = nil
        if g_inputBinding ~= nil and Vehicle ~= nil
           and g_inputBinding.currentContextName == Vehicle.INPUT_CONTEXT_NAME
           and g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
            vehicle = g_localPlayer:getCurrentVehicle()
        end
        if vehicle ~= self.spsDriveWatchVehicle then
            self.spsDriveWatchVehicle = vehicle
            self.spsDriveWatchStrikes = 0
            self.spsDriveWatchHeals   = 0
        end
        if vehicle ~= nil and vehicle.spec_drivable ~= nil
           and (vehicle.getIsAIActive == nil or not vehicle:getIsAIActive()) then
            local broken = false
            local detail = ""
            for _, axisName in ipairs({ "AXIS_ACCELERATE_VEHICLE", "AXIS_BRAKE_VEHICLE" }) do
                local action = g_inputBinding.nameActions[axisName]
                if action ~= nil then
                    local numEvents, numActiveEvents = 0, 0
                    local eventList = g_inputBinding.actionEvents[action]
                    if eventList ~= nil then
                        for _, ev in pairs(eventList) do
                            numEvents = numEvents + 1
                            if ev.isActive then numActiveEvents = numActiveEvents + 1 end
                        end
                    end
                    local numActiveBindings = nil
                    if action.getNumActiveBindings ~= nil then
                        numActiveBindings = action:getNumActiveBindings()
                    end
                    if numEvents == 0 or numActiveEvents == 0
                       or (numActiveBindings ~= nil and numActiveBindings == 0) then
                        broken = true
                    end
                    detail = detail .. string.format("%s[ev=%d act=%d bind=%s] ",
                        axisName, numEvents, numActiveEvents, tostring(numActiveBindings))
                end
            end
            if broken then
                self.spsDriveWatchStrikes = (self.spsDriveWatchStrikes or 0) + 1
                if self.spsDriveWatchStrikes >= 2 and (self.spsDriveWatchHeals or 0) < 3 then
                    self.spsDriveWatchHeals   = (self.spsDriveWatchHeals or 0) + 1
                    self.spsDriveWatchStrikes = 0
                    print(string.format(
                        "[SPS] WARNING: drive-input watchdog: broken drive axes on '%s' — %s— requesting re-registration (attempt %d/3)",
                        tostring(vehicle.configFileName), detail, self.spsDriveWatchHeals))
                    if vehicle.requestActionEventUpdate ~= nil then
                        vehicle:requestActionEventUpdate()
                    end
                end
            else
                self.spsDriveWatchStrikes = 0
                self.spsDriveWatchHeals   = 0
            end
        end
    end
    
    -- Deferred water plane loading (wait for terrain to be ready)
    if g_waterPlaneManager ~= nil and not g_waterPlaneManager.planesLoaded then
        if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
            spsInfo("[SPS INIT] Terrain ready, loading water planes now")
            g_waterPlaneManager:loadWaterPlanes()
            g_waterPlaneManager.planesLoaded = true
            -- [SPS 1.0.1.8] player-drawn water courses of this map (per-PC file), added on top
            if SPSWaterCourses ~= nil then SPSWaterCourses.loadForMap() end
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

    -- Sprayer SOURCE registration (IBC liquid tanks: passive source drawing from
    -- the tank's own fill unit; independent of the slurry and active-sprayer paths)
    local sprayerSourceConfig = g_slurryPipeManager:findSprayerSourceVehicleConfigForVehicle(self)
    if sprayerSourceConfig ~= nil then
        g_slurryPipeManager:registerSprayerSourceVehicle(self)
    end

    -- [SPS 1.0.1.8] Farm liquid carrier (water in / milk out; independent of the other two;
    -- a water trailer is usually neither slurry- nor sprayer-registered)
    if g_slurryPipeManager.findLiquidLaneVehicleConfigForVehicle ~= nil
    and g_slurryPipeManager:findLiquidLaneVehicleConfigForVehicle(self) ~= nil then
        g_slurryPipeManager:registerLiquidLaneVehicle(self)
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
-- [SPS 1.0.0.9.33] Slurry cab-control registration, root-driven.
-- spsStripVanillaTurnOn: remove the vanilla spec_turnOnVehicle event so the
-- pump key doesn't appear twice and a non-chosen SPS vehicle can never
-- shadow-toggle its pump through the vanilla action.
-- spsRegisterSlurryControlsFor: the former per-vehicle slurry block, with
-- `registrar` (the root, whose action-event pass is running) registering events
-- that TARGET `vehicle`; all state reads and the spsActionEvents store are on
-- the target so SPSM_Flow's action-text updates keep working unchanged.
-- ---------------------------------------------------------------------------
local function spsStripVanillaTurnOn(vehicle)
    local specTOV = vehicle.spec_turnOnVehicle
    if specTOV ~= nil and specTOV.actionEvents ~= nil and specTOV.toggleTurnOnInputBinding ~= nil then
        local vanillaEvent = specTOV.actionEvents[specTOV.toggleTurnOnInputBinding]
        if vanillaEvent ~= nil then
            g_inputBinding:removeActionEvent(vanillaEvent.actionEventId)
            specTOV.actionEvents[specTOV.toggleTurnOnInputBinding] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Key trace (console: spsDebug Init.Keys on). Prints every SPS
-- cab-control registration pass on the root, and — the part no registration
-- log can show — WHO removes an SPS_ event afterwards: every removal in the
-- engine funnels through InputBinding:removeEventInternal (removeActionEvent,
-- removeActionEventsByTarget, clearActionEventsTable all end there, verified
-- InputBinding.lua:702/714/741), so one wrapper with a callstack names the
-- caller (vanilla eviction in Vehicle:addActionEvent, AttacherJoints
-- removeActionEvents on requestActionEventUpdate, a mod, ...). Zero cost when
-- the channel is off beyond one table read per removal.
-- ---------------------------------------------------------------------------
local function spsKeysOn()
    return SPSDebugConfig ~= nil and SPSDebugConfig.isOn ~= nil and SPSDebugConfig.isOn("Init.Keys")
end
local function spsKeysLog(fmt, ...)
    if spsKeysOn() then print("[SPS KEYS] " .. string.format(fmt, ...)) end
end
if InputBinding ~= nil and InputBinding.removeEventInternal ~= nil and not InputBinding._spsKeysTraced then
    InputBinding._spsKeysTraced = true
    local origRemoveEventInternal = InputBinding.removeEventInternal
    function InputBinding:removeEventInternal(event, eventList, index)
        if event ~= nil and spsKeysOn() then
            local an = tostring(event.actionName)
            if an:sub(1, 4) == "SPS_" then
                local tgt = event.targetObject
                print(string.format("[SPS KEYS] REMOVE %s id=%s target=%s  (callstack follows)",
                    an, tostring(event.id),
                    tostring(tgt ~= nil and tgt.configFileName or tgt)))
                if printCallstack ~= nil then printCallstack() end
            end
        end
        return origRemoveEventInternal(self, event, eventList, index)
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] spsAddControl: addActionEvent with a diagnosable failure.
-- Vehicle:addActionEvent returns state=false and eventId "" (an EMPTY STRING,
-- not nil) both when the same action is already registered for this target
-- (vanilla's duplicate pass in one tick) and when the key collides with an
-- ACTIVE action of the same category (checkEventCollision, the profile binds
-- the same key to both). The old `if id ~= nil` test treated "" as success, so a
-- dropped SPS key was stored as a dead id and nothing was logged. Now: a
-- duplicate reuses the live event id (texts keep updating); a collision prints
-- ONE warning naming the clashing action and returns nil.
-- ---------------------------------------------------------------------------
local function spsAddControl(registrar, events, action, target, callback, triggerUp, triggerDown, triggerAlways, startActive, callbackState)
    local ok, id = registrar:addActionEvent(events, action, target, callback,
        triggerUp, triggerDown, triggerAlways, startActive, callbackState)
    if ok and id ~= nil and id ~= "" then
        spsKeysLog("registered %s id=%s target=%s registrar=%s", tostring(action), tostring(id),
            tostring(target and target.configFileName), tostring(registrar and registrar.configFileName))
        return id
    end
    spsKeysLog("addActionEvent refused %s for %s (state=%s id=%s)", tostring(action),
        tostring(target and target.configFileName), tostring(ok), tostring(id))
    local actionObj = g_inputBinding.nameActions[action]
    local list = actionObj ~= nil and g_inputBinding.actionEvents[actionObj] or nil
    if list ~= nil then
        for _, ev in ipairs(list) do
            if ev.targetObject == target then return ev.id end
        end
    end
    local collides, other = g_inputBinding:checkEventCollision(action, false)
    local otherName = other ~= nil and other.name or (collides and "?" or "none found")
    print(string.format("[SPS] WARNING: control '%s' NOT registered on '%s' - key collision with active action '%s' (both bound to the same key in this input profile). Rebind one of them in Options > Controls.",
        tostring(action), tostring(target and target.configFileName), tostring(otherName)))
    return nil
end

local function spsRegisterSlurryControlsFor(registrar, vehicle)
    local isSelfPowered = g_slurryPipeManager:isVehicleSelfPowered(vehicle)
    local spsEvents   = {}
    local pumpEventId = nil
    local flowEventId = nil

    local hasSpreader = g_slurryPipeManager:vehicleHasSpreader(vehicle)

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
    local pid = spsAddControl(registrar,
        spsEvents, InputAction.SPS_TOGGLE_PUMP, vehicle,
        pumpCallback, false, true, false, true, nil)
    if pid ~= nil then
        local state = g_slurryPipeManager:getVehicleState(vehicle)
        local pumpOn = hasSpreader and (state and state.pumpRunning == true) or vehicle:getIsTurnedOn()
        -- HVP tankers drive a high-volume pump rather than building tank vacuum, so the
        -- prompt names the HVP; vacuum/conduit keep the existing pump wording.
        local pumpType = g_slurryPipeManager:getPumpType(vehicle)
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
    local hudEditId = spsAddControl(registrar,
        spsEvents, InputAction.SPS_HUD_EDIT, vehicle,
        function(vehicle, actionName, inputValue, callbackState, isAnalog)
            SPSMod:enterHudEdit()
        end,
        false, true, false, true, nil)
    if hudEditId ~= nil then
        g_inputBinding:setActionEventText(hudEditId, g_i18n:getText("action_spsHudEdit"))
        g_inputBinding:setActionEventTextPriority(hudEditId, GS_PRIO_LOW)
    end
    if g_slurryPipeManager:vehicleHasFillArms(vehicle) or g_slurryPipeManager:isVehicleConduit(vehicle) then
        local id = spsAddControl(registrar,
            spsEvents,
            InputAction.SPS_TOGGLE_FLOW,
            vehicle,
            function(vehicle, actionName, inputValue, callbackState, isAnalog)
                if g_slurryPipeManager ~= nil then
                    g_slurryPipeManager:onActionToggleFlow(vehicle)
                end
            end,
            false, true, false, true, nil
        )
        if id ~= nil then
            local state   = g_slurryPipeManager:getVehicleState(vehicle)
            local isConduit    = g_slurryPipeManager:isVehicleConduit(vehicle)
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
    if not (g_slurryPipeManager ~= nil and g_slurryPipeManager:vehicleHasOutsideDirectionControl(vehicle)) then
        local dirId = spsAddControl(registrar,
            spsEvents,
            InputAction.SPS_TOGGLE_DIRECTION,
            vehicle,
            function(vehicle, actionName, inputValue, callbackState, isAnalog)
                if g_slurryPipeManager ~= nil then
                    g_slurryPipeManager:onActionToggleDirection(vehicle)
                end
            end,
            false, true, false, true, nil
        )
        if dirId ~= nil then
            local state = g_slurryPipeManager:getVehicleState(vehicle)
            local isConduit = g_slurryPipeManager:isVehicleConduit(vehicle)
            local pumpType  = g_slurryPipeManager:getPumpType(vehicle)
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

    -- SPS_TOGGLE_SPREADER: only for vehicles with a spreader (spec_dischargeable).
    -- [SPS 1.0.0.9.37] Front mounts are excluded: they are manureBarrel-typed
    -- (so vehicleHasSpreader passes) but are pump/arm units, never spreaders —
    -- the valve toggle must not appear on them (SPSM_FrontMount 1.0.0.6+).
    local spreaderEventId = nil
    if g_slurryPipeManager:vehicleHasSpreader(vehicle)
       and not (g_slurryPipeManager.isFrontMountVehicle ~= nil
                and g_slurryPipeManager:isFrontMountVehicle(vehicle)) then
        local sid = spsAddControl(registrar,
            spsEvents,
            InputAction.SPS_TOGGLE_SPREADER,
            vehicle,
            function(vehicle, actionName, inputValue, callbackState, isAnalog)
                if g_slurryPipeManager ~= nil then
                    g_slurryPipeManager:onActionToggleSpreader(vehicle)
                end
            end,
            false, true, false, true, nil
        )
        if sid ~= nil then
            local state = g_slurryPipeManager:getVehicleState(vehicle)
            local spreaderTxt = (state and state.spreaderValveOpen)
                and g_i18n:getText("action_spsSpreaderClose")
                or  g_i18n:getText("action_spsSpreaderOpen")
            g_inputBinding:setActionEventText(sid, spreaderTxt)
            g_inputBinding:setActionEventTextPriority(sid, GS_PRIO_VERY_HIGH)
            spreaderEventId = sid
        end
    end

    vehicle.spsActionEvents = { pumpEventId = pumpEventId, flowEventId = flowEventId, dirEventId = dirEventId, spreaderEventId = spreaderEventId }
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

    -- -----------------------------------------------------------------------
    -- [SPS 1.0.1.8] Mirror vanilla's early-out. Vehicle:registerActionEvents
    -- (Vehicle.lua:2059) does NOTHING while a GUI is visible, the player is
    -- frozen, or this vehicle is the excluded one: no actionEventUpdateRequested
    -- reset, no beginActionEventsModification(VEHICLE). Everything below used to
    -- run anyway, so with a dialog open (EasyDevControls teleport, 2026-09-25
    -- 14:03:02) the SPS keys were registered straight into the CURRENT context —
    -- MENU — as second event objects carrying the SAME id strings as the live
    -- VEHICLE ones (InputEvent:makeId = action|target|trigger). g_inputBinding.
    -- events[id] then pointed at the MENU copy, every setActionEventText went
    -- there, and the F1 box kept drawing the untouched VEHICLE copy until a
    -- re-enter recreated the context. Vanilla also re-requests the update every
    -- frame in that state (flag never cleared), which is why the trace showed a
    -- root pass per frame while the dialog was open. Now SPS is a no-op there too.
    -- -----------------------------------------------------------------------
    if (g_gui ~= nil and g_gui:getIsGuiVisible())
    or (g_currentMission ~= nil and g_currentMission.isPlayerFrozen)
    or excludedVehicle == self then
        if self._spsRegSkipLogged ~= true then
            self._spsRegSkipLogged = true
            spsKeysLog("registerActionEvents %s: skipped like vanilla (guiVisible=%s playerFrozen=%s excluded=%s ctx=%s)",
                tostring(self.configFileName),
                tostring(g_gui ~= nil and g_gui:getIsGuiVisible()),
                tostring(g_currentMission ~= nil and g_currentMission.isPlayerFrozen),
                tostring(excludedVehicle == self),
                tostring(g_inputBinding and g_inputBinding.currentContextName))
        end
        return
    end
    self._spsRegSkipLogged = nil

    -- -----------------------------------------------------------------------
    -- [SPS 1.0.0.9.35 DIAG] Drive-guard trace. Vanilla Drivable registers the
    -- accelerate/brake/steer axes ONLY when, on the tractor's pass:
    --     getIsActiveForInput(true, true) AND entered AND not getIsAIActive()
    -- (Drivable.lua:787-800). This prints all three per registration pass so
    -- the guard that wrongly fails under Courseplay names itself. Channel-
    -- gated: `spsDebug SPSM_FrontMount on`. Runs before the SPS guards below
    -- so EVERY vehicle's pass traces, not only SPS-registered ones.
    -- -----------------------------------------------------------------------
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn ~= nil and SPSDebugConfig.isOn("SPSM_FrontMount") then
        local aiActive = "n/a"
        if self.getIsAIActive ~= nil then aiActive = tostring(self:getIsAIActive()) end
        local afi = "n/a"
        if self.getIsActiveForInput ~= nil then afi = tostring(self:getIsActiveForInput(true, true)) end
        local entered = "n/a"
        if self.getIsEntered ~= nil then entered = tostring(self:getIsEntered()) end
        local sel = "nil"
        local root = self.rootVehicle
        if root ~= nil and root.getSelectedVehicle ~= nil then
            local sv = root:getSelectedVehicle()
            if sv ~= nil then sel = tostring(sv.configFileName) end
        end
        print(string.format("[SPS DIAG] regAE veh=%s isRoot=%s aiActive=%s activeForInput(t,t)=%s entered=%s selected=%s",
            tostring(self.configFileName), tostring(self == self.rootVehicle),
            aiActive, afi, entered, sel))
        -- [SPS 1.0.0.9.35 DIAG2] Binding scoreboard for the drive axes. All
        -- APIs proven in InputBinding.lua: nameActions, actionEvents[action],
        -- event.isActive/targetObject, action:getBindings(),
        -- action:getNumActiveBindings(). Registration is fine per DIAG, so
        -- this shows whether the EVENTS stay active and whether the KEY
        -- BINDINGS survive conflict-disabling (checkEventCollision disables
        -- the newcomer's colliding binding; resetActiveActionBindings
        -- re-enables all without replaying past conflicts).
        for _, axisName in ipairs({ "AXIS_ACCELERATE_VEHICLE", "AXIS_BRAKE_VEHICLE" }) do
            local action = g_inputBinding.nameActions[axisName]
            if action ~= nil then
                local numEvents, numActiveEvents, targets = 0, 0, ""
                local eventList = g_inputBinding.actionEvents[action]
                if eventList ~= nil then
                    for _, ev in pairs(eventList) do
                        numEvents = numEvents + 1
                        if ev.isActive then numActiveEvents = numActiveEvents + 1 end
                        local tgt = "?"
                        if ev.targetObject ~= nil and ev.targetObject.configFileName ~= nil then
                            tgt = tostring(ev.targetObject.configFileName):match("([^/]+)%.xml$") or "?"
                        end
                        targets = targets .. tgt .. (ev.isActive and "(on) " or "(OFF) ")
                    end
                end
                local numBindings = 0
                if action.getBindings ~= nil then
                    for _ in pairs(action:getBindings()) do numBindings = numBindings + 1 end
                end
                local numActiveBindings = "?"
                if action.getNumActiveBindings ~= nil then
                    numActiveBindings = tostring(action:getNumActiveBindings())
                end
                print(string.format("[SPS DIAG2] %s events=%d activeEvents=%d bindings=%d activeBindings=%s targets=%s",
                    axisName, numEvents, numActiveEvents, numBindings, numActiveBindings, targets))
            end
        end
    end

    if g_slurryPipeManager == nil then return end
    if not self.isClient then return end
    if not self:getIsActiveForInput(true) then return end

    -- ---------------------------------------------------------------------------
    -- [SPS] Fixed-agitator cab action ("Connect PTO" on the range key, plus the
    -- PTO engage toggle). Must run BEFORE the sprayer/slurry early-returns below:
    -- a plain tractor lining up to a placeable agitator is NOT an SPS slurry
    -- vehicle, so those returns would skip it. registerCabActionEvent self-gates
    -- to vehicles that actually expose a rear PTO output (no PTO output => no-op),
    -- so this is harmless on every other vehicle. The same-tick guard prevents the
    -- duplicate registrations FS25 issues per context switch (mirrors the
    -- _spsRegisterTime idiom used for the slurry block). The prompt is shown/hidden
    -- by range each tick inside SPSFixedAgitator.updateAll via _spsAgitatorEventId.
    -- ---------------------------------------------------------------------------
    if SPSFixedAgitator ~= nil and SPSFixedAgitator.registerCabActionEvent ~= nil then
        local nowT = g_currentMission and g_currentMission.time or 0
        if self._spsAgitatorRegisterTime ~= nowT then
            self._spsAgitatorRegisterTime = nowT
            SPSFixedAgitator.registerCabActionEvent(self)
        end
    end

    -- ---------------------------------------------------------------------------
    -- SPRAYER safety net: if any R/I events slipped past the type-level override,
    -- remove them here. Uses findSprayerVehicleConfigForVehicle (needs only
    -- configFileName) so it works regardless of registration timing.
    -- ---------------------------------------------------------------------------
    if g_slurryPipeManager:isSprayerVehicleRegistered(self)
    or g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil then
        sprayTrace("registerActionEvents[%s] sprayer cab pass: registered=%s hasConfig=%s hasTurnOnSpec=%s cover=%s",
            tostring(self.configFileName),
            tostring(g_slurryPipeManager:isSprayerVehicleRegistered(self)),
            tostring(g_slurryPipeManager:findSprayerVehicleConfigForVehicle(self) ~= nil),
            tostring(self.spec_turnOnVehicle ~= nil),
            tostring(self.spec_cover ~= nil and self.spec_cover.state or "no-cover"))
        local specD = self.spec_dischargeable
        if specD ~= nil and specD.actionEvents ~= nil then
            local evTip = specD.actionEvents[InputAction.TOGGLE_TIPSTATE]
            if evTip ~= nil then
                g_inputBinding:removeActionEvent(evTip.actionEventId)
                specD.actionEvents[InputAction.TOGGLE_TIPSTATE] = nil
                sprayTrace("[SPS INIT] sprayer cab: removed TOGGLE_TIPSTATE (I)")
            end
            local evGround = specD.actionEvents[InputAction.TOGGLE_TIPSTATE_GROUND]
            if evGround ~= nil then
                g_inputBinding:removeActionEvent(evGround.actionEventId)
                specD.actionEvents[InputAction.TOGGLE_TIPSTATE_GROUND] = nil
                sprayTrace("[SPS INIT] sprayer cab: removed TOGGLE_TIPSTATE_GROUND (R)")
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
                sprayTrace("[SPS INIT] sprayer cab: removed UNLOAD (I — pallet spawn)")
            end
        end
    end

    -- ---------------------------------------------------------------------------
    -- SLURRY block — ROOT-DRIVEN as of 1.0.0.9.33.
    --
    -- Vanilla invokes per-implement registerActionEvents down the SELECTED
    -- implement's attacher chain, so a SIBLING implement's pass never runs while
    -- the other sibling is selected. Field case: Saddle Trac back tank on the
    -- module joint + dribble bar on the rear joint of the same tractor — the tank
    -- was uncontrollable with the DB selected and vice versa. The ROOT's pass
    -- runs in EVERY selection state, so the root now registers the SPS control
    -- set for the chosen SPS vehicle under it, and non-root passes skip the
    -- slurry block entirely.
    --
    -- Choice rule: with exactly one SPS-controllable vehicle under the root
    -- (every previously working setup) behaviour is unchanged. With two or more
    -- (e.g. front mount + tanker) the G-selected one owns the controls; if none
    -- is selected, the first in chain order does. Selection changes re-run this
    -- pass via vanilla, so the controls follow G live. Vanilla turn-on (B) is
    -- stripped from EVERY candidate, chosen or not.
    -- ---------------------------------------------------------------------------
    if self ~= self.rootVehicle then return end

    local candidates = {}
    local chain = (self.getChildVehicles ~= nil and self:getChildVehicles()) or { self }
    for _, v in ipairs(chain) do
        if g_slurryPipeManager:isRegistered(v)
           and not g_slurryPipeManager:isSpreaderImplement(v)
           and g_slurryPipeManager:findSprayerVehicleConfigForVehicle(v) == nil
           and v.spec_turnOnVehicle ~= nil
           and not g_slurryPipeManager:isVehicleAgitatorOnly(v) then
            table.insert(candidates, v)
        end
    end
    if #candidates == 0 then
        spsKeysLog("root pass %s: no SPS candidates in chain", tostring(self.configFileName))
        return
    end

    local target = candidates[1]
    if #candidates > 1 then
        for _, v in ipairs(candidates) do
            if v.getIsSelected ~= nil and v:getIsSelected() then
                target = v
                break
            end
        end
    end

    -- Prevent double-registration within the same frame (FS25 calls
    -- registerActionEvents multiple times per context switch). Keyed on the
    -- ROOT: it is the sole registrar now.
    -- [SPS 1.0.1.8] Keyed on g_updateLoopIndex (engine frame counter, vanilla
    -- AnimationManager.lua:101/201), NOT g_currentMission.time: mission time only
    -- advances while the mission isRunning (BaseMission.lua:800-809, set true only
    -- in doUnpauseGame), so it is frozen for the whole savegame load (the player is
    -- put in the spawn vehicle in Player:onStartMission, before the unpause) and in
    -- every pause menu. Every pass in those windows shared "time 0" and was skipped
    -- here AFTER vanilla's requestActionEventUpdate had already removed the SPS
    -- events (removeActionEventsByTarget, callstack in log 2026-09-25 13:06:19) —
    -- dead ids, F1 rows frozen, vanilla turn-on back on B. Belt and braces: even in
    -- the same frame, never skip when the stored events are no longer live (a
    -- duplicate pass with live events is refused by vanilla anyway and
    -- spsAddControl reuses the live id).
    local frame = g_updateLoopIndex or (g_currentMission and g_currentMission.time) or 0
    if self._spsRegisterFrame == frame then
        local ev = target.spsActionEvents
        local pumpLive = ev ~= nil and ev.pumpEventId ~= nil and g_inputBinding ~= nil
                         and g_inputBinding.events[ev.pumpEventId] ~= nil
        if pumpLive then
            if spsKeysOn() then
                local live = string.format("pump=%s flow=%s dir=%s",
                    tostring(ev.pumpEventId ~= nil and g_inputBinding.events[ev.pumpEventId] ~= nil),
                    tostring(ev.flowEventId ~= nil and g_inputBinding.events[ev.flowEventId] ~= nil),
                    tostring(ev.dirEventId  ~= nil and g_inputBinding.events[ev.dirEventId]  ~= nil))
                spsKeysLog("root pass %s SKIPPED (same-frame guard, frame=%s) target=%s liveEvents[%s]",
                    tostring(self.configFileName), tostring(frame), tostring(target.configFileName), live)
            end
            return
        end
        spsKeysLog("root pass %s same frame %s but SPS events dead - re-registering",
            tostring(self.configFileName), tostring(frame))
    end
    self._spsRegisterFrame = frame
    if spsKeysOn() then
        local sel = "nil"
        if self.getSelectedVehicle ~= nil and self:getSelectedVehicle() ~= nil then
            sel = tostring(self:getSelectedVehicle().configFileName)
        end
        spsKeysLog("root pass %s: candidates=%d target=%s selected=%s context=%s frame=%s missionTime=%s running=%s",
            tostring(self.configFileName), #candidates, tostring(target.configFileName), sel,
            tostring(g_inputBinding and g_inputBinding.currentContextName), tostring(frame),
            tostring(g_currentMission and g_currentMission.time),
            tostring(g_currentMission and g_currentMission.isRunning))
    end

    for _, v in ipairs(candidates) do
        v.spsActionEvents = nil   -- clear so re-registration always gets fresh events
        spsStripVanillaTurnOn(v)
    end

    spsRegisterSlurryControlsFor(self, target)
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
        if g_slurryPipeManager.isLiquidLaneVehicleRegistered ~= nil
        and g_slurryPipeManager:isLiquidLaneVehicleRegistered(self) then
            g_slurryPipeManager:unregisterLiquidLaneVehicle(self)
        end
        -- IBC source entries live in registeredSprayerPlaceables (object-keyed);
        -- this is a no-op scan for non-IBC vehicles.
        g_slurryPipeManager:unregisterSprayerPlaceable(self)
    end
    if origVehicleDelete ~= nil then
        origVehicleDelete(self, immediate)
    end
end

-- ---------------------------------------------------------------------------
-- Placeable hooks
-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Build-menu preview: dress it like the placed building (SPS nodes
-- linked, base parts hidden) — visual only, see SPSM_Preview.lua.
local origPlaceableOnFinishedLoading = Placeable.onFinishedLoading
function Placeable:onFinishedLoading(...)
    if origPlaceableOnFinishedLoading ~= nil then
        origPlaceableOnFinishedLoading(self, ...)
    end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.applyPlaceablePreviewVisuals ~= nil
    and PlaceablePropertyState ~= nil and self.propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW then
        local ok, err = pcall(g_slurryPipeManager.applyPlaceablePreviewVisuals, g_slurryPipeManager, self)
        if not ok then
            print("[SPS PREVIEW] error dressing preview of " .. tostring(self.configFileName) .. ": " .. tostring(err))
        end
    end
end

local origPlaceableFinalize = Placeable.finalizePlacement
function Placeable:finalizePlacement()
    if origPlaceableFinalize ~= nil then
        origPlaceableFinalize(self)
    end
    -- [SPS FLOOR 1.0.1.8] A placeable's collision just entered physics: let every
    -- hose and locked chain segment re-probe its floor for a while, so pipes that
    -- were shaped before this pad/building existed (load order, or a pad placed
    -- under a parked hose) climb onto it instead of staying sunk.
    if SPSPipeVisual ~= nil and SPSPipeVisual.bumpFloorEpoch ~= nil then SPSPipeVisual.bumpFloorEpoch() end
    if SPSHoseVisual ~= nil and SPSHoseVisual.bumpFloorEpoch ~= nil then SPSHoseVisual.bumpFloorEpoch() end
    if SPSSprayerPipeVisual ~= nil and SPSSprayerPipeVisual.bumpFloorEpoch ~= nil then SPSSprayerPipeVisual.bumpFloorEpoch() end
    if SPSPipeChain ~= nil and SPSPipeChain.bumpFloorEpoch ~= nil then SPSPipeChain.bumpFloorEpoch() end
    if g_slurryPipeManager ~= nil and (self.spec_silo ~= nil or self.spec_husbandry ~= nil or self.spec_siloExtension ~= nil or self.spec_productionPoint ~= nil or self.spec_buyingStation ~= nil) then
        -- Avoid double-registration for placeables already registered in loadMap
        if g_slurryPipeManager:getPlaceableEntry(self) == nil then
            g_slurryPipeManager:registerPlaceable(self)
        end
        if g_slurryPipeManager:getSprayerPlaceableEntry(self) == nil then
            g_slurryPipeManager:registerSprayerPlaceable(self)
        end
        if g_slurryPipeManager.registerLiquidLanePlaceable ~= nil
        and g_slurryPipeManager:getLiquidLanePlaceableEntry(self) == nil then
            g_slurryPipeManager:registerLiquidLanePlaceable(self)
        end
    end
end

local origPlaceableDelete = Placeable.delete
function Placeable:delete(immediate)
    if g_slurryPipeManager ~= nil and (self.spec_silo ~= nil or self.spec_husbandry ~= nil or self.spec_siloExtension ~= nil or self.spec_productionPoint ~= nil or self.spec_buyingStation ~= nil) then
        g_slurryPipeManager:unregisterPlaceable(self)
        g_slurryPipeManager:unregisterSprayerPlaceable(self)
        if g_slurryPipeManager.unregisterLiquidLanePlaceable ~= nil then
            g_slurryPipeManager:unregisterLiquidLanePlaceable(self)
        end
    end
    if origPlaceableDelete ~= nil then
        origPlaceableDelete(self, immediate)
    end
end

-- ---------------------------------------------------------------------------
-- [SPS] Central debug registry sync. init.lua is the LAST sourceFile in
-- modDesc, so every SPS class exists by the time this runs. Pushes the
-- SPSDebugConfig channel values into the class-field debug switches
-- (SlurryPipeManager.DEBUG / MP_DEBUG / SPRAYER_TRACE, SPSPipeChain.DEBUG,
-- SlurryDebug.enabled, etc.). See scripts/SPSDebugConfig.lua.
-- ---------------------------------------------------------------------------
if SPSDebugConfig ~= nil and SPSDebugConfig.applyAll ~= nil then
    SPSDebugConfig.applyAll()
    spsInfo("[SPS INIT] SPSDebugConfig.applyAll — debug channels synced")
else
    print("[SPS INIT] WARNING: SPSDebugConfig not loaded — debug channels not synced")
end
