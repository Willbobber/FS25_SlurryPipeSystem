-- SlurryPipeManager.lua
-- FS25_SlurryPipeSystem

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
print("[SPS] SlurryPipeManager.lua loading start")

SPS_DIRECTION_FILL      = 0
SPS_DIRECTION_DISCHARGE = 1

SPS_TIP_TYPE_OPEN_PIT        = "OPEN_PIT"
SPS_TIP_TYPE_RUBBER_BOOT     = "RUBBER_BOOT"
SPS_TIP_TYPE_RUBBER_BOOT_PIT = "RUBBER_BOOT_PIT"

SPS_VALVE_TYPE_HYDRAULIC = "HYDRAULIC"
SPS_VALVE_TYPE_MANUAL    = "MANUAL"
SPS_VALVE_TYPE_NONE      = "NONE"

SlurryPipeManager = {}
local SlurryPipeManager_mt = Class(SlurryPipeManager)

SlurryPipeManager.SOURCE_SEARCH_RADIUS      = 30.0
SlurryPipeManager.DEFAULT_LITERS_PER_SECOND = 1000

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
    local configDir   = modDirectory .. "configs/vehicleConfigs/"
    local level1      = Files.new(configDir)
    if level1 == nil then
        SlurryDebug.log("loadVehicleConfigs - could not open " .. configDir)
        return
    end
    for _, entry in pairs(level1.files) do
        if entry.isDirectory then
            local folderName  = entry.filename
            local xmlFilePath = configDir .. folderName .. "/fillPoints.xml"
            if fileExists(xmlFilePath) then
                self.vehicleConfigMap[folderName] = { xmlFilePath = xmlFilePath, folderName = folderName }
                SlurryDebug.log("SlurryPipeManager: found vehicle config for '" .. folderName .. "'")
            end
        end
    end
    SlurryDebug.log("SlurryPipeManager: loaded " .. tostring(table.size(self.vehicleConfigMap)) .. " vehicle configs")
end

function SlurryPipeManager:loadPlaceableConfigs(modDirectory)
    local configDir = modDirectory .. "configs/placeableConfigs/"
    local level1    = Files.new(configDir)
    if level1 == nil then
        SlurryDebug.log("loadPlaceableConfigs - could not open " .. configDir)
        return
    end
    for _, entry in pairs(level1.files) do
        if entry.isDirectory then
            local folderPath = configDir .. entry.filename .. "/"
            local directXml  = folderPath .. "fillPoints.xml"
            if fileExists(directXml) then
                -- Legacy / single-placeable folder: key = folder name (e.g. baseTank)
                local key = entry.filename
                self.placeableConfigMap[key] = { xmlFilePath = directXml, folderName = key }
                SlurryDebug.log("loadPlaceableConfigs: config '" .. key .. "'")
            else
                -- Mod-name folder containing per-placeable subfolders
                -- e.g. FS25_UKStyleBuilding/cowShedUK/fillPoints.xml -> key = "cowShedUK"
                local level2 = Files.new(folderPath)
                if level2 ~= nil then
                    for _, sub in pairs(level2.files) do
                        if sub.isDirectory then
                            local subXml = folderPath .. sub.filename .. "/fillPoints.xml"
                            if fileExists(subXml) then
                                local key = sub.filename
                                self.placeableConfigMap[key] = { xmlFilePath = subXml, folderName = key }
                                SlurryDebug.log("loadPlaceableConfigs: config '" .. key .. "' in " .. entry.filename)
                            end
                        end
                    end
                end
            end
        end
    end
    SlurryDebug.log("loadPlaceableConfigs: loaded " .. tostring(table.size(self.placeableConfigMap)) .. " placeable configs")
end

-- ---------------------------------------------------------------------------
-- Config matching
-- ---------------------------------------------------------------------------
function SlurryPipeManager:findVehicleConfigForVehicle(vehicle)
    if vehicle.configFileName == nil then return nil end
    local vehicleFile = vehicle.configFileName:match("([^/\\]+)%.xml$")
    if vehicleFile == nil then return nil end
    SlurryDebug.log("SlurryPipeManager:findVehicleConfigForVehicle searching for '" .. vehicleFile .. "'")
    for folderName, config in pairs(self.vehicleConfigMap) do
        if string.find(folderName:lower(), vehicleFile:lower(), 1, true)
        or string.find(vehicleFile:lower(), folderName:lower(), 1, true) then
            SlurryDebug.log("SlurryPipeManager:findVehicleConfigForVehicle matched '" .. folderName .. "'")
            return config
        end
    end
    SlurryDebug.log("SlurryPipeManager:findVehicleConfigForVehicle no match for '" .. vehicleFile .. "'")
    return nil
end

