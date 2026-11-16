"""Pure mapping from pyatv state to the Control4 now-playing JSON contract.

Nothing in here does I/O, so it is unit-tested directly. The contract (consumed and
validated by the Lua driver) always contains every key; unknown values are ``None``
(JSON ``null``) and ``genres`` is always a list.

Mapping decisions (kept deliberately simple; see README "Mapping"):

* ``playback.state``: device offline / unreachable / powered off -> ``"off"``.
  Otherwise pyatv ``DeviceState``: Idle->idle, Loading->buffering, Paused->paused,
  Playing->playing, Stopped->stopped, Seeking->buffering. No playing info -> idle.
* ``media.kind``: Music->music. TV or Video *with* series name / season / episode ->
  episode. TV without series info -> video. Video that looks live (see below) ->
  live_tv. Video longer than 60 min -> movie. Other Video -> video. Unknown -> unknown.
* ``playback.is_live``: a heuristic, not a fact. True when there is an active session
  (playing/paused/buffering) with a title but no duration (pyatv reports none/0 for
  live streams). False when a duration is known. ``None`` when nothing is playing.
"""

from __future__ import annotations

import hashlib
import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence

from pyatv.const import DeviceState, MediaType
from pyatv.interface import Playing

PROVIDER = "appletv"
MOVIE_MIN_DURATION_S = 60 * 60

_STATE_MAP = {
    DeviceState.Idle: "idle",
    DeviceState.Loading: "buffering",
    DeviceState.Paused: "paused",
    DeviceState.Playing: "playing",
    DeviceState.Stopped: "stopped",
    DeviceState.Seeking: "buffering",
}
_ACTIVE_STATES = {"playing", "paused", "buffering"}


@dataclass(frozen=True)
class Snapshot:
    """Everything the mapping needs about one device at one point in time."""

    device_name: str
    online: bool  # connected AND not reported as powered off
    playing: Optional[Playing] = None
    app_name: Optional[str] = None
    app_id: Optional[str] = None
    volume: Optional[float] = None  # 0..100 as reported by pyatv
    updated_at: Optional[float] = None  # epoch seconds when `playing` was captured
    artwork_version: Optional[str] = None  # opaque, URL-safe; None = no artwork


@dataclass(frozen=True)
class DeviceSummary:
    """Row returned by GET /v1/devices (plus aliases used for id resolution)."""

    id: str
    name: str
    address: Optional[str]
    model: Optional[str]
    os: Optional[str]
    paired_protocols: Sequence[str]
    connected: bool
    aliases: Sequence[str] = ()

    def to_json(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "address": self.address,
            "model": self.model,
            "os": self.os,
            "paired_protocols": list(self.paired_protocols),
            "connected": self.connected,
        }


class AmbiguousDeviceError(LookupError):
    """More than one device matches the requested slug."""


def slugify(name: str) -> str:
    """URL-safe slug: 'Living Room (2)' -> 'living-room-2'."""
    ascii_name = (
        unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode("ascii")
    )
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_name.lower()).strip("-")
    return slug or "device"


def resolve_device(
    devices: Sequence[DeviceSummary], key: str
) -> Optional[DeviceSummary]:
    """Find a device by pyatv identifier (any of its identifiers) or name slug.

    Identifiers win over slugs and match case-insensitively. Raises
    AmbiguousDeviceError when a slug matches more than one device.
    """
    wanted = key.strip().lower()
    for dev in devices:
        if wanted == dev.id.lower() or wanted in (a.lower() for a in dev.aliases):
            return dev
    slug = slugify(key)
    matches = [dev for dev in devices if slugify(dev.name) == slug]
    if len(matches) > 1:
        raise AmbiguousDeviceError(key)
    return matches[0] if matches else None


def artwork_version(artwork_id: Optional[str]) -> Optional[str]:
    """Short, URL-safe cache-busting token derived from pyatv's artwork id."""
    if not artwork_id:
        return None
    return hashlib.sha256(artwork_id.encode("utf-8")).hexdigest()[:16]


