-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.2

-- SPSCouplerAnimator.lua
-- Lightweight per-coupling animator. Mirrors the vanilla AnimatedVehicle data
-- model (parts list with startTime/endTime in seconds, startRot/endRot in
-- degrees, optional startTrans/endTrans) but resolves nodes by walking the
-- coupling's mountNode subtree instead of going through i3dMappings.
--
-- Library is loaded once from configs/couplerAnimations.xml. Each coupling
-- can declare a connectorAnimation id (plays forward on connect, reverse on
-- disconnect) and a valveAnimation id (plays forward on valve open, reverse
-- on valve close). Both are independent and per-coupling local.

print("[SPS BUILD] SPSCouplerAnimator 1.0.1.2 loaded")

SPSCouplerAnimator = {}

-- Library cache: { [animId(int)] = { id, name, parts = { ... } } }
SPSCouplerAnimator._library = nil
SPSCouplerAnimator._loaded  = false


-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function parseVec3(str)
    if str == nil then return nil end
    local x, y, z = str:match("(%S+)%s+(%S+)%s+(%S+)")
    if x == nil then return nil end
    return { tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0 }
end

-- Depth-first search for a child by name under root.
local function findDeepByName(root, name)
    if root == nil or root == 0 or name == nil then return nil end
    if getName(root) == name then return root end
    for i = 0, getNumOfChildren(root) - 1 do
        local found = findDeepByName(getChildAt(root, i), name)
        if found ~= nil then return found end
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- Library loading
-- ---------------------------------------------------------------------------

