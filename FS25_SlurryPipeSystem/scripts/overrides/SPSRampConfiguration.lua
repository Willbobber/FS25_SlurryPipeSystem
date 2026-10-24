-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSRampConfiguration.lua  -  [SPS 1.0.1.8] "Ramp: Yes / No" option in the build menu for slurry stores whose SPS
-- nodeTree carries a ramp (William 2026-10-22: "turn on or off the ramp on each store so I can place one with a ramp
-- and then without").
--
-- The stores are base-game / map placeables, so SPS cannot add a <...Configurations> block to their XML. Instead it
-- uses the game's own configuration system (decoded ConfigurationManager / ConfigurationUtil / ConstructionScreen):
--   * a placeable configuration type "spsRamp" is registered in an append to Placeable.init - mods are sourced before
--     that task runs (MPLoadingScreen:initializeLoading), and configuration types travel over the network by their
--     registration NUMBER, so every machine must register at the same point;
--   * its item class's static postLoad (called by ConfigurationUtil.getConfigurationsFromXML for every store item and
--     every type) gives Yes (default) / No items to the store items whose SPS config declares
--     <rampOption node="..."/> - the build menu then shows the row (ConstructionScreen:processStoreItemConfigurationSet);
--   * the choice is saved (name + saveId), loaded and synced by the game like any placeable configuration;
--   * after SPS links its nodeTree onto a placeable (registerPlaceable) or its build-menu preview (SPSM_Preview),
--     SPSRampConfiguration.apply deletes the named nodes when the choice is No (visual and collision go together).

SPSRampConfiguration = {}
SPSRampConfiguration.CONFIG_NAME = "spsRamp"
SPSRampConfiguration.MOD_DIR     = g_currentModDirectory
SPSRampConfiguration.SAVE_YES    = "ramp"
SPSRampConfiguration.SAVE_NO     = "noRamp"

-- ---------------------------------------------------------------------------
-- Which configs offer the option: manifest path (lower case) -> list of node names
-- ---------------------------------------------------------------------------
local function readRampNodes(xmlFile, key)
    local nodes = {}
    local i = 0
    while true do
        local k = string.format("%s.rampOption(%d)", key, i)
        if not xmlFile:hasProperty(k) then break end
        local name = xmlFile:getString(k .. "#node")
        if name ~= nil and name ~= "" then table.insert(nodes, name) end
        i = i + 1
    end
    return nodes
end

function SPSRampConfiguration.getManifestRamps()
    if SPSRampConfiguration._manifestRamps ~= nil then return SPSRampConfiguration._manifestRamps end
    local map = {}
    SPSRampConfiguration._manifestRamps = map
    local configRoot = SPSRampConfiguration.MOD_DIR .. "configs/"
    local manifest = XMLFile.loadIfExists("spsRampManifest", configRoot .. "spsConfigManifest.xml")
    if manifest == nil then return map end
    local idx = 0
    while true do
        local key = string.format("spsConfigManifest.placeableConfigs.placeable(%d)", idx)
        if not manifest:hasProperty(key) then break end
        local matchPath = manifest:getString(key .. "#path")
        if matchPath ~= nil and matchPath ~= "" then
            local cfgDir = manifest:getString(key .. "#configFolder")
            if cfgDir == nil or cfgDir == "" then cfgDir = matchPath:match("^(.*)/[^/]+%.xml$") end
            if cfgDir ~= nil then
                local fp = XMLFile.loadIfExists("spsRampFillPoints", configRoot .. cfgDir .. "/fillPoints.xml")
                if fp ~= nil then
                    local nodes = readRampNodes(fp, "slurryPipeSystem")
                    if #nodes > 0 then map[matchPath:lower():gsub("\\", "/")] = nodes end
                    fp:delete()
                end
            end
        end
        idx = idx + 1
    end
    manifest:delete()
    return map
end

