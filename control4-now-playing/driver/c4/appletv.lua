--[[
c4.appletv -- the owner's "SmartBuildOS Apple TV Native" driver (smartbuildos_appletv_native.c4z,
Beta 120+) as a now-playing source, read through its published variable contract. No pairing,
no Python bridge: both drivers run on the same controller.

The contract (from the Apple TV driver's author):
  * The variables live on the MAIN Apple TV driver device (the protocol device), not on its
    media_player (5000), media_service "Apple TV Apps & Search" (5001) or avswitch "App
    Switcher" (5002) proxies. Their ids are registered dynamically: resolve them by exact NAME.
  * All are read-only STRING variables; missing fields are "".
      NOW_PLAYING_TITLE  _SERIES  _SEASON  _EPISODE  _ARTIST  _ALBUM  _APP_NAME  _APP_ID
      NOW_PLAYING_PLAY_STATE   Playing|Paused|Stopped|Interrupted|Seeking|Unknown ("" = cleared)
      NOW_PLAYING_POSITION     seconds at the last metadata observation ("0" = unknown)
      NOW_PLAYING_DURATION     seconds ("0" = unknown)
      NOW_PLAYING_ARTWORK_URL  https artwork URL reported by the app, or ""
      NOW_PLAYING_UPDATED_AT   controller epoch seconds of the observation ("0" when cleared)
      NOW_PLAYING_VALID        "1" observed snapshot, "0" cleared (VALID=1 does not imply a title)
      NOW_PLAYING_REVISION     incremented per snapshot; resets when that driver's module reloads
  * Event 19 "Now Playing snapshot updated" fires (C4:FireEvent(19), no payload) after every
    snapshot write; a change of NOW_PLAYING_REVISION is an equally good trigger.
  * Licensed and unrestricted builds ship as the SAME file (smartbuildos_appletv_native.c4z); their
    display name / model may differ. Identification never looks at names: a device "is" an Apple
    TV Native driver when it exposes NOW_PLAYING_REVISION. The accepted driver file names (only
    used to FIND candidates) are M.C4Z_NAMES -- one line per variant (keep driver.xml's
    DEVICE_SELECTOR <items> in step; tests/c4/appletv_spec.lua checks that).

Observing event 19 (verified in Snap One's docs-driverworks-api, 7_event/_5-RegisterDeviceEvent.md
and _4.1-OnDeviceEvent.md, both "Available in 2.9.0"): C4:RegisterDeviceEvent(deviceId, eventId)
registers a driver for ANOTHER device's event; Director then calls OnDeviceEvent(firingDeviceId,
eventId). C4:FireEvent itself (7_event/_3-FireEvent.md) only fires the event on the firing driver;
it is not a broadcast. The docs note the API is meant for drivers "created in support of one
another" (the event id must be known -- here it is part of the contract). So: event 19 is
registered (guarded: a missing/failing API only logs) AND the REVISION variable listener stays the
primary trigger; the programming command "Refresh Apple TV Now Playing" is the Composer fallback.
  * Not used on purpose: PLAYBACK_POSITION (a ~1/s local estimate; we extrapolate ourselves from
    POSITION + UPDATED_AT, same controller clock) and event 12 NOW_PLAYING_CHANGED (title only).

Receiver rules implemented here: read the snapshot when connecting; re-read on every REVISION
change (variable listener), on event 19 (OnDeviceEvent) and on Refresh; read REVISION before and after the fields and retry
when it moved (MAX_TRIES; a read that never settles is NOT published -- it is retried RETRY_S
later, and the next REVISION notification triggers a read anyway); VALID=0 clears what is shown; a
REVISION lower than the last applied one is a driver restart (variable ids may have changed: the
name map is rebuilt and the listener re-registered). The SAME revision with different content
(a reset that landed on the applied number, seen by the safety poll or event 19) is confirmed by
a second read RETRY_S later and then applied as a restart. A failed or implausible read (REVISION not a
number, VALID not 0/1: a stale name map) also rebuilds the map once. A safety poll (POLL_S)
rebuilds the name map and re-reads REVISION in case a notification was missed or the ids moved.

Staleness: when the Apple TV driver stops updating while VALID=1 we cannot tell (a paused movie
legitimately produces no updates), so the last snapshot stays until it is cleared or replaced.
Position extrapolation while Playing is bounded instead (np.flatten.MAX_EXTRAPOLATE_S, the page's
EXTRAP_MAX_S): never past the duration, never more than 4 h past UPDATED_AT.

Numbers (POSITION, DURATION, UPDATED_AT, SEASON, EPISODE, REVISION) are parsed strictly: plain
decimal (optionally with a fraction / exponent), no sign, no hex, no nan/inf, within a plausible
range; anything else is "unknown" (nil), never an error and never a negative/NaN/inf value.

Pure helpers
  AppleTV.to_playback(snap, opts) -> playback (np.playback shape)
      snap = { TITLE = "...", ..., REVISION = "42" } (names without the NOW_PLAYING_ prefix)
      opts = { device_name = "...", now = epoch }
  AppleTV.var_map(vars)    -> { [NAME] = id | true }  (C4:GetDeviceVariables result, any shape)
  AppleTV.app_name(name, id) -> display name for the app
  AppleTV.ids(v)           -> list of device ids from a GetDevicesByC4iName-style table
  AppleTV.plausible(snap)  -> ok, why   (VALID is 0/1/"", UPDATED_AT numeric/"")
Watcher (C4 injected)
  local w = AppleTV.new(C4, deps, on_change)      on_change(watcher) after each applied snapshot
                                                   or status change
  w:configure({ selected = n, override = n, name = "..." } | nil)   (idempotent)
  w:stop()
  w:on_variable(idDevice, idVariable, strValue) -> true when handled
  w:on_device_event(idDevice, idEvent) -> true when handled (event 19 of the device being read)
  w:read(reason, force)   re-read now (force: re-apply even when REVISION is unchanged); never
                          re-entrant (a read requested during a read runs right after it)
  w:playback()            the current playback (an "off" playback while nothing is resolved)
  w:status_text()         for the read-only "Apple TV Driver Status" property
  w:report()              lines + ok for "Test Metadata Sources"

C4 APIs (Snap One DriverWorks API reference, docs-driverworks-api):
  required  C4:GetDeviceVariables(id)        22_miscellaneous/_12 (2.8.0): "all of the variables ... as
                                              well as all of the information for each"; the exact
                                              table shape is NOT documented: var_map() accepts
                                              {[varId]={name=,value=}} (expected), {[i]={id=,name=}},
                                              {[NAME]={id=|value=}} and {[NAME]=value}
            C4:GetDeviceVariable(dev, varId) / C4:RegisterVariableListener / UnregisterVariableListener
            C4:GetDeviceDisplayName(id)
            C4:RegisterDeviceEvent / UnregisterDeviceEvent(dev, 19)   7_event/_5, _7 (2.9.0)
            (all calls go through W:_call: a missing API or an error is "not available")
  optional  C4:GetDevicesByC4iName(c4z)      25_proxy/_4 (1.6.0): table of device ids
  (guarded) C4:GetDevices({DeviceIds=...} | {C4iNames=...})   22_miscellaneous/_9 (2.10.0): a
                                              proxy's entry carries a `protocol` sub-table, a
                                              protocol driver's a `proxies` one
            C4:GetProxyDevicesById(id)       25_proxy/_2 (1.6.0): the proxies of a device
]]

