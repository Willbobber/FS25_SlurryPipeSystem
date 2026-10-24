-- ===========================================================================
-- SPSShearBoltPersistence  [SPS 1.0.1.8]
-- ---------------------------------------------------------------------------
-- Saves each machine's shear bolt wear / snapped state into the SPS savegame
-- file (FS25_SlurryPipeSystem.xml), keyed by the vehicle's uniqueId (stable
-- across save/load, Vehicle.lua saves it as vehicles.vehicle(?)#uniqueId).
-- Before this a snapped bolt came back whole after a reload.
--
-- Load fills SPSShearBolt.pendingByUid; SPSShearBolt.update applies an entry
-- the first time it ticks that vehicle (server only - the snap then reaches
-- clients through the normal SPSShearBoltEvent / join dump).
-- Piggybacks the manager's save/load calls like SPSSeparator / chain bonds,
-- so it must load AFTER SlurryPipeManager.lua.
-- ===========================================================================

SPSShearBoltPersistence = {}

local ROOT = "slurryPipeSystem.shearBolts.vehicle(%d)"

function SPSShearBoltPersistence.save(manager, savePath)
    if g_server == nil or savePath == nil then return end
    local xmlFile = XMLFile.loadIfExists("spsShearSave", savePath)
    if xmlFile == nil then return end
    local idx = 0
    for _, vEntry in ipairs(manager.registeredVehicles or {}) do
        local v, s = vEntry.vehicle, vEntry.state
        if v ~= nil and s ~= nil and v.getUniqueId ~= nil and ((s.shearWear or 0) > 0 or s.shearSnapped == true) then
            local uid = v:getUniqueId()
            if uid ~= nil then
                local key = string.format(ROOT, idx)
                xmlFile:setString(key .. "#uniqueId", uid)
                xmlFile:setFloat(key .. "#wear", s.shearWear or 0)
                xmlFile:setBool(key .. "#snapped", s.shearSnapped == true)
                idx = idx + 1
            end
        end
    end
    xmlFile:save()
    xmlFile:delete()
end

function SPSShearBoltPersistence.load(savePath)
    SPSShearBolt.pendingByUid = nil
    if g_server == nil or savePath == nil then return end
    local xmlFile = XMLFile.loadIfExists("spsShearLoad", savePath)
    if xmlFile == nil then return end
    local pending, n = {}, 0
    local idx = 0
    while true do
        local key = string.format(ROOT, idx)
        local uid = xmlFile:getString(key .. "#uniqueId")
        if uid == nil then break end
        pending[uid] = { wear = xmlFile:getFloat(key .. "#wear", 0), snapped = xmlFile:getBool(key .. "#snapped", false) }
        n = n + 1
        idx = idx + 1
    end
    xmlFile:delete()
    if n > 0 then
        SPSShearBolt.pendingByUid = pending
    end
end

local origSave = SlurryPipeManager.saveCouplingConnections
function SlurryPipeManager:saveCouplingConnections(savePath)
    origSave(self, savePath)
    local ok, err = pcall(SPSShearBoltPersistence.save, self, savePath)
    if not ok then
        print("[SPS SHEAR] ERROR saving shear bolt state: " .. tostring(err))
    end
end

local origLoad = SlurryPipeManager.loadCouplingConnections
function SlurryPipeManager:loadCouplingConnections(savePath)
    local ok, err = pcall(SPSShearBoltPersistence.load, savePath)
    if not ok then
        print("[SPS SHEAR] ERROR loading shear bolt state: " .. tostring(err))
    end
    origLoad(self, savePath)
end
