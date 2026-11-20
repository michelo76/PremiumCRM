-- The SmartBuildOS Apple TV Native driver as a now-playing source (c4/appletv.lua): the pure
-- snapshot mapping, then the watcher and the whole driver against a fake Apple TV driver device
-- whose NOW_PLAYING_* variables are registered dynamically (c4_mock dyn_device).
local T = ...
local AppleTV = require("c4.appletv")
local Config = require("c4.config")
local Deps = require("c4.deps")
local Mock = require("c4_mock")
local json = require("np.json")

local DRIVER = T.root .. "/driver"
local ROOM = 100
local ATV, MP, APPS, SWITCHER = 300, 301, 302, 303 -- main device + its three proxies
local ATV2 = 400
local C4Z = AppleTV.C4Z
local NOW = 1790000000

local function P(t, now) return AppleTV.to_playback(t, { device_name = "Den", now = now or NOW }) end

---------------------------------------------------------------------------
-- pure mapping
---------------------------------------------------------------------------

describe("c4.appletv.to_playback (pure)", function()
  local states = {
    { "Playing", "playing" }, { "Paused", "paused" }, { "Stopped", "stopped" }, { "Seeking", "buffering" },
    { "Interrupted", "paused" }, { "Unknown", "idle" }, { "playing", "playing" }, { "Loading", "idle" },
  }
  for _, c in ipairs(states) do
    it("state " .. c[1] .. " -> " .. c[2], function()
      local pb = P({ VALID = "1", PLAY_STATE = c[1], TITLE = "X" })
      T.eq(pb.playback.state, c[2])
      T.eq(pb.media.title, "X")
      T.eq(pb.source.provider, "appletv")
      T.eq(pb.source.device_name, "Den")
    end)
  end

  it("VALID=0 -> idle, all media, app and artwork cleared", function()
    local pb = P({ VALID = "0", PLAY_STATE = "Playing", TITLE = "Stale", ARTIST = "A", APP_NAME = "Music",
      ARTWORK_URL = "https://x/a.jpg", POSITION = "12", DURATION = "200", UPDATED_AT = "0" })
    T.eq(pb.playback.state, "idle")
    T.deep_eq(pb.media, { kind = "unknown", genres = {} })
    T.is_nil(pb.source.app_name); T.is_nil(pb.playback.position_s); T.is_nil(pb.playback.duration_s)
    T.eq(pb.source.provider, "appletv")
  end)
  it("VALID=1 with an empty PLAY_STATE -> idle, cleared", function()
    local pb = P({ VALID = "1", PLAY_STATE = "", TITLE = "T" })
    T.eq(pb.playback.state, "idle"); T.is_nil(pb.media.title)
  end)
  it("an empty snapshot (every field \"\") -> idle, nothing", function()
    local pb = P({ VALID = "", PLAY_STATE = "", TITLE = "", POSITION = "", DURATION = "", UPDATED_AT = "" })
    T.eq(pb.playback.state, "idle"); T.eq(pb.media.kind, "unknown"); T.is_nil(pb.media.title)
    T.is_nil(AppleTV.to_playback(nil).media.title)
  end)
  it("VALID=1 without a title is a valid, title-less session", function()
    local pb = P({ VALID = "1", PLAY_STATE = "Playing", APP_NAME = "Netflix", APP_ID = "com.netflix.Netflix" })
    T.eq(pb.playback.state, "playing"); T.is_nil(pb.media.title); T.eq(pb.media.kind, "unknown")
    T.eq(pb.source.app_name, "Netflix"); T.eq(pb.source.app_id, "com.netflix.Netflix")
  end)

  it("episode: series + season/episode numbers, episode_title = title, subtitle", function()
    local pb = P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Forks", SERIES = "The Bear", SEASON = "2",
      EPISODE = "7", POSITION = "120.5", DURATION = "2400", UPDATED_AT = tostring(NOW - 3) })
    T.eq(pb.media.kind, "episode"); T.eq(pb.media.series_title, "The Bear")
    T.eq(pb.media.season, 2); T.eq(pb.media.episode, 7); T.eq(pb.media.episode_title, "Forks")
    T.eq(pb.media.subtitle, "The Bear · S2E7")
    T.eq(pb.playback.position_s, 120.5); T.eq(pb.playback.duration_s, 2400)
    T.eq(pb.playback.position_updated_at, NOW - 3); T.eq(pb.playback.is_live, false)
  end)
  it("episode from season/episode alone (no series)", function()
    local pb = P({ VALID = "1", PLAY_STATE = "Paused", TITLE = "Pilot", EPISODE = "1" })
    T.eq(pb.media.kind, "episode"); T.eq(pb.media.episode, 1); T.is_nil(pb.media.season)
    T.eq(pb.media.subtitle, "E1")
  end)
  it("season 0 (specials) is a number; non-numeric season/episode -> nil", function()
    local pb = P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Special", SERIES = "S", SEASON = "0", EPISODE = "3" })
    T.eq(pb.media.season, 0); T.eq(pb.media.episode, 3)
    pb = P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "T", SERIES = "Show", SEASON = "S2", EPISODE = "seven" })
    T.is_nil(pb.media.season); T.is_nil(pb.media.episode); T.eq(pb.media.kind, "episode")
    pb = P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "T", SEASON = "2a", EPISODE = "2.5" })
    T.is_nil(pb.media.season); T.is_nil(pb.media.episode); T.eq(pb.media.kind, "video")
    T.eq(P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "T", SEASON = "02", EPISODE = "4.0" }).media.season, 2)
  end)
  it("music: artist or album", function()
    local pb = P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Blinding Lights", ARTIST = "The Weeknd",
      ALBUM = "After Hours", DURATION = "200" })
    T.eq(pb.media.kind, "music"); T.eq(pb.media.artist, "The Weeknd"); T.eq(pb.media.album, "After Hours")
    T.eq(pb.media.subtitle, "The Weeknd"); T.is_nil(pb.media.episode_title)
    T.eq(P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "x", ALBUM = "Only Album" }).media.kind, "music")
  end)
  it("movie: no series/music fields and duration > 60 min; exactly 60 min is video", function()
    T.eq(P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Top Gun", DURATION = "7800" }).media.kind, "movie")
    T.eq(P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Doc", DURATION = "3600" }).media.kind, "video")
  end)
  it("video: a title only; unknown: nothing", function()
    T.eq(P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Clip", DURATION = "300" }).media.kind, "video")
    T.eq(P({ VALID = "1", PLAY_STATE = "Playing" }).media.kind, "unknown")
  end)
  it("duration \"0\" / \"\" -> nil (and a title-only session then looks live, like the bridge)", function()
    local pb = P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Stream", POSITION = "0", DURATION = "0", UPDATED_AT = "0" })
    T.is_nil(pb.playback.duration_s); T.is_nil(pb.playback.position_s)
    T.is_nil(pb.playback.position_updated_at, "UPDATED_AT 0 -> nil")
    T.eq(pb.playback.is_live, true); T.eq(pb.media.kind, "video")
    pb = P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Clip", POSITION = "0", DURATION = "" })
    T.is_nil(pb.playback.duration_s)
    pb = P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Clip", POSITION = "0", DURATION = "90" })
    T.eq(pb.playback.position_s, 0, "position 0 with a known duration is the start")
    T.eq(P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "C", POSITION = "abc", DURATION = "-5" }).playback.duration_s, nil)
  end)
  it("artwork: https only (http / data / junk rejected)", function()
    local function art(u) return P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "T", ARTWORK_URL = u }).media.artwork_url end
    T.eq(art("https://is1-ssl.mzstatic.com/a/600x600bb.jpg"), "https://is1-ssl.mzstatic.com/a/600x600bb.jpg")
    T.is_nil(art("http://192.168.1.20/art.jpg")); T.is_nil(art("data:image/png;base64,AAAA"))
    T.is_nil(art("")); T.is_nil(art("not a url"))
  end)
  it("whitespace-only fields are empty", function()
    local pb = P({ VALID = " 1 ", PLAY_STATE = " Playing ", TITLE = "  ", ARTIST = " A " })
    T.eq(pb.playback.state, "playing"); T.is_nil(pb.media.title); T.eq(pb.media.artist, "A")
  end)
  it("app name: the display name, a bundle-id fallback mapped when known, else kept", function()
    T.eq(AppleTV.app_name("Netflix", "com.netflix.Netflix"), "Netflix")
    T.eq(AppleTV.app_name("com.netflix.Netflix", "com.netflix.Netflix"), "Netflix")
    T.eq(AppleTV.app_name("", "com.apple.TVWatchList"), "TV")
    T.eq(AppleTV.app_name("com.example.someapp", "com.example.someapp"), "com.example.someapp")
    T.is_nil(AppleTV.app_name("", ""))
  end)
  it("survives np.playback.normalize unchanged (static provider path)", function()
    local Playback = require("np.playback")
    local pb = P({ VALID = "1", PLAY_STATE = "Playing", TITLE = "Forks", SERIES = "The Bear", SEASON = "2",
      EPISODE = "7", DURATION = "2400", POSITION = "10", UPDATED_AT = tostring(NOW),
      ARTWORK_URL = "https://img.example.com/a.jpg" })
    local n = Playback.normalize(pb, NOW, { provider = "appletv" })
    T.eq(n.media.kind, "episode"); T.eq(n.media.season, 2); T.eq(n.media.artwork_url, "https://img.example.com/a.jpg")
    T.eq(n.playback.position_updated_at, NOW)
  end)
