--[[
c4.variables -- the driver's Control4 variables.

!!! APPEND-ONLY !!!
Composer programming binds to variable IDs, and Control4 assigns IDs in the order the
driver calls C4:AddVariable. NEVER reorder, rename or remove an entry of LIST; only append
new ones at the end. tests/c4/variables_spec.lua asserts that np.flatten.definitions()
still matches the head of this list, so a core change cannot silently reorder IDs.

  Vars.LIST                         ordered { name, type }
  Vars.define(C4)                   AddVariable for every entry (call from OnDriverInit only)
  Vars.new(C4) -> v                 change tracker
  v:update(flat_list)               SetVariable only for values that changed; -> n changed
  v:set(name, value, type)          single variable (only when changed)
  Vars.to_c4(value, type)           Lua value -> variable string ("1"/"0" for BOOL)
]]

local M = {}

M.LIST = {
  -- np.flatten.definitions() (order matters, see header)
  { "TITLE", "STRING" }, { "SUBTITLE", "STRING" }, { "MEDIA_KIND", "STRING" }, { "SERIES_TITLE", "STRING" },
  { "SEASON", "NUMBER" }, { "EPISODE", "NUMBER" }, { "EPISODE_TITLE", "STRING" }, { "ARTIST", "STRING" },
  { "ALBUM", "STRING" }, { "CHANNEL_NAME", "STRING" }, { "CHANNEL_NUMBER", "STRING" }, { "APP_NAME", "STRING" },
  { "SOURCE_DEVICE", "STRING" }, { "SOURCE_PROVIDER", "STRING" }, { "PLAY_STATE", "STRING" },
  { "IS_PLAYING", "BOOL" }, { "IS_PAUSED", "BOOL" }, { "IS_LIVE", "BOOL" }, { "POSITION_SECONDS", "NUMBER" },
  { "DURATION_SECONDS", "NUMBER" }, { "PROGRESS_PERCENT", "NUMBER" }, { "VOLUME", "NUMBER" }, { "YEAR", "NUMBER" },
  { "GENRES", "STRING" }, { "CONTENT_RATING", "STRING" }, { "RUNTIME_MINUTES", "NUMBER" }, { "OVERVIEW", "STRING" },
  { "TAGLINE", "STRING" }, { "IMDB_ID", "STRING" }, { "IMDB_RATING", "NUMBER" }, { "IMDB_URL", "STRING" },
  { "ROTTEN_TOMATOES", "NUMBER" }, { "METACRITIC", "NUMBER" }, { "DIRECTOR", "STRING" }, { "CAST", "STRING" },
  { "NETWORK", "STRING" }, { "POSTER_URL", "STRING" }, { "BACKDROP_URL", "STRING" }, { "ARTWORK_URL", "STRING" },
  { "LOGO_URL", "STRING" }, { "TRAILER_URL", "STRING" }, { "DISPLAY_LINE_1", "STRING" },
  { "DISPLAY_LINE_2", "STRING" }, { "MEDIA_KEY", "STRING" }, { "VERSION", "NUMBER" }, { "LAST_CHANGED", "NUMBER" },
  -- glue-owned
  { "STATE_JSON", "STRING" },
  -- append new variables below this line only
}

M.STATE_JSON = "STATE_JSON"

local function initial(typ)
  if typ == "NUMBER" or typ == "BOOL" then return "0" end
  return ""
end

function M.to_c4(v, typ)
  if typ == "BOOL" then return (v == true or v == "1" or v == 1) and "1" or "0" end
  if typ == "NUMBER" then
    local n = tonumber(v) or 0
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
    return tostring(n)
  end
  if v == nil then return "" end
  return tostring(v)
end

function M.define(C4)
  for _, d in ipairs(M.LIST) do
    -- AddVariable(name, initial value, type, read-only, hidden)
    C4:AddVariable(d[1], initial(d[2]), d[2], true, false)
  end
end

local V = {}
V.__index = V

function M.new(C4)
  local self = setmetatable({ C4 = C4, values = {}, types = {} }, V)
  for _, d in ipairs(M.LIST) do
    self.values[d[1]] = initial(d[2])
    self.types[d[1]] = d[2]
  end
  return self
end

function V:set(name, value, typ)
  local s = M.to_c4(value, typ or self.types[name] or "STRING")
  if self.values[name] == s then return false end
  self.values[name] = s
  self.C4:SetVariable(name, s)
  return true
end

function V:update(flat)
  local n = 0
  for _, item in ipairs(flat or {}) do
    if self.types[item.name] and self:set(item.name, item.value, item.type) then n = n + 1 end
  end
  return n
end

function V:get(name) return self.values[name] end

return M
