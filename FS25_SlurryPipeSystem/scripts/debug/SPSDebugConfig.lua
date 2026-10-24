-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.10.4

-- SPSDebugConfig.lua
-- FS25_SlurryPipeSystem
--
-- ---------------------------------------------------------------------------
-- CENTRAL DEBUG REGISTRY — the ONE place all SPS debug switches live.
--
-- This file MUST be the FIRST sourceFile in modDesc <extraSourceFiles> so the
-- registry exists before any other SPS script loads.
--
-- How it works:
--   * Every script file has a named channel in SPSDebugConfig.channels below.
--     true = that file's trace logging is on, false = silent.
--   * Files whose debug switch is a class field (e.g. SPSPipeChain.DEBUG) are
--     driven by SPSDebugConfig.applyAll(), which pushes each channel value into
--     the matching class field. applyAll() is called once from init.lua after
--     all scripts have loaded, and again after every console toggle.
--   * Files whose logging was rewired in Phase 1 (the sprayer files and the
--     init.lua do-blocks) consult SPSDebugConfig.isOn("<channel>") at call
--     time, so toggles take effect instantly with no reload.
--   * Channels marked RESERVED belong to files not yet wired to the registry;
--     they are listed now so the full file map exists in one place. They gain
--     effect as each file is wired during the core/domain split.
--
-- Release discipline: ship this file with EVERY channel false. That is the
-- whole release/test difference — no other file needs touching.
--
-- In-game console (optional, never required):
--   spsDebug                     -> list all channels and their state
--   spsDebug <channel> on|off    -> toggle one channel
--   spsDebug all on|off          -> toggle everything
--   Toggles are SAVED to modSettings/FS25_SlurryPipeSystem/spsDebugChannels.xml
--   and restored on the next load (1.0.1.8), so a channel can trace the load itself.
-- ---------------------------------------------------------------------------

SPSDebugConfig = {}

