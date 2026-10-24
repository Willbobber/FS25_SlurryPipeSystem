--[[
  ConstructionBrushSPSWaterDraw  -  [SPS 1.0.1.8] "Draw water course" build-menu brush

  Sourced by g_constructionBrushTypeManager:addBrushType (SPSWaterCourses.lua), NOT listed in
  modDesc. Modelled on ConstructionBrushNewFence (click to place, right click undo, Esc cancel).

  Flow (William 2026-10-20):
    1. first LEFT click must be ON THE WATER - that sets the surface height of the course;
    2. every further LEFT click drops a ring marker, on the bank or the water, any height;
    3. RIGHT click removes the last marker (then the water point);
    4. Esc / back cancels everything while something is placed;
    5. LEFT click on the FIRST marker (3+ markers) closes the ring -> name box (prefilled)
       -> "Water course complete" -> saved and live at once.
  Multiplayer: any player with the landscaping permission may draw. The ring goes to the server
  (SPSWaterCourses.requestAdd -> SPSWaterCourseEvent), which validates, saves and broadcasts it.
]]

ConstructionBrushSPSWaterDraw = {}
local ConstructionBrushSPSWaterDraw_mt = Class(ConstructionBrushSPSWaterDraw, ConstructionBrush)

ConstructionBrushSPSWaterDraw.FLASH_MS = 2500

function ConstructionBrushSPSWaterDraw.new(subclass_mt, cursor)
    local self = ConstructionBrush.new(subclass_mt or ConstructionBrushSPSWaterDraw_mt, cursor)
    self.supportsPrimaryButton   = true
    self.supportsSecondaryButton = true
    self.requiredPermission      = Farm.PERMISSION.LANDSCAPING
    self.waterY       = nil      -- surface height from the first click
    self.waterPoint   = nil      -- {x, z} of that click (drawn as a float marker)
    self.points       = {}       -- ring markers, flat {x1,z1,x2,z2,...}
    self.flashText    = nil
    self.flashUntil   = 0
    self.flashIsError = false
    self.pendingName  = nil
    return self
end

function ConstructionBrushSPSWaterDraw:activate()
    ConstructionBrushSPSWaterDraw:superClass().activate(self)
    self.cursor:setRotationEnabled(false)
    self.cursor:setShape(GuiTopDownCursor.SHAPES.CIRCLE)
    self.cursor:setShapeSize(0.5)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SUCCESS)
    -- terrain + water surface hits; keep the cursor visible over water (setTerrainOnly hides it there)
    self.cursor:setTerrainOnly(true)
    self.cursor:setIsWaterDetectionActive(true)
    self.cursor.hitTerrainOnly = false
    self:clear()
end

function ConstructionBrushSPSWaterDraw:deactivate()
    self:clear()
    self.cursor:setIsWaterDetectionActive(false)
    self.cursor:setTerrainOnly(false)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT, nil)
    ConstructionBrushSPSWaterDraw:superClass().deactivate(self)
end

function ConstructionBrushSPSWaterDraw:clear()
    self.waterY, self.waterPoint = nil, nil
    self.points = {}
    self.pendingName = nil
    self:setInputTextDirty()
end

function ConstructionBrushSPSWaterDraw:flash(key, isError)
    self.flashText = g_i18n:getText(key)
    self.flashUntil = (g_time or 0) + ConstructionBrushSPSWaterDraw.FLASH_MS
    self.flashIsError = isError ~= false
end

function ConstructionBrushSPSWaterDraw:canCancel()
    return self.waterY ~= nil or #self.points > 0
end

function ConstructionBrushSPSWaterDraw:cancel()
    self:clear()
    self:flash("sps_waterCourse_cancelled", false)
end

function ConstructionBrushSPSWaterDraw:isAllowed()
    if not self:hasPlayerPermission() then return false, ConstructionBrush.ERROR_MESSAGES[ConstructionBrush.ERROR.NO_PERMISSION] end
    return true, nil
end

function ConstructionBrushSPSWaterDraw:isNearFirst(x, z)
    if #self.points < 2 * SPSWaterCourses.MIN_POINTS then return false end
    local dx, dz = x - self.points[1], z - self.points[2]
    return math.sqrt(dx * dx + dz * dz) <= SPSWaterCourses.CLOSE_RADIUS
end

function ConstructionBrushSPSWaterDraw:update(dt)
    local ok = self:isAllowed()
    local x, _, z = self.cursor:getPosition()
    local near = x ~= nil and self:isNearFirst(x, z)
    if near ~= self._wasNear then
        self._wasNear = near
        self:setInputTextDirty()          -- "Place marker" <-> "Close the ring"
    end
    if not ok then
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.ERROR)
    elseif near then
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT)
    else
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SUCCESS)
    end
end

