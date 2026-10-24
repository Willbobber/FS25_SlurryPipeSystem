-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSM_LiquidLanes.lua — SlurryPipeManager domain module: FARM LIQUID LANES
-- (animal drinking WATER into a barn, MILK out of a barn).
--
-- [SPS 1.0.1.8] A third pipe system next to slurry and sprayers, fully separate
-- from both. It borrows the sprayer lane's hose asset (a second
-- SPSSprayerPipeVisual instance, g_spsLiquidLanePipeVisual), the arc test and the
-- connector animator — nothing else. Own XML blocks, own registries, own matching,
-- own events, own control node. A sprayer coupler can never match a barn's water
-- or milk coupler because matching only ever scans registeredLiquidLanePlaceables.
--
-- Shape (William 2026-09-28):
--   BARN side   — one coupler PER LANE, each in its own block:
--                 <animalWaterSystem><waterPipeCouplings>…   (WATER, vehicle -> barn)
--                 <milkPipeSystem><milkPipeCouplings>…       (MILK,  barn -> vehicle)
--                 (the slurry coupler stays in <slurryPipeSystem> as before)
--   VEHICLE side — ONE generic connector, <liquidPipeSystem><liquidPipeCouplings>…,
--                 which connects to whichever coupler it is parked at. The far
--                 coupler's lane decides what flows and which way. The connector
--                 serves every lane whose liquid its fill unit accepts (an MKS 8
--                 tank takes WATER, MILK, fertiliser and herbicide, so all three),
--                 narrowable with lanes="WATER MILK".
--   SPRAYER lane — the connector may also meet the SPRAYER lane's sources (sprayer
--                 silos, IBC tanks, phyto buying stations). That lane is a BRIDGE:
--                 on connect the vehicle gets a temporary sprayer-vehicle entry
--                 (flagged isLiquidLaneBridge) and the existing sprayer code runs
--                 the connection — load/unload, compartments, ANY tanks, buying
--                 station pricing, its own MP events — exactly as for a sprayer.
--                 Real sprayers are untouched: they never get a liquid connector.
--   Held-liquid gate: a tank holding milk only sees MILK couplers, water only
--                 WATER couplers, fert/herb only SPRAYER couplers, empty sees all.
--
-- Water/slurry split: water through a SLURRY coupler still dilutes the pit
-- (SPSM_Consistency.resolveStoreDepositFillType, unchanged). Water through the
-- WATER lane is credited to the husbandry's WATER level only, through the
-- vanilla unloading-station path, so the slurry model never sees it. Milk is
-- drawn through the vanilla loading-station path, the same one the milk load
-- trigger uses, so vanilla bookkeeping stays right.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSM_LiquidLanes 1.0.1.8 loaded") end

SPS_LL_TAG = "[SPS LL]"

