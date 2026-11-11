--[[
c4.events -- derive Control4 events from consecutive engine states. Pure.

  Events.NAMES                         ordered event names (driver.xml ids 1..n, same order)
  Events.initial() -> snap             snapshot before the first state (nothing playing)
  Events.derive(snap, state, changes) -> { "Event Name", ... }, new_snap

Rules (phase: playing | paused | stopped; buffering keeps the previous phase so a rebuffer
never looks like a stop/start; idle/stopped/off -> stopped):
  Source Changed      source provider/device changed to a non-empty one
  App Changed         app changed (to or from something)
  Media Changed       media identity (media_key of something with a title/artist/channel...)
                      changed to a non-empty identity
  Playback Started    phase -> playing from stopped, or from paused on different media
  Playback Resumed    paused -> playing, same media that already started
  Playback Paused     playing -> paused
  Playback Stopped    playing|paused -> stopped (stopped / idle / off)
  Movie/TV Episode/Music Track/Live TV Started
                      content start: playing and (phase was not playing or the identity
                      changed), once per identity, by media.kind
  Details Available   details attached for the current media_key (once per media_key)
Order: Source, App, Media, transport, kind-specific, Details.
]]

local M = {}

M.NAMES = {
  "Media Changed", "Playback Started", "Playback Paused", "Playback Stopped", "Playback Resumed",
  "Details Available", "Source Changed", "App Changed", "Movie Started", "TV Episode Started",
  "Music Track Started", "Live TV Started",
}

M.DESCRIPTIONS = {
  ["Media Changed"] = "When the media playing in NAME's room changes",
  ["Playback Started"] = "When playback starts",
  ["Playback Paused"] = "When playback is paused",
  ["Playback Stopped"] = "When playback stops (stopped, idle or off after playing or paused)",
  ["Playback Resumed"] = "When paused media resumes playing",
  ["Details Available"] = "When metadata details (ratings, cast, overview...) are attached",
  ["Source Changed"] = "When the active source device changes",
  ["App Changed"] = "When the active app changes",
  ["Movie Started"] = "When a movie starts playing",
  ["TV Episode Started"] = "When a TV episode starts playing",
  ["Music Track Started"] = "When a music track starts playing",
  ["Live TV Started"] = "When live TV starts playing",
}

local KIND_EVENT = {
  movie = "Movie Started", episode = "TV Episode Started", music = "Music Track Started",
  live_tv = "Live TV Started",
}

local function nz(v) return v ~= nil and v ~= "" end

function M.initial()
  return { phase = "stopped", identity = "", started = "", details_for = "", source = "", app = "" }
end

function M.identity(state)
  local m = state.media or {}
  local st = state.playback and state.playback.state
  if st == "off" then return "" end
  if nz(m.title) or nz(m.series_title) or nz(m.artist) or nz(m.album) or nz(m.channel_name)
    or nz(m.channel_number) then
    return state.media_key or ""
  end
  return ""
end

local function phase_of(st, prev_phase)
  if st == "playing" then return "playing" end
  if st == "paused" then return "paused" end
  if st == "buffering" then return prev_phase end
  return "stopped"
end

function M.derive(snap, state, changes)
  snap = snap or M.initial()
  state = state or {}
  local out = {}
  local src, pb = state.source or {}, state.playback or {}
  local new = {
    phase = phase_of(pb.state, snap.phase),
    identity = M.identity(state),
    started = snap.started,
    details_for = snap.details_for,
    source = (src.provider or "") .. "|" .. (src.device_name or ""),
    app = src.app_id or src.app_name or "",
  }
  if (src.provider or "") == "" and (src.device_name or "") == "" then new.source = "" end

  if new.source ~= snap.source and new.source ~= "" then out[#out + 1] = "Source Changed" end
  if new.app ~= snap.app then out[#out + 1] = "App Changed" end
  local media_changed = new.identity ~= snap.identity
  if media_changed and new.identity ~= "" then out[#out + 1] = "Media Changed" end

  local p0, p1 = snap.phase, new.phase
  if p1 == "playing" and p0 ~= "playing" then
    if p0 == "paused" and new.identity == snap.started and not media_changed and new.identity ~= "" then
      out[#out + 1] = "Playback Resumed"
    elseif p0 == "paused" and new.identity == "" and snap.identity == "" and snap.started == "" then
      out[#out + 1] = "Playback Resumed" -- title-less source (e.g. Roku ECP only): same "nothing"
    else
      out[#out + 1] = "Playback Started"
    end
  elseif p1 == "paused" and p0 == "playing" then
    out[#out + 1] = "Playback Paused"
  elseif p1 == "stopped" and (p0 == "playing" or p0 == "paused") then
    out[#out + 1] = "Playback Stopped"
  end
  if p1 == "stopped" then new.started = "" end

  if p1 == "playing" and new.identity ~= "" and new.identity ~= snap.started then
    local ev = KIND_EVENT[(state.media or {}).kind or ""]
    if ev then out[#out + 1] = ev end
    new.started = new.identity
  end

  local key = state.media_key or ""
  if state.details ~= nil and key ~= "" and key ~= snap.details_for then
    out[#out + 1] = "Details Available"
    new.details_for = key
  elseif state.details == nil and key ~= snap.details_for then
    new.details_for = ""
  end
  return out, new
end

return M
