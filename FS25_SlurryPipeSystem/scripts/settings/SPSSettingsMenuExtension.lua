-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.4

-- SPSSettingsMenuExtension.lua
-- FS25_SlurryPipeSystem

SPSSettingsMenuExtension = {}

-- ---------------------------------------------------------------------------
-- onFrameOpen — called once to build UI elements, guarded by initDone flag
-- ---------------------------------------------------------------------------
function SPSSettingsMenuExtension:onFrameOpen()
    if self.sps_initDone then
        return
    end

    -- Build colour name list from manager
    local colorTexts = {}
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.pipeColors ~= nil then
        for _, entry in ipairs(g_slurryPipeManager.pipeColors) do
            table.insert(colorTexts, entry.name)
        end
    end

    if #colorTexts == 0 then
        print("[SPS] SPSSettingsMenuExtension: no colours loaded — deferring")
        return
    end

    local onOff = { g_i18n:getText("ui_no"), g_i18n:getText("ui_yes") }

    -- Section header
    local headerEl = TextElement.new()
    headerEl.name = "sectionHeader"
    headerEl:loadProfile(g_gui:getProfile("fs25_settingsSectionHeader"), true)
    headerEl:setText(g_i18n:getText("sps_settingsHeader"))
    self.gameSettingsLayout:addElement(headerEl)
    headerEl:onGuiSetupFinished()

    -- Slurry Pipe colour row
    self.sps_slurryPipeColorElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self,
        "onSPSSlurryPipeColorChanged",
        colorTexts,
        g_i18n:getText("sps_settingsSlurryPipe"),
        g_i18n:getText("sps_settingsSlurryPipeTooltip")
    )

    -- Master: Slurry Realism. Off = no thickness, crust, blockages or length falloff.
    self.sps_realismElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self,
        "onSPSRealismChanged",
        onOff,
        g_i18n:getText("sps_settingsRealism"),
        g_i18n:getText("sps_settingsRealismTooltip")
    )

    -- Store Thickening and Crust Vegetation are mandatory parts of the master and
    -- are intentionally NOT shown — they have no independent switch, so listing them
    -- would only add greyed clutter. They ride the realism master directly.

    -- Optional sub-features.
    self.sps_thicknessFlowElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self,
        "onSPSThicknessFlowChanged",
        onOff,
        g_i18n:getText("sps_settingsThicknessFlow"),
        g_i18n:getText("sps_settingsThicknessFlowTooltip")
    )
    self.sps_blockagesElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self,
        "onSPSBlockagesChanged",
        onOff,
        g_i18n:getText("sps_settingsBlockages"),
        g_i18n:getText("sps_settingsBlockagesTooltip")
    )
    self.sps_lengthFalloffElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self,
        "onSPSLengthFalloffChanged",
        onOff,
        g_i18n:getText("sps_settingsLengthFalloff"),
        g_i18n:getText("sps_settingsLengthFalloffTooltip")
    )

    -- PTO shear bolt master on/off. Independent of the realism master (it is gated
    -- per-vehicle by the <shearBolt bolt="true"/> tag, not by realism).
    self.sps_shearBoltElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self,
        "onSPSShearBoltChanged",
        onOff,
        g_i18n:getText("sps_settingsShearBolt"),
        g_i18n:getText("sps_settingsShearBoltTooltip")
    )

    -- Spreader HUD section
    local hudHeader = TextElement.new()
    hudHeader.name = "sectionHeader"
    hudHeader:loadProfile(g_gui:getProfile("fs25_settingsSectionHeader"), true)
    hudHeader:setText(g_i18n:getText("sps_hudSettingsHeader"))
    self.gameSettingsLayout:addElement(hudHeader)
    hudHeader:onGuiSetupFinished()

    self.sps_hudEnabledElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self, "onSPSHudEnabledChanged", onOff,
        g_i18n:getText("sps_hudSetEnabled"), g_i18n:getText("sps_hudSetEnabledTooltip"))
    self.sps_hudImageElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self, "onSPSHudImageChanged", onOff,
        g_i18n:getText("sps_hudSetImage"), g_i18n:getText("sps_hudSetImageTooltip"))
    self.sps_hudFillElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self, "onSPSHudFillChanged", onOff,
        g_i18n:getText("sps_hudSetFill"), g_i18n:getText("sps_hudSetFieldTooltip"))
    self.sps_hudCrustElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self, "onSPSHudCrustChanged", onOff,
        g_i18n:getText("sps_hudSetCrust"), g_i18n:getText("sps_hudSetFieldTooltip"))
    self.sps_hudThickElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self, "onSPSHudThickChanged", onOff,
        g_i18n:getText("sps_hudSetThick"), g_i18n:getText("sps_hudSetFieldTooltip"))
    self.sps_hudRiskElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self, "onSPSHudRiskChanged", onOff,
        g_i18n:getText("sps_hudSetRisk"), g_i18n:getText("sps_hudSetFieldTooltip"))
    self.sps_hudPumpElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self, "onSPSHudPumpChanged", onOff,
        g_i18n:getText("sps_hudSetPump"), g_i18n:getText("sps_hudSetFieldTooltip"))

    self.sps_hudScaleTexts  = { "50%", "75%", "100%", "125%", "150%" }
    self.sps_hudScaleValues = { 0.5, 0.75, 1.0, 1.25, 1.5 }
    self.sps_hudScaleElement = SPSSettingsMenuExtension:_addMultiTextOption(
        self, "onSPSHudScaleChanged", self.sps_hudScaleTexts,
        g_i18n:getText("sps_hudSetScale"), g_i18n:getText("sps_hudSetScaleTooltip"))

    self.gameSettingsLayout:invalidateLayout()
    self:updateAlternatingElements(self.gameSettingsLayout)

    self.sps_initDone = true
    SPSSettingsMenuExtension:_updateState(self)
