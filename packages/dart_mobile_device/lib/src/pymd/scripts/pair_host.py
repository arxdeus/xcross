"""Advertise this host for iOS device-initiated pairing (iOS 27+).

Exists because `pymobiledevice3 remote pair-host` always advertises the
deterministic `generate_host_id()` identifier. A device that has *already*
paired with that identifier recognizes it and silently attempts pair-verify
instead of a fresh pair-setup, so no PIN is ever shown and the tap on the
phone appears to do nothing. There is no CLI flag for the identifier, so
xcross drives the library API directly.

Usage: python3 pair_host.py <name> [--timeout SECONDS] [--fresh]

  --fresh  advertise a random identifier, forcing pair-setup (a PIN) even
           when the phone still lists a stale entry for this host.

Output lines are contract with the Dart side; keep them stable:
  XCROSS-PAIR-ADVERTISING <name> <identifier>
  XCROSS-PAIR-PIN <code>
  XCROSS-PAIR-CONNECTED
  XCROSS-PAIR-RETRY <reason>
  XCROSS-PAIR-OK <udid> <name>
  XCROSS-PAIR-RECORD <path>
  XCROSS-PAIR-FAIL <reason>
"""

import argparse
import asyncio
import platform
import sys
import time
import uuid

try:
    from pymobiledevice3.remote.tunnel_service import (
        PairableHostInfo,
        serve_pairable_host,
    )
except ImportError as exc:  # pragma: no cover - reported to the caller as-is
    print(f"XCROSS-PAIR-FAIL unsupported pymobiledevice3: {exc}", flush=True)
    sys.exit(2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--fresh", action="store_true")
    args = parser.parse_args()

    kwargs = {"name": args.name}
    if args.fresh:
        # A brand-new identifier the phone cannot recognize, so it must run
        # pair-setup and show the PIN.
        kwargs["identifier"] = str(uuid.uuid4()).upper()
    info = PairableHostInfo(**kwargs)

    print(f"XCROSS-PAIR-ADVERTISING {info.name} {info.identifier}", flush=True)

    def pin_callback(pin: str) -> None:
        print(f"XCROSS-PAIR-CONNECTED", flush=True)
        print(f"XCROSS-PAIR-PIN {pin}", flush=True)

    def waiting_callback(elapsed: float) -> None:
        print(f"XCROSS-PAIR-WAITING {int(elapsed)}", flush=True)

    async def run() -> int:
        deadline = time.monotonic() + args.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print("XCROSS-PAIR-FAIL timeout", flush=True)
                return 1
            try:
                result = await serve_pairable_host(
                    info,
                    pin_callback=pin_callback,
                    waiting_callback=waiting_callback,
                    timeout=remaining,
                )
            except asyncio.TimeoutError:
                print("XCROSS-PAIR-FAIL timeout", flush=True)
                return 1
            except Exception as exc:  # noqa: BLE001
                # A half-open probe, a port scanner, or a phone that gave up
                # mid-handshake all land here and would otherwise end the
                # advertisement after a single stray packet. Keep serving:
                # the user is still standing at the phone.
                print(
                    f"XCROSS-PAIR-RETRY {type(exc).__name__}: {exc}",
                    flush=True,
                )
                continue
            device = result.peer_device
            print(f"XCROSS-PAIR-OK {device.udid} {device.name}", flush=True)
            print(f"XCROSS-PAIR-RECORD {result.record_path}", flush=True)
            return 0

    try:
        return asyncio.run(run())
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.argv[0] = platform.node()
    sys.exit(main())