SPSDebugConfig.channels = {
    -- ------------------------------------------------------------- manager
    ["SlurryPipeManager"]              = false, -- [SPS PM] main manager trace
    ["SlurryPipeManager.MP"]           = false, -- [SPS MP]/[SPS MP RX] multiplayer trace
    ["SlurryPipeManager.SprayerTrace"] = false, -- [SPS SPRAY] sprayer fill/turn-on path (manager side)

    -- ------------------------------------------- manager domain modules
    ["SPSM_Chains"]                    = false, -- RESERVED (module logs via SlurryPipeManager channels for now)
    ["SPSM_Couplers"]                  = false, -- RESERVED
    ["SPSM_Flow"]                      = false, -- RESERVED
    ["SPSBootDeform"]                  = false, -- [SPS BOOT] skinned boot lock / release on the arm tip
    ["SPSM_Pressure"]                  = false, -- RESERVED
    ["SPSM_Consistency"]               = false, -- RESERVED
    ["SPSM_Stores"]                    = false, -- [SPS STORES] slurryStore parse / plane drive / MP trace
    ["SPSWaterCourses"]                = false, -- [SPS WC] player-drawn water courses: file load/save, registration
    ["SPSM_Spreader"]                  = false, -- RESERVED
    ["SPSM_Sprayers"]                  = false, -- RESERVED
    ["SPSM_Sprayers.FrontTank"]        = false, -- [SPS FT-BAL] front/rear tank combo link + FlowControl balancer trace
    ["SPSM_IBC"]                       = false, -- RESERVED

    -- ----------------------------------------------------------- overrides
    ["ManureBarrelOverride.SprayerTrace"] = false, -- [SPS SPRAY] override-side sprayer trace
    ["ManureBarrelOverride"]           = false, -- RESERVED (not yet wired)
    ["PlaceableOverride"]              = false, -- RESERVED (not yet wired)

    -- ---------------------------------------------------------------- init
    ["Init.SprayerTrace"]              = false, -- [SPS SPRAY] action-event register trace
    ["Init.IbcRedirect"]               = false, -- [SPS IBC] i3d redirect prints
    ["Init.LoadTrigger"]               = false, -- [SPS LT]/[SPS FT] load/fill trigger block trace
    ["Init.Keys"]                      = false, -- [SPS KEYS] SPS cab-control registration passes + who removes an SPS_ key event (callstack)

    -- ------------------------------------------------------- chains & pipes
    ["SPSChainActivatable"]            = false, -- [SPS SPCA]
    ["SPSPipeChain"]                   = false, -- [SPS PC]
    ["SPSPipeVisual"]                  = false, -- RESERVED (not yet wired)
    ["SPSHoseVisual"]                  = false, -- [SPS HOSE] new physical hoses (proof build, 1.0.1.8)
    ["SPSPipeActivatable"]             = false, -- RESERVED (not yet wired)
    ["SPSCouplerAnimator"]             = false, -- RESERVED (not yet wired)
    ["SPSOutsideControlActivatable"]   = false, -- RESERVED (not yet wired)
    ["SPSPumpControlActivatable"]      = false, -- RESERVED (not yet wired)

    -- --------------------------------------------------------------- events
    ["SPSEvents"]                      = false, -- RESERVED (not yet wired)

    -- ------------------------------------------------------------- sprayers
    ["SPSSprayerEvents"]               = false, -- [SPS SPR EVT]
    ["SPSSprayerPipeActivatable"]      = false, -- [SPS SPR ACT] (class currently dormant)
    ["SPSSprayerPipeVisual"]           = false, -- [SPS SSPV]
    ["SPSSprayerPumpControl"]          = false, -- [SPS SPR CTRL]
    ["SPSSprayerTankSwitch"]           = false, -- [SPS TANK SW] multi-tank coupler walk-up switch (1.0.1.8)

    -- ------------------------------------------------------------ agitators
    ["SPSFixedAgitator"]               = false, -- agitator trace
    ["SPSFixedAgitatorShaft"]          = false, -- agitator shaft trace
    ["SPSFixedAgitatorActivatable"]    = false, -- RESERVED (not yet wired)
    ["SPSFixedAgitatorEvent"]          = false, -- RESERVED (not yet wired)
    ["SlurryAgitator"]                 = false, -- RESERVED (not yet wired)
    ["SlurryAgitatorEvent"]            = false, -- RESERVED (not yet wired)

    -- ------------------------------------------------------------ front mount
    ["SPSM_FrontMount"]                = false, -- [SPS FM] front-mount receiver resolution trace

    -- ------------------------------------------------------------ separator
    ["SPSSeparator"]                   = false, -- [SPS SEPARATOR] core trace
    ["SPSSeparatorActivatable"]        = false, -- [SPS SEP ACT] walk-up control trace
    ["SPSSeparatorEvent"]              = false, -- [SPS SEP EVT] MP event trace
    ["SPSSlurryTankExtensions"]        = false, -- [SPS TANK EXT] slurry tank extension disabling
    ["SPSChainBondPersistence"]        = false, -- [SPS BOND SAVE] non-vehicle bond save trace

    -- ------------------------------------------- farm liquid lanes (water / milk)
    ["SPSM_LiquidLanes"]               = false, -- [SPS LL] register / connect / flow trace
    ["SPSLiquidLaneControl"]           = false, -- [SPS LL CTRL] walk-up control trace
    ["SPSLiquidLaneEvent"]             = false, -- [SPS LL EVT] MP event trace
    ["SPSM_Preview"]                   = false, -- [SPS PREVIEW] build-menu preview dressing

    -- --------------------------------------------------------- buying station
    ["SPSBuyStationActivatable"]       = false, -- [SPS BUY ACT] type-switch walk-up trace
    ["SPSBuyStationEvent"]             = false, -- [SPS BUY EVT] MP event trace

    -- ------------------------------------------------------------ shear bolt
    ["SPSShearBolt"]                   = false, -- shear bolt wear trace
    ["SPSShearBoltActivatable"]        = false, -- RESERVED (not yet wired)
    ["SPSShearBoltEvent"]              = false, -- RESERVED (not yet wired)

    -- --------------------------------------------------------- blockage/HUD
    ["SPSBlockageActivatable"]         = false, -- RESERVED (not yet wired)
    ["SPSBlockageEvent"]               = false, -- RESERVED (not yet wired)
    ["SPSSpreaderHUD"]                 = false, -- RESERVED (not yet wired)
    ["SPSConduitHUDExtension"]         = false, -- RESERVED (not yet wired)
    ["SPSSettingsMenuExtension"]       = false, -- RESERVED (not yet wired)

    -- ----------------------------------------------------------------- misc
    ["SlurryDebug"]                    = false, -- world-space debug markers (SlurryDebug.enabled)
    ["SlurryNodeUtil"]                 = false, -- RESERVED (not yet wired)
    ["SlurryTractorCapability"]        = false, -- RESERVED (not yet wired)
    ["SPSCrustVegetation"]             = false, -- RESERVED (not yet wired)
    ["SPSWaterPlaneManager"]           = false, -- RESERVED (not yet wired)
    ["Build"]                          = false, -- per-file "[SPS BUILD] X loaded" lines at script load
    ["Info"]                           = false, -- routine "it worked" lines (holders, node trees, lanes, pipe grab/drop, hooks)
}

