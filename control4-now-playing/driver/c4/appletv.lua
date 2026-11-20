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
  * Event 19 "Now Playing snapshot updated" fires after every snapshot write (dealers can wire
    it to our "Refresh" command); a change of NOW_PLAYING_REVISION is an equally good trigger.
  * Not used on purpose: PLAYBACK_POSITION (a ~1/s local estimate; we extrapolate ourselves from
    POSITION + UPDATED_AT, same controller clock) and event 12 NOW_PLAYING_CHANGED (title only).

Receiver rules implemented here: read the snapshot when connecting; re-read on every REVISION
change (variable listener) and on Refresh; read REVISION before and after the fields and retry
when it moved (MAX_TRIES, then the latest read is accepted and logged); VALID=0 clears what is
shown; a REVISION lower than the last applied one is a driver restart (variable ids may have
changed: the name map is rebuilt and the listener re-registered). A safety poll (POLL_S) rebuilds
the name map and re-reads REVISION in case a notification was missed or the ids moved.

Staleness: when the Apple TV driver stops updating while VALID=1 we cannot tell (a paused movie
legitimately produces no updates), so the last snapshot stays until it is cleared or replaced.

Pure helpers
  AppleTV.to_playback(snap, opts) -> playback (np.playback shape)
      snap = { TITLE = "...", ..., REVISION = "42" } (names without the NOW_PLAYING_ prefix)
      opts = { device_name = "...", now = epoch }
  AppleTV.var_map(vars)    -> { [NAME] = id | true }  (C4:GetDeviceVariables result, any shape)
  AppleTV.app_name(name, id) -> display name for the app
  AppleTV.ids(v)           -> list of device ids from a GetDevicesByC4iName-style table
Watcher (C4 injected)
  local w = AppleTV.new(C4, deps, on_change)      on_change(watcher) after each applied snapshot
                                                   or status change
  w:configure({ selected = n, override = n, name = "..." } | nil)   (idempotent)
  w:stop()
  w:on_variable(idDevice, idVariable, strValue) -> true when handled
  w:read(reason, force)   re-read now (force: re-apply even when REVISION is unchanged)
  w:playback()            the current playback (an "off" playback while nothing is resolved)
  w:status_text()         for the read-only "Apple TV Driver Status" property
  w:report()              lines + ok for "Test Metadata Sources"

C4 APIs (Snap One DriverWorks API reference, docs-driverworks-api):
  required  C4:GetDeviceVariables(id)        22_miscellaneous/_12 (2.8.0): {[varId]={name=,value=}}
                                              (shape as used by the variable_parser sample driver)
            C4:GetDeviceVariable(dev, varId) / C4:RegisterVariableListener / UnregisterVariableListener
            C4:GetDeviceDisplayName(id)
  optional  C4:GetDevicesByC4iName(c4z)      25_proxy/_4 (1.6.0): table of device ids
  (guarded) C4:GetDevices({DeviceIds=...})   22_miscellaneous/_9 (2.10.0): a proxy's entry carries a
                                              `protocol` sub-table, a protocol driver's a `proxies` one
            C4:GetProxyDevicesById(id)       25_proxy/_2 (1.6.0): the proxies of a device
]]

local util = require("np.util")
local playback_mod = require("np.playback")

local M = {}

M.C4Z = "smartbuildos_appletv_native.c4z"
M.PREFIX = "NOW_PLAYING_"
M.FIELDS = { "TITLE", "SERIES", "SEASON", "EPISODE", "ARTIST", "ALBUM", "APP_NAME", "APP_ID", "PLAY_STATE",
  "POSITION", "DURATION", "ARTWORK_URL", "UPDATED_AT", "VALID" }
M.REVISION = "REVISION"
M.POLL_S = 30
M.MAX_TRIES = 3
M.MOVIE_MIN_DURATION_S = 60 * 60 -- same threshold as the pyatv bridge (bridge/atv_bridge/mapping.py)

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

