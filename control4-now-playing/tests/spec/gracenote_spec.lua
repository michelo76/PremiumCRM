local T = ...
local FakeDeps = require("fake_deps")
local Gracenote = require("np.enrich.gracenote")
local pbm = require("np.playback")

local function pb(media) return pbm.normalize({ playback = { state = "playing", is_live = true }, media = media }, 0) end

local function run(fd, e, p, ctx)
  local r = {}
  e:enrich(p, function(err, partial) r.err, r.partial = err, partial end, ctx or { details = {} })
  fd:flush()
  return r
end

describe("np.enrich.gracenote (fixture-only; untested against live API)", function()
  local fd, e
  before_each(function()
    fd = FakeDeps.new() -- clock 2026-09-21T14:13:20Z
    e = Gracenote.new({ api_key = "GN", lineup_id = "USA-OTA22201-DEFAULT" }, fd.deps)
    fd:route("/lineups/USA-OTA22201-DEFAULT/channels", { status = 200, body = T.fixture("gn_channels.json") })
    fd:route("/stations/10021/airings", { status = 200, body = T.fixture("gn_airings.json") })
  end)

  it("finds the current airing by channel number", function()
    local live = pb({ kind = "live_tv", channel_number = "7.1", channel_name = "WJLA-HD", title = "ABC World News" })
    T.ok(e:supports(live))
    local r = run(fd, e, live)
    T.is_nil(r.err)
    local url = fd:last("/airings").url
    T.contains(url, "api_key=GN"); T.contains(url, "startDateTime=2026-09-21T10%3A13Z")
    local d = r.partial
    T.eq(d.live.program_title, "ABC World News Tonight With David Muir")
    T.eq(d.live.program_start, 1790000000 - 800); T.eq(d.live.program_end, 1790000000 + 1000)
    T.eq(d.live.next.title, "Jeopardy!"); T.eq(d.live.next.start, 1790000000 + 1000)
    T.eq(d.overview, "David Muir anchors the day's top national and international stories.")
    T.eq(d.ids.tms, "EP000046230123"); T.eq(d._hints.tms_root_id, "25789123")
    T.eq(d.content_rating, "TV-G"); T.deep_eq(d.genres, { "News" })
    T.eq(d.poster_url, "https://demo.tmsimg.com/assets/p184610_b_h3_aa.jpg")
    T.eq(d.episode.title, "September 21, 2026"); T.deep_eq(d.attribution, { "Gracenote" })
  end)

  it("matches by call sign and caches the lineup", function()
    local live = pb({ kind = "live_tv", channel_name = "WJLA-DT" })
    run(fd, e, live)
    T.eq(Gracenote.find_station({ { channel = "7.1", callSign = "WJLADT", stationId = "1" } }, nil, "WJLA-HD"), "1")
    run(fd, e, live)
    T.eq(fd:count("/channels"), 1); T.eq(fd:count("/airings"), 2)
  end)

  it("channel_map short-circuits the lineup", function()
    e = Gracenote.new({ api_key = "GN", channel_map = { ["7.1"] = "10021" } }, fd.deps)
    local r = run(fd, e, pb({ kind = "live_tv", channel_number = "7.1" }))
    T.eq(fd:count("/channels"), 0); T.ok(r.partial.live)
  end)

  it("unknown station -> no match", function()
    local r = run(fd, e, pb({ kind = "live_tv", channel_number = "99.9" }))
    T.is_nil(r.err); T.is_nil(r.partial)
  end)

  it("program search fallback for movies when nothing matched", function()
    fd:route("/programs/search", { status = 200, body = T.fixture("gn_program_search.json") })
    local movie = pb({ kind = "movie", title = "Top Gun: Maverick", year = 2022 })
    T.ok(e:supports(movie, { details = {} }))
    T.no(e:supports(movie, { details = { matched = true } }))
    local r = run(fd, e, movie)
    T.eq(r.partial.ids.tms, "MV013948950000"); T.eq(r.partial.content_rating, "PG-13")
    T.deep_eq(r.partial.crew.directors, { "Joseph Kosinski" }); T.eq(r.partial.year, 2022)
  end)

  it("errors: 403 bad key, garbage, unexpected shape", function()
    fd:route("/channels", { status = 403, body = "<h1>Developer Inactive</h1>" })
    T.contains(run(fd, e, pb({ kind = "live_tv", channel_number = "7.1" })).err, "403")
    local fd2 = FakeDeps.new()
    local e2 = Gracenote.new({ api_key = "GN", lineup_id = "L" }, fd2.deps)
    fd2:route("/channels", FakeDeps.json({ error = "x" }))
    T.contains(run(fd2, e2, pb({ kind = "live_tv", channel_number = "7.1" })).err, "unexpected")
  end)

  it("needs a key and lineup or map for live", function()
    T.no(Gracenote.new({}, fd.deps):supports(pb({ kind = "live_tv", channel_number = "7.1" })))
    T.no(Gracenote.new({ api_key = "k" }, fd.deps):supports(pb({ kind = "live_tv", channel_number = "7.1" })))
    T.no(e:supports(pb({ kind = "live_tv" })))
  end)
end)
