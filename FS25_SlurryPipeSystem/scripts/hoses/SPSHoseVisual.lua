-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSHoseVisual.lua
-- [SPS 1.0.1.8] PROOF BUILD — the ONE hose class for the new physical hoses in
-- i3d/pipes/hoses.i3d (pipe_F/M, pipe_F/F, pipe_M/M, waterHose).
--
-- Status: steps 2b/3/4 (2026-10-13) - LIVE for EVERY hose the mod draws when SPSHoseVisual.LIVE is true:
-- coupler-to-coupler slurry (SPSM_Couplers._createCouplerVisual), chain segments (SPSPipeChain._loadPipe),
-- sprayer and water/milk lane hoses (SPSSprayerPipeVisual.createPipe). With LIVE false everything falls back to the old
-- SPSPipeVisual / SPSSprayerPipeVisual / SPSPipeChain keep drawing every hose the
-- game shows. This file exists to answer the work-up's proofs T1–T5 in game via
-- the console commands at the bottom (spsHoseProof / spsHoseProofFree /
-- spsHoseProofClear). See 05_PROJECT_DOCS/NEW_HOSES_WORKUP.md sections 8–9.
--
-- Asset facts the class relies on (read from hoses.i3d, 2026-10-11):
--   * every hose is ONE skinned Shape; its bones, its "<name>_endConnector" node
--     and its "detectionNode01" triangle are DIRECT CHILDREN of that shape;
--   * the mesh runs along the shape's +Z from the start coupling point (origin)
--     to the end coupling point (the _endConnector node, ~4.1 m);
--   * 13 bones, UNEVEN spacing, numbered differently per hose (Bone01..13,
--     Bone14..26, ...) — so bones are found by the "Bone" prefix and ORDERED BY
--     THEIR REST Z, never by number or child index;
--   * each bone carries one kinematic "col" capsule (group 0x11004, mask
--     0xfe3efb83) — collisions wanted by William, so clones add physics;
--   * materials: hose_mat is the rubber; the metal end pieces share the same
--     colorScale parameter, so colour must go to ONE material index.
--
-- Engine facts (decoded dataS, PROVEN): getShapeIsSkinned(node),
-- getNumOfShapeBones(node), getShapeBone(node, idx0) and
-- setShapeBones(node, skeleton, oldSkeleton, keepBindPoses) — see
-- PlaceableDynamicallyLoadedParts.lua:67-80, I3DUtil.setShapeBonesRec;
-- clone(node, groupUnderParent, callOnCreate, addPhysics) — AdsSystem.lua:106,
-- MotionPathEffect.lua:334; getNumOfMaterials / getMaterialSlotName /
-- setShaderParameter(..., materialIndex) — VehicleMaterial.lua:139-154.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSHoseVisual 1.0.1.8 loaded (proof build)") end

SPSHoseVisual = {}
SPSHoseVisual.__index = SPSHoseVisual

SPSHoseVisual.DEF_FILE = "i3d/pipes/hoses.xml"   -- the one definition of every hose
SPSHoseVisual.FILE     = "i3d/pipes/hoses.i3d"   -- fallback if hoses.xml names no i3d

-- Variant key -> { shape, fluid, startEnd, farEnd, radius, hoseMatIndex }, filled from hoses.xml
-- by SPSHoseVisual.loadDefinitions(). startEnd = the end at the shape origin (Bone01), farEnd =
-- the end at <shape>_endConnector; for pipe_F/M the first letter is the start end (William).
-- Also SPSHoseVisual.CONNECTORS = { name -> { fluid, fluids (set), gender, accepts } } for connections.i3d.
SPSHoseVisual.VARIANTS   = {}
SPSHoseVisual.CONNECTORS = {}

-- Read hoses.xml into VARIANTS / CONNECTORS. Returns the i3d path to load (or nil on failure).
function SPSHoseVisual.loadDefinitions(modDirectory)
    local path = modDirectory .. SPSHoseVisual.DEF_FILE
    if not fileExists(path) then
        print("[SPS HOSE] loadDefinitions: ERROR not found " .. path)
        return nil
    end
    local xmlFile = XMLFile.load("spsHoses", path)
    if xmlFile == nil then
        print("[SPS HOSE] loadDefinitions: ERROR could not read " .. path)
        return nil
    end
    local folder = string.gsub(SPSHoseVisual.DEF_FILE, "[^/]*$", "")
    local i3dName = xmlFile:getString("hoses#i3d")
    local i3dPath = (i3dName ~= nil and i3dName ~= "") and (modDirectory .. folder .. i3dName) or (modDirectory .. SPSHoseVisual.FILE)
    SPSHoseVisual.VARIANTS, SPSHoseVisual.CONNECTORS = {}, {}
    local idx, n = 0, 0
    while true do
        local key = string.format("hoses.hose(%d)", idx)
        if not xmlFile:hasProperty(key) then break end
        local k     = xmlFile:getString(key .. "#key")
        local shape = xmlFile:getString(key .. "#shape")
        if k ~= nil and shape ~= nil then
            SPSHoseVisual.VARIANTS[string.upper(k)] = {
                shape        = shape,
                fluid        = string.lower(xmlFile:getString(key .. "#fluid", "slurry")),
                startEnd     = string.lower(xmlFile:getString(key .. "#startEnd", "male")),
                farEnd       = string.lower(xmlFile:getString(key .. "#farEnd", "male")),
                radius       = xmlFile:getFloat(key .. "#radius", 0.07),
                hoseMatIndex = xmlFile:getInt(key .. "#hoseMatIndex", 0),
                -- false = the rubber keeps the material's own colorScale (milk hose is white by
                -- design); true = the settings-menu pipe colour is applied to hose_mat.
                tintable     = xmlFile:getBool(key .. "#tintable", true),
            }
            n = n + 1
        else
            print(string.format("[SPS HOSE] loadDefinitions: WARNING hose(%d) needs key= and shape=", idx))
        end
        idx = idx + 1
    end
    idx = 0
    local nc = 0
    while true do
        local key = string.format("hoses.connectors.connector(%d)", idx)
        if not xmlFile:hasProperty(key) then break end
        local name = xmlFile:getString(key .. "#name")
        if name ~= nil then
            local gender = string.lower(xmlFile:getString(key .. "#gender", "female"))
            local opposite = (gender == "male") and "female" or ((gender == "female") and "male" or gender)
            -- fluid= is a space-separated list ("water milk": the 80 mm fittings serve both).
            local fluidList = string.lower(xmlFile:getString(key .. "#fluid", "slurry"))
            local fluids, firstFluid = {}, nil
            for f in string.gmatch(fluidList, "%S+") do
                fluids[f] = true
                if firstFluid == nil then firstFluid = f end
            end
            SPSHoseVisual.CONNECTORS[name] = {
                fluid   = firstFluid or "slurry",   -- first listed, for messages
                fluids  = fluids,                    -- set: fluids["milk"] == true
                gender  = gender,
                accepts = string.lower(xmlFile:getString(key .. "#accepts", opposite)),
            }
            nc = nc + 1
        end
        idx = idx + 1
    end
    xmlFile:delete()
    print(string.format("[SPS HOSE] loadDefinitions: %d hose(s), %d connector(s) from %s", n, nc, path))
    if n == 0 then return nil end
    return i3dPath
end