-- Idempotent — only loads once per game session.
function SPSCouplerAnimator.ensureLoaded(modDirectory)
    if SPSCouplerAnimator._loaded then return end
    -- [SPS 1.0.0.9.24] The SPSM_Sprayers bind sites pass
    -- g_currentMission.spsModDirectory, which was never assigned in 1.0.0.9.
    -- If such a call arrived FIRST in the session it latched an EMPTY library
    -- (order-of-registration dependent: worked on some machines, every later
    -- bind on others printed "not in library"). Resolve a nil directory from
    -- the manager before latching, and if still unresolvable return WITHOUT
    -- latching so a later good call can still load.
    if modDirectory == nil and g_slurryPipeManager ~= nil then
        modDirectory = g_slurryPipeManager.modDirectory
    end
    if modDirectory == nil and g_currentMission ~= nil then
        modDirectory = g_currentMission.spsModDirectory
    end
    if modDirectory == nil then
        print("[SPS] SPSCouplerAnimator.ensureLoaded: modDirectory is nil (library NOT latched, will retry on next call)")
        return
    end
    SPSCouplerAnimator._loaded  = true
    SPSCouplerAnimator._library = {}

    if modDirectory == nil then
        print("[SPS] SPSCouplerAnimator.ensureLoaded: modDirectory is nil")
        return
    end

    local path = modDirectory .. "configs/couplerAnimations.xml"
    local xmlFile = XMLFile.load("spsCouplerAnimations", path)
    if xmlFile == nil then
        print("[SPS] SPSCouplerAnimator.ensureLoaded: could not load " .. path)
        return
    end

    local idx = 0
    local count = 0
    while true do
        local key = string.format("couplerAnimations.couplerAnimation(%d)", idx)
        if not xmlFile:hasProperty(key) then break end

        local id = xmlFile:getInt(key .. "#id")
        if id ~= nil then
            local entry = {
                id    = id,
                name  = xmlFile:getString(key .. "#name", "anim_" .. tostring(id)),
                parts = {},
            }
            local pIdx = 0
            while true do
                local pKey = string.format("%s.part(%d)", key, pIdx)
                if not xmlFile:hasProperty(pKey) then break end
                local nodeName = xmlFile:getString(pKey .. "#node")
                if nodeName ~= nil then
                    local part = {
                        nodeName  = nodeName,
                        startTime = xmlFile:getFloat(pKey .. "#startTime", 0),
                        endTime   = xmlFile:getFloat(pKey .. "#endTime",   1),
                        -- Rotation values stored in degrees; converted to
                        -- radians at bind() time per-instance.
                        startRot   = parseVec3(xmlFile:getString(pKey .. "#startRot")),
                        endRot     = parseVec3(xmlFile:getString(pKey .. "#endRot")),
                        startTrans = parseVec3(xmlFile:getString(pKey .. "#startTrans")),
                        endTrans   = parseVec3(xmlFile:getString(pKey .. "#endTrans")),
                    }
                    table.insert(entry.parts, part)
                end
                pIdx = pIdx + 1
            end
            SPSCouplerAnimator._library[id] = entry
            count = count + 1
            print(string.format("[SPS] couplerAnimation id=%d '%s' loaded with %d part(s)",
                id, entry.name, #entry.parts))
        end
        idx = idx + 1
    end

    xmlFile:delete()
    print("[SPS] SPSCouplerAnimator.ensureLoaded: " .. tostring(count) .. " animation(s) from " .. path)
end


-- ---------------------------------------------------------------------------
-- Per-config local animation definitions
-- ---------------------------------------------------------------------------

-- [SPS 1.0.0.9.24] Parses a <couplerAnimations> block from a config's OWN xml
-- (embedded placeable/vehicle xml or bundled fillPoints.xml). Same element
-- format as configs/couplerAnimations.xml. Returns { [id] = entry } or nil if
-- the block is absent/empty. The returned table is LOCAL to the config that
-- declared it — it is passed into bind() and consulted before the global
-- library, so a third-party config can define its own animations (including
-- shadowing global ids 1/2) without touching SPS files and without affecting
-- any other vehicle or placeable in the session.
--
-- keyPrefix must end at the owning system element including the trailing dot,
-- e.g. "placeable.slurryPipeSystem." or kp already containing
-- "sprayerPipeSystem." — parseLocal appends "couplerAnimations..." itself.
function SPSCouplerAnimator.parseLocal(xmlFile, keyPrefix)
    if xmlFile == nil or keyPrefix == nil then return nil end

    local localLib = nil
    local idx = 0
    while true do
        local key = string.format("%scouplerAnimations.couplerAnimation(%d)", keyPrefix, idx)
        if not xmlFile:hasProperty(key) then break end

        local id = xmlFile:getInt(key .. "#id")
        if id ~= nil then
            local entry = {
                id    = id,
                name  = xmlFile:getString(key .. "#name", "localAnim_" .. tostring(id)),
                parts = {},
            }
            local pIdx = 0
            while true do
                local pKey = string.format("%s.part(%d)", key, pIdx)
                if not xmlFile:hasProperty(pKey) then break end
                local nodeName = xmlFile:getString(pKey .. "#node")
                if nodeName ~= nil then
                    local part = {
                        nodeName  = nodeName,
                        startTime = xmlFile:getFloat(pKey .. "#startTime", 0),
                        endTime   = xmlFile:getFloat(pKey .. "#endTime",   1),
                        startRot   = parseVec3(xmlFile:getString(pKey .. "#startRot")),
                        endRot     = parseVec3(xmlFile:getString(pKey .. "#endRot")),
                        startTrans = parseVec3(xmlFile:getString(pKey .. "#startTrans")),
                        endTrans   = parseVec3(xmlFile:getString(pKey .. "#endTrans")),
                    }
                    table.insert(entry.parts, part)
                end
                pIdx = pIdx + 1
            end
            if localLib == nil then localLib = {} end
            localLib[id] = entry
            print(string.format("[SPS] local couplerAnimation id=%d '%s' loaded with %d part(s) from config xml",
                id, entry.name, #entry.parts))
        end
        idx = idx + 1
    end

    return localLib
end


-- ---------------------------------------------------------------------------
-- Per-coupling instance binding
-- ---------------------------------------------------------------------------

-- Resolves all named parts from the library entry against the coupling's
-- mountNode subtree. Returns an instance table or nil if the animation id
-- doesn't exist or no parts could be resolved.
-- [SPS 1.0.0.9.24] Optional third parameter localLibrary: a per-config table
-- from parseLocal(). Checked BEFORE the global library so config-local ids win
-- for that config's couplings only. All pre-existing two-argument call sites
-- behave exactly as before (localLibrary arrives nil).
function SPSCouplerAnimator.bind(mountNode, animId, localLibrary)
    if SPSCouplerAnimator._library == nil and localLibrary == nil then return nil end
    if animId == nil or mountNode == nil then return nil end

    local entry = nil
    if localLibrary ~= nil then
        entry = localLibrary[animId]
    end
    if entry == nil and SPSCouplerAnimator._library ~= nil then
        entry = SPSCouplerAnimator._library[animId]
    end
    if entry == nil then
        print("[SPS] SPSCouplerAnimator.bind: animation id=" .. tostring(animId) .. " not in library")
        return nil
    end

    local parts  = {}
    local maxEnd = 0

    for _, p in ipairs(entry.parts) do
        local node = findDeepByName(mountNode, p.nodeName)
        if node ~= nil then
            local part = {
                node      = node,
                startTime = p.startTime,
                endTime   = p.endTime,
            }
            if p.startRot ~= nil and p.endRot ~= nil then
                part.startRotRad = { math.rad(p.startRot[1]), math.rad(p.startRot[2]), math.rad(p.startRot[3]) }
                part.endRotRad   = { math.rad(p.endRot[1]),   math.rad(p.endRot[2]),   math.rad(p.endRot[3])   }
                part.hasRot      = true
                -- Initial pose = startRot (disconnected/closed state).
                setRotation(node, part.startRotRad[1], part.startRotRad[2], part.startRotRad[3])
            end
            if p.startTrans ~= nil and p.endTrans ~= nil then
                part.startTrans = { p.startTrans[1], p.startTrans[2], p.startTrans[3] }
                part.endTrans   = { p.endTrans[1],   p.endTrans[2],   p.endTrans[3]   }
                part.hasTrans   = true
                setTranslation(node, part.startTrans[1], part.startTrans[2], part.startTrans[3])
            end
            table.insert(parts, part)
            if p.endTime > maxEnd then maxEnd = p.endTime end
        else
            print("[SPS] SPSCouplerAnimator.bind: part node '" .. tostring(p.nodeName)
                .. "' not found under mountNode for animation id=" .. tostring(animId))
        end
    end

    if #parts == 0 then return nil end

    return {
        animId      = animId,
        parts       = parts,
        duration    = maxEnd,   -- seconds
        currentTime = 0,        -- 0 = at start, duration = at end
        direction   = 0,        -- -1 reverse, 0 idle, 1 forward
        playing     = false,
    }
end


-- ---------------------------------------------------------------------------
-- Playback
-- ---------------------------------------------------------------------------

-- direction: 1 = forward (start->end), -1 = reverse (end->start)
-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.6] Vanilla-animation adapter.
--
-- A modder can author the clamp/valve animation ONCE in their vehicle's own
-- <animations> block and reference it by NAME from the coupling
-- (#connectorAnimationName / #valveAnimationName) instead of duplicating the
-- parts in <couplerAnimations>. bindVanilla returns an instance the whole
-- existing API (play/update/getSaveState/restoreState/setStart/setEnd) accepts,
-- delegating to AnimatedVehicle — so every call site in chains, couplers,
-- sprayers and the savegame restore works with either kind unchanged.
-- Vehicle couplings only: placeables have no AnimatedVehicle.
-- Normalised time (duration = 1); playAnimation is called with noEventSend=true
-- because every SPS trigger already runs on all peers via SPS's own events.
-- ---------------------------------------------------------------------------
function SPSCouplerAnimator.bindVanilla(vehicle, animName)
    if vehicle == nil or animName == nil or animName == "" then return nil end
    if vehicle.getAnimationExists == nil or not vehicle:getAnimationExists(animName) then
        print(string.format(
            "[SPS] WARNING: coupling animation '%s' not found in the animations of %s",
            tostring(animName), tostring(vehicle.configFileName)))
        return nil
    end
    return {
        isVanilla   = true,
        vehicle     = vehicle,
        animName    = animName,
        animId      = 0,      -- save slot is an int; vanilla instances save 0
        duration    = 1,      -- normalised time
        currentTime = 0,
        direction   = 0,
        playing     = false,
    }
end

function SPSCouplerAnimator.play(inst, direction)
    if inst == nil then return end
    inst.direction = direction
    if inst.isVanilla then
        -- Engine-managed: AnimatedVehicle progresses it, update() stays a no-op.
        inst.playing = false
        if inst.vehicle.playAnimation ~= nil then
            inst.vehicle:playAnimation(inst.animName, direction, nil, true)
        end
        return
    end
    inst.playing   = true
end


function SPSCouplerAnimator._applyAt(inst, t)
    if inst.isVanilla then return end
    for _, part in ipairs(inst.parts) do
        local localT
        if t <= part.startTime then
            localT = 0
        elseif t >= part.endTime then
            localT = 1
        else
            localT = (t - part.startTime) / (part.endTime - part.startTime)
        end
        if part.hasRot then
            local sr, er = part.startRotRad, part.endRotRad
            setRotation(part.node,
                sr[1] + (er[1] - sr[1]) * localT,
                sr[2] + (er[2] - sr[2]) * localT,
                sr[3] + (er[3] - sr[3]) * localT)
        end
        if part.hasTrans then
            local st, et = part.startTrans, part.endTrans
            setTranslation(part.node,
                st[1] + (et[1] - st[1]) * localT,
                st[2] + (et[2] - st[2]) * localT,
                st[3] + (et[3] - st[3]) * localT)
        end
    end
end


-- ---------------------------------------------------------------------------
-- Save / restore helpers
-- ---------------------------------------------------------------------------
-- Returns the exact runtime state needed by SlurryPipeManager so coupler
-- animations can be written into FS25_SlurryPipeSystem.xml. This mirrors the
-- basegame idea of saving animation time + direction, but stays independent
-- from vehicle/placeable AnimatedObject systems.
function SPSCouplerAnimator.getSaveState(inst)
    if inst == nil then return nil end
    if inst.isVanilla then
        local t = 0
        if inst.vehicle ~= nil and inst.vehicle.getAnimationTime ~= nil then
            t = inst.vehicle:getAnimationTime(inst.animName) or 0
        end
        return {
            animId    = 0,
            time      = t,
            direction = inst.direction or 0,
            playing   = false,
            duration  = 1,
        }
    end

    return {
        animId    = inst.animId,
        time      = inst.currentTime or 0,
        direction = inst.direction or 0,
        playing   = inst.playing == true,
        duration  = inst.duration or 0,
    }
end

-- Restores a previously saved animation state and immediately applies the pose
-- to the bound nodes. This is what makes a reloaded coupler handle/connector
-- appear in the saved position without waiting for another event.
function SPSCouplerAnimator.restoreState(inst, time, direction, playing)
    if inst == nil then return end
    if inst.isVanilla then
        local t = time or 0
        if t == math.huge then t = 1 end
        t = math.clamp(t, 0, 1)
        inst.currentTime = t
        inst.direction   = direction or 0
        if inst.vehicle ~= nil and inst.vehicle.setAnimationTime ~= nil then
            inst.vehicle:setAnimationTime(inst.animName, t, true)
        end
        -- A save taken mid-swing resumes the swing from the saved time.
        if playing == true and inst.direction ~= 0
        and inst.vehicle ~= nil and inst.vehicle.playAnimation ~= nil then
            inst.vehicle:playAnimation(inst.animName, inst.direction, t, true)
        end
        return
    end

    local duration = inst.duration or 0
    local t = time or 0
    if t == math.huge then
        t = duration
    end

    inst.currentTime = math.clamp(t, 0, duration)
    inst.direction   = direction or 0
    inst.playing     = playing == true and inst.direction ~= 0

    SPSCouplerAnimator._applyAt(inst, inst.currentTime)
end


-- [SPS 1.0.1.2] Snap an instance to its start or end pose without playing.
-- These are the legacy-savegame fallback used by SlurryPipeManager
-- :_applyPendingCouplerAnimation when a restored entry carries the old
-- `legacyConnected` boolean instead of the newer per-object
-- {time, direction, playing} table. Both call sites were guarded with
-- `~= nil`, so with the functions absent the branch was silently skipped and
-- a legacy save's connector kept whatever pose the i3d loaded with.
-- Implemented on top of restoreState so the pose is applied immediately and
-- the instance is left stopped (direction 0, playing false), matching what
-- a completed forward/reverse play leaves behind.
function SPSCouplerAnimator.setStart(inst)
    if inst == nil then return end
    SPSCouplerAnimator.restoreState(inst, 0, 0, false)
end

function SPSCouplerAnimator.setEnd(inst)
    if inst == nil then return end
    SPSCouplerAnimator.restoreState(inst, inst.duration or 0, 0, false)
end


function SPSCouplerAnimator.update(inst, dt)
    if inst == nil or not inst.playing then return end
    local dtSec = dt * 0.001
    inst.currentTime = inst.currentTime + dtSec * inst.direction
    if inst.direction > 0 and inst.currentTime >= inst.duration then
        inst.currentTime = inst.duration
        inst.playing     = false
    elseif inst.direction < 0 and inst.currentTime <= 0 then
        inst.currentTime = 0
        inst.playing     = false
    end
    SPSCouplerAnimator._applyAt(inst, inst.currentTime)
end