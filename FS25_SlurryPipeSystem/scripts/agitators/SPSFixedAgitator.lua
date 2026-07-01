-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.0
--
-- SPSFixedAgitator.lua
-- ---------------------------------------------------------------------------
-- Fixed (placeable-mounted) PTO agitator.
--
-- A set of mixer blades on a slurry-store placeable that spin only while a
-- tractor is connected at the PTO node AND that tractor's engine is running.
-- A placeable is NOT a vehicle and cannot be a real PTO power consumer, so this
-- is a logical connection: SPS detects a nearby tractor, validates alignment,
-- holds a reference to it, and reads its motor state. While connected the
-- tractor is immobilised (Drivable.updateVehiclePhysics override) exactly like
-- a real PTO hookup would hold it.
--
-- This module is entirely separate from the tanker-side PTO probes in
-- ManureBarrelOverride.lua (isPTOConnected / getBayernPTOConnected): those key
-- off a vehicle<->vehicle attacher joint, which does not exist here. Routing the
-- agitator through them would false-positive (no joint -> pass-through true), so
-- the agitator owns its own connection state below.
--
-- STEP 1 scope: parse, ptoDistanceNode-based detection (scans enterable
-- ±range alignment gate, connect/disconnect + MP sync, movement lock, blade
-- spin, agitation. No walterscheid shaft visual yet (step 2). PTO sound is the
-- immediate next add once connect is verified in-game.
-- ---------------------------------------------------------------------------

SPSFixedAgitator = {}

SPSFixedAgitator.DEBUG = false
local function log(fmt, ...)
    if not SPSFixedAgitator.DEBUG then return end
    if select("#", ...) > 0 then
        print("[SPS FIXEDAGITATOR] " .. string.format(fmt, ...))
    else
        print("[SPS FIXEDAGITATOR] " .. tostring(fmt))
    end
end
SPSFixedAgitator.log = log

-- Vehicles currently held by a fixed agitator. Maps vehicle -> true on every
-- peer (server sets it on connect; clients set it from the sync event), so the
-- movement-lock override applies wherever the vehicle is controlled.
SPSFixedAgitator.lockedVehicles = {}

-- ---------------------------------------------------------------------------
-- Node resolution helper (matches registerPlaceable's runtime-linked nodes).
-- Tries the directly-linked nodeTree children first, then a recursive name
-- search of the placeable's component root for nested nodes (e.g. blades).
-- ---------------------------------------------------------------------------
local function findInTree(root, name, results)
    if root == nil or root == 0 then return end
    if getName(root) == name then table.insert(results, root) end
    for i = 0, getNumOfChildren(root) - 1 do
        findInTree(getChildAt(root, i), name, results)
    end
end

local function makeResolver(linkedNodes, compRoot)
    return function(name)
        if name == nil or name == "" then return nil end
        if linkedNodes ~= nil then
            for _, n in ipairs(linkedNodes) do
                if getName(n) == name then return n end
            end
        end
        if compRoot ~= nil and compRoot ~= 0 then
            local matches = {}
            findInTree(compRoot, name, matches)
            if #matches > 0 then return matches[1] end
        end
        return nil
    end
end

-- ---------------------------------------------------------------------------
-- readConfig — parse the <fixedAgitator> block off the same xmlFile/kp the rest
-- of registerPlaceable uses. Returns a config table or nil if the block is
-- absent. Node NAMES are resolved later (initForPlaceable) once linked.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.readConfig(xmlFile, kp)
    kp = kp or ""
    local base = kp .. "slurryPipeSystem.fixedAgitator"
    if not xmlFile:hasProperty(base) then return nil end

    local cfg = {}
    cfg.turnOffIfNotAllowed = xmlFile:getBool(base .. "#turnOffIfNotAllowed", true)
    cfg.maxConnectDistance  = xmlFile:getFloat(base .. "#maxConnectDistance", 0.2)

    -- <input inputNode=".." detachNode=".." filename=".." .../>
    cfg.inputNodeName    = xmlFile:getString(base .. ".input#inputNode", nil)
    cfg.detachNodeName   = xmlFile:getString(base .. ".input#detachNode", nil)
    cfg.shaftFilename    = xmlFile:getString(base .. ".input#filename", nil)
    cfg.shaftZOffset     = xmlFile:getFloat(base .. ".input#zOffset", 0)
    cfg.distanceNodeName = xmlFile:getString(base .. ".input#distanceNode", "ptoDistanceNode")

    -- <level node=".."/> — slurry surface must be at or above this node's world Y
    -- for the agitator to actually mix. Blades still spin when engaged; only the
    -- mixing (crust re-suspension) is gated by level.
    cfg.levelNodeName = xmlFile:getString(base .. ".level#node", "agitatorLevelNode")

    -- <animationNodes><animationNode node=".." rotSpeed=".." rotAxis=".." .../></animationNodes>
    cfg.blades = {}
    local idx = 0
    while true do
        local key = string.format("%s.animationNodes.animationNode(%d)", base, idx)
        if not xmlFile:hasProperty(key) then break end
        local b = {}
        b.nodeName       = xmlFile:getString(key .. "#node", nil)
        b.rotSpeedDeg    = xmlFile:getFloat(key .. "#rotSpeed", 0)       -- degrees / second
        b.rotAxis        = xmlFile:getInt(key .. "#rotAxis", 2)          -- 1=X 2=Y 3=Z
        b.turnOnFadeTime = xmlFile:getFloat(key .. "#turnOnFadeTime", 1) -- seconds
        b.turnOffFadeTime= xmlFile:getFloat(key .. "#turnOffFadeTime", 1)-- seconds
        table.insert(cfg.blades, b)
        idx = idx + 1
    end

    -- <sounds><turnedOn .../></sounds> — captured for step 1b (sound deferred).
    cfg.soundLinkNodeName = xmlFile:getString(base .. ".sounds.turnedOn#linkNode", nil)
    cfg.soundTemplate     = xmlFile:getString(base .. ".sounds.turnedOn#template", nil)
    cfg.soundVolumeScale  = xmlFile:getFloat(base .. ".sounds.turnedOn#volumeScale", 1)

    return cfg
end

-- ---------------------------------------------------------------------------
-- initForPlaceable — resolve nodes, capture blade base rotations, init runtime
-- state. Called from registerPlaceable
-- with the still-open xmlFile and the linkedNodes list.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.initForPlaceable(manager, pEntry, xmlFile, kp, linkedNodes)
    local cfg = SPSFixedAgitator.readConfig(xmlFile, kp)
    if cfg == nil then return end

    local placeable = pEntry.placeable
    local compRoot  = placeable ~= nil and placeable.components ~= nil
        and placeable.components[1] ~= nil and placeable.components[1].node or nil
    local resolve   = makeResolver(linkedNodes, compRoot)

    local fa = {}
    fa.cfg              = cfg
    fa.placeable        = placeable
    fa.inputNode        = resolve(cfg.inputNodeName)
    fa.detachNode       = resolve(cfg.detachNodeName)
    fa.distanceNode     = resolve(cfg.distanceNodeName)
    fa.levelNode        = resolve(cfg.levelNodeName)
    fa.soundNode        = resolve(cfg.soundLinkNodeName)
    fa.maxConnectDist   = cfg.maxConnectDistance or 0.2

    -- Blade nodes + captured base rotation (spin is added on the chosen axis so
    -- any authored orientation is preserved).
    fa.blades = {}
    for _, b in ipairs(cfg.blades) do
        local node = resolve(b.nodeName)
        if node ~= nil and node ~= 0 then
            local rx, ry, rz = getRotation(node)
            table.insert(fa.blades, {
                node     = node,
                baseRot  = { rx, ry, rz },
                spin     = 0,
                rate     = math.rad(b.rotSpeedDeg or 0), -- rad / second
                axis     = b.rotAxis or 2,
                onFade   = math.max(0.001, b.turnOnFadeTime or 1),
                offFade  = math.max(0.001, b.turnOffFadeTime or 1),
            })
        else
            log("blade node '%s' not found on %s", tostring(b.nodeName), tostring(placeable and placeable.configFileName))
        end
    end

    -- Runtime state (running is server-authoritative; synced via event).
    fa.connectedVehicle  = nil
    fa.running           = false
    fa.fade              = 0       -- 0..1 blade-spin ramp (visual, all peers)

    pEntry.fixedAgitator = fa
    log("init complete for %s (input=%s distance=%s level=%s blades=%d)",
        tostring(placeable and placeable.configFileName),
        tostring(fa.inputNode ~= nil), tostring(fa.distanceNode ~= nil),
        tostring(fa.levelNode ~= nil), #fa.blades)

    -- Load the walterscheid shaft (parks itself at the detach node when ready).
    -- Fully isolated: a shaft load error must never break agitator registration.
    if SPSFixedAgitatorShaft ~= nil and fa.cfg.shaftFilename ~= nil then
        local baseDir = placeable ~= nil and placeable.baseDirectory or nil
        local ok, err = pcall(function()
            SPSFixedAgitatorShaft.load(fa, baseDir, function(_)
                SPSFixedAgitator.updateShaftPose(fa)
            end)
        end)
        if not ok then log("shaft load error: %s", tostring(err)) end
    end
end

-- ---------------------------------------------------------------------------
-- updateShaftPose — attach the shaft to the connected tractor's PTO output, or
-- park it at the detach node. Safe before the i3d finishes loading (no-op).
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.updateShaftPose(fa)
    if fa == nil or fa.shaft == nil or not fa.shaft.i3dLoaded then return end
    if SPSFixedAgitatorShaft == nil then return end
    -- Isolated: a shaft geometry error must never break connect/engage.
    local ok, err = pcall(function()
        if fa.connectedVehicle ~= nil then
            local node = SPSFixedAgitator.getTractorPtoNode(fa.connectedVehicle, fa.distanceNode)
            if node ~= nil and node ~= 0 then
                SPSFixedAgitatorShaft.attach(fa.shaft, node)
                return
            end
        end
        SPSFixedAgitatorShaft.park(fa.shaft)
    end)
    if not ok then log("shaft pose error: %s", tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- getTractorPtoNode — the tractor's rear PTO output stub, present unattached
-- (PowerTakeOffs.loadOutputPowerTakeOff loads outputNode at vehicle load).
-- Picks the output node nearest the agitator's distance node when several exist
-- (front + rear PTO). Returns node or nil.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.getTractorPtoNode(vehicle, refNode)
    if vehicle == nil then return nil end
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    local spec = root ~= nil and root.spec_powerTakeOffs or nil
    if spec == nil or spec.outputPowerTakeOffs == nil then return nil end

    local best, bestDist = nil, math.huge
    for _, output in pairs(spec.outputPowerTakeOffs) do
        local node = output.outputNode
        if node ~= nil and node ~= 0 and entityExists(node) then
            if refNode ~= nil and refNode ~= 0 and entityExists(refNode) then
                local d = calcDistanceFrom(node, refNode)
                if d < bestDist then best, bestDist = node, d end
            else
                best = node
            end
        end
    end
    return best, bestDist
end

-- ---------------------------------------------------------------------------
-- pickCandidate — the detection. Scans enterable vehicles (tractors) and
-- returns the one whose rear PTO output node sits within maxConnectDist of the
-- agitator's ptoDistanceNode, plus that node. This IS the "distance node looks
-- for the tractor's PTO node and checks its range" rule — no trigger.
-- (g_currentMission.vehicleSystem.enterables confirmed in Motorized.lua.)
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.pickCandidate(fa)
    if fa == nil or fa.distanceNode == nil or fa.distanceNode == 0 then return nil end
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then return nil end
    local enterables = g_currentMission.vehicleSystem.enterables
    if enterables == nil then return nil end

    local best, bestDist, bestNode = nil, math.huge, nil
    for _, veh in pairs(enterables) do
        if veh ~= nil and veh.getRootVehicle ~= nil then
            local node, d = SPSFixedAgitator.getTractorPtoNode(veh, fa.distanceNode)
            if node ~= nil and d ~= nil and d <= fa.maxConnectDist and d < bestDist then
                best, bestDist, bestNode = veh, d, node
            end
        end
    end
    return best, bestNode, bestDist
end

-- ---------------------------------------------------------------------------
-- requestConnect / requestDisconnect — entry points used by the activatable
-- (and later the cab action). Server applies immediately + broadcasts; client
-- sends a request the server validates.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.requestConnect(placeable, vehicle)
    if placeable == nil or vehicle == nil then return end
    if g_server ~= nil then
        SPSFixedAgitator.applyConnect(placeable, vehicle, true)
    elseif SPSFixedAgitatorEvent ~= nil then
        SPSFixedAgitatorEvent.sendRequest(placeable, vehicle, true)
    end
end

function SPSFixedAgitator.requestDisconnect(placeable)
    if placeable == nil then return end
    if g_server ~= nil then
        SPSFixedAgitator.applyConnect(placeable, nil, false)
    elseif SPSFixedAgitatorEvent ~= nil then
        SPSFixedAgitatorEvent.sendRequest(placeable, nil, false)
    end
end

-- ---------------------------------------------------------------------------
-- applyConnect — authoritative state change. Called on the server (directly or
-- from a client request) and on every peer through the broadcast event so the
-- lock registry / blade target stay in step everywhere.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.applyConnect(placeable, vehicle, connect, isFromEvent)
    local pEntry = g_slurryPipeManager ~= nil and g_slurryPipeManager:getPlaceableEntry(placeable) or nil
    local fa = pEntry ~= nil and pEntry.fixedAgitator or nil
    if fa == nil then return end

    -- Release any prior locked vehicle.
    if fa.connectedVehicle ~= nil then
        SPSFixedAgitator.lockedVehicles[fa.connectedVehicle] = nil
    end

    if connect and vehicle ~= nil then
        fa.connectedVehicle = vehicle
        SPSFixedAgitator.lockedVehicles[vehicle] = true
        fa.ptoEngaged = false   -- shaft connected; PTO not engaged until the player turns it on
        fa.running    = false
        log("connected %s (PTO disengaged — press the implement on/off key to engage)",
            tostring(vehicle.configFileName))
    else
        fa.connectedVehicle = nil
        fa.ptoEngaged = false
        fa.running = false
        log("disconnected agitator on %s", tostring(placeable and placeable.configFileName))
    end

    -- Move the shaft to match (attach to tractor / park).
    SPSFixedAgitator.updateShaftPose(fa)

    -- Authoritative server broadcasts the resulting state to all clients.
    if g_server ~= nil and not isFromEvent and SPSFixedAgitatorEvent ~= nil then
        SPSFixedAgitatorEvent.sendState(placeable, fa.connectedVehicle, fa.running, fa.ptoEngaged)
    end
end

-- ---------------------------------------------------------------------------
-- applyEngage — set the PTO-engaged flag (the player turning the PTO on/off).
-- Blades only spin while engaged. running is recomputed by the server tick.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.applyEngage(placeable, engaged, isFromEvent)
    local pEntry = g_slurryPipeManager ~= nil and g_slurryPipeManager:getPlaceableEntry(placeable) or nil
    local fa = pEntry ~= nil and pEntry.fixedAgitator or nil
    if fa == nil or fa.connectedVehicle == nil then return end

    fa.ptoEngaged = engaged == true
    log("PTO %s on %s", fa.ptoEngaged and "ENGAGED" or "disengaged", tostring(placeable and placeable.configFileName))

    if g_server ~= nil and not isFromEvent and SPSFixedAgitatorEvent ~= nil then
        SPSFixedAgitatorEvent.sendState(placeable, fa.connectedVehicle, fa.running, fa.ptoEngaged)
    end
end

function SPSFixedAgitator.requestEngage(placeable, engaged)
    if placeable == nil then return end
    if g_server ~= nil then
        SPSFixedAgitator.applyEngage(placeable, engaged, false)
    elseif SPSFixedAgitatorEvent ~= nil then
        SPSFixedAgitatorEvent.sendEngageRequest(placeable, engaged)
    end
end

-- ---------------------------------------------------------------------------
-- applyState — receiver-side apply from a broadcast state event (all peers).
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.applyState(placeable, vehicle, running, engaged)
    local pEntry = g_slurryPipeManager ~= nil and g_slurryPipeManager:getPlaceableEntry(placeable) or nil
    local fa = pEntry ~= nil and pEntry.fixedAgitator or nil
    if fa == nil then return end

    if fa.connectedVehicle ~= nil and fa.connectedVehicle ~= vehicle then
        SPSFixedAgitator.lockedVehicles[fa.connectedVehicle] = nil
    end
    fa.connectedVehicle = vehicle
    if vehicle ~= nil then
        SPSFixedAgitator.lockedVehicles[vehicle] = true
    end
    fa.running    = running == true
    fa.ptoEngaged = engaged == true
    SPSFixedAgitator.updateShaftPose(fa)
end

-- ---------------------------------------------------------------------------
-- updateAll — per-tick driver. Server: validate the held connection (range +
-- motor), drive running state, apply agitation, sync transitions. All peers:
-- ramp + spin the blades from the running flag.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.updateAll(manager, dt)
    if manager == nil or manager.registeredPlaceables == nil then return end
    local dtSec = dt * 0.001

    local doServer = g_server ~= nil and manager.isFeatureEnabled ~= nil and manager:isFeatureEnabled()
    local env       = g_currentMission ~= nil and g_currentMission.environment or nil
    local timeScale = env ~= nil and env.timeAdjustment or 1
    local dtHours   = (dt * 0.001) * timeScale / 3600

    for _, pEntry in ipairs(manager.registeredPlaceables) do
        local fa = pEntry.fixedAgitator
        if fa ~= nil then
            -- ---- server authority ----
            if doServer and fa.connectedVehicle ~= nil then
                local veh  = fa.connectedVehicle
                local root = veh.getRootVehicle ~= nil and veh:getRootVehicle() or veh
                local stillValid = veh ~= nil and entityExists(veh.rootNode or 0) ~= false
                -- Range guard: tractor PTO node must remain within reach.
                local node, d = SPSFixedAgitator.getTractorPtoNode(veh, fa.distanceNode)
                local inRange = node ~= nil and d ~= nil and d <= (fa.maxConnectDist + 0.05)
                local motorOk = root ~= nil and root.getIsMotorStarted ~= nil and root:getIsMotorStarted()

                if (not inRange) and fa.cfg.turnOffIfNotAllowed then
                    -- Tractor drove off the connection — full disconnect.
                    SPSFixedAgitator.applyConnect(pEntry.placeable, nil, false)
                else
                    local wasRunning = fa.running
                    fa.running = motorOk and inRange and (fa.ptoEngaged == true)

                    -- Level gate: only mix while the slurry surface is at/above the
                    -- level node. Blades still spin (fa.running); mixing is extra.
                    local aboveLevel = true
                    if fa.levelNode ~= nil and fa.levelNode ~= 0 and entityExists(fa.levelNode)
                    and pEntry.sourceEntry ~= nil and SlurryNodeUtil ~= nil then
                        local lx, ly, lz = getWorldTranslation(fa.levelNode)
                        local surfaceY = SlurryNodeUtil.getSurfaceWorldY(pEntry.sourceEntry, lx, lz)
                        aboveLevel = surfaceY ~= nil and surfaceY > -math.huge and surfaceY >= ly
                        fa._lastSurfaceY, fa._lastLevelY = surfaceY, ly
                    end

                    if fa.running and aboveLevel then
                        if manager.applyAgitation ~= nil and pEntry.sourceEntry ~= nil then
                            local before = pEntry.sourceEntry.settle or 0
                            manager:applyAgitation(pEntry.sourceEntry, dtHours)
                            -- Throttled mixing log (~1s) so the effect is visible.
                            fa._mixLogT = (fa._mixLogT or 0) + dt
                            if fa._mixLogT >= 1000 then
                                fa._mixLogT = 0
                                log("mixing: settle %.4f -> %.4f (surfaceY=%.2f levelY=%.2f)",
                                    before, pEntry.sourceEntry.settle or 0,
                                    fa._lastSurfaceY or -1, fa._lastLevelY or -1)
                            end
                        end
                    elseif fa.running and not aboveLevel then
                        fa._mixLogT = (fa._mixLogT or 0) + dt
                        if fa._mixLogT >= 1000 then
                            fa._mixLogT = 0
                            log("engaged but below level — not mixing (surfaceY=%.2f levelY=%.2f)",
                                fa._lastSurfaceY or -1, fa._lastLevelY or -1)
                        end
                    end

                    if fa.running ~= wasRunning and SPSFixedAgitatorEvent ~= nil then
                        SPSFixedAgitatorEvent.sendState(pEntry.placeable, fa.connectedVehicle, fa.running, fa.ptoEngaged)
                    end
                end
            end

            -- ---- blade visual (all peers) ----
            if #fa.blades > 0 then
                local target = fa.running and 1 or 0
                for _, b in ipairs(fa.blades) do
                    local fadeTime = (target == 1) and b.onFade or b.offFade
                    local step = dtSec / fadeTime
                    if fa.fade < target then
                        fa.fade = math.min(target, fa.fade + step)
                    elseif fa.fade > target then
                        fa.fade = math.max(target, fa.fade - step)
                    end
                    if fa.fade > 0 and b.node ~= nil and entityExists(b.node) then
                        b.spin = b.spin + b.rate * fa.fade * dtSec
                        if b.spin > math.pi * 2 then b.spin = b.spin - math.pi * 2 end
                        local rx, ry, rz = b.baseRot[1], b.baseRot[2], b.baseRot[3]
                        if b.axis == 1 then rx = rx + b.spin
                        elseif b.axis == 3 then rz = rz + b.spin
                        else ry = ry + b.spin end
                        setRotation(b.node, rx, ry, rz)
                    end
                end
            end
        end
    end

    -- ---- cab prompt visibility (client) ----
    -- For the tractor the local player is sitting in, show "Connect PTO" while a
    -- free agitator is within reach, or "Disconnect PTO" while this tractor holds
    -- one; hide otherwise. The action event itself is registered on entry by
    -- registerCabActionEvent.
    if g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil then
        local enterables = g_currentMission.vehicleSystem.enterables
        if enterables ~= nil then
            for _, veh in pairs(enterables) do
                local id = veh._spsAgitatorEventId
                if id ~= nil and veh.getIsEntered ~= nil and veh:getIsEntered() then
                    local show, txt = false, nil
                    -- Holding one -> offer disconnect.
                    for _, pE in ipairs(manager.registeredPlaceables) do
                        local fa2 = pE.fixedAgitator
                        if fa2 ~= nil and fa2.connectedVehicle == veh then
                            show, txt = true, g_i18n:getText("action_spsAgitatorDisconnect")
                            break
                        end
                    end
                    -- Otherwise, in range of a free one -> offer connect.
                    if not show then
                        for _, pE in ipairs(manager.registeredPlaceables) do
                            local fa2 = pE.fixedAgitator
                            if fa2 ~= nil and fa2.connectedVehicle == nil
                            and fa2.distanceNode ~= nil and fa2.distanceNode ~= 0 then
                                local node, d = SPSFixedAgitator.getTractorPtoNode(veh, fa2.distanceNode)
                                if node ~= nil and d ~= nil and d <= fa2.maxConnectDist then
                                    show, txt = true, g_i18n:getText("action_spsAgitatorConnect")
                                    break
                                end
                            end
                        end
                    end
                    g_inputBinding:setActionEventActive(id, show)
                    g_inputBinding:setActionEventTextVisibility(id, show)
                    if show and txt ~= nil then
                        g_inputBinding:setActionEventText(id, txt)
                    end
                    if show ~= (veh._spsAgitatorShown == true) then
                        veh._spsAgitatorShown = show
                        log("cab prompt %s for %s (id=%s)",
                            show and "ACTIVE" or "hidden", tostring(veh.configFileName), tostring(id))
                    end

                    -- Engage prompt: only while this tractor holds an agitator.
                    local eid = veh._spsAgitatorEngageId
                    if eid ~= nil then
                        local heldFa = nil
                        for _, pE in ipairs(manager.registeredPlaceables) do
                            local fa3 = pE.fixedAgitator
                            if fa3 ~= nil and fa3.connectedVehicle == veh then heldFa = fa3 break end
                        end
                        if heldFa ~= nil then
                            g_inputBinding:setActionEventActive(eid, true)
                            g_inputBinding:setActionEventTextVisibility(eid, true)
                            g_inputBinding:setActionEventText(eid, g_i18n:getText(
                                heldFa.ptoEngaged and "action_spsAgitatorPtoOff" or "action_spsAgitatorPtoOn"))
                        else
                            g_inputBinding:setActionEventActive(eid, false)
                            g_inputBinding:setActionEventTextVisibility(eid, false)
                        end
                    end
                end
            end
        end
    end

    -- ---- shaft telescope (all peers), fully isolated ----
    -- Runs AFTER all connect/engage/prompt logic and is pcall-wrapped, so a shaft
    -- geometry error can never break the cab prompt or connection again.
    if SPSFixedAgitatorShaft ~= nil then
        for _, pEntry in ipairs(manager.registeredPlaceables) do
            local fa = pEntry.fixedAgitator
            if fa ~= nil and fa.shaft ~= nil and fa.shaft.i3dLoaded then
                local ok, err = pcall(SPSFixedAgitatorShaft.update, fa.shaft)
                if not ok then
                    log("shaft update error (disabling shaft updates): %s", tostring(err))
                    fa.shaft.i3dLoaded = false  -- stop hammering a broken shaft
                end
            end
        end
    end
end
-- updateAll shows/hides + sets its text by range each tick. The callback
-- connects the nearest in-range free agitator, or disconnects the one this
-- tractor holds.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.registerCabActionEvent(vehicle)
    if vehicle == nil or not vehicle.isClient then return end
    if InputAction.SPS_TOGGLE_AGITATOR == nil then return end
    if vehicle.addActionEvent == nil then return end
    local spec = vehicle.spec_powerTakeOffs
    if spec == nil or spec.outputPowerTakeOffs == nil then return end

    local hasOutput = false
    for _, o in pairs(spec.outputPowerTakeOffs) do
        if o.outputNode ~= nil and o.outputNode ~= 0 then hasOutput = true break end
    end
    if not hasOutput then return end

    local events = {}
    local _, id = vehicle:addActionEvent(
        events, InputAction.SPS_TOGGLE_AGITATOR, vehicle,
        SPSFixedAgitator.onCabActionEvent, false, true, false, true, nil)
    if id ~= nil then
        vehicle._spsAgitatorEventId = id
        vehicle._spsAgitatorEvents  = events  -- keep the table referenced
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventActive(id, false)
        g_inputBinding:setActionEventTextVisibility(id, false)
        log("cab action registered on %s (id=%s)", tostring(vehicle.configFileName), tostring(id))
    else
        log("cab action FAILED to register on %s (binding SPS_TOGGLE_AGITATOR present? %s)",
            tostring(vehicle.configFileName), tostring(InputAction.SPS_TOGGLE_AGITATOR ~= nil))
    end

    -- PTO engage on the familiar implement on/off key (IMPLEMENT_EXTRA). Shown
    -- only while connected (toggled visible in updateAll).
    if InputAction.IMPLEMENT_EXTRA ~= nil then
        local _, eid = vehicle:addActionEvent(
            events, InputAction.IMPLEMENT_EXTRA, vehicle,
            SPSFixedAgitator.onCabEngageEvent, false, true, false, true, nil)
        if eid ~= nil then
            vehicle._spsAgitatorEngageId = eid
            g_inputBinding:setActionEventTextPriority(eid, GS_PRIO_VERY_HIGH)
            g_inputBinding:setActionEventActive(eid, false)
            g_inputBinding:setActionEventTextVisibility(eid, false)
        end
    end
end

function SPSFixedAgitator.onCabEngageEvent(vehicle, actionName, inputValue, callbackState, isAnalog)
    if inputValue ~= nil and inputValue <= 0 then return end
    if g_slurryPipeManager == nil then return end
    for _, pEntry in ipairs(g_slurryPipeManager.registeredPlaceables) do
        local fa = pEntry.fixedAgitator
        if fa ~= nil and fa.connectedVehicle == vehicle then
            log("cab engage -> %s", (not fa.ptoEngaged) and "ENGAGE" or "disengage")
            SPSFixedAgitator.requestEngage(pEntry.placeable, not fa.ptoEngaged)
            return
        end
    end
end

function SPSFixedAgitator.onCabActionEvent(vehicle, actionName, inputValue, callbackState, isAnalog)
    log("cab action FIRED (inputValue=%s vehicle=%s)", tostring(inputValue), tostring(vehicle and vehicle.configFileName))
    if inputValue ~= nil and inputValue <= 0 then return end
    if g_slurryPipeManager == nil then return end

    -- Already holding one -> disconnect it.
    for _, pEntry in ipairs(g_slurryPipeManager.registeredPlaceables) do
        local fa = pEntry.fixedAgitator
        if fa ~= nil and fa.connectedVehicle == vehicle then
            log("cab action -> disconnect")
            SPSFixedAgitator.requestDisconnect(pEntry.placeable)
            return
        end
    end

    -- Otherwise connect the nearest free agitator within range.
    local bestPE, bestDist = nil, math.huge
    for _, pEntry in ipairs(g_slurryPipeManager.registeredPlaceables) do
        local fa = pEntry.fixedAgitator
        if fa ~= nil and fa.connectedVehicle == nil and fa.distanceNode ~= nil and fa.distanceNode ~= 0 then
            local node, d = SPSFixedAgitator.getTractorPtoNode(vehicle, fa.distanceNode)
            log("cab action candidate: ptoNode=%s dist=%s max=%.3f",
                tostring(node ~= nil), node ~= nil and string.format("%.3f", d) or "n/a", fa.maxConnectDist or -1)
            if node ~= nil and d ~= nil and d <= fa.maxConnectDist and d < bestDist then
                bestPE, bestDist = pEntry, d
            end
        end
    end
    if bestPE ~= nil then
        log("cab action -> connect (dist=%.3f, g_server=%s)", bestDist, tostring(g_server ~= nil))
        SPSFixedAgitator.requestConnect(bestPE.placeable, vehicle)
    else
        log("cab action -> no candidate in range")
    end
end

-- ---------------------------------------------------------------------------
-- Movement lock. Overwrites Drivable.updateVehiclePhysics on tractor types:
-- while the vehicle is held by an agitator, force zero drive + handbrake so it
-- holds against forward, reverse and slope roll. Registered from init.lua.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.updateVehiclePhysics(self, superFunc, axisForward, axisSide, doHandbrake, dt)
    if SPSFixedAgitator.lockedVehicles[self] then
        axisForward = 0
        doHandbrake = true
    end
    return superFunc(self, axisForward, axisSide, doHandbrake, dt)
end

function SPSFixedAgitator.registerOverrides()
    if g_vehicleTypeManager == nil then return end
    local n = 0
    for _, typeEntry in pairs(g_vehicleTypeManager:getTypes()) do
        if typeEntry.specializations ~= nil then
            local hasDrivable = false
            for _, spec in ipairs(typeEntry.specializations) do
                if spec.className == "Drivable" then hasDrivable = true break end
            end
            if hasDrivable then
                SpecializationUtil.registerOverwrittenFunction(
                    typeEntry, "updateVehiclePhysics", SPSFixedAgitator.updateVehiclePhysics)
                n = n + 1
            end
        end
    end
    log("registered updateVehiclePhysics lock on %d drivable types", n)

    -- One-shot: register the detection-dump console command.
    if not SPSFixedAgitator._consoleRegistered and addConsoleCommand ~= nil then
        addConsoleCommand("spsAgitatorDebug",
            "Dump fixed-agitator PTO detection (enterables + distance to each ptoDistanceNode)",
            "consoleDump", SPSFixedAgitator)
        SPSFixedAgitator._consoleRegistered = true
    end
end

-- ---------------------------------------------------------------------------
-- consoleDump — run "spsAgitatorDebug" in the console with a tractor parked.
-- Prints how many enterables exist and, for every fixed agitator, the distance
-- from each enterable's rear PTO output node to that agitator's ptoDistanceNode.
-- If the nearest distance is > maxConnectDistance the gate is unmet (move the
-- tractor or widen maxConnectDistance). ptoNode=false means the tractor exposes
-- no rear PTO output node.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.consoleDump()
    if g_slurryPipeManager == nil then return "[SPS] no manager" end
    local enterables = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil
        and g_currentMission.vehicleSystem.enterables or nil
    local out = {}
    local nEnt = 0
    if enterables ~= nil then for _ in pairs(enterables) do nEnt = nEnt + 1 end end
    table.insert(out, string.format("[SPS] enterables=%d", nEnt))

    local nAg = 0
    for _, pEntry in ipairs(g_slurryPipeManager.registeredPlaceables) do
        local fa = pEntry.fixedAgitator
        if fa ~= nil then
            nAg = nAg + 1
            local dnOk = fa.distanceNode ~= nil and fa.distanceNode ~= 0 and entityExists(fa.distanceNode)
            table.insert(out, string.format("[SPS] agitator #%d distanceNode=%s maxConnectDist=%.3f connected=%s",
                nAg, tostring(dnOk), fa.maxConnectDist or -1, tostring(fa.connectedVehicle ~= nil)))
            if dnOk and enterables ~= nil then
                for _, veh in pairs(enterables) do
                    if veh ~= nil and veh.getRootVehicle ~= nil then
                        local node, d = SPSFixedAgitator.getTractorPtoNode(veh, fa.distanceNode)
                        local nm = veh.configFileName and tostring(veh.configFileName):match("([^/\\]+)%.xml$") or tostring(veh)
                        table.insert(out, string.format("[SPS]   %-28s ptoNode=%-5s dist=%s%s",
                            nm, tostring(node ~= nil),
                            node ~= nil and string.format("%.3f m", d) or "n/a",
                            (node ~= nil and d ~= nil and d <= fa.maxConnectDist) and "  <== IN RANGE" or ""))
                    end
                end
            end
        end
    end
    if nAg == 0 then table.insert(out, "[SPS] no fixed agitators registered") end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- cleanup — release lock and any held vehicle on unregister/delete.
-- ---------------------------------------------------------------------------
function SPSFixedAgitator.cleanup(pEntry)
    local fa = pEntry ~= nil and pEntry.fixedAgitator or nil
    if fa == nil then return end
    if fa.connectedVehicle ~= nil then
        SPSFixedAgitator.lockedVehicles[fa.connectedVehicle] = nil
        fa.connectedVehicle = nil
    end
    if fa.shaft ~= nil and SPSFixedAgitatorShaft ~= nil then
        pcall(SPSFixedAgitatorShaft.delete, fa.shaft)
        fa.shaft = nil
    end
    fa.running = false
    pEntry.fixedAgitator = nil
end