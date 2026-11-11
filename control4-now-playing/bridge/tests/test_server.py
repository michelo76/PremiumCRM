"""HTTP handler tests with a fake backend (no Apple TV, no pyatv connections)."""

from typing import Dict, List, Optional, Tuple

import pytest
from pyatv.const import DeviceState, MediaType
from pyatv.interface import Playing

from atv_bridge.manager import Artwork
from atv_bridge.mapping import DeviceSummary, Snapshot
from atv_bridge.server import create_app

PNG = b"\x89PNG\r\n\x1a\nfake"


class FakeBackend:
    def __init__(self) -> None:
        self.summaries: List[DeviceSummary] = [
            DeviceSummary(
                "AA:BB:CC:DD:EE:FF",
                "Living Room",
                "192.168.1.20",
                "Apple TV 4K (gen 3)",
                "tvOS 18.1",
                ["airplay", "companion"],
                True,
                ("AA:BB:CC:DD:EE:FF", "1234-uuid"),
            ),
            DeviceSummary("11:22", "Bedroom", "192.168.1.21", None, None, [], False),
        ]
        self.snapshots: Dict[str, Snapshot] = {
            "AA:BB:CC:DD:EE:FF": Snapshot(
                device_name="Living Room",
                online=True,
                playing=Playing(
                    media_type=MediaType.Video,
                    device_state=DeviceState.Playing,
                    title="Film",
                    total_time=7000,
                    position=60,
                ),
                app_name="Netflix",
                app_id="com.netflix.Netflix",
                updated_at=1790000000.0,
                artwork_version="abc123",
            ),
            "11:22": Snapshot(device_name="Bedroom", online=False),
        }
        self.artwork_calls: List[Tuple[str, Optional[str]]] = []

    def devices(self) -> List[DeviceSummary]:
        return self.summaries

    async def snapshot(self, device_id: str) -> Snapshot:
        return self.snapshots[device_id]

    async def artwork(self, device_id: str, version: Optional[str]):
        self.artwork_calls.append((device_id, version))
        if device_id == "AA:BB:CC:DD:EE:FF":
            return "abc123", Artwork(PNG, "image/png")
        return None


@pytest.fixture
def backend() -> FakeBackend:
    return FakeBackend()


@pytest.fixture
async def client(aiohttp_client, backend):
    return await aiohttp_client(create_app(backend))


@pytest.fixture
async def auth_client(aiohttp_client, backend):
    return await aiohttp_client(create_app(backend, token="s3cret"))


async def test_health(client):
    resp = await client.get("/v1/health")
    assert resp.status == 200
    body = await resp.json()
    assert body["status"] == "ok"
    assert body["devices"] == 2 and body["connected"] == 1


async def test_devices(client):
    resp = await client.get("/v1/devices")
    body = await resp.json()
    assert body[0] == {
        "id": "AA:BB:CC:DD:EE:FF",
        "name": "Living Room",
        "address": "192.168.1.20",
        "model": "Apple TV 4K (gen 3)",
        "os": "tvOS 18.1",
        "paired_protocols": ["airplay", "companion"],
        "connected": True,
    }
    assert "aliases" not in body[0]


@pytest.mark.parametrize(
    "key", ["AA:BB:CC:DD:EE:FF", "AA%3ABB%3ACC%3ADD%3AEE%3AFF", "living-room", "1234-uuid"]
)
async def test_now_playing_resolution(client, key):
    resp = await client.get(f"/v1/devices/{key}/now-playing")
    assert resp.status == 200
    body = await resp.json()
    assert body["source"]["app_name"] == "Netflix"
    assert body["playback"]["state"] == "playing"
    assert body["media"]["kind"] == "movie"


async def test_now_playing_artwork_url_uses_host(client):
    resp = await client.get(
        "/v1/devices/living-room/now-playing", headers={"Host": "bridge.lan:8765"}
    )
    body = await resp.json()
    assert (
        body["media"]["artwork_url"]
        == "http://bridge.lan:8765/v1/devices/AA%3ABB%3ACC%3ADD%3AEE%3AFF/artwork?v=abc123"
    )


async def test_now_playing_offline_device(client):
    body = await (await client.get("/v1/devices/bedroom/now-playing")).json()
    assert body["playback"]["state"] == "off"
    assert body["media"]["artwork_url"] is None


async def test_unknown_device_404(client):
    resp = await client.get("/v1/devices/garage/now-playing")
    assert resp.status == 404
    assert (await resp.json())["error"] == "device_not_found"


async def test_ambiguous_slug_409(client, backend):
    backend.summaries.append(
        DeviceSummary("33:44", "Living-Room", None, None, None, [], False)
    )
    resp = await client.get("/v1/devices/living-room/now-playing")
    assert resp.status == 409
    assert (await resp.json())["error"] == "ambiguous_device"


async def test_artwork(client, backend):
    resp = await client.get("/v1/devices/living-room/artwork?v=abc123")
    assert resp.status == 200
    assert resp.content_type == "image/png"
    assert await resp.read() == PNG
    assert "max-age" in resp.headers["Cache-Control"]
    assert backend.artwork_calls == [("AA:BB:CC:DD:EE:FF", "abc123")]

    stale = await client.get("/v1/devices/living-room/artwork?v=old")
    assert stale.headers["Cache-Control"] == "no-cache"


async def test_artwork_missing_404(client):
    resp = await client.get("/v1/devices/bedroom/artwork")
    assert resp.status == 404


async def test_token_required(auth_client):
    assert (await auth_client.get("/v1/devices")).status == 401
    assert (await auth_client.get("/v1/devices?token=wrong")).status == 401
    bad = await auth_client.get("/v1/devices", headers={"Authorization": "Bearer nope"})
    assert bad.status == 401
    assert (await auth_client.get("/v1/devices?token=s3cret")).status == 200
    ok = await auth_client.get("/v1/devices", headers={"Authorization": "Bearer s3cret"})
    assert ok.status == 200
    ok2 = await auth_client.get(
        "/v1/devices/living-room/now-playing",
        headers={"Authorization": "bearer s3cret"},
    )
    assert ok2.status == 200


async def test_health_is_public_with_token(auth_client):
    assert (await auth_client.get("/v1/health")).status == 200


async def test_artwork_url_carries_token_when_auth_enabled(auth_client):
    body = await (
        await auth_client.get("/v1/devices/living-room/now-playing?token=s3cret")
    ).json()
    url = body["media"]["artwork_url"]
    assert url.endswith("/artwork?v=abc123&token=s3cret")
    path = url.split("://", 1)[1].split("/", 1)[1]
    resp = await auth_client.get("/" + path)
    assert resp.status == 200