local util = require("np.util")
local playback_mod = require("np.playback")

local M = {}

-- Driver file names used to FIND Apple TV Native devices (GetDevicesByC4iName / GetDevices).
-- Licensed and unrestricted builds are both packaged as smartbuildos_appletv_native.c4z; a
-- variant with another file name is one more line here (+ driver.xml DEVICE_SELECTOR <items>).
-- The Device ID override and the selector work for any file name: what identifies the driver is
-- the NOW_PLAYING_REVISION variable, never a name or model string.
M.C4Z_NAMES = {
  "smartbuildos_appletv_native.c4z",
}
M.C4Z = M.C4Z_NAMES[1]
M.EVENT_ID = 19 -- "Now Playing snapshot updated"
M.PREFIX = "NOW_PLAYING_"
M.FIELDS = { "TITLE", "SERIES", "SEASON", "EPISODE", "ARTIST", "ALBUM", "APP_NAME", "APP_ID", "PLAY_STATE",
  "POSITION", "DURATION", "ARTWORK_URL", "UPDATED_AT", "VALID" }
M.REVISION = "REVISION"
M.POLL_S = 30
M.MAX_TRIES = 3
M.MOVIE_MIN_DURATION_S = 60 * 60 -- same threshold as the pyatv bridge (bridge/atv_bridge/mapping.py)
M.MAX_SECONDS = 30 * 86400        -- POSITION / DURATION beyond this are implausible -> unknown
M.MAX_EPOCH = 1e10                -- UPDATED_AT beyond this (year 2286) is implausible -> unknown
M.MAX_COUNT = 1e6                 -- season / episode numbers beyond this -> unknown

M.STATES = {
  playing = "playing", paused = "paused", stopped = "stopped", seeking = "buffering",
  interrupted = "paused", unknown = "idle",
}

-- Only the most common apps; anything else keeps what the driver reported.
M.APPS = {
  ["com.apple.TVWatchList"] = "TV", ["com.apple.TVMusic"] = "Music", ["com.apple.TVPhotos"] = "Photos",
  ["com.apple.podcasts"] = "Podcasts", ["com.apple.Fitness"] = "Fitness",
  ["com.netflix.Netflix"] = "Netflix", ["com.google.ios.youtube"] = "YouTube",
  ["com.disney.disneyplus"] = "Disney+", ["com.hulu.plus"] = "Hulu", ["com.amazon.aiv.AIVApp"] = "Prime Video",
  ["com.wbd.stream"] = "Max", ["com.hbo.hbonow"] = "Max", ["com.spotify.client"] = "Spotify",
  ["com.plexapp.plex"] = "Plex", ["com.peacocktv.peacock"] = "Peacock", ["com.cbsvideo.app"] = "Paramount+",
}

