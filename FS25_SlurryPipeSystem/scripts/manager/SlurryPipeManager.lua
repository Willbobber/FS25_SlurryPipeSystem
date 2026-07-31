-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.10.4

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

-- [SPS 1.0.0.9.26] Source-entry type tag for buying-station placeables
-- (vanilla placeable type "buyingStation", e.g. buyable liquid manure wells).
-- String-typed like "FILL_UNIT_ONLY" so SlurryNodeUtil needs no change.
SPS_SOURCE_TYPE_BUYING_STATION = "BUYING_STATION"

SPS_MAX_CONNECT_DIST    = 5.9   -- max distance (m) at which two couplers can connect
SPS_AUTODISCONNECT_DIST = 6.0   -- distance (m) at which a connected pipe auto-disconnects

SlurryPipeManager = {}
local SlurryPipeManager_mt = Class(SlurryPipeManager)

-- ---------------------------------------------------------------------------
-- Debug logging
-- Flip SlurryPipeManager.DEBUG to true to print [SPS PM] trace lines from every
-- key part of this script; set it to false to silence all logging from this
-- file in one place.
--
-- SlurryPipeManager.log(fmt, ...) checks the flag BEFORE doing any string.format
-- work, and callers pass the format + arguments through (they do not pre-format).
-- That means when DEBUG is false there is no string allocation, so the helper is
-- safe to call from event/lifecycle code. Per-tick / hot-path call sites are
-- additionally wrapped in `if SlurryPipeManager.DEBUG then ... end` and gated on a
-- state change so the loop body is skipped entirely when logging is off and never
-- spams a line every frame when it is on.
-- ---------------------------------------------------------------------------
SlurryPipeManager.DEBUG = false

function SlurryPipeManager.log(fmt, ...)
    if not SlurryPipeManager.DEBUG then return end
    if select("#", ...) > 0 then
        print("[SPS PM] " .. string.format(fmt, ...))
    else
        print("[SPS PM] " .. tostring(fmt))
    end
end

-- ---------------------------------------------------------------------------
-- [SPS SPRAY] Sprayer-issue diagnostic trace.
-- Independent of SlurryPipeManager.DEBUG so the sprayer fill/turn-on path can be
-- traced without the frame-spammy PM log. Flip to true to enable; leave false in
-- normal play. sprayTrace checks the flag BEFORE any string.format work.
-- ---------------------------------------------------------------------------
SlurryPipeManager.SPRAYER_TRACE = false

function SlurryPipeManager.sprayTrace(fmt, ...)
    if not SlurryPipeManager.SPRAYER_TRACE then return end
    if select("#", ...) > 0 then
        print("[SPS SPRAY] " .. string.format(fmt, ...))
    else
        print("[SPS SPRAY] " .. tostring(fmt))
    end
end

-- ---------------------------------------------------------------------------
-- [SPS MP] / miscellaneous diagnostic gate. Every previously-ungated raw
-- print() in this file (MP state sync, FRCDIAG, client-optimistic couplings,
-- embedded pipe effect resolve) now routes through this wrapper so a single
-- flag silences them on release. Pass-through: it forwards its args verbatim to
-- print(), so each call keeps its own "[SPS ...]" prefix. Flip to true to trace.
-- ---------------------------------------------------------------------------
SlurryPipeManager.MP_DEBUG = false
print("[SPS BUILD] SlurryPipeManager 1.0.0.10.4 loaded")
-- findOverlappingCoupler: from couplingId
-- _applyPendingCouplerAnimation: couplingId

function SlurryPipeManager.logMP(...)
    if not SlurryPipeManager.MP_DEBUG then return end
    print(...)
end

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
-- [SPS BLOCKAGE v1.0.0.10.4] Banded blockage model. Blockages are caused by LUMPS,
-- i.e. the crust the tanker is carrying; dry matter's job is slowing the pump, not
-- clogging the bar, so it is only a mild amplifier here. A macerator is a lump
-- smasher with a finite capacity: below BLOCKAGE_OUTLET_CRUST_MIN it takes the
-- punishment and the outlets stay clear (only the base foreign-object chance
-- applies); above it, lumps get past and the outlets start to clog too. A bar with
-- NO macerator node has no such protection and its outlets are exposed from
-- BLOCKAGE_OUTLET_CRUST_MIN_RAW upward -- which is the whole reason to fit one.
--
-- Every value below is a DEFAULT. Each may be overridden per vehicle on the
-- <blockageNodes> container in that vehicle's fillPoints.xml, so a fine-orifice
-- trailing shoe can be authored more fragile than a splash plate.
SlurryPipeManager.BLOCKAGE_MACERATOR_CRUST_MIN = 0.25 -- carried crust below which the macerator copes and nothing lump-driven happens
SlurryPipeManager.BLOCKAGE_OUTLET_CRUST_MIN    = 0.60 -- the macerator's capacity ceiling: past this, lumps reach the outlets
SlurryPipeManager.BLOCKAGE_OUTLET_CRUST_MIN_RAW = 0.25 -- outlet threshold when NO macerator is fitted (unprotected bar)
-- Retained under its original name because SPSSpreaderHUD reads it for the risk
-- band; it now means "the crust at which lumps first become a factor at all".
SlurryPipeManager.BLOCKAGE_CRUST_MIN        = 0.25  -- tanker-carried crust below which only the base (foreign-object) chance applies
SlurryPipeManager.BLOCKAGE_BASE_CHANCE      = 0.001 -- per-BAR random clog chance even on clean slurry (wood/debris/foreign object)
SlurryPipeManager.BLOCKAGE_DM_BONUS         = 0.25  -- extra blockage multiplier at the jam point (thick + crusted is worst); 0 = DM has no effect
-- [SPS CRUST v1.0.0.10.2] Crust timing. Both values are ABSOLUTE in-game hours and
-- are deliberately independent of the player's daysPerPeriod setting: crust forms on
-- a physical timescale, not a seasonal one, so these numbers mean the same thing on
-- every save. Both are consumed as a linear rate against the shared monotonic game
-- clock (Environment:getMonotonicHour), so they are timescale-correct and survive
-- sleeping, fast-forward and save/load without drift.
--   grow:  settle += hours / CRUST_GROW_HOURS  * storeCrustGrow
--   mix:   settle -= hours / CRUST_MIX_HOURS   * agitatorCrustMix
SlurryPipeManager.CRUST_GROW_HOURS          = 720.0 -- game hours of no mixing for crust to grow 0 -> 100% (30 in-game days)
SlurryPipeManager.CRUST_MIX_HOURS           = 2.0   -- game hours of continuous stirring for 100% -> 0% at crustMix="1"
-- Per-vehicle / per-placeable XML multipliers are clamped into this band on read so a
-- typo can never make a store uncrustable or a mixer instantaneous. Higher = faster.
SlurryPipeManager.CRUST_MULT_MIN            = 0.1
SlurryPipeManager.CRUST_MULT_MAX            = 10.0
-- Legacy names retained ONLY so any third-party script still reading them does not
-- index a nil. Nothing inside SPS consumes these any more.
SlurryPipeManager.SETTLE_YEARS_TO_FULL      = 1.0   -- DEPRECATED (superseded by CRUST_GROW_HOURS)
SlurryPipeManager.AGITATION_RATE_MULT       = 1.0   -- DEPRECATED (folded into CRUST_MIX_HOURS)
-- Two-pool slurry model. A store tracks litres of dry matter (solids); liquid is the
-- live (totalFill - solids). The true dry-matter fraction DM = solids/total is mapped
-- onto the 0..1 player-facing thickness gauge: DM_FRESH reads 0%, DM_JAMMED reads 100%.
-- Mixing can only ever bring the gauge down to the DM-derived value (settling removed);
-- if DM itself is past the jam point the only remedy is adding water.
SlurryPipeManager.DM_FRESH                  = 0.06  -- dry-matter fraction shown as 0% on the gauge
SlurryPipeManager.DM_JAMMED                 = 0.15  -- dry-matter fraction shown as 100% (un-pumpable even fully mixed)
SlurryPipeManager.DM_REMOVAL_LIQUID_BIAS    = 1.6   -- liquid leaves at this multiple of its share (>1 = liquid pulled first)
SlurryPipeManager.WARNING_RANGE             = 15    -- metres: blinking flow warnings only show when in-cab or this close on foot
-- [SPS BLOCKAGE v1.0.0.10.4] Ramp slopes, added on top of BLOCKAGE_BASE_CHANCE and
-- scaled by how far carried crust has climbed past that row's threshold. Sized
-- against a ~5 minute tankful, i.e. 50 rolls at BLOCKAGE_ROLL_INTERVAL: fully mixed
-- slurry gives roughly a 5% chance of any stoppage per load, a month-unstirred store
-- around 70% on both rows. OUTLET_CHANCE was previously 0.0, which meant crust had
-- no effect whatsoever on the outlets and only the macerator ever responded to it.
SlurryPipeManager.BLOCKAGE_OUTLET_CHANCE    = 0.030
SlurryPipeManager.BLOCKAGE_MACERATOR_CHANCE = 0.027
SlurryPipeManager.BLOCKAGE_ROLL_INTERVAL    = 6000
SlurryPipeManager.BLOCKAGE_CLEAR_RADIUS     = 0.75

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
    self._chainsByNetId        = {}   -- [SPS MP] netId -> SPSPipeChain (replication key)
    self._nextChainNetId       = 1    -- [SPS MP] server-side netId allocator
    self._dumpedConnections    = {}   -- [SPS MP] client connections already sent an initial state dump
    self.chainTerminusEntries  = {}   -- chain end arcs checked in findOverlappingCoupler
    self.pendingChains              = {}   -- saved chain data waiting for anchor coupling to register
    self.pendingDeployedCouplings   = {}   -- saved deployed couplings waiting for placeable to register
    self.pendingPumpStates          = {}   -- saved per-vehicle pump direction waiting for vehicle to register
    self._pendingCouplerAnims       = {}   -- saved coupler animation states waiting to be applied
    -- [SPS MP] Join-dump connect/valve events that arrived on a client BEFORE the
    -- referenced vehicles finished loading (couplings not yet registered). Drained
    -- by _tryResolveMPPending() via tryResolvePendingConnections() as vehicles register.
    self._pendingMPConnections      = {}
    self._pendingMPValves           = {}
    -- [SPS MP] Join-dump chain-terminus bonds (SPSChainConnectEvent) that arrived
    -- before the tanker coupler or the chain was registered on this client. Unlike
    -- direct connects, applyChainConnect used to drop these silently, so a joiner saw
    -- the chain geometry but no end bez / valve. Drained by _tryResolveMPPending too.
    self._pendingMPChainBonds       = {}
    -- [SPS MP] Join-dump chain-state rebuilds whose anchor owner (esp. a store
    -- placeable) had not registered yet on this client. Without this the chain
    -- rebuilds free-standing: segment 1 loses its anchor mount, so its rotation
    -- defaults to 0 (visible twist) and the valve/removal link is missing. Keyed by
    -- netId -> {anchorObject, couplingId, isPlaceable, payload}. Drained in
    -- _tryResolveChainAnchorRebinds() as placeables/vehicles register.
    self._pendingChainAnchorRebinds = {}
    self._chainRebindResolving      = false
    -- [SPS MP] Bez visuals whose creation was skipped because g_spsPipeVisual was
    -- not ready (async i3d load during map start — exactly the window in which a
    -- joining client drains its queued chain bonds). Previously the couplings were
    -- marked connected but the visual was PERMANENTLY dropped; the pipe only
    -- appeared after a manual remove/re-add. Drained in update() once ready.
    self._pendingPipeVisuals        = {}
    -- [SPS MP] Join-dump store crust values whose store placeable had not registered
    -- yet on this client. Drained by _tryResolveMPPending as placeables register.
    self._pendingMPStoreCrust       = {}
    -- [SPS MP] Sprayer pipe connects (SPSSprayerConnectEvent) that arrived before the
    -- sprayer/IBC was registered on this client. A freshly-spawned IBC pallet loads
    -- async, so the spawn's connect broadcast almost always beats it — without a retry
    -- the IBC shows but the pipe never draws. Drained when a sprayer (source) registers.
    self._pendingSprayerConnects    = {}
    self._mpResolving               = false
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
    -- IBC (liquid tank) persistence. false = empty IBCs self-delete (vanilla);
    -- true = they stay on the map. Server-authoritative (deletion is server-side).
    self.ibcPersistWhenEmpty        = false
    self.featureToggles = {
        thicknessFlow = true,   -- thick slurry slows fill / discharge / spread
        blockages     = true,   -- spread blockage system (Pass 2)
        lengthFalloff = true,   -- flow drop over strap-pipe length
    }
    -- [SPS 1.0.0.9.30] PTO shear bolt master switch (settings menu). Independent
    -- of the realism master; consumed at the SPSShearBolt.update call sites in
    -- SPSM_Pressure. Server-authoritative, synced via SPSSettingsSyncEvent.
    self.shearBoltEnabled           = true
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
    self.sprayerSourceVehicleConfigMap = {}  -- IBC liquid tanks (passive sprayer sources)
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
    self._chainsByNetId       = {}
    self._dumpedConnections   = {}
    self.chainTerminusEntries = {}
    self.registeredVehicles    = {}
    -- [SPS 1.0.0.9.15] Crust foliage clones are world-parented and no longer
    -- die with the map's placeables — delete them explicitly on mission end.
    if SPSCrustVegetation ~= nil and SPSCrustVegetation.deleteForPlaceable ~= nil then
        -- [SPS 1.0.0.9.31] Plant instances moved from pEntry.crustInstances onto the
        -- STORE entry, so the old pEntry-level guard would now never fire and the
        -- clones would survive mission end. deleteForPlaceable is idempotent and does
        -- its own has-anything check across every store, so call it unconditionally.
        for _, entry in ipairs(self.registeredPlaceables) do
            SPSCrustVegetation.deleteForPlaceable(entry)
        end
    end
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
    SlurryPipeManager.log("loadVehicleConfigs: enter modDir=%s", tostring(modDirectory))
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
    SlurryPipeManager.log("loadPlaceableConfigs: enter modDir=%s", tostring(modDirectory))
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
    SlurryPipeManager.log("loadPipeColors: enter")
    local path = modDirectory .. "configs/spsColors.xml"
    local xmlFile = XMLFile.load("spsColors", path)
    if xmlFile == nil then
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
    for i, c in ipairs(self.pipeColors) do
    end
    -- [SPS 1.0.0.9.30] Palette is loaded — apply the player's own saved
    -- HUD/colour preferences (per-user file, all machines incl. MP clients).
    self:loadUserSettings()
end

function SlurryPipeManager:setCurrentPipeColor(index)
    if self.pipeColors == nil or #self.pipeColors == 0 then
        return
    end
    index = math.clamp(index, 1, #self.pipeColors)
    local c = self.pipeColors[index]
    self.currentPipeColorIndex = index
    self.currentPipeColor      = { r = c.r, g = c.g, b = c.b }
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.30] Per-user settings (HUD + pipe colour picker)
-- These are per-PLAYER preferences, so they persist in the local user profile
-- (getUserProfileAppPath(), same writable root vanilla uses for storeItems.csv
-- in FSBaseMission:consoleCommandExportStoreItems) instead of the savegame.
-- Every machine — host, dedicated client, listen guest — keeps its own file.
-- The legacy savegame keys are still written/read for back-compat; the user
-- file, when present, wins (loadUserSettings is re-run after the savegame
-- values are applied in loadCouplingConnections).
-- ---------------------------------------------------------------------------
function SlurryPipeManager.getUserSettingsPath()
    if getUserProfileAppPath == nil then return nil end
    return getUserProfileAppPath() .. "FS25_SlurryPipeSystem_user.xml"
end

function SlurryPipeManager:saveUserSettings()
    local path = SlurryPipeManager.getUserSettingsPath()
    if path == nil then return end
    local xmlFile = XMLFile.create("spsUserSettings", path, "spsUserSettings")
    if xmlFile == nil then return end
    local hs = self.hudSettings or {}
    xmlFile:setInt  ("spsUserSettings#colorIndex", self.currentPipeColorIndex or 1)
    xmlFile:setBool ("spsUserSettings#hudEnabled", hs.enabled ~= false)
    xmlFile:setBool ("spsUserSettings#hudImage",   hs.image   ~= false)
    xmlFile:setBool ("spsUserSettings#hudFill",    hs.fill    ~= false)
    xmlFile:setBool ("spsUserSettings#hudCrust",   hs.crust   ~= false)
    xmlFile:setBool ("spsUserSettings#hudThick",   hs.thick   ~= false)
    xmlFile:setBool ("spsUserSettings#hudRisk",    hs.risk    ~= false)
    xmlFile:setBool ("spsUserSettings#hudPump",    hs.pump    ~= false)
    xmlFile:setFloat("spsUserSettings#hudScale",   hs.scale or 1.0)
    if hs.posX ~= nil then xmlFile:setFloat("spsUserSettings#hudPosX", hs.posX) end
    if hs.posY ~= nil then xmlFile:setFloat("spsUserSettings#hudPosY", hs.posY) end
    xmlFile:save()
    xmlFile:delete()
end

