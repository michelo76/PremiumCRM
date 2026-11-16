--[[
c4.status -- human-readable text for the read-only status properties. Pure.

  Status.text(state, engine_status, info) -> "Playing — The Bear (Netflix on Living Room Roku)"
  Status.active_source(state, engine_status) -> "Roku: Living Room Roku"
  Status.metadata_sources(info) -> "TMDB, OMDb, Music (iTunes/MusicBrainz)" | "None"
]]

local flatten = require("np.flatten")

local M = {}

M.NOT_CONFIGURED = "Not configured: set a Roku Address, an Apple TV bridge + device, a Home Assistant " ..
  "URL/token/entity, or turn Use Control4 Room Media On"

local LABELS = {
  roku = "Roku", appletv = "Apple TV", homeassistant = "Home Assistant", c4room = "Control4 Room",
  bridge = "Apple TV",
}

local STATE_WORDS = {
  playing = "Playing", paused = "Paused", buffering = "Buffering", stopped = "Stopped",
  idle = "Idle", off = "Off",
}

local function short(s, n)
  s = tostring(s or "")
  if #s > n then s = s:sub(1, n - 3) .. "..." end
  return s
end

function M.label(id)
  return LABELS[tostring(id or "")] or tostring(id or "?")
end

function M.text(state, est, info)
  info = info or {}
  if info.configured == false then return M.NOT_CONFIGURED end
  local parts = {}
  if info.gated then
    parts[1] = "Off — room is off (Show Only When Room Is On)"
  elseif state then
    local st = state.playback and state.playback.state or "idle"
    local word = STATE_WORDS[st] or st
    local l1, l2 = flatten.display_lines(state)
    if st == "idle" or st == "stopped" or st == "off" then
      parts[1] = (l1 ~= "" and l1 ~= word and l1 ~= "Off") and (word .. " — " .. l1) or word
    else
      local s = word
      if l1 ~= "" then s = s .. " — " .. l1 end
      if l2 ~= "" then s = s .. " (" .. l2 .. ")" end
      parts[1] = s
    end
  else
    parts[1] = "Starting"
  end
  for _, p in ipairs(est and est.providers or {}) do
    if p.last_error then parts[#parts + 1] = M.label(p.id) .. ": " .. short(p.last_error, 160) end
  end
  for _, w in ipairs(info.warnings or {}) do parts[#parts + 1] = "Warning: " .. w end
  return table.concat(parts, " | ")
end

function M.active_source(state, est)
  local id = est and est.active_provider
  local src = state and state.source or {}
  if not id and (src.provider or "") == "" then return "None" end
  local s = M.label(id or src.provider)
  if src.device_name and src.device_name ~= "" then s = s .. ": " .. src.device_name end
  if src.app_name and src.app_name ~= "" then s = s .. " (" .. src.app_name .. ")" end
  if est and est.merged_from then s = s .. " + title from " .. M.label(est.merged_from) end
  return s
end

function M.metadata_sources(info)
  local e = info and info.enrichers or {}
  if #e == 0 then return "None" end
  return table.concat(e, ", ")
end

return M
