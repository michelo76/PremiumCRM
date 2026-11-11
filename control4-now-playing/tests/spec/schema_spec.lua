local T = ...
local schema = require("np.schema")
local json = require("np.json")

describe("np.schema", function()
  it("emits nulls for absent scalars and [] for absent arrays, exact key order", function()
    local s = schema.encode_state({ schema = 1, version = 3, updated_at = 1790000000, media_key = "k",
      room = { id = 12, name = "Family Room" }, source = { provider = "roku" },
      playback = { state = "idle", is_live = false }, media = { kind = "unknown", genres = {} } })
    T.eq(s:sub(1, 71), '{"schema":1,"version":3,"updated_at":1790000000,"media_key":"k","room":')
    T.contains(s, '"source":{"provider":"roku","device_name":null,"app_name":null,"app_id":null,"app_icon_url":null}')
    T.contains(s, '"playback":{"state":"idle","position_s":null,"duration_s":null,"position_updated_at":null,"is_live":false,"volume":null}')
    T.contains(s, '"genres":[]'); T.contains(s, '"details":null}')
    local v = json.decode(s)
    T.eq(v.media.kind, "unknown")
  end)
  it("details: nullable blocks null, arrays [], unknown keys dropped", function()
    local s = schema.encode_details({ matched = true, confidence = 0.9, extra_junk = "x", ratings = { tmdb = 8 },
      cast = { { name = "A", secret = 1 } }, music = { label = "XO" } })
    T.no(s:find("extra_junk")); T.no(s:find("secret"))
    T.contains(s, '"ratings":{"imdb":null,"rotten_tomatoes":null,"metacritic":null,"tmdb":8}')
    T.contains(s, '"cast":[{"name":"A","character":null,"photo_url":null}]')
    T.contains(s, '"crew":{"directors":[],"writers":[],"creators":[]}')
    T.contains(s, '"episode":null'); T.contains(s, '"series":null'); T.contains(s, '"live":null')
    T.contains(s, '"music":{"artist_bio":null,"artist_image_url":null,"album_year":null,"label":"XO","album_tracks":[],"track_genre":null}')
    T.contains(s, '"facts":[]'); T.contains(s, '"ids":{"imdb":null,"tmdb":null,"musicbrainz":null,"tms":null}')
    T.contains(s, '"links":{"imdb":null}'); T.contains(s, '"attribution":[]')
  end)
end)
