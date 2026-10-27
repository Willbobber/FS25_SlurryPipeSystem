-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.9.24
--
-- SPSChainBondPersistence.lua
-- ---------------------------------------------------------------------------
-- Persists coupling bonds that vanilla-SPS save misses.
--
-- Gap (verified in SlurryPipeManager.saveCouplingConnections): the
-- connections walk covers ONLY registeredVehicles couplings, so any bond with
-- no vehicle on either end is never written to the savegame. In practice that
-- is a chain END terminus bonded to a STORE coupling (the separator workflow:
-- chain anchored at the sep, bez-bonded to a slurry store) and any future
-- store-to-store bond. Field report: on reload the chain itself restores but
-- the bez bond to the store is gone.
--
-- The LOAD side needs nothing: loadCouplingConnections reads every
-- connections.connection(i) generically, chains restore before connections,
-- and findCouplingAtPos already searches placeable store couplings AND
-- chainTerminusEntries (its own comment says chainStartCoupling id=-2 lives
-- there for exactly this). Duplicate entries are tolerated by the restore
-- guard (`not cA.isConnected and not cB.isConnected`).
--
-- So this file only APPENDS the missing bonds: it wraps
-- saveCouplingConnections, reopens the file the original just wrote, and adds
-- connection entries for every bonded storeCoupling / chain terminus whose
-- bond was not already covered by the vehicle walk. Same fields, same format,
-- indices continue where the original stopped. Zero core edits.
-- ---------------------------------------------------------------------------
-- [1.0.0.9.24] Field-report fix (savegame reload duplicated/looped bez pipes):
--
--   Bug A — sideIsVehicle tested `c.vehicle`, a field that does NOT exist on
--   vehicle couplingEntries (registerVehicle stores the vehicle on vEntry,
--   never on the coupling). The exclusion therefore never fired and every
--   vehicle-side bond was re-written REVERSED by the append pass (verified in
--   savegame: connection pairs 0/6, 1/8, 2/3 are exact mirror duplicates).
--   Fixed: vehicle-side detection is now a membership set built from
--   registeredVehicles[].couplingEntries at append time.
--
--   Bug B — chain-start↔anchor bonds were written as connection entries. For
--   localStart chains the chainStartCoupling mountNode COINCIDES with the
--   store coupling mountNode, producing degenerate A==B entries (verified in
--   savegame: connections 4, 5, 7 have identical/near-identical endpoints).
--   On reload, chains restore first WITHOUT marking the anchor store coupling
--   isConnected, then tryResolvePendingConnections resolves the A==B entry:
--   findCouplingAtPos returns the SAME store coupling for both endpoints, the
--   `not isConnected` guard passes, and applyConnectCouplings(sc, sc) creates
--   a bez pipe from the coupler's inNode back to its own outNode — the
--   loop-back pipe seen in the field screenshots. Chain-anchor state is
--   restored by the chain restore itself and must never be a connection
--   entry. Fixed: bonds whose endpoints coincide (< 0.1 m) or whose partner
--   is the coupling itself are skipped on save.
--
--   Dedup — the old `seen` key was `c.pipeId or c`; for a pipeId-less bond
--   the fallback key differs per side so both sides wrote. Fixed: unordered
--   pair key over both coupling refs (pipeId kept as primary when present).
--
--   Load-side sanitizer (NEW) — savegames written by 1.0.0.9.23 already
--   contain degenerate and duplicate entries. loadCouplingConnections is now
--   wrapped: after the original populates mgr.pendingConnections, entries
--   with coincident endpoints are dropped and unordered-pair duplicates are
--   collapsed to their first occurrence. Existing corrupted saves therefore
--   heal on next load/save cycle. Zero core edits.
-- ---------------------------------------------------------------------------

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSChainBondPersistence 1.0.0.9.24 loaded") end

SPSChainBondPersistence = {}

-- Debug: central registry channel "SPSChainBondPersistence" (SPSDebugConfig).
-- Class field pushed by applyAll(); call-time isOn() gives instant toggling.
-- Ships false.
SPSChainBondPersistence.DEBUG = false
local function log(fmt, ...)
    if not (SPSChainBondPersistence.DEBUG
        or (SPSDebugConfig ~= nil and SPSDebugConfig.isOn("SPSChainBondPersistence"))) then
        return
    end
    if select("#", ...) > 0 then
        print("[SPS BOND SAVE] " .. string.format(fmt, ...))
    else
        print("[SPS BOND SAVE] " .. tostring(fmt))
    end
