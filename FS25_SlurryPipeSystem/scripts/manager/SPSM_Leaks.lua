-- ===========================================================================
-- FS25_SlurryPipeSystem - SPSM_Leaks.lua  (SlurryPipeManager extension)
-- [SPS 1.0.2.0] LEAKS WITH THE VALVE LEFT OPEN (William 2026-11-02). "Pipe leakage" setting on, PHYSICAL pipe mode:
--
--   SERVER tickLeaks(dt):
--     * slurry STORES (registeredPlaceables storeCouplings): a store coupler whose own valve is open with nothing
--       connected - no pipe, or a pipe whose far end lies free on the ground - drains the store by gravity
--       (LEAK_STORE_LPS) onto the ground under the valve / pipe end -> SPSSpill puddle.
--     * 80 mm LANE fittings (water / milk): the barn's coupler (ball valve open, nothing connected) drains the barn
--       (milk out of a milk lane, water out of a trough lane); a tanker's liquid connector (ball valve open, pump
--       off, nothing connected) drains the tank. LEAK_LANE_LPS.
--     Tanker SLURRY couplings are NOT here: their leak runs through the normal flow session (SPSM_Flow
--     resolveExternalSource GROUND_SPILL - pump / gravity as the flow resolver decides).
--
--   EVERY PEER updateLeakStreams(dt): the same four coupling kinds, judged from the synced valve / plug / level state
--     each client already has, drive the leak stream visuals (SPSLeakEffect) - stream from the leak node down to the
--     surface the puddle sits on, slurry / water / milk material.
-- Debug: SPSDebugConfig channel "SPSM_Leaks".
-- ===========================================================================
SlurryPipeManager.LEAK_STORE_LPS = 150    -- L/s gravity leak from a store's open valve
SlurryPipeManager.LEAK_LANE_LPS  = 80     -- L/s gravity leak from an open 80 mm fitting

local function leakLog(fmt, ...)
    if SPSDebugConfig ~= nil and SPSDebugConfig.isOn ~= nil and SPSDebugConfig.isOn("SPSM_Leaks") then
        print("[SPS LEAK] " .. string.format(fmt, ...))
    end
end

local function ftName(ft)
    return tostring(g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeNameByIndex(ft) or ft)
end

-- the mod's pipe material for a liquid (slurry default; water; milk) - leak streams (SPSLeakEffect) and the fill-arm
-- stream (SPSM_Flow detectArmConnection) both ask here
function SlurryPipeManager.pipeEffectMaterialFor(fillType)
    if fillType == FillType.WATER then return g_spsWaterMaterial or g_spsSlurryMaterial end
    if fillType ~= nil and g_fillTypeManager ~= nil then
        local name = g_fillTypeManager:getFillTypeNameByIndex(fillType)
        if name == "MILK" or name == "BUFFALOMILK" then return g_spsMilkMaterial or g_spsWaterMaterial or g_spsSlurryMaterial end
        -- [SPS CHEM 2026-11-09] sprayer liquids pour like water, not slurry (SPSSpill.typeInfo keeps the same rule)
        if SPSSpill ~= nil and SPSSpill.typeInfo ~= nil then
            local info = SPSSpill.typeInfo(fillType)
            if info ~= nil and info.child == 1 then return g_spsWaterMaterial or g_spsSlurryMaterial end
        end
    end
    return g_spsSlurryMaterial
end

-- vehicle slurry coupling: is its valve open for a leak (same rule as hasActiveCouplingConnection / resolveExternalSource)
local function slurryLeakValveOpen(entry, c)
    return c.valveOpen or (c.valveType == SPS_VALVE_TYPE_NONE and not c.valveFromRearControl)
        or (c.valveFromRearControl and entry.state ~= nil and entry.state.valveOpen == true)
end

-- a barn lane coupler: the liquid it would leak and the barn's level of it
function SlurryPipeManager:_leakBarnLaneFillType(pEntry, c)
    local lane = c.lane
    if lane == nil or pEntry.storage == nil then return nil, 0 end
    if lane.direction == "FROM_BARN" and self._llBarnMilkType ~= nil then
        local ft, lvl = self:_llBarnMilkType(pEntry.placeable, pEntry.storage, lane)
        if ft ~= nil and (lvl or 0) > 0 then return ft, lvl end
        return nil, 0
    end
    for _, name in ipairs(lane.fillTypeNames or {}) do
        local ft = g_fillTypeManager:getFillTypeIndexByName(name)
        if ft ~= nil then
            local lvl = pEntry.storage:getFillLevel(ft) or 0
            if lvl > 0 then return ft, lvl end
        end
    end
    return nil, 0
