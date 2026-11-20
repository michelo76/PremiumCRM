--[[
End-to-end state generator: runs the REAL driver (driver.lua -> c4.app -> np.engine, providers,
enrichers) against the C4 mock with scripted provider / metadata responses from tests/fixtures,
and writes exactly what the web page would receive:

  <out>/<name>.json          the STATE_JSON variable value (sent_at + schema-1 document)
  <out>/<name>.dtu.json      { "cmd": "NOW_PLAYING", "params": { "state": "<json string>" } }
                             = the last C4:SendDataToUI("NOW_PLAYING", {state=json}) call
  <out>/<name>.vars.json     every Control4 variable (name -> string), for assertions
  <out>/<name>.artwork.json  [ { "cmd": "NOW_PLAYING_ARTWORK", "params": {url, data|error} }, ... ]
                             the driver's real replies to GET_ARTWORK for every LAN image URL of
                             the state (what a Navigator page asks for)
  <out>/<name>.relay.json    the driver's LAN relay (c4/httpserver.lua) answers, raw HTTP bytes
                             base64-encoded: { webview_url, token, state (200), not_modified
                             (?inm=<etag> -> 304), unauthorized (no k -> 401), options (204),
                             artwork = { [url] = 200 with the image bytes } }
  <out>/index.json           scenario list + the mock clock
  <out>/atv_seq.json         { steps = [ STATE_JSON, ... ] }: one open page, the SmartBuildOS Apple TV
                             driver source over time (playing with artwork -> same title, artwork
                             cleared + paused -> VALID=0), replayed by render.js

  lua5.1 tests/e2e/gen_states.lua <out_dir>          (also: luajit)

Used by tools/e2e.sh (Playwright renders every file through both page transports).
]]

local script = arg and arg[0] or "tests/e2e/gen_states.lua"
local here = script:match("^(.*)[/\\][^/\\]*$") or "."
local root = here .. "/../.."
package.path = root .. "/driver/?.lua;" .. root .. "/tests/?.lua;" .. root .. "/tests/c4/?.lua;" .. package.path

local Mock = require("c4_mock")
local json = require("np.json")
local App = require("c4.app")
local Artwork = require("c4.artwork")
local b64 = require("c4.b64")
local RELAY_TOKEN = "e2e-relay-token-0123456789" -- fixed (persisted) so lua5.1 / luajit output is identical

local OUT = arg[1] or (root .. "/build/e2e")
os.execute("mkdir -p '" .. OUT .. "'")

