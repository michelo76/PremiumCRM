--[[
np.enrich.music -- iTunes Search API (keyless) + optional MusicBrainz (keyless).

config: { enabled = true, country = "US", musicbrainz = true,
          user_agent = "NowPlayingInfo-Control4/1.0 (Control4 DriverWorks driver)",
          min_confidence = 0.7, timeout = 8 }

iTunes   GET https://itunes.apple.com/search?term=<artist title>&entity=song&media=music&limit=10
         -> best match (track/artist/album similarity) -> artwork (100x100bb -> 1000x1000bb),
            album, year, genre, duration;
         GET https://itunes.apple.com/lookup?id=<collectionId>&entity=song -> album track list.
MusicBrainz (descriptive User-Agent required, <= 1 request/second, enforced module-wide):
         GET https://musicbrainz.org/ws/2/recording?query=...&fmt=json&limit=5 -> recording id
         GET https://musicbrainz.org/ws/2/release/<id>?inc=labels&fmt=json -> label
details.music = {album_year, label, album_tracks[{n,title,duration_s}], track_genre,
                 artist_image_url (nil), artist_bio (nil)}
]]

local util = require("np.util")
local base = require("np.enrich.base")

local M = {}

local ITUNES = "https://itunes.apple.com"
local MB = "https://musicbrainz.org/ws/2"
M.DEFAULT_UA = "NowPlayingInfo-Control4/1.0 (Control4 DriverWorks driver)"

-- module-wide MusicBrainz throttle (one Lua state per driver instance)
local mb_next_slot = 0
function M._reset_throttle() mb_next_slot = 0 end

local Music = {}
Music.__index = Music

function M.new(config, deps)
  local self = setmetatable({}, Music)
  base.init(self, "iTunes", config, deps)
  self.attribution = "iTunes"
  self.mb = setmetatable({}, { __index = self })
  base.init(self.mb, "MusicBrainz", config, deps)
  return self
end

function Music:supports(pb)
  if self.config.enabled == false then return false end
  local m = pb.media or {}
  return m.kind == "music" and util.nonempty(m.title) ~= nil
end

local function strip_feat(s)
  if not s then return s end
  s = s:gsub("%s*[%(%[][Ff]eat%.?[^%)%]]*[%)%]]", ""):gsub("%s*[%(%[][Ww]ith [^%)%]]*[%)%]]", "")
  return util.clean_title(s) or s
end

function M.score(m, r)
  local t = util.similarity(strip_feat(m.title), strip_feat(r.trackName or ""))
  if not m.artist then
    local s = t
    if m.album then s = 0.75 * t + 0.25 * util.similarity(m.album, r.collectionName or "") end
    return s
  end
  local a = util.similarity(m.artist, r.artistName or "")
  -- "Artist A & Artist B" vs "Artist A": partial credit for containment
  local na, nr = util.norm(m.artist), util.norm(r.artistName or "")
  if a < 0.8 and na ~= "" and nr ~= "" and (na:find(nr, 1, true) or nr:find(na, 1, true)) then a = 0.85 end
  if m.album then
    local al = util.similarity(strip_feat(m.album), strip_feat(r.collectionName or ""))
    return 0.5 * t + 0.35 * a + 0.15 * al
  end
  return 0.6 * t + 0.4 * a
end

local function big_art(u)
  if type(u) ~= "string" then return nil end
  return (u:gsub("/%d+x%d+bb%.", "/1000x1000bb."))
end

function Music:_itunes(pb, cb)
  local m = pb.media
  local term = util.join({ m.artist, strip_feat(m.title) }, " ")
  base.get_json(self, { method = "GET", url = util.url(ITUNES .. "/search", {
    term = term, entity = "song", media = "music", limit = 10, country = self.config.country or "US",
  }) }, function(err, data)
    if err then return cb(err) end
    local best, best_s
    for _, r in ipairs(type(data.results) == "table" and data.results or {}) do
      if r.kind == "song" or r.wrapperType == "track" then
        local s = M.score(m, r)
        if not best_s or s > best_s then best, best_s = r, s end
      end
    end
    if not best or best_s < (self.config.min_confidence or 0.7) then return cb(nil, nil) end
    local year = type(best.releaseDate) == "string" and tonumber(best.releaseDate:match("^(%d%d%d%d)")) or nil
    local partial = {
      matched = true, confidence = util.round(best_s, 2),
      poster_url = big_art(best.artworkUrl100 or best.artworkUrl60),
      year = year,
      release_date = type(best.releaseDate) == "string" and best.releaseDate:match("^(%d%d%d%d%-%d%d%-%d%d)") or nil,
      genres = best.primaryGenreName and { best.primaryGenreName } or {},
      runtime_min = nil,
      music = { album_year = year, track_genre = best.primaryGenreName, album_tracks = {} },
      attribution = { "iTunes" },
      _hints = { album = best.collectionName, artist = best.artistName, track = best.trackName,
        duration_s = tonumber(best.trackTimeMillis) and tonumber(best.trackTimeMillis) / 1000 or nil },
    }
    if not best.collectionId then return cb(nil, partial) end
    base.get_json(self, { method = "GET", url = util.url(ITUNES .. "/lookup", {
      id = best.collectionId, entity = "song", country = self.config.country or "US",
    }) }, function(lerr, ldata)
      if lerr then
        self.deps.log("debug", "iTunes album lookup failed: " .. tostring(lerr))
        return cb(nil, partial)
      end
      local tracks = {}
      for _, r in ipairs(type(ldata.results) == "table" and ldata.results or {}) do
        if r.wrapperType == "track" and r.trackName then
          tracks[#tracks + 1] = { n = tonumber(r.trackNumber), disc = tonumber(r.discNumber) or 1,
            title = r.trackName, duration_s = tonumber(r.trackTimeMillis) and math.floor(tonumber(r.trackTimeMillis) / 1000 + 0.5) or nil }
        end
      end
      table.sort(tracks, function(a, b)
        if a.disc ~= b.disc then return a.disc < b.disc end
        return (a.n or 0) < (b.n or 0)
      end)
      for _, t in ipairs(tracks) do t.disc = nil end
      partial.music.album_tracks = tracks
      cb(nil, partial)
    end)
  end)
