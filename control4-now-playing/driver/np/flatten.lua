--[[
np.flatten -- state document -> ordered list of Control4 variables.

  flatten.flatten(state, now) -> { {name=, value=, type="STRING"|"NUMBER"|"BOOL"}, ... }
      Strings are never nil (""), numbers are 0 when unknown, BOOL values are Lua booleans.
      `now` (optional) extrapolates POSITION_SECONDS / PROGRESS_PERCENT while playing.
  flatten.definitions()     -> { {name=, type=}, ... } in the same order (for C4:AddVariable)
  flatten.display_lines(state) -> line1, line2
  flatten.position(state, now) -> extrapolated position seconds | nil
]]

local util = require("np.util")

local M = {}

local DEFS = {
  { "TITLE", "STRING" }, { "SUBTITLE", "STRING" }, { "MEDIA_KIND", "STRING" }, { "SERIES_TITLE", "STRING" },
  { "SEASON", "NUMBER" }, { "EPISODE", "NUMBER" }, { "EPISODE_TITLE", "STRING" }, { "ARTIST", "STRING" },
  { "ALBUM", "STRING" }, { "CHANNEL_NAME", "STRING" }, { "CHANNEL_NUMBER", "STRING" }, { "APP_NAME", "STRING" },
  { "SOURCE_DEVICE", "STRING" }, { "SOURCE_PROVIDER", "STRING" }, { "PLAY_STATE", "STRING" },
  { "IS_PLAYING", "BOOL" }, { "IS_PAUSED", "BOOL" }, { "IS_LIVE", "BOOL" }, { "POSITION_SECONDS", "NUMBER" },
  { "DURATION_SECONDS", "NUMBER" }, { "PROGRESS_PERCENT", "NUMBER" }, { "VOLUME", "NUMBER" }, { "YEAR", "NUMBER" },
  { "GENRES", "STRING" }, { "CONTENT_RATING", "STRING" }, { "RUNTIME_MINUTES", "NUMBER" }, { "OVERVIEW", "STRING" },
  { "TAGLINE", "STRING" }, { "IMDB_ID", "STRING" }, { "IMDB_RATING", "NUMBER" }, { "IMDB_URL", "STRING" },
  { "ROTTEN_TOMATOES", "NUMBER" }, { "METACRITIC", "NUMBER" }, { "DIRECTOR", "STRING" }, { "CAST", "STRING" },
  { "NETWORK", "STRING" }, { "POSTER_URL", "STRING" }, { "BACKDROP_URL", "STRING" }, { "ARTWORK_URL", "STRING" },
  { "LOGO_URL", "STRING" }, { "TRAILER_URL", "STRING" }, { "DISPLAY_LINE_1", "STRING" },
  { "DISPLAY_LINE_2", "STRING" }, { "MEDIA_KEY", "STRING" }, { "VERSION", "NUMBER" }, { "LAST_CHANGED", "NUMBER" },
}

function M.definitions()
  local out = {}
  for i, d in ipairs(DEFS) do out[i] = { name = d[1], type = d[2] } end
  return out
end

local function s(v)
  if v == nil then return "" end
  return tostring(v)
end

function M.position(state, now)
  local pb = state and state.playback or {}
  local pos = tonumber(pb.position_s)
  if not pos then return nil end
  if now and pb.state == "playing" and pb.position_updated_at then
    pos = pos + math.max(0, now - pb.position_updated_at)
    if pb.duration_s and not pb.is_live and pos > pb.duration_s then pos = pb.duration_s end
  end
  return pos
end

local function title_of(state)
  local m = state.media or {}
  local d = state.details
  local t = m.title and (util.clean_title(m.title) or m.title)
  if not t and d and d.live then t = d.live.program_title end
  return t
end

