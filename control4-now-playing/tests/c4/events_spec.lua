local T = ...
local Events = require("c4.events")

local function st(state, o)
  o = o or {}
  return {
    media_key = o.key or "", playback = { state = state },
    source = { provider = o.provider or "roku", device_name = o.device or "LR Roku", app_name = o.app, app_id = o.app_id },
    media = { kind = o.kind or "unknown", title = o.title, artist = o.artist },
    details = o.details,
  }
end

local function run(seq)
  local snap = Events.initial()
  local all = {}
  for _, s in ipairs(seq) do
    local ev
    ev, snap = Events.derive(snap, s, {})
    all[#all + 1] = table.concat(ev, ",")
  end
  return all, snap
end

describe("c4.events.derive", function()
  it("initial truthful state: playing a movie fires each start event once", function()
    local out = run({ st("playing", { key = "k1", title = "Inception", kind = "movie", app = "Netflix" }) })
    T.eq(out[1], "Source Changed,App Changed,Media Changed,Playback Started,Movie Started")
  end)
  it("initial idle / off state fires only Source Changed (nothing stopped)", function()
    local out = run({ st("idle"), st("idle"), st("off") })
    T.eq(out[1], "Source Changed")
    T.eq(out[2], "")
    T.eq(out[3], "")
  end)
  it("play -> pause -> resume -> stop", function()
    local m = { key = "k1", title = "The Bear", kind = "episode", app = "Hulu" }
    local out = run({ st("playing", m), st("paused", m), st("playing", m), st("stopped", m) })
    T.eq(out[2], "Playback Paused")
    T.eq(out[3], "Playback Resumed")
    T.eq(out[4], "Playback Stopped")
  end)
  it("buffering never looks like a stop/start", function()
    local m = { key = "k1", title = "X", kind = "movie" }
    local out = run({ st("playing", m), st("buffering", m), st("playing", m) })
    T.eq(out[2], ""); T.eq(out[3], "")
  end)
  it("next track while playing: Media Changed + Music Track Started, no Playback Started", function()
    local out = run({ st("playing", { key = "a", title = "One", artist = "A", kind = "music" }),
      st("playing", { key = "b", title = "Two", artist = "A", kind = "music" }) })
    T.eq(out[2], "Media Changed,Music Track Started")
  end)
  it("new media that starts paused, then plays: Started (not Resumed) + kind event", function()
    local m = { key = "k9", title = "Dune", kind = "movie" }
    local out = run({ st("idle"), st("paused", m), st("playing", m) })
    T.eq(out[2], "Media Changed")
    T.eq(out[3], "Playback Started,Movie Started")
  end)
  it("paused on A then playing B -> Started", function()
    local out = run({ st("playing", { key = "a", title = "A", kind = "movie" }), st("paused", { key = "a", title = "A", kind = "movie" }),
      st("playing", { key = "b", title = "B", kind = "live_tv" }) })
    T.eq(out[3], "Media Changed,Playback Started,Live TV Started")
  end)
  it("title-less Roku ECP: pause/resume and app changes", function()
    local out = run({ st("playing", { app = "Netflix", app_id = "12" }), st("paused", { app = "Netflix", app_id = "12" }),
      st("playing", { app = "Netflix", app_id = "12" }), st("playing", { app = "Hulu", app_id = "2285" }) })
    T.eq(out[1], "Source Changed,App Changed,Playback Started")
    T.eq(out[2], "Playback Paused")
    T.eq(out[3], "Playback Resumed")
    T.eq(out[4], "App Changed")
  end)
  it("off after playing -> Stopped; title arriving later -> Media Changed + kind event", function()
    local out = run({ st("playing", { app = "Netflix" }), st("playing", { app = "Netflix", key = "m", title = "Heat", kind = "movie" }),
      st("off", { app = "Netflix" }) })
    T.eq(out[2], "Media Changed,Movie Started")
    T.eq(out[3], "Playback Stopped")
  end)
  it("Details Available once per media_key", function()
    local m = { key = "k1", title = "X", kind = "movie" }
    local md = { key = "k1", title = "X", kind = "movie", details = { matched = true } }
    local out = run({ st("playing", m), st("playing", md), st("paused", md), st("playing", md) })
    T.eq(out[2], "Details Available")
    T.eq(out[3], "Playback Paused")
    T.eq(out[4], "Playback Resumed")
    local md2 = { key = "k2", title = "Y", kind = "movie", details = { matched = true } }
    local out2 = run({ st("playing", md), st("playing", md2) })
    T.eq(out2[2], "Media Changed,Movie Started,Details Available")
  end)
  it("source change", function()
    local out = run({ st("playing", { provider = "roku" }), st("playing", { provider = "appletv", device = "ATV" }) })
    T.eq(out[2], "Source Changed")
  end)
  it("derive is pure: does not mutate the snapshot", function()
    local snap = Events.initial()
    local copy = {}
    for k, v in pairs(snap) do copy[k] = v end
    Events.derive(snap, st("playing", { key = "x", title = "t" }), {})
    T.deep_eq(snap, copy)
  end)
end)
