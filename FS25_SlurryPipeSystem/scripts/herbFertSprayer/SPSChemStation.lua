-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.2.0

-- SPSChemStation.lua — [SPS CHEM 2026-10-29] the chem station on an SPS sprayer (toggle: featureToggles.chemMixing)
--
-- Real life: concentrate goes into the chem bowl (induction hopper) by hand, water goes in through the fill pipe,
-- the two mix in the tank; two chemicals never mix without a washout in between; water on its own through the tank
-- IS the washout.
--
-- [SPS CHEM 2026-11-05] The tank books, the water / washout rules and the WATER spraying moved to SPSChemMix (type
-- level, every sprayer - concentrate can go in through any sprayer's lid). What stays here is what only a sprayer
-- with a <chemStation> has:
--   getFillUnitIndexFromNode  the bowl's FILLABLE shape answers "the sprayer tank" while the toggle is on, and
--                             remembers that the last raycast hit was the bowl (instance override)
--   checkConcentratePour      concentrate only with the door open, the bowl out and - poured by hand - into the bowl
-- entry.chem is the same table as vehicle.spsChemMix (SPSChemMix.getState).

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSChemStation 1.0.2.0 loaded") end

SPSChemStation = {}

local function clog(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("SPSChemStation") then return end
    if select("#", ...) > 0 then
        print("[SPS CHEM] " .. string.format(fmt, ...))
    else
        print("[SPS CHEM] " .. tostring(fmt))
    end
end

local function warn(key, fallback)
    local txt = fallback
    if g_i18n ~= nil and g_i18n:hasText(key) then txt = g_i18n:getText(key) end
    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(txt, 2500)
    end
end

local function ftName(ft)
    return (ft ~= nil and g_fillTypeManager:getFillTypeNameByIndex(ft)) or "?"
end

function SPSChemStation.isOn()
    return SPSChemMix ~= nil and SPSChemMix.isOn()
end

-- ---------------------------------------------------------------------------
-- State helpers
-- ---------------------------------------------------------------------------
function SPSChemStation.sprayerFillUnit(entry)
    if entry.couplings ~= nil and #entry.couplings > 0 then
        return entry.couplings[1].fillUnitIndex or 1
    end
    return 1
end

function SPSChemStation.bowlIsOut(entry)
    local cs = entry.chemStation
    if cs == nil or cs.bowlAnim == nil then return true end   -- no bowl declared: nothing to fold out
    for _, aca in ipairs(entry.animationControlActivatables or {}) do
        if aca.animName == cs.bowlAnim then return aca:_isOut() end
    end
    local v = entry.object
    if v ~= nil and v.getAnimationTime ~= nil and v:getAnimationExists(cs.bowlAnim) then
        return (v:getAnimationTime(cs.bowlAnim) or 0) > 0.5
    end
    return false
end

function SPSChemStation.doorIsOpen(entry)
    local c = entry.couplings ~= nil and entry.couplings[1] or nil
    if c == nil or c.loadAnimationName == nil then return true end   -- no door declared
    return c.loadAnimPlayed == true
end

-- ---------------------------------------------------------------------------
-- Install (called from registerSprayerVehicle after the couplings / controls exist)
-- ---------------------------------------------------------------------------
function SPSChemStation.install(vehicle, entry)
    if vehicle == nil or entry == nil or entry._chemInstalled then return end
    entry._chemInstalled = true
    entry.chem = (SPSChemMix ~= nil and SPSChemMix.getState(vehicle)) or entry.chem
    local fui = SPSChemStation.sprayerFillUnit(entry)

    -- bowl shape -> sprayer tank; remember the last hit.
    -- The pour raycast resolves a hit shape to its vehicle through g_currentMission:getNodeObject, which only
    -- knows nodes registered with addNodeObject - FillUnit does that for exactFillRootNode (FillUnit.lua:1394).
    -- Without it a hit on the bowl shape resolves to nothing and the game ignores it silently.
    if entry.chemStation ~= nil and entry.chemStation.bowlFillNode ~= nil and vehicle.getFillUnitIndexFromNode ~= nil then
        if g_currentMission ~= nil and g_currentMission.addNodeObject ~= nil and entityExists(entry.chemStation.bowlFillNode) then
            g_currentMission:addNodeObject(entry.chemStation.bowlFillNode, vehicle)
            entry._chemNodeObjectAdded = true
        end
        vehicle.getFillUnitIndexFromNode = Utils.overwrittenFunction(vehicle.getFillUnitIndexFromNode,
            function(self, superFunc, node)
                if node == entry.chemStation.bowlFillNode then
                    if not SPSChemStation.isOn() then return nil end
                    -- always a target while the toggle is on: checkConcentratePour refuses with a warning when the
                    -- bowl is in / door shut, instead of a silent "nothing to pour into"
                    local now = g_time or 0
                    if now - (entry._chemBowlHitTime or -1e9) > 1000 then   -- [SPS CHEM 2026-11-09] evidence, once per second
                        clog("bowl shape hit on %s", tostring(vehicle.configFileName))
                    end
                    entry._chemBowlHitTime = now
                    return fui
                end
                return superFunc(self, node)
            end)
    end

    clog("installed on %s (fui=%d bowlFillNode=%s bowlAnim=%s)", tostring(vehicle.configFileName), fui,
        tostring(entry.chemStation and entry.chemStation.bowlFillNode), tostring(entry.chemStation and entry.chemStation.bowlAnim))
end

-- ---------------------------------------------------------------------------
-- The concentrate rule (called from SPSChemMix.addFillLevel, server). A sprayer without a <chemStation> takes
-- concentrate through its lid: always true.
-- ---------------------------------------------------------------------------
function SPSChemStation.checkConcentratePour(vehicle, toolType)
    local m = g_slurryPipeManager
    local entry = m ~= nil and m.getSprayerVehicleEntry ~= nil and m:getSprayerVehicleEntry(vehicle) or nil
    if entry == nil or entry.chemStation == nil then return true end
    if not SPSChemStation.doorIsOpen(entry) then
        clog("refused: door shut")
        warn("warning_spsChemDoor", "Open the chem station door first")
        return false
    end
    if not SPSChemStation.bowlIsOut(entry) then
        clog("refused: bowl not out")
        warn("warning_spsChemBowl", "Fold out the chem bowl to add chemical")
        return false
    end
    -- a hand pour must land IN the bowl, not on the tank (a pipe / trigger into the bowl is fine)
    if toolType ~= ToolType.TRIGGER and entry.chemStation.bowlFillNode ~= nil
    and (g_time or 0) - (entry._chemBowlHitTime or -1e9) > 500 then
        clog("refused: hand pour did not come through the bowl shape")
        warn("warning_spsChemUseBowl", "Pour the chemical into the bowl")
        return false
    end
    return true
end

-- Console: spsChemInfo - state of every registered sprayer + where its bowl fill shape sits
function SPSChemStation:consoleInfo()
    local m = g_slurryPipeManager
    if m == nil then return "SPS not loaded" end
    local out = { string.format("chemMixing=%s", tostring(SPSChemStation.isOn())) }
    for _, e in ipairs(m.registeredSprayerVehicles or {}) do
        local v = e.object
        local c = (SPSChemMix ~= nil and SPSChemMix.getState(v)) or e.chem or {}
        local fui = SPSChemStation.sprayerFillUnit(e)
        local line = string.format("%s: tank %s %.0f l | chem=%s %.0f l water %.0f l washing=%s dirty=%s | door=%s bowl=%s",
            tostring(v and v.configFileName), ftName(v and v:getFillUnitFillType(fui)), v and v:getFillUnitFillLevel(fui) or 0,
            ftName(c.type), c.chemL or 0, c.waterL or 0, tostring(c.washing), ftName(c.dirtyWith),
            tostring(SPSChemStation.doorIsOpen(e)), tostring(SPSChemStation.bowlIsOut(e)))
        local cs = e.chemStation
        if cs ~= nil and cs.bowlFillNode ~= nil and entityExists(cs.bowlFillNode) then
            local _, by = getWorldTranslation(cs.bowlFillNode)
            local _, ty = getWorldTranslation(v.rootNode)
            line = line .. string.format(" | bowl fill shape %.2f m above the vehicle root", by - ty)
        end
        if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
            local _, py = getWorldTranslation(g_localPlayer.rootNode)
            line = line .. string.format(" | player feet y %.2f", py)
        end
        table.insert(out, line)
    end
    -- [SPS CHEM 2026-11-09] liquid carriers with a chem bowl (550 Water/Chem Bowser): tank + books + bowl shape
    for _, e in ipairs(m.registeredLiquidLaneVehicles or {}) do
        local v = e.object
        if e.chemStation ~= nil and v ~= nil then
            local c = (SPSChemMix ~= nil and SPSChemMix.getState(v)) or e.chem or {}
            local fui = SPSChemStation.sprayerFillUnit(e)
            local line = string.format("%s (carrier): tank %s %.0f l | chem=%s %.0f l water %.0f l | bowl fitted=%s",
                tostring(v.configFileName), ftName(v:getFillUnitFillType(fui)), v:getFillUnitFillLevel(fui) or 0,
                ftName(c.type), c.chemL or 0, c.waterL or 0, tostring(e.chemStation.bowlFillNode ~= nil))
            local cs = e.chemStation
            if cs.bowlFillNode ~= nil and entityExists(cs.bowlFillNode) then
                local _, by = getWorldTranslation(cs.bowlFillNode)
                local _, ty = getWorldTranslation(v.rootNode)
                line = line .. string.format(" | bowl fill shape %.2f m above the vehicle root (rigid body %s)", by - ty,
                    tostring(getRigidBodyType(cs.bowlFillNode)))
            end
            table.insert(out, line)
        end
    end
    for _, l in ipairs(out) do print("[SPS CHEM] " .. l) end
    return table.concat(out, "\n")
end
addConsoleCommand("spsChemInfo", "SPS: chem station state of every registered sprayer", "consoleInfo", SPSChemStation)

-- Called from the sprayer unregister path.
function SPSChemStation.uninstall(entry)
    if entry ~= nil and entry._chemNodeObjectAdded and entry.chemStation ~= nil and entry.chemStation.bowlFillNode ~= nil
    and g_currentMission ~= nil and g_currentMission.removeNodeObject ~= nil then
        g_currentMission:removeNodeObject(entry.chemStation.bowlFillNode)
        entry._chemNodeObjectAdded = nil
    end
end

-- [SPS CHEM 2026-11-09] <chemStation handleAnimation="...">: the bowl's handle swings open while chemical is poured into
-- the bowl (a hit on the fill shape within the last HANDLE_OPEN_MS) and closes again after (William: "when the bowl is
-- active the handle is open and when not its closed"). Runs where the pour is seen (SP / the pouring client).
SPSChemStation.HANDLE_OPEN_MS = 2000
local function tickHandle(e)
    local cs, v = e.chemStation, e.object
    if cs == nil or cs.handleAnim == nil or v == nil or v.getAnimationExists == nil or not v:getAnimationExists(cs.handleAnim) then return end
    local open = (g_time or 0) - (e._chemBowlHitTime or -1e9) < SPSChemStation.HANDLE_OPEN_MS
    if (e._chemHandleOpen == true) ~= open then
        e._chemHandleOpen = open
        v:playAnimation(cs.handleAnim, open and 1 or -1, nil, true)
        clog("handle %s on %s (%s)", open and "OPEN" or "CLOSED", tostring(v.configFileName), tostring(cs.handleAnim))
    end
end
function SPSChemStation.update(dt)
    local m = g_slurryPipeManager
    if m == nil then return end
    for _, e in ipairs(m.registeredSprayerVehicles or {}) do tickHandle(e) end
    for _, e in ipairs(m.registeredLiquidLaneVehicles or {}) do tickHandle(e) end
end

-- Ratio for a readout: litres of water per litre of concentrate (nil = no chemical in)
function SPSChemStation.ratio(entry)
    local c = entry ~= nil and ((SPSChemMix ~= nil and SPSChemMix.getState(entry.object)) or entry.chem) or nil
    if c == nil or c.type == nil or c.chemL <= 0 then return nil end
    return c.waterL / c.chemL
end

-- ---------------------------------------------------------------------------
-- Toggle / ratio changes at runtime
-- ---------------------------------------------------------------------------
function SlurryPipeManager:applyChemMixingSetting()
    if SPSChemMix ~= nil then SPSChemMix.applySetting() end
end

-- ---------------------------------------------------------------------------
-- Save / load. [SPS CHEM 2026-11-05] Books of every sprayer are saved by uniqueId (SPSChemMix.save). The old
-- position-keyed block (slurryPipeSystem.sprayerChem, 2026-10-29 saves) is still read once and applied at register.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_saveSprayerChem(xmlFile)
    if SPSChemMix ~= nil then SPSChemMix.save(xmlFile) end
end

function SlurryPipeManager:_loadSprayerChem(xmlFile)
    if SPSChemMix ~= nil then SPSChemMix.load(xmlFile) end
    self._pendingSprayerChem = {}
    local idx = 0
    while true do
        local base = string.format("slurryPipeSystem.sprayerChem.vehicle(%d)", idx)
        if not xmlFile:hasProperty(base) then break end
        local function ft(s) local i = g_fillTypeManager:getFillTypeIndexByName(s or ""); return (i ~= nil and i ~= FillType.UNKNOWN) and i or nil end
        table.insert(self._pendingSprayerChem, {
            x = xmlFile:getFloat(base .. "#x", 0), y = xmlFile:getFloat(base .. "#y", 0), z = xmlFile:getFloat(base .. "#z", 0),
            chem = { type = ft(xmlFile:getString(base .. "#type")), chemL = xmlFile:getFloat(base .. "#chemL", 0),
                     waterL = xmlFile:getFloat(base .. "#waterL", 0), washing = xmlFile:getBool(base .. "#washing", false),
                     dirtyWith = ft(xmlFile:getString(base .. "#dirtyWith")) },
        })
        idx = idx + 1
    end
end

function SlurryPipeManager:_applyPendingSprayerChem(vehicle, entry)
    if self._pendingSprayerChem == nil or #self._pendingSprayerChem == 0 or vehicle == nil or vehicle.rootNode == nil
    or not entityExists(vehicle.rootNode) then return end
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    for i, p in ipairs(self._pendingSprayerChem) do
        local dx, dy, dz = vx - p.x, vy - p.y, vz - p.z
        if dx * dx + dy * dy + dz * dz <= 0.01 then
            table.remove(self._pendingSprayerChem, i)
            local st = SPSChemMix ~= nil and SPSChemMix.getState(vehicle) or nil
            -- a uniqueId save (chemMix block) wins: getState has already applied it, and that block only exists in
            -- saves written after the 2026-11-05 build, which no longer write this one
            if st ~= nil and not st._fromSave then
                for k, val in pairs(p.chem) do st[k] = val end
                entry.chem = st
                clog("restored chem state (old save) on %s: type=%s chem=%.1f water=%.1f washing=%s dirty=%s",
                    tostring(vehicle.configFileName), ftName(st.type), st.chemL, st.waterL, tostring(st.washing), ftName(st.dirtyWith))
            end
            return
        end
    end
end
