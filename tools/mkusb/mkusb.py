#!/usr/bin/env python3
"""Build a single bootable disk image for real hardware.

The development setup boots an ISO and mounts a separate data disk. A USB
stick cannot do that: it has to be one image containing a protective MBR, a
GPT, an EFI System Partition holding the bootloader and kernel, and a CitrusFS
partition holding the root filesystem.

The ESP is FAT32 because that is the only filesystem UEFI firmware is required
to understand.
"""

import os
import struct
import subprocess
import sys
import uuid
import zlib

SECTOR = 512
ESP_GUID = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B").bytes_le
DATA_GUID = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4").bytes_le


def crc32(b):
    return zlib.crc32(b) & 0xFFFFFFFF


def build_esp(size_mib, files):
    """Create a FAT32 image containing `files`, given as {path: bytes}."""
    path = "build/esp.img"
    with open(path, "wb") as f:
        f.write(b"\x00" * (size_mib * 1024 * 1024))

    # mformat rather than newfs_msdos: the latter insists on a real block
    # device and refuses a plain file.
    subprocess.run(
        ["mformat", "-i", path, "-F", "-v", "ORANGEOS", "::"],
        check=True, capture_output=True,
    )

    made = set()
    for dest, data in files.items():
        directory = os.path.dirname(dest)
        parts = directory.split("/") if directory else []
        for i in range(len(parts)):
            d = "/".join(parts[: i + 1])
            if d and d not in made:
                subprocess.run(["mmd", "-i", path, f"::{d}"],
                               capture_output=True)
                made.add(d)

        tmp = "build/.espfile"
        with open(tmp, "wb") as f:
            f.write(data)
        subprocess.run(["mcopy", "-i", path, "-o", tmp, f"::{dest}"], check=True)

    if os.path.exists("build/.espfile"):
        os.remove("build/.espfile")

    with open(path, "rb") as f:
        return f.read()


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: mkusb.py <out.img> <citrusfs.img> [size-mib]")

    out, rootfs_path = sys.argv[1], sys.argv[2]
    size_mib = int(sys.argv[3]) if len(sys.argv) > 3 else 128

    with open(rootfs_path, "rb") as f:
        rootfs = f.read()

    total = (size_mib * 1024 * 1024) // SECTOR
    disk = bytearray(SECTOR * total)

    esp_mib = 48
    esp_first = 2048
    esp_sectors = (esp_mib * 1024 * 1024) // SECTOR
    esp_last = esp_first + esp_sectors - 1

    root_first = esp_last + 1
    root_sectors = len(rootfs) // SECTOR
    root_last = root_first + root_sectors - 1
    if root_last > total - 34:
        sys.exit(f"mkusb: root filesystem does not fit ({root_last} > {total-34})")

    entries = bytearray(128 * 128)

    def put(i, guid, first, last, name):
        e = bytearray(128)
        e[0:16] = guid
        e[16:32] = uuid.uuid4().bytes_le
        e[32:40] = struct.pack("<Q", first)
        e[40:48] = struct.pack("<Q", last)
        n = name.encode("utf-16-le")[:72]
        e[56:56 + len(n)] = n
        entries[i * 128:(i + 1) * 128] = e

    put(0, ESP_GUID, esp_first, esp_last, "ORANGE-ESP")
    put(1, DATA_GUID, root_first, root_last, "ORANGE-ROOT")

    earr_crc = crc32(bytes(entries))

    def header(cur, bak, earr_lba):
        h = bytearray(92)
        h[0:8] = b"EFI PART"
        h[8:12] = struct.pack("<I", 0x00010000)
        h[12:16] = struct.pack("<I", 92)
        h[24:32] = struct.pack("<Q", cur)
        h[32:40] = struct.pack("<Q", bak)
        h[40:48] = struct.pack("<Q", 34)
        h[48:56] = struct.pack("<Q", total - 34)
        h[56:72] = uuid.uuid4().bytes_le
        h[72:80] = struct.pack("<Q", earr_lba)
        h[80:84] = struct.pack("<I", 128)
        h[84:88] = struct.pack("<I", 128)
        h[88:92] = struct.pack("<I", earr_crc)
        h[16:20] = struct.pack("<I", crc32(bytes(h)))
        return h

    # Protective MBR: a machine that only understands MBR sees one partition
    # covering the whole disk, rather than free space it might offer to format.
    disk[446:462] = (
        bytes([0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00])
        + struct.pack("<I", min(total - 1, 0xFFFFFFFF))
    )
    disk[510:512] = b"\x55\xAA"

    disk[SECTOR:SECTOR + 92] = header(1, total - 1, 2)
    disk[2 * SECTOR:2 * SECTOR + len(entries)] = entries
    disk[(total - 1) * SECTOR:(total - 1) * SECTOR + 92] = header(total - 1, 1, total - 33)
    disk[(total - 33) * SECTOR:(total - 33) * SECTOR + len(entries)] = entries

    with open("zig-out/bin/kernel.elf", "rb") as f:
        kernel = f.read()
    with open("boot/limine.conf", "rb") as f:
        conf = f.read()
    with open("third_party/limine/BOOTX64.EFI", "rb") as f:
        bootx64 = f.read()

    esp = build_esp(esp_mib, {
        "EFI/BOOT/BOOTX64.EFI": bootx64,
        "boot/kernel.elf": kernel,
        "boot/limine.conf": conf,
    })

    disk[esp_first * SECTOR:esp_first * SECTOR + len(esp)] = esp
    disk[root_first * SECTOR:root_first * SECTOR + len(rootfs)] = rootfs

    with open(out, "wb") as f:
        f.write(bytes(disk))

    print(f"mkusb: {out}  {size_mib} MiB")
    print(f"  ESP   LBA {esp_first}..{esp_last}   {esp_mib} MiB FAT32")
    print(f"  root  LBA {root_first}..{root_last}   {len(rootfs)//1024//1024} MiB CitrusFS")


if __name__ == "__main__":
    main()
