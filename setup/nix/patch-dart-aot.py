#!/usr/bin/env python3
"""Point a Dart AOT executable at the Nix dynamic loader.

`dart compile exe` produces a small ELF runtime followed by the AOT snapshot
and a 16-byte trailer: the little-endian snapshot offset and a magic number.
Running `patchelf` directly on that file grows or moves ELF data, the trailer
then points at the wrong bytes, and the runtime falls back to printing the
`dartvm` usage text. Patch only the ELF runtime and re-append the untouched
snapshot at a page-aligned offset with a fresh trailer.
"""

import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

MAGIC = 0x0000_0000_F6F6_DCDC
PAGE = 1 << 16


def main(source: str, destination: str, interpreter: str) -> None:
    data = Path(source).read_bytes()
    offset, magic = struct.unpack("<qQ", data[-16:])
    if magic != MAGIC or not 0 < offset < len(data) - 16:
        sys.exit(f"{source}: not a Dart AOT executable")

    with tempfile.TemporaryDirectory() as scratch:
        runtime = Path(scratch, "runtime")
        runtime.write_bytes(data[:offset])
        subprocess.run(
            ["patchelf", "--set-interpreter", interpreter, str(runtime)],
            check=True,
        )
        patched = runtime.read_bytes()

    aligned = -(-len(patched) // PAGE) * PAGE
    snapshot = data[offset:-16]
    output = Path(destination)
    output.write_bytes(
        patched
        + b"\0" * (aligned - len(patched))
        + snapshot
        + struct.pack("<qQ", aligned, MAGIC)
    )
    shutil.copymode(source, output)


if __name__ == "__main__":
    main(*sys.argv[1:])
