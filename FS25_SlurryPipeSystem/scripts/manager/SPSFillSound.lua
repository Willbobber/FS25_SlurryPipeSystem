-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.2.0

-- SPSFillSound.lua — [SPS 2026-11-06] sounds while a pipe moves liquid (William: "so the pipe water makes noise")
--
-- The game only plays a vehicle's fill sound (<fillUnit><sounds><fill .../></sounds></fillUnit>) at its own fill
-- triggers. SPS pipes add the liquid straight into the tank, so nothing played. Now:
--   * FILL sound: while a pipe (or a washout) is filling a machine, that machine's own fillUnit fill sound plays.
--     Any vehicle: add <sounds><fill template="defaultRefuelSound"/></sounds> inside its <fillUnit> block.
--   * DISCHARGE sound: while a pipe is EMPTYING a machine, its own discharge sound plays (the game only plays it while the
--     machine tips through its discharge node). Any vehicle: <dischargeSound template="..."/> inside its <dischargeNode>.
--   * PIPE FLOW sound (optional, SPS config): <sprayerPipeSystem><sounds><pipeFlow template="..." linkNode="..."/>
--     plays on a sprayer while its pipe moves liquid either way (filling it or emptying it).
-- Covers every SPS pipe: slurry, water and milk (tankers, lanes, tanker-to-tanker levelling) and sprayer hoses - they all
-- move liquid through transferFill / addToSource / removeFromSource.
-- Server: the flow code calls mark(vehicle, isFilling) every time liquid moves. A machine counts as filling / flowing
-- for HOLD_MS after the last move. Only the on / off changes are sent to the clients (SPSFillSoundEvent), and a
-- joining player gets the current ones (sendAllTo).

SPSFillSound = {}
SPSFillSound.HOLD_MS  = 500
SPSFillSound.BIT_FILL = 1
SPSFillSound.BIT_FLOW = 2
SPSFillSound.BIT_DISCH = 4
SPSFillSound.active   = {}   -- server: vehicle -> { fillT, flowT }

local S = SPSFillSound

-- server: liquid just moved into (isFilling) or out of a machine through a pipe
function SPSFillSound.mark(vehicle, isFilling)
    if g_server == nil or vehicle == nil or vehicle.isDeleted then return end
    local a = S.active[vehicle]
    if a == nil then a = { fillT = -math.huge, flowT = -math.huge, dischT = -math.huge }; S.active[vehicle] = a end
    local t = g_time or 0
    a.flowT = t
    if isFilling then a.fillT = t else a.dischT = t end
end

local function bitsOf(a, t)
    local b = 0
    if t - a.fillT < S.HOLD_MS then b = b + S.BIT_FILL end
    if t - a.flowT < S.HOLD_MS then b = b + S.BIT_FLOW end
    if t - a.dischT < S.HOLD_MS then b = b + S.BIT_DISCH end
    return b
end

-- every peer: switch the sounds of one machine
function SPSFillSound.apply(vehicle, bits)
    if vehicle == nil or vehicle.isDeleted then return end
    local old = vehicle.spsSoundBits or 0
    vehicle.spsSoundBits = bits
    if not vehicle.isClient or g_soundManager == nil then return end
    -- the machine's own fill sound (only stopped by us when we started it: a fill trigger may own it)
    local fillOn = bits % 2 == 1
    if vehicle.setFillSoundIsPlaying ~= nil and vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.samples ~= nil
    and vehicle.spec_fillUnit.samples.fill ~= nil then
        if fillOn and old % 2 == 0 then
            vehicle:setFillSoundIsPlaying(true)
            vehicle.spsFillSoundOurs = true
        elseif not fillOn and vehicle.spsFillSoundOurs then
            local ft = vehicle.spec_fillUnit.fillTrigger
            if ft == nil or not ft.isFilling then vehicle:setFillSoundIsPlaying(false) end
            vehicle.spsFillSoundOurs = nil
        end
    end
    -- the machine's own discharge sound (left alone while the machine is tipping through its discharge node itself)
    local sd = vehicle.spec_dischargeable
    local dn = sd ~= nil and (sd.currentDischargeNode or (sd.dischargeNodes ~= nil and sd.dischargeNodes[1])) or nil
    local dsmp = dn ~= nil and dn.dischargeSample or nil
    if dsmp ~= nil then
        local dischOn = math.floor(bits / S.BIT_DISCH) % 2 == 1
        local vanillaOn = sd.currentDischargeState ~= nil and Dischargeable ~= nil
            and sd.currentDischargeState ~= Dischargeable.DISCHARGE_STATE_OFF
        if dischOn and not g_soundManager:getIsSamplePlaying(dsmp) then
            g_soundManager:playSample(dsmp)
            vehicle.spsDischSoundOurs = dsmp
        elseif not dischOn and vehicle.spsDischSoundOurs ~= nil then
            if not vanillaOn then g_soundManager:stopSample(vehicle.spsDischSoundOurs) end
            vehicle.spsDischSoundOurs = nil
        end
    end
    -- the SPS pipe flow sound of a sprayer config
    local entry = g_slurryPipeManager ~= nil and g_slurryPipeManager.getSprayerVehicleEntry ~= nil
        and g_slurryPipeManager:getSprayerVehicleEntry(vehicle) or nil
    local smp = entry ~= nil and entry.pipeFlowSample or nil
    if smp ~= nil then
        local flowOn = math.floor(bits / S.BIT_FLOW) % 2 == 1
        if flowOn and not g_soundManager:getIsSamplePlaying(smp) then
            g_soundManager:playSample(smp)
        elseif not flowOn and g_soundManager:getIsSamplePlaying(smp) then
            g_soundManager:stopSample(smp)
        end
    end
end

-- server, every frame
function SPSFillSound.update(dt)
    if g_server == nil or next(S.active) == nil then return end
    local t = g_time or 0
    local mp = g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer
    for v, a in pairs(S.active) do
        if v.isDeleted then
            S.active[v] = nil
        else
            local b = bitsOf(a, t)
            if b ~= (v.spsSoundBits or 0) then
                S.apply(v, b)
                if mp then g_server:broadcastEvent(SPSFillSoundEvent.new(v, b), nil, nil, v) end
            end
            if b == 0 then S.active[v] = nil end
        end
    end
end

-- server: a joining player hears what is running now
function SPSFillSound.sendAllTo(connection)
    if connection == nil then return end
    for v, _ in pairs(S.active) do
        if not v.isDeleted and (v.spsSoundBits or 0) ~= 0 then
            connection:sendEvent(SPSFillSoundEvent.new(v, v.spsSoundBits))
        end
    end
end

SPSFillSoundEvent = {}
local SPSFillSoundEvent_mt = Class(SPSFillSoundEvent, Event)
InitEventClass(SPSFillSoundEvent, "SPSFillSoundEvent")

function SPSFillSoundEvent.emptyNew()
    return Event.new(SPSFillSoundEvent_mt)
end

function SPSFillSoundEvent.new(vehicle, bits)
    local self = SPSFillSoundEvent.emptyNew()
    self.vehicle, self.bits = vehicle, bits or 0
    return self
end

function SPSFillSoundEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.bits    = streamReadUIntN(streamId, 3)
    self:run(connection)
end

function SPSFillSoundEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUIntN(streamId, self.bits, 3)
end

function SPSFillSoundEvent:run(connection)
    if not connection:getIsServer() or self.vehicle == nil then return end   -- server -> client only
    SPSFillSound.apply(self.vehicle, self.bits)
end
