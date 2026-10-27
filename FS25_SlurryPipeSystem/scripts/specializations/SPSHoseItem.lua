-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSHoseItem.lua
-- [SPS 1.0.1.8] Vehicle specialization for the BOUGHT pipe (vehicles/hoses/pipe_F_M.xml - physics
-- test build 2026-10-15; 05_PROJECT_DOCS/BOUGHT_HOSES_PLAN.md).
--
-- The pipe is a PHYSICS vehicle: 13 dynamic capsule components (col01..col13, the skin bone of
-- that section inside each) joined by 12 componentJoints declared in the XML. The engine bends
-- the pipe, the capsules keep it out of the ground / buildings / vehicles / the player, and the
-- skinned mesh (child of col01) follows the bones. There is no code-driven curve here any more.
-- This spec does what the engine does not:
--   * COLOUR - the designColor configuration goes onto the mesh's hose_mat slot (colorScale);
--   * HANDS  - the vanilla hands (HandToolHands) target any DYNAMIC node carrying the
--     VEHICLE / DYNAMIC_OBJECT collision bit, accept the object when getTotalMass <= 0.2 t and
--     supportsPickUp, then hold heldItemNode = object.rootNode (= col01) at ITS centre of mass
--     (HandToolHands.lua:545-552, createItemJoint :619-669). Our hook on pickUpTarget swaps
--     heldItemNode to the component the ray actually hit, so the joint (made a physics frame
--     later on the server) holds the pipe where the player grabbed it and the rest hangs from
--     that col through the joints. R is NOT used for picking up.
--   * ENDS   - two pipe ends (hoseStart on the first body, hoseEnd on the last), each with a
--     gender. An end PLUGGED into a coupling (SPSM_PhysPipes; mouse controls in SPSHoseItemHands)
--     has its body set KINEMATIC on the server and is placed on the coupling node every frame
--     (spsPlaceEnd) so it rides a moving tanker; the other 12 bodies hang off it through the
--     joints. Unplugged -> DYNAMIC again. Clients' components are kinematic anyway
--     (Vehicle.lua:2494) and follow the server's component sync (writeUpdateStream writes every
--     non-static component, :1402-1408). Overstretch (ends further apart than the rest length
--     + margin, e.g. the tanker drives off) unplugs the vehicle end - the original system's
--     auto-disconnect, physical edition.
--
-- Engine facts (decoded dataS): HandToolHands.TARGET_MASK DYNAMIC_OBJECT+TREE+VEHICLE (:5),
-- MAXIMUM_PICKUP_MASS 0.2 t (:6), getCanPickUpNode (:368-395), pickUpTarget (:545-586),
-- createItemJoint reads spec_hands.heldItemNode (:625-629), drop/throw/break all read the same
-- field; Vehicle:loadComponentFromXML registers EVERY component node with addNodeObject
-- (Vehicle.lua:2577) so getNodeObject(col) = this vehicle; Vehicle:getCanBePickedUp =
-- supportsPickUp (:2987); Player.hands = the equipped hands tool (Player.lua:429);
-- target record {node, x, y, z, distance} (PlayerTargeter.lua:98-103).

