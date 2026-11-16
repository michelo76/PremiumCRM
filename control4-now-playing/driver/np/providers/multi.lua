--[[
np.providers.multi -- polls an ordered list of providers and picks the active one.

  Multi.new(providers, config, deps)
      providers: ordered list of provider objects (each has :poll(cb), .id, optional .group)
      config:    { sticky_s = 10, stale_s = 10, backoff_base_s = 2, backoff_max_s = 60 }
  multi:poll(cb)    cb(err, playback, info)  info = { active_id =, merged_from =, errors = {id=err} }
  multi:status()    -> list of { id, kind, group, ok, last_error, fails, next_try, state, active }
  multi:get(id)     -> provider

Selection: rank playing(5) > buffering(4) > paused(3) > stopped(2) > idle(1) > off(0); ties
go to list order. Sticky: the currently active provider is kept while its rank is >= the best
candidate, or while it is still paused/buffering and was playing within sticky_s seconds.

Error handling (per provider): a failing provider is retried with exponential backoff
(2, 4, 8 ... 60 s); its last good result is still used for stale_s seconds so a single
dropped request does not blank the screen.

Merge: when the chosen result lacks a title, another provider in the same `group` (same
physical device, e.g. Roku ECP transport + Home Assistant title) that is playing/paused/
buffering donates missing media fields.
]]

local util = require("np.util")

local M = {}

M.RANK = { playing = 5, buffering = 4, paused = 3, stopped = 2, idle = 1, off = 0 }
local RANK = M.RANK

local MERGE_FIELDS = { "title", "subtitle", "series_title", "season", "episode", "episode_title",
  "artist", "album", "album_artist", "track_number", "channel_name", "channel_number", "year",
  "artwork_url" }

local Multi = {}
Multi.__index = Multi

function M.new(providers, config, deps)
  local self = setmetatable({}, Multi)
  self.deps = deps
  self.config = config or {}
  self.entries = {}
  for i, p in ipairs(providers or {}) do
    self.entries[i] = { p = p, id = p.id or ("provider" .. i), group = p.group, fails = 0, next_try = 0 }
  end
  self.active_id = nil
  self.switched_at = nil
  return self
end

function Multi:get(id)
  for _, e in ipairs(self.entries) do if e.id == id then return e.p end end
  return nil
end

local function rank_of(pb)
  return RANK[pb and pb.playback and pb.playback.state or "off"] or 0
end

function Multi:_usable(e, now)
  if not e.last then return nil end
  if e.fresh then return e.last end
  local stale = self.config.stale_s or 10
  if e.last_ok_at and now - e.last_ok_at <= stale then return e.last end
  return nil
end

function Multi:_record(e, err, pb)
  local now = self.deps.now()
  e.busy = false
  if err or type(pb) ~= "table" then
    e.fails = e.fails + 1
    e.fresh = false
    e.last_error = tostring(err or "no result")
    local base = self.config.backoff_base_s or 2
    local maxb = self.config.backoff_max_s or 60
    local delay = math.min(maxb, base * (2 ^ (e.fails - 1)))
    e.next_try = now + delay
    if e.fails == 1 or e.fails % 10 == 0 then
      self.deps.log("warn", "provider " .. e.id .. " failed (" .. e.fails .. "x, retry in " .. delay .. "s): " .. e.last_error)
    end
  else
    if e.fails > 0 then self.deps.log("info", "provider " .. e.id .. " recovered") end
    e.fails = 0
    e.next_try = 0
    e.last_error = nil
    e.last = pb
    e.last_ok_at = now
    e.fresh = true
    if pb.playback and pb.playback.state == "playing" then e.last_playing_at = now end
  end
end

function Multi:poll(cb)
  local now = self.deps.now()
  local remaining = 1
  local finished = false
  local function step()
    remaining = remaining - 1
    if remaining == 0 and not finished then
      finished = true
      self:_choose(cb)
    end
  end
  for _, e in ipairs(self.entries) do
    if e.busy and e.busy_since and now - e.busy_since > 60 then
      e.busy = false -- a provider callback was lost; do not wedge forever
    end
    if not e.busy and now >= (e.next_try or 0) then
      remaining = remaining + 1
      e.busy = true
      e.busy_since = now
      local called = false
      local ok, perr = pcall(e.p.poll, e.p, function(err, pb)
        if called then return end
        called = true
        self:_record(e, err, pb)
        step()
      end)
      if not ok and not called then
        called = true
        self:_record(e, "provider crashed: " .. tostring(perr))
        step()
      end
    else
      e.fresh = false
    end
  end
  step()
end

function Multi:_choose(cb)
  local now = self.deps.now()
  local cands, errors = {}, {}
  for _, e in ipairs(self.entries) do
    local pb = self:_usable(e, now)
    if pb then cands[#cands + 1] = { e = e, pb = pb, r = rank_of(pb) } end
    if e.last_error then errors[e.id] = e.last_error end
  end
  if #cands == 0 then
    local msgs = {}
    for _, e in ipairs(self.entries) do
      msgs[#msgs + 1] = e.id .. ": " .. tostring(e.last_error or "no data yet")
    end
    return cb("no provider available (" .. table.concat(msgs, "; ") .. ")", nil, { errors = errors })
  end
  local best = cands[1]
  for i = 2, #cands do
    if cands[i].r > best.r then best = cands[i] end
  end
  local cur
  for _, c in ipairs(cands) do if c.e.id == self.active_id then cur = c end end
  if cur and cur ~= best then
    local sticky = self.config.sticky_s or 10
    if cur.r >= best.r then
      best = cur
    elseif cur.r >= RANK.paused and cur.e.last_playing_at and now - cur.e.last_playing_at < sticky then
      best = cur
    end
  end
  if self.active_id ~= best.e.id then
    if self.active_id then
      self.deps.log("info", "active provider " .. tostring(self.active_id) .. " -> " .. best.e.id)
    end
    self.active_id = best.e.id
    self.switched_at = now
  end
  local result = util.deep_copy(best.pb)
  local info = { active_id = best.e.id, errors = errors }
  if best.e.group and not result.media.title then
    for _, c in ipairs(cands) do
      if c ~= best and c.e.group == best.e.group and c.r >= RANK.paused and c.pb.media.title then
        M.merge_media(result, c.pb)
        info.merged_from = c.e.id
        break
      end
    end
  end
  cb(nil, result, info)
end

-- Fill missing media fields of `into` from `donor` (same physical device).
function M.merge_media(into, donor)
  local m, d = into.media, donor.media
  for _, f in ipairs(MERGE_FIELDS) do
    if m[f] == nil and d[f] ~= nil then m[f] = d[f] end
  end
  if (not m.genres or #m.genres == 0) and d.genres and #d.genres > 0 then m.genres = util.deep_copy(d.genres) end
  if (m.kind == "unknown" or m.kind == "video") and d.kind ~= "unknown" and d.kind ~= "video" then
    m.kind = d.kind
  end
  if not into.source.app_name and donor.source.app_name then into.source.app_name = donor.source.app_name end
  if not into.playback.duration_s and donor.playback.duration_s then
    into.playback.duration_s = donor.playback.duration_s
  end
  return into
end

function Multi:status()
  local out = {}
  for _, e in ipairs(self.entries) do
    out[#out + 1] = {
      id = e.id, kind = e.p.kind, group = e.group, ok = e.last_error == nil and e.last ~= nil,
      last_error = e.last_error, fails = e.fails, next_try = e.next_try,
      state = e.last and e.last.playback.state or nil, active = (e.id == self.active_id),
    }
  end
  return out
end

return M
