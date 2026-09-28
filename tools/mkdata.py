#!/usr/bin/env python3
"""Create an empty OrangeOS data disk (/data; docs/design/013).

    python3 tools/mkdata.py build/data.img [--size-mib 256] [--keep]

The image is sparse: a superblock in its first 4 KiB block and two empty
slots, each half of the rest. The kernel (kernel/fs/tmpfs/persist.zig) loads
the newest valid slot at boot and saves /data into the other. With --keep an
existing image is left alone, so rebuilding the system never erases what is
saved on the data disk.
"""
import argparse
import os
import struct
import sys
import zlib

BLOCK = 4096
SUPER_MAGIC = b"OrangeOS data v1"
VERSION = 1


def superblock(slot_blocks):
    fields = SUPER_MAGIC + struct.pack("<IIQ", VERSION, 0, slot_blocks)
    return (fields + struct.pack("<I", zlib.crc32(fields))).ljust(BLOCK, b"\0")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("image")
    parser.add_argument("--size-mib", type=int, default=256)
    parser.add_argument("--keep", action="store_true", help="leave an existing image unchanged")
    args = parser.parse_args(argv)
    if args.keep and os.path.exists(args.image):
        print(f"mkdata: keeping {args.image}")
        return
    blocks = args.size_mib * 1024 * 1024 // BLOCK
    slot_blocks = (blocks - 1) // 2
    if slot_blocks < 2:
        raise SystemExit("mkdata: image too small")
    with open(args.image, "wb") as f:
        f.write(superblock(slot_blocks))
        f.truncate(blocks * BLOCK)
    print(f"mkdata: {args.image} ({args.size_mib} MiB, two slots of {slot_blocks * BLOCK // (1024 * 1024)} MiB)")


if __name__ == "__main__":
    main(sys.argv[1:])
