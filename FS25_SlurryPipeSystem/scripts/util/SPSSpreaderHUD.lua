-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4

-- SPSSpreaderHUD.lua
-- FS25_SlurryPipeSystem
--
-- Top-centre HUD panel for the active spreader. Uses the vanilla info-box chrome
-- (gui.hudExtension_* overlays, same as SPSConduitHUDExtension) so it matches the base
-- game style. Shows, top to bottom: a title, slurry detail rows (with the correct gauge
-- for the controlling tanker — bar for vacuum, L/s for HVP), the DB icon, and a strip of
-- section cells that turn red when their outlet is blocked (or all red when the macerator
-- is blocked). The cell count is read from the spreader's blockage entries (== work-area
-- sections), so it adapts to any bar / cultivator automatically.
--
-- Stage 1: draw + visibility + field toggles + scale. Position is centred at top.
-- (Drag-to-place + per-profile persistence come in Stage 2, via SPSMod:mouseEvent.)

SPSSpreaderHUD = {}
local SPSSpreaderHUD_mt = Class(SPSSpreaderHUD)

SPSSpreaderHUD.ICON_PATH    = "icons/dibblebarIcon_bomechTracPack.png"  -- generic, used for all
SPSSpreaderHUD.CELL_PATH    = "icons/sps_hud_cell.png"
SPSSpreaderHUD.ICON_ASPECT  = 4.835    -- width / height of the cropped icon

-- Layout in reference pixels (scaled by UI scale * user scale at draw time).
SPSSpreaderHUD.PANEL_W   = 340
SPSSpreaderHUD.PAD_X     = 14
SPSSpreaderHUD.BORDER    = 6
SPSSpreaderHUD.TITLE_H   = 24
SPSSpreaderHUD.ROW_H     = 20
SPSSpreaderHUD.GAP       = 8
SPSSpreaderHUD.CELL_H    = 16
SPSSpreaderHUD.CELL_GAP  = 4
SPSSpreaderHUD.TOP_PAD   = 4
SPSSpreaderHUD.BOT_PAD   = 10
SPSSpreaderHUD.TEXT_PX   = 13
SPSSpreaderHUD.TOP_Y     = 0.985   -- normalized top edge of the panel

function SPSSpreaderHUD.new(modDir)
    local self = setmetatable({}, SPSSpreaderHUD_mt)
    self.modDir  = modDir
    self.visible = true
    self.scale   = 1.0
    self.posX    = nil     -- nil => centred each frame; set by drag in Stage 2
    self.posY    = SPSSpreaderHUD.TOP_Y

    -- per-field visibility (Stage 2 settings will toggle these)
    self.fieldVisible = { image = true, fill = true, crust = true, thick = true, risk = true, pump = true }

    local r, g, b, a = unpack(HUD.COLOR.BACKGROUND)
    self.bgTop    = g_overlayManager:createOverlay("gui.hudExtension_top",    0, 0, 0, 0)
    self.bgMid    = g_overlayManager:createOverlay("gui.hudExtension_middle", 0, 0, 0, 0)
    self.bgBottom = g_overlayManager:createOverlay("gui.hudExtension_bottom", 0, 0, 0, 0)
    self.bgTop:setColor(r, g, b, a)
    self.bgMid:setColor(r, g, b, a)
    self.bgBottom:setColor(r, g, b, a)

    self.iconOverlay = createImageOverlay(Utils.getFilename(SPSSpreaderHUD.ICON_PATH, modDir))
    self.cellOverlay = createImageOverlay(Utils.getFilename(SPSSpreaderHUD.CELL_PATH, modDir))
    if self.iconOverlay == nil or self.iconOverlay == 0 then
        print("[SPS HUD] WARNING: could not load DB icon at " .. tostring(SPSSpreaderHUD.ICON_PATH))
    end
    if self.cellOverlay == nil or self.cellOverlay == 0 then
        print("[SPS HUD] WARNING: could not load cell image at " .. tostring(SPSSpreaderHUD.CELL_PATH))
    end
    return self
end