-- Channel query used by call-time gated log helpers.
-- Safe to call with any string; unknown channels read as off.
function SPSDebugConfig.isOn(channel)
    return SPSDebugConfig.channels[channel] == true
end

-- [SPS 1.0.1.8] Routine "it worked" lines (registration, pipe grab / drop / stow, hook installed, hose reach ...) go
-- through spsInfo, so a normal log carries only warnings / errors and the one-off status lines. spsDebug Info on.
function spsInfoOn()
    return SPSDebugConfig ~= nil and SPSDebugConfig.channels ~= nil and SPSDebugConfig.channels["Info"] == true
end
function spsInfo(...)
    if spsInfoOn() then print(...) end
end

-- Gated print helper for files wired at call time.
-- Usage: SPSDebugConfig.log("SPSSprayerEvents", "[SPS SPR EVT] fmt %s", value)
function SPSDebugConfig.log(channel, fmt, ...)
    if SPSDebugConfig.channels[channel] ~= true then return end
    if select("#", ...) > 0 then
        print(string.format(fmt, ...))
    else
        print(tostring(fmt))
    end
end

-- ---------------------------------------------------------------------------
-- applyAll — push channel values into the class-field switches that pre-date
-- the registry. Every target is nil-guarded: this runs safely even if a script
-- failed to load or applyAll is called before init.lua finishes.
-- ---------------------------------------------------------------------------
function SPSDebugConfig.applyAll()
    local ch = SPSDebugConfig.channels

    if SlurryPipeManager ~= nil then
        SlurryPipeManager.DEBUG         = ch["SlurryPipeManager"] == true
        SlurryPipeManager.MP_DEBUG      = ch["SlurryPipeManager.MP"] == true
        SlurryPipeManager.SPRAYER_TRACE = ch["SlurryPipeManager.SprayerTrace"] == true
    end
    if SlurryPipeSystemOverride ~= nil then
        SlurryPipeSystemOverride.SPRAYER_TRACE = ch["ManureBarrelOverride.SprayerTrace"] == true
    end
    if SPSChainActivatable ~= nil then
        SPSChainActivatable.DEBUG = ch["SPSChainActivatable"] == true
    end
    if SPSPipeChain ~= nil then
        SPSPipeChain.DEBUG = ch["SPSPipeChain"] == true
    end
    if SPSShearBolt ~= nil then
        SPSShearBolt.DEBUG = ch["SPSShearBolt"] == true
    end
    if SPSFixedAgitator ~= nil then
        SPSFixedAgitator.DEBUG = ch["SPSFixedAgitator"] == true
    end
    if SPSFixedAgitatorShaft ~= nil then
        SPSFixedAgitatorShaft.DEBUG = ch["SPSFixedAgitatorShaft"] == true
    end
    if SPSSeparator ~= nil then
        SPSSeparator.DEBUG = ch["SPSSeparator"] == true
    end
    if SPSSeparatorActivatable ~= nil then
        SPSSeparatorActivatable.DEBUG = ch["SPSSeparatorActivatable"] == true
    end
    if SPSSeparatorEvent ~= nil then
        SPSSeparatorEvent.DEBUG = ch["SPSSeparatorEvent"] == true
    end
    if SPSSlurryTankExtensions ~= nil then
        SPSSlurryTankExtensions.DEBUG = ch["SPSSlurryTankExtensions"] == true
    end
    if SPSChainBondPersistence ~= nil then
        SPSChainBondPersistence.DEBUG = ch["SPSChainBondPersistence"] == true
    end
    if SPSBuyStationActivatable ~= nil then
        SPSBuyStationActivatable.DEBUG = ch["SPSBuyStationActivatable"] == true
    end
    if SPSBuyStationEvent ~= nil then
        SPSBuyStationEvent.DEBUG = ch["SPSBuyStationEvent"] == true
    end
    if SPSM_Stores ~= nil then
        SPSM_Stores.DEBUG = ch["SPSM_Stores"] == true
    end
    if SlurryDebug ~= nil then
        SlurryDebug.enabled = ch["SlurryDebug"] == true
    end
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.1.8] Persistence. A console toggle now survives a reload: the ON
-- channels are written to
--   <My Games/FarmingSimulator2025>/modSettings/FS25_SlurryPipeSystem/spsDebugChannels.xml
-- after every `spsDebug` toggle and read back when this file loads (first
-- sourceFile, so before any other SPS script runs). Needed because mod scripts
-- only load with a savegame — nothing that happens DURING load (the savegame
-- enter pass, the first key registrations) could be traced before. The file
-- lives outside the mod folder, so a release build is unaffected; delete the
-- file or run `spsDebug all off` to go quiet. APIs: getUserProfileAppPath /
-- createFolder (AIDebugDump.lua:3/44), XMLFile.create/load/iterate
-- (XMLFile.lua:4/18/187).
-- ---------------------------------------------------------------------------
SPSDebugConfig.SETTINGS_DIR  = nil
SPSDebugConfig.SETTINGS_FILE = nil
if getUserProfileAppPath ~= nil then
    SPSDebugConfig.SETTINGS_DIR  = getUserProfileAppPath() .. "modSettings/FS25_SlurryPipeSystem/"
    SPSDebugConfig.SETTINGS_FILE = SPSDebugConfig.SETTINGS_DIR .. "spsDebugChannels.xml"
