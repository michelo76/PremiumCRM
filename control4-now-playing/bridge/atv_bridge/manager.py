"""Device discovery, connections and cached now-playing state (the pyatv side)."""

from __future__ import annotations

import asyncio
import logging
import os
import random
import time
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple

import pyatv
from pyatv import exceptions
from pyatv.const import (
    DeviceModel,
    FeatureName,
    FeatureState,
    OperatingSystem,
    PowerState,
    Protocol,
)
from pyatv.interface import (
    AppleTV,
    BaseConfig,
    DeviceListener,
    Playing,
    PowerListener,
    PushListener,
)
from pyatv.storage.file_storage import FileStorage

from atv_bridge.mapping import DeviceSummary, Snapshot, artwork_version, slugify

_LOGGER = logging.getLogger(__name__)

STORAGE_FILENAME = "pyatv.json"
SCAN_TIMEOUT_S = 5
METADATA_TIMEOUT_S = 3.0
ARTWORK_TIMEOUT_S = 8.0
ARTWORK_CACHE_PER_DEVICE = 8
BACKOFF_MIN_S = 2.0
BACKOFF_MAX_S = 60.0
BACKOFF_AUTH_S = 300.0  # device demands credentials we do not have
STABLE_CONNECTION_S = 60.0
_HOMEPODS = {DeviceModel.HomePod, DeviceModel.HomePodMini, DeviceModel.HomePodGen2}
_AUTH_ERRORS = (
    exceptions.AuthenticationError,
    exceptions.NoCredentialsError,
    exceptions.InvalidCredentialsError,
)


@dataclass(frozen=True)
class Artwork:
    data: bytes
    mimetype: str


def storage_path(config_dir: Path) -> Path:
    return config_dir / STORAGE_FILENAME


def open_storage(config_dir: Path, loop: asyncio.AbstractEventLoop) -> FileStorage:
    config_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    return FileStorage(str(storage_path(config_dir)), loop)


def secure_storage_file(config_dir: Path) -> None:
    """Credentials live in this file: keep it owner-readable only."""
    path = storage_path(config_dir)
    if path.exists():
        os.chmod(path, 0o600)


def paired_protocols(config: BaseConfig) -> List[str]:
    return sorted(s.protocol.name.lower() for s in config.services if s.credentials)


def os_string(config: BaseConfig) -> Optional[str]:
    info = config.device_info
    if info.operating_system == OperatingSystem.Unknown:
        return None
    name = {OperatingSystem.TvOS: "tvOS", OperatingSystem.MacOS: "macOS"}.get(
        info.operating_system, info.operating_system.name
    )
    return f"{name} {info.version}" if info.version else name


def model_string(config: BaseConfig) -> Optional[str]:
    model = config.device_info.model_str
    return None if not model or model == "Unknown" else model


def name_matches(config: BaseConfig, key: str) -> bool:
    wanted = key.strip().lower()
    return (
        wanted in (i.lower() for i in config.all_identifiers)
        or wanted == config.name.lower()
        or slugify(key) == slugify(config.name)
    )


def is_now_playing_capable(config: BaseConfig) -> bool:
    """Devices whose now-playing state pyatv can actually read (Apple TV, HomePod).

    Third-party AirPlay receivers (TVs, speakers) are skipped unless named with
    --device: pyatv can only see what *it* streams to those.
    """
    info = config.device_info
    return (
        info.operating_system == OperatingSystem.TvOS
        or info.model in _HOMEPODS
        or config.get_service(Protocol.MRP) is not None
        or bool(paired_protocols(config))
    )


