-- ===========================================================================
-- FS25_SlurryPipeSystem - SPSSpill.lua
-- [SPS 1.0.2.0] LEAK PUDDLES (William 2026-11-02): with the "Pipe leakage" setting on, a tanker whose physical
-- pipe ends free on the ground empties through its open valve (SPSM_PhysPipes physFreeEndSpillPos, SPSM_Flow
-- GROUND_SPILL sink). The litres that run out land here and become a puddle on the terrain under the pipe end.
--
--   * SERVER owns the list: addLitres() finds the puddle within MERGE_RADIUS of the spot (else creates one; the
--     oldest goes when MAX_PUDDLES is reached) and grows it. Every GROW_STEP litres (and on create / remove) one
--     SPSSpillPuddleEvent goes to the clients. A puddle that has not been fed for DRY_AFTER_MS shrinks and vanishes.
--   * CLIENTS (and the listen server) mirror the list visually: the base game's decal puddle
--     ($data/maps/mapEU/textures/props/puddles/smallPuddle.i3d, puddleShader) is loaded once (shared i3d), one
--     instance per puddle, tinted via the shader's waterColor / waterOpacity by LIQUID (slurry brown, water clear,
--     milk white - the TYPES table), scaled by litres, laid on the surface under the leak (terrain or a building's
--     concrete). Saved with the SPS save data (saveToXML / loadFromXML) and restored on load.
--   * Join: SlurryPipeManager's join dump calls sendAllTo(connection).
--   * Who feeds it: tanker slurry couplings through the flow (SPSM_Flow GROUND_SPILL), slurry stores and the 80 mm
--     water / milk fittings of tankers and barns through SPSM_Leaks (valve left open, nothing connected).
-- Debug: SPSDebugConfig channel "SPSSpill".
-- ===========================================================================
SPSSpill = {}
SPSSpill.MAX_PUDDLES   = 12          -- cap (William: "yes a cap")
SPSSpill.MERGE_RADIUS  = 2.5         -- m: litres landing this close feed the same puddle
SPSSpill.GROW_STEP     = 250         -- litres between two size updates to the clients
SPSSpill.BROADCAST_MIN_MS = 1000     -- and never more than one size update a second per puddle
SPSSpill.MAX_LITRES    = 8000        -- the puddle stops growing (radius ~ MAX_RADIUS)
SPSSpill.MIN_RADIUS    = 0.6         -- m, a fresh puddle
SPSSpill.MAX_RADIUS    = 3.0         -- m, at MAX_LITRES (4.5 covered a whole yard - William's TSA shot 2026-11-03)
SPSSpill.DRY_AFTER_MS  = 15 * 60 * 1000   -- real ms without feed before a SLURRY puddle starts drying (TYPES overrides)
SPSSpill.DRY_LITRES_PER_S = 4        -- drying rate once it starts
-- [SPS 1.0.2.0] OUR OWN decals (William 2026-11-03: the map's rain puddle came out grey, a flat tint looked like a
-- painted sheet -> "the slurry store has a slurry plane, the water troughs a water plane, we use those").
-- i3d/effects/spsPuddle.i3d: one 2 m decal quad, THREE shapes (child 0 slurry = the lagoon fill plane surface, 1 water
-- = the game's fakeWater surface at 55 % alpha, 2 milk = creamy white), outline in the diffuse alpha, lagoon ripple
-- normal, the game's gloss, decalShader alpha-blended. The puddle's fill type picks the child (TYPES.child). A drying
-- puddle SHRINKS (the colour / opacity shader params of the old puddleShader route are gone; tint() and the opacity
-- fade are no-ops on these materials). Mod-relative path.
SPSSpill.PUDDLE_I3D    = "i3d/effects/spsPuddle.i3d"
SPSSpill.MOD_DIR       = g_currentModDirectory
SPSSpill.ASSET_RADIUS  = 0.8         -- m: radius of the visible blob in the diffuse alpha at scale 1 (quad is 2 m)
SPSSpill.COLOR_SLURRY  = { 0.10, 0.065, 0.025 }   -- (only used by a waterColor-capable material - none now)
SPSSpill.COLOR_WATER   = { 0.11, 0.24, 0.34 }
SPSSpill.COLOR_MILK    = { 0.93, 0.91, 0.86 }
SPSSpill.OPACITY       = 1.0
SPSSpill.Y_OFFSET      = 0.02        -- m above the terrain (decal)
-- [SPS 1.0.2.0] per-liquid look and life (William 2026-11-02: water and milk pool like slurry "but go after 5 mins").
-- Keyed by fill type NAME (resolved once, FillType indices are not known at file load); anything not listed = slurry
-- (child 0, 15 min, 4 L/s).
SPSSpill.TYPES = {
    WATER       = { child = 1, color = SPSSpill.COLOR_WATER, opacity = 1.0, dryAfterMs = 5 * 60 * 1000, dryLitresPerS = 8 },
    MILK        = { child = 2, color = SPSSpill.COLOR_MILK,  opacity = 1.0, dryAfterMs = 5 * 60 * 1000, dryLitresPerS = 8 },
    BUFFALOMILK = { child = 2, color = SPSSpill.COLOR_MILK,  opacity = 1.0, dryAfterMs = 5 * 60 * 1000, dryLitresPerS = 8 },
}
SPSSpill._typeByIndex = nil

-- the TYPES row for a fill type index (nil = slurry defaults)
function SPSSpill.typeInfo(fillType)
    if SPSSpill._typeByIndex == nil then
        SPSSpill._typeByIndex = {}
        if g_fillTypeManager ~= nil then
            -- [SPS CHEM 2026-11-09] every sprayer liquid (fertiliser, herbicide, concentrates, mod liquids): the WATER
            -- look, not slurry (William: "it should be more like water, but not water, a chem" - a chem look of its
            -- own needs a material in i3d/effects/spsPuddle.i3d). Explicit rows below win.
            local chem = { child = 1, color = SPSSpill.COLOR_WATER, opacity = 1.0, dryAfterMs = 5 * 60 * 1000, dryLitresPerS = 6 }
            local ok, list = pcall(g_fillTypeManager.getFillTypesByCategoryNames, g_fillTypeManager, "sprayer", nil)
            if ok and type(list) == "table" then
                for _, idx in ipairs(list) do SPSSpill._typeByIndex[idx] = chem end
            end
            for idx, ft in ipairs(g_fillTypeManager.fillTypes or {}) do
                if type(ft.name) == "string" and ft.name:sub(-5) == "_CONC" then SPSSpill._typeByIndex[idx] = chem end
            end
            for name, info in pairs(SPSSpill.TYPES) do
                local idx = g_fillTypeManager:getFillTypeIndexByName(name)
                if idx ~= nil then SPSSpill._typeByIndex[idx] = info end
            end
        end
    end
    return fillType ~= nil and SPSSpill._typeByIndex[fillType] or nil
end

SPSSpill.puddles    = {}             -- id -> { id, x, y, z, litres, fillType, lastFedMs, sentLitres, node, loading }
-- [SPS CHEM 2026-11-07] STRIP puddles (sprayer washout, William: "wide on the x and short on the z"): p.len / p.wid in
-- metres and p.rotY (the strip's X axis along the boom). Fixed size, keyed by a 1 m grid cell of their centre (standing
-- still, the next rinse feeds the same strips), their own cap so they never push out leak puddles.
SPSSpill.MAX_STRIPS = 40
SPSSpill.nextId     = 1
SPSSpill._sharedReq = nil            -- shared i3d request id
SPSSpill._tickAcc   = 0

local function dbg(fmt, ...)
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn ~= nil and SPSDebugConfig.isOn("SPSSpill") then
        print("[SPS SPILL] " .. string.format(fmt, ...))
    end
end

local function nowMs() return g_time or 0 end

local function isServer() return g_server ~= nil end
local function isClient() return g_client ~= nil end

local function radiusFor(litres)
    local t = math.min(1, math.max(0, (litres or 0) / SPSSpill.MAX_LITRES))
    return SPSSpill.MIN_RADIUS + (SPSSpill.MAX_RADIUS - SPSSpill.MIN_RADIUS) * math.sqrt(t)
end

-- [SPS 1.0.2.0] The SURFACE under a point: a short downward raycast against terrain + static objects + buildings +
-- roads (the concrete apron of a placed shed is a BUILDING collision, not terrain - William 2026-11-02: "the poo is
-- not laying on that concrete"), falling back to the terrain height. Same mask / pattern as SPSPipeChain's floor probe.
SPSSpill.SURFACE_RAY_UP   = 0.5
SPSSpill.SURFACE_RAY_DOWN = 6.0
function SPSSpill.surfaceY(x, y, z)
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    local ty = terrain ~= nil and getTerrainHeightAtWorldPos(terrain, x, y or 0, z) or (y or 0)
    if SPSSpill._rayMask == nil then
        if CollisionFlag ~= nil and RaycastUtil ~= nil and RaycastUtil.raycastClosest ~= nil
           and CollisionFlag.STATIC_OBJECT ~= nil and CollisionFlag.TERRAIN ~= nil
           and CollisionFlag.BUILDING ~= nil and CollisionFlag.ROAD ~= nil then
            SPSSpill._rayMask = CollisionFlag.STATIC_OBJECT + CollisionFlag.TERRAIN + CollisionFlag.BUILDING + CollisionFlag.ROAD
        else
            SPSSpill._rayMask = false
        end
    end
    if SPSSpill._rayMask == false then return ty end
    local hitId, _, hitY, _ = RaycastUtil.raycastClosest(x, (y or ty) + SPSSpill.SURFACE_RAY_UP, z, 0, -1, 0,
        SPSSpill.SURFACE_RAY_UP + SPSSpill.SURFACE_RAY_DOWN, SPSSpill._rayMask)
    if hitId ~= nil and hitId ~= 0 and hitY ~= nil and hitY > ty then return hitY end
    return ty
end

-- ---------------------------------------------------------------------------
-- server side
-- ---------------------------------------------------------------------------
local function broadcast(p)
    if not isServer() or SPSSpillPuddleEvent == nil then return end
    g_server:broadcastEvent(SPSSpillPuddleEvent.new(p.id, p.x, p.y, p.z, p.litres, p.fillType, p.len, p.wid, p.rotY), false, nil, nil)
    p.sentLitres = p.litres
end

local function removePuddle(p, reason)
    if p == nil then return end
    dbg("puddle %d removed (%s, %.0f L)", p.id, tostring(reason), p.litres or 0)
    p.litres = 0
    if isServer() then broadcast(p) end
    SPSSpill.removeVisual(p)
    SPSSpill.puddles[p.id] = nil
end

-- Server: `litres` of `fillType` ran out of a pipe end at x,y,z (y = terrain height under the end)
function SPSSpill.addLitres(x, y, z, litres, fillType)
    if not isServer() or litres == nil or litres <= 0 or x == nil then return end
    local best, bestD = nil, SPSSpill.MERGE_RADIUS * SPSSpill.MERGE_RADIUS
    local count, oldest = 0, nil
    for _, p in pairs(SPSSpill.puddles) do
        if p.len == nil then   -- strips have their own cap / key
            count = count + 1
            local d = (p.x - x) ^ 2 + (p.z - z) ^ 2
            if d < bestD then best, bestD = p, d end
            if oldest == nil or p.lastFedMs < oldest.lastFedMs then oldest = p end
        end
    end
    local t = nowMs()
    if best == nil then
        if count >= SPSSpill.MAX_PUDDLES and oldest ~= nil then removePuddle(oldest, "cap") end
        best = { id = SPSSpill.nextId, x = x, y = y, z = z, litres = 0, fillType = fillType or 0, lastFedMs = t, sentLitres = -1 }
        SPSSpill.nextId = SPSSpill.nextId + 1
        if SPSSpill.nextId > 65000 then SPSSpill.nextId = 1 end
        SPSSpill.puddles[best.id] = best
        dbg("puddle %d created at %.1f %.1f %.1f (%s)", best.id, x, y, z, tostring(fillType))
    end
    best.litres = math.min(SPSSpill.MAX_LITRES, best.litres + litres)
    best.peak = math.max(best.peak or 0, best.litres)
    best.lastFedMs = t
    best.fillType = fillType or best.fillType
    -- size updates to the clients: on create, then at most once per BROADCAST_MIN_MS and GROW_STEP litres (a TSA pours
    -- ~700 L/s, so per-batch updates would be 7 events a second)
    local due = best.sentLitres < 0
        or ((best.litres - best.sentLitres >= SPSSpill.GROW_STEP or best.litres >= SPSSpill.MAX_LITRES and best.sentLitres < SPSSpill.MAX_LITRES)
            and t - (best.lastSentMs or 0) >= SPSSpill.BROADCAST_MIN_MS)
    if due then
        best.lastSentMs = t
        broadcast(best)
        SPSSpill.applyVisual(best)   -- the listen server renders too
    end
end

-- Server: `litres` onto a STRIP puddle (len x wid metres, its length along rotY) centred at x,y,z
function SPSSpill.addStrip(x, y, z, litres, fillType, len, wid, rotY)
    if not isServer() or litres == nil or litres <= 0 or x == nil then return end
    local key = string.format("%d:%d", math.floor(x + 0.5), math.floor(z + 0.5))
    local hit, count, oldest = nil, 0, nil
    for _, p in pairs(SPSSpill.puddles) do
        if p.len ~= nil then
            count = count + 1
            if p.stripKey == key then hit = p end
            if oldest == nil or p.lastFedMs < oldest.lastFedMs then oldest = p end
        end
    end
    local t = nowMs()
    if hit == nil then
        if count >= SPSSpill.MAX_STRIPS and oldest ~= nil then removePuddle(oldest, "strip cap") end
        hit = { id = SPSSpill.nextId, x = x, y = y, z = z, litres = 0, fillType = fillType or 0, lastFedMs = t, sentLitres = -1,
                len = len, wid = wid, rotY = rotY or 0, stripKey = key }
        SPSSpill.nextId = SPSSpill.nextId + 1
        if SPSSpill.nextId > 65000 then SPSSpill.nextId = 1 end
        SPSSpill.puddles[hit.id] = hit
    end
    hit.litres = math.min(SPSSpill.MAX_LITRES, hit.litres + litres)
    hit.peak = math.max(hit.peak or 0, hit.litres)
    hit.lastFedMs = t
    if hit.sentLitres < 0 or t - (hit.lastSentMs or 0) >= SPSSpill.BROADCAST_MIN_MS then
        hit.lastSentMs = t
        broadcast(hit)
        SPSSpill.applyVisual(hit)
    end
end

-- Server: join dump
function SPSSpill.sendAllTo(connection)
    if not isServer() or connection == nil or SPSSpillPuddleEvent == nil then return end
    for _, p in pairs(SPSSpill.puddles) do
        if p.litres > 0 then
            connection:sendEvent(SPSSpillPuddleEvent.new(p.id, p.x, p.y, p.z, p.litres, p.fillType, p.len, p.wid, p.rotY))
        end
    end
end

-- ---------------------------------------------------------------------------
-- client side (mirror)
-- ---------------------------------------------------------------------------
function SPSSpill.applyRemote(id, x, y, z, litres, fillType, len, wid, rotY)
    if id == nil then return end
    local p = SPSSpill.puddles[id]
    if litres == nil or litres <= 0 then
        if p ~= nil then SPSSpill.removeVisual(p); SPSSpill.puddles[id] = nil end
        return
    end
    if p == nil then
        p = { id = id, x = x, y = y, z = z, litres = litres, fillType = fillType or 0, lastFedMs = nowMs(), sentLitres = litres }
        SPSSpill.puddles[id] = p
    else
        p.x, p.y, p.z, p.litres, p.fillType, p.lastFedMs = x, y, z, litres, fillType or p.fillType, nowMs()
    end
    if len ~= nil and len > 0 then p.len, p.wid, p.rotY = len, wid, rotY or 0 end
    p.peak = math.max(p.peak or 0, litres)
    SPSSpill.applyVisual(p)
end

-- ---------------------------------------------------------------------------
-- visuals (anything with a renderer: clients and the listen server; a dedicated server skips)
-- ---------------------------------------------------------------------------
local function tint(node, fillType)
    local info = SPSSpill.typeInfo(fillType)
    local c = info ~= nil and info.color or SPSSpill.COLOR_SLURRY
    local a = info ~= nil and info.opacity or SPSSpill.OPACITY
    local function rec(n)
        if getHasClassId(n, ClassIds.SHAPE) then
            if getHasShaderParameter(n, "waterColor") then setShaderParameter(n, "waterColor", c[1], c[2], c[3], 0, false) end
            if getHasShaderParameter(n, "waterOpacity") then setShaderParameter(n, "waterOpacity", a, 0, 0, 0, false) end
        end
        for i = 0, getNumOfChildren(n) - 1 do rec(getChildAt(n, i)) end
    end
    rec(node)
end

local function setOpacityRec(node, a)
    if getHasClassId(node, ClassIds.SHAPE) and getHasShaderParameter(node, "waterOpacity") then
        setShaderParameter(node, "waterOpacity", a, 0, 0, 0, false)
    end
    for i = 0, getNumOfChildren(node) - 1 do setOpacityRec(getChildAt(node, i), a) end
end

local function placeVisual(p)
    if p.node == nil or p.node == 0 or not entityExists(p.node) then return end
    setTranslation(p.node, p.x, p.y + SPSSpill.Y_OFFSET, p.z)
    if p.len ~= nil and p.len > 0 then
        -- strip: fixed size along its heading, shrinking a little as it dries
        local f = math.max(0.4, math.min(1, (p.litres or 0) / math.max(p.peak or 1, 1)))
        setRotation(p.node, 0, p.rotY or 0, 0)
        setScale(p.node, 0.5 * p.len / SPSSpill.ASSET_RADIUS * f, 1, 0.5 * (p.wid or 1) / SPSSpill.ASSET_RADIUS * f)
    else
        local s = radiusFor(p.litres) / SPSSpill.ASSET_RADIUS
        setScale(p.node, s, 1, s)
    end
    -- [SPS 1.0.2.0] FADE (William: "it should fade away over time"): a drying puddle thins out as it shrinks - opacity
    -- follows litres / the most it ever held, down to a faint stain before it goes
    local peak = math.max(p.peak or p.litres, 1)
    local info = SPSSpill.typeInfo(p.fillType)
    local a = (info ~= nil and info.opacity or SPSSpill.OPACITY) * math.max(0.15, math.min(1, p.litres / peak))
    setOpacityRec(p.node, a)
    setVisibility(p.node, true)
end

-- "$data/..." must be resolved to the real game path first (Utils.getFilename); the engine loader does not expand it
-- (2026-11-02 log: "could not load $data/maps/... (reason 2)" on every batch).
local function puddleFile()
    if SPSSpill._resolvedFile == nil then
        local f
        if string.sub(SPSSpill.PUDDLE_I3D, 1, 1) == "$" then
            f = Utils.getFilename(SPSSpill.PUDDLE_I3D, "")
        else
            f = (SPSSpill.MOD_DIR or "") .. SPSSpill.PUDDLE_I3D      -- the mod's own decal
        end
        if f == nil or f == "" or not fileExists(f) then
            print("[SPS SPILL] WARNING: puddle asset not found: " .. tostring(SPSSpill.PUDDLE_I3D) .. " -> " .. tostring(f) .. " - leak puddles have no visual")
            SPSSpill._resolvedFile = false
        else
            SPSSpill._resolvedFile = f
        end
    end
    return SPSSpill._resolvedFile
end

function SPSSpill.applyVisual(p)
    if not isClient() or p == nil or p.litres <= 0 then return end
    if p.node ~= nil then placeVisual(p); return end
    if p.loading or p.noVisual or SPSSpill._assetFailed then return end
    local file = puddleFile()
    if file == false then SPSSpill._assetFailed = true; return end
    p.loading = true
    SPSSpill._sharedReq = g_i3DManager:loadSharedI3DFileAsync(file, false, false, SPSSpill.onPuddleLoaded, SPSSpill, { id = p.id })
end

function SPSSpill:onPuddleLoaded(i3dNode, failedReason, args)
    local p = args ~= nil and SPSSpill.puddles[args.id] or nil
    if i3dNode == nil or i3dNode == 0 then
        if not SPSSpill._assetFailed then
            print("[SPS SPILL] WARNING: could not load " .. tostring(SPSSpill._resolvedFile) .. " (reason " .. tostring(failedReason) .. ") - leak puddles have no visual")
        end
        SPSSpill._assetFailed = true                       -- once: no retry storm
        if p ~= nil then p.loading = false; p.noVisual = true end
        return
    end
    if p == nil or p.litres <= 0 then delete(i3dNode); return end   -- gone meanwhile
    -- the shape for this liquid (child 0 slurry / 1 water / 2 milk); the rest of the loaded copy goes
    local info = SPSSpill.typeInfo(p.fillType)
    local want = info ~= nil and info.child or 0
    if want >= getNumOfChildren(i3dNode) then want = 0 end
    local node = getChildAt(i3dNode, want)
    if node == nil or node == 0 then delete(i3dNode); p.loading = false; return end
    link(getRootNode(), node)
    delete(i3dNode)
    p.node = node
    p.loading = false
    setName(node, string.format("spsSpillPuddle%02d", p.id))
    tint(node, p.fillType)
    placeVisual(p)
    dbg("puddle %d visual ready (%.0f L, r=%.2f m)", p.id, p.litres, radiusFor(p.litres))
end

function SPSSpill.removeVisual(p)
    if p ~= nil and p.node ~= nil and p.node ~= 0 and entityExists(p.node) then delete(p.node) end
    if p ~= nil then p.node = nil end
end

-- ---------------------------------------------------------------------------
-- per frame (from SlurryPipeManager:update): once a second
-- ---------------------------------------------------------------------------
function SPSSpill.update(dt)
    SPSSpill._tickAcc = SPSSpill._tickAcc + (dt or 0)
    if SPSSpill._tickAcc < 1000 then return end
    local step = SPSSpill._tickAcc * 0.001
    SPSSpill._tickAcc = 0
    if not isServer() then return end
    local t = nowMs()
    if SPSSpill._resendAfterLoad then          -- restored puddles: tell the clients (and draw them here) once
        SPSSpill._resendAfterLoad = nil
        for _, p in pairs(SPSSpill.puddles) do broadcast(p); SPSSpill.applyVisual(p) end
    end
    for id, p in pairs(SPSSpill.puddles) do
        local info = SPSSpill.typeInfo(p.fillType)   -- water / milk dry sooner and faster than slurry
        if t - p.lastFedMs > (info ~= nil and info.dryAfterMs or SPSSpill.DRY_AFTER_MS) then
            p.litres = p.litres - (info ~= nil and info.dryLitresPerS or SPSSpill.DRY_LITRES_PER_S) * step
            if p.litres <= 0 then
                removePuddle(p, "dried")
            elseif p.sentLitres - p.litres >= SPSSpill.GROW_STEP then
                broadcast(p)
                SPSSpill.applyVisual(p)
            end
        end
    end
end

function SPSSpill.removeAll()
    for _, p in pairs(SPSSpill.puddles) do SPSSpill.removeVisual(p) end
    SPSSpill.puddles = {}
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.2.0] SAVE / LOAD (William: "should it be saved for a reload?" - yes): the server writes every puddle into
-- the SPS save file (slurryPipeSystem.spillPuddles.puddle#x y z litres peak fillType dryMs), the load rebuilds the
-- list; the first update after load re-sends them to the clients and the drying clock continues where it was.
-- ---------------------------------------------------------------------------
function SPSSpill.saveToXML(xmlFile)
    if xmlFile == nil then return end
    local i = 0
    local t = nowMs()
    for _, p in pairs(SPSSpill.puddles) do
        if p.litres > 0 then
            local key = string.format("slurryPipeSystem.spillPuddles.puddle(%d)", i)
            xmlFile:setFloat(key .. "#x", p.x); xmlFile:setFloat(key .. "#y", p.y); xmlFile:setFloat(key .. "#z", p.z)
            xmlFile:setFloat(key .. "#litres", p.litres)
            xmlFile:setFloat(key .. "#peak", p.peak or p.litres)
            xmlFile:setString(key .. "#fillType", g_fillTypeManager:getFillTypeNameByIndex(p.fillType) or "LIQUIDMANURE")
            xmlFile:setFloat(key .. "#dryMs", math.max(0, t - (p.lastFedMs or t)))   -- how long it has been drying
            if p.len ~= nil then
                xmlFile:setFloat(key .. "#len", p.len); xmlFile:setFloat(key .. "#wid", p.wid or 1)
                xmlFile:setFloat(key .. "#rotY", p.rotY or 0); xmlFile:setString(key .. "#stripKey", p.stripKey or "")
            end
            i = i + 1
        end
    end
end

function SPSSpill.loadFromXML(xmlFile)
    if xmlFile == nil or not isServer() then return end
    local i, n, t = 0, 0, nowMs()
    while true do
        local key = string.format("slurryPipeSystem.spillPuddles.puddle(%d)", i)
        if not xmlFile:hasProperty(key) then break end
        local litres = xmlFile:getFloat(key .. "#litres", 0)
        if litres > 0 then
            local ft = g_fillTypeManager:getFillTypeIndexByName(xmlFile:getString(key .. "#fillType", "LIQUIDMANURE")) or FillType.LIQUIDMANURE
            local p = { id = SPSSpill.nextId, x = xmlFile:getFloat(key .. "#x", 0), y = xmlFile:getFloat(key .. "#y", 0), z = xmlFile:getFloat(key .. "#z", 0),
                        litres = litres, peak = xmlFile:getFloat(key .. "#peak", litres), fillType = ft,
                        lastFedMs = t - xmlFile:getFloat(key .. "#dryMs", 0), sentLitres = -1 }
            SPSSpill.nextId = SPSSpill.nextId + 1
            local len = xmlFile:getFloat(key .. "#len")   -- [SPS CHEM 2026-11-07] strip shape
            if len ~= nil and len > 0 then
                p.len, p.wid, p.rotY = len, xmlFile:getFloat(key .. "#wid", 1), xmlFile:getFloat(key .. "#rotY", 0)
                p.stripKey = xmlFile:getString(key .. "#stripKey")
            end
            SPSSpill.puddles[p.id] = p
            n = n + 1
        end
        i = i + 1
    end
    SPSSpill._resendAfterLoad = n > 0
    if n > 0 then print(string.format("[SPS] %d leak puddle(s) restored from the savegame", n)) end
end
