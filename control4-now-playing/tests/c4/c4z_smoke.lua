--[[
Smoke test for a BUILT package: loads driver.lua from an unzipped c4z tree with the C4 mock,
proving that dotted requires (np.engine, c4.app, ...) and www/ files resolve from the package
layout alone (package.path points ONLY at the unzipped tree; the mock lives in tests/c4).

  python3 tools/build.py
  mkdir -p /tmp/x && cd /tmp/x && unzip -o .../build/now_playing_info.c4z
  lua5.1 tests/c4/c4z_smoke.lua /tmp/x        (or luajit)
Exit code 0 on success.
]]

local dir = assert(arg[1], "usage: c4z_smoke.lua <unzipped c4z dir>")
local script = arg[0]
local here = script:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. here .. "/?.lua"
package.cpath = ""

local Mock = require("c4_mock")
local failures = 0
local function check(cond, msg)
  if cond then io.write("  ok   ", msg, "\n") else failures = failures + 1; io.write("  FAIL ", msg, "\n") end
end

local m = Mock.new({ root = dir })
m.Properties["Roku Address"] = "192.168.1.50"
m.Properties["LAN Web Port"] = "8080"
m:route("/query/device-info", { status = 200, body = [[<?xml version="1.0"?><device-info><user-device-name>Den Roku</user-device-name><power-mode>PowerOn</power-mode></device-info>]] })
m:route("/query/active-app", { status = 200, body = [[<active-app><app id="12" type="appl">Netflix</app></active-app>]] })
m:route("/query/media-player", { status = 200, body = [[<player error="false" state="play"><plugin id="12" name="Netflix"/><position>60000 ms</position><duration>3600000 ms</duration><is_live>false</is_live></player>]] })
m.devices[100].vars = { [1010] = "1", [1031] = "" }
m:start()
m:advance(5)

io.write("c4z smoke test: ", dir, "\n")
check(#m.violations == 0, "no forbidden calls in OnDriverInit")
check(#m.added_vars == 47 and m.added_vars[47].name == "STATE_JSON", "47 variables, STATE_JSON last")
check(#m.errors == 0, "no errors logged" .. (#m.errors > 0 and (": " .. m.errors[1]) or ""))
check(m.vars.PLAY_STATE == "playing" and m.vars.APP_NAME == "Netflix", "Roku state published (" .. tostring(m.vars.PLAY_STATE) .. ", " .. tostring(m.vars.APP_NAME) .. ")")
check(m.vars.STATE_JSON:find('"sent_at":', 1, true) ~= nil, "STATE_JSON published with sent_at")
check(#m:proxy_cmds("URL_CHANGED") == 1, "URL_CHANGED sent")
check(#m:proxy_cmds("ICON_CHANGED") == 1, "ICON_CHANGED sent")

-- every loaded driver module came from the unzipped tree
local function from_pkg(modname)
  local mod = package.loaded[modname]
  if type(mod) ~= "table" then return false end
  for _, v in pairs(mod) do
    if type(v) == "function" then
      local src = debug.getinfo(v, "S").source
      return src:sub(1, #dir + 1) == "@" .. dir
    end
  end
  return false
end
for _, mod in ipairs({ "c4.app", "c4.config", "c4.room", "np.engine", "np.providers.roku", "np.enrich.pipeline", "np.json" }) do
  check(from_pkg(mod), "require('" .. mod .. "') resolved inside the package")
end

-- www/ from the package through the LAN server (C4:FileOpen("www/index.html"))
m:connect(1); m:client_send(1, "GET / HTTP/1.1\r\n\r\n")
check(m:response(1):find("^HTTP/1.1 200") ~= nil and m:response(1):find("<html", 1, true) ~= nil, "www/index.html served from the package")
m:connect(2); m:client_send(2, "GET /api/state HTTP/1.1\r\n\r\n")
check(m:response(2):find('"app_name":"Netflix"', 1, true) ~= nil, "/api/state served")

-- stamped by the build
local ver = require("c4.version")
check(ver.BUILD_DATE ~= "dev", "version.lua BUILD_DATE stamped (" .. ver.BUILD_DATE .. ")")
check(m.xml.version == "10000", "driver.xml <version> stamped (" .. tostring(m.xml.version) .. ")")
check(m.updated_props["Driver Version"] == ver.string(), "Driver Version property = " .. tostring(m.updated_props["Driver Version"]))

m:destroy()
check(m:pending_timers() == 0, "destroy cancels all timers")
print(failures == 0 and "c4z smoke test PASSED" or ("c4z smoke test FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