function SPSSpreaderHUD:delete()
    if self.bgTop ~= nil then self.bgTop:delete() end
    if self.bgMid ~= nil then self.bgMid:delete() end
    if self.bgBottom ~= nil then self.bgBottom:delete() end
    if self.iconOverlay ~= nil and self.iconOverlay ~= 0 then delete(self.iconOverlay) end
    if self.cellOverlay ~= nil and self.cellOverlay ~= 0 then delete(self.cellOverlay) end
end

-- Settings hooks (used by Stage 2 / settings menu)
function SPSSpreaderHUD:setVisible(v)        self.visible = v == true end
function SPSSpreaderHUD:setScale(s)          self.scale = math.max(0.5, math.min(2.0, s or 1.0)) end
function SPSSpreaderHUD:setFieldVisible(k,v) if self.fieldVisible[k] ~= nil then self.fieldVisible[k] = v == true end end
function SPSSpreaderHUD:setPosition(x,y)     self.posX = x; self.posY = y end

-- True if the vehicle has a sprayer work area (a spreader, even with no blockage nodes).
function SPSSpreaderHUD:_hasSprayerWorkArea(vehicle)
    local wa = vehicle ~= nil and vehicle.spec_workArea or nil
    if wa == nil or wa.workAreas == nil then return false end
    for _, a in ipairs(wa.workAreas) do
        if a.functionName == "processSprayerArea" then return true end
    end
    return false
end

-- The spreader to display: a registered vehicle the player is currently in
-- (getIsActiveForInput(true) ignores implement selection) that is a spreader — either it
-- carries blockage nodes (shows the section strip) OR it has a sprayer work area (built-in
-- spreader like the RossMore; shows details + icon, no strip). Returns its entry, or nil.
function SPSSpreaderHUD:_getActiveSpreader()
    if g_slurryPipeManager == nil or g_slurryPipeManager.registeredVehicles == nil then return nil end
    for _, entry in ipairs(g_slurryPipeManager.registeredVehicles) do
        local v = entry.vehicle
        if v ~= nil then
            local hasBlock = entry.blockageEntries ~= nil and #entry.blockageEntries > 0
            if hasBlock or self:_hasSprayerWorkArea(v) then
                local root = (v.getRootVehicle ~= nil) and v:getRootVehicle() or v
                if root ~= nil and root.getIsActiveForInput ~= nil and root:getIsActiveForInput(true) then
                    return entry
                end
            end
        end
    end
    return nil
end

