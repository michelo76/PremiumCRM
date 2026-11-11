--[[
np.json -- small pure-Lua JSON encoder/decoder (Lua 5.1 / LuaJIT compatible).

MIT License. Copyright (c) 2026 Now Playing Info contributors.
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in the
Software without restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions: The above copyright notice and this
permission notice shall be included in all copies or substantial portions of the
Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

API
  json.decode(str)            -> value | nil, err   (JSON null -> nil; arrays/objects
                                                     carry json.array / json.object marks)
  json.encode(value)          -> str | nil, err
  json.null                   -> sentinel encoded as null
  json.array(t) / json.object(t)  mark a table so that an EMPTY table encodes as [] / {}
  json.ordered(t, keys)       mark an object with an explicit key order
  json.is_array(t)            -> true if marked array or a non-empty 1..n sequence

Unmarked empty tables encode as {}.  Object keys without an explicit order are
emitted sorted, so output is deterministic (important for ETags).
]]

local M = {}

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local setmetatable, getmetatable = setmetatable, getmetatable
local sbyte, schar, sfind, ssub, sformat = string.byte, string.char, string.find, string.sub, string.format
local floor, huge = math.floor, math.huge
local concat = table.concat

M.null = setmetatable({}, { __tostring = function() return "null" end, __jsontype = "null" })

local array_mt = { __jsontype = "array" }
local object_mt = { __jsontype = "object" }

function M.array(t)
  return setmetatable(t or {}, array_mt)
end

function M.object(t)
  return setmetatable(t or {}, object_mt)
end

function M.ordered(t, keys)
  return setmetatable(t or {}, { __jsontype = "object", __jsonorder = keys })
end

local function json_kind(t)
  local mt = getmetatable(t)
  return mt and mt.__jsontype
end

local function seq_len(t)
  -- returns n if t is a pure 1..n sequence (n may be 0), else nil
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k <= 0 or floor(k) ~= k then return nil end
    if k > n then n = k end
  end
  -- allow holes only if count matches (no holes)
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  if count ~= n then return nil end
  return n
end

function M.is_array(t)
  if type(t) ~= "table" then return false end
  local kind = json_kind(t)
  if kind == "array" then return true end
  if kind == "object" then return false end
  local n = seq_len(t)
  return n ~= nil and n > 0
end

---------------------------------------------------------------------------
-- Encoder
---------------------------------------------------------------------------

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_str(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or sformat("\\u%04x", sbyte(c))
  end) .. '"'
end

local function encode_number(v)
  if v ~= v or v == huge or v == -huge then return "null" end
  if floor(v) == v and v > -1e15 and v < 1e15 then
    return sformat("%d", v)
  end
  return sformat("%.14g", v)
end

local encode_value