end

-- run fn after the MusicBrainz 1 req/s slot is free
function Music:_mb_slot(fn)
  local now = self.deps.now()
  local wait = mb_next_slot - now
  if wait <= 0 then
    mb_next_slot = now + 1.1
    return fn()
  end
  mb_next_slot = mb_next_slot + 1.1
  self.deps.set_timer(wait, fn)
end

local function lucene(s)
  return '"' .. tostring(s):gsub('[%"\\]', " ") .. '"'
end

function Music:_mb_get(url, cb)
  self:_mb_slot(function()
    base.get_json(self.mb, { method = "GET", url = url, headers = {
      ["User-Agent"] = self.config.user_agent or M.DEFAULT_UA, Accept = "application/json" } }, cb)
  end)
end

function Music:_musicbrainz(pb, album_hint, cb)
  local m = pb.media
  local q = "recording:" .. lucene(strip_feat(m.title))
  if m.artist then q = q .. " AND artist:" .. lucene(m.artist) end
  self:_mb_get(util.url(MB .. "/recording", { query = q, fmt = "json", limit = 5 }), function(err, data)
    if err then return cb(err) end
    local best, best_s
    for _, r in ipairs(type(data.recordings) == "table" and data.recordings or {}) do
      local s = util.similarity(strip_feat(m.title), r.title or "")
      local ac = r["artist-credit"]
      if m.artist and type(ac) == "table" and ac[1] then
        s = 0.6 * s + 0.4 * util.similarity(m.artist, ac[1].name or (ac[1].artist and ac[1].artist.name) or "")
      end
      if (tonumber(r.score) or 0) < 80 then s = s - 0.2 end
      if not best_s or s > best_s then best, best_s = r, s end
    end
    if not best or best_s < 0.75 then return cb(nil, nil) end
    local partial = { ids = { musicbrainz = best.id }, attribution = { "MusicBrainz" }, music = {} }
    -- choose the release matching the album (iTunes collectionName / media.album) if possible
    local want = album_hint or m.album
    local rel, rel_s
    for _, r in ipairs(type(best.releases) == "table" and best.releases or {}) do
      local s = want and util.similarity(want, r.title or "") or 0.5
      local rg = r["release-group"]
      if rg and rg["primary-type"] == "Album" then s = s + 0.05 end
      if r.status == "Official" then s = s + 0.02 end
      if not rel_s or s > rel_s then rel, rel_s = r, s end
    end
    if not rel then return cb(nil, partial) end
    local y = type(rel.date) == "string" and tonumber(rel.date:match("^(%d%d%d%d)")) or nil
    partial.music.album_year = y
    self:_mb_get(MB .. "/release/" .. rel.id .. "?inc=labels&fmt=json", function(lerr, ldata)
      if not lerr and type(ldata) == "table" then
        for _, li in ipairs(type(ldata["label-info"]) == "table" and ldata["label-info"] or {}) do
          if li.label and li.label.name then partial.music.label = li.label.name; break end
        end
      end
      cb(nil, partial)
    end)
  end)
end

function Music:enrich(pb, cb)
  self:_itunes(pb, function(err, partial)
    if self.config.musicbrainz == false then return cb(err, partial) end
    local album_hint = partial and partial._hints and partial._hints.album
    self:_musicbrainz(pb, album_hint, function(merr, mbp)
      if merr then self.deps.log("debug", "MusicBrainz: " .. tostring(merr)) end
      if not partial and not mbp then return cb(err or merr, nil) end
      if not partial then
        -- MusicBrainz alone found it: modest confidence
        mbp.matched = true
        mbp.confidence = 0.75
        return cb(nil, mbp)
      end
      if mbp then
        partial.ids = mbp.ids
        partial.music.label = mbp.music.label
        partial.music.album_year = partial.music.album_year or mbp.music.album_year
        partial.attribution[#partial.attribution + 1] = "MusicBrainz"
      end
      cb(nil, partial)
    end)
  end)
end

return M
