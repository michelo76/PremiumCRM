# Apple TV now-playing bridge

A small always-on service that talks to Apple TVs (and HomePods) with
[pyatv](https://pyatv.dev) and exposes what is playing as plain JSON over HTTP, for
the Control4 now-playing driver to poll. Apple TV has no simple LAN HTTP API, so this
bridge runs on any box on the same LAN: Raspberry Pi, NAS, Docker host.

Coded and tested against **pyatv 0.18.0** (aiohttp 3.14, Python 3.9+).

## Setup: scan, pair, serve

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

python -m atv_bridge scan                      # list devices, ids, slugs, pairing needs
python -m atv_bridge pair "Living Room"        # pairs every protocol that needs it
python -m atv_bridge serve                     # http://0.0.0.0:8765
```

`pair` accepts a device id, name or slug, and `--protocol companion|airplay|raop|mrp`
to pair a single protocol. When the TV shows a PIN, type it in. Credentials are saved
to `~/.config/atv-bridge/pyatv.json` (file mode 600). Change the folder with
`--config-dir` or `ATV_BRIDGE_CONFIG_DIR`.

### Which protocols need pairing (tvOS 15 and later)

| Protocol  | Needed for                                             | Pairing                   |
|-----------|--------------------------------------------------------|---------------------------|
| AirPlay   | metadata: MRP is tunnelled over AirPlay on tvOS 15+    | **required** (PIN)        |
| Companion | power state (sleep becomes `off`), app info, volume    | **required** (PIN)        |
| MRP       | only on tvOS 14 and earlier (direct MRP port)          | required on old tvOS      |
| RAOP      | audio streaming only; not used for now playing         | usually not needed        |

Running `pair <device>` with no `--protocol` pairs AirPlay and Companion, the
protocols `scan` reports as `mandatory`. If `scan` shows `disabled`, on the Apple TV
set *Settings > AirPlay and HomeKit > Allow Access* to "Everyone on the Same Network".
HomePods normally need no pairing.

### serve options

| Flag / env var                          | Default               | Meaning                                    |
|-----------------------------------------|-----------------------|--------------------------------------------|
| `--host` / `ATV_BRIDGE_HOST`            | `0.0.0.0`             | Bind address                               |
| `--port` / `ATV_BRIDGE_PORT`            | `8765`                | Port                                       |
| `--token` / `ATV_BRIDGE_TOKEN`          | none                  | Shared secret (prefer the env var)         |
| `--config-dir` / `ATV_BRIDGE_CONFIG_DIR`| `~/.config/atv-bridge`| Where credentials are stored               |
| `--device` (repeatable)                 | all Apple TVs/HomePods| Manage only these ids/names                |
| `--scan-interval` / `ATV_BRIDGE_SCAN_INTERVAL` | `300`          | Seconds between discovery rescans          |
| `--scan-hosts` / `ATV_BRIDGE_SCAN_HOSTS`| none                  | Comma-separated IPs, unicast scan          |
| `--log-level` / `ATV_BRIDGE_LOG_LEVEL`  | `INFO`                | Bridge log level (`DEBUG` adds access log) |
| `--pyatv-log-level`                     | `WARNING`             | pyatv logs. **At DEBUG, pyatv may log credentials.** |

Without `--device`, the bridge manages devices whose state pyatv can read: tvOS
devices, HomePods, anything offering MRP, and anything you have paired. Third-party
AirPlay receivers (TVs, speakers) are skipped.

## HTTP API

These endpoints return JSON:

* `GET /v1/health`: `{"status":"ok","version":...,"uptime_s":...,"devices":N,"connected":M}`.
  It needs no token, so it works as a health check.
* `GET /v1/devices`: a list of `{id, name, address, model, os, paired_protocols, connected}`.
* `GET /v1/devices/{id}/now-playing`: the contract below.
* `GET /v1/devices/{id}/artwork?v=<version>`: image bytes, with the device's
  content-type. The images are cached in memory, keeping 8 per device. When `v` matches
  the current artwork, the response is `Cache-Control: max-age=86400`.

`{id}` can be the pyatv identifier (any of the device's identifiers), the device name,
or its slug (`Living Room` becomes `living-room`). An unknown id returns 404
`device_not_found`. A slug that matches two devices returns 409 `ambiguous_device`.

### Now-playing contract

The response always has every key. A value that is unknown is `null`, and `genres` is
always a list.

```json
{"source":{"provider":"appletv","device_name":"Living Room","app_name":"Netflix","app_id":"com.netflix.Netflix","app_icon_url":null},
 "playback":{"state":"playing","position_s":123.0,"duration_s":3600.0,"position_updated_at":1790000000,"is_live":false,"volume":null},
 "media":{"kind":"movie","title":"…","subtitle":null,"series_title":null,"season":null,"episode":null,"episode_title":null,"artist":null,"album":null,"album_artist":null,"track_number":null,"channel_name":null,"channel_number":null,"year":null,"genres":[],"artwork_url":"http://bridge:8765/v1/devices/AA%3ABB…/artwork?v=3f2a…"}}
```

`position_s` is read when the request arrives. pyatv extrapolates it from the device's
own timestamp. `position_updated_at` is the epoch second it was read. To show a running
clock between polls, add `now - position_updated_at` while `state == "playing"`.

### Mapping

The mapping code is in `atv_bridge/mapping.py`, a pure function covered by unit tests.

* **state**: if the device is not connected, is unreachable, or reports power Off
  (asleep), the state is `off`. Otherwise pyatv's state maps as follows: Idle→`idle`,
  Loading→`buffering`, Paused→`paused`, Playing→`playing`, Stopped→`stopped`,
  Seeking→`buffering`. Connected with no session at all gives `idle`.
* **kind**:
  * Music→`music`.
  * TV or Video that has a series name, season or episode→`episode`.
  * TV with no series info→`video`.
  * Video that looks live (see below)→`live_tv`.
  * Video longer than 60 minutes→`movie`.
  * Any other Video→`video`.
  * Unknown→`unknown`.

  The `movie` and `live_tv` kinds are heuristics, not facts.
* **is_live**: `true` when a session is active (playing, paused or buffering) with a
  title but no duration. `false` when a duration is known. `null` when nothing is
  playing or nothing is known.
* **subtitle**: for music, the artist. For an episode, `Series · S2E7`. Otherwise
  `null`. For an episode, `episode_title` repeats `title`.
* **volume**: 0–100 as pyatv reports it, when the Volume feature is available (usually
  it isn't on Apple TV: volume belongs to the TV or receiver). Otherwise `null`.
* **artwork_url**: an absolute URL built from the request's `Host` header, ending in
  `?v=<16-hex hash of pyatv's artwork id>`. It never carries the token (the URL is copied
  into Control4 variables, the state JSON and logs). With a token configured, the artwork
  endpoint accepts either the token (header or `?token=`) or a `v` equal to the version it
  serves, so an `<img>` on the LAN can load it without headers; any other request is 401.
  The Control4 driver sends the token as a header when it fetches artwork for remote
  Navigators. It is `null` when there is no artwork.
