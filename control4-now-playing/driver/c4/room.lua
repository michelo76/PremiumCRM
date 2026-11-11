--[[
c4.room -- Control4 room media -> a playback document for the np "static" provider.

Room variables (on the room device):
  1000 CURRENT_SELECTED_DEVICE   1001 CURRENT_AUDIO_DEVICE   1002 CURRENT_VIDEO_DEVICE
  1005 CURRENT_MEDIA             1006 CURRENT_MEDIA_TYPE     1010 POWER_STATE
  1031 "CURRENT MEDIA INFO"      1036 PLAYING_AUDIO_DEVICE
There is NO play/pause variable on the room, so room media is reported as "playing"
whenever the room is on and media info is non-empty.

The XML shape of 1031 is undocumented: source drivers feed it with UPDATE_MEDIA_INFO
(TITLE, ALBUM, ARTIST, GENRE, IMAGEURL -- IMAGEURL sometimes base64-encoded), others with
LINE1/LINE2/LINE3. parse_media_info is therefore deliberately tolerant.

Pure helpers
  Room.parse_media_info(str) -> { title, artist, album, genre, image } | nil
  Room.is_on(snapshot)       -> true | false | nil (unknown)
  Room.to_playback(snapshot, device_name) -> playback (np.playback shape)
Watcher (C4 injected)
  local r = Room.new(C4, deps, on_change)    on_change(snapshot, var_id)
  r:watch(room_id) / r:unwatch()
  r:on_variable(idDevice, idVariable, strValue) -> true when handled
  r:snapshot(), r:device_name(), r:playback(), r:raw_report() (for "Print Room Media Info")
]]

local util = require("np.util")
local json = require("np.json")
local b64 = require("c4.b64")

local M = {}

M.VAR = {
  SELECTED = 1000, AUDIO = 1001, VIDEO = 1002, MEDIA = 1005, MEDIA_TYPE = 1006, POWER = 1010,
  VOLUME = 1011, MEDIA_INFO = 1031, PLAYING_AUDIO = 1036,
}
M.WATCH = { 1000, 1005, 1010, 1031, 1036 }

-- canonical field <- normalized tag names, in priority order
local FIELDS = {
  title = { "title", "songname", "song", "trackname", "track", "name", "line1" },
  artist = { "artist", "artistname", "performer", "line2" },
  album = { "album", "albumname", "line3" },
  genre = { "genre" },
  image = { "imageurl", "image", "img", "imgurl", "art", "arturl", "artwork", "artworkurl", "albumart",
    "albumarturl", "coverart", "coverarturl", "cover", "thumbnail", "thumb" },
}

local function norm_tag(t)
  t = tostring(t):lower():gsub("^.*:", "") -- strip namespace prefix
  return (t:gsub("[^%w]", ""))
end

local function clean(v)
  if type(v) ~= "string" then
    if type(v) == "number" then return tostring(v) end
    return nil
  end
  v = util.xml_unescape(v)
  if v:find("&amp;", 1, true) or v:find("&#", 1, true) then v = util.xml_unescape(v) end -- double-escaped
  v = v:gsub("^%s+", ""):gsub("%s+$", "")
  if v == "" or v:lower() == "null" or v:lower() == "(null)" then return nil end
  return v
end

function M.image_url(v)
  v = clean(v)
  if not v then return nil end
  if v:find("^https?://") then return v end
  local d = b64.decode(v)
  if d then
    d = d:gsub("^%s+", ""):gsub("%s+$", "")
    if d:find("^https?://[%w%.%-%[%]:]+") and not d:find("[%z\1-\31]") then return d end
  end
  return nil
end

