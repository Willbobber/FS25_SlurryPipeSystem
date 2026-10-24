-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSConduitHUDExtension.lua
-- FS25_SlurryPipeSystem
--
-- [SPS 1.0.1.8] Pump flow meter for the PTO (conduit) pump and the pump mixer (tower mixer):
--   status (PUMPING / why it stopped), rate + litres pumped, thickness + flow speed, FROM / TO with levels, and the
--   thickness warning row.
-- Built only from state every peer already has (valve state, turned on, coupler valves, fill levels, store thickness):
-- the flow itself runs on the server, so rate and pumped litres are measured from the destination's fill level
-- (sample(), called every frame by the manager, so the count keeps going while the meter is not on screen).

SPSConduitHUDExtension = {}
local SPSConduitHUDExtension_mt = Class(SPSConduitHUDExtension)

local RATE_WINDOW_MS = 1000

-- _pumpMixerEndpoints stop tags -> HUD reason text
local MIXER_REASONS = {
    ["no agitator tip"]                            = "hud_spsPumpNotInSlurry",
    ["tip not submerged in a store"]               = "hud_spsPumpNotInSlurry",
    ["no connected coupler"]                       = "hud_spsPumpNoPipe",
    ["partner is draw-only (flowDirection FILL)"]  = "hud_spsPumpDrawOnly",
    ["receiving coupler's valve is closed"]        = "hud_spsPumpRecvValve",
    ["partner has no tank / store"]                = "hud_spsPumpNoTank",
    ["partner is the store being pumped from"]     = "hud_spsPumpSameStore",
}

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

    self.NUM_ROWS = 5
    self.meter = { dst = nil, lastLevel = nil, lastTime = nil, rate = 0, pumped = 0 }

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

local function isVehicleEntry(entry)
    return entry ~= nil and (entry.type == SlurryNodeUtil.SOURCE_TYPE_FILL_VOLUME or entry.type == "FILL_UNIT_ONLY")
end

-- level, capacity (nil, nil when unknown)
local function getLevel(entry, fillType)
    if entry == nil then return nil, nil end
    if isVehicleEntry(entry) then
        if entry.vehicle ~= nil and entry.fillUnitIndex ~= nil then
            return entry.vehicle:getFillUnitFillLevel(entry.fillUnitIndex) or 0,
                   entry.vehicle:getFillUnitCapacity(entry.fillUnitIndex) or 0
        end
    elseif entry.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE and entry.storage ~= nil then
        local lvl = entry.storage:getFillLevel(fillType) or 0
        local cap = 0
        if entry.storage.getCapacity ~= nil then cap = entry.storage:getCapacity(fillType) or 0 end
        return lvl, cap
    end
    return nil, nil
end

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
            return (si.name:gsub("^%$l10n_storeItem_", ""))
        end
    end
    return entry.debugLabel or "---"
end

local function getLevelStr(entry, fillType)
    local lvl, cap = getLevel(entry, fillType)
    if lvl == nil then return "" end
    if cap ~= nil and cap > 0 then
        return string.format(" %d/%dL (%.0f%%)", MathUtil.round(lvl), MathUtil.round(cap), (lvl / cap) * 100)
    end
    return string.format(" %dL", MathUtil.round(lvl))
end

