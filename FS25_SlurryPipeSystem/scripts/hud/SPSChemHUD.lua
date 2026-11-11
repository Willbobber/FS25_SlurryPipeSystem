-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.2.0

-- SPSChemHUD.lua — [SPS CHEM 2026-11-05] chem mix panel (Chem Mixing on), mixer-wagon style.
--
-- Shows the books of one chem sprayer (SPSChemMix), per product like the mixer wagon: ready mix, concentrate and
-- water that went in, then the mix ratio with a strength bar and band (green = good, amber = strong / double,
-- red = too weak / scorch / crop kill) and what to add to hit the target.
-- Which sprayer: the one in the vehicle combination you are driving, else the nearest within 6 m on foot.
-- Top centre, same chrome and scale as the slurry spreader panel (never both: that one is slurry only).

SPSChemHUD = {}
SPSChemHUD.ON_FOOT_RADIUS = 6.0   -- on foot, sprayers without a control spot
SPSChemHUD.SPOT_MARGIN    = 0.5   -- on foot, around the control spot's radius
SPSChemHUD.PANEL_W = 340
SPSChemHUD.PAD_X   = 14
SPSChemHUD.BORDER  = 6
SPSChemHUD.ROW_H   = 20
SPSChemHUD.BAR_H   = 8
SPSChemHUD.TOP_PAD = 4
SPSChemHUD.BOT_PAD = 8
SPSChemHUD.TEXT_PX = 13
SPSChemHUD.TOP_Y   = 0.985

local function txt(key, fallback)
    if g_i18n ~= nil and g_i18n:hasText(key) then return g_i18n:getText(key) end
    return fallback
end

local function ftTitle(ft)
    return (ft ~= nil and g_fillTypeManager:getFillTypeTitleByIndex(ft)) or "?"
end

function SPSChemHUD.init()
    if SPSChemHUD._ready then return end
    local r, g, b, a = unpack(HUD.COLOR.BACKGROUND)
    SPSChemHUD.bgTop    = g_overlayManager:createOverlay("gui.hudExtension_top",    0, 0, 0, 0)
    SPSChemHUD.bgMid    = g_overlayManager:createOverlay("gui.hudExtension_middle", 0, 0, 0, 0)
    SPSChemHUD.bgBottom = g_overlayManager:createOverlay("gui.hudExtension_bottom", 0, 0, 0, 0)
    SPSChemHUD.bgTop:setColor(r, g, b, a)
    SPSChemHUD.bgMid:setColor(r, g, b, a)
    SPSChemHUD.bgBottom:setColor(r, g, b, a)
    SPSChemHUD.bar = g_overlayManager:createOverlay("gui.hudExtension_middle", 0, 0, 0, 0)
    SPSChemHUD._ready = true
end

