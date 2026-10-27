-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.9.25

-- SPSSprayerPipeVisual.lua
-- FS25_SlurryPipeSystem

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSSprayerPipeVisual 1.0.0.9.25 loaded") end

SPSSprayerPipeVisual = {}
SPSSprayerPipeVisual.__index = SPSSprayerPipeVisual

-- [SPS] Debug gate lives in scripts/SPSDebugConfig.lua (channel "SPSSprayerPipeVisual").
-- Hard failure prints (load ERROR, createPipe ERROR) remain unconditional — they
-- signal genuine problems, not trace noise.
local function log(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("SPSSprayerPipeVisual") then return end
    if select("#", ...) > 0 then
        print("[SPS SSPV] " .. string.format(fmt, ...))
    else
        print("[SPS SSPV] " .. tostring(fmt))
    end
end

-- i3d layout (sprayerPipe = pipeRoot, 33 direct children, indices 0-32):
--   child 0      = hose1                 (skinned mesh, Bone1-Bone16 bound)
--   child 1      = hose2                 (skinned mesh, Bone17-Bone32 bound)
--   child 2      = sprayerStartConnector → child 0=sprayerStartTarget, child 1=Bone1
--   child 3      = sprayerEndConnector   → child 0=sprayerEndTarget,   child 1=Bone32
--   child 4..18  = Bone2..Bone16         (direct children of pipeRoot)
--   Bone17       = child 0 of Bone16     (NESTED — not a direct pipeRoot child)
--   child 19..32 = Bone18..Bone31        (direct children of pipeRoot)
--
-- Interior bones driven by bezier: Bone2..Bone31 (30 total).
-- Bone17 must be fetched as getChildAt(Bone16, 0) — not from pipeRoot directly.

SPSSprayerPipeVisual.NUM_INTERIOR_BONES = 29
SPSSprayerPipeVisual.TENSION_FACTOR     = 0.4
SPSSprayerPipeVisual.SAG_FACTOR         = 0.08
-- [SPS 1.0.1.8] Slack model. The hose mesh is 7.58 m long (Bone1 at 0, Bone32 at
-- 7.5826 in sprayerPipe.i3d) but couplers are usually 3-4 m apart, so the skin was
-- squashed to half its rest length everywhere — the "bunched up" hose (William's
-- log 2026-09-28 20:37: span 3.62, arc 3.71, every bone gap 0.12 m vs 0.25 m at
-- rest). A real hose that long droops to the ground and lies there. So: the sag is
-- solved so that the hose's LAID length — the curve with the ground flattening its
-- bow — equals REST_LENGTH, and the bones are spread evenly along that laid shape.
SPSSprayerPipeVisual.REST_LENGTH        = 7.58   -- metres of hose mesh between Bone1 and Bone32
SPSSprayerPipeVisual.LAY_SAMPLES        = 64     -- polyline samples for the laid shape
-- Two knobs take up the surplus (William 2026-09-28, screenshot 20:45: sag alone dug
-- the curve underground and the floor clamp flattened it into a V with sharp corners):
--   sag = just enough droop for the middle to reach the ground (from the couplers'
--         height above it), never more;
--   bow = a smooth SIDEWAYS arc, solved so the laid length equals REST_LENGTH.
-- The hose keeps its length and its shape: down to the ground, round in an arc, up.
-- v4 (William 2026-09-30, log: bow 3.75 m out of a 3.89 m span): the full-length
-- rule swung a loop wider than the gap. The bow is now capped at a third of the
-- span; whatever length that cannot lay is absorbed as mild rib compression
-- (about 1.4x at a 4 m span) instead of a huge sideways arc. The slurry hose never
-- needs any of this: its mesh (~3.75 m) is shorter than its couplers' reach (4 m).
SPSSprayerPipeVisual.MAX_BOW_FACTOR     = 0.35   -- bow never exceeds this * span (v3 was 1.2)
-- v3 (William, screenshot 20:55: "two straight sections then an arc"): the sag is
-- solved so the curve only KISSES the ground — lowest point on the floor, never
-- under it — so the floor clamp has nothing to flatten and the hose is one
-- continuous bend. The sideways bow then takes up all the remaining length.
SPSSprayerPipeVisual.TOUCH_TOLERANCE    = 0.02   -- metres: how close "kissing the ground" must be

-- ---------------------------------------------------------------------------
-- [SPS FLOOR] _stripFloorBitsRec
-- Removes the floor-ray bits (STATIC_OBJECT/TERRAIN/BUILDING/ROAD) from the
-- collisionFilterGroup of every shape inside a freshly loaded pipe i3d, once,
-- at load time. Without this the downward floor ray hits the pipe's OWN
-- kinematic collision capsules (group 0x11004 contains the BUILDING bit),
-- which lifted bones onto themselves and caused a per-frame bounce feedback
-- loop. After stripping, the ray physically cannot see any SPS pipe — only
-- real floors. getCollisionFilterGroup / setCollisionFilterGroup and
-- getHasClassId(node, ClassIds.SHAPE) usage is source-confirmed in vanilla
-- CollisionFlag.lua. VEHICLE / CAMERA_BLOCKING bits are left untouched.
-- ---------------------------------------------------------------------------
function SPSSprayerPipeVisual._stripFloorBitsRec(node)
    if node == nil or node == 0 then return end
    if CollisionFlag == nil or bit32 == nil then return end
    if SPSSprayerPipeVisual._floorStripMask == nil then
        SPSSprayerPipeVisual._floorStripMask = bit32.bnot(
            CollisionFlag.STATIC_OBJECT
            + CollisionFlag.TERRAIN
            + CollisionFlag.BUILDING
            + CollisionFlag.ROAD)
    end
    if getHasClassId(node, ClassIds.SHAPE) then
        local group = getCollisionFilterGroup(node)
        if group ~= nil and group ~= 0 then
            setCollisionFilterGroup(node, bit32.band(group, SPSSprayerPipeVisual._floorStripMask))
        end
    end
    for i = 0, getNumOfChildren(node) - 1 do
        SPSSprayerPipeVisual._stripFloorBitsRec(getChildAt(node, i))
    end
end

-- ---------------------------------------------------------------------------
-- [SPS FLOOR] Static-surface floor support.
-- The terrain heightmap alone cannot see concrete pads, building floors,
-- bridge decks, or roads, so a short downward raycast is combined with the
-- heightmap and the HIGHER of the two becomes the pipe floor.
-- Mask (built lazily from vanilla CollisionFlag, source-confirmed):
--   STATIC_OBJECT (bit 1) + TERRAIN (bit 8) + BUILDING (bit 12) + ROAD (bit 13)
-- The ray starts FLOOR_RAY_UP above the bone and casts straight down for
-- FLOOR_RAY_UP + FLOOR_RAY_DOWN metres. Starting just above the bone is
-- deliberate: a deck high above a pipe running underneath it is never hit,
-- so pipes routed under bridges are not wrongly lifted onto them.
-- Engine call pattern taken from vanilla RaycastUtil.raycastClosest.
-- Falls back to the plain terrain height if CollisionFlag or RaycastUtil
-- are unavailable.
-- NOTE: requires pipe i3d collision shapes to use group 0x10004 (not 0x11004,
-- whose BUILDING bit would let the ray hit the pipe's own components).
-- ---------------------------------------------------------------------------
SPSSprayerPipeVisual.FLOOR_RAY_UP   = 0.5
SPSSprayerPipeVisual.FLOOR_RAY_DOWN = 2.0

-- [SPS FLOOR 1.0.1.8] Floor re-probe window. The per-bone floor cache below is
-- keyed on XZ only, so a floor probed BEFORE a static surface existed in physics
-- (saved hoses are rebuilt during load, before every placeable's collision is
-- in; a concrete pad can also be placed under a parked hose later) was kept for
-- ever and the hose sat sunk in the concrete. For FLOOR_RECHECK_WINDOW ms after
-- a pipe's first update, and again whenever floorEpoch is bumped (any placeable
-- finalising placement), the cache is dropped and the floor re-probed every
-- FLOOR_RECHECK_INTERVAL ms, bypassing the endpoint-pose gate. Cost while the
-- window is open: one raycast per bone per second per hose.
SPSSprayerPipeVisual.FLOOR_RECHECK_WINDOW   = 15000
SPSSprayerPipeVisual.FLOOR_RECHECK_INTERVAL = 1000
SPSSprayerPipeVisual.floorEpoch             = 0

function SPSSprayerPipeVisual.bumpFloorEpoch()
    SPSSprayerPipeVisual.floorEpoch = SPSSprayerPipeVisual.floorEpoch + 1
end

-- Returns true when this update must re-probe the floor (cache already cleared).
function SPSSprayerPipeVisual._floorRecheckDue(inst)
    local now   = g_time or 0
    local epoch = SPSSprayerPipeVisual.floorEpoch
    if inst._floorEpoch ~= epoch then
        inst._floorEpoch        = epoch
        inst._floorRecheckUntil = now + SPSSprayerPipeVisual.FLOOR_RECHECK_WINDOW
        inst._floorNextRecheck  = now
    end
    local untilT = inst._floorRecheckUntil
    if untilT == nil then return false end
    if now >= untilT then
        inst._floorRecheckUntil = nil
        return false
    end
    if now < (inst._floorNextRecheck or 0) then return false end
    inst._floorNextRecheck = now + SPSSprayerPipeVisual.FLOOR_RECHECK_INTERVAL
    inst._floorCache = nil
    return true
end
SPSSprayerPipeVisual._floorRayMask  = nil

function SPSSprayerPipeVisual.getFloorWorldY(px, py, pz, terrainY)
    if SPSSprayerPipeVisual._floorRayMask == nil then
        if CollisionFlag ~= nil and RaycastUtil ~= nil
        and CollisionFlag.STATIC_OBJECT ~= nil and CollisionFlag.TERRAIN ~= nil
        and CollisionFlag.BUILDING ~= nil and CollisionFlag.ROAD ~= nil then
            SPSSprayerPipeVisual._floorRayMask = CollisionFlag.STATIC_OBJECT
                + CollisionFlag.TERRAIN
                + CollisionFlag.BUILDING
                + CollisionFlag.ROAD
        else
            return terrainY
        end
    end
    local hitId, _, hitY, _ = RaycastUtil.raycastClosest(
        px, py + SPSSprayerPipeVisual.FLOOR_RAY_UP, pz,
        0, -1, 0,
        SPSSprayerPipeVisual.FLOOR_RAY_UP + SPSSprayerPipeVisual.FLOOR_RAY_DOWN,
        SPSSprayerPipeVisual._floorRayMask)
    if hitId ~= nil and hitId ~= 0 and hitY ~= nil and hitY > terrainY then
        return hitY
    end
    return terrainY
end

function SPSSprayerPipeVisual.new(modDirectory)
    local self = setmetatable({}, SPSSprayerPipeVisual)
    self.modDirectory = modDirectory
    self._isLoaded    = false
    return self
end

function SPSSprayerPipeVisual:load()
    local pipePath = self.modDirectory .. "i3d/pipes/sprayerPipe.i3d"
    if fileExists(pipePath) then
        self._isLoaded = true
        log("load: OK %s", pipePath)
    else
        -- [SPS 1.0.1.8] the old bezier sprayer pipe mesh was RETIRED on 2026-10-18 (parked in i3d/newPipe)
        spsInfo("[SPS SSPV] load: old bezier sprayer pipe mesh absent (retired) - new hoses only")
    end
end

function SPSSprayerPipeVisual:delete()
    self._isLoaded = false
end

-- [SPS 1.0.1.9] also ready when the new hoses can draw (old sprayerPipe.i3d gone since 1.0.1.8): SPSM_Sprayers and
-- SPSM_LiquidLanes gate on this, so sprayer + water/milk lane hoses were never drawn in ORIGINAL mode
function SPSSprayerPipeVisual:isReady()
    return self._isLoaded or (SPSHoseVisual ~= nil and SPSHoseVisual.LIVE and g_spsHoseVisual ~= nil and g_spsHoseVisual:isReady())
end

-- ---------------------------------------------------------------------------
-- createPipe
-- nodeA: source coupler mountNode  — pipeRoot snaps here.
-- nodeB: destination coupler mountNode — endConnectors snaps here.
-- ---------------------------------------------------------------------------
function SPSSprayerPipeVisual:createPipe(nodeA, nodeB, fluid)
    -- [SPS HOSE step 4] new physical hose (WATER / MILK) when the live switch is on; the
    -- instance carries isHose so updatePipe/destroyPipe below delegate to the hose class.
    if SPSHoseVisual ~= nil and SPSHoseVisual.LIVE and g_spsHoseVisual ~= nil and g_spsHoseVisual:isReady() then
        local inst = g_spsHoseVisual:createLaneHose(nodeA, nodeB, fluid)
        if inst ~= nil then return inst end
        print("[SPS HOSE] OLD sprayer pipe used: createLaneHose failed (see the [SPS HOSE] error above)")
    elseif SPSHoseVisual ~= nil and not SPSHoseVisual.LIVE then
        print("[SPS HOSE] OLD sprayer pipe used for a " .. tostring(fluid or "water") .. " lane connection: spsHoseLive is OFF")
    end
    if not self._isLoaded then
        print("[SPS SSPV] createPipe: ERROR not loaded")
        return nil
    end

    local pipePath = self.modDirectory .. "i3d/pipes/sprayerPipe.i3d"
    local i3dRoot = loadI3DFile(pipePath)
    if i3dRoot == nil or i3dRoot == 0 then
        print("[SPS SSPV] createPipe: ERROR loadI3DFile failed")
        return nil
    end
    -- [SPS FLOOR] make this pipe invisible to the floor ray (see _stripFloorBitsRec)
    SPSSprayerPipeVisual._stripFloorBitsRec(i3dRoot)
    link(getRootNode(), i3dRoot)

    local pipeRoot = getChildAt(i3dRoot, 0)
    if pipeRoot == nil or pipeRoot == 0 then
        print("[SPS SSPV] createPipe: ERROR pipeRoot not found")
        delete(i3dRoot)
        return nil
    end

    local startConnectors = getChildAt(pipeRoot, 2)
    local endConnectors   = getChildAt(pipeRoot, 3)
    if startConnectors == nil or startConnectors == 0
    or endConnectors   == nil or endConnectors   == 0 then
        print("[SPS SSPV] createPipe: ERROR connector nodes not found")
        delete(i3dRoot)
        return nil
    end

    -- Bone1 and Bone32 are the bezier endpoints — they follow their parent
    -- connectors and their world positions are read after the parent snaps.
    local bone1  = getChildAt(startConnectors, 1)
    local bone32 = getChildAt(endConnectors, 1)
    if bone1 == nil or bone1 == 0 or bone32 == nil or bone32 == 0 then
        print("[SPS SSPV] createPipe: ERROR Bone1 or Bone32 not found")
        delete(i3dRoot)
        return nil
    end

    -- Interior bones driven by bezier:
    -- Bone2..Bone16 at pipeRoot children 4..18 (15 bones)
    -- Bone18..Bone31 at pipeRoot children 19..32 (14 bones)
    -- Bone17 is a child of Bone16 and moves with it automatically — not driven here.
    local bones = {}
    for i = 1, 15 do
        local boneNode = getChildAt(pipeRoot, 3 + i)  -- children 4..18
        if boneNode == nil or boneNode == 0 then
            print("[SPS SSPV] createPipe: ERROR Bone" .. (i + 1) .. " not found at pipeRoot child " .. (3 + i))
            delete(i3dRoot)
            return nil
        end
        bones[i] = boneNode
    end
    for i = 1, 14 do
        local boneNode = getChildAt(pipeRoot, 18 + i)  -- children 19..32
        if boneNode == nil or boneNode == 0 then
            print("[SPS SSPV] createPipe: ERROR Bone" .. (17 + i) .. " not found at pipeRoot child " .. (18 + i))
            delete(i3dRoot)
            return nil
        end
        bones[15 + i] = boneNode  -- slots 16..29
    end

    local inst = {
        i3dRoot         = i3dRoot,
        pipeRoot        = pipeRoot,
        startConnectors = startConnectors,
        endConnectors   = endConnectors,
        bone1           = bone1,
        bone32          = bone32,
        bones           = bones,
        nodeA           = nodeA,
        nodeB           = nodeB,
    }

    -- Link pipeRoot to nodeA in local space — pipe start follows source coupler.
    link(nodeA, pipeRoot)
    setTranslation(pipeRoot, 0, 0, 0)
    setRotation(pipeRoot, 0, 0, 0)

    -- Link endConnectors to nodeB using sprayerEndTarget (child 0) as the snap point.
    -- sprayerEndTarget is the physical connection tip — offset endConnectors so it
    -- lands at nodeB, not the endConnectors origin.
    local sprayerEndTarget = getChildAt(endConnectors, 0)
    local etx, ety, etz   = getTranslation(sprayerEndTarget)
    link(nodeB, endConnectors)
    setTranslation(endConnectors, -etx, -ety, -etz)
    setRotation(endConnectors, 0, 0, 0)

    self:updatePipe(inst)
    log("createPipe: OK nodeA=%s nodeB=%s", tostring(nodeA), tostring(nodeB))
    return inst
end

-- ---------------------------------------------------------------------------
-- updatePipe
-- Called every tick. pipeRoot and endConnectors are linked to their
-- respective nodes in local space (done in createPipe) so they follow
-- automatically. Only the bezier bones need updating each tick.
-- ---------------------------------------------------------------------------
function SPSSprayerPipeVisual:updatePipe(inst)
    if inst == nil then return end
    if inst.isHose then
        if g_spsHoseVisual ~= nil then g_spsHoseVisual:updateHose(inst, false) end
        return
    end

    local nodeA = inst.nodeA
    local nodeB = inst.nodeB
    if nodeA == nil or nodeB == nil then return end
    if not entityExists(nodeA) or not entityExists(nodeB) then return end

    local ax, ay, az    = getWorldTranslation(nodeA)
    local bx, by, bz    = getWorldTranslation(nodeB)
    local arx, ary, arz = getWorldRotation(nodeA)
    local brx, bry, brz = getWorldRotation(nodeB)

    if ax == nil or bx == nil or arx == nil or brx == nil then return end

    -- [SPS PERF] Reshape only when an endpoint actually moved — same gate as
    -- SPSPipeVisual:updatePipe. Everything below is a pure function of the two
    -- endpoint poses, so a hose whose ends are both still is skipped entirely.
    -- Thresholds: 1 mm position, ~0.06° rotation (1e-3 rad).
    local floorRecheck = SPSSprayerPipeVisual._floorRecheckDue(inst)
    local lp = inst._lastPose
    if lp ~= nil then
        local d1x, d1y, d1z = ax - lp[1], ay - lp[2], az - lp[3]
        local d2x, d2y, d2z = bx - lp[4], by - lp[5], bz - lp[6]
        local r1x, r1y, r1z = arx - lp[7], ary - lp[8], arz - lp[9]
        local r2x, r2y, r2z = brx - lp[10], bry - lp[11], brz - lp[12]
        if  d1x*d1x + d1y*d1y + d1z*d1z < 1e-6
        and d2x*d2x + d2y*d2y + d2z*d2z < 1e-6
        and r1x*r1x + r1y*r1y + r1z*r1z < 1e-6
        and r2x*r2x + r2y*r2y + r2z*r2z < 1e-6
        and not floorRecheck then
            return
        end
        lp[1], lp[2], lp[3], lp[4],  lp[5],  lp[6]  = ax,  ay,  az,  bx,  by,  bz
        lp[7], lp[8], lp[9], lp[10], lp[11], lp[12] = arx, ary, arz, brx, bry, brz
    else
        inst._lastPose = { ax, ay, az, bx, by, bz, arx, ary, arz, brx, bry, brz }
    end

    -- Read Bone1 and Bone32 world positions — these are the true bezier
    -- endpoints and match the skin bind positions exactly.
    if not entityExists(inst.bone1) or not entityExists(inst.bone32) then return end
    local p0x, p0y, p0z = getWorldTranslation(inst.bone1)
    local p3x, p3y, p3z = getWorldTranslation(inst.bone32)

    local dx   = p3x - p0x
    local dy   = p3y - p0y
    local dz   = p3z - p0z
    local span = math.sqrt(dx*dx + dy*dy + dz*dz)
    if span < 0.001 then return end

    local adx, ady, adz = localDirectionToWorld(nodeA, 0, 0, 1)
    local bdx, bdy, bdz = localDirectionToWorld(nodeB, 0, 0, 1)

    local tension = span * SPSSprayerPipeVisual.TENSION_FACTOR
    local baseSag = span * SPSSprayerPipeVisual.SAG_FACTOR
    local p1xBase, p1yBase, p1zBase = p0x + adx * tension, p0y + ady * tension, p0z + adz * tension
    local p2xBase, p2yBase, p2zBase = p3x - bdx * tension, p3y - bdy * tension, p3z - bdz * tension

    local terrainRoot = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    local floorLift   = SPSSprayerPipeVisual.SAG_FACTOR
    local S           = SPSSprayerPipeVisual.LAY_SAMPLES
    local poly = inst._poly
    if poly == nil then poly = { x = {}, y = {}, z = {}, c = {} }; inst._poly = poly end

    -- Sideways direction for the bow: horizontal, perpendicular to A->B. Its sign is
    -- chosen once per hose (the side the two couplers' out directions lean to, else
    -- +), so the arc never flips from frame to frame.
    local hx, hz = dx, dz
    local hlen = math.sqrt(hx*hx + hz*hz)
    if hlen < 0.001 then hx, hz, hlen = 1, 0, 1 end
    hx, hz = hx / hlen, hz / hlen
    local sx, sz = -hz, hx                      -- up x forward
    if inst._bowSign == nil then
        local lean = (adx * sx + adz * sz) - (bdx * sx + bdz * sz)
        inst._bowSign = (lean < 0) and -1 or 1
    end
    sx, sz = sx * inst._bowSign, sz * inst._bowSign

    -- Shape for a given sag + bow: bezier samples, each lifted to the terrain
    -- (cheap heightmap query; the exact floor incl. pads is applied per bone
    -- below). Fills poly; returns the laid length and the lowest clearance of the
    -- UNCLAMPED curve above the terrain (negative = it went under).
    local function layShape(sagV, bowV)
        local p1x, p1y, p1z = p1xBase + sx * bowV, p1yBase - sagV, p1zBase + sz * bowV
        local p2x, p2y, p2z = p2xBase + sx * bowV, p2yBase - sagV, p2zBase + sz * bowV
        local lx, ly, lz = p0x, p0y, p0z
        poly.x[0], poly.y[0], poly.z[0], poly.c[0] = p0x, p0y, p0z, 0
        local total, minClear = 0, math.huge
        for k = 1, S do
            local t   = k / S
            local mt  = 1 - t
            local mt2 = mt * mt
            local t2  = t * t
            local a, b, c, d = mt2 * mt, 3 * mt2 * t, 3 * mt * t2, t2 * t
            local x = a*p0x + b*p1x + c*p2x + d*p3x
            local y = a*p0y + b*p1y + c*p2y + d*p3y
            local z = a*p0z + b*p1z + c*p2z + d*p3z
            if terrainRoot ~= nil and k < S then
                local ty = getTerrainHeightAtWorldPos(terrainRoot, x, 0, z) + floorLift
                local clear = y - ty
                if clear < minClear then minClear = clear end
                if y < ty then y = ty end
            end
            local ddx, ddy, ddz = x - lx, y - ly, z - lz
            total = total + math.sqrt(ddx*ddx + ddy*ddy + ddz*ddz)
            poly.x[k], poly.y[k], poly.z[k], poly.c[k] = x, y, z, total
            lx, ly, lz = x, y, z
        end
        if minClear == math.huge then minClear = 0 end
        return total, minClear
    end

    local TOL = SPSSprayerPipeVisual.TOUCH_TOLERANCE
    -- Sag that makes the curve just touch the ground for this bow: the largest sag
    -- whose lowest point is still on or above the floor (bisection; clearance falls
    -- as sag grows). Base sag if that already reaches the floor.
    local function solveSagTouch(bowV)
        local _, clear = layShape(baseSag, bowV)
        if clear <= TOL then return baseSag end
        local lo, hi = baseSag, baseSag + clear * 1.5 + 0.5
        local _, clearHi = layShape(hi, bowV)
        local guard = 0
        while clearHi > 0 and guard < 6 do
            hi = hi * 2; _, clearHi = layShape(hi, bowV); guard = guard + 1
        end
        if clearHi > 0 then return hi end
        for _ = 1, 12 do
            local mid = 0.5 * (lo + hi)
            local _, c = layShape(mid, bowV)
            if c > TOL then lo = mid else hi = mid end
            if hi - lo < 0.005 then break end
        end
        return lo
    end
    -- Bow that makes the laid length reach REST_LENGTH for this sag (bisection;
    -- laid length grows with bow). 0 when the hose is already long enough.
    local REST = SPSSprayerPipeVisual.REST_LENGTH
    local function solveBow(sagV)
        local laid0 = layShape(sagV, 0)
        if laid0 >= REST then return 0 end
        local lo, hi = 0, span * SPSSprayerPipeVisual.MAX_BOW_FACTOR
        if layShape(sagV, hi) <= REST then return hi end
        for _ = 1, 14 do
            local mid = 0.5 * (lo + hi)
            if layShape(sagV, mid) < REST then lo = mid else hi = mid end
        end
        return hi
    end

    -- Sag and bow interact (the bow moves the low point sideways), so alternate
    -- twice: touch → length → touch → length.
    local sag = solveSagTouch(0)
    local bow = solveBow(sag)
    sag = solveSagTouch(bow)
    bow = solveBow(sag)
    local laid = layShape(sag, bow)
    inst._laidLength = laid
    inst._sag        = sag
    inst._bow        = bow

    -- Place the bones at equal laid distances; tangent from the polyline segment.
    local NUM   = SPSSprayerPipeVisual.NUM_INTERIOR_BONES
    local TOTAL = NUM + 1
    local seg = 1
    for i = 1, NUM do
        local target = laid * i / TOTAL
        while seg < S and poly.c[seg] < target do seg = seg + 1 end
        local c0, c1 = poly.c[seg - 1], poly.c[seg]
        local f = (c1 > c0) and ((target - c0) / (c1 - c0)) or 0
        local px = poly.x[seg - 1] + (poly.x[seg] - poly.x[seg - 1]) * f
        local py = poly.y[seg - 1] + (poly.y[seg] - poly.y[seg - 1]) * f
        local pz = poly.z[seg - 1] + (poly.z[seg] - poly.z[seg - 1]) * f
        local tdx = poly.x[seg] - poly.x[seg - 1]
        local tdy = poly.y[seg] - poly.y[seg - 1]
        local tdz = poly.z[seg] - poly.z[seg - 1]
        local tlen = math.sqrt(tdx*tdx + tdy*tdy + tdz*tdz)
        if tlen > 0.0001 then
            tdx = tdx / tlen
            tdy = tdy / tlen
            tdz = tdz / tlen
        end

        -- Exact floor clamp per bone (terrain + concrete pads / bridges / roads),
        -- cached per bone XZ as before.
        if terrainRoot ~= nil then
            local fc = inst._floorCache
            if fc == nil then
                fc = {}
                inst._floorCache = fc
            end
            local c  = fc[i]
            local ty
            if c ~= nil then
                local cdx, cdz = px - c[1], pz - c[2]
                if cdx*cdx + cdz*cdz < 0.0625 then
                    ty = c[3]
                end
            end
            if ty == nil then
                ty = getTerrainHeightAtWorldPos(terrainRoot, px, 0, pz)
                -- [SPS FLOOR] also rest on static surfaces (concrete/buildings/bridges/roads)
                ty = SPSSprayerPipeVisual.getFloorWorldY(px, py, pz, ty)
                if c == nil then
                    fc[i] = { px, pz, ty }
                else
                    c[1], c[2], c[3] = px, pz, ty
                end
            end
            local minY = ty + floorLift
            if py < minY then
                py = minY
            end
        end

        local ry = math.atan2(tdx, tdz)
        local rx = -math.atan2(tdy, math.sqrt(tdx*tdx + tdz*tdz))

        setWorldTranslation(inst.bones[i], px, py, pz)
        setWorldRotation(inst.bones[i], rx, ry, 0)
    end

    -- [SPS 1.0.1.8] Shape diagnostic (channel SPSSprayerPipeVisual): answers ONE
    -- question — are the bones evenly spaced along the hose, and do the two end
    -- directions point along the hose? Printed for the first 3 reshapes of a pipe.
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSSprayerPipeVisual") then
        inst._diagCount = (inst._diagCount or 0) + 1
        if inst._diagCount <= 3 then
            local ux, uy, uz = dx / span, dy / span, dz / span
            local dotA = adx*ux + ady*uy + adz*uz
            local dotB = bdx*ux + bdy*uy + bdz*uz
            local segs = {}
            local lx, ly, lz = p0x, p0y, p0z
            local minS, maxS, sum = math.huge, 0, 0
            for i = 1, NUM do
                local wx, wy, wz = getWorldTranslation(inst.bones[i])
                local d = math.sqrt((wx-lx)^2 + (wy-ly)^2 + (wz-lz)^2)
                segs[#segs+1] = string.format("%.2f", d)
                if d < minS then minS = d end
                if d > maxS then maxS = d end
                sum = sum + d
                lx, ly, lz = wx, wy, wz
            end
            local dEnd = math.sqrt((p3x-lx)^2 + (p3y-ly)^2 + (p3z-lz)^2)
            segs[#segs+1] = string.format("%.2f", dEnd)
            sum = sum + dEnd
            print(string.format("[SPS SSPV] shape #%d: span=%.2f laid=%.2f sag=%.2f bow=%.2f rest=%.2f tanA.AB=%.2f tanB.AB=%.2f (expect +1 / +1) bone gaps min=%.2f max=%.2f mean=%.2f",
                inst._diagCount, span, inst._laidLength or 0, inst._sag or 0, inst._bow or 0, SPSSprayerPipeVisual.REST_LENGTH, dotA, dotB, minS, maxS, sum / (NUM + 1)))
            print("[SPS SSPV] gaps Bone1->…->Bone32: " .. table.concat(segs, " "))
        end
    end
end

-- ---------------------------------------------------------------------------
-- destroyPipe
-- ---------------------------------------------------------------------------
function SPSSprayerPipeVisual:destroyPipe(inst)
    if inst == nil then return end
    if inst.isHose then
        if g_spsHoseVisual ~= nil then g_spsHoseVisual:destroyHose(inst) end
        return
    end
    log("destroyPipe: tearing down instance")

    -- During savegame quit/delete, FS25 may already have deleted linked parent
    -- nodes. Never link/delete a node unless the entity still exists.
    local i3dRootExists = inst.i3dRoot ~= nil and inst.i3dRoot ~= 0 and entityExists(inst.i3dRoot)

    if inst.pipeRoot ~= nil and inst.pipeRoot ~= 0 and entityExists(inst.pipeRoot) then
        link(getRootNode(), inst.pipeRoot)
    end

    if inst.endConnectors ~= nil and inst.endConnectors ~= 0 and entityExists(inst.endConnectors) then
        link(getRootNode(), inst.endConnectors)
    end

    if i3dRootExists then
        delete(inst.i3dRoot)
    end

    inst.i3dRoot = nil
    inst.pipeRoot = nil
    inst.startConnectors = nil
    inst.endConnectors = nil
    inst._lastPose = nil
    inst._floorCache = nil
    inst._floorRecheckUntil = nil
    inst.bone1 = nil
    inst.bone32 = nil
    inst.bones = nil
end