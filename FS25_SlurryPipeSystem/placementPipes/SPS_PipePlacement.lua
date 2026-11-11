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

source("EditorSettings.lua")
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
    -- [SPS 2026-11-10] the 550 Water/Chem Bowser's three pipes (tools/build_bowser_donors.py). Their hose keys start
    -- WT_, which is the "bowser" stow family: name the slot explicitly in the XML, e.g.
    --   <placement node="bowserSuction01" pipes="WT_SUCTION"/>  <placement node="bowserSmall01" pipes="WT_SMALL"/>
    { file = "pipe_bowserSuction.i3d", label = "pipe_bowserSuction (550 bowser suction, 25 bodies)" },
    { file = "pipe_bowserWash.i3d",    label = "pipe_bowserWash (550 bowser wash hose, 19 bodies)" },
    { file = "pipe_bowserSmall.i3d",   label = "pipe_bowserSmall (550 bowser small hose, 25 bodies)" },
}

local function say(fmt, ...) print("[SPS placement] " .. string.format(fmt, ...)) end

-- Editor labels don't wrap long text (it gets cut off at the window edge), so notes are wrapped by hand.
-- Long words (paths) are split after a slash. Same approach as MapOverviewTool's wrapDialogText.
local NOTE_LINE_LENGTH = 62
local function wrapText(text, lineLength)
    local maxLength = lineLength or NOTE_LINE_LENGTH
    local out = {}
    for line in string.gmatch((text or "") .. "\n", "(.-)\n") do
        local current = ""
        for word in string.gmatch(line, "%S+") do
            while word ~= "" do
                local sep = current == "" and "" or " "
                local room = maxLength - #current - #sep
                if #word <= room then
                    current = current .. sep .. word
                    word = ""
                else
                    local cut = nil
                    if room > 10 then cut = string.find(string.sub(word, 1, room), "[/\\][^/\\]*$") end
                    if cut == nil and current == "" then cut = maxLength end
                    if cut ~= nil then
                        current = current .. sep .. string.sub(word, 1, cut)
                        word = string.sub(word, cut + 1)
                    end
                    out[#out + 1] = current
                    current = ""
                end
            end
        end
        out[#out + 1] = current
    end
    return table.concat(out, "\n")
end

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

-- ---------------------------------------------------------------------------
-- [2026-11-02] SPLIT / REJOIN BONES (William: the Bone01 > Bone02 > ... chain is what the script needs, but it gets in
-- the way when placing bones by hand). Split: every bone of the selected pipe becomes a direct child of the pipe MESH
-- (the node that holds Bone01), keeping its world position + rotation, so each bone can be moved on its own. Rejoin:
-- Bone(k) goes back under Bone(k-1), again keeping world transforms, so the chain the capture / import code reads is
-- back. Selection: the pipe root, the mesh or any of its bones.
-- ---------------------------------------------------------------------------
local function boneNumber(node)
    return tonumber(string.match(getName(node) or "", "^Bone(%d+)$"))
end

-- every BoneNN below `mesh`, sorted by number, wherever it sits now (chain or flat)
local function collectBones(mesh)
    local list = {}
    walk(mesh, function(n) if n ~= mesh and isBone(n) then list[#list + 1] = n end end)
    table.sort(list, function(a, b) return boneNumber(a) < boneNumber(b) end)
    return list
end

-- the mesh node of the pipe the selection belongs to: a non-bone node with a Bone child, found on the node itself,
-- one level below it (the pipe root) or above it (a selected bone)
local function findBoneMesh(node)
    local n = node
    for _ = 1, 10 do
        if n == nil or n == 0 then return nil end
        if not isBone(n) and boneChild(n) ~= nil then return n end
        if not isBone(n) then
            for i = 0, getNumOfChildren(n) - 1 do
                local c = getChildAt(n, i)
                if not isBone(c) and boneChild(c) ~= nil then return c end
            end
        end
        n = getParent(n)
    end
    return nil
end

local function relinkKeepWorld(child, newParent)
    local x, y, z = getWorldTranslation(child)
    local rx, ry, rz = getWorldRotation(child)
    link(newParent, child)
    setWorldTranslation(child, x, y, z)
    setWorldRotation(child, rx, ry, rz)
end

local function selectedBoneMesh()
    if getNumSelected() == 0 then say("ERROR: select the pipe (its root, mesh or a bone) first"); return nil end
    local mesh = findBoneMesh(getSelection(0))
    if mesh == nil then say("ERROR: '%s' is not part of a pipe with Bone01.. bones", getName(getSelection(0)) or "?"); return nil end
    return mesh
end

local function splitBones()
    local mesh = selectedBoneMesh()
    if mesh == nil then return end
    local bones = collectBones(mesh)
    if #bones < 2 then say("ERROR: '%s' has %d bone(s) - nothing to split", getName(mesh), #bones); return end
    local moved = 0
    for _, b in ipairs(bones) do          -- in number order: a parent is re-linked before its children, world kept
        if getParent(b) ~= mesh then relinkKeepWorld(b, mesh); moved = moved + 1 end
    end
    say("'%s': %d bones split - all %d are direct children of the mesh now (world positions kept). Move them, then Rejoin bones. The pipe is NOT listed in 'Pipe' / 'Create nodes' while split.",
        getName(mesh), moved, #bones)
end

local function rejoinBones()
    local mesh = selectedBoneMesh()
    if mesh == nil then return end
    local bones = collectBones(mesh)
    if #bones < 2 then say("ERROR: '%s' has %d bone(s) - nothing to rejoin", getName(mesh), #bones); return end
    for k = 2, #bones do
        if boneNumber(bones[k]) ~= boneNumber(bones[k - 1]) + 1 then
            say("WARNING: bone numbers are not continuous (%s after %s) - chaining them anyway", getName(bones[k]), getName(bones[k - 1]))
        end
    end
    local moved = 0
    if getParent(bones[1]) ~= mesh then relinkKeepWorld(bones[1], mesh); moved = moved + 1 end
    for k = 2, #bones do
        if getParent(bones[k]) ~= bones[k - 1] then relinkKeepWorld(bones[k], bones[k - 1]); moved = moved + 1 end
    end
    say("'%s': chain rebuilt Bone01 > ... > Bone%02d (%d re-linked, world positions kept) - Refresh lists to pick it again",
        getName(mesh), boneNumber(bones[#bones]) or #bones, moved)
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

-- The donor folder picked by hand in the window (only asked for when auto-detection fails) is remembered in the
-- editor's configs folder (EditorSettings "spsPipePlacement", key donorFolder) - same as MapOverviewTool's settings.
local CONFIG_NAME = "spsPipePlacement"
local CONFIG_KEY_DONOR_DIR = "donorFolder"

-- reads the remembered donor folder ("" when none / EditorSettings unavailable)
local function loadSavedDonorDir()
    if EditorSettings == nil then return "" end
    local ok, value = pcall(function()
        local config = EditorSettings.new(CONFIG_NAME)
        local v = config:getValue(CONFIG_KEY_DONOR_DIR, "")
        config:delete()
        return v
    end)
    return (ok and type(value) == "string") and value or ""
end

-- writes the donor folder to the configs folder; returns true when saved
local function saveDonorDir(dir)
    if EditorSettings == nil then return false end
    local ok = pcall(function()
        local config = EditorSettings.new(CONFIG_NAME)
        config:setValue(CONFIG_KEY_DONOR_DIR, dir or "")
        config:saveSettings()
        config:delete()
    end)
    return ok
end

-- folder names the SPS mod may be unpacked under (checked as siblings of every folder above the open scene)
local SPS_MOD_FOLDERS = { "FS25_SlurryPipeSystem", "FS25_SlurryPipeSystem-main", "FS25_SlurryPipeSystem_dev" }

local function normDir(path)
    if path == nil or path == "" then return nil end
    path = string.gsub(path, "\\", "/")
    if string.sub(path, -1) ~= "/" then path = path .. "/" end
    return path
end

local function hasDonors(dir)
    return dir ~= nil and fileExists(dir .. "pipe_FM.i3d")
end

-- checks <dir>/placementPipes/ and <dir>/<SPS mod folder>/placementPipes/
local function donorDirIn(dir)
    local d = normDir(dir)
    if d == nil then return nil end
    if hasDonors(d .. "placementPipes/") then return d .. "placementPipes/" end
    for _, modName in ipairs(SPS_MOD_FOLDERS) do
        local cand = d .. modName .. "/placementPipes/"
        if hasDonors(cand) then return cand end
    end
    return nil
end

-- walks up from a file/folder path, testing every parent with donorDirIn
local function donorDirAbove(path)
    if path == nil or path == "" then return nil end
    local dir = (string.gsub(path, "\\", "/"))
    for _ = 1, 12 do
        dir = string.match(dir, "^(.*)/[^/]*$")
        if dir == nil or dir == "" then break end
        local found = donorDirIn(dir)
        if found ~= nil then return found end
    end
    return nil
end

-- placementPipes/ : found in this order
--   1. walking up from the open scene: inside the scene's own mod, OR in a sibling FS25_SlurryPipeSystem mod
--      (a node tree open in mods/FS25_majorLGP2050_2400/... finds mods/FS25_SlurryPipeSystem/placementPipes/).
--      This comes FIRST so the copy of the SPS mod the open scene belongs to always wins over a remembered folder.
--   2. the remembered donor folder from the configs folder (set with Browse / Set folder in the window)
--   3. the folder this script was run from (the script ships in placementPipes/)
--   4. the user's FS25 mods folder (getUserProfileAppPath, if the editor exposes it)
local cachedDonorDir = nil
local function donorDir()
    if cachedDonorDir ~= nil and hasDonors(cachedDonorDir) then return cachedDonorDir end
    local found = nil

    -- 1. above the open scene (own mod, or sibling SPS mod in the same mods folder)
    local scene = getSceneFilename ~= nil and getSceneFilename() or nil
    found = donorDirAbove(scene)

    -- 2. remembered donor folder (configs folder)
    if found == nil then
        local saved = loadSavedDonorDir()
        if saved ~= "" then
            local d = normDir(saved)
            if hasDonors(d) then
                found = d
            else
                say("WARNING: remembered donor folder '%s' has no pipe_FM.i3d any more - trying the other locations", saved)
            end
        end
    end

    -- 3. this script's own location (getinfo must run inside a function of THIS file: level 1 = that function)
    if found == nil and debug ~= nil and debug.getinfo ~= nil then
        local ok, info = pcall(function() return debug.getinfo(1, "S") end)
        local src = ok and info ~= nil and info.source or nil
        if src ~= nil and string.sub(src, 1, 1) == "@" then
            src = (string.gsub(string.sub(src, 2), "\\", "/"))
            local own = string.match(src, "^(.*/)[^/]*$")
            if hasDonors(own) then found = own else found = donorDirAbove(src) end
        end
    end

    -- 4. the user's FS25 mods folder
    if found == nil and getUserProfileAppPath ~= nil then
        local ok, profile = pcall(getUserProfileAppPath)
        if ok and profile ~= nil and profile ~= "" then
            found = donorDirIn(normDir(profile) .. "mods")
        end
    end

    if found ~= nil then
        say("donor pipes: %s", found)
        cachedDonorDir = found
    end
    return found
end

local DONOR_DIR_ERROR = "ERROR: placementPipes/ not found - looked above the open scene and in a sibling FS25_SlurryPipeSystem mod folder (it must be UNZIPPED). Set the donor folder in the window - it is remembered from then on."

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
    if dir == nil then say(DONOR_DIR_ERROR); return end
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
    if dir == nil then say(DONOR_DIR_ERROR); return end
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
        UILabel.new(rows, wrapText(text), false, TextAlignment.LEFT, VerticalAlignment.TOP, -1, -1, W - 20, -1, BorderDirection.BOTTOM, 6)   -- TOP: label sits in a row sizer
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

    -- DONOR FOLDER: always shown, so a wrong remembered folder can be changed. Auto-detection (the open scene's own
    -- SPS copy, else the remembered folder, else the script's / the mods folder) fills it in; Browse / Set folder
    -- override it for this run and remember it for scenes that have no SPS copy of their own.
    local currentDonor = donorDir()
    if currentDonor == nil then
        note("placementPipes/ was NOT found automatically. Click Browse and pick the SPS mod's placementPipes folder (the one with pipe_FM.i3d) - or the FS25_SlurryPipeSystem folder itself. It is remembered from then on.")
    else
        note("Donor pipes: " .. currentDonor .. " (auto-detected - Browse / Set folder to use another copy; remembered for scenes without an SPS copy next to them)")
    end

    -- accepts the placementPipes folder itself, or a folder that contains it (the SPS mod folder / the mods folder)
    local function applyDonorFolder(value)
        value = string.gsub(value or "", "^%s*\"?(.-)\"?%s*$", "%1")   -- trim spaces / quotes from a pasted path
        local d = normDir(value)
        if d ~= nil and not hasDonors(d) then d = donorDirIn(d) end
        if d == nil or not hasDonors(d) then
            say("ERROR: no pipe_FM.i3d in '%s' - pick the placementPipes folder of the unzipped FS25_SlurryPipeSystem mod", value)
            return
        end
        cachedDonorDir = d
        if saveDonorDir(d) then
            say("donor folder set and remembered: %s", d)
        else
            say("donor folder set: %s (could not write it to the configs folder - it is kept until the script is run again)", d)
        end
        local h = self.holders[self.holderIdx]
        SPSPipePlacement.open(h and h.name)
    end

    local cd = row("Donor folder")
    self.donorDirBox = UITextArea.new(cd, currentDonor or loadSavedDonorDir(), TextAlignment.LEFT, false, false, -1, -1, 220, -1, -1, 0)
    UIButton.new(cd, "Browse...", function()
        if openDirDialog == nil then say("ERROR: this editor has no folder dialog - type the path and click Set folder"); return end
        local start = self.donorDirBox:getValue() or ""
        local folder = openDirDialog(start)
        if folder == nil or string.match(folder, "^%s*$") then return end   -- cancelled
        self.donorDirBox:setValue(folder)
        applyDonorFolder(folder)
    end, nil, -1, -1, 75, 24, BorderDirection.LEFT, 6, 0)

    local bd = UIColumnLayoutSizer.new()
    UIPanel.new(rows, bd, -1, -1, -1, -1, BorderDirection.BOTTOM, 8)
    UIButton.new(bd, "Set folder", function()
        applyDonorFolder(self.donorDirBox:getValue())
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

    -- 1b. bones of the SELECTED pipe: split flat for free placing, rejoin into the chain afterwards
    note("1b. Posing help: select the pipe (root, mesh or a bone). Split bones makes every bone a direct child of the mesh so each can be moved on its own; Rejoin bones puts the Bone01 > Bone02 > ... chain back. World positions are kept both ways.")
    local b2b = UIColumnLayoutSizer.new()
    UIPanel.new(rows, b2b, -1, -1, -1, -1, BorderDirection.BOTTOM, 8)
    UIButton.new(b2b, "Split bones", function() splitBones() end, nil, -1, -1, 140, 26, BorderDirection.RIGHT, 10, 0)
    UIButton.new(b2b, "Rejoin bones", function()
        rejoinBones()
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
