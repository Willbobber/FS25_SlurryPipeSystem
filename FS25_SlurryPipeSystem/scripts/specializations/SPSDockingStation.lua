-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSDockingStation.lua
-- [SPS 1.0.1.8] The SPS Docking Station (vehicles/dockingStation): a carriable post with one pipe coupling and one
-- rubber boot port (SPS registers those from the vehicle XML's own <slurryPipeSystem> block - nothing here).
--
-- This specialization only manages the BODY. The station is a 30 kg dynamic body so the hands can carry it, but
-- once SET DOWN it must behave like the old static chain docking station: a tanker's fill arm pushed into the boot
-- must not shove or tip it (William 2026-10-18: "the col is causing the arm to stop it being emptied"). So on the
-- server the body goes KINEMATIC (immovable) once it has come to rest, and DYNAMIC again the moment the hands pick
-- it up (prepended hook on HandToolHands.pickUpTarget, before the vanilla hand joint is created).
--
-- CARRIED ON A TANKER (William 2026-10-19): a vehicle can carry the station on a frame. Its fillPoints.xml names the
-- frame's position node (<dockingStationHolders><dockingStationHolder id nodeName radius/>, see SlurryPipeManager
-- registerVehicle) - the node where the station's ROOT goes (its base on the frame, same axes as the station i3d).
-- Holding the station with its base within radius of that node offers "Place docking station" on the right mouse
-- (SPSHoseItemHands); the station then rides the frame: the one body KINEMATIC, placed on the node every frame by
-- the server, VEHICLE collision off (it sits inside the tanker's hull box - with the bit on PhysX would shove the
-- tanker), coupling and boot port out of service (SPSM_PhysPipes / SPSM_Flow skip a stowed station). Aiming at it
-- offers the plain pick-up (hook 1 below lets a kinematic body through); the grab takes it off the frame, carried
-- with VEHICLE collision off until the drop so it comes clear of the hull. Saved as .stow#vehicle #holder, restored
-- by the manager once the carrying vehicle has registered (SPSM_PhysPipes dsQueueRestore).

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSDockingStation 1.0.1.8 loaded") end

SPSDockingStation = {}
SPSDockingStation.SPEC_NAME   = string.format("spec_%s.spsDockingStation", g_currentModName)
SPSDockingStation.MOD_NAME    = g_currentModName   -- file-scope copy: initSpecialization runs after sourcing (see SPSHoseItem)
SPSDockingStation.REST_SPEED  = 0.05   -- m/s: slower than this counts as at rest
SPSDockingStation.REST_TIME   = 500    -- ms at rest before the body is frozen

local function say(fmt, ...)
    spsInfo("[SPS DS] " .. string.format(fmt, ...))
end

local function valid(n) return n ~= nil and n ~= 0 and entityExists(n) end

-- The mask on every collision shape of the one body: the root and its compoundChild cols (under "cols"); the
-- skinned visual mesh is no collision shape and is skipped.
local function setBodyMask(node, mask)
    setCollisionFilterMask(node, mask)
    local function walk(n)
        for i = 0, getNumOfChildren(n) - 1 do
            local c = getChildAt(n, i)
            if getHasClassId(c, ClassIds.SHAPE) and not getShapeIsSkinned(c) then
                setCollisionFilterMask(c, mask)
            end
            walk(c)
        end
    end
    walk(node)
end

function SPSDockingStation.prerequisitesPresent(specializations)
    return true
end

function SPSDockingStation.initSpecialization()
    -- Savegame (key = vehicle key + "." + <modName>.spsDockingStation): the vehicle frame the station rides on.
    local sg = Vehicle.xmlSchemaSavegame
    if sg ~= nil then
        local sb = string.format("vehicles.vehicle(?).%s.spsDockingStation.stow", SPSDockingStation.MOD_NAME)
        sg:register(XMLValueType.STRING, sb .. "#vehicle", "Unique id of the vehicle whose docking station holder this station rides on")
        sg:register(XMLValueType.INT,    sb .. "#holder",  "Docking station holder id on that vehicle")
    end
end

function SPSDockingStation.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad",     SPSDockingStation)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", SPSDockingStation)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate",   SPSDockingStation)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete",   SPSDockingStation)
end

