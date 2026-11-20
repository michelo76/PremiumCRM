local T = ...
local Status = require("c4.status")

local function st(state, media, source, details)
  return { playback = { state = state }, media = media or {}, source = source or {}, details = details }
end

describe("c4.status.button_text (Navigator button / ICON_CHANGED icon_description)", function()
  it("episode, music, movie, app only", function()
    T.eq(Status.button_text(st("playing", { kind = "episode", series_title = "The Bear", season = 2, episode = 7,
      episode_title = "Forks" })), "The Bear — S2·E7 Forks")
    T.eq(Status.button_text(st("playing", { kind = "music", title = "Dreams", artist = "Fleetwood Mac" })), "Dreams — Fleetwood Mac")
    T.eq(Status.button_text(st("buffering", { kind = "movie", title = "Heat", year = 1995 })), "Heat (1995)")
    T.eq(Status.button_text(st("playing", { kind = "unknown" }, { app_name = "Netflix", device_name = "Roku" })), "Netflix")
  end)
  it("paused gets a prefix; idle / stopped / off / nothing known -> default", function()
    T.eq(Status.button_text(st("paused", { kind = "music", title = "Dreams", artist = "Fleetwood Mac" })), "Paused: Dreams — Fleetwood Mac")
    for _, s in ipairs({ "idle", "stopped", "off" }) do
      T.eq(Status.button_text(st(s, { kind = "movie", title = "Heat" })), "Now Playing", s)
    end
    T.eq(Status.button_text(st("playing")), "Now Playing")
    T.eq(Status.button_text(nil), "Now Playing")
  end)
  it("caps at 60 characters, UTF-8 safe, with an ellipsis", function()
    local long = string.rep("é", 80)
    local t = Status.button_text(st("playing", { kind = "unknown", title = long }))
    local n = 0
    for _ in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    T.eq(n, 60); T.eq(t:sub(-3), "…"); T.eq(t:sub(1, 2), "é")
    T.ok(not t:find("[\192-\255]$") and t:find("^[%z\1-\127\194-\244]"), "no broken sequence")
    local ascii = Status.button_text(st("paused", { kind = "unknown", title = string.rep("word ", 20) }))
    T.ok(#ascii <= 62 and ascii:sub(-3) == "…" and not ascii:find(" …", 1, true), ascii)
    T.eq(Status.button_text(st("playing", { kind = "unknown", title = string.rep("x", 60) })), string.rep("x", 60))
  end)
end)
