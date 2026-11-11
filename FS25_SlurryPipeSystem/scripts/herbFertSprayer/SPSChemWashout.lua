-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.2.0

-- SPSChemWashout.lua — [SPS CHEM 2026-11-06] sprayer washout (CHEM_DILUTION_SPEC.md "Washout - William's decisions")
--
-- A fert / herb sprayer that sprayed its tank empty is dirty with that chemical: a small sump amount (sumpLiters)
-- stays behind at the strength the tank had (st.residue, 1.0 = a full-strength mix). A washout is N rinses
-- (setting "Washout rinses" 1 / 2 / 3, default 3). One rinse:
--   1. PREP   Wash out pressed in the cab: the boom unfolds (if folded) to its normal working position. Lowering /
--             boom height only when the config asks for it (lowerBoom="true" / boomHeightNode) - William 2026-11-07
--   2. TANK   30 s tank wash: rinseLiters of clean water runs in from the rinse tank over rinseFillTime (10 s) (or water
--             already piped into the main tank is used), wash sounds on - only while WATER IS IN the main tank (William
--             2026-11-07: station valve on dirty = no water came in, yet the wash sounds played)
--   3. BOOM   30 s boom spray: boomFlushShare (10 %) of the water out through every nozzle (the sprayer's own nozzle
--             effects + spray sound, strip puddles under the nozzles), wash sounds off
--   4. FINAL  10 s tank wash, spray OFF, wash sounds on
--   5. DRAIN  20 s (drainTime): spray on again, the rest of the rinse water out through the nozzles standing still; empty
--             = the rinse counts, the player is asked: next rinse / fold boom (William 2026-11-07)
-- Each emptied rinse dilutes the residue by sump / (sump + rinse water). After the last one the tank is clean and the
-- player is asked to fold the boom; after the others, whether to start the next rinse.
-- Plain water sprayed out without the cycle is a POOR rinse: it dilutes less and never counts.
-- A different chemical into a dirty tank is allowed; the residue is recorded (st.contamType / contamLevel) for the
-- crop damage of part 2.
--
-- Per vehicle (all optional) in the SPS config: <sprayerPipeSystem><washout .../></sprayerPipeSystem>
--   rinseFillUnitIndex  a WATER fill unit = built-in rinse tank (none: water must come in by pipe)
--   rinseLiters / rinseShare   water per rinse (default 3 % of the main tank)
--   sumpLiters / sumpShare     what stays in the tank after emptying (default 1 % of the main tank)
--   tankFlushTime 30 / boomFlushTime 30 / finalFlushTime 10   seconds
--   rinseFillTime 10   seconds for the rinse water to run in from the rinse tank (within the tank wash)
--   boomFlushShare 0.1 share of the rinse water out in the boom spray; drainTime 20 = seconds to spray the rest out
--   puddleLength 4 / puddleWidth 1.2 / puddleOverlap 1.15: strip puddles along the work area line under the nozzles
--   boomFlushShare 0.1         share of the rinse water that leaves through the nozzles (puddles)
--   requireField true / autoUnfold true / nozzlePuddles true
--   lowerBoom false    true: lower a mounted sprayer on the linkage for the washout
--   boomHeightNode     a moving tool (i3dMappings id) to move for the washout - none by default
--   boomHeightLowest   "min" | "max": which end of that tool to move to (default min)
--   <sounds><tankFlush .../>..<tankFlush5 .../><boomFlush .../></sounds> inside <washout>: own sounds, the tankFlush ones
--     played together (default sounds/spsWashoutSounds.xml: three layered water sounds)
--
-- [SPS CHEM 2026-11-07] WASHOUT STATION (placeables with <sprayerPipeSystem><washoutStation/>, William: "connect a pipe to
-- any tank, mainly one that doesn't have a washout tank ... flushes the main tank with clean water, washes it, flushes
-- the boom, washes the main tank, then empties the dirty water back down the washout pipe ... then asks if the 2nd
-- should be done"): with the sprayer's pipe on a station, Wash out needs no rinse tank, no field and no water in the
-- tank. The station is a mains tap: the rinse water runs into the main tank from it over rinseFillTime and is PAID
-- (WATER pricePerLiter x the station's waterPriceScale, finance line "water"); TANK / BOOM / FINAL run as above; then
-- phase 6 RETURN (instead of DRAIN): the dirty water is pumped back down the pipe and vanishes (no nozzles, no puddles),
-- the station's changeover valve node (optional) turns while it does; empty = the rinse counts, the question comes as
-- usual, the next rinse draws fresh water again. A sprayer with its own rinse tank uses it for the water and the station
-- for the return (the station takes over the water only when the rinse tank runs dry).
-- The station is ALSO a paid tap for the ordinary pipe: its store is kept FULL of WATER while its valve is on "clean
-- water in" (Y load + B at the sprayer buys water for the main or rinse tank, charged per litre in tickSprayerFlow) and
-- EMPTY while on "dirty water out" (Y unload + B: whatever arrives vanishes). The valve (the station's handle,
-- <washoutStation changeoverNodeName> at cleanRotation / dirtyRotation) is set by the cycle and the sprayer's direction
-- in valveMode="auto", or BY HAND at the station (R at the handle) in valveMode="manual" - then the cycle waits for it.
-- Wash out and the sprayer's B / Y are also on the walk-up control node (SPSSprayerPumpControl) for a sprayer with no
-- water on board (William 2026-11-07). Automatic / by hand is the SETTINGS MENU row "Washout station valve"
-- (featureToggles.washoutValveManual, admin, synced, saved), not the station's XML.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSChemWashout 1.0.2.0 loaded") end

SPSChemWashout = {}
SPSChemWashout.PHASE_NONE   = 0
-- [SPS 2026-11-10] a washout started ON FOOT: the next-rinse / fold-boom question goes to the player standing within this of
-- the sprayer (William: "it didn't give me the washout complete and fold boom when outside, as soon as I got in the cab the
-- message popped up") - before, only the player in the cab was ever asked
SPSChemWashout.ASK_ON_FOOT_RADIUS = 20
SPSChemWashout.PHASE_PREP   = 1
SPSChemWashout.PHASE_TANK   = 2
SPSChemWashout.PHASE_BOOM   = 3
SPSChemWashout.PHASE_FINAL  = 4
SPSChemWashout.PHASE_DRAIN  = 5
SPSChemWashout.PHASE_RETURN = 6   -- [station] the dirty water back down the pipe (no nozzles)
SPSChemWashout.CHANGEOVER_SPEED = 0.004   -- rad per ms the station's changeover valve node turns
SPSChemWashout.VALVE_CLEAN = false        -- station valve states (pe.washoutValveDirty)
SPSChemWashout.VALVE_DIRTY = true
SPSChemWashout.PREP_TIMEOUT_MS = 60000
SPSChemWashout.PUDDLE_STEP_M   = 4.0
SPSChemWashout.PUDDLE_EVERY_MS = 6000
SPSChemWashout.KEEP_FOR_FINAL_L = 1.0   -- the boom spray leaves this in the tank for the final wash

SPSChemWashout.ACT_START  = 1
SPSChemWashout.ACT_TARGET = 2
SPSChemWashout.ACT_FOLD   = 3
SPSChemWashout.ACT_DISMISS = 4

SPSChemWashout.ASK_NONE  = 0
SPSChemWashout.ASK_NEXT  = 1
SPSChemWashout.ASK_CLEAN = 2

SPSChemWashout.running = {}   -- vehicle -> true (server: cycle in PREP..FINAL)
SPSChemWashout.MOD_DIR = g_currentModDirectory
SPSChemWashout.TANK_SOUNDS = { "tankFlush", "tankFlush2", "tankFlush3", "tankFlush4", "tankFlush5" }   -- played together

local P = SPSChemWashout

local function clog(fmt, ...)
    if SPSDebugConfig == nil or not SPSDebugConfig.isOn("SPSChemStation") then return end
    if select("#", ...) > 0 then
        print("[SPS WASH] " .. string.format(fmt, ...))
    else
        print("[SPS WASH] " .. tostring(fmt))
    end
end

local function txt(key, fallback)
    if g_i18n ~= nil and g_i18n:hasText(key) then return g_i18n:getText(key) end
    return fallback
end

local function warn(key, fallback, ...)
    local s = txt(key, fallback)
    if select("#", ...) > 0 then s = string.format(s, ...) end
    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(s, 3000)
    end
end

local function ftTitle(ft)
    return (ft ~= nil and g_fillTypeManager:getFillTypeTitleByIndex(ft)) or "?"
end

local function markDirty(vehicle)
    if g_server ~= nil and vehicle ~= nil and SPSChemMix ~= nil then SPSChemMix.dirty[vehicle] = true end
end

-- a phase of the cycle (PREP .. RETURN)
function SPSChemWashout.inCycle(ph)
    return ph ~= nil and ph >= P.PHASE_PREP and ph <= P.PHASE_RETURN
end

-- the emptying phases (through the nozzles / back to the station)
local function isEmptying(ph)
    return ph == P.PHASE_DRAIN or ph == P.PHASE_RETURN
end

-- [station] the washout station this sprayer's pipe is on right now (the sprayer placeable entry), or nil
function SPSChemWashout.stationOf(vehicle)
    local mgr = g_slurryPipeManager
    if mgr == nil or mgr.getSprayerVehicleEntry == nil or mgr.registeredSprayerPlaceables == nil then return nil end
    local entry = mgr:getSprayerVehicleEntry(vehicle)
    if entry == nil then return nil end
    for _, c in ipairs(entry.couplings or {}) do
        local partner = c.isConnected and c.connectedPartnerCoupling or nil
        if partner ~= nil then
            for _, pe in ipairs(mgr.registeredSprayerPlaceables) do
                if pe.isWashoutStation then
                    for _, sc in ipairs(pe.couplings or {}) do
                        if sc == partner then return pe end
                    end
                end
            end
        end
    end
    return nil
end

-- [station] every sprayer whose pipe is on this station right now
-- [SPS MKS8 2026-11-11] ...and every TANKER hosed to it through a lane bridge (it has a sprayer state: Y direction): with
-- Y on Unload the valve goes to "dirty water out" and the tanker's water goes down the dirty line (William)
local function stationSprayers(pe)
    local list = {}
    local mgr = g_slurryPipeManager
    for _, sc in ipairs(pe.couplings or {}) do
        local v = sc.isConnected and sc.connectedTarget or nil
        if v ~= nil and (v.spec_sprayer ~= nil or (mgr ~= nil and mgr.getSprayerObjectState ~= nil and mgr:getSprayerObjectState(v) ~= nil)) then
            list[#list + 1] = v
        end
    end
    return list
end

-- [station] the valve is on "dirty water out"
function SPSChemWashout.stationValveDirty(pe)
    return pe ~= nil and pe.washoutValveDirty == true
end

-- [station] settings menu "Washout station valve": true = by hand at the station (the cycle waits for it),
-- false = automatic (William 2026-11-07: a player adjusts it as needed)
function SPSChemWashout.valveManual()
    local m = g_slurryPipeManager
    return m ~= nil and m.featureToggles ~= nil and m.featureToggles.washoutValveManual == true
end

-- [station] set the valve (server; broadcast on change). Manual mode: the player's choice; auto: the cycle's.
function SPSChemWashout.setStationValve(pe, dirty, noEventSend)
    if pe == nil or pe.washoutValveDirty == dirty then return end
    pe.washoutValveDirty = dirty
    if g_server ~= nil and not noEventSend and SPSWashoutValveEvent ~= nil and pe.object ~= nil then
        g_server:broadcastEvent(SPSWashoutValveEvent.new(pe.object, dirty), nil, nil, pe.object, nil, nil, true)
    end
    clog("washout station %s valve -> %s", tostring(pe.object and pe.object.configFileName), dirty and "DIRTY water out" or "CLEAN water in")
end

-- [station] client or server: the player flips the valve by hand (manual mode)
function SPSChemWashout.requestStationValve(pe, dirty)
    if pe == nil or pe.object == nil then return end
    if g_server ~= nil then
        P.setStationValve(pe, dirty)
    elseif g_client ~= nil and SPSWashoutValveEvent ~= nil then
        g_client:getServerConnection():sendEvent(SPSWashoutValveEvent.new(pe.object, dirty))
    end
end

-- [station] the placeable entry of a station object (any peer)
function SPSChemWashout.stationEntryOf(placeable)
    local mgr = g_slurryPipeManager
    if mgr == nil or mgr.registeredSprayerPlaceables == nil or placeable == nil then return nil end
    for _, pe in ipairs(mgr.registeredSprayerPlaceables) do
        if pe.isWashoutStation and pe.object == placeable then return pe end
    end
    return nil
end

-- [station] join dump: every station's valve state to one freshly joined client
function SPSChemWashout.sendStationsTo(connection)
    local mgr = g_slurryPipeManager
    if connection == nil or mgr == nil or mgr.registeredSprayerPlaceables == nil or SPSWashoutValveEvent == nil then return end
    for _, pe in ipairs(mgr.registeredSprayerPlaceables) do
        if pe.isWashoutStation and pe.object ~= nil then
            connection:sendEvent(SPSWashoutValveEvent.new(pe.object, pe.washoutValveDirty == true))
        end
    end
end

-- [station] clean water drawn through the ordinary pipe (Y load + B): charged per litre (tickSprayerFlow, server)
function SPSChemWashout.chargeWater(vehicle, pe, litres)
    if vehicle == nil or pe == nil or litres == nil or litres <= 0 or g_currentMission == nil then return end
    local ftDesc = g_fillTypeManager:getFillTypeByIndex(FillType.WATER)
    local price = litres * (ftDesc ~= nil and ftDesc.pricePerLiter or 0) * (pe.washoutWaterScale or 1)
    if price <= 0 then return end
    local farm = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or 1
    g_currentMission:addMoney(-price, farm, MoneyType.PURCHASE_WATER, true)
    pe.washoutSold = (pe.washoutSold or 0) + litres
    if not pe._washoutSaleLogged then
        pe._washoutSaleLogged = true
        clog("%s buys water from %s (first batch %.2f l for %.3f)", tostring(vehicle.configFileName), tostring(pe.object and pe.object.configFileName), litres, price)
    end
end

-- rinses a washout needs (setting, 1..3)
function SPSChemWashout.rinsesNeeded()
    local m = g_slurryPipeManager
    local n = m ~= nil and m.featureToggles ~= nil and tonumber(m.featureToggles.chemRinses) or nil
    if n == nil or n < 1 or n > 3 then return 3 end
    return math.floor(n)
end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
-- raw <washout> block, read by registerSprayerVehicle while the SPS config xml is open (nil = no block)
function SPSChemWashout.readConfig(xmlFile, key)
    if xmlFile == nil or key == nil or not xmlFile:hasProperty(key) then return nil end
    return {
        rinseFui         = xmlFile:getInt(key .. "#rinseFillUnitIndex"),
        rinseLiters      = xmlFile:getFloat(key .. "#rinseLiters"),
        rinseShare       = xmlFile:getFloat(key .. "#rinseShare"),
        sumpLiters       = xmlFile:getFloat(key .. "#sumpLiters"),
        sumpShare        = xmlFile:getFloat(key .. "#sumpShare"),
        tankFlushTime    = xmlFile:getFloat(key .. "#tankFlushTime"),
        boomFlushTime    = xmlFile:getFloat(key .. "#boomFlushTime"),
        finalFlushTime   = xmlFile:getFloat(key .. "#finalFlushTime"),
        rinseFillTime    = xmlFile:getFloat(key .. "#rinseFillTime"),
        drainTime        = xmlFile:getFloat(key .. "#drainTime"),
        boomFlushShare   = xmlFile:getFloat(key .. "#boomFlushShare"),
        requireField     = xmlFile:getBool(key .. "#requireField"),
        autoUnfold       = xmlFile:getBool(key .. "#autoUnfold"),
        nozzlePuddles    = xmlFile:getBool(key .. "#nozzlePuddles"),
        puddleLength     = xmlFile:getFloat(key .. "#puddleLength"),
        puddleWidth      = xmlFile:getFloat(key .. "#puddleWidth"),
        puddleOverlap    = xmlFile:getFloat(key .. "#puddleOverlap"),
        boomHeightNode   = xmlFile:getString(key .. "#boomHeightNode"),
        boomHeightLowest = xmlFile:getString(key .. "#boomHeightLowest"),
        lowerBoom        = xmlFile:getBool(key .. "#lowerBoom"),
        hasSounds        = xmlFile:hasProperty(key .. ".sounds"),
    }
end

local function pick(v, d) if v == nil then return d end return v end

-- the washout settings of one chem sprayer (built once, from the <washout> block or the defaults)
function SPSChemWashout.getCfg(vehicle)
    if vehicle == nil then return nil end
    if vehicle.spsWashoutCfg ~= nil then return vehicle.spsWashoutCfg end
    local fui = SPSChemMix.getChemFillUnit(vehicle)
    if fui == nil then return nil end
    local entry = g_slurryPipeManager ~= nil and g_slurryPipeManager.getSprayerVehicleEntry ~= nil
        and g_slurryPipeManager:getSprayerVehicleEntry(vehicle) or nil
    local raw = entry ~= nil and entry.washoutXml or {}
    local cap = vehicle:getFillUnitCapacity(fui) or 1000
    local c = {
        mainFui        = fui,
        rinseL         = raw.rinseLiters or cap * pick(raw.rinseShare, 0.03),
        sumpL          = raw.sumpLiters or math.max(5, cap * pick(raw.sumpShare, 0.01)),
        tankMs         = pick(raw.tankFlushTime, 30) * 1000,
        boomMs         = pick(raw.boomFlushTime, 30) * 1000,
        finalMs        = pick(raw.finalFlushTime, 10) * 1000,
        fillMs         = math.max(1, pick(raw.rinseFillTime, 10)) * 1000,
        drainMs        = math.max(1, pick(raw.drainTime, 20)) * 1000,
        boomShare      = math.max(0, math.min(1, pick(raw.boomFlushShare, 0.1))),
        requireField   = pick(raw.requireField, true),
        autoUnfold     = pick(raw.autoUnfold, true),
        puddles        = pick(raw.nozzlePuddles, true),
        puddleLen      = math.max(0.5, pick(raw.puddleLength, 4.0)),     -- m along the boom per strip
        puddleWid      = math.max(0.2, pick(raw.puddleWidth, 1.2)),      -- m front to back
        puddleOverlap  = math.max(1.0, pick(raw.puddleOverlap, 1.15)),   -- strips a little longer than their spacing
        heightNode     = raw.boomHeightNode,
        heightLowMax   = raw.boomHeightLowest == "max",
        lowerBoom      = raw.lowerBoom == true,
    }
    -- rinse tank: must be a different fill unit that takes WATER
    local rf = raw.rinseFui
    local fus = vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits or {}
    if rf ~= nil and rf ~= fui and fus[rf] ~= nil and fus[rf].supportedFillTypes ~= nil and fus[rf].supportedFillTypes[FillType.WATER] then
        c.rinseFui = rf
    elseif rf ~= nil then
        print(string.format("[SPS WARNING] %s: <washout rinseFillUnitIndex=\"%d\"> is not a water fill unit - no rinse tank",
            tostring(vehicle.configFileName), rf))
    end
    -- cache only once the SPS config is registered (asked earlier, the <washout> block was not read yet)
    if entry ~= nil then vehicle.spsWashoutCfg = c end
    return c
end

-- ---------------------------------------------------------------------------
-- Residue
-- ---------------------------------------------------------------------------
-- strength of the chemical left in the system right now (sump residue diluted by any water in the tank)
function SPSChemWashout.residueNow(vehicle, st)
    if st == nil or st.dirtyWith == nil then return 0 end
    local r = st.residue or 1
    local cfg = P.getCfg(vehicle)
    local level = (cfg ~= nil and vehicle:getFillUnitFillLevel(cfg.mainFui)) or 0
    if st.washing and level > 0.001 and cfg ~= nil then
        r = r * cfg.sumpL / (cfg.sumpL + level)
    end
    return r
end

-- the tank ran empty while holding water (server). The rinse that was waiting to be emptied counts; anything else
-- (plain water, a cycle that never finished) is a poor rinse.
function SPSChemWashout.onWaterEmptied(vehicle, st, waterL)
    if st.dirtyWith == nil then
        st.phase, st.poorRinse = P.PHASE_NONE, false
        return
    end
    local cfg = P.getCfg(vehicle)
    local sump = cfg ~= nil and cfg.sumpL or 20
    local w = math.max(0, waterL or 0)
    local factor = sump / (sump + w)
    P.running[vehicle] = nil
    if isEmptying(st.phase) then
        st.residue = (st.residue or 1) * factor
        st.rinsesDone = (st.rinsesDone or 0) + 1
        st.phase, st.poorRinse = P.PHASE_NONE, false
        st.askId = ((st.askId or 0) + 1) % 250
        if st.rinsesDone >= P.rinsesNeeded() then
            clog("rinse %d emptied: tank CLEAN (residue was %.3f)", st.rinsesDone, st.residue)
            st.dirtyWith, st.residue, st.rinsesDone = nil, 0, 0
            st.ask = P.ASK_CLEAN
        else
            clog("rinse %d of %d emptied: residue %.3f", st.rinsesDone, P.rinsesNeeded(), st.residue)
            st.ask = P.ASK_NEXT
        end
    else
        st.residue = (st.residue or 1) * math.sqrt(factor)
        st.phase, st.poorRinse = P.PHASE_NONE, true
        clog("plain water emptied (%.0f l): poor rinse, residue %.3f", w, st.residue)
    end
    markDirty(vehicle)
end

-- a rinse is running (any stage up to the final flush, or the rinse water running out)
function SPSChemWashout.isBusy(st)
    if st == nil or st.phase == nil then return false end
    if st.phase >= P.PHASE_PREP and st.phase <= P.PHASE_FINAL then return true end
    return isEmptying(st.phase) and (st.phaseT or 0) > 0
end

function SPSChemWashout.warnContam(ft)
    warn("warning_spsWashContam", "Not washed out: %s residue is in the new mix - it may damage the crop", ftTitle(ft))
end

-- ---------------------------------------------------------------------------
-- Start / checks
-- ---------------------------------------------------------------------------
local function isUnfolded(vehicle)
    return vehicle.getIsUnfolded == nil or vehicle:getIsUnfolded()
end

-- ok (true) or false + warning key + fallback + args
function SPSChemWashout.check(vehicle)
    local st = SPSChemMix.getState(vehicle)
    local cfg = P.getCfg(vehicle)
    if st == nil or cfg == nil then return false end
    if st.dirtyWith == nil then return false, "warning_spsWashClean", "The tank is clean - no washout needed" end
    if st.type ~= nil then
        return false, "warning_spsWashChemIn", "Empty the tank first (it holds %s)", ftTitle(st.type)
    end
    if isEmptying(st.phase) then return true end   -- resume running the rinse water out (after a reload or a stop)
    local station = P.stationOf(vehicle)   -- [station] no field, no water needed: the station is the tap and the drain
    if station == nil and cfg.requireField and vehicle.getIsOnField ~= nil and not vehicle:getIsOnField() then
        return false, "warning_spsWashField", "Wash out in a field or at a washout point"
    end
    if not isUnfolded(vehicle) then
        local sf = vehicle.spec_foldable
        local dir = sf ~= nil and sf.turnOnFoldDirection or 1
        if not cfg.autoUnfold or vehicle.getIsFoldAllowed == nil or not vehicle:getIsFoldAllowed(dir, false) then
            return false, "warning_spsWashFold", "Unfold the boom first"
        end
    end
    local level = vehicle:getFillUnitFillLevel(cfg.mainFui) or 0
    local need = cfg.rinseL
    if level < need - 0.5 and station == nil then
        if cfg.rinseFui ~= nil then
            local have = vehicle:getFillUnitFillLevel(cfg.rinseFui) or 0
            if have + level < need - 0.5 then
                return false, "warning_spsWashWaterTank", "The rinse tank needs %d l of water", math.ceil(need - level)
            end
        else
            return false, "warning_spsWashWaterPipe", "Add %d l of clean water to the tank by pipe first", math.ceil(need - level)
        end
    end
    return true
end

-- the moving tool that sets the boom height (nil = none)
local function heightTool(vehicle, cfg)
    local sc = vehicle.spec_cylindered
    if sc == nil or sc.movingTools == nil then return nil end
    -- the XML name is an i3dMappings id (as everywhere in a vehicle xml); fall back to the node name
    if cfg.heightNode ~= nil and I3DUtil ~= nil and I3DUtil.indexToObject ~= nil and vehicle.getMovingToolByNode ~= nil then
        local ok, node = pcall(I3DUtil.indexToObject, vehicle.components, cfg.heightNode, vehicle.i3dMappings)
        local t = ok and node ~= nil and vehicle:getMovingToolByNode(node) or nil
        if t ~= nil then return t end
    end
    for _, t in ipairs(sc.movingTools) do
        if t.node ~= nil and ((cfg.heightNode ~= nil and getName(t.node) == cfg.heightNode)
        ) then
            return t
        end
    end
    return nil
end

-- server: unfold, lower, boom to its lowest
local function prepBoom(vehicle, cfg)
    local sf = vehicle.spec_foldable
    if not isUnfolded(vehicle) and sf ~= nil and vehicle.setFoldState ~= nil then
        vehicle:setFoldState(sf.turnOnFoldDirection or 1, false)
        clog("unfolding the boom")
    end
    -- only when the config asks for it: a mounted sprayer lowers on the three-point linkage
    local av = cfg.lowerBoom and vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() or nil
    if av ~= nil and av.getAttacherJointIndexFromObject ~= nil and av.setJointMoveDown ~= nil then
        local ji = av:getAttacherJointIndexFromObject(vehicle)
        local allows = vehicle.getAllowsLowering == nil or vehicle:getAllowsLowering()
        if ji ~= nil and allows then av:setJointMoveDown(ji, true, false) end
    end
    local t = heightTool(vehicle, cfg)
    if t ~= nil and t.rotMin ~= nil and t.rotMax ~= nil then
        local target = cfg.heightLowMax and 1 or 0
        t.curTargetPosition = target
        t.curTargetDirection = target - Cylindered.getMovingToolState(vehicle, t)
        vehicle.spsWashHeightTool = t
        clog("boom height tool %s -> %s", tostring(getName(t.node)), cfg.heightLowMax and "max" or "min")
    end
end

-- server: start a rinse (returns ok)
function SPSChemWashout.start(vehicle)
    local ok = P.check(vehicle)
    if not ok then return false end
    local st, cfg = SPSChemMix.getState(vehicle), P.getCfg(vehicle)
    if isEmptying(st.phase) then
        -- carry on emptying (paused by Wash out, or caught at a save): back to the station if the pipe is on one,
        -- else through the nozzles
        local lvl = vehicle:getFillUnitFillLevel(cfg.mainFui) or 0
        st.phase = P.stationOf(vehicle) ~= nil and P.PHASE_RETURN or P.PHASE_DRAIN
        st.phaseT, st.drainRate, st.puddleT, st.puddleOut = cfg.drainMs, math.max(1, lvl) / cfg.drainMs, 0, 0
        P.running[vehicle] = true
        markDirty(vehicle)
        clog("emptying the rinse water again (%.0f l, %s)", lvl, st.phase == P.PHASE_RETURN and "to the station" or "through the nozzles")
        return true
    end
    prepBoom(vehicle, cfg)
    st.phase, st.phaseT, st.ask, st.poorRinse = P.PHASE_PREP, P.PREP_TIMEOUT_MS, P.ASK_NONE, false
    st.moveLeft = math.max(0, cfg.rinseL - (vehicle:getFillUnitFillLevel(cfg.mainFui) or 0))
    st.stationPaid = 0
    P.running[vehicle] = true
    markDirty(vehicle)
    local station = P.stationOf(vehicle)
    clog("rinse %d of %d started on %s (rinse %.0f l, from %s)", (st.rinsesDone or 0) + 1, P.rinsesNeeded(),
        tostring(vehicle.configFileName), cfg.rinseL,
        st.moveLeft <= 0 and "main tank" or (cfg.rinseFui ~= nil and "rinse tank" or (station ~= nil and "the washout station" or "?")))
    return true
end

-- [station] clean water from the station into the main tank: litres this tick, paid at WATER pricePerLiter x the
-- station's waterPriceScale (the base game's "water" finance line, as an automatic barn supply)
local function stationWaterIn(vehicle, st, cfg, station, farm, dt)
    local fui = cfg.mainFui
    -- manual valve: the player must have set it to "clean water in" - the tank wash waits (its countdown held)
    if P.valveManual() and P.stationValveDirty(station) then
        st.phaseT = (st.phaseT or 0) + dt
        if not st._valveWarned then
            st._valveWarned = true
            if vehicle.isClient then warn("warning_spsWashValveClean", "Set the washout station valve to clean water in") end
        end
        return
    end
    st._valveWarned = nil
    local step = math.min(st.moveLeft, cfg.rinseL * dt / math.max(1, cfg.fillMs))
    local free = (vehicle:getFillUnitCapacity(fui) or 0) - (vehicle:getFillUnitFillLevel(fui) or 0)
    step = math.min(step, free)
    if step <= 0 then st.moveLeft = 0 return end
    local got = vehicle:addFillUnitFillLevel(farm, fui, step, FillType.WATER, ToolType.UNDEFINED, nil) or 0
    if got <= 0 then st.moveLeft = 0 return end
    st.moveLeft = st.moveLeft - got
    if SPSFillSound ~= nil then SPSFillSound.mark(vehicle, true) end
    local ftDesc = g_fillTypeManager:getFillTypeByIndex(FillType.WATER)
    local price = got * (ftDesc ~= nil and ftDesc.pricePerLiter or 0) * (station.washoutWaterScale or 1)
    if price > 0 and g_currentMission ~= nil then
        g_currentMission:addMoney(-price, farm, MoneyType.PURCHASE_WATER, true)
        st.stationPaid = (st.stationPaid or 0) + price
    end
    if st.moveLeft <= 0 then
        clog("%.0f l of clean water from %s for %.2f", cfg.rinseL, tostring(station.object and station.object.configFileName), st.stationPaid or 0)
    end
end

function SPSChemWashout.stop(vehicle, why)
    local st = vehicle.spsChemMix
    P.running[vehicle] = nil
    if vehicle.spsWashHeightTool ~= nil then vehicle.spsWashHeightTool.curTargetPosition = nil; vehicle.spsWashHeightTool = nil end
    if st ~= nil and isEmptying(st.phase) then
        st.phaseT = 0          -- paused: Wash out runs the rest out
        markDirty(vehicle)
    elseif st ~= nil and st.phase ~= P.PHASE_NONE then
        st.phase = P.PHASE_NONE
        markDirty(vehicle)
        clog("washout stopped (%s)", tostring(why))
    end
end

-- client or server: the Wash out key
function SPSChemWashout.request(vehicle, act, value)
    if g_server ~= nil then
        P.apply(vehicle, act, value)
    else
        local st = vehicle.spsChemMix or (act == P.ACT_TARGET and SPSChemMix.getState(vehicle)) or nil
        if act == P.ACT_TARGET and st ~= nil then st.rinseTarget = value == true end   -- shown at once
        g_client:getServerConnection():sendEvent(SPSChemWashoutEvent.new(vehicle, act, value == true))
    end
end

-- server
function SPSChemWashout.apply(vehicle, act, value)
    local st = SPSChemMix.getState(vehicle)
    if st == nil then return end
    if act == P.ACT_START then
        if P.running[vehicle] then
            P.stop(vehicle, "stopped by the player")
        else
            st.ask = P.ASK_NONE
            P.start(vehicle)
        end
    elseif act == P.ACT_TARGET then
        st.rinseTarget = value == true
        markDirty(vehicle)
    elseif act == P.ACT_FOLD then
        st.ask = P.ASK_NONE
        local sf = vehicle.spec_foldable
        if sf ~= nil and vehicle.setFoldState ~= nil and isUnfolded(vehicle) then
            local dir = -(sf.turnOnFoldDirection or 1)
            if vehicle.getIsFoldAllowed == nil or vehicle:getIsFoldAllowed(dir, false) then vehicle:setFoldState(dir, false) end
        end
        markDirty(vehicle)
    elseif act == P.ACT_DISMISS then
        st.ask = P.ASK_NONE
        markDirty(vehicle)
    end
end

-- ---------------------------------------------------------------------------
-- Cycle (server) + client side (countdown, nozzle effects, the question)
-- ---------------------------------------------------------------------------
local function nozzlePoints(vehicle)
    local pts = {}
    local sp = vehicle.spec_sprayer
    for _, e in ipairs(sp ~= nil and sp.effects or {}) do
        local n = e.node or e.linkNode
        if n ~= nil and entityExists(n) then
            local x, y, z = getWorldTranslation(n)
            local near = false
            for _, p in ipairs(pts) do
                if (p[1] - x) ^ 2 + (p[3] - z) ^ 2 < P.PUDDLE_STEP_M ^ 2 then near = true; break end
            end
            if not near then pts[#pts + 1] = { x, y, z } end
        end
    end
    if #pts == 0 and vehicle.spec_workArea ~= nil then
        for _, wa in ipairs(vehicle.spec_workArea.workAreas or {}) do
            for _, n in ipairs({ wa.start, wa.width, wa.height }) do
                if n ~= nil and entityExists(n) then
                    local x, y, z = getWorldTranslation(n)
                    pts[#pts + 1] = { x, y, z }
                end
            end
        end
    end
    return pts
end

-- the boom line under the nozzles: the two work area points furthest apart sideways (start / width / height of the
-- sprayer's work areas). The boom width config and switched-off sections move those nodes, so this is always the real
-- width (UX5201: 33 / 36 / 40 m). Nil when the sprayer has no work area.
local function boomLine(vehicle)
    local wa = vehicle.spec_workArea
    if wa == nil or wa.workAreas == nil or vehicle.rootNode == nil then return nil end
    local lo, hi = nil, nil
    for _, area in ipairs(wa.workAreas) do
        if area.type == nil or WorkAreaType == nil or area.type == WorkAreaType.SPRAYER then
            for _, n in ipairs({ area.start, area.width, area.height }) do
                if n ~= nil and entityExists(n) then
                    local x, y, z = getWorldTranslation(n)
                    local lx = worldToLocal(vehicle.rootNode, x, y, z)
                    if lo == nil or lx < lo.lx then lo = { lx = lx, x = x, y = y, z = z } end
                    if hi == nil or lx > hi.lx then hi = { lx = lx, x = x, y = y, z = z } end
                end
            end
        end
    end
    if lo == nil or hi == nil or hi.lx - lo.lx < 0.5 then return nil end
    return lo, hi
end

-- litres out of the nozzles -> strip puddles along the boom line: one every puddleLength m, slightly overlapping, long
-- along the boom and short front to back, turned to the boom's heading (William: "wide on the x, short on the z")
local function puddlesAtNozzles(vehicle, cfg, litres)
    if not cfg.puddles or litres == nil or litres <= 0 or SPSSpill == nil then return end
    local a, b = boomLine(vehicle)
    if a == nil or SPSSpill.addStrip == nil then
        -- no work area: one round puddle under the sprayer
        if SPSSpill.addLitres ~= nil and vehicle.rootNode ~= nil then
            local x, y, z = getWorldTranslation(vehicle.rootNode)
            SPSSpill.addLitres(x, SPSSpill.surfaceY ~= nil and SPSSpill.surfaceY(x, y, z) or y, z, litres, FillType.WATER)
        end
        return
    end
    local dx, dz = b.x - a.x, b.z - a.z
    local len = math.sqrt(dx * dx + dz * dz)
    local n = math.max(1, math.ceil(len / cfg.puddleLen))
    local seg = len / n
    local rotY = math.atan2(-dz, dx)     -- the decal's X axis along the boom
    for i = 0, n - 1 do
        local t = (i + 0.5) / n
        local x, y, z = a.x + dx * t, a.y + (b.y - a.y) * t, a.z + dz * t
        y = SPSSpill.surfaceY ~= nil and SPSSpill.surfaceY(x, y, z) or y
        SPSSpill.addStrip(x, y, z, litres / n, FillType.WATER, seg * cfg.puddleOverlap, cfg.puddleWid, rotY)
    end
end

local function serverTick(vehicle, st, cfg, dt)
    local fui = cfg.mainFui
    local farm = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or 1
    -- a chemical went in, or the tank was emptied under the cycle: stop
    if st.type ~= nil then P.stop(vehicle, "chemical in the tank"); return end
    -- the player took the boom height over
    local ht = vehicle.spsWashHeightTool
    if ht ~= nil and (ht.move or 0) ~= 0 then ht.curTargetPosition = nil; vehicle.spsWashHeightTool = nil end

    st.phaseT = (st.phaseT or 0) - dt
    if st.phase == P.PHASE_PREP then
        if isUnfolded(vehicle) then
            st.phase, st.phaseT = P.PHASE_TANK, cfg.tankMs
            markDirty(vehicle)
        elseif st.phaseT <= 0 then
            P.stop(vehicle, "boom did not unfold")
        end
        return
    end
    if (st.phase == P.PHASE_BOOM or st.phase == P.PHASE_DRAIN) and not isUnfolded(vehicle) then P.stop(vehicle, "boom folded"); return end

    if st.phase == P.PHASE_TANK then
        -- 1) TANK WASH (30 s): the rinse water runs in from the rinse tank over rinseFillTime (10 s), wash sounds on;
        --    [station] no rinse tank (or it ran dry): paid clean water from the washout station the pipe is on
        if (st.moveLeft or 0) > 0 then
            local fromTank = false
            if cfg.rinseFui ~= nil then
                local step = math.min(st.moveLeft, cfg.rinseL * dt / math.max(1, cfg.fillMs))
                local got = -(vehicle:addFillUnitFillLevel(farm, cfg.rinseFui, -step, FillType.WATER, ToolType.UNDEFINED, nil) or 0)
                if got > 0 then
                    vehicle:addFillUnitFillLevel(farm, fui, got, FillType.WATER, ToolType.UNDEFINED, nil)
                    st.moveLeft = st.moveLeft - got
                    if SPSFillSound ~= nil then SPSFillSound.mark(vehicle, true) end   -- the machine's fill sound
                    fromTank = true
                end
            end
            if not fromTank then
                local station = P.stationOf(vehicle)
                if station ~= nil then
                    stationWaterIn(vehicle, st, cfg, station, farm, dt)
                else
                    st.moveLeft = 0
                end
            end
        end
        if st.phaseT <= 0 then
            -- 2) BOOM SPRAY (30 s): boomFlushShare (10 %) of the water out through every nozzle, puddles under them
            local lvl = vehicle:getFillUnitFillLevel(fui) or 0
            st.phase, st.phaseT = P.PHASE_BOOM, cfg.boomMs
            st.boomRate = math.min(lvl - P.KEEP_FOR_FINAL_L, lvl * cfg.boomShare) / math.max(1, cfg.boomMs)
            st.boomRate = math.max(0, st.boomRate)
            st.puddleT, st.puddleOut = P.PUDDLE_EVERY_MS / 2, 0
            markDirty(vehicle)
            clog("tank wash done (%.0f l in the tank): boom spray", lvl)
        end
    elseif st.phase == P.PHASE_BOOM then
        local lvl = vehicle:getFillUnitFillLevel(fui) or 0
        local out = math.min(math.max(0, lvl - P.KEEP_FOR_FINAL_L), (st.boomRate or 0) * dt)
        if out > 0 then
            vehicle:addFillUnitFillLevel(farm, fui, -out, FillType.WATER, ToolType.UNDEFINED, nil)
            st.puddleOut = (st.puddleOut or 0) + out
        end
        st.puddleT = (st.puddleT or 0) - dt
        if st.puddleT <= 0 then
            st.puddleT = P.PUDDLE_EVERY_MS / 2
            puddlesAtNozzles(vehicle, cfg, st.puddleOut)
            st.puddleOut = 0
        end
        if st.phaseT <= 0 then
            -- 3) FINAL TANK WASH (10 s): spray OFF, wash sounds on
            puddlesAtNozzles(vehicle, cfg, st.puddleOut)
            st.puddleOut = 0
            st.phase, st.phaseT = P.PHASE_FINAL, cfg.finalMs
            markDirty(vehicle)
            clog("boom spray done: final tank wash (spray off)")
        end
    elseif st.phase == P.PHASE_FINAL then
        if st.phaseT <= 0 then
            -- 4) EMPTY (20 s): spray ON again, the rest of the rinse water out through the nozzles standing still;
            --    [station] the pipe is on a washout station: back down the pipe instead (RETURN, no nozzles)
            local lvl = vehicle:getFillUnitFillLevel(fui) or 0
            local toStation = P.stationOf(vehicle) ~= nil
            st.phase, st.phaseT = toStation and P.PHASE_RETURN or P.PHASE_DRAIN, cfg.drainMs
            st.drainRate = math.max(1, lvl) / cfg.drainMs     -- litres per ms
            st.puddleT, st.puddleOut = P.PUDDLE_EVERY_MS / 2, 0
            if vehicle.spsWashHeightTool ~= nil then vehicle.spsWashHeightTool.curTargetPosition = nil; vehicle.spsWashHeightTool = nil end
            markDirty(vehicle)
            clog("final tank wash done: %.0f l of rinse water %s", lvl, toStation and "back down the pipe to the washout station" or "out through the nozzles")
        end
    elseif st.phase == P.PHASE_RETURN then
        -- [station] the dirty water pumps back down the pipe and is gone; the pipe must still be on a station
        local station = P.stationOf(vehicle)
        if station == nil then
            st.phase = P.PHASE_DRAIN   -- pipe pulled: the rest goes out through the nozzles
            markDirty(vehicle)
            clog("washout station gone: the rest goes out through the nozzles")
            return
        end
        if P.valveManual() and not P.stationValveDirty(station) then
            -- manual valve: waits for "dirty water out"
            st.phaseT = (st.phaseT or 0) + dt
            if not st._valveWarned then
                st._valveWarned = true
                if vehicle.isClient then warn("warning_spsWashValveDirty", "Set the washout station valve to dirty water out") end
            end
            return
        end
        st._valveWarned = nil
        local lvl = vehicle:getFillUnitFillLevel(fui) or 0
        local out = math.min(lvl, (st.drainRate or 0.01) * dt)
        st.phaseT = math.max(1, (lvl - out) / math.max(0.0001, st.drainRate or 0.01))
        if lvl - out <= 0.5 then
            P.finishRinse(vehicle, st, farm)
        elseif out > 0 then
            vehicle:addFillUnitFillLevel(farm, fui, -out, FillType.WATER, ToolType.UNDEFINED, nil)
            if SPSFillSound ~= nil then SPSFillSound.mark(vehicle, false) end
        end
    elseif st.phase == P.PHASE_DRAIN then
        local lvl = vehicle:getFillUnitFillLevel(fui) or 0
        local out = math.min(lvl, (st.drainRate or 0.01) * dt)
        st.puddleOut = (st.puddleOut or 0) + out
        st.puddleT = (st.puddleT or 0) - dt
        if st.puddleT <= 0 then
            st.puddleT = P.PUDDLE_EVERY_MS / 2
            puddlesAtNozzles(vehicle, cfg, st.puddleOut)
            st.puddleOut = 0
        end
        st.phaseT = math.max(1, (lvl - out) / math.max(0.0001, st.drainRate or 0.01))
        if lvl - out <= 0.5 then
            -- 5) empty: the rinse counts, the player is asked (next rinse / fold boom)
            puddlesAtNozzles(vehicle, cfg, st.puddleOut)
            st.puddleOut = 0
            P.finishRinse(vehicle, st, farm)
        elseif out > 0 then
            vehicle:addFillUnitFillLevel(farm, fui, -out, FillType.WATER, ToolType.UNDEFINED, nil)
        end
    end
end

-- the rinse is over: the last litres go out, the rinse is counted (onWaterEmptied via the fill rule), question asked
function SPSChemWashout.finishRinse(vehicle, st, farm)
    local cfg = P.getCfg(vehicle)
    if vehicle.spsWashHeightTool ~= nil then vehicle.spsWashHeightTool.curTargetPosition = nil; vehicle.spsWashHeightTool = nil end
    local lvl = cfg ~= nil and (vehicle:getFillUnitFillLevel(cfg.mainFui) or 0) or 0
    if not isEmptying(st.phase) then st.phase = P.PHASE_DRAIN end   -- onWaterEmptied counts DRAIN / RETURN as a finished rinse
    if lvl > 0.001 then
        vehicle:addFillUnitFillLevel(farm or 1, cfg.mainFui, -lvl, FillType.WATER, ToolType.UNDEFINED, nil)
    end
    if isEmptying(st.phase) then   -- not emptied through the fill rule (nothing left): count it here
        P.onWaterEmptied(vehicle, st, st.washMaxL or lvl)
    end
    clog("rinse finished: %d of %d done", st.rinsesDone or 0, P.rinsesNeeded())
end

-- the nozzle effects are wanted: the boom spray and the empty - NOT the final tank wash between them
-- water in the main tank (client and server: fill levels are synced). Nothing sounds or sprays from an empty tank -
-- e.g. the station valve still on "dirty water out" so no clean water came in (William 2026-11-07, video)
local function tankHasWater(vehicle)
    local fui = SPSChemMix ~= nil and SPSChemMix.getChemFillUnit(vehicle) or nil
    if fui == nil then return false end
    return (vehicle:getFillUnitFillLevel(fui) or 0) > 0.5
end

local function wantNozzles(vehicle, st)
    if st == nil or not (st.phase == P.PHASE_BOOM or (st.phase == P.PHASE_DRAIN and (st.phaseT or 0) > 0)) then return false end
    return tankHasWater(vehicle)
end

-- fill type whose spray look the nozzles borrow. Only vanilla fill types own a "sprayer" material; the Soil & Fertilizer
-- chemicals and its in-game BLEND_* tank mixes do not (it remaps them to LIQUIDFERTILIZER for its own nozzle effects), so
-- setEffectTypeInfo with one of those drew nothing: puddles but no spray from the boom (William 2026-11-11, log 21:51)
local function nozzleFillType(st)
    local ft = st ~= nil and st.dirtyWith or nil
    if ft == nil or ft == FillType.UNKNOWN then return FillType.LIQUIDFERTILIZER end
    if g_materialManager ~= nil and g_materialManager.getMaterial ~= nil
       and g_materialManager:getMaterial(ft, "sprayer", 1) == nil then
        return FillType.LIQUIDFERTILIZER
    end
    return ft
end

-- Sprayer:updateSprayerEffects override (registered by SPSChemMix.registerOverrides on every Sprayer type). The game
-- switches its nozzle effects only while it sprays (and stops them all on a forced update), so starting them from the
-- side did not hold: during a washout this override IS the switch - every nozzle effect of the boom on, in the look of
-- the chemical being washed out (water has no sprayer material), the sprayer's own spray sound.
function SPSChemWashout.updateSprayerEffects(self, superFunc, force)
    local spec = self.spec_sprayer
    local st = self.spsChemMix
    if spec ~= nil and SPSChemMix ~= nil and SPSChemMix.isOn() and wantNozzles(self, st) then
        if not self.spsWashFx or force then
            local ft = nozzleFillType(st)
            g_effectManager:setEffectTypeInfo(spec.effects, ft)
            g_effectManager:startEffects(spec.effects)
            for _, t in ipairs(spec.sprayTypes or {}) do
                if t.effects ~= nil then
                    g_effectManager:setEffectTypeInfo(t.effects, ft)
                    g_effectManager:startEffects(t.effects)
                end
            end
            if spec.samples ~= nil and spec.samples.spray ~= nil then g_soundManager:playSamples(spec.samples.spray) end
            if spec.animationNodes ~= nil then g_animationManager:startAnimations(spec.animationNodes) end
            spec.lastEffectsState = true
            self.spsWashFx = true
        end
        return
    end
    if self.spsWashFx then
        -- spray stage over: switch the nozzles off HERE. Handing it back to the game's switch did not stop them
        -- (Precision Farming keeps its own effect latch on sprayers) - they ran through the final tank wash.
        self.spsWashFx = nil
        g_effectManager:stopEffects(spec.effects)
        for _, t in ipairs(spec.sprayTypes or {}) do
            if t.effects ~= nil then g_effectManager:stopEffects(t.effects) end
            if t.animationNodes ~= nil then g_animationManager:stopAnimations(t.animationNodes) end
            if t.samples ~= nil and t.samples.spray ~= nil then g_soundManager:stopSamples(t.samples.spray) end
        end
        if spec.samples ~= nil and spec.samples.spray ~= nil then g_soundManager:stopSamples(spec.samples.spray) end
        if spec.animationNodes ~= nil then g_animationManager:stopAnimations(spec.animationNodes) end
        spec.lastEffectsState = false
        return
    end
    return superFunc(self, force)
end

-- washout sounds (client): tank flush while the water bashes round the tank, boom flush (optional) at the nozzles
local function loadWashSamples(vehicle)
    if vehicle.spsWashSamples ~= nil then return vehicle.spsWashSamples end
    local smp = {}
    vehicle.spsWashSamples = smp
    if g_soundManager == nil then return smp end
    local entry = g_slurryPipeManager ~= nil and g_slurryPipeManager.getSprayerVehicleEntry ~= nil
        and g_slurryPipeManager:getSprayerVehicleEntry(vehicle) or nil
    -- the vehicle's own <washout><sounds> (its SPS config file, opened now - a handle kept from loading can be dead),
    -- else the SPS default file
    local function loadFrom(path, key, baseDir, label)
        local xml = path ~= nil and XMLFile.loadIfExists("spsWashoutSounds", path) or nil
        if xml == nil then
            print(string.format("[SPS WASH] washout sounds: cannot open %s (%s)", tostring(path), label))
            return
        end
        smp.tank = {}
        for _, name in ipairs(P.TANK_SOUNDS) do
            local s = g_soundManager:loadSampleFromXML(xml, key, name, baseDir, vehicle.components, 0,
                AudioGroup.VEHICLE, vehicle.i3dMappings, vehicle)
            if s ~= nil then smp.tank[#smp.tank + 1] = s end
        end
        smp.boom = g_soundManager:loadSampleFromXML(xml, key, "boomFlush", baseDir, vehicle.components, 0,
            AudioGroup.VEHICLE, vehicle.i3dMappings, vehicle)
        xml:delete()
        print(string.format("[SPS WASH] washout sounds for %s: %d tank wash sound(s)%s from %s",
            tostring(vehicle.configFileName), #smp.tank, smp.boom ~= nil and " + boom sound" or "", label))
    end
    local src = entry ~= nil and entry.washSoundSrc or nil
    if src ~= nil then loadFrom(src.path, src.key, src.baseDir, "its own <washout><sounds>") end
    if smp.tank == nil or (#smp.tank == 0 and smp.boom == nil) then
        if src ~= nil then print("[SPS WASH] washout sounds: the sprayer's own sounds did not load - using the SPS defaults") end
        loadFrom((P.MOD_DIR or "") .. "sounds/spsWashoutSounds.xml", "sounds", P.MOD_DIR, "sounds/spsWashoutSounds.xml")
    end
    smp.tank = smp.tank or {}
    smp.own = false
    return smp
end

local function setSample(s, on)
    if s == nil then return end
    local playing = g_soundManager:getIsSamplePlaying(s)
    if on and not playing then g_soundManager:playSample(s) elseif not on and playing then g_soundManager:stopSample(s) end
end

local function clientSounds(vehicle, st)
    local ph = st ~= nil and st.phase or 0
    -- tank wash sounds: TANK / FINAL phase AND water in the main tank (not while the cycle waits for the water)
    local tankOn = (ph == P.PHASE_TANK or ph == P.PHASE_FINAL) and tankHasWater(vehicle)
    local boomOn = wantNozzles(vehicle, st)
    if not tankOn and not boomOn and vehicle.spsWashSamples == nil then return end
    local smp = loadWashSamples(vehicle)
    for _, s in ipairs(smp.tank or {}) do setSample(s, tankOn) end
    setSample(smp.boom, boomOn)
    if smp._lastTank ~= tankOn then
        smp._lastTank = tankOn
        local n = 0
        for _, s in ipairs(smp.tank or {}) do if g_soundManager:getIsSamplePlaying(s) then n = n + 1 end end
        clog("tank wash sounds %s (%d of %d playing)", tankOn and "ON" or "OFF", n, #(smp.tank or {}))
    end
end

function SPSChemWashout.deleteSamples(vehicle)
    local smp = vehicle ~= nil and vehicle.spsWashSamples or nil
    if smp == nil or smp.own then return end   -- own samples belong to the SPS entry (deleted with it)
    local all = { smp.boom }
    for _, s in ipairs(smp.tank or {}) do all[#all + 1] = s end
    for _, s in pairs(all) do
        pcall(function() g_soundManager:stopSample(s); g_soundManager:deleteSample(s) end)
    end
    vehicle.spsWashSamples = nil
end

-- client: nozzle effects on / off with the BOOM phase (books are synced, so every peer sees them)
local function clientEffects(vehicle, st)
    local sp = vehicle.spec_sprayer
    if sp == nil then return end
    local want = st ~= nil and (st.phase == P.PHASE_BOOM or (st.phase == P.PHASE_DRAIN and (st.phaseT or 0) > 0))
    local cs = vehicle.spsWashClient or {}
    vehicle.spsWashClient = cs
    if want == (cs.effectsOn == true) then return end
    cs.effectsOn = want
    local ft = nozzleFillType(st)
    if want then
        g_effectManager:setEffectTypeInfo(sp.effects, ft)
        g_effectManager:startEffects(sp.effects)
        for _, t in ipairs(sp.sprayTypes or {}) do
            if t.effects ~= nil then
                g_effectManager:setEffectTypeInfo(t.effects, ft)
                g_effectManager:startEffects(t.effects)
            end
        end
        if sp.samples ~= nil and sp.samples.spray ~= nil then g_soundManager:playSamples(sp.samples.spray) end
    else
        g_effectManager:stopEffects(sp.effects)
        for _, t in ipairs(sp.sprayTypes or {}) do
            if t.effects ~= nil then g_effectManager:stopEffects(t.effects) end
        end
        if sp.samples ~= nil and sp.samples.spray ~= nil then g_soundManager:stopSamples(sp.samples.spray) end
    end
end

local function isMine(vehicle)
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    return root ~= nil and root.getIsActiveForInput ~= nil and root:getIsActiveForInput(true)
end

function SPSChemWashout.onAnswer(yes, args)
    local vehicle, kind = args[1], args[2]
    if vehicle == nil or vehicle.isDeleted then return end
    if kind == P.ASK_NEXT then
        P.request(vehicle, yes and P.ACT_START or P.ACT_FOLD)
    else
        P.request(vehicle, yes and P.ACT_FOLD or P.ACT_DISMISS)
    end
end

-- who gets the question: the player in the cab, or (nobody in a vehicle here) the player on foot near the sprayer
local function askTarget(vehicle)
    if isMine(vehicle) then return true end
    if g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil then return false end   -- in some other vehicle
    if g_localPlayer == nil or g_localPlayer.rootNode == nil or not entityExists(g_localPlayer.rootNode) then return false end
    if vehicle.rootNode == nil or not entityExists(vehicle.rootNode) then return false end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    return MathUtil.vector3Length(px - vx, py - vy, pz - vz) <= (P.ASK_ON_FOOT_RADIUS or 20)
end

local function clientAsk(vehicle, st)
    if st == nil or (st.ask or 0) == P.ASK_NONE or not askTarget(vehicle) then return end
    local cs = vehicle.spsWashClient or {}
    vehicle.spsWashClient = cs
    if cs.askedId == st.askId then return end
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then return end
    cs.askedId = st.askId
    if YesNoDialog == nil or YesNoDialog.show == nil then return end
    local title = txt("sps_washDlgTitle", "Sprayer washout")
    if st.ask == P.ASK_NEXT then
        YesNoDialog.show(P.onAnswer, nil,
            string.format(txt("sps_washDlgNext", "Rinse %d of %d done. Start the next rinse?"), st.rinsesDone or 0, P.rinsesNeeded()),
            title, txt("sps_washDlgNextYes", "Next rinse"), txt("sps_washDlgFold", "Fold boom"), nil, nil, nil, { vehicle, P.ASK_NEXT })
    else
        YesNoDialog.show(P.onAnswer, nil,
            txt("sps_washDlgClean", "Washout complete - the tank is clean. Fold the boom?"),
            title, txt("sps_washDlgFold", "Fold boom"), txt("sps_washDlgLeave", "Leave unfolded"), nil, nil, nil, { vehicle, P.ASK_CLEAN })
    end
end

-- every frame (from SPSChemMix.update, server and clients)
-- [SPS CHEM 2026-11-07] washout stations (placeables with <sprayerPipeSystem><washoutStation/>), server, Chem Mixing
-- on or off. The station's WATER store is the tap and the drain of the ordinary pipe:
--   valve "clean water in"  -> the store is kept FULL (Y load + B at a sprayer draws paid water; nothing can be unloaded)
--   valve "dirty water out" -> the store is kept EMPTY (Y unload + B: whatever arrives vanishes; nothing to draw)
-- Settings "Washout station valve" automatic: the valve follows the cycle (RETURN = dirty, water in = clean) or, with no
-- cycle, the connected sprayer's direction (unload = dirty, load = clean); by hand: only the player at the station moves it.
function SPSChemWashout.tickStations(dt)
    local mgr = g_slurryPipeManager
    if mgr == nil or mgr.registeredSprayerPlaceables == nil then return end
    for _, pe in ipairs(mgr.registeredSprayerPlaceables) do
        if pe.isWashoutStation then
            if not P.valveManual() then
                local dirty = false
                local anyIn = false
                for _, v in ipairs(stationSprayers(pe)) do
                    local st = v.spsChemMix
                    if st ~= nil and st.phase == P.PHASE_RETURN then dirty = true break end
                    if st ~= nil and st.phase == P.PHASE_TANK and (st.moveLeft or 0) > 0 then anyIn = true end
                    if not anyIn and mgr.getSprayerObjectState ~= nil then
                        local s = mgr:getSprayerObjectState(v)
                        if s ~= nil and s.direction ~= SPS_SPRAYER_DIRECTION_FILL then dirty = true break end
                    end
                end
                P.setStationValve(pe, dirty)
            end
            local storage = pe.sourceEntry ~= nil and pe.sourceEntry.storage or nil
            if storage ~= nil and storage.fillLevels ~= nil then
                local want = P.stationValveDirty(pe) and 0 or (storage.capacities ~= nil and storage.capacities[FillType.WATER] or storage.capacity or 0)
                for ft, lvl in pairs(storage.fillLevels) do
                    local target = (ft == FillType.WATER) and want or 0
                    if math.abs((lvl or 0) - target) > 0.001 then storage:setFillLevel(target, ft) end
                end
            end
        end
    end
end

-- [station] client: every handle of the station turns to its cleanRotation / dirtyRotation with the valve state - pipe
-- on or not (William 2026-11-07: with no pipe on the station the panel text changed but the handle did not move). Two
-- handles on the bundled station: the clean tap (open while clean water goes in) and the dirty return (open while the
-- dirty water comes back) - one valve state moves both.
function SPSChemWashout.clientStations(dt)
    local mgr = g_slurryPipeManager
    if mgr == nil or mgr.registeredSprayerPlaceables == nil then return end
    for _, pe in ipairs(mgr.registeredSprayerPlaceables) do
        if pe.isWashoutStation and pe.washoutHandles ~= nil then
            local dirty = P.stationValveDirty(pe)
            for _, h in ipairs(pe.washoutHandles) do
                local node = h.node
                if node ~= nil and node ~= 0 and entityExists(node) then
                    local target = dirty and h.rotDirty or h.rotClean
                    local cur = h.cur
                    if cur == nil then
                        local x, y, z = getRotation(node)
                        cur = { x, y, z }
                        h.cur = cur
                    end
                    local moved = false
                    for i = 1, 3 do
                        local d = target[i] - cur[i]
                        if math.abs(d) > 0.0005 then
                            local step = P.CHANGEOVER_SPEED * dt
                            cur[i] = cur[i] + (d > 0 and math.min(d, step) or math.max(d, -step))
                            moved = true
                        end
                    end
                    if moved then setRotation(node, cur[1], cur[2], cur[3]) end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- [station] valve state: server -> clients (and a client's request in manual mode)
-- ---------------------------------------------------------------------------
SPSWashoutValveEvent = {}
local SPSWashoutValveEvent_mt = Class(SPSWashoutValveEvent, Event)
InitEventClass(SPSWashoutValveEvent, "SPSWashoutValveEvent")

function SPSWashoutValveEvent.emptyNew()
    return Event.new(SPSWashoutValveEvent_mt)
end

function SPSWashoutValveEvent.new(placeable, dirty)
    local self = SPSWashoutValveEvent.emptyNew()
    self.placeable, self.dirty = placeable, dirty == true
    return self
end

function SPSWashoutValveEvent:readStream(streamId, connection)
    self.placeable = NetworkUtil.readNodeObject(streamId)
    self.dirty     = streamReadBool(streamId)
    self:run(connection)
end

function SPSWashoutValveEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteBool(streamId, self.dirty)
end

function SPSWashoutValveEvent:run(connection)
    if self.placeable == nil then return end
    local pe = SPSChemWashout.stationEntryOf(self.placeable)
    if pe == nil then return end
    if not connection:getIsServer() then
        -- a client's hand on the valve: only with the valve set to "by hand", then everyone hears
        if SPSChemWashout.valveManual() then SPSChemWashout.setStationValve(pe, self.dirty) end
        return
    end
    pe.washoutValveDirty = self.dirty   -- server's word on a client
end

-- ---------------------------------------------------------------------------
-- [station] walk-up valve (manual mode): R at the station's handle flips clean water in / dirty water out
-- ---------------------------------------------------------------------------
SPSWashoutValveActivatable = {}
SPSWashoutValveActivatable.__index = SPSWashoutValveActivatable

function SPSWashoutValveActivatable.new(pEntry, node, radius)
    local self = setmetatable({}, SPSWashoutValveActivatable)
    self.pEntry, self.node, self.radius = pEntry, node, radius or 2.5
    self.activateText = ""
    return self
end

function SPSWashoutValveActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

function SPSWashoutValveActivatable:getIsActivatable()
    if g_localPlayer == nil or g_localPlayer.rootNode == nil then return false end
    local pe = self.pEntry
    if pe == nil or not P.valveManual() then return false end
    local node = self.node
    if node == nil or node == 0 or not entityExists(node) then
        local sc = pe.couplings ~= nil and pe.couplings[1] or nil
        node = sc ~= nil and sc.mountNode or nil
        if node == nil or node == 0 or not entityExists(node) then return false end
    end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(node)
    if MathUtil.vector3Length(px - cx, py - cy, pz - cz) > self.radius then return false end
    self.activateText = P.stationValveDirty(pe)
        and txt("action_spsWashValveClean", "Station valve: clean water in")
        or  txt("action_spsWashValveDirty", "Station valve: dirty water out")
    return true
end

function SPSWashoutValveActivatable:getDistance(posX, posY, posZ)
    local node = self.node
    if node == nil or node == 0 or not entityExists(node) then return math.huge end
    local x, y, z = getWorldTranslation(node)
    return MathUtil.vector3Length(posX - x, posY - y, posZ - z)
end

function SPSWashoutValveActivatable:activate() end
function SPSWashoutValveActivatable:deactivate() end
function SPSWashoutValveActivatable:update(dt) end

function SPSWashoutValveActivatable:run()
    local pe = self.pEntry
    if pe == nil then return end
    P.requestStationValve(pe, not P.stationValveDirty(pe))
end

function SPSChemWashout.update(dt)
    if g_server ~= nil then SPSChemWashout.tickStations(dt) end
    if g_client ~= nil then SPSChemWashout.clientStations(dt) end
    if SPSChemMix == nil or not SPSChemMix.isOn() then return end
    if g_server ~= nil then
        for v, _ in pairs(P.running) do
            if v.isDeleted or v.spsChemMix == nil then
                P.running[v] = nil
            else
                local cfg = P.getCfg(v)
                if cfg ~= nil then serverTick(v, v.spsChemMix, cfg, dt) end
            end
        end
    end
    if g_client ~= nil then
        local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
        for _, v in ipairs(vs ~= nil and vs.vehicles or {}) do
            local st = v.spsChemMix
            if st ~= nil and v.spec_sprayer ~= nil then
                if g_server == nil and P.inCycle(st.phase) then
                    st.phaseT = math.max(0, (st.phaseT or 0) - dt)   -- client countdown between syncs
                end
                if v.isClient and v.updateSprayerEffects ~= nil and (wantNozzles(v, st) or v.spsWashFx) then
                    v:updateSprayerEffects()
                end
                if v.isClient then clientSounds(v, st) end
                clientAsk(v, st)
                if isMine(v) then P.refreshActionText(v) end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Wash out key in the cab (appended to Sprayer.onRegisterActionEvents)
-- ---------------------------------------------------------------------------
function SPSChemWashout.onRegisterActionEvents(self, isActiveForInput, isActiveForInputIgnoreSelection)
    if not self.isClient or InputAction.SPS_CHEM_WASHOUT == nil then return end
    if not isActiveForInputIgnoreSelection or SPSChemMix == nil or not SPSChemMix.isOn() then return end
    if SPSChemMix.getChemFillUnit(self) == nil then return end
    local spec = self.spec_sprayer
    local _, id = self:addActionEvent(spec.actionEvents, InputAction.SPS_CHEM_WASHOUT, self, SPSChemWashout.actionEventWashout,
        false, true, false, true, nil)
    if id ~= nil then
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_HIGH)
        g_inputBinding:setActionEventText(id, P.actionText(self))
    end
end

function SPSChemWashout.actionText(vehicle)
    local st = vehicle.spsChemMix
    if st ~= nil and P.inCycle(st.phase) and P.isBusy(st) then
        return txt("action_spsChemWashoutStop", "Stop washout")
    end
    return string.format(txt("action_spsChemWashout", "Wash out sprayer (rinse %d of %d)"),
        math.min(P.rinsesNeeded(), ((st ~= nil and st.rinsesDone) or 0) + 1), P.rinsesNeeded())
end

function SPSChemWashout.actionEventWashout(self, actionName, inputValue, callbackState, isAnalog)
    local st = SPSChemMix.getState(self)
    local busy = P.isBusy(st)
    if not busy then
        local ok, key, fb, a = P.check(self)
        if not ok then
            if key ~= nil then warn(key, fb, a) end
            return
        end
    end
    P.request(self, P.ACT_START)
end

-- keep the key text in step (client, the vehicle you are in)
function SPSChemWashout.refreshActionText(vehicle)
    local spec = vehicle.spec_sprayer
    local ae = spec ~= nil and spec.actionEvents ~= nil and InputAction.SPS_CHEM_WASHOUT ~= nil
        and spec.actionEvents[InputAction.SPS_CHEM_WASHOUT] or nil
    if ae ~= nil and ae.actionEventId ~= nil then
        g_inputBinding:setActionEventText(ae.actionEventId, P.actionText(vehicle))
    end
end

if Sprayer ~= nil and Sprayer.onRegisterActionEvents ~= nil then
    Sprayer.onRegisterActionEvents = Utils.appendedFunction(Sprayer.onRegisterActionEvents, SPSChemWashout.onRegisterActionEvents)
end
-- washout sound samples go with the sprayer
if Sprayer ~= nil and Sprayer.onDelete ~= nil then
    Sprayer.onDelete = Utils.prependedFunction(Sprayer.onDelete, function(self) SPSChemWashout.deleteSamples(self) end)
end

-- ---------------------------------------------------------------------------
-- Fill target: Y at the pump steps fill main tank -> fill rinse tank -> empty (sprayers with a rinse tank)
-- ---------------------------------------------------------------------------
-- [SPS CHEM 2026-11-07] a real tank: fillable whatever the Chem Mixing setting (a new save starts with it OFF, and Y then
-- never offered the rinse tank - William: "I should be able to fill either")
function SPSChemWashout.hasRinseTank(vehicle)
    local cfg = SPSChemMix ~= nil and SPSChemMix.getChemFillUnit(vehicle) ~= nil and P.getCfg(vehicle) or nil
    return cfg ~= nil and cfg.rinseFui ~= nil
end

function SPSChemWashout.isRinseTarget(vehicle)
    local st = vehicle.spsChemMix
    return st ~= nil and st.rinseTarget == true and P.hasRinseTank(vehicle)
end

-- the fill unit a pipe session fills (nil = the coupling's own)
function SPSChemWashout.flowFillUnit(vehicle, state)
    if state ~= nil and state.direction == SPS_SPRAYER_DIRECTION_FILL and P.isRinseTarget(vehicle) then
        return P.getCfg(vehicle).rinseFui
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Network: client -> server request
-- ---------------------------------------------------------------------------
SPSChemWashoutEvent = {}
local SPSChemWashoutEvent_mt = Class(SPSChemWashoutEvent, Event)
InitEventClass(SPSChemWashoutEvent, "SPSChemWashoutEvent")

function SPSChemWashoutEvent.emptyNew()
    return Event.new(SPSChemWashoutEvent_mt)
end

function SPSChemWashoutEvent.new(vehicle, act, value)
    local self = SPSChemWashoutEvent.emptyNew()
    self.vehicle, self.act, self.value = vehicle, act, value == true
    return self
end

function SPSChemWashoutEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.act     = streamReadUInt8(streamId)
    self.value   = streamReadBool(streamId)
    self:run(connection)
end

function SPSChemWashoutEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUInt8(streamId, self.act)
    streamWriteBool(streamId, self.value)
end

function SPSChemWashoutEvent:run(connection)
    if connection:getIsServer() or self.vehicle == nil then return end   -- client -> server only
    if self.act < SPSChemWashout.ACT_START or self.act > SPSChemWashout.ACT_DISMISS then return end
    if self.vehicle.isDeleted or SPSChemMix == nil or SPSChemMix.getChemFillUnit(self.vehicle) == nil then return end
    SPSChemWashout.apply(self.vehicle, self.act, self.value)
end
