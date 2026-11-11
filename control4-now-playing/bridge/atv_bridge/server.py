"""aiohttp HTTP API exposing the now-playing contract."""

from __future__ import annotations

import hmac
import logging
import time
from typing import Awaitable, Callable, List, Optional, Protocol, Tuple
from urllib.parse import quote, urlencode

from aiohttp import web
from aiohttp.abc import AbstractAccessLogger

from atv_bridge import __version__
from atv_bridge.manager import Artwork
from atv_bridge.mapping import (
    AmbiguousDeviceError,
    DeviceSummary,
    Snapshot,
    map_now_playing,
    resolve_device,
)

_LOGGER = logging.getLogger(__name__)

Handler = Callable[[web.Request], Awaitable[web.StreamResponse]]


class Backend(Protocol):
    """What the server needs from the device manager (faked in tests)."""

    def devices(self) -> List[DeviceSummary]: ...

    async def snapshot(self, device_id: str) -> Snapshot: ...

    async def artwork(
        self, device_id: str, version: Optional[str]
    ) -> Optional[Tuple[str, Artwork]]: ...


BACKEND_KEY: "web.AppKey[Backend]" = web.AppKey("backend")
TOKEN_KEY: "web.AppKey[Optional[str]]" = web.AppKey("token")
STARTED_KEY: "web.AppKey[float]" = web.AppKey("started")
PUBLIC_PATHS = {"/v1/health"}


class RedactingAccessLogger(AbstractAccessLogger):
    """Access log without query strings (they may carry ?token=)."""

    def log(self, request, response, time):  # type: ignore[override]
        self.logger.debug(
            "%s %s %s -> %s (%.1f ms)",
            request.remote,
            request.method,
            request.path,
            response.status,
            time * 1000,
        )


def _error(status: int, code: str, message: str) -> web.Response:
    return web.json_response({"error": code, "message": message}, status=status)


def _presented_token(request: web.Request) -> Optional[str]:
    header = request.headers.get("Authorization", "")
    if header[:7].lower() == "bearer ":
        return header[7:].strip()
    return request.query.get("token")


@web.middleware
async def auth_middleware(request: web.Request, handler: Handler) -> web.StreamResponse:
    expected = request.app[TOKEN_KEY]
    if expected and request.path not in PUBLIC_PATHS:
        presented = _presented_token(request) or ""
        if not hmac.compare_digest(presented.encode(), expected.encode()):
            return _error(401, "unauthorized", "missing or invalid token")
    return await handler(request)


def _resolve(request: web.Request) -> DeviceSummary:
    key = request.match_info["id"]
    try:
        device = resolve_device(request.app[BACKEND_KEY].devices(), key)
    except AmbiguousDeviceError:
        raise web.HTTPConflict(
            text='{"error":"ambiguous_device","message":"name matches several '
            'devices; use the device id"}',
            content_type="application/json",
        ) from None
    if device is None:
        raise web.HTTPNotFound(
            text='{"error":"device_not_found","message":"unknown device"}',
            content_type="application/json",
        )
    return device


def artwork_url(request: web.Request, device_id: str, version: str) -> str:
    params = {"v": version}
    token = request.app[TOKEN_KEY]
    if token:
        # Control4 navigators fetch images directly and cannot send headers.
        params["token"] = token
    base = f"{request.scheme}://{request.host}"
    return f"{base}/v1/devices/{quote(device_id, safe='')}/artwork?{urlencode(params)}"


async def health(request: web.Request) -> web.Response:
    devices = request.app[BACKEND_KEY].devices()
    return web.json_response(
        {
            "status": "ok",
            "version": __version__,
            "uptime_s": int(time.time() - request.app[STARTED_KEY]),
            "devices": len(devices),
            "connected": sum(1 for d in devices if d.connected),
        }
    )


async def list_devices(request: web.Request) -> web.Response:
    devices = request.app[BACKEND_KEY].devices()
    return web.json_response([d.to_json() for d in devices])


async def now_playing(request: web.Request) -> web.Response:
    device = _resolve(request)
    snapshot = await request.app[BACKEND_KEY].snapshot(device.id)
    art = (
        artwork_url(request, device.id, snapshot.artwork_version)
        if snapshot.artwork_version
        else None
    )
    return web.json_response(map_now_playing(snapshot, art))


async def artwork(request: web.Request) -> web.Response:
    device = _resolve(request)
    requested = request.query.get("v")
    result = await request.app[BACKEND_KEY].artwork(device.id, requested)
    if result is None:
        return _error(404, "no_artwork", "no artwork available")
    version, art = result
    cache = (
        "public, max-age=86400"
        if requested and requested == version
        else "no-cache"
    )
    return web.Response(
        body=art.data,
        content_type=art.mimetype,
        headers={"Cache-Control": cache, "ETag": f'"{version}"'},
    )


def create_app(backend: Backend, token: Optional[str] = None) -> web.Application:
    app = web.Application(middlewares=[auth_middleware])
    app[BACKEND_KEY] = backend
    app[TOKEN_KEY] = token or None
    app[STARTED_KEY] = time.time()
    app.router.add_get("/v1/health", health)
    app.router.add_get("/v1/devices", list_devices)
    app.router.add_get("/v1/devices/{id}/now-playing", now_playing)
    app.router.add_get("/v1/devices/{id}/artwork", artwork)
    return app