-- [SPS 1.0.1.8] DIRT + WEAR with use (William 2026-10-23), as the physical pipes (SPSHoseItem): the type carries the
-- vanilla washable + wearable specs (listed BEFORE spsDockingStation in modDesc). A set-down station never moves, and
-- vanilla gives 0 dirt / 0 wear below 1 km/h, so USE drives them: in service (a fill arm docked in the boot, or a
-- pipe plugged into the coupling) = IN_SERVICE; liquid passing (the docked tanker's pump running, or the coupling
-- valve open) = the washable workMultiplier (XML, default 4) / WEAR_FLOWING. Riding a tanker's frame / carried =
-- vanilla moving rule. No damage. A frozen station sleeps: the arm detection (SPSM_Flow detectArmConnection) and a
-- plugged pipe (SPSHoseItem:onUpdate) wake it while in use, so the washable / wearable ticks run.
SPSDockingStation.DIRT_IN_SERVICE = 0.5
SPSDockingStation.WEAR_IN_SERVICE = 0.5
SPSDockingStation.WEAR_FLOWING    = 2

function SPSDockingStation.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getDirtMultiplier",    SPSDockingStation.getDirtMultiplier)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getWearMultiplier",    SPSDockingStation.getWearMultiplier)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getUsageCausesDamage", SPSDockingStation.getUsageCausesDamage)
end

-- 0 idle / riding a frame, 1 in service, 2 liquid passing
function SPSDockingStation:spsDsGetUsageLevel()
    local spec = self[SPSDockingStation.SPEC_NAME]
    local mgr = g_slurryPipeManager
    if spec == nil or spec.stow ~= nil or mgr == nil or mgr.getVehicleEntry == nil then return 0 end
    local entry = mgr:getVehicleEntry(self)
    if entry == nil then return 0 end
    local level = 0
    for _, c in ipairs(entry.couplingEntries or {}) do
        if c.physPipe ~= nil or c.isConnected then
            if (c.isLiquidLane and c.ballValveOpen) or (not c.isLiquidLane and c.valveOpen) then return 2 end
            level = 1
        end
    end
    local ports = entry.rubberBootPortEntries
    if ports ~= nil and #ports > 0 then
        for _, ve in ipairs(mgr.registeredVehicles or {}) do
            for _, arm in ipairs(ve.armEntries or {}) do
                local bp = arm.connectedBootPort
                if bp ~= nil and bp.vehicle == self then
                    if ve.state ~= nil and ve.state.pumpRunning then return 2 end
                    level = 1
                end
            end
        end
    end
    return level
end

function SPSDockingStation:getDirtMultiplier(superFunc)
    local m = superFunc(self)
    local use = self:spsDsGetUsageLevel()
    if use == 2 then
        m = math.max(m, self:getWorkDirtMultiplier())
    elseif use == 1 then
        m = math.max(m, SPSDockingStation.DIRT_IN_SERVICE)
    end
    return m
end

function SPSDockingStation:getWearMultiplier(superFunc, nodeData)
    local m = superFunc(self, nodeData)
    local use = self:spsDsGetUsageLevel()
    if use == 2 then
        m = math.max(m, SPSDockingStation.WEAR_FLOWING)
    elseif use == 1 then
        m = math.max(m, SPSDockingStation.WEAR_IN_SERVICE)
    end
    return m
end

function SPSDockingStation:getUsageCausesDamage(superFunc)
    return false
end

function SPSDockingStation.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "spsDsSetFrozen",       SPSDockingStation.spsDsSetFrozen)
    SpecializationUtil.registerFunction(vehicleType, "spsDsOnGrabbed",       SPSDockingStation.spsDsOnGrabbed)
    SpecializationUtil.registerFunction(vehicleType, "spsDsIsStowed",        SPSDockingStation.spsDsIsStowed)
    SpecializationUtil.registerFunction(vehicleType, "spsDsStow",            SPSDockingStation.spsDsStow)
    SpecializationUtil.registerFunction(vehicleType, "spsDsUnstow",          SPSDockingStation.spsDsUnstow)
    SpecializationUtil.registerFunction(vehicleType, "spsDsPlaceStow",       SPSDockingStation.spsDsPlaceStow)
    SpecializationUtil.registerFunction(vehicleType, "spsDsApplyCollision",  SPSDockingStation.spsDsApplyCollision)
    SpecializationUtil.registerFunction(vehicleType, "spsDsGetUsageLevel",   SPSDockingStation.spsDsGetUsageLevel)
end

