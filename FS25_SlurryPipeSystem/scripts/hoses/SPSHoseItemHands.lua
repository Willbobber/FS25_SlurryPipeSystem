-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSHoseItemHands.lua
-- [SPS 1.0.1.8] Mouse controls of the BOUGHT PHYSICAL pipes (William 2026-10-15), all on the game's
-- own hands tool (HandToolHands), PHYSICAL pipe mode only:
--   LEFT  mouse (ACTIVATE_HANDTOOL)            pick the pipe up / drop it      - vanilla, untouched
--   RIGHT mouse (ACTIVATE_HANDTOOL_SECONDARY)  holding a pipe whose free end is in range of a free,
--                                              gender-matching coupling -> CONNECT that end (the pipe
--                                              leaves the hands and plugs in). Otherwise vanilla throw.
--   RIGHT mouse, hands empty, AIMING at the plugged-in END of a pipe -> UNPLUG that end AND take it
--                                              into the hands (walk it to the next coupling).
--   LEFT  mouse, hands empty, AIMING at the plugged-in END of a pipe -> UNPLUG that end; the pipe
--                                              just falls (no pick-up).
--   Aiming at the middle, or at a free end, is plain vanilla pick-up - never a disconnect.
-- "The end" = the body the hand aims at is one of the END_ZONE bodies at that end of the pipe
-- (William 2026-10-15: each end independent, by the body the hand touches, not by distance - a bent
-- pipe can have both ends together). The plugged end's own body is kinematic with collision off, so
-- the aim ray only ever hits its neighbours - hence the zone.
-- Hooks: HandToolHands.onUpdate (appended: decide the mode, set the two prompt texts, keep the
-- right-mouse event active with empty hands), onThrowAction / onPickUpAction (overwritten: act in
-- our modes, vanilla otherwise). The pickUpTarget hook that makes the hands hold the grabbed body
-- lives in SPSHoseItem.lua.
-- Engine facts: onRegisterActionEvents (HandToolHands.lua:274-295: pickUp = ACTIVATE_HANDTOOL
-- triggerUp, throw = ACTIVATE_HANDTOOL_SECONDARY triggerDown+triggerAlways, the throw itself fires
-- from onUpdate when the button is released); onUpdate sets the prompts' active state and texts
-- every frame while not holding (:205-233); targeter record {node,x,y,z,distance}
-- (PlayerTargeter.lua:98-103); getClosestTargetedNodeFromType(HandToolHands) (:206).

SPSHoseItemHands = {}
SPSHoseItemHands.END_ZONE = 3   -- bodies counted from each end that mean "this end" (3 of 13 = ~1 m)
-- [SPS 1.0.1.8] William 2026-10-17: "I need to be right on top of the body to select it". The vanilla hands look
-- HandToolHands.PICKUP_DISTANCE (2 m) along the aim ray and that one number serves every pickable object, so a
-- SECOND target type (key = this table) is registered on the player's targeter while the hands are held: same
-- collision mask, longer reach, filtered to physical-pipe bodies only. With empty hands the aim falls back to
-- it when the vanilla 2 m target is empty: the pipe's prompts work from there, and a plain pick-up at that
-- range goes through pickUpTarget with the hold distance clamped to the vanilla 2 m (the pipe swings in).
SPSHoseItemHands.PIPE_TARGET_DISTANCE = 4.0

local function nodeOk(n) return n ~= nil and n ~= 0 and entityExists(n) end

local function pipeOf(node)
    if not nodeOk(node) or g_currentMission == nil then return nil end
    local obj = g_currentMission:getNodeObject(node)
    if obj ~= nil and obj.spsGetEnd ~= nil then return obj end
    return nil
end

-- [SPS 1.0.1.8] the SPS Docking Station in the hands (SPSDockingStation): placed on a vehicle's frame like a pipe on a rack
local function dsOf(node)
    if not nodeOk(node) or g_currentMission == nil then return nil end
    local obj = g_currentMission:getNodeObject(node)
    if obj ~= nil and obj.spsDsStow ~= nil then return obj end
    return nil
