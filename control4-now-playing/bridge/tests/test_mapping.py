"""Pure mapping tests: pyatv Playing -> Control4 contract."""

from typing import Any, Dict

import pytest
from pyatv.const import DeviceState, MediaType
from pyatv.interface import Playing

from atv_bridge.mapping import (
    AmbiguousDeviceError,
    DeviceSummary,
    Snapshot,
    artwork_version,
    map_now_playing,
    resolve_device,
    slugify,
)

CONTRACT_KEYS = {
    "source": {"provider", "device_name", "app_name", "app_id", "app_icon_url"},
    "playback": {
        "state",
        "position_s",
        "duration_s",
        "position_updated_at",
        "is_live",
        "volume",
    },
    "media": {
        "kind",
        "title",
        "subtitle",
        "series_title",
        "season",
        "episode",
        "episode_title",
        "artist",
        "album",
        "album_artist",
        "track_number",
        "channel_name",
        "channel_number",
        "year",
        "genres",
        "artwork_url",
    },
}


def assert_contract(doc: Dict[str, Any]) -> None:
    assert set(doc) == set(CONTRACT_KEYS)
    for section, keys in CONTRACT_KEYS.items():
        assert set(doc[section]) == keys, section
    assert isinstance(doc["media"]["genres"], list)
    assert doc["source"]["provider"] == "appletv"


def snap(playing=None, online=True, **kw) -> Snapshot:
    kw.setdefault("updated_at", 1790000000.7)
    return Snapshot(device_name="Living Room", online=online, playing=playing, **kw)


def test_offline_is_off_with_all_keys_null():
    doc = map_now_playing(
        snap(Playing(title="X", device_state=DeviceState.Playing), online=False),
        artwork_url="http://x/a",
    )
    assert_contract(doc)
    assert doc["playback"]["state"] == "off"
    assert doc["media"]["kind"] == "unknown"
    assert doc["media"]["title"] is None
    assert doc["media"]["artwork_url"] is None
    assert doc["source"]["app_name"] is None
    assert doc["playback"]["position_updated_at"] is None
    assert doc["source"]["device_name"] == "Living Room"


def test_connected_without_playing_is_idle():
    doc = map_now_playing(snap(None))
    assert_contract(doc)
    assert doc["playback"]["state"] == "idle"
    assert doc["playback"]["is_live"] is None
    assert doc["media"]["genres"] == []


@pytest.mark.parametrize(
    "state,expected",
    [
        (DeviceState.Idle, "idle"),
        (DeviceState.Loading, "buffering"),
        (DeviceState.Paused, "paused"),
        (DeviceState.Playing, "playing"),
        (DeviceState.Stopped, "stopped"),
        (DeviceState.Seeking, "buffering"),
    ],
)
def test_device_state_mapping(state, expected):
    doc = map_now_playing(snap(Playing(device_state=state)))
    assert doc["playback"]["state"] == expected


def test_music():
    p = Playing(
        media_type=MediaType.Music,
        device_state=DeviceState.Playing,
        title="Song",
        artist="Band",
        album="Record",
        genre="Rock",
        total_time=200,
        position=42,
    )
    doc = map_now_playing(
        snap(p, app_name="Music", app_id="com.apple.TVMusic", volume=37.123),
        artwork_url="http://h/art",
    )
    assert_contract(doc)
    m, pb = doc["media"], doc["playback"]
    assert m["kind"] == "music"
    assert (m["title"], m["artist"], m["album"], m["subtitle"]) == (
        "Song",
        "Band",
        "Record",
        "Band",
    )
    assert m["genres"] == ["Rock"]
    assert m["artwork_url"] == "http://h/art"
    assert pb == {
        "state": "playing",
        "position_s": 42.0,
        "duration_s": 200.0,
        "position_updated_at": 1790000000,
        "is_live": False,
        "volume": 37.1,
    }
    assert doc["source"]["app_id"] == "com.apple.TVMusic"


def test_video_with_series_info_is_episode():
    p = Playing(
        media_type=MediaType.Video,
        device_state=DeviceState.Paused,
        title="The One Where",
        series_name="Friends",
        season_number=2,
        episode_number=7,
        total_time=1320,
        position=100,
    )
    m = map_now_playing(snap(p))["media"]
    assert m["kind"] == "episode"
    assert m["series_title"] == "Friends"
    assert (m["season"], m["episode"]) == (2, 7)
    assert m["episode_title"] == "The One Where"
    assert m["subtitle"] == "Friends · S2E7"