function SlurryPipeManager:loadUserSettings()
    local path = SlurryPipeManager.getUserSettingsPath()
    if path == nil then return end
    local xmlFile = XMLFile.loadIfExists("spsUserSettings", path, nil)
    if xmlFile == nil then return end
    self.hudSettings = self.hudSettings or {}
    local hs = self.hudSettings
    hs.enabled = xmlFile:getBool("spsUserSettings#hudEnabled", hs.enabled ~= false)
    hs.image   = xmlFile:getBool("spsUserSettings#hudImage",   hs.image   ~= false)
    hs.fill    = xmlFile:getBool("spsUserSettings#hudFill",    hs.fill    ~= false)
    hs.crust   = xmlFile:getBool("spsUserSettings#hudCrust",   hs.crust   ~= false)
    hs.thick   = xmlFile:getBool("spsUserSettings#hudThick",   hs.thick   ~= false)
    hs.risk    = xmlFile:getBool("spsUserSettings#hudRisk",    hs.risk    ~= false)
    hs.pump    = xmlFile:getBool("spsUserSettings#hudPump",    hs.pump    ~= false)
    hs.scale   = xmlFile:getFloat("spsUserSettings#hudScale",  hs.scale or 1.0)
    if xmlFile:hasProperty("spsUserSettings#hudPosX") then hs.posX = xmlFile:getFloat("spsUserSettings#hudPosX", 0.5) end
    if xmlFile:hasProperty("spsUserSettings#hudPosY") then hs.posY = xmlFile:getFloat("spsUserSettings#hudPosY", 0.985) end
    local colorIndex = xmlFile:getInt("spsUserSettings#colorIndex")
    xmlFile:delete()
    if colorIndex ~= nil then
        self:setCurrentPipeColor(colorIndex)
    end
    self._userSettingsLoaded = true
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.30] Gameplay settings (server-authoritative, MP-synced)
-- applyGameplaySettings sets the fields locally; when broadcast=true on the
-- server it also pushes the full set to every client via SPSSettingsSyncEvent.
-- requestGameplaySettings is the single entry point the settings menu uses:
-- the server applies + broadcasts; a client applies optimistically and sends
-- the request to the server (which rebroadcasts to the other clients).
-- ---------------------------------------------------------------------------
function SlurryPipeManager:applyGameplaySettings(t, broadcast)
    if t == nil then return end
    if t.realismEnabled ~= nil then self.realismEnabled = t.realismEnabled == true end
    self.featureToggles = self.featureToggles or {}
    if t.thicknessFlow ~= nil then self.featureToggles.thicknessFlow = t.thicknessFlow ~= false end
    if t.blockages ~= nil then self.featureToggles.blockages = t.blockages ~= false end
    if t.lengthFalloff ~= nil then self.featureToggles.lengthFalloff = t.lengthFalloff ~= false end
    if t.shearBoltEnabled ~= nil then self.shearBoltEnabled = t.shearBoltEnabled ~= false end
    if t.ibcPersistWhenEmpty ~= nil then
        self.ibcPersistWhenEmpty = t.ibcPersistWhenEmpty == true
        self:applyIbcPersistSetting()
    end
    if broadcast == true and g_server ~= nil and SPSSettingsSyncEvent ~= nil then
        local ft = self.featureToggles
        g_server:broadcastEvent(SPSSettingsSyncEvent.new(
            self.realismEnabled, ft.thicknessFlow, ft.blockages, ft.lengthFalloff,
            self.shearBoltEnabled, self.ibcPersistWhenEmpty), false, nil, nil)
    end
end

function SlurryPipeManager:requestGameplaySettings(t)
    if t == nil then return end
    if g_server ~= nil then
        self:applyGameplaySettings(t, true)
    else
        -- Client: apply optimistically, then ask the server to apply +
        -- rebroadcast to the other clients (this sender is excluded there).
        self:applyGameplaySettings(t, false)
        if SPSSettingsSyncEvent ~= nil and SPSSettingsSyncEvent.sendRequest ~= nil then
            SPSSettingsSyncEvent.sendRequest()
        end
    end
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

-- ---------------------------------------------------------------------------
-- [SPS CRUST v1.0.0.10.2] Shared game clock
--
-- Every time-based crust process (store crusting, mobile agitator, fixed PTO
-- agitator) reads game hours from ONE source: Giants' own monotonic clock,
-- Environment:getMonotonicHour() = currentMonotonicDay * 24 + dayTime / 3600000.
--
-- Why not dt: converting a real-millisecond dt into game time needs the live
-- timescale, and the previous code used Environment.timeAdjustment for that.
-- timeAdjustment is NOT a timescale -- Environment.lua sets it as
-- 1 / daysPerPeriod, a season-length normaliser -- so every crust process was
-- running at 1/daysPerPeriod of REAL time and ignoring the player's timescale
-- entirely. Reading the monotonic hour instead is timescale-correct by
-- construction (Environment advances dayTime by dt * getEffectiveTimeScale())
-- and is jump-safe: sleeping, fast-forward and save/load simply produce a
-- larger delta rather than silently losing time.
-- ---------------------------------------------------------------------------

-- Absolute game hour, or nil while the environment is not yet available.
function SlurryPipeManager:getGameHour()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil or env.getMonotonicHour == nil then return nil end
    local ok, h = pcall(env.getMonotonicHour, env)
    if not ok or type(h) ~= "number" then return nil end
    return h
end

-- Game hours elapsed since this owner last consumed the clock.
--
-- owner is any table with a life at least as long as the process (a vehicle
-- entry, a fixedAgitator table, the manager itself); field is the key the
-- last-read stamp is parked under, so one owner can drive several independent
-- processes. Returns 0 on the first call (nothing to charge yet) and 0 on any
-- backwards step, so a clock rewind can never produce negative mixing.
--
-- IMPORTANT: an intermittent process (an agitator that stops and restarts) MUST
-- call releaseGameHours when it goes inactive. Otherwise the whole idle period
-- lands on its first active tick as one enormous delta.
function SlurryPipeManager:consumeGameHours(owner, field)
    if owner == nil then return 0 end
    local now = self:getGameHour()
    if now == nil then return 0 end
    local last = owner[field]
    owner[field] = now
    if last == nil then return 0 end
    local d = now - last
    if d <= 0 then return 0 end
    return d
end

-- Drop an owner's stamp so the next consumeGameHours starts fresh at 0.
function SlurryPipeManager:releaseGameHours(owner, field)
    if owner ~= nil then owner[field] = nil end
end

-- Clamp an XML-supplied crust multiplier into the sane band. nil -> 1.0.
function SlurryPipeManager.clampCrustMult(v)
    if type(v) ~= "number" then return 1.0 end
    return math.max(SlurryPipeManager.CRUST_MULT_MIN,
           math.min(SlurryPipeManager.CRUST_MULT_MAX, v))
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.10.3] <effects> parameter reader
--
-- Until now the ONLY things read from an <effects> block were the two node
-- names; every timing and shaping value was hardcoded identically for every
-- vehicle and placeable in the mod, so the attributes already authored in the
-- shipped configs (startDelay, maxBending, extraDistance, ...) did nothing.
-- They are now read here.
--
-- Shape is unchanged and index-ordered, exactly as the configs already author it:
--   <effects>
--       <effectNode effectNode="effect"          .../>   <!-- 0 = stream -->
--       <effectNode effectNode="pipeEffectSmoke" .../>   <!-- 1 = smoke  -->
--   </effects>
--
-- TIMES ARE IN SECONDS, matching every other time attribute in SPS (<pressure>
-- minBuildTime, <spreaderAnimation> stopDelay) and matching the values already
-- authored in the shipped configs -- startDelay="0.1" on a smoke node is the
-- 100 ms the code used to hardcode. Converted to engine milliseconds here.
--
-- Every default reproduces the previous hardcoded value exactly, so a config
-- that declares nothing behaves byte-for-byte as it did in V1.0.0.10.
--
-- effectClass, materialType and positionUpdateNodes remain unread: the effect
-- objects are built directly rather than through the effect manager's schema,
-- so the class and the smoke node are structural, not selectable.
-- ---------------------------------------------------------------------------
function SlurryPipeManager.readEffectParams(xmlFile, effectsKey)
    local function secs(key, defaultSeconds)
        local v = xmlFile:getFloat(key, nil)
        if type(v) ~= "number" or v < 0 then v = defaultSeconds end
        return v * 1000
    end
    local sKey = effectsKey .. ".effectNode(0)"   -- stream
    local mKey = effectsKey .. ".effectNode(1)"   -- smoke

    local ep = {}
    ep.stream = {
        maxBending    = xmlFile:getFloat(sKey .. "#maxBending",    0.8),
        extraDistance = xmlFile:getFloat(sKey .. "#extraDistance", 0.1),
        fadeInTime    = secs(sKey .. "#fadeInTime",    1.0),
        fadeOutTime   = secs(sKey .. "#fadeOutTime",   1.0),
        planeFadeTime = secs(sKey .. "#planeFadeTime", 1.0),
        startDelay    = secs(sKey .. "#startDelay",    0.0),
        stopDelay     = secs(sKey .. "#stopDelay",     0.0),
    }
    ep.smoke = {
        fadeInTime    = secs(mKey .. "#fadeInTime",    1.0),
        fadeOutTime   = secs(mKey .. "#fadeOutTime",   1.0),
        planeFadeTime = secs(mKey .. "#planeFadeTime", 1.0),
        startDelay    = secs(mKey .. "#startDelay",    0.1),
        stopDelay     = secs(mKey .. "#stopDelay",     0.1),
        alignToWorldY = xmlFile:getBool(mKey .. "#alignToWorldY", true),
    }
    return ep
end

-- Fallback set used when a build site has no <effects> block to read from
-- (the legacy single effect resolved by node name). Identical to the values
-- hardcoded before 1.0.0.10.3.
function SlurryPipeManager.defaultEffectParams()
    return {
        stream = { maxBending = 0.8, extraDistance = 0.1, fadeInTime = 1000,
                   fadeOutTime = 1000, planeFadeTime = 1000,
                   startDelay = 0, stopDelay = 0 },
        smoke  = { fadeInTime = 1000, fadeOutTime = 1000, planeFadeTime = 1000,
                   startDelay = 100, stopDelay = 100, alignToWorldY = true },
    }
end

function SlurryPipeManager:findVehicleConfigForVehicle(vehicle)
    SlurryPipeManager.log("findVehicleConfigForVehicle: %s", tostring(vehicle and vehicle.configFileName))
    if vehicle.configFileName == nil then return nil end

    -- Embedded config check: does the vehicle's own XML carry a <slurryPipeSystem>
    -- element? If so, the vehicle is self-contained and overrides any internal
    -- manifest match. This is what lets third-party modders ship SPS-ready
    -- vehicles that include their own couplers, animations, and node references
    -- without ever touching the SPS mod folder.
    -- Do NOT query vehicle.xmlFile here. By onFinishedLoading its underlying C
    -- handle can already be released while the Lua wrapper is still non-nil
    -- (XMLFile:delete does not nil the table), so vehicle.xmlFile:hasProperty()
    -- throws "Unknown entity id ... for 'object' in method 'hasXMLProperty'".
    -- Load a fresh handle we own from the vehicle's own config file (guaranteed
    -- valid), query it, delete it. nil schema is fine: hasProperty forwards
    -- straight to hasXMLProperty and needs no schema.
    local embeddedXml = XMLFile.loadIfExists("spsEmbeddedSlurryCheck", vehicle.configFileName, nil)
    if embeddedXml ~= nil then
        local isEmbedded = embeddedXml:hasProperty("vehicle.slurryPipeSystem")
        embeddedXml:delete()
        if isEmbedded then
            SlurryDebug.log("findVehicleConfigForVehicle: embedded <slurryPipeSystem> found in " .. tostring(vehicle.configFileName))
            return {
                xmlFilePath  = vehicle.configFileName,    -- used for nodeTree path resolution
                xmlKeyPrefix = "vehicle.",                -- prepended to every "slurryPipeSystem..." read
                isEmbedded   = true,
            }
        end
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


-- ---------------------------------------------------------------------------
-- [SPS PERF 1.0.0.9.1] Cached front for findVehicleConfigForVehicle.
-- The finder is a pure function of vehicle.configFileName (manifest + embedded
-- XML checks are fixed for the whole session), yet it is invoked from per-frame
-- and per-tick paths (FillTrigger/LoadTrigger hooks in init.lua, the discharge
-- gates in ManureBarrelOverride) — and every call loaded + parsed the vehicle's
-- XML from disk via XMLFile.loadIfExists. On dedicated servers with vehicles in
-- fill triggers this stalled the main thread every tick (reported as ~45 km/h
-- speed caps + steering lag). Results are now cached per configFileName;
-- `false` marks a cached negative. Never invalidated: the config set is static
-- after load. Purely additive — the original function above is untouched and
-- still does the real work on first sight of each configFileName.
-- ---------------------------------------------------------------------------
SlurryPipeManager._findVehicleConfigUncached = SlurryPipeManager.findVehicleConfigForVehicle
function SlurryPipeManager:findVehicleConfigForVehicle(vehicle)
    if vehicle == nil or vehicle.configFileName == nil then
        return SlurryPipeManager._findVehicleConfigUncached(self, vehicle)
    end
    local cache = self._vehicleCfgCache
    if cache == nil then
        cache = {}
        self._vehicleCfgCache = cache
    end
    local hit = cache[vehicle.configFileName]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    local config = SlurryPipeManager._findVehicleConfigUncached(self, vehicle)
    if config == nil then
        cache[vehicle.configFileName] = false
    else
        cache[vehicle.configFileName] = config
    end
    return config
end

