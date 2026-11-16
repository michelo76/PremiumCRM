--[[
A faithful-enough mock of the Control4 DriverWorks Lua API for driving driver.lua in tests.

  local Mock = require("c4_mock")
  local m = Mock.new({ root = T.root .. "/driver" })   -- reads driver.xml + www/ from root
  m:load()                      -- loads driver.lua in its own environment (C4, Properties)
  m:init()                      -- OnDriverInit (phase "init": forbidden APIs raise + are recorded)
  m:late_init()                 -- OnDriverLateInit
  m:advance(sec) / m:flush()    -- fake clock: C4 timers and HTTP replies fire in order
  m:route(match, resp)          -- scripted C4:url responses (later routes win):
                                --   {status=, body=, headers=} | {err=7, msg=} | {never=true} |
                                --   function(req) -> resp ; resp.delay (s), resp.times (uses)
  m:prop(name, value)           -- set a property and call OnPropertyChanged
  m:device(id, name, vars)      -- define a device (rooms: ids from m.room_id)
  m:set_var(dev, var, value)    -- change a device variable (fires listeners)
  m:connect(h) / m:client_send(h, data) / m:client_close(h)   -- LAN server clients
  m:call(fn_name, ...)          -- call a global driver entry point

Recorded: m.added_vars (ordered), m.vars, m.set_log, m.events, m.proxy, m.data_to_ui,
m.requests, m.updated_props, m.prints, m.errors, m.violations, m.server, m.sent, m.closed,
m.listeners. os.time() and print() are redirected to the active mock while one is active.
]]

local util = require("np.util")
local json = require("np.json")

local M = {}

---------------------------------------------------------------------------
-- global redirections (os.time / print) -> the active mock
---------------------------------------------------------------------------

local active
local orig_time, orig_print = os.time, print
os.time = function(t)
  if t == nil and active then return math.floor(active.t) end
  return orig_time(t)
