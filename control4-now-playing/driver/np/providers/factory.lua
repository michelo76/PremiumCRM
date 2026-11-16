--[[
np.providers.factory -- build a provider from one entry of config.providers.

  factory.create(cfg, deps) -> provider | nil, err
  cfg.type: "roku" | "homeassistant" (alias "ha") | "bridge" (alias "appletv") | "static"
            | "custom" (cfg.provider = any object with :poll(cb), optional .id/.group/.kind --
              lets the glue or tests plug in their own provider)
]]

local M = {}

local TYPES = {
  roku = "np.providers.roku",
  homeassistant = "np.providers.homeassistant",
  ha = "np.providers.homeassistant",
  bridge = "np.providers.bridge",
  appletv = "np.providers.bridge",
  static = "np.providers.static",
}

function M.create(cfg, deps)
  if type(cfg) ~= "table" then return nil, "provider config must be a table" end
  if cfg.type == "custom" then
    local p = cfg.provider
    if type(p) ~= "table" or type(p.poll) ~= "function" then return nil, "custom provider needs a :poll()" end
    p.id = p.id or cfg.id or "custom"
    p.group = p.group or cfg.group
    p.kind = p.kind or "custom"
    return p
  end
  local modname = TYPES[tostring(cfg.type or ""):lower()]
  if not modname then return nil, "unknown provider type: " .. tostring(cfg.type) end
  local ok, res = pcall(function() return require(modname).new(cfg, deps) end)
  if not ok then return nil, tostring(res) end
  return res
end

return M
