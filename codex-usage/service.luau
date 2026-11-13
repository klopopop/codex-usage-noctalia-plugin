--!nonstrict
-- Only this service makes requests; all displays consume shared state.
local busy = false
local nextPoll = 0
local lastGood = nil
local lastManual = 0
local statsBusy, nextStats = false, 0
local warned = {} -- [окно] = { resetsAt, level }
noctalia.setUpdateInterval(1000)

-- resets_at может слегка гулять — новое окно, только если сдвиг > 10 мин
local function sameWindow(a, b)
  return a ~= nil and b ~= nil and math.abs(a - b) <= 600
end

-- Уведомления: окно перешло 80% / 95%, окно сброшено после 80%+.
local function notifyLimits(snap, silent)
  silent = silent or noctalia.getConfig("notify") == false
  local bucket = snap.limits and snap.limits[1]
  if bucket == nil then return end
  for index, window in ipairs({ bucket.primary or false, bucket.secondary or false }) do
    if window then
      local key = index == 1 and "primary" or "secondary"
      local title = "Codex: " .. (window.durationMins == 300 and "сессия" or (window.durationMins == 10080 and "неделя" or "окно"))
      local w = warned[key]
      if w ~= nil and not sameWindow(window.resetsAt, w.resetsAt) and w.level >= 80 and window.usedPercent < w.level then
        if not silent then
          noctalia.notify(title .. " — лимит сброшен", string.format("Использовано %.0f%%. Можно работать.", window.usedPercent))
        end
        w = nil
      end
      if w == nil or not sameWindow(w.resetsAt, window.resetsAt) then
        w = { resetsAt = window.resetsAt, level = 0 }
      end
      local level = window.usedPercent >= 95 and 95 or (window.usedPercent >= 80 and 80 or 0)
      if level > w.level and not silent then
        local left = window.resetsAt and math.max(0, window.resetsAt - math.floor(noctalia.nowMs() / 1000)) or nil
        noctalia.notify(title .. string.format(": %.0f%%", window.usedPercent),
          left and string.format("Сброс через %d ч %02d мин.", left // 3600, (left % 3600) // 60) or "")
      end
      w.level = math.max(w.level, level)
      warned[key] = w
    end
  end
end

-- Локальная статистика из ~/.codex/sessions (инкрементально, ~0.1 с).
local function refreshStats()
  if statsBusy then return end
  statsBusy = true
  nextStats = noctalia.nowMs() + 60000
  local accepted = noctalia.runAsync({ "python3", noctalia.pluginDir() .. "/tools/stats.py" }, function(result)
    statsBusy = false
    local ok, data = pcall(noctalia.json.decode, result.stdout or "")
    if result.exitCode == 0 and ok and type(data) == "table" and data.ok == true then
      noctalia.state.set("usage.stats", data)
    end
  end)
  if not accepted then statsBusy = false end
end

local function publish(error)
  noctalia.state.set("usage.data", {
    snapshot = lastGood, error = error, loading = busy,
    checkedAt = math.floor(noctalia.nowMs() / 1000),
  })
end

local function refresh()
  if busy then return end
  busy = true
  nextPoll = noctalia.nowMs() + math.max(60, tonumber(noctalia.getConfig("refresh_seconds")) or 120) * 1000
  publish(nil)
  local accepted = noctalia.runAsync({ "python3", noctalia.pluginDir() .. "/tools/usage.py",
    "--codex", noctalia.expandPath(noctalia.getConfig("codex_path") or "codex") }, function(result)
    busy = false
    local ok, data = pcall(noctalia.json.decode, result.stdout or "")
    if result.exitCode == 0 and ok and type(data) == "table" and data.ok == true then
      -- первый ответ — только запомнить уровни, без уведомлений
      notifyLimits(data, lastGood == nil)
      lastGood = data
      publish(nil)
    else
      publish(ok and type(data) == "table" and data.error or "unavailable")
    end
  end)
  if not accepted then busy = false; publish("unavailable") end
end

function update()
  if noctalia.nowMs() >= nextPoll then refresh() end
  if noctalia.nowMs() >= nextStats then refreshStats() end
end
function onResume() nextPoll = 0; nextStats = 0 end
function onConfigChanged() nextPoll = 0 end
noctalia.state.watch("usage.refresh", function()
  -- Guard rapid repeated clicks as well as concurrent requests.
  if noctalia.nowMs() - lastManual < 5000 then return end
  lastManual = noctalia.nowMs()
  refresh()
  refreshStats()
end)
noctalia.state.watch("usage.panelOpen", function(value)
  if value == true then refreshStats() end
end)
refresh()
refreshStats()


-- Explicit user confirmation only. Never consume a reset credit on a timer.
noctalia.state.watch("usage.reset", function()
  if busy then
    noctalia.state.set("usage.resetStatus", { error = "busy" })
    return
  end
  busy = true
  publish(nil)
  noctalia.state.set("usage.resetStatus", { loading = true })
  local accepted = noctalia.runAsync({ "python3", noctalia.pluginDir() .. "/tools/usage.py",
    "--codex", noctalia.expandPath(noctalia.getConfig("codex_path") or "codex"), "--reset" }, function(result)
    busy = false
    local ok, data = pcall(noctalia.json.decode, result.stdout or "")
    if result.exitCode == 0 and ok and type(data) == "table" and data.ok == true then
      noctalia.state.set("usage.resetStatus", { outcome = data.outcome })
    else
      noctalia.state.set("usage.resetStatus", { error = ok and type(data) == "table" and data.error or "unavailable" })
    end
    refresh()
  end)
  if not accepted then
    busy = false
    publish(nil)
    noctalia.state.set("usage.resetStatus", { error = "unavailable" })
  end
end)
