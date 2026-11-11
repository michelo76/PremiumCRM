--[[
Live smoke test for the KEYLESS enrichers (iTunes Search + MusicBrainz) using a curl-backed
deps implementation. NOT part of the default run (needs internet + curl).

  lua tests/live/smoke.lua                       # Blinding Lights / The Weeknd
  lua tests/live/smoke.lua "So What" "Miles Davis"

Exit code 0 when iTunes matched; prints the merged details JSON.
]]

local script = arg and arg[0] or "tests/live/smoke.lua"
local live_dir = script:match("^(.*)[/\\][^/\\]*$") or "."
local root = live_dir .. "/../.."
package.path = root .. "/driver/?.lua;" .. package.path

local json = require("np.json")
local Pipeline = require("np.enrich.pipeline")
local schema = require("np.schema")
local pbm = require("np.playback")

local function shell_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local clock = os.time()
local timers = {}

local deps
deps = {
  json = json,
  now = function() return clock end,
  log = function(level, msg) io.stderr:write("[" .. level .. "] " .. msg .. "\n") end,
  set_timer = function(sec, fn)
    local t = { at = clock + sec, fn = fn }
    t.cancel = function(h) h.cancelled = true end
    timers[#timers + 1] = t
    return t
  end,
  http = {
    request = function(req, cb)
      local args = { "curl", "-sS", "-m", tostring(req.timeout or 8), "-w", shell_quote("\n%{http_code}") }
      for k, v in pairs(req.headers or {}) do args[#args + 1] = "-H " .. shell_quote(k .. ": " .. v) end
      args[#args + 1] = shell_quote(req.url)
      local f = io.popen(table.concat(args, " ") .. " 2>&1")
      local out = f:read("*a")
      f:close()
      local body, code = out:match("^(.*)\n(%d%d%d)$")
      -- deliver asynchronously (next timer tick), as the contract requires
      deps.set_timer(0, function()
        if not code or code == "000" then return cb("curl failed: " .. out:sub(1, 200)) end
        cb(nil, { status = tonumber(code), headers = {}, body = body })
      end)
    end,
  },
}

local function run_timers()
  while true do
    local best, bi
    for i, t in ipairs(timers) do
      if not t.cancelled and (not best or t.at < best.at) then best, bi = t, i end
    end
    if not best then return end
    table.remove(timers, bi)
    if best.at > clock then
      os.execute("sleep " .. string.format("%.2f", best.at - clock))
      clock = best.at
    end
    if not best.cancelled then best.fn() end
  end
end

local title = arg[1] or "Blinding Lights"
local artist = arg[2] or "The Weeknd"
local p = Pipeline.new({ music = { enabled = true, musicbrainz = true } }, deps)
local pb = pbm.normalize({ playback = { state = "playing" }, media = { kind = "music", title = title, artist = artist } }, clock)
local result, info
p:lookup(pb, "live", function(d, i) result, info = d, i end)
run_timers()

if info and info.errors and #info.errors > 0 then print("errors: " .. table.concat(info.errors, "; ")) end
if not result then
  print("NO MATCH")
  os.exit(1)
end
print(schema.encode_details(result))
os.exit(0)
