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
  <out>/index.json           scenario list + the mock clock

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
    props = with(BRIDGE, KEYS),
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
  m:advance(8) -- first poll, 1.5 s enrichment debounce, metadata requests, re-polls
  assert(#m.errors == 0, sc.name .. ": driver errors:\n" .. table.concat(m.errors, "\n"))
  local sj = m.vars.STATE_JSON
  local st = assert(json.decode(sj), sc.name .. ": STATE_JSON is not JSON")
  assert(st.schema == 1 and type(st.sent_at) == "number", sc.name .. ": no schema/sent_at")
  local dtu = m.data_to_ui[#m.data_to_ui]
  assert(dtu and dtu.cmd == "NOW_PLAYING" and type(dtu.params.state) == "string", sc.name .. ": no DataToUI push")
  for _, s in ipairs(SECRETS) do
    assert(not sj:find(s, 1, true), sc.name .. ": secret leaked into STATE_JSON: " .. s)
    for name, v in pairs(m.vars) do
      assert(not tostring(v):find(s, 1, true), sc.name .. ": secret leaked into variable " .. name)
    end
  end
  write(OUT .. "/" .. sc.name .. ".json", sj)
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
  index.scenarios[#index.scenarios + 1] = { name = sc.name, desc = sc.desc, version = st.version,
    state = st.playback.state, kind = st.media.kind, bytes = #sj, lan_images = #lan }
  io.write(string.format("%-11s v%-3d %-8s %-8s %6d bytes  %s\n", sc.name, st.version, st.playback.state,
    st.media.kind, #sj, sc.desc))
  m:destroy()
end

write(OUT .. "/index.json", json.encode(index))
print("wrote " .. #SCENARIOS .. " scenarios to " .. OUT)
