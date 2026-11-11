--[[
c4.app -- the driver: wires np.engine to Control4 (variables, events, webview proxy, room
media, LAN artwork, optional LAN HTTP server, status properties, actions).
driver.lua only forwards the C4 entry points here through App:dispatch (xpcall + traceback),
so a Lua error never kills the driver.

  local app = App.new(C4, { properties = function() return Properties end, print = print })
  app:dispatch("on_init" | "on_late_init" | "on_destroyed" | "on_property_changed" |
               "execute_command" | "ui_request" | "received_from_proxy" |
               "on_watched_variable_changed" | "on_server_data_in" | "on_server_status", ...)

Lifecycle: OnDriverInit adds the variables (nothing else is allowed there); everything else
starts in OnDriverLateInit and is torn down in OnDriverDestroyed.
]]

local Engine = require("np.engine")
local flatten = require("np.flatten")
local util = require("np.util")
local Version = require("c4.version")
local Vars = require("c4.variables")
local Deps = require("c4.deps")
local Config = require("c4.config")
local Events = require("c4.events")
local Room = require("c4.room")
local Artwork = require("c4.artwork")
local Server = require("c4.httpserver")
local Status = require("c4.status")
local Diag = require("c4.diagnostics")

local M = {}

M.PROXY = Version.PROXY_BINDING
M.WEBVIEW_URL = Version.WEBVIEW_URL
M.URL_DELAY_S = 3
M.POSITION_S = 5
M.STATUS_S = 15
M.RECONFIG_DEBOUNCE_S = 0.5
M.CACHE_PERSIST_KEY = "np_enrich_cache_v1"

M.READ_ONLY = {
  ["Driver Version"] = true, ["Status"] = true, ["Active Source"] = true, ["Metadata Sources"] = true,
  ["Web View URL"] = true, ["LAN URL"] = true,
}

-- '{' -> '{"sent_at":N,' : the page corrects controller/device clock skew with it.
function M.with_sent_at(json, now)
  if type(json) ~= "string" or json:sub(1, 1) ~= "{" then return json end
  local n = string.format("%d", math.floor(tonumber(now) or 0))
  if json == "{}" then return '{"sent_at":' .. n .. "}" end
  return '{"sent_at":' .. n .. "," .. json:sub(2)
end

function M.xml_escape(s)
  return (tostring(s):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }))
end

local App = {}
App.__index = App

function M.new(C4, env)
  env = env or {}
  local self = setmetatable({}, App)
  self.C4 = C4
  self.props = env.properties or function() return {} end
  self.print = env.print or function(...) print(...) end
  self.prop_cache = {}
  self.timers = {}
  self.last_icon = ""
  self.ev_snap = Events.initial()
  return self
end

---------------------------------------------------------------------------
-- dispatch / helpers
---------------------------------------------------------------------------

function App:dispatch(method, ...)
  local fn = self[method]
  if not fn then return nil end
  local args, n = { ... }, select("#", ...)
  local ok, res = xpcall(function() return fn(self, unpack(args, 1, n)) end, debug.traceback)
  if not ok then
    local msg = "NowPlaying: " .. method .. " failed: " .. tostring(res)
    if self.deps then self.deps.log("error", msg)
    else
      pcall(self.print, msg)
      if self.C4 and self.C4.ErrorLog then pcall(self.C4.ErrorLog, self.C4, msg) end
    end
    return nil
  end
  return res
end

function App:_out(line)
  line = self.deps and self.deps.redact(line) or line
  pcall(self.print, line)
end

function App:_update_prop(name, value)
  value = tostring(value or "")
  if self.prop_cache[name] == value then return end
  self.prop_cache[name] = value
  if self.C4.UpdateProperty then pcall(self.C4.UpdateProperty, self.C4, name, value) end
end

function App:_timer(key, seconds, fn)
  self:_cancel(key)
  self.timers[key] = self.deps.set_timer(seconds, function()
    self.timers[key] = nil
    fn()
  end)
end

function App:_cancel(key)
  local t = self.timers[key]
  if t then t:cancel(); self.timers[key] = nil end
end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------

function App:on_init(dit)
  -- ONLY variable creation here (fixed, append-only order: see c4/variables.lua).
  Vars.define(self.C4)
  self.vars = Vars.new(self.C4)
  self.inited = true
end

