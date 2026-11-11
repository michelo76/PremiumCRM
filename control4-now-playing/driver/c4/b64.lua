--[[
c4.b64 -- pure-Lua base64 (Lua 5.1 / LuaJIT, no bit ops). Used when C4:Base64Encode is
unavailable and to decode base64-wrapped IMAGEURL values from room media info.

  b64.encode(s) -> string
  b64.decode(s) -> string | nil   (nil when s is not plausible base64)
]]

local M = {}

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
  local c = ALPHA:sub(i, i)
  ENC[i - 1] = c
  DEC[c:byte()] = i - 1
end
DEC[("-"):byte()] = 62 -- url-safe alphabet
DEC[("_"):byte()] = 63

local floor = math.floor

function M.encode(s)
  local out = {}
  local n = #s
  for i = 1, n, 3 do
    local a, b, c = s:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = floor(v / 262144) % 64
    local c2 = floor(v / 4096) % 64
    local c3 = floor(v / 64) % 64
    local c4 = v % 64
    out[#out + 1] = ENC[c1] .. ENC[c2] .. (b and ENC[c3] or "=") .. (c and ENC[c4] or "=")
  end
  return table.concat(out)
end

function M.decode(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s+", "")
  if s == "" or not s:find("^[A-Za-z0-9%+/%-_]+=?=?$") then return nil end
  s = s:gsub("=+$", "")
  if #s % 4 == 1 then return nil end
  local out = {}
  local bits, nbits = 0, 0
  for i = 1, #s do
    local v = DEC[s:byte(i)]
    if not v then return nil end
    bits = bits * 64 + v
    nbits = nbits + 6
    if nbits >= 8 then
      nbits = nbits - 8
      local p = 2 ^ nbits
      local byte = floor(bits / p)
      bits = bits % p
      out[#out + 1] = string.char(byte)
    end
  end
  return table.concat(out)
end

return M