* pyatv does not expose `app_icon_url`, `album_artist`, `track_number`, `channel_*` or
  `year`, so they are always `null`. `genres` holds pyatv's single genre, when one is
  reported.

## Runtime behaviour

* **Connections.** There is one connection per device. Push updates keep a cached
  state, and every `now-playing` request re-reads the state, which pyatv holds locally.
* **Reconnects.** When a connection is lost, the bridge reconnects with exponential
  backoff (2 s, doubling up to 60 s, with jitter). Before each attempt it does a
  targeted rescan, which picks up a changed IP. A device that rejects the bridge's
  credentials is retried every 5 minutes, and the log says how to pair it.
* **Discovery.** A full rescan runs every 5 minutes and picks up new devices.
* **Shutdown.** On SIGTERM or SIGINT the bridge stops the push updaters and closes
  every connection.

## Docker

```bash
docker compose build
docker compose run --rm atv-bridge scan
docker compose run --rm atv-bridge pair "Living Room"
docker compose up -d
```

**Host networking is required** (`network_mode: host`). mDNS multicast does not cross
Docker's bridge network. Host networking is supported on Linux. Docker Desktop on
macOS and Windows does not give real host networking, so run the bridge natively
there. The image runs as a non-root user (uid 10001), and credentials live on the
`/data` volume.

## systemd

See `deploy/atv-bridge.service`. The install steps are in the comments at the top of
that file.

## Tests

```bash
pip install -r requirements-dev.txt
python -m pytest
```

The tests need no Apple TV. They cover the mapping, the HTTP handlers (using a fake
backend), token auth, slug resolution, and per-device state and the artwork cache
(using a fake pyatv device).

## Troubleshooting

* **`scan` finds nothing.** The bridge must be on the same L2 network or VLAN as the
  Apple TVs, or mDNS must be reflected to it. Check firewalls for UDP 5353. In Docker,
  use host networking. As a workaround, use `--scan-hosts 192.168.1.20,…` (unicast).
* **Log says "authentication required/failed".** Run `pair` again. Pairings break
  after a factory reset, after removing the remote under *Settings > Remotes and
  Devices*, or on some tvOS upgrades.
* **State is always `off`.** The device is unreachable, or it is asleep. A sleeping
  Apple TV reports power Off, which needs Companion pairing.
* **Title and artwork are empty while playing.** The app does not publish metadata.
  See Limitations.
* **More detail.** Set `--log-level DEBUG` for the access log and connection events.
  Use `--pyatv-log-level DEBUG` only briefly: it can print credentials.

## Limitations

* Now playing depends on what the app publishes to the system's Now Playing
  center. Many apps report full metadata (for example the Apple TV app and Music).
  Some report only a title. Some DRM or live-TV apps report only transport
  state (playing or paused), with no title, duration or artwork. The contract then
  shows `kind: "unknown"` with null fields.
* There are no channel names or numbers, years or app icons: pyatv does not provide
  them.
* The `movie`, `live_tv` and `is_live` values are heuristics, as described above.
* Third-party AirPlay receivers only expose what pyatv itself streams to them, so they
  are not managed by default.
* On 32-bit ARM (older Raspberry Pi OS), some pyatv dependencies (cryptography,
  miniaudio) may need compilers to install. Prefer a 64-bit OS.

## Security

The bridge is **LAN-only and unauthenticated by default**. Anyone who can reach port
8765 can read what is playing. Do not expose it to the internet. Set a token
(`ATV_BRIDGE_TOKEN`), which clients send as `Authorization: Bearer <token>` or
`?token=<token>`, and bind to a specific interface where possible. Exception: the
current artwork image is also served to anyone presenting its `?v=` version (a 64-bit
hash only published in `now-playing` responses), so web views can show it. The token is sent
in plain HTTP, so treat it as a light LAN guard, not real security. Access logs never
include query strings. `pyatv.json` holds pairing credentials: keep it at mode 600
and back it up like a password.