end)

describe("c4.appletv helpers (pure)", function()
  it("var_map accepts every GetDeviceVariables shape", function()
    T.deep_eq(AppleTV.var_map({ [1001] = { name = "NOW_PLAYING_REVISION", value = "3" }, ["1002"] = { name = "X", value = "" } }),
      { NOW_PLAYING_REVISION = 1001, X = 1002 })
    T.deep_eq(AppleTV.var_map({ { id = 7, name = "NOW_PLAYING_TITLE" } }), { NOW_PLAYING_TITLE = 7 })
    T.deep_eq(AppleTV.var_map({ NOW_PLAYING_TITLE = { id = "9", value = "x" } }), { NOW_PLAYING_TITLE = 9 })
    T.deep_eq(AppleTV.var_map({ NOW_PLAYING_TITLE = { value = "x" }, NOW_PLAYING_VALID = "1" }),
      { NOW_PLAYING_TITLE = true, NOW_PLAYING_VALID = true })
    T.deep_eq(AppleTV.var_map(nil), {}); T.deep_eq(AppleTV.var_map("x"), {})
  end)
  it("value_in reads a value by name in any shape", function()
    T.eq(AppleTV.value_in({ [5] = { name = "A", value = 42 } }, "A"), "42")
    T.eq(AppleTV.value_in({ A = { value = "v" } }, "A"), "v")
    T.eq(AppleTV.value_in({ A = "w" }, "A"), "w")
    T.eq(AppleTV.value_in({ [5] = { name = "A" } }, "A"), "")
    T.is_nil(AppleTV.value_in({ B = "x" }, "A"))
  end)
  it("ids: GetDevicesByC4iName-style tables, strings, numbers", function()
    T.deep_eq(AppleTV.ids({ [300] = "Apple TV", [12] = "Other" }), { 12, 300 })
    T.deep_eq(AppleTV.ids({ 300, "400" }), { 300, 400 })
    T.deep_eq(AppleTV.ids("300, 400"), { 300, 400 })
    T.deep_eq(AppleTV.ids(7), { 7 }); T.deep_eq(AppleTV.ids(nil), {})
  end)
  it("plausible: VALID 0/1/\"\", UPDATED_AT numeric/\"\"", function()
    T.ok(AppleTV.plausible({ VALID = "1", UPDATED_AT = "1790000000" }))
    T.ok(AppleTV.plausible({ VALID = "", UPDATED_AT = "" }))
    T.no(AppleTV.plausible({ VALID = "Top Gun", UPDATED_AT = "1" }))
    T.no(AppleTV.plausible({ VALID = "1", UPDATED_AT = "Playing" }))
  end)
  it("Config.device_id parses selector / manual ids", function()
    T.eq(Config.device_id("300"), 300); T.eq(Config.device_id(" 300 "), 300); T.eq(Config.device_id("300,301"), 300)
    T.is_nil(Config.device_id("")); T.is_nil(Config.device_id("abc")); T.is_nil(Config.device_id("0"))
    T.is_nil(Config.device_id("-3")); T.is_nil(Config.device_id("1.5"))
  end)
end)

