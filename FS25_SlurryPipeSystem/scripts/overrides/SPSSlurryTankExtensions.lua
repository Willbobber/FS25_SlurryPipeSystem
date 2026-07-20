-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9.23
--
-- SPSSlurryTankExtensions.lua
-- ---------------------------------------------------------------------------
-- Disables the vanilla silo EXTENSION system for liquid-manure tanks only.
--
-- Why: SPS models each slurry store as one standalone vessel (fill plane,
-- solids/DM pools, couplers). The vanilla extension system pools an
-- isExtension storage into every supportsExtension station in radius, which
-- silently merges capacities behind SPS's back. Slurry tank XMLs ship with
-- these flags on (baseTank.xml / liquidManureTank.xml:
--   loadingStation#supportsExtension="true"
--   unloadingStation#supportsExtension="true"
--   storage#isExtension="true").
--
-- How (verified against vanilla sources, no game files touched):
--   StorageSystem:addStorage           consults storage.isExtension at add
--   StorageSystem:addLoadingStation    consults station.supportsExtension at add
--   StorageSystem:addUnloadingStation  consults station.supportsExtension at add
-- These three are wrapped below; for liquid-manure objects the flag is forced
-- false BEFORE the original runs, so they never enter storageExtensions /
-- extendableLoadingStations / extendableUnloadingStations. Everything else —
-- including the silo's DIRECT link between its own stations and its own
-- storage (PlaceableSilo:onFinalizePlacement -> addStorageToUnloadingStation /
-- addStorageToLoadingStation) — is untouched, so grain silos and their
-- extensions keep working exactly as vanilla.
--
-- Detection is by supported fill type, not store text: a storage counts as a
-- slurry tank when its fillTypes map (Storage:load builds it from either
-- fillTypes="LIQUIDMANURE" or fillTypeCategories="slurryTank") supports
-- LIQUIDMANURE or DIGESTATE. Stations are judged by the owning placeable's
-- spec_silo.storages (both StorageSystem add calls receive the placeable).
--
-- MP: runs identically on server and clients (both build stations/storages
-- from the same XML), fully deterministic — no sync needed.
-- ---------------------------------------------------------------------------

print("[SPS BUILD] SPSSlurryTankExtensions 1.0.0.9.23 loaded")

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
local function storageIsSlurry(storage)
    if storage == nil or storage.getIsFillTypeSupported == nil then return false end
    if FillType.LIQUIDMANURE ~= nil and storage:getIsFillTypeSupported(FillType.LIQUIDMANURE) then
        return true
    end
    if FillType.DIGESTATE ~= nil and storage:getIsFillTypeSupported(FillType.DIGESTATE) then
        return true
    end
    return false
end

local function placeableIsSlurrySilo(placeable)
    if placeable == nil or placeable.spec_silo == nil
    or placeable.spec_silo.storages == nil then
        return false
    end
    for _, storage in ipairs(placeable.spec_silo.storages) do
        if storageIsSlurry(storage) then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- StorageSystem wraps — flags cleared BEFORE the original consults them.
-- All wraps are additive and fail-open: any error is contained and the
-- original vanilla behaviour proceeds.
-- ---------------------------------------------------------------------------
local origAddStorage = StorageSystem.addStorage
function StorageSystem:addStorage(storage)
    local ok, err = pcall(function()
        if storage ~= nil and storage.isExtension == true and storageIsSlurry(storage) then
            storage.isExtension = false
            log("cleared isExtension on slurry storage (capacity=%s)",
                tostring(storage.capacity))
        end
    end)
    if not ok then
        print("[SPS TANK EXT] ERROR in addStorage wrap: " .. tostring(err))
    end
    return origAddStorage(self, storage)
end

local origAddLoadingStation = StorageSystem.addLoadingStation
function StorageSystem:addLoadingStation(station, placeable)
    local ok, err = pcall(function()
        if station ~= nil and station.supportsExtension == true
        and placeableIsSlurrySilo(placeable) then
            station.supportsExtension = false
            log("cleared supportsExtension on slurry loading station (%s)",
                tostring(placeable.configFileName))
        end
    end)
    if not ok then
        print("[SPS TANK EXT] ERROR in addLoadingStation wrap: " .. tostring(err))
    end
    return origAddLoadingStation(self, station, placeable)
end

local origAddUnloadingStation = StorageSystem.addUnloadingStation
function StorageSystem:addUnloadingStation(station, placeable)
    local ok, err = pcall(function()
        if station ~= nil and station.supportsExtension == true
        and placeableIsSlurrySilo(placeable) then
            station.supportsExtension = false
            log("cleared supportsExtension on slurry unloading station (%s)",
                tostring(placeable ~= nil and placeable.configFileName or "?"))
        end
    end)
    if not ok then
        print("[SPS TANK EXT] ERROR in addUnloadingStation wrap: " .. tostring(err))
    end
    return origAddUnloadingStation(self, station, placeable)
end
