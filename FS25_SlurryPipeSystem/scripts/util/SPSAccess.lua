-- ===========================================================================
-- SPSAccess  [SPS 1.0.1.8]
-- ---------------------------------------------------------------------------
-- Farm permission gate for the SPS walk-up prompts (activatables). Before this,
-- any farm's player could open another farm's valves, start its pump, repair
-- its shear bolt or work its separator in multiplayer.
--
-- Uses the game's own AccessHandler:canPlayerAccess (farms/AccessHandler.lua):
-- owner farm, farms the owner granted contractor access, and objects owned by
-- nobody / everybody (map placeables such as the BGA, farmId 0) all pass - so
-- single player and shared map stores behave exactly as before.
-- ===========================================================================

SPSAccess = {}

-- Resolve something that owns a farm id: a vehicle/placeable itself, or an SPS
-- registry entry / coupling that carries one in a known field.
local function resolveOwner(o)
    if type(o) ~= "table" then return nil end
    if o.getOwnerFarmId ~= nil then return o end
    for _, k in ipairs({ "vehicle", "placeable", "object" }) do
        local v = o[k]
        if type(v) == "table" and v.getOwnerFarmId ~= nil then return v end
    end
    return nil
end

-- True when the local player may use o. Anything without an owner passes.
function SPSAccess.localCanUse(o)
    local owner = resolveOwner(o)
    if owner == nil then return true end
    local mission = g_currentMission
    if mission == nil or mission.accessHandler == nil then return true end
    return mission.accessHandler:canPlayerAccess(owner)
end
