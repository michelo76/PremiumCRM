--[[
np.net -- thin, defensive wrappers around deps.http.request.

  net.request(deps, req, cb)   cb(err, resp) is called EXACTLY once, even if the transport
                               never answers (a safety timer fires after req.timeout + 5 s),
                               answers twice, or throws.
  net.get_json(deps, req, cb)  cb(err, data, info)
       info = { status = <number|nil>, kind = "ok"|"transport"|"http"|"auth"|"not_found"|
                "rate_limited"|"decode", retry_after = <seconds|nil>, body = <raw body> }
       err is a human readable string when kind ~= "ok".
  net.header(resp, name)       case-insensitive header lookup
]]

local M = {}

function M.header(resp, name)
  if not resp or type(resp.headers) ~= "table" then return nil end
  local lname = name:lower()
  for k, v in pairs(resp.headers) do
    if type(k) == "string" and k:lower() == lname then
      if type(v) == "table" then return v[1] end
      return v
    end
  end
  return nil
end

function M.request(deps, req, cb)
  local done = false
  local guard
  local function finish(err, resp)
    if done then return end
    done = true
    if guard and guard.cancel then pcall(guard.cancel, guard) end
    cb(err, resp)
  end
  req.method = req.method or "GET"
  req.headers = req.headers or {}
  req.timeout = req.timeout or 8
  if deps.set_timer then
    guard = deps.set_timer(req.timeout + 5, function()
      finish("timeout: no response after " .. tostring(req.timeout + 5) .. "s")
    end)
  end
  local ok, perr = pcall(deps.http.request, req, function(err, resp)
    if err == nil and type(resp) ~= "table" then err = "transport: empty response" end
    finish(err, resp)
  end)
  if not ok then finish("transport: " .. tostring(perr)) end
end

local function retry_after(resp)
  local v = M.header(resp, "Retry-After")
  local n = tonumber(v)
  if n and n >= 0 then return n end
  return nil
end

local function safe_decode(deps, body)
  local ok, data, derr = pcall(deps.json.decode, body or "")
  if not ok then return nil, tostring(data) end
  return data, derr
end

function M.get_json(deps, req, cb)
  M.request(deps, req, function(err, resp)
    if err then
      return cb(tostring(err), nil, { kind = "transport" })
    end
    local status = tonumber(resp.status) or 0
    local info = { status = status, kind = "ok", body = resp.body }
    if status == 429 then
      info.kind = "rate_limited"
      info.retry_after = retry_after(resp)
      return cb("rate limited (HTTP 429)", nil, info)
    end
    if status == 401 or status == 403 then
      info.kind = "auth"
      -- still try to decode: some APIs (OMDb) put the reason in the body
      local data = safe_decode(deps, resp.body)
      return cb("unauthorized (HTTP " .. status .. ")", data, info)
    end
    if status == 404 then
      info.kind = "not_found"
      local data = safe_decode(deps, resp.body)
      return cb("not found (HTTP 404)", data, info)
    end
    if status < 200 or status >= 300 then
      info.kind = "http"
      return cb("HTTP " .. status, nil, info)
    end
    local data, derr = safe_decode(deps, resp.body)
    if type(data) ~= "table" then
      info.kind = "decode"
      return cb("invalid JSON: " .. tostring(derr or "not an object"), nil, info)
    end
    cb(nil, data, info)
  end)
end

return M
