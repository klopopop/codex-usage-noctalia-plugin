--!nonstrict
-- Панель: окна лимитов Codex с отметкой графика и прогнозом, сбросы лимитов,
-- статистика Codex из ~/.codex/sessions: сегодня, 14 дней, часы, модели,
-- проекты. Дизайн общий с плагином Claude Usage (views.luau).
local fmt = require("./format.luau")
local views = require("./views.luau")
local list = views.list
local opened = false
local launching = false
local confirmReset = false

local function openTerminal()
  if launching then return end
  launching = true
  panel.close()
  local accepted = noctalia.runAsync({ "python3", noctalia.pluginDir() .. "/tools/terminal.py", "show",
    "--codex", noctalia.expandPath(noctalia.getConfig("codex_path") or "codex"),
    "--directory", noctalia.expandPath(noctalia.getConfig("terminal_directory") or "~") }, function(result)
    launching = false
    if result.exitCode ~= 0 then
      noctalia.notifyError("Codex", result.stderr ~= "" and result.stderr or "Не удалось открыть терминал.")
    end
  end)
  if not accepted then
    launching = false
    noctalia.notifyError("Codex", "Не удалось запустить терминал.")
  end
end

local function openWebsite(url)
  panel.close()
  local accepted = noctalia.runAsync({ "xdg-open", url }, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError("Codex Usage", "Не удалось открыть браузер по умолчанию.")
    end
  end)
  if not accepted then
    noctalia.notifyError("Codex Usage", "Не удалось запустить браузер.")
  end
end

local function section(glyph, title, extra)
  return ui.row({ gap = 8, align = "center", paddingV = 2 }, list(
    ui.glyph({ name = glyph, size = 14, color = "primary" }),
    ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    extra
  ))
end

local function card(children)
  return ui.column({ gap = 12, padding = 14, radius = 14, fill = "surface_container" }, children)
end

local function header(snap)
  local bucket = snap and snap.limits and snap.limits[1] or nil
  return ui.row({ align = "center", gap = 12 }, {
    ui.column({ width = 40, height = 40, radius = 12, fill = fmt.alpha(fmt.SESSION, 0.18), align = "center", justify = "center" }, {
      ui.glyph({ name = "terminal-2", size = 22, color = fmt.SESSION }),
    }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = "Codex", fontSize = 20, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = "Использование квоты", fontSize = 11, color = "on_surface_variant" }),
    }),
    views.chip(bucket and string.upper(bucket.plan or "CODEX") or "CODEX", fmt.SESSION),
    ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Обновить (Ctrl+R)", onClick = function() fmt.refresh() end }),
    ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = "Настройки",
      onClick = function() noctalia.runAsync({ "noctalia", "msg", "settings-open-plugin", "pvs/codex-usage" }) end }),
    ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = function() panel.close() end }),
  })
end

