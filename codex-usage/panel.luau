--!nonstrict
local fmt = require("./format.luau")
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

local function windowView(window, index)
  local p = window.usedPercent
  local color = fmt.color(p)
  local stamp = window.resetsAt and noctalia.formatTime("%d.%m %H:%M", window.resetsAt) or "—"
  return ui.column({ gap = 9, paddingV = 8 }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.label({ text = (index == 1 and "Основное окно · " or "Второе окно · ") .. fmt.duration(window.durationMins), fontSize = 14, color = "on_surface", flexGrow = 1 }),
      ui.label({ text = string.format("%.0f%%", p), fontSize = 18, fontWeight = "bold", color = color }),
    }),
    ui.progress({ progress = p / 100, height = 8, fill = color, track = "surface_container_highest", radius = 4 }),
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = "clock", size = 13, color = "on_surface_variant" }),
      ui.label({ text = fmt.left(window.resetsAt), fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = stamp, fontSize = 12, color = "on_surface_variant" }),
    }),
  })
end

local function render()
  if not opened then return end
  local state = fmt.state()
  local snap = state.snapshot
  local rows = {}
  if state.error then
    table.insert(rows, ui.label({ text = fmt.error(state.error), maxLines = 4, fontSize = 13, color = "error" }))
  end
  if snap then
    if fmt.stale(state) then
      table.insert(rows, ui.label({ text = "Последние полученные данные · могут быть устаревшими", fontSize = 12, color = "error", maxLines = 2 }))
    end
    for _, bucket in ipairs(snap.limits or {}) do
      local items = {
        ui.row({ align = "center", gap = 10 }, {
          ui.label({ text = bucket.id == "codex" and "Codex" or bucket.name, fontWeight = "bold", fontSize = 16, color = "primary", flexGrow = 1 }),
          ui.label({ text = bucket.plan or "", fontSize = 12, color = "on_surface_variant" }),
        }),
      }
      if bucket.primary then table.insert(items, windowView(bucket.primary, 1)) end
      if bucket.secondary then table.insert(items, windowView(bucket.secondary, 2)) end
      if not bucket.primary and not bucket.secondary then
        table.insert(items, ui.label({ text = "Окна лимитов не предоставлены аккаунтом.", fontSize = 13, maxLines = 2, color = "on_surface_variant" }))
      end
      if bucket.creditBalance ~= nil then
        table.insert(items, ui.label({ text = "Кредиты: " .. tostring(bucket.creditBalance), fontSize = 13, color = "on_surface_variant" }))
      elseif bucket.unlimitedCredits then
        table.insert(items, ui.label({ text = "Кредиты: без ограничения", fontSize = 13, color = "on_surface_variant" }))
      end
      if bucket.reachedType then
        table.insert(items, ui.label({ text = "Ограничение: " .. bucket.reachedType, maxLines = 2, fontSize = 12, color = "error" }))
      end
      table.insert(rows, ui.column({ padding = 16, gap = 10, radius = 12, fill = "surface_container" }, items))
    end
    if snap.ordinaryUsageAllowed == false then
      table.insert(rows, ui.label({ text = "Включённое использование сейчас недоступно.", fontSize = 13, maxLines = 2, color = "error" }))
    end
    if snap.resetCredits ~= nil then
      table.insert(rows, ui.row({ gap = 10, padding = 14, fill = "surface_container", radius = 10 }, {
        ui.glyph({ name = "ticket", size = 18, color = "primary" }),
        ui.label({ text = "Доступные сбросы лимитов: " .. tostring(snap.resetCredits), fontSize = 13, color = "on_surface", maxLines = 2 }),
      }))
    end
  elseif not state.error then
    table.insert(rows, ui.label({ text = "Получаем лимиты из Codex…", fontSize = 14, color = "on_surface_variant" }))
  end
  local resetStatus = noctalia.state.get("usage.resetStatus") or {}
  if snap and snap.resetCredits ~= nil and snap.resetCredits > 0 and not fmt.stale(state) then
    if confirmReset then
      table.insert(rows, ui.column({ gap = 10, padding = 14, fill = "surface_container", radius = 10 }, {
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
  if resetText then table.insert(rows, ui.label({ text = resetText, fontSize = 13, maxLines = 4, color = resetStatus.error and "error" or "on_surface_variant" })) end
  table.insert(rows, ui.label({ text = "Проценты показывают использованную квоту. Время сброса — по данным Codex.", fontSize = 12, color = "on_surface_variant", maxLines = 3 }))
  panel.render(ui.column({ gap = 16, flexGrow = 1 }, {
    ui.row({ align = "center", gap = 12 }, {
      ui.glyph({ name = "terminal-2", size = 22, color = "primary" }),
      ui.label({ text = "Codex Usage", fontSize = 20, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", onClick = function() fmt.refresh() end }),
      ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", onClick = function() noctalia.runAsync({ "noctalia", "msg", "settings-open-plugin", "pvs/codex-usage" }) end }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = function() panel.close() end }),
    }),
    ui.column({ gap = 8 }, {
      ui.button({ text = "Открыть Codex", glyph = "terminal-2", variant = "primary", onClick = openTerminal }),
      ui.row({ gap = 8 }, {
        ui.button({ text = "Codex в браузере", glyph = "external-link", variant = "secondary", flexGrow = 1, onClick = function() openWebsite("https://chatgpt.com/codex") end }),
        ui.button({ text = "ChatGPT", glyph = "message-circle", variant = "secondary", flexGrow = 1, onClick = function() openWebsite("https://chatgpt.com/") end }),
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 14 }, rows),
    ui.label({ text = state.loading and "Обновляется…" or (snap and ("Обновлено " .. noctalia.formatTime("%H:%M:%S", snap.fetchedAt)) or "Нет данных"), fontSize = 12, color = "on_surface_variant" }),
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
function onClose() noctalia.state.set("usage.panelOpen", false); opened = false; confirmReset = false; panel.setWantsSecondTicks(false) end
function update() render() end
function onKey(chord, pressed) if pressed and chord == "ctrl+r" then fmt.refresh() end end
noctalia.state.watch("usage.data", function() render() end)

noctalia.state.watch("usage.resetStatus", function() render() end)

function onExit() noctalia.state.set("usage.panelOpen", false) end
