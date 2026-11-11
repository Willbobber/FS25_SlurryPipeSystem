-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.2.0

-- SPSSettingsMenuExtension.lua
-- FS25_SlurryPipeSystem
--
-- [SPS 2026-11-07] ONE place for every SPS setting (William: "all in one place and then split inside that one place
-- for slurry side and fert side and general side"): everything goes into the GENERAL SETTINGS tab (the one tab every
-- player can always see) in four blocks, each under its own section header:
--   SLURRY PIPE SYSTEM - GENERAL      pipe mode, pipe dirt (+ speed), pipe leakage, IBC persists, pipe colour
--   SLURRY PIPE SYSTEM - SLURRY       slurry realism (+ thickness / blockages / falloff), PTO shear bolt
--   SLURRY PIPE SYSTEM - SPREADER HUD the per-player HUD master + its rows
--   SLURRY PIPE SYSTEM - SPRAYERS     chem mixing (+ ratio / rinses / washout station valve)
-- Sub-rows are indented (leading spaces in their l10n title) and greyed while their master is off.
-- The gameplay rows used to live in the GAME SETTINGS tab, which vanilla hides from non-admin players in MP
-- (InGameMenuSettingsFrame:onFrameOpen canChangeGameSettings). They are server-authoritative and synced
-- (SPSSettingsSyncEvent), so SPS greys them ITSELF for a non-admin client (same rule as the game's: single player,
-- the host, or master rights) - everyone sees the live values, only an admin can move them. The per-player rows
-- (pipe colour, HUD) are never greyed.

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSSettingsMenuExtension 1.0.2.0 loaded") end

SPSSettingsMenuExtension = {}

-- the game's own rule (InGameMenuSettingsFrame:onFrameOpen): single player, the host, or master rights
function SPSSettingsMenuExtension.canChangeGameplay(page)
    local isMP = g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer == true
    if not isMP then return true end
    if g_inGameMenu ~= nil and g_inGameMenu.isServer then return true end
    return page ~= nil and page.hasMasterRights == true
end

