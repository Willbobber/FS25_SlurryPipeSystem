-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.6

-- SPSM_Sprayers.lua
-- FS25_SlurryPipeSystem
--
-- SlurryPipeManager domain module: fertiliser/herbicide sprayer subsystem.
-- PURE RELOCATION from scripts/manager/SlurryPipeManager.lua (V1.0.0.8 tag):
-- every function body in this file is byte-identical to the baseline.
-- Loads AFTER the core manager file (see modDesc extraSourceFiles order).

print("[SPS BUILD] SPSM_Sprayers 1.0.1.6 loaded")


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
    -- [SPS 1.0.1.4] Mission/contract vehicles are never SPS-captured. Contract
    -- completion is computed from the server's density maps and the mission
    -- sprayer must be fillable through vanilla triggers (missions never
    -- pre-fill), so a captured lease sprayer could brick spraying contracts —
    -- reported as "herbicide contracts don't work on dedicated servers".
    -- Instance check, deliberately ABOVE the configFileName cache: a leased
    -- and an owned copy of the same sprayer share a configFileName but must
    -- answer differently. propertyState is set before onFinishedLoading and
    -- streamed to clients (Vehicle.lua:585/1238), so every capture gate that
    -- funnels through this finder sees the same answer on every peer.
    if vehicle ~= nil and VehiclePropertyState ~= nil
       and vehicle.propertyState == VehiclePropertyState.MISSION then
        return nil
    end
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
-- [SPS 1.0.1.4] Cached, mission-guarded front for
-- findSprayerSourceVehicleConfigForVehicle — the third capture path, which was
-- left behind when the slurry and active-sprayer finders were fixed.
--
-- Same two reasons as its siblings:
--   * Mission/contract vehicles are never SPS-captured. SPS blocks the vanilla
--     fill paths on a captured vehicle, so a leased contract front tank / IBC
--     that cannot be filled through a normal trigger can brick the contract —
--     the "herbicide contracts don't work on dedicated servers" report. The
--     instance check sits deliberately ABOVE the configFileName cache: a leased
--     and an owned copy of the same tank share a configFileName but must answer
--     differently. Store tagging passes a bare shim table with no propertyState,
--     so it is unaffected.
--   * The finder is a pure function of vehicle.configFileName, yet it loaded and
--     parsed the vehicle's XML from disk via XMLFile.loadIfExists on every call.
--     `false` marks a cached negative. Never invalidated: the config set is
--     static after load.
-- Purely additive — the original above is untouched and still does the real work
-- on first sight of each configFileName.
-- ---------------------------------------------------------------------------
SlurryPipeManager._findSprayerSourceVehicleConfigUncached = SlurryPipeManager.findSprayerSourceVehicleConfigForVehicle
function SlurryPipeManager:findSprayerSourceVehicleConfigForVehicle(vehicle)
    if vehicle ~= nil and VehiclePropertyState ~= nil
       and vehicle.propertyState == VehiclePropertyState.MISSION then
        return nil
    end
    if vehicle == nil or vehicle.configFileName == nil then
        return SlurryPipeManager._findSprayerSourceVehicleConfigUncached(self, vehicle)
    end
    local cache = self._sprayerSourceVehicleCfgCache
    if cache == nil then
        cache = {}
        self._sprayerSourceVehicleCfgCache = cache
    end
    local hit = cache[vehicle.configFileName]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    local config = SlurryPipeManager._findSprayerSourceVehicleConfigUncached(self, vehicle)
    if config == nil then
        cache[vehicle.configFileName] = false
    else
        cache[vehicle.configFileName] = config
    end
    return config
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

    -- [SPS 1.0.0.9.24] Per-config coupler animation definitions (optional
    -- <couplerAnimations> block inside this config's xml, same format as
    -- configs/couplerAnimations.xml). Passed into bind() so sprayer configs
    -- can carry their own animations; local ids shadow global ids for this
    -- config's couplings only.
    local localAnimLibrary = nil
    if SPSCouplerAnimator ~= nil and SPSCouplerAnimator.parseLocal ~= nil then
        localAnimLibrary = SPSCouplerAnimator.parseLocal(xmlFile, kp)
    end

    local entry = {
        object           = vehicle,
        isVehicle        = true,
        linkedNodes      = {},
        couplings        = {},
        pumpControls     = {},
        pipeActivatables = {},
        litersPerSecond  = xmlFile:getFloat(kp .. "flow#litersPerSecond", 200),
        -- [SPS 1.0.1.4] Optional FlowControl balance overrides. All defaults mirror
        -- the real Amazone FT-P (rear held at 30%, top-up to 40%, 200 l/min pump).
        -- Absent block => defaults, so unconfigured combos work out of the box.
        ftBalance        = {
            lowPct          = xmlFile:getFloat(kp .. "frontTankBalance#lowPct", 30),
            highPct         = xmlFile:getFloat(kp .. "frontTankBalance#highPct", 40),
            litersPerMinute = xmlFile:getFloat(kp .. "frontTankBalance#transferLitersPerMinute", 200),
        },
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
                    couplingEntry.connectorAnim = SPSCouplerAnimator.bind(couplingEntry.mountNode, couplingEntry.connectorAnimationId, localAnimLibrary)
                end
                if couplingEntry.valveAnimationId ~= nil then
                    couplingEntry.valveAnim = SPSCouplerAnimator.bind(couplingEntry.mountNode, couplingEntry.valveAnimationId, localAnimLibrary)
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

-- [SPS 1.0.0.9.25] Orphan liquid adoption.
-- Liquid can enter the vanilla Storage without SPS seeing it: dev/console
-- fills and the store's own buy/fill trigger both write straight to
-- storage.fillLevels, leaving every dynamic compartment ledger at nil/0 —
-- so FILL out stops with compartment-empty despite a visibly full tank.
-- This sweep computes, per fillType, the ORPHAN level = aggregate storage
-- level minus the sum of locked compartment ledgers (types owned by fixed
-- #capacity declarations are skipped — their level legitimately lives in
-- the aggregate). Any orphan is adopted into unlocked dynamic couplers in
-- ascending id order, each capped at its #capacity, using the normal
-- lock-until-empty rules (dynAllowed respected). Storage levels are NOT
-- touched — the liquid is already there; only the ledger is credited.
-- Server-authoritative; clients receive the result via the existing
-- SPSSprayerCompartmentEvent sync. Silent no-op when nothing is orphaned.
-- Called at registration (after restore/reconcile) and from the
-- compartment-empty branch of tickSprayerFlow so mid-session external
-- fills are picked up without a reload.
function SlurryPipeManager:_adoptOrphanSprayerLiquid(entry)
    if g_server == nil then return false end
    if entry == nil or entry.dynCouplers == nil or #entry.dynCouplers == 0 then return false end
    local storage = entry.sourceEntry ~= nil and entry.sourceEntry.storage or nil
    if storage == nil or storage.fillLevels == nil then return false end
    -- Sum of locked compartment ledgers per type.
    local ledger = {}
    for _, sc in ipairs(entry.dynCouplers) do
        if sc.dynFillType ~= nil then
            ledger[sc.dynFillType] = (ledger[sc.dynFillType] or 0) + (sc.dynLevel or 0)
        end
    end
    -- Orphan per type, skipping fixed-declaration types (aggregate-owned).
    local orphanTypes = {}
    local orphanLevels = {}
    for ft, lvl in pairs(storage.fillLevels) do
        if (entry.spsFixedCaps == nil or entry.spsFixedCaps[ft] == nil) then
            local orphan = (lvl or 0) - (ledger[ft] or 0)
            if orphan > 0.001 then
                table.insert(orphanTypes, ft)
                orphanLevels[ft] = orphan
            end
        end
    end
    if #orphanTypes == 0 then return false end
    table.sort(orphanTypes)
    local adopted = false
    -- [SPS 1.0.0.9.29] Top-up pass: external fills into a tank ALREADY
    -- locked to that type raise the aggregate but not the ledger, so the
    -- liquid could not be withdrawn. Credit same-type orphan into locked
    -- couplers (up to each coupler's own capacity) before assigning any
    -- free couplers.
    for _, sc in ipairs(entry.dynCouplers) do
        if sc.dynFillType ~= nil then
            local lockedFt = sc.dynFillType
            local orphan = orphanLevels[lockedFt]
            if orphan ~= nil and orphan > 0.001 then
                local room = (sc.spsCapacity or 0) - (sc.dynLevel or 0)
                if room > 0.001 then
                    local take = math.min(room, orphan)
                    sc.dynLevel = (sc.dynLevel or 0) + take
                    orphanLevels[lockedFt] = orphan - take
                    adopted = true
                    SlurryPipeManager.log("compartment TOP-UP: %s coupler=%s %s +%.1f l (external fill)",
                        tostring(entry.object and entry.object.configFileName), tostring(sc.id),
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(lockedFt) or lockedFt), take)
                    self:_syncSprayerCompartment(entry, sc, true)
                end
            end
        end
    end
    -- Unlocked couplers in ascending id order (local sorted copy).
    local free = {}
    for _, sc in ipairs(entry.dynCouplers) do
        if sc.dynFillType == nil then table.insert(free, sc) end
    end
    if #free == 0 then
        if adopted then self:_recomputeSprayerDynCapacities(entry) end
        return adopted
    end
    table.sort(free, function(a, b) return (a.id or 0) < (b.id or 0) end)
    -- [SPS 1.0.0.10.3] Walk restarts at the head of the free list for EVERY orphan
    -- type, and a coupler is only consumed when it actually accepts the type.
    -- Previously a single cursor was declared outside this loop and advanced on every
    -- pass including refusals, so a free tank that rejected type A was never offered
    -- type B and was silently burned. That diverged from _dynStoreComputeOccupancy —
    -- which resets its cursor per type and only removes couplers it assigns — so the
    -- gate could believe liquid was housed while this sweep left it unadopted and
    -- therefore unpumpable. Only visible with per-coupler dynAllowed restrictions;
    -- a dynAllowAny store behaved identically either way. The two are now the same
    -- algorithm, which is the invariant the gate's accounting depends on.
    for _, ft in ipairs(orphanTypes) do
        local remaining = orphanLevels[ft]
        local i = 1
        while remaining > 0.001 and i <= #free do
            local sc = free[i]
            if sc.dynAllowAny == true or (sc.dynAllowed ~= nil and sc.dynAllowed[ft] == true) then
                local take = math.min(remaining, sc.spsCapacity or remaining)
                sc.dynFillType = ft
                sc.dynLevel    = take
                remaining      = remaining - take
                adopted        = true
                SlurryPipeManager.log("compartment ADOPT: %s coupler=%s -> %s %.1f l (external fill)",
                    tostring(entry.object and entry.object.configFileName), tostring(sc.id),
                    tostring(g_fillTypeManager:getFillTypeNameByIndex(ft) or ft), take)
                self:_syncSprayerCompartment(entry, sc, true)
                table.remove(free, i)
            else
                i = i + 1
            end
        end
        if remaining > 0.001 then
            SlurryPipeManager.log("compartment ADOPT: %s — %.1f l of %s left unadopted (no free compartment)",
                tostring(entry.object and entry.object.configFileName), remaining,
                tostring(g_fillTypeManager:getFillTypeNameByIndex(ft) or ft))
        end
    end
    if adopted then
        self:_recomputeSprayerDynCapacities(entry)
    end
    return adopted
end

-- [SPS 1.0.0.9.27] Per-tank occupancy gate for dynamic stores.
-- A dynamic store is N physical tanks (dynCouplers), one fillType per tank,
-- lock-until-empty, and EACH tank has its own total: the #capacity
-- attribute on its <sprayerPipeCoupling> in fillPoints.xml. Modders may
-- declare unequal tanks (e.g. three at 40000, one at 20000) and the gate
-- honours each declared value exactly. Vanilla Storage has no such notion:
-- with no per-type capacity entry getFreeCapacity falls into its
-- shared-pool branch (capacity − Σ levels) and setFillLevel clamps only
-- against the global capacity — so the store's own buy/fill trigger and
-- dev controls could push a 5th distinct type into a 4-tank store, or
-- overfill one type past its tank.
-- Occupancy is computed by SIMULATING the exact assignment the adoption
-- sweep performs: locked compartments own their couplers; each unadopted
-- orphan type (aggregate level above its ledger sum) is then greedily
-- assigned free couplers in ascending id order (fillType index order
-- between types, dynAllowed respected), each capped at that coupler's own
-- capacity. The simulation and the sweep therefore always agree, before
-- and after adoption runs.
-- Per type: maxLevel = Σ capacities of tanks holding it (locked+assigned)
-- + Σ capacities of remaining free tanks that allow it (growth claims
-- whole tanks; adoption locks them as the liquid actually arrives).
-- A NEW type is admitted only while a remaining free tank allows it.
-- Fixed #capacity types are untouched (aggregate-owned, vanilla rules).
-- [SPS 1.0.0.10.3] Returns: assignedCaps (per-type total capacity of the tanks
-- holding or claiming that type), freeCouplers (tanks still unassigned after the
-- simulation, ascending id). The "isFixed, isActive, allowedNew, maxLevel" tuple
-- described above is what _dynStoreTypeGate below returns, not this function.
function SlurryPipeManager:_dynStoreComputeOccupancy(entry, storage)
    local lockedCapsByType, assignedCaps = {}, {}
    local freeCouplers = {}
    for _, sc in ipairs(entry.dynCouplers) do
        if sc.dynFillType ~= nil then
            lockedCapsByType[sc.dynFillType] = (lockedCapsByType[sc.dynFillType] or 0) + (sc.spsCapacity or 0)
            assignedCaps[sc.dynFillType]     = (assignedCaps[sc.dynFillType] or 0) + (sc.spsCapacity or 0)
        else
            table.insert(freeCouplers, sc)
        end
    end
    table.sort(freeCouplers, function(a, b) return (a.id or 0) < (b.id or 0) end)
    -- Unhoused orphans, assigned exactly as _adoptOrphanSprayerLiquid would.
    -- [SPS 1.0.0.9.30] Net against the CAPACITY of couplers already locked
    -- to the type, not the ledger: right after a fill-session CLAIM the
    -- coupler is locked with ledger 0 while the liquid sits in the
    -- aggregate (top-up credits it later, at registration/tick). Using the
    -- ledger made that liquid look homeless and virtually consumed a free
    -- coupler, burning one tank per claimed type — a 4-tank store refused
    -- the 4th product. Liquid within a same-type locked tank's capacity is
    -- housed; only the excess needs a free coupler.
    local orphanTypes, orphanLevels = {}, {}
    if storage ~= nil and storage.fillLevels ~= nil then
        for ft, lvl in pairs(storage.fillLevels) do
            if (entry.spsFixedCaps == nil or entry.spsFixedCaps[ft] == nil) then
                local orphan = (lvl or 0) - (lockedCapsByType[ft] or 0)
                if orphan > 0.001 then
                    table.insert(orphanTypes, ft)
                    orphanLevels[ft] = orphan
                end
            end
        end
    end
    table.sort(orphanTypes)
    for _, ft in ipairs(orphanTypes) do
        local remaining = orphanLevels[ft]
        local i = 1
        while remaining > 0.001 and i <= #freeCouplers do
            local sc = freeCouplers[i]
            if sc.dynAllowAny == true or (sc.dynAllowed ~= nil and sc.dynAllowed[ft] == true) then
                local cap = sc.spsCapacity or remaining
                assignedCaps[ft] = (assignedCaps[ft] or 0) + cap
                remaining = remaining - math.min(remaining, cap)
                table.remove(freeCouplers, i)
            else
                i = i + 1
            end
        end
        -- Present but no tank could take it: still active, zero grant.
        if assignedCaps[ft] == nil then assignedCaps[ft] = 0 end
    end
    return assignedCaps, freeCouplers
end

function SlurryPipeManager:_dynStoreTypeGate(entry, storage, ft)
    if entry == nil or entry.dynCouplers == nil or #entry.dynCouplers == 0 then
        return false, false, true, math.huge
    end
    if entry.spsFixedCaps ~= nil and entry.spsFixedCaps[ft] ~= nil then
        return true, false, true, math.huge
    end
    local assignedCaps, freeCouplers = self:_dynStoreComputeOccupancy(entry, storage)
    -- [SPS 1.0.0.9.29] No automatic growth: an active type is capped at
    -- the tanks it already holds. The NEXT free tank allowing ft (ascending
    -- id) is reported separately so the fill-session logic can claim
    -- exactly one tank per fill activation (press R again = one more tank).
    local nextCoupler = nil
    for _, sc in ipairs(freeCouplers) do
        if sc.dynAllowAny == true or (sc.dynAllowed ~= nil and sc.dynAllowed[ft] == true) then
            nextCoupler = sc
            break
        end
    end
    if assignedCaps[ft] ~= nil then
        return false, true, true, assignedCaps[ft], nextCoupler
    end
    if nextCoupler ~= nil then
        -- New type: admitted, first session limited to that one tank.
        return false, false, true, 0, nextCoupler
    end
    return false, false, false, 0
end

-- [SPS 1.0.0.9.26] Per-instance Storage wrappers for dynamic stores.
-- Installed on the store's own Storage object only (no class override, no
-- other storages affected). All external entry paths confirmed from vanilla
-- source: PlaceableSilo fills via storage:getFreeCapacity + setFillLevel;
-- StorageSystem aggregates via getFreeCapacity; dev fills land in
-- setFillLevel. Withdrawals (level decreases) always pass. SPS's own
-- compartment deposit locks the compartment BEFORE setFillLevel, so the
-- type is active by the time the wrapper sees it — pipe flow unaffected.
function SlurryPipeManager:_installDynStoreGate(entry)
    local storage = entry ~= nil and entry.sourceEntry ~= nil and entry.sourceEntry.storage or nil
    if storage == nil then return end
    if entry.dynCouplers == nil or #entry.dynCouplers == 0 then return end
    if storage._spsDynGateInstalled == true then return end
    storage._spsDynGateInstalled = true
    -- [SPS 1.0.0.9.28] Global capacity override: the placeable's own XML
    -- declares one total for the whole Storage (e.g. 40000) and vanilla
    -- enforces it in setFillLevel's clamp and getFreeCapacity's
    -- shared-pool branch — capping the ENTIRE store at one tank's worth.
    -- For a dynamic store the authoritative totals are the fillPoints
    -- coupler capacities: override storage.capacity with their sum (plus
    -- any fixed #capacity declarations) so the store XML amount is
    -- ignored and per-tank limits from the gate are what actually bind.
    -- Runs identically on server and clients at registration, so the
    -- network aggregate stays consistent.
    do
        local total = 0
        for _, sc in ipairs(entry.dynCouplers) do
            total = total + (sc.spsCapacity or 0)
        end
        for _, cap in pairs(entry.spsFixedCaps or {}) do
            total = total + cap
        end
        if total > 0 and storage.capacity ~= total then
            SlurryPipeManager.log("dyn store capacity override: %s %s -> %d (sum of fillPoints coupler capacities)",
                tostring(entry.object and entry.object.configFileName),
                tostring(storage.capacity), total)
            storage.capacity = total
        end
    end
    local manager = self
    local origSupported = storage.getIsFillTypeSupported
    local origFreeCap   = storage.getFreeCapacity
    local origSetLevel  = storage.setFillLevel
    -- [SPS 1.0.0.10.3] Park everything the uninstall needs on the storage itself.
    -- The three wrappers below are closures over `entry`, so leaving them in place
    -- after the placeable is unregistered pins the dead entry (and through it the
    -- deleted placeable) for as long as the Storage lives, and any late vanilla
    -- call would be gated against a store that no longer exists. storage.capacity
    -- is overridden below, so its original is saved here too.
    storage._spsDynGateRestore = {
        getIsFillTypeSupported = origSupported,
        getFreeCapacity        = origFreeCap,
        setFillLevel           = origSetLevel,
        capacity               = storage.capacity,
    }
    -- [SPS 1.0.0.9.29] Fill sessions: one tank per fill activation.
    -- The trigger gives Storage no activation signal, so a session is
    -- detected by a gap in the fill stream: no accepted increase for
    -- SPS_DYN_FILL_SESSION_GAP_MS = release + press R again = new session.
    -- While a stream is hot, an active type is clamped at the tanks it
    -- already holds; once cold, getFreeCapacity advertises exactly the
    -- NEXT allowing free tank (so re-activation is possible) and the first
    -- accepted increase claims (locks) that one coupler for the type.
    local SPS_DYN_FILL_SESSION_GAP_MS = 1500
    storage._spsFillSession = storage._spsFillSession or {}
    local function sessionIsCold(stg, ft)
        local last = stg._spsFillSession[ft]
        return last == nil or ((g_time or 0) - last) > SPS_DYN_FILL_SESSION_GAP_MS
    end
    local function claimNextTank(stg, ft, nextCoupler)
        if g_server == nil or nextCoupler == nil then return false end
        nextCoupler.dynFillType = ft
        nextCoupler.dynLevel    = nextCoupler.dynLevel or 0
        SlurryPipeManager.log("compartment CLAIM (new fill): %s coupler=%s -> %s (%d l tank)",
            tostring(entry.object and entry.object.configFileName), tostring(nextCoupler.id),
            tostring(g_fillTypeManager:getFillTypeNameByIndex(ft) or ft),
            nextCoupler.spsCapacity or 0)
        manager:_recomputeSprayerDynCapacities(entry)
        manager:_syncSprayerCompartment(entry, nextCoupler, true)
        return true
    end
    storage.getIsFillTypeSupported = function(stg, ft)
        if origSupported(stg, ft) ~= true then return false end
        local isFixed, isActive, allowedNew = manager:_dynStoreTypeGate(entry, stg, ft)
        if isFixed or isActive then return true end
        return allowedNew
    end
    storage.getFreeCapacity = function(stg, ft)
        local isFixed, isActive, allowedNew, maxLevel, nextCoupler = manager:_dynStoreTypeGate(entry, stg, ft)
        if isFixed then return origFreeCap(stg, ft) end
        if not isActive and not allowedNew then return 0 end
        -- [SPS 1.0.0.9.31] The gate's room is authoritative here. Do NOT
        -- min() against vanilla's per-type free capacity: the capacity
        -- recompute writes storage.capacities[ft] = sum of tanks CURRENTLY
        -- locked to ft (correct for the info panel), so once those tanks
        -- are full vanilla reports 0 free — which crushed the cold
        -- next-tank advertisement to zero and made a same-type refill into
        -- a further free tank impossible ("tank 1 is full of DAP"). The
        -- global total is already overridden to the sum of all coupler
        -- capacities, so the gate's whole-tank accounting is the only
        -- binding constraint.
        local lvl = stg:getFillLevel(ft) or 0
        local room = maxLevel - lvl
        if room > 0.001 then
            return room
        end
        -- Assigned tanks full: advertise the next tank only when the
        -- stream is cold, so pressing R again can start a new session.
        if nextCoupler ~= nil and sessionIsCold(stg, ft) then
            return math.max(nextCoupler.spsCapacity or 0, 0)
        end
        return 0
    end
    storage.setFillLevel = function(stg, fillLevel, ft, fillInfo)
        -- Clients receive server-authoritative levels through
        -- readUpdateStream -> setFillLevel; never gate those.
        if g_server == nil then
            return origSetLevel(stg, fillLevel, ft, fillInfo)
        end
        local cur = stg.fillLevels ~= nil and (stg.fillLevels[ft] or 0) or 0
        if fillLevel > cur then
            local isFixed, isActive, allowedNew, maxLevel, nextCoupler = manager:_dynStoreTypeGate(entry, stg, ft)
            if not isFixed then
                if not isActive and not allowedNew then
                    if stg._spsGateLogged ~= ft then
                        stg._spsGateLogged = ft
                        SlurryPipeManager.log("dyn store gate: %s refused %s — no free tank",
                            tostring(entry.object and entry.object.configFileName),
                            tostring(g_fillTypeManager:getFillTypeNameByIndex(ft) or ft))
                    end
                    return
                end
                if fillLevel > maxLevel + 0.001 then
                    -- Beyond assigned tanks: allowed only as a NEW session,
                    -- claiming exactly one more tank.
                    if nextCoupler ~= nil and sessionIsCold(stg, ft) then
                        if claimNextTank(stg, ft, nextCoupler) then
                            maxLevel = maxLevel + (nextCoupler.spsCapacity or 0)
                        end
                    end
                    if fillLevel > maxLevel then fillLevel = maxLevel end
                end
                if fillLevel > cur then
                    stg._spsFillSession[ft] = g_time or 0
                end
            end
        end
        return origSetLevel(stg, fillLevel, ft, fillInfo)
    end
    SlurryPipeManager.log("dyn store gate: installed on %s (%d tank(s))",
        tostring(entry.object and entry.object.configFileName), #entry.dynCouplers)
end

-- [SPS 1.0.0.10.3] Balance for _installDynStoreGate. Restores the three wrapped
-- Storage functions and the original global capacity, then clears the install
-- latch so a later re-registration of the same Storage installs cleanly. Safe to
-- call on an entry that never had a gate (no latch = no-op), and safe to call
-- twice. Called from unregisterSprayerPlaceable.
function SlurryPipeManager:_uninstallDynStoreGate(entry)
    local storage = entry ~= nil and entry.sourceEntry ~= nil and entry.sourceEntry.storage or nil
    if storage == nil then return end
    local saved = storage._spsDynGateRestore
    if saved == nil then return end
    storage.getIsFillTypeSupported = saved.getIsFillTypeSupported
    storage.getFreeCapacity        = saved.getFreeCapacity
    storage.setFillLevel           = saved.setFillLevel
    if saved.capacity ~= nil then
        storage.capacity = saved.capacity
    end
    storage._spsDynGateRestore  = nil
    storage._spsDynGateInstalled = nil
    storage._spsFillSession      = nil
    storage._spsGateLogged       = nil
    SlurryPipeManager.log("dyn store gate: uninstalled from %s",
        tostring(entry.object and entry.object.configFileName))
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

    -- [SPS 1.0.0.9.24] Per-config coupler animation definitions — see
    -- registerSprayerVehicle.
    local localAnimLibrary = nil
    if SPSCouplerAnimator ~= nil and SPSCouplerAnimator.parseLocal ~= nil then
        localAnimLibrary = SPSCouplerAnimator.parseLocal(xmlFile, kp)
    end

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
    -- [SPS 1.0.1.2] Sprayer buying-station placeable (vanilla placeable type
    -- "buyingStation" — same PlaceableBuyingStation/BuyingStation.lua vanilla
    -- pair already verified for the slurry side): an infinite PAID source for
    -- sprayers, mirroring the slurry SPS_SOURCE_TYPE_BUYING_STATION path. No
    -- Storage object exists; the vanilla station performs the whole purchase
    -- inside addFillLevelToFillableObject for its own declared types, and
    -- SPS-extra types purchase through transferSprayerFillFromBuyingStation.
    -- Sold set is EXPLICIT-ONLY — nothing is auto-added:
    --   buyingStation#fillTypes           ordered switch cycle, vanilla-declared
    --                                     types (vanilla pricing)
    --   buyingStation#fillType            legacy single type (one-entry cycle)
    --   buyingStation#default             starting selection
    --   <extraFillType name= priceScale=> single SPS-extra sold type (SPS-side
    --                                     purchase; priceScale 0 = free)
    --   <extraFillTypeCategory name= priceScale=>
    --                                     [SPS 1.0.1.2] whole fillType CATEGORY
    --                                     appended to the cycle — the script-mod
    --                                     hook (e.g. Soil & Fertilizer liquids):
    --                                     unknown categories/types resolve to
    --                                     nothing and are skipped with a log
    --                                     line, so one config loads clean with
    --                                     or without the liquid mod installed.
    --                                     Types the vanilla station already
    --                                     declares keep vanilla pricing; an
    --                                     explicit <extraFillType> scale wins
    --                                     over its category's scale.
    -- [SPS 1.0.1.3] Slurry and sprayer buying stations are mutually exclusive
    -- on one placeable — two gates: the config must not also declare a slurry
    -- buyingStation block, and the placeable must not already be registered as
    -- a slurry buy station (registerPlaceable runs first in loadMap AND
    -- finalizePlacement, so the slurry side always wins a conflict).
    local bsBlockedBySlurry = false
    if sourceEntry == nil and xmlFile:hasProperty(kp .. "buyingStation") then
        if xmlFile:hasProperty((config.xmlKeyPrefix or "") .. "slurryPipeSystem.buyingStation") then
            bsBlockedBySlurry = true
        end
        if not bsBlockedBySlurry and self.getBuyStationEntry ~= nil then
            local slurryEntry = self:getBuyStationEntry(placeable)
            if slurryEntry ~= nil then bsBlockedBySlurry = true end
        end
        if bsBlockedBySlurry then
            print("Warning: [SPS] " .. tostring(placeable.configFileName)
                .. ": slurry and sprayer buying stations cannot share one placeable — <sprayerPipeSystem><buyingStation> ignored")
        end
    end
    if sourceEntry == nil and not bsBlockedBySlurry
    and placeable.spec_buyingStation ~= nil
    and placeable.spec_buyingStation.buyingStation ~= nil
    and xmlFile:hasProperty(kp .. "buyingStation") then
        local station = placeable.spec_buyingStation.buyingStation
        local bsFillTypes = {}
        local bsSeen      = {}
        local function bsAppend(ftIdx)
            if ftIdx == nil or bsSeen[ftIdx] == true then return end
            -- [SPS 1.0.1.3] Sprayers cannot accept water — WATER is refused
            -- from the sprayer buy-station cycle no matter where it is
            -- declared (#fillTypes / #fillType / extras / categories).
            if ftIdx == FillType.WATER then
                if not bsSeen._waterWarned then
                    bsSeen._waterWarned = true
                    print("Warning: [SPS] " .. tostring(placeable.configFileName)
                        .. ": WATER is not sellable on a sprayer buying station — excluded")
                end
                return
            end
            bsSeen[ftIdx] = true
            table.insert(bsFillTypes, ftIdx)
        end
        local bsTypesStr = xmlFile:getString(kp .. "buyingStation#fillTypes", nil)
        if bsTypesStr ~= nil then
            for ftName in bsTypesStr:gmatch("%S+") do
                local ftIdx = g_fillTypeManager:getFillTypeIndexByName(ftName)
                if ftIdx ~= nil then
                    bsAppend(ftIdx)
                else
                    SlurryPipeManager.log("registerSprayerPlaceable: buyingStation#fillTypes unknown fillType '%s' ignored",
                        tostring(ftName))
                end
            end
        end
        if #bsFillTypes == 0 then
            local bsFillTypeName = xmlFile:getString(kp .. "buyingStation#fillType", "LIQUIDFERTILIZER")
            bsAppend(g_fillTypeManager:getFillTypeIndexByName(bsFillTypeName) or FillType.LIQUIDFERTILIZER)
        end
        -- SPS-extra sold types: fillType -> priceScale for types the vanilla
        -- station does NOT declare (its getEffectiveFillTypePrice would index a
        -- nil priceScale — verified source, slurry side). Explicit singles first.
        local bsExtraScales = {}
        local extraIdx = 0
        while true do
            local eKey = string.format(kp .. "buyingStation.extraFillType(%d)", extraIdx)
            if not xmlFile:hasProperty(eKey) then break end
            local eName = xmlFile:getString(eKey .. "#name", nil)
            local eIdx  = eName ~= nil and g_fillTypeManager:getFillTypeIndexByName(eName) or nil
            if eIdx ~= nil then
                bsAppend(eIdx)
                -- [SPS 1.0.1.3] WATER never enters the sold set (see bsAppend).
                if eIdx ~= FillType.WATER then
                    bsExtraScales[eIdx] = xmlFile:getFloat(eKey .. "#priceScale", 1.0)
                end
            else
                SlurryPipeManager.log("registerSprayerPlaceable: buyingStation.extraFillType unknown fillType '%s' ignored",
                    tostring(eName))
            end
            extraIdx = extraIdx + 1
        end
        -- [SPS 1.0.1.2] Category extras. Register-time resolution keeps the
        -- cycle static + deterministic on every machine (MP prompt parity).
        local catIdx = 0
        while true do
            local cKey2 = string.format(kp .. "buyingStation.extraFillTypeCategory(%d)", catIdx)
            if not xmlFile:hasProperty(cKey2) then break end
            local cName  = xmlFile:getString(cKey2 .. "#name", nil)
            local cScale = xmlFile:getFloat(cKey2 .. "#priceScale", 1.0)
            if cName ~= nil then
                local list = g_fillTypeManager:getFillTypesByCategoryNames(cName,
                    "Warning: [SPS] buyingStation.extraFillTypeCategory has invalid category '%s'.")
                if list ~= nil and #list > 0 then
                    for _, ftIdx in ipairs(list) do
                        bsAppend(ftIdx)
                        -- Vanilla-declared types keep vanilla pricing (no extra
                        -- entry); an explicit extraFillType scale wins.
                        -- [SPS 1.0.1.3] WATER never enters the sold set.
                        if ftIdx ~= FillType.WATER
                        and bsExtraScales[ftIdx] == nil
                        and not (station.getIsFillTypeSupported ~= nil and station:getIsFillTypeSupported(ftIdx)) then
                            bsExtraScales[ftIdx] = cScale
                        end
                    end
                else
                    SlurryPipeManager.log("registerSprayerPlaceable: buyingStation.extraFillTypeCategory '%s' resolved no fillTypes — skipped (liquid mod not installed?)",
                        tostring(cName))
                end
            end
            catIdx = catIdx + 1
        end
        local bsSelected = bsFillTypes[1]
        local bsDefaultStr = xmlFile:getString(kp .. "buyingStation#default", nil)
        if bsDefaultStr ~= nil then
            local bsDefault = g_fillTypeManager:getFillTypeIndexByName(bsDefaultStr)
            if bsDefault ~= nil then
                for _, ftIdx in ipairs(bsFillTypes) do
                    if ftIdx == bsDefault then bsSelected = bsDefault break end
                end
            end
        end
        sourceEntry = {
            type       = SPS_SOURCE_TYPE_BUYING_STATION,
            placeable  = placeable,
            station    = station,
            fillType   = bsSelected,
            fillTypes  = bsFillTypes,
            extraPriceScales = bsExtraScales,
            debugLabel = tostring(placeable.configFileName):match("([^/]+)%.xml$") or "sprayerBuyingStation",
        }
        SlurryPipeManager.log("registerSprayerPlaceable: buying-station sourceEntry for %s (types=%d)",
            tostring(placeable.configFileName), #bsFillTypes)
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
                    sc.connectorAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.connectorAnimationId, localAnimLibrary)
                end
                if sc.valveAnimationId ~= nil then
                    sc.valveAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.valveAnimationId, localAnimLibrary)
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
    -- [SPS 1.0.0.9.25] Adopt liquid that arrived outside SPS (dev fill /
    -- store's own buy trigger) so it is pumpable through dynamic couplers.
    self:_adoptOrphanSprayerLiquid(entry)
    -- [SPS 1.0.0.9.26] One-type-per-tank gate on this store's Storage:
    -- external fills (buy trigger, dev) are refused once every tank is
    -- occupied, and active types are capped to whole-tank grants.
    self:_installDynStoreGate(entry)

    -- [SPS 1.0.1.2] Sprayer buying-station type switch: same walk-up
    -- activatable as the slurry well (SPSBuyStationActivatable), constructed
    -- with systemId=1 so its toggle request routes to THIS entry's sourceEntry
    -- even if a placeable ever carries both systems. Only meaningful when more
    -- than one type is declared — getIsActivatable hides itself otherwise.
    -- Must run before xmlFile:delete (reads switchNodeName / switchRadius).
    if sourceEntry ~= nil and sourceEntry.type == SPS_SOURCE_TYPE_BUYING_STATION
    and SPSBuyStationActivatable ~= nil
    and g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        local switchNode   = findLinkedNode(xmlFile:getString(kp .. "buyingStation#switchNodeName", nil))
        local switchRadius = xmlFile:getFloat(kp .. "buyingStation#switchRadius", 3.0)
        local buyAct = SPSBuyStationActivatable.new(entry, switchNode, switchRadius, 1)
        entry.buyStationActivatable = buyAct
        g_currentMission.activatableObjectsSystem:addActivatable(buyAct)
    end

    if xmlFileOwned then xmlFile:delete() end
    table.insert(self.registeredSprayerPlaceables, entry)
end

-- [SPS 1.0.1.2] Returns entry, sourceEntry for a registered SPRAYER
-- buying-station placeable — sprayer-registry mirror of getBuyStationEntry.
function SlurryPipeManager:getSprayerBuyStationEntry(placeable)
    for _, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.object == placeable then
            local se = entry.sourceEntry
            if se ~= nil and se.type == SPS_SOURCE_TYPE_BUYING_STATION then
                return entry, se
            end
            return nil, nil
        end
    end
    return nil, nil
end

-- [SPS 1.0.1.3] The liquid a PART-FULL sprayer currently connected to this
-- buying station holds, or nil (no connection / connected sprayer empty).
-- While non-nil the station is dedicated to that liquid: the flow tick forces
-- it and applyBuyStationType refuses a switch away from it (prompt hidden by
-- SPSBuyStationActivatable). Runs identically on clients — connection state
-- and fill levels are already synced.
function SlurryPipeManager:getSprayerBuyStationHeldType(placeable)
    local entry = self:getSprayerBuyStationEntry(placeable)
    if entry == nil then return nil end
    for _, sc in ipairs(entry.couplings or {}) do
        if sc.isConnected then
            local veh = sc.connectedTarget
            if veh ~= nil and veh.getFillUnitFillLevel ~= nil then
                local vEntry = self:getSprayerVehicleEntry(veh)
                local fui = 1
                if vEntry ~= nil and vEntry.couplings ~= nil and #vEntry.couplings > 0 then
                    fui = vEntry.couplings[1].fillUnitIndex or 1
                end
                local lvl = veh:getFillUnitFillLevel(fui) or 0
                local ft  = veh:getFillUnitFillType(fui)
                if lvl > 0 and ft ~= nil and ft ~= FillType.UNKNOWN then
                    return ft
                end
            end
        end
    end
    return nil
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

    -- [SPS 1.0.0.9.24] Per-config coupler animation definitions — see
    -- registerSprayerVehicle.
    local localAnimLibrary = nil
    if SPSCouplerAnimator ~= nil and SPSCouplerAnimator.parseLocal ~= nil then
        localAnimLibrary = SPSCouplerAnimator.parseLocal(xmlFile, kp)
    end

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
                    sc.connectorAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.connectorAnimationId, localAnimLibrary)
                end
                if sc.valveAnimationId ~= nil then
                    sc.valveAnim = SPSCouplerAnimator.bind(sc.mountNode, sc.valveAnimationId, localAnimLibrary)
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
            -- [SPS 1.0.0.10.3] Balance the per-instance Storage gate installed at
            -- registration, so the wrappers do not outlive the entry they close over.
            self:_uninstallDynStoreGate(entry)
            -- [SPS 1.0.1.2] Sprayer buying-station type-switch activatable cleanup.
            if entry.buyStationActivatable ~= nil then
                entry.buyStationActivatable:delete()
                entry.buyStationActivatable = nil
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

    -- [SPS 1.0.1.3] Sprayer buying station: when a part-full sprayer connects,
    -- the station's sold-type selection snaps to the sprayer's held liquid
    -- (server-authoritative; applyBuyStationType broadcasts STATE so every
    -- prompt updates). If the station does not sell the held type the
    -- selection stays put and the flow's own sold gate denies with a log.
    if g_server ~= nil then
        local vehSide, stationOwner = nil, nil
        if ownerAEntry ~= nil then vehSide = ownerA; stationOwner = ownerB
        elseif ownerBEntry ~= nil then vehSide = ownerB; stationOwner = ownerA end
        if vehSide ~= nil and stationOwner ~= nil and self.getSprayerBuyStationEntry ~= nil then
            local _, se = self:getSprayerBuyStationEntry(stationOwner)
            if se ~= nil and vehSide.getFillUnitFillLevel ~= nil then
                local vEntry = self:getSprayerVehicleEntry(vehSide)
                local fui = 1
                if vEntry ~= nil and vEntry.couplings ~= nil and #vEntry.couplings > 0 then
                    fui = vEntry.couplings[1].fillUnitIndex or 1
                end
                local heldLvl = vehSide:getFillUnitFillLevel(fui) or 0
                local heldFt  = vehSide:getFillUnitFillType(fui)
                if heldLvl > 0 and heldFt ~= nil and heldFt ~= FillType.UNKNOWN
                and heldFt ~= se.fillType
                and self:buyStationSellsFillType(se, heldFt) then
                    SlurryPipeManager.log("applySprayerConnect: buy station auto-switched to held type %s",
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(heldFt)))
                    self:applyBuyStationType(stationOwner, heldFt, true, 1)
                end
            end
        end
    end
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
    -- [SPS 1.0.1.4] Front/rear tank combo (FlowControl): when this vehicle is one
    -- half of a linked front-tank + rear-sprayer pair, the vehicle side of the
    -- pipe becomes BOTH fill units — fill both / drain both, regardless of which
    -- member the pipe is physically connected to.
    local combo = self._spsSprayerCombos ~= nil and self._spsSprayerCombos[vehicle] or nil
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

    -- [SPS 1.0.1.4] Combo discharge: the session vehicle's own unit may be empty
    -- while its partner still holds liquid — resolve the held type across both
    -- units so a drain-both session doesn't stall on an empty session unit.
    if combo ~= nil and srcEntry == vehicleEntry
    and (fillType == nil or fillType == FillType.UNKNOWN) then
        fillType = self:_comboHeldFillType(combo)
    end

    -- [SPS 1.0.1.3] Buying-station source: a part-full sprayer keeps its held
    -- type no matter what the station switch says — mirror of the slurry
    -- station rule ("a part-full tanker keeps its held type"). Precedence
    -- stays restrict > held > selection: the coupler-restrict block below
    -- still overrides this, exactly as it overrides the selection.
    if srcEntry.type == SPS_SOURCE_TYPE_BUYING_STATION
    and dstEntry.type == "FILL_UNIT_ONLY" and dstEntry.vehicle ~= nil then
        local heldLvl = dstEntry.vehicle:getFillUnitFillLevel(dstEntry.fillUnitIndex) or 0
        local heldFt  = dstEntry.vehicle:getFillUnitFillType(dstEntry.fillUnitIndex)
        if heldLvl > 0 and heldFt ~= nil and heldFt ~= FillType.UNKNOWN then
            fillType = heldFt
        end
    end

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
            -- [SPS 1.0.0.9.25] Before declaring it empty, sweep for liquid
            -- that entered the aggregate Storage outside SPS (dev fill /
            -- store buy trigger) and adopt it into free compartments.
            if dynStoreCoupler.dynFillType == nil or (dynStoreCoupler.dynLevel or 0) <= 0 then
                self:_adoptOrphanSprayerLiquid(dynEntry)
            end
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

    -- [SPS 1.0.1.4] Combo fill: the destination passes if EITHER member accepts
    -- the type (the split helper only routes liquid into accepting units).
    local comboDestAccepts = false
    if combo ~= nil and dstEntry == vehicleEntry then
        comboDestAccepts = self:_comboAcceptsFillType(combo, fillType)
    end
    -- Destination must accept this fillType (dynamic compartments enforce their
    -- own permit + capacity above/below, and pre-seeded zero-capacity types
    -- would fail the vanilla free-capacity check before the first lock).
    if dynStoreCoupler == nil and not comboDestAccepts and not self:_destAcceptsFillType(dstEntry, fillType) then 
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
    elseif srcEntry.type == SPS_SOURCE_TYPE_BUYING_STATION then
        -- [SPS 1.0.1.2] Infinite paid source — the per-tick amount is bounded
        -- by rate and destination capacity below; the money gate lives in
        -- transferSprayerFillFromBuyingStation (applied=0 stalls the flow,
        -- pump stays on, same as a drained store).
        sourceLevel = math.huge
    end
    -- [SPS 1.0.1.4] Combo drain: source level is the SUM of both members' levels
    -- holding this fillType, so the flow keeps running until both are empty.
    if combo ~= nil and srcEntry == vehicleEntry then
        sourceLevel = self:_comboFillLevel(combo, fillType)
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
    -- [SPS 1.0.1.4] Combo fill: free capacity is the SUM across both members that
    -- accept this fillType — dest-full only when BOTH tanks are full.
    if combo ~= nil and dstEntry == vehicleEntry then
        freeCapacity = self:_comboFreeCapacity(combo, fillType)
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
            -- [SPS 1.0.1.4] Combo: split the vehicle-side deposit across both tanks
            if combo ~= nil then
                self:_comboDistributeFill(combo, amount, fillType, vehicle)
            else
                self:addToSource(dstEntry, amount, fillType, vehicle)
            end
        else
            -- [SPS 1.0.1.4] Combo: draw the vehicle-side withdrawal from both tanks
            if combo ~= nil then
                self:_comboDistributeDrain(combo, amount, fillType, vehicle)
            else
                self:removeFromSource(srcEntry, amount, fillType, vehicle)
            end
            self:_dynCompartmentDeposit(dynEntry, dynStoreCoupler, fillType, amount)
        end
    else
        if srcEntry.type == SPS_SOURCE_TYPE_BUYING_STATION then
            -- [SPS 1.0.1.2] Paid fill — vanilla station purchase (or SPS-side
            -- purchase for extras) replaces removeFromSource+addToSource: the
            -- station has no level to decrement and the vanilla call performs
            -- the fill itself. Destination is always the sprayer vehicle here
            -- (_destAcceptsFillType returns false for a buy-station dest, so
            -- the Unload direction never reaches this line).
            self:transferSprayerFillFromBuyingStation(vehicle, session, amount, fillType, srcEntry)
        else
            -- [SPS 1.0.1.4] Combo: whichever side of the transfer is the vehicle
            -- becomes a split across both combo members; the external side is
            -- untouched. srcEntry/dstEntry compare by table identity against
            -- vehicleEntry, so only the vehicle side ever reroutes.
            if combo ~= nil and srcEntry == vehicleEntry then
                self:_comboDistributeDrain(combo, amount, fillType, vehicle)
            else
                self:removeFromSource(srcEntry, amount, fillType, vehicle)
            end
            if combo ~= nil and dstEntry == vehicleEntry then
                self:_comboDistributeFill(combo, amount, fillType, vehicle)
            else
                self:addToSource(dstEntry, amount, fillType, vehicle)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.2] Sprayer buying-station fill
