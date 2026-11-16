local T = ...
local FakeDeps = require("fake_deps")
local Omdb = require("np.enrich.omdb")
local pbm = require("np.playback")

local function pb(media) return pbm.normalize({ playback = { state = "playing" }, media = media }, 0) end

local function run(fd, e, p, ctx)
  local r = {}
  e:enrich(p, function(err, partial) r.err, r.partial = err, partial end, ctx or { details = {} })
  fd:flush()
  return r
end

describe("np.enrich.omdb", function()
  local fd, e
  before_each(function()
    fd = FakeDeps.new()
    e = Omdb.new({ api_key = "OK" }, fd.deps)
  end)

  it("uses the IMDb id from TMDB and maps ratings/facts", function()
    fd:route("i=tt1745960", { status = 200, body = T.fixture("omdb_tt1745960.json") })
    local ctx = { details = { matched = true, ids = { imdb = "tt1745960" } } }
    T.ok(e:supports(pb({ kind = "video" }), ctx))
    local r = run(fd, e, pb({ kind = "movie", title = "Top Gun: Maverick" }), ctx)
    T.contains(fd:last("omdbapi").url, "apikey=OK"); T.contains(fd:last("omdbapi").url, "plot=short")
    local d = r.partial
    T.eq(d.ratings.imdb.score, 8.2); T.eq(d.ratings.imdb.votes, 751532)
    T.eq(d.ratings.rotten_tomatoes, 96); T.eq(d.ratings.metacritic, 78)
    T.eq(d.content_rating, "PG-13")
    T.deep_eq(d.facts, { { label = "Awards", value = "Won 1 Oscar. 16 wins & 106 nominations total" },
      { label = "Box Office", value = "$718,732,821" } })
    T.eq(d.release_date, "2022-05-27"); T.eq(d.runtime_min, 130)
    T.deep_eq(d.crew.writers, { "Jim Cash", "Jack Epps Jr.", "Peter Craig" })
    T.eq(d.cast[1].name, "Tom Cruise"); T.deep_eq(d.attribution, { "OMDb" })
    T.eq(d.matched, true)
  end)

  it("falls back to a title search when TMDB is absent", function()
    fd:route("t=Top%20Gun%3A%20Maverick", { status = 200, body = T.fixture("omdb_tt1745960.json") })
    local r = run(fd, e, pb({ kind = "movie", title = "Top Gun: Maverick (2022)" }))
    local url = fd:last("omdbapi").url
    T.contains(url, "type=movie"); T.contains(url, "y=2022"); T.contains(url, "plot=full")
    T.eq(r.partial.matched, true); T.eq(r.partial.confidence, 0.9)
    T.eq(r.partial.ids.imdb, "tt1745960")
    T.ok(r.partial.poster_url:find("^https://m.media%-amazon.com"))
  end)

  it("rejects a title search that returns a different title", function()
    fd:route("omdbapi", { status = 200, body = T.fixture("omdb_tt14452776.json") })
    local r = run(fd, e, pb({ kind = "movie", title = "Completely Different" }))
    T.is_nil(r.partial); T.is_nil(r.err)
  end)

  it("episodes: series ratings + episode block when TMDB lacks it", function()
    fd:route("t=The%20Bear", { status = 200, body = T.fixture("omdb_tt14452776.json") })
    fd:route("Episode=7", { status = 200, body = T.fixture("omdb_bear_s2e7.json") })
    local r = run(fd, e, pb({ kind = "episode", series_title = "The Bear", title = "Forks", season = 2, episode = 7 }))
    T.contains(fd:last("Episode=7").url, "i=tt14452776")
    T.eq(r.partial.ratings.imdb.score, 8.5); T.eq(r.partial.episode.title, "Forks")
    T.eq(r.partial.episode.rating, 9.6); T.eq(r.partial.episode.air_date, "2023-06-22")
    T.is_nil(r.partial.ratings.rotten_tomatoes); T.is_nil(r.partial.ratings.metacritic, "N/A ignored")
    T.deep_eq(r.partial.crew.directors, {})
  end)

  it("skips the episode call when TMDB already has the episode", function()
    fd:route("i=tt14452776", { status = 200, body = T.fixture("omdb_tt14452776.json") })
    run(fd, e, pb({ kind = "episode", series_title = "The Bear", season = 2, episode = 7 }),
      { details = { matched = true, ids = { imdb = "tt14452776" }, episode = { title = "Forks" } } })
    T.eq(fd:count("omdbapi"), 1)
  end)

  it("not found -> no match, not an error", function()
    fd:route("omdbapi", { status = 200, body = T.fixture("omdb_notfound.json") })
    local r = run(fd, e, pb({ kind = "movie", title = "Nope" }))
    T.is_nil(r.err); T.is_nil(r.partial)
  end)

  it("invalid key (401 + body) and request limit block further calls", function()
    fd:route("omdbapi", { status = 401, body = T.fixture("omdb_badkey.json") })
    local r = run(fd, e, pb({ kind = "movie", title = "A" }))
    T.contains(r.err, "invalid API key")
    run(fd, e, pb({ kind = "movie", title = "A" }))
    T.eq(fd:count("omdbapi"), 1)
    local fd2 = FakeDeps.new()
    local e2 = Omdb.new({ api_key = "OK" }, fd2.deps)
    fd2:route("omdbapi", { status = 401, body = T.fixture("omdb_limit.json") })
    T.contains(run(fd2, e2, pb({ kind = "movie", title = "A" })).err, "limit")
  end)

  it("500 / garbage / timeout are errors", function()
    fd:route("omdbapi", { status = 500, body = "" })
    T.contains(run(fd, e, pb({ kind = "movie", title = "A" })).err, "500")
    fd:route("omdbapi", { status = 200, body = "Service Unavailable" })
    T.contains(run(fd, e, pb({ kind = "movie", title = "A" })).err, "invalid JSON")
    fd:route("omdbapi", { err = "timeout" })
    T.contains(run(fd, e, pb({ kind = "movie", title = "A" })).err, "timeout")
  end)

  it("supports", function()
    T.no(Omdb.new({}, fd.deps):supports(pb({ kind = "movie", title = "X" })))
    T.no(e:supports(pb({ kind = "music", title = "X" })))
    T.no(e:supports(pb({ kind = "video", title = "X" })))
    T.ok(e:supports(pb({ kind = "episode", series_title = "X" })))
  end)
end)
