--[[
c4.httpserver -- tiny optional LAN HTTP endpoint (property "LAN Web Port", 0 = off).

  GET|HEAD /  and /index.html   the web UI, read from the c4z (www/index.html)
  GET|HEAD /api/state           state JSON; ETag / If-None-Match -> 304; Cache-Control: no-store;
                                Access-Control-Allow-Origin: *
  anything else                 404 (405 for other methods, 413 for oversized requests)
Every response carries Connection: close and a Date header; the client is closed after the
response and its buffer is freed.

  local S = Server.new(C4, deps, { state = fn() -> json, etag ; index = fn() -> html|nil })
  S:start(port) -> ok, err      S:stop()
  S:on_data(handle, data)       from OnServerDataIn
  S:on_status(handle, port, status)  from OnServerConnectionStatusChanged
  Server.parse_request(raw)     -> { method, path, headers } | nil, err  (pure)
]]

local M = {}

M.MAX_REQUEST = 8192
M.MAX_CLIENTS = 32

local REASONS = {
  [200] = "OK", [304] = "Not Modified", [400] = "Bad Request", [404] = "Not Found",
  [405] = "Method Not Allowed", [413] = "Payload Too Large", [500] = "Internal Server Error",
  [503] = "Service Unavailable",
}

function M.http_date(t)
  return os.date("!%a, %d %b %Y %H:%M:%S GMT", t)
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
  return { method = method, target = target, path = path, version = ver, headers = headers }
end

local S = {}
S.__index = S

function M.new(C4, deps, handlers)
  return setmetatable({ C4 = C4, deps = deps, h = handlers or {}, buffers = {}, nbuf = 0, port = nil, done = {} }, S)
end

function S:start(port)
  port = tonumber(port)
  if not port or port <= 0 then self:stop(); return false, "disabled" end
  if self.port == port then return true end
  self:stop()
  if not self.C4.CreateServer then return false, "C4:CreateServer unavailable" end
  local ok, err = pcall(self.C4.CreateServer, self.C4, port)
  if not ok then
    self.deps.log("error", "LAN web server on port " .. port .. " failed: " .. tostring(err))
    return false, tostring(err)
  end
  self.port = port
  self.deps.log("info", "LAN web server listening on port " .. port)
  return true
end

function S:stop()
  if self.port and self.C4.DestroyServer then pcall(self.C4.DestroyServer, self.C4) end
  self.port = nil
  self.buffers = {}
  self.nbuf = 0
  self.done = {}
end

function S:_free(h)
  if self.buffers[h] ~= nil then
    self.buffers[h] = nil
    self.nbuf = self.nbuf - 1
  end
end

function S:on_status(h, port, status)
  status = tostring(status):upper()
  if status == "OFFLINE" then
    self:_free(h)
    self.done[h] = nil
  elseif status == "ONLINE" then
    self:_free(h)
    self.done[h] = nil -- handle numbers may be reused
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
  local keys = {}
  for k in pairs(headers) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do out[#out + 1] = k .. ": " .. headers[k] end
  local payload = table.concat(out, "\r\n") .. "\r\n\r\n"
  if not head_only and status ~= 304 then payload = payload .. body end
  pcall(self.C4.ServerSend, self.C4, h, payload)
  pcall(self.C4.ServerCloseClient, self.C4, h)
  self:_free(h)
  self.done[h] = true -- ignore anything still arriving on this connection
end

function S:on_data(h, data)
  if self.done[h] then return end
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
  local req, err = M.parse_request(buf)
  if not req then
    return self:_send(h, 400, { ["Content-Type"] = "text/plain" }, "bad request\n")
  end
  self.deps.log("debug", "LAN HTTP " .. req.method .. " " .. req.path)
  self:_route(h, req)
end

function S:_route(h, req)
  local head = req.method == "HEAD"
  if req.method ~= "GET" and not head then
    return self:_send(h, 405, { ["Content-Type"] = "text/plain", Allow = "GET, HEAD" }, "method not allowed\n")
  end
  if req.path == "/" or req.path == "/index.html" then
    local html = self.h.index and self.h.index()
    if not html then return self:_send(h, 500, { ["Content-Type"] = "text/plain" }, "index.html unavailable\n", head) end
    return self:_send(h, 200, { ["Content-Type"] = "text/html; charset=utf-8", ["Cache-Control"] = "no-cache" }, html, head)
  end
  if req.path == "/api/state" then
    local json, etag = self.h.state()
    local hdr = { ["Content-Type"] = "application/json; charset=utf-8", ["Cache-Control"] = "no-store", ETag = etag }
    local inm = req.headers["if-none-match"]
    if inm and etag then
      for tag in inm:gmatch("[^,]+") do
        tag = tag:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^W/", "")
        if tag == etag or tag == "*" then return self:_send(h, 304, hdr, "", true) end
      end
    end
    return self:_send(h, 200, hdr, json, head)
  end
  return self:_send(h, 404, { ["Content-Type"] = "text/plain" }, "not found\n", head)
end

return M