function SPSDockingStation:onLoad(savegame)
    local spec = {}
    self[SPSDockingStation.SPEC_NAME] = spec
    spec.frozen    = false
    spec.restTimer = 0
    spec.isHeld    = false
    spec.hands     = nil
    spec.stow      = nil   -- { holder, vehicle, holderId } while riding a vehicle frame
    spec.carryIgnoresVehicle = nil
    spec.pendingStow = nil
    if savegame ~= nil and savegame.xmlFile ~= nil and not savegame.resetVehicles then
        local stKey = savegame.key .. "." .. SPSDockingStation.MOD_NAME .. ".spsDockingStation.stow"
        if savegame.xmlFile:hasProperty(stKey) then
            local v = savegame.xmlFile:getValue(stKey .. "#vehicle")
            local h = savegame.xmlFile:getValue(stKey .. "#holder")
            if v ~= nil and h ~= nil then spec.pendingStow = { owner = v, holderId = h } end
        end
    end
    self:raiseActive()
end

function SPSDockingStation:onPostLoad(savegame)
    local spec = self[SPSDockingStation.SPEC_NAME]
    if spec == nil then return end
    -- [SPS 1.0.1.8] registry of the carriable stations on every peer (counts for the pipe-mode dialog, removal on
    -- the PHYSICAL -> ORIGINAL switch: in original mode the station is placed at a pipe end with R, never bought)
    if self.propertyState ~= VehiclePropertyState.SHOP_CONFIG and g_slurryPipeManager ~= nil then
        g_slurryPipeManager.physStations = g_slurryPipeManager.physStations or {}
        g_slurryPipeManager.physStations[self] = true
    end
    if spec.pendingStow ~= nil and self.isServer and self.propertyState ~= VehiclePropertyState.SHOP_CONFIG
       and g_slurryPipeManager ~= nil and g_slurryPipeManager.dsQueueRestore ~= nil then
        g_slurryPipeManager:dsQueueRestore(self, spec.pendingStow.owner, spec.pendingStow.holderId)
    end
    spec.pendingStow = nil
end

function SPSDockingStation:onDelete()
    local spec = self[SPSDockingStation.SPEC_NAME]
    if spec == nil then return end
    if spec.stow ~= nil then self:spsDsUnstow() end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.dsCancelRestore ~= nil then g_slurryPipeManager:dsCancelRestore(self) end
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.physStations ~= nil then g_slurryPipeManager.physStations[self] = nil end
end

function SPSDockingStation:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[SPSDockingStation.SPEC_NAME]
    if spec == nil or spec.stow == nil or spec.stow.vehicle == nil or spec.stow.vehicle.getUniqueId == nil then return end
    local vid = spec.stow.vehicle:getUniqueId()
    if vid ~= nil then
        xmlFile:setValue(key .. ".stow#vehicle", vid)
        xmlFile:setValue(key .. ".stow#holder",  spec.stow.holderId or 1)
    end
end

-- Server: freeze (KINEMATIC) or free (DYNAMIC) the one body.
function SPSDockingStation:spsDsSetFrozen(frozen)
    local spec = self[SPSDockingStation.SPEC_NAME]
    if spec == nil or not self.isServer or spec.frozen == frozen then return end
    local comp = self.components[1]
    if comp == nil or not valid(comp.node) then return end
    if frozen then
        setRigidBodyType(comp.node, RigidBodyType.KINEMATIC)
    else
        setRigidBodyType(comp.node, RigidBodyType.DYNAMIC)
        setLinearVelocity(comp.node, 0, 0, 0)
        setAngularVelocity(comp.node, 0, 0, 0)
    end
    spec.frozen    = frozen
    spec.restTimer = 0
    say("%s", frozen and "set down - body frozen (kinematic)" or "picked up - body free (dynamic)")
    self:raiseActive()
end

-- Collision mask of the body: the i3d mask, minus VEHICLE while it rides a frame or is carried off one.
function SPSDockingStation:spsDsApplyCollision()
    local spec = self[SPSDockingStation.SPEC_NAME]
    local comp = spec ~= nil and self.components[1] or nil
    if comp == nil or not valid(comp.node) then return end
    if spec.i3dMask == nil then spec.i3dMask = getCollisionFilterMask(comp.node) end
    local mask = spec.i3dMask
    if spec.stow ~= nil or spec.carryIgnoresVehicle then
        mask = bit32.band(mask, bit32.bnot(CollisionFlag.VEHICLE))
    end
    setBodyMask(comp.node, mask)
end

