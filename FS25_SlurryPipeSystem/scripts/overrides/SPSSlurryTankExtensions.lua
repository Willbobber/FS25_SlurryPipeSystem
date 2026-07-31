-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.10.1
--
-- SPSSlurryTankExtensions.lua
-- ---------------------------------------------------------------------------
-- Filters the vanilla silo EXTENSION system for slurry storages — replaces
-- the 1.0.0.9.x flag-clearing approach (which also broke husbandries that
-- have no internal slurry storage and rely on a nearby liquid-manure tank:
-- PlaceableHusbandryLiquidManure:getConditionInfos shows
-- "info_husbandryMissingLiquidManureTank" and updateProduction throttles
-- output when getHusbandryCapacity(LIQUIDMANURE) == 0).
--
-- Vanilla flags (baseTank.xml storage#isExtension="true",
-- station#supportsExtension="true") are now left UNTOUCHED so discovery
-- works exactly as vanilla. Filtering instead happens at the single choke
-- point every extension link direction funnels through (all verified in
-- vanilla source):
--   PlaceableHusbandry:onFinalizePlacement / setOwnerFarmId / onBuy
--   PlaceableSilo:onFinalizePlacement
--   PlaceableSiloExtension:onFinalizePlacement
-- all call StorageSystem:addStorageToUnloadingStation(s) /
-- addStorageToLoadingStation(s), and the plural helpers call the singular
-- functions internally (StorageSystem.lua) — so wrapping the two singular
-- functions covers barn-first, tank-first, buy and farm-transfer cases.
--
-- Link rules (only applied when the INCOMING storage supports LIQUIDMANURE
-- or DIGESTATE; everything else passes straight to vanilla):
--   1. Storage -> a station on its OWN placeable          -> ALLOW (direct
--      vanilla link, spec_silo.storages / spec_husbandry.storage checked).
--   2. Slurry storage -> foreign station on a spec_silo
--      placeable (tank/silo)                              -> BLOCK. Kills
--      tank<->tank pooling so every SPS store keeps its own fill level
--      (separator-safe).
--   3. Slurry storage -> foreign station on a
--      spec_husbandry placeable                           -> ALLOW only if
--      that husbandry's OWN storage has no capacity for the shared slurry
--      fill type (Storage:getCapacity = capacities[ft] or shared capacity;
--      an explicit capacity="0" correctly reads as 0). A self-contained
--      cow shed (own 100000 l) stays standalone; a barn with no internal
--      slurry storage links to the nearby tank and keeps producing.
--   4. Any other owner (production points, etc.) or a station with no
--      owningPlaceable                                    -> ALLOW (vanilla).
--
-- Station ownership: both PlaceableHusbandry (lines 80/101) and
-- PlaceableSilo (lines 60/64) set station.owningPlaceable at load, before
-- any link is formed.
--
-- MP: runs identically on server and clients (both build stations/storages
-- from the same XML and run the same finalize paths), fully deterministic —
-- no sync needed.
--
-- All wraps are fail-open: any error in the decision is contained and the
-- original vanilla behaviour proceeds.
-- ---------------------------------------------------------------------------

print("[SPS BUILD] SPSSlurryTankExtensions 1.0.0.10.1 loaded")

SPSSlurryTankExtensions = {}

-- Debug: central registry channel "SPSSlurryTankExtensions" (SPSDebugConfig).
-- Class field pushed by applyAll(); call-time isOn() gives instant toggling.
-- Ships false.
SPSSlurryTankExtensions.DEBUG = false
local function log(fmt, ...)
    if not (SPSSlurryTankExtensions.DEBUG
        or (SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSSlurryTankExtensions"))) then
        return
    end
    if select("#", ...) > 0 then
        print("[SPS TANK EXT] " .. string.format(fmt, ...))
    else
        print("[SPS TANK EXT] " .. tostring(fmt))
    end
end

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------

-- The slurry fill types this filter cares about. Built lazily so FillType
-- indices are resolved at first use, after fill types are registered.
local slurryFillTypes = nil
local function getSlurryFillTypes()
    if slurryFillTypes == nil then
        slurryFillTypes = {}
        if FillType.LIQUIDMANURE ~= nil then
            table.insert(slurryFillTypes, FillType.LIQUIDMANURE)
        end
        if FillType.DIGESTATE ~= nil then
            table.insert(slurryFillTypes, FillType.DIGESTATE)
        end
    end
    return slurryFillTypes
end

local function storageIsSlurry(storage)
    if storage == nil or storage.getIsFillTypeSupported == nil then return false end
    for _, ft in ipairs(getSlurryFillTypes()) do
        if storage:getIsFillTypeSupported(ft) then
            return true
        end
    end
    return false
end

-- Rule 1: is this storage one of the owning placeable's OWN storages?
local function storageBelongsToPlaceable(storage, placeable)
    if storage == nil or placeable == nil then return false end
    if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
        for _, own in ipairs(placeable.spec_silo.storages) do
            if own == storage then
                return true
            end
        end
    end
    if placeable.spec_husbandry ~= nil and placeable.spec_husbandry.storage == storage then
        return true
    end
    return false
end

-- Rule 3: does this husbandry's OWN storage already provide capacity for any
-- slurry fill type the incoming storage supports?
-- Storage:getCapacity(ft) = self.capacities[ft] or self.capacity (verified,
-- Storage.lua) — an explicit per-type capacity="0" returns 0 (0 is truthy in
-- Lua so the 'or' does not override it); a type listed via #fillTypes with no
-- per-type capacity falls back to the shared pool capacity, i.e. the barn CAN
-- store it itself and counts as self-contained.
local function husbandryHasOwnSlurryCapacity(placeable, incomingStorage)
    local spec = placeable.spec_husbandry
    if spec == nil or spec.storage == nil then return false end
    local own = spec.storage
    if own.fillTypes == nil or own.getCapacity == nil then return false end
    for _, ft in ipairs(getSlurryFillTypes()) do
        if incomingStorage:getIsFillTypeSupported(ft)
        and own.fillTypes[ft] == true
        and (own:getCapacity(ft) or 0) > 0 then
            return true
        end
    end
    return false
end

-- Central decision. Returns true when the link must be blocked.
local function shouldBlockLink(storage, station, stationKind)
    if storage == nil or station == nil then return false end
    if not storageIsSlurry(storage) then return false end

    local owner = station.owningPlaceable
    if owner == nil then
        return false -- rule 4: unknown owner -> vanilla
    end

    if storageBelongsToPlaceable(storage, owner) then
        return false -- rule 1: own direct link -> vanilla
    end

    if owner.spec_silo ~= nil then
        -- rule 2: foreign slurry storage into a tank/silo station
        log("BLOCK slurry link -> foreign silo %s station (%s)",
            stationKind, tostring(owner.configFileName))
        return true
    end

    if owner.spec_husbandry ~= nil then
        -- rule 3: husbandry — allow only if it has no own slurry capacity
        if husbandryHasOwnSlurryCapacity(owner, storage) then
            log("BLOCK slurry link -> self-contained husbandry %s station (%s)",
                stationKind, tostring(owner.configFileName))
            return true
        end
        log("ALLOW slurry link -> husbandry with no own slurry capacity %s station (%s)",
            stationKind, tostring(owner.configFileName))
        return false
    end

    return false -- rule 4: anything else -> vanilla
end

-- ---------------------------------------------------------------------------
-- StorageSystem wraps — the two singular add functions are the choke point
-- for every extension link direction (the plural helpers call these).
-- Blocked links return false, matching the vanilla success/failure contract.
-- ---------------------------------------------------------------------------
local origAddStorageToUnloadingStation = StorageSystem.addStorageToUnloadingStation
function StorageSystem:addStorageToUnloadingStation(storage, unloadingStation)
    local ok, block = pcall(shouldBlockLink, storage, unloadingStation, "unloading")
    if not ok then
        print("[SPS TANK EXT] ERROR in addStorageToUnloadingStation wrap: " .. tostring(block))
        block = false
    end
    if block == true then
        return false
    end
    return origAddStorageToUnloadingStation(self, storage, unloadingStation)
end

local origAddStorageToLoadingStation = StorageSystem.addStorageToLoadingStation
function StorageSystem:addStorageToLoadingStation(storage, loadingStation)
    local ok, block = pcall(shouldBlockLink, storage, loadingStation, "loading")
    if not ok then
        print("[SPS TANK EXT] ERROR in addStorageToLoadingStation wrap: " .. tostring(block))
        block = false
    end
    if block == true then
        return false
    end
    return origAddStorageToLoadingStation(self, storage, loadingStation)
end