function M.display_lines(state)
  local m, src, pb, d = state.media or {}, state.source or {}, state.playback or {}, state.details
  local dash = " — "
  local line1, context
  local title = title_of(state)
  local st = pb.state
  if m.kind == "episode" or (m.series_title and (m.season or m.episode)) then
    local series = m.series_title
    local ep_title = m.episode_title
    if not series then
      local p = util.parse_episode(m.title or "")
      series = p and p.series or title
      ep_title = ep_title or (p and p.episode_title)
    elseif not ep_title and m.title and m.title ~= series then
      ep_title = m.title
    end
    local se = ""
    if m.season and m.episode then se = "S" .. m.season .. "·E" .. m.episode
    elseif m.episode then se = "E" .. m.episode end
    local tail = util.join({ se, ep_title or (d and d.episode and d.episode.title) }, " ")
    line1 = util.join({ series, tail }, dash)
  elseif m.kind == "music" then
    line1 = util.join({ title, m.artist or m.album_artist }, dash)
    context = util.join({ m.album, (d and d.music and d.music.album_year) or m.year }, " · ")
  elseif m.kind == "live_tv" then
    line1 = title or m.channel_name
    context = util.join({ m.channel_number, m.channel_name ~= line1 and m.channel_name or nil }, " ")
  elseif m.kind == "movie" then
    local year = m.year or (d and d.year)
    line1 = year and title and (title .. " (" .. year .. ")") or title
  else
    line1 = title
  end
  local where
  if src.app_name and src.device_name then where = src.app_name .. " on " .. src.device_name
  else where = src.app_name or src.device_name end
  if not line1 or line1 == "" then
    if st == "off" then line1 = "Off"
    elseif src.app_name and (st == "playing" or st == "paused" or st == "buffering") then line1 = src.app_name
    elseif st == "idle" or st == "stopped" or st == nil then line1 = "Nothing playing"
    else line1 = src.app_name or "" end
    if line1 == src.app_name then where = src.device_name end
  end
  local line2 = util.join({ context, where }, " · ")
  return line1 or "", line2 or ""
end

function M.flatten(state, now)
  state = state or {}
  local m, src, pb = state.media or {}, state.source or {}, state.playback or {}
  local d = state.details or {}
  local ratings, ids, links, crew = d.ratings or {}, d.ids or {}, d.links or {}, d.crew or {}
  local pos = M.position(state, now)
  local dur = tonumber(pb.duration_s)
  local progress = 0
  if pos and dur and dur > 0 and not pb.is_live then
    progress = math.floor(math.min(100, pos / dur * 100) + 0.5)
  end
  local cast = {}
  for i, c in ipairs(d.cast or {}) do if i <= 5 then cast[#cast + 1] = c.name end end
  local genres = (d.genres and #d.genres > 0) and d.genres or m.genres or {}
  local l1, l2 = M.display_lines(state)
  local imdb_score = ratings.imdb and ratings.imdb.score
  local vals = {
    TITLE = title_of(state), SUBTITLE = m.subtitle, MEDIA_KIND = m.kind or "unknown",
    SERIES_TITLE = m.series_title, SEASON = m.season, EPISODE = m.episode,
    EPISODE_TITLE = m.episode_title or (d.episode and d.episode.title), ARTIST = m.artist, ALBUM = m.album,
    CHANNEL_NAME = m.channel_name, CHANNEL_NUMBER = m.channel_number, APP_NAME = src.app_name,
    SOURCE_DEVICE = src.device_name, SOURCE_PROVIDER = src.provider, PLAY_STATE = pb.state or "idle",
    IS_PLAYING = pb.state == "playing", IS_PAUSED = pb.state == "paused", IS_LIVE = pb.is_live == true,
    POSITION_SECONDS = pos and math.floor(pos + 0.5) or 0, DURATION_SECONDS = dur and math.floor(dur + 0.5) or 0,
    PROGRESS_PERCENT = progress, VOLUME = pb.volume, YEAR = m.year or d.year,
    GENRES = util.join(genres, ", "), CONTENT_RATING = d.content_rating, RUNTIME_MINUTES = d.runtime_min,
    OVERVIEW = util.truncate(d.overview or (d.episode and d.episode.overview) or m.subtitle, 1000),
    TAGLINE = d.tagline, IMDB_ID = ids.imdb, IMDB_RATING = imdb_score, IMDB_URL = links.imdb,
    ROTTEN_TOMATOES = ratings.rotten_tomatoes, METACRITIC = ratings.metacritic,
    DIRECTOR = util.join(crew.directors or {}, ", "), CAST = util.join(cast, ", "),
    NETWORK = (d.networks and d.networks[1]) or m.channel_name,
    POSTER_URL = d.poster_url or m.artwork_url, BACKDROP_URL = d.backdrop_url,
    ARTWORK_URL = m.artwork_url or d.poster_url, LOGO_URL = d.logo_url, TRAILER_URL = d.trailer_url,
    DISPLAY_LINE_1 = l1, DISPLAY_LINE_2 = l2, MEDIA_KEY = state.media_key, VERSION = state.version,
    LAST_CHANGED = state.updated_at and math.floor(state.updated_at) or 0,
  }
  local out = {}
  for _, def in ipairs(DEFS) do
    local name, typ = def[1], def[2]
    local v = vals[name]
    if typ == "NUMBER" then v = tonumber(v) or 0
    elseif typ == "BOOL" then v = v == true
    else v = s(v) end
    out[#out + 1] = { name = name, value = v, type = typ }
  end
  return out
end

return M
