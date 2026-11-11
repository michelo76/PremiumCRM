-- Static consistency: driver.xml <-> Lua glue, variable ID order, referenced files.
local T = ...
local Mock = require("c4_mock")
local flatten = require("np.flatten")
local Vars = require("c4.variables")
local Events = require("c4.events")
local Version = require("c4.version")

local DRIVER = T.root .. "/driver"

local function read(path)
  local f = assert(io.open(path, "rb"), "missing " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

local LUA_FILES = { "driver.lua", "c4/app.lua", "c4/config.lua", "c4/deps.lua", "c4/events.lua", "c4/room.lua",
  "c4/artwork.lua", "c4/httpserver.lua", "c4/status.lua", "c4/diagnostics.lua", "c4/variables.lua",
  "c4/version.lua", "c4/b64.lua" }

local function all_lua()
  local parts = {}
  for _, f in ipairs(LUA_FILES) do parts[#parts + 1] = read(DRIVER .. "/" .. f) end
  return table.concat(parts, "\n")
end

local xml = Mock.parse_driver_xml(DRIVER .. "/driver.xml")

describe("variables (append-only IDs)", function()
  it("flatten.definitions() matches the head of c4.variables.LIST exactly", function()
    local defs = flatten.definitions()
    T.ok(#defs > 0)
    for i, d in ipairs(defs) do
      T.eq(Vars.LIST[i][1], d.name, "variable #" .. i .. " name")
      T.eq(Vars.LIST[i][2], d.type, "variable #" .. i .. " type")
    end
    T.eq(Vars.LIST[#defs + 1][1], "STATE_JSON", "STATE_JSON follows the flatten variables")
  end)
  it("has no duplicate names and only supported types", function()
    local seen = {}
    for _, d in ipairs(Vars.LIST) do
      T.no(seen[d[1]], "duplicate " .. d[1])
      seen[d[1]] = true
      T.ok(({ STRING = 1, NUMBER = 1, BOOL = 1, INT = 1, FLOAT = 1 })[d[2]], d[1] .. " type " .. d[2])
    end
  end)
  it("pins the current order (IDs) -- update ONLY by appending", function()
    local names = {}
    for _, d in ipairs(Vars.LIST) do names[#names + 1] = d[1] end
    T.eq(table.concat(names, ","), "TITLE,SUBTITLE,MEDIA_KIND,SERIES_TITLE,SEASON,EPISODE,EPISODE_TITLE,ARTIST," ..
      "ALBUM,CHANNEL_NAME,CHANNEL_NUMBER,APP_NAME,SOURCE_DEVICE,SOURCE_PROVIDER,PLAY_STATE,IS_PLAYING,IS_PAUSED," ..
      "IS_LIVE,POSITION_SECONDS,DURATION_SECONDS,PROGRESS_PERCENT,VOLUME,YEAR,GENRES,CONTENT_RATING," ..
      "RUNTIME_MINUTES,OVERVIEW,TAGLINE,IMDB_ID,IMDB_RATING,IMDB_URL,ROTTEN_TOMATOES,METACRITIC,DIRECTOR,CAST," ..
      "NETWORK,POSTER_URL,BACKDROP_URL,ARTWORK_URL,LOGO_URL,TRAILER_URL,DISPLAY_LINE_1,DISPLAY_LINE_2,MEDIA_KEY," ..
      "VERSION,LAST_CHANGED,STATE_JSON")
  end)
  it("to_c4 formats BOOL as 1/0 and integral numbers without decimals", function()
    T.eq(Vars.to_c4(true, "BOOL"), "1")
    T.eq(Vars.to_c4(false, "BOOL"), "0")
    T.eq(Vars.to_c4(42, "NUMBER"), "42")
    T.eq(Vars.to_c4(8.5, "NUMBER"), "8.5")
    T.eq(Vars.to_c4(nil, "STRING"), "")
  end)
end)

describe("driver.xml", function()
  it("declares exactly the events c4.events can fire, ids 1..n in order", function()
    T.eq(#xml.event_order, #Events.NAMES)
    for i, name in ipairs(Events.NAMES) do
      T.eq(xml.event_order[i], name)
      T.eq(xml.events[name], i)
    end
  end)
  it("every FireEvent literal in Lua is declared", function()
    local src = all_lua()
    for _, pat in ipairs({ "FireEvent%(%s*[^,\"]-,%s*\"([^\"]+)\"", "FireEvent%(%s*\"([^\"]+)\"" }) do
      for name in src:gmatch(pat) do T.ok(xml.events[name], "undeclared event " .. name) end
    end
    -- the names c4.events can emit
    local ev = read(DRIVER .. "/c4/events.lua")
    for name in ev:gmatch("out%[#out %+ 1%] = \"([^\"]+)\"") do T.ok(xml.events[name], "undeclared " .. name) end
    for name in ev:gmatch("= \"([%w ]+ Started)\"") do T.ok(xml.events[name], "undeclared " .. name) end
  end)
  it("every Properties[...] / UpdateProperty name used in Lua exists in the XML and vice versa", function()
    local src = all_lua()
    local used = {}
    for name in src:gmatch("Properties%[%s*\"([^\"]+)\"%s*%]") do used[name] = true end
    for name in src:gmatch("_update_prop%(%s*\"([^\"]+)\"") do used[name] = true end
    for name in src:gmatch("UpdateProperty%([^\"]-\"([^\"]+)\"") do used[name] = true end
    T.ok(next(used) ~= nil)
    for name in pairs(used) do T.ok(xml.properties[name], "property used in Lua but not in driver.xml: " .. name) end
    for name, p in pairs(xml.properties) do
      if p.type ~= "LABEL" then T.ok(used[name], "property in driver.xml never used in Lua: " .. name) end
    end
  end)
  it("read-only status properties are marked readonly", function()
    for _, n in ipairs({ "Driver Version", "Status", "Active Source", "Metadata Sources", "Web View URL", "LAN URL" }) do
      T.ok(xml.properties[n] and xml.properties[n].readonly, n)
    end
  end)
  it("password properties", function()
    for _, n in ipairs({ "Apple TV Bridge Token", "Home Assistant Token", "TMDB API Key", "OMDb API Key", "Gracenote API Key" }) do
      T.ok(xml.properties[n].password, n)
    end
  end)
  it("actions map to handlers and the Refresh command exists", function()
    local app = read(DRIVER .. "/c4/app.lua")
    T.eq(#xml.actions, 5)
    for _, a in ipairs(xml.actions) do
      T.ok(app:find(a.command .. " = \"_action_", 1, true), "no handler for action " .. a.command)
    end
    T.deep_eq(xml.commands, { "Refresh" })
  end)
  it("version integer matches c4.version", function()
    local maj, min, pat = Version.VERSION:match("^(%d+)%.(%d+)%.(%d+)$")
    T.eq(tonumber(xml.version), maj * 10000 + min * 100 + pat)
  end)
  it("web view URL / icons use the c4z filename and exist in www/", function()
    local raw = xml.raw
    T.contains(raw, "<web_view_url proxybindingid=\"5001\">" .. Version.WEBVIEW_URL .. "</web_view_url>")
    local n = 0
    for path in raw:gmatch("controller://driver/([^<\"]+)") do
      local name, rest = path:match("^([^/]+)/(.+)$")
      T.eq(name, Version.DRIVER_FILENAME)
      local f = io.open(DRIVER .. "/www/" .. rest, "rb")
      T.ok(f, "missing www/" .. rest)
      if f then f:close() end
      n = n + 1
    end
    T.ok(n >= 11)
    for path in raw:gmatch("image_source=\"c4z\">([^<]+)<") do
      local f = io.open(DRIVER .. "/www/" .. path, "rb"); T.ok(f, "missing www/" .. path); if f then f:close() end
    end
    for path in raw:gmatch("_image=\"([^\"]+)\"") do
      local f = io.open(DRIVER .. "/www/" .. path, "rb"); T.ok(f, "missing www/" .. path); if f then f:close() end
    end
  end)
end)