function SPSSpreaderHUD:_buildRows(controller)
    local M = g_slurryPipeManager
    local rows = {}
    local fv = self.fieldVisible

    if fv.fill then
        local lvl = 0
        if SlurryPipeSystemOverride ~= nil and SlurryPipeSystemOverride.getSPSFillLevel ~= nil then
            lvl = SlurryPipeSystemOverride.getSPSFillLevel(controller) or 0
        end
        rows[#rows+1] = { l = g_i18n:getText("sps_hudSlurry"), v = string.format("%d l", MathUtil.round(lvl)) }
    end

    local crust = M.getTankerCrust ~= nil and (M:getTankerCrust(controller) or 0) or 0
    if fv.crust then
        rows[#rows+1] = { l = g_i18n:getText("sps_hudCrust"), v = string.format("%d%%", MathUtil.round(crust * 100)) }
    end
    if fv.thick then
        local th = M.getTankerThickness ~= nil and (M:getTankerThickness(controller) or 0) or 0
        rows[#rows+1] = { l = g_i18n:getText("sps_hudThickness"), v = string.format("%d%%", MathUtil.round(th * 100)) }
    end
    if fv.risk then
        local key = "sps_hudRiskLow"
        if crust >= 0.6 then key = "sps_hudRiskHigh"
        elseif crust >= (M.BLOCKAGE_CRUST_MIN or 0.3) then key = "sps_hudRiskMed" end
        rows[#rows+1] = { l = g_i18n:getText("sps_hudRisk"), v = g_i18n:getText(key) }
    end
    if fv.pump then
        local label, val
        if M.usesPressureModel ~= nil and M:usesPressureModel(controller) then
            local st = M:getVehicleState(controller)
            local p  = st and st.pressure or 0
            label = g_i18n:getText("sps_hudVacuum")
            val   = string.format("%.1f bar", p)
        else
            local rate = M.getEmptyRate ~= nil and (M:getEmptyRate(controller) or 0) or 0
            local pt   = M.getPumpType ~= nil and M:getPumpType(controller) or nil
            label = (pt == "HVP") and g_i18n:getText("sps_hudHVP") or g_i18n:getText("sps_hudPump")
            val   = string.format("%d L/s", MathUtil.round(rate))
        end
        rows[#rows+1] = { l = label, v = val }
    end
    return rows
end

function SPSSpreaderHUD:draw()
    -- pull player-configured settings (persisted in the manager)
    local hs = (g_slurryPipeManager ~= nil) and g_slurryPipeManager.hudSettings or nil
    if hs ~= nil then
        self.visible            = hs.enabled ~= false
        self.scale              = hs.scale or 1.0
        self.posX               = hs.posX
        self.posY               = hs.posY or SPSSpreaderHUD.TOP_Y
        self.fieldVisible.image = hs.image ~= false
        self.fieldVisible.fill  = hs.fill  ~= false
        self.fieldVisible.crust = hs.crust ~= false
        self.fieldVisible.thick = hs.thick ~= false
        self.fieldVisible.risk  = hs.risk  ~= false
        self.fieldVisible.pump  = hs.pump  ~= false
    end
    if not self.visible then return end
    if g_slurryPipeManager == nil then return end
    local entry = self:_getActiveSpreader()
    if entry == nil then return end
    local vehicle    = entry.vehicle
    local controller = g_slurryPipeManager:getBlockageController(vehicle) or vehicle

    local rows = self:_buildRows(controller)

    -- count outlet sections (exclude the macerator) for the cell strip
    local nCells = 0
    for _, b in ipairs(entry.blockageEntries or {}) do
        if not b.isMacerator then nCells = nCells + 1 end
    end
    local hasCells = nCells > 0
    local maceratorBlocked = g_slurryPipeManager.isMaceratorBlocked ~= nil
        and g_slurryPipeManager:isMaceratorBlocked(vehicle) or false

    -- map outlet index -> blocked
    local blockedByCell = {}
    do
        local i = 0
        for _, b in ipairs(entry.blockageEntries or {}) do
            if not b.isMacerator then
                i = i + 1
                blockedByCell[i] = (b.blocked == true)
            end
        end
    end

    local s = g_gameSettings:getValue(GameSettings.SETTING.UI_SCALE) * (self.scale or 1.0)
    local function W(px) local w = getNormalizedScreenValues(px, 0) return w end
    local function H(px) local _, h = getNormalizedScreenValues(0, px) return h end

    local panelWpx = SPSSpreaderHUD.PANEL_W * s
    local padXpx   = SPSSpreaderHUD.PAD_X   * s
    local borderpx = SPSSpreaderHUD.BORDER  * s
    local titleHpx = SPSSpreaderHUD.TITLE_H * s
    local rowHpx   = SPSSpreaderHUD.ROW_H   * s
    local gappx    = SPSSpreaderHUD.GAP     * s
    local cellHpx  = SPSSpreaderHUD.CELL_H  * s
    local cellGpx  = SPSSpreaderHUD.CELL_GAP* s
    local topPadpx = SPSSpreaderHUD.TOP_PAD * s
    local botPadpx = SPSSpreaderHUD.BOT_PAD * s
    local textpx   = SPSSpreaderHUD.TEXT_PX * s
    local iconWpx  = panelWpx - 2 * padXpx
    local iconHpx  = self.fieldVisible.image and (iconWpx / SPSSpreaderHUD.ICON_ASPECT) or 0

    local midpx = topPadpx + #rows * rowHpx + gappx + iconHpx + botPadpx
    if hasCells then midpx = midpx + gappx + cellHpx end
    local panelW = W(panelWpx)
    local border = H(borderpx)
    local mid    = H(midpx)

    local leftX  = (self.posX ~= nil) and self.posX or (0.5 - panelW * 0.5)
    local topY   = self.posY or SPSSpreaderHUD.TOP_Y
    self._lastPanelW = panelW
    self._lastTopY   = topY

    -- chrome
    self.bgTop:setDimension(panelW, border)
    self.bgMid:setDimension(panelW, mid)
    self.bgBottom:setDimension(panelW, border)
    self.bgTop:setPosition(leftX, topY - border)
    self.bgMid:setPosition(leftX, self.bgTop.y - mid)
    self.bgBottom:setPosition(leftX, self.bgMid.y - border)
    self.bgTop:render()
    self.bgMid:render()
    self.bgBottom:render()

    local _, textSize = getNormalizedScreenValues(0, textpx)
    local padX = W(padXpx)
    local rightX = leftX + panelW - padX

    -- (title removed — no header text on the spreader panel)

    -- slurry rows (label left, value right)
    local cy = topY - border - H(topPadpx)
    for _, row in ipairs(rows) do
        local baseline = cy - H(rowHpx * 0.74)
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(0.82, 0.82, 0.80, 1)
        renderText(leftX + padX, baseline, textSize, row.l)
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextColor(1, 1, 1, 1)
        renderText(rightX, baseline, textSize, row.v)
        cy = cy - H(rowHpx)
    end
    setTextAlignment(RenderText.ALIGN_LEFT)

    cy = cy - H(gappx)

    -- DB icon (white line-art; faint red tint if the macerator is blocked)
    if self.fieldVisible.image and self.iconOverlay ~= nil and self.iconOverlay ~= 0
       and getIsOverlayReady(self.iconOverlay) then
        local iconW = W(iconWpx)
        local iconH = H(iconHpx)
        if maceratorBlocked then
            setOverlayColor(self.iconOverlay, 1.0, 0.55, 0.55, 1.0)
        else
            setOverlayColor(self.iconOverlay, 1.0, 1.0, 1.0, 1.0)
        end
        renderOverlay(self.iconOverlay, leftX + padX, cy - iconH, iconW, iconH)
        cy = cy - iconH - H(gappx)
    end

    -- section cell strip (only when the spreader actually has outlet sections)
    if hasCells and self.cellOverlay ~= nil and self.cellOverlay ~= 0
       and getIsOverlayReady(self.cellOverlay) then
        local stripW   = iconWpx
        local cellWpx  = (stripW - (nCells - 1) * cellGpx) / nCells
        local cellW    = W(cellWpx)
        local cellH    = H(cellHpx)
        local cellY    = cy - cellH
        local xpx      = padXpx
        for i = 1, nCells do
            local red = maceratorBlocked or blockedByCell[i]
            if red then
                setOverlayColor(self.cellOverlay, 0.95, 0.16, 0.16, 1.0)
            else
                setOverlayColor(self.cellOverlay, 0.24, 0.82, 0.36, 0.95)
            end
            renderOverlay(self.cellOverlay, leftX + W(xpx), cellY, cellW, cellH)
            xpx = xpx + cellWpx + cellGpx
        end
    end

    -- edit-mode hint, centred just above the panel
    if self.editMode then
        local _, hintSize = getNormalizedScreenValues(0, 12 * s)
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(1, 0.85, 0.3, 1)
        renderText(leftX + panelW * 0.5, topY + H(6 * s), hintSize, g_i18n:getText("sps_hudEditHint"))
        setTextAlignment(RenderText.ALIGN_LEFT)
    end

    setTextColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------------------
-- Edit mode (driven by SPS_HUD_EDIT + SPSMod:mouseEvent)
-- ---------------------------------------------------------------------------
function SPSSpreaderHUD:isEditMode()
    return self.editMode == true
end

function SPSSpreaderHUD:setEditMode(on)
    self.editMode = on == true
end

-- Reposition so the panel's top-centre tracks the cursor (normalized coords).
function SPSSpreaderHUD:applyMouseMove(x, y)
    local hs = g_slurryPipeManager ~= nil and g_slurryPipeManager.hudSettings or nil
    if hs == nil then return end
    local w = self._lastPanelW or 0.18
    hs.posX = math.max(0, math.min(x - w * 0.5, 1 - w))
    hs.posY = math.max(0.10, math.min(y, 0.999))
end

function SPSSpreaderHUD:applyScroll(delta)
    local hs = g_slurryPipeManager ~= nil and g_slurryPipeManager.hudSettings or nil
    if hs == nil then return end
    hs.scale = math.max(0.5, math.min(2.0, (hs.scale or 1.0) + delta))
end