local function limitsBlock(state)
  local rows = {}
  local snap = state.snapshot
  if state.error then
    table.insert(rows, ui.row({ gap = 10, padding = 12, radius = 12, fill = "error/0.12" }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
      ui.label({ text = fmt.error(state.error) .. (snap and " Ниже — последние полученные данные." or ""), fontSize = 12, color = "on_surface", maxLines = 4, flexGrow = 1 }),
    }))
  end
  if snap == nil then
    if not state.error then
      table.insert(rows, ui.label({ text = "Получаем лимиты из Codex…", fontSize = 13, color = "on_surface_variant" }))
    end
    return rows
  end
  local limits = fmt.limits()
  for _, l in ipairs(limits) do
    table.insert(rows, views.limitCard(l, false))
  end
  if #limits == 0 then
    table.insert(rows, ui.label({ text = "Окна лимитов не предоставлены аккаунтом.", fontSize = 13, maxLines = 2, color = "on_surface_variant" }))
  end
  -- кредиты, ограничения, сбросы
  local facts = {}
  for _, bucket in ipairs(snap.limits or {}) do
    if bucket.creditBalance ~= nil and tostring(bucket.creditBalance) ~= "0" then
      table.insert(facts, { "coin", "Кредиты: " .. tostring(bucket.creditBalance), "on_surface" })
    elseif bucket.unlimitedCredits then
      table.insert(facts, { "coin", "Кредиты: без ограничения", "on_surface" })
    end
    if bucket.reachedType then
      table.insert(facts, { "alert-triangle", "Ограничение: " .. bucket.reachedType, "error" })
    end
  end
  if snap.ordinaryUsageAllowed == false then
    table.insert(facts, { "alert-triangle", "Включённое использование сейчас недоступно.", "error" })
  end
  if snap.resetCredits ~= nil then
    table.insert(facts, { "ticket", "Доступные сбросы лимитов: " .. tostring(snap.resetCredits), "on_surface" })
  end
  for _, f in ipairs(facts) do
    table.insert(rows, ui.row({ gap = 10, paddingH = 14, paddingV = 10, radius = 12, fill = "surface_container" }, {
      ui.glyph({ name = f[1], size = 15, color = f[3] == "error" and "error" or fmt.SESSION }),
      ui.label({ text = f[2], fontSize = 12, color = f[3], maxLines = 2, flexGrow = 1 }),
    }))
  end
  -- сброс лимитов: только по явному подтверждению
  local resetStatus = noctalia.state.get("usage.resetStatus") or {}
  if snap.resetCredits ~= nil and snap.resetCredits > 0 and not fmt.stale(state) then
    if confirmReset then
      table.insert(rows, ui.column({ gap = 10, padding = 14, fill = "surface_container", radius = 12 }, {
        ui.label({ text = "Использовать один доступный сброс? Codex сбросит подходящие окна лимитов.", fontSize = 13, maxLines = 3, color = "on_surface" }),
        ui.row({ gap = 8 }, {
          ui.button({ text = "Отмена", variant = "ghost", onClick = function() confirmReset = false; render() end }),
          ui.button({ text = "Использовать сброс", variant = "primary", onClick = function()
            confirmReset = false
            noctalia.state.set("usage.reset", noctalia.nowMs())
            render()
          end }),
        }),
      }))
    elseif not resetStatus.loading and not state.loading then
      table.insert(rows, ui.button({ text = "Сбросить лимиты…", glyph = "refresh", variant = "secondary", onClick = function() confirmReset = true; render() end }))
    end
  end
  local resetText = nil
  if resetStatus.loading then resetText = "Выполняется сброс…"
  elseif resetStatus.outcome == "reset" then resetText = "Лимиты сброшены. Использован один сброс."
  elseif resetStatus.outcome == "alreadyRedeemed" then resetText = "Этот сброс уже выполнен. Повторно он не списан."
  elseif resetStatus.outcome == "nothingToReset" then resetText = "Codex не нашёл подходящих для сброса окон."
  elseif resetStatus.outcome == "noCredit" then resetText = "Доступных сбросов больше нет."
  elseif resetStatus.error == "busy" then resetText = "Дождись окончания обновления и повтори действие."
  elseif resetStatus.error == "pending_reset" then resetText = "Не удалось прочитать сохранённую попытку сброса. Нужна проверка файла состояния."
  elseif resetStatus.error then resetText = "Результат сброса не подтверждён. При повторе используется тот же ключ операции."
  end
  if resetText then
    table.insert(rows, ui.label({ text = resetText, fontSize = 12, maxLines = 4, color = resetStatus.error and "error" or "on_surface_variant" }))
  end
  return rows
end

