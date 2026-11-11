--[[
np.enrich.pipeline -- runs the applicable enrichers in order (tmdb -> omdb -> gracenote ->
music), deep-merges their partial results, caches by media_key and coalesces concurrent
lookups.

  Pipeline.new(enrich_config, deps, opts)
      enrich_config = { tmdb = {...}, omdb = {...}, gracenote = {...}, music = {...},
                        cache = { max = 50, ttl_s = 21600, negative_ttl_s = 600, error_ttl_s = 120,
                                  persist = false, persist_entries = 10, persist_key = "np_enrich_cache_v1" } }
      Enrichers are enabled only when configured: tmdb (api_key|bearer), omdb (api_key),
      gracenote (api_key). music (keyless) is on unless music.enabled == false.
      opts.enrichers = { ... } injects enricher objects instead (tests).
  pipeline:lookup(playback, media_key, cb, opts)   cb(details|nil, info)
      info = { cached = bool, negative = bool, aborted = bool, unsupported = bool, errors = {..} }
      opts.is_current() -> false aborts between enricher steps (result neither cached nor used).
      cb may be invoked synchronously (cache hit).
  pipeline:peek(media_key) -> details | false (negative entry) | nil (unknown)
  pipeline:enabled_names() -> {"TMDB", ...}
  Pipeline.merge(acc, partial) / Pipeline.finalize(acc)  (exposed for tests)

Merge rules: later enrichers only fill gaps (scalars nil/"" and empty arrays); nested tables
(ratings, ids, links, crew, episode, series, music, live) merge key by key; facts append
de-duplicated by label; attribution accumulates unique names; matched = any; confidence =
first provided. partial._hints is collected into ctx.hints (never published).
]]

local util = require("np.util")
local json = require("np.json")
local Cache = require("np.cache")

local M = {}

local Pipeline = {}
Pipeline.__index = Pipeline