end

-- ---------------------------------------------------------------------------
-- updateGameSettings — called whenever the settings page refreshes
-- ---------------------------------------------------------------------------
function SPSSettingsMenuExtension:updateGameSettings()
    SPSSettingsMenuExtension:_updateState(self)
end

-- ---------------------------------------------------------------------------
-- _updateState — syncs UI element state to manager state, and greys the
-- sub-options when the realism master is off.
-- ---------------------------------------------------------------------------
function SPSSettingsMenuExtension:_updateState(page)
    if not page.sps_initDone then return end
    if g_slurryPipeManager == nil then return end
    local mgr = g_slurryPipeManager

    if page.sps_slurryPipeColorElement ~= nil then
        page.sps_slurryPipeColorElement:setState(mgr.currentPipeColorIndex, false)
    end

    local master = mgr.realismEnabled == true
    local ft     = mgr.featureToggles or {}

    if page.sps_realismElement ~= nil then
        page.sps_realismElement:setState(master and 2 or 1, false)
    end

    -- Optional: reflect stored value, enabled only while master is on.
    if page.sps_thicknessFlowElement ~= nil then
        page.sps_thicknessFlowElement:setState((ft.thicknessFlow ~= false) and 2 or 1, false)
        page.sps_thicknessFlowElement:setDisabled(not master)
    end
    if page.sps_blockagesElement ~= nil then
        page.sps_blockagesElement:setState((ft.blockages ~= false) and 2 or 1, false)
        page.sps_blockagesElement:setDisabled(not master)
    end
    if page.sps_lengthFalloffElement ~= nil then
        page.sps_lengthFalloffElement:setState((ft.lengthFalloff ~= false) and 2 or 1, false)
        page.sps_lengthFalloffElement:setDisabled(not master)
    end

    -- Shear bolt master — not tied to the realism master, so never greyed by it.
    if page.sps_shearBoltElement ~= nil then
        page.sps_shearBoltElement:setState((mgr.shearBoltEnabled ~= false) and 2 or 1, false)
    end

    local hs = mgr.hudSettings or {}
    local hudOn = hs.enabled ~= false
    if page.sps_hudEnabledElement ~= nil then page.sps_hudEnabledElement:setState(hudOn and 2 or 1, false) end
    if page.sps_hudImageElement ~= nil then page.sps_hudImageElement:setState((hs.image ~= false) and 2 or 1, false); page.sps_hudImageElement:setDisabled(not hudOn) end
    if page.sps_hudFillElement  ~= nil then page.sps_hudFillElement:setState((hs.fill ~= false) and 2 or 1, false);  page.sps_hudFillElement:setDisabled(not hudOn) end
    if page.sps_hudCrustElement ~= nil then page.sps_hudCrustElement:setState((hs.crust ~= false) and 2 or 1, false); page.sps_hudCrustElement:setDisabled(not hudOn) end
    if page.sps_hudThickElement ~= nil then page.sps_hudThickElement:setState((hs.thick ~= false) and 2 or 1, false); page.sps_hudThickElement:setDisabled(not hudOn) end
    if page.sps_hudRiskElement  ~= nil then page.sps_hudRiskElement:setState((hs.risk ~= false) and 2 or 1, false);  page.sps_hudRiskElement:setDisabled(not hudOn) end
    if page.sps_hudPumpElement  ~= nil then page.sps_hudPumpElement:setState((hs.pump ~= false) and 2 or 1, false);  page.sps_hudPumpElement:setDisabled(not hudOn) end
    if page.sps_hudScaleElement ~= nil then
        local vals = page.sps_hudScaleValues or { 0.5, 0.75, 1.0, 1.25, 1.5 }
        local cur, idx, best = hs.scale or 1.0, 3, 999
        for i, v in ipairs(vals) do local d = math.abs(v - cur); if d < best then best = d; idx = i end end
        page.sps_hudScaleElement:setState(idx, false)
        page.sps_hudScaleElement:setDisabled(not hudOn)
    end
