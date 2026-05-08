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
    self.agitationEnabled           = true
    self._lastMonotonicDay          = nil  -- tracked to detect day transitions
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
        receiverEntries       = {},
        rubberBootPortEntries = {},
        pumpControlEntries    = {},
        litersPerSecond       = xmlFile:getFloat(kp .. "slurryPipeSystem.flow#litersPerSecond", SlurryPipeManager.DEFAULT_LITERS_PER_SECOND),
        selfPowered           = xmlFile:getBool(kp .. "slurryPipeSystem.pump#selfPowered", false),
        conduit               = xmlFile:getBool(kp .. "slurryPipeSystem.pump#conduit", false),
        agitatorOnly          = xmlFile:getBool(kp .. "slurryPipeSystem#agitatorOnly", false),
        nodeTreeRoot          = nil,
        sourceEntry           = nil,
        xmlFileOwned          = xmlFileOwned,
        state = {
            pumpRunning       = false,
            valveOpen         = false,
            direction         = SPS_DIRECTION_FILL,
            spreaderValveOpen = false,
        },
    }

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
            print("[SPS] nodeTreeRoot name=" .. tostring(getName(nodeTreeRoot)) .. " children=" .. tostring(getNumOfChildren(nodeTreeRoot)) .. " effectNode=" .. tostring(entry.effectNode))
            local c0 = getChildAt(nodeTreeRoot, 0)
            if c0 ~= nil and c0 ~= 0 then
                print("[SPS] child0 name=" .. tostring(getName(c0)) .. " children=" .. tostring(getNumOfChildren(c0)))
                for gi = 0, getNumOfChildren(c0) - 1 do
                    local g = getChildAt(c0, gi)
                    print("[SPS]   group[" .. gi .. "]=" .. tostring(getName(g)) .. " children=" .. tostring(getNumOfChildren(g)))
                    for ci = 0, getNumOfChildren(g) - 1 do
                        local cont = getChildAt(g, ci)
                        print("[SPS]     container[" .. ci .. "]=" .. tostring(getName(cont)) .. " children=" .. tostring(getNumOfChildren(cont)))
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
                            print("[SPS] container target '" .. targetName .. "' not found in vehicle")
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
    print("[SPS] pipeEffects guard: isClient=" .. tostring(vehicle.isClient) .. " nodeTreeRoot=" .. tostring(entry.nodeTreeRoot ~= nil) .. " armEntries=" .. #entry.armEntries)
    if vehicle.isClient and entry.nodeTreeRoot ~= nil and #entry.armEntries > 0 then
        local effectNode = entry.effectNode
        local smokeNode  = entry.smokeNode
        print("[SPS] pipeEffects check: effectNode=" .. tostring(effectNode) .. " smokeNode=" .. tostring(smokeNode) .. " arms=" .. #entry.armEntries)
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
            print("[SPS] pipeEffects manually built: " .. #effects .. " for " .. tostring(vehicle.configFileName))
        else
            print("[SPS] pipeEffects: effect/pipeEffectSmoke not found in nodeTree")
        end
    end

    -- Pipe couplings (data loaded for future use; no connection logic active)
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
            local couplingEntry = {
                id                  = couplingId,
                mountNode           = mountNode,
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

    -- Pump controls
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

    -- Create pump control activatables for rear-control nodes
    entry.pumpControlActivatables = {}
    for _, pc in ipairs(entry.pumpControlEntries) do
        local pca = SPSPumpControlActivatable.new(vehicle, pc.node, pc.radius)
        table.insert(entry.pumpControlActivatables, pca)
        g_currentMission.activatableObjectsSystem:addActivatable(pca)
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
                print("[SPS] registerVehicle: agitator tipNode '" .. agitatorTipNodeName .. "' not found in " .. tostring(vehicle.configFileName))
            end
        end
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
            if entry.engineLoopSample ~= nil then
                g_soundManager:stopSample(entry.engineLoopSample)
                g_soundManager:deleteSample(entry.engineLoopSample)
                entry.engineLoopSample = nil
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
                            print("[SPS] registerPlaceable: container target '" .. targetName .. "' not found in placeable")
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
    elseif fillPlaneNode == nil and placeable.spec_husbandry ~= nil then
        -- No fill plane authored — husbandry placeable with coupling-only access.
        -- Build a minimal sourceEntry so coupling flow can read/write the storage
        -- even though arm surface detection is not possible.
        local storage = nil
        local sh = placeable.spec_husbandry
        if sh.storage ~= nil and type(sh.storage.getFillLevel) == "function" then
            storage = sh.storage
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
            SlurryDebug.log("registerPlaceable: husbandry coupling-only sourceEntry for " .. tostring(placeable.configFileName))
        else
            SlurryDebug.log("registerPlaceable: no storage found for husbandry placeable " .. tostring(placeable.configFileName))
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

    -- Restore saved thickness for this placeable if available
    if self._pendingThickness ~= nil and sourceEntry ~= nil then
        local compNode = placeable.components ~= nil and placeable.components[1] ~= nil
            and placeable.components[1].node or nil
        if compNode ~= nil then
            local px, py, pz = getWorldTranslation(compNode)
            for i, pt in ipairs(self._pendingThickness) do
                local dx, dy, dz = px - pt.px, py - pt.py, pz - pt.pz
                if (dx*dx + dy*dy + dz*dz) <= 1.0 then
                    sourceEntry.thickness        = pt.thickness
                    sourceEntry.thicknessDayCount = pt.dayCount
                    table.remove(self._pendingThickness, i)
                    SlurryDebug.log("[SPS Thickness] restored " .. string.format("%.1f", pt.thickness * 100)
                        .. "% for " .. tostring(placeable.configFileName))
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
    end

    xmlFile:setInt("slurryPipeSystem#selectedColorIndex", self.currentPipeColorIndex)
    xmlFile:setBool("slurryPipeSystem#agitationEnabled", self.agitationEnabled)

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
            xmlFile:setFloat(base .. "#thickness",     se.thickness or 0)
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
        for _, c in ipairs(pEntry.storeCouplings) do saveCouplingAnim(c, "placeable") end
    end
    for _, c in ipairs(self.chainTerminusEntries) do saveCouplingAnim(c, "chain") end

    xmlFile:save()
    xmlFile:delete()
    print("[SPS] saveCouplingConnections: saved " .. written .. " connections, "
        .. #self.pipeChains .. " chains to " .. tostring(savePath))
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

    -- Restore agitation toggle
    self.agitationEnabled = xmlFile:getBool("slurryPipeSystem#agitationEnabled", true)

    -- Load thickness data into a pending map keyed by rounded placeable position
    -- Actual application happens in tryResolvePendingConnections after placeables register
    self._pendingThickness = {}
    local thickIdx = 0
    while true do
        local base = string.format("slurryPipeSystem.thicknesses.entry(%d)", thickIdx)
        if not xmlFile:hasProperty(base) then break end
        table.insert(self._pendingThickness, {
            px        = xmlFile:getFloat(base .. "#px",        0),
            py        = xmlFile:getFloat(base .. "#py",        0),
            pz        = xmlFile:getFloat(base .. "#pz",        0),
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

    xmlFile:delete()
    print("[SPS] loadCouplingConnections: loaded " .. #self.pendingConnections
        .. " connections, " .. #self.pendingChains .. " chains, "
        .. #self.pendingDeployedCouplings .. " deployed couplings, "
        .. #self._pendingThickness .. " thickness entries"
        .. ", " .. animLoadIdx .. " coupler anim entries")
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

function SlurryPipeManager:onChainStartLaying(coupling, anchorActivatable)
    if coupling == nil then return end
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

function SlurryPipeManager:getVehicleEntry(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then return entry end
    end
    return nil
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

function SlurryPipeManager:onActionToggleSpreader(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    local newOpen = not state.spreaderValveOpen
    print("[SPS SPREADER] onActionToggleSpreader -> " .. tostring(newOpen) .. " pumpRunning=" .. tostring(state.pumpRunning))
    if newOpen and not state.pumpRunning then
        if vehicle.isClient then
            g_currentMission:showBlinkingWarning(g_i18n:getText("action_slurryPumpOn"), 2000)
        end
        print("[SPS SPREADER] blocked — pump not running")
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

function SlurryPipeManager:onActionToggleDirection(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
    if state.valveOpen then
        if vehicle.isClient then g_currentMission:showBlinkingWarning(g_i18n:getText("warning_slurryCloseFlowFirst"), 2000) end
        return
    end
    local newDir = (state.direction == SPS_DIRECTION_FILL) and SPS_DIRECTION_DISCHARGE or SPS_DIRECTION_FILL
    if g_server ~= nil then
        state.direction = newDir
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
    local pumpId = vehicle.spsActionEvents.pumpEventId
    if pumpId ~= nil then
        local pumpOn
        if self:isVehicleSelfPowered(vehicle) or self:vehicleHasSpreader(vehicle) then
            pumpOn = state.pumpRunning == true
        else
            pumpOn = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn()
        end
        g_inputBinding:setActionEventText(pumpId, pumpOn
            and g_i18n:getText("action_slurryPumpOff")
            or  g_i18n:getText("action_slurryPumpOn"))
    end
    local flowId = vehicle.spsActionEvents.flowEventId
    if flowId ~= nil then
        g_inputBinding:setActionEventText(flowId, state.valveOpen and g_i18n:getText("action_slurryFlowClose") or g_i18n:getText("action_slurryFlowOpen"))
        g_inputBinding:setActionEventActive(flowId, true)
    end
    local dirId = vehicle.spsActionEvents.dirEventId
    if dirId ~= nil then
        local dirTxt
        if self:isVehicleConduit(vehicle) then
            dirTxt = (state.direction == SPS_DIRECTION_FILL)
                and g_i18n:getText("action_spsConduitDirBtoA")
                or  g_i18n:getText("action_spsConduitDirAtoB")
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

function SlurryPipeManager:buildFlowSession(vehicle)
    local litersPerSecond = SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local vehicleFillUnit = 1
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            litersPerSecond = entry.litersPerSecond
            if #entry.armEntries > 0 then
                vehicleFillUnit = entry.armEntries[1].fillUnitIndex
            elseif #entry.couplingEntries > 0 then
                vehicleFillUnit = entry.couplingEntries[1].fillUnitIndex
            end
            break
        end
    end
    return { vehicle = vehicle, vehicleFillUnit = vehicleFillUnit, baseLitersPerSecond = litersPerSecond }
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
function SlurryPipeManager:findOverlappingCoupler(coupling)
    -- Already connected — no new connection possible
    if coupling.isConnected then return nil end
    local apexA, arc1A, arc2A = self:_getCouplingArcNodes(coupling)
    if apexA == nil or not entityExists(apexA) then return nil end

    local apexAx, apexAy, apexAz = getWorldTranslation(apexA)

    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, vc in ipairs(vEntry.couplingEntries) do
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

    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc ~= coupling
                and (coupling.placeable == nil or sc.placeable ~= coupling.placeable)
                and not sc.isConnected
                and (not sc.deployable or sc.isDeployed) then
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
        print("[SPS] applyConnectCouplings: chain re-anchored from coupling id="
            .. tostring(oldAnchor and oldAnchor.id) .. " to id=" .. tostring(vehicleCoupling.id))
    end
    reAnchorIfNeeded(couplingA, couplingB)
    reAnchorIfNeeded(couplingB, couplingA)

    if g_spsPipeVisual ~= nil and g_spsPipeVisual:isReady() then
        local nodeA = couplingA.mountNode
        local nodeB = couplingB.mountNode
        if couplingA.isChainTerminus and couplingA.chain ~= nil and not couplingA.isChainStart then
            local segs = couplingA.chain.segments
            if #segs > 0 then nodeA = segs[#segs].endConnectors end
        elseif couplingB.isChainTerminus and couplingB.chain ~= nil and not couplingB.isChainStart then
            local segs = couplingB.chain.segments
            if #segs > 0 then nodeB = segs[#segs].endConnectors end
        elseif couplingB.isChainStart and couplingB.chain ~= nil then
            local segs = couplingB.chain.segments
            if #segs > 0 then nodeB = segs[1].pipeRoot end
        elseif couplingA.isChainStart and couplingA.chain ~= nil then
            local segs = couplingA.chain.segments
            if #segs > 0 then nodeA = segs[1].pipeRoot end
        end
        local startConnType = (couplingA.connectorType ~= nil) and couplingA.connectorType or "male"
        local endConnType   = (couplingB.connectorType ~= nil) and couplingB.connectorType or "female"
        local startFlip     = (couplingA.isChainTerminus == true) or (couplingA.placeable ~= nil)
        local endFlip       = (couplingB.isChainTerminus == true) or (couplingB.placeable ~= nil)
        print(string.format("[SPS] applyConnectCouplings: startFlip=%s endFlip=%s A.isChainTerminus=%s B.isChainTerminus=%s A.isChainStart=%s B.isChainStart=%s",
            tostring(startFlip), tostring(endFlip),
            tostring(couplingA.isChainTerminus), tostring(couplingB.isChainTerminus),
            tostring(couplingA.isChainStart),    tostring(couplingB.isChainStart)))
        local inst = g_spsPipeVisual:createPipe(nodeA, nodeB, startConnType, endConnType, endFlip, startFlip)
        if inst ~= nil then
            local pipeId = self._nextPipeId
            self._nextPipeId = self._nextPipeId + 1
            local cr = self.currentPipeColor.r
            local cg = self.currentPipeColor.g
            local cb = self.currentPipeColor.b
            g_spsPipeVisual:applyColor(inst, cr, cg, cb)
            -- Bez pipe end connector visibility:
            -- Chain start (detNode04) = female receiver -> connectorEnd shows female02 (child 0)
            -- Chain far end (terminus) = female -> bez meets it with male -> connectorEnd shows male02 (child 1)
            -- Chain start as connectorStart: show female01 (chain start is female)
            if couplingB.isChainStart and inst.endConnectors ~= nil then
                inst.connectorEndFlipped = true
                local femaleConn = getChildAt(inst.endConnectors, 0)
                local maleConn   = getChildAt(inst.endConnectors, 1)
                if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, true) end
                if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, false) end
            elseif couplingB.isChainTerminus and not couplingB.isChainStart and inst.endConnectors ~= nil then
                -- Chain far end is female — bez end connecting to it uses male02
                local femaleConn = getChildAt(inst.endConnectors, 0)
                local maleConn   = getChildAt(inst.endConnectors, 1)
                if femaleConn ~= nil and femaleConn ~= 0 then setVisibility(femaleConn, false) end
                if maleConn   ~= nil and maleConn   ~= 0 then setVisibility(maleConn, true) end
            elseif couplingA.isChainStart and inst.startConnectors ~= nil then
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
function SlurryPipeManager:update(dt)
	self._updateCount = (self._updateCount or 0) + 1
    if self._updateCount == 1 then print("[SPS] update() is running") end

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
 
    -- Slurry thickness: accumulate per placeable sourceEntry each game day.
    -- One full period (daysPerPeriod days) = +10% thickness.
    -- Only runs server-side, agitationEnabled must be true.
    if g_server ~= nil and self.agitationEnabled and g_currentMission ~= nil and g_currentMission.environment ~= nil then
        local env     = g_currentMission.environment
        local today   = env.currentMonotonicDay
        local dpp     = env.daysPerPeriod or 28
        if self._lastMonotonicDay == nil then
            self._lastMonotonicDay = today
        elseif today ~= self._lastMonotonicDay then
            self._lastMonotonicDay = today
            -- Increment each placeable sourceEntry's day counter
            for _, pEntry in ipairs(self.registeredPlaceables) do
                if pEntry.agitatorEnabled and pEntry.sourceEntry ~= nil and pEntry.sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                    local se = pEntry.sourceEntry
                    se.thicknessDayCount = (se.thicknessDayCount or 0) + 1
                    if se.thicknessDayCount >= dpp then
                        se.thicknessDayCount = 0
                        se.thickness = math.min(1.0, MathUtil.round((se.thickness or 0) + 0.1, 1))
                        SlurryDebug.log("[SPS Thickness] " .. tostring(pEntry.placeable.configFileName)
                            .. " thickness now " .. string.format("%.1f", (se.thickness or 0) * 100) .. "%")
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
    if g_server ~= nil and self.agitationEnabled then
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
                    if state.spreaderValveOpen then
                        state.spreaderValveOpen = false
                        SPSSpreaderValveEvent.sendEvent(vehicle, false)
                    end
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
 
    if g_server == nil then return end
 
    -- Drive placeable inlet effects per-coupling — only fires for couplings that have effects declared
    for _, pEntry in ipairs(self.registeredPlaceables) do
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
							shouldPlay = pumpOn and dirOk and tankerHasSlurry
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
                                        local pumpOn2
                                        if self:isVehicleSelfPowered(vehicle2) then
                                            pumpOn2 = vState2 ~= nil and vState2.pumpRunning == true
                                        else
                                            pumpOn2 = vehicle2.getIsTurnedOn ~= nil and vehicle2:getIsTurnedOn() or false
                                        end
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
                                        
                                        if pumpOn2 and valveOpen2 and dirOk2 and tankerHasSlurry2 then
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
        local isDischarge = state ~= nil and state.direction == SPS_DIRECTION_DISCHARGE or false
        local pumpOn      = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() or false
        local fillLevel   = vehicle.getFillUnitFillLevel ~= nil and vehicle:getFillUnitFillLevel(arm.fillUnitIndex) or 0
        local shouldPlay  = arm.isConnected and valveOpen and isDischarge and pumpOn and fillLevel > 0
        if shouldPlay then
            if not arm.effectPlaying then
                local effectFillType = vehicle:getFillUnitFillType(arm.fillUnitIndex)
                if effectFillType == nil or effectFillType == FillType.UNKNOWN then
                    effectFillType = FillType.LIQUIDMANURE
                end
                g_effectManager:setEffectTypeInfo(entry.pipeEffects, effectFillType)
                local pe = entry.pipeEffects[1]
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
                freeCapacity = dstEntry.storage:getFreeCapacity(fillType) or 0
            end
        end
        if freeCapacity <= 0 then return end
        local amount = math.min(session.baseLitersPerSecond * dt * 0.001, sourceLevel, freeCapacity)
        -- Apply thickness multiplier from source storage
        if srcEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            local mult = self:getFlowRateMultiplier(srcEntry)
            if mult <= 0 then
                if vehicle.isClient then
                    g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
                end
                return
            end
            amount = amount * mult
        end
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

    if isArmActive then
        -- Fill arm: requires both cab hydraulic valve open AND pump running
        if not state.valveOpen then
            return
        end
        if not pumpRunning then
            return
        end
        local rate = session.baseLitersPerSecond * dt * 0.001
        if state.direction == SPS_DIRECTION_FILL then
            local extSrc = self:resolveExternalSource(vehicle)
            if extSrc ~= nil then
                local mult = self:getFlowRateMultiplier(extSrc)
                if mult <= 0 then
                    if vehicle.isClient then
                        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
                    end
                    return
                end
                rate = rate * mult
            end
            self:transferFill(vehicle, session, rate, fillType)
        else
            self:transferDischarge(vehicle, session, rate, fillType)
        end
    else
        -- Pipe coupling: pump must be running for transfer.
        -- Check if the connected partner coupling restricts flow direction.
        -- Includes chain connections where the partner is reached via a terminus.
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
                            if partnerDir == "DISCHARGE" and state.direction == SPS_DIRECTION_FILL then
                                return
                            elseif partnerDir == "FILL" and state.direction == SPS_DIRECTION_DISCHARGE then
                                return
                            end
                        end
                    end
                end
                break
            end
        end

        if not pumpRunning then return end
        local rate = session.baseLitersPerSecond * dt * 0.001
        if state.direction == SPS_DIRECTION_FILL then
            local extSrc = self:resolveExternalSource(vehicle)
            if extSrc ~= nil then
                local mult = self:getFlowRateMultiplier(extSrc)
                if mult <= 0 then
                    if vehicle.isClient then
                        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsSlurryTooThick"), 2000)
                    end
                    return
                end
                rate = rate * mult
            end
            self:transferFill(vehicle, session, rate, fillType)
        else
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
function SlurryPipeManager:getFlowRateMultiplier(sourceEntry)
    if not self.agitationEnabled then return 1.0 end
    if sourceEntry == nil then return 1.0 end
    if sourceEntry.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return 1.0 end
    local t = sourceEntry.thickness or 0
    if t >= 0.9 then return 0.0 end
    -- Linear: each 10% thickness = 10% flow reduction, capped at 80%
    return math.max(0.0, 1.0 - math.min(t, 0.8))
end

-- Returns a warning level string for the given sourceEntry thickness.
-- "none", "thickening", "tooThick"
function SlurryPipeManager:getThicknessWarning(sourceEntry)
    if not self.agitationEnabled then return "none" end
    if sourceEntry == nil then return "none" end
    if sourceEntry.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return "none" end
    local t = sourceEntry.thickness or 0
    if t >= 0.9 then return "tooThick" end
    if t >= 0.8 then return "thickening" end
    return "none"
end

-- Called by SlurryAgitator spec each tick while actively stirring.
-- dtHours: game hours elapsed this tick (dt * 0.001 / 3600 * timeScale).
-- Reduces thickness by dtHours / hoursPerTenPercent where
-- hoursPerTenPercent = daysPerPeriod * 24 / 10 — matching the accumulation rate.
function SlurryPipeManager:applyAgitation(sourceEntry, dtHours)
    if not self.agitationEnabled then return end
    if sourceEntry == nil then return end
    if sourceEntry.type ~= SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then return end
    if (sourceEntry.thickness or 0) <= 0 then return end
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local dpp = (env ~= nil and env.daysPerPeriod or 28)
    local hoursPerTenPercent = dpp * 24 / 10
    local reduction = dtHours / hoursPerTenPercent
    sourceEntry.thickness = math.max(0.0, (sourceEntry.thickness or 0) - reduction)
    SlurryDebug.log("[SPS Agitation] thickness now " .. string.format("%.2f", (sourceEntry.thickness or 0) * 100) .. "%")
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

    local sourceLevel = 0
    if extSource.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or extSource.type == "FILL_UNIT_ONLY" then
        if extSource.vehicle ~= nil then
            sourceLevel = extSource.vehicle:getFillUnitFillLevel(extSource.fillUnitIndex) or 0
        end
    elseif extSource.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        if extSource.storage ~= nil then
            sourceLevel = extSource.storage:getFillLevel(fillType) or 0
        end
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
            freeCapacity = extDest.storage:getFreeCapacity(fillType) or 0
        end
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
                        print("[SPS] resolveVehicleSource FALLBACK FILL_UNIT_ONLY: " .. tostring(vehicle.configFileName))
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
                        if farCoupling ~= nil and farCoupling.connectedPartnerCoupling ~= nil then
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

    print("[SPS] resolveExternalSource: no source found for " .. tostring(vehicle.configFileName)
        .. " (no arm/coupling active with valve open)")
    return nil
end

function SlurryPipeManager:removeFromSource(sourceEntry, amount, fillType, farmVehicle)
    if sourceEntry == nil then return end
    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or sourceEntry.type == "FILL_UNIT_ONLY" then
        local srcVehicle = sourceEntry.vehicle
        if srcVehicle ~= nil and srcVehicle.addFillUnitFillLevel ~= nil then
            srcVehicle:addFillUnitFillLevel(srcVehicle:getOwnerFarmId(), sourceEntry.fillUnitIndex, -amount, fillType, ToolType.TRIGGER, nil)
        end
    elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        local storage = sourceEntry.storage
        if storage ~= nil then
            storage:setFillLevel(math.max(0, (storage:getFillLevel(fillType) or 0) - amount), fillType)
        end
    end
end

function SlurryPipeManager:addToSource(sourceEntry, amount, fillType, farmVehicle)
    if sourceEntry == nil then return end
    if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or sourceEntry.type == "FILL_UNIT_ONLY" then
        local destVehicle = sourceEntry.vehicle
        if destVehicle ~= nil and destVehicle.addFillUnitFillLevel ~= nil then
            destVehicle:addFillUnitFillLevel(destVehicle:getOwnerFarmId(), sourceEntry.fillUnitIndex, amount, fillType, ToolType.TRIGGER, nil)
        end
    elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
        local storage = sourceEntry.storage
        if storage ~= nil then
            local free  = storage:getFreeCapacity(fillType) or 0
            local toAdd = math.min(amount, free)
            if toAdd > 0 then storage:setFillLevel((storage:getFillLevel(fillType) or 0) + toAdd, fillType) end
        end
    end
end