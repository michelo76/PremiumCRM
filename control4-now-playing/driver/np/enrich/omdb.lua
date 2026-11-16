--[[
np.enrich.omdb -- OMDb API (IMDb rating/votes, Rotten Tomatoes, Metacritic, Rated, Awards,
BoxOffice; fallback plot/poster/actors/director when TMDB found nothing).
Runs AFTER tmdb so it can use the IMDb id (ctx.details.ids.imdb).

config: { api_key = "...", timeout = 8 }

  i=<imdb id>                    when an IMDb id is known (series id for episodes -> series ratings)
  t=<title>&y=<year>&type=movie  otherwise (movie)
  t=<series>&type=series         episodes (series-level ratings) and, without TMDB, a second
                                 t=<series>&Season=&Episode= call for episode title/plot.
OMDb signals errors in the body: {"Response":"False","Error":"Movie not found!"} = no match,
"Invalid API key!" (401) = bad key, "Request limit reached!" (401) = daily quota.
]]

local util = require("np.util")
local base = require("np.enrich.base")

local M = {}

local API = "https://www.omdbapi.com/"

local O = {}
O.__index = O

function M.new(config, deps)
  local self = setmetatable({}, O)
  base.init(self, "OMDb", config, deps)
  self.attribution = "OMDb"
  return self
end

local function na(v)
  v = util.nonempty(v)
  if not v or v == "N/A" then return nil end
  return v
end

local function imdb_from_ctx(ctx)
  local d = ctx and ctx.details
  return d and d.ids and d.ids.imdb or nil
end

function O:supports(pb, ctx)
  if not util.nonempty(self.config.api_key) then return false end
  local kind = pb.media and pb.media.kind
  if imdb_from_ctx(ctx) then return true end
  if kind == "movie" then return util.clean_title(pb.media.title) ~= nil end
  if kind == "episode" then return (pb.media.series_title or pb.media.title) ~= nil end
  return false
end

function O:_get(params, cb)
  params.apikey = self.config.api_key
  base.get_json(self, { method = "GET", url = util.url(API, params) }, function(err, data, info)
    if type(data) == "table" and data.Response == "False" then
      local msg = tostring(data.Error or "error")
      local low = msg:lower()
      if low:find("not found") or low:find("incorrect imdb") then return cb(nil, nil) end
      if low:find("limit") then
        base.block(self, 3600, "daily request limit reached")
        return cb("OMDb: request limit reached")
      end
      if low:find("api key") then
        base.block(self, 3600, "API key rejected")
        return cb("OMDb: invalid API key")
      end
      return cb("OMDb: " .. msg)
    end
    if err then return cb(err) end
    cb(nil, data)
  end)
end

local function parse_votes(v)
  v = na(v)
  if not v then return nil end
  return tonumber((v:gsub(",", "")))
end

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9,
  Oct = 10, Nov = 11, Dec = 12 }

local function parse_released(v)
  v = na(v)
  if not v then return nil end
  local d, mon, y = v:match("^(%d%d?) (%a%a%a) (%d%d%d%d)$")
  if not d or not MONTHS[mon] then return nil end
  return string.format("%04d-%02d-%02d", tonumber(y), MONTHS[mon], tonumber(d))
end

local function list(v, limit)
  local out = {}
  v = na(v)
  if not v then return out end
  for _, x in ipairs(util.split(v, ",")) do
    x = util.nonempty(x)
    if x and (not limit or #out < limit) then
      x = x:gsub("%s*%b()", "") -- "Christopher Nolan (screenplay)" -> "Christopher Nolan"
      out[#out + 1] = x
    end
  end
  return out
end

function M.map(d)
  local ratings = {}
  local score = tonumber(na(d.imdbRating))
  if score then ratings.imdb = { score = score, votes = parse_votes(d.imdbVotes) } end
  for _, r in ipairs(d.Ratings or {}) do
    if r.Source == "Rotten Tomatoes" then
      ratings.rotten_tomatoes = tonumber((tostring(r.Value or ""):match("^(%d+)%%")))
    elseif r.Source == "Metacritic" then
      ratings.metacritic = tonumber((tostring(r.Value or ""):match("^(%d+)/")))
    end
  end
  if not ratings.metacritic then ratings.metacritic = tonumber(na(d.Metascore)) end
  local facts = {}
  if na(d.Awards) then facts[#facts + 1] = { label = "Awards", value = na(d.Awards) } end
  if na(d.BoxOffice) then facts[#facts + 1] = { label = "Box Office", value = na(d.BoxOffice) } end
  local cast = {}
  for _, n in ipairs(list(d.Actors, 20)) do cast[#cast + 1] = { name = n } end
  local imdb = na(d.imdbID)
  local year = tonumber((tostring(d.Year or ""):match("^(%d%d%d%d)")))
  return {
    content_rating = na(d.Rated),
    ratings = ratings,
    facts = facts,
    overview = na(d.Plot),
    poster_url = (na(d.Poster) or ""):find("^https?://") and na(d.Poster) or nil,
    cast = cast,
    crew = { directors = list(d.Director), writers = list(d.Writer), creators = {} },
    genres = list(d.Genre),
    runtime_min = tonumber((tostring(d.Runtime or ""):match("^(%d+) min"))),
    year = year,
    release_date = parse_released(d.Released),
    ids = { imdb = imdb },
    links = { imdb = imdb and ("https://www.imdb.com/title/" .. imdb .. "/") or nil },
    attribution = { "OMDb" },
  }
end

function O:enrich(pb, cb, ctx)
  local m = pb.media or {}
  local imdb = imdb_from_ctx(ctx)
  local had_tmdb = ctx and ctx.details and ctx.details.matched
  local params
  local by_title = false
  if imdb then
    params = { i = imdb }
  elseif m.kind == "episode" then
    local ep = util.parse_episode(m.title or "")
    local series = util.clean_title(m.series_title or (ep and ep.series) or m.title)
    params = { t = series, type = "series" }
    by_title = true
  else
    params = { t = util.clean_title(m.title), type = "movie", y = m.year or util.extract_year(m.title) }
    by_title = true
  end
  params.plot = had_tmdb and "short" or "full"
  self:_get(params, function(err, d)
    if err then return cb(err) end
    if not d then return cb(nil, nil) end
    local partial = M.map(d)
    if by_title then
      local conf = util.similarity(params.t, d.Title or "")
      if conf < 0.8 then return cb(nil, nil) end
      partial.matched = true
      partial.confidence = util.round(math.min(conf, 0.9), 2)
    else
      partial.matched = true
    end
    -- episode details when TMDB did not provide them
    local season, episode = m.season, m.episode
    if m.kind == "episode" and season and episode and not (ctx and ctx.details and ctx.details.episode) then
      local ep_params = { Season = season, Episode = episode, plot = "full" }
      if d.imdbID then ep_params.i = d.imdbID else ep_params.t = params.t end
      self:_get(ep_params, function(eerr, e)
        if not eerr and e then
          partial.episode = {
            title = na(e.Title), overview = na(e.Plot), air_date = parse_released(e.Released),
            runtime_min = tonumber((tostring(e.Runtime or ""):match("^(%d+) min"))),
            rating = tonumber(na(e.imdbRating)),
          }
          if not partial.poster_url and na(e.Poster) then partial.poster_url = na(e.Poster) end
        end
        cb(nil, partial)
      end)
      return
    end
    cb(nil, partial)
  end)
end

return M
