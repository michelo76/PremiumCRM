--[[
c4.httpserver -- tiny LAN HTTP endpoint (property "LAN Web Port", default 8487, 0 = off).
It is the page's fallback transport ("LAN relay") when the Navigator JS API delivers nothing.

  GET|HEAD /  and /index.html   the web UI, read from the c4z (www/index.html) -- no token
  GET|HEAD /api/state?k=<tok>   state JSON; ETag / If-None-Match (or ?inm=<etag>, which needs
                                no CORS preflight) -> 304; Cache-Control: no-store
  GET|HEAD /api/artwork?url=<u>&k=<tok>
                                the image bytes of <u>, which must be an image of the CURRENT
                                state (same rule as GET_ARTWORK; size-capped by c4.artwork)
  OPTIONS  *                    CORS preflight -> 204
  anything else                 404 (405 for other methods, 413 for oversized requests,
                                401 for a missing/wrong token, 408 for a stalled client)
Every response carries Connection: close, a Date header and Access-Control-Allow-Origin: *
(the page's origin is controller://..., the token is the protection) plus
Access-Control-Expose-Headers: ETag, Date. The client is closed after the response and its
buffer is freed; a client that has not sent a complete request within IDLE_S is closed.

C4 API notes (Snap One docs): C4:CreateServer(port, delimiter, useUDP, identifier) returns
false, err on failure (it does not throw); the identifier argument exists since OS 3.3.1 and
is passed back as the last argument of OnServerDataIn / OnServerConnectionStatusChanged.
Older OSes take C4:CreateServer(port): if the 4-argument call throws, the 1-argument form is
tried. C4:DestroyServer(port) needs the port. A failed listen is retried with backoff
(RETRY_MIN_S doubling up to RETRY_MAX_S); handlers.on_listen is called on every change.

  local S = Server.new(C4, deps, {
    state   = fn() -> json, etag ;   index = fn() -> html|nil ;
    token   = fn() -> string ;       -- required by /api/*; nil/"" refuses everything
    artwork = fn(url, cb) ;          -- cb(status, headers, body) exactly once (may be async)
    on_listen = fn(listening, port, err) })
  S:start(port) -> ok, err      S:stop()       S.listening, S.port, S.last_error
  S:on_data(handle, data, address, port, identifier)       from OnServerDataIn
  S:on_status(handle, port, status, address, identifier)   from OnServerConnectionStatusChanged
  Server.parse_request(raw)     -> { method, path, query, headers } | nil, err  (pure)
  Server.parse_query(qs) ; Server.token_eq(given, expected)                   (pure)
]]

local M = {}

M.MAX_REQUEST = 8192
M.MAX_CLIENTS = 32
M.IDLE_S = 10
M.RETRY_MIN_S = 5
M.RETRY_MAX_S = 300
M.IDENTIFIER = "now_playing_info_lan"

local REASONS = {
  [200] = "OK", [204] = "No Content", [304] = "Not Modified", [400] = "Bad Request", [401] = "Unauthorized",
  [403] = "Forbidden", [404] = "Not Found", [405] = "Method Not Allowed", [408] = "Request Timeout",
  [413] = "Payload Too Large", [500] = "Internal Server Error", [502] = "Bad Gateway",
  [503] = "Service Unavailable",
}

function M.http_date(t)
  return os.date("!%a, %d %b %Y %H:%M:%S GMT", t)
end

local function unescape(s)
  s = s:gsub("%+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function M.parse_query(qs)
  local q = {}
  for pair in tostring(qs or ""):gmatch("[^&;]+") do
    local k, v = pair:match("^([^=]*)=(.*)$")
    if not k then k, v = pair, "" end
    k = unescape(k)
    if k ~= "" and q[k] == nil then q[k] = unescape(v) end
  end
  return q
end

-- Compares every byte of the expected token whatever the input (no early exit on the first
-- mismatch), so the response time does not reveal how much of a guess was right.
function M.token_eq(given, expected)
  if type(given) ~= "string" or type(expected) ~= "string" or expected == "" then return false end
  local diff = (#given == #expected) and 0 or 1
  for i = 1, #expected do
    if given:byte(i) ~= expected:byte(i) then diff = diff + 1 end
  end
  return diff == 0
end

function M.parse_request(raw)
  local head = raw:match("^(.-)\r?\n\r?\n")
  if not head then return nil, "incomplete" end
  local lines = {}
  for line in (head .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  local method, target, ver = (lines[1] or ""):match("^(%u+)%s+(%S+)%s+HTTP/(%d%.%d)$")
  if not method then return nil, "bad request line" end
  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.-)%s*$")
    if k then headers[k:lower()] = v end
  end
  local path = target:gsub("[?#].*$", "")
  local qs = target:match("%?([^#]*)") or ""
  return { method = method, target = target, path = path, query = M.parse_query(qs), version = ver, headers = headers }
end

-- An identifier argument that names some other server of this driver (strings that look like
-- an address are the client address, not an identifier).
local function foreign(id)
  return type(id) == "string" and id ~= "" and id ~= M.IDENTIFIER and not id:find("^[%x%.:%[%]]+$")
end

local S = {}
S.__index = S

function M.new(C4, deps, handlers)
  return setmetatable({
    C4 = C4, deps = deps, h = handlers or {},
    buffers = {}, nbuf = 0, done = {}, idle = {}, conn = {}, serial = 0,
    port = nil, want = nil, listening = false, last_error = nil, retry = nil, retry_s = M.RETRY_MIN_S,
  }, S)
end

function S:_notify()
  if self.h.on_listen then pcall(self.h.on_listen, self.listening, self.port or self.want, self.last_error) end
end

-- C4:CreateServer: 4-argument form (identifier, OS 3.3.1+) first, the 1-argument form when that
-- throws. Returns ok, err. A `false, err` return is a failure; anything else is success.
function S:_create(port)
  local C4 = self.C4
  local ok, r1, r2 = pcall(C4.CreateServer, C4, port, "", false, M.IDENTIFIER)
  if not ok then
    local first = r1
    ok, r1, r2 = pcall(C4.CreateServer, C4, port)
    if not ok then return false, tostring(r1 or first) end
    self.legacy = true
  end
  if r1 == false then return false, tostring(r2 or "CreateServer failed") end
  return true
end

function S:start(port)
  port = tonumber(port)
  if not port or port <= 0 then
    local was = self.want or self.listening
    self:stop()
    if was then self:_notify() end
    return false, "disabled"
  end
  if self.want == port then
    if self.listening then return true end
    return false, self.last_error -- a retry is already scheduled
  end
  self:stop()
  self.want = port
  self.retry_s = M.RETRY_MIN_S
  return self:_listen()
end

function S:_listen()
  local port = self.want
  if not port then return false, "disabled" end
  if not self.C4.CreateServer then
    self.last_error = "C4:CreateServer unavailable"
    self:_notify()
    return false, self.last_error
  end
  local ok, err = self:_create(port)
  if not ok then
    self.listening, self.port, self.last_error = false, nil, err
    local wait = self.retry_s
    self.retry_s = math.min(self.retry_s * 2, M.RETRY_MAX_S)
    self.deps.log("error", "LAN web server on port " .. port .. " failed: " .. tostring(err) .. " (retry in " .. wait .. " s)")
    if self.retry then self.retry:cancel() end
    self.retry = self.deps.set_timer(wait, function()
      self.retry = nil
      if self.want == port and not self.listening then self:_listen() end
    end)
    self:_notify()
    return false, err
  end
  self.listening, self.port, self.last_error = true, port, nil
  self.retry_s = M.RETRY_MIN_S
  self.deps.log("info", "LAN web server listening on port " .. port)
  self:_notify()
  return true
end

function S:stop()
  if self.retry then self.retry:cancel(); self.retry = nil end
  if self.listening and self.port and self.C4.DestroyServer then
    pcall(self.C4.DestroyServer, self.C4, self.port)
  end
  for _, t in pairs(self.idle) do t:cancel() end
  self.port, self.want, self.listening, self.last_error = nil, nil, false, nil
  self.buffers, self.nbuf, self.done, self.idle, self.conn = {}, 0, {}, {}, {}
end

function S:_free(h)
  if self.buffers[h] ~= nil then
    self.buffers[h] = nil
    self.nbuf = self.nbuf - 1
  end
  local t = self.idle[h]
  if t then t:cancel(); self.idle[h] = nil end
end

-- A new connection on handle h (handle numbers are reused): fresh id, idle timer.
function S:_open(h)
  self:_free(h)
  self.done[h] = nil
  self.serial = self.serial + 1
  local id = self.serial
  self.conn[h] = id
  self.idle[h] = self.deps.set_timer(M.IDLE_S, function()
    self.idle[h] = nil
    if self.conn[h] ~= id or self.done[h] then return end
    self.deps.log("debug", "LAN HTTP client " .. tostring(h) .. " idle for " .. M.IDLE_S .. " s: closed")
    self:_send(h, 408, { ["Content-Type"] = "text/plain" }, "request timeout\n")
  end)
end

function S:on_status(h, port, status, a4, a5)
  if foreign(a4) or foreign(a5) then return end
  status = tostring(status):upper()
  if status == "ONLINE" then
    self:_open(h)
  elseif status == "OFFLINE" then
    self:_free(h)
    self.done[h] = nil
    self.conn[h] = nil -- an async response still in flight is dropped
  end
end

function S:_send(h, status, headers, body, head_only)
  body = body or ""
  local out = { "HTTP/1.1 " .. status .. " " .. (REASONS[status] or "Status") }
  headers = headers or {}
  headers["Date"] = M.http_date(self.deps.now())
  headers["Connection"] = "close"
  headers["Content-Length"] = tostring(#body)
  headers["Access-Control-Allow-Origin"] = "*"
  headers["Access-Control-Expose-Headers"] = "ETag, Date"
  local keys = {}
  for k in pairs(headers) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do out[#out + 1] = k .. ": " .. headers[k] end
  local payload = table.concat(out, "\r\n") .. "\r\n\r\n"
  if not head_only and status ~= 304 and status ~= 204 then payload = payload .. body end
  pcall(self.C4.ServerSend, self.C4, h, payload)
  pcall(self.C4.ServerCloseClient, self.C4, h)
  self:_free(h)
  self.done[h] = true -- ignore anything still arriving on this connection
end

function S:on_data(h, data, address, port, identifier)
  if foreign(identifier) then return end
  if self.done[h] then return end
  if self.conn[h] == nil then self:_open(h) end -- data without a prior ONLINE
  if self.buffers[h] == nil then
    if self.nbuf >= M.MAX_CLIENTS then
      return self:_send(h, 503, { ["Content-Type"] = "text/plain" }, "busy\n")
    end
    self.buffers[h] = ""
    self.nbuf = self.nbuf + 1
  end
  local buf = self.buffers[h] .. (data or "")
  if #buf > M.MAX_REQUEST then
    return self:_send(h, 413, { ["Content-Type"] = "text/plain" }, "request too large\n")
  end
  self.buffers[h] = buf
  if not buf:find("\r?\n\r?\n") then return end
  local t = self.idle[h]
  if t then t:cancel(); self.idle[h] = nil end
  local req = M.parse_request(buf)
  if not req then
    return self:_send(h, 400, { ["Content-Type"] = "text/plain" }, "bad request\n")
  end
  self.deps.log("debug", "LAN HTTP " .. req.method .. " " .. req.path)
  self:_route(h, req)
end

local JSON = "application/json; charset=utf-8"

function S:_authorized(req)
  local tok = self.h.token and self.h.token()
  return M.token_eq(req.query.k, tok)
end

function S:_route(h, req)
  local head = req.method == "HEAD"
  if req.method == "OPTIONS" then
    return self:_send(h, 204, { ["Access-Control-Allow-Methods"] = "GET, HEAD, OPTIONS",
      ["Access-Control-Allow-Headers"] = "If-None-Match", ["Access-Control-Max-Age"] = "600" }, "")
  end
  if req.method ~= "GET" and not head then
    return self:_send(h, 405, { ["Content-Type"] = "text/plain", Allow = "GET, HEAD, OPTIONS" }, "method not allowed\n")
  end
  if req.path == "/" or req.path == "/index.html" then
    local html = self.h.index and self.h.index()
    if not html then return self:_send(h, 500, { ["Content-Type"] = "text/plain" }, "index.html unavailable\n", head) end
    return self:_send(h, 200, { ["Content-Type"] = "text/html; charset=utf-8", ["Cache-Control"] = "no-cache" }, html, head)
  end
  if req.path == "/api/state" or req.path == "/api/artwork" then
    if not self:_authorized(req) then
      self.deps.log("debug", "LAN HTTP " .. req.path .. ": missing or wrong token")
      return self:_send(h, 401, { ["Content-Type"] = JSON, ["Cache-Control"] = "no-store" }, '{"error":"unauthorized"}\n', head)
    end
  end
  if req.path == "/api/state" then
    local json, etag = self.h.state()
    local hdr = { ["Content-Type"] = JSON, ["Cache-Control"] = "no-store", ETag = etag }
    local inm = req.headers["if-none-match"] or req.query.inm
    if inm and etag then
      for tag in inm:gmatch("[^,]+") do
        tag = tag:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^W/", "")
        if tag == etag or tag == "*" then return self:_send(h, 304, hdr, "", true) end
      end
    end
    return self:_send(h, 200, hdr, json, head)
  end
  if req.path == "/api/artwork" then
    local url = req.query.url
    if type(url) ~= "string" or not url:find("^https?://") or not self.h.artwork then
      return self:_send(h, 400, { ["Content-Type"] = JSON }, '{"error":"url required"}\n', head)
    end
    local id = self.conn[h]
    local answered = false
    self.h.artwork(url, function(status, hdr, body)
      if answered then return end
      answered = true
      if self.conn[h] ~= id or self.done[h] then return end -- client gone / handle reused
      self:_send(h, status, hdr or {}, body, head)
    end)
    return
  end
  return self:_send(h, 404, { ["Content-Type"] = "text/plain" }, "not found\n", head)
end

return M
