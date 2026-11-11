"""Command line: scan, pair, serve."""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
from pathlib import Path
from typing import List, Optional, Sequence

import pyatv
from pyatv.const import PairingRequirement, Protocol
from pyatv.interface import BaseConfig, BaseService

from atv_bridge import __version__
from atv_bridge.manager import (
    DeviceManager,
    model_string,
    name_matches,
    open_storage,
    os_string,
    paired_protocols,
    secure_storage_file,
    storage_path,
)
from atv_bridge.mapping import slugify

_LOGGER = logging.getLogger("atv_bridge")

PROTOCOLS = {
    "companion": Protocol.Companion,
    "airplay": Protocol.AirPlay,
    "raop": Protocol.RAOP,
    "mrp": Protocol.MRP,
}
REMOTE_NAME = "Control4 Now Playing Bridge"


def _env(name: str, default: Optional[str] = None) -> Optional[str]:
    return os.environ.get(f"ATV_BRIDGE_{name}", default)


def _setup_logging(level: str, pyatv_level: str) -> None:
    logging.basicConfig(
        level=level.upper(),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )
    # pyatv at DEBUG can print service configs including credentials.
    logging.getLogger("pyatv").setLevel(pyatv_level.upper())
    logging.getLogger("aiohttp.access").setLevel(level.upper())


def _hosts(value: Optional[str]) -> List[str]:
    return [h.strip() for h in (value or "").split(",") if h.strip()]


async def _scan(config_dir: Path, hosts: Sequence[str], timeout: int) -> List[BaseConfig]:
    storage = open_storage(config_dir, asyncio.get_running_loop())
    await storage.load()
    return await pyatv.scan(
        asyncio.get_running_loop(),
        timeout=timeout,
        hosts=list(hosts) or None,
        storage=storage,
    )


def _service_line(service: BaseService) -> str:
    paired = "paired" if service.credentials else service.pairing.name.lower()
    return f"{service.protocol.name.lower()}:{service.port} ({paired})"


async def cmd_scan(args: argparse.Namespace) -> int:
    configs = await _scan(args.config_dir, _hosts(args.scan_hosts), args.timeout)
    if not configs:
        print("No devices found. Is this host on the same LAN/VLAN (mDNS)?")
        return 1
    for conf in sorted(configs, key=lambda c: c.name.lower()):
        print(f"{conf.name}")
        print(f"  id:       {conf.identifier}")
        print(f"  slug:     {slugify(conf.name)}")
        print(f"  address:  {conf.address}")
        print(f"  model:    {model_string(conf) or '?'}   os: {os_string(conf) or '?'}")
        print(f"  services: {', '.join(_service_line(s) for s in conf.services)}")
        print()
    print(
        "pairing column: 'mandatory' = run `pair` for that protocol; "
        "'disabled' = enable access in the device settings first."
    )
    return 0


async def _read_pin() -> str:
    loop = asyncio.get_running_loop()
    return (await loop.run_in_executor(None, input, "Enter PIN shown on the TV: ")).strip()


def _protocols_to_pair(conf: BaseConfig, requested: Optional[str]) -> List[Protocol]:
    if requested:
        return [PROTOCOLS[requested]]
    wanted = []
    for proto in (Protocol.AirPlay, Protocol.Companion, Protocol.MRP, Protocol.RAOP):
        service = conf.get_service(proto)
        if service is None or service.credentials:
            continue
        if service.pairing == PairingRequirement.Mandatory:
            wanted.append(proto)
    return wanted


async def cmd_pair(args: argparse.Namespace) -> int:
    loop = asyncio.get_running_loop()
    storage = open_storage(args.config_dir, loop)
    await storage.load()
    configs = await pyatv.scan(
        loop, timeout=args.timeout, hosts=_hosts(args.scan_hosts) or None, storage=storage
    )
    matches = [c for c in configs if name_matches(c, args.device)]
    if len(matches) != 1:
        print(
            f"{'No' if not matches else 'Several'} device(s) match {args.device!r}; "
            "run `scan` and use the id."
        )
        return 1
    conf = matches[0]
    protocols = _protocols_to_pair(conf, args.protocol)
    if not protocols:
        print(f"{conf.name}: nothing needs pairing (already paired or not required).")
        return 0

    failures = 0
    for proto in protocols:
        service = conf.get_service(proto)
        if service is None:
            print(f"{conf.name} does not offer {proto.name}.")
            failures += 1
            continue
        if service.pairing == PairingRequirement.Disabled:
            print(
                f"{proto.name}: pairing disabled on the device. On the Apple TV set "
                "Settings > AirPlay and HomeKit > Allow Access to 'Everyone on the "
                "Same Network' (or 'Anyone'), then retry."
            )
            failures += 1
            continue
        print(f"Pairing {proto.name} with {conf.name} ...")
        handler = await pyatv.pair(conf, proto, loop, storage=storage, name=REMOTE_NAME)
        try:
            await handler.begin()
            if handler.device_provides_pin:
                handler.pin(await _read_pin())
            else:
                handler.pin(1234)
                input(f"Enter PIN 1234 on the device for '{REMOTE_NAME}', then press Enter")
            await handler.finish()
            if handler.has_paired:
                print(f"  {proto.name}: paired.")
            else:
                print(f"  {proto.name}: pairing did not complete.")
                failures += 1
        except Exception as exc:  # pylint: disable=broad-except
            print(f"  {proto.name}: pairing failed: {type(exc).__name__}: {exc}")
            failures += 1
        finally:
            await handler.close()

    await storage.save()
    secure_storage_file(args.config_dir)
    print(f"Credentials saved to {storage_path(args.config_dir)} (mode 600).")
    return 1 if failures else 0


