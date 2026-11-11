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

-- [SPS MKS8 2026-11-10] ONE fitting, several tanks (<liquidPipeCoupling> with <tank id fillUnitIndex name
-- tankTopNodeName tankBottomNodeName/> children): the coupling always routes to the SELECTED tank - its fillUnitIndex
-- and gravity nodes are copied onto the coupling, so every reader of c.fillUnitIndex stays as it is. Y at the control
-- node cycles the tanks (onLiquidLaneToggleDirection); saved in liquidTankSelections, synced by SPSLiquidLaneTankSelectEvent.
function SlurryPipeManager._llApplyTankToCoupling(c, idx)
    local t = c ~= nil and c.tanks ~= nil and c.tanks[idx] or nil
    if t == nil then return false end
    c.selectedTank  = idx
    c.fillUnitIndex = t.fillUnitIndex or c.fillUnitIndex or 1
    if t.tankTopNode    ~= nil then c.tankTopNode    = t.tankTopNode end
    if t.tankBottomNode ~= nil then c.tankBottomNode = t.tankBottomNode end
    if c.bridgeCoupling ~= nil then c.bridgeCoupling.fillUnitIndex = c.fillUnitIndex end
    return true
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
                -- [SPS 1.0.2.0] vehicle <animations> names (time 0 closed, 1 open) that follow THIS fitting's
                -- valve (Kotte TSA: the tank valves behind the water coupler); demand-counted, see SPSM_Flow
                valveAnimationNames      = SlurryPipeManager.splitAnimationNames(xmlFile:getString(cKey .. "#valveAnimations")),
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
                -- [SPS MKS8 2026-11-10] <tank> children: see _llApplyTankToCoupling
                local tIdx = 0
                while true do
                    local tKey = string.format(cKey .. ".tank(%d)", tIdx)
                    if not xmlFile:hasProperty(tKey) then break end
                    c.tanks = c.tanks or {}
                    table.insert(c.tanks, {
                        id             = xmlFile:getInt(tKey .. "#id", tIdx + 1),
                        fillUnitIndex  = xmlFile:getInt(tKey .. "#fillUnitIndex", tIdx + 1),
                        name           = xmlFile:getString(tKey .. "#name"),
                        tankTopNode    = findLinkedNode(xmlFile:getString(tKey .. "#tankTopNodeName")),
                        tankBottomNode = findLinkedNode(xmlFile:getString(tKey .. "#tankBottomNodeName")),
                    })
                    tIdx = tIdx + 1
                end
                if c.tanks ~= nil then SlurryPipeManager._llApplyTankToCoupling(c, 1) end
                -- [SPS 2026-11-09] BOWSER fittings (550 Water/Chem Bowser) - a fitting that takes only its own pipes:
                --   #acceptPipes="WT_SUCTION WT_SMALL"  hose keys allowed on this fitting (nothing else plugs in)
                --   #acceptEnd="start" | "end"           which pipe end (start = gender "bowser", end = "water")
                --   #waterSource="WT_SUCTION"            that pipe's free far end in a water course = INTAKE (B = pump)
                --   #washOutlet="WT_WASH"                that pipe's free far end POURS the tank out where it lies (B = pump)
                --   #washLitersPerSecond                 pour rate of the wash hose (default 40)
                --   #connectorAnimationName              VEHICLE animation held open while a pipe is plugged in / connected
                local ap = xmlFile:getString(cKey .. "#acceptPipes")
                if ap ~= nil and ap ~= "" then
                    c.acceptPipes, c.acceptPipesText = {}, ap
                    for k in ap:gmatch("%S+") do c.acceptPipes[string.upper(k)] = true end
                end
                local ae = xmlFile:getString(cKey .. "#acceptEnd")
                if ae == "start" then c.acceptGender = "bowser" elseif ae == "end" then c.acceptGender = "water" end
                c.waterSourceKey      = xmlFile:getString(cKey .. "#waterSource")
                c.washOutletKey       = xmlFile:getString(cKey .. "#washOutlet")
                c.washLitersPerSecond = xmlFile:getFloat(cKey .. "#washLitersPerSecond", 40)
                c.connectorAnimName   = xmlFile:getString(cKey .. "#connectorAnimationName")
                c.stowedVisualName    = xmlFile:getString(cKey .. "#stowedVisual")   -- [2026-11-09] rack visual hidden while the pipe is in use (original mode)
                -- [SPS MKS8 2026-11-10] valve="false": a fitting with NO valve of its own (the MKS 8 dual tank). No R prompt in
                -- pipe mode; its ballValveOpen simply follows "a pipe is plugged in" (lane tick), so flow / leak / disconnect
                -- rules behave as with a valve the player opened on plugging and closed on unplugging.
                c.hasValve = xmlFile:getBool(cKey .. "#valve", true)
                if c.waterSourceKey ~= nil then c.waterSourceKey = string.upper(c.waterSourceKey) end
                if c.washOutletKey ~= nil then c.washOutletKey = string.upper(c.washOutletKey) end
                -- [SPS 2026-11-10] the fitting's PARTNER hose (original mode): the accept-list key that is neither the suction
                -- nor the wash hose (550 bowser: WT_SMALL) - a fitting with its own pipes connects with ITS hose, never the generic
                for k in pairs(c.acceptPipes or {}) do
                    if k ~= c.waterSourceKey and k ~= c.washOutletKey then c.partnerHoseKey = k end
                end
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
                SlurryPipeManager.gateAdd(c.valveActivatable)
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
            -- [SPS MKS8 2026-11-10] a multi-tank fitting serves every lane ANY of its tanks accepts
            local units = {}
            for _, t in ipairs(c.tanks or {}) do units[#units + 1] = t.fillUnitIndex end
            if #units == 0 then units[1] = c.fillUnitIndex end
            for _, k in ipairs(SPS_LL_LANE_ORDER) do
                local lane = SPS_LIQUID_LANES[k]
                for _, fui in ipairs(units) do
                    for _, ft in ipairs(llLaneFillTypes(lane)) do
                        if vehicle.getFillUnitAllowsFillType ~= nil and vehicle:getFillUnitAllowsFillType(fui, ft) then
                            c.lanes[k] = true
                            break
                        end
                    end
                    if c.lanes[k] then break end
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
    -- [SPS MKS8 2026-11-10] <loadAnimation name="rearDoor" doorCloseAuto="false" textOpen="$l10n_.." textClose="$l10n_.."/>:
    -- a door / cover that must be OPEN before anything connects to this vehicle's fittings - the sprayer's loadAnimation,
    -- lane edition. Pipe mode: SPSM_PhysPipes refuses a plug while loadAnimPlayed is false (generic check); original mode:
    -- onLiquidLaneConnect. N at the control node opens / closes it (onLiquidLaneToggleDoor, SPSLiquidLaneDoorEvent), closing
    -- is refused with anything on a fitting. doorCloseAuto (default true) closes it after a disconnect / unplug.
    local doorName = xmlFile:getString(kp .. "loadAnimation#name")
    if doorName ~= nil and doorName ~= "" then
        if vehicle.getAnimationExists == nil or not vehicle:getAnimationExists(doorName) then
            print(string.format("%s WARNING: loadAnimation '%s' not found on %s - no door", SPS_LL_TAG, tostring(doorName), tostring(vehicle.configFileName)))
        else
            entry.state.loadAnimName = doorName
            entry.doorTextOpen  = xmlFile:getString(kp .. "loadAnimation#textOpen")
            entry.doorTextClose = xmlFile:getString(kp .. "loadAnimation#textClose")
            local autoClose = xmlFile:getBool(kp .. "loadAnimation#doorCloseAuto", true)
            for _, c in ipairs(entry.couplings) do
                c.loadAnimationName = doorName
                c.loadAnimAutoClose = autoClose
                c.loadAnimPlayed    = false
            end
        end
    end

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
            SlurryPipeManager.gateAdd(ctrl)
        else
            print(string.format("%s WARNING: control node '%s' not found on %s — no walk-up prompt",
                SPS_LL_TAG, tostring(pcName), tostring(vehicle.configFileName)))
        end
        pcIndex = pcIndex + 1
    end

    -- [SPS CHEM 2026-11-09] <chemStation bowlFillNode="..." [bowlAnimation="..."] [configType="design" configIndex="0"]/>
    -- A chem bowl on a liquid carrier (550 Water/Chem Bowser): the bowl shape becomes a pour target for the
    -- connector's fill unit through SPSChemStation.install, exactly as on a sprayer (node object + the
    -- getFillUnitIndexFromNode hook). Optional config gate, same convention as the fill-arm / coupling gates:
    -- #configIndex = 0-based slot(s) of the #configType configuration (default "design", "0" or "0,2") on which
    -- the bowl is fitted; a configuration the vehicle does not have passes. Not fitted = no entry, no node
    -- object, no hook (the XML objectChange turns the shape's rigid body off as well).
    if SPSChemStation ~= nil and xmlFile:hasProperty(kp .. "chemStation") then
        local csKey   = kp .. "chemStation"
        local cfgStr  = xmlFile:getString(csKey .. "#configIndex")
        local cfgType = xmlFile:getString(csKey .. "#configType", "design")
        local active  = vehicle.configurations ~= nil and vehicle.configurations[cfgType] or nil
        local fitted  = true
        if cfgStr ~= nil and active ~= nil then
            fitted = false
            for token in string.gmatch(cfgStr, "[^,]+") do
                if tonumber((token:gsub("%s+", ""))) == active - 1 then fitted = true break end
            end
        end
        if fitted then
            local bowlName = xmlFile:getString(csKey .. "#bowlFillNode")
            entry.chemStation = {
                bowlFillNode = findLinkedNode(bowlName),
                bowlAnim     = xmlFile:getString(csKey .. "#bowlAnimation"),
                handleAnim   = xmlFile:getString(csKey .. "#handleAnimation"),   -- [SPS CHEM 2026-11-09] open while pouring
            }
            if entry.chemStation.bowlFillNode == nil then
                print(string.format("%s WARNING: chemStation bowlFillNode '%s' not found on %s - the bowl is not a pour target",
                    SPS_LL_TAG, tostring(bowlName), tostring(vehicle.configFileName)))
            end
            SPSChemStation.install(vehicle, entry)
        else
            llLog("chemStation on %s not fitted (%s slot %s, wanted %s)", tostring(vehicle.configFileName),
                tostring(cfgType), tostring(active - 1), tostring(cfgStr))
        end
    end

    -- [SPS 2026-11-09] <extraFillTypes categories="SPRAYER" fillUnitIndex="1"/>: a FillUnit takes EITHER fillTypes OR
    -- fillTypeCategories (FillUnit.lua:1671-1674) and no category holds water without diesel / DEF, so the 550 bowser
    -- lists water / LF / HERB in its XML and every liquid of these categories (Soil & Fertilizer's) is added here, on
    -- every peer (the supportedFillTypes table is what getFillUnitSupportsFillType / AllowsFillType read).
    local efi = 0
    while true do
        local ek = string.format(kp .. "extraFillTypes(%d)", efi)
        if not xmlFile:hasProperty(ek) then break end
        local fui = xmlFile:getInt(ek .. "#fillUnitIndex", 1)
        local fu = vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits ~= nil and vehicle.spec_fillUnit.fillUnits[fui] or nil
        local cats = xmlFile:getString(ek .. "#categories")
        if fu ~= nil and fu.supportedFillTypes ~= nil and cats ~= nil and g_fillTypeManager ~= nil then
            local added = {}
            for cat in cats:gmatch("%S+") do
                for _, ft in ipairs(g_fillTypeManager:getFillTypesByCategoryNames(cat, "Warning: [SPS LL] unknown fillTypeCategory '%s'") or {}) do
                    if not fu.supportedFillTypes[ft] then
                        fu.supportedFillTypes[ft] = true
                        added[#added + 1] = tostring(g_fillTypeManager:getFillTypeNameByIndex(ft))
                    end
                end
            end
            if #added > 0 then
                spsInfo(string.format("%s %s: fill unit %d also takes %s", SPS_LL_TAG, tostring(vehicle.configFileName), fui, table.concat(added, " ")))
            end
        else
            print(string.format("%s WARNING: extraFillTypes on %s - fill unit %d not found", SPS_LL_TAG, tostring(vehicle.configFileName), fui))
        end
        efi = efi + 1
    end

    -- [SPS 2026-11-09] <generator pullAnimation="..." pulls="3" pullSpeed="1.5" pullPause="0.4" revsAnimation="...">
    --   <sounds><pull .../><start .../><engineLoop .../></sounds></generator>
    -- The little petrol pump engine of the 550 bowser (William: "like the TSA but the pull cord is a 3 times pull").
    -- B at the control node = pump on: the cord is pulled `pulls` times (time-based, so server and clients agree), then
    -- the engine loop runs and the revs lever swings; liquid only moves once it runs (_llTickGenerator / tickLiquidLaneFlow).
    if xmlFile:hasProperty(kp .. "generator") then
        local gk = kp .. "generator"
        entry.generator = {
            pullAnim  = xmlFile:getString(gk .. "#pullAnimation"),
            pulls     = math.max(1, xmlFile:getInt(gk .. "#pulls", 3)),
            pullSpeed = xmlFile:getFloat(gk .. "#pullSpeed", 1.5),
            pullPause = xmlFile:getFloat(gk .. "#pullPause", 0.4),
            revsAnim  = xmlFile:getString(gk .. "#revsAnimation"),
            phase = "off", t = 0, pullsDone = 0,
        }
        if vehicle.isClient and g_soundManager ~= nil then
            for _, sname in ipairs({ "pull", "start", "engineLoop" }) do
                if xmlFile:hasProperty(gk .. ".sounds." .. sname) then
                    entry.generator[sname .. "Sample"] = g_soundManager:loadSampleFromXML(xmlFile, gk .. ".sounds", sname,
                        vehicle.baseDirectory, vehicle.components, 0, AudioGroup.VEHICLE, vehicle.i3dMappings, vehicle)
                end
            end
        end
        llLog("generator on %s: pull=%s x%d speed %.2f pause %.2f revs=%s", tostring(vehicle.configFileName),
            tostring(entry.generator.pullAnim), entry.generator.pulls, entry.generator.pullSpeed, entry.generator.pullPause, tostring(entry.generator.revsAnim))
    end
    -- [SPS 2026-11-09] <physicalModeHide> + <pipeHolders> on the LIQUID root, same schema and rules as the slurry side
    if self.readPhysModeHide ~= nil then
        entry.physModeHide = self:readPhysModeHide(xmlFile, nil, vehicle.components, vehicle.configFileName, vehicle, kp)
        self:applyPhysModeHide(entry.physModeHide)
    end
    if self.readPipeHolders ~= nil and xmlFile:hasProperty(kp .. "pipeHolders") then
        self:readPipeHolders(xmlFile, kp .. "pipeHolders", vehicle, entry, findLinkedNode)
        if self.hideGatedHolderBranches ~= nil then self:hideGatedHolderBranches(entry) end
    end

    if xmlFileOwned then xmlFile:delete() end

    if #entry.couplings == 0 then
        print(string.format("%s %s: <%s> present but no usable coupling — not registered",
            SPS_LL_TAG, tostring(vehicle.configFileName), SPS_LL_VEHICLE_ROOT))
        for _, pc in ipairs(entry.controls) do if pc.activatable ~= nil then pc.activatable:delete() end end
        if SPSChemStation ~= nil and SPSChemStation.uninstall ~= nil then SPSChemStation.uninstall(entry) end
        self:_llCleanupExtras(entry)
        return
    end
    if #entry.controls == 0 then
        print(string.format("%s %s: registered without a <%s> node — nothing can connect it",
            SPS_LL_TAG, tostring(vehicle.configFileName), SPS_LL_VEHICLE_CONTROLS))
    end

    -- [SPS MKS8 2026-11-10] restore the door (saved with the sprayers' animations) and the selected tank of this vehicle
    if entry.state.loadAnimName ~= nil and self._applyPendingSprayerAnimation ~= nil then
        self:_applyPendingSprayerAnimation(vehicle, entry)
    end
    self:_llApplyPendingTankSelections(vehicle, entry)
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
            -- [SPS CHEM 2026-11-09] chem bowl node object (bowser)
            if SPSChemStation ~= nil and SPSChemStation.uninstall ~= nil then SPSChemStation.uninstall(entry) end
            self:_llCleanupExtras(entry)   -- [SPS 2026-11-09] holders out of the global list, generator samples
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
        -- [SPS 1.0.2.0] reach rule 6c at the connect range too (see SPSM_Sprayers findOverlappingSprayerCoupler)
        -- [SPS 2026-11-10] ...a fitting with its own partner hose reaches that hose's length (llConnectReach)
        local reach = self:llConnectReach(coupling, sc)
        -- [SPS 2026-11-10] the same mount-to-mount gap the drop check measures (llCouplingGap), never the arc apexes
        if self:llCouplingGap(coupling, sc) > reach then return end
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
    -- [SPS 2026-11-10] TRANSFER: another TANKER's 80 mm liquid connector (William: "bowser to tank via the arc"). Pipe mode
    -- has had this through the physical chain since 1.0.1.8 (SPSM_PhysPipes); original mode never offered it. Both connectors
    -- must take water or milk; B pumps, Y = load / unload (onLiquidLaneToggleDirection).
    local trLane = SPS_LIQUID_LANES.TRANSFER
    if trLane ~= nil and (coupling.lanes == nil or coupling.lanes.WATER or coupling.lanes.MILK or coupling.lanes.TRANSFER) then
        for _, vEntry in ipairs(self.registeredLiquidLaneVehicles or {}) do
            if vEntry.object ~= nil and vEntry.object ~= coupling.object then
                for _, sc in ipairs(vEntry.couplings or {}) do
                    if sc.isVehicleSide and not sc.isConnected and sc.physPipe == nil and sc.origSuction == nil and sc.origWash == nil
                    and (sc.lanes == nil or sc.lanes.WATER or sc.lanes.MILK or sc.lanes.TRANSFER) then
                        consider(sc, trLane)
                    end
                end
            end
        end
    end
    -- [SPS 2026-11-10] ...and a SPRAYER VEHICLE's own coupler (William: tanker water fitting <-> sprayer water fitting in
    -- original mode). Same bridge as a barn's sprayer lane; pipe mode did this through the physical chain already
    -- (SPSM_PhysPipes _physEvaluateChain: a connector that takes WATER). Never this vehicle's own coupler or a bridge entry.
    if coupling.lanes ~= nil and (coupling.lanes.SPRAYER or coupling.lanes.WATER) and llLaneAcceptsHeld(spLane, heldFt)
    and self.registeredSprayerVehicles ~= nil then
        for _, vEntry in ipairs(self.registeredSprayerVehicles) do
            if not vEntry.isLiquidLaneBridge and vEntry.object ~= nil and vEntry.object ~= coupling.object then
                for _, sc in ipairs(vEntry.couplings or {}) do
                    if not sc.isConnected and sc.physPipe == nil then consider(sc, spLane) end
                end
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
        maxPipeLength            = self:llConnectReach(cV, nil),   -- [2026-11-10] the bowser's own small hose keeps its 7.4 m (else the 80 mm 4.0 m)
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
        partnerHoseKey           = cV.partnerHoseKey,   -- [2026-11-10] the bowser's own small hose on a sprayer connect
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
    -- [SPS MKS8 2026-11-10] a closed door (loadAnimation) on this fitting: open it first
    if coupling.loadAnimationName ~= nil and not coupling.loadAnimPlayed then
        if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsLaneDoorFirst"), 2000)
        end
        return
    end
    if g_server == nil then
        SPSLiquidLaneConnectEvent.sendEvent(vehicle, coupling.id, nil, 0, 0)
        return
    end
    local other, lane = self:findOverlappingLiquidLaneCoupler(coupling)
    if other == nil or other.isConnected or lane == nil then return end
    if other.loadAnimationName ~= nil and not other.loadAnimPlayed then   -- [SPS MKS8] the far side's door (Transfer to an MKS8)
        if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsLaneDoorFirst"), 2000)
        end
        return
    end
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
        -- [SPS 2026-11-10] original mode: the hose on the fitting = its handle over, as the far side's connector animation
        -- (William: "the tanker valve opens but the bowser valve does not"); back on disconnect
        if cV.physPipe == nil then self:_llNamedValves(cV, true) end
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
        -- [SPS 2026-11-10] a fitting with its own pipes (550 bowser) connects with ITS small hose; else the generic lane hose
        local inst  = self:_llKeyedPartnerHose(cV, cP)
        if inst == nil then
            inst = g_spsLiquidLanePipeVisual:createPipe(nodeA, nodeB, (lane ~= nil and lane.key == "MILK") and "milk" or "water")
        end
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
    -- [SPS 2026-11-10] original mode: a vehicle fitting's NAMED valves (550 bowser waterInletValve) swing over with the
    -- connection, like the tanker's connector animation on the other end (William, log 13:36: Supercis <-> bowser Transfer,
    -- "the tanker valve opens but the bowser valve does not"); they stay over until the disconnect (applyLiquidLaneDisconnect)
    if not physPipe then
        self:_llNamedValves(cV, true)
        self:_llNamedValves(cP, true)
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
        -- [SPS 2026-11-10] a sprayer VEHICLE's coupler too (tanker <-> sprayer in original mode; join state / MP events)
        return self:_findSprayerCouplingById(targetObject, targetCouplingId, true)
            or self:_findSprayerCouplingById(targetObject, targetCouplingId, false), lane
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
        if coupling.physPipe == nil then self:_llNamedValves(coupling, false) end   -- [2026-11-10] bowser inlet handle back
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
    self:_llNamedValves(coupling, false)   -- [SPS 1.0.2.0] tank valves behind the fitting close with it
    self:_llNamedValves(partner, false)
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
    -- [SPS MKS8 2026-11-10] doorCloseAuto: a vehicle-side door closes once nothing is on its fittings any more
    if coupling ~= nil and coupling.isVehicleSide then self:_llAutoCloseDoor(coupling.object) end
    if partner ~= nil and partner.isVehicleSide then self:_llAutoCloseDoor(partner.object) end
end

function SlurryPipeManager:_llAutoCloseDoor(vehicle)
    local entry = vehicle ~= nil and self:getLiquidLaneVehicleEntry(vehicle) or nil
    if entry == nil or entry.state.loadAnimName == nil then return end
    local c1 = entry.couplings[1]
    if c1 == nil or not c1.loadAnimPlayed or c1.loadAnimAutoClose == false then return end
    if self:llDoorCanClose(vehicle) then self:applyLiquidLaneDoor(vehicle, false) end
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
            -- [SPS CHEM 2026-11-06] hose from this tanker to a SPRAYER: the sprayer's own B / Y run it (from here B
            -- would pump the sprayer's tank into this one)
            local b = self.activeLiquidLaneBridges ~= nil and self.activeLiquidLaneBridges[vehicle] or nil
            if b ~= nil and b.sprayerSide then
                -- [SPS 2026-11-10] a GENERATOR vehicle hosed to a sprayer: B is still its own engine (log 00:04 - nine
                -- presses did nothing); the sprayer's B / Y run that flow as before
                if entry.generator == nil then return end
            else
                -- SPRAYER lane: exactly the sprayer's B toggle (pump + valve, events, sound).
                if self.onSprayerToggleValve ~= nil then self:onSprayerToggleValve(vehicle) end
                -- [SPS MKS8 2026-11-10] a GENERATOR vehicle on a sprayer placeable (MKS8 <-> washout station): the same B is
                -- also its engine - fall through to the lane valve like the 550 does on a sprayer vehicle
                if entry.generator == nil then return end
            end
        end
    end
    local newValve = not entry.state.valveOpen
    if newValve then
        local c, mode = nil, nil
        for _, cc in ipairs(entry.couplings) do if cc.isConnected then c = cc break end end
        if c == nil then
            -- [SPS 2026-11-09] 550 bowser: suction pipe in the water (intake) / wash hose lying free (pour) - B = pump
            for _, cc in ipairs(entry.couplings) do
                mode = self:_llSpecialMode(cc)
                if mode ~= nil then c = cc break end
            end
        end
        -- [SPS 2026-11-09] a GENERATOR vehicle (550 bowser): B starts the little engine with or without a pipe on it
        -- (William); the flow then follows whatever is connected / lying in the water. Everything below is advice only.
        local engineOnly = c == nil and entry.generator ~= nil
        if c == nil and not engineOnly then return end
        entry.state.specialPumping = mode ~= nil
        entry._idleReason = nil
        -- [SPS 1.0.1.8] physical pipes: the pump only runs with BOTH fitting valves open (R at the fittings)
        -- [SPS 2026-11-09] the wash outlet has no valve (William: "that valve can open anyway"); the inlet keeps its
        -- valve (waterInletValve, R at the control node) for the suction pipe and the small hose alike
        if c ~= nil and c.physPipe ~= nil and c.washOutletKey == nil and entry.generator == nil then
            -- (a generator vehicle starts with the valve open or closed - William; the valve gates the flow, see
            -- _llEvaluateSpecial / tickLiquidLaneFlow)
            local p = c.connectedPartnerCoupling
            if not c.ballValveOpen or (p ~= nil and not p.ballValveOpen) then
                if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                    g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsFittingValveClosed"), 2500)
                end
                return
            end
        end
        local ok, warnKey = true, nil
        if engineOnly or (c ~= nil and c.bridgeCoupling ~= nil) then
            -- [SPS MKS8 2026-11-11] a bridge was already judged by onSprayerToggleValve above (its lane evaluation only
            -- printed "pump refused (nil lane)" before the engine started anyway - log 23:14:23)
            ok = true
        elseif mode ~= nil then
            ok, warnKey = self:_llEvaluateSpecial(vehicle, c, mode)
        elseif c.activeLane ~= nil and c.activeLane.transfer then
            ok, warnKey = self:_llEvaluateTransfer(vehicle, c)
        else
            ok, warnKey = self:_llEvaluate(vehicle, c)
        end
        if not ok and c ~= nil and c.physPipe ~= nil then
            print(string.format("[SPS PHYS] pump refused on %s (%s lane): %s", tostring(vehicle and vehicle.configFileName),
                tostring(c.activeLane and c.activeLane.key), tostring(warnKey or "cannot flow")))
        end
        if not ok then
            if warnKey ~= nil and g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                g_currentMission:showBlinkingWarning(g_i18n:getText(warnKey), 2500)
            end
            if entry.generator == nil then return end   -- a generator vehicle starts its engine anyway (nothing flows yet)
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
    -- [SPS MKS8 2026-11-10] NOT connected: Y picks the tank the fitting will serve (what it holds decides the lanes on
    -- offer); connected: Y steps through direction x tank, "Load front tank / Load rear tank / Unload front tank / ..."
    -- (the sprayer's load / wash tank / unload, William). A fixed-direction lane steps the tank only.
    if c == nil then return end   -- [SPS MKS8 2026-11-11] nothing connected: nothing to direct (Shift+Y picks the tank)
    local steps = self:_llDirectionSteps(vehicle, c)
    if #steps <= 1 then
        if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsLiquidDirectionFixed"), 2000)
        end
        return
    end
    local _, curDir = self:getLiquidLaneDisplayState(vehicle)
    local curTank = c.selectedTank or 1
    local cur = 1
    for i, s in ipairs(steps) do if s.dir == curDir and s.tank == curTank then cur = i break end end
    local nxt = steps[(cur % #steps) + 1]
    if nxt.tank ~= curTank then
        local bridgeOpen = false
        if c.bridgeCoupling ~= nil then
            local st = self:_llBridgeState(vehicle)
            bridgeOpen = st ~= nil and st.valveOpen == true
        end
        if entry.state.valveOpen or bridgeOpen then   -- never re-route a running transfer
            if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsCloseValveFirst"), 2000)
            end
            return
        end
        self:onLiquidLaneSelectTank(vehicle, c, nxt.tank)
    end
    if nxt.dir ~= curDir then
        if c.bridgeCoupling ~= nil then
            -- [SPS MKS8 2026-11-11] pipe mode with a ball valve: a transfer runs only with the engine on AND the valve open -
            -- then say so (the sprayer toggle refuses silently); the valve shut = free to change, engine or not
            if c.physPipe ~= nil and c.hasValve ~= false and c.ballValveOpen then
                local st = self:_llBridgeState(vehicle)
                if st ~= nil and st.valveOpen then
                    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsCloseValveFirst"), 2000)
                    end
                    return
                end
            end
            if self.onSprayerToggleDirection ~= nil then self:onSprayerToggleDirection(vehicle) end
        elseif c.activeLane ~= nil and c.activeLane.transfer then
            if g_server ~= nil then self:applyLiquidLaneTransferDirection(vehicle, nxt.dir) end
            SPSLiquidLaneTransferDirectionEvent.sendEvent(vehicle, nxt.dir)
        end
    end
end

-- the Y steps of a connected fitting, { {dir, tank} ... } in cycle order
function SlurryPipeManager:_llDirectionSteps(vehicle, c)
    local dirs
    if c.bridgeCoupling ~= nil or (c.activeLane ~= nil and c.activeLane.transfer) then
        dirs = { SPS_SPRAYER_DIRECTION_FILL, SPS_SPRAYER_DIRECTION_DISCHARGE }
    else
        local _, d = self:getLiquidLaneDisplayState(vehicle)
        dirs = { d }
    end
    -- [SPS MKS8 2026-11-11] Y = direction only (William: four steps were too many), the tank is Shift+Y. Unload at a
    -- washout station pushes the tank down the station's dirty line (SPSChemWashout.tickStations follows the direction).
    local tanks = { c.selectedTank or 1 }
    local steps = {}
    for _, d in ipairs(dirs) do for _, t in ipairs(tanks) do steps[#steps + 1] = { dir = d, tank = t } end end
    return steps
end

function SlurryPipeManager:applyLiquidLaneTankSelect(vehicle, couplingId, tankIdx)
    local c = self:_findLiquidLaneCouplingById(vehicle, couplingId)
    if c == nil or c.tanks == nil or c.tanks[tankIdx] == nil then return false end
    if c.selectedTank == tankIdx then return true end
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry ~= nil and entry.state.valveOpen and g_server ~= nil then self:_llStopFlow(vehicle, "tank changed") end
    SlurryPipeManager._llApplyTankToCoupling(c, tankIdx)
    -- [SPS MKS8 2026-11-11] a sprayer flow session built while the engine ran keeps its own fill unit: re-route it too
    local session = self.activeSprayerFlows ~= nil and self.activeSprayerFlows[vehicle] or nil
    if session ~= nil then session.vehicleFillUnit = c.fillUnitIndex end
    llLog("tank %d (fill unit %d) selected on %s coupling id=%s", tankIdx, c.fillUnitIndex, tostring(vehicle and vehicle.configFileName), tostring(c.id))
    return true
end

-- [SPS MKS8 2026-11-11] Shift+Y at the control node: the next tank of a multi-tank fitting, pipe on or not; never while
-- the pump / bridge valve is open (a running transfer is not re-routed)
function SlurryPipeManager:onLiquidLaneNextTank(vehicle)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil then return end
    local c = nil
    for _, cc in ipairs(entry.couplings) do if cc.isConnected and cc.tanks ~= nil then c = cc break end end
    if c == nil then for _, cc in ipairs(entry.couplings) do if cc.tanks ~= nil then c = cc break end end end
    if c == nil or #c.tanks < 2 then return end
    local bridgeOpen = false
    if c.bridgeCoupling ~= nil then
        local st = self:_llBridgeState(vehicle)
        bridgeOpen = st ~= nil and st.valveOpen == true
    end
    local running = entry.state.valveOpen or bridgeOpen
    -- a ball valve on the fitting (pipe mode): the engine alone moves nothing - only engine + valve OPEN is a running
    -- transfer (William 11:28: "the engine on should not have an effect on tank switch")
    if c.physPipe ~= nil and c.hasValve ~= false then running = running and c.ballValveOpen == true end
    if running then
        if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsCloseValveFirst"), 2000)
        end
        return
    end
    self:onLiquidLaneSelectTank(vehicle, c, ((c.selectedTank or 1) % #c.tanks) + 1)
end

function SlurryPipeManager:onLiquidLaneSelectTank(vehicle, coupling, tankIdx)
    if coupling == nil or coupling.tanks == nil then return end
    if g_server ~= nil and not self:applyLiquidLaneTankSelect(vehicle, coupling.id, tankIdx) then return end
    SPSLiquidLaneTankSelectEvent.sendEvent(vehicle, coupling.id, tankIdx)
end

-- [SPS MKS8 2026-11-10] a config text that may be a "$l10n_" key: looked up through THIS mod's g_i18n (the engine's
-- I18N:convertText runs in the base environment, whose g_i18n cannot see mod texts - screenshot 22:10 "Missing
-- 'sps_mks8DoorOpen' in l10n_en.xml" with the key present in the file). A key that is still missing falls back to nil.
function SlurryPipeManager.llConfigText(s)
    if s == nil or s == "" then return nil end
    if string.sub(s, 1, 6) == "$l10n_" then
        local key = string.sub(s, 7)
        if g_i18n ~= nil and g_i18n:hasText(key) then return g_i18n:getText(key) end
        return nil
    end
    return s
end

-- "front tank (water 3,200 l)" / "rear tank (empty)" for the selected tank of a multi-tank fitting, nil otherwise
function SlurryPipeManager:llTankLabel(vehicle, c)
    if c == nil or c.tanks == nil then return nil end
    local t = c.tanks[c.selectedTank or 1]
    if t == nil then return nil end
    local name = SlurryPipeManager.llConfigText(t.name)
    if name == nil or name == "" then name = string.format(g_i18n:getText("sps_tankN"), t.id or (c.selectedTank or 1)) end
    local lvl = vehicle.getFillUnitFillLevel ~= nil and (vehicle:getFillUnitFillLevel(t.fillUnitIndex) or 0) or 0
    local what = g_i18n:getText("sps_tankEmpty")
    if lvl > 0.5 and vehicle.getFillUnitFillType ~= nil then
        local ft = vehicle:getFillUnitFillType(t.fillUnitIndex)
        local ftName = (g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeTitleByIndex ~= nil) and g_fillTypeManager:getFillTypeTitleByIndex(ft) or tostring(ft)
        local vol = (g_i18n.formatVolume ~= nil) and g_i18n:formatVolume(lvl, 0) or string.format("%d l", math.floor(lvl + 0.5))
        what = string.format("%s %s", tostring(ftName), vol)
    end
    return string.format("%s (%s)", name, what)
end

-- the door (loadAnimation) of a lane vehicle: open / close on this peer
function SlurryPipeManager:applyLiquidLaneDoor(vehicle, open)
    local entry = vehicle ~= nil and self:getLiquidLaneVehicleEntry(vehicle) or nil
    local name = entry ~= nil and entry.state.loadAnimName or nil
    if name == nil or vehicle.playAnimation == nil then return false end
    for _, c in ipairs(entry.couplings) do c.loadAnimPlayed = open == true end
    vehicle:playAnimation(name, open and 1 or -1, nil, true)
    llLog("door %s on %s", open and "OPEN" or "closed", tostring(vehicle.configFileName))
    return true
end

-- the door can close only with nothing on any fitting (connected, pipe plugged, original-mode hose out)
function SlurryPipeManager:llDoorCanClose(vehicle)
    local entry = vehicle ~= nil and self:getLiquidLaneVehicleEntry(vehicle) or nil
    for _, c in ipairs(entry ~= nil and entry.couplings or {}) do
        if c.isConnected or c.physPipe ~= nil or c.origSuction ~= nil or c.origWash ~= nil then return false end
    end
    return true
end

function SlurryPipeManager:onLiquidLaneToggleDoor(vehicle)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil or entry.state.loadAnimName == nil then return end
    local c1 = entry.couplings[1]
    local open = not (c1 ~= nil and c1.loadAnimPlayed)
    if not open and not self:llDoorCanClose(vehicle) then
        if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsDoorPipe"), 2000)
        end
        return
    end
    if g_server ~= nil then self:applyLiquidLaneDoor(vehicle, open) end
    SPSLiquidLaneDoorEvent.sendEvent(vehicle, open)
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
    self:_llNamedValves(coupling, open)   -- [SPS 1.0.2.0]
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
    -- [SPS CHEM 2026-11-09] water into a tank holding a chemical dilutes it (SPSChemMix.addFillLevel books it) - the
    -- bowser mixes concentrate (William). Anything else still has to match.
    if dstLvl > 0.001 and dstFt ~= ft and not SlurryPipeManager.llWaterDilutes(dst, ft, dstFui) then return false, "warning_spsTransferType" end
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
    -- [SPS CHEM 2026-11-10] the sender's strength rides along (as the sprayer / discharge paths do)
    local prev = SPSChemMix ~= nil and SPSChemMix.ctx or nil
    if SPSChemMix ~= nil and SPSChemMix.ctxOfVehicle ~= nil then SPSChemMix.ctx = SPSChemMix.ctxOfVehicle(src, srcFui, ft) end
    self:removeFromSource({ type = "FILL_UNIT_ONLY", vehicle = src, fillUnitIndex = srcFui }, amount, ft, src)
    self:addToSource({ type = "FILL_UNIT_ONLY", vehicle = dst, fillUnitIndex = dstFui }, amount, ft, dst)
    if SPSChemMix ~= nil then SPSChemMix.ctx = prev end
end

-- What the control node shows: valveOpen and direction (SPS_SPRAYER_DIRECTION_*),
-- uniform across lanes so the prompts read the same at a barn and at a silo.
function SlurryPipeManager:getLiquidLaneDisplayState(vehicle)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil then return false, SPS_SPRAYER_DIRECTION_FILL, nil end
    local c = nil
    for _, cc in ipairs(entry.couplings) do if cc.isConnected then c = cc break end end
    if c == nil then
        -- [SPS 2026-11-09] bowser intake / wash pour: pump state, direction fixed
        for _, cc in ipairs(entry.couplings) do
            if self:_llSpecialMode(cc) ~= nil then return entry.state.valveOpen == true, SPS_SPRAYER_DIRECTION_FILL, nil end
        end
        return false, SPS_SPRAYER_DIRECTION_FILL, nil
    end
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

-- [SPS 1.0.2.0] Vehicle-side fitting with #valveAnimations: hold / release the named vehicle animations
-- with the fitting's valve (original mode: the flow toggle; physical mode: R at the fitting; disconnect: closed).
function SlurryPipeManager:_llNamedValves(c, open)
    if c == nil or not c.isVehicleSide or c.valveAnimationNames == nil or c.object == nil then return end
    if (c._namedValvesOpen == true) == (open == true) then return end
    c._namedValvesOpen = open == true
    if self:getVehicleEntry(c.object) ~= nil then
        self:spsAnimDemandList(c.object, c.valveAnimationNames, open and 1 or -1, false)
    else
        -- [SPS 2026-11-09] spsAnimDemand only knows slurry-registered vehicles: a lane-only vehicle (550 bowser) plays its
        -- valve animations directly (waterInletValve = the inlet handle, R at the control node / B in original mode)
        local v = c.object
        for _, n in ipairs(c.valveAnimationNames) do
            if v.getAnimationExists ~= nil and v:getAnimationExists(n) and v.playAnimation ~= nil then
                v:playAnimation(n, open and 1 or -1, nil, true)
            end
        end
    end
end

function SlurryPipeManager:applyLiquidLaneValveState(vehicle, valveOpen)
    local entry = self:getLiquidLaneVehicleEntry(vehicle)
    if entry == nil then return end
    entry.state.valveOpen = valveOpen
    if not valveOpen then
        entry.state.specialPumping = nil
        for _, c in ipairs(entry.couplings) do if not c.isConnected then c.valveOpen = false end end   -- [SPS 2026-11-09] stale special flags
    end
    for _, c in ipairs(entry.couplings) do
        if c.isConnected or self:_llSpecialMode(c) ~= nil then   -- [SPS 2026-11-09] bowser intake / wash pour
            c.valveOpen = valveOpen
            if c.connectedPartnerCoupling ~= nil then c.connectedPartnerCoupling.valveOpen = valveOpen end
            if SPSCouplerAnimator ~= nil and c.physPipe == nil then   -- physical pipes: the handle is the FITTING valve
                if c.valveAnim ~= nil then SPSCouplerAnimator.play(c.valveAnim, valveOpen and 1 or -1) end
                local p = c.connectedPartnerCoupling
                if p ~= nil and p.valveAnim ~= nil then SPSCouplerAnimator.play(p.valveAnim, valveOpen and 1 or -1) end
            end
            if c.physPipe == nil then
                -- [2026-11-10] connected in original mode: the handles went over with the connection and stay there
                -- (applyLiquidLaneConnect); only a special fitting (intake / wash, no partner) follows B
                self:_llNamedValves(c, valveOpen or c.isConnected)
                local p = c.connectedPartnerCoupling
                if p ~= nil then self:_llNamedValves(p, valveOpen or p.isConnected) end
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
    if entry.generator ~= nil then
        -- [SPS 2026-11-09] 550 bowser: the engine stays running (William), the pump just has nothing it may move
        if entry._idleReason ~= reason then
            entry._idleReason = reason
            print(string.format("%s %s: engine running, nothing flows - %s", SPS_LL_TAG, tostring(vehicle and vehicle.configFileName), tostring(reason)))
        end
        return
    end
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
    -- [SPS 2026-11-10] the WASH hose pours whenever its lance is in hand with the pour on and the engine runs, whatever
    -- else is connected (William: hose to the sprayer connected, wash hose in hand, "the bowser amount doesn't move")
    -- [SPS 2026-11-10] a special fitting (wash / intake) is live whenever the pump / engine is on (entry.state.valveOpen), not
    -- only when it was special at the B press
    local pumpOn = entry.state.valveOpen == true
    if entry.generator == nil or entry.generator.phase == "run" then
        for _, cc in ipairs(entry.couplings) do
            if (cc.valveOpen or pumpOn) and self:_llSpecialMode(cc) == "wash" then self:_llTickSpecial(entry, cc, "wash", dt) end
        end
    end
    local c, mode = nil, nil
    for _, cc in ipairs(entry.couplings) do if cc.isConnected and cc.valveOpen then c = cc break end end
    if c == nil then
        -- [SPS 2026-11-09] 550 bowser: suction pipe in the water (bought pipe or the original-mode laid one)
        for _, cc in ipairs(entry.couplings) do
            if cc.valveOpen or pumpOn then
                mode = self:_llSpecialMode(cc)
                if mode == "wash" then mode = nil end   -- ticked above
                if mode ~= nil then c = cc break end
            end
        end
        if c == nil then
            if entry.state.specialPumping and entry.generator == nil then self:_llStopFlow(vehicle, "pipe taken off the bowser") end
            return   -- pump off (or an engine running with nothing to pump): updateLiquidLanes runs _llTickGravity instead
        end
    end
    -- [SPS 2026-11-09] generator: nothing moves until the little engine runs (pull cord first)
    if entry.generator ~= nil and entry.generator.phase ~= "run" then return end
    if mode ~= nil then
        self:_llTickSpecial(entry, c, mode, dt)
        return
    end
    local partner = c.connectedPartnerCoupling
    if partner == nil then return end
    -- [SPS MKS8 2026-11-11] a sprayer BRIDGE (hose to a sprayer vehicle / placeable) is moved by the SPRAYER tick; its far
    -- coupler is a sprayer coupler with no lane valve, so the check below printed "engine running, nothing flows - fitting
    -- valve closed" while the water was flowing (log 23:14:25). Nothing below applies to a bridge.
    if c.bridgeCoupling ~= nil then return end
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
       and st._gravReason ~= string.gsub(tostring(reason), "[%d%.%-]+", "#") then
        -- [2026-11-09] compare without the numbers: "low side (y=49.73 ...)" changed every tick - 109 lines in one fill
        print(string.format("[SPS PHYS] gravity idle on %s: %s", name, tostring(reason)))
    end
    st._gravActive = active
    st._gravReason = string.gsub(tostring(reason), "[%d%.%-]+", "#")
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
    if dstLvl > 0.001 and dstFt ~= ft and not SlurryPipeManager.llWaterDilutes(other, ft, dstFui) then return false, "the tanks hold different liquids" end
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
                -- [SPS CHEM 2026-11-07] a sprayer hose's bridge carries NO animations (the fitting handle is the R valve,
                -- SPSM_PhysPipes): then nobody else ticks it and the handle froze while the valve opened (William)
                local bc = c.bridgeCoupling
                if bc == nil or (bc.connectorAnim == nil and bc.valveAnim == nil) then
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
    -- [SPS 2026-11-09] 550 bowser: a fitting's VEHICLE connector animation follows "a pipe is on it"; the generator
    for _, entry in ipairs(self.registeredLiquidLaneVehicles) do
        local v = entry.object
        if v ~= nil then
            for _, c in ipairs(entry.couplings) do
                if c.connectorAnimName ~= nil then
                    -- [2026-11-10] ...or an original-mode pipe in use on it (cap off / handle over while the hose is out - William)
                    local want = c.physPipe ~= nil or c.isConnected or c.origSuction ~= nil or c.origWash ~= nil
                    if (c._connAnimOn == true) ~= want then
                        c._connAnimOn = want
                        -- played directly: spsAnimDemand only knows SLURRY-registered vehicles (getVehicleEntry)
                        if v.getAnimationExists ~= nil and v:getAnimationExists(c.connectorAnimName) and v.playAnimation ~= nil then
                            v:playAnimation(c.connectorAnimName, want and 1 or -1, nil, true)
                        end
                    end
                end
            end
            if entry.generator ~= nil then self:_llTickGenerator(entry, dt) end
            -- [SPS MKS8 2026-11-10] valve-less fittings: open while a pipe is plugged in, shut otherwise
            for _, c in ipairs(entry.couplings) do
                if c.hasValve == false then c.ballValveOpen = c.physPipe ~= nil end
            end
            -- [SPS 2026-11-09] original-mode pipes: the wash hose end rides in its player's hands; pipe mode PHYSICAL
            -- takes both back (server)
            for _, c in ipairs(entry.couplings) do
                if c.origWash ~= nil or (c.origSuction ~= nil and c.origSuction.carried) then
                    self:_llOrigFollowPlayer(c)
                    -- [SPS 2026-11-10] the holder climbs into a vehicle: the pipe goes back on the rack (William). Only the
                    -- holder's own machine decides; every peer applies through the event.
                    local st = c.origWash or c.origSuction
                    local kind = c.origWash ~= nil and 2 or 1
                    if st ~= nil and not st._releaseSent and g_currentMission ~= nil and st.userId == g_currentMission.playerUserId
                    and g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil and g_localPlayer:getCurrentVehicle() ~= nil then
                        st._releaseSent = true
                        llLog("orig pipe kind %d: holder entered a vehicle - put back", kind)
                        if g_server ~= nil then self:applyLiquidLaneOrigPipe(v, c.id, kind, false, 0, 0, 0, -1) end
                        SPSLiquidLaneOrigPipeEvent.sendEvent(v, c.id, kind, false, 0, 0, 0, -1)
                    end
                end
                if g_server ~= nil and self.physicalPipesEnabled == true and (c.origWash ~= nil or c.origSuction ~= nil) then
                    local kind = c.origSuction ~= nil and 1 or 2
                    self:applyLiquidLaneOrigPipe(v, c.id, kind, false, 0, 0, 0, -1)
                    SPSLiquidLaneOrigPipeEvent.sendEvent(v, c.id, kind, false, 0, 0, 0, -1)
                end
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
                    -- [2026-11-10] the connect gate's own gap and reach + the drop margin (llCouplingGap / llDropReach)
                    local dist = self:llCouplingGap(c, p)
                    local reach = self:llDropReach(c, p)   -- a bowser's own small hose keeps its length
                    if dist > reach then
                        -- [SPS 1.0.2.0] always say why (one line per drop)
                        print(string.format("%s hose dropped: fittings %.1f m apart, reach %.1f m (%s connector id=%s)",
                            SPS_LL_TAG, dist, reach, tostring(entry.object and entry.object.configFileName), tostring(c.id)))
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
            -- [SPS CHEM 2026-11-06] sprayer <-> tanker hose: the sprayer disconnect played the shared fitting handle
            -- back; the fitting valve keeps its own state (R), so show that again
            if b.sprayerSide and cV ~= nil and self._physResyncConnectorAnim ~= nil then self:_physResyncConnectorAnim(cV) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Join dump: re-send live hoses and open valves to a freshly joined connection.
-- Bridged (SPRAYER lane) connections are sent from HERE with their lane id — the
-- sprayer join dump skips bridge entries — followed by the sprayer-side state.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- [SPS 2026-11-09] 550 WATER/CHEM BOWSER: fittings with an accept list and a bought pipe whose far end is FREE.
--   "intake": the fitting's waterSource pipe (suction) with its far end lying in a water course -> B pumps water in.
--   "wash"  : the fitting's washOutlet pipe (wash hose) -> B pours the tank out at the far end (puddle + stream).
-- A connected coupling (both ends on fittings) is never special - that is the ordinary lane / transfer path.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_llSpecialMode(c)
    if c == nil or not c.isVehicleSide or c.isConnected then return nil end
    -- [SPS 2026-11-09] ORIGINAL mode: the suction pipe laid to a point / the wash hose in a player's hands
    if c.origSuction ~= nil then return "intake" end
    if c.origWash ~= nil then return "wash" end
    if c.physPipe == nil then return nil end
    if c.waterSourceKey == nil and c.washOutletKey == nil then return nil end
    local pipe = c.physPipe
    local key = pipe.spsGetHoseKey ~= nil and pipe:spsGetHoseKey() or nil
    if key == nil then return nil end
    if self._physChainTerminals ~= nil then
        local cA, cB = self:_physChainTerminals(pipe)
        if (cA ~= nil and cA ~= c) or (cB ~= nil and cB ~= c) then return nil end   -- far end on another fitting
    end
    if key == c.waterSourceKey then return "intake" end
    if key == c.washOutletKey then return "wash" end
    return nil
end

-- ok, warnKey, tankLevel, tankFree, tankFillType
function SlurryPipeManager:_llEvaluateSpecial(vehicle, c, mode)
    if vehicle == nil or c == nil then return false, nil end
    local fui = c.fillUnitIndex or 1
    local lvl = vehicle.getFillUnitFillLevel ~= nil and (vehicle:getFillUnitFillLevel(fui) or 0) or 0
    local ft  = vehicle.getFillUnitFillType ~= nil and vehicle:getFillUnitFillType(fui) or nil
    if mode == "intake" then
        -- the inlet valve: R at the control node in pipe mode; in original mode B is pump + valve (laid suction)
        if c.origSuction == nil and not c.ballValveOpen then return false, "warning_spsBowserInletValve" end
        local inWater
        if c.origSuction ~= nil then
            -- [SPS 2026-11-10] still in the player's hands: lay it first (right mouse)
            if c.origSuction.carried then return false, "warning_spsBowserEndNotInWater" end
            inWater = self:_llOrigEndInWater(c)
        else
            -- [SPS 2026-11-11] a physical suction pipe draws only through a water cage fitted on its end (the original-mode
            -- laid suction above is not a physical pipe and has no cage)
            local plane, drawOk, cageMissing
            if self.physFreeEndWaterPlane ~= nil then plane, drawOk, cageMissing = self:physFreeEndWaterPlane(c, true) end
            inWater = plane ~= nil
            if inWater and drawOk == false then
                return false, cageMissing and "warning_spsAddCage" or "warning_spsBowserEndNotInWater"
            end
        end
        if not inWater then return false, "warning_spsBowserEndNotInWater" end
        -- water into a tank of chemical / concentrate: a dilution when chem mixing books it (SPSChemMix.addFillLevel)
        if lvl > 0.001 and ft ~= FillType.WATER and not SlurryPipeManager.llWaterDilutes(vehicle, FillType.WATER, fui) then
            return false, "warning_spsAnimalWaterOnly"
        end
        local free = vehicle.getFillUnitFreeCapacity ~= nil and (vehicle:getFillUnitFreeCapacity(fui) or 0) or 0
        if free <= 0.001 then return false, "warning_spsLiquidTankFull" end
        return true, nil, lvl, free, ft
    elseif mode == "wash" then
        if lvl <= 0.001 or ft == nil or ft == FillType.UNKNOWN then return false, "warning_spsAnimalWaterEmpty" end
        if c.origWash == nil then   -- (original mode: the hose end IS in a player's hands)
            if self._physFreeEndNode == nil or self:_physFreeEndNode(c) == nil then return false, nil end
            -- [SPS 2026-11-09] William: "liquid won't come out until we pick up the end of the pipe" - the lance end (or one
            -- of the two bodies behind it) must be in the player's hands
            if not self:_llWashEndHeld(c) then return false, "warning_spsWashHoldEnd" end
            -- [SPS 2026-11-10] ...and the pour started with the right mouse (SPSHoseItemHands "lance")
            if not c.lancePour then return false, "warning_spsLancePour" end
        elseif not c.lancePour then
            -- [SPS 2026-11-10] original mode: the same right mouse with the hose end in hand (SlurryPipeManager._llOrigLanceAction)
            return false, "warning_spsLancePour"
        end
        return true, nil, lvl, 0, ft
    end
    return false, nil
end

function SlurryPipeManager:_llTickSpecial(entry, c, mode, dt)
    local vehicle = entry.object
    local ok, warnKey, lvl, free, ft = self:_llEvaluateSpecial(vehicle, c, mode)
    if not ok then
        self:_llStopFlow(vehicle, tostring(warnKey or ("cannot " .. tostring(mode))))
        return
    end
    local fui = c.fillUnitIndex or 1
    if mode == "intake" then
        local amount = math.min((entry.litersPerSecond or 200) * dt * 0.001, free)
        if amount > 0 then
            self:addToSource({ type = "FILL_UNIT_ONLY", vehicle = vehicle, fillUnitIndex = fui }, amount, FillType.WATER, vehicle)
        end
    else
        -- wash: whatever the tank holds leaves at the lance and lands where the pipe end points
        local amount = math.min((c.washLitersPerSecond or 40) * dt * 0.001, lvl)
        if amount <= 0 then return end
        -- [SPS 2026-11-10] where the lance points: a chem tank within reach (sprayer, IBC, another bowser) takes the liquid
        -- with the bowser's strength (William: "use it to hand pour into a sprayer"); else it lands on the ground
        local lx, ly, lz
        if c.origWash ~= nil then lx, ly, lz = self:_llOrigEndPos(c)
        elseif self._physFreeEndNode ~= nil then local _, ex, ey, ez = self:_physFreeEndNode(c); lx, ly, lz = ex, ey, ez end
        local target, tfui = self:_llLanceTarget(vehicle, lx, ly, lz)
        local prev = SPSChemMix ~= nil and SPSChemMix.ctx or nil
        if SPSChemMix ~= nil and SPSChemMix.ctxOfVehicle ~= nil then SPSChemMix.ctx = SPSChemMix.ctxOfVehicle(vehicle, fui, ft) end
        self:removeFromSource({ type = "FILL_UNIT_ONLY", vehicle = vehicle, fillUnitIndex = fui }, amount, ft, vehicle)
        if target ~= nil then
            self:addToSource({ type = "FILL_UNIT_ONLY", vehicle = target, fillUnitIndex = tfui }, amount, ft, target)
        elseif SPSSpill ~= nil and SPSSpill.addLitres ~= nil then
            if c.origWash ~= nil then
                local x, y, z = lx, ly, lz
                if x ~= nil then SPSSpill.addLitres(x, SPSSpill.surfaceY ~= nil and SPSSpill.surfaceY(x, y, z) or y, z, amount, ft) end
            elseif self.physFreeEndSpillPos ~= nil then
                local sx, sy, sz = self:physFreeEndSpillPos(c, nil, true)
                if sx ~= nil then SPSSpill.addLitres(sx, sy, sz, amount, ft) end
            end
        end
        if SPSChemMix ~= nil then SPSChemMix.ctx = prev end
    end
end

-- Client: the wash hose's stream (called by updateLeakStreams inside its begin / end frame).
function SlurryPipeManager:_llLeakStreams()
    if SPSLeakEffect == nil then return end
    for _, entry in ipairs(self.registeredLiquidLaneVehicles or {}) do
        local v = entry.object
        if v ~= nil and entry.state.valveOpen and (entry.generator == nil or entry.generator.phase == "run") then
            for _, c in ipairs(entry.couplings) do
                -- [SPS 2026-11-09] the stream shows only while litres really leave: same test as the server tick (end in hand,
                -- tank not empty) - William saw water pouring from a wash hose lying on the ground (visual only)
                if (c.valveOpen or entry.state.valveOpen) and self:_llSpecialMode(c) == "wash" and (self:_llEvaluateSpecial(v, c, "wash")) then
                    local fui = c.fillUnitIndex or 1
                    local lvl = v.getFillUnitFillLevel ~= nil and (v:getFillUnitFillLevel(fui) or 0) or 0
                    if lvl > 0.001 and c.origWash ~= nil and c.origWash.endNode ~= nil and entityExists(c.origWash.endNode) then
                        -- original mode: straight down from the hose end in the player's hands
                        local x, y, z = getWorldTranslation(c.origWash.endNode)
                        local ty = SPSSpill ~= nil and SPSSpill.surfaceY ~= nil and SPSSpill.surfaceY(x, y, z) or (y - 1)
                        SPSLeakEffect.set(c, v, c.origWash.endNode, y, ty, v:getFillUnitFillType(fui), nil)
                    elseif lvl > 0.001 and self.physFreeEndSpillPos ~= nil then
                        local sx, ty, sz, leakNode, ny, _, _, _, frame = self:physFreeEndSpillPos(c, nil, true)
                        if sx ~= nil and leakNode ~= nil then
                            SPSLeakEffect.set(c, v, leakNode, ny, ty, v:getFillUnitFillType(fui), frame)
                        end
                    end
                end
            end
        end
    end
end

-- The generator: off -> pull (x pulls, time-based) -> run. Every peer runs it from the synced pump state.
function SlurryPipeManager:_llTickGenerator(entry, dt)
    local g, v = entry.generator, entry.object
    if g == nil or v == nil then return end
    local want = entry.state.valveOpen == true
    local function sample(n) return g[n .. "Sample"] end
    local function play(n) if v.isClient and g_soundManager ~= nil and sample(n) ~= nil then g_soundManager:playSample(sample(n)) end end
    local function stop(n) if v.isClient and g_soundManager ~= nil and sample(n) ~= nil then g_soundManager:stopSample(sample(n)) end end
    local function hasAnim(n) return n ~= nil and v.getAnimationExists ~= nil and v:getAnimationExists(n) end
    local function pullOnce()
        if hasAnim(g.pullAnim) then
            if v.setAnimationTime ~= nil then v:setAnimationTime(g.pullAnim, 0, true) end
            v:playAnimation(g.pullAnim, g.pullSpeed or 1.5, 0, true)
        end
        play("pull")
    end
    -- [SPS 2026-11-09] William: "the pull needs to happen with the sounds that start then stop to emulate an engine that's
    -- not starting, on the 3rd pull when the pull cord gets to the top the rev anim plays and the pull cord goes back".
    -- One pull = the pull animation (cord up 0..0.5, back 0.5..1) at pullSpeed: the `pull` sound at the start, the `start`
    -- sound (engine turning) from the start to the TOP of the stroke, where it stops again - except on the last pull,
    -- where the engine catches: engineLoop + revs lever, while the cord returns by itself.
    if want and g.phase == "off" then
        g.phase, g.t, g.pullsDone, g.topDone = "pull", 0, 0, false
        pullOnce(); play("start")
        llLog("generator on %s: pulling the cord", tostring(v.configFileName))
    elseif not want and g.phase ~= "off" then
        g.phase, g.t, g.pullsDone, g.topDone = "off", 0, 0, false
        stop("engineLoop"); stop("pull"); stop("start")
        if hasAnim(g.revsAnim) then v:playAnimation(g.revsAnim, -1, nil, true) end
        llLog("generator on %s: off", tostring(v.configFileName))
    end
    if g.phase == "pull" then
        g.t = g.t + dt
        local dur = 1000
        if hasAnim(g.pullAnim) and v.getAnimationDuration ~= nil then
            dur = (v:getAnimationDuration(g.pullAnim) or 1000) / math.max(0.01, g.pullSpeed or 1.5)
        end
        if not g.topDone and g.t >= dur * 0.5 then
            g.topDone = true
            stop("start")
            if g.pullsDone + 1 >= (g.pulls or 3) then
                g.phase = "run"
                play("engineLoop")
                if hasAnim(g.revsAnim) then v:playAnimation(g.revsAnim, 1, nil, true) end
                llLog("generator on %s: caught on pull %d - running", tostring(v.configFileName), g.pullsDone + 1)
            end
        elseif g.topDone and g.t >= dur + (g.pullPause or 0.4) * 1000 then
            g.pullsDone, g.t, g.topDone = g.pullsDone + 1, 0, false
            pullOnce(); play("start")
        end
    end
end

-- [SPS CHEM 2026-11-09] WATER poured into a tank that holds a booked chemical is a dilution (SPSChemMix.addFillLevel
-- books it against the chemical) - the bowser mixes concentrate (William). False for anything else.
function SlurryPipeManager.llWaterDilutes(dst, ft, dstFui)
    if dst == nil or ft ~= FillType.WATER then return false end
    if SPSChemMix == nil or SPSChemMix.isOn == nil or not SPSChemMix.isOn() or SPSChemMix.getState == nil then return false end
    -- [2026-11-09] a tank of PURE concentrate has no books (part 3) - water into it becomes the booked mix, so it dilutes too.
    -- Log 23:35 "warning_spsTransferType": the bowser held IBC concentrate, the Supercis water - refused by the books test.
    -- [SPS MKS8 2026-11-11] the receiving UNIT (a dual tank books each tank); nil = the vehicle's chem tank
    local fui = dstFui or (SPSChemMix.getChemFillUnit ~= nil and SPSChemMix.getChemFillUnit(dst) or nil)
    if fui ~= nil and SPSChemMix.isConcentrate ~= nil and dst.getFillUnitFillType ~= nil
    and (dst:getFillUnitFillLevel(fui) or 0) > 0.001 and SPSChemMix.isConcentrate(dst:getFillUnitFillType(fui)) then
        return true
    end
    local st = SPSChemMix.getState(dst, fui)
    return st ~= nil and st.type ~= nil
end

-- [SPS 2026-11-09] Is the FAR end of the pipe plugged into `c` in the player's hands (the lance of the wash hose)? The hands
-- hold one body (SPSHoseItem spec.isHeld / spec.heldNode); the end body or the two behind it count.
function SlurryPipeManager:_llWashEndHeld(c)
    local pipe = c ~= nil and c.physPipe or nil
    if pipe == nil or SPSHoseItem == nil or pipe.spsGetEnd == nil then return false end
    local spec = pipe[SPSHoseItem.SPEC_NAME]
    if spec == nil or not spec.isHeld or spec.heldNode == nil then return false end
    local e = pipe:spsGetEnd((c.physPipeEnd == 1) and 2 or 1)
    if e == nil or e.comp == nil then return false end
    for i, comp in ipairs(pipe.components or {}) do
        if comp.node == spec.heldNode then return math.abs(i - e.comp) <= 2 end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- [SPS 2026-11-09] ORIGINAL MODE on the 550 bowser (William 2026-11-09): in the bowser's arc with no partner in reach, R lays
-- the SUCTION pipe to where the player stands (its end draws when under a water surface); at the pump, X takes the WASH hose
-- into the player's hands (the end follows the player, the pump pours there) and puts it back. Both are drawn with the lane
-- hose visual from the fitting to an end node; the fitting's rack visual (#stowedVisual) hides meanwhile. Not saved.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_llOrigEndPos(c)
    local n = c ~= nil and ((c.origWash ~= nil and c.origWash.endNode) or (c.origSuction ~= nil and c.origSuction.endNode)) or nil
    if n == nil or n == 0 or not entityExists(n) then return nil end
    return getWorldTranslation(n)
end

function SlurryPipeManager:_llOrigEndInWater(c)
    local x, y, z = self:_llOrigEndPos(c)
    if x == nil or g_waterPlaneManager == nil then return false end
    local plane = g_waterPlaneManager:findWaterPlaneAtPosition(x, z)
    if plane == nil then return false end
    return plane.waterY == nil or y <= plane.waterY + (SlurryPipeManager.PHYS_WATER_END_MAX_ABOVE or 0.25)
end

local function llPlayerByUserId(userId)
    if userId == nil or userId < 0 or g_currentMission == nil or g_currentMission.playerSystem == nil then return nil end
    local ps = g_currentMission.playerSystem
    if ps.getPlayerByUserId ~= nil then return ps:getPlayerByUserId(userId) end
    return nil
end

-- [SPS 2026-11-10] the original-mode pipe in a player's hands: its state and kind (2 = wash hose, 1 = carried suction end)
local function llOrigHeld(c)
    if c == nil then return nil, nil end
    if c.origWash ~= nil then return c.origWash, 2 end
    if c.origSuction ~= nil and c.origSuction.carried then return c.origSuction, 1 end
    return nil, nil
end

function SlurryPipeManager:_llOrigFollowPlayer(c)
    local w, kind = llOrigHeld(c)
    if w == nil or w.endNode == nil or not entityExists(w.endNode) then return end
    local player = llPlayerByUserId(w.userId)
    local root = player ~= nil and player.rootNode or nil
    if root ~= nil and root ~= 0 and entityExists(root) then
        local x, y, z = getWorldTranslation(root)
        local dx, _, dz = localDirectionToWorld(root, 0, 0, 1)
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 1e-4 then dx, dz = dx / l, dz / l else dx, dz = 0, 1 end
        -- [2026-11-10] the hands hold the hose about two bodies BEHIND its end (William: "we are picking up the wash hose right
        -- at the end and that means I cannot see the end"): the end point sits LL_HOLD_AHEAD in front of the player
        local ex, ey, ez = x + dx * SlurryPipeManager.LL_HOLD_AHEAD, y + 0.9, z + dz * SlurryPipeManager.LL_HOLD_AHEAD
        -- [SPS 2026-11-10] the hose is only so long: past its reach from the outlet the end stays on the hose, pulled
        -- straight toward the player (William: "pick up the end, walk around with it")
        local fn = c.outNode or c.mountNode
        if fn ~= nil and fn ~= 0 and entityExists(fn) then
            local fx, fy, fz = getWorldTranslation(fn)
            local reach = self:llOrigPipeReach(c, kind)
            local vx, vy, vz = ex - fx, ey - fy, ez - fz
            local dist = math.sqrt(vx * vx + vy * vy + vz * vz)
            if dist > reach and dist > 1e-4 then
                local s = reach / dist
                ex, ey, ez = fx + vx * s, fy + vy * s, fz + vz * s
            end
        end
        setTranslation(w.endNode, ex, ey, ez)
        setDirection(w.endNode, dx, 0, dz, 0, 1, 0)   -- the hose arrives from behind the player, along their facing
    end
end

function SlurryPipeManager:_llOrigSetStowedVisual(entry, c, visible)
    if c.stowedVisualName == nil or entry == nil or entry.object == nil then return end
    local n = SlurryNodeUtil.findVehicleNodeByName(entry.object, c.stowedVisualName, false)
    if n ~= nil and n ~= 0 and entityExists(n) then setVisibility(n, visible) end
end

function SlurryPipeManager:_llOrigRemove(entry, c)
    local st = c.origSuction or c.origWash
    if st == nil then return end
    if st.pipeId ~= nil and self.activeLiquidLanePipes ~= nil then
        local pd = self.activeLiquidLanePipes[st.pipeId]
        if pd ~= nil and g_spsLiquidLanePipeVisual ~= nil then g_spsLiquidLanePipeVisual:destroyPipe(pd.inst) end
        self.activeLiquidLanePipes[st.pipeId] = nil
    end
    if st.endNode ~= nil and entityExists(st.endNode) then delete(st.endNode) end
    self:_llOrigLanceInput(c, false)   -- [2026-11-10] right-mouse pour prompt goes with the hose
    if not c.isConnected then self:_llNamedValves(c, false) end   -- the inlet handle back
    c.origSuction, c.origWash, c.valveOpen, c.lancePour = nil, nil, false, false
    self:_llOrigSetStowedVisual(entry, c, true)
end

-- Apply on every peer. kind 1 = suction laid at (x,y,z) / taken up; kind 2 = wash hose into userId's hands / put back.
function SlurryPipeManager:applyLiquidLaneOrigPipe(object, couplingId, kind, on, x, y, z, userId)
    local c = self:_findLiquidLaneCouplingById(object, couplingId)
    local entry = self:getLiquidLaneVehicleEntry(object)
    if c == nil or entry == nil then return end
    if kind == 3 then
        -- [SPS 2026-11-10] the wash hose's lance: pour on / off (right mouse with the end in hand, both pipe modes)
        c.lancePour = on == true
        self:_llOrigLanceText(c)
        llLog("lance pour %s on %s", on and "ON" or "OFF", tostring(object.configFileName))
        return
    end
    if kind == 4 then
        -- [SPS 2026-11-10] the CARRIED suction end is laid where it is (right mouse of its carrier): on the ground / the river
        -- bed at (x,y,z), pointing away from the bowser; the prompt goes, R at the bowser takes the pipe up again
        local st = c.origSuction
        if st == nil or not st.carried then return end
        st.carried, st.userId = false, -1
        if st.endNode ~= nil and entityExists(st.endNode) then
            setTranslation(st.endNode, x, y, z)
            local fn = c.outNode or c.mountNode
            if fn ~= nil and fn ~= 0 and entityExists(fn) then
                local fx, _, fz = getWorldTranslation(fn)
                local ddx, ddz = x - fx, z - fz
                if ddx * ddx + ddz * ddz > 1e-4 then setDirection(st.endNode, ddx, 0, ddz, 0, 1, 0) end
            end
        end
        self:_llOrigLanceInput(c, false)
        llLog("orig suction end LAID on %s at %.1f %.1f %.1f", tostring(object.configFileName), x, y, z)
        return
    end
    if not on then
        self:_llOrigRemove(entry, c)
        if g_server ~= nil and entry.state.valveOpen and entry.generator == nil then self:_llStopFlow(object, "pipe taken up") end
        llLog("orig pipe kind %d OFF on %s", kind, tostring(object.configFileName))
        return
    end
    if c.origSuction ~= nil or c.origWash ~= nil or c.isConnected then return end
    -- [SPS 2026-11-10] one pipe out at a time (William): taking the suction pipe puts the wash hose back and the other way round
    for _, cc in ipairs(entry.couplings or {}) do
        if cc ~= c and ((kind == 1 and cc.origWash ~= nil) or (kind == 2 and cc.origSuction ~= nil)) then
            self:_llOrigRemove(entry, cc)
            if g_server ~= nil and entry.state.valveOpen and entry.generator == nil then self:_llStopFlow(object, "other pipe taken") end
            llLog("orig pipe: the other pipe of %s put back (one in use at a time)", tostring(object.configFileName))
        end
    end
    local node = createTransformGroup(kind == 1 and "spsOrigSuctionEnd" or "spsOrigWashEnd")
    link(getRootNode(), node)
    setTranslation(node, x, y, z)
    -- [SPS 2026-11-10] both pipes START in the player's hands (William: "connect the end and then walk out the rest"): the
    -- end follows userId's player (updateLiquidLanes -> _llOrigFollowPlayer); the suction end is laid by its right mouse
    local st = { endNode = node, userId = userId, carried = true }
    if kind == 1 then c.origSuction = st else c.origWash = st end
    -- [SPS 2026-11-10] the engine already running (B before the pipe was taken): this fitting is live now. Before, only the
    -- couplings that were special AT the B press got valveOpen (applyLiquidLaneValveState) - log 11:17: B at :19 with nothing
    -- in hand, wash hose taken at :33, pour ON at :35, nothing flowed, "the valve for the wash pipe is closed" (William)
    c.valveOpen = entry.state.valveOpen == true
    if c.valveOpen then self:_llNamedValves(c, true) end   -- the inlet handle swings with a live fitting
    local vis = g_spsLiquidLanePipeVisual
    if vis ~= nil and vis:isReady() then
        -- [SPS 2026-11-10] the fitting's OWN pipe (hoses.xml key = the fitting's waterSource / washOutlet, drawn from
        -- i3d/pipes/bowserHoses.i3d); the generic 80 mm lane hose only when that key is not loaded (log 09:37 "WATER hose
        -- drawn ... end=spsOrigSuctionEnd" = William's "wrong pipe").
        -- A pipe LEAVES a fitting along its inNode's -Z (= outNode +Z; SPSHoseItem:spsPlaceEnd). The wash outlet has no
        -- outNode: from its mount with sign -1 - from the mount with +1 the hose set off INTO the trailer (William 10:21).
        local key = kind == 1 and c.waterSourceKey or c.washOutletKey
        local startNode, startSign = c.outNode, 1
        if startNode == nil or startNode == 0 or not entityExists(startNode) then startNode, startSign = c.mountNode, -1 end
        local inst = nil
        if key ~= nil and vis.hasPipeVariant ~= nil and vis:hasPipeVariant(key) then
            -- no capsules: a carried hose must not block its carrier; a big droop so the hose lies on the ground between
            -- the fitting and the hands instead of standing as a stiff arc
            inst = vis:createPipeKeyed(key, startNode, node, { physics = false, startSign = startSign, sagFactor = SlurryPipeManager.LL_ORIG_SAG })
        end
        if inst == nil then
            llLog("orig pipe kind %d: no hose variant '%s' loaded - generic water hose", kind, tostring(key))
            inst = vis:createPipe(c.outNode or c.mountNode, node, "water")
        end
        if inst ~= nil then
            local pipeId = self._nextLiquidLanePipeId
            self._nextLiquidLanePipeId = pipeId + 1
            self.activeLiquidLanePipes[pipeId] = { inst = inst, couplingA = c, couplingB = { mountNode = node } }
            st.pipeId = pipeId
        end
    end
    self:_llOrigSetStowedVisual(entry, c, false)
    self:_llOrigFollowPlayer(c)
    self:_llOrigLanceInput(c, true)
    llLog("orig pipe kind %d ON (in hand) on %s at %.1f %.1f %.1f (user %s)", kind, tostring(object.configFileName), x, y, z, tostring(userId))
end
SlurryPipeManager.LL_ORIG_SAG = 0.5   -- droop share of the span for the bowser's original-mode pipes (floor clamp lays them)
SlurryPipeManager.LL_HOLD_AHEAD = 1.0 -- m in front of the player root where a carried hose END sits (hands ~0.4 m, so ~0.6 m of hose shows)

-- [SPS 2026-11-10] How far an ORIGINAL-mode pipe of this fitting reaches: its own hose's rest length (the end pieces are
-- rigid, so a little short of it) when the keyed hose is loaded, else the fitting's reach. kind 1 = suction, 2 = wash.
SlurryPipeManager.LL_ORIG_REACH_MARGIN = 0.3
function SlurryPipeManager:llOrigPipeReach(c, kind)
    local key = kind == 1 and c.waterSourceKey or c.washOutletKey
    local vis = g_spsLiquidLanePipeVisual
    if key ~= nil and vis ~= nil and vis.pipeVariantRestLength ~= nil then
        local rest = vis:pipeVariantRestLength(key)
        if rest ~= nil and rest > 1 then return rest - SlurryPipeManager.LL_ORIG_REACH_MARGIN end
    end
    return c.maxPipeLength or 7.5
end

-- [SPS 2026-11-10] How far two couplers may be apart to connect / stay connected: a fitting with its own partner hose (the
-- bowser's 7.67 m small hose) reaches that hose's length; otherwise the 80 mm rule (both reaches capped at the 4.16 m water hose).
function SlurryPipeManager:llConnectReach(cA, cB)
    local vis = g_spsLiquidLanePipeVisual
    if vis ~= nil and vis.pipeVariantRestLength ~= nil then
        for _, c in ipairs({ cA, cB }) do
            if c.partnerHoseKey ~= nil then
                local rest = vis:pipeVariantRestLength(c.partnerHoseKey)
                if rest ~= nil and rest > 1 then return rest - SlurryPipeManager.LL_ORIG_REACH_MARGIN end
            end
        end
    end
    return math.min(SPS_MAX_CONNECT_DIST, (cA ~= nil and cA.maxPipeLength) or 7.5, (cB ~= nil and cB.maxPipeLength) or 7.5)
end

-- [SPS 2026-11-10] The ONE distance between two couplers, for the connect gate AND the drop check: mount node to mount node
-- (the arc apex only when a side has no mount node). Before, connect measured the arc apexes and drop measured the mounts,
-- and the Supercis arc group sits 6 cm off its mount - a connect at 3.98 m apex was a 4.03 m mount gap, dropped at once.
function SlurryPipeManager:llCouplingGap(cA, cB)
    local function nodeOf(c)
        if c == nil then return nil end
        local n = c.mountNode
        if n == nil or n == 0 or not entityExists(n) then
            n = self:_getCouplingArcNodes(c)
        end
        if n == nil or n == 0 or not entityExists(n) then return nil end
        return n
    end
    local a, b = nodeOf(cA), nodeOf(cB)
    if a == nil or b == nil then return math.huge end
    local ax, ay, az = getWorldTranslation(a)
    local bx, by, bz = getWorldTranslation(b)
    return MathUtil.vector3Length(ax - bx, ay - by, az - bz)
end

-- [SPS 2026-11-10] How far a CONNECTED pair may drift before the hose is dropped: the connect reach plus the margin, so a
-- pair that connected at the edge of its reach stays connected (SPS_REACH_DROP_MARGIN, SlurryPipeManager.lua).
function SlurryPipeManager:llDropReach(cA, cB)
    return self:llConnectReach(cA, cB) + (SPS_REACH_DROP_MARGIN or 0.5)
end

-- [SPS 2026-11-10] A tanker hosed to a SPRAYER (bridge): the sprayer's B is the valve on both ends in original mode (valves open
-- with the flow, as at a silo) - the tanker's NAMED valve animations (550 bowser waterInletValve) follow it (William: "the sprayer
-- side opened the valve but the bowser side stayed shut").
-- [2026-11-10] ...and since the handle now goes over with the connection itself (applyLiquidLaneConnect), the sprayer's B
-- only ever opens it; it comes back on the disconnect.
function SlurryPipeManager:_llBridgeNamedValves(vehicle, open)
    if open ~= true then return end
    local b = self.activeLiquidLaneBridges ~= nil and vehicle ~= nil and self.activeLiquidLaneBridges[vehicle] or nil
    if b ~= nil and b.cV ~= nil and b.cV.physPipe == nil then self:_llNamedValves(b.cV, true) end
end

-- [SPS 2026-11-10] A fitting with its own pipes (acceptPipes) connects with ITS hose, never the generic one (William: "the only
-- hose that can connect here is the bowser's own"): the partner key (WT_SMALL), drawn from that fitting (outNode, or the mount
-- with sign -1: a pipe leaves a fitting along its inNode's -Z) to the partner's inNode. Either side may be the bowser. nil = no
-- such fitting on either side, or its hose variant is not loaded - the caller draws the generic hose.
function SlurryPipeManager:_llKeyedPartnerHose(cA, cB)
    local vis = g_spsLiquidLanePipeVisual
    if vis == nil or vis.hasPipeVariant == nil or not vis:isReady() then return nil end
    local src, dst = nil, nil
    if cA ~= nil and cA.partnerHoseKey ~= nil and vis:hasPipeVariant(cA.partnerHoseKey) then src, dst = cA, cB
    elseif cB ~= nil and cB.partnerHoseKey ~= nil and vis:hasPipeVariant(cB.partnerHoseKey) then src, dst = cB, cA end
    if src == nil or dst == nil then return nil end
    local startNode, startSign = src.outNode, 1
    if startNode == nil or startNode == 0 or not entityExists(startNode) then startNode, startSign = src.mountNode, -1 end
    local endNode = dst.inNode or dst.mountNode
    if startNode == nil or startNode == 0 or endNode == nil or endNode == 0 then return nil end
    local inst = vis:createPipeKeyed(src.partnerHoseKey, startNode, endNode, { startSign = startSign })
    if inst ~= nil then llLog("partner hose %s drawn from %s", tostring(src.partnerHoseKey), tostring(src.object and src.object.configFileName)) end
    return inst
end

-- [SPS 2026-11-10] ORIGINAL mode, the wash hose in the LOCAL player's hands: right mouse (the hands' secondary action, the
-- same button that starts the pour from the bought hose in pipe mode) toggles the pour. Registered in the player's input
-- context when the hose is taken, removed when it goes back / away. Other players' hoses register nothing here.
-- Right mouse with an original-mode pipe in hand: wash hose = pour on / off (kind 3); carried suction end = lay it here
-- (kind 4: on the ground under the hands - the river bed when wading - so B can then pump).
function SlurryPipeManager._llOrigLanceAction(c, actionName, inputValue)
    if inputValue == nil or inputValue <= 0 or c == nil or c.object == nil or SPSLiquidLaneOrigPipeEvent == nil then return end
    local st, kind = llOrigHeld(c)
    if st == nil then return end
    -- the X key also drives this action in William's bindings: X is take / return at the pump, never the pour
    if Input ~= nil and Input.isKeyPressed ~= nil and Input.KEY_x ~= nil and Input.isKeyPressed(Input.KEY_x) then return end
    -- one toggle per press: the log of 10:38 showed ON / OFF pairs 0.2 s apart
    local now = g_time or 0
    if c._lanceLastPress ~= nil and now - c._lanceLastPress < 300 then return end
    c._lanceLastPress = now
    if kind == 1 then
        if st.endNode == nil or not entityExists(st.endNode) then return end
        local x, y, z = getWorldTranslation(st.endNode)
        local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
        local gy = y
        if terrain ~= nil then
            gy = getTerrainHeightAtWorldPos(terrain, x, 0, z)
            if SPSPipeVisual ~= nil and SPSPipeVisual.getFloorWorldY ~= nil then gy = SPSPipeVisual.getFloorWorldY(x, y, z, gy) end
        end
        if g_server ~= nil and g_slurryPipeManager ~= nil then g_slurryPipeManager:applyLiquidLaneOrigPipe(c.object, c.id, 4, true, x, gy, z, -1) end
        SPSLiquidLaneOrigPipeEvent.sendEvent(c.object, c.id, 4, true, x, gy, z, -1)
        llLog("suction (original mode): right mouse -> laid at %.1f %.1f %.1f", x, gy, z)
        return
    end
    local on = not c.lancePour
    if g_server ~= nil and g_slurryPipeManager ~= nil then g_slurryPipeManager:applyLiquidLaneOrigPipe(c.object, c.id, 3, on, 0, 0, 0, -1) end
    SPSLiquidLaneOrigPipeEvent.sendEvent(c.object, c.id, 3, on, 0, 0, 0, -1)
    llLog("lance (original mode): right mouse -> pour %s", on and "ON" or "OFF")
end

function SlurryPipeManager:_llOrigLanceText(c)
    if c == nil or c._lanceEventId == nil or g_inputBinding == nil then return end
    local _, kind = llOrigHeld(c)
    local key = (kind == 1) and "action_spsLaySuction" or (c.lancePour and "action_spsLancePourOff" or "action_spsLancePourOn")
    g_inputBinding:setActionEventText(c._lanceEventId, g_i18n:getText(key))
end

function SlurryPipeManager:_llOrigLanceInput(c, on)
    if c == nil or g_inputBinding == nil then return end
    if c._lanceEventId ~= nil then
        g_inputBinding:removeActionEvent(c._lanceEventId)
        c._lanceEventId = nil
    end
    local st = llOrigHeld(c)
    if not on or st == nil or g_currentMission == nil then return end
    if st.userId == nil or st.userId < 0 or st.userId ~= g_currentMission.playerUserId then return end
    -- [SPS 2026-11-10] the hands' secondary action (right mouse): a mod action of our own bound to MOUSE_BUTTON_RIGHT never
    -- fired on foot (log 10:50-10:56: no "right mouse" line at all) - the game's own on-foot mouse bindings win the conflict
    -- silently (same finding as FS25_RealFarmContracts' modDesc notes). This action is also on X in William's bindings;
    -- _llOrigLanceAction ignores the press while X is held, so X stays take / return only.
    local action = InputAction.ACTIVATE_HANDTOOL_SECONDARY
    if action == nil then return end
    local _, id = g_inputBinding:registerActionEvent(action, c,
        SlurryPipeManager._llOrigLanceAction, false, true, false, true, nil, true, false)
    if id ~= nil then
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(id, true)
        c._lanceEventId = id
        self:_llOrigLanceText(c)
    end
    -- X = put back: the pump control's OWN X event - it follows the holder (SPSLiquidLaneControl _localHolds). A second
    -- event of ours on SPS_TOGGLE_ANIMATION was refused by the engine while the control's existed (InputBinding:
    -- registerActionEvent, one event per action + trigger code) - log 11:16-11:19: no return at all.
end

-- [SPS 2026-11-10] A chem tank (sprayer, IBC, bowser - anything SPSChemMix books) whose fill point is within reach of the
-- lance end at (x,y,z): vehicle, fillUnitIndex, else nil.
SlurryPipeManager.LL_LANCE_REACH = 1.5
function SlurryPipeManager:_llLanceTarget(bowser, x, y, z)
    if x == nil or SPSChemMix == nil or SPSChemMix.getChemFillUnit == nil then return nil end
    local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    local best, bestFui, bestD = nil, nil, SlurryPipeManager.LL_LANCE_REACH
    for _, v in ipairs(vs ~= nil and vs.vehicles or {}) do
        if v ~= bowser and v.spec_fillUnit ~= nil then
            local fui = SPSChemMix.getChemFillUnit(v)
            local fu = fui ~= nil and v.spec_fillUnit.fillUnits[fui] or nil
            if fu ~= nil then
                local node = (fu.exactFillRootNode ~= nil and fu.exactFillRootNode ~= 0 and entityExists(fu.exactFillRootNode)) and fu.exactFillRootNode or v.rootNode
                if node ~= nil and node ~= 0 and entityExists(node) then
                    local nx, ny, nz = getWorldTranslation(node)
                    local d = MathUtil.vector3Length(nx - x, ny - y, nz - z)
                    if d < bestD then best, bestFui, bestD = v, fui, d end
                end
            end
        end
    end
    return best, bestFui
end

-- Holders out of the global stow list, generator samples gone (unregister / failed registration).
function SlurryPipeManager:_llCleanupExtras(entry)
    if entry == nil then return end
    for _, c in ipairs(entry.couplings or {}) do   -- [2026-11-09] original-mode pipes of a vanishing vehicle
        if c.origSuction ~= nil or c.origWash ~= nil then self:_llOrigRemove(entry, c) end
    end
    for _, ph in ipairs(entry.pipeHolderEntries or {}) do
        for j, h in ipairs(self.pipeHolderEntries or {}) do
            if h == ph then table.remove(self.pipeHolderEntries, j) break end
        end
    end
    entry.pipeHolderEntries = nil
    local g = entry.generator
    if g ~= nil and g_soundManager ~= nil then
        for _, n in ipairs({ "pullSample", "startSample", "engineLoopSample" }) do
            if g[n] ~= nil then g_soundManager:deleteSample(g[n]); g[n] = nil end
        end
    end
end

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
            -- [SPS CHEM 2026-11-06] a sprayer <-> tanker hose is a physical pipe: its plug events rebuild it, not a lane event
            if cV ~= nil and cP ~= nil and vehicle ~= nil and b.owner ~= nil and not b.sprayerSide and not b.physChain then   -- [SPS MKS8] phys chains: plug events
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
    -- [SPS MKS8 2026-11-10] the selected tank of every multi-tank fitting that is not on tank 1 (by mount position)
    local tIdx = 0
    for _, vEntry in ipairs(self.registeredLiquidLaneVehicles or {}) do
        for _, cV in ipairs(vEntry.couplings) do
            if cV.tanks ~= nil and (cV.selectedTank or 1) ~= 1 and cV.mountNode ~= nil and entityExists(cV.mountNode) then
                local ax, ay, az = getWorldTranslation(cV.mountNode)
                local base = string.format("slurryPipeSystem.liquidTankSelections.selection(%d)", tIdx)
                xmlFile:setFloat(base .. "#x", ax); xmlFile:setFloat(base .. "#y", ay); xmlFile:setFloat(base .. "#z", az)
                xmlFile:setInt(base .. "#tank", cV.selectedTank)
                tIdx = tIdx + 1
            end
        end
    end
end

function SlurryPipeManager:_llApplyPendingTankSelections(vehicle, entry)
    local list = self._pendingTankSelections
    if list == nil or #list == 0 or entry == nil then return end
    for _, p in ipairs(list) do
        if not p.applied then
            for _, c in ipairs(entry.couplings) do
                if c.tanks ~= nil and c.mountNode ~= nil and entityExists(c.mountNode) then
                    local cx, cy, cz = getWorldTranslation(c.mountNode)
                    if MathUtil.vector3Length(cx - p.x, cy - p.y, cz - p.z) <= 0.1 then
                        p.applied = true
                        self:applyLiquidLaneTankSelect(vehicle, c.id, p.tank)
                    end
                end
            end
        end
    end
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
    -- [SPS MKS8 2026-11-10] selected tanks (applied when the vehicle registers, _llApplyPendingTankSelections)
    self._pendingTankSelections = {}
    local tIdx = 0
    while true do
        local base = string.format("slurryPipeSystem.liquidTankSelections.selection(%d)", tIdx)
        if not xmlFile:hasProperty(base) then break end
        table.insert(self._pendingTankSelections, {
            x = xmlFile:getFloat(base .. "#x", 0), y = xmlFile:getFloat(base .. "#y", 0), z = xmlFile:getFloat(base .. "#z", 0),
            tank = xmlFile:getInt(base .. "#tank", 1), applied = false,
        })
        tIdx = tIdx + 1
    end
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
