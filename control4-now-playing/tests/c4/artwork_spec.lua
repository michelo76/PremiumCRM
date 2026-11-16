local T = ...
local Artwork = require("c4.artwork")
local FakeDeps = require("fake_deps")
local b64 = require("c4.b64")

local PNG = "\137PNG\r\n\26\n" .. string.rep("x", 100)
local JPG = "\255\216\255\224" .. string.rep("y", 50)

local function setup(opts)
  local fd = FakeDeps.new()
  fd.deps.base64 = b64.encode
  local a = Artwork.new(fd.deps, opts or {})
  return fd, a
end

describe("c4.artwork.is_lan", function()
  it("private ranges, .local, single-label and relative are LAN", function()
    for _, u in ipairs({ "http://10.1.2.3/a.jpg", "http://172.16.0.1:8080/x", "http://172.31.255.1/x",
      "http://192.168.1.10:8765/v1/devices/a/artwork?v=1", "http://homeassistant.local:8123/api/x",
      "http://127.0.0.1/x", "http://169.254.1.1/x", "http://nas/x", "/api/media_player_proxy/x",
      "http://[fd00::1]:80/x", "http://user:pw@192.168.0.2/x" }) do
      T.ok(Artwork.is_lan(u), u)
    end
  end)
  it("public hosts and data URIs are not", function()
    for _, u in ipairs({ "https://image.tmdb.org/t/p/w500/x.jpg", "http://172.32.0.1/x", "http://8.8.8.8/x",
      "https://is1-ssl.mzstatic.com/image/x.jpg", "data:image/png;base64,AAAA", "http://[2001:db8::1]/x" }) do
      T.no(Artwork.is_lan(u), u)
    end
  end)
  it("sniffs image types", function()
    T.eq(Artwork.sniff(PNG), "image/png"); T.eq(Artwork.sniff(JPG), "image/jpeg")
    T.eq(Artwork.sniff("GIF89a...."), "image/gif"); T.is_nil(Artwork.sniff("<html>"))
  end)
end)

describe("c4.artwork fetcher (GET_ARTWORK)", function()
  local function get(a, url)
    local r = {}
    a:fetch(url, function(err, data) r.n = (r.n or 0) + 1; r.err, r.data = err, data end)
    return r
  end
  it("downloads once per URL however many ask; every caller answered exactly once; cached after", function()
    local fd, a = setup()
    local url = "http://192.168.1.20/art.png"
    fd:route("art.png", { status = 200, body = PNG, headers = { ["Content-Type"] = "image/png" }, delay = 1 })
    local r1, r2 = get(a, url), get(a, url)
    T.is_nil(r1.n, "async while downloading")
    fd:advance(2)
    T.eq(fd:count("art.png"), 1, "one in-flight request per URL")
    T.eq(r1.n, 1); T.eq(r2.n, 1)
    T.eq(r1.data, "data:image/png;base64," .. b64.encode(PNG)); T.eq(r2.data, r1.data)
    local r3 = get(a, url)
    T.eq(r3.n, 1, "cache hit answers synchronously"); T.eq(r3.data, r1.data)
    T.eq(fd:count("art.png"), 1)
  end)
  it("public URLs are fetched too (page asks after an <img> failure); disabled / non-http refused", function()
    local fd, a = setup()
    fd:route("tmdb", { status = 200, body = JPG })
    local r = get(a, "https://image.tmdb.org/x.jpg")
    fd:flush()
    T.contains(r.data, "data:image/jpeg;base64,")
    T.eq(get(a, "data:image/png;base64,AAAA").err, "not an http(s) URL")
    T.eq(get(a, "file:///etc/passwd").err, "not an http(s) URL")
    a:set_enabled(false)
    T.eq(get(a, "http://10.0.0.1/x.jpg").err, "disabled")
    T.eq(#fd.requests, 1)
  end)
  it("oversize (Content-Length or body) and failures answer an error and are not retried inside retry_s", function()
    local fd, a = setup({ max_bytes = 1000, retry_s = 300 })
    fd:route("big1", { status = 200, body = PNG, headers = { ["Content-Length"] = "5000" } })
    fd:route("big2", { status = 200, body = "\137PNG\r\n\26\n" .. string.rep("z", 2000) })
    fd:route("err", { err = "connection refused" })
    fd:route("404", { status = 404, body = "nope" })
    fd:route("html", { status = 200, body = "<html></html>", headers = { ["Content-Type"] = "text/html" } })
    local urls = { "http://10.0.0.1/big1", "http://10.0.0.1/big2", "http://10.0.0.1/err", "http://10.0.0.1/404", "http://10.0.0.1/html" }
    local rs = {}
    for i, u in ipairs(urls) do rs[i] = get(a, u) end
    fd:flush()
    for i = 1, #urls do T.eq(rs[i].n, 1); T.ok(rs[i].err, urls[i]); T.is_nil(rs[i].data) end
    T.contains(rs[1].err, "too large"); T.contains(rs[2].err, "too large"); T.eq(rs[4].err, "HTTP 404")
    T.eq(rs[5].err, "not an image")
    for _, u in ipairs(urls) do T.ok(get(a, u).err) end
    fd:flush()
    T.eq(#fd.requests, 5, "no retry inside retry_s")
    T.eq(a.stats.failed, 5)
    fd:advance(301)
    get(a, "http://10.0.0.1/err")
    fd:flush()
    T.eq(#fd.requests, 6)
  end)
  it("sniffs when Content-Type is missing/wrong; LRU cap bounds memory", function()
    local fd, a = setup({ max_entries = 3 })
    fd:route("/img", { status = 200, body = JPG, headers = { ["Content-Type"] = "application/octet-stream" } })
    for i = 1, 5 do get(a, "http://10.0.0.1/img" .. i) end
    fd:flush()
    T.eq(a:count(), 3)
    T.contains(get(a, "http://10.0.0.1/img5").data, "data:image/jpeg;base64,")
  end)
  it("auth headers only for URLs under the configured prefix", function()
    local fd, a = setup()
    a:set_auth({ { prefix = "http://192.168.1.10:8765/", headers = { Authorization = "Bearer s3" } } })
    fd:route("/", { status = 200, body = PNG })
    get(a, "http://192.168.1.10:8765/v1/devices/Den/artwork?v=1")
    get(a, "http://192.168.1.10:8766/x.png")
    get(a, "http://192.168.1.10:8765.evil.example/x.png")
    fd:flush()
    T.eq(fd.requests[1].headers.Authorization, "Bearer s3")
    T.is_nil(fd.requests[2].headers.Authorization)
    T.is_nil(fd.requests[3].headers.Authorization)
  end)
  it("clear() drops the cache and answers in-flight callers 'cancelled' (once)", function()
    local fd, a = setup()
    fd:route("x.png", { status = 200, body = PNG, delay = 1 })
    local r = get(a, "http://10.0.0.1/x.png")
    a:clear()
    T.eq(r.n, 1); T.eq(r.err, "cancelled")
    fd:advance(2)
    T.eq(r.n, 1); T.eq(a:count(), 0)
  end)
end)