function SlurryPipeManager:findPlaceableConfigForPlaceable(placeable)
    SlurryPipeManager.log("findPlaceableConfigForPlaceable: %s", tostring(placeable and placeable.configFileName))
    if placeable.configFileName == nil then return nil end

    -- Embedded config check: does the placeable's own XML carry a
    -- <slurryPipeSystem> element? See findVehicleConfigForVehicle for rationale.
    -- See findVehicleConfigForVehicle for rationale: placeable.xmlFile's handle can
    -- be dead by the time we run while the Lua wrapper is still non-nil, which crashes
    -- hasProperty. Load a fresh owned handle from the placeable's config file instead.
    local embeddedXml = XMLFile.loadIfExists("spsEmbeddedPlaceableSlurryCheck", placeable.configFileName, nil)
    if embeddedXml ~= nil then
        local isEmbedded = embeddedXml:hasProperty("placeable.slurryPipeSystem")
        embeddedXml:delete()
        if isEmbedded then
            SlurryDebug.log("findPlaceableConfigForPlaceable: embedded <slurryPipeSystem> found in " .. tostring(placeable.configFileName))
            return {
                xmlFilePath  = placeable.configFileName,
                xmlKeyPrefix = "placeable.",
                isEmbedded   = true,
            }
        end
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
    SlurryPipeManager.log("registerVehicle: enter %s", tostring(vehicle and vehicle.configFileName))
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

    -- [SPS 1.0.0.9.24] Per-config coupler animation definitions: an optional
    -- <couplerAnimations> block inside THIS config's xml (same format as
    -- configs/couplerAnimations.xml). nil when absent. Passed into every
    -- bind() below so third-party configs can define their own animations
    -- without editing SPS files; local ids shadow global ids for this
    -- config's couplings only.
    local localAnimLibrary = nil
    if SPSCouplerAnimator ~= nil and SPSCouplerAnimator.parseLocal ~= nil then
        localAnimLibrary = SPSCouplerAnimator.parseLocal(xmlFile, kp .. "slurryPipeSystem.")
    end

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
    end
    -- Normalise / validate.
    if resolvedPumpType ~= "vacuum" and resolvedPumpType ~= "HVP"
       and resolvedPumpType ~= "conduit" and resolvedPumpType ~= "openTop" then
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
            if root == nil or root == 0 or not entityExists(root) then return nil end
            if getName(root) == targetName then return root end
            for i = 0, getNumOfChildren(root) - 1 do
                local found = searchTree(getChildAt(root, i), targetName)
                if found ~= nil then return found end
            end
            return nil
        end
        return searchTree(vehicle.rootNode, name)
    end

    -- Surface height reference (opaque tanks have no fill volume to read a head
    -- from). Two authored nodes mark the slurry surface at empty and at full; the
    -- live world surface Y is lerp(emptyNode.y, fullNode.y, fillLevel/capacity).
    -- Resolved by name from the vehicle tree (moves with the vehicle, so it stays
    -- tilt-correct). Used by head equalisation; preferred over a fill volume when
    -- present so both sides of a coupling measure head the same way.
    do
        local emptyName = xmlFile:getString(kp .. "slurryPipeSystem.surfaceRef#emptyNode")
        local fullName  = xmlFile:getString(kp .. "slurryPipeSystem.surfaceRef#fullNode")
        if emptyName ~= nil and fullName ~= nil then
            local en = findLinkedNode(emptyName)
            local fn = findLinkedNode(fullName)
            if en ~= nil and fn ~= nil then
                entry.surfaceRef = { emptyNode = en, fullNode = fn }
                SlurryPipeManager.log("registerVehicle: surfaceRef resolved empty='%s' full='%s' on %s",
                    tostring(emptyName), tostring(fullName), tostring(vehicle.configFileName))
            else
                SlurryPipeManager.log("registerVehicle: surfaceRef names NOT found (empty='%s'->%s full='%s'->%s) on %s",
                    tostring(emptyName), tostring(en), tostring(fullName), tostring(fn), tostring(vehicle.configFileName))
            end
        end
    end

    -- Embedded i3d support: when no separate nodeTree.i3d is declared, the effect
    -- nodes ("effect" / "pipeEffectSmoke") are authored directly in the vehicle's
    -- own i3d. They were never resolved in that case (effectNode/smokeNode only get
    -- set inside the nodeTree block above), so the streaming effect was skipped.
    -- Resolve them here by name from the vehicle tree as a fallback. Names must be
    -- unique in the vehicle i3d (searchTree returns the first depth-first hit).
    if entry.effectNode == nil then
        entry.effectNode = findLinkedNode("effect")
    end
    if entry.smokeNode == nil then
        entry.smokeNode = findLinkedNode("pipeEffectSmoke")
    end
    if entry.nodeTreeRoot == nil and (entry.effectNode ~= nil or entry.smokeNode ~= nil) then
        SlurryPipeManager.logMP(string.format("[SPS] embedded pipe effect nodes resolved from vehicle i3d (effect=%s smoke=%s) for %s",
            tostring(entry.effectNode), tostring(entry.smokeNode), tostring(vehicle.configFileName)))
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

    -- configIndexMatches: true when the 0-based activeIndex appears in a
    -- comma-separated list of indices (e.g. "1,2,3"; whitespace tolerant). Used by
    -- the fillArm primary/secondary, pipeCoupling and rubberBootPort config gates.
    local function configIndexMatches(indexStr, activeIndex)
        if indexStr == nil or activeIndex == nil then return false end
        for token in string.gmatch(indexStr, "[^,]+") do
            local n = tonumber((token:gsub("%s+", "")))
            if n ~= nil and n == activeIndex then
                return true
            end
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

        -- Optional SECONDARY config gate. The primary gate above allows only one
        -- configType per arm; this adds a second condition so one arm can depend on
        -- a different config as well (e.g. bare PT arm only when NO suction head).
        --   #configType2  : second configuration name (e.g. "design6")
        --   #configIndex2 : 0-based active index(es), comma-separated (e.g. "1,2")
        --   #configMode2  : "require" (default) keep only when index2 matches;
        --                   "exclude" drop when index2 matches
        local cfg2Str = xmlFile:getString(armKey .. "#configIndex2")
        if cfg2Str ~= nil then
            local cfg2Type = xmlFile:getString(armKey .. "#configType2", "cylindered")
            local cfg2Mode = xmlFile:getString(armKey .. "#configMode2", "require")
            local active2  = getActiveConfigIndex(cfg2Type)
            if active2 ~= nil then
                local matches2 = configIndexMatches(cfg2Str, active2)
                if (cfg2Mode == "exclude" and matches2)
                or (cfg2Mode ~= "exclude" and not matches2) then
                    SlurryDebug.log(string.format(
                        "fillArm id=%s dropped by secondary gate (configType2=%s index2=%s mode=%s active2=%s)",
                        tostring(armId), tostring(cfg2Type), tostring(cfg2Str),
                        tostring(cfg2Mode), tostring(active2)))
                    armIndex = armIndex + 1
                    continue
                end
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
                armIndex = armIndex + 1
                continue
            end
        elseif tipType == SPS_TIP_TYPE_OPEN_PIT then
            armEntry.centreNode = findLinkedNode(xmlFile:getString(armKey .. "#centreNodeName"))
            if armEntry.centreNode == nil then
                armIndex = armIndex + 1
                continue
            end
        elseif tipType == SPS_TIP_TYPE_RUBBER_BOOT_PIT then
            armEntry.tipNode    = findLinkedNode(xmlFile:getString(armKey .. "#tipNodeName"))
            armEntry.centreNode = findLinkedNode(xmlFile:getString(armKey .. "#centreNodeName"))
            if armEntry.tipNode == nil and armEntry.centreNode == nil then
                armIndex = armIndex + 1
                continue
            end
        end

        -- Optional per-arm embedded pipe effect. Resolves an effect transform node
        -- (its child(0) is the PipeEffect shape) and a smoke node from the vehicle's
        -- own i3d by the names declared in the arm's <effects> block. Only the node
        -- names are read here; the actual PipeEffect/ShaderPlaneEffect is built later
        -- once the effect classes and materials are available. Additive: arms with no
        -- <effects> block simply have no per-arm stream.
        local armEffectKey = armKey .. ".effects"
        if xmlFile:hasProperty(armEffectKey) then
            local eName = xmlFile:getString(armEffectKey .. ".effectNode(0)#effectNode")
            local sName = xmlFile:getString(armEffectKey .. ".effectNode(1)#effectNode")
            local eNode = findLinkedNode(eName)
            local sNode = findLinkedNode(sName)
            if eNode ~= nil and sNode ~= nil then
                armEntry.effectNode = eNode
                armEntry.smokeNode  = sNode
                -- [SPS 1.0.0.10.3] Per-arm effect timing/shaping, read from this
                -- arm's own <effects> block. Held on the arm entry so two arms on
                -- one tanker can differ, and consumed by buildSpsPipeEffectSet.
                armEntry.effectParams = SlurryPipeManager.readEffectParams(xmlFile, armEffectKey)
            end
        end

        table.insert(entry.armEntries, armEntry)
        armIndex = armIndex + 1
    end

    -- Embedded detection nodes: a node authored in the vehicle's own i3d sits inside a
    -- container named after the arm it belongs to (e.g. SPS_fillArmCentre02 under a
    -- "turretPTArm04" container). That container is a static authoring copy, so the
    -- node never moves. Relink each detection node under the LIVE arm of the same name,
    -- so it follows the real moving arm. World position is preserved so the node stays
    -- where authored. No XML/nodeTree declaration is needed; the container name drives
    -- it. Nodes whose name has no matching live arm (chassis couplers) are left alone.
    --
    -- The live-arm search must be DETERMINISTIC and IDEMPOTENT: arm names are duplicated
    -- (real arm + SPS authoring copy + effect copy), and registerVehicle re-runs on
    -- every config change. So we reject any candidate that lives under an "SPS_*" or
    -- "pipeEffects" subtree (walking its ancestors). That always resolves to the real
    -- moving arm, and re-running simply relinks the node onto the same arm it is already
    -- under (a no-op) instead of flipping it back onto a static copy.
    do
        local function isAuthoringCopy(node)
            local p = node
            while p ~= nil and p ~= 0 do
                local nm = getName(p)
                if nm == "pipeEffects" or (nm ~= nil and nm:sub(1, 4) == "SPS_") then
                    return true
                end
                p = getParent(p)
            end
            return false
        end
        local relinked = {}
        local function relinkUnderNamedArm(spsNode)
            if spsNode == nil or relinked[spsNode] or not entityExists(spsNode) then return end
            local container = getParent(spsNode)
            if container == nil then return end
            local armName = getName(container)
            local live = nil
            local function search(root)
                if live ~= nil or root == nil then return end
                if getName(root) == armName and not isAuthoringCopy(root) then
                    live = root
                    return
                end
                for i = 0, getNumOfChildren(root) - 1 do
                    search(getChildAt(root, i))
                end
            end
            search(vehicle.rootNode)
            if live ~= nil then
                -- Pose-INDEPENDENT re-seat. The authoring container is a static copy of
                -- the arm in its REST pose, so the node's LOCAL transform relative to that
                -- container already encodes the correct arm-relative offset. Capture that
                -- local transform and re-apply it under the live arm. We do NOT read the
                -- live arm's current world pose here.
                --
                -- Why this matters: Cylindered:onPostLoad restores a savegame's moved arm
                -- BEFORE Vehicle:onFinishedLoading (where this relink runs). The previous
                -- worldToLocal(live, authoredWorld) baked whatever pose the arm held at
                -- relink time, so on reload the node was seated at the rest-pose world spot
                -- relative to the moved arm (node snapped to zero while the arm sat in its
                -- saved position). Preserving the authored local transform is invariant to
                -- the live arm's pose, so fresh and reloaded sessions both seat correctly.
                local lx, ly, lz = getTranslation(spsNode)
                local rx, ry, rz = getRotation(spsNode)
                removeFromPhysics(spsNode)
                link(live, spsNode)
                addToPhysics(spsNode)
                setTranslation(spsNode, lx, ly, lz)
                setRotation(spsNode, rx, ry, rz)
                relinked[spsNode] = true
            end
        end
        for _, ae in ipairs(entry.armEntries) do
            relinkUnderNamedArm(ae.tipNode)
            relinkUnderNamedArm(ae.centreNode)
            -- Per-arm embedded pipe effect/smoke transforms are authored under
            -- pipeEffects containers named after the live arm parts. Relink them the
            -- same way so the stream tracks the arm (the PipeEffect is built off the
            -- node's child shape, so it follows once the transform is re-parented).
            relinkUnderNamedArm(ae.effectNode)
            relinkUnderNamedArm(ae.smokeNode)
        end
    end


    -- Load fill arm effects from the effect nodes (separate nodeTree.i3d OR, for an
    -- embedded config, the vehicle's own i3d — resolved above). Gate on the effect
    -- nodes existing rather than on a nodeTree file being present, so embedded
    -- configs build the same effect. The inner effectNode/smokeNode nil-check is
    -- unchanged and still guards the actual build.
    entry.pipeEffects = nil
    -- Build helper (additive): assembles one PipeEffect + ShaderPlaneEffect pair for
    -- a given effect/smoke node pair and returns the {pe, se} list. Called once for
    -- the legacy single effect (entry.effectNode/smokeNode) and once per arm that
    -- declares its own embedded <effects> nodes, so a tanker can show more than one
    -- stream (one per arm variant).
    -- [SPS 1.0.0.10.3] effectParams supplies every timing/shaping value that used
    -- to be hardcoded here. nil is accepted and falls back to the old constants,
    -- so an arm with no <effects> attributes is unchanged.
    local function buildSpsPipeEffectSet(effectNode, smokeNode, effectParams)
        if not vehicle.isClient then return nil end
        local ep = effectParams or SlurryPipeManager.defaultEffectParams()
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
            pe.maxBending    = ep.stream.maxBending
            pe.extraDistance = ep.stream.extraDistance
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
            pe.fadeInTime    = ep.stream.fadeInTime
            pe.fadeOutTime   = ep.stream.fadeOutTime
            pe.startDelay    = ep.stream.startDelay
            pe.stopDelay     = ep.stream.stopDelay
            pe.currentDelay  = ep.stream.startDelay
            pe.state         = ShaderPlaneEffect.STATE_OFF
            pe.planeFadeTime = ep.stream.planeFadeTime
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
            se.fadeInTime    = ep.smoke.fadeInTime
            se.fadeOutTime   = ep.smoke.fadeOutTime
            se.startDelay    = ep.smoke.startDelay
            se.stopDelay     = ep.smoke.stopDelay
            se.currentDelay  = ep.smoke.startDelay
            se.state         = ShaderPlaneEffect.STATE_OFF
            se.planeFadeTime = ep.smoke.planeFadeTime
            se.fadeCur = { -1, 1 }
            se.fadeDir = { 1, 1 }
            se.fadeX   = { -1, 1 }
            se.fadeY   = { -1, 1 }
            se.alignToWorldY  = ep.smoke.alignToWorldY
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
            return effects
        end
        return nil
    end

    -- Hide every declared per-arm effect mesh once at registration, INDEPENDENT of
    -- the config gate. Embedded effect meshes live in the vehicle's own i3d and are
    -- present in every config (and in the shop), so they are visible by default until
    -- something hides them. The per-arm build below only hides the arm that is
    -- currently gated-in (and only on a client), so we sweep all fillArm <effects>
    -- blocks here (no gate, no client check) and hide the stream shape (child 0 of the
    -- effect transform, matching pe.node) plus the smoke node. The streaming code
    -- re-shows them on demand. Mirrors how the legacy single-effect build hides the
    -- base tanker's one mesh unconditionally.
    do
        local hideArmIndex = 0
        while true do
            local hKey = string.format(kp .. "slurryPipeSystem.fillArms.fillArm(%d)", hideArmIndex)
            if not xmlFile:hasProperty(hKey) then break end
            local hEffKey = hKey .. ".effects"
            if xmlFile:hasProperty(hEffKey) then
                local eNode = findLinkedNode(xmlFile:getString(hEffKey .. ".effectNode(0)#effectNode"))
                local sNode = findLinkedNode(xmlFile:getString(hEffKey .. ".effectNode(1)#effectNode"))
                if eNode ~= nil and entityExists(eNode) and getNumOfChildren(eNode) > 0 then
                    setVisibility(getChildAt(eNode, 0), false)
                end
                if sNode ~= nil and entityExists(sNode) then
                    setVisibility(sNode, false)
                end
            end
            hideArmIndex = hideArmIndex + 1
        end
    end

    -- Legacy single effect (separate nodeTree.i3d, or embedded effect/pipeEffectSmoke
    -- resolved by name above). Unchanged behaviour.
    if entry.effectNode ~= nil and entry.smokeNode ~= nil and #entry.armEntries > 0 then
        -- [SPS 1.0.0.10.3] The legacy single effect resolves its nodes by name
        -- ("effect" / "pipeEffectSmoke") rather than from an <effects> block, so
        -- there was nowhere to author its timing. An OPTIONAL top-level
        -- <slurryPipeSystem><effects> block is now honoured for exactly that;
        -- absent, the previous hardcoded values are used unchanged.
        local legacyKey = kp .. "slurryPipeSystem.effects"
        local legacyParams = xmlFile:hasProperty(legacyKey)
            and SlurryPipeManager.readEffectParams(xmlFile, legacyKey)
            or  SlurryPipeManager.defaultEffectParams()
        entry.pipeEffects = buildSpsPipeEffectSet(entry.effectNode, entry.smokeNode, legacyParams)
    end

    -- Per-arm effects (embedded i3d): each arm that resolved its own effect/smoke
    -- nodes gets an independent stream, so multiple arms on one tanker can each emit.
    for _, armE in ipairs(entry.armEntries) do
        if armE.effectNode ~= nil and armE.smokeNode ~= nil then
            armE.pipeEffects = buildSpsPipeEffectSet(armE.effectNode, armE.smokeNode,
                armE.effectParams)
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
                -- [SPS] Per-coupler fillType restriction (e.g. BGA500's separate
                -- LIQUIDMANURE / DIGESTATE couplers on one shared storage). nil = no
                -- restriction declared in XML = unchanged legacy behaviour.
                fillType            = (function()
                    local ftName = xmlFile:getString(cKey .. "#fillType")
                    if ftName == nil then return nil end
                    return g_fillTypeManager:getFillTypeIndexByName(ftName)
                end)(),
                -- [SPS 1.0.0.9.25] Optional hydraulic head node: the highest point
                -- of this coupler's pipework. When present, gravity/head
                -- equalisation only flows while the DRIVING surface is above this
                -- node (a crest gravity cannot beat — no siphon for slurry).
                -- Absent = nil = no gate = unchanged legacy behaviour. Pumped
                -- (pressure) flow ignores it entirely.
                headHeightNode      = findLinkedNode(xmlFile:getString(cKey .. "#headHeightNodeName")),
            }
            -- Bind coupler animations if either id is declared on this coupling.
            if SPSCouplerAnimator ~= nil
            and (couplingEntry.connectorAnimationId ~= nil or couplingEntry.valveAnimationId ~= nil) then
                SPSCouplerAnimator.ensureLoaded(self.modDirectory)
                if couplingEntry.connectorAnimationId ~= nil then
                    couplingEntry.connectorAnim = SPSCouplerAnimator.bind(couplingEntry.mountNode, couplingEntry.connectorAnimationId, localAnimLibrary)
                end
                if couplingEntry.valveAnimationId ~= nil then
                    couplingEntry.valveAnim = SPSCouplerAnimator.bind(couplingEntry.mountNode, couplingEntry.valveAnimationId, localAnimLibrary)
                end
                SlurryPipeManager.log("sprayer bind DIAG (vehicle): id=%s connIds=%s/%s bound=%s/%s",
                    tostring(couplingEntry.id), tostring(couplingEntry.connectorAnimationId), tostring(couplingEntry.valveAnimationId),
                    tostring(couplingEntry.connectorAnim ~= nil), tostring(couplingEntry.valveAnim ~= nil))
            end
            table.insert(entry.couplingEntries, couplingEntry)
        else
        end
        couplingIndex = couplingIndex + 1
    end

    -- Blockage nodes (dribble bar / spreader). Each may optionally name an animation,
    -- read here and played on block/clear if present, skipped if absent. A node named
    -- *Macerator is the central distributor: blocking it stops the whole bar. The
    -- macerator and centre node share a spot, so they are never both flagged.

    -- [SPS BLOCKAGE v1.0.0.10.4] Optional per-vehicle blockage tuning, authored as
    -- attributes on the <blockageNodes> CONTAINER (not on individual nodes, since
    -- these describe the bar as a whole). Every attribute is optional; anything
    -- absent falls back to the global default, so existing configs load unchanged
    -- and this whole block is inert unless a modder opts in. Values are clamped so a
    -- typo cannot produce a bar that clogs every roll or never clogs at all.
    local btKey = kp .. "slurryPipeSystem.blockageNodes"
    if xmlFile:hasProperty(btKey) then
        local function readTune(attr, default, lo, hi)
            local v = xmlFile:getFloat(btKey .. "#" .. attr)
            if v == nil then return default end
            return math.max(lo, math.min(hi, v))
        end
        entry.blockageTuning = {
            baseChance        = readTune("baseChance",        nil, 0.0, 1.0),
            maceratorCrustMin = readTune("maceratorCrustMin", nil, 0.0, 1.0),
            maceratorChance   = readTune("maceratorChance",   nil, 0.0, 1.0),
            outletCrustMin    = readTune("outletCrustMin",    nil, 0.0, 1.0),
            outletCrustMinRaw = readTune("outletCrustMinRaw", nil, 0.0, 1.0),
            outletChance      = readTune("outletChance",      nil, 0.0, 1.0),
            dmBonus           = readTune("dmBonus",           nil, 0.0, 10.0),
        }
    end

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
                blockageIndex = blockageIndex + 1
                continue
            end
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
                            end
                        else
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

        -- Optional config gate (mirrors fillArm/pipeCoupling). #cylinderedConfigIndex
        -- is the 0-based active index(es) (comma list ok); #configType names the
        -- configuration (default "cylindered"). Lets a boot port be hidden unless its
        -- config is fitted (e.g. design8 dockingFunnelStation). Additive: ports with
        -- no gate attr behave exactly as before (always present).
        local rbpCfgIndexStr = xmlFile:getString(rbpKey .. "#cylinderedConfigIndex")
        if rbpCfgIndexStr ~= nil then
            local cfgType     = xmlFile:getString(rbpKey .. "#configType", "cylindered")
            local activeIndex = getActiveConfigIndex(cfgType)
            if activeIndex ~= nil and not configIndexMatches(rbpCfgIndexStr, activeIndex) then
                rbpIndex = rbpIndex + 1
                continue
            end
        end

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
	
    -- [SPS MIXED INTEROP] Keep the vanilla FillTrigger ENABLED.
    -- A vehicle's fillTrigger has sourceObject = itself, so it is the vanilla path by
    -- which ANOTHER vehicle loads FROM this one (R prompt via addFillUnitTrigger, and
    -- fillVehicle pumps source->vehicle). Setting isEnabled=false early-outs
    -- fillTriggerCallback for every entering vehicle, so no one — including plain
    -- non-SPS tankers — can load from an SPS vessel (e.g. the FRC65 nurse tank).
    -- Per-fillable gating is already done by the init.lua FillTrigger hook
    -- (getIsActivatable/fillVehicle keyed on spsBlocksFillable): SPS fillables are
    -- blocked and must use the pipe/arm, while non-SPS and AI pass through. Leaving the
    -- trigger enabled therefore restores non-SPS R-loading without letting SPS players
    -- bypass the pipe system.
    if vehicle.spec_fillTriggerVehicle ~= nil
    and vehicle.spec_fillTriggerVehicle.fillTrigger ~= nil then
        vehicle.spec_fillTriggerVehicle.fillTrigger.isEnabled = true
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
            -- Inject the SPS nodeTree node into vehicle.i3dMappings so
            -- loadSampleFromXML can resolve the engineLoop linkNode (e.g.
            -- exhaustNode). That node lives in the injected SPS nodeTree, not the
            -- vehicle's own i3d, so the vanilla name lookup would otherwise fail
            -- and the engine logs "Index not found: <linkNode>". Mirrors the
            -- sibling registration path. The mapping value must be a table
            -- { nodeId, rootNode }; a bare integer is treated as a child-index path.
            if vehicle.i3dMappings ~= nil then
                local linkNodeName = xmlFile:getString(soundKey .. "#linkNode")
                if linkNodeName ~= nil then
                    local foundNode = findLinkedNode(linkNodeName)
                    if foundNode ~= nil then
                        vehicle.i3dMappings[linkNodeName] = { nodeId = foundNode, rootNode = vehicle.rootNode }
                    end
                end
            end
            entry.engineLoopSample = g_soundManager:loadSampleFromXML(
                xmlFile, kp .. "slurryPipeSystem.sounds", "engineLoop",
                vehicle.baseDirectory, vehicle.components, 0,
                AudioGroup.VEHICLE, vehicle.i3dMappings, vehicle)
            if entry.engineLoopSample ~= nil then
            else
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
    -- [SPS CRUST v1.0.0.10.2] Per-vehicle mixing speed. 1.0 = baseline
    -- (CRUST_MIX_HOURS to clear a full crust); 2.0 = twice as fast, i.e. half the
    -- time. Clamped on read so a bad XML value cannot make mixing instantaneous.
    entry.agitatorCrustMix = SlurryPipeManager.clampCrustMult(
        xmlFile:getFloat(kp .. "slurryPipeSystem.agitator#crustMix", 1.0))
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

        -- [SPS 1.0.0.9.13] Restore WATER levels that vanilla discarded during
        -- savegame load (see _saveVehicleWaterLevels). Server-side; matched by
        -- saved position + fillUnit index, applied only to a unit that came up
        -- empty. Clients receive the level via the normal fillUnit sync.
        if g_server ~= nil and self._pendingVehicleWater ~= nil
        and #self._pendingVehicleWater > 0 and vehicle.rootNode ~= nil then
            local vx, _, vz = getWorldTranslation(vehicle.rootNode)
            for i = #self._pendingVehicleWater, 1, -1 do
                local p = self._pendingVehicleWater[i]
                local dx, dz = p.x - vx, p.z - vz
                if dx*dx + dz*dz <= 1.0 then
                    local cur = vehicle:getFillUnitFillLevel(p.fui) or 0
                    if cur <= 0.001 and p.level > 0.001 then
                        local applied = vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), p.fui, p.level, FillType.WATER, ToolType.TRIGGER, nil)
                        SlurryPipeManager.log("registerVehicle[%s]: restored WATER %.1f l (applied %.1f) to fillUnit %d",
                            tostring(vehicle.configFileName), p.level, applied or 0, p.fui)
                    end
                    table.remove(self._pendingVehicleWater, i)
                end
            end
        end
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
    SlurryPipeManager.log("unregisterVehicle: enter %s", tostring(vehicle and vehicle.configFileName))
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
            -- Per-arm embedded effects
            if entry.armEntries ~= nil then
                for _, armE in ipairs(entry.armEntries) do
                    if armE.pipeEffects ~= nil then
                        g_effectManager:deleteEffects(armE.pipeEffects)
                        armE.pipeEffects = nil
                    end
                end
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
    SlurryPipeManager.log("registerPlaceable: enter %s", tostring(placeable and placeable.configFileName))
    -- [SPS MP 1.0.0.9.2] Dedupe guard (handover item 4): a store registering twice
    -- on one machine (loadMap + finalizePlacement race / JIP re-walk) created a
    -- second coupling-table generation; store-valve/crust/disconnect lookups then
    -- resolved the stale generation and that machine kept ghost pipes. One entry
    -- per placeable, ever.
    for _, existing in ipairs(self.registeredPlaceables) do
        if existing.placeable == placeable then
            SlurryPipeManager.log("registerPlaceable: duplicate suppressed for %s", tostring(placeable and placeable.configFileName))
            return
        end
    end
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

    -- [SPS 1.0.0.9.24] Per-config coupler animation definitions — see
    -- registerVehicle. Makes the <couplerAnimations> block inside a
    -- third-party placeable's own xml (as shipped in the cow shed example)
    -- actually functional.
    local localAnimLibrary = nil
    if SPSCouplerAnimator ~= nil and SPSCouplerAnimator.parseLocal ~= nil then
        localAnimLibrary = SPSCouplerAnimator.parseLocal(xmlFile, kp .. "slurryPipeSystem.")
    end

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
        end
    end

    
    -- [SPS 1.0.0.9.11] Manifest tails no longer carry the mod-folder name
    -- (players rename downloaded map folders at will), so a placeable from a
    -- DIFFERENT map with the same relative path can path-match. Verify the
    -- match by outcome: a bundled (non-embedded) config whose nodeTree linked
    -- ZERO nodes hit the wrong placeable — bail before hideNodes, couplings or
    -- state touch it. Embedded configs are self-owned and never bail here.
    if not config.isEmbedded and #linkedNodes == 0 then
        SlurryPipeManager.log("registerPlaceable: config path-matched %s but no nodeTree targets exist — wrong placeable, skipping",
            tostring(placeable.configFileName))
        if xmlFileOwned then xmlFile:delete() end
        return
    end

    local function findLinkedNode(name)
        if name == nil or name == "" then return nil end
        for _, n in ipairs(linkedNodes) do
            if getName(n) == name then return n end
        end
        -- [SPS] Embedded-i3d fallback. Two authoring styles are supported:
        --   (1) nodeTree + fillPoints.xml: SPS nodes are loaded from a separate
        --       nodeTree.i3d and linked onto the placeable, collected in linkedNodes
        --       (the loop above resolves them). This is the baseTank path.
        --   (2) own-folder placeable: the SPS nodes are baked into the placeable's
        --       OWN i3d and its own <slurryPipeSystem> xml, so no nodeTree is loaded
        --       and linkedNodes is empty. In that case resolve the requested name by
        --       searching the placeable's own component tree (same approach already
        --       used by hideNodes below). Only reached on a linkedNodes miss, so the
        --       nodeTree path (1) is unchanged.
        if placeable.components ~= nil then
            local function searchByName(node)
                if node == nil or node == 0 then return nil end
                if getName(node) == name then return node end
                for i = 0, getNumOfChildren(node) - 1 do
                    local found = searchByName(getChildAt(node, i))
                    if found ~= nil then return found end
                end
                return nil
            end
            for _, comp in ipairs(placeable.components) do
                if comp ~= nil and comp.node ~= nil and comp.node ~= 0 then
                    local hit = searchByName(comp.node)
                    if hit ~= nil then
                        SlurryDebug.log("findLinkedNode: resolved '" .. tostring(name)
                            .. "' from placeable i3d (embedded, no nodeTree)")
                        return hit
                    end
                end
            end
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
                end
            end
        end
        hideCollIndex = hideCollIndex + 1
    end

    local fillPlaneNode = xmlFile:getNode(kp .. "slurryPipeSystem.fillPlane#node", nil, placeable.components, placeable.i3dMappings)
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
        end
    elseif planeShape ~= nil then
    end

    -- [SPS 1.0.0.9.31] Multi-store placeables (<slurryStores>). Parsed BEFORE the
    -- legacy single <fillPlane> so store 1 can become the primary sourceEntry: every
    -- existing lookup, save path, coupler binding and HUD read then works unchanged
    -- against it, and the extra stores ride alongside in pEntry.storeSources.
    -- Returns nil when the block is absent, leaving the legacy path below untouched.
    local storeSources = nil
    if SlurryPipeManager.parseSlurryStores ~= nil then
        storeSources = self:parseSlurryStores(placeable, xmlFile, kp, findLinkedNode)
    end

    -- [SPS 1.0.0.10.3] <fillPlane> and <slurryStores> are alternatives, not
    -- companions. Declaring both was previously unguarded: the legacy crust block
    -- further down would re-parent the placeable-level crust mesh onto the singular
    -- fill plane while initStoreCrust re-parented store 1's crust mesh onto the
    -- store plane, leaving one mesh bound to a node the other owner also moves.
    -- <slurryStores> wins (it is the more specific declaration) and the singular
    -- block is ignored from here on, announced unconditionally so the config author
    -- sees it in a player log with no debug channels enabled.
    local legacyPlaneIgnored = false
    if storeSources ~= nil and #storeSources > 0 and fillPlaneNode ~= nil and fillPlaneNode ~= 0 then
        legacyPlaneIgnored = true
        print("[SPS WARNING] " .. tostring(placeable.configFileName)
            .. ": both <fillPlane> and <slurryStores> are declared. These are"
            .. " alternatives — <slurryStores> is being used and the singular"
            .. " <fillPlane> block (including its crust nodes) is ignored."
            .. " Remove <fillPlane> from this config.")
    end

    local sourceEntry = nil
    if storeSources ~= nil and #storeSources > 0 then
        sourceEntry = storeSources[1]
        SlurryDebug.log("registerPlaceable: " .. tostring(#storeSources) .. " slurryStore(s) on "
            .. tostring(placeable.configFileName) .. " — store 1 is primary")
    elseif fillPlaneNode ~= nil and (placeable.spec_silo ~= nil or placeable.spec_husbandry ~= nil or placeable.spec_siloExtension ~= nil) then
        sourceEntry = SlurryNodeUtil.buildStoragePlaneSource(placeable, fillPlaneNode, minY, maxY, fillType, planeBounds)
    elseif fillPlaneNode ~= nil and placeable.spec_productionPoint ~= nil then
        -- [SPS 1.0.0.9.31] A production point has no engine-driven fill plane: nothing
        -- in vanilla links its Storage levels to a plane node, so a plane authored via
        -- the legacy singular <fillPlane> block would sit frozen at its authored height
        -- and report a constant surface Y to arm detection. <slurryStores> exists for
        -- exactly this case (it drives the plane itself) — say so rather than silently
        -- building a broken source. Fall through to coupling-only so the couplers,
        -- which do not need a plane, keep working.
        print("[SPS WARNING] " .. tostring(placeable.configFileName)
            .. ": <fillPlane> is not supported on a production point because nothing drives"
            .. " the plane. Use <slurryStores><slurryStore .../></slurryStores> instead."
            .. " Continuing with coupling-only access.")
        local storage = nil
        if placeable.spec_productionPoint.productionPoint ~= nil
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
        end
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
    -- [SPS 1.0.0.9.26] Buying-station placeable (vanilla type "buyingStation",
    -- PlaceableBuyingStation/BuyingStation.lua — verified source): an infinite
    -- PAID source. No Storage object exists; the vanilla station performs the
    -- whole purchase (fill + per-litre charge + money HUD) inside
    -- addFillLevelToFillableObject, so the sourceEntry only carries the station
    -- handle plus the config-declared fillType. Pipe-only by construction: no
    -- fillPlane is authored, so fill arms can never detect or connect to it.
    if sourceEntry == nil and placeable.spec_buyingStation ~= nil
    and placeable.spec_buyingStation.buyingStation ~= nil then
        local bsFillTypeName = xmlFile:getString(kp .. "slurryPipeSystem.buyingStation#fillType", "LIQUIDMANURE")
        -- [SPS 1.0.0.9.27] Switchable sold type on ONE coupler: #fillTypes is a
        -- space-separated ordered cycle (e.g. "LIQUIDMANURE DIGESTATE") with
        -- optional #default selection. Legacy single #fillType still works
        -- (one-entry cycle = switch prompt never shows). The live selection is
        -- sourceEntry.fillType — _resolveSourceFillType and
        -- transferFillFromBuyingStation already read exactly that field, so the
        -- walk-up switch only ever mutates it (server-authoritative via
        -- SPSBuyStationEvent).
        local bsFillTypes = {}
        local bsTypesStr = xmlFile:getString(kp .. "slurryPipeSystem.buyingStation#fillTypes", nil)
        if bsTypesStr ~= nil then
            for ftName in bsTypesStr:gmatch("%S+") do
                local ftIdx = g_fillTypeManager:getFillTypeIndexByName(ftName)
                if ftIdx ~= nil then
                    table.insert(bsFillTypes, ftIdx)
                else
                    SlurryDebug.log("registerPlaceable: buyingStation#fillTypes unknown fillType '" .. tostring(ftName) .. "' ignored")
                end
            end
        end
        if #bsFillTypes == 0 then
            table.insert(bsFillTypes, g_fillTypeManager:getFillTypeIndexByName(bsFillTypeName) or FillType.LIQUIDMANURE)
        end
        local bsDefault = nil
        local bsDefaultStr = xmlFile:getString(kp .. "slurryPipeSystem.buyingStation#default", nil)
        if bsDefaultStr ~= nil then
            bsDefault = g_fillTypeManager:getFillTypeIndexByName(bsDefaultStr)
        end
        local bsSelected = bsFillTypes[1]
        if bsDefault ~= nil then
            for _, ftIdx in ipairs(bsFillTypes) do
                if ftIdx == bsDefault then bsSelected = bsDefault break end
            end
        end
        -- [SPS 1.0.0.9.28] SPS-extra sold types: fillTypes the vanilla station
        -- does NOT declare (e.g. WATER on a slurry well). The vanilla purchase
        -- path would crash on them (getEffectiveFillTypePrice indexes
        -- fillTypePricesScale, nil for undeclared types — verified source), so
        -- transferFillFromBuyingStation performs the SPS-side purchase for
        -- these with the same price maths, at the per-type #priceScale below
        -- (0 = free). Declared as child elements:
        --   <extraFillType name="WATER" priceScale="0.1"/>
        -- Extra types are appended to the switch cycle after #fillTypes.
        local bsExtraScales = {}
        local extraIdx = 0
        while true do
            local eKey = string.format(kp .. "slurryPipeSystem.buyingStation.extraFillType(%d)", extraIdx)
            if not xmlFile:hasProperty(eKey) then break end
            local eName = xmlFile:getString(eKey .. "#name", nil)
            local eIdx  = eName ~= nil and g_fillTypeManager:getFillTypeIndexByName(eName) or nil
            if eIdx ~= nil then
                local already = false
                for _, ftIdx in ipairs(bsFillTypes) do
                    if ftIdx == eIdx then already = true break end
                end
                if not already then
                    table.insert(bsFillTypes, eIdx)
                end
                bsExtraScales[eIdx] = xmlFile:getFloat(eKey .. "#priceScale", 1.0)
            else
                SlurryDebug.log("registerPlaceable: buyingStation.extraFillType unknown fillType '" .. tostring(eName) .. "' ignored")
            end
            extraIdx = extraIdx + 1
        end
        sourceEntry = {
            type       = SPS_SOURCE_TYPE_BUYING_STATION,
            placeable  = placeable,
            station    = placeable.spec_buyingStation.buyingStation,
            fillType   = bsSelected,
            fillTypes  = bsFillTypes,
            -- [SPS 1.0.0.9.28] fillType -> priceScale for SPS-extra sold types
            -- (empty when only vanilla-declared types are sold).
            extraPriceScales = bsExtraScales,
            -- Optional authored consistency for bought slurry. nil = no blend
            -- applied on fill (tank average unchanged) — see
            -- transferFillFromBuyingStation.
            thickness  = xmlFile:getFloat(kp .. "slurryPipeSystem.buyingStation#thickness", nil),
            crust      = xmlFile:getFloat(kp .. "slurryPipeSystem.buyingStation#crust", nil),
            debugLabel = tostring(placeable.configFileName):match("([^/]+)%.xml$") or "buyingStation",
        }
        SlurryDebug.log("registerPlaceable: buying-station sourceEntry for " .. tostring(placeable.configFileName)
            .. " (types=" .. tostring(#bsFillTypes) .. ")")
    end
    if sourceEntry ~= nil then
        table.insert(self.sourceEntries, sourceEntry)
    end
    -- [SPS 1.0.0.9.31] Stores 2..n are real sources too — an arm dipped in the second
    -- lagoon resolves through self.sourceEntries like any other. Store 1 is already in
    -- (it IS sourceEntry), so start at 2 and never double-insert it.
    if storeSources ~= nil then
        for i = 2, #storeSources do
            table.insert(self.sourceEntries, storeSources[i])
        end
    end

    -- [SPS 1.0.0.9.31] Couplers are built before pEntry exists, but store binding
    -- needs the same lookup pEntry would provide. A stub carrying just the two fields
    -- getStoreSources reads keeps that lookup on one code path instead of two.
    local pEntryStub = { storeSources = storeSources, sourceEntry = sourceEntry }

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
                -- [SPS 1.0.0.9.31] #storeId binds this coupler to one declared
                -- <slurryStore>, so a draw through it moves that lagoon's level and
                -- therefore that lagoon's plane. Omitted (or no stores declared) keeps
                -- the legacy behaviour of pointing at the placeable's primary source;
                -- the existing per-coupler #fillType restriction still applies on top,
                -- which is what lets a second coupler serve DIGESTATE off the same
                -- Storage with no store of its own.
                sourceEntry              = (function()
                    if storeSources == nil then return sourceEntry end
                    local declaredStoreId = xmlFile:getInt(cKey .. "#storeId", nil)
                    local declaredFtName  = xmlFile:getString(cKey .. "#fillType", nil)
                    local declaredFt      = declaredFtName ~= nil
                        and g_fillTypeManager:getFillTypeIndexByName(declaredFtName) or nil
                    return self:getStoreSourceForCoupling(pEntryStub, declaredStoreId, declaredFt)
                end)(),
                -- [SPS] Per-coupler fillType restriction (e.g. BGA500's separate
                -- LIQUIDMANURE / DIGESTATE couplers on one shared storage). nil = no
                -- restriction declared in XML = unchanged legacy behaviour.
                fillType                 = (function()
                    local ftName = xmlFile:getString(cKey .. "#fillType")
                    if ftName == nil then return nil end
                    return g_fillTypeManager:getFillTypeIndexByName(ftName)
                end)(),
                placeable                = placeable,
                deployable               = deployable,
                isDeployed               = not deployable,
                pipeEffects              = nil,
                inletDistance            = 1.5,
                effectPlaying            = false,
                undeployedVisibleNodes   = undeployedVisibleNodes,
                -- [SPS 1.0.0.9.25] Optional hydraulic head node for this store
                -- coupler: the highest point of the internal pipe run (e.g. a
                -- slurry tower's fill riser crest). REQUIRED for this coupler to
                -- take part in vehicle<->store head equalisation — a store
                -- coupler without it is ignored by equalisation exactly as all
                -- store couplers were before (pumped flow unaffected). Gravity
                -- flow through this coupler, in EITHER direction, only runs
                -- while the driving surface is above this node.
                headHeightNode           = findDeepLinkedNode(xmlFile:getString(cKey .. "#headHeightNodeName", nil)),
                -- [SPS 1.0.0.9.29] Optional lid link: saveId of a vanilla
                -- AnimatedObject on THIS placeable (modder's own <animatedObjects>
                -- section). When declared, SPS drives that object open on deploy /
                -- closed on undeploy (vanilla AnimatedObject self-syncs in MP), the
                -- coupler only connects while the lid is fully open, and the lid's
                -- walk-up trigger is locked while any linked coupler is deployed or
                -- connected. Absent = unchanged legacy deploy behaviour.
                deployAnimObjectSaveId   = xmlFile:getString(cKey .. "#deployAnimatedObjectSaveId", nil),
                deployAnimObject         = nil,   -- resolved lazily by SPSM_Couplers:getCouplingLidObject
                deployAnimObjectMissing  = false, -- warn-once latch when saveId doesn't resolve
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
                    sc.connectorAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.connectorAnimationId, localAnimLibrary)
                end
                if sc.valveAnimationId ~= nil then
                    sc.valveAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.valveAnimationId, localAnimLibrary)
                end
                SlurryPipeManager.log("sprayer bind DIAG (sc): id=%s connIds=%s/%s bound=%s/%s",
                    tostring(sc.id), tostring(sc.connectorAnimationId), tostring(sc.valveAnimationId),
                    tostring(sc.connectorAnim ~= nil), tostring(sc.valveAnim ~= nil))
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
            -- [SPS 1.0.0.10.3] Same per-config effect timing the vehicle side now
            -- reads, so a placeable inlet stream can be tuned independently too.
            local ep = xmlFile:hasProperty(cKey .. ".effects")
                and SlurryPipeManager.readEffectParams(xmlFile, cKey .. ".effects")
                or  SlurryPipeManager.defaultEffectParams()
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
                        pe.maxBending         = ep.stream.maxBending
                        pe.extraDistance      = ep.stream.extraDistance
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
                        pe.fadeInTime         = ep.stream.fadeInTime
                        pe.fadeOutTime        = ep.stream.fadeOutTime
                        pe.startDelay         = ep.stream.startDelay
                        pe.stopDelay          = ep.stream.stopDelay
                        pe.currentDelay       = ep.stream.startDelay
                        pe.state              = ShaderPlaneEffect.STATE_OFF
                        pe.planeFadeTime      = ep.stream.planeFadeTime
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
                        se.fadeInTime         = ep.smoke.fadeInTime
                        se.fadeOutTime        = ep.smoke.fadeOutTime
                        se.startDelay         = ep.smoke.startDelay
                        se.stopDelay          = ep.smoke.stopDelay
                        se.currentDelay       = ep.smoke.startDelay
                        se.state              = ShaderPlaneEffect.STATE_OFF
                        se.planeFadeTime      = ep.smoke.planeFadeTime
                        se.fadeCur            = { -1, 1 }
                        se.fadeDir            = { 1, 1 }
                        se.fadeX              = { -1, 1 }
                        se.fadeY              = { -1, 1 }
                        se.alignToWorldY      = ep.smoke.alignToWorldY
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
                    else
                    end
                else
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
        -- [SPS 1.0.0.9.31] Full store list for a <slurryStores> placeable; nil for
        -- every legacy one. getStoreSources(pEntry) hides the difference from callers.
        storeSources     = storeSources,
        storeCouplings   = storeCouplings,
        linkedNodes      = linkedNodes,
        hiddenNodes      = hiddenNodes,
        hiddenCollisions = hiddenCollisions,
        agitatorEnabled  = xmlFile:getBool(kp .. "slurryPipeSystem#agitator", false),
        -- [SPS CRUST v1.0.0.10.2] Per-store crusting speed. 1.0 = baseline
        -- (CRUST_GROW_HOURS from clean to fully crusted); 0.5 = a covered tank that
        -- crusts at half rate, 1.5 = an exposed open lagoon. Clamped on read.
        crustGrowMult    = SlurryPipeManager.clampCrustMult(
                               xmlFile:getFloat(kp .. "slurryPipeSystem#crustGrow", 1.0)),
        crustConfig      = SPSCrustVegetation ~= nil and SPSCrustVegetation.readConfig(xmlFile, kp) or nil,
        crustInstances   = nil,
        pipeAnimNode     = xmlFile:getNode(kp .. "slurryPipeSystem.pipeAnimNode#node", nil, placeable.components, placeable.i3dMappings),
        pipeAnimRX       = math.rad(xmlFile:getFloat(kp .. "slurryPipeSystem.pipeAnimNode#rx", 0)),
        pipeAnimRY       = math.rad(xmlFile:getFloat(kp .. "slurryPipeSystem.pipeAnimNode#ry", 0)),
        pipeAnimRZ       = math.rad(xmlFile:getFloat(kp .. "slurryPipeSystem.pipeAnimNode#rz", 0)),
        config           = config,
        xmlFileOwned     = xmlFileOwned,
    }
    table.insert(self.registeredPlaceables, pEntry)

    -- Fixed (placeable) PTO agitator: parse <fixedAgitator>, resolve its nodes
    -- off the same linkedNodes, install the vehicle-detection trigger, and add
    -- the walk-up connect/disconnect activatable. Must run before xmlFile:delete.
    if SPSFixedAgitator ~= nil then
        SPSFixedAgitator.initForPlaceable(self, pEntry, xmlFile, kp, linkedNodes)
        if pEntry.fixedAgitator ~= nil and SPSFixedAgitatorActivatable ~= nil
        and g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
            local fixedAgitatorAct = SPSFixedAgitatorActivatable.new(pEntry)
            pEntry.fixedAgitatorActivatable = fixedAgitatorAct
            g_currentMission.activatableObjectsSystem:addActivatable(fixedAgitatorAct)
        end
    end

    -- [SPS 1.0.0.9.27] Buying-station type switch: walk-up activatable on the
    -- config-declared switch node (the panel by the electrical box), cycling
    -- the sold fillType. Only meaningful when more than one type is declared —
    -- getIsActivatable hides itself for single-type stations. Must run before
    -- xmlFile:delete (reads switchNodeName / switchRadius).
    if sourceEntry ~= nil and sourceEntry.type == SPS_SOURCE_TYPE_BUYING_STATION
    and SPSBuyStationActivatable ~= nil
    and g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        local switchNode = findLinkedNode(xmlFile:getString(kp .. "slurryPipeSystem.buyingStation#switchNodeName", nil))
        local switchRadius = xmlFile:getFloat(kp .. "slurryPipeSystem.buyingStation#switchRadius", 3.0)
        local buyAct = SPSBuyStationActivatable.new(pEntry, switchNode, switchRadius)
        pEntry.buyStationActivatable = buyAct
        g_currentMission.activatableObjectsSystem:addActivatable(buyAct)
    end

    if xmlFileOwned then xmlFile:delete() end
    SlurryDebug.log("registerPlaceable - registered " .. tostring(placeable.configFileName))

    -- Mark whether this store participates in the thickness model, then restore its
    -- saved two-pool state if available (migrating old single-thickness saves).
    if sourceEntry ~= nil and sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        -- [SPS 1.0.0.9.31] A <slurryStore> declares its own #agitator, already applied
        -- in parseSlurryStores — a slurry lagoon crusts while a digestate lagoon beside
        -- it need not. Only fall back to the placeable-level flag when no store set it.
        if storeSources == nil then
            sourceEntry.thickeningEnabled = pEntry.agitatorEnabled == true
        end
    end
    -- [SPS 1.0.0.9.31] Restore per store. A saved entry matches when the placeable
    -- position is within a metre AND the store ids agree; a legacy entry (#storeId
    -- absent, read as 0) matches the primary store only, so old saves land exactly
    -- where they used to. Each entry is consumed once, so two lagoons at one position
    -- cannot both claim the same pool.
    if self._pendingThickness ~= nil then
        local compNode = placeable.components ~= nil and placeable.components[1] ~= nil
            and placeable.components[1].node or nil
        if compNode ~= nil then
            local px, py, pz = getWorldTranslation(compNode)
            local allStores  = (storeSources ~= nil and #storeSources > 0)
                and storeSources
                or (sourceEntry ~= nil and { sourceEntry } or {})
            for storeIdx, se in ipairs(allStores) do
                for i, pt in ipairs(self._pendingThickness) do
                    local dx, dy, dz = px - pt.px, py - pt.py, pz - pt.pz
                    local savedId = pt.storeId or 0
                    local wantId  = se.storeId or 0
                    local idMatch = (savedId == wantId)
                        or (savedId == 0 and storeIdx == 1)
                    if (dx*dx + dy*dy + dz*dz) <= 1.0 and idMatch then
                        se.thicknessDayCount = pt.dayCount
                        if pt.hasPools then
                            se.solids = pt.solids
                            se.settle = pt.settle
                        else
                            -- Old #thickness gauge: treat it as settling (mixable) and let
                            -- solids lazy-init at fresh DM.
                            se._migratedSettle = pt.thickness
                        end
                        table.remove(self._pendingThickness, i)
                        SlurryDebug.log("[SPS Thickness] restored store pools for "
                            .. tostring(placeable.configFileName)
                            .. " store " .. tostring(wantId))
                        break
                    end
                end
            end
        end
    end

    self:tryResolvePendingConnections()

    -- [SPS Crust] Restore the crust-plane rise + foliage anchor, and make it work for
    -- own-folder placeables as well as nodeTree ones.
    --
    -- How baseTank works: the nodeTree linker re-parents the crust mesh (crust_fillPlane)
    -- onto the live, engine-driven slurry plane (slurryPit_fillPlane). Because it becomes
    -- a CHILD of that engine plane it tracks the slurry surface for free, and the mod only
    -- drives its local Y = settle * maxRise so it rises as the crust forms. Foliage then
    -- attaches to the crustFoliage anchor (a child of crust_fillPlane) and rides with it.
    --
    -- Own-folder placeables bake these nodes into their OWN i3d under crustPlane, so
    -- crust_fillPlane is NOT a child of the engine plane after load. We resolve it from
    -- the placeable's own tree (findLinkedNode already falls back to that) and re-parent
    -- it onto fillPlaneNode here, replicating exactly what the linker does. On baseTank it
    -- is already parented there, so the re-parent is guarded and skipped. Additive.
    -- [SPS 1.0.0.10.3] Skipped entirely when <slurryStores> is present: those stores
    -- bind their own crust plane and foliage anchor per store in initStoreCrust.
    if pEntry.crustConfig ~= nil and sourceEntry ~= nil and not legacyPlaneIgnored
    and fillPlaneNode ~= nil and fillPlaneNode ~= 0 then
        local cc = pEntry.crustConfig
        if cc.planeNode ~= nil and cc.planeNode ~= "" then
            local crustPlaneNode = findLinkedNode(cc.planeNode)
            if crustPlaneNode ~= nil and crustPlaneNode ~= 0 then
                -- Track the engine plane by parenting onto it, unless already a child of it.
                if getParent(crustPlaneNode) ~= fillPlaneNode then
                    link(fillPlaneNode, crustPlaneNode)
                    setRotation(crustPlaneNode, 0, 0, 0)
                    SlurryDebug.log("[SPS Crust] re-parented crust plane '" .. tostring(cc.planeNode)
                        .. "' onto engine fill plane (own-folder placeable)")
                end
                sourceEntry.crustPlaneNode = crustPlaneNode
                sourceEntry.crustMaxRise   = cc.maxRise or 0.1
                -- Snap to the restored crust height immediately so it is correct on load.
                local settle0 = sourceEntry.settle or sourceEntry._migratedSettle or 0
                setTranslation(crustPlaneNode, 0, settle0 * sourceEntry.crustMaxRise, 0)
                SlurryDebug.log("[SPS Crust] crustPlane '" .. tostring(cc.planeNode)
                    .. "' resolved=" .. tostring(crustPlaneNode)
                    .. " maxRise=" .. tostring(sourceEntry.crustMaxRise)
                    .. " settle0=" .. tostring(settle0))
            else
                SlurryDebug.log("[SPS Crust] crustPlane '" .. tostring(cc.planeNode) .. "' NOT resolved")
            end
        end
        -- Foliage anchor: when authored, SPSCrustVegetation attaches plants here (a child
        -- of crust_fillPlane) so they ride the crust; otherwise it falls back to the plane.
        if cc.foliageNode ~= nil and cc.foliageNode ~= "" then
            local foliageAnchor = findLinkedNode(cc.foliageNode)
            if foliageAnchor ~= nil and foliageAnchor ~= 0 then
                sourceEntry.crustFoliageNode = foliageAnchor
                SlurryDebug.log("[SPS Crust] crustFoliage '" .. tostring(cc.foliageNode)
                    .. "' resolved=" .. tostring(foliageAnchor))
            else
                SlurryDebug.log("[SPS Crust] crustFoliage '" .. tostring(cc.foliageNode) .. "' NOT resolved")
            end
        end
    end

    -- Scatter crust vegetation on the fill plane if configured.
    -- [SPS 1.0.0.9.31] Multi-store placeables do this per store instead — each lagoon
    -- parents its own crust mesh, binds its own foliage anchor and holds its own plant
    -- instances — so the single-plane path below is skipped when stores are present.
    if storeSources ~= nil then
        self:initStoreCrust(pEntry)
    elseif pEntry.crustConfig ~= nil and SPSCrustVegetation ~= nil then
        SPSCrustVegetation.initForPlaceable(pEntry, self.modDirectory)
    end
end

-- ---------------------------------------------------------------------------
-- unregisterPlaceable
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.13] Vehicle WATER level persistence.
-- SPS grants WATER support to registered tankers AFTER vehicle load (the
-- Vehicle:onFinishedLoading hook), but vanilla FillUnit applies its savegame
-- values BEFORE that point — so on reload a WATER-filled tanker restores
-- against a unit that does not yet support WATER and vanilla discards the
-- level (field report: water-filled tankers empty after save/reload; slurry
-- survives because it is natively supported). Until the seeding can run
-- pre-restore, SPS persists WATER levels itself: written at save, restored
-- at registerVehicle (position + fillUnit keyed, server-side; clients get the
-- level through the normal fillUnit sync).
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_saveVehicleWaterLevels(xmlFile)
    local idx = 0
    for _, entry in ipairs(self.registeredVehicles) do
        local vehicle = entry.vehicle
        if vehicle ~= nil and vehicle.spec_fillUnit ~= nil and vehicle.rootNode ~= nil then
            for fui, fillUnit in ipairs(vehicle.spec_fillUnit.fillUnits) do
                local lvl = vehicle:getFillUnitFillLevel(fui) or 0
                if lvl > 0.001 and vehicle:getFillUnitFillType(fui) == FillType.WATER then
                    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
                    local base = string.format("slurryPipeSystem.vehicleWater.unit(%d)", idx)
                    xmlFile:setFloat(base .. "#x", vx)
                    xmlFile:setFloat(base .. "#y", vy)
                    xmlFile:setFloat(base .. "#z", vz)
                    xmlFile:setInt(base .. "#fillUnitIndex", fui)
                    xmlFile:setFloat(base .. "#level", lvl)
                    idx = idx + 1
                end
            end
        end
    end
    if idx > 0 then
        SlurryPipeManager.log("saveCouplingConnections: wrote %d vehicle WATER level(s)", idx)
    end
end

function SlurryPipeManager:_loadVehicleWaterLevels(xmlFile)
    self._pendingVehicleWater = {}
    local idx = 0
    while true do
        local base = string.format("slurryPipeSystem.vehicleWater.unit(%d)", idx)
        if not xmlFile:hasProperty(base) then break end
        table.insert(self._pendingVehicleWater, {
            x   = xmlFile:getFloat(base .. "#x", 0),
            z   = xmlFile:getFloat(base .. "#z", 0),
            fui = xmlFile:getInt(base .. "#fillUnitIndex", 1),
            level = xmlFile:getFloat(base .. "#level", 0),
        })
        idx = idx + 1
    end
    if idx > 0 then
        SlurryPipeManager.log("loadCouplingConnections: %d pending vehicle WATER level(s)", idx)
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.3] Placeable detach-handler registry.
-- When a registered placeable of ANY style (store, pen, sprayer placeable, and
-- any future placeable such as the separator) is deleted/sold, every SPS
-- subsystem holding a reference to it must tear that reference down and sync
-- the teardown. Each domain module registers its own handler at load; a future
-- module (e.g. SPSM_Separator) just registers its own — zero core edits.
-- detachAllFromPlaceable runs the handlers exactly once per placeable (latch),
-- so the duplicate vanilla delete call observed in MP logs no-ops safely.
-- Handlers receive (manager, placeable); each scans its own registries and is
-- idempotent. Handler errors are contained (a broken handler must never abort
-- a sell) and always printed, never debug-gated.
-- ---------------------------------------------------------------------------
SlurryPipeManager.placeableDetachHandlers = {}

