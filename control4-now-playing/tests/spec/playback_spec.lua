local T = ...
local pbm = require("np.playback")

describe("np.playback.normalize", function()
  it("sanitizes junk input", function()
    local pb = pbm.normalize({
      source = { provider = "  appletv ", device_name = 42, app_icon_url = "javascript:alert(1)" },
      playback = { state = "PLAY", position_s = "12.5", duration_s = -4, is_live = "true", volume = 300 },
      media = { kind = "tvshow", title = "  ", season = "2", episode = "x", year = 99999,
        genres = "Drama, Comedy", artwork_url = "ftp://nope" },
    }, 100)
    T.eq(pb.source.provider, "appletv"); T.eq(pb.source.device_name, "42"); T.is_nil(pb.source.app_icon_url)
    T.eq(pb.playback.state, "playing"); T.eq(pb.playback.position_s, 12.5); T.is_nil(pb.playback.duration_s)
    T.eq(pb.playback.is_live, true); T.is_nil(pb.playback.volume); T.eq(pb.playback.position_updated_at, 100)
    T.eq(pb.media.kind, "episode"); T.is_nil(pb.media.title); T.eq(pb.media.season, 2); T.is_nil(pb.media.episode)
    T.is_nil(pb.media.year); T.deep_eq(pb.media.genres, { "Drama", "Comedy" }); T.is_nil(pb.media.artwork_url)
  end)
  it("defaults unknown values", function()
    local pb = pbm.normalize("garbage", 5, { provider = "c4room" })
    T.eq(pb.playback.state, "idle"); T.eq(pb.media.kind, "unknown"); T.eq(pb.source.provider, "c4room")
    T.deep_eq(pb.media.genres, {})
  end)
  it("is_active", function()
    T.ok(pbm.is_active({ playback = { state = "paused" } }))
    T.no(pbm.is_active({ playback = { state = "idle" } }))
  end)
end)