end

function SPSDebugConfig.save()
    if SPSDebugConfig.SETTINGS_FILE == nil or XMLFile == nil then return end
    if createFolder ~= nil then createFolder(SPSDebugConfig.SETTINGS_DIR) end
    local xml = XMLFile.create("spsDebugChannels", SPSDebugConfig.SETTINGS_FILE, "spsDebugChannels")
    if xml == nil then return end
    local keys = {}
    for k, v in pairs(SPSDebugConfig.channels) do
        if v == true then table.insert(keys, k) end
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local key = string.format("spsDebugChannels.channel(%d)", i - 1)
        xml:setString(key .. "#name", k)
        xml:setBool(key .. "#on", true)
    end
    xml:save(false, true)
    xml:delete()
end

function SPSDebugConfig.loadSaved()
    if SPSDebugConfig.SETTINGS_FILE == nil or XMLFile == nil or fileExists == nil then return end
    if not fileExists(SPSDebugConfig.SETTINGS_FILE) then return end
    local xml = XMLFile.load("spsDebugChannels", SPSDebugConfig.SETTINGS_FILE)
    if xml == nil then return end
    local ch = SPSDebugConfig.channels
    local restored = {}
    xml:iterate("spsDebugChannels.channel", function(_, key)
        local name = xml:getString(key .. "#name")
        if name ~= nil and ch[name] ~= nil and xml:getBool(key .. "#on", false) == true then
            ch[name] = true
            table.insert(restored, name)
        end
    end)
    xml:delete()
    if #restored > 0 then
        print(string.format("[SPS DBG] restored ON channels from %s: %s",
            SPSDebugConfig.SETTINGS_FILE, table.concat(restored, ", ")))
    end
end

SPSDebugConfig.loadSaved()

-- ---------------------------------------------------------------------------
-- Console command (optional). Same registration pattern as the existing
-- spsCap command in SlurryTractorCapability.lua.
-- ---------------------------------------------------------------------------
function SPSDebugConfig.consoleDebug(_, channel, state)
    local ch = SPSDebugConfig.channels

    -- No args: list every channel and its state.
    if channel == nil or channel == "" or channel == "list" then
        local keys = {}
        for k in pairs(ch) do
            table.insert(keys, k)
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            print(string.format("[SPS DBG]   %-36s %s", k, ch[k] and "ON" or "off"))
        end
        return "[SPS DBG] usage: spsDebug <channel|all> <on|off>"
    end

    local value
    if state == "on" or state == "true" or state == "1" then
        value = true
    elseif state == "off" or state == "false" or state == "0" then
        value = false
    else
        return "[SPS DBG] state must be 'on' or 'off'"
    end

    if channel == "all" then
        for k in pairs(ch) do
            ch[k] = value
        end
        SPSDebugConfig.applyAll()
        SPSDebugConfig.save()
        return string.format("[SPS DBG] ALL channels -> %s (saved)", value and "ON" or "off")
    end

    if ch[channel] == nil then
        return string.format("[SPS DBG] unknown channel '%s' — run spsDebug list", tostring(channel))
    end

    ch[channel] = value
    SPSDebugConfig.applyAll()
    SPSDebugConfig.save()
    return string.format("[SPS DBG] %s -> %s (saved, survives reload)", channel, value and "ON" or "off")
end

if addConsoleCommand ~= nil then
    addConsoleCommand("spsDebug", "List or toggle SPS debug channels: spsDebug <channel|all> <on|off>",
        "consoleDebug", SPSDebugConfig)
end

print("[SPS] Slurry Pipe System scripts loading (routine lines: spsDebug Info on, per-file load lines: spsDebug Build on)")