-- collect tag -> text and attribute name -> value (first occurrence wins)
local function collect_xml(s, found)
  -- CDATA -> escaped text so the leaf pattern below sees no '<'
  s = s:gsub("<!%[CDATA%[(.-)%]%]>", function(c)
    return (c:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
  end)
  for open, attrs, text, close in s:gmatch("<([%w_:%-%.]+)([^<>]-)>([^<]*)</([%w_:%-%.]+)%s*>") do
    if norm_tag(open) == norm_tag(close) then
      local k = norm_tag(open)
      if found[k] == nil then found[k] = text end
    end
  end
  for _, attrs in s:gmatch("<([%w_:%-%.]+)([^<>]*)>") do
    for k, _, v in attrs:gmatch("([%w_:%-%.]+)%s*=%s*([\"'])(.-)%2") do
      local nk = norm_tag(k)
      if found[nk] == nil then found[nk] = v end
    end
  end
  -- <item name="TITLE">x</item> / <item><key>TITLE</key><value>x</value></item>
  for nm, text in s:gmatch("<[%w_:%-%.]+[^<>]-name%s*=%s*[\"']([^\"']+)[\"'][^<>]->([^<]*)</") do
    local nk = norm_tag(nm)
    if found[nk] == nil then found[nk] = text end
  end
  for key, text in s:gmatch("<[Kk][Ee][Yy]>([^<]*)</[Kk][Ee][Yy]>%s*<[Vv][Aa][Ll][Uu][Ee]>([^<]*)</[Vv][Aa][Ll][Uu][Ee]>") do
    local nk = norm_tag(key)
    if found[nk] == nil then found[nk] = text end
  end
end

local function collect_json(v, found, depth)
  if depth > 4 or type(v) ~= "table" then return end
  for k, x in pairs(v) do
    if type(k) == "string" and (type(x) == "string" or type(x) == "number") then
      local nk = norm_tag(k)
      if found[nk] == nil then found[nk] = tostring(x) end
    elseif type(x) == "table" then
      collect_json(x, found, depth + 1)
    end
  end
end

function M.parse_media_info(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  local found = {}
  local first = s:sub(1, 1)
  if first == "{" or first == "[" then
    local ok, v = pcall(json.decode, s)
    if ok and type(v) == "table" then collect_json(v, found, 0) end
  else
    if not s:find("<", 1, true) and s:find("&lt;", 1, true) then s = util.xml_unescape(s) end
    collect_xml(s, found)
  end
  local out = {}
  local any = false
  for field, names in pairs(FIELDS) do
    for _, n in ipairs(names) do
      local v
      if field == "image" then v = M.image_url(found[n]) else v = clean(found[n]) end
      if v then out[field] = v; any = true; break end
    end
  end
  if not (out.title or out.artist or out.album) then return nil end
  return any and out or nil
end

local ON = { ["1"] = true, on = true, ["true"] = true, yes = true }
local OFF = { ["0"] = true, off = true, ["false"] = true, no = true }

function M.is_on(snap)
  snap = snap or {}
  local p = snap[M.VAR.POWER]
  if p ~= nil then
    p = tostring(p):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if ON[p] then return true end
    if OFF[p] then return false end
  end
  local sel = tonumber(snap[M.VAR.SELECTED])
  if sel ~= nil then return sel > 0 end
  return nil
end

function M.to_playback(snap, device_name, now)
  snap = snap or {}
  local on = M.is_on(snap)
  local pb = {
    source = { provider = "c4room", device_name = device_name },
    playback = { state = "idle", position_updated_at = now, is_live = false },
    media = { kind = "unknown", genres = {} },
  }
  if on == false then
    pb.playback.state = "off"
    return pb
  end
  local info = M.parse_media_info(snap[M.VAR.MEDIA_INFO])
  if info and on ~= false then
    pb.playback.state = "playing"
    pb.media = {
      kind = (info.artist or info.album) and "music" or "unknown",
      title = info.title, artist = info.artist, album = info.album,
      genres = info.genre and { info.genre } or {},
      artwork_url = info.image,
    }
  end
  return pb
end

---------------------------------------------------------------------------
-- watcher
---------------------------------------------------------------------------

local R = {}
R.__index = R

function M.new(C4, deps, on_change)
  return setmetatable({ C4 = C4, deps = deps, on_change = on_change, room_id = nil, snap = {} }, R)
end

function R:watch(room_id)
  room_id = tonumber(room_id)
  if self.room_id == room_id and self.watching then return end
  self:unwatch()
  if not room_id then return end
  self.room_id = room_id
  self.watching = true
  self.snap = {}
  local C4 = self.C4
  for _, v in ipairs(M.WATCH) do
    if C4.RegisterVariableListener then
      local ok, err = pcall(C4.RegisterVariableListener, C4, room_id, v)
      if not ok then self.deps.log("warn", "RegisterVariableListener(" .. room_id .. "," .. v .. "): " .. tostring(err)) end
    end
  end
  -- belt and braces: read current values for anything the listener did not deliver yet
  for _, v in ipairs(M.WATCH) do
    if self.snap[v] == nil and C4.GetDeviceVariable then
      local ok, val = pcall(C4.GetDeviceVariable, C4, room_id, v)
      if ok and val ~= nil then self.snap[v] = tostring(val) end
    end
  end
  if self.on_change then self.on_change(self.snap, nil) end
end

function R:unwatch()
  if self.watching and self.room_id and self.C4.UnregisterVariableListener then
    for _, v in ipairs(M.WATCH) do
      pcall(self.C4.UnregisterVariableListener, self.C4, self.room_id, v)
    end
  end
  self.watching = false
  self.room_id = nil
  self.snap = {}
end

function R:on_variable(dev, var, value)
  dev, var = tonumber(dev), tonumber(var)
  if not self.watching or dev ~= self.room_id then return false end
  local known = false
  for _, v in ipairs(M.WATCH) do if v == var then known = true end end
  if not known then return false end
  if var == M.VAR.MEDIA_INFO then
    self.deps.log("debug", "room " .. tostring(dev) .. " CURRENT MEDIA INFO raw: " .. tostring(value))
  end
  if self.snap[var] == value then return true end
  self.snap[var] = value
  if self.on_change then self.on_change(self.snap, var) end
  return true
end

function R:snapshot() return self.snap end
function R:is_on() return M.is_on(self.snap) end

function R:device_name()
  local id = tonumber(self.snap[M.VAR.SELECTED])
  if not id or id <= 0 then id = tonumber(self.snap[M.VAR.PLAYING_AUDIO]) end
  if not id or id <= 0 then return nil end
  if self.C4.GetDeviceDisplayName then
    local ok, name = pcall(self.C4.GetDeviceDisplayName, self.C4, id)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return nil
end

function R:playback()
  return M.to_playback(self.snap, self:device_name(), self.deps.now())
end

function R:raw_report()
  local lines = { "Room device " .. tostring(self.room_id) .. (self.watching and "" or " (not watched)") }
  local names = {
    [1000] = "CURRENT_SELECTED_DEVICE", [1005] = "CURRENT_MEDIA", [1010] = "POWER_STATE",
    [1031] = "CURRENT MEDIA INFO", [1036] = "PLAYING_AUDIO_DEVICE",
  }
  for _, v in ipairs(M.WATCH) do
    local val = self.snap[v]
    if val == nil and self.room_id and self.C4.GetDeviceVariable then
      local ok, x = pcall(self.C4.GetDeviceVariable, self.C4, self.room_id, v)
      if ok then val = x end
    end
    lines[#lines + 1] = string.format("  %d %s = %s", v, names[v], val == nil and "(nil)" or ("[[" .. tostring(val) .. "]]"))
  end
  local info = M.parse_media_info(self.snap[M.VAR.MEDIA_INFO])
  if info then
    lines[#lines + 1] = "  parsed: title=" .. tostring(info.title) .. " artist=" .. tostring(info.artist) ..
      " album=" .. tostring(info.album) .. " genre=" .. tostring(info.genre) .. " image=" .. tostring(info.image)
  else
    lines[#lines + 1] = "  parsed: (no media info)"
  end
  lines[#lines + 1] = "  room on: " .. tostring(M.is_on(self.snap)) .. ", device: " .. tostring(self:device_name())
  return table.concat(lines, "\n")
end

return M
