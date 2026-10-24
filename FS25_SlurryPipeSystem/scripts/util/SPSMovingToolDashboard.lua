-- FS25_SlurryPipeSystem
-- Author: Oscar Mods
-- Version: 1.0.1.8

-- SPSMovingToolDashboard.lua  -  [SPS 1.0.1.8] lever dashboards that follow ONE named moving tool.
--
-- Vanilla `valueType="movingTool"` dashboards pick their tool by input axis only: the first moving tool with that
-- axis in the ACTIVE control group (Cylindered.getMovingToolDashboardState, decoded Cylindered.lua 3791-3809).
-- With two control groups sharing keys (tower mixer: legs on J/N + K/M in group 1, ladders on the same keys in group
-- 2) a lever then also follows the other group's tool. This adds an opt-in form of the existing `axis` attribute:
--
--     axis="AXIS_CRANE_ARM|rightLegArm01"    (input action | node name of the moving tool)
--
-- Such a dashboard follows only the moving tool on that node, and only while that tool's control group is the
-- active one; otherwise it rests centred (0.5, the vanilla idle value). `axis` is a STRING in the vanilla schema, so
-- no schema change is needed; movingToolDashboardAttributes stores it untouched. Dashboards without '|' run the
-- vanilla function unchanged, so no other vehicle is affected.
-- The function is passed by reference when a vehicle registers its dashboard value types (setValue(self,
-- Cylindered.getMovingToolDashboardState) in Cylindered:onRegisterDashboardValueTypes), i.e. at vehicle load, after
-- this file ran at mod load - so replacing the table field here is enough.

SPSMovingToolDashboard = {}

if Cylindered ~= nil and Cylindered.getMovingToolDashboardState ~= nil and not SPSMovingToolDashboard._hooked then
    SPSMovingToolDashboard._hooked = true
    local vanilla = Cylindered.getMovingToolDashboardState

    Cylindered.getMovingToolDashboardState = function(self, dashboard)
        local axis = dashboard ~= nil and dashboard.axis or nil
        if type(axis) ~= "string" or string.find(axis, "|", 1, true) == nil then
            return vanilla(self, dashboard)
        end
        -- resolve "axis|nodeName" once per dashboard
        if dashboard.spsToolAxis == nil then
            local a, n = string.match(axis, "^([^|]+)|(.+)$")
            dashboard.spsToolAxis, dashboard.spsToolNodeName = a or "", n or ""
        end
        local spec = self.spec_cylindered
        if spec == nil or spec.movingTools == nil then return 0.5 end
        if dashboard.spsTool == nil then
            for _, movingTool in ipairs(spec.movingTools) do
                if movingTool.axis == dashboard.spsToolAxis and movingTool.node ~= nil
                   and getName(movingTool.node) == dashboard.spsToolNodeName then
                    dashboard.spsTool = movingTool
                    break
                end
            end
            if dashboard.spsTool == nil then
                dashboard.spsTool = false   -- not found: stop searching, rest centred
                print(string.format("[SPS] lever dashboard: no moving tool '%s' on axis %s - lever stays centred",
                    tostring(dashboard.spsToolNodeName), tostring(dashboard.spsToolAxis)))
            end
        end
        local tool = dashboard.spsTool
        if not tool then return 0.5 end
        local group = tool.controlGroupIndex or 0
        if group ~= 0 and group ~= spec.currentControlGroupIndex then return 0.5 end
        return ((tool.smoothedMove or 0) + 1) / 2
    end
end

if SPSDebugConfig ~= nil then SPSDebugConfig.log("Build", "[SPS BUILD] SPSMovingToolDashboard 1.0.1.8 loaded (lever dashboards bound to one moving tool)") end