function SlurryPipeManager.registerPlaceableDetachHandler(name, fn)
    table.insert(SlurryPipeManager.placeableDetachHandlers, { name = name, fn = fn })
end

function SlurryPipeManager:detachAllFromPlaceable(placeable)
    if placeable == nil or placeable._spsDetachDone == true then return end
    placeable._spsDetachDone = true
    for _, h in ipairs(SlurryPipeManager.placeableDetachHandlers) do
        local ok, err = pcall(h.fn, self, placeable)
        if not ok then
            print(string.format("[SPS] ERROR: placeable detach handler '%s' failed: %s",
                tostring(h.name), tostring(err)))
        end
    end
end

function SlurryPipeManager:unregisterPlaceable(placeable)
    SlurryPipeManager.log("unregisterPlaceable: enter %s", tostring(placeable and placeable.configFileName))
    for i, entry in ipairs(self.registeredPlaceables) do
        if entry.placeable == placeable then
            if entry.sourceEntry ~= nil then
                for j, src in ipairs(self.sourceEntries) do
                    if src == entry.sourceEntry then table.remove(self.sourceEntries, j) break end
                end
            end
            -- [SPS 1.0.0.9.31] Stores 2..n were inserted into self.sourceEntries at
            -- registration alongside the primary; drop them here too or a sold
            -- multi-lagoon placeable leaves dangling sources behind.
            if entry.storeSources ~= nil then
                for k = 2, #entry.storeSources do
                    for j, src in ipairs(self.sourceEntries) do
                        if src == entry.storeSources[k] then table.remove(self.sourceEntries, j) break end
                    end
                end
            end
            -- [SPS 1.0.0.9.3] Run every domain's detach handler (chains anchored
            -- or bonded here, connected strap couplings, sprayer pipes, ...)
            -- BEFORE local teardown. The 1.0.0.9.2 owner-keyed broadcast pre-pass
            -- was relocated into the Couplers handler (SPSM_Couplers.lua).
            self:detachAllFromPlaceable(placeable)
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
                -- [SPS 1.0.0.9.16] HIDE, don't delete. Field log 11:10:03: our
                -- delete() on these injected nodeTree shapes ran during the sell,
                -- and the construction screen's mouse-over highlight was still
                -- holding their ids in the SAME frame -> three
                -- "setShaderParameter: Unknown entity id" stacks per sell
                -- (Placeable.lua:1462 setOverlayColor). The engine reaps the
                -- whole placeable subtree as part of the sell anyway (proven:
                -- it deleted 347 child clones before our hook in earlier logs),
                -- so hiding is leak-free and leaves no dangling id behind.
                for _, nodeId in ipairs(entry.linkedNodes) do
                    if nodeId ~= nil and nodeId ~= 0 and entityExists(nodeId) then
                        setVisibility(nodeId, false)
                    end
                end
            end
            if entry.fixedAgitatorActivatable ~= nil then
                entry.fixedAgitatorActivatable:delete()
                entry.fixedAgitatorActivatable = nil
            end
            -- [SPS 1.0.0.9.27] Buying-station type-switch activatable cleanup.
            if entry.buyStationActivatable ~= nil then
                entry.buyStationActivatable:delete()
                entry.buyStationActivatable = nil
            end
            if SPSFixedAgitator ~= nil and entry.fixedAgitator ~= nil then
                SPSFixedAgitator.cleanup(entry)
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
    SlurryPipeManager.log("saveCouplingConnections: enter path=%s", tostring(savePath))
    local xmlFile = XMLFile.create("spsSave", savePath, "slurryPipeSystem")
    if xmlFile == nil then
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
                -- [SPS DIAG/FIX] Persist full chain-start rotation (see SPSPipeChain
                -- getSaveData/restoreFromSaveData). Optional attributes — old saves
                -- and readers without them fall back to yaw-only behaviour.
                if data.chainStartRX ~= nil then
                    xmlFile:setFloat(base .. "#chainStartRX", data.chainStartRX)
                end
                if data.chainStartRZ ~= nil then
                    xmlFile:setFloat(base .. "#chainStartRZ", data.chainStartRZ)
                end
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

    -- Save per-vehicle pump direction (FILL/DISCHARGE), keyed by component world
    -- position + configFileName (mirrors how connections are position-keyed).
    -- Restored in tryResolvePendingConnections by nearest position + config match.
    local pumpIdx = 0
    for _, vEntry in ipairs(self.registeredVehicles) do
        local state = vEntry.state
        local veh   = vEntry.vehicle
        if state ~= nil and state.direction ~= nil
        and veh ~= nil and veh.components ~= nil and veh.components[1] ~= nil then
            local wx, wy, wz = getWorldTranslation(veh.components[1].node)
            local base = string.format("slurryPipeSystem.pumpStates.pumpState(%d)", pumpIdx)
            xmlFile:setFloat (base .. "#x",         wx)
            xmlFile:setFloat (base .. "#y",         wy)
            xmlFile:setFloat (base .. "#z",         wz)
            xmlFile:setString(base .. "#config",    tostring(veh.configFileName))
            xmlFile:setInt   (base .. "#direction", state.direction)
            pumpIdx = pumpIdx + 1
        end
    end

    xmlFile:setInt("slurryPipeSystem#selectedColorIndex", self.currentPipeColorIndex)
    xmlFile:setBool("slurryPipeSystem#realismEnabled", self.realismEnabled)
    xmlFile:setBool("slurryPipeSystem#ibcPersistWhenEmpty", self.ibcPersistWhenEmpty == true)
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
    -- [SPS 1.0.0.9.31] One entry PER STORE, not per placeable. Entries are keyed by
    -- placeable world position plus #storeId, because a multi-lagoon placeable has
    -- several independent dry-matter pools at one position and the position alone can
    -- no longer identify which. #storeId is omitted (read back as 0) for a legacy
    -- single-store placeable, and the loader treats 0 as "the primary store", so old
    -- savegames restore unchanged.
    local thickIdx = 0
    for _, pEntry in ipairs(self.registeredPlaceables) do
        local wx, wy, wz = 0, 0, 0
        if pEntry.placeable ~= nil and pEntry.placeable.components ~= nil
        and pEntry.placeable.components[1] ~= nil then
            wx, wy, wz = getWorldTranslation(pEntry.placeable.components[1].node)
        end
        for _, se in ipairs(self:getStoreSources(pEntry)) do
            if se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                local base = string.format("slurryPipeSystem.thicknesses.entry(%d)", thickIdx)
                xmlFile:setFloat(base .. "#px",            wx)
                xmlFile:setFloat(base .. "#py",            wy)
                xmlFile:setFloat(base .. "#pz",            wz)
                xmlFile:setFloat(base .. "#solids",        se.solids or 0)
                xmlFile:setFloat(base .. "#settle",        se.settle or 0)
                xmlFile:setInt(base   .. "#dayCount",      se.thicknessDayCount or 0)
                if se.storeId ~= nil then
                    xmlFile:setInt(base .. "#storeId",     se.storeId)
                end
                thickIdx = thickIdx + 1
            end
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

    -- [SPS 1.0.0.9.5] Dynamic sprayer compartments (locked type + level per coupler).
    if self._saveSprayerCompartments ~= nil then
        self:_saveSprayerCompartments(xmlFile)
    end
    -- [SPS 1.0.0.9.13] Vehicle WATER levels (vanilla discards them on reload
    -- because SPS grants WATER support after the savegame restore).
    self:_saveVehicleWaterLevels(xmlFile)

    xmlFile:save()
    xmlFile:delete()