def _clean_str(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    value = str(value).strip()
    return value or None


def _positive(value: Optional[float]) -> Optional[float]:
    if value is None or value <= 0:
        return None
    return float(value)


def map_state(snapshot: Snapshot) -> str:
    if not snapshot.online:
        return "off"
    if snapshot.playing is None:
        return "idle"
    return _STATE_MAP.get(snapshot.playing.device_state, "idle")


def classify_kind(playing: Optional[Playing], is_live: Optional[bool]) -> str:
    """Best-effort media kind. Never more certain than pyatv's data allows."""
    if playing is None:
        return "unknown"
    media_type = playing.media_type
    has_series = bool(_clean_str(playing.series_name)) or (
        playing.season_number is not None or playing.episode_number is not None
    )
    if media_type == MediaType.Music:
        return "music"
    if media_type == MediaType.TV:
        return "episode" if has_series else "video"
    if media_type == MediaType.Video:
        if has_series:
            return "episode"
        if is_live:
            return "live_tv"
        duration = _positive(playing.total_time)
        if duration is not None and duration > MOVIE_MIN_DURATION_S:
            return "movie"
        return "video"
    return "unknown"


def _subtitle(kind: str, playing: Playing) -> Optional[str]:
    if kind == "music":
        return _clean_str(playing.artist)
    if kind == "episode":
        parts: List[str] = []
        series = _clean_str(playing.series_name)
        if series:
            parts.append(series)
        se = ""
        if playing.season_number is not None:
            se += f"S{playing.season_number}"
        if playing.episode_number is not None:
            se += f"E{playing.episode_number}"
        if se:
            parts.append(se)
        return " · ".join(parts) or None
    return None


def map_now_playing(
    snapshot: Snapshot, artwork_url: Optional[str] = None
) -> Dict[str, Any]:
    """Build the exact now-playing contract dict for one device."""
    state = map_state(snapshot)
    online = state != "off"
    playing = snapshot.playing if online else None

    position = duration = None
    is_live: Optional[bool] = None
    if playing is not None:
        position = float(playing.position) if playing.position is not None else None
        duration = _positive(playing.total_time)
        if state in _ACTIVE_STATES:
            if duration is not None:
                is_live = False
            elif _clean_str(playing.title):
                is_live = True

    kind = classify_kind(playing, is_live)
    title = _clean_str(playing.title) if playing else None
    genre = _clean_str(playing.genre) if playing else None

    return {
        "source": {
            "provider": PROVIDER,
            "device_name": snapshot.device_name,
            "app_name": _clean_str(snapshot.app_name) if online else None,
            "app_id": _clean_str(snapshot.app_id) if online else None,
            "app_icon_url": None,
        },
        "playback": {
            "state": state,
            "position_s": position,
            "duration_s": duration,
            "position_updated_at": (
                int(snapshot.updated_at)
                if online and position is not None and snapshot.updated_at
                else None
            ),
            "is_live": is_live,
            "volume": (
                round(float(snapshot.volume), 1)
                if online and snapshot.volume is not None
                else None
            ),
        },
        "media": {
            "kind": kind,
            "title": title,
            "subtitle": _subtitle(kind, playing) if playing else None,
            "series_title": _clean_str(playing.series_name) if playing else None,
            "season": playing.season_number if playing else None,
            "episode": playing.episode_number if playing else None,
            "episode_title": title if kind == "episode" else None,
            "artist": _clean_str(playing.artist) if playing else None,
            "album": _clean_str(playing.album) if playing else None,
            "album_artist": None,  # not exposed by pyatv
            "track_number": None,  # not exposed by pyatv
            "channel_name": None,  # not exposed by pyatv
            "channel_number": None,  # not exposed by pyatv
            "year": None,  # not exposed by pyatv
            "genres": [genre] if genre else [],
            "artwork_url": artwork_url if online else None,
        },
    }