async def cmd_serve(args: argparse.Namespace) -> int:
    from aiohttp import web

    from atv_bridge.server import RedactingAccessLogger, create_app

    manager = DeviceManager(
        args.config_dir,
        scan_interval=args.scan_interval,
        devices=args.device or [],
        scan_hosts=_hosts(args.scan_hosts),
    )
    app = create_app(manager, token=args.token)

    async def _start(_app: web.Application) -> None:
        await manager.start()

    async def _stop(_app: web.Application) -> None:
        await manager.stop()

    app.on_startup.append(_start)
    app.on_cleanup.append(_stop)

    runner = web.AppRunner(app, access_log_class=RedactingAccessLogger)
    await runner.setup()
    site = web.TCPSite(runner, args.host, args.port)
    await site.start()
    _LOGGER.info(
        "atv-bridge %s listening on http://%s:%d (auth: %s)",
        __version__,
        args.host,
        args.port,
        "token" if args.token else "NONE - LAN only!",
    )
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    try:
        import signal

        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop.set)
    except (NotImplementedError, RuntimeError):  # pragma: no cover (Windows)
        pass
    try:
        await stop.wait()
    finally:
        _LOGGER.info("Shutting down")
        await runner.cleanup()
    return 0


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--config-dir",
        type=Path,
        default=Path(_env("CONFIG_DIR", "~/.config/atv-bridge")).expanduser(),
        help="directory holding pyatv.json credentials (env ATV_BRIDGE_CONFIG_DIR)",
    )
    common.add_argument(
        "--log-level", default=_env("LOG_LEVEL", "INFO"), help="DEBUG, INFO, WARNING"
    )
    common.add_argument(
        "--pyatv-log-level",
        default=_env("PYATV_LOG_LEVEL", "WARNING"),
        help="pyatv library log level (DEBUG may log credentials)",
    )
    common.add_argument(
        "--scan-hosts",
        default=_env("SCAN_HOSTS"),
        help="comma-separated IPs to scan by unicast instead of multicast mDNS",
    )

    parser = argparse.ArgumentParser(
        prog="atv_bridge", description="Apple TV now-playing bridge for Control4"
    )
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_scan = sub.add_parser("scan", parents=[common], help="list devices on the LAN")
    p_scan.add_argument("--timeout", type=int, default=5)

    p_pair = sub.add_parser("pair", parents=[common], help="pair with a device")
    p_pair.add_argument("device", help="device id, name or slug (see `scan`)")
    p_pair.add_argument("--protocol", choices=sorted(PROTOCOLS), default=None)
    p_pair.add_argument("--timeout", type=int, default=5)

    p_serve = sub.add_parser("serve", parents=[common], help="run the HTTP bridge")
    p_serve.add_argument("--host", default=_env("HOST", "0.0.0.0"))
    p_serve.add_argument("--port", type=int, default=int(_env("PORT", "8765") or 8765))
    p_serve.add_argument(
        "--token",
        default=_env("TOKEN"),
        help="shared secret; prefer env ATV_BRIDGE_TOKEN (not visible in ps)",
    )
    p_serve.add_argument(
        "--device",
        action="append",
        help="only manage this device id/name (repeatable; default: all Apple "
        "TVs/HomePods found)",
    )
    p_serve.add_argument(
        "--scan-interval",
        type=float,
        default=float(_env("SCAN_INTERVAL", "300") or 300),
        help="seconds between discovery rescans",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    _setup_logging(args.log_level, args.pyatv_log_level)
    command = {"scan": cmd_scan, "pair": cmd_pair, "serve": cmd_serve}[args.command]
    try:
        return asyncio.run(command(args))
    except KeyboardInterrupt:
        return 130