-- ---------------------------------------------------------------------------
-- End-gender rule (William 2026-10-12): every connection point has a gender and
-- a hose end only mates with the OPPOSITE one. The coupler XML attribute
-- `connector="male|female"` (SlurryPipeManager, default vehicle=male,
-- placeable=female) has always meant "the hose end that plugs in HERE", so a
-- tanker (male) to a store (male) needs the M/M hose. A laid hose's free end is
-- simply that end's own gender; whatever plugs into it must be the opposite.
-- pickVariant returns the variant whose ends match the two couplers, and
-- whether it has to be laid from the far coupler (reversed) to do so.
-- ---------------------------------------------------------------------------
-- fluid: "slurry" | "water" | "milk". The MILK hose carries the same end type as the
-- water hose ("water" ends, 80 mm), so the FLUID is what tells them apart: a milk
-- source must pass fluid="milk" (William 2026-10-13: milk hose for milk connections).
-- With no fluid given, water ends mean water, anything else means slurry.
function SPSHoseVisual.pickVariant(startWanted, farWanted, fluid)
    startWanted = string.lower(tostring(startWanted or "male"))
    farWanted   = string.lower(tostring(farWanted   or "female"))
    if fluid == nil or fluid == "" then
        fluid = (startWanted == "water" or farWanted == "water") and "water" or "slurry"
    end
    fluid = string.lower(tostring(fluid))
    -- Sorted keys: never let pairs() order decide between two variants.
    local keys = {}
    for key in pairs(SPSHoseVisual.VARIANTS) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local v = SPSHoseVisual.VARIANTS[key]
        if v.fluid == fluid and v.startEnd == startWanted and v.farEnd == farWanted then return key, false end
    end
    for _, key in ipairs(keys) do
        local v = SPSHoseVisual.VARIANTS[key]
        if v.fluid == fluid and v.startEnd == farWanted and v.farEnd == startWanted then return key, true end
    end
    return nil, false
end

SPSHoseVisual.HOSE_MATERIAL_SLOT = "hose"   -- slot name William may set on hose_mat in GE

