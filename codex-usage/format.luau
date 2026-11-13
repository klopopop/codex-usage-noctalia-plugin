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
return M
