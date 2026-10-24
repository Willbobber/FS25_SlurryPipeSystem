-- Author:Oscar Mods
-- Name:SPS Pipe Placement
-- Description:SPS stow placements - create a pipe set (holder node structure), import a pipe, pose it, Create nodes writes p01..pNN under the holder
-- Icon:
-- Hide: no
-- FS25_SlurryPipeSystem - SPS_PipePlacement.lua - GIANTS EDITOR script (not a game script). Ships in placementPipes/.
--
-- A stowed SPS pipe sits on a vehicle where a modder POSED a real pipe. Run this script with your node tree open:
--   * New pipe set : Create pipe set builds the holder structure the SPS nodeTree linker needs (file root > SPS root >
--              pipeHolders > <attach node> > pipeHolder > SPS_pipeHolderNN, next free NN) - "Attach to" is the name of the
--              VEHICLE node the set is linked onto (e.g. profi2_vis); the holder is placed at the selected node, if any.
--   * Holder : a node named SPS_pipeHolderNN anywhere in the scene (the placement is written UNDER it)
--   * Pipe   : any posed pipe root in the scene. The donors here are a skinned mesh under the root with ONE bone
--              chain Bone01 > Bone02 > ... (rotate a bone and everything after it follows - pose from the first bone
--              outwards). The older layout - children ..col01, ..col02 ... each with a Bone child - still works.
--              Any bone / body count - the script walks the pipe from its first bone to its last.
--   * Name   : the placement's name under the holder (slurry, water_a, water_b ...). An existing one is replaced.
--   Create nodes : writes <holder>/<name>/p01..pNN = every bone's position + rotation (where the stowed bodies go).
--   Show on slot : pick a slot already captured (holder/name with p01..pNN) and a donor, Import onto slot loads the
--             donor at the bottom of the scene and puts every bone on its point - the pipe as it will lie on the
--             vehicle, ready to re-use / re-pose / capture again. It is only a preview: delete it when done.
--   Import  : loads a clean donor pipe from this folder into the scene (under the selected node, else the scene root)
--             so you can position its root and pose its BONES. Donors are a convenience only - any pipe works.
--   Naming  : the number a slot name ends in is its PLACE on the rail - one pipe per place. A 6 m slot shares the
--             place of the 4 m slot it sits on: slurry01 + slurryLong01, water02 + waterLong02.
-- The XML then names the holder node and its placements:
--   <pipeHolder id="1" nodeName="SPS_pipeHolder01" radius="1.0">
--       <placement node="slurry"  pipes="FM FF MM"/>
--       <placement node="water_a" pipes="WATER MILK"/>
--   </pipeHolder>
-- One slurry placement serves F/M, F/F and M/M (pose with pipe_FF, the longest); one water placement serves the
-- water AND the milk hose.

source("editorUtils.lua")

SPSPipePlacement = {}

