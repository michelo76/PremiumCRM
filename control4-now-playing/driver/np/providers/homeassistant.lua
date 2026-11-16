--[[
np.providers.homeassistant -- Home Assistant media_player entity via the REST API.
The catch-all for Apple TV, Sonos, Plex, Kodi, Chromecast, Android TV, ...

config: { base_url = "http://homeassistant.local:8123", token = "<long-lived access token>",
          entity_id = "media_player.living_room_apple_tv", name = "Living Room Apple TV" (optional),
          provider_name = "appletv" (optional; source.provider, default "homeassistant"),
          group = "lr-tv" (optional), id = "..." (optional), timeout = 5 }

GET <base>/api/states/<entity_id>  with  Authorization: Bearer <token>
volume_level (0..1) is published as 0..100. media_season/media_episode arrive as strings.
Position: media_position + media_position_updated_at (ISO8601 -> epoch); HA does not push
per-second updates, consumers extrapolate while playing.
config.picture_is_app_icon = true|false|nil(auto) -- see map_entity.
401 -> M.ERR_AUTH and no further requests for >= 60 s (doubling to 600 s).
]]

local util = require("np.util")
local net = require("np.net")
local playback_mod = require("np.playback")

local M = {}

local HA = {}
HA.__index = HA

local CONTENT_KIND = {
  movie = "movie", tvshow = "episode", episode = "episode", season = "episode", music = "music",
  track = "music", video = "video", channel = "live_tv", channels = "live_tv",
}

-- HA media_player states (incl. legacy "standby" and the universal unavailable/unknown,
-- which are NOT errors: the device is simply not reachable/known -> off).
local STATE_MAP = {
  playing = "playing", paused = "paused", buffering = "buffering", idle = "idle", on = "idle",
  standby = "off", off = "off", unavailable = "off", unknown = "off",
}

function M.new(config, deps)
  assert(type(config) == "table" and config.base_url and config.entity_id,
    "homeassistant provider: base_url and entity_id are required")
  local self = setmetatable({}, HA)
  self.kind = "homeassistant"
  self.config = config
  self.deps = deps
  self.base = (config.base_url:gsub("/+$", ""))
  self.id = config.id or ("ha:" .. config.entity_id)
  self.group = config.group
  return self
end

local function absolute(base, u)
  u = util.nonempty(u)
  if not u then return nil end
  if u:find("^https?://") then return u end
  if u:sub(1, 1) ~= "/" then u = "/" .. u end
  return base .. u
end

function M.map_entity(entity, base, config, now)
  local a = type(entity.attributes) == "table" and entity.attributes or {}
  local raw_state = tostring(entity.state or ""):lower()
  local state = STATE_MAP[raw_state] or "idle"
  if raw_state == "on" and util.nonempty(a.media_title) then state = "playing" end
  local ctype = type(a.media_content_type) == "string" and a.media_content_type:lower() or nil
  -- movie/music/video/episode/live_tv map directly; app/playlist/anything else -> unknown
  local kind = ctype and CONTENT_KIND[ctype] or "unknown"
  if kind == "unknown" or kind == "video" then
    local has_series = util.nonempty(a.media_series_title) ~= nil
      or (tonumber(a.media_season) ~= nil and tonumber(a.media_episode) ~= nil)
    if has_series then
      kind = "episode"
    elseif kind == "unknown" and util.nonempty(a.media_artist) and util.nonempty(a.media_album_name) then
      kind = "music"
    end
  end

  -- entity_picture is relative (/api/media_player_proxy/<entity>?token=..&cache=..) and carries
  -- its own token: make it absolute, never add the bearer header when fetching it.
  -- HA's Roku integration (and similar app-only devices) publish the APP ICON as entity_picture
  -- when no title is known: auto-detect (app present, no media_title) unless
  -- config.picture_is_app_icon forces true/false.
  local picture = absolute(base, a.entity_picture)
  local has_app = util.nonempty(a.app_id) or util.nonempty(a.app_name)
  local pic_is_icon = config.picture_is_app_icon
  if pic_is_icon == nil then pic_is_icon = (has_app ~= nil) and util.nonempty(a.media_title) == nil end
  local artwork_url, app_icon_url = picture, nil
  if pic_is_icon then artwork_url, app_icon_url = nil, picture end

  local pos_at = util.iso8601_to_epoch(a.media_position_updated_at) or now
  local vol = tonumber(a.volume_level)
  local raw = {
    source = {
      provider = config.provider_name or "homeassistant",
      device_name = config.name or a.friendly_name or entity.entity_id,
      app_name = util.nonempty(a.app_name) or util.nonempty(a.source),
      app_id = a.app_id,
      app_icon_url = app_icon_url,
    },
    playback = {
      state = state,
      position_s = a.media_position,
      duration_s = a.media_duration,
      position_updated_at = pos_at,
      is_live = (kind == "live_tv") or false,
      volume = vol and (vol * 100) or nil,
    },
    media = {
      kind = kind,
      title = a.media_title,
      series_title = a.media_series_title,
      season = a.media_season,
      episode = a.media_episode,
      artist = a.media_artist,
      album = a.media_album_name,
      album_artist = a.media_album_artist,
      track_number = a.media_track,
      channel_name = a.media_channel,
      artwork_url = artwork_url,
    },
  }
  if kind == "episode" and raw.media.series_title then
    -- HA puts the episode name in media_title when a series title is present
    raw.media.episode_title = a.media_title
  end
  local pb = playback_mod.normalize(raw, now)
  if pb.playback.state == "off" then
    pb.media = { kind = "unknown", genres = {} }
    pb.playback.position_s, pb.playback.duration_s = nil, nil
  end
  return pb
end

M.ERR_AUTH = "Home Assistant rejected the access token (HTTP 401): create a long-lived access " ..
  "token in your HA user profile"

function HA:poll(cb)
  local now = self.deps.now()
  -- HA bans IPs after repeated failed logins: after a 401 stay quiet for >= 60 s (doubling).
  if self.auth_blocked_until and now < self.auth_blocked_until then
    return cb(M.ERR_AUTH .. " (retrying in " .. math.ceil(self.auth_blocked_until - now) .. "s)")
  end
  local url = self.base .. "/api/states/" .. self.config.entity_id
  net.get_json(self.deps, {
    method = "GET", url = url, timeout = self.config.timeout or 5,
    headers = { Authorization = "Bearer " .. tostring(self.config.token or ""),
      ["Content-Type"] = "application/json" },
  }, function(err, data, info)
    if err then
      if info.kind == "auth" then
        self.auth_backoff = math.min(600, (self.auth_backoff or 30) * 2)
        self.auth_blocked_until = self.deps.now() + self.auth_backoff
        return cb(M.ERR_AUTH)
      elseif info.kind == "not_found" then
        return cb("Home Assistant entity not found: " .. self.config.entity_id)
      end
      return cb("Home Assistant: " .. err)
    end
    self.auth_backoff = nil
    cb(nil, M.map_entity(data, self.base, self.config, self.deps.now()))
  end)
end

return M
