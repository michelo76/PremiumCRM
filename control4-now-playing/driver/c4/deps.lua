--[[
c4.deps -- builds the np.engine `deps` table from Control4 APIs.

  local Deps = require("c4.deps")
  local deps = Deps.new(C4, { debug_mode = function() return "Off" end, prefix = "NowPlaying" })
  deps.http.request(req, cb)    C4:url() transfer; cb(err, {status, headers, body}) EXACTLY once
  deps.set_timer(sec, fn)       C4:SetTimer; always asynchronous (0 s -> 1 ms); handle:cancel()
  deps.now()                    os.time()
  deps.store.get/set            C4:PersistGetValue / PersistSetValue
  deps.json                     np.json (deterministic, understands schema marks)
  deps.log(level, msg)          gated by the "Debug Mode" property; secrets redacted
  deps.set_secrets({..})        literal strings to redact from every log line
  deps.redact(s)                redaction helper (also used by the Print actions)
  deps.safe(name, fn)           wrap fn so an error is logged with a traceback, never thrown

Debug Mode: "Off" (errors only, to C4:ErrorLog), "Print" (print()), "Log" (C4:DebugLog or
C4:ErrorLog), "Print and Log". Optional C4 APIs are feature-tested.
]]

local json = require("np.json")

local M = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

-- Query parameters / headers that carry secrets. Lua patterns are case-sensitive, so the
-- letters are spelled as classes.
local function ci(word)
  return (word:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

local REDACT_PATTERNS = {
  { "([?&;]" .. ci("api") .. "_?" .. ci("key") .. "=)[^&%s\"'<>]+", "%1***" },
  { "([?&;]" .. ci("key") .. "=)[^&%s\"'<>]+", "%1***" },
  { "([?&;]" .. ci("access") .. "_" .. ci("token") .. "=)[^&%s\"'<>]+", "%1***" },
  { "([?&;]" .. ci("token") .. "=)[^&%s\"'<>]+", "%1***" },
  { "([?&;]" .. ci("auth") .. "=)[^&%s\"'<>]+", "%1***" },
  { "(" .. ci("bearer") .. "%s+)[%w%-%._~%+/=]+", "%1***" },
}

local function escape_pattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

function M.redact(s, secrets)
  if type(s) ~= "string" then s = tostring(s) end
  for _, sec in ipairs(secrets or {}) do
    if type(sec) == "string" and #sec >= 4 then
      s = s:gsub(escape_pattern(sec), "***")
    end
  end
  for _, p in ipairs(REDACT_PATTERNS) do s = s:gsub(p[1], p[2]) end
  return s
end

function M.mode_flags(mode)
  mode = tostring(mode or "Off")
  local print_on = mode == "Print" or mode == "Print and Log"
  local log_on = mode == "Log" or mode == "Print and Log"
  return print_on, log_on
end

function M.new(C4, opts)
  opts = opts or {}
  local prefix = opts.prefix or "NowPlaying"
  local secrets = {}
  local deps = {}

  local function debug_mode()
    if opts.debug_mode then
      local ok, m = pcall(opts.debug_mode)
      if ok then return m end
    end
    return "Off"
  end

  local function emit(level, msg)
    local print_on, log_on = M.mode_flags(debug_mode())
    local line = prefix .. " [" .. level .. "] " .. M.redact(msg, secrets)
    if print_on then print(line) end
    if log_on then
      if C4.DebugLog then pcall(C4.DebugLog, C4, line)
      elseif C4.ErrorLog then pcall(C4.ErrorLog, C4, line) end
    end
    if level == "error" and not log_on and C4.ErrorLog then pcall(C4.ErrorLog, C4, line) end
  end

  function deps.log(level, msg)
    if not LEVELS[level] then level = "info" end
    pcall(emit, level, tostring(msg))
  end

  function deps.set_secrets(list) secrets = list or {} end
  function deps.redact(s) return M.redact(s, secrets) end

  function deps.safe(name, fn)
    return function(...)
      local args = { ... }
      local n = select("#", ...)
      local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
      if not ok then deps.log("error", name .. " failed: " .. tostring(err)) end
      return ok
    end
  end

  deps.json = json
  deps.now = opts.now or function() return os.time() end

  function deps.set_timer(seconds, fn)
    local handle = { cancelled = false }
    local ms = math.max(1, math.floor((tonumber(seconds) or 0) * 1000 + 0.5))
    local cb = deps.safe("timer", function()
      if handle.cancelled then return end
      handle.cancelled = true -- one-shot
      fn()
    end)
    local ok, t = pcall(C4.SetTimer, C4, ms, function() cb() end, false)
    if ok then handle.timer = t else deps.log("error", "SetTimer failed: " .. tostring(t)) end
    function handle.cancel(h)
      h = h or handle
      h.cancelled = true
      if h.timer and h.timer.Cancel then pcall(h.timer.Cancel, h.timer) end
      h.timer = nil
    end
    return handle
  end

  deps.http = {}
  function deps.http.request(req, cb)
    local done = false
    local function finish(err, resp)
      if done then return end
      done = true
      local ok, cerr = xpcall(function() cb(err, resp) end, debug.traceback)
      if not ok then deps.log("error", "http callback failed: " .. tostring(cerr)) end
    end
    local method = (req.method or "GET"):upper()
    local timeout = tonumber(req.timeout) or 8
    deps.log("debug", method .. " " .. tostring(req.url))
    local ok, err = pcall(function()
      local t = C4:url()
      t:OnDone(function(transfer, responses, errCode, errMsg)
        if errCode ~= 0 and errCode ~= nil then
          return finish("transport error " .. tostring(errCode) .. ": " .. tostring(errMsg or ""))
        end
        local r = type(responses) == "table" and responses[#responses] or nil
        if not r then return finish("transport: no response") end
        finish(nil, { status = tonumber(r.code) or 0, headers = r.headers or {}, body = r.body or "" })
      end)
      t:SetOptions({ fail_on_error = false, timeout = timeout, connect_timeout = math.min(5, timeout) })
      if method == "POST" then
        t:Post(req.url, req.body or "", req.headers or {})
      else
        t:Get(req.url, req.headers or {})
      end
    end)
    if not ok then finish("transport: " .. tostring(err)) end
  end

  deps.store = {
    get = function(k)
      if not C4.PersistGetValue then return nil end
      local ok, v = pcall(C4.PersistGetValue, C4, k)
      if ok then return v end
      return nil
    end,
    set = function(k, v)
      if not C4.PersistSetValue then return end
      if v == nil and C4.PersistDeleteValue then pcall(C4.PersistDeleteValue, C4, k); return end
      pcall(C4.PersistSetValue, C4, k, v)
    end,
  }

  function deps.base64(s)
    if C4.Base64Encode then
      local ok, r = pcall(C4.Base64Encode, C4, s)
      if ok and type(r) == "string" then return r end
    end
    return require("c4.b64").encode(s)
  end

  return deps
end

return M