-- the chem sprayer to show (vehicle, fill unit) or nil
function SPSChemHUD.findVehicle()
    local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if vs == nil or vs.vehicles == nil then return nil end
    local px, py, pz
    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil and entityExists(g_localPlayer.rootNode)
    and (g_localPlayer.getIsControlled == nil or g_localPlayer:getIsControlled()) then
        px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    end
    local best, bestD = nil, math.huge
    local mgr = g_slurryPipeManager
    for _, v in ipairs(vs.vehicles) do
        -- [SPS CHEM 2026-11-09] liquid carriers with an SPS control node (550 Water/Chem Bowser) show the panel too (William:
        -- "the bowser has no mixing screen like the amazone sprayer has"); other tanks still get an info line only
        local laneEntry = mgr ~= nil and mgr.getLiquidLaneVehicleEntry ~= nil and mgr:getLiquidLaneVehicleEntry(v) or nil
        local fui = (SPSChemMix.isChemSprayer(v) or (laneEntry ~= nil and laneEntry.controls ~= nil and #laneEntry.controls > 0))
            and SPSChemMix.getChemFillUnit(v) or nil   -- [part 3] sprayers (+ bowsers) only
        if fui ~= nil and v.rootNode ~= nil then
            local root = v.getRootVehicle ~= nil and v:getRootVehicle() or v
            if root ~= nil and root.getIsActiveForInput ~= nil and root:getIsActiveForInput(true) then
                return v, fui
            end
            if px ~= nil then
                -- [SPS CHEM 2026-11-07] standing at the sprayer's control spot (door / bowl / pipe prompts), William
                local entry = mgr ~= nil and mgr.getSprayerVehicleEntry ~= nil and mgr:getSprayerVehicleEntry(v) or nil
                local spots = (entry ~= nil and entry.pumpControls) or (laneEntry ~= nil and laneEntry.controls) or nil
                if spots ~= nil and #spots > 0 then
                    for _, pc in ipairs(spots) do
                        if pc.node ~= nil and entityExists(pc.node) then
                            local x, y, z = getWorldTranslation(pc.node)
                            local d = (x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2
                            local r = (pc.radius or 1.5) + SPSChemHUD.SPOT_MARGIN
                            if d <= r * r and d < bestD then best, bestD = v, d end
                        end
                    end
                else
                    local x, y, z = getWorldTranslation(v.rootNode)
                    local d = (x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2
                    if d <= SPSChemHUD.ON_FOOT_RADIUS ^ 2 and d < bestD then best, bestD = v, d end
                end
            end
        end
    end
    if best ~= nil then return best, SPSChemMix.getChemFillUnit(best) end
    return nil
end

-- [SPS MKS8 2026-11-11] a TANKER with several tanks (a lane fitting with <tank> children, no sprayer spec): the panel is a
-- tank list - one line per tank with its level and what it holds (water / milk / concentrate / booked mix + strength) -
-- never the mixer-wagon rows (William: "it's not a sprayer, it's just a tank to hold and transport water"). The
-- coupling of the vehicle's multi-tank fitting, else nil.
function SPSChemHUD.tankListOf(v)
    if v == nil or v.spec_sprayer ~= nil then return nil end
    local mgr = g_slurryPipeManager
    local entry = mgr ~= nil and mgr.getLiquidLaneVehicleEntry ~= nil and mgr:getLiquidLaneVehicleEntry(v) or nil
    if entry == nil then return nil end
    for _, c in ipairs(entry.couplings or {}) do
        if c.tanks ~= nil and #c.tanks > 1 then return c end
    end
    return nil
end

local function litres(x)
    return string.format("%d", math.floor((x or 0) + 0.5))
end

function SPSChemHUD.buildTankRows(v, c)
    local name = (v.getName ~= nil and v:getName()) or ""
    local rows = { { l = txt("sps_chemHudTanks", "Tanks") .. (name ~= "" and (" - " .. name) or ""), v = "" } }
    for i, t in ipairs(c.tanks) do
        local fui = t.fillUnitIndex or i
        local tname = SlurryPipeManager.llConfigText ~= nil and SlurryPipeManager.llConfigText(t.name) or nil
        if tname == nil or tname == "" then tname = string.format(txt("sps_tankN", "tank %d"), t.id or i) end
        local sel  = (c.selectedTank or 1) == i
        local lvl  = v:getFillUnitFillLevel(fui) or 0
        local cap  = v:getFillUnitCapacity(fui) or 0
        local held = v:getFillUnitFillType(fui)
        local what, col = txt("sps_tankEmpty", "empty"), nil
        if lvl > 0.5 then
            local vol = string.format("%s / %s l", litres(lvl), litres(cap))
            if SPSChemMix.isConcentrate ~= nil and SPSChemMix.isConcentrate(held) then
                local base = SPSChemMix.concToBase ~= nil and SPSChemMix.concToBase[held] or nil
                what = string.format("%s %s  %s", txt("sps_chemHudConc", "Concentrate"), ftTitle(base or held), vol)
            else
                local st = (SPSChemMix.isChemFillUnit ~= nil and SPSChemMix.isChemFillUnit(v, fui)) and SPSChemMix.getState(v, fui) or nil
                local s  = (st ~= nil and st.type ~= nil) and SPSChemMix.getStrength(st) or nil
                if s ~= nil then
                    local band = SPSChemMix.getBand(s)
                    col = band ~= nil and { band[3], band[4], band[5] } or nil
                    what = string.format("%s %.0f%% %s  %s", ftTitle(st.type), s * 100,
                        txt("sps_chemBand" .. (band and band[2] or "Good"), band and band[2] or ""), vol)
                else
                    what = string.format("%s  %s", ftTitle(held), vol)
                end
            end
        end
        rows[#rows + 1] = { l = (sel and "> " or "   ") .. tname, v = what, col = col }
    end
    return rows
end

function SPSChemHUD.buildRows(v, fui)
    local level = v:getFillUnitFillLevel(fui) or 0
    local held  = v:getFillUnitFillType(fui)
    local st    = SPSChemMix.getState(v)
    if st == nil then return nil end
    local n     = SPSChemMix.waterParts()
    local rows  = {}

    -- [SPS CHEM 2026-11-07] the pipe is on a washout station: its valve
    local station = SPSChemWashout ~= nil and SPSChemWashout.stationOf ~= nil and SPSChemWashout.stationOf(v) or nil
    if station ~= nil then
        local dirty = SPSChemWashout.stationValveDirty(station)
        rows[#rows + 1] = { l = txt("sps_chemHudStation", "Washout station"),
                            v = (dirty and txt("sps_chemHudValveDirty", "valve: dirty water out") or txt("sps_chemHudValveClean", "valve: clean water in"))
                                .. (SPSChemWashout.valveManual() and (" " .. txt("sps_chemHudValveManual", "(set by hand)")) or ""),
                            col = dirty and { 1.0, 0.75, 0.2 } or { 0.55, 0.80, 1.0 } }
    end

    if level <= 0.001 and st.dirtyWith == nil then
        rows[#rows + 1] = { l = txt("sps_chemHudTitle", "Chem mix"), v = txt("sps_chemHudEmptyClean", "Empty - clean") }
        SPSChemHUD.rinseTankRow(v, rows)
        return rows
    end
    if level <= 0.001 then
        rows[#rows + 1] = { l = txt("sps_chemHudTitle", "Chem mix"), v = txt("sps_chemHudEmpty", "Empty") }
        rows[#rows + 1] = { l = string.format(txt("sps_chemHudDirty", "Tank dirty with %s - wash out first"), ftTitle(st.dirtyWith)), v = "", col = { 1.0, 0.75, 0.2 } }
        SPSChemHUD.washRows(v, st, rows)
        return rows
    end

    -- [SPS CHEM 2026-11-09] a tank of PURE concentrate (IBC poured into a bowser): no books yet - say so and how much water it wants
    if st.type == nil and SPSChemMix.isConcentrate ~= nil and SPSChemMix.isConcentrate(held) then
        local base = SPSChemMix.concToBase ~= nil and SPSChemMix.concToBase[held] or nil
        rows[#rows + 1] = { l = txt("sps_chemHudTitle", "Chem mix") .. (base ~= nil and (" - " .. ftTitle(base)) or ""),
                            v = string.format("%s 1:%d", txt("sps_chemHudTarget", "target"), n) }
        rows[#rows + 1] = { l = txt("sps_chemHudConc", "Concentrate"), v = string.format("%.0f l", level) }
        rows[#rows + 1] = { l = txt("sps_chemHudWater", "Water"), v = "0 l" }
        rows[#rows + 1] = { l = txt("sps_chemHudAddWater", "Add water"), v = string.format("+%.0f l", level * n), col = { 0.82, 0.82, 0.80 } }
        return rows
    end
    if held == FillType.WATER or st.type == nil then
        rows[#rows + 1] = { l = txt("sps_chemHudTitle", "Chem mix"), v = txt("sps_chemHudWashout", "Water / washout") }
        rows[#rows + 1] = { l = txt("sps_chemHudWater", "Water"), v = string.format("%.0f l", level) }
        if st.dirtyWith ~= nil then
            rows[#rows + 1] = { l = string.format(txt("sps_chemHudWashing", "Washing out %s"), ftTitle(st.dirtyWith)), v = "", col = { 1.0, 0.75, 0.2 } }
            SPSChemHUD.washRows(v, st, rows)
        else
            SPSChemHUD.rinseTankRow(v, rows)
        end
        return rows
    end

    -- books on a client are the last synced ratio; scale them to the live level
    local total = math.max(0.001, (st.chemL or 0) + (st.waterL or 0))
    local k = level / total
    local chemL, waterL, mixL = (st.chemL or 0) * k, (st.waterL or 0) * k, math.min(level, (st.mixL or 0) * k)
    -- what went in, per product: ready mix carries its own 1 : n share, the rest was added as concentrate / water
    local concAdded  = math.max(0, chemL  - mixL / (n + 1))
    local waterAdded = math.max(0, waterL - mixL * n / (n + 1))
    local strength = SPSChemMix.getStrength(st) or 1
    local band = SPSChemMix.getBand(strength)
    local col = band ~= nil and { band[3], band[4], band[5] } or { 1, 1, 1 }

    rows[#rows + 1] = { l = txt("sps_chemHudTitle", "Chem mix") .. " - " .. ftTitle(st.type),
                        v = string.format("%s 1:%d", txt("sps_chemHudTarget", "target"), n) }
    if mixL > 0.5 then
        rows[#rows + 1] = { l = txt("sps_chemHudReadyMix", "Ready mix"), v = string.format("%.0f l", mixL) }
    end
    if concAdded > 0.5 or mixL <= 0.5 then
        rows[#rows + 1] = { l = txt("sps_chemHudConc", "Concentrate"), v = string.format("%.0f l", concAdded) }
    end
    if waterAdded > 0.5 or mixL <= 0.5 then
        rows[#rows + 1] = { l = txt("sps_chemHudWater", "Water"), v = string.format("%.0f l", waterAdded) }
    end
    local ratioTxt = chemL > 0.001 and string.format("1:%.1f", waterL / chemL) or "-"
    -- strength bar: full width = 250%, tick at 100%
    rows[#rows + 1] = { l = txt("sps_chemHudMix", "Mix") .. " " .. ratioTxt,
                        v = string.format("%.0f%%  %s", strength * 100, txt("sps_chemBand" .. (band and band[2] or "Good"), band and band[2] or "")),
                        col = col, bar = strength, barMax = 2.5 }
    -- what to add to land on the ratio (water for the concentrate in, or concentrate for the water in)
    -- [SPS CHEM 2026-11-06] not washed out before this chemical went in
    if st.contamType ~= nil and (st.contamLevel or 0) > 0.0005 then
        rows[#rows + 1] = { l = string.format(txt("sps_chemHudContam", "%s residue in the mix"), ftTitle(st.contamType)),
                            v = string.format("%.1f%%", st.contamLevel * 100), col = { 0.95, 0.30, 0.20 } }
    end
    SPSChemHUD.rinseTankRow(v, rows)
    if strength > 1.2 then
        rows[#rows + 1] = { l = txt("sps_chemHudAddWater", "Add water"), v = string.format("+%.0f l", math.max(0, chemL * n - waterL)), col = { 0.82, 0.82, 0.80 } }
    elseif strength < 0.8 then
        rows[#rows + 1] = { l = txt("sps_chemHudAddConc", "Add concentrate"), v = string.format("+%.0f l", math.max(0, waterL / n - chemL)), col = { 0.82, 0.82, 0.80 } }
    end
    return rows
end

-- [SPS CHEM 2026-11-06] washout lines: rinse count, what is happening now, residue, rinse tank
local PHASE_KEYS = {
    [1] = { "sps_chemHudPhasePrep",  "Unfolding the boom" },
    [2] = { "sps_chemHudPhaseTank",  "Flushing the tank" },
    [3] = { "sps_chemHudPhaseBoom",  "Flushing the boom" },
    [4] = { "sps_chemHudPhaseFinal", "Final tank flush" },
    [5] = { "sps_chemHudPhaseDrain", "Rinse water out through the nozzles" },
    [6] = { "sps_chemHudPhaseReturn", "Dirty water back to the washout station" },   -- [station]
}

function SPSChemHUD.rinseTankRow(v, rows)
    local cfg = SPSChemWashout ~= nil and SPSChemWashout.getCfg(v) or nil
    if cfg == nil or cfg.rinseFui == nil then return end
    rows[#rows + 1] = { l = txt("sps_chemHudRinseTank", "Rinse tank"),
                        v = string.format("%.0f / %.0f l", v:getFillUnitFillLevel(cfg.rinseFui) or 0, v:getFillUnitCapacity(cfg.rinseFui) or 0) }
    -- which tank a pipe fills (Y at the pump: load main tank / load rinse tank / unload)
    local state = g_slurryPipeManager ~= nil and g_slurryPipeManager.getSprayerObjectState ~= nil
        and g_slurryPipeManager:getSprayerObjectState(v) or nil
    if state ~= nil and state.direction == SPS_SPRAYER_DIRECTION_FILL then
        local rinse = SPSChemWashout.isRinseTarget(v)
        rows[#rows + 1] = { l = txt("sps_chemHudPipeFills", "Pipe fills"),
                            v = rinse and txt("sps_chemHudRinseTank", "Rinse tank") or txt("sps_chemHudMainTank", "Main tank"),
                            col = rinse and { 0.55, 0.80, 1.0 } or nil }
    end
end

function SPSChemHUD.washRows(v, st, rows)
    if SPSChemWashout == nil then return end
    local need = SPSChemWashout.rinsesNeeded()
    local done = st.rinsesDone or 0
    local ph = st.phase or 0
    local amber, green, red = { 1.0, 0.75, 0.2 }, { 0.30, 0.85, 0.35 }, { 0.95, 0.30, 0.20 }
    if ph >= 1 and ph <= 4 then
        local k = PHASE_KEYS[ph]
        rows[#rows + 1] = { l = string.format(txt("sps_chemHudRinse", "Rinse %d of %d"), done + 1, need) .. " - " .. txt(k[1], k[2]),
                            v = ph == 1 and "" or string.format("%d s", math.ceil((st.phaseT or 0) / 1000)), col = green }
    elseif ph == 5 or ph == 6 then
        -- rinse water running out through the nozzles / back to the station (countdown), or paused (Wash out runs the rest out)
        local running = (st.phaseT or 0) > 0
        rows[#rows + 1] = { l = string.format(txt("sps_chemHudRinse", "Rinse %d of %d"), done + 1, need) .. " - " ..
                                (running and txt(PHASE_KEYS[ph][1], PHASE_KEYS[ph][2]) or txt("sps_chemHudDrainPaused", "Paused - press Wash out")),
                            v = running and string.format("%d s", math.ceil(st.phaseT / 1000)) or "", col = running and green or amber }
    else
        rows[#rows + 1] = { l = txt("sps_chemHudRinsesDone", "Rinses done"), v = string.format("%d / %d", done, need) }
    end
    if st.poorRinse and ph == 0 then
        rows[#rows + 1] = { l = txt("sps_chemHudPoorRinse", "Poor rinse - use Wash out and do it again"), v = "", col = red }
    end
    rows[#rows + 1] = { l = txt("sps_chemHudResidue", "Residue left"),
                        v = string.format("%.1f%%", (SPSChemWashout.residueNow(v, st) or 0) * 100), col = amber }
    SPSChemHUD.rinseTankRow(v, rows)
end

function SPSChemHUD.draw()
    if SPSChemMix == nil or not SPSChemMix.isOn() or g_currentMission == nil or g_gui == nil
    or (g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible()) then return end
    local hs = (g_slurryPipeManager ~= nil) and g_slurryPipeManager.hudSettings or nil
    if hs ~= nil and hs.enabled == false then return end
    local v, fui = SPSChemHUD.findVehicle()
    if v == nil then return end
    local tankC = SPSChemHUD.tankListOf(v)   -- [SPS MKS8 2026-11-11] a multi-tank tanker: the tank list
    local rows = tankC ~= nil and SPSChemHUD.buildTankRows(v, tankC) or SPSChemHUD.buildRows(v, fui)
    if rows == nil or #rows == 0 then return end
    SPSChemHUD.init()

    local s = g_gameSettings:getValue(GameSettings.SETTING.UI_SCALE) * ((hs ~= nil and hs.scale) or 1.0)
    local function W(px) local w = getNormalizedScreenValues(px, 0) return w end
    local function H(px) local _, h = getNormalizedScreenValues(0, px) return h end

    local nBars = 0
    for _, r in ipairs(rows) do if r.bar ~= nil then nBars = nBars + 1 end end
    local panelW = W(SPSChemHUD.PANEL_W * s)
    local border = H(SPSChemHUD.BORDER * s)
    local mid    = H((SPSChemHUD.TOP_PAD + #rows * SPSChemHUD.ROW_H + nBars * (SPSChemHUD.BAR_H + 2) + SPSChemHUD.BOT_PAD) * s)
    local leftX  = 0.5 - panelW * 0.5
    local topY   = SPSChemHUD.TOP_Y

    SPSChemHUD.bgTop:setDimension(panelW, border)
    SPSChemHUD.bgMid:setDimension(panelW, mid)
    SPSChemHUD.bgBottom:setDimension(panelW, border)
    SPSChemHUD.bgTop:setPosition(leftX, topY - border)
    SPSChemHUD.bgMid:setPosition(leftX, SPSChemHUD.bgTop.y - mid)
    SPSChemHUD.bgBottom:setPosition(leftX, SPSChemHUD.bgMid.y - border)
    SPSChemHUD.bgTop:render()
    SPSChemHUD.bgMid:render()
    SPSChemHUD.bgBottom:render()

    local _, textSize = getNormalizedScreenValues(0, SPSChemHUD.TEXT_PX * s)
    local padX   = W(SPSChemHUD.PAD_X * s)
    local rightX = leftX + panelW - padX
    local barW   = panelW - 2 * padX
    local cy = topY - border - H(SPSChemHUD.TOP_PAD * s)
    for i, row in ipairs(rows) do
        local baseline = cy - H(SPSChemHUD.ROW_H * s * 0.74)
        setTextBold(i == 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(0.82, 0.82, 0.80, 1)
        renderText(leftX + padX, baseline, textSize, row.l)
        setTextAlignment(RenderText.ALIGN_RIGHT)
        if row.col ~= nil then
            setTextColor(row.col[1], row.col[2], row.col[3], 1)
        else
            setTextColor(1, 1, 1, 1)
        end
        renderText(rightX, baseline, textSize, row.v)
        cy = cy - H(SPSChemHUD.ROW_H * s)
        if row.bar ~= nil then
            -- bar: full width = barMax x target, white tick at 100%
            local bmax = row.barMax or 1.5
            local bh = H(SPSChemHUD.BAR_H * s)
            SPSChemHUD.bar:setColor(0.25, 0.25, 0.25, 0.9)
            SPSChemHUD.bar:setDimension(barW, bh)
            SPSChemHUD.bar:setPosition(leftX + padX, cy - bh)
            SPSChemHUD.bar:render()
            local f = math.max(0, math.min(1, row.bar / bmax))
            if f > 0 then
                SPSChemHUD.bar:setColor(row.col[1], row.col[2], row.col[3], 1)
                SPSChemHUD.bar:setDimension(barW * f, bh)
                SPSChemHUD.bar:render()
            end
            SPSChemHUD.bar:setColor(1, 1, 1, 1)
            SPSChemHUD.bar:setDimension(W(2 * s), bh)
            SPSChemHUD.bar:setPosition(leftX + padX + barW / bmax, cy - bh)
            SPSChemHUD.bar:render()
            cy = cy - bh - H(2 * s)
        end
    end
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end
