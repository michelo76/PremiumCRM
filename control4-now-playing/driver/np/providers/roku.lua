--[[
np.providers.roku -- Roku External Control Protocol (ECP, HTTP port 8060).

config: { host = "192.168.1.50", port = 8060, name = "Living Room Roku" (optional override),
          group = "lr-tv" (optional, physical-device group for merging), id = "roku1" (optional),
          timeout = 4, device_info_ttl = 10 }

Reality check, modelled honestly:
  * ECP exposes the ACTIVE APP and the TRANSPORT (state, position, duration, is_live) but NOT
    the title of what is playing. media.title is therefore nil and media.kind "video" while
    something plays; another provider in the same `group` (e.g. Home Assistant) can fill in
    the title through np.providers.multi.
  * On a Roku TV tuner input (app id "tvinput.dtv") /query/tv-active-channel gives channel
    name/number and, when guide data is present, program title/description -> kind live_tv.
  * Home screen / screensaver -> state "idle". power-mode other than PowerOn -> "off".
  * Newer Roku OS returns HTTP 403 unless Settings > System > Advanced system settings >
    Control by mobile apps > Network access is "Default"/"Permissive"; surfaced as ERR_403.

provider:poll(cb)  cb(err, playback)
]]

local util = require("np.util")
local net = require("np.net")
local playback_mod = require("np.playback")

local M = {}

M.ERR_403 = "Roku ECP access denied (HTTP 403): on the Roku enable Settings > System > " ..
  "Advanced system settings > Control by mobile apps > Network access = Default (or Permissive)"

local Roku = {}
Roku.__index = Roku

local PLAYER_STATES = {
  play = "playing", pause = "paused", buffer = "buffering", open = "buffering", startup = "buffering",
  stop = "stopped", finished = "stopped", close = "idle", none = "idle",
}

function M.new(config, deps)
  assert(type(config) == "table" and config.host, "roku provider: config.host is required")
  local self = setmetatable({}, Roku)
  self.kind = "roku"
  self.config = config
  self.deps = deps
  self.id = config.id or ("roku:" .. config.host)
  self.group = config.group
  self.base = "http://" .. config.host .. ":" .. tostring(config.port or 8060)
  self.device = nil
  self.device_at = nil
  return self
end

function Roku:_get_xml(path, cb)
  net.request(self.deps, { method = "GET", url = self.base .. path, timeout = self.config.timeout or 4 },
    function(err, resp)
      if err then return cb("Roku unreachable (" .. tostring(err) .. ")") end
      local status = tonumber(resp.status) or 0
      if status == 403 then return cb(M.ERR_403) end
      if status ~= 200 then return cb("Roku ECP " .. path .. " returned HTTP " .. status) end
      local root, xerr = util.xml_parse(resp.body or "")
      if not root then return cb("Roku ECP " .. path .. ": " .. tostring(xerr)) end
      cb(nil, root)
    end)
end

function Roku:app_icon_url(app_id)
  if not app_id then return nil end
  return self.base .. "/query/icon/" .. util.urlencode(app_id)
end

function Roku:_device_info(cb)
  local now = self.deps.now()
  local ttl = self.config.device_info_ttl or 10
  if self.device and self.device_at and (now - self.device_at) < ttl and self.device.power == "PowerOn" then
    return cb(nil, self.device)
  end
  self:_get_xml("/query/device-info", function(err, root)
    if err then return cb(err) end
    local di = util.xml_find(root, "device-info")
    if not di then return cb("Roku ECP device-info: unexpected document") end
    local dev = {
      name = util.xml_text(di, "user-device-name") or util.xml_text(di, "friendly-device-name")
        or util.xml_text(di, "friendly-model-name") or util.xml_text(di, "model-name"),
      power = util.xml_text(di, "power-mode") or "PowerOn",
      is_tv = util.xml_text(di, "is-tv") == "true",
      model = util.xml_text(di, "model-name"),
      serial = util.xml_text(di, "serial-number"),
    }
    self.device, self.device_at = dev, now
    cb(nil, dev)
  end)
end

function Roku:_base_playback(dev)
  local pb = playback_mod.empty("idle", self.deps.now())
  pb.source.provider = "roku"
  pb.source.device_name = self.config.name or (dev and dev.name) or "Roku"
  return pb