end

-- Two couplings closer than this are the same physical point (chain-start
-- terminus sitting ON its anchor store coupling). Matches the 0.1 m position
-- tolerance used by tryResolvePendingConnections.findCouplingAtPos.
local COINCIDENT_EPS_SQ = 0.1 * 0.1

local function writeBond(xmlFile, mgr, idx, c)
    local partner = c.connectedPartnerCoupling
    if c.mountNode == nil or partner.mountNode == nil then return false end
    if not entityExists(c.mountNode) or not entityExists(partner.mountNode) then return false end
    local ax, ay, az = getWorldTranslation(c.mountNode)
    local bx, by, bz = getWorldTranslation(partner.mountNode)
    -- [1.0.0.9.24 Bug B] Never write a degenerate bond: coincident endpoints
    -- are a chain-start↔anchor pairing whose state is owned by chain restore.
    local dx, dy, dz = ax - bx, ay - by, az - bz
    if (dx*dx + dy*dy + dz*dz) <= COINCIDENT_EPS_SQ then
        log("skip degenerate bond at %.3f %.3f %.3f (coincident endpoints)", ax, ay, az)
        return false
    end
    local base = string.format("slurryPipeSystem.connections.connection(%d)", idx)
    xmlFile:setFloat(base .. "#ax", ax)
    xmlFile:setFloat(base .. "#ay", ay)
    xmlFile:setFloat(base .. "#az", az)
    xmlFile:setFloat(base .. "#bx", bx)
    xmlFile:setFloat(base .. "#by", by)
    xmlFile:setFloat(base .. "#bz", bz)
    xmlFile:setBool(base .. "#valveOpen", c.valveOpen == true)
    local pipeData = c.pipeId ~= nil and mgr.activePipes[c.pipeId] or nil
    xmlFile:setFloat(base .. "#colorR", pipeData and pipeData.colorR or mgr.currentPipeColor.r)
    xmlFile:setFloat(base .. "#colorG", pipeData and pipeData.colorG or mgr.currentPipeColor.g)
    xmlFile:setFloat(base .. "#colorB", pipeData and pipeData.colorB or mgr.currentPipeColor.b)
    return true
end