-- ramp node names for a store item / placeable config file, or nil. Same path-tail rule as
-- SlurryPipeManager:findPlaceableConfigForPlaceable; an embedded <slurryPipeSystem> block is read from the item's XML.
function SPSRampConfiguration.getRampNodesForFile(configFileName, xmlFile)
    if configFileName == nil then return nil end
    if xmlFile ~= nil and xmlFile:hasProperty("placeable.slurryPipeSystem") then
        local nodes = readRampNodes(xmlFile, "placeable.slurryPipeSystem")
        return #nodes > 0 and nodes or nil
    end
    local cfn = configFileName:lower():gsub("\\", "/")
    for matchPath, nodes in pairs(SPSRampConfiguration.getManifestRamps()) do
        if cfn:sub(-#matchPath) == matchPath then return nodes end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Configuration item class (subclass of the vanilla placeable item, like PlaceableConfigurationItemColor)
-- ---------------------------------------------------------------------------
SPSRampConfigurationItem = {}
local SPSRampConfigurationItem_mt = Class(SPSRampConfigurationItem, PlaceableConfigurationItem)

function SPSRampConfigurationItem.new(configName, customMt)
    return PlaceableConfigurationItem.new(configName, customMt or SPSRampConfigurationItem_mt)
end

function SPSRampConfigurationItem.postLoad(xmlFile, baseKey, baseDir, customEnvironment, isMod, configurationItems, storeItem, configName)
    if storeItem ~= nil and #configurationItems == 0 then
        local nodes = SPSRampConfiguration.getRampNodesForFile(storeItem.xmlFilename, xmlFile)
        if nodes ~= nil then
            local yes = SPSRampConfigurationItem.new(SPSRampConfiguration.CONFIG_NAME)
            yes.name      = g_i18n:getText("configuration_valueYes")
            yes.isDefault = true
            yes.saveId    = SPSRampConfiguration.SAVE_YES
            yes:setIndex(1)
            local no = SPSRampConfigurationItem.new(SPSRampConfiguration.CONFIG_NAME)
            no.name   = g_i18n:getText("configuration_valueNo")
            no.saveId = SPSRampConfiguration.SAVE_NO
            no:setIndex(2)
            table.insert(configurationItems, yes)
            table.insert(configurationItems, no)
            storeItem.spsRampNodes = nodes
        end
    end
    PlaceableConfigurationItem.postLoad(xmlFile, baseKey, baseDir, customEnvironment, isMod, configurationItems, storeItem, configName)
end

-- ---------------------------------------------------------------------------
-- Registration (every mission load, same point on every machine)
-- ---------------------------------------------------------------------------
function SPSRampConfiguration.registerType()
    local mgr = g_placeableConfigurationManager
    if mgr == nil or mgr:getConfigurationDescByName(SPSRampConfiguration.CONFIG_NAME) ~= nil then return end
    SPSRampConfiguration._manifestRamps = nil   -- re-read: a new mission may run with an updated mod folder
    mgr:addConfigurationType(SPSRampConfiguration.CONFIG_NAME, g_i18n:getText("configuration_spsRamp"), nil, SPSRampConfigurationItem)
end

if Placeable ~= nil and Placeable.init ~= nil then
    Placeable.init = Utils.appendedFunction(Placeable.init, SPSRampConfiguration.registerType)
end

-- ---------------------------------------------------------------------------
-- Apply on a placeable (real one and the build-menu preview), after SPS linked its nodeTree
-- ---------------------------------------------------------------------------
local function collectByName(node, names, out)
    local name = getName(node)
    if names[name] then
        table.insert(out, node)
        return                                  -- the whole subtree goes with it
    end
    for i = 0, getNumOfChildren(node) - 1 do
        collectByName(getChildAt(node, i), names, out)
    end
end

function SPSRampConfiguration.isRampRemoved(placeable)
    local cfg = placeable ~= nil and placeable.configurations or nil
    local idx = cfg ~= nil and cfg[SPSRampConfiguration.CONFIG_NAME] or nil
    if idx == nil then return false end
    local item = g_storeManager ~= nil and g_storeManager:getItemByXMLFilename(placeable.configFileName) or nil
    local items = item ~= nil and item.configurations ~= nil and item.configurations[SPSRampConfiguration.CONFIG_NAME] or nil
    local entry = items ~= nil and items[idx] or nil
    return entry ~= nil and entry.saveId == SPSRampConfiguration.SAVE_NO
end

function SPSRampConfiguration.apply(placeable)
    if not SPSRampConfiguration.isRampRemoved(placeable) then return end
    local item = g_storeManager:getItemByXMLFilename(placeable.configFileName)
    local nodes = item ~= nil and item.spsRampNodes or nil
    if nodes == nil or placeable.components == nil then return end
    local names = {}
    for _, n in ipairs(nodes) do names[n] = true end
    local found = {}
    for _, comp in ipairs(placeable.components) do
        if comp.node ~= nil and comp.node ~= 0 then collectByName(comp.node, names, found) end
    end
    for _, node in ipairs(found) do
        delete(node)
    end
    if #found > 0 and SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SlurryPipeManager") then
        print(string.format("[SPS] ramp option: removed %d node(s) on %s", #found, tostring(placeable.configFileName)))
    end
end
