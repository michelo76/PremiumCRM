--[[
c4.app -- the driver: wires np.engine to Control4 (variables, events, webview proxy, room
media, LAN artwork, optional LAN HTTP server, status properties, actions).
driver.lua only forwards the C4 entry points here through App:dispatch (xpcall + traceback),
so a Lua error never kills the driver.

  local app = App.new(C4, { properties = function() return Properties end, print = print })
  app:dispatch("on_init" | "on_late_init" | "on_destroyed" | "on_property_changed" |
               "execute_command" | "ui_request" | "received_from_proxy" |
               "on_watched_variable_changed" | "on_server_data_in" | "on_server_status", ...)

Web view protocol (see README "Page <-> driver protocol"):
  ExecuteCommand GET_STATE            -> SendDataToUI("NOW_PLAYING", { state = json })
  ExecuteCommand GET_ARTWORK {url=u}  -> SendDataToUI("NOW_PLAYING_ARTWORK", { url = u, data = uri })
                                         or { url = u, error = "..." }; u must be an image URL
                                         of the current state (c4.artwork)
  (the same two commands arriving through ReceivedFromProxy on binding 5001 -- the page's
   proxy-flag fallback -- are answered the same way)
  LAN relay (c4.httpserver, on by default): the web view URL carries
    ?relay=<urlencoded http://<controller-ip>:<port>>&k=<token>; the page polls
    <relay>/api/state?k= and loads LAN artwork from <relay>/api/artwork?url=&k= when the JS API
    stays silent. The token is minted once and persisted (TOKEN_KEY).

Lifecycle: OnDriverInit adds the variables (nothing else is allowed there); everything else
starts in OnDriverLateInit and is torn down in OnDriverDestroyed.
]]

local Engine = require("np.engine")
local flatten = require("np.flatten")
local Version = require("c4.version")
local Vars = require("c4.variables")
local Deps = require("c4.deps")
local Config = require("c4.config")
local Events = require("c4.events")
local Room = require("c4.room")
local AppleTV = require("c4.appletv")
local Artwork = require("c4.artwork")
local Server = require("c4.httpserver")
local Status = require("c4.status")
local Diag = require("c4.diagnostics")
local json = require("np.json")
local b64 = require("c4.b64")

local M = {}

M.PROXY = Version.PROXY_BINDING
M.WEBVIEW_URL = Version.WEBVIEW_URL
M.URL_DELAY_S = 3
-- Proxy notifications sent before the project has finished starting are lost (Control4's
-- WebView sample re-sends after 60 s): URL_CHANGED and ICON_CHANGED are sent again then.
M.URL_RESEND_S = 60
M.TOKEN_KEY = "np_lan_token_v1"
M.POSITION_S = 5
M.STATUS_S = 15
M.RECONFIG_DEBOUNCE_S = 0.5
M.CACHE_PERSIST_KEY = "np_enrich_cache_v1"
M.ARTWORK_CMD = "NOW_PLAYING_ARTWORK"
-- programming command (driver.xml <commands>): wire the Apple TV driver's event 19 "Now Playing
-- snapshot updated" to it in Composer when OnDeviceEvent / the REVISION listener do not deliver
M.ATV_REFRESH_CMD = "Refresh Apple TV Now Playing"

M.READ_ONLY = {
  ["Driver Version"] = true, ["Status"] = true, ["Active Source"] = true, ["Metadata Sources"] = true,
  ["Web View URL"] = true, ["LAN URL"] = true, ["Apple TV Driver Status"] = true,
}

-- '{' -> '{"sent_at":N,' : the page corrects controller/device clock skew with it.
function M.with_sent_at(json, now)
  if type(json) ~= "string" or json:sub(1, 1) ~= "{" then return json end
  local n = string.format("%d", math.floor(tonumber(now) or 0))
  if json == "{}" then return '{"sent_at":' .. n .. "}" end
  return '{"sent_at":' .. n .. "," .. json:sub(2)
end

