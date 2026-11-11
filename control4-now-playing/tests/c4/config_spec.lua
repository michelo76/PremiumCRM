local T = ...
local Config = require("c4.config")
local Mock = require("c4_mock")

local xml = Mock.parse_driver_xml(T.root .. "/driver/driver.xml")
local function defaults(over)
  local p = {}
  for name, d in pairs(xml.properties) do p[name] = d.default end
  for k, v in pairs(over or {}) do p[k] = v end
  return p
end
local CTX = { room_id = 100, room_name = "Living Room", version = "1.0.0" }

local function find(cfg, typ)
  for _, p in ipairs(cfg.providers) do if p.type == typ then return p end end
end

describe("c4.config.build", function()
  it("defaults: only Control4 room media, music lookup on, sensible polls", function()
    local cfg, info = Config.build(defaults(), CTX)
    T.eq(#cfg.providers, 1)
    T.eq(cfg.providers[1].type, "static")
    T.eq(cfg.providers[1].id, "c4room")
    T.eq(cfg.providers[1].name, "Living Room")
    T.ok(info.configured)
    T.ok(info.watch_room)
    T.deep_eq(cfg.room, { id = 100, name = "Living Room" })
    T.deep_eq(cfg.poll, { active_s = 2, idle_s = 5 })
    T.eq(cfg.enrich.music.enabled, true)
    T.is_nil(cfg.enrich.tmdb)
    T.deep_eq(info.enrichers, { "Music (iTunes/MusicBrainz)" })
    T.eq(info.embed_artwork, true)
    T.eq(info.lan_port, 0)
    T.eq(info.debug_mode, "Off")
  end)
  it("works with an empty Properties table (all optional)", function()
    local cfg, info = Config.build({}, {})
    T.eq(#cfg.providers, 1)
    T.ok(info.configured)
  end)
  it("nothing configured when room media is off and no source is set", function()
    local cfg, info = Config.build(defaults({ ["Use Control4 Room Media"] = "Off" }), CTX)
    T.eq(#cfg.providers, 0)
    T.no(info.configured)
    T.no(info.watch_room)
  end)
  it("Roku address normalisation", function()
    local cfg = Config.build(defaults({ ["Roku Address"] = " http://192.168.1.50:8060/ ", ["Roku Name"] = "LR Roku" }), CTX)
    local r = find(cfg, "roku")
    T.eq(r.host, "192.168.1.50"); T.eq(r.port, 8060); T.eq(r.name, "LR Roku")
    T.eq(cfg.providers[#cfg.providers].type, "static", "room media is last (loses ties)")
    local cfg2 = Config.build(defaults({ ["Roku Address"] = "roku.local" }), CTX)
    T.eq(find(cfg2, "roku").host, "roku.local"); T.is_nil(find(cfg2, "roku").port)
  end)
  it("Apple TV bridge: url-encoded device id + bearer token header", function()
    local cfg, info = Config.build(defaults({
      ["Apple TV Bridge URL"] = "192.168.1.10:8765/", ["Apple TV Device"] = "AA:BB Living Room",
      ["Apple TV Bridge Token"] = "s3cret-token",
    }), CTX)
    local b = find(cfg, "bridge")
    T.eq(b.url, "http://192.168.1.10:8765/v1/devices/AA%3ABB%20Living%20Room/now-playing")
    T.eq(b.provider_name, "appletv")
    T.eq(b.headers.Authorization, "Bearer s3cret-token")
    T.ok(info.secrets[1] == "s3cret-token")
  end)
  it("half-configured Apple TV / Home Assistant produce warnings, not providers", function()
    local cfg, info = Config.build(defaults({ ["Apple TV Bridge URL"] = "http://x:8765", ["Home Assistant URL"] = "http://ha:8123" }), CTX)
    T.is_nil(find(cfg, "bridge")); T.is_nil(find(cfg, "homeassistant"))
    T.eq(#info.warnings, 2)
    T.contains(info.warnings[2], "Token, Entity ID")
  end)
  it("Home Assistant separate / same device as Roku / same device as Apple TV", function()
    local base = { ["Home Assistant URL"] = "http://ha.local:8123/", ["Home Assistant Token"] = "tok12345",
      ["Home Assistant Entity ID"] = "media_player.lr", ["Roku Address"] = "10.0.0.5",
      ["Apple TV Bridge URL"] = "http://10.0.0.9:8765", ["Apple TV Device"] = "lr" }
    local cfg = Config.build(defaults(base), CTX)
    local ha = find(cfg, "homeassistant")
    T.eq(ha.base_url, "http://ha.local:8123"); T.eq(ha.token, "tok12345"); T.is_nil(ha.group)
    T.is_nil(find(cfg, "roku").group)

    base["Home Assistant Entity Is"] = "Same Device As Roku"
    cfg = Config.build(defaults(base), CTX)
    T.eq(find(cfg, "homeassistant").group, Config.ROKU_GROUP)
    T.eq(find(cfg, "roku").group, Config.ROKU_GROUP)
    T.is_nil(find(cfg, "bridge").group)

    base["Home Assistant Entity Is"] = "Same Device As Apple TV"
    cfg = Config.build(defaults(base), CTX)
    T.eq(find(cfg, "homeassistant").group, Config.APPLETV_GROUP)
    T.eq(find(cfg, "bridge").group, Config.APPLETV_GROUP)
    T.is_nil(find(cfg, "roku").group)

    base["Roku Address"] = ""
    base["Home Assistant Entity Is"] = "Same Device As Roku"
    local _, info = Config.build(defaults(base), CTX)
    T.contains(table.concat(info.warnings, ";"), "no Roku is set")
  end)
  it("TMDB key: v3 key vs v4 bearer JWT", function()
    T.deep_eq(Config.tmdb_auth("0123456789abcdef0123456789abcdef"), { api_key = "0123456789abcdef0123456789abcdef" })
    T.deep_eq(Config.tmdb_auth("eyJhbGciOiJIUzI1NiJ9.x.y"), { bearer = "eyJhbGciOiJIUzI1NiJ9.x.y" })
    T.deep_eq(Config.tmdb_auth(string.rep("a", 80)), { bearer = string.rep("a", 80) })
    T.is_nil(Config.tmdb_auth("  "))
  end)
  it("enrichers, language, country, music off", function()
    local cfg, info = Config.build(defaults({
      ["TMDB API Key"] = "k3y0123456789", ["OMDb API Key"] = "omdbkey1", ["Gracenote API Key"] = "gnkey123",
      ["Gracenote Lineup ID"] = "USA-OTA22201-DEFAULT", ["Music Lookup"] = "Off", ["Metadata Language"] = "de-DE",
      ["Content Rating Country"] = "de",
    }), CTX)
    T.deep_eq(cfg.enrich.tmdb, { api_key = "k3y0123456789", language = "de-DE", country = "DE" })
    T.deep_eq(cfg.enrich.omdb, { api_key = "omdbkey1" })
    T.deep_eq(cfg.enrich.gracenote, { api_key = "gnkey123", lineup_id = "USA-OTA22201-DEFAULT" })
    T.eq(cfg.enrich.music.enabled, false)
    T.deep_eq(info.enrichers, { "TMDB", "OMDb", "Gracenote" })
    T.eq(#info.secrets, 3)
  end)
  it("poll intervals and port are clamped", function()
    local cfg, info = Config.build(defaults({ ["Poll Interval Playing"] = "0", ["Poll Interval Idle"] = "999",
      ["LAN Web Port"] = "70000" }), CTX)
    T.deep_eq(cfg.poll, { active_s = 1, idle_s = 120 })
    T.eq(info.lan_port, 65535)
    cfg = Config.build(defaults({ ["Poll Interval Playing"] = "junk" }), CTX)
    T.eq(cfg.poll.active_s, 2)
  end)
  it("room gating: room off -> only the room provider remains", function()
    local over = { ["Roku Address"] = "10.0.0.5", ["Show Only When Room Is On"] = "On" }
    local ctx = { room_id = 1, room_name = "R", room_on = false }
    local cfg, info = Config.build(defaults(over), ctx)
    T.ok(info.gated); T.ok(info.configured)
    T.eq(#cfg.providers, 1); T.eq(cfg.providers[1].id, "c4room")
    ctx.room_on = true
    cfg, info = Config.build(defaults(over), ctx)
    T.no(info.gated); T.eq(#cfg.providers, 2)
    ctx.room_on = nil -- unknown -> not gated
    cfg, info = Config.build(defaults(over), ctx)
    T.no(info.gated)
    over["Use Control4 Room Media"] = "Off"
    ctx.room_on = false
    cfg, info = Config.build(defaults(over), ctx)
    T.ok(info.watch_room, "gate needs room power even with room media off")
    T.eq(cfg.providers[1].id, "c4room")
  end)
  it("base_url rejects junk", function()
    T.is_nil(Config.base_url("ftp://x"))
    T.is_nil(Config.base_url(""))
    T.eq(Config.base_url("https://ha.example.com:8123//"), "https://ha.example.com:8123")
  end)
end)
