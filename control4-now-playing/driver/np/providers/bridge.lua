--[[
np.providers.bridge -- generic JSON bridge: GET <url> returns the playback structure
({source={...}, playback={...}, media={...}}) directly; it is validated and sanitized with
np.playback.normalize. Used with the companion pyatv Apple TV bridge:
  GET http://host:8765/v1/devices/<id>/now-playing

config: { url = "http://192.168.1.20:8765/v1/devices/<id>/now-playing",
          provider_name = "appletv" (default source.provider when the bridge omits it),
          name = "Living Room Apple TV" (device_name fallback), headers = {...} (optional),
          group = "...", id = "...", timeout = 5 }
]]

local net = require("np.net")
local playback_mod = require("np.playback")

local M = {}

local Bridge = {}
Bridge.__index = Bridge

function M.new(config, deps)
  assert(type(config) == "table" and config.url, "bridge provider: config.url is required")
  local self = setmetatable({}, Bridge)
  self.kind = "bridge"
  self.config = config
  self.deps = deps
  self.id = config.id or ("bridge:" .. config.url)
  self.group = config.group
  return self
end

function Bridge:poll(cb)
  net.get_json(self.deps, {
    method = "GET", url = self.config.url, timeout = self.config.timeout or 5,
    headers = self.config.headers or { Accept = "application/json" },
  }, function(err, data)
    if err then return cb("bridge: " .. err) end
    if type(data.playback) ~= "table" then
      return cb("bridge: response is not a playback document (missing 'playback')")
    end
    local pb = playback_mod.normalize(data, self.deps.now(), {
      provider = self.config.provider_name or "bridge",
      device_name = self.config.name,
    })
    if self.config.name then pb.source.device_name = self.config.name end
    cb(nil, pb)
  end)
end

return M
