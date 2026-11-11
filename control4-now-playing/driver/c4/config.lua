--[[
c4.config -- driver Properties -> np.engine config. Pure (no C4 calls): unit-testable.

  local cfg, info = Config.build(Properties, ctx)
    ctx  = { room_id = 12, room_name = "Family Room", room_on = true|false|nil, version = "1.0.0" }
    cfg  = engine config (see np/engine.lua header)
    info = {
      configured = bool,          -- at least one provider (otherwise the engine is not started)
      sources    = { "Roku", ... },    enrichers = { "TMDB", ... },
      warnings   = { "...", ... },     -- half-configured sources etc.
      room_media = bool, gate = bool, gated = bool (room is off and gating is on),
      embed_artwork = bool, lan_port = n, debug_mode = "Off"|...,
      secrets = { ... },          -- token/key strings to redact from logs
      watch_room = bool,          -- room variables must be watched
    }

Every property is optional; defaults match driver.xml.
]]

local M = {}

M.ROOM_PROVIDER_ID = "c4room"
M.ROKU_GROUP = "dev-roku"
M.APPLETV_GROUP = "dev-appletv"

local function trim(s)
  if s == nil then return nil end
  s = tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  return s
end

local function on(v, default)
  v = trim(v)
  if v == nil then return default end
  v = v:lower()
  return v == "on" or v == "true" or v == "yes" or v == "1"
end

local function int(v, default, min, max)
  local n = tonumber(trim(v) or "")
  if not n then return default end
  n = math.floor(n)
  if n < min then n = min end
  if n > max then n = max end
  return n
end

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end
M.urlencode = urlencode

-- "192.168.1.10:8765", "http://x/" -> "http://192.168.1.10:8765" (no trailing slash)
function M.base_url(v)
  v = trim(v)
  if not v then return nil end
  if not v:find("^[%a][%w+.-]*://") then v = "http://" .. v end
  if not v:find("^https?://") then return nil end
  v = v:gsub("/+$", "")
  if not v:match("^https?://[^/]+") then return nil end
  return v
end

-- "http://192.168.1.50:8060/" -> "192.168.1.50", 8060
function M.roku_host(v)
  v = trim(v)
  if not v then return nil end
  v = v:gsub("^%a+://", ""):gsub("/.*$", "")
  local host, port = v:match("^%[?([^%]]+)%]?:(%d+)$")
  if not host then host = v end
  if host == "" or host:find("[%s/]") then return nil end
  return host, tonumber(port)
end

-- TMDB accepts a v3 API key (32 hex chars) or a v4 read access token (a JWT, "eyJ...").
function M.tmdb_auth(key)
  key = trim(key)
  if not key then return nil end
  if key:find("^eyJ") or #key > 64 then return { bearer = key } end
  return { api_key = key }
end

local DEBUG_MODES = { Off = true, Print = true, Log = true, ["Print and Log"] = true }

