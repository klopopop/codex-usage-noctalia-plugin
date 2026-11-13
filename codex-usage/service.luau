--!nonstrict
-- Only this service makes requests; all displays consume shared state.
local busy = false
local nextPoll = 0
local lastGood = nil
local lastManual = 0
noctalia.setUpdateInterval(1000)

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
end
function onResume() nextPoll = 0 end
function onConfigChanged() nextPoll = 0 end
noctalia.state.watch("usage.refresh", function()
  -- Guard rapid repeated clicks as well as concurrent requests.
  if noctalia.nowMs() - lastManual < 5000 then return end
  lastManual = noctalia.nowMs()
  refresh()
end)
refresh()


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
