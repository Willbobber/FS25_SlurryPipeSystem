-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.4

-- SPSConduitHUDExtension.lua
-- FS25_SlurryPipeSystem

SPSConduitHUDExtension = {}
local SPSConduitHUDExtension_mt = Class(SPSConduitHUDExtension)

function SPSConduitHUDExtension.new(vehicle)
    local self = setmetatable({}, SPSConduitHUDExtension_mt)
    self.isSPSExtension = true        -- bypass InputHelpDisplay visibility gate
    self.priority = GS_PRIO_HIGH
    self.vehicle  = vehicle

    local r, g, b, a = unpack(HUD.COLOR.BACKGROUND)
    self.backgroundTop    = g_overlayManager:createOverlay("gui.hudExtension_top",    0, 0, 0, 0)
    self.backgroundScale  = g_overlayManager:createOverlay("gui.hudExtension_middle", 0, 0, 0, 0)
    self.backgroundBottom = g_overlayManager:createOverlay("gui.hudExtension_bottom", 0, 0, 0, 0)
    self.backgroundTop:setColor(r, g, b, a)
    self.backgroundScale:setColor(r, g, b, a)
    self.backgroundBottom:setColor(r, g, b, a)

    -- Two data rows: FROM and TO, plus optional thickness warning
    self.NUM_ROWS = 2

    self:storeScaledValues()
    g_messageCenter:subscribe(
        MessageType.SETTING_CHANGED[GameSettings.SETTING.UI_SCALE],
        self.storeScaledValues, self)

    return self
end

function SPSConduitHUDExtension:delete()
    self.backgroundTop:delete()
    self.backgroundScale:delete()
    self.backgroundBottom:delete()
    g_messageCenter:unsubscribeAll(self)
end

function SPSConduitHUDExtension:storeScaledValues()
    local uiScale = g_gameSettings:getValue(GameSettings.SETTING.UI_SCALE)
    local _, offsetTop    = getNormalizedScreenValues(0, 26 * uiScale)
    local _, offsetBottom = getNormalizedScreenValues(0,  8 * uiScale)
    local _, rowHeight    = getNormalizedScreenValues(0, 22 * uiScale)

    self.offsetTop    = offsetTop
    self.offsetBottom = offsetBottom
    self.rowHeight    = rowHeight
    self.totalHeight  = rowHeight * self.NUM_ROWS + offsetTop + offsetBottom

    local width, borderH = getNormalizedScreenValues(330 * uiScale, 6 * uiScale)
    self.backgroundTop:setDimension(width, borderH)
    self.backgroundBottom:setDimension(width, borderH)
    self.backgroundScale:setDimension(width, self.totalHeight - 2 * borderH)

    self.titleOffsetX, self.titleOffsetY = getNormalizedScreenValues(14 * uiScale, -19 * uiScale)
    local _, titleSize = getNormalizedScreenValues(0, 11 * uiScale)
    self.titleSize = titleSize

    local _, textSize = getNormalizedScreenValues(0, 11 * uiScale)
    self.textSize    = textSize
    self.textOffsetX, self.textOffsetY = getNormalizedScreenValues(14 * uiScale, 7 * uiScale)
end

function SPSConduitHUDExtension:getHeight()
    return self.totalHeight
end

