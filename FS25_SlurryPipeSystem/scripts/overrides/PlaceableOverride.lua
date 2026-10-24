-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.4

-- PlaceableOverride.lua

SPSPlaceableOverride = {}

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.2] Per-tank rows for dynamic sprayer stores.
--
-- A dynamic sprayer store (fert / herbicide) is N PHYSICAL TANKS, one per
-- <sprayerPipeCoupling> in its fillPoints.xml. Each tank holds exactly ONE
-- fillType at a time and stays locked to it until it drains — that rule is
-- enforced by _dynStoreComputeOccupancy / _dynStoreTypeGate (SPSM_Sprayers
-- 955-1037), and _installDynStoreGate (1068) overrides storage.capacity with
-- the SUM of the coupler capacities so the per-tank limits are what bind.
-- So a 1-coupler store can carry 1 product and a 4-coupler store 4.
--
-- The on-foot info box did not reflect that. Vanilla PlaceableSilo:updateInfo
-- (PlaceableSilo 350-378) builds its rows from
-- spec.loadingStation:getAllFillLevels(farmId) — i.e. per FILLTYPE, summed
-- across the whole silo. Tanks are not fill types, so there was no way to see
-- WHICH coupler held what, and two tanks holding the same product collapsed
-- into a single row.
--
-- This block emits exactly one row per coupler, ascending id:
--     T-1   Liquid Fertilizer  12,400 l
--     T-2   Herbicide           3,100 l
--     T-3   Empty
-- Row count therefore follows the config with nothing hardcoded — declare a
-- fifth <sprayerPipeCoupling> and a fifth row appears. Empty tanks are still
-- listed, because "how many free tanks are left" is exactly what the type gate
-- is deciding on when it admits or refuses a new product.
--
-- Data source, all of it pre-existing:
--     sc.id           tank number
--     sc.dynFillType  locked fillType, nil when the tank is free
--     sc.dynLevel     litres in THIS tank (the compartment ledger)
--     sc.spsCapacity  this tank's own #capacity
-- The ledger is server-authoritative and replicated by
-- SPSSprayerCompartmentEvent (_syncSprayerCompartment, SPSM_Sprayers 764), so
-- these rows are correct on a client without any new event.
-- ---------------------------------------------------------------------------

-- Volume string, matching the format vanilla uses for its own rows
-- (PlaceableSilo 373 -> g_i18n:formatVolume(level, 0)).
local function spsFormatVolume(litres)
    if g_i18n ~= nil and g_i18n.formatVolume ~= nil then
        return g_i18n:formatVolume(litres or 0, 0)
    end
    return string.format("%d l", math.floor((litres or 0) + 0.5))
end

-- True when the SPS store's own Storage accounts for the ENTIRE amount vanilla
-- would show for this fillType.
--
-- Vanilla's row is the aggregate over every storage the silo's loadingStation
-- owns. Normally that is just the SPS store, so its row is fully replaced by
-- the per-tank rows. But a placeable may own a second storage SPS knows nothing
-- about; deleting the row there would hide litres that are genuinely present
-- and not represented in any tank. So the row is only removed when the two
-- figures agree — otherwise it is left in place alongside the tank rows.
--
-- getAllFillLevels is the same call PlaceableSilo:updateInfo (354) builds its
-- rows from, so this compares like with like.
local function spsStoreOwnsWholeAggregate(placeable, storage, fillType)
    if storage == nil or storage.getFillLevel == nil then return false end
    local spec = placeable.spec_silo
    if spec == nil or spec.loadingStation == nil or spec.loadingStation.getAllFillLevels == nil then
        -- Not a silo-spec placeable: vanilla emitted no fill-type rows to
        -- reconcile against, so there is nothing to remove.
        return false
    end
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or nil
    if farmId == nil then return false end
    local levels = spec.loadingStation:getAllFillLevels(farmId)
    if levels == nil then return false end
    local aggregate = levels[fillType] or 0
    local mine      = storage:getFillLevel(fillType) or 0
    return math.abs(aggregate - mine) <= 0.1
end

-- Removes the vanilla row whose title matches this fillType's title. Vanilla
-- writes title = g_fillTypeManager:getFillTypeTitleByIndex(ft) (PlaceableSilo
-- 373), so the title is the only handle available. Walks backwards so removal
-- cannot skip an entry.
local function spsRemoveFillTypeRow(infoTable, fillType)
    local title = g_fillTypeManager:getFillTypeTitleByIndex(fillType)
    if title == nil or title == "" then return end
    for i = #infoTable, 1, -1 do
        if infoTable[i] ~= nil and infoTable[i].title == title then
            table.remove(infoTable, i)
            return
        end
    end
end

-- Removes vanilla's "silo is empty" placeholder (PlaceableSilo 376), which it
-- inserts as { title = "", text = infohud_siloEmpty } when no fill type cleared
-- its 0.1 l threshold. Once the tank rows are present that line is misleading —
-- a store with a locked-but-nearly-drained tank is not "empty".
local function spsRemoveSiloEmptyRow(infoTable)
    local emptyText = g_i18n:getText("infohud_siloEmpty")
    for i = #infoTable, 1, -1 do
        local row = infoTable[i]
        if row ~= nil and (row.title == nil or row.title == "") and row.text == emptyText then
            table.remove(infoTable, i)
            return
        end
    end
end

