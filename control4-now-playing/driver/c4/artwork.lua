--[[
c4.artwork -- on-demand artwork fetcher for the web view (GET_ARTWORK).

A remote Navigator (phone on LTE) cannot load http://192.168.x.x/... images. The state
document always keeps the ORIGINAL image URLs (small STATE_JSON / DataToUI payloads); the
PAGE decides it needs help -- the URL's host is private-LAN / relative (is_lan, the same rule
as the page's isLan()) or an <img> failed to load -- and asks the driver:

  page:   C4.sendCommand("GET_ARTWORK", JSON.stringify({url: u}), true, false)
  driver: ExecuteCommand("GET_ARTWORK") -> c4.app checks that `u` is an image URL of the
          CURRENT state (no open proxy) -> A:fetch(u, cb) -> downloads (size cap, LRU cache,
          failure back-off, one request per URL however many pages ask) ->
          C4:SendDataToUI("NOW_PLAYING_ARTWORK", { url = u, data = "data:image/...;base64,..." })
          or                                     { url = u, error = "..." }
With "Embed LAN Artwork" Off, GET_ARTWORK is answered with an error (page shows its
generated artwork).

  local A = Artwork.new(deps, { max_bytes = 262144, max_entries = 12, retry_s = 300 })
  A:fetch(url, cb)          cb(err|nil, data_uri|nil) exactly once; cached hits answer synchronously
  A:set_auth({ { prefix = "http://bridge:8765/", headers = { Authorization = "Bearer ..." } } })
                            extra request headers for URLs under a prefix (Apple TV bridge token)
  A:set_enabled(bool) ; A:count() ; A:clear()
  Artwork.is_lan(url) -> bool ; Artwork.sniff(body) -> mime | nil ; Artwork.host_of(url)
]]

local M = {}

local function octets(host)
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

function M.host_of(url)
  if type(url) ~= "string" then return nil end
  local hp = url:match("^%a[%w+.-]*://([^/?#]+)")
  if not hp then return nil end
  hp = hp:gsub("^.*@", "")
  local v6 = hp:match("^%[([^%]]+)%]")
  if v6 then return v6:lower() end
  return (hp:gsub(":%d+$", "")):lower()
end

function M.is_lan(url)
  if type(url) ~= "string" or url == "" then return false end
  if url:find("^data:") then return false end
  if not url:find("^%a[%w+.-]*://") then return true end -- relative: only resolvable on the LAN
  local host = M.host_of(url)
  if not host then return false end
  if host == "localhost" or host:find("%.local$") or host:find("%.lan$") or host:find("%.home%.arpa$") then
    return true
  end
  local a, b = octets(host)
  if a then
    if a == 10 or a == 127 then return true end
    if a == 172 and b >= 16 and b <= 31 then return true end
    if a == 192 and b == 168 then return true end
    if a == 169 and b == 254 then return true end
    return false
  end
  if host:find(":") then
    if host == "::1" or host:find("^f[cd]") or host:find("^fe[89ab]") then return true end
    return false
  end
  if not host:find("%.") then return true end -- single-label hostname ("nas", "homeassistant")
  return false
end

function M.sniff(body)
  if type(body) ~= "string" or #body < 4 then return nil end
  if body:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png" end
  if body:sub(1, 3) == "\255\216\255" then return "image/jpeg" end
  if body:sub(1, 4) == "GIF8" then return "image/gif" end
  if body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP" then return "image/webp" end
  if body:sub(1, 2) == "BM" then return "image/bmp" end
  local head = body:sub(1, 256):lower()
  if head:find("<svg", 1, true) then return "image/svg+xml" end
  return nil
end

local A = {}
A.__index = A

function M.new(deps, opts)
  opts = opts or {}
  local self = setmetatable({
    deps = deps,
    max_bytes = opts.max_bytes or 262144,
    max_entries = opts.max_entries or 12,
    retry_s = opts.retry_s or 300,
    timeout = opts.timeout or 8,
    enabled = opts.enabled ~= false,
    auth = {},       -- { { prefix = "http://host:port/", headers = {...} }, ... }
    cache = {},      -- url -> { data = uri, used = n }
    failed = {},     -- url -> { at = retry_at, err = "..." }
    waiters = {},    -- url -> { cb, ... } while a download is in flight
    gen = 0,
    tick = 0,
    stats = { ok = 0, failed = 0 },
  }, A)
  return self