function M.build(Properties, ctx)
  Properties = Properties or {}
  ctx = ctx or {}
  local info = { sources = {}, enrichers = {}, warnings = {}, secrets = {} }
  local providers = {}
  local function secret(v) if v then info.secrets[#info.secrets + 1] = v end end

  -- Room
  local room_media = on(Properties["Use Control4 Room Media"], true)
  local gate = on(Properties["Show Only When Room Is On"], false)
  info.room_media, info.gate = room_media, gate
  info.watch_room = room_media or gate

  -- Home Assistant grouping
  local ha_is = trim(Properties["Home Assistant Entity Is"]) or "Separate Device"

  -- Roku
  local roku_host, roku_port = M.roku_host(Properties["Roku Address"])
  local roku_group
  if roku_host then
    if ha_is == "Same Device As Roku" then roku_group = M.ROKU_GROUP end
    providers[#providers + 1] = {
      type = "roku", id = "roku", host = roku_host, port = roku_port,
      name = trim(Properties["Roku Name"]), group = roku_group,
    }
    info.sources[#info.sources + 1] = "Roku"
  elseif trim(Properties["Roku Address"]) then
    info.warnings[#info.warnings + 1] = "Roku Address is not a valid host"
  end

  -- Apple TV (companion bridge)
  local atv_base = M.base_url(Properties["Apple TV Bridge URL"])
  local atv_dev = trim(Properties["Apple TV Device"])
  local atv_token = trim(Properties["Apple TV Bridge Token"])
  local atv_group
  secret(atv_token)
  if atv_base and atv_dev then
    if ha_is == "Same Device As Apple TV" then atv_group = M.APPLETV_GROUP end
    local headers = { Accept = "application/json" }
    if atv_token then headers.Authorization = "Bearer " .. atv_token end
    providers[#providers + 1] = {
      type = "bridge", id = "appletv", url = atv_base .. "/v1/devices/" .. urlencode(atv_dev) .. "/now-playing",
      provider_name = "appletv", headers = headers, group = atv_group,
    }
    info.sources[#info.sources + 1] = "Apple TV"
    info.appletv_base = atv_base
  elseif atv_base or atv_dev then
    info.warnings[#info.warnings + 1] = atv_base and "Apple TV Device is empty"
      or "Apple TV Bridge URL is empty or invalid"
  end

  -- Home Assistant
  local ha_base = M.base_url(Properties["Home Assistant URL"])
  local ha_token = trim(Properties["Home Assistant Token"])
  local ha_entity = trim(Properties["Home Assistant Entity ID"])
  secret(ha_token)
  if ha_base and ha_token and ha_entity then
    local group
    if ha_is == "Same Device As Roku" then
      if roku_group then group = roku_group
      else info.warnings[#info.warnings + 1] = "Home Assistant Entity Is 'Same Device As Roku' but no Roku is set" end
    elseif ha_is == "Same Device As Apple TV" then
      if atv_group then group = atv_group
      else info.warnings[#info.warnings + 1] = "Home Assistant Entity Is 'Same Device As Apple TV' but no Apple TV is set" end
    end
    providers[#providers + 1] = {
      type = "homeassistant", id = "homeassistant", base_url = ha_base, token = ha_token,
      entity_id = ha_entity, group = group,
    }
    info.sources[#info.sources + 1] = "Home Assistant"
  elseif ha_base or ha_token or ha_entity then
    local missing = {}
    if not ha_base then missing[#missing + 1] = "URL" end
    if not ha_token then missing[#missing + 1] = "Token" end
    if not ha_entity then missing[#missing + 1] = "Entity ID" end
    info.warnings[#info.warnings + 1] = "Home Assistant " .. table.concat(missing, ", ") .. " missing"
  end

  -- Control4 room media: last, so dedicated providers win ties.
  local room_provider = {
    type = "static", id = M.ROOM_PROVIDER_ID, provider_name = "c4room", name = ctx.room_name,
  }
  if room_media then
    providers[#providers + 1] = room_provider
    info.sources[#info.sources + 1] = "Control4 Room"
  end

  info.configured = #providers > 0

  -- Gating: room off -> only the (empty / off) room provider remains -> state "off".
  info.gated = gate and ctx.room_on == false
  if info.gated then providers = { room_provider } end

  -- Enrichment
  local lang = trim(Properties["Metadata Language"]) or "en-US"
  local country = (trim(Properties["Content Rating Country"]) or "US"):upper()
  local enrich = { cache = { max = 50, ttl_s = 21600, negative_ttl_s = 600, persist = true } }
  local tmdb = M.tmdb_auth(Properties["TMDB API Key"])
  if tmdb then
    tmdb.language, tmdb.country = lang, country
    enrich.tmdb = tmdb
    secret(tmdb.api_key or tmdb.bearer)
    info.enrichers[#info.enrichers + 1] = "TMDB"
  end
  local omdb = trim(Properties["OMDb API Key"])
  if omdb then
    enrich.omdb = { api_key = omdb }
    secret(omdb)
    info.enrichers[#info.enrichers + 1] = "OMDb"
  end
  local gn = trim(Properties["Gracenote API Key"])
  if gn then
    enrich.gracenote = { api_key = gn, lineup_id = trim(Properties["Gracenote Lineup ID"]) }
    secret(gn)
    info.enrichers[#info.enrichers + 1] = "Gracenote"
  end
  local music = on(Properties["Music Lookup"], true)
  enrich.music = {
    enabled = music, musicbrainz = true, country = country,
    user_agent = "NowPlayingInfo-Control4/" .. tostring(ctx.version or "1") .. " (Control4 DriverWorks driver)",
  }
  if music then info.enrichers[#info.enrichers + 1] = "Music (iTunes/MusicBrainz)" end

  local active_s = int(Properties["Poll Interval Playing"], 2, 1, 30)
  local idle_s = int(Properties["Poll Interval Idle"], 5, 2, 120)

  info.embed_artwork = on(Properties["Embed LAN Artwork"], true)
  info.lan_port = int(Properties["LAN Web Port"], 0, 0, 65535)
  local dm = trim(Properties["Debug Mode"]) or "Off"
  info.debug_mode = DEBUG_MODES[dm] and dm or "Off"

  local cfg = {
    room = { id = ctx.room_id, name = ctx.room_name },
    providers = providers,
    enrich = enrich,
    poll = { active_s = active_s, idle_s = idle_s },
    sticky_s = 10, stale_s = 10, enrich_debounce_s = 1.5, seek_threshold_s = 3,
  }
  return cfg, info
end

return M
