--[[
c4.status -- human-readable text for the read-only status properties. Pure.

  Status.text(state, engine_status, info) -> "Playing — The Bear (Netflix on Living Room Roku)"
  Status.active_source(state, engine_status) -> "Roku: Living Room Roku"
  Status.metadata_sources(info) -> "TMDB, OMDb, Music (iTunes/MusicBrainz)" | "None"
  Status.button_text(state)  -> the Navigator button's text (ICON_CHANGED icon_description):
                                "The Bear — S2·E7 Forks", "Paused: Dreams — Fleetwood Mac",
                                "Netflix" (app only); BUTTON_DEFAULT when nothing plays.
                                At most BUTTON_MAX characters (UTF-8 safe, "…" when cut).
]]

local flatten = require("np.flatten")

local M = {}

M.NOT_CONFIGURED = "Not configured: set a Roku Address, select the Apple TV Driver (or an Apple TV bridge + " ..
  "device), a Home Assistant URL/token/entity, or turn Use Control4 Room Media On"

local LABELS = {
  roku = "Roku", appletv = "Apple TV", homeassistant = "Home Assistant", c4room = "Control4 Room",
  bridge = "Apple TV", appletv_driver = "Apple TV (driver)",
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

M.BUTTON_DEFAULT = "Now Playing"
M.BUTTON_MAX = 60

-- first n UTF-8 characters of s; "…" appended when cut (total stays <= n characters)
function M.ellipsize(s, n)
  local chars = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  if #chars <= n then return table.concat(chars) end
  local cut, prev = table.concat(chars, "", 1, n - 1), nil
  while cut ~= prev do -- no dangling separator before the ellipsis
    prev = cut
    cut = cut:gsub("[%s%-:,]+$", ""):gsub("·$", ""):gsub("—$", "")
  end
  return cut .. "…"
end

function M.button_text(state)
  local st = state and state.playback and state.playback.state
  if st ~= "playing" and st ~= "paused" and st ~= "buffering" then return M.BUTTON_DEFAULT end
  local l1 = flatten.display_lines(state)
  l1 = tostring(l1 or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if l1 == "" or l1 == "Nothing playing" or l1 == "Off" then return M.BUTTON_DEFAULT end
  if st == "paused" then l1 = "Paused: " .. l1 end
  return M.ellipsize(l1, M.BUTTON_MAX)
end

function M.metadata_sources(info)
  local e = info and info.enrichers or {}
  if #e == 0 then return "None" end
  return table.concat(e, ", ")
end

return M
