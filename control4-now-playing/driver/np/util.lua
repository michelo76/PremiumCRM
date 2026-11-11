--[[
np.util -- pure helpers shared by every Now Playing module (no C4, no io).

  util.trim(s), util.nonempty(v) -> trimmed string | nil
  util.urlencode(s), util.query(params) -> "a=1&b=2" (sorted, nil skipped), util.url(base, params)
  util.clean_title(s)            -> display/search title with junk removed (year, [4K], SxxEyy..., release tags,
                                    " - Topic", "(Official Video)", "(feat. X)", "- Remastered 2011" ...)
  util.extract_year(s)           -> number | nil
  util.parse_episode(s)          -> {season=, episode=, series=, episode_title=} | nil
  util.norm(s)                   -> lowercase ascii-folded alnum token string (for keys and matching)
  util.levenshtein(a, b), util.similarity(a, b) -> 0..1
  util.xml_parse(s) -> root | nil, err ; util.xml_child(node, tag), util.xml_children(node, tag),
  util.xml_text(node, tag), util.xml_find(node, tag)
  util.deep_equal(a, b), util.copy(t), util.deep_copy(t)
  util.iso8601_to_epoch(s), util.epoch_to_iso(t), util.days_from_civil(y, m, d)
  util.format_money(n), util.truncate(s, n), util.join(list, sep), util.split(s, sep)
  util.is_list(t), util.round(n, places), util.hash(s)
]]

local M = {}

local floor = math.floor

function M.trim(s)
  if s == nil then return nil end
  s = tostring(s)
  s = s:gsub("^%s+", "")
  s = s:gsub("%s+$", "")
  return s
end

function M.nonempty(v)
  local t = type(v)
  if t == "number" then return tostring(v) end
  if t ~= "string" then return nil end
  v = M.trim(v)
  if v == "" then return nil end
  return v
end

function M.round(n, places)
  if type(n) ~= "number" then return nil end
  local m = 10 ^ (places or 0)
  return floor(n * m + 0.5) / m
end