-- Called from the pickUpTarget hook BEFORE the hands make their joint: the body must be dynamic for that.
function SPSDockingStation:spsDsOnGrabbed(hands)
    local spec = self[SPSDockingStation.SPEC_NAME]
    if spec == nil then return end
    if spec.stow ~= nil then
        -- off the frame the moment it is grabbed; carried clear of the hull without the VEHICLE bit (see header)
        spec.carryIgnoresVehicle = true
        if g_slurryPipeManager ~= nil and g_slurryPipeManager.dsUnstow ~= nil then
            g_slurryPipeManager:dsUnstow(self)
        else
            self:spsDsUnstow()
        end
    end
    self:spsDsSetFrozen(false)
    if spec.carryIgnoresVehicle then self:spsDsApplyCollision() end
    spec.isHeld = true
    spec.hands  = hands
    self:raiseActive()
end

-- ---------------------------------------------------------------------------
-- Riding a vehicle frame
-- ---------------------------------------------------------------------------
function SPSDockingStation:spsDsIsStowed()
    local spec = self[SPSDockingStation.SPEC_NAME]
    return spec ~= nil and spec.stow ~= nil
end

-- holder = a dockingStationHolder entry of the manager ({ id, node, vehicle, radius, station })
function SPSDockingStation:spsDsStow(holder)
    local spec = self[SPSDockingStation.SPEC_NAME]
    if spec == nil or holder == nil or not valid(holder.node) then return false end
    if spec.stow ~= nil then return spec.stow.holder == holder end
    if holder.station ~= nil and holder.station ~= self then return false end
    local comp = self.components[1]
    if comp == nil or not valid(comp.node) then return false end
    spec.stow = { holder = holder, vehicle = holder.vehicle, holderId = holder.id }
    holder.station = self
    spec.carryIgnoresVehicle = nil
    if self.isServer then
        setRigidBodyType(comp.node, RigidBodyType.KINEMATIC)
        setLinearVelocity(comp.node, 0, 0, 0)
        setAngularVelocity(comp.node, 0, 0, 0)
        spec.frozen, spec.restTimer = true, 0
        self:spsDsApplyCollision()
        self:spsDsPlaceStow()
    end
    self:raiseActive()
    say("placed on docking station holder %d of %s", holder.id or 0, tostring(holder.vehicle ~= nil and holder.vehicle.configFileName))
    return true
end

-- Off the frame. Grabbed: the grab hook frees the body next. Holder vehicle gone: the body is freed here and drops.
function SPSDockingStation:spsDsUnstow()
    local spec = self[SPSDockingStation.SPEC_NAME]
    if spec == nil or spec.stow == nil then return false end
    local st = spec.stow
    if st.holder ~= nil and st.holder.station == self then st.holder.station = nil end
    spec.stow = nil
    if self.isServer then
        self:spsDsSetFrozen(false)
        self:spsDsApplyCollision()
    end
    self:raiseActive()
    say("taken off docking station holder %d of %s", st.holderId or 0, tostring(st.vehicle ~= nil and st.vehicle.configFileName))
    return true
end

-- Server, every frame while riding: the root on the holder node (position + axes).
function SPSDockingStation:spsDsPlaceStow()
    local spec = self[SPSDockingStation.SPEC_NAME]
    local st = spec ~= nil and spec.stow or nil
    local comp = self.components[1]
    if st == nil or st.holder == nil or not valid(st.holder.node) or comp == nil or not valid(comp.node) then return end
    local n = st.holder.node
    local x, y, z = getWorldTranslation(n)
    local dx, dy, dz = localDirectionToWorld(n, 0, 0, 1)
    local ux, uy, uz = localDirectionToWorld(n, 0, 1, 0)
    setDirection(comp.node, dx, dy, dz, ux, uy, uz)
    setWorldTranslation(comp.node, x, y, z)
end

function SPSDockingStation:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self[SPSDockingStation.SPEC_NAME]
    if spec == nil or not self.isServer then return end
    if spec.stow ~= nil then
        local st = spec.stow
        if st.holder == nil or st.holder.station ~= self or not valid(st.holder.node) then
            self:spsDsUnstow()                                   -- holder gone (vehicle sold / deleted): drops
        else
            self:spsDsPlaceStow()
            self:raiseActive()
            return
        end
    end
    if spec.isHeld then
        local hands = spec.hands
        local hs = hands ~= nil and hands.spec_hands or nil
        if hs ~= nil and hs.heldItemNode == self.rootNode then
            self:raiseActive()
            return
        end
        -- dropped / thrown
        spec.isHeld, spec.hands, spec.restTimer = false, nil, 0
        if spec.carryIgnoresVehicle then
            spec.carryIgnoresVehicle = nil
            self:spsDsApplyCollision()                           -- full i3d mask back: it can be bumped by a tractor again
        end
    end
    if spec.frozen then
        if self:spsDsGetUsageLevel() > 0 then self:raiseActive() end   -- in use: keep the dirt / wear ticks running
        return
    end
    local comp = self.components[1]
    if comp == nil or not valid(comp.node) then return end
    local vx, vy, vz = getLinearVelocity(comp.node)
    local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
    if speed < SPSDockingStation.REST_SPEED then
        spec.restTimer = spec.restTimer + dt
        if spec.restTimer >= SPSDockingStation.REST_TIME then
            self:spsDsSetFrozen(true)
            return
        end
    else
        spec.restTimer = 0
    end
    self:raiseActive()
