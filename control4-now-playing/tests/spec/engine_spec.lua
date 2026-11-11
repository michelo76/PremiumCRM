local T = ...
local FakeDeps = require("fake_deps")
local Engine = require("np.engine")
local json = require("np.json")
local pbm = require("np.playback")

-- A clock-driven fake device: position advances with the fake clock while playing.
local function device(fd, id, init)
  local d = { id = id, kind = "fake", polls = 0, inflight = 0, max_inflight = 0 }
  d.s = init or {}
  d.s.state = d.s.state or "playing"
  d.pos0, d.t0 = d.s.position or 0, fd.t
  function d:seek(pos) self.pos0, self.t0 = pos, fd.t end
  function d:set(s) for k, v in pairs(s) do self.s[k] = v end end
  function d:position()
    if self.s.state == "playing" then return self.pos0 + (fd.t - self.t0) end
    return self.pos0
  end
  function d:pause() self.pos0 = self:position(); self.t0 = fd.t; self.s.state = "paused" end
  function d:poll(cb)
    self.polls = self.polls + 1
    if self.s.err then return cb(self.s.err) end
    self.inflight = self.inflight + 1
    if self.inflight > self.max_inflight then self.max_inflight = self.inflight end
    local function reply()
      self.inflight = self.inflight - 1
      cb(nil, pbm.normalize({
        source = { provider = self.s.provider or "roku", device_name = "Living Room Roku", app_name = self.s.app or "Netflix",
          app_id = "12", app_icon_url = self.s.icon },
        playback = { state = self.s.state, position_s = self:position(), duration_s = self.s.duration or 3600,
          position_updated_at = fd.t, is_live = self.s.is_live },
        media = self.s.media or { kind = "movie", title = self.s.title },
      }, fd.t))
    end
    if self.s.delay then fd.deps.set_timer(self.s.delay, reply) else reply() end
  end
  return d
end

local function tmdb_routes(fd)
  fd:route("/search/movie", { status = 200, body = T.fixture("tmdb_search_movie_topgun.json") })
  fd:route("/movie/361743", { status = 200, body = T.fixture("tmdb_movie_361743.json") })
  fd:route("/search/movie?", FakeDeps.json({ page = 1, results = {} })) -- default: nothing
  fd:route(function(r) return r.url:find("/search/movie", 1, true) and r.url:find("Maverick", 1, true) end,
    { status = 200, body = T.fixture("tmdb_search_movie_topgun.json") })
end

