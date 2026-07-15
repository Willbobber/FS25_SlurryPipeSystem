-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9

-- SPSM_Sprayers.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: fertiliser/herbicide sprayer subsystem.
-- PURE RELOCATION from scripts/manager/SlurryPipeManager.lua (V1.0.0.8 tag):
-- every function body in this file is byte-identical to the baseline.
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

print("[SPS BUILD] SPSM_Sprayers 1.0.0.9.16 loaded")


-- Applies saved sprayer animation state to a newly registered vehicle.
-- Position-based matching with 0.1m tolerance.
function SlurryPipeManager:_applyPendingSprayerAnimation(vehicle, entry)
    SlurryPipeManager.log("_applyPendingSprayerAnimation: %s", tostring(vehicle and vehicle.configFileName))
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
                    return true
                end
            end
        end
    end
    return false
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
    SlurryPipeManager.log("loadSprayerVehicleConfigs: enter")
    local configRoot   = modDirectory .. "configs/"
    local manifestPath = modDirectory .. "configs/spsConfigManifest.xml"
    local xmlFile = XMLFile.load("spsManifest", manifestPath)
    if xmlFile == nil then
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
            else
                local xmlFilePath = configRoot .. cfgDir .. "/fillPoints.xml"
                if fileExists(xmlFilePath) then
                    self.sprayerVehicleConfigMap[matchPath:lower()] = {
                        xmlFilePath = xmlFilePath,
                        matchPath   = matchPath,
                    }
                else
                end
            end
        end
        idx = idx + 1
    end
    xmlFile:delete()
    local count = 0
    for _ in pairs(self.sprayerVehicleConfigMap) do count = count + 1 end
end

function SlurryPipeManager:loadSprayerPlaceableConfigs(modDirectory)
    SlurryPipeManager.log("loadSprayerPlaceableConfigs: enter")
    local configRoot   = modDirectory .. "configs/"
    local manifestPath = modDirectory .. "configs/spsConfigManifest.xml"
    local xmlFile = XMLFile.load("spsManifest", manifestPath)
    if xmlFile == nil then
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
            else
                local xmlFilePath = configRoot .. cfgDir .. "/fillPoints.xml"
                if fileExists(xmlFilePath) then
                    self.sprayerPlaceableConfigMap[matchPath:lower()] = {
                        xmlFilePath = xmlFilePath,
                        matchPath   = matchPath,
                    }
                else
                end
            end
        end
        idx = idx + 1
    end
    xmlFile:delete()
    local count = 0
    for _ in pairs(self.sprayerPlaceableConfigMap) do count = count + 1 end
end

