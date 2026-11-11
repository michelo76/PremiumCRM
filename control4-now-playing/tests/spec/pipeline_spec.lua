local T = ...
local FakeDeps = require("fake_deps")
local Pipeline = require("np.enrich.pipeline")
local pbm = require("np.playback")

-- fake enricher: result scripted, optional async delay
local function fake(name, opts)
  opts = opts or {}
  local e = { name = name, attribution = name, calls = 0 }
  function e:supports(pb, ctx)
    if opts.supports then return opts.supports(pb, ctx) end
    return true
  end
  function e:enrich(pb, cb, ctx)
    self.calls = self.calls + 1
    self.last_ctx_imdb = ctx and ctx.details and ctx.details.ids and ctx.details.ids.imdb
    local res = opts.result
    if type(res) == "function" then res = res(pb, ctx) end
    if opts.delay then
      opts.fd.deps.set_timer(opts.delay, function() cb(opts.err, res) end)
    else
      cb(opts.err, res)
    end
  end
  return e
end

local function pb(title) return pbm.normalize({ playback = { state = "playing" }, media = { kind = "movie", title = title } }, 0) end

describe("np.enrich.pipeline merge", function()
  it("fills gaps, merges ratings/ids by key, appends facts and attribution", function()
    local acc = {}
    Pipeline.merge(acc, { matched = true, confidence = 0.93, overview = "TMDB overview", genres = { "Action" },
      ratings = { tmdb = 8.2 }, ids = { imdb = "tt1", tmdb = 5 }, facts = { { label = "Budget", value = "$1M" } },
      cast = {}, attribution = { "TMDB" }, _hints = { imdb_episode = "tt9" } })
    local hints = {}
    Pipeline.merge(acc, { matched = true, confidence = 0.5, overview = "OMDb plot", genres = { "Drama" },
      ratings = { imdb = { score = 8.2, votes = 10 }, rotten_tomatoes = 96, tmdb = 1 },
      ids = { imdb = "tt-other" }, facts = { { label = "Budget", value = "dup" }, { label = "Awards", value = "1 Oscar" } },
      cast = { { name = "Tom" } }, content_rating = "PG-13", attribution = { "OMDb", "TMDB" } }, hints)
    T.eq(acc.overview, "TMDB overview"); T.deep_eq(acc.genres, { "Action" })
    T.eq(acc.ratings.tmdb, 8.2); T.eq(acc.ratings.imdb.score, 8.2); T.eq(acc.ratings.rotten_tomatoes, 96)
    T.eq(acc.ids.imdb, "tt1"); T.eq(acc.ids.tmdb, 5)
    T.deep_eq(acc.facts, { { label = "Budget", value = "$1M" }, { label = "Awards", value = "1 Oscar" } })
    T.deep_eq(acc.cast, { { name = "Tom" } }, "empty array filled by later")
    T.eq(acc.content_rating, "PG-13"); T.deep_eq(acc.attribution, { "TMDB", "OMDb" })
    T.eq(acc.confidence, 0.93); T.eq(acc.matched, true)
    T.is_nil(acc._hints)
  end)
  it("finalize guarantees arrays/tables", function()
    local d = Pipeline.finalize({ matched = true, music = {} })
    T.deep_eq(d.genres, {}); T.deep_eq(d.crew.directors, {}); T.deep_eq(d.ratings, {})
    T.deep_eq(d.music.album_tracks, {}); T.deep_eq(d.attribution, {})
  end)
end)