---------------------------------------------------------------------------
-- fake SmartBuildOS Apple TV driver
---------------------------------------------------------------------------

local function names()
  local out = {}
  for _, f in ipairs(AppleTV.FIELDS) do out[#out + 1] = "NOW_PLAYING_" .. f end
  out[#out + 1] = "NOW_PLAYING_REVISION"
  return out
end

-- a cleared contract plus some unrelated variables of the real driver (ids interleave)
local function cleared(extra)
  local v = { PLAYBACK_POSITION = "0", POWER_STATE = "On", CURRENT_APP = "", NOW_PLAYING_CHANGED = "" }
  for _, n in ipairs(names()) do v[n] = "" end
  v.NOW_PLAYING_POSITION, v.NOW_PLAYING_DURATION, v.NOW_PLAYING_UPDATED_AT = "0", "0", "0"
  v.NOW_PLAYING_VALID, v.NOW_PLAYING_REVISION = "0", "0"
  for k, x in pairs(extra or {}) do v[k] = x end
  return v
end

-- the Apple TV driver: main device + Media Player / Apps & Search / App Switcher proxies
local function add_atv(m, id, name, opts)
  opts = opts or {}
  m:dyn_device(id or ATV, name or "Den Apple TV", opts.values or cleared(), { c4i = C4Z, base = opts.base or 1001 })
  if not opts.no_proxies then
    local base = id or ATV
    m:proxy_device(base + 1, (name or "Den Apple TV"), base, "media_player.c4i")
    m:proxy_device(base + 2, "Apple TV Apps & Search", base, "media_service.c4i")
    m:proxy_device(base + 3, "App Switcher", base, "avswitch.c4i")
  end
end

-- what the Apple TV driver does on every snapshot: all fields, VALID, UPDATED_AT, then REVISION
local ORDER = names()
local function publish(m, dev, t, opts)
  opts = opts or {}
  local d = m.devices[dev]
  local rev = tonumber(d.vars[d.var_ids.NOW_PLAYING_REVISION]) or 0
  local vals = {}
  for _, f in ipairs(AppleTV.FIELDS) do vals["NOW_PLAYING_" .. f] = t[f] or "" end
  if t.POSITION == nil then vals.NOW_PLAYING_POSITION = "0" end
  if t.DURATION == nil then vals.NOW_PLAYING_DURATION = "0" end
  vals.NOW_PLAYING_VALID = t.VALID or "1"
  vals.NOW_PLAYING_UPDATED_AT = t.UPDATED_AT or (vals.NOW_PLAYING_VALID == "1" and tostring(math.floor(m.t)) or "0")
  vals.NOW_PLAYING_REVISION = tostring(opts.rev or (rev + 1))
  m:set_named_many(dev, vals, ORDER)
end

local BEAR = { PLAY_STATE = "Playing", TITLE = "Forks", SERIES = "The Bear", SEASON = "2", EPISODE = "7",
  APP_NAME = "Hulu", APP_ID = "com.hulu.plus", POSITION = "300", DURATION = "2280",
  ARTWORK_URL = "https://img.example.com/bear-s2e7.jpg" }
local MOVIE = { PLAY_STATE = "Playing", TITLE = "Top Gun: Maverick", APP_NAME = "TV", APP_ID = "com.apple.TVWatchList",
  POSITION = "60", DURATION = "7860", ARTWORK_URL = "https://img.example.com/topgun.jpg" }

local function new(props)
  local m = Mock.new({ root = DRIVER, room_id = ROOM })
  m.Properties["Use Control4 Room Media"] = "Off"
  m.Properties["Music Lookup"] = "Off"
  for k, v in pairs(props or {}) do
    assert(m.xml.properties[k], "unknown property " .. k)
    m.Properties[k] = v
  end
  return m
end

local function state_of(m) return json.decode(m.vars.STATE_JSON) end
local function listeners(m) local n = 0; for _ in pairs(m.listeners) do n = n + 1 end; return n end
local function status(m) return m.updated_props["Apple TV Driver Status"] end
local function no_errors(m) T.eq(#m.errors, 0, table.concat(m.errors, "\n")) end

-- driver selecting `sel`, Apple TV already playing `snap`
local function running(sel, snap, props, setup)
  local m = new(props)
  m.Properties["Apple TV Driver"] = sel and tostring(sel) or ""
  add_atv(m)
  if setup then setup(m) end
  m:activate()
  if snap then publish(m, ATV, snap) end
  m:start()
  m:advance(1)
  return m
end

---------------------------------------------------------------------------
-- the driver end to end
---------------------------------------------------------------------------

describe("Apple TV driver source: connecting", function()
  it("connect -> initial read -> state, our variables, STATE_JSON, status", function()
    local m = running(ATV, BEAR)
    no_errors(m)
    T.eq(m.vars.PLAY_STATE, "playing"); T.eq(m.vars.TITLE, "Forks"); T.eq(m.vars.SERIES_TITLE, "The Bear")
    T.eq(m.vars.SEASON, "2"); T.eq(m.vars.EPISODE, "7"); T.eq(m.vars.MEDIA_KIND, "episode")
    T.eq(m.vars.APP_NAME, "Hulu"); T.eq(m.vars.SOURCE_DEVICE, "Den Apple TV"); T.eq(m.vars.SOURCE_PROVIDER, "appletv")
    T.eq(m.vars.DURATION_SECONDS, "2280"); T.eq(m.vars.ARTWORK_URL, "https://img.example.com/bear-s2e7.jpg")
    local st = state_of(m)
    T.eq(st.playback.state, "playing"); T.eq(st.media.title, "Forks"); T.eq(st.source.provider, "appletv")
    T.eq(st.source.app_id, "com.hulu.plus")
    T.contains(status(m), "Connected to Den Apple TV (device 300), revision 1")
    T.contains(m.updated_props["Active Source"], "Apple TV (driver): Den Apple TV (Hulu)")
    T.ok(m.listeners[ATV .. ":" .. m:var_id(ATV, "NOW_PLAYING_REVISION")], "listener on REVISION, resolved by name")
    T.eq(listeners(m), 1)
    T.deep_eq(m.events, {}, "the state found at start is the baseline")
    m:destroy()
  end)

  it("position extrapolates from POSITION + UPDATED_AT (not PLAYBACK_POSITION)", function()
    local m = new({ ["Apple TV Driver"] = tostring(ATV) })
    add_atv(m)
    m:activate()
    publish(m, ATV, { PLAY_STATE = "Playing", TITLE = "Clip", POSITION = "100", DURATION = "600",
      UPDATED_AT = tostring(math.floor(m.t) - 20) })
    m:set_named(ATV, "PLAYBACK_POSITION", "999")
    m:start()
    m:advance(1)
    local p = tonumber(m.vars.POSITION_SECONDS)
    T.ok(p >= 120 and p <= 122, "position " .. tostring(p))
    m:destroy()
  end)

  it("a cleared Apple TV driver (VALID=0) at start -> idle, nothing shown", function()
    local m = running(ATV, nil)
    T.eq(m.vars.PLAY_STATE, "idle"); T.eq(m.vars.TITLE, ""); T.eq(m.vars.SOURCE_PROVIDER, "appletv")
    T.contains(status(m), "nothing playing (VALID=0)")
    no_errors(m)
    m:destroy()
  end)
end)

describe("Apple TV driver source: snapshot updates", function()
  it("a revision bump with a new title -> Media Changed", function()
    local m = running(ATV, BEAR)
    local n = #m.events
    publish(m, ATV, MOVIE)
    m:advance(1)
    T.eq(m.vars.TITLE, "Top Gun: Maverick"); T.eq(m.vars.MEDIA_KIND, "movie"); T.eq(m.vars.APP_NAME, "TV")
    local ev = table.concat(m:events_since(n), ",")
    T.contains(ev, "Media Changed"); T.contains(ev, "App Changed"); T.contains(ev, "Movie Started")
    T.contains(status(m), "revision 2")
    no_errors(m)
    m:destroy()
  end)

  it("same title, position jump (seek) -> new position, no Media Changed", function()
    local m = running(ATV, BEAR)
    local n = #m.events
    local seek = {}
    for k, v in pairs(BEAR) do seek[k] = v end
    seek.POSITION = "1500"
    publish(m, ATV, seek)
    m:advance(1)
    T.eq(m.vars.TITLE, "Forks")
    local p = tonumber(m.vars.POSITION_SECONDS)
    T.ok(p >= 1500 and p < 1505, "position " .. tostring(p))
    T.deep_eq(m:events_since(n), {})
    m:destroy()
  end)

  it("Paused, then VALID=0 -> idle, metadata and artwork cleared", function()
    local m = running(ATV, BEAR)
    local paused = {}
    for k, v in pairs(BEAR) do paused[k] = v end
    paused.PLAY_STATE = "Paused"
    local n = #m.events
    publish(m, ATV, paused)
    m:advance(1)
    T.eq(m.vars.PLAY_STATE, "paused")
    T.deep_eq(m:events_since(n), { "Playback Paused" })
    publish(m, ATV, { VALID = "0", PLAY_STATE = "" })
    m:advance(1)
    T.eq(m.vars.PLAY_STATE, "idle"); T.eq(m.vars.TITLE, ""); T.eq(m.vars.ARTWORK_URL, "")
    local st = state_of(m)
    T.is_nil(st.media.title); T.is_nil(st.media.artwork_url)
    no_errors(m)
    m:destroy()
  end)

  it("an unchanged REVISION notification does not re-read; a stale field write without a revision is ignored", function()
    local m = running(ATV, BEAR)
    local reads = 0
    m.on_get_var = function() reads = reads + 1 end
    m:set_named(ATV, "NOW_PLAYING_REVISION", "1") -- same revision
    m:set_named(ATV, "NOW_PLAYING_TITLE", "Half written") -- not watched: only REVISION triggers
    m:advance(1)
    T.eq(reads, 0)
    T.eq(m.vars.TITLE, "Forks")
    m:destroy()
  end)

  it("torn read (revision changes mid-read) -> retried; a mixed snapshot is never published", function()
    local m = running(ATV, BEAR)
    local n0 = #m.set_log
    -- while the receiver reads the fields of revision 2 (movie), the Apple TV driver writes
    -- revision 3 (an episode) field by field: the first attempt sees the movie's title and
    -- series but the episode's app
    local aid, armed, attempts = m:var_id(ATV, "NOW_PLAYING_APP_NAME"), true, 0
    m.on_get_var = function(_, var)
      if var == aid then attempts = attempts + 1 end
      if armed and var == aid then
        armed = false
        local ep = {}
        for k, v in pairs(BEAR) do ep[k] = v end
        ep.TITLE = "Forks (part 2)"
        publish(m, ATV, ep)
      end
    end
    publish(m, ATV, MOVIE)
    m:advance(1)
    m.on_get_var = nil
    T.ok(attempts >= 2, "read again (" .. attempts .. ")")
    T.eq(m.vars.TITLE, "Forks (part 2)"); T.eq(m.vars.SERIES_TITLE, "The Bear"); T.eq(m.vars.APP_NAME, "Hulu")
    T.contains(status(m), "revision 3")
    -- no published state ever mixed the movie's title with the episode's app
    for i = n0 + 1, #m.set_log do
      local e = m.set_log[i]
      if e.name == "STATE_JSON" then
        local st = json.decode(e.value)
        T.no(st.media.title == "Top Gun: Maverick" and st.source.app_name == "Hulu", "mixed snapshot published")
      end
    end
    no_errors(m)
    m:destroy()
  end)

  it("a revision that never settles is not published and retried later", function()
    local m = running(ATV, BEAR)
    local rid = m:var_id(ATV, "NOW_PLAYING_REVISION")
    local churn = 0
    local tid = m:var_id(ATV, "NOW_PLAYING_TITLE")
    m.on_get_var = function(_, var)
      if var == tid and churn < 3 then
        churn = churn + 1
        local d = m.devices[ATV]
        d.vars[d.var_ids.NOW_PLAYING_TITLE] = "Churn " .. churn
        d.vars[rid] = tostring(10 + churn) -- written without notifying (listener fires later)
      end
    end
    m:set_var(ATV, rid, "10") -- notify revision 10 -> read attempts see 10 -> 11 -> 12 -> 13
    T.eq(m.vars.TITLE, "Forks", "nothing published while torn")
    T.eq(m:pending_timers() > 0, true)
    m.on_get_var = nil
    m:advance(2) -- RETRY_S
    T.eq(m.vars.TITLE, "Churn 3")
    T.contains(status(m), "revision 13")
    no_errors(m)
    m:destroy()
  end)

  it("revision reset with re-numbered variable ids (Apple TV driver reloaded) -> recovers", function()
    local m = running(ATV, BEAR)
    publish(m, ATV, MOVIE) -- revision 2
    m:advance(1)
    local old_rid = m:var_id(ATV, "NOW_PLAYING_REVISION")
    -- reload: variables deleted and re-added with new ids, listeners on the old ids are gone
    m.listeners = {}
    m:renumber(ATV, 2001)
    local d = m.devices[ATV]
    for _, n in ipairs(names()) do d.vars[d.var_ids[n]] = "" end
    d.vars[d.var_ids.NOW_PLAYING_REVISION] = "0"
    publish(m, ATV, { PLAY_STATE = "Playing", TITLE = "After Reload", APP_NAME = "Plex", DURATION = "1200" })
    T.eq(m.vars.TITLE, "Top Gun: Maverick", "the old listener is gone: nothing yet")
    m:advance(AppleTV.POLL_S + 1) -- safety poll: map rebuilt, listener re-registered, read
    T.eq(m.vars.TITLE, "After Reload")
    T.contains(status(m), "revision 1")
    local new_rid = m:var_id(ATV, "NOW_PLAYING_REVISION")
    T.neq(new_rid, old_rid)
    T.ok(m.listeners[ATV .. ":" .. new_rid]); T.eq(listeners(m), 1)
    -- and live updates flow through the new listener
    publish(m, ATV, BEAR)
    m:advance(1)
    T.eq(m.vars.TITLE, "Forks")
    no_errors(m)
    m:destroy()
  end)

  it("revision goes back (restart, same ids) -> treated as a restart, re-read and re-registered", function()
    local m = running(ATV, BEAR)
    publish(m, ATV, MOVIE) -- 2
    publish(m, ATV, BEAR) -- 3
    m:advance(1)
    local regs = 0
    local orig = m.C4.RegisterVariableListener
    m.C4.RegisterVariableListener = function(...) regs = regs + 1; return orig(...) end
    publish(m, ATV, { PLAY_STATE = "Paused", TITLE = "Fresh" }, { rev = 1 })
    m:advance(1)
    T.eq(m.vars.TITLE, "Fresh"); T.eq(m.vars.PLAY_STATE, "paused")
    T.ok(regs >= 1, "listener re-registered")
    T.contains(status(m), "revision 1")
    T.eq(m.env.NOW_PLAYING_APP.atv.restarts, 1)
    no_errors(m)
    m:destroy()
  end)

  it("a stale name map that reads other variables (implausible VALID) is rebuilt before publishing", function()
    local m = running(ATV, BEAR)
    -- reload that swaps the ids of VALID and TITLE without the revision going back
    local d = m.devices[ATV]
    local vid, tid = d.var_ids.NOW_PLAYING_VALID, d.var_ids.NOW_PLAYING_TITLE
    d.var_ids.NOW_PLAYING_VALID, d.var_ids.NOW_PLAYING_TITLE = tid, vid
    d.vars[vid], d.vars[tid] = d.vars[tid], d.vars[vid]
    publish(m, ATV, MOVIE) -- revision 2, written through the new ids
    m:advance(1)
    T.eq(m.vars.TITLE, "Top Gun: Maverick")
    T.eq(m.vars.PLAY_STATE, "playing")
    no_errors(m)
    m:destroy()
  end)
end)

describe("Apple TV driver source: device resolution", function()
  it("the selector picked the Media Player proxy -> the main device is resolved", function()
    local m = running(MP, BEAR)
    T.eq(m.vars.TITLE, "Forks")
    T.contains(status(m), "(device 300)")
    T.ok(m.listeners[ATV .. ":" .. m:var_id(ATV, "NOW_PLAYING_REVISION")])
    no_errors(m)
    m:destroy()
  end)

  for _, c in ipairs({ { APPS, "Apps & Search" }, { SWITCHER, "App Switcher" } }) do
    it("the " .. c[2] .. " proxy -> the main device", function()
      local m = running(c[1], BEAR)
      T.eq(m.vars.TITLE, "Forks"); T.contains(status(m), "(device 300)")
      m:destroy()
    end)
  end

  it("a proxy, without GetDevices: found through GetDevicesByC4iName + GetProxyDevicesById", function()
    local m = running(MP, BEAR, nil, function(mm) mm.C4.GetDevices = nil end)
    T.eq(m.vars.TITLE, "Forks"); T.contains(status(m), "(device 300)")
    no_errors(m)
    m:destroy()
  end)

  it("a proxy on an OS with none of the optional APIs -> a clear status, no errors", function()
    local m = running(MP, BEAR, nil, function(mm)
      mm.C4.GetDevices, mm.C4.GetDevicesByC4iName, mm.C4.GetProxyDevicesById = nil, nil, nil
    end)
    T.eq(m.vars.TITLE, "")
    T.contains(status(m), "has no NOW_PLAYING_* variables")
    T.contains(status(m), "Device 301")
    no_errors(m)
    m:destroy()
  end)

  it("an Apple TV driver without the contract (older beta) -> clear status, nothing else used", function()
    local m = new({ ["Apple TV Driver"] = tostring(ATV2) })
    add_atv(m) -- a second, current Apple TV driver must NOT be picked instead
    m:dyn_device(ATV2, "Bedroom Apple TV", { PLAYBACK_POSITION = "0", POWER_STATE = "On" }, { c4i = C4Z })
    m:start(); m:advance(1)
    T.contains(status(m), "Bedroom Apple TV")
    T.contains(status(m), "Beta 120")
    T.eq(m.vars.TITLE, ""); T.eq(listeners(m), 0)
    no_errors(m)
    m:action("TestMetadataSources")
    m:advance(1)
    T.contains(m:all_prints(), "FAILED")
    m:destroy()
  end)

  it("a device that is not an Apple TV driver at all, no Apple TV driver installed -> clear status", function()
    local m = new({ ["Apple TV Driver"] = "245" })
    m:device(245, "Sonos Five", { [1000] = "x" })
    m:start(); m:advance(1)
    T.contains(status(m), "Device 245 (Sonos Five) has no NOW_PLAYING_* variables")
    T.eq(m.vars.PLAY_STATE, "off")
    no_errors(m)
    m:destroy()
  end)

  it("a deleted device -> 'not found'", function()
    local m = new({ ["Apple TV Driver"] = "777" })
    m:start(); m:advance(1)
    T.contains(status(m), "Device 777 not found")
    no_errors(m)
    m:destroy()
  end)

  it("manual Apple TV Driver Device ID overrides the selector", function()
    local m = new({ ["Apple TV Driver"] = tostring(MP), ["Apple TV Driver Device ID"] = tostring(ATV2) })
    add_atv(m)
    add_atv(m, ATV2, "Bedroom Apple TV", { base = 5001 })
    m:activate()
    publish(m, ATV, BEAR)
    publish(m, ATV2, MOVIE)
    m:start(); m:advance(1)
    T.eq(m.vars.TITLE, "Top Gun: Maverick"); T.eq(m.vars.SOURCE_DEVICE, "Bedroom Apple TV")
    T.contains(status(m), "(device 400)")
    no_errors(m)
    m:destroy()
  end)

  it("override only (selector empty) works; a non-numeric override is a warning", function()
    local m = new({ ["Apple TV Driver Device ID"] = tostring(ATV) })
    add_atv(m); m:activate(); publish(m, ATV, BEAR)
    m:start(); m:advance(1)
    T.eq(m.vars.TITLE, "Forks")
    m:destroy()
    m = new({ ["Apple TV Driver Device ID"] = "den" })
    m:start(); m:advance(1)
    T.contains(table.concat(m.env.NOW_PLAYING_APP.info.warnings, "|"), "Apple TV Driver Device ID is not a numeric device id")
    T.eq(status(m), "Not configured")
    m:destroy()
  end)

  it("ambiguity: two Apple TV drivers and the selection is neither -> says so, no guessing", function()
    local m = new({ ["Apple TV Driver"] = "245" })
    m:device(245, "Sonos Five", { [1000] = "x" })
    add_atv(m); add_atv(m, ATV2, "Bedroom Apple TV", { base = 5001 })
    m:activate(); publish(m, ATV, BEAR); publish(m, ATV2, MOVIE)
    m:start(); m:advance(1)
    T.contains(status(m), "Ambiguous: 2 Apple TV drivers in the project (devices 300, 400)")
    T.contains(status(m), "Apple TV Driver Device ID")
    T.eq(m.vars.TITLE, ""); T.eq(listeners(m), 0)
    no_errors(m)
    m:destroy()
  end)

  it("two Apple TV drivers and the selection is a proxy of one -> that one", function()
    local m = new({ ["Apple TV Driver"] = tostring(ATV2 + 1) })
    add_atv(m); add_atv(m, ATV2, "Bedroom Apple TV", { base = 5001 })
    m:activate(); publish(m, ATV, BEAR); publish(m, ATV2, MOVIE)
    m:start(); m:advance(1)
    T.eq(m.vars.TITLE, "Top Gun: Maverick"); T.contains(status(m), "(device 400)")
    m:destroy()
  end)

  it("GetDeviceVariables keyed by name (no ids): read from the table, safety poll instead of a listener", function()
    local m = new({ ["Apple TV Driver"] = tostring(ATV) })
    m.gdv_shape = "by_name"
    add_atv(m); m:activate(); publish(m, ATV, BEAR)
    m:start(); m:advance(1)
    T.eq(m.vars.TITLE, "Forks"); T.eq(listeners(m), 0)
    publish(m, ATV, MOVIE)
    m:advance(AppleTV.POLL_S + 1)
    T.eq(m.vars.TITLE, "Top Gun: Maverick")
    no_errors(m)
    m:destroy()
  end)

  it("the Apple TV driver appears later -> picked up by the safety poll", function()
    local m = new({ ["Apple TV Driver"] = tostring(ATV) })
    m:start(); m:advance(1)
    T.contains(status(m), "not found")
    add_atv(m); publish(m, ATV, BEAR)
    m:advance(AppleTV.POLL_S + 1)
    T.eq(m.vars.TITLE, "Forks"); T.contains(status(m), "Connected")
    m:destroy()
  end)

  it("the Apple TV driver is deleted -> status says so, the source goes off", function()
    local m = running(ATV, BEAR)
    m.devices[ATV] = nil; m.devices[MP] = nil; m.devices[APPS] = nil; m.devices[SWITCHER] = nil
    m:advance(AppleTV.POLL_S + 1)
    T.contains(status(m), "not found")
    T.eq(m.vars.PLAY_STATE, "off"); T.eq(m.vars.TITLE, "")
    T.eq(listeners(m), 0)
    no_errors(m)
    m:destroy()
  end)
end)

describe("Apple TV driver source: engine wiring", function()
  it("ordered before the pyatv bridge, which stays as fallback; same HA group", function()
    local p = {}
    for name, d in pairs(Mock.parse_driver_xml(DRIVER .. "/driver.xml").properties) do p[name] = d.default end
    p["Apple TV Driver"] = "300"
    p["Apple TV Bridge URL"] = "http://192.168.1.10:8765"; p["Apple TV Device"] = "Den"
    p["Home Assistant URL"] = "http://ha:8123"; p["Home Assistant Token"] = "t"; p["Home Assistant Entity ID"] = "media_player.x"
    p["Home Assistant Entity Is"] = "Same Device As Apple TV"
    local cfg, info = Config.build(p, { room_id = 1 })
    T.eq(cfg.providers[1].id, "appletv_driver"); T.eq(cfg.providers[1].type, "static")
    T.eq(cfg.providers[1].provider_name, "appletv")
    T.eq(cfg.providers[2].type, "bridge"); T.eq(cfg.providers[3].type, "homeassistant")
    T.eq(cfg.providers[1].group, Config.APPLETV_GROUP); T.eq(cfg.providers[2].group, Config.APPLETV_GROUP)
    T.eq(cfg.providers[3].group, Config.APPLETV_GROUP)
    T.deep_eq(info.appletv_driver, { selected = 300 })
    -- the driver alone also satisfies "Same Device As Apple TV"
    p["Apple TV Bridge URL"] = ""; p["Apple TV Device"] = ""
    cfg, info = Config.build(p, { room_id = 1 })
    T.eq(#info.warnings, 0)
    T.eq(cfg.providers[2].group, Config.APPLETV_GROUP)
    p["Apple TV Driver"] = ""
    cfg, info = Config.build(p, { room_id = 1 })
    T.is_nil(info.appletv_driver)
    T.contains(table.concat(info.warnings, "|"), "no Apple TV is set")
  end)

  it("both playing: the driver source wins (list order); nothing from the driver: the bridge", function()
    local function setup(driver_playing)
      local m = new({ ["Apple TV Driver"] = tostring(ATV), ["Apple TV Bridge URL"] = "http://192.168.1.10:8765",
        ["Apple TV Device"] = "Den" })
      m:route("/now-playing", { status = 200, body = T.fixture("bridge_appletv.json") })
      add_atv(m)
      m:activate()
      if driver_playing then publish(m, ATV, BEAR) end
      m:start(); m:advance(3)
      return m
    end
    local m = setup(true)
    T.eq(m.vars.TITLE, "Forks"); T.contains(m.updated_props["Active Source"], "Apple TV (driver)")
    no_errors(m)
    m:destroy()
    m = setup(false)
    T.eq(m.vars.TITLE, json.decode(T.fixture("bridge_appletv.json")).media.title)
    no_errors(m)
    m:destroy()
  end)

  it("enrichment runs for an Apple TV episode (TMDB)", function()
    local m = new({ ["Apple TV Driver"] = tostring(ATV), ["TMDB API Key"] = "tmdbkey0123456789abcdef" })
    m:route("/search/tv", { status = 200, body = T.fixture("tmdb_search_tv_bear.json") })
    m:route("/tv/136315?", { status = 200, body = T.fixture("tmdb_tv_136315.json") })
    m:route("/tv/136315/season/2/episode/7", { status = 200, body = T.fixture("tmdb_tv_136315_s2e7.json") })
    add_atv(m); m:activate(); publish(m, ATV, BEAR)
    m:start(); m:advance(8)
    T.contains(m:last("/search/tv").url, "query=The%20Bear")
    local st = state_of(m)
    T.ok(st.details, "details attached")
    T.eq(st.details.episode.title, "Forks")
    T.ok(m.vars.OVERVIEW ~= "", "overview")
    no_errors(m)
    m:destroy()
  end)

  it("Show Only When Room Is On: gated while the room is off, back when it is on", function()
    local m = new({ ["Apple TV Driver"] = tostring(ATV), ["Show Only When Room Is On"] = "On" })
    m.devices[ROOM].vars = { [1010] = "0" }
    add_atv(m); m:activate(); publish(m, ATV, BEAR)
    m:start(); m:advance(1)
    T.eq(m.vars.PLAY_STATE, "off")
    m:set_var(ROOM, 1010, "1")
    m:advance(2)
    T.eq(m.vars.TITLE, "Forks")
    no_errors(m)
    m:destroy()
  end)
end)

describe("Apple TV driver source: actions, routing, lifecycle", function()
  it("Refresh / Refresh Now force an immediate re-read even when REVISION is unchanged", function()
    local m = running(ATV, BEAR)
    local reads = 0
    m.on_get_var = function(dev) if dev == ATV then reads = reads + 1 end end
    -- a field changed without a revision bump (e.g. a missed notification): Refresh re-reads
    m:call("ExecuteCommand", "Refresh", {})
    T.ok(reads >= #AppleTV.FIELDS + 2, "re-read on Refresh (" .. reads .. ")")
    reads = 0
    m:action("RefreshNow")
    T.ok(reads >= #AppleTV.FIELDS + 2, "re-read on Refresh Now")
    T.ok(m:printed("refresh requested"))
    -- and a revision written without a notification is picked up by Refresh
    local d = m.devices[ATV]
    d.vars[d.var_ids.NOW_PLAYING_TITLE] = "Silent"
    d.vars[d.var_ids.NOW_PLAYING_REVISION] = "2"
    m:call("ExecuteCommand", "Refresh", {})
    m:advance(1)
    T.eq(m.vars.TITLE, "Silent")
    no_errors(m)
    m:destroy()
  end)

  it("Test Metadata Sources reports the resolved device, variables by name, revision, VALID", function()
    local m = running(MP, BEAR)
    m.prints = {}
    m:action("TestMetadataSources")
    m:advance(1)
    local out = m:all_prints()
    T.contains(out, "Apple TV driver (SmartBuildOS)  OK - device 300 (Den Apple TV), main device of 301")
    T.contains(out, "variables found: 15/15 (all)")
    T.contains(out, "listening on NOW_PLAYING_REVISION (variable " .. m:var_id(ATV, "NOW_PLAYING_REVISION") .. ")")
    T.contains(out, "revision 1, VALID=1, state Playing, title \"Forks\", app Hulu")
    T.contains(out, "done, 0 problem(s)")
    m:destroy()
  end)

  it("Test Metadata Sources names missing variables", function()
    local vals = cleared()
    vals.NOW_PLAYING_ARTWORK_URL, vals.NOW_PLAYING_APP_ID = nil, nil
    local m = new({ ["Apple TV Driver"] = tostring(ATV) })
    add_atv(m, ATV, nil, { values = vals })
    m:start(); m:advance(1)
    m.prints = {}
    m:action("TestMetadataSources")
    m:advance(1)
    local out = m:all_prints()
    T.contains(out, "INCOMPLETE")
    T.contains(out, "variables found: 13/15 (missing: NOW_PLAYING_APP_ID, NOW_PLAYING_ARTWORK_URL)")
    T.contains(out, "done, 1 problem(s)")
    no_errors(m)
    m:destroy()
  end)

  it("Test Metadata Sources on an unresolved device lists the installed Apple TV drivers", function()
    local m = new({ ["Apple TV Driver"] = "245" })
    m:device(245, "Sonos Five", { [1000] = "x" })
    add_atv(m); add_atv(m, ATV2, "Bedroom Apple TV", { base = 5001 })
    m:start(); m:advance(1)
    m.prints = {}
    m:action("TestMetadataSources")
    m:advance(1)
    local out = m:all_prints()
    T.contains(out, "FAILED - Ambiguous")
    T.contains(out, "smartbuildos_appletv_native.c4z devices in the project: 300 (Den Apple TV), 400 (Bedroom Apple TV)")
    m:destroy()
  end)

  it("OnWatchedVariableChanged is routed to the room watcher and the Apple TV watcher", function()
    local m = running(ATV, BEAR, { ["Use Control4 Room Media"] = "On" }, function(mm)
      mm.devices[ROOM].vars = { [1010] = "1" }
    end)
    T.ok(m.listeners[ROOM .. ":1031"]); T.eq(listeners(m), 6, "5 room + 1 Apple TV")
    publish(m, ATV, MOVIE)
    m:advance(1)
    T.eq(m.vars.TITLE, "Top Gun: Maverick")
    m:set_var(ROOM, 1031, "<m><TITLE>Room Song</TITLE><ARTIST>X</ARTIST></m>")
    m:advance(1)
    T.eq(m.vars.TITLE, "Top Gun: Maverick", "the playing Apple TV outranks room media")
    T.ok(m.env.NOW_PLAYING_APP.room.snap[1031]:find("Room Song"), "room watcher got its variable")
    -- an unrelated watched callback is ignored by both
    m:call("OnWatchedVariableChanged", 999, 1, "x")
    no_errors(m)
    m:destroy()
  end)

  it("reconfiguration xN and destroy leave timer and listener counts flat", function()
    local m = running(ATV, BEAR)
    m:advance(61) -- past the one-shot URL announcements
    local timers, ls = m:pending_timers(), listeners(m)
    for i = 1, 5 do
      m:prop("Apple TV Name", "Den " .. i)
      m:advance(1)
      m:prop("Apple TV Driver", tostring(i % 2 == 0 and ATV or MP))
      m:advance(1)
      m:prop("Apple TV Driver Device ID", i % 2 == 0 and "" or tostring(ATV))
      m:advance(1)
      T.eq(m:pending_timers(), timers, "timers after reconfig " .. i)
      T.eq(listeners(m), ls, "listeners after reconfig " .. i)
    end
    T.eq(m.vars.SOURCE_DEVICE, "Den 5", "Apple TV Name overrides the device name")
    m:prop("Apple TV Driver", "")
    m:prop("Apple TV Driver Device ID", "")
    m:advance(1)
    T.eq(listeners(m), 0)
    T.eq(status(m), "Not configured")
    m:prop("Apple TV Driver", tostring(ATV))
    m:advance(1)
    T.eq(listeners(m), 1)
    m:destroy()
    T.eq(listeners(m), 0, "destroy unregisters")
    T.eq(m:pending_timers(), 0, "destroy cancels every timer")
    no_errors(m)
  end)
end)

describe("c4.appletv watcher (C4 mock, no driver)", function()
  local function watcher(m)
    m:activate()
    m.phase = "running"
    local deps = Deps.new(m.C4, { debug_mode = function() return "Off" end })
    local changes = 0
    local w = AppleTV.new(m.C4, deps, function() changes = changes + 1 end)
    m.env = { OnWatchedVariableChanged = function(d, v, val) return w:on_variable(d, v, val) end }
    return w, function() return changes end
  end

  it("configure is idempotent; stop is clean; on_variable ignores foreign variables", function()
    local m = new()
    add_atv(m); m:activate(); publish(m, ATV, BEAR)
    local w, changes = watcher(m)
    w:configure({ selected = ATV })
    T.eq(w:playback().media.title, "Forks")
    local c = changes()
    w:configure({ selected = ATV })
    T.eq(changes(), c, "same selection: nothing happens")
    T.eq(listeners(m), 1); T.eq(m:pending_timers(), 1)
    T.no(w:on_variable(ATV, 1, "x")); T.no(w:on_variable(5, m:var_id(ATV, "NOW_PLAYING_REVISION"), "1"))
    w:configure({ selected = ATV, name = "Den" })
    T.eq(w:playback().source.device_name, "Den")
    w:stop()
    T.eq(listeners(m), 0); T.eq(m:pending_timers(), 0)
    T.eq(w:playback().playback.state, "off"); T.eq(w:status_text(), "Not configured")
    w:configure(nil)
    T.eq(listeners(m), 0)
    m:deactivate()
  end)

  it("a C4 API that throws is contained (status, no error)", function()
    local m = new()
    add_atv(m)
    local w = watcher(m)
    m.C4.GetDeviceVariables = function() error("boom") end
    w:configure({ selected = ATV })
    T.contains(w:status_text(), "no NOW_PLAYING_* variables")
    T.eq(w:playback().playback.state, "off")
    w:stop()
    m:deactivate()
  end)
end)