-- What the pump is doing right now: { src, dst, fillType, stop (l10n key or nil = pumping), thickness, flowMult,
-- thickSrc, isMixer }
function SPSConduitHUDExtension:resolve()
    local mgr  = g_slurryPipeManager
    local veh  = self.vehicle
    local info = {}
    local entry = mgr ~= nil and mgr:getVehicleEntry(veh) or nil
    local state = mgr ~= nil and mgr:getVehicleState(veh) or nil
    if entry == nil or state == nil then
        info.stop = "hud_spsPumpNoPipe"
        return info
    end
    info.isMixer = entry.pumpMixer == true

    local turnedOn
    if mgr:isVehicleSelfPowered(veh) then
        turnedOn = state.pumpRunning == true
    else
        turnedOn = veh.getIsTurnedOn ~= nil and veh:getIsTurnedOn() or false
    end
    local valveOpen = state.valveOpen == true
    info.turnedOn = turnedOn

    if info.isMixer then
        -- same valve rule as tickFlow: the valve button OR the open valve of a connected MANUAL coupler
        if not valveOpen then
            for _, c in ipairs(entry.couplingEntries or {}) do
                if c.isConnected and c.valveOpen and c.valveType == SPS_VALVE_TYPE_MANUAL then valveOpen = true break end
            end
        end
        local src, dst, reason = mgr:_pumpMixerEndpoints(entry, nil)
        info.src = src or mgr:getPumpMixerStore(entry)
        info.dst = dst
        if info.dst == nil then
            for _, c in ipairs(entry.couplingEntries or {}) do
                if c.isConnected then info.dst = mgr:resolveSourceForCouplingPartner(c) break end
            end
        end
        if not valveOpen then
            info.stop = "hud_spsPumpValveClosed"
        elseif not turnedOn then
            info.stop = "hud_spsPumpBladesOff"
        elseif reason ~= nil then
            info.stop = MIXER_REASONS[reason] or "hud_spsPumpNoTank"
        end
    else
        local c1, c2
        for _, c in ipairs(entry.couplingEntries or {}) do
            if     c.id == 1 then c1 = c
            elseif c.id == 2 then c2 = c end
        end
        local connected = c1 ~= nil and c2 ~= nil and c1.isConnected and c2.isConnected
        if connected then
            local dir = state.direction or SPS_DIRECTION_FILL
            info.src = mgr:resolveSourceForCouplingPartner((dir == SPS_DIRECTION_DISCHARGE) and c1 or c2)
            info.dst = mgr:resolveSourceForCouplingPartner((dir == SPS_DIRECTION_DISCHARGE) and c2 or c1)
        end
        if not valveOpen then
            info.stop = "hud_spsPumpValveClosed"
        elseif not turnedOn then
            info.stop = "hud_spsPumpOff"
        elseif not connected then
            info.stop = "hud_spsPumpNoPipe"
        elseif info.src == nil or info.dst == nil then
            info.stop = "hud_spsPumpNoTank"
        end
    end

    info.fillType = mgr:_resolveSourceFillType(info.src)

    -- thickness of what is being pumped: a store's apparent thickness, or the thickness a tanker carries
    local thickSrc = info.src
    if not info.isMixer and (thickSrc == nil
        or (thickSrc.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE and not thickSrc.thickeningEnabled)) then
        thickSrc = mgr:resolveExternalSource(veh) or thickSrc
    end
    info.thickSrc = thickSrc
    if thickSrc ~= nil then
        if thickSrc.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            info.thickness = mgr:getApparentThickness(thickSrc)
            info.flowMult  = mgr:getFlowRateMultiplier(thickSrc)
        elseif isVehicleEntry(thickSrc) and thickSrc.vehicle ~= nil then
            info.thickness = mgr:getTankerThickness(thickSrc.vehicle)
            info.flowMult  = mgr:thicknessToFlowMultiplier(info.thickness)
        end
    end

    if info.stop == nil then
        local ft = info.fillType or FillType.LIQUIDMANURE
        local srcLevel = getLevel(info.src, ft)
        if info.fillType == nil or (srcLevel ~= nil and srcLevel <= 0) then
            info.stop = "hud_spsPumpSourceEmpty"
        elseif info.dst ~= nil and info.dst.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE and info.dst.storage ~= nil then
            local free = info.dst.storage:getFreeCapacity(mgr:resolveStoreDepositFillType(info.dst, ft)) or 0
            if free <= 0 then info.stop = "hud_spsPumpDestFull" end
        else
            local dl, dc = getLevel(info.dst, ft)
            if dl ~= nil and dc ~= nil and dc > 0 and dl >= dc - 0.5 then info.stop = "hud_spsPumpDestFull" end
        end
        if info.stop == nil and info.flowMult ~= nil and info.flowMult <= 0 then
            info.stop = "hud_spsPumpTooThick"
        end
    end
    return info
end

-- Every frame: rate (L/s over RATE_WINDOW_MS) and litres pumped into the current destination. The pumped total
-- restarts when the destination changes (a new tanker / store on the pipe).
-- [SPS 1.0.1.8] Why a RUNNING pump is not moving slurry, for the tanker HUD / coupler prompt.
-- Returns the stop l10n key (nil when pumping or no running pump involves the vehicle). Uses the
-- flow meter's last resolve (sample() runs every frame for every pump on clients).
function SPSConduitHUDExtension.getStopReasonFor(vehicle)
    local mgr = g_slurryPipeManager
    if mgr == nil or vehicle == nil then return nil end
    for _, entry in ipairs(mgr.registeredVehicles or {}) do
        local ext  = entry.hudExtension
        local info = ext ~= nil and ext.info or nil
        if info ~= nil and info.turnedOn then
            local hit = entry.vehicle == vehicle
                or (isVehicleEntry(info.src) and info.src.vehicle == vehicle)
                or (isVehicleEntry(info.dst) and info.dst.vehicle == vehicle)
            if hit then return info.stop, true end
        end
    end
    return nil, false
end

function SPSConduitHUDExtension:sample()
    if g_slurryPipeManager == nil then return end
    local info = self:resolve()
    self.info = info
    local m = self.meter
    local now = g_time or 0
    if info.dst ~= m.dst then
        m.dst, m.lastLevel, m.lastTime, m.rate, m.pumped = info.dst, nil, nil, 0, 0
    end
    if info.dst == nil then return end
    local lvl = getLevel(info.dst, info.fillType or FillType.LIQUIDMANURE)
    if lvl == nil then return end
    if m.lastLevel == nil then
        m.lastLevel, m.lastTime = lvl, now
        return
    end
    local elapsed = now - m.lastTime
    if elapsed >= RATE_WINDOW_MS then
        local delta = lvl - m.lastLevel
        if info.stop == nil and delta > 0 then
            m.rate   = delta * 1000 / elapsed
            m.pumped = m.pumped + delta
        else
            m.rate = 0
        end
        m.lastLevel, m.lastTime = lvl, now
    end