end

function A:set_enabled(on) self.enabled = on and true or false end

function A:set_auth(list) self.auth = list or {} end

function A:_headers(url)
  local h = { Accept = "image/*" }
  for _, a in ipairs(self.auth) do
    if type(a.prefix) == "string" and a.prefix ~= "" and url:sub(1, #a.prefix) == a.prefix then
      for k, v in pairs(a.headers or {}) do h[k] = v end
    end
  end
  return h
end

local function call(cb, err, data)
  local ok, e = pcall(cb, err, data)
  return ok, e
end

-- cb(err, data_uri): exactly once. Cached results (and remembered failures) answer at once.
function A:fetch(url, cb)
  if not self.enabled then return call(cb, "disabled") end
  if type(url) ~= "string" or not url:find("^https?://[^/]") then return call(cb, "not an http(s) URL") end
  local e = self.cache[url]
  if e then
    self.tick = self.tick + 1
    e.used = self.tick
    return call(cb, nil, e.data)
  end
  local f = self.failed[url]
  if f and self.deps.now() < f.at then return call(cb, f.err) end
  if self.waiters[url] then
    table.insert(self.waiters[url], cb)
    return
  end
  self.waiters[url] = { cb }
  self:_download(url)
end

function A:_finish(url, err, data)
  local list = self.waiters[url] or {}
  self.waiters[url] = nil
  for _, cb in ipairs(list) do
    local ok, e = call(cb, err, data)
    if not ok then self.deps.log("error", "artwork callback failed: " .. tostring(e)) end
  end
end

function A:_fail(url, why)
  self.failed[url] = { at = self.deps.now() + self.retry_s, err = why }
  self.stats.failed = self.stats.failed + 1
  self.deps.log("info", "artwork not fetched (" .. why .. "): " .. url)
  self:_finish(url, why)
end

function A:_download(url)
  local gen = self.gen
  self.deps.http.request({ method = "GET", url = url, timeout = self.timeout, headers = self:_headers(url) },
    function(err, resp)
      if gen ~= self.gen then return end -- cleared meanwhile (waiters were dropped with it)
      if err then return self:_fail(url, tostring(err)) end
      local status = tonumber(resp.status) or 0
      if status < 200 or status >= 300 then return self:_fail(url, "HTTP " .. status) end
      local body = resp.body or ""
      local len
      for k, v in pairs(resp.headers or {}) do
        if type(k) == "string" and k:lower() == "content-length" then len = tonumber(v) end
      end
      if (len and len > self.max_bytes) or #body > self.max_bytes then
        return self:_fail(url, "too large: " .. tostring(len or #body) .. " bytes > " .. self.max_bytes)
      end
      if #body == 0 then return self:_fail(url, "empty body") end
      local mime
      for k, v in pairs(resp.headers or {}) do
        if type(k) == "string" and k:lower() == "content-type" and type(v) == "string" then
          mime = v:match("^%s*([%w%-%.+]+/[%w%-%.+]+)")
        end
      end
      local sniffed = M.sniff(body)
      if not mime or not mime:lower():find("^image/") then mime = sniffed end
      if not mime then return self:_fail(url, "not an image") end
      local data = "data:" .. mime:lower() .. ";base64," .. self.deps.base64(body)
      self.failed[url] = nil
      self:_store(url, data)
      self.stats.ok = self.stats.ok + 1
      self.deps.log("debug", "artwork fetched (" .. #body .. " bytes): " .. url)
      self:_finish(url, nil, data)
    end)
end

function A:_store(url, data)
  self.tick = self.tick + 1
  self.cache[url] = { data = data, used = self.tick }
  local n, oldest, oldest_k = 0, nil, nil
  for k, e in pairs(self.cache) do
    n = n + 1
    if not oldest or e.used < oldest then oldest, oldest_k = e.used, k end
  end
  if n > self.max_entries and oldest_k then self.cache[oldest_k] = nil end
end

function A:count()
  local n = 0
  for _ in pairs(self.cache) do n = n + 1 end
  return n
end

-- Drops the cache; downloads in flight are answered "cancelled" (callbacks stay exactly-once).
function A:clear()
  self.gen = self.gen + 1
  local pending = self.waiters
  self.cache, self.failed, self.waiters = {}, {}, {}
  for url, list in pairs(pending) do
    for _, cb in ipairs(list) do call(cb, "cancelled") end
  end
end

return M
