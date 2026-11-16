--[[
np.playback -- the normalized "raw playback" structure every provider returns, plus a
sanitizer used for untrusted input (JSON bridge, static pushes from the glue).

  playback = {
    source   = { provider, device_name, app_name, app_id, app_icon_url },
    playback = { state, position_s, duration_s, position_updated_at, is_live, volume },
    media    = { kind, title, subtitle, series_title, season, episode, episode_title, artist,
                 album, album_artist, track_number, channel_name, channel_number, year,
                 genres = {..}, artwork_url },
  }
  state  in playing|paused|buffering|stopped|idle|off
  kind   in movie|episode|music|live_tv|video|unknown
  volume is 0..100 (number) or nil

  playback.normalize(raw, now, defaults) -> sanitized deep copy (never fails; junk dropped)
  playback.empty(state, now)             -> a minimal valid playback with the given state
  playback.is_active(pb)                 -> true for playing|paused|buffering
  playback.STATES, playback.KINDS, playback.SOURCE_FIELDS, playback.PLAYBACK_FIELDS, playback.MEDIA_FIELDS
]]

local util = require("np.util")

local M = {}

M.STATES = { playing = true, paused = true, buffering = true, stopped = true, idle = true, off = true }
M.KINDS = { movie = true, episode = true, music = true, live_tv = true, video = true, unknown = true }

M.SOURCE_FIELDS = { "provider", "device_name", "app_name", "app_id", "app_icon_url" }
M.PLAYBACK_FIELDS = { "state", "position_s", "duration_s", "position_updated_at", "is_live", "volume" }
M.MEDIA_FIELDS = { "kind", "title", "subtitle", "series_title", "season", "episode", "episode_title",
  "artist", "album", "album_artist", "track_number", "channel_name", "channel_number", "year",
  "genres", "artwork_url" }

local STATE_ALIASES = {
  play = "playing", playing = "playing", ["on"] = "idle", pause = "paused", paused = "paused",
  buffer = "buffering", buffering = "buffering", loading = "buffering", seeking = "buffering",
  stop = "stopped", stopped = "stopped", idle = "idle", none = "idle", standby = "off",
  off = "off", unavailable = "off", unknown = "idle",
}

local KIND_ALIASES = {
  movie = "movie", film = "movie", episode = "episode", tvshow = "episode", tv_show = "episode",
  show = "episode", series = "episode", music = "music", song = "music", track = "music",
  audio = "music", podcast = "music", live_tv = "live_tv", channel = "live_tv", livetv = "live_tv",
  live = "live_tv", video = "video", unknown = "unknown",
}

local function str(v, maxlen)
  local s = util.nonempty(v)
  if s and #s > (maxlen or 500) then s = util.truncate(s, maxlen or 500) end
  return s
end

local function num(v, min, max)
  local n = tonumber(v)
  if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
  if min and n < min then return nil end
  if max and n > max then return nil end
  return n
end

local function int(v, min, max)
  local n = num(v, min, max)
  if not n then return nil end
  return math.floor(n + 0.5)
end

local function bool(v)
  if v == true or v == "true" or v == 1 or v == "1" or v == "yes" then return true end
  if v == false or v == "false" or v == 0 or v == "0" or v == "no" then return false end
  return nil
end

local function url(v)
  local s = str(v, 2048)
  if s and (s:find("^https?://")) then return s end
  return nil
end

function M.map_state(v)
  if type(v) ~= "string" then return nil end
  return STATE_ALIASES[v:lower()]
end

function M.map_kind(v)
  if type(v) ~= "string" then return nil end
  return KIND_ALIASES[v:lower()]
end

function M.empty(state, now)
  return {
    source = {},
    playback = { state = state or "idle", position_updated_at = now, is_live = false },
    media = { kind = "unknown", genres = {} },
  }
end

function M.is_active(pb)
  local s = pb and pb.playback and pb.playback.state
  return s == "playing" or s == "paused" or s == "buffering"
end

local function genres(v)
  local out = {}
  if type(v) == "string" then v = util.split(v, ",") end
  if type(v) == "table" then
    for _, g in ipairs(v) do
      local s = str(g, 64)
      if s and #out < 12 then out[#out + 1] = s end
    end
  end
  return out
end

function M.normalize(raw, now, defaults)
  raw = type(raw) == "table" and raw or {}
  defaults = defaults or {}
  local rs = type(raw.source) == "table" and raw.source or {}
  local rp = type(raw.playback) == "table" and raw.playback or {}
  local rm = type(raw.media) == "table" and raw.media or {}

  local source = {
    provider = str(rs.provider, 64) or defaults.provider,
    device_name = str(rs.device_name, 128) or defaults.device_name,
    app_name = str(rs.app_name, 128),
    app_id = str(rs.app_id, 128),
    app_icon_url = url(rs.app_icon_url),
  }

  local volume = num(rp.volume, 0, 100)
  local playback = {
    state = M.map_state(rp.state) or "idle",
    position_s = num(rp.position_s, 0),
    duration_s = num(rp.duration_s, 0),
    position_updated_at = num(rp.position_updated_at, 0) or now,
    is_live = bool(rp.is_live) or false,
    volume = volume,
  }
  if playback.duration_s == 0 then playback.duration_s = nil end

  local media = {
    kind = M.map_kind(rm.kind) or "unknown",
    title = str(rm.title),
    subtitle = str(rm.subtitle),
    series_title = str(rm.series_title),
    season = int(rm.season, 0, 10000),
    episode = int(rm.episode, 0, 100000),
    episode_title = str(rm.episode_title),
    artist = str(rm.artist),
    album = str(rm.album),
    album_artist = str(rm.album_artist),
    track_number = int(rm.track_number, 0, 10000),
    channel_name = str(rm.channel_name, 128),
    channel_number = str(rm.channel_number, 32),
    year = int(rm.year, 1870, 2100),
    genres = genres(rm.genres),
    artwork_url = url(rm.artwork_url),
  }
  return { source = source, playback = playback, media = media }
end

return M