-- ---------------------------------------------------------------------------
-- onFrameOpen — called once to build UI elements, guarded by initDone flag
-- ---------------------------------------------------------------------------
function SPSSettingsMenuExtension:onFrameOpen()
    SPSSettingsMenuExtension._page = self   -- [SPS 1.0.1.8] the frame, for callbacks that must reset a row
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

    local onOff  = { g_i18n:getText("ui_no"), g_i18n:getText("ui_yes") }
    local layout = self.generalSettingsLayout
    local frame  = self

    local function header(key)
        local el = TextElement.new()
        el.name = "sectionHeader"
        el:loadProfile(g_gui:getProfile("fs25_settingsSectionHeader"), true)
        el:setText(g_i18n:getText(key))
        layout:addElement(el)
        el:onGuiSetupFinished()
    end
    local function row(callback, texts, titleKey, tooltipKey)
        return SPSSettingsMenuExtension:_addMultiTextOption(frame, callback, texts,
            g_i18n:getText(titleKey), g_i18n:getText(tooltipKey), layout)
    end

    -- ------------------------------------------------------------------
    -- GENERAL: the pipes themselves
    -- ------------------------------------------------------------------
    header("sps_settingsSectionGeneral")
    -- [SPS 1.0.1.8] Pipe mode: No = original system (lay / connect / chains; physical pipes hidden in
    -- the shop), Yes = physical pipes only (every original pipe prompt off).
    self.sps_physicalPipesElement = row("onSPSPhysicalPipesChanged", onOff, "sps_settingsPhysicalPipes", "sps_settingsPhysicalPipesTooltip")
    -- [SPS 1.0.2.0] Pipe dirt: on/off + speed multiplier (server-synced like the rest).
    self.sps_hoseDirtElement = row("onSPSHoseDirtChanged", onOff, "sps_settingsHoseDirt", "sps_settingsHoseDirtTooltip")
    self.sps_hoseDirtSpeedValues = { 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0 }
    local dirtSpeedTexts = {}
    for i, v in ipairs(self.sps_hoseDirtSpeedValues) do dirtSpeedTexts[i] = string.format("%gx", v) end
    self.sps_hoseDirtSpeedElement = row("onSPSHoseDirtSpeedChanged", dirtSpeedTexts, "sps_settingsHoseDirtSpeed", "sps_settingsHoseDirtSpeedTooltip")
    -- [SPS 1.0.2.0] Pipe leakage: a physical pipe ending free on the ground can be opened and empties the tanker
    -- onto the ground, leaving a puddle (default off).
    self.sps_spillElement = row("onSPSSpillChanged", onOff, "sps_settingsSpill", "sps_settingsSpillTooltip")
    -- IBC (liquid tank) persistence. Yes = an emptied IBC stays on the map; No = it disappears when emptied (vanilla).
    self.sps_ibcPersistElement = row("onSPSIbcPersistChanged", onOff, "sps_settingsIbcPersist", "sps_settingsIbcPersistTooltip")
    -- Slurry Pipe colour row (per-player: the colour THIS player lays with)
    self.sps_slurryPipeColorElement = row("onSPSSlurryPipeColorChanged", colorTexts, "sps_settingsSlurryPipe", "sps_settingsSlurryPipeTooltip")

    -- ------------------------------------------------------------------
    -- SLURRY: realism and its sub-features, the shear bolt
    -- ------------------------------------------------------------------
    header("sps_settingsSectionSlurry")
    -- Master: Slurry Realism. Off = no thickness, crust, blockages or length falloff.
    self.sps_realismElement = row("onSPSRealismChanged", onOff, "sps_settingsRealism", "sps_settingsRealismTooltip")
    -- Store Thickening and Crust Vegetation are mandatory parts of the master and are intentionally NOT shown.
    self.sps_thicknessFlowElement = row("onSPSThicknessFlowChanged", onOff, "sps_settingsThicknessFlow", "sps_settingsThicknessFlowTooltip")
    self.sps_blockagesElement     = row("onSPSBlockagesChanged",     onOff, "sps_settingsBlockages",     "sps_settingsBlockagesTooltip")
    self.sps_lengthFalloffElement = row("onSPSLengthFalloffChanged", onOff, "sps_settingsLengthFalloff", "sps_settingsLengthFalloffTooltip")
    -- PTO shear bolt master on/off. Independent of the realism master (gated per-vehicle by <shearBolt bolt="true"/>).
    self.sps_shearBoltElement = row("onSPSShearBoltChanged", onOff, "sps_settingsShearBolt", "sps_settingsShearBoltTooltip")

    -- ------------------------------------------------------------------
    -- SPREADER HUD (slurry side, per-player): the master switch, then its rows
    -- ------------------------------------------------------------------
    header("sps_hudSettingsHeader")
    self.sps_hudEnabledElement  = row("onSPSHudEnabledChanged",  onOff, "sps_hudSetEnabled",  "sps_hudSetEnabledTooltip")
    self.sps_hudImageElement    = row("onSPSHudImageChanged",    onOff, "sps_hudSetImage",    "sps_hudSetImageTooltip")
    self.sps_hudFillElement     = row("onSPSHudFillChanged",     onOff, "sps_hudSetFill",     "sps_hudSetFieldTooltip")
    self.sps_hudCrustElement    = row("onSPSHudCrustChanged",    onOff, "sps_hudSetCrust",    "sps_hudSetFieldTooltip")
    self.sps_hudThickElement    = row("onSPSHudThickChanged",    onOff, "sps_hudSetThick",    "sps_hudSetFieldTooltip")
    self.sps_hudRiskElement     = row("onSPSHudRiskChanged",     onOff, "sps_hudSetRisk",     "sps_hudSetFieldTooltip")
    self.sps_hudPumpElement     = row("onSPSHudPumpChanged",     onOff, "sps_hudSetPump",     "sps_hudSetFieldTooltip")
    self.sps_hudHideHelpElement = row("onSPSHudHideHelpChanged", onOff, "sps_hudSetHideHelp", "sps_hudSetHideHelpTooltip")
    self.sps_hudScaleTexts  = { "50%", "75%", "100%", "125%", "150%" }
    self.sps_hudScaleValues = { 0.5, 0.75, 1.0, 1.25, 1.5 }
    self.sps_hudScaleElement = row("onSPSHudScaleChanged", self.sps_hudScaleTexts, "sps_hudSetScale", "sps_hudSetScaleTooltip")

    -- ------------------------------------------------------------------
    -- SPRAYERS: chem mixing and its sub-rows
    -- ------------------------------------------------------------------
    header("sps_settingsSectionSprayers")
    -- [SPS CHEM] Realistic sprayer filling: chemical via the chem bowl, water via the pipe, washouts.
    self.sps_chemMixingElement = row("onSPSChemMixingChanged", onOff, "sps_settingsChemMixing", "sps_settingsChemMixingTooltip")
    -- [SPS CHEM 2026-11-05] Mix ratio: water parts per part of concentrate (greyed while Chem Mixing is off)
    self.sps_chemRatioValues = { 4, 9, 19, 49 }
    local ratioTexts = {}
    for i, v in ipairs(self.sps_chemRatioValues) do ratioTexts[i] = string.format("1:%d", v) end
    self.sps_chemRatioElement = row("onSPSChemRatioChanged", ratioTexts, "sps_settingsChemRatio", "sps_settingsChemRatioTooltip")
    -- [SPS CHEM 2026-11-06] Washout rinses (greyed while Chem Mixing is off)
    self.sps_chemRinsesElement = row("onSPSChemRinsesChanged", { "1", "2", "3" }, "sps_settingsChemRinses", "sps_settingsChemRinsesTooltip")
    -- [SPS CHEM 2026-11-07] Washout station valve: automatic / by hand (greyed while Chem Mixing is off)
    self.sps_washoutValveElement = row("onSPSWashoutValveChanged",
        { g_i18n:getText("sps_settingsWashoutValveAuto"), g_i18n:getText("sps_settingsWashoutValveManual") },
        "sps_settingsWashoutValve", "sps_settingsWashoutValveTooltip")

    layout:invalidateLayout()
    self:updateAlternatingElements(layout)

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
-- _updateState — syncs UI element state to manager state; greys a block's sub-rows while its master is off and
-- every gameplay row for a player who may not change the game's settings.
-- ---------------------------------------------------------------------------
function SPSSettingsMenuExtension:_updateState(page)
    if not page.sps_initDone then return end
    if g_slurryPipeManager == nil then return end
    local mgr = g_slurryPipeManager
    local admin = SPSSettingsMenuExtension.canChangeGameplay(page)
    local ft    = mgr.featureToggles or {}

    -- a gameplay row: value + greyed when not admin, or when its master (if any) is off
    local function set(el, state, masterOn)
        if el == nil then return end
        el:setState(state, false)
        el:setDisabled((not admin) or (masterOn == false))
    end

    -- GENERAL
    set(page.sps_physicalPipesElement, (mgr.physicalPipesEnabled == true) and 2 or 1)
    local dirtOn = mgr.hoseDirtEnabled ~= false
    set(page.sps_hoseDirtElement, dirtOn and 2 or 1)
    if page.sps_hoseDirtSpeedElement ~= nil then
        local vals = page.sps_hoseDirtSpeedValues or { 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0 }
        local cur, idx, best = mgr.hoseDirtSpeed or 1.0, 4, 999
        for i, v in ipairs(vals) do local d = math.abs(v - cur); if d < best then best = d; idx = i end end
        set(page.sps_hoseDirtSpeedElement, idx, dirtOn)
    end
    set(page.sps_spillElement, (mgr.spillEnabled == true) and 2 or 1)
    set(page.sps_ibcPersistElement, (mgr.ibcPersistWhenEmpty == true) and 2 or 1)
    if page.sps_slurryPipeColorElement ~= nil then   -- per-player, never greyed
        page.sps_slurryPipeColorElement:setState(mgr.currentPipeColorIndex, false)
    end

    -- SLURRY
    local master = mgr.realismEnabled == true
    set(page.sps_realismElement, master and 2 or 1)
    set(page.sps_thicknessFlowElement, (ft.thicknessFlow ~= false) and 2 or 1, master)
    set(page.sps_blockagesElement,     (ft.blockages     ~= false) and 2 or 1, master)
    set(page.sps_lengthFalloffElement, (ft.lengthFalloff ~= false) and 2 or 1, master)
    set(page.sps_shearBoltElement, (mgr.shearBoltEnabled ~= false) and 2 or 1)

    -- SPREADER HUD (per-player: never admin-greyed; the rows under the master grey with it)
    local hs = mgr.hudSettings or {}
    local hudOn = hs.enabled ~= false
    local function hud(el, state, underMaster)
        if el == nil then return end
        el:setState(state, false)
        el:setDisabled(underMaster == true and not hudOn)
    end
    hud(page.sps_hudEnabledElement,  hudOn and 2 or 1, false)
    hud(page.sps_hudImageElement,    (hs.image ~= false) and 2 or 1, true)
    hud(page.sps_hudFillElement,     (hs.fill  ~= false) and 2 or 1, true)
    hud(page.sps_hudCrustElement,    (hs.crust ~= false) and 2 or 1, true)
    hud(page.sps_hudThickElement,    (hs.thick ~= false) and 2 or 1, true)
    hud(page.sps_hudRiskElement,     (hs.risk  ~= false) and 2 or 1, true)
    hud(page.sps_hudPumpElement,     (hs.pump  ~= false) and 2 or 1, true)
    hud(page.sps_hudHideHelpElement, (hs.hideWithHelp == true) and 2 or 1, true)
    if page.sps_hudScaleElement ~= nil then
        local vals = page.sps_hudScaleValues or { 0.5, 0.75, 1.0, 1.25, 1.5 }
        local cur, idx, best = hs.scale or 1.0, 3, 999
        for i, v in ipairs(vals) do local d = math.abs(v - cur); if d < best then best = d; idx = i end end
        hud(page.sps_hudScaleElement, idx, true)
    end

    -- SPRAYERS
    local chemOn = ft.chemMixing == true
    set(page.sps_chemMixingElement, chemOn and 2 or 1)
    if page.sps_chemRatioElement ~= nil then
        local vals = page.sps_chemRatioValues or { 4, 9, 19, 49 }
        local idx = 2
        for i, v in ipairs(vals) do if v == tonumber(ft.chemRatio) then idx = i end end
        set(page.sps_chemRatioElement, idx, chemOn)
    end
    set(page.sps_chemRinsesElement, math.clamp(tonumber(ft.chemRinses) or 3, 1, 3), chemOn)
    set(page.sps_washoutValveElement, (ft.washoutValveManual == true) and 2 or 1, chemOn)