SPSHoseItem = {}
SPSHoseItem.MOD_NAME  = g_currentModName
SPSHoseItem.SPEC_NAME = string.format("spec_%s.spsHoseItem", g_currentModName)
SPSHoseItem.STRETCH_MARGIN = 1.15   -- unplug the vehicle end when the ends are further apart than rest x this
-- [SPS 1.0.1.8] Bodies BEYOND the end body that are held rigid (kinematic, at their straight rest offset) while the
-- end is plugged in. The pipe is one skinned mesh with a bone per body; with only the end body pinned, chain tension
-- (two pipes joined) pulled the neighbour's bone and skewed the skinned collar off the fitting (William's screenshot,
-- 2026-10-18). Safe inside the vehicle's hull since 1.0.1.9: the whole pipe is pair-collision OFF against the vehicle
-- it is plugged into (spsSetVehiclePairCollision), so a kinematic neighbour there cannot shove the tanker.
SPSHoseItem.PLUG_RIGID_NEIGHBOURS = 1
SPSHoseItem._i3dRest = {}   -- i3d path -> { [nodeName] = {x, y, z} } (rest translations of the top-level bodies)
-- [SPS 1.0.1.9] 0: no body loses its VEHICLE bit any more (was 2 = ~1 m of pipe, which still left the TSA's 3rd body
-- inside the tanker - player report + William 2026-10-25). Replaced by setPairCollision against the plugged vehicle
-- only (the game's own idiom for a bale on a loader / a mounted object: MountableObject:mountKinematic). The pipe keeps
-- every other collision: ground, buildings, player, OTHER vehicles, other pipes. The plugged end body itself still
-- collides with nothing while plugged (it sits inside the fitting) - spsSetEndCollision k=0.
SPSHoseItem.NO_VEHICLE_NEIGHBOURS = 0
-- [SPS 1.0.1.8] the three shop selectors of vehicles/hoses/spsPipe.xml (titles come from the XML's #title attribute)
SPSHoseItem.SHOP_CONFIGS = {
    { name = "spsPipeType",   title = "Pipe"   },   -- 1 slurry, 2 water, 3 milk
    { name = "spsPipeLength", title = "Length" },   -- 1 = 4 m, 2 = 6 m
    { name = "spsPipeEnds",   title = "Ends"   },   -- 1 F/M, 2 F/F, 3 M/M (slurry only)
}

-- Component configuration (spsPipe.xml order: 1-3 slurry 4 m FM FF MM, 4-6 slurry 6 m, 7/8 water 4/6 m, 9/10 milk
-- 4/6 m) for a Type / Length / Ends choice. nil when the vehicle does not use the shop selectors.
function SPSHoseItem.componentForShopChoice(pipeType, length, ends)
    if pipeType == nil then return nil end
    local long = (length == 2) and 1 or 0
    if pipeType == 2 then return 7 + long end
    if pipeType == 3 then return 9 + long end
    return long * 3 + math.max(1, math.min(3, ends or 1))
end

local function say(fmt, ...)
    spsInfo("[SPS HOSE ITEM] " .. string.format(fmt, ...))
end
local function valid(n) return n ~= nil and n ~= 0 and entityExists(n) end

-- [SPS 1.0.1.8] A body's collision mask lives on EVERY collision shape of the body: the root capsule AND its
-- compoundChild shapes - setCollisionFilterMask on the root does not reach them (the game tests shapes one by one:
-- I3DManager / CollisionFlag.checkCollisionMaskRec). EXCEPT the grab cubes startGrab / endGrab (2026-10-18): they
-- are what the player aims at to take a plugged-in end back out of a coupler, so they KEEP their collision at all
-- times (William: "set far enough back to not cause issues" with the tanker); only the capsules are masked.
SPSHoseItem.GRAB_NODES = { startGrab = true, endGrab = true }
-- includeGrabs: the grab cubes take the mask too. Off for the PLUG masks (a plugged end's cube keeps full collision so
-- the player can aim at it), ON for the stow / rest masks: a STOWED pipe is kinematic on the rack and a cube left with
-- its VEHICLE bit inside the tank shoved the tanker sideways (William 2026-10-19 11:27, water hose on holder 2).
-- PROVEN 2026-10-19 11:49 (log): a compoundChild cube reports RigidBodyType NONE, so a "has a rigid body" test skips
-- it - the cubes never took ANY mask and kept full vehicle collision on every pipe. Child collision shapes are told
-- apart from the skinned mesh by getShapeIsSkinned instead.
local function setBodyMask(node, mask, includeGrabs)
    setCollisionFilterMask(node, mask)
    for i = 0, getNumOfChildren(node) - 1 do
        local c = getChildAt(node, i)
        if getHasClassId(c, ClassIds.SHAPE) and not getShapeIsSkinned(c)
           and (includeGrabs or not SPSHoseItem.GRAB_NODES[getName(c) or ""]) then
            setCollisionFilterMask(c, mask)
        end
    end
end

function SPSHoseItem.prerequisitesPresent(specializations)
    return true
end

function SPSHoseItem.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("SPSHoseItem")
    schema:register(XMLValueType.STRING,     "vehicle.spsHose#hoseKey",        "SPS hose key (FM, FF, MM, WATER, MILK)", "FM")
    schema:register(XMLValueType.NODE_INDEX, "vehicle.spsHose#meshNode",       "The skinned hose mesh (colour target)")
    schema:register(XMLValueType.NODE_INDEX, "vehicle.spsHose#startNode",      "Hose start coupling point (+Z = hose direction)")
    schema:register(XMLValueType.NODE_INDEX, "vehicle.spsHose#endNode",        "Hose end coupling point (+Z = arrival direction)")
    schema:register(XMLValueType.BOOL,       "vehicle.spsHose#tintable",       "The colour configuration applies to the rubber", true)
    schema:register(XMLValueType.STRING,     "vehicle.spsHose#startGender",    "Gender of the hose START end (female|male)", "female")
    schema:register(XMLValueType.STRING,     "vehicle.spsHose#endGender",      "Gender of the hose END end (female|male)", "male")
    schema:register(XMLValueType.INT,        "vehicle.spsHose#startComponent", "1-based component index the start end belongs to", 1)
    schema:register(XMLValueType.INT,        "vehicle.spsHose#endComponent",   "1-based component index the end end belongs to", 13)
    -- [SPS 1.0.1.8] one shop item, several pipes: a <variant> per component configuration (slurryPipe.xml)
    schema:register(XMLValueType.INT,        "vehicle.spsHose.variant(?)#config",      "1-based component configuration this variant belongs to")
    schema:register(XMLValueType.STRING,     "vehicle.spsHose.variant(?)#hoseKey",     "SPS hose key of this variant")
    schema:register(XMLValueType.NODE_INDEX, "vehicle.spsHose.variant(?)#meshNode",    "Skinned mesh of this variant")
    schema:register(XMLValueType.NODE_INDEX, "vehicle.spsHose.variant(?)#startNode",   "Hose start of this variant")
    schema:register(XMLValueType.NODE_INDEX, "vehicle.spsHose.variant(?)#endNode",     "Hose end of this variant")
    schema:register(XMLValueType.STRING,     "vehicle.spsHose.variant(?)#startGender", "Gender of the start end")
    -- [SPS 1.0.1.8] 0-based material index of the rubber (hose_mat) on the mesh - used when no material slot is
    -- NAMED hose_mat (the colour must never reach the metal fittings; the long pipes carry hose_mat first)
    schema:register(XMLValueType.INT,        "vehicle.spsHose#hoseMaterialIndex",            "0-based index of the rubber material on the mesh")
    schema:register(XMLValueType.INT,        "vehicle.spsHose.variant(?)#hoseMaterialIndex", "0-based index of the rubber material on this variant's mesh")
    schema:register(XMLValueType.STRING,     "vehicle.spsHose.variant(?)#endGender",   "Gender of the end end")
    -- [SPS 1.0.1.8] one shop item for every pipe (vehicles/hoses/spsPipe.xml): per-variant body count, tint and rubber colour
    schema:register(XMLValueType.INT,        "vehicle.spsHose.variant(?)#endComponent", "1-based component index of this variant's end body")
    schema:register(XMLValueType.BOOL,       "vehicle.spsHose.variant(?)#tintable",     "The colour configuration applies to this variant's rubber")
    schema:register(XMLValueType.COLOR,      "vehicle.spsHose.variant(?)#rubberColor",  "Fixed rubber colour of this variant (water / milk)")
    schema:register(XMLValueType.FLOAT,      "vehicle.spsHose.variant(?)#dirtScale",    "Dirt rate factor of this variant (water / milk 0.5: clean liquids)", 1)
    schema:setXMLSpecializationType()
    -- [SPS 1.0.1.8] ONE SHOP PAGE (William 2026-10-24): three shop selectors Type / Length / Ends. The engine picks the
    -- bodies by the "component" configuration only, so these three are our own configuration types and
    -- SPSHoseItem:onPreLoad (runs before the i3d / components load, Vehicle.lua:518) sets "component" from them.
    -- Each Type option carries a dependentConfiguration on "component", which hides the component list in the shop
    -- (ShopConfigScreen.lua:1187-1199). XML: vehicle.spsHose.<name>Configurations.<name>Configuration(?)
    -- (ConfigurationManager:addConfigurationType). Their XML paths are registered here because Vehicle.postInit
    -- registered the game's own configuration paths before mod specializations exist.
    for _, ct in ipairs(SPSHoseItem.SHOP_CONFIGS) do
        if g_vehicleConfigurationManager:getConfigurationDescByName(ct.name) == nil then
            g_vehicleConfigurationManager:addConfigurationType(ct.name, ct.title, "spsHose", VehicleConfigurationItem)
            local desc = g_vehicleConfigurationManager:getConfigurationDescByName(ct.name)
            if desc ~= nil then
                VehicleConfigurationItem.registerXMLPaths(schema, desc.configurationsKey, desc.configurationKey .. "(?)")
            end
        end
    end
    -- [SPS 1.0.1.8] Savegame (key = vehicle key + "." + <modName>.spsHoseItem, Vehicle.lua:1189-1194): where each
    -- end was - plugged into a coupling (owner's unique id + coupling id + which system) and / or joined to
    -- another pipe's end (its unique id + end). Restored by SPSM_PhysPipes once the owners have registered.
    local sg = Vehicle.xmlSchemaSavegame
    if sg ~= nil then
        -- NOTE: g_currentModName is only this mod's name while its scripts are being sourced; initSpecialization
        -- runs later (TypeManager finalize, mission load) - use the file-scope copy or the path registers under
        -- the wrong name and every setValue in saveToXMLFile fails "Path not registered" (William's save 00:14).
        local base = string.format("vehicles.vehicle(?).%s.spsHoseItem.end(?)", SPSHoseItem.MOD_NAME)
        sg:register(XMLValueType.STRING, base .. "#owner",     "Unique id of the vehicle / placeable the end is plugged into")
        sg:register(XMLValueType.INT,    base .. "#coupling",  "Coupling id on that owner")
        sg:register(XMLValueType.BOOL,   base .. "#placeable", "Owner is a placeable", false)
        sg:register(XMLValueType.BOOL,   base .. "#lane",      "Coupling belongs to the 80 mm liquid-lane system", false)
        sg:register(XMLValueType.BOOL,   base .. "#sprayer",   "Coupling belongs to the fert / herb sprayer system", false)
        sg:register(XMLValueType.BOOL,   base .. "#valveOpen", "Valve of that coupling was open (slurry coupler valve / lane fitting ball valve)", false)
        sg:register(XMLValueType.STRING, base .. "#joinPipe",  "Unique id of the pipe this end is joined to")
        sg:register(XMLValueType.INT,    base .. "#joinEnd",   "End index (1 / 2) on that pipe")
        -- [SPS 1.0.1.8] stowed on a vehicle's pipe holder (SPSHoseItem:spsStow)
        local sb = string.format("vehicles.vehicle(?).%s.spsHoseItem.stow", SPSHoseItem.MOD_NAME)
        sg:register(XMLValueType.STRING, sb .. "#vehicle", "Unique id of the vehicle whose pipe holder this pipe is stowed on")
        sg:register(XMLValueType.INT,    sb .. "#holder",  "Pipe holder id on that vehicle")
        sg:register(XMLValueType.STRING, sb .. "#slot",    "Slot (placement) name under that holder")
    end
end

function SPSHoseItem.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "spsGetHoseKey",         SPSHoseItem.spsGetHoseKey)
    SpecializationUtil.registerFunction(vehicleType, "spsApplyColor",         SPSHoseItem.spsApplyColor)
    SpecializationUtil.registerFunction(vehicleType, "spsGetComponentIndex",  SPSHoseItem.spsGetComponentIndex)
    SpecializationUtil.registerFunction(vehicleType, "spsOnGrabbed",          SPSHoseItem.spsOnGrabbed)
    SpecializationUtil.registerFunction(vehicleType, "spsSetPlayerCollision", SPSHoseItem.spsSetPlayerCollision)
    SpecializationUtil.registerFunction(vehicleType, "spsGetEnd",             SPSHoseItem.spsGetEnd)
    SpecializationUtil.registerFunction(vehicleType, "spsAttachEnd",          SPSHoseItem.spsAttachEnd)
    SpecializationUtil.registerFunction(vehicleType, "spsUpdateBoundingSphere", SPSHoseItem.spsUpdateBoundingSphere)   -- [SPS 1.0.1.9] render culling
    SpecializationUtil.registerFunction(vehicleType, "spsDetachEnd",          SPSHoseItem.spsDetachEnd)
    SpecializationUtil.registerFunction(vehicleType, "spsPlaceEnd",           SPSHoseItem.spsPlaceEnd)
    SpecializationUtil.registerFunction(vehicleType, "spsUpdateEnds",         SPSHoseItem.spsUpdateEnds)
    SpecializationUtil.registerFunction(vehicleType, "spsSetEndCollision",    SPSHoseItem.spsSetEndCollision)
    SpecializationUtil.registerFunction(vehicleType, "spsSetVehiclePairCollision", SPSHoseItem.spsSetVehiclePairCollision)
    SpecializationUtil.registerFunction(vehicleType, "spsPlaceEndAt",         SPSHoseItem.spsPlaceEndAt)
    SpecializationUtil.registerFunction(vehicleType, "spsJoinEnd",            SPSHoseItem.spsJoinEnd)
    SpecializationUtil.registerFunction(vehicleType, "spsUnjoinEnd",          SPSHoseItem.spsUnjoinEnd)
    SpecializationUtil.registerFunction(vehicleType, "spsIsEndBusy",          SPSHoseItem.spsIsEndBusy)
    SpecializationUtil.registerFunction(vehicleType, "spsApplyCollision", SPSHoseItem.spsApplyCollision)
    SpecializationUtil.registerFunction(vehicleType, "spsBuildRigidRuns",     SPSHoseItem.spsBuildRigidRuns)
    SpecializationUtil.registerFunction(vehicleType, "spsStow",               SPSHoseItem.spsStow)
    SpecializationUtil.registerFunction(vehicleType, "spsUnstow",             SPSHoseItem.spsUnstow)
    SpecializationUtil.registerFunction(vehicleType, "spsPlaceStow",          SPSHoseItem.spsPlaceStow)
    SpecializationUtil.registerFunction(vehicleType, "spsRestZs",             SPSHoseItem.spsRestZs)
    SpecializationUtil.registerFunction(vehicleType, "spsIsStowed",           SPSHoseItem.spsIsStowed)
    SpecializationUtil.registerFunction(vehicleType, "spsGetUsageLevel",      SPSHoseItem.spsGetUsageLevel)
end

-- [SPS 1.0.1.8] DIRT + WEAR over time (William 2026-10-23: "the pipes need to build dirt over time, wear over time").
-- The spsHose type carries the vanilla washable + wearable specs (listed BEFORE spsHoseItem in modDesc so these
-- overrides find the functions). Vanilla gives 0 dirt / 0 wear while standing (Washable:getDirtMultiplier and
-- Wearable:getWearMultiplier return 0 below 1 km/h) - a plugged-in pipe pumping slurry never moves, so the pipe's
-- USE drives them too: in service (an end plugged or joined) = DIRT/WEAR_IN_SERVICE, liquid passing (the valve of a
-- coupling an end is plugged into is open) = the washable workMultiplier (XML, default 4) / WEAR_FLOWING. Moving
-- (carried, on a rack of a moving tanker) keeps the vanilla rule incl. field and wet ground; the higher value wins.
-- Rain, the pressure washer and the dirt-interval game setting work as on any vehicle. No DAMAGE: a pipe has no
-- breakdown and no repair bill. Rates per pipe XML: <washable dirtDuration workMultiplier/>, <wearable wearDuration/>.
SPSHoseItem.DIRT_IN_SERVICE = 0.5
SPSHoseItem.WEAR_IN_SERVICE = 0.5
SPSHoseItem.WEAR_FLOWING    = 2

function SPSHoseItem.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getDirtMultiplier",    SPSHoseItem.getDirtMultiplier)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getWearMultiplier",    SPSHoseItem.getWearMultiplier)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getUsageCausesDamage", SPSHoseItem.getUsageCausesDamage)
end

-- 0 = idle, 1 = in service (an end plugged into a coupling or joined to another pipe), 2 = liquid passing (the valve
-- of a coupling an end is plugged into is open: lane fitting ballValveOpen / slurry coupler valveOpen - on a
-- HYDRAULIC coupler that flag mirrors the vehicle's cab valve, which is what we want here)
function SPSHoseItem:spsGetUsageLevel()
    local spec = self[SPSHoseItem.SPEC_NAME]
    if spec == nil or spec.ends == nil then return 0 end
    local level = 0
    for _, e in ipairs(spec.ends) do
        local c = e.coupling
        if c ~= nil then
            if (c.isLiquidLane and c.ballValveOpen) or (not c.isLiquidLane and c.valveOpen) then
                return 2
            end
            level = 1
        elseif e.joinedTo ~= nil then
            level = 1
        end
    end
    return level
end

function SPSHoseItem:getDirtMultiplier(superFunc)
    local m = superFunc(self)
    local use = self:spsGetUsageLevel()
    if use == 2 then
        m = math.max(m, self:getWorkDirtMultiplier())
    elseif use == 1 then
        m = math.max(m, SPSHoseItem.DIRT_IN_SERVICE)
    end
    local spec = self[SPSHoseItem.SPEC_NAME]
    return m * ((spec ~= nil and spec.dirtScale) or 1)   -- water / milk: half rate (variant #dirtScale)
end

function SPSHoseItem:getWearMultiplier(superFunc, nodeData)
    local m = superFunc(self, nodeData)
    local use = self:spsGetUsageLevel()
    if use == 2 then
        m = math.max(m, SPSHoseItem.WEAR_FLOWING)
    elseif use == 1 then
        m = math.max(m, SPSHoseItem.WEAR_IN_SERVICE)
    end
    return m
end

function SPSHoseItem:getUsageCausesDamage(superFunc)
    return false
end

function SPSHoseItem.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPreLoad",  SPSHoseItem)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad",     SPSHoseItem)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", SPSHoseItem)
    SpecializationUtil.registerEventListener(vehicleType, "onLoadFinished", SPSHoseItem)   -- [SPS 1.0.1.9] wake-up reports (bodies are in physics by then)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate",   SPSHoseItem)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete",   SPSHoseItem)
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Collision while HELD (William 2026-10-18). The bodies keep the flags their i3d gives them (the
-- stock vehicle flags: group VEHICLE + CAMERA_BLOCKING, mask 0xfe3ffb83): hoses lie on concrete, knock against each
-- other, vehicles and the player, and never cut through anything. The ONE change: while a player holds the pipe
-- the static bits STATIC_OBJECT + TREE + BUILDING are dropped on every body, so a capsule that has worked its way
-- into a kerb or slab can always be pulled out (before: it wedged, the hand joint strained and the hands let go).
-- On the drop each body gets its own i3d mask back and the pipe lies ON the concrete. Plugged ends keep their plug
-- masks (spsSetPlugCollision) throughout: the saved base is swapped and a live neighbour mask rebuilt from it.
SPSHoseItem.HELD_IGNORES_STATIC = true
-- [SPS 1.0.1.8] Pipe-only collision bit (William 2026-10-18: the stow rack's cradle, in the VEHICLE group, "is causing
-- the tanker to fly all over" - a kinematic shape overlapping the tanker's own compound). Every pipe body gets bit 7
-- (0x80, registered by nothing in the game; every vehicle mask already contains it) ADDED to its group. A cradle
-- flagged group 0x80 / mask 0x80 then collides with pipes only: not the tanker, not the player, not other vehicles.
SPSHoseItem.PIPE_GROUP_BIT = 0x80

function SPSHoseItem:spsApplyCollision(ignoreStatic)
    local spec = self[SPSHoseItem.SPEC_NAME]
    spec.i3dMasks = spec.i3dMasks or {}
    local staticBits = CollisionFlag.STATIC_OBJECT + CollisionFlag.TREE + CollisionFlag.BUILDING
    local saved = spec.savedMasks
    for ci, comp in ipairs(self.components) do
        if comp ~= nil and valid(comp.node) then
            if spec.i3dMasks[ci] == nil then
                spec.i3dMasks[ci] = getCollisionFilterMask(comp.node)
                -- once, at load: the pipe-only group bit on top of the i3d group (see PIPE_GROUP_BIT)
                setCollisionFilterGroup(comp.node, bit32.bor(getCollisionFilterGroup(comp.node), SPSHoseItem.PIPE_GROUP_BIT))
            end
            local mask = spec.i3dMasks[ci]
            if ignoreStatic then mask = bit32.band(mask, bit32.bnot(staticBits)) end
            if ignoreStatic and spec.carryIgnoresVehicle then
                -- [SPS 1.0.1.8] taken off a rack and carried: the bodies went dynamic where the pose left them, partly
                -- inside the tanker's own hull (mudguard box) - with the VEHICLE bit on PhysX shoved them out through
                -- the wheel arch (William 2026-10-19). Ignore vehicles until the drop.
                mask = bit32.band(mask, bit32.bnot(CollisionFlag.VEHICLE))
            end
            if spec.stow ~= nil then
                -- stowed: EVERY body AND its grab cubes ignore vehicles - it rides ON one (the bodies are kinematic
                -- on the slot's points, nothing needs to stop them). The i3d masks come back on unstow.
                setBodyMask(comp.node, bit32.band(mask, bit32.bnot(CollisionFlag.VEHICLE)), true)
            elseif saved ~= nil and saved[ci] ~= nil then
                saved[ci] = mask
                if getCollisionFilterMask(comp.node) ~= 0 then
                    setBodyMask(comp.node, bit32.band(mask, bit32.bnot(CollisionFlag.VEHICLE)))
                end
            else
                setBodyMask(comp.node, mask, true)   -- rest / held: the cubes get their i3d mask back too
            end
        end
    end
end

-- [SPS 1.0.1.8] The shop's Type / Length / Ends choice -> the component configuration (the bodies). Runs before the
-- i3d and the components are loaded (Vehicle:load raises onPreLoad, then loadFinished builds self.components from
-- self.configurations.component). Shop preview, bought pipes and savegames all go through here.
function SPSHoseItem:onPreLoad(savegame)
    local cfg = self.configurations
    if cfg == nil or cfg.spsPipeType == nil then return end
    local comp = SPSHoseItem.componentForShopChoice(cfg.spsPipeType, cfg.spsPipeLength, cfg.spsPipeEnds)
    if comp ~= nil and comp ~= cfg.component then
        cfg.component = comp
        if self.boughtConfigurations ~= nil then
            self.boughtConfigurations.component = { [comp] = true }
        end
    end
end

function SPSHoseItem:onLoad(savegame)
    local spec = self[SPSHoseItem.SPEC_NAME]
    local xml  = self.xmlFile
    -- Single-pipe file: attributes on <spsHose>. Multi-pipe file (slurryPipe.xml): the <variant> whose
    -- #config equals the chosen component configuration wins (the loader built self.components from it).
    local key = "vehicle.spsHose"
    local cfg = (self.configurations ~= nil and self.configurations["component"]) or 1
    local vi = 0
    while true do
        local vKey = string.format("vehicle.spsHose.variant(%d)", vi)
        if not xml:hasProperty(vKey) then break end
        if xml:getValue(vKey .. "#config", vi + 1) == cfg then key = vKey; break end
        vi = vi + 1
    end
    spec.variantKey = key
    spec.hoseKey   = string.upper(xml:getValue(key .. "#hoseKey", xml:getValue("vehicle.spsHose#hoseKey", "FM")))
    spec.meshNode  = xml:getValue(key .. "#meshNode",  nil, self.components, self.i3dMappings)
    spec.startNode = xml:getValue(key .. "#startNode", nil, self.components, self.i3dMappings)
    spec.endNode   = xml:getValue(key .. "#endNode",   nil, self.components, self.i3dMappings)
    spec.tintable  = xml:getValue(key .. "#tintable", xml:getValue("vehicle.spsHose#tintable", true))
    spec.dirtScale = xml:getValue(key .. "#dirtScale", 1)
    spec.hoseMaterialIndex = xml:getValue(key .. "#hoseMaterialIndex", xml:getValue("vehicle.spsHose#hoseMaterialIndex"))
    spec.isPreview = (self.propertyState == VehiclePropertyState.SHOP_CONFIG)
    spec.isHeld    = false
    spec.heldNode  = nil
    spec.hands     = nil
    if spec.meshNode == nil then
        Logging.xmlWarning(xml, "spsHose#meshNode missing - the pipe cannot be coloured")
    end
    if spec.startNode == nil or spec.endNode == nil then
        Logging.xmlWarning(xml, "spsHose#startNode / #endNode missing - the pipe cannot be connected")
    end

    -- The two ends. sign: hose START leaves the coupling (its +Z points AWAY from the coupling
    -- node's +Z, which points INTO the coupling), hose END arrives along the coupling's +Z.
    spec.ends = {
        { idx = 1, comp = xml:getValue("vehicle.spsHose#startComponent", 1),  node = spec.startNode,
          gender = string.lower(xml:getValue(key .. "#startGender", xml:getValue("vehicle.spsHose#startGender", "female"))), sign = -1 },
        { idx = 2, comp = xml:getValue(key .. "#endComponent", xml:getValue("vehicle.spsHose#endComponent", 13)), node = spec.endNode,
          gender = string.lower(xml:getValue(key .. "#endGender", xml:getValue("vehicle.spsHose#endGender", "male"))),     sign =  1 },
    }
    for _, e in ipairs(spec.ends) do
        e.coupling, e.object, e.isPlaceable, e.couplingId, e.kinematic = nil, nil, false, nil, false
        e.joinedTo, e.jointId = nil, nil   -- pipe-to-pipe: { pipe = otherPipe, idx = otherEnd }, physics joint id (server)
    end
    self:spsApplyCollision(false)   -- records each body's i3d mask; changes nothing
    spec.restLength = nil
    spec.stow = nil          -- { holder, vehicle, holderId, zSign, comp } while stowed on a pipe holder

    spec.color = nil
    local colorId = self.configurations ~= nil and self.configurations["designColor"] or nil
    if colorId ~= nil and ConfigurationUtil ~= nil and ConfigurationUtil.getColorByConfigId ~= nil then
        local c = ConfigurationUtil.getColorByConfigId(self, "designColor", colorId)
        if type(c) == "table" and c[1] ~= nil then spec.color = { c[1], c[2], c[3] } end
    end
    -- [SPS 1.0.1.8] water / milk share one set of bodies in spsPipe.i3d: their rubber colour comes from the variant
    if not spec.tintable then
        local rc = xml:getValue(key .. "#rubberColor", nil, true)
        if type(rc) == "table" and rc[1] ~= nil then
            spec.color, spec.tintable = { rc[1], rc[2], rc[3] }, true
        end
    end
    -- Saved end state (plugged / joined) -> restored by the manager once the owners exist (onPostLoad).
    spec.pendingRestore = nil
    if savegame ~= nil and savegame.xmlFile ~= nil and not savegame.resetVehicles then
        local sgKey = savegame.key .. "." .. SPSHoseItem.MOD_NAME .. ".spsHoseItem"
        for i = 0, 1 do
            local eKey = string.format("%s.end(%d)", sgKey, i)
            if savegame.xmlFile:hasProperty(eKey) then
                local r = {
                    owner       = savegame.xmlFile:getValue(eKey .. "#owner"),
                    couplingId  = savegame.xmlFile:getValue(eKey .. "#coupling"),
                    isPlaceable = savegame.xmlFile:getValue(eKey .. "#placeable", false),
                    isLane      = savegame.xmlFile:getValue(eKey .. "#lane", false),
                    isSprayer   = savegame.xmlFile:getValue(eKey .. "#sprayer", false),
                    valveOpen   = savegame.xmlFile:getValue(eKey .. "#valveOpen", false),
                    joinPipe    = savegame.xmlFile:getValue(eKey .. "#joinPipe"),
                    joinEnd     = savegame.xmlFile:getValue(eKey .. "#joinEnd"),
                }
                if r.owner ~= nil or r.joinPipe ~= nil then
                    spec.pendingRestore = spec.pendingRestore or {}
                    spec.pendingRestore[i + 1] = r
                end
            end
        end
        local stKey = sgKey .. ".stow"
        if savegame.xmlFile:hasProperty(stKey) then
            local v = savegame.xmlFile:getValue(stKey .. "#vehicle")
            local h = savegame.xmlFile:getValue(stKey .. "#holder")
            local sl = savegame.xmlFile:getValue(stKey .. "#slot")
            if v ~= nil and h ~= nil then
                spec.pendingRestore = spec.pendingRestore or {}
                spec.pendingRestore.stow = { owner = v, holderId = h, slotName = sl }
            end
        end
    end
end

function SPSHoseItem:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[SPSHoseItem.SPEC_NAME]
    if spec == nil or spec.ends == nil then return end
    for _, e in ipairs(spec.ends) do
        local eKey = string.format("%s.end(%d)", key, e.idx - 1)
        local owner = e.coupling ~= nil and e.object or nil
        local ownerId = owner ~= nil and owner.getUniqueId ~= nil and owner:getUniqueId() or nil
        if ownerId ~= nil and e.couplingId ~= nil then
            xmlFile:setValue(eKey .. "#owner",     ownerId)
            xmlFile:setValue(eKey .. "#coupling",  e.couplingId)
            xmlFile:setValue(eKey .. "#placeable", e.isPlaceable == true)
            xmlFile:setValue(eKey .. "#lane",      e.coupling.isLiquidLane == true)
            xmlFile:setValue(eKey .. "#sprayer",   e.coupling.isSprayerCoupling == true)
            -- [SPS 1.0.1.8] valve state of the coupling this end is plugged into (William: valves must survive a reload)
            -- a HYDRAULIC coupler's valve is its vehicle's cab valve (saved with the vehicle) - its flag is only a mirror
            local vOpen = (e.coupling.isLiquidLane and e.coupling.ballValveOpen)
                or (not e.coupling.isLiquidLane and e.coupling.valveType ~= SPS_VALVE_TYPE_HYDRAULIC and e.coupling.valveOpen)
            if vOpen == true then xmlFile:setValue(eKey .. "#valveOpen", true) end
        end
        local other = e.joinedTo ~= nil and e.joinedTo.pipe or nil
        local otherId = other ~= nil and other.getUniqueId ~= nil and other:getUniqueId() or nil
        if otherId ~= nil and e.joinedTo.idx ~= nil then
            xmlFile:setValue(eKey .. "#joinPipe", otherId)
            xmlFile:setValue(eKey .. "#joinEnd",  e.joinedTo.idx)
        end
    end
    if spec.stow ~= nil and spec.stow.vehicle ~= nil and spec.stow.vehicle.getUniqueId ~= nil then
        local vid = spec.stow.vehicle:getUniqueId()
        if vid ~= nil then
            xmlFile:setValue(key .. ".stow#vehicle", vid)
            xmlFile:setValue(key .. ".stow#holder",  spec.stow.holderId or 1)
            if spec.stow.slotName ~= nil then xmlFile:setValue(key .. ".stow#slot", spec.stow.slotName) end
        end
    end
end

-- Rest translations of the top-level nodes of the pipe i3d (the bodies lie straight along +Z, no rotation),
-- read from the file itself so a bent pipe from a savegame still gives the straight offsets.
function SPSHoseItem.loadRestTranslations(i3dPath)
    if i3dPath == nil then return nil end
    local cached = SPSHoseItem._i3dRest[i3dPath]
    if cached ~= nil then return cached end
    local map = {}
    local xml = XMLFile.load("spsHoseI3dRest", i3dPath)
    if xml ~= nil then
        for _, tag in ipairs({ "Shape", "TransformGroup" }) do
            local i = 0
            while true do
                local key = string.format("i3D.Scene.%s(%d)", tag, i)
                if not xml:hasProperty(key) then break end
                local name = xml:getString(key .. "#name")
                local t = xml:getString(key .. "#translation") or "0 0 0"
                local x, y, z = t:match("([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)")
                if name ~= nil then map[name] = { tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0 } end
                i = i + 1
            end
        end
        xml:delete()
    end
    SPSHoseItem._i3dRest[i3dPath] = map
    return map
end

-- Per end: the neighbour bodies held rigid with it + their rest offset in the end body's frame.
function SPSHoseItem:spsBuildRigidRuns()
    local spec = self[SPSHoseItem.SPEC_NAME]
    local i3dPath = self.i3dFilename
    if i3dPath == nil and self.xmlFile ~= nil then
        i3dPath = Utils.getFilename(self.xmlFile:getValue("vehicle.base.filename"), self.baseDirectory)
    end
    local rest = SPSHoseItem.loadRestTranslations(i3dPath) or {}
    local n = SPSHoseItem.PLUG_RIGID_NEIGHBOURS   -- [SPS 1.0.1.9] no longer capped by NO_VEHICLE_NEIGHBOURS (pair collision covers it)
    for _, e in ipairs(spec.ends) do
        e.rigid = {}
        local endComp = self.components[e.comp]
        local endRest = endComp ~= nil and valid(endComp.node) and rest[getName(endComp.node)] or nil
        local dir = (e.idx == 1) and 1 or -1
        for k = 1, n do
            local ci = e.comp + k * dir
            local comp = self.components[ci]
            local nbRest = comp ~= nil and valid(comp.node) and rest[getName(comp.node)] or nil
            if endRest ~= nil and nbRest ~= nil then
                table.insert(e.rigid, { comp = ci, dx = nbRest[1] - endRest[1], dy = nbRest[2] - endRest[2], dz = nbRest[3] - endRest[3] })
            end
        end
    end
end

function SPSHoseItem:onPostLoad(savegame)
    local spec = self[SPSHoseItem.SPEC_NAME]
    self:spsApplyColor()
    if valid(spec.startNode) and valid(spec.endNode) then
        spec.restLength = calcDistanceFrom(spec.startNode, spec.endNode)
    end
    self:spsBuildRigidRuns()
    -- [SPS 1.0.1.8] SHOP PREVIEW = a static pipe (William 2026-10-24: the shop pipes "move around a lot and sometimes
    -- bend into the floor"). Every body KINEMATIC from the start: the pipe stays exactly as the i3d lays it out
    -- (straight), no joint swing, no sinking into the workshop floor.
    if spec.isPreview then
        for _, comp in ipairs(self.components) do
            if valid(comp.node) then
                setRigidBodyType(comp.node, RigidBodyType.KINEMATIC)
            end
        end
    end
    if not spec.isPreview then
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager.physPipes = g_slurryPipeManager.physPipes or {}
            g_slurryPipeManager.physPipes[self] = true
        end
        say("%s pipe loaded: %d components, mass %.0f kg, rest length %.2f m, ends %s/%s, colour %s (%s)",
            tostring(spec.hoseKey), #self.components, self:getTotalMass() * 1000, spec.restLength or 0,
            spec.ends[1].gender, spec.ends[2].gender,
            spec.color and string.format("%.2f %.2f %.2f", spec.color[1], spec.color[2], spec.color[3]) or "none",
            tostring(spec.colorSlotInfo or "not tinted"))
        if spec.pendingRestore ~= nil and self.isServer and g_slurryPipeManager ~= nil and g_slurryPipeManager.physQueueRestore ~= nil then
            g_slurryPipeManager:physQueueRestore(self, spec.pendingRestore)
        end
        spec.pendingRestore = nil
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.9] MP: keep the server telling the clients where the pipe is. The game keeps a vehicle active - and only
-- an active vehicle sends its component positions (Vehicle:updateTick -> raiseDirtyFlags) - while its ROOT body is
-- awake (Vehicle:update :1604), and re-activates a sleeping vehicle through a wake-up report on that root body alone
-- (Vehicle:addToPhysics :1736). A pipe is 13-19 jointed bodies, and on an F/F or M/M pipe the root (the i3d's first
-- body, FM_col01) is not even a physics body: once the root slept, the server stopped updating the clients while the
-- rest of the pipe was still falling - "dropped pipes hang in mid-air until picked up again" (server tester 2026-10-25,
-- screenshot 18:49). Server only: a wake-up report on EVERY real body (kept in step with isAddedToPhysics, so a vehicle
-- reset re-registers them) and onUpdate keeps the vehicle active while ANY body is awake. Plain functions.
-- ---------------------------------------------------------------------------
function SPSHoseItem.syncWakeReports(pipe, forceOff)
    local spec = pipe[SPSHoseItem.SPEC_NAME]
    if spec == nil or not pipe.isServer or addWakeUpReport == nil or removeWakeUpReport == nil then return end
    local want = (pipe.isAddedToPhysics == true) and not forceOff
    if spec._wakeReportsOn == want then return end
    local n = 0
    for _, comp in ipairs(pipe.components or {}) do
        if comp ~= nil and valid(comp.node) and comp.node ~= pipe.rootNode then   -- the root carries the game's own report
            if want then
                if getRigidBodyType(comp.node) ~= RigidBodyType.NONE then
                    addWakeUpReport(comp.node, "onVehicleWakeUpCallback", pipe)
                    n = n + 1
                end
            else
                removeWakeUpReport(comp.node)
            end
        end
    end
    spec._wakeReportsOn = want
    if want then say("%s pipe: wake-up reports on %d bodies", tostring(spec.hoseKey), n) end
end

function SPSHoseItem.anyBodyAwake(pipe)
    for _, comp in ipairs(pipe.components or {}) do
        if comp ~= nil and valid(comp.node) and getRigidBodyType(comp.node) == RigidBodyType.DYNAMIC
           and not getIsSleeping(comp.node) then
            return true
        end
    end
    return false
end

function SPSHoseItem:onLoadFinished(savegame)
    SPSHoseItem.syncWakeReports(self)
    self:spsUpdateBoundingSphere(true)
end

-- [SPS 1.0.1.9] RENDER CULLING (William 2026-10-26, screenshots 20:04: a water hose plugged into the Hardi Aeon
-- vanished on a small camera turn). The skinned pipe mesh is a child of the FIRST body and the engine culls it by
-- its BIND-POSE bounding sphere: the straight rest pipe, ~2 m along that body's +Z. Once the pipe is bent, dragged
-- or laid away from that axis the real pipe is somewhere else, and when the rest-pose sphere leaves the view the
-- whole mesh goes. Same defect and same cure as the drawn hoses' T5 fix (SPSHoseVisual :812, vanilla idiom
-- ForestryPhysicsRope.lua:251 / ForestryRope.lua:90): re-centre the sphere on the bodies, in the mesh's local
-- space, whenever they have moved. Runs on every peer (each draws its own copy): every update while the pipe is
-- active, at load, and at every plug / unplug / rack placement so a pipe that never wakes on a client is right too.
SPSHoseItem.BV_MARGIN = 0.6    -- metres on top of the half-diagonal: body radius, skin sag between bodies, slack
SPSHoseItem.BV_EPS    = 0.25   -- re-issue the sphere once centre or radius moved this much

function SPSHoseItem:spsUpdateBoundingSphere(force)
    local spec = self[SPSHoseItem.SPEC_NAME]
    if spec == nil or not valid(spec.meshNode) or setShapeBoundingSphere == nil then return end
    local minX, minY, minZ, maxX, maxY, maxZ = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
    local n = 0
    for _, comp in ipairs(self.components or {}) do
        if comp ~= nil and valid(comp.node) then
            local x, y, z = getWorldTranslation(comp.node)
            if x < minX then minX = x end
            if y < minY then minY = y end
            if z < minZ then minZ = z end
            if x > maxX then maxX = x end
            if y > maxY then maxY = y end
            if z > maxZ then maxZ = z end
            n = n + 1
        end
    end
    if n == 0 then return end
    local wx, wy, wz = (minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5
    local dx, dy, dz = maxX - minX, maxY - minY, maxZ - minZ
    local radius = 0.5 * math.sqrt(dx * dx + dy * dy + dz * dz) + SPSHoseItem.BV_MARGIN
    local lx, ly, lz = worldToLocal(spec.meshNode, wx, wy, wz)
    local bv = spec._bv
    local eps = SPSHoseItem.BV_EPS
    if force or bv == nil or math.abs(bv[1] - lx) > eps or math.abs(bv[2] - ly) > eps or math.abs(bv[3] - lz) > eps
       or math.abs(bv[4] - radius) > eps then
        setShapeBoundingSphere(spec.meshNode, lx, ly, lz, radius)
        spec._bv = { lx, ly, lz, radius }
    end
end

function SPSHoseItem:onDelete()
    local spec = self[SPSHoseItem.SPEC_NAME]
    if spec == nil then return end
    SPSHoseItem.syncWakeReports(self, true)
    local mgr = g_slurryPipeManager
    if spec.ends ~= nil then
        for _, e in ipairs(spec.ends) do
            if e.coupling ~= nil or e.joinedTo ~= nil then
                if mgr ~= nil and mgr.applyPhysPipeDisconnect ~= nil then
                    mgr:applyPhysPipeDisconnect(self, e.idx)   -- breaks the flow connection, frees the coupling / the other pipe
                end
                if e.coupling ~= nil and e.coupling.physPipe == self then
                    e.coupling.physPipe, e.coupling.physPipeEnd = nil, nil
                end
                if e.joinedTo ~= nil then self:spsUnjoinEnd(e.idx) end
                e.coupling = nil
            end
        end
    end
    if spec.stow ~= nil then self:spsUnstow() end
    if mgr ~= nil and mgr.physPipes ~= nil then mgr.physPipes[self] = nil end
    if mgr ~= nil and mgr.physCancelRestore ~= nil then mgr:physCancelRestore(self) end
end

-- Colour -> the hose_mat slot of the mesh (same call the automatic hoses use, SPSHoseVisual:applyColor).
function SPSHoseItem:spsApplyColor()
    local spec = self[SPSHoseItem.SPEC_NAME]
    if not spec.tintable or spec.color == nil or not valid(spec.meshNode) then return end
    local shape = spec.meshNode
    local n = getNumOfMaterials(shape)
    local idx, slots = nil, {}
    for i = 0, n - 1 do
        local sn = getMaterialSlotName(shape, i)
        slots[#slots + 1] = tostring(sn)
        if idx == nil and sn == "hose_mat" then idx = i end
    end
    local how = "slot name"
    -- [SPS 1.0.1.8] no slot named hose_mat: the XML's hoseMaterialIndex (the tool / hand-set index of the rubber);
    -- only without that does the colour go to every material (which tints the metal fittings too)
    if idx == nil and spec.hoseMaterialIndex ~= nil and spec.hoseMaterialIndex < n then
        idx, how = spec.hoseMaterialIndex, "xml index"
    end
    local r, g, b = spec.color[1], spec.color[2], spec.color[3]
    if idx ~= nil then
        setShaderParameter(shape, "colorScale", r, g, b, nil, false, idx)
    else
        setShaderParameter(shape, "colorScale", r, g, b, nil, false)
        how = "ALL materials (no hose_mat slot, no hoseMaterialIndex)"
    end
    spec.colorSlotInfo = string.format("%s -> material %s of %d [%s]", how, tostring(idx), n, table.concat(slots, ","))
end

function SPSHoseItem:spsGetHoseKey()
    local spec = self[SPSHoseItem.SPEC_NAME]
    return spec ~= nil and spec.hoseKey or nil
end

-- 1-based component index of a node, or nil when the node is not one of our bodies.
-- Component index of a node of this pipe. [SPS 1.0.1.8] A child of a body counts too (the grab cubes startGrab /
-- endGrab and the new collision capsules are compoundChild shapes under the bodies): walk up to the body.
function SPSHoseItem:spsGetComponentIndex(node)
    local guard = 0
    -- [SPS 1.0.1.9] entityExists: the hands of a remote player on a dedicated server can keep a deleted node
    -- (HandToolHands only clears a dead heldItemNode for the owning player, ref :204) - getParent on it is a script error
    while node ~= nil and node ~= 0 and entityExists(node) and guard < 8 do
        for i, component in ipairs(self.components) do
            if component.node == node then return i end
        end
        node = getParent(node)
        guard = guard + 1
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Ends
-- ---------------------------------------------------------------------------
function SPSHoseItem:spsGetEnd(idx)
    local spec = self[SPSHoseItem.SPEC_NAME]
    return spec ~= nil and spec.ends ~= nil and spec.ends[idx] or nil
end

-- Plug end idx into a coupling (coupling table + its owner object). Server: body -> KINEMATIC, placed.
function SPSHoseItem:spsAttachEnd(idx, coupling, object, isPlaceable)
    local spec = self[SPSHoseItem.SPEC_NAME]
    local e = spec.ends[idx]
    if e == nil or coupling == nil then return false end
    e.coupling, e.object, e.isPlaceable, e.couplingId = coupling, object, isPlaceable == true, coupling.id
    coupling.physPipe, coupling.physPipeEnd = self, idx
    -- slurry couplers: the connector animation (clamp handles) closes on the pipe, as on a hose connect.
    -- 80 mm lane fittings: NOTHING moves on plug - their handle is the fitting VALVE (R at the fitting).
    if SPSCouplerAnimator ~= nil and coupling.connectorAnim ~= nil and not coupling.isLiquidLane then
        SPSCouplerAnimator.play(coupling.connectorAnim, 1)
    end
    if self.isServer then
        local comp = self.components[e.comp]
        if comp ~= nil and valid(comp.node) then
            self:spsSetEndCollision(e, true)
            setRigidBodyType(comp.node, RigidBodyType.KINEMATIC)
            e.kinematic = true
            -- the rigid run: the neighbour bodies ride with the end body (see PLUG_RIGID_NEIGHBOURS)
            for _, r in ipairs(e.rigid or {}) do
                local nb = self.components[r.comp]
                if nb ~= nil and valid(nb.node) then setRigidBodyType(nb.node, RigidBodyType.KINEMATIC) end
            end
        end
        self:spsPlaceEnd(e)
    end
    -- [SPS 1.0.1.9] body types first, then the pairing - the game's order (MountableObject:mountKinematic :153-161)
    self:spsSetVehiclePairCollision(object, isPlaceable, false)
    self:spsUpdateBoundingSphere(true)
    self:raiseActive()
    return true
end

-- A plugged-in end is KINEMATIC, i.e. immovable. If its capsule - or a dynamic body squeezed between
-- it and the tanker - overlaps the vehicle's collision, PhysX resolves the overlap by shoving the
-- VEHICLE: the tanker spun in circles the moment the pipe was connected (William, test 2026-10-15).
-- So while an end is plugged in its body collides with nothing. [SPS 1.0.1.9] The neighbour rule
-- (NO_VEHICLE_NEIGHBOURS bodies losing the VEHICLE bit) is retired - a fixed count could never fit every
-- coupler aim (Kotte TSA: sideways across the rear, 3rd body inside the hull); the whole pipe is now
-- paired off against the plugged vehicle instead (spsSetVehiclePairCollision). Masks restored on unplug.
-- Server only (physics).
function SPSHoseItem:spsSetEndCollision(e, plugged)
    if not self.isServer then return end
    local spec = self[SPSHoseItem.SPEC_NAME]
    spec.savedMasks = spec.savedMasks or {}
    local dir = (e.idx == 1) and 1 or -1
    for k = 0, SPSHoseItem.NO_VEHICLE_NEIGHBOURS do
        local ci = e.comp + k * dir
        local comp = self.components[ci]
        if comp ~= nil and valid(comp.node) then
            if plugged then
                if spec.savedMasks[ci] == nil then
                    spec.savedMasks[ci] = getCollisionFilterMask(comp.node)
                end
                local mask = 0
                if k > 0 then
                    mask = bit32.band(spec.savedMasks[ci], bit32.bnot(CollisionFlag.VEHICLE))
                end
                setBodyMask(comp.node, mask)
            elseif spec.savedMasks[ci] ~= nil then
                setBodyMask(comp.node, spec.savedMasks[ci])
                spec.savedMasks[ci] = nil
            end
        end
    end
end

-- [SPS 1.0.1.9] While plugged into a VEHICLE (tanker, sprayer, docking station) every body of this pipe ignores that
-- vehicle's components and nothing else - setPairCollision, the game's idiom for a bale on a loader / a mounted object
-- (MountableObject:mountKinematic / unmountKinematic, BaleLoader:setBalePairCollision). William 2026-10-25: "ignore a
-- col from the connected veh but still have cols for everything else". Counted per vehicle so a pipe with both ends on
-- the same vehicle pairs back on only when the last end comes off. Placeables are static: nothing to pair (skipped).
-- Runs on server and clients like the game's own calls (both have the shapes).
function SPSHoseItem:spsSetVehiclePairCollision(vehicle, isPlaceable, enabled)
    if isPlaceable or vehicle == nil or vehicle.components == nil or setPairCollision == nil then return end
    local spec = self[SPSHoseItem.SPEC_NAME]
    spec.pairedVehicles = spec.pairedVehicles or {}
    local count = spec.pairedVehicles[vehicle] or 0
    if not enabled then
        count = count + 1
        spec.pairedVehicles[vehicle] = count
        if count > 1 then return end          -- the other end is already plugged into this vehicle: paired off already
    else
        count = count - 1
        if count > 0 then spec.pairedVehicles[vehicle] = count; return end
        spec.pairedVehicles[vehicle] = nil
        if count < 0 then return end          -- never paired off (nothing to restore)
    end
    local n = 0
    for _, comp in ipairs(self.components) do
        if comp ~= nil and valid(comp.node) then
            for _, vc in ipairs(vehicle.components) do
                if vc ~= nil and valid(vc.node) then
                    setPairCollision(comp.node, vc.node, enabled)
                    n = n + 1
                end
            end
        end
    end
    say("%s pipe %s collision with %s (%d body pairs)", tostring(spec.hoseKey), enabled and "RESTORED" or "IGNORES",
        tostring(vehicle.configFileName), n)
end

-- Unplug end idx. Server: body -> DYNAMIC again (falls / hangs from the joints).
function SPSHoseItem:spsDetachEnd(idx)
    local spec = self[SPSHoseItem.SPEC_NAME]
    local e = spec ~= nil and spec.ends[idx] or nil
    if e == nil then return false end
    local coupling = e.coupling
    if coupling ~= nil and coupling.physPipe == self then
        coupling.physPipe, coupling.physPipeEnd = nil, nil
        if coupling.isLiquidLane then
            -- the fitting valve closes with the pipe off (state + handle), so the next plug starts closed
            coupling.ballValveOpen = false
            local anim = coupling.valveAnim or coupling.connectorAnim
            if SPSCouplerAnimator ~= nil and anim ~= nil then SPSCouplerAnimator.play(anim, -1) end
        elseif SPSCouplerAnimator ~= nil and coupling.connectorAnim ~= nil then
            SPSCouplerAnimator.play(coupling.connectorAnim, -1)
        end
    end
    local pairedObject, pairedIsPlaceable = e.object, e.isPlaceable
    e.coupling, e.object, e.isPlaceable, e.couplingId = nil, nil, false, nil
    if self.isServer and e.kinematic then
        local comp = self.components[e.comp]
        if comp ~= nil and valid(comp.node) then
            setRigidBodyType(comp.node, RigidBodyType.DYNAMIC)
            setLinearVelocity(comp.node, 0, 0, 0)
            setAngularVelocity(comp.node, 0, 0, 0)
        end
        for _, r in ipairs(e.rigid or {}) do
            local nb = self.components[r.comp]
            if nb ~= nil and valid(nb.node) then
                setRigidBodyType(nb.node, RigidBodyType.DYNAMIC)
                setLinearVelocity(nb.node, 0, 0, 0)
                setAngularVelocity(nb.node, 0, 0, 0)
            end
        end
        self:spsSetEndCollision(e, false)
    end
    e.kinematic = false
    -- [SPS 1.0.1.9] collide with that vehicle again (unless the other end is still plugged into it - counted)
    self:spsSetVehiclePairCollision(pairedObject, pairedIsPlaceable, true)
    self:spsUpdateBoundingSphere(true)
    self:raiseActive()
    return true
end

-- Put the end's body so that the end node sits ON the coupling node, pointing the right way.
-- Coupling node +Z points INTO the coupling (inNode convention; store couplings use mountNode the
-- same way). The end node has no rotation of its own inside its body, so body +Z = end node +Z.
function SPSHoseItem:spsPlaceEnd(e)
    local c = e.coupling
    if c == nil then return end
    self:spsPlaceEndAt(e, c.inNode or c.mountNode, e.sign)
    -- rigid run: neighbours straight behind the end body at their rest offsets (same orientation)
    local endComp = self.components[e.comp]
    if endComp == nil or not valid(endComp.node) or e.rigid == nil then return end
    local dx, dy, dz = localDirectionToWorld(endComp.node, 0, 0, 1)
    local ux, uy, uz = localDirectionToWorld(endComp.node, 0, 1, 0)
    for _, r in ipairs(e.rigid) do
        local nb = self.components[r.comp]
        if nb ~= nil and valid(nb.node) then
            setDirection(nb.node, dx, dy, dz, ux, uy, uz)
            local wx, wy, wz = localToWorld(endComp.node, r.dx, r.dy, r.dz)
            setWorldTranslation(nb.node, wx, wy, wz)
        end
    end
end

-- Put the end's body so that the end node sits ON targetNode with the end node's +Z = zSign x target +Z.
function SPSHoseItem:spsPlaceEndAt(e, target, zSign)
    if not valid(target) then return end
    local comp = self.components[e.comp]
    if comp == nil or not valid(comp.node) or not valid(e.node) then return end
    local dx, dy, dz = localDirectionToWorld(target, 0, 0, zSign)
    local ux, uy, uz = localDirectionToWorld(target, 0, 1, 0)
    setDirection(comp.node, dx, dy, dz, ux, uy, uz)
    local tx, ty, tz = getWorldTranslation(target)
    local nx, ny, nz = getWorldTranslation(e.node)
    local cx, cy, cz = getWorldTranslation(comp.node)
    setWorldTranslation(comp.node, cx + (tx - nx), cy + (ty - ny), cz + (tz - nz))
end

function SPSHoseItem:spsIsEndBusy(idx)
    local e = self:spsGetEnd(idx)
    return e ~= nil and (e.coupling ~= nil or e.joinedTo ~= nil)
end

-- ---------------------------------------------------------------------------
-- STOW on a vehicle's pipe holder (William 2026-10-18/19). A holder (SPS_pipeHolderNN) carries SLOTS - groups a modder
-- captured in GIANTS Editor from a posed pipe (placementPipes/SPS_PipePlacement.lua): slurryNN / waterNN with p01..pNN
-- transforms = where each body sits, position AND rotation. Stowing lays the pipe on that point chain: every body is
-- kinematic and placed every frame by ARC LENGTH along the chain, centred, so body count and point count need not
-- match and every pipe of the family lands on the same posed curve. The posed droop IS the droop - no physics sag,
-- nothing on the rack has to match the pipe. VEHICLE collision is off on every body while stowed (it rides on one).
-- Only a FREE pipe (no end plugged or joined) can be stowed. Grabbing any body releases it. The pipe keeps the way
-- round it arrives in (zSign). Server places; every peer tracks the state. Per frame: M point reads + N placements.
-- ---------------------------------------------------------------------------
function SPSHoseItem:spsIsStowed()
    local spec = self[SPSHoseItem.SPEC_NAME]
    return spec ~= nil and spec.stow ~= nil
end

-- rest z of every body along the straight pipe (from the i3d), fallback 0.333 m spacing
function SPSHoseItem:spsRestZs()
    local i3dPath = self.i3dFilename
    if i3dPath == nil and self.xmlFile ~= nil then
        i3dPath = Utils.getFilename(self.xmlFile:getValue("vehicle.base.filename"), self.baseDirectory)
    end
    local rest = SPSHoseItem.loadRestTranslations(i3dPath) or {}
    local zs = {}
    for i, comp in ipairs(self.components) do
        local r = valid(comp.node) and rest[getName(comp.node) or ""] or nil
        zs[i] = r ~= nil and r[3] or ((i - 1) * 0.333)
    end
    return zs
end

-- world polyline of a slot's points: positions P[j], cumulative lengths S[j], total L (or nil)
local function chainOf(points)
    local P, S, L = {}, {}, 0
    for j, n in ipairs(points) do
        if not valid(n) then return nil end
        local x, y, z = getWorldTranslation(n)
        P[j] = { x, y, z }
        if j > 1 then
            local q = P[j - 1]
            L = L + math.sqrt((x - q[1]) ^ 2 + (y - q[2]) ^ 2 + (z - q[3]) ^ 2)
        end
        S[j] = L
    end
    if #P < 2 or L < 0.05 then return nil end
    return P, S, L
end

function SPSHoseItem:spsStow(holder, slot)
    local spec = self[SPSHoseItem.SPEC_NAME]
    if spec == nil or holder == nil or slot == nil or slot.points == nil or #slot.points < 2 then return false end
    if spec.stow ~= nil then return spec.stow.slot == slot end
    if self:spsIsEndBusy(1) or self:spsIsEndBusy(2) then return false end
    local P, S, L = chainOf(slot.points)
    if P == nil then return false end
    local zs = self:spsRestZs()
    local n = #zs
    -- which way round: the pipe keeps the direction it arrives in
    local mid = math.max(1, math.floor((n + 1) / 2))
    local comp = self.components[mid]
    if comp == nil or not valid(comp.node) then return false end
    local px, py, pz = localDirectionToWorld(comp.node, 0, 0, 1)
    local cx, cy, cz = P[#P][1] - P[1][1], P[#P][2] - P[1][2], P[#P][3] - P[1][3]
    local zSign = ((px * cx + py * cy + pz * cz) < 0) and -1 or 1
    spec.stow = { holder = holder, slot = slot, vehicle = holder.vehicle, holderId = holder.id, slotName = slot.name,
                  zSign = zSign, zs = zs, zMid = (zs[1] + zs[n]) * 0.5 }
    slot.pipe = self
    if self.isServer then
        self:spsApplyCollision(false)                -- stowed: every body ignores vehicles (see spsApplyCollision)
        for _, c in ipairs(self.components) do
            if valid(c.node) then
                setRigidBodyType(c.node, RigidBodyType.KINEMATIC)
                setLinearVelocity(c.node, 0, 0, 0)
                setAngularVelocity(c.node, 0, 0, 0)
            end
        end
        self:spsPlaceStow()
    end
    self:raiseActive()
    say("%s pipe stowed in slot '%s' of holder %d on %s (%d bodies on %d points, chain %.2f m, zSign %d)",
        tostring(spec.hoseKey), tostring(slot.name), holder.id or 0, tostring(holder.vehicle ~= nil and holder.vehicle.configFileName),
        n, #slot.points, L, zSign)
    return true
end

function SPSHoseItem:spsUnstow()
    local spec = self[SPSHoseItem.SPEC_NAME]
    if spec == nil or spec.stow == nil then return false end
    local st = spec.stow
    if st.slot ~= nil and st.slot.pipe == self then st.slot.pipe = nil end
    spec.stow = nil
    if self.isServer then
        for _, c in ipairs(self.components) do
            if valid(c.node) then
                setRigidBodyType(c.node, RigidBodyType.DYNAMIC)
                setLinearVelocity(c.node, 0, 0, 0)
                setAngularVelocity(c.node, 0, 0, 0)
            end
        end
        self:spsApplyCollision(spec.isHeld == true)  -- i3d masks back on every body (static bits off while held)
    end
    self:raiseActive()
    say("%s pipe taken off its holder", tostring(spec.hoseKey))
    return true
end

-- Server, every frame while stowed: every body on the slot's point chain by arc length, centred on the chain, the
-- tangent of its segment as direction and the nearest point's Y as up (the pose's roll).
function SPSHoseItem:spsPlaceStow()
    local spec = self[SPSHoseItem.SPEC_NAME]
    local st = spec ~= nil and spec.stow or nil
    if st == nil or st.slot == nil then return end
    local P, S, L = chainOf(st.slot.points)
    if P == nil then return end
    local pts = st.slot.points
    local zSign = st.zSign or 1
    local j = 1
    for i, comp in ipairs(self.components) do
        if valid(comp.node) then
            local s = L * 0.5 + zSign * ((st.zs[i] or 0) - st.zMid)
            if s < 0 then s = 0 elseif s > L then s = L end
            -- segment j with S[j] <= s <= S[j+1] (bodies come in increasing s when zSign = 1, decreasing otherwise)
            j = 1
            while j < #P - 1 and S[j + 1] < s do j = j + 1 end
            local seg = S[j + 1] - S[j]
            local t = seg > 1e-6 and (s - S[j]) / seg or 0
            local a, b = P[j], P[j + 1]
            local x, y, z = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
            local dx, dy, dz = (b[1] - a[1]) * zSign, (b[2] - a[2]) * zSign, (b[3] - a[3]) * zSign
            local near = pts[(t < 0.5) and j or (j + 1)]
            local ux, uy, uz = localDirectionToWorld(near, 0, 1, 0)
            local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dl > 1e-6 then
                setDirection(comp.node, dx / dl, dy / dl, dz / dl, ux, uy, uz)
            end
            setWorldTranslation(comp.node, x, y, z)
        end
    end
    self:spsUpdateBoundingSphere(true)   -- [SPS 1.0.1.9] render culling: bodies just moved onto the rack
end

-- PIPE-TO-PIPE: join end idx to otherPipe's end otherIdx. The MOVER (the pipe in the player's hands)
-- snaps its end onto the other end, then (server) a locked physics joint ties the two end bodies, so
-- the two pipes behave as one chain. Each end's OUTWARD direction is -Z for a start and +Z for an end;
-- at a junction outward(B) = -outward(A), i.e. B's node +Z = (B is a start ? +1 : -1) x outward(A).
function SPSHoseItem:spsJoinEnd(idx, otherPipe, otherIdx, isMover)
    local e = self:spsGetEnd(idx)
    local oe = otherPipe ~= nil and otherPipe.spsGetEnd ~= nil and otherPipe:spsGetEnd(otherIdx) or nil
    if e == nil or oe == nil then return false end
    e.joinedTo = { pipe = otherPipe, idx = otherIdx }
    if self.isServer and isMover and valid(oe.node) then
        local outwardA = (oe.idx == 1) and -1 or 1          -- other end's outward along its node Z
        local zSign = ((e.idx == 1) and 1 or -1) * outwardA
        self:spsPlaceEndAt(e, oe.node, zSign)
        local comp, ocomp = self.components[e.comp], otherPipe.components[oe.comp]
        if comp ~= nil and ocomp ~= nil and valid(comp.node) and valid(ocomp.node) then
            setLinearVelocity(comp.node, 0, 0, 0); setAngularVelocity(comp.node, 0, 0, 0)
            local joint = JointConstructor.new()
            joint:setActors(comp.node, ocomp.node)
            local x, y, z = getWorldTranslation(e.node)
            joint:setJointWorldPositions(x, y, z, x, y, z)
            for axis = 0, 2 do
                joint:setTranslationLimit(axis, true, 0, 0)
                joint:setRotationLimit(axis, 0, 0)
            end
            local ax, ay, az = localDirectionToWorld(e.node, 1, 0, 0)
            joint:setJointWorldAxes(ax, ay, az, ax, ay, az)
            local nx, ny, nz = localDirectionToWorld(e.node, 0, 1, 0)
            joint:setJointWorldNormals(nx, ny, nz, nx, ny, nz)
            joint:setEnableCollision(false)
            local id = joint:finalize()
            e.jointId, oe.jointId = id, id
        end
    end
    self:raiseActive()
    return true
end

-- Undo spsJoinEnd on BOTH sides (the joint is one object shared by the pair).
function SPSHoseItem:spsUnjoinEnd(idx)
    local e = self:spsGetEnd(idx)
    if e == nil or e.joinedTo == nil then return false end
    local otherPipe, otherIdx = e.joinedTo.pipe, e.joinedTo.idx
    if self.isServer and e.jointId ~= nil then
        removeJoint(e.jointId)
    end
    e.joinedTo, e.jointId = nil, nil
    local oe = otherPipe ~= nil and otherPipe.spsGetEnd ~= nil and otherPipe:spsGetEnd(otherIdx) or nil
    if oe ~= nil and oe.joinedTo ~= nil and oe.joinedTo.pipe == self then
        oe.joinedTo, oe.jointId = nil, nil
        if otherPipe.raiseActive ~= nil then otherPipe:raiseActive() end
    end
    self:raiseActive()
    return true
end

-- Server, every frame while an end is plugged in: follow the couplings; drop ends whose coupling
-- vanished; unplug the vehicle end when the pipe is overstretched.
function SPSHoseItem:spsUpdateEnds()
    local spec = self[SPSHoseItem.SPEC_NAME]
    if not self.isServer or spec.ends == nil then return false end
    local any = false
    if spec.stow ~= nil then
        local st = spec.stow
        if st.slot == nil or st.slot.pipe ~= self or st.holder == nil or not valid(st.holder.node) then
            self:spsUnstow()                                   -- holder gone (vehicle sold / deleted)
        else
            self:spsPlaceStow()
            any = true
        end
    end
    for _, e in ipairs(spec.ends) do
        if e.coupling ~= nil then
            local c = e.coupling
            if c.physPipe ~= self or not valid(c.inNode or c.mountNode) then
                -- coupling freed elsewhere (owner sold / deleted) -> let go
                self:spsDetachEnd(e.idx)
            else
                self:spsPlaceEnd(e)
                any = true
            end
        end
    end
    -- Overstretch: both ends plugged in and pulled apart beyond the rest length -> unplug the
    -- vehicle end (both vehicles: the END end), like the original auto-disconnect.
    local a, b = spec.ends[1], spec.ends[2]
    if any and a.coupling ~= nil and b.coupling ~= nil and spec.restLength ~= nil
       and valid(a.node) and valid(b.node) then
        local d = calcDistanceFrom(a.node, b.node)
        if d > spec.restLength * SPSHoseItem.STRETCH_MARGIN then
            local victim = b
            if b.isPlaceable and not a.isPlaceable then victim = a end
            say("%s pipe overstretched (%.2f m > %.2f m) - unplugging end %d", tostring(spec.hoseKey),
                d, spec.restLength * SPSHoseItem.STRETCH_MARGIN, victim.idx)
            if g_slurryPipeManager ~= nil and g_slurryPipeManager.physPipeDisconnect ~= nil then
                g_slurryPipeManager:physPipeDisconnect(self, victim.idx, true)   -- forced: a ripped-off pipe ignores the valve gate
            else
                self:spsDetachEnd(victim.idx)
            end
        end
    end
    return any
end

-- ---------------------------------------------------------------------------
-- Hands
-- ---------------------------------------------------------------------------
-- Player capsule vs every body of the pipe. The vanilla hands only toggle the ONE held node
-- (HandToolHands.lua:555-560, 598-605); a 4 m pipe hanging from the hand would otherwise shove
-- the player about with its other twelve capsules.
function SPSHoseItem:spsSetPlayerCollision(hands, enabled)
    local player = hands ~= nil and hands.getCarryingPlayer ~= nil and hands:getCarryingPlayer() or nil
    local cct = player ~= nil and player.capsuleController ~= nil and player.capsuleController.capsuleId or nil
    if cct == nil then return end
    for _, component in ipairs(self.components) do
        if valid(component.node) then
            setCCTPairCollision(cct, component.node, enabled)
        end
    end
end

-- Called from the HandToolHands.pickUpTarget hook once the hands hold this pipe's root.
-- hitNode = the component the player's ray hit.
function SPSHoseItem:spsOnGrabbed(hands, hitNode)
    local spec = self[SPSHoseItem.SPEC_NAME]
    local hs = hands.spec_hands
    local ci = self:spsGetComponentIndex(hitNode)
    if hs == nil or ci == nil then return end
    if spec.stow ~= nil then                 -- off the rack the moment a body is grabbed (server applies, event syncs)
        spec.carryIgnoresVehicle = true      -- and carried clear of the tanker without fighting its hull (see spsApplyCollision)
        if g_slurryPipeManager ~= nil and g_slurryPipeManager.physPipeUnstow ~= nil then
            g_slurryPipeManager:physPipeUnstow(self)
        else
            self:spsUnstow()
        end
    end
    hitNode = self.components[ci].node   -- a grab cube / capsule child resolves to its BODY (the joint needs a rigid body)
    if hitNode ~= self.rootNode then
        -- The joint, the drop, the throw and the break report all read hs.heldItemNode:
        -- point them at the grabbed body instead of col01.
        hs.heldItemNode = hitNode
        if not hands.isServer and hands.orientRotationNodeToItem ~= nil then
            hands:orientRotationNodeToItem(hitNode)
        end
    end
    self:spsSetPlayerCollision(hands, false)
    if SPSHoseItem.HELD_IGNORES_STATIC then self:spsApplyCollision(true) end   -- can always be pulled out of concrete
    spec.isHeld   = true
    spec.heldNode = hitNode
    spec.hands    = hands
    self:raiseActive()
    say("grabbed %s pipe at component %d of %d", tostring(spec.hoseKey), ci, #self.components)
end

function SPSHoseItem:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self[SPSHoseItem.SPEC_NAME]
    -- [SPS 1.0.1.9] stay active (= keep sending positions to the clients) while ANY body still moves, not only the root
    if self.isServer then
        SPSHoseItem.syncWakeReports(self)
        if SPSHoseItem.anyBodyAwake(self) then self:raiseActive() end
    end
    -- [SPS 1.0.1.9] render bounding sphere follows the bodies (see spsUpdateBoundingSphere) - every peer, every frame
    self:spsUpdateBoundingSphere(false)
    -- plugged-in ends ride their couplings (server); a pipe in service (joined only, middle of a chain) stays
    -- active too, so the washable / wearable ticks run and it builds dirt + wear like the plugged ones
    if self:spsUpdateEnds() or (self.isServer and self:spsGetUsageLevel() > 0) then
        self:raiseActive()
        -- a docking station this pipe is plugged into sleeps once frozen: keep it awake for its dirt / wear ticks
        for _, e in ipairs(spec.ends or {}) do
            if e.coupling ~= nil and e.object ~= nil and e.object.spsDsGetUsageLevel ~= nil then
                e.object:raiseActive()
            end
        end
    end
    if not spec.isHeld then return end
    local hands = spec.hands
    local held = hands ~= nil and hands.getHeldItem ~= nil and hands:getHeldItem() or nil
    if held ~= nil and held == spec.heldNode then
        self:raiseActive()
        return
    end
    -- dropped / thrown / joint broke
    spec.isHeld = false
    spec.carryIgnoresVehicle = nil
    self:spsSetPlayerCollision(hands, true)
    if SPSHoseItem.HELD_IGNORES_STATIC then self:spsApplyCollision(false) end  -- full collisions back: lies ON the concrete
    spec.heldNode = nil
    spec.hands    = nil
    say("dropped %s pipe", tostring(spec.hoseKey))
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] FREE A STUCK PIPE (William 2026-10-24: a pipe caught in a tanker wheel "wont come out"). His design:
-- grab the pipe, press "Free stuck pipe" (SPS_FREE_PIPE, SPSHoseItemHands) and, while it is still held, the pipe
-- ignores vehicles so it can be pulled out of the wheel / fender; let go and every collision comes back (the drop
-- path in onUpdate clears carryIgnoresVehicle and re-applies the i3d masks - the same path a rack pickup uses).
-- Server only (physics); a client sends SPSPhysPipeFreeEvent. Plain function, not a vehicle method.
-- ---------------------------------------------------------------------------
function SPSHoseItem.spsFreeHeldPipe(pipe)
    local spec = pipe ~= nil and pipe[SPSHoseItem.SPEC_NAME] or nil
    if spec == nil or not pipe.isServer or not spec.isHeld or spec.carryIgnoresVehicle then return false end
    spec.carryIgnoresVehicle = true
    pipe:spsApplyCollision(true)
    say("%s pipe freed: ignores vehicles until it is let go", tostring(spec.hoseKey))
    return true
end

-- ---------------------------------------------------------------------------
-- Hook: the vanilla hands grabbed something. pickUpTarget(self=hands, target, noEventSend) returns
-- false and holds nothing NEW when the target is not pickable, so only act when it returned true and
-- the hands now hold this pipe's root; then hand over the node that was actually hit.
-- [SPS 1.0.1.9] overwritten (was appended): an appended hook also ran after a FAILED pick-up, when heldItemNode is
-- still the previous item - on a dedicated server that can be a deleted node (Nitrado log 2026-10-24 21:36,
-- "Unknown entity id ... getParent" from spsGetComponentIndex via HandsPickUpObjectEvent). Return value passed on.
-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.9] Grab hint store (SPSPhysPipeGrabEvent): which pipe body the remote player's hand hit. Plain function.
function SPSHoseItem.spsSetGrabHint(hands, pipe, componentIndex)
    local hs = hands ~= nil and hands.spec_hands or nil
    if hs == nil then return end
    hs._spsGrabHint = { pipe = pipe, ci = componentIndex, time = g_time or 0 }
end

if HandToolHands ~= nil and HandToolHands.pickUpTarget ~= nil and not SPSHoseItem._hooked then
    SPSHoseItem._hooked = true
    HandToolHands.pickUpTarget = Utils.overwrittenFunction(HandToolHands.pickUpTarget, function(hands, superFunc, target, noEventSend)
        -- [SPS 1.0.1.9] The vanilla pick-up event carries only the OBJECT; the server rebuilds the target as
        -- object.rootNode = the i3d's first body (female end of an F/M pipe; an inactive non-physics node on F/F and
        -- M/M). A joined client therefore sends the body it hit ahead of the vanilla event, and the receiving side
        -- (server, then the other clients) swaps the vanilla target to that body here, before the vanilla checks run.
        if target ~= nil and target.node ~= nil and g_currentMission ~= nil then
            local hs = hands.spec_hands
            local hint = hs ~= nil and hs._spsGrabHint or nil
            if hs ~= nil then hs._spsGrabHint = nil end   -- one hint per pick-up attempt
            local aimed = g_currentMission:getNodeObject(target.node)
            if g_server == nil and aimed ~= nil and aimed.spsGetComponentIndex ~= nil and SPSPhysPipeGrabEvent ~= nil then
                local ci = aimed:spsGetComponentIndex(target.node)
                if ci ~= nil then
                    SPSPhysPipeGrabEvent.sendEvent(hands, aimed, ci)
                    -- proven on the tester's server 2026-10-25 20:12 - Info channel from here on (spsDebug Info on)
                    spsInfo(string.format("[SPS PHYS] grab hint SENT to server: pipe %s body %d (aimed node %s)",
                        tostring(aimed.configFileName), ci, tostring(getName(target.node))))
                end
            elseif hint ~= nil then
                local usable = hint.pipe ~= nil and not hint.pipe.isDeleted and hint.pipe.components ~= nil
                               and ((g_time or 0) - (hint.time or 0)) < 3000
                local matches = usable and (aimed == hint.pipe or hint.pipe.rootNode == target.node)
                local comp = matches and hint.pipe.components[hint.ci] or nil
                if comp ~= nil and valid(comp.node) then
                    spsInfo(string.format("[SPS PHYS] grab hint APPLIED: vanilla target %s -> pipe body %d (%s)",
                        tostring(getName(target.node)), hint.ci, tostring(getName(comp.node))))
                    target = { node = comp.node, x = target.x, y = target.y, z = target.z, distance = target.distance }
                else
                    -- a hint that does not fit is worth a normal log line: it means the ordering assumption broke
                    print(string.format("[SPS PHYS] grab hint NOT applied: usable=%s matches=%s body %s (vanilla target %s, aimed object %s)",
                        tostring(usable), tostring(matches), tostring(hint.ci), tostring(getName(target.node)),
                        tostring(aimed ~= nil and aimed.configFileName or aimed)))
                end
            end
        end
        local picked = superFunc(hands, target, noEventSend)
        if target ~= nil and target.node ~= nil and g_currentMission ~= nil then
            local o = g_currentMission:getNodeObject(target.node)
            if o ~= nil and o.spsGetComponentIndex ~= nil then
                local hs = hands.spec_hands
                -- (hands hold = the vanilla choice at this point; spsOnGrabbed below re-points it to the aimed body)
                spsInfo(string.format("[SPS PHYS] pick-up %s: pipe %s, target body %s, hands hold %s (server=%s)",
                    picked and "OK" or "REFUSED", tostring(o.configFileName), tostring(o:spsGetComponentIndex(target.node)),
                    tostring(hs ~= nil and hs.heldItemNode ~= nil and getName(hs.heldItemNode) or "nothing"), tostring(hands.isServer)))
            end
        end
        if not picked or target == nil or target.node == nil or g_currentMission == nil then return picked end
        local object = g_currentMission:getNodeObject(target.node)
        if object == nil or object.spsOnGrabbed == nil then return picked end
        local hs = hands.spec_hands
        -- the hands hold the root OR the body that was hit: a multi-variant pipe file (slurryPipe.i3d: FM / FF / MM bodies
        -- selected by the shop's component configuration) keeps the FILE's first body (FM_col01) as rootNode, which is not
        -- part of an F/F or M/M pipe - comparing with rootNode only dropped every F/F / M/M grab (William 2026-10-23:
        -- stowed F/F + M/M would not come off, and were carried without the SPS hold handling)
        if hs == nil or hs.heldItemNode == nil then return picked end
        if hs.heldItemNode ~= object.rootNode
           and (object.spsGetComponentIndex == nil or object:spsGetComponentIndex(hs.heldItemNode) == nil) then return picked end
        object:spsOnGrabbed(hands, target.node)
        return picked
    end)
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] PRESSURE WASHER on pipes / docking stations (William 2026-10-24: "if the pipes get dirty it should be
-- able to be washed"). The lance raycasts the VEHICLE group and then only accepts a shape whose collision MASK still
-- has the VEHICLE bit (HandToolHPWLance:onLanceCallback, CollisionFlag.getHasMaskFlagSet). Our pipes clear that bit
-- on purpose: a plugged-in end body (spsSetEndCollision, mask 0) and EVERY body of a stowed pipe / a
-- station on its frame (they ride inside a tanker). Those hits are accepted here for SPS pipes and stations only;
-- every other vehicle goes through the vanilla test unchanged.
-- ---------------------------------------------------------------------------
if HandToolHPWLance ~= nil and HandToolHPWLance.onLanceCallback ~= nil and not SPSHoseItem._washHooked then
    SPSHoseItem._washHooked = true
    HandToolHPWLance.onLanceCallback = Utils.overwrittenFunction(HandToolHPWLance.onLanceCallback,
        function(lance, superFunc, nodeId, x, y, z, distance, nx, ny, nz, subShapeIndex, shapeId, isLast)
            if nodeId ~= nil and nodeId ~= 0 and shapeId ~= nil and shapeId ~= 0
               and not CollisionFlag.getHasMaskFlagSet(shapeId, CollisionFlag.VEHICLE)
               and g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil then
                local v = g_currentMission.vehicleSystem:getVehicleByNodeId(nodeId, shapeId)
                if v ~= nil and (v.spsGetHoseKey ~= nil or v.spsDsIsStowed ~= nil)
                   and v.getAllowsWashingByType ~= nil and v:getAllowsWashingByType(Washable.WASHTYPE_HIGH_PRESSURE_WASHER) then
                    local spec = lance.spec_highPressureWasherLance
                    if spec ~= nil then
                        spec.targetedVehicleId = NetworkUtil.getObjectId(v)
                        return false
                    end
                end
            end
            return superFunc(lance, nodeId, x, y, z, distance, nx, ny, nz, subShapeIndex, shapeId, isLast)
        end)
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] SHOP PAGE of the one pipe item (William 2026-10-24): "Ends" and the colour only mean something for a
-- slurry pipe - hide both when Pipe = water / milk. ShopConfigScreen builds the option list once
-- (updateConfigOptionsData) and a click only reloads the preview (updateData), so: the Ends option is skipped and
-- the designColor row removed for a non-slurry choice, and a click on "Pipe" rebuilds the list on the next frame.
-- Only vehicles/hoses/spsPipe.xml is touched.
-- ---------------------------------------------------------------------------
local function isSpsPipeItem(storeItem)
    return storeItem ~= nil and storeItem.xmlFilename ~= nil
        and string.find(storeItem.xmlFilename, "vehicles/hoses/spsPipe.xml", 1, true) ~= nil
end
local function shopIsSlurry(screen)
    return screen.configurations == nil or (screen.configurations.spsPipeType or 1) == 1
end

if ShopConfigScreen ~= nil and not SPSHoseItem._shopHooked then
    SPSHoseItem._shopHooked = true
    ShopConfigScreen.updateConfigOptionElement = Utils.overwrittenFunction(ShopConfigScreen.updateConfigOptionElement,
        function(screen, superFunc, configElementIndex, option, storeItem, vehicle, saleItem)
            local mine = isSpsPipeItem(storeItem) and option ~= nil
            if mine and option.name == "spsPipeEnds" and not shopIsSlurry(screen) then
                return   -- water / milk: no Ends row
            end
            local r = superFunc(screen, configElementIndex, option, storeItem, vehicle, saleItem)
            if mine and option.name == "spsPipeType" and screen.configurationToListElement ~= nil then
                local le = screen.configurationToListElement.spsPipeType
                local oe = le ~= nil and le:getDescendantByName("option") or nil
                if oe ~= nil and oe.onClickCallback ~= nil then
                    local cb = oe.onClickCallback   -- freshly set by superFunc every build
                    oe.onClickCallback = function(...)
                        cb(...)
                        screen.spsPipeRebuild = true
                    end
                end
            end
            return r
        end)
    ShopConfigScreen.updateConfigOptionsData = Utils.overwrittenFunction(ShopConfigScreen.updateConfigOptionsData,
        function(screen, superFunc, storeItem, vehicle, saleItem)
            local count = superFunc(screen, storeItem, vehicle, saleItem)
            if isSpsPipeItem(storeItem) and not shopIsSlurry(screen) then
                for i, opt in ipairs(screen.colorPickers or {}) do
                    if opt.configName == "designColor" and screen.colorElements ~= nil then
                        -- the colour row: walk up from the colour button to the row in the list, then put it away the
                        -- way updateConfigOptionsData clears its rows (invisible, out of focus, unlinked, back to cache)
                        local el = screen.colorElements[i]
                        while el ~= nil and el.parent ~= nil and el.parent ~= screen.configurationLayout do
                            el = el.parent
                        end
                        if el ~= nil and el.parent == screen.configurationLayout then
                            el:setVisible(false)
                            FocusManager:removeElement(el)
                            el:unlinkElement()
                            table.insert(screen.configItemCache, el)
                            screen.colorElements[i] = nil
                            count = count - 1
                        end
                    end
                end
            end
            return count
        end)
    ShopConfigScreen.update = Utils.appendedFunction(ShopConfigScreen.update, function(screen, dt)
        if screen.spsPipeRebuild then
            screen.spsPipeRebuild = nil
            if screen.storeItem ~= nil and screen.updateConfigOptionsDisplay ~= nil then
                screen:updateConfigOptionsDisplay(screen.storeItem, screen.vehicle, screen.saleItem)
            end
        end
    end)
    -- [SPS 1.0.1.8] Centre the pipe preview on the workshop point the shop camera orbits (ShopConfigScreen: the camera
    -- target is the fixed workshop position, it never follows the vehicle). The per-length <shopOffset> did not move
    -- the preview in game (William 2026-10-24 14:36: 4 m and 6 m near end in the same spot), so the midpoint is placed
    -- absolutely here: works for every length / type, and stays right even if the config offset is applied after all.
    -- Preview bodies are KINEMATIC (onPostLoad), so a direct move sticks.
    ShopConfigScreen.onVehiclesLoaded = Utils.appendedFunction(ShopConfigScreen.onVehiclesLoaded, function(screen)
        if not isSpsPipeItem(screen.storeItem) or screen.workshopWorldPosition == nil then return end
        for _, v in pairs(screen.previewVehicles or {}) do
            local spec = v[SPSHoseItem.SPEC_NAME]
            if spec ~= nil and valid(spec.startNode) and valid(spec.endNode) then
                -- midpoint of the two real pipe ends
                local ax, _, az = getWorldTranslation(spec.startNode)
                local bx, _, bz = getWorldTranslation(spec.endNode)
                local mx, mz = (ax + bx) * 0.5, (az + bz) * 0.5
                local dx = screen.workshopWorldPosition[1] - mx
                local dz = screen.workshopWorldPosition[3] - mz
                -- height: William's 'groundLevel' node under each variant's mesh marks the bottom of its end fitting
                -- (slurry -0.09, water / milk -0.052): sit it on the workshop floor (was one storeData Y for every
                -- type, so the thinner water / milk pipes floated)
                local dy = 0
                local ground = valid(spec.meshNode) and getChild(spec.meshNode, "groundLevel") or 0
                if valid(ground) then
                    local _, gy, _ = getWorldTranslation(ground)
                    dy = screen.workshopWorldPosition[2] - gy
                end
                for _, comp in ipairs(v.components or {}) do
                    if valid(comp.node) then
                        local x, y, z = getWorldTranslation(comp.node)
                        setWorldTranslation(comp.node, x + dx, y + dy, z + dz)
                    end
                end
            end
        end
    end)
end
