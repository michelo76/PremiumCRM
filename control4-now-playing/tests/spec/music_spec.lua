local T = ...
local FakeDeps = require("fake_deps")
local Music = require("np.enrich.music")
local pbm = require("np.playback")

local function pb(media) return pbm.normalize({ playback = { state = "playing" }, media = media }, 0) end

local function run(fd, e, p, advance)
  local r = {}
  e:enrich(p, function(err, partial) r.err, r.partial = err, partial end, { details = {} })
  fd:advance(advance or 5)
  return r
end

local song = { kind = "music", title = "Blinding Lights", artist = "The Weeknd", album = "After Hours" }

describe("np.enrich.music", function()
  local fd, e
  before_each(function()
    Music._reset_throttle()
    fd = FakeDeps.new()
    e = Music.new({ enabled = true, musicbrainz = true }, fd.deps)
    fd:route("itunes.apple.com/search", { status = 200, body = T.fixture("itunes_search_blinding.json") })
    fd:route("itunes.apple.com/lookup", { status = 200, body = T.fixture("itunes_lookup_after_hours.json") })
    fd:route("musicbrainz.org/ws/2/recording", { status = 200, body = T.fixture("mb_recording_search.json") })
    fd:route("musicbrainz.org/ws/2/release/", { status = 200, body = T.fixture("mb_release_after_hours.json") })
  end)

  it("enriches from iTunes + MusicBrainz", function()
    local r = run(fd, e, pb(song))
    T.is_nil(r.err)
    local d = r.partial
    T.contains(fd:last("itunes.apple.com/search").url, "term=The%20Weeknd%20Blinding%20Lights")
    T.contains(fd:last("itunes.apple.com/search").url, "entity=song")
    T.contains(fd:last("lookup").url, "id=1499378108")
    T.eq(d.poster_url, "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/6f/23/0e/6f230e2d/20UMGIM12176.rgb.jpg/1000x1000bb.jpg")
    T.eq(d.year, 2019); T.deep_eq(d.genres, { "R&B/Soul" }); T.gt(d.confidence, 0.95)
    T.eq(d.music.track_genre, "R&B/Soul"); T.eq(d.music.album_year, 2019)
    T.eq(#d.music.album_tracks, 4)
    T.deep_eq(d.music.album_tracks[1], { n = 1, title = "Alone Again", duration_s = 250 })
    T.deep_eq(d.music.album_tracks[3], { n = 9, title = "Blinding Lights", duration_s = 200 })
    T.eq(d.music.label, "XO"); T.eq(d.ids.musicbrainz, "5e6e2b4d-5b0b-4d5e-9b3d-2a5b0b3f1c11")
    T.contains(fd:last("musicbrainz.org/ws/2/release/").url, "bb22bb22", "album release chosen")
    T.deep_eq(d.attribution, { "iTunes", "MusicBrainz" })
    local ua = fd:last("musicbrainz").headers["User-Agent"]
    T.contains(ua, "NowPlayingInfo")
  end)

  it("throttles MusicBrainz to <= 1 request per second", function()
    e:enrich(pb(song), function() end)
    fd:flush()
    T.eq(fd:count("musicbrainz"), 1, "second MB call waits for its slot")
    fd:advance(1.2)
    T.eq(fd:count("musicbrainz"), 2)
  end)

  it("works without MusicBrainz", function()
    e = Music.new({ musicbrainz = false }, fd.deps)
    local r = run(fd, e, pb(song))
    T.eq(fd:count("musicbrainz"), 0); T.deep_eq(r.partial.attribution, { "iTunes" }); T.is_nil(r.partial.music.label)
  end)

  it("matches without album and ignores (feat.) noise", function()
    local r = run(fd, e, pb({ kind = "music", title = "Blinding Lights (feat. Nobody)", artist = "The Weeknd" }))
    T.eq(r.partial.music.album_tracks[3].title, "Blinding Lights")
  end)

  it("low confidence -> no iTunes match; MusicBrainz alone may still identify", function()
    fd:route("musicbrainz.org/ws/2/recording", FakeDeps.json({ recordings = {} }))
    local r = run(fd, e, pb({ kind = "music", title = "Totally Unrelated Song", artist = "Nobody Known" }))
    T.is_nil(r.err); T.is_nil(r.partial)
  end)

  it("iTunes errors fall back to MusicBrainz-only result", function()
    fd:route("itunes.apple.com/search", { status = 503, body = "" })
    local r = run(fd, e, pb(song))
    T.is_nil(r.err); T.eq(r.partial.ids.musicbrainz, "5e6e2b4d-5b0b-4d5e-9b3d-2a5b0b3f1c11")
    T.eq(r.partial.confidence, 0.75)
  end)

  it("both failing -> error", function()
    fd:route("itunes.apple.com/search", { status = 200, body = "garbage" })
    fd:route("musicbrainz.org", { status = 503, body = "" })
    local r = run(fd, e, pb(song))
    T.contains(r.err, "iTunes")
  end)

  it("lookup failure keeps the search result", function()
    fd:route("itunes.apple.com/lookup", { err = "timeout" })
    local r = run(fd, e, pb(song))
    T.ok(r.partial.poster_url); T.deep_eq(r.partial.music.album_tracks, {})
  end)

  it("supports only music with a title, unless disabled", function()
    T.ok(e:supports(pb(song)))
    T.no(e:supports(pb({ kind = "movie", title = "X" })))
    T.no(e:supports(pb({ kind = "music" })))
    T.no(Music.new({ enabled = false }, fd.deps):supports(pb(song)))
  end)
end)