function SPSChainBondPersistence.appendMissingBonds(mgr, savePath)
    if mgr == nil or savePath == nil or not fileExists(savePath) then return end
    local xmlFile = XMLFile.load("spsBondSave", savePath)
    if xmlFile == nil then return end

    -- [1.0.0.9.24 Bug A] Vehicle-side detection by membership, not by a
    -- nonexistent `.vehicle` field. Every coupling in this set was already
    -- covered (from its vehicle side) by the original save walk.
    local vehicleCouplings = {}
    for _, vEntry in ipairs(mgr.registeredVehicles) do
        if vEntry.couplingEntries ~= nil then
            for _, vc in ipairs(vEntry.couplingEntries) do
                vehicleCouplings[vc] = true
            end
        end
    end
    local function sideIsVehicle(c)
        return c ~= nil and vehicleCouplings[c] == true
    end

    -- Continue numbering after the original's last connection entry.
    local idx = 0
    while xmlFile:hasProperty(string.format("slurryPipeSystem.connections.connection(%d)", idx)) do
        idx = idx + 1
    end
    local firstAppended = idx

    -- One entry per bond. [1.0.0.9.24] Unordered PAIR key so the same bond
    -- seen from either side maps to one key even when pipeId is nil.
    local seen = {}
    local function bondKey(c)
        if c.pipeId ~= nil then return "pipe:" .. tostring(c.pipeId) end
        local a, b = tostring(c), tostring(c.connectedPartnerCoupling)
        if b < a then a, b = b, a end
        return a .. "|" .. b
    end
    local function considerList(list)
        if list == nil then return end
        for _, c in ipairs(list) do
            -- [SPS 1.0.1.9] a bond made by a PHYSICAL pipe is saved by the pipe (SPSHoseItem end#owner/#coupling) and
            -- re-made from its plugged ends; written here it came back as an ORIGINAL hose on reload, the coupler read
            -- "busy" and the real pipe was left loose (William 2026-10-26 22:06, Borger <-> base tank)
            if c.isConnected == true and c.connectedPartnerCoupling ~= nil
            and c.connectedPartnerCoupling ~= c
            and c.physPipe == nil and c.connectedPartnerCoupling.physPipe == nil
            and not sideIsVehicle(c) and not sideIsVehicle(c.connectedPartnerCoupling) then
                local key = bondKey(c)
                if not seen[key] then
                    seen[key] = true
                    if writeBond(xmlFile, mgr, idx, c) then
                        idx = idx + 1
                    end
                end
            end
        end
    end

    for _, pEntry in ipairs(mgr.registeredPlaceables) do
        considerList(pEntry.storeCouplings)
    end
    considerList(mgr.chainTerminusEntries)

    if idx > firstAppended then
        xmlFile:save()
        log("appended %d non-vehicle bond(s) (entries %d..%d)",
            idx - firstAppended, firstAppended, idx - 1)
    end
    xmlFile:delete()
end

-- [1.0.0.9.24] Strip degenerate and duplicate connection entries that a
-- 1.0.0.9.23 save wrote, AFTER the original load populated
-- pendingConnections and BEFORE any resolution tick runs. Degenerate =
-- coincident endpoints (would self-connect a store coupling and spawn a
-- loop-back bez pipe). Duplicate = same unordered endpoint pair (reversed
-- re-writes of vehicle bonds); first occurrence is kept so valveOpen/colour
-- state is preserved.
function SPSChainBondPersistence.sanitizePendingConnections(mgr)
    if mgr == nil or mgr.pendingConnections == nil or #mgr.pendingConnections == 0 then
        return
    end
    local kept, seenPairs = {}, {}
    local droppedDegenerate, droppedDuplicate = 0, 0
    local function pk(x, y, z)
        return string.format("%.2f_%.2f_%.2f", x, y, z)
    end
    for _, p in ipairs(mgr.pendingConnections) do
        local dx, dy, dz = p.ax - p.bx, p.ay - p.by, p.az - p.bz
        if (dx*dx + dy*dy + dz*dz) <= COINCIDENT_EPS_SQ then
            droppedDegenerate = droppedDegenerate + 1
            log("sanitize: dropped degenerate entry at %.3f %.3f %.3f", p.ax, p.ay, p.az)
        else
            local a, b = pk(p.ax, p.ay, p.az), pk(p.bx, p.by, p.bz)
            local pairKey = a < b and (a .. "|" .. b) or (b .. "|" .. a)
            if seenPairs[pairKey] then
                droppedDuplicate = droppedDuplicate + 1
                log("sanitize: dropped duplicate entry %s", pairKey)
            else
                seenPairs[pairKey] = true
                table.insert(kept, p)
            end
        end
    end
    if droppedDegenerate > 0 or droppedDuplicate > 0 then
        mgr.pendingConnections = kept
        print(string.format(
            "[SPS] BondSanitize: dropped %d degenerate / %d duplicate saved connection entr%s (%d kept)",
            droppedDegenerate, droppedDuplicate,
            (droppedDegenerate + droppedDuplicate) == 1 and "y" or "ies", #kept))
    end
end

local origSaveConnectionsBond = SlurryPipeManager.saveCouplingConnections
function SlurryPipeManager:saveCouplingConnections(savePath)
    origSaveConnectionsBond(self, savePath)
    local ok, err = pcall(SPSChainBondPersistence.appendMissingBonds, self, savePath)
    if not ok then
        print("[SPS BOND SAVE] ERROR appending bonds: " .. tostring(err))
    end
end

local origLoadConnectionsBond = SlurryPipeManager.loadCouplingConnections
function SlurryPipeManager:loadCouplingConnections(savePath)
    origLoadConnectionsBond(self, savePath)
    local ok, err = pcall(SPSChainBondPersistence.sanitizePendingConnections, self)
    if not ok then
        print("[SPS BOND SAVE] ERROR sanitizing pending connections: " .. tostring(err))
    end
end