local function build_enrichers(cfg, deps)
  local list = {}
  local function add(modname, c)
    local ok, e = pcall(function() return require(modname).new(c, deps) end)
    if ok then list[#list + 1] = e else deps.log("error", "enricher " .. modname .. ": " .. tostring(e)) end
  end
  if cfg.tmdb and (util.nonempty(cfg.tmdb.api_key) or util.nonempty(cfg.tmdb.bearer)) then
    add("np.enrich.tmdb", cfg.tmdb)
  end
  if cfg.omdb and util.nonempty(cfg.omdb.api_key) then add("np.enrich.omdb", cfg.omdb) end
  if cfg.gracenote and util.nonempty(cfg.gracenote.api_key) then add("np.enrich.gracenote", cfg.gracenote) end
  local music = cfg.music or {}
  if music.enabled ~= false then add("np.enrich.music", music) end
  return list
end

function M.new(config, deps, opts)
  config = config or {}
  opts = opts or {}
  local self = setmetatable({}, Pipeline)
  self.config = config
  self.deps = deps
  local cc = config.cache or {}
  self.ttl = cc.ttl_s or 21600
  self.neg_ttl = cc.negative_ttl_s or 600
  self.err_ttl = cc.error_ttl_s or 120
  self.cache = opts.cache or Cache.new(cc.max or 50)
  self.enrichers = opts.enrichers or build_enrichers(config, deps)
  self.inflight = {}
  self.persist = cc.persist and deps.store ~= nil
  self.persist_key = cc.persist_key or "np_enrich_cache_v1"
  self.persist_entries = cc.persist_entries or 10
  if self.persist and not opts.cache then self:_load() end
  return self
end

function Pipeline:enabled_names()
  local out = {}
  for _, e in ipairs(self.enrichers) do out[#out + 1] = e.attribution or e.name end
  return out
end

---------------------------------------------------------------------------
-- merge
---------------------------------------------------------------------------

local function is_empty(t) return type(t) == "table" and next(t) == nil end

local function fill(dst, k, v)
  local cur = dst[k]
  if type(v) == "table" then
    if next(v) == nil then
      if cur == nil then dst[k] = {} end
    elseif util.is_list(v) then
      if cur == nil or is_empty(cur) then dst[k] = util.deep_copy(v) end
    else
      if type(cur) ~= "table" then
        if cur ~= nil then return end
        cur = {}
        dst[k] = cur
      end
      for kk, vv in pairs(v) do fill(cur, kk, vv) end
    end
  elseif v ~= nil then
    if cur == nil or cur == "" then dst[k] = v end
  end
end

function M.merge(acc, part, hints)
  for k, v in pairs(part or {}) do
    if k == "_hints" then
      if hints and type(v) == "table" then for hk, hv in pairs(v) do if hints[hk] == nil then hints[hk] = hv end end end
    elseif k == "facts" then
      acc.facts = acc.facts or {}
      local seen = {}
      for _, f in ipairs(acc.facts) do seen[f.label] = true end
      for _, f in ipairs(v) do
        if f.label and f.value and not seen[f.label] then
          seen[f.label] = true
          acc.facts[#acc.facts + 1] = { label = f.label, value = f.value }
        end
      end
    elseif k == "attribution" then
      acc.attribution = acc.attribution or {}
      for _, name in ipairs(v) do
        local dup = false
        for _, x in ipairs(acc.attribution) do if x == name then dup = true end end
        if not dup then acc.attribution[#acc.attribution + 1] = name end
      end
    elseif k == "matched" then
      acc.matched = acc.matched or (v == true)
    elseif k == "confidence" then
      if acc.confidence == nil then acc.confidence = v end
    else
      fill(acc, k, v)
    end
  end
  return acc
end

local ARRAYS = { "genres", "cast", "networks", "studios", "facts", "attribution" }

function M.finalize(acc)
  local d = util.deep_copy(acc)
  d._hints = nil
  for _, k in ipairs(ARRAYS) do if type(d[k]) ~= "table" then d[k] = {} end end
  d.crew = type(d.crew) == "table" and d.crew or {}
  for _, k in ipairs({ "directors", "writers", "creators" }) do
    if type(d.crew[k]) ~= "table" then d.crew[k] = {} end
  end
  for _, k in ipairs({ "ratings", "ids", "links" }) do
    if type(d[k]) ~= "table" then d[k] = {} end
  end
  if type(d.music) == "table" and type(d.music.album_tracks) ~= "table" then d.music.album_tracks = {} end
  d.matched = d.matched == true
  if d.confidence then d.confidence = util.round(d.confidence, 2) end
  if #d.cast > 20 then
    local c = {}
    for i = 1, 20 do c[i] = d.cast[i] end
    d.cast = c
  end
  return d
end

---------------------------------------------------------------------------
-- lookup
---------------------------------------------------------------------------

function Pipeline:peek(key)
  local v = self.cache:get(key, self.deps.now())
  return v
end

function Pipeline:_applicable(pb, ctx)
  local list = {}
  for _, e in ipairs(self.enrichers) do
    local ok, sup = pcall(e.supports, e, pb, ctx)
    if ok and sup then list[#list + 1] = e end
  end
  return list
end

function Pipeline:lookup(pb, key, cb, opts)
  opts = opts or {}
  local now = self.deps.now()
  local cached = self.cache:get(key, now)
  if cached ~= nil then
    if cached == false then return cb(nil, { cached = true, negative = true }) end
    return cb(cached, { cached = true })
  end
  if self.inflight[key] then
    table.insert(self.inflight[key], cb)
    return
  end
  local ctx = { details = {}, hints = {} }
  if #self:_applicable(pb, ctx) == 0 then
    return cb(nil, { unsupported = true })
  end
  local waiters = { cb }
  self.inflight[key] = waiters
  local errors, nomatch = {}, 0
  local snapshot = util.deep_copy(pb)

  local function finish(details, info)
    self.inflight[key] = nil
    for _, w in ipairs(waiters) do
      local ok, e = pcall(w, details, info)
      if not ok then self.deps.log("error", "enrich callback failed: " .. tostring(e)) end
    end
  end

  local i = 0
  local step
  step = function()
    i = i + 1
    local e = self.enrichers[i]
    -- abort before spending more API calls on media that is no longer current; a chain that
    -- already completed is still cached (cheap to reuse if the user switches back).
    if e and opts.is_current and not opts.is_current() then
      return finish(nil, { aborted = true, errors = errors })
    end
    if not e then
      local t = self.deps.now()
      if ctx.details.matched then
        local details = M.finalize(ctx.details)
        self.cache:set(key, details, self.ttl, t)
        self:_schedule_save()
        return finish(details, { errors = errors })
      end
      if #errors > 0 and nomatch == 0 then
        self.cache:set(key, false, self.err_ttl, t)
      else
        self.cache:set(key, false, self.neg_ttl, t)
      end
      return finish(nil, { negative = true, errors = errors })
    end
    local ok_sup, sup = pcall(e.supports, e, snapshot, ctx)
    if not ok_sup or not sup then return step() end
    local called = false
    local function on_result(err, partial)
      if called then return end
      called = true
      if err then
        errors[#errors + 1] = tostring(err)
        self.deps.log("warn", "enrich " .. tostring(e.name) .. ": " .. tostring(err))
      elseif type(partial) == "table" then
        M.merge(ctx.details, partial, ctx.hints)
      else
        nomatch = nomatch + 1
      end
      step()
    end
    local ok, perr = pcall(e.enrich, e, snapshot, on_result, ctx)
    if not ok then on_result("crashed: " .. tostring(perr)) end
  end
  step()
end

function Pipeline:clear()
  self.cache = Cache.new(self.cache.max)
end

---------------------------------------------------------------------------
-- persistence (optional, compact)
---------------------------------------------------------------------------

function Pipeline:_load()
  local ok, raw = pcall(self.deps.store.get, self.persist_key)
  if not ok or raw == nil then return end
  local data = raw
  if type(raw) == "string" then data = json.decode(raw) end
  if type(data) ~= "table" then return end
  local now = self.deps.now()
  for i = #data, 1, -1 do
    local e = data[i]
    if type(e) == "table" and e.k and type(e.d) == "table" and tonumber(e.x) and tonumber(e.x) > now then
      self.cache:set(e.k, M.finalize(e.d), tonumber(e.x) - now, now)
    end
  end
end

function Pipeline:_schedule_save()
  if not self.persist or self.save_timer then return end
  self.save_timer = self.deps.set_timer(5, function()
    self.save_timer = nil
    self:save()
  end)
end

function Pipeline:save()
  if not self.persist then return end
  local out = {}
  for _, e in ipairs(self.cache:entries()) do
    if e.value and #out < self.persist_entries then
      local d = util.deep_copy(e.value)
      if d.cast and #d.cast > 10 then
        local c = {}
        for i = 1, 10 do c[i] = d.cast[i] end
        d.cast = c
      end
      out[#out + 1] = { k = e.key, x = e.expires, d = d }
    end
  end
  local s = json.encode(out)
  if s then pcall(self.deps.store.set, self.persist_key, s) end
end

return M