end

-- ---------------------------------------------------------------------------
-- Callbacks
-- ---------------------------------------------------------------------------
local function refresh()
    local page = SPSSettingsMenuExtension._page
    if page ~= nil then SPSSettingsMenuExtension:_updateState(page) end
end

function SPSSettingsMenuExtension:onSPSSlurryPipeColorChanged(state)
    if g_slurryPipeManager == nil then
        print("[SPS] SPSSettingsMenuExtension: manager nil, ignoring")
        return
    end
    g_slurryPipeManager:setCurrentPipeColor(state)
    if g_slurryPipeManager.saveUserSettings ~= nil then g_slurryPipeManager:saveUserSettings() end
end

function SPSSettingsMenuExtension:onSPSRealismChanged(state)
    if g_slurryPipeManager == nil then return end
    -- [SPS 1.0.0.9.30] Server-authoritative: apply + MP-sync via the manager.
    g_slurryPipeManager:requestGameplaySettings({ realismEnabled = (state == 2) })
    refresh()   -- re-grey the sub-rows immediately
end

function SPSSettingsMenuExtension:onSPSThicknessFlowChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:requestGameplaySettings({ thicknessFlow = (state == 2) })
end

function SPSSettingsMenuExtension:onSPSBlockagesChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:requestGameplaySettings({ blockages = (state == 2) })
end