end

-- Called from SPSMod:loadMap after manager is ready.
-- Populates pendingConnections. Each entry is resolved as couplings register.
function SlurryPipeManager:loadCouplingConnections(savePath)
    SlurryPipeManager.log("loadCouplingConnections: enter path=%s", tostring(savePath))
    if not fileExists(savePath) then
        return
    end

    local xmlFile = XMLFile.load("spsSave", savePath)
    if xmlFile == nil then
        return
    end

    -- [SPS 1.0.0.9.5] Dynamic sprayer compartments -> pending, applied at register.
    if self._loadSprayerCompartments ~= nil then
        self:_loadSprayerCompartments(xmlFile)
    end
    -- [SPS 1.0.0.9.13] Vehicle WATER levels -> pending, applied at registerVehicle.
    self:_loadVehicleWaterLevels(xmlFile)
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
            -- [SPS DIAG/FIX] Full chain-start rotation. Read only when present so
            -- older saves leave chainStartRX/RZ nil and restore keeps yaw-only.
            if xmlFile:hasProperty(base .. "#chainStartRX") then
                chainData.chainStartRX = xmlFile:getFloat(base .. "#chainStartRX", 0)
            end
            if xmlFile:hasProperty(base .. "#chainStartRZ") then
                chainData.chainStartRZ = xmlFile:getFloat(base .. "#chainStartRZ", 0)
            end
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

    -- Load per-vehicle pump direction (applied in tryResolvePendingConnections).
    self.pendingPumpStates = {}
    local pumpIdx = 0
    while true do
        local base = string.format("slurryPipeSystem.pumpStates.pumpState(%d)", pumpIdx)
        if not xmlFile:hasProperty(base) then break end
        table.insert(self.pendingPumpStates, {
            x         = xmlFile:getFloat(base  .. "#x", 0),
            y         = xmlFile:getFloat(base  .. "#y", 0),
            z         = xmlFile:getFloat(base  .. "#z", 0),
            config    = xmlFile:getString(base .. "#config", nil),
            direction = xmlFile:getInt(base    .. "#direction", SPS_DIRECTION_FILL),
        })
        pumpIdx = pumpIdx + 1
    end

    -- Restore realism settings. Back-compat: older saves used #agitationEnabled as
    -- the single master, so fall back to it for the master's default.
    local legacyMaster = xmlFile:getBool("slurryPipeSystem#agitationEnabled", true)
    self.realismEnabled = xmlFile:getBool("slurryPipeSystem#realismEnabled", legacyMaster)
    self.ibcPersistWhenEmpty = xmlFile:getBool("slurryPipeSystem#ibcPersistWhenEmpty", false)
    self:applyIbcPersistSetting()
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
    -- [SPS 1.0.0.9.30] The savegame HUD/colour keys above are legacy (they are
    -- shared across all players). Re-apply the per-user file on top so each
    -- player's own preferences win on every machine, host included.
    self:loadUserSettings()

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
            -- 0 = legacy entry with no store id: applies to the primary store.
            storeId   = xmlFile:getInt(base   .. "#storeId",   0),
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
end

