--[[
np.engine -- the Now Playing core: polls providers, publishes a stable state document,
runs enrichment, notifies listeners. Platform-agnostic: NO reference to C4; everything
external comes through `deps`.

deps = {
  http  = { request = function(req, cb) end },   -- req {method,url,headers,body,timeout}; cb(err, resp) once;
                                                  -- resp {status, headers, body}
  json  = { decode = fn(str) -> value|nil, err ; encode = fn(value) -> str },  (np.json is fine)
  now   = fn() -> epoch seconds,
  set_timer = fn(seconds, fn) -> handle with :cancel(),
  log   = fn(level, msg),                         -- "debug"|"info"|"warn"|"error"
  store = { get = fn(key), set = fn(key, value) },-- optional (enrichment cache persistence)
}
Image URLs are published exactly as the providers / enrichers report them (the state stays
small); a UI that cannot reach a LAN-only image asks the glue to fetch it (c4/artwork.lua).

config (the glue builds this from driver properties):
{
  room      = { id = 12, name = "Family Room" },
  providers = {                                   -- ordered: earlier wins ties
    { type = "roku", host = "192.168.1.50", name = "Living Room Roku", group = "lr-tv" },
    { type = "homeassistant", base_url = "http://ha.local:8123", token = "...",
      entity_id = "media_player.living_room", name = "...", provider_name = "appletv", group = "lr-tv" },
    { type = "bridge", url = "http://host:8765/v1/devices/<id>/now-playing", provider_name = "appletv" },
    { type = "static", id = "c4room", provider_name = "c4room", name = "Family Room" },
  },
  enrich = {
    tmdb = { api_key = "..." | bearer = "...", language = "en-US", country = "US" },
    omdb = { api_key = "..." },
    gracenote = { api_key = "...", lineup_id = "USA-OTA22201-DEFAULT", channel_map = {...} },
    music = { enabled = true, musicbrainz = true, country = "US", user_agent = "..." },
    cache = { max = 50, ttl_s = 21600, negative_ttl_s = 600, persist = false },
  },
  poll = { active_s = 2, idle_s = 5 },
  sticky_s = 10,                 -- provider stickiness
  stale_s = 10,                  -- reuse a failing provider's last result this long
  enrich_debounce_s = 1.5,       -- wait this long after a media change before enriching
  seek_threshold_s = 3,          -- republish position only when it deviates more than this
}

API
  Engine.new(config, deps)            -> engine
  engine:start() / engine:stop()
  engine:refresh()                    -- poll ASAP (next timer tick; never re-entrant)
  engine:get_state()                  -- deep copy of the state document (nil = absent)
  engine:get_state_json()             -> json, etag   (memoized per version)
  engine:on_change(fn)                -> unsubscribe fn;  fn(state_copy, changes)
        changes: { media, playback_state, position, details, source, room } (true when changed)
  engine:set_config(config)           -- live property changes
  engine:push(provider_id, playback)  -- feed a static provider (C4 room) and refresh
  engine:get_provider(id)
  engine:flatten(now)                 -> np.flatten list for C4 variables
  engine:get_status()                 -> diagnostics table
  Engine.media_key(playback), Engine.flatten(state, now)
]]

local util = require("np.util")
local schema = require("np.schema")
local playback_mod = require("np.playback")
local factory = require("np.providers.factory")
local Multi = require("np.providers.multi")
local Pipeline = require("np.enrich.pipeline")
local flatten = require("np.flatten")

local M = {}
M.SCHEMA_VERSION = 1
M.POLL_WATCHDOG_S = 30 -- a poll whose callback never comes is abandoned after this long
M.flatten = flatten.flatten

local Engine = {}
Engine.__index = Engine

function M.media_key(pb)
  local s, m = pb.source or {}, pb.media or {}
  local st = pb.playback and pb.playback.state
  if st == "off" then return (s.provider or "") .. "|off" end
  local se = ""
  if m.season or m.episode then se = "s" .. tostring(m.season or "") .. "e" .. tostring(m.episode or "") end
  local parts = {
    s.provider or "", s.app_id or util.norm(s.app_name),
    util.norm(m.series_title), util.norm(m.title), se,
    util.norm(m.artist), util.norm(m.album), tostring(m.channel_number or util.norm(m.channel_name)),
  }
  return table.concat(parts, "|")
end

local function initial_state(config, now)
  return {
    schema = M.SCHEMA_VERSION, version = 0, updated_at = now, media_key = "",
    room = util.deep_copy(config.room or {}),
    source = {}, playback = { state = "idle", is_live = false }, media = { kind = "unknown", genres = {} },
    details = nil,
  }
end

function M.new(config, deps)
  assert(type(deps) == "table" and deps.http and deps.now and deps.set_timer, "engine: deps missing")
  deps.log = deps.log or function() end
  local self = setmetatable({}, Engine)
  self.deps = deps
  self.config = config or {}
  self.listeners = {}
  self.running = false
  self.poll_seq = 0
  self.enrich_seq = 0
  self.state = initial_state(self.config, deps.now())
  self.json_cache = nil
  self:_build_providers()
  self:_build_pipeline()
  return self
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------