-- ---------------------------------------------------------------------------
-- Fill a sprayer from a buying-station placeable. Sprayer mirror of the slurry
-- transferFillFromBuyingStation (SPSM_Flow — vanilla behaviour verified there
-- against PlaceableBuyingStation.lua / BuyingStation.lua):
--   * Vanilla-declared types: station:addFillLevelToFillableObject performs
--     the whole purchase server-side (farm money gate, fill, per-litre charge
--     at getEffectiveFillTypePrice, delayed money-change HUD).
--   * SPS-extra types (extraFillType / extraFillTypeCategory): the vanilla
--     path would index a nil priceScale, so SPS performs the same maths —
--     money gate (>0), fill, charge at priceScale x pricePerLiter x
--     EconomyManager.getPriceMultiplier via g_currentMission:addMoney with the
--     station's own moneyChangeType. priceScale 0 = free.
--   * NO thickness/crust blends — those are slurry tanker consistency state
--     and do not exist on sprayer fill units.
--   * applied <= 0 (farm broke / fill unit refused, e.g. held-type mismatch)
--     = stalled flow; pump stays on, same as a drained store.
--   * Server-only by construction: tickSprayerFlow runs behind the g_server
--     guard in updateSprayers, matching LoadTrigger:update's isServer gate
--     around the same vanilla call.
function SlurryPipeManager:transferSprayerFillFromBuyingStation(vehicle, session, delta, fillType, extSource)
    if delta == nil or delta <= 0 then return end
    local station = extSource ~= nil and extSource.station or nil
    if station == nil then return end
    -- Per-coupler fillType restriction already applied by the tickSprayerFlow
    -- restrict block; an unresolved type falls back to the station selection.
    if fillType == nil or fillType == FillType.UNKNOWN then
        fillType = extSource.fillType
    end
    -- The station must actually sell this type: vanilla-provided
    -- (BuyingStation.providedFillTypes) or SPS-extra (config-declared).
    local sold, isExtra = self:buyStationSellsFillType(extSource, fillType)
    if fillType == nil or not sold then
        if not session._loggedBuyStationTypeBlock then
            session._loggedBuyStationTypeBlock = true
            SlurryPipeManager.log("transferSprayerFillFromBuyingStation: station does not provide fillType=%s — fill denied",
                tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType) or fillType))
        end
        return
    end
    session._loggedBuyStationTypeBlock = nil
    -- [SPS 1.0.1.6] Front/rear combo: split the purchase across BOTH members,
    -- proportional to free capacity — same rule as _comboDistributeFill — so a
    -- buying-station fill behaves exactly like a pipe fill (both tanks reach
    -- full together). Each member is purchased into individually: the vanilla
    -- station path takes any fillable object + fill unit, and the SPS-extra
    -- path charges each member's own farm. No combo = one member = the exact
    -- pre-1.0.1.6 behaviour.
    local members = { { vehicle = vehicle, fui = session.vehicleFillUnit, share = delta } }
    local combo = self._spsSprayerCombos ~= nil and self._spsSprayerCombos[vehicle] or nil
    if combo ~= nil then
        local pv, pFui
        if combo.rear == vehicle then
            pv, pFui = combo.front, combo.frontFillUnit
        else
            pv, pFui = combo.rear, combo.rearFillUnit
        end
        if pv ~= nil and pv.getFillUnitAllowsFillType ~= nil
        and pv:getFillUnitAllowsFillType(pFui, fillType) then
            local ownFree = math.max(0, (vehicle:getFillUnitCapacity(session.vehicleFillUnit) or 0)
                - (vehicle:getFillUnitFillLevel(session.vehicleFillUnit) or 0))
            local pFree = math.max(0, (pv:getFillUnitCapacity(pFui) or 0)
                - (pv:getFillUnitFillLevel(pFui) or 0))
            local totalFree = ownFree + pFree
            if pFree > 0 and totalFree > 0 then
                members[1].share = math.min(delta * (ownFree / totalFree), ownFree)
                table.insert(members, { vehicle = pv, fui = pFui,
                    share = math.min(delta * (pFree / totalFree), pFree) })
            end
        end
    end
    local applied = 0
    for _, mem in ipairs(members) do
        if mem.share > 0 then
            local memApplied
            if isExtra then
                local farmId = mem.vehicle:getOwnerFarmId()
                if not (0 < g_currentMission:getMoney(farmId)) then
                    memApplied = 0
                else
                    memApplied = mem.vehicle:addFillUnitFillLevel(farmId, mem.fui,
                        mem.share, fillType, ToolType.TRIGGER, nil)
                    if memApplied ~= nil and memApplied > 0 then
                        local scale        = extSource.extraPriceScales[fillType] or 1.0
                        local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillType)
                        local pricePerLiter = scale * (fillTypeDesc ~= nil and fillTypeDesc.pricePerLiter or 0)
                            * EconomyManager.getPriceMultiplier(fillType)
                        local price = pricePerLiter * memApplied
                        if price > 0 and extSource.station ~= nil then
                            g_currentMission:addMoney(-price, farmId, extSource.station.moneyChangeType, true)
                        end
                    end
                end
            else
                memApplied = station:addFillLevelToFillableObject(mem.vehicle, mem.fui,
                    fillType, mem.share, nil, ToolType.TRIGGER)
            end
            applied = applied + (memApplied or 0)
        end
    end
    if applied <= 0 then
        -- Farm out of money (vanilla gate) or fill unit refused (e.g. sprayer
        -- already holds a different liquid) — stalled flow.
        if session._lastBuyStationStall ~= true then
            session._lastBuyStationStall = true
            SlurryPipeManager.sprayTrace("transferSprayerFillFromBuyingStation[%s] applied=0 (no money or fill rejected, fillType=%s)",
                tostring(vehicle.configFileName),
                tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType) or fillType))
        end
        return
    end
    session._lastBuyStationStall = nil
    session.totalTransferred = (session.totalTransferred or 0) + applied
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

    -- [SPS 1.0.1.4] Front/rear tank combo: rebuild the pair map ~1/sec (attach/
    -- detach is slow-changing), run the FlowControl balancer every tick. Both are
    -- server-authoritative by construction (g_server guard above); fill level
    -- changes reach clients via the vanilla FillUnit dirty flags — no new events.
    self._sprayerComboMapTick = (self._sprayerComboMapTick or 0) + 1
    if self._sprayerComboMapTick >= 60 or self._spsSprayerCombos == nil then
        self._sprayerComboMapTick = 0
        self:_updateSprayerCombos()
        -- [SPS 1.0.1.5] Dynamic-store orphan reconcile, same 1-second cadence:
        -- external fills through the store's own buy/fill trigger raise the
        -- vanilla aggregate but not the compartment ledgers, so the info box
        -- showed stale T-rows (locked tanks at 0 l, litres missing per tank)
        -- until the next empty-compartment fill session tripped adoption.
        self:_tickSprayerDynReconcile()
    end
    self:_tickSprayerComboBalance(dt)

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

