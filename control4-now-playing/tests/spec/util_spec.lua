local T = ...
local util = require("np.util")

describe("util.clean_title", function()
  local cases = {
    { "Inception (2010)", "Inception" },
    { "Top Gun: Maverick [4K]", "Top Gun: Maverick" },
    { "The Bear S02E07 Forks", "The Bear" },
    { "The Office - Season 2 Episode 7 - The Client", "The Office" },
    { "Inception.2010.1080p.BluRay.x264-SPARKS.mkv", "Inception" },
    { "Blade.Runner.2049.2017.2160p.UHD.BluRay.x265", "Blade Runner 2049" },
    { "Blinding Lights (Official Video)", "Blinding Lights" },
    { "Bohemian Rhapsody - Remastered 2011", "Bohemian Rhapsody" },
    { "The Weeknd - Topic", "The Weeknd" },
    { "Save Your Tears (feat. Ariana Grande)", "Save Your Tears" },
    { "Stay (Lyric Video)", "Stay" },
    { "Song Name - Official Music Video", "Song Name" },
    { "Friends 2x07 The One with the Race Car Bed", "Friends" },
    { "Dune: Part Two (2024) [HDR] [Dolby Vision]", "Dune: Part Two" },
    { "(500) Days of Summer", "(500) Days of Summer" },
    { "  ", nil },
  }
  for _, c in ipairs(cases) do
    it("cleans " .. c[1], function() T.eq(util.clean_title(c[1]), c[2]) end)
  end
end)

describe("util.parse_episode", function()
  it("parses SxxEyy with series and episode title", function()
    local p = util.parse_episode("The Bear S02E07 Forks")
    T.eq(p.season, 2); T.eq(p.episode, 7); T.eq(p.series, "The Bear"); T.eq(p.episode_title, "Forks")
  end)
  it("parses lowercase s2e7 and separators", function()
    local p = util.parse_episode("the.bear.s2e7.forks.1080p.web.h264")
    T.eq(p.season, 2); T.eq(p.episode, 7); T.eq(p.series, "the bear"); T.eq(p.episode_title, "forks")
  end)
  it("parses Season N Episode M", function()
    local p = util.parse_episode("The Office - Season 2, Episode 7 - The Client")
    T.eq(p.season, 2); T.eq(p.episode, 7); T.eq(p.series, "The Office"); T.eq(p.episode_title, "The Client")
  end)
  it("parses 2x07", function()
    local p = util.parse_episode("Friends 2x07 The One with the Race Car Bed")
    T.eq(p.season, 2); T.eq(p.episode, 7); T.eq(p.series, "Friends")
  end)
  it("does not treat resolutions as episodes", function()
    T.is_nil(util.parse_episode("Video 1920x1080 sample"))
    T.is_nil(util.parse_episode("Inception"))
    T.is_nil(util.parse_episode(nil))
  end)
end)

describe("util.extract_year", function()
  it("finds bracketed and filename years", function()
    T.eq(util.extract_year("Inception (2010)"), 2010)
    T.eq(util.extract_year("Blade.Runner.2049.2017.1080p"), 2017)
    T.is_nil(util.extract_year("Blade Runner 2049"))
  end)
end)

describe("util.similarity", function()
  it("is 1 for punctuation/case/article differences", function()
    T.eq(util.similarity("Top Gun: Maverick", "top gun maverick"), 1)
    T.eq(util.similarity("The Bear", "Bear"), 1)
    T.eq(util.similarity("Beyoncé", "Beyonce"), 1)
    T.eq(util.similarity("Law & Order", "Law and Order"), 1)
  end)
  it("ranks related titles in between", function()
    local s = util.similarity("The Office", "The Office (US)")
    T.gt(s, 0.7); T.lt(s, 1)
    T.lt(util.similarity("Top Gun", "Top Gun: Maverick"), 0.8)
    T.lt(util.similarity("The Bear", "Bear Grylls: Breaking Point"), 0.6)
    T.lt(util.similarity("Inception", "Interstellar"), 0.6)
  end)
  it("handles empties", function()
    T.eq(util.similarity("", "x"), 0)
    T.eq(util.similarity(nil, nil), 0)
  end)
  it("levenshtein basics", function()
    T.eq(util.levenshtein("kitten", "sitting"), 3)
    T.eq(util.levenshtein("", "abc"), 3)
  end)
end)

