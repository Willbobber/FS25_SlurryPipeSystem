-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.2.0

-- SPSChemMix.lua — [SPS CHEM 2026-11-05] concentrate + water dilution (CHEM_DILUTION_SPEC.md parts 1, 2 and 3)
--
-- Toggle: featureToggles.chemMixing (SPS settings "Chem Mixing"). Ratio: featureToggles.chemRatio = water parts per
-- part of concentrate (4 / 9 / 19 / 49, default 9).
--
-- Concentrate is its own fill type (fillTypes/spsChemFillTypes.xml): LIQUIDFERTILIZER_CONC, HERBICIDE_CONC.
--   * every fill unit that takes LIQUIDFERTILIZER / HERBICIDE also takes the matching concentrate (loadFillUnitFromXML)
--   * pallets (no Attachable / Motorized / Sprayer) that START full of LF / HERB - i.e. shop purchases - start as
--     concentrate while the toggle is on; their shop price is base x (water parts + 1) (applyPrices)
--   * PalletSpawner pallets (productions) spawn empty and are filled after, so they stay the normal (ready mix) type
--   * [SPS CHEM 2026-11-08] MOD LIQUIDS (William: "we just want liquids but need the ones from Soil and Fert"): after every
--     mod's fill types are in (FillTypeManager.loadModFillTypes, appended) SPS makes a <NAME>_CONC twin for every fill type
--     that sits in a PURE sprayer-liquid category - one holding LIQUIDFERTILIZER or HERBICIDE and none of the dry / slurry
--     markers (NOT_LIQUID_MARKERS). Soil & Fertilizer's UAN32 / UAN28 / Anhydrous / Starter / Liquid urea ... qualify (its
--     "LIQUIDFERTILIZER" category); its powders (UREA AN AMS MAP DAP ...) sit only in the FERTILIZER category and are left
--     alone - they go through dry spreaders. A twin's FAMILY is LF or HERB (whichever its category holds): a tank that
--     takes the family type takes the twin too, because S&F adds its liquids to LF tanks in FillUnit.onPostLoad, AFTER
--     loadFillUnitFromXML has run. Console `spsChemPallets`: liquids, twins, categories, every shop pallet + its verdict.
--     ~22:00: a twin is made ONLY for a liquid some mod SELLS as a pallet (startFillType of a modDesc storeItem, multi-buy
--     packs followed) - S&F 2.5.0.77 lists 48 liquids but sells 20; its 28 BLEND_* tank mixes are made in game, never
--     bought, and the game allows 255 fill types in all (FillTypeManager.SEND_NUM_BITS = 8). Hard stop with a warning at
--     TWIN_CAP_HEADROOM below that cap. NOT_CONCENTRATE names a sold liquid that is never a tank-mix concentrate
--     (anhydrous ammonia is a pressurised gas knifed into the soil, starter 10-34-0 goes neat in-furrow): no twin, normal
--     price. While the toggle is on every repriced shop pallet is also RENAMED "<name> (concentrate)" (sps_chemStoreConcName)
--     so the player sees why it costs what it costs (William 2026-11-08: "add concentrate to its name so players know").
--
-- PART 1 - a sprayer's chem tank (first fill unit that takes LF or HERB) never holds concentrate: it holds the normal
-- fill type and SPS keeps books (vehicle.spsChemMix):
--   type      base chemical held (LIQUIDFERTILIZER / HERBICIDE / any other sprayable), nil = none
--   chemL     litres of concentrate in the tank
--   waterL    litres of water in the tank (chemL + waterL = the tank's fill level)
--   washing   true while the tank holds plain WATER (a washout)
--   dirtyWith last chemical sprayed out; a different chemical needs a washout first
--   mixL      litres of the tank that came in as READY MIX (its concentrate / water share is inside chemL / waterL;
--             kept apart only so the panel can say "ready mix" instead of showing water nobody added)
-- Ready mix (buying station, silo, untracked source) is booked as 1 part concentrate : N parts water.
-- Strength = (chemL / total) x (N + 1); 1.0 = exactly on ratio.
--
-- PART 3 (2026-11-07) - EVERY tank that holds mix carries the same books: trailers, IBCs, bowsers (any FillUnit vehicle
-- whose unit takes LF / HERB, the first such unit) and silo / production STORAGES (storage.spsChemBooks[fillType]).
-- A non-sprayer tank may hold PURE concentrate (the shop IBC): no books, strength = N + 1; water into it makes it a
-- booked mix, more concentrate keeps it pure. Litres moving between tanks carry their strength: the sender's share
-- (concentrate litres per litre) rides in SPSChemMix.ctx while the receiver's add runs - set around the SPS pipe
-- transfers (SPSM_Flow / SPSM_Sprayers), vanilla discharge (Dischargeable:dischargeToObject -> trailer, silo
-- unload trigger), vanilla fill triggers (LoadingStation:addFillLevelToFillableObject <- silo) and storage writes
-- (Storage:setFillLevel). No context = ready mix (buying station, silo refill, production output, AI helper).
-- Rinse water leaving a washing sprayer by pipe / discharge carries its residue: a receiving tank that takes the
-- chemical books it as a (very) thin mix of that chemical (ctx.waterChem).
--
-- PART 2 (2026-11-07) - FIELD EFFECT (processSprayerArea, strength of the tank feeding the boom):
--   < 80 %      too weak: nothing written, litres used ("another pass needed")
--   80-120 %    good: normal pass
--   120-180 %   strong: normal pass, concentrate wasted
--   180-250 %   double: fertiliser +2 levels (herbicide: normal kill)
--   >= 250 %    scorch: the patch's fertiliser level is stripped (spray level + spray type reset)
--   >= 400 %    flatten: crop destroyed (the wheel-destruction write) + stripped
--   Not washed out (herbicide residue in the new mix, st.contamType / contamLevel): >= CONTAM_SCORCH strips, >=
--   CONTAM_KILL destroys, on top of the pass.
--   Soil & Fertilizer loaded: the litres it books (onFertilizerApplied / onHerbicideAppliedDirect) are scaled by the
--   strength, its own burn (applyBurnEffect, > 1.25 / 1.5) is fed the strength, SPS scorch / flatten OFF.
--   Precision Farming on the sprayer: N scaled through getCurrentNitrogenLevelOffset (PF's hook for exactly this),
--   its over-fertilisation curve does the damage, SPS scorch / flatten OFF. Too weak writes nothing in every case.
--
-- Books are server-side (the fill code runs there); SPSChemBooksEvent copies them to clients for the HUD. Spraying
-- takes concentrate and water out in proportion, so the ratio only changes when something goes IN - that is the only
-- time an event is sent (throttled).

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSChemMix 1.0.2.0 loaded") end

SPSChemMix = {}
SPSChemMix.RATIOS        = { 4, 9, 19, 49 }
SPSChemMix.DEFAULT_RATIO = 9
SPSChemMix.SYNC_MS       = 500
SPSChemMix.PAIRS         = { { "LIQUIDFERTILIZER", "LIQUIDFERTILIZER_CONC" }, { "HERBICIDE", "HERBICIDE_CONC" } }
-- [SPS CHEM 2026-11-08] mod liquids: a fill type is a sprayer liquid when some category holds it together with
-- LIQUIDFERTILIZER or HERBICIDE and holds NONE of these (a dry / bulk / slurry / "everything" silo category does not vote)
SPSChemMix.NOT_LIQUID_MARKERS = { "FERTILIZER", "LIME", "SEEDS", "MANURE", "LIQUIDMANURE", "DIGESTATE", "WATER", "DIESEL",
    "MILK", "WHEAT", "BARLEY", "GRASS_WINDROW", "SILAGE", "WOODCHIPS", "SUGARBEET", "POTATO", "MINERAL_FEED", "PIGFOOD",
    "FORAGE", "STRAW", "HAY" }
SPSChemMix.dynamicPairs = {}   -- { baseName, concName, familyName } made by createConcentrateTwins (mod liquids)
SPSChemMix.unsoldLiquids = {}  -- liquid name -> true: qualifies by category but no mod sells it as a pallet (no twin)
SPSChemMix.cappedLiquids = {}  -- liquid name -> true: twin NOT made, the fill type cap was reached
SPSChemMix.TWIN_CAP_HEADROOM = 4   -- fill types left free below the engine cap (2^SEND_NUM_BITS - 1)
-- [SPS CHEM 2026-11-08] sold sprayer liquids that are NOT tank-mix concentrates in real life: no twin, sold at the normal
-- price. ANHYDROUS = pressurised ammonia gas, knifed into the soil, never in a sprayer tank with water; STARTER = 10-34-0
-- placed neat in-furrow by the planter. Everything else that qualifies (UAN, liquid urea / AMS / MAP / DAP / potash, the
-- insecticide / fungicide actives, liquid lime, LF, herbicide) is bought strong and diluted in the tank.
SPSChemMix.NOT_CONCENTRATE = { ANHYDROUS = true, STARTER = true }
SPSChemMix.notConcLiquids  = {}  -- liquid name -> true: in NOT_CONCENTRATE, no twin
SPSChemMix.PALLET_FILLUNIT_KEY = "vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration(0).fillUnits.fillUnit"
SPSChemMix.baseFamily   = {}   -- base index -> LIQUIDFERTILIZER / HERBICIDE index (the two base types map to themselves)

-- strength bands (spec): lower bound, l10n key suffix, r g b
SPSChemMix.BANDS = {
    { 0.00, "Weak",    0.95, 0.30, 0.20 },
    { 0.80, "Good",    0.30, 0.85, 0.35 },
    { 1.20, "Strong",  1.00, 0.75, 0.20 },
    { 1.80, "Double",  1.00, 0.60, 0.15 },
    { 2.50, "Scorch",  0.95, 0.30, 0.20 },
    { 4.00, "Flatten", 0.95, 0.16, 0.16 },
}
-- [SPS CHEM 2026-11-07] field effect thresholds (part 2)
SPSChemMix.WEAK_BELOW    = 0.80
SPSChemMix.DOUBLE_FROM   = 1.80
SPSChemMix.SCORCH_FROM   = 2.50
SPSChemMix.FLATTEN_FROM  = 4.00
SPSChemMix.CONTAM_SCORCH = 0.15   -- herbicide residue strength (1 = full-strength mix) that strips the fertiliser
SPSChemMix.CONTAM_KILL   = 0.50   -- ... that destroys the crop
SPSChemMix.SF_BURN_FROM  = 1.25   -- Soil & Fertilizer BURN_RISK_THRESHOLD (its constant is read when present)
SPSChemMix.WARN_MS       = 4000   -- field warnings: at most one per vehicle per this many ms

SPSChemMix.concToBase = {}   -- concentrate index -> base index
SPSChemMix.baseToConc = {}   -- base index -> concentrate index
SPSChemMix.pending    = {}   -- vehicle uniqueId -> saved books (applied when the state is first made)
SPSChemMix.pendingStorage = {}   -- storage key -> { [fillType] = { chemL, waterL } } (applied on first use)
SPSChemMix.dirty      = {}   -- vehicle -> true (server: books changed, send to clients)
SPSChemMix._syncTimer = 0
SPSChemMix.ctx        = nil  -- [part 3] transfer context while a receiver's add runs: { share = conc litres per
                             -- litre of the base type coming in, waterChem = { type, share } for rinse water }

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
SPSChemMix.warn = warn

local function ftName(ft)
    return (ft ~= nil and g_fillTypeManager:getFillTypeNameByIndex(ft)) or "?"
end

local function ftTitle(ft)
    local d = ft ~= nil and g_fillTypeManager:getFillTypeByIndex(ft) or nil
    return d ~= nil and d.title or ftName(ft)
end

local function i18n(key, fallback)
    if g_i18n ~= nil and g_i18n:hasText(key) then return g_i18n:getText(key) end
    return fallback
end

function SPSChemMix.isOn()
    local m = g_slurryPipeManager
    return m ~= nil and m.featureToggles ~= nil and m.featureToggles.chemMixing == true
end

-- water parts per part of concentrate
function SPSChemMix.waterParts()
    local m = g_slurryPipeManager
    local r = m ~= nil and m.featureToggles ~= nil and tonumber(m.featureToggles.chemRatio) or nil
    for _, v in ipairs(SPSChemMix.RATIOS) do
        if v == r then return v end
    end
    return SPSChemMix.DEFAULT_RATIO
end

function SPSChemMix.resolveFillTypes()
    if SPSChemMix._resolved then return end
    local function pair(baseName, concName, familyName)
        local b = g_fillTypeManager:getFillTypeIndexByName(baseName)
        local c = g_fillTypeManager:getFillTypeIndexByName(concName)
        if b ~= nil and c ~= nil and c ~= FillType.UNKNOWN then
            SPSChemMix.concToBase[c] = b
            SPSChemMix.baseToConc[b] = c
            local f = familyName ~= nil and g_fillTypeManager:getFillTypeIndexByName(familyName) or nil
            SPSChemMix.baseFamily[b] = f or b
        end
    end
    for _, p in ipairs(SPSChemMix.PAIRS) do pair(p[1], p[2], nil) end
    for _, p in ipairs(SPSChemMix.dynamicPairs) do pair(p[1], p[2], p[3]) end   -- [SPS CHEM 2026-11-08] mod liquids
    SPSChemMix._resolved = next(SPSChemMix.concToBase) ~= nil
    if not SPSChemMix._resolved then
        print("[SPS] WARNING: chem concentrate fill types not found (fillTypes/spsChemFillTypes.xml not loaded?)")
    end
end

function SPSChemMix.isConcentrate(fillType)
    SPSChemMix.resolveFillTypes()
    return fillType ~= nil and SPSChemMix.concToBase[fillType] ~= nil
end

-- a chemical SPS books (has a concentrate twin)
function SPSChemMix.isChemBase(fillType)
    SPSChemMix.resolveFillTypes()
    return fillType ~= nil and SPSChemMix.baseToConc[fillType] ~= nil
end

-- ---------------------------------------------------------------------------
-- Type overrides (called from init.lua registerOverrides, after finalizeTypes)
-- ---------------------------------------------------------------------------
local function typeHas(typeEntry, className)
    for _, spec in ipairs(typeEntry.specializations or {}) do
        if spec.className == className then return true end
    end
    return false
end

-- a pallet-like object: fill unit, but nothing that drives, attaches or sprays (IBC, canister, barrel, bag)
-- ---------------------------------------------------------------------------
-- [SPS CHEM 2026-11-08] Concentrate twins for MOD liquids (William: Soil & Fertilizer's UAN32 tubs cost the normal price;
-- "we just want liquids but need the ones from Soil and Fert"). Runs once, appended to FillTypeManager.loadModFillTypes -
-- after EVERY mod's fill types and categories are in (a Mission00.loadMapData task), on server and clients alike: same
-- mods, same sorted order, same indices. A fill type is a sprayer liquid when some category holds it together with
-- LIQUIDFERTILIZER or HERBICIDE and holds none of NOT_LIQUID_MARKERS (the base SPRAYER category and S&F's own
-- LIQUIDFERTILIZER category qualify; a map silo category listing everything does not vote). Powders live only in
-- FERTILIZER-type categories and never qualify. The two base types keep their xml twins (spsChemFillTypes.xml).
-- ---------------------------------------------------------------------------
function SPSChemMix.isSprayerLiquidCategory(fm, ftSet)
    local lf, hb = fm:getFillTypeIndexByName("LIQUIDFERTILIZER"), fm:getFillTypeIndexByName("HERBICIDE")
    if not ((lf ~= nil and ftSet[lf]) or (hb ~= nil and ftSet[hb])) then return false end
    for _, marker in ipairs(SPSChemMix.NOT_LIQUID_MARKERS) do
        local mi = fm:getFillTypeIndexByName(marker)
        if mi ~= nil and ftSet[mi] then return false end
    end
    return true
end

-- every sprayer liquid: index -> family index (LIQUIDFERTILIZER or HERBICIDE; a type in both families = LF)
function SPSChemMix.collectSprayerLiquids(fm)
    local out = {}
    local lf, hb = fm:getFillTypeIndexByName("LIQUIDFERTILIZER"), fm:getFillTypeIndexByName("HERBICIDE")
    for _, ftSet in pairs(fm.categoryNameToFillTypes or {}) do
        if SPSChemMix.isSprayerLiquidCategory(fm, ftSet) then
            local fam = (lf ~= nil and ftSet[lf]) and lf or hb
            for ft, _ in pairs(ftSet) do
                local d = fm:getFillTypeByIndex(ft)
                if d ~= nil and d.name ~= nil and ft ~= FillType.UNKNOWN and string.sub(d.name, -5) ~= "_CONC" then
                    if out[ft] == nil or fam == lf then out[ft] = fam end
                end
            end
        end
    end
    if lf ~= nil then out[lf] = lf end
    if hb ~= nil then out[hb] = hb end
    return out
end

-- [SPS CHEM 2026-11-08] every start fill type a MOD sells in the shop (modDesc storeItems, already collected by the base
-- StoreManager at mod load as g_storeManager.modStoreItems; a multi-buy pack is followed to the pallet it spawns). The
-- xml files are read here, before the store items exist. nil = the list is not available (no filter).
function SPSChemMix.collectModSoldStartTypes()
    local items = g_storeManager ~= nil and g_storeManager.modStoreItems or nil
    if items == nil then return nil, 0 end
    local out, n = {}, 0
    local key = SPSChemMix.PALLET_FILLUNIT_KEY
    for _, it in ipairs(items) do
        if it.xmlFilename ~= nil then
            -- modStoreItems keep the RELATIVE path from modDesc; StoreManager:loadItem joins it with baseDir the same way
            -- (2026-11-08 22:55: passed raw, nothing was found -> "0 sold by mods" -> no S&F twin, William's report)
            local ft = SPSChemMix._readPalletXml(Utils.getFilename(it.xmlFilename, it.baseDir), key)
            if ft == nil and SPSChemMix._mipTarget ~= nil then
                ft = SPSChemMix._readPalletXml(Utils.getFilename(SPSChemMix._mipTarget, it.baseDir), key)
            end
            if ft ~= nil then
                ft = string.upper(ft)
                if out[ft] == nil then n = n + 1 end
                out[ft] = true
            end
        end
    end
    return out, n
end

function SPSChemMix.createConcentrateTwins(fm)
    if fm == nil or fm.getFillTypeIndexByName == nil then fm = g_fillTypeManager end
    if fm == nil or SPSChemMix._twinsDone or FillTypeDesc == nil then return end
    SPSChemMix._twinsDone = true
    local lf   = fm:getFillTypeIndexByName("LIQUIDFERTILIZER")
    local mult = SPSChemMix.waterParts() + 1
    local liquids = SPSChemMix.collectSprayerLiquids(fm)
    local sold, nSold = SPSChemMix.collectModSoldStartTypes()
    local order = {}
    for ft, _ in pairs(liquids) do table.insert(order, fm:getFillTypeByIndex(ft)) end
    table.sort(order, function(a, b) return a.name < b.name end)   -- deterministic indices on every machine
    local cap = 2 ^ (FillTypeManager.SEND_NUM_BITS or 8) - 1 - SPSChemMix.TWIN_CAP_HEADROOM
    local names, made, unsold, capped, notConc = {}, {}, {}, {}, {}
    for _, base in ipairs(order) do
        local fam   = liquids[base.index]
        local cname = base.name .. "_CONC"
        table.insert(names, base.name)
        local static = false
        for _, p in ipairs(SPSChemMix.PAIRS) do if p[1] == base.name then static = true end end
        if not static and SPSChemMix.NOT_CONCENTRATE[base.name] then
            -- sold, liquid, but never a tank-mix concentrate (see NOT_CONCENTRATE): no twin, normal price
            SPSChemMix.notConcLiquids[base.name] = true
            table.insert(notConc, base.name)
        elseif not static and sold ~= nil and not sold[base.name] then
            -- qualifies by category, but nothing in the shop spawns full of it (S&F's BLEND_* tank mixes): no twin
            SPSChemMix.unsoldLiquids[base.name] = true
            table.insert(unsold, base.name)
        elseif not static and fm:getFillTypeIndexByName(cname) == nil and #fm.fillTypes >= cap then
            SPSChemMix.cappedLiquids[base.name] = true
            table.insert(capped, base.name)
        else
        if fm:getFillTypeIndexByName(cname) == nil then
            local d = FillTypeDesc.new()
            d.name  = cname
            d.title = string.format(i18n("sps_chemConcTitle", "%s concentrate"), base.title or base.name)
            d.unitShort        = base.unitShort
            d.showOnPriceTable = false
            d.isBulkType   = base.isBulkType == true
            d.isPalletType = base.isPalletType == true
            d.isBaleType   = false
            d.massPerLiter = base.massPerLiter or d.massPerLiter
            d.maxPhysicalSurfaceAngle = base.maxPhysicalSurfaceAngle or d.maxPhysicalSurfaceAngle
            d.hudOverlayFilename = base.hudOverlayFilename
            d.palletFilename     = nil
            d.pricePerLiter      = (base.pricePerLiter or 0) * mult
            d.startPricePerLiter = (base.startPricePerLiter or base.pricePerLiter or 0) * mult
            for period, f in pairs((base.economy ~= nil and base.economy.factors) or {}) do
                d.economy.factors[period] = f
                d.economy.history[period] = f * d.pricePerLiter
            end
            d.prioritizedEffectType = base.prioritizedEffectType or d.prioritizedEffectType
            d.fillSmokeColor  = base.fillSmokeColor
            d.fruitSmokeColor = base.fruitSmokeColor
            if fm:addFillType(d) then
                d:finalize()
                table.insert(made, cname)
            end
        end
        if not static then
            table.insert(SPSChemMix.dynamicPairs, { base.name, cname, (fam == lf) and "LIQUIDFERTILIZER" or "HERBICIDE" })
        end
        end
    end
    SPSChemMix._resolved = false   -- the maps may have been built before the twins existed: rebuild them
    SPSChemMix.resolveFillTypes()
    print(string.format("[SPS] chem mix: %d sprayer liquid(s) [%s]; %d sold by mods; %d concentrate twin(s) made [%s]; %d not sold, no twin [%s]; %d not a concentrate [%s]; fill types now %d of %d",
        #names, table.concat(names, " "), nSold or 0, #made, table.concat(made, " "), #unsold, table.concat(unsold, " "),
        #notConc, table.concat(notConc, " "), #fm.fillTypes, cap + SPSChemMix.TWIN_CAP_HEADROOM))
    if #capped > 0 then
        print(string.format("[SPS] WARNING: chem mix: fill type cap reached - NO concentrate twin for %d liquid(s) [%s]; their pallets stay at the normal price",
            #capped, table.concat(capped, " ")))
    end
end

if FillTypeManager ~= nil and FillTypeManager.loadModFillTypes ~= nil and not SPSChemMix._twinHookInstalled then
    SPSChemMix._twinHookInstalled = true
    FillTypeManager.loadModFillTypes = Utils.appendedFunction(FillTypeManager.loadModFillTypes, SPSChemMix.createConcentrateTwins)
end

function SPSChemMix.isPalletType(typeEntry)
    return typeEntry ~= nil and typeHas(typeEntry, "FillUnit") and not typeHas(typeEntry, "Attachable")
        and not typeHas(typeEntry, "Motorized") and not typeHas(typeEntry, "Sprayer")
end

function SPSChemMix.registerOverrides(types)
    local nFill, nPallet, nSpray, nDisch, nPF = 0, 0, 0, 0, 0
    for _, typeEntry in pairs(types or {}) do
        if typeHas(typeEntry, "FillUnit") then
            if SPSChemMix.isPalletType(typeEntry) then
                SpecializationUtil.registerOverwrittenFunction(typeEntry, "loadFillUnitFromXML", SPSChemMix.loadFillUnitFromXMLPallet)
                nPallet = nPallet + 1
            else
                SpecializationUtil.registerOverwrittenFunction(typeEntry, "loadFillUnitFromXML", SPSChemMix.loadFillUnitFromXML)
            end
            nFill = nFill + 1
            -- [SPS CHEM 2026-11-07 part 3] books on EVERY tank that can hold a chemical (was: sprayers only)
            SpecializationUtil.registerOverwrittenFunction(typeEntry, "addFillUnitFillLevel", SPSChemMix.addFillUnitFillLevel)
            SpecializationUtil.registerOverwrittenFunction(typeEntry, "getFillUnitAllowsFillType", SPSChemMix.getFillUnitAllowsFillType)
            if typeHas(typeEntry, "Sprayer") then
                SpecializationUtil.registerOverwrittenFunction(typeEntry, "getSprayerUsage", SPSChemMix.getSprayerUsage)
                SpecializationUtil.registerOverwrittenFunction(typeEntry, "processSprayerArea", SPSChemMix.processSprayerArea)
                SpecializationUtil.registerOverwrittenFunction(typeEntry, "getSprayerDoubledAmountActive", SPSChemMix.getSprayerDoubledAmountActive)
                if SPSChemWashout ~= nil then   -- [SPS CHEM 2026-11-07] washout nozzle effects
                    SpecializationUtil.registerOverwrittenFunction(typeEntry, "updateSprayerEffects", SPSChemWashout.updateSprayerEffects)
                end
                -- [part 2] Precision Farming: its ExtendedSprayer asks the tank vehicle for a nitrogen level offset
                if typeHas(typeEntry, "ExtendedSprayer") then
                    SpecializationUtil.registerOverwrittenFunction(typeEntry, "getCurrentNitrogenLevelOffset", SPSChemMix.getCurrentNitrogenLevelOffset)
                    nPF = nPF + 1
                end
                nSpray = nSpray + 1
            end
            -- [part 3] a tipping / pumping vehicle hands its strength to whatever it discharges into
            if typeHas(typeEntry, "Dischargeable") then
                SpecializationUtil.registerOverwrittenFunction(typeEntry, "dischargeToObject", SPSChemMix.dischargeToObject)
                nDisch = nDisch + 1
            end
        end
    end
    SPSChemMix.installGlobalHooks()
    print(string.format("[SPS] chem mix: concentrate support on %d fill unit types (%d pallet types), books on all; sprayer field effect on %d types (%d with Precision Farming), discharge strength on %d types",
        nFill, nPallet, nSpray, nPF, nDisch))
end

-- [part 3] class-level hooks (once): storage books, silo fill triggers, Soil & Fertilizer litres
function SPSChemMix.installGlobalHooks()
    if SPSChemMix._hooked then return end
    SPSChemMix._hooked = true
    if Storage ~= nil and Storage.setFillLevel ~= nil then
        Storage.setFillLevel = Utils.overwrittenFunction(Storage.setFillLevel, SPSChemMix.storageSetFillLevel)
    end
    if LoadingStation ~= nil and LoadingStation.addFillLevelToFillableObject ~= nil then
        LoadingStation.addFillLevelToFillableObject = Utils.overwrittenFunction(LoadingStation.addFillLevelToFillableObject, SPSChemMix.loadingStationFill)
    end
    if Sprayer ~= nil and Sprayer.onEndWorkAreaProcessing ~= nil then
        -- [part 2] the strength of the pass is published for the Soil & Fertilizer booking hook (an appended hook of
        -- the same event, installed after ours as S&F loads after SPS; a PREPEND runs before every append)
        Sprayer.onEndWorkAreaProcessing = Utils.prependedFunction(Sprayer.onEndWorkAreaProcessing, SPSChemMix.onEndWorkAreaProcessingPre)
        Sprayer.onEndWorkAreaProcessing = Utils.appendedFunction(Sprayer.onEndWorkAreaProcessing, SPSChemMix.onEndWorkAreaProcessingPost)
    end
end

local function extendFillUnit(vehicle, entry, isPallet)
    SPSChemMix.resolveFillTypes()
    local sft = entry ~= nil and entry.supportedFillTypes or nil
    if sft == nil then return end
    local isChemTank = false
    for base, conc in pairs(SPSChemMix.baseToConc) do
        -- [SPS CHEM 2026-11-08] a mod liquid's twin also goes where its FAMILY type goes: S&F adds UAN32 etc. to every
        -- LIQUIDFERTILIZER tank later (FillUnit.onPostLoad), after this override has run
        local fam = SPSChemMix.baseFamily[base]
        if sft[base] or (fam ~= nil and fam ~= base and sft[fam]) then
            sft[conc] = true
            isChemTank = true
            -- [SPS CHEM 2026-11-06] a container that dresses itself by fill type (mrh canister / barrel decals) has no
            -- entry for the concentrate and kept its i3d default (the herbicide decal on a fertiliser canister):
            -- the concentrate wears the base product's materials
            local mats = entry.fillTypeMaterials
            if mats ~= nil then
                local add = {}
                for _, m in ipairs(mats) do
                    if m.fillTypeIndex == base then
                        local c = {}
                        for k, v in pairs(m) do c[k] = v end
                        c.fillTypeIndex = conc
                        table.insert(add, c)
                    end
                end
                for _, c in ipairs(add) do table.insert(mats, c) end
            end
        end
    end
    if not isChemTank or not SPSChemMix.isOn() then return end
    if isPallet then
        -- shop purchase (no savegame: FillUnit:onPostLoad adds the start level) -> concentrate
        local conc = entry.startFillTypeIndex ~= nil and SPSChemMix.baseToConc[entry.startFillTypeIndex] or nil
        if conc ~= nil and (entry.startFillLevel or 0) > 0 then
            entry.startFillTypeIndex = conc
        end
    elseif vehicle.spec_sprayer ~= nil and not sft[FillType.WATER]
    and not (sft[FillType.LIQUIDMANURE] or sft[FillType.DIGESTATE] or sft[FillType.MANURE]) then
        -- fert / herb sprayer chem tank: water for diluting / washing out (never a slurry tank / spreader)
        sft[FillType.WATER] = true
        entry.spsChemAddedWater = true
    end
end

function SPSChemMix.loadFillUnitFromXML(self, superFunc, xmlFile, key, entry, index)
    local ok = superFunc(self, xmlFile, key, entry, index)
    extendFillUnit(self, entry, false)
    return ok
end

function SPSChemMix.loadFillUnitFromXMLPallet(self, superFunc, xmlFile, key, entry, index)
    local ok = superFunc(self, xmlFile, key, entry, index)
    extendFillUnit(self, entry, true)
    return ok
end

-- ---------------------------------------------------------------------------
-- Books
-- ---------------------------------------------------------------------------
-- The vehicle's chem tank: first fill unit that takes LIQUIDFERTILIZER or HERBICIDE (nil = none).
-- Sprayers: "sprayer" in FS25 also covers slurry tankers, dribble bars, splash plates and manure spreaders (same
-- Sprayer spec) - anything that spreads manure / slurry / digestate is out. [part 3] Any other FillUnit vehicle
-- (trailer, IBC, bowser): its first unit that takes a chemical.
function SPSChemMix.getChemFillUnit(vehicle)
    if vehicle == nil or vehicle.spec_fillUnit == nil then return nil end
    if vehicle.spsChemFui ~= nil then return vehicle.spsChemFui or nil end
    SPSChemMix.resolveFillTypes()
    if vehicle.spec_sprayer ~= nil then
        if vehicle.spec_manureBarrel ~= nil or vehicle.spec_manureSpreader ~= nil
        or (vehicle.spec_sprayer.isSlurryTanker == true) or (vehicle.spec_sprayer.isManureSpreader == true) then
            vehicle.spsChemFui = false
            return nil
        end
        for _, fu in ipairs(vehicle.spec_fillUnit.fillUnits or {}) do
            local sft = fu.supportedFillTypes or {}
            if sft[FillType.LIQUIDMANURE] or sft[FillType.DIGESTATE] or sft[FillType.MANURE] then
                vehicle.spsChemFui = false
                return nil
            end
        end
    end
    for fui, fu in ipairs(vehicle.spec_fillUnit.fillUnits or {}) do
        for base, _ in pairs(SPSChemMix.baseToConc) do
            if fu.supportedFillTypes ~= nil and fu.supportedFillTypes[base] then
                vehicle.spsChemFui = fui
                return fui
            end
        end
    end
    vehicle.spsChemFui = false
    return nil
end

-- [SPS MKS8 2026-11-11] a TANKER with several chem-capable units (MKS 8 Dual Tank: both tanks take LF / HERB) books
-- each unit on its own (vehicle.spsChemMixByFui[fui]; the vehicle's chem tank stays vehicle.spsChemMix). A sprayer keeps
-- ONE chem tank - the washout, bowl and usage rules are built on it.
function SPSChemMix.isChemFillUnit(vehicle, fui)
    if vehicle == nil or fui == nil then return false end
    local cf = SPSChemMix.getChemFillUnit(vehicle)
    if cf == nil then return false end
    if fui == cf then return true end
    if vehicle.spec_sprayer ~= nil then return false end
    local fu = vehicle.spec_fillUnit.fillUnits[fui]
    if fu == nil or fu.supportedFillTypes == nil then return false end
    for base, _ in pairs(SPSChemMix.baseToConc) do
        if fu.supportedFillTypes[base] then return true end
    end
    return false
end

-- every chem-capable unit of a vehicle, the vehicle's chem tank first ({} = none)
function SPSChemMix.chemFillUnits(vehicle)
    local list = {}
    local cf = SPSChemMix.getChemFillUnit(vehicle)
    if cf == nil then return list end
    list[1] = cf
    if vehicle.spec_sprayer == nil then
        for fui, _ in ipairs(vehicle.spec_fillUnit.fillUnits or {}) do
            if fui ~= cf and SPSChemMix.isChemFillUnit(vehicle, fui) then list[#list + 1] = fui end
        end
    end
    return list
end

-- a fert / herb SPRAYER with a chem tank (the panel, washout, bowl and water rules are for these only)
function SPSChemMix.isChemSprayer(vehicle)
    return vehicle ~= nil and vehicle.spec_sprayer ~= nil and SPSChemMix.getChemFillUnit(vehicle) ~= nil
end

-- Toggle switched at runtime: WATER on / off every sprayer chem tank (off only while it holds no water).
function SPSChemMix.applyWaterSupportAll()
    local on = SPSChemMix.isOn()
    local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    for _, v in ipairs(vs ~= nil and vs.vehicles or {}) do
        local fui = SPSChemMix.isChemSprayer(v) and SPSChemMix.getChemFillUnit(v) or nil
        local fu = fui ~= nil and v.spec_fillUnit.fillUnits[fui] or nil
        if fu ~= nil then
            if on and not fu.supportedFillTypes[FillType.WATER] then
                fu.supportedFillTypes[FillType.WATER] = true
                fu.spsChemAddedWater = true
            elseif not on and fu.spsChemAddedWater and v:getFillUnitFillType(fui) ~= FillType.WATER then
                fu.supportedFillTypes[FillType.WATER] = nil
                fu.spsChemAddedWater = nil
            end
        end
    end
end

local function isSprayable(fillType)
    if fillType == nil or fillType == FillType.UNKNOWN or fillType == FillType.WATER then return false end
    return g_sprayTypeManager ~= nil and g_sprayTypeManager:getSprayTypeByFillTypeIndex(fillType) ~= nil
end

-- what this vehicle books: a sprayer books any sprayable product (S&F custom types included), any other tank only
-- the chemicals that have a concentrate (LF / HERB)
local function booksType(vehicle, fillType)
    if vehicle.spec_sprayer ~= nil then return isSprayable(fillType) end
    return SPSChemMix.isChemBase(fillType)
end

-- Books for a vehicle (made on first use: from the save if there is one, else from what the tank holds now,
-- read as ready mix).
-- Keep the books in step with the tank (server). Anything that changed the tank without going through
-- addFillUnitFillLevel (savegame restore before the books existed, another mod setting the level) is read as ready mix;
-- a level change of the same chemical keeps the ratio. [part 3] a tank of PURE concentrate has no books.
local function reconcile(vehicle, st, fui)
    fui = fui or SPSChemMix.getChemFillUnit(vehicle)
    if fui == nil or st == nil then return end
    local level = vehicle:getFillUnitFillLevel(fui) or 0
    local held  = vehicle:getFillUnitFillType(fui)
    local isSprayer = vehicle.spec_sprayer ~= nil
    if level <= 0.001 then
        if st.type ~= nil then
            if isSprayer then st.dirtyWith, st.residue, st.rinsesDone = st.type, 1, 0 end
        elseif st.washing and SPSChemWashout ~= nil and isSprayer then
            SPSChemWashout.onWaterEmptied(vehicle, st, st.washMaxL or st.waterL)
        end
        st.type, st.chemL, st.waterL, st.washing, st.mixL, st.washMaxL = nil, 0, 0, false, 0, 0
    elseif SPSChemMix.isConcentrate(held) then
        st.type, st.chemL, st.waterL, st.washing, st.mixL = nil, 0, 0, false, 0
    elseif held == FillType.WATER then
        if not st.washing or st.type ~= nil then st.type, st.chemL, st.washing, st.mixL = nil, 0, isSprayer, 0 end
        st.waterL = level
    elseif st.type ~= held then
        if booksType(vehicle, held) then
            local n = SPSChemMix.waterParts()
            st.type, st.washing = held, false
            st.chemL, st.waterL, st.mixL = level / (n + 1), level * n / (n + 1), level
        else
            st.type, st.chemL, st.waterL, st.washing, st.mixL = nil, 0, 0, false, 0
        end
    else
        local total = (st.chemL or 0) + (st.waterL or 0)
        if math.abs(total - level) > 0.5 then
            if total > 0.001 then
                st.chemL, st.waterL = st.chemL * level / total, st.waterL * level / total
                st.mixL = (st.mixL or 0) * level / total
            else
                local n = SPSChemMix.waterParts()
                st.chemL, st.waterL, st.mixL = level / (n + 1), level * n / (n + 1), level
            end
        end
    end
end

-- fresh books for one unit: from the save (pending by uniqueId, "#fui" appended for a unit other than the chem tank),
-- else from what the unit holds now (read as ready mix)
local function newState(vehicle, fui, isPrimary)
    local st = { type = nil, chemL = 0, waterL = 0, mixL = 0, washing = false, dirtyWith = nil }
    local uid = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil
    local key = (uid ~= nil and not isPrimary) and (uid .. "#" .. tostring(fui)) or uid
    local p = key ~= nil and SPSChemMix.pending[key] or nil
    if p ~= nil then
        for k, v in pairs(p) do st[k] = v end
        SPSChemMix.pending[key] = nil
        st._fromSave = true
        clog("restored books on %s unit %d: %s chem %.1f water %.1f washing=%s dirty=%s", tostring(vehicle.configFileName), fui,
            ftName(st.type), st.chemL, st.waterL, tostring(st.washing), ftName(st.dirtyWith))
    else
        local level = vehicle:getFillUnitFillLevel(fui) or 0
        local held  = vehicle:getFillUnitFillType(fui)
        if level > 0.001 then
            if held == FillType.WATER then
                st.washing, st.waterL = vehicle.spec_sprayer ~= nil, level
            elseif not SPSChemMix.isConcentrate(held) and booksType(vehicle, held) then
                local n = SPSChemMix.waterParts()
                st.type, st.chemL, st.waterL, st.mixL = held, level / (n + 1), level * n / (n + 1), level
            end
        end
    end
    return st
end

-- the books of a unit: fui nil = the vehicle's chem tank (vehicle.spsChemMix, as always); another chem-capable unit of
-- a tanker = vehicle.spsChemMixByFui[fui] ([SPS MKS8 2026-11-11]); nil when the unit books nothing
function SPSChemMix.getState(vehicle, fui)
    if vehicle == nil then return nil end
    local cf = SPSChemMix.getChemFillUnit(vehicle)
    if cf == nil then return nil end
    local synced = vehicle.isServer and (vehicle.getIsSynchronized == nil or vehicle:getIsSynchronized())
    if fui ~= nil and fui ~= cf then
        if not SPSChemMix.isChemFillUnit(vehicle, fui) then return nil end
        local all = vehicle.spsChemMixByFui
        if all == nil then all = {}; vehicle.spsChemMixByFui = all end
        if all[fui] == nil then all[fui] = newState(vehicle, fui, false) end
        if synced then reconcile(vehicle, all[fui], fui) end
        return all[fui]
    end
    if vehicle.spsChemMix == nil then vehicle.spsChemMix = newState(vehicle, cf, true) end
    if synced then reconcile(vehicle, vehicle.spsChemMix, cf) end
    return vehicle.spsChemMix
end

-- strength (1.0 = on ratio), nil when no chemical in
function SPSChemMix.getStrength(st)
    if st == nil or st.type == nil then return nil end
    local total = (st.chemL or 0) + (st.waterL or 0)
    if total <= 0.001 then return nil end
    return (st.chemL / total) * (SPSChemMix.waterParts() + 1)
end

function SPSChemMix.getBand(strength)
    if strength == nil then return nil end
    local band = SPSChemMix.BANDS[1]
    for _, b in ipairs(SPSChemMix.BANDS) do
        if strength >= b[1] then band = b end
    end
    return band
end

-- [part 2 / 3] strength of what a vehicle's unit holds: pure concentrate = N + 1, booked mix = its books, anything
-- untracked = 1.0 (ready mix). Second return: the books (sprayer contamination lives there).
function SPSChemMix.getVehicleStrength(vehicle, fui)
    local cf = SPSChemMix.getChemFillUnit(vehicle)
    fui = fui or cf
    if cf == nil or not SPSChemMix.isChemFillUnit(vehicle, fui) then return 1, nil end
    local held = vehicle:getFillUnitFillType(fui)
    if SPSChemMix.isConcentrate(held) and (vehicle:getFillUnitFillLevel(fui) or 0) > 0.001 then
        return SPSChemMix.waterParts() + 1, nil
    end
    local st = SPSChemMix.getState(vehicle, fui)
    return SPSChemMix.getStrength(st) or 1, st
end

local function markDirty(vehicle)
    if g_server ~= nil and vehicle ~= nil then SPSChemMix.dirty[vehicle] = true end
end

-- ---------------------------------------------------------------------------
-- [part 3] Transfer context: the sender's share rides along while the receiver's add runs
-- ---------------------------------------------------------------------------
-- concentrate litres per litre in a vehicle's unit (nil = untracked, read as ready mix)
function SPSChemMix.shareOfVehicle(vehicle, fui, fillType)
    if not SPSChemMix.isChemFillUnit(vehicle, fui) then return nil end
    local held = vehicle:getFillUnitFillType(fui)
    if SPSChemMix.isConcentrate(held) then return 1 end
    local st = SPSChemMix.getState(vehicle, fui)
    if st == nil or st.type == nil or (fillType ~= nil and fillType ~= st.type and SPSChemMix.concToBase[fillType] ~= st.type) then return nil end
    local total = (st.chemL or 0) + (st.waterL or 0)
    if total <= 0.001 then return nil end
    return st.chemL / total
end

-- rinse water with residue in a washing sprayer's unit: { type, share } (nil = clean water)
function SPSChemMix.rinseWaterOf(vehicle, fui)
    if vehicle.spec_sprayer == nil then return nil end
    local cf = SPSChemMix.getChemFillUnit(vehicle)
    if cf == nil or fui ~= cf then return nil end
    local st = SPSChemMix.getState(vehicle)
    if st == nil or not st.washing or st.dirtyWith == nil then return nil end
    local r = SPSChemWashout ~= nil and SPSChemWashout.residueNow ~= nil and SPSChemWashout.residueNow(vehicle, st) or 0
    if r <= 0.0005 then return nil end
    return { type = st.dirtyWith, share = math.min(1, r / (SPSChemMix.waterParts() + 1)) }
end

function SPSChemMix.ctxOfVehicle(vehicle, fui, fillType)
    if not SPSChemMix.isOn() or vehicle == nil or fui == nil then return nil end
    if fillType == FillType.WATER then
        local w = SPSChemMix.rinseWaterOf(vehicle, fui)
        return w ~= nil and { waterChem = w } or nil
    end
    local share = SPSChemMix.shareOfVehicle(vehicle, fui, fillType)
    return share ~= nil and { share = share } or nil
end

-- an SPS source / destination entry (vehicle + fillUnitIndex, or a storage)
function SPSChemMix.ctxOfEntry(entry, fillType)
    if not SPSChemMix.isOn() or entry == nil then return nil end
    if entry.vehicle ~= nil and entry.fillUnitIndex ~= nil then
        return SPSChemMix.ctxOfVehicle(entry.vehicle, entry.fillUnitIndex, fillType)
    elseif entry.storage ~= nil then
        local share = SPSChemMix.shareOfStorage(entry.storage, fillType)
        return share ~= nil and { share = share } or nil
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- [part 3] Storage books (silos, production points): storage.spsChemBooks[fillType] = { chemL, waterL }
-- ---------------------------------------------------------------------------
local function forEachStorage(cb)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, pl in ipairs(ps ~= nil and ps.placeables or {}) do
        local uid = pl.getUniqueId ~= nil and pl:getUniqueId() or nil
        if uid ~= nil then
            local silo = pl.spec_silo
            if silo ~= nil and silo.storages ~= nil then
                for i, s in ipairs(silo.storages) do cb(s, uid .. "#silo" .. i) end
            end
            local pp = pl.spec_productionPoint ~= nil and pl.spec_productionPoint.productionPoint or nil
            if pp ~= nil and pp.storage ~= nil then cb(pp.storage, uid .. "#prod") end
        end
    end
end

-- the save key of a storage (placeable uniqueId + which storage), nil for one no placeable owns
function SPSChemMix.storageKey(storage)
    local map = SPSChemMix._storageKeys
    if map == nil or map[storage] == nil then
        map = setmetatable({}, { __mode = "k" })
        forEachStorage(function(s, key) map[s] = key end)
        SPSChemMix._storageKeys = map
    end
    return map[storage]
end

function SPSChemMix.getStorageBooks(storage, fillType, create)
    if storage == nil or fillType == nil then return nil end
    local all = storage.spsChemBooks
    if all == nil then
        all = {}
        storage.spsChemBooks = all
        if next(SPSChemMix.pendingStorage) ~= nil then
            local key = SPSChemMix.storageKey(storage)
            local p = key ~= nil and SPSChemMix.pendingStorage[key] or nil
            if p ~= nil then
                for ft, b in pairs(p) do all[ft] = b end
                SPSChemMix.pendingStorage[key] = nil
                clog("restored silo books %s", tostring(key))
            end
        end
    end
    local b = all[fillType]
    if b == nil and create then
        b = { chemL = 0, waterL = 0 }
        all[fillType] = b
    end
    return b
end

-- concentrate litres per litre of a fill type in a storage (nil = untracked, read as ready mix); books that drifted
-- from the level (toggle was off for a while) are scaled to it first
function SPSChemMix.shareOfStorage(storage, fillType)
    if not SPSChemMix.isChemBase(fillType) then return nil end
    local b = SPSChemMix.getStorageBooks(storage, fillType, false)
    if b == nil then return nil end
    local total = (b.chemL or 0) + (b.waterL or 0)
    if total <= 0.001 then return nil end
    local level = storage.getFillLevel ~= nil and (storage:getFillLevel(fillType) or 0) or total
    if math.abs(level - total) > 0.5 then
        local k = level / total
        b.chemL, b.waterL = b.chemL * k, b.waterL * k
        total = level
        if total <= 0.001 then return nil end
    end
    return b.chemL / total
end

-- Storage:setFillLevel (absolute level): book the delta. In = the context's share, else ready mix; out = in proportion.
function SPSChemMix.storageSetFillLevel(storage, superFunc, fillLevel, fillType, fillInfo)
    local old = storage.fillLevels ~= nil and storage.fillLevels[fillType] or nil
    superFunc(storage, fillLevel, fillType, fillInfo)
    if old == nil or g_server == nil or not SPSChemMix.isOn() or not SPSChemMix.isChemBase(fillType) then return end
    local new = storage.fillLevels[fillType] or 0
    local delta = new - old
    if math.abs(delta) < 0.0001 then return end
    local b = SPSChemMix.getStorageBooks(storage, fillType, true)
    if new <= 0.001 then
        b.chemL, b.waterL = 0, 0
        return
    end
    local n = SPSChemMix.waterParts()
    if delta > 0 then
        local total = (b.chemL or 0) + (b.waterL or 0)
        if total <= 0.001 and old > 0.001 then
            -- untracked contents already in the silo: ready mix
            b.chemL, b.waterL = old / (n + 1), old * n / (n + 1)
        end
        local share = (SPSChemMix.ctx ~= nil and SPSChemMix.ctx.share) or 1 / (n + 1)
        b.chemL  = b.chemL  + delta * share
        b.waterL = b.waterL + delta * (1 - share)
        clog("silo %s +%.1f l (share %.3f) -> chem %.1f water %.1f", ftName(fillType), delta, share, b.chemL, b.waterL)
    else
        local total = (b.chemL or 0) + (b.waterL or 0)
        if total > 0.001 then
            local k = new / total
            b.chemL, b.waterL = b.chemL * k, b.waterL * k
        else
            b.chemL, b.waterL = new / (n + 1), new * n / (n + 1)
        end
    end
end

-- LoadingStation:addFillLevelToFillableObject (silo -> vehicle at a fill trigger): the silo's share goes along
function SPSChemMix.loadingStationFill(station, superFunc, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
    if not SPSChemMix.isOn() or not SPSChemMix.isChemBase(fillTypeIndex) or station.sourceStorages == nil then
        return superFunc(station, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
    end
    local share = nil
    for _, s in pairs(station.sourceStorages) do
        if s.getFillLevel ~= nil and (s:getFillLevel(fillTypeIndex) or 0) > 0.001 then
            share = SPSChemMix.shareOfStorage(s, fillTypeIndex)
            break
        end
    end
    local prev = SPSChemMix.ctx
    SPSChemMix.ctx = share ~= nil and { share = share } or nil
    local r = superFunc(station, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
    SPSChemMix.ctx = prev
    return r
end

-- Dischargeable:dischargeToObject (tipping / pumping into a trailer, an unload trigger -> silo): the sender's
-- share (or its rinse water's residue) goes along
function SPSChemMix.dischargeToObject(self, superFunc, dischargeNode, emptyLiters, object, targetFillUnitIndex)
    if not SPSChemMix.isOn() or dischargeNode == nil or dischargeNode.fillUnitIndex == nil then
        return superFunc(self, dischargeNode, emptyLiters, object, targetFillUnitIndex)
    end
    local prev = SPSChemMix.ctx
    SPSChemMix.ctx = SPSChemMix.ctxOfVehicle(self, dischargeNode.fillUnitIndex, self:getFillUnitFillType(dischargeNode.fillUnitIndex))
    local r = superFunc(self, dischargeNode, emptyLiters, object, targetFillUnitIndex)
    SPSChemMix.ctx = prev
    return r
end

-- ---------------------------------------------------------------------------
-- Fill unit overrides (every FillUnit type)
-- ---------------------------------------------------------------------------
function SPSChemMix.getFillUnitAllowsFillType(self, superFunc, fillUnitIndex, fillType)
    local base = SPSChemMix.concToBase[fillType]
    if not SPSChemMix.isOn() or not SPSChemMix.isChemFillUnit(self, fillUnitIndex) then
        if base ~= nil then return superFunc(self, fillUnitIndex, base) end   -- off: concentrate = the normal product
        return superFunc(self, fillUnitIndex, fillType)
    end
    local fu    = self.spec_fillUnit.fillUnits[fillUnitIndex]
    if fu == nil or not fu.supportedFillTypes[fillType] then return false end
    local held  = self:getFillUnitFillType(fillUnitIndex)
    local level = self:getFillUnitFillLevel(fillUnitIndex) or 0
    if level <= 0.001 or held == FillType.UNKNOWN then return true end
    -- water dilutes whatever chemical is in or tops up a washout; a chemical into washout water makes the mix
    if fillType == FillType.WATER or held == FillType.WATER then return true end
    if held == (base or fillType) then return true end
    -- [part 3] a tank of pure concentrate takes its own mix (becomes a booked mix) and more of its concentrate
    local heldBase = SPSChemMix.concToBase[held]
    if heldBase ~= nil and heldBase == (base or fillType) then return true end
    return superFunc(self, fillUnitIndex, base or fillType)
end

function SPSChemMix.addFillUnitFillLevel(self, superFunc, farmId, fillUnitIndex, delta, fillType, toolType, fillPositionData)
    local base = SPSChemMix.concToBase[fillType]
    local fui  = SPSChemMix.getChemFillUnit(self)
    -- clients (stream sync) and loading (savegame restore): the type arriving is the type stored - never remapped
    if not self.isServer or (self.getIsSynchronized ~= nil and not self:getIsSynchronized()) then
        return superFunc(self, farmId, fillUnitIndex, delta, fillType, toolType, fillPositionData)
    end
    -- other fill units / toggle off: straight through, concentrate as the normal product - unless the unit takes
    -- the concentrate itself (a second chem unit on a tank, toggle on): then it keeps it
    if not SPSChemMix.isOn() or not SPSChemMix.isChemFillUnit(self, fillUnitIndex) then   -- [SPS MKS8 2026-11-11] any booked unit
        if base ~= nil and SPSChemMix.isOn() and self.spec_fillUnit ~= nil then
            local fu = self.spec_fillUnit.fillUnits[fillUnitIndex]
            if fu ~= nil and fu.supportedFillTypes ~= nil and fu.supportedFillTypes[fillType] then
                return superFunc(self, farmId, fillUnitIndex, delta, fillType, toolType, fillPositionData)
            end
        end
        return superFunc(self, farmId, fillUnitIndex, delta, base or fillType, toolType, fillPositionData)
    end
    return SPSChemMix.addFillLevel(self, superFunc, farmId, fillUnitIndex, delta, fillType, toolType, fillPositionData)
end

-- a chemical going in (concentrate, ready mix or a booked mix with a known share): the books
local function addChemical(vehicle, superFunc, farmId, fui, delta, want, fillType, toolType, fillPositionData, st, level, held, share, isConc, isSprayer)
    local contamType, contamLevel = nil, 0
    if isSprayer and st.dirtyWith ~= nil and st.dirtyWith ~= want then
        -- [SPS CHEM 2026-11-06] not washed out: allowed, the residue goes into the new mix (crop damage, part 2)
        contamType = st.dirtyWith
        contamLevel = SPSChemWashout ~= nil and SPSChemWashout.residueNow(vehicle, st) or 1
    end
    local function takeOver()
        if st.dirtyWith ~= nil or st.washing then
            if contamType ~= nil then
                st.contamType, st.contamLevel = contamType, contamLevel
                if SPSChemWashout ~= nil and SPSChemWashout.warnContam ~= nil then SPSChemWashout.warnContam(contamType) end
                clog("%s into a tank dirty with %s: residue %.3f recorded", ftName(want), ftName(contamType), contamLevel)
            end
            if isSprayer and SPSChemWashout ~= nil then SPSChemWashout.stop(vehicle, "chemical added") end
            st.residue, st.rinsesDone, st.poorRinse, st.phase, st.washMaxL = 0, 0, false, 0, 0
        end
    end

    -- chemical into washout / plain water: the water becomes the mix
    if held == FillType.WATER and level > 0.001 then
        takeOver()
        superFunc(vehicle, farmId, fui, -level, FillType.WATER, ToolType.UNDEFINED, nil)
        local total = superFunc(vehicle, farmId, fui, level + delta, want, toolType, fillPositionData) or 0
        local added = math.max(0, total - level)
        st.type, st.washing, st.dirtyWith = want, false, nil
        st.waterL = math.min(level, total) + added * (1 - share)
        st.chemL  = added * share
        st.mixL   = (not isConc) and added or 0
        markDirty(vehicle)
        clog("%s %.1f l into %.1f l of water -> mix (chem %.1f / water %.1f)", ftName(fillType), added, level, st.chemL, st.waterL)
        return added
    end

    local applied = superFunc(vehicle, farmId, fui, delta, want, toolType, fillPositionData) or 0
    if applied > 0 then
        takeOver()
        st.type, st.dirtyWith, st.washing = want, nil, false
        st.chemL  = st.chemL  + applied * share
        st.waterL = st.waterL + applied * (1 - share)
        if not isConc then st.mixL = (st.mixL or 0) + applied end
        markDirty(vehicle)
        clog("%s %.1f l (%s, share %.3f) -> chem %.1f / water %.1f, strength %.0f%%", ftName(fillType), applied,
            isConc and "concentrate" or "mix", share, st.chemL, st.waterL, (SPSChemMix.getStrength(st) or 0) * 100)
    end
    return applied
end

-- The fill rule (server). Concentrate comes in as its base type (sprayers) or stays pure (any other empty tank);
-- ready mix and water are booked by ratio; a transfer context overrides the share.
function SPSChemMix.addFillLevel(vehicle, superFunc, farmId, fui, delta, fillType, toolType, fillPositionData)
    local isSprayer = vehicle.spec_sprayer ~= nil
    local st    = SPSChemMix.getState(vehicle, fui)
    local level = vehicle:getFillUnitFillLevel(fui) or 0
    local held  = vehicle:getFillUnitFillType(fui)
    local n     = SPSChemMix.waterParts()
    local ctx   = SPSChemMix.ctx
    local conc  = SPSChemMix.concToBase[fillType]
    local heldConc = level > 0.001 and SPSChemMix.isConcentrate(held)   -- [part 3] a tank of pure concentrate

    -- OUT (spraying, discharging, pumped away): let it happen, then scale the books and detect "empty"
    if delta <= 0 then
        if heldConc then return superFunc(vehicle, farmId, fui, delta, fillType, toolType, fillPositionData) end
        local strengthBefore = SPSChemMix.getStrength(st)
        local applied = superFunc(vehicle, farmId, fui, delta, conc or fillType, toolType, fillPositionData)
        if level > 0 and applied ~= nil and applied < 0 then
            local frac = math.max(0, (level + applied) / level)
            st.chemL  = st.chemL  * frac
            st.waterL = st.waterL * frac
            st.mixL   = (st.mixL or 0) * frac
        end
        if (vehicle:getFillUnitFillLevel(fui) or 0) <= 0.001 then
            if st.type ~= nil and isSprayer then
                -- [SPS CHEM 2026-11-06] washout: the sump keeps a little of the mix at the strength the tank had
                st.dirtyWith, st.residue, st.rinsesDone, st.poorRinse = st.type, math.max(0.05, strengthBefore or 1), 0, false
                st.contamType, st.contamLevel = nil, 0
                clog("tank empty: %s used up, tank now dirty with it (residue %.2f)", ftName(st.type), st.residue)
            elseif st.washing and isSprayer and SPSChemWashout ~= nil then
                SPSChemWashout.onWaterEmptied(vehicle, st, st.washMaxL or st.waterL)
            end
            st.type, st.chemL, st.waterL, st.washing, st.mixL, st.washMaxL = nil, 0, 0, false, 0, 0
            markDirty(vehicle)
        end
        return applied
    end

    -- IN: water
    if fillType == FillType.WATER then
        -- [part 3] rinse water carrying residue (from a washing sprayer by pipe / discharge): a thin mix of that
        -- chemical for a tank that takes it
        local wc = ctx ~= nil and ctx.waterChem or nil
        if wc ~= nil and wc.type ~= nil and booksType(vehicle, wc.type) and vehicle:getFillUnitSupportsFillType(fui, wc.type)
        and (st.type == nil or st.type == wc.type) and not heldConc then
            return addChemical(vehicle, superFunc, farmId, fui, delta, wc.type, wc.type, toolType, fillPositionData, st, level, held, wc.share or 0, false, isSprayer)
        end
        if heldConc then
            -- [part 3] water into a tank of pure concentrate (IBC / bowser): it becomes the booked mix
            local hb = SPSChemMix.concToBase[held]
            superFunc(vehicle, farmId, fui, -level, held, ToolType.UNDEFINED, nil)
            local total = superFunc(vehicle, farmId, fui, level + delta, hb, toolType, fillPositionData) or 0
            local added = math.max(0, total - level)
            st.type, st.washing, st.dirtyWith, st.mixL = hb, false, nil, 0
            st.chemL, st.waterL = math.min(level, total), added
            markDirty(vehicle)
            clog("water %.1f l into %.1f l of %s -> mix (chem %.1f / water %.1f)", added, level, ftName(held), st.chemL, st.waterL)
            return added
        end
        if st.type ~= nil and level > 0.001 and held ~= FillType.WATER then
            -- dilute: the vanilla unit holds one type, so water is booked as the chemical
            local applied = superFunc(vehicle, farmId, fui, delta, held, toolType, fillPositionData) or 0
            st.waterL = st.waterL + applied
            if applied > 0 then
                markDirty(vehicle)
                clog("water %.1f l into %s (chem %.1f / water %.1f)", applied, ftName(held), st.chemL, st.waterL)
            end
            return applied
        end
        local applied = superFunc(vehicle, farmId, fui, delta, FillType.WATER, toolType, fillPositionData) or 0
        if applied > 0 and isSprayer then
            if not st.washing then clog("washout / plain water started (dirty with %s)", ftName(st.dirtyWith)) end
            st.washing = true
            st.waterL = st.waterL + applied
            st.washMaxL = math.max(st.washMaxL or 0, vehicle:getFillUnitFillLevel(fui) or 0)
            markDirty(vehicle)
        end
        return applied
    end

    -- IN: chemical (concentrate or mix)
    local want = conc or fillType
    if not booksType(vehicle, want) then
        return superFunc(vehicle, farmId, fui, delta, fillType, toolType, fillPositionData)
    end
    if conc ~= nil and not isSprayer and (level <= 0.001 or heldConc) then
        -- [part 3] concentrate into an empty tank / onto pure concentrate (IBC, bowser): it stays pure
        return superFunc(vehicle, farmId, fui, delta, fillType, toolType, fillPositionData)
    end
    if conc ~= nil and isSprayer and SPSChemStation ~= nil and SPSChemStation.checkConcentratePour ~= nil
    and not SPSChemStation.checkConcentratePour(vehicle, toolType) then
        return 0
    end
    if st.type ~= nil and st.type ~= want then
        if isSprayer then warn("warning_spsChemWashout", "Wash out first: the tank holds " .. ftName(st.type)) end
        return 0
    end
    local share = conc ~= nil and 1 or ((ctx ~= nil and ctx.share) or 1 / (n + 1))   -- concentrate litres per litre coming in
    if heldConc then
        -- [part 3] mix into a tank of pure concentrate: the concentrate becomes booked, then the mix is added
        local hb = SPSChemMix.concToBase[held]
        if hb ~= want then return 0 end
        superFunc(vehicle, farmId, fui, -level, held, ToolType.UNDEFINED, nil)
        local total = superFunc(vehicle, farmId, fui, level + delta, want, toolType, fillPositionData) or 0
        local added = math.max(0, total - level)
        st.type, st.washing, st.dirtyWith = want, false, nil
        st.chemL  = math.min(level, total) + added * share
        st.waterL = added * (1 - share)
        st.mixL   = added
        markDirty(vehicle)
        clog("%s %.1f l (share %.3f) onto %.1f l of pure concentrate -> chem %.1f / water %.1f", ftName(fillType), added, share, level, st.chemL, st.waterL)
        return added
    end
    return addChemical(vehicle, superFunc, farmId, fui, delta, want, fillType, toolType, fillPositionData, st, level, held, share, conc ~= nil, isSprayer)
end

-- ---------------------------------------------------------------------------
-- Sprayer overrides
-- ---------------------------------------------------------------------------
-- WATER has no spray type (litersPerSecond would be 1 = 120x a chemical): a washout sprays at the herbicide rate
function SPSChemMix.getSprayerUsage(self, superFunc, fillType, dt)
    if fillType == FillType.WATER and SPSChemMix.isOn() and SPSChemMix.getChemFillUnit(self) ~= nil then
        return superFunc(self, FillType.HERBICIDE, dt)
    end
    return superFunc(self, fillType, dt)
end

-- [part 2] the double band plays the vanilla "doubled amount" (fertiliser +2 levels) for the pass
function SPSChemMix.getSprayerDoubledAmountActive(self, superFunc, sprayTypeIndex)
    if self._spsChemDouble == true then return true, true end
    return superFunc(self, sprayTypeIndex)
end

-- throttled on-screen warning for the player driving this sprayer (client side of the machine)
local function fieldWarn(vehicle, key, fallback, arg)
    if vehicle.isClient ~= true then return end
    local root = vehicle.rootVehicle or vehicle
    if root.getIsActiveForInput == nil or not root:getIsActiveForInput(true) then return end
    local now = g_time or 0
    if vehicle._spsChemWarnT ~= nil and now - vehicle._spsChemWarnT < SPSChemMix.WARN_MS then return end
    vehicle._spsChemWarnT = now
    local txt = i18n(key, fallback)
    if arg ~= nil then txt = string.format(txt, arg) end
    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(txt, 2500)
    end
end

-- strip the patch's fertiliser: spray level to 0 on the field, spray type reset
local function stripFertilizer(sx, sz, wx, wz, hx, hz)
    local fd = SPSChemMix._stripData
    if fd == nil then
        local fgs = g_currentMission.fieldGroundSystem
        local lvlId, lvlFirst, lvlNum = fgs:getDensityMapData(FieldDensityMap.SPRAY_LEVEL)
        local gtId, gtFirst, gtNum = fgs:getDensityMapData(FieldDensityMap.GROUND_TYPE)
        fd = { modifier = DensityMapModifier.new(lvlId, lvlFirst, lvlNum, g_terrainNode),
               fieldFilter = DensityMapFilter.new(gtId, gtFirst, gtNum) }
        fd.fieldFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
        SPSChemMix._stripData = fd
    end
    fd.modifier:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
    fd.modifier:executeSet(0, fd.fieldFilter)
    FSDensityMapUtil.resetSprayArea(sx, sz, wx, wz, hx, hz, true)
end

local function flattenCrop(sx, sz, wx, wz, hx, hz)
    FSDensityMapUtil.updateWheelDestructionArea(sx, sz, wx, wz, hx, hz)
    stripFertilizer(sx, sz, wx, wz, hx, hz)
end

-- Soil & Fertilizer present and able to take our calls?
local function soilSys()
    local m = g_SoilFertilityManager
    return m ~= nil and m.soilSystem or nil
end

-- the strength feeding the boom this pass (the tank vehicle's books) + the sprayer books (contamination)
function SPSChemMix.passStrength(sprayer)
    local wap = sprayer.spec_sprayer.workAreaParameters
    local sv, sfui = wap.sprayVehicle, wap.sprayVehicleFillUnitIndex
    if sv == nil then return 1, nil end
    return SPSChemMix.getVehicleStrength(sv, sfui)
end

-- [part 2] the field effect
function SPSChemMix.processSprayerArea(self, superFunc, workArea, dt)
    local spec = self.spec_sprayer
    local wap  = spec ~= nil and spec.workAreaParameters or nil
    if wap == nil or not SPSChemMix.isOn() or SPSChemMix.getChemFillUnit(self) == nil then
        return superFunc(self, workArea, dt)
    end
    -- WATER writes nothing to the field but still counts as working, so the litres are used
    if wap.sprayFillType == FillType.WATER then
        if (wap.sprayFillLevel or 0) <= 0 then return 0, 0 end
        wap.isActive = true
        wap.lastSprayTime = g_time
        if 1 < self:getLastSpeed() then spec.isWorking = true end
        return 0, 0
    end
    if (wap.sprayFillLevel or 0) <= 0 or not isSprayable(wap.sprayFillType) then
        return superFunc(self, workArea, dt)
    end
    local strength, st = SPSChemMix.passStrength(self)
    local desc  = g_sprayTypeManager:getSprayTypeByIndex(wap.sprayType)
    local isFert = desc ~= nil and desc.isFertilizer == true
    local pf = self.getCurrentNitrogenLevelOffset ~= nil and g_precisionFarming ~= nil   -- PF drives N and the damage
    local sf = soilSys() ~= nil                                                          -- S&F books and burns
    -- not washed out: a herbicide residue in the mix damages the crop
    local contamKill, contamScorch = false, false
    if st ~= nil and st.contamType ~= nil and (st.contamLevel or 0) > 0 then
        local cd = g_sprayTypeManager:getSprayTypeByFillTypeIndex(st.contamType)
        if cd ~= nil and cd.isHerbicide and st.contamType ~= wap.sprayFillType then
            contamKill   = st.contamLevel >= SPSChemMix.CONTAM_KILL
            contamScorch = st.contamLevel >= SPSChemMix.CONTAM_SCORCH
        end
    end

    local function markWorking()
        wap.isActive = true
        wap.lastSprayTime = g_time
        if 1 < self:getLastSpeed() then spec.isWorking = true end
    end
    local clientFar = not self.isServer and Sprayer.CLIENT_DM_UPDATE_RADIUS < self.currentUpdateDistance

    -- too weak: nothing written, the litres are used, the player is told
    if strength < SPSChemMix.WEAK_BELOW then
        markWorking()
        fieldWarn(self, "warning_spsChemWeak", "Mix too weak - nothing applied, add concentrate or make another pass")
        return 0, 0
    end

    local changed, total = 0, 0
    local sx, sz, wx, wz, hx, hz
    local function coords()
        if sx == nil then
            local _
            sx, _, sz = getWorldTranslation(workArea.start)
            wx, _, wz = getWorldTranslation(workArea.width)
            hx, _, hz = getWorldTranslation(workArea.height)
        end
    end
    local spsBurn = not pf and not sf
    if spsBurn and strength >= SPSChemMix.FLATTEN_FROM then
        markWorking()
        if not clientFar then coords(); flattenCrop(sx, sz, wx, wz, hx, hz) end
        fieldWarn(self, "warning_spsChemKill", "Mix far too strong - the crop is being destroyed")
        return 0, 0
    elseif spsBurn and strength >= SPSChemMix.SCORCH_FROM then
        markWorking()
        if not clientFar then coords(); stripFertilizer(sx, sz, wx, wz, hx, hz) end
        fieldWarn(self, "warning_spsChemScorch", "Mix far too strong - the crop is scorched")
        return 0, 0
    elseif not pf and isFert and strength >= SPSChemMix.DOUBLE_FROM then
        self._spsChemDouble = true
        changed, total = superFunc(self, workArea, dt)
        self._spsChemDouble = nil
    else
        changed, total = superFunc(self, workArea, dt)
    end

    -- the residue's damage comes on top of the pass
    if (contamKill or contamScorch) and not clientFar and wap.isActive then
        coords()
        if contamKill then flattenCrop(sx, sz, wx, wz, hx, hz) else stripFertilizer(sx, sz, wx, wz, hx, hz) end
        fieldWarn(self, "warning_spsChemContamDamage", "%s residue in the mix is damaging the crop - wash out", ftTitle(st.contamType))
    end

    -- Soil & Fertilizer: its burn fed the strength (its own thresholds decide)
    if sf and self.isServer and wap.isActive and isFert then
        local sys = soilSys()
        local burnFrom = (SoilConstants ~= nil and SoilConstants.SPRAYER_RATE ~= nil and SoilConstants.SPRAYER_RATE.BURN_RISK_THRESHOLD) or SPSChemMix.SF_BURN_FROM
        if strength > burnFrom and sys.applyBurnEffect ~= nil and sys.hookManager ~= nil and sys.hookManager.getFieldIdAtWorldPosition ~= nil then
            coords()
            local ok, fieldId = pcall(sys.hookManager.getFieldIdAtWorldPosition, sys.hookManager, sx, sz, true)
            if ok and fieldId ~= nil and fieldId > 0 then pcall(sys.applyBurnEffect, sys, fieldId, strength) end
        end
    end
    return changed, total
end

-- [part 2] Soil & Fertilizer books the litres of the pass from Sprayer.onEndWorkAreaProcessing (its appended hook):
-- the strength is published before the event and cleared after, and S&F's booking is scaled by it (lazy wrap below)
function SPSChemMix.onEndWorkAreaProcessingPre(self, dt, hasProcessed)
    SPSChemMix._sfStrength = nil
    if not SPSChemMix.isOn() or self.spec_sprayer == nil or SPSChemMix.getChemFillUnit(self) == nil then return end
    local wap = self.spec_sprayer.workAreaParameters
    if wap == nil or not wap.isActive or wap.sprayFillType == FillType.WATER then return end
    local s = SPSChemMix.passStrength(self)
    if s ~= 1 then SPSChemMix._sfStrength = s end
end

function SPSChemMix.onEndWorkAreaProcessingPost(self, dt, hasProcessed)
    SPSChemMix._sfStrength = nil
end

local function wrapSF(name)
    local orig = SoilFertilitySystem[name]
    if type(orig) ~= "function" then return end
    SoilFertilitySystem[name] = function(sys, fieldId, a, liters, ...)
        local s = SPSChemMix._sfStrength
        if s ~= nil and liters ~= nil then liters = liters * s end
        return orig(sys, fieldId, a, liters, ...)
    end
end

function SPSChemMix.installSFHooks()
    if SPSChemMix._sfHooked or SoilFertilitySystem == nil then return end
    SPSChemMix._sfHooked = true
    wrapSF("onFertilizerApplied")          -- (fieldId, fillTypeIndex, liters)
    wrapSF("onHerbicideAppliedDirect")     -- (fieldId, effectiveness, liters)
    print("[SPS] chem mix: Soil & Fertilizer found - booked litres scaled by the mix strength, SPS scorch off")
end

-- [part 2] Precision Farming asks the TANK vehicle for a nitrogen level offset per sub-section (lastChangeLevels =
-- the levels this pass would add): the strength scales it. Too weak never gets here (nothing written).
function SPSChemMix.getCurrentNitrogenLevelOffset(self, superFunc, lastChangeLevels)
    local base = superFunc(self, lastChangeLevels) or 0
    if not SPSChemMix.isOn() then return base end
    local s = SPSChemMix.getVehicleStrength(self, nil)
    if s == 1 or lastChangeLevels == nil then return base end
    return base + MathUtil.round(lastChangeLevels * (s - 1))
end

-- [part 3] the on-foot info box line for any tank with books (sprayers, trailers, IBCs, bowsers)
function SPSChemMix.getInfoLine(vehicle)
    if not SPSChemMix.isOn() then return nil end
    local cf = SPSChemMix.getChemFillUnit(vehicle)
    if cf == nil then return nil end
    local held = vehicle:getFillUnitFillType(cf)
    local level = vehicle:getFillUnitFillLevel(cf) or 0
    if level <= 0.001 then return nil end
    if SPSChemMix.isConcentrate(held) then
        return i18n("sps_chemInfoConc", "Concentrate"), ftTitle(SPSChemMix.concToBase[held])
    end
    local st = vehicle.spsChemMix
    if st == nil and vehicle.isServer then st = SPSChemMix.getState(vehicle) end
    local s = SPSChemMix.getStrength(st)
    if s == nil then return nil end
    local band = SPSChemMix.getBand(s)
    return i18n("sps_chemInfoMix", "Mix strength") .. " " .. ftTitle(st.type),
        string.format("%.0f%% %s", s * 100, i18n("sps_chemBand" .. (band and band[2] or "Good"), band and band[2] or ""))
end

-- ---------------------------------------------------------------------------
-- Prices: concentrate = base x (water parts + 1); shop chem pallets the same while the toggle is on
-- ---------------------------------------------------------------------------
local PALLET_FILLUNIT = SPSChemMix.PALLET_FILLUNIT_KEY

-- Shop items that spawn a pallet type full of a sprayer liquid. Read once (only when the toggle is first on).
-- [SPS CHEM 2026-11-08] the first fill unit of configuration 0 that STARTS with something; <parentFile> + <set> files
-- (mrh barrels, S&F tubs) are resolved by XMLFile.load itself (initInheritance), nothing to do here.
function SPSChemMix._readPalletXml(filename, key)
    SPSChemMix._mipTarget = nil
    local xml = filename ~= nil and XMLFile.loadIfExists("spsChemStoreScan", filename) or nil
    if xml == nil then return nil end
    local startFt, startLv
    local i = 0
    while i < 8 do
        local k = string.format("%s(%d)", key, i)
        if not xml:hasProperty(k) then break end
        local ft = xml:getString(k .. "#startFillType")
        if ft ~= nil then
            startFt, startLv = ft, xml:getFloat(k .. "#startFillLevel", 0)
            break
        end
        i = i + 1
    end
    local typeName = xml:getString("vehicle#type")
    SPSChemMix._mipTarget = xml:getString("vehicle.multipleItemPurchase#filename")
    xml:delete()
    return startFt, startLv, typeName
end

function SPSChemMix.scanStorePallets(force)
    if SPSChemMix._storePallets ~= nil and not force then return SPSChemMix._storePallets end
    SPSChemMix.resolveFillTypes()
    local list, report = {}, {}
    SPSChemMix._palletReport = report   -- [SPS CHEM 2026-11-08] every pallet that spawns with contents + its verdict
    if g_storeManager == nil or g_vehicleTypeManager == nil then return list end
    local t0 = getTimeSec ~= nil and getTimeSec() or 0
    local key = PALLET_FILLUNIT
    for _, item in ipairs(g_storeManager:getItems() or {}) do
        if item.species == StoreSpecies.VEHICLE and item.xmlFilename ~= nil and not item.isBundleItem
        and (item.price or 0) > 0 and (item.price or 0) < 100000 then
            local startFt, startLv, typeName = SPSChemMix._readPalletXml(item.xmlFilename, key)
            -- a multi-buy pack ("6 x IBC") is its own type with an empty fill unit; what it spawns is named in
            -- <multipleItemPurchase filename=...>, so read that pallet instead (its price list is in the pack's configs)
            local viaPack = nil
            if startFt == nil and SPSChemMix._mipTarget ~= nil then
                viaPack = Utils.getFilename(SPSChemMix._mipTarget, item.baseDir)
                startFt, startLv, typeName = SPSChemMix._readPalletXml(viaPack, key)
            end
            if startFt ~= nil then
                local base = g_fillTypeManager:getFillTypeIndexByName(startFt)
                local conc = base ~= nil and SPSChemMix.baseToConc[base] or nil
                local verdict
                if base == nil then
                    verdict = "skip: fill type '" .. tostring(startFt) .. "' unknown"
                elseif conc == nil then
                    verdict = "skip: " .. tostring(startFt) .. " is not a sprayer liquid (no concentrate twin)"
                elseif (startLv or 0) <= 0 then
                    verdict = "skip: starts empty"
                elseif typeName == nil then
                    verdict = "skip: no vehicle type"
                else
                    local typeEntry = g_vehicleTypeManager:getTypeByName(typeName, item.customEnvironment)
                    if typeEntry == nil and item.customEnvironment ~= nil then
                        typeEntry = g_vehicleTypeManager:getTypeByName(item.customEnvironment .. "." .. typeName)
                    end
                    if typeEntry == nil then
                        verdict = "skip: vehicle type '" .. tostring(typeName) .. "' not found"
                    elseif not SPSChemMix.isPalletType(typeEntry) then
                        verdict = "skip: type '" .. tostring(typeName) .. "' is not a pallet (Attachable / Motorized / Sprayer)"
                    else
                        local cfg = {}
                        for _, items in pairs(item.configurations or {}) do
                            for _, ci in ipairs(items) do
                                if ci.price ~= nil and ci.price ~= 0 then
                                    table.insert(cfg, { item = ci, price = ci.price })
                                end
                            end
                        end
                        table.insert(list, { item = item, price = item.price, name = item.name, cfg = cfg })
                        verdict = "REPRICED"
                    end
                end
                table.insert(report, { xml = item.xmlFilename, pack = viaPack, typeName = typeName, startFt = startFt,
                    level = startLv or 0, base = item.price or 0, verdict = verdict, shopName = item.name })
            end
        end
    end
    SPSChemMix._storePallets = list
    print(string.format("[SPS] chem mix: %d shop chemical pallet(s) found (%.0f ms)", #list,
        ((getTimeSec ~= nil and getTimeSec() or 0) - t0) * 1000))
    return list
end

function SPSChemMix.applyPrices()
    SPSChemMix.resolveFillTypes()
    local mult = SPSChemMix.waterParts() + 1
    for conc, base in pairs(SPSChemMix.concToBase) do
        local cd, bd = g_fillTypeManager:getFillTypeByIndex(conc), g_fillTypeManager:getFillTypeByIndex(base)
        if cd ~= nil and bd ~= nil then
            cd.pricePerLiter = (bd.pricePerLiter or 0) * mult
            if bd.startPricePerLiter ~= nil then cd.startPricePerLiter = bd.startPricePerLiter * mult end
        end
    end
    local on = SPSChemMix.isOn()
    if not on and SPSChemMix._storePallets == nil then return end   -- never scanned, nothing to restore
    local m = on and mult or 1
    local nameFmt = i18n("sps_chemStoreConcName", "%s (concentrate)")
    for _, p in ipairs(SPSChemMix.scanStorePallets()) do
        p.item.price = math.floor(p.price * m + 0.5)
        for _, c in ipairs(p.cfg) do c.item.price = math.floor(c.price * m + 0.5) end
        -- [SPS CHEM 2026-11-08] the shop name says what the price says (William: "add concentrate to its name")
        if p.name ~= nil then
            p.item.name = on and string.format(nameFmt, p.name) or p.name
        end
    end
    clog("prices: concentrate x%d, %d shop pallet(s) %s", mult, #(SPSChemMix._storePallets or {}), on and "repriced" or "at base price")
end

-- settings changed (toggle or ratio)
function SPSChemMix.applySetting()
    SPSChemMix.applyWaterSupportAll()
    SPSChemMix.applyPrices()
end

-- ---------------------------------------------------------------------------
-- Network: books server -> clients
-- ---------------------------------------------------------------------------
function SPSChemMix.update(dt)
    if SPSChemWashout ~= nil then SPSChemWashout.update(dt) end
    if not SPSChemMix._sfHooked and SoilFertilitySystem ~= nil then SPSChemMix.installSFHooks() end
    if g_server == nil or next(SPSChemMix.dirty) == nil then return end
    SPSChemMix._syncTimer = SPSChemMix._syncTimer + dt
    if SPSChemMix._syncTimer < SPSChemMix.SYNC_MS then return end
    SPSChemMix._syncTimer = 0
    local mp = g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer
    if mp then
        for v, _ in pairs(SPSChemMix.dirty) do
            if v.isDeleted ~= true then
                if v.spsChemMix ~= nil then g_server:broadcastEvent(SPSChemBooksEvent.new(v, v.spsChemMix, 0), nil, nil, v) end
                for fui, st in pairs(v.spsChemMixByFui or {}) do   -- [SPS MKS8 2026-11-11] the other tanks
                    g_server:broadcastEvent(SPSChemBooksEvent.new(v, st, fui), nil, nil, v)
                end
            end
        end
    end
    SPSChemMix.dirty = {}
end

-- join dump: every set of books to one freshly joined client
function SPSChemMix.sendAllTo(connection)
    if connection == nil then return end
    local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    for _, v in ipairs(vs ~= nil and vs.vehicles or {}) do
        if v.spsChemMix ~= nil then connection:sendEvent(SPSChemBooksEvent.new(v, v.spsChemMix, 0)) end
        for fui, st in pairs(v.spsChemMixByFui or {}) do connection:sendEvent(SPSChemBooksEvent.new(v, st, fui)) end
    end
end

SPSChemBooksEvent = {}
local SPSChemBooksEvent_mt = Class(SPSChemBooksEvent, Event)
InitEventClass(SPSChemBooksEvent, "SPSChemBooksEvent")

function SPSChemBooksEvent.emptyNew()
    return Event.new(SPSChemBooksEvent_mt)
end

function SPSChemBooksEvent.new(vehicle, st, fui)
    local self = SPSChemBooksEvent.emptyNew()
    self.vehicle   = vehicle
    self.fui       = fui or 0   -- [SPS MKS8 2026-11-11] 0 = the vehicle's chem tank, else that unit's books
    self.type      = st.type or FillType.UNKNOWN
    self.chemL     = st.chemL or 0
    self.waterL    = st.waterL or 0
    self.mixL      = st.mixL or 0
    self.washing   = st.washing == true
    self.dirtyWith = st.dirtyWith or FillType.UNKNOWN
    -- [SPS CHEM 2026-11-06] washout
    self.residue     = st.residue or 0
    self.rinsesDone  = math.min(255, st.rinsesDone or 0)
    self.phase       = st.phase or 0
    self.phaseT      = math.max(0, st.phaseT or 0)
    self.rinseTarget = st.rinseTarget == true
    self.poorRinse   = st.poorRinse == true
    self.ask         = st.ask or 0
    self.askId       = st.askId or 0
    self.contamType  = st.contamType or FillType.UNKNOWN
    self.contamLevel = st.contamLevel or 0
    return self
end

function SPSChemBooksEvent:readStream(streamId, connection)
    self.vehicle   = NetworkUtil.readNodeObject(streamId)
    self.fui       = streamReadUInt8(streamId)
    self.type      = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.chemL     = streamReadFloat32(streamId)
    self.waterL    = streamReadFloat32(streamId)
    self.mixL      = streamReadFloat32(streamId)
    self.washing   = streamReadBool(streamId)
    self.dirtyWith = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.residue     = streamReadFloat32(streamId)
    self.rinsesDone  = streamReadUInt8(streamId)
    self.phase       = streamReadUInt8(streamId)
    self.phaseT      = streamReadFloat32(streamId)
    self.rinseTarget = streamReadBool(streamId)
    self.poorRinse   = streamReadBool(streamId)
    self.ask         = streamReadUInt8(streamId)
    self.askId       = streamReadUInt8(streamId)
    self.contamType  = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.contamLevel = streamReadFloat32(streamId)
    self:run(connection)
end

function SPSChemBooksEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUInt8(streamId, math.min(255, self.fui or 0))
    streamWriteUIntN(streamId, self.type, FillTypeManager.SEND_NUM_BITS)
    streamWriteFloat32(streamId, self.chemL)
    streamWriteFloat32(streamId, self.waterL)
    streamWriteFloat32(streamId, self.mixL)
    streamWriteBool(streamId, self.washing)
    streamWriteUIntN(streamId, self.dirtyWith, FillTypeManager.SEND_NUM_BITS)
    streamWriteFloat32(streamId, self.residue)
    streamWriteUInt8(streamId, self.rinsesDone)
    streamWriteUInt8(streamId, self.phase)
    streamWriteFloat32(streamId, self.phaseT)
    streamWriteBool(streamId, self.rinseTarget)
    streamWriteBool(streamId, self.poorRinse)
    streamWriteUInt8(streamId, self.ask)
    streamWriteUInt8(streamId, self.askId)
    streamWriteUIntN(streamId, self.contamType, FillTypeManager.SEND_NUM_BITS)
    streamWriteFloat32(streamId, self.contamLevel)
end

function SPSChemBooksEvent:run(connection)
    if not connection:getIsServer() or self.vehicle == nil then return end   -- server -> client only
    local function ft(i) return (i ~= nil and i ~= FillType.UNKNOWN) and i or nil end
    local st = { type = ft(self.type), chemL = self.chemL, waterL = self.waterL, mixL = self.mixL,
                 washing = self.washing, dirtyWith = ft(self.dirtyWith),
                 residue = self.residue, rinsesDone = self.rinsesDone, phase = self.phase, phaseT = self.phaseT,
                 rinseTarget = self.rinseTarget, poorRinse = self.poorRinse, ask = self.ask, askId = self.askId,
                 contamType = ft(self.contamType), contamLevel = self.contamLevel }
    if (self.fui or 0) > 0 then
        self.vehicle.spsChemMixByFui = self.vehicle.spsChemMixByFui or {}
        self.vehicle.spsChemMixByFui[self.fui] = st
    else
        self.vehicle.spsChemMix = st
    end
end

-- ---------------------------------------------------------------------------
-- Save / load (vehicles by uniqueId, storages by placeable uniqueId + index)
-- ---------------------------------------------------------------------------
function SPSChemMix.save(xmlFile)
    local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    local idx = 0
    for _, v in ipairs(vs ~= nil and vs.vehicles or {}) do
        local uid = v.getUniqueId ~= nil and v:getUniqueId() or nil
        local units = uid ~= nil and SPSChemMix.chemFillUnits(v) or {}
        for ui, fui in ipairs(units) do   -- [SPS MKS8 2026-11-11] every booked unit; the chem tank comes first, no #fui
        local st = SPSChemMix.getState(v, fui)
        if st ~= nil and (st.type ~= nil or st.washing or st.dirtyWith ~= nil or st.rinseTarget) then
            local base = string.format("slurryPipeSystem.chemMix.vehicle(%d)", idx)
            xmlFile:setString(base .. "#uniqueId", uid)
            if ui > 1 then xmlFile:setInt(base .. "#fui", fui) end
            xmlFile:setString(base .. "#type", st.type and ftName(st.type) or "")
            xmlFile:setFloat(base .. "#chemL", st.chemL or 0)
            xmlFile:setFloat(base .. "#waterL", st.waterL or 0)
            xmlFile:setFloat(base .. "#mixL", st.mixL or 0)
            xmlFile:setBool(base .. "#washing", st.washing == true)
            xmlFile:setString(base .. "#dirtyWith", st.dirtyWith and ftName(st.dirtyWith) or "")
            -- [SPS CHEM 2026-11-06] washout (a cycle that was running is saved as finished: its water is in the tank)
            local ph = st.phase or 0
            if ph >= 1 and ph <= 4 then
                ph = ((v:getFillUnitFillLevel(fui) or 0) > 1) and 5 or 0
            end
            xmlFile:setFloat(base .. "#residue", st.residue or 0)
            xmlFile:setInt(base .. "#rinsesDone", st.rinsesDone or 0)
            xmlFile:setInt(base .. "#phase", ph)
            xmlFile:setFloat(base .. "#washMaxL", st.washMaxL or 0)
            xmlFile:setBool(base .. "#rinseTarget", st.rinseTarget == true)
            xmlFile:setBool(base .. "#poorRinse", st.poorRinse == true)
            xmlFile:setString(base .. "#contamType", st.contamType and ftName(st.contamType) or "")
            xmlFile:setFloat(base .. "#contamLevel", st.contamLevel or 0)
            idx = idx + 1
        end
        end
    end
    if idx > 0 then clog("saved books of %d tank(s)", idx) end
    -- [part 3] storages
    local sidx = 0
    forEachStorage(function(storage, key)
        local all = storage.spsChemBooks
        if all ~= nil then
            for ft, b in pairs(all) do
                if (b.chemL or 0) + (b.waterL or 0) > 0.001 then
                    local base = string.format("slurryPipeSystem.chemMix.storage(%d)", sidx)
                    xmlFile:setString(base .. "#key", key)
                    xmlFile:setString(base .. "#fillType", ftName(ft))
                    xmlFile:setFloat(base .. "#chemL", b.chemL or 0)
                    xmlFile:setFloat(base .. "#waterL", b.waterL or 0)
                    sidx = sidx + 1
                end
            end
        end
    end)
    if sidx > 0 then clog("saved books of %d silo product(s)", sidx) end
end

function SPSChemMix.load(xmlFile)
    SPSChemMix.pending = {}
    SPSChemMix.pendingStorage = {}
    local function ft(s) local i = g_fillTypeManager:getFillTypeIndexByName(s or ""); return (i ~= nil and i ~= FillType.UNKNOWN) and i or nil end
    local idx = 0
    while true do
        local base = string.format("slurryPipeSystem.chemMix.vehicle(%d)", idx)
        if not xmlFile:hasProperty(base) then break end
        local uid = xmlFile:getString(base .. "#uniqueId")
        if uid ~= nil and xmlFile:getFloat(base .. "#mixL") == nil then
            -- [SPS CHEM 2026-11-06] saves from before the ready-mix line: books exactly on 1 : n were ready mix
            local c, w = xmlFile:getFloat(base .. "#chemL", 0), xmlFile:getFloat(base .. "#waterL", 0)
            local n = SPSChemMix.waterParts()
            if c > 0 and math.abs(w / c - n) < 0.05 * n then xmlFile:setFloat(base .. "#mixL", c + w) end
        end
        if uid ~= nil then
            local sfui = xmlFile:getInt(base .. "#fui")   -- [SPS MKS8 2026-11-11] a unit other than the chem tank
            local pkey = (sfui ~= nil and sfui > 0) and (uid .. "#" .. tostring(sfui)) or uid
            SPSChemMix.pending[pkey] = {
                type = ft(xmlFile:getString(base .. "#type")), chemL = xmlFile:getFloat(base .. "#chemL", 0),
                waterL = xmlFile:getFloat(base .. "#waterL", 0), washing = xmlFile:getBool(base .. "#washing", false),
                mixL = xmlFile:getFloat(base .. "#mixL"),
                dirtyWith = ft(xmlFile:getString(base .. "#dirtyWith")),
                residue = xmlFile:getFloat(base .. "#residue"), rinsesDone = xmlFile:getInt(base .. "#rinsesDone", 0),
                phase = xmlFile:getInt(base .. "#phase", 0), washMaxL = xmlFile:getFloat(base .. "#washMaxL", 0),
                rinseTarget = xmlFile:getBool(base .. "#rinseTarget", false), poorRinse = xmlFile:getBool(base .. "#poorRinse", false),
                contamType = ft(xmlFile:getString(base .. "#contamType")), contamLevel = xmlFile:getFloat(base .. "#contamLevel", 0),
            }
            local p = SPSChemMix.pending[pkey]
            if p.dirtyWith ~= nil and p.residue == nil then p.residue = 1 end   -- saves from before the washout
        end
        idx = idx + 1
    end
    -- [part 3] storages
    local sidx = 0
    while true do
        local base = string.format("slurryPipeSystem.chemMix.storage(%d)", sidx)
        if not xmlFile:hasProperty(base) then break end
        local key = xmlFile:getString(base .. "#key")
        local f = ft(xmlFile:getString(base .. "#fillType"))
        if key ~= nil and f ~= nil then
            SPSChemMix.pendingStorage[key] = SPSChemMix.pendingStorage[key] or {}
            SPSChemMix.pendingStorage[key][f] = { chemL = xmlFile:getFloat(base .. "#chemL", 0), waterL = xmlFile:getFloat(base .. "#waterL", 0) }
        end
        sidx = sidx + 1
    end
    SPSChemMix._storageKeys = nil
end

-- Console: spsChemMix - books of every tank + silo, prices
function SPSChemMix:consoleInfo()
    SPSChemMix.resolveFillTypes()
    local n = SPSChemMix.waterParts()
    local out = { string.format("chemMixing=%s ratio 1:%d  S&F=%s PF=%s", tostring(SPSChemMix.isOn()), n,
        tostring(g_SoilFertilityManager ~= nil), tostring(g_precisionFarming ~= nil)) }
    for conc, base in pairs(SPSChemMix.concToBase) do
        local cd, bd = g_fillTypeManager:getFillTypeByIndex(conc), g_fillTypeManager:getFillTypeByIndex(base)
        table.insert(out, string.format("  %s %.2f/l (base %s %.2f/l)", ftName(conc), cd and cd.pricePerLiter or 0,
            ftName(base), bd and bd.pricePerLiter or 0))
    end
    for _, p in ipairs(SPSChemMix._storePallets or {}) do
        table.insert(out, string.format("  shop: %s %d (base %d)", tostring(p.item.xmlFilename), p.item.price or 0, p.price or 0))
    end
    local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    for _, v in ipairs(vs ~= nil and vs.vehicles or {}) do
        local fui = SPSChemMix.getChemFillUnit(v)
        if fui ~= nil and (v:getFillUnitFillLevel(fui) or 0) > 0.001 then
            local st = SPSChemMix.getState(v) or {}
            local s = SPSChemMix.getVehicleStrength(v, fui)
            table.insert(out, string.format("  %s%s: tank %s %.0f l | %s chem %.1f water %.1f strength %.0f%% washing=%s dirty=%s",
                v.spec_sprayer ~= nil and "" or "[tank] ", tostring(v.configFileName), ftName(v:getFillUnitFillType(fui)), v:getFillUnitFillLevel(fui) or 0,
                ftName(st.type), st.chemL or 0, st.waterL or 0, s * 100, tostring(st.washing), ftName(st.dirtyWith)))
        end
    end
    forEachStorage(function(storage, key)
        for ft, b in pairs(storage.spsChemBooks or {}) do
            local total = (b.chemL or 0) + (b.waterL or 0)
            if total > 0.001 then
                table.insert(out, string.format("  [silo] %s %s: %.0f l chem %.1f water %.1f strength %.0f%%", key, ftName(ft),
                    storage:getFillLevel(ft) or 0, b.chemL, b.waterL, b.chemL / total * (n + 1) * 100))
            end
        end
    end)
    for _, l in ipairs(out) do print("[SPS CHEM] " .. l) end
    return table.concat(out, "\n")
end
addConsoleCommand("spsChemMix", "SPS: chem mix books of every tank and silo + concentrate prices", "consoleInfo", SPSChemMix)

-- [SPS CHEM 2026-11-08] Console: spsChemPallets [rescan] - the sprayer liquids and their twins, the categories that made
-- them liquids, and every shop pallet that spawns with contents: REPRICED or skipped with the reason (William: "a way that
-- the script reads all the stuff and says yes you need a price increase and no you don't")
function SPSChemMix:consolePallets(arg)
    SPSChemMix.resolveFillTypes()
    local fm  = g_fillTypeManager
    local out = {}
    local lf  = fm:getFillTypeIndexByName("LIQUIDFERTILIZER")
    local names = {}
    for ft, fam in pairs(SPSChemMix.collectSprayerLiquids(fm)) do
        local nm = ftName(ft)
        local twin = SPSChemMix.baseToConc[ft] ~= nil and " +conc"
            or (SPSChemMix.unsoldLiquids[nm] and " no twin: not sold")
            or (SPSChemMix.notConcLiquids[nm] and " no twin: not a concentrate")
            or (SPSChemMix.cappedLiquids[nm] and " NO TWIN: fill type cap")
            or " NO TWIN"
        table.insert(names, string.format("%s(%s%s)", nm, fam == lf and "fert" or "herb", twin))
    end
    table.sort(names)
    table.insert(out, string.format("chemMixing=%s ratio 1:%d  sprayer liquids: %s", tostring(SPSChemMix.isOn()),
        SPSChemMix.waterParts(), table.concat(names, " ")))
    local cats = {}
    for catName, ftSet in pairs(fm.categoryNameToFillTypes or {}) do
        local l = {}
        for ft, _ in pairs(ftSet) do table.insert(l, ftName(ft)) end
        table.sort(l)
        table.insert(cats, string.format("  category %s %s: %s", catName,
            SPSChemMix.isSprayerLiquidCategory(fm, ftSet) and "= LIQUID" or "(no vote)", table.concat(l, " ")))
    end
    table.sort(cats)
    for _, c in ipairs(cats) do table.insert(out, c) end
    if arg == "rescan" and SPSChemMix._storePallets ~= nil then
        for _, p in ipairs(SPSChemMix._storePallets) do   -- back to base prices / names first, the rescan records them as base
            p.item.price = p.price
            if p.name ~= nil then p.item.name = p.name end
            for _, c in ipairs(p.cfg) do c.item.price = c.price end
        end
        SPSChemMix._storePallets = nil
        SPSChemMix.scanStorePallets(true)
        SPSChemMix.applyPrices()
    elseif SPSChemMix._storePallets == nil then
        SPSChemMix.scanStorePallets()   -- never scanned (Chem Mixing off since load): list without repricing
    end
    table.insert(out, string.format("shop pallets that spawn with contents: %d seen, %d repriced%s",
        #(SPSChemMix._palletReport or {}), #(SPSChemMix._storePallets or {}),
        SPSChemMix.isOn() and "" or " (Chem Mixing OFF: shop prices stay at base)"))
    for _, r in ipairs(SPSChemMix._palletReport or {}) do
        table.insert(out, string.format("  %s %s%s | type=%s start=%s %.0f l | base price %d%s",
            r.verdict == "REPRICED" and "REPRICED" or "skipped ", tostring(r.xml),
            r.pack ~= nil and (" -> " .. tostring(r.pack)) or "", tostring(r.typeName), tostring(r.startFt), r.level, r.base,
            r.shopName ~= nil and (" | shop: " .. tostring(r.shopName)) or ""))
        if r.verdict ~= "REPRICED" then table.insert(out, "           " .. r.verdict) end
    end
    for _, l in ipairs(out) do print("[SPS CHEM] " .. l) end
    return table.concat(out, "\n")
end
addConsoleCommand("spsChemPallets", "SPS: sprayer liquids + concentrate twins, and every shop chemical pallet with its price verdict (arg: rescan)", "consolePallets", SPSChemMix)