function SPSSettingsMenuExtension:onSPSLengthFalloffChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:requestGameplaySettings({ lengthFalloff = (state == 2) })
end

function SPSSettingsMenuExtension:onSPSShearBoltChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:requestGameplaySettings({ shearBoltEnabled = (state == 2) })
end

function SPSSettingsMenuExtension:onSPSIbcPersistChanged(state)
    if g_slurryPipeManager == nil then return end
    -- requestGameplaySettings runs applyIbcPersistSetting inside the apply.
    g_slurryPipeManager:requestGameplaySettings({ ibcPersistWhenEmpty = (state == 2) })
end

function SPSSettingsMenuExtension:onSPSChemMixingChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:requestGameplaySettings({ chemMixing = (state == 2) })
    refresh()
end

-- [SPS CHEM 2026-11-06] washout rinses step
function SPSSettingsMenuExtension:onSPSChemRinsesChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:requestGameplaySettings({ chemRinses = math.clamp(state or 3, 1, 3) })
end

-- [SPS CHEM 2026-11-07] washout station valve: 1 = automatic, 2 = by hand
function SPSSettingsMenuExtension:onSPSWashoutValveChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:requestGameplaySettings({ washoutValveManual = (state == 2) })
end

-- [SPS CHEM 2026-11-05] mix ratio step
function SPSSettingsMenuExtension:onSPSChemRatioChanged(state)
    if g_slurryPipeManager == nil then return end
    local page = SPSSettingsMenuExtension._page
    local vals = (page ~= nil and page.sps_chemRatioValues) or { 4, 9, 19, 49 }
    g_slurryPipeManager:requestGameplaySettings({ chemRatio = vals[state] or 9 })