local function encode_table(t, buf, stack, depth)
  if stack[t] then error("json: circular reference") end
  if depth > 100 then error("json: nesting too deep") end
  stack[t] = true
  local kind = json_kind(t)
  local n = (kind ~= "object") and seq_len(t) or nil
  if kind == "array" or (kind ~= "object" and n and n > 0) then
    if not n then
      n = 0
      for k in pairs(t) do if type(k) == "number" and k > n then n = k end end
    end
    buf[#buf + 1] = "["
    for i = 1, n do
      if i > 1 then buf[#buf + 1] = "," end
      encode_value(t[i], buf, stack, depth + 1)
    end
    buf[#buf + 1] = "]"
  else
    local mt = getmetatable(t)
    local order = mt and mt.__jsonorder
    local seen, keys = {}, {}
    if order then
      for _, k in ipairs(order) do
        if t[k] ~= nil and not seen[k] then keys[#keys + 1] = k; seen[k] = true end
      end
    end
    local rest = {}
    for k in pairs(t) do
      if not seen[k] then
        local tk = type(k)
        if tk ~= "string" and tk ~= "number" then error("json: invalid key type " .. tk) end
        rest[#rest + 1] = k
      end
    end
    table.sort(rest, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(rest) do keys[#keys + 1] = k end
    buf[#buf + 1] = "{"
    for i, k in ipairs(keys) do
      if i > 1 then buf[#buf + 1] = "," end
      buf[#buf + 1] = escape_str(tostring(k))
      buf[#buf + 1] = ":"
      encode_value(t[k], buf, stack, depth + 1)
    end
    buf[#buf + 1] = "}"
  end
  stack[t] = nil
end

encode_value = function(v, buf, stack, depth)
  local tv = type(v)
  if v == nil or v == M.null then
    buf[#buf + 1] = "null"
  elseif tv == "boolean" then
    buf[#buf + 1] = v and "true" or "false"
  elseif tv == "number" then
    buf[#buf + 1] = encode_number(v)
  elseif tv == "string" then
    buf[#buf + 1] = escape_str(v)
  elseif tv == "table" then
    encode_table(v, buf, stack, depth)
  else
    error("json: cannot encode " .. tv)
  end
end

function M.encode(v)
  local buf = {}
  local ok, err = pcall(encode_value, v, buf, {}, 0)
  if not ok then return nil, tostring(err) end
  return concat(buf)
end

---------------------------------------------------------------------------
-- Decoder
---------------------------------------------------------------------------

local function utf8_char(cp)
  if cp < 0x80 then return schar(cp) end
  if cp < 0x800 then
    return schar(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return schar(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return schar(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40,
    0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function decode_error(str, pos, msg)
  error({ json_error = sformat("json: %s at position %d", msg, pos) })
end

local function skip_ws(str, pos)
  local _, e = sfind(str, "^[ \t\r\n]*", pos)
  return e + 1
end

local decode_value

local function decode_string(str, pos)
  -- pos points at opening quote
  local buf = {}
  local i = pos + 1
  while true do
    local s, e = sfind(str, '["\\]', i)
    if not s then decode_error(str, pos, "unterminated string") end
    if s > i then buf[#buf + 1] = ssub(str, i, s - 1) end
    local c = ssub(str, s, s)
    if c == '"' then
      return concat(buf), s + 1
    end
    local esc = ssub(str, s + 1, s + 1)
    if esc == "u" then
      local hex = ssub(str, s + 2, s + 5)
      local cp = tonumber(hex, 16)
      if not cp or #hex ~= 4 then decode_error(str, s, "bad unicode escape") end
      local nexti = s + 6
      if cp >= 0xD800 and cp <= 0xDBFF and ssub(str, nexti, nexti + 1) == "\\u" then
        local lo = tonumber(ssub(str, nexti + 2, nexti + 5), 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          nexti = nexti + 6
        end
      end
      buf[#buf + 1] = utf8_char(cp)
      i = nexti
    else
      local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
      local r = map[esc]
      if not r then decode_error(str, s, "bad escape") end
      buf[#buf + 1] = r
      i = s + 2
    end
  end
end

local function decode_array(str, pos, depth)
  local arr = setmetatable({}, array_mt)
  local n = 0
  pos = skip_ws(str, pos + 1)
  if ssub(str, pos, pos) == "]" then return arr, pos + 1 end
  while true do
    local v
    v, pos = decode_value(str, pos, depth + 1)
    n = n + 1
    arr[n] = v
    pos = skip_ws(str, pos)
    local c = ssub(str, pos, pos)
    if c == "]" then return arr, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected ',' or ']'") end
    pos = skip_ws(str, pos + 1)
  end
end

local function decode_object(str, pos, depth)
  local obj = setmetatable({}, object_mt)
  pos = skip_ws(str, pos + 1)
  if ssub(str, pos, pos) == "}" then return obj, pos + 1 end
  while true do
    if ssub(str, pos, pos) ~= '"' then decode_error(str, pos, "expected string key") end
    local k
    k, pos = decode_string(str, pos)
    pos = skip_ws(str, pos)
    if ssub(str, pos, pos) ~= ":" then decode_error(str, pos, "expected ':'") end
    pos = skip_ws(str, pos + 1)
    local v
    v, pos = decode_value(str, pos, depth + 1)
    obj[k] = v
    pos = skip_ws(str, pos)
    local c = ssub(str, pos, pos)
    if c == "}" then return obj, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected ',' or '}'") end
    pos = skip_ws(str, pos + 1)
  end
end

decode_value = function(str, pos, depth)
  if depth > 200 then decode_error(str, pos, "nesting too deep") end
  pos = skip_ws(str, pos)
  local c = ssub(str, pos, pos)
  if c == "{" then return decode_object(str, pos, depth) end
  if c == "[" then return decode_array(str, pos, depth) end
  if c == '"' then return decode_string(str, pos) end
  if ssub(str, pos, pos + 3) == "true" then return true, pos + 4 end
  if ssub(str, pos, pos + 4) == "false" then return false, pos + 5 end
  if ssub(str, pos, pos + 3) == "null" then return nil, pos + 4 end
  local s, e = sfind(str, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
  if s then
    local num = tonumber(ssub(str, s, e))
    if num then return num, e + 1 end
  end
  decode_error(str, pos, "unexpected character '" .. c .. "'")
end

function M.decode(str)
  if type(str) ~= "string" then return nil, "json: expected string, got " .. type(str) end
  local ok, res, pos = pcall(decode_value, str, 1, 0)
  if not ok then
    if type(res) == "table" and res.json_error then return nil, res.json_error end
    return nil, "json: " .. tostring(res)
  end
  pos = skip_ws(str, pos)
  if pos <= #str then return nil, sformat("json: trailing garbage at position %d", pos) end
  return res
end

return M
