"""DeviceHandle state handling with a fake pyatv AppleTV (no network)."""

from pathlib import Path
from types import SimpleNamespace
from typing import Optional

from pyatv import exceptions
from pyatv.const import DeviceState, MediaType, PowerState
from pyatv.interface import App, ArtworkInfo, Playing

from atv_bridge.manager import DeviceHandle, DeviceManager


class FakeMetadata:
    def __init__(self) -> None:
        self.current = Playing(
            media_type=MediaType.Music,
            device_state=DeviceState.Playing,
            title="Song",
            total_time=100,
            position=10,
        )
        self.artwork_id: Optional[str] = "art-1"
        self.fetches = 0

    async def playing(self) -> Playing:
        return self.current

    @property
    def app(self) -> App:
        return App("Music", "com.apple.TVMusic")

    async def artwork(self, width=512, height=None):
        self.fetches += 1
        return ArtworkInfo(b"jpeg-bytes", "image/jpeg", 512, 512)


class FakeFeatures:
    def in_state(self, states, *names) -> bool:
        raise exceptions.NotSupportedError()


def make_handle() -> DeviceHandle:
    config = SimpleNamespace(
        identifier="AA:BB", name="Den", address="10.0.0.5", all_identifiers=["AA:BB"]
    )
    handle = DeviceHandle(DeviceManager(Path("/nonexistent")), config)  # type: ignore[arg-type]
    handle.atv = SimpleNamespace(  # type: ignore[assignment]
        metadata=FakeMetadata(), features=FakeFeatures()
    )
    return handle


async def test_snapshot_reads_metadata_and_app():
    handle = make_handle()
    snap = await handle.snapshot()
    assert snap.online and snap.playing.title == "Song"
    assert (snap.app_name, snap.app_id) == ("Music", "com.apple.TVMusic")
    assert snap.volume is None  # feature check raised -> treated as unknown
    assert snap.updated_at is not None and snap.artwork_version


async def test_power_off_means_offline():
    handle = make_handle()
    handle.powerstate_update(PowerState.On, PowerState.Off)
    assert (await handle.snapshot()).online is False


async def test_disconnected_handle_keeps_name_offline():
    handle = make_handle()
    handle.atv = None
    snap = await handle.snapshot()
    assert snap.online is False and snap.device_name == "Den"
    assert snap.artwork_version is None


async def test_push_update_and_connection_lost():
    handle = make_handle()
    new = Playing(device_state=DeviceState.Paused, title="Other")
    handle.playstatus_update(None, new)
    assert handle.playing is new
    handle.connection_lost(Exception("boom"))
    assert handle._lost.is_set()


async def test_artwork_cached_by_version():
    handle = make_handle()
    version = (await handle.snapshot()).artwork_version
    first = await handle.artwork(version)
    second = await handle.artwork(version)
    assert first is not None and first[0] == version
    assert second == first
    assert handle.atv.metadata.fetches == 1
    handle.atv.metadata.artwork_id = None
    assert await handle.artwork(None) is None
    assert await handle.artwork(version) == first  # old version still in cache