describe("util url helpers", function()
  it("encodes RFC3986", function()
    T.eq(util.urlencode("Top Gun: Maverick & co/é"), "Top%20Gun%3A%20Maverick%20%26%20co%2F%C3%A9")
  end)
  it("builds sorted queries skipping nil", function()
    T.eq(util.query({ b = 2, a = "x y", c = nil }), "a=x%20y&b=2")
    T.eq(util.url("http://h/p", { q = 1 }), "http://h/p?q=1")
    T.eq(util.url("http://h/p?x=1", { q = 1 }), "http://h/p?x=1&q=1")
    T.eq(util.url("http://h/p", {}), "http://h/p")
  end)
end)

describe("util xml", function()
  it("parses Roku active-app with attributes and entities", function()
    local root = assert(util.xml_parse(T.fixture("roku_active_app_netflix.xml")))
    local app = util.xml_child(util.xml_find(root, "active-app"), "app")
    T.eq(app.attrs.id, "12"); T.eq(util.xml_text(app), "Netflix")
  end)
  it("handles self-closing tags, entities, comments, CDATA", function()
    local root = assert(util.xml_parse('<?xml version="1.0"?><!-- c --><a x=\'1\'><b/><c>A &amp; B &#233;</c><d><![CDATA[<raw>]]></d></a>'))
    local a = util.xml_find(root, "a")
    T.eq(a.attrs.x, "1"); T.ok(util.xml_child(a, "b"))
    T.eq(util.xml_text(a, "c"), "A & B é"); T.eq(util.xml_text(a, "d"), "<raw>")
  end)
  it("rejects malformed xml", function()
    local r, err = util.xml_parse("<a><b></a>")
    T.is_nil(r); T.contains(err, "mismatched")
    r, err = util.xml_parse("<a>")
    T.is_nil(r); T.ok(err)
  end)
end)

describe("util time", function()
  it("parses ISO8601 variants", function()
    T.eq(util.iso8601_to_epoch("2026-09-21T14:13:20Z"), 1790000000)
    T.eq(util.iso8601_to_epoch("2026-09-21T14:13:20+00:00"), 1790000000)
    T.near(util.iso8601_to_epoch("2026-09-21T14:13:20.250000+00:00"), 1790000000.25, 1e-6)
    T.eq(util.iso8601_to_epoch("2026-09-21T10:13:20-04:00"), 1790000000)
    T.eq(util.iso8601_to_epoch("2026-09-21T14:13Z"), 1790000000 - 20)
    T.eq(util.iso8601_to_epoch("1970-01-01"), 0)
    T.is_nil(util.iso8601_to_epoch("yesterday"))
    T.is_nil(util.iso8601_to_epoch(nil))
  end)
  it("formats epoch as ISO", function()
    T.eq(util.epoch_to_iso(1790000000), "2026-09-21T14:13:20Z")
    T.eq(util.epoch_to_iso(1790000000, false), "2026-09-21T14:13Z")
    T.eq(util.epoch_to_iso(951782400), "2000-02-29T00:00:00Z")
  end)
end)

describe("util misc", function()
  it("formats money", function()
    T.eq(util.format_money(165000000), "$165M")
    T.eq(util.format_money(1488732821), "$1.49B")
    T.eq(util.format_money(2000000000), "$2B")
    T.eq(util.format_money(2500000), "$2.5M")
    T.eq(util.format_money(12345), "$12,345")
    T.is_nil(util.format_money(0))
  end)
  it("truncates without splitting UTF-8", function()
    T.eq(util.truncate("abcdef", 10), "abcdef")
    T.eq(util.truncate("abcdef", 3), "abc…")
    T.eq(util.truncate("aé", 2), "a…")
  end)
  it("deep_equal / deep_copy", function()
    local a = { x = { 1, 2, { y = "z" } } }
    local b = util.deep_copy(a)
    T.ok(util.deep_equal(a, b)); T.ok(a.x ~= b.x)
    b.x[3].y = "w"
    T.no(util.deep_equal(a, b))
    T.no(util.deep_equal({ a = 1 }, { a = 1, b = 2 }))
  end)
  it("hash is stable", function()
    T.eq(util.hash("abc"), util.hash("abc")); T.neq(util.hash("abc"), util.hash("abd"))
  end)
end)