end

-- ---------------------------------------------------------------------------
-- Callbacks
-- ---------------------------------------------------------------------------
function SPSSettingsMenuExtension:onSPSSlurryPipeColorChanged(state)
    if g_slurryPipeManager == nil then
        print("[SPS] SPSSettingsMenuExtension: manager nil, ignoring")
        return
    end
    g_slurryPipeManager:setCurrentPipeColor(state)
end

function SPSSettingsMenuExtension:onSPSRealismChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.realismEnabled = (state == 2)
    -- Re-grey the sub-rows immediately.
    SPSSettingsMenuExtension:_updateState(self)
end

function SPSSettingsMenuExtension:onSPSThicknessFlowChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.featureToggles.thicknessFlow = (state == 2)
end

function SPSSettingsMenuExtension:onSPSBlockagesChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.featureToggles.blockages = (state == 2)
end

function SPSSettingsMenuExtension:onSPSLengthFalloffChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.featureToggles.lengthFalloff = (state == 2)
end

function SPSSettingsMenuExtension:onSPSShearBoltChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.shearBoltEnabled = (state == 2)
end

function SPSSettingsMenuExtension:onSPSHudEnabledChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.enabled = (state == 2)
end
function SPSSettingsMenuExtension:onSPSHudImageChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.image = (state == 2)
end
function SPSSettingsMenuExtension:onSPSHudFillChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.fill = (state == 2)
end
function SPSSettingsMenuExtension:onSPSHudCrustChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.crust = (state == 2)
end
function SPSSettingsMenuExtension:onSPSHudThickChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.thick = (state == 2)
end
function SPSSettingsMenuExtension:onSPSHudRiskChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.risk = (state == 2)
end
function SPSSettingsMenuExtension:onSPSHudPumpChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.pump = (state == 2)
end
function SPSSettingsMenuExtension:onSPSHudScaleChanged(state)
    if g_slurryPipeManager == nil then return end
    local vals = { 0.5, 0.75, 1.0, 1.25, 1.5 }
    g_slurryPipeManager.hudSettings.scale = vals[state] or 1.0
end

-- ---------------------------------------------------------------------------
-- _addMultiTextOption — creates and attaches a MultiTextOptionElement row
-- Mirrors the ELS helper pattern exactly.
-- ---------------------------------------------------------------------------
function SPSSettingsMenuExtension:_addMultiTextOption(frame, callbackName, texts, title, tooltip)
    local container = BitmapElement.new()
    container:loadProfile(g_gui:getProfile("fs25_multiTextOptionContainer"), true)

    local option = MultiTextOptionElement.new()
    option:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOption"), true)
    option.target = SPSSettingsMenuExtension
    option:setCallback("onClickCallback", callbackName)
    option:setTexts(texts)

    local titleEl = TextElement.new()
    titleEl:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOptionTitle"), true)
    titleEl:setText(title)

    local tooltipEl = TextElement.new()
    tooltipEl.name = "ignore"
    tooltipEl:loadProfile(g_gui:getProfile("fs25_multiTextOptionTooltip"), true)
    tooltipEl:setText(tooltip)

    option:addElement(tooltipEl)
    container:addElement(option)
    container:addElement(titleEl)

    option:onGuiSetupFinished()
    titleEl:onGuiSetupFinished()
    tooltipEl:onGuiSetupFinished()

    frame.gameSettingsLayout:addElement(container)
    container:onGuiSetupFinished()

    return option
end

-- ---------------------------------------------------------------------------
-- Hook into InGameMenuSettingsFrame
-- ---------------------------------------------------------------------------
local function init()
    InGameMenuSettingsFrame.onFrameOpen    = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen,    SPSSettingsMenuExtension.onFrameOpen)
    InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(InGameMenuSettingsFrame.updateGameSettings, SPSSettingsMenuExtension.updateGameSettings)
end

init()