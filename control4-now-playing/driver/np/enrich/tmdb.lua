--[[
np.enrich.tmdb -- The Movie Database (TMDB) API v3.

config: { api_key = "<v3 key>" | bearer = "<v4 read access token>", language = "en-US",
          country = "US" (content rating country), timeout = 8,
          deny_apps = {...} (extra app names never matched via /search/multi) }
An api_key that looks like a JWT ("eyJ...") is sent as a bearer token automatically.

Strategy
  movie          /search/movie (query, year; retried without year) -> best by fuzzy title +
                 year proximity + popularity -> /movie/{id}?append_to_response=credits,
                 release_dates,external_ids,videos,images
  episode        /search/tv (series title) -> /tv/{id}?append_to_response=credits,
                 content_ratings,external_ids,videos,images (+ /tv/{id}/season/{s}/episode/{e})
  video/unknown/live_tv with a title: SxxEyy in the title -> tv path (threshold 0.85); else
                 /search/multi, accepting only high confidence (sim >= 0.9, vote_count >= 25,
                 year within 1 when known) and never for apps like YouTube/Twitch.
  music          not supported.

enricher:supports(pb) ; enricher:enrich(pb, cb, ctx)  cb(err, partial)
partial._hints = { imdb_episode =, tmdb_type = "movie"|"tv" } (internal; stripped by the pipeline)
]]

local util = require("np.util")
local base = require("np.enrich.base")

local M = {}

local API = "https://api.themoviedb.org/3"
local IMG = "https://image.tmdb.org/t/p/"

M.DENY_APPS = { "youtube", "twitch", "tiktok", "vimeo", "facebook", "instagram", "spotify",
  "pandora", "amazon music", "apple music", "tidal", "soundcloud", "iheart", "siriusxm",
  "dailymotion", "pluto news", "news", "photos", "screensaver", "home" }

local LANGS = { en = "English", es = "Spanish", fr = "French", de = "German", it = "Italian",
  ja = "Japanese", ko = "Korean", zh = "Chinese", cn = "Cantonese", hi = "Hindi", pt = "Portuguese",
  ru = "Russian", sv = "Swedish", da = "Danish", no = "Norwegian", nl = "Dutch", pl = "Polish",
  tr = "Turkish", ar = "Arabic", he = "Hebrew", th = "Thai", fi = "Finnish", is = "Icelandic" }

local T = {}
T.__index = T

function M.new(config, deps)
  local self = setmetatable({}, T)
  base.init(self, "TMDB", config, deps)
  self.attribution = "TMDB"
  return self
end

function T:_configured()
  return util.nonempty(self.config.api_key) or util.nonempty(self.config.bearer)
end

local function app_denied(pb, extra)
  local app = util.norm(pb.source and pb.source.app_name or "")
  if app == "" then return false end
  local lists = { M.DENY_APPS, extra or {} }
  for _, list in ipairs(lists) do
    for _, d in ipairs(list) do
      if app == d or app:find(d, 1, true) == 1 then return true end
    end
  end
  return false
end

function T:_plan(pb)
  local m = pb.media or {}
  local kind = m.kind
  if kind == "music" then return nil end
  local title = m.title
  if kind == "movie" then
    local q = util.clean_title(title)
    if not q then return nil end
    return { mode = "movie", query = q, year = m.year or util.extract_year(title), threshold = 0.72 }
  end
  if kind == "episode" then
    local ep = util.parse_episode(title or "") or util.parse_episode(m.episode_title or "")
    local q = (m.series_title and util.clean_title(m.series_title))
      or (ep and ep.series and util.clean_title(ep.series)) or util.clean_title(title)
    if not q then return nil end
    return { mode = "tv", query = q, season = m.season or (ep and ep.season),
      episode = m.episode or (ep and ep.episode), threshold = 0.72 }
  end
  -- live_tv / video / unknown
  if kind ~= "live_tv" and app_denied(pb, self.config.deny_apps) then return nil end
  local ep = util.parse_episode(title or "")
  if ep and ep.series then
    return { mode = "tv", query = util.clean_title(ep.series), season = ep.season, episode = ep.episode,
      threshold = 0.85 }
  end
  if m.series_title then
    return { mode = "tv", query = util.clean_title(m.series_title), season = m.season, episode = m.episode,
      threshold = 0.85 }
  end
  local q = util.clean_title(title)
  if not q then return nil end
  return { mode = "multi", query = q, year = m.year or util.extract_year(title), threshold = 0.9 }
