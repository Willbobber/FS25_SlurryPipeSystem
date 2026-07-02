-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4

-- SlurryTractorCapability.lua
-- FS25_SlurryPipeSystem
--
-- Resolves whether the TRACTOR attached to an SPS implement is allowed to
-- operate outside-cab controls (PTO / hydraulics / lift). This is a pure
-- gameplay/realism gate, NOT an engine limitation: TurnOnVehicle:getCanBeTurnedOn
-- only checks getIsPowered(), so the turn-on path itself is not context-gated.
--
-- Two-tier lookup (Tier 1 wins):
--   Tier 1  Opt-in marker in the tractor's OWN vehicle.xml. Authoritative and
--           future-proof; any mod author declares it. Lives at
--               <vehicle> ... <spsOutsideControls pto="true"/> ... </vehicle>
--           NOTE: deliberately NOT under <vehicle><slurryPipeSystem> — that path
--           is how SlurryPipeManager detects an embedded SPS tanker config, so a
--           marker there would wrongly register the tractor as a slurry vehicle.
--   Tier 2  Bundled configs/spsVehList.xml, keyed by configFileName path-tail
--           (same match rule as spsConfigManifest.xml). Covers base-game tractors.
--   Neither Defaults to all-false (no outside operation).

SlurryTractorCapability = {}

-- Cached path-tail -> caps map built from spsVehList.xml. nil = not yet loaded.
SlurryTractorCapability._vehList = nil

local function newCaps()
    return { pto = false, hydraulics = false, lift = false }
end

-- ---------------------------------------------------------------------------
-- Tier 2 list loader (lazy, once). Mirrors SlurryPipeManager:loadVehicleConfigs.
-- ---------------------------------------------------------------------------
function SlurryTractorCapability._ensureList()
    if SlurryTractorCapability._vehList ~= nil then
        return
    end
    SlurryTractorCapability._vehList = {}

    if g_slurryPipeManager == nil or g_slurryPipeManager.modDirectory == nil then
        print("[SPS CAP] vehList not loaded — modDirectory unavailable")
        return
    end

    local path = g_slurryPipeManager.modDirectory .. "configs/spsVehList.xml"
    if not fileExists(path) then
        print("[SPS CAP] no spsVehList.xml at " .. path)
        return
    end

    local xmlFile = XMLFile.load("spsVehList", path)
    if xmlFile == nil then
        print("[SPS CAP] failed to load " .. path)
        return
    end

    local count = 0
    local idx   = 0
    while true do
        local key = string.format("spsVehList.vehicle(%d)", idx)
        if not xmlFile:hasProperty(key) then break end

        local matchPath = xmlFile:getString(key .. "#path")
        if matchPath ~= nil and matchPath ~= "" then
            local caps = {
                pto        = xmlFile:getBool(key .. "#pto",        false),
                hydraulics = xmlFile:getBool(key .. "#hydraulics", false),
                lift       = xmlFile:getBool(key .. "#lift",       false),
            }
            SlurryTractorCapability._vehList[matchPath:lower():gsub("\\", "/")] = {
                matchPath = matchPath,
                caps      = caps,
            }
            count = count + 1
        end
        idx = idx + 1
    end
    xmlFile:delete()
    --print("[SPS CAP] loaded " .. tostring(count) .. " tractor entries from spsVehList.xml")
end

-- ---------------------------------------------------------------------------
-- Resolve the power-source vehicle for an SPS implement.
-- For a towed tanker this is the front-most vehicle (the tractor). We read the
-- capability marker from this vehicle.
-- ---------------------------------------------------------------------------
function SlurryTractorCapability.resolveTractor(implementVehicle)
    if implementVehicle == nil then return nil end
    if implementVehicle.getRootVehicle ~= nil then
        local root = implementVehicle:getRootVehicle()
        if root ~= nil then
            return root
        end
    end
    return implementVehicle
end