-- The URL a GET_ARTWORK request asks for. The Navigator's exact tParams shape for
-- C4.sendCommand(name, "<json>", ...) is unverified, so accept: a table with `url`, a JSON
-- string, or a table holding such a JSON string under any key.
function M.artwork_request_url(params, depth)
  depth = depth or 0
  if depth > 3 then return nil end
  if type(params) == "string" then
    local s = params:gsub("^%s+", ""):gsub("%s+$", "")
    if s:find("^https?://") then return s end
    if s:sub(1, 1) == "{" then
      local ok, v = pcall(json.decode, s)
      if ok and type(v) == "table" then return M.artwork_request_url(v, depth + 1) end
    end
    return nil
  end
  if type(params) ~= "table" then return nil end
  for _, k in ipairs({ "url", "URL", "Url" }) do
    if type(params[k]) == "string" and params[k]:find("^https?://") then return params[k] end
  end
  for _, v in pairs(params) do
    local u = M.artwork_request_url(v, depth + 1)
    if u then return u end
  end
  return nil
end

-- Image URLs the page may ask the driver to fetch: those of the current state only (cast
-- photos excluded -- the page never asks for them). Anything else is refused (no open proxy).
function M.state_image_urls(state)
  local set = {}
  local function add(u) if type(u) == "string" and u:find("^https?://") then set[u] = true end end
  state = state or {}
  add((state.media or {}).artwork_url)
  add((state.source or {}).app_icon_url)
  local d = state.details
  if type(d) == "table" then
    add(d.poster_url); add(d.backdrop_url); add(d.logo_url)
    if type(d.music) == "table" then add(d.music.artist_image_url) end
    if type(d.episode) == "table" then add(d.episode.still_url) end
  end
  return set
end

-- web_view_url with the LAN relay pointer (omitted when the relay is unknown/disabled)
function M.webview_url(relay, token)
  if not relay or not token or token == "" then return M.WEBVIEW_URL end
  return M.WEBVIEW_URL .. "?relay=" .. Config.urlencode(relay) .. "&k=" .. Config.urlencode(token)
end