-- ===========================================================================
-- [SPS 1.0.1.4] FRONT/REAR TANK COMBO ("FlowControl")
-- ===========================================================================
-- Generic pairing of ANY front tank with ANY rear sprayer on the same root
-- vehicle — no per-pair config required. Discriminator (confirmed against
-- vanilla sources): the rear consumer carries spec_sprayer (Sprayer.lua);
-- front tanks are plain fillable implements (no spec_sprayer) positioned
-- forward of the root vehicle origin.
--
-- Three behaviours:
--   1. PIPE FILL  — one connection (to EITHER member) fills BOTH fill units,
--      split proportional to free capacity, so tanks with different starting
--      levels reach 100% together (real FT-P: "both tanks are automatically
--      fully filled during the filling process").
--   2. PIPE DRAIN — one connection drains BOTH units, split proportional to
--      current level; source-empty only when both are empty.
--   3. BALANCER   — fully automatic, no pump, no keybind (the real FT carries
--      its own transfer pump): when the rear falls to lowPct (default 30%),
--      liquid is pulled front->rear at transferLitersPerMinute (default 200)
--      until the rear recovers to highPct (default 40%) or the front is empty.
--      Net effect matches the real system: the rear is never emptied before
--      the front; the front drains first (front axle load preserved), then
--      the rear runs 30% -> 0.
--
-- Pairing requires only ONE member to be SPS-registered (the one the pipe
-- physically connects to). Front candidates that are SPS slurry-registered
-- (front-mount slurry receivers, SPSM_FrontMount) are excluded so the two
-- systems never fight over the same tank.
--
-- MP: everything below runs inside the g_server guard of updateSprayers.
-- Combo state is derived (recomputed from attach state), so JIP needs no
-- state dump; fill levels sync via vanilla FillUnit dirty flags.
--
-- Known v1 limitation: a buying-station fill (transferSprayerFillFromBuying-
-- Station) fills only the session vehicle's own unit — the vanilla station
-- call performs the fill itself, so it cannot be split. The balancer then
-- redistributes to the rear as normal.
-- ===========================================================================

-- Gated trace for this block. Channel: SPSM_Sprayers.FrontTank
local function ftbTrace(fmt, ...)
    if SPSDebugConfig == nil or SPSDebugConfig.isOn == nil
    or not SPSDebugConfig.isOn("SPSM_Sprayers.FrontTank") then return end
    if select("#", ...) > 0 then
        print("[SPS FT-BAL] " .. string.format(fmt, ...))
    else
        print("[SPS FT-BAL] " .. tostring(fmt))
    end
end

-- True when obj sits forward of the root vehicle origin (local +Z in root
-- space). User-confirmed convention: a front tank is always physically in
-- front, so the sign test is sufficient.
function SlurryPipeManager:_comboIsForwardOfRoot(obj, root)
    if obj == nil or root == nil or obj.rootNode == nil or root.rootNode == nil then return false end
    local wx, wy, wz = getWorldTranslation(obj.rootNode)
    local _, _, lz = worldToLocal(root.rootNode, wx, wy, wz)
    return lz > 0
end

-- Recursively collect every vehicle attached under 'vehicle' (depth-capped).
-- Uses vanilla AttacherJoints:getAttachedImplements (AttacherJoints.lua:1039).
function SlurryPipeManager:_comboCollectAttached(vehicle, out, depth)
    out   = out or {}
    depth = depth or 0
    if depth > 4 or vehicle == nil or vehicle.getAttachedImplements == nil then return out end
    for _, impl in ipairs(vehicle:getAttachedImplements() or {}) do
        local obj = impl.object
        if obj ~= nil then
            table.insert(out, obj)
            self:_comboCollectAttached(obj, out, depth + 1)
        end
    end
    return out
end

-- First fill unit on 'candidate' sharing at least one supported fillType with
-- refTypes (a supportedFillTypes table, FillUnit.lua:819 format: [ft]=true).
function SlurryPipeManager:_comboSharedFillUnit(candidate, refTypes)
    if refTypes == nil or candidate == nil
    or candidate.spec_fillUnit == nil or candidate.spec_fillUnit.fillUnits == nil then return nil end
    for fui, fu in ipairs(candidate.spec_fillUnit.fillUnits) do
        if fu.supportedFillTypes ~= nil then
            for ft, allowed in pairs(fu.supportedFillTypes) do
                if allowed == true and refTypes[ft] == true then
                    return fui
                end
            end
        end
    end
    return nil
end

-- Find a front tank for a registered rear sprayer. Front candidate must have
-- no spec_sprayer, sit forward of the root origin, NOT be slurry-registered,
-- and share a supported fillType with the rear's sprayer fill unit.
function SlurryPipeManager:_comboFindFrontForRear(rear, root)
    local rearFui = 1
    if rear.getSprayerFillUnitIndex ~= nil then
        rearFui = rear:getSprayerFillUnitIndex() or 1
    end
    local rearTypes = rear.getFillUnitSupportedFillTypes ~= nil
        and rear:getFillUnitSupportedFillTypes(rearFui) or nil
    if rearTypes == nil then return nil end
    for _, obj in ipairs(self:_comboCollectAttached(root)) do
        if obj ~= rear
        and obj.spec_sprayer == nil
        and obj.spec_fillUnit ~= nil
        and self:getVehicleEntry(obj) == nil
        and self:_comboIsForwardOfRoot(obj, root) then
            local frontFui = self:_comboSharedFillUnit(obj, rearTypes)
            if frontFui ~= nil then
                return obj, frontFui, rearFui
            end
        end
    end
    return nil
end

-- Find a rear sprayer for a registered front tank. Rear candidate carries
-- spec_sprayer and shares a supported fillType with the front's tank. The
-- root vehicle itself is a valid rear (self-propelled sprayer edge case).
function SlurryPipeManager:_comboFindRearForFront(front, root)
    local candidates = self:_comboCollectAttached(root)
    table.insert(candidates, 1, root)
    for _, obj in ipairs(candidates) do
        if obj ~= front
        and obj.spec_sprayer ~= nil
        and obj.getFillUnitSupportedFillTypes ~= nil then
            local rearFui = 1
            if obj.getSprayerFillUnitIndex ~= nil then
                rearFui = obj:getSprayerFillUnitIndex() or 1
            end
            local rearTypes = obj:getFillUnitSupportedFillTypes(rearFui)
            local frontFui = self:_comboSharedFillUnit(front, rearTypes)
            if frontFui ~= nil then
                return obj, frontFui, rearFui
            end
        end
    end
    return nil
end

-- Rebuild the combo map from current attach state. Keyed by BOTH members so
-- tickSprayerFlow resolves the pair no matter which side the pipe is on;
-- each combo is iterated once via the (key == combo.rear) filter.
function SlurryPipeManager:_updateSprayerCombos()
    local combos = {}
    for _, vEntry in ipairs(self.registeredSprayerVehicles) do
        local obj = vEntry.object
        if obj ~= nil and obj.getRootVehicle ~= nil then
            local root = obj:getRootVehicle()
            if root ~= nil and root.rootNode ~= nil then
                local front, rear, frontFui, rearFui
                if obj.spec_sprayer ~= nil then
                    if root ~= obj then
                        rear = obj
                        front, frontFui, rearFui = self:_comboFindFrontForRear(rear, root)
                    end
                elseif obj.spec_fillUnit ~= nil and root ~= obj
                and self:_comboIsForwardOfRoot(obj, root) then
                    front = obj
                    rear, frontFui, rearFui = self:_comboFindRearForFront(front, root)
                end
                if front ~= nil and rear ~= nil and combos[rear] == nil then
                    local rearEntry  = self:getSprayerVehicleEntry(rear)
                    local frontEntry = self:getSprayerVehicleEntry(front)
                    local balance = (rearEntry ~= nil and rearEntry.ftBalance)
                        or (frontEntry ~= nil and frontEntry.ftBalance)
                        or { lowPct = 30, highPct = 40, litersPerMinute = 200 }
                    local combo = {
                        front = front, frontFillUnit = frontFui,
                        rear  = rear,  rearFillUnit  = rearFui,
                        balance = balance,
                    }
                    combos[rear]  = combo
                    combos[front] = combo
                    local prev = self._spsSprayerCombos ~= nil and self._spsSprayerCombos[rear] or nil
                    if prev == nil or prev.front ~= front then
                        ftbTrace("combo linked: front=%s (fui=%d) <-> rear=%s (fui=%d)",
                            tostring(front.configFileName), frontFui,
                            tostring(rear.configFileName), rearFui)
                    end
                end
            end
        end
    end
    -- Unlink trace + pull-state cleanup for combos that disappeared
    if self._spsSprayerCombos ~= nil then
        for k, c in pairs(self._spsSprayerCombos) do
            if k == c.rear and combos[k] == nil then
                ftbTrace("combo unlinked: rear=%s", tostring(k.configFileName))
                if self._spsComboPullState ~= nil then
                    self._spsComboPullState[k] = nil
                end
            end
        end
    end
    self._spsSprayerCombos = combos
end

-- Held fillType across both members (rear preferred). nil when both empty.
function SlurryPipeManager:_comboHeldFillType(combo)
    local members = {
        { combo.rear,  combo.rearFillUnit  },
        { combo.front, combo.frontFillUnit },
    }
    for _, m in ipairs(members) do
        local v, fui = m[1], m[2]
        if v ~= nil and v.getFillUnitFillLevel ~= nil
        and (v:getFillUnitFillLevel(fui) or 0) > 0 then
            local ft = v:getFillUnitFillType(fui)
            if ft ~= nil and ft ~= FillType.UNKNOWN then
                return ft
            end
        end
    end
    return nil
end

-- True when EITHER member accepts the fillType (vanilla getFillUnitAllows-
-- FillType, FillUnit.lua:835 — held-type + change-threshold aware).
function SlurryPipeManager:_comboAcceptsFillType(combo, fillType)
    if fillType == nil then return false end
    if combo.rear ~= nil and combo.rear.getFillUnitAllowsFillType ~= nil
    and combo.rear:getFillUnitAllowsFillType(combo.rearFillUnit, fillType) then
        return true
    end
    if combo.front ~= nil and combo.front.getFillUnitAllowsFillType ~= nil
    and combo.front:getFillUnitAllowsFillType(combo.frontFillUnit, fillType) then
        return true
    end
    return false
end

-- Combined level of both members holding fillType (nil type = any held).
function SlurryPipeManager:_comboFillLevel(combo, fillType)
    local total = 0
    local members = {
        { combo.rear,  combo.rearFillUnit  },
        { combo.front, combo.frontFillUnit },
    }
    for _, m in ipairs(members) do
        local v, fui = m[1], m[2]
        if v ~= nil and v.getFillUnitFillLevel ~= nil then
            local lvl = v:getFillUnitFillLevel(fui) or 0
            if lvl > 0 then
                if fillType == nil or v:getFillUnitFillType(fui) == fillType then
                    total = total + lvl
                end
            end
        end
    end
    return total
end

-- Combined free capacity across members that accept fillType.
function SlurryPipeManager:_comboFreeCapacity(combo, fillType)
    local total = 0
    local members = {
        { combo.rear,  combo.rearFillUnit  },
        { combo.front, combo.frontFillUnit },
    }
    for _, m in ipairs(members) do
        local v, fui = m[1], m[2]
        if v ~= nil and v.getFillUnitCapacity ~= nil then
            if fillType == nil
            or (v.getFillUnitAllowsFillType ~= nil and v:getFillUnitAllowsFillType(fui, fillType)) then
                local cap = v:getFillUnitCapacity(fui) or 0
                local lvl = v:getFillUnitFillLevel(fui) or 0
                total = total + math.max(0, cap - lvl)
            end
        end
    end
    return total
end

-- Split an incoming amount across both members proportional to FREE capacity:
-- different starting levels reach 100% at the same moment. Only accepting
-- members receive liquid; per-member share is clamped to that member's free
-- space so nothing overfills. Uses the standard addToSource helper (bypass
-- path, dirty flags, MP sync all inherited).
function SlurryPipeManager:_comboDistributeFill(combo, amount, fillType, farmVehicle)
    if amount == nil or amount <= 0 then return end
    local members   = {}
    local totalFree = 0
    local defs = {
        { combo.rear,  combo.rearFillUnit  },
        { combo.front, combo.frontFillUnit },
    }
    for _, m in ipairs(defs) do
        local v, fui = m[1], m[2]
        if v ~= nil and v.getFillUnitAllowsFillType ~= nil
        and v:getFillUnitAllowsFillType(fui, fillType) then
            local free = math.max(0, (v:getFillUnitCapacity(fui) or 0) - (v:getFillUnitFillLevel(fui) or 0))
            if free > 0 then
                table.insert(members, { vehicle = v, fui = fui, free = free })
                totalFree = totalFree + free
            end
        end
    end
    if totalFree <= 0 then return end
    for _, mem in ipairs(members) do
        local share = math.min(amount * (mem.free / totalFree), mem.free)
        if share > 0 then
            self:addToSource(
                { type = "FILL_UNIT_ONLY", vehicle = mem.vehicle, fillUnitIndex = mem.fui },
                share, fillType, farmVehicle)
        end
    end
end

-- Split an outgoing amount across both members proportional to current LEVEL
-- (matching fillType): both drain toward empty together. Uses the standard
-- removeFromSource helper.
function SlurryPipeManager:_comboDistributeDrain(combo, amount, fillType, farmVehicle)
    if amount == nil or amount <= 0 then return end
    local members  = {}
    local totalLvl = 0
    local defs = {
        { combo.rear,  combo.rearFillUnit  },
        { combo.front, combo.frontFillUnit },
    }
    for _, m in ipairs(defs) do
        local v, fui = m[1], m[2]
        if v ~= nil and v.getFillUnitFillLevel ~= nil then
            local lvl = v:getFillUnitFillLevel(fui) or 0
            if lvl > 0 and (fillType == nil or v:getFillUnitFillType(fui) == fillType) then
                table.insert(members, { vehicle = v, fui = fui, lvl = lvl })
                totalLvl = totalLvl + lvl
            end
        end
    end
    if totalLvl <= 0 then return end
    for _, mem in ipairs(members) do
        local share = math.min(amount * (mem.lvl / totalLvl), mem.lvl)
        if share > 0 then
            self:removeFromSource(
                { type = "FILL_UNIT_ONLY", vehicle = mem.vehicle, fillUnitIndex = mem.fui },
                share, fillType, farmVehicle)
        end
    end
end

-- FlowControl balancer tick (server). Fully automatic — no SPS pump state, no
-- keybind (the real front tank carries its own transfer pump). Hysteresis:
-- pull starts at lowPct, stops at highPct / front empty / type mismatch.
-- Suspended while a pipe flow session is active on either member so it never
-- fights a fill-both / drain-both transfer.
function SlurryPipeManager:_tickSprayerComboBalance(dt)
    if self._spsSprayerCombos == nil then return end
    self._spsComboPullState = self._spsComboPullState or {}
    for key, combo in pairs(self._spsSprayerCombos) do
        if key == combo.rear
        and self.activeSprayerFlows[combo.rear] == nil
        and self.activeSprayerFlows[combo.front] == nil then
            local rear,  rFui = combo.rear,  combo.rearFillUnit
            local front, fFui = combo.front, combo.frontFillUnit
            local rearCap  = rear:getFillUnitCapacity(rFui) or 0
            local rearLvl  = rear:getFillUnitFillLevel(rFui) or 0
            local frontLvl = front:getFillUnitFillLevel(fFui) or 0
            local pct = 0
            if rearCap > 0 then pct = rearLvl / rearCap * 100 end
            local b       = combo.balance or {}
            local lowPct  = b.lowPct or 30
            local highPct = math.max(b.highPct or 40, lowPct + 1)
            local pulling = self._spsComboPullState[rear] == true

            if not pulling and pct <= lowPct and frontLvl > 0 then
                local ft = front:getFillUnitFillType(fFui)
                if ft ~= nil and ft ~= FillType.UNKNOWN
                and rear.getFillUnitAllowsFillType ~= nil
                and rear:getFillUnitAllowsFillType(rFui, ft) then
                    pulling = true
                    self._spsComboPullState[rear] = true
                    rear._spsFtbTypeBlockLogged = nil
                    ftbTrace("balance START rear=%.1f%% (low=%.0f%%) front=%.0f l type=%s",
                        pct, lowPct, frontLvl,
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(ft)))
                elseif ft ~= nil and ft ~= FillType.UNKNOWN
                and rear._spsFtbTypeBlockLogged ~= true then
                    -- One-shot WARNING-class line (unconditional per SPS logging rules)
                    rear._spsFtbTypeBlockLogged = true
                    print(string.format(
                        "[SPS] WARNING: frontTankBalance: rear sprayer '%s' cannot accept front tank fillType %s — transfer blocked",
                        tostring(rear.configFileName),
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(ft))))
                end
            end

            if pulling then
                local ft = front:getFillUnitFillType(fFui)
                local stopReason = nil
                if frontLvl <= 0 or ft == nil or ft == FillType.UNKNOWN then
                    stopReason = "front-empty"
                elseif pct >= highPct then
                    stopReason = "rear-restored"
                elseif rear.getFillUnitAllowsFillType == nil
                or not rear:getFillUnitAllowsFillType(rFui, ft) then
                    stopReason = "type-mismatch"
                end
                if stopReason ~= nil then
                    self._spsComboPullState[rear] = nil
                    ftbTrace("balance STOP (%s) rear=%.1f%% front=%.0f l",
                        stopReason, pct, frontLvl)
                else
                    -- l/min -> l/ms; chunk bounded by front level + rear free space
                    local rate  = (b.litersPerMinute or 200) / 60000
                    local chunk = math.min(rate * dt, frontLvl, math.max(0, rearCap - rearLvl))
                    if chunk > 0 then
                        self:removeFromSource(
                            { type = "FILL_UNIT_ONLY", vehicle = front, fillUnitIndex = fFui },
                            chunk, ft, rear)
                        self:addToSource(
                            { type = "FILL_UNIT_ONLY", vehicle = rear, fillUnitIndex = rFui },
                            chunk, ft, rear)
                        -- 1s heartbeat (keyed on the rear vehicle so it survives map rebuilds)
                        rear._spsFtbHbMs = rear._spsFtbHbMs or 0
                        local nowMs = g_time or 0
                        if nowMs - rear._spsFtbHbMs >= 1000 then
                            rear._spsFtbHbMs = nowMs
                            ftbTrace("balance FLOW %.2f l/s rear=%.1f%% (%.0f l) front=%.0f l",
                                chunk / math.max(dt, 0.0001) * 1000, pct, rearLvl, frontLvl)
                        end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.5] Periodic orphan reconcile for dynamic-compartment stores.