function SlurryPipeManager:_tryResolveMPPending()
    if self._pendingMPConnections == nil then self._pendingMPConnections = {} end
    if self._pendingMPValves == nil then self._pendingMPValves = {} end
    if self._pendingMPChainBonds == nil then self._pendingMPChainBonds = {} end
    if self._pendingMPStoreCrust == nil then self._pendingMPStoreCrust = {} end
    if #self._pendingMPConnections == 0 and #self._pendingMPValves == 0
    and #self._pendingMPChainBonds == 0 and #self._pendingMPStoreCrust == 0 then return end

    self._mpResolving = true

    -- Connects first.
    local keptC = {}
    for _, e in ipairs(self._pendingMPConnections) do
        local cA = self:_findCouplingById(e.vehicleA, e.couplingIdA, false)
        if cA == nil then cA = self:_findCouplingById(e.vehicleA, e.couplingIdA, true) end
        local cB
        if e.targetType == SlurryPipeConnectEvent.TARGET_TYPE_VEHICLE then
            cB = self:_findCouplingById(e.targetObject, e.couplingIdB, false)
        else
            cB = self:_findCouplingById(e.targetObject, e.couplingIdB, true)
        end
        if cA ~= nil and cB ~= nil then
            if not cA.isConnected and not cB.isConnected then
                local ownerA = e.vehicleA or cA.placeable
                self:applyConnectCouplings(cA, cB, ownerA, e.targetObject)
            end
            SlurryPipeManager.logMP(string.format("[SPS MP] _tryResolveMPPending: connect RESOLVED idA=%s idB=%s",
                tostring(e.couplingIdA), tostring(e.couplingIdB)))
        else
            table.insert(keptC, e)   -- still waiting on a vehicle to register
        end
    end
    self._pendingMPConnections = keptC

    -- Chain-terminus bonds next: the tanker coupler and/or chain may have just
    -- registered. Resolve the same way applyChainConnect does, so the end bez is
    -- created. Done before valves so a valve on the chain terminus sees the bond.
    local keptCB = {}
    for _, e in ipairs(self._pendingMPChainBonds) do
        local vc = self:_findCouplingById(e.anchorObject, e.vehicleCouplingId, e.isPlaceable == true)
        local ch = self._chainsByNetId[e.chainNetId]
        local term = (ch ~= nil) and self:_resolveChainTerminus(ch, e.terminusSegIndex) or nil
        if vc ~= nil and ch ~= nil and term ~= nil then
            if not vc.isConnected and not term.isConnected then
                local owner = (not e.isPlaceable) and e.anchorObject or vc.placeable
                self:applyConnectCouplings(vc, term, owner, nil)
            end
            SlurryPipeManager.logMP(string.format("[SPS MP] _tryResolveMPPending: chain bond RESOLVED netId=%s seg=%s couplingId=%s",
                tostring(e.chainNetId), tostring(e.terminusSegIndex), tostring(e.vehicleCouplingId)))
        else
            table.insert(keptCB, e)   -- still waiting on tanker/chain to register
        end
    end
    self._pendingMPChainBonds = keptCB

    -- Store crust next: apply once the store placeable has registered on this client.
    local keptSC = {}
    for _, e in ipairs(self._pendingMPStoreCrust) do
        if self:applyStoreCrustState(e.placeable, e.solids, e.settle, true, e.storeIndex) then
            SlurryPipeManager.logMP("[SPS MP] _tryResolveMPPending: store crust RESOLVED")
        else
            table.insert(keptSC, e)   -- store still not registered
        end
    end
    self._pendingMPStoreCrust = keptSC

    -- Valves second (coupling now connected, so partner sync applies).
    -- IMPORTANT: resolve strictly against the valve's own owner. Passing nil to
    -- applyValveState lets its global placeable fallback grab ANY placeable coupling
    -- with a matching id (e.g. a baseTank's id=1), applying the valve to the wrong
    -- object and consuming the queue entry. So for a vehicle-owned valve we look the
    -- coupling up on that vehicle only and pass the coupling object (object-first).
    local keptV = {}
    for _, e in ipairs(self._pendingMPValves) do
        local resolved = false
        if e.vehicle ~= nil then
            local c = self:_findCouplingById(e.vehicle, e.couplingId, false)
            if c ~= nil then
                self:applyValveState(e.vehicle, e.couplingId, e.isOpen, c)
                resolved = true
            end
        else
            -- No vehicle owner (placeable/chain valve): defer to applyValveState's
            -- own scoped lookup (placeableOwner was pre-resolved at event time).
            if self:applyValveState(e.vehicle, e.couplingId, e.isOpen, nil) then
                resolved = true
            end
        end
        if resolved then
            SlurryPipeManager.logMP(string.format("[SPS MP] _tryResolveMPPending: valve RESOLVED couplingId=%s isOpen=%s",
                tostring(e.couplingId), tostring(e.isOpen)))
        else
            table.insert(keptV, e)
        end
    end
    self._pendingMPValves = keptV

    self._mpResolving = false
end

function SlurryPipeManager:tryResolvePendingConnections()
    -- [SPS MP] Drain client join-dump connect/valve events that were queued because
    -- their vehicles had not finished loading. Runs first so it benefits from the
    -- vehicle/placeable that just registered (this function is called at the end of
    -- registerVehicle/registerPlaceable).
    -- [SPS MP] Rebind any chain whose anchor owner has just registered (JIP race)
    -- BEFORE draining the bond/valve queues, so bonds in the same pass resolve
    -- against the rebuilt (anchored) chain instead of a copy about to be deleted.
    self:_tryResolveChainAnchorRebinds()
    self:_tryResolveMPPending()
    SlurryPipeManager.log("tryResolvePendingConnections: pendingConns=%d pendingChains=%d pendingDeployed=%d", #self.pendingConnections, #self.pendingChains, #self.pendingDeployedCouplings)
    if #self.pendingConnections == 0 and #self.pendingChains == 0 and #self.pendingDeployedCouplings == 0
    and #self.pendingPumpStates == 0
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

    -- Resolve pending pump directions: match each to a registered vehicle by
    -- nearest component position with the same configFileName, then restore
    -- state.direction. Vehicles are placed by Giants before SPS load, so the
    -- component position matches within a small margin.
    if #self.pendingPumpStates > 0 then
        local PUMP_TOL_SQ = 2.0 * 2.0
        local resolvedPumps = {}
        for _, pending in ipairs(self.pendingPumpStates) do
            local best, bestSq = nil, PUMP_TOL_SQ
            for _, vEntry in ipairs(self.registeredVehicles) do
                local veh = vEntry.vehicle
                if veh ~= nil and vEntry.state ~= nil
                and veh.components ~= nil and veh.components[1] ~= nil
                and (pending.config == nil or tostring(veh.configFileName) == pending.config) then
                    local cx, cy, cz = getWorldTranslation(veh.components[1].node)
                    local dx, dy, dz = cx - pending.x, cy - pending.y, cz - pending.z
                    local d2 = dx*dx + dy*dy + dz*dz
                    if d2 <= bestSq then best, bestSq = vEntry, d2 end
                end
            end
            if best ~= nil then
                best.state.direction = pending.direction
                SlurryPipeManager.log("tryResolvePendingConnections: restored pump direction=%d on %s",
                    pending.direction, tostring(best.vehicle and best.vehicle.configFileName))
                table.insert(resolvedPumps, pending)
            end
        end
        for _, r in ipairs(resolvedPumps) do
            for i, p in ipairs(self.pendingPumpStates) do
                if p == r then table.remove(self.pendingPumpStates, i) break end
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

-- ===========================================================================
-- [SPS MP] Late-join initial state sync
-- ---------------------------------------------------------------------------
-- Event replication only covers changes made while a client is connected. When
-- a client joins after the host has already built pipes / opened valves, the
-- server must replay the full current state to that one connection, or the
-- joiner sees no pipes, closed valves, and a phantom "connect" option.
-- ===========================================================================

-- MessageType.PLAYER_CREATED callback (server). player.connection is the joining
-- client's connection; the host's own local player is skipped.
-- PLAYER_CREATED is informational only; the actual dump is driven by scanning
-- g_server.clientConnections in update() (player.connection is not the same object
-- as the server's client connection, so we must use the canonical list).
function SlurryPipeManager:onPlayerJoined(player)
    if g_server == nil then return end
    SlurryPipeManager.logMP("[SPS MP] onPlayerJoined: a client joined (dump handled by connection scan)")
end

-- [SPS MP] Each tick, send the initial state dump to any client connection that
-- has become ready for events and hasn't been dumped yet. This uses the exact
-- list (g_server.clientConnections) and readiness flag (isReadyForEvents) that
-- Server:broadcastEvent uses, so timing matches normal event delivery.
function SlurryPipeManager:_processJoinDumps(dt)
    if g_server == nil or g_server.clientConnections == nil then return end
    if self._dumpedConnections == nil then self._dumpedConnections = {} end
    for streamId, connection in pairs(g_server.clientConnections) do
        if streamId ~= NetworkNode.LOCAL_STREAM_ID
        and connection ~= nil
        and connection.isReadyForEvents
        and not self._dumpedConnections[connection] then
            self._dumpedConnections[connection] = true
            SlurryPipeManager.logMP(string.format("[SPS MP] join dump: client streamId=%s ready, sending state", tostring(streamId)))
            self:sendFullStateToConnection(connection)
        end
    end
end

function SlurryPipeManager:sendFullStateToConnection(connection)
    if g_server == nil or connection == nil then return end
    self._dumpCounts = { direct = 0, chainBond = 0, valve = 0, pump = 0, flow = 0, deploy = 0, crust = 0,
                         agit = 0, fixedAgit = 0, blockage = 0, shear = 0, spreaderValve = 0, sprayerConnect = 0 }

    -- 1) Chain geometry (must arrive before bonds/valves that reference termini).
    local chainCount = 0
    for _, chain in ipairs(self.pipeChains) do
        -- [SPS MP] Chains restored from a savegame never went through the live-lay
        -- path, so chain.netId is nil and the whole chain (plus its terminus bonds,
        -- which key on chain.netId) is invisible to the join dump — a late joiner
        -- sees no saved pipes. Allocate a netId now so the chain becomes dumpable.
        if g_server ~= nil and chain.netId == nil and not chain.isRemoteLive and #chain.segments > 0 then
            chain.netId = self:_allocChainNetId()
            self._chainsByNetId[chain.netId] = chain
            SlurryPipeManager.logMP(string.format("[SPS MP] join dump: allocated netId=%s for restored chain (segs=%d)",
                tostring(chain.netId), #chain.segments))
        end
        if chain.netId ~= nil and not chain.isRemoteLive and #chain.segments > 0 then
            local payload = self:_serializeChain(chain)
            if payload ~= nil then
                local anchorObject, acid, isPl = self:_getChainAnchorDescriptor(chain)
                connection:sendEvent(SPSChainStateEvent.new(chain.netId, false, anchorObject, acid, isPl, payload))
                chainCount = chainCount + 1
            end
        end
    end

    -- 2) Chain-terminus bonds (anchor bez + tanker-to-chain).
    for _, ct in ipairs(self.chainTerminusEntries) do
        if ct.isConnected and ct.chain ~= nil and ct.chain.netId ~= nil then
            local ext = ct.connectedPartnerCoupling
            if ext ~= nil then
                local v, p = self:_findCouplingOwner(ext)
                local owner = v or p
                if owner ~= nil then
                    local role = self:_getChainTerminusRole(ct.chain, ct) or 0
                    connection:sendEvent(SPSChainConnectEvent.new(owner, v == nil, ext.id, ct.chain.netId, role, true))
                    self._dumpCounts.chainBond = self._dumpCounts.chainBond + 1
                end
            end
        end
    end

    -- 3) Direct coupler bonds (no chain terminus on either side), deduped per pair.
    local sentPairs = {}
    local function dumpDirect(coupling)
        if not coupling.isConnected then return end
        local partner = coupling.connectedPartnerCoupling
        if partner == nil then return end
        if coupling.isChainTerminus or partner.isChainTerminus then return end
        local key  = tostring(coupling) .. "|" .. tostring(partner)
        local rkey = tostring(partner) .. "|" .. tostring(coupling)
        if sentPairs[key] or sentPairs[rkey] then return end
        sentPairs[key] = true
        local vA, pA = self:_findCouplingOwner(coupling)
        local vB, pB = self:_findCouplingOwner(partner)
        local ownerA, ownerB = vA or pA, vB or pB
        if ownerA == nil or ownerB == nil then return end
        local targetType = (vB ~= nil) and SlurryPipeConnectEvent.TARGET_TYPE_VEHICLE
                                       or  SlurryPipeConnectEvent.TARGET_TYPE_PLACEABLE
        connection:sendEvent(SlurryPipeConnectEvent.new(ownerA, ownerB, targetType, coupling.id, partner.id))
        self._dumpCounts.direct = self._dumpCounts.direct + 1
    end
    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, c in ipairs(vEntry.couplingEntries) do dumpDirect(c) end
    end
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do dumpDirect(sc) end
        end
    end

    -- 3b) Deployed placeable couplings. Deployable couplers register stowed
    -- (isDeployed = not deployable), so a late joiner builds them hidden and
    -- removeFromPhysics. The live SPSCouplingDeployEvent only fires on toggle, so
    -- without this pass a joiner never sees a coupler that was deployed before they
    -- connected — they cannot see it or connect a pipe to it. Re-send the current
    -- deploy state so applyCouplingDeployState runs on the joiner (visibility +
    -- addToPhysics + undeployedVisibleNodes). Must precede the bond/valve passes so
    -- the mount node is live before anything references it.
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc.deployable and sc.isDeployed then
                    connection:sendEvent(SPSCouplingDeployEvent.new(pEntry.placeable, sc.id, true))
                    self._dumpCounts.deploy = self._dumpCounts.deploy + 1
                end
            end
        end
    end

    -- 3c) Store crust/thickness. Raise the crust plane and show crust foliage on the
    -- joiner for any store that has aged. Uses the same one-way SPSStoreCrustEvent the
    -- live change-detection pass uses.
    -- [SPS 1.0.0.9.31] One dump per store, carrying the same 1-based index the live
    -- pass sends, so a joiner rebuilds every lagoon on a multi-store placeable rather
    -- than only its primary. Single-store placeables dump index 1 exactly as before.
    for _, pEntry in ipairs(self.registeredPlaceables) do
        for i, se in ipairs(self:getStoreSources(pEntry)) do
            if se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE
            and ((se.settle or 0) > 0 or (se.solids or 0) > 0) then
                connection:sendEvent(SPSStoreCrustEvent.new(pEntry.placeable, se.solids or 0, se.settle or 0, i))
                self._dumpCounts.crust = self._dumpCounts.crust + 1
            end
        end
    end

    -- [SPS 1.0.0.9.31] Channel-gated snapshot of every store's level/solids/settle at
    -- the moment of the join dump, so a joiner's view can be diffed against the
    -- server's if a lagoon comes up wrong. Silent unless SPSM_Stores is on.
    if self.logStoreMPState ~= nil then
        self:logStoreMPState("JIP-dump")
    end

    -- 4) Open valves (vehicle couplers, placeable store couplers, chain termini).
    local function dumpValve(coupling, vehicle)
        if coupling.isConnected and coupling.valveOpen then
            connection:sendEvent(SlurryValveStateEvent.new(vehicle, coupling, true))
            self._dumpCounts.valve = self._dumpCounts.valve + 1
        end
    end
    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, c in ipairs(vEntry.couplingEntries) do dumpValve(c, vEntry.vehicle) end
    end
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do dumpValve(sc, nil) end
        end
    end
    for _, ct in ipairs(self.chainTerminusEntries) do
        if ct.isConnected and ct.valveOpen then
            local v = self:_findCouplingOwner(ct)
            connection:sendEvent(SlurryValveStateEvent.new(v, ct, true))
            self._dumpCounts.valve = self._dumpCounts.valve + 1
        end
    end

    -- 5) Pump / hydraulic flow valve / direction per vehicle.
    for _, vEntry in ipairs(self.registeredVehicles) do
        local state = vEntry.state
        if state ~= nil then
            if state.pumpRunning then
                connection:sendEvent(SPSSelfPumpStateEvent.new(vEntry.vehicle, true))
                self._dumpCounts.pump = self._dumpCounts.pump + 1
            end
            if state.valveOpen then
                connection:sendEvent(SlurryFlowStateEvent.new(vEntry.vehicle, true))
                self._dumpCounts.flow = self._dumpCounts.flow + 1
            end
            if state.direction == SPS_DIRECTION_DISCHARGE then
                connection:sendEvent(SlurryFlowDirectionEvent.new(vEntry.vehicle, state.direction))
            end
            -- [SPS MP] Current stored pressure, so a late joiner sees a held value
            -- immediately (the live broadcast only fires when pressure changes).
            if state.pressure ~= nil and math.abs(state.pressure) > 0.001
               and SPSPressureStateEvent ~= nil then
                connection:sendEvent(SPSPressureStateEvent.new(vEntry.vehicle, state.pressure))
            end
        end
    end

    -- 6) Mobile agitator running, spreader valve open, and shear-bolt snapped —
    -- per-vehicle runtime state. All broadcast live on change but were never
    -- re-sent on join, so a late joiner saw a stopped agitator, a closed spreader
    -- valve, and an intact bolt regardless of the real state.
    for _, vEntry in ipairs(self.registeredVehicles) do
        if vEntry.agitatorIsActive == true and SlurryAgitatorEvent ~= nil then
            connection:sendEvent(SlurryAgitatorEvent.new(vEntry.vehicle, true))
            self._dumpCounts.agit = self._dumpCounts.agit + 1
        end
        local state = vEntry.state
        if state ~= nil then
            if state.spreaderValveOpen == true and SPSSpreaderValveEvent ~= nil then
                connection:sendEvent(SPSSpreaderValveEvent.new(vEntry.vehicle, true))
                self._dumpCounts.spreaderValve = self._dumpCounts.spreaderValve + 1
            end
            if state.shearSnapped == true and SPSShearBoltEvent ~= nil then
                connection:sendEvent(SPSShearBoltEvent.new(vEntry.vehicle, true))
                self._dumpCounts.shear = self._dumpCounts.shear + 1
            end
        end
    end

    -- 7) Blockage per node. blockageEntries hold the authoritative blocked flag;
    -- addressing is by the same node index the live event uses (getBlockageNodeIndex),
    -- applied on the joiner via applyBlockageByIndex.
    for _, vEntry in ipairs(self.registeredVehicles) do
        if vEntry.blockageEntries ~= nil and SPSBlockageEvent ~= nil then
            for _, b in ipairs(vEntry.blockageEntries) do
                if b.blocked == true then
                    local idx = self:getBlockageNodeIndex(vEntry.vehicle, b)
                    if idx ~= nil then
                        connection:sendEvent(SPSBlockageEvent.new(vEntry.vehicle, idx, true))
                        self._dumpCounts.blockage = self._dumpCounts.blockage + 1
                    end
                end
            end
        end
    end

    -- 8) Fixed (placeable) agitator: connected tractor + running/engaged state. The
    -- STATE request (reqType 2) is what SPSFixedAgitator.applyState consumes on a peer;
    -- send it to the joiner for any fixed agitator that currently has a tractor bound.
    if SPSFixedAgitatorEvent ~= nil and SPSFixedAgitatorEvent.STATE ~= nil then
        for _, pEntry in ipairs(self.registeredPlaceables) do
            local fa = pEntry.fixedAgitator
            if fa ~= nil and fa.connectedVehicle ~= nil then
                connection:sendEvent(SPSFixedAgitatorEvent.new(
                    SPSFixedAgitatorEvent.STATE, pEntry.placeable, fa.connectedVehicle,
                    false, fa.running == true, fa.ptoEngaged == true))
                self._dumpCounts.fixedAgit = self._dumpCounts.fixedAgit + 1
            end
        end
    end

    -- 9) Active sprayer pipe connections (sprayer <-> IBC). Re-sent so a late joiner
    -- draws existing sprayer pipes; applySprayerConnectById queues + retries if the IBC
    -- has not registered on the joiner yet.
    if self.activeSprayerPipes ~= nil and SPSSprayerConnectEvent ~= nil then
        for _, p in pairs(self.activeSprayerPipes) do
            local cA, cB = p.couplingA, p.couplingB
            if cA ~= nil and cB ~= nil then
                local ownerA = cA.object or cA.placeable
                local ownerB = cB.object or cB.placeable
                if ownerA ~= nil and ownerB ~= nil then
                    connection:sendEvent(SPSSprayerConnectEvent.new(ownerA, cA.id, ownerB, cB.id))
                    self._dumpCounts.sprayerConnect = self._dumpCounts.sprayerConnect + 1
                end
            end
        end
    end

    -- 10) [SPS MP] Sprayer runtime state (pump / valve / direction). The connect
    -- pass above only re-draws the pipes; without this a joiner saw a running
    -- sprayer's pump/valve as off until someone re-toggled it.
    if self.registeredSprayerVehicles ~= nil then
        for _, sEntry in ipairs(self.registeredSprayerVehicles) do
            local st = sEntry.state
            if st ~= nil and sEntry.object ~= nil then
                if st.pumpRunning == true and SPSSprayerPumpStateEvent ~= nil then
                    connection:sendEvent(SPSSprayerPumpStateEvent.new(sEntry.object, true))
                end
                if st.valveOpen == true and SPSSprayerValveStateEvent ~= nil then
                    connection:sendEvent(SPSSprayerValveStateEvent.new(sEntry.object, true))
                end
                if st.direction ~= nil and SPSSprayerDirectionEvent ~= nil then
                    connection:sendEvent(SPSSprayerDirectionEvent.new(sEntry.object, st.direction))
                end
            end
        end
    end

    -- 11) [SPS 1.0.0.9.5] Dynamic sprayer compartment locks, so a late joiner's
    -- capacity recompute matches the server (levels arrive via the Storage
    -- object's own streams).
    if SPSSprayerCompartmentEvent ~= nil then
        for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
            for _, sc in ipairs(pEntry.dynCouplers or {}) do
                if sc.dynFillType ~= nil then
                    connection:sendEvent(SPSSprayerCompartmentEvent.new(pEntry.object, sc.id, sc.dynFillType, sc.dynLevel or 0))
                end
            end
        end
    end

    -- 12) [SPS 1.0.0.9.27] Buying-station selected sold type, so a late joiner's
    -- switch prompt (and any fill it watches) shows the live selection instead
    -- of the config default. Sent whenever the station is switchable.
    if SPSBuyStationEvent ~= nil then
        for _, pEntry in ipairs(self.registeredPlaceables) do
            local se = pEntry.sourceEntry
            if se ~= nil and se.type == SPS_SOURCE_TYPE_BUYING_STATION
            and se.fillTypes ~= nil and #se.fillTypes > 1 then
                local name = g_fillTypeManager:getFillTypeNameByIndex(se.fillType)
                if name ~= nil then
                    connection:sendEvent(SPSBuyStationEvent.new(
                        SPSBuyStationEvent.STATE, pEntry.placeable, name))
                end
            end
        end
    end

    -- 13) [SPS 1.0.0.9.30] Gameplay settings (realism / sub-features / shear
    -- bolt / IBC persist), so a late joiner's manager and settings menu show
    -- the live server values instead of the defaults.
    if SPSSettingsSyncEvent ~= nil and SPSSettingsSyncEvent.sendCurrent ~= nil then
        SPSSettingsSyncEvent.sendCurrent(connection)
    end

    local d = self._dumpCounts
    SlurryPipeManager.logMP(string.format("[SPS MP] sendFullStateToConnection: chains=%d chainBonds=%d directBonds=%d deploy=%d crust=%d valves=%d pump=%d flow=%d agit=%d fixedAgit=%d blockage=%d shear=%d spreaderValve=%d sprayerConnect=%d",
        chainCount, d.chainBond, d.direct, d.deploy, d.crust, d.valve, d.pump, d.flow,
        d.agit, d.fixedAgit, d.blockage, d.shear, d.spreaderValve, d.sprayerConnect))
