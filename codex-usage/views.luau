--!nonstrict
-- Общие куски интерфейса для панели и превью при наведении.
local fmt = require("./format.luau")
local M = {}

-- Массив из аргументов без nil (nil посреди {…} обрывает список детей).
local function list(...)
  local t, out = table.pack(...), {}
  for i = 1, t.n do
    if t[i] ~= nil and t[i] ~= false then
      table.insert(out, t[i])
    end
  end
  return out
end
M.list = list

local function chip(text, color)
  return ui.column({ paddingH = 8, paddingV = 3, radius = 7, fill = fmt.alpha(color, 0.14) }, {
    ui.label({ text = text, fontSize = 10, fontWeight = "bold", color = color }),
  })
end
M.chip = chip

-- Карточка лимита: название, большой процент, шкала с отметкой «по графику»,
-- время сброса; в полном виде — ещё строка темпа.
function M.limitCard(limit, compact)
  local accent = fmt.accent(limit)
  local p = limit.percent or 0
  local marker = fmt.elapsed(limit)
  local rows = {
    ui.row({ gap = 8, align = "center" }, list(
      ui.box({ width = 4, height = compact and 18 or 22, radius = 2, fill = accent }),
      ui.column({ gap = 1, flexGrow = 1 }, list(
        ui.label({ text = limit.label, fontSize = compact and 14 or 15, fontWeight = "bold", color = "on_surface" }),
        (not compact) and ui.label({ text = fmt.windowText(limit), fontSize = 11, color = "on_surface_variant" })
      )),
      limit.active and (limit.percent or 0) > 0 and chip("ИДЁТ", accent),
      ui.label({ text = string.format("%.0f%%", p), fontSize = compact and 22 or 30, fontWeight = "bold", color = accent })
    )),
    ui.progress({ progress = p / 100, height = compact and 8 or 10, radius = 5, fill = accent,
      track = "surface_container_highest", marker = marker, markerColor = "on_surface/0.55" }),
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "clock", size = 12, color = "on_surface_variant" }),
      ui.label({ text = "сброс через " .. fmt.left(limit.resetsAt), fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = fmt.resetStamp(limit), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    }),
  }
  if not compact then
    local pace = fmt.pace(limit)
    if pace ~= nil then
      table.insert(rows, ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "activity", size = 12, color = pace.color }),
        ui.label({ text = pace.text, fontSize = 11, color = pace.color, maxLines = 2, flexGrow = 1 }),
      }))
    end
  end
  return ui.column({ gap = compact and 8 or 10, paddingH = 14, paddingV = compact and 11 or 14, radius = 14,
    fill = "surface_container_high", border = fmt.alpha(accent, 0.25), borderWidth = 1 }, rows)
end

-- Плитка-цифра: значок, значение, подпись.
function M.tile(glyph, value, caption, accent)
  return ui.column({ gap = 4, paddingH = 12, paddingV = 10, radius = 12, flexGrow = 1, fill = "surface_container_high" }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = glyph, size = 13, color = accent }),
      ui.label({ text = caption, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.label({ text = value, fontSize = 20, fontWeight = "bold", color = "on_surface" }),
  })
end

-- Столбики по дням (14 дней), сегодня — акцентом.
function M.dayBars(days, height, accent)
  local max = 1
  for _, d in ipairs(days or {}) do
    max = math.max(max, d.fresh or 0)
  end
  local cols = {}
  for i, d in ipairs(days or {}) do
    local isToday = i == #days
    local h = math.floor((d.fresh or 0) / max * (height - 4) + 0.5)
    local fill = isToday and accent or fmt.alpha(accent, d.weekday >= 5 and 0.3 or 0.5)
    table.insert(cols, ui.column({ key = "d" .. d.date, gap = 4, flexGrow = 1, align = "stretch",
      tooltip = string.format("%s %s · %s токенов · %d сообщ. · %d сесс.", fmt.weekday(d.weekday), string.sub(d.date, 9, 10) .. "." .. string.sub(d.date, 6, 7), fmt.tokens(d.fresh), d.messages or 0, d.sessions or 0) }, {
      ui.column({ height = height, justify = "end", align = "stretch" }, {
        ui.box({ height = math.max(h, (d.fresh or 0) > 0 and 3 or 2), radius = 3, fill = (d.fresh or 0) > 0 and fill or "on_surface/0.08" }),
      }),
      ui.row({ justify = "center" }, {
        ui.label({ text = fmt.weekday(d.weekday), fontSize = 9, color = isToday and accent or "on_surface_variant" }),
      }),
    }))
  end
  return ui.row({ gap = 4, align = "end" }, cols)
end

-- Тепловая карта 7 дней × 24 часа: насыщенность — число ответов Claude.
function M.heatmap(heat, days, accent, cell)
  cell = cell or 12
  local max = 1
  for _, row in ipairs(heat or {}) do
    for _, v in ipairs(row) do
      max = math.max(max, v)
    end
  end
  local rows = {}
  local offset = #(days or {}) - #(heat or {})
  for r, row in ipairs(heat or {}) do
    local d = days[offset + r]
    local cells = { ui.label({ text = d and fmt.weekday(d.weekday) or "", fontSize = 9, color = "on_surface_variant", width = 18 }) }
    for hour, v in ipairs(row) do
      local a = v > 0 and (0.18 + 0.82 * math.sqrt(v / max)) or 0
      table.insert(cells, ui.box({
        width = cell, height = cell, radius = 3,
        fill = v > 0 and fmt.alpha(accent, a) or "on_surface/0.06",
        tooltip = v > 0 and string.format("%02d:00 · ответов: %d", hour - 1, v) or nil,
      }))
    end
    table.insert(rows, ui.row({ gap = 2, align = "center" }, cells))
  end
  local ticks = { ui.box({ width = 18, height = 1, fill = "#00000000" }) }
  for hour = 0, 23 do
    -- пустая подпись схлопывается в 0 — ширину держит обёртка
    table.insert(ticks, ui.row({ width = cell, height = 12 }, {
      ui.label({ text = hour % 6 == 0 and tostring(hour) or " ", fontSize = 9, color = "on_surface_variant" }),
    }))
  end
  table.insert(rows, ui.row({ gap = 2 }, ticks))
  return ui.column({ gap = 2 }, rows)
end

-- Список с долями: имя, полоска, значение.
function M.shares(items, accent, valueOf)
  local rows = {}
  for i, it in ipairs(items or {}) do
    table.insert(rows, ui.column({ key = "s" .. i .. (it.name or ""), gap = 4, tooltip = it.path }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = it.name or "?", fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
        ui.label({ text = valueOf(it), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.progress({ progress = math.max(0.01, it.share or 0), height = 5, radius = 3, fill = i == 1 and accent or fmt.alpha(accent, 0.55), track = "on_surface/0.07" }),
    }))
  end
  return ui.column({ gap = 9 }, rows)
end

return M
