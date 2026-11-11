--[[
np.enrich.gracenote -- Gracenote / TMS OnConnect Data Delivery (http://data.tmsapi.com/v1.1).

*** UNTESTED AGAINST THE LIVE API ***  OnConnect keys are licence-gated; this module is written
from the documented response shapes and exercised only with recorded-style fixtures. Expect
to adjust field names after the first real run (log level "debug" prints every URL).

config: { api_key = "...", lineup_id = "USA-OTA22201-DEFAULT" | "USA-DISH501-X" ...,
          channel_map = { ["7.1"] = "10021" } (optional: channel number/name -> stationId),
          image_base = "https://demo.tmsimg.com/" (TMS image host; licence dependent),
          search_fallback = true (use /programs/search for movie/episode when nothing matched),
          timeout = 8 }

live_tv:
  GET /lineups/{lineupId}/channels?api_key=        (cached 24 h) -> stationId by channel number/call sign
  GET /stations/{stationId}/airings?startDateTime=&endDateTime=&api_key=
      -> current airing + next  => details.live {program_title, program_start, program_end,
         next{title,start}}, overview, genres, ids.tms (tmsId), episode block for episodic programs
movie/episode fallback (only when no earlier enricher matched):
  GET /programs/search?q=&entityType=movie|episode&api_key=
]]

local util = require("np.util")
local base = require("np.enrich.base")

local M = {}

local API = "http://data.tmsapi.com/v1.1"

local G = {}
G.__index = G

function M.new(config, deps)
  local self = setmetatable({}, G)
  base.init(self, "Gracenote", config, deps)
  self.attribution = "Gracenote"
  self.channels = nil
  self.channels_at = nil
  return self
end

function G:supports(pb, ctx)
  if not util.nonempty(self.config.api_key) then return false end
  local m = pb.media or {}
  if m.kind == "live_tv" then
    return (m.channel_number or m.channel_name) ~= nil and
      (self.config.lineup_id ~= nil or self.config.channel_map ~= nil)
  end
  if self.config.search_fallback == false then return false end
  if ctx and ctx.details and ctx.details.matched then return false end
  if m.kind == "movie" or m.kind == "episode" then
    return util.clean_title(m.series_title or m.title) ~= nil
  end
  return false
end

function G:_get(path, params, cb)
  params = params or {}
  params.api_key = self.config.api_key
  local url = util.url(API .. path, params)
  self.deps.log("debug", "Gracenote GET " .. url:gsub("api_key=[^&]+", "api_key=***"))
  base.get_json(self, { method = "GET", url = url }, cb)
end

local function norm_channel(s)
  if not s then return nil end
  s = tostring(s):gsub("%-", "."):gsub("%s+", "")
  return s
end

local function norm_call(s)
  if not s then return nil end
  s = tostring(s):upper():gsub("%-?DT%d*$", ""):gsub("%-?HD$", ""):gsub("%-?TV$", ""):gsub("[^%w]", "")
  return s
end

function M.find_station(channels, number, name)
  local num = norm_channel(number)
  local call = norm_call(name)
  local by_call
  for _, c in ipairs(channels or {}) do
    if num and norm_channel(c.channel) == num then return c.stationId end
    if call and call ~= "" and (norm_call(c.callSign) == call or norm_call(c.affiliateCallSign) == call) then
      by_call = by_call or c.stationId
    end
  end
  if by_call then return by_call end
  if num and not num:find("%.") then
    for _, c in ipairs(channels or {}) do
      if norm_channel(c.channel) == num .. ".1" then return c.stationId end
    end
  end
  return nil
end

function G:_station(m, cb)
  local map = self.config.channel_map
  if map then
    local sid = (m.channel_number and map[m.channel_number]) or (m.channel_name and map[m.channel_name])
    if sid then return cb(nil, tostring(sid)) end
  end
  if not self.config.lineup_id then return cb(nil, nil) end
  local now = self.deps.now()
  if self.channels and self.channels_at and now - self.channels_at < 86400 then
    return cb(nil, M.find_station(self.channels, m.channel_number, m.channel_name))
  end
  self:_get("/lineups/" .. util.urlencode(self.config.lineup_id) .. "/channels", { enhancedCallSign = "true" },
    function(err, data)
      if err then return cb(err) end
      if not util.is_list(data) then return cb("Gracenote: unexpected channels response") end
      self.channels, self.channels_at = data, now
      cb(nil, M.find_station(data, m.channel_number, m.channel_name))
    end)
end

local function image(self, p)
  local uri = p and p.preferredImage and p.preferredImage.uri
  if type(uri) ~= "string" or uri == "" then return nil end
  if uri:find("^https?://") then return uri end
  return (self.config.image_base or "https://demo.tmsimg.com/") .. uri:gsub("^/", "")
end

local function rating_of(p)
  for _, r in ipairs(p and p.ratings or {}) do
    if r.code and (r.body == "USA Parental Rating" or r.body == "Motion Picture Association of America") then
      return r.code
    end
  end
  return nil
end

function M.map_program(self, p)
  local cast = {}
  for _, n in ipairs(p.topCast or {}) do
    if #cast < 20 then cast[#cast + 1] = { name = n } end
  end
  local genres = {}
  for _, g in ipairs(p.genres or {}) do genres[#genres + 1] = g end
  local out = {
    overview = util.nonempty(p.longDescription) or util.nonempty(p.shortDescription),
    genres = genres,
    year = tonumber(p.releaseYear),
    release_date = util.nonempty(p.releaseDate) or util.nonempty(p.origAirDate),
    content_rating = rating_of(p),
    poster_url = image(self, p),
    cast = cast,
    crew = { directors = p.directors or {}, writers = {}, creators = {} },
    ids = { tms = p.tmsId },
    attribution = { "Gracenote" },
    _hints = { tms_root_id = p.rootId, tms_series_id = p.seriesId },
  }
  if p.episodeTitle or p.episodeNum then
    out.episode = {
      title = util.nonempty(p.episodeTitle), overview = util.nonempty(p.longDescription) or util.nonempty(p.shortDescription),
      air_date = util.nonempty(p.origAirDate),
    }
  end
  return out
end

function M.current_airing(airings, now)
  local cur, nxt
  for i, a in ipairs(airings or {}) do
    local s = util.iso8601_to_epoch(a.startTime)
    local e = util.iso8601_to_epoch(a.endTime) or (s and tonumber(a.duration) and s + tonumber(a.duration) * 60)
    if s and e and s <= now and now < e then
      cur = a
      nxt = airings[i + 1]
      break
    end
  end
  return cur, nxt
end

function G:_live(pb, cb)
  local m = pb.media
  self:_station(m, function(err, sid)
    if err then return cb(err) end
    if not sid then
      self.deps.log("debug", "Gracenote: no station for channel " .. tostring(m.channel_number or m.channel_name))
      return cb(nil, nil)
    end
    local now = self.deps.now()
    self:_get("/stations/" .. sid .. "/airings", {
      startDateTime = util.epoch_to_iso(now - 4 * 3600, false),
      endDateTime = util.epoch_to_iso(now + 4 * 3600, false),
      imageSize = "Md",
    }, function(aerr, airings)
      if aerr then return cb(aerr) end
      if not util.is_list(airings) then return cb("Gracenote: unexpected airings response") end
      local cur, nxt = M.current_airing(airings, now)
      if not cur or type(cur.program) ~= "table" then return cb(nil, nil) end
      local partial = M.map_program(self, cur.program)
      partial.matched = true
      partial.confidence = 0.95
      partial.live = {
        program_title = util.nonempty(cur.program.title),
        program_start = util.iso8601_to_epoch(cur.startTime),
        program_end = util.iso8601_to_epoch(cur.endTime),
        next = (nxt and type(nxt.program) == "table") and {
          title = util.nonempty(nxt.program.title), start = util.iso8601_to_epoch(nxt.startTime),
        } or nil,
      }
      cb(nil, partial)
    end)
  end)
end

function G:_search(pb, cb)
  local m = pb.media
  local q = util.clean_title(m.kind == "episode" and (m.series_title or m.title) or m.title)
  local entity = m.kind == "movie" and "movie" or "show"
  self:_get("/programs/search", { q = q, queryFields = "title", entityType = entity, limit = 5 }, function(err, data)
    if err then return cb(err) end
    local hits = type(data) == "table" and data.hits or nil
    local best, best_s
    for _, h in ipairs(hits or {}) do
      local p = h.program or h
      local s = util.similarity(q, p.title or "")
      if m.year and tonumber(p.releaseYear) and math.abs(m.year - tonumber(p.releaseYear)) > 1 then s = s - 0.2 end
      if not best_s or s > best_s then best, best_s = p, s end
    end
    if not best or best_s < 0.85 then return cb(nil, nil) end
    local partial = M.map_program(self, best)
    partial.matched = true
    partial.confidence = util.round(best_s, 2)
    cb(nil, partial)
  end)
end

function G:enrich(pb, cb)
  if pb.media.kind == "live_tv" then return self:_live(pb, cb) end
  return self:_search(pb, cb)
end

return M