local function statsBlock(st)
  if st.today == nil then
    return { card({ ui.label({ text = "Считаем статистику из журналов Codex…", fontSize = 12, color = "on_surface_variant" }) }) }
  end
  local blocks = {}
  local today, week, prev = st.today, st.week, st.prevWeek or {}
  local accent = fmt.SESSION

  table.insert(blocks, card({
    section("calendar-event", "Сегодня", (st.streak or 0) > 1 and views.chip(st.streak .. " ДН. ПОДРЯД", fmt.WEEK) or nil),
    ui.row({ gap = 8 }, {
      views.tile("message-chatbot", tostring(today.messages or 0), "ответов", accent),
      views.tile("terminal-2", tostring(today.sessions or 0), "сессий", fmt.WEEK),
      views.tile("pencil", fmt.tokens(today.output), "написано", fmt.SCOPED),
      views.tile("stack-2", fmt.tokens(today.total), "контекст", fmt.WARN),
    }),
  }))

  local delta = nil
  if (prev.fresh or 0) > 0 then
    local ratio = (week.fresh or 0) / prev.fresh
    local d = math.floor((ratio - 1) * 100 + 0.5)
    -- при росте в разы проценты нечитаемы: «×17»
    local text = ratio >= 3 and string.format("×%.0f К ПРОШЛОЙ", ratio) or ((d >= 0 and "+" or "") .. d .. "% К ПРОШЛОЙ")
    delta = views.chip(text, d >= 0 and fmt.WARN or fmt.SESSION)
  end
  table.insert(blocks, card({
    section("chart-bar", "14 дней", delta),
    views.dayBars(st.days, 74, accent),
    ui.row({ gap = 14 }, {
      ui.label({ text = "За неделю: " .. fmt.tokens(week.fresh) .. " токенов", fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = (week.messages or 0) .. " ответов · " .. (week.sessions or 0) .. " сессий", fontSize = 11, color = "on_surface_variant" }),
    }),
  }))

  table.insert(blocks, card({
    section("flame", "Когда работаю · 7 дней"),
    views.heatmap(st.heat, st.days, accent, 17),
  }))

  local parts = {}
  if st.models and #st.models > 0 then
    table.insert(parts, section("cpu", "Модели · 7 дней"))
    table.insert(parts, views.shares(st.models, fmt.WEEK, function(it) return fmt.tokens(it.tokens) end))
  end
  if st.projects and #st.projects > 0 then
    table.insert(parts, section("folder", "Проекты · 7 дней"))
    table.insert(parts, views.shares(st.projects, fmt.SCOPED, function(it)
      return fmt.tokens(it.tokens) .. " · " .. it.days .. " дн."
    end))
  end
  if #parts > 0 then
    table.insert(blocks, card(parts))
  end
  return blocks
end

function render()
  if not opened then return end
  local state = fmt.state()
  local snap = state.snapshot
  local body = {}
  for _, b in ipairs(limitsBlock(state)) do
    table.insert(body, b)
  end
  for _, b in ipairs(statsBlock(fmt.stats())) do
    table.insert(body, b)
  end
  table.insert(body, ui.label({
    text = "Проценты — использованная квота, время сброса — по данным Codex. Отметка на шкале — где был бы расход, если тратить ровно до сброса. Токены — из журналов ~/.codex/sessions; «контекст» — с кешем.",
    fontSize = 10, color = "on_surface_variant", maxLines = 4 }))

  local updated = state.loading and "обновляется…"
    or (snap and ("обновлено " .. noctalia.formatTime("%H:%M:%S", snap.fetchedAt)) or "нет данных")
  panel.render(ui.column({ gap = 14, flexGrow = 1 }, {
    header(snap),
    ui.scroll({ flexGrow = 1, gap = 12 }, body),
    ui.row({ gap = 8 }, {
      ui.button({ text = "Открыть Codex", glyph = "terminal-2", variant = "primary", flexGrow = 1, onClick = openTerminal }),
      ui.button({ text = "Codex", glyph = "external-link", variant = "secondary", tooltip = "Codex в браузере", onClick = function() openWebsite("https://chatgpt.com/codex") end }),
      ui.button({ text = "ChatGPT", glyph = "message-circle", variant = "secondary", onClick = function() openWebsite("https://chatgpt.com/") end }),
    }),
    ui.label({ text = updated .. " · правый клик по значку — обновить", fontSize = 10, color = "on_surface_variant" }),
  }))
end

function onOpen()
  opened = true
  noctalia.state.set("usage.panelOpen", true)
  panel.setWantsSecondTicks(true)
  render()
  local state = fmt.state()
  if state.snapshot == nil or fmt.stale(state) then fmt.refresh() end
end

function onClose()
  noctalia.state.set("usage.panelOpen", false)
  opened = false
  confirmReset = false
  panel.setWantsSecondTicks(false)
end

local ticks = 0
function update()
  ticks += 1
  if ticks % 15 == 0 then render() end
end

function onKey(chord, pressed) if pressed and chord == "ctrl+r" then fmt.refresh() end end
noctalia.state.watch("usage.data", function() render() end)
noctalia.state.watch("usage.stats", function() render() end)
noctalia.state.watch("usage.resetStatus", function() render() end)

function onExit() noctalia.state.set("usage.panelOpen", false) end
