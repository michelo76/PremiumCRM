local T = ...
local FakeDeps = require("fake_deps")
local Multi = require("np.providers.multi")
local pbm = require("np.playback")

-- scripted provider: result can be changed between polls
local function scripted(id, group)
  local p = { id = id, group = group, kind = "scripted", polls = 0 }
  p.result = { state = "idle" }
  function p:poll(cb)
    self.polls = self.polls + 1
    if self.result.err then return cb(self.result.err) end
    local pb = pbm.normalize({ source = { provider = id }, playback = { state = self.result.state },
      media = self.result.media or {} }, 0)
    cb(nil, pb)
  end
  return p
end

local function poll(fd, m)
  local r = {}
  m:poll(function(err, pb, info) r.err, r.pb, r.info = err, pb, info end)
  fd:flush()
  return r
end

describe("np.providers.multi", function()
  local fd, a, b, m
  before_each(function()
    fd = FakeDeps.new()
    a, b = scripted("a"), scripted("b")
    m = Multi.new({ a, b }, { sticky_s = 10 }, fd.deps)
  end)

  it("prefers playing > buffering > paused > idle; ties by list order", function()
    a.result = { state = "idle" }; b.result = { state = "playing" }
    T.eq(poll(fd, m).info.active_id, "b")
    local m2 = Multi.new({ scripted("x"), scripted("y") }, {}, fd.deps)
    T.eq(poll(fd, m2).info.active_id, "x")
    local p1, p2 = scripted("p1"), scripted("p2")
    p1.result = { state = "paused" }; p2.result = { state = "buffering" }
    T.eq(poll(fd, Multi.new({ p1, p2 }, {}, fd.deps)).info.active_id, "p2")
  end)

  it("is sticky: a briefly paused active provider is kept", function()
    a.result = { state = "playing" }; b.result = { state = "idle" }
    T.eq(poll(fd, m).info.active_id, "a")
    fd:advance(2)
    a.result = { state = "paused" }; b.result = { state = "playing" }
    T.eq(poll(fd, m).info.active_id, "a", "within sticky window")
    fd:advance(5)
    T.eq(poll(fd, m).info.active_id, "a")
    fd:advance(6)
    T.eq(poll(fd, m).info.active_id, "b", "after sticky window")
  end)

  it("switches immediately when the active provider goes idle/off", function()
    a.result = { state = "playing" }
    poll(fd, m)
    fd:advance(1)
    a.result = { state = "off" }; b.result = { state = "playing" }
    T.eq(poll(fd, m).info.active_id, "b")
  end)

  it("keeps the active provider on equal rank (no flapping)", function()
    a.result = { state = "playing" }; b.result = { state = "idle" }
    poll(fd, m)
    fd:advance(20)
    a.result = { state = "idle" }; b.result = { state = "playing" }
    T.eq(poll(fd, m).info.active_id, "b")
    fd:advance(20)
    a.result = { state = "playing" }; b.result = { state = "playing" }
    T.eq(poll(fd, m).info.active_id, "b")
  end)

  it("backs off a failing provider exponentially and reuses its last result briefly", function()
    a.result = { state = "playing" }
    poll(fd, m)
    a.result = { err = "boom" }
    fd:advance(2)
    local r = poll(fd, m)
    T.eq(r.info.active_id, "a", "stale result still used")
    T.eq(a.polls, 2)
    fd:advance(1); poll(fd, m)
    T.eq(a.polls, 2, "in backoff (2s)")
    fd:advance(1.5); poll(fd, m)
    T.eq(a.polls, 3)
    fd:advance(2); poll(fd, m)
    T.eq(a.polls, 3, "backoff doubled to 4s")
    fd:advance(10)
    r = poll(fd, m)
    T.eq(r.info.active_id, "b", "stale result expired")
    T.ok(fd:has_log("warn", "provider a failed"))
    local st = m:status()
    T.eq(st[1].ok, false); T.contains(st[1].last_error, "boom")
    a.result = { state = "playing" }
    fd:advance(60); poll(fd, m)
    T.ok(fd:has_log("info", "recovered"))
  end)

  it("errors when no provider is available", function()
    a.result = { err = "x" }; b.result = { err = "y" }
    local r = poll(fd, m)
    T.contains(r.err, "no provider available"); T.contains(r.err, "a: x")
  end)

  it("survives a crashing provider", function()
    local bad = { id = "bad", poll = function() error("kaboom") end }
    local good = scripted("good"); good.result = { state = "playing" }
    local r = poll(fd, Multi.new({ bad, good }, {}, fd.deps))
    T.eq(r.info.active_id, "good"); T.contains(r.info.errors.bad, "kaboom")
  end)

  it("merges missing title from the same physical device group", function()
    local roku, ha, other = scripted("roku", "lr"), scripted("ha", "lr"), scripted("kitchen", "k")
    roku.result = { state = "playing", media = { kind = "video" } }
    ha.result = { state = "playing", media = { kind = "episode", title = "Forks", series_title = "The Bear", season = 2, episode = 7 } }
    other.result = { state = "paused", media = { title = "Other" } }
    local r = poll(fd, Multi.new({ roku, ha, other }, {}, fd.deps))
    T.eq(r.info.active_id, "roku"); T.eq(r.info.merged_from, "ha")
    T.eq(r.pb.media.title, "Forks"); T.eq(r.pb.media.kind, "episode"); T.eq(r.pb.media.season, 2)
    T.eq(r.pb.source.provider, "roku")
  end)

  it("does not merge across groups or from idle donors", function()
    local roku, ha = scripted("roku", "lr"), scripted("ha", "lr")
    roku.result = { state = "playing", media = { kind = "video" } }
    ha.result = { state = "idle", media = { title = "Old" } }
    local r = poll(fd, Multi.new({ roku, ha }, {}, fd.deps))
    T.is_nil(r.pb.media.title)
    local x, y = scripted("x", "g1"), scripted("y", "g2")
    x.result = { state = "playing" }; y.result = { state = "playing", media = { title = "T" } }
    r = poll(fd, Multi.new({ x, y }, {}, fd.deps))
    T.is_nil(r.pb.media.title)
  end)

  it("never overlaps a provider poll that is still in flight", function()
    local slow = { id = "slow", n = 0 }
    local pending
    function slow:poll(cb) self.n = self.n + 1; pending = cb end
    local mm = Multi.new({ slow }, {}, fd.deps)
    mm:poll(function() end)
    mm:poll(function() end)
    T.eq(slow.n, 1)
    pending(nil, pbm.normalize({ playback = { state = "playing" } }, 0))
  end)
end)
