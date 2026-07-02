-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4

-- PlaceableOverride.lua

SPSPlaceableOverride = {}

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
    end
end