end

-- Hook 1 (frozen station AND stowed pipe): the vanilla pick-up test (HandToolHands:getCanPickUpNode, ref :372) refuses any body that is not DYNAMIC
-- on the server, so a frozen (KINEMATIC) station never even shows the "pick up" prompt (William 2026-10-18: "placed on
-- the map and I can't grab it by hand"). For a station WE froze (set down OR riding a frame), run the rest of the
-- vanilla checks (holding, mass, mounts) without the body-type test; hook 2 below then frees the body before the hand
-- joint is made.
if HandToolHands ~= nil and HandToolHands.getCanPickUpNode ~= nil and not SPSDockingStation._hookedCanPickUp then
    SPSDockingStation._hookedCanPickUp = true
    HandToolHands.getCanPickUpNode = Utils.overwrittenFunction(HandToolHands.getCanPickUpNode, function(hands, superFunc, node)
        if hands.isServer and node ~= nil and node ~= 0 and entityExists(node) and getRigidBodyType(node) == RigidBodyType.KINEMATIC
           and g_currentMission ~= nil then
            local object = g_currentMission:getNodeObject(node)
            local spec = object ~= nil and object.spsDsOnGrabbed ~= nil and object[SPSDockingStation.SPEC_NAME] or nil
            -- [SPS 1.0.1.8] a STOWED physical pipe is all-kinematic on its rack (SPSHoseItem:spsStow) - same rule:
            -- grabbing it releases it (spsOnGrabbed -> physPipeUnstow), so the pick-up prompt must show
            local stowedPipe = object ~= nil and object.spsIsStowed ~= nil and object:spsIsStowed()
            if (spec ~= nil and (spec.frozen or spec.stow ~= nil)) or stowedPipe then
                if hands:getIsHoldingItem() then return false end
                local hs = hands.spec_hands
                local mass = HandToolHands.calculateItemMass ~= nil and HandToolHands.calculateItemMass(node) or nil
                if mass == nil or (hs ~= nil and hs.currentMaximumMass ~= nil and hs.currentMaximumMass < mass) then return false end
                if object.dynamicMountObject ~= nil or object.tensionMountObject ~= nil then return false end
                if object.getCanBePickedUp ~= nil and not object:getCanBePickedUp(hands.getCarryingPlayer ~= nil and hands:getCarryingPlayer() or nil) then return false end
                return true
            end
        end
        return superFunc(hands, node)
    end)
end

-- Hook 2: runs BEFORE HandToolHands.pickUpTarget. A frozen station must be dynamic for the hand joint to move it.
-- [SPS 1.0.1.9] overwritten (was prepended): Utils.prependedFunction drops the return value, and this hook is the OUTER
-- wrapper (spsDockingStation is registered after spsHoseItem in modDesc). HandsPickUpObjectEvent:run (ref :58) reads that
-- return on the server: nil = "failed" -> HandsPickUpFailedEvent -> the CLIENT let go while the SERVER kept holding, for
-- every pick-up by a joined player (any object). The server hands then sat on a node that was later deleted.
if HandToolHands ~= nil and HandToolHands.pickUpTarget ~= nil and not SPSDockingStation._hooked then
    SPSDockingStation._hooked = true
    HandToolHands.pickUpTarget = Utils.overwrittenFunction(HandToolHands.pickUpTarget, function(hands, superFunc, target, noEventSend)
        if target ~= nil and target.node ~= nil and g_currentMission ~= nil then
            local object = g_currentMission:getNodeObject(target.node)
            if object ~= nil and object.spsDsOnGrabbed ~= nil
               and (object.getCanBePickedUp == nil or object:getCanBePickedUp(hands.getCarryingPlayer ~= nil and hands:getCarryingPlayer() or nil)) then
                object:spsDsOnGrabbed(hands)
            end
        end
        return superFunc(hands, target, noEventSend)
    end)
end
