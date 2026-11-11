-- ===========================================================================
-- FS25_SlurryPipeSystem - SPSLeakEffect.lua
-- [SPS 1.0.2.0] LEAK STREAMS (William 2026-11-02: "a pipe effect on every coupler that will look like the valve is
-- open and a stream of poo is coming out ... onto the place of the puddle"). CLIENT-side visual only.
--
-- ONE shared i3d (i3d/effects/spsLeakStream.i3d = the base-game pipe effect tube lifted from the Profi2 nodeTree)
-- is loaded once. For every coupler / pipe end that is leaking RIGHT NOW (SPSM_Leaks updateLeakStreams decides,
-- from the synced valve / plug state every peer already has) a clone is created lazily under its own world-upright
-- group, driven as a vanilla PipeEffect (the PIPE_EFFECT shader stretches the tube to the distance set each frame:
-- leak node down to the surface the puddle sits on). The material is the mod's slurry / water / milk pipe material.
-- When the leak stops the effect fades out and the clone is deleted - idle couplers carry NOTHING. Nothing is baked
-- into any vehicle or placeable i3d (William's option 1, not option 2).
--
-- API (SPSM_Leaks): beginFrame(); set(key, owner, node, nodeY, surfaceY, fillType) per leaking point; endFrame().
-- Debug: SPSDebugConfig channel "SPSM_Leaks".
-- ===========================================================================
SPSLeakEffect = {}
SPSLeakEffect.I3D            = "i3d/effects/spsLeakStream.i3d"
SPSLeakEffect.MIN_DISTANCE   = 0.05     -- m: shorter than this = nothing to draw
SPSLeakEffect.EXTRA_DISTANCE = 0.1      -- m: the tube reaches a little into the puddle decal
SPSLeakEffect.INSET          = 0.08     -- m: fallback start inset when no frame is given (SPSM_Leaks owns the real one)
SPSLeakEffect.FADE_IN_MS     = 600
SPSLeakEffect.FADE_OUT_MS    = 900
SPSLeakEffect.SHAPE_SCALE    = 0.6      -- default x/y scale of the 0.22 m tube (leakStreamFrame hands the bore's in)
-- Geometry (William 2026-11-03): the tube leaves ALONG the socket axis and gravity bends it so its END points straight
-- down. PIPE_EFFECT shader: local +Z = tube, controlPoint.x = length, controlPoint.y = bend (rad) toward local -Y,
-- lerped along the tube. The group's +Z is the flow axis, +Y = up-in-plane; bend and length come from
-- SlurryPipeManager.leakStreamSolve (the end TANGENT, not the end rotation, is what must be vertical - a 90 degree
-- bend on a level socket hooks back under itself). The puddle sits where the stream lands (physFreeEndSpillPos).
-- No flare at the end (shapeScaleSpread.z = 0).

SPSLeakEffect.active   = {}   -- key -> { root, shape, pe, fillType, seen, stopping }
SPSLeakEffect._proto   = nil  -- the loaded "spsLeakStream" group (hidden template under the root node)
SPSLeakEffect._loading = false
SPSLeakEffect._failed  = false
SPSLeakEffect.MOD_DIR  = g_currentModDirectory   -- captured at load (only valid while the mod's files load)
SPSLeakEffect._streamsCreated = 0

local function dbg(fmt, ...)
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn ~= nil and SPSDebugConfig.isOn("SPSM_Leaks") then
        print("[SPS LEAK] " .. string.format(fmt, ...))
    end
end

local function nodeOk(n) return n ~= nil and n ~= 0 and entityExists(n) end

-- the mod's pipe material for a liquid: SlurryPipeManager.pipeEffectMaterialFor (SPSM_Leaks.lua, loaded after the manager)
local function materialFor(fillType)
    if SlurryPipeManager ~= nil and SlurryPipeManager.pipeEffectMaterialFor ~= nil then
        return SlurryPipeManager.pipeEffectMaterialFor(fillType)
    end
    return g_spsSlurryMaterial
end

-- ---------------------------------------------------------------------------
-- shared template
-- ---------------------------------------------------------------------------
function SPSLeakEffect.ensureLoaded()
    if SPSLeakEffect._proto ~= nil or SPSLeakEffect._loading or SPSLeakEffect._failed then return end
    local dir = SPSLeakEffect.MOD_DIR or SPS_MOD_DIRECTORY
    if g_i3DManager == nil or dir == nil then
        print("[SPS LEAK] WARNING: no i3d manager / mod directory - leak streams have no visual")
        SPSLeakEffect._failed = true
        return
    end
    local file = dir .. SPSLeakEffect.I3D
    if not fileExists(file) then
        print("[SPS LEAK] WARNING: " .. tostring(file) .. " not found - leak streams have no visual")
        SPSLeakEffect._failed = true
        return
    end
    SPSLeakEffect._loading = true
    g_i3DManager:loadSharedI3DFileAsync(file, false, false, SPSLeakEffect.onLoaded, SPSLeakEffect, nil)
end

function SPSLeakEffect:onLoaded(i3dNode, failedReason, args)
    SPSLeakEffect._loading = false
    if i3dNode == nil or i3dNode == 0 then
        print("[SPS LEAK] WARNING: could not load " .. tostring(SPSLeakEffect.I3D) .. " (reason " .. tostring(failedReason) .. ") - leak streams have no visual")
        SPSLeakEffect._failed = true
        return
    end
    local proto = getChildAt(i3dNode, 0)
    if proto == nil or proto == 0 then delete(i3dNode); SPSLeakEffect._failed = true; return end
    link(getRootNode(), proto)
    delete(i3dNode)
    setVisibility(proto, false)
    setName(proto, "spsLeakStreamProto")
    SPSLeakEffect._proto = proto
    print("[SPS LEAK] leak stream template loaded (" .. tostring(SPSLeakEffect.I3D) .. ")")   -- once per map
end

-- ---------------------------------------------------------------------------
-- one stream
-- ---------------------------------------------------------------------------
local function registerClasses()
    if g_effectManager:getEffectClass("PipeEffect") == nil and PipeEffect ~= nil then
        g_effectManager:registerEffectClass("PipeEffect", PipeEffect)
    end
    if g_effectManager:getEffectClass("ShaderPlaneEffect") == nil and ShaderPlaneEffect ~= nil then
        g_effectManager:registerEffectClass("ShaderPlaneEffect", ShaderPlaneEffect)
    end
end

local function createStream(key, owner, fillType, scale)
    if SPSLeakEffect._proto == nil or PipeEffect == nil or g_effectManager == nil then return nil end
    registerClasses()
    local root = clone(SPSLeakEffect._proto, false, false, false)
    if root == nil or root == 0 then return nil end
    link(getRootNode(), root)
    setName(root, "spsLeakStream")
    setRotation(root, 0, 0, 0)
    setVisibility(root, true)
    local shape = getChildAt(root, 0)   -- pipeEffect shape: its +Z is the tube; the GROUP is aimed along the flow axis
    if shape == nil or shape == 0 then delete(root); return nil end
    setRotation(shape, 0, 0, 0)         -- (the i3d carries the fill-arm's -90 0 180; not wanted here)
    scale = scale or SPSLeakEffect.SHAPE_SCALE
    -- same manual build as SlurryPipeManager buildSpsPipeEffectSet (no XML schema needed); straight down: maxBending 0
    local pe = PipeEffect.new()
    pe.parent            = owner
    pe.baseDirectory     = owner ~= nil and owner.baseDirectory or ""
    pe.rootNodes         = root
    pe.node              = shape
    pe.maxBending        = 0
    pe.extraDistance     = SPSLeakEffect.EXTRA_DISTANCE
    pe.updateDistance    = true
    pe.distance          = 0
    pe.controlPointY     = 0
    pe.worldTarget       = { 0, 0, 0 }
    pe.controlPoint      = { 10, 0, 0, 0 }
    pe.shapeScaleSpread  = { scale, scale, 0, 0 }   -- bore-sized, no spread at the end
    pe.uvScaleSpeedFreqAmp = nil
    pe.positionUpdateNodes = nil
    pe.materialType      = "spsSlurryPipe"
    pe.materialTypeId    = 1
    pe.dynamicFillType   = false
    pe.hasValidMaterial  = false
    pe.lastFillTypeIndex = nil
    pe.fadeInTime        = SPSLeakEffect.FADE_IN_MS
    pe.fadeOutTime       = SPSLeakEffect.FADE_OUT_MS
    pe.startDelay        = 0
    pe.stopDelay         = 0
    pe.currentDelay      = 0
    pe.state             = ShaderPlaneEffect.STATE_OFF
    pe.planeFadeTime     = 0
    pe.fadeCur = { -1, 1 }
    pe.fadeDir = { 1, 1 }
    pe.fadeX   = { -1, 1 }
    pe.fadeY   = { -1, 1 }
    pe.alwaysVisibile    = false
    pe.showOnFirstUse    = false
    pe.prio              = 0
    pe.deleteListeners   = {}
    pe.startRestriction  = {}
    pe.allowUpdate       = true
    pe.lastUpdateTime    = 0
    setVisibility(shape, false)
    g_effectManager:setUpdateDistance({ pe }, math.huge)
    local mat = materialFor(fillType)
    if mat ~= nil then
        setMaterial(shape, mat, 0)
        pe.hasValidMaterial = true
        pe.useBaseMaterial  = true
    end
    g_effectManager:setEffectTypeInfo({ pe }, fillType or FillType.LIQUIDMANURE)   -- writes shapeScaleSpread / controlPoint
    g_effectManager:startEffects({ pe })
    local e = { key = key, root = root, shape = shape, pe = pe, fillType = fillType, seen = true, stopping = false, scale = scale }
    SPSLeakEffect.active[key] = e
    SPSLeakEffect._streamsCreated = SPSLeakEffect._streamsCreated + 1
    local msg = string.format("stream created for %s (%s) material=%s", tostring(key),
        tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType) or fillType), tostring(mat ~= nil))
    if SPSLeakEffect._streamsCreated <= 3 then print("[SPS LEAK] " .. msg) else dbg("%s", msg) end   -- first three always
    return e
end

local function destroyStream(e, why)
    if e == nil then return end
    if e.pe ~= nil and g_effectManager ~= nil then g_effectManager:deleteEffects({ e.pe }) end   -- Effect:delete frees no node
    if nodeOk(e.root) then delete(e.root) end
    SPSLeakEffect.active[e.key] = nil
    dbg("stream removed for %s (%s)", tostring(e.key), tostring(why))
end

-- ---------------------------------------------------------------------------
-- per frame protocol
-- ---------------------------------------------------------------------------
function SPSLeakEffect.beginFrame()
    for _, e in pairs(SPSLeakEffect.active) do e.seen = false end
end

-- A point is leaking this frame: node = the socket / pipe end, nodeY its height, surfaceY the puddle surface under it,
-- frame = { dx, dy, dz, scale } from SlurryPipeManager:leakStreamFrame (outward flow axis, tube scale); nil = straight down.
function SPSLeakEffect.set(key, owner, node, nodeY, surfaceY, fillType, frame)
    if g_client == nil or key == nil or not nodeOk(node) then return end
    SPSLeakEffect.ensureLoaded()
    local e = SPSLeakEffect.active[key]
    if e == nil then
        e = createStream(key, owner, fillType, frame ~= nil and frame.scale or nil)
        if e == nil then
            if SPSLeakEffect._proto ~= nil and not SPSLeakEffect._createWarned then
                SPSLeakEffect._createWarned = true
                print("[SPS LEAK] WARNING: stream could not be created (PipeEffect=" .. tostring(PipeEffect ~= nil)
                    .. " effectManager=" .. tostring(g_effectManager ~= nil) .. ")")
            end
            return
        end
    end
    e.seen = true
    if e.stopping then   -- leaking again before the fade-out finished
        e.stopping = false
        g_effectManager:startEffects({ e.pe })
    end
    if fillType ~= nil and fillType ~= e.fillType then
        local mat = materialFor(fillType)
        if mat ~= nil and nodeOk(e.shape) then setMaterial(e.shape, mat, 0) end
        e.fillType = fillType
    end
    if not nodeOk(e.root) then destroyStream(e, "root gone"); return end
    local x, y, z = getWorldTranslation(node)
    local dx, dy, dz = 0, -1, 0
    local sx, sy, sz = x, y, z
    if frame ~= nil and frame.dx ~= nil then
        dx, dy, dz = frame.dx, frame.dy, frame.dz
        if frame.sx ~= nil then sx, sy, sz = frame.sx, frame.sy, frame.sz end   -- the START (leakStreamFrame)
    else
        sy = sy - SPSLeakEffect.INSET
    end
    -- the group: at the start, +Z along the flow axis, +Y = up-in-plane
    setTranslation(e.root, sx, sy, sz)
    local ux, uy, uz = 0, 1, 0
    if math.abs(dy) > 0.98 then ux, uy, uz = 0, 0, 1 end   -- vertical socket: any horizontal "up" will do
    setDirection(e.root, dx, dy, dz, ux, uy, uz)
    local h = sy - (surfaceY or sy)
    if h > SPSLeakEffect.MIN_DISTANCE then
        -- bend so the END points straight down and the length lands it on the surface (SPSM_Leaks leakStreamSolve)
        local bend, len = 0, h
        if SlurryPipeManager ~= nil and SlurryPipeManager.leakStreamSolve ~= nil then
            bend, len = SlurryPipeManager.leakStreamSolve(dy, h)
        end
        len = len + SPSLeakEffect.EXTRA_DISTANCE
        e.pe.distance, e.pe.controlPointY = len, bend
        setShaderParameter(e.shape, "controlPoint", len - PipeEffect.SAFETY_OFFSET, bend, 0, 0, false)
    else
        e.pe.distance = 0
        setShaderParameter(e.shape, "controlPoint", 0.001, 0, 0, 0, false)   -- the fade state owns visibility
    end
end

function SPSLeakEffect.endFrame()
    for key, e in pairs(SPSLeakEffect.active) do
        if not e.seen and not e.stopping then
            e.stopping = true
            g_effectManager:stopEffects({ e.pe })
        elseif e.stopping and (e.pe.state == ShaderPlaneEffect.STATE_OFF) then
            destroyStream(e, "faded out")
        end
    end
end

function SPSLeakEffect.removeAll()
    for _, e in pairs(SPSLeakEffect.active) do
        if e.pe ~= nil and g_effectManager ~= nil then g_effectManager:deleteEffects({ e.pe }) end
        if nodeOk(e.root) then delete(e.root) end
    end
    SPSLeakEffect.active = {}
    if nodeOk(SPSLeakEffect._proto) then delete(SPSLeakEffect._proto) end
    SPSLeakEffect._proto, SPSLeakEffect._loading, SPSLeakEffect._failed = nil, false, false
end
