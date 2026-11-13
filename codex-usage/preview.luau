--!nonstrict
-- Read-only hover surface: no focus, no pointer region, no account requests.
local fmt = require("./format.luau")
local function quota(window, secondary)
  local p = window.usedPercent
  local accent = secondary and "#B8AEFF" or "#6EDCB4"
  if p >= 90 then accent = "#FF7E91"
  elseif p >= 70 then accent = "#F0CA78" end
  local title = secondary and "Длинное окно" or "Короткое окно"
  if window.durationMins == 300 then title = "Сессия"
  elseif window.durationMins == 10080 then title = "Неделя" end
  local resetLabel = "Срок сброса не указан"
  if window.resetsAt ~= nil then
    resetLabel = window.resetsAt <= math.floor(noctalia.nowMs() / 1000)
      and "Ожидается обновление лимита" or ("сброс через " .. fmt.left(window.resetsAt))
  end
  return ui.column({ gap = 9, paddingH = 14, paddingV = 12, radius = 12, fill = "surface_container_high" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.box({ width = 4, height = 18, radius = 2, fill = accent }),
      ui.label({ text = title, fontSize = 14, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.label({ text = fmt.duration(window.durationMins), fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = string.format("%.0f%%", p), fontSize = 22, fontWeight = "bold", color = accent }),
    }),
    ui.progress({ progress = p / 100, height = 8, radius = 4, fill = accent, track = "surface_container_highest" }),
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "clock", size = 12, color = "on_surface_variant" }),
      ui.label({ text = resetLabel, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = string.format("%.0f%% осталось", 100 - p), fontSize = 11, color = accent }),
    }),
  })
end

function update()
  local state = fmt.state()
  local snap = state.snapshot
  local bucket = snap and snap.limits and snap.limits[1] or nil
  local stale = fmt.stale(state)
  local rows = {
    ui.row({ gap = 9, align = "center" }, {
      ui.column({ width = 32, height = 32, radius = 10, fill = "primary/0.15", align = "center", justify = "center" }, {
        ui.glyph({ name = "terminal-2", size = 19, color = "primary" }),
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = "Codex", fontSize = 17, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = "Использование квоты", fontSize = 10, color = "on_surface_variant" }),
      }),
      ui.column({ paddingH = 9, paddingV = 4, radius = 7, fill = "primary/0.12" }, {
        ui.label({ text = bucket and string.upper(bucket.plan or "CODEX") or "CODEX", fontSize = 10, fontWeight = "bold", color = "primary" }),
      }),
    }),
  }
  if bucket and bucket.primary then table.insert(rows, quota(bucket.primary, false)) end
  if bucket and bucket.secondary then table.insert(rows, quota(bucket.secondary, true)) end
  if not bucket or (not bucket.primary and not bucket.secondary) then
    table.insert(rows, ui.label({ text = state.error and fmt.error(state.error) or "Лимиты пока не получены", fontSize = 12, color = "on_surface_variant", maxLines = 4 }))
  end
  if stale then
    table.insert(rows, ui.label({ text = "Последние данные · требуется обновление", fontSize = 10, color = "#F0CA78", maxLines = 2 }))
  end
  table.insert(rows, ui.spacer({ flexGrow = 1 }))
  table.insert(rows, ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "mouse", size = 12, color = "on_surface_variant" }),
    ui.label({ text = "Клик — панель", fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
    ui.label({ text = state.loading and "обновляется…" or (snap and noctalia.formatTime("%H:%M", snap.fetchedAt) or ""), fontSize = 10, color = "on_surface_variant" }),
  }))
  layer.render(ui.column({ padding = 16, gap = 12, flexGrow = 1, fill = "surface", radius = 18,
    border = "outline_variant/0.6", borderWidth = 1 }, rows))
end
noctalia.setUpdateInterval(1000)
noctalia.state.watch("usage.data", function() update() end)
update()