local function fixture(name)
  local f = assert(io.open(root .. "/tests/fixtures/" .. name, "rb"), "missing fixture " .. name)
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local ROOM = 100
local function file(path)
  local f = assert(io.open(root .. "/tests/e2e/fixtures/" .. path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end
local POSTER = { status = 200, body = file("lan_poster.png"), headers = { ["Content-Type"] = "image/png" } }
local ICON = { status = 200, body = file("lan_icon.png"), headers = { ["Content-Type"] = "image/png" } }

local function new(props)
  local m = Mock.new({ root = root .. "/driver", room_id = ROOM, room_name = "Family Room" })
  m.Properties["Use Control4 Room Media"] = "Off"
  m.persist["np_lan_token_v1"] = RELAY_TOKEN
  for k, v in pairs(props or {}) do
    assert(m.xml.properties[k], "unknown property " .. k)
    m.Properties[k] = v
  end
  return m
end

local KEYS = { ["TMDB API Key"] = "tmdbkey0123456789abcdef", ["OMDb API Key"] = "omdbsecretkey" }
local function with(a, b)
  local o = {}
  for k, v in pairs(a or {}) do o[k] = v end
  for k, v in pairs(b or {}) do o[k] = v end
  return o
end

local function roku(m, app, player)
  m:route("/query/device-info", { status = 200, body = fixture("roku_device_info.xml") })
  m:route("/query/active-app", { status = 200, body = fixture(app) })
  m:route("/query/media-player", { status = 200, body = fixture(player) })
  m:route("/query/tv-active-channel", { status = 200, body = fixture("roku_tv_active_channel.xml") })
  m:route("/query/icon/", ICON)
end
local function tmdb_movie(m)
  m:route("/search/movie", { status = 200, body = fixture("tmdb_search_movie_topgun.json") })
  m:route("/movie/361743", { status = 200, body = fixture("tmdb_movie_361743.json") })
  m:route("omdbapi.com", { status = 200, body = fixture("omdb_tt1745960.json") })
end
local function tmdb_bear(m)
  m:route("/search/tv", { status = 200, body = fixture("tmdb_search_tv_bear.json") })
  m:route("/tv/136315?", { status = 200, body = fixture("tmdb_tv_136315.json") })
  m:route("/tv/136315/season/2/episode/7", { status = 200, body = fixture("tmdb_tv_136315_s2e7.json") })
  m:route("omdbapi.com", { status = 200, body = fixture("omdb_tt14452776.json") })
  m:route("Episode=7", { status = 200, body = fixture("omdb_bear_s2e7.json") })
end
local function music(m)
  m:route("itunes.apple.com/search", { status = 200, body = fixture("itunes_search_blinding.json") })
  m:route("itunes.apple.com/lookup", { status = 200, body = fixture("itunes_lookup_after_hours.json") })
  m:route("musicbrainz.org/ws/2/recording", { status = 200, body = fixture("mb_recording_search.json") })
  m:route("musicbrainz.org/ws/2/release/", { status = 200, body = fixture("mb_release_after_hours.json") })
end
local function ha(m, file, edit)
  local d = json.decode(fixture(file))
  if edit then edit(d) end
  m:route("/api/states/", { status = 200, body = json.encode(d) })
  m:route("/api/media_player_proxy/", POSTER)
end
local HA = {
  ["Home Assistant URL"] = "http://192.168.1.2:8123", ["Home Assistant Token"] = "ha-long-lived-token-xyz",
  ["Home Assistant Entity ID"] = "media_player.living_room",
}
local ROKU = { ["Roku Address"] = "192.168.1.50", ["Roku Name"] = "Living Room Roku" }
local BRIDGE = { ["Apple TV Bridge URL"] = "http://192.168.1.10:8765", ["Apple TV Device"] = "Den",
  ["Apple TV Bridge Token"] = "bridge-secret-t0k3n" }

local SCENARIOS = {
  { name = "episode", desc = "Roku + HA (same device) episode, TMDB + OMDb",
    props = with(with(ROKU, HA), with(KEYS, { ["Home Assistant Entity Is"] = "Same Device As Roku" })),
    setup = function(m)
      roku(m, "roku_active_app_netflix.xml", "roku_media_player_play.xml")
      ha(m, "ha_appletv_episode.json")
      tmdb_bear(m)
    end },
  { name = "atv_episode", desc = "SmartBuildOS Apple TV driver (variable contract) episode, TMDB + OMDb",
    props = with(KEYS, { ["Apple TV Driver"] = "301" }), -- the Media Player proxy: resolved to the main device
    setup = function(m)
      local now = tostring(math.floor(m.t))
      m:dyn_device(300, "Den Apple TV", {
        NOW_PLAYING_TITLE = "Forks", NOW_PLAYING_SERIES = "The Bear", NOW_PLAYING_SEASON = "2",
        NOW_PLAYING_EPISODE = "7", NOW_PLAYING_ARTIST = "", NOW_PLAYING_ALBUM = "", NOW_PLAYING_APP_NAME = "Hulu",
        NOW_PLAYING_APP_ID = "com.hulu.plus", NOW_PLAYING_PLAY_STATE = "Playing", NOW_PLAYING_POSITION = "754",
        NOW_PLAYING_DURATION = "2280", NOW_PLAYING_ARTWORK_URL = "", NOW_PLAYING_UPDATED_AT = now,
        NOW_PLAYING_VALID = "1", NOW_PLAYING_REVISION = "42", PLAYBACK_POSITION = "0",
      }, { c4i = "smartbuildos_appletv_native.c4z" })
      m:proxy_device(301, "Den Apple TV", 300, "media_player.c4i")
      tmdb_bear(m)
    end,
    check = function(st, m)
      assert(st.source.provider == "appletv" and st.source.device_name == "Den Apple TV" and
        st.source.app_name == "Hulu", "atv_episode: source")
      assert(st.media.series_title == "The Bear" and st.media.season == 2 and st.media.episode == 7, "atv_episode: media")
      assert(st.details and st.details.episode and st.details.episode.title == "Forks", "atv_episode: not enriched")
      assert(m.updated_props["Apple TV Driver Status"]:find("revision 42", 1, true), "atv_episode: driver status")
    end },
  { name = "music", desc = "HA Sonos music, iTunes + MusicBrainz",
    props = with(HA, { ["Home Assistant Entity ID"] = "media_player.kitchen" }),
    setup = function(m) ha(m, "ha_sonos_music.json"); music(m) end },
  { name = "live", desc = "Roku TV antenna (live TV) + Gracenote",
    props = with(ROKU, { ["Gracenote API Key"] = "gnkey0123", ["Gracenote Lineup ID"] = "USA-OTA22201-DEFAULT" }),
    setup = function(m)
      roku(m, "roku_active_app_dtv.xml", "roku_media_player_live.xml")
      m:route("/lineups/USA-OTA22201-DEFAULT/channels", { status = 200, body = fixture("gn_channels.json") })
      m:route("/stations/10021/airings", { status = 200, body = fixture("gn_airings.json") })
    end },
  { name = "movie", desc = "Apple TV bridge movie (LAN artwork with ?token=), TMDB + OMDb",
    props = with(BRIDGE, KEYS), pre_s = 1, -- also capture the state published BEFORE enrichment (same media_key)
    setup = function(m)
      local d = json.decode(fixture("bridge_appletv.json"))
      d.media.artwork_url = "http://192.168.1.10:8765/v1/devices/Den/artwork?v=abc&token=bridge-secret-t0k3n"
      m:route("/now-playing", { status = 200, body = json.encode(d) })
      m:route("/v1/devices/Den/artwork", POSTER)
      tmdb_movie(m)
    end },
  { name = "unenriched", desc = "HA movie title, no metadata keys",
    props = with(HA, { ["Music Lookup"] = "Off" }),
    setup = function(m) ha(m, "ha_movie_title.json") end },
  { name = "paused", desc = "Roku + HA movie, paused, TMDB + OMDb",
    props = with(with(ROKU, HA), with(KEYS, { ["Home Assistant Entity Is"] = "Same Device As Roku" })),
    setup = function(m)
      roku(m, "roku_active_app_netflix.xml", "roku_media_player_pause.xml")
      ha(m, "ha_movie_title.json", function(d) d.state = "paused" end)
      tmdb_movie(m)
    end },
  { name = "idle", desc = "Roku on the home screen",
    props = ROKU,
    setup = function(m) roku(m, "roku_active_app_home.xml", "roku_media_player_none.xml") end },
  { name = "off", desc = "HA media player off",
    props = HA,
    setup = function(m) ha(m, "ha_off.json") end },
  { name = "room", desc = "Control4 room media only (no providers, no keys)",
    props = { ["Use Control4 Room Media"] = "On", ["Music Lookup"] = "Off" },
    setup = function(m)
      m:device(245, "Sonos Five", {})
      m.devices[ROOM].vars = { [1000] = "245", [1010] = "1",
        [1031] = "<mediainfo><TITLE>So What</TITLE><ARTIST>Miles Davis</ARTIST><ALBUM>Kind of Blue</ALBUM>" ..
          "<IMAGEURL>https://cdn.example.com/kob.jpg</IMAGEURL></mediainfo>" }
    end },
}

local index = { generated_by = "tests/e2e/gen_states.lua", scenarios = {} }
local SECRETS = { "tmdbkey0123456789abcdef", "omdbsecretkey", "ha-long-lived-token-xyz", "bridge-secret-t0k3n", "gnkey0123" }

for _, sc in ipairs(SCENARIOS) do
  local m = new(sc.props)
  sc.setup(m)
  m:start()
  local pre
  if sc.pre_s then
    -- <name>.pre.json: what an open page receives first when this media starts (details not yet
    -- attached, same media_key as the final state) -- render.js replays pre -> final.
    m:advance(sc.pre_s)
    pre = assert(m.vars.STATE_JSON, sc.name .. ": no state before enrichment")
  end
  m:advance(8 - (sc.pre_s or 0)) -- first poll, 1.5 s enrichment debounce, metadata requests, re-polls
  assert(#m.errors == 0, sc.name .. ": driver errors:\n" .. table.concat(m.errors, "\n"))
  local sj = m.vars.STATE_JSON
  local st = assert(json.decode(sj), sc.name .. ": STATE_JSON is not JSON")
  assert(st.schema == 1 and type(st.sent_at) == "number", sc.name .. ": no schema/sent_at")
  if sc.check then sc.check(st, m) end
  local dtu = m.data_to_ui[#m.data_to_ui]
  assert(dtu and dtu.cmd == "NOW_PLAYING" and type(dtu.params.state) == "string", sc.name .. ": no DataToUI push")
  for _, s in ipairs(SECRETS) do
    assert(not sj:find(s, 1, true), sc.name .. ": secret leaked into STATE_JSON: " .. s)
    for name, v in pairs(m.vars) do
      assert(not tostring(v):find(s, 1, true), sc.name .. ": secret leaked into variable " .. name)
    end
  end
  write(OUT .. "/" .. sc.name .. ".json", sj)
  if pre then
    local ps = json.decode(pre)
    assert(ps.details == nil and ps.media_key == st.media_key and st.details ~= nil,
      sc.name .. ": pre state must be the unenriched state of the same media_key")
    write(OUT .. "/" .. sc.name .. ".pre.json", pre)
  end
  write(OUT .. "/" .. sc.name .. ".dtu.json", json.encode({ cmd = dtu.cmd, params = { state = dtu.params.state } }))
  write(OUT .. "/" .. sc.name .. ".vars.json", json.encode(m.vars))
  -- What a Navigator page asks for: every LAN image of the state, sent exactly as the page
  -- sends it (C4.sendCommand("GET_ARTWORK", JSON.stringify({url}), ...)).
  local lan = {}
  for u in pairs(App.state_image_urls(m.env.NOW_PLAYING_APP.engine.state)) do
    if Artwork.is_lan(u) then lan[#lan + 1] = u end
  end
  table.sort(lan)
  local n0 = #m.data_to_ui
  for _, u in ipairs(lan) do m:call("ExecuteCommand", "GET_ARTWORK", json.encode({ url = u })) end
  m:advance(2)
  local replies = json.array({})
  for i = n0 + 1, #m.data_to_ui do
    local d = m.data_to_ui[i]
    if d.cmd == "NOW_PLAYING_ARTWORK" then
      assert(type(d.params.data) == "string" and d.params.data:find("^data:image/"), sc.name .. ": artwork failed: " ..
        tostring(d.params.url) .. " " .. tostring(d.params.error))
      replies[#replies + 1] = { cmd = d.cmd, params = { url = d.params.url, data = d.params.data } }
    end
  end
  assert(#replies == #lan, sc.name .. ": expected " .. #lan .. " artwork replies, got " .. #replies)
  write(OUT .. "/" .. sc.name .. ".artwork.json", json.encode(replies))
  -- the LAN relay, exactly as a page reaches it (default port 8487, token from the web view URL)
  local urls = m:proxy_cmds("URL_CHANGED")
  local wv = assert(urls[#urls], sc.name .. ": no URL_CHANGED").params.url
  assert(wv:find("?relay=http%3A%2F%2F192.168.1.5%3A8487&k=" .. RELAY_TOKEN, 1, true), sc.name .. ": web view URL " .. wv)
  local hn = 900
  local function relay(target, extra)
    hn = hn + 1
    m:connect(hn)
    m:client_send(hn, (extra and "OPTIONS " or "GET ") .. target .. " HTTP/1.1\r\nHost: 192.168.1.5:8487\r\nOrigin: controller://driver\r\n\r\n")
    m:advance(2)
    local raw = m:response(hn)
    assert(raw ~= "" and m.closed[hn], sc.name .. ": relay gave no answer for " .. target)
    return raw
  end
  local function q(v) return (v:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end
  local rs = relay("/api/state?k=" .. RELAY_TOKEN)
  assert(rs:find("^HTTP/1.1 200") and rs:find("\r\n\r\n{\"sent_at\":"), sc.name .. ": relay state")
  local etag = assert(rs:match("\r\nETag: ([^\r]+)"), sc.name .. ": relay ETag")
  local rec = { webview_url = wv, token = RELAY_TOKEN, etag = etag, state = b64.encode(rs),
    not_modified = b64.encode(relay("/api/state?k=" .. RELAY_TOKEN .. "&inm=" .. q(etag))),
    unauthorized = b64.encode(relay("/api/state")), options = b64.encode(relay("/api/state", true)), artwork = {} }
  assert(b64.decode(rec.not_modified):find("^HTTP/1.1 304"), sc.name .. ": relay 304")
  assert(b64.decode(rec.unauthorized):find("^HTTP/1.1 401"), sc.name .. ": relay 401")
  for _, u in ipairs(lan) do
    local ra = relay("/api/artwork?url=" .. q(u) .. "&k=" .. RELAY_TOKEN)
    assert(ra:find("^HTTP/1.1 200") and ra:find("Content%-Type: image/"), sc.name .. ": relay artwork " .. u .. ": " .. ra:sub(1, 40))
    rec.artwork[u] = b64.encode(ra)
  end
  if #lan == 0 then rec.artwork = json.object({}) end
  write(OUT .. "/" .. sc.name .. ".relay.json", json.encode(rec))
  index.scenarios[#index.scenarios + 1] = { name = sc.name, desc = sc.desc, version = st.version,
    state = st.playback.state, kind = st.media.kind, bytes = #sj, lan_images = #lan, pre = pre and true or nil }
  io.write(string.format("%-11s v%-3d %-8s %-8s %6d bytes  %s\n", sc.name, st.version, st.playback.state,
    st.media.kind, #sj, sc.desc))
  m:destroy()
end

-- The Apple TV driver source over time on ONE open page (render.js runAtvLifecycle): the exact
-- states the real driver publishes for: playing with artwork -> same title, ARTWORK_URL cleared
-- and Paused -> VALID=0 (disconnect). No metadata keys: no enrichment poster.
do
  local m = new({ ["Apple TV Driver"] = "300", ["Music Lookup"] = "Off" })
  local function vals(t)
    local v = { NOW_PLAYING_TITLE = "", NOW_PLAYING_SERIES = "", NOW_PLAYING_SEASON = "", NOW_PLAYING_EPISODE = "",
      NOW_PLAYING_ARTIST = "", NOW_PLAYING_ALBUM = "", NOW_PLAYING_APP_NAME = "", NOW_PLAYING_APP_ID = "",
      NOW_PLAYING_PLAY_STATE = "", NOW_PLAYING_POSITION = "0", NOW_PLAYING_DURATION = "0", NOW_PLAYING_ARTWORK_URL = "",
      NOW_PLAYING_UPDATED_AT = "0", NOW_PLAYING_VALID = "0", NOW_PLAYING_REVISION = "0" }
    for k, x in pairs(t) do v["NOW_PLAYING_" .. k] = x end
    return v
  end
  local playing = { TITLE = "Forks", SERIES = "The Bear", SEASON = "2", EPISODE = "7", APP_NAME = "Hulu",
    APP_ID = "com.hulu.plus", PLAY_STATE = "Playing", POSITION = "754", DURATION = "2280",
    ARTWORK_URL = "https://img.example.com/atv/bear-s2e7.jpg", VALID = "1" }
  m:dyn_device(300, "Den Apple TV", vals({}), { c4i = "smartbuildos_appletv_native.c4z" })
  local rev = 0
  local function snapshot(t)
    rev = rev + 1
    local v = vals(t)
    v.NOW_PLAYING_UPDATED_AT = t.VALID == "1" and tostring(math.floor(m.t)) or "0"
    v.NOW_PLAYING_REVISION = tostring(rev)
    local names = {}
    for k in pairs(v) do if k ~= "NOW_PLAYING_REVISION" then names[#names + 1] = k end end
    table.sort(names)
    names[#names + 1] = "NOW_PLAYING_REVISION" -- written last, like the Apple TV driver
    m:set_named_many(300, v, names)
  end
  m:activate()
  snapshot(playing)
  m:start(); m:advance(3)
  local steps = json.array({})
  steps[1] = m.vars.STATE_JSON
  local paused = {}
  for k, x in pairs(playing) do paused[k] = x end
  paused.ARTWORK_URL, paused.PLAY_STATE, paused.POSITION = "", "Paused", "800"
  m:advance(46); snapshot(paused); m:advance(2)
  steps[2] = m.vars.STATE_JSON
  m:advance(10); snapshot({ VALID = "0" }); m:advance(2)
  steps[3] = m.vars.STATE_JSON
  assert(#m.errors == 0, "atv_seq: driver errors:\n" .. table.concat(m.errors, "\n"))
  local a, b, c = json.decode(steps[1]), json.decode(steps[2]), json.decode(steps[3])
  assert(a.media.artwork_url == playing.ARTWORK_URL and a.playback.state == "playing", "atv_seq: step 1")
  assert(b.media_key == a.media_key and b.media.artwork_url == nil and b.playback.state == "paused", "atv_seq: step 2")
  assert(c.playback.state == "idle" and c.media.title == nil and c.media.artwork_url == nil, "atv_seq: step 3")
  write(OUT .. "/atv_seq.json", json.encode({ steps = steps }))
  m:destroy()
end

write(OUT .. "/index.json", json.encode(index))
print("wrote " .. #SCENARIOS .. " scenarios to " .. OUT)