end
_G.print = function(...)
  if active then
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    active.prints[#active.prints + 1] = table.concat(parts, "\t")
    if active.echo then orig_print(...) end
    return
  end
  return orig_print(...)
end

---------------------------------------------------------------------------
-- driver.xml
---------------------------------------------------------------------------

function M.parse_driver_xml(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  local root = assert(util.xml_parse(s))
  local dd = assert(util.xml_find(root, "devicedata"), "no <devicedata>")
  local out = { properties = {}, property_order = {}, events = {}, event_order = {}, actions = {}, commands = {},
    raw = s, root = root }
  out.version = util.xml_text(dd, "version")
  local cfg = util.xml_child(dd, "config")
  local props = util.xml_child(cfg, "properties")
  for _, p in ipairs(util.xml_children(props, "property")) do
    local name = util.xml_text(p, "name")
    local items = {}
    for _, it in ipairs(util.xml_children(util.xml_child(p, "items"), "item")) do items[#items + 1] = it.text end
    out.properties[name] = {
      type = util.xml_text(p, "type"), default = util.xml_text(p, "default") or "",
      readonly = util.xml_text(p, "readonly") == "true", password = util.xml_text(p, "password") == "true",
      items = items, minimum = tonumber(util.xml_text(p, "minimum")), maximum = tonumber(util.xml_text(p, "maximum")),
    }
    out.property_order[#out.property_order + 1] = name
  end
  for _, e in ipairs(util.xml_children(util.xml_child(dd, "events"), "event")) do
    local name = util.xml_text(e, "name")
    out.events[name] = tonumber(util.xml_text(e, "id"))
    out.event_order[#out.event_order + 1] = name
  end
  for _, a in ipairs(util.xml_children(util.xml_child(cfg, "actions"), "action")) do
    out.actions[#out.actions + 1] = { name = util.xml_text(a, "name"), command = util.xml_text(a, "command") }
  end
  for _, c in ipairs(util.xml_children(util.xml_child(cfg, "commands"), "command")) do
    out.commands[#out.commands + 1] = util.xml_text(c, "name")
  end
  return out
end

---------------------------------------------------------------------------

local Mock = {}
Mock.__index = Mock

M.FORBIDDEN_IN_INIT = {
  SetVariable = true, SetTimer = true, JsonEncode = true, JsonDecode = true, RoomGetId = true,
  GetDeviceVariable = true, CreateServer = true, FireEvent = true, GetControllerNetworkAddress = true,
  RegisterVariableListener = true, url = true, SendToProxy = true, SendDataToUI = true,
}

function M.new(opts)
  opts = opts or {}
  local m = setmetatable({
    root = opts.root, t = opts.start or 1790000000, seq = 0, queue = {},
    room_id = opts.room_id or 100, devices = {},
    added_vars = {}, vars = {}, set_log = {}, events = {}, proxy = {}, data_to_ui = {},
    requests = {}, routes = {}, updated_props = {}, prints = {}, errors = {}, debuglog = {},
    violations = {}, persist = {}, listeners = {}, server = nil, servers_created = 0,
    sent = {}, closed = {}, files = {}, file_handles = 0, phase = "loaded", echo = opts.echo,
  }, Mock)
  m.xml = M.parse_driver_xml(opts.xml or (m.root .. "/driver.xml"))
  m.Properties = {}
  for name, p in pairs(m.xml.properties) do m.Properties[name] = p.default end
  m:device(m.room_id, opts.room_name or "Living Room", {})
  m.C4 = m:_build_c4()
  return m
end

function Mock:activate() active = self end
function Mock:deactivate() if active == self then active = nil end end

function Mock:_check(name)
  if self.phase == "init" and M.FORBIDDEN_IN_INIT[name] then
    self.violations[#self.violations + 1] = name
    error("C4:" .. name .. " is not allowed in OnDriverInit", 3)
  end
end

-- event queue (C4 timers + internal deliveries) ----------------------------

function Mock:_enqueue(delay, fn, kind)
  self.seq = self.seq + 1
  local ev = { at = self.t + (delay or 0), seq = self.seq, fn = fn, kind = kind or "internal", cancelled = false }
  self.queue[#self.queue + 1] = ev
  return ev
end

function Mock:advance(sec)
  local target = self.t + (sec or 0)
  local guard = 0
  while true do
    local best, bi
    for i, ev in ipairs(self.queue) do
      if not ev.cancelled and ev.at <= target + 1e-9 and
        (not best or ev.at < best.at or (ev.at == best.at and ev.seq < best.seq)) then
        best, bi = ev, i
      end
    end
    if not best then break end
    guard = guard + 1
    assert(guard < 100000, "mock: runaway timers")
    table.remove(self.queue, bi)
    if best.at > self.t then self.t = best.at end
    best.fn()
  end
  local keep = {}
  for _, ev in ipairs(self.queue) do if not ev.cancelled then keep[#keep + 1] = ev end end
  self.queue = keep
  self.t = target
end

function Mock:flush() self:advance(0) end

function Mock:pending_timers()
  local n = 0
  for _, ev in ipairs(self.queue) do
    if not ev.cancelled and ev.kind == "timer" then n = n + 1 end
  end
  return n
end

-- http ----------------------------------------------------------------------

function Mock:route(match, resp)
  self.routes[#self.routes + 1] = { match = match, response = resp, used = 0 }
  return self
end

function Mock:clear_routes() self.routes = {} end

function Mock:count(substr)
  local n = 0
  for _, r in ipairs(self.requests) do if not substr or r.url:find(substr, 1, true) then n = n + 1 end end
  return n
end

function Mock:last(substr)
  for i = #self.requests, 1, -1 do
    if not substr or self.requests[i].url:find(substr, 1, true) then return self.requests[i] end
  end
end

function Mock:_http(tr, method, url, body, headers)
  assert(type(url) == "string", "url must be a string")
  assert(tr.done, "C4:url transfer started without OnDone")
  local req = { method = method, url = url, body = body, headers = headers or {}, options = tr.options }
  self.requests[#self.requests + 1] = req
  local resp
  for i = #self.routes, 1, -1 do
    local r = self.routes[i]
    local exhausted = type(r.response) == "table" and r.response.times and r.used >= r.response.times
    local hit
    if type(r.match) == "function" then hit = r.match(req) else hit = url:find(r.match, 1, true) ~= nil end
    if not exhausted and hit then
      r.used = r.used + 1
      resp = r.response
      if type(resp) == "function" then resp = resp(req) end
      break
    end
  end
  resp = resp or { status = 404, body = "no route" }
  if resp.never then return end
  self:_enqueue(resp.delay or 0, function()
    if resp.err then
      tr.done(tr, {}, resp.err, resp.msg or "error")
    else
      tr.done(tr, { { code = resp.status or 200, headers = resp.headers or {}, body = resp.body or "", url = url } }, 0, nil)
    end
  end, "http")
end

-- devices -------------------------------------------------------------------

function Mock:device(id, name, vars)
  self.devices[id] = { name = name, vars = vars or {} }
end

function Mock:set_var(dev, var, value)
  self.devices[dev] = self.devices[dev] or { name = "Device " .. dev, vars = {} }
  self.devices[dev].vars[var] = value
  if self.listeners[dev .. ":" .. var] then
    self:call("OnWatchedVariableChanged", dev, var, value)
  end
end

-- server --------------------------------------------------------------------

function Mock:connect(h)
  assert(self.server, "no server")
  self:call("OnServerConnectionStatusChanged", h, self.server.port, "ONLINE")
end

function Mock:client_send(h, data) self:call("OnServerDataIn", h, data) end

function Mock:client_close(h)
  self:call("OnServerConnectionStatusChanged", h, self.server and self.server.port or 0, "OFFLINE")
end

function Mock:response(h) return table.concat(self.sent[h] or {}) end

-- C4 table ------------------------------------------------------------------

function Mock:_build_c4()
  local m = self
  local C4 = {}

  function C4:AddVariable(name, value, typ, ro, hidden)
    assert(type(name) == "string" and type(value) == "string", "AddVariable(name, strValue, ...)")
    assert(({ STRING = 1, NUMBER = 1, INT = 1, FLOAT = 1, BOOL = 1 })[typ], "bad variable type " .. tostring(typ))
    if m.vars[name] ~= nil then error("variable " .. name .. " added twice") end
    m.added_vars[#m.added_vars + 1] = { name = name, value = value, type = typ, readonly = ro, hidden = hidden,
      phase = m.phase, id = #m.added_vars + 1 }
    m.vars[name] = value
    return true
  end
  function C4:SetVariable(name, value)
    m:_check("SetVariable")
    if m.vars[name] == nil then error("SetVariable on unknown variable " .. tostring(name)) end
    assert(type(value) == "string", "SetVariable value must be a string (" .. name .. ")")
    m.vars[name] = value
    m.set_log[#m.set_log + 1] = { name = name, value = value }
  end
  function C4:FireEvent(name)
    m:_check("FireEvent")
    if not m.xml.events[name] then error("FireEvent: event not declared in driver.xml: " .. tostring(name)) end
    m.events[#m.events + 1] = name
  end
  function C4:SendToProxy(id, cmd, params)
    m:_check("SendToProxy")
    m.proxy[#m.proxy + 1] = { id = id, cmd = cmd, params = params }
  end
  function C4:SendDataToUI(cmd, params)
    m:_check("SendDataToUI")
    m.data_to_ui[#m.data_to_ui + 1] = { cmd = cmd, params = params }
  end
  function C4:UpdateProperty(name, value)
    if not m.xml.properties[name] then error("UpdateProperty: undeclared property " .. tostring(name)) end
    m.Properties[name] = tostring(value)
    m.updated_props[name] = tostring(value)
  end
  function C4:SetTimer(ms, fn, rep)
    m:_check("SetTimer")
    assert(type(ms) == "number" and ms > 0, "SetTimer: delay must be > 0 ms")
    local timer = { cancelled = false }
    local function schedule()
      timer.ev = m:_enqueue(ms / 1000, function()
        if timer.cancelled then return end
        if rep then schedule() else timer.cancelled = true end
        fn(timer, 0)
      end, "timer")
    end
    function timer:Cancel()
      self.cancelled = true
      if self.ev then self.ev.cancelled = true end
    end
    schedule()
    return timer
  end
  function C4:url()
    m:_check("url")
    local tr = {}
    function tr:OnDone(fn) self.done = fn; return self end
    function tr:SetOptions(o) self.options = o; return self end
    function tr:Get(url, headers) m:_http(self, "GET", url, nil, headers); return self end
    function tr:Post(url, data, headers) m:_http(self, "POST", url, data, headers); return self end
    function tr:Cancel() end
    return tr
  end
  function C4:PersistSetValue(k, v) m.persist[k] = v end
  function C4:PersistGetValue(k) return m.persist[k] end
  function C4:PersistDeleteValue(k) m.persist[k] = nil end
  function C4:JsonEncode(t) m:_check("JsonEncode"); return json.encode(t) end
  function C4:JsonDecode(s) m:_check("JsonDecode"); return json.decode(s) end
  function C4:Base64Encode(s)
    return require("c4.b64").encode(s)
  end
  function C4:RoomGetId() m:_check("RoomGetId"); return m.room_id end
  function C4:GetDevicesByC4iName(c4i)
    if c4i == "roomdevice.c4i" then return { [m.room_id] = m.devices[m.room_id].name } end
    return {}
  end
  function C4:GetDeviceDisplayName(id)
    local d = m.devices[tonumber(id)]
    return d and d.name or nil
  end
  function C4:GetDeviceVariable(dev, var)
    m:_check("GetDeviceVariable")
    local d = m.devices[tonumber(dev)]
    return d and d.vars[tonumber(var)] or nil
  end
  function C4:RegisterVariableListener(dev, var)
    m:_check("RegisterVariableListener")
    m.listeners[dev .. ":" .. var] = true
    local d = m.devices[tonumber(dev)]
    local v = d and d.vars[tonumber(var)]
    m:call("OnWatchedVariableChanged", dev, var, v == nil and "" or v)
    return true
  end
  function C4:UnregisterVariableListener(dev, var)
    m.listeners[dev .. ":" .. var] = nil
  end
  function C4:CreateServer(port)
    m:_check("CreateServer")
    m.server = { port = port }
    m.servers_created = m.servers_created + 1
  end
  function C4:DestroyServer() m.server = nil end
  function C4:ServerSend(h, data)
    assert(type(data) == "string")
    m.sent[h] = m.sent[h] or {}
    table.insert(m.sent[h], data)
  end
  function C4:ServerCloseClient(h) m.closed[h] = true end
  function C4:GetControllerNetworkAddress()
    m:_check("GetControllerNetworkAddress")
    return "192.168.1.5"
  end
  function C4:FileSetDir(dir) m.file_dir = dir end
  function C4:FileOpen(path)
    if m.file_dir ~= "C4Z" then return -1 end
    local f = io.open(m.root .. "/" .. path, "rb")
    if not f then return -1 end
    local data = f:read("*a")
    f:close()
    m.file_handles = m.file_handles + 1
    local h = m.file_handles
    m.files[h] = { data = data, pos = #data } -- opens positioned at EOF
    return h
  end
  function C4:FileSetPos(h, pos) m.files[h].pos = pos end
  function C4:FileGetSize(h) return #m.files[h].data end
  function C4:FileRead(h, n)
    local f = m.files[h]
    local s = f.data:sub(f.pos + 1, f.pos + n)
    f.pos = f.pos + #s
    return s
  end
  function C4:FileClose(h) m.files[h] = nil end
  function C4:ErrorLog(s) m.errors[#m.errors + 1] = s end
  function C4:DebugLog(s) m.debuglog[#m.debuglog + 1] = s end
  function C4:GetDriverConfigInfo(k)
    if k == "version" then return m.xml.version end
    return nil
  end
  return C4
end

-- driver loading ------------------------------------------------------------

function Mock:load(path)
  path = path or (self.root .. "/driver.lua")
  self:activate()
  local env = setmetatable({ C4 = self.C4, Properties = self.Properties }, { __index = _G })
  self.env = env
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return self
end

function Mock:call(name, ...)
  local fn = self.env and self.env[name]
  if not fn then return nil end
  self:activate()
  return fn(...)
end

function Mock:init()
  self.phase = "init"
  self:call("OnDriverInit", 0)
  self.phase = "running"
end

function Mock:late_init()
  self:call("OnDriverLateInit", 0)
end

function Mock:start()
  self:load(); self:init(); self:late_init()
  return self
end

function Mock:prop(name, value)
  assert(self.xml.properties[name], "unknown property " .. tostring(name))
  self.Properties[name] = value
  self:call("OnPropertyChanged", name)
end

function Mock:action(cmd) return self:call("ExecuteCommand", "LUA_ACTION", { ACTION = cmd }) end

function Mock:events_since(n)
  local out = {}
  for i = (n or 0) + 1, #self.events do out[#out + 1] = self.events[i] end
  return out
end

function Mock:printed(substr)
  for _, p in ipairs(self.prints) do if p:find(substr, 1, true) then return true end end
  return false
end

function Mock:all_prints() return table.concat(self.prints, "\n") end

function Mock:proxy_cmds(cmd)
  local out = {}
  for _, p in ipairs(self.proxy) do if p.cmd == cmd then out[#out + 1] = p end end
  return out
end

function Mock:destroy()
  self:call("OnDriverDestroyed", 0)
  self:deactivate()
end

return M
