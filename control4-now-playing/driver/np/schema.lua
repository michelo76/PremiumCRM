--[[
np.schema -- the published state document (schema 1) and its strict JSON encoder.

The engine keeps the state as plain Lua tables where "absent" is simply nil. Lua cannot
store nil, so the encoder walks this schema description and:
  * emits every declared key in the declared order (stable output -> stable ETags),
  * writes absent scalars as null, absent arrays as [], absent non-nullable objects as an
    object full of nulls and absent nullable objects as null,
  * drops any key that is not declared (the document has EXACTLY the documented shape).

  schema.encode_state(state) -> json string
  schema.shape(state)        -> the json-ready table (ordered, json.null placeholders)
  schema.STATE / schema.DETAILS -> the shape descriptions
It always uses np.json (the glue may give deps.json a different implementation, which
would not understand the array/ordering marks).
]]

local json = require("np.json")

local M = {}

-- descriptors
local function S() return { t = "scalar" } end
local function A(item) return { t = "array", item = item } end
local function O(fields, nullable) return { t = "object", fields = fields, nullable = nullable } end
-- fields: ordered list of { name, descriptor }

local person = O({ { "name", S() }, { "character", S() }, { "photo_url", S() } })

M.DETAILS = O({
  { "matched", S() }, { "confidence", S() }, { "tagline", S() }, { "overview", S() },
  { "release_date", S() }, { "year", S() }, { "runtime_min", S() }, { "content_rating", S() },
  { "genres", A(S()) }, { "status", S() },
  { "poster_url", S() }, { "backdrop_url", S() }, { "logo_url", S() },
  { "ratings", O({
    { "imdb", O({ { "score", S() }, { "votes", S() } }, true) },
    { "rotten_tomatoes", S() }, { "metacritic", S() }, { "tmdb", S() },
  }) },
  { "cast", A(person) },
  { "crew", O({ { "directors", A(S()) }, { "writers", A(S()) }, { "creators", A(S()) } }) },
  { "networks", A(S()) }, { "studios", A(S()) }, { "trailer_url", S() },
  { "episode", O({ { "title", S() }, { "overview", S() }, { "air_date", S() }, { "still_url", S() },
    { "runtime_min", S() }, { "rating", S() } }, true) },
  { "series", O({ { "seasons", S() }, { "episodes", S() }, { "first_air_date", S() },
    { "next_episode", O({ { "season", S() }, { "episode", S() }, { "air_date", S() }, { "title", S() } }, true) },
  }, true) },
  { "music", O({ { "artist_bio", S() }, { "artist_image_url", S() }, { "album_year", S() }, { "label", S() },
    { "album_tracks", A(O({ { "n", S() }, { "title", S() }, { "duration_s", S() } })) },
    { "track_genre", S() } }, true) },
  { "live", O({ { "program_title", S() }, { "program_start", S() }, { "program_end", S() },
    { "next", O({ { "title", S() }, { "start", S() } }, true) } }, true) },
  { "facts", A(O({ { "label", S() }, { "value", S() } })) },
  { "ids", O({ { "imdb", S() }, { "tmdb", S() }, { "musicbrainz", S() }, { "tms", S() } }) },
  { "links", O({ { "imdb", S() } }) },
  { "attribution", A(S()) },
}, true)

M.STATE = O({
  { "schema", S() }, { "version", S() }, { "updated_at", S() }, { "media_key", S() },
  { "room", O({ { "id", S() }, { "name", S() } }) },
  { "source", O({ { "provider", S() }, { "device_name", S() }, { "app_name", S() }, { "app_id", S() },
    { "app_icon_url", S() } }) },
  { "playback", O({ { "state", S() }, { "position_s", S() }, { "duration_s", S() },
    { "position_updated_at", S() }, { "is_live", S() }, { "volume", S() } }) },
  { "media", O({ { "kind", S() }, { "title", S() }, { "subtitle", S() }, { "series_title", S() },
    { "season", S() }, { "episode", S() }, { "episode_title", S() }, { "artist", S() }, { "album", S() },
    { "album_artist", S() }, { "track_number", S() }, { "channel_name", S() }, { "channel_number", S() },
    { "year", S() }, { "genres", A(S()) }, { "artwork_url", S() } }) },
  { "details", M.DETAILS },
})

local shape

local function shape_scalar(v)
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then return v end
  return json.null
end

shape = function(desc, v)
  if desc.t == "scalar" then
    return shape_scalar(v)
  elseif desc.t == "array" then
    local out = json.array({})
    if type(v) == "table" then
      for i = 1, #v do out[#out + 1] = shape(desc.item, v[i]) end
    end
    return out
  else
    if type(v) ~= "table" then
      if desc.nullable then return json.null end
      v = {}
    end
    local keys, out = {}, {}
    for i, f in ipairs(desc.fields) do
      keys[i] = f[1]
      out[f[1]] = shape(f[2], v[f[1]])
    end
    return json.ordered(out, keys)
  end
end

function M.shape(state, desc)
  return shape(desc or M.STATE, state)
end

function M.encode_state(state)
  return json.encode(shape(M.STATE, state))
end

function M.encode_details(details)
  return json.encode(shape(M.DETAILS, details))
end

return M