class DeviceHandle(PushListener, DeviceListener, PowerListener):
    """One device: its connection lifecycle and the last known state."""

    def __init__(self, manager: "DeviceManager", config: BaseConfig) -> None:
        self._manager = manager
        self.config = config
        self.id: str = config.identifier or slugify(config.name)
        self.atv: Optional[AppleTV] = None
        self.playing: Optional[Playing] = None
        self.updated_at: Optional[float] = None
        self.power_state: PowerState = PowerState.Unknown
        self._lost = asyncio.Event()
        self._task: Optional[asyncio.Task] = None
        self._artwork: "OrderedDict[str, Artwork]" = OrderedDict()
        self._artwork_lock = asyncio.Lock()

    @property
    def name(self) -> str:
        return self.config.name

    @property
    def connected(self) -> bool:
        return self.atv is not None

    def summary(self) -> DeviceSummary:
        return DeviceSummary(
            id=self.id,
            name=self.name,
            address=str(self.config.address) if self.config.address else None,
            model=model_string(self.config),
            os=os_string(self.config),
            paired_protocols=paired_protocols(self.config),
            connected=self.connected,
            aliases=tuple(self.config.all_identifiers),
        )

    # --- lifecycle -------------------------------------------------------------

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._run(), name=f"atv:{self.name}")

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        await self._teardown()

    async def _run(self) -> None:
        backoff = BACKOFF_MIN_S
        while True:
            delay = backoff
            started = time.monotonic()
            try:
                await self._connect()
                await self._lost.wait()
                _LOGGER.warning("%s: connection lost, reconnecting", self.name)
            except asyncio.CancelledError:
                raise
            except _AUTH_ERRORS as exc:
                delay = BACKOFF_AUTH_S
                _LOGGER.warning(
                    "%s: authentication required/failed (%s). Pair it: "
                    "python -m atv_bridge pair %r",
                    self.name,
                    type(exc).__name__,
                    self.id,
                )
            except Exception as exc:  # pylint: disable=broad-except
                _LOGGER.warning(
                    "%s: connect failed: %s: %s", self.name, type(exc).__name__, exc
                )
            finally:
                await self._teardown()

            if time.monotonic() - started > STABLE_CONNECTION_S:
                backoff = delay = BACKOFF_MIN_S
            else:
                backoff = min(backoff * 2, BACKOFF_MAX_S)
            await asyncio.sleep(delay + random.uniform(0, delay / 4))
            fresh = await self._manager.rescan_one(self.id)
            if fresh is not None:
                self.config = fresh

    async def _connect(self) -> None:
        self._lost.clear()
        _LOGGER.info("%s: connecting to %s", self.name, self.config.address)
        atv = await pyatv.connect(
            self.config, asyncio.get_running_loop(), storage=self._manager.storage
        )
        self.atv = atv
        atv.listener = self
        atv.power.listener = self
        atv.push_updater.listener = self
        try:
            self.power_state = atv.power.power_state
        except exceptions.NotSupportedError:
            self.power_state = PowerState.Unknown
        try:
            atv.push_updater.start()
        except exceptions.NotSupportedError:
            _LOGGER.info("%s: push updates unsupported; polling on request", self.name)
        await self._refresh()
        _LOGGER.info("%s: connected", self.name)

    async def _teardown(self) -> None:
        atv, self.atv = self.atv, None
        if atv is None:
            return
        try:
            atv.push_updater.stop()
        except Exception:  # pylint: disable=broad-except
            pass
        tasks = atv.close()
        if tasks:
            await asyncio.wait(tasks, timeout=5)

    # --- pyatv listener callbacks ---------------------------------------------

    def playstatus_update(self, updater, playstatus: Playing) -> None:
        self.playing = playstatus
        self.updated_at = time.time()
        _LOGGER.debug(
            "%s: %s %s", self.name, playstatus.device_state.name, playstatus.title
        )

    def playstatus_error(self, updater, exception: Exception) -> None:
        _LOGGER.debug("%s: push update error: %s", self.name, exception)

    def connection_lost(self, exception: Exception) -> None:
        self._lost.set()

    def connection_closed(self) -> None:
        self._lost.set()

    def powerstate_update(self, old_state: PowerState, new_state: PowerState) -> None:
        _LOGGER.info("%s: power %s -> %s", self.name, old_state.name, new_state.name)
        self.power_state = new_state
        self.updated_at = time.time()

    # --- state -----------------------------------------------------------------

    async def _refresh(self) -> None:
        """Re-read playing state; MRP extrapolates position at read time."""
        atv = self.atv
        if atv is None:
            return
        try:
            self.playing = await asyncio.wait_for(
                atv.metadata.playing(), METADATA_TIMEOUT_S
            )
            self.updated_at = time.time()
        except (asyncio.TimeoutError, exceptions.NotSupportedError):
            pass
        except Exception as exc:  # pylint: disable=broad-except
            _LOGGER.debug("%s: metadata refresh failed: %s", self.name, exc)

    def _artwork_id(self) -> Optional[str]:
        atv = self.atv
        if atv is None:
            return None
        try:
            return atv.metadata.artwork_id or None
        except Exception:  # pylint: disable=broad-except
            return None

    async def snapshot(self) -> Snapshot:
        await self._refresh()
        atv = self.atv
        app_name = app_id = None
        volume: Optional[float] = None
        if atv is not None:
            try:
                app = atv.metadata.app
                if app is not None:
                    app_name, app_id = app.name, app.identifier
            except Exception:  # pylint: disable=broad-except
                pass
            try:
                if atv.features.in_state(FeatureState.Available, FeatureName.Volume):
                    volume = atv.audio.volume
            except Exception:  # pylint: disable=broad-except
                pass
        return Snapshot(
            device_name=self.name,
            online=atv is not None and self.power_state != PowerState.Off,
            playing=self.playing,
            app_name=app_name,
            app_id=app_id,
            volume=volume,
            updated_at=self.updated_at,
            artwork_version=artwork_version(self._artwork_id()),
        )

    async def artwork(self, version: Optional[str]) -> Optional[Tuple[str, Artwork]]:
        if version and version in self._artwork:
            self._artwork.move_to_end(version)
            return version, self._artwork[version]
        async with self._artwork_lock:
            current = artwork_version(self._artwork_id())
            if current is None or self.atv is None:
                return None
            if current in self._artwork:
                return current, self._artwork[current]
            try:
                info = await asyncio.wait_for(
                    self.atv.metadata.artwork(width=512), ARTWORK_TIMEOUT_S
                )
            except Exception as exc:  # pylint: disable=broad-except
                _LOGGER.debug("%s: artwork fetch failed: %s", self.name, exc)
                return None
            if info is None or not info.bytes:
                return None
            art = Artwork(info.bytes, info.mimetype or "image/jpeg")
            self._artwork[current] = art
            while len(self._artwork) > ARTWORK_CACHE_PER_DEVICE:
                self._artwork.popitem(last=False)
            return current, art