end


-- ---------------------------------------------------------------------------
-- State queries
-- ---------------------------------------------------------------------------
function SlurryPipeManager:hasValidConnection(vehicle)
    SlurryPipeManager.log("hasValidConnection: %s", tostring(vehicle and vehicle.configFileName))
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
    SlurryPipeManager.log("onAIGateChanged: %s aiNow=%s", tostring(vehicle and vehicle.configFileName), tostring(aiNow))

    -- Vanilla FillTrigger: SPS disables it at registration so the player must use
    -- the pipe/arm system to load. AI workers (vanilla / Courseplay / AutoDrive)
    -- have no pipe and load the vanilla way — at a store's fill trigger — so the
    -- trigger must be live while AI drives. Restore the SPS-disabled state when the
    -- player takes back over. Toggled on server and client (the trigger gate is a
    -- local field; AI fill runs server-side, the activation check reads isEnabled).
    if vehicle.spec_fillTriggerVehicle ~= nil
       and vehicle.spec_fillTriggerVehicle.fillTrigger ~= nil then
        -- [SPS MIXED INTEROP] Stay enabled regardless of AI. The init.lua FillTrigger
        -- hook gates per-fillable (SPS blocked, non-SPS + AI allowed), so the trigger
        -- must remain live for a non-SPS player to load from this vessel — not only
        -- while an AI worker is driving.
        vehicle.spec_fillTriggerVehicle.fillTrigger.isEnabled = true
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
            end
            if state.spreaderValveOpen == true then
                state.spreaderValveOpen = false
                SPSSpreaderValveEvent.sendEvent(vehicle, false)
            end
            if state.pumpRunning == true then
                state.pumpRunning = false
                SPSSelfPumpStateEvent.sendEvent(vehicle, false)
            end
        end
        -- Non-spreader pumps run on the vanilla turn-on flag — clear it. The
        -- setIsTurnedOn override passes straight through to vanilla now that
        -- the vehicle is AI-controlled, and the AI turns implements on itself
        -- afterwards through its own controlledAction.
        if vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn()
           and vehicle.setIsTurnedOn ~= nil then
            vehicle:setIsTurnedOn(false)
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

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.27] Buying-station sold-type switch (single switchable coupler)
-- ---------------------------------------------------------------------------
-- Returns pEntry, sourceEntry for a registered buying-station placeable.
function SlurryPipeManager:getBuyStationEntry(placeable)
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.placeable == placeable then
            local se = pEntry.sourceEntry
            if se ~= nil and se.type == SPS_SOURCE_TYPE_BUYING_STATION then
                return pEntry, se
            end
            return nil, nil
        end
    end
    return nil, nil
end

