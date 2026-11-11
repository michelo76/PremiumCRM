--[[
np.cache -- tiny LRU cache with per-entry TTL.

  cache = Cache.new(max_entries)
  cache:get(key, now)              -> value, entry | nil   (expired entries are evicted)
  cache:set(key, value, ttl, now)  (value may be false to record a negative result)
  cache:delete(key) ; cache:keys() -> keys, most recently used first ; cache:size()
  cache:entries()                  -> list of {key=, value=, expires=} MRU first
]]

local M = {}

local Cache = {}
Cache.__index = Cache

function M.new(max)
  return setmetatable({ max = max or 50, map = {}, order = {} }, Cache)
end

local function remove_from_order(order, key)
  for i = #order, 1, -1 do
    if order[i] == key then table.remove(order, i); return end
  end
end

function Cache:_touch(key)
  remove_from_order(self.order, key)
  table.insert(self.order, 1, key)
end

function Cache:get(key, now)
  local e = self.map[key]
  if not e then return nil end
  if e.expires and now and now >= e.expires then
    self:delete(key)
    return nil
  end
  self:_touch(key)
  return e.value, e
end

function Cache:set(key, value, ttl, now)
  self.map[key] = { value = value, expires = ttl and now and (now + ttl) or nil, stored = now }
  self:_touch(key)
  while #self.order > self.max do
    local old = table.remove(self.order)
    self.map[old] = nil
  end
end

function Cache:delete(key)
  self.map[key] = nil
  remove_from_order(self.order, key)
end

function Cache:keys()
  local out = {}
  for i, k in ipairs(self.order) do out[i] = k end
  return out
end

function Cache:size()
  return #self.order
end

function Cache:entries()
  local out = {}
  for _, k in ipairs(self.order) do
    local e = self.map[k]
    out[#out + 1] = { key = k, value = e.value, expires = e.expires }
  end
  return out
end

return M
