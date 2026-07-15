-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9

-- SPSM_IBC.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: IBC tank spawn / connect / persistence.
-- PURE RELOCATION from scripts/manager/SlurryPipeManager.lua (V1.0.0.8 tag):
-- every function body in this file is byte-identical to the baseline.
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

print("[SPS BUILD] SPSM_IBC 1.0.0.9 loaded")


-- ---------------------------------------------------------------------------
-- applyIbcPersistSetting — flip removeVehicleIfEmpty on every registered IBC
-- source vehicle to match self.ibcPersistWhenEmpty. Called from the settings
-- callback (live change) and after savegame load. Server-authoritative: the
-- FillUnit empty-deletion runs server-side only, so clients need no change.
-- The vanilla value is stashed per-entry on first register so toggling back to
-- "disappear" restores the original behaviour rather than forcing true.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:applyIbcPersistSetting()
    local persist = self.ibcPersistWhenEmpty == true
    for _, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.isSourceVehicle and entry.object ~= nil then
            local spec = entry.object.spec_fillUnit
            if spec ~= nil then
                if entry._ibcOrigRemoveIfEmpty == nil then
                    entry._ibcOrigRemoveIfEmpty = spec.removeVehicleIfEmpty
                end
                if persist then
                    spec.removeVehicleIfEmpty = false
                else
                    spec.removeVehicleIfEmpty = entry._ibcOrigRemoveIfEmpty
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- IBC spawn-and-connect (hold R on an empty sprayer coupler arc)
--
-- Mirrors the slurry chain's "hold R adds docking station". A fresh EMPTY IBC
-- pallet is spawned just in front of the sprayer coupler and a pipe is connected
-- sprayer(outNode) -> IBC(inNode). The player then sets UNLOAD, opens flow to
-- fill it, disconnects, and the IBC is a normal usable/movable pallet.
--
-- Server-authoritative: VehicleLoadingData replicates the spawned pallet to
-- clients automatically, and the connect is broadcast via SPSSprayerConnectEvent.
-- A client-initiated hold-R in MP needs a request event (follow-up); on a client
-- this is a logged no-op for now.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_ibcTankXmlForSprayer(sprayerObject, coupling)
    -- Spawn the IBC that matches the sprayer's current fill type: fertilizer ->
    -- fertilizer tank, herbicide -> herbicide tank. Both are SPS-enabled (i3d
    -- redirect + manifest + shared fillPoints). Unknown/empty -> nil (no spawn).
    local fuIndex  = (coupling ~= nil and coupling.fillUnitIndex) or 1
    local fillType = nil
    if sprayerObject.getFillUnitFillType ~= nil then
        fillType = sprayerObject:getFillUnitFillType(fuIndex)
    end

    -- [SPS] No IBC for an empty sprayer: there is nothing to offload, so hold-R adds
    -- nothing. Explicit fill-level gate (an empty unit also reports UNKNOWN below, but
    -- this covers the case where a type is retained at zero level).
    if sprayerObject.getFillUnitFillLevel ~= nil then
        local lvl = sprayerObject:getFillUnitFillLevel(fuIndex) or 0
        if lvl <= 0 then
            SlurryPipeManager.log("_ibcTankXmlForSprayer: sprayer empty (fu=%s) — no IBC", tostring(fuIndex))
            return nil
        end
    end

    -- [SPS +S&F] Correct-label IBC spawn for any REGISTERED liquid (e.g. TheCodingDad's
    -- Soil & Fertilizer). The held fillType carries the pallet XML it was authored with
    -- (FillTypeDesc.palletFilename, resolved against its own mod's base directory, so it is
    -- a full loadable path with mods in the mods folder). If SPS has a sprayer-source config
    -- registered for that pallet's path — which means the init.lua i3d redirect ALSO carries
    -- it, so the spawned tank gets its coupler node — spawn THAT pallet so the IBC shows the
    -- correct store name / fill type. Anything not registered falls through to the category /
    -- legacy branches below, so native behaviour is unchanged and unknown types still no-op.
    if fillType ~= nil and fillType ~= FillType.UNKNOWN and g_fillTypeManager ~= nil then
        local desc = g_fillTypeManager:getFillTypeByIndex(fillType)
        if desc ~= nil and desc.palletFilename ~= nil and self.sprayerSourceVehicleConfigMap ~= nil then
            local palletLower = desc.palletFilename:lower():gsub("\\", "/")
            for matchPathLower in pairs(self.sprayerSourceVehicleConfigMap) do
                if palletLower:sub(-#matchPathLower) == matchPathLower then
                    SlurryPipeManager.log("_ibcTankXmlForSprayer: fillType=%s -> registered pallet '%s'",
                        tostring(fillType), tostring(desc.palletFilename))
                    return desc.palletFilename
                end
            end
        end

        -- Category classification (native or any mod that folds its liquids into the native
        -- LIQUIDFERTILIZER / HERBICIDE categories, which is how S&F extends them). Picks the
        -- shared vanilla coupler-tank when no specifically-registered pallet matched above.
        if g_fillTypeManager.getIsFillTypeInCategory ~= nil then
            if g_fillTypeManager:getIsFillTypeInCategory(fillType, "HERBICIDE") then
                return "data/objects/pallets/liquidTank/herbicideTank.xml"
            elseif g_fillTypeManager:getIsFillTypeInCategory(fillType, "LIQUIDFERTILIZER") then
                return "data/objects/pallets/liquidTank/fertilizerTank.xml"
            end
        end
    end

    local fertIdx = g_fillTypeManager:getFillTypeIndexByName("LIQUIDFERTILIZER")
    local herbIdx = g_fillTypeManager:getFillTypeIndexByName("HERBICIDE")
    if fillType == fertIdx then
        return "data/objects/pallets/liquidTank/fertilizerTank.xml"
    elseif fillType == herbIdx then
        return "data/objects/pallets/liquidTank/herbicideTank.xml"
    end
    SlurryPipeManager.log("_ibcTankXmlForSprayer: unsupported sprayer fillType=%s (fu=%s) — no IBC spawned",
        tostring(fillType), tostring(fuIndex))
    return nil
end

function SlurryPipeManager:spawnAndConnectIBC(sprayerObject, coupling)
    if sprayerObject == nil or coupling == nil or coupling.isConnected then return end
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        -- MP client: request the server to spawn + connect. VehicleLoadingData is
        -- server-authoritative and replicates the pallet to every peer, and the
        -- connect is broadcast via SPSSprayerConnectEvent, so only the request is sent.
        SlurryPipeManager.log("spawnAndConnectIBC: client — requesting server spawn (coupling id=%s)", tostring(coupling.id))
        SPSIbcSpawnRequestEvent.sendEvent(sprayerObject, coupling.id)
        return
    end

    local tankXml = self:_ibcTankXmlForSprayer(sprayerObject, coupling)
    if tankXml == nil then
        SlurryPipeManager.log("spawnAndConnectIBC: no SPS IBC tank for this sprayer — abort")
        return
    end

    local node = coupling.outNode or coupling.mountNode
    if node == nil or node == 0 then return end
    -- 4 m in front of the coupler (local +Z), dropped to terrain height. The bez
    -- pipe (SPSSprayerPipeVisual) then spans the gap with the same sag rules.
    local px, _, pz = localToWorld(node, 0, 0, 8.0)
    local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
    -- [SPS] Yaw from the node's world FORWARD VECTOR, not Euler extraction.
    -- getWorldRotation returns the (±pi, theta, ±pi) representation for world
    -- yaws beyond ±90 deg; taking ry alone is then ~180 deg off — the IBC spawned
    -- facing the wrong way whenever the sprayer was parked at a "flipped" heading
    -- (the exact mechanism behind the chain-start twist).
    local fdx, _, fdz = localDirectionToWorld(node, 0, 0, 1)
    local ry = math.atan2(fdx, fdz)
    ry = ry + math.pi  -- face the IBC coupler back toward the sprayer (180 deg)

    -- [SPS] Authored spawn point override. If the coupler carries a child node named
    -- "IBCspawnPoint", the modder is dictating placement: reuse its world X/Z and heading
    -- (yaw) but keep Y on the terrain so the tank sits on the ground (hill or flat) and
    -- stays upright. Overrides the legacy pose above; the face-the-coupler reorientation in
    -- onIbcSpawnedForConnect re-checks the same node and skips when present. Node absent ->
    -- legacy placement stands, fully backward compatible.
    if coupling.mountNode ~= nil and coupling.mountNode ~= 0 then
        local function findChildByName(root, targetName)
            if getName(root) == targetName then return root end
            for i = 0, getNumOfChildren(root) - 1 do
                local found = findChildByName(getChildAt(root, i), targetName)
                if found ~= nil then return found end
            end
            return nil
        end
        local spawnPoint = findChildByName(coupling.mountNode, "IBCspawnPoint")
        if spawnPoint ~= nil and spawnPoint ~= 0 then
            px, _, pz = getWorldTranslation(spawnPoint)
            py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
            -- [SPS] Authored heading via forward vector (see note above) — the
            -- node's yaw exactly as placed in the i3d, at any world orientation.
            local sdx, _, sdz = localDirectionToWorld(spawnPoint, 0, 0, 1)
            ry = math.atan2(sdx, sdz)
            SlurryPipeManager.log("spawnAndConnectIBC: using authored IBCspawnPoint pose (yaw=%.3f)", ry)
        end
    end

    local farmId = (sprayerObject.getOwnerFarmId ~= nil and sprayerObject:getOwnerFarmId()) or AccessHandler.EVERYONE

    local data = VehicleLoadingData.new()
    data:setFilename(tankXml)
    data:setPosition(px, py, pz)
    data:setRotation(0, ry, 0)
    data:setPropertyState(VehiclePropertyState.OWNED)
    data:setOwnerFarmId(farmId)
    data:setCustomParameter("spawnEmpty", true)
    data:load(self.onIbcSpawnedForConnect, self, { sprayerObject = sprayerObject, couplingId = coupling.id })
    SlurryPipeManager.log("spawnAndConnectIBC: spawning %s at (%.1f, %.1f, %.1f)", tankXml, px, py, pz)
end

function SlurryPipeManager:onIbcSpawnedForConnect(vehicles, loadState, args)
    if loadState ~= VehicleLoadingState.OK or vehicles == nil or vehicles[1] == nil then
        SlurryPipeManager.log("onIbcSpawnedForConnect: spawn failed (state=%s)", tostring(loadState))
        return
    end
    local ibc = vehicles[1]

    -- onFinishedLoading should have registered the IBC as a sprayer source;
    -- guard in case load ordering differs.
    local ibcEntry = nil
    for _, e in ipairs(self.registeredSprayerPlaceables) do
        if e.object == ibc then ibcEntry = e break end
    end
    if ibcEntry == nil then
        self:registerSprayerSourceVehicle(ibc)
        for _, e in ipairs(self.registeredSprayerPlaceables) do
            if e.object == ibc then ibcEntry = e break end
        end
    end
    if ibcEntry == nil or #ibcEntry.couplings == 0 then
        SlurryPipeManager.log("onIbcSpawnedForConnect: spawned IBC not registered / no coupling")
        return
    end

    local sprayerObject = args and args.sprayerObject
    local couplingId    = args and args.couplingId
    local ibcCouplingId = ibcEntry.couplings[1].id

    -- [SPS] Deterministically face the spawned IBC's coupler at the sprayer coupler.
    -- The sprayer pipe's end tangent is each node's local +Z (SPSSprayerPipeVisual), so
    -- we rotate the IBC until its coupler's +Z points at the sprayer coupler. This is
    -- geometry, not a calibrated angle, so it is correct for ANY tank i3d — replacing
    -- the old fixed 180 that only matched one authored coupler forward. setAbsolutePosition
    -- is the vanilla physics-safe teleport (Vehicle.lua). Iterates a few times because the
    -- coupler orbits the root as the body turns; converges in 1-2 passes for a 4 m gap.
    -- Guarded to single-component pallets so the reference position cannot drift. Server
    -- side only (this callback is server-only); the reoriented pose replicates normally.
    -- [SPS] Skipped when the sprayer coupler carries an IBCspawnPoint child: that node
    -- already fixed the tank's heading in spawnAndConnectIBC, so re-facing it here would
    -- fight the authored pose. Re-derived from the sprayer coupler (no threaded state).
    local sprCoupForSpawnCheck = self:_findSprayerCouplingById(sprayerObject, couplingId, false)
                              or self:_findSprayerCouplingById(sprayerObject, couplingId, true)
    local hasAuthoredSpawn = false
    if sprCoupForSpawnCheck ~= nil and sprCoupForSpawnCheck.mountNode ~= nil and sprCoupForSpawnCheck.mountNode ~= 0 then
        local function findChildByName(root, targetName)
            if getName(root) == targetName then return root end
            for i = 0, getNumOfChildren(root) - 1 do
                local f = findChildByName(getChildAt(root, i), targetName)
                if f ~= nil then return f end
            end
            return nil
        end
        hasAuthoredSpawn = findChildByName(sprCoupForSpawnCheck.mountNode, "IBCspawnPoint") ~= nil
    end
    if not hasAuthoredSpawn then
    do
        local ibcCoup = ibcEntry.couplings[1]
        local ibcNode = ibcCoup.outNode or ibcCoup.mountNode
        local sprCoup = self:_findSprayerCouplingById(sprayerObject, couplingId, false)
                     or self:_findSprayerCouplingById(sprayerObject, couplingId, true)
        local sprNode = sprCoup ~= nil and (sprCoup.inNode or sprCoup.mountNode) or nil
        local root    = ibc.rootNode
        if ibcNode ~= nil and ibcNode ~= 0 and sprNode ~= nil and sprNode ~= 0
        and root ~= nil and root ~= 0 and ibc.setAbsolutePosition ~= nil
        and ibc.components ~= nil and #ibc.components == 1 then
            for _ = 1, 4 do
                local fx, _, fz = localDirectionToWorld(ibcNode, 0, 0, 1)   -- coupler +Z (pipe tangent)
                local cx, _, cz = getWorldTranslation(ibcNode)
                local sx, _, sz = getWorldTranslation(sprNode)
                local delta = math.atan2(sx - cx, sz - cz) - math.atan2(fx, fz)
                while delta >  math.pi do delta = delta - 2 * math.pi end
                while delta < -math.pi do delta = delta + 2 * math.pi end
                if math.abs(delta) < 0.01 then break end
                local rx, ry, rz = getWorldTranslation(root)
                local _, ryaw, _ = getWorldRotation(root)
                ibc:setAbsolutePosition(rx, ry, rz, 0, ryaw + delta, 0)
            end
            SlurryPipeManager.log("onIbcSpawnedForConnect: IBC oriented so its coupler faces the sprayer")
        end
    end
    end

    -- Node roles for the spawned connection: the pipe starts at the IBC (outNode)
    -- and ends at the sprayer (inNode). applySprayerConnect always draws
    -- couplingA.outNode -> couplingB.inNode, so the IBC is couplingA and the
    -- sprayer is couplingB here (sprayer end = inNode, IBC end = outNode).
    self:applySprayerConnectById(ibc, ibcCouplingId, sprayerObject, couplingId)
    SPSSprayerConnectEvent.sendEvent(ibc, ibcCouplingId, sprayerObject, couplingId)
    -- [SPS MP] The freshly spawned IBC is often not yet network-known on clients
    -- when this broadcast fires, so the connect never arrives there — the client
    -- keeps "connect pipe" and no visual while every other machine shows the
    -- bond. Re-send twice after the vehicle has had time to sync; clients that
    -- already applied it no-op via the applySprayerConnect idempotency guard.
    if g_server ~= nil then
        if self._pendingIbcConnectResends == nil then self._pendingIbcConnectResends = {} end
        table.insert(self._pendingIbcConnectResends, {
            ownerA = ibc, idA = ibcCouplingId, ownerB = sprayerObject, idB = couplingId,
            nextAt = (g_time or 0) + 1000, attempts = 0,
        })
    end
    SlurryPipeManager.log("onIbcSpawnedForConnect: spawned + connected IBC %s", tostring(ibc.configFileName))
end