end

local function parse_ms(s)
  if not s then return nil end
  local n = tonumber((s:match("^%s*(%d+)")))
  if not n then return nil end
  return n / 1000
end

function Roku:_media_player(pb, cb)
  self:_get_xml("/query/media-player", function(err, root)
    if err then return cb(err) end
    local player = util.xml_find(root, "player")
    if not player then return cb(nil, pb) end
    if player.attrs.error == "true" then
      pb.playback.state = "idle"
      return cb(nil, pb)
    end
    local st = PLAYER_STATES[(player.attrs.state or "none"):lower()] or "idle"
    pb.playback.state = st
    pb.playback.position_s = parse_ms(util.xml_text(player, "position"))
    pb.playback.duration_s = parse_ms(util.xml_text(player, "duration"))
    if pb.playback.duration_s == 0 then pb.playback.duration_s = nil end
    pb.playback.is_live = util.xml_text(player, "is_live") == "true"
    pb.playback.position_updated_at = self.deps.now()
    if st == "playing" or st == "paused" or st == "buffering" then
      if pb.media.kind == "unknown" then pb.media.kind = "video" end
    end
    local plugin = util.xml_child(player, "plugin")
    if plugin and not pb.source.app_id and plugin.attrs.id then
      pb.source.app_id = plugin.attrs.id
      pb.source.app_name = pb.source.app_name or plugin.attrs.name
    end
    cb(nil, pb)
  end)
end

function Roku:_tv_channel(pb, cb)
  self:_get_xml("/query/tv-active-channel", function(err, root)
    pb.media.kind = "live_tv"
    pb.playback.is_live = true
    pb.playback.state = "playing"
    if err then
      self.deps.log("debug", "roku tv-active-channel: " .. tostring(err))
      return cb(nil, pb)
    end
    local ch = util.xml_find(root, "channel")
    if ch then
      pb.media.channel_number = util.xml_text(ch, "number")
      pb.media.channel_name = util.xml_text(ch, "name")
      pb.media.title = util.xml_text(ch, "program-title")
      pb.media.subtitle = util.xml_text(ch, "program-description")
      if util.xml_text(ch, "signal-state") == "none" and not pb.media.title then
        pb.playback.state = "idle"
      end
    end
    cb(nil, pb)
  end)
end

function Roku:poll(cb)
  local done = false
  local function finish(err, pb)
    if done then return end
    done = true
    cb(err, pb)
  end
  self:_device_info(function(err, dev)
    if err then return finish(err) end
    local pb = self:_base_playback(dev)
    if dev.power ~= "PowerOn" then
      pb.playback.state = "off"
      return finish(nil, pb)
    end
    self:_get_xml("/query/active-app", function(aerr, root)
      if aerr then return finish(aerr) end
      local aa = util.xml_find(root, "active-app")
      local app = aa and util.xml_child(aa, "app")
      local saver = aa and util.xml_child(aa, "screensaver")
      local app_id = app and app.attrs.id
      local app_name = app and util.nonempty(app.text)
      if saver then
        pb.playback.state = "idle"
        pb.source.app_name = util.nonempty(saver.text) or "Screensaver"
        pb.source.app_id = saver.attrs.id
        return finish(nil, pb)
      end
      if not app_id then
        -- home screen: <app>Roku</app> without an id
        pb.playback.state = "idle"
        pb.source.app_name = app_name or "Home"
        return finish(nil, pb)
      end
      pb.source.app_id = app_id
      pb.source.app_name = app_name
      pb.source.app_icon_url = self:app_icon_url(app_id)
      if app_id:find("^tvinput%.dtv") then
        return self:_tv_channel(pb, function(_, p) finish(nil, p) end)
      end
      if app_id:find("^tvinput%.") then
        -- HDMI / AV input: we know the input is showing but nothing about the content
        pb.playback.state = "playing"
        pb.media.kind = "unknown"
        return finish(nil, pb)
      end
      self:_media_player(pb, function(merr, p)
        if merr then return finish(merr) end
        finish(nil, p)
      end)
    end)
  end)
end

return M