end

function T:supports(pb)
  return self:_configured() ~= nil and self:_plan(pb) ~= nil
end

function T:_get(path, params, cb)
  params = params or {}
  params.language = self.config.language or "en-US"
  local headers = { Accept = "application/json" }
  local key, bearer = util.nonempty(self.config.api_key), util.nonempty(self.config.bearer)
  if key and key:find("^eyJ") and not bearer then bearer, key = key, nil end
  if bearer then headers.Authorization = "Bearer " .. bearer else params.api_key = key end
  base.get_json(self, { method = "GET", url = util.url(API .. path, params), headers = headers }, cb)
end

local function cand_year(c)
  local d = c.release_date or c.first_air_date
  return type(d) == "string" and tonumber(d:match("^(%d%d%d%d)")) or nil
end

function M.score(plan, c, index)
  local mt = c.media_type
  if plan.mode == "multi" and mt ~= "movie" and mt ~= "tv" then return nil end
  local s = util.similarity(plan.query, c.title or c.name or "")
  local s2 = util.similarity(plan.query, c.original_title or c.original_name or "")
  if s2 > s then s = s2 end
  local cy = cand_year(c)
  if plan.year and cy and plan.mode ~= "tv" then
    local d = math.abs(plan.year - cy)
    if d == 0 then s = s + 0.08 elseif d == 1 then s = s + 0.03 else s = s - 0.1 * math.min(d, 3) end
  end
  local pop = tonumber(c.popularity) or 0
  s = s + 0.04 * math.min(1, math.log10(1 + pop) / 3)
  s = s - 0.005 * ((index or 1) - 1)
  if s > 1 then s = 1 end
  if s < 0 then s = 0 end
  if plan.mode == "multi" then
    if (tonumber(c.vote_count) or 0) < 25 then return nil end
    if plan.year and cy and math.abs(plan.year - cy) > 1 then return nil end
  end
  return s
end

function M.pick(plan, results)
  local best, best_s
  for i, c in ipairs(results or {}) do
    local s = M.score(plan, c, i)
    if s and (not best_s or s > best_s) then best, best_s = c, s end
  end
  if best and best_s >= plan.threshold then return best, best_s end
  return nil, best_s
end

local function img(size, path)
  if type(path) ~= "string" or path == "" then return nil end
  if path:find("%.svg$") then size = "original" end
  return IMG .. size .. path
end

