#!/usr/bin/env python3
"""The /data volume survives reboots and a damaged save (docs/design/013).

Build: zig build -Ddesktop-profile; ORANGE_DATA_PROBE=1 scripts/mkdisk.sh

Boots the system three times on one fresh data disk, with data-probe started
at boot:
  1. /data is empty; the probe saves files and fsyncs.
  2. The probe finds every file as boot 1 left it, and saves again.
  3. Before booting, the newest save's header is damaged on the host; the
     kernel must say so and load the other slot's (older) save instead.
"""
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(__file__))
from desktop_smoke import Guest  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
BLOCK = 4096


def boot(image, expect, label, seconds=240):
    g = Guest(extra_args=("-drive", f"id=data0,file={image},format=raw,if=none",
                          "-device", "ide-hd,drive=data0,bus=ahci.1"))
    try:
        g.until(lambda: "data-probe: PASS" in g.log() or "data-probe: FAIL" in g.log(), label, seconds)
        log = g.log()
        assert expect in log, log[-3000:]
        print(f"PASS {label}", flush=True)
        return log
    finally:
        g.close()


def slots(image):
    """(generation, header offset) of each valid slot header."""
    with open(image, "rb") as f:
        sb = f.read(BLOCK)
        slot_blocks = struct.unpack_from("<Q", sb, 24)[0]
        found = []
        for slot in range(2):
            offset = (1 + slot * slot_blocks) * BLOCK
            f.seek(offset)
            header = f.read(32)
            if header[:8] == b"ORDSLOT1" and zlib.crc32(header[:28]) == struct.unpack_from("<I", header, 28)[0]:
                found.append((struct.unpack_from("<Q", header, 8)[0], offset))
        return found


def main():
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-data-"))
    image = work / "data.img"
    subprocess.run([sys.executable, str(ROOT / "tools/mkdata.py"), str(image), "--size-mib", "64"], check=True)

    log = boot(image, "data-probe: PASS empty /data; saved boot 1", "boot 1 saves to an empty /data")
    assert "data volume on" in log and ": empty" in log, log[-3000:]

    log = boot(image, "data-probe: PASS found boot 1's files; saved boot 2", "boot 2 finds boot 1's files")
    assert "data volume on" in log and ": save " in log, log[-3000:]

    saved = sorted(slots(image))
    assert len(saved) == 2, f"both slots hold saves after two boots: {saved}"
    (older, _), (newest, offset) = saved
    with open(image, "r+b") as f:
        f.seek(offset + 8)
        f.write(b"\xff")  # the generation field: the header CRC no longer matches
    g = Guest(extra_args=("-drive", f"id=data0,file={image},format=raw,if=none",
                          "-device", "ide-hd,drive=data0,bus=ahci.1"))
    try:
        g.until(lambda: "data volume on" in g.log(), "boot 3 mounts /data", 120)
        assert f": save {older}," in g.log(), g.log()[-3000:]
        print(f"PASS a damaged newest save ({newest}) falls back to the other slot ({older})", flush=True)
    finally:
        g.close()
    print(f"Data volume checks passed; image in {work}", flush=True)


if __name__ == "__main__":
    main()