local function full(name) return M.PREFIX .. name end
M.full_name = full

local function s(v)
  if v == nil then return nil end
  v = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
  if v == "" then return nil end
  return v
end

-- A plain non-negative decimal number ("12", " 12 ", "12.5", ".5", "1e3"); anything else
-- ("-5", "0x10", "nan", "inf", "1e400", "", "abc", "1.2.3") -> nil. Never NaN, inf or negative.
local function decimal(v, max)
  v = s(v)
  if not v then return nil end
  local mant = v:match("^([%d%.]+)[eE][+]?%d+$") or v:match("^([%d%.]+)$")
  if not mant or not mant:find("%d") or mant:find("%..*%.") then return nil end
  local n = tonumber(v)
  if not n or n ~= n or n < 0 or n == math.huge or (max and n > max) then return nil end
  return n
end
M.decimal = decimal

local function count(v)
  -- season / episode numbers: a plain non-negative integer ("2", "02", "2.0");
  -- anything else ("S2", "2a", "2.5", "", "1e3", "0x2") -> nil. Season 0 (specials) is a real number.
  v = s(v)
  if not v or not v:find("^%d+%.?0*$") then return nil end
  local n = decimal(v, M.MAX_COUNT)
  if not n then return nil end
  return math.floor(n)
end

local function seconds(v) return decimal(v, M.MAX_SECONDS) end

function M.looks_like_bundle_id(v)
  return type(v) == "string" and v:find("^[%w%-_]+%.[%w%-_]+%.[%w%-_%.]+$") ~= nil
end

function M.app_name(name, id)
  name, id = s(name), s(id)
  if name and name ~= id and not M.looks_like_bundle_id(name) then return name end
  local known = M.APPS[id or ""] or M.APPS[name or ""]
  return known or name or id
end

function M.to_playback(snap, opts)
  snap, opts = snap or {}, opts or {}
  local now = opts.now
  local valid = s(snap.VALID) == "1"
  local raw_state = s(snap.PLAY_STATE)
  local pb = playback_mod.empty("idle", now)
  pb.source = { provider = "appletv", device_name = opts.device_name }
  if not valid or not raw_state then return pb end -- cleared: idle, no media, no artwork

  local state = M.STATES[raw_state:lower()] or "idle"
  local title = s(snap.TITLE)
  local series = s(snap.SERIES)
  local season, episode = count(snap.SEASON), count(snap.EPISODE)
  local artist, album = s(snap.ARTIST), s(snap.ALBUM)
  local duration = seconds(snap.DURATION)
  if duration == 0 then duration = nil end
  local position = seconds(snap.POSITION)
  if position == 0 and not duration then position = nil end -- both unknown
  local updated = decimal(snap.UPDATED_AT, M.MAX_EPOCH)
  if updated == 0 then updated = nil end

  -- the pyatv bridge's heuristic: an active session with a title but no duration looks live
  local is_live
  if state == "playing" or state == "paused" or state == "buffering" then
    if duration then is_live = false elseif title then is_live = true end
  end

  -- no media-type field in the contract: inferred, in the bridge's order of certainty
  local kind
  if series or season or episode then kind = "episode"
  elseif artist or album then kind = "music"
  elseif duration and duration > M.MOVIE_MIN_DURATION_S then kind = "movie"
  elseif title then kind = "video"
  else kind = "unknown" end

  local subtitle
  if kind == "music" then subtitle = artist
  elseif kind == "episode" then
    local se = (season and ("S" .. season) or "") .. (episode and ("E" .. episode) or "")
    subtitle = util.join({ n = 2, series, se }, " · ")
    if subtitle == "" then subtitle = nil end
  end

  local art = s(snap.ARTWORK_URL)
  if art and not art:find("^https://") then art = nil end

  local app_id = s(snap.APP_ID)
  pb.source.app_name = M.app_name(snap.APP_NAME, app_id)
  pb.source.app_id = app_id
  pb.playback = { state = state, position_s = position, duration_s = duration,
    position_updated_at = updated, is_live = is_live }
  pb.media = {
    kind = kind, title = title, subtitle = subtitle, series_title = series, season = season, episode = episode,
    episode_title = kind == "episode" and title or nil, artist = artist, album = album, genres = {},
    artwork_url = art,
  }
  return pb
end

-- C4:GetDeviceVariables(id) -> { [NAME] = varId } (true when a name has no usable id; values
-- are then read from the whole table). The shape is undocumented; accepted: {[id]={name=,value=}}
-- (expected), {[i]={id=,name=}}, {[name]={id=,value=}}, {[name]=value}.
function M.var_map(vars)
  local map = {}
  if type(vars) ~= "table" then return map end
  for k, v in pairs(vars) do
    if type(v) == "table" then
      local name = v.name or v.Name or v.NAME or v.varName
      local id = tonumber(v.id or v.ID or v.varId or v.variableId)
      if name == nil and type(k) == "string" and not tonumber(k) then name = k end
      if id == nil and tonumber(k) and (v.name or v.Name or v.NAME or v.varName) then id = tonumber(k) end
      if type(name) == "string" then map[name] = id or map[name] or true end
    elseif type(k) == "string" and not tonumber(k) then
      if map[k] == nil then map[k] = true end
    end
  end
  return map
