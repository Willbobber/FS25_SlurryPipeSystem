-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSM_Preview.lua — SlurryPipeManager domain module: CONSTRUCTION PREVIEW visuals.
--
-- [SPS 1.0.1.8] The build-menu preview of a placeable is a separate Placeable
-- loaded with propertyState CONSTRUCTION_PREVIEW and thrown away when the player
-- confirms; the real building is loaded afresh and only THAT one reaches
-- finalizePlacement, where SPS registers it. So the preview always showed the base
-- parts (fillmaster, fence) and no SPS couplers — the SPS version only appeared
-- after placing (William, 2026-09-29).
--
-- This module applies the VISUAL half of registration to a preview: link every
-- configured nodeTree (slurry, sprayer, liquid lanes) onto the preview's
-- hierarchy and hide the <hideNodes>. Nothing is registered, no storage is
-- touched, no activatable is created, collisions are left alone (the preview's
-- own collision drives the placement overlap test). The linked nodes die with the
-- preview object.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSM_Preview 1.0.1.8 loaded") end

local function pvLog(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("SPSM_Preview") then return end
    if select("#", ...) > 0 then
        print("[SPS PREVIEW] " .. string.format(fmt, ...))
    else
        print("[SPS PREVIEW] " .. tostring(fmt))
    end
end

local function findByName(root, name)
    if root == nil or root == 0 or not entityExists(root) then return nil end
    if getName(root) == name then return root end
    for i = 0, getNumOfChildren(root) - 1 do
        local found = findByName(getChildAt(root, i), name)
        if found ~= nil then return found end
    end
    return nil
end

local function findAllInTree(root, name, results)
    if root == nil or root == 0 or not entityExists(root) then return end
    if getName(root) == name then table.insert(results, root) end
    for i = 0, getNumOfChildren(root) - 1 do
        findAllInTree(getChildAt(root, i), name, results)
    end
end

-- Same link rule as every register function: nodeTree root > group > container
-- named after a live node; the container's children are re-linked under it.
local function linkNodeTree(placeable, xmlFilePath, nodeTreePath)
    if nodeTreePath == nil or nodeTreePath == "" then return 0 end
    local configFolder = xmlFilePath:match("^(.*[/\\])")
    if configFolder == nil then return 0 end
    local nodeTreeRoot = loadI3DFile(configFolder .. nodeTreePath)
    if nodeTreeRoot == nil or nodeTreeRoot == 0 then return 0 end
    local linked = 0
    local spsRoot = getChildAt(nodeTreeRoot, 0)
    if spsRoot ~= nil and spsRoot ~= 0 and placeable.components ~= nil then
        for groupIdx = 0, getNumOfChildren(spsRoot) - 1 do
            local group = getChildAt(spsRoot, groupIdx)
            for containerIdx = 0, getNumOfChildren(group) - 1 do
                local container  = getChildAt(group, containerIdx)
                local targetName = getName(container)
                local liveParent = nil
                for _, comp in ipairs(placeable.components) do
                    liveParent = findByName(comp.node, targetName)
                    if liveParent ~= nil then break end
                end
                if liveParent ~= nil then
                    local children = {}
                    for childIdx = 0, getNumOfChildren(container) - 1 do
                        table.insert(children, getChildAt(container, childIdx))
                    end
                    for _, spsNode in ipairs(children) do
                        -- preview: visual only, keep it out of physics
                        removeFromPhysics(spsNode)
                        link(liveParent, spsNode)
                        linked = linked + 1
                    end
                end
            end
        end
    end
    delete(nodeTreeRoot)
    return linked
end

-- Opens the config the finder resolved. Embedded configs open the placeable's own
-- XML by path (its xmlFile handle may be gone by onFinishedLoading).
local function openConfig(config, placeable)
    if config == nil then return nil, nil end
    if config.isEmbedded then
        return XMLFile.loadIfExists("spsPreviewCfg", placeable.configFileName, nil), placeable.configFileName
    end
    return XMLFile.loadIfExists("spsPreviewCfg", config.xmlFilePath, nil), config.xmlFilePath
end

function SlurryPipeManager:applyPlaceablePreviewVisuals(placeable)
    if placeable == nil or placeable.configFileName == nil or placeable.components == nil then return end
    local label  = tostring(placeable.configFileName)
    local linked = 0
    local hidden = 0

    -- 1. Slurry lane: nodeTree + hideNodes
    if self.findPlaceableConfigForPlaceable ~= nil then
        local cfg = self:findPlaceableConfigForPlaceable(placeable)
        if cfg ~= nil then
            local xmlFile, xmlPath = openConfig(cfg, placeable)
            if xmlFile ~= nil then
                local kp = (cfg.xmlKeyPrefix or "") .. "slurryPipeSystem."
                linked = linked + linkNodeTree(placeable, xmlPath, xmlFile:getString(kp .. "nodeTree#filename"))
                -- [SPS 1.0.1.8] "Ramp: No" chosen in the build menu: the preview drops the ramp too
                if SPSRampConfiguration ~= nil then SPSRampConfiguration.apply(placeable) end
                local idx = 0
                while true do
                    local hKey = string.format(kp .. "hideNodes.node(%d)", idx)
                    if not xmlFile:hasProperty(hKey) then break end
                    local nodeName = xmlFile:getString(hKey .. "#name")
                    if nodeName ~= nil and nodeName ~= "" then
                        for _, comp in ipairs(placeable.components) do
                            local matches = {}
                            findAllInTree(comp.node, nodeName, matches)
                            for _, n in ipairs(matches) do setVisibility(n, false); hidden = hidden + 1 end
                        end
                    end
                    idx = idx + 1
                end
                xmlFile:delete()
            end
        end
    end

    -- 2. Sprayer lane: nodeTree
    if self.findSprayerPlaceableConfigForPlaceable ~= nil then
        local cfg = self:findSprayerPlaceableConfigForPlaceable(placeable)
        if cfg ~= nil then
            local xmlFile, xmlPath = openConfig(cfg, placeable)
            if xmlFile ~= nil then
                local kp = (cfg.xmlKeyPrefix or "") .. "sprayerPipeSystem."
                linked = linked + linkNodeTree(placeable, xmlPath, xmlFile:getString(kp .. "nodeTree#filename"))
                xmlFile:delete()
            end
        end
    end

    -- 3. Liquid lanes (water / milk): each lane block may carry its own nodeTree
    if self.findLiquidLanePlaceableConfigForPlaceable ~= nil and SPS_LIQUID_LANES ~= nil then
        local cfg = self:findLiquidLanePlaceableConfigForPlaceable(placeable)
        if cfg ~= nil then
            local xmlFile, xmlPath = openConfig(cfg, placeable)
            if xmlFile ~= nil then
                local prefixes = cfg.prefixes or (cfg.xmlKeyPrefix and { cfg.xmlKeyPrefix }) or { "slurryPipeSystem.", "" }
                for _, k in ipairs(SPS_LL_LANE_ORDER or {}) do
                    local lane = SPS_LIQUID_LANES[k]
                    if lane ~= nil and lane.xmlRoot ~= nil then
                        for _, pre in ipairs(prefixes) do
                            if xmlFile:hasProperty(pre .. lane.xmlRoot) then
                                linked = linked + linkNodeTree(placeable, xmlPath, xmlFile:getString(pre .. lane.xmlRoot .. ".nodeTree#filename"))
                                break
                            end
                        end
                    end
                end
                xmlFile:delete()
            end
        end
    end

    if linked > 0 or hidden > 0 then
        pvLog("preview dressed: %s — %d SPS node(s) linked, %d base node(s) hidden", label, linked, hidden)
    end
end
