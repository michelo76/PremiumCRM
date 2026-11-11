-- End-to-end: the real driver.lua (+ c4/*, np/*) against the C4 mock.
local T = ...
local Mock = require("c4_mock")
local Vars = require("c4.variables")
local json = require("np.json")
local b64 = require("c4.b64")
local Status = require("c4.status")

local DRIVER = T.root .. "/driver"
local ROOM = 100

local function new(props, opts)
  local m = Mock.new({ root = DRIVER, room_id = ROOM, echo = opts and opts.echo })
  for k, v in pairs(props or {}) do
    assert(m.xml.properties[k], "unknown property " .. k)
    m.Properties[k] = v
  end
  return m
end

local function ha_body(state, attrs)
  local d = json.decode(T.fixture("ha_movie_title.json"))
  d.state = state or d.state
  for k, v in pairs(attrs or {}) do d.attributes[k] = v end
  return json.encode(d)
end

local function roku_routes(m, player)
  m:route("/query/device-info", { status = 200, body = T.fixture("roku_device_info.xml") })
  m:route("/query/active-app", { status = 200, body = T.fixture("roku_active_app_netflix.xml") })
  m:route("/query/media-player", { status = 200, body = T.fixture(player or "roku_media_player_play.xml") })
end

local function tmdb_routes(m)
  m:route("/search/movie", { status = 200, body = T.fixture("tmdb_search_movie_topgun.json") })
  m:route("/movie/361743", { status = 200, body = T.fixture("tmdb_movie_361743.json") })
end

local ROKU_HA = {
  ["Roku Address"] = "192.168.1.50", ["Roku Name"] = "Living Room Roku",
  ["Home Assistant URL"] = "http://192.168.1.2:8123", ["Home Assistant Token"] = "ha-long-lived-token-xyz",
  ["Home Assistant Entity ID"] = "media_player.living_room_roku", ["Home Assistant Entity Is"] = "Same Device As Roku",
  ["TMDB API Key"] = "tmdbkey0123456789abcdef", ["Use Control4 Room Media"] = "Off",
}

local function state_of(m)
  local s = m.vars.STATE_JSON
  return json.decode(s)
end

local function last_ui(m)
  local d = m.data_to_ui[#m.data_to_ui]
  return d and json.decode(d.params.state), d
end

describe("driver lifecycle", function()
  it("OnDriverInit adds every variable in the fixed order and calls nothing forbidden", function()
    local m = new()
    m:load(); m:init()
    T.eq(#m.violations, 0, "violations: " .. table.concat(m.violations, ","))
    T.eq(#m.added_vars, #Vars.LIST)
    for i, d in ipairs(Vars.LIST) do
      T.eq(m.added_vars[i].name, d[1]); T.eq(m.added_vars[i].type, d[2]); T.eq(m.added_vars[i].phase, "init")
    end
    T.eq(m.added_vars[#m.added_vars].name, "STATE_JSON")
    T.eq(#m.set_log, 0); T.eq(m:pending_timers(), 0); T.eq(#m.requests, 0); T.eq(#m.errors, 0)
    m:destroy()
  end)
  it("the mock enforces the OnDriverInit restrictions", function()
    local m = new()
    m.phase = "init"
    local ok = pcall(function() m.C4:SetTimer(10, function() end) end)
    T.no(ok); T.eq(m.violations[1], "SetTimer")
    m:deactivate()
  end)
  it("variable IDs are stable across driver restarts", function()
    local a, b = new(), new()
    a:load(); a:init(); b:load(); b:init()
    for i = 1, #a.added_vars do T.eq(a.added_vars[i].name, b.added_vars[i].name) end
    a:deactivate(); b:deactivate()
  end)
  it("OnDriverLateInit starts the engine, publishes STATE_JSON, sends URL_CHANGED after ~3 s", function()
    local m = new():start()
    T.eq(#m.errors, 0, table.concat(m.errors, "\n"))
    T.eq(m.updated_props["Driver Version"]:match("^%d+%.%d+%.%d+"), "1.0.0")
    T.eq(m.updated_props["Web View URL"], "controller://driver/now_playing_info/index.html")
    T.eq(m.updated_props["LAN URL"], "Disabled")
    local st = state_of(m)
    T.eq(st.schema, 1); T.eq(st.sent_at, m.t)
    T.eq(#m:proxy_cmds("URL_CHANGED"), 0)
    m:advance(2.9)
    T.eq(#m:proxy_cmds("URL_CHANGED"), 0)
    m:advance(0.2)
    local u = m:proxy_cmds("URL_CHANGED")
    T.eq(#u, 1); T.eq(u[1].id, 5001); T.eq(u[1].params.url, "controller://driver/now_playing_info/index.html")
    T.ok(m.listeners[ROOM .. ":1031"], "room media watched by default")
    T.eq(st.room.name, "Living Room")
    m:destroy()
  end)
  it("nothing configured: clear Status, no polling, no requests", function()
    local m = new({ ["Use Control4 Room Media"] = "Off" }):start()
    m:advance(60)
    T.eq(#m.requests, 0)
    T.eq(m.updated_props["Status"], Status.NOT_CONFIGURED)
    T.no(m.listeners[ROOM .. ":1031"])
    m:destroy()
  end)
  it("OnDriverDestroyed stops everything (timers, listeners, server, requests)", function()
    local m = new(ROKU_HA)
    m.Properties["LAN Web Port"] = "8080"
    m.Properties["Use Control4 Room Media"] = "On"
    roku_routes(m)
    m:route("/api/states/", { status = 200, body = ha_body() })
    m:start()
    m:advance(10)
    T.ok(m.server)
    m:call("OnDriverDestroyed", 0)
    T.eq(m:pending_timers(), 0)
    T.is_nil(m.server)
    T.is_nil(next(m.listeners))
    local n = #m.requests
    m:advance(60)
    T.eq(#m.requests, n)
    m:deactivate()
  end)
  it("entry points before LateInit / with junk never throw", function()
    local m = new()
    m:load()
    m:call("OnPropertyChanged", "Roku Address")
    m:call("OnWatchedVariableChanged", 1, 2, "x")
    m:call("ExecuteCommand", "GET_STATE", nil)
    T.eq(m:call("UIRequest", "GET_STATE", {}), "")
    m:init(); m:late_init()
    m:call("ExecuteCommand", nil, "junk")
    m:call("OnServerDataIn", 7, "GET / HTTP/1.1\r\n\r\n")
    m:call("ReceivedFromProxy", 5001, "SELECT", {})
    T.eq(#m.errors, 0, table.concat(m.errors, "\n"))
    m:destroy()
  end)
end)

describe("driver with Roku + Home Assistant (same device)", function()
  local function setup()
    local m = new(ROKU_HA)
    roku_routes(m)
    m:route("/api/states/", function() return { status = 200, body = m.ha_body or ha_body() } end)
    tmdb_routes(m)
    m:start()
    return m
  end

  it("publishes variables, STATE_JSON, DataToUI, events and the playing icon", function()
    local m = setup()
    m:advance(1)
    T.eq(#m.errors, 0, table.concat(m.errors, "\n"))
    T.eq(m.vars.TITLE, "Top Gun: Maverick")
    T.eq(m.vars.APP_NAME, "Netflix")
    T.eq(m.vars.SOURCE_DEVICE, "Living Room Roku")
    T.eq(m.vars.SOURCE_PROVIDER, "roku")
    T.eq(m.vars.PLAY_STATE, "playing")
    T.eq(m.vars.IS_PLAYING, "1"); T.eq(m.vars.IS_PAUSED, "0")
    T.eq(m.vars.MEDIA_KIND, "movie")
    local st = state_of(m)
    T.eq(st.media.title, "Top Gun: Maverick"); T.ok(st.sent_at <= m.t and st.sent_at >= m.t - 1)
    local ui = last_ui(m)
    T.eq(ui.version, st.version); T.eq(m.data_to_ui[#m.data_to_ui].cmd, "NOW_PLAYING")
    T.deep_eq(m:events_since(0), { "Source Changed", "App Changed", "Media Changed", "Playback Started", "Movie Started" })
    local icons = m:proxy_cmds("ICON_CHANGED")
    T.eq(#icons, 1); T.eq(icons[1].params.icon, "playing")
    T.contains(m.updated_props["Status"], "Playing — Top Gun: Maverick")
    T.contains(m.updated_props["Active Source"], "Roku")
    T.eq(m.updated_props["Metadata Sources"], "TMDB, Music (iTunes/MusicBrainz)")

    -- enrichment (debounced 1.5 s) -> Details Available
    local n = #m.events
    m:advance(3)
    T.deep_eq(m:events_since(n), { "Details Available" })
    T.ok(m.vars.OVERVIEW ~= "")
    T.ok(state_of(m).details ~= nil)
    T.no(m.vars.STATE_JSON:find("tmdbkey0123456789abcdef", 1, true))

    -- pause
    n = #m.events
    roku_routes(m, "roku_media_player_pause.xml")
    m.ha_body = ha_body("paused")
    m:advance(3)
    T.deep_eq(m:events_since(n), { "Playback Paused" })
    T.eq(m.vars.PLAY_STATE, "paused")
    T.eq(m:proxy_cmds("ICON_CHANGED")[2].params.icon, "")
    m:destroy()
  end)

  it("only changed variables are written; STATE_JSON only on version change", function()
    local m = setup()
    m:advance(5)
    local version = m.vars.VERSION
    local writes = #m.set_log
    m:advance(1.9) -- one more identical poll
    local json_writes = 0
    for i = writes + 1, #m.set_log do
      T.ok(m.set_log[i].name == "POSITION_SECONDS" or m.set_log[i].name == "PROGRESS_PERCENT",
        "unexpected write " .. m.set_log[i].name)
      if m.set_log[i].name == "STATE_JSON" then json_writes = json_writes + 1 end
    end
    T.eq(m.vars.VERSION, version); T.eq(json_writes, 0)
    m:destroy()
  end)

  it("keeps POSITION_SECONDS fresh every 5 s while playing (between polls)", function()
    local m = new(ROKU_HA)
    m.Properties["Poll Interval Playing"] = "30"
    roku_routes(m)
    m:route("/api/states/", { status = 200, body = ha_body() })
    m:start()
    m:advance(1)
    local p0 = tonumber(m.vars.POSITION_SECONDS)
    local v0 = m.vars.VERSION
    local polls = m:count("/query/media-player")
    m:advance(10)
    T.eq(m:count("/query/media-player"), polls, "no poll in between")
    T.eq(tonumber(m.vars.POSITION_SECONDS), p0 + 10, "position extrapolated by the 5 s timer")
    T.eq(m.vars.VERSION, v0, "no state version bump for position ticks")
    m:destroy()
  end)

  it("GET_STATE via ExecuteCommand re-pushes every time; UIRequest returns escaped JSON", function()
    local m = setup()
    m:advance(1)
    local n = #m.data_to_ui
    m:call("ExecuteCommand", "GET_STATE", {})
    m:call("ExecuteCommand", "GET_STATE", "{}")
    T.eq(#m.data_to_ui, n + 2, "a push per request even when nothing changed")
    m:advance(1)
    m:call("ExecuteCommand", "GET_STATE", {})
    local ui = last_ui(m)
    T.eq(ui.sent_at, m.t)
    T.eq(ui.media.title, "Top Gun: Maverick")
    local r = m:call("UIRequest", "GET_STATE", {})
    T.eq(r:sub(1, 1), "{")
    T.contains(r, "&quot;sent_at&quot;:" .. m.t)
    T.no(r:find('"', 1, true))
    local unesc = r:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
    T.eq(json.decode(unesc).media.title, "Top Gun: Maverick")
    T.eq(m:call("UIRequest", "OTHER", {}), "")
    m:destroy()
  end)

  it("property change reconfigures without leaking timers or duplicating polls", function()
    local m = setup()
    m:advance(10)
    local base_timers = m:pending_timers()
    for i = 1, 5 do m:prop("Roku Name", "Roku " .. i) end
    m:prop("Poll Interval Playing", "3")
    m:advance(0.6)
    T.eq(m.vars.SOURCE_DEVICE, "Roku 5")
    m:advance(10)
    T.eq(m:pending_timers(), base_timers)
    local c0 = m:count("/query/media-player")
    m:advance(30)
    local polls = m:count("/query/media-player") - c0
    T.ok(polls >= 9 and polls <= 11, "about one poll every 3 s, got " .. polls)
    -- read-only property writes are ignored
    m:prop("Status", "x")
    m:advance(1)
    T.eq(m:pending_timers(), base_timers)
    m:destroy()
  end)

  it("removing every source publishes an honest off state and stops polling", function()
    local m = setup()
    m:advance(3)
    T.eq(m.vars.PLAY_STATE, "playing")
    local n = #m.events
    m:prop("Roku Address", "")
    m:prop("Home Assistant URL", "")
    m:advance(1)
    T.eq(m.vars.PLAY_STATE, "off")
    T.eq(m.updated_props["Status"], Status.NOT_CONFIGURED)
    T.deep_eq(m:events_since(n), { "App Changed", "Playback Stopped" })
    local c = #m.requests
    m:advance(60)
    T.eq(#m.requests, c)
    m:destroy()
  end)

  it("Debug Mode Print logs with secrets redacted", function()
    local m = setup()
    m:prop("Debug Mode", "Print")
    m:advance(10)
    local all = m:all_prints()
    T.contains(all, "NowPlaying [debug]")
    T.no(all:find("ha-long-lived-token-xyz", 1, true))
    T.no(all:find("tmdbkey0123456789abcdef", 1, true))
    m:destroy()
  end)

  it("Roku failing -> per-provider error in Status, driver keeps going", function()
    local m = new({ ["Roku Address"] = "192.168.1.50", ["Use Control4 Room Media"] = "Off" })
    m:route("192.168.1.50", { status = 403, body = "" })
    m:start()
    m:advance(20)
    T.contains(m.updated_props["Status"], "Roku: Roku ECP access denied")
    T.eq(m.vars.PLAY_STATE, "off")
    m:destroy()
  end)
end)

describe("driver actions", function()
  it("Refresh Now / Refresh command poll immediately; Print State; Test Metadata Sources", function()
    local m = new(ROKU_HA)
    m.Properties["OMDb API Key"] = "omdbsecretkey"
    roku_routes(m)
    m:route("/api/states/", { status = 200, body = ha_body() })
    tmdb_routes(m)
    m:route("/3/configuration", { status = 401, body = "{}" })
    m:route("omdbapi.com", { status = 200, body = '{"Response":"True","imdbRating":"9.3"}' })
    m:route("itunes.apple.com", { status = 200, body = '{"resultCount":0,"results":[]}' })
    m:start()
    m:advance(1)
    local c = m:count("/query/media-player")
    m:action("RefreshNow")
    m:advance(0.1)
    T.eq(m:count("/query/media-player"), c + 1)
    m:call("ExecuteCommand", "Refresh", {})
    m:advance(0.1)
    T.eq(m:count("/query/media-player"), c + 2)

    m:action("PrintState")
    T.ok(m:printed("TITLE              = Top Gun: Maverick"))
    T.ok(m:printed("STATE_JSON"))

    m.prints = {}
    m:action("TestMetadataSources")
    m:advance(1)
    local out = m:all_prints()
    T.contains(out, "Roku (192.168.1.50)")
    T.contains(out, "OK")
    T.contains(out, "TMDB")
    T.contains(out, "API key rejected")
    T.contains(out, "OMDb")
    T.contains(out, "IMDb rating 9.3")
    T.contains(out, "done, 1 problem(s)")
    T.no(out:find("omdbsecretkey", 1, true)); T.no(out:find("tmdbkey0123456789abcdef", 1, true))
    T.no(out:find("ha-long-lived-token-xyz", 1, true))

    m:action("ClearMetadataCache")
    T.ok(m:printed("caches cleared"))
    T.is_nil(m.persist["np_enrich_cache_v1"])
    m:destroy()
  end)
end)

describe("driver with Control4 room media", function()
  local SONOS = 245
  local function setup(info, extra)
    local m = new(extra)
    m:device(SONOS, "Sonos Five", {})
    m.devices[ROOM].vars = { [1000] = tostring(SONOS), [1010] = "1", [1031] = info or "" }
    m:start()
    m:advance(1)
    return m
  end

  local cases = {
    { "TITLE/ARTIST/ALBUM + plain IMAGEURL",
      "<mediainfo><TITLE>So What</TITLE><ARTIST>Miles Davis</ARTIST><ALBUM>Kind of Blue</ALBUM><IMAGEURL>https://cdn.example.com/kob.jpg</IMAGEURL></mediainfo>",
      { TITLE = "So What", ARTIST = "Miles Davis", ALBUM = "Kind of Blue", MEDIA_KIND = "music", PLAY_STATE = "playing",
        ARTWORK_URL = "https://cdn.example.com/kob.jpg", SOURCE_DEVICE = "Sonos Five", SOURCE_PROVIDER = "c4room" } },
    { "base64 IMAGEURL",
      "<mediainfo><TITLE>Blue in Green</TITLE><ARTIST>Miles Davis</ARTIST><IMAGEURL>" .. b64.encode("https://cdn.example.com/b.jpg") .. "</IMAGEURL></mediainfo>",
      { TITLE = "Blue in Green", ARTWORK_URL = "https://cdn.example.com/b.jpg", MEDIA_KIND = "music" } },
    { "LINE1-3",
      "<info><LINE1>Morning Edition</LINE1><LINE2>NPR</LINE2><LINE3>KQED</LINE3></info>",
      { TITLE = "Morning Edition", ARTIST = "NPR", ALBUM = "KQED", PLAY_STATE = "playing" } },
    { "title only -> unknown kind",
      "<media><title>Some Show</title></media>",
      { TITLE = "Some Show", MEDIA_KIND = "unknown", PLAY_STATE = "playing" } },
    { "empty", "", { TITLE = "", PLAY_STATE = "idle" } },
    { "garbage", "<<<garbage>>>", { TITLE = "", PLAY_STATE = "idle" } },
  }
  for _, c in ipairs(cases) do
    it("media info: " .. c[1], function()
      local m = setup(c[2])
      for k, v in pairs(c[3]) do T.eq(m.vars[k], v, k) end
      T.eq(#m.errors, 0, table.concat(m.errors, "\n"))
      m:destroy()
    end)
  end

  it("follows live changes of 1031 and power off", function()
    local m = setup("")
    m:set_var(ROOM, 1031, "<m><TITLE>Track A</TITLE><ARTIST>X</ARTIST></m>")
    m:advance(1)
    T.eq(m.vars.TITLE, "Track A")
    local n = #m.events
    m:set_var(ROOM, 1031, "<m><TITLE>Track B</TITLE><ARTIST>X</ARTIST></m>")
    m:advance(1)
    T.eq(m.vars.TITLE, "Track B")
    T.deep_eq(m:events_since(n), { "Media Changed", "Music Track Started" })
    n = #m.events
    m:set_var(ROOM, 1010, "0")
    m:advance(1)
    T.eq(m.vars.PLAY_STATE, "off")
    T.deep_eq(m:events_since(n), { "Playback Stopped" })
    m:destroy()
  end)

  it("Print Room Media Info prints the raw values", function()
    local raw = "<mediainfo><TITLE>So What</TITLE></mediainfo>"
    local m = setup(raw)
    m:action("PrintRoomMediaInfo")
    local out = m:all_prints()
    T.contains(out, "1031 CURRENT MEDIA INFO = [[" .. raw .. "]]")
    T.contains(out, "parsed: title=So What")
    m:destroy()
  end)

  it("Show Only When Room Is On gates Roku: off while the room is off, polls again when on", function()
    local m = new({ ["Roku Address"] = "192.168.1.50", ["Show Only When Room Is On"] = "On" })
    roku_routes(m)
    m.devices[ROOM].vars = { [1000] = "0", [1010] = "0", [1031] = "" }
    m:start()
    m:advance(10)
    T.eq(m.vars.PLAY_STATE, "off")
    T.eq(m:count("192.168.1.50"), 0, "Roku not polled while the room is off")
    T.contains(m.updated_props["Status"], "room is off")
    m:set_var(ROOM, 1010, "1")
    m:advance(3)
    T.eq(m.vars.PLAY_STATE, "playing")
    T.eq(m.vars.APP_NAME, "Netflix")
    local n = #m.events
    m:set_var(ROOM, 1010, "0")
    m:advance(3)
    T.eq(m.vars.PLAY_STATE, "off")
    T.deep_eq(m:events_since(n), { "Source Changed", "App Changed", "Playback Stopped" })
    m:destroy()
  end)

  it("Room property selects another room's listeners", function()
    local m = setup("")
    m:device(300, "Den", { [1010] = "1", [1031] = "<m><TITLE>Den Song</TITLE><ARTIST>Y</ARTIST></m>" })
    m:prop("Room", "300")
    m:advance(1)
    T.eq(m.vars.TITLE, "Den Song")
    T.no(m.listeners[ROOM .. ":1031"]); T.ok(m.listeners["300:1031"])
    T.eq(state_of(m).room.name, "Den")
    m:destroy()
  end)
end)

describe("LAN artwork embedding", function()
  local PNG = "\137PNG\r\n\26\n" .. string.rep("p", 2000)
  local function setup(art_resp, embed)
    local m = new({ ["Apple TV Bridge URL"] = "http://192.168.1.10:8765", ["Apple TV Device"] = "Den",
      ["Use Control4 Room Media"] = "Off", ["Embed LAN Artwork"] = embed or "On" })
    local doc = json.decode(T.fixture("bridge_appletv.json"))
    doc.media.artwork_url = "http://192.168.1.10:8765/v1/devices/Den/artwork?v=abc&token=t0k3n"
    m:route("/now-playing", { status = 200, body = json.encode(doc) })
    m:route("/artwork", art_resp)
    m:start()
    m:advance(1)
    return m
  end
  it("embeds a data: URI in the state JSON; variables keep the http URL", function()
    local m = setup({ status = 200, body = PNG, headers = { ["Content-Type"] = "image/png" } })
    m:advance(1)
    local st = state_of(m)
    T.eq(st.media.artwork_url, "data:image/png;base64," .. b64.encode(PNG))
    T.eq(last_ui(m).media.artwork_url, st.media.artwork_url)
    T.eq(m.vars.ARTWORK_URL, "http://192.168.1.10:8765/v1/devices/Den/artwork?v=abc&token=t0k3n")
    T.ok(not m.vars.POSTER_URL:find("^data:"))
    T.eq(m:count("/artwork"), 1)
    m:advance(20)
    T.eq(m:count("/artwork"), 1, "downloaded once")
    m:destroy()
  end)
  it("oversize artwork stays a URL", function()
    local m = setup({ status = 200, body = "\137PNG\r\n\26\n" .. string.rep("x", 300 * 1024) })
    m:advance(2)
    T.eq(state_of(m).media.artwork_url, "http://192.168.1.10:8765/v1/devices/Den/artwork?v=abc&token=t0k3n")
    T.eq(#m.errors, 0)
    m:destroy()
  end)
  it("download failure stays a URL and is not retried every poll", function()
    local m = setup({ err = 7, msg = "couldn't connect" })
    m:advance(30)
    T.ok(not state_of(m).media.artwork_url:find("^data:"))
    T.eq(m:count("/artwork"), 1)
    m:destroy()
  end)
  it("Embed LAN Artwork Off leaves the URL alone", function()
    local m = setup({ status = 200, body = PNG }, "Off")
    m:advance(5)
    T.eq(m:count("/artwork"), 0)
    T.ok(state_of(m).media.artwork_url:find("^http://192"))
    m:destroy()
  end)
end)

describe("LAN HTTP server", function()
  local function setup()
    local m = new({ ["LAN Web Port"] = "8080" })
    m:start()
    m:advance(1)
    return m
  end
  local function request(m, h, raw)
    m:connect(h)
    m:client_send(h, raw)
    return m:response(h)
  end
  it("serves index.html, /api/state (200 then 304), 404, HEAD, 405 and closes clients", function()
    local m = setup()
    T.eq(m.server.port, 8080)
    T.eq(m.updated_props["LAN URL"], "http://192.168.1.5:8080/")
    local r = request(m, 1, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    T.ok(r:find("^HTTP/1.1 200 OK\r\n")); T.contains(r, "Content-Type: text/html")
    T.contains(r, "<!doctype html>"); T.ok(m.closed[1])
    T.contains(request(m, 2, "GET /index.html HTTP/1.1\r\n\r\n"), "HTTP/1.1 200 OK")

    r = request(m, 3, "GET /api/state HTTP/1.1\r\n\r\n")
    T.ok(r:find("^HTTP/1.1 200 OK"))
    T.contains(r, "Cache-Control: no-store"); T.contains(r, "Access-Control-Allow-Origin: *")
    T.contains(r, "Connection: close"); T.contains(r, "Date: ")
    local etag = r:match("ETag: ([^\r]+)")
    T.ok(etag)
    local body = r:match("\r\n\r\n(.*)$")
    T.eq(json.decode(body).sent_at, m.t)
    T.eq(tonumber(r:match("Content%-Length: (%d+)")), #body)

    m:advance(5)
    r = request(m, 4, "GET /api/state HTTP/1.1\r\nIf-None-Match: " .. etag .. "\r\n\r\n")
    T.ok(r:find("^HTTP/1.1 304 Not Modified"), r)
    T.eq(r:match("\r\n\r\n(.*)$"), "")

    T.ok(request(m, 5, "GET /nope HTTP/1.1\r\n\r\n"):find("^HTTP/1.1 404"))
    r = request(m, 6, "HEAD /api/state HTTP/1.1\r\n\r\n")
    T.ok(r:find("^HTTP/1.1 200")); T.eq(r:match("\r\n\r\n(.*)$"), ""); T.ok(tonumber(r:match("Content%-Length: (%d+)")) > 10)
    r = request(m, 7, "POST /api/state HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}")
    T.ok(r:find("^HTTP/1.1 405")); T.contains(r, "Allow: GET, HEAD")
    for h = 1, 7 do T.ok(m.closed[h], "closed " .. h) end
    m:destroy()
  end)
  it("handles requests split across chunks and caps request size; buffers freed", function()
    local m = setup()
    m:connect(10)
    m:client_send(10, "GET /api/st")
    T.is_nil(m.sent[10])
    m:client_send(10, "ate HTTP/1.1\r\nHost: x\r\n")
    T.is_nil(m.sent[10])
    m:client_send(10, "\r\n")
    T.ok(m:response(10):find("^HTTP/1.1 200"))
    m:connect(11)
    for _ = 1, 10 do m:client_send(11, string.rep("a", 1000)) end
    T.ok(m:response(11):find("^HTTP/1.1 413"))
    m:connect(12)
    m:client_send(12, "GET / HT")
    m:client_close(12)
    m:connect(13); m:client_send(13, "GET /x HTTP/1.1\r\n\r\n")
    T.ok(m.closed[13])
    -- the driver keeps no per-connection state after a response / close
    local srv = m.env.NOW_PLAYING_APP.server
    T.eq(srv.nbuf, 0); T.is_nil(next(srv.buffers))
    m:destroy()
  end)
  it("port change re-creates the server; 0 disables", function()
    local m = setup()
    m:prop("LAN Web Port", "9090")
    m:advance(1)
    T.eq(m.server.port, 9090); T.eq(m.servers_created, 2)
    m:prop("LAN Web Port", "0")
    m:advance(1)
    T.is_nil(m.server); T.eq(m.updated_props["LAN URL"], "Disabled")
    m:destroy()
  end)
end)