function M.split(s, sep)
  local out = {}
  if s == nil then return out end
  sep = sep or ","
  local start = 1
  while true do
    local i, j = string.find(s, sep, start, true)
    if not i then
      out[#out + 1] = string.sub(s, start)
      break
    end
    out[#out + 1] = string.sub(s, start, i - 1)
    start = j + 1
  end
  return out
end

function M.join(list, sep)
  local out = {}
  if list then
    for i = 1, (list.n or #list) do
      local v = list[i]
      if v ~= nil and v ~= "" then out[#out + 1] = tostring(v) end
    end
  end
  return table.concat(out, sep or ", ")
end

function M.is_list(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

---------------------------------------------------------------------------
-- URL helpers
---------------------------------------------------------------------------

function M.urlencode(s)
  s = tostring(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function M.query(params)
  local keys = {}
  for k, v in pairs(params or {}) do
    if v ~= nil then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = M.urlencode(k) .. "=" .. M.urlencode(tostring(params[k]))
  end
  return table.concat(parts, "&")
end

function M.url(base, params)
  local q = M.query(params)
  if q == "" then return base end
  return base .. (string.find(base, "?", 1, true) and "&" or "?") .. q
end

---------------------------------------------------------------------------
-- Text normalisation
---------------------------------------------------------------------------

-- Common Latin-1 / Latin Extended-A characters (UTF-8) folded to ASCII.
local FOLD = {
  ["à"]="a",["á"]="a",["â"]="a",["ã"]="a",["ä"]="a",["å"]="a",["æ"]="ae",["ç"]="c",
  ["è"]="e",["é"]="e",["ê"]="e",["ë"]="e",["ì"]="i",["í"]="i",["î"]="i",["ï"]="i",
  ["ñ"]="n",["ò"]="o",["ó"]="o",["ô"]="o",["õ"]="o",["ö"]="o",["ø"]="o",["ù"]="u",
  ["ú"]="u",["û"]="u",["ü"]="u",["ý"]="y",["ÿ"]="y",["ß"]="ss",["œ"]="oe",
  ["À"]="a",["Á"]="a",["Â"]="a",["Ã"]="a",["Ä"]="a",["Å"]="a",["Æ"]="ae",["Ç"]="c",
  ["È"]="e",["É"]="e",["Ê"]="e",["Ë"]="e",["Ì"]="i",["Í"]="i",["Î"]="i",["Ï"]="i",
  ["Ñ"]="n",["Ò"]="o",["Ó"]="o",["Ô"]="o",["Õ"]="o",["Ö"]="o",["Ø"]="o",["Ù"]="u",
  ["Ú"]="u",["Û"]="u",["Ü"]="u",["Ý"]="y",["Œ"]="oe",
  ["’"]="'",["‘"]="'",["“"]='"',["”"]='"',["–"]="-",["—"]="-",["·"]=" ",
}

function M.fold(s)
  if not s then return s end
  return (s:gsub("[\192-\239][\128-\191]+", function(ch) return FOLD[ch] or ch end))
end

-- Lowercased, ascii-folded, punctuation-free, single-spaced token string.
function M.norm(s)
  if s == nil then return "" end
  s = M.fold(tostring(s)):lower()
  s = s:gsub("&", " and ")
  s = s:gsub("['`]", "")
  s = s:gsub("[^%w]+", " ")
  return M.trim(s:gsub("%s+", " ")) or ""
end

-- Junk that is always removed when it appears inside brackets.
local BRACKET_JUNK = {
  "^%d%d%d%d$", "^official", "video$", "^lyrics?$", "lyric video", "^audio$", "official audio",
  "visuali[sz]er", "^hd$", "^hq$", "^4k", "^uhd", "^8k", "^1080p", "^720p", "^2160p", "remaster",
  "^explicit$", "^clean$", "^feat[%. ]", "^ft[%. ]", "^featuring ", "^with ", "dolby vision", "^hdr",
  "^sdh$", "^cc$", "^subtitled$", "^dubbed$", "^extended", "^director'?s cut", "^imax",
  "^theatrical", "^unrated", "^bonus track", "^deluxe", "^single", "^radio edit$", "^mono$", "^stereo$",
}

-- Release tokens: once one of these appears in a "filename-like" title, the rest is junk.
local RELEASE_TOKENS = {
  ["2160p"]=1,["1080p"]=1,["1080i"]=1,["720p"]=1,["576p"]=1,["480p"]=1,["4k"]=1,["uhd"]=1,
  ["hdr"]=1,["hdr10"]=1,["dv"]=1,["x264"]=1,["x265"]=1,["h264"]=1,["h265"]=1,["hevc"]=1,
  ["avc"]=1,["bluray"]=1,["bdrip"]=1,["brrip"]=1,["webrip"]=1,["webdl"]=1,["web"]=1,["hdtv"]=1,
  ["dvdrip"]=1,["remux"]=1,["aac"]=1,["ac3"]=1,["eac3"]=1,["dts"]=1,["ddp5"]=1,["dd5"]=1,
  ["atmos"]=1,["10bit"]=1,["proper"]=1,["repack"]=1,["amzn"]=1,["nf"]=1,["dsnp"]=1,["hmax"]=1,
}

local function strip_ws(s)
  s = s:gsub("%s+", " ")
  s = M.trim(s)
  -- trailing / leading separators
  s = s:gsub("[%s%-:|/,~·]+$", "")
  s = s:gsub("^[%s%-:|/,~]+", "")
  return s
end

local function bracket_is_junk(inner)
  local low = M.trim(inner:lower())
  if low == "" then return true end
  for _, p in ipairs(BRACKET_JUNK) do
    if low:find(p) then return true end
  end
  return false
end

local function is_filename_like(s)
  if s:find(" ", 1, true) then return false end
  local seps = 0
  for _ in s:gmatch("[%._]") do seps = seps + 1 end
  return seps >= 2
end

-- Locate an episode marker; returns s_idx, e_idx (byte positions), season, episode.
local function find_episode_marker(s)
  local low = s:lower()
  local best
  local function consider(a, b, season, ep)
    if a and (not best or a < best[1]) then best = { a, b, tonumber(season), tonumber(ep) } end
  end
  -- S02E07, s2e7, S02 E07, S02.E07
  local a, b, se, ep = low:find("%f[%w]s(%d%d?)[%s%._%-]?e(%d%d?%d?)%f[%W]")
  consider(a, b, se, ep)
  -- Season 2 Episode 7 / Season 2, Ep. 7
  a, b, se, ep = low:find("season%s*(%d+)%s*[,%-:]?%s*episode%s*(%d+)")
  consider(a, b, se, ep)
  a, b, se, ep = low:find("season%s*(%d+)%s*[,%-:]?%s*ep%.?%s*(%d+)")
  consider(a, b, se, ep)
  -- 2x07
  a, b, se, ep = low:find("%f[%w](%d%d?)x(%d%d%d?)%f[%W]")
  consider(a, b, se, ep)
  if best then return best[1], best[2], best[3], best[4] end
  return nil
end

-- Parse "Show S02E07 Title", "Show - Season 2 Episode 7 - Title", "Show 2x07 Title".
function M.parse_episode(s)
  if type(s) ~= "string" then return nil end
  local work = s
  if is_filename_like(work) then
    work = work:gsub("%.%w%w%w%w?$", ""):gsub("[%._]", " ")
  end
  local a, b, season, episode = find_episode_marker(work)
  if not a then return nil end
  local series = strip_ws(work:sub(1, a - 1))
  local after = strip_ws(work:sub(b + 1))
  -- strip release junk from the episode title part
  local cut
  for tok_start, tok in after:lower():gmatch("()(%w+)") do
    if RELEASE_TOKENS[tok] then cut = tok_start; break end
  end
  if cut then after = strip_ws(after:sub(1, cut - 1)) end
  after = after:gsub("%b[]", ""):gsub("%s+", " ")
  after = strip_ws(after)
  return {
    season = season,
    episode = episode,
    series = series ~= "" and series or nil,
    episode_title = after ~= "" and after or nil,
  }
end

function M.extract_year(s)
  if type(s) ~= "string" then return nil end
  local y = s:match("[%(%[]((1[89]%d%d))[%)%]]") or s:match("[%(%[]((20%d%d))[%)%]]")
  if y then return tonumber(y) end
  if is_filename_like(s) or s:lower():find("1080p") or s:lower():find("2160p") or s:lower():find("720p") then
    local last
    for yy in s:gmatch("%f[%d]((19%d%d))%f[%D]") do last = yy end
    for yy in s:gmatch("%f[%d]((20%d%d))%f[%D]") do last = last and math.max(tonumber(last), tonumber(yy)) or yy end
    if last then return tonumber(last) end
  end
  return nil
end

function M.clean_title(s)
  if type(s) ~= "string" then return nil end
  s = M.trim(s)
  if s == "" then return nil end
  local filename = is_filename_like(s)
  if filename then
    s = s:gsub("%.[mM][kK][vV]$", ""):gsub("%.[mM][pP]4$", ""):gsub("%.[aA][vV][iI]$", "")
         :gsub("%.[mM]4[vV]$", ""):gsub("%.[tT][sS]$", ""):gsub("%.[mM][oO][vV]$", "")
    s = s:gsub("[%._]", " ")
  end
  -- bracketed junk
  s = s:gsub("%b()", function(m) if bracket_is_junk(m:sub(2, -2)) then return " " end end)
  s = s:gsub("%b[]", function(m) if bracket_is_junk(m:sub(2, -2)) then return " " end end)
  s = s:gsub("%b{}", function(m) if bracket_is_junk(m:sub(2, -2)) then return " " end end)
  -- " - Topic" (YouTube auto channels), trailing official-video markers, remaster suffixes
  local low = s:lower()
  local cuts = {
    "%s+%-%s+topic%s*$", "%s*[%-|]%s*official[%w%s]*$", "%s*[%-|]%s*lyrics?%s*v?i?d?e?o?%s*$",
    "%s+%-%s+[%w%s]*remaster[%w%s]*$", "%s+%-%s+single%s*$", "%s+%-%s+ep%s*$",
    "%s+%-%s+%d%d%d%d%s+remaster[%w%s]*$", "%s+feat%.?%s.*$", "%s+ft%.%s.*$",
  }
  for _, p in ipairs(cuts) do
    local a = low:find(p)
    if a then s = s:sub(1, a - 1); low = low:sub(1, a - 1) end
  end
  -- episode marker: keep series part
  local a = find_episode_marker(s)
  if a and a > 1 then s = s:sub(1, a - 1) end
  -- release junk & trailing year in filename-like titles
  if filename or low:find("%f[%w]1080p") or low:find("%f[%w]2160p") or low:find("%f[%w]720p") then
    local cut
    for tok_start, tok in s:lower():gmatch("()(%w+)") do
      if RELEASE_TOKENS[tok] then cut = tok_start; break end
    end
    if cut then s = s:sub(1, cut - 1) end
    s = strip_ws(s)
    local prefix = s:match("^(.-)%s+[12][089]%d%d$")
    if prefix and prefix ~= "" then s = prefix end
  end
  s = strip_ws(s)
  if s == "" then return nil end
  return s
end

---------------------------------------------------------------------------
-- Fuzzy matching
---------------------------------------------------------------------------

function M.levenshtein(a, b)
  a, b = a or "", b or ""
  if #a > 100 then a = a:sub(1, 100) end
  if #b > 100 then b = b:sub(1, 100) end
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  local prev, cur = {}, {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    cur[0] = i
    local ca = a:byte(i)
    for j = 1, lb do
      local cost = (ca == b:byte(j)) and 0 or 1
      local v = prev[j] + 1
      local ins = cur[j - 1] + 1
      if ins < v then v = ins end
      local sub = prev[j - 1] + cost
      if sub < v then v = sub end
      cur[j] = v
    end
    prev, cur = cur, prev
  end
  return prev[lb]
end

local function tokens(s)
  local t = {}
  for w in s:gmatch("%S+") do t[#t + 1] = w end
  return t
end

local function sim_norm(na, nb)
  if na == "" or nb == "" then return 0 end
  if na == nb then return 1 end
  local ta, tb = tokens(na), tokens(nb)
  local counts = {}
  for _, w in ipairs(tb) do counts[w] = (counts[w] or 0) + 1 end
  local common = 0
  for _, w in ipairs(ta) do
    if (counts[w] or 0) > 0 then common = common + 1; counts[w] = counts[w] - 1 end
  end
  local dice = 2 * common / (#ta + #tb)
  local maxlen = math.max(#na, #nb)
  local lev = 1 - M.levenshtein(na, nb) / maxlen
  return 0.55 * dice + 0.45 * lev
end

-- Similarity 0..1 between two titles (token Dice + Levenshtein ratio, article-insensitive).
function M.similarity(a, b)
  local na, nb = M.norm(a), M.norm(b)
  local s = sim_norm(na, nb)
  local sa, sb = na:gsub("^the ", ""):gsub("^a ", ""), nb:gsub("^the ", ""):gsub("^a ", "")
  local s2 = sim_norm(sa, sb)
  if s2 > s then s = s2 end
  return s
end

---------------------------------------------------------------------------
-- Minimal XML reader (enough for Roku ECP)
---------------------------------------------------------------------------

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + floor(cp / 64), 0x80 + cp % 64) end
  if cp < 0x10000 then
    return string.char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return string.char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end

function M.xml_unescape(s)
  return (s:gsub("&(#?x?)(%w+);", function(kind, v)
    if kind == "#" then local n = tonumber(v); return n and utf8_char(n) or nil end
    if kind == "#x" then local n = tonumber(v, 16); return n and utf8_char(n) or nil end
    return ENTITIES[v]
  end))
end

function M.xml_parse(s)
  if type(s) ~= "string" then return nil, "xml: not a string" end
  local root = { tag = "#document", attrs = {}, children = {}, text = "" }
  local stack = { root }
  local pos = 1
  local len = #s
  while pos <= len do
    local lt = s:find("<", pos, true)
    local top = stack[#stack]
    if not lt then
      top.text = top.text .. M.xml_unescape(s:sub(pos))
      break
    end
    if lt > pos then top.text = top.text .. M.xml_unescape(s:sub(pos, lt - 1)) end
    if s:sub(lt, lt + 3) == "<!--" then
      local e = s:find("-->", lt + 4, true)
      if not e then return nil, "xml: unterminated comment" end
      pos = e + 3
    elseif s:sub(lt, lt + 8) == "<![CDATA[" then
      local e = s:find("]]>", lt + 9, true)
      if not e then return nil, "xml: unterminated CDATA" end
      top.text = top.text .. s:sub(lt + 9, e - 1)
      pos = e + 3
    elseif s:sub(lt, lt + 1) == "<?" or s:sub(lt, lt + 1) == "<!" then
      local e = s:find(">", lt, true)
      if not e then return nil, "xml: unterminated declaration" end
      pos = e + 1
    else
      local e = s:find(">", lt, true)
      if not e then return nil, "xml: unterminated tag" end
      local body = s:sub(lt + 1, e - 1)
      if body:sub(1, 1) == "/" then
        local name = M.trim(body:sub(2))
        if #stack < 2 then return nil, "xml: unexpected close </" .. name .. ">" end
        if stack[#stack].tag ~= name then
          return nil, "xml: mismatched close </" .. name .. "> for <" .. stack[#stack].tag .. ">"
        end
        stack[#stack] = nil
      else
        local selfclose = body:sub(-1) == "/"
        if selfclose then body = body:sub(1, -2) end
        local name = body:match("^%s*([%w_:%-%.]+)")
        if not name then return nil, "xml: bad tag at " .. lt end
        local node = { tag = name, attrs = {}, children = {}, text = "", parent = nil }
        for k, _, v in body:gmatch("([%w_:%-%.]+)%s*=%s*([\"'])(.-)%2") do
          node.attrs[k] = M.xml_unescape(v)
        end
        top.children[#top.children + 1] = node
        if not selfclose then stack[#stack + 1] = node end
      end
      pos = e + 1
    end
  end
  if #stack > 1 then return nil, "xml: unclosed <" .. stack[#stack].tag .. ">" end
  return root
end

function M.xml_child(node, tag)
  if not node then return nil end
  for _, c in ipairs(node.children) do
    if c.tag == tag then return c end
  end
  return nil
end

function M.xml_children(node, tag)
  local out = {}
  if not node then return out end
  for _, c in ipairs(node.children) do
    if tag == nil or c.tag == tag then out[#out + 1] = c end
  end
  return out
end

function M.xml_find(node, tag)
  if not node then return nil end
  if node.tag == tag then return node end
  for _, c in ipairs(node.children) do
    local f = M.xml_find(c, tag)
    if f then return f end
  end
  return nil
end

function M.xml_text(node, tag)
  local c = tag and M.xml_child(node, tag) or node
  if not c then return nil end
  return M.nonempty(c.text)
end

---------------------------------------------------------------------------
-- Tables
---------------------------------------------------------------------------

function M.deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then
    if type(a) == "number" and type(b) == "number" then return a == b end
    return false
  end
  for k, v in pairs(a) do
    if not M.deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

function M.copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return setmetatable(o, getmetatable(t))
end

function M.deep_copy(t, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local o = {}
  seen[t] = o
  for k, v in pairs(t) do o[M.deep_copy(k, seen)] = M.deep_copy(v, seen) end
  return setmetatable(o, getmetatable(t))
end

---------------------------------------------------------------------------
-- Time
---------------------------------------------------------------------------

function M.days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

function M.civil_from_days(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return y, m, d
end

-- ISO-8601 -> epoch seconds (UTC). Accepts "2024-05-01T12:34:56.789+00:00", "...Z",
-- "2024-05-01T23:00Z" (no seconds), "2024-05-01" (midnight UTC). Returns nil on failure.
function M.iso8601_to_epoch(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, rest = s:match("^%s*(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if mo < 1 or mo > 12 or d < 1 or d > 31 then return nil end
  local h, mi, sec, frac, tz = 0, 0, 0, 0, ""
  if rest ~= "" then
    local hh, mm, tail = rest:match("^[T ](%d%d):(%d%d)(.*)$")
    if not hh then return nil end
    h, mi = tonumber(hh), tonumber(mm)
    local ss, tail2 = tail:match("^:(%d%d)(.*)$")
    if ss then sec = tonumber(ss); tail = tail2 end
    local fr, tail3 = tail:match("^[%.,](%d+)(.*)$")
    if fr then frac = tonumber("0." .. fr); tail = tail3 end
    tz = tail
  end
  local offset = 0
  if tz ~= "" and tz ~= "Z" and tz ~= "z" then
    local sign, oh, om = tz:match("^([%+%-])(%d%d):?(%d?%d?)$")
    if not sign then return nil end
    offset = (tonumber(oh) * 3600 + (tonumber(om) or 0) * 60) * (sign == "-" and -1 or 1)
  end
  return M.days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec + frac - offset
end

function M.epoch_to_iso(t, with_seconds)
  t = floor(t)
  local days = floor(t / 86400)
  local secs = t - days * 86400
  local y, m, d = M.civil_from_days(days)
  local h = floor(secs / 3600)
  local mi = floor((secs % 3600) / 60)
  local s = secs % 60
  if with_seconds == false then
    return string.format("%04d-%02d-%02dT%02d:%02dZ", y, m, d, h, mi)
  end
  return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, h, mi, s)
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local function trim_decimal(s)
  return (s:gsub("%.0$", ""))
end

function M.format_money(n)
  n = tonumber(n)
  if not n or n <= 0 then return nil end
  if n >= 1e9 then
    local s = string.format("%.2f", n / 1e9):gsub("0+$", ""):gsub("%.$", "")
    return "$" .. s .. "B"
  end
  if n >= 1e6 then
    if n >= 1e8 then return "$" .. string.format("%d", floor(n / 1e6 + 0.5)) .. "M" end
    return "$" .. trim_decimal(string.format("%.1f", n / 1e6)) .. "M"
  end
  local s = string.format("%d", floor(n + 0.5))
  local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return "$" .. formatted
end

-- Byte truncation that never splits a UTF-8 sequence; appends an ellipsis when cut.
function M.truncate(s, n)
  if type(s) ~= "string" or #s <= n then return s end
  local cut = n
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut) .. "…"
end

-- djb2 hash -> 8 hex chars (no bit ops; Lua 5.1 safe)
function M.hash(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return string.format("%08x", h)
end

return M