function App:on_late_init(dit)
  local C4 = self.C4
  self.destroyed = false
  self.vars = self.vars or Vars.new(C4)
  self.deps = Deps.new(C4, {
    debug_mode = function() local Properties = self.props(); return Properties["Debug Mode"] end,
  })
  local deps = self.deps
  self.room = Room.new(C4, deps, function(_, var) self:_room_changed(var) end)
  self.artwork = Artwork.new(deps, { on_ready = function() if self.engine then self.engine:refresh() end end })
  self.server = Server.new(C4, deps, {
    state = function() return self:_state_for_ui() end,
    index = function() return self:_index_html() end,
  })
  self:_update_prop("Driver Version", Version.string())
  self:_update_prop("Web View URL", M.WEBVIEW_URL)
  self:_configure("late init")
  self:_publish(self.engine:get_state(), true)
  self:_timer("url", M.URL_DELAY_S, function() self:_send_url() end)
  self:_status_tick()
  deps.log("info", "Now Playing Info " .. Version.string() .. " started")
end

function App:on_destroyed(dit)
  self.destroyed = true
  if self.engine then
    self.engine:stop()
    if self.unsubscribe then self.unsubscribe(); self.unsubscribe = nil end
  end
  for k in pairs(self.timers) do self:_cancel(k) end
  if self.room then self.room:unwatch() end
  if self.server then self.server:stop() end
  if self.artwork then self.artwork:clear() end
end

---------------------------------------------------------------------------
-- configuration
---------------------------------------------------------------------------

function App:_room_ctx()
  local Properties = self.props()
  local C4 = self.C4
  local room_id = tonumber(Properties["Room"])
  if not room_id or room_id <= 0 then
    local ok, id = pcall(C4.RoomGetId, C4)
    room_id = ok and tonumber(id) or nil
  end
  local room_name
  if room_id and C4.GetDeviceDisplayName then
    local ok, n = pcall(C4.GetDeviceDisplayName, C4, room_id)
    if ok and type(n) == "string" and n ~= "" then room_name = n end
  end
  return room_id, room_name
end

function App:_build_config()
  local Properties = self.props()
  local room_id, room_name = self:_room_ctx()
  local ctx = { room_id = room_id, room_name = room_name, version = Version.VERSION }
  local cfg, info = Config.build(Properties, ctx)
  if info.watch_room then
    self.room:watch(room_id)
    ctx.room_on = self.room:is_on()
    cfg, info = Config.build(Properties, ctx)
  else
    self.room:unwatch()
  end
  return cfg, info
end

function App:_configure(reason)
  if self.destroyed then return end
  self.configuring = true
  local ok, err = pcall(function()
    local deps = self.deps
    local cfg, info = self:_build_config()
    deps.set_secrets(info.secrets)
    local prev_room = self.cfg and self.cfg.room and self.cfg.room.id
    self.cfg, self.info = cfg, info
    self.artwork:set_enabled(info.embed_artwork)
    if not self.engine then
      self.engine = Engine.new(cfg, deps)
      self.unsubscribe = self.engine:on_change(function(state, changes) self:_on_change(state, changes) end)
    else
      self.engine:set_config(cfg)
    end
    self.engine:set_artwork_rewriter(info.embed_artwork and self.artwork.rewrite or nil)
    if info.configured then
      if info.room_media or info.gated then self:_push_room() end
      if not self.engine.running then self.engine:start() end
    else
      if self.engine.running then self.engine:stop() end
      -- publish an honest "off" instead of the last (stale) media: one forced poll with no
      -- providers yields the engine's "off" state; no network traffic.
      local st = self.engine.state
      if st.version > 0 and st.playback.state ~= "off" then self.engine:refresh() end
    end
    local sok = self.server:start(info.lan_port)
    if info.lan_port > 0 and sok then
      local ip = "controller"
      if self.C4.GetControllerNetworkAddress then
        local gok, a = pcall(self.C4.GetControllerNetworkAddress, self.C4)
        if gok and a and a ~= "" then ip = a end
      end
      self:_update_prop("LAN URL", "http://" .. ip .. ":" .. info.lan_port .. "/")
    elseif info.lan_port > 0 then
      self:_update_prop("LAN URL", "Error: could not listen on port " .. info.lan_port)
    else
      self:_update_prop("LAN URL", "Disabled")
    end
    if prev_room and prev_room ~= cfg.room.id then self:_send_url() end
    deps.log("debug", "configured (" .. tostring(reason) .. "): sources=" .. table.concat(info.sources, ",") ..
      " enrichers=" .. table.concat(info.enrichers, ",") .. (info.gated and " [gated: room off]" or ""))
  end)
  self.configuring = false
  if not ok then error(err, 0) end
  self:_update_status()
