"""Bridge <-> Lua contract: the documents map_now_playing() produces for representative
devices are checked into ../tests/fixtures/bridge_contract.json, which the Lua side
(tests/spec/bridge_contract_spec.lua) runs through np.providers.bridge field by field.

This test fails when the mapping output drifts from the fixture. Regenerate with
    NP_REGEN_CONTRACT=1 python -m pytest tests/test_contract_fixture.py
and re-run the Lua specs.
"""

import json
import os
from pathlib import Path

from pyatv.const import DeviceState, MediaType
from pyatv.interface import Playing

from atv_bridge.mapping import Snapshot, map_now_playing

FIXTURE = Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "bridge_contract.json"
ART = "http://192.168.1.10:8765/v1/devices/AA%3ABB/artwork?v=0123456789abcdef"


def snap(playing=None, online=True, **kw):
    kw.setdefault("updated_at", 1790000000.7)
    kw.setdefault("app_name", "TV")
    kw.setdefault("app_id", "com.apple.TVWatchList")
    kw.setdefault("volume", 37.5)
    return Snapshot(device_name="Den Apple TV", online=online, playing=playing, **kw)


def documents():
    return {
        "movie": map_now_playing(
            snap(Playing(media_type=MediaType.Video, device_state=DeviceState.Playing, title="Dune: Part Two",
                         genre="Science Fiction", total_time=9960, position=1234.5)),
            ART,
        ),
        "episode": map_now_playing(
            snap(Playing(media_type=MediaType.Video, device_state=DeviceState.Paused, title="Forks",
                         series_name="The Bear", season_number=2, episode_number=7, total_time=2460, position=600)),
            ART,
        ),
        "music": map_now_playing(
            snap(Playing(media_type=MediaType.Music, device_state=DeviceState.Playing, title="Dreams",
                         artist="Fleetwood Mac", album="Rumours", genre="Rock", total_time=257, position=42),
                 app_name="Music", app_id="com.apple.TVMusic"),
            ART,
        ),
        "live": map_now_playing(
            snap(Playing(media_type=MediaType.Video, device_state=DeviceState.Playing, title="Evening News",
                         total_time=0, position=0)),
            None,
        ),
        "idle": map_now_playing(snap(None)),
        "off": map_now_playing(snap(Playing(title="X"), online=False), ART),
    }


def test_contract_fixture_matches_mapping():
    docs = documents()
    text = json.dumps(docs, indent=1, sort_keys=True) + "\n"
    if os.environ.get("NP_REGEN_CONTRACT"):
        FIXTURE.write_text(text, encoding="utf-8")
    assert FIXTURE.exists(), "run with NP_REGEN_CONTRACT=1 to create " + str(FIXTURE)
    assert json.loads(FIXTURE.read_text(encoding="utf-8")) == json.loads(text), (
        "bridge mapping drifted from tests/fixtures/bridge_contract.json; regenerate it "
        "(NP_REGEN_CONTRACT=1) and run the Lua bridge_contract spec"
    )