describe("np.enrich.pipeline lookup", function()
  local fd
  before_each(function() fd = FakeDeps.new() end)

  it("runs enrichers in order, passing accumulated details (omdb sees imdb id)", function()
    local tm = fake("TMDB", { result = { matched = true, confidence = 0.9, ids = { imdb = "tt1745960" }, attribution = { "TMDB" } } })
    local om = fake("OMDb", { result = { ratings = { rotten_tomatoes = 96 }, attribution = { "OMDb" } } })
    local p = Pipeline.new({}, fd.deps, { enrichers = { tm, om } })
    local got, info
    p:lookup(pb("Top Gun"), "k1", function(d, i) got, info = d, i end)
    fd:flush()
    T.eq(om.last_ctx_imdb, "tt1745960")
    T.eq(got.ratings.rotten_tomatoes, 96); T.deep_eq(got.attribution, { "TMDB", "OMDb" }); T.eq(got.confidence, 0.9)
    T.no(info.cached)
  end)

  it("caches positive results for 6h and serves synchronously", function()
    local tm = fake("TMDB", { result = { matched = true, overview = "x" } })
    local p = Pipeline.new({}, fd.deps, { enrichers = { tm } })
    p:lookup(pb("A"), "k", function() end); fd:flush()
    local sync_hit
    p:lookup(pb("A"), "k", function(d, info) sync_hit = info.cached and d.overview end)
    T.eq(sync_hit, "x"); T.eq(tm.calls, 1)
    T.eq(p:peek("k").overview, "x")
    fd:advance(6 * 3600 + 1)
    T.is_nil(p:peek("k"))
    p:lookup(pb("A"), "k", function() end); fd:flush()
    T.eq(tm.calls, 2)
  end)

  it("negative cache: no match for 10 min, transient errors only 2 min", function()
    local none = fake("TMDB", { result = nil })
    local p = Pipeline.new({}, fd.deps, { enrichers = { none } })
    local got = "unset"
    p:lookup(pb("A"), "k", function(d, info) got = d; T.ok(info.negative) end); fd:flush()
    T.is_nil(got); T.eq(p:peek("k"), false)
    fd:advance(599); T.eq(p:peek("k"), false)
    fd:advance(2); T.is_nil(p:peek("k"))
    local bad = fake("TMDB", { err = "HTTP 500" })
    p = Pipeline.new({}, fd.deps, { enrichers = { bad } })
    p:lookup(pb("A"), "k", function() end); fd:flush()
    T.eq(p:peek("k"), false); fd:advance(121); T.is_nil(p:peek("k"))
  end)

  it("one enricher failing does not lose another's result", function()
    local bad = fake("TMDB", { err = "rate limited" })
    local good = fake("iTunes", { result = { matched = true, confidence = 0.8, poster_url = "http://p" } })
    local p = Pipeline.new({}, fd.deps, { enrichers = { bad, good } })
    local got, info
    p:lookup(pb("A"), "k", function(d, i) got, info = d, i end); fd:flush()
    T.eq(got.poster_url, "http://p"); T.eq(#info.errors, 1)
  end)

  it("survives a crashing enricher", function()
    local boom = { name = "boom", supports = function() return true end, enrich = function() error("nil index") end }
    local good = fake("g", { result = { matched = true } })
    local p = Pipeline.new({}, fd.deps, { enrichers = { boom, good } })
    local got
    p:lookup(pb("A"), "k", function(d) got = d end); fd:flush()
    T.ok(got and got.matched)
  end)

  it("coalesces concurrent lookups for the same key", function()
    local slow = fake("TMDB", { delay = 1, fd = fd, result = { matched = true, overview = "o" } })
    local p = Pipeline.new({}, fd.deps, { enrichers = { slow } })
    local n = 0
    p:lookup(pb("A"), "k", function(d) if d then n = n + 1 end end)
    p:lookup(pb("A"), "k", function(d) if d then n = n + 1 end end)
    fd:advance(2)
    T.eq(slow.calls, 1); T.eq(n, 2)
  end)

  it("aborts mid-chain when is_current turns false (nothing cached)", function()
    local current = true
    local first = fake("TMDB", { delay = 1, fd = fd, result = { matched = true } })
    local second = fake("OMDb", { result = { overview = "x" } })
    local p = Pipeline.new({}, fd.deps, { enrichers = { first, second } })
    local info
    p:lookup(pb("A"), "k", function(_, i) info = i end, { is_current = function() return current end })
    current = false
    fd:advance(2)
    T.ok(info.aborted); T.eq(second.calls, 0); T.is_nil(p:peek("k"))
  end)

  it("unsupported media is not looked up or cached", function()
    local e = fake("TMDB", { supports = function() return false end })
    local p = Pipeline.new({}, fd.deps, { enrichers = { e } })
    local info
    p:lookup(pb("A"), "k", function(_, i) info = i end)
    T.ok(info.unsupported); T.eq(e.calls, 0); T.is_nil(p:peek("k"))
  end)

  it("LRU evicts beyond max entries", function()
    local e = fake("x", { result = { matched = true } })
    local p = Pipeline.new({ cache = { max = 3 } }, fd.deps, { enrichers = { e } })
    for i = 1, 5 do p:lookup(pb("A" .. i), "k" .. i, function() end) end
    fd:flush()
    T.is_nil(p:peek("k1")); T.is_nil(p:peek("k2")); T.ok(p:peek("k5"))
  end)

  it("persists compactly through deps.store and reloads", function()
    local e = fake("x", { result = { matched = true, overview = "persisted", cast = {
      { name = "1" }, { name = "2" }, { name = "3" }, { name = "4" }, { name = "5" }, { name = "6" },
      { name = "7" }, { name = "8" }, { name = "9" }, { name = "10" }, { name = "11" }, { name = "12" } } } })
    local p = Pipeline.new({ cache = { persist = true } }, fd.deps, { enrichers = { e } })
    p:lookup(pb("A"), "k", function() end)
    fd:advance(6)
    local raw = fd.store_data["np_enrich_cache_v1"]
    T.eq(type(raw), "string"); T.contains(raw, "persisted")
    local p2 = Pipeline.new({ cache = { persist = true } }, fd.deps, { enrichers = {} })
    local d = p2:peek("k")
    T.eq(d.overview, "persisted"); T.eq(#d.cast, 10)
  end)

  it("builds enrichers from config (only configured ones; music on by default)", function()
    T.deep_eq(Pipeline.new({}, fd.deps):enabled_names(), { "iTunes" })
    T.deep_eq(Pipeline.new({ tmdb = { api_key = "k" }, omdb = { api_key = "o" }, gracenote = { api_key = "g" },
      music = { enabled = false } }, fd.deps):enabled_names(), { "TMDB", "OMDb", "Gracenote" })
    T.deep_eq(Pipeline.new({ tmdb = { api_key = "" } }, fd.deps):enabled_names(), { "iTunes" })
  end)
end)

describe("np.enrich.pipeline with real enrichers (TMDB -> OMDb)", function()
  it("merges TMDB and OMDb for a movie", function()
    local fd = FakeDeps.new()
    fd:route("/search/movie", { status = 200, body = T.fixture("tmdb_search_movie_topgun.json") })
    fd:route("/movie/361743", { status = 200, body = T.fixture("tmdb_movie_361743.json") })
    fd:route("omdbapi.com", { status = 200, body = T.fixture("omdb_tt1745960.json") })
    local p = Pipeline.new({ tmdb = { api_key = "k" }, omdb = { api_key = "o" }, music = { enabled = false } }, fd.deps)
    local d
    p:lookup(pb("Top Gun: Maverick"), "k", function(x) d = x end)
    fd:flush()
    T.contains(fd:last("omdbapi").url, "i=tt1745960")
    T.eq(d.ratings.tmdb, 8.2); T.eq(d.ratings.imdb.score, 8.2); T.eq(d.ratings.rotten_tomatoes, 96)
    T.eq(d.overview:sub(1, 20), "After more than thir", "TMDB overview kept")
    T.eq(d.facts[1].label, "Budget"); T.eq(d.facts[#d.facts].label, "Box Office")
    T.deep_eq(d.attribution, { "TMDB", "OMDb" }); T.eq(d.matched, true)
  end)
end)
