local T = ...
local FakeDeps = require("fake_deps")
local net = require("np.net")

describe("np.net.get_json", function()
  local fd, got
  before_each(function()
    fd = FakeDeps.new()
    got = nil
  end)
  local function call(url)
    net.get_json(fd.deps, { url = url, timeout = 3 }, function(err, data, info) got = { err = err, data = data, info = info } end)
    fd:flush()
  end
  it("decodes success", function()
    fd:route("/ok", FakeDeps.json({ a = 1 }))
    call("http://x/ok")
    T.is_nil(got.err); T.eq(got.data.a, 1); T.eq(got.info.kind, "ok")
  end)
  it("classifies 429 with Retry-After", function()
    fd:route("/rl", { status = 429, headers = { ["retry-after"] = "17" }, body = "" })
    call("http://x/rl")
    T.eq(got.info.kind, "rate_limited"); T.eq(got.info.retry_after, 17); T.contains(got.err, "429")
  end)
  it("classifies 401, 404, 500, garbage, transport errors", function()
    fd:route("/401", { status = 401, body = '{"status_message":"Invalid API key"}' })
    call("http://x/401"); T.eq(got.info.kind, "auth"); T.eq(got.data.status_message, "Invalid API key")
    fd:route("/404", { status = 404, body = "nope" })
    call("http://x/404"); T.eq(got.info.kind, "not_found")
    fd:route("/500", { status = 500, body = "boom" })
    call("http://x/500"); T.eq(got.info.kind, "http"); T.contains(got.err, "500")
    fd:route("/garbage", { status = 200, body = "<html>" })
    call("http://x/garbage"); T.eq(got.info.kind, "decode")
    fd:route("/down", { err = "connection refused" })
    call("http://x/down"); T.eq(got.info.kind, "transport"); T.contains(got.err, "refused")
  end)
  it("times out via safety timer when the transport never answers, exactly once", function()
    fd:route("/hang", { never = true })
    local calls = 0
    net.get_json(fd.deps, { url = "http://x/hang", timeout = 3 }, function(err) calls = calls + 1; got = err end)
    fd:advance(7)
    T.eq(calls, 0)
    fd:advance(2)
    T.eq(calls, 1); T.contains(got, "timeout")
    fd:advance(60)
    T.eq(calls, 1)
  end)
  it("survives a transport that throws or answers twice", function()
    local deps = { json = fd.deps.json, set_timer = fd.deps.set_timer,
      http = { request = function() error("socket exploded") end } }
    local e
    net.request(deps, { url = "u" }, function(err) e = err end)
    T.contains(e, "socket exploded")
    local n = 0
    deps.http.request = function(_, cb) cb(nil, { status = 200, body = "{}" }); cb(nil, { status = 200, body = "{}" }) end
    net.request(deps, { url = "u" }, function() n = n + 1 end)
    T.eq(n, 1)
  end)
end)
