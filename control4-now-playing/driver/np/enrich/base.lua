--[[
np.enrich.base -- shared plumbing for enrichers: JSON requests with rate-limit (429) and
bad-key (401/403) backoff.

  base.init(self, name, config, deps)
  base.blocked(self)                 -> err string while backing off, else nil
  base.get_json(self, req, cb)       cb(err, data, info) ; err is prefixed with the enricher name
                                     429 -> no requests for Retry-After or 30 s doubling to 15 min
                                     401/403 -> no requests for 1 h (key is wrong; don't hammer)
]]

local net = require("np.net")

local M = {}

function M.init(self, name, config, deps)
  self.name = name
  self.config = config or {}
  self.deps = deps
  self.blocked_until = nil
  self.block_reason = nil
  self.rl_backoff = nil
  return self
end

function M.blocked(self)
  if self.blocked_until and self.deps.now() < self.blocked_until then
    return self.name .. ": " .. (self.block_reason or "backing off")
  end
  return nil
end

function M.block(self, seconds, reason)
  self.blocked_until = self.deps.now() + seconds
  self.block_reason = reason
end

function M.get_json(self, req, cb)
  local berr = M.blocked(self)
  if berr then return cb(berr, nil, { kind = "blocked" }) end
  req.timeout = req.timeout or self.config.timeout or 8
  net.get_json(self.deps, req, function(err, data, info)
    if err then
      if info.kind == "rate_limited" then
        self.rl_backoff = math.min(900, (self.rl_backoff or 15) * 2)
        local wait = info.retry_after or self.rl_backoff
        M.block(self, wait, "rate limited")
        self.deps.log("warn", self.name .. ": rate limited, pausing " .. wait .. "s")
      elseif info.kind == "auth" then
        M.block(self, 3600, "API key rejected")
        self.deps.log("error", self.name .. ": API key rejected (HTTP " .. tostring(info.status) .. ")")
      end
      return cb(self.name .. ": " .. err, data, info)
    end
    self.rl_backoff = nil
    cb(nil, data, info)
  end)
end

return M