end

-- the value of NAME in a GetDeviceVariables table (fallback read path)
function M.value_in(vars, name)
  if type(vars) ~= "table" then return nil end
  for k, v in pairs(vars) do
    if type(v) == "table" then
      if (v.name or v.Name or v.NAME or v.varName or k) == name then
        local x = v.value; if x == nil then x = v.Value end
        if x ~= nil then return tostring(x) end
        return ""
      end
    elseif k == name then
      return tostring(v)
    end
  end
  return nil
end

-- device ids from {[id]=name} / {id, id} / {[id]=true} / "1,2"
function M.ids(v)
  local out, seen = {}, {}
  local function add(n)
    n = tonumber(n)
    if n and n > 0 and not seen[n] then seen[n] = true; out[#out + 1] = n end
  end
  if type(v) == "table" then
    for k, x in pairs(v) do
      if type(x) == "number" or (type(x) == "string" and tonumber(x)) then add(x) else add(k) end
    end
  elseif type(v) == "string" then
    for n in v:gmatch("%d+") do add(n) end
  elseif type(v) == "number" then
    add(v)
  end
  table.sort(out)
  return out
end


-- a value of NOW_PLAYING_REVISION / _UPDATED_AT: a plain non-negative integer string
local function is_int_str(v) return type(v) == "string" and v:find("^%s*%d+%s*$") ~= nil end

-- Cheap sanity check of a snapshot read through the name map: when the Apple TV driver reloads,
-- its variable ids can be reassigned and a stale map then reads other variables. VALID is always
-- "0"/"1" and UPDATED_AT a number (or "" when unset); anything else means the map is wrong.
function M.plausible(snap)
  local v = s(snap.VALID)
  if v ~= nil and v ~= "0" and v ~= "1" then return false, "NOW_PLAYING_VALID = " .. tostring(snap.VALID) end
  local u = s(snap.UPDATED_AT)
  if u ~= nil and not decimal(u) then return false, "NOW_PLAYING_UPDATED_AT = " .. tostring(snap.UPDATED_AT) end
  return true
end

---------------------------------------------------------------------------
-- watcher
---------------------------------------------------------------------------

local W = {}
W.__index = W

M.RETRY_S = 1 -- a read torn MAX_TRIES times in a row is retried this much later

function M.new(C4, deps, on_change)
  return setmetatable({ C4 = C4, deps = deps, on_change = on_change, status = "Not configured", restarts = 0,
    epoch = 0 }, W)
end

function W:_log(level, msg) self.deps.log(level, "Apple TV driver: " .. msg) end

-- every C4 call goes through here: a missing (older OS) or failing API is "not available",
-- never an error in our driver
function W:_call(name, ...)
  local f = self.C4[name]
  if type(f) ~= "function" then return false, "C4:" .. name .. " not available" end
  return pcall(f, self.C4, ...)
end

function W:_name_of(id)
  local ok, n = self:_call("GetDeviceDisplayName", id)
  if ok and type(n) == "string" and n ~= "" then return n end
  return nil
end

function W:_vars(id)
  local ok, v = self:_call("GetDeviceVariables", id)
  if ok and type(v) == "table" then return v end
  return nil
end

-- name map of device id when it exposes the contract (NOW_PLAYING_REVISION), else nil
function W:_contract_map(id)
  if not id then return nil end
  local map = M.var_map(self:_vars(id))
  if map[full(M.REVISION)] then return map end
  return nil
end

-- every SmartBuildOS Apple TV driver (main) device in the project:
-- C4:GetDevicesByC4iName and C4:GetDevices({C4iNames=}) (both optional, results merged;
-- GetDevices entries carrying a `protocol` sub-table are proxies and skipped)
function W:_installed()
  local out, seen = {}, {}
  for _, c4z in ipairs(M.C4Z_NAMES) do
    local ok, v = self:_call("GetDevicesByC4iName", c4z)
    if ok then
      for _, id in ipairs(M.ids(v)) do if not seen[id] then seen[id] = true; out[#out + 1] = id end end
    end
  end
  local ok2, t = self:_call("GetDevices", { C4iNames = table.concat(M.C4Z_NAMES, ",") })
  if ok2 and type(t) == "table" then
    for k, e in pairs(t) do
      local id = tonumber(k)
      if id and not seen[id] and not (type(e) == "table" and type(e.protocol) == "table") then
        seen[id] = true; out[#out + 1] = id
      end
    end
  end
  table.sort(out)
  return out
end

-- devices linked to `id` by C4:GetDevices({DeviceIds=}) (a proxy's `protocol`, a protocol
-- driver's `proxies`); optional API
function W:_related(id)
  local rel, seen = {}, {}
  local ok, t = self:_call("GetDevices", { DeviceIds = tostring(id) })
  if ok and type(t) == "table" then
    local e = t[id] or t[tostring(id)]
    if type(e) == "table" then
      for _, key in ipairs({ "protocol", "proxies" }) do
        if type(e[key]) == "table" then
          for pid in pairs(e[key]) do
            local n = tonumber(pid)
            if n and n ~= id and not seen[n] then seen[n] = true; rel[#rel + 1] = n end
          end
        end
      end
    end
  end
  table.sort(rel)
  return rel
end

-- does main device `dev` own proxy `id`? (C4:GetProxyDevicesById, C4:GetDevices; both optional)
function W:_owns(dev, id)
  local res = { n = 0 }
  local function collect(ok, ...) if ok then res = { n = select("#", ...), ... } end end
  collect(self:_call("GetProxyDevicesById", dev))
  for i = 1, res.n do
    for _, p in ipairs(M.ids(res[i])) do if p == id then return true end end
  end
  local ok, t = self:_call("GetDevices", { DeviceIds = tostring(dev) })
  if ok and type(t) == "table" then
    local e = t[dev] or t[tostring(dev)]
    if type(e) == "table" and type(e.proxies) == "table" then
      for p in pairs(e.proxies) do if tonumber(p) == id then return true end end
    end
  end
  return false
end

local function label(self, id)
  local n = self:_name_of(id)
  return "device " .. id .. (n and (" (" .. n .. ")") or "")
end

-- -> dev, map, how | nil, nil, problem
-- Order: Apple TV Driver Device ID, then Apple TV Driver (the selector); the first one that
-- exposes NOW_PLAYING_REVISION wins. Otherwise (a child proxy, or the wrong device) the main
-- device is looked for: proxy -> protocol links, then the SmartBuildOS drivers installed in the
-- project. Several candidates and none related to the selection: ambiguous, no guessing.
function W:_resolve()
  local opts = self.opts or {}
  local tried = {}
  for _, c in ipairs({ { opts.override, "Apple TV Driver Device ID" }, { opts.selected, "Apple TV Driver" } }) do
    local id = c[1]
    if id and not tried[id] then
      tried[#tried + 1] = id; tried[id] = true
      local map = self:_contract_map(id)
      if map then return id, map, c[2] end
    end
  end
  local first = tried[1]
  if not first then return nil, nil, "Not configured" end
  -- 1) documented proxy -> protocol links of what was given
  for _, id in ipairs(tried) do
    for _, rel in ipairs(self:_related(id)) do
      local map = self:_contract_map(rel)
      if map then return rel, map, "main device of " .. id end
    end
  end
  -- 2) the SmartBuildOS drivers installed in the project
  local installed = self:_installed()
  for _, dev in ipairs(installed) do
    for _, id in ipairs(tried) do
      if dev == id or self:_owns(dev, id) then
        -- the selection IS (or belongs to) this Apple TV driver: use it or report it, never another one
        local map = self:_contract_map(dev)
        if map then return dev, map, "main device of " .. id end
        return nil, nil, "Apple TV driver " .. label(self, dev) .. " has no NOW_PLAYING_* variables — " ..
          "update it to SmartBuildOS Apple TV Native Beta 120 or later"
      end
    end
  end
  local cands = {}
  for _, dev in ipairs(installed) do
    if not tried[dev] and self:_contract_map(dev) then cands[#cands + 1] = dev end
  end
  if #cands == 1 then
    return cands[1], self:_contract_map(cands[1]),
      "the only " .. table.concat(M.C4Z_NAMES, "/") .. " device in the project (device " .. first .. " is not one)"
  end
  if #cands > 1 then
    local ids = {}
    for _, d in ipairs(cands) do ids[#ids + 1] = tostring(d) end
    return nil, nil, "Ambiguous: " .. #cands .. " Apple TV drivers in the project (devices " .. table.concat(ids, ", ") ..
      ") and device " .. first .. " is none of them — select the right one or set Apple TV Driver Device ID"
  end
  local name = self:_name_of(first)
  if not name and not self:_vars(first) then
    return nil, nil, "Device " .. first .. " not found — select the Apple TV driver again"
  end
  return nil, nil, "Device " .. first .. (name and (" (" .. name .. ")") or "") ..
    " has no NOW_PLAYING_* variables and no SmartBuildOS Apple TV Native driver (Beta 120+) was found"
end

function W:_notify()
  if self.on_change then self.on_change(self) end
end

function W:_set_status(text, force_notify)
  if self.status == text and not force_notify then return end
  self.status = text
  self:_notify()
end

function W:_listen(force)
  local id = self.map and self.map[full(M.REVISION)]
  local key = self.dev and type(id) == "number" and (self.dev .. ":" .. id) or nil
  if key == self.listen_key and not force then return end
  self:_unlisten()
  if not key then
    if self.dev then self:_log("info", "no variable id for NOW_PLAYING_REVISION: relying on the " .. M.POLL_S .. " s poll") end
    return
  end
  self.listen_key, self.listen_dev, self.listen_var = key, self.dev, id
  self.registering = true
  local ok, err = self:_call("RegisterVariableListener", self.dev, id)
  self.registering = false
  if not ok then self:_log("warn", "RegisterVariableListener(" .. self.dev .. "," .. id .. "): " .. tostring(err)) end
end

function W:_unlisten()
  if self.listen_key then
    self:_call("UnregisterVariableListener", self.listen_dev, self.listen_var)
  end
  self.listen_key, self.listen_dev, self.listen_var = nil, nil, nil
end

-- event 19 of the device being read (C4:RegisterDeviceEvent, OS 2.9.0+; guarded: without it the
-- REVISION listener, the safety poll and the Composer-wired command still work)
function W:_watch_event(force)
  local dev = self.dev
  if dev == self.event_dev and not force then return end
  self:_unwatch_event()
  if not dev then return end
  local ok, err = self:_call("RegisterDeviceEvent", dev, M.EVENT_ID)
  if ok then
    self.event_dev = dev
  else
    self.event_dev = nil
    if self.event_warned ~= dev then
      self.event_warned = dev
      self:_log("info", "event " .. M.EVENT_ID .. " not subscribed (" .. tostring(err) ..
        "): relying on the NOW_PLAYING_REVISION listener / the \"Refresh Apple TV Now Playing\" command")
    end
  end
end

function W:_unwatch_event()
  if self.event_dev then self:_call("UnregisterDeviceEvent", self.event_dev, M.EVENT_ID) end
  self.event_dev = nil
end

function W:_cancel_timers()
  if self.timer then self.timer:cancel(); self.timer = nil end
  if self.retry then self.retry:cancel(); self.retry = nil end
  if self.confirm then self.confirm:cancel(); self.confirm = nil end
  self.suspect = nil
end

function W:_arm()
  if self.timer then self.timer:cancel(); self.timer = nil end
  if not self.opts then return end
  self.timer = self.deps.set_timer(M.POLL_S, function()
    self.timer = nil
    self:_safety_poll()
    self:_arm()
  end)
end

-- (re)resolve the device and its name map; true when the contract is available
function W:_connect(reason)
  local dev, map, how = self:_resolve()
  if not dev then
    local had = self.dev ~= nil or self.snap ~= nil
    if self.dev then self:_log("warn", "lost the Apple TV driver device " .. self.dev .. ": " .. tostring(how)) end
    self:_unlisten()
    self:_unwatch_event()
    self.dev, self.map, self.how, self.applied_rev, self.snap = nil, nil, nil, nil, nil
    self.epoch = (self.epoch or 0) + 1
    if how ~= self.last_problem then self:_log("warn", how) end
    self.last_problem = how
    self:_set_status(how, had) -- what was shown is gone: always tell the app
    return false
  end
  self.last_problem = nil
  if dev ~= self.dev then
    self:_log("info", "using " .. label(self, dev) .. ": " .. how .. (reason and (" [" .. reason .. "]") or ""))
    self.applied_rev, self.snap = nil, nil
    self.epoch = (self.epoch or 0) + 1
    if self.confirm then self.confirm:cancel(); self.confirm = nil end
    self.suspect = nil
  end
  self.dev, self.map, self.how = dev, map, how
  self:_listen()
  self:_watch_event()
  return true
end

-- the content of a snapshot (every field, in contract order)
function M.fingerprint(snap)
  local t = {}
  for i, f in ipairs(M.FIELDS) do t[i] = tostring(snap and snap[f] or "") end
  return table.concat(t, "\0")
end

local function same_map(a, b)
  if not a or not b then return false end
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- rebuild the name map of the current device (ids change when that driver reloads)
-- -> ok, changed
function W:_remap(force_listen)
  if not self.dev then return self:_connect("remap"), true end
  local map = self:_contract_map(self.dev)
  if not map then return self:_connect("variables gone"), true end
  local changed = not same_map(map, self.map)
  if changed then self:_log("info", "variable ids of device " .. self.dev .. " changed: map rebuilt") end
  self.map = map
  self:_listen(force_listen)
  self:_watch_event(force_listen or changed) -- new ids = that driver reloaded: subscribe afresh
  return true, changed
end

-- the value of a contract field; `t` caches one GetDeviceVariables table for name-only maps
function W:_get(name, t)
  local id = self.map and self.map[full(name)]
  if id == nil then return nil end
  if type(id) == "number" then
    local ok, v = self:_call("GetDeviceVariable", self.dev, id)
    if ok and v ~= nil then return tostring(v) end
    return nil
  end
  -- no id in the GetDeviceVariables shape: read the value from the whole table
  if t then
    if t.vars == nil then t.vars = self:_vars(self.dev) or false end
    return M.value_in(t.vars or nil, full(name))
  end
  return M.value_in(self:_vars(self.dev), full(name))
end

local function rev_of(v)
  if not is_int_str(v) then return nil end
  return tonumber((v:gsub("%s", "")))
end

-- one consistent snapshot: REVISION, all fields, REVISION again; retried while it moves.
-- -> snap, rev | nil, err ("torn" when it never settled)
function W:_read_snapshot()
  for attempt = 1, M.MAX_TRIES do
    local r1 = self:_get(M.REVISION)
    if r1 == nil then return nil, "cannot read NOW_PLAYING_REVISION" end
    if not rev_of(r1) then return nil, "NOW_PLAYING_REVISION is not a number (" .. r1 .. ")" end
    local snap, t = {}, {}
    for _, f in ipairs(M.FIELDS) do snap[f] = self:_get(f, t) or "" end
    local r2 = self:_get(M.REVISION)
    if r2 == nil then return nil, "cannot read NOW_PLAYING_REVISION" end
    if r1 == r2 then
      local ok, why = M.plausible(snap)
      if not ok then return nil, "implausible snapshot (" .. why .. ")" end
      snap.REVISION = r2
      return snap, rev_of(r2)
    end
    self:_log("debug", "torn read (revision " .. r1 .. " -> " .. tostring(r2) .. "), attempt " .. attempt)
  end
  return nil, "torn"
end

function W:_retry_soon(reason)
  if self.retry then return end
  self:_log("warn", "revision kept changing during " .. M.MAX_TRIES .. " reads; nothing published, retrying")
  self.retry = self.deps.set_timer(M.RETRY_S, function()
    self.retry = nil
    self:read("retry after torn read (" .. tostring(reason) .. ")")
  end)
end

function W:_apply(snap, rev, reason)
  self.applied_rev, self.snap = rev, snap
  self.status = "Connected to " .. (self:_name_of(self.dev) or ("device " .. self.dev)) .. " (device " .. self.dev ..
    "), revision " .. rev .. (s(snap.VALID) == "1" and "" or ", nothing playing (VALID=0)")
  self.deps.log("debug", "Apple TV driver: snapshot " .. rev .. " (" .. tostring(reason) .. "): state=" ..
    tostring(snap.PLAY_STATE) .. " valid=" .. tostring(snap.VALID) .. " title=" .. tostring(snap.TITLE))
  self:_notify()
end

function W:_read(reason, force)
  if not self.dev and not self:_connect(reason) then return false end
  local snap, rev = self:_read_snapshot()
  if not snap and rev ~= "torn" then
    -- the variable ids may have moved (driver reload): rebuild the map once and read again
    self:_log("info", tostring(rev) .. ": re-resolving the variables")
    local ok, changed = self:_remap(true)
    if not (ok and self.dev) then return false end
    if changed then force = true end
    snap, rev = self:_read_snapshot()
  end
  if not snap then
    if rev == "torn" then self:_retry_soon(reason); return false end
    self:_set_status("Device " .. tostring(self.dev) .. ": " .. tostring(rev))
    return false
  end
  if self.applied_rev and rev < self.applied_rev then
    self.restarts = self.restarts + 1
    self:_log("info", "revision went back (" .. self.applied_rev .. " -> " .. rev ..
      "): the Apple TV driver restarted; re-resolving its variables")
    self.applied_rev = nil
    local ok = self:_remap(true) -- also re-registers the listener
    if not (ok and self.dev) then return false end
    snap, rev = self:_read_snapshot()
    if not snap then
      if rev == "torn" then self:_retry_soon(reason); return false end
      self:_set_status("Device " .. tostring(self.dev) .. ": " .. tostring(rev))
      return false
    end
  end
  if rev == self.applied_rev and not force then
    if self.snap and M.fingerprint(snap) ~= M.fingerprint(self.snap) then return self:_suspect(snap, rev, reason) end
    self.suspect = nil
    return true
  end
  self.suspect = nil
  self:_apply(snap, rev, reason)
  return true
end

-- The applied REVISION number with different content: a module reload whose fresh counter landed
-- on our number (or a read in the middle of a write). Confirmed by a second read RETRY_S later
-- (same revision, same content) before it is applied as a restart; at most MAX_TRIES checks.
function W:_suspect(snap, rev, reason)
  local fp = M.fingerprint(snap)
  local sus = self.suspect
  if sus and sus.rev == rev and sus.fp == fp and sus.epoch == self.epoch then
    self.suspect = nil
    self.restarts = self.restarts + 1
    self:_log("info", "revision " .. rev .. " re-used with different content: the Apple TV driver restarted")
    self:_apply(snap, rev, reason)
    return true
  end
  local tries = (sus and sus.rev == rev and sus.epoch == self.epoch) and (sus.tries + 1) or 1
  if tries > M.MAX_TRIES then self.suspect = nil; return false end
  self.suspect = { rev = rev, fp = fp, tries = tries, epoch = self.epoch }
  if not self.confirm then
    self.confirm = self.deps.set_timer(M.RETRY_S, function()
      self.confirm = nil
      if self.suspect then self:read("confirm revision " .. rev) end
    end)
  end
  return false
end

-- Read now. force: re-apply even when REVISION is unchanged. Never re-entrant: a read asked for
-- while one runs (a listener fired from inside it) runs right after it.
function W:read(reason, force)
  if not self.opts then return false end
  if self.reading then
    self.again = { reason = reason, force = force or (self.again and self.again.force) }
    return false
  end
  self.reading = true
  local ok, res = pcall(self._read, self, reason, force)
  self.reading = false
  if not ok then self.again = nil; error(res, 0) end
  local again = self.again
  self.again = nil
  if again and self.opts then return self:read(again.reason, again.force) end
  return res
end

function W:_safety_poll()
  if not self.opts then return end
  if not self.dev then
    if self:_connect("retry") then self:read("connect", true) end
    return
  end
  local ok, changed = self:_remap()
  if ok and self.dev then self:read("safety poll", changed) end
end

function W:configure(opts)
  if opts == nil or not (opts.selected or opts.override) then return self:stop() end
  local o = self.opts
  if o and o.selected == opts.selected and o.override == opts.override then
    if o.name ~= opts.name then
      o.name = opts.name
      self:_notify()
    end
    -- unresolved so far: any reconfiguration is a good moment to try again
    if not self.dev and self:_connect("reconfigure") then self:read("connect", true) end
    return
  end
  self:stop()
  self.opts = { selected = opts.selected, override = opts.override, name = opts.name }
  if self:_connect("configure") then self:read("connect", true) end
  self:_arm()
end

function W:stop()
  self:_cancel_timers()
  self:_unlisten()
  self:_unwatch_event()
  self.epoch = (self.epoch or 0) + 1
  local was = self.opts ~= nil
  self.opts, self.dev, self.map, self.how, self.applied_rev, self.snap, self.last_problem = nil, nil, nil, nil, nil, nil, nil
  self.again = nil
  self.status = "Not configured"
  if was then self:_notify() end
end

function W:on_variable(dev, var, value)
  dev, var = tonumber(dev), tonumber(var)
  if not self.listen_key or dev ~= self.listen_dev or var ~= self.listen_var then return false end
  if self.registering then return true end -- the immediate callback: connecting reads explicitly
  local rev = rev_of(value)
  if rev and self.applied_rev and rev == self.applied_rev then return true end
  self:read("revision " .. tostring(value))
  return true
end

-- OnDeviceEvent(firingDeviceId, eventId): event 19 of the device being read -> read now. Not
-- forced: an unchanged revision with unchanged content is a no-op (no duplicate redraw when the
-- REVISION listener already applied it); anything else (another device / event, a late event
-- from the previous selection) is ignored.
function W:on_device_event(dev, ev)
  dev, ev = tonumber(dev), tonumber(ev)
  if not self.opts or not self.dev or dev ~= self.dev or ev ~= M.EVENT_ID then return false end
  self:read("event " .. M.EVENT_ID)
  return true
end

function W:device_name()
  if self.opts and self.opts.name then return self.opts.name end
  return self.dev and self:_name_of(self.dev) or nil
end

function W:playback()
  local now = self.deps.now()
  if not self.snap then
    local pb = playback_mod.empty("off", now)
    pb.source = { provider = "appletv", device_name = self:device_name() }
    return pb
  end
  return M.to_playback(self.snap, { device_name = self:device_name(), now = now })
end

function W:status_text() return self.status end

-- "Test Metadata Sources": re-resolves, re-reads -> lines, ok
function W:report()
  if not self.opts then return { "  Apple TV driver: not configured" }, true end
  if self.dev then self:_remap() else self:_connect("test") end
  if self.dev then self:read("test", true) end
  local lines = {}
  if not self.dev then
    lines[1] = "  Apple TV driver (SmartBuildOS)  FAILED - " .. tostring(self.status)
    local ids = self:_installed()
    local t = {}
    for _, id in ipairs(ids) do t[#t + 1] = id .. " (" .. tostring(self:_name_of(id)) .. ")" end
    lines[2] = "    " .. table.concat(M.C4Z_NAMES, "/") .. " devices in the project: " .. (#t > 0 and table.concat(t, ", ") or "none found")
    return lines, false
  end
  local found, missing = { full(M.REVISION) }, {}
  for _, f in ipairs(M.FIELDS) do
    if self.map[full(f)] then found[#found + 1] = full(f) else missing[#missing + 1] = full(f) end
  end
  local snap = self.snap or {}
  lines[#lines + 1] = "  Apple TV driver (SmartBuildOS)  " .. (#missing == 0 and "OK" or "INCOMPLETE") .. " - " ..
    label(self, self.dev) .. ", " .. tostring(self.how)
  lines[#lines + 1] = "    variables found: " .. #found .. "/" .. (#M.FIELDS + 1) ..
    (#missing > 0 and (" (missing: " .. table.concat(missing, ", ") .. ")") or " (all)") ..
    (self.listen_var and (", listening on NOW_PLAYING_REVISION (variable " .. self.listen_var .. ")") or "") ..
    (self.event_dev and (", event " .. M.EVENT_ID .. " subscribed") or (", event " .. M.EVENT_ID .. " not subscribed"))
  lines[#lines + 1] = "    revision " .. tostring(snap.REVISION or "?") .. ", VALID=" .. tostring(snap.VALID or "?") ..
    ", state " .. tostring(s(snap.PLAY_STATE) or "-") .. (s(snap.TITLE) and (", title \"" .. snap.TITLE .. "\"") or "") ..
    (s(snap.APP_NAME) and (", app " .. snap.APP_NAME) or "")
  return lines, #missing == 0
end

return M
