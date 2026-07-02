-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.0.4

-- SlurryAgitator.lua
-- Vehicle specialization for a PTO-driven slurry agitator.
-- The tip node must be submerged below the fill plane surface and within
-- the registered source bounds for agitation to apply.
-- Agitation reduces slurry thickness in SlurryPipeManager at a rate
-- proportional to g_currentMission.environment.daysPerPeriod.

SlurryAgitator = {}
SlurryAgitator.MOD_NAME = g_currentModName

-- ---------------------------------------------------------------------------
-- Prerequisites
-- ---------------------------------------------------------------------------
function SlurryAgitator.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PowerTakeOffs, specializations)
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------
function SlurryAgitator.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "spsGetAgitatorTipNode",   SlurryAgitator.spsGetAgitatorTipNode)
    SpecializationUtil.registerFunction(vehicleType, "spsGetActiveSourceEntry", SlurryAgitator.spsGetActiveSourceEntry)
end

function SlurryAgitator.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad",             SlurryAgitator)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete",           SlurryAgitator)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate",           SlurryAgitator)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdateTick",       SlurryAgitator)
    SpecializationUtil.registerEventListener(vehicleType, "onDeactivate",       SlurryAgitator)
end

function SlurryAgitator.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("SlurryAgitator")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".slurryAgitator#tipNode",
        "Node that must be submerged below the fill plane surface")
    schema:setXMLSpecializationType()
end

-- ---------------------------------------------------------------------------
-- onLoad
-- ---------------------------------------------------------------------------
function SlurryAgitator:onLoad(savegame)
    local spec = self.spec_slurryAgitator
    local xmlFile = self.xmlFile

    spec.tipNode   = xmlFile:getValue(self.configFileName .. ".vehicle.slurryAgitator#tipNode",
                        nil, self.components, self.i3dMappings)

    if spec.tipNode == nil then
        Logging.warning("[SPS SlurryAgitator] onLoad: no tipNode found in " .. tostring(self.configFileName))
    end

    spec.isRunning         = false   -- true when PTO spinning and tip submerged
    spec.activeSourceEntry = nil     -- the sourceEntry currently being agitated
    spec._submergedTime    = 0       -- accumulated active game hours this session (debug)

    print("[SPS SlurryAgitator] loaded for " .. tostring(self.configFileName))
end

-- ---------------------------------------------------------------------------
-- onDelete
-- ---------------------------------------------------------------------------
function SlurryAgitator:onDelete()
    local spec = self.spec_slurryAgitator
    spec.isRunning         = false
    spec.activeSourceEntry = nil
end

-- ---------------------------------------------------------------------------
-- onDeactivate
-- ---------------------------------------------------------------------------
function SlurryAgitator:onDeactivate()
    local spec = self.spec_slurryAgitator
    if spec.isRunning then
        spec.isRunning = false
        spec.activeSourceEntry = nil
        SlurryAgitatorEvent.sendEvent(self, false)
    end
end

-- ---------------------------------------------------------------------------
-- onUpdateTick — server-side: detect submerge, drive agitation
-- ---------------------------------------------------------------------------
function SlurryAgitator:onUpdateTick(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSuperFocused)
    local spec = self.spec_slurryAgitator
    if not self.isServer then return end
    if g_slurryPipeManager == nil then return end
    if not g_slurryPipeManager.agitationEnabled then
        if spec.isRunning then
            spec.isRunning = false
            spec.activeSourceEntry = nil
            SlurryAgitatorEvent.sendEvent(self, false)
        end
        return
    end

    -- PTO must be engaged (spinning)
    local ptoRunning = false
    if self.spec_powerTakeOffs ~= nil then
        for _, pto in ipairs(self.spec_powerTakeOffs.powerTakeOffs) do
            if pto.isActive then ptoRunning = true break end
        end
    end

    if not ptoRunning then
        if spec.isRunning then
            spec.isRunning = false
            spec.activeSourceEntry = nil
            SlurryAgitatorEvent.sendEvent(self, false)
        end
        return
    end

    -- Find which registered placeable sourceEntry the tip is submerged in
    local tipNode = spec.tipNode
    if tipNode == nil then return end

    local tx, ty, tz = getWorldTranslation(tipNode)
    local foundEntry = nil

    for _, pEntry in ipairs(g_slurryPipeManager.registeredPlaceables) do
        local se = pEntry.sourceEntry
        if se ~= nil and se.type == SlurryNodeUtil.SOURCE_TYPE_STORAGE_PLANE then
            -- Check tip is within plan bounds
            local inBounds = false
            if se.planeBounds ~= nil then
                inBounds = SlurryNodeUtil.isNodeInPlaneBounds(tipNode, se.planeBounds)
            end
            if inBounds then
                -- Check tip is below surface Y
                local surfY = SlurryNodeUtil.getSurfaceWorldY(se, tx, tz)
                if ty <= surfY then
                    foundEntry = se
                    break
                end
            end
        end
    end

    local wasRunning = spec.isRunning
    spec.isRunning         = foundEntry ~= nil
    spec.activeSourceEntry = foundEntry

    if spec.isRunning ~= wasRunning then
        SlurryAgitatorEvent.sendEvent(self, spec.isRunning)
    end

    -- Apply agitation if active
    if spec.isRunning and foundEntry ~= nil then
        -- Convert dt (ms) to game hours using environment time scale
        local env        = g_currentMission ~= nil and g_currentMission.environment or nil
        local timeScale  = env ~= nil and env.timeAdjustment or 1
        local dtHours    = (dt * 0.001) * timeScale / 3600
        g_slurryPipeManager:applyAgitation(foundEntry, dtHours)
        spec._submergedTime = spec._submergedTime + dtHours
    end
end

-- ---------------------------------------------------------------------------
-- onUpdate — client-side: HUD warning when PTO running but not submerged
-- ---------------------------------------------------------------------------
function SlurryAgitator:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSuperFocused)
    local spec = self.spec_slurryAgitator
    if not isActiveForInput then return end

    -- Show "not submerged" warning if PTO running but agitator not active
    local ptoRunning = false
    if self.spec_powerTakeOffs ~= nil then
        for _, pto in ipairs(self.spec_powerTakeOffs.powerTakeOffs) do
            if pto.isActive then ptoRunning = true break end
        end
    end

    if ptoRunning and not spec.isRunning then
        g_currentMission:showBlinkingWarning(g_i18n:getText("warning_spsAgitatorNotSubmerged"), 2000)
    end
end

-- ---------------------------------------------------------------------------
-- Accessor functions
-- ---------------------------------------------------------------------------
function SlurryAgitator:spsGetAgitatorTipNode()
    return self.spec_slurryAgitator.tipNode
end

function SlurryAgitator:spsGetActiveSourceEntry()
    return self.spec_slurryAgitator.activeSourceEntry
end