-- Walk-up request: cycle to the next sold type in the config-declared order.
-- On the server this applies immediately (and broadcasts STATE); on a client
-- it sends SPSBuyStationEvent.REQ_SETTYPE and waits for the STATE broadcast.
function SlurryPipeManager:requestBuyStationTypeToggle(placeable)
    local _, se = self:getBuyStationEntry(placeable)
    if se == nil or se.fillTypes == nil or #se.fillTypes < 2 then return end
    local curIdx = 1
    for i, ft in ipairs(se.fillTypes) do
        if ft == se.fillType then curIdx = i break end
    end
    local nextFt = se.fillTypes[(curIdx % #se.fillTypes) + 1]
    if g_server ~= nil then
        self:applyBuyStationType(placeable, nextFt, true)
    elseif SPSBuyStationEvent ~= nil then
        local name = g_fillTypeManager:getFillTypeNameByIndex(nextFt)
        if name ~= nil then
            SPSBuyStationEvent.sendTypeRequest(placeable, name)
        end
    end
end

-- [SPS 1.0.0.9.28] Does this buy-station sourceEntry sell the given type?
-- Sold if the vanilla station provides it (getIsFillTypeSupported) OR it is an
-- SPS-extra type declared in the bundled config. Returns sold, isExtra —
-- isExtra=true routes the purchase through the SPS-side path in
-- transferFillFromBuyingStation (the vanilla path would crash on undeclared
-- types, see getEffectiveFillTypePrice).
function SlurryPipeManager:buyStationSellsFillType(se, fillTypeIndex)
    if se == nil or fillTypeIndex == nil then return false, false end
    if se.extraPriceScales ~= nil and se.extraPriceScales[fillTypeIndex] ~= nil then
        return true, true
    end
    if se.station ~= nil and se.station.getIsFillTypeSupported ~= nil
    and se.station:getIsFillTypeSupported(fillTypeIndex) then
        return true, false
    end
    return false, false
end

-- Sets the selected sold type. Validated against the config-declared cycle
-- AND the station's sold set (vanilla-provided OR SPS-extra), so a
-- stale/forged event can never select a type the station does not sell.
-- broadcast=true only on the server after a local apply
-- (SPSBuyStationEvent.sendState); clients applying a STATE broadcast pass
-- false.
function SlurryPipeManager:applyBuyStationType(placeable, fillTypeIndex, broadcast)
    local _, se = self:getBuyStationEntry(placeable)
    if se == nil or fillTypeIndex == nil then return end
    local inCycle = false
    for _, ft in ipairs(se.fillTypes or {}) do
        if ft == fillTypeIndex then inCycle = true break end
    end
    if not inCycle then return end
    if not self:buyStationSellsFillType(se, fillTypeIndex) then
        SlurryPipeManager.log("applyBuyStationType: station does not sell fillType=%s — ignored",
            tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)))
        return
    end
    se.fillType = fillTypeIndex
    SlurryPipeManager.log("applyBuyStationType: %s -> %s",
        tostring(placeable.configFileName),
        tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)))
    if broadcast == true and g_server ~= nil and SPSBuyStationEvent ~= nil then
        SPSBuyStationEvent.sendState(placeable, fillTypeIndex)
    end
end

function SlurryPipeManager:getPlaceableEntry(placeable)
    for _, entry in ipairs(self.registeredPlaceables) do
        if entry.placeable == placeable then return entry end
    end
    return nil
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

function SlurryPipeManager:update(dt)
	self._updateCount = (self._updateCount or 0) + 1
--    if self._updateCount == 1 then print("[SPS] update() is running") end

	-- [SPS MP] Send the initial state dump to any client whose connection has
	-- become ready for events (Connection:sendEvent drops events before then).
	self:_processJoinDumps(dt)
	-- [SPS MP] Create any bez visuals that were queued while the pipe visual was
	-- still async-loading (join-dump bonds applied mid map-load).
	self:_drainPendingPipeVisuals()
	-- [SPS MP] Re-send IBC-spawn connects after the vehicle has network-synced
	-- (see the queue site in the IBC-loaded callback). Server only, 2 attempts.
	if g_server ~= nil and self._pendingIbcConnectResends ~= nil and #self._pendingIbcConnectResends > 0 then
		local now = g_time or 0
		for i = #self._pendingIbcConnectResends, 1, -1 do
			local e = self._pendingIbcConnectResends[i]
			if now >= e.nextAt then
				-- [SPS MP] Only re-send while the bond STILL EXISTS server-side.
				-- Without this check the re-send resurrected hoses the player had
				-- just removed (guest removes -> re-send re-connects it on clients;
				-- host stayed removed because the broadcast only reaches clients).
				local cA = nil
				if self._findSprayerCouplingById ~= nil then
					-- IBC source vehicles register into registeredSprayerPlaceables,
					-- so try both lists (mirrors the existing lookup pattern).
					cA = self:_findSprayerCouplingById(e.ownerA, e.idA, false)
					  or self:_findSprayerCouplingById(e.ownerA, e.idA, true)
				end
				if cA == nil or not cA.isConnected then
					SlurryPipeManager.logMP(string.format(
						"[SPS MP] IBC connect re-send CANCELLED idA=%s idB=%s (bond no longer live)",
						tostring(e.idA), tostring(e.idB)))
					table.remove(self._pendingIbcConnectResends, i)
				else
					if e.ownerA ~= nil and e.ownerB ~= nil and SPSSprayerConnectEvent ~= nil then
						SPSSprayerConnectEvent.sendEvent(e.ownerA, e.idA, e.ownerB, e.idB)
						SlurryPipeManager.logMP(string.format(
							"[SPS MP] IBC connect RE-SENT idA=%s idB=%s attempt=%d",
							tostring(e.idA), tostring(e.idB), e.attempts + 1))
					end
					e.attempts = e.attempts + 1
					e.nextAt   = now + 1000
					if e.attempts >= 8 or e.ownerA == nil or e.ownerB == nil then
						table.remove(self._pendingIbcConnectResends, i)
					end
				end
			end
		end
	end
	-- [SPS AI GATE] player<->AI transition detection must run before anything
	-- else this tick so suspend/resume happens ahead of pressure/flow/blockage.
	self:updateAIGate(dt)
	self:updateSpreaderAnimations(dt)
	self:updatePumpSounds(dt)

	-- Fixed placeable PTO agitator: validate held connections, drive running
	-- state + agitation (server), spin blades (all peers).
	if SPSFixedAgitator ~= nil then
		SPSFixedAgitator.updateAll(self, dt)
	end
	
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
        -- [SPS 1.0.0.9.31] Iterate every store on the placeable, not just the primary.
        -- The gate moved from pEntry.agitatorEnabled to the per-store thickeningEnabled
        -- flag, which registerPlaceable sets from pEntry.agitatorEnabled for every
        -- legacy placeable — so single-store behaviour is unchanged.
        for _, pEntry in ipairs(self.registeredPlaceables) do
            for _, se in ipairs(self:getStoreSources(pEntry)) do
                if se.thickeningEnabled and se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                    self:_reconcileStorePools(se)
                end
            end
        end
    end

    -- [SPS Crust] Drive each crust plane's local Y = settle * maxRise every tick. The
    -- crust mesh is a child of the engine-driven fill plane (re-parented at registration),
    -- so it already tracks the slurry surface; this only adds the rise as the crust forms.
    -- Server-authoritative, since settle is server state. Flush at settle 0, full at 1.0.
    if g_server ~= nil and self:isFeatureEnabled() then
        for _, pEntry in ipairs(self.registeredPlaceables) do
            for _, se in ipairs(self:getStoreSources(pEntry)) do
                if se.crustPlaneNode ~= nil and se.crustPlaneNode ~= 0 then
                    local settle = se.settle or 0
                    setTranslation(se.crustPlaneNode, 0, settle * (se.crustMaxRise or 0), 0)
                end
            end
        end
    end

    -- [SPS 1.0.0.9.31] Drive SPS-owned fill planes from their store level. A silo's
    -- plane is moved by the engine and is never touched here; a production point has
    -- no such driver, so its plane is ours to move. Runs on server AND client and
    -- outside the realism gate — this is the visual for a vanilla storage level, and
    -- vanilla syncs those levels itself, so both sides derive the same height.
    if SlurryPipeManager.updateStorePlanes ~= nil then
        self:updateStorePlanes()
    end

    -- [SPS 1.0.0.10.3] Refresh crust foliage when the SLURRY SURFACE moves.
    --
    -- Every existing updateVisibility call site is driven by a CRUST change
    -- (applyStoreCrustState, applyAgitation, and the growth loop below, which is
    -- gated on settle actually changing). Nothing was driven by the fill level, so
    -- plants never followed a filling or emptying pit -- they were left at the
    -- height the surface happened to be at when the placeable registered, and a pit
    -- that then filled simply buried them.
    --
    -- Runs on server AND client, and outside the realism gate: this is the visual
    -- position of a vanilla storage level, and updateVisibility hides everything
    -- itself when the master toggle is off. One getWorldTranslation per store per
    -- tick, and the refresh only fires when the height actually stepped, so a store
    -- sitting full for a season costs the read and nothing else.
    if SPSCrustVegetation ~= nil and SPSCrustVegetation.updateVisibility ~= nil then
        for _, pEntry in ipairs(self.registeredPlaceables) do
            for _, se in ipairs(self:getStoreSources(pEntry)) do
                if se.crustInstances ~= nil
                and se.fillPlaneNode ~= nil and se.fillPlaneNode ~= 0
                and entityExists(se.fillPlaneNode) then
                    local _, planeY, _ = getWorldTranslation(se.fillPlaneNode)
                    if se._foliageLastPlaneY == nil
                    or math.abs(planeY - se._foliageLastPlaneY) > 0.005 then
                        se._foliageLastPlaneY = planeY
                        SPSCrustVegetation.updateVisibility(pEntry, se)
                    end
                end
            end
        end
    end

    -- [SPS CRUST v1.0.0.10.2] Crust growth: an unmixed store crusts continuously.
    -- Driven per tick off the shared monotonic game clock rather than the old
    -- whole-day step, so the crust plane rises smoothly instead of jumping once per
    -- in-game day, and the rate is now ABSOLUTE (CRUST_GROW_HOURS) instead of being
    -- scaled by daysPerPeriod. Mixing (applyAgitation) drives it back down; the moment
    -- mixing stops it starts climbing again. Only while the store holds slurry.
    --
    -- The clock is consumed ONCE per tick into a local, then applied to every store,
    -- so all stores advance in lockstep and no store can be charged twice. The
    -- previous _lastMonotonicDay catch-up is no longer needed: a time jump (sleep,
    -- fast-forward, load) simply arrives as a larger hour delta.
    if g_server ~= nil and self:isFeatureEnabled() then
        local growHours = self:consumeGameHours(self, "_crustGrowHourStamp")
        if growHours > 0 and SlurryPipeManager.CRUST_GROW_HOURS > 0 then
            local basePerHour = 1.0 / SlurryPipeManager.CRUST_GROW_HOURS
            for _, pEntry in ipairs(self.registeredPlaceables) do
                -- Per-store XML multiplier: covered tanks crust slower, open lagoons faster.
                local growMult = SlurryPipeManager.clampCrustMult(pEntry.crustGrowMult)
                local gain     = basePerHour * growHours * growMult
                if gain > 0 then
                    for _, se in ipairs(self:getStoreSources(pEntry)) do
                        if se.thickeningEnabled and se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                            self:_ensureStorePools(se)
                            if self:_getStoreTotalFill(se) > 0 then
                                local before = se.settle or 0
                                se.settle = math.min(1.0, before + gain)
                                if se.settle ~= before and SPSCrustVegetation ~= nil then
                                    SPSCrustVegetation.updateVisibility(pEntry, se)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- [SPS MP] Replicate store crust/thickness to clients. All store aging, mixing
    -- and fill are server-authoritative and the driving loops above are server-gated,
    -- so the guest's solids/settle never move on their own — its crust plane stays
    -- flat and its foliage/HUD read thickness 0. Broadcast the two pool values, gated
    -- on a material change in settle or dry-matter fraction so it only sends when the
    -- crust visibly moves (grows per in-game day; DM changes on fill/deposit/mix).
    if g_server ~= nil and self:isFeatureEnabled() then
        -- [SPS 1.0.0.9.31] One send per store, carrying the 1-based store index so a
        -- multi-lagoon placeable's crusts stay independent across the wire. Index 1 is
        -- the primary sourceEntry, which is what every single-store placeable sends.
        for _, pEntry in ipairs(self.registeredPlaceables) do
            local sources = self:getStoreSources(pEntry)
            for i, se in ipairs(sources) do
                if se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                    local solids = se.solids or 0
                    local settle = se.settle or 0
                    local total  = self:_getStoreTotalFill(se)
                    local dm     = (total > 0) and (solids / total) or 0
                    if se._syncedSettle == nil
                    or math.abs(settle - se._syncedSettle) > 0.002
                    or math.abs(dm - (se._syncedDM or -1)) > 0.002 then
                        se._syncedSettle = settle
                        se._syncedDM     = dm
                        SPSStoreCrustEvent.sendEvent(pEntry.placeable, solids, settle, i)
                    end
                end
            end
        end
    end

    -- Manager-driven agitator: runs for any registered vehicle with an agitatorTipNode.
    -- No specialization required — works for any vehicle type including ModHub mods.
    -- [SPS CRUST v1.0.0.10.2] Each agitator now consumes the shared monotonic game
    -- clock through its OWN per-entry stamp rather than a single dt-derived scalar.
    -- The stamp is released the moment the agitator goes inactive, so a mixer that is
    -- lifted out, has its PTO pulled, or whose tractor is switched off cannot bank
    -- idle time and dump it as one huge mixing step when it restarts.
    if g_server ~= nil and self:isFeatureEnabled() then
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
                        for _, se in ipairs(self:getStoreSources(pEntry)) do
                            if se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE
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
                        if foundEntry ~= nil then break end
                    end
                    vEntry.agitatorIsActive = foundEntry ~= nil
                    if foundEntry ~= nil then
                        local hours = self:consumeGameHours(vEntry, "_agitatorHourStamp")
                        if hours > 0 then
                            self:applyAgitation(foundEntry, hours, vEntry.agitatorCrustMix)
                        end
                    else
                        -- Submerged check failed this tick: stop the clock so the time
                        -- spent out of the slurry is never charged as mixing.
                        self:releaseGameHours(vEntry, "_agitatorHourStamp")
                    end
                else
                    vEntry.agitatorIsActive = false
                    self:releaseGameHours(vEntry, "_agitatorHourStamp")
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

    -- [SPS MP] Client-side bezier reshape. The per-tick pipe-update loop below
    -- runs only after the following server-only early-return, so on a client the
    -- bez pipe is shaped once at createPipe (often while the vehicle is still at a
    -- transient load pose) and never corrected — leaving it malformed. Run the same
    -- reshape here for clients so the hose follows its couplers every tick.
    if g_server == nil and g_spsPipeVisual ~= nil then
        for _, pipeData in pairs(self.activePipes) do
            if pipeData.couplingA.mountNode ~= nil and pipeData.couplingB.mountNode ~= nil then
                g_spsPipeVisual:updatePipe(pipeData.inst)
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
							shouldPlay = pumpOn and (self:getPressureFlowScalar(vehicle) > 0) and dirOk and tankerHasSlurry
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
                                        local pumpOn2b
                                        if self:isVehicleSelfPowered(vehicle2) then
                                            pumpOn2b = vState2 ~= nil and vState2.pumpRunning == true
                                        else
                                            pumpOn2b = vehicle2.getIsTurnedOn ~= nil and vehicle2:getIsTurnedOn() or false
                                        end
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
                                        
                                        if pumpOn2b and (self:getPressureFlowScalar(vehicle2) > 0) and valveOpen2 and dirOk2 and tankerHasSlurry2 then
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
 
    -- Hydraulic head equalisation between directly-coupled tankers. Runs before
    -- the flow sessions below so the _equaliseActive flag it sets is fresh when
    -- tickFlow -> resolveCouplingFlow reads it this frame. Server-only + throttled.
    self:updateLevelEqualise(dt)

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
                else
                end
            end
        else
            if self.activeFlows[vehicle] ~= nil then
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
-- Store-item SPS tagging
--
-- Appends a short marker to the display name of every store item that is
-- SPS-compatible, so the shop tile and detail panel read e.g. "Supercis 800 SPS".
-- Compatibility is resolved exactly the way live vehicles/placeables are: the
-- four find*Config* functions above are reused via a lightweight shim carrying
-- only `configFileName` (the single field they read). That covers slurry AND
-- sprayer, manifest matches AND embedded <slurryPipeSystem>/<sprayerPipeSystem>.
--
-- Timing: store items are built during the base StoreManager:loadMapData, which
-- runs before this mod's loadMap. The config maps therefore do not exist at
-- addItem time, so tagging cannot happen there. Instead tagSPSStoreItems() is
-- called once from SPSMod:loadMap after the config maps are populated. Store
-- item names are read from storeItem.name at display time, so mutating the field
-- once here is sufficient for both the tile and the detail view.
-- ---------------------------------------------------------------------------
SlurryPipeManager.STORE_TAG = " SPS"   -- appended suffix; change here to restyle

-- Returns true if the given store item's config file is SPS-compatible.
-- storeItem.xmlFilename is the same full config path Giants reports as
-- vehicle/placeable.configFileName, so the existing tail-match + embedded logic
-- applies unchanged via the shim.
function SlurryPipeManager:isStoreItemSPS(storeItem)
    if storeItem == nil or storeItem.xmlFilename == nil then return false end
    local shim = { configFileName = storeItem.xmlFilename }

    if storeItem.species == StoreSpecies.VEHICLE then
        if self:findVehicleConfigForVehicle(shim) ~= nil then return true end
        if self:findSprayerVehicleConfigForVehicle(shim) ~= nil then return true end
    elseif storeItem.species == StoreSpecies.PLACEABLE then
        if self:findPlaceableConfigForPlaceable(shim) ~= nil then return true end
        if self:findSprayerPlaceableConfigForPlaceable(shim) ~= nil then return true end
    end
    return false
end

-- One-shot pass over the loaded store items, appending STORE_TAG to the name of
-- every SPS-compatible item. Idempotent: an item already carrying the tag is
-- skipped, so a re-run (e.g. store reload) never stacks duplicate suffixes.
function SlurryPipeManager:tagSPSStoreItems()
    if g_storeManager == nil then return end
    local items = g_storeManager:getItems()
    if items == nil then return end

    local tag    = SlurryPipeManager.STORE_TAG
    local tagLen = #tag
    local tagged = 0
    for i = 1, #items do
        local storeItem = items[i]
        if storeItem ~= nil and storeItem.name ~= nil then
            local alreadyTagged = string.sub(storeItem.name, -tagLen) == tag
            if not alreadyTagged and self:isStoreItemSPS(storeItem) then
                storeItem.name = storeItem.name .. tag
                tagged = tagged + 1
            end
        end
    end
    SlurryPipeManager.log("tagSPSStoreItems: tagged %d store item(s)", tagged)
end
