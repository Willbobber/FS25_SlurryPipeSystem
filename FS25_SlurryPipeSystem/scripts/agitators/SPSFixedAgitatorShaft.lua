-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4
--
-- SPSFixedAgitatorShaft.lua
-- ---------------------------------------------------------------------------
-- Loads and poses a walterscheid PTO shaft on a PLACEABLE fixed agitator.
--
-- A placeable can't use the PowerTakeOffs vehicle spec, but the shaft geometry
-- in PowerTakeOffs.lua is pure node math (the update funcs don't touch the
-- vehicle 'self'), so it is ported here verbatim and driven from our own
-- pto table:
--   * load   — async-load walterscheidW.i3d, resolve nodes, build the
--              single/double-joint telescoping parts, park at the detach node.
--   * attach — link the free end to the tractor's PTO output node (work pose).
--   * park   — link the free end back to the detach node (rest pose).
--   * update — per-frame telescope (called for every loaded shaft each tick).
--
-- Node roles (match vanilla loadInputPowerTakeOff):
--   inputNode  = ptoNodeAttached  (shaft's fixed/implement end)
--   detachNode = ptoNodeDetached  (where the free end parks at rest)
--   linkNode   = shaft free end   (-> tractor PTO output when connected)
-- ---------------------------------------------------------------------------

SPSFixedAgitatorShaft = {}

SPSFixedAgitatorShaft.DEBUG = false
local function slog(fmt, ...)
    if not SPSFixedAgitatorShaft.DEBUG then return end
    if select("#", ...) > 0 then print("[SPS SHAFT] " .. string.format(fmt, ...))
    else print("[SPS SHAFT] " .. tostring(fmt)) end
end

-- ---- ported geometry (self-less; operate on the pto table) -----------------

local function updateSingleJoint(pto)
    local x, y, z = getWorldTranslation(pto.linkNode)
    local dx, dy, dz = worldToLocal(pto.startNode, x, y, z)
    I3DUtil.setDirection(pto.startJoint, dx, dy, dz, 0, 1, 0)
    dx, dy, dz = worldToLocal(getParent(pto.endJoint), x, y, z)
    setTranslation(pto.endJoint, 0, 0, MathUtil.vector3Length(dx, dy, dz))
    local dist = calcDistanceFrom(pto.scalePart, pto.scalePartRef)
    setScale(pto.scalePart, 1, 1, dist / pto.scalePartBaseDistance)
end

local function updateDoubleJoint(pto)
    local x, y, z = getWorldTranslation(pto.startNode)
    local dx, dy, dz = worldToLocal(getParent(pto.endJoint2), x, y, z)
    dx, dy, dz = MathUtil.vector3Normalize(dx, dy, dz)
    I3DUtil.setDirection(pto.endJoint2, dx * 0.5, dy * 0.5, (dz + 1) * 0.5, 0, 1, 0)
    x, y, z = getWorldTranslation(pto.endJoint1Ref)
    dx, dy, dz = worldToLocal(getParent(pto.startJoint1), x, y, z)
    dx, dy, dz = MathUtil.vector3Normalize(dx, dy, dz)
    I3DUtil.setDirection(pto.startJoint1, dx * 0.5, dy * 0.5, (dz + 1) * 0.5, 0, 1, 0)
    x, y, z = getWorldTranslation(pto.endJoint1Ref)
    dx, dy, dz = worldToLocal(getParent(pto.startJoint2), x, y, z)
    dx, dy, dz = MathUtil.vector3Normalize(dx, dy, dz)
    I3DUtil.setDirection(pto.startJoint2, dx, dy, dz, 0, 1, 0)
    dx, dy, dz = worldToLocal(getParent(pto.endJoint1), x, y, z)
    setTranslation(pto.endJoint1, 0, 0, MathUtil.vector3Length(dx, dy, dz))
    local dist = calcDistanceFrom(pto.scalePart, pto.scalePartRef)
    setScale(pto.scalePart, 1, 1, dist / pto.scalePartBaseDistance)
end

local function updateLength(pto)
    if pto.betweenLength == nil or pto.betweenLength == 0 then return end
    local attachLength = calcDistanceFrom(pto.linkNode, pto.startNode)
    local transPartScale = math.max(attachLength - (pto.connectorLength or 0), 0) / pto.betweenLength
    setScale(pto.translationPart, 1, 1, transPartScale)
    if pto.decal ~= nil then
        local transPartLength = transPartScale * pto.translationPartLength
        if pto.decalMinOffset * 2 + pto.decalSize < transPartLength then
            local offset = math.min((transPartLength - pto.decalSize) / 2, pto.decalOffset)
            local decalTranslation = offset + pto.decalSize * 0.5
            local x, y, _ = getTranslation(pto.decal)
            setTranslation(pto.decal, x, y, -decalTranslation / transPartScale)
            setScale(pto.decal, 1, 1, 1 / transPartScale)
        else
            setVisibility(pto.decal, false)
        end
    end
end

local function updateShaft(pto)
    if not pto.i3dLoaded then return end
    if not (pto.isLinked or pto.isPlaced) then return end
    if pto.updateFunc ~= nil then pto.updateFunc(pto) end
end
SPSFixedAgitatorShaft.update = updateShaft

local function park(pto)
    if not pto.i3dLoaded then return end
    if pto.detachNode ~= nil and pto.detachNode ~= 0 then
        link(pto.detachNode, pto.linkNode)
        link(pto.inputNode, pto.startNode)
        setTranslation(pto.linkNode, 0, 0, pto.zOffset)
        setTranslation(pto.startNode, 0, 0, -pto.zOffset)
        pto.isLinked = true
        setVisibility(pto.linkNode, true)
        setVisibility(pto.startNode, true)
        updateShaft(pto)
        updateLength(pto)
    end
end
SPSFixedAgitatorShaft.park = park

local function attach(pto, outputNode)
    if not pto.i3dLoaded or outputNode == nil or outputNode == 0 then return false end
    link(outputNode, pto.linkNode)
    link(pto.inputNode, pto.startNode)
    setTranslation(pto.linkNode, 0, 0, pto.zOffset)
    setTranslation(pto.startNode, 0, 0, -pto.zOffset)
    pto.isLinked = true
    setVisibility(pto.linkNode, true)
    setVisibility(pto.startNode, true)
    updateShaft(pto)
    updateLength(pto)
    return true
end
SPSFixedAgitatorShaft.attach = attach

-- ---- loading ---------------------------------------------------------------

local function buildLoadedShaft(pto, xmlFile, i3dNode, args)
    pto.components  = {}
    pto.i3dMappings = {}
    I3DUtil.loadI3DComponents(i3dNode, pto.components)
    I3DUtil.loadI3DMapping(xmlFile, "powerTakeOff", pto.components, pto.i3dMappings)

    pto.startNode = xmlFile:getValue("powerTakeOff.startNode#node", nil, pto.components, pto.i3dMappings)
    if pto.startNode == nil then
        slog("no startNode in %s", tostring(args.i3dFilename))
        delete(i3dNode); xmlFile:delete(); return
    end

    pto.size      = xmlFile:getValue("powerTakeOff#size", 0.19)
    pto.minLength = xmlFile:getValue("powerTakeOff#minLength", 0.6)
    pto.maxAngle  = xmlFile:getValue("powerTakeOff#maxAngle", 45)
    pto.zOffset   = pto.zOffset or xmlFile:getValue("powerTakeOff#zOffset", 0)
    -- loadAnimations needs a target with .customEnvironment (mod env). Use the
    -- placeable. pcall-guarded: the joint-spin animation is cosmetic, so if it
    -- fails the shaft still loads and telescopes.
    local okA, animOrErr = pcall(function()
        return g_animationManager:loadAnimations(
            xmlFile, "powerTakeOff.animationNodes", pto.components, args.placeable, pto.i3dMappings)
    end)
    if okA then
        pto.animationNodes = animOrErr
    else
        slog("loadAnimations skipped: %s", tostring(animOrErr))
        pto.animationNodes = nil
    end

    local C, M = pto.components, pto.i3dMappings
    if xmlFile:getValue("powerTakeOff#isSingleJoint") then
        pto.startJoint        = xmlFile:getValue("powerTakeOff.startJoint#node", nil, C, M)
        pto.scalePart         = xmlFile:getValue("powerTakeOff.scalePart#node", nil, C, M)
        pto.scalePartRef      = xmlFile:getValue("powerTakeOff.scalePart#referenceNode", nil, C, M)
        local _, _, dis = localToLocal(pto.scalePartRef, pto.scalePart, 0, 0, 0)
        pto.scalePartBaseDistance = dis
        pto.translationPart   = xmlFile:getValue("powerTakeOff.translationPart#node", nil, C, M)
        pto.translationPartRef = xmlFile:getValue("powerTakeOff.translationPart#referenceNode", nil, C, M)
        pto.translationPartLength = xmlFile:getValue("powerTakeOff.translationPart#length", 0.4)
        pto.decal             = xmlFile:getValue("powerTakeOff.translationPart.decal#node", nil, C, M)
        pto.decalSize         = xmlFile:getValue("powerTakeOff.translationPart.decal#size", 0.1)
        pto.decalOffset       = xmlFile:getValue("powerTakeOff.translationPart.decal#offset", 0.05)
        pto.decalMinOffset    = xmlFile:getValue("powerTakeOff.translationPart.decal#minOffset", 0.01)
        pto.endJoint          = xmlFile:getValue("powerTakeOff.endJoint#node", nil, C, M)
        pto.linkNode          = xmlFile:getValue("powerTakeOff.linkNode#node", nil, C, M)
        local _, _, betweenLength = localToLocal(pto.translationPart, pto.translationPartRef, 0, 0, 0)
        local _, _, ptoLength     = localToLocal(pto.startNode, pto.linkNode, 0, 0, 0)
        pto.betweenLength   = math.abs(betweenLength)
        pto.connectorLength = math.abs(ptoLength) - math.abs(betweenLength)
        setTranslation(pto.linkNode, 0, 0, 0)
        setRotation(pto.linkNode, 0, 0, 0)
        pto.updateFunc = updateSingleJoint
    elseif xmlFile:getValue("powerTakeOff#isDoubleJoint") then
        pto.startJoint1       = xmlFile:getValue("powerTakeOff.startJoint1#node", nil, C, M)
        pto.startJoint2       = xmlFile:getValue("powerTakeOff.startJoint2#node", nil, C, M)
        pto.scalePart         = xmlFile:getValue("powerTakeOff.scalePart#node", nil, C, M)
        pto.scalePartRef      = xmlFile:getValue("powerTakeOff.scalePart#referenceNode", nil, C, M)
        local _, _, dis = localToLocal(pto.scalePartRef, pto.scalePart, 0, 0, 0)
        pto.scalePartBaseDistance = dis
        pto.translationPart   = xmlFile:getValue("powerTakeOff.translationPart#node", nil, C, M)
        pto.translationPartRef = xmlFile:getValue("powerTakeOff.translationPart#referenceNode", nil, C, M)
        pto.translationPartLength = xmlFile:getValue("powerTakeOff.translationPart#length", 0.4)
        pto.decal             = xmlFile:getValue("powerTakeOff.translationPart.decal#node", nil, C, M)
        pto.decalSize         = xmlFile:getValue("powerTakeOff.translationPart.decal#size", 0.1)
        pto.decalOffset       = xmlFile:getValue("powerTakeOff.translationPart.decal#offset", 0.05)
        pto.decalMinOffset    = xmlFile:getValue("powerTakeOff.translationPart.decal#minOffset", 0.01)
        pto.endJoint1         = xmlFile:getValue("powerTakeOff.endJoint1#node", nil, C, M)
        pto.endJoint1Ref      = xmlFile:getValue("powerTakeOff.endJoint1#referenceNode", nil, C, M)
        pto.endJoint2         = xmlFile:getValue("powerTakeOff.endJoint2#node", nil, C, M)
        pto.linkNode          = xmlFile:getValue("powerTakeOff.linkNode#node", nil, C, M)
        local _, _, betweenLength = localToLocal(pto.translationPart, pto.translationPartRef, 0, 0, 0)
        local _, _, ptoLength     = localToLocal(pto.startNode, pto.linkNode, 0, 0, 0)
        pto.betweenLength   = math.abs(betweenLength)
        pto.connectorLength = math.abs(ptoLength) - math.abs(betweenLength)
        setTranslation(pto.linkNode, 0, 0, 0)
        setRotation(pto.linkNode, 0, 0, 0)
        pto.updateFunc = updateDoubleJoint
    else
        -- basic
        pto.linkNode = xmlFile:getValue("powerTakeOff.linkNode#node", nil, C, M)
    end

    -- The shaft i3d's startNode lives under the implement input node.
    link(pto.inputNode, pto.startNode)
    pto.i3dLoaded = true

    -- Rest pose by default; if already connected (load raced the connect), the
    -- caller re-attaches via SPSFixedAgitatorShaft.attach.
    park(pto)
    updateShaft(pto)

    delete(i3dNode)
    xmlFile:delete()
    if args.onLoaded ~= nil then args.onLoaded(pto) end
    slog("loaded shaft for %s", tostring(args.i3dFilename))
end

-- Async finisher: never let a build error escape into loadSharedI3DFileAsyncFinished.
local function onI3DLoaded(target, i3dNode, failedReason, args)
    local pto     = args.pto
    local xmlFile = args.xmlFile
    if i3dNode == nil or i3dNode == 0 then
        slog("i3d load failed for %s", tostring(args.i3dFilename))
        if xmlFile ~= nil then pcall(function() xmlFile:delete() end) end
        return
    end
    local ok, err = pcall(buildLoadedShaft, pto, xmlFile, i3dNode, args)
    if not ok then
        slog("shaft build error: %s", tostring(err))
        if i3dNode ~= 0 and entityExists(i3dNode) then delete(i3dNode) end
        if xmlFile ~= nil then pcall(function() xmlFile:delete() end) end
        pto.i3dLoaded = false
    end
end

-- load(fa, baseDir, onLoaded) — fa supplies inputNode/detachNode + cfg filename.
function SPSFixedAgitatorShaft.load(fa, baseDir, onLoaded)
    if fa == nil or fa.cfg == nil then return nil end
    local filename = fa.cfg.shaftFilename
    if filename == nil or filename == "" then return nil end
    if fa.inputNode == nil or fa.inputNode == 0 then
        slog("no inputNode — cannot load shaft")
        return nil
    end
    if PowerTakeOffs == nil or PowerTakeOffs.xmlSchema == nil then
        slog("PowerTakeOffs.xmlSchema unavailable — cannot load shaft")
        return nil
    end

    local xmlFilename = Utils.getFilename(filename, baseDir)
    local xmlFile = XMLFile.load("SPSPtoConfig", xmlFilename, PowerTakeOffs.xmlSchema)
    if xmlFile == nil then
        slog("failed to open pto config %s", tostring(xmlFilename))
        return nil
    end
    local i3dFilename = xmlFile:getValue("powerTakeOff#filename")
    if i3dFilename == nil then
        slog("no i3d filename in %s", tostring(xmlFilename))
        xmlFile:delete()
        return nil
    end
    i3dFilename = Utils.getFilename(i3dFilename, baseDir)

    local pto = {
        inputNode   = fa.inputNode,
        detachNode  = fa.detachNode,
        zOffset     = fa.cfg.shaftZOffset or 0,
        i3dLoaded   = false,
        isLinked    = false,
    }
    fa.shaft = pto

    local args = { pto = pto, xmlFile = xmlFile, i3dFilename = i3dFilename, onLoaded = onLoaded, placeable = fa.placeable }
    pto.sharedLoadRequestId = g_i3DManager:loadSharedI3DFileAsync(
        i3dFilename, false, false, onI3DLoaded, SPSFixedAgitatorShaft, args)
    return pto
end

function SPSFixedAgitatorShaft.delete(pto)
    if pto == nil then return end
    if pto.animationNodes ~= nil and g_animationManager ~= nil then
        g_animationManager:deleteAnimations(pto.animationNodes)
        pto.animationNodes = nil
    end
    if pto.startNode ~= nil and pto.startNode ~= 0 and entityExists(pto.startNode) then
        delete(pto.startNode)
    end
    pto.i3dLoaded = false
    pto.isLinked  = false
end