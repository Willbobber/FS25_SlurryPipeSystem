-- SlurryDebug.lua
-- FS25_SlurryPipeSystem
-- Debug rendering helpers. All output is gated by SlurryDebug.enabled.
-- Enable via modDesc.xml <slurryPipeSystem debug="true" />

SlurryDebug = {}
SlurryDebug.enabled = false

-- Colours used for each node/state type
SlurryDebug.COLOR = {
    UPPER_NODE_OK       = { 0, 1, 0, 1 },   -- green  : upper node inside trigger
    UPPER_NODE_FAIL     = { 1, 0, 0, 1 },   -- red    : upper node outside trigger
    LOWER_NODE_OK       = { 0, 0, 1, 1 },   -- blue   : lower node submerged
    LOWER_NODE_FAIL     = { 1, 0.5, 0, 1 }, -- orange : lower node above surface
    SURFACE_PLANE       = { 0, 1, 1, 1 },   -- cyan   : slurry surface Y marker
    PIPE_CONNECTED      = { 0, 1, 0, 1 },   -- green  : pipe coupling connected
    PIPE_DISCONNECTED   = { 1, 0, 0, 1 },   -- red    : pipe coupling not connected
    RECEIVER_OK         = { 0, 1, 0, 1 },   -- green  : receiver cup aligned
    RECEIVER_FAIL       = { 1, 0, 0, 1 },   -- red    : receiver cup out of range
}

-- Draw a single world-space point
-- @param wx wy wz  world position
-- @param color     table { r, g, b, a }
-- @param size      float, default 0.1
function SlurryDebug.drawPoint(wx, wy, wz, color, size)
    if not SlurryDebug.enabled then return end
    size = size or 0.1
    drawDebugPoint(wx, wy, wz, color[1], color[2], color[3], color[4])
end

-- Draw a world-space line between two points
-- @param x1 y1 z1  start world position
-- @param x2 y2 z2  end world position
-- @param color     table { r, g, b, a }
function SlurryDebug.drawLine(x1, y1, z1, x2, y2, z2, color)
    if not SlurryDebug.enabled then return end
    drawDebugLine(x1, y1, z1, color[1], color[2], color[3],
                  x2, y2, z2, color[1], color[2], color[3])
end

-- Render a text label at a world position
-- @param wx wy wz  world position
-- @param text      string
-- @param size      float, default 0.012
function SlurryDebug.drawText(wx, wy, wz, text, size)
    if not SlurryDebug.enabled then return end
    size = size or 0.012
    Utils.renderTextAtWorldPosition(wx, wy, wz, text, size)
end

-- Draw upper and lower arm nodes with their current pass/fail state
-- @param upperNode     scenegraph node
-- @param lowerNode     scenegraph node
-- @param upperOk       bool
-- @param lowerOk       bool
-- @param surfaceWorldY float, world Y of current slurry surface
function SlurryDebug.drawArmNodes(upperNode, lowerNode, upperOk, lowerOk, surfaceWorldY)
    if not SlurryDebug.enabled then return end

    local ux, uy, uz = getWorldTranslation(upperNode)
    local lx, ly, lz = getWorldTranslation(lowerNode)

    local upperColor = upperOk and SlurryDebug.COLOR.UPPER_NODE_OK or SlurryDebug.COLOR.UPPER_NODE_FAIL
    local lowerColor = lowerOk and SlurryDebug.COLOR.LOWER_NODE_OK or SlurryDebug.COLOR.LOWER_NODE_FAIL

    SlurryDebug.drawPoint(ux, uy, uz, upperColor, 0.15)
    SlurryDebug.drawPoint(lx, ly, lz, lowerColor, 0.15)

    -- vertical line between nodes
    SlurryDebug.drawLine(ux, uy, uz, lx, ly, lz, { 1, 1, 1, 1 })

    -- surface Y marker at lower node X/Z
    SlurryDebug.drawPoint(lx, surfaceWorldY, lz, SlurryDebug.COLOR.SURFACE_PLANE, 0.12)
    SlurryDebug.drawLine(lx - 0.3, surfaceWorldY, lz, lx + 0.3, surfaceWorldY, lz, SlurryDebug.COLOR.SURFACE_PLANE)

    SlurryDebug.drawText(ux, uy + 0.2, uz, string.format("UPPER:%s", upperOk and "OK" or "FAIL"))
    SlurryDebug.drawText(lx, ly + 0.2, lz, string.format("LOWER:%s surfY:%.2f", lowerOk and "OK" or "FAIL", surfaceWorldY))
end

-- Draw a pipe coupling point and its connection state
-- @param node          scenegraph node for the coupling mount
-- @param isConnected   bool
-- @param label         string, optional
function SlurryDebug.drawCouplingPoint(node, isConnected, label)
    if not SlurryDebug.enabled then return end

    local wx, wy, wz = getWorldTranslation(node)
    local color = isConnected and SlurryDebug.COLOR.PIPE_CONNECTED or SlurryDebug.COLOR.PIPE_DISCONNECTED
    SlurryDebug.drawPoint(wx, wy, wz, color, 0.12)

    local text = label or "COUPLING"
    SlurryDebug.drawText(wx, wy + 0.2, wz, string.format("%s:%s", text, isConnected and "CONN" or "DISC"))
end

-- Draw a receiver cup node and its alignment state
-- @param node          scenegraph node
-- @param isAligned     bool
-- @param distance      float, current distance from nozzle tip
function SlurryDebug.drawReceiverNode(node, isAligned, distance)
    if not SlurryDebug.enabled then return end

    local wx, wy, wz = getWorldTranslation(node)
    local color = isAligned and SlurryDebug.COLOR.RECEIVER_OK or SlurryDebug.COLOR.RECEIVER_FAIL
    SlurryDebug.drawPoint(wx, wy, wz, color, 0.15)
    SlurryDebug.drawText(wx, wy + 0.2, wz, string.format("RECEIVER:%s dist:%.2fm", isAligned and "OK" or "FAIL", distance or 0))
end

-- Log a message to the console with mod prefix, only when debug enabled
-- @param msg   string
function SlurryDebug.log(msg)
    if not SlurryDebug.enabled then return end
    print("[SPS] " .. tostring(msg))
end