-- Curve shape of the AUTOMATIC hose (William 2026-10-13, screenshot 10:05): a plain cubic
-- bezier that leaves the start coupler along its direction, droops by SAG_FACTOR x span,
-- arrives along the end direction, and simply compresses or stretches its mesh to the
-- distance between the two couplers. The length-fitted sag + sideways bow of the first
-- step-2 build laid an S-bend he did not want and was removed the same day. Fixed-length
-- behaviour belongs to the store-bought physical pipes later, not to this connection.
SPSHoseVisual.TENSION_FACTOR  = 0.4    -- end-tangent length as a share of the span
SPSHoseVisual.SAG_FACTOR      = 0.08   -- droop as a share of the span
-- [SPS HOSE 2026-10-13, William's screenshots 13:19-13:20] Rigid end runs. The metal fitting,
-- its clamp band and the first rib are skinned across the last TWO bones at each end, and the
-- bezier used to start bending at the very first bone gap (0.27 m from the fitting), so the band
-- swung with the curve and the end looked broken. Now RIGID_END_BONES bones at each end sit
-- exactly on the coupler axis (position AND rotation) and the curve runs between the inner
-- rigid bones. Rotations of the curve bones come from their FINAL neighbour positions (after
-- the floor clamp), never from the raw curve tangent - the old tangent rotations tilted bones
-- that the floor had lifted into a straight line, which showed as kinks down a flat-lying chain.
SPSHoseVisual.RIGID_END_BONES = 2
-- [SPS 1.0.1.8] hoses further than this (m, hose midpoint to camera) are not reshaped; 0 = off
SPSHoseVisual.CULL_DISTANCE = 120
SPSHoseVisual.ARC_SAMPLES     = 64     -- polyline samples per curve evaluation
SPSHoseVisual.TEMPLATE_Y      = -1000  -- the invisible template parks far below the map

-- [SPS HOSE steps 2b/3/4] ONE live switch for every hose (William 2026-10-13: "move them all
-- over to the new pipes"). true = slurry coupler connections, chain segments, sprayer hoses and
-- water/milk lane hoses are all drawn with this class; false = the old visuals
-- (SPSPipeVisual / SPSPipeChain old loader / SPSSprayerPipeVisual). Console `spsHoseLive on|off`
-- flips it at runtime for NEW hoses; hoses already laid keep the visual they were born with.
SPSHoseVisual.LIVE = true
-- Reach of the 80 mm hoses (water / milk / sprayer lanes). The old sprayer mesh was 7.58 m, the
-- new one is 4.16 m, so a coupling declaring (or defaulting to) 7.5 m would stretch it x1.8.
-- Work-up 6c (William 2026-10-02): effective reach = min(XML reach, hose reach); nobody edits an
-- XML, a 7.5 simply behaves as 4.0. Slurry couplings are NOT capped (their reach is already 4.0).
SPSHoseVisual.REACH_80MM = 4.0

function SPSHoseVisual.capReach80(reach, label)
    if not SPSHoseVisual.LIVE then return reach end
    if reach ~= nil and reach > SPSHoseVisual.REACH_80MM then
        spsInfo(string.format("[SPS HOSE] reach %.1f -> %.1f (80 mm hose length) %s", reach, SPSHoseVisual.REACH_80MM, tostring(label or "")))
        return SPSHoseVisual.REACH_80MM
    end
    return reach
end

-- [SPS FLOOR] Floor re-probe window, same mechanics as SPSPipeVisual (see its header): for
-- FLOOR_RECHECK_WINDOW ms after a hose's first update, and again whenever floorEpoch is
-- bumped (a placeable finalising placement, init.lua), the per-bone floor cache is dropped
-- every FLOOR_RECHECK_INTERVAL ms and the floor re-probed, bypassing the pose gate - so a
-- hose rebuilt from a save before a concrete pad's collision existed climbs onto the pad.
SPSHoseVisual.FLOOR_RECHECK_WINDOW   = 15000
SPSHoseVisual.FLOOR_RECHECK_INTERVAL = 1000
SPSHoseVisual.floorEpoch             = 0

function SPSHoseVisual.bumpFloorEpoch()
    SPSHoseVisual.floorEpoch = SPSHoseVisual.floorEpoch + 1
end

-- Returns true when this update must re-probe the floor (cache already cleared).
function SPSHoseVisual._floorRecheckDue(inst)
    local now   = g_time or 0
    local epoch = SPSHoseVisual.floorEpoch
    if inst._floorEpoch ~= epoch then
        inst._floorEpoch        = epoch
        inst._floorRecheckUntil = now + SPSHoseVisual.FLOOR_RECHECK_WINDOW
        inst._floorNextRecheck  = now
    end
    local untilT = inst._floorRecheckUntil
    if untilT == nil then return false end
    if now >= untilT then
        inst._floorRecheckUntil = nil
        return false
    end
    if now < (inst._floorNextRecheck or 0) then return false end
    inst._floorNextRecheck = now + SPSHoseVisual.FLOOR_RECHECK_INTERVAL
    inst._floorCache = nil
    return true
end

local function dbg(fmt, ...)
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn ~= nil and SPSDebugConfig.isOn("SPSHoseVisual") then
        print("[SPS HOSE] " .. string.format(fmt, ...))
    end
end
local function say(fmt, ...)
    print("[SPS HOSE] " .. string.format(fmt, ...))
end
local function valid(n) return n ~= nil and n ~= 0 and entityExists(n) end
local function findChildByName(node, name)
    if not valid(node) then return nil end
    for i = 0, getNumOfChildren(node) - 1 do
        local c = getChildAt(node, i)
        if getName(c) == name then return c end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- construction / template load
-- ---------------------------------------------------------------------------
function SPSHoseVisual.new(modDirectory)
    local self = setmetatable({}, SPSHoseVisual)
    self.modDirectory = modDirectory
    self.templateRoot = nil
    self.descriptors  = {}   -- variantKey -> descriptor (see _describeShape)
    self.hoses        = {}   -- inst list (every hose this class created)
    self._isLoaded    = false
    return self
end

function SPSHoseVisual:isReady() return self._isLoaded end

-- Collect the children of a hose shape: bones (ordered by rest Z), end node, detection.
function SPSHoseVisual._describeShape(shape, variantKey, v)
    local d = {
        key = variantKey, shapeName = v.shape, templateShape = shape,
        radius = v.radius, hoseMatIndex = v.hoseMatIndex, fluid = v.fluid, tintable = v.tintable,
        boneNames = {}, boneRestZ = {}, endRestZ = nil, endNodeName = nil, detectionStartName = "detectionNode01",
    }
    local bones = {}
    for i = 0, getNumOfChildren(shape) - 1 do
        local c    = getChildAt(shape, i)
        local name = getName(c) or ""
        local _, _, z = getTranslation(c)
        if string.sub(name, 1, 4) == "Bone" then
            table.insert(bones, { name = name, z = z })
        elseif string.find(name, "_endConnector", 1, true) ~= nil then
            d.endNodeName = name
            d.endRestZ    = z
        end
    end
    table.sort(bones, function(a, b) return a.z < b.z end)
    for i, b in ipairs(bones) do
        d.boneNames[i] = b.name
        d.boneRestZ[i] = b.z
    end
    d.numBones = #bones
    if d.endRestZ == nil and d.numBones > 0 then d.endRestZ = d.boneRestZ[d.numBones] end
    d.restLength = (d.endRestZ or 0)
    d.skinned = getShapeIsSkinned(shape)
    d.numShapeBones = d.skinned and getNumOfShapeBones(shape) or 0
    return d
end

function SPSHoseVisual:load()
    local path = SPSHoseVisual.loadDefinitions(self.modDirectory)
    if path == nil then
        say("load: ERROR no hose definitions - hoses disabled")
        return
    end
    if not fileExists(path) then
        say("load: ERROR not found %s", path)
        return
    end
    local root = loadI3DFile(path)
    if root == nil or root == 0 then
        say("load: ERROR loadI3DFile failed %s", path)
        return
    end
    -- Floor ray must never see any SPS hose (same rule as the old pipes).
    if SPSPipeVisual ~= nil and SPSPipeVisual._stripFloorBitsRec ~= nil then
        SPSPipeVisual._stripFloorBitsRec(root)
    end
    link(getRootNode(), root)
    setTranslation(root, 0, SPSHoseVisual.TEMPLATE_Y, 0)
    setVisibility(root, false)
    -- The template is never played with: take its 52 kinematic capsules out of
    -- physics (vanilla pairs addToPhysics/removeFromPhysics the same way,
    -- FenceSegment.lua, HandToolHands.lua). Clones get physics added in place.
    removeFromPhysics(root)
    self.templateRoot = root

    local byName = {}
    for i = 0, getNumOfChildren(root) - 1 do
        local c = getChildAt(root, i)
        byName[getName(c) or ""] = c
    end
    local found = 0
    for key, v in pairs(SPSHoseVisual.VARIANTS) do
        local shape = byName[v.shape]
        if shape ~= nil then
            local d = SPSHoseVisual._describeShape(shape, key, v)
            self.descriptors[key] = d
            found = found + 1
            say("load: %-5s shape='%s' skinned=%s shapeBones=%d childBones=%d rest=%.3f m first=%s@%.3f last=%s@%.3f end=%s",
                key, v.shape, tostring(d.skinned), d.numShapeBones, d.numBones, d.restLength,
                tostring(d.boneNames[1]), d.boneRestZ[1] or -1,
                tostring(d.boneNames[d.numBones]), d.boneRestZ[d.numBones] or -1, tostring(d.endNodeName))
        else
            say("load: WARNING variant %s: shape '%s' not in %s", key, v.shape, path)
        end
    end
    local defined = 0
    for _ in pairs(SPSHoseVisual.VARIANTS) do defined = defined + 1 end
    self._isLoaded = found > 0
    say("load: %s (%d/%d variants) %s", self._isLoaded and "OK" or "ERROR", found, defined, path)
    say("load: live hoses %s for slurry couplers, chains, sprayer and water/milk lanes (spsHoseLive on|off)", SPSHoseVisual.LIVE and "ON" or "OFF")
end

function SPSHoseVisual:delete()
    for i = #self.hoses, 1, -1 do
        self:destroyHose(self.hoses[i])
    end
    self.hoses = {}
    if valid(self.templateRoot) then delete(self.templateRoot) end
    self.templateRoot = nil
    self.descriptors  = {}
    self._isLoaded    = false
end

-- ---------------------------------------------------------------------------
-- instantiate one hose: clone (default) | rebind (clone + setShapeBones) | load
-- Returns shape node, its own child map {name -> node}, and the node to delete
-- when the hose goes (the shape itself for clones, the whole file root for load).
-- ---------------------------------------------------------------------------
function SPSHoseVisual:_instantiate(d, mode, addPhysics)
    local shape, owner
    if mode == "load" then
        local path = self.modDirectory .. SPSHoseVisual.FILE
        local root = loadI3DFile(path)
        if root == nil or root == 0 then return nil end
        if SPSPipeVisual ~= nil and SPSPipeVisual._stripFloorBitsRec ~= nil then SPSPipeVisual._stripFloorBitsRec(root) end
        link(getRootNode(), root)
        -- keep only the wanted hose; the other objects (and their 39 capsules) go
        for i = getNumOfChildren(root) - 1, 0, -1 do
            local c = getChildAt(root, i)
            if getName(c) == d.shapeName then shape = c else delete(c) end
        end
        if shape == nil then delete(root); return nil end
        owner = root
    else
        if not valid(d.templateShape) then return nil end
        -- No physics at clone time: the old hoses got theirs from loadI3DFile in
        -- place; a clone gets it from addToPhysics AFTER it is linked under its
        -- coupler (createHose), the base-game idiom (link -> addToPhysics:
        -- PlaceableHusbandryFence.lua:389-390, HandToolHands.lua:108-109).
        shape = clone(d.templateShape, false, false, false)
        if shape == nil or shape == 0 then return nil end
        owner = shape
        if mode == "rebind" then
            -- Re-point the clone's skin at ITS OWN child bones (by name, from the
            -- template skeleton). Needed only if T1 shows the clone still deforms
            -- with the template's bones.
            setShapeBones(shape, shape, d.templateShape, true)
        end
    end
    local children = {}
    for i = 0, getNumOfChildren(shape) - 1 do
        local c = getChildAt(shape, i)
        children[getName(c) or ""] = c
    end
    return shape, children, owner
end

-- T1 evidence: which skeleton does this shape's skin point at?
function SPSHoseVisual._skinReport(shape, children, d)
    if not getShapeIsSkinned(shape) then return "NOT SKINNED" end
    local own, templ, other = 0, 0, 0
    local ownSet = {}
    for _, n in pairs(children) do ownSet[n] = true end
    local templSet = {}
    if valid(d.templateShape) then
        for i = 0, getNumOfChildren(d.templateShape) - 1 do templSet[getChildAt(d.templateShape, i)] = true end
    end
    local n = getNumOfShapeBones(shape)
    for i = 0, n - 1 do
        local b = getShapeBone(shape, i)
        if ownSet[b] then own = own + 1 elseif templSet[b] then templ = templ + 1 else other = other + 1 end
    end
    return string.format("skinned, %d bones: own=%d template=%d other=%d -> %s",
        n, own, templ, other, (own == n) and "OK (skin follows this hose's bones)" or "FAIL (skin bound elsewhere)")
end

-- ---------------------------------------------------------------------------
-- createHose
--   variantKey : "FM" | "FF" | "MM" | "WATER"
--   startNode  : node whose +Z (times startSign) is the direction the hose LEAVES
--                the start coupling point (normally a coupler's outNode, sign +1)
--   endNode    : node whose +Z (times endSign) is the direction the hose ARRIVES
--                at the far coupling point (normally a coupler's inNode, sign +1)
--   opts       : { mode="clone"|"rebind"|"load", physics=true, startSign=1, endSign=1 }
-- The shape root is linked under startNode (hose start = coupling point). The
-- far end piece follows the LAST BONE, which is posed so the end coupling point
-- lands on endNode. Interior bones sit at their own rest arc-length share of a
-- cubic bezier between the first and last bone.
-- ---------------------------------------------------------------------------
function SPSHoseVisual:createHose(variantKey, startNode, endNode, opts)
    opts = opts or {}
    if not self._isLoaded then say("createHose: ERROR not loaded"); return nil end
    local d = self.descriptors[variantKey]
    if d == nil then say("createHose: ERROR unknown variant %s", tostring(variantKey)); return nil end
    if not valid(startNode) or not valid(endNode) then say("createHose: ERROR start/end node invalid"); return nil end
    if d.numBones < 3 then say("createHose: ERROR %s has %d bones", variantKey, d.numBones); return nil end

    local mode = opts.mode or "clone"
    local shape, children, owner = self:_instantiate(d, mode, opts.physics)
    if shape == nil then say("createHose: ERROR instantiate failed (mode=%s)", mode); return nil end

    local bones = {}
    for i = 1, d.numBones do
        local b = children[d.boneNames[i]]
        if b == nil then
            say("createHose: ERROR bone %s missing on instance", tostring(d.boneNames[i]))
            if valid(owner) then delete(owner) end
            return nil
        end
        bones[i] = b
    end

    local inst = {
        isHose = true,   -- SPSPipeVisual:updatePipe/destroyPipe/applyColor delegate on this
        variant = variantKey, d = d, mode = mode,
        shape = shape, owner = owner, bones = bones,
        endNode = children[d.endNodeName or ""],
        detStart = children[d.detectionStartName],          -- detectionNode01 (+02/03) at the hose START
        detEnd   = findChildByName(children[d.endNodeName or ""], "detectionNode04"),  -- (+05/06) under the far end
        startNode = startNode, endNodeTarget = endNode,
        startSign = opts.startSign or 1, endSign = opts.endSign or 1,
        noFloor = opts.noFloor == true,   -- shop preview: no terrain/floor clamp (hangar is its own scene)
        _lastPose = nil, _floorCache = nil, _poly = nil,
    }

    -- Hose start = coupling point: the shape root rides on startNode.
    link(startNode, shape)
    setTranslation(shape, 0, 0, 0)
    setRotation(shape, 0, (inst.startSign < 0) and math.pi or 0, 0)
    -- [SPS HOSE T6] collisions: the per-bone "col" capsules become kinematic
    -- bodies here, in place, exactly as the old pipes' pieces did at load.
    if mode ~= "load" and opts.physics ~= false then
        addToPhysics(shape)
        inst.physicsAdded = true
    end

    inst.skinReport = SPSHoseVisual._skinReport(shape, children, d)
    self:applyColor(inst, (opts.color and opts.color[1]) or 1, (opts.color and opts.color[2]) or 1, (opts.color and opts.color[3]) or 1)
    self:updateHose(inst, true)
    table.insert(self.hoses, inst)
    return inst
end

-- ---------------------------------------------------------------------------
-- [SPS HOSE step 2b] createSlurryHose — adapter for the slurry coupler code.
-- Takes exactly what SPSM_Couplers handed the old SPSPipeVisual:createPipe:
--   nodeA = LEAD coupling's inNode   (hose START in the old -Z mesh convention)
--   nodeB = FOLLOW coupling's outNode (hose END)
--   startWanted / endWanted = each coupling's connector="male|female" = the hose
--   end that must sit there (end-gender rule, D7).
-- Direction mapping onto this +Z class:
--   inNode  +Z points INTO its coupling  -> leaving from it = sign -1, arriving at it = sign +1
--   outNode +Z points OUT of its coupling -> leaving from it = sign +1, arriving at it = sign -1
-- pickVariant may report that the only matching hose has to be laid from the
-- follow side (reversed): the start piece then sits on nodeB and the signs flip.
-- Example: tanker (male) to store (male) -> M/M hose, not reversed.
-- ---------------------------------------------------------------------------
function SPSHoseVisual:createSlurryHose(nodeA, nodeB, startWanted, endWanted, opts)
    local key, reversed = SPSHoseVisual.pickVariant(startWanted, endWanted, "slurry")
    if key == nil then
        say("createSlurryHose: ERROR no slurry hose has ends %s/%s", tostring(startWanted), tostring(endWanted))
        return nil
    end
    local o = opts or {}
    o.mode = o.mode or "clone"
    if o.physics == nil then o.physics = true end
    local inst
    if not reversed then
        o.startSign, o.endSign = -1, -1
        inst = self:createHose(key, nodeA, nodeB, o)
    else
        o.startSign, o.endSign = 1, 1
        inst = self:createHose(key, nodeB, nodeA, o)
    end
    if inst ~= nil then
        inst.liveSlurry = true
        -- Always logged (not channel-gated): the one line that proves a connection is drawn
        -- by the NEW hose and not the old bez pipe (William's question, 2026-10-13).
        say("LIVE: %s hose%s drawn for coupler connection start=%s end=%s (ends wanted %s/%s), %d hose(s) owned",
            key, reversed and " (laid reversed)" or "", tostring(getName(nodeA)), tostring(getName(nodeB)),
            tostring(startWanted), tostring(endWanted), #self.hoses)
    end
    return inst
end

-- ---------------------------------------------------------------------------
-- [SPS HOSE step 4] createLaneHose — adapter for sprayers and the water/milk lanes.
-- Same arguments the old SPSSprayerPipeVisual:createPipe took: nodeA = vehicle
-- connector outNode (hose leaves along its +Z), nodeB = far inNode (hose arrives
-- along its +Z) - the old sprayer mesh ran +Z too, so both signs are +1.
-- fluid: "milk" -> MILK hose (white), anything else -> WATER hose (blue); fert and
-- herbicide sprayers use the water hose (D1).
-- ---------------------------------------------------------------------------
function SPSHoseVisual:createLaneHose(nodeA, nodeB, fluid, opts)
    local key = (string.lower(tostring(fluid or "water")) == "milk") and "MILK" or "WATER"
    if self.descriptors[key] == nil then
        say("createLaneHose: ERROR variant %s not loaded", key)
        return nil
    end
    local o = opts or {}
    o.mode = o.mode or "clone"
    if o.physics == nil then o.physics = true end
    o.startSign, o.endSign = 1, 1
    local inst = self:createHose(key, nodeA, nodeB, o)
    if inst ~= nil then
        inst.liveLane = true
        say("LIVE: %s hose drawn for %s lane connection start=%s end=%s, %d hose(s) owned",
            key, tostring(fluid or "water"), tostring(getName(nodeA)), tostring(getName(nodeB)), #self.hoses)
    end
    return inst
end

-- ---------------------------------------------------------------------------
-- [SPS HOSE step 3] createChainSegmentHose — one laid chain segment.
-- startProxy = the segment's start transform (old "pipeRoot": the chain runs along
-- its -Z), endProxy = the segment's end transform (old "endConnectors": yaw 180, so
-- ITS +Z points back toward the start). The F/M hose is laid FROM the end proxy
-- (female end at the free chain end, male end at the start - the old look): hose
-- start = endProxy, leaving along +Z (sign +1); hose end = startProxy, arriving
-- along its +Z (sign +1). The hose shape therefore lives under endProxy; the chain
-- moves endProxy while laying and the hose follows.
-- Detection: the hose's own triangles. detectionNode01 (at the hose start) sits at
-- the chain END, detectionNode04 (under the far end) at the chain START.
-- ---------------------------------------------------------------------------
function SPSHoseVisual:createChainSegmentHose(startProxy, endProxy, color)
    if self.descriptors["FM"] == nil then
        say("createChainSegmentHose: ERROR variant FM not loaded")
        return nil
    end
    local inst = self:createHose("FM", endProxy, startProxy, { mode = "clone", physics = true, startSign = 1, endSign = 1, color = color })
    if inst ~= nil then
        inst.liveChain = true
        say("LIVE: FM hose drawn for a chain segment (female at the free end), %d hose(s) owned", #self.hoses)
    end
    return inst
end

-- ---------------------------------------------------------------------------
-- updateHose — reshape when an end moved (pose gate like the old pipes)
-- ---------------------------------------------------------------------------
local function dirFromNode(node, sign)
    local dx, dy, dz = localDirectionToWorld(node, 0, 0, sign)
    local l = math.sqrt(dx*dx + dy*dy + dz*dz)
    if l < 1e-6 then return 0, 0, 1 end
    return dx / l, dy / l, dz / l
end

-- +Z-mesh bone orientation from a unit tangent: yaw first, then pitch, no roll.
local function rotFromDir(tdx, tdy, tdz)
    local ry = math.atan2(tdx, tdz)
    local rx = -math.atan2(tdy, math.sqrt(tdx*tdx + tdz*tdz))
    return rx, ry, 0
end

function SPSHoseVisual:updateHose(inst, force)
    if inst == nil or not valid(inst.shape) then return end
    local sN, eN = inst.startNode, inst.endNodeTarget
    if not valid(sN) or not valid(eN) then return end
    local d = inst.d

    local ax, ay, az    = getWorldTranslation(sN)
    local bx, by, bz    = getWorldTranslation(eN)
    local arx, ary, arz = getWorldRotation(sN)
    local brx, bry, brz = getWorldRotation(eN)
    if ax == nil or bx == nil then return end

    local floorRecheck = SPSHoseVisual._floorRecheckDue(inst)
    local lp = inst._lastPose
    if lp ~= nil and not force and not floorRecheck then
        local d1 = (ax-lp[1])^2 + (ay-lp[2])^2 + (az-lp[3])^2
        local d2 = (bx-lp[4])^2 + (by-lp[5])^2 + (bz-lp[6])^2
        local r1 = (arx-lp[7])^2 + (ary-lp[8])^2 + (arz-lp[9])^2
        local r2 = (brx-lp[10])^2 + (bry-lp[11])^2 + (brz-lp[12])^2
        if d1 < 1e-6 and d2 < 1e-6 and r1 < 1e-6 and r2 < 1e-6 then return end
    end
    -- [SPS 1.0.1.8] distance cull: a hose nobody can see is not reshaped. _lastPose is left alone, so the first
    -- frame back in range sees the moved ends and reshapes.
    if not force and SPSHoseVisual.CULL_DISTANCE > 0 and getCamera ~= nil then
        local cam = getCamera()
        if cam ~= nil and cam ~= 0 then
            local cx, cy, cz = getWorldTranslation(cam)
            local cd = SPSHoseVisual.CULL_DISTANCE
            local mx, my, mz = (ax + bx) * 0.5 - cx, (ay + by) * 0.5 - cy, (az + bz) * 0.5 - cz
            if lp ~= nil and mx*mx + my*my + mz*mz > cd * cd then return end
        end
    end
    -- reuse the pose table (was a new 12-value table per moving hose per frame)
    if lp == nil then
        lp = {}
        inst._lastPose = lp
    end
    lp[1], lp[2], lp[3], lp[4], lp[5], lp[6] = ax, ay, az, bx, by, bz
    lp[7], lp[8], lp[9], lp[10], lp[11], lp[12] = arx, ary, arz, brx, bry, brz

    -- Directions: leaving the start, arriving at the end.
    local sdx, sdy, sdz = dirFromNode(sN, inst.startSign)
    local edx, edy, edz = dirFromNode(eN, inst.endSign)

    local N     = d.numBones
    local zEnd  = d.endRestZ or d.boneRestZ[N]
    local zr    = d.boneRestZ
    -- Rigid runs: bones 1..ra follow the start axis, rb..N the end axis; the curve joins bone ra to bone rb.
    local R = SPSHoseVisual.RIGID_END_BONES
    if R < 1 then R = 1 end
    if 2 * R + 1 > N then R = 1 end
    local ra, rb = R, N - R + 1
    local rest = zr[rb] - zr[ra]                 -- mesh length of the curved part

    -- Curve endpoints = the inner rigid bones, on their coupler axes.
    local p0x, p0y, p0z = ax + sdx * zr[ra], ay + sdy * zr[ra], az + sdz * zr[ra]
    local backB = zEnd - zr[rb]
    local p3x, p3y, p3z = bx - edx * backB, by - edy * backB, bz - edz * backB

    local dx, dy, dz = p3x - p0x, p3y - p0y, p3z - p0z
    local span = math.sqrt(dx*dx + dy*dy + dz*dz)
    if span < 0.01 then return end

    -- Curve(s). Normal: ONE plain cubic (tangents along the coupler directions, droop of
    -- SAG_FACTOR x span, no length fitting - see the header), the mesh compressing or
    -- stretching to the distance. Held bought pipe (inst.via = {x,y,z, restZ}): TWO cubics
    -- meeting at the hand from below - start tip -> hand, hand -> end tip - so the pipe
    -- drapes from wherever it was grabbed; the bones are split at the grabbed rest position.
    -- Sampled into a polyline so bones sit at their own rest share of the laid length.
    local terrainRoot = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if inst.noFloor then terrainRoot = nil end
    local S = SPSHoseVisual.ARC_SAMPLES
    local poly = inst._poly
    if poly == nil then poly = { x = {}, y = {}, z = {}, c = {} }; inst._poly = poly end
    local via = inst.via
    local splitZ, lenA = nil, nil
    local sag = inst.noFloor and 0 or span * SPSHoseVisual.SAG_FACTOR
    local cps = {}   -- list of cubic control point sets {p0x..p3z}
    if via ~= nil and via[4] > zr[ra] + 0.05 and via[4] < zr[rb] - 0.05 then
        local vx, vy, vz = via[1], via[2], via[3]
        local la = math.sqrt((vx-p0x)^2 + (vy-p0y)^2 + (vz-p0z)^2)
        local lb = math.sqrt((p3x-vx)^2 + (p3y-vy)^2 + (p3z-vz)^2)
        local ta, tb = la * SPSHoseVisual.TENSION_FACTOR, lb * SPSHoseVisual.TENSION_FACTOR
        cps[1] = { p0x, p0y, p0z,  p0x + sdx*ta, p0y + sdy*ta, p0z + sdz*ta,  vx, vy - ta, vz,  vx, vy, vz }
        cps[2] = { vx, vy, vz,  vx, vy - tb, vz,  p3x - edx*tb, p3y - edy*tb, p3z - edz*tb,  p3x, p3y, p3z }
        splitZ = via[4]
        sag = 0
    else
        local tension = span * SPSHoseVisual.TENSION_FACTOR
        cps[1] = { p0x, p0y, p0z,
                   p0x + sdx * tension, p0y + sdy * tension - sag, p0z + sdz * tension,
                   p3x - edx * tension, p3y - edy * tension - sag, p3z - edz * tension,
                   p3x, p3y, p3z }
    end
    local lx, ly, lz = p0x, p0y, p0z
    poly.x[0], poly.y[0], poly.z[0], poly.c[0] = p0x, p0y, p0z, 0
    local laid, k = 0, 0
    for ci = 1, #cps do
        local c = cps[ci]
        for i = 1, S do
            local t = i / S; local mt = 1 - t
            local mt2, t2 = mt*mt, t*t
            local a, b, cc, e = mt2*mt, 3*mt2*t, 3*mt*t2, t2*t
            local x = a*c[1] + b*c[4] + cc*c[7] + e*c[10]
            local y = a*c[2] + b*c[5] + cc*c[8] + e*c[11]
            local z = a*c[3] + b*c[6] + cc*c[9] + e*c[12]
            laid = laid + math.sqrt((x-lx)^2 + (y-ly)^2 + (z-lz)^2)
            k = k + 1
            poly.x[k], poly.y[k], poly.z[k], poly.c[k] = x, y, z, laid
            lx, ly, lz = x, y, z
        end
        if ci == 1 and #cps == 2 then lenA = laid end
    end
    local NS = k
    inst.curveLength = laid
    inst.restSpan    = rest
    inst._sag        = sag

    -- Final world positions of every bone (bone 1 rides with the root and is never moved).
    local pos = inst._pos
    if pos == nil then pos = {}; inst._pos = pos end
    for i = 1, N do if pos[i] == nil then pos[i] = { 0, 0, 0 } end end
    pos[1][1], pos[1][2], pos[1][3] = ax + sdx * zr[1], ay + sdy * zr[1], az + sdz * zr[1]
    for i = 2, ra do
        pos[i][1], pos[i][2], pos[i][3] = ax + sdx * zr[i], ay + sdy * zr[i], az + sdz * zr[i]
    end
    for i = rb, N do
        local back = zEnd - zr[i]
        pos[i][1], pos[i][2], pos[i][3] = bx - edx * back, by - edy * back, bz - edz * back
    end

    -- Curve bones at their OWN rest share of the laid polyline, then the exact floor per bone
    -- (terrain + concrete pads / bridges / roads), cached while the bone stays within 0.25 m in XZ.
    local fc = inst._floorCache
    if fc == nil then fc = {}; inst._floorCache = fc end
    local seg = 1
    for i = ra + 1, rb - 1 do
        local target
        if splitZ ~= nil then
            if zr[i] <= splitZ then
                target = lenA * (zr[i] - zr[ra]) / (splitZ - zr[ra])
            else
                target = lenA + (laid - lenA) * (zr[i] - splitZ) / (zr[rb] - splitZ)
            end
        else
            target = laid * (zr[i] - zr[ra]) / rest
        end
        while seg < NS and poly.c[seg] < target do seg = seg + 1 end
        local c0, c1 = poly.c[seg-1], poly.c[seg]
        local f = (c1 > c0) and ((target - c0) / (c1 - c0)) or 0
        local px = poly.x[seg-1] + (poly.x[seg] - poly.x[seg-1]) * f
        local py = poly.y[seg-1] + (poly.y[seg] - poly.y[seg-1]) * f
        local pz = poly.z[seg-1] + (poly.z[seg] - poly.z[seg-1]) * f
        if terrainRoot ~= nil then
            local c = fc[i]
            local ty
            if c ~= nil and (px-c[1])^2 + (pz-c[2])^2 < 0.0625 then ty = c[3] end
            if ty == nil then
                ty = getTerrainHeightAtWorldPos(terrainRoot, px, 0, pz)
                if SPSPipeVisual ~= nil and SPSPipeVisual.getFloorWorldY ~= nil then
                    ty = SPSPipeVisual.getFloorWorldY(px, py, pz, ty)
                end
                fc[i] = { px, pz, ty }
            end
            local minY = ty + d.radius
            if py < minY then py = minY end
        end
        pos[i][1], pos[i][2], pos[i][3] = px, py, pz
    end

    -- Apply. Rigid bones take the axis direction; curve bones the direction between their
    -- neighbours' FINAL positions (smooth through the floor clamp, half the turn at each gap).
    local srx, sry, srz = rotFromDir(sdx, sdy, sdz)
    local erx, ery, erz = rotFromDir(edx, edy, edz)
    for i = 2, N do
        local rx, ry, rz
        if i <= ra then
            rx, ry, rz = srx, sry, srz
        elseif i >= rb then
            rx, ry, rz = erx, ery, erz
        else
            local pp, pn = pos[i-1], pos[i+1]
            local tdx, tdy, tdz = pn[1] - pp[1], pn[2] - pp[2], pn[3] - pp[3]
            local tl = math.sqrt(tdx*tdx + tdy*tdy + tdz*tdz)
            if tl > 1e-4 then
                rx, ry, rz = rotFromDir(tdx / tl, tdy / tl, tdz / tl)
            else
                rx, ry, rz = srx, sry, srz
            end
        end
        setWorldTranslation(inst.bones[i], pos[i][1], pos[i][2], pos[i][3])
        setWorldRotation(inst.bones[i], rx, ry, rz)
    end

    -- The end node (detection triangle) rides on the far coupling point.
    if valid(inst.endNode) then
        setWorldTranslation(inst.endNode, bx, by, bz)
        setWorldRotation(inst.endNode, erx, ery, erz)
    end

    -- [SPS HOSE T5] Render culling. A skinned shape is culled by its bind-pose
    -- bounding sphere (~4.1 m along +Z from the root). A laid hose that is
    -- stretched or bent away from the root axis puts its far end OUTSIDE that
    -- sphere, so the whole hose vanished when only the far end was in view
    -- (William 2026-10-11, connected hose only). Re-centre the sphere on the
    -- laid span, in the shape's local space, every reshape - the same call and
    -- space vanilla uses for its ropes (ForestryPhysicsRope.lua:251-252,
    -- ForestryRope.lua:90: worldToLocal(...) then setShapeBoundingSphere).
    -- Radius covers the sag as well as the half-span.
    local lx, ly, lz = worldToLocal(inst.shape, p3x, p3y, p3z)
    local half = 0.5 * math.sqrt(lx*lx + ly*ly + lz*lz)
    local bvRadius = half + sag + 0.6
    local cx, cy, cz = lx * 0.5, ly * 0.5, lz * 0.5
    local bv = inst._bv
    if bv == nil or math.abs(bv[1]-cx) > 0.25 or math.abs(bv[2]-cy) > 0.25 or math.abs(bv[3]-cz) > 0.25 or math.abs(bv[4]-bvRadius) > 0.25 then
        setShapeBoundingSphere(inst.shape, cx, cy, cz, bvRadius)
        inst._bv = { cx, cy, cz, bvRadius }
    end
end

-- ---------------------------------------------------------------------------
-- applyColor — rubber only. Slot name first (GE), else the per-variant index.
-- ---------------------------------------------------------------------------
function SPSHoseVisual:applyColor(inst, r, g, b)
    if inst == nil or not valid(inst.shape) then return end
    local shape = inst.shape
    local n = getNumOfMaterials(shape)
    local idx = nil
    local slots = {}
    for i = 0, n - 1 do
        local sn = getMaterialSlotName(shape, i)
        slots[#slots + 1] = tostring(sn)
        if sn == SPSHoseVisual.HOSE_MATERIAL_SLOT or sn == "hose_mat" then idx = i end
    end
    inst.materialSlots = table.concat(slots, ",")
    if inst.d.tintable == false then
        -- The rubber keeps the material's own colorScale from the i3d (milk hose: white).
        inst.colorIndex = "fixed"
        return
    end
    if idx == nil then idx = inst.d.hoseMatIndex end
    if idx ~= nil and idx < n then
        setShaderParameter(shape, "colorScale", r, g, b, nil, false, idx)
        inst.colorIndex = idx
    else
        setShaderParameter(shape, "colorScale", r, g, b, nil, false)
        inst.colorIndex = -1
    end
end

function SPSHoseVisual:destroyHose(inst)
    if inst == nil then return end
    if valid(inst.shape) then
        if inst.physicsAdded then removeFromPhysics(inst.shape) end
        link(getRootNode(), inst.shape)
    end
    if valid(inst.owner) then delete(inst.owner) end
    inst.shape, inst.owner, inst.bones, inst.endNode = nil, nil, nil, nil
    inst._lastPose, inst._floorCache, inst._floorRecheckUntil, inst._poly, inst._pos = nil, nil, nil, nil, nil
    for i, h in ipairs(self.hoses) do if h == inst then table.remove(self.hoses, i); break end end
end

function SPSHoseVisual:update(dt)
    for _, inst in ipairs(self.hoses) do self:updateHose(inst, false) end
end

-- Proof lines: tangent vs direction at both ends, gaps vs rest gaps, end roll.
function SPSHoseVisual:report(inst)
    if inst == nil or not valid(inst.shape) then return end
    local d, N = inst.d, inst.d.numBones
    local function pos(n) return getWorldTranslation(n) end
    local x1, y1, z1 = pos(inst.bones[1]); local x2, y2, z2 = pos(inst.bones[2])
    local xN, yN, zN = pos(inst.bones[N]); local xM, yM, zM = pos(inst.bones[N-1])
    local sdx, sdy, sdz = dirFromNode(inst.startNode, inst.startSign)
    local edx, edy, edz = dirFromNode(inst.endNodeTarget, inst.endSign)
    local function unit(ax, ay, az) local l = math.sqrt(ax*ax+ay*ay+az*az); if l < 1e-6 then return 0,0,0 end return ax/l, ay/l, az/l end
    local s2x, s2y, s2z = unit(x2-x1, y2-y1, z2-z1)
    local e2x, e2y, e2z = unit(xN-xM, yN-yM, zN-zM)
    local dotS = s2x*sdx + s2y*sdy + s2z*sdz
    local dotE = e2x*edx + e2y*edy + e2z*edz
    -- gaps
    local minR, maxR = math.huge, -math.huge
    for i = 2, N do
        local px, py, pz = pos(inst.bones[i]); local qx, qy, qz = pos(inst.bones[i-1])
        local gap  = math.sqrt((px-qx)^2 + (py-qy)^2 + (pz-qz)^2)
        local rest = d.boneRestZ[i] - d.boneRestZ[i-1]
        local r = (rest > 1e-4) and gap / rest or 0
        if r < minR then minR = r end
        if r > maxR then maxR = r end
    end
    -- end roll: last bone up vs target node up
    local ux, uy, uz = localDirectionToWorld(inst.bones[N], 0, 1, 0)
    local tx, ty, tz = localDirectionToWorld(inst.endNodeTarget, 0, 1, 0)
    local upDot = ux*tx + uy*ty + uz*tz
    -- end landing error: shape-local end coupling point vs target
    local ex, ey, ez = getWorldTranslation(inst.endNodeTarget)
    local cx, cy, cz = xN + edx*(d.endRestZ - d.boneRestZ[N]), yN + edy*(d.endRestZ - d.boneRestZ[N]), zN + edz*(d.endRestZ - d.boneRestZ[N])
    local landErr = math.sqrt((cx-ex)^2 + (cy-ey)^2 + (cz-ez)^2)
    say("REPORT %s mode=%s sign=%d/%d | T1 %s", inst.variant, inst.mode, inst.startSign, inst.endSign, tostring(inst.skinReport))
    say("REPORT %s | curve %.3f m vs rest span %.3f m (x%.2f) | gaps/rest min %.2f max %.2f | start tangent·dir %.3f | end tangent·dir %.3f",
        inst.variant, inst.curveLength or 0, inst.restSpan or 0,
        (inst.restSpan and inst.restSpan > 0) and (inst.curveLength or 0) / inst.restSpan or 0, minR, maxR, dotS, dotE)
    say("REPORT %s | T2 end up·target up %.3f (1 = no roll) | end landing error %.3f m | T4 slots=[%s] colour index %s",
        inst.variant, upDot, landErr, tostring(inst.materialSlots), tostring(inst.colorIndex))
    say("REPORT %s | SHAPE sag %.2f m, %d rigid bone(s) at each end | curved part laid %.3f m vs rest %.3f m (x%.3f, mesh compressed/stretched to fit) | tintable=%s fluid=%s",
        inst.variant, inst._sag or 0, SPSHoseVisual.RIGID_END_BONES, inst.curveLength or 0, inst.restSpan or 0,
        (inst.restSpan and inst.restSpan > 0) and (inst.curveLength or 0) / inst.restSpan or 0,
        tostring(inst.d.tintable), tostring(inst.d.fluid))
    -- T6 evidence: the per-bone "col" capsules - do they exist on this instance and
    -- did they get a rigid body? (clone(..., addPhysics) is the UNKNOWN here)
    local nCol, nBody, kinds, grp, msk = 0, 0, {}, nil, nil
    for i = 1, N do
        local bone = inst.bones[i]
        for c = 0, getNumOfChildren(bone) - 1 do
            local col = getChildAt(bone, c)
            if getHasClassId(col, ClassIds.SHAPE) then
                nCol = nCol + 1
                local rbt = getRigidBodyType(col)
                kinds[tostring(rbt)] = (kinds[tostring(rbt)] or 0) + 1
                if rbt ~= RigidBodyType.NONE then nBody = nBody + 1 end
                if grp == nil then grp, msk = getCollisionFilterGroup(col), getCollisionFilterMask(col) end
            end
        end
    end
    local kindList = {}
    for k, v in pairs(kinds) do kindList[#kindList + 1] = k .. "x" .. v end
    say("REPORT %s | T6 col shapes %d, with rigid body %d (types %s; KINEMATIC=%s NONE=%s) | group 0x%X mask 0x%X",
        inst.variant, nCol, nBody, table.concat(kindList, ","), tostring(RigidBodyType.KINEMATIC), tostring(RigidBodyType.NONE),
        grp or 0, msk or 0)
    -- T5 evidence: the render bounding sphere the engine culls this skinned shape by.
    local bx2, by2, bz2, br = getShapeWorldBoundingSphere(inst.shape)
    local sx, sy, sz = getWorldTranslation(inst.shape)
    local farDist = math.sqrt((xN-bx2)^2 + (yN-by2)^2 + (zN-bz2)^2)
    say("REPORT %s | T5 bounding sphere centre (%.2f %.2f %.2f) radius %.2f m | centre is %.2f m from the hose root, last bone is %.2f m from the centre (%s)",
        inst.variant, bx2 or 0, by2 or 0, bz2 or 0, br or 0,
        math.sqrt((bx2-sx)^2 + (by2-sy)^2 + (bz2-sz)^2), farDist, (br ~= nil and farDist > br) and "OUTSIDE -> culled when only the far end is in view" or "inside")
end

-- ===========================================================================
-- PROOF CONSOLE COMMANDS (dev only; the live mod never calls these)
--   spsHoseProof [variant=FM] [mode=clone|rebind|load] [reverse=0|1] [pipe=1]
--       lays a new hose beside the Nth existing slurry connection (activePipes):
--       vehicle coupler outNode -> far coupler inNode. reverse=1 lays the same
--       hose the other way round (start piece on the far coupler) = T3.
--   spsHoseProofFree [variant=FM] [mode] [length=3.8]
--       lays one hose on the ground in front of the camera, no couplers needed.
--   spsHoseProofClear      removes every proof hose and helper node.
-- ===========================================================================
SPSHoseProof = { nodes = {} }

local function parseMode(s)
    s = s and string.lower(s) or "clone"
    if s ~= "clone" and s ~= "rebind" and s ~= "load" then return "clone" end
    return s
end
local function parseVariant(s)
    s = (s ~= nil and string.lower(s) ~= "auto") and string.upper(s) or "FM"
    if SPSHoseVisual.VARIANTS[s] == nil then return "FM" end
    return s
end
local function currentColor()
    local m = g_slurryPipeManager
    if m ~= nil and m.currentPipeColor ~= nil then
        return { m.currentPipeColor.r or 1, m.currentPipeColor.g or 1, m.currentPipeColor.b or 1 }
    end
    return { 1, 1, 1 }
end

function SPSHoseProof.consoleProof(_, variant, mode, reverse, pipeArg)
    local hv = g_spsHoseVisual
    if hv == nil or not hv:isReady() then return "[SPS HOSE] proof: hose visual not loaded" end
    local m = g_slurryPipeManager
    if m == nil or m.activePipes == nil then return "[SPS HOSE] proof: no manager" end
    local want = tonumber(pipeArg) or 1
    local n, picked = 0, nil
    for _, pd in pairs(m.activePipes) do
        n = n + 1
        if n == want then picked = pd end
    end
    if picked == nil then return string.format("[SPS HOSE] proof: no slurry connection #%d (have %d). Connect a tanker first, or use spsHoseProofFree.", want, n) end

    -- Which coupling belongs to a vehicle? That one is the hose START (outNode).
    local cA, cB = picked.couplingA, picked.couplingB
    local vehA = m._findCouplingOwner ~= nil and (m:_findCouplingOwner(cA)) or nil
    local startC, endC = cA, cB
    if vehA == nil then startC, endC = cB, cA end
    local startNode = startC.outNode or startC.mountNode
    local endNode   = endC.inNode   or endC.mountNode
    local opts = { mode = parseMode(mode), physics = true, color = currentColor(), startSign = 1, endSign = 1 }
    -- No variant (or "auto") = pick it from the two couplers' declared hose ends.
    local variantKey = parseVariant(variant)
    if variant == nil or string.lower(tostring(variant)) == "auto" then
        local wantS, wantF = startC.connectorType or "male", endC.connectorType or "female"
        local picked, flip = SPSHoseVisual.pickVariant(wantS, wantF)
        if picked == nil then
            return string.format("[SPS HOSE] proof: no hose variant has ends %s/%s", tostring(wantS), tostring(wantF))
        end
        variantKey = picked
        if flip then reverse = "1" end
        say("proof: couplers want hose ends start=%s far=%s -> %s%s", wantS, wantF, picked, flip and " laid reversed" or "")
    end
    if tostring(reverse) == "1" or tostring(reverse) == "true" then
        -- lay it the other way round: start piece on the far coupler
        startNode, endNode = (endC.inNode or endC.mountNode), (startC.outNode or startC.mountNode)
        opts.startSign, opts.endSign = -1, -1
    end
    local inst = hv:createHose(variantKey, startNode, endNode, opts)
    if inst == nil then return "[SPS HOSE] proof: createHose failed (see log)" end
    say("proof: laid %s between coupling id=%s (%s) and id=%s (%s), %d proof hose(s) live",
        inst.variant, tostring(startC.id), getName(startNode) or "?", tostring(endC.id), getName(endNode) or "?", #hv.hoses)
    hv:report(inst)
    return "[SPS HOSE] proof hose laid - see log.txt REPORT lines"
end

function SPSHoseProof.consoleFree(_, variant, mode, lengthArg)
    local hv = g_spsHoseVisual
    if hv == nil or not hv:isReady() then return "[SPS HOSE] proof: hose visual not loaded" end
    local cam = getCamera()
    if cam == nil or cam == 0 then return "[SPS HOSE] proof: no camera" end
    local cx, cy, cz = getWorldTranslation(cam)
    local fx, _, fz = localDirectionToWorld(cam, 0, 0, -1)
    local fl = math.sqrt(fx*fx + fz*fz); if fl < 1e-3 then fx, fz = 0, 1 else fx, fz = fx/fl, fz/fl end
    local length = tonumber(lengthArg) or 3.8
    local terrain = g_currentMission and g_currentMission.terrainRootNode
    local function ground(x, z) return terrain and getTerrainHeightAtWorldPos(terrain, x, 0, z) or cy end
    local sx, sz = cx + fx * 2.0, cz + fz * 2.0
    local ex, ez = sx + fx * length, sz + fz * length
    local yaw = math.atan2(fx, fz)
    local a = createTransformGroup("spsHoseProofStart"); link(getRootNode(), a)
    setWorldTranslation(a, sx, ground(sx, sz) + 0.3, sz); setWorldRotation(a, 0, yaw, 0)
    local b = createTransformGroup("spsHoseProofEnd"); link(getRootNode(), b)
    setWorldTranslation(b, ex, ground(ex, ez) + 0.3, ez); setWorldRotation(b, 0, yaw, 0)
    table.insert(SPSHoseProof.nodes, a); table.insert(SPSHoseProof.nodes, b)
    local inst = hv:createHose(parseVariant(variant), a, b, { mode = parseMode(mode), physics = true, color = currentColor() })
    if inst == nil then return "[SPS HOSE] proof: createHose failed (see log)" end
    say("proofFree: laid %s %.1f m ahead of the camera, %d proof hose(s) live", inst.variant, length, #hv.hoses)
    hv:report(inst)
    return "[SPS HOSE] free hose laid - see log.txt REPORT lines"
end

function SPSHoseProof.consoleClear()
    local hv = g_spsHoseVisual
    local n = 0
    if hv ~= nil then
        n = #hv.hoses
        for i = #hv.hoses, 1, -1 do hv:destroyHose(hv.hoses[i]) end
    end
    for _, node in ipairs(SPSHoseProof.nodes) do if valid(node) then delete(node) end end
    SPSHoseProof.nodes = {}
    return string.format("[SPS HOSE] cleared %d proof hose(s)", n)
end

function SPSHoseProof.consoleLive(_, arg)
    if arg ~= nil then
        local a = string.lower(tostring(arg))
        if a == "on" or a == "1" or a == "true" then SPSHoseVisual.LIVE = true
        elseif a == "off" or a == "0" or a == "false" then SPSHoseVisual.LIVE = false end
    end
    return string.format("[SPS HOSE] live hoses: %s (slurry couplers, chains, sprayer, water/milk lanes; applies to NEW hoses - reconnect / re-lay to see the change)",
        SPSHoseVisual.LIVE and "ON - new physical hoses" or "OFF - old pipes")
end

function SPSHoseProof.consoleReport()
    local hv = g_spsHoseVisual
    if hv == nil then return "[SPS HOSE] no hose visual" end
    for _, inst in ipairs(hv.hoses) do hv:report(inst) end
    return string.format("[SPS HOSE] reported %d hose(s)", #hv.hoses)
end

-- [SPS 1.0.1.8] the spsHoseProof* dev commands were removed from the release build (the functions stay for dev use)
if addConsoleCommand ~= nil then
    addConsoleCommand("spsHoseLive",        "Draw every hose (slurry couplers, chains, sprayer, water/milk lanes) with the new physical hoses: [on|off] (no argument = show)",      "consoleLive",   SPSHoseProof)
end