function SPSPlaceableOverride.updateInfo(self, superFunc, infoTable)
    superFunc(self, infoTable)
    if g_slurryPipeManager ~= nil then
        local pEntry = g_slurryPipeManager:getPlaceableEntry(self)
        if pEntry ~= nil and pEntry.agitatorEnabled and pEntry.sourceEntry ~= nil then
            local se  = pEntry.sourceEntry
            local t   = g_slurryPipeManager:getApparentThickness(se)
            local pct = math.min(100, math.floor(t * 100 + 0.5))
            local dmPct  = math.min(100, math.floor(g_slurryPipeManager:getStoreDM(se) * 100 + 0.5))
            local liqPct = math.max(0, 100 - dmPct)
            local crustPct = math.min(100, math.floor((se.settle or 0) * 100 + 0.5))
            local warn = g_slurryPipeManager:getThicknessWarning(se)

            -- Dry matter is the true concentration that rises as liquid is pulled off
            -- (and falls when water is added); liquid is its complement. Crust is the
            -- un-mixed lumpiness that builds over time and drives spreader blockages —
            -- agitate to clear it. These make the two-pool state visible.
            table.insert(infoTable, {
                title = g_i18n:getText("sps_infoLiquidTitle"),
                text  = string.format("%d%%", liqPct),
            })
            table.insert(infoTable, {
                title = g_i18n:getText("sps_infoDryMatterTitle"),
                text  = string.format("%d%%", dmPct),
            })
            table.insert(infoTable, {
                title = g_i18n:getText("sps_infoCrustTitle"),
                text  = string.format("%d%%", crustPct),
            })

            -- Thickness / pumpability gauge with state-based guidance.
            if warn == "tooThick" then
                -- Dry matter itself is jammed: mixing cannot help, water is required.
                table.insert(infoTable, {
                    title      = g_i18n:getText("warning_spsSlurryTooThick"),
                    text       = string.format("%d%%", pct),
                    accentuate = true,
                })
            elseif warn == "needsMix" then
                -- Settled but pumpable once stirred.
                table.insert(infoTable, {
                    title      = g_i18n:getText("warning_spsSlurryNeedsMix"),
                    text       = string.format("%d%%", pct),
                    accentuate = true,
                })
            elseif warn == "thickeningWater" then
                -- [SPS 1.0.1.4] 80% band driven by dry matter, not settling: mixing
                -- removes only settle and can never bring the gauge below the DM line,
                -- so the advice here is water — the old "agitation advised" text was a
                -- dead end for this state.
                table.insert(infoTable, {
                    title      = string.format(g_i18n:getText("warning_spsSlurryThickeningWater"), pct),
                    text       = "",
                    accentuate = true,
                })
            elseif warn == "thickening" then
                table.insert(infoTable, {
                    title      = string.format(g_i18n:getText("warning_spsSlurryThickening"), pct),
                    text       = "",
                    accentuate = true,
                })
            else
                table.insert(infoTable, {
                    title = g_i18n:getText("sps_infoThicknessTitle"),
                    text  = string.format("%d%%", pct),
                })
            end
        end

        -- [SPS 1.0.1.2] Dynamic sprayer store: one row per physical tank.
        -- Independent of the slurry block above — a store is registered either as
        -- a slurry placeable or a sprayer placeable, never both, so the two never
        -- run together on the same object.
        local sEntry = g_slurryPipeManager.getSprayerPlaceableEntry ~= nil
            and g_slurryPipeManager:getSprayerPlaceableEntry(self) or nil
        if sEntry ~= nil and sEntry.dynCouplers ~= nil and #sEntry.dynCouplers > 0 then
            local storage = sEntry.sourceEntry ~= nil and sEntry.sourceEntry.storage or nil

            -- Ascending id order — the same order the adoption sweep and the
            -- occupancy simulation assign tanks in (SPSM_Sprayers 883, 969), so
            -- the numbering a player reads here is the numbering the gate used.
            -- Sorted on a LOCAL copy: entry.dynCouplers is the live list the gate
            -- walks and must not be reordered from a draw callback.
            local tanks = {}
            for _, sc in ipairs(sEntry.dynCouplers) do
                table.insert(tanks, sc)
            end
            -- [SPS 1.0.1.8] displayId = row number assigned at registration (unique per
            -- store even when a multi-tank coupler's <tank> ids restart at 1).
            table.sort(tanks, function(a, b)
                return (a.displayId or a.id or 0) < (b.displayId or b.id or 0)
            end)

            -- Drop the vanilla per-fillType rows these tanks account for, so the
            -- same litres are not listed twice under two different groupings.
            -- Only types actually held by a tank are considered: a fixed
            -- #capacity declaration (entry.spsFixedCaps) is aggregate-owned by
            -- design and keeps its vanilla row untouched.
            local seenTypes = {}
            for _, sc in ipairs(tanks) do
                local ft = sc.dynFillType
                if ft ~= nil and not seenTypes[ft] then
                    seenTypes[ft] = true
                    if sEntry.spsFixedCaps == nil or sEntry.spsFixedCaps[ft] == nil then
                        if spsStoreOwnsWholeAggregate(self, storage, ft) then
                            spsRemoveFillTypeRow(infoTable, ft)
                        end
                    end
                end
            end
            spsRemoveSiloEmptyRow(infoTable)

            local emptyLabel = g_i18n:getText("sps_infoTankEmpty")
            for _, sc in ipairs(tanks) do
                local title = string.format("T-%d", sc.displayId or sc.id or 0)
                local text
                if sc.dynFillType ~= nil then
                    local ftTitle = g_fillTypeManager:getFillTypeTitleByIndex(sc.dynFillType)
                        or tostring(sc.dynFillType)
                    text = string.format("%s  %s", ftTitle, spsFormatVolume(sc.dynLevel or 0))
                else
                    text = emptyLabel
                end
                table.insert(infoTable, {
                    title = title,
                    text  = text,
                })
            end
        end
    end
end