local function make(fd, devs, extra)
  local providers = {}
  for _, d in ipairs(devs) do providers[#providers + 1] = { type = "custom", provider = d } end
  local cfg = { room = { id = 12, name = "Family Room" }, providers = providers,
    enrich = { tmdb = { api_key = "K" }, music = { enabled = false } }, poll = { active_s = 2, idle_s = 5 }, sticky_s = 10 }
  for k, v in pairs(extra or {}) do cfg[k] = v end
  local e = Engine.new(cfg, fd.deps)
  local events = {}
  e:on_change(function(state, changes) events[#events + 1] = { state = state, changes = changes } end)
  return e, events
end

describe("np.engine", function()
  local fd
  before_each(function() fd = FakeDeps.new() end)

  it("publishes the first poll as version 1 with room/source/media", function()
    local d = device(fd, "roku", { title = "Top Gun: Maverick" })
    tmdb_routes(fd)
    local e, events = make(fd, { d })
    T.eq(e:get_state().version, 0)
    e:start(); fd:flush()
    local s = e:get_state()
    T.eq(s.version, 1); T.eq(s.schema, 1); T.eq(s.room.name, "Family Room")
    T.eq(s.source.app_name, "Netflix"); T.eq(s.media.title, "Top Gun: Maverick"); T.eq(s.playback.state, "playing")
    T.ok(events[1].changes.media); T.ok(events[1].changes.source); T.ok(events[1].changes.playback_state)
    T.eq(s.media_key, "roku|12||top gun maverick||||")
  end)

  it("does not bump version while position advances smoothly; polls every 2s", function()
    local d = device(fd, "roku", { title = "Top Gun: Maverick" })
    tmdb_routes(fd)
    local e = make(fd, { d })
    e:start(); fd:flush()
    fd:advance(3) -- enrichment lands (version 2)
    local v = e:get_state().version
    local polls = d.polls
    fd:advance(60)
    T.eq(e:get_state().version, v, "no churn from position")
    T.eq(d.polls - polls, 30, "2s active interval")
    local json1, etag1 = e:get_state_json()
    local json2, etag2 = e:get_state_json()
    T.eq(etag1, etag2); T.ok(json1 == json2)
  end)

  it("republishes position on a seek (>3s deviation) and on pause", function()
    local d = device(fd, "roku", { title = "Top Gun: Maverick" })
    tmdb_routes(fd)
    local e, events = make(fd, { d })
    e:start(); fd:advance(4)
    local v = e:get_state().version
    d:seek(d:position() + 2) -- small jitter: ignored
    fd:advance(2)
    T.eq(e:get_state().version, v)
    d:seek(1800)
    fd:advance(2)
    local s = e:get_state()
    T.eq(s.version, v + 1); T.ok(events[#events].changes.position); T.no(events[#events].changes.media)
    T.near(s.playback.position_s, 1802, 0.01, "seek target + 2s until next poll")
    d:pause()
    fd:advance(2)
    s = e:get_state()
    T.eq(s.version, v + 2); T.eq(s.playback.state, "paused"); T.ok(events[#events].changes.playback_state)
  end)

  it("media change -> details cleared -> debounced enrichment -> details attached", function()
    local d = device(fd, "roku", { title = "Some Unknown Thing" })
    tmdb_routes(fd)
    local e, events = make(fd, { d })
    e:start(); fd:flush()
    fd:advance(2)
    d:set({ title = "Top Gun: Maverick" })
    fd:advance(2) -- poll sees new media at t+4
    T.is_nil(e:get_state().details)
    T.eq(fd:count("Maverick"), 0, "debounce: not yet")
    fd:advance(1.6)
    T.eq(fd:count("/search/movie"), 2)
    local s = e:get_state()
    T.ok(s.details); T.eq(s.details.ids.tmdb, 361743); T.eq(s.details.matched, true)
    T.ok(events[#events].changes.details)
    local js = e:get_state_json()
    local doc = json.decode(js)
    T.eq(doc.details.ids.imdb, "tt1745960"); T.eq(doc.details.ratings.tmdb, 8.2)
    T.contains(js, '"networks":[]'); T.contains(js, '"episode":null'); T.contains(js, '"subtitle":null')
    T.contains(js, '"genres":[]', "media.genres empty array")
  end)

  it("channel surfing does not spam enrichment APIs", function()
    local d = device(fd, "roku", { title = "Show 1" })
    tmdb_routes(fd)
    local e = make(fd, { d }, { poll = { active_s = 1 } })
    e:start(); fd:flush()
    for i = 2, 8 do
      d:set({ title = "Show " .. i })
      fd:advance(1)
    end
    T.eq(fd:count("/search/"), 0)
    fd:advance(3)
    T.eq(fd:count("/search/"), 1)
    T.contains(fd:last("/search/").url, "Show%208")
  end)

  it("discards a stale enrichment result when media changes mid-flight (but caches it)", function()
    local d = device(fd, "roku", { title = "Top Gun: Maverick" })
    tmdb_routes(fd)
    fd:route("/movie/361743", { status = 200, body = T.fixture("tmdb_movie_361743.json"), delay = 3 })
    local e = make(fd, { d })
    e:start(); fd:flush()
    fd:advance(1.6) -- enrichment started, details request takes 3s
    T.eq(fd:count("/movie/361743"), 1)
    d:set({ title = "Other Programme" })
    fd:advance(2)
    fd:advance(2) -- details response arrives now
    local s = e:get_state()
    T.eq(s.media.title, "Other Programme"); T.is_nil(s.details)
    T.ok(fd:has_log("debug", "stale"))
    -- switching back is served from cache instantly
    d:set({ title = "Top Gun: Maverick" })
    fd:advance(2)
    T.ok(e:get_state().details); T.eq(fd:count("/movie/361743"), 1)
  end)

  it("switches providers (stickiness) and merges group titles", function()
    local a = device(fd, "a", { state = "playing", title = "A Movie", provider = "roku" })
    local b = device(fd, "b", { state = "idle", title = "B Movie", provider = "appletv" })
    local e = make(fd, { a, b })
    e:start(); fd:flush()
    T.eq(e:get_state().source.provider, "roku")
    a:pause(); b:set({ state = "playing" })
    fd:advance(2)
    T.eq(e:get_state().source.provider, "roku", "sticky")
    fd:advance(10)
    T.eq(e:get_state().source.provider, "appletv")
    T.eq(e:get_status().active_provider, "b")
  end)

  it("all providers failing -> off state, error logged, idle polling with backoff", function()
    local d = device(fd, "roku", { title = "X" })
    local e = make(fd, { d })
    e:start(); fd:flush()
    T.eq(e:get_state().playback.state, "playing")
    d:set({ err = "Roku unreachable (timeout)" })
    fd:advance(2)
    T.eq(e:get_state().playback.state, "playing", "stale result within stale_s")
    fd:advance(14)
    local s = e:get_state()
    T.eq(s.playback.state, "off"); T.contains(e:get_status().last_error, "unreachable")
    local polls = d.polls
    fd:advance(30)
    T.lt(d.polls - polls, 4, "provider backoff limits retries")
    d:set({ err = false })
    fd:advance(70)
    T.eq(e:get_state().playback.state, "playing")
  end)

  it("never overlaps polls with a slow provider", function()
    local d = device(fd, "roku", { title = "X", delay = 5 })
    local e = make(fd, { d })
    e:start()
    fd:advance(30)
    T.eq(d.max_inflight, 1)
    e:refresh(); e:refresh()
    fd:advance(10)
    T.eq(d.max_inflight, 1)
  end)

  it("a provider whose callback is lost cannot wedge the engine (30 s poll watchdog)", function()
    local good = device(fd, "roku", { title = "Heat" })
    local lost = { kind = "fake", id = "lost", polls = 0 }
    function lost:poll(cb) self.polls = self.polls + 1 end -- never answers
    local e = make(fd, { good, lost })
    e:start()
    fd:advance(29)
    T.eq(e:get_state().version, 0, "waiting for the lost provider")
    fd:advance(2)
    T.eq(e:get_state().media.title, "Heat", "watchdog re-polled and published the healthy provider")
    local p0 = good.polls
    fd:advance(40)
    T.gt(good.polls - p0, 10, "regular polling resumed")
    T.ok(lost.polls >= 2, "the lost provider is retried once multi gives up on it (60 s)")
    e:stop()
    T.eq(fd:pending_timers(), 0)
  end)

  it("idle uses the 5s interval", function()
    local d = device(fd, "roku", { state = "idle" })
    local e = make(fd, { d })
    e:start(); fd:flush()
    local p = d.polls
    fd:advance(20)
    T.eq(d.polls - p, 4)
  end)

  it("stop() halts polling and late results are ignored", function()
    local d = device(fd, "roku", { title = "X", delay = 1 })
    local e = make(fd, { d })
    e:start(); fd:flush()
    e:stop()
    fd:advance(30)
    T.eq(d.polls, 1); T.eq(e:get_state().version, 0)
  end)

  it("static provider push triggers a refresh", function()
    local e, events = make(fd, {}, { providers = { { type = "static", id = "c4room", name = "Family Room" } } })
    e:start(); fd:flush()
    T.eq(e:get_state().playback.state, "off")
    local ok = e:push("c4room", { playback = { state = "playing" }, media = { kind = "music", title = "So What", artist = "Miles Davis" },
      source = { app_name = "TuneIn" } })
    T.ok(ok)
    fd:flush()
    local s = e:get_state()
    T.eq(s.media.title, "So What"); T.eq(s.source.provider, "c4room"); T.eq(s.source.device_name, "Family Room")
    T.no(e:push("nope", {}))
  end)

  it("set_config: room change bumps version; provider rebuild keeps static pushes", function()
    local e, events = make(fd, {}, { providers = { { type = "static", id = "c4room" } } })
    e:start(); fd:flush()
    e:push("c4room", { playback = { state = "playing" }, media = { title = "Kept" } })
    fd:flush()
    local v = e:get_state().version
    local cfg = { room = { id = 12, name = "Den" }, providers = { { type = "static", id = "c4room", name = "Den" } },
      enrich = { music = { enabled = false } } }
    e:set_config(cfg)
    T.eq(e:get_state().room.name, "Den"); T.ok(events[#events].changes.room); T.gt(e:get_state().version, v)
    fd:flush()
    T.eq(e:get_state().media.title, "Kept")
  end)

  it("publishes LAN image URLs unchanged (no data: URIs in the state); no churn", function()
    local d = device(fd, "roku", { title = "X", icon = "http://192.168.1.50:8060/query/icon/12" })
    local e = make(fd, { d })
    e:start(); fd:flush()
    T.eq(e:get_state().source.app_icon_url, "http://192.168.1.50:8060/query/icon/12")
    T.no(e:get_state_json():find("data:", 1, true))
    local v = e:get_state().version
    fd:advance(10)
    T.eq(e:get_state().version, v)
  end)

  it("listener errors are contained; unsubscribe works", function()
    local d = device(fd, "roku", { title = "X" })
    local e = make(fd, { d })
    local n = 0
    e:on_change(function() error("listener bug") end)
    local unsub = e:on_change(function() n = n + 1 end)
    e:start(); fd:flush()
    T.eq(n, 1); T.ok(fd:has_log("error", "listener bug"))
    unsub()
    d:seek(3000); fd:advance(2)
    T.eq(n, 1)
  end)

  it("get_state returns a copy", function()
    local d = device(fd, "roku", { title = "X" })
    local e = make(fd, { d })
    e:start(); fd:flush()
    local s = e:get_state(); s.media.title = "hacked"
    T.eq(e:get_state().media.title, "X")
  end)

  it("etag changes with version; flatten exposes variables", function()
    local d = device(fd, "roku", { title = "X" })
    local e = make(fd, { d })
    e:start(); fd:flush()
    local _, e1 = e:get_state_json()
    d:seek(3000); fd:advance(2)
    local _, e2 = e:get_state_json()
    T.neq(e1, e2)
    local vars = {}
    for _, v in ipairs(e:flatten()) do vars[v.name] = v.value end
    T.eq(vars.TITLE, "X"); T.eq(vars.SOURCE_PROVIDER, "roku"); T.eq(vars.APP_NAME, "Netflix")
  end)

  it("works with sync (re-entrant) HTTP callbacks end-to-end: Roku + HA merged", function()
    fd = FakeDeps.new({ sync = true })
    fd:route("/query/device-info", { status = 200, body = T.fixture("roku_device_info.xml") })
    fd:route("/query/active-app", { status = 200, body = T.fixture("roku_active_app_netflix.xml") })
    fd:route("/query/media-player", { status = 200, body = T.fixture("roku_media_player_play.xml") })
    fd:route("/api/states/", { status = 200, body = T.fixture("ha_movie_title.json") })
    tmdb_routes(fd)
    local e = Engine.new({ room = { id = 1, name = "LR" }, providers = {
      { type = "roku", host = "192.168.1.50", group = "lr" },
      { type = "homeassistant", base_url = "http://ha:8123", token = "t", entity_id = "media_player.living_room_roku", group = "lr" },
    }, enrich = { tmdb = { api_key = "K" }, music = { enabled = false } } }, fd.deps)
    e:start(); fd:flush()
    local s = e:get_state()
    T.eq(s.source.provider, "roku"); T.eq(s.media.title, "Top Gun: Maverick"); T.eq(s.media.kind, "movie")
    T.eq(e:get_status().merged_from, "ha:media_player.living_room_roku")
    fd:advance(2)
    T.eq(e:get_state().details.ids.tmdb, 361743)
    local vars = {}
    for _, v in ipairs(e:flatten()) do vars[v.name] = v.value end
    T.eq(vars.DISPLAY_LINE_1, "Top Gun: Maverick (2022)")
    T.eq(vars.DISPLAY_LINE_2, "Netflix on Living Room Roku")
    T.eq(vars.CONTENT_RATING, "PG-13"); T.eq(vars.IMDB_ID, "tt1745960")
  end)
end)