-- A random URL-safe token (the LAN relay's credential). math.random seeded from the clock,
-- a table address and, when the OS has it, C4:UUID("Random") mixed into every character.
local TOKEN_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
function M.mint_token(C4, n)
  n = n or 24
  local extra = ""
  if C4 and C4.UUID then
    local ok, u = pcall(C4.UUID, C4, "Random")
    if ok and type(u) == "string" then extra = u:gsub("[^%x]", "") end
  end
  local seed = os.time() + math.floor((os.clock() * 1000003) % 1000003)
  local addr = tostring({}):match("(%x+)$")
  if addr then seed = seed + (tonumber(addr:sub(-7), 16) or 0) end
  for i = 1, #extra do seed = (seed * 31 + extra:byte(i)) % 2147483629 end
  math.randomseed(seed % 2147483629)
  local out = {}
  for i = 1, n do
    local r = math.random(0, 63)
    if #extra > 0 then r = (r + (tonumber(extra:sub((i - 1) % #extra + 1, (i - 1) % #extra + 1), 16) or 0) * 4) % 64 end
    out[i] = TOKEN_ALPHA:sub(r + 1, r + 1)
  end
  return table.concat(out)
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
  self.last_desc = Status.BUTTON_DEFAULT
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
  self.atv = AppleTV.new(C4, deps, function() self:_atv_changed() end)
  self.artwork = Artwork.new(deps)
  self.token = self:_lan_token()
  self.server = Server.new(C4, deps, {
    state = function() return self:_state_for_ui() end,
    index = function() return self:_index_html() end,
    token = function() return self.token end,
    artwork = function(url, cb) self:_relay_artwork(url, cb) end,
    on_listen = function() if not self.configuring then self:_lan_changed() end end,
  })
  self:_update_prop("Driver Version", Version.string())
  self:_configure("late init")
  self:_publish(self.engine:get_state(), true)
  self:_timer("url", M.URL_DELAY_S, function() self:_send_url() end)
  self:_timer("url_resend", M.URL_RESEND_S, function()
    self:_send_url()
    self:_send_icon()
  end)
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
  if self.atv then self.atv:stop() end
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
  -- the SmartBuildOS Apple TV driver (idempotent: same selection = same listener)
  self.atv:configure(info.appletv_driver)
  self:_update_prop("Apple TV Driver Status", self.atv:status_text())
  return cfg, info
end

function App:_configure(reason)
  if self.destroyed then return end
  self.configuring = true
  local ok, err = pcall(function()
    local deps = self.deps
    local cfg, info = self:_build_config()
    local secrets = {}
    for i, v in ipairs(info.secrets) do secrets[i] = v end
    if self.token then secrets[#secrets + 1] = self.token end
    deps.set_secrets(secrets)
    local prev_room = self.cfg and self.cfg.room and self.cfg.room.id
    self.cfg, self.info = cfg, info
    self.artwork:set_enabled(info.embed_artwork)
    self.artwork:set_auth(info.artwork_auth)
    if not self.engine then
      self.engine = Engine.new(cfg, deps)
      self.unsubscribe = self.engine:on_change(function(state, changes) self:_on_change(state, changes) end)
    else
      self.engine:set_config(cfg)
    end
    if info.configured then
      if info.room_media or info.gated then self:_push_room() end
      if info.appletv_driver then self:_push_atv() end
      if not self.engine.running then self.engine:start() end
    else
      if self.engine.running then self.engine:stop() end
      -- publish an honest "off" instead of the last (stale) media: one forced poll with no
      -- providers yields the engine's "off" state; no network traffic.
      local st = self.engine.state
      if st.version > 0 and st.playback.state ~= "off" then self.engine:refresh() end
    end
    self.server:start(info.lan_port)
    self:_lan_changed()
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

-- the Apple TV driver watcher read a new snapshot (or its status changed)
function App:_push_atv()
  if not (self.engine and self.atv) then return end
  self.engine:push(Config.APPLETV_DRIVER_ID, self.atv:playback()) -- false while gated: no provider
end

function App:_atv_changed()
  if self.destroyed then return end
  self:_update_prop("Apple TV Driver Status", self.atv:status_text())
  if self.configuring or not self.engine then return end
  if self.info and self.info.appletv_driver then self:_push_atv() end
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
  return flatten.flatten(state, self.deps.now())
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
  -- downloads for images that are no longer part of the state (another title, another source,
  -- a cleared ARTWORK_URL) are cancelled; their late responses are never delivered
  if self.artwork then
    local n = self.artwork:retain(M.state_image_urls(state))
    if n > 0 then self.deps.log("debug", "cancelled " .. n .. " artwork download(s) no longer in the state") end
  end
  self:_publish(state, false, changes)
end

-- is `url` an image of the state as it is NOW (checked again when a download completes)
function App:_art_current(url)
  return self.engine ~= nil and not self.destroyed and M.state_image_urls(self.engine.state)[url] == true
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
  -- the button's icon + text (what is playing); only re-sent when one of them changes
  local icon = (st == "playing" or st == "buffering") and "playing" or ""
  local desc = Status.button_text(state)
  if icon ~= self.last_icon or desc ~= self.last_desc then
    self.last_icon, self.last_desc = icon, desc
    self:_send_icon()
  end
  if not initial then
    local events
    events, self.ev_snap = Events.derive(self.ev_snap, state, changes)
    if not self.ev_baseline then
      -- The first real state after (re)start is only the baseline: a controller reboot or driver
      -- update while a movie plays must not fire Source/App/Media Changed, Playback/Movie Started.
      self.ev_baseline = true
      if #events > 0 then self.deps.log("debug", "events baseline (not fired): " .. table.concat(events, ", ")) end
      events = {}
    end
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
  self:_lan_changed() -- also picks up a controller IP that changed / became known late
  self:_update_status()
  self:_timer("status", M.STATUS_S, function() self:_status_tick() end)
end

function App:_update_status(state)
  if not self.engine then return end
  state = state or self.engine:get_state()
  local est = self.engine:get_status()
  local text = Status.text(state, est, self.info)
  local srv = self.server
  if srv and srv.want and not srv.listening and srv.last_error then
    text = text .. " | LAN Web Port " .. tostring(srv.want) .. ": " .. tostring(srv.last_error) .. " (retrying)"
  end
  self:_update_prop("Status", text)
  self:_update_prop("Active Source", Status.active_source(state, est))
  self:_update_prop("Metadata Sources", Status.metadata_sources(self.info))
end

function App:_controller_ip()
  local C4 = self.C4
  if not C4.GetControllerNetworkAddress then return nil end
  local ok, a = pcall(C4.GetControllerNetworkAddress, C4)
  if ok and type(a) == "string" then
    a = a:gsub("^%s+", ""):gsub("%s+$", "")
    if a ~= "" and a ~= "0.0.0.0" and not a:find("[%s/]") then return a end
  end
  return nil
end

function App:_lan_token()
  local t = self.deps.store.get(M.TOKEN_KEY)
  if type(t) ~= "string" or #t < 16 or not t:find("^[%w%-_]+$") then
    t = M.mint_token(self.C4)
    self.deps.store.set(M.TOKEN_KEY, t)
    self.deps.log("info", "LAN relay token minted")
  end
  return t
end

-- http://<ip>:<port> of the LAN relay when it is listening and the controller IP is known
function App:_relay_base()
  local srv = self.server
  if not (srv and srv.listening and srv.port) then return nil end
  local ip = self:_controller_ip()
  if not ip then return nil end
  if ip:find(":", 1, true) then ip = "[" .. ip .. "]" end
  return "http://" .. ip .. ":" .. srv.port
end

-- LAN URL + Web View URL properties; URL_CHANGED again when the URL changed after the first
-- announcement (port, controller IP or token).
function App:_lan_changed()
  if not self.server or self.destroyed then return end
  local srv, port = self.server, self.info and self.info.lan_port or 0
  if port <= 0 then
    self:_update_prop("LAN URL", "Disabled")
  elseif srv.listening then
    self:_update_prop("LAN URL", "http://" .. (self:_controller_ip() or "controller") .. ":" .. srv.port ..
      "/?k=" .. Config.urlencode(self.token))
  else
    self:_update_prop("LAN URL", "Error: could not listen on port " .. port .. ": " .. tostring(srv.last_error or "?") .. " (retrying)")
  end
  local url = M.webview_url(self:_relay_base(), self.token)
  self:_update_prop("Web View URL", url)
  if self.url_announced and url ~= self.url_sent then self:_send_url() end
  self:_update_status()
end

function App:_send_url()
  local url = M.webview_url(self:_relay_base(), self.token)
  self.url_sent, self.url_announced = url, true
  self:_update_prop("Web View URL", url)
  if self.deps then self.deps.log("debug", "URL_CHANGED " .. url) end
  pcall(self.C4.SendToProxy, self.C4, M.PROXY, "URL_CHANGED", { url = url })
end

function App:_send_icon()
  pcall(self.C4.SendToProxy, self.C4, M.PROXY, "ICON_CHANGED",
    { icon = self.last_icon or "", icon_description = self.last_desc or Status.BUTTON_DEFAULT })
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
  local raw = params
  params = type(params) == "table" and params or {}
  if not self.engine then return end
  if cmd == "GET_STATE" then
    return self:_push_ui()
  elseif cmd == "GET_ARTWORK" then
    return self:_get_artwork(raw)
  elseif cmd == "LUA_ACTION" then
    local m = ACTIONS[tostring(params.ACTION)]
    if m then return self[m](self) end
    self.deps.log("warn", "unknown action " .. tostring(params.ACTION))
  elseif cmd == "Refresh" then
    return self:_action_refresh()
  elseif cmd == M.ATV_REFRESH_CMD then
    return self:_action_refresh_atv()
  else
    self.deps.log("debug", "ExecuteCommand ignored: " .. tostring(cmd))
  end
end

function App:_artwork_reply(t)
  if self.destroyed or not self.C4.SendDataToUI then return end
  pcall(self.C4.SendDataToUI, self.C4, M.ARTWORK_CMD, t)
end

function App:_get_artwork(params)
  local url = M.artwork_request_url(params)
  if not url then
    self.deps.log("debug", "GET_ARTWORK without a usable url")
    return
  end
  if not M.state_image_urls(self.engine.state)[url] then
    self.deps.log("info", "GET_ARTWORK refused (not an image of the current state): " .. url)
    return self:_artwork_reply({ url = url, error = "not in current state" })
  end
  self.artwork:fetch(url, function(err, data)
    if err then return self:_artwork_reply({ url = url, error = tostring(err) }) end
    -- the state moved on while downloading (new snapshot / source): never hand it out as current
    if not self:_art_current(url) then
      self.deps.log("debug", "GET_ARTWORK reply dropped (no longer in the current state): " .. url)
      return self:_artwork_reply({ url = url, error = "not in current state" })
    end
    self:_artwork_reply({ url = url, data = data })
  end)
end

-- /api/artwork on the LAN relay: the raw image bytes of an image URL of the current state.
-- cb(status, headers, body)
function App:_relay_artwork(url, cb)
  local function err(status, msg)
    cb(status, { ["Content-Type"] = "application/json; charset=utf-8", ["Cache-Control"] = "no-store" },
      json.encode({ error = msg }) .. "\n")
  end
  if not self.engine or not M.state_image_urls(self.engine.state)[url] then
    self.deps.log("info", "relay artwork refused (not an image of the current state): " .. tostring(url))
    return err(403, "not in current state")
  end
  self.artwork:fetch(url, function(e, data)
    if e == "cancelled" or (not e and not self:_art_current(url)) then return err(410, "not in current state") end
    if e then return err(e == "disabled" and 403 or 502, tostring(e)) end
    local mime, enc = tostring(data):match("^data:([^;,]+);base64,(.*)$")
    local bytes = enc and b64.decode(enc)
    if not bytes then return err(502, "bad image data") end
    cb(200, { ["Content-Type"] = mime, ["Cache-Control"] = "private, max-age=300" }, bytes)
  end)
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
  if tonumber(binding) ~= M.PROXY then return end
  if cmd == "SELECT" or cmd == "GET_STATE" then
    self:_push_ui()
    self.engine:refresh()
  elseif cmd == "GET_ARTWORK" then
    -- the page's proxy-flag fallback (C4.sendCommand(..., false)) arrives here
    self:_get_artwork(params)
  end
end

function App:on_watched_variable_changed(dev, var, value)
  if self.room and self.room:on_variable(dev, var, value) then return end
  if self.atv then self.atv:on_variable(dev, var, value) end
end

function App:on_device_event(dev, ev)
  if self.destroyed or not self.atv then return end
  if not self.atv:on_device_event(dev, ev) then
    self.deps.log("debug", "OnDeviceEvent ignored: device " .. tostring(dev) .. " event " .. tostring(ev))
  end
end

function App:on_server_data_in(h, data, address, port, identifier)
  if self.server then self.server:on_data(h, data, address, port, identifier) end
end

function App:on_server_status(h, port, status, a4, a5)
  if self.server then self.server:on_status(h, port, status, a4, a5) end
end

---------------------------------------------------------------------------
-- actions
---------------------------------------------------------------------------

function App:_action_refresh()
  if self.info and (self.info.room_media or self.info.gated) then self:_push_room() end
  -- also the target of the Apple TV driver's event 19 "Now Playing snapshot updated" (dealer
  -- programming): re-read its snapshot now, even when REVISION looks unchanged (an applied read
  -- pushes through _atv_changed; an unresolved device is re-resolved first)
  if self.info and self.info.appletv_driver and self.atv then
    if not self.atv.dev then self.atv:configure(self.info.appletv_driver) end
    self.atv:read("refresh", true)
  end
  if self.engine.running then self.engine:refresh() end
  self:_out("Now Playing Info: refresh requested")
end

-- "Refresh Apple TV Now Playing": an immediate, forced re-read of the selected Apple TV driver's
-- snapshot only (no provider polling). Re-applying an unchanged snapshot changes nothing in the
-- engine, so it never causes a redraw when the REVISION listener already applied it.
function App:_action_refresh_atv()
  if not (self.info and self.info.appletv_driver and self.atv) then
    self.deps.log("info", M.ATV_REFRESH_CMD .. ": no Apple TV driver selected")
    return
  end
  if not self.atv.dev then self.atv:configure(self.info.appletv_driver) end
  self.atv:read("command", true)
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
  local atv_bad = 0
  if self.info and self.info.appletv_driver and self.atv then
    local lines, ok = self.atv:report()
    out("Test Metadata Sources: Apple TV driver (local variables)")
    for _, l in ipairs(lines) do out(l) end
    if not ok then atv_bad = 1 end
    self:_update_prop("Apple TV Driver Status", self.atv:status_text())
  end
  Diag.run(self.cfg or {}, self.deps, out, function(results)
    local bad = atv_bad
    for _, r in pairs(results) do if not r.ok then bad = bad + 1 end end
    out("Test Metadata Sources: done, " .. bad .. " problem(s)")
  end)
end

return M