local DONORS = {
    { file = "pipe_FM.i3d",    label = "pipe_FM (slurry F/M)" },
    { file = "pipe_FF.i3d",    label = "pipe_FF (slurry F/F, longest)" },
    { file = "pipe_MM.i3d",    label = "pipe_MM (slurry M/M)" },
    { file = "pipe_water.i3d", label = "pipe_water (water + milk)" },
    -- the 6 m pipes (19 bodies): a slot captured with one of these only takes a 6 m pipe of its family
    -- (the stow code's length rule); capture the 4 m slots with the pipes above
    { file = "pipe_FM_long.i3d",    label = "pipe_FM_long (slurry F/M 6 m)" },
    { file = "pipe_FF_long.i3d",    label = "pipe_FF_long (slurry F/F 6 m)" },
    { file = "pipe_MM_long.i3d",    label = "pipe_MM_long (slurry M/M 6 m)" },
    { file = "pipe_water_long.i3d", label = "pipe_water_long (water + milk 6 m)" },
}

local function say(fmt, ...) print("[SPS placement] " .. string.format(fmt, ...)) end

-- ---------------------------------------------------------------------------
-- scene scans
-- ---------------------------------------------------------------------------
local function walk(node, fn)
    fn(node)
    for i = 0, getNumOfChildren(node) - 1 do walk(getChildAt(node, i), fn) end
end

local function isBone(node)
    return string.match(getName(node) or "", "^Bone%d+$") ~= nil
end

-- the first Bone child of a node, or nil
local function boneChild(node)
    for i = 0, getNumOfChildren(node) - 1 do
        local c = getChildAt(node, i)
        if isBone(c) then return c end
    end
    return nil
end

-- bone-chain layout: root > mesh > Bone01 > Bone02 > ... (the chain hangs off a DIRECT child of the root, so only the
-- pipe root itself matches - not the mesh or the bones further down)
local function chainOf(root)
    if isBone(root) then return {} end
    for i = 0, getNumOfChildren(root) - 1 do
        local c = getChildAt(root, i)
        local first = (not isBone(c)) and boneChild(c) or nil
        if first ~= nil then
            local list, b = {}, first
            while b ~= nil do
                list[#list + 1] = { node = b, bone = b, order = #list + 1 }
                b = boneChild(b)
            end
            return list
        end
    end
    return {}
end

-- bodies of a pipe root in pipe order: a bone chain (see chainOf), else children named ..colNN with a Bone child
local function bodiesOf(root)
    local chain = chainOf(root)
    if #chain >= 2 then return chain end
    local list = {}
    for i = 0, getNumOfChildren(root) - 1 do
        local c = getChildAt(root, i)
        local n = string.match(getName(c) or "", "col(%d+)$")
        if n ~= nil then
            local bone = nil
            for j = 0, getNumOfChildren(c) - 1 do
                local cc = getChildAt(c, j)
                if string.sub(getName(cc) or "", 1, 4) == "Bone" then bone = cc; break end
            end
            if bone ~= nil then list[#list + 1] = { node = c, bone = bone, order = tonumber(n) } end
        end
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    return list
end

local function findHolders()
    local out = {}
    walk(getRootNode(), function(n)
        local name = getName(n) or ""
        if string.match(name, "^SPS_pipeHolder%d+$") then out[#out + 1] = { node = n, name = name } end
    end)
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function findPipes()
    local out = {}
    walk(getRootNode(), function(n)
        local count = #bodiesOf(n)
        if count >= 2 then out[#out + 1] = { node = n, name = getName(n) or "?", count = count } end
    end)
    return out
end

local function findChild(parent, name)
    for i = 0, getNumOfChildren(parent) - 1 do
        local c = getChildAt(parent, i)
        if getName(c) == name then return c end
    end
    return nil
end

local function findOrCreate(parent, name)
    local n = findChild(parent, name)
    if n ~= nil then return n, false end
    n = createTransformGroup(name)
    link(parent, n)
    setTranslation(n, 0, 0, 0)
    setRotation(n, 0, 0, 0)
    return n, true
end

-- the SPS root = the scene's first child (what the game's nodeTree linker reads as getChildAt(fileRoot, 0))
local function spsRootOf()
    local root = getRootNode()
    if getNumOfChildren(root) > 0 then return getChildAt(root, 0) end
    return nil
end

-- attach-node name of an existing pipe set (first container under pipeHolders), the default of the field
local function existingAttachName()
    local spsRoot = spsRootOf()
    local group = spsRoot ~= nil and findChild(spsRoot, "pipeHolders") or nil
    if group ~= nil and getNumOfChildren(group) > 0 then return getName(getChildAt(group, 0)) end
    return nil
end

-- placementPipes/ : next to this mod, found by walking up from the open scene file
local function donorDir()
    local scene = getSceneFilename ~= nil and getSceneFilename() or nil
    if scene == nil or scene == "" then return nil end
    local dir = string.gsub(scene, "\\", "/")
    for _ = 1, 12 do
        dir = string.match(dir, "^(.*)/[^/]*$")
        if dir == nil or dir == "" then break end
        if fileExists(dir .. "/placementPipes/pipe_FM.i3d") then return dir .. "/placementPipes/" end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------
local function capture(holder, pipeRoot, name)
    if holder == nil then say("ERROR: no holder chosen (needs a node named SPS_pipeHolderNN in the scene)"); return end
    if pipeRoot == nil then say("ERROR: no pipe chosen"); return end
    if name == nil or name == "" then say("ERROR: give the placement a name (slurry, water_a, ...)"); return end
    local bodies = bodiesOf(pipeRoot)
    if #bodies < 2 then say("ERROR: '%s' has no pipe bodies", getName(pipeRoot)); return end
    local old = findChild(holder, name)
    if old ~= nil then
        say("replacing the existing placement '%s' under '%s'", name, getName(holder))
        delete(old)
    end
    local group = createTransformGroup(name)
    link(holder, group)
    setTranslation(group, 0, 0, 0)
    setRotation(group, 0, 0, 0)
    for k, b in ipairs(bodies) do
        local p = createTransformGroup(string.format("p%02d", k))
        link(group, p)
        local x, y, z = getWorldTranslation(b.bone)
        local rx, ry, rz = getWorldRotation(b.bone)
        setWorldTranslation(p, x, y, z)
        setWorldRotation(p, rx, ry, rz)
    end
    local family = string.find(string.lower(name .. (getName(pipeRoot) or "")), "water", 1, true) and "water" or "slurry"
    if setUserAttribute ~= nil then
        setUserAttribute(group, "spsPipeFamily", "String", family)
        setUserAttribute(group, "spsPlacement", "String", string.format("%d points, bones of '%s' (SPS_PipePlacement.lua)", #bodies, getName(pipeRoot)))
    end
    say("'%s/%s': %d points written from the %d bones of '%s'. XML: <placement node=\"%s\" pipes=\"%s\"/> on that holder.",
        getName(holder), name, #bodies, #bodies, getName(pipeRoot), name, family == "water" and "WATER MILK" or "FM FF MM")
end

-- builds <SPS root>/pipeHolders/<attachName>/pipeHolder/SPS_pipeHolderNN (existing levels are reused); returns the
-- new holder's name
local function createPipeSet(attachName)
    attachName = attachName ~= nil and string.gsub(attachName, "^%s*(.-)%s*$", "%1") or ""
    if attachName == "" then
        say("ERROR: fill in 'Attach to' = the name of the vehicle node the pipe set is linked onto (e.g. profi2_vis)")
        return nil
    end
    local spsRoot = spsRootOf()
    if spsRoot == nil then
        say("ERROR: the scene is empty - open the vehicle's SPS nodeTree.i3d (its first root node is the SPS root)")
        return nil
    end
    -- the attach node is a node of the VEHICLE i3d; the SPS root (and any SPS_ node) only exists in this file, so the
    -- game would find nothing to link onto (William 2026-10-23: SPS_Cobra_vis / SPS_pgII20Genesis instead of
    -- Cobra_vis / pgII20Genesis_vis -> "SPS_pipeHolder01 not found")
    if attachName == getName(spsRoot) or string.sub(attachName, 1, 4) == "SPS_" then
        say("ERROR: 'Attach to' = '%s' is an SPS node of this file, not a node of the vehicle. Use the name of the tanker node the rack sits on, as it is in the VEHICLE's own i3d (e.g. Cobra_vis, pgII20Genesis_vis, hoseHolderLeft)", attachName)
        return nil
    end
    local selected = (getNumSelected() > 0) and getSelection(0) or nil
    local sx, sy, sz
    if selected ~= nil then sx, sy, sz = getWorldTranslation(selected) end

    local group, newGroup = findOrCreate(spsRoot, "pipeHolders")
    local container, newContainer = findOrCreate(group, attachName)
    local holderParent, newParent = findOrCreate(container, "pipeHolder")

    local maxN = 0
    for _, h in ipairs(findHolders()) do
        local n = tonumber(string.match(h.name, "(%d+)$")) or 0
        if n > maxN then maxN = n end
    end
    local name = string.format("SPS_pipeHolder%02d", maxN + 1)
    local holder = createTransformGroup(name)
    link(holderParent, holder)
    setTranslation(holder, 0, 0, 0)
    setRotation(holder, 0, 0, 0)
    if sx ~= nil then setWorldTranslation(holder, sx, sy, sz) end

    say("pipe set: %s/pipeHolders%s/%s%s/pipeHolder%s/%s%s", getName(spsRoot), newGroup and " (new)" or "",
        attachName, newContainer and " (new)" or "", newParent and " (new)" or "", name,
        sx ~= nil and string.format(" at the selected node '%s'", getName(selected)) or " at the attach origin - move it to the rack")
    say('XML (vehicle <slurryPipeSystem>): <pipeHolders> ... <pipeHolder id="%d" nodeName="%s" radius="1.0"/> ... </pipeHolders>',
        maxN + 1, name)
    say("'%s' must be a node of the VEHICLE i3d - the game links the pipe set onto it by that name", attachName)
    return name
end

-- every captured slot in the scene: a child of an SPS_pipeHolderNN that has p01.. children
local function pointsOf(slot)
    local pts = {}
    for i = 0, getNumOfChildren(slot) - 1 do
        local c = getChildAt(slot, i)
        local n = tonumber(string.match(getName(c) or "", "^p(%d+)$"))
        if n ~= nil then pts[#pts + 1] = { node = c, order = n } end
    end
    table.sort(pts, function(a, b) return a.order < b.order end)
    return pts
end

local function findSlots()
    local out = {}
    for _, h in ipairs(findHolders()) do
        for i = 0, getNumOfChildren(h.node) - 1 do
            local c = getChildAt(h.node, i)
            local count = #pointsOf(c)
            if count >= 2 then
                out[#out + 1] = { node = c, name = h.name .. "/" .. (getName(c) or "?"), count = count }
            end
        end
    end
    return out
end

-- loads a donor at the bottom of the scene and lays its bones on the slot's points (bone k = point pk, world position
-- + rotation, parent bones first so the chain follows)
local function importOntoSlot(slot, donor)
    if slot == nil then say("ERROR: no captured slot chosen (a holder child with p01..pNN)"); return end
    local dir = donorDir()
    if dir == nil then say("ERROR: placementPipes/ not found above the open scene - open a node tree that lives inside FS25_SlurryPipeSystem"); return end
    local path = dir .. donor.file
    if not fileExists(path) then say("ERROR: %s not found", path); return end
    local pts = pointsOf(slot.node)
    local fileRoot = loadI3DFile(path, false, false, false)
    if fileRoot == nil or fileRoot == 0 then say("ERROR: loadI3DFile failed for %s", path); return end
    local pipeRoot = getChildAt(fileRoot, 0)
    link(getRootNode(), pipeRoot)
    delete(fileRoot)
    local bodies = bodiesOf(pipeRoot)
    if #bodies ~= #pts then
        say("WARNING: %s has %d bones but '%s' has %d points - only the first %d are placed (4 m pipes = 13, 6 m = 19)",
            donor.file, #bodies, slot.name, #pts, math.min(#bodies, #pts))
    end
    for k = 1, math.min(#bodies, #pts) do
        local x, y, z = getWorldTranslation(pts[k].node)
        local rx, ry, rz = getWorldRotation(pts[k].node)
        setWorldTranslation(bodies[k].bone, x, y, z)
        setWorldRotation(bodies[k].bone, rx, ry, rz)
    end
    setName(pipeRoot, string.format("%s_on_%s", getName(pipeRoot) or "pipe", getName(slot.node) or "slot"))
    say("'%s' laid on '%s' (%d bones) at the bottom of the scene - pose / capture as usual, delete it when done",
        getName(pipeRoot), slot.name, math.min(#bodies, #pts))
end

local function importDonor(donor)
    local dir = donorDir()
    if dir == nil then say("ERROR: placementPipes/ not found above the open scene - open a node tree that lives inside FS25_SlurryPipeSystem"); return end
    local path = dir .. donor.file
    if not fileExists(path) then say("ERROR: %s not found", path); return end
    local parent = (getNumSelected() > 0) and getSelection(0) or getRootNode()
    local fileRoot = loadI3DFile(path, false, false, false)
    if fileRoot == nil or fileRoot == 0 then say("ERROR: loadI3DFile failed for %s", path); return end
    local pipeRoot = getChildAt(fileRoot, 0)
    link(parent, pipeRoot)
    delete(fileRoot)
    say("imported %s as '%s' under '%s' - position its root, pose its BONES, then pick it below and Create nodes", donor.file, getName(pipeRoot), getName(parent))
end

-- ---------------------------------------------------------------------------
-- window
-- ---------------------------------------------------------------------------
function SPSPipePlacement.open(selectHolderName)
    local self = {}
    if g_spsPipePlacementWindow ~= nil and g_spsPipePlacementWindow.frame ~= nil then
        g_spsPipePlacementWindow.frame:close()
    end
    g_spsPipePlacementWindow = self

    self.holders = findHolders()
    self.pipes   = findPipes()
    self.slots   = findSlots()
    self.slotIdx, self.slotDonorIdx = 1, 4
    self.holderIdx, self.pipeIdx, self.donorIdx = 1, 1, 2
    for i, h in ipairs(self.holders) do
        if h.name == selectHolderName then self.holderIdx = i end
    end

    local holderLabels, pipeLabels, donorLabels = {}, {}, {}
    for i, h in ipairs(self.holders) do holderLabels[i] = h.name end
    for i, p in ipairs(self.pipes) do pipeLabels[i] = string.format("%s (%d bodies)", p.name, p.count) end
    for i, d in ipairs(DONORS) do donorLabels[i] = d.label end
    if #holderLabels == 0 then holderLabels[1] = "(no SPS_pipeHolderNN node in the scene)" end
    if #pipeLabels == 0 then pipeLabels[1] = "(no posed pipe in the scene - import one above)" end

    local W = 440
    local frameSizer = UIRowLayoutSizer.new()
    self.frame = UIWindow.new(frameSizer, "SPS Pipe Placement")
    local borderSizer = UIRowLayoutSizer.new()
    UIPanel.new(frameSizer, borderSizer)
    local rows = UIRowLayoutSizer.new()
    UIPanel.new(borderSizer, rows, -1, -1, W, -1, BorderDirection.ALL, 10, 1)

    local function row(labelText)
        local col = UIColumnLayoutSizer.new()
        UIPanel.new(rows, col, -1, -1, -1, -1, BorderDirection.BOTTOM, 8)
        UILabel.new(col, labelText, false, TextAlignment.LEFT, VerticalAlignment.CENTER, -1, -1, 110)
        return col
    end
    local function note(text)
        UILabel.new(rows, text, false, TextAlignment.LEFT, VerticalAlignment.TOP, -1, -1, W - 20, -1, BorderDirection.BOTTOM, 6)   -- TOP: label sits in a row sizer
    end

    -- STEP 0: a new pipe set = the holder node structure on the vehicle
    note("0. New pipe set: builds pipeHolders > <attach node> > pipeHolder > SPS_pipeHolderNN (next free number). Select a node first to place the holder there.")
    local c0 = row("Attach to")
    self.attachBox = UITextArea.new(c0, existingAttachName() or "", TextAlignment.LEFT, false, false, -1, -1, 300, -1, -1, 0)
    local b0 = UIColumnLayoutSizer.new()
    UIPanel.new(rows, b0, -1, -1, -1, -1, BorderDirection.BOTTOM, 8)
    UIButton.new(b0, "Create pipe set", function()
        local made = createPipeSet(self.attachBox:getValue())
        if made ~= nil then SPSPipePlacement.open(made) end
    end, nil, -1, -1, 140, 26, BorderDirection.RIGHT, 10, 0)

    UIHorizontalLine.new(rows, -1, -1, -1, -1, BorderDirection.BOTTOM, 8, 0)

    -- STEP 1: import a donor pipe, position its root, pose its bones
    note("1. Import a pipe (under the selected node, else the scene root), position its root, pose its BONES.")
    local c5 = row("Donor")
    UIChoice.new(c5, donorLabels, 1, -1, 300, -1):setOnChangeCallback(function(value) self.donorIdx = tonumber(value) or 2 end)
    local b2 = UIColumnLayoutSizer.new()
    UIPanel.new(rows, b2, -1, -1, -1, -1, BorderDirection.BOTTOM, 8)
    UIButton.new(b2, "Import pipe", function()
        importDonor(DONORS[self.donorIdx] or DONORS[2])
        local h = self.holders[self.holderIdx]
        SPSPipePlacement.open(h and h.name)
    end, nil, -1, -1, 140, 26, BorderDirection.RIGHT, 10, 0)

    UIHorizontalLine.new(rows, -1, -1, -1, -1, BorderDirection.BOTTOM, 8, 0)

    -- STEP 2: holder + posed pipe + name -> create the nodes
    note("2. Pick the holder and the posed pipe, name the placement, create the nodes. Then delete the posed pipe.")
    local c1 = row("Holder")
    UIChoice.new(c1, holderLabels, self.holderIdx - 1, -1, 300, -1):setOnChangeCallback(function(value) self.holderIdx = tonumber(value) or 1 end)
    local c2 = row("Pipe")
    UIChoice.new(c2, pipeLabels, 0, -1, 300, -1):setOnChangeCallback(function(value) self.pipeIdx = tonumber(value) or 1 end)
    local c3 = row("Name")
    self.nameBox = UITextArea.new(c3, "slurry", TextAlignment.LEFT, false, false, -1, -1, 300, -1, -1, 0)

    local b1 = UIColumnLayoutSizer.new()
    UIPanel.new(rows, b1, -1, -1, -1, -1, BorderDirection.BOTTOM, 4)
    UIButton.new(b1, "Create nodes", function()
        local h = self.holders[self.holderIdx]
        local p = self.pipes[self.pipeIdx]
        capture(h and h.node, p and p.node, self.nameBox:getValue())
    end, nil, -1, -1, 140, 26, BorderDirection.RIGHT, 10, 0)
    UIButton.new(b1, "Refresh lists", function()
        local h = self.holders[self.holderIdx]
        SPSPipePlacement.open(h and h.name)
    end, nil, -1, -1, 140, 26, BorderDirection.RIGHT, 10, 0)

    UIHorizontalLine.new(rows, -1, -1, -1, -1, BorderDirection.BOTTOM, 8, 0)

    -- STEP 3: show a pipe on a slot that is already captured
    note("3. Show a pipe on a captured slot: pick the slot and a donor (same length: 13 points = 4 m, 19 = 6 m), Import onto slot. Delete it when done.")
    local slotLabels = {}
    for i, sl in ipairs(self.slots) do slotLabels[i] = string.format("%s (%d points)", sl.name, sl.count) end
    if #slotLabels == 0 then slotLabels[1] = "(no captured slot in the scene)" end
    local c6 = row("Slot")
    UIChoice.new(c6, slotLabels, 0, -1, 300, -1):setOnChangeCallback(function(value) self.slotIdx = tonumber(value) or 1 end)
    local c7 = row("Pipe")
    UIChoice.new(c7, donorLabels, self.slotDonorIdx - 1, -1, 300, -1):setOnChangeCallback(function(value) self.slotDonorIdx = tonumber(value) or 4 end)
    local b3 = UIColumnLayoutSizer.new()
    UIPanel.new(rows, b3, -1, -1, -1, -1, BorderDirection.BOTTOM, 4)
    UIButton.new(b3, "Import onto slot", function()
        importOntoSlot(self.slots[self.slotIdx], DONORS[self.slotDonorIdx] or DONORS[4])
        local h = self.holders[self.holderIdx]
        SPSPipePlacement.open(h and h.name)
    end, nil, -1, -1, 140, 26, BorderDirection.RIGHT, 10, 0)

    self.frame:showWindow()
    say("holders: %d, posed pipes: %d, captured slots: %d", #self.holders, #self.pipes, #self.slots)
end

SPSPipePlacement.open()
