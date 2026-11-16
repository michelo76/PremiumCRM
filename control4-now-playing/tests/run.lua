--[[
Zero-dependency test runner (Lua 5.1 / LuaJIT).

  lua tests/run.lua                 run every spec
  lua tests/run.lua engine util     run specs whose file name contains any of the words
  luajit tests/run.lua -v           verbose (print each test)

Specs live in tests/spec/*_spec.lua (core) and tests/c4/*_spec.lua (Control4 glue) and use the globals describe/it/before_each plus the
assertion helpers in `T` (passed as the spec chunk's first argument and also global `T`).
]]

local script = arg and arg[0] or "tests/run.lua"
local tests_dir = script:match("^(.*)[/\\][^/\\]*$") or "."
local root = tests_dir .. "/.."
package.path = root .. "/driver/?.lua;" .. root .. "/tests/?.lua;" .. root .. "/tests/c4/?.lua;" .. package.path

local SPECS = {
  "json_spec", "util_spec", "playback_spec", "net_spec", "roku_spec", "homeassistant_spec",
  "bridge_static_spec", "bridge_contract_spec", "multi_spec", "tmdb_spec", "omdb_spec", "gracenote_spec", "music_spec",
  "pipeline_spec", "schema_spec", "flatten_spec", "engine_spec",
  -- Control4 glue (tests/c4/): pure modules, then the real driver.lua against the C4 mock
  "c4/static_spec", "c4/config_spec", "c4/events_spec", "c4/room_spec", "c4/artwork_spec",
  "c4/httpserver_spec", "c4/driver_spec",
}

local verbose = false
local filters = {}
for _, a in ipairs(arg or {}) do
  if a == "-v" then verbose = true else filters[#filters + 1] = a end
end

---------------------------------------------------------------------------
-- assertions
---------------------------------------------------------------------------

local T = {}
_G.T = T
T.root = root

local function fmt(v, depth)
  depth = depth or 0
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  if depth > 3 then return "{...}" end
  local parts = {}
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = tostring(k) .. "=" .. fmt(v[k], depth + 1)
    if #parts > 12 then parts[#parts + 1] = "..."; break end
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end
T.fmt = fmt

local function fail(msg, level)
  error({ test_failure = msg }, (level or 2) + 1)
end

local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

function T.eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual))
  end
end
function T.neq(actual, unexpected, msg)
  if actual == unexpected then fail((msg and (msg .. ": ") or "") .. "did not expect " .. fmt(unexpected)) end
end
function T.deep_eq(actual, expected, msg)
  if not deep_eq(actual, expected) then
    fail((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual))
  end
end
function T.ok(v, msg) if not v then fail(msg or ("expected truthy, got " .. fmt(v))) end end
function T.no(v, msg) if v then fail(msg or ("expected falsy, got " .. fmt(v))) end end
function T.is_nil(v, msg) if v ~= nil then fail((msg and (msg .. ": ") or "") .. "expected nil, got " .. fmt(v)) end end
function T.near(a, b, tol, msg)
  tol = tol or 1e-6
  if type(a) ~= "number" or math.abs(a - b) > tol then
    fail((msg and (msg .. ": ") or "") .. "expected ~" .. tostring(b) .. ", got " .. fmt(a))
  end
end
function T.contains(s, sub, msg)
  if type(s) ~= "string" or not s:find(sub, 1, true) then
    fail((msg and (msg .. ": ") or "") .. "expected " .. fmt(s) .. " to contain " .. fmt(sub))
  end
end
function T.gt(a, b, msg) if not (type(a) == "number" and a > b) then fail((msg or "") .. " expected > " .. tostring(b) .. ", got " .. fmt(a)) end end
function T.lt(a, b, msg) if not (type(a) == "number" and a < b) then fail((msg or "") .. " expected < " .. tostring(b) .. ", got " .. fmt(a)) end end

function T.fixture(name)
  local f = assert(io.open(root .. "/tests/fixtures/" .. name, "rb"), "missing fixture " .. name)
  local s = f:read("*a")
  f:close()
  return s
end

---------------------------------------------------------------------------
-- describe / it
---------------------------------------------------------------------------

local results = { passed = 0, failed = 0, failures = {} }
local current_suite = {}
local befores = {}

function _G.describe(name, fn)
  current_suite[#current_suite + 1] = name
  local saved = #befores
  fn()
  for i = #befores, saved + 1, -1 do befores[i] = nil end
  current_suite[#current_suite] = nil
end

function _G.before_each(fn)
  befores[#befores + 1] = fn
end

function _G.it(name, fn)
  local full = table.concat(current_suite, " > ") .. " > " .. name
  local ok, err = xpcall(function()
    for _, b in ipairs(befores) do b() end
    fn()
  end, function(e)
    if type(e) == "table" and e.test_failure then
      return e.test_failure .. "\n" .. debug.traceback("", 3):gsub("\n[^\n]*run%.lua[^\n]*", "")
    end
    return tostring(e) .. "\n" .. debug.traceback("", 2)
  end)
  if ok then
    results.passed = results.passed + 1
    if verbose then print("  ok   " .. full) end
  else
    results.failed = results.failed + 1
    results.failures[#results.failures + 1] = { name = full, err = err }
    if verbose then print("  FAIL " .. full) end
  end
end

---------------------------------------------------------------------------

local function selected(name)
  if #filters == 0 then return true end
  for _, f in ipairs(filters) do if name:find(f, 1, true) then return true end end
  return false
end

local t0 = os.clock()
for _, name in ipairs(SPECS) do
  if selected(name) then
    if verbose then print(name) end
    local file = name:find("/", 1, true) and (root .. "/tests/" .. name .. ".lua")
      or (root .. "/tests/spec/" .. name .. ".lua")
    local chunk, lerr = loadfile(file)
    if not chunk then
      results.failed = results.failed + 1
      results.failures[#results.failures + 1] = { name = name, err = "load error: " .. tostring(lerr) }
    else
      local before = results.passed + results.failed
      local ok, err = pcall(chunk, T)
      if not ok then
        results.failed = results.failed + 1
        results.failures[#results.failures + 1] = { name = name, err = "spec crashed: " .. tostring(err) }
      end
      if not verbose then
        io.write(string.format("%-22s %3d tests\n", name, results.passed + results.failed - before))
      end
    end
  end
end

for _, f in ipairs(results.failures) do
  print("\nFAIL: " .. f.name .. "\n  " .. tostring(f.err):gsub("\n", "\n  "))
end
print(string.format("\n%d passed, %d failed (%s, %.2fs)", results.passed, results.failed,
  (jit and jit.version) or _VERSION, os.clock() - t0))
os.exit(results.failed == 0 and 0 or 1)