-- Sprayer SOURCE vehicles: basegame/mod IBC liquid tanks that a sprayer draws
-- from via pipe. Manifest section <sprayerSourceVehicleConfigs>; loader mirrors
-- loadSprayerVehicleConfigs exactly. A missing section yields zero configs (the
-- hasProperty break), so this is a no-op until IBC entries are added.
function SlurryPipeManager:loadSprayerSourceVehicleConfigs(modDirectory)
    SlurryPipeManager.log("loadSprayerSourceVehicleConfigs: enter")
    local configRoot   = modDirectory .. "configs/"
    local manifestPath = modDirectory .. "configs/spsConfigManifest.xml"
    local xmlFile = XMLFile.load("spsManifest", manifestPath)
    if xmlFile == nil then
        return
    end
    local idx = 0
    while true do
        local key = string.format("spsConfigManifest.sprayerSourceVehicleConfigs.vehicle(%d)", idx)
        if not xmlFile:hasProperty(key) then break end
        local matchPath = xmlFile:getString(key .. "#path")
        if matchPath ~= nil and matchPath ~= "" then
            local cfgDir = xmlFile:getString(key .. "#configFolder")
            if cfgDir == nil or cfgDir == "" then
                cfgDir = matchPath:match("^(.*)/[^/]+%.xml$")
            end
            if cfgDir == nil then
            else
                local xmlFilePath = configRoot .. cfgDir .. "/fillPoints.xml"
                if fileExists(xmlFilePath) then
                    self.sprayerSourceVehicleConfigMap[matchPath:lower()] = {
                        xmlFilePath = xmlFilePath,
                        matchPath   = matchPath,
                    }
                else
                end
            end
        end
        idx = idx + 1
    end
    xmlFile:delete()
    local count = 0
    for _ in pairs(self.sprayerSourceVehicleConfigMap) do count = count + 1 end
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
    -- See findVehicleConfigForVehicle for rationale: vehicle.xmlFile's handle can
    -- be dead at onFinishedLoading while the wrapper is still non-nil, which crashes
    -- hasProperty. Load a fresh owned handle from the vehicle's config file instead.
    local embeddedXml = XMLFile.loadIfExists("spsEmbeddedSprayerCheck", vehicle.configFileName, nil)
    if embeddedXml ~= nil then
        local isEmbedded = embeddedXml:hasProperty("vehicle.sprayerPipeSystem")
        embeddedXml:delete()
        if isEmbedded then
            SlurryDebug.log("findSprayerVehicleConfigForVehicle: embedded <sprayerPipeSystem> found in " .. tostring(vehicle.configFileName))
            return {
                xmlFilePath  = vehicle.configFileName,    -- used for nodeTree path resolution
                xmlKeyPrefix = "vehicle.",                -- prepended ahead of "sprayerPipeSystem..."
                isEmbedded   = true,
            }
        end
    end

    local cfn = vehicle.configFileName:lower():gsub("\\", "/")
    for matchPathLower, config in pairs(self.sprayerVehicleConfigMap) do
        if cfn:sub(-#matchPathLower) == matchPathLower then
            return config
        end
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- [SPS PERF 1.0.0.9.1] Cached front for findSprayerVehicleConfigForVehicle.
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
SlurryPipeManager._findSprayerVehicleConfigUncached = SlurryPipeManager.findSprayerVehicleConfigForVehicle
function SlurryPipeManager:findSprayerVehicleConfigForVehicle(vehicle)
    if vehicle == nil or vehicle.configFileName == nil then
        return SlurryPipeManager._findSprayerVehicleConfigUncached(self, vehicle)
    end
    local cache = self._sprayerVehicleCfgCache
    if cache == nil then
        cache = {}
        self._sprayerVehicleCfgCache = cache
    end
    local hit = cache[vehicle.configFileName]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    local config = SlurryPipeManager._findSprayerVehicleConfigUncached(self, vehicle)
    if config == nil then
        cache[vehicle.configFileName] = false
    else
        cache[vehicle.configFileName] = config
    end
    return config
end

function SlurryPipeManager:findSprayerPlaceableConfigForPlaceable(placeable)
    if placeable.configFileName == nil then return nil end

    -- Embedded config check: a placeable whose own XML carries a <sprayerPipeSystem>
    -- element is self-contained. See findSprayerVehicleConfigForVehicle for rationale.
    -- See findVehicleConfigForVehicle for rationale: placeable.xmlFile's handle can
    -- be dead while the wrapper is still non-nil, crashing hasProperty. Load a fresh
    -- owned handle from the placeable's config file instead.
    local embeddedXml = XMLFile.loadIfExists("spsEmbeddedPlaceableSprayerCheck", placeable.configFileName, nil)
    if embeddedXml ~= nil then
        local isEmbedded = embeddedXml:hasProperty("placeable.sprayerPipeSystem")
        embeddedXml:delete()
        if isEmbedded then
            SlurryDebug.log("findSprayerPlaceableConfigForPlaceable: embedded <sprayerPipeSystem> found in " .. tostring(placeable.configFileName))
            return {
                xmlFilePath  = placeable.configFileName,
                xmlKeyPrefix = "placeable.",
                isEmbedded   = true,
            }
        end
    end

    local cfn = placeable.configFileName:lower():gsub("\\", "/")
    for matchPathLower, config in pairs(self.sprayerPlaceableConfigMap) do
        if cfn:sub(-#matchPathLower) == matchPathLower then
            return config
        end
    end
    return nil
end

-- Sprayer SOURCE vehicle lookup (IBC liquid tanks). A distinct embedded element
-- <sprayerPipeSystemSource> keeps third-party source tanks fully separate from the
-- active-sprayer embedded path (<sprayerPipeSystem>), so neither registration ever
-- captures the other's vehicles. See findSprayerVehicleConfigForVehicle for the
-- fresh-handle rationale (vehicle.xmlFile can be dead at onFinishedLoading).
function SlurryPipeManager:findSprayerSourceVehicleConfigForVehicle(vehicle)
    if vehicle.configFileName == nil then return nil end

    local embeddedXml = XMLFile.loadIfExists("spsEmbeddedSprayerSourceCheck", vehicle.configFileName, nil)
    if embeddedXml ~= nil then
        local isEmbedded = embeddedXml:hasProperty("vehicle.sprayerPipeSystemSource")
        embeddedXml:delete()
        if isEmbedded then
            SlurryDebug.log("findSprayerSourceVehicleConfigForVehicle: embedded <sprayerPipeSystemSource> found in " .. tostring(vehicle.configFileName))
            return {
                xmlFilePath  = vehicle.configFileName,
                xmlKeyPrefix = "vehicle.",
                isEmbedded   = true,
            }
        end
    end

    local cfn = vehicle.configFileName:lower():gsub("\\", "/")
    for matchPathLower, config in pairs(self.sprayerSourceVehicleConfigMap) do
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
    SlurryPipeManager.log("registerSprayerVehicle: enter %s", tostring(vehicle and vehicle.configFileName))
    for _, entry in ipairs(self.registeredSprayerVehicles) do
        if entry.object == vehicle then return end
    end

    local config = self:findSprayerVehicleConfigForVehicle(vehicle)
    if config == nil then
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
        end
    end

    local function findLinkedNode(name)
        if name == nil or name == "" then return nil end
        for _, n in ipairs(entry.linkedNodes) do
            if getName(n) == name then return n end
        end
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
            else
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
            else
            end
        end
    end

    -- Load vehicle-level load animation (e.g. toggleCover), shared across all couplings
    local vehicleLoadAnimName = xmlFile:getString(kp .. "loadAnimation#name")

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
                if node == nil or node == 0 or not entityExists(node) then return end
                for i = 0, getNumOfChildren(node) - 1 do
                    local child = getChildAt(node, i)
                    local n = getName(child)
                    if n == "inNode" then inNode = child
                    elseif n == "outNode" then outNode = child
                    else findInOut(child) end
                end
            end
            findInOut(mountNode)
            -- Per-coupler fillType restriction (sprayerPipeCoupling#fillType). Optional.
            -- When set, only that fillType may pass through this coupler in either
            -- direction; enforced in tickSprayerFlow. nil => unrestricted (any type).
            local restrictFillType = nil
            local restrictFillTypeName = xmlFile:getString(cKey .. "#fillType")
            if restrictFillTypeName ~= nil then
                restrictFillType = g_fillTypeManager:getFillTypeIndexByName(restrictFillTypeName)
                if restrictFillType == nil then
                    SlurryPipeManager.log("registerSprayerVehicle: unknown coupling #fillType '%s' (coupling id=%s) — no restriction applied",
                        tostring(restrictFillTypeName), tostring(couplingId))
                end
            end
            local couplingEntry = {
                id                       = couplingId,
                mountNode                = mountNode,
                inNode                   = inNode,
                outNode                  = outNode,
                flowDirection            = xmlFile:getString(cKey .. "#flowDirection", "BOTH"),
                restrictFillType         = restrictFillType,
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
                SlurryPipeManager.log("sprayer bind DIAG (vehicle): id=%s connIds=%s/%s bound=%s/%s",
                    tostring(couplingEntry.id), tostring(couplingEntry.connectorAnimationId), tostring(couplingEntry.valveAnimationId),
                    tostring(couplingEntry.connectorAnim ~= nil), tostring(couplingEntry.valveAnim ~= nil))
            end
            table.insert(entry.couplings, couplingEntry)
            -- Control node activatable handles connect/disconnect for vehicles with sprayerPumpControls.
            -- SPSSprayerPipeActivatable is not registered; control node is single interaction point.
        else
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
        else
        end
        pcIndex = pcIndex + 1
    end

    if xmlFileOwned then xmlFile:delete() end
    table.insert(self.registeredSprayerVehicles, entry)
    
    -- Restore animation state from save if available
    self:_applyPendingSprayerAnimation(vehicle, entry)
    -- [SPS MP] A just-registered sprayer may be the target of a queued connect.
    self:_tryResolveSprayerConnects()
    
end

-- ---------------------------------------------------------------------------
-- Sprayer registration — placeable
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.4] Storage fillType seeding — "SPS xml controls the store".
--
-- A sprayerPipeCoupling that declares fillType="X" is a statement that X must
-- flow through this store. Vanilla Storage only accepts types listed in the
-- PLACEABLE's own xml (getFreeCapacity returns 0 for anything else), which
-- forced map/base xml edits. This seeds the live Storage instead — the same
-- philosophy as the vehicle-side WATER line in registerVehicle
-- (fillUnit.supportedFillTypes[WATER] = true), extended to stores.
--
-- Vanilla ground truth (Storage.lua): a supported type consists of SIX pieces
-- of state — fillTypes[ft], fillLevels[ft], fillLevelsLastSynced[ft],
-- fillLevelsLastPublished[ft], an entry in sortedFillTypes, and (optionally)
-- capacities[ft]. All but capacities are seeded; capacity intentionally falls
-- through to the shared self.capacity (getCapacity does this natively), so
-- seeded types share the tank volume — correct for closed amount-only tanks.
--
-- MP: join/update streams iterate sortedFillTypes on BOTH ends. Seeding runs
-- deterministically on every machine at register time from the same SPS xml,
-- and sortedFillTypes is re-sorted after seeding, so host and client iterate
-- identical lists. Savegame: saveToXMLFile iterates fillLevels (seeded types
-- included, by NAME); loadFromXMLFile restores them because seeding runs at
-- placeable finalize, before savegame level restore.
--
-- Modder respect: strictly ADDITIVE. Existing types and
-- supportsMultipleFillTypes are never touched (per-type capacities are only
-- written for types whose couplers declare #capacity — the SPS xml is then
-- authoritative for that type's volume), so a modder store that already
-- lists many fillTypes keeps them all; SPS only adds coupler-declared types
-- the store lacks. Full opt-out for modders shipping their own SPS config:
--   <sprayerPipeCouplings storageFillTypeControl="store">
-- ("store" = never seed; couplers then only ROUTE among the store's own types.
--  Default "sps" = seed missing declared types.)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_seedStorageFillTypes(storage, couplings, ownerName, extraTypes)
    if storage == nil or storage.fillTypes == nil or storage.fillLevels == nil
    or storage.sortedFillTypes == nil then
        return
    end
    local added = nil
    for _, sc in ipairs(couplings or {}) do
        local ft = sc.restrictFillType
        if ft ~= nil and storage.fillTypes[ft] ~= true then
            storage.fillTypes[ft]  = true
            storage.fillLevels[ft] = storage.fillLevels[ft] or 0
            if storage.fillLevelsLastSynced ~= nil then
                storage.fillLevelsLastSynced[ft] = storage.fillLevelsLastSynced[ft] or 0
            end
            if storage.fillLevelsLastPublished ~= nil then
                storage.fillLevelsLastPublished[ft] = storage.fillLevelsLastPublished[ft] or 0
            end
            table.insert(storage.sortedFillTypes, ft)
            if added == nil then added = {} end
            table.insert(added, g_fillTypeManager:getFillTypeNameByIndex(ft) or tostring(ft))
        end
    end
    -- [SPS 1.0.0.9.5] extraTypes: additional fillType set to seed (dynamic
    -- compartment unions). Same six-piece seeding as coupler-declared types.
    if extraTypes ~= nil then
        for ft in pairs(extraTypes) do
            if storage.fillTypes[ft] ~= true then
                storage.fillTypes[ft]  = true
                storage.fillLevels[ft] = storage.fillLevels[ft] or 0
                if storage.fillLevelsLastSynced ~= nil then
                    storage.fillLevelsLastSynced[ft] = storage.fillLevelsLastSynced[ft] or 0
                end
                if storage.fillLevelsLastPublished ~= nil then
                    storage.fillLevelsLastPublished[ft] = storage.fillLevelsLastPublished[ft] or 0
                end
                table.insert(storage.sortedFillTypes, ft)
                if added == nil then added = {} end
                table.insert(added, g_fillTypeManager:getFillTypeNameByIndex(ft) or tostring(ft))
            end
        end
    end
    if added ~= nil then
        table.sort(storage.sortedFillTypes)
        SlurryPipeManager.log("registerSprayerPlaceable[%s]: seeded storage fillTypes: %s",
            tostring(ownerName), table.concat(added, ", "))
    end
    -- Per-type capacities (fixed #capacity declarations AND locked dynamic
    -- compartments) are owned by _recomputeSprayerDynCapacities, called after
    -- registration and on every lock/unlock.
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.5] Dynamic compartments — helpers.
-- Each dynamic coupler is one physical tank: dynFillType (nil = unlocked) +
-- dynLevel, capacity = sc.spsCapacity. The vanilla Storage stays the display
-- and network aggregate: levels move via storage:setFillLevel (dirty flags,
-- fill planes and listeners all handled by vanilla), capacities[ft] is
-- recomputed as fixed declarations + the sum of compartments currently locked
-- to ft — when the last same-type compartment unlocks its capacity entry is
-- removed and, with the level at zero, the type vanishes from the info panel.
-- Server is authoritative (flow runs server-side); clients mirror compartment
-- state via SPSSprayerCompartmentEvent so their capacity recompute matches.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_findSprayerPlaceableEntryByCoupling(sc)
    for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
        for _, c in ipairs(pEntry.couplings) do
            if c == sc then return pEntry end
        end
    end
    return nil
end

function SlurryPipeManager:_recomputeSprayerDynCapacities(entry)
    local storage = entry.sourceEntry ~= nil and entry.sourceEntry.storage or nil
    if storage == nil then return end
    local sums = {}
    for ft, cap in pairs(entry.spsFixedCaps or {}) do
        sums[ft] = (sums[ft] or 0) + cap
    end
    for _, sc in ipairs(entry.dynCouplers or {}) do
        if sc.dynFillType ~= nil then
            sums[sc.dynFillType] = (sums[sc.dynFillType] or 0) + (sc.spsCapacity or 0)
        end
    end
    if next(sums) == nil and entry.spsManagedCapTypes == nil then return end
    storage.capacities = storage.capacities or {}
    entry.spsManagedCapTypes = entry.spsManagedCapTypes or {}
    for ft in pairs(entry.spsManagedCapTypes) do
        if sums[ft] == nil then
            storage.capacities[ft] = nil       -- vanish: capacity entry removed
            entry.spsManagedCapTypes[ft] = nil
        end
    end
    for ft, cap in pairs(sums) do
        if storage.capacities[ft] ~= cap then
            SlurryPipeManager.log("sprayer store capacity[%s] = %d (SPS)",
                tostring(g_fillTypeManager:getFillTypeNameByIndex(ft) or ft), cap)
        end
        storage.capacities[ft] = cap
        entry.spsManagedCapTypes[ft] = true
    end
end

function SlurryPipeManager:_syncSprayerCompartment(entry, sc, force)
    if g_server == nil or SPSSprayerCompartmentEvent == nil then return end
    local now = g_time or 0
    if not force and sc._dynSyncMs ~= nil and (now - sc._dynSyncMs) < 1000 then return end
    sc._dynSyncMs = now
    g_server:broadcastEvent(SPSSprayerCompartmentEvent.new(entry.object, sc.id,
        sc.dynFillType or 0, sc.dynLevel or 0), nil, nil, entry.object)
end

function SlurryPipeManager:_dynCompartmentDeposit(entry, sc, fillType, amount)
    if sc.dynFillType == nil then
        sc.dynFillType = fillType
        sc.dynLevel    = sc.dynLevel or 0
        SlurryPipeManager.log("compartment LOCK: %s coupler=%s -> %s",
            tostring(entry.object and entry.object.configFileName), tostring(sc.id),
            tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType) or fillType))
        self:_recomputeSprayerDynCapacities(entry)
        self:_syncSprayerCompartment(entry, sc, true)
    end
    sc.dynLevel = math.min((sc.dynLevel or 0) + amount, sc.spsCapacity or math.huge)
    local storage = entry.sourceEntry ~= nil and entry.sourceEntry.storage or nil
    if storage ~= nil then
        storage:setFillLevel((storage:getFillLevel(fillType) or 0) + amount, fillType)
    end
    self:_syncSprayerCompartment(entry, sc, false)
end

function SlurryPipeManager:_dynCompartmentWithdraw(entry, sc, fillType, amount)
    local removed = math.min(amount, sc.dynLevel or 0)
    sc.dynLevel = (sc.dynLevel or 0) - removed
    local storage = entry.sourceEntry ~= nil and entry.sourceEntry.storage or nil
    if storage ~= nil and removed > 0 then
        storage:setFillLevel((storage:getFillLevel(fillType) or 0) - removed, fillType)
    end
    if sc.dynLevel <= 0.001 then
        SlurryPipeManager.log("compartment UNLOCK (empty): %s coupler=%s was %s",
            tostring(entry.object and entry.object.configFileName), tostring(sc.id),
            tostring(g_fillTypeManager:getFillTypeNameByIndex(sc.dynFillType) or sc.dynFillType))
        sc.dynFillType = nil
        sc.dynLevel    = 0
        self:_recomputeSprayerDynCapacities(entry)
        self:_syncSprayerCompartment(entry, sc, true)
    else
        self:_syncSprayerCompartment(entry, sc, false)
    end
end

-- Client-side apply (event + join dump). Levels of the vanilla Storage arrive
-- via its own update stream; this mirrors only the compartment ledger so the
-- capacity recompute matches the server.
function SlurryPipeManager:applySprayerCompartmentState(placeable, couplerId, fillType, level)
    for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
        if pEntry.object == placeable then
            for _, sc in ipairs(pEntry.dynCouplers or {}) do
                if sc.id == couplerId then
                    sc.dynFillType = (fillType ~= nil and fillType > 0) and fillType or nil
                    sc.dynLevel    = level or 0
                    self:_recomputeSprayerDynCapacities(pEntry)
                    return true
                end
            end
        end
    end
    return false
end

function SlurryPipeManager:_saveSprayerCompartments(xmlFile)
    local idx = 0
    for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
        if pEntry.dynCouplers ~= nil and pEntry.object ~= nil and pEntry.object.rootNode ~= nil then
            local px, py, pz = getWorldTranslation(pEntry.object.rootNode)
            for _, sc in ipairs(pEntry.dynCouplers) do
                if sc.dynFillType ~= nil and (sc.dynLevel or 0) > 0 then
                    local base = string.format("slurryPipeSystem.sprayerCompartments.compartment(%d)", idx)
                    xmlFile:setFloat(base .. "#x", px)
                    xmlFile:setFloat(base .. "#y", py)
                    xmlFile:setFloat(base .. "#z", pz)
                    xmlFile:setInt(base .. "#couplerId", sc.id)
                    xmlFile:setString(base .. "#fillType",
                        g_fillTypeManager:getFillTypeNameByIndex(sc.dynFillType) or "UNKNOWN")
                    xmlFile:setFloat(base .. "#level", sc.dynLevel)
                    idx = idx + 1
                end
            end
        end
    end
    if idx > 0 then
        SlurryPipeManager.log("saveCouplingConnections: wrote %d sprayer compartment(s)", idx)
    end
end

function SlurryPipeManager:_loadSprayerCompartments(xmlFile)
    self._pendingSprayerCompartments = {}
    local idx = 0
    while true do
        local base = string.format("slurryPipeSystem.sprayerCompartments.compartment(%d)", idx)
        if not xmlFile:hasProperty(base) then break end
        table.insert(self._pendingSprayerCompartments, {
            x            = xmlFile:getFloat(base .. "#x", 0),
            z            = xmlFile:getFloat(base .. "#z", 0),
            couplerId    = xmlFile:getInt(base .. "#couplerId", 0),
            fillTypeName = xmlFile:getString(base .. "#fillType", ""),
            level        = xmlFile:getFloat(base .. "#level", 0),
        })
        idx = idx + 1
    end
    if idx > 0 then
        SlurryPipeManager.log("loadCouplingConnections: %d pending sprayer compartment(s)", idx)
    end
end

function SlurryPipeManager:registerSprayerPlaceable(placeable)
    SlurryPipeManager.log("registerSprayerPlaceable: enter %s", tostring(placeable and placeable.configFileName))
    for _, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.object == placeable then return end
    end

    local config = self:findSprayerPlaceableConfigForPlaceable(placeable)
    if config == nil then
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
        return
    end

    local kp = (config.xmlKeyPrefix or "") .. "sprayerPipeSystem."

    -- Resolve storage from silo spec (sprayer placeables must be spec_silo)
    local storage = nil
    if placeable.spec_silo ~= nil and placeable.spec_silo.storage ~= nil then
        storage = placeable.spec_silo.storage
    elseif placeable.spec_husbandry ~= nil and placeable.spec_husbandry.storage ~= nil then
        storage = placeable.spec_husbandry.storage
    elseif placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil and #placeable.spec_silo.storages > 0 then
        storage = placeable.spec_silo.storages[1]
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
    else
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
        end
    end

    
    -- [SPS 1.0.0.9.11] Manifest tails no longer carry the mod-folder name
    -- (players rename downloaded map folders at will), so a placeable from a
    -- DIFFERENT map with the same relative path can path-match. Verify the
    -- match by outcome: a bundled (non-embedded) config whose nodeTree linked
    -- ZERO nodes hit the wrong placeable — bail before hideNodes, couplings or
    -- state touch it. Embedded configs are self-owned and never bail here.
    if not config.isEmbedded and #linkedNodes == 0 then
        SlurryPipeManager.log("registerSprayerPlaceable: config path-matched %s but no nodeTree targets exist — wrong placeable, skipping",
            tostring(placeable.configFileName))
        if xmlFileOwned then xmlFile:delete() end
        return
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
                if root == nil or root == 0 or not entityExists(root) then return nil end
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
        -- [SPS 1.0.0.9.10] Placeable-schema parity with the slurry side:
        -- embedded slurry pipeCouplings accept node="..." resolved through the
        -- placeable's i3dMappings (core, embedded branch), and modder stores
        -- were authored that way. Sprayer placeable couplings now accept the
        -- same #node fallback, so one authoring style covers both systems.
        -- #mountNodeName (name search) stays primary; nothing existing changes.
        if mountNode == nil then
            mountNode = xmlFile:getNode(cKey .. "#node", nil, placeable.components, placeable.i3dMappings)
            if mountNode ~= nil then
                mountNodeName = getName(mountNode)
            end
        end
        if mountNode ~= nil then
            local inNode, outNode
            local function findInOut(node)
                if node == nil or node == 0 or not entityExists(node) then return end
                for i = 0, getNumOfChildren(node) - 1 do
                    local child = getChildAt(node, i)
                    local n = getName(child)
                    if n == "inNode" then inNode = child
                    elseif n == "outNode" then outNode = child
                    else findInOut(child) end
                end
            end
            findInOut(mountNode)
            -- Per-coupler fillType restriction (sprayerPipeCoupling#fillType). Optional.
            -- When set, only that fillType may pass through this coupler in either
            -- direction; enforced in tickSprayerFlow. nil => unrestricted (any type).
            local restrictFillType = nil
            local restrictFillTypeName = xmlFile:getString(cKey .. "#fillType")
            if restrictFillTypeName ~= nil then
                restrictFillType = g_fillTypeManager:getFillTypeIndexByName(restrictFillTypeName)
                if restrictFillType == nil then
                    SlurryPipeManager.log("registerSprayerPlaceable: unknown coupling #fillType '%s' (coupling id=%s) — no restriction applied",
                        tostring(restrictFillTypeName), tostring(couplingId))
                end
            end
            -- [SPS 1.0.0.9.4] Optional per-coupler capacity (sprayerPipeCoupling#capacity).
            -- Requires #fillType; same-type couplers on one store SUM into that
            -- type's capacity (each coupler = one physical tank). Applied to the
            -- Storage in _seedStorageFillTypes below.
            local spsCapacity = xmlFile:getFloat(cKey .. "#capacity")
            -- [SPS 1.0.0.9.5] Dynamic compartment coupler: #fillTypeCategories (or a
            -- #fillTypes name list) instead of a fixed #fillType. The coupler is one
            -- physical tank: it starts unlocked, LOCKS to the first fillType that
            -- flows through it and only unlocks when its own level drains to zero
            -- (the type then vanishes from the tank again). Requires #capacity.
            local dynAllowed = nil
            local dynAllowAny = false
            local dynCats  = xmlFile:getString(cKey .. "#fillTypeCategories")
            local dynNames = xmlFile:getString(cKey .. "#fillTypes")
            -- [SPS 1.0.0.9.6] fillTypes="ANY" (or fillTypeCategories="ANY"):
            -- accept whatever fillType the CONNECTED SPRAYER actually holds.
            -- Needed because script mods (e.g. SoilFertilizer) grant their
            -- liquids to vehicle fillUnits at runtime WITHOUT putting them in
            -- the base 'sprayer' category, so category resolution never sees
            -- them. ANY compartments still lock-until-empty exactly the same.
            -- Display contract [1.0.0.9.9]: ANY couplers pre-seed the base
            -- 'sprayer' CATEGORY at register (static + deterministic on every
            -- machine, so join-stream type lists stay identical), so basegame
            -- herb/fert/liquid fert always show on the tank's info panel.
            -- Script-mod types (e.g. SoilFertilizer) display when THAT mod
            -- makes the storage support them — SF does, which is why SF
            -- liquids appeared on the panel while unseeded herb did not.
            -- A mod type nobody seeds still flows and locks correctly but
            -- tracks in the SPS ledger + save + MP event only (no panel row).
            if (dynCats ~= nil and dynCats:upper() == "ANY")
            or (dynNames ~= nil and dynNames:upper() == "ANY") then
                dynAllowAny = true
                dynAllowed  = {}
                dynCats, dynNames = nil, nil
                if spsCapacity == nil or spsCapacity <= 0 then
                    SlurryPipeManager.log("registerSprayerPlaceable: coupling id=%s declares ANY without #capacity — dynamic compartment disabled",
                        tostring(couplingId))
                    dynAllowAny = false
                    dynAllowed  = nil
                end
            end
            if dynCats ~= nil or dynNames ~= nil then
                local list = nil
                if dynCats ~= nil then
                    list = g_fillTypeManager:getFillTypesByCategoryNames(dynCats,
                        "Warning: [SPS] sprayerPipeCoupling has invalid fillTypeCategory '%s'.")
                else
                    list = g_fillTypeManager:getFillTypesByNames(dynNames,
                        "Warning: [SPS] sprayerPipeCoupling has invalid fillType '%s'.")
                end
                if list ~= nil and #list > 0 then
                    if spsCapacity == nil or spsCapacity <= 0 then
                        SlurryPipeManager.log("registerSprayerPlaceable: coupling id=%s declares fillTypeCategories/fillTypes without #capacity — dynamic compartment disabled",
                            tostring(couplingId))
                    else
                        dynAllowed = {}
                        for _, ft in ipairs(list) do dynAllowed[ft] = true end
                        if restrictFillType ~= nil then
                            SlurryPipeManager.log("registerSprayerPlaceable: coupling id=%s declares BOTH #fillType and categories/list — dynamic wins, fixed restriction dropped",
                                tostring(couplingId))
                            restrictFillType = nil
                        end
                    end
                end
            end
            if spsCapacity ~= nil and restrictFillType == nil and dynAllowed == nil then
                SlurryPipeManager.log("registerSprayerPlaceable: coupling id=%s declares #capacity without a valid #fillType — capacity ignored",
                    tostring(couplingId))
                spsCapacity = nil
            end
            local sc = {
                id                       = couplingId,
                mountNode                = mountNode,
                inNode                   = inNode,
                outNode                  = outNode,
                flowDirection            = xmlFile:getString(cKey .. "#flowDirection", "BOTH"),
                restrictFillType         = restrictFillType,
                spsCapacity              = spsCapacity,
                dynAllowed               = dynAllowed,
                dynAllowAny              = dynAllowAny,
                dynFillType              = nil,
                dynLevel                 = 0,
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
                SlurryPipeManager.log("sprayer bind DIAG (sc): id=%s connIds=%s/%s bound=%s/%s",
                    tostring(sc.id), tostring(sc.connectorAnimationId), tostring(sc.valveAnimationId),
                    tostring(sc.connectorAnim ~= nil), tostring(sc.valveAnim ~= nil))
            end
            table.insert(entry.couplings, sc)
            -- Placeable-side SPSSprayerPipeActivatable intentionally NOT registered.
            -- All connect/disconnect must go through the vehicle's sprayerPumpControl
            -- node to enforce the load animation -> connect -> valve animation sequence.
        else
        end
        couplingIndex = couplingIndex + 1
    end

    -- [SPS 1.0.0.9.4] Seed the store's Storage with every coupler-declared
    -- fillType unless the config opts out (storageFillTypeControl="store").
    -- See _seedStorageFillTypes above for the full contract.
    local storageControl = xmlFile:getString(kp .. "sprayerPipeCouplings#storageFillTypeControl")
    if storageControl == nil then storageControl = "sps" end
    -- [SPS 1.0.0.9.5] Fixed declared capacities + dynamic coupler bookkeeping.
    entry.spsFixedCaps = nil
    entry.dynCouplers  = nil
    local dynUnion = nil
    for _, sc in ipairs(entry.couplings) do
        if sc.restrictFillType ~= nil and sc.spsCapacity ~= nil and sc.spsCapacity > 0 then
            entry.spsFixedCaps = entry.spsFixedCaps or {}
            entry.spsFixedCaps[sc.restrictFillType] = (entry.spsFixedCaps[sc.restrictFillType] or 0) + sc.spsCapacity
        end
        if sc.dynAllowed ~= nil then
            entry.dynCouplers = entry.dynCouplers or {}
            table.insert(entry.dynCouplers, sc)
            dynUnion = dynUnion or {}
            for ft in pairs(sc.dynAllowed) do dynUnion[ft] = true end
            -- [SPS 1.0.0.9.9] ANY couplers seed the base 'sprayer' category so
            -- basegame liquids always display (see ANY doc block above).
            if sc.dynAllowAny == true then
                local baseList = g_fillTypeManager:getFillTypesByCategoryNames("sprayer",
                    "Warning: [SPS] base category 'sprayer' missing fillType '%s'.")
                if baseList ~= nil then
                    for _, ft in ipairs(baseList) do dynUnion[ft] = true end
                end
            end
        end
    end
    for _, sc in ipairs(entry.dynCouplers or {}) do
        if sc.dynAllowAny == true then
            SlurryPipeManager.log("registerSprayerPlaceable[%s]: coupler=%s dynamic=ANY (vehicle-held type), capacity=%d",
                tostring(placeable.configFileName), tostring(sc.id), sc.spsCapacity or 0)
        else
            local names = {}
            for ft in pairs(sc.dynAllowed or {}) do
                table.insert(names, g_fillTypeManager:getFillTypeNameByIndex(ft) or tostring(ft))
            end
            table.sort(names)
            SlurryPipeManager.log("registerSprayerPlaceable[%s]: coupler=%s dynamic allowed: %s, capacity=%d",
                tostring(placeable.configFileName), tostring(sc.id), table.concat(names, ", "), sc.spsCapacity or 0)
        end
    end
    if storage ~= nil and storageControl ~= "store" then
        -- Pre-seed EVERY allowed dynamic type at register. Vanilla Storage join
        -- streams iterate sortedFillTypes on BOTH ends with no framing, so the
        -- supported-type list must be identical on every machine from load —
        -- lock/unlock therefore only ever moves LEVELS and CAPACITIES, never the
        -- type list. Zero-level types cost one bool on the stream and do not
        -- show on the info panel, so "vanish when empty" comes for free.
        self:_seedStorageFillTypes(storage, entry.couplings, placeable.configFileName, dynUnion)
    end
    -- Restore saved compartment locks (position + coupler id keyed).
    if self._pendingSprayerCompartments ~= nil and placeable.rootNode ~= nil then
        local px, _, pz = getWorldTranslation(placeable.rootNode)
        for i = #self._pendingSprayerCompartments, 1, -1 do
            local p = self._pendingSprayerCompartments[i]
            local dx, dz = p.x - px, p.z - pz
            if dx*dx + dz*dz <= 0.25 then
                for _, sc in ipairs(entry.dynCouplers or {}) do
                    if sc.id == p.couplerId then
                        local ft = g_fillTypeManager:getFillTypeIndexByName(p.fillTypeName)
                        if ft ~= nil and (sc.dynAllowAny == true or sc.dynAllowed[ft] == true) then
                            sc.dynFillType = ft
                            sc.dynLevel    = p.level
                            SlurryPipeManager.log("registerSprayerPlaceable[%s]: restored compartment coupler=%s %s %.1f l",
                                tostring(placeable.configFileName), tostring(sc.id), tostring(p.fillTypeName), p.level)
                        end
                        break
                    end
                end
                table.remove(self._pendingSprayerCompartments, i)
            end
        end
    end
    self:_recomputeSprayerDynCapacities(entry)
    -- [SPS 1.0.0.9.9] Aggregate reconcile: the vanilla Storage level for each
    -- type must be at least the sum of the SPS compartment ledgers holding it.
    -- Heals saves from builds where a type was deposited while unseeded (the
    -- ledger kept it, the panel never saw it); a no-op when already in step.
    if storage ~= nil and entry.dynCouplers ~= nil then
        local sums = {}
        for _, sc in ipairs(entry.dynCouplers) do
            if sc.dynFillType ~= nil and (sc.dynLevel or 0) > 0 then
                sums[sc.dynFillType] = (sums[sc.dynFillType] or 0) + sc.dynLevel
            end
        end
        for ft, sum in pairs(sums) do
            if storage.fillTypes ~= nil and storage.fillTypes[ft] == true then
                local cur = storage:getFillLevel(ft) or 0
                if cur < sum then
                    storage:setFillLevel(sum, ft)
                    SlurryPipeManager.log("registerSprayerPlaceable[%s]: reconciled %s aggregate %.1f -> %.1f (compartment ledger)",
                        tostring(placeable.configFileName),
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(ft) or ft), cur, sum)
                end
            end
        end
    end

    if xmlFileOwned then xmlFile:delete() end
    table.insert(self.registeredSprayerPlaceables, entry)
end

-- ---------------------------------------------------------------------------
-- Sprayer SOURCE vehicle registration (IBC liquid tanks)
--
-- An IBC is a passive source: the sprayer connects a pipe to it and pulls (or,
-- for unload, pushes) liquid. It is stored in the SAME registeredSprayerPlaceables
-- table as placeable sources — every downstream connect / _findSprayerCouplingById
-- / findOverlappingSprayerCoupler / transfer / sync / HUD consumer already reads
-- that table generically off entry.object / entry.couplings / entry.sourceEntry,
-- so no consumer needs touching. The differences from a placeable source are:
--   * source is the tank's own fill unit (type "FILL_UNIT_ONLY"), already handled
--     alongside STORAGE_PLANE / FILL_VOLUME in the transfer/surface switches;
--   * coupler nodes live in the vehicle's own i3d (the SPS geometry supplied by
--     the init.lua i3d redirect), resolved by name from vehicle.components — no
--     nodeTree injection, so linkedNodes stays empty and unregister never deletes
--     vehicle-owned nodes.
-- Unregistration reuses unregisterSprayerPlaceable (object-keyed).
-- ---------------------------------------------------------------------------
function SlurryPipeManager:registerSprayerSourceVehicle(vehicle)
    SlurryPipeManager.log("registerSprayerSourceVehicle: enter %s", tostring(vehicle and vehicle.configFileName))
    for _, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.object == vehicle then return end
    end

    local config = self:findSprayerSourceVehicleConfigForVehicle(vehicle)
    if config == nil then
        return
    end

    local xmlFile
    local xmlFileOwned = false
    if config.isEmbedded then
        xmlFile = vehicle.xmlFile
    else
        xmlFile = XMLFile.load("spsSprayerSourcePoints", config.xmlFilePath)
        xmlFileOwned = true
    end
    if xmlFile == nil then
        return
    end

    local elementName = config.isEmbedded and "sprayerPipeSystemSource" or "sprayerPipeSystem"
    local kp = (config.xmlKeyPrefix or "") .. elementName .. "."

    -- Source = the tank's own fill unit.
    local fillUnitIndex = xmlFile:getInt(kp .. "#fillUnitIndex", 1)
    local sourceEntry = {
        type          = "FILL_UNIT_ONLY",
        vehicle       = vehicle,
        fillUnitIndex = fillUnitIndex,
    }

    -- Resolve coupler nodes by name from the vehicle's own component tree.
    local function findVehicleNode(name)
        if name == nil or name == "" or vehicle.components == nil then return nil end
        local function searchTree(root, targetName)
            -- [SPS] Guard against dead/unknown entity ids. At the async
            -- onFinishedLoading callback a source vehicle's component (or a child)
            -- can be an invalid entity — calling getName/getNumOfChildren on it
            -- throws "Unknown entity id" and the following getNumOfChildren-1 does
            -- nil arithmetic, killing update(). Skip cleanly instead.
            if root == nil or root == 0 or not entityExists(root) then return nil end
            if getName(root) == targetName then return root end
            for i = 0, getNumOfChildren(root) - 1 do
                local found = searchTree(getChildAt(root, i), targetName)
                if found ~= nil then return found end
            end
            return nil
        end
        for _, comp in ipairs(vehicle.components) do
            local found = searchTree(comp.node, name)
            if found ~= nil then return found end
        end
        return nil
    end

    local entry = {
        object           = vehicle,
        isPlaceable      = false,
        isSourceVehicle  = true,
        vehicle          = vehicle,
        linkedNodes      = {},
        couplings        = {},
        pipeActivatables = {},
        sourceEntry      = sourceEntry,
    }

    local couplingIndex = 0
    while true do
        local cKey = string.format(kp .. "sprayerPipeCouplings.sprayerPipeCoupling(%d)", couplingIndex)
        if not xmlFile:hasProperty(cKey) then break end
        local couplingId    = xmlFile:getInt(cKey .. "#id", couplingIndex + 1)
        local mountNodeName = xmlFile:getString(cKey .. "#mountNodeName")
        local mountNode     = findVehicleNode(mountNodeName)
        if mountNode ~= nil then
            local inNode, outNode
            local function findInOut(node)
                -- [SPS] Same dead-entity guard as searchTree above.
                if node == nil or node == 0 or not entityExists(node) then return end
                for i = 0, getNumOfChildren(node) - 1 do
                    local child = getChildAt(node, i)
                    local n = getName(child)
                    if n == "inNode" then inNode = child
                    elseif n == "outNode" then outNode = child
                    else findInOut(child) end
                end
            end
            findInOut(mountNode)
            local restrictFillType = nil
            local restrictFillTypeName = xmlFile:getString(cKey .. "#fillType")
            if restrictFillTypeName ~= nil then
                restrictFillType = g_fillTypeManager:getFillTypeIndexByName(restrictFillTypeName)
                if restrictFillType == nil then
                    SlurryPipeManager.log("registerSprayerSourceVehicle: unknown coupling #fillType '%s' (coupling id=%s) — no restriction applied",
                        tostring(restrictFillTypeName), tostring(couplingId))
                end
            end
            local sc = {
                id                       = couplingId,
                mountNode                = mountNode,
                inNode                   = inNode,
                outNode                  = outNode,
                flowDirection            = xmlFile:getString(cKey .. "#flowDirection", "BOTH"),
                restrictFillType         = restrictFillType,
                maxPipeLength            = xmlFile:getFloat(cKey .. "#maxPipeLength", 7.5),
                connectorAnimationId     = xmlFile:getInt(cKey .. "#connectorAnimation"),
                valveAnimationId         = xmlFile:getInt(cKey .. "#valveAnimation"),
                isConnected              = false,
                valveOpen                = false,
                connectedTarget          = nil,
                connectedPartnerCoupling = nil,
                pipeId                   = nil,
                object                   = vehicle,
                placeable                = nil,
                sourceEntry              = sourceEntry,
            }
            if SPSCouplerAnimator ~= nil
            and (sc.connectorAnimationId ~= nil or sc.valveAnimationId ~= nil) then
                SPSCouplerAnimator.ensureLoaded(g_currentMission.spsModDirectory)
                if sc.connectorAnimationId ~= nil then
                    sc.connectorAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.connectorAnimationId)
                end
                if sc.valveAnimationId ~= nil then
                    sc.valveAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.valveAnimationId)
                end
                SlurryPipeManager.log("sprayer bind DIAG (sc): id=%s connIds=%s/%s bound=%s/%s",
                    tostring(sc.id), tostring(sc.connectorAnimationId), tostring(sc.valveAnimationId),
                    tostring(sc.connectorAnim ~= nil), tostring(sc.valveAnim ~= nil))
            end
            table.insert(entry.couplings, sc)
        else
        end
        couplingIndex = couplingIndex + 1
    end

    if xmlFileOwned then xmlFile:delete() end
    table.insert(self.registeredSprayerPlaceables, entry)
    -- Capture the tank's vanilla removeVehicleIfEmpty and apply the current IBC
    -- persist setting to this instance (deletion is server-side only).
    local spec = vehicle.spec_fillUnit
    if spec ~= nil then
        entry._ibcOrigRemoveIfEmpty = spec.removeVehicleIfEmpty
        if self.ibcPersistWhenEmpty == true then
            spec.removeVehicleIfEmpty = false
        end
    end
    SlurryPipeManager.log("registerSprayerSourceVehicle: registered %s with %d coupling(s)",
        tostring(vehicle.configFileName), #entry.couplings)
    -- [SPS MP] A just-registered IBC source may satisfy a connect that arrived before
    -- the async pallet finished loading — draw the pipe now.
    self:_tryResolveSprayerConnects()
end

-- ---------------------------------------------------------------------------
-- Sprayer unregistration
-- ---------------------------------------------------------------------------
function SlurryPipeManager:unregisterSprayerVehicle(vehicle)
    SlurryPipeManager.log("unregisterSprayerVehicle: %s", tostring(vehicle and vehicle.configFileName))
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
                entry.engineLoopSample = nil
            end
            -- Delete linked nodes
            -- [SPS 1.0.0.9.16] HIDE, don't delete — the sell-hover dangling-id
            -- evidence (log 11:10:03, three setShaderParameter stacks on our
            -- injected shapes) applies to every injected-node teardown: the
            -- owner's subtree is engine-reaped on delete, hiding is leak-free.
            for _, nodeId in ipairs(entry.linkedNodes) do
                if nodeId ~= nil and nodeId ~= 0 and entityExists(nodeId) then
                    setVisibility(nodeId, false)
                end
            end
            if entry.nodeTreeRoot ~= nil and entry.nodeTreeRoot ~= 0 then
                delete(entry.nodeTreeRoot)
                entry.nodeTreeRoot = nil
            end
            table.remove(self.registeredSprayerVehicles, i)
            return
        end
    end
end

function SlurryPipeManager:unregisterSprayerPlaceable(placeable)
    SlurryPipeManager.log("unregisterSprayerPlaceable: %s", tostring(placeable and placeable.configFileName))
    for i, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.object == placeable then
            -- [SPS 1.0.0.9.3] Domain detach handlers (idempotent; latched, so
            -- running here AND in unregisterPlaceable is safe).
            self:detachAllFromPlaceable(placeable)
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
            -- [SPS 1.0.0.9.16] HIDE, don't delete — the sell-hover dangling-id
            -- evidence (log 11:10:03, three setShaderParameter stacks on our
            -- injected shapes) applies to every injected-node teardown: the
            -- owner's subtree is engine-reaped on delete, hiding is leak-free.
            for _, nodeId in ipairs(entry.linkedNodes) do
                if nodeId ~= nil and nodeId ~= 0 and entityExists(nodeId) then
                    setVisibility(nodeId, false)
                end
            end
            table.remove(self.registeredSprayerPlaceables, i)
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

    -- [SPS 1.0.0.9.8] With several couplers on one store (four-tank fert
    -- station), more than one arc can overlap from a single parking spot and
    -- first-match-in-registration-order picked an arbitrary tank — field logs
    -- show EVERY connect resolving to coupler 4 regardless of where the player
    -- stood, so herb/fert kept meeting coupler 4's lock while couplers 1-3 sat
    -- empty. All overlapping candidates are now collected and the one nearest
    -- the LOCAL PLAYER wins (connecting is a walk-up action): walk to the tank
    -- you want. Fallback metric when no local player exists: nearest to the
    -- vehicle coupler apex — deterministic either way. Remote machines never
    -- run this for selection (the connect event carries resolved ids).
    local refX, refY, refZ = apexAx, apexAy, apexAz
    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        refX, refY, refZ = getWorldTranslation(g_localPlayer.rootNode)
    end
    local best, bestDist = nil, math.huge

    local function consider(cand)
        local apexB, arc1B, arc2B = self:_getCouplingArcNodes(cand)
        if apexB == nil or not entityExists(apexB) then return end
        local bx, by, bz = getWorldTranslation(apexB)
        if MathUtil.vector3Length(apexAx-bx, apexAy-by, apexAz-bz) > SPS_MAX_CONNECT_DIST then return end
        if not self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then return end
        local d = MathUtil.vector3Length(refX-bx, refY-by, refZ-bz)
        if d < bestDist then
            best, bestDist = cand, d
        end
    end

    for _, vEntry in ipairs(self.registeredSprayerVehicles) do
        for _, vc in ipairs(vEntry.couplings) do
            if vc ~= coupling and not vc.isConnected then
                consider(vc)
            end
        end
    end
    for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
        for _, sc in ipairs(pEntry.couplings) do
            if sc ~= coupling and not sc.isConnected then
                consider(sc)
            end
        end
    end

    return best
end

-- ---------------------------------------------------------------------------
-- Sprayer connect
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onSprayerCouplerConnect(object, coupling)
    SlurryPipeManager.log("onSprayerCouplerConnect: couplingId=%s", tostring(coupling and coupling.id))
    if g_server == nil then
        -- Client: send to server. Server will find the overlapping coupler itself.
        SPSSprayerConnectEvent.sendEvent(object, coupling.id, nil, 0)
        return
    end

    local otherCoupling = self:findOverlappingSprayerCoupler(coupling)
    if otherCoupling == nil then
        return
    end
    if coupling.isConnected then
        return
    end
    if otherCoupling.isConnected then
        return
    end

    local ownerA = object or coupling.placeable or coupling.object
    local ownerB = otherCoupling.placeable or otherCoupling.object

    self:applySprayerConnect(coupling, otherCoupling, ownerA, ownerB)

    -- Broadcast to clients with both IDs now known
    SPSSprayerConnectEvent.sendEvent(ownerA, coupling.id, ownerB, otherCoupling.id)
end

function SlurryPipeManager:applySprayerEngineSound(object, on)
    if object == nil or not object.isClient or g_soundManager == nil then return end
    local entry = self:getSprayerVehicleEntry(object)
    if entry ~= nil and entry.engineLoopSample ~= nil then
        if on then
            g_soundManager:playSample(entry.engineLoopSample)
        else
            g_soundManager:stopSample(entry.engineLoopSample)
        end
    end
end

function SlurryPipeManager:applySprayerConnect(couplingA, couplingB, ownerA, ownerB)
    -- [SPS MP] Idempotency: connect events can be legitimately re-delivered (the
    -- IBC-spawn re-send below targets clients that missed the first broadcast
    -- because the freshly spawned vehicle was not yet network-known to them).
    -- Machines that already applied this exact bond must not build a second pipe.
    if couplingA ~= nil and couplingB ~= nil
    and couplingA.isConnected and couplingB.isConnected
    and couplingA.connectedPartnerCoupling == couplingB
    and couplingA.pipeId ~= nil then
        SlurryPipeManager.log("applySprayerConnect: SKIP — already connected (pipeId=%s)", tostring(couplingA.pipeId))
        return
    end
    SlurryPipeManager.log("applySprayerConnect: A.id=%s B.id=%s animA=%s animB=%s",
        tostring(couplingA and couplingA.id), tostring(couplingB and couplingB.id),
        tostring(couplingA ~= nil and couplingA.connectorAnim ~= nil),
        tostring(couplingB ~= nil and couplingB.connectorAnim ~= nil))
    
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
        else
        end
    else
    end

    -- Play connector animations forward (pipe connection)
    if SPSCouplerAnimator ~= nil then
        if couplingA.connectorAnim ~= nil then
            SPSCouplerAnimator.play(couplingA.connectorAnim, 1)
        end
        if couplingB.connectorAnim ~= nil then
            SPSCouplerAnimator.play(couplingB.connectorAnim, 1)
        end
    end

    -- Valve stays closed on connect. Player explicitly starts flow via B key (onSprayerToggleValve).
    couplingA.valveOpen = false
    if couplingB ~= nil then couplingB.valveOpen = false end
    local ownerAEntry = self:getSprayerVehicleEntry(ownerA)
    if ownerAEntry ~= nil then ownerAEntry.state.valveOpen = false end
    local ownerBEntry = self:getSprayerVehicleEntry(ownerB)
    if ownerBEntry ~= nil then ownerBEntry.state.valveOpen = false end
end

-- [SPS MP] Queue a sprayer connect whose sprayer/IBC is not registered yet. Deduped
-- by the four addressing fields so a re-received connect does not stack. Drained by
-- _tryResolveSprayerConnects as sprayers/sources register.
function SlurryPipeManager:_queuePendingSprayerConnect(object, couplingId, targetObject, targetCouplingId)
    if self._pendingSprayerConnects == nil then self._pendingSprayerConnects = {} end
    for _, e in ipairs(self._pendingSprayerConnects) do
        if e.object == object and e.couplingId == couplingId
        and e.targetObject == targetObject and e.targetCouplingId == targetCouplingId then
            return
        end
    end
    table.insert(self._pendingSprayerConnects, {
        object = object, couplingId = couplingId,
        targetObject = targetObject, targetCouplingId = targetCouplingId,
    })
    SlurryPipeManager.logMP(string.format("[SPS MP] queued pending sprayer connect idA=%s idB=%s (pending=%d)",
        tostring(couplingId), tostring(targetCouplingId), #self._pendingSprayerConnects))
end

-- [SPS MP] Drain pending sprayer connects. Resolves both couplings directly and
-- applies via applySprayerConnect (not ...ById) so a still-unresolved entry cannot
-- re-queue. Called as each sprayer vehicle / IBC source registers.
function SlurryPipeManager:_tryResolveSprayerConnects()
    if self._pendingSprayerConnects == nil or #self._pendingSprayerConnects == 0 then return end
    local kept = {}
    for _, e in ipairs(self._pendingSprayerConnects) do
        local cA = self:_findSprayerCouplingById(e.object, e.couplingId, false)
        if cA == nil then cA = self:_findSprayerCouplingById(e.object, e.couplingId, true) end
        local cB = nil
        if e.targetObject ~= nil and e.targetCouplingId ~= nil and e.targetCouplingId > 0 then
            cB = self:_findSprayerCouplingById(e.targetObject, e.targetCouplingId, false)
            if cB == nil then cB = self:_findSprayerCouplingById(e.targetObject, e.targetCouplingId, true) end
        end
        if cA ~= nil and cB ~= nil then
            local ownerA = e.object or cA.placeable or cA.object
            local ownerB = e.targetObject or cB.placeable or cB.object
            self:applySprayerConnect(cA, cB, ownerA, ownerB)
            SlurryPipeManager.logMP(string.format("[SPS MP] _tryResolveSprayerConnects: RESOLVED idA=%s idB=%s",
                tostring(e.couplingId), tostring(e.targetCouplingId)))
        else
            table.insert(kept, e)   -- still waiting on the sprayer/IBC to register
        end
    end
    self._pendingSprayerConnects = kept
end

-- Network event path: called with IDs from remote clients or server broadcasts.
-- If targetCouplingId == 0 (client-to-server), finds the other coupling by arc overlap.
function SlurryPipeManager:applySprayerConnectById(object, couplingId, targetObject, targetCouplingId)
    SlurryPipeManager.log("applySprayerConnectById: idA=%s idB=%s", tostring(couplingId), tostring(targetCouplingId))
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
        -- Addressed sprayer/IBC not registered yet on this client — queue for retry
        -- instead of dropping (spawned-IBC pallet loads async, beating this event).
        if object ~= nil and couplingId ~= nil then
            self:_queuePendingSprayerConnect(object, couplingId, targetObject, targetCouplingId)
        end
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
        -- Only queue when B was addressed by an explicit id that failed to resolve
        -- (a race). A nil overlap in the arc case is a genuine no-connect — don't queue.
        if targetObject ~= nil and targetCouplingId ~= nil and targetCouplingId > 0 then
            self:_queuePendingSprayerConnect(object, couplingId, targetObject, targetCouplingId)
        end
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
    SlurryPipeManager.log("onSprayerCouplerDisconnect: couplingId=%s", tostring(coupling and coupling.id))
    -- No valve check for sprayers - valves auto-open on connect and auto-close on disconnect
    
    if g_server == nil then
        SPSSprayerDisconnectEvent.sendEvent(object, coupling.id)
        return
    end

    self:applySprayerDisconnect(object, coupling.id, coupling)
    SPSSprayerDisconnectEvent.sendEvent(object, coupling.id)
end

function SlurryPipeManager:applySprayerDisconnect(object, couplingId, couplingObj)
    SlurryPipeManager.log("applySprayerDisconnect: couplingId=%s", tostring(couplingId))
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
    end
    local ownerBEntry = self:getSprayerVehicleEntry(ownerB)
    if ownerBEntry ~= nil and ownerBEntry.state.pumpRunning then
        ownerBEntry.state.pumpRunning = false
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
        end
        if partner ~= nil and partner.valveAnim ~= nil then
            SPSCouplerAnimator.play(partner.valveAnim, -1)
        end
    end

    -- Play connector animations reverse (pipe disconnection)
    if SPSCouplerAnimator ~= nil then
        if coupling.connectorAnim ~= nil then
            SPSCouplerAnimator.play(coupling.connectorAnim, -1)
        end
        if partner ~= nil and partner.connectorAnim ~= nil then
            SPSCouplerAnimator.play(partner.connectorAnim, -1)
        end
    end

    -- NOW destroy pipe visual (after animations started)
    if coupling.pipeId ~= nil then
        local pipeData = self.activeSprayerPipes[coupling.pipeId]
        if pipeData ~= nil and g_spsSprayerPipeVisual ~= nil then
            g_spsSprayerPipeVisual:destroyPipe(pipeData.inst)
            self.activeSprayerPipes[coupling.pipeId] = nil
        else
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
        end
        if partner ~= nil and partner.loadAnimationName ~= nil and partner.loadAnimPlayed then
            local partnerVehicle = partner.object
            if partnerVehicle ~= nil and partnerVehicle.playAnimation ~= nil then
                partnerVehicle:playAnimation(partner.loadAnimationName, -1)
            end
        end
    end
    coupling.loadAnimPlayed = false
    if partner ~= nil then partner.loadAnimPlayed = false end

end

-- ---------------------------------------------------------------------------
-- Sprayer action handlers — called by SPSSprayerPumpControl
-- ---------------------------------------------------------------------------
-- Sprayers have a single B-key flow toggle: there is no separate pump control,
-- so pumpRunning is mirrored to valveOpen here. tickSprayerFlow requires both.
function SlurryPipeManager:onSprayerToggleValve(object)
    SlurryPipeManager.log("onSprayerToggleValve: enter")
    local entry = self:getSprayerVehicleEntry(object)
    if entry == nil then return end
    local state = entry.state
    local newValve = not state.valveOpen
    -- Pipe must be connected before opening
    if newValve and not self:sprayerHasConnectedPipe(object) then
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
        -- [SPS MP] CLIENT: apply locally BEFORE sending — the server's rebroadcast
        -- excludes the originating connection, so without this the guest who
        -- pressed the key never saw its own valve/pump change (state, anims,
        -- engine sound) while every other machine did. Mirrors the slurry pump
        -- toggle pattern.
        state.valveOpen   = newValve
        state.pumpRunning = newValve
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
    end
    -- Play/stop engine sound (valve open = flow = engine on for sprayers)
    if object.isClient and entry.engineLoopSample ~= nil then
        if newValve then
            g_soundManager:playSample(entry.engineLoopSample)
        else
            g_soundManager:stopSample(entry.engineLoopSample)
        end
    end
end

function SlurryPipeManager:onSprayerToggleDirection(object)
    SlurryPipeManager.log("onSprayerToggleDirection: enter")
    local entry = self:getSprayerVehicleEntry(object)
    if entry == nil then return end
    local state = entry.state
    if state.valveOpen then
        return
    end
    local newDir = (state.direction == SPS_SPRAYER_DIRECTION_FILL)
        and SPS_SPRAYER_DIRECTION_DISCHARGE
        or  SPS_SPRAYER_DIRECTION_FILL
    if g_server ~= nil then
        state.direction = newDir
        SPSSprayerDirectionEvent.sendEvent(object, newDir)
    else
        -- [SPS MP] CLIENT: apply locally BEFORE sending (rebroadcast excludes the
        -- originating connection — see onSprayerToggleValve).
        state.direction = newDir
        SPSSprayerDirectionEvent.sendEvent(object, newDir)
    end
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
    SlurryPipeManager.log("buildSprayerFlowSession: %s", tostring(vehicle and vehicle.configFileName))
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
    -- [SPS SPRAY] transition-gated tracer: only prints when the stop-reason CHANGES,
    -- so a stalled flow logs once, not every tick. Additive; no-op when trace is off.
    local function strace(reason, extra)
        if session._sprayTraceLast ~= reason then
            session._sprayTraceLast = reason
            SlurryPipeManager.sprayTrace("tickSprayerFlow[%s] %s%s",
                tostring(vehicle and vehicle.configFileName), tostring(reason),
                extra ~= nil and (" " .. tostring(extra)) or "")
        end
    end
    local entry   = self:getSprayerVehicleEntry(vehicle)
    if entry == nil then 
        strace("STOP:no-entry")
        return 
    end
    local state = entry.state
    if not state.pumpRunning then 
        strace("STOP:pump-off")
        return 
    end
    if not state.valveOpen then 
        strace("STOP:valve-closed")
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
        strace("STOP:no-connected-open-coupling")
        return 
    end

    -- Build vehicle-side sourceEntry inline
    local vehicleEntry = { type = "FILL_UNIT_ONLY", vehicle = vehicle, fillUnitIndex = session.vehicleFillUnit }
    -- Resolve the external side
    local extEntry = self:_resolveSprayerSource(activeCoupling)
    if extEntry == nil then 
        strace("STOP:no-external-source", "coupling=" .. tostring(activeCoupling.id))
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

    -- [SPS 1.0.0.9.5] Dynamic compartment coupler on the placeable side?
    local dynStoreCoupler, dynEntry = nil, nil
    do
        local pc = activeCoupling.connectedPartnerCoupling
        if pc ~= nil and pc.dynAllowed ~= nil then
            dynEntry = self:_findSprayerPlaceableEntryByCoupling(pc)
            if dynEntry ~= nil then dynStoreCoupler = pc end
        end
    end
    if dynStoreCoupler ~= nil then
        if state.direction == SPS_SPRAYER_DIRECTION_FILL then
            -- store -> vehicle: an unlocked compartment holds nothing.
            if dynStoreCoupler.dynFillType == nil or (dynStoreCoupler.dynLevel or 0) <= 0 then
                strace("STOP:compartment-empty", "coupler=" .. tostring(dynStoreCoupler.id))
                return
            end
            fillType = dynStoreCoupler.dynFillType
        else
            -- vehicle -> store: lock to the incoming type, or enforce the lock.
            local vt = nil
            if srcEntry.vehicle ~= nil then
                vt = srcEntry.vehicle:getFillUnitFillType(srcEntry.fillUnitIndex)
            end
            if vt == nil or vt == FillType.UNKNOWN then
                strace("STOP:nil-fillType")
                return
            end
            if dynStoreCoupler.dynFillType ~= nil and vt ~= dynStoreCoupler.dynFillType then
                if not dynStoreCoupler._loggedFillTypeBlock then
                    SlurryPipeManager.log("tickSprayerFlow: compartment coupler=%s is locked to %s until empty; source holds %s — flow denied",
                        tostring(dynStoreCoupler.id),
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(dynStoreCoupler.dynFillType)),
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(vt)))
                    dynStoreCoupler._loggedFillTypeBlock = true
                end
                strace("STOP:compartment-locked")
                return
            end
            if dynStoreCoupler.dynFillType == nil
            and dynStoreCoupler.dynAllowAny ~= true
            and dynStoreCoupler.dynAllowed[vt] ~= true then
                strace("STOP:type-not-allowed",
                    tostring(g_fillTypeManager:getFillTypeNameByIndex(vt)))
                return
            end
            dynStoreCoupler._loggedFillTypeBlock = nil
            fillType = vt
        end
    end

    -- Per-coupler fillType restriction (sprayerPipeCoupling#fillType) override.
    --
    -- When a coupler declares a fillType it DICTATES the type moved rather than merely
    -- rejecting a mismatch after the fact. This matters for a store holding several
    -- fillTypes at once (one tank with both LIQUIDFERTILIZER and HERBICIDE):
    -- _resolveSourceFillType returns whichever type the store enumerates first, so a
    -- FERTILIZER coupler could otherwise resolve HERBICIDE and be blocked against itself.
    -- Letting the coupler's restriction drive the type makes it draw the correct one from
    -- the multi-type store; if the store does not hold it, the source-level check below
    -- sees 0 and stops the flow (no wrong-type transfer).
    --
    -- For a vehicle source (discharge) getFillUnitFillLevel is type-agnostic, so a
    -- fert-filled tanker reports a level for ANY requested type. Confirm the unit
    -- actually holds the restricted type before allowing discharge through the coupler.
    local partnerCoupling = activeCoupling.connectedPartnerCoupling
    local restrict = activeCoupling.restrictFillType
    if restrict == nil and partnerCoupling ~= nil then
        restrict = partnerCoupling.restrictFillType
    end
    if dynStoreCoupler == nil and restrict ~= nil then
        fillType = restrict
        if srcEntry.type == "FILL_UNIT_ONLY" and srcEntry.vehicle ~= nil then
            local heldType = srcEntry.vehicle:getFillUnitFillType(srcEntry.fillUnitIndex)
            if heldType ~= restrict then
                if not activeCoupling._loggedFillTypeBlock then
                    SlurryPipeManager.log("tickSprayerFlow: coupling id=%s only permits fillType=%d; source vehicle holds fillType=%s — flow denied",
                        tostring(activeCoupling.id), restrict, tostring(heldType))
                    activeCoupling._loggedFillTypeBlock = true
                end
                return
            end
        end
        activeCoupling._loggedFillTypeBlock = nil
    end
    if fillType == nil then 
        strace("STOP:nil-fillType")
        return 
    end

    -- Destination must accept this fillType (dynamic compartments enforce their
    -- own permit + capacity above/below, and pre-seeded zero-capacity types
    -- would fail the vanilla free-capacity check before the first lock).
    if dynStoreCoupler == nil and not self:_destAcceptsFillType(dstEntry, fillType) then 
        strace("STOP:dest-rejects-fillType",
            string.format("dir=%s fillType=%s dstType=%s", tostring(state.direction), tostring(fillType), tostring(dstEntry.type)))
        return 
    end

    -- Get source level
    local sourceLevel = 0
    if srcEntry.type == "FILL_UNIT_ONLY" then
        if srcEntry.vehicle ~= nil then
            sourceLevel = srcEntry.vehicle:getFillUnitFillLevel(srcEntry.fillUnitIndex) or 0
        end
    elseif srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if dynStoreCoupler ~= nil then
            sourceLevel = dynStoreCoupler.dynLevel or 0
        elseif srcEntry.storage ~= nil then
            sourceLevel = srcEntry.storage:getFillLevel(fillType) or 0
        end
    end
    if sourceLevel <= 0 then 
        strace("STOP:source-empty", string.format("dir=%s fillType=%s", tostring(state.direction), tostring(fillType)))
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
        if dynStoreCoupler ~= nil then
            freeCapacity = (dynStoreCoupler.spsCapacity or 0) - (dynStoreCoupler.dynLevel or 0)
        elseif dstEntry.storage ~= nil then
            freeCapacity = dstEntry.storage:getFreeCapacity(fillType) or 0
        end
    end
    if freeCapacity <= 0 then 
        strace("STOP:dest-full", string.format("dir=%s fillType=%s", tostring(state.direction), tostring(fillType)))
        return 
    end

    local amount = math.min(session.baseLitersPerSecond * dt * 0.001, sourceLevel, freeCapacity)
    if amount <= 0 then 
        strace("STOP:zero-amount")
        return 
    end

    -- Flowing. Log the transition into FLOW and a periodic heartbeat with live levels.
    session._sprayTraceHbMs = session._sprayTraceHbMs or 0
    local nowMs = g_time or 0
    if session._sprayTraceLast ~= "FLOW" or (nowMs - session._sprayTraceHbMs) >= 1000 then
        session._sprayTraceHbMs = nowMs
        session._sprayTraceLast = "FLOW"
        local dstLvl = (dstEntry.type == "FILL_UNIT_ONLY" and dstEntry.vehicle ~= nil)
            and (dstEntry.vehicle:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0) or -1
        SlurryPipeManager.sprayTrace("tickSprayerFlow[%s] FLOW dir=%s fillType=%s amount=%.2f srcLvl=%.1f dstFree=%.1f dstLvl=%.1f",
            tostring(vehicle and vehicle.configFileName), tostring(state.direction), tostring(fillType),
            amount, sourceLevel, freeCapacity, dstLvl)
    end

    if dynStoreCoupler ~= nil then
        -- Compartment side handled by the ledger helpers (which also drive the
        -- vanilla Storage aggregate + MP sync); vehicle side stays on the
        -- standard helpers.
        if state.direction == SPS_SPRAYER_DIRECTION_FILL then
            self:_dynCompartmentWithdraw(dynEntry, dynStoreCoupler, fillType, amount)
            self:addToSource(dstEntry, amount, fillType, vehicle)
        else
            self:removeFromSource(srcEntry, amount, fillType, vehicle)
            self:_dynCompartmentDeposit(dynEntry, dynStoreCoupler, fillType, amount)
        end
    else
        self:removeFromSource(srcEntry, amount, fillType, vehicle)
        self:addToSource(dstEntry, amount, fillType, vehicle)
    end
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
            end
        else
            if self.activeSprayerFlows[vehicle] ~= nil then
                self.activeSprayerFlows[vehicle] = nil
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
                        self:applySprayerDisconnect(vEntry.object, c.id, c)
                        SPSSprayerDisconnectEvent.sendEvent(vEntry.object, c.id)
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.0.9.3] Placeable detach handler — sprayer pipes.
-- Broadcast leg for sprayer-placeable disconnects (mirror of the slurry fix:
-- local applySprayerDisconnect already runs in unregisterSprayerPlaceable on
-- every machine; the missing piece was the authoritative server broadcast).
-- Also purges queued pending sprayer connects referencing the placeable on
-- every machine so a late retry can't resolve against a dead object.
-- ---------------------------------------------------------------------------
SlurryPipeManager.registerPlaceableDetachHandler("Sprayers", function(mgr, placeable)
    if mgr._pendingSprayerConnects ~= nil then
        local kept = {}
        for _, e in ipairs(mgr._pendingSprayerConnects) do
            if e.object ~= placeable and e.targetObject ~= placeable then
                table.insert(kept, e)
            else
                SlurryPipeManager.logMP("[SPS MP] detach: purged pending sprayer connect (placeable removed)")
            end
        end
        mgr._pendingSprayerConnects = kept
    end
    if g_server == nil then return end
    for _, entry in ipairs(mgr.registeredSprayerPlaceables) do
        if entry.object == placeable and entry.couplings ~= nil then
            for _, sc in ipairs(entry.couplings) do
                if sc.isConnected then
                    SPSSprayerDisconnectEvent.sendEvent(placeable, sc.id)
                end
            end
        end
    end
end)