local function count(v)
  -- season / episode numbers: plain non-negative integers only ("S2", "2a", "" -> nil); 0 -> nil
  -- (a missing number written as "0" must not turn every title into an episode)
  v = s(v)
  if not v or not v:find("^%d+%.?0*$") then return nil end
  local n = tonumber(v)
  if not n or n <= 0 then return nil end
  return math.floor(n)
end

local function seconds(v)
  local n = tonumber(s(v) or "")
  if not n or n ~= n or n < 0 or n == math.huge then return nil end
  return n
end

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
  local updated = seconds(snap.UPDATED_AT)
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
    position_updated_at = updated or now, is_live = is_live }
  pb.media = {
    kind = kind, title = title, subtitle = subtitle, series_title = series, season = season, episode = episode,
    episode_title = kind == "episode" and title or nil, artist = artist, album = album, genres = {},
    artwork_url = art,
  }
  return pb
end

-- C4:GetDeviceVariables(id) -> { [NAME] = varId } (true when a name has no usable id; values
-- are then read from the whole table). Accepted shapes: {[id]={name=,value=}} (documented /
-- sample drivers), {[i]={id=,name=}}, {[name]={id=,value=}}, {[name]=value}.
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

---------------------------------------------------------------------------
-- watcher
---------------------------------------------------------------------------

local W = {}
W.__index = W

function M.new(C4, deps, on_change)
  return setmetatable({ C4 = C4, deps = deps, on_change = on_change, status = "Not configured" }, W)
end

function W:_log(level, msg) self.deps.log(level, "Apple TV driver: " .. msg) end

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

-- every SmartBuildOS Apple TV driver device in the project
function W:_installed()
  local ok, v = self:_call("GetDevicesByC4iName", M.C4Z)
  if not ok then return {} end
  return M.ids(v)
end

