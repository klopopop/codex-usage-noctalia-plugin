--!nonstrict
local fmt = require("./format.luau")
local hovered = false
local hoverSince = 0
local hoverShown = false
local locating = false

local function hidePreview()
  noctalia.layer.hide("preview")
  hoverShown = false
end

local function showPreview()
  if locating or hoverShown or noctalia.state.get("usage.panelOpen") == true then return end
  locating = true
  noctalia.setUpdateInterval(1000)
  local accepted = noctalia.runAsync({ "hyprctl", "-j", "cursorpos" }, function(result)
    locating = false
    if not hovered or noctalia.state.get("usage.panelOpen") == true then return end
    local ok, cursor = pcall(noctalia.json.decode, result.stdout or "")
    if result.exitCode ~= 0 or not ok or type(cursor) ~= "table" then return end
    local output = nil
    for _, item in ipairs(noctalia.outputs()) do
      if item.name == barWidget.outputName() or
        (type(cursor.x) == "number" and type(cursor.y) == "number" and
         cursor.x >= item.x and cursor.x < item.x + item.width and
         cursor.y >= item.y and cursor.y < item.y + item.height) then
        output = item; break
      end
    end
    if output == nil or type(cursor.x) ~= "number" or type(cursor.y) ~= "number" then return end
    local width, height = math.min(380, output.width - 16), math.min(470, output.height - 16)
    local px, py = cursor.x - output.x, cursor.y - output.y
    local x = math.max(8, math.min(output.width - width - 8, px - width / 2))
    local y = py < output.height / 2 and (py + 25) or (py - height - 18)
    if barWidget.isVertical() then
      x = px < output.width / 2 and (px + 25) or (px - width - 18)
      y = math.max(8, math.min(output.height - height - 8, py - height / 2))
    end
    x = math.max(8, math.min(output.width - width - 8, x))
    y = math.max(8, math.min(output.height - height - 8, y))
    noctalia.layer.configure("preview", { width = width, height = height, output = output.name,
      anchors = { "top", "left" }, margins = { top = math.floor(y), left = math.floor(x) },
      exclusiveZone = -1, keyboard = "none", clickThrough = true })
    hoverShown = true
    noctalia.layer.show("preview")
  end)
  if not accepted then locating = false end
end

function update()
  local state = fmt.state()
  local snap = state.snapshot
  local bucket = snap and snap.limits and snap.limits[1] or nil
  local primary = bucket and bucket.primary or nil
  local secondary = bucket and bucket.secondary or nil
  local stale = fmt.stale(state)
  local text = primary and string.format("%.0f%%", primary.usedPercent) or "—"
  if secondary and noctalia.getConfig("show_weekly") then text ..= string.format(" · %.0f%%", secondary.usedPercent) end
  if stale then text ..= " !" end
  local color = stale and "on_surface_variant" or (primary and fmt.color(primary.usedPercent) or "on_surface_variant")
  local children = { ui.glyph({ name = "terminal-2", size = 16, color = color }) }
  if not barWidget.isVertical() then
    table.insert(children, ui.label({ text = text, color = color }))
    -- мини-шкала короткого окна с отметкой «по графику»
    if primary and noctalia.getConfig("bar_meter") ~= false then
      local limit = fmt.toLimit(primary, 1, bucket)
      table.insert(children, ui.progress({
        progress = primary.usedPercent / 100, width = 28, height = 5, radius = 3,
        fill = stale and "on_surface_variant" or fmt.accent(limit), track = "on_surface/0.15",
        marker = fmt.elapsed(limit), markerColor = "on_surface/0.7",
      }))
    end
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.clearTooltip()
  barWidget.render(container({ gap = 6, align = "center", onHover = "onWidgetHover" }, children))
  if hovered and noctalia.nowMs() - hoverSince >= 300 then showPreview() end
end
function onWidgetHover(value)
  hovered = value == "true"
  if hovered then
    hoverSince = noctalia.nowMs()
    noctalia.setUpdateInterval(100)
  else
    noctalia.setUpdateInterval(30000)
    hidePreview()
  end
end
function onClick()
  hidePreview()
  noctalia.togglePanel("pvs/codex-usage:panel")
end
function onRightClick() fmt.refresh() end
function onConfigChanged() update() end
function onExit() hidePreview() end
noctalia.state.watch("usage.data", function() update() end)
noctalia.state.watch("usage.panelOpen", function(value) if value == true then hidePreview() end end)
noctalia.setUpdateInterval(30000)
update()