end

function App:_push_room()
  if not (self.engine and self.room and self.room.watching) then return end
  self.engine:push(Config.ROOM_PROVIDER_ID, self.room:playback())
end

function App:_room_changed(var)
  if self.configuring or not self.engine or self.destroyed then return end
  local info = self.info or {}
  if info.gate then
    local gated_now = self.room:is_on() == false
    if gated_now ~= (info.gated == true) then
      return self:_configure("room power " .. (gated_now and "off" or "on"))
    end
  end
  if info.room_media or info.gated then self:_push_room() end
end

---------------------------------------------------------------------------
-- publishing
---------------------------------------------------------------------------

function App:_flat(state)
  local copy = util.deep_copy(state)
  self.artwork:restore(copy)
  return flatten.flatten(copy, self.deps.now())
end

function App:_state_for_ui()
  local json, etag = self.engine:get_state_json()
  return M.with_sent_at(json, self.deps.now()), etag
end

function App:_push_ui()
  if not self.engine or not self.C4.SendDataToUI then return end
  local json = self:_state_for_ui()
  pcall(self.C4.SendDataToUI, self.C4, "NOW_PLAYING", { state = json })
end

function App:_on_change(state, changes)
  if self.destroyed then return end
  self:_publish(state, false, changes)
end

function App:_publish(state, initial, changes)
  local C4 = self.C4
  self.vars:update(self:_flat(state))
  if state.version ~= self.json_version then
    self.json_version = state.version
    self.vars:set(Vars.STATE_JSON, M.with_sent_at(self.engine:get_state_json(), self.deps.now()), "STRING")
    self:_push_ui()
  end
  local st = state.playback and state.playback.state
  local icon = (st == "playing" or st == "buffering") and "playing" or ""
  if icon ~= self.last_icon then
    self.last_icon = icon
    pcall(C4.SendToProxy, C4, M.PROXY, "ICON_CHANGED",
      { icon = icon, icon_description = icon == "playing" and "Playing" or "Now Playing" })
  end
  if not initial then
    local events
    events, self.ev_snap = Events.derive(self.ev_snap, state, changes)
    for _, name in ipairs(events) do
      self.deps.log("info", "event: " .. name)
      pcall(C4.FireEvent, C4, name)
    end
  end
  if st == "playing" then
    if not self.timers.position then self:_position_tick(true) end
  else
    self:_cancel("position")
  end
  self:_update_status(state)
end

function App:_position_tick(schedule_only)
  if not schedule_only and self.engine then
    local state = self.engine:get_state()
    if state.playback and state.playback.state == "playing" then
      self.vars:update(self:_flat(state))
    else
      return
    end
  end
  self:_timer("position", M.POSITION_S, function() self:_position_tick(false) end)
end

function App:_status_tick()
  self:_update_status()
  self:_timer("status", M.STATUS_S, function() self:_status_tick() end)
end

function App:_update_status(state)
  if not self.engine then return end
  state = state or self.engine:get_state()
  local est = self.engine:get_status()
  self:_update_prop("Status", Status.text(state, est, self.info))
  self:_update_prop("Active Source", Status.active_source(state, est))
  self:_update_prop("Metadata Sources", Status.metadata_sources(self.info))
end

function App:_send_url()
  pcall(self.C4.SendToProxy, self.C4, M.PROXY, "URL_CHANGED", { url = M.WEBVIEW_URL })
end

function App:_index_html()
  if self.index_cache then return self.index_cache end
  local C4 = self.C4
  if not C4.FileOpen then return nil end
  if C4.FileSetDir then pcall(C4.FileSetDir, C4, "C4Z") end
  local ok, fh = pcall(C4.FileOpen, C4, "www/index.html")
  if not ok or fh == nil or fh == -1 then
    self.deps.log("error", "cannot open www/index.html in the c4z")
    return nil
  end
  local data
  pcall(function()
    C4:FileSetPos(fh, 0) -- FileOpen leaves the position at EOF
    data = C4:FileRead(fh, C4:FileGetSize(fh))
  end)
  pcall(C4.FileClose, C4, fh)
  if type(data) == "string" and data ~= "" then self.index_cache = data end
  return self.index_cache
end

---------------------------------------------------------------------------
-- C4 entry points
---------------------------------------------------------------------------