-- protocol device(s) related to a proxy id and vice versa (optional APIs, all guarded)
function W:_related(id)
  local rel, seen = {}, {}
  local function add(n) n = tonumber(n); if n and n ~= id and not seen[n] then seen[n] = true; rel[#rel + 1] = n end end
  local ok, t = self:_call("GetDevices", { DeviceIds = tostring(id) })
  if ok and type(t) == "table" then
    local e = t[id] or t[tostring(id)]
    if type(e) == "table" then
      for _, key in ipairs({ "protocol", "protocols", "proxies" }) do
        if type(e[key]) == "table" then for pid in pairs(e[key]) do add(pid) end end
      end
    end
  end
  return rel
end

-- does main device `dev` own proxy `id`?
function W:_owns(dev, id)
  local res = { self:_call("GetProxyDevicesById", dev) }
  if res[1] then
    for i = 2, #res do
      for _, p in ipairs(M.ids(res[i])) do if p == id then return true end end
    end
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

-- -> dev, map, how | nil, nil, problem
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
  -- a child proxy (Media Player / Apps & Search / App Switcher) or another device was given:
  -- look for the main driver device. 1) documented proxy -> protocol links
  for _, id in ipairs(tried) do
    for _, rel in ipairs(self:_related(id)) do
      local map = self:_contract_map(rel)
      if map then return rel, map, "main device of " .. id end
    end
  end
  -- 2) the SmartBuildOS drivers installed in the project
  local cands = {}
  for _, dev in ipairs(self:_installed()) do
    if not tried[dev] then
      local map = self:_contract_map(dev)
      if map then cands[#cands + 1] = { dev = dev, map = map } end
    end
  end
  for _, c in ipairs(cands) do
    for _, id in ipairs(tried) do
      if self:_owns(c.dev, id) then return c.dev, c.map, "main device of " .. id end
    end
  end
  if #cands == 1 then return cands[1].dev, cands[1].map, "only " .. M.C4Z .. " device in the project" end
  if #cands > 1 then
    local ids = {}
    for _, c in ipairs(cands) do ids[#ids + 1] = tostring(c.dev) end
    return nil, nil, "Ambiguous: several Apple TV drivers (devices " .. table.concat(ids, ", ") ..
      ") and device " .. first .. " is none of them; set Apple TV Driver Device ID"
  end
  local name = self:_name_of(first)
  if not name and not self:_vars(first) then
    return nil, nil, "Device " .. first .. " not found — select the Apple TV driver again"
  end
  return nil, nil, "Selected device " .. first .. (name and (" (" .. name .. ")") or "") ..
    " has no NOW_PLAYING_* variables — is the driver Beta 120 or later?"
end

function W:_set_status(text)
  if self.status == text then return end
  self.status = text
  if self.on_change then self.on_change(self) end
end

function W:_listen()
  local id = self.map and self.map[full(M.REVISION)]
  local key = self.dev and type(id) == "number" and (self.dev .. ":" .. id) or nil
  if key == self.listen_key then return end
  self:_unlisten()
  if not key then return end
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
    if self.dev then self:_log("warn", "lost the Apple TV driver device " .. self.dev .. ": " .. tostring(how)) end
    self:_unlisten()
    self.dev, self.map, self.applied_rev, self.snap = nil, nil, nil, nil
    self:_set_status(how)
    if how ~= self.last_problem then self:_log("warn", how) end
    self.last_problem = how
    return false
  end
  self.last_problem = nil
  if dev ~= self.dev then
    self:_log("info", "using device " .. dev .. " (" .. tostring(self:_name_of(dev)) .. ", " .. how .. ")" ..
      (reason and (" [" .. reason .. "]") or ""))
    self.applied_rev = nil
  end
  self.dev, self.map = dev, map
  self:_listen()
  return true
end

-- rebuild the name map of the current device (ids change when that driver reloads)
function W:_remap()
  if not self.dev then return self:_connect("remap") end
  local map = self:_contract_map(self.dev)
  if not map then return self:_connect("variables gone") end
  self.map = map
  self:_listen()
  return true
end

function W:_get(name)
  local id = self.map and self.map[full(name)]
  if id == nil then return nil end
  if type(id) == "number" then
    local ok, v = self:_call("GetDeviceVariable", self.dev, id)
    if ok and v ~= nil then return tostring(v) end
    return nil
  end
  -- no id in the GetDeviceVariables shape: read the value from the whole table
  return M.value_in(self:_vars(self.dev), full(name))
end

-- one consistent snapshot: -> snap, rev | nil, err
function W:_read_snapshot()
  local snap, r1, r2
  for attempt = 1, M.MAX_TRIES do
    r1 = self:_get(M.REVISION)
    if r1 == nil then return nil, "cannot read NOW_PLAYING_REVISION" end
    snap = {}
    for _, f in ipairs(M.FIELDS) do snap[f] = self:_get(f) or "" end
    r2 = self:_get(M.REVISION)
    if r2 == nil then return nil, "cannot read NOW_PLAYING_REVISION" end
    if r1 == r2 then break end
    if attempt == M.MAX_TRIES then
      self:_log("warn", "revision kept changing during " .. M.MAX_TRIES .. " reads (" .. r1 .. " -> " .. r2 ..
        "); using the latest read")
    else
      self:_log("debug", "torn read (revision " .. r1 .. " -> " .. r2 .. "), reading again")
    end
  end
  snap.REVISION = r2
  return snap, tonumber(s(r2) or "") or 0
end

function W:read(reason, force)
  if not self.opts then return end
  if not self.dev and not self:_connect(reason) then return end
  local snap, rev = self:_read_snapshot()
  if not snap then
    -- ids may have moved (driver reload): rebuild the map once and try again
    if not (self:_remap() and self.dev) then return end
    snap, rev = self:_read_snapshot()
    if not snap then
      self:_set_status("Device " .. self.dev .. ": " .. tostring(rev))
      return
    end
  end
  if self.applied_rev and rev < self.applied_rev then
    self:_log("info", "revision went back (" .. self.applied_rev .. " -> " .. rev ..
      "): the Apple TV driver restarted; re-resolving its variables")
    self.applied_rev = nil
    if not (self:_remap() and self.dev) then return end
    snap, rev = self:_read_snapshot()
    if not snap then return self:_set_status("Device " .. tostring(self.dev) .. ": " .. tostring(rev)) end
  end
  if rev == self.applied_rev and not force then return end
  self.applied_rev, self.snap = rev, snap
  self.status = "Connected to " .. (self:_name_of(self.dev) or ("device " .. self.dev)) .. " (device " .. self.dev ..
    "), revision " .. rev .. (s(snap.VALID) == "1" and "" or ", nothing playing (VALID=0)")
  self.deps.log("debug", "Apple TV driver: snapshot " .. rev .. " (" .. tostring(reason) .. "): state=" ..
    tostring(snap.PLAY_STATE) .. " valid=" .. tostring(snap.VALID) .. " title=" .. tostring(snap.TITLE))
  if self.on_change then self.on_change(self) end
end

function W:_safety_poll()
  if not self.opts then return end
  if not self.dev then
    if self:_connect("retry") then self:read("connect") end
    return
  end
  self:_remap()
  self:read("safety poll")
end

function W:configure(opts)
  if opts == nil or not (opts.selected or opts.override) then return self:stop() end
  local o = self.opts
  if o and o.selected == opts.selected and o.override == opts.override then
    if o.name ~= opts.name then
      self.opts = opts
      if self.on_change then self.on_change(self) end
    end
    return
  end
  self:stop()
  self.opts = { selected = opts.selected, override = opts.override, name = opts.name }
  if self:_connect("configure") then self:read("connect") end
  self:_arm()
end

function W:stop()
  if self.timer then self.timer:cancel(); self.timer = nil end
  self:_unlisten()
  local was = self.opts ~= nil
  self.opts, self.dev, self.map, self.applied_rev, self.snap, self.last_problem = nil, nil, nil, nil, nil, nil
  self.status = "Not configured"
  if was and self.on_change then self.on_change(self) end
end

function W:on_variable(dev, var, value)
  dev, var = tonumber(dev), tonumber(var)
  if not self.listen_key or dev ~= self.listen_dev or var ~= self.listen_var then return false end
  if self.registering then return true end -- the immediate callback: configure reads explicitly
  local rev = tonumber(s(value) or "")
  if rev and self.applied_rev and rev == self.applied_rev then return true end
  self:read("revision " .. tostring(value))
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
    pb.source = { provider = "appletv", device_name = self.opts and self.opts.name or nil }
    return pb
  end
  return M.to_playback(self.snap, { device_name = self:device_name(), now = now })
end

function W:status_text() return self.status end

-- "Test Metadata Sources": -> lines, ok
function W:report()
  if not self.opts then return { "  Apple TV driver: not configured" }, true end
  if self.dev then self:_remap() else self:_connect("test") end
  if self.dev then self:read("test") end
  local lines = {}
  if not self.dev then
    lines[1] = "  Apple TV driver (SmartBuildOS)  FAILED - " .. tostring(self.status)
    local ids = self:_installed()
    if #ids > 0 then
      local t = {}
      for _, id in ipairs(ids) do t[#t + 1] = id .. " (" .. tostring(self:_name_of(id)) .. ")" end
      lines[2] = "    " .. M.C4Z .. " devices in the project: " .. table.concat(t, ", ")
    end
    return lines, false
  end
  local found, missing = {}, {}
  for _, f in ipairs(M.FIELDS) do
    if self.map[full(f)] then found[#found + 1] = f else missing[#missing + 1] = full(f) end
  end
  local snap = self.snap or {}
  lines[1] = "  Apple TV driver (SmartBuildOS)  OK - " .. (self:_name_of(self.dev) or "?") .. " (device " .. self.dev ..
    "), revision " .. tostring(snap.REVISION) .. ", VALID=" .. tostring(snap.VALID) .. ", state " ..
    tostring(s(snap.PLAY_STATE) or "-") .. (s(snap.TITLE) and (", title \"" .. snap.TITLE .. "\"") or "")
  lines[2] = "    variables found: " .. (#found + 1) .. "/" .. (#M.FIELDS + 1) ..
    (#missing > 0 and (" (missing: " .. table.concat(missing, ", ") .. ")") or " (all)")
  return lines, #missing == 0
end

return M
