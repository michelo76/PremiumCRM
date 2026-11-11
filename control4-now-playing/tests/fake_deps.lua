--[[
Fake implementation of the deps contract for tests: scripted HTTP, controllable clock/timers,
captured logs, in-memory store.

  local FakeDeps = require("fake_deps")
  local fd = FakeDeps.new({ start = 1790000000, sync = false })
  fd.deps                              -- pass to modules
  fd:route(match, response)            -- match: plain URL substring or function(req)->bool
                                       -- response: {status=, body=, headers=} | {err="..."} |
                                       --           {never=true} | function(req) -> response
                                       -- optional response.delay (seconds), response.times (uses)
                                       -- later routes win over earlier ones.
  fd:advance(seconds)                  -- move the clock, firing due timers / http replies in order
  fd:flush()                           -- advance(0)
  fd:count(substr) / fd:last(substr)   -- request inspection; fd.requests is the full log
  fd.logs, fd.unmatched, fd.store_data
Unmatched requests get HTTP 404 "no route" (and are recorded in fd.unmatched).
With sync=true HTTP replies are delivered inside deps.http.request (re-entrancy tests).
]]

local M = {}

local FD = {}
FD.__index = FD

function M.new(opts)
  opts = opts or {}
  local fd = setmetatable({
    t = opts.start or 1790000000, timers = {}, seq = 0, routes = {}, requests = {}, logs = {},
    unmatched = {}, store_data = {}, sync = opts.sync or false,
  }, FD)
  fd.deps = {
    http = { request = function(req, cb) fd:_request(req, cb) end },
    json = require("np.json"),
    now = function() return fd.t end,
    set_timer = function(sec, fn) return fd:_add_timer(sec, fn) end,
    log = function(level, msg)
      fd.logs[#fd.logs + 1] = { level = level, msg = msg }
      if opts.print_logs then print("[" .. level .. "] " .. msg) end
    end,
    store = {
      get = function(k) return fd.store_data[k] end,
      set = function(k, v) fd.store_data[k] = v end,
    },
  }
  return fd
end

function FD:_add_timer(sec, fn)
  self.seq = self.seq + 1
  local timer = { at = self.t + (sec or 0), seq = self.seq, fn = fn, cancelled = false }
  timer.cancel = function(h) h.cancelled = true end
  self.timers[#self.timers + 1] = timer
  return timer
end

function FD:pending_timers()
  local n = 0
  for _, t in ipairs(self.timers) do if not t.cancelled then n = n + 1 end end
  return n
end

function FD:advance(sec)
  local target = self.t + (sec or 0)
  while true do
    local best, bi
    for i, tm in ipairs(self.timers) do
      if not tm.cancelled and tm.at <= target and
        (not best or tm.at < best.at or (tm.at == best.at and tm.seq < best.seq)) then
        best, bi = tm, i
      end
    end
    if not best then break end
    table.remove(self.timers, bi)
    if best.at > self.t then self.t = best.at end
    best.fn()
  end
  -- drop cancelled timers
  local keep = {}
  for _, tm in ipairs(self.timers) do if not tm.cancelled then keep[#keep + 1] = tm end end
  self.timers = keep
  self.t = target
end

function FD:flush() self:advance(0) end

function FD:route(match, response)
  self.routes[#self.routes + 1] = { match = match, response = response, used = 0 }
  return self
end

function FD:clear_routes() self.routes = {} end

local function matches(m, req)
  if type(m) == "function" then return m(req) end
  return req.url:find(m, 1, true) ~= nil
end

function FD:_request(req, cb)
  self.requests[#self.requests + 1] = req
  local resp
  for i = #self.routes, 1, -1 do
    local r = self.routes[i]
    local exhausted = type(r.response) == "table" and r.response.times and r.used >= r.response.times
    if not exhausted and matches(r.match, req) then
      r.used = r.used + 1
      resp = r.response
      if type(resp) == "function" then resp = resp(req) end
      break
    end
  end
  if not resp then
    self.unmatched[#self.unmatched + 1] = req.url
    resp = { status = 404, body = "no route" }
  end
  if resp.never then return end
  local function deliver()
    if resp.err then return cb(resp.err) end
    cb(nil, { status = resp.status or 200, headers = resp.headers or {}, body = resp.body or "" })
  end
  if self.sync and not resp.delay then deliver() else self:_add_timer(resp.delay or 0, deliver) end
end

function FD:count(substr)
  local n = 0
  for _, r in ipairs(self.requests) do if not substr or r.url:find(substr, 1, true) then n = n + 1 end end
  return n
end

function FD:last(substr)
  for i = #self.requests, 1, -1 do
    local r = self.requests[i]
    if not substr or r.url:find(substr, 1, true) then return r end
  end
  return nil
end

function FD:has_log(level, substr)
  for _, l in ipairs(self.logs) do
    if (not level or l.level == level) and l.msg:find(substr, 1, true) then return true end
  end
  return false
end

-- convenience: JSON response from a Lua table or raw string
function M.json(v, status)
  local body = type(v) == "string" and v or require("np.json").encode(v)
  return { status = status or 200, body = body, headers = { ["Content-Type"] = "application/json" } }
end

return M
