local T = ...
local flatten = require("np.flatten")

local function vars(state, now)
  local out = {}
  for _, v in ipairs(flatten.flatten(state, now)) do out[v.name] = v end
  return out
end

local episode_state = {
  schema = 1, version = 7, updated_at = 1790000000.7, media_key = "k",
  room = { id = 12, name = "Family Room" },
  source = { provider = "roku", device_name = "Living Room Roku", app_name = "Netflix", app_id = "12" },
  playback = { state = "playing", position_s = 600, duration_s = 2400, position_updated_at = 1790000000, is_live = false },
  media = { kind = "episode", title = "Forks", series_title = "The Bear", season = 2, episode = 7, episode_title = "Forks", genres = {} },
  details = { matched = true, genres = { "Drama", "Comedy" }, content_rating = "TV-MA", runtime_min = 40,
    overview = string.rep("x", 1200), tagline = nil,
    ratings = { imdb = { score = 8.5, votes = 1 }, rotten_tomatoes = 99, metacritic = 88 },
    cast = { { name = "A" }, { name = "B" }, { name = "C" }, { name = "D" }, { name = "E" }, { name = "F" } },
    crew = { directors = { "Ramy Youssef" }, writers = {}, creators = {} }, networks = { "Hulu", "FX" },
    poster_url = "https://img/p.jpg", backdrop_url = "https://img/b.jpg",
    ids = { imdb = "tt14452776" }, links = { imdb = "https://www.imdb.com/title/tt14452776/" }, year = 2022 },
}

describe("np.flatten", function()
  it("produces typed, never-nil variables in definition order", function()
    local list = flatten.flatten(episode_state, 1790000000)
    local defs = flatten.definitions()
    T.eq(#list, #defs)
    for i, v in ipairs(list) do
      T.eq(v.name, defs[i].name); T.eq(v.type, defs[i].type)
      if v.type == "STRING" then T.eq(type(v.value), "string", v.name)
      elseif v.type == "NUMBER" then T.eq(type(v.value), "number", v.name)
      else T.eq(type(v.value), "boolean", v.name) end
    end
  end)
  it("maps an episode", function()
    local v = vars(episode_state, 1790000060)
    T.eq(v.TITLE.value, "Forks"); T.eq(v.SERIES_TITLE.value, "The Bear"); T.eq(v.SEASON.value, 2)
    T.eq(v.DISPLAY_LINE_1.value, "The Bear — S2·E7 Forks")
    T.eq(v.DISPLAY_LINE_2.value, "Netflix on Living Room Roku")
    T.eq(v.IS_PLAYING.value, true); T.eq(v.IS_PAUSED.value, false)
    T.eq(v.POSITION_SECONDS.value, 660, "extrapolated"); T.eq(v.PROGRESS_PERCENT.value, 28)
    T.eq(v.GENRES.value, "Drama, Comedy"); T.eq(v.CAST.value, "A, B, C, D, E")
    T.eq(v.DIRECTOR.value, "Ramy Youssef"); T.eq(v.NETWORK.value, "Hulu")
    T.eq(v.IMDB_RATING.value, 8.5); T.eq(v.ROTTEN_TOMATOES.value, 99); T.eq(v.METACRITIC.value, 88)
    T.eq(v.IMDB_URL.value, "https://www.imdb.com/title/tt14452776/"); T.eq(v.TAGLINE.value, "")
    T.eq(#v.OVERVIEW.value, 1000 + #"…"); T.eq(v.YEAR.value, 2022); T.eq(v.LAST_CHANGED.value, 1790000000)
    T.eq(v.ARTWORK_URL.value, "https://img/p.jpg"); T.eq(v.VERSION.value, 7)
  end)
  it("handles an empty/initial state", function()
    local v = vars({ playback = { state = "idle" }, media = { kind = "unknown" }, source = {} })
    T.eq(v.TITLE.value, ""); T.eq(v.SEASON.value, 0); T.eq(v.DISPLAY_LINE_1.value, "Nothing playing")
    T.eq(v.DISPLAY_LINE_2.value, ""); T.eq(v.IS_LIVE.value, false); T.eq(v.PROGRESS_PERCENT.value, 0)
    v = vars({})
    T.eq(v.PLAY_STATE.value, "idle")
  end)
  it("display lines for music, movie, live, untitled app, off", function()
    local l1, l2 = flatten.display_lines({ source = { app_name = "Spotify", device_name = "Kitchen" },
      playback = { state = "playing" }, media = { kind = "music", title = "Blinding Lights", artist = "The Weeknd", album = "After Hours" },
      details = { music = { album_year = 2020 } } })
    T.eq(l1, "Blinding Lights — The Weeknd"); T.eq(l2, "After Hours · 2020 · Spotify on Kitchen")
    l1 = flatten.display_lines({ source = {}, playback = { state = "playing" }, media = { kind = "movie", title = "Top Gun: Maverick [4K]", year = 2022 } })
    T.eq(l1, "Top Gun: Maverick (2022)")
    l1, l2 = flatten.display_lines({ source = { app_name = "Antenna TV", device_name = "LR" }, playback = { state = "playing" },
      media = { kind = "live_tv", title = "World News", channel_number = "7.1", channel_name = "WJLA-HD" } })
    T.eq(l1, "World News"); T.eq(l2, "7.1 WJLA-HD · Antenna TV on LR")
    l1, l2 = flatten.display_lines({ source = { app_name = "Netflix", device_name = "Living Room Roku" },
      playback = { state = "playing" }, media = { kind = "video" } })
    T.eq(l1, "Netflix"); T.eq(l2, "Living Room Roku")
    l1 = flatten.display_lines({ source = {}, playback = { state = "off" }, media = {} })
    T.eq(l1, "Off")
  end)
  it("live progress is 0 and position not clamped to duration", function()
    local v = vars({ playback = { state = "playing", is_live = true, position_s = 100, duration_s = 50, position_updated_at = 0 },
      media = { kind = "live_tv" }, source = {} }, 10)
    T.eq(v.PROGRESS_PERCENT.value, 0); T.eq(v.POSITION_SECONDS.value, 110); T.eq(v.IS_LIVE.value, true)
  end)
end)