end

-- Holder lists (pipe racks / station frames) in reach: the chosen one sticks while it stays in reach, SPS_STOW_NEXT /
-- PREV step through, nearest is the default. Returns the chosen list entry.
local function pickHolder(spec, list)
    local sel = 1
    if spec._spsStowChoice ~= nil then
        for i, c in ipairs(list) do
            if c.holder == spec._spsStowChoice then sel = i end
        end
    end
    if spec._spsStowCycle ~= nil and spec._spsStowCycle ~= 0 and #list > 1 then
        sel = ((sel - 1 + spec._spsStowCycle) % #list) + 1
    end
    spec._spsStowCycle = 0
    local c = list[sel]
    spec._spsStowChoice = c.holder
    return c
end

local function physicalMode()
    local mgr = g_slurryPipeManager
    return mgr ~= nil and mgr.isPhysicalPipesMode ~= nil and mgr:isPhysicalPipesMode()
end

-- Which end of the pipe is this body part of? 1 / 2, or nil for the middle.
local function endZoneOf(pipe, node)
    local ci = pipe.spsGetComponentIndex ~= nil and pipe:spsGetComponentIndex(node) or nil
    if ci == nil then return nil end
    local n = #pipe.components
    local a, b = pipe:spsGetEnd(1), pipe:spsGetEnd(2)
    local compA = (a ~= nil and a.comp) or 1
    local compB = (b ~= nil and b.comp) or n
    if math.abs(ci - compA) < SPSHoseItemHands.END_ZONE then return 1 end
    if math.abs(ci - compB) < SPSHoseItemHands.END_ZONE then return 2 end
    return nil
end

-- Held pipe: the free end closest to a free, gender-matching coupling - or to a free, mating end of
-- another pipe - within the connect radius. Held by an end -> only that end may connect and the search
-- point is the HELD BODY (the hand), not the tip hanging below it (William 2026-10-15: holding body 2 after
-- a take, the connect only worked once the dangling tip was moved onto the coupling); held in the middle
-- -> either free end, measured at its tip.
-- Returns kind ("coupling" | "pipe"), endIdx, then coupling, owner, isPlaceable  or  otherPipe, otherIdx.
local function findConnectCandidate(mgr, pipe, heldNode)
    local onlyIdx = endZoneOf(pipe, heldNode)
    local hx, hy, hz = nil, nil, nil
    if onlyIdx ~= nil and nodeOk(heldNode) then hx, hy, hz = getWorldTranslation(heldNode) end
    local bestD, bestKind, bestIdx, a1, a2, a3 = math.huge, nil, nil, nil, nil, nil
    for idx = 1, 2 do
        local e = pipe:spsGetEnd(idx)
        if (onlyIdx == nil or onlyIdx == idx) and e ~= nil and e.coupling == nil and e.joinedTo == nil and nodeOk(e.node) then
            local x, y, z = getWorldTranslation(e.node)
            if hx ~= nil then x, y, z = hx, hy, hz end
            local c, owner, isPlaceable, d = mgr:findCouplingForPhysPipeEnd(x, y, z, e.gender)
            if c ~= nil and d < bestD then
                bestD, bestKind, bestIdx, a1, a2, a3 = d, "coupling", idx, c, owner, isPlaceable
            end
            if mgr.findPipeEndForPhysPipeEnd ~= nil then
                local op, oidx, d2 = mgr:findPipeEndForPhysPipeEnd(x, y, z, e.gender, pipe)
                if op ~= nil and d2 < bestD then
                    bestD, bestKind, bestIdx, a1, a2, a3 = d2, "pipe", idx, op, oidx, nil
                end
            end
        end
    end
    return bestKind, bestIdx, a1, a2, a3
end

-- Aimed-at body -> (pipe, plugged end index) when the body is in the zone of a PLUGGED end.
local function aimedPluggedEnd(targetNode)
    local pipe = pipeOf(targetNode)
    if pipe == nil then return nil, nil end
    local idx = endZoneOf(pipe, targetNode)
    if idx == nil then return pipe, nil end
    local e = pipe:spsGetEnd(idx)
    if e == nil or (e.coupling == nil and e.joinedTo == nil) then return pipe, nil end
    return pipe, idx
end

-- ---------------------------------------------------------------------------
-- Per frame: decide the mode and dress the prompts. Runs AFTER the vanilla onUpdate, which has
-- already reset the texts / active flags for the empty-hands case.
-- ---------------------------------------------------------------------------
function SPSHoseItemHands.onUpdate(hands, dt)
    local spec = hands.spec_hands
    if spec == nil then return end
    local player = hands.getCarryingPlayer ~= nil and hands:getCarryingPlayer() or nil
    if player == nil or not player.isOwner then return end
    -- [SPS 1.0.1.8] "Free stuck pipe" key: only while an SPS pipe is held and not freed yet
    if spec._spsFreeId ~= nil then
        local heldPipe = pipeOf(spec.heldItemNode)
        if heldPipe == nil then spec._spsFreedPipe = nil end
        g_inputBinding:setActionEventActive(spec._spsFreeId, heldPipe ~= nil and spec._spsFreedPipe ~= heldPipe)
    end
    -- Must-release latch (William's water-pipe test 2026-10-16 22:34: one right-mouse press connected the
    -- end and, 55-70 ms later, unplugged it again). The throw event is triggerAlways, so while the button
    -- is held its callback fires EVERY frame the event is active - a frame with the event active and no
    -- callback means the button is up. The old "frame gap" test was fooled because the vanilla onUpdate
    -- deactivates the event with empty hands and the aim needs a few frames to land on the plugged end's
    -- neighbour: the gap grew while the button was still down.
    if spec._spsNeedRelease and spec._spsThrowActive
       and (spec._spsThrowSeenIdx == nil or (g_updateLoopIndex - spec._spsThrowSeenIdx) >= 2) then
        spec._spsNeedRelease = false
    end
    spec._spsThrowActive = false
    local hadConnectText = spec._spsMode == "connect" or spec._spsMode == "stow" or spec._spsMode == "dsStow"
    spec._spsMode, spec._spsPipe, spec._spsEnd = nil, nil, nil
    spec._spsCoupling, spec._spsOwner, spec._spsIsPlaceable = nil, nil, false
    spec._spsOtherPipe, spec._spsOtherEnd = nil, nil
    spec._spsUnplugPipe, spec._spsUnplugEnd, spec._spsAimNode = nil, nil, nil
    spec._spsFarTarget = nil
    spec._spsHolder, spec._spsSlot, spec._spsStowList = nil, nil, nil
    if spec._spsStowNextId ~= nil then g_inputBinding:setActionEventActive(spec._spsStowNextId, false) end
    if spec._spsStowPrevId ~= nil then g_inputBinding:setActionEventActive(spec._spsStowPrevId, false) end
    -- [SPS 1.0.1.8] holding the SPS Docking Station: a vehicle's station frame in reach of its base -> PLACE it there
    -- (right mouse; both pipe modes). Several in reach: same cycle keys as the pipe racks. Taking it off = plain pick-up.
    if hands:getIsHoldingItem() then
        local ds = dsOf(spec.heldItemNode)
        if ds ~= nil then
            spec._spsThrowActive = true
            local dmgr = g_slurryPipeManager
            local list = (dmgr ~= nil and dmgr.findDsHoldersForStation ~= nil) and dmgr:findDsHoldersForStation(ds) or {}
            if #list > 0 then
                local c = pickHolder(spec, list)
                spec._spsStowList = list
                spec._spsMode, spec._spsPipe, spec._spsHolder = "dsStow", ds, c.holder
                if spec.throwActionEventId ~= nil then
                    local text = string.format(g_i18n:getText("action_spsDsStow"), c.holder.id or 0)
                    if #list > 1 then text = text .. " " .. g_i18n:getText("action_spsPhysStowCycle") end
                    g_inputBinding:setActionEventText(spec.throwActionEventId, text)
                end
                if spec._spsStowNextId ~= nil then g_inputBinding:setActionEventActive(spec._spsStowNextId, #list > 1) end
                if spec._spsStowPrevId ~= nil then g_inputBinding:setActionEventActive(spec._spsStowPrevId, #list > 1) end
                return
            end
            spec._spsStowChoice = nil
            if hadConnectText and spec.throwActionEventId ~= nil then
                g_inputBinding:setActionEventText(spec.throwActionEventId, spec.throwText)
            end
            return
        end
    end
    if not physicalMode() then
        if hadConnectText and spec.throwActionEventId ~= nil then
            g_inputBinding:setActionEventText(spec.throwActionEventId, spec.throwText)
        end
        return
    end
    local mgr = g_slurryPipeManager

    if hands:getIsHoldingItem() then
        spec._spsThrowActive = true   -- vanilla keeps the throw event active while something is held
        local pipe = pipeOf(spec.heldItemNode)
        if pipe ~= nil then
            local kind, idx, a1, a2, a3 = findConnectCandidate(mgr, pipe, spec.heldItemNode)
            if kind ~= nil then
                spec._spsMode, spec._spsPipe, spec._spsEnd = (kind == "pipe") and "join" or "connect", pipe, idx
                if kind == "pipe" then
                    spec._spsOtherPipe, spec._spsOtherEnd = a1, a2
                else
                    spec._spsCoupling, spec._spsOwner, spec._spsIsPlaceable = a1, a2, a3
                end
                if spec.throwActionEventId ~= nil then
                    g_inputBinding:setActionEventText(spec.throwActionEventId, g_i18n:getText("action_spsPhysConnect"))
                end
                return
            end
            -- [SPS 1.0.1.8] nothing to connect: vehicle pipe holders within reach of the pipe's middle -> STOW.
            -- Several in reach: SPS_STOW_NEXT / PREV (mouse wheel or , .) cycle them; the choice sticks while that
            -- holder stays in reach; nearest is the default.
            if mgr ~= nil and mgr.findPipeHoldersForPipe ~= nil then
                local list = mgr:findPipeHoldersForPipe(pipe)
                if #list > 0 then
                    local c = pickHolder(spec, list)
                    spec._spsStowList = list
                    spec._spsMode, spec._spsPipe, spec._spsHolder, spec._spsSlot = "stow", pipe, c.holder, c.slot
                    if spec.throwActionEventId ~= nil then
                        local text = string.format(g_i18n:getText("action_spsPhysStow"), c.holder.id or 0, c.slot.family, c.free or 0, c.total or 0)
                        if #list > 1 then text = text .. " " .. g_i18n:getText("action_spsPhysStowCycle") end
                        g_inputBinding:setActionEventText(spec.throwActionEventId, text)
                    end
                    if spec._spsStowNextId ~= nil then g_inputBinding:setActionEventActive(spec._spsStowNextId, #list > 1) end
                    if spec._spsStowPrevId ~= nil then g_inputBinding:setActionEventActive(spec._spsStowPrevId, #list > 1) end
                    return
                end
            end
            spec._spsStowChoice = nil
        end
        if hadConnectText and spec.throwActionEventId ~= nil then
            g_inputBinding:setActionEventText(spec.throwActionEventId, spec.throwText)
        end
        return
    end

    -- Hands empty: everything keys off the body the hand AIMS at. Only the zone of a PLUGGED end
    -- offers a disconnect; the middle and a free end stay plain vanilla pick-up.
    if spec.football ~= nil or player.targeter == nil or player.targeter.closestTargetsByKey == nil then return end
    local near = player.targeter.closestTargetsByKey[HandToolHands]
    local far  = player.targeter.closestTargetsByKey[SPSHoseItemHands]
    local targetNode = near ~= nil and near.node or nil
    if targetNode == nil and far ~= nil and pipeOf(far.node) ~= nil then
        -- beyond the vanilla reach but a pipe body: aim at it, and offer the plain pick-up from here
        targetNode = far.node
        if hands.getCanPickUpNode == nil or hands:getCanPickUpNode(far.node) then
            spec._spsFarTarget = { node = far.node, x = far.x, y = far.y, z = far.z,
                distance = math.min(far.distance, HandToolHands.PICKUP_DISTANCE) }   -- copy: the record is pooled per frame
            if spec.pickUpActionEventId ~= nil then
                g_inputBinding:setActionEventActive(spec.pickUpActionEventId, true)
                g_inputBinding:setActionEventText(spec.pickUpActionEventId, spec.pickupText)
            end
        end
    end
    local tPipe, tIdx = aimedPluggedEnd(targetNode)
    if tPipe == nil or tIdx == nil then return end
    -- LEFT = unplug this end, the pipe falls
    spec._spsUnplugPipe, spec._spsUnplugEnd, spec._spsAimNode = tPipe, tIdx, targetNode
    if spec.pickUpActionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.pickUpActionEventId, true)
        g_inputBinding:setActionEventText(spec.pickUpActionEventId, g_i18n:getText("action_spsPhysDrop"))
    end
    -- RIGHT = unplug this end and carry it
    spec._spsMode, spec._spsPipe, spec._spsEnd = "takeEnd", tPipe, tIdx
    if spec.throwActionEventId ~= nil then
        g_inputBinding:setActionEventActive(spec.throwActionEventId, true)
        g_inputBinding:setActionEventText(spec.throwActionEventId, g_i18n:getText("action_spsPhysDisconnect"))
        spec._spsThrowActive = true
    end
end

-- Stow-cycle inputs: step the chosen holder; applied by the next onUpdate (which also re-reads the list).
function SPSHoseItemHands.onStowNext(hands, actionName, inputValue)
    local spec = hands.spec_hands
    if spec ~= nil then spec._spsStowCycle = (spec._spsStowCycle or 0) + 1 end
end
function SPSHoseItemHands.onStowPrev(hands, actionName, inputValue)
    local spec = hands.spec_hands
    if spec ~= nil then spec._spsStowCycle = (spec._spsStowCycle or 0) - 1 end
end
-- [SPS 1.0.1.8] "Free stuck pipe" (SPS_FREE_PIPE, default Left Alt + F): the held pipe ignores vehicles until let go
-- (SPSHoseItem.spsFreeHeldPipe). Only offered while an SPS pipe is in the hands and not freed yet (onUpdate).
function SPSHoseItemHands.onFreePipe(hands, actionName, inputValue)
    local spec = hands.spec_hands
    local pipe = spec ~= nil and pipeOf(spec.heldItemNode) or nil
    if pipe == nil or spec._spsFreedPipe == pipe then return end
    spec._spsFreedPipe = pipe
    if g_server ~= nil then
        SPSHoseItem.spsFreeHeldPipe(pipe)
    elseif SPSPhysPipeFreeEvent ~= nil then
        SPSPhysPipeFreeEvent.sendEvent(pipe)
    end
end

-- RIGHT mouse. The vanilla event is triggerDown + triggerAlways (called every frame while held):
-- one action per press, the button must come up (latch, see onUpdate) before the next.
function SPSHoseItemHands.onThrowAction(hands, superFunc, actionName, inputValue)
    local spec = hands.spec_hands
    local player = hands.getCarryingPlayer ~= nil and hands:getCarryingPlayer() or nil
    if spec ~= nil and player ~= nil and player.isOwner then spec._spsThrowSeenIdx = g_updateLoopIndex end
    if spec ~= nil and player ~= nil and player.isOwner and spec._spsMode ~= nil then
        if not spec._spsNeedRelease then
            spec._spsNeedRelease = true
            SPSHoseItemHands.doAction(hands, spec)
        end
        return
    end
    -- [SPS 1.0.1.8 diag] right mouse while HOLDING a pipe with no connectable end: say why (William:
    -- "unplugged into the hands, could not reconnect straight away").
    if spec ~= nil and player ~= nil and player.isOwner and physicalMode() and hands:getIsHoldingItem() then
        local newPress = not spec._spsNeedRelease
        spec._spsNeedRelease = true
        if newPress then
            local pipe = pipeOf(spec.heldItemNode)
            if pipe ~= nil then
                local mgr = g_slurryPipeManager
                local ci = pipe:spsGetComponentIndex(spec.heldItemNode)
                local only = endZoneOf(pipe, spec.heldItemNode)
                local parts = {}
                for idx = 1, 2 do
                    local e = pipe:spsGetEnd(idx)
                    if e ~= nil and nodeOk(e.node) then
                        local x, y, z = getWorldTranslation(e.node)
                        local c, _, _, d, miss = mgr:findCouplingForPhysPipeEnd(x, y, z, e.gender, 6.0)
                        parts[#parts + 1] = string.format("end%d(%s%s): %s", idx, e.gender, e.coupling ~= nil and ", plugged" or "",
                            c ~= nil and string.format("free coupling id=%s at %.2f m", tostring(c.id), d) or (miss or "no coupling within 6 m"))
                    end
                end
                spsInfo(string.format("[SPS PHYS] right mouse, holding body %s (end zone %s) but nothing to connect: %s",
                    tostring(ci), tostring(only), table.concat(parts, " | ")))
            end
        end
    end
    return superFunc(hands, actionName, inputValue)
end

-- LEFT mouse with empty hands aiming at the zone of a plugged-in end: unplug THAT end, let it fall.
function SPSHoseItemHands.onPickUpAction(hands, superFunc, actionName, inputValue)
    local spec = hands.spec_hands
    local player = hands.getCarryingPlayer ~= nil and hands:getCarryingPlayer() or nil
    local byKey = player ~= nil and player.targeter ~= nil and player.targeter.closestTargetsByKey or nil
    if spec ~= nil and player ~= nil and player.isOwner and spec._spsUnplugPipe ~= nil
       and spec.football == nil and not hands:getIsHoldingItem() then
        local target = byKey ~= nil and (byKey[HandToolHands] or byKey[SPSHoseItemHands]) or nil
        local pipe = spec._spsUnplugPipe
        if target ~= nil and pipeOf(target.node) == pipe then
            local idx = spec._spsUnplugEnd
            if idx ~= nil and g_slurryPipeManager ~= nil then
                if g_slurryPipeManager:physPipeDisconnect(pipe, idx) then
                    spsInfo(string.format("[SPS PHYS] left mouse: unplugged end %d, pipe dropped", idx))
                end
            end
            return
        end
    end
    -- plain pick-up of a pipe body beyond the vanilla 2 m (nothing vanilla-pickable is in range)
    if spec ~= nil and player ~= nil and player.isOwner and spec._spsFarTarget ~= nil
       and spec.football == nil and not hands:getIsHoldingItem() and (byKey == nil or byKey[HandToolHands] == nil) then
        hands:pickUpTarget(spec._spsFarTarget)
        return
    end
    return superFunc(hands, actionName, inputValue)
end

function SPSHoseItemHands.doAction(hands, spec)
    local mgr = g_slurryPipeManager
    if mgr == nil or spec._spsPipe == nil then return end
    local pipe, idx = spec._spsPipe, spec._spsEnd
    if spec._spsMode == "connect" then
        if hands:getIsHoldingItem() and hands.dropHeldItem ~= nil then
            hands:dropHeldItem()   -- the plugged body goes kinematic: it must not stay jointed to the hand
        end
        mgr:physPipeConnect(pipe, idx, spec._spsOwner, spec._spsIsPlaceable, spec._spsCoupling.id, spec._spsCoupling.isLiquidLane == true)
        spsInfo(string.format("[SPS PHYS] right mouse: connect end %d", idx))
    elseif spec._spsMode == "join" then
        if hands:getIsHoldingItem() and hands.dropHeldItem ~= nil then
            hands:dropHeldItem()
        end
        mgr:physPipeJoin(pipe, idx, spec._spsOtherPipe, spec._spsOtherEnd)
        spsInfo(string.format("[SPS PHYS] right mouse: join end %d to another pipe's end %d", idx, spec._spsOtherEnd or 0))
    elseif spec._spsMode == "stow" then
        if hands:getIsHoldingItem() and hands.dropHeldItem ~= nil then
            hands:dropHeldItem()   -- the bodies go kinematic on the rack: the pipe must not stay jointed to the hand
        end
        local ph, sl = spec._spsHolder, spec._spsSlot
        if ph ~= nil then
            mgr:physPipeStow(pipe, ph.vehicle, ph.id, sl ~= nil and sl.name or nil)
            spsInfo(string.format("[SPS PHYS] right mouse: stow pipe in slot '%s' of holder %d of %s", tostring(sl and sl.name), ph.id or 0,
                tostring(ph.vehicle and ph.vehicle.configFileName)))
        end
    elseif spec._spsMode == "dsStow" then
        if hands:getIsHoldingItem() and hands.dropHeldItem ~= nil then
            hands:dropHeldItem()   -- the body goes kinematic on the frame: it must not stay jointed to the hand
        end
        local dh = spec._spsHolder
        if dh ~= nil and mgr.dsStow ~= nil then
            mgr:dsStow(pipe, dh.vehicle, dh.id)
            spsInfo(string.format("[SPS PHYS] right mouse: place the docking station on holder %d of %s", dh.id or 0,
                tostring(dh.vehicle and dh.vehicle.configFileName)))
        end
    elseif spec._spsMode == "takeEnd" then
        mgr:physPipeDisconnect(pipe, idx)
        -- ...and straight into the hands. Take the body the player AIMED at (a dynamic neighbour of the
        -- end - the end body itself was kinematic a moment ago and may not be pickable this frame); the
        -- pickUpTarget hook in SPSHoseItem makes the hands hold that body.
        local e = pipe:spsGetEnd(idx)
        local node = spec._spsAimNode
        if not nodeOk(node) or pipe:spsGetComponentIndex(node) == nil then
            node = (e ~= nil and pipe.components[e.comp] ~= nil) and pipe.components[e.comp].node or nil
        end
        if e ~= nil and nodeOk(node) and nodeOk(e.node) and hands.pickUpTarget ~= nil then
            local x, y, z = getWorldTranslation(node)
            local player = hands:getCarryingPlayer()
            local d = 1.5
            if player ~= nil and nodeOk(player.rootNode) then
                local px, py, pz = getWorldTranslation(player.rootNode)
                d = math.max(0.8, MathUtil.vector3Length(px - x, py - y, pz - z))
            end
            hands:pickUpTarget({ node = node, x = x, y = y, z = z, distance = d })
            -- (the pickUpTarget hook in SPSHoseItem is an appendedFunction, which drops the return value - ask the hands)
            local ok = hands:getIsHoldingItem()
            print(string.format("[SPS PHYS] right mouse: unplugged end %d and %s", idx, ok and "took it into the hands" or "could NOT pick it up"))
        end
    end
end

-- ---------------------------------------------------------------------------
if HandToolHands ~= nil and not SPSHoseItemHands._hooked then
    SPSHoseItemHands._hooked = true
    HandToolHands.onUpdate       = Utils.appendedFunction(HandToolHands.onUpdate, SPSHoseItemHands.onUpdate)
    HandToolHands.onThrowAction  = Utils.overwrittenFunction(HandToolHands.onThrowAction, SPSHoseItemHands.onThrowAction)
    HandToolHands.onPickUpAction = Utils.overwrittenFunction(HandToolHands.onPickUpAction, SPSHoseItemHands.onPickUpAction)
    -- the long pipe-only target type lives exactly as long as the vanilla one (onHeldStart / onHeldEnd :298-312);
    -- so do the stow-cycle action events (SPS_STOW_NEXT / PREV: mouse wheel or , . - rebindable)
    HandToolHands.onHeldStart = Utils.appendedFunction(HandToolHands.onHeldStart, function(hands)
        local player = hands.getCarryingPlayer ~= nil and hands:getCarryingPlayer() or nil
        if player == nil or not player.isOwner or player.targeter == nil then return end
        player.targeter:addTargetType(SPSHoseItemHands, HandToolHands.TARGET_MASK, 0.5, SPSHoseItemHands.PIPE_TARGET_DISTANCE)
        player.targeter:addFilterToTargetType(SPSHoseItemHands, function(hitNode) return pipeOf(hitNode) ~= nil end)
        local spec = hands.spec_hands
        if spec ~= nil and InputAction.SPS_STOW_NEXT ~= nil and spec._spsStowNextId == nil then
            local _, idN = g_inputBinding:registerActionEvent(InputAction.SPS_STOW_NEXT, hands, SPSHoseItemHands.onStowNext, false, true, false, false)
            local _, idP = g_inputBinding:registerActionEvent(InputAction.SPS_STOW_PREV, hands, SPSHoseItemHands.onStowPrev, false, true, false, false)
            spec._spsStowNextId, spec._spsStowPrevId = idN, idP
            if idN ~= nil then g_inputBinding:setActionEventTextPriority(idN, GS_PRIO_LOW) end
            if idP ~= nil then g_inputBinding:setActionEventTextPriority(idP, GS_PRIO_LOW) end
        end
        if spec ~= nil and InputAction.SPS_FREE_PIPE ~= nil and spec._spsFreeId == nil then
            local _, idF = g_inputBinding:registerActionEvent(InputAction.SPS_FREE_PIPE, hands, SPSHoseItemHands.onFreePipe, false, true, false, false)
            spec._spsFreeId = idF
            if idF ~= nil then
                g_inputBinding:setActionEventText(idF, g_i18n:getText("input_SPS_FREE_PIPE"))
                g_inputBinding:setActionEventTextPriority(idF, GS_PRIO_NORMAL)
                g_inputBinding:setActionEventActive(idF, false)
            end
        end
    end)
    HandToolHands.onHeldEnd = Utils.prependedFunction(HandToolHands.onHeldEnd, function(hands)
        local player = hands.getCarryingPlayer ~= nil and hands:getCarryingPlayer() or nil
        if player == nil or not player.isOwner or player.targeter == nil then return end
        if player.targeter:getHasTargetedKey(SPSHoseItemHands) then player.targeter:removeTargetType(SPSHoseItemHands) end
        local spec = hands.spec_hands
        if spec ~= nil then
            if spec._spsStowNextId ~= nil then g_inputBinding:removeActionEvent(spec._spsStowNextId) end
            if spec._spsStowPrevId ~= nil then g_inputBinding:removeActionEvent(spec._spsStowPrevId) end
            spec._spsStowNextId, spec._spsStowPrevId, spec._spsStowChoice = nil, nil, nil
            if spec._spsFreeId ~= nil then g_inputBinding:removeActionEvent(spec._spsFreeId) end
            spec._spsFreeId, spec._spsFreedPipe = nil, nil
        end
    end)
end