end

-- ---------------------------------------------------------------------------
-- SERVER: the litres
-- ---------------------------------------------------------------------------
function SlurryPipeManager:tickLeaks(dt)
    if g_server == nil or self.spillEnabled ~= true or self.physicalPipesEnabled ~= true then return end
    if SPSSpill == nil or SPSSpill.addLitres == nil or self.physFreeEndSpillPos == nil then return end
    local s = (dt or 0) * 0.001
    if s <= 0 then return end

    -- 1. slurry stores
    for _, pEntry in ipairs(self.registeredPlaceables) do
        if pEntry.storeCouplings ~= nil then
            for _, sc in ipairs(pEntry.storeCouplings) do
                if sc.valveOpen and not sc.isConnected and sc.isDeployed ~= false then
                    local se = sc.sourceEntry
                    if se ~= nil and se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE and se.storage ~= nil then
                        local x, ty, z = self:physFreeEndSpillPos(sc)
                        if x ~= nil then
                            local ft = self:_resolveSourceFillType(se)
                            local lvl = ft ~= nil and (se.storage:getFillLevel(ft) or 0) or 0
                            local amt = math.min(SlurryPipeManager.LEAK_STORE_LPS * s, lvl)
                            if amt > 0 then
                                self:removeFromSource(se, amt, ft, sc.placeable)   -- the store's own farm: access granted
                                SPSSpill.addLitres(x, ty, z, amt, ft)
                                if not sc._spsLeakLogged then
                                    sc._spsLeakLogged = true
                                    print(string.format("[SPS LEAK] %s coupling id=%s LEAKING %s onto the ground (store valve open, %s)",
                                        tostring(pEntry.placeable and pEntry.placeable.configFileName), tostring(sc.id), ftName(ft),
                                        sc.physPipe ~= nil and "pipe end free" or "no pipe"))
                                end
                            end
                        else
                            sc._spsLeakLogged = nil
                        end
                    end
                else
                    sc._spsLeakLogged = nil
                end
            end
        end
    end

    -- 2. barn lane couplers (water / milk)
    for _, pEntry in ipairs(self.registeredLiquidLanePlaceables or {}) do
        for _, c in ipairs(pEntry.couplings or {}) do
            if c.ballValveOpen and not c.isConnected then
                local x, ty, z = self:physFreeEndSpillPos(c)
                if x ~= nil then
                    local ft, lvl = self:_leakBarnLaneFillType(pEntry, c)
                    local amt = ft ~= nil and math.min(SlurryPipeManager.LEAK_LANE_LPS * s, lvl) or 0
                    if amt > 0 then
                        local placeable = pEntry.placeable
                        local drawn = amt
                        if placeable.removeHusbandryFillLevel ~= nil then
                            local farmId = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
                            local remaining = placeable:removeHusbandryFillLevel(farmId, amt, ft) or amt
                            drawn = amt - remaining
                        else
                            local old = pEntry.storage:getFillLevel(ft) or 0
                            pEntry.storage:setFillLevel(math.max(0, old - amt), ft)
                            drawn = old - (pEntry.storage:getFillLevel(ft) or 0)
                        end
                        if drawn > 0 then
                            SPSSpill.addLitres(x, ty, z, drawn, ft)
                            if not c._spsLeakLogged then
                                c._spsLeakLogged = true
                                print(string.format("[SPS LEAK] %s lane coupler id=%s LEAKING %s onto the ground (fitting valve open, %s)",
                                    tostring(placeable and placeable.configFileName), tostring(c.id), ftName(ft),
                                    c.physPipe ~= nil and "pipe end free" or "no pipe"))
                            end
                        end
                    end
                else
                    c._spsLeakLogged = nil
                end
            else
                c._spsLeakLogged = nil
            end
        end
    end

    -- 3. tanker liquid connectors (water / milk tank), pump off
    for _, entry in ipairs(self.registeredLiquidLaneVehicles or {}) do
        local vehicle = entry.object
        if vehicle ~= nil and not (entry.state ~= nil and entry.state.valveOpen) then
            for _, c in ipairs(entry.couplings or {}) do
                if c.ballValveOpen and not c.isConnected and c.bridgeCoupling == nil then
                    local x, ty, z = self:physFreeEndSpillPos(c)
                    if x ~= nil and vehicle.getFillUnitFillLevel ~= nil then
                        local fui = c.fillUnitIndex or 1
                        local lvl = vehicle:getFillUnitFillLevel(fui) or 0
                        local ft  = vehicle:getFillUnitFillType(fui)
                        if lvl > 0 and ft ~= nil and ft ~= FillType.UNKNOWN then
                            local amt = math.min(SlurryPipeManager.LEAK_LANE_LPS * s, lvl)
                            self:removeFromSource({ type = "FILL_UNIT_ONLY", vehicle = vehicle, fillUnitIndex = fui }, amt, ft, vehicle)
                            SPSSpill.addLitres(x, ty, z, amt, ft)
                            if not c._spsLeakLogged then
                                c._spsLeakLogged = true
                                print(string.format("[SPS LEAK] %s liquid connector id=%s LEAKING %s onto the ground (fitting valve open, %s)",
                                    tostring(vehicle.configFileName), tostring(c.id), ftName(ft),
                                    c.physPipe ~= nil and "pipe end free" or "no pipe"))
                            end
                        end
                    else
                        c._spsLeakLogged = nil
                    end
                else
                    c._spsLeakLogged = nil
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- EVERY PEER: the streams
-- ---------------------------------------------------------------------------
-- The stream's frame at a leak point: outward flow axis (unit, world) + tube scale for the bore. A pipe end hands its
-- axis in (physFreeEndSpillPos). A SOCKET: the pipe end is placed along the socket's +-Z (SPSHoseItem spsPlaceEndAt),
-- the sign that points at the coupler's arcs (the player's side = the front of the coupler) is "out"; a coupler with
-- no arcs (80 mm fittings) takes the sign that points away from the owner's root node. William 2026-11-03: "a stream
-- that fits the hole, remembering not all couplers are level" - the stream leaves ALONG the socket and gravity bends it.
-- Returns { dx, dy, dz (outward axis), scale, sx, sy, sz (the stream's START, world) }. Start (William 2026-11-03): an
-- 80 mm fitting's in/out node sits where the hose end plugs, the stream starts LANE_START_Z further along the node's
-- own Z; a slurry coupler's / pipe end's stream starts START_INSET back inside the bore.
SlurryPipeManager.LEAK_LANE_START_Z = 0.055
SlurryPipeManager.LEAK_START_INSET  = 0.08
function SlurryPipeManager:leakStreamFrame(c, owner, node, axX, axY, axZ)
    local scale = c.isLiquidLane and 0.36 or 0.6        -- tube is 0.22 m across: 80 mm fitting / 150 mm coupler
    local sx, sy, sz = getWorldTranslation(node)
    if axX ~= nil then   -- a pipe end: axis known
        local k = SlurryPipeManager.LEAK_START_INSET
        return { dx = axX, dy = axY, dz = axZ, scale = scale, sx = sx - axX * k, sy = sy - axY * k, sz = sz - axZ * k }
    end
    local zx, zy, zz = localDirectionToWorld(node, 0, 0, 1)
    if c.isLiquidLane then
        local k = SlurryPipeManager.LEAK_LANE_START_Z
        sx, sy, sz = sx + zx * k, sy + zy * k, sz + zz * k
    end
    local rx, ry, rz
    if not c.isLiquidLane and self._getCouplingArcNodes ~= nil then
        local _, a1, a2 = self:_getCouplingArcNodes(c)
        if a1 ~= nil and a2 ~= nil then
            local x1, y1, z1 = getWorldTranslation(a1)
            local x2, y2, z2 = getWorldTranslation(a2)
            rx, ry, rz = (x1 + x2) * 0.5 - sx, (y1 + y2) * 0.5 - sy, (z1 + z2) * 0.5 - sz
        end
    end
    if rx == nil and owner ~= nil and owner.rootNode ~= nil and owner.rootNode ~= 0 and entityExists(owner.rootNode) then
        local ox, oy, oz = getWorldTranslation(owner.rootNode)
        rx, ry, rz = sx - ox, sy - oy, sz - oz
    end
    local sign = 1
    if rx ~= nil and (zx * rx + zy * ry + zz * rz) < 0 then sign = -1 end
    local dx, dy, dz = zx * sign, zy * sign, zz * sign
    if not c.isLiquidLane then
        local k = SlurryPipeManager.LEAK_START_INSET
        sx, sy, sz = sx - dx * k, sy - dy * k, sz - dz * k
    end
    return { dx = dx, dy = dy, dz = dz, scale = scale, sx = sx, sy = sy, sz = sz }
end

-- ---------------------------------------------------------------------------
-- The stream curve (shared by the visual and the puddle placement). PIPE_EFFECT shader: the tube is rotated
-- progressively along its length by `bend` (end rotation = bend, toward local -Y = down-in-plane), so the END TANGENT
-- overshoots the end rotation: tangent angle alpha(bend) = atan2(sin b + b cos b, cos b - b sin b). William 2026-11-03:
-- the end must point STRAIGHT DOWN -> solve alpha(bend) = beta (beta = angle from the flow axis to straight down), then
-- the length that puts the end on the surface `h` below the start is D = h / cos(bend - beta), and the end lands
-- D * (cos b - sin b * cot beta) along the axis's horizontal direction in FRONT of the start (the puddle goes there).
-- Returns bend, length, forwardOffset (m along the horizontal flow direction).
-- ---------------------------------------------------------------------------
SlurryPipeManager.LEAK_MAX_BEND = 1.6
function SlurryPipeManager.leakStreamSolve(dy, h)
    local beta = math.acos(math.max(-1, math.min(1, -(dy or -1))))   -- 0 = pointing down, pi/2 = level
    if beta < 0.05 or h == nil or h <= 0 then return 0, (h or 0), 0 end
    local lo, hi = 0, math.min(beta, SlurryPipeManager.LEAK_MAX_BEND)
    for _ = 1, 18 do
        local b = (lo + hi) * 0.5
        local alpha = math.atan2(math.sin(b) + b * math.cos(b), math.cos(b) - b * math.sin(b))
        if alpha < beta then lo = b else hi = b end
    end
    local b = (lo + hi) * 0.5
    local c = math.cos(b - beta)
    if c < 0.2 then c = 0.2 end
    local D = h / c
    local fwd = D * (math.cos(b) - math.sin(b) * (math.cos(beta) / math.sin(beta)))
    return b, D, fwd
end

function SlurryPipeManager:updateLeakStreams(dt)
    if SPSLeakEffect == nil or g_client == nil then return end
    -- [SPS 1.0.2.0] 2026-11-05: `phys` alone drives the tanker streams, because a pour INTO a pit shows whatever
    -- "Pipe leakage" says (William: "the pipe had no effect at the end when in the pit"); `on` = the ground leaks.
    local phys = self.physicalPipesEnabled == true and self.physFreeEndSpillPos ~= nil
    local on = self.spillEnabled == true and phys
    SPSLeakEffect.beginFrame()
    if phys then
        -- a) tanker slurry couplings: valve open for a leak, flow resolver says DISCHARGE with something to move
        for _, entry in ipairs(self.registeredVehicles) do
            local vehicle = entry.vehicle
            if vehicle ~= nil and entry.couplingEntries ~= nil then
                for _, c in ipairs(entry.couplingEntries) do
                    if not c.isConnected and slurryLeakValveOpen(entry, c) then
                        -- ground leak first; else a pipe end / bare coupler mouth above a pit's surface (pitSe = that store)
                        local x, ty, z, node, ny, ax, ay, az, fr, pitSe
                        if on then x, ty, z, node, ny, ax, ay, az, fr = self:physFreeEndSpillPos(c) end
                        if x == nil then x, ty, z, node, ny, ax, ay, az, fr, pitSe = self:physFreeEndSpillPos(c, true) end
                        if x ~= nil then
                            local fui = c.fillUnitIndex or 1
                            local lvl = vehicle.getFillUnitFillLevel ~= nil and (vehicle:getFillUnitFillLevel(fui) or 0) or 0
                            if lvl > SlurryPipeManager.EFFECT_EMPTY_LITRES then
                                local state = entry.state or self:getVehicleState(vehicle)
                                local dir, scalar = nil, 0
                                if state ~= nil then dir, scalar = self:resolveCouplingFlow(vehicle, state, self:_isPumpOn(vehicle), true) end
                                local ft = vehicle:getFillUnitFillType(fui)
                                -- a full pit takes nothing (transferDischarge moves no litres): no stream either
                                local pitFull = pitSe ~= nil and pitSe.storage ~= nil and pitSe.storage.getFreeCapacity ~= nil
                                    and (pitSe.storage:getFreeCapacity(self:resolveStoreDepositFillType(pitSe, ft)) or 0) <= 0
                                if dir == SPS_DIRECTION_DISCHARGE and (scalar or 0) > 0 and not pitFull then
                                    SPSLeakEffect.set(c, vehicle, node, ny, ty, ft,
                                        fr or self:leakStreamFrame(c, vehicle, node, ax, ay, az))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if on then
        -- b) slurry stores
        for _, pEntry in ipairs(self.registeredPlaceables) do
            if pEntry.storeCouplings ~= nil then
                for _, sc in ipairs(pEntry.storeCouplings) do
                    if sc.valveOpen and not sc.isConnected and sc.isDeployed ~= false then
                        local se = sc.sourceEntry
                        if se ~= nil and se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE and se.storage ~= nil then
                            local x, ty, z, node, ny, ax, ay, az, fr = self:physFreeEndSpillPos(sc)
                            if x ~= nil then
                                local ft = self:_resolveSourceFillType(se)
                                if ft ~= nil and (se.storage:getFillLevel(ft) or 0) > SlurryPipeManager.EFFECT_EMPTY_LITRES then
                                    SPSLeakEffect.set(sc, pEntry.placeable, node, ny, ty, ft,
                                        fr or self:leakStreamFrame(sc, pEntry.placeable, node, ax, ay, az))
                                end
                            end
                        end
                    end
                end
            end
        end
        -- c) barn lane couplers
        for _, pEntry in ipairs(self.registeredLiquidLanePlaceables or {}) do
            for _, c in ipairs(pEntry.couplings or {}) do
                if c.ballValveOpen and not c.isConnected then
                    local x, ty, z, node, ny, ax, ay, az, fr = self:physFreeEndSpillPos(c)
                    if x ~= nil then
                        local ft, lvl = self:_leakBarnLaneFillType(pEntry, c)
                        if ft ~= nil and lvl > SlurryPipeManager.EFFECT_EMPTY_LITRES then
                            SPSLeakEffect.set(c, pEntry.placeable, node, ny, ty, ft,
                                fr or self:leakStreamFrame(c, pEntry.placeable, node, ax, ay, az))
                        end
                    end
                end
            end
        end
        -- d) tanker liquid connectors, pump off
        for _, entry in ipairs(self.registeredLiquidLaneVehicles or {}) do
            local vehicle = entry.object
            if vehicle ~= nil and not (entry.state ~= nil and entry.state.valveOpen) then
                for _, c in ipairs(entry.couplings or {}) do
                    if c.ballValveOpen and not c.isConnected and c.bridgeCoupling == nil then
                        local x, ty, z, node, ny, ax, ay, az, fr = self:physFreeEndSpillPos(c)
                        if x ~= nil and vehicle.getFillUnitFillLevel ~= nil then
                            local fui = c.fillUnitIndex or 1
                            local lvl = vehicle:getFillUnitFillLevel(fui) or 0
                            local ft  = vehicle:getFillUnitFillType(fui)
                            if lvl > SlurryPipeManager.EFFECT_EMPTY_LITRES and ft ~= nil and ft ~= FillType.UNKNOWN then
                                SPSLeakEffect.set(c, vehicle, node, ny, ty, ft,
                                    fr or self:leakStreamFrame(c, vehicle, node, ax, ay, az))
                            end
                        end
                    end
                end
            end
        end
    end
    -- [SPS 2026-11-09] 550 bowser wash hose pour. [2026-11-10] in BOTH pipe modes: gated on `phys` the original-mode pour
    -- moved litres (puddles in the log 11:09) with no stream at all (William: "no pour"); the function gates on its own state
    if self._llLeakStreams ~= nil then self:_llLeakStreams() end
    SPSLeakEffect.endFrame()
end
