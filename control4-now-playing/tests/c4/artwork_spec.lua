local T = ...
local Artwork = require("c4.artwork")
local FakeDeps = require("fake_deps")
local b64 = require("c4.b64")

local PNG = "\137PNG\r\n\26\n" .. string.rep("x", 100)
local JPG = "\255\216\255\224" .. string.rep("y", 50)

local function setup(opts)
  local fd = FakeDeps.new()
  fd.deps.base64 = b64.encode
  local ready = 0
  opts = opts or {}
  opts.on_ready = function() ready = ready + 1 end
  local a = Artwork.new(fd.deps, opts)
  return fd, a, function() return ready end
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

describe("c4.artwork rewriter", function()
  it("returns the original until downloaded, then a data URI; restore maps back", function()
    local fd, a, ready = setup()
    local url = "http://192.168.1.20/art.png"
    fd:route("art.png", { status = 200, body = PNG, headers = { ["Content-Type"] = "image/png" } })
    T.eq(a.rewrite(url, "artwork"), url)
    T.eq(a.rewrite(url, "artwork"), url, "no duplicate download while in flight")
    fd:flush()
    T.eq(fd:count("art.png"), 1)
    T.eq(ready(), 1)
    local data = a.rewrite(url, "artwork")
    T.eq(data, "data:image/png;base64," .. b64.encode(PNG))
    T.eq(a.rewrite(url, "artwork"), data, "deterministic")
    local st = { media = { artwork_url = data }, source = { app_icon_url = "data:image/png;base64,unknown" } }
    a:restore(st)
    T.eq(st.media.artwork_url, url)
    T.is_nil(st.source.app_icon_url, "unknown data URIs never leak")
  end)
  it("public URLs untouched, disabled = identity", function()
    local fd, a = setup()
    T.eq(a.rewrite("https://image.tmdb.org/x.jpg"), "https://image.tmdb.org/x.jpg")
    a:set_enabled(false)
    T.eq(a.rewrite("http://10.0.0.1/x.jpg"), "http://10.0.0.1/x.jpg")
    fd:flush()
    T.eq(#fd.requests, 0)
  end)
  it("oversize (Content-Length or body) and failures are not embedded and retried later only", function()
    local fd, a, ready = setup({ max_bytes = 1000, retry_s = 300 })
    fd:route("big1", { status = 200, body = PNG, headers = { ["Content-Length"] = "5000" } })
    fd:route("big2", { status = 200, body = "\137PNG\r\n\26\n" .. string.rep("z", 2000) })
    fd:route("err", { err = "connection refused" })
    fd:route("404", { status = 404, body = "nope" })
    fd:route("html", { status = 200, body = "<html></html>", headers = { ["Content-Type"] = "text/html" } })
    for _, u in ipairs({ "http://10.0.0.1/big1", "http://10.0.0.1/big2", "http://10.0.0.1/err", "http://10.0.0.1/404", "http://10.0.0.1/html" }) do
      a.rewrite(u)
    end
    fd:flush()
    T.eq(ready(), 0)
    for _, u in ipairs({ "http://10.0.0.1/big1", "http://10.0.0.1/big2", "http://10.0.0.1/err", "http://10.0.0.1/404", "http://10.0.0.1/html" }) do
      T.eq(a.rewrite(u), u)
    end
    fd:flush()
    T.eq(#fd.requests, 5, "no retry inside retry_s")
    T.eq(a.stats.failed, 5)
    fd:advance(301)
    a.rewrite("http://10.0.0.1/err")
    fd:flush()
    T.eq(#fd.requests, 6)
  end)
  it("sniffs when Content-Type is missing/wrong; LRU cap", function()
    local fd, a = setup({ max_entries = 3 })
    fd:route("/img", { status = 200, body = JPG, headers = { ["Content-Type"] = "application/octet-stream" } })
    for i = 1, 5 do a.rewrite("http://10.0.0.1/img" .. i) end
    fd:flush()
    T.eq(a:count(), 3)
    T.contains(a.rewrite("http://10.0.0.1/img5"), "data:image/jpeg;base64,")
  end)
  it("clear() drops cache and ignores in-flight results", function()
    local fd, a, ready = setup()
    fd:route("x.png", { status = 200, body = PNG, delay = 1 })
    a.rewrite("http://10.0.0.1/x.png")
    a:clear()
    fd:advance(2)
    T.eq(ready(), 0); T.eq(a:count(), 0)
  end)
end)
