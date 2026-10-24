-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSPipeModeDialog.lua
-- [SPS 1.0.1.8] PIPE MODE dialogs (William 2026-10-15). The two pipe systems never run together:
--   ORIGINAL  = lay / connect / chain prompts at couplings, sprayers and water/milk lanes; the bought
--               physical pipes are hidden in the shop.
--   PHYSICAL  = bought pipes only; every original prompt is off.
-- 1. Start-up choice: the first time a game is started with the mod (pipeModeChosen == false in the
--    per-game save file) the host is asked which system to use. Answered once per savegame; the
--    settings menu row "Physical Pipes" changes it later.
-- 2. Switch-to-physical warning: whenever the mode goes ORIGINAL -> PHYSICAL (start-up choice,
--    settings row) the player is told that EVERY original pipe in this game is removed and the
--    original connection system is switched off, even mid-game, and must confirm. The removal
--    itself runs on the server inside SlurryPipeManager:applyGameplaySettings (removeAllOriginalPipes),
--    so the console command and a client's request remove them too.
-- 3. Switch-to-original warning (William 2026-10-20): the mirror - PHYSICAL -> ORIGINAL REMOVES every
--    physical pipe in this game (removeAllPhysicalPipes on the server, same place) and must be confirmed.
-- Only the host asks (g_server ~= nil): the setting is server-authoritative and a dedicated server
-- has no GUI (it stays ORIGINAL until an admin flips the settings row).
-- Engine facts: YesNoDialog.show(callback, target, text, title, yesText, noText, ...) calls
-- callback(value, args) when target is nil (YesNoDialog.lua:8, :85-94); BaseMission.isMissionStarted
-- (BaseMission.lua:249); g_gui:getIsGuiVisible() (BaseMission.lua:892).

SPSPipeModeDialog = {}
SPSPipeModeDialog.START_DELAY_MS = 2500   -- after the mission started and no menu is open

SPSPipeModeDialog._timer = 0
SPSPipeModeDialog._done  = false

function SPSPipeModeDialog.reset()
    SPSPipeModeDialog._timer = 0
    SPSPipeModeDialog._done  = false
end

-- Called every frame from SPSMod:update. Shows the start-up choice once, when due.
function SPSPipeModeDialog.update(dt)
    if SPSPipeModeDialog._done then return end
    local mgr = g_slurryPipeManager
    if mgr == nil or g_currentMission == nil or not g_currentMission.isMissionStarted then return end
    if g_server == nil or g_dedicatedServer ~= nil then
        SPSPipeModeDialog._done = true      -- clients never ask; a dedicated server has no screen
        return
    end
    if mgr.pipeModeChosen == true then
        SPSPipeModeDialog._done = true
        return
    end
    if g_gui ~= nil and g_gui:getIsGuiVisible() then return end   -- loading screen / menu still up
    SPSPipeModeDialog._timer = SPSPipeModeDialog._timer + (dt or 0)
    if SPSPipeModeDialog._timer < SPSPipeModeDialog.START_DELAY_MS then return end
    SPSPipeModeDialog._done = true
    SPSPipeModeDialog.showStartupChoice()
end

function SPSPipeModeDialog.countsText(chains, coupl, spr, lane)
    return string.format(g_i18n:getText("sps_pipeModeCounts"), chains, coupl, spr, lane)
end

function SPSPipeModeDialog.showStartupChoice()
    local mgr = g_slurryPipeManager
    if mgr == nil or YesNoDialog == nil then return end
    local chains, coupl, spr, lane = mgr:countOriginalPipes()
    local text = g_i18n:getText("sps_pipeModeQuestion")
    if chains + coupl + spr + lane > 0 then
        text = text .. "\n\n" .. string.format(g_i18n:getText("sps_pipeModeExisting"),
            SPSPipeModeDialog.countsText(chains, coupl, spr, lane))
    end
    print("[SPS] pipe mode: asking the host which pipe system to use (first start of this game)")
    YesNoDialog.show(SPSPipeModeDialog.onStartupChoice, nil, text, g_i18n:getText("sps_pipeModeTitle"),
        g_i18n:getText("sps_pipeModeBtnPhysical"), g_i18n:getText("sps_pipeModeBtnOriginal"))
end

function SPSPipeModeDialog.onStartupChoice(yes)
    local mgr = g_slurryPipeManager
    if mgr == nil then return end
    if yes then
        SPSPipeModeDialog.confirmSwitchToPhysical(function(ok)
            if not ok then
                -- Declined the warning: stay on the original system, remembered for this game.
                mgr:requestGameplaySettings({ physicalPipesEnabled = false })
            end
        end)
    else
        mgr:requestGameplaySettings({ physicalPipesEnabled = false })
    end
end

-- Warn, then on confirmation switch to PHYSICAL (the server removes every original pipe inside the
-- apply). onDone(ok) is called either way so a settings row can reset itself when declined.
function SPSPipeModeDialog.confirmSwitchToPhysical(onDone)
    local mgr = g_slurryPipeManager
    if mgr == nil or YesNoDialog == nil then
        if onDone ~= nil then onDone(false) end
        return
    end
    local chains, coupl, spr, lane = mgr:countOriginalPipes()
    local text = string.format(g_i18n:getText("sps_pipeModeWarnText"),
        SPSPipeModeDialog.countsText(chains, coupl, spr, lane))
    YesNoDialog.show(function(yes)
        if yes then
            mgr:requestGameplaySettings({ physicalPipesEnabled = true })
        end
        if onDone ~= nil then onDone(yes == true) end
    end, nil, text, g_i18n:getText("sps_pipeModeWarnTitle"),
        g_i18n:getText("sps_pipeModeBtnSwitch"), g_i18n:getText("sps_pipeModeBtnKeep"),
        DialogElement.TYPE_WARNING)
end

-- [SPS 1.0.1.8] Warn, then on confirmation switch to ORIGINAL (the server deletes every physical pipe inside the
-- apply - removeAllPhysicalPipes). onDone(ok) is called either way so the settings row can reset itself.
function SPSPipeModeDialog.confirmSwitchToOriginal(onDone)
    local mgr = g_slurryPipeManager
    if mgr == nil or YesNoDialog == nil or mgr.countPhysicalPipes == nil then
        if onDone ~= nil then onDone(false) end
        return
    end
    local nPipes, nPlugged, nStowed, nStations = mgr:countPhysicalPipes()
    local text = string.format(g_i18n:getText("sps_pipeModeWarnOrigText"),
        string.format(g_i18n:getText("sps_pipeModePhysCounts"), nPipes, nPlugged, nStowed, nStations))
    YesNoDialog.show(function(yes)
        if yes then
            mgr:requestGameplaySettings({ physicalPipesEnabled = false })
        end
        if onDone ~= nil then onDone(yes == true) end
    end, nil, text, g_i18n:getText("sps_pipeModeWarnOrigTitle"),
        g_i18n:getText("sps_pipeModeBtnSwitch"), g_i18n:getText("sps_pipeModeBtnKeepPhysical"),
        DialogElement.TYPE_WARNING)
end
