#!/usr/bin/env python3
"""Check the sparse browser-capacity image and boot it in QEMU."""

import pathlib
import struct
import zlib

from desktop_smoke import Guest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DISK = ROOT / "build/browser-disk.img"
FS = ROOT / "build/browser-citrus.img"
SECTOR = 512


def check_image():
    assert DISK.stat().st_size == 2112 * 1024**2
    assert FS.stat().st_size == 2048 * 1024**2
    # A fresh browser profile must reserve capacity, not consume it all.
    assert DISK.stat().st_blocks * SECTOR < 256 * 1024**2
    with DISK.open("rb") as image:
        image.seek(SECTOR)
        primary = image.read(92)
        assert primary[:8] == b"EFI PART"
        saved_crc = struct.unpack_from("<I", primary, 16)[0]
        zeroed = bytearray(primary)
        zeroed[16:20] = b"\0" * 4
        assert zlib.crc32(zeroed) == saved_crc
        total_sectors = DISK.stat().st_size // SECTOR
        image.seek((total_sectors - 1) * SECTOR)
        backup = image.read(92)
        assert backup[:8] == b"EFI PART"
        assert backup[56:72] == primary[56:72]
        image.seek(2 * SECTOR + 128)
        entry = image.read(128)
        first, last = struct.unpack_from("<QQ", entry, 32)
        assert first == 22528
        assert (last - first + 1) * SECTOR >= FS.stat().st_size
        image.seek(first * SECTOR)
        superblock = image.read(4096)
        assert superblock[:4] == b"CTRS"
        assert struct.unpack_from("<Q", superblock, 16)[0] == 2048 * 256
    print("PASS sparse 2 GiB CitrusFS image, GPT and filesystem metadata", flush=True)


def main():
    check_image()
    guest = Guest(disk_path=DISK)
    print(f"Evidence: {guest.output}", flush=True)
    try:
        guest.until(lambda: "mounted CitrusFS" in guest.log(), "browser-capacity filesystem mounts", 45)
        guest.until(lambda: '"Welcome"' in guest.log() and "squeeze: window" in guest.log(),
                    "desktop boots from browser-capacity disk", 60)
        guest.screenshot("browser-capacity-desktop")
    finally:
        guest.close()


if __name__ == "__main__":
    main()