function SPSConduitHUDExtension:draw(inputHelpDisplay, posX, posY)
    -- Position and render background panels
    self.backgroundTop:setPosition(posX, posY - self.backgroundTop.height)
    self.backgroundScale:setPosition(posX, self.backgroundTop.y - self.backgroundScale.height)
    self.backgroundBottom:setPosition(posX, self.backgroundScale.y - self.backgroundBottom.height)
    self.backgroundTop:render()
    self.backgroundScale:render()
    self.backgroundBottom:render()

    -- Title
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    local maxWidth = self.backgroundTop.width - 2 * self.titleOffsetX
    local title = Utils.limitTextToWidth("SPS Pump", self.titleSize, maxWidth, false, "...")
    renderText(posX + self.titleOffsetX, posY + self.titleOffsetY, self.titleSize, title)
    setTextBold(false)

    -- Resolve source and destination
    local srcText = "FROM: ---"
    local dstText = "   TO: ---"

    if g_slurryPipeManager ~= nil then
        local cvState = g_slurryPipeManager:getVehicleState(self.vehicle)
        local c1, c2
        for _, vEntry in ipairs(g_slurryPipeManager.registeredVehicles) do
            if vEntry.vehicle == self.vehicle then
                for _, c in ipairs(vEntry.couplingEntries) do
                    if     c.id == 1 then c1 = c
                    elseif c.id == 2 then c2 = c end
                end
                break
            end
        end

        if c1 ~= nil and c2 ~= nil and c1.isConnected and c2.isConnected then
            local dir = cvState and cvState.direction or SPS_DIRECTION_FILL
            local srcCoupling = (dir == SPS_DIRECTION_DISCHARGE) and c1 or c2
            local dstCoupling = (dir == SPS_DIRECTION_DISCHARGE) and c2 or c1

            local function getName(entry)
                if entry == nil then return "---" end
                if entry.vehicle ~= nil then
                    local n = nil
                    if entry.vehicle.getFullName ~= nil then n = entry.vehicle:getFullName() end
                    return n or entry.debugLabel or "---"
                end
                if entry.placeable ~= nil then
                    local si = entry.placeable.storeItem
                    if si ~= nil and si.name ~= nil and si.name ~= "" then
                        return si.name:gsub("^%$l10n_storeItem_", "")
                    end
                end
                return entry.debugLabel or "---"
            end

            local function getLevelStr(entry)
                if entry == nil then return "" end
                local ft = FillType.LIQUIDMANURE
                if entry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or entry.type == "FILL_UNIT_ONLY" then
                    if entry.vehicle ~= nil then
                        local lvl = entry.vehicle:getFillUnitFillLevel(entry.fillUnitIndex) or 0
                        local cap = entry.vehicle:getFillUnitCapacity(entry.fillUnitIndex) or 0
                        if cap > 0 then
                            return string.format(" %d/%dL (%.0f%%)", MathUtil.round(lvl), MathUtil.round(cap), (lvl/cap)*100)
                        end
                        return string.format(" %dL", MathUtil.round(lvl))
                    end
                elseif entry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
                    if entry.storage ~= nil then
                        local lvl = entry.storage:getFillLevel(ft) or 0
                        local cap = 0
                        if entry.storage.getCapacity ~= nil then
                            cap = entry.storage:getCapacity(ft) or 0
                        end
                        if cap > 0 then
                            return string.format(" %d/%dL (%.0f%%)", MathUtil.round(lvl), MathUtil.round(cap), (lvl/cap)*100)
                        end
                        return string.format(" %dL", MathUtil.round(lvl))
                    end
                end
                return ""
            end

            local srcEntry = g_slurryPipeManager:resolveSourceForCouplingPartner(srcCoupling)
            local dstEntry = g_slurryPipeManager:resolveSourceForCouplingPartner(dstCoupling)
            srcText = "FROM: " .. getName(srcEntry) .. getLevelStr(srcEntry)
            dstText = "   TO: " .. getName(dstEntry) .. getLevelStr(dstEntry)
        end
    end

    -- Build row list — FROM, TO, and optional thickness warning
    local rows = { srcText, dstText }

    if g_slurryPipeManager ~= nil then
        local cvState = g_slurryPipeManager:getVehicleState(self.vehicle)
        if cvState ~= nil then
            local extSrc = g_slurryPipeManager:resolveExternalSource(self.vehicle)
            if extSrc ~= nil then
                local warn = g_slurryPipeManager:getThicknessWarning(extSrc)
                if warn == "tooThick" then
                    table.insert(rows, g_i18n:getText("warning_spsSlurryTooThick"))
                elseif warn == "thickening" then
                    local pct = math.floor((extSrc.thickness or 0) * 100)
                    table.insert(rows, string.format(g_i18n:getText("warning_spsSlurryThickening"), pct))
                end
            end
        end
    end

    -- Update background height if row count changed
    local numRows = #rows
    if numRows ~= self.NUM_ROWS then
        self.NUM_ROWS = numRows
        self:storeScaledValues()
    end

    -- Draw rows bottom-up from offsetTop
    local rowPosY = posY - self.offsetTop
    for _, rowStr in ipairs(rows) do
        rowPosY = rowPosY - self.rowHeight
        local clipped = Utils.limitTextToWidth(rowStr, self.textSize,
            self.backgroundTop.width - 2 * self.textOffsetX, false, "...")
        renderText(posX + self.textOffsetX, rowPosY + self.textOffsetY, self.textSize, clipped)
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)

    return self.backgroundBottom.y
end