-- ---------------------------------------------------------------------------
-- Tier 1: read the tractor's own vehicle.xml marker.
-- Returns caps table if the marker element is present, else nil.
-- ---------------------------------------------------------------------------
function SlurryTractorCapability._readTier1(tractor)
    if tractor == nil or tractor.configFileName == nil then return nil end
    if not fileExists(tractor.configFileName) then return nil end

    local xmlFile = XMLFile.load("spsTractorCaps", tractor.configFileName)
    if xmlFile == nil then return nil end

    local caps = nil
    if xmlFile:hasProperty("vehicle.spsOutsideControls") then
        caps = {
            pto        = xmlFile:getBool("vehicle.spsOutsideControls#pto",        false),
            hydraulics = xmlFile:getBool("vehicle.spsOutsideControls#hydraulics", false),
            lift       = xmlFile:getBool("vehicle.spsOutsideControls#lift",       false),
        }
    end
    xmlFile:delete()
    return caps
end

-- ---------------------------------------------------------------------------
-- Tier 2: path-tail match against the bundled list.
-- Mirrors SlurryPipeManager:findVehicleConfigForVehicle path-tail rule exactly.
-- ---------------------------------------------------------------------------
function SlurryTractorCapability._readTier2(tractor)
    if tractor == nil or tractor.configFileName == nil then return nil end
    SlurryTractorCapability._ensureList()

    local cfn = tractor.configFileName:lower():gsub("\\", "/")
    for matchPathLower, entry in pairs(SlurryTractorCapability._vehList) do
        if cfn:sub(-#matchPathLower) == matchPathLower then
            return entry.caps, entry.matchPath
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public: resolve outside-control capabilities for the tractor pulling this
-- implement. Always returns a caps table (never nil).
-- ---------------------------------------------------------------------------
function SlurryTractorCapability.getForImplement(implementVehicle)
    local tractor = SlurryTractorCapability.resolveTractor(implementVehicle)
    if tractor == nil then
        return newCaps(), "none"
    end

    -- Tier 1 wins outright if the marker is present.
    local t1 = SlurryTractorCapability._readTier1(tractor)
    if t1 ~= nil then
        return t1, "tier1:" .. tostring(tractor.configFileName)
    end

    -- Tier 2 fallback.
    local t2, matched = SlurryTractorCapability._readTier2(tractor)
    if t2 ~= nil then
        return t2, "tier2:" .. tostring(matched)
    end

    return newCaps(), "default:" .. tostring(tractor.configFileName)
end

-- Convenience boolean for the most common gate.
function SlurryTractorCapability.hasOutsidePTO(implementVehicle)
    local caps = SlurryTractorCapability.getForImplement(implementVehicle)
    return caps.pto == true
end

-- ---------------------------------------------------------------------------
-- Console test command: spsCap
-- While seated in / controlling a vehicle, prints the resolved tractor and its
-- outside-control capabilities so detection can be verified from the log before
-- any activatable wiring lands. Remove this command once detection is confirmed.
-- ---------------------------------------------------------------------------
function SlurryTractorCapability.consoleCap()
    if g_localPlayer == nil then
        return "[SPS CAP] no local player"
    end
    local vehicle = g_localPlayer:getCurrentVehicle()
    if vehicle == nil then
        return "[SPS CAP] not in a vehicle — enter the tanker (or its tractor) and run again"
    end

    local tractor = SlurryTractorCapability.resolveTractor(vehicle)
    local caps, src = SlurryTractorCapability.getForImplement(vehicle)

    --print("[SPS CAP] current vehicle : " .. tostring(vehicle.configFileName))
    --print("[SPS CAP] resolved tractor: " .. tostring(tractor ~= nil and tractor.configFileName or "nil"))
    --print("[SPS CAP] source          : " .. tostring(src))
    --print(string.format("[SPS CAP] caps -> pto=%s hydraulics=%s lift=%s",
    --    tostring(caps.pto), tostring(caps.hydraulics), tostring(caps.lift)))
    return "[SPS CAP] done — see lines above"
end

if addConsoleCommand ~= nil then
    addConsoleCommand("spsCap", "Print resolved outside-control caps for the current vehicle's tractor",
        "consoleCap", SlurryTractorCapability)
end
