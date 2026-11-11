--[[
c4.artwork -- embed LAN-only artwork as data: URIs.

A remote Navigator (phone on LTE) cannot load http://192.168.x.x/... images. With "Embed LAN
Artwork" on, artwork/app-icon URLs whose host is private (10/8, 172.16/12, 192.168/16,
127/8, 169.254/16, *.local, localhost, IPv6 ULA/link-local) are downloaded on the controller
and substituted with data:<mime>;base64,... through engine:set_artwork_rewriter(fn).

The rewriter is synchronous and deterministic: it returns the original URL until the
download has finished (then the cached data URI); on completion `on_ready()` is called
(the glue calls engine:refresh()). Failures are remembered for retry_s (no hammering).
The Control4 variables must keep the original URL: restore(state) maps data URIs back.

  local A = Artwork.new(deps, { max_bytes = 262144, max_entries = 12, on_ready = fn })
  A.rewrite(url, kind) -> url | data uri          (bound function, pass to the engine)
  A:restore(state) -> state (in place)            data URIs -> original URLs ("" if unknown)
  A:clear()
  Artwork.is_lan(url) -> bool ; Artwork.sniff(body) -> mime | nil
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
    on_ready = opts.on_ready,
    enabled = opts.enabled ~= false,
    cache = {},      -- url -> { data = uri, used = n }
    by_data = {},    -- data uri -> url
    failed = {},     -- url -> retry_at
    inflight = {},   -- url -> true
    tick = 0,
    stats = { ok = 0, failed = 0 },
  }, A)
  self.rewrite = function(url, kind) return self:_rewrite(url, kind) end
  return self
end

function A:set_enabled(on) self.enabled = on and true or false end

function A:_rewrite(url, kind)
  if not self.enabled or type(url) ~= "string" then return url end
  local e = self.cache[url]
  if e then
    self.tick = self.tick + 1
    e.used = self.tick
    return e.data
  end
  if not M.is_lan(url) or not url:find("^https?://") then return url end
  local retry_at = self.failed[url]
  if retry_at and self.deps.now() < retry_at then return url end
  if not self.inflight[url] then self:_fetch(url) end
  return url
end

function A:_fail(url, why)
  self.inflight[url] = nil
  self.failed[url] = self.deps.now() + self.retry_s
  self.stats.failed = self.stats.failed + 1
  self.deps.log("info", "LAN artwork not embedded (" .. why .. "): " .. url)
end

function A:_fetch(url)
  self.inflight[url] = true
  local gen = self.gen
  self.deps.http.request({ method = "GET", url = url, timeout = self.timeout, headers = { Accept = "image/*" } },
    function(err, resp)
      if gen ~= self.gen then return end -- cleared meanwhile
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
      self.inflight[url] = nil
      self.failed[url] = nil
      self:_store(url, data)
      self.stats.ok = self.stats.ok + 1
      self.deps.log("debug", "LAN artwork embedded (" .. #body .. " bytes): " .. url)
      if self.on_ready then self.on_ready(url) end
    end)
end

function A:_store(url, data)
  self.tick = self.tick + 1
  self.cache[url] = { data = data, used = self.tick }
  self.by_data[data] = url
  local n, oldest, oldest_k = 0, nil, nil
  for k, e in pairs(self.cache) do
    n = n + 1
    if not oldest or e.used < oldest then oldest, oldest_k = e.used, k end
  end
  if n > self.max_entries and oldest_k then
    self.by_data[self.cache[oldest_k].data] = nil
    self.cache[oldest_k] = nil
  end
end

function A:count()
  local n = 0
  for _ in pairs(self.cache) do n = n + 1 end
  return n
end

local function back(self, u)
  if type(u) == "string" and u:find("^data:") then return self.by_data[u] or nil end
  return u
end

-- Replace data URIs in a state copy by their original URLs (never leaks a data URI).
function A:restore(state)
  if type(state) ~= "table" then return state end
  if state.media then state.media.artwork_url = back(self, state.media.artwork_url) end
  if state.source then state.source.app_icon_url = back(self, state.source.app_icon_url) end
  return state
end

function A:clear()
  self.gen = (self.gen or 0) + 1
  self.cache, self.by_data, self.failed, self.inflight = {}, {}, {}, {}
end

return M