class DeviceManager:
    """Discovers devices, keeps one DeviceHandle per device, rescans periodically."""

    def __init__(
        self,
        config_dir: Path,
        *,
        scan_interval: float = 300.0,
        devices: Sequence[str] = (),
        scan_hosts: Sequence[str] = (),
    ) -> None:
        self.config_dir = config_dir
        self.scan_interval = scan_interval
        self.device_filter = list(devices)
        self.scan_hosts = list(scan_hosts)
        self.storage: Optional[FileStorage] = None
        self._handles: Dict[str, DeviceHandle] = {}
        self._scan_lock = asyncio.Lock()
        self._rescan_task: Optional[asyncio.Task] = None
        self.started_at = time.time()

    async def start(self) -> None:
        loop = asyncio.get_running_loop()
        self.storage = open_storage(self.config_dir, loop)
        await self.storage.load()
        _LOGGER.info("Using credential storage %s", storage_path(self.config_dir))
        await self.rescan()
        self._rescan_task = asyncio.create_task(self._rescan_loop(), name="rescan")

    async def stop(self) -> None:
        if self._rescan_task is not None:
            self._rescan_task.cancel()
            try:
                await self._rescan_task
            except asyncio.CancelledError:
                pass
        await asyncio.gather(
            *(h.stop() for h in self._handles.values()), return_exceptions=True
        )
        _LOGGER.info("Stopped %d device connection(s)", len(self._handles))

    async def _scan(
        self, identifier: Optional[str] = None, timeout: int = SCAN_TIMEOUT_S
    ) -> List[BaseConfig]:
        async with self._scan_lock:
            return await pyatv.scan(
                asyncio.get_running_loop(),
                timeout=timeout,
                identifier=identifier,
                hosts=self.scan_hosts or None,
                storage=self.storage,
            )

    def _wanted(self, config: BaseConfig) -> bool:
        if self.device_filter:
            return any(name_matches(config, key) for key in self.device_filter)
        return is_now_playing_capable(config)

    async def rescan(self) -> None:
        try:
            configs = await self._scan()
        except Exception as exc:  # pylint: disable=broad-except
            _LOGGER.warning("Scan failed: %s", exc)
            return
        seen: Set[str] = set()
        for config in configs:
            ident = config.identifier
            if ident is None or not self._wanted(config):
                continue
            seen.add(ident)
            handle = self._handles.get(ident)
            if handle is None:
                handle = DeviceHandle(self, config)
                self._handles[ident] = handle
                _LOGGER.info(
                    "Discovered %s (%s) at %s", config.name, ident, config.address
                )
                handle.start()
            elif not handle.connected:
                handle.config = config  # picks up a changed address on reconnect
        _LOGGER.debug("Scan found %d device(s), %d managed", len(configs), len(seen))

    async def rescan_one(self, identifier: str) -> Optional[BaseConfig]:
        try:
            found = await self._scan(identifier=identifier, timeout=3)
        except Exception:  # pylint: disable=broad-except
            return None
        return found[0] if found else None

    async def _rescan_loop(self) -> None:
        while True:
            await asyncio.sleep(self.scan_interval)
            await self.rescan()

    # --- Backend interface used by the HTTP server ------------------------------

    def devices(self) -> List[DeviceSummary]:
        return [h.summary() for h in self._handles.values()]

    async def snapshot(self, device_id: str) -> Snapshot:
        return await self._handles[device_id].snapshot()

    async def artwork(
        self, device_id: str, version: Optional[str]
    ) -> Optional[Tuple[str, Artwork]]:
        return await self._handles[device_id].artwork(version)