function SlurryPipeManager:findPlaceableConfigForPlaceable(placeable)
    if placeable.configFileName == nil then return nil end
    local placeableFile = placeable.configFileName:match("([^/]+)%.xml$")
    if placeableFile == nil then return nil end
    return self.placeableConfigMap[placeableFile]
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

    local xmlFile = XMLFile.load("spsVehiclePoints", config.xmlFilePath)
    if xmlFile == nil then
        SlurryDebug.log("registerVehicle - XML load failed: " .. tostring(config.xmlFilePath))
        return
    end

    local entry = {
        vehicle               = vehicle,
        config                = config,
        linkedNodes           = {},
        armEntries            = {},
        couplingEntries       = {},
        receiverEntries       = {},
        rubberBootPortEntries = {},
        pumpControlEntries    = {},
        litersPerSecond       = xmlFile:getFloat("slurryPipeSystem.flow#litersPerSecond", SlurryPipeManager.DEFAULT_LITERS_PER_SECOND),
        gravityDischarge      = xmlFile:getBool("slurryPipeSystem.flow#gravityDischarge", false),
        gravityFactor         = xmlFile:getFloat("slurryPipeSystem.flow#gravityFactor", 0.15),
        nodeTreeRoot          = nil,
        sourceEntry           = nil,
        state = {
            pumpRunning = false,
            valveOpen   = false,
            direction   = SPS_DIRECTION_FILL,
        },
    }

    -- Load nodeTree
    local nodeTreePath = xmlFile:getString("slurryPipeSystem.nodeTree#filename")
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
                        print("[SPS] container '" .. targetName .. "' childCount=" .. tostring(getNumOfChildren(container)) .. " liveParent=" .. tostring(liveParent))
                        if liveParent ~= nil then
                            local children = {}
                            for childIdx = 0, getNumOfChildren(container) - 1 do
                                table.insert(children, getChildAt(container, childIdx))
                            end
                            for _, spsNode in ipairs(children) do
                                link(liveParent, spsNode)
                                table.insert(entry.linkedNodes, spsNode)
                                print("[SPS] linked " .. getName(spsNode) .. " under " .. targetName)
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
        return nil
    end

    -- Fill arms
    local activeCylinderedIndex = nil
    if vehicle.configurations ~= nil and vehicle.configurations["cylindered"] ~= nil then
        activeCylinderedIndex = vehicle.configurations["cylindered"] - 1
    end

    local armIndex = 0
    while true do
        local armKey = string.format("slurryPipeSystem.fillArms.fillArm(%d)", armIndex)
        if not xmlFile:hasProperty(armKey) then break end

        local armId   = xmlFile:getInt(armKey .. "#id", armIndex + 1)
        local tipType = xmlFile:getString(armKey .. "#tipType", SPS_TIP_TYPE_OPEN_PIT)

        local cfgIndexStr = xmlFile:getString(armKey .. "#cylinderedConfigIndex")
        if cfgIndexStr ~= nil then
            local cfgIndex = tonumber(cfgIndexStr)
            if activeCylinderedIndex == nil or cfgIndex ~= activeCylinderedIndex then
                print("[SPS] fillArm id=" .. armId .. " skipped (cylinderedConfigIndex=" .. tostring(cfgIndex) .. " active=" .. tostring(activeCylinderedIndex) .. ")")
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
        print("[SPS] fillArm id=" .. armId .. " tipType=" .. tipType .. " registered on " .. tostring(vehicle.configFileName))
        armIndex = armIndex + 1
    end

    -- Pipe couplings (data loaded for future use; no connection logic active)
    local couplingIndex = 0
    while true do
        local cKey = string.format("slurryPipeSystem.pipeCouplings.pipeCoupling(%d)", couplingIndex)
        if not xmlFile:hasProperty(cKey) then break end
        local couplingId = xmlFile:getInt(cKey .. "#id", couplingIndex + 1)

        local cCfgIndexStr = xmlFile:getString(cKey .. "#cylinderedConfigIndex")
        if cCfgIndexStr ~= nil then
            local cfgIndex = tonumber(cCfgIndexStr)
            if activeCylinderedIndex == nil or cfgIndex ~= activeCylinderedIndex then
                print("[SPS] pipeCoupling id=" .. couplingId .. " skipped (cylinderedConfigIndex=" .. tostring(cfgIndex) .. " active=" .. tostring(activeCylinderedIndex) .. ")")
                couplingIndex = couplingIndex + 1
                continue
            end
        end

        local mountNode = findLinkedNode(xmlFile:getString(cKey .. "#mountNodeName"))
        if mountNode ~= nil then
            local couplingEntry = {
                id              = couplingId,
                mountNode       = mountNode,
                valveType       = xmlFile:getString(cKey .. "#valveType", SPS_VALVE_TYPE_MANUAL),
                maxPipeLength   = xmlFile:getFloat(cKey .. "#maxPipeLength", 6.0),
                fillUnitIndex   = xmlFile:getInt(cKey .. "#fillUnitIndex", 1),
                isConnected     = false,
                connectedTarget = nil,
            }
            table.insert(entry.couplingEntries, couplingEntry)
            print("[SPS] pipeCoupling id=" .. couplingId .. " registered on " .. tostring(vehicle.configFileName))
        else
            print("[SPS] pipeCoupling id=" .. tostring(couplingId) .. " mountNode not found, skipping")
        end
        couplingIndex = couplingIndex + 1
    end

    -- Rubber boot ports
    local rbpIndex = 0
    while true do
        local rbpKey = string.format("slurryPipeSystem.rubberBootPorts.rubberBootPort(%d)", rbpIndex)
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
            print("[SPS] rubberBootPort id=" .. rbpId .. " registered on " .. tostring(vehicle.configFileName))
        else
            print("[SPS] rubberBootPort id=" .. tostring(rbpId) .. " lowerNode or upperNode not found, skipping")
        end
        rbpIndex = rbpIndex + 1
    end

    -- Pump controls
    local pcIndex = 0
    while true do
        local pcKey = string.format("slurryPipeSystem.pumpControls.pumpControl(%d)", pcIndex)
        if not xmlFile:hasProperty(pcKey) then break end
        local pcId   = xmlFile:getInt(pcKey .. "#id", pcIndex + 1)
        local pcNode = findLinkedNode(xmlFile:getString(pcKey .. "#nodeName"))
        if pcNode ~= nil then
            table.insert(entry.pumpControlEntries, { id = pcId, node = pcNode, vehicle = vehicle })
            print("[SPS] pumpControl id=" .. pcId .. " registered on " .. tostring(vehicle.configFileName))
        else
            print("[SPS] pumpControl id=" .. tostring(pcId) .. " node not found, skipping")
        end
        pcIndex = pcIndex + 1
    end

    -- Disable the vanilla FillTrigger
    if vehicle.spec_fillTriggerVehicle ~= nil
    and vehicle.spec_fillTriggerVehicle.fillTrigger ~= nil then
        vehicle.spec_fillTriggerVehicle.fillTrigger.isEnabled = false
        print("[SPS] Disabled vanilla FillTrigger on " .. tostring(vehicle.configFileName))
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

    table.insert(self.registeredVehicles, entry)
    xmlFile:delete()
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
    local xmlFile = XMLFile.load("spsPlaceablePoints", config.xmlFilePath)
    if xmlFile == nil then return end

    -- Optional nodeTree: links SPS nodes onto the placeable hierarchy.
    local linkedNodes = {}
    local nodeTreePath = xmlFile:getString("slurryPipeSystem.nodeTree#filename")
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
                                link(liveParent, spsNode)
                                table.insert(linkedNodes, spsNode)
                                print("[SPS] registerPlaceable: linked " .. getName(spsNode) .. " under " .. targetName)
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

    local fillPlaneNode = xmlFile:getNode("slurryPipeSystem.fillPlane#node", nil, placeable.components, placeable.i3dMappings)
    local minY          = xmlFile:getFloat("slurryPipeSystem.fillPlane#minY", 0)
    local maxY          = xmlFile:getFloat("slurryPipeSystem.fillPlane#maxY", 1)
    local fillTypeName  = xmlFile:getString("slurryPipeSystem.fillPlane#fillType", "LIQUIDMANURE")
    print("[SPS] registerPlaceable: fillPlaneNode=" .. tostring(fillPlaneNode) .. " minY=" .. tostring(minY) .. " maxY=" .. tostring(maxY) .. " fillType=" .. tostring(fillTypeName))
    local fillType = g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or FillType.LIQUIDMANURE

    local sourceEntry = nil
    if fillPlaneNode ~= nil and (placeable.spec_silo ~= nil or placeable.spec_husbandry ~= nil or placeable.spec_siloExtension ~= nil) then
        sourceEntry = SlurryNodeUtil.buildStoragePlaneSource(placeable, fillPlaneNode, minY, maxY, fillType)
    end
    if sourceEntry ~= nil then
        table.insert(self.sourceEntries, sourceEntry)
    end

    -- Pipe couplings: mountNodeName (nodeTree) or node+offset (i3dMapping legacy)
    local storeCouplings = {}
    local couplingIndex  = 0
    while true do
        local cKey = string.format("slurryPipeSystem.pipeCouplings.pipeCoupling(%d)", couplingIndex)
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
            local sc = {
                id              = couplingId,
                mountNode       = mountNode,
                arcNode         = arcNode,
                valveType       = xmlFile:getString(cKey .. "#valveType", SPS_VALVE_TYPE_MANUAL),
                gravity         = xmlFile:getBool(cKey .. "#gravity", false),
                isConnected     = false,
                valveOpen       = false,
                connectedTarget = nil,
                connectedPartnerCoupling = nil,
                pipeId          = nil,
                sourceEntry     = sourceEntry,
                placeable       = placeable,
                deployable      = deployable,
                isDeployed      = not deployable,  -- non-deployable couplings are always "deployed"
            }
            -- Deployable couplings start hidden
            if deployable then
                setVisibility(sc.mountNode, false)
            end
            table.insert(storeCouplings, sc)
            local activatable = SPSPipeActivatable.new(nil, sc)
            sc.activatable = activatable
            g_currentMission.activatableObjectsSystem:addActivatable(activatable)
            local chainAct = SPSChainActivatable.new(nil, 0, sc)
            sc.chainActivatable = chainAct
            g_currentMission.activatableObjectsSystem:addActivatable(chainAct)
            print("[SPS] registerPlaceable: storeCoupling id=" .. couplingId
                .. " valveType=" .. tostring(sc.valveType)
                .. " gravity=" .. tostring(sc.gravity)
                .. " deployable=" .. tostring(sc.deployable) .. " registered")
        end
        couplingIndex = couplingIndex + 1
    end

    table.insert(self.registeredPlaceables, {
        placeable      = placeable,
        config         = config,
        sourceEntry    = sourceEntry,
        storeCouplings = storeCouplings,
        linkedNodes    = linkedNodes,
        pipeAnimNode   = xmlFile:getNode("slurryPipeSystem.pipeAnimNode#node", nil, placeable.components, placeable.i3dMappings),
        pipeAnimRX     = math.rad(xmlFile:getFloat("slurryPipeSystem.pipeAnimNode#rx", 0)),
        pipeAnimRY     = math.rad(xmlFile:getFloat("slurryPipeSystem.pipeAnimNode#ry", 0)),
        pipeAnimRZ     = math.rad(xmlFile:getFloat("slurryPipeSystem.pipeAnimNode#rz", 0)),
    })
    xmlFile:delete()
    SlurryDebug.log("registerPlaceable - registered " .. tostring(placeable.configFileName))
    self:tryResolvePendingConnections()
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
                    if sc.activatable ~= nil then sc.activatable:delete() end
                    if sc.chainActivatable ~= nil then sc.chainActivatable:delete() end
                end
            end
            if entry.linkedNodes ~= nil then
                for _, nodeId in ipairs(entry.linkedNodes) do
                    if nodeId ~= nil and nodeId ~= 0 then delete(nodeId) end
                end
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
                    idx = idx + 1
                    written = written + 1
                end
            end
        end
    end

    -- Save pipe chains
    for chainIdx, chain in ipairs(self.pipeChains) do
        local data = chain:getSaveData()
        local base = string.format("slurryPipeSystem.chains.chain(%d)", chainIdx - 1)
        xmlFile:setFloat(base .. "#anchorX",           data.anchorX)
        xmlFile:setFloat(base .. "#anchorY",           data.anchorY)
        xmlFile:setFloat(base .. "#anchorZ",           data.anchorZ)
        xmlFile:setBool(base  .. "#hasDockingStation", data.hasDockingStation)
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
            xmlFile:setFloat(segBase .. "#x",  segData.x)
            xmlFile:setFloat(segBase .. "#y",  segData.y)
            xmlFile:setFloat(segBase .. "#z",  segData.z)
            xmlFile:setFloat(segBase .. "#rx", segData.rx)
            xmlFile:setFloat(segBase .. "#ry", segData.ry)
            xmlFile:setFloat(segBase .. "#rz", segData.rz)
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
        }
        table.insert(self.pendingConnections, pending)
        idx = idx + 1
    end

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
            dsSaveX           = xmlFile:getFloat(base .. "#dsSaveX",  0),
            dsSaveY           = xmlFile:getFloat(base .. "#dsSaveY",  0),
            dsSaveZ           = xmlFile:getFloat(base .. "#dsSaveZ",  0),
            dsSaveRX          = xmlFile:getFloat(base .. "#dsSaveRX", 0),
            dsSaveRY          = xmlFile:getFloat(base .. "#dsSaveRY", 0),
            dsSaveRZ          = xmlFile:getFloat(base .. "#dsSaveRZ", 0),
            segments          = {},
        }
        local segIdx = 0
        while true do
            local segBase = string.format(base .. ".segment(%d)", segIdx)
            if not xmlFile:hasProperty(segBase) then break end
            table.insert(chainData.segments, {
                x  = xmlFile:getFloat(segBase .. "#x",  0),
                y  = xmlFile:getFloat(segBase .. "#y",  0),
                z  = xmlFile:getFloat(segBase .. "#z",  0),
                rx = xmlFile:getFloat(segBase .. "#rx", 0),
                ry = xmlFile:getFloat(segBase .. "#ry", 0),
                rz = xmlFile:getFloat(segBase .. "#rz", 0),
            })
            segIdx = segIdx + 1
        end
        table.insert(self.pendingChains, chainData)
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

    xmlFile:delete()
    print("[SPS] loadCouplingConnections: loaded " .. #self.pendingConnections
        .. " connections, " .. #self.pendingChains .. " chains, "
        .. #self.pendingDeployedCouplings .. " deployed couplings")
end

-- Called at the end of registerVehicle and registerPlaceable.
-- For each pending connection, checks if both mount nodes now exist.
-- Position match tolerance: 0.1m (positions stored as floats, no drift expected).
function SlurryPipeManager:tryResolvePendingConnections()
    if #self.pendingConnections == 0 then return end

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
        return nil, nil, nil
    end

    local resolved = {}
    for _, pending in ipairs(self.pendingConnections) do
        local cA, ownerAv, ownerAp = findCouplingAtPos(pending.ax, pending.ay, pending.az)
        local cB, ownerBv, ownerBp = findCouplingAtPos(pending.bx, pending.by, pending.bz)

        if cA ~= nil and cB ~= nil and not cA.isConnected and not cB.isConnected then
            local ownerA = ownerAv or ownerAp
            local ownerB = ownerBv or ownerBp
            self:applyConnectCouplings(cA, cB, ownerA, ownerB)
            if pending.valveOpen then
                self:applyValveState(ownerAv, cA.id, true)
            end
            print("[SPS] tryResolvePendingConnections: restored connection coupling "
                .. tostring(cA.id) .. " <-> " .. tostring(cB.id))
            table.insert(resolved, pending)
        end
    end

    for _, r in ipairs(resolved) do
        for i, p in ipairs(self.pendingConnections) do
            if p == r then table.remove(self.pendingConnections, i) break end
        end
    end

    -- Resolve pending chains — find anchor coupling by position then restore chain
    if #self.pendingChains > 0 then
        local resolvedChains = {}
        for _, chainData in ipairs(self.pendingChains) do
            local anchorCoupling = findCouplingAtPos(
                chainData.anchorX, chainData.anchorY, chainData.anchorZ)
            if anchorCoupling ~= nil then
                local chain = SPSPipeChain.new(anchorCoupling, self.modDirectory)
                chain:restoreFromSaveData(chainData)
                table.insert(self.pipeChains, chain)
                print("[SPS] tryResolvePendingConnections: restored chain with "
                    .. #chain.segments .. " segments")
                table.insert(resolvedChains, chainData)
            end
        end
        for _, r in ipairs(resolvedChains) do
            for i, p in ipairs(self.pendingChains) do
                if p == r then table.remove(self.pendingChains, i) break end
            end
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
                            print("[SPS] tryResolvePendingConnections: restored deployed coupling id=" .. sc.id)
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
                    -- On undeploy: reset anim node once so Giants animation can take back control
                    if not isDeployed and pEntry.pipeAnimNode ~= nil and pEntry.pipeAnimNode ~= 0 then
                        setRotation(pEntry.pipeAnimNode, 0, 0, 0)
                    end
                    print("[SPS] coupling id=" .. couplingId .. " deployed=" .. tostring(isDeployed))
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
        print("[SPS] onChainStartLaying: created new chain for coupling id=" .. tostring(coupling.id))
    end
    if anchorActivatable ~= nil then
        anchorActivatable.chain = chain
    end
    local mx, my, mz = getWorldTranslation(coupling.mountNode)
    -- Derive sry from actual world forward direction to handle compound node rotations correctly
    local fdx, _, fdz = localDirectionToWorld(coupling.mountNode, 0, 0, -1)
    local mry = math.atan2(-fdx, -fdz)
    chain:startLaying(mx, my, mz, mry)
end

-- Keep old name as alias for compatibility
function SlurryPipeManager:onChainLayPipe(coupling, anchorActivatable)
    self:onChainStartLaying(coupling, anchorActivatable)
end

-- Called by anchor SPSChainActivatable after all segments removed.
-- Removes the empty chain from the manager.
function SlurryPipeManager:onChainEmpty(chain, coupling)
    for i, c in ipairs(self.pipeChains) do
        if c == chain then
            chain:delete()
            table.remove(self.pipeChains, i)
            print("[SPS] onChainEmpty: removed empty chain for coupling id=" .. tostring(coupling ~= nil and coupling.id or "?"))
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

function SlurryPipeManager:isGravityDischarge(vehicle)
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then return entry.gravityDischarge == true end
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

function SlurryPipeManager:connectionIsFilLArm(vehicle)
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

function SlurryPipeManager:onArmConnected(vehicle, arm) end
function SlurryPipeManager:onArmDisconnected(vehicle, arm) self:stopFlow(vehicle) end

-- ---------------------------------------------------------------------------
-- Action handlers
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onActionToggleFlow(vehicle)
    local state = self:getVehicleState(vehicle)
    if state == nil then return end
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
    local flowId = vehicle.spsActionEvents.flowEventId
    if flowId ~= nil then
        g_inputBinding:setActionEventText(flowId, state.valveOpen and g_i18n:getText("action_slurryFlowClose") or g_i18n:getText("action_slurryFlowOpen"))
        g_inputBinding:setActionEventActive(flowId, true)
    end
    local dirId = vehicle.spsActionEvents.dirEventId
    if dirId ~= nil then
        g_inputBinding:setActionEventText(dirId, (state.direction == SPS_DIRECTION_FILL) and g_i18n:getText("action_slurryDirectionDischarge") or g_i18n:getText("action_slurryDirectionFill"))
        g_inputBinding:setActionEventActive(dirId, not state.valveOpen)
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
        print("[SPS] stopFlow: " .. tostring(vehicle.configFileName))
    end
end

function SlurryPipeManager:buildFlowSession(vehicle)
    local litersPerSecond = SlurryPipeManager.DEFAULT_LITERS_PER_SECOND
    local vehicleFillUnit = 1
    local gravityFactor   = 0.15
    for _, entry in ipairs(self.registeredVehicles) do
        if entry.vehicle == vehicle then
            litersPerSecond = entry.litersPerSecond
            gravityFactor   = entry.gravityFactor or 0.15
            if #entry.armEntries > 0 then
                vehicleFillUnit = entry.armEntries[1].fillUnitIndex
            elseif #entry.couplingEntries > 0 then
                vehicleFillUnit = entry.couplingEntries[1].fillUnitIndex
            end
            break
        end
    end
    return { vehicle = vehicle, vehicleFillUnit = vehicleFillUnit, baseLitersPerSecond = litersPerSecond, gravityFactor = gravityFactor }
end

-- ---------------------------------------------------------------------------
-- Arc overlap detection
-- Coupling node structure: mountNode -> child(0) = ArcsNode -> child(0) = Arc01, child(1) = Arc02
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_getCouplingArcNodes(coupling)
    -- Chain terminus: detNode01 IS the apex, its children are arc02/arc03
    if coupling.isChainTerminus then
        local apexNode = coupling.mountNode
        if apexNode == nil or apexNode == 0 then return nil, nil, nil end
        if getNumOfChildren(apexNode) < 2 then return nil, nil, nil end
        local arc1 = getChildAt(apexNode, 0)
        local arc2 = getChildAt(apexNode, 1)
        if arc1 == nil or arc1 == 0 or arc2 == nil or arc2 == 0 then return nil, nil, nil end
        return apexNode, arc1, arc2
    end
    local baseNode = coupling.arcNode or coupling.mountNode
    if baseNode == nil or baseNode == 0 then return nil, nil, nil end
    if getNumOfChildren(baseNode) == 0 then return nil, nil, nil end
    local arcsNode = getChildAt(baseNode, 0)
    if arcsNode == nil or arcsNode == 0 then return nil, nil, nil end
    if getNumOfChildren(arcsNode) < 2 then return nil, nil, nil end
    local arc1 = getChildAt(arcsNode, 0)
    local arc2 = getChildAt(arcsNode, 1)
    if arc1 == nil or arc1 == 0 or arc2 == nil or arc2 == 0 then return nil, nil, nil end
    return arcsNode, arc1, arc2
end

function SlurryPipeManager:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B)
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
    local apexA, arc1A, arc2A = self:_getCouplingArcNodes(coupling)
    if apexA == nil then return nil end

    for _, vEntry in ipairs(self.registeredVehicles) do
        for _, vc in ipairs(vEntry.couplingEntries) do
            if vc ~= coupling and not vc.isConnected then
                local apexB, arc1B, arc2B = self:_getCouplingArcNodes(vc)
                if apexB ~= nil then
                    if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                        return vc
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
                    if apexB ~= nil then
                        if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                            return sc
                        end
                    end
                end
            end
        end
    end

    -- Chain terminus arcs — laid pipe ends a vehicle can connect to
    for _, ct in ipairs(self.chainTerminusEntries) do
        if ct ~= coupling and not ct.isConnected then
            local apexB, arc1B, arc2B = self:_getCouplingArcNodes(ct)
            if apexB ~= nil then
                if self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then
                    return ct
                end
            end
        end
    end

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

    if g_spsPipeVisual ~= nil and g_spsPipeVisual:isReady() then
        local nodeA = couplingA.mountNode
        local nodeB = couplingB.mountNode
        if couplingA.isChainTerminus and couplingA.chain ~= nil then
            local segs = couplingA.chain.segments
            if #segs > 0 then nodeA = segs[#segs].endConnectors end
        elseif couplingB.isChainTerminus and couplingB.chain ~= nil then
            local segs = couplingB.chain.segments
            if #segs > 0 then nodeB = segs[#segs].endConnectors end
        end
        local inst = g_spsPipeVisual:createPipe(nodeA, nodeB)
        if inst ~= nil then
            local pipeId = self._nextPipeId
            self._nextPipeId = self._nextPipeId + 1
            self.activePipes[pipeId] = { inst = inst, couplingA = couplingA, couplingB = couplingB }
            couplingA.pipeId = pipeId
            couplingB.pipeId = pipeId
            print("[SPS] applyConnectCouplings: pipe visual created pipeId=" .. pipeId)
        else
            print("[SPS] applyConnectCouplings: WARNING pipe visual createPipe returned nil")
        end
    else
        print("[SPS] applyConnectCouplings: WARNING g_spsPipeVisual not ready, no visual created")
    end

    print("[SPS] applyConnectCouplings: connected coupling " .. tostring(couplingA.id) .. " <-> " .. tostring(couplingB.id)
        .. " ownerA=" .. tostring(ownerA ~= nil and (ownerA.configFileName or "placeable") or "nil")
        .. " ownerB=" .. tostring(ownerB ~= nil and (ownerB.configFileName or "placeable") or "nil")
        .. " pipeId=" .. tostring(couplingA.pipeId))
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

    print("[SPS] onCouplerDisconnect: coupling id=" .. tostring(coupling.id)
        .. " isConnected=" .. tostring(coupling.isConnected)
        .. " isServer=" .. tostring(g_server ~= nil))

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
    print("[SPS] applyDisconnect: coupling id=" .. tostring(couplingId)
        .. " pipeId=" .. tostring(coupling.pipeId)
        .. " partner=" .. tostring(partner ~= nil and partner.id or "nil")
        .. " valveOpen=" .. tostring(coupling.valveOpen))

    -- Destroy pipe visual
    if coupling.pipeId ~= nil then
        local pipeData = self.activePipes[coupling.pipeId]
        if pipeData ~= nil and g_spsPipeVisual ~= nil then
            g_spsPipeVisual:destroyPipe(pipeData.inst)
            self.activePipes[coupling.pipeId] = nil
            print("[SPS] applyDisconnect: pipe visual destroyed pipeId=" .. tostring(coupling.pipeId))
        else
            print("[SPS] applyDisconnect: WARNING pipeId=" .. tostring(coupling.pipeId) .. " had no pipeData in activePipes")
        end
        coupling.pipeId = nil
        if partner ~= nil then partner.pipeId = nil end
    else
        print("[SPS] applyDisconnect: WARNING coupling id=" .. tostring(couplingId) .. " had no pipeId - no visual to destroy")
    end

    -- Stop any active flow
    if coupling.connectedTarget ~= nil then
        self:stopFlow(vehicle)
    end

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
        print("[SPS] applyDisconnect: partner coupling id=" .. tostring(partner.id) .. " cleared")
    else
        print("[SPS] applyDisconnect: WARNING no partner found for coupling id=" .. tostring(couplingId))
    end

    print("[SPS] applyDisconnect: done, coupling id=" .. tostring(couplingId))
end

function SlurryPipeManager:onValveOpen(vehicle, coupling)
    if not coupling.isConnected then return end
    if coupling.valveOpen then return end

    if g_server == nil then
        SlurryValveStateEvent.sendEvent(vehicle, coupling.id, true)
        return
    end

    self:applyValveState(vehicle, coupling.id, true)
    SlurryValveStateEvent.sendEvent(vehicle, coupling.id, true)
end

function SlurryPipeManager:onValveClose(vehicle, coupling)
    if not coupling.isConnected then return end
    if not coupling.valveOpen then return end

    if g_server == nil then
        SlurryValveStateEvent.sendEvent(vehicle, coupling.id, false)
        return
    end

    self:applyValveState(vehicle, coupling.id, false)
    SlurryValveStateEvent.sendEvent(vehicle, coupling.id, false)
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

function SlurryPipeManager:applyValveState(vehicle, couplingId, isOpen)
    local coupling = self:_findCouplingById(vehicle, couplingId, false)
    if coupling == nil then
        -- Try placeable
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.storeCouplings ~= nil then
                for _, sc in ipairs(pEntry.storeCouplings) do
                    if sc.id == couplingId then coupling = sc break end
                end
            end
            if coupling ~= nil then break end
        end
    end
    if coupling == nil then return end

    coupling.valveOpen = isOpen

    -- Also sync the partner coupling valve so both ends agree
    local partner = coupling.connectedPartnerCoupling
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

    print("[SPS] applyValveState: coupling id=" .. tostring(couplingId) .. " valve=" .. tostring(isOpen))
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------
function SlurryPipeManager:update(dt)
    self._updateCount = (self._updateCount or 0) + 1
    if self._updateCount == 1 or self._updateCount % 300 == 0 then
        print("[SPS] update() tick #" .. self._updateCount .. " isServer=" .. tostring(g_server ~= nil) .. " sources=" .. #self.sourceEntries .. " vehicles=" .. #self.registeredVehicles)
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
                print("[SPS] detectArmConnection: arm blocked - coupling connected on " .. tostring(vehicle.configFileName))
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
    if supportsRubberBoot and arm.tipNode ~= nil then
        local tx, ty, tz   = getWorldTranslation(arm.tipNode)
        local XZ_TOLERANCE = 0.15
        for _, rbpEntry in ipairs(self.rubberBootPortEntries) do
            if rbpEntry.vehicle ~= vehicle and rbpEntry.lowerNode ~= nil and rbpEntry.upperNode ~= nil then
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

    -- Open pit detection
    local supportsOpenPit = (tipType == SPS_TIP_TYPE_OPEN_PIT) or (tipType == SPS_TIP_TYPE_RUBBER_BOOT_PIT)
    if supportsOpenPit and not newConnected and arm.centreNode ~= nil then
        local THRESHOLD   = 0.08
        local RADIUS_SQ   = SlurryPipeManager.SOURCE_SEARCH_RADIUS * SlurryPipeManager.SOURCE_SEARCH_RADIUS
        local centreX, centreY, centreZ = getWorldTranslation(arm.centreNode)

        for _, sourceEntry in ipairs(self.sourceEntries) do
            if sourceEntry.vehicle == vehicle then continue end

            -- XZ proximity: arm centre must be within SOURCE_SEARCH_RADIUS of the source
            local refX, refZ
            if sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                local nx, _, nz = getWorldTranslation(sourceEntry.fillPlaneNode)
                refX, refZ = nx, nz
            elseif sourceEntry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME then
                local nx, _, nz = getWorldTranslation(sourceEntry.baseNode)
                refX, refZ = nx, nz
            else
                continue
            end
            local dx = centreX - refX
            local dz = centreZ - refZ
            if dx * dx + dz * dz > RADIUS_SQ then continue end

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
        local shouldPlay  = arm.isConnected and valveOpen and isDischarge and pumpOn
        if shouldPlay then
            if not arm.effectPlaying then g_effectManager:startEffects(entry.pipeEffects) arm.effectPlaying = true end
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

    local pumpRunning     = vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() or false
    local isArmActive     = self:connectionIsFilLArm(vehicle)
    local hasCouplingFlow = self:hasActiveCouplingConnection(vehicle)

    if not isArmActive and not hasCouplingFlow then
        if not session._loggedNoConn then
            print("[SPS] tickFlow: no active connection (arm=" .. tostring(isArmActive) .. " coupling=" .. tostring(hasCouplingFlow) .. ") for " .. tostring(vehicle.configFileName))
            session._loggedNoConn = true
        end
        return
    end
    session._loggedNoConn = false

    local fillType = vehicle:getFillUnitFillType(session.vehicleFillUnit)
    if fillType == nil or fillType == FillType.UNKNOWN then fillType = FillType.LIQUIDMANURE end

    if isArmActive then
        -- Fill arm: requires both cab hydraulic valve open AND pump running
        if not state.valveOpen then
            if not session._loggedNoValve then
                print("[SPS] tickFlow: arm active but cab valve closed on " .. tostring(vehicle.configFileName))
                session._loggedNoValve = true
            end
            return
        end
        session._loggedNoValve = false
        if not pumpRunning then
            if not session._loggedNoPump then
                print("[SPS] tickFlow: arm active, valve open, but pump off on " .. tostring(vehicle.configFileName))
                session._loggedNoPump = true
            end
            return
        end
        session._loggedNoPump = false
        local rate = session.baseLitersPerSecond * dt * 0.001
        if state.direction == SPS_DIRECTION_FILL then
            self:transferFill(vehicle, session, rate, fillType)
        else
            self:transferDischarge(vehicle, session, rate, fillType)
        end
    else
        -- Pipe coupling: manual valve already confirmed open via hasCouplingFlow.
        -- Gravity flow: if connected partner coupling has gravity=true and pump is off,
        -- allow fill at reduced rate without requiring pump.
        local isGravity = false
        for _, entry in ipairs(self.registeredVehicles) do
            if entry.vehicle == vehicle then
                for _, c in ipairs(entry.couplingEntries) do
                    if c.isConnected and c.valveOpen and c.connectedPartnerCoupling ~= nil then
                        if c.connectedPartnerCoupling.gravity == true then
                            isGravity = true
                        end
                    end
                end
                break
            end
        end

        if not pumpRunning then
            if isGravity and state.direction == SPS_DIRECTION_FILL then
                local rate = session.baseLitersPerSecond * (session.gravityFactor or 0.15) * dt * 0.001
                self:transferFill(vehicle, session, rate, fillType)
            else
                if not session._loggedNoPump then
                    print("[SPS] tickFlow: coupling active but pump off on " .. tostring(vehicle.configFileName))
                    session._loggedNoPump = true
                end
            end
            return
        end
        session._loggedNoPump = false
        local rate = session.baseLitersPerSecond * dt * 0.001
        if state.direction == SPS_DIRECTION_FILL then
            self:transferFill(vehicle, session, rate, fillType)
        else
            self:transferDischarge(vehicle, session, rate, fillType)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Transfer functions
-- ---------------------------------------------------------------------------
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
                    print("[SPS] resolveVehicleSource OK: " .. tostring(vehicle.configFileName))
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

print("[SPS] SlurryPipeManager.lua loading complete")