def test_tv_type_without_series_is_video():
    p = Playing(media_type=MediaType.TV, title="Clip", total_time=300)
    assert map_now_playing(snap(p))["media"]["kind"] == "video"


def test_tv_type_with_series_is_episode():
    p = Playing(media_type=MediaType.TV, title="Ep", series_name="Show")
    assert map_now_playing(snap(p))["media"]["kind"] == "episode"


def test_long_video_is_movie_short_is_video():
    long_p = Playing(media_type=MediaType.Video, title="Film", total_time=7200)
    short_p = Playing(media_type=MediaType.Video, title="Trailer", total_time=150)
    exactly_hour = Playing(media_type=MediaType.Video, title="Doc", total_time=3600)
    assert map_now_playing(snap(long_p))["media"]["kind"] == "movie"
    assert map_now_playing(snap(short_p))["media"]["kind"] == "video"
    assert map_now_playing(snap(exactly_hour))["media"]["kind"] == "video"
    assert map_now_playing(snap(long_p))["media"]["episode_title"] is None


def test_live_heuristic_video_without_duration():
    p = Playing(
        media_type=MediaType.Video,
        device_state=DeviceState.Playing,
        title="Evening News",
        total_time=0,
        position=12,
    )
    doc = map_now_playing(snap(p))
    assert doc["playback"]["is_live"] is True
    assert doc["playback"]["duration_s"] is None
    assert doc["media"]["kind"] == "live_tv"


def test_live_music_stream_stays_music():
    p = Playing(media_type=MediaType.Music, device_state=DeviceState.Playing, title="Radio")
    doc = map_now_playing(snap(p))
    assert doc["media"]["kind"] == "music"
    assert doc["playback"]["is_live"] is True


def test_drm_app_transport_only():
    """Some apps publish only transport state: no title, no duration."""
    p = Playing(media_type=MediaType.Unknown, device_state=DeviceState.Playing)
    doc = map_now_playing(snap(p, app_name="Some App", app_id="com.x"))
    assert_contract(doc)
    assert doc["playback"]["state"] == "playing"
    assert doc["playback"]["is_live"] is None
    assert doc["media"]["kind"] == "unknown"
    assert doc["media"]["title"] is None
    assert doc["source"]["app_name"] == "Some App"


def test_unknown_media_type_is_unknown():
    p = Playing(media_type=MediaType.Unknown, title="Thing", total_time=9000)
    assert map_now_playing(snap(p))["media"]["kind"] == "unknown"


def test_blank_strings_become_null():
    p = Playing(media_type=MediaType.Music, title="  ", artist="", genre=" ")
    m = map_now_playing(snap(p))["media"]
    assert m["title"] is None and m["artist"] is None and m["genres"] == []


def test_missing_position_has_no_timestamp():
    p = Playing(media_type=MediaType.Video, device_state=DeviceState.Playing, title="t")
    pb = map_now_playing(snap(p))["playback"]
    assert pb["position_s"] is None and pb["position_updated_at"] is None


def test_slugify():
    assert slugify("Living Room") == "living-room"
    assert slugify("  Kid's Room (2) ") == "kid-s-room-2"
    assert slugify("Salón Café") == "salon-cafe"
    assert slugify("!!!") == "device"


def _dev(id_, name, aliases=()):
    return DeviceSummary(id_, name, "10.0.0.2", None, None, [], True, aliases)


def test_resolve_by_id_alias_and_slug():
    devs = [
        _dev("AA:BB", "Living Room", aliases=("AA:BB", "uuid-1")),
        _dev("CC:DD", "Bedroom"),
    ]
    assert resolve_device(devs, "AA:BB").id == "AA:BB"
    assert resolve_device(devs, "aa:bb").id == "AA:BB"
    assert resolve_device(devs, "uuid-1").id == "AA:BB"
    assert resolve_device(devs, "living-room").id == "AA:BB"
    assert resolve_device(devs, "Living Room").id == "AA:BB"
    assert resolve_device(devs, "bedroom").id == "CC:DD"
    assert resolve_device(devs, "garage") is None


def test_resolve_ambiguous_slug():
    devs = [_dev("1", "Den"), _dev("2", "den")]
    assert resolve_device(devs, "1").id == "1"
    with pytest.raises(AmbiguousDeviceError):
        resolve_device(devs, "den")


def test_artwork_version_stable_and_urlsafe():
    v = artwork_version("some/artwork:id")
    assert v == artwork_version("some/artwork:id")
    assert v.isalnum() and len(v) == 16
    assert artwork_version(None) is None
    assert artwork_version("") is None