function ConstructionBrushSPSWaterDraw:draw()
    local ok, reason = self:isAllowed()
    if not ok then
        self.cursor:setErrorMessage(g_i18n:getText(reason))
    elseif self.flashText ~= nil and (g_time or 0) < self.flashUntil then
        if self.flashIsError then self.cursor:setErrorMessage(self.flashText) else self.cursor:setMessage(self.flashText) end
    elseif self.waterY == nil then
        self.cursor:setMessage(g_i18n:getText("sps_waterCourse_hintClickWater"))
    end

    local n = #self.points / 2
    -- the water point: a float marker at the surface
    if self.waterPoint ~= nil then
        local wx, wz, wy = self.waterPoint[1], self.waterPoint[2], self.waterY
        drawDebugLine(wx - 0.5, wy, wz, 0.2, 0.6, 1.0, wx + 0.5, wy, wz, 0.2, 0.6, 1.0)
        drawDebugLine(wx, wy, wz - 0.5, 0.2, 0.6, 1.0, wx, wy, wz + 0.5, 0.2, 0.6, 1.0)
        drawDebugLine(wx, wy, wz, 0.2, 0.6, 1.0, wx, wy + 1.5, wz, 0.2, 0.6, 1.0)
    end
    if n == 0 then return end
    -- the ring so far (posts stand on the water level + their own ground is irrelevant: the ring is XZ only)
    local y = self.waterY
    SPSWaterCourses.drawRing(self.points, y, 1.0, 0.85, 0.1, false)
    -- live segment from the last marker to the cursor; green closing segment when near the first marker
    local cx, _, cz = self.cursor:getPosition()
    if cx ~= nil then
        local lx, lz = self.points[2 * n - 1], self.points[2 * n]
        if self:isNearFirst(cx, cz) then
            drawDebugLine(lx, y + SPSWaterCourses.POST_HEIGHT, lz, 0.2, 1.0, 0.2, self.points[1], y + SPSWaterCourses.POST_HEIGHT, self.points[2], 0.2, 1.0, 0.2)
        else
            drawDebugLine(lx, y + SPSWaterCourses.POST_HEIGHT, lz, 1.0, 1.0, 1.0, cx, y + SPSWaterCourses.POST_HEIGHT, cz, 1.0, 1.0, 1.0)
        end
    end
end

function ConstructionBrushSPSWaterDraw:onButtonPrimary()
    local ok, reason = self:isAllowed()
    if not ok then self:flash(reason, true); return end
    if self.pendingName ~= nil then return end           -- name box open
    local x, _, z = self.cursor:getPosition()
    if x == nil then return end

    if self.waterY == nil then
        local wy = SPSWaterCourses.sampleWaterY(x, z)
        if wy == nil then
            self:flash("sps_waterCourse_clickWaterFirst", true)
            return
        end
        self.waterY, self.waterPoint = wy, { x, z }
        self:flash("sps_waterCourse_levelSet", false)
        self:setInputTextDirty()
        return
    end

    local n = #self.points / 2
    if self:isNearFirst(x, z) then
        self:finish()
        return
    end
    if n >= SPSWaterCourses.MAX_POINTS then self:flash("sps_waterCourse_tooManyPoints", true); return end
    if n >= 1 then
        local lx, lz = self.points[2 * n - 1], self.points[2 * n]
        local dx, dz = x - lx, z - lz
        if math.sqrt(dx * dx + dz * dz) < SPSWaterCourses.MIN_EDGE then self:flash("sps_waterCourse_edgeTooShort", true); return end
        -- the new edge may not cross the ring drawn so far (its own last edge touches it, skip that)
        if n >= 3 and SPSWaterCourses.segmentCrossesRing(self.points, lx, lz, x, z, false, true) then
            self:flash("sps_waterCourse_crossing", true)
            return
        end
    end
    self.points[#self.points + 1] = x
    self.points[#self.points + 1] = z
    self:setInputTextDirty()
end

function ConstructionBrushSPSWaterDraw:onButtonSecondary()
    if self.pendingName ~= nil then return end
    if #self.points > 0 then
        self.points[#self.points] = nil
        self.points[#self.points] = nil
    elseif self.waterY ~= nil then
        self.waterY, self.waterPoint = nil, nil
    end
    self:setInputTextDirty()
end

function ConstructionBrushSPSWaterDraw:finish()
    local ok, reason = SPSWaterCourses.validateRing(self.points)
    if not ok then self:flash(reason, true); return end
    local default = SPSWaterCourses.defaultName()
    self.pendingName = default
    TextInputDialog.show(self.onNameEntered, self, default, g_i18n:getText("sps_waterCourse_namePrompt"), nil, 32,
        g_i18n:getText("button_confirm"), nil, default)
end

function ConstructionBrushSPSWaterDraw:onNameEntered(text, clickOk, args)
    local default = self.pendingName
    self.pendingName = nil
    if default == nil then return end
    -- an unchanged prefill is sent as "" so the SERVER numbers the course (its nextId, not this client's)
    local name = ""
    local trimmed = text ~= nil and tostring(text):match("^%s*(.-)%s*$") or ""
    if clickOk and trimmed ~= "" and trimmed ~= default then name = trimmed end
    local course, reason = SPSWaterCourses.requestAdd(self.points, self.waterY, name)
    if course == nil and reason ~= "sent" then
        self:flash(reason or "sps_waterCourse_crossing", true)
        return
    end
    self:clear()
    self:flash("sps_waterCourse_complete", false)
end

function ConstructionBrushSPSWaterDraw:getButtonPrimaryText()
    if self.waterY == nil then return g_i18n:getText("sps_waterCourse_actionClickWater") end
    local x, _, z = self.cursor:getPosition()
    if x ~= nil and self:isNearFirst(x, z) then return g_i18n:getText("sps_waterCourse_actionClose") end
    return g_i18n:getText("sps_waterCourse_actionPlace")
end

function ConstructionBrushSPSWaterDraw:getButtonSecondaryText()
    if #self.points > 0 then return g_i18n:getText("sps_waterCourse_actionRemoveLast") end
    if self.waterY ~= nil then return g_i18n:getText("sps_waterCourse_actionRemoveLevel") end
    return nil
end
