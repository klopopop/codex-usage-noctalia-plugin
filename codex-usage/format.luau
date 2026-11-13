--!nonstrict
local M = {}
function M.state()
  return noctalia.state.get("usage.data") or {}
end
function M.duration(minutes)
  if minutes == nil then return "окно" end
  if minutes % 1440 == 0 then return tostring(minutes / 1440) .. " д" end
  if minutes % 60 == 0 then return tostring(minutes / 60) .. " ч" end
  return tostring(minutes) .. " мин"
end
function M.left(timestamp)
  if timestamp == nil then return "срок сброса неизвестен" end
  local sec = math.max(0, timestamp - math.floor(noctalia.nowMs() / 1000))
  if sec == 0 then return "ожидается обновление лимита" end
  local mins = math.ceil(sec / 60)
  if mins >= 1440 then return string.format("%d д %d ч", mins // 1440, (mins % 1440) // 60) end
  if mins >= 60 then return string.format("%d ч %d мин", mins // 60, mins % 60) end
  return tostring(mins) .. " мин"
end
function M.color(percent)
  if percent >= 90 then return "error" end
  if percent >= 70 then return "#E7C46A" end
  return "primary"
end
function M.stale(state)
  return state.error ~= nil or (state.snapshot ~= nil and
    noctalia.nowMs() / 1000 - state.snapshot.fetchedAt > math.max(60, tonumber(noctalia.getConfig("refresh_seconds")) or 120) * 2)
end
function M.error(code)
  if code == "login_required" then return "Нужен вход через codex login с аккаунтом ChatGPT." end
  if code == "missing_codex" then return "Codex CLI не найден. Укажи полный путь в настройках плагина." end
  if code == "timeout" then return "Codex не ответил вовремя. Повторим автоматически." end
  if code == "protocol" then return "Неизвестный формат лимитов. Проверь версию Codex CLI." end
  return "Не удалось получить лимиты. Проверь подключение и вход в Codex."
end
function M.refresh() noctalia.state.set("usage.refresh", noctalia.nowMs()) end

-- ── Общее с плагином Claude Usage: окна лимитов, темп, статистика ──

M.SESSION = "#6EDCB4" -- короткое окно (обычно 5 ч)
M.WEEK = "#B8AEFF" -- длинное окно (обычно неделя)
M.SCOPED = "#7CC4FF" -- прочие квоты
M.WARN = "#F0CA78"
M.HOT = "#FF7E91"
local WEEKDAYS = { "Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс" }

-- Цвет с прозрачностью: роль → "role/0.3", hex → "#rrggbbaa"
function M.alpha(color, a)
  if string.sub(color, 1, 1) == "#" and #color == 7 then
    return color .. string.format("%02X", math.floor(math.max(0, math.min(1, a)) * 255 + 0.5))
  end
  return color .. "/" .. tostring(a)
end

function M.now()
  return math.floor(noctalia.nowMs() / 1000)
end

function M.stats()
  return noctalia.state.get("usage.stats") or {}
end

-- Окно лимита Codex → общий вид { kind, label, percent, resetsAt, windowSec }.
function M.toLimit(window, index, bucket)
  local mins = window.durationMins
  local label = (index == 1 and "Короткое окно" or "Длинное окно")
  if mins == 300 then
    label = "Сессия"
  elseif mins == 10080 then
    label = "Неделя"
  end
  if bucket ~= nil and bucket.id ~= "codex" then
    label = (bucket.name or bucket.id) .. " · " .. label
  end
  return {
    kind = index == 1 and "primary" or "secondary",
    label = label,
    percent = window.usedPercent or 0,
    resetsAt = window.resetsAt,
    windowSec = mins and mins * 60 or nil,
    active = index == 1 and (window.usedPercent or 0) > 0,
  }
end

-- Все окна всех квот в общем виде.
function M.limits()
  local snap = M.state().snapshot
  local out = {}
  for _, bucket in ipairs(snap and snap.limits or {}) do
    if bucket.primary then
      table.insert(out, M.toLimit(bucket.primary, 1, bucket))
    end
    if bucket.secondary then
      table.insert(out, M.toLimit(bucket.secondary, 2, bucket))
    end
  end
  return out
end

function M.windowText(limit)
  return "окно " .. M.duration(limit.windowSec and limit.windowSec // 60 or nil)
end

function M.accent(limit)
  local p = limit.percent or 0
  if p >= 90 then
    return M.HOT
  end
  if p >= 70 then
    return M.WARN
  end
  if string.find(limit.label, " · ", 1, true) then
    return M.SCOPED
  end
  return limit.kind == "primary" and M.SESSION or M.WEEK
end

function M.when(ts)
  if ts == nil then
    return "—"
  end
  if os.date("%Y-%m-%d", ts) == os.date("%Y-%m-%d") then
    return noctalia.formatTime("%H:%M", ts)
  end
  local wday = os.date("*t", ts).wday -- 1 = воскресенье (%u Luau не знает)
  return WEEKDAYS[(wday + 5) % 7 + 1] .. " " .. noctalia.formatTime("%H:%M", ts)
end

function M.resetStamp(limit)
  return M.when(limit.resetsAt)
end

-- Доля прошедшего окна (0–1) — отметка «по графику» на шкале.
function M.elapsed(limit)
  if limit.windowSec == nil or limit.resetsAt == nil then
    return nil
  end
  local left = math.max(0, limit.resetsAt - M.now())
  return math.max(0, math.min(1, 1 - left / limit.windowSec))
end

-- Темп: хватит ли до сброса при текущей скорости.
function M.pace(limit)
  local e = M.elapsed(limit)
  local p = limit.percent or 0
  if e == nil or e < 0.1 then -- в начале окна прогноз шумит
    return nil
  end
  if p >= 100 then
    return { text = "лимит исчерпан", color = M.HOT }
  end
  if p > 0 then
    local rate = p / (e * limit.windowSec)
    local secsTo100 = (100 - p) / rate
    local left = limit.resetsAt - M.now()
    if secsTo100 < left then
      local early = left - secsTo100
      local by = early >= 86400 and string.format("%d д %d ч", early // 86400, (early % 86400) // 3600)
        or (early >= 3600 and string.format("%d ч %02d мин", early // 3600, (early % 3600) // 60) or (math.ceil(early / 60) .. " мин"))
      return { text = "при таком темпе кончится к " .. M.when(M.now() + math.floor(secsTo100)) .. " — за " .. by .. " до сброса", color = p >= 70 and M.HOT or M.WARN }
    end
  end
  local diff = p - e * 100
  if diff > 8 then
    return { text = "быстрее графика, но до сброса хватит", color = "on_surface_variant" }
  end
  if diff < -8 then
    return { text = "с запасом: " .. string.format("%.0f%%", -diff) .. " ниже графика", color = "on_surface_variant" }
  end
  return { text = "идёт по графику", color = "on_surface_variant" }
end

function M.tokens(n)
  n = tonumber(n) or 0
  if n >= 1e9 then
    return string.format("%.2fB", n / 1e9)
  end
  if n >= 1e6 then
    return string.format("%.1fM", n / 1e6)
  end
  if n >= 1e3 then
    return string.format("%.0fK", n / 1e3)
  end
  return tostring(math.floor(n))
end

function M.weekday(index0)
  return WEEKDAYS[(index0 or 0) + 1]
end

return M