end

-- [SPS 1.0.2.0] Pipe dirt on/off (+ re-grey the speed row) and speed step
function SPSSettingsMenuExtension:onSPSHoseDirtChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:requestGameplaySettings({ hoseDirtEnabled = (state == 2) })
    refresh()
end

function SPSSettingsMenuExtension:onSPSSpillChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager:requestGameplaySettings({ spillEnabled = (state == 2) })
end

function SPSSettingsMenuExtension:onSPSHoseDirtSpeedChanged(state)
    if g_slurryPipeManager == nil then return end
    local page = SPSSettingsMenuExtension._page
    local vals = (page ~= nil and page.sps_hoseDirtSpeedValues) or { 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0 }
    local v = vals[state] or 1.0
    g_slurryPipeManager:requestGameplaySettings({ hoseDirtSpeed = v })
end

function SPSSettingsMenuExtension:onSPSPhysicalPipesChanged(state)
    local mgr = g_slurryPipeManager
    if mgr == nil then return end
    if state == 2 and mgr.physicalPipesEnabled ~= true and SPSPipeModeDialog ~= nil then
        -- ORIGINAL -> PHYSICAL removes every original pipe: warn first, reset the row if declined.
        SPSPipeModeDialog.confirmSwitchToPhysical(function(ok)
            local page = SPSSettingsMenuExtension._page
            if not ok and page ~= nil and page.sps_physicalPipesElement ~= nil then
                page.sps_physicalPipesElement:setState(1, false)
            end
        end)
        return
    end
    if state == 1 and mgr.physicalPipesEnabled == true and SPSPipeModeDialog ~= nil
       and SPSPipeModeDialog.confirmSwitchToOriginal ~= nil then
        -- [SPS 1.0.1.8] PHYSICAL -> ORIGINAL removes every physical pipe: warn first, reset the row if declined.
        SPSPipeModeDialog.confirmSwitchToOriginal(function(ok)
            local page = SPSSettingsMenuExtension._page
            if not ok and page ~= nil and page.sps_physicalPipesElement ~= nil then
                page.sps_physicalPipesElement:setState(2, false)
            end
        end)
        return
    end
    -- requestGameplaySettings runs applyPhysicalPipesSetting (shop items) inside the apply.
    mgr:requestGameplaySettings({ physicalPipesEnabled = (state == 2) })