function App:on_property_changed(name)
  if not self.deps or self.destroyed then return end -- before OnDriverLateInit
  if M.READ_ONLY[name] then return end
  if name == "Debug Mode" then
    local Properties = self.props()
    self.deps.log("info", "Debug Mode: " .. tostring(Properties["Debug Mode"]))
    return
  end
  -- Composer sends one call per property: coalesce bursts into one reconfiguration.
  self:_timer("reconfig", M.RECONFIG_DEBOUNCE_S, function() self:_configure("property " .. tostring(name)) end)
end

local ACTIONS = {
  RefreshNow = "_action_refresh",
  ClearMetadataCache = "_action_clear_cache",
  PrintState = "_action_print_state",
  PrintRoomMediaInfo = "_action_print_room",
  TestMetadataSources = "_action_test",
}

function App:execute_command(cmd, params)
  params = type(params) == "table" and params or {}
  if not self.engine then return end
  if cmd == "GET_STATE" then
    return self:_push_ui()
  elseif cmd == "LUA_ACTION" then
    local m = ACTIONS[tostring(params.ACTION)]
    if m then return self[m](self) end
    self.deps.log("warn", "unknown action " .. tostring(params.ACTION))
  elseif cmd == "Refresh" then
    return self:_action_refresh()
  else
    self.deps.log("debug", "ExecuteCommand ignored: " .. tostring(cmd))
  end
end

function App:ui_request(cmd, params)
  if not self.engine then return "" end
  if cmd == "GET_STATE" then
    return M.xml_escape(self:_state_for_ui())
  end
  return ""
end

function App:received_from_proxy(binding, cmd, params)
  if not self.engine then return end
  self.deps.log("debug", "ReceivedFromProxy " .. tostring(binding) .. " " .. tostring(cmd))
  if tonumber(binding) == M.PROXY and (cmd == "SELECT" or cmd == "GET_STATE") then
    self:_push_ui()
    self.engine:refresh()
  end
end

function App:on_watched_variable_changed(dev, var, value)
  if self.room then self.room:on_variable(dev, var, value) end
end

function App:on_server_data_in(h, data)
  if self.server then self.server:on_data(h, data) end
end

function App:on_server_status(h, port, status)
  if self.server then self.server:on_status(h, port, status) end
end

---------------------------------------------------------------------------
-- actions
---------------------------------------------------------------------------

function App:_action_refresh()
  if self.info and (self.info.room_media or self.info.gated) then self:_push_room() end
  if self.engine.running then self.engine:refresh() end
  self:_out("Now Playing Info: refresh requested")
end

function App:_action_clear_cache()
  if self.engine.pipeline then self.engine.pipeline:clear() end
  self.deps.store.set(M.CACHE_PERSIST_KEY, nil)
  self.artwork:clear()
  self:_out("Now Playing Info: metadata and artwork caches cleared")
  if self.engine.running then self.engine:refresh() end
end

function App:_action_print_state()
  local state = self.engine:get_state()
  local lines = { "Now Playing Info state (version " .. tostring(state.version) .. "):" }
  for _, v in ipairs(self:_flat(state)) do
    lines[#lines + 1] = string.format("  %-18s = %s", v.name, Vars.to_c4(v.value, v.type))
  end
  local json = self.engine:get_state_json()
  lines[#lines + 1] = "  STATE_JSON         = (" .. #json .. " bytes)"
  local est = self.engine:get_status()
  lines[#lines + 1] = "  engine running=" .. tostring(est.running) .. " active=" .. tostring(est.active_provider)
  for _, p in ipairs(est.providers or {}) do
    lines[#lines + 1] = string.format("  provider %-14s state=%s fails=%d%s", tostring(p.id), tostring(p.state),
      p.fails or 0, p.last_error and (" error=" .. p.last_error) or "")
  end
  lines[#lines + 1] = "  Status: " .. (self.prop_cache["Status"] or "")
  self:_out(table.concat(lines, "\n"))
end

function App:_action_print_room()
  if not self.room.watching then
    local room_id = self:_room_ctx()
    local tmp = Room.new(self.C4, self.deps, nil)
    tmp.room_id = room_id
    self:_out("Now Playing Info room media (Use Control4 Room Media is Off; values read directly):\n" .. tmp:raw_report())
    return
  end
  self:_out("Now Playing Info room media:\n" .. self.room:raw_report())
end

function App:_action_test()
  local out = function(line) self:_out(line) end
  Diag.run(self.cfg or {}, self.deps, out, function(results)
    local bad = 0
    for _, r in pairs(results) do if not r.ok then bad = bad + 1 end end
    out("Test Metadata Sources: done, " .. bad .. " problem(s)")
  end)
end

return M
