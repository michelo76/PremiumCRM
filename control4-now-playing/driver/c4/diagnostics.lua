--[[
c4.diagnostics -- "Test Metadata Sources" action: one small request per configured source /
enricher, reporting OK or the reason it failed. Keys and tokens are never printed.

  Diag.run(cfg, deps, out, done)    out(line) per result; done(results) at the end
  Diag.checks(cfg) -> list of { name, req, judge(status, body, data) -> ok, detail }
]]

local net = require("np.net")
local util = require("np.util")
local json = require("np.json")

local M = {}

local function decode(body)
  local ok, v = pcall(json.decode, body or "")
  if ok and type(v) == "table" then return v end
  return nil
end

local function http_judge(status)
  if status == 401 or status == 403 then return false, "rejected credentials (HTTP " .. status .. ")" end
  if status == 404 then return false, "not found (HTTP 404)" end
  if status < 200 or status >= 300 then return false, "HTTP " .. status end
  return true
end

function M.checks(cfg)
  local list = {}
  for _, p in ipairs(cfg.providers or {}) do
    if p.type == "roku" then
      list[#list + 1] = {
        name = "Roku (" .. p.host .. ")",
        req = { url = "http://" .. p.host .. ":" .. tostring(p.port or 8060) .. "/query/device-info", timeout = 5 },
        judge = function(status, body)
          if status == 403 then return false, require("np.providers.roku").ERR_403 end
          local ok, why = http_judge(status)
          if not ok then return ok, why end
          local name = body:match("<friendly%-device%-name>([^<]*)<") or body:match("<user%-device%-name>([^<]*)<")
          local power = body:match("<power%-mode>([^<]*)<")
          return true, util.join({ n = 2, name, power and ("power " .. power) or nil }, ", ")
        end,
      }
    elseif p.type == "bridge" then
      list[#list + 1] = {
        name = "Apple TV bridge",
        req = { url = p.url, headers = p.headers, timeout = 5 },
        judge = function(status, body)
          if status == 404 then
            local d = decode(body)
            return false, "device not found on the bridge (" .. tostring(d and d.error or "HTTP 404") ..
              "): check Apple TV Device against GET /v1/devices"
          end
          if status == 401 then return false, "bridge rejected the token (HTTP 401): check Apple TV Bridge Token" end
          local ok, why = http_judge(status)
          if not ok then return ok, why end
          local d = decode(body)
          if not d or type(d.playback) ~= "table" then return false, "unexpected response (not a now-playing document)" end
          return true, "state " .. tostring(d.playback.state) .. (d.source and d.source.device_name and
            (" on " .. tostring(d.source.device_name)) or "")
        end,
      }
    elseif p.type == "homeassistant" then
      list[#list + 1] = {
        name = "Home Assistant (" .. p.entity_id .. ")",
        req = { url = p.base_url .. "/api/states/" .. p.entity_id, timeout = 5,
          headers = { Authorization = "Bearer " .. p.token, Accept = "application/json" } },
        judge = function(status, body)
          if status == 401 then return false, require("np.providers.homeassistant").ERR_AUTH end
          if status == 404 then return false, "entity " .. p.entity_id .. " not found" end
          local ok, why = http_judge(status)
          if not ok then return ok, why end
          local d = decode(body)
          return true, "state " .. tostring(d and d.state)
        end,
      }
    end
  end
  local e = cfg.enrich or {}
  if e.tmdb then
    local req = { url = "https://api.themoviedb.org/3/configuration", timeout = 8, headers = { Accept = "application/json" } }
    if e.tmdb.bearer then req.headers.Authorization = "Bearer " .. e.tmdb.bearer
    else req.url = req.url .. "?api_key=" .. util.urlencode(e.tmdb.api_key) end
    list[#list + 1] = { name = "TMDB", req = req, judge = function(status)
      if status == 401 then return false, "API key rejected (HTTP 401): use the v3 API key or v4 read access token from themoviedb.org > Settings > API" end
      return http_judge(status)
    end }
  end
  if e.omdb then
    list[#list + 1] = {
      name = "OMDb",
      req = { url = "https://www.omdbapi.com/?i=tt0111161&apikey=" .. util.urlencode(e.omdb.api_key), timeout = 8 },
      judge = function(status, body)
        local d = decode(body)
        if d and d.Response == "False" then return false, tostring(d.Error) end
        local ok, why = http_judge(status)
        if not ok then return ok, why end
        if not d then return false, "invalid JSON" end
        return true, "IMDb rating " .. tostring(d.imdbRating)
      end,
    }
  end
  if e.gracenote then
    local url
    if e.gracenote.lineup_id then
      url = "http://data.tmsapi.com/v1.1/lineups/" .. util.urlencode(e.gracenote.lineup_id) ..
        "/channels?api_key=" .. util.urlencode(e.gracenote.api_key)
    else
      url = "http://data.tmsapi.com/v1.1/programs/search?q=Inception&entityType=movie&api_key=" ..
        util.urlencode(e.gracenote.api_key)
    end
    list[#list + 1] = { name = "Gracenote", req = { url = url, timeout = 8 }, judge = function(status)
      return http_judge(status)
    end }
  end
  if e.music and e.music.enabled ~= false then
    list[#list + 1] = {
      name = "Music lookup (iTunes)",
      req = { url = "https://itunes.apple.com/search?term=test&entity=song&limit=1", timeout = 8 },
      judge = function(status, body)
        local ok, why = http_judge(status)
        if not ok then return ok, why end
        local d = decode(body)
        if not d then return false, "invalid JSON" end
        return true
      end,
    }
  end
  return list
end

function M.run(cfg, deps, out, done)
  local checks = M.checks(cfg)
  local results = {}
  local pending = #checks
  if pending == 0 then
    out("Test Metadata Sources: nothing configured")
    if done then done(results) end
    return
  end
  out("Test Metadata Sources: running " .. pending .. " check(s)...")
  for i, c in ipairs(checks) do
    c.req.method = "GET"
    net.request(deps, c.req, function(err, resp)
      local ok, detail
      if err then
        ok, detail = false, "unreachable: " .. tostring(err)
      else
        local pok, a, b = pcall(c.judge, tonumber(resp.status) or 0, resp.body or "")
        if pok then ok, detail = a, b else ok, detail = false, "check crashed: " .. tostring(a) end
      end
      results[i] = { name = c.name, ok = ok, detail = detail }
      out(deps.redact(string.format("  %-28s %s%s", c.name, ok and "OK" or "FAILED",
        (detail and detail ~= "") and (" - " .. detail) or "")))
      pending = pending - 1
      if pending == 0 and done then done(results) end
    end)
  end
end

return M
