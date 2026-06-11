-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.0

-- SlurryPipeManager.lua
-- FS25_SlurryPipeSystem

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

SPS_DIRECTION_FILL      = 0
SPS_DIRECTION_DISCHARGE = 1

SPS_SPRAYER_DIRECTION_FILL      = 0
SPS_SPRAYER_DIRECTION_DISCHARGE = 1

SPS_TIP_TYPE_OPEN_PIT        = "OPEN_PIT"
SPS_TIP_TYPE_RUBBER_BOOT     = "RUBBER_BOOT"
SPS_TIP_TYPE_RUBBER_BOOT_PIT = "RUBBER_BOOT_PIT"

SPS_VALVE_TYPE_HYDRAULIC = "HYDRAULIC"
SPS_VALVE_TYPE_MANUAL    = "MANUAL"
SPS_VALVE_TYPE_NONE      = "NONE"

SPS_MAX_CONNECT_DIST    = 5.9   -- max distance (m) at which two couplers can connect
SPS_AUTODISCONNECT_DIST = 6.0   -- distance (m) at which a connected pipe auto-disconnects

SlurryPipeManager = {}
local SlurryPipeManager_mt = Class(SlurryPipeManager)

SlurryPipeManager.FILL_VOLUME_SEARCH_RADIUS = 3.0   -- XZ radius for vehicle fill volume (nurse tank) detection only
SlurryPipeManager.DEFAULT_LITERS_PER_SECOND = 1000

-- Pressure system defaults (overridable per-vehicle via <pressure> in fillPoints.xml).
-- All bar values; build/fall/purge times in seconds.
SlurryPipeManager.DEFAULT_MAX_PRESSURE      = 2.0   -- ±bar ceiling
SlurryPipeManager.DEFAULT_MIN_THRESHOLD     = 0.3   -- bar required before flow can start (consumed in Phase 3)
SlurryPipeManager.DEFAULT_MIN_BUILD_TIME    = 10    -- sec to reach max at a full tank
SlurryPipeManager.DEFAULT_MAX_BUILD_TIME    = 30    -- sec to reach max at an empty tank
SlurryPipeManager.DEFAULT_FALL_TIME_WORKING = 60    -- sec max->0 while fluid is transferring (slow)
SlurryPipeManager.DEFAULT_FALL_TIME_EMPTY   = 30    -- sec max->0 while venting, no transfer (fast)
SlurryPipeManager.DEFAULT_PURGE_TIME        = 10    -- sec to vent from max to 0 on direction flip
SlurryPipeManager.DEFAULT_GRAVITY_FLOW_SCALAR = 0.5 -- backflow/gravity rate as a fraction of base flow when pressure is spent
SlurryPipeManager.DEFAULT_LENGTH_FALLOFF_FLOOR = 0.5 -- min flow fraction at full strap-pipe stretch (1.0 = no falloff)
SlurryPipeManager.BLOCKAGE_CRUST_MIN        = 0.3   -- tanker-carried crust below which only the base (foreign-object) chance applies
SlurryPipeManager.BLOCKAGE_BASE_CHANCE      = 0.0015-- per-outlet random clog chance even on clean slurry (wood/debris/foreign object)
SlurryPipeManager.BLOCKAGE_DM_BONUS         = 0.5   -- extra blockage multiplier at the jam point (thick + crusted is worst); 0 = DM has no effect
SlurryPipeManager.SETTLE_YEARS_TO_FULL      = 1.0   -- game years of no mixing for crust to grow 0 -> 100% (grows every in-game day)
-- Two-pool slurry model. A store tracks litres of dry matter (solids); liquid is the
-- live (totalFill - solids). The true dry-matter fraction DM = solids/total is mapped
-- onto the 0..1 player-facing thickness gauge: DM_FRESH reads 0%, DM_JAMMED reads 100%.
-- Mixing can only ever bring the gauge down to the DM-derived value (settling removed);
-- if DM itself is past the jam point the only remedy is adding water.
SlurryPipeManager.DM_FRESH                  = 0.06  -- dry-matter fraction shown as 0% on the gauge
SlurryPipeManager.DM_JAMMED                 = 0.15  -- dry-matter fraction shown as 100% (un-pumpable even fully mixed)
SlurryPipeManager.DM_REMOVAL_LIQUID_BIAS    = 1.6   -- liquid leaves at this multiple of its share (>1 = liquid pulled first)
SlurryPipeManager.WARNING_RANGE             = 15    -- metres: blinking flow warnings only show when in-cab or this close on foot
SlurryPipeManager.BLOCKAGE_OUTLET_CHANCE    = 0.04
SlurryPipeManager.BLOCKAGE_MACERATOR_CHANCE = 0.01
SlurryPipeManager.BLOCKAGE_ROLL_INTERVAL    = 2000
SlurryPipeManager.BLOCKAGE_CLEAR_RADIUS     = 0.5

-- Module-level node search — finds all nodes named 'name' under root.
-- Used by registerVehicle and registerPlaceable.
local function spsFindAllInTree(root, name, results)
    local stack = { root }
    while #stack > 0 do
        local node = table.remove(stack)
        if getName(node) == name then
            table.insert(results, node)
        end
        for i = 0, getNumOfChildren(node) - 1 do
            table.insert(stack, getChildAt(node, i))
        end
    end
end

function SlurryPipeManager.new()
    local self = setmetatable({}, SlurryPipeManager_mt)
    self.registeredVehicles    = {}
    self.registeredPlaceables  = {}
    self.sourceEntries         = {}
    self.activeFlows           = {}
    self.rubberBootPortEntries = {}
    self.vehicleConfigMap      = {}
    self.placeableConfigMap    = {}
    self.activePipes           = {}   -- pipeId -> { inst, couplingA, couplingB }
    self._nextPipeId           = 1
    self.pendingConnections    = {}   -- saved connections waiting for both couplings to register
    self.pipeChains            = {}   -- active SPSPipeChain instances
    self.chainTerminusEntries  = {}   -- chain end arcs checked in findOverlappingCoupler
    self.pendingChains              = {}   -- saved chain data waiting for anchor coupling to register
    self.pendingDeployedCouplings   = {}   -- saved deployed couplings waiting for placeable to register
    self._pendingCouplerAnims       = {}   -- saved coupler animation states waiting to be applied
    self.pipeColors                 = {}   -- {name, r, g, b} loaded from spsColors.xml
    self.currentPipeColorIndex      = 1
    self.currentPipeColor           = { r = 0, g = 0.05, b = 0 }  -- default green until XML loads
    -- Realism settings. realismEnabled is the master: OFF disables ALL of the
    -- below (thickness, crust, blockages, length falloff). featureToggles are the
    -- optional sub-settings, only meaningful while the master is on; each defaults
    -- ON. Store thickening and crust are mandatory (no toggle) so they aren't keyed
    -- here — they ride the master directly. Always gate features via
    -- isFeatureEnabled() rather than reading these fields directly.
    self.realismEnabled             = true
    self.featureToggles = {
        thicknessFlow = true,   -- thick slurry slows fill / discharge / spread
        blockages     = true,   -- spread blockage system (Pass 2)
        lengthFalloff = true,   -- flow drop over strap-pipe length
    }
    -- Spreader HUD (top-centre DB readout) — player-configurable, persisted per savegame.
    -- posX/posY nil => centred at top until the player drags it.
    self.hudSettings = {
        enabled = true, image = true,
        fill = true, crust = true, thick = true, risk = true, pump = true,
        scale = 1.0, posX = nil, posY = nil,
    }
    self._lastMonotonicDay          = nil  -- tracked to detect day transitions
    -- Sprayer system tables (herbicide / fertiliser, bez pipe only)
    self.registeredSprayerVehicles    = {}
    self.registeredSprayerPlaceables  = {}
    self.activeSprayerFlows           = {}
    self.activeSprayerPipes           = {}
    self._nextSprayerPipeId           = 1
    self.sprayerVehicleConfigMap      = {}
    self.sprayerPlaceableConfigMap    = {}
    self._sprayerDistCheckTick        = 0
    self._pendingSprayerAnimations    = {}  -- saved animation states waiting to be applied
    SlurryDebug.log("SlurryPipeManager created")
    return self
end

-- Returns the path to the mod's save file for the current savegame, or nil.
function SlurryPipeManager.getSavePath()
    if g_currentMission == nil then return nil end
    if g_currentMission.missionInfo == nil then return nil end
    if g_currentMission.missionInfo.savegameDirectory == nil then return nil end
    return g_currentMission.missionInfo.savegameDirectory .. "/FS25_SlurryPipeSystem.xml"
end


function SlurryPipeManager:delete()
    -- Destroy all active pipe visuals
    for _, pipeData in pairs(self.activePipes) do
        if g_spsPipeVisual ~= nil and pipeData.inst ~= nil then
            g_spsPipeVisual:destroyPipe(pipeData.inst)
        end
    end
    for _, chain in ipairs(self.pipeChains) do
        chain:delete()
    end
    self.pipeChains           = {}
    self.chainTerminusEntries = {}
    self.registeredVehicles    = {}
    self.registeredPlaceables  = {}
    self.sourceEntries         = {}
    self.activeFlows           = {}
    self.rubberBootPortEntries = {}
    self.activePipes           = {}
    -- Sprayer cleanup
    for _, pipeData in pairs(self.activeSprayerPipes) do
        if g_spsSprayerPipeVisual ~= nil and pipeData.inst ~= nil then
            g_spsSprayerPipeVisual:destroyPipe(pipeData.inst)
        end
    end
    self.registeredSprayerVehicles   = {}
    self.registeredSprayerPlaceables = {}
    self.activeSprayerFlows          = {}
    self.activeSprayerPipes          = {}
    SlurryDebug.log("SlurryPipeManager deleted")
end

-- ---------------------------------------------------------------------------
-- Config loading
-- ---------------------------------------------------------------------------
function SlurryPipeManager:loadVehicleConfigs(modDirectory)
    self.modDirectory = modDirectory
    local configRoot   = modDirectory .. "configs/"
    local manifestPath = modDirectory .. "configs/spsConfigManifest.xml"
    local xmlFile = XMLFile.load("spsManifest", manifestPath)
    if xmlFile == nil then
        SlurryDebug.log("loadVehicleConfigs - could not load manifest: " .. manifestPath)
        return
    end
    local idx = 0
    while true do
        local key = string.format("spsConfigManifest.vehicleConfigs.vehicle(%d)", idx)
        if not xmlFile:hasProperty(key) then break end

        local matchPath = xmlFile:getString(key .. "#path")
        if matchPath ~= nil and matchPath ~= "" then
            -- Bundled fillPoints.xml location:
            --   default: derived from matchPath by stripping the trailing XML filename
            --   override: optional configFolder attribute on the manifest entry
            -- The override is needed when a modder ships multiple XMLs in a shared
            -- folder (e.g. mods/X/xml/A.xml and mods/X/xml/B.xml) — auto-derivation
            -- would collide on the same fillPoints folder, so each entry must
            -- explicitly declare its own bundled location.
            local cfgDir = xmlFile:getString(key .. "#configFolder")
            if cfgDir == nil or cfgDir == "" then
                cfgDir = matchPath:match("^(.*)/[^/]+%.xml$")
            end
            if cfgDir == nil then
                SlurryDebug.log("loadVehicleConfigs: malformed path '" .. matchPath .. "'")
            else
                local xmlFilePath = configRoot .. cfgDir .. "/fillPoints.xml"
                if fileExists(xmlFilePath) then
                    self.vehicleConfigMap[matchPath:lower()] = {
                        xmlFilePath = xmlFilePath,
                        matchPath   = matchPath,
                    }
                    SlurryDebug.log("loadVehicleConfigs: registered '" .. matchPath .. "' -> " .. xmlFilePath)
                else
                    SlurryDebug.log("loadVehicleConfigs: no fillPoints.xml at " .. xmlFilePath .. " (manifest path '" .. matchPath .. "')")
                end
            end
        end
        idx = idx + 1
    end
    xmlFile:delete()
    local vcCount = 0
    for _ in pairs(self.vehicleConfigMap) do vcCount = vcCount + 1 end
    SlurryDebug.log("SlurryPipeManager: loaded " .. tostring(vcCount) .. " vehicle configs")
end

function SlurryPipeManager:loadPlaceableConfigs(modDirectory)
    local configRoot   = modDirectory .. "configs/"
    local manifestPath = modDirectory .. "configs/spsConfigManifest.xml"
    local xmlFile = XMLFile.load("spsManifest", manifestPath)
    if xmlFile == nil then
        SlurryDebug.log("loadPlaceableConfigs - could not load manifest: " .. manifestPath)
        return
    end
    local idx = 0
    while true do
        local key = string.format("spsConfigManifest.placeableConfigs.placeable(%d)", idx)
        if not xmlFile:hasProperty(key) then break end

        local matchPath = xmlFile:getString(key .. "#path")
        if matchPath ~= nil and matchPath ~= "" then
            -- See loadVehicleConfigs for the configFolder override rationale.
            local cfgDir = xmlFile:getString(key .. "#configFolder")
            if cfgDir == nil or cfgDir == "" then
                cfgDir = matchPath:match("^(.*)/[^/]+%.xml$")
            end
            if cfgDir == nil then
                SlurryDebug.log("loadPlaceableConfigs: malformed path '" .. matchPath .. "'")
            else
                local xmlFilePath = configRoot .. cfgDir .. "/fillPoints.xml"
                if fileExists(xmlFilePath) then
                    self.placeableConfigMap[matchPath:lower()] = {
                        xmlFilePath = xmlFilePath,
                        matchPath   = matchPath,
                    }
                    SlurryDebug.log("loadPlaceableConfigs: registered '" .. matchPath .. "' -> " .. xmlFilePath)
                else
                    SlurryDebug.log("loadPlaceableConfigs: no fillPoints.xml at " .. xmlFilePath .. " (manifest path '" .. matchPath .. "')")
                end
            end
        end
        idx = idx + 1
    end
    xmlFile:delete()
    local pcCount = 0
    for _ in pairs(self.placeableConfigMap) do pcCount = pcCount + 1 end
    SlurryDebug.log("loadPlaceableConfigs: loaded " .. tostring(pcCount) .. " placeable configs")
end

-- ---------------------------------------------------------------------------
-- Pipe colour config
-- ---------------------------------------------------------------------------
function SlurryPipeManager:loadPipeColors(modDirectory)
    local path = modDirectory .. "configs/spsColors.xml"
    local xmlFile = XMLFile.load("spsColors", path)
    if xmlFile == nil then
        print("[SPS] loadPipeColors: could not load " .. path)
        return
    end
    self.pipeColors = {}
    local idx = 0
    while true do
        local key = string.format("spsColors.color(%d)", idx)
        if not xmlFile:hasProperty(key) then break end
        table.insert(self.pipeColors, {
            name = xmlFile:getString(key .. "#name", "Color " .. (idx + 1)),
            r    = xmlFile:getFloat(key .. "#r", 0),
            g    = xmlFile:getFloat(key .. "#g", 0),
            b    = xmlFile:getFloat(key .. "#b", 0),
        })
        idx = idx + 1
    end
    xmlFile:delete()
    if #self.pipeColors > 0 then
        local c = self.pipeColors[1]
        self.currentPipeColor = { r = c.r, g = c.g, b = c.b }
        self.currentPipeColorIndex = 1
    end
    print("[SPS] loadPipeColors: loaded " .. #self.pipeColors .. " colours")
    for i, c in ipairs(self.pipeColors) do
    end
end

function SlurryPipeManager:setCurrentPipeColor(index)
    if self.pipeColors == nil or #self.pipeColors == 0 then
        print("[SPS] setCurrentPipeColor: pipeColors empty, ignoring index=" .. tostring(index))
        return
    end
    index = math.clamp(index, 1, #self.pipeColors)
    local c = self.pipeColors[index]
    self.currentPipeColorIndex = index
    self.currentPipeColor      = { r = c.r, g = c.g, b = c.b }
end

-- Single gate for every realism feature. Returns false whenever the master is off.
-- For an optional sub-feature (key given) it additionally requires that toggle to be
-- on (default on). With no key it just reports the master — used by the mandatory
-- features (store thickening, crust) that ride the master directly.
function SlurryPipeManager:isFeatureEnabled(key)
    if not self.realismEnabled then return false end
    if key == nil then return true end
    return self.featureToggles[key] ~= false
end
function SlurryPipeManager:findVehicleConfigForVehicle(vehicle)
    if vehicle.configFileName == nil then return nil end

    -- Embedded config check: does the vehicle's own XML carry a <slurryPipeSystem>
    -- element? If so, the vehicle is self-contained and overrides any internal
    -- manifest match. This is what lets third-party modders ship SPS-ready
    -- vehicles that include their own couplers, animations, and node references
    -- without ever touching the SPS mod folder.
    if vehicle.xmlFile ~= nil and vehicle.xmlFile:hasProperty("vehicle.slurryPipeSystem") then
        SlurryDebug.log("findVehicleConfigForVehicle: embedded <slurryPipeSystem> found in " .. tostring(vehicle.configFileName))
        return {
            xmlFilePath  = vehicle.configFileName,    -- used for nodeTree path resolution
            xmlKeyPrefix = "vehicle.",                -- prepended to every "slurryPipeSystem..." read
            isEmbedded   = true,
        }
    end

    -- Path-tail match against manifest entries. configFileName is the full path
    -- Giants gives us (e.g. "C:/.../mods/FS25_Pichon_BMIX80/BMIX.xml" or
    -- "data/vehicles/kaweco/profi2/profi2.xml"). A manifest entry with
    -- path="data/vehicles/kaweco/profi2/profi2.xml" matches when the vehicle's
    -- configFileName ENDS with that exact path (case-insensitive). Forward-
    -- slash-only — Giants always reports forward slashes in paths.
    local cfn = vehicle.configFileName:lower():gsub("\\", "/")
    for matchPathLower, config in pairs(self.vehicleConfigMap) do
        if cfn:sub(-#matchPathLower) == matchPathLower then
            SlurryDebug.log("findVehicleConfigForVehicle: matched '" .. config.matchPath .. "'")
            return config
        end
    end
    SlurryDebug.log("findVehicleConfigForVehicle: no match for '" .. vehicle.configFileName .. "'")
    return nil
end

function SlurryPipeManager:findPlaceableConfigForPlaceable(placeable)
    if placeable.configFileName == nil then return nil end

    -- Embedded config check: does the placeable's own XML carry a
    -- <slurryPipeSystem> element? See findVehicleConfigForVehicle for rationale.
    if placeable.xmlFile ~= nil and placeable.xmlFile:hasProperty("placeable.slurryPipeSystem") then
        SlurryDebug.log("findPlaceableConfigForPlaceable: embedded <slurryPipeSystem> found in " .. tostring(placeable.configFileName))
        return {
            xmlFilePath  = placeable.configFileName,
            xmlKeyPrefix = "placeable.",
            isEmbedded   = true,
        }
    end

    -- Path-tail match against manifest entries. Same rule as vehicles.
    local cfn = placeable.configFileName:lower():gsub("\\", "/")
    for matchPathLower, config in pairs(self.placeableConfigMap) do
        if cfn:sub(-#matchPathLower) == matchPathLower then
            SlurryDebug.log("findPlaceableConfigForPlaceable: matched '" .. config.matchPath .. "'")
            return config
        end
    end
    SlurryDebug.log("findPlaceableConfigForPlaceable: no match for '" .. placeable.configFileName .. "'")
    return nil
end

-- ---------------------------------------------------------------------------
-- registerVehicle
-- ---------------------------------------------------------------------------
function SlurryPipeManager:registerVehicle(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then return end
    end

    local config = self:findVehicleConfigForVehicle(vehicle)
    if config == nil then
        SlurryDebug.log("registerVehicle - no config for " .. tostring(vehicle.configFileName))
        return
    end

    -- Embedded configs use the vehicle's own xmlFile (already loaded by Giants);
    -- bundled configs open the SPS-internal fillPoints.xml. Track which one so
    -- we know whether to call delete() at the end (we MUST NOT delete the
    -- vehicle's own xmlFile — Giants owns it).
    local xmlFile
    local xmlFileOwned = false
    if config.isEmbedded then
        xmlFile = vehicle.xmlFile
    else
        xmlFile = XMLFile.load("spsVehiclePoints", config.xmlFilePath)
        xmlFileOwned = true
    end
    if xmlFile == nil then
        SlurryDebug.log("registerVehicle - XML load failed: " .. tostring(config.xmlFilePath))
        return
    end

    local kp = config.xmlKeyPrefix or ""

    local entry = {
        vehicle               = vehicle,
        config                = config,
        linkedNodes           = {},
        armEntries            = {},
        couplingEntries       = {},
        blockageEntries       = {},
        blockageRollTimer     = 0,
        receiverEntries       = {},
        rubberBootPortEntries = {},
        pumpControlEntries    = {},
        litersPerSecond       = xmlFile:getFloat(kp .. "slurryPipeSystem.flow#litersPerSecond", SlurryPipeManager.DEFAULT_LITERS_PER_SECOND),
        -- Separate fill (suck-in) and empty (push-out / spread) rates, litres/second.
        -- Resolution order (set just below): SPS fill/empty -> SPS single litersPerSecond
        -- -> vanilla in the same file (fillTriggerVehicle / dischargeNode) -> default.
        fillLitersPerSecond   = nil,
        emptyLitersPerSecond  = nil,
        pressure              = {
            maxPressure     = xmlFile:getFloat(kp .. "slurryPipeSystem.pressure#maxPressure",     SlurryPipeManager.DEFAULT_MAX_PRESSURE),
            minThreshold    = xmlFile:getFloat(kp .. "slurryPipeSystem.pressure#minThreshold",    SlurryPipeManager.DEFAULT_MIN_THRESHOLD),
            minBuildTime    = xmlFile:getFloat(kp .. "slurryPipeSystem.pressure#minBuildTime",    SlurryPipeManager.DEFAULT_MIN_BUILD_TIME),
            maxBuildTime    = xmlFile:getFloat(kp .. "slurryPipeSystem.pressure#maxBuildTime",    SlurryPipeManager.DEFAULT_MAX_BUILD_TIME),
            fallTimeWorking = xmlFile:getFloat(kp .. "slurryPipeSystem.pressure#fallTimeWorking", SlurryPipeManager.DEFAULT_FALL_TIME_WORKING),
            fallTimeEmpty   = xmlFile:getFloat(kp .. "slurryPipeSystem.pressure#fallTimeEmpty",   SlurryPipeManager.DEFAULT_FALL_TIME_EMPTY),
            purgeTime       = xmlFile:getFloat(kp .. "slurryPipeSystem.pressure#purgeTime",       SlurryPipeManager.DEFAULT_PURGE_TIME),
            gravityFlowScalar = xmlFile:getFloat(kp .. "slurryPipeSystem.pressure#gravityFlowScalar", SlurryPipeManager.DEFAULT_GRAVITY_FLOW_SCALAR),
            openTop         = xmlFile:getBool(kp  .. "slurryPipeSystem.pressure#openTop", false),
        },
        selfPowered           = xmlFile:getBool(kp .. "slurryPipeSystem.pump#selfPowered", false),
        conduit               = xmlFile:getBool(kp .. "slurryPipeSystem.pump#conduit", false),
        pumpType              = nil,   -- resolved just below from pump#pumpType
        agitatorOnly          = xmlFile:getBool(kp .. "slurryPipeSystem#agitatorOnly", false),
        -- Per-vehicle shear-bolt opt-in. Only vehicles whose fillPoints carry
        -- <shearBolt bolt="true"/> get a PTO shear bolt (wear, snap, freeze, and the
        -- walk-up repair activatable). Default false: no bolt, no wear, no activatable.
        shearBolt             = xmlFile:getBool(kp .. "slurryPipeSystem.shearBolt#bolt", false),
        nodeTreeRoot          = nil,
        sourceEntry           = nil,
        xmlFileOwned          = xmlFileOwned,
        state = {
            pumpRunning       = false,
            valveOpen         = false,
            direction         = SPS_DIRECTION_FILL,
            spreaderValveOpen = false,
            pressure          = 0,      -- signed bar, -maxPressure .. +maxPressure
            purging           = false,  -- true while venting to 0 after an opposing flip (set in Phase 2)
            thickness         = 0,      -- 0..1 slurry thickness (DM gauge) CARRIED by the tanker (inherited on fill, reset on empty)
            crust             = 0,      -- 0..1 un-mixed/lumpiness CARRIED by the tanker (inherited from the store's crust on fill; drives blockages; reset on empty)
        },
    }

    -- ---------------------------------------------------------------------
    -- Resolve the tanker drive model (pumpType). One explicit attribute per
    -- config, four values:
    --   "vacuum"  : stored-pressure model (build/hold/taper, ±bar gauge)
    --   "HVP"     : high-volume pump — pump-gated (PTO on = flow, off = stop),
    --               l/s gauge, spread rate falls with slurry thickness
    --   "conduit" : pump station — pump-gated, drives the conduit transfer HUD
    --   "openTop" : passive vessel (FRC) — never builds/holds pressure, no gauge
    -- Legacy fallbacks keep older configs working: an existing pump#conduit="true"
    -- maps to "conduit", an existing pressure#openTop="true" maps to "openTop".
    -- A missing attribute defaults to "vacuum" with a one-time warning so a modder
    -- who forgot to tag a third-party tanker can see it in the log.
    local rawPumpType = xmlFile:getString(kp .. "slurryPipeSystem.pump#pumpType", nil)
    local resolvedPumpType
    if rawPumpType ~= nil then
        resolvedPumpType = tostring(rawPumpType)
    elseif entry.conduit == true then
        resolvedPumpType = "conduit"
    elseif entry.pressure ~= nil and entry.pressure.openTop == true then
        resolvedPumpType = "openTop"
    else
        resolvedPumpType = "vacuum"
        print("[SPS] WARNING: no <pump pumpType=\"...\"/> in config for "
            .. tostring(vehicle ~= nil and vehicle.configFileName or config.xmlFilePath)
            .. " — defaulting to \"vacuum\". Add a pumpType tag (vacuum/HVP/conduit/openTop).")
    end
    -- Normalise / validate.
    if resolvedPumpType ~= "vacuum" and resolvedPumpType ~= "HVP"
       and resolvedPumpType ~= "conduit" and resolvedPumpType ~= "openTop" then
        print("[SPS] WARNING: unknown pumpType \"" .. resolvedPumpType .. "\" in "
            .. tostring(vehicle ~= nil and vehicle.configFileName or config.xmlFilePath)
            .. " — defaulting to \"vacuum\".")
        resolvedPumpType = "vacuum"
    end
    entry.pumpType = resolvedPumpType
    -- Derive the legacy flags from pumpType so existing call sites (conduit HUD,
    -- the openTop pressure exemption) keep working with no further change.
    entry.conduit = (resolvedPumpType == "conduit")
    if resolvedPumpType == "openTop" and entry.pressure ~= nil then
        entry.pressure.openTop = true
    end

    -- ---------------------------------------------------------------------
    -- Resolve fill (suck-in) and empty (push-out / spread) rates, litres/second.
    -- The SPS section always wins; vanilla is only a same-file fallback.
    --   1. SPS  slurryPipeSystem.flow#fillLitersPerSecond / #emptyLitersPerSecond
    --   2. SPS  slurryPipeSystem.flow#litersPerSecond  (single, used for both)
    --   3. Vanilla in the SAME file: fillTriggerVehicle#litersPerSecond (fill) and
    --      the first dischargeNode#emptySpeed (empty). Only reachable for an embedded
    --      <slurryPipeSystem> in a vehicle's own XML — a separate fillPoints.xml does
    --      not contain the vanilla nodes, so those configs must set the SPS rates.
    --   4. Default (DEFAULT_LITERS_PER_SECOND).
    local spsFill  = xmlFile:getFloat(kp .. "slurryPipeSystem.flow#fillLitersPerSecond",  nil)
    local spsEmpty = xmlFile:getFloat(kp .. "slurryPipeSystem.flow#emptyLitersPerSecond", nil)
    local spsBoth  = xmlFile:getFloat(kp .. "slurryPipeSystem.flow#litersPerSecond",      nil)
    local vanFill  = xmlFile:getFloat(kp .. "fillTriggerVehicle#litersPerSecond",         nil)
    local vanEmpty = xmlFile:getFloat(kp .. "dischargeable.dischargeNode(0)#emptySpeed",  nil)

    entry.fillLitersPerSecond  = spsFill  or spsBoth or vanFill  or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    entry.emptyLitersPerSecond = spsEmpty or spsBoth or vanEmpty or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    -- Keep the single-value field as the empty rate so any legacy reader stays sane.
    entry.litersPerSecond      = entry.emptyLitersPerSecond
--    SlurryDebug.log(string.format("[SPS Flow] %s fill=%.0f empty=%.0f (pumpType=%s)",
--        tostring(vehicle ~= nil and vehicle.configFileName or config.xmlFilePath),
--        entry.fillLitersPerSecond, entry.emptyLitersPerSecond, tostring(entry.pumpType)))

    -- Load nodeTree
    local nodeTreePath = xmlFile:getString(kp .. "slurryPipeSystem.nodeTree#filename")
    if nodeTreePath ~= nil then
        local configFolder = config.xmlFilePath:match("^(.*[/\\])")
        local fullPath     = configFolder .. nodeTreePath
        local nodeTreeRoot = loadI3DFile(fullPath)
        if nodeTreeRoot ~= nil and nodeTreeRoot ~= 0 then
            entry.nodeTreeRoot = nodeTreeRoot
            local function findByName(root, name)
                if getName(root) == name then return root end
                for i = 0, getNumOfChildren(root) - 1 do
                    local found = findByName(getChildAt(root, i), name)
                    if found ~= nil then return found end
                end
                return nil
            end
            -- Store effect nodes BEFORE linking (they will be moved out of nodeTreeRoot)
            entry.effectNode = findByName(nodeTreeRoot, "effect")
            entry.smokeNode  = findByName(nodeTreeRoot, "pipeEffectSmoke")
--            print("[SPS] nodeTreeRoot name=" .. tostring(getName(nodeTreeRoot)) .. " children=" .. tostring(getNumOfChildren(nodeTreeRoot)) .. " effectNode=" .. tostring(entry.effectNode))
            local c0 = getChildAt(nodeTreeRoot, 0)
            if c0 ~= nil and c0 ~= 0 then
               -- print("[SPS] child0 name=" .. tostring(getName(c0)) .. " children=" .. tostring(getNumOfChildren(c0)))
                for gi = 0, getNumOfChildren(c0) - 1 do
                    local g = getChildAt(c0, gi)
                    --print("[SPS]   group[" .. gi .. "]=" .. tostring(getName(g)) .. " children=" .. tostring(getNumOfChildren(g)))
                    for ci = 0, getNumOfChildren(g) - 1 do
                        local cont = getChildAt(g, ci)
                       -- print("[SPS]     container[" .. ci .. "]=" .. tostring(getName(cont)) .. " children=" .. tostring(getNumOfChildren(cont)))
                    end
                end
            end
            local spsRoot = getChildAt(nodeTreeRoot, 0)
            if spsRoot ~= nil and spsRoot ~= 0 then
                for groupIdx = 0, getNumOfChildren(spsRoot) - 1 do
                    local group = getChildAt(spsRoot, groupIdx)
                    for containerIdx = 0, getNumOfChildren(group) - 1 do
                        local container  = getChildAt(group, containerIdx)
                        local targetName = getName(container)
                        local liveParent = findByName(vehicle.rootNode, targetName)
                        if liveParent ~= nil then
                            local children = {}
                            for childIdx = 0, getNumOfChildren(container) - 1 do
                                table.insert(children, getChildAt(container, childIdx))
                            end
                            for _, spsNode in ipairs(children) do
                                removeFromPhysics(spsNode)
                                link(liveParent, spsNode)
                                addToPhysics(spsNode)
                                table.insert(entry.linkedNodes, spsNode)
                            end
                        else
                            --print("[SPS] container target '" .. targetName .. "' not found in vehicle")
                        end
                    end
                end
            end
        else
            SlurryDebug.log("SlurryPipeManager: failed to load nodeTree: " .. tostring(fullPath))
        end
    end


    local function findLinkedNode(name)
        if name == nil or name == "" then return nil end
        for _, n in ipairs(entry.linkedNodes) do
            if getName(n) == name then return n end
        end
        -- Fallback: search the vehicle's own node tree for nodes already authored in the i3d
        local function searchTree(root, targetName)
            if getName(root) == targetName then return root end
            for i = 0, getNumOfChildren(root) - 1 do
                local found = searchTree(getChildAt(root, i), targetName)
                if found ~= nil then return found end
            end
            return nil
        end
        return searchTree(vehicle.rootNode, name)
    end

    -- Fill arms
    -- getActiveConfigIndex resolves the active 0-based slot for any config type.
    -- Defaults to "cylindered" for vehicles that use the standard cylindered spec.
    local function getActiveConfigIndex(configType)
        local ct = configType or "cylindered"
        if vehicle.configurations ~= nil and vehicle.configurations[ct] ~= nil then
            return vehicle.configurations[ct] - 1
        end
        return nil
    end

    -- configIndexMatches handles both single values ("2") and comma-separated
    -- lists ("0,1,2") — needed for vehicles like RossMore with multiple designs.
    local function configIndexMatches(cfgIndexStr, activeIndex)
        for part in cfgIndexStr:gmatch("[^,]+") do
            if tonumber(part) == activeIndex then return true end
        end
        return false
    end

    local armIndex = 0
    while true do
        local armKey = string.format(kp .. "slurryPipeSystem.fillArms.fillArm(%d)", armIndex)
        if not xmlFile:hasProperty(armKey) then break end

        local armId   = xmlFile:getInt(armKey .. "#id", armIndex + 1)
        local tipType = xmlFile:getString(armKey .. "#tipType", SPS_TIP_TYPE_OPEN_PIT)

        local cfgIndexStr = xmlFile:getString(armKey .. "#cylinderedConfigIndex")
        if cfgIndexStr ~= nil then
            local cfgType     = xmlFile:getString(armKey .. "#configType", "cylindered")
            local activeIndex = getActiveConfigIndex(cfgType)
            if activeIndex ~= nil and not configIndexMatches(cfgIndexStr, activeIndex) then
                armIndex = armIndex + 1
                continue
            end
        end

        local armEntry = {
            id                = armId,
            tipType           = tipType,
            fillUnitIndex     = xmlFile:getInt(armKey .. "#fillUnitIndex", 1),
            isConnected       = false,
            connectedSource   = nil,
            connectedBootPort = nil,
        }

        if tipType == SPS_TIP_TYPE_RUBBER_BOOT then
            armEntry.tipNode = findLinkedNode(xmlFile:getString(armKey .. "#tipNodeName"))
            if armEntry.tipNode == nil then
                print("[SPS] fillArm id=" .. armId .. " RUBBER_BOOT tipNode not found, skipping")
                armIndex = armIndex + 1
                continue
            end
        elseif tipType == SPS_TIP_TYPE_OPEN_PIT then
            armEntry.centreNode = findLinkedNode(xmlFile:getString(armKey .. "#centreNodeName"))
            if armEntry.centreNode == nil then
                print("[SPS] fillArm id=" .. armId .. " OPEN_PIT centreNode not found, skipping")
                armIndex = armIndex + 1
                continue
            end
        elseif tipType == SPS_TIP_TYPE_RUBBER_BOOT_PIT then
            armEntry.tipNode    = findLinkedNode(xmlFile:getString(armKey .. "#tipNodeName"))
            armEntry.centreNode = findLinkedNode(xmlFile:getString(armKey .. "#centreNodeName"))
            if armEntry.tipNode == nil and armEntry.centreNode == nil then
                print("[SPS] fillArm id=" .. armId .. " RUBBER_BOOT_PIT no usable nodes, skipping")
                armIndex = armIndex + 1
                continue
            end
        end

        table.insert(entry.armEntries, armEntry)
        armIndex = armIndex + 1
    end


    -- Load fill arm effects from nodeTree pipeEffects node and fillPoints.xml
    entry.pipeEffects = nil
    --print("[SPS] pipeEffects guard: isClient=" .. tostring(vehicle.isClient) .. " nodeTreeRoot=" .. tostring(entry.nodeTreeRoot ~= nil) .. " armEntries=" .. #entry.armEntries)
    if vehicle.isClient and entry.nodeTreeRoot ~= nil and #entry.armEntries > 0 then
        local effectNode = entry.effectNode
        local smokeNode  = entry.smokeNode
        --print("[SPS] pipeEffects check: effectNode=" .. tostring(effectNode) .. " smokeNode=" .. tostring(smokeNode) .. " arms=" .. #entry.armEntries)
        if effectNode ~= nil and smokeNode ~= nil then
            -- Register classes if needed
            if g_effectManager:getEffectClass("PipeEffect") == nil and PipeEffect ~= nil then
                g_effectManager:registerEffectClass("PipeEffect", PipeEffect)
            end
            if g_effectManager:getEffectClass("ShaderPlaneEffect") == nil and ShaderPlaneEffect ~= nil then
                g_effectManager:registerEffectClass("ShaderPlaneEffect", ShaderPlaneEffect)
            end
            -- Build effects manually — avoids needing a registered schema on our xmlFile
            local effects = {}
            -- PipeEffect on the stream node
            local pe = PipeEffect.new()
            pe.parent        = vehicle
            pe.baseDirectory = vehicle.baseDirectory
            pe.rootNodes     = effectNode
            pe.node          = getChildAt(effectNode, 0)  -- pipeEffect Shape, not the TG
            pe.maxBending    = 0.8
            pe.extraDistance = 0.1
            pe.updateDistance = true
            pe.distance      = 0
            pe.controlPointY = 0
            pe.worldTarget   = { 0, 0, 0 }
            pe.controlPoint  = { 10, 0.25, 0, 0 }
            pe.shapeScaleSpread   = { 0.6, 1, 1, 0 }
            pe.uvScaleSpeedFreqAmp = nil
            pe.positionUpdateNodes = { smokeNode }
            pe.materialType  = "spsSlurryPipe"
            pe.materialTypeId = 1
            pe.dynamicFillType = false
            pe.hasValidMaterial = false
            pe.lastFillTypeIndex = nil
            pe.fadeInTime    = 1000
            pe.fadeOutTime   = 1000
            pe.startDelay    = 0
            pe.stopDelay     = 0
            pe.currentDelay  = 0
            pe.state         = ShaderPlaneEffect.STATE_OFF
            pe.planeFadeTime = 1000
            pe.fadeCur = { -1, 1 }
            pe.fadeDir = { 1, 1 }
            pe.fadeX   = { -1, 1 }
            pe.fadeY   = { -1, 1 }
            pe.alwaysVisibile = false
            pe.showOnFirstUse = false
            pe.prio      = 0
            pe.deleteListeners  = {}
            pe.startRestriction = {}
            pe.allowUpdate   = true
            pe.lastUpdateTime = 0
            setVisibility(pe.node, false)
            g_effectManager:setUpdateDistance({ pe }, math.huge)
            table.insert(effects, pe)
            -- Apply slurry material directly — "pipe" type has no LIQUIDMANURE entry in MaterialManager
            if g_spsSlurryMaterial ~= nil then
                setMaterial(pe.node, g_spsSlurryMaterial, 0)
                pe.hasValidMaterial = true
                pe.useBaseMaterial  = true
            end
            -- ShaderPlaneEffect on the smoke node
            local se = ShaderPlaneEffect.new()
            se.parent        = vehicle
            se.baseDirectory = vehicle.baseDirectory
            se.rootNodes     = smokeNode
            se.node          = smokeNode
            se.materialType  = "unloadingSmoke"
            se.materialTypeId = 1
            se.dynamicFillType = false
            se.hasValidMaterial = false
            se.lastFillTypeIndex = nil
            se.fadeInTime    = 1000
            se.fadeOutTime   = 1000
            se.startDelay    = 100
            se.stopDelay     = 100
            se.currentDelay  = 100
            se.state         = ShaderPlaneEffect.STATE_OFF
            se.planeFadeTime = 1000
            se.fadeCur = { -1, 1 }
            se.fadeDir = { 1, 1 }
            se.fadeX   = { -1, 1 }
            se.fadeY   = { -1, 1 }
            se.alignToWorldY  = true
            se.alignXAxisToWorldY = false
            se.alwaysVisibile = false
            se.showOnFirstUse = false
            se.prio      = 0
            se.deleteListeners  = {}
            se.startRestriction = {}
            se.allowUpdate   = true
            se.lastUpdateTime = 0
            setVisibility(smokeNode, false)
            g_effectManager:setUpdateDistance({ se }, math.huge)
            table.insert(effects, se)
            entry.pipeEffects = effects
            --print("[SPS] pipeEffects manually built: " .. #effects .. " for " .. tostring(vehicle.configFileName))
        else
            print("[SPS] pipeEffects: effect/pipeEffectSmoke not found in nodeTree")
        end
    end

    -- Pipe couplings (data loaded for future use; no connection logic active)
    -- usedCouplingMountNodes guards against a single physical coupler registering
    -- more than one coupling. That happens when config-gated variants
    -- (cylinderedConfigIndex) cannot be resolved to an active config
    -- (getActiveConfigIndex returns nil), so every variant passes the gate and the
    -- same mount node is claimed twice. Two couplings on one node means two lay /
    -- connect activatables on one coupler — the "two pipes from one coupler" bug.
    local usedCouplingMountNodes = {}
    local couplingIndex = 0
    while true do
        local cKey = string.format(kp .. "slurryPipeSystem.pipeCouplings.pipeCoupling(%d)", couplingIndex)
        if not xmlFile:hasProperty(cKey) then break end
        local couplingId = xmlFile:getInt(cKey .. "#id", couplingIndex + 1)

        local cCfgIndexStr = xmlFile:getString(cKey .. "#cylinderedConfigIndex")
        if cCfgIndexStr ~= nil then
            local cfgType     = xmlFile:getString(cKey .. "#configType", "cylindered")
            local activeIndex = getActiveConfigIndex(cfgType)
            if activeIndex ~= nil and not configIndexMatches(cCfgIndexStr, activeIndex) then
                couplingIndex = couplingIndex + 1
                continue
            end
        end

        local mountNode = findLinkedNode(xmlFile:getString(cKey .. "#mountNodeName"))
        if mountNode ~= nil then
            -- Drop a duplicate that resolved to a mount node already claimed by an
            -- earlier coupling on THIS vehicle (config-gating bypass). Keep the first.
            if usedCouplingMountNodes[mountNode] ~= nil then
                SlurryDebug.log(string.format(
                    "registerVehicle: dropped duplicate coupling id=%s on mountNode already held by id=%s (%s)",
                    tostring(couplingId), tostring(usedCouplingMountNodes[mountNode]),
                    tostring(vehicle.configFileName)))
                couplingIndex = couplingIndex + 1
                continue
            end
            usedCouplingMountNodes[mountNode] = couplingId
            -- Find inNode and outNode children of the mountNode
            local inNode, outNode
            for i = 0, getNumOfChildren(mountNode) - 1 do
                local child = getChildAt(mountNode, i)
                local childName = getName(child)
                if childName == "inNode" then
                    inNode = child
                elseif childName == "outNode" then
                    outNode = child
                end
            end
            local couplingEntry = {
                id                  = couplingId,
                mountNode           = mountNode,
                inNode              = inNode,
                outNode             = outNode,
                valveType           = xmlFile:getString(cKey .. "#valveType", SPS_VALVE_TYPE_MANUAL),
                flowDirection       = xmlFile:getString(cKey .. "#flowDirection", "BOTH"),
                maxPipeLength       = xmlFile:getFloat(cKey .. "#maxPipeLength", 6.0),
                fillUnitIndex       = xmlFile:getInt(cKey .. "#fillUnitIndex", 1),
                valveFromRearControl = xmlFile:getBool(cKey .. "#valveFromRearControl", false),
                connectorType       = xmlFile:getString(cKey .. "#connector", "male"),
                connectorAnimationId = xmlFile:getInt(cKey .. "#connectorAnimation"),
                valveAnimationId     = xmlFile:getInt(cKey .. "#valveAnimation"),
                isConnected         = false,
                connectedTarget     = nil,
                sourceEntry         = nil,
            }
            -- Bind coupler animations if either id is declared on this coupling.
            if SPSCouplerAnimator ~= nil
            and (couplingEntry.connectorAnimationId ~= nil or couplingEntry.valveAnimationId ~= nil) then
                SPSCouplerAnimator.ensureLoaded(self.modDirectory)
                if couplingEntry.connectorAnimationId ~= nil then
                    couplingEntry.connectorAnim = SPSCouplerAnimator.bind(couplingEntry.mountNode, couplingEntry.connectorAnimationId)
                end
                if couplingEntry.valveAnimationId ~= nil then
                    couplingEntry.valveAnim = SPSCouplerAnimator.bind(couplingEntry.mountNode, couplingEntry.valveAnimationId)
                end
            end
            table.insert(entry.couplingEntries, couplingEntry)
        else
            print("[SPS] pipeCoupling id=" .. tostring(couplingId) .. " mountNode not found, skipping")
        end
        couplingIndex = couplingIndex + 1
    end

    -- Blockage nodes (dribble bar / spreader). Each may optionally name an animation,
    -- read here and played on block/clear if present, skipped if absent. A node named
    -- *Macerator is the central distributor: blocking it stops the whole bar. The
    -- macerator and centre node share a spot, so they are never both flagged.
    local blockageIndex = 0
    while true do
        local bKey = string.format(kp .. "slurryPipeSystem.blockageNodes.blockageNode(%d)", blockageIndex)
        if not xmlFile:hasProperty(bKey) then break end

        -- Config gate (same pattern as fill arms / couplings). #workAreaConfigIndex is
        -- a 0-based active-config index (or comma list). #configType names the config
        -- (default "workArea" -> vehicle.configurations.workArea). When the active config
        -- does not match, skip this node so only ONE bar loads per config — not both.
        local bCfgIndexStr = xmlFile:getString(bKey .. "#workAreaConfigIndex")
        if bCfgIndexStr ~= nil then
            local bCfgType     = xmlFile:getString(bKey .. "#configType", "workArea")
            local bActiveIndex = getActiveConfigIndex(bCfgType)
            if bActiveIndex ~= nil and not configIndexMatches(bCfgIndexStr, bActiveIndex) then
                print(string.format("[SPS] blockageNode skip: %s workAreaConfigIndex=%s active=%d (%s)",
                    tostring(xmlFile:getString(bKey .. "#mountNodeName")), tostring(bCfgIndexStr), bActiveIndex, tostring(bCfgType)))
                blockageIndex = blockageIndex + 1
                continue
            end
            print(string.format("[SPS] blockageNode match: %s workAreaConfigIndex=%s active=%s (%s)",
                tostring(xmlFile:getString(bKey .. "#mountNodeName")), tostring(bCfgIndexStr), tostring(bActiveIndex), tostring(bCfgType)))
        end

        local nodeName = xmlFile:getString(bKey .. "#mountNodeName")
        local node     = findLinkedNode(nodeName)
        if node ~= nil then
            local isMacerator = (nodeName ~= nil and string.find(nodeName, "Macerator") ~= nil)
            table.insert(entry.blockageEntries, {
                node              = node,
                name              = nodeName,
                blockageAnimation = xmlFile:getString(bKey .. "#blockageAnimation"),
                blocked           = false,
                isMacerator       = isMacerator,
                -- Optional band parent (authored in the nodeTree) for the per-outlet
                -- work-area section. Absent on the macerator (it has no section).
                workAreaNodeName  = xmlFile:getString(bKey .. "#workAreaNode"),
            })
        else
            print("[SPS] blockageNode '" .. tostring(nodeName) .. "' not found, skipping")
        end
        blockageIndex = blockageIndex + 1
    end
    if #entry.blockageEntries > 0 then
        --print("[SPS] loaded " .. #entry.blockageEntries .. " blockage node(s) for " .. tostring(vehicle.configFileName))
    end

    -- Spreader section bands.
    -- Each outlet blockage node may name a work-area parent (#workAreaNode) authored in
    -- the linked nodeTree; under that parent are workAreaStart / workAreaWidth /
    -- workAreaHeight. We clone the vehicle's existing sprayer work area's processing
    -- fields, swap in the band's three nodes, and append the band to
    -- spec_workArea.workAreas. The original full-width sprayer area is flagged
    -- (_spsOriginalSprayArea) so the work-area override stops spraying it — the bands
    -- then own the ground. A blocked outlet's band is skipped by the override, leaving a
    -- real unsprayed stripe at that lateral position. Built on server AND client (work
    -- areas exist on both; blocked state syncs via SPSBlockageEvent). No i3d nodes are
    -- created here — only existing authored nodes are referenced.
    do
        local waSpec = vehicle.spec_workArea
        if waSpec ~= nil and waSpec.workAreas ~= nil then
            -- Template = the vehicle's existing sprayer area (the full-width one). Flag
            -- every pre-existing sprayer area as the original so the override disables it.
            local template = nil
            for _, wa in ipairs(waSpec.workAreas) do
                if wa.functionName == "processSprayerArea" and wa._spsBlockageEntry == nil then
                    wa._spsOriginalSprayArea = true
                    if template == nil then template = wa end
                end
            end

            if template ~= nil then
                -- Child-by-name search scoped to a single band parent. The start/width/
                -- height names are shared across all bands, so they MUST be resolved
                -- under their own parent — never via the global findLinkedNode.
                local function findChildByName(root, wantName)
                    if root == nil or root == 0 then return nil end
                    if getName(root) == wantName then return root end
                    for ci = 0, getNumOfChildren(root) - 1 do
                        local f = findChildByName(getChildAt(root, ci), wantName)
                        if f ~= nil then return f end
                    end
                    return nil
                end

                -- The frame the vanilla sprayer area lives in (parent of its start node).
                -- Band parents authored in the nodeTree use coordinates in THIS frame
                -- (e.g. +18..-18 across the bar), so any band we have to link ourselves
                -- is linked here to get correct world positions.
                local frameParent = nil
                if template.start ~= nil then frameParent = getParent(template.start) end

                local built = 0
                for _, b in ipairs(entry.blockageEntries) do
                    if not b.isMacerator and b.workAreaNodeName ~= nil and b.workAreaNodeName ~= "" then
                        local parent = findLinkedNode(b.workAreaNodeName)
                        -- Fallback: the generic nodeTree linker only attaches a container's
                        -- children when the CONTAINER name matches a live vehicle node. If
                        -- the band parents were authored as the containers themselves (their
                        -- names are not live nodes), they were left in the loaded nodeTree.
                        -- Find them there and link them onto the vanilla work-area frame so
                        -- their authored coordinates resolve correctly — no specific i3d
                        -- nesting required.
                        if parent == nil and entry.nodeTreeRoot ~= nil and entry.nodeTreeRoot ~= 0 and frameParent ~= nil then
                            local found = findChildByName(entry.nodeTreeRoot, b.workAreaNodeName)
                            if found ~= nil then
                                removeFromPhysics(found)
                                link(frameParent, found)
                                addToPhysics(found)
                                table.insert(entry.linkedNodes, found)
                                parent = found
                                --print("[SPS] section '" .. tostring(b.workAreaNodeName) .. "' self-linked from nodeTree onto work-area frame")
                            end
                        end
                        if parent ~= nil then
                            local startNode  = findChildByName(parent, "workAreaStart")
                            local widthNode  = findChildByName(parent, "workAreaWidth")
                            local heightNode = findChildByName(parent, "workAreaHeight")
                            if startNode ~= nil and widthNode ~= nil and heightNode ~= nil then
                                -- Shallow-copy the ENTIRE template work area so the band
                                -- inherits every field the engine/specs expect — including
                                -- the fold limits Foldable sets at load (foldMinLimit/
                                -- foldMaxLimit). Hand-picking fields missed those and
                                -- crashed Foldable.update ("nil < number") when a band went
                                -- active. Then override only the band-specific bits.
                                local band = {}
                                for k, v in pairs(template) do
                                    band[k] = v
                                end
                                band.start              = startNode
                                band.width              = widthNode
                                band.height             = heightNode
                                band.workWidth          = -1
                                band.lastProcessingTime = 0
                                band.lastWorkedHectares = 0
                                band.index              = nil  -- set after insert
                                -- The template was flagged as the original full-width area;
                                -- a section band must NOT carry that flag or the override
                                -- would disable it.
                                band._spsOriginalSprayArea = nil
                                band._spsLastActive        = nil
                                band._spsBlockageEntry     = b
                                band._spsSectionName       = b.workAreaNodeName
                                table.insert(waSpec.workAreas, band)
                                band.index = #waSpec.workAreas
                                if vehicle.updateWorkAreaWidth ~= nil then
                                    vehicle:updateWorkAreaWidth(band.index)
                                end
                                if waSpec.workAreaByType ~= nil then
                                    if waSpec.workAreaByType[band.type] == nil then
                                        waSpec.workAreaByType[band.type] = {}
                                    end
                                    table.insert(waSpec.workAreaByType[band.type], band)
                                end
                                b.workArea = band
                                built = built + 1
                                local wx, wy, wz = getWorldTranslation(startNode)
                                --print(string.format("[SPS] section band '%s' built (index %d) startWorld=%.2f %.2f %.2f",
                                --    tostring(b.workAreaNodeName), band.index, wx, wy, wz))
                            else
                                print("[SPS] section '" .. tostring(b.workAreaNodeName) .. "' missing workAreaStart/Width/Height child, skipping")
                            end
                        else
                            print("[SPS] section workAreaNode '" .. tostring(b.workAreaNodeName) .. "' not found, skipping")
                        end
                    end
                end

                if built > 0 then
                    vehicle._spsHasSectionBands = true
                    --print("[SPS] built " .. built .. " spreader section band(s) for " .. tostring(vehicle.configFileName))
                end
            else
                --print("[SPS] no sprayer work area template on " .. tostring(vehicle.configFileName) .. " — section bands not built")
            end
        end
    end

    -- Rubber boot ports
    local rbpIndex = 0
    while true do
        local rbpKey = string.format(kp .. "slurryPipeSystem.rubberBootPorts.rubberBootPort(%d)", rbpIndex)
        if not xmlFile:hasProperty(rbpKey) then break end
        local rbpId        = xmlFile:getInt(rbpKey .. "#id", rbpIndex + 1)
        local rbpLowerNode = findLinkedNode(xmlFile:getString(rbpKey .. "#lowerNodeName"))
        local rbpUpperNode = findLinkedNode(xmlFile:getString(rbpKey .. "#upperNodeName"))
        if rbpLowerNode ~= nil and rbpUpperNode ~= nil then
            local rbpEntry = {
                id            = rbpId,
                lowerNode     = rbpLowerNode,
                upperNode     = rbpUpperNode,
                vehicle       = vehicle,
                valveType     = xmlFile:getString(rbpKey .. "#valveType", SPS_VALVE_TYPE_NONE),
                fillUnitIndex = xmlFile:getInt(rbpKey .. "#fillUnitIndex", 1),
                valveOpen     = false,
            }
            table.insert(entry.rubberBootPortEntries, rbpEntry)
            table.insert(self.rubberBootPortEntries, rbpEntry)
        else
            print("[SPS] rubberBootPort id=" .. tostring(rbpId) .. " lowerNode or upperNode not found, skipping")
        end
        rbpIndex = rbpIndex + 1
    end

    -- Pump controls (TSA-style all-in-one rear node — UNCHANGED, uses #nodeName)
    local pcIndex = 0
    while true do
        local pcKey = string.format(kp .. "slurryPipeSystem.pumpControls.pumpControl(%d)", pcIndex)
        if not xmlFile:hasProperty(pcKey) then break end
        local pcId     = xmlFile:getInt(pcKey .. "#id", pcIndex + 1)
        local pcRadius = xmlFile:getFloat(pcKey .. "#radius", 1.5)
        local pcNode   = findLinkedNode(xmlFile:getString(pcKey .. "#nodeName"))
        if pcNode ~= nil then
            table.insert(entry.pumpControlEntries, { id = pcId, node = pcNode, radius = pcRadius, vehicle = vehicle })
        else
            print("[SPS] pumpControl id=" .. tostring(pcId) .. " node not found, skipping")
        end
        pcIndex = pcIndex + 1
    end

    -- Outside controls (one node, per-item flags). PTO prompt is gated by tractor
    -- capability; direction prompt relocates the cab fill/empty control to the node.
    entry.outsideControlEntries = {}
    local ocIndex = 0
    while true do
        local ocKey = string.format(kp .. "slurryPipeSystem.outsideControls.outsideControl(%d)", ocIndex)
        if not xmlFile:hasProperty(ocKey) then break end
        local ocId        = xmlFile:getInt(ocKey .. "#id", ocIndex + 1)
        local ocRadius    = xmlFile:getFloat(ocKey .. "#radius", 1.5)
        local ocPto       = xmlFile:getBool(ocKey .. "#pto", false)
        local ocDirection = xmlFile:getBool(ocKey .. "#direction", false)
        local ocNode      = findLinkedNode(xmlFile:getString(ocKey .. "#mountNodeName"))
        if ocNode ~= nil then
            table.insert(entry.outsideControlEntries, { id = ocId, node = ocNode, radius = ocRadius, pto = ocPto, direction = ocDirection, vehicle = vehicle })
            --print("[SPS] outsideControl id=" .. tostring(ocId) .. " registered (pto=" .. tostring(ocPto) .. " direction=" .. tostring(ocDirection) .. ")")
        else
            --print("[SPS] outsideControl id=" .. tostring(ocId) .. " node not found, skipping")
        end
        ocIndex = ocIndex + 1
    end
	
	-- Optional spreader animation, driven by SPS discharge state (not turnOn)
    entry.spreaderAnimationName = xmlFile:getString(kp .. "slurryPipeSystem.spreaderAnimation#name")
    entry.spreaderAnimationStopDelay = xmlFile:getFloat(kp .. "slurryPipeSystem.spreaderAnimation#stopDelay", 2.0) * 1000
    entry._spreadAnimOn = false
    entry._spreadAnimTail = nil
    if entry.spreaderAnimationName ~= nil then
        --print("[SPS] spreaderAnimation '" .. entry.spreaderAnimationName
            --.. "' registered (SPS-driven, stopDelay=" .. tostring(entry.spreaderAnimationStopDelay) .. "ms)")
    end
	
    -- Disable the vanilla FillTrigger
    if vehicle.spec_fillTriggerVehicle ~= nil
    and vehicle.spec_fillTriggerVehicle.fillTrigger ~= nil then
        vehicle.spec_fillTriggerVehicle.fillTrigger.isEnabled = false
    end

    -- Create proximity activatables for each coupling
    entry.pipeActivatables  = {}
    entry.chainActivatables = {}
    for _, coupling in ipairs(entry.couplingEntries) do
        if coupling.mountNode ~= nil then
            local pipeAct  = SPSPipeActivatable.new(vehicle, coupling)
            table.insert(entry.pipeActivatables, pipeAct)
            g_currentMission.activatableObjectsSystem:addActivatable(pipeAct)
            local chainAct = SPSChainActivatable.new(nil, 0, coupling)
            coupling.chainActivatable = chainAct
            table.insert(entry.chainActivatables, chainAct)
            g_currentMission.activatableObjectsSystem:addActivatable(chainAct)
        end
    end

    -- Create pump control activatables for rear-control nodes (TSA-style, unchanged)
    entry.pumpControlActivatables = {}
    for _, pc in ipairs(entry.pumpControlEntries) do
        local pca = SPSPumpControlActivatable.new(vehicle, pc.node, pc.radius)
        table.insert(entry.pumpControlActivatables, pca)
        g_currentMission.activatableObjectsSystem:addActivatable(pca)
    end

    -- Create the merged outside-control activatable(s) (PTO + direction on one node)
    entry.outsideControlActivatables = {}
    for _, oc in ipairs(entry.outsideControlEntries) do
        local act = SPSOutsideControlActivatable.new(vehicle, oc.node, oc.radius, oc.pto, oc.direction)
        table.insert(entry.outsideControlActivatables, act)
        g_currentMission.activatableObjectsSystem:addActivatable(act)
    end

    -- Walk-up, hold-to-clear activatables, one per blockage node (outlets + macerator).
    -- They only appear while their node is blocked, and only clear once the bar is
    -- stopped (see canClearBlockage).
    entry.blockageActivatables = {}
    if SPSBlockageActivatable ~= nil
    and g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        for _, b in ipairs(entry.blockageEntries) do
            if b.node ~= nil then
                local ba = SPSBlockageActivatable.new(vehicle, b)
                table.insert(entry.blockageActivatables, ba)
                g_currentMission.activatableObjectsSystem:addActivatable(ba)
            end
        end
    end

    -- Walk-up, hold-to-repair activatable for a snapped shear bolt, hosted on the
    -- outside-control node (same node the player uses for outside PTO/direction). If
    -- the tanker has no outside-control node, fall back to a pump-control node. Only
    -- ever appears while the bolt is snapped (vac tanks only — see SPSShearBolt).
    entry.shearBoltActivatables = {}
    if entry.shearBolt == true
    and SPSShearBoltActivatable ~= nil
    and g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        local hostNodes = {}
        for _, oc in ipairs(entry.outsideControlEntries) do
            if oc.node ~= nil then table.insert(hostNodes, { node = oc.node, radius = oc.radius }) end
        end
        if #hostNodes == 0 then
            for _, pc in ipairs(entry.pumpControlEntries) do
                if pc.node ~= nil then table.insert(hostNodes, { node = pc.node, radius = pc.radius }) end
            end
        end
        for _, h in ipairs(hostNodes) do
            local sba = SPSShearBoltActivatable.new(vehicle, h.node, h.radius)
            table.insert(entry.shearBoltActivatables, sba)
            g_currentMission.activatableObjectsSystem:addActivatable(sba)
        end
        if SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil then
            SPSShearBolt.dbg(string.format("repair activatable: created %d on %s (%d outsideControl, %d pumpControl host nodes)",
                #entry.shearBoltActivatables, tostring(vehicle.configFileName),
                #entry.outsideControlEntries, #entry.pumpControlEntries))
        end
    elseif SPSShearBolt ~= nil and SPSShearBolt.DEBUG and SPSShearBolt.dbg ~= nil then
        if entry.shearBolt ~= true then
            SPSShearBolt.dbg("repair activatable NOT created — <shearBolt bolt=\"true\"/> not set for "
                .. tostring(vehicle.configFileName) .. " (this vehicle has no shear bolt)")
        else
            SPSShearBolt.dbg("repair activatable NOT created — SPSShearBoltActivatable is nil (is SPSShearBoltActivatable.lua sourced in modDesc?)")
        end
    end

    -- Load engine loop sound for selfPowered vehicles
    entry.engineLoopSample = nil
    if entry.selfPowered and vehicle.isClient then
        local soundKey = kp .. "slurryPipeSystem.sounds.engineLoop"
        if xmlFile:hasProperty(soundKey) then
            entry.engineLoopSample = g_soundManager:loadSampleFromXML(
                xmlFile, kp .. "slurryPipeSystem.sounds", "engineLoop",
                vehicle.baseDirectory, vehicle.components, 0,
                AudioGroup.VEHICLE, vehicle.i3dMappings, vehicle)
            if entry.engineLoopSample ~= nil then
            else
                print("[SPS] engineLoop sound failed to load for " .. tostring(vehicle.configFileName))
            end
        end
    end

    -- Vacuum pump sounds: slurry01 while filling, slurry02 when full (then back to
    -- slurry01 when emptying). Samples reference base-game sound TEMPLATES by name
    -- (requiresFile=false), so nothing is copied and no base file is edited. Only on
    -- vacuum tanks; play/stop is driven per-tick by updatePumpSounds.
    entry.vacPumpFilling   = nil
    entry.vacPumpFull      = nil
    entry.vacFullThreshold = 0.99
    entry._vacSoundState   = "off"
    if vehicle.isClient and xmlFile:getString(kp .. "slurryPipeSystem.pump#pumpType") == "vacuum" then
        local sndKey = kp .. "slurryPipeSystem.sounds"
        entry.vacFullThreshold = xmlFile:getFloat(sndKey .. "#fullThreshold", 0.99)
        if xmlFile:hasProperty(sndKey .. ".vacPumpFilling") then
            entry.vacPumpFilling = g_soundManager:loadSampleFromXML(
                xmlFile, sndKey, "vacPumpFilling",
                vehicle.baseDirectory, vehicle.components, 0,
                AudioGroup.VEHICLE, vehicle.i3dMappings, vehicle, false)
        end
        if xmlFile:hasProperty(sndKey .. ".vacPumpFull") then
            entry.vacPumpFull = g_soundManager:loadSampleFromXML(
                xmlFile, sndKey, "vacPumpFull",
                vehicle.baseDirectory, vehicle.components, 0,
                AudioGroup.VEHICLE, vehicle.i3dMappings, vehicle, false)
        end
        if entry.vacPumpFilling ~= nil or entry.vacPumpFull ~= nil then
            --print("[SPS] vac pump sounds loaded for " .. tostring(vehicle.configFileName)
                --.. " (fullThreshold=" .. tostring(entry.vacFullThreshold) .. ")")
        end
    end

    -- Build sourceEntry now so chain termini and conduit resolution can use it.
    -- fillUnitIndex comes from first arm (if any) or first coupling.
    if vehicle.spec_fillVolume ~= nil then
        local fillUnitIndex = 1
        if #entry.armEntries > 0 then
            fillUnitIndex = entry.armEntries[1].fillUnitIndex
        elseif #entry.couplingEntries > 0 then
            fillUnitIndex = entry.couplingEntries[1].fillUnitIndex
        end
        local builtSource = SlurryNodeUtil.buildFillVolumeSource(vehicle, fillUnitIndex)
        if builtSource ~= nil then
            entry.sourceEntry = builtSource
            table.insert(self.sourceEntries, builtSource)
            for _, c in ipairs(entry.couplingEntries) do
                c.sourceEntry = builtSource
            end
        end
    end

    -- Create conduit HUD extension if this is a conduit pump and client-side
    entry.hudExtension = nil
    if entry.conduit and vehicle.isClient and SPSConduitHUDExtension ~= nil then
        entry.hudExtension = SPSConduitHUDExtension.new(vehicle)
    end

    -- Agitator: optional tip node declared in fillPoints.xml
    -- Works for any vehicle type — no specialization required
    entry.agitatorTipNode = nil
    entry.agitatorIsActive = false
    local agitatorTipNodeName = xmlFile:getString(kp .. "slurryPipeSystem.agitator#tipNode", nil)
    if agitatorTipNodeName ~= nil then
        local compRoot = vehicle.components ~= nil and vehicle.components[1] ~= nil
            and vehicle.components[1].node or nil
        if compRoot ~= nil then
            local matches = {}
            spsFindAllInTree(compRoot, agitatorTipNodeName, matches)
            if #matches > 0 then
                entry.agitatorTipNode = matches[1]
                SlurryDebug.log("registerVehicle: agitator tipNode '" .. agitatorTipNodeName .. "' found for " .. tostring(vehicle.configFileName))
            else
                --print("[SPS] registerVehicle: agitator tipNode '" .. agitatorTipNodeName .. "' not found in " .. tostring(vehicle.configFileName))
            end
        end
    end

    -- Add WATER fillType support for water intake via fill arms
    -- (SPS-registered vehicles can load water from lakes/ponds using arms)
    if vehicle.spec_fillUnit ~= nil then
        for _, fillUnit in ipairs(vehicle.spec_fillUnit.fillUnits) do
            if fillUnit.supportedFillTypes ~= nil then
                fillUnit.supportedFillTypes[FillType.WATER] = true
            end
        end
        SlurryDebug.log("registerVehicle - added WATER fillType support to " .. tostring(vehicle.configFileName))
    end

    -- A registration that carries ONLY blockage nodes (no fill arms, no couplings) is
    -- a spreader implement (e.g. the sbh4_36 dribble bar registered for its blockage
    -- nodes), NOT a slurry tanker in its own right. findAttachedDribbleBars relies on
    -- this so the controlling tanker can still discover and drive such a bar even though
    -- it is now SPS-registered.
    entry.isSpreaderImplement = (#entry.armEntries == 0)
        and (#entry.couplingEntries == 0)
        and (entry.blockageEntries ~= nil and #entry.blockageEntries > 0)

    -- A spreader implement (dribble bar) is registered ONLY to carry blockage nodes.
    -- It must not have a pressure system of its own: clearing entry.pressure makes
    -- updatePressure, isSpreaderDischargeActive and the HUD gauge all skip it (exactly
    -- like an openTop vessel), so it can never build phantom vacuum/pressure or fire its
    -- own spreader gating. Its controlling tanker drives everything.
    if entry.isSpreaderImplement then
        entry.pressure = nil
    end

    table.insert(self.registeredVehicles, entry)
    if entry.xmlFileOwned then xmlFile:delete() end
    SlurryDebug.log("SlurryPipeManager:registerVehicle - registered " .. tostring(vehicle.configFileName))
    self:tryResolvePendingConnections()
end

-- ---------------------------------------------------------------------------
-- unregisterVehicle
-- ---------------------------------------------------------------------------
function SlurryPipeManager:unregisterVehicle(vehicle)
    for i, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            self:stopFlow(vehicle)
            -- Force-disconnect and destroy any active pipe visuals on this vehicle's couplings
            for _, coupling in ipairs(entry.couplingEntries) do
                if coupling.isConnected then
                    self:_forceDisconnect(vehicle, coupling)
                end
            end
            -- Disconnect and destroy any active pipe visuals on this vehicle's couplings
            for _, coupling in ipairs(entry.couplingEntries) do
                if coupling.isConnected then
                    self:onCouplerDisconnect(vehicle, coupling)
                end
                if coupling.pipeId ~= nil then
                    local pipeData = self.activePipes[coupling.pipeId]
                    if pipeData ~= nil and g_spsPipeVisual ~= nil then
                        g_spsPipeVisual:destroyPipe(pipeData.inst)
                        self.activePipes[coupling.pipeId] = nil
                    end
                    coupling.pipeId = nil
                end
            end
            if entry.sourceEntry ~= nil then
                for j, src in ipairs(self.sourceEntries) do
                    if src == entry.sourceEntry then table.remove(self.sourceEntries, j) break end
                end
            end
            for _, rbpEntry in ipairs(entry.rubberBootPortEntries) do
                for j, rbp in ipairs(self.rubberBootPortEntries) do
                    if rbp == rbpEntry then table.remove(self.rubberBootPortEntries, j) break end
                end
            end
            if entry.pipeEffects ~= nil then
                g_effectManager:deleteEffects(entry.pipeEffects)
                entry.pipeEffects = nil
            end
            -- Clean up coupling activatables
            if entry.pipeActivatables ~= nil then
                for _, activatable in ipairs(entry.pipeActivatables) do
                    activatable:delete()
                end
                entry.pipeActivatables = nil
            end
            if entry.chainActivatables ~= nil then
                for _, activatable in ipairs(entry.chainActivatables) do
                    activatable:delete()
                end
                entry.chainActivatables = nil
            end
            if entry.pumpControlActivatables ~= nil then
                for _, activatable in ipairs(entry.pumpControlActivatables) do
                    activatable:delete()
                end
                entry.pumpControlActivatables = nil
            end
            if entry.outsideControlActivatables ~= nil then
                for _, activatable in ipairs(entry.outsideControlActivatables) do
                    activatable:delete()
                end
                entry.outsideControlActivatables = nil
            end
            if entry.blockageActivatables ~= nil then
                for _, activatable in ipairs(entry.blockageActivatables) do
                    activatable:delete()
                end
                entry.blockageActivatables = nil
            end
            if entry.shearBoltActivatables ~= nil then
                for _, activatable in ipairs(entry.shearBoltActivatables) do
                    activatable:delete()
                end
                entry.shearBoltActivatables = nil
            end
            if entry.engineLoopSample ~= nil then
                g_soundManager:stopSample(entry.engineLoopSample)
                g_soundManager:deleteSample(entry.engineLoopSample)
                entry.engineLoopSample = nil
            end
            if entry.vacPumpFilling ~= nil then
                g_soundManager:stopSample(entry.vacPumpFilling)
                g_soundManager:deleteSample(entry.vacPumpFilling)
                entry.vacPumpFilling = nil
            end
            if entry.vacPumpFull ~= nil then
                g_soundManager:stopSample(entry.vacPumpFull)
                g_soundManager:deleteSample(entry.vacPumpFull)
                entry.vacPumpFull = nil
            end
            if entry.hudExtension ~= nil then
                if g_currentMission ~= nil and g_currentMission.hud ~= nil then
                    g_currentMission.hud:removeInfoExtension(entry.hudExtension)
                end
                entry.hudExtension:delete()
                entry.hudExtension = nil
            end
            if entry.nodeTreeRoot ~= nil and entry.nodeTreeRoot ~= 0 then
                delete(entry.nodeTreeRoot)
                entry.nodeTreeRoot = nil
            end
            if vehicle.spec_fillTriggerVehicle ~= nil
            and vehicle.spec_fillTriggerVehicle.fillTrigger ~= nil then
                vehicle.spec_fillTriggerVehicle.fillTrigger.isEnabled = true
            end
            table.remove(self.registeredVehicles, i)
            SlurryDebug.log("unregisterVehicle - " .. tostring(vehicle.configFileName))
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- registerPlaceable
-- ---------------------------------------------------------------------------
function SlurryPipeManager:registerPlaceable(placeable)
    local config = self:findPlaceableConfigForPlaceable(placeable)
    if config == nil then return end

    -- Embedded vs bundled xml (see registerVehicle for rationale).
    local xmlFile
    local xmlFileOwned = false
    if config.isEmbedded then
        xmlFile = placeable.xmlFile
    else
        xmlFile = XMLFile.load("spsPlaceablePoints", config.xmlFilePath)
        xmlFileOwned = true
    end
    if xmlFile == nil then return end

    local kp = config.xmlKeyPrefix or ""

    -- Optional nodeTree: links SPS nodes onto the placeable hierarchy.
    local linkedNodes = {}
    local nodeTreePath = xmlFile:getString(kp .. "slurryPipeSystem.nodeTree#filename")
    if nodeTreePath ~= nil then
        local configFolder = config.xmlFilePath:match("^(.*[/\\])")
        local fullPath = configFolder .. nodeTreePath
        local nodeTreeRoot = loadI3DFile(fullPath)
        if nodeTreeRoot ~= nil and nodeTreeRoot ~= 0 then
            local function findByName(root, name)
                if getName(root) == name then return root end
                for i = 0, getNumOfChildren(root) - 1 do
                    local found = findByName(getChildAt(root, i), name)
                    if found ~= nil then return found end
                end
                return nil
            end
            local searchRoot = placeable.components ~= nil
                and placeable.components[1] ~= nil
                and placeable.components[1].node or nil
            local spsRoot = getChildAt(nodeTreeRoot, 0)
            if spsRoot ~= nil and spsRoot ~= 0 and searchRoot ~= nil then
                for groupIdx = 0, getNumOfChildren(spsRoot) - 1 do
                    local group = getChildAt(spsRoot, groupIdx)
                    for containerIdx = 0, getNumOfChildren(group) - 1 do
                        local container  = getChildAt(group, containerIdx)
                        local targetName = getName(container)
                        local liveParent = findByName(searchRoot, targetName)
                        if liveParent ~= nil then
                            local children = {}
                            for childIdx = 0, getNumOfChildren(container) - 1 do
                                table.insert(children, getChildAt(container, childIdx))
                            end
                            for _, spsNode in ipairs(children) do
                                removeFromPhysics(spsNode)
                                link(liveParent, spsNode)
                                addToPhysics(spsNode)
                                table.insert(linkedNodes, spsNode)
                            end
                        else
                            --print("[SPS] registerPlaceable: container target '" .. targetName .. "' not found in placeable")
                        end
                    end
                end
            end
            delete(nodeTreeRoot)
        else
            print("[SPS] registerPlaceable: failed to load nodeTree: " .. tostring(fullPath))
        end
    end

    local function findLinkedNode(name)
        if name == nil or name == "" then return nil end
        for _, n in ipairs(linkedNodes) do
            if getName(n) == name then return n end
        end
        return nil
    end

    -- Recursive search through a node tree collecting ALL nodes matching name
    local function findAllInTree(root, name, results)
        if root == nil or root == 0 then return end
        if getName(root) == name then table.insert(results, root) end
        for i = 0, getNumOfChildren(root) - 1 do
            findAllInTree(getChildAt(root, i), name, results)
        end
    end

    -- Hide named nodes from the base game i3d. Stored so visibility can be
    -- restored if the mod is removed while the placeable remains in the world.
    local hiddenNodes = {}
    local hideIndex = 0
    while true do
        local hKey = string.format(kp .. "slurryPipeSystem.hideNodes.node(%d)", hideIndex)
        if not xmlFile:hasProperty(hKey) then break end
        local nodeName = xmlFile:getString(hKey .. "#name")
        if nodeName ~= nil and nodeName ~= "" then
            local compRoot = placeable.components ~= nil
                and placeable.components[1] ~= nil
                and placeable.components[1].node or nil
            if compRoot ~= nil then
                local matches = {}
                findAllInTree(compRoot, nodeName, matches)
                if #matches > 0 then
                    for _, found in ipairs(matches) do
                        setVisibility(found, false)
                        table.insert(hiddenNodes, found)
                    end
                else
                    print("[SPS] registerPlaceable: hideNode '" .. nodeName .. "' not found in " .. tostring(placeable.configFileName))
                end
            end
        end
        hideIndex = hideIndex + 1
    end

    -- Disable collisions on named nodes independently of visibility.
    -- Uses setCompoundChildActive(node, false) — stored for restore on unregister.
    local hiddenCollisions = {}
    local hideCollIndex = 0
    while true do
        local hKey = string.format(kp .. "slurryPipeSystem.hideCollisions.node(%d)", hideCollIndex)
        if not xmlFile:hasProperty(hKey) then break end
        local nodeName  = xmlFile:getString(hKey .. "#name")
        -- Try i3d index path first (node="0>18|0|2|0|5|1"), then fall back to name search
        local indexNode = xmlFile:getNode(hKey .. "#node", nil, placeable.components, placeable.i3dMappings)
        if indexNode ~= nil and indexNode ~= 0 then
            removeFromPhysics(indexNode)
            table.insert(hiddenCollisions, indexNode)
        elseif nodeName ~= nil and nodeName ~= "" then
            local compRoot = placeable.components ~= nil
                and placeable.components[1] ~= nil
                and placeable.components[1].node or nil
            if compRoot ~= nil then
                local matches = {}
                findAllInTree(compRoot, nodeName, matches)
                if #matches > 0 then
                    for _, found in ipairs(matches) do
                        removeFromPhysics(found)
                        table.insert(hiddenCollisions, found)
                    end
                else
                    print("[SPS] registerPlaceable: hideCollision '" .. nodeName .. "' not found in " .. tostring(placeable.configFileName))
                end
            end
        end
        hideCollIndex = hideCollIndex + 1
    end

    local fillPlaneNode = xmlFile:getNode(kp .. "slurryPipeSystem.fillPlane#node", nil, placeable.components, placeable.i3dMappings)
    print("[SPS fillPlane debug] " .. tostring(placeable.configFileName)
        .. " fillPlaneNode=" .. tostring(fillPlaneNode)
        .. " components=" .. tostring(placeable.components ~= nil)
        .. " i3dMappings=" .. tostring(placeable.i3dMappings ~= nil)
        .. " nodeAttr=" .. tostring(xmlFile:getString(kp .. "slurryPipeSystem.fillPlane#node", "MISSING")))
    local minY          = xmlFile:getFloat(kp .. "slurryPipeSystem.fillPlane#minY", 0)
    local maxY          = xmlFile:getFloat(kp .. "slurryPipeSystem.fillPlane#maxY", 1)
    local fillTypeName  = xmlFile:getString(kp .. "slurryPipeSystem.fillPlane#fillType", "LIQUIDMANURE")
    local fillType = g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or FillType.LIQUIDMANURE

    -- Build XZ detection bounds from authored nodes in the nodeTree.
    -- round:     centreNode + edgeNode      (radius = XZ dist between them)
    -- rectangle: centreNode + corner1/2     (bounds in centreNode local space)
    -- Y of these nodes is irrelevant — only XZ is used for detection.
    local planeBounds    = nil
    local planeShape     = xmlFile:getString(kp .. "slurryPipeSystem.fillPlane#shape", nil)
    local centreNodeName = xmlFile:getString(kp .. "slurryPipeSystem.fillPlane#centreNodeName", nil)
    local centreNode     = findLinkedNode(centreNodeName)

    if planeShape == "round" then
        local edgeNode = findLinkedNode(xmlFile:getString(kp .. "slurryPipeSystem.fillPlane#edgeNodeName", nil))
        if centreNode ~= nil and edgeNode ~= nil then
            local cx, _, cz = getWorldTranslation(centreNode)
            local ex, _, ez = getWorldTranslation(edgeNode)
            local radius = math.sqrt((cx - ex) * (cx - ex) + (cz - ez) * (cz - ez))
            planeBounds = { shape = "round", centreNode = centreNode, radius = radius }
        else
            print("[SPS] registerPlaceable: shape=round but centreNode or edgeNode missing")
        end
    elseif planeShape == "rectangle" then
        local corner1Node = findLinkedNode(xmlFile:getString(kp .. "slurryPipeSystem.fillPlane#corner1NodeName", nil))
        local corner2Node = findLinkedNode(xmlFile:getString(kp .. "slurryPipeSystem.fillPlane#corner2NodeName", nil))
        if centreNode ~= nil and corner1Node ~= nil and corner2Node ~= nil then
            local c1x, c1y, c1z = getWorldTranslation(corner1Node)
            local c2x, c2y, c2z = getWorldTranslation(corner2Node)
            local lx1, _, lz1 = worldToLocal(centreNode, c1x, c1y, c1z)
            local lx2, _, lz2 = worldToLocal(centreNode, c2x, c2y, c2z)
            planeBounds = {
                shape      = "rectangle",
                centreNode = centreNode,
                minX       = math.min(lx1, lx2),
                maxX       = math.max(lx1, lx2),
                minZ       = math.min(lz1, lz2),
                maxZ       = math.max(lz1, lz2),
            }
        else
            print("[SPS] registerPlaceable: shape=rectangle but centreNode or corner nodes missing")
        end
    elseif planeShape ~= nil then
        print("[SPS] registerPlaceable: unknown shape '" .. tostring(planeShape) .. "'")
    end

    local sourceEntry = nil
    if fillPlaneNode ~= nil and (placeable.spec_silo ~= nil or placeable.spec_husbandry ~= nil or placeable.spec_siloExtension ~= nil) then
        sourceEntry = SlurryNodeUtil.buildStoragePlaneSource(placeable, fillPlaneNode, minY, maxY, fillType, planeBounds)
    elseif fillPlaneNode == nil and (placeable.spec_husbandry ~= nil or placeable.spec_productionPoint ~= nil) then
        -- No fill plane authored — husbandry/production point placeable with coupling-only access.
        -- Build a minimal sourceEntry so coupling flow can read/write the storage
        -- even though arm surface detection is not possible.
        local storage = nil
        local sh = placeable.spec_husbandry
        if sh ~= nil and sh.storage ~= nil and type(sh.storage.getFillLevel) == "function" then
            storage = sh.storage
        end
        if storage == nil and placeable.spec_productionPoint ~= nil
        and placeable.spec_productionPoint.productionPoint ~= nil
        and placeable.spec_productionPoint.productionPoint.storage ~= nil then
            storage = placeable.spec_productionPoint.productionPoint.storage
        end
        if storage ~= nil then
            sourceEntry = {
                type      = SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE,
                placeable = placeable,
                storage   = storage,
                fillPlaneNode = nil,
                minY      = 0,
                maxY      = 1,
                fillType  = fillType,
                planeBounds = nil,
                debugLabel = tostring(placeable.configFileName):match("([^/]+)%.xml$") or "placeable",
            }
            SlurryDebug.log("registerPlaceable: coupling-only sourceEntry for " .. tostring(placeable.configFileName))
        else
            SlurryDebug.log("registerPlaceable: no storage found for coupling-only placeable " .. tostring(placeable.configFileName))
        end
    end
    if sourceEntry ~= nil then
        table.insert(self.sourceEntries, sourceEntry)
    end

    -- Pipe couplings: mountNodeName (nodeTree) or node+offset (i3dMapping legacy)
    local storeCouplings = {}
    local couplingIndex  = 0

    -- Helper used in per-coupling effect building below
    local function findChildByName(parent, name)
        for i = 0, getNumOfChildren(parent) - 1 do
            local child = getChildAt(parent, i)
            if getName(child) == name then return child end
            local found = findChildByName(child, name)
            if found ~= nil then return found end
        end
    end

    while true do
        local cKey = string.format(kp .. "slurryPipeSystem.pipeCouplings.pipeCoupling(%d)", couplingIndex)
        if not xmlFile:hasProperty(cKey) then break end
        local couplingId    = xmlFile:getInt(cKey .. "#id", couplingIndex + 1)
        local mountNodeName = xmlFile:getString(cKey .. "#mountNodeName")
        local mountNode, arcNode

        if mountNodeName ~= nil then
            mountNode = findLinkedNode(mountNodeName)
            arcNode   = nil
            if mountNode == nil then
                print("[SPS] registerPlaceable: mountNodeName '" .. mountNodeName .. "' not found in linkedNodes, skipping")
                couplingIndex = couplingIndex + 1
                continue
            end
        else
            local parentNodeId = xmlFile:getNode(cKey .. "#node", nil, placeable.components, placeable.i3dMappings)
            if parentNodeId ~= nil then
                local ox = xmlFile:getFloat(cKey .. "#offsetX", 0)
                local oy = xmlFile:getFloat(cKey .. "#offsetY", 0)
                local oz = xmlFile:getFloat(cKey .. "#offsetZ", 0)
                if ox ~= 0 or oy ~= 0 or oz ~= 0 then
                    mountNode = SlurryNodeUtil.injectTransformNode(parentNodeId, ox, oy, oz, "sps_store_coupling" .. tostring(couplingId))
                else
                    mountNode = parentNodeId
                end
                arcNode = parentNodeId
            end
        end

        if mountNode ~= nil then
            local deployable = xmlFile:getBool(cKey .. "#deployable", false)

            -- undeployedVisibleNodes: space-separated list of node names.
            -- Searches deep through all linked node subtrees (not just direct links).
            local function findDeepLinkedNode(name)
                if name == nil or name == "" then return nil end
                for _, root in ipairs(linkedNodes) do
                    local function deepSearch(n)
                        if n == nil or n == 0 then return nil end
                        if getName(n) == name then return n end
                        for i = 0, getNumOfChildren(n) - 1 do
                            local found = deepSearch(getChildAt(n, i))
                            if found ~= nil then return found end
                        end
                        return nil
                    end
                    local found = deepSearch(root)
                    if found ~= nil then return found end
                end
                return nil
            end

            local undeployedVisibleNodes = {}
            local undeployedStr = xmlFile:getString(cKey .. "#undeployedVisibleNode", nil)
            if undeployedStr ~= nil then
                for nodeName in undeployedStr:gmatch("%S+") do
                    local n = findDeepLinkedNode(nodeName)
                    if n ~= nil then
                        table.insert(undeployedVisibleNodes, n)
                    else
                        print("[SPS] registerPlaceable: undeployedVisibleNode '" .. nodeName .. "' not found for coupling id=" .. tostring(couplingId))
                    end
                end
            end

            local sc = {
                id                       = couplingId,
                mountNode                = mountNode,
                arcNode                  = arcNode,
                inNode                   = nil,
                outNode                  = nil,
                valveType                = xmlFile:getString(cKey .. "#valveType", SPS_VALVE_TYPE_MANUAL),
                flowDirection            = xmlFile:getString(cKey .. "#flowDirection", "BOTH"),
                connectorType            = xmlFile:getString(cKey .. "#connector", "female"),
                connectorAnimationId     = xmlFile:getInt(cKey .. "#connectorAnimation"),
                valveAnimationId         = xmlFile:getInt(cKey .. "#valveAnimation"),
                isConnected              = false,
                valveOpen                = false,
                connectedTarget          = nil,
                connectedPartnerCoupling = nil,
                pipeId                   = nil,
                sourceEntry              = sourceEntry,
                placeable                = placeable,
                deployable               = deployable,
                isDeployed               = not deployable,
                pipeEffects              = nil,
                inletDistance            = 1.5,
                effectPlaying            = false,
                undeployedVisibleNodes   = undeployedVisibleNodes,
            }
            -- Find inNode and outNode children of the mountNode
            for i = 0, getNumOfChildren(mountNode) - 1 do
                local child = getChildAt(mountNode, i)
                local childName = getName(child)
                if childName == "inNode" then
                    sc.inNode = child
                elseif childName == "outNode" then
                    sc.outNode = child
                end
            end
            -- Bind coupler animations if either id is declared on this coupling.
            if SPSCouplerAnimator ~= nil
            and (sc.connectorAnimationId ~= nil or sc.valveAnimationId ~= nil) then
                SPSCouplerAnimator.ensureLoaded(self.modDirectory)
                if sc.connectorAnimationId ~= nil then
                    sc.connectorAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.connectorAnimationId)
                end
                if sc.valveAnimationId ~= nil then
                    sc.valveAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.valveAnimationId)
                end
            end
            -- Deployable couplings start hidden; undeployedVisibleNodes start visible
            if deployable then
                setVisibility(sc.mountNode, false)
                removeFromPhysics(sc.mountNode)
                for _, n in ipairs(undeployedVisibleNodes) do
                    setVisibility(n, true)
                end
            end

            -- Build inlet pipe effects for this coupling if declared
            local effectNodeName = xmlFile:getString(cKey .. ".effects.effectNode(0)#effectNode")
            local smokeNodeName  = xmlFile:getString(cKey .. ".effects.effectNode(1)#effectNode")
            sc.inletDistance     = xmlFile:getFloat(cKey .. ".effects#inletDistance", 1.5)
            if g_client ~= nil and effectNodeName ~= nil and smokeNodeName ~= nil then
                local effectNode = findLinkedNode(effectNodeName)
                if effectNode ~= nil then
                    local smokeNode = findChildByName(effectNode, smokeNodeName)
                    if smokeNode ~= nil then
                        if g_effectManager:getEffectClass("PipeEffect") == nil and PipeEffect ~= nil then
                            g_effectManager:registerEffectClass("PipeEffect", PipeEffect)
                        end
                        if g_effectManager:getEffectClass("ShaderPlaneEffect") == nil and ShaderPlaneEffect ~= nil then
                            g_effectManager:registerEffectClass("ShaderPlaneEffect", ShaderPlaneEffect)
                        end
                        local effects = {}
                        local pe = PipeEffect.new()
                        pe.parent             = placeable
                        pe.baseDirectory      = placeable.baseDirectory or ""
                        pe.rootNodes          = effectNode
                        pe.node               = getChildAt(effectNode, 0)
                        pe.maxBending         = 0.8
                        pe.extraDistance      = 0.1
                        pe.updateDistance     = true
                        pe.distance           = 0
                        pe.controlPointY      = 0
                        pe.worldTarget        = { 0, 0, 0 }
                        pe.controlPoint       = { 10, 0.25, 0, 0 }
                        pe.shapeScaleSpread   = { 0.6, 1, 1, 0 }
                        pe.uvScaleSpeedFreqAmp = nil
                        pe.positionUpdateNodes = { smokeNode }
                        pe.materialType       = "spsSlurryPipe"
                        pe.materialTypeId     = 1
                        pe.dynamicFillType    = false
                        pe.hasValidMaterial   = false
                        pe.lastFillTypeIndex  = nil
                        pe.fadeInTime         = 1000
                        pe.fadeOutTime        = 1000
                        pe.startDelay         = 0
                        pe.stopDelay          = 0
                        pe.currentDelay       = 0
                        pe.state              = ShaderPlaneEffect.STATE_OFF
                        pe.planeFadeTime      = 1000
                        pe.fadeCur            = { -1, 1 }
                        pe.fadeDir            = { 1, 1 }
                        pe.fadeX              = { -1, 1 }
                        pe.fadeY              = { -1, 1 }
                        pe.alwaysVisibile     = false
                        pe.showOnFirstUse     = false
                        pe.prio               = 0
                        pe.deleteListeners    = {}
                        pe.startRestriction   = {}
                        pe.allowUpdate        = true
                        pe.lastUpdateTime     = 0
                        setVisibility(pe.node, false)
                        g_effectManager:setUpdateDistance({ pe }, math.huge)
                        if g_spsSlurryMaterial ~= nil then
                            setMaterial(pe.node, g_spsSlurryMaterial, 0)
                            pe.hasValidMaterial = true
                            pe.useBaseMaterial  = true
                        end
                        table.insert(effects, pe)
                        local se = ShaderPlaneEffect.new()
                        se.parent             = placeable
                        se.baseDirectory      = placeable.baseDirectory or ""
                        se.rootNodes          = smokeNode
                        se.node               = smokeNode
                        se.materialType       = "unloadingSmoke"
                        se.materialTypeId     = 1
                        se.dynamicFillType    = false
                        se.hasValidMaterial   = false
                        se.lastFillTypeIndex  = nil
                        se.fadeInTime         = 1000
                        se.fadeOutTime        = 1000
                        se.startDelay         = 100
                        se.stopDelay          = 100
                        se.currentDelay       = 100
                        se.state              = ShaderPlaneEffect.STATE_OFF
                        se.planeFadeTime      = 1000
                        se.fadeCur            = { -1, 1 }
                        se.fadeDir            = { 1, 1 }
                        se.fadeX              = { -1, 1 }
                        se.fadeY              = { -1, 1 }
                        se.alignToWorldY      = true
                        se.alignXAxisToWorldY = false
                        se.alwaysVisibile     = false
                        se.showOnFirstUse     = false
                        se.prio               = 0
                        se.deleteListeners    = {}
                        se.startRestriction   = {}
                        se.allowUpdate        = true
                        se.lastUpdateTime     = 0
                        setVisibility(smokeNode, false)
                        g_effectManager:setUpdateDistance({ se }, math.huge)
                        table.insert(effects, se)
                        sc.pipeEffects = effects
                        print("[SPS] registerPlaceable: inlet effects built for coupling id=" .. tostring(couplingId) .. " on " .. tostring(placeable.configFileName))
                    else
                        print("[SPS] registerPlaceable: smokeNode '" .. tostring(smokeNodeName) .. "' not found under effect TG for coupling id=" .. tostring(couplingId))
                    end
                else
                    print("[SPS] registerPlaceable: effectNode '" .. tostring(effectNodeName) .. "' not found in linkedNodes for coupling id=" .. tostring(couplingId))
                end
            end

            table.insert(storeCouplings, sc)
            local activatable = SPSPipeActivatable.new(nil, sc)
            sc.activatable = activatable
            g_currentMission.activatableObjectsSystem:addActivatable(activatable)
            local chainAct = SPSChainActivatable.new(nil, 0, sc)
            sc.chainActivatable = chainAct
            g_currentMission.activatableObjectsSystem:addActivatable(chainAct)
        end
        couplingIndex = couplingIndex + 1
    end

    local pEntry = {
        placeable        = placeable,
        config           = config,
        sourceEntry      = sourceEntry,
        storeCouplings   = storeCouplings,
        linkedNodes      = linkedNodes,
        hiddenNodes      = hiddenNodes,
        hiddenCollisions = hiddenCollisions,
        agitatorEnabled  = xmlFile:getBool(kp .. "slurryPipeSystem#agitator", false),
        crustConfig      = SPSCrustVegetation ~= nil and SPSCrustVegetation.readConfig(xmlFile) or nil,
        crustInstances   = nil,
        pipeAnimNode     = xmlFile:getNode(kp .. "slurryPipeSystem.pipeAnimNode#node", nil, placeable.components, placeable.i3dMappings),
        pipeAnimRX       = math.rad(xmlFile:getFloat(kp .. "slurryPipeSystem.pipeAnimNode#rx", 0)),
        pipeAnimRY       = math.rad(xmlFile:getFloat(kp .. "slurryPipeSystem.pipeAnimNode#ry", 0)),
        pipeAnimRZ       = math.rad(xmlFile:getFloat(kp .. "slurryPipeSystem.pipeAnimNode#rz", 0)),
        config           = config,
        xmlFileOwned     = xmlFileOwned,
    }
    table.insert(self.registeredPlaceables, pEntry)
    if xmlFileOwned then xmlFile:delete() end
    SlurryDebug.log("registerPlaceable - registered " .. tostring(placeable.configFileName))

    -- Mark whether this store participates in the thickness model, then restore its
    -- saved two-pool state if available (migrating old single-thickness saves).
    if sourceEntry ~= nil and sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        sourceEntry.thickeningEnabled = pEntry.agitatorEnabled == true
    end
    if self._pendingThickness ~= nil and sourceEntry ~= nil then
        local compNode = placeable.components ~= nil and placeable.components[1] ~= nil
            and placeable.components[1].node or nil
        if compNode ~= nil then
            local px, py, pz = getWorldTranslation(compNode)
            for i, pt in ipairs(self._pendingThickness) do
                local dx, dy, dz = px - pt.px, py - pt.py, pz - pt.pz
                if (dx*dx + dy*dy + dz*dz) <= 1.0 then
                    sourceEntry.thicknessDayCount = pt.dayCount
                    if pt.hasPools then
                        sourceEntry.solids = pt.solids
                        sourceEntry.settle = pt.settle
                    else
                        -- Old #thickness gauge: treat it as settling (mixable) and let
                        -- solids lazy-init at fresh DM.
                        sourceEntry._migratedSettle = pt.thickness
                    end
                    table.remove(self._pendingThickness, i)
                    SlurryDebug.log("[SPS Thickness] restored store pools for " .. tostring(placeable.configFileName))
                    break
                end
            end
        end
    end

    self:tryResolvePendingConnections()

    -- Scatter crust vegetation on the fill plane if configured
    if pEntry.crustConfig ~= nil and SPSCrustVegetation ~= nil then
        SPSCrustVegetation.initForPlaceable(pEntry, self.modDirectory)
    end
end

-- ---------------------------------------------------------------------------
-- unregisterPlaceable
-- ---------------------------------------------------------------------------
function SlurryPipeManager:unregisterPlaceable(placeable)
    for i, entry in ipairs(self.registeredPlaceables) do
        if entry.placeable == placeable then
            if entry.sourceEntry ~= nil then
                for j, src in ipairs(self.sourceEntries) do
                    if src == entry.sourceEntry then table.remove(self.sourceEntries, j) break end
                end
            end
            if entry.storeCouplings ~= nil then
                for _, sc in ipairs(entry.storeCouplings) do
                    -- Disconnect any pipes connected to this coupling
                    if sc.isConnected then
                        -- Close valve first to allow disconnect
                        sc.valveOpen = false
                        if sc.connectedPartnerCoupling ~= nil then
                            sc.connectedPartnerCoupling.valveOpen = false
                        end
                        -- applyDisconnect handles nil vehicle for placeables
                        self:applyDisconnect(nil, sc.id, sc)
                    end
                    -- Remove any pipe chains anchored at this coupling
                    if sc.pipeChain ~= nil and SPSPipeChain ~= nil then
                        SPSPipeChain.delete(sc.pipeChain)
                        sc.pipeChain = nil
                    end
                    if sc.pipeEffects ~= nil then
                        g_effectManager:stopEffects(sc.pipeEffects)
                        g_effectManager:deleteEffects(sc.pipeEffects)
                        sc.pipeEffects = nil
                    end
                    if sc.activatable ~= nil then sc.activatable:delete() end
                    if sc.chainActivatable ~= nil then sc.chainActivatable:delete() end
                end
            end
            if entry.hiddenNodes ~= nil then
                for _, nodeId in ipairs(entry.hiddenNodes) do
                    if nodeId ~= nil and nodeId ~= 0 then
                        setVisibility(nodeId, true)
                        addToPhysics(nodeId)
                    end
                end
            end
            if entry.hiddenCollisions ~= nil then
                for _, nodeId in ipairs(entry.hiddenCollisions) do
                    if nodeId ~= nil and nodeId ~= 0 then
                        addToPhysics(nodeId)
                    end
                end
            end
            if entry.linkedNodes ~= nil then
                for _, nodeId in ipairs(entry.linkedNodes) do
                    if nodeId ~= nil and nodeId ~= 0 then delete(nodeId) end
                end
            end
            if SPSCrustVegetation ~= nil then
                SPSCrustVegetation.deleteForPlaceable(entry)
            end
            table.remove(self.registeredPlaceables, i)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Save / Load coupling connections
-- ---------------------------------------------------------------------------

-- Called from SPSMod:saveMap. Writes all currently connected couplings to XML.
-- Each connection is identified by the world position of both mount nodes.
-- Position is stable across save/load for both placeables and vehicles
-- (vehicles are at their parked position when saving).
function SlurryPipeManager:saveCouplingConnections(savePath)
    local xmlFile = XMLFile.create("spsSave", savePath, "slurryPipeSystem")
    if xmlFile == nil then
        print("[SPS] saveCouplingConnections: failed to create " .. tostring(savePath))
        return
    end

    local idx = 0
    local written = 0

    -- Walk every vehicle coupling. Only write one side (isConnected + pipeId set
    -- means this IS the "A" side that owns the pipeId entry).
    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, c in ipairs(vEntry.couplingEntries) do
            if c.isConnected and c.pipeId ~= nil then
                local partner = c.connectedPartnerCoupling
                if partner ~= nil then
                    local ax, ay, az = getWorldTranslation(c.mountNode)
                    local bx, by, bz = getWorldTranslation(partner.mountNode)
                    local base = string.format("slurryPipeSystem.connections.connection(%d)", idx)
                    xmlFile:setFloat(base .. "#ax", ax)
                    xmlFile:setFloat(base .. "#ay", ay)
                    xmlFile:setFloat(base .. "#az", az)
                    xmlFile:setFloat(base .. "#bx", bx)
                    xmlFile:setFloat(base .. "#by", by)
                    xmlFile:setFloat(base .. "#bz", bz)
                    xmlFile:setBool(base .. "#valveOpen", c.valveOpen == true)
                    local pipeData = self.activePipes[c.pipeId]
                    xmlFile:setFloat(base .. "#colorR", pipeData and pipeData.colorR or self.currentPipeColor.r)
                    xmlFile:setFloat(base .. "#colorG", pipeData and pipeData.colorG or self.currentPipeColor.g)
                    xmlFile:setFloat(base .. "#colorB", pipeData and pipeData.colorB or self.currentPipeColor.b)
                    idx = idx + 1
                    written = written + 1
                end
            end
        end
    end

    -- Save pipe chains — skip empty chains (no segments, no docking station)
    local chainSaveIdx = 0
    for _, chain in ipairs(self.pipeChains) do
        local data = chain:getSaveData()
        if #data.segments == 0 and not data.hasDockingStation then
            print("[SPS] saveCouplingConnections: skipping empty chain at anchor ("
                .. string.format("%.2f,%.2f,%.2f", data.anchorX, data.anchorY, data.anchorZ) .. ")")
        else
            local base = string.format("slurryPipeSystem.chains.chain(%d)", chainSaveIdx)
            xmlFile:setFloat(base .. "#anchorX",           data.anchorX)
            xmlFile:setFloat(base .. "#anchorY",           data.anchorY)
            xmlFile:setFloat(base .. "#anchorZ",           data.anchorZ)
            xmlFile:setBool(base  .. "#hasDockingStation", data.hasDockingStation)
            xmlFile:setBool(base  .. "#localStart", data.localStart == true)
            if data.chainStartX ~= nil then
                xmlFile:setFloat(base .. "#chainStartX",  data.chainStartX)
                xmlFile:setFloat(base .. "#chainStartY",  data.chainStartY)
                xmlFile:setFloat(base .. "#chainStartZ",  data.chainStartZ)
                xmlFile:setFloat(base .. "#chainStartRY", data.chainStartRY)
            end
            if data.hasDockingStation then
                xmlFile:setFloat(base .. "#dsSaveX",  data.dsSaveX)
                xmlFile:setFloat(base .. "#dsSaveY",  data.dsSaveY)
                xmlFile:setFloat(base .. "#dsSaveZ",  data.dsSaveZ)
                xmlFile:setFloat(base .. "#dsSaveRX", data.dsSaveRX)
                xmlFile:setFloat(base .. "#dsSaveRY", data.dsSaveRY)
                xmlFile:setFloat(base .. "#dsSaveRZ", data.dsSaveRZ)
            end
            for segIdx, segData in ipairs(data.segments) do
                local segBase = string.format(base .. ".segment(%d)", segIdx - 1)
                xmlFile:setFloat(segBase .. "#x",      segData.x)
                xmlFile:setFloat(segBase .. "#y",      segData.y)
                xmlFile:setFloat(segBase .. "#z",      segData.z)
                xmlFile:setFloat(segBase .. "#rx",     segData.rx)
                xmlFile:setFloat(segBase .. "#ry",     segData.ry)
                xmlFile:setFloat(segBase .. "#rz",     segData.rz)
                xmlFile:setFloat(segBase .. "#colorR", segData.colorR or self.currentPipeColor.r)
                xmlFile:setFloat(segBase .. "#colorG", segData.colorG or self.currentPipeColor.g)
                xmlFile:setFloat(segBase .. "#colorB", segData.colorB or self.currentPipeColor.b)
            end
            chainSaveIdx = chainSaveIdx + 1
        end
    end

    -- Save deployed couplings
    local deployIdx = 0
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
            if sc.deployable and sc.isDeployed and sc.mountNode ~= nil then
                local wx, wy, wz = getWorldTranslation(sc.mountNode)
                local base = string.format("slurryPipeSystem.deployedCouplings.coupling(%d)", deployIdx)
                xmlFile:setFloat(base .. "#x",  wx)
                xmlFile:setFloat(base .. "#y",  wy)
                xmlFile:setFloat(base .. "#z",  wz)
                xmlFile:setInt(base .. "#id",   sc.id)
                deployIdx = deployIdx + 1
            end
        end
        end  -- Close if pEntry.storeCouplings ~= nil
    end

    xmlFile:setInt("slurryPipeSystem#selectedColorIndex", self.currentPipeColorIndex)
    xmlFile:setBool("slurryPipeSystem#realismEnabled", self.realismEnabled)
    xmlFile:setBool("slurryPipeSystem#featureThicknessFlow", self.featureToggles.thicknessFlow ~= false)
    xmlFile:setBool("slurryPipeSystem#featureBlockages",     self.featureToggles.blockages     ~= false)
    xmlFile:setBool("slurryPipeSystem#featureLengthFalloff", self.featureToggles.lengthFalloff ~= false)

    local hs = self.hudSettings or {}
    xmlFile:setBool ("slurryPipeSystem#hudEnabled", hs.enabled ~= false)
    xmlFile:setBool ("slurryPipeSystem#hudImage",   hs.image   ~= false)
    xmlFile:setBool ("slurryPipeSystem#hudFill",    hs.fill    ~= false)
    xmlFile:setBool ("slurryPipeSystem#hudCrust",   hs.crust   ~= false)
    xmlFile:setBool ("slurryPipeSystem#hudThick",   hs.thick   ~= false)
    xmlFile:setBool ("slurryPipeSystem#hudRisk",    hs.risk    ~= false)
    xmlFile:setBool ("slurryPipeSystem#hudPump",    hs.pump    ~= false)
    xmlFile:setFloat("slurryPipeSystem#hudScale",   hs.scale or 1.0)
    if hs.posX ~= nil then xmlFile:setFloat("slurryPipeSystem#hudPosX", hs.posX) end
    if hs.posY ~= nil then xmlFile:setFloat("slurryPipeSystem#hudPosY", hs.posY) end

    -- Save per-placeable slurry thickness and day counter
    local thickIdx = 0
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.sourceEntry ~= nil and pEntry.sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            local se  = pEntry.sourceEntry
            local wx, wy, wz = 0, 0, 0
            if pEntry.placeable ~= nil and pEntry.placeable.components ~= nil
            and pEntry.placeable.components[1] ~= nil then
                wx, wy, wz = getWorldTranslation(pEntry.placeable.components[1].node)
            end
            local base = string.format("slurryPipeSystem.thicknesses.entry(%d)", thickIdx)
            xmlFile:setFloat(base .. "#px",            wx)
            xmlFile:setFloat(base .. "#py",            wy)
            xmlFile:setFloat(base .. "#pz",            wz)
            xmlFile:setFloat(base .. "#solids",        se.solids or 0)
            xmlFile:setFloat(base .. "#settle",        se.settle or 0)
            xmlFile:setInt(base   .. "#dayCount",      se.thicknessDayCount or 0)
            thickIdx = thickIdx + 1
        end
    end

    -- Save connector/valve animation state for every coupling that has one.
    -- Coupling id alone is not unique, so we also save owner type and mount-node position.
    local animIdx = 0
    local function writeAnimState(aBase, slotIndex, slotName, inst)
        if SPSCouplerAnimator == nil or SPSCouplerAnimator.getSaveState == nil then return slotIndex end
        local state = SPSCouplerAnimator.getSaveState(inst)
        if state == nil then return slotIndex end

        local oBase = string.format(aBase .. ".animatedObject(%d)", slotIndex)
        xmlFile:setString(oBase .. "#id",        slotName)
        xmlFile:setInt(oBase    .. "#animId",    state.animId or 0)
        xmlFile:setFloat(oBase  .. "#time",      state.time or 0)
        xmlFile:setInt(oBase    .. "#direction", state.direction or 0)
        xmlFile:setBool(oBase   .. "#playing",   state.playing == true)
        return slotIndex + 1
    end

    local function saveCouplingAnim(c, ownerType)
        if c == nil or c.mountNode == nil or c.mountNode == 0 or not entityExists(c.mountNode) then return end
        if c.connectorAnim == nil and c.valveAnim == nil then return end

        local wx, wy, wz = getWorldTranslation(c.mountNode)
        local aBase = string.format("slurryPipeSystem.couplerAnimations.entry(%d)", animIdx)
        xmlFile:setString(aBase .. "#ownerType", ownerType)
        xmlFile:setFloat(aBase  .. "#x",         wx)
        xmlFile:setFloat(aBase  .. "#y",         wy)
        xmlFile:setFloat(aBase  .. "#z",         wz)
        xmlFile:setInt(aBase    .. "#id",        c.id or -9999)

        local slotIndex = 0
        slotIndex = writeAnimState(aBase, slotIndex, "connector", c.connectorAnim)
        slotIndex = writeAnimState(aBase, slotIndex, "valve",     c.valveAnim)
        if slotIndex > 0 then animIdx = animIdx + 1 end
    end

    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, c in ipairs(vEntry.couplingEntries) do saveCouplingAnim(c, "vehicle") end
    end
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, c in ipairs(pEntry.storeCouplings) do saveCouplingAnim(c, "placeable") end
        end
    end
    for _, c in ipairs(self.chainTerminusEntries) do saveCouplingAnim(c, "chain") end

    -- Save sprayer vehicle animation states
    local sprayerAnimIdx = 0
    for _, sEntry in ipairs(self.registeredSprayerVehicles) do
        if sEntry.object ~= nil and sEntry.state.loadAnimName ~= nil then
            local vehicle = sEntry.object
            if vehicle.getAnimationExists ~= nil and vehicle:getAnimationExists(sEntry.state.loadAnimName) then
                local animTime = vehicle:getAnimationTime(sEntry.state.loadAnimName)
                local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
                local base = string.format("slurryPipeSystem.sprayerAnimations.sprayerAnimation(%d)", sprayerAnimIdx)
                xmlFile:setFloat(base .. "#x", vx)
                xmlFile:setFloat(base .. "#y", vy)
                xmlFile:setFloat(base .. "#z", vz)
                xmlFile:setString(base .. "#animName", sEntry.state.loadAnimName)
                xmlFile:setFloat(base .. "#animTime", animTime)
                sprayerAnimIdx = sprayerAnimIdx + 1
            end
        end
    end

    xmlFile:save()
    xmlFile:delete()
    print("[SPS] saveCouplingConnections: saved " .. written .. " connections, "
        .. #self.pipeChains .. " chains, " .. sprayerAnimIdx .. " sprayer animations to " .. tostring(savePath))
end

-- Called from SPSMod:loadMap after manager is ready.
-- Populates pendingConnections. Each entry is resolved as couplings register.
function SlurryPipeManager:loadCouplingConnections(savePath)
    if not fileExists(savePath) then
        print("[SPS] loadCouplingConnections: no save file at " .. tostring(savePath))
        return
    end

    local xmlFile = XMLFile.load("spsSave", savePath)
    if xmlFile == nil then
        print("[SPS] loadCouplingConnections: failed to load " .. tostring(savePath))
        return
    end

    self.pendingConnections = {}
    local idx = 0
    while true do
        local base = string.format("slurryPipeSystem.connections.connection(%d)", idx)
        if not xmlFile:hasProperty(base) then break end
        local pending = {
            ax        = xmlFile:getFloat(base .. "#ax", 0),
            ay        = xmlFile:getFloat(base .. "#ay", 0),
            az        = xmlFile:getFloat(base .. "#az", 0),
            bx        = xmlFile:getFloat(base .. "#bx", 0),
            by        = xmlFile:getFloat(base .. "#by", 0),
            bz        = xmlFile:getFloat(base .. "#bz", 0),
            valveOpen = xmlFile:getBool(base .. "#valveOpen", false),
            colorR    = xmlFile:getFloat(base .. "#colorR", nil),
            colorG    = xmlFile:getFloat(base .. "#colorG", nil),
            colorB    = xmlFile:getFloat(base .. "#colorB", nil),
        }
        table.insert(self.pendingConnections, pending)
        idx = idx + 1
    end

    -- Restore selected colour index
    local savedIndex = xmlFile:getInt("slurryPipeSystem#selectedColorIndex", 1)
    self:setCurrentPipeColor(savedIndex)

    -- Load chain data
    self.pendingChains = {}
    local chainIdx = 0
    while true do
        local base = string.format("slurryPipeSystem.chains.chain(%d)", chainIdx)
        if not xmlFile:hasProperty(base) then break end
        local chainData = {
            anchorX           = xmlFile:getFloat(base .. "#anchorX", 0),
            anchorY           = xmlFile:getFloat(base .. "#anchorY", 0),
            anchorZ           = xmlFile:getFloat(base .. "#anchorZ", 0),
            hasDockingStation = xmlFile:getBool(base .. "#hasDockingStation", false),
            localStart        = xmlFile:getBool(base .. "#localStart", false),
            dsSaveX           = xmlFile:getFloat(base .. "#dsSaveX",  0),
            dsSaveY           = xmlFile:getFloat(base .. "#dsSaveY",  0),
            dsSaveZ           = xmlFile:getFloat(base .. "#dsSaveZ",  0),
            dsSaveRX          = xmlFile:getFloat(base .. "#dsSaveRX", 0),
            dsSaveRY          = xmlFile:getFloat(base .. "#dsSaveRY", 0),
            dsSaveRZ          = xmlFile:getFloat(base .. "#dsSaveRZ", 0),
            segments          = {},
        }
        if xmlFile:hasProperty(base .. "#chainStartX") then
            chainData.chainStartX  = xmlFile:getFloat(base .. "#chainStartX",  0)
            chainData.chainStartY  = xmlFile:getFloat(base .. "#chainStartY",  0)
            chainData.chainStartZ  = xmlFile:getFloat(base .. "#chainStartZ",  0)
            chainData.chainStartRY = xmlFile:getFloat(base .. "#chainStartRY", 0)
        end
        local segIdx = 0
        while true do
            local segBase = string.format(base .. ".segment(%d)", segIdx)
            if not xmlFile:hasProperty(segBase) then break end
            table.insert(chainData.segments, {
                x      = xmlFile:getFloat(segBase .. "#x",      0),
                y      = xmlFile:getFloat(segBase .. "#y",      0),
                z      = xmlFile:getFloat(segBase .. "#z",      0),
                rx     = xmlFile:getFloat(segBase .. "#rx",     0),
                ry     = xmlFile:getFloat(segBase .. "#ry",     0),
                rz     = xmlFile:getFloat(segBase .. "#rz",     0),
                colorR = xmlFile:getFloat(segBase .. "#colorR", nil),
                colorG = xmlFile:getFloat(segBase .. "#colorG", nil),
                colorB = xmlFile:getFloat(segBase .. "#colorB", nil),
            })
            segIdx = segIdx + 1
        end
        -- Skip empty chains (no segments, no docking station) — nothing to restore
        if #chainData.segments == 0 and not chainData.hasDockingStation then
            print("[SPS] loadCouplingConnections: skipping empty chain at anchor ("
                .. string.format("%.2f,%.2f,%.2f", chainData.anchorX, chainData.anchorY, chainData.anchorZ) .. ")")
        else
            table.insert(self.pendingChains, chainData)
        end
        chainIdx = chainIdx + 1
    end

    -- Load deployed couplings
    self.pendingDeployedCouplings = {}
    local deployIdx = 0
    while true do
        local base = string.format("slurryPipeSystem.deployedCouplings.coupling(%d)", deployIdx)
        if not xmlFile:hasProperty(base) then break end
        table.insert(self.pendingDeployedCouplings, {
            x  = xmlFile:getFloat(base .. "#x",  0),
            y  = xmlFile:getFloat(base .. "#y",  0),
            z  = xmlFile:getFloat(base .. "#z",  0),
            id = xmlFile:getInt(base .. "#id",   0),
        })
        deployIdx = deployIdx + 1
    end

    -- Restore realism settings. Back-compat: older saves used #agitationEnabled as
    -- the single master, so fall back to it for the master's default.
    local legacyMaster = xmlFile:getBool("slurryPipeSystem#agitationEnabled", true)
    self.realismEnabled = xmlFile:getBool("slurryPipeSystem#realismEnabled", legacyMaster)
    self.featureToggles = self.featureToggles or {}
    self.featureToggles.thicknessFlow = xmlFile:getBool("slurryPipeSystem#featureThicknessFlow", true)
    self.featureToggles.blockages     = xmlFile:getBool("slurryPipeSystem#featureBlockages",     true)
    self.featureToggles.lengthFalloff = xmlFile:getBool("slurryPipeSystem#featureLengthFalloff", true)

    self.hudSettings = self.hudSettings or {}
    local hs = self.hudSettings
    hs.enabled = xmlFile:getBool("slurryPipeSystem#hudEnabled", true)
    hs.image   = xmlFile:getBool("slurryPipeSystem#hudImage",   true)
    hs.fill    = xmlFile:getBool("slurryPipeSystem#hudFill",    true)
    hs.crust   = xmlFile:getBool("slurryPipeSystem#hudCrust",   true)
    hs.thick   = xmlFile:getBool("slurryPipeSystem#hudThick",   true)
    hs.risk    = xmlFile:getBool("slurryPipeSystem#hudRisk",    true)
    hs.pump    = xmlFile:getBool("slurryPipeSystem#hudPump",    true)
    hs.scale   = xmlFile:getFloat("slurryPipeSystem#hudScale",  1.0)
    if xmlFile:hasProperty("slurryPipeSystem#hudPosX") then hs.posX = xmlFile:getFloat("slurryPipeSystem#hudPosX", 0.5) end
    if xmlFile:hasProperty("slurryPipeSystem#hudPosY") then hs.posY = xmlFile:getFloat("slurryPipeSystem#hudPosY", 0.985) end

    -- Load thickness data into a pending map keyed by rounded placeable position
    -- Actual application happens in tryResolvePendingConnections after placeables register
    self._pendingThickness = {}
    local thickIdx = 0
    while true do
        local base = string.format("slurryPipeSystem.thicknesses.entry(%d)", thickIdx)
        if not xmlFile:hasProperty(base) then break end
        local hasPools = xmlFile:hasProperty(base .. "#solids")
        table.insert(self._pendingThickness, {
            px        = xmlFile:getFloat(base .. "#px",        0),
            py        = xmlFile:getFloat(base .. "#py",        0),
            pz        = xmlFile:getFloat(base .. "#pz",        0),
            hasPools  = hasPools,
            solids    = xmlFile:getFloat(base .. "#solids",    0),
            settle    = xmlFile:getFloat(base .. "#settle",    0),
            thickness = xmlFile:getFloat(base .. "#thickness", 0),
            dayCount  = xmlFile:getInt(base   .. "#dayCount",  0),
        })
        thickIdx = thickIdx + 1
    end

    -- Load saved coupler animation states.  New format stores owner/position and
    -- per-animation time/direction.  Old #connected saves are still accepted.
    self._pendingCouplerAnims = {}
    local animLoadIdx = 0
    while true do
        local aBase = string.format("slurryPipeSystem.couplerAnimations.entry(%d)", animLoadIdx)
        if not xmlFile:hasProperty(aBase) then break end

        local entry = {
            ownerType = xmlFile:getString(aBase .. "#ownerType", nil),
            x         = xmlFile:getFloat(aBase .. "#x", 0),
            y         = xmlFile:getFloat(aBase .. "#y", 0),
            z         = xmlFile:getFloat(aBase .. "#z", 0),
            id        = xmlFile:getInt(aBase .. "#id", -9999),
            objects   = {},
            applied   = false,
        }

        local objIdx = 0
        while true do
            local oBase = string.format(aBase .. ".animatedObject(%d)", objIdx)
            if not xmlFile:hasProperty(oBase) then break end
            local slotName = xmlFile:getString(oBase .. "#id", "")
            entry.objects[slotName] = {
                animId    = xmlFile:getInt(oBase .. "#animId", 0),
                time      = xmlFile:getFloat(oBase .. "#time", 0),
                direction = xmlFile:getInt(oBase .. "#direction", 0),
                playing   = xmlFile:getBool(oBase .. "#playing", false),
            }
            objIdx = objIdx + 1
        end

        if objIdx == 0 and xmlFile:hasProperty(aBase .. "#connected") then
            entry.legacyConnected = xmlFile:getBool(aBase .. "#connected", false)
        end

        table.insert(self._pendingCouplerAnims, entry)
        animLoadIdx = animLoadIdx + 1
    end

    -- Load sprayer vehicle animation states
    self._pendingSprayerAnimations = {}
    local sprayerAnimLoadIdx = 0
    while true do
        local base = string.format("slurryPipeSystem.sprayerAnimations.sprayerAnimation(%d)", sprayerAnimLoadIdx)
        if not xmlFile:hasProperty(base) then break end
        local entry = {
            x        = xmlFile:getFloat(base .. "#x", 0),
            y        = xmlFile:getFloat(base .. "#y", 0),
            z        = xmlFile:getFloat(base .. "#z", 0),
            animName = xmlFile:getString(base .. "#animName", ""),
            animTime = xmlFile:getFloat(base .. "#animTime", 0),
            applied  = false,
        }
        table.insert(self._pendingSprayerAnimations, entry)
        sprayerAnimLoadIdx = sprayerAnimLoadIdx + 1
    end

    xmlFile:delete()
    print("[SPS] loadCouplingConnections: loaded " .. #self.pendingConnections
        .. " connections, " .. #self.pendingChains .. " chains, "
        .. #self.pendingDeployedCouplings .. " deployed couplings, "
        .. #self._pendingThickness .. " thickness entries"
        .. ", " .. animLoadIdx .. " coupler anim entries"
        .. ", " .. sprayerAnimLoadIdx .. " sprayer anim entries")
end

-- Applies saved coupler animation time/direction to a registered coupling.
-- This is deliberately position-based because pipeCoupling id values repeat between
-- vehicles, placeables and chain ends.
function SlurryPipeManager:_applyPendingCouplerAnimation(coupling)
    if coupling == nil or coupling.mountNode == nil or coupling.mountNode == 0 then return false end
    if self._pendingCouplerAnims == nil or SPSCouplerAnimator == nil then return false end
    if not entityExists(coupling.mountNode) then return false end

    local cx, cy, cz = getWorldTranslation(coupling.mountNode)
    local TOLERANCE_SQ = 0.1 * 0.1

    for _, entry in ipairs(self._pendingCouplerAnims) do
        if not entry.applied and entry.id == coupling.id then
            local dx, dy, dz = cx - (entry.x or 0), cy - (entry.y or 0), cz - (entry.z or 0)
            if dx*dx + dy*dy + dz*dz <= TOLERANCE_SQ then
                local function restore(slotName, inst)
                    if inst == nil then return end
                    local obj = entry.objects ~= nil and entry.objects[slotName] or nil
                    if obj ~= nil and SPSCouplerAnimator.restoreState ~= nil then
                        SPSCouplerAnimator.restoreState(inst, obj.time or 0, obj.direction or 0, obj.playing == true)
                    elseif slotName == "connector" and entry.legacyConnected ~= nil then
                        if entry.legacyConnected and SPSCouplerAnimator.setEnd ~= nil then
                            SPSCouplerAnimator.setEnd(inst)
                        elseif SPSCouplerAnimator.setStart ~= nil then
                            SPSCouplerAnimator.setStart(inst)
                        end
                    end
                end

                restore("connector", coupling.connectorAnim)
                restore("valve", coupling.valveAnim)
                entry.applied = true
                return true
            end
        end
    end
    return false
end

-- Applies saved sprayer animation state to a newly registered vehicle.
-- Position-based matching with 0.1m tolerance.
function SlurryPipeManager:_applyPendingSprayerAnimation(vehicle, entry)
    if vehicle == nil or entry == nil or entry.state.loadAnimName == nil then return false end
    if self._pendingSprayerAnimations == nil or #self._pendingSprayerAnimations == 0 then return false end
    if not entityExists(vehicle.rootNode) then return false end
    
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local TOLERANCE_SQ = 0.1 * 0.1
    
    for _, pending in ipairs(self._pendingSprayerAnimations) do
        if not pending.applied and pending.animName == entry.state.loadAnimName then
            local dx, dy, dz = vx - pending.x, vy - pending.y, vz - pending.z
            if dx*dx + dy*dy + dz*dz <= TOLERANCE_SQ then
                if vehicle.getAnimationExists ~= nil and vehicle:getAnimationExists(pending.animName) then
                    vehicle:setAnimationTime(pending.animName, pending.animTime, true, false)
                    pending.applied = true
                    print("[SPS SPR] _applyPendingSprayerAnimation: restored '" .. pending.animName 
                        .. "' to time " .. string.format("%.2f", pending.animTime))
                    return true
                end
            end
        end
    end
    return false
end

-- Called at the end of registerVehicle and registerPlaceable.
-- For each pending connection, checks if both mount nodes now exist.
-- Position match tolerance: 0.1m (positions stored as floats, no drift expected).
function SlurryPipeManager:tryResolvePendingConnections()
    if #self.pendingConnections == 0 and #self.pendingChains == 0 and #self.pendingDeployedCouplings == 0
    and next(self._pendingCouplerAnims) == nil then return end

    local TOLERANCE_SQ = 0.1 * 0.1

    local function posMatchesCoupling(coupling, wx, wy, wz)
        if coupling.mountNode == nil then return false end
        local cx, cy, cz = getWorldTranslation(coupling.mountNode)
        local dx, dy, dz = cx - wx, cy - wy, cz - wz
        return (dx*dx + dy*dy + dz*dz) <= TOLERANCE_SQ
    end

    local function findCouplingAtPos(wx, wy, wz)
        for _, vEntry in ipairs(self.registeredVehicles) do
            for _, c in ipairs(vEntry.couplingEntries) do
                if posMatchesCoupling(c, wx, wy, wz) then return c, vEntry.vehicle, nil end
            end
        end
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.storeCouplings ~= nil then
                for _, sc in ipairs(pEntry.storeCouplings) do
                    if posMatchesCoupling(sc, wx, wy, wz) then return sc, nil, pEntry.placeable end
                end
            end
        end
        -- Also search chain terminus entries — chainStartCoupling (id=-2) lives here
        -- and is not in registeredVehicles or registeredPlaceables.
        for _, ct in ipairs(self.chainTerminusEntries) do
            if posMatchesCoupling(ct, wx, wy, wz) then return ct, nil, nil end
        end
        return nil, nil, nil
    end

    -- Resolve pending chains FIRST — must run before connections so that
    -- chainStartCoupling (id=-2) is in chainTerminusEntries before the
    -- bez pipe connection tries to find it by position.
    if #self.pendingChains > 0 then
        local resolvedChains = {}
        for _, chainData in ipairs(self.pendingChains) do
            local anchorCoupling = findCouplingAtPos(
                chainData.anchorX, chainData.anchorY, chainData.anchorZ)
            if anchorCoupling ~= nil then
                local chain = SPSPipeChain.new(anchorCoupling, self.modDirectory)
                chain:restoreFromSaveData(chainData)
                table.insert(self.pipeChains, chain)
                -- Link chain back to anchor coupling's chainActivatable
                if anchorCoupling.chainActivatable ~= nil then
                    anchorCoupling.chainActivatable.chain = chain
                end
                table.insert(resolvedChains, chainData)
            end
        end
        for _, r in ipairs(resolvedChains) do
            for i, p in ipairs(self.pendingChains) do
                if p == r then table.remove(self.pendingChains, i) break end
            end
        end
    end

    -- Resolve pending connections — chains are now restored so chainStartCoupling
    -- entries are present in chainTerminusEntries and findable by position.
    local resolved = {}
    for _, pending in ipairs(self.pendingConnections) do
        local cA, ownerAv, ownerAp = findCouplingAtPos(pending.ax, pending.ay, pending.az)
        local cB, ownerBv, ownerBp = findCouplingAtPos(pending.bx, pending.by, pending.bz)

        if cA ~= nil and cB ~= nil and not cA.isConnected and not cB.isConnected then
            local ownerA = ownerAv or ownerAp
            local ownerB = ownerBv or ownerBp
            -- Temporarily set currentPipeColor to saved colour so applyConnectCouplings picks it up
            local savedColor = self.currentPipeColor
            self.currentPipeColor = { r = pending.colorR or savedColor.r, g = pending.colorG or savedColor.g, b = pending.colorB or savedColor.b }
            self:applyConnectCouplings(cA, cB, ownerA, ownerB)
            self.currentPipeColor = savedColor
            -- Immediately snap connector/valve animations to saved state.
            -- Must run AFTER applyConnectCouplings (which calls play()) so we override it.
            self:_applyPendingCouplerAnimation(cA)
            self:_applyPendingCouplerAnimation(cB)
            if pending.valveOpen then
                self:applyValveState(ownerAv, cA.id, true, cA)
            end
            table.insert(resolved, pending)
        end
    end

    for _, r in ipairs(resolved) do
        for i, p in ipairs(self.pendingConnections) do
            if p == r then table.remove(self.pendingConnections, i) break end
        end
    end

    -- Resolve pending deployed couplings
    if #self.pendingDeployedCouplings > 0 then
        local resolved = {}
        local TOLERANCE_SQ = 0.1 * 0.1
        for _, pending in ipairs(self.pendingDeployedCouplings) do
            for _, pEntry in ipairs(self.registeredPlaceables) do
                for _, sc in ipairs(pEntry.storeCouplings) do
                    if sc.deployable and sc.id == pending.id and sc.mountNode ~= nil then
                        local cx, cy, cz = getWorldTranslation(sc.mountNode)
                        local dx = cx - pending.x
                        local dy = cy - pending.y
                        local dz = cz - pending.z
                        if dx*dx + dy*dy + dz*dz <= TOLERANCE_SQ then
                            self:applyCouplingDeployState(sc.placeable, sc.id, true)
                            table.insert(resolved, pending)
                        end
                    end
                end
            end
        end
        for _, r in ipairs(resolved) do
            for i, p in ipairs(self.pendingDeployedCouplings) do
                if p == r then table.remove(self.pendingDeployedCouplings, i) break end
            end
        end
    end

    -- Final pass: restore saved animation positions on any registered coupler
    -- that did not go through applyConnectCouplings this tick.
    if self._pendingCouplerAnims ~= nil then
        for _, vEntry in ipairs(self.registeredVehicles) do
            for _, c in ipairs(vEntry.couplingEntries) do self:_applyPendingCouplerAnimation(c) end
        end
        for _, pEntry in ipairs(self.registeredPlaceables) do
            for _, c in ipairs(pEntry.storeCouplings) do self:_applyPendingCouplerAnimation(c) end
        end
        for _, c in ipairs(self.chainTerminusEntries) do self:_applyPendingCouplerAnimation(c) end
    end
end


-- ---------------------------------------------------------------------------
-- Chain management
-- ---------------------------------------------------------------------------

-- Called by anchor SPSChainActivatable when player presses R with no pipe ahead.
-- Creates a new chain for this coupling if one doesn't exist, then lays first segment.
-- ---------------------------------------------------------------------------
-- Deployable coupling management
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onCouplingDeploy(coupling)
    if coupling == nil or not coupling.deployable or coupling.isDeployed then return end
    if g_server ~= nil then
        self:applyCouplingDeployState(coupling.placeable, coupling.id, true)
        SPSCouplingDeployEvent.sendEvent(coupling.placeable, coupling.id, true)
    else
        SPSCouplingDeployEvent.sendEvent(coupling.placeable, coupling.id, true)
    end
end

function SlurryPipeManager:onCouplingUndeploy(coupling)
    if coupling == nil or not coupling.deployable or not coupling.isDeployed then return end
    if coupling.isConnected then return end
    if coupling.chainActivatable ~= nil and coupling.chainActivatable.chain ~= nil then return end
    if g_server ~= nil then
        self:applyCouplingDeployState(coupling.placeable, coupling.id, false)
        SPSCouplingDeployEvent.sendEvent(coupling.placeable, coupling.id, false)
    else
        SPSCouplingDeployEvent.sendEvent(coupling.placeable, coupling.id, false)
    end
end

function SlurryPipeManager:applyCouplingDeployState(placeable, couplingId, isDeployed)
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.placeable == placeable then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc.id == couplingId then
                    sc.isDeployed = isDeployed
                    setVisibility(sc.mountNode, isDeployed)
                    if isDeployed then
                        addToPhysics(sc.mountNode)
                    else
                        removeFromPhysics(sc.mountNode)
                    end
                    -- Swap undeployedVisibleNodes — visible when NOT deployed
                    if sc.undeployedVisibleNodes ~= nil then
                        for _, n in ipairs(sc.undeployedVisibleNodes) do
                            setVisibility(n, not isDeployed)
                        end
                    end
                    -- On undeploy: reset anim node once so Giants animation can take back control
                    if not isDeployed and pEntry.pipeAnimNode ~= nil and pEntry.pipeAnimNode ~= 0 then
                        setRotation(pEntry.pipeAnimNode, 0, 0, 0)
                    end
                    return
                end
            end
        end
    end
end

-- [SPS TRACE] node descriptor: id / name / world pos, nil-safe.
function SlurryPipeManager:_traceNode(label, node)
    if node == nil or node == 0 then
--        print("[SPS TRACE]   " .. label .. " = nil/0")
        return
    end
    if not entityExists(node) then
        --print("[SPS TRACE]   " .. label .. " = " .. tostring(node) .. " (NO ENTITY)")
        return
    end
    local x, y, z = getWorldTranslation(node)
    --print(string.format("[SPS TRACE]   %s = id=%s name='%s' pos=(%.3f,%.3f,%.3f)",
        --label, tostring(node), tostring(getName(node)), x or 0, y or 0, z or 0))
end

-- [SPS TRACE] coupling descriptor: id, owner, mount/in/out nodes, flags.
function SlurryPipeManager:_traceCoupling(label, c)
    --if c == nil then print("[SPS TRACE] " .. label .. " = nil") return end
    local owner = "?"
    local v, p = self:_findCouplingOwner(c)
    if v ~= nil then owner = "vehicle:" .. tostring(v.configFileName)
    elseif p ~= nil then owner = "placeable:" .. tostring(p.configFileName)
    elseif c.isChainTerminus then owner = "chainTerminus"
    end
    --print(string.format("[SPS TRACE] %s id=%s owner=%s connector=%s isConnected=%s isChainTerminus=%s isChainStart=%s placeable=%s",
    --    label, tostring(c.id), owner, tostring(c.connectorType),
    --    tostring(c.isConnected), tostring(c.isChainTerminus), tostring(c.isChainStart),
    --    tostring(c.placeable ~= nil)))
    self:_traceNode(label .. ".mountNode", c.mountNode)
    self:_traceNode(label .. ".inNode",    c.inNode)
    self:_traceNode(label .. ".outNode",   c.outNode)
end

function SlurryPipeManager:onChainStartLaying(coupling, anchorActivatable)
    if coupling == nil then return end
    --print("[SPS TRACE] ===== onChainStartLaying =====")
    self:_traceCoupling("onChainStartLaying.coupling", coupling)
    local chain = nil
    for _, c in ipairs(self.pipeChains) do
        if c.anchorCoupling == coupling then chain = c break end
    end
    if chain == nil then
        chain = SPSPipeChain.new(coupling, self.modDirectory)
        table.insert(self.pipeChains, chain)
    end
    if anchorActivatable ~= nil then
        anchorActivatable.chain = chain
    end

    local mx, my, mz = getWorldTranslation(coupling.mountNode)
    local fdx, _, fdz = localDirectionToWorld(coupling.mountNode, 0, 0, -1)
    local mry = math.atan2(-fdx, -fdz)

    -- Vehicle coupling: start chain 3.5m ahead so the tanker can drive away
    -- and the chain stays independent. Player walks to that point.
    -- Placeable coupling: start chain directly at coupling (placeable never moves).
    local vehicle, _ = self:_findCouplingOwner(coupling)
    if vehicle ~= nil then
        local sx = mx + fdx * 3.5
        local sz = mz + fdz * 3.5
        local sy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, sx, 0, sz) + 0.05
        chain:startLaying(sx, sy, sz, mry)
    else
        chain:startLaying(mx, my, mz, mry, coupling.mountNode)
    end

    -- Play connector animation forward on the anchor coupling (no-op if not bound).
    if SPSCouplerAnimator ~= nil and coupling.connectorAnim ~= nil then
        SPSCouplerAnimator.play(coupling.connectorAnim, 1)
    end
end

-- Keep old name as alias for compatibility
function SlurryPipeManager:onChainLayPipe(coupling, anchorActivatable)
    self:onChainStartLaying(coupling, anchorActivatable)
end

-- Called by anchor SPSChainActivatable after all segments removed.
-- Removes the empty chain from the manager.
function SlurryPipeManager:onChainEmpty(chain, coupling)
    -- Play connector animation reverse on the anchor coupling (no-op if not bound).
    if SPSCouplerAnimator ~= nil and coupling ~= nil and coupling.connectorAnim ~= nil then
        SPSCouplerAnimator.play(coupling.connectorAnim, -1)
    end
    for i, c in ipairs(self.pipeChains) do
        if c == chain then
            chain:delete()
            table.remove(self.pipeChains, i)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- State queries
-- ---------------------------------------------------------------------------
function SlurryPipeManager:hasValidConnection(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            for _, arm in ipairs(entry.armEntries) do
                if arm.isConnected then return true end
            end
            for _, c in ipairs(entry.couplingEntries) do
                if c.isConnected and c.valveOpen then return true end
            end
            return false
        end
    end
    return false
end

function SlurryPipeManager:isRegistered(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then return true end
    end
    return false
end

function SlurryPipeManager:getVehicleState(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then return entry.state end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- [SPS AI GATE] — vanilla AI worker / Courseplay / AutoDrive support
--
-- While ANY AI drives a vehicle chain, SPS must fully stand down and let the
-- vanilla trigger system run: no pipes, no fill arms, no pressure, no shear
-- bolt, no thickness scaling, no blockages. Detection is a single source-
-- verified check (SlurryPipeSystemOverride.isAIControlled — root
-- getIsAIActive(), which covers the vanilla helper, Courseplay AND AutoDrive,
-- see that function's header). Every overwritten function in
-- ManureBarrelOverride early-outs to superFunc on that check, and the per-tick
-- edge detector below handles the player<->AI TRANSITIONS:
--
--   player -> AI : neutralise live SPS state (pump off, all valves closed,
--                  synced via existing SPS events), then re-raise
--                  onRootVehicleChanged on the whole chain so
--                  TurnOnVehicle:onRootVehicleChanged registers its AI
--                  controlledAction — its original registration at attach time
--                  was blocked by the SPS getCanToggleTurnedOn override, and
--                  AIJobVehicle:aiJobStarted does NOT re-raise the event itself
--                  (verified against vanilla source). Without this the helper
--                  can never turn the implement on and sits in the field.
--   AI -> player : re-raise onRootVehicleChanged again; getCanToggleTurnedOn
--                  now blocks again, so TurnOnVehicle's else-branch removes the
--                  controlledAction and full SPS control returns to the player.
--
-- Per-tick edge detection (instead of MessageType.AI_VEHICLE_STATE_CHANGE) is
-- deliberate: pure AutoDrive driving never starts a Giants AI job, so it never
-- publishes that message — but it DOES flip getIsAIActive (AD overwrites it).
-- The edge detector covers all three uniformly, on server and clients.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:isAIControlled(vehicle)
    return SlurryPipeSystemOverride ~= nil
       and SlurryPipeSystemOverride.isAIControlled ~= nil
       and SlurryPipeSystemOverride.isAIControlled(vehicle)
end

-- Root + every attached implement of the vehicle's chain.
function SlurryPipeManager:getAIGateChain(vehicle)
    local chain = {}
    if vehicle == nil then return chain end
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if root == nil then return chain end
    if root.getChildVehicles ~= nil then
        for _, v in ipairs(root:getChildVehicles()) do
            chain[#chain + 1] = v
        end
    end
    local hasRoot = false
    for _, v in ipairs(chain) do
        if v == root then hasRoot = true; break end
    end
    if not hasRoot then chain[#chain + 1] = root end
    return chain
end

-- Per-tick transition detector. Cheap: registeredVehicles is a small list and
-- isAIControlled is a couple of field reads.
function SlurryPipeManager:updateAIGate(dt)
    for _, vEntry in ipairs(self.registeredVehicles) do
        local v = vEntry.vehicle
        if v ~= nil then
            local aiNow = self:isAIControlled(v)
            if aiNow ~= (vEntry.aiGateActive == true) then
                vEntry.aiGateActive = aiNow
                self:onAIGateChanged(v, vEntry, aiNow)
            end
        end
    end
end

function SlurryPipeManager:onAIGateChanged(vehicle, vEntry, aiNow)
    print("[SPS AI GATE] " .. (aiNow and "AI took control — SPS suspended for "
                                      or "AI released control — SPS restored for ")
        .. tostring(vehicle.configFileName))

    -- Vanilla FillTrigger: SPS disables it at registration so the player must use
    -- the pipe/arm system to load. AI workers (vanilla / Courseplay / AutoDrive)
    -- have no pipe and load the vanilla way — at a store's fill trigger — so the
    -- trigger must be live while AI drives. Restore the SPS-disabled state when the
    -- player takes back over. Toggled on server and client (the trigger gate is a
    -- local field; AI fill runs server-side, the activation check reads isEnabled).
    if vehicle.spec_fillTriggerVehicle ~= nil
       and vehicle.spec_fillTriggerVehicle.fillTrigger ~= nil then
        vehicle.spec_fillTriggerVehicle.fillTrigger.isEnabled = aiNow
        print("[SPS AI GATE]   vanilla fillTrigger " .. (aiNow and "ENABLED (AI loads at stores)"
                                                               or "disabled (SPS pipe loading)"))
    end

    if aiNow and g_server ~= nil then
        -- Neutralise live SPS state so vanilla starts from a clean slate.
        -- All three setters mirror the player toggle paths exactly (state on the
        -- server + existing SPS event broadcast for MP sync).
        local state = vEntry.state
        if state ~= nil then
            if state.valveOpen == true then
                state.valveOpen = false
                SlurryFlowStateEvent.sendEvent(vehicle, false)
                print("[SPS AI GATE]   flow valve closed")
            end
            if state.spreaderValveOpen == true then
                state.spreaderValveOpen = false
                SPSSpreaderValveEvent.sendEvent(vehicle, false)
                print("[SPS AI GATE]   spreader valve closed")
            end
            if state.pumpRunning == true then
                state.pumpRunning = false
                SPSSelfPumpStateEvent.sendEvent(vehicle, false)
                print("[SPS AI GATE]   pump stopped")
            end
        end
        -- Non-spreader pumps run on the vanilla turn-on flag — clear it. The
        -- setIsTurnedOn override passes straight through to vanilla now that
        -- the vehicle is AI-controlled, and the AI turns implements on itself
        -- afterwards through its own controlledAction.
        if vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn()
           and vehicle.setIsTurnedOn ~= nil then
            vehicle:setIsTurnedOn(false)
            print("[SPS AI GATE]   turn-on flag cleared")
        end
        self:updateActionEventTexts(vehicle)
    end

    -- Both directions, server AND client: re-evaluate TurnOnVehicle's AI
    -- controlledAction registration across the whole chain, now that
    -- getCanToggleTurnedOn answers differently for it. The vanilla handler is
    -- idempotent (updateParent when already registered / remove when no longer
    -- allowed), so re-raising is safe for every other listener too — this is
    -- the same event raised on every attach/detach.
    for _, v in ipairs(self:getAIGateChain(vehicle)) do
        if v.rootVehicle ~= nil then
            SpecializationUtil.raiseEvent(v, "onRootVehicleChanged", v.rootVehicle)
        end
    end
    print("[SPS AI GATE]   onRootVehicleChanged re-raised on chain")
end

function SlurryPipeManager:getVehicleEntry(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then return entry end
    end
    return nil
end

-- True for a vehicle registered ONLY for blockage nodes (a dribble bar), as opposed to
-- a slurry tanker. Such a vehicle must not receive the SPS control action events or be
-- treated as a controller — its tanker drives it.
function SlurryPipeManager:isSpreaderImplement(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    return entry ~= nil and entry.isSpreaderImplement == true
end

function SlurryPipeManager:getPlaceableEntry(placeable)
    for _, entry in ipairs(self.registeredPlaceables) do
        if entry.placeable == placeable then return entry end
    end
    return nil
end

function SlurryPipeManager:connectionIsFillArm(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            for _, arm in ipairs(entry.armEntries) do if arm.isConnected then return true end end
            return false
        end
    end
    return false
end

function SlurryPipeManager:vehicleHasFillArms(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            return #entry.armEntries > 0
        end
    end
    return false
end

function SlurryPipeManager:vehicleHasSpreader(vehicle)
    -- Check the tanker itself (e.g. Cobra with built-in spreader)
    if vehicle.spec_dischargeable ~= nil then return true end
    -- Check attached implements (e.g. Samson with detachable rear spreader)
    local root = vehicle:getRootVehicle()
    if root ~= nil and root.getChildVehicles ~= nil then
        for _, v in ipairs(root:getChildVehicles()) do
            if v ~= vehicle and v.spec_dischargeable ~= nil then
                return true
            end
        end
    end
    return false
end

-- Returns all child vehicles attached to the same root that are NOT SPS-registered
-- and have a TurnOnVehicle spec — i.e. rear dribble bars / spreader attachments.
-- The SPS spreader valve drives their TurnOnVehicle state: open -> setIsTurnedOn(true),
-- close -> auto-off via getCanBeTurnedOn / TurnOnVehicle.turnOffIfNotAllowed.
function SlurryPipeManager:findAttachedDribbleBars(vehicle)
    local bars = {}
    local root = vehicle:getRootVehicle()
    if root == nil or root.getChildVehicles == nil then return bars end
    for _, v in ipairs(root:getChildVehicles()) do
        -- A child counts as a controllable dribble bar if it is a turn-on implement
        -- that is NOT itself a slurry tanker. A bar registered only for blockage nodes
        -- (isSpreaderImplement) is allowed through — being SPS-registered for blockages
        -- must not hide it from its controlling tanker.
        if v ~= vehicle and v.spec_turnOnVehicle ~= nil then
            local vEntry = self:getVehicleEntry(v)
            local isTanker = (vEntry ~= nil) and (vEntry.isSpreaderImplement ~= true)
            if not isTanker then
                table.insert(bars, v)
            end
        end
    end
    return bars
end

function SlurryPipeManager:onActionToggleSpreader(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local newOpen = not state.spreaderValveOpen
    print("[SPS SPREADER] onActionToggleSpreader -> " .. tostring(newOpen) .. " dir=" .. tostring(state.direction))
    -- The spreader can only discharge, so it may only open when the pump is set to
    -- Pressure (DISCHARGE). Pump state is irrelevant — stored pressure drives the
    -- spread. (The fill arm, by contrast, may open in either direction.)
    if newOpen and state.direction ~= SPS_DIRECTION_DISCHARGE then
        if vehicle.isClient then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSetToPressure"), 2000)
        end
        print("[SPS SPREADER] blocked — pump not set to Pressure")
        return
    end
    if g_server ~= nil then
        state.spreaderValveOpen = newOpen
        SPSSpreaderValveEvent.sendEvent(vehicle, newOpen)
        self:updateActionEventTexts(vehicle)
    else
        SPSSpreaderValveEvent.sendEvent(vehicle, newOpen)
    end
end

function SlurryPipeManager:isVehicleSelfPowered(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            return entry.selfPowered == true
        end
    end
    return false
end

function SlurryPipeManager:isVehicleAgitatorOnly(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then return entry.agitatorOnly == true end
    end
    return false
end

function SlurryPipeManager:isVehicleConduit(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then return entry.conduit == true end
    end
    return false
end

-- Returns the source entry on the far side of a coupling's connection.
-- Used by conduit pump to find what to pull from / push into.
function SlurryPipeManager:resolveSourceForCouplingPartner(coupling)
    if not coupling.isConnected then return nil end
    local partner = coupling.connectedPartnerCoupling
    if partner == nil then return nil end
    -- Chain terminus: use stored sourceEntry if available, else walk to anchor
    if partner.isChainTerminus then
        if partner.sourceEntry ~= nil then
            return partner.sourceEntry
        end
        -- sourceEntry not set at chain creation — resolve from anchor on demand
        if partner.chain ~= nil and partner.chain.anchorCoupling ~= nil then
            local anchor = partner.chain.anchorCoupling
            for _, pEntry in ipairs(self.registeredPlaceables) do
                if pEntry.storeCouplings ~= nil then
                    for _, sc in ipairs(pEntry.storeCouplings) do
                        if sc == anchor then return pEntry.sourceEntry end
                    end
                end
            end
            for _, vEntry in ipairs(self.registeredVehicles) do
                for _, c in ipairs(vEntry.couplingEntries) do
                    if c == anchor then
                        return self:resolveVehicleSource(vEntry.vehicle)
                    end
                end
            end
        end
        return nil
    end
    -- Partner on a placeable
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc == partner then return pEntry.sourceEntry end
            end
        end
    end
    -- Partner on a vehicle — resolve that vehicle's fill source
    local target = coupling.connectedTarget
    if target ~= nil then
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.vehicle == target then
                return self:resolveVehicleSource(vEntry.vehicle)
            end
        end
    end
    return nil
end

function SlurryPipeManager:hasActiveCouplingConnection(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            for _, c in ipairs(entry.couplingEntries) do
                if c.isConnected and c.valveOpen then return true end
            end
            return false
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Arm/coupling callbacks (stubs kept for future coupling re-addition)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onPumpStateChanged(vehicle, isPumpRunning)
    local state = self:getVehicleState(vehicle)
    if state ~= nil then
        state.pumpRunning = isPumpRunning == true
    end
end

function SlurryPipeManager:onSelfPumpToggle(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local newRunning = not (state.pumpRunning == true)
    if g_server ~= nil then
        state.pumpRunning = newRunning
        SPSSelfPumpStateEvent.sendEvent(vehicle, newRunning)
        self:updateActionEventTexts(vehicle)
    else
        SPSSelfPumpStateEvent.sendEvent(vehicle, newRunning)
    end
    if vehicle.isClient then
        local entry = self:getVehicleEntry(vehicle)
        if entry ~= nil and entry.engineLoopSample ~= nil then
            if newRunning then
                g_soundManager:playSample(entry.engineLoopSample)
            else
                g_soundManager:stopSample(entry.engineLoopSample)
            end
        end
    end
end

-- Shared PTO/pump toggle used by BOTH the cab action event and the outside
-- ptoControl node, so behaviour is identical in and out of the cab. This is the
-- exact logic that previously lived inline in init.lua's cab pumpCallback.
function SlurryPipeManager:togglePump(vehicle)
    if vehicle == nil then return end
    if self:vehicleHasSpreader(vehicle) then
        local root = vehicle:getRootVehicle()
        if root ~= nil and root.getIsMotorStarted ~= nil and not root:getIsMotorStarted() then
            local warning = vehicle:getTurnedOnNotAllowedWarning()
            if warning ~= nil and vehicle.isClient then
                g_currentMission:showBlinkingWarning(warning, 2000)
            end
            --print("[SPS PUMP] spreader vehicle pump blocked — motor not started")
            return
        end
        if not SlurryPipeSystemOverride.isPTOConnected(vehicle) then
            --print("[SPS PUMP] spreader vehicle pump blocked — PTO not connected")
            return
        end
        local state = self:getVehicleState(vehicle)
        if state == nil then return end
        local newPump = not state.pumpRunning
        --print("[SPS PUMP] spreader vehicle pump -> " .. tostring(newPump) .. " spreaderValveOpen=" .. tostring(state.spreaderValveOpen))
        if g_server ~= nil then
            state.pumpRunning = newPump
            SPSSelfPumpStateEvent.sendEvent(vehicle, newPump)
            if newPump then
                vehicle:setIsTurnedOn(true)
                print("[SPS PUMP] pump on — setIsTurnedOn(true) for PTO sounds")
            else
                vehicle:setIsTurnedOn(false)
                print("[SPS PUMP] pump off — setIsTurnedOn(false) requested; guard/driver keep it on if still discharging")
            end
            self:updateActionEventTexts(vehicle)
        else
            SPSSelfPumpStateEvent.sendEvent(vehicle, newPump)
        end
    else
        if not vehicle:getIsTurnedOn() and not vehicle:getCanBeTurnedOn() then
            local warning = vehicle:getTurnedOnNotAllowedWarning()
            if warning ~= nil and vehicle.isClient then
                g_currentMission:showBlinkingWarning(warning, 2000)
            end
            print("[SPS PUMP] non-spreader pump blocked — getCanBeTurnedOn false")
            return
        end
        --print("[SPS PUMP] non-spreader setIsTurnedOn -> " .. tostring(not vehicle:getIsTurnedOn()))
        vehicle:setIsTurnedOn(not vehicle:getIsTurnedOn())
        self:updateActionEventTexts(vehicle)
    end
end

-- True when the tanker carries an outside <directionControl> node; used by
-- init.lua to suppress the cab direction control so it lives only at the node.
function SlurryPipeManager:vehicleHasOutsideDirectionControl(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil or entry.outsideControlEntries == nil then return false end
    for _, oc in ipairs(entry.outsideControlEntries) do
        if oc.direction == true then return true end
    end
    return false
end

function SlurryPipeManager:onArmConnected(vehicle, arm) end
function SlurryPipeManager:onArmDisconnected(vehicle, arm) self:stopFlow(vehicle) end

-- ---------------------------------------------------------------------------
-- Action handlers
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onActionToggleFlow(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    -- MA: hydraulic hoses must be connected to open the valve
    if not state.valveOpen then
        if not SlurryPipeSystemOverride.isHydraulicsConnected(vehicle) then
            if vehicle.isClient then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsConnectHydraulics"), 2000)
            end
            return
        end
    end
    -- Block opening the hydraulic valve when engine is off
    if not state.valveOpen then
        local root = vehicle:getRootVehicle()
        if root ~= nil and root.getIsMotorStarted ~= nil and not root:getIsMotorStarted() then
            if vehicle.isClient then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_slurryEngineOff"), 2000)
            end
            return
        end
    end
    if g_server ~= nil then
        local newOpen = not state.valveOpen
        state.valveOpen = newOpen
        SlurryFlowStateEvent.sendEvent(vehicle, newOpen)
        self:updateActionEventTexts(vehicle)
    else
        SlurryFlowStateEvent.sendEvent(vehicle, not state.valveOpen)
    end
end

-- Sets the target direction. Server-side, arms a purge when the existing
-- pressure opposes the new direction: the engine then vents to 0 (at purgeTime)
-- before building the new way. If pressure is 0 or already toward the new
-- target, no purge is needed and any in-progress purge is cleared.
-- Routed through here from both onActionToggleDirection (host) and
-- SlurryFlowDirectionEvent:run (dedicated server / client direction sync).
function SlurryPipeManager:applyDirectionAndPurge(vehicle, newDir)
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    state.direction = newDir
    if g_server ~= nil then
        local targetSign = (newDir == SPS_DIRECTION_DISCHARGE) and 1 or -1
        local p = state.pressure or 0
        state.purging = (p * targetSign < 0)
    end
end

function SlurryPipeManager:onActionToggleDirection(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    if state.valveOpen then
        if vehicle.isClient then g_currentMission:showBlinkingWarning(g_i18n:getText("warning_slurryCloseFlowFirst"), 2000) end
        return
    end
    local newDir = (state.direction == SPS_DIRECTION_FILL) and SPS_DIRECTION_DISCHARGE or SPS_DIRECTION_FILL
    if g_server ~= nil then
        self:applyDirectionAndPurge(vehicle, newDir)
        SlurryFlowDirectionEvent.sendEvent(vehicle, newDir)
        self:updateActionEventTexts(vehicle)
    else
        SlurryFlowDirectionEvent.sendEvent(vehicle, newDir)
    end
end

function SlurryPipeManager:updateActionEventTexts(vehicle)
    if not vehicle.isClient then return end
    if vehicle.spsActionEvents == nil then return end
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local pumpType = self:getPumpType(vehicle)
    local pumpId = vehicle.spsActionEvents.pumpEventId
    if pumpId ~= nil then
        local pumpOn
        if self:isVehicleSelfPowered(vehicle) or self:vehicleHasSpreader(vehicle) then
            pumpOn = state.pumpRunning == true
        else
            pumpOn = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn()
        end
        local offKey = (pumpType == "HVP") and "action_spsHVPOff" or "action_slurryPumpOff"
        local onKey  = (pumpType == "HVP") and "action_spsHVPOn"  or "action_slurryPumpOn"
        g_inputBinding:setActionEventText(pumpId, pumpOn
            and g_i18n:getText(offKey)
            or  g_i18n:getText(onKey))
    end
    local flowId = vehicle.spsActionEvents.flowEventId
    if flowId ~= nil then
        local flowOpenKey  = self:isVehicleConduit(vehicle) and "action_spsConduitFlowOpen"  or "action_slurryFlowOpen"
        local flowCloseKey = self:isVehicleConduit(vehicle) and "action_spsConduitFlowClose" or "action_slurryFlowClose"
        g_inputBinding:setActionEventText(flowId, state.valveOpen and g_i18n:getText(flowCloseKey) or g_i18n:getText(flowOpenKey))
        g_inputBinding:setActionEventActive(flowId, true)
    end
    local dirId = vehicle.spsActionEvents.dirEventId
    if dirId ~= nil then
        local dirTxt
        if self:isVehicleConduit(vehicle) then
            dirTxt = (state.direction == SPS_DIRECTION_FILL)
                and g_i18n:getText("action_spsConduitDirBtoA")
                or  g_i18n:getText("action_spsConduitDirAtoB")
        elseif pumpType == "HVP" then
            dirTxt = (state.direction == SPS_DIRECTION_FILL)
                and g_i18n:getText("action_spsHVPDirDischarge")
                or  g_i18n:getText("action_spsHVPDirFill")
        else
            dirTxt = (state.direction == SPS_DIRECTION_FILL)
                and g_i18n:getText("action_slurryDirectionDischarge")
                or  g_i18n:getText("action_slurryDirectionFill")
        end
        g_inputBinding:setActionEventText(dirId, dirTxt)
        g_inputBinding:setActionEventActive(dirId, not state.valveOpen)
    end
    local spreaderId = vehicle.spsActionEvents.spreaderEventId
    if spreaderId ~= nil then
        g_inputBinding:setActionEventText(spreaderId, state.spreaderValveOpen
            and g_i18n:getText("action_spsSpreaderClose")
            or  g_i18n:getText("action_spsSpreaderOpen"))
    end
end

-- ---------------------------------------------------------------------------
-- Blockage system (dribble bar / spreader)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:getBlockageEntries(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return {} end
    return entry.blockageEntries or {}
end

function SlurryPipeManager:isMaceratorBlocked(vehicle)
    for _, b in ipairs(self:getBlockageEntries(vehicle)) do
        if b.isMacerator and b.blocked then return true end
    end
    return false
end

function SlurryPipeManager:getBlockageFlowFraction(vehicle)
    if not self:isFeatureEnabled("blockages") then return 1.0 end
    local list = self:getBlockageEntries(vehicle)
    if #list == 0 then return 1.0 end
    if self:isMaceratorBlocked(vehicle) then return 0.0 end
    local outlets, open = 0, 0
    for _, b in ipairs(list) do
        if not b.isMacerator then
            outlets = outlets + 1
            if not b.blocked then open = open + 1 end
        end
    end
    if outlets == 0 then return 1.0 end
    return open / outlets
end

-- The tanker whose spread state controls a node-bearing implement (walk up attachers).
function SlurryPipeManager:getBlockageController(nodeOwner)
    local v, guard = nodeOwner, 0
    while v ~= nil and guard < 8 do
        if self:vehicleHasSpreader(v) and not self:isSpreaderImplement(v) then return v end
        if v.getAttacherVehicle == nil then break end
        local up = v:getAttacherVehicle()
        if up == nil or up == v then break end
        v = up; guard = guard + 1
    end
    return nodeOwner
end

function SlurryPipeManager:updateBlockages(dt)
    if g_server == nil then return end
    if not self:isFeatureEnabled("blockages") then return end
    for _, entry in ipairs(self.registeredVehicles) do
        local vehicle = entry.vehicle
        local list    = entry.blockageEntries
        if list ~= nil and #list > 0 then
            local controller = self:getBlockageController(vehicle)
            local cstate     = self:getVehicleState(controller)
            -- Only roll for blockages while ACTUALLY spreading: discharge active (pump/
            -- pressure) AND the spreader valve open. isSpreaderDischargeActive alone is
            -- true for an HVP tanker whenever the pump runs and for a vacuum tanker
            -- whenever pressure is built in the discharge direction — both of which can
            -- hold during a FILL (spreader valve shut), which previously popped the
            -- blockage warning while nothing was being spread. The valve gate fixes that.
            -- [SPS AI GATE] never roll blockages while AI drives — vanilla spreading.
            if self:isSpreaderDischargeActive(controller)
               and cstate ~= nil and cstate.spreaderValveOpen == true
               and not self:isAIControlled(controller) then
                entry.blockageRollTimer = (entry.blockageRollTimer or 0) + dt
                if entry.blockageRollTimer >= SlurryPipeManager.BLOCKAGE_ROLL_INTERVAL then
                    entry.blockageRollTimer = 0
                    -- Blockages are driven by the CRUST (un-mixed lumpiness) the tanker
                    -- carries, since mixing the store is what clears it. Crust below
                    -- BLOCKAGE_CRUST_MIN contributes nothing; above it the chance ramps to
                    -- full. A small base chance always applies even on clean slurry, to
                    -- emulate a foreign object (wood/stone). Dry matter mildly amplifies
                    -- the result so thick AND crusted is the worst case.
                    local crust      = self:getTankerCrust(controller)
                    local crustScale = 0.0
                    if crust > SlurryPipeManager.BLOCKAGE_CRUST_MIN then
                        local span = 1.0 - SlurryPipeManager.BLOCKAGE_CRUST_MIN
                        crustScale = span > 0 and ((crust - SlurryPipeManager.BLOCKAGE_CRUST_MIN) / span) or 1.0
                        crustScale = math.min(1.0, math.max(0.0, crustScale))
                    end
                    local dmSpan  = SlurryPipeManager.DM_JAMMED - SlurryPipeManager.DM_FRESH
                    local dmFac   = dmSpan > 0 and ((self:gaugeToDM(self:getTankerThickness(controller)) - SlurryPipeManager.DM_FRESH) / dmSpan) or 0
                    dmFac         = math.min(1.0, math.max(0.0, dmFac))
                    local dmMult  = 1.0 + SlurryPipeManager.BLOCKAGE_DM_BONUS * dmFac

                    local maceratorChance = (SlurryPipeManager.BLOCKAGE_BASE_CHANCE + SlurryPipeManager.BLOCKAGE_MACERATOR_CHANCE * crustScale) * dmMult
                    local outletChance    = (SlurryPipeManager.BLOCKAGE_BASE_CHANCE + SlurryPipeManager.BLOCKAGE_OUTLET_CHANCE   * crustScale) * dmMult

                    if not self:isMaceratorBlocked(vehicle) then
                        if math.random() < maceratorChance then
                            for _, b in ipairs(list) do
                                if b.isMacerator then self:setBlockageState(vehicle, b, true) end
                            end
                        else
                            for _, b in ipairs(list) do
                                if not b.isMacerator and not b.blocked and math.random() < outletChance then
                                    self:setBlockageState(vehicle, b, true)
                                end
                            end
                        end
                    end
                end
            else
                entry.blockageRollTimer = 0
            end
        end
    end
end

function SlurryPipeManager:getBlockageNodeIndex(vehicle, blockageEntry)
    local list = self:getBlockageEntries(vehicle)
    for i, b in ipairs(list) do if b == blockageEntry then return i end end
    return nil
end

function SlurryPipeManager:setBlockageState(vehicle, blockageEntry, blocked, noEventSend)
    if blockageEntry == nil or blockageEntry.blocked == blocked then return end
    blockageEntry.blocked = blocked
    self:playBlockageAnimation(vehicle, blockageEntry, blocked)
    if blocked and vehicle.isClient then
        -- Name what blocked so the player knows whether it's the whole-bar macerator
        -- (everything stops) or a single outlet section (only that strip stops).
        local msg
        if blockageEntry.isMacerator then
            msg = g_i18n:getText("warning_spsBlockageMacerator")
        else
            -- Friendly label from the node name, e.g. SPS_blockageNodeLeft01 -> "Left 01".
            local label = tostring(blockageEntry.name or "")
            label = label:gsub("^SPS_blockageNode", "")
            label = label:gsub("(%a)(%d)", "%1 %2")
            if label == "" then label = "outlet" end
            msg = string.format(g_i18n:getText("warning_spsBlockageSection"), label)
        end
        g_currentMission:showBlinkingWarning(msg, 2500)
    end
    if not noEventSend and SPSBlockageEvent ~= nil then
        local idx = self:getBlockageNodeIndex(vehicle, blockageEntry)
        if idx ~= nil then SPSBlockageEvent.sendEvent(vehicle, idx, blocked) end
    end
end

function SlurryPipeManager:applyBlockageByIndex(vehicle, index, blocked)
    local b = self:getBlockageEntries(vehicle)[index]
    if b ~= nil then self:setBlockageState(vehicle, b, blocked, true) end
end

function SlurryPipeManager:playBlockageAnimation(vehicle, blockageEntry, blocked)
    local animName = blockageEntry.blockageAnimation
    if animName == nil or animName == "" then return end
    if vehicle.playAnimation == nil or not vehicle.isClient then return end
    vehicle:playAnimation(animName, blocked and 1 or -1, nil, true)
end

function SlurryPipeManager:clearAllBlockages(vehicle)
    local n = 0
    for _, b in ipairs(self:getBlockageEntries(vehicle)) do
        if b.blocked then self:setBlockageState(vehicle, b, false); n = n + 1 end
    end
    return n
end

function SlurryPipeManager:clearNearestBlockage(vehicle, px, py, pz)
    local best, bestDist = nil, SlurryPipeManager.BLOCKAGE_CLEAR_RADIUS
    for _, b in ipairs(self:getBlockageEntries(vehicle)) do
        if b.blocked and b.node ~= nil then
            local nx, ny, nz = getWorldTranslation(b.node)
            local d = MathUtil.vector3Length(nx - px, ny - py, nz - pz)
            if d <= bestDist then best, bestDist = b, d end
        end
    end
    if best ~= nil then self:setBlockageState(vehicle, best, false) end
    return best
end

-- Pressure (bar) below which a vacuum line counts as "vented" for clearing.
SlurryPipeManager.BLOCKAGE_CLEAR_PRESSURE_EPS = 0.05

-- Whether a blockage on this spreader may be cleared right now. Gated on the bar being
-- stopped, which differs by the controlling tanker's drive model: a vacuum tanker must
-- have vented back to ~0 bar; an HVP / pump-gated tanker must have its pump off. (You
-- cannot unclog a live, pressurised bar.)
function SlurryPipeManager:canClearBlockage(vehicle)
    local controller = self:getBlockageController(vehicle)
    if controller == nil then return false end
    local state = self:getVehicleState(controller)
    if state == nil then return false end
    if self:usesPressureModel(controller) then
        return math.abs(state.pressure or 0) <= SlurryPipeManager.BLOCKAGE_CLEAR_PRESSURE_EPS
    end
    return state.pumpRunning ~= true
end

-- Player-initiated clear of one specific blockage node (from its walk-up activatable).
-- Re-checks the stop gate, then clears + syncs via setBlockageState (SPSBlockageEvent).
function SlurryPipeManager:onClearBlockage(vehicle, blockageEntry)
    if blockageEntry == nil or blockageEntry.blocked ~= true then return end
    if not self:canClearBlockage(vehicle) then return end
    self:setBlockageState(vehicle, blockageEntry, false)
end

-- ---------------------------------------------------------------------------
-- Flow session
-- ---------------------------------------------------------------------------
function SlurryPipeManager:startFlow(vehicle)
    if self.activeFlows[vehicle] ~= nil then return end
    local session = self:buildFlowSession(vehicle)
    if session ~= nil then
        self.activeFlows[vehicle] = session
        SlurryDebug.log("startFlow - session started for " .. tostring(vehicle.configFileName))
    end
end

function SlurryPipeManager:stopFlow(vehicle)
    if self.activeFlows[vehicle] ~= nil then
        self.activeFlows[vehicle] = nil
    end
end

-- Returns the resolved drive model for a vehicle: "vacuum" | "HVP" | "conduit" |
-- "openTop", or nil if unregistered.
function SlurryPipeManager:getPumpType(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return nil end
    return entry.pumpType
end

-- Fill (suck-in) rate, litres/second, for this vehicle.
function SlurryPipeManager:getFillRate(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return SlurryPipeManager.DEFAULT_LITERS_PER_SECOND end
    return entry.fillLitersPerSecond or entry.litersPerSecond or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
end

-- Empty (push-out / spread) rate, litres/second, for this vehicle.
function SlurryPipeManager:getEmptyRate(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return SlurryPipeManager.DEFAULT_LITERS_PER_SECOND end
    return entry.emptyLitersPerSecond or entry.litersPerSecond or SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
end

-- Single chokepoint for the vacuum/pump split. Returns true only for a tanker that
-- runs the stored-pressure model (pumpType "vacuum"); false for every pump-gated or
-- passive endpoint (HVP, conduit, openTop, no <pressure> block) and for fert/herb
-- sprayers. When false, the caller uses the legacy pump gate (PTO on = flow). Accepts
-- either a vehicle or an already-resolved entry.
function SlurryPipeManager:usesPressureModel(vehicleOrEntry)
    local entry, vehicle
    if vehicleOrEntry ~= nil and vehicleOrEntry.armEntries ~= nil then
        -- A registered entry (entries always carry an armEntries table).
        entry   = vehicleOrEntry
        vehicle = entry.vehicle
    else
        vehicle = vehicleOrEntry
        entry   = self:getVehicleEntry(vehicle)
    end
    if entry == nil then return false end
    local cfg = entry.pressure
    if cfg == nil or cfg.openTop == true then return false end
    if entry.pumpType ~= nil and entry.pumpType ~= "vacuum" then return false end
    if vehicle ~= nil and vehicle.spec_sprayer ~= nil
       and vehicle.spec_sprayer.isFertilizerSprayer == true then
        return false
    end
    return true
end

-- Spreader discharge is driven by stored pressure, not the PTO. For a pressure
-- tanker it is active when set to Pressure (DISCHARGE) and pressure is at/above
-- the flow threshold; for exempt endpoints (HVP / open-top FRC / conduit / fert-herb
-- sprayer / no <pressure> block) it falls back to the pump state. Used by the spreader
-- discharge / work-area gates in ManureBarrelOverride.
function SlurryPipeManager:isSpreaderDischargeActive(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil or entry.state == nil then return false end
    local state = entry.state
    local cfg   = entry.pressure
    if not self:usesPressureModel(entry) then
        return state.pumpRunning == true
    end
    if state.direction ~= SPS_DIRECTION_DISCHARGE then return false end
    return (state.pressure or 0) >= cfg.minThreshold
end

-- True when the spreader's spraying component should be TURNED ON. Discharge is
-- driven by SPS state, not by the pump press or fold: it should be on while the
-- pump is running (building/holding), OR while a spreader valve is open and stored
-- pressure is still discharging (isSpreaderDischargeActive). Used by the turn-state
-- driver in update() and by the setIsTurnedOn guard so vanilla fold/turn calls can't
-- fight it.
function SlurryPipeManager:getSpreaderAnimationName(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    return entry ~= nil and entry.spreaderAnimationName or nil
end

-- Drives the SPS-managed spreader animation from actual discharge. Plays as soon
-- as the valve is open AND slurry is flowing. When flow stops, it does NOT cut the
-- animation immediately — it runs a tail-off (spreaderAnimationStopDelay) so the
-- boom keeps moving while the last of the slurry drains out, matching the discharge
-- effect's fade. If flow resumes during the tail, the stop is cancelled.
function SlurryPipeManager:updateSpreaderAnimations(dt)
    for _, entry in ipairs(self.registeredVehicles) do
        local vehicle = entry.vehicle
        if entry.spreaderAnimationName ~= nil and vehicle ~= nil
           and vehicle.isClient and vehicle.playAnimation ~= nil then
            local controller = self:getBlockageController(vehicle)
            local cstate     = self:getVehicleState(controller)
            -- "Poo is actually being spread" requires slurry in the controlling tank.
            -- Without this, a vacuum tank with the valve open and stored pressure still
            -- above minThreshold would animate the boom on an empty tank. When the tank
            -- drains to 0 mid-spread this goes false and the tail-off below stops it.
            local centry     = self:getVehicleEntry(controller)
            local _, clevel  = self:getPressureFillRatio(controller, centry)
            local hasSlurry  = (clevel ~= nil and clevel > 0)
            local active = self:isSpreaderDischargeActive(controller)
                and cstate ~= nil and cstate.spreaderValveOpen == true
                and hasSlurry

            if active then
                -- Flowing: cancel any pending stop, start the clip if not already running.
                -- Self-healing: vanilla Sprayer:onTurnedOff unconditionally stops/reverses
                -- its own named animations when SPS issues setIsTurnedOn(false) at PTO-off;
                -- if the vehicle names this same clip there, our running clip gets killed
                -- externally. So re-assert whenever the clip is not actually playing.
                entry._spreadAnimTail = nil
                local playing = vehicle.getIsAnimationPlaying == nil
                    or vehicle:getIsAnimationPlaying(entry.spreaderAnimationName)
                if entry._spreadAnimOn ~= true then
                    entry._spreadAnimOn = true
                    vehicle:playAnimation(entry.spreaderAnimationName, 1,
                        vehicle:getAnimationTime(entry.spreaderAnimationName), true)
                    print("[SPS ANIM] spreaderAnimation play (discharging)")
                elseif not playing then
                    vehicle:playAnimation(entry.spreaderAnimationName, 1,
                        vehicle:getAnimationTime(entry.spreaderAnimationName), true)
                end
            elseif entry._spreadAnimOn == true then
                -- Flow stopped: run the tail-off, then stop once it expires.
                -- Keep the clip alive through the tail if something stops it externally.
                if entry._spreadAnimTail == nil then
                    entry._spreadAnimTail = entry.spreaderAnimationStopDelay or 2000
                    print("[SPS ANIM] spreaderAnimation tail start ("
                        .. tostring(entry._spreadAnimTail) .. "ms)")
                end
                entry._spreadAnimTail = entry._spreadAnimTail - dt
                if entry._spreadAnimTail <= 0 then
                    entry._spreadAnimTail = nil
                    entry._spreadAnimOn = false
                    vehicle:stopAnimation(entry.spreaderAnimationName, true)
                    print("[SPS ANIM] spreaderAnimation stop (tail complete)")
                else
                    local playing = vehicle.getIsAnimationPlaying == nil
                        or vehicle:getIsAnimationPlaying(entry.spreaderAnimationName)
                    if not playing then
                        vehicle:playAnimation(entry.spreaderAnimationName, 1,
                            vehicle:getAnimationTime(entry.spreaderAnimationName), true)
                    end
                end
            end
        end
    end
end

-- Vacuum pump sound: slurry01 (filling) until the tank is full, then slurry02
-- (full, higher/dull) for as long as it stays full and the pump runs, and back to
-- slurry01 when emptying. Plays only while the pump is running, only on vacuum
-- tanks, driven by the same fill ratio the pressure model uses.
function SlurryPipeManager:updatePumpSounds(dt)
    for _, entry in ipairs(self.registeredVehicles) do
        local vehicle = entry.vehicle
        if (entry.vacPumpFilling ~= nil or entry.vacPumpFull ~= nil)
           and vehicle ~= nil and vehicle.isClient then
            -- Is the pump running? (same signal the pump action-text uses.)
            local state  = entry.state
            local pumpOn
            if self:isVehicleSelfPowered(vehicle) or self:vehicleHasSpreader(vehicle) then
                pumpOn = state ~= nil and state.pumpRunning == true
            else
                pumpOn = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn()
            end

            local desired = "off"
            if pumpOn then
                local fillRatio = self:getPressureFillRatio(vehicle, entry) or 0
                if fillRatio >= (entry.vacFullThreshold or 0.99) then
                    desired = "full"
                else
                    desired = "filling"
                end
            end

            if desired ~= entry._vacSoundState then
                if entry.vacPumpFilling ~= nil and g_soundManager:getIsSamplePlaying(entry.vacPumpFilling) then
                    g_soundManager:stopSample(entry.vacPumpFilling)
                end
                if entry.vacPumpFull ~= nil and g_soundManager:getIsSamplePlaying(entry.vacPumpFull) then
                    g_soundManager:stopSample(entry.vacPumpFull)
                end
                if desired == "filling" and entry.vacPumpFilling ~= nil then
                    g_soundManager:playSample(entry.vacPumpFilling)
                elseif desired == "full" and entry.vacPumpFull ~= nil then
                    g_soundManager:playSample(entry.vacPumpFull)
                end
                entry._vacSoundState = desired
                --print("[SPS SND] vac pump sound -> " .. desired)
            end
        end
    end
end

function SlurryPipeManager:shouldSpreaderBeOn(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return false end
    -- The TURN-ON state (green icon, PTO spin, PTO power load / working engine
    -- sound) follows the pump button ONLY. Pressing PTO off at the headland must
    -- immediately whiten the tanker icon, disengage the PTO and drop the working
    -- sound — even though the spreader valve stays open and stored pressure keeps
    -- pumping slurry out. The discharge itself is NOT driven from here: it runs off
    -- the stored-pressure gate in the work-area / discharge overrides (which no
    -- longer require turnOn), so spreading continues to taper while this is false.
    return state.pumpRunning == true
end

-- Returns a short HUD string for the stored pressure, e.g. "+1.2 Bar", "-0.8 Bar",
-- or "0.0 Bar" at rest. Returns nil only when this vehicle has no pressure system at
-- all (not registered, open-top/exempt, or a fert/herb sprayer). Used by the
-- fill-levels HUD override to append the reading after the fill type name. Sign
-- convention matches the model: + = pressure (discharge side), - = vacuum (fill
-- side); zero is shown unsigned.
-- Returns a short HUD string for the per-tanker working gauge, appended after the
-- fill type name in the fill-levels HUD.
--   * vacuum tanker  -> stored pressure, e.g. "+1.2 Bar" / "-0.8 Bar" / "0.0 Bar".
--   * HVP tanker     -> effective flow rate, e.g. "▸ 695 L/s" (discharge) / "◂ 695 L/s"
--                       (fill), scaled by slurry thickness so thick slurry shows a lower
--                       number; nil while the pump is off.
--   * conduit / openTop / fert-herb / unregistered -> nil (no per-tanker gauge here).
function SlurryPipeManager:getPressureInfoText(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return nil end
    local cfg = entry.pressure
    if cfg == nil or cfg.openTop == true then return nil end
    if vehicle.spec_sprayer ~= nil and vehicle.spec_sprayer.isFertilizerSprayer == true then
        return nil
    end

    -- HVP: show the pump's working effort as a percentage rather than a litre rate.
    -- 100% = clean slurry pumping at full rate; the figure falls as slurry thickens
    -- (20% thick -> ~80%, 50% -> ~50%, blocked -> 0%), conveying "the pump is only
    -- working at this fraction of full efficiency". Always visible (parity with the
    -- vacuum bar gauge), and reads 0% whenever nothing is flowing (pump off). ">>" =
    -- pumping out (discharge), "<<" = pumping in (fill). ASCII only (no font glyphs).
    -- HVP: show the effective (thickness-adjusted) flow rate in litres/second.
    -- baseRate is the tanker's own <flow litersPerSecond>; the thickness multiplier
    -- scales it down as slurry thickens (clean = full rate, thicker = less, blocked = 0).
    -- Always visible (parity with the vacuum bar gauge), including empty and pump-off,
    -- and reads 0 L/s when nothing is flowing. ">>" = pumping out, "<<" = pumping in.
    if entry.pumpType == "HVP" then
        local state = entry.state
        if state == nil or state.pumpRunning ~= true then
            return "0 L/s"
        end
        local discharging = (state.direction == SPS_DIRECTION_DISCHARGE)
        local baseRate = discharging and self:getEmptyRate(vehicle) or self:getFillRate(vehicle)
        local mult     = self:thicknessToFlowMultiplier(self:getTankerThickness(vehicle))
        local rate     = baseRate * mult
        local marker   = discharging and ">>" or "<<"
        return string.format("%s %d L/s", marker, MathUtil.round(rate))
    end

    -- Conduit pumps have their own HUD; no per-tanker gauge here.
    if entry.pumpType == "conduit" then return nil end

    -- vacuum (and any other pressure-model tanker): stored ±bar gauge.
    local p = (entry.state ~= nil and entry.state.pressure) or 0
    local sign = ""
    if p >= 0.05 then
        sign = "+"
    elseif p <= -0.05 then
        sign = "-"
    end
    return string.format("%s%.1f Bar", sign, math.abs(p))
end

-- Returns (scalar, usesPressure) for a vehicle's flow rate.
--   usesPressure = true  -> a real tanker: flow is gated/scaled by stored pressure,
--                           NOT by the PTO. scalar = |pressure|/maxPressure, or 0
--                           when |pressure| < minThreshold (no flow).
--   usesPressure = false -> exempt endpoint (open-top FRC, fert/herb sprayer, or no
--                           <pressure> block, e.g. conduit pump): scalar = 1.0 and the
--                           caller keeps its normal pump gate. Behaviour unchanged.
function SlurryPipeManager:getPressureFlowScalar(vehicle)
    local entry = self:getVehicleEntry(vehicle)
    if entry == nil then return 1.0, false end
    local cfg = entry.pressure
    if not self:usesPressureModel(entry) then return 1.0, false end
    local maxP = cfg.maxPressure
    if maxP <= 0 then maxP = SlurryPipeManager.DEFAULT_MAX_PRESSURE end
    local p = math.abs((entry.state ~= nil and entry.state.pressure) or 0)
    if p < cfg.minThreshold then return 0.0, true end
    return math.min(1.0, p / maxP), true
end

-- Resolves the effective pipe/arm flow for a tanker once its valve is confirmed open.
-- Returns (flowDir, scalar):
--   flowDir = SPS_DIRECTION_FILL or SPS_DIRECTION_DISCHARGE, or nil for no flow
--   scalar  = rate multiplier applied to baseLitersPerSecond
--
-- The core of the pressure system: stored pressure drives flow in its built direction
-- whenever |pressure| >= minThreshold, PTO on or off.
--   * FILL: a vacuum at/above minThreshold draws slurry IN. You must build the vacuum to
--     min before any fill starts (so opening the valve + starting the PTO from zero does
--     nothing until min is reached), but once the vacuum exists it fills on its own —
--     including stored vacuum with the PTO already off (taper).
--   * DISCHARGE: pressure at/above minThreshold pushes slurry OUT, likewise on stored
--     pressure after the PTO is off (taper).
--   * Exempt endpoint (conduit pump / open-top FRC / fert sprayer, usesPressure=false):
--     legacy pump gate — flows in state.direction at full rate only while the PTO runs.
--   * GRAVITY / BACKFLOW: once the PTO is off AND the stored pressure has bled below
--     minThreshold, a tanker that still holds slurry drains OUT by gravity (DISCHARGE) at
--     gravityFlowScalar until the valve is closed by hand or the tank empties. After a
--     FILL this is the "vacuum falls to nothing, then it flows backwards and empties"
--     behaviour; after a DISCHARGE it continues the drain past the pressure taper.
function SlurryPipeManager:resolveCouplingFlow(vehicle, state, pumpRunning, hasContent)
    local pScalar, usesPressure = self:getPressureFlowScalar(vehicle)

    if not usesPressure then
        if pumpRunning then return state.direction, 1.0 end
        return nil, 0.0
    end

    -- Stored pressure/vacuum at or above threshold drives flow in its built direction.
    if pScalar > 0 then
        return state.direction, pScalar
    end

    -- Pressure spent (|pressure| < minThreshold) and the PTO is not replenishing it:
    -- gravity backflow OUT while slurry remains.
    if not pumpRunning and hasContent then
        local entry = self:getVehicleEntry(vehicle)
        local g = SlurryPipeManager.DEFAULT_GRAVITY_FLOW_SCALAR
        if entry ~= nil and entry.pressure ~= nil and entry.pressure.gravityFlowScalar ~= nil then
            g = entry.pressure.gravityFlowScalar
        end
        if g > 0 then
            return SPS_DIRECTION_DISCHARGE, g
        end
    end

    return nil, 0.0
end

function SlurryPipeManager:buildFlowSession(vehicle)
    local fillLPS  = SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local emptyLPS = SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local vehicleFillUnit = 1
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            fillLPS  = entry.fillLitersPerSecond  or entry.litersPerSecond or fillLPS
            emptyLPS = entry.emptyLitersPerSecond or entry.litersPerSecond or emptyLPS
            if #entry.armEntries > 0 then
                vehicleFillUnit = entry.armEntries[1].fillUnitIndex
            elseif #entry.couplingEntries > 0 then
                vehicleFillUnit = entry.couplingEntries[1].fillUnitIndex
            end
            break
        end
    end
    return {
        vehicle               = vehicle,
        vehicleFillUnit       = vehicleFillUnit,
        baseLitersPerSecond   = emptyLPS,   -- legacy field = empty rate
        baseFillLitersPerSecond  = fillLPS,
        baseEmptyLitersPerSecond = emptyLPS,
    }
end

-- ---------------------------------------------------------------------------
-- Arc overlap detection
-- Coupling node structure: mountNode -> child(0) = ArcsNode -> child(0) = Arc01, child(1) = Arc02
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_getCouplingArcNodes(coupling)
    -- Chain terminus: detNode01 IS the apex, its children are arc02/arc03
    if coupling.isChainTerminus then
        local apexNode = coupling.mountNode
        if apexNode == nil or apexNode == 0 or not entityExists(apexNode) then return nil, nil, nil end
        if getNumOfChildren(apexNode) < 2 then return nil, nil, nil end
        local arc1 = getChildAt(apexNode, 0)
        local arc2 = getChildAt(apexNode, 1)
        if arc1 == nil or arc1 == 0 or arc2 == nil or arc2 == 0 then return nil, nil, nil end
        if not entityExists(arc1) or not entityExists(arc2) then return nil, nil, nil end
        return apexNode, arc1, arc2
    end
    local baseNode = coupling.arcNode or coupling.mountNode
    if baseNode == nil or baseNode == 0 or not entityExists(baseNode) then return nil, nil, nil end
    if getNumOfChildren(baseNode) == 0 then return nil, nil, nil end
    local arcsNode = getChildAt(baseNode, 0)
    if arcsNode == nil or arcsNode == 0 or not entityExists(arcsNode) then return nil, nil, nil end
    if getNumOfChildren(arcsNode) < 2 then return nil, nil, nil end
    local arc1 = getChildAt(arcsNode, 0)
    local arc2 = getChildAt(arcsNode, 1)
    if arc1 == nil or arc1 == 0 or arc2 == nil or arc2 == 0 then return nil, nil, nil end
    if not entityExists(arc1) or not entityExists(arc2) then return nil, nil, nil end
    return arcsNode, arc1, arc2
end

-- Returns true if the world-space point (px,pz) lies inside this coupling's own
-- arc triangle (apex, arc1, arc2). Used so the player must physically stand
-- inside a coupling's arc for that coupling to become the selected one.
-- Returns false when the coupling has no resolvable arc geometry — callers then
-- fall back to a proximity radius.
function SlurryPipeManager:isPointInCouplingArc(coupling, px, pz)
    if coupling == nil then return false end
    local apex, arc1, arc2 = self:_getCouplingArcNodes(coupling)
    if apex == nil or arc1 == nil or arc2 == nil then return false end
    if not entityExists(apex) or not entityExists(arc1) or not entityExists(arc2) then return false end
    local ax, _, az   = getWorldTranslation(apex)
    local b1x, _, b1z = getWorldTranslation(arc1)
    local b2x, _, b2z = getWorldTranslation(arc2)
    -- Same point-in-triangle test used by _arcsOverlap, triangle = (apex, arc1, arc2)
    local d1 = (px - b1x) * (az - b1z)  - (ax - b1x)  * (pz - b1z)
    local d2 = (px - b2x) * (b1z - b2z) - (b1x - b2x) * (pz - b2z)
    local d3 = (px - ax)  * (b2z - az)  - (b2x - ax)  * (pz - az)
    local hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    local hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (hasNeg and hasPos)
end

function SlurryPipeManager:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B)
    -- Validate all nodes exist before accessing them
    if not entityExists(apexA) or not entityExists(arc1A) or not entityExists(arc2A) then return false end
    if not entityExists(apexB) or not entityExists(arc1B) or not entityExists(arc2B) then return false end
    
    local function pointInTri(px, pz, ax, az, bx, bz, cx, cz)
        local d1 = (px-bx)*(az-bz) - (ax-bx)*(pz-bz)
        local d2 = (px-cx)*(bz-cz) - (bx-cx)*(pz-cz)
        local d3 = (px-ax)*(cz-az) - (cx-ax)*(pz-az)
        local hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0)
        local hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0)
        return not (hasNeg and hasPos)
    end
    local function segmentsIntersect(ax, az, bx, bz, cx, cz, dx, dz)
        local d1x, d1z = bx - ax, bz - az
        local d2x, d2z = dx - cx, dz - cz
        local cross = d1x * d2z - d1z * d2x
        if math.abs(cross) < 1e-8 then return false end
        local tx = ((cx - ax) * d2z - (cz - az) * d2x) / cross
        local ux = ((cx - ax) * d1z - (cz - az) * d1x) / cross
        return tx >= 0 and tx <= 1 and ux >= 0 and ux <= 1
    end
    local aax, _, aaz = getWorldTranslation(apexA)
    local a1x, _, a1z = getWorldTranslation(arc1A)
    local a2x, _, a2z = getWorldTranslation(arc2A)
    local abx, _, abz = getWorldTranslation(apexB)
    local b1x, _, b1z = getWorldTranslation(arc1B)
    local b2x, _, b2z = getWorldTranslation(arc2B)
    local bInA = pointInTri(abx,abz,aax,aaz,a1x,a1z,a2x,a2z)
             or  pointInTri(b1x,b1z,aax,aaz,a1x,a1z,a2x,a2z)
             or  pointInTri(b2x,b2z,aax,aaz,a1x,a1z,a2x,a2z)
    local aInB = pointInTri(aax,aaz,abx,abz,b1x,b1z,b2x,b2z)
             or  pointInTri(a1x,a1z,abx,abz,b1x,b1z,b2x,b2z)
             or  pointInTri(a2x,a2z,abx,abz,b1x,b1z,b2x,b2z)
    if bInA or aInB then return true end
    local edgesA = {{aax,aaz,a1x,a1z},{aax,aaz,a2x,a2z},{a1x,a1z,a2x,a2z}}
    local edgesB = {{abx,abz,b1x,b1z},{abx,abz,b2x,b2z},{b1x,b1z,b2x,b2z}}
    for _, ea in ipairs(edgesA) do
        for _, eb in ipairs(edgesB) do
            if segmentsIntersect(ea[1],ea[2],ea[3],ea[4],eb[1],eb[2],eb[3],eb[4]) then
                return true
            end
        end
    end
    return false
end

-- Returns the first coupling whose arc overlaps with the given coupling.
-- Checks both vehicle couplings and placeable store couplings.
-- ---------------------------------------------------------------------------
-- Check if any coupling exists within specified distance (simple presence check)
-- Used for extended zone checks when starting chain laying
-- ---------------------------------------------------------------------------
function SlurryPipeManager:hasNearbyCoupling(coupling, maxDistance)
    if coupling == nil then return false end
    
    local apexA = coupling.mountNode
    if apexA == nil or not entityExists(apexA) then return false end
    
    local ax, ay, az = getWorldTranslation(apexA)
    
    -- Check vehicle couplings.
    -- Skip the vehicle that owns `coupling` entirely. A tanker's own couplers
    -- (and any duplicate-registered couplers sharing a mount node on the same
    -- vehicle, e.g. config-gated entries that both resolved) sit within the
    -- radius of each other and must never block that vehicle from laying.
    for _, vEntry in ipairs(self.registeredVehicles) do
        local ownsCoupling = false
        for _, vc in ipairs(vEntry.couplingEntries) do
            if vc == coupling then ownsCoupling = true break end
        end
        if not ownsCoupling then
            for _, vc in ipairs(vEntry.couplingEntries) do
                local apexB = vc.mountNode
                if apexB ~= nil and entityExists(apexB) then
                    local bx, by, bz = getWorldTranslation(apexB)
                    local dist = MathUtil.vector3Length(ax-bx, ay-by, az-bz)
                    if dist <= maxDistance then
                        SlurryDebug.log(string.format(
                            "hasNearbyCoupling: coupling id=%s blocked by foreign vehicle coupler id=%s dist=%.2f",
                            tostring(coupling.id), tostring(vc.id), dist))
                        return true
                    end
                end
            end
        end
    end
    
    -- Check placeable couplings
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc ~= coupling and (coupling.placeable == nil or sc.placeable ~= coupling.placeable) then
                    local apexB = sc.mountNode
                    if apexB ~= nil and entityExists(apexB) then
                        local bx, by, bz = getWorldTranslation(apexB)
                        local dist = MathUtil.vector3Length(ax-bx, ay-by, az-bz)
                        if dist <= maxDistance then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    -- Check chain terminus couplings
    for _, ct in ipairs(self.chainTerminusEntries) do
        if ct ~= coupling then
            local apexB = ct.mountNode
            if apexB ~= nil and entityExists(apexB) then
                local bx, by, bz = getWorldTranslation(apexB)
                local dist = MathUtil.vector3Length(ax-bx, ay-by, az-bz)
                if dist <= maxDistance then
                    return true
                end
            end
        end
    end
    
    return false
end

-- ---------------------------------------------------------------------------
-- Find first overlapping coupling within connection distance
-- ---------------------------------------------------------------------------
function SlurryPipeManager:findOverlappingCoupler(coupling)
    -- Already connected — no new connection possible
    if coupling.isConnected then return nil end
    local apexA, arc1A, arc2A = self:_getCouplingArcNodes(coupling)
    if apexA == nil or not entityExists(apexA) then return nil end

    local apexAx, apexAy, apexAz = getWorldTranslation(apexA)

    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, vc in ipairs(vEntry.couplingEntries) do
            if vc ~= coupling and not vc.isConnected then
                -- Skip if this coupling is a chain anchor with active segments
                local hasChain = false
                for _, chain in ipairs(self.pipeChains) do
                    if chain.anchorCoupling == vc and #chain.segments > 0 then
                        hasChain = true
                        break
                    end
                end
                if not hasChain then
                    local apexB, arc1B, arc2B = self:_getCouplingArcNodes(vc)
                    if apexB ~= nil and entityExists(apexB) then
                        local bx, by, bz = getWorldTranslation(apexB)
                        if MathUtil.vector3Length(apexAx-bx, apexAy-by, apexAz-bz) <= SPS_MAX_CONNECT_DIST then
                            if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                                return vc
                            end
                        end
                    end
                end
            end
        end
    end

    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc ~= coupling
                and (coupling.placeable == nil or sc.placeable ~= coupling.placeable)
                and not sc.isConnected
                and (not sc.deployable or sc.isDeployed) then
                    -- Skip if this coupling is a chain anchor with active segments
                    local hasChain = false
                    for _, chain in ipairs(self.pipeChains) do
                        if chain.anchorCoupling == sc and #chain.segments > 0 then
                            hasChain = true
                            break
                        end
                    end
                    if not hasChain then
                        local apexB, arc1B, arc2B = self:_getCouplingArcNodes(sc)
                        if apexB ~= nil and entityExists(apexB) then
                            local bx, by, bz = getWorldTranslation(apexB)
                            if MathUtil.vector3Length(apexAx-bx, apexAy-by, apexAz-bz) <= SPS_MAX_CONNECT_DIST then
                                if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                                    return sc
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Chain terminus arcs — laid pipe ends a vehicle can connect to
    -- Pick the closest overlapping terminus within maxPipeLength
    local bestCt   = nil
    local bestDist = math.huge
    local apexAx, _, apexAz = getWorldTranslation(apexA)
    for _, ct in ipairs(self.chainTerminusEntries) do
        if ct ~= coupling and not ct.isConnected then
            local isOwnChain
            if ct.isChainStart then
                if ct.chain ~= nil and ct.chain.anchorCoupling == coupling then
                    -- This coupling is the current anchor — block if already connected
                    -- or if it's a placeable (placeables don't reconnect)
                    isOwnChain = coupling.placeable ~= nil or ct.isConnected
                else
                    -- Chain start is disconnected — any vehicle coupling may pick it up.
                    -- Only block placeable couplings from connecting to a chain start.
                    isOwnChain = coupling.placeable ~= nil
                end
            else
                -- chainEnd: skip if caller is the own chain anchor
                isOwnChain = ct.chain ~= nil and ct.chain.anchorCoupling == coupling
            end
            if not isOwnChain then
                local apexB, arc1B, arc2B = self:_getCouplingArcNodes(ct)
                if apexB ~= nil and entityExists(apexB) then
                    if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                        local bx, _, bz = getWorldTranslation(apexB)
                        local d = MathUtil.vector3Length(apexAx - bx, 0, apexAz - bz)
                        if d < bestDist then
                            bestDist = d
                            bestCt   = ct
                        end
                    end
                end
            end
        end
    end
    if bestCt ~= nil then return bestCt end

    return nil
end

function SlurryPipeManager:_findCouplingOwner(coupling)
    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, c in ipairs(vEntry.couplingEntries) do
            if c == coupling then return vEntry.vehicle, nil end
        end
    end
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc == coupling then return nil, pEntry.placeable end
            end
        end
    end
    return nil, nil
end

function SlurryPipeManager:_findCouplingById(vehicleOrPlaceable, couplingId, isPlaceable)
    if not isPlaceable then
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.vehicle == vehicleOrPlaceable then
                for _, c in ipairs(vEntry.couplingEntries) do
                    if c.id == couplingId then return c end
                end
            end
        end
    else
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.placeable == vehicleOrPlaceable then
                if pEntry.storeCouplings ~= nil then
                    for _, sc in ipairs(pEntry.storeCouplings) do
                        if sc.id == couplingId then return sc end
                    end
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Coupling connect / disconnect / valve handlers
-- Called from SPSPipeActivatable. Authority check here.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onCouplerConnect(vehicle, coupling)
    if g_server == nil then
        SlurryPipeConnectEvent.sendEvent(vehicle, nil, 0, coupling.id, 0)
        return
    end

    local otherCoupling = self:findOverlappingCoupler(coupling)
    if otherCoupling == nil then
        print("[SPS] onCouplerConnect: no overlapping coupler")
        return
    end

--    print("[SPS TRACE] ===== onCouplerConnect (player activated) =====")
    self:_traceCoupling("onCouplerConnect.coupling(activated)", coupling)
    self:_traceCoupling("onCouplerConnect.otherCoupling(found)", otherCoupling)

    -- Both couplers must be free to connect
    if coupling.isConnected then
        print("[SPS] onCouplerConnect: source coupling already connected")
        return
    end
    if otherCoupling.isConnected then
        print("[SPS] onCouplerConnect: target coupling already connected")
        return
    end

    -- Determine owners — vehicle is nil when coupling is on a placeable
    local ownerA = vehicle or coupling.placeable
    local targetVehicle, targetPlaceable = self:_findCouplingOwner(otherCoupling)
    local ownerB = targetVehicle or targetPlaceable

    local targetType = targetVehicle ~= nil
        and SlurryPipeConnectEvent.TARGET_TYPE_VEHICLE
        or  SlurryPipeConnectEvent.TARGET_TYPE_PLACEABLE

    -- Apply directly using coupling objects — no ID lookup needed on this machine
    self:applyConnectCouplings(coupling, otherCoupling, ownerA, ownerB)

    -- Broadcast for MP (vehicle may be nil for placeable-initiated connections)
    SlurryPipeConnectEvent.sendEvent(vehicle or ownerA, ownerB, targetType, coupling.id, otherCoupling.id)
end

-- applyConnectCouplings — called locally with the actual coupling objects.
-- Avoids the ID lookup ambiguity that breaks placeable-initiated connections.
function SlurryPipeManager:applyConnectCouplings(couplingA, couplingB, ownerA, ownerB)
--    print("[SPS TRACE] ===== applyConnectCouplings =====")
    self:_traceCoupling("applyConnect.couplingA", couplingA)
    self:_traceCoupling("applyConnect.couplingB", couplingB)
    couplingA.isConnected              = true
    couplingA.connectedTarget          = ownerB
    couplingA.connectedPartnerCoupling = couplingB

    couplingB.isConnected              = true
    couplingB.connectedTarget          = ownerA
    couplingB.connectedPartnerCoupling = couplingA

    -- If a vehicle coupling is connecting to a chainStartCoupling, re-anchor the chain
    -- to the new vehicle coupling so any coupling on the tanker can own the chain.
    local function reAnchorIfNeeded(vehicleCoupling, chainStartCoupling)
        if chainStartCoupling == nil or not chainStartCoupling.isChainStart then return end
        if chainStartCoupling.chain == nil then return end
        local chain = chainStartCoupling.chain
        local oldAnchor = chain.anchorCoupling
        if oldAnchor == vehicleCoupling then return end
        if oldAnchor ~= nil and oldAnchor.chainActivatable ~= nil then
            oldAnchor.chainActivatable.chain = nil
        end
        chain.anchorCoupling = vehicleCoupling
        if vehicleCoupling.chainActivatable ~= nil then
            vehicleCoupling.chainActivatable.chain = chain
        end
        --print("[SPS] applyConnectCouplings: chain re-anchored from coupling id="
            --.. tostring(oldAnchor and oldAnchor.id) .. " to id=" .. tostring(vehicleCoupling.id))
    end
    reAnchorIfNeeded(couplingA, couplingB)
    reAnchorIfNeeded(couplingB, couplingA)

    if g_spsPipeVisual ~= nil and g_spsPipeVisual:isReady() then
        -- Determine which coupling is the lead (start of bez pipe).
        -- Default: couplingA is lead unless couplingB is a chain terminus.
        -- Chain terminus connections: chain terminus is always the lead.
        local leadCoupling, followCoupling = couplingA, couplingB
        local swapped = false
        
        -- If B is a chain terminus (not chain start), swap so chain is lead
        if couplingB.isChainTerminus and not couplingB.isChainStart then
            leadCoupling, followCoupling = couplingB, couplingA
            swapped = true
        end
        
        -- Determine connection nodes: lead uses inNode, follow uses outNode
        local nodeA = leadCoupling.inNode or leadCoupling.mountNode
        local nodeB = followCoupling.outNode or followCoupling.mountNode
        
        -- Chain segment overrides
        if leadCoupling.isChainTerminus and leadCoupling.chain ~= nil and not leadCoupling.isChainStart then
            local segs = leadCoupling.chain.segments
            if #segs > 0 then nodeA = segs[#segs].endConnectors end
        elseif leadCoupling.isChainStart and leadCoupling.chain ~= nil then
            local segs = leadCoupling.chain.segments
            if #segs > 0 then nodeA = segs[1].pipeRoot end
        end
        
        if followCoupling.isChainTerminus and followCoupling.chain ~= nil and not followCoupling.isChainStart then
            local segs = followCoupling.chain.segments
            if #segs > 0 then nodeB = segs[#segs].endConnectors end
        elseif followCoupling.isChainStart and followCoupling.chain ~= nil then
            local segs = followCoupling.chain.segments
            if #segs > 0 then nodeB = segs[1].pipeRoot end
        end
        
        local startConnType = (leadCoupling.connectorType ~= nil) and leadCoupling.connectorType or "male"
        local endConnType   = (followCoupling.connectorType ~= nil) and followCoupling.connectorType or "female"
        
        --print(string.format("[SPS] applyConnectCouplings: swapped=%s lead.isChainTerminus=%s follow.isChainTerminus=%s lead.isChainStart=%s follow.isChainStart=%s",
        --    tostring(swapped),
        --    tostring(leadCoupling.isChainTerminus), tostring(followCoupling.isChainTerminus),
        --    tostring(leadCoupling.isChainStart),    tostring(followCoupling.isChainStart)))

        -- [SPS TRACE] Which coupling ended up lead/follow, and the EXACT nodes the
        -- bez pipe will use. nodeA = pipe START (pipeRoot), nodeB = pipe END (endConnectors).
--        print(string.format("[SPS TRACE] applyConnect: LEAD id=%s (inNode used=%s) | FOLLOW id=%s (outNode used=%s)",
--            tostring(leadCoupling.id),   tostring(leadCoupling.inNode ~= nil and not (leadCoupling.isChainTerminus and leadCoupling.chain ~= nil)),
--            tostring(followCoupling.id), tostring(followCoupling.outNode ~= nil and not (followCoupling.isChainTerminus and followCoupling.chain ~= nil))))
        self:_traceNode("applyConnect.nodeA(pipe START)", nodeA)
        self:_traceNode("applyConnect.nodeB(pipe END)",   nodeB)
--        print("[SPS TRACE] applyConnect: startConnType=" .. tostring(startConnType) .. " endConnType=" .. tostring(endConnType))

        local inst = g_spsPipeVisual:createPipe(nodeA, nodeB, startConnType, endConnType, false, false)
        if inst ~= nil then
            local pipeId = self._nextPipeId
            self._nextPipeId = self._nextPipeId + 1
            local cr = self.currentPipeColor.r
            local cg = self.currentPipeColor.g
            local cb = self.currentPipeColor.b
            g_spsPipeVisual:applyColor(inst, cr, cg, cb)
            -- Bez pipe end connector visibility based on lead/follow
            if followCoupling.isChainStart and inst.endConnectors ~= nil then
                inst.connectorEndFlipped = true
                local femaleConn = getChildAt(inst.endConnectors, 0)
                local maleConn   = getChildAt(inst.endConnectors, 1)
                if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, true) end
                if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, false) end
            elseif followCoupling.isChainTerminus and not followCoupling.isChainStart and inst.endConnectors ~= nil then
                local femaleConn = getChildAt(inst.endConnectors, 0)
                local maleConn   = getChildAt(inst.endConnectors, 1)
                if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, false) end
                if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, true) end
            elseif leadCoupling.isChainStart and inst.startConnectors ~= nil then
                local femaleConn = getChildAt(inst.startConnectors, 0)
                local maleConn   = getChildAt(inst.startConnectors, 1)
                if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, true) end
                if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, false) end
            end
            self.activePipes[pipeId] = { inst = inst, couplingA = couplingA, couplingB = couplingB, colorR = cr, colorG = cg, colorB = cb }
            couplingA.pipeId = pipeId
            couplingB.pipeId = pipeId
        else
            print("[SPS] applyConnectCouplings: WARNING pipe visual createPipe returned nil")
        end
    else
        print("[SPS] applyConnectCouplings: WARNING g_spsPipeVisual not ready, no visual created")
    end

    -- Play connector animations forward on both ends (no-op if not bound).
    if SPSCouplerAnimator ~= nil then
        if couplingA.connectorAnim ~= nil then SPSCouplerAnimator.play(couplingA.connectorAnim, 1) end
        if couplingB.connectorAnim ~= nil then SPSCouplerAnimator.play(couplingB.connectorAnim, 1) end
    end

end

function SlurryPipeManager:onCouplerDisconnect(vehicle, coupling)
    -- Valve must be closed
    if coupling.valveOpen then
        print("[SPS] onCouplerDisconnect: REFUSED - valve is open on coupling id=" .. tostring(coupling.id))
        if g_currentMission ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_slurryCloseValveFirst"), 2000)
        end
        return
    end


    if g_server == nil then
        SlurryPipeDisconnectEvent.sendEvent(vehicle, coupling.id)
        return
    end

    -- Pass the coupling object directly to avoid id-ambiguity with multiple
    -- identical placeable instances that share the same coupling id numbers.
    self:applyDisconnect(vehicle, coupling.id, coupling)
    SlurryPipeDisconnectEvent.sendEvent(vehicle, coupling.id)
end

-- applyDisconnect: couplingObj is the actual coupling table when available (local path).
-- The network event path passes only vehicle+couplingId, which falls back to id search.
function SlurryPipeManager:applyDisconnect(vehicle, couplingId, couplingObj)
    local coupling = couplingObj
    if coupling == nil then
        coupling = self:_findCouplingById(vehicle, couplingId, false)
        if coupling == nil then
            -- Try placeable — note: ambiguous with multiple identical placeables,
            -- but this path is only hit from the network event on remote clients.
            for _, pEntry in ipairs(self.registeredPlaceables) do
                if pEntry.storeCouplings ~= nil then
                    for _, sc in ipairs(pEntry.storeCouplings) do
                        if sc.id == couplingId then coupling = sc break end
                    end
                end
                if coupling ~= nil then break end
            end
        end
    end
    if coupling == nil then
        print("[SPS] applyDisconnect: coupling id=" .. tostring(couplingId) .. " not found")
        return
    end

    local partner = coupling.connectedPartnerCoupling

    -- Destroy pipe visual
    if coupling.pipeId ~= nil then
        local pipeData = self.activePipes[coupling.pipeId]
        if pipeData ~= nil and g_spsPipeVisual ~= nil then
            g_spsPipeVisual:destroyPipe(pipeData.inst)
            self.activePipes[coupling.pipeId] = nil
        else
            print("[SPS] applyDisconnect: WARNING pipeId=" .. tostring(coupling.pipeId) .. " had no pipeData in activePipes")
        end
        coupling.pipeId = nil
        if partner ~= nil then partner.pipeId = nil end
    else
        print("[SPS] applyDisconnect: WARNING coupling id=" .. tostring(couplingId) .. " had no pipeId - no visual to destroy")
    end

    -- Stop any active flow
    if coupling.connectedTarget ~= nil and vehicle ~= nil then
        self:stopFlow(vehicle)
    end

    -- Capture valveOpen state before clearing so we know whether to play valveAnim reverse
    local wasValveOpen = (coupling.valveOpen == true) or (partner ~= nil and partner.valveOpen == true)

    -- Clear state on both ends
    coupling.isConnected             = false
    coupling.valveOpen               = false
    coupling.connectedTarget         = nil
    coupling.connectedPartnerCoupling = nil

    if partner ~= nil then
        partner.isConnected              = false
        partner.valveOpen                = false
        partner.connectedTarget          = nil
        partner.connectedPartnerCoupling = nil
        local partnerVehicle, _ = self:_findCouplingOwner(partner)
        if partnerVehicle ~= nil then self:stopFlow(partnerVehicle) end
    else
        print("[SPS] applyDisconnect: WARNING no partner found for coupling id=" .. tostring(couplingId))
    end

    -- Free chain binding: if this disconnect breaks a vehicle/placeable coupling
    -- ↔ chainStart bez, the chain becomes a free-standing world entity. The
    -- coupling is no longer "owned by" the chain, so it can immediately lay a
    -- new first pipe or accept a new connection. Reconnect re-binds via
    -- reAnchorIfNeeded in applyConnectCouplings (handles oldAnchor == nil).
    local function freeChainBindingIfNeeded(c, p)
        if c == nil or p == nil then return end
        if not p.isChainStart then return end
        if p.chain == nil then return end
        local chain = p.chain
        if chain.anchorCoupling ~= c then return end
        -- Cache the world position so the chain saves correctly without an
        -- anchorCoupling reference (SPSPipeChain:getSaveData falls back to it).
        if c.mountNode ~= nil and c.mountNode ~= 0 and entityExists(c.mountNode) then
            chain.anchorX, chain.anchorY, chain.anchorZ = getWorldTranslation(c.mountNode)
        end
        chain.anchorCoupling = nil
        if c.chainActivatable ~= nil then c.chainActivatable.chain = nil end
        print(string.format(
            "[SPS] applyDisconnect: freed chain anchor binding — coupling id=%s released (chain remains, segments=%d)",
            tostring(c.id), #chain.segments))
    end
    freeChainBindingIfNeeded(coupling, partner)
    freeChainBindingIfNeeded(partner, coupling)

    -- Play connector animations reverse on both ends (no-op if not bound).
    -- Also play valve animations reverse if the valve was open at disconnect time —
    -- so the valve handle returns to closed regardless of which side initiates removal.
    if SPSCouplerAnimator ~= nil then
        if coupling.connectorAnim ~= nil then SPSCouplerAnimator.play(coupling.connectorAnim, -1) end
        if partner ~= nil and partner.connectorAnim ~= nil then SPSCouplerAnimator.play(partner.connectorAnim, -1) end
        if wasValveOpen then
            if coupling.valveAnim ~= nil then SPSCouplerAnimator.play(coupling.valveAnim, -1) end
            if partner ~= nil and partner.valveAnim ~= nil then SPSCouplerAnimator.play(partner.valveAnim, -1) end
        end
    end

end

function SlurryPipeManager:onValveOpen(vehicle, coupling)
    if not coupling.isConnected then return end
    if coupling.valveOpen then return end

    print(string.format("[SPS valve] onValveOpen: coupling.id=%s isChainTerminus=%s partner.id=%s",
        tostring(coupling.id), tostring(coupling.isChainTerminus),
        tostring(coupling.connectedPartnerCoupling and coupling.connectedPartnerCoupling.id or nil)))

    if g_server == nil then
        SlurryValveStateEvent.sendEvent(vehicle, coupling, true)
        return
    end

    self:applyValveState(vehicle, coupling.id, true, coupling)
    SlurryValveStateEvent.sendEvent(vehicle, coupling, true)

    -- Propagate through chain: if the connected partner is a chain terminus,
    -- walk to the far end and open that coupling too.
    self:_propagateValveState(coupling, true)
end

function SlurryPipeManager:onValveClose(vehicle, coupling)
    if not coupling.isConnected then return end
    if not coupling.valveOpen then return end

    if g_server == nil then
        SlurryValveStateEvent.sendEvent(vehicle, coupling, false)
        return
    end

    self:applyValveState(vehicle, coupling.id, false, coupling)
    SlurryValveStateEvent.sendEvent(vehicle, coupling, false)

    -- Propagate through chain: if the connected partner is a chain terminus,
    -- walk to the far end and close that coupling too.
    self:_propagateValveState(coupling, false)
end

-- Walk a chain to find the coupling at the opposite end from the given coupling,
-- then apply and broadcast the valve state to it.
function SlurryPipeManager:_propagateValveState(coupling, open)
    local partner = coupling.connectedPartnerCoupling
    if partner == nil then
        print("[SPS valve] _propagateValveState: partner is nil, abort")
        return
    end

    print(string.format("[SPS valve] _propagateValveState: partner.id=%s isChainTerminus=%s partner.chain=%s",
        tostring(partner.id), tostring(partner.isChainTerminus), tostring(partner.chain ~= nil)))

    -- Find the far-end coupling by walking: if partner is a chain terminus,
    -- get the chain, find the other terminus that is connected, open/close it.
    local farEnd = nil
    if partner.isChainTerminus and partner.chain ~= nil then
        local chain = partner.chain
        -- Walk all terminus entries for this chain looking for the connected far end
        for _, ct in ipairs(self.chainTerminusEntries) do
            print(string.format("[SPS valve]   walk: ct.id=%s ct.chain=match=%s ct.isConnected=%s ct~=partner=%s",
                tostring(ct.id), tostring(ct.chain == chain), tostring(ct.isConnected), tostring(ct ~= partner)))
            if ct ~= partner and ct.chain == chain and ct.isConnected then
                farEnd = ct
                break
            end
        end
    elseif coupling.isChainTerminus and coupling.chain ~= nil then
        -- Coupling itself is a terminus — partner is the external coupler.
        -- Walk the chain from the other end.
        local chain = coupling.chain
        for _, ct in ipairs(self.chainTerminusEntries) do
            if ct ~= coupling and ct.chain == chain and ct.isConnected then
                -- ct is the far terminus — its partner is the external coupler at the other end
                if ct.connectedPartnerCoupling ~= nil then
                    farEnd = ct.connectedPartnerCoupling
                end
                break
            end
        end
    end

    if farEnd == nil then
        print("[SPS valve] _propagateValveState: farEnd is nil, abort")
        return
    end
    if farEnd.valveOpen == open then
        print("[SPS valve] _propagateValveState: farEnd already in target state, abort")
        return
    end

    print(string.format("[SPS valve] _propagateValveState: forwarding to farEnd.id=%s", tostring(farEnd.id)))
    self:applyValveState(nil, farEnd.id, open, farEnd)
    local farVehicle, _ = self:_findCouplingOwner(farEnd)
    SlurryValveStateEvent.sendEvent(farVehicle, farEnd, open)
end

-- Force-disconnect regardless of valve state — used when vehicle is unregistered
-- or auto-disconnected by distance. Closes valve first then disconnects.
function SlurryPipeManager:_forceDisconnect(vehicle, coupling)
    if not coupling.isConnected then return end
    -- Close valve first so applyDisconnect doesn't refuse
    if coupling.valveOpen then
        coupling.valveOpen = false
        if coupling.connectedPartnerCoupling ~= nil then
            coupling.connectedPartnerCoupling.valveOpen = false
        end
    end
    self:applyDisconnect(vehicle, coupling.id, coupling)
    SlurryPipeDisconnectEvent.sendEvent(vehicle, coupling.id)
end

function SlurryPipeManager:applyConnect(vehicleA, targetObject, targetType, couplingIdA, couplingIdB)
    -- Find couplingA — vehicle may be nil if the initiator was a placeable
    local couplingA
    if vehicleA ~= nil then
        couplingA = self:_findCouplingById(vehicleA, couplingIdA, false)
        if couplingA == nil then
            -- vehicleA might actually be a placeable passed as the owner
            couplingA = self:_findCouplingById(vehicleA, couplingIdA, true)
        end
    end
    if couplingA == nil then
        -- Fallback: search all placeable store couplings by id
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.storeCouplings ~= nil then
                for _, sc in ipairs(pEntry.storeCouplings) do
                    if sc.id == couplingIdA and not sc.isConnected then
                        couplingA = sc
                        break
                    end
                end
            end
            if couplingA ~= nil then break end
        end
    end

    local couplingB
    if targetType == SlurryPipeConnectEvent.TARGET_TYPE_VEHICLE then
        couplingB = self:_findCouplingById(targetObject, couplingIdB, false)
    else
        couplingB = self:_findCouplingById(targetObject, couplingIdB, true)
    end

    if couplingA == nil or couplingB == nil then
        print("[SPS] applyConnect: coupling not found A=" .. tostring(couplingIdA) .. " B=" .. tostring(couplingIdB))
        return
    end

    local ownerA = vehicleA or (couplingA.placeable)
    local ownerB = targetObject
    self:applyConnectCouplings(couplingA, couplingB, ownerA, ownerB)
end

function SlurryPipeManager:applyValveState(vehicle, couplingId, isOpen, couplingObj)
    -- Object-first: when caller has the coupling table, use it directly to avoid
    -- id ambiguity across multiple placeables that share coupling ids.
    local coupling = couplingObj
    local foundIn = "objectArg"
    if coupling == nil then
        coupling = self:_findCouplingById(vehicle, couplingId, false)
        foundIn = "vehicle"
    end
    if coupling == nil then
        -- Try placeable
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.storeCouplings ~= nil then
                for _, sc in ipairs(pEntry.storeCouplings) do
                    if sc.id == couplingId then coupling = sc break end
                end
            end
            if coupling ~= nil then foundIn = "placeable" break end
        end
    end
    -- Try chain terminus entries (chain start couplings have id=-2, segment chain
    -- couplings use segment-index ids — neither lives in vehicle/placeable lists)
    if coupling == nil then
        for _, ct in ipairs(self.chainTerminusEntries) do
            if ct.id == couplingId then coupling = ct foundIn = "chainTerminus" break end
        end
    end
    if coupling == nil then
        print(string.format("[SPS valve] applyValveState: coupling.id=%s NOT FOUND", tostring(couplingId)))
        return
    end

    print(string.format("[SPS valve] applyValveState: id=%s found in %s, isOpen=%s, partner.id=%s",
        tostring(coupling.id), foundIn, tostring(isOpen),
        tostring(coupling.connectedPartnerCoupling and coupling.connectedPartnerCoupling.id or nil)))

    coupling.valveOpen = isOpen

    -- Also sync the partner coupling valve so both ends agree
    local partner = coupling.connectedPartnerCoupling
    -- Special case: chain start couplings are linked to the placeable anchor via
    -- the chain object, not via connectedPartnerCoupling. Use the chain anchor as
    -- the effective partner so the placeable's valve handle animation fires.
    if partner == nil and coupling.isChainStart and coupling.chain ~= nil then
        partner = coupling.chain.anchorCoupling
    end
    if partner ~= nil then
        partner.valveOpen = isOpen
    end

    -- If closing, stop any active flow on both sides
    if not isOpen then
        if vehicle ~= nil then self:stopFlow(vehicle) end
        if partner ~= nil then
            local partnerVehicle, _ = self:_findCouplingOwner(partner)
            if partnerVehicle ~= nil then self:stopFlow(partnerVehicle) end
        end
    end

    -- Play valve animations (no-op if not bound).
    if SPSCouplerAnimator ~= nil then
        local dir = isOpen and 1 or -1
        if coupling.valveAnim ~= nil then
            print(string.format("[SPS valve] applyValveState: playing valveAnim on coupling.id=%s", tostring(couplingId)))
            SPSCouplerAnimator.play(coupling.valveAnim, dir)
        end
        if partner ~= nil and partner.valveAnim ~= nil then
            print(string.format("[SPS valve] applyValveState: playing valveAnim on partner.id=%s", tostring(partner.id)))
            SPSCouplerAnimator.play(partner.valveAnim, dir)
        end
    end

end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Pressure engine (server-authoritative)
-- Pressure is a STORED signed value (-maxPressure .. +maxPressure). It changes
-- only by priority each tick:
--   1. PURGE — direction flipped against stored pressure -> 0 at purgeRate
--   2. BUILD — PTO on -> toward ±max at buildRate (build wins over drain, so the
--              PTO holds pressure at max while fluid flows)
--   3. DRAIN — PTO off + any valve open -> toward 0; slow (fallTimeWorking) while
--              fluid is present/transferring, fast (fallTimeEmpty) when venting
--   4. HOLD  — PTO off + valves closed -> unchanged (pressure is stored)
-- Build time scales with poo fill ratio: full = minBuildTime, empty = maxBuildTime.
-- Open-top passive vessels (FRC) and fert/herb sprayers are skipped entirely.
--
-- Flow rate (Phase 3) scales with |pressure| / maxPressure.
-- ---------------------------------------------------------------------------

-- Moves 'current' toward 'target' by at most 'step' (signed bar values).
function SlurryPipeManager:_movePressureToward(current, target, step)
    if step <= 0 then return current end
    if current < target then
        return math.min(target, current + step)
    elseif current > target then
        return math.max(target, current - step)
    end
    return current
end

-- Returns the tank fill ratio (0..1) and absolute fill level for the vehicle's
-- primary fill unit (first arm, else first coupling, else unit 1).
function SlurryPipeManager:getPressureFillRatio(vehicle, vEntry)
    if vehicle == nil or vehicle.getFillUnitFillLevel == nil then
        return 0, nil
    end
    local fillUnitIndex = 1
    if vEntry ~= nil then
        if vEntry.armEntries ~= nil and #vEntry.armEntries > 0 then
            fillUnitIndex = vEntry.armEntries[1].fillUnitIndex
        elseif vEntry.couplingEntries ~= nil and #vEntry.couplingEntries > 0 then
            fillUnitIndex = vEntry.couplingEntries[1].fillUnitIndex
        end
    end
    local level = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
    local cap   = vehicle.getFillUnitCapacity ~= nil and (vehicle:getFillUnitCapacity(fillUnitIndex) or 0) or 0
    if cap <= 0 then
        return 0, level
    end
    return math.min(1, math.max(0, level / cap)), level
end

-- True if any flow path is open on this vehicle: the fill-arm cab valve, the
-- spreader valve, or any connected coupling's manual valve. An open valve means
-- pressure is being spent (priority 3) unless the PTO is replenishing it.
function SlurryPipeManager:isAnyValveOpen(vEntry, state)
    if state.valveOpen or state.spreaderValveOpen then return true end
    if vEntry.couplingEntries ~= nil then
        for _, c in ipairs(vEntry.couplingEntries) do
            if c.isConnected and c.valveOpen then return true end
        end
    end
    return false
end

function SlurryPipeManager:updatePressure(dt)
    local dtSec = dt * 0.001

    -- Shear bolt for non-vacuum slurry pumps (HVP / conduit). The vacuum path runs
    -- inside the pressure block below (usesPressureModel == true), so this loop only
    -- covers slurry vehicles that do NOT use the pressure model, to avoid double
    -- processing. Per-vehicle opt-in via <shearBolt bolt="true"/>; fert/herb sprayers
    -- are excluded here (sprayer-side shear bolts are handled separately). Vehicles
    -- with no spec_drivable (e.g. a stationary conduit station) simply accrue no wear
    -- inside SPSShearBolt.update, so this is a safe no-op for them.
    if SPSShearBolt ~= nil then
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.shearBolt == true then
                local v = vEntry.vehicle
                local isFert = v ~= nil and v.spec_sprayer ~= nil
                    and v.spec_sprayer.isFertilizerSprayer == true
                -- [SPS AI GATE] no shear wear while AI drives
                if not isFert and not self:usesPressureModel(vEntry)
                   and not self:isAIControlled(v) then
                    SPSShearBolt.update(self, vEntry, dt)
                end
            end
        end
    end

    for _, vEntry in ipairs(self.registeredVehicles) do
        local vehicle = vEntry.vehicle
        local state   = vEntry.state
        local cfg     = vEntry.pressure
        -- [SPS AI GATE] AI in control: hold pressure exactly where it is and
        -- accrue no shear wear — the overrides pass everything through to
        -- vanilla, so nothing reads pressure while AI drives. Resumes from the
        -- held value when the player takes back over.
        if vehicle ~= nil and self:isAIControlled(vehicle) then
            continue
        end
        -- Pressure is slurry/water only. A vehicle carrying the sprayer spec may
        -- be a slurry spreader (poo — pressure applies) OR a fert/herb sprayer
        -- (must be shielded). Vanilla Sprayer classifies this at load:
        -- isFertilizerSprayer = not slurry/digestate and not manure. Shield those.
        if vehicle ~= nil and vehicle.spec_sprayer ~= nil
        and vehicle.spec_sprayer.isFertilizerSprayer == true then
            vehicle = nil
        end
        -- Open-top passive vessels (FRC), HVP and conduit pumps, and fert/herb
        -- sprayers do not run the stored-pressure model. They are still valid flow
        -- sources/sinks, just never pressurised. usesPressureModel is the single
        -- chokepoint for that decision (it already shields fert/herb above, but the
        -- guard there stays for clarity).
        if vehicle ~= nil and not self:usesPressureModel(vEntry) then
            if state ~= nil then state.pressure = 0; state.purging = false end
            vehicle = nil
        end
        if vehicle ~= nil and state ~= nil and cfg ~= nil then
            local maxP = cfg.maxPressure
            if maxP <= 0 then maxP = SlurryPipeManager.DEFAULT_MAX_PRESSURE end

            local fillRatio, fillLevel = self:getPressureFillRatio(vehicle, vEntry)

            -- Build time scales with poo fill ratio: full = minBuildTime (fast),
            -- empty = maxBuildTime (slow). Symmetric for vacuum and pressure.
            local buildTime = cfg.maxBuildTime - fillRatio * (cfg.maxBuildTime - cfg.minBuildTime)
            if buildTime <= 0 then buildTime = cfg.minBuildTime end
            if buildTime <= 0 then buildTime = SlurryPipeManager.DEFAULT_MIN_BUILD_TIME end

            local buildRate   = maxP / buildTime                                                    -- bar/sec
            local purgeRate   = (cfg.purgeTime       > 0) and (maxP / cfg.purgeTime)       or maxP   -- bar/sec
            local fallWorking = (cfg.fallTimeWorking > 0) and (maxP / cfg.fallTimeWorking) or maxP   -- bar/sec (slow)
            local fallEmpty   = (cfg.fallTimeEmpty   > 0) and (maxP / cfg.fallTimeEmpty)   or maxP   -- bar/sec (fast)

            local p           = state.pressure or 0
            local valveOpen   = self:isAnyValveOpen(vEntry, state)
            local hasContent  = (fillLevel ~= nil and fillLevel > 0)

            -- An empty tank carries no slurry, so it carries no thickness or crust.
            if not hasContent then
                if (state.thickness or 0) > 0 then state.thickness = 0 end
                if (state.crust or 0) > 0 then state.crust = 0 end
            end

            -- Stored-pressure model, evaluated by priority each tick:
            --   1. PURGE  — direction flipped against stored pressure -> 0 (fast, purgeRate)
            --   2. BUILD  — PTO on -> toward ±max at buildRate (overrides drain: PTO holds at max while flowing)
            --   3. DRAIN  — PTO off + a valve open -> toward 0
            --                working (fluid present) = slow; venting (empty) = fast
            --   4. HOLD   — PTO off + valves closed -> unchanged (pressure is stored)
            if state.purging then
                p = self:_movePressureToward(p, 0, purgeRate * dtSec)
                if p == 0 then state.purging = false end
            elseif state.pumpRunning and not state.shearSnapped then
                -- Shear bolt intact: PTO drives the pump, build/hold pressure.
                -- If the bolt has snapped the pump is disconnected, so we fall
                -- through to DRAIN (valve open) / HOLD even with the PTO on.
                local target = (state.direction == SPS_DIRECTION_DISCHARGE) and maxP or -maxP
                p = self:_movePressureToward(p, target, buildRate * dtSec)
            elseif valveOpen then
                local rate = hasContent and fallWorking or fallEmpty
                p = self:_movePressureToward(p, 0, rate * dtSec)
            end
            -- else: HOLD — no change.

            state.pressure = p

            -- Shear bolt: accrue wear from hard turning under PTO load, snap when
            -- worn out, and keep the snapped shaft frozen (vac tanks only — this
            -- block is gated by usesPressureModel above). Per-vehicle opt-in via
            -- <shearBolt bolt="true"/>. Non-vacuum slurry pumps (HVP/conduit) are
            -- handled by the dedicated loop at the top of updatePressure.
            if SPSShearBolt ~= nil and vEntry.shearBolt == true then
                SPSShearBolt.update(self, vEntry, dt)
            end
            if math.abs((state._lastLoggedPressure or 999) - p) >= 0.1 then
                state._lastLoggedPressure = p
                --SlurryDebug.log(string.format("[SPS PRESSURE] %s p=%.2f dir=%s pump=%s purge=%s valve=%s content=%s ratio=%.2f",
                --    tostring(vehicle.configFileName), p,
                --    tostring(state.direction), tostring(state.pumpRunning),
                --    tostring(state.purging), tostring(valveOpen),
                --    tostring(hasContent), fillRatio))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Shear bolt: state query, repair gate, repair, and MP apply
-- ---------------------------------------------------------------------------
function SlurryPipeManager:isShearBoltSnapped(vehicle)
    local state = self:getVehicleState(vehicle)
    return state ~= nil and state.shearSnapped == true
end

-- Repair is allowed only with the tractor PTO off AND the engine stopped.
function SlurryPipeManager:canRepairShearBolt(vehicle)
    if not self:isShearBoltSnapped(vehicle) then return false end
    -- PTO off (the tanker is not turned on).
    if vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() then return false end
    local state = self:getVehicleState(vehicle)
    if state ~= nil and state.pumpRunning == true then return false end
    -- Engine stopped.
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if root ~= nil and root.getIsMotorStarted ~= nil and root:getIsMotorStarted() then
        return false
    end
    return true
end

function SlurryPipeManager:repairShearBolt(vehicle)
    if SPSShearBolt == nil then return end
    if not self:canRepairShearBolt(vehicle) then return end
    SPSShearBolt.repair(self, vehicle)
end

-- Called by SPSShearBoltEvent on receiving peers (and directly on the trigger peer).
function SlurryPipeManager:applyShearBoltState(vehicle, snapped)
    if SPSShearBolt == nil then return end
    SPSShearBolt.applyState(self, vehicle, snapped)
end

function SlurryPipeManager:update(dt)
	self._updateCount = (self._updateCount or 0) + 1
--    if self._updateCount == 1 then print("[SPS] update() is running") end
	-- [SPS AI GATE] player<->AI transition detection must run before anything
	-- else this tick so suspend/resume happens ahead of pressure/flow/blockage.
	self:updateAIGate(dt)
	self:updateSpreaderAnimations(dt)
	self:updatePumpSounds(dt)
	
    -- Tick coupler animations (connector + valve, vehicles + placeables).
    -- Each instance is a no-op when not playing.
    if SPSCouplerAnimator ~= nil then
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.couplingEntries ~= nil then
                for _, c in ipairs(vEntry.couplingEntries) do
                    if c.connectorAnim ~= nil then SPSCouplerAnimator.update(c.connectorAnim, dt) end
                    if c.valveAnim     ~= nil then SPSCouplerAnimator.update(c.valveAnim,     dt) end
                end
            end
        end
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.storeCouplings ~= nil then
                for _, c in ipairs(pEntry.storeCouplings) do
                    if c.connectorAnim ~= nil then SPSCouplerAnimator.update(c.connectorAnim, dt) end
                    if c.valveAnim     ~= nil then SPSCouplerAnimator.update(c.valveAnim,     dt) end
                end
            end
        end
        -- Sprayer coupler animations (connector + valve)
        for _, sEntry in ipairs(self.registeredSprayerVehicles) do
            if sEntry.couplings ~= nil then
                for _, c in ipairs(sEntry.couplings) do
                    if c.connectorAnim ~= nil then SPSCouplerAnimator.update(c.connectorAnim, dt) end
                    if c.valveAnim     ~= nil then SPSCouplerAnimator.update(c.valveAnim,     dt) end
                end
            end
        end
        for _, sEntry in ipairs(self.registeredSprayerPlaceables) do
            if sEntry.couplings ~= nil then
                for _, c in ipairs(sEntry.couplings) do
                    if c.connectorAnim ~= nil then SPSCouplerAnimator.update(c.connectorAnim, dt) end
                    if c.valveAnim     ~= nil then SPSCouplerAnimator.update(c.valveAnim,     dt) end
                end
            end
        end
    end
    
    -- Conduit HUD: addInfoExtension must be called every frame.
    -- g_currentMission.controlledVehicle is always nil in FS25 — use
    -- getIsActiveForInput to detect when the player is in the pump's cab.
    if g_currentMission ~= nil then
        for _, entry in ipairs(self.registeredVehicles) do
            if entry.conduit and entry.hudExtension ~= nil and entry.vehicle.isClient then
                if entry.vehicle:getIsActiveForInput(false) then
                    g_currentMission.hud:addInfoExtension(entry.hudExtension)
                end
            end
        end
    end
 
    -- Pressure engine: stored-pressure build/drain/purge per registered pump vehicle.
    -- Server-authoritative. Stored-pressure model — flow scaling, spreader
    -- gates and HUD consume state.pressure from Phase 3 onward.
    if g_server ~= nil then
        self:updatePressure(dt)
    end
    self:updateBlockages(dt)

    -- Reconcile each store's dry-matter pool against its actual total every tick. Slurry
    -- added or removed outside the SPS pipe system (vanilla loading station, AI, map
    -- presets, console) carries no dry matter on its own, so a rise is treated as fresh
    -- slurry (DM_FRESH) and a fall as a proportional draw. SPS transfers keep _lastTotal
    -- in step themselves, so they are never double-counted here.
    if g_server ~= nil and self:isFeatureEnabled() then
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.agitatorEnabled and pEntry.sourceEntry ~= nil
            and pEntry.sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                self:_reconcileStorePools(pEntry.sourceEntry)
            end
        end
    end

    -- Crust growth: an unmixed store crusts continuously. Each in-game day it gains a
    -- slice sized so a full year (12 periods) takes it 0 -> 100%, independent of the
    -- player's daysPerPeriod setting. Mixing (applyAgitation) drives it back down; the
    -- moment mixing stops it starts climbing again. Only while the store holds slurry.
    if g_server ~= nil and self:isFeatureEnabled() and g_currentMission ~= nil and g_currentMission.environment ~= nil then
        local env     = g_currentMission.environment
        local today   = env.currentMonotonicDay
        local dpp     = env.daysPerPeriod or 1
        if self._lastMonotonicDay == nil then
            self._lastMonotonicDay = today
        elseif today ~= self._lastMonotonicDay then
            local daysElapsed = math.max(1, today - self._lastMonotonicDay)
            self._lastMonotonicDay = today
            -- 12 periods per game year; SETTLE_YEARS_TO_FULL years to crust over.
            local daysToFull = 12 * dpp * SlurryPipeManager.SETTLE_YEARS_TO_FULL
            local perDay     = (daysToFull > 0) and (1.0 / daysToFull) or 0
            local gain       = perDay * daysElapsed
            for _, pEntry in ipairs(self.registeredPlaceables) do
                if pEntry.agitatorEnabled and pEntry.sourceEntry ~= nil and pEntry.sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                    local se = pEntry.sourceEntry
                    self:_ensureStorePools(se)
                    if self:_getStoreTotalFill(se) > 0 then
                        se.settle = math.min(1.0, (se.settle or 0) + gain)
                        if SPSCrustVegetation ~= nil then
                            SPSCrustVegetation.updateVisibility(pEntry)
                        end
                    end
                end
            end
        end
    end

    -- Manager-driven agitator: runs for any registered vehicle with an agitatorTipNode.
    -- No specialization required — works for any vehicle type including ModHub mods.
    if g_server ~= nil and self:isFeatureEnabled() then
        local env       = g_currentMission ~= nil and g_currentMission.environment or nil
        local timeScale = env ~= nil and env.timeAdjustment or 1
        local dtHours   = (dt * 0.001) * timeScale / 3600
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.agitatorTipNode ~= nil and entityExists(vEntry.agitatorTipNode) then
                local tipNode = vEntry.agitatorTipNode
                local ptoOk   = SlurryPipeSystemOverride.isPTOConnected(vEntry.vehicle)
                local motorOk = false
                local root    = vEntry.vehicle:getRootVehicle()
                if root ~= nil and root.getIsMotorStarted ~= nil then
                    motorOk = root:getIsMotorStarted()
                end
                local wasActive = vEntry.agitatorIsActive
                if ptoOk and motorOk then
                    -- Find matching sourceEntry by bounds and surface Y
                    local tx, ty, tz   = getWorldTranslation(tipNode)
                    local foundEntry   = nil
                    for _, pEntry in ipairs(self.registeredPlaceables) do
                        local se = pEntry.sourceEntry
                        if se ~= nil and se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE
                        and se.planeBounds ~= nil then
                            if SlurryNodeUtil.isNodeInPlaneBounds(tipNode, se.planeBounds) then
                                local surfY = SlurryNodeUtil.getSurfaceWorldY(se, tx, tz)
                                if surfY ~= -math.huge and ty <= surfY then
                                    foundEntry = se
                                    break
                                end
                            end
                        end
                    end
                    vEntry.agitatorIsActive = foundEntry ~= nil
                    if foundEntry ~= nil then
                        self:applyAgitation(foundEntry, dtHours)
                    end
                else
                    vEntry.agitatorIsActive = false
                end
                -- Sync state change to clients
                if vEntry.agitatorIsActive ~= wasActive then
                    SlurryAgitatorEvent.sendEvent(vEntry.vehicle, vEntry.agitatorIsActive)
                end
            end
        end
    end

    -- Vehicle positions are not finalised at onFinishedLoading time so the coupling
    -- position check in tryResolvePendingConnections can fail at registration. By
    -- retrying each tick until vehicles have settled, we catch late-registering vehicles.
    if self._updateCount <= 300 then
        if #self.pendingConnections > 0 or #self.pendingChains > 0 or #self.pendingDeployedCouplings > 0 then
            self:tryResolvePendingConnections()
        end
    end
 
    -- Motor/PTO guard: stop pump if tractor engine off or PTO disconnected.
    -- Runs server-side only. Only checks PTO-driven spreader vehicles because:
    --   - selfPowered vehicles have their own power source (no tractor needed)
    --   - non-spreader vehicles are already gated by setIsTurnedOn/getCanBeTurnedOn
    --   - spreader vehicles use state.pumpRunning directly and need explicit cleanup
    if g_server ~= nil then
        for _, entry in ipairs(self.registeredVehicles) do
            local vehicle = entry.vehicle
            local state   = entry.state
            if state.pumpRunning and not self:isVehicleSelfPowered(vehicle) and self:vehicleHasSpreader(vehicle) then
                local root    = vehicle:getRootVehicle()
                local motorOk = root ~= nil and root.getIsMotorStarted ~= nil and root:getIsMotorStarted()
                local ptoOk   = SlurryPipeSystemOverride.isPTOConnected(vehicle)
                if not motorOk or not ptoOk then
                    print("[SPS PUMP] update: stopping pump — motorOk=" .. tostring(motorOk) .. " ptoOk=" .. tostring(ptoOk) .. " vehicle=" .. tostring(vehicle.configFileName))
                    state.pumpRunning = false
                    -- Spreader valve intentionally left OPEN. Stored pressure must
                    -- keep pushing slurry out (tapering) until it drains below
                    -- minThreshold. updatePressure priority 3 (valve open + PTO off)
                    -- handles the drain; force-closing here would freeze pressure
                    -- (priority 4 HOLD) and stop discharge instantly.
                    if state.valveOpen then
                        state.valveOpen = false
                    end
                    vehicle:setIsTurnedOn(false)
                    SPSSelfPumpStateEvent.sendEvent(vehicle, false)
                    self:updateActionEventTexts(vehicle)
                end
            end
        end
    end

    -- Spreader turn-state driver (server-authoritative).
    -- The spraying component must be turned on whenever discharge SHOULD be flowing,
    -- which is decided purely by SPS state (shouldSpreaderBeOn): pump running, OR a
    -- spreader valve open with stored pressure at/above minThreshold. This is what
    -- makes the "build pressure -> pump off -> open valve" sequence start spreading,
    -- and what tapers/stops it cleanly when pressure drains or the valve closes.
    -- It replaces the old fold-based bar sync (getIsLowered was unreliable on some
    -- bars, so a bar only ever came on via a pump press) and the separate taper-off.
    --   - Built-in self-spreaders (RossMore, Joskin): the tanker's OWN sprayer work
    --     area is gated by TurnOnVehicle on getIsTurnedOn(), so drive the tanker.
    --   - Attached-implement spreaders (Samson, Oxbo): drive each attached bar (its
    --     work area needs the bar turned on); the tanker fill unit is kept live via
    --     getIsFillUnitActive. The tanker is also driven for PTO sounds/animations.
    -- setIsTurnedOn is a no-op when already in the requested state, so SetTurnedOnEvent
    -- only fires on a real change.
    if g_server ~= nil then
        for _, entry in ipairs(self.registeredVehicles) do
            local vehicle = entry.vehicle
            -- Skip spreader implements (dribble bars registered for blockage nodes):
            -- they have spec_dischargeable so vehicleHasSpreader is true, but they are
            -- NOT their own controller. Driving them here would compute wantOn from their
            -- empty self-state (false) and fight the real tanker's pass that wants them on
            -- (the cause of the DB icon never going green). The tanker's pass below drives
            -- them via findAttachedDribbleBars.
            if not self:isSpreaderImplement(vehicle) and self:vehicleHasSpreader(vehicle)
               and not self:isAIControlled(vehicle) then
                local wantOn = self:shouldSpreaderBeOn(vehicle)
                if vehicle.getIsTurnedOn ~= nil and vehicle.setIsTurnedOn ~= nil
                   and wantOn ~= vehicle:getIsTurnedOn() then
                    vehicle:setIsTurnedOn(wantOn)
                end
                for _, bar in ipairs(self:findAttachedDribbleBars(vehicle)) do
                    if bar.getIsTurnedOn ~= nil and bar.setIsTurnedOn ~= nil
                       and wantOn ~= bar:getIsTurnedOn() then
                        bar:setIsTurnedOn(wantOn)
                    end
                end
            end
        end
    end

    -- [SPS AI GATE] Deterministic AI spreader turn-on (vanilla / Courseplay).
    -- Some vehicle configs never turn their spreader on through vanilla's AI
    -- controlledAction path (no activateOnLowering, folded at start, action
    -- registered late) — the Joskin Cobra is one: every gate reads "allowed" yet
    -- isTurnedOn stays false. So under AI we drive the turn state directly from
    -- the canonical line signal: getIsAIImplementInLine() (spec_aiImplement.
    -- isLineStarted, set by AIImplement.aiImplementStartLine/EndLine) is true ONLY
    -- while the worker is actually working a field line and false on headland
    -- turns and transport. Matching the turn state to it is exactly what vanilla
    -- intends — and because the vehicles vanilla already turns on correctly derive
    -- from the same isLineStarted, this agrees with them and is a no-op there
    -- (setIsTurnedOn fires no SetTurnedOnEvent when the state is unchanged), so it
    -- never fights the already-working Farmtech/Kaweco. It simply fills the gap for
    -- the configs vanilla leaves off. AutoDrive (pure route driving, never starts a
    -- field line) keeps isLineStarted false, so the spreader stays off under AD —
    -- correct, since AD is transport, not field spreading.
    if g_server ~= nil then
        for _, entry in ipairs(self.registeredVehicles) do
            local vehicle = entry.vehicle
            if vehicle ~= nil
               and not self:isSpreaderImplement(vehicle)
               and self:vehicleHasSpreader(vehicle)
               and self:isAIControlled(vehicle)
               and not self:isShearBoltSnapped(vehicle) then
                local bars = self:findAttachedDribbleBars(vehicle)
                -- On line if the tanker itself OR any attached dribble bar (the
                -- actual AI implement on a Kaweco/Bomech-style rig) is in line.
                local inLine = false
                if vehicle.getIsAIImplementInLine ~= nil and vehicle:getIsAIImplementInLine() then
                    inLine = true
                end
                if not inLine then
                    for _, bar in ipairs(bars) do
                        if bar.getIsAIImplementInLine ~= nil and bar:getIsAIImplementInLine() then
                            inLine = true
                            break
                        end
                    end
                end
                if vehicle.getIsTurnedOn ~= nil and vehicle.setIsTurnedOn ~= nil
                   and inLine ~= vehicle:getIsTurnedOn() then
                    vehicle:setIsTurnedOn(inLine)
                    print("[SPS AI GATE] AI spreader turn " .. (inLine and "ON" or "OFF")
                        .. " (in-line driver) for " .. tostring(vehicle.configFileName))
                end
                for _, bar in ipairs(bars) do
                    if bar.getIsTurnedOn ~= nil and bar.setIsTurnedOn ~= nil
                       and inLine ~= bar:getIsTurnedOn() then
                        bar:setIsTurnedOn(inLine)
                    end
                end
            end
        end
    end
 
    -- Update all pipe chains (live segment tracking + docking station bezier)
    for _, chain in ipairs(self.pipeChains) do
        chain:update(dt)
    end
 
    -- Pipe anim node: driven by isDeployed state on deployable couplings.
    -- Only override when deployed — when not deployed let Giants animation control the node.
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.pipeAnimNode ~= nil and pEntry.pipeAnimNode ~= 0 then
            local deployed = false
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc.deployable and sc.isDeployed then
                    deployed = true
                    break
                end
            end
            if deployed then
                setRotation(pEntry.pipeAnimNode, pEntry.pipeAnimRX, pEntry.pipeAnimRY, pEntry.pipeAnimRZ)
            end
        end
    end
 
    -- ----------------------------------------------------------------------
    -- [SPS #2] Precision Farming spray-effect continuity during the taper.
    -- Runs on ALL peers (spray effects are client-side), so it sits BEFORE the
    -- server-only gate below. PF only drives its spray effect while
    -- getIsTurnedOn() is true (its onUpdateTick gate + internal re-check in
    -- ExtendedSprayer:updateSprayerEffectState), so during the stored-pressure
    -- taper (PTO off, turnOn off) PF drops the visuals even though slurry is
    -- still being applied. We drive that rear discharge effect ourselves via
    -- _driveSprayerEffect (the same g_effectManager/g_soundManager/g_animationManager
    -- operations PF uses, taken off self.spec_sprayer) while the taper is active, and
    -- stop it when the valve closes or pressure falls below min. The real turnOn (green
    -- icon / PTO / sound) is left untouched. Guarded per-implement on PF being present
    -- (getIsPrecisionSprayingRequired registered) and on having a sprayer; a pure no-op
    -- without Precision Farming.
    -- ----------------------------------------------------------------------
    do
        for _, vEntry in ipairs(self.registeredVehicles) do
            local vehicle = vEntry.vehicle
            local state   = vEntry.state
            if vehicle ~= nil and state ~= nil
               and not self:isSpreaderImplement(vehicle)
               and self:vehicleHasSpreader(vehicle)
               and not self:isShearBoltSnapped(vehicle)   -- leave snap/repair scenario untouched
               and not self:isAIControlled(vehicle) then  -- [SPS AI GATE] AI owns the effect (vanilla)

                local discharging = self:isSpreaderDischargeActive(vehicle)

                -- Spreader implement(s): the tanker itself (built-in plate) plus any
                -- attached dribble bars.
                local candidates = { vehicle }
                for _, bar in ipairs(self:findAttachedDribbleBars(vehicle)) do
                    candidates[#candidates + 1] = bar
                end

                for _, sv in ipairs(candidates) do
                    if sv ~= nil and sv.getIsPrecisionSprayingRequired ~= nil then  -- PF present on this implement
                        local realOn = (sv.getIsTurnedOn ~= nil) and sv:getIsTurnedOn()
                        if not realOn then
                            -- Desired effect state during the taper: on while discharging AND
                            -- PF itself would show it (precision required + effects visible).
                            -- We evaluate PF's non-turnOn gates directly; turnOn is the only
                            -- thing we override.
                            local wantOn = (state.spreaderValveOpen == true) and discharging
                            if wantOn and sv.getIsPrecisionSprayingRequired ~= nil then
                                wantOn = sv:getIsPrecisionSprayingRequired()
                            end
                            if wantOn and sv.getAreEffectsVisible ~= nil then
                                wantOn = sv:getAreEffectsVisible()
                            end

                            if wantOn and sv._spsPfEffectOn ~= true then
                                -- START the rear discharge effect directly (PF's latch would
                                -- otherwise block a re-assert through PF's own function).
                                self:_driveSprayerEffect(sv, true)
                                sv._spsPfEffectOn = true
                            elseif (not wantOn) and sv._spsPfEffectOn == true then
                                -- STOP cleanly when discharging ends or the valve closes.
                                self:_driveSprayerEffect(sv, false)
                                sv._spsPfEffectOn = false
                            end
                        elseif sv._spsPfEffectOn == true then
                            -- Real turnOn returned (pump re-engaged): PF owns the effect again
                            -- (its onTurnedOn already forced an update). Just clear our flag.
                            sv._spsPfEffectOn = false
                        end
                    end
                end
            end
        end
    end

    if g_server == nil then return end
 
    -- Drive placeable inlet effects per-coupling — only fires for couplings that have effects declared
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
            if sc.pipeEffects ~= nil then
                local shouldPlay = false
                if sc.isConnected and sc.connectedPartnerCoupling ~= nil then
                    local partner = sc.connectedPartnerCoupling
                    -- Resolve real vehicle: direct owner, or via chain terminus anchor
                    local vehicle, _ = self:_findCouplingOwner(partner)
                    local resolvedCoupling = partner
                    if vehicle == nil and partner.isChainTerminus and partner.chain ~= nil then
                        vehicle, _ = self:_findCouplingOwner(partner.chain.anchorCoupling)
                        resolvedCoupling = partner.chain.anchorCoupling
                    end
                    if vehicle ~= nil then
                        local vState = self:getVehicleState(vehicle)
                        local pumpOn
                        if self:isVehicleSelfPowered(vehicle) then
                            pumpOn = vState ~= nil and vState.pumpRunning == true
                        else
                            pumpOn = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() or false
                        end
                        if self:isVehicleConduit(vehicle) then
                            local cabOpen = vState ~= nil and vState.valveOpen
                            local conduitActive = self.activeFlows[vehicle] ~= nil
                            local pumpOn
                            if self:isVehicleSelfPowered(vehicle) then
                                pumpOn = vState ~= nil and vState.pumpRunning == true
                            else
                                pumpOn = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() or false
                            end
                            local isDestination = false
                            local dir = vState and vState.direction or SPS_DIRECTION_FILL
                            for _, vEntry in ipairs(self.registeredVehicles) do
                                if vEntry.vehicle == vehicle then
                                    for _, c in ipairs(vEntry.couplingEntries) do
                                        if c == resolvedCoupling then
                                            if (c.id == 2 and dir == SPS_DIRECTION_DISCHARGE) or
                                               (c.id == 1 and dir == SPS_DIRECTION_FILL) then
                                                isDestination = true
                                            end
                                            break
                                        end
                                    end
                                    break
                                end
                            end
							print("[SPS PIPE EFFECT TEST] path=conduit resolvedCoupling=" .. tostring(resolvedCoupling ~= nil))
                            shouldPlay = conduitActive and cabOpen and pumpOn and isDestination
                        elseif sc.valveOpen then
							local isDischarge = vState ~= nil and vState.direction == SPS_DIRECTION_DISCHARGE
							local dirOk
							if sc.flowDirection == "DISCHARGE" then dirOk = isDischarge
							elseif sc.flowDirection == "FILL" then dirOk = not isDischarge
							else dirOk = true end
						
							local tankerHasSlurry = false
						
							if vehicle ~= nil and resolvedCoupling ~= nil and vehicle.getFillUnitFillLevel ~= nil then
								local fillUnitIndex = resolvedCoupling.fillUnitIndex
								if fillUnitIndex ~= nil then
									tankerHasSlurry = vehicle:getFillUnitFillLevel(fillUnitIndex) > 0
								end
							end
							print("[SPS PIPE EFFECT TEST] path=direct scValveOpen=" .. tostring(sc.valveOpen))
							shouldPlay = (self:getPressureFlowScalar(vehicle) > 0) and dirOk and tankerHasSlurry
						end
                    end
                end
                -- Chain anchor path: this store coupling is a chain anchor (sc.isConnected=false).
                -- Walk all chain terminus entries to find one whose chain is anchored at this store.
                -- That terminus connects to whatever is on the other side (tanker or pump coupling).
                if not shouldPlay then
                    for _, ct in ipairs(self.chainTerminusEntries) do
                        if ct.chain ~= nil and ct.chain.anchorCoupling == sc then
                            -- This chain is anchored at this store coupling.
                            if ct.isConnected and ct.connectedPartnerCoupling ~= nil then
                                local partner = ct.connectedPartnerCoupling
                                -- Resolve real vehicle — partner may itself be a chain terminus
                                local vehicle2, _ = self:_findCouplingOwner(partner)
                                local resolvedC = partner
                                if vehicle2 == nil and partner.isChainTerminus and partner.chain ~= nil then
                                    vehicle2, _ = self:_findCouplingOwner(partner.chain.anchorCoupling)
                                    resolvedC = partner.chain.anchorCoupling
                                end
                                if vehicle2 ~= nil then
                                    local vState2 = self:getVehicleState(vehicle2)
                                    if self:isVehicleConduit(vehicle2) then
                                        local conduitActive2 = self.activeFlows[vehicle2] ~= nil
                                        local cabOpen2 = vState2 ~= nil and vState2.valveOpen
                                        local pumpOn2
                                        if self:isVehicleSelfPowered(vehicle2) then
                                            pumpOn2 = vState2 ~= nil and vState2.pumpRunning == true
                                        else
                                            pumpOn2 = vehicle2.getIsTurnedOn ~= nil and vehicle2:getIsTurnedOn() or false
                                        end
                                        local isDestination2 = false
                                        local dir2 = vState2 and vState2.direction or SPS_DIRECTION_FILL
                                        for _, vEntry2 in ipairs(self.registeredVehicles) do
                                            if vEntry2.vehicle == vehicle2 then
                                                for _, c2 in ipairs(vEntry2.couplingEntries) do
                                                    if c2 == resolvedC then
                                                        if (c2.id == 2 and dir2 == SPS_DIRECTION_DISCHARGE) or
                                                           (c2.id == 1 and dir2 == SPS_DIRECTION_FILL) then
                                                            isDestination2 = true
                                                        end
                                                        break
                                                    end
                                                end
                                                break
                                            end
                                        end
                                        if conduitActive2 and cabOpen2 and pumpOn2 and isDestination2 then
                                            shouldPlay = true
                                        end
                                    else
                                        local valveOpen2 = resolvedC.valveOpen == true
                                        local isDischarge2 = vState2 ~= nil and vState2.direction == SPS_DIRECTION_DISCHARGE
                                        local dirOk2
                                        if sc.flowDirection == "DISCHARGE" then dirOk2 = isDischarge2
                                        elseif sc.flowDirection == "FILL" then dirOk2 = not isDischarge2
                                        else dirOk2 = true end
                                        
                                        local tankerHasSlurry2 = false
                                        if vehicle2 ~= nil and resolvedC ~= nil and vehicle2.getFillUnitFillLevel ~= nil then
                                            local fillUnitIndex2 = resolvedC.fillUnitIndex
                                            if fillUnitIndex2 ~= nil then
                                                tankerHasSlurry2 = vehicle2:getFillUnitFillLevel(fillUnitIndex2) > 0
                                            end
                                        end
                                        
                                        if (self:getPressureFlowScalar(vehicle2) > 0) and valveOpen2 and dirOk2 and tankerHasSlurry2 then
                                            shouldPlay = true
                                        end
                                    end
                                end
                            end
                            if shouldPlay then break end
                        end
                    end
                end
                if shouldPlay then
                    if not sc.effectPlaying then
                        g_effectManager:startEffects(sc.pipeEffects)
                        local pe = sc.pipeEffects[1]
                        if pe ~= nil and pe.setDistance ~= nil then
                            pe:setDistance(sc.inletDistance or 1.5)
                            setVisibility(pe.node, true)
                        end
                        sc.effectPlaying = true
                    end
                else
                    if sc.effectPlaying then
                        g_effectManager:stopEffects(sc.pipeEffects)
                        sc.effectPlaying = false
                    end
                end
            end
        end
        end  -- Close if pEntry.storeCouplings ~= nil
    end
 
    -- Resolve vehicle sources (retry each tick until ready)
    for _, vEntry in ipairs(self.registeredVehicles) do
        if vEntry.sourceEntry == nil and vEntry.vehicle.spec_fillUnit ~= nil then
            self:resolveVehicleSource(vEntry.vehicle)
        end
    end
 
    -- Arm detection every 3 ticks
    self.armDetectTick = (self.armDetectTick or 0) + 1
    if self.armDetectTick >= 3 then
        self.armDetectTick = 0
        for _, entry in ipairs(self.registeredVehicles) do
            for _, arm in ipairs(entry.armEntries) do
                self:detectArmConnection(entry.vehicle, entry, arm)
            end
        end
    end
 
    -- Sync sessions with valve state
    -- Arms: session when cab valve open
    -- Couplings: session when coupling manual valve open (state.valveOpen not used)
    for _, entry in ipairs(self.registeredVehicles) do
        local vehicle         = entry.vehicle
        local cabValveOpen    = entry.state ~= nil and entry.state.valveOpen or false
        local hasCouplingFlow = self:hasActiveCouplingConnection(vehicle)
        local needsSession    = cabValveOpen or hasCouplingFlow
        
        if needsSession then
            if self.activeFlows[vehicle] == nil then
                local session = self:buildFlowSession(vehicle)
                if session ~= nil then
                    self.activeFlows[vehicle] = session
                    print("[SPS] update: flow session STARTED for " .. tostring(vehicle.configFileName)
                        .. " cabValve=" .. tostring(cabValveOpen)
                        .. " couplingFlow=" .. tostring(hasCouplingFlow))
                else
                    print("[SPS] update: buildFlowSession returned nil for " .. tostring(vehicle.configFileName))
                end
            end
        else
            if self.activeFlows[vehicle] ~= nil then
                print("[SPS] update: flow session STOPPED for " .. tostring(vehicle.configFileName))
                self:stopFlow(vehicle)
            end
        end
    end
 
    for vehicle, session in pairs(self.activeFlows) do
        self:tickFlow(session, dt)
    end
 
    -- Update pipe bezier visuals each tick
    if g_spsPipeVisual ~= nil then
        for pipeId, pipeData in pairs(self.activePipes) do
            if pipeData.couplingA.mountNode ~= nil and pipeData.couplingB.mountNode ~= nil then
                g_spsPipeVisual:updatePipe(pipeData.inst)
            end
        end
    end
 
    -- Auto-disconnect couplings when vehicle moves beyond maxPipeLength.
    -- Runs every 10 ticks server-side only.
    if g_server ~= nil then
        self._distCheckTick = (self._distCheckTick or 0) + 1
        if self._distCheckTick >= 10 then
            self._distCheckTick = 0
            self._distCheckRan = (self._distCheckRan or 0) + 1
            if self._distCheckRan <= 3 then
            end
            for _, entry in ipairs(self.registeredVehicles) do
                for _, coupling in ipairs(entry.couplingEntries) do
                    if coupling.isConnected and coupling.mountNode ~= nil then
                        local partner = coupling.connectedPartnerCoupling
                        if partner ~= nil and partner.mountNode ~= nil then
                            if entityExists(coupling.mountNode) and entityExists(partner.mountNode) then
                                local ax, ay, az = getWorldTranslation(coupling.mountNode)
                                local bx, by, bz = getWorldTranslation(partner.mountNode)
                                local dist = MathUtil.vector3Length(ax - bx, ay - by, az - bz)
                                if dist > SPS_AUTODISCONNECT_DIST then
                                    print("[SPS] auto-disconnect: dist=" .. string.format("%.1f", dist)
                                        .. "m > max=" .. tostring(SPS_AUTODISCONNECT_DIST) .. "m")
                                    self:_forceDisconnect(entry.vehicle, coupling)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
 
    -- Update chain pipe visuals
    for _, chain in ipairs(self.pipeChains) do
        chain:update(dt)
    end
end

-- ---------------------------------------------------------------------------
-- [SPS #2] Direct sprayer-effect driver (Precision Farming compatibility)
-- Starts/stops the Sprayer's spray effect, sound and animations using the exact
-- same operations PF performs in ExtendedSprayer:updateSprayerEffectState, but
-- driven straight off self.spec_sprayer. This avoids depending on PF's class
-- table (not visible as a global from this manager) and bypasses PF's
-- lastSprayerEffectState latch (pinned true while turned off). Used only to keep
-- the rear discharge effect showing during the stored-pressure taper under PF.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_driveSprayerEffect(sv, on)
    local specSprayer = sv.spec_sprayer
    if specSprayer == nil then return end
    if sv.isClient == false then return end   -- effects are client-side only
    local sprayType = (sv.getActiveSprayType ~= nil) and sv:getActiveSprayType() or nil
    if on then
        local fillType = FillType.UNKNOWN
        if sv.getFillUnitLastValidFillType ~= nil and sv.getSprayerFillUnitIndex ~= nil then
            fillType = sv:getFillUnitLastValidFillType(sv:getSprayerFillUnitIndex())
            if fillType == FillType.UNKNOWN and sv.getFillUnitFirstSupportedFillType ~= nil then
                fillType = sv:getFillUnitFirstSupportedFillType(sv:getSprayerFillUnitIndex())
            end
        end
        if specSprayer.effects ~= nil then
            g_effectManager:setEffectTypeInfo(specSprayer.effects, fillType)
            g_effectManager:startEffects(specSprayer.effects)
        end
        if specSprayer.samples ~= nil and specSprayer.samples.spray ~= nil then
            g_soundManager:playSamples(specSprayer.samples.spray)
        end
        if sprayType ~= nil then
            g_effectManager:setEffectTypeInfo(sprayType.effects, fillType)
            g_effectManager:startEffects(sprayType.effects)
            g_animationManager:startAnimations(sprayType.animationNodes)
            if sprayType.samples ~= nil then
                g_soundManager:playSamples(sprayType.samples.spray)
            end
        end
        g_animationManager:startAnimations(specSprayer.animationNodes)
    else
        if specSprayer.effects ~= nil then
            g_effectManager:stopEffects(specSprayer.effects)
        end
        if specSprayer.samples ~= nil and specSprayer.samples.spray ~= nil then
            g_soundManager:stopSamples(specSprayer.samples.spray)
        end
        if specSprayer.sprayTypes ~= nil then
            for _, st in ipairs(specSprayer.sprayTypes) do
                g_effectManager:stopEffects(st.effects)
                g_animationManager:stopAnimations(st.animationNodes)
                if st.samples ~= nil then
                    g_soundManager:stopSamples(st.samples.spray)
                end
            end
        end
        g_animationManager:stopAnimations(specSprayer.animationNodes)
    end
end

-- ---------------------------------------------------------------------------
-- Arm detection
-- ---------------------------------------------------------------------------
function SlurryPipeManager:detectArmConnection(vehicle, entry, arm)
    -- If any pipe coupling on this vehicle is connected, the pipe governs.
    -- Arm detection is blocked completely to prevent cab valve from bypassing
    -- the manual valve on the pipe connection.
    for _, c in ipairs(entry.couplingEntries) do
        if c.isConnected then
            if arm.isConnected then
                arm.isConnected    = false
                arm.connectedSource   = nil
                arm.connectedBootPort = nil
            end
            return
        end
    end

    local state     = entry.state
    local direction = state and state.direction or SPS_DIRECTION_FILL
    local tipType   = arm.tipType or SPS_TIP_TYPE_OPEN_PIT

    local newConnected    = false
    local foundSource     = nil
    local foundBootPort   = nil

    -- Rubber boot detection
    local supportsRubberBoot = (tipType == SPS_TIP_TYPE_RUBBER_BOOT) or (tipType == SPS_TIP_TYPE_RUBBER_BOOT_PIT)
    if supportsRubberBoot and arm.tipNode ~= nil and entityExists(arm.tipNode) then
        local tx, ty, tz   = getWorldTranslation(arm.tipNode)
        local XZ_TOLERANCE = 0.15
        for _, rbpEntry in ipairs(self.rubberBootPortEntries) do
            if rbpEntry.vehicle ~= vehicle and rbpEntry.lowerNode ~= nil and rbpEntry.upperNode ~= nil then
                if entityExists(rbpEntry.lowerNode) and entityExists(rbpEntry.upperNode) then
                    local lx, lowerY, lz = getWorldTranslation(rbpEntry.lowerNode)
                    local _,  upperY, _  = getWorldTranslation(rbpEntry.upperNode)
                    if lowerY > upperY then lowerY, upperY = upperY, lowerY end
                    local xzDist = math.sqrt((tx - lx) * (tx - lx) + (tz - lz) * (tz - lz))
                    if ty >= lowerY and ty <= upperY and xzDist <= XZ_TOLERANCE then
                        newConnected  = true
                        foundBootPort = rbpEntry
                        break
                    end
                end
            end
        end
    end

    -- Open pit detection
    local supportsOpenPit = (tipType == SPS_TIP_TYPE_OPEN_PIT) or (tipType == SPS_TIP_TYPE_RUBBER_BOOT_PIT)
    if supportsOpenPit and not newConnected and arm.centreNode ~= nil then
        local THRESHOLD   = 0.08
        local centreX, centreY, centreZ = getWorldTranslation(arm.centreNode)

        for _, sourceEntry in ipairs(self.sourceEntries) do
            if sourceEntry.vehicle == vehicle then continue end

            -- XZ check: shape-based bounds for STORAGE_PLANE, fixed radius for FILL_VOLUME.
            local xzOk = false
            if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                local bounds = sourceEntry.planeBounds
                if bounds == nil then continue end
                if bounds.shape == "round" then
                    local bx, _, bz = getWorldTranslation(bounds.centreNode)
                    local dx = centreX - bx
                    local dz = centreZ - bz
                    xzOk = (dx * dx + dz * dz) <= (bounds.radius * bounds.radius)
                elseif bounds.shape == "rectangle" then
                    local lx, _, lz = worldToLocal(bounds.centreNode, centreX, centreY, centreZ)
                    xzOk = lx >= bounds.minX and lx <= bounds.maxX and lz >= bounds.minZ and lz <= bounds.maxZ
                end
            elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
                local bx, _, bz = getWorldTranslation(sourceEntry.baseNode)
                local dx = centreX - bx
                local dz = centreZ - bz
                local r = SlurryPipeManager.FILL_VOLUME_SEARCH_RADIUS
                xzOk = (dx * dx + dz * dz) <= (r * r)
            end
            if not xzOk then continue end

            local surfaceY = SlurryNodeUtil.getSurfaceWorldY(sourceEntry, centreX, centreZ)
            if surfaceY == -math.huge then continue end

            local valid = false
            if direction == SPS_DIRECTION_FILL then
                -- Centre node must be below the surface: nozzle is submerged
                valid = surfaceY > centreY + THRESHOLD
            else
                -- Centre node must be above the surface: nozzle is over the liquid
                valid = centreY > surfaceY + THRESHOLD
            end

            if valid then
                newConnected = true
                foundSource  = sourceEntry
                break
            end
        end
    end

    -- Water plane detection (only if not already connected)
    if supportsOpenPit and not newConnected and arm.centreNode ~= nil and g_waterPlaneManager ~= nil then
        local THRESHOLD = 0.08
        local centreX, centreY, centreZ = getWorldTranslation(arm.centreNode)
        
        -- Find water plane at this position
        local waterPlane = g_waterPlaneManager:findWaterPlaneAtPosition(centreX, centreZ)
        
        if waterPlane ~= nil then
            local valid = false
            
            if direction == SPS_DIRECTION_FILL then
                -- Fill: centre node must be below water surface (submerged)
                valid = centreY < waterPlane.waterY - THRESHOLD
            else
                -- Discharge: centre node must be above water surface
                valid = centreY > waterPlane.waterY + THRESHOLD
            end
            
            if valid then
                -- Create infinite water source
                local waterSource = g_waterPlaneManager:createWaterSource(waterPlane)
                newConnected = true
                foundSource = waterSource
            end
        end
    end

    local prevConnected   = arm.isConnected
    arm.isConnected       = newConnected
    arm.connectedSource   = foundSource
    arm.connectedBootPort = foundBootPort

    if prevConnected ~= newConnected then
        if newConnected then
            print("[SPS] Arm connected (" .. (foundBootPort ~= nil and "RUBBER_BOOT" or "OPEN_PIT") .. ") on " .. tostring(vehicle.configFileName))
            self:onArmConnected(vehicle, arm)
        else
            print("[SPS] Arm disconnected on " .. tostring(vehicle.configFileName))
            self:onArmDisconnected(vehicle, arm)
        end
    end

    if entry.pipeEffects ~= nil then
        local valveOpen   = state ~= nil and state.valveOpen or false
        local fillLevel   = vehicle.getFillUnitFillLevel ~= nil and vehicle:getFillUnitFillLevel(arm.fillUnitIndex) or 0
        -- The stream follows actual flow, which is pressure-driven (not the PTO),
        -- and shows in BOTH directions: a discharge stream out, or a suction
        -- stream while filling. For an exempt endpoint the scalar is 1.0 so it
        -- behaves as a simple on/off with the valve.
        local pScalar     = self:getPressureFlowScalar(vehicle)
        local isDischarge = state ~= nil and state.direction == SPS_DIRECTION_DISCHARGE or false
        local hasFlowContent
        if isDischarge then
            hasFlowContent = fillLevel > 0      -- discharging: slurry must be in the tank
        else
            hasFlowContent = foundSource ~= nil -- filling: a source must be present to draw from
        end
        local shouldPlay  = arm.isConnected and valveOpen and pScalar > 0 and hasFlowContent
        if shouldPlay then
            if not arm.effectPlaying then
                local effectFillType = vehicle:getFillUnitFillType(arm.fillUnitIndex)
                if effectFillType == nil or effectFillType == FillType.UNKNOWN then
                    effectFillType = FillType.LIQUIDMANURE
                end
                -- Apply material matching the current fluid before starting effects
                local pe = entry.pipeEffects[1]
                if pe ~= nil then
                    if effectFillType == FillType.WATER and g_spsWaterMaterial ~= nil then
                        setMaterial(pe.node, g_spsWaterMaterial, 0)
                        print("[SPS] arm effect: applying WATER material for " .. tostring(vehicle.configFileName))
                    elseif g_spsSlurryMaterial ~= nil then
                        setMaterial(pe.node, g_spsSlurryMaterial, 0)
                        print("[SPS] arm effect: applying SLURRY material for " .. tostring(vehicle.configFileName))
                    end
                    pe.hasValidMaterial = true
                    pe.useBaseMaterial  = true
                end
                g_effectManager:setEffectTypeInfo(entry.pipeEffects, effectFillType)
                print("[SPS] after setEffectTypeInfo: hasValidMaterial=" .. tostring(pe and pe.hasValidMaterial) .. " node=" .. tostring(pe and pe.node))
                g_effectManager:startEffects(entry.pipeEffects)
                arm.effectPlaying = true
            end
            -- Update stream distance: nozzle to slurry surface
            if arm.centreNode ~= nil and foundSource ~= nil then
                local _, nozzleY, _ = getWorldTranslation(arm.centreNode)
                local surfY = SlurryNodeUtil.getSurfaceWorldY(foundSource, centreX, centreZ)
                if surfY ~= -math.huge then
                    local dist = math.abs(nozzleY - surfY)
                    local pipeEffect = entry.pipeEffects[1]
                    if pipeEffect ~= nil and pipeEffect.setDistance ~= nil then
                        pipeEffect:setDistance(dist)
                        setVisibility(pipeEffect.node, dist > 0.05)
                    end
                end
            end
        else
            if arm.effectPlaying then g_effectManager:stopEffects(entry.pipeEffects) arm.effectPlaying = false end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Flow tick
-- ---------------------------------------------------------------------------
function SlurryPipeManager:tickFlow(session, dt)
    local vehicle = session.vehicle
    local state   = self:getVehicleState(vehicle)
    if state == nil then return end

    local pumpRunning
    if self:isVehicleSelfPowered(vehicle) then
        pumpRunning = state.pumpRunning == true
    else
        pumpRunning = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() or false
    end

    -- Conduit pump: direct source-to-source transfer, no vehicle fill unit involved
    if self:isVehicleConduit(vehicle) then
        if not state.valveOpen then return end
        if not pumpRunning then return end
        local c1, c2
        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.vehicle == vehicle then
                for _, c in ipairs(vEntry.couplingEntries) do
                    if     c.id == 1 then c1 = c
                    elseif c.id == 2 then c2 = c end
                end
                break
            end
        end
        if c1 == nil or c2 == nil or not c1.isConnected or not c2.isConnected then return end

        -- Stop flow if the near-end bez pipe has been physically removed on either side.
        -- For vehicle-anchored chains the near-end bez is chainStartCoupling on segment 1.
        local function chainIntact(pumpCoupling)
            local partner = pumpCoupling.connectedPartnerCoupling
            if partner == nil or not partner.isChainTerminus then return true end
            local chain = partner.chain
            if chain == nil then return true end
            local anchor = chain.anchorCoupling
            if anchor == nil or anchor.placeable ~= nil then return true end
            local seg1 = chain.segments and chain.segments[1]
            if seg1 ~= nil and seg1.chainStartCoupling ~= nil then
                if not seg1.chainStartCoupling.isConnected then return false end
            end
            return true
        end
        if not chainIntact(c1) or not chainIntact(c2) then return end
        local srcCoupling = (state.direction == SPS_DIRECTION_DISCHARGE) and c1 or c2
        local dstCoupling = (state.direction == SPS_DIRECTION_DISCHARGE) and c2 or c1

        -- Check flowDirection on the real partner couplings (may be behind chain terminus)
        local function resolvePartnerFlowDirection(pumpCoupling)
            local partner = pumpCoupling.connectedPartnerCoupling
            if partner == nil then return nil end
            if partner.isChainTerminus and partner.chain ~= nil then
                partner = partner.chain.anchorCoupling
            end
            return partner and partner.flowDirection or nil
        end
        local srcPartnerDir = resolvePartnerFlowDirection(srcCoupling)
        local dstPartnerDir = resolvePartnerFlowDirection(dstCoupling)
        if srcPartnerDir == "DISCHARGE" then return end
        if dstPartnerDir == "FILL" then return end
        local srcEntry = self:resolveSourceForCouplingPartner(srcCoupling)
        local dstEntry = self:resolveSourceForCouplingPartner(dstCoupling)
        if srcEntry == nil or dstEntry == nil then return end

        -- Resolve fillType from what the source actually holds (LIQUIDMANURE,
        -- DIGESTATE, etc.). If source is empty, nothing to transfer.
        local fillType = self:_resolveSourceFillType(srcEntry)
        if fillType == nil then return end

        -- Verify destination accepts this fillType (right category + free space).
        if not self:_destAcceptsFillType(dstEntry, fillType) then
            if not session._loggedTypeMismatch then
                print(string.format("[SPS] coupling-to-coupling: destination does not accept fillType %s (source=%s, dst=%s)",
                    tostring(fillType),
                    tostring(srcEntry.type), tostring(dstEntry.type)))
                session._loggedTypeMismatch = true
            end
            return
        end

        local sourceLevel = 0
        if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or srcEntry.type == "FILL_UNIT_ONLY" then
            if srcEntry.vehicle ~= nil then
                sourceLevel = srcEntry.vehicle:getFillUnitFillLevel(srcEntry.fillUnitIndex) or 0
            end
        elseif srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            if srcEntry.storage ~= nil then
                sourceLevel = srcEntry.storage:getFillLevel(fillType) or 0
            end
        end
        if sourceLevel <= 0 then return end
        local freeCapacity = 0
        if dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or dstEntry.type == "FILL_UNIT_ONLY" then
            if dstEntry.vehicle ~= nil then
                local cap   = dstEntry.vehicle:getFillUnitCapacity(dstEntry.fillUnitIndex) or 0
                local level = dstEntry.vehicle:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0
                freeCapacity = cap - level
            end
        elseif dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            if dstEntry.storage ~= nil then
                freeCapacity = dstEntry.storage:getFreeCapacity(self:resolveStoreDepositFillType(dstEntry, fillType)) or 0
            end
        end
        if freeCapacity <= 0 then return end
        local rateBase = (state.direction == SPS_DIRECTION_DISCHARGE)
            and (session.baseEmptyLitersPerSecond or session.baseLitersPerSecond)
            or  (session.baseFillLitersPerSecond  or session.baseLitersPerSecond)
        local amount = math.min(rateBase * dt * 0.001, sourceLevel, freeCapacity)
        -- Apply thickness slowdown based on what the SOURCE carries. A placeable
        -- store uses its apparent (DM) thickness; a tanker source uses the thickness
        -- it is carrying (state.thickness). Either way thick slurry slows the transfer
        -- and a jammed source (mult <= 0) stops it with the same warning.
        local mult = 1.0
        if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            mult = self:getFlowRateMultiplier(srcEntry)
        elseif (srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME
                or srcEntry.type == "FILL_UNIT_ONLY")
               and srcEntry.vehicle ~= nil then
            mult = self:thicknessToFlowMultiplier(self:getTankerThickness(srcEntry.vehicle))
        end
        if mult <= 0 then
            if self:_warningIsRelevant(vehicle) then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
            end
            return
        end
        amount = amount * mult
        if amount <= 0 then return end
        self:removeFromSource(srcEntry, amount, fillType, vehicle)
        self:addToSource(dstEntry, amount, fillType, vehicle)
        session.totalTransferred = (session.totalTransferred or 0) + amount
        return
    end

    local isArmActive     = self:connectionIsFillArm(vehicle)
    local hasCouplingFlow = self:hasActiveCouplingConnection(vehicle)

    if not isArmActive and not hasCouplingFlow then
        return
    end

    local fillType = vehicle:getFillUnitFillType(session.vehicleFillUnit)
    if fillType == nil or fillType == FillType.UNKNOWN then fillType = FillType.LIQUIDMANURE end
    
    -- If connected to water source via arm, override fillType to WATER
    if isArmActive and state.direction == SPS_DIRECTION_FILL then
        local extSrc = self:resolveExternalSource(vehicle)
        if extSrc ~= nil and extSrc.type == 3 then  -- SPSWaterPlaneManager.SOURCE_TYPE_WATER
            fillType = FillType.WATER
        end
    end

    local hasContent = (vehicle.getFillUnitFillLevel ~= nil
        and (vehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0) > 0)

    if isArmActive then
        -- Fill arm requires the cab hydraulic valve open. The effective flow is then
        -- resolved by the pressure model (resolveCouplingFlow): stored pressure/vacuum
        -- at/above minThreshold drives flow in its built direction, and a spent tank
        -- backflows out by gravity.
        if not state.valveOpen then
            return
        end
        local flowDir, scalar = self:resolveCouplingFlow(vehicle, state, pumpRunning, hasContent)
        if flowDir == nil or scalar <= 0 then return end
        local rateBase = (flowDir == SPS_DIRECTION_FILL)
            and (session.baseFillLitersPerSecond or session.baseLitersPerSecond)
            or  (session.baseEmptyLitersPerSecond or session.baseLitersPerSecond)
        local rate = rateBase * dt * 0.001 * scalar
        rate = rate * self:getPipeLengthFalloff(vehicle)   -- 1.0 for a rigid arm
        if flowDir == SPS_DIRECTION_FILL then
            local extSrc = self:resolveExternalSource(vehicle)
            if extSrc ~= nil then
                local mult = self:getFlowRateMultiplier(extSrc)   -- source (store) thickness slows the suck
                if mult <= 0 then
                    if self:_warningIsRelevant(vehicle) then
                        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
                    end
                    return
                end
                rate = rate * mult
            end
            local oldLevel = vehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0
            self:transferFill(vehicle, session, rate, fillType)
            -- Inherit the source's thickness into the tank for whatever was added.
            local added = (vehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0) - oldLevel
            if added > 0 then
                self:applyFillThicknessBlend(vehicle, oldLevel, added, self:getSourceThickness(extSrc))
                self:applyFillCrustBlend(vehicle, oldLevel, added, self:getSourceCrust(extSrc))
            end
        else
            rate = rate * self:getTankerThicknessMultiplier(vehicle)   -- carried thickness slows the push-out
            self:transferDischarge(vehicle, session, rate, fillType)
        end
    else
        -- Pipe coupling. Resolve the effective flow from the pressure model first
        -- (stored pressure/vacuum at/above minThreshold drives flow in its built
        -- direction; a spent tank backflows out by gravity), then honour any partner
        -- coupling flow-direction restriction against that EFFECTIVE direction.
        local flowDir, scalar = self:resolveCouplingFlow(vehicle, state, pumpRunning, hasContent)
        if flowDir == nil or scalar <= 0 then return end

        for _, vEntry in ipairs(self.registeredVehicles) do
            if vEntry.vehicle == vehicle then
                for _, c in ipairs(vEntry.couplingEntries) do
                    if c.isConnected and c.connectedPartnerCoupling ~= nil then
                        -- Direct partner or chain terminus partner
                        local partner = c.connectedPartnerCoupling
                        local effectivePartner = partner
                        if partner.isChainTerminus and partner.chain ~= nil then
                            effectivePartner = partner.chain.anchorCoupling or partner
                        end
                        local partnerDir = effectivePartner.flowDirection
                        if partnerDir ~= nil and partnerDir ~= "BOTH" then
                            if partnerDir == "DISCHARGE" and flowDir == SPS_DIRECTION_FILL then
                                return
                            elseif partnerDir == "FILL" and flowDir == SPS_DIRECTION_DISCHARGE then
                                return
                            end
                        end
                    end
                end
                break
            end
        end

        local rateBase = (flowDir == SPS_DIRECTION_FILL)
            and (session.baseFillLitersPerSecond or session.baseLitersPerSecond)
            or  (session.baseEmptyLitersPerSecond or session.baseLitersPerSecond)
        local rate = rateBase * dt * 0.001 * scalar
        rate = rate * self:getPipeLengthFalloff(vehicle)   -- strap pipe stretch falloff
        if flowDir == SPS_DIRECTION_FILL then
            local extSrc = self:resolveExternalSource(vehicle)
            if extSrc ~= nil then
                local mult = self:getFlowRateMultiplier(extSrc)   -- source (store) thickness slows the suck
                if mult <= 0 then
                    if self:_warningIsRelevant(vehicle) then
                        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
                    end
                    return
                end
                rate = rate * mult
            end
            local oldLevel = vehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0
            self:transferFill(vehicle, session, rate, fillType)
            local added = (vehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0) - oldLevel
            if added > 0 then
                self:applyFillThicknessBlend(vehicle, oldLevel, added, self:getSourceThickness(extSrc))
                self:applyFillCrustBlend(vehicle, oldLevel, added, self:getSourceCrust(extSrc))
            end
        else
            rate = rate * self:getTankerThicknessMultiplier(vehicle)   -- carried thickness slows the push-out
            self:transferDischarge(vehicle, session, rate, fillType)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Slurry thickness
-- ---------------------------------------------------------------------------

-- Returns a 0.0-1.0 multiplier for flow rate based on sourceEntry thickness.
-- thickness 0.0-0.8 : linear reduction (0% thick = full flow, 80% thick = 20% flow)
-- thickness >= 0.9  : no flow
-- ---------------------------------------------------------------------------
-- Two-pool dry-matter model (stores)
-- ---------------------------------------------------------------------------

-- Map a true dry-matter fraction (solids/total) to the 0..1 thickness gauge.
function SlurryPipeManager:dmToGauge(dm)
    local lo, hi = SlurryPipeManager.DM_FRESH, SlurryPipeManager.DM_JAMMED
    if hi <= lo then return 0.0 end
    return math.max(0.0, math.min(1.0, ((dm or 0) - lo) / (hi - lo)))
end

-- Inverse: a 0..1 gauge value back to a dry-matter fraction. Used when a tanker
-- (which carries a gauge value) discharges into a store and we need real solids.
function SlurryPipeManager:gaugeToDM(gauge)
    local lo, hi = SlurryPipeManager.DM_FRESH, SlurryPipeManager.DM_JAMMED
    return lo + math.max(0.0, math.min(1.0, gauge or 0)) * (hi - lo)
end

-- Total slurry held by a store, summed across every fill type it tracks. Slurry and
-- digestate share one fillPlane and are treated as a single pile, so the dry-matter
-- maths must see the combined level rather than a single fillType's level.
function SlurryPipeManager:_getStoreTotalFill(se)
    if se == nil or se.storage == nil then return 0 end
    local levels = se.storage.getFillLevels ~= nil and se.storage:getFillLevels() or se.storage.fillLevels
    if levels ~= nil then
        local total = 0
        for _, lvl in pairs(levels) do
            total = total + (lvl or 0)
        end
        return total
    end
    return (se.fillType ~= nil and (se.storage:getFillLevel(se.fillType) or 0)) or 0
end

-- Lazily initialise the two-pool fields on a storage sourceEntry. solids = litres of
-- dry matter; settle = 0..1 settling offset removed by agitation. Liquid is derived
-- live as (totalFill - solids).
function SlurryPipeManager:_ensureStorePools(se)
    if se == nil then return end
    if se.solids == nil then
        se.solids = self:_getStoreTotalFill(se) * SlurryPipeManager.DM_FRESH
    end
    if se.settle == nil then
        se.settle = se._migratedSettle or 0
        se._migratedSettle = nil
    end
    if se._lastTotal == nil then
        se._lastTotal = self:_getStoreTotalFill(se)
    end
end

-- Reconcile the dry-matter pool against the store's real total. A rise since we last
-- looked came from outside SPS (vanilla fill, AI, map, console) and is treated as fresh
-- slurry at DM_FRESH; a fall is a proportional draw. SPS transfers update _lastTotal as
-- they go, so their changes show no delta here and are not re-counted.
function SlurryPipeManager:_reconcileStorePools(se)
    if se == nil or se.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return end
    if not se.thickeningEnabled then return end
    self:_ensureStorePools(se)
    local total = self:_getStoreTotalFill(se)
    local last  = se._lastTotal or total
    if total > last + 0.001 then
        se.solids = (se.solids or 0) + (total - last) * SlurryPipeManager.DM_FRESH
    elseif total < last - 0.001 then
        local dm = last > 0 and ((se.solids or 0) / last) or 0
        se.solids = math.max(0, (se.solids or 0) - (last - total) * dm)
    end
    se.solids   = math.max(0, math.min(se.solids or 0, total))
    se._lastTotal = total
    -- An empty store holds no slurry, so it holds no crust.
    if total <= 0 and (se.settle or 0) > 0 then se.settle = 0 end
end

-- A flow warning should only blink when the player is actually working this rig:
-- sitting in its cab (active for input on the root vehicle) or stood next to it on
-- foot, within WARNING_RANGE. Without this a connected pump left running would spam
-- the warning across the whole map. Mirrors the cab guard and on-foot proximity test
-- used by the pump-control activatables.
function SlurryPipeManager:_warningIsRelevant(vehicle)
    if vehicle == nil or not vehicle.isClient then return false end
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if root ~= nil and root.getIsActiveForInput ~= nil and root:getIsActiveForInput(true) then
        return true
    end
    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        local vx, vy, vz
        if vehicle.rootNode ~= nil then
            vx, vy, vz = getWorldTranslation(vehicle.rootNode)
        elseif vehicle.components ~= nil and vehicle.components[1] ~= nil then
            vx, vy, vz = getWorldTranslation(vehicle.components[1].node)
        end
        if vx ~= nil then
            local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
            local dx, dy, dz = px - vx, py - vy, pz - vz
            local r = SlurryPipeManager.WARNING_RANGE
            if (dx*dx + dy*dy + dz*dz) <= r * r then return true end
        end
    end
    return false
end

-- True dry-matter fraction of a store right now (0..1) = solids / total.
function SlurryPipeManager:getStoreDM(se)
    if se == nil or se.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return 0 end
    self:_ensureStorePools(se)
    local total = self:_getStoreTotalFill(se)
    if total <= 0 then return 0 end
    return math.max(0.0, math.min(1.0, (se.solids or 0) / total))
end

-- The player-facing thickness gauge (0..1) = gauge(DM) + settling offset, clamped.
-- Every flow / warning / display consumer reads this. Returns 0 for stores that do
-- not participate in the thickness model.
function SlurryPipeManager:getApparentThickness(se)
    if se == nil or se.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return 0 end
    if not se.thickeningEnabled then return 0 end
    self:_ensureStorePools(se)
    local dmGauge = self:dmToGauge(self:getStoreDM(se))
    return math.max(0.0, math.min(1.0, dmGauge + (se.settle or 0)))
end

-- For depositing into a storage-plane store: returns the fillType to actually use
-- against the storage object. A slurry store is configured for slurryTank only and
-- does NOT accept WATER, so water piped or fill-armed in is converted to the store's
-- current content type (or, if empty, its configured fillPlane type) as it enters —
-- it becomes slurry or digestate. Returns just the deposit fillType.
function SlurryPipeManager:resolveStoreDepositFillType(se, incomingFillType)
    if se == nil or se.storage == nil then return incomingFillType end
    local levels = se.storage.getFillLevels ~= nil and se.storage:getFillLevels() or se.storage.fillLevels
    if levels ~= nil and levels[incomingFillType] ~= nil then
        return incomingFillType   -- store natively accepts this type
    end
    -- Not accepted: prefer the type the store currently holds, else its native type.
    local native = se.fillType
    if levels ~= nil then
        for ft, lvl in pairs(levels) do
            if (lvl or 0) > 0 then native = ft break end
        end
    end
    return native
end

function SlurryPipeManager:getFlowRateMultiplier(sourceEntry)
    if not self:isFeatureEnabled("thicknessFlow") then return 1.0 end
    if sourceEntry == nil then return 1.0 end
    if sourceEntry.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return 1.0 end
    local t = self:getApparentThickness(sourceEntry)
    if t >= 0.9 then return 0.0 end
    -- Linear: each 10% thickness = 10% flow reduction, capped at 80%
    return math.max(0.0, 1.0 - math.min(t, 0.8))
end

-- Same thickness->flow curve as getFlowRateMultiplier, but for a raw thickness value
-- (0..1). Used for the thickness a tanker CARRIES (state.thickness) so pipe-discharge
-- and (Pass 2) spreading slow down with thick slurry, exactly as filling from a thick
-- store already does.
function SlurryPipeManager:thicknessToFlowMultiplier(t)
    if not self:isFeatureEnabled("thicknessFlow") then return 1.0 end
    t = t or 0
    if t >= 0.9 then return 0.0 end
    return math.max(0.0, 1.0 - math.min(t, 0.8))
end

-- The thickness a tanker is carrying right now (0..1), or 0 if none/unknown.
function SlurryPipeManager:getTankerThickness(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return 0 end
    return state.thickness or 0
end

-- The crust/lumpiness a tanker is carrying right now (0..1). Inherited from the store's
-- un-mixed level at fill time; this is what drives spreader blockages. 0 if none/unknown.
function SlurryPipeManager:getTankerCrust(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return 0 end
    return state.crust or 0
end

-- The crust an external source carries, for inheritance on fill:
--   storage plane -> its stored crust (settle)
--   another tanker -> that tanker's carried crust
--   water / anything else -> 0 (clean)
function SlurryPipeManager:getSourceCrust(extSource)
    if extSource == nil then return 0 end
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        self:_ensureStorePools(extSource)
        return extSource.settle or 0
    end
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extSource.type == "FILL_UNIT_ONLY" then
        if extSource.vehicle ~= nil then
            return self:getTankerCrust(extSource.vehicle)
        end
    end
    return 0
end

-- Volume-weighted blend of inherited crust into a tanker as it fills (mirrors
-- applyFillThicknessBlend). Loading from a freshly-mixed store thins the carried crust;
-- loading from a long-unmixed store raises it.
function SlurryPipeManager:applyFillCrustBlend(vehicle, oldLevel, addedVol, srcCrust)
    if addedVol <= 0 then return end
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local oldC  = state.crust or 0
    local denom = (oldLevel or 0) + addedVol
    if denom <= 0 then
        state.crust = srcCrust or 0
    else
        state.crust = ((oldLevel or 0) * oldC + addedVol * (srcCrust or 0)) / denom
    end
end

-- Flow multiplier from the thickness a tanker CARRIES (used on the pipe-discharge side).
function SlurryPipeManager:getTankerThicknessMultiplier(vehicle)
    return self:thicknessToFlowMultiplier(self:getTankerThickness(vehicle))
end

-- The thickness of whatever an external source is holding, for inheritance on fill:
--   storage plane -> its stored thickness
--   another tanker (fill volume / fill unit) -> that tanker's carried thickness
--   water (type 3) / anything else -> 0 (water is never thick)
function SlurryPipeManager:getSourceThickness(extSource)
    if extSource == nil then return 0 end
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        -- A pump draws mixed slurry from below any surface crust, so the tanker inherits
        -- the store's true dry-matter level (gauge of DM), not the settled surface gauge.
        return self:dmToGauge(self:getStoreDM(extSource))
    end
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extSource.type == "FILL_UNIT_ONLY" then
        if extSource.vehicle ~= nil then
            return self:getTankerThickness(extSource.vehicle)
        end
    end
    return 0
end

-- Blends inherited thickness into a tanker as it fills. New carried thickness is the
-- volume-weighted average of what was already in the tank and what just came in:
--   new = (oldLevel*oldThk + addedVol*srcThk) / (oldLevel + addedVol)
-- so topping up from a thinner source thins the load and vice-versa. oldLevel is the
-- tank level BEFORE this tick's add.
function SlurryPipeManager:applyFillThicknessBlend(vehicle, oldLevel, addedVol, srcThk)
    if addedVol <= 0 then return end
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local oldThk = state.thickness or 0
    local denom  = (oldLevel or 0) + addedVol
    if denom <= 0 then
        state.thickness = srcThk or 0
    else
        state.thickness = ((oldLevel or 0) * oldThk + addedVol * (srcThk or 0)) / denom
    end
end

-- Flow falloff over the length of a connected strap pipe: full rate when the couplers
-- are close, dropping linearly to a floor as the live distance approaches maxPipeLength.
-- Returns 1.0 for a fill arm (rigid, no pipe) or when no connected coupling is found.
-- Direct coupling connections only; chain falloff (summed segments) is a later addition.
function SlurryPipeManager:getPipeLengthFalloff(vehicle)
    if not self:isFeatureEnabled("lengthFalloff") then return 1.0 end
    if self:connectionIsFillArm(vehicle) then return 1.0 end
    for _, vEntry in ipairs(self.registeredVehicles) do
        if vEntry.vehicle == vehicle then
            for _, c in ipairs(vEntry.couplingEntries) do
                if c.isConnected and c.valveOpen
                and c.mountNode ~= nil
                and c.connectedPartnerCoupling ~= nil
                and c.connectedPartnerCoupling.mountNode ~= nil then
                    local ax, ay, az = getWorldTranslation(c.mountNode)
                    local bx, by, bz = getWorldTranslation(c.connectedPartnerCoupling.mountNode)
                    local dist   = MathUtil.vector3Length(ax - bx, ay - by, az - bz)
                    local maxLen = c.maxPipeLength or 6.0
                    if maxLen <= 0 then return 1.0 end
                    local floor = SlurryPipeManager.DEFAULT_LENGTH_FALLOFF_FLOOR
                    local frac  = math.min(1.0, math.max(0.0, dist / maxLen))
                    return math.max(floor, 1.0 - (1.0 - floor) * frac)
                end
            end
            break
        end
    end
    return 1.0
end

-- Returns a warning level string for the given sourceEntry thickness.
-- "none", "thickening", "tooThick"
function SlurryPipeManager:getThicknessWarning(sourceEntry)
    if not self:isFeatureEnabled() then return "none" end
    if sourceEntry == nil then return "none" end
    if sourceEntry.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return "none" end
    if not sourceEntry.thickeningEnabled then return "none" end
    local apparent = self:getApparentThickness(sourceEntry)
    local dmGauge  = self:dmToGauge(self:getStoreDM(sourceEntry))
    -- Jammed on dry matter alone -> mixing can't help, water needed.
    if dmGauge >= 0.9 then return "tooThick" end
    -- Jammed by settling but dry matter is fine -> agitation will free it.
    if apparent >= 0.9 then return "needsMix" end
    if apparent >= 0.8 then return "thickening" end
    return "none"
end

-- Called by SlurryAgitator spec each tick while actively stirring.
-- dtHours: game hours elapsed this tick (dt * 0.001 / 3600 * timeScale).
-- Reduces thickness by dtHours / hoursPerTenPercent where
-- hoursPerTenPercent = daysPerPeriod * 24 / 10 — matching the accumulation rate.
function SlurryPipeManager:applyAgitation(sourceEntry, dtHours)
    if not self:isFeatureEnabled() then return end
    if sourceEntry == nil then return end
    if sourceEntry.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return end
    self:_ensureStorePools(sourceEntry)
    -- Mixing re-suspends settled solids: it only removes the settling offset. It can
    -- never lower the dry-matter fraction, so a store whose DM is already jammed stays
    -- jammed no matter how long it is stirred (the player must add water instead).
    if (sourceEntry.settle or 0) <= 0 then return end
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local dpp = (env ~= nil and env.daysPerPeriod or 28)
    local hoursPerTenPercent = dpp * 24 / 10
    local reduction = dtHours / hoursPerTenPercent
    sourceEntry.settle = math.max(0.0, (sourceEntry.settle or 0) - reduction)
    --SlurryDebug.log("[SPS Agitation] gauge now " .. string.format("%.2f", self:getApparentThickness(sourceEntry) * 100) .. "%")
    -- Update vegetation visibility for the matching placeable
    if SPSCrustVegetation ~= nil then
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.sourceEntry == sourceEntry then
                SPSCrustVegetation.updateVisibility(pEntry)
                break
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Transfer functions (existing)
-- ---------------------------------------------------------------------------

-- Returns the fillType currently held by a sourceEntry, or nil if empty.
-- For vehicle fill units → reads the vehicle's runtime fill type.
-- For storage planes → walks the storage's fillType list and returns the
-- first type with level > 0 (multi-type storages are rare; in practice
-- one type at a time).
function SlurryPipeManager:_resolveSourceFillType(srcEntry)
    if srcEntry == nil then return nil end
    if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or srcEntry.type == "FILL_UNIT_ONLY" then
        if srcEntry.vehicle == nil then return nil end
        local ft = srcEntry.vehicle:getFillUnitFillType(srcEntry.fillUnitIndex)
        if ft == nil or ft == FillType.UNKNOWN then return nil end
        local level = srcEntry.vehicle:getFillUnitFillLevel(srcEntry.fillUnitIndex) or 0
        if level <= 0 then return nil end
        return ft
    elseif srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if srcEntry.storage == nil or srcEntry.storage.fillTypes == nil then return nil end
        for ft, _ in pairs(srcEntry.storage.fillTypes) do
            local lvl = srcEntry.storage:getFillLevel(ft) or 0
            if lvl > 0 then return ft end
        end
        return nil
    end
    return nil
end

-- Returns true if the destination entry can accept the given fillType right now
-- (has free capacity for that specific type).
function SlurryPipeManager:_destAcceptsFillType(dstEntry, fillType)
    if dstEntry == nil or fillType == nil then return false end
    if dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or dstEntry.type == "FILL_UNIT_ONLY" then
        if dstEntry.vehicle == nil then return false end
        if dstEntry.vehicle.getFillUnitAllowsFillType ~= nil then
            if not dstEntry.vehicle:getFillUnitAllowsFillType(dstEntry.fillUnitIndex, fillType) then return false end
        end
        local cap   = dstEntry.vehicle:getFillUnitCapacity(dstEntry.fillUnitIndex) or 0
        local level = dstEntry.vehicle:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0
        return (cap - level) > 0
    elseif dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if dstEntry.storage == nil then return false end
        local free = dstEntry.storage:getFreeCapacity(fillType) or 0
        return free > 0
    end
    return false
end

function SlurryPipeManager:transferFill(vehicle, session, delta, fillType)
    local extSource = self:resolveExternalSource(vehicle)
    if extSource == nil then return end
    
    -- Force fillType to WATER when filling from water source
    if extSource.type == 3 then
        fillType = FillType.WATER
    end

    local sourceLevel = 0
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extSource.type == "FILL_UNIT_ONLY" then
        if extSource.vehicle ~= nil then
            sourceLevel = extSource.vehicle:getFillUnitFillLevel(extSource.fillUnitIndex) or 0
        end
    elseif extSource.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if extSource.storage ~= nil then
            sourceLevel = extSource.storage:getFillLevel(fillType) or 0
        end
    elseif extSource.type == 3 then  -- Water source (infinite)
        sourceLevel = 999999  -- Infinite water source
    end

    if sourceLevel <= 0 then return end

    delta = math.min(delta, sourceLevel)

    local applied = vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), session.vehicleFillUnit, delta, fillType, ToolType.TRIGGER, nil)
    if applied <= 0 then return end
    self:removeFromSource(extSource, applied, fillType, vehicle)
end

function SlurryPipeManager:transferDischarge(vehicle, session, delta, fillType)
    local extDest = self:resolveExternalSource(vehicle)
    if extDest == nil then return end

    local freeCapacity = 0
    if extDest.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extDest.type == "FILL_UNIT_ONLY" then
        if extDest.vehicle ~= nil then
            local cap   = extDest.vehicle:getFillUnitCapacity(extDest.fillUnitIndex) or 0
            local level = extDest.vehicle:getFillUnitFillLevel(extDest.fillUnitIndex) or 0
            freeCapacity = cap - level
        end
    elseif extDest.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if extDest.storage ~= nil then
            freeCapacity = extDest.storage:getFreeCapacity(self:resolveStoreDepositFillType(extDest, fillType)) or 0
        end
    elseif extDest.type == 3 then  -- Water source (infinite capacity)
        freeCapacity = 999999  -- Infinite capacity
    end

    if freeCapacity <= 0 then return end

    delta = math.min(delta, freeCapacity)

    local applied = vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), session.vehicleFillUnit, -delta, fillType, ToolType.TRIGGER, nil)
    if applied >= 0 then return end
    self:addToSource(extDest, math.abs(applied), fillType, vehicle)
end

-- ---------------------------------------------------------------------------
-- Source resolution
-- ---------------------------------------------------------------------------
function SlurryPipeManager:resolveVehicleSource(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            if entry.sourceEntry == nil then
                local fillUnitIndex = 1
                if #entry.armEntries > 0 then
                    fillUnitIndex = entry.armEntries[1].fillUnitIndex
                end

                local sourceEntry = nil

                if vehicle.spec_fillVolume ~= nil then
                    sourceEntry = SlurryNodeUtil.buildFillVolumeSource(vehicle, fillUnitIndex)
                end

                if sourceEntry == nil and vehicle.spec_fillUnit ~= nil and vehicle.addFillUnitFillLevel ~= nil then
                    local fillUnit = vehicle.spec_fillUnit.fillUnits ~= nil and vehicle.spec_fillUnit.fillUnits[fillUnitIndex] or nil
                    if fillUnit ~= nil then
                        sourceEntry = {
                            type          = "FILL_UNIT_ONLY",
                            vehicle       = vehicle,
                            fillUnitIndex = fillUnitIndex,
                        }
--                        print("[SPS] resolveVehicleSource FALLBACK FILL_UNIT_ONLY: " .. tostring(vehicle.configFileName))
                    end
                end

                if sourceEntry ~= nil then
                    entry.sourceEntry = sourceEntry
                    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
                        table.insert(self.sourceEntries, sourceEntry)
                    end
                else
                    if not entry.sourceResolvePrinted then
                        print("[SPS] resolveVehicleSource deferred: " .. tostring(vehicle.configFileName))
                        entry.sourceResolvePrinted = true
                    end
                end
            end
            return entry.sourceEntry
        end
    end
    return nil
end

function SlurryPipeManager:resolveExternalSource(vehicle)
    local entry = nil
    for _, e in ipairs(self.registeredVehicles) do if e.vehicle == vehicle then entry = e break end end
    if entry == nil then return nil end

    -- Fill arm path
    for _, arm in ipairs(entry.armEntries) do
        if arm.isConnected then
            if arm.connectedBootPort ~= nil then
                if arm.connectedBootPort.isChain and arm.connectedBootPort.chain ~= nil then
                    local src = arm.connectedBootPort.chain.anchorCoupling.sourceEntry
                    if src ~= nil then return src end
                else
                    return self:resolveVehicleSource(arm.connectedBootPort.vehicle)
                end
            end
            if arm.connectedSource ~= nil then return arm.connectedSource end
        end
    end

    -- Coupling path (pipe connected and valve open)
    for _, coupling in ipairs(entry.couplingEntries) do
        if coupling.isConnected and coupling.valveOpen then
            local partner = coupling.connectedPartnerCoupling
            if partner ~= nil and partner.isChainTerminus then
                if partner.isChainStart then
                    -- Vehicle-anchored chain: the near-end sourceEntry is the vehicle's own fill
                    -- volume — wrong for external source resolution. Traverse to the far end of
                    -- the chain and return whatever the last chainCoupling is connected to.
                    local chain = partner.chain
                    if chain ~= nil and #chain.segments > 0 then
                        local farCoupling = chain.segments[#chain.segments].chainCoupling
                        if farCoupling ~= nil then
                            -- Check if far end is connected to something
                            if farCoupling.connectedPartnerCoupling ~= nil then
                                local farPartner = farCoupling.connectedPartnerCoupling
                                for _, pEntry in ipairs(self.registeredPlaceables) do
                                    if pEntry.storeCouplings ~= nil then
                                        for _, sc in ipairs(pEntry.storeCouplings) do
                                            if sc == farPartner then return pEntry.sourceEntry end
                                        end
                                    end
                                end
                                for _, vEntry in ipairs(self.registeredVehicles) do
                                    for _, vc in ipairs(vEntry.couplingEntries) do
                                        if vc == farPartner then
                                            return self:resolveVehicleSource(vEntry.vehicle)
                                        end
                                    end
                                end
                            else
                                -- Far end not connected to anything - check if it's in water
                                if farCoupling.mountNode ~= nil and entityExists(farCoupling.mountNode) then
                                    local fx, fy, fz = getWorldTranslation(farCoupling.mountNode)
                                    if g_waterPlaneManager ~= nil then
                                        local waterPlane = g_waterPlaneManager:findWaterPlaneAtPosition(fx, fz)
                                        if waterPlane ~= nil then
                                            return {
                                                type = 3,
                                                storage = waterPlane,
                                                waterPlane = waterPlane
                                            }
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                if partner.sourceEntry ~= nil then return partner.sourceEntry end
            end
            if coupling.connectedTarget ~= nil then
                local target = coupling.connectedTarget
                for _, pEntry in ipairs(self.registeredPlaceables) do
                    if pEntry.placeable == target then return pEntry.sourceEntry end
                end
                for _, vEntry in ipairs(self.registeredVehicles) do
                    if vEntry.vehicle == target then return self:resolveVehicleSource(vEntry.vehicle) end
                end
            end
        end
    end
    
    -- Check strap pipe free end for water (before declaring no source found)
    for _, coupling in ipairs(entry.couplingEntries) do
        if coupling.pipeId ~= nil and coupling.valveOpen then
            local pipeData = self.activePipes[coupling.pipeId]
            if pipeData ~= nil then
                -- Determine which end is the free end
                local freeEndCoupling = nil
                
                -- Check if coupling A is from this vehicle
                local aIsThisVehicle = false
                for _, vEntry in ipairs(self.registeredVehicles) do
                    if vEntry.vehicle == vehicle then
                        for _, vc in ipairs(vEntry.couplingEntries) do
                            if vc == pipeData.couplingA then
                                aIsThisVehicle = true
                                break
                            end
                        end
                        break
                    end
                end
                
                -- If A is this vehicle's coupling, then B is the free end
                if aIsThisVehicle then
                    freeEndCoupling = pipeData.couplingB
                else
                    freeEndCoupling = pipeData.couplingA
                end
                
                -- Check if free end is in water
                if freeEndCoupling ~= nil then
                    if freeEndCoupling.mountNode ~= nil and entityExists(freeEndCoupling.mountNode) then
                        local fx, fy, fz = getWorldTranslation(freeEndCoupling.mountNode)
                        
                        if g_waterPlaneManager ~= nil then
                            local waterPlane = g_waterPlaneManager:findWaterPlaneAtPosition(fx, fz)
                            if waterPlane ~= nil then
                                return {
                                    type = 3,
                                    storage = waterPlane,
                                    waterPlane = waterPlane
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- No source found - this is normal when pump runs without valid connection
    return nil
end

function SlurryPipeManager:removeFromSource(sourceEntry, amount, fillType, farmVehicle)
    if sourceEntry == nil then return end
    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or sourceEntry.type == "FILL_UNIT_ONLY" then
        local srcVehicle = sourceEntry.vehicle
        if srcVehicle ~= nil and srcVehicle.addFillUnitFillLevel ~= nil then
            local fui    = sourceEntry.fillUnitIndex
            local applied = srcVehicle:addFillUnitFillLevel(srcVehicle:getOwnerFarmId(), fui, -amount, fillType, ToolType.TRIGGER, nil)

            -- BYPASS PATH (mirrors addToSource): vanilla returned 0 but the unit
            -- actually has the requested fillType at a level we can draw from. The
            -- shadowed getFillUnitSupportsToolType blocks both add and remove. Fall
            -- back to direct mutation when the vanilla path silently fails.
            if amount > 0 and (applied == nil or applied == 0)
            and srcVehicle.spec_fillUnit ~= nil
            and srcVehicle.spec_fillUnit.fillUnits ~= nil then
                local spec = srcVehicle.spec_fillUnit
                local fu   = spec.fillUnits[fui]
                if fu ~= nil and (fu.fillLevel or 0) > 0 and fu.fillType == fillType then
                    local oldFillLevel = fu.fillLevel
                    fu.fillLevel = math.max(0, oldFillLevel - amount)
                    local delta = fu.fillLevel - oldFillLevel  -- negative
                    if fu.fillLevel <= 0 then
                        -- Unit emptied: clear fillType per vanilla convention (line 1218-1228)
                        if SpecializationUtil ~= nil and SpecializationUtil.raiseEvent ~= nil then
                            SpecializationUtil.raiseEvent(srcVehicle, "onChangedFillType", fui, FillType.UNKNOWN, fu.fillType)
                        end
                        fu.fillType = FillType.UNKNOWN
                        -- Same root-vehicle state change as the fill side, so cab specs refresh
                        if srcVehicle.rootVehicle ~= nil and srcVehicle.rootVehicle.raiseStateChange ~= nil
                        and VehicleStateChange ~= nil and VehicleStateChange.FILLTYPE_CHANGE ~= nil then
                            srcVehicle.rootVehicle:raiseStateChange(VehicleStateChange.FILLTYPE_CHANGE)
                        end
                    end
                    spec.isInfoDirty = true
                    if srcVehicle.isServer and spec.dirtyFlag ~= nil and srcVehicle.raiseDirtyFlags ~= nil then
                        srcVehicle:raiseDirtyFlags(spec.dirtyFlag)
                    end
                    if SpecializationUtil ~= nil and SpecializationUtil.raiseEvent ~= nil then
                        SpecializationUtil.raiseEvent(srcVehicle, "onFillUnitFillLevelChanged",
                            fui, -amount, fillType, ToolType.TRIGGER, nil, delta)
                    end
                    if not srcVehicle._spsBypassRemoveLogged then
                        srcVehicle._spsBypassRemoveLogged = true
                        print(string.format(
                            "[SPS SPR] removeFromSource: vanilla gate bypassed for fui=%s, fillType=%s, delta=%s (one-time)",
                            tostring(fui), tostring(fillType), tostring(delta)))
                    end
                end
            end
        end
    elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        local storage = sourceEntry.storage
        if storage ~= nil then
            local oldLevel = storage:getFillLevel(fillType) or 0
            local removed  = math.min(amount, oldLevel)
            -- Preferential-liquid draw: when pumping slurry out, more of what leaves is
            -- liquid than its plain share, so the dry matter left behind concentrates.
            -- As liquid runs low the draw is forced to be solids and DM races up, until
            -- the store jams (>=90% gauge) and the only fix is adding water.
            if sourceEntry.thickeningEnabled and removed > 0 and fillType ~= FillType.WATER then
                self:_ensureStorePools(sourceEntry)
                local total  = self:_getStoreTotalFill(sourceEntry)   -- slurry+digestate pile
                local solids = sourceEntry.solids or 0
                local liquid = math.max(0, total - solids)
                local dm     = total > 0 and (solids / total) or 0
                local liquidOut = math.min(removed * (1 - dm) * SlurryPipeManager.DM_REMOVAL_LIQUID_BIAS,
                                           liquid, removed)
                local solidsOut = math.min(removed - liquidOut, solids)
                sourceEntry.solids = math.max(0, solids - solidsOut)
            end
            storage:setFillLevel(math.max(0, oldLevel - removed), fillType)
            if sourceEntry.thickeningEnabled then
                sourceEntry._lastTotal = self:_getStoreTotalFill(sourceEntry)
            end
        end
    elseif sourceEntry.type == 3 then  -- Water source (infinite)
        -- Water planes have infinite capacity, no removal needed
        -- Visual/sound effects could be added here
    end
end

function SlurryPipeManager:addToSource(sourceEntry, amount, fillType, farmVehicle)
    if sourceEntry == nil then return end
    
    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or sourceEntry.type == "FILL_UNIT_ONLY" then
        local destVehicle = sourceEntry.vehicle
        if destVehicle ~= nil and destVehicle.addFillUnitFillLevel ~= nil then
            local farmId = destVehicle:getOwnerFarmId()
            local fui    = sourceEntry.fillUnitIndex

            -- Lazy inject ToolType.TRIGGER into the fillUnit's supportedToolTypes,
            -- with verbose first-call-per-vehicle diagnostics to see exactly which gate
            -- (if any) silently fails. Flag prevents log spam after first attempt.
            if not destVehicle._spsTriggerInjectAttempted then
                destVehicle._spsTriggerInjectAttempted = true
                local hasTT      = ToolType ~= nil
                local hasTTTrig  = hasTT and ToolType.TRIGGER ~= nil
                local hasSpec    = destVehicle.spec_fillUnit ~= nil
                local hasFUList  = hasSpec and destVehicle.spec_fillUnit.fillUnits ~= nil
                local fu         = hasFUList and destVehicle.spec_fillUnit.fillUnits[fui] or nil
                local hasSTT     = fu ~= nil and fu.supportedToolTypes ~= nil
                local sttBefore  = hasSTT and fu.supportedToolTypes[hasTTTrig and ToolType.TRIGGER or 0] or nil
                print(string.format(
                    "[SPS SPR INJECT] fui=%s ToolType=%s ToolType.TRIGGER=%s spec_fillUnit=%s fillUnits=%s fu=%s supportedToolTypes=%s before=%s",
                    tostring(fui), tostring(hasTT), tostring(hasTTTrig),
                    tostring(hasSpec), tostring(hasFUList), tostring(fu ~= nil),
                    tostring(hasSTT), tostring(sttBefore)))
                if hasTTTrig and hasSTT then
                    fu.supportedToolTypes[ToolType.TRIGGER] = true
                    local sttAfter      = fu.supportedToolTypes[ToolType.TRIGGER]
                    local getterTool    = destVehicle:getFillUnitSupportsToolType(fui, ToolType.TRIGGER)
                    local getterFill    = destVehicle:getFillUnitSupportsFillType(fui, fillType)
                    local getterCombo   = destVehicle:getFillUnitSupportsToolTypeAndFillType(fui, ToolType.TRIGGER, fillType)
                    print(string.format(
                        "[SPS SPR INJECT] set complete after=%s getter(tool)=%s getter(fill)=%s combo=%s",
                        tostring(sttAfter), tostring(getterTool), tostring(getterFill), tostring(getterCombo)))
                    -- Dump function refs to detect overwrites
                    print(string.format(
                        "[SPS SPR INJECT] fn refs: supportsToolType=%s vanilla=%s combo=%s",
                        tostring(destVehicle.getFillUnitSupportsToolType),
                        tostring(FillUnit and FillUnit.getFillUnitSupportsToolType),
                        tostring(destVehicle.getFillUnitSupportsToolTypeAndFillType)))
                    -- Dump every toolType key present in the table
                    local keys = {}
                    for k, v in pairs(fu.supportedToolTypes) do
                        keys[#keys + 1] = tostring(k) .. "=" .. tostring(v)
                    end
                    print("[SPS SPR INJECT] supportedToolTypes contents: { " .. table.concat(keys, ", ") .. " }")
                    -- Dump all ToolType constants we can see
                    if ToolType ~= nil then
                        local tt = {}
                        for k, v in pairs(ToolType) do
                            if type(v) == "number" then
                                tt[#tt + 1] = tostring(k) .. "=" .. tostring(v)
                            end
                        end
                        print("[SPS SPR INJECT] ToolType constants: { " .. table.concat(tt, ", ") .. " }")
                    end
                else
                    print("[SPS SPR INJECT] could not inject — gate failure")
                end
            end

            local applied = destVehicle:addFillUnitFillLevel(farmId, fui, amount, fillType, ToolType.TRIGGER, nil)

            -- BYPASS PATH: vanilla returned 0 but the fillUnit is legitimately fillable
            -- (allowsFillType=true, freeCapacity>0). A spec override in the vehicle's
            -- type chain is shadowing getFillUnitSupportsToolType and returning false
            -- despite supportedToolTypes containing all tool types. Replicate what
            -- vanilla addFillUnitFillLevel does AFTER its gate. Only fires when the
            -- vanilla call genuinely failed, so unaffected for slurry tankers / cobra.
            if amount > 0 and (applied == nil or applied == 0)
            and destVehicle:getFillUnitAllowsFillType(fui, fillType)
            and destVehicle.spec_fillUnit ~= nil
            and destVehicle.spec_fillUnit.fillUnits ~= nil then
                local spec = destVehicle.spec_fillUnit
                local fu   = spec.fillUnits[fui]
                if fu ~= nil then
                    local oldFillLevel = fu.fillLevel or 0
                    local capacity     = (fu.capacity ~= nil and fu.capacity > 0) and fu.capacity or math.huge
                    local fillTypeChanged = false
                    -- Change fillType if differs and unit is empty (mirrors vanilla line 1193-1213)
                    if fu.fillType ~= fillType and oldFillLevel <= 0 then
                        fu.fillType = fillType
                        fillTypeChanged = true
                    end
                    fu.fillLevel = math.max(0, math.min(capacity, oldFillLevel + amount))
                    if fu.fillLevel > 0 then
                        fu.lastValidFillType = fu.fillType
                    end
                    applied = fu.fillLevel - oldFillLevel
                    spec.isInfoDirty = true
                    -- Mark dirty for multiplayer sync
                    if destVehicle.isServer and spec.dirtyFlag ~= nil and destVehicle.raiseDirtyFlags ~= nil then
                        destVehicle:raiseDirtyFlags(spec.dirtyFlag)
                    end
                    -- On fillType change: raise FILLTYPE_CHANGE state on root vehicle (vanilla
                    -- line 1209) and per-spec onChangedFillType (line 1210). Without these,
                    -- downstream specs (e.g. TurnOnVehicle, Sprayer) don't refresh their cab
                    -- action events, so vanilla 'Turn on sprayer' (B) stays hidden after fill.
                    if fillTypeChanged then
                        if destVehicle.rootVehicle ~= nil and destVehicle.rootVehicle.raiseStateChange ~= nil
                        and VehicleStateChange ~= nil and VehicleStateChange.FILLTYPE_CHANGE ~= nil then
                            destVehicle.rootVehicle:raiseStateChange(VehicleStateChange.FILLTYPE_CHANGE)
                        end
                        if SpecializationUtil ~= nil and SpecializationUtil.raiseEvent ~= nil then
                            SpecializationUtil.raiseEvent(destVehicle, "onChangedFillType",
                                fui, fillType, FillType.UNKNOWN)
                        end
                    end
                    -- Raise the standard fill change event so UI/sound/dashboards update
                    if SpecializationUtil ~= nil and SpecializationUtil.raiseEvent ~= nil then
                        SpecializationUtil.raiseEvent(destVehicle, "onFillUnitFillLevelChanged",
                            fui, amount, fillType, ToolType.TRIGGER, nil, applied)
                    end
                    if not destVehicle._spsBypassLogged then
                        destVehicle._spsBypassLogged = true
                        print(string.format(
                            "[SPS SPR] addToSource: vanilla gate bypassed for fui=%s, fillType=%s, applied=%s (one-time)",
                            tostring(fui), tostring(fillType), tostring(applied)))
                    end
                end
            end
            -- DIAGNOSTIC: fire once per second per vehicle if applied=0 despite a positive request
            if amount > 0 and (applied == nil or applied == 0) then
                local nowMs = g_time or 0
                destVehicle._spsDiagLastMs = destVehicle._spsDiagLastMs or 0
                if nowMs - destVehicle._spsDiagLastMs >= 1000 then
                    destVehicle._spsDiagLastMs = nowMs
                    local spec       = destVehicle.spec_fillUnit
                    local fu         = spec and spec.fillUnits and spec.fillUnits[fui] or nil
                    local sToolTrig  = destVehicle:getFillUnitSupportsToolType(fui, ToolType.TRIGGER)
                    local sFillType  = destVehicle:getFillUnitSupportsFillType(fui, fillType)
                    local allowFT    = destVehicle:getFillUnitAllowsFillType(fui, fillType)
                    print(string.format(
                        "[SPS SPR DIAG] addToSource: applied=%s farmId=%s fui=%s fillType=%s ToolType.TRIGGER=%s isServer=%s",
                        tostring(applied), tostring(farmId), tostring(fui), tostring(fillType),
                        tostring(ToolType.TRIGGER), tostring(destVehicle.isServer)))
                    print(string.format(
                        "[SPS SPR DIAG]   supportsToolType(TRIGGER)=%s supportsFillType=%s allowsFillType=%s",
                        tostring(sToolTrig), tostring(sFillType), tostring(allowFT)))
                    print(string.format(
                        "[SPS SPR DIAG]   fillUnit.fillType=%s fillUnit.fillLevel=%s fillUnit.capacity=%s ignoreFillLimit=%s",
                        tostring(fu and fu.fillType),
                        tostring(fu and fu.fillLevel),
                        tostring(fu and fu.capacity),
                        tostring(fu and fu.ignoreFillLimit)))
                    print(string.format(
                        "[SPS SPR DIAG]   trailerFillLimit=%s",
                        tostring(g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.trailerFillLimit)))
                end
            end
        end
    elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        local storage = sourceEntry.storage
        if storage ~= nil then
            -- Convert an unsupported incoming type (e.g. WATER) to the store's native
            -- slurry/digestate type as it enters.
            local depositFillType = self:resolveStoreDepositFillType(sourceEntry, fillType)
            local free  = storage:getFreeCapacity(depositFillType) or 0
            local toAdd = math.min(amount, free)
            if toAdd > 0 then
                -- Re-blend the store's dry matter: slurry/digestate adds solids at the
                -- tanker's carried DM; water adds volume but no dry matter, so it dilutes
                -- the store (the only lever that lowers DM).
                if sourceEntry.thickeningEnabled then
                    self:_ensureStorePools(sourceEntry)
                    local solidsIn = 0
                    if fillType ~= FillType.WATER and farmVehicle ~= nil then
                        solidsIn = toAdd * self:gaugeToDM(self:getTankerThickness(farmVehicle))
                    end
                    sourceEntry.solids = (sourceEntry.solids or 0) + solidsIn
                end
                storage:setFillLevel((storage:getFillLevel(depositFillType) or 0) + toAdd, depositFillType)
                if sourceEntry.thickeningEnabled then
                    sourceEntry._lastTotal = self:_getStoreTotalFill(sourceEntry)
                end
            end
        end
    elseif sourceEntry.type == 3 then  -- Water source (infinite capacity)
        -- Water returns to water plane (infinite capacity, no action needed)
    end
end

-- ===========================================================================
-- SPRAYER SYSTEM
-- Handles herbicide / fertiliser transfer via bez pipe only.
-- Completely separate from slurry registration, flow, and pipe visual tables.
-- All methods prefixed with "Sprayer" to avoid any collision with slurry code.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Sprayer config loading
-- ---------------------------------------------------------------------------
function SlurryPipeManager:loadSprayerVehicleConfigs(modDirectory)
    local configRoot   = modDirectory .. "configs/"
    local manifestPath = modDirectory .. "configs/spsConfigManifest.xml"
    local xmlFile = XMLFile.load("spsManifest", manifestPath)
    if xmlFile == nil then
        print("[SPS SPR] loadSprayerVehicleConfigs: could not load manifest: " .. manifestPath)
        return
    end
    local idx = 0
    while true do
        local key = string.format("spsConfigManifest.sprayerVehicleConfigs.vehicle(%d)", idx)
        if not xmlFile:hasProperty(key) then break end
        local matchPath = xmlFile:getString(key .. "#path")
        if matchPath ~= nil and matchPath ~= "" then
            local cfgDir = xmlFile:getString(key .. "#configFolder")
            if cfgDir == nil or cfgDir == "" then
                cfgDir = matchPath:match("^(.*)/[^/]+%.xml$")
            end
            if cfgDir == nil then
                print("[SPS SPR] loadSprayerVehicleConfigs: malformed path '" .. matchPath .. "'")
            else
                local xmlFilePath = configRoot .. cfgDir .. "/fillPoints.xml"
                if fileExists(xmlFilePath) then
                    self.sprayerVehicleConfigMap[matchPath:lower()] = {
                        xmlFilePath = xmlFilePath,
                        matchPath   = matchPath,
                    }
                    print("[SPS SPR] loadSprayerVehicleConfigs: registered '" .. matchPath .. "' -> " .. xmlFilePath)
                else
                    print("[SPS SPR] loadSprayerVehicleConfigs: no fillPoints.xml at " .. xmlFilePath)
                end
            end
        end
        idx = idx + 1
    end
    xmlFile:delete()
    local count = 0
    for _ in pairs(self.sprayerVehicleConfigMap) do count = count + 1 end
    print("[SPS SPR] loadSprayerVehicleConfigs: loaded " .. tostring(count) .. " sprayer vehicle configs")
end

function SlurryPipeManager:loadSprayerPlaceableConfigs(modDirectory)
    local configRoot   = modDirectory .. "configs/"
    local manifestPath = modDirectory .. "configs/spsConfigManifest.xml"
    local xmlFile = XMLFile.load("spsManifest", manifestPath)
    if xmlFile == nil then
        print("[SPS SPR] loadSprayerPlaceableConfigs: could not load manifest: " .. manifestPath)
        return
    end
    local idx = 0
    while true do
        local key = string.format("spsConfigManifest.sprayerPlaceableConfigs.placeable(%d)", idx)
        if not xmlFile:hasProperty(key) then break end
        local matchPath = xmlFile:getString(key .. "#path")
        if matchPath ~= nil and matchPath ~= "" then
            local cfgDir = xmlFile:getString(key .. "#configFolder")
            if cfgDir == nil or cfgDir == "" then
                cfgDir = matchPath:match("^(.*)/[^/]+%.xml$")
            end
            if cfgDir == nil then
                print("[SPS SPR] loadSprayerPlaceableConfigs: malformed path '" .. matchPath .. "'")
            else
                local xmlFilePath = configRoot .. cfgDir .. "/fillPoints.xml"
                if fileExists(xmlFilePath) then
                    self.sprayerPlaceableConfigMap[matchPath:lower()] = {
                        xmlFilePath = xmlFilePath,
                        matchPath   = matchPath,
                    }
                    print("[SPS SPR] loadSprayerPlaceableConfigs: registered '" .. matchPath .. "' -> " .. xmlFilePath)
                else
                    print("[SPS SPR] loadSprayerPlaceableConfigs: no fillPoints.xml at " .. xmlFilePath)
                end
            end
        end
        idx = idx + 1
    end
    xmlFile:delete()
    local count = 0
    for _ in pairs(self.sprayerPlaceableConfigMap) do count = count + 1 end
    print("[SPS SPR] loadSprayerPlaceableConfigs: loaded " .. tostring(count) .. " sprayer placeable configs")
end

-- ---------------------------------------------------------------------------
-- Sprayer config lookup
-- ---------------------------------------------------------------------------
function SlurryPipeManager:findSprayerVehicleConfigForVehicle(vehicle)
    if vehicle.configFileName == nil then return nil end

    -- Embedded config check: a vehicle whose own XML carries a <sprayerPipeSystem>
    -- element is self-contained and overrides any internal manifest match. This is
    -- what lets third-party modders ship SPS-ready sprayers that include their own
    -- couplers, animations and node references without ever touching the SPS mod
    -- folder. Mirrors findVehicleConfigForVehicle (slurry) exactly.
    if vehicle.xmlFile ~= nil and vehicle.xmlFile:hasProperty("vehicle.sprayerPipeSystem") then
        SlurryDebug.log("findSprayerVehicleConfigForVehicle: embedded <sprayerPipeSystem> found in " .. tostring(vehicle.configFileName))
        return {
            xmlFilePath  = vehicle.configFileName,    -- used for nodeTree path resolution
            xmlKeyPrefix = "vehicle.",                -- prepended ahead of "sprayerPipeSystem..."
            isEmbedded   = true,
        }
    end

    local cfn = vehicle.configFileName:lower():gsub("\\", "/")
    for matchPathLower, config in pairs(self.sprayerVehicleConfigMap) do
        if cfn:sub(-#matchPathLower) == matchPathLower then
            return config
        end
    end
    return nil
end

function SlurryPipeManager:findSprayerPlaceableConfigForPlaceable(placeable)
    if placeable.configFileName == nil then return nil end

    -- Embedded config check: a placeable whose own XML carries a <sprayerPipeSystem>
    -- element is self-contained. See findSprayerVehicleConfigForVehicle for rationale.
    if placeable.xmlFile ~= nil and placeable.xmlFile:hasProperty("placeable.sprayerPipeSystem") then
        SlurryDebug.log("findSprayerPlaceableConfigForPlaceable: embedded <sprayerPipeSystem> found in " .. tostring(placeable.configFileName))
        return {
            xmlFilePath  = placeable.configFileName,
            xmlKeyPrefix = "placeable.",
            isEmbedded   = true,
        }
    end

    local cfn = placeable.configFileName:lower():gsub("\\", "/")
    for matchPathLower, config in pairs(self.sprayerPlaceableConfigMap) do
        if cfn:sub(-#matchPathLower) == matchPathLower then
            return config
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Sprayer registration — vehicle
-- ---------------------------------------------------------------------------
function SlurryPipeManager:registerSprayerVehicle(vehicle)
    for _, entry in ipairs(self.registeredSprayerVehicles) do
        if entry.object == vehicle then return end
    end

    local config = self:findSprayerVehicleConfigForVehicle(vehicle)
    if config == nil then
        print("[SPS SPR] registerSprayerVehicle: no config for " .. tostring(vehicle.configFileName))
        return
    end

    -- Embedded configs use the vehicle's own xmlFile (already loaded by Giants, not
    -- owned by us); bundled configs open the SPS-internal fillPoints.xml. Mirrors
    -- registerVehicle (slurry).
    local xmlFile
    local xmlFileOwned = false
    if config.isEmbedded then
        xmlFile = vehicle.xmlFile
    else
        xmlFile = XMLFile.load("spsSprayerVehiclePoints", config.xmlFilePath)
        xmlFileOwned = true
    end
    if xmlFile == nil then
        print("[SPS SPR] registerSprayerVehicle: XML load failed: " .. tostring(config.xmlFilePath))
        return
    end

    local kp = (config.xmlKeyPrefix or "") .. "sprayerPipeSystem."

    local entry = {
        object           = vehicle,
        isVehicle        = true,
        linkedNodes      = {},
        couplings        = {},
        pumpControls     = {},
        pipeActivatables = {},
        litersPerSecond  = xmlFile:getFloat(kp .. "flow#litersPerSecond", 200),
        nodeTreeRoot     = nil,
        state = {
            pumpRunning   = false,
            valveOpen     = false,
            direction     = SPS_SPRAYER_DIRECTION_FILL,
            loadAnimName  = xmlFile:getString(kp .. "loadAnimation#name"),  -- optional vehicle animation
            coupling      = nil,  -- reference to first coupling (set after loading)
        },
    }

    -- Load nodeTree — same link pattern as slurry registerVehicle
    local nodeTreePath = xmlFile:getString(kp .. "nodeTree#filename")
    if nodeTreePath ~= nil then
        local configFolder = config.xmlFilePath:match("^(.*[/\\])")
        local fullPath     = configFolder .. nodeTreePath
        local nodeTreeRoot = loadI3DFile(fullPath)
        if nodeTreeRoot ~= nil and nodeTreeRoot ~= 0 then
            entry.nodeTreeRoot = nodeTreeRoot
            local function findByName(root, name)
                if getName(root) == name then return root end
                for i = 0, getNumOfChildren(root) - 1 do
                    local found = findByName(getChildAt(root, i), name)
                    if found ~= nil then return found end
                end
                return nil
            end
            local spsRoot = getChildAt(nodeTreeRoot, 0)
            if spsRoot ~= nil and spsRoot ~= 0 then
                for groupIdx = 0, getNumOfChildren(spsRoot) - 1 do
                    local group = getChildAt(spsRoot, groupIdx)
                    for containerIdx = 0, getNumOfChildren(group) - 1 do
                        local container  = getChildAt(group, containerIdx)
                        local targetName = getName(container)
                        local liveParent = findByName(vehicle.rootNode, targetName)
                        if liveParent ~= nil then
                            local children = {}
                            for childIdx = 0, getNumOfChildren(container) - 1 do
                                table.insert(children, getChildAt(container, childIdx))
                            end
                            for _, spsNode in ipairs(children) do
                                removeFromPhysics(spsNode)
                                link(liveParent, spsNode)
                                addToPhysics(spsNode)
                                table.insert(entry.linkedNodes, spsNode)
                            end
                        else
--                            print("[SPS SPR] registerSprayerVehicle: container target '" .. targetName .. "' not found in vehicle")
                        end
                    end
                end
            end
        else
            print("[SPS SPR] registerSprayerVehicle: failed to load nodeTree: " .. tostring(fullPath))
        end
    end

    local function findLinkedNode(name)
        if name == nil or name == "" then return nil end
        for _, n in ipairs(entry.linkedNodes) do
            if getName(n) == name then return n end
        end
        local function searchTree(root, targetName)
            if getName(root) == targetName then return root end
            for i = 0, getNumOfChildren(root) - 1 do
                local found = searchTree(getChildAt(root, i), targetName)
                if found ~= nil then return found end
            end
            return nil
        end
        return searchTree(vehicle.rootNode, name)
    end

    -- Inject SPS nodeTree nodes into vehicle.i3dMappings so loadSampleFromXML
    -- can resolve linkNode names (e.g. exhaustNode) that are not in the vehicle's
    -- own i3d but have been linked in from the SPS nodeTree.
    if vehicle.i3dMappings ~= nil then
        local linkNodeName = xmlFile:getString(kp .. "sounds.engineLoop#linkNode")
        if linkNodeName ~= nil then
            local foundNode = findLinkedNode(linkNodeName)
            if foundNode ~= nil then
                -- I3DUtil.indexToObject requires the mapping value to be a table
                -- { nodeId, rootNode } — a bare integer is treated as a child-index
                -- path and crashes ("Failed to find child N ... only N children").
                vehicle.i3dMappings[linkNodeName] = { nodeId = foundNode, rootNode = vehicle.rootNode }
                print("[SPS SPR] registerSprayerVehicle: injected '" .. linkNodeName .. "' into i3dMappings nodeId=" .. tostring(foundNode) .. " rootNode=" .. tostring(vehicle.rootNode))
            else
                print("[SPS SPR] registerSprayerVehicle: linkNode '" .. linkNodeName .. "' not found in vehicle hierarchy")
            end
        end
    end

    -- Load engine loop sound
    entry.engineLoopSample = nil
    if vehicle.isClient then
        local soundKey = kp .. "sounds.engineLoop"
        if xmlFile:hasProperty(soundKey) then
            entry.engineLoopSample = g_soundManager:loadSampleFromXML(
                xmlFile, kp .. "sounds", "engineLoop",
                vehicle.baseDirectory, vehicle.components, 0,
                AudioGroup.VEHICLE, vehicle.i3dMappings, vehicle)
            if entry.engineLoopSample ~= nil then
                print("[SPS SPR] registerSprayerVehicle: engine sound loaded")
            else
                print("[SPS SPR] registerSprayerVehicle: engine sound failed to load")
            end
        end
    end

    -- Load vehicle-level load animation (e.g. toggleCover), shared across all couplings
    local vehicleLoadAnimName = xmlFile:getString(kp .. "loadAnimation#name")
    print("[SPS SPR] registerSprayerVehicle: loadAnimationName=" .. tostring(vehicleLoadAnimName))

    -- Load sprayer pipe couplings
    local couplingIndex = 0
    while true do
        local cKey = string.format(kp .. "sprayerPipeCouplings.sprayerPipeCoupling(%d)", couplingIndex)
        if not xmlFile:hasProperty(cKey) then break end
        local couplingId = xmlFile:getInt(cKey .. "#id", couplingIndex + 1)
        local mountNode  = findLinkedNode(xmlFile:getString(cKey .. "#mountNodeName"))
        if mountNode ~= nil then
            local inNode, outNode
            local function findInOut(node)
                for i = 0, getNumOfChildren(node) - 1 do
                    local child = getChildAt(node, i)
                    local n = getName(child)
                    if n == "inNode" then inNode = child
                    elseif n == "outNode" then outNode = child
                    else findInOut(child) end
                end
            end
            findInOut(mountNode)
            local couplingEntry = {
                id                       = couplingId,
                mountNode                = mountNode,
                inNode                   = inNode,
                outNode                  = outNode,
                flowDirection            = xmlFile:getString(cKey .. "#flowDirection", "BOTH"),
                maxPipeLength            = xmlFile:getFloat(cKey .. "#maxPipeLength", 7.5),
                fillUnitIndex            = xmlFile:getInt(cKey .. "#fillUnitIndex", 1),
                connectorAnimationId     = xmlFile:getInt(cKey .. "#connectorAnimation"),
                valveAnimationId         = xmlFile:getInt(cKey .. "#valveAnimation"),
                loadAnimationName        = vehicleLoadAnimName,
                loadAnimPlayed           = false,
                isConnected              = false,
                valveOpen                = false,
                connectedTarget          = nil,
                connectedPartnerCoupling = nil,
                pipeId                   = nil,
                object                   = vehicle,
            }
            -- Bind coupler animations (connector + valve) if configured
            if SPSCouplerAnimator ~= nil
            and (couplingEntry.connectorAnimationId ~= nil or couplingEntry.valveAnimationId ~= nil) then
                SPSCouplerAnimator.ensureLoaded(g_currentMission.spsModDirectory)
                if couplingEntry.connectorAnimationId ~= nil then
                    couplingEntry.connectorAnim = SPSCouplerAnimator.bind(couplingEntry.mountNode, couplingEntry.connectorAnimationId)
                end
                if couplingEntry.valveAnimationId ~= nil then
                    couplingEntry.valveAnim = SPSCouplerAnimator.bind(couplingEntry.mountNode, couplingEntry.valveAnimationId)
                end
            end
            table.insert(entry.couplings, couplingEntry)
            -- Control node activatable handles connect/disconnect for vehicles with sprayerPumpControls.
            -- SPSSprayerPipeActivatable is not registered; control node is single interaction point.
            print("[SPS SPR] registerSprayerVehicle: coupling id=" .. tostring(couplingId) .. " registered, loadAnim=" .. tostring(couplingEntry.loadAnimationName))
        else
            print("[SPS SPR] registerSprayerVehicle: coupling id=" .. tostring(couplingId) .. " mountNode not found, skipping")
        end
        couplingIndex = couplingIndex + 1
    end

    -- Store reference to first coupling in state (for pump control access)
    if #entry.couplings > 0 then
        entry.state.coupling = entry.couplings[1]
    end

    -- Load sprayer pump controls
    local pcIndex = 0
    while true do
        local pcKey = string.format(kp .. "sprayerPumpControls.sprayerPumpControl(%d)", pcIndex)
        if not xmlFile:hasProperty(pcKey) then break end
        local pcId     = xmlFile:getInt(pcKey .. "#id", pcIndex + 1)
        local pcRadius = xmlFile:getFloat(pcKey .. "#radius", 1.5)
        local pcNode   = findLinkedNode(xmlFile:getString(pcKey .. "#nodeName"))
        if pcNode ~= nil then
            local pumpCtrl = SPSSprayerPumpControl.new(vehicle, pcNode, pcRadius)
            table.insert(entry.pumpControls, { id = pcId, node = pcNode, radius = pcRadius, activatable = pumpCtrl })
            g_currentMission.activatableObjectsSystem:addActivatable(pumpCtrl)
            print("[SPS SPR] registerSprayerVehicle: pumpControl id=" .. tostring(pcId) .. " registered")
        else
            print("[SPS SPR] registerSprayerVehicle: pumpControl id=" .. tostring(pcId) .. " node not found, skipping")
        end
        pcIndex = pcIndex + 1
    end

    if xmlFileOwned then xmlFile:delete() end
    table.insert(self.registeredSprayerVehicles, entry)
    
    -- Restore animation state from save if available
    self:_applyPendingSprayerAnimation(vehicle, entry)
    
    print("[SPS SPR] registerSprayerVehicle: registered " .. tostring(vehicle.configFileName))
end

-- ---------------------------------------------------------------------------
-- Sprayer registration — placeable
-- ---------------------------------------------------------------------------
function SlurryPipeManager:registerSprayerPlaceable(placeable)
    for _, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.object == placeable then return end
    end

    local config = self:findSprayerPlaceableConfigForPlaceable(placeable)
    if config == nil then
        print("[SPS SPR] registerSprayerPlaceable: no config for " .. tostring(placeable.configFileName))
        return
    end

    local xmlFile
    local xmlFileOwned = false
    if config.isEmbedded then
        xmlFile = placeable.xmlFile
    else
        xmlFile = XMLFile.load("spsSprayerPlaceablePoints", config.xmlFilePath)
        xmlFileOwned = true
    end
    if xmlFile == nil then
        print("[SPS SPR] registerSprayerPlaceable: XML load failed: " .. tostring(config.xmlFilePath))
        return
    end

    local kp = (config.xmlKeyPrefix or "") .. "sprayerPipeSystem."

    -- Resolve storage from silo spec (sprayer placeables must be spec_silo)
    local storage = nil
    if placeable.spec_silo ~= nil and placeable.spec_silo.storage ~= nil then
        storage = placeable.spec_silo.storage
        print("[SPS SPR] registerSprayerPlaceable: found storage in spec_silo")
    elseif placeable.spec_husbandry ~= nil and placeable.spec_husbandry.storage ~= nil then
        storage = placeable.spec_husbandry.storage
        print("[SPS SPR] registerSprayerPlaceable: found storage in spec_husbandry")
    elseif placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil and #placeable.spec_silo.storages > 0 then
        storage = placeable.spec_silo.storages[1]
        print("[SPS SPR] registerSprayerPlaceable: found storage in spec_silo.storages[1]")
    end

    local sourceEntry = nil
    if storage ~= nil then
        sourceEntry = {
            type        = SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE,
            placeable   = placeable,
            storage     = storage,
            fillPlaneNode = nil,
            planeBounds   = nil,
        }
        print("[SPS SPR] registerSprayerPlaceable: sourceEntry created for " .. tostring(placeable.configFileName))
    else
        print("[SPS SPR] registerSprayerPlaceable: no storage found for " .. tostring(placeable.configFileName))
    end

    local linkedNodes = {}

    -- Load nodeTree — same link pattern as slurry registerPlaceable
    local nodeTreePath = xmlFile:getString(kp .. "nodeTree#filename")
    if nodeTreePath ~= nil then
        local configFolder = config.xmlFilePath:match("^(.*[/\\])")
        local fullPath     = configFolder .. nodeTreePath
        local nodeTreeRoot = loadI3DFile(fullPath)
        if nodeTreeRoot ~= nil and nodeTreeRoot ~= 0 then
            local function findByName(root, name)
                if getName(root) == name then return root end
                for i = 0, getNumOfChildren(root) - 1 do
                    local found = findByName(getChildAt(root, i), name)
                    if found ~= nil then return found end
                end
                return nil
            end
            local spsRoot = getChildAt(nodeTreeRoot, 0)
            if spsRoot ~= nil and spsRoot ~= 0 then
                for groupIdx = 0, getNumOfChildren(spsRoot) - 1 do
                    local group = getChildAt(spsRoot, groupIdx)
                    for containerIdx = 0, getNumOfChildren(group) - 1 do
                        local container  = getChildAt(group, containerIdx)
                        local targetName = getName(container)
                        -- Search through all placeable component root nodes
                        local liveParent = nil
                        if placeable.components ~= nil then
                            for _, comp in ipairs(placeable.components) do
                                local found = findByName(comp.node, targetName)
                                if found ~= nil then liveParent = found break end
                            end
                        end
                        if liveParent ~= nil then
                            local children = {}
                            for childIdx = 0, getNumOfChildren(container) - 1 do
                                table.insert(children, getChildAt(container, childIdx))
                            end
                            for _, spsNode in ipairs(children) do
                                removeFromPhysics(spsNode)
                                link(liveParent, spsNode)
                                addToPhysics(spsNode)
                                table.insert(linkedNodes, spsNode)
                            end
                        else
--                            print("[SPS SPR] registerSprayerPlaceable: container target '" .. targetName .. "' not found in placeable")
                        end
                    end
                end
            end
            delete(nodeTreeRoot)
        else
            print("[SPS SPR] registerSprayerPlaceable: failed to load nodeTree: " .. tostring(fullPath))
        end
    end

    local function findLinkedNode(name)
        if name == nil or name == "" then return nil end
        for _, n in ipairs(linkedNodes) do
            if getName(n) == name then return n end
        end
        -- Embedded fallback: resolve nodes authored directly in the placeable's own
        -- i3d (no nodeTree injection). Only active for embedded configs so the bundled
        -- (nodeTree) path is unchanged.
        if config.isEmbedded and placeable.components ~= nil then
            local function searchTree(root, targetName)
                if getName(root) == targetName then return root end
                for i = 0, getNumOfChildren(root) - 1 do
                    local found = searchTree(getChildAt(root, i), targetName)
                    if found ~= nil then return found end
                end
                return nil
            end
            for _, comp in ipairs(placeable.components) do
                local found = searchTree(comp.node, name)
                if found ~= nil then return found end
            end
        end
        return nil
    end

    local entry = {
        object           = placeable,
        isPlaceable      = true,
        linkedNodes      = linkedNodes,
        couplings        = {},
        pipeActivatables = {},
        sourceEntry      = sourceEntry,
    }

    -- Load sprayer pipe couplings
    local couplingIndex = 0
    while true do
        local cKey = string.format(kp .. "sprayerPipeCouplings.sprayerPipeCoupling(%d)", couplingIndex)
        if not xmlFile:hasProperty(cKey) then break end
        local couplingId    = xmlFile:getInt(cKey .. "#id", couplingIndex + 1)
        local mountNodeName = xmlFile:getString(cKey .. "#mountNodeName")
        local mountNode     = findLinkedNode(mountNodeName)
        if mountNode ~= nil then
            local inNode, outNode
            local function findInOut(node)
                for i = 0, getNumOfChildren(node) - 1 do
                    local child = getChildAt(node, i)
                    local n = getName(child)
                    if n == "inNode" then inNode = child
                    elseif n == "outNode" then outNode = child
                    else findInOut(child) end
                end
            end
            findInOut(mountNode)
            local sc = {
                id                       = couplingId,
                mountNode                = mountNode,
                inNode                   = inNode,
                outNode                  = outNode,
                flowDirection            = xmlFile:getString(cKey .. "#flowDirection", "BOTH"),
                maxPipeLength            = xmlFile:getFloat(cKey .. "#maxPipeLength", 7.5),
                connectorAnimationId     = xmlFile:getInt(cKey .. "#connectorAnimation"),
                valveAnimationId         = xmlFile:getInt(cKey .. "#valveAnimation"),
                isConnected              = false,
                valveOpen                = false,
                connectedTarget          = nil,
                connectedPartnerCoupling = nil,
                pipeId                   = nil,
                object                   = placeable,
                placeable                = placeable,
                sourceEntry              = sourceEntry,
            }
            -- Bind coupler animations (connector + valve) if configured
            if SPSCouplerAnimator ~= nil
            and (sc.connectorAnimationId ~= nil or sc.valveAnimationId ~= nil) then
                SPSCouplerAnimator.ensureLoaded(g_currentMission.spsModDirectory)
                if sc.connectorAnimationId ~= nil then
                    sc.connectorAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.connectorAnimationId)
                end
                if sc.valveAnimationId ~= nil then
                    sc.valveAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.valveAnimationId)
                end
            end
            table.insert(entry.couplings, sc)
            -- Placeable-side SPSSprayerPipeActivatable intentionally NOT registered.
            -- All connect/disconnect must go through the vehicle's sprayerPumpControl
            -- node to enforce the load animation -> connect -> valve animation sequence.
            print("[SPS SPR] registerSprayerPlaceable: coupling id=" .. tostring(couplingId) .. " registered (no activatable, vehicle-side only)")
        else
            print("[SPS SPR] registerSprayerPlaceable: coupling id=" .. tostring(couplingId)
                .. " mountNode '" .. tostring(mountNodeName) .. "' not found, skipping")
        end
        couplingIndex = couplingIndex + 1
    end

    if xmlFileOwned then xmlFile:delete() end
    table.insert(self.registeredSprayerPlaceables, entry)
    print("[SPS SPR] registerSprayerPlaceable: registered " .. tostring(placeable.configFileName))
end

-- ---------------------------------------------------------------------------
-- Sprayer unregistration
-- ---------------------------------------------------------------------------
function SlurryPipeManager:unregisterSprayerVehicle(vehicle)
    for i, entry in ipairs(self.registeredSprayerVehicles) do
        if entry.object == vehicle then
            -- Stop any active flow
            self.activeSprayerFlows[vehicle] = nil
            -- Force-disconnect all couplings
            for _, coupling in ipairs(entry.couplings) do
                if coupling.isConnected then
                    coupling.valveOpen = false
                    if coupling.connectedPartnerCoupling ~= nil then
                        coupling.connectedPartnerCoupling.valveOpen = false
                    end
                    self:applySprayerDisconnect(vehicle, coupling.id, coupling)
                end
            end
            -- Remove activatables
            for _, act in ipairs(entry.pipeActivatables) do
                act:delete()
            end
            for _, pc in ipairs(entry.pumpControls) do
                if pc.activatable ~= nil then pc.activatable:delete() end
            end
            -- Clean up engine loop sound BEFORE deleting linked / nodeTree nodes,
            -- otherwise the sample's bound nodes are already gone when stopSample /
            -- deleteSample run ("Unknown entity id …"). Wrap in pcall: in
            -- ShopConfigScreen preview, the sample object can be partially valid
            -- (engine returns a stub with nil id) and stopSample throws
            -- "Expected: Float. Actual: Nil". Cleanup-time errors must never crash.
            if entry.engineLoopSample ~= nil then
                local okStop, errStop = pcall(function()
                    g_soundManager:stopSample(entry.engineLoopSample)
                end)
                local okDel, errDel = pcall(function()
                    g_soundManager:deleteSample(entry.engineLoopSample)
                end)
                print("[SPS SPR] unregisterSprayerVehicle: sample cleanup stopOk="
                    .. tostring(okStop) .. " delOk=" .. tostring(okDel)
                    .. (okStop and "" or " stopErr=" .. tostring(errStop))
                    .. (okDel  and "" or " delErr="  .. tostring(errDel)))
                entry.engineLoopSample = nil
            end
            -- Delete linked nodes
            for _, nodeId in ipairs(entry.linkedNodes) do
                if nodeId ~= nil and nodeId ~= 0 then delete(nodeId) end
            end
            if entry.nodeTreeRoot ~= nil and entry.nodeTreeRoot ~= 0 then
                delete(entry.nodeTreeRoot)
                entry.nodeTreeRoot = nil
            end
            table.remove(self.registeredSprayerVehicles, i)
            print("[SPS SPR] unregisterSprayerVehicle: " .. tostring(vehicle.configFileName))
            return
        end
    end
end

function SlurryPipeManager:unregisterSprayerPlaceable(placeable)
    for i, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.object == placeable then
            for _, sc in ipairs(entry.couplings) do
                if sc.isConnected then
                    sc.valveOpen = false
                    if sc.connectedPartnerCoupling ~= nil then
                        sc.connectedPartnerCoupling.valveOpen = false
                    end
                    self:applySprayerDisconnect(nil, sc.id, sc)
                end
                if sc.activatable ~= nil then sc.activatable:delete() end
            end
            for _, nodeId in ipairs(entry.linkedNodes) do
                if nodeId ~= nil and nodeId ~= 0 then delete(nodeId) end
            end
            table.remove(self.registeredSprayerPlaceables, i)
            print("[SPS SPR] unregisterSprayerPlaceable: " .. tostring(placeable.configFileName))
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Sprayer lookup helpers
-- ---------------------------------------------------------------------------
function SlurryPipeManager:isSprayerVehicleRegistered(vehicle)
    for _, entry in ipairs(self.registeredSprayerVehicles) do
        if entry.object == vehicle then return true end
    end
    return false
end

function SlurryPipeManager:isSprayerPlaceableRegistered(placeable)
    for _, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.object == placeable then return true end
    end
    return false
end

function SlurryPipeManager:getSprayerVehicleEntry(vehicle)
    for _, entry in ipairs(self.registeredSprayerVehicles) do
        if entry.object == vehicle then return entry end
    end
    return nil
end

function SlurryPipeManager:getSprayerPlaceableEntry(placeable)
    for _, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.object == placeable then return entry end
    end
    return nil
end

function SlurryPipeManager:getSprayerObjectState(object)
    local vEntry = self:getSprayerVehicleEntry(object)
    if vEntry ~= nil then return vEntry.state end
    return nil
end

function SlurryPipeManager:sprayerHasConnectedPipe(object)
    local vEntry = self:getSprayerVehicleEntry(object)
    if vEntry ~= nil then
        for _, c in ipairs(vEntry.couplings) do
            if c.isConnected then return true end
        end
    end
    local pEntry = self:getSprayerPlaceableEntry(object)
    if pEntry ~= nil then
        for _, c in ipairs(pEntry.couplings) do
            if c.isConnected then return true end
        end
    end
    return false
end

-- Internal: find coupling table entry by id, searching both tables
function SlurryPipeManager:_findSprayerCouplingById(object, couplingId, searchPlaceables)
    if not searchPlaceables then
        for _, vEntry in ipairs(self.registeredSprayerVehicles) do
            if vEntry.object == object then
                for _, c in ipairs(vEntry.couplings) do
                    if c.id == couplingId then return c end
                end
            end
        end
    else
        for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
            if pEntry.object == object then
                for _, c in ipairs(pEntry.couplings) do
                    if c.id == couplingId then return c end
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Sprayer arc detection
-- Reuses _getCouplingArcNodes and _arcsOverlap — node structure is identical.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:findOverlappingSprayerCoupler(coupling)
    if coupling.isConnected then return nil end
    local apexA, arc1A, arc2A = self:_getCouplingArcNodes(coupling)
    if apexA == nil or not entityExists(apexA) then return nil end
    local apexAx, apexAy, apexAz = getWorldTranslation(apexA)

    for _, vEntry in ipairs(self.registeredSprayerVehicles) do
        for _, vc in ipairs(vEntry.couplings) do
            if vc ~= coupling and not vc.isConnected then
                local apexB, arc1B, arc2B = self:_getCouplingArcNodes(vc)
                if apexB ~= nil and entityExists(apexB) then
                    local bx, by, bz = getWorldTranslation(apexB)
                    if MathUtil.vector3Length(apexAx-bx, apexAy-by, apexAz-bz) <= SPS_MAX_CONNECT_DIST then
                        if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                            return vc
                        end
                    end
                end
            end
        end
    end

    for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
        for _, sc in ipairs(pEntry.couplings) do
            if sc ~= coupling and not sc.isConnected then
                local apexB, arc1B, arc2B = self:_getCouplingArcNodes(sc)
                if apexB ~= nil and entityExists(apexB) then
                    local bx, by, bz = getWorldTranslation(apexB)
                    if MathUtil.vector3Length(apexAx-bx, apexAy-by, apexAz-bz) <= SPS_MAX_CONNECT_DIST then
                        if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                            return sc
                        end
                    end
                end
            end
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Sprayer connect
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onSprayerCouplerConnect(object, coupling)
    if g_server == nil then
        -- Client: send to server. Server will find the overlapping coupler itself.
        SPSSprayerConnectEvent.sendEvent(object, coupling.id, nil, 0)
        return
    end

    local otherCoupling = self:findOverlappingSprayerCoupler(coupling)
    if otherCoupling == nil then
        print("[SPS SPR] onSprayerCouplerConnect: no overlapping coupler found")
        return
    end
    if coupling.isConnected then
        print("[SPS SPR] onSprayerCouplerConnect: source coupling already connected")
        return
    end
    if otherCoupling.isConnected then
        print("[SPS SPR] onSprayerCouplerConnect: target coupling already connected")
        return
    end

    local ownerA = object or coupling.placeable or coupling.object
    local ownerB = otherCoupling.placeable or otherCoupling.object

    self:applySprayerConnect(coupling, otherCoupling, ownerA, ownerB)

    -- Broadcast to clients with both IDs now known
    SPSSprayerConnectEvent.sendEvent(ownerA, coupling.id, ownerB, otherCoupling.id)
end

function SlurryPipeManager:applySprayerConnect(couplingA, couplingB, ownerA, ownerB)
    
    couplingA.isConnected              = true
    couplingA.connectedTarget          = ownerB
    couplingA.connectedPartnerCoupling = couplingB

    couplingB.isConnected              = true
    couplingB.connectedTarget          = ownerA
    couplingB.connectedPartnerCoupling = couplingA
    

    if g_spsSprayerPipeVisual ~= nil and g_spsSprayerPipeVisual:isReady() then
        -- couplingA is the side the player activated from — pipe starts at its outNode.
        -- couplingB is the far side — pipe ends at its inNode.
        local nodeA = couplingA.outNode or couplingA.mountNode
        local nodeB = couplingB.inNode  or couplingB.mountNode
        local inst  = g_spsSprayerPipeVisual:createPipe(nodeA, nodeB)
        if inst ~= nil then
            local pipeId = self._nextSprayerPipeId
            self._nextSprayerPipeId = self._nextSprayerPipeId + 1
            self.activeSprayerPipes[pipeId] = { inst = inst, couplingA = couplingA, couplingB = couplingB }
            couplingA.pipeId = pipeId
            couplingB.pipeId = pipeId
            print("[SPS SPR] applySprayerConnect: pipe created pipeId=" .. tostring(pipeId))
        else
            print("[SPS SPR] applySprayerConnect: WARNING g_spsSprayerPipeVisual:createPipe returned nil")
        end
    else
        print("[SPS SPR] applySprayerConnect: WARNING g_spsSprayerPipeVisual not ready, no visual created")
    end

    -- Play connector animations forward (pipe connection)
    if SPSCouplerAnimator ~= nil then
        if couplingA.connectorAnim ~= nil then
            SPSCouplerAnimator.play(couplingA.connectorAnim, 1)
            print("[SPS SPR] applySprayerConnect: connector animation played forward on couplingA")
        end
        if couplingB.connectorAnim ~= nil then
            SPSCouplerAnimator.play(couplingB.connectorAnim, 1)
            print("[SPS SPR] applySprayerConnect: connector animation played forward on couplingB")
        end
    end

    -- Valve stays closed on connect. Player explicitly starts flow via B key (onSprayerToggleValve).
    couplingA.valveOpen = false
    if couplingB ~= nil then couplingB.valveOpen = false end
    local ownerAEntry = self:getSprayerVehicleEntry(ownerA)
    if ownerAEntry ~= nil then ownerAEntry.state.valveOpen = false end
    local ownerBEntry = self:getSprayerVehicleEntry(ownerB)
    if ownerBEntry ~= nil then ownerBEntry.state.valveOpen = false end
    print("[SPS SPR] applySprayerConnect: valves initialised closed")
end

-- Network event path: called with IDs from remote clients or server broadcasts.
-- If targetCouplingId == 0 (client-to-server), finds the other coupling by arc overlap.
function SlurryPipeManager:applySprayerConnectById(object, couplingId, targetObject, targetCouplingId)
    -- Find couplingA — check vehicles first, then placeables
    local couplingA = self:_findSprayerCouplingById(object, couplingId, false)
    if couplingA == nil then
        couplingA = self:_findSprayerCouplingById(object, couplingId, true)
    end
    if couplingA == nil then
        -- object may be nil for placeable-initiated — search all
        for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
            for _, c in ipairs(pEntry.couplings) do
                if c.id == couplingId and (object == nil or pEntry.object == object) then
                    couplingA = c
                    break
                end
            end
            if couplingA ~= nil then break end
        end
    end
    if couplingA == nil then
        print("[SPS SPR] applySprayerConnectById: couplingA not found id=" .. tostring(couplingId))
        return
    end

    -- Find couplingB — if not given, use arc overlap (client→server case)
    local couplingB = nil
    if targetCouplingId ~= nil and targetCouplingId > 0 and targetObject ~= nil then
        couplingB = self:_findSprayerCouplingById(targetObject, targetCouplingId, false)
        if couplingB == nil then
            couplingB = self:_findSprayerCouplingById(targetObject, targetCouplingId, true)
        end
    end
    if couplingB == nil then
        couplingB = self:findOverlappingSprayerCoupler(couplingA)
    end
    if couplingB == nil then
        print("[SPS SPR] applySprayerConnectById: couplingB not found")
        return
    end

    local ownerA = object       or couplingA.placeable or couplingA.object
    local ownerB = targetObject or couplingB.placeable or couplingB.object
    self:applySprayerConnect(couplingA, couplingB, ownerA, ownerB)
end

-- ---------------------------------------------------------------------------
-- Sprayer disconnect
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onSprayerCouplerDisconnect(object, coupling)
    -- No valve check for sprayers - valves auto-open on connect and auto-close on disconnect
    
    if g_server == nil then
        SPSSprayerDisconnectEvent.sendEvent(object, coupling.id)
        return
    end

    self:applySprayerDisconnect(object, coupling.id, coupling)
    SPSSprayerDisconnectEvent.sendEvent(object, coupling.id)
end

function SlurryPipeManager:applySprayerDisconnect(object, couplingId, couplingObj)
    local coupling = couplingObj
    if coupling == nil then
        -- Network path: search by id
        if object ~= nil then
            coupling = self:_findSprayerCouplingById(object, couplingId, false)
        end
        if coupling == nil then
            for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
                for _, c in ipairs(pEntry.couplings) do
                    if c.id == couplingId then coupling = c break end
                end
                if coupling ~= nil then break end
            end
        end
    end

    if coupling == nil then
        print("[SPS SPR] applySprayerDisconnect: coupling id=" .. tostring(couplingId) .. " not found")
        return
    end

    local partner = coupling.connectedPartnerCoupling

    -- Stop any active flow for either end
    local ownerA = object or coupling.placeable or coupling.object
    local ownerB = partner ~= nil and (partner.object or partner.placeable) or nil
    if ownerA ~= nil then self.activeSprayerFlows[ownerA] = nil end
    if ownerB ~= nil then self.activeSprayerFlows[ownerB] = nil end

    -- Stop pump on vehicle side
    local ownerAEntry = self:getSprayerVehicleEntry(ownerA)
    if ownerAEntry ~= nil and ownerAEntry.state.pumpRunning then
        ownerAEntry.state.pumpRunning = false
        print("[SPS SPR] applySprayerDisconnect: pump stopped on ownerA")
    end
    local ownerBEntry = self:getSprayerVehicleEntry(ownerB)
    if ownerBEntry ~= nil and ownerBEntry.state.pumpRunning then
        ownerBEntry.state.pumpRunning = false
        print("[SPS SPR] applySprayerDisconnect: pump stopped on ownerB")
    end

    -- Close valves (must be before animations play)
    coupling.valveOpen = false
    if partner ~= nil then
        partner.valveOpen = false
    end
    
    -- Also clear state.valveOpen on vehicle side
    if ownerAEntry ~= nil then
        ownerAEntry.state.valveOpen = false
    end
    if ownerBEntry ~= nil then
        ownerBEntry.state.valveOpen = false
    end

    -- Stop engine sound on disconnect
    if ownerAEntry ~= nil and ownerAEntry.engineLoopSample ~= nil then
        g_soundManager:stopSample(ownerAEntry.engineLoopSample)
    end
    if ownerBEntry ~= nil and ownerBEntry.engineLoopSample ~= nil then
        g_soundManager:stopSample(ownerBEntry.engineLoopSample)
    end

    -- Play valve animations reverse FIRST (auto-close valves)
    if SPSCouplerAnimator ~= nil then
        if coupling.valveAnim ~= nil then
            SPSCouplerAnimator.play(coupling.valveAnim, -1)
            print("[SPS SPR] applySprayerDisconnect: valve animation reversed on coupling")
        end
        if partner ~= nil and partner.valveAnim ~= nil then
            SPSCouplerAnimator.play(partner.valveAnim, -1)
            print("[SPS SPR] applySprayerDisconnect: valve animation reversed on partner")
        end
    end

    -- Play connector animations reverse (pipe disconnection)
    if SPSCouplerAnimator ~= nil then
        if coupling.connectorAnim ~= nil then
            SPSCouplerAnimator.play(coupling.connectorAnim, -1)
            print("[SPS SPR] applySprayerDisconnect: connector animation reversed on coupling")
        end
        if partner ~= nil and partner.connectorAnim ~= nil then
            SPSCouplerAnimator.play(partner.connectorAnim, -1)
            print("[SPS SPR] applySprayerDisconnect: connector animation reversed on partner")
        end
    end

    -- NOW destroy pipe visual (after animations started)
    if coupling.pipeId ~= nil then
        local pipeData = self.activeSprayerPipes[coupling.pipeId]
        if pipeData ~= nil and g_spsSprayerPipeVisual ~= nil then
            g_spsSprayerPipeVisual:destroyPipe(pipeData.inst)
            self.activeSprayerPipes[coupling.pipeId] = nil
        else
            print("[SPS SPR] applySprayerDisconnect: WARNING pipeId=" .. tostring(coupling.pipeId) .. " had no pipeData")
        end
        coupling.pipeId = nil
        if partner ~= nil then partner.pipeId = nil end
    end

    -- Clear both coupling ends
    coupling.isConnected              = false
    coupling.connectedTarget          = nil
    coupling.connectedPartnerCoupling = nil

    if partner ~= nil then
        partner.isConnected              = false
        partner.connectedTarget          = nil
        partner.connectedPartnerCoupling = nil
    end

    -- Reverse load animation (close cover) on the vehicle side and reset state
    local vehicleOwner = object or coupling.object
    if vehicleOwner ~= nil and vehicleOwner.playAnimation ~= nil then
        if coupling.loadAnimationName ~= nil and coupling.loadAnimPlayed then
            vehicleOwner:playAnimation(coupling.loadAnimationName, -1)
            print("[SPS SPR] applySprayerDisconnect: reversed load animation on vehicle")
        end
        if partner ~= nil and partner.loadAnimationName ~= nil and partner.loadAnimPlayed then
            local partnerVehicle = partner.object
            if partnerVehicle ~= nil and partnerVehicle.playAnimation ~= nil then
                partnerVehicle:playAnimation(partner.loadAnimationName, -1)
                print("[SPS SPR] applySprayerDisconnect: reversed load animation on partner vehicle")
            end
        end
    end
    coupling.loadAnimPlayed = false
    if partner ~= nil then partner.loadAnimPlayed = false end

    print("[SPS SPR] applySprayerDisconnect: coupling id=" .. tostring(couplingId) .. " disconnected")
end

-- ---------------------------------------------------------------------------
-- Sprayer action handlers — called by SPSSprayerPumpControl
-- ---------------------------------------------------------------------------
-- Sprayers have a single B-key flow toggle: there is no separate pump control,
-- so pumpRunning is mirrored to valveOpen here. tickSprayerFlow requires both.
function SlurryPipeManager:onSprayerToggleValve(object)
    local entry = self:getSprayerVehicleEntry(object)
    if entry == nil then return end
    local state = entry.state
    local newValve = not state.valveOpen
    -- Pipe must be connected before opening
    if newValve and not self:sprayerHasConnectedPipe(object) then
        print("[SPS SPR] onSprayerToggleValve: no pipe connected, valve blocked")
        return
    end
    if g_server ~= nil then
        state.valveOpen   = newValve
        state.pumpRunning = newValve
        -- Mirror valveOpen onto the coupling entries so tickSprayerFlow sees it
        for _, c in ipairs(entry.couplings) do
            if c.isConnected then
                c.valveOpen = newValve
                if c.connectedPartnerCoupling ~= nil then
                    c.connectedPartnerCoupling.valveOpen = newValve
                end
            end
        end
        SPSSprayerValveStateEvent.sendEvent(object, newValve)
        SPSSprayerPumpStateEvent.sendEvent(object, newValve)
    else
        SPSSprayerValveStateEvent.sendEvent(object, newValve)
        SPSSprayerPumpStateEvent.sendEvent(object, newValve)
    end
    -- Play/stop engine sound (valve open = flow = engine on for sprayers)
    if object.isClient and entry.engineLoopSample ~= nil then
        if newValve then
            g_soundManager:playSample(entry.engineLoopSample)
        else
            g_soundManager:stopSample(entry.engineLoopSample)
        end
    end
    print("[SPS SPR] onSprayerToggleValve: valveOpen=" .. tostring(newValve) .. " pumpRunning=" .. tostring(newValve))
end

function SlurryPipeManager:onSprayerToggleDirection(object)
    local entry = self:getSprayerVehicleEntry(object)
    if entry == nil then return end
    local state = entry.state
    if state.valveOpen then
        print("[SPS SPR] onSprayerToggleDirection: valve open, direction change blocked")
        return
    end
    local newDir = (state.direction == SPS_SPRAYER_DIRECTION_FILL)
        and SPS_SPRAYER_DIRECTION_DISCHARGE
        or  SPS_SPRAYER_DIRECTION_FILL
    if g_server ~= nil then
        state.direction = newDir
        SPSSprayerDirectionEvent.sendEvent(object, newDir)
    else
        SPSSprayerDirectionEvent.sendEvent(object, newDir)
    end
    print("[SPS SPR] onSprayerToggleDirection: direction=" .. tostring(newDir))
end

-- ---------------------------------------------------------------------------
-- Sprayer flow
-- ---------------------------------------------------------------------------

-- Returns a sourceEntry for the coupling's connected partner side.
-- Searches sprayer placeables first, then sprayer vehicles.
function SlurryPipeManager:_resolveSprayerSource(coupling)
    if not coupling.isConnected then 
        return nil 
    end
    local partner = coupling.connectedPartnerCoupling
    if partner == nil then 
        return nil 
    end

    -- Partner is a sprayer placeable coupling
    for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
        for _, sc in ipairs(pEntry.couplings) do
            if sc == partner then 
                return pEntry.sourceEntry 
            end
        end
    end

    -- Partner is a sprayer vehicle coupling
    local target = coupling.connectedTarget
    if target ~= nil then
        local vEntry = self:getSprayerVehicleEntry(target)
        if vEntry ~= nil then
            local fillUnitIndex = 1
            if #vEntry.couplings > 0 then
                fillUnitIndex = vEntry.couplings[1].fillUnitIndex or 1
            end
            return { type = "FILL_UNIT_ONLY", vehicle = target, fillUnitIndex = fillUnitIndex }
        end
    end

    return nil
end

function SlurryPipeManager:buildSprayerFlowSession(vehicle)
    local entry = self:getSprayerVehicleEntry(vehicle)
    local litersPerSecond = 200
    local fillUnitIndex   = 1
    if entry ~= nil then
        litersPerSecond = entry.litersPerSecond
        if #entry.couplings > 0 then
            fillUnitIndex = entry.couplings[1].fillUnitIndex or 1
        end
    end
    return { vehicle = vehicle, vehicleFillUnit = fillUnitIndex, baseLitersPerSecond = litersPerSecond }
end

function SlurryPipeManager:tickSprayerFlow(session, dt)
    local vehicle = session.vehicle
    local entry   = self:getSprayerVehicleEntry(vehicle)
    if entry == nil then 
        return 
    end
    local state = entry.state
    if not state.pumpRunning then 
        return 
    end
    if not state.valveOpen then 
        return 
    end

    -- Find the first connected coupling with its valve open
    local activeCoupling = nil
    for _, c in ipairs(entry.couplings) do
        if c.isConnected and c.valveOpen then
            activeCoupling = c
            break
        end
    end
    if activeCoupling == nil then 
        return 
    end

    -- Build vehicle-side sourceEntry inline
    local vehicleEntry = { type = "FILL_UNIT_ONLY", vehicle = vehicle, fillUnitIndex = session.vehicleFillUnit }
    -- Resolve the external side
    local extEntry = self:_resolveSprayerSource(activeCoupling)
    if extEntry == nil then 
        return 
    end

    -- Direction determines which side is source and which is destination
    local srcEntry, dstEntry
    if state.direction == SPS_SPRAYER_DIRECTION_FILL then
        srcEntry = extEntry
        dstEntry = vehicleEntry
    else
        srcEntry = vehicleEntry
        dstEntry = extEntry
    end

    -- Determine what fillType the source actually holds
    local fillType = self:_resolveSourceFillType(srcEntry)
    if fillType == nil then 
        return 
    end

    -- Destination must accept this fillType
    if not self:_destAcceptsFillType(dstEntry, fillType) then 
        return 
    end

    -- Get source level
    local sourceLevel = 0
    if srcEntry.type == "FILL_UNIT_ONLY" then
        if srcEntry.vehicle ~= nil then
            sourceLevel = srcEntry.vehicle:getFillUnitFillLevel(srcEntry.fillUnitIndex) or 0
        end
    elseif srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if srcEntry.storage ~= nil then
            sourceLevel = srcEntry.storage:getFillLevel(fillType) or 0
        end
    end
    if sourceLevel <= 0 then 
        return 
    end

    -- Get destination free capacity
    local freeCapacity = 0
    if dstEntry.type == "FILL_UNIT_ONLY" then
        if dstEntry.vehicle ~= nil then
            local cap   = dstEntry.vehicle:getFillUnitCapacity(dstEntry.fillUnitIndex) or 0
            local level = dstEntry.vehicle:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0
            freeCapacity = cap - level
        end
    elseif dstEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if dstEntry.storage ~= nil then
            freeCapacity = dstEntry.storage:getFreeCapacity(fillType) or 0
        end
    end
    if freeCapacity <= 0 then 
        return 
    end

    local amount = math.min(session.baseLitersPerSecond * dt * 0.001, sourceLevel, freeCapacity)
    if amount <= 0 then 
        return 
    end

    self:removeFromSource(srcEntry, amount, fillType, vehicle)
    self:addToSource(dstEntry, amount, fillType, vehicle)
end

-- ---------------------------------------------------------------------------
-- Sprayer update — called from SPSMod:update(dt)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:updateSprayers(dt)
    -- Update sprayer bez pipe bezier bones each tick
    if g_spsSprayerPipeVisual ~= nil then
        for _, pipeData in pairs(self.activeSprayerPipes) do
            if pipeData.couplingA.mountNode ~= nil and pipeData.couplingB.mountNode ~= nil then
                g_spsSprayerPipeVisual:updatePipe(pipeData.inst)
            end
        end
    end

    if g_server == nil then return end

    -- Sync active flow sessions with pump + valve + connection state
    for _, vEntry in ipairs(self.registeredSprayerVehicles) do
        local vehicle = vEntry.object
        local state   = vEntry.state
        local hasFlow = state.valveOpen and self:sprayerHasConnectedPipe(vehicle)
        if hasFlow then
            if self.activeSprayerFlows[vehicle] == nil then
                self.activeSprayerFlows[vehicle] = self:buildSprayerFlowSession(vehicle)
                print("[SPS SPR] updateSprayers: flow session STARTED for " .. tostring(vehicle.configFileName))
            end
        else
            if self.activeSprayerFlows[vehicle] ~= nil then
                self.activeSprayerFlows[vehicle] = nil
                print("[SPS SPR] updateSprayers: flow session STOPPED for " .. tostring(vehicle.configFileName))
            end
        end
    end

    -- Tick all active sprayer flow sessions
    for _, session in pairs(self.activeSprayerFlows) do
        self:tickSprayerFlow(session, dt)
    end

    -- Auto-disconnect when pipe is stretched beyond maxPipeLength — every 10 ticks
    self._sprayerDistCheckTick = (self._sprayerDistCheckTick or 0) + 1
    if self._sprayerDistCheckTick >= 10 then
        self._sprayerDistCheckTick = 0
        for _, vEntry in ipairs(self.registeredSprayerVehicles) do
            for _, c in ipairs(vEntry.couplings) do
                if c.isConnected
                and c.mountNode ~= nil
                and c.connectedPartnerCoupling ~= nil
                and c.connectedPartnerCoupling.mountNode ~= nil then
                    local ax, ay, az = getWorldTranslation(c.mountNode)
                    local bx, by, bz = getWorldTranslation(c.connectedPartnerCoupling.mountNode)
                    local dist = MathUtil.vector3Length(ax-bx, ay-by, az-bz)
                    if dist > (c.maxPipeLength or 7.5) then
                        print("[SPS SPR] updateSprayers: auto-disconnect coupling id=" .. tostring(c.id)
                            .. " dist=" .. string.format("%.2f", dist))
                        self:applySprayerDisconnect(vEntry.object, c.id, c)
                        SPSSprayerDisconnectEvent.sendEvent(vEntry.object, c.id)
                    end
                end
            end
        end
    end
end