local function names(list, limit)
  local out = {}
  for _, x in ipairs(list or {}) do
    if x.name and (not limit or #out < limit) then out[#out + 1] = x.name end
  end
  return out
end

local function crew_jobs(crew, pred)
  local out, seen = {}, {}
  for _, c in ipairs(crew or {}) do
    if c.name and pred(c) and not seen[c.name] then
      seen[c.name] = true
      out[#out + 1] = c.name
    end
  end
  return out
end

local WRITER_JOBS = { Screenplay = true, Writer = true, Story = true, Novel = true, Teleplay = true,
  ["Original Story"] = true, Author = true }

local function map_cast(cast)
  local list = {}
  for _, c in ipairs(cast or {}) do list[#list + 1] = c end
  table.sort(list, function(a, b) return (tonumber(a.order) or 999) < (tonumber(b.order) or 999) end)
  local out = {}
  for _, c in ipairs(list) do
    if #out >= 20 then break end
    local character = c.character
    if not character and type(c.roles) == "table" and c.roles[1] then character = c.roles[1].character end
    out[#out + 1] = { name = c.name, character = util.nonempty(character), photo_url = img("w185", c.profile_path) }
  end
  return out
end

local function pick_logo(images)
  local logos = images and images.logos
  if type(logos) ~= "table" or #logos == 0 then return nil end
  local best
  for _, l in ipairs(logos) do
    local en = l.iso_639_1 == "en" and 1 or 0
    local score = en * 100 + (tonumber(l.vote_average) or 0)
    if not best or score > best.score then best = { score = score, l = l } end
  end
  return best and img("w500", best.l.file_path)
end

local function pick_trailer(videos)
  local list = videos and videos.results
  local best
  for _, v in ipairs(list or {}) do
    if v.site == "YouTube" and v.key then
      local s = (v.type == "Trailer" and 10 or (v.type == "Teaser" and 5 or 0)) + (v.official and 2 or 0)
      if s > 0 and (not best or s > best.s) then best = { s = s, v = v } end
    end
  end
  return best and ("https://www.youtube.com/watch?v=" .. best.v.key) or nil
end

local function movie_rating(rd, country)
  for _, r in ipairs(rd and rd.results or {}) do
    if r.iso_3166_1 == country then
      local any
      for _, x in ipairs(r.release_dates or {}) do
        local cert = util.nonempty(x.certification)
        if cert then
          if x.type == 3 then return cert end
          any = any or cert
        end
      end
      return any
    end
  end
  return nil
end

local function tv_rating(cr, country)
  for _, r in ipairs(cr and cr.results or {}) do
    if r.iso_3166_1 == country then return util.nonempty(r.rating) end
  end
  return nil
end

local function year_of(d)
  return type(d) == "string" and tonumber(d:match("^(%d%d%d%d)")) or nil
end

local function lang_name(code)
  if not code then return nil end
  return LANGS[code] or code:upper()
end

local function imdb_link(id)
  return id and ("https://www.imdb.com/title/" .. id .. "/") or nil
end

local function rating(v, count)
  v = tonumber(v)
  if not v or v <= 0 or (count and tonumber(count) == 0) then return nil end
  return util.round(v, 1)
end

function M.map_movie(d, conf, country)
  local credits = d.credits or {}
  local imdb = util.nonempty(d.imdb_id) or (d.external_ids and util.nonempty(d.external_ids.imdb_id))
  local facts = {}
  local function fact(label, value) if value then facts[#facts + 1] = { label = label, value = value } end end
  fact("Budget", util.format_money(d.budget))
  fact("Revenue", util.format_money(d.revenue))
  fact("Original Language", lang_name(d.original_language))
  if d.original_title and d.original_title ~= d.title then fact("Original Title", d.original_title) end
  fact("Status", util.nonempty(d.status))
  return {
    matched = true, confidence = util.round(conf, 2),
    tagline = util.nonempty(d.tagline), overview = util.nonempty(d.overview),
    release_date = util.nonempty(d.release_date), year = year_of(d.release_date),
    runtime_min = (tonumber(d.runtime) or 0) > 0 and tonumber(d.runtime) or nil,
    content_rating = movie_rating(d.release_dates, country),
    genres = names(d.genres), status = util.nonempty(d.status),
    poster_url = img("w780", d.poster_path), backdrop_url = img("w1280", d.backdrop_path),
    logo_url = pick_logo(d.images),
    ratings = { tmdb = rating(d.vote_average, d.vote_count) },
    cast = map_cast(credits.cast),
    crew = {
      directors = crew_jobs(credits.crew, function(c) return c.job == "Director" end),
      writers = crew_jobs(credits.crew, function(c) return WRITER_JOBS[c.job] end),
      creators = {},
    },
    networks = {}, studios = names(d.production_companies, 5),
    trailer_url = pick_trailer(d.videos),
    facts = facts,
    ids = { imdb = imdb, tmdb = d.id },
    links = { imdb = imdb_link(imdb) },
    attribution = { "TMDB" },
    _hints = { tmdb_type = "movie" },
  }
end

function M.map_tv(d, ep, conf, country)
  local credits = d.credits or {}
  local imdb = d.external_ids and util.nonempty(d.external_ids.imdb_id)
  local runtime = type(d.episode_run_time) == "table" and tonumber(d.episode_run_time[1]) or nil
  local facts = {}
  local function fact(label, value) if value then facts[#facts + 1] = { label = label, value = value } end end
  fact("Original Language", lang_name(d.original_language))
  if d.original_name and d.original_name ~= d.name then fact("Original Title", d.original_name) end
  fact("Status", util.nonempty(d.status))
  fact("First Aired", util.nonempty(d.first_air_date))
  if d.status == "Ended" then fact("Last Aired", util.nonempty(d.last_air_date)) end
  local nx = d.next_episode_to_air
  local out = {
    matched = true, confidence = util.round(conf, 2),
    tagline = util.nonempty(d.tagline), overview = util.nonempty(d.overview),
    release_date = util.nonempty(d.first_air_date), year = year_of(d.first_air_date),
    runtime_min = runtime,
    content_rating = tv_rating(d.content_ratings, country),
    genres = names(d.genres), status = util.nonempty(d.status),
    poster_url = img("w780", d.poster_path), backdrop_url = img("w1280", d.backdrop_path),
    logo_url = pick_logo(d.images),
    ratings = { tmdb = rating(d.vote_average, d.vote_count) },
    cast = map_cast(credits.cast),
    crew = {
      directors = {}, writers = {},
      creators = names(d.created_by),
    },
    networks = names(d.networks), studios = names(d.production_companies, 5),
    trailer_url = pick_trailer(d.videos),
    series = {
      seasons = tonumber(d.number_of_seasons), episodes = tonumber(d.number_of_episodes),
      first_air_date = util.nonempty(d.first_air_date),
      next_episode = (type(nx) == "table" and nx.season_number) and {
        season = nx.season_number, episode = nx.episode_number,
        air_date = util.nonempty(nx.air_date), title = util.nonempty(nx.name),
      } or nil,
    },
    facts = facts,
    ids = { imdb = imdb, tmdb = d.id },
    links = { imdb = imdb_link(imdb) },
    attribution = { "TMDB" },
    _hints = { tmdb_type = "tv" },
  }
  if type(ep) == "table" then
    local eimdb = ep.external_ids and util.nonempty(ep.external_ids.imdb_id)
    out.episode = {
      title = util.nonempty(ep.name), overview = util.nonempty(ep.overview),
      air_date = util.nonempty(ep.air_date), still_url = img("w780", ep.still_path),
      runtime_min = tonumber(ep.runtime) or runtime, rating = rating(ep.vote_average, ep.vote_count),
    }
    if out.episode.runtime_min then out.runtime_min = out.episode.runtime_min end
    local ecrew = ep.crew or (ep.credits and ep.credits.crew)
    out.crew.directors = crew_jobs(ecrew, function(c) return c.job == "Director" end)
    out.crew.writers = crew_jobs(ecrew, function(c) return WRITER_JOBS[c.job] end)
    out._hints.imdb_episode = eimdb
    out._hints.season = ep.season_number
    out._hints.episode = ep.episode_number
  end
  return out
end

function T:enrich(pb, cb)
  local plan = self:_plan(pb)
  if not plan then return cb(nil, nil) end
  local country = self.config.country or "US"
  local path = ({ movie = "/search/movie", tv = "/search/tv", multi = "/search/multi" })[plan.mode]
  local function search(with_year, next_cb)
    local params = { query = plan.query, include_adult = "false", page = 1 }
    if with_year and plan.year and plan.mode == "movie" then params.year = plan.year end
    self:_get(path, params, next_cb)
  end
  local function after_search(err, data)
    if err then return cb(err) end
    local results = type(data.results) == "table" and data.results or {}
    local best, conf = M.pick(plan, results)
    if not best then
      self.deps.log("debug", string.format("TMDB: no confident match for '%s' (best %.2f)", plan.query, conf or 0))
      return cb(nil, nil)
    end
    local is_tv = plan.mode == "tv" or best.media_type == "tv"
    if not is_tv then
      self:_get("/movie/" .. best.id, {
        append_to_response = "credits,release_dates,external_ids,videos,images",
        include_image_language = "en,null",
      }, function(derr, d)
        if derr then return cb(derr) end
        cb(nil, M.map_movie(d, conf, country))
      end)
      return
    end
    self:_get("/tv/" .. best.id, {
      append_to_response = "credits,content_ratings,external_ids,videos,images",
      include_image_language = "en,null",
    }, function(derr, d)
      if derr then return cb(derr) end
      if plan.season and plan.episode then
        self:_get("/tv/" .. best.id .. "/season/" .. plan.season .. "/episode/" .. plan.episode,
          { append_to_response = "external_ids,credits" }, function(eerr, ep)
            if eerr then
              self.deps.log("debug", "TMDB episode lookup failed: " .. tostring(eerr))
              ep = nil
            end
            cb(nil, M.map_tv(d, ep, conf, country))
          end)
      else
        cb(nil, M.map_tv(d, nil, conf, country))
      end
    end)
  end
  search(true, function(err, data)
    if not err and plan.year and plan.mode == "movie" and type(data.results) == "table" and #data.results == 0 then
      return search(false, after_search)
    end
    after_search(err, data)
  end)
end

return M