end

function SPSConduitHUDExtension:draw(inputHelpDisplay, posX, posY)
    -- Position and render background panels
    self.backgroundTop:setPosition(posX, posY - self.backgroundTop.height)
    self.backgroundScale:setPosition(posX, self.backgroundTop.y - self.backgroundScale.height)
    self.backgroundBottom:setPosition(posX, self.backgroundScale.y - self.backgroundBottom.height)
    self.backgroundTop:render()
    self.backgroundScale:render()
    self.backgroundBottom:render()

    local info = self.info or self:resolve()
    local m = self.meter

    -- Title
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    local maxWidth = self.backgroundTop.width - 2 * self.titleOffsetX
    local titleText = info.isMixer and g_i18n:getText("hud_spsPumpMixerTitle") or "SPS Pump"
    local title = Utils.limitTextToWidth(titleText, self.titleSize, maxWidth, false, "...")
    renderText(posX + self.titleOffsetX, posY + self.titleOffsetY, self.titleSize, title)
    setTextBold(false)

    -- rows: { text, r, g, b }
    local rows = {}
    if info.stop == nil then
        table.insert(rows, { string.format(g_i18n:getText("hud_spsPumpStatus"), g_i18n:getText("hud_spsPumpPumping")), 0.4, 1, 0.4 })
    else
        table.insert(rows, { string.format(g_i18n:getText("hud_spsPumpStatus"),
            string.format(g_i18n:getText("hud_spsPumpStopped"), g_i18n:getText(info.stop))), 1, 0.6, 0.2 })
    end
    if info.isMixer then
        -- blades row: green while they spin (mixing), whatever the pump is doing
        if info.turnedOn then
            table.insert(rows, { string.format(g_i18n:getText("hud_spsPumpBlades"), g_i18n:getText("hud_spsPumpBladesSpinning")), 0.4, 1, 0.4 })
        else
            table.insert(rows, { string.format(g_i18n:getText("hud_spsPumpBlades"), g_i18n:getText("hud_spsPumpBladesStopped")), 0.7, 0.7, 0.7 })
        end
    end
    table.insert(rows, { string.format(g_i18n:getText("hud_spsPumpRate"),
        MathUtil.round(info.stop == nil and m.rate or 0), MathUtil.round(m.pumped)), 1, 1, 1 })
    if info.thickness ~= nil then
        table.insert(rows, { string.format(g_i18n:getText("hud_spsPumpThickness"),
            math.floor(info.thickness * 100), math.floor((info.flowMult or 1) * 100)), 1, 1, 1 })
    end
    local ft = info.fillType or FillType.LIQUIDMANURE
    table.insert(rows, { "FROM: " .. getName(info.src) .. getLevelStr(info.src, ft), 1, 1, 1 })
    table.insert(rows, { "   TO: " .. getName(info.dst) .. getLevelStr(info.dst, ft), 1, 1, 1 })

    -- thickness warning row (store sources only)
    if g_slurryPipeManager ~= nil and info.thickSrc ~= nil then
        local warn = g_slurryPipeManager:getThicknessWarning(info.thickSrc)
        local pct = math.floor((info.thickness or 0) * 100)
        if warn == "tooThick" then
            table.insert(rows, { g_i18n:getText("warning_spsSlurryTooThick"), 1, 0.4, 0.4 })
        elseif warn == "needsMix" then
            table.insert(rows, { g_i18n:getText("warning_spsSlurryNeedsMix"), 1, 0.4, 0.4 })
        elseif warn == "thickeningWater" then
            table.insert(rows, { string.format(g_i18n:getText("warning_spsSlurryThickeningWater"), pct), 1, 0.8, 0.3 })
        elseif warn == "thickening" then
            table.insert(rows, { string.format(g_i18n:getText("warning_spsSlurryThickening"), pct), 1, 0.8, 0.3 })
        end
    end

    -- Update background height if row count changed
    local numRows = #rows
    if numRows ~= self.NUM_ROWS then
        self.NUM_ROWS = numRows
        self:storeScaledValues()
    end

    -- Draw rows top-down from offsetTop
    local rowPosY = posY - self.offsetTop
    for _, row in ipairs(rows) do
        rowPosY = rowPosY - self.rowHeight
        local clipped = Utils.limitTextToWidth(row[1], self.textSize,
            self.backgroundTop.width - 2 * self.textOffsetX, false, "...")
        setTextColor(row[2], row[3], row[4], 1)
        renderText(posX + self.textOffsetX, rowPosY + self.textOffsetY, self.textSize, clipped)
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)

    return self.backgroundBottom.y
end
