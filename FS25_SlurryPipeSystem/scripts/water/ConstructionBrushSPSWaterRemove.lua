--[[
  ConstructionBrushSPSWaterRemove  -  [SPS 1.0.1.8] "Remove water course" build-menu brush

  Sourced by g_constructionBrushTypeManager:addBrushType (SPSWaterCourses.lua). While active every
  player-drawn course on the map is drawn as a ring; the one under the cursor is highlighted and
  named; LEFT click asks yes/no and removes it. Map-maker water planes (SPS_waterNodes / manifest
  i3ds) are never shown or removable here. Multiplayer: the remove goes to the server
  (SPSWaterCourses.requestRemove -> SPSWaterCourseEvent) and comes back as a broadcast.
]]

ConstructionBrushSPSWaterRemove = {}
local ConstructionBrushSPSWaterRemove_mt = Class(ConstructionBrushSPSWaterRemove, ConstructionBrush)

function ConstructionBrushSPSWaterRemove.new(subclass_mt, cursor)
    local self = ConstructionBrush.new(subclass_mt or ConstructionBrushSPSWaterRemove_mt, cursor)
    self.supportsPrimaryButton = true
    self.requiredPermission    = Farm.PERMISSION.LANDSCAPING
    self.hovered    = nil
    self.dialogOpen = false
    self.flashText  = nil
    self.flashUntil = 0
    return self
end

function ConstructionBrushSPSWaterRemove:activate()
    ConstructionBrushSPSWaterRemove:superClass().activate(self)
    self.cursor:setRotationEnabled(false)
    self.cursor:setShape(GuiTopDownCursor.SHAPES.CIRCLE)
    self.cursor:setShapeSize(0.5)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT)
    self.cursor:setTerrainOnly(true)
    self.cursor:setIsWaterDetectionActive(true)
    self.cursor.hitTerrainOnly = false
    self.hovered = nil
end

function ConstructionBrushSPSWaterRemove:deactivate()
    self.cursor:setIsWaterDetectionActive(false)
    self.cursor:setTerrainOnly(false)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT, nil)
    ConstructionBrushSPSWaterRemove:superClass().deactivate(self)
end

function ConstructionBrushSPSWaterRemove:isAllowed()
    if not self:hasPlayerPermission() then return false, ConstructionBrush.ERROR_MESSAGES[ConstructionBrush.ERROR.NO_PERMISSION] end
    return true, nil
end

function ConstructionBrushSPSWaterRemove:update(dt)
    local x, _, z = self.cursor:getPosition()
    local before = self.hovered
    self.hovered = (x ~= nil) and SPSWaterCourses.findCourseAt(x, z) or nil
    if self.hovered ~= before then self:setInputTextDirty() end
    local ok = self:isAllowed()
    if not ok then
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.ERROR)
    elseif self.hovered ~= nil then
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SUCCESS)
    else
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT)
    end
end

function ConstructionBrushSPSWaterRemove:draw()
    local ok, reason = self:isAllowed()
    if not ok then
        self.cursor:setErrorMessage(g_i18n:getText(reason))
    elseif self.flashText ~= nil and (g_time or 0) < self.flashUntil then
        self.cursor:setMessage(self.flashText)
    elseif self.hovered ~= nil then
        self.cursor:setMessage(self.hovered.name or "")
    elseif #SPSWaterCourses.order == 0 then
        self.cursor:setMessage(g_i18n:getText("sps_waterCourse_noneOnMap"))
    end
    for _, id in ipairs(SPSWaterCourses.order) do
        local c = SPSWaterCourses.courses[id]
        if c ~= nil then
            if c == self.hovered then
                SPSWaterCourses.drawCourse(c, 1.0, 0.25, 0.15)
            else
                SPSWaterCourses.drawCourse(c, 0.3, 0.7, 1.0)
            end
        end
    end
end

function ConstructionBrushSPSWaterRemove:onButtonPrimary()
    local ok, reason = self:isAllowed()
    if not ok then return end
    if self.dialogOpen or self.hovered == nil then return end
    local course = self.hovered
    self.dialogOpen = true
    YesNoDialog.show(function(_, yes)
        self.dialogOpen = false
        if yes then
            SPSWaterCourses.requestRemove(course.id)
            self.hovered = nil
            self.flashText = g_i18n:getText("sps_waterCourse_removed")
            self.flashUntil = (g_time or 0) + 2500
            self:setInputTextDirty()
        end
    end, self, string.format(g_i18n:getText("sps_waterCourse_removeConfirm"), course.name or ""))
end

function ConstructionBrushSPSWaterRemove:getButtonPrimaryText()
    if self.hovered ~= nil then return g_i18n:getText("sps_waterCourse_actionRemove") end
    return nil
end