end

-- [SPS 1.0.0.9.30] HUD callbacks are per-player: apply locally and persist to
-- the player's own user file. Never synced — every player keeps their own HUD.
local function spsSaveUser()
    if g_slurryPipeManager ~= nil and g_slurryPipeManager.saveUserSettings ~= nil then
        g_slurryPipeManager:saveUserSettings()
    end
end

function SPSSettingsMenuExtension:onSPSHudEnabledChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.enabled = (state == 2)
    spsSaveUser()
    refresh()   -- the master: re-grey the HUD rows immediately
end
function SPSSettingsMenuExtension:onSPSHudImageChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.image = (state == 2)
    spsSaveUser()
end
function SPSSettingsMenuExtension:onSPSHudFillChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.fill = (state == 2)
    spsSaveUser()
end
function SPSSettingsMenuExtension:onSPSHudCrustChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.crust = (state == 2)
    spsSaveUser()
end
function SPSSettingsMenuExtension:onSPSHudThickChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.thick = (state == 2)
    spsSaveUser()
end
function SPSSettingsMenuExtension:onSPSHudRiskChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.risk = (state == 2)
    spsSaveUser()
end
function SPSSettingsMenuExtension:onSPSHudPumpChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.pump = (state == 2)
    spsSaveUser()
end
function SPSSettingsMenuExtension:onSPSHudHideHelpChanged(state)
    if g_slurryPipeManager == nil then return end
    g_slurryPipeManager.hudSettings.hideWithHelp = (state == 2)
    spsSaveUser()
end
function SPSSettingsMenuExtension:onSPSHudScaleChanged(state)
    if g_slurryPipeManager == nil then return end
    local vals = { 0.5, 0.75, 1.0, 1.25, 1.5 }
    g_slurryPipeManager.hudSettings.scale = vals[state] or 1.0
    spsSaveUser()
end

-- ---------------------------------------------------------------------------
-- _addMultiTextOption — creates and attaches a MultiTextOptionElement row
-- Mirrors the ELS helper pattern exactly.
-- ---------------------------------------------------------------------------
function SPSSettingsMenuExtension:_addMultiTextOption(frame, callbackName, texts, title, tooltip, layout)
    -- [SPS 2026-11-07] every SPS row goes into the GENERAL settings layout (one place); the gameSettingsLayout
    -- default is kept for any caller that still passes nothing.
    local targetLayout = layout or frame.generalSettingsLayout or frame.gameSettingsLayout
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

    targetLayout:addElement(container)
    container:onGuiSetupFinished()

    return option
end

-- ---------------------------------------------------------------------------
-- Hook into InGameMenuSettingsFrame
-- ---------------------------------------------------------------------------
local function init()
    InGameMenuSettingsFrame.onFrameOpen    = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen,    SPSSettingsMenuExtension.onFrameOpen)
    InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(InGameMenuSettingsFrame.updateGameSettings, SPSSettingsMenuExtension.updateGameSettings)
    -- [SPS 1.0.0.9.30] Vanilla only calls updateGameSettings inside the
    -- canChangeGameSettings branch of onFrameOpen (admin/host), so on a
    -- non-admin MP client our state refresh would never run. updateGeneralSettings
    -- runs for everyone, so hook it too (same refresh, idempotent).
    if InGameMenuSettingsFrame.updateGeneralSettings ~= nil then
        InGameMenuSettingsFrame.updateGeneralSettings = Utils.appendedFunction(InGameMenuSettingsFrame.updateGeneralSettings, SPSSettingsMenuExtension.updateGameSettings)
    end
end

init()
