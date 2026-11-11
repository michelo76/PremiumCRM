--[[
np.providers.static -- a provider the glue feeds by pushing playback documents.
The Control4 room provider uses this: the glue parses C4 room media info and calls
  provider:push(playback)   (or engine:push(id, playback), which also triggers a refresh)

config: { id = "c4room", provider_name = "c4room" (default), name = "Family Room" (device_name
          fallback), group = "...", max_age_s = nil (optional: pushed data older than this is
          reported as "off") }

provider:push(pb)   sanitized copy stored; provider.on_update (set by the engine) is called
provider:clear()    back to "off"
provider:poll(cb)   cb(nil, last pushed playback | an "off" playback)
]]

local util = require("np.util")
local playback_mod = require("np.playback")

local M = {}

local Static = {}
Static.__index = Static

function M.new(config, deps)
  config = config or {}
  local self = setmetatable({}, Static)
  self.kind = "static"
  self.config = config
  self.deps = deps
  self.id = config.id or "static"
  self.group = config.group
  self.current = nil
  self.pushed_at = nil
  self.on_update = nil
  return self
end

function Static:_defaults()
  return { provider = self.config.provider_name or "c4room", device_name = self.config.name }
end

function Static:push(pb)
  self.current = playback_mod.normalize(pb, self.deps.now(), self:_defaults())
  self.pushed_at = self.deps.now()
  if self.on_update then self.on_update(self) end
end

function Static:clear()
  self.current = nil
  self.pushed_at = nil
  if self.on_update then self.on_update(self) end
end

function Static:poll(cb)
  local now = self.deps.now()
  local max_age = self.config.max_age_s
  if not self.current or (max_age and self.pushed_at and now - self.pushed_at > max_age) then
    local pb = playback_mod.empty("off", now)
    pb.source.provider = self:_defaults().provider
    pb.source.device_name = self.config.name
    return cb(nil, pb)
  end
  cb(nil, util.deep_copy(self.current))
end

return M
