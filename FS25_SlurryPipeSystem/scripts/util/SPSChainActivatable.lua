-- FS25_SlurryPipeSystem 
-- Author: Oscar Mods 
-- Version: 1.0.0.0

-- SPSChainActivatable.lua
-- FS25_SlurryPipeSystem

SPSChainActivatable = {}
SPSChainActivatable.__index = SPSChainActivatable

SPSChainActivatable.ACTIVATE_RADIUS = 1.5
SPSChainActivatable.HOLD_THRESHOLD  = 0.8

function SPSChainActivatable.new(chain, arcIndex, coupling)
    local self          = setmetatable({}, SPSChainActivatable)
    self.chain          = chain
    self.arcIndex       = arcIndex   -- 0 = anchor, N = locked segment end
    self.coupling       = coupling   -- only set for arcIndex == 0
    self.activateText   = ""
    self._holdTime      = 0
    self._isHolding     = false
    self._longFired     = false
    self._actionEventId = nil
    self.isEndActivatable = false  -- true = detNode01 (end of pipe), false = pipeRoot (start of pipe)
    return self
end

function SPSChainActivatable:delete()
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

function SPSChainActivatable:getIsActivatable()
    if g_localPlayer == nil then return false end
    local node = self:_getNode()
    if node == nil or node == 0 then return false end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local cx, cy, cz = getWorldTranslation(node)
    local dist = MathUtil.vector3Length(px - cx, py - cy, pz - cz)
    -- Anchor while live pipe being walked: larger radius so player can finalise
    local radius = SPSChainActivatable.ACTIVATE_RADIUS
    if self.arcIndex == 0 and self.chain ~= nil and self.chain.liveSegment ~= nil then
        radius = 3.5
    end
    if dist > radius then return false end
    -- Anchor: hide when another coupling arc overlaps (SPSPipeActivatable handles connect)
    -- Skip this when a live pipe is being walked — finalisePipe must show regardless
    local isLaying = self.chain ~= nil and self.chain.liveSegment ~= nil
    if self.arcIndex == 0 and self.coupling ~= nil and g_slurryPipeManager ~= nil and not isLaying then
        if g_slurryPipeManager:findOverlappingCoupler(self.coupling) ~= nil then return false end
    end
    -- Terminus: hide when live pipe is being walked
    if self.arcIndex > 0 and self.chain ~= nil and self.chain.liveSegment ~= nil then
        return false
    end
    -- End activatable only: hide when a vehicle arc overlaps the chain coupling
    -- (SPSPipeActivatable handles the tanker connect in that case)
    if self.isEndActivatable and self.arcIndex > 0 and self.chain ~= nil and g_slurryPipeManager ~= nil then
        local seg = self.chain.segments[self.arcIndex]
        if seg ~= nil and seg.chainCoupling ~= nil then
            -- Only suppress for overlap check when not already connected
            -- (if connected, we need to show disconnect — don't hide the activatable)
            if not seg.chainCoupling.isConnected then
                if g_slurryPipeManager:findOverlappingCoupler(seg.chainCoupling) ~= nil then return false end
            end
        end
    end
    local state = self:_getState()
    if state == nil then return false end
    return true
end

function SPSChainActivatable:getDistance(posX, posY, posZ)
    local node = self:_getNode()
    if node == nil or node == 0 then return math.huge end
    local cx, cy, cz = getWorldTranslation(node)
    return MathUtil.vector3Length(posX - cx, posY - cy, posZ - cz)
end

function SPSChainActivatable:activate()
    self._holdTime  = 0
    self._isHolding = false
    self._longFired = false
    self.activateText = self:_buildActivateText()
end

function SPSChainActivatable:deactivate()
    self._isHolding = false
    self._holdTime  = 0
    self._longFired = false
end

function SPSChainActivatable:update(dt)
    self.activateText = self:_buildActivateText()
    if self._actionEventId ~= nil then
        g_inputBinding:setActionEventText(self._actionEventId, self.activateText)
    end
    if self._isHolding and not self._longFired then
        self._holdTime = self._holdTime + dt * 0.001
        if self._holdTime >= SPSChainActivatable.HOLD_THRESHOLD then
            self._longFired = true
            self:_onLongPress()
        end
    end
end

function SPSChainActivatable:run()
    self:_onShortPress()
end

function SPSChainActivatable:registerCustomInput(inputContext)
    self._holdTime  = 0
    self._isHolding = false
    self._longFired = false
    local _, id = g_inputBinding:registerActionEvent(
        InputAction.ACTIVATE_OBJECT, self, self._onActivateInput,
        true, true, false, true, nil, true, false)
    if id ~= nil then
        self._actionEventId = id
        g_inputBinding:setActionEventText(id, self:_buildActivateText())
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(id, true)
    end
end

function SPSChainActivatable:removeCustomInput()
    if self._actionEventId ~= nil then
        g_inputBinding:removeActionEvent(self._actionEventId)
        self._actionEventId = nil
    end
    self._isHolding = false
    self._holdTime  = 0
    self._longFired = false
end

function SPSChainActivatable:_onActivateInput(actionName, inputValue, callbackState, isAnalog)
    if inputValue > 0 then
        self._isHolding = true
        self._holdTime  = 0
        self._longFired = false
    else
        if self._isHolding and not self._longFired then self:_onShortPress() end
        self._isHolding = false
        self._holdTime  = 0
        self._longFired = false
    end
end

function SPSChainActivatable:_onShortPress()
    local state = self:_getState()
    print("[SPS SPCA] ChainActivatable shortPress arc=" .. self.arcIndex .. " isEnd=" .. tostring(self.isEndActivatable) .. " state=" .. tostring(state))
    if state == "layFirstPipe" then
        -- Start laying from anchor coupler
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onChainStartLaying(self.coupling, self)
        end
    elseif state == "finalisePipe" then
        -- Short press: lock only if player has walked at least 0.5m from pipe start
        if self.chain ~= nil and self.chain.liveSegment ~= nil then
            local liveSeg = self.chain.liveSegment
            if liveSeg.startX ~= nil and g_localPlayer ~= nil then
                local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
                local d = math.sqrt((px - liveSeg.startX)^2 + (pz - liveSeg.startZ)^2)
                if d >= 0.5 then
                    self.chain:lockLivePipe()
                else
                    if g_currentMission ~= nil then
                        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsPipeTooShort"), 1500)
                    end
                end
            end
        end
    elseif state == "layMorePipe" then
        if self.chain ~= nil then
            local lastSeg = self.chain.segments[#self.chain.segments]
            if lastSeg ~= nil and lastSeg.endConnectors ~= nil then
                local ex, ey, ez = getWorldTranslation(lastSeg.endConnectors)
                local _, ery, _  = getWorldRotation(lastSeg.endConnectors)
                self.chain:startLaying(ex, ey, ez, ery)
            end
        end
    elseif state == "removePipeChain" then
        if self.arcIndex == 0 then
            -- Remove all segments
            self.chain:removeFromIndex(1)
            if g_slurryPipeManager ~= nil then
                g_slurryPipeManager:onChainEmpty(self.chain, self.coupling)
            end
            self.chain = nil
        else
            -- Remove from this segment onwards
            self.chain:removeFromIndex(self.arcIndex)
        end
    elseif state == "dockingStationOpen" or state == "dockingStationClosed" then
        self.chain:removeDockingStation()
        if #self.chain.segments == 0 and self.arcIndex == 0 then
            if g_slurryPipeManager ~= nil then
                g_slurryPipeManager:onChainEmpty(self.chain, self.coupling)
            end
            self.chain = nil
        end
    elseif state == "connectedValveClosed" or state == "connectedHydraulicValve" then
        local seg = self.chain.segments[self.arcIndex]
        if seg ~= nil and seg.chainCoupling ~= nil and g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onCouplerDisconnect(nil, seg.chainCoupling)
        end
    end
end

function SPSChainActivatable:_onLongPress()
    local state = self:_getState()
    print("[SPS SPCA] ChainActivatable longPress arc=" .. self.arcIndex .. " isEnd=" .. tostring(self.isEndActivatable) .. " state=" .. tostring(state))
    if state == "finalisePipe" then
        -- Long press while laying: cancel the live pipe entirely
        if self.chain ~= nil then
            self.chain:cancelLivePipe()
            print("[SPS SPCA] ChainActivatable: cancelled live pipe via long press")
        end
    elseif state == "deployCoupling" then
        if g_slurryPipeManager ~= nil then
            g_slurryPipeManager:onCouplingDeploy(self.coupling)
        end
    elseif state == "layMorePipe" or state == "layFirstPipe" then
        -- Deployable coupling deployed with no chain: long press removes coupling
        if state == "layFirstPipe" and self.coupling ~= nil
        and self.coupling.deployable and self.coupling.isDeployed then
            if g_slurryPipeManager ~= nil then
                g_slurryPipeManager:onCouplingUndeploy(self.coupling)
            end
        -- Non-deployable or chain exists: long press adds docking station
        elseif self.chain ~= nil and self.chain.dockingStation == nil then
            self.chain:addDockingStation()
        end
    elseif state == "dockingStationClosed" then
        if self.chain ~= nil and self.chain.anchorCoupling ~= nil then
            self.chain.anchorCoupling.valveOpen = true
        end
    elseif state == "dockingStationOpen" then
        if self.chain ~= nil and self.chain.anchorCoupling ~= nil then
            self.chain.anchorCoupling.valveOpen = false
        end
    elseif state == "connectedValveClosed" then
        local seg = self.chain.segments[self.arcIndex]
        if seg ~= nil and seg.chainCoupling ~= nil then
            local cc = seg.chainCoupling
            cc.valveOpen = true
            if cc.connectedPartnerCoupling ~= nil then
                cc.connectedPartnerCoupling.valveOpen = true
            end
            -- Propagate open back to anchor so hasActiveCouplingConnection fires for the vehicle
            if self.chain.anchorCoupling ~= nil then
                self.chain.anchorCoupling.valveOpen = true
                if self.chain.anchorCoupling.connectedPartnerCoupling ~= nil then
                    self.chain.anchorCoupling.connectedPartnerCoupling.valveOpen = true
                end
            end
        end
    elseif state == "connectedValveOpen" then
        local seg = self.chain.segments[self.arcIndex]
        if seg ~= nil and seg.chainCoupling ~= nil then
            local cc = seg.chainCoupling
            cc.valveOpen = false
            if cc.connectedPartnerCoupling ~= nil then
                cc.connectedPartnerCoupling.valveOpen = false
                if g_slurryPipeManager ~= nil then
                    local v, _ = g_slurryPipeManager:_findCouplingOwner(cc.connectedPartnerCoupling)
                    if v ~= nil then g_slurryPipeManager:stopFlow(v) end
                end
            end
            -- Propagate close back to anchor to stop the vehicle flow session
            if self.chain.anchorCoupling ~= nil then
                self.chain.anchorCoupling.valveOpen = false
                if self.chain.anchorCoupling.connectedPartnerCoupling ~= nil then
                    self.chain.anchorCoupling.connectedPartnerCoupling.valveOpen = false
                end
                if g_slurryPipeManager ~= nil then
                    local anchorVehicle, _ = g_slurryPipeManager:_findCouplingOwner(self.chain.anchorCoupling)
                    if anchorVehicle ~= nil then g_slurryPipeManager:stopFlow(anchorVehicle) end
                end
            end
        end
    end
end

function SPSChainActivatable:_getState()
    -- Anchor (arcIndex == 0)
    if self.arcIndex == 0 then
        -- Deployable coupling not yet deployed — offer deploy (long press)
        if self.coupling ~= nil and self.coupling.deployable and not self.coupling.isDeployed then
            return "deployCoupling"
        end

        if self.coupling ~= nil and self.coupling.isConnected then
            -- Still allow finalise if a live pipe is being walked
            if self.chain == nil or self.chain.liveSegment == nil then return nil end
        end

        if self.chain == nil then
            -- Conduit pump couplings: pipes connect TO them, not FROM them
            if self.coupling ~= nil and g_slurryPipeManager ~= nil then
                local v, _ = g_slurryPipeManager:_findCouplingOwner(self.coupling)
                if v ~= nil and g_slurryPipeManager:isVehicleConduit(v) then return nil end
            end
            return "layFirstPipe"
        end
        -- Live pipe being walked: offer finalise (short) or cancel (long press)
        if self.chain.liveSegment ~= nil then
            return "finalisePipe"
        end
        -- No live pipe, no segments, no DS
        if #self.chain.segments == 0 and self.chain.dockingStation == nil then
            return "layFirstPipe"
        end
        -- Segments exist and no live pipe: remove is at the chain start, not here
        if #self.chain.segments > 0 and self.chain.liveSegment == nil then
            -- For vehicle couplings, chain starts 3.5m away — remove is at the chain not here
            if g_slurryPipeManager ~= nil and self.coupling ~= nil then
                local vehicle, _ = g_slurryPipeManager:_findCouplingOwner(self.coupling)
                if vehicle ~= nil then return nil end
            end
            return "removePipeChain"
        end
        -- DS without segments
        if self.chain.dockingStation ~= nil then
            return (self.chain.anchorCoupling ~= nil and self.chain.anchorCoupling.valveOpen)
                and "dockingStationOpen" or "dockingStationClosed"
        end
        return nil
    end

    -- Terminus (arcIndex > 0) — only locked segments have activatables
    if self.chain == nil then return nil end

    -- End activatable (detNode01 = end of pipe): lay more pipe, docking station, valve control
    if self.isEndActivatable then
        -- Only active when this is the last locked segment
        if self.chain.segments[self.arcIndex + 1] ~= nil then return nil end
        -- Don't show while a live pipe is already being walked
        if self.chain.liveSegment ~= nil then return nil end
        local seg = self.chain.segments[self.arcIndex]
        if seg == nil then return nil end
        if seg.chainCoupling ~= nil and seg.chainCoupling.isConnected then
            -- If connected partner has a cab-controlled valve, no valve prompts here
            local cc = seg.chainCoupling
            if cc.connectedPartnerCoupling ~= nil then
                local partner = cc.connectedPartnerCoupling
                if partner.valveType == SPS_VALVE_TYPE_HYDRAULIC then
                    return "connectedHydraulicValve"
                end
                if g_slurryPipeManager ~= nil then
                    local v, _ = g_slurryPipeManager:_findCouplingOwner(partner)
                    if v ~= nil and g_slurryPipeManager:isVehicleConduit(v) then
                        return "connectedHydraulicValve"
                    end
                end
            end
            return seg.chainCoupling.valveOpen and "connectedValveOpen" or "connectedValveClosed"
        end
        if self.chain.dockingStation ~= nil then
            return (self.chain.anchorCoupling ~= nil and self.chain.anchorCoupling.valveOpen)
                and "dockingStationOpen" or "dockingStationClosed"
        end
        -- Conduit vehicle anchor: cannot lay more pipe from it
        if g_slurryPipeManager ~= nil and self.chain ~= nil and self.chain.anchorCoupling ~= nil then
            local v, _ = g_slurryPipeManager:_findCouplingOwner(self.chain.anchorCoupling)
            if v ~= nil and g_slurryPipeManager:isVehicleConduit(v) then return nil end
        end
        return "layMorePipe"
    end

    -- Primary activatable (pipeRoot = start of pipe): remove from here
    -- Suppressed for placeable-anchored chains (anchor activatable handles that position).
    -- For vehicle-anchored chains, chain starts 3.5m away so pipeRoot IS the right place.
    if self.arcIndex == 1 then
        if g_slurryPipeManager ~= nil and self.chain ~= nil and self.chain.anchorCoupling ~= nil then
            local vehicle, _ = g_slurryPipeManager:_findCouplingOwner(self.chain.anchorCoupling)
            if vehicle == nil then return nil end
        else
            return nil
        end
    end
    -- Don't show while a live pipe is being walked
    if self.chain.liveSegment ~= nil then return nil end
    return "removePipeChain"
end

function SPSChainActivatable:_getNode()
    if self.arcIndex == 0 then
        -- While live pipe is being walked, follow its end so player can press R
        if self.chain ~= nil and self.chain.liveSegment ~= nil then
            return self.chain.liveSegment.endConnectors
        end
        return self.coupling ~= nil and self.coupling.mountNode or nil
    else
        if self.chain == nil then return nil end
        local seg = self.chain.segments[self.arcIndex]
        if seg == nil then return nil end
        if self.isEndActivatable then
            return seg.endConnectors or nil   -- end of pipe: lay more / docking station
        else
            return seg.pipeRoot or nil        -- start of pipe: remove from here
        end
    end
end

function SPSChainActivatable:_buildActivateText()
    local state = self:_getState()
    if state == "deployCoupling"          then return g_i18n:getText("action_spsDeployCoupling") end
    if state == "removeCoupling"          then return g_i18n:getText("action_spsRemoveCoupling") end
    if state == "layFirstPipe"            then return g_i18n:getText("action_spsLayFirstPipe") end
    if state == "finalisePipe"         then return g_i18n:getText("action_spsFinalisePipe") end
    if state == "layMorePipe"          then return g_i18n:getText("action_spsLayPipe") end
    if state == "removePipeChain"      then return g_i18n:getText("action_spsRemovePipe") end
    if state == "dockingStationClosed" then return g_i18n:getText("action_spsRemoveDockingStation") end
    if state == "dockingStationOpen"   then return g_i18n:getText("action_spsRemoveDockingStation") end
    if state == "connectedValveClosed"     then return g_i18n:getText("action_spsDisconnectOrOpenValve") end
    if state == "connectedValveOpen"       then return g_i18n:getText("action_spsCloseValve") end
    if state == "connectedHydraulicValve"  then return g_i18n:getText("action_spsDisconnectPipe") end
    return ""
end