-- ---------------------------------------------------------------------------
-- _adoptOrphanSprayerLiquid previously ran only at placeable registration and
-- from the compartment-empty branch of tickSprayerFlow, so liquid bought at
-- the store's own buy/fill trigger mid-session stayed orphaned in the vanilla
-- aggregate: Used Capacity was right while the per-tank T-rows were stale
-- (a just-locked tank stuck at 0 l, top-ups into locked tanks not credited).
-- This sweep runs on the same 1-second cadence as the combo map rebuild,
-- behind a cheap divergence check (aggregate sum of non-fixed types vs the
-- compartment ledger sum) so the full adoption pass only executes when
-- something is actually orphaned. The adoption itself is unchanged: it is
-- idempotent, top-up-aware for locked tanks, MP-synced per compartment via
-- SPSSprayerCompartmentEvent, and recomputes dyn capacities afterwards.
-- Server-only by construction (called inside the g_server guard of
-- updateSprayers, matching _adoptOrphanSprayerLiquid's own g_server gate).
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_tickSprayerDynReconcile()
    for _, entry in ipairs(self.registeredSprayerPlaceables) do
        if entry.dynCouplers ~= nil and #entry.dynCouplers > 0 then
            local storage = entry.sourceEntry ~= nil and entry.sourceEntry.storage or nil
            if storage ~= nil and storage.fillLevels ~= nil then
                local ledger = 0
                for _, sc in ipairs(entry.dynCouplers) do
                    ledger = ledger + (sc.dynLevel or 0)
                end
                local aggregate = 0
                for ft, lvl in pairs(storage.fillLevels) do
                    if entry.spsFixedCaps == nil or entry.spsFixedCaps[ft] == nil then
                        aggregate = aggregate + (lvl or 0)
                    end
                end
                if aggregate - ledger > 0.001 then
                    self:_adoptOrphanSprayerLiquid(entry)
                end
            end
        end
    end
end