function Engine:_build_providers(reuse)
  local list = {}
  for i, pc in ipairs(self.config.providers or {}) do
    local p, err
    local id = pc.id
    if reuse and pc.type == "static" and reuse[id or "static"] then
      p = reuse[id or "static"]
      p.config = pc
    else
      p, err = factory.create(pc, self.deps)
    end
    if p then
      if p.kind == "static" then
        p.on_update = function() self:refresh() end
      end
      list[#list + 1] = p
    else
      self.deps.log("error", "provider #" .. i .. " ignored: " .. tostring(err))
    end
  end
  self.multi = Multi.new(list, {
    sticky_s = self.config.sticky_s, stale_s = self.config.stale_s,
    backoff_base_s = self.config.backoff_base_s, backoff_max_s = self.config.backoff_max_s,
  }, self.deps)
end

function Engine:_build_pipeline(old)
  self.pipeline = Pipeline.new(self.config.enrich or {}, self.deps, { cache = old and old.cache })
end

---------------------------------------------------------------------------
-- listeners / publishing
---------------------------------------------------------------------------

function Engine:on_change(fn)
  self.listeners[#self.listeners + 1] = fn
  return function()
    for i, f in ipairs(self.listeners) do
      if f == fn then table.remove(self.listeners, i); return end
    end
  end
end

function Engine:_emit(changes)
  for _, fn in ipairs(self.listeners) do
    local ok, err = pcall(fn, util.deep_copy(self.state), changes)
    if not ok then self.deps.log("error", "on_change listener failed: " .. tostring(err)) end
  end
end

function Engine:_bump(changes)
  self.state.version = self.state.version + 1
  self.state.updated_at = self.deps.now()
  self:_emit(changes)
end

function Engine:get_state()
  return util.deep_copy(self.state)
end

function Engine:get_state_json()
  local c = self.json_cache
  if c and c.version == self.state.version then return c.json, c.etag end
  local s = schema.encode_state(self.state)
  local etag = '"' .. tostring(self.state.version) .. "-" .. util.hash(s) .. '"'
  self.json_cache = { version = self.state.version, json = s, etag = etag }
  return s, etag
end

function Engine:flatten(now)
  return flatten.flatten(self.state, now or self.deps.now())
end

---------------------------------------------------------------------------
-- state transitions
---------------------------------------------------------------------------

local function differs(a, b, tol)
  if a == nil and b == nil then return false end
  if a == nil or b == nil then return true end
  return math.abs(a - b) > (tol or 0)
end

function Engine:_playback_changes(prev, new)
  -- returns "state" | "position" | nil
  if prev.state ~= new.state or (prev.is_live == true) ~= (new.is_live == true)
    or differs(prev.volume, new.volume, 0.5) then
    return "state"
  end
  if not new.is_live and differs(prev.duration_s, new.duration_s, 2) then return "state" end
  if new.position_s == nil then
    if prev.position_s ~= nil then return "position" end
    return nil
  end
  if prev.position_s == nil then return "position" end
  local expected = prev.position_s
  if prev.state == "playing" then
    local dt = (new.position_updated_at or self.deps.now()) - (prev.position_updated_at or self.deps.now())
    expected = prev.position_s + math.max(0, dt)
  end
  if math.abs(new.position_s - expected) > (self.config.seek_threshold_s or 3) then return "position" end
  return nil
end

function Engine:_apply(pb)
  self.last_pb = util.deep_copy(pb)
  local st = self.state
  local key = M.media_key(pb)
  local changes = {}
  local any = false
  if not util.deep_equal(st.source, pb.source) then
    st.source = pb.source; changes.source = true; any = true
  end
  if not util.deep_equal(st.media, pb.media) then
    st.media = pb.media; changes.media = true; any = true
  end
  local pc = self:_playback_changes(st.playback, pb.playback)
  if pc == "state" then
    st.playback = pb.playback; changes.playback_state = true; any = true
  elseif pc == "position" then
    st.playback = pb.playback; changes.position = true; any = true
  end
  if key ~= st.media_key then
    st.media_key = key
    changes.media = true
    any = true
    local had = st.details ~= nil
    local cached = self.pipeline:peek(key)
    st.details = cached or nil
    if had or st.details then changes.details = true end
    self.enrich_seq = self.enrich_seq + 1
    if self.enrich_timer then self.enrich_timer:cancel(); self.enrich_timer = nil end
    if cached == nil then self:_schedule_enrich(util.deep_copy(pb), key) end
  end
  if any then self:_bump(changes) end
end

function Engine:_schedule_enrich(pb, key)
  local seq = self.enrich_seq
  local function is_current()
    return self.state.media_key == key and self.enrich_seq == seq
  end
  self.enrich_timer = self.deps.set_timer(self.config.enrich_debounce_s or 1.5, function()
    self.enrich_timer = nil
    if not is_current() then return end
    self.pipeline:lookup(pb, key, function(details, info)
      if not is_current() then
        self.deps.log("debug", "discarding stale enrichment for " .. key)
        return
      end
      if details then
        self.state.details = details
        self:_bump({ details = true })
      elseif info and info.errors and #info.errors > 0 then
        self.deps.log("info", "enrichment failed for " .. key .. ": " .. table.concat(info.errors, "; "))
      end
    end, { is_current = is_current })
  end)
end

---------------------------------------------------------------------------
-- polling
---------------------------------------------------------------------------

function Engine:_interval()
  local p = self.config.poll or {}
  if playback_mod.is_active(self.state) then return p.active_s or 2 end
  return p.idle_s or 5
end

function Engine:_schedule(delay, force)
  if self.poll_timer then self.poll_timer:cancel(); self.poll_timer = nil end
  self.poll_timer = self.deps.set_timer(delay, function()
    self.poll_timer = nil
    if self.running or force then self:_poll_now() end
  end)
end

function Engine:_poll_now()
  local now = self.deps.now()
  if self.polling and self.poll_started and now - self.poll_started < M.POLL_WATCHDOG_S then
    self.refresh_pending = true
    return
  end
  self.poll_seq = self.poll_seq + 1
  local seq = self.poll_seq
  self.polling = true
  self.poll_started = now
  self.multi:poll(function(err, pb, info)
    if seq ~= self.poll_seq then return end -- superseded (stop / set_config / watchdog)
    self.polling = false
    self.last_info = info
    if err then
      if self.last_error ~= err then self.deps.log("warn", err) end
      self.last_error = err
      local off = playback_mod.empty("off", self.deps.now())
      self:_apply(off)
    else
      self.last_error = nil
      local ok, aerr = pcall(self._apply, self, pb)
      if not ok then self.deps.log("error", "apply failed: " .. tostring(aerr)) end
    end
    if self.running then
      if self.refresh_pending then
        self.refresh_pending = false
        self:_schedule(0)
      else
        self:_schedule(self:_interval())
      end
    end
  end)
  -- Watchdog: if this poll's callback is lost (a provider that never answers), poll again
  -- after POLL_WATCHDOG_S (the superseded callback is ignored; multi skips the busy provider).
  -- A normal completion re-schedules and so cancels it.
  if self.polling and seq == self.poll_seq and self.running then
    self:_schedule(M.POLL_WATCHDOG_S)
  end
end

function Engine:start()
  if self.running then return end
  self.running = true
  self:_schedule(0)
end

function Engine:stop()
  self.running = false
  self.poll_seq = self.poll_seq + 1
  self.polling = false
  self.enrich_seq = self.enrich_seq + 1
  if self.poll_timer then self.poll_timer:cancel(); self.poll_timer = nil end
  if self.enrich_timer then self.enrich_timer:cancel(); self.enrich_timer = nil end
end

function Engine:refresh()
  if self.polling then
    self.refresh_pending = true
    return
  end
  self:_schedule(0, true)
end

function Engine:get_provider(id)
  return self.multi:get(id)
end

function Engine:push(id, pb)
  local p = self.multi:get(id)
  if not p or not p.push then return false, "no static provider with id " .. tostring(id) end
  p:push(pb)
  return true
end

function Engine:set_config(config)
  config = config or {}
  local old = self.config
  self.config = config
  local function changed(k) return not util.deep_equal(old[k], config[k]) end
  if changed("providers") or changed("sticky_s") or changed("stale_s") then
    local reuse = {}
    for _, e in ipairs(self.multi.entries) do
      if e.p.kind == "static" then reuse[e.p.id] = e.p end
    end
    self:_build_providers(reuse)
    self.poll_seq = self.poll_seq + 1
    self.polling = false
  end
  if changed("enrich") then
    self:_build_pipeline(self.pipeline)
    self.pipeline:clear()
    -- re-enrich what is on screen with the new keys/settings
    self.enrich_seq = self.enrich_seq + 1
    if self.enrich_timer then self.enrich_timer:cancel(); self.enrich_timer = nil end
    if self.last_pb and self.state.media_key ~= "" then
      self:_schedule_enrich(util.deep_copy(self.last_pb), self.state.media_key)
    end
  end
  if changed("room") then
    self.state.room = util.deep_copy(config.room or {})
    self:_bump({ room = true })
  end
  if self.running then self:refresh() end
end

function Engine:get_status()
  return {
    running = self.running, version = self.state.version, media_key = self.state.media_key,
    active_provider = self.multi.active_id, providers = self.multi:status(),
    enrichers = self.pipeline:enabled_names(), last_error = self.last_error,
    merged_from = self.last_info and self.last_info.merged_from or nil,
  }
end

return M
