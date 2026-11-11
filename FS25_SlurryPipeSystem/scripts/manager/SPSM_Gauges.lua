-- ===========================================================================
-- FS25_SlurryPipeSystem - SPSM_Gauges.lua  (SlurryPipeManager extension)
-- [SPS 1.0.2.0] PRESSURE GAUGES - PHASE A (William 2026-11-04): needle gauges that READ the pressure the mod
-- already has. Display only - nothing in here moves a litre or touches SPSM_Pressure / SPSM_Flow.
-- Design sheet: 05_PROJECT_DOCS/PRESSURE_GAUGES_SPEC.md (Phase A sections A1-A6).
--
-- XML (inside <slurryPipeSystem>):
--   <pressureGauges>
--       <!-- gauge group already pasted into the vehicle i3d (GE): node = the GROUP, needleRotNode found under it -->
--       <pressureGauge type="tank"  node="pressureGauge_tank01" dial="compound"/>
--       <!-- gauge cloned from the shared i3d onto an EMPTY mount node (linked at 0 0 0 / 0 0 0) -->
--       <pressureGauge type="outer" couplingId="1" node="gaugeMount01" sharedGauge="pressureGaugeHori02"/>
--       <pressureGauge type="outer" fillArmId="1"  node="gaugeMount02" sharedGauge="pressureGaugeVert03"/>
--   </pressureGauges>
--   type        : "tank"  = reads the stored tank pressure (state.pressure, signed bar; vacuum tankers only - on a
--                           pump-gated vehicle it reads 0 and warns once at load)
--                 "outer" = bound to ONE part (couplingId or fillArmId) and reads that part's LINE pressure
--                 "discharge" = the rear discharge line (William 2026-11-04, Supercis tank03 on the 0..+10 dial): while
--                           SPREADING (lever on discharge, pump on, spreader valve open) it shows the positive tank
--                           pressure x (1 + thickness * thicknessGain), plus blockedPressure bar while a blockage node
--                           of the vehicle is blocked; 0 otherwise. thicknessGain default 1.0, blockedPressure 4.0 (bar).
--                           HVP (William 2026-11-08, Profi2 tank05 / 07: "for an HVP it's not building a pressure to
--                           spread like a vac tank, it's pressure being built because of the spread"): an HVP has no
--                           stored tank pressure, so the base is the PUMP's own pressure while it pushes out of the
--                           spreader - builds to the + limit while spreading with slurry aboard, purges otherwise
--                           (_gaugeHvpSpreadPressure). Same thickness / blockage terms on top.
--                 "pump" = the PUMP itself (William 2026-11-05, Profi2 tank06: "the pump pressure - or + for the
--                           fillarm and the coupler but not the spreader"). HVP only, takes NO couplingId /
--                           fillArmId: it looks at every fill arm and every coupling at once. Signed like the
--                           pump-side gauge (- while filling, + while discharging), so it wants a compound dial.
--                           While the pump pushes out of the spreader it builds to the + limit like any other
--                           discharge (William 2026-11-08; before that it read 0 there). Empty tank = air = purge.
--   node        : i3d node name (resolved like every other SPS node). With sharedGauge it is the empty mount
--                 transform; without, the gauge group itself (needleRotNode searched under it by name)
--   sharedGauge : one of the six groups of i3d/pressureGauges/pressureGauges.i3d
--                 (pressureGaugeVert01..03 bottom entry, pressureGaugeHori01..03 back entry; 01 = 0..+10 bar,
--                 02 = 0..-10 bar vacuum, 03 = -4..+4 bar compound). Omitted = the gauge is in the vehicle i3d.
--   pumpSide    : outer gauges on an HVP only (William 2026-11-05, Profi2 fill arm: "the gauge before the valve starts
--                 to build pressure when the pump is turned on"). The PUMP side of the part's valve: builds with the
--                 pump even with the valve shut (dead-head), follows the line once the valve is open and the line is
--                 higher, purges when the pump is off and the valve is shut or the open end reaches nothing. The plain
--                 outer gauge keeps reading the line past the valve. Display only, computed on every machine from
--                 state that already syncs (no event). On a vacuum tanker it just reads the line.
--   dial        : "pressure" (0..+10) | "vacuum" (0..-10) | "compound" (-4..+4). Default from the sharedGauge
--                 suffix; REQUIRED for a gauge in the vehicle i3d (unknown / missing = warning, gauge skipped).
--   needleNode  : default "needleRotNode"; lag: needle smoothing in seconds, default 0.6
--   config gate : #configType / #cylinderedConfigIndex (+ #configType2 / #configIndex2 / #configMode2), exactly
--                 as the pipeCouplings use it.
--
-- OUTER gauge rule (Phase A, display only, from the state every peer already has synced):
--   pipe on the part AND its valve open  -> line pressure = the tank's state.pressure
--   valve closed                         -> line pressure HOLDS its last value
--   pipe pulled / no pipe                -> 0 ("if it has no pipe then it can't build back pressure")
--   The fill-arm valve is the vehicle-wide cab valve (state.valveOpen); a coupling has its own valveOpen.
--   HVP / conduit / openTop: state.pressure is forced 0 by SPSM_Pressure, so every gauge reads 0 (Phase B).
--   Known gap: a client joining while a line HOLDS a value sees 0 until that valve is next opened.
--
-- NEEDLE: needleRotNode rotates about its LOCAL Z. Sweep measured by William in GE on the saved asset
-- (helper node "rotZ 151 to -150" in pressureGauges.i3d, 2026-11-04): Z = +151 deg at the dial's FIRST mark,
-- -150 deg at its LAST mark, passing through 0 (needle straight up) half way. angle = lerp(151, -150, t),
-- t = (value - min) / (max - min) clamped to 0..1, then eased toward the target (first order, dt based).
-- The needle snaps to its value on the first tick (vehicle load / savegame) and eases from then on.
--
-- Runs on every machine from SlurryPipeManager:update(dt) (visual, no event). Cloned shared gauges are deleted
-- with the vehicle (cleanupGauges from unregisterVehicle); the hidden proto stays for the map, like the leak proto.
-- Debug: SPSDebugConfig channel "SPSM_Gauges", prefix [SPS GAUGE], change-deduped per gauge.
-- ===========================================================================

SPS_GAUGE_SHARED_I3D = "i3d/pressureGauges/pressureGauges.i3d"

-- One table for every dial: value range + needle angle (degrees about local Z) at min and at max.
SPS_GAUGE_DIALS = {
    pressure = { min =  0, max =  10, angleMin = 151, angleMax = -150 },   -- atlas bottom-right (Vert01 / Hori01)
    vacuum   = { min =  0, max = -10, angleMin = 151, angleMax = -150 },   -- atlas bottom-left  (Vert02 / Hori02)
    compound = { min = -4, max =   4, angleMin = 151, angleMax = -150 },   -- atlas top-left     (Vert03 / Hori03)
}
local SHARED_SUFFIX_DIAL = { ["01"] = "pressure", ["02"] = "vacuum", ["03"] = "compound" }

SlurryPipeManager.GAUGE_DEFAULT_LAG   = 0.6     -- seconds, needle smoothing
SlurryPipeManager.GAUGE_LOG_QUANTUM   = 0.05    -- bar, debug print only when the shown value moves this much

local function gaugeLog(fmt, ...)
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn ~= nil and SPSDebugConfig.isOn("SPSM_Gauges") then
        print("[SPS GAUGE] " .. string.format(fmt, ...))
    end
end

local function nodeOk(n) return n ~= nil and n ~= 0 and entityExists(n) end

-- depth-first search for a child (any depth) by exact name
local function findChildByName(node, name)
    if not nodeOk(node) then return nil end
    for i = 0, getNumOfChildren(node) - 1 do
        local c = getChildAt(node, i)
        if getName(c) == name then return c end
        local deeper = findChildByName(c, name)
        if deeper ~= nil then return deeper end
    end
    return nil
end

local function clamp01(t) if t < 0 then return 0 elseif t > 1 then return 1 end return t end

-- ---------------------------------------------------------------------------
-- shared asset (lazy, once per map; hidden proto under the root, one clone per sharedGauge gauge)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:ensureGaugeProtoLoaded()
    if self._gaugeProto ~= nil or self._gaugeProtoLoading or self._gaugeProtoFailed then return end
    local dir = self.modDirectory or SPS_MOD_DIRECTORY
    if g_i3DManager == nil or dir == nil then
        print("[SPS GAUGE] WARNING: no i3d manager / mod directory - shared gauges cannot load")
        self._gaugeProtoFailed = true
        return
    end
    local file = dir .. SPS_GAUGE_SHARED_I3D
    if not fileExists(file) then
        print("[SPS GAUGE] WARNING: " .. tostring(file) .. " not found - shared gauges cannot load")
        self._gaugeProtoFailed = true
        return
    end
    self._gaugeProtoLoading = true
    g_i3DManager:loadSharedI3DFileAsync(file, false, false, self.onGaugeProtoLoaded, self, nil)
end

function SlurryPipeManager:onGaugeProtoLoaded(i3dNode, failedReason, args)
    self._gaugeProtoLoading = false
    if i3dNode == nil or i3dNode == 0 then
        print("[SPS GAUGE] WARNING: could not load " .. tostring(SPS_GAUGE_SHARED_I3D) .. " (reason "
            .. tostring(failedReason) .. ") - shared gauges cannot load")
        self._gaugeProtoFailed = true
        return
    end
    -- keep the whole i3d root (its children are the six gauge groups); hidden, named, parked under the scene root
    link(getRootNode(), i3dNode)
    setVisibility(i3dNode, false)
    setName(i3dNode, "spsPressureGaugesProto")
    self._gaugeProto = i3dNode
    print("[SPS GAUGE] gauge template loaded (" .. tostring(SPS_GAUGE_SHARED_I3D) .. ", "
        .. tostring(getNumOfChildren(i3dNode)) .. " groups)")   -- once per map
end

-- ---------------------------------------------------------------------------
-- config
-- ---------------------------------------------------------------------------
function SlurryPipeManager:parseGauges(entry, xmlFile, kp, findLinkedNode)
    entry.gaugeEntries = {}
    if xmlFile == nil then return end
    local vehicle = entry.vehicle
    local vname = tostring(vehicle and vehicle.configFileName)

    -- config gate helpers (same semantics as the pipeCoupling gate in registerVehicle)
    local function activeConfigIndex(configType)
        local ct = configType or "cylindered"
        if vehicle ~= nil and vehicle.configurations ~= nil and vehicle.configurations[ct] ~= nil then
            return vehicle.configurations[ct] - 1
        end
        return nil
    end
    local function indexMatches(indexStr, activeIndex)
        if indexStr == nil or activeIndex == nil then return false end
        for token in string.gmatch(indexStr, "[^,]+") do
            local n = tonumber((token:gsub("%s+", "")))
            if n ~= nil and n == activeIndex then return true end
        end
        return false
    end

    local usesPressure = self:usesPressureModel(entry)
    local warnedNoPressure = false
    local i = 0
    while true do
        local key = string.format(kp .. "slurryPipeSystem.pressureGauges.pressureGauge(%d)", i)
        if not xmlFile:hasProperty(key) then break end
        i = i + 1
        local idx = i
        local gType = string.lower(xmlFile:getString(key .. "#type", "tank"))
        local nodeName = xmlFile:getString(key .. "#node")
        local shared = xmlFile:getString(key .. "#sharedGauge")
        local dialName = xmlFile:getString(key .. "#dial")

        -- primary gate
        local cfgIndexStr = xmlFile:getString(key .. "#cylinderedConfigIndex")
        if cfgIndexStr ~= nil then
            local active = activeConfigIndex(xmlFile:getString(key .. "#configType", "cylindered"))
            if active ~= nil and not indexMatches(cfgIndexStr, active) then
                gaugeLog("gauge %d on %s dropped by config gate (index %s, active %s)", idx, vname, tostring(cfgIndexStr), tostring(active))
                continue
            end
        end
        -- secondary gate
        local cfg2Str = xmlFile:getString(key .. "#configIndex2")
        if cfg2Str ~= nil then
            local mode2   = xmlFile:getString(key .. "#configMode2", "require")
            local active2 = activeConfigIndex(xmlFile:getString(key .. "#configType2", "cylindered"))
            if active2 ~= nil then
                local m = indexMatches(cfg2Str, active2)
                if (mode2 == "exclude" and m) or (mode2 ~= "exclude" and not m) then
                    gaugeLog("gauge %d on %s dropped by secondary gate", idx, vname)
                    continue
                end
            end
        end

        if gType ~= "tank" and gType ~= "outer" and gType ~= "discharge" and gType ~= "pump" then
            print(string.format("[SPS GAUGE] WARNING: pressureGauge %d on %s skipped - type '%s' (tank | outer | discharge | pump)", idx, vname, tostring(gType)))
            continue
        end
        local node = findLinkedNode(nodeName)
        if not nodeOk(node) then
            print(string.format("[SPS GAUGE] WARNING: pressureGauge %d on %s skipped - node '%s' not found", idx, vname, tostring(nodeName)))
            continue
        end
        if shared ~= nil and shared ~= "" and dialName == nil then
            dialName = SHARED_SUFFIX_DIAL[string.sub(shared, -2)]
        end
        local dial = dialName ~= nil and SPS_GAUGE_DIALS[string.lower(dialName)] or nil
        if dial == nil then
            print(string.format("[SPS GAUGE] WARNING: pressureGauge %d on %s skipped - dial '%s' (pressure | vacuum | compound; required for a gauge in the vehicle i3d)",
                idx, vname, tostring(dialName)))
            continue
        end

        local g = {
            index      = idx,
            type       = gType,
            node       = node,
            shared     = (shared ~= nil and shared ~= "") and shared or nil,
            dialName   = string.lower(dialName),
            dial       = dial,
            needleName = xmlFile:getString(key .. "#needleNode", "needleRotNode"),
            lag        = math.max(0, xmlFile:getFloat(key .. "#lag", SlurryPipeManager.GAUGE_DEFAULT_LAG)),
            needle     = nil,      -- resolved now (vehicle i3d) or after the clone (shared)
            root       = nil,      -- cloned gauge root (shared only), deleted with the vehicle
            angle      = nil,      -- shown needle angle, degrees; nil = snap on the first tick
            lastLogged = nil,
            -- discharge only
            thicknessGain   = xmlFile:getFloat(key .. "#thicknessGain", 1.0),
            blockedPressure = xmlFile:getFloat(key .. "#blockedPressure", 4.0),
            pumpSide        = xmlFile:getBool(key .. "#pumpSide", false),   -- outer only, see header
        }

        -- binding
        if gType == "outer" then
            local couplingId = xmlFile:getInt(key .. "#couplingId")
            local fillArmId  = xmlFile:getInt(key .. "#fillArmId")
            if (couplingId == nil) == (fillArmId == nil) then
                print(string.format("[SPS GAUGE] WARNING: pressureGauge %d on %s skipped - an outer gauge needs exactly one of couplingId / fillArmId", idx, vname))
                continue
            end
            if couplingId ~= nil then
                for _, c in ipairs(entry.couplingEntries or {}) do
                    if c.id == couplingId then g.coupling = c break end
                end
                if g.coupling == nil then
                    print(string.format("[SPS GAUGE] WARNING: pressureGauge %d on %s skipped - couplingId %s not on this vehicle (config?)", idx, vname, tostring(couplingId)))
                    continue
                end
            else
                for _, a in ipairs(entry.armEntries or {}) do
                    if a.id == fillArmId then g.fillArm = a break end
                end
                if g.fillArm == nil then
                    print(string.format("[SPS GAUGE] WARNING: pressureGauge %d on %s skipped - fillArmId %s not on this vehicle (config?)", idx, vname, tostring(fillArmId)))
                    continue
                end
            end
        elseif gType == "pump" then
            -- [SPS 1.0.2.0] No binding: a pump gauge follows the pump across every fill arm and coupling of this
            -- vehicle, so it needs the HVP line-pressure model rather than a stored tank pressure.
            if self.usesLinePressure == nil or not self:usesLinePressure(entry) then
                print(string.format("[SPS GAUGE] WARNING: pump gauge on %s - vehicle is not an HVP (pumpType %s), it will read 0",
                    vname, tostring(entry.pumpType)))
            end
        elseif gType == "tank" and not usesPressure and not warnedNoPressure then   -- [SPS 1.0.2.0] discharge gauges on an HVP read the pump instead
            warnedNoPressure = true
            print(string.format("[SPS GAUGE] WARNING: tank gauge on %s - vehicle has no stored pressure (pumpType %s), it will read 0",
                vname, tostring(entry.pumpType)))
        end

        if g.shared == nil then
            g.needle = findChildByName(node, g.needleName)
            if not nodeOk(g.needle) then
                print(string.format("[SPS GAUGE] WARNING: pressureGauge %d on %s skipped - needle '%s' not found under '%s'", idx, vname, tostring(g.needleName), tostring(nodeName)))
                continue
            end
            g.restRx, g.restRy, g.restRz = getRotation(g.needle)
        else
            self:ensureGaugeProtoLoaded()
        end

        table.insert(entry.gaugeEntries, g)
        gaugeLog("gauge %d on %s: %s%s dial %s node '%s'%s lag %.2f", idx, vname, gType,
            g.coupling ~= nil and (" coupling " .. tostring(g.coupling.id)) or (g.fillArm ~= nil and (" fillArm " .. tostring(g.fillArm.id)) or ""),
            g.dialName, tostring(nodeName), g.shared ~= nil and (" shared " .. g.shared) or "", g.lag)
    end
    if #entry.gaugeEntries > 0 then
        print(string.format("[SPS GAUGE] %d gauge(s) on %s", #entry.gaugeEntries, vname))
    end
end

-- clone the shared group onto the mount node (needs the proto; retried every tick until it is there)
function SlurryPipeManager:_mountSharedGauge(g, vname)
    if g.root ~= nil or g.failed then return g.needle ~= nil end
    if self._gaugeProto == nil then
        if self._gaugeProtoFailed then g.failed = true end
        return false
    end
    local src = findChildByName(self._gaugeProto, g.shared)
    if not nodeOk(src) then
        print(string.format("[SPS GAUGE] WARNING: sharedGauge '%s' (gauge %d on %s) is not in %s", tostring(g.shared), g.index, vname, SPS_GAUGE_SHARED_I3D))
        g.failed = true
        return false
    end
    if not nodeOk(g.node) then g.failed = true return false end
    local root = clone(src, false, false, false)
    if not nodeOk(root) then g.failed = true return false end
    link(g.node, root)
    setTranslation(root, 0, 0, 0)
    setRotation(root, 0, 0, 0)
    setVisibility(root, true)
    g.root = root
    g.needle = findChildByName(root, g.needleName)
    if not nodeOk(g.needle) then
        print(string.format("[SPS GAUGE] WARNING: needle '%s' not found in sharedGauge '%s' (gauge %d on %s)", tostring(g.needleName), tostring(g.shared), g.index, vname))
        g.failed = true
        return false
    end
    g.restRx, g.restRy, g.restRz = getRotation(g.needle)
    gaugeLog("gauge %d on %s: shared '%s' cloned onto '%s'", g.index, vname, g.shared, tostring(getName(g.node)))
    return true
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.2.0] PUMP-SIDE gauge value (outer gauge with pumpSide="true", HVP only). The pump side of the valve is a dead
-- end while the valve is shut, so it charges as soon as the pump runs, at the same build / purge speed as the line
-- (SPSM_Pressure tickLinePressure: maxP / minBuildTime, maxP / purgeTime). Once the valve is open it can never read less
-- than the line past it. Pump off: it holds while an open valve reaches a pipe with a source; with the valve shut, or an
-- open end that reaches nothing, it bleeds off. Inputs are _linePathInputs (synced state) - no event, display only.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_gaugePumpSide(entry, g, lineP, s)
    if self.usesLinePressure == nil or not self:usesLinePressure(entry) or entry.state == nil then return lineP end
    local part = g.coupling or g.fillArm
    local kind = g.coupling ~= nil and SlurryPipeManager.LINE_PART_COUPLING or SlurryPipeManager.LINE_PART_ARM
    local pipeOn, valveOpen, hasSource = self:_linePathInputs(entry, kind, part)
    local cfg  = entry.pressure
    local maxP = cfg.maxPressure
    if maxP == nil or maxP <= 0 then maxP = SlurryPipeManager.DEFAULT_MAX_PRESSURE end
    local gVac = entry.state.direction ~= SPS_DIRECTION_DISCHARGE   -- [SPS 1.0.2.0] vacuum side: its own limit / build time
    local maxB = SlurryPipeManager.pcfgMax(cfg, gVac)
    local buildTime = gVac and cfg.minBuildTimeVacuum or cfg.minBuildTime
    if buildTime == nil or buildTime <= 0 then buildTime = SlurryPipeManager.DEFAULT_MIN_BUILD_TIME end
    local purgeTime = cfg.purgeTime
    if purgeTime == nil or purgeTime <= 0 then purgeTime = SlurryPipeManager.DEFAULT_PURGE_TIME end
    local target = (entry.state.direction == SPS_DIRECTION_DISCHARGE) and maxB or -maxB
    local ps = g.pumpP or 0
    local reaches = pipeOn and hasSource                      -- an open end that reaches a liquid
    if self:_isPumpOn(entry.vehicle) then
        if valveOpen and not reaches then
            ps = self:_movePressureToward(ps, 0, maxP / purgeTime * s)      -- open to air: nothing to push against
        else
            ps = self:_movePressureToward(ps, target, maxB / buildTime * s) -- dead-head, or open onto a source
        end
    elseif not valveOpen or not reaches then
        ps = self:_movePressureToward(ps, 0, maxP / purgeTime * s)
    end
    if valveOpen and math.abs(lineP) > math.abs(ps) then ps = lineP end    -- never below the line past an open valve
    g.pumpP = ps
    return ps
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.2.0] PUMP gauge value (type="pump", HVP only, William 2026-11-05). One gauge for the PUMP itself instead of
-- for one part: "the pump pressure - or + for the fillarm and the coupler but not the spreader". It scans every fill
-- arm and every coupling and follows the pump the same way a pump-side gauge does - target -maxPressure while filling,
-- +maxPressure while discharging, same build / purge rates:
--   pushing out of the SPREADER  -> purge to 0. That flow leaves out the back; it is not pressing on this manifold.
--   any path OPEN TO AIR         -> purge. Its valve is open and its far end reaches nothing, so the manifold vents
--                                   through it and cannot hold pressure, whatever the other paths are doing.
--   otherwise, pump on           -> build toward the signed target (a shut valve is a dead end, an open one onto a
--                                   source is pushed against / drawn from).
--   pump off                     -> hold while some path is open onto a source (the column of liquid holds it),
--                                   otherwise bleed off.
-- With a single part this reduces to exactly _gaugePumpSide. Inputs are _linePathInputs (synced state) - no event,
-- display only, computed on every machine.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_gaugePumpAll(entry, g, state, s)
    if self.usesLinePressure == nil or not self:usesLinePressure(entry) or state == nil then return 0 end
    local cfg  = entry.pressure
    local maxP = cfg.maxPressure
    if maxP == nil or maxP <= 0 then maxP = SlurryPipeManager.DEFAULT_MAX_PRESSURE end
    local gVac = state.direction ~= SPS_DIRECTION_DISCHARGE   -- [SPS 1.0.2.0] vacuum side: its own limit / build time
    local maxB = SlurryPipeManager.pcfgMax(cfg, gVac)
    local buildTime = gVac and cfg.minBuildTimeVacuum or cfg.minBuildTime
    if buildTime == nil or buildTime <= 0 then buildTime = SlurryPipeManager.DEFAULT_MIN_BUILD_TIME end
    local purgeTime = cfg.purgeTime
    if purgeTime == nil or purgeTime <= 0 then purgeTime = SlurryPipeManager.DEFAULT_PURGE_TIME end

    local ps     = g.pumpP or 0
    local pumpOn = self._isPumpOn ~= nil and self:_isPumpOn(entry.vehicle)

    -- [SPS 1.0.2.0] pushing out of the SPREADER (William 2026-11-08): the spread IS the load the pump works against,
    -- so the pump gauge builds to the + limit like the discharge gauges - with slurry aboard. An empty tank cycles
    -- air through the open spreader valve and the gauge purges. (Until 2026-11-08 this branch read 0.)
    if pumpOn and state.direction == SPS_DIRECTION_DISCHARGE and state.spreaderValveOpen == true then
        local _, fillLevel = self:getPressureFillRatio(entry.vehicle, entry)
        if fillLevel == nil or fillLevel <= 0 then
            g.pumpP = self:_movePressureToward(ps, 0, maxP / purgeTime * s)
            return g.pumpP
        end
        -- the pump reads the spreading back pressure itself (state.spreadPressure, the number that sets the rate)
        g.pumpP = state.spreadPressure or ps
        return g.pumpP
    end

    local venting, holding = false, false
    local function scanParts(kind, list)
        for _, part in ipairs(list or {}) do
            local pipeOn, valveOpen, hasSource = self:_linePathInputs(entry, kind, part)
            if valveOpen then
                if pipeOn and hasSource then holding = true else venting = true end
            end
        end
    end
    scanParts(SlurryPipeManager.LINE_PART_ARM,      entry.armEntries)
    scanParts(SlurryPipeManager.LINE_PART_COUPLING, entry.couplingEntries)

    if venting then
        ps = self:_movePressureToward(ps, 0, maxP / purgeTime * s)
    elseif pumpOn then
        local target = (state.direction == SPS_DIRECTION_DISCHARGE) and maxB or -maxB
        ps = self:_movePressureToward(ps, target, maxB / buildTime * s)
    elseif not holding then
        ps = self:_movePressureToward(ps, 0, maxP / purgeTime * s)
    end                                   -- pump off with an open path onto a source: holds
    g.pumpP = ps
    return ps
end

-- ---------------------------------------------------------------------------
-- [SPS 1.0.2.0] HVP discharge-line base pressure (William 2026-11-08, Profi2 tank05 / 07 never moved: the discharge
-- gauge read state.pressure, which an HVP never has). The HVP pump builds pressure BECAUSE it is pushing slurry out
-- of the spreader: pump on + lever on DISCHARGE + spreader valve open + slurry aboard -> toward the + limit at the
-- build rate; anything else (pump off, lever elsewhere, valve shut, tank empty = air) -> purge to 0. Display only,
-- per gauge (g.spreadP), computed on every machine from synced state. Vacuum tankers never come here.
-- ---------------------------------------------------------------------------
function SlurryPipeManager:_gaugeHvpSpreadPressure(entry, g, state, s)
    -- [SPS 1.0.2.0] since 2026-11-08 ~21:30 the value is the tanker's state.spreadPressure (SPSM_Pressure
    -- tickSpreadPressure, every machine) - the same number that sets the spread rate - so needle and rate agree.
    if state == nil then return 0 end
    return state.spreadPressure or 0
end

-- ---------------------------------------------------------------------------
-- per frame (every machine)
-- ---------------------------------------------------------------------------
function SlurryPipeManager:tickGauges(dt)
    if dt == nil or dt <= 0 then return end
    local s = dt * 0.001
    for _, entry in ipairs(self.registeredVehicles) do
        local gauges = entry.gaugeEntries
        if gauges ~= nil and #gauges > 0 and entry.vehicle ~= nil then
            local state = entry.state
            local tankP = (state ~= nil and state.pressure) or 0
            local vname = tostring(entry.vehicle.configFileName)
            for _, g in ipairs(gauges) do
                if g.shared ~= nil and g.needle == nil then self:_mountSharedGauge(g, vname) end
                if nodeOk(g.needle) then
                    -- the value this gauge shows
                    local value
                    if g.type == "tank" then
                        value = tankP
                    elseif g.type == "pump" then
                        value = self:_gaugePumpAll(entry, g, state, s)
                    elseif g.type == "discharge" then
                        -- spreading = lever on discharge + pump on + spreader valve open; otherwise the line is at rest
                        value = 0
                        -- [SPS 1.0.2.0] HVP: no stored tank pressure - the base is the pump's own spreading pressure
                        -- (builds while spreading, purges otherwise; ticked outside the gate too so it winds down)
                        local hvp = self.usesLinePressure ~= nil and self:usesLinePressure(entry)
                        local baseP = hvp and self:_gaugeHvpSpreadPressure(entry, g, state, s) or math.max(0, tankP)
                        if state ~= nil and state.direction == SPS_DIRECTION_DISCHARGE and state.spreaderValveOpen == true
                        and self._isPumpOn ~= nil and self:_isPumpOn(entry.vehicle) then
                            value = baseP * (1 + (state.thickness or 0) * g.thicknessGain)
                            if entry.blockageEntries ~= nil then
                                for _, b in ipairs(entry.blockageEntries) do
                                    if b.blocked == true then value = value + g.blockedPressure break end
                                end
                            end
                        end
                    else
                        local part, connected, valveOpen
                        if g.coupling ~= nil then
                            part = g.coupling
                            connected = part.isConnected == true
                            valveOpen = part.valveOpen == true
                        else
                            part = g.fillArm
                            connected = part.isConnected == true
                            valveOpen = state ~= nil and state.valveOpen == true
                        end
                        if self.usesLinePressure ~= nil and self:usesLinePressure(entry) then
                            -- [SPS 1.0.2.0 B2] HVP: the line pressure is REAL server state (SPSM_Pressure
                            -- tickLinePressure, synced by SPSLinePressureEvent) - read it, never derive it here
                        elseif not connected then
                            part.linePressure = 0                 -- pipe pulled / no pipe: nothing to hold
                        elseif valveOpen then
                            part.linePressure = tankP             -- open to the tank: follows it
                        else
                            part.linePressure = part.linePressure or 0   -- shut: holds
                        end
                        value = part.linePressure or 0
                        if g.pumpSide then value = self:_gaugePumpSide(entry, g, value, s) end
                    end
                    -- value -> needle angle, eased
                    local d = g.dial
                    local t = clamp01((value - d.min) / (d.max - d.min))
                    local target = d.angleMin + (d.angleMax - d.angleMin) * t
                    if g.angle == nil or g.lag <= 0 then
                        g.angle = target
                    else
                        g.angle = g.angle + (target - g.angle) * (1 - math.exp(-s / g.lag))
                    end
                    setRotation(g.needle, g.restRx, g.restRy, math.rad(g.angle))
                    if g.lastLogged == nil or math.abs(value - g.lastLogged) >= SlurryPipeManager.GAUGE_LOG_QUANTUM then
                        g.lastLogged = value
                        gaugeLog("%s gauge %d (%s) on %s: %.2f bar -> needle %.1f deg (target %.1f)", g.type, g.index, g.dialName, vname, value, g.angle, target)
                    end
                end
            end
        end
    end
end

-- vehicle gone: drop the cloned shared gauges (gauges in the vehicle i3d die with the vehicle)
function SlurryPipeManager:cleanupGauges(entry)
    if entry == nil or entry.gaugeEntries == nil then return end
    for _, g in ipairs(entry.gaugeEntries) do
        if nodeOk(g.root) then delete(g.root) end
        g.root, g.needle = nil, nil
    end
    entry.gaugeEntries = {}
end