-- Lane descriptors. Everything type- and direction-specific lives here.
SPS_LIQUID_LANES = {
    WATER = {
        key           = "WATER",
        id            = 1,                 -- wire id (UIntN 2)
        xmlRoot       = "animalWaterSystem",
        couplingsKey  = "waterPipeCouplings.waterPipeCoupling",
        direction     = "TO_BARN",
        fillTypeNames = { "WATER" },
        titleKey      = "sps_laneWater",
        flowOnKey     = "action_spsWaterFlowOn",
        flowOffKey    = "action_spsWaterFlowOff",
    },
    MILK = {
        key           = "MILK",
        id            = 2,
        xmlRoot       = "milkPipeSystem",
        couplingsKey  = "milkPipeCouplings.milkPipeCoupling",
        direction     = "FROM_BARN",
        fillTypeNames = { "MILK", "BUFFALOMILK" },
        titleKey      = "sps_laneMilk",
        flowOnKey     = "action_spsMilkFlowOn",
        flowOffKey    = "action_spsMilkFlowOff",
    },
    -- Bridge lane: no barn block, its couplers are the sprayer lane's placeable
    -- side (registeredSprayerPlaceables). Liquid set = the game's "sprayer"
    -- fill-type category (LIQUIDFERTILIZER, HERBICIDE, plus script-mod liquids
    -- such as Soil & Fertilizer's) — WATER / MILK never count as sprayer liquids.
    SPRAYER = {
        key           = "SPRAYER",
        id            = 3,
        xmlRoot       = nil,
        couplingsKey  = nil,
        direction     = "BOTH",
        fillTypeNames = { "LIQUIDFERTILIZER", "HERBICIDE" },
        categoryNames = { "sprayer" },
        excludeNames  = { "WATER", "MILK", "BUFFALOMILK" },
        titleKey      = "sps_laneSprayer",
        bridge        = true,
    },
    -- [SPS 1.0.1.8] TRANSFER (William 2026-10-17): tanker to tanker, PHYSICAL pipes only - both ends are
    -- vehicle liquid connectors joined by a bought pipe (SPSM_PhysPipes _physEvaluateChain). No XML block, no
    -- barn. The tanker whose control node you use is the pump (B); Y picks Load (into it) / Unload (out of it).
    -- Liquid set = water and milk; the tanks decide what they take (_llEvaluateTransfer).
    TRANSFER = {
        key           = "TRANSFER",
        id            = 4,
        xmlRoot       = nil,
        couplingsKey  = nil,
        direction     = "TRANSFER",
        fillTypeNames = { "WATER", "MILK", "BUFFALOMILK" },
        titleKey      = "sps_laneTransfer",
        transfer      = true,
    },
}
SPS_LL_LANE_ORDER = { "WATER", "MILK", "SPRAYER", "TRANSFER" }

-- Vehicle-side block (one generic connector)
SPS_LL_VEHICLE_ROOT         = "liquidPipeSystem"
SPS_LL_VEHICLE_COUPLINGS    = "liquidPipeCouplings.liquidPipeCoupling"
SPS_LL_VEHICLE_CONTROLS     = "liquidPumpControls.liquidPumpControl"
-- Where the blocks live (William 2026-09-28: "the normal fashion"). A config file has
-- ONE root, and every bundled SPS config's root is <slurryPipeSystem>, so:
--   bundled placeable/vehicle : the lane blocks are CHILDREN of <slurryPipeSystem>
--                               in the SAME fillPoints.xml the slurry lane uses, and
--                               their nodes live in the SAME nodeTree.i3d (the slurry
--                               lane links it first; we find the nodes by name).
--                               A placeable/vehicle with no slurry side (small barns,
--                               MKS trailers) gets its own fillPoints.xml with that
--                               same root, listed under liquidPlaceableConfigs /
--                               liquidVehicleConfigs. A vehicle-only file may also
--                               use <liquidPipeSystem> as its root.
--   embedded                  : blocks directly under <placeable> / <vehicle>, or
--                               inside that XML's own <slurryPipeSystem>.
-- Every prefix in this list is tried, first hit wins.
SPS_LL_BUNDLED_PREFIXES  = { "slurryPipeSystem.", "" }
SPS_LL_EMBEDDED_PREFIXES = { "placeable.", "placeable.slurryPipeSystem." }
SPS_LL_EMBEDDED_VEHICLE_PREFIXES = { "vehicle.", "vehicle.slurryPipeSystem." }

local function llLog(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("SPSM_LiquidLanes") then return end
    if select("#", ...) > 0 then
        print(SPS_LL_TAG .. " " .. string.format(fmt, ...))
    else
        print(SPS_LL_TAG .. " " .. tostring(fmt))
    end
end

local function llLaneById(id)
    for _, k in ipairs(SPS_LL_LANE_ORDER) do
        if SPS_LIQUID_LANES[k].id == id then return SPS_LIQUID_LANES[k] end
    end
    return nil
end

-- Resolved fill-type indices per lane (lazy; FillType names exist after fill types load)
local function llLaneFillTypes(lane)
    if lane._fillTypes == nil then
        local seen, list = {}, {}
        local excluded = {}
        for _, name in ipairs(lane.excludeNames or {}) do
            local ft = g_fillTypeManager:getFillTypeIndexByName(name)
            if ft ~= nil then excluded[ft] = true end
        end
        local function add(ft)
            if ft ~= nil and not seen[ft] and not excluded[ft] then
                seen[ft] = true
                table.insert(list, ft)
            end
        end
        for _, name in ipairs(lane.fillTypeNames or {}) do
            add(g_fillTypeManager:getFillTypeIndexByName(name))
        end
        for _, cat in ipairs(lane.categoryNames or {}) do
            local ok, catList = pcall(function()
                return g_fillTypeManager:getFillTypesByCategoryNames(cat, "Warning: [SPS LL] unknown fillTypeCategory '%s'")
            end)
            if ok and type(catList) == "table" then
                for _, ft in ipairs(catList) do add(ft) end
            end
        end
        lane._fillTypes = list
    end
    return lane._fillTypes
end

-- true when the lane's liquid set contains heldFt (nil heldFt = empty tank = always ok)
local function llLaneAcceptsHeld(lane, heldFt)
    if heldFt == nil or heldFt == FillType.UNKNOWN then return true end
    for _, ft in ipairs(llLaneFillTypes(lane)) do
        if ft == heldFt then return true end
    end
    return false
end

local function llLaneTitle(lane)
    if lane == nil then return "" end
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(lane.titleKey) then
        return g_i18n:getText(lane.titleKey)
    end
    return lane.key
end

function SlurryPipeManager:getLiquidLane(key)
    return SPS_LIQUID_LANES[key]
end

function SlurryPipeManager:getLiquidLaneTitle(lane)
    return llLaneTitle(lane)
end

-- ---------------------------------------------------------------------------
-- Tables (created in SlurryPipeManager.new; ensured here for safety)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_llEnsureTables()
    self.registeredLiquidLaneVehicles   = self.registeredLiquidLaneVehicles   or {}
    self.registeredLiquidLanePlaceables = self.registeredLiquidLanePlaceables or {}
    self.activeLiquidLanePipes          = self.activeLiquidLanePipes          or {}
    self._nextLiquidLanePipeId          = self._nextLiquidLanePipeId          or 1
    self.liquidLaneVehicleConfigMap     = self.liquidLaneVehicleConfigMap     or {}
    self.liquidLanePlaceableConfigMap   = self.liquidLanePlaceableConfigMap   or {}
    self._pendingLiquidLaneConnects     = self._pendingLiquidLaneConnects     or {}
end

-- ---------------------------------------------------------------------------
-- Config maps (manifest) — same shape as the sprayer manifest sections
-- ---------------------------------------------------------------------------
local function llLoadConfigMap(modDirectory, manifestKey, map, label)
    local configRoot   = modDirectory .. "configs/"
    local manifestPath = modDirectory .. "configs/spsConfigManifest.xml"
    local xmlFile = XMLFile.load("spsManifestLL", manifestPath)
    if xmlFile == nil then return end
    local idx = 0
    while true do
        local key = string.format(manifestKey .. "(%d)", idx)
        if not xmlFile:hasProperty(key) then break end
        local matchPath = xmlFile:getString(key .. "#path")
        if matchPath ~= nil and matchPath ~= "" then
            local cfgDir = xmlFile:getString(key .. "#configFolder")
            if cfgDir == nil or cfgDir == "" then
                cfgDir = matchPath:match("^(.*)/[^/]+%.xml$")
            end
            if cfgDir ~= nil then
                local xmlFilePath = configRoot .. cfgDir .. "/fillPoints.xml"
                if fileExists(xmlFilePath) then
                    map[matchPath:lower()] = { xmlFilePath = xmlFilePath, matchPath = matchPath }
                else
                    print(string.format("%s WARNING: %s manifest entry '%s' points at a missing file %s — skipped",
                        SPS_LL_TAG, label, tostring(matchPath), tostring(xmlFilePath)))
                end
            end
        end
        idx = idx + 1
    end
    xmlFile:delete()
end

function SlurryPipeManager:loadLiquidLaneVehicleConfigs(modDirectory)
    self:_llEnsureTables()
    llLoadConfigMap(modDirectory, "spsConfigManifest.liquidVehicleConfigs.vehicle", self.liquidLaneVehicleConfigMap, "vehicle")
end

function SlurryPipeManager:loadLiquidLanePlaceableConfigs(modDirectory)
    self:_llEnsureTables()
    llLoadConfigMap(modDirectory, "spsConfigManifest.liquidPlaceableConfigs.placeable", self.liquidLanePlaceableConfigMap, "placeable")
end

-- ---------------------------------------------------------------------------
-- Config finders. Embedded wins, else manifest suffix match. Vehicle finder is
-- cached per configFileName and never captures mission vehicles.
-- ---------------------------------------------------------------------------
local function llSuffixMatch(configFileName, map)
    local cfn = configFileName:lower():gsub("\\", "/")
    for matchPathLower, config in pairs(map) do
        if cfn:sub(-#matchPathLower) == matchPathLower then return config end
    end
    return nil
end

function SlurryPipeManager:findLiquidLaneVehicleConfigForVehicle(vehicle)
    self:_llEnsureTables()
    if vehicle == nil or vehicle.configFileName == nil then return nil end
    if VehiclePropertyState ~= nil and vehicle.propertyState == VehiclePropertyState.MISSION then
        return nil
    end
    self._llVehicleCfgCache = self._llVehicleCfgCache or {}
    local hit = self._llVehicleCfgCache[vehicle.configFileName]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    local config = nil
    local embeddedXml = XMLFile.loadIfExists("spsEmbeddedLLVehicleCheck", vehicle.configFileName, nil)
    if embeddedXml ~= nil then
        for _, pre in ipairs(SPS_LL_EMBEDDED_VEHICLE_PREFIXES) do
            if embeddedXml:hasProperty(pre .. SPS_LL_VEHICLE_ROOT) then
                config = { xmlFilePath = vehicle.configFileName, xmlKeyPrefix = pre, isEmbedded = true }
                break
            end
        end
        -- Wrong-tag help: the barn blocks, or a tag that does not exist, on a VEHICLE
        -- would otherwise fail silently (William 2026-09-28: "what if a player adds a
        -- waterPipeSystem tag to a slurry tanker?").
        if config == nil then
            for _, pre in ipairs(SPS_LL_EMBEDDED_VEHICLE_PREFIXES) do
                for _, wrong in ipairs({ "waterPipeSystem", "milkPipeSystem", "animalWaterSystem" }) do
                    if embeddedXml:hasProperty(pre .. wrong) then
                        print(string.format("%s WARNING: %s has <%s> under <%s> — that is not a vehicle block. A vehicle gets ONE <%s> block (lanes come from its fill unit). See SPS_README_05_Animal_Water.md",
                            SPS_LL_TAG, tostring(vehicle.configFileName), wrong, pre:sub(1, -2), SPS_LL_VEHICLE_ROOT))
                    end
                end
            end
        end
        embeddedXml:delete()
    end
    -- Own manifest section (vehicles with no slurry side, e.g. the MKS trailers)
    if config == nil then
        local own = llSuffixMatch(vehicle.configFileName, self.liquidLaneVehicleConfigMap)
        if own ~= nil then
            config = { xmlFilePath = own.xmlFilePath, xmlKeyPrefix = nil, isEmbedded = false, prefixes = SPS_LL_BUNDLED_PREFIXES }
        end
    end
    -- The slurry lane's own bundled config for this vehicle: a <liquidPipeSystem>
    -- child of its <slurryPipeSystem> root needs no manifest entry of its own.
    if config == nil and self.findVehicleConfigForVehicle ~= nil then
        local slurryCfg = self:findVehicleConfigForVehicle(vehicle)
        if slurryCfg ~= nil and not slurryCfg.isEmbedded and slurryCfg.xmlFilePath ~= nil then
            local xf = XMLFile.loadIfExists("spsLLSlurryVehicleCfgCheck", slurryCfg.xmlFilePath, nil)
            if xf ~= nil then
                if xf:hasProperty("slurryPipeSystem." .. SPS_LL_VEHICLE_ROOT) then
                    config = { xmlFilePath = slurryCfg.xmlFilePath, xmlKeyPrefix = "slurryPipeSystem.", isEmbedded = false }
                end
                xf:delete()
            end
        end
    end
    self._llVehicleCfgCache[vehicle.configFileName] = config or false
    return config
end

-- Returns config, or nil. A placeable is a candidate if ANY lane block is present.
-- Does this xml hold any lane block under any of the prefixes? Returns true/false.
local function llXmlHasAnyLane(xmlFile, prefixes)
    for _, pre in ipairs(prefixes) do
        for _, k in ipairs(SPS_LL_LANE_ORDER) do
            local root = SPS_LIQUID_LANES[k].xmlRoot
            if root ~= nil and xmlFile:hasProperty(pre .. root) then return true end
        end
    end
    return false
end

function SlurryPipeManager:findLiquidLanePlaceableConfigForPlaceable(placeable)
    self:_llEnsureTables()
    if placeable == nil or placeable.configFileName == nil then return nil end
    -- 1. Embedded: blocks under <placeable> or inside its <slurryPipeSystem>
    local embeddedXml = XMLFile.loadIfExists("spsEmbeddedLLPlaceableCheck", placeable.configFileName, nil)
    if embeddedXml ~= nil then
        local any = llXmlHasAnyLane(embeddedXml, SPS_LL_EMBEDDED_PREFIXES)
        if not any then
            for _, pre in ipairs(SPS_LL_EMBEDDED_PREFIXES) do
                for _, wrong in ipairs({ SPS_LL_VEHICLE_ROOT, "waterPipeSystem" }) do
                    if embeddedXml:hasProperty(pre .. wrong) then
                        print(string.format("%s WARNING: %s has <%s> under <%s> — a barn uses <animalWaterSystem> (water in) and/or <milkPipeSystem> (milk out). See SPS_README_05_Animal_Water.md",
                            SPS_LL_TAG, tostring(placeable.configFileName), wrong, pre:sub(1, -2)))
                    end
                end
            end
        end
        embeddedXml:delete()
        if any then
            return { xmlFilePath = placeable.configFileName, isEmbedded = true, prefixes = SPS_LL_EMBEDDED_PREFIXES }
        end
    end
    -- 2. Own manifest section (barns with no slurry side)
    local own = llSuffixMatch(placeable.configFileName, self.liquidLanePlaceableConfigMap)
    if own ~= nil then
        return { xmlFilePath = own.xmlFilePath, isEmbedded = false, prefixes = SPS_LL_BUNDLED_PREFIXES }
    end
    -- 3. The slurry lane's bundled config for this placeable (the cow barn's own
    --    fillPoints.xml): lane blocks inside its <slurryPipeSystem> root.
    if self.findPlaceableConfigForPlaceable ~= nil then
        local slurryCfg = self:findPlaceableConfigForPlaceable(placeable)
        if slurryCfg ~= nil and not slurryCfg.isEmbedded and slurryCfg.xmlFilePath ~= nil then
            local xf = XMLFile.loadIfExists("spsLLSlurryPlaceableCfgCheck", slurryCfg.xmlFilePath, nil)
            if xf ~= nil then
                local any = llXmlHasAnyLane(xf, SPS_LL_BUNDLED_PREFIXES)
                xf:delete()
                if any then
                    return { xmlFilePath = slurryCfg.xmlFilePath, isEmbedded = false, prefixes = SPS_LL_BUNDLED_PREFIXES }
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Shared helpers: nodeTree linking + coupler parsing
-- ---------------------------------------------------------------------------
local function llFindByName(root, name)
    if root == nil or root == 0 or not entityExists(root) then return nil end
    if getName(root) == name then return root end
    for i = 0, getNumOfChildren(root) - 1 do
        local found = llFindByName(getChildAt(root, i), name)
        if found ~= nil then return found end
    end
    return nil
end

-- Loads <nodeTree filename> under key prefix kp and links every container's
-- children onto the live node of the same name. Returns the loaded root.
local function llLinkNodeTree(xmlFile, kp, config, findLiveParent, linkedNodes)
    local nodeTreePath = xmlFile:getString(kp .. "nodeTree#filename")
    if nodeTreePath == nil then return nil end
    local configFolder = config.xmlFilePath:match("^(.*[/\\])")
    local fullPath     = configFolder .. nodeTreePath
    local nodeTreeRoot = loadI3DFile(fullPath)
    if nodeTreeRoot == nil or nodeTreeRoot == 0 then
        print(string.format("%s WARNING: nodeTree '%s' failed to load", SPS_LL_TAG, tostring(fullPath)))
        return nil
    end
    local spsRoot = getChildAt(nodeTreeRoot, 0)
    if spsRoot ~= nil and spsRoot ~= 0 then
        for groupIdx = 0, getNumOfChildren(spsRoot) - 1 do
            local group = getChildAt(spsRoot, groupIdx)
            for containerIdx = 0, getNumOfChildren(group) - 1 do
                local container  = getChildAt(group, containerIdx)
                local liveParent = findLiveParent(getName(container))
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
                    llLog("nodeTree container '%s' has no live parent — skipped", tostring(getName(container)))
                end
            end
        end
    end
    return nodeTreeRoot
end

local function llFindInOut(mountNode)
    local inNode, outNode
    local function walk(node)
        if node == nil or node == 0 or not entityExists(node) then return end
        for i = 0, getNumOfChildren(node) - 1 do
            local child = getChildAt(node, i)
            local n = getName(child)
            if n == "inNode" then inNode = child
            elseif n == "outNode" then outNode = child
            else walk(child) end
        end
    end
    walk(mountNode)
    return inNode, outNode
end

-- Parses one coupling list (key = "<kp><listKey>(i)") into records. lane is nil
-- on the vehicle side (generic connector) and a lane descriptor on the barn side.
local function llParseCouplings(xmlFile, kp, listKey, owner, isVehicle, lane, findLinkedNode, localAnimLibrary, ownerLabel)
    local couplings = {}
    local idx = 0
    while true do
        local cKey = string.format(kp .. listKey .. "(%d)", idx)
        if not xmlFile:hasProperty(cKey) then break end
        local couplingId = xmlFile:getInt(cKey .. "#id", idx + 1)
        local mountName  = xmlFile:getString(cKey .. "#mountNodeName")
        local mountNode  = findLinkedNode(mountName)
        if mountNode == nil then
            print(string.format("%s WARNING: coupling id=%s on %s — mount node '%s' not found, coupling skipped",
                SPS_LL_TAG, tostring(couplingId), tostring(ownerLabel), tostring(mountName)))
        else
            local inNode, outNode = llFindInOut(mountNode)
            local c = {
                id                       = couplingId,
                lane                     = lane,           -- barn side: fixed; vehicle side: nil
                activeLane               = nil,            -- set while connected (both sides)
                mountNode                = mountNode,
                inNode                   = inNode,
                outNode                  = outNode,
                maxPipeLength            = SPSHoseVisual.capReach80(xmlFile:getFloat(cKey .. "#maxPipeLength", 7.5), cKey),   -- [SPS HOSE] 6c reach rule
                connectorAnimationId     = xmlFile:getInt(cKey .. "#connectorAnimation"),
                valveAnimationId         = xmlFile:getInt(cKey .. "#valveAnimation"),
                isConnected              = false,
                valveOpen                = false,
                connectedTarget          = nil,
                connectedPartnerCoupling = nil,
                pipeId                   = nil,
                object                   = owner,
                isVehicleSide            = isVehicle,
                isLiquidLane             = true,   -- [SPS 1.0.1.8] tells the physical-pipe code which system owns this coupling
                ballValveOpen            = false,  -- [SPS 1.0.1.8] the fitting's own valve (physical pipes: R at the fitting)
                -- [SPS 1.0.1.8] gravity nodes "the same as slurry" (William 2026-10-18): crest of the pipe run +
                -- the tank's top / bottom (surface = bottom + level / capacity * (top - bottom)). All optional.
                headHeightNode           = findLinkedNode(xmlFile:getString(cKey .. "#headHeightNodeName")),
                tankTopNode              = findLinkedNode(xmlFile:getString(cKey .. "#tankTopNodeName")),
                tankBottomNode           = findLinkedNode(xmlFile:getString(cKey .. "#tankBottomNodeName")),
            }
            if isVehicle then
                c.fillUnitIndex = xmlFile:getInt(cKey .. "#fillUnitIndex", 1)
                -- Lanes this connector may serve. Default: every lane whose liquid the
                -- fill unit accepts (decided after parsing, needs the vehicle).
                local lanesStr = xmlFile:getString(cKey .. "#lanes")
                if lanesStr ~= nil and lanesStr ~= "" then
                    c.lanes = {}
                    for name in lanesStr:gmatch("%S+") do
                        local up = name:upper()
                        if SPS_LIQUID_LANES[up] ~= nil then
                            c.lanes[up] = true
                        else
                            print(string.format("%s WARNING: unknown lane '%s' on %s coupling id=%s — ignored",
                                SPS_LL_TAG, tostring(name), tostring(ownerLabel), tostring(couplingId)))
                        end
                    end
                end
            else
                c.placeable = owner
            end
            if SPSCouplerAnimator ~= nil
            and (c.connectorAnimationId ~= nil or c.valveAnimationId ~= nil) then
                SPSCouplerAnimator.ensureLoaded(g_currentMission.spsModDirectory)
                if c.connectorAnimationId ~= nil then
                    c.connectorAnim = SPSCouplerAnimator.bind(mountNode, c.connectorAnimationId, localAnimLibrary)
                end
                if c.valveAnimationId ~= nil then
                    c.valveAnim = SPSCouplerAnimator.bind(mountNode, c.valveAnimationId, localAnimLibrary)
                end
            end
            table.insert(couplings, c)
            -- [SPS 1.0.1.8] fitting valve prompt (shows in PHYSICAL mode while a pipe is on the fitting)
            -- Vehicle side: R at the control node (SPSLiquidLaneControl) - two prompts in one spot hide each other
            if not isVehicle and SPSLaneValveActivatable ~= nil and g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
                c.valveActivatable = SPSLaneValveActivatable.new(c)
                g_currentMission.activatableObjectsSystem:addActivatable(c.valveActivatable)
            end
            llLog("coupling id=%s lane=%s on %s: mount=%s in=%s out=%s head=%s tankTop=%s tankBottom=%s", tostring(couplingId),
                tostring(lane and lane.key or "vehicle"), tostring(ownerLabel),
                tostring(mountName), tostring(inNode ~= nil), tostring(outNode ~= nil),
                tostring(c.headHeightNode ~= nil), tostring(c.tankTopNode ~= nil), tostring(c.tankBottomNode ~= nil))
        end
        idx = idx + 1
    end
    return couplings
end

-- ---------------------------------------------------------------------------
-- Vehicle registration — <liquidPipeSystem>
-- ---------------------------------------------------------------------------
function SlurryPipeManager:registerLiquidLaneVehicle(vehicle)
    self:_llEnsureTables()
    for _, entry in ipairs(self.registeredLiquidLaneVehicles) do
        if entry.object == vehicle then return end
    end
    local config = self:findLiquidLaneVehicleConfigForVehicle(vehicle)
    if config == nil then return end

    local xmlFile, xmlFileOwned
    if config.isEmbedded then
        xmlFile = vehicle.xmlFile
    else
        xmlFile = XMLFile.load("spsLLVehiclePoints", config.xmlFilePath)
        xmlFileOwned = true
    end
    if xmlFile == nil then return end

    -- Which prefix holds the block in THIS file
    local kp = nil
    if config.xmlKeyPrefix ~= nil then
        kp = config.xmlKeyPrefix .. SPS_LL_VEHICLE_ROOT .. "."
    else
        for _, pre in ipairs(config.prefixes or SPS_LL_BUNDLED_PREFIXES) do
            if xmlFile:hasProperty(pre .. SPS_LL_VEHICLE_ROOT) then kp = pre .. SPS_LL_VEHICLE_ROOT .. "." break end
        end
    end
    if kp == nil then
        if xmlFileOwned then xmlFile:delete() end
        return
    end
    local localAnimLibrary = nil
    if SPSCouplerAnimator ~= nil and SPSCouplerAnimator.parseLocal ~= nil then
        localAnimLibrary = SPSCouplerAnimator.parseLocal(xmlFile, kp)
    end

    local entry = {
        object          = vehicle,
        isVehicle       = true,
        linkedNodes     = {},
        couplings       = {},
        controls        = {},
        litersPerSecond = xmlFile:getFloat(kp .. "flow#litersPerSecond", 200),
        nodeTreeRoot    = nil,
        state           = { valveOpen = false },
    }

    entry.nodeTreeRoot = llLinkNodeTree(xmlFile, kp, config, function(name)
        return SlurryNodeUtil.findVehicleNodeByName(vehicle, name, false)
    end, entry.linkedNodes)

    local function findLinkedNode(name)
        if name == nil or name == "" then return nil end
        for _, n in ipairs(entry.linkedNodes) do
            if getName(n) == name then return n end
        end
        local found = SlurryNodeUtil.findVehicleNodeByName(vehicle, name, false)
        if found ~= nil then return found end
        found = SlurryNodeUtil.findVehicleNodeByName(vehicle, name, true)
        if found ~= nil then
            print(string.format("%s WARNING: node '%s' on %s only matched after trimming whitespace (actual '%s')",
                SPS_LL_TAG, tostring(name), tostring(vehicle.configFileName), tostring(getName(found))))
        end
        return found
    end

    entry.couplings = llParseCouplings(xmlFile, kp, SPS_LL_VEHICLE_COUPLINGS, vehicle, true, nil,
        findLinkedNode, localAnimLibrary, vehicle.configFileName)

    -- Lane set per connector: explicit #lanes, else every lane whose liquid the
    -- fill unit accepts. A connector that ends up with no lane is useless — warn.
    -- A vehicle that is a REAL sprayer (own <sprayerPipeSystem>) keeps its own
    -- sprayer control; the bridge lane is only for vehicles that are not.
    local isRealSprayer = self.isSprayerVehicleRegistered ~= nil and self:isSprayerVehicleRegistered(vehicle)
        or (self.findSprayerVehicleConfigForVehicle ~= nil and self:findSprayerVehicleConfigForVehicle(vehicle) ~= nil)
    for _, c in ipairs(entry.couplings) do
        if c.lanes == nil then
            c.lanes = {}
            for _, k in ipairs(SPS_LL_LANE_ORDER) do
                local lane = SPS_LIQUID_LANES[k]
                for _, ft in ipairs(llLaneFillTypes(lane)) do
                    if vehicle.getFillUnitAllowsFillType ~= nil and vehicle:getFillUnitAllowsFillType(c.fillUnitIndex, ft) then
                        c.lanes[k] = true
                        break
                    end
                end
            end
        end
        if isRealSprayer and c.lanes.SPRAYER then
            c.lanes.SPRAYER = nil
            print(string.format("%s %s is a sprayer itself — its liquid connector will not serve the SPRAYER lane",
                SPS_LL_TAG, tostring(vehicle.configFileName)))
        end
        local names = {}
        for _, k in ipairs(SPS_LL_LANE_ORDER) do if c.lanes[k] then table.insert(names, k) end end
        if #names == 0 then
            print(string.format("%s WARNING: %s coupling id=%s serves no lane (fill unit %d accepts neither water nor milk)",
                SPS_LL_TAG, tostring(vehicle.configFileName), tostring(c.id), c.fillUnitIndex))
        end
        c.laneNames = table.concat(names, " ")
    end

    -- Walk-up control node(s)
    local pcIndex = 0
    while true do
        local pcKey = string.format(kp .. SPS_LL_VEHICLE_CONTROLS .. "(%d)", pcIndex)
        if not xmlFile:hasProperty(pcKey) then break end
        local pcId     = xmlFile:getInt(pcKey .. "#id", pcIndex + 1)
        local pcRadius = xmlFile:getFloat(pcKey .. "#radius", 1.5)
        local pcName   = xmlFile:getString(pcKey .. "#nodeName")
        local pcNode   = findLinkedNode(pcName)
        if pcNode ~= nil and SPSLiquidLaneControl ~= nil then
            local ctrl = SPSLiquidLaneControl.new(vehicle, pcNode, pcRadius)
            table.insert(entry.controls, { id = pcId, node = pcNode, radius = pcRadius, activatable = ctrl })
            g_currentMission.activatableObjectsSystem:addActivatable(ctrl)
        else
            print(string.format("%s WARNING: control node '%s' not found on %s — no walk-up prompt",
                SPS_LL_TAG, tostring(pcName), tostring(vehicle.configFileName)))
        end
        pcIndex = pcIndex + 1
    end

    if xmlFileOwned then xmlFile:delete() end

    if #entry.couplings == 0 then
        print(string.format("%s %s: <%s> present but no usable coupling — not registered",
            SPS_LL_TAG, tostring(vehicle.configFileName), SPS_LL_VEHICLE_ROOT))
        for _, pc in ipairs(entry.controls) do if pc.activatable ~= nil then pc.activatable:delete() end end
        return
    end
    if #entry.controls == 0 then
        print(string.format("%s %s: registered without a <%s> node — nothing can connect it",
            SPS_LL_TAG, tostring(vehicle.configFileName), SPS_LL_VEHICLE_CONTROLS))
    end

    table.insert(self.registeredLiquidLaneVehicles, entry)
    spsInfo(string.format("%s registerLiquidLaneVehicle: registered %s (%d connector(s) [%s], %d control(s))",
        SPS_LL_TAG, tostring(vehicle.configFileName), #entry.couplings,
        tostring(entry.couplings[1].laneNames), #entry.controls))
    self:_tryResolveLiquidLaneConnects()
end

function SlurryPipeManager:unregisterLiquidLaneVehicle(vehicle)
    self:_llEnsureTables()
    for i, entry in ipairs(self.registeredLiquidLaneVehicles) do
        if entry.object == vehicle then
            for _, c in ipairs(entry.couplings) do
                if c.isConnected then self:applyLiquidLaneDisconnect(vehicle, c.id, c) end
                if c.valveActivatable ~= nil then c.valveActivatable:delete(); c.valveActivatable = nil end
            end
            for _, pc in ipairs(entry.controls) do
                if pc.activatable ~= nil then pc.activatable:delete() end
            end
            -- Hide, don't delete: the owner's subtree is engine-reaped (dangling-id
            -- evidence recorded on the sprayer unregister).
            for _, nodeId in ipairs(entry.linkedNodes) do
                if nodeId ~= nil and nodeId ~= 0 and entityExists(nodeId) then setVisibility(nodeId, false) end
            end
            if entry.nodeTreeRoot ~= nil and entry.nodeTreeRoot ~= 0 then
                delete(entry.nodeTreeRoot)
                entry.nodeTreeRoot = nil
            end
            table.remove(self.registeredLiquidLaneVehicles, i)
            llLog("unregisterLiquidLaneVehicle: %s", tostring(vehicle and vehicle.configFileName))
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Placeable registration — husbandries, one block per lane
-- ---------------------------------------------------------------------------
-- Per-lane fitness check. Returns ok, reason.
local function llPlaceableLaneOk(placeable, storage, lane)
    local fts = llLaneFillTypes(lane)
    if lane.key == "WATER" then
        local waterSpec = placeable.spec_husbandryWater
        if waterSpec == nil or waterSpec.automaticWaterSupply ~= false then
            return false, "water supply is AUTOMATIC (no drinking-water pool)"
        end
    end
    local any = false
    for _, ft in ipairs(fts) do
        if storage.getIsFillTypeSupported == nil or storage:getIsFillTypeSupported(ft) then any = true break end
    end
    if not any then
        return false, "husbandry storage holds none of " .. table.concat(lane.fillTypeNames, "/")
    end
    return true, nil
end

function SlurryPipeManager:registerLiquidLanePlaceable(placeable)
    self:_llEnsureTables()
    if placeable == nil or placeable.spec_husbandry == nil then return end
    for _, entry in ipairs(self.registeredLiquidLanePlaceables) do
        if entry.object == placeable then return end
    end
    local config = self:findLiquidLanePlaceableConfigForPlaceable(placeable)
    if config == nil then return end

    local label   = tostring(placeable.configFileName)
    local sh      = placeable.spec_husbandry
    local storage = (sh ~= nil and sh.storage ~= nil and type(sh.storage.getFillLevel) == "function") and sh.storage or nil
    if storage == nil then
        print(string.format("%s WARNING: %s has a liquid-lane block but no husbandry storage — skipped", SPS_LL_TAG, label))
        return
    end

    local xmlFile, xmlFileOwned
    if config.isEmbedded then
        xmlFile = placeable.xmlFile
    else
        xmlFile = XMLFile.load("spsLLPlaceablePoints", config.xmlFilePath)
        xmlFileOwned = true
    end
    if xmlFile == nil then return end

    local prefixes = config.prefixes or SPS_LL_BUNDLED_PREFIXES
    local function findLiveParent(name)
        if placeable.components == nil then return nil end
        for _, comp in ipairs(placeable.components) do
            local found = llFindByName(comp.node, name)
            if found ~= nil then return found end
        end
        return nil
    end

    local entry = {
        object      = placeable,
        placeable   = placeable,
        isPlaceable = true,
        linkedNodes = {},
        couplings   = {},
        storage     = storage,
        lanes       = {},   -- lane key -> true for every lane that registered
    }

    -- Nodes: our own linked nodes first, then anything already in the placeable —
    -- which includes the slurry lane's nodeTree (it registers first), so a lane
    -- coupler authored in the SAME nodeTree.i3d as the slurry coupler is found.
    local function findLinkedNode(name)
        if name == nil or name == "" then return nil end
        for _, n in ipairs(entry.linkedNodes) do
            if getName(n) == name then return n end
        end
        return findLiveParent(name)
    end

    local anyBlock = false
    for _, k in ipairs(SPS_LL_LANE_ORDER) do
        local lane = SPS_LIQUID_LANES[k]
        local kp = nil
        if lane.xmlRoot ~= nil then
            for _, pre in ipairs(prefixes) do
                if xmlFile:hasProperty(pre .. lane.xmlRoot) then kp = pre .. lane.xmlRoot .. "." break end
            end
        end
        if kp ~= nil then
            anyBlock = true
            local ok, reason = llPlaceableLaneOk(placeable, storage, lane)
            if not ok then
                print(string.format("%s WARNING: %s has <%s> but %s — %s coupler skipped",
                    SPS_LL_TAG, label, lane.xmlRoot, reason, lane.key))
            else
                local localAnimLibrary = nil
                if SPSCouplerAnimator ~= nil and SPSCouplerAnimator.parseLocal ~= nil then
                    localAnimLibrary = SPSCouplerAnimator.parseLocal(xmlFile, kp)
                end
                local before = #entry.linkedNodes
                local root = llLinkNodeTree(xmlFile, kp, config, findLiveParent, entry.linkedNodes)
                if root ~= nil and root ~= 0 then delete(root) end
                local laneCouplings = llParseCouplings(xmlFile, kp, lane.couplingsKey, placeable, false, lane,
                    findLinkedNode, localAnimLibrary, label)
                if #laneCouplings > 0 then
                    for _, c in ipairs(laneCouplings) do table.insert(entry.couplings, c) end
                    entry.lanes[k] = true
                else
                    print(string.format("%s %s: <%s> present but no usable coupling (linked %d node(s))",
                        SPS_LL_TAG, label, lane.xmlRoot, #entry.linkedNodes - before))
                end
            end
        end
    end
    if xmlFileOwned then xmlFile:delete() end
    if not anyBlock then return end

    -- Nothing usable (wrong placeable path-matched, or the nodes are not in the
    -- i3d yet): do not register.
    if #entry.couplings == 0 then
        llLog("registerLiquidLanePlaceable: %s — no coupler registered", label)
        return
    end

    table.insert(self.registeredLiquidLanePlaceables, entry)
    local laneNames = {}
    for _, k in ipairs(SPS_LL_LANE_ORDER) do if entry.lanes[k] then table.insert(laneNames, k) end end
    spsInfo(string.format("%s registerLiquidLanePlaceable: registered %s (%d coupling(s): %s)",
        SPS_LL_TAG, label, #entry.couplings, table.concat(laneNames, " ")))
    self:_tryResolveLiquidLaneConnects()
end

function SlurryPipeManager:unregisterLiquidLanePlaceable(placeable)
    self:_llEnsureTables()
    for i, entry in ipairs(self.registeredLiquidLanePlaceables) do
        if entry.object == placeable then
            for _, c in ipairs(entry.couplings) do
                if c.isConnected then self:applyLiquidLaneDisconnect(nil, c.id, c) end
                if c.valveActivatable ~= nil then c.valveActivatable:delete(); c.valveActivatable = nil end
            end
            for _, nodeId in ipairs(entry.linkedNodes) do
                if nodeId ~= nil and nodeId ~= 0 and entityExists(nodeId) then setVisibility(nodeId, false) end
            end
            table.remove(self.registeredLiquidLanePlaceables, i)
            llLog("unregisterLiquidLanePlaceable: %s", tostring(placeable and placeable.configFileName))
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Lookups
-- ---------------------------------------------------------------------------
function SlurryPipeManager:getLiquidLaneVehicleEntry(vehicle)
    if vehicle == nil or self.registeredLiquidLaneVehicles == nil then return nil end
    for _, e in ipairs(self.registeredLiquidLaneVehicles) do
        if e.object == vehicle then return e end
    end
    return nil
end

function SlurryPipeManager:getLiquidLanePlaceableEntry(placeable)
    if placeable == nil or self.registeredLiquidLanePlaceables == nil then return nil end
    for _, e in ipairs(self.registeredLiquidLanePlaceables) do
        if e.object == placeable then return e end
    end
    return nil
end

function SlurryPipeManager:isLiquidLaneVehicleRegistered(vehicle)
    return self:getLiquidLaneVehicleEntry(vehicle) ~= nil
end

function SlurryPipeManager:liquidLaneHasConnectedPipe(vehicle)
    local e = self:getLiquidLaneVehicleEntry(vehicle)
    if e == nil then return false end
    for _, c in ipairs(e.couplings) do
        if c.isConnected then return true end
    end
    return false
end

function SlurryPipeManager:_findLiquidLaneCouplingById(object, couplingId)
    if object == nil or couplingId == nil then return nil end
    local vEntry = self:getLiquidLaneVehicleEntry(object)
    if vEntry ~= nil then
        for _, c in ipairs(vEntry.couplings) do
            if c.id == couplingId then return c end
        end
    end
    local pEntry = self:getLiquidLanePlaceableEntry(object)
    if pEntry ~= nil then
        for _, c in ipairs(pEntry.couplings) do
            if c.id == couplingId then return c end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Matching: a VEHICLE connector looks for a BARN coupler whose lane it serves.
-- Scans this system's placeable registry and nothing else. Same arc + distance
-- test as slurry/sprayer, nearest to the player wins (walk to the coupler you want).
-- ---------------------------------------------------------------------------
function SlurryPipeManager:findOverlappingLiquidLaneCoupler(coupling)
    if coupling == nil or coupling.isConnected or not coupling.isVehicleSide then return nil end
    local apexA, arc1A, arc2A = self:_getCouplingArcNodes(coupling)
    if apexA == nil or not entityExists(apexA) then return nil end
    local ax, ay, az = getWorldTranslation(apexA)
    local refX, refY, refZ = ax, ay, az
    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        refX, refY, refZ = getWorldTranslation(g_localPlayer.rootNode)
    end
    local best, bestDist = nil, math.huge
    -- The flag rule (William): a tank holding milk may only meet a MILK coupler, a
    -- tank holding water only a WATER coupler. An empty tank may meet either.
    local heldFt = nil
    if coupling.object ~= nil and coupling.object.getFillUnitFillLevel ~= nil then
        local lvl = coupling.object:getFillUnitFillLevel(coupling.fillUnitIndex or 1) or 0
        if lvl > 0.001 then heldFt = coupling.object:getFillUnitFillType(coupling.fillUnitIndex or 1) end
    end
    local bestLane = nil
    local function consider(sc, lane)
        local apexB, arc1B, arc2B = self:_getCouplingArcNodes(sc)
        if apexB == nil or not entityExists(apexB) then return end
        local bx, by, bz = getWorldTranslation(apexB)
        if MathUtil.vector3Length(ax - bx, ay - by, az - bz) > SPS_MAX_CONNECT_DIST then return end
        if not self:_arcsOverlap(apexA, arc1A, arc2A, apexB, arc1B, arc2B) then return end
        local d = MathUtil.vector3Length(refX - bx, refY - by, refZ - bz)
        if d < bestDist then best, bestDist, bestLane = sc, d, lane end
    end
    -- Barn lanes (own registry)
    for _, pEntry in ipairs(self.registeredLiquidLanePlaceables) do
        for _, sc in ipairs(pEntry.couplings) do
            if not sc.isConnected and sc.lane ~= nil and coupling.lanes ~= nil and coupling.lanes[sc.lane.key]
            and llLaneAcceptsHeld(sc.lane, heldFt) then
                consider(sc, sc.lane)
            end
        end
    end
    -- Bridge lane: the sprayer lane's sources (silos, IBC tanks, buying stations)
    local spLane = SPS_LIQUID_LANES.SPRAYER
    if coupling.lanes ~= nil and coupling.lanes.SPRAYER and llLaneAcceptsHeld(spLane, heldFt)
    and self.registeredSprayerPlaceables ~= nil then
        for _, pEntry in ipairs(self.registeredSprayerPlaceables) do
            for _, sc in ipairs(pEntry.couplings or {}) do
                if not sc.isConnected then consider(sc, spLane) end
            end
        end
    end
    return best, bestLane
end

-- Owner object of a far-side coupling (barn placeable, sprayer placeable, IBC vehicle)
local function llCouplingOwner(c)
    if c == nil then return nil end
    return c.placeable or c.object
end

-- ---------------------------------------------------------------------------
-- SPRAYER bridge: a temporary sprayer-vehicle entry for this vehicle so the
-- sprayer lane's own code runs the connection. Created on every peer at connect,
-- removed at disconnect. Flagged isLiquidLaneBridge so sprayer-side bookkeeping
-- (save, join dump, combos) leaves it to this module.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_llEnsureSprayerBridge(vehicle, cV)
    local existing = self:getSprayerVehicleEntry(vehicle)
    if existing ~= nil then
        if existing.isLiquidLaneBridge then return existing.couplings[1] end
        return nil   -- a real sprayer: never bridge
    end
    local llEntry = self:getLiquidLaneVehicleEntry(vehicle)
    local bc = {
        id                       = cV.id,
        mountNode                = cV.mountNode,
        inNode                   = cV.inNode,
        outNode                  = cV.outNode,
        flowDirection            = "BOTH",
        restrictFillType         = nil,
        maxPipeLength            = SPSHoseVisual.capReach80(cV.maxPipeLength or 7.5, "sprayer bridge"),
        fillUnitIndex            = cV.fillUnitIndex or 1,
        connectorAnimationId     = cV.connectorAnimationId,
        valveAnimationId         = cV.valveAnimationId,
        connectorAnim            = cV.connectorAnim,
        valveAnim                = cV.valveAnim,
        loadAnimationName        = nil,
        loadAnimPlayed           = false,
        isConnected              = false,
        valveOpen                = false,
        connectedTarget          = nil,
        connectedPartnerCoupling = nil,
        pipeId                   = nil,
        object                   = vehicle,
        isLiquidLaneBridge       = true,
    }
    local entry = {
        object             = vehicle,
        isVehicle          = true,
        isLiquidLaneBridge = true,
        linkedNodes        = {},
        couplings          = { bc },
        pumpControls       = {},
        pipeActivatables   = {},
        litersPerSecond    = llEntry ~= nil and llEntry.litersPerSecond or 200,
        ftBalance          = { lowPct = 30, highPct = 40, litersPerMinute = 200 },
        nodeTreeRoot       = nil,
        state = {
            pumpRunning  = false,
            valveOpen    = false,
            direction    = SPS_SPRAYER_DIRECTION_FILL,
            loadAnimName = nil,
            coupling     = bc,
        },
    }
    table.insert(self.registeredSprayerVehicles, entry)
    llLog("sprayer bridge created for %s", tostring(vehicle and vehicle.configFileName))
    return bc
end

function SlurryPipeManager:_llRemoveSprayerBridge(vehicle)
    if self.registeredSprayerVehicles == nil then return end
    for i, e in ipairs(self.registeredSprayerVehicles) do
        if e.object == vehicle and e.isLiquidLaneBridge then
            if self.activeSprayerFlows ~= nil then self.activeSprayerFlows[vehicle] = nil end
            table.remove(self.registeredSprayerVehicles, i)
            llLog("sprayer bridge removed for %s", tostring(vehicle and vehicle.configFileName))
            return
        end
    end
end

-- Sprayer-side state of a bridged vehicle (nil when not bridged)
function SlurryPipeManager:_llBridgeState(vehicle)
    local e = self:getSprayerVehicleEntry(vehicle)
    if e ~= nil and e.isLiquidLaneBridge then return e.state, e.couplings[1] end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Connect / disconnect
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onLiquidLaneConnect(vehicle, coupling)
    if coupling == nil or coupling.isConnected then return end
    if g_server == nil then
        SPSLiquidLaneConnectEvent.sendEvent(vehicle, coupling.id, nil, 0, 0)
        return
    end
    local other, lane = self:findOverlappingLiquidLaneCoupler(coupling)
    if other == nil or other.isConnected or lane == nil then return end
    local owner = llCouplingOwner(other)
    self:applyLiquidLaneConnect(coupling, other, vehicle, owner, lane)
    SPSLiquidLaneConnectEvent.sendEvent(vehicle, coupling.id, owner, other.id, lane.id)
end

function SlurryPipeManager:applyLiquidLaneConnect(cV, cP, vehicle, placeable, lane)
    if cV == nil or cP == nil then return end
    lane = lane or cP.lane
    if lane == nil then return end
    if lane.bridge then
        -- SPRAYER lane: hand the connection to the sprayer code through a bridge entry.
        if cV.isConnected and cV.connectedPartnerCoupling == cP then return end
        local bc = self:_llEnsureSprayerBridge(vehicle, cV)
        if bc == nil then return end
        self:applySprayerConnect(bc, cP, vehicle, placeable)
        cV.isConnected = true; cV.activeLane = lane; cV.connectedTarget = placeable
        cV.connectedPartnerCoupling = cP; cV.bridgeCoupling = bc; cV.valveOpen = false
        self.activeLiquidLaneBridges = self.activeLiquidLaneBridges or {}
        self.activeLiquidLaneBridges[vehicle] = { cV = cV, cP = cP, owner = placeable }
        llLog("applyLiquidLaneConnect (bridge): %s id=%s -> %s id=%s", tostring(vehicle and vehicle.configFileName),
            tostring(cV.id), tostring(placeable and placeable.configFileName), tostring(cP.id))
        return
    end
    if cV.isConnected and cP.isConnected and cV.connectedPartnerCoupling == cP and (cV.pipeId ~= nil or cV.physPipe ~= nil) then
        return -- idempotent re-delivery
    end
    cV.isConnected = true;  cV.connectedTarget = placeable; cV.connectedPartnerCoupling = cP; cV.activeLane = lane
    cP.isConnected = true;  cP.connectedTarget = vehicle;   cP.connectedPartnerCoupling = cV; cP.activeLane = lane
    cV.valveOpen = false;   cP.valveOpen = false
    local vEntry = self:getLiquidLaneVehicleEntry(vehicle)
    if vEntry ~= nil then vEntry.state.valveOpen = false end
    if cP.isVehicleSide then   -- TRANSFER: the far side is a tanker too
        local pe = self:getLiquidLaneVehicleEntry(cP.object)
        if pe ~= nil then pe.state.valveOpen = false end
    end

    -- [SPS 1.0.1.8] PHYSICAL pipes: the bought pipe IS the hose - draw nothing (SPSM_PhysPipes).
    local physPipe = cV.physPipe ~= nil or cP.physPipe ~= nil
    if not physPipe and g_spsLiquidLanePipeVisual ~= nil and g_spsLiquidLanePipeVisual:isReady() then
        -- Hose always drawn from the vehicle connector's outNode to the barn's inNode,
        -- whichever way the liquid flows (it is one hose).
        local nodeA = cV.outNode or cV.mountNode
        local nodeB = cP.inNode  or cP.mountNode
        local inst  = g_spsLiquidLanePipeVisual:createPipe(nodeA, nodeB, (lane ~= nil and lane.key == "MILK") and "milk" or "water")
        if inst ~= nil then
            local pipeId = self._nextLiquidLanePipeId
            self._nextLiquidLanePipeId = pipeId + 1
            self.activeLiquidLanePipes[pipeId] = { inst = inst, couplingA = cV, couplingB = cP }
            cV.pipeId = pipeId
            cP.pipeId = pipeId
        end
    end
    -- [SPS 1.0.1.8] physical pipes: the fitting's only handle IS its valve (R at the fitting / control node) -
    -- the player turns it, never the code (William 2026-10-17: barn handle opened by itself on connect)
    if SPSCouplerAnimator ~= nil and not physPipe then
        if cV.connectorAnim ~= nil then SPSCouplerAnimator.play(cV.connectorAnim, 1) end
        if cP.connectorAnim ~= nil then SPSCouplerAnimator.play(cP.connectorAnim, 1) end
    end
    llLog("applyLiquidLaneConnect: %s id=%s -> %s id=%s lane=%s pipeId=%s", tostring(vehicle and vehicle.configFileName),
        tostring(cV.id), tostring(placeable and placeable.configFileName), tostring(cP.id),
        tostring(lane and lane.key), tostring(cV.pipeId))
end

function SlurryPipeManager:_queuePendingLiquidLaneConnect(object, couplingId, targetObject, targetCouplingId, laneId)
    for _, e in ipairs(self._pendingLiquidLaneConnects) do
        if e.object == object and e.couplingId == couplingId
        and e.targetObject == targetObject and e.targetCouplingId == targetCouplingId then
            return
        end
    end
    table.insert(self._pendingLiquidLaneConnects, {
        object = object, couplingId = couplingId, targetObject = targetObject, targetCouplingId = targetCouplingId,
        laneId = laneId,
    })
end

-- Far-side coupling lookup by lane: barn lanes in this registry, bridge lane in the sprayer one.
function SlurryPipeManager:_llFindFarCouplingById(targetObject, targetCouplingId, laneId)
    local lane = llLaneById(laneId)
    if lane ~= nil and lane.bridge then
        if self._findSprayerCouplingById == nil then return nil, lane end
        return self:_findSprayerCouplingById(targetObject, targetCouplingId, true), lane
    end
    local c = self:_findLiquidLaneCouplingById(targetObject, targetCouplingId)
    return c, (c ~= nil and c.lane) or lane
end

function SlurryPipeManager:_tryResolveLiquidLaneConnects()
    -- Savegame hoses first (position-matched), then the MP queue.
    self:_tryResolveSavedLiquidLaneConnects()
    if self._pendingLiquidLaneConnects == nil or #self._pendingLiquidLaneConnects == 0 then return end
    local kept = {}
    for _, e in ipairs(self._pendingLiquidLaneConnects) do
        local cV = self:_findLiquidLaneCouplingById(e.object, e.couplingId)
        local cP, lane = nil, nil
        if e.targetObject ~= nil and (e.targetCouplingId or 0) > 0 then
            cP, lane = self:_llFindFarCouplingById(e.targetObject, e.targetCouplingId, e.laneId)
        end
        if cV ~= nil and cP ~= nil then
            self:applyLiquidLaneConnect(cV, cP, e.object, e.targetObject, lane)
        else
            table.insert(kept, e)
        end
    end
    self._pendingLiquidLaneConnects = kept
end

-- Network path. targetCouplingId == 0 => client-originated; resolve by arc here.
function SlurryPipeManager:applyLiquidLaneConnectById(object, couplingId, targetObject, targetCouplingId, laneId)
    local cV = self:_findLiquidLaneCouplingById(object, couplingId)
    if cV == nil then
        if object ~= nil and couplingId ~= nil then
            self:_queuePendingLiquidLaneConnect(object, couplingId, targetObject, targetCouplingId, laneId)
        end
        return
    end
    local cP, lane = nil, nil
    if targetObject ~= nil and (targetCouplingId or 0) > 0 then
        cP, lane = self:_llFindFarCouplingById(targetObject, targetCouplingId, laneId)
        if cP == nil then
            self:_queuePendingLiquidLaneConnect(object, couplingId, targetObject, targetCouplingId, laneId)
            return
        end
    else
        cP, lane = self:findOverlappingLiquidLaneCoupler(cV)
        if cP == nil then return end
    end
    self:applyLiquidLaneConnect(cV, cP, object, llCouplingOwner(cP), lane)
end

function SlurryPipeManager:onLiquidLaneDisconnect(vehicle, coupling)
    if coupling == nil then return end
    if g_server == nil then
        SPSLiquidLaneDisconnectEvent.sendEvent(vehicle, coupling.id)
        return
    end
    self:applyLiquidLaneDisconnect(vehicle, coupling.id, coupling)
    SPSLiquidLaneDisconnectEvent.sendEvent(vehicle, coupling.id)
end

function SlurryPipeManager:applyLiquidLaneDisconnect(object, couplingId, couplingObj)
    local coupling = couplingObj or self:_findLiquidLaneCouplingById(object, couplingId)
    if coupling == nil then return end
    if coupling.bridgeCoupling ~= nil then
        -- SPRAYER lane: let the sprayer code tear its side down, then drop the bridge.
        local vehicle = coupling.object
        local bc = coupling.bridgeCoupling
        if bc.isConnected and self.applySprayerDisconnect ~= nil then
            self:applySprayerDisconnect(vehicle, bc.id, bc)
        end
        self:_llRemoveSprayerBridge(vehicle)
        if self.activeLiquidLaneBridges ~= nil then self.activeLiquidLaneBridges[vehicle] = nil end
        coupling.isConnected = false; coupling.connectedTarget = nil; coupling.connectedPartnerCoupling = nil
        coupling.activeLane = nil; coupling.bridgeCoupling = nil; coupling.valveOpen = false
        llLog("applyLiquidLaneDisconnect (bridge): id=%s", tostring(couplingId))
        return
    end
    local partner = coupling.connectedPartnerCoupling
    local vehicleSide = coupling.isVehicleSide and coupling or (partner ~= nil and partner.isVehicleSide and partner or nil)
    local vehicle = vehicleSide ~= nil and vehicleSide.object or nil
    local vEntry  = self:getLiquidLaneVehicleEntry(vehicle)
    if vEntry ~= nil then vEntry.state.valveOpen = false end
    coupling.valveOpen = false
    if partner ~= nil then partner.valveOpen = false end

    if partner ~= nil and partner.isVehicleSide then   -- TRANSFER: the far tanker stops pumping too
        local pe = self:getLiquidLaneVehicleEntry(partner.object)
        if pe ~= nil then pe.state.valveOpen = false end
    end
    if SPSCouplerAnimator ~= nil then
        -- physical pipes: the valve animation is the FITTING valve (applyLaneFittingValve) - leave it as set
        if coupling.valveAnim ~= nil and coupling.physPipe == nil then SPSCouplerAnimator.play(coupling.valveAnim, -1) end
        if partner ~= nil and partner.valveAnim ~= nil and partner.physPipe == nil then SPSCouplerAnimator.play(partner.valveAnim, -1) end
        if coupling.connectorAnim ~= nil and coupling.physPipe == nil then SPSCouplerAnimator.play(coupling.connectorAnim, -1) end
        if partner ~= nil and partner.connectorAnim ~= nil and partner.physPipe == nil then SPSCouplerAnimator.play(partner.connectorAnim, -1) end
    end
    if coupling.pipeId ~= nil then
        local pipeData = self.activeLiquidLanePipes[coupling.pipeId]
        if pipeData ~= nil and g_spsLiquidLanePipeVisual ~= nil then
            g_spsLiquidLanePipeVisual:destroyPipe(pipeData.inst)
        end
        self.activeLiquidLanePipes[coupling.pipeId] = nil
        coupling.pipeId = nil
        if partner ~= nil then partner.pipeId = nil end
    end
    coupling.isConnected = false; coupling.connectedTarget = nil; coupling.connectedPartnerCoupling = nil; coupling.activeLane = nil
    if partner ~= nil then
        partner.isConnected = false; partner.connectedTarget = nil; partner.connectedPartnerCoupling = nil; partner.activeLane = nil
    end
    -- [SPS 1.0.1.8] PHYSICAL pipes: free the pipe end plugged into THIS coupling (not the partner's), as
    -- the slurry applyDisconnect does. Honours coupling._physKeepEnd (chain broken in the middle).
    if self._physFreeCoupling ~= nil then self:_physFreeCoupling(coupling) end
    llLog("applyLiquidLaneDisconnect: id=%s", tostring(couplingId))
end

-- ---------------------------------------------------------------------------
-- Lane-specific checks
-- ---------------------------------------------------------------------------
-- MILK: which milk type the barn actually holds. Highest level above zero wins,
-- ties (and nothing held) fall to the first supported type in lane order.
function SlurryPipeManager:_llBarnMilkType(placeable, storage, lane)
    local bestFt, bestLvl, firstSupported = nil, 0, nil
    for _, ft in ipairs(llLaneFillTypes(lane)) do
        if storage.getIsFillTypeSupported == nil or storage:getIsFillTypeSupported(ft) then
            if firstSupported == nil then firstSupported = ft end
            local lvl = placeable.getHusbandryFillLevel ~= nil and (placeable:getHusbandryFillLevel(ft) or 0) or (storage:getFillLevel(ft) or 0)
            if lvl > bestLvl then bestFt, bestLvl = ft, lvl end
        end
    end
    return bestFt or firstSupported, bestLvl
end

-- Returns ok, warningKey, fillType, srcLevel, dstFree — everything the valve toggle
-- and the tick need to decide whether this connection can move liquid right now.
function SlurryPipeManager:_llEvaluate(vehicle, c)
    local partner = c.connectedPartnerCoupling
    local lane    = c.activeLane or (partner ~= nil and partner.lane) or nil
    if partner == nil or partner.placeable == nil or lane == nil then return false, nil end
    local placeable = partner.placeable
    local pEntry    = self:getLiquidLanePlaceableEntry(placeable)
    if pEntry == nil or pEntry.storage == nil then return false, nil end
    local storage = pEntry.storage
    local fui     = c.fillUnitIndex or 1
    local tankLvl = vehicle.getFillUnitFillLevel ~= nil and (vehicle:getFillUnitFillLevel(fui) or 0) or 0
    local tankFt  = vehicle.getFillUnitFillType ~= nil and vehicle:getFillUnitFillType(fui) or nil

    if lane.direction == "TO_BARN" then
        local ft = llLaneFillTypes(lane)[1]
        if ft == nil then return false, nil end
        if tankLvl > 0.001 and tankFt ~= ft then return false, "warning_spsAnimalWaterOnly", ft, tankLvl, 0 end
        if tankLvl <= 0.001 then return false, "warning_spsAnimalWaterEmpty", ft, 0, 0 end
        local free = storage:getFreeCapacity(ft) or 0
        if free <= 0.001 then return false, "warning_spsLiquidBarnFull", ft, tankLvl, 0 end
        return true, nil, ft, tankLvl, free
    else -- FROM_BARN
        local ft, barnLvl = self:_llBarnMilkType(placeable, storage, lane)
        if ft == nil then return false, nil end
        if barnLvl <= 0.001 then return false, "warning_spsMilkBarnEmpty", ft, 0, 0 end
        if tankLvl > 0.001 and tankFt ~= ft then return false, "warning_spsMilkOnly", ft, barnLvl, 0 end
        if vehicle.getFillUnitAllowsFillType ~= nil and not vehicle:getFillUnitAllowsFillType(fui, ft) then
            return false, "warning_spsMilkOnly", ft, barnLvl, 0
        end
        local free = vehicle.getFillUnitFreeCapacity ~= nil and (vehicle:getFillUnitFreeCapacity(fui) or 0) or 0
        if free <= 0.001 then return false, "warning_spsLiquidTankFull", ft, barnLvl, 0 end
        return true, nil, ft, barnLvl, free
    end
end

-- ---------------------------------------------------------------------------
-- Valve (B at the control node). One toggle = pump + valve.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onLiquidLaneToggleValve(vehicle)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil then return end
    do
        local c = nil
        for _, cc in ipairs(entry.couplings) do if cc.isConnected then c = cc break end end
        if c ~= nil and c.bridgeCoupling ~= nil then
            -- SPRAYER lane: exactly the sprayer's B toggle (pump + valve, events, sound).
            if self.onSprayerToggleValve ~= nil then self:onSprayerToggleValve(vehicle) end
            return
        end
    end
    local newValve = not entry.state.valveOpen
    if newValve then
        local c = nil
        for _, cc in ipairs(entry.couplings) do if cc.isConnected then c = cc break end end
        if c == nil then return end
        -- [SPS 1.0.1.8] physical pipes: the pump only runs with BOTH fitting valves open (R at the fittings)
        if c.physPipe ~= nil then
            local p = c.connectedPartnerCoupling
            if not c.ballValveOpen or (p ~= nil and not p.ballValveOpen) then
                if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                    g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsFittingValveClosed"), 2500)
                end
                return
            end
        end
        local ok, warnKey
        if c.activeLane ~= nil and c.activeLane.transfer then
            ok, warnKey = self:_llEvaluateTransfer(vehicle, c)
        else
            ok, warnKey = self:_llEvaluate(vehicle, c)
        end
        if not ok and c.physPipe ~= nil then
            print(string.format("[SPS PHYS] pump refused on %s (%s lane): %s", tostring(vehicle and vehicle.configFileName),
                tostring(c.activeLane and c.activeLane.key), tostring(warnKey or "cannot flow")))
        end
        if not ok then
            if warnKey ~= nil and g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                g_currentMission:showBlinkingWarning(g_i18n:getText(warnKey), 2500)
            end
            return
        end
    end
    -- Server applies + broadcasts; a client applies locally first (the server's
    -- rebroadcast excludes the sender) then sends.
    self:applyLiquidLaneValveState(vehicle, newValve)
    SPSLiquidLaneValveStateEvent.sendEvent(vehicle, newValve)
end

-- Y at the control node. Same key as a sprayer: on the SPRAYER lane it is the
-- sprayer's own Load/Unload toggle; on a barn lane the direction is fixed by the
-- lane, so the press only explains that.
function SlurryPipeManager:onLiquidLaneToggleDirection(vehicle)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil then return end
    local c = nil
    for _, cc in ipairs(entry.couplings) do if cc.isConnected then c = cc break end end
    if c == nil then return end
    if c.bridgeCoupling ~= nil then
        if self.onSprayerToggleDirection ~= nil then self:onSprayerToggleDirection(vehicle) end
        return
    end
    if c.activeLane ~= nil and c.activeLane.transfer then
        -- [SPS 1.0.1.8] TRANSFER: Load (into this tanker) <-> Unload (out of it); changing it stops the pump
        local cur = entry.state.transferDirection or SPS_SPRAYER_DIRECTION_FILL
        local dir = (cur == SPS_SPRAYER_DIRECTION_FILL) and SPS_SPRAYER_DIRECTION_DISCHARGE or SPS_SPRAYER_DIRECTION_FILL
        if g_server ~= nil then self:applyLiquidLaneTransferDirection(vehicle, dir) end
        SPSLiquidLaneTransferDirectionEvent.sendEvent(vehicle, dir)
        return
    end
    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsLiquidDirectionFixed"), 2000)
    end
end

function SlurryPipeManager:applyLiquidLaneTransferDirection(vehicle, direction)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil then return end
    if entry.state.valveOpen and g_server ~= nil then self:_llStopFlow(vehicle, "direction changed") end
    entry.state.transferDirection = direction
    llLog("transfer direction %s on %s", direction == SPS_SPRAYER_DIRECTION_FILL and "LOAD" or "UNLOAD", tostring(vehicle and vehicle.configFileName))
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Fitting ball valves (PHYSICAL pipes). R at a fitting = SPSLaneValveActivatable:run.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:onLaneFittingValveToggle(coupling)
    if coupling == nil then return end
    local owner = coupling.isVehicleSide and coupling.object or coupling.placeable
    if owner == nil then return end
    local open = not coupling.ballValveOpen
    if g_server ~= nil then self:applyLaneFittingValve(coupling, open) end
    SPSLaneFittingValveEvent.sendEvent(owner, coupling.id, open)
end

function SlurryPipeManager:applyLaneFittingValveById(object, couplingId, open)
    local c = self:_findLiquidLaneCouplingById(object, couplingId)
    if c ~= nil then self:applyLaneFittingValve(c, open) end
end

function SlurryPipeManager:applyLaneFittingValve(coupling, open)
    if coupling == nil or coupling.ballValveOpen == open then return end
    coupling.ballValveOpen = open
    -- the handle: valveAnimation if the config has one, else its connectorAnimation (older barn configs put the
    -- fitting's only handle there) - either way it is the VALVE in physical mode
    local anim = coupling.valveAnim or coupling.connectorAnim
    if SPSCouplerAnimator ~= nil and anim ~= nil then
        SPSCouplerAnimator.play(anim, open and 1 or -1)
    end
    local owner = coupling.isVehicleSide and coupling.object or coupling.placeable
    print(string.format("[SPS PHYS] fitting valve %s: coupling id=%s of %s%s", open and "OPEN" or "CLOSED",
        tostring(coupling.id), tostring(owner and owner.configFileName), anim ~= nil and "" or " (no handle animation on this fitting)"))
    if not open and coupling.isConnected and g_server ~= nil then
        -- a closed valve stops whichever tanker is pumping through this fitting
        local p = coupling.connectedPartnerCoupling
        if coupling.isVehicleSide then self:_llStopFlow(coupling.object, "fitting valve closed") end
        if p ~= nil and p.isVehicleSide then self:_llStopFlow(p.object, "fitting valve closed") end
    end
end

-- TRANSFER: src / dst by the pumping tanker's direction. Returns ok, warnKey, fillType, srcLevel, dstFree,
-- src, srcFillUnit, dst, dstFillUnit.
function SlurryPipeManager:_llEvaluateTransfer(vehicle, c)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    local p     = c ~= nil and c.connectedPartnerCoupling or nil
    local other = (p ~= nil and p.isVehicleSide) and p.object or nil
    if entry == nil or other == nil then return false, nil end
    local oEntry = self:getLiquidLaneVehicleEntry(other)
    if oEntry ~= nil and oEntry.state.valveOpen and not entry.state.valveOpen then return false, "warning_spsTransferPumping" end
    local dir = entry.state.transferDirection or SPS_SPRAYER_DIRECTION_FILL
    local src, srcFui, dst, dstFui
    if dir == SPS_SPRAYER_DIRECTION_FILL then
        src, srcFui, dst, dstFui = other, p.fillUnitIndex or 1, vehicle, c.fillUnitIndex or 1
    else
        src, srcFui, dst, dstFui = vehicle, c.fillUnitIndex or 1, other, p.fillUnitIndex or 1
    end
    local srcLvl = src.getFillUnitFillLevel ~= nil and (src:getFillUnitFillLevel(srcFui) or 0) or 0
    local ft     = src.getFillUnitFillType ~= nil and src:getFillUnitFillType(srcFui) or nil
    if srcLvl <= 0.001 or ft == nil or ft == FillType.UNKNOWN then
        return false, (src == vehicle) and "warning_spsAnimalWaterEmpty" or "warning_spsTransferOtherEmpty"
    end
    if not llLaneAcceptsHeld(c.activeLane, ft) then return false, "warning_spsTransferType" end
    if dst.getFillUnitAllowsFillType ~= nil and not dst:getFillUnitAllowsFillType(dstFui, ft) then return false, "warning_spsTransferType" end
    local dstLvl = dst.getFillUnitFillLevel ~= nil and (dst:getFillUnitFillLevel(dstFui) or 0) or 0
    local dstFt  = dst.getFillUnitFillType ~= nil and dst:getFillUnitFillType(dstFui) or nil
    if dstLvl > 0.001 and dstFt ~= ft then return false, "warning_spsTransferType" end
    local free = dst.getFillUnitFreeCapacity ~= nil and (dst:getFillUnitFreeCapacity(dstFui) or 0) or 0
    if free <= 0.001 then return false, (dst == vehicle) and "warning_spsLiquidTankFull" or "warning_spsTransferOtherFull" end
    return true, nil, ft, srcLvl, free, src, srcFui, dst, dstFui
end

function SlurryPipeManager:_llTickTransfer(entry, c, partner, dt)
    local vehicle = entry.object
    local ok, warnKey, ft, srcLvl, free, src, srcFui, dst, dstFui = self:_llEvaluateTransfer(vehicle, c)
    if not ok then
        self:_llStopFlow(vehicle, tostring(warnKey or "cannot transfer"))
        return
    end
    local amount = math.min((entry.litersPerSecond or 200) * dt * 0.001, srcLvl, free)
    if amount <= 0 then return end
    self:removeFromSource({ type = "FILL_UNIT_ONLY", vehicle = src, fillUnitIndex = srcFui }, amount, ft, src)
    self:addToSource({ type = "FILL_UNIT_ONLY", vehicle = dst, fillUnitIndex = dstFui }, amount, ft, dst)
end

-- What the control node shows: valveOpen and direction (SPS_SPRAYER_DIRECTION_*),
-- uniform across lanes so the prompts read the same at a barn and at a silo.
function SlurryPipeManager:getLiquidLaneDisplayState(vehicle)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil then return false, SPS_SPRAYER_DIRECTION_FILL, nil end
    local c = nil
    for _, cc in ipairs(entry.couplings) do if cc.isConnected then c = cc break end end
    if c == nil then return false, SPS_SPRAYER_DIRECTION_FILL, nil end
    if c.bridgeCoupling ~= nil then
        local st = self:_llBridgeState(vehicle)
        if st ~= nil then return st.valveOpen == true, st.direction or SPS_SPRAYER_DIRECTION_FILL, c.activeLane end
        return false, SPS_SPRAYER_DIRECTION_FILL, c.activeLane
    end
    local lane = c.activeLane
    if lane ~= nil and lane.transfer then
        return entry.state.valveOpen == true, entry.state.transferDirection or SPS_SPRAYER_DIRECTION_FILL, lane
    end
    local dir  = (lane ~= nil and lane.direction == "TO_BARN") and SPS_SPRAYER_DIRECTION_DISCHARGE or SPS_SPRAYER_DIRECTION_FILL
    return entry.state.valveOpen == true, dir, lane
end

function SlurryPipeManager:applyLiquidLaneValveState(vehicle, valveOpen)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil then return end
    entry.state.valveOpen = valveOpen
    for _, c in ipairs(entry.couplings) do
        if c.isConnected then
            c.valveOpen = valveOpen
            if c.connectedPartnerCoupling ~= nil then c.connectedPartnerCoupling.valveOpen = valveOpen end
            if SPSCouplerAnimator ~= nil and c.physPipe == nil then   -- physical pipes: the handle is the FITTING valve
                if c.valveAnim ~= nil then SPSCouplerAnimator.play(c.valveAnim, valveOpen and 1 or -1) end
                local p = c.connectedPartnerCoupling
                if p ~= nil and p.valveAnim ~= nil then SPSCouplerAnimator.play(p.valveAnim, valveOpen and 1 or -1) end
            end
        end
    end
    llLog("valve %s on %s", valveOpen and "OPEN" or "CLOSED", tostring(vehicle and vehicle.configFileName))
    -- [SPS 1.0.1.8] physical-pipe lane: pump state + both fitting valves (state change only)
    for _, c in ipairs(entry.couplings) do
        if c.isConnected and c.physPipe ~= nil then
            local p = c.connectedPartnerCoupling
            print(string.format("[SPS PHYS] pump %s on %s (%s): fitting valves here %s / far %s",
                valveOpen and "ON" or "OFF", tostring(vehicle and vehicle.configFileName),
                tostring(c.activeLane and c.activeLane.key), c.ballValveOpen and "open" or "closed",
                (p ~= nil and p.ballValveOpen) and "open" or "closed"))
        end
    end
end

-- Server-side auto stop with a reason.
function SlurryPipeManager:_llStopFlow(vehicle, reason)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil or not entry.state.valveOpen then return end
    self:applyLiquidLaneValveState(vehicle, false)
    if g_server ~= nil then SPSLiquidLaneValveStateEvent.sendEvent(vehicle, false) end
    print(string.format("%s flow stopped on %s: %s", SPS_LL_TAG, tostring(vehicle and vehicle.configFileName), tostring(reason)))
end

-- ---------------------------------------------------------------------------
-- Flow tick (server).
--   TO_BARN  : vehicle fill unit -> husbandry storage through the vanilla
--              UNLOADING station (listener fires: trough plane, thirst; farm access).
--   FROM_BARN: husbandry storage -> vehicle through the vanilla LOADING station
--              (the milk load trigger's own path), credited via the bypass-safe
--              addToSource so shadowed tool-type gates cannot swallow it.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:tickLiquidLaneFlow(entry, dt)
    local vehicle = entry.object
    local c = nil
    for _, cc in ipairs(entry.couplings) do if cc.isConnected and cc.valveOpen then c = cc break end end
    if c == nil then return end   -- pump off: updateLiquidLanes runs _llTickGravity instead
    local partner = c.connectedPartnerCoupling
    if partner == nil then return end
    -- [SPS 1.0.1.8] physical pipes: both fitting valves must stay open
    if c.physPipe ~= nil and (not c.ballValveOpen or not partner.ballValveOpen) then
        self:_llStopFlow(vehicle, "fitting valve closed")
        return
    end
    if c.activeLane ~= nil and c.activeLane.transfer then
        self:_llTickTransfer(entry, c, partner, dt)
        return
    end
    if partner.placeable == nil then return end
    local placeable = partner.placeable
    local pEntry    = self:getLiquidLanePlaceableEntry(placeable)
    if pEntry == nil or pEntry.storage == nil then return end
    local lane = c.activeLane or partner.lane
    if lane == nil then return end

    local ok, warnKey, fillType, srcLevel, dstFree = self:_llEvaluate(vehicle, c)
    if not ok then
        self:_llStopFlow(vehicle, tostring(warnKey or "cannot flow"))
        return
    end
    -- the pump moves liquid regardless of the surface heights (uphill is what it is for)
    local moved, reason = self:_llMoveLiquid(entry, c, lane, pEntry, fillType, srcLevel, dstFree, dt, 1.0)
    if not moved and reason ~= nil then self:_llStopFlow(vehicle, reason) end
end

-- One tick of liquid between the vehicle's fill unit and the barn, in the lane's direction.
-- rateFactor scales entry.litersPerSecond (1.0 = pump; gravity tapers with the head).
-- Returns true when something moved; false + reason when the barn refused (nil reason = nothing to do).
function SlurryPipeManager:_llMoveLiquid(entry, c, lane, pEntry, fillType, srcLevel, dstFree, dt, rateFactor)
    local vehicle   = entry.object
    local placeable = pEntry.placeable
    local fui    = c.fillUnitIndex or 1
    local lps    = (entry.litersPerSecond or 200) * (rateFactor or 1.0)
    local amount = math.min(lps * dt * 0.001, srcLevel, dstFree)
    if amount <= 0 then return false, nil end
    local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil

    if lane.direction == "TO_BARN" then
        local moved = 0
        if placeable.addHusbandryFillLevelFromTool ~= nil then
            moved = placeable:addHusbandryFillLevelFromTool(farmId, amount, fillType, nil, ToolType.TRIGGER, nil) or 0
        end
        if moved <= 0 then
            -- Station refused. "Unload trigger does not list this type" (author declared
            -- the storage but not the trigger) => write the storage directly, the
            -- listener still fires. Anything else (farm access) => stop.
            local station = placeable.spec_husbandry.unloadingStation
            local typeAllowed = station == nil or station.getIsFillTypeAllowed == nil or station:getIsFillTypeAllowed(fillType)
            if not typeAllowed then
                local old = pEntry.storage:getFillLevel(fillType) or 0
                pEntry.storage:setFillLevel(old + amount, fillType)
                moved = (pEntry.storage:getFillLevel(fillType) or 0) - old
            end
            if moved <= 0 then
                return false, "barn refused the liquid (farm access?)"
            end
        end
        self:removeFromSource({ type = "FILL_UNIT_ONLY", vehicle = vehicle, fillUnitIndex = fui }, moved, fillType, vehicle)
    else
        local remaining = amount
        if placeable.removeHusbandryFillLevel ~= nil then
            remaining = placeable:removeHusbandryFillLevel(farmId, amount, fillType) or amount
        else
            local old = pEntry.storage:getFillLevel(fillType) or 0
            pEntry.storage:setFillLevel(math.max(0, old - amount), fillType)
            remaining = amount - (old - (pEntry.storage:getFillLevel(fillType) or 0))
        end
        local drawn = amount - remaining
        if drawn <= 0 then
            return false, "barn refused the draw (farm access?)"
        end
        self:addToSource({ type = "FILL_UNIT_ONLY", vehicle = vehicle, fillUnitIndex = fui }, drawn, fillType, vehicle)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] GRAVITY on the 80 mm lanes (William 2026-10-18: "the same gravity system that slurry uses -
-- if the valves are open the product will flow"). PHYSICAL pipes only, pump OFF, both fitting valves open.
-- Surface heights: a tank's liquid surface = tankBottomNode + level / capacity * (tankTopNode - tankBottomNode)
-- (coupling attributes tankTopNodeName / tankBottomNodeName). Vehicle side falls back to the slurry helper
-- (_equaliseSurfaceWorldY: surfaceRef or the fill volume) when the connector has no tank nodes.
-- Rule (mirrors _equalisePairStore): the liquid runs in the lane's direction only when the driving surface is
-- above the receiving surface AND above both couplers' head height nodes (a crest gravity cannot beat - no
-- siphon). Rate tapers with the head like slurry. B (the pump) ignores all of this.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_llTankSurfaceY(coupling, level, capacity)
    if coupling == nil or coupling.tankTopNode == nil or coupling.tankBottomNode == nil then return nil end
    if not entityExists(coupling.tankTopNode) or not entityExists(coupling.tankBottomNode) then return nil end
    if capacity == nil or capacity <= 0 then return nil end
    local frac = math.clamp((level or 0) / capacity, 0, 1)
    local _, bY, _ = getWorldTranslation(coupling.tankBottomNode)
    local _, tY, _ = getWorldTranslation(coupling.tankTopNode)
    return bY + (tY - bY) * frac
end

function SlurryPipeManager:_llVehicleSurfaceY(vehicle, c)
    local fui = c.fillUnitIndex or 1
    local lvl = vehicle.getFillUnitFillLevel ~= nil and (vehicle:getFillUnitFillLevel(fui) or 0) or 0
    local cap = vehicle.getFillUnitCapacity ~= nil and (vehicle:getFillUnitCapacity(fui) or 0) or 0
    local y = self:_llTankSurfaceY(c, lvl, cap)
    if y ~= nil then return y, "tank nodes" end
    if self._equaliseSurfaceWorldY ~= nil then
        y = self:_equaliseSurfaceWorldY(vehicle, { fillUnitIndex = fui })
        if y ~= nil then return y, "fill volume" end
    end
    return nil
end

function SlurryPipeManager:_llBarnSurfaceY(coupling, storage, fillType)
    if storage == nil or fillType == nil then return nil end
    local lvl = storage.getFillLevel ~= nil and (storage:getFillLevel(fillType) or 0) or 0
    local free = storage.getFreeCapacity ~= nil and (storage:getFreeCapacity(fillType) or 0) or 0
    return self:_llTankSurfaceY(coupling, lvl, lvl + free)
end

-- START (with the numbers) / STOP (with the reason) per vehicle; while running an UPDATE line at most every 10 s
SlurryPipeManager.LL_GRAVITY_LOG_MS = 10000
function SlurryPipeManager:_llGravityState(entry, active, reason)
    local st = entry.state
    if st == nil then return end
    local now = g_time or 0
    local name = tostring(entry.object and entry.object.configFileName)
    if active then
        if not st._gravActive then
            print(string.format("[SPS PHYS] gravity flow START on %s: %s", name, tostring(reason)))
            st._gravNextLog = now + SlurryPipeManager.LL_GRAVITY_LOG_MS
        elseif st._gravNextLog ~= nil and now >= st._gravNextLog then
            print(string.format("[SPS PHYS] gravity flow UPDATE on %s: %s", name, tostring(reason)))
            st._gravNextLog = now + SlurryPipeManager.LL_GRAVITY_LOG_MS
        end
    elseif st._gravActive then
        print(string.format("[SPS PHYS] gravity flow STOP on %s: %s", name, tostring(reason)))
    elseif SPSDebugConfig ~= nil and SPSDebugConfig.isOn ~= nil and SPSDebugConfig.isOn("SPSM_LiquidLanes")
       and st._gravReason ~= reason then
        print(string.format("[SPS PHYS] gravity idle on %s: %s", name, tostring(reason)))
    end
    st._gravActive = active
    st._gravReason = reason
end

-- TRANSFER by gravity: THIS tanker is the source (its surface is the higher one). Returns ok, reason, ft,
-- srcLevel, dstFree, srcFui, dstFui. The receiving tanker's own tick sees itself as the low side and idles.
function SlurryPipeManager:_llEvaluateGravityTransfer(vehicle, c, other, p)
    local srcFui, dstFui = c.fillUnitIndex or 1, p.fillUnitIndex or 1
    local srcLvl = vehicle.getFillUnitFillLevel ~= nil and (vehicle:getFillUnitFillLevel(srcFui) or 0) or 0
    local ft     = vehicle.getFillUnitFillType ~= nil and vehicle:getFillUnitFillType(srcFui) or nil
    if srcLvl <= 0.001 or ft == nil or ft == FillType.UNKNOWN then return false, "tank is empty" end
    if not llLaneAcceptsHeld(c.activeLane, ft) then return false, "tank holds neither water nor milk" end
    if other.getFillUnitAllowsFillType ~= nil and not other:getFillUnitAllowsFillType(dstFui, ft) then
        return false, "the other tank does not take this liquid"
    end
    local dstLvl = other.getFillUnitFillLevel ~= nil and (other:getFillUnitFillLevel(dstFui) or 0) or 0
    local dstFt  = other.getFillUnitFillType ~= nil and other:getFillUnitFillType(dstFui) or nil
    if dstLvl > 0.001 and dstFt ~= ft then return false, "the tanks hold different liquids" end
    local free = other.getFillUnitFreeCapacity ~= nil and (other:getFillUnitFreeCapacity(dstFui) or 0) or 0
    if free <= 0.001 then return false, "the other tank is full" end
    return true, nil, ft, srcLvl, free, srcFui, dstFui
end

function SlurryPipeManager:_llTickGravity(entry, dt)
    if self.physicalPipesEnabled ~= true then return end
    local vehicle = entry.object
    local c = nil
    for _, cc in ipairs(entry.couplings) do
        if cc.isConnected and cc.physPipe ~= nil and cc.bridgeCoupling == nil then c = cc break end
    end
    if c == nil then
        if entry.state ~= nil and entry.state._gravActive then self:_llGravityState(entry, false, "disconnected") end
        return
    end
    local partner = c.connectedPartnerCoupling
    if partner == nil then return end
    local lane = c.activeLane or partner.lane
    if lane == nil or lane.bridge then return end
    if not c.ballValveOpen or not partner.ballValveOpen then
        return self:_llGravityState(entry, false, "fitting valve closed")
    end
    local deadband = SlurryPipeManager.EQUALISE_HEAD_DEADBAND or 0.0015
    local taper    = SlurryPipeManager.EQUALISE_TAPER_HEAD or 0.30

    if lane.transfer or partner.isVehicleSide then
        -- TANKER TO TANKER: the higher surface drains into the lower one (either way), unless a pump runs
        local other = partner.object
        local oEntry = other ~= nil and self:getLiquidLaneVehicleEntry(other) or nil
        if other == nil or oEntry == nil then return end
        if oEntry.state.valveOpen then return self:_llGravityState(entry, false, "the other tanker is pumping") end
        local yA, howA = self:_llVehicleSurfaceY(vehicle, c)
        local yB, howB = self:_llVehicleSurfaceY(other, partner)
        if yA == nil then return self:_llGravityState(entry, false, "this tanker has no tankTop / tankBottom nodes and no fill volume") end
        if yB == nil then return self:_llGravityState(entry, false, "the other tanker has no tankTop / tankBottom nodes and no fill volume") end
        local head = yA - yB
        if head <= deadband then
            return self:_llGravityState(entry, false, string.format("this tank is the low side (y=%.2f, other y=%.2f)", yA, yB))
        end
        if c.headHeightNode ~= nil and entityExists(c.headHeightNode) then
            local _, hy, _ = getWorldTranslation(c.headHeightNode)
            if yA <= hy then return self:_llGravityState(entry, false, string.format("surface %.2f below this head height node %.2f", yA, hy)) end
        end
        if partner.headHeightNode ~= nil and entityExists(partner.headHeightNode) then
            local _, hy, _ = getWorldTranslation(partner.headHeightNode)
            if yA <= hy then return self:_llGravityState(entry, false, string.format("surface %.2f below the other head height node %.2f", yA, hy)) end
        end
        local ok, reason, ft, srcLvl, free, srcFui, dstFui = self:_llEvaluateGravityTransfer(vehicle, c, other, partner)
        if not ok then return self:_llGravityState(entry, false, reason) end
        local factor = math.clamp(head / taper, 0.1, 1.0)
        self:_llGravityState(entry, true, string.format("TRANSFER to %s, this y=%.2f (%s) other y=%.2f (%s) head=%.2f m rate x%.2f",
            tostring(other.configFileName), yA, tostring(howA), yB, tostring(howB), head, factor))
        local amount = math.min((entry.litersPerSecond or 200) * factor * dt * 0.001, srcLvl, free)
        if amount <= 0 then return end
        self:removeFromSource({ type = "FILL_UNIT_ONLY", vehicle = vehicle, fillUnitIndex = srcFui }, amount, ft, vehicle)
        self:addToSource({ type = "FILL_UNIT_ONLY", vehicle = other, fillUnitIndex = dstFui }, amount, ft, other)
        return
    end

    if partner.placeable == nil then return end
    local pEntry = self:getLiquidLanePlaceableEntry(partner.placeable)
    if pEntry == nil or pEntry.storage == nil then return end

    local ok, warnKey, fillType, srcLevel, dstFree = self:_llEvaluate(vehicle, c)
    if not ok then return self:_llGravityState(entry, false, tostring(warnKey or "cannot flow")) end

    local yV, how = self:_llVehicleSurfaceY(vehicle, c)
    if yV == nil then return self:_llGravityState(entry, false, "vehicle has no tankTop / tankBottom nodes and no fill volume") end
    local yB = self:_llBarnSurfaceY(partner, pEntry.storage, fillType)
    if yB == nil then return self:_llGravityState(entry, false, "barn coupler has no tankTop / tankBottom nodes") end

    local yHi, yLo
    if lane.direction == "TO_BARN" then yHi, yLo = yV, yB else yHi, yLo = yB, yV end
    local head = yHi - yLo
    if head <= deadband then
        return self:_llGravityState(entry, false, string.format("level - receiving surface is as high or higher (tank y=%.2f barn y=%.2f)", yV, yB))
    end
    -- crests: the driving surface must clear the highest point of BOTH pipe runs
    if c.headHeightNode ~= nil and entityExists(c.headHeightNode) then
        local _, hy, _ = getWorldTranslation(c.headHeightNode)
        if yHi <= hy then return self:_llGravityState(entry, false, string.format("driving surface %.2f below the vehicle head height node %.2f", yHi, hy)) end
    end
    if partner.headHeightNode ~= nil and entityExists(partner.headHeightNode) then
        local _, hy, _ = getWorldTranslation(partner.headHeightNode)
        if yHi <= hy then return self:_llGravityState(entry, false, string.format("driving surface %.2f below the barn head height node %.2f", yHi, hy)) end
    end

    local factor = math.clamp(head / taper, 0.1, 1.0)
    self:_llGravityState(entry, true, string.format("%s lane, tank y=%.2f (%s) barn y=%.2f head=%.2f m rate x%.2f",
        tostring(lane.key), yV, tostring(how), yB, head, factor))
    local moved, reason = self:_llMoveLiquid(entry, c, lane, pEntry, fillType, srcLevel, dstFree, dt, factor)
    if not moved and reason ~= nil then self:_llGravityState(entry, false, reason) end
end

-- ---------------------------------------------------------------------------
-- Per-frame update (called from SPSMod:update after updateSprayers)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:updateLiquidLanes(dt)
    if self.activeLiquidLanePipes == nil then return end
    if g_spsLiquidLanePipeVisual ~= nil then
        for _, pipeData in pairs(self.activeLiquidLanePipes) do
            if pipeData.couplingA.mountNode ~= nil and pipeData.couplingB.mountNode ~= nil then
                g_spsLiquidLanePipeVisual:updatePipe(pipeData.inst)
            end
        end
    end
    self:_llReconcileBridges()

    -- Tick coupler animations (connector + valve) for this system's couplings on
    -- EVERY peer. The manager's animator loop only covers slurry and sprayer
    -- couplings, so without this play() set a direction and nothing ever moved
    -- (William's MKS 8 test, 2026-09-28). A bridged connector's instances are the
    -- bridge coupling's own, already ticked by the sprayer loop — skip those.
    if SPSCouplerAnimator ~= nil then
        for _, vEntry in ipairs(self.registeredLiquidLaneVehicles) do
            for _, c in ipairs(vEntry.couplings) do
                if c.bridgeCoupling == nil then
                    if c.connectorAnim ~= nil then SPSCouplerAnimator.update(c.connectorAnim, dt) end
                    if c.valveAnim     ~= nil then SPSCouplerAnimator.update(c.valveAnim,     dt) end
                end
            end
        end
        for _, pEntry in ipairs(self.registeredLiquidLanePlaceables) do
            for _, c in ipairs(pEntry.couplings) do
                if c.connectorAnim ~= nil then SPSCouplerAnimator.update(c.connectorAnim, dt) end
                if c.valveAnim     ~= nil then SPSCouplerAnimator.update(c.valveAnim,     dt) end
            end
        end
    end
    if g_server == nil then return end

    for _, entry in ipairs(self.registeredLiquidLaneVehicles) do
        if entry.state.valveOpen then
            self:tickLiquidLaneFlow(entry, dt)
        elseif self.physicalPipesEnabled == true then
            self:_llTickGravity(entry, dt)   -- [SPS 1.0.1.8] pump off: gravity through open fitting valves
        end
    end

    -- Stretch check every 10 ticks, same rule as the sprayer hose. Bridged
    -- connections are stretched-checked by the sprayer loop; reconciled below.
    self._llDistCheckTick = (self._llDistCheckTick or 0) + 1
    if self._llDistCheckTick >= 10 then
        self._llDistCheckTick = 0
        for _, entry in ipairs(self.registeredLiquidLaneVehicles) do
            for _, c in ipairs(entry.couplings) do
                local p = c.connectedPartnerCoupling
                -- [SPS 1.0.1.8] a PHYSICAL pipe has its own overstretch rule (SPSHoseItem) - skip it here
                if c.isConnected and c.bridgeCoupling == nil and c.physPipe == nil and c.mountNode ~= nil and p ~= nil and p.mountNode ~= nil then
                    local ax, ay, az = getWorldTranslation(c.mountNode)
                    local bx, by, bz = getWorldTranslation(p.mountNode)
                    if MathUtil.vector3Length(ax - bx, ay - by, az - bz) > (c.maxPipeLength or 7.5) then
                        self:applyLiquidLaneDisconnect(entry.object, c.id, c)
                        SPSLiquidLaneDisconnectEvent.sendEvent(entry.object, c.id)
                    end
                end
            end
        end
    end
end

-- Runs on every peer, every frame: when the sprayer code dropped a bridged
-- connection on its side (its stretch check, a sold silo, the IBC deleted), clear
-- ours too. Cheap: only bridged vehicles are looked at.
function SlurryPipeManager:_llReconcileBridges()
    if self.activeLiquidLaneBridges == nil then return end
    for vehicle, b in pairs(self.activeLiquidLaneBridges) do
        local cV = b.cV
        local bc = cV ~= nil and cV.bridgeCoupling or nil
        if cV == nil or bc == nil or not bc.isConnected then
            if cV ~= nil then self:applyLiquidLaneDisconnect(vehicle, cV.id, cV) end
            self.activeLiquidLaneBridges[vehicle] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Join dump: re-send live hoses and open valves to a freshly joined connection.
-- Bridged (SPRAYER lane) connections are sent from HERE with their lane id — the
-- sprayer join dump skips bridge entries — followed by the sprayer-side state.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:sendLiquidLaneJoinState(connection)
    if connection == nil or self.activeLiquidLanePipes == nil then return end
    if SPSLiquidLaneConnectEvent ~= nil then
        for _, p in pairs(self.activeLiquidLanePipes) do
            local cV, cP = p.couplingA, p.couplingB
            if cV ~= nil and cP ~= nil and cV.object ~= nil and cP.placeable ~= nil and cP.lane ~= nil then
                connection:sendEvent(SPSLiquidLaneConnectEvent.new(cV.object, cV.id, cP.placeable, cP.id, cP.lane.id))
            end
        end
        for vehicle, b in pairs(self.activeLiquidLaneBridges or {}) do
            local cV, cP = b.cV, b.cP
            if cV ~= nil and cP ~= nil and vehicle ~= nil and b.owner ~= nil then
                connection:sendEvent(SPSLiquidLaneConnectEvent.new(vehicle, cV.id, b.owner, cP.id, SPS_LIQUID_LANES.SPRAYER.id))
                local st = self:_llBridgeState(vehicle)
                if st ~= nil then
                    if st.pumpRunning == true and SPSSprayerPumpStateEvent ~= nil then
                        connection:sendEvent(SPSSprayerPumpStateEvent.new(vehicle, true))
                    end
                    if st.valveOpen == true and SPSSprayerValveStateEvent ~= nil then
                        connection:sendEvent(SPSSprayerValveStateEvent.new(vehicle, true))
                    end
                    if st.direction ~= nil and SPSSprayerDirectionEvent ~= nil then
                        connection:sendEvent(SPSSprayerDirectionEvent.new(vehicle, st.direction))
                    end
                end
            end
        end
    end
    if SPSLiquidLaneValveStateEvent ~= nil then
        for _, entry in ipairs(self.registeredLiquidLaneVehicles) do
            if entry.state.valveOpen and entry.object ~= nil then
                connection:sendEvent(SPSLiquidLaneValveStateEvent.new(entry.object, true))
            end
        end
    end
    -- [SPS 1.0.1.8 MP] physical pipes: every OPEN fitting ball valve (R at the fitting) and each tanker's transfer
    -- direction (Y) - a late joiner otherwise sees every handle closed and the default direction. The physical
    -- plugs themselves were re-sent by sendFullStateToConnection pass 3a before this.
    if SPSLaneFittingValveEvent ~= nil then
        for _, entry in ipairs(self.registeredLiquidLaneVehicles) do
            for _, c in ipairs(entry.couplings or {}) do
                if c.ballValveOpen and entry.object ~= nil then
                    connection:sendEvent(SPSLaneFittingValveEvent.new(entry.object, c.id, true))
                end
            end
        end
        for _, entry in ipairs(self.registeredLiquidLanePlaceables or {}) do
            for _, c in ipairs(entry.couplings or {}) do
                if c.ballValveOpen and entry.object ~= nil then
                    connection:sendEvent(SPSLaneFittingValveEvent.new(entry.object, c.id, true))
                end
            end
        end
    end
    if SPSLiquidLaneTransferDirectionEvent ~= nil then
        for _, entry in ipairs(self.registeredLiquidLaneVehicles) do
            if entry.object ~= nil and entry.state ~= nil and entry.state.transferDirection ~= nil then
                connection:sendEvent(SPSLiquidLaneTransferDirectionEvent.new(entry.object, entry.state.transferDirection))
            end
        end
    end
end

-- Mission end cleanup (called from SlurryPipeManager:delete)
function SlurryPipeManager:_llDeleteAll()
    if self.activeLiquidLanePipes ~= nil and g_spsLiquidLanePipeVisual ~= nil then
        for _, pipeData in pairs(self.activeLiquidLanePipes) do
            if pipeData.inst ~= nil then g_spsLiquidLanePipeVisual:destroyPipe(pipeData.inst) end
        end
    end
    self.registeredLiquidLaneVehicles   = {}
    self.registeredLiquidLanePlaceables = {}
    self.activeLiquidLanePipes          = {}
    self._pendingLiquidLaneConnects     = {}
    self.activeLiquidLaneBridges        = {}
end

-- ---------------------------------------------------------------------------
-- Savegame persistence (William: hoses survive a reload on every lane). Same
-- scheme as slurry: both mount-node world positions + valve state, restored by
-- position match (0.1 m) as vehicles and barns register, retried for the first
-- 300 update ticks because vehicle positions settle after onFinishedLoading.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_saveLiquidLaneConnections(xmlFile)
    local idx = 0
    for _, vEntry in ipairs(self.registeredLiquidLaneVehicles or {}) do
        for _, cV in ipairs(vEntry.couplings) do
            local cP = cV.connectedPartnerCoupling
            -- [SPS 1.0.1.8] a connection made by a PHYSICAL pipe is saved by the pipe itself (SPSHoseItem) and
            -- re-made when its ends are restored - never here (it would come back as a drawn hose).
            if cV.isConnected and cP ~= nil and cV.physPipe == nil and cP.physPipe == nil and cV.mountNode ~= nil and cP.mountNode ~= nil
            and entityExists(cV.mountNode) and entityExists(cP.mountNode) and cV.activeLane ~= nil then
                local ax, ay, az = getWorldTranslation(cV.mountNode)
                local bx, by, bz = getWorldTranslation(cP.mountNode)
                local base = string.format("slurryPipeSystem.liquidConnections.connection(%d)", idx)
                xmlFile:setFloat(base .. "#ax", ax); xmlFile:setFloat(base .. "#ay", ay); xmlFile:setFloat(base .. "#az", az)
                xmlFile:setFloat(base .. "#bx", bx); xmlFile:setFloat(base .. "#by", by); xmlFile:setFloat(base .. "#bz", bz)
                xmlFile:setInt(base .. "#lane", cV.activeLane.id)
                local valveOpen, direction = vEntry.state.valveOpen == true, SPS_SPRAYER_DIRECTION_FILL
                if cV.bridgeCoupling ~= nil then
                    local st = self:_llBridgeState(vEntry.object)
                    if st ~= nil then valveOpen = st.valveOpen == true; direction = st.direction or direction end
                end
                xmlFile:setBool(base .. "#valveOpen", valveOpen)
                xmlFile:setInt (base .. "#direction", direction)
                idx = idx + 1
            end
        end
    end
    llLog("_saveLiquidLaneConnections: wrote %d", idx)
end

function SlurryPipeManager:_loadLiquidLaneConnections(xmlFile)
    self._pendingSavedLiquidLaneConnects = {}
    local idx = 0
    while true do
        local base = string.format("slurryPipeSystem.liquidConnections.connection(%d)", idx)
        if not xmlFile:hasProperty(base) then break end
        table.insert(self._pendingSavedLiquidLaneConnects, {
            ax = xmlFile:getFloat(base .. "#ax", 0), ay = xmlFile:getFloat(base .. "#ay", 0), az = xmlFile:getFloat(base .. "#az", 0),
            bx = xmlFile:getFloat(base .. "#bx", 0), by = xmlFile:getFloat(base .. "#by", 0), bz = xmlFile:getFloat(base .. "#bz", 0),
            valveOpen = xmlFile:getBool(base .. "#valveOpen", false),
            laneId    = xmlFile:getInt(base .. "#lane", 0),
            direction = xmlFile:getInt(base .. "#direction", SPS_SPRAYER_DIRECTION_FILL),
        })
        idx = idx + 1
    end
    llLog("_loadLiquidLaneConnections: %d pending", idx)
end

function SlurryPipeManager:_findLiquidLaneCouplingAtPos(wx, wy, wz, wantVehicle)
    local TOL_SQ = 0.1 * 0.1
    local function near(c)
        if c.mountNode == nil or not entityExists(c.mountNode) then return false end
        local cx, cy, cz = getWorldTranslation(c.mountNode)
        local dx, dy, dz = cx - wx, cy - wy, cz - wz
        return dx*dx + dy*dy + dz*dz <= TOL_SQ
    end
    if wantVehicle then
        for _, vEntry in ipairs(self.registeredLiquidLaneVehicles) do
            for _, c in ipairs(vEntry.couplings) do
                if near(c) then return c, vEntry.object end
            end
        end
    else
        for _, pEntry in ipairs(self.registeredLiquidLanePlaceables) do
            for _, c in ipairs(pEntry.couplings) do
                if near(c) then return c, pEntry.object end
            end
        end
    end
    return nil, nil
end

function SlurryPipeManager:_tryResolveSavedLiquidLaneConnects()
    local list = self._pendingSavedLiquidLaneConnects
    if list == nil or #list == 0 then return end
    local kept = {}
    for _, p in ipairs(list) do
        local cV, vehicle   = self:_findLiquidLaneCouplingAtPos(p.ax, p.ay, p.az, true)
        local lane = llLaneById(p.laneId)
        local cP, placeable
        if lane ~= nil and lane.bridge then
            if self._findSprayerCouplingAtPos ~= nil then
                cP, placeable = self:_findSprayerCouplingAtPos(p.bx, p.by, p.bz)
            end
        else
            cP, placeable = self:_findLiquidLaneCouplingAtPos(p.bx, p.by, p.bz, false)
            if cP ~= nil then lane = cP.lane end
        end
        if cV ~= nil and cP ~= nil and lane ~= nil and not cV.isConnected and not cP.isConnected then
            self:applyLiquidLaneConnect(cV, cP, vehicle, placeable, lane)
            if lane.bridge then
                local st, bc = self:_llBridgeState(vehicle)
                if st ~= nil then
                    st.direction = p.direction or SPS_SPRAYER_DIRECTION_FILL
                    if p.valveOpen then
                        st.valveOpen = true; st.pumpRunning = true
                        if bc ~= nil then bc.valveOpen = true end
                        if cP ~= nil then cP.valveOpen = true end
                    end
                end
            elseif p.valveOpen then
                -- Re-check the lane rules before reopening; a save made mid-transfer
                -- may have emptied the tank in the same tick it was written.
                local ok = self:_llEvaluate(vehicle, cV)
                if ok then self:applyLiquidLaneValveState(vehicle, true) end
            end
            llLog("_tryResolveSavedLiquidLaneConnects: restored hose idV=%s idP=%s lane=%s",
                tostring(cV.id), tostring(cP.id), tostring(lane.key))
        else
            table.insert(kept, p)
        end
    end
    self._pendingSavedLiquidLaneConnects = kept
end
