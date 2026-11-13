--!nonstrict
-- Карточка при наведении: только чтение, без фокуса, кликов и запросов.
-- Дизайн общий с Claude Usage (views.luau).
local fmt = require("./format.luau")
local views = require("./views.luau")

function update()
  local state = fmt.state()
  local snap = state.snapshot
  local st = fmt.stats()
  local bucket = snap and snap.limits and snap.limits[1] or nil
  local rows = {
    ui.row({ gap = 10, align = "center" }, {
      ui.column({ width = 34, height = 34, radius = 10, fill = fmt.alpha(fmt.SESSION, 0.18), align = "center", justify = "center" }, {
        ui.glyph({ name = "terminal-2", size = 19, color = fmt.SESSION }),
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = "Codex", fontSize = 17, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = "Использование квоты", fontSize = 10, color = "on_surface_variant" }),
      }),
      views.chip(bucket and string.upper(bucket.plan or "CODEX") or "CODEX", fmt.SESSION),
    }),
  }
  local shown = 0
  for _, l in ipairs(fmt.limits()) do
    if shown < 2 then
      table.insert(rows, views.limitCard(l, true))
      shown += 1
    end
  end
  if shown == 0 then
    table.insert(rows, ui.label({ text = state.error and fmt.error(state.error) or "Лимиты пока не получены", fontSize = 12, color = "on_surface_variant", maxLines = 4 }))
  end
  if st.today ~= nil then
    table.insert(rows, ui.column({ gap = 8, paddingH = 14, paddingV = 10, radius = 14, fill = "surface_container_high" }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "calendar-event", size = 12, color = "on_surface_variant" }),
        ui.label({ text = string.format("Сегодня: %d ответов · %s токенов", st.today.messages or 0, fmt.tokens(st.today.fresh)), fontSize = 11, color = "on_surface", flexGrow = 1, maxLines = 1 }),
      }),
      views.dayBars(st.days, 34, fmt.SESSION),
    }))
  end
  if fmt.stale(state) and snap ~= nil then
    table.insert(rows, ui.label({ text = "Последние данные · требуется обновление", fontSize = 10, color = fmt.WARN, maxLines = 2 }))
  end
  table.insert(rows, ui.spacer({ flexGrow = 1 }))
  table.insert(rows, ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "mouse", size = 12, color = "on_surface_variant" }),
    ui.label({ text = "Клик — панель · правый — обновить", fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
    ui.label({ text = state.loading and "обновляется…" or (snap and noctalia.formatTime("%H:%M", snap.fetchedAt) or ""), fontSize = 10, color = "on_surface_variant" }),
  }))
  layer.render(ui.column({ padding = 16, gap = 10, flexGrow = 1, fill = "surface", radius = 18,
    border = "outline_variant/0.6", borderWidth = 1 }, rows))
end

noctalia.setUpdateInterval(1000)
noctalia.state.watch("usage.data", function() update() end)
noctalia.state.watch("usage.stats", function() update() end)
update()
