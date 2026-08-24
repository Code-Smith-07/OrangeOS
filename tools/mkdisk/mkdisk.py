#!/usr/bin/env python3
"""Create a GPT-partitioned disk image for Orange OS development.

Lays down a protective MBR, primary and backup GPT headers, and two
partitions: an EFI System partition and a data partition for CitrusFS.
"""

import struct
import sys
import uuid
import zlib

SECTOR = 512
ESP_GUID = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B").bytes_le
DATA_GUID = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4").bytes_le


def crc32(b):
    return zlib.crc32(b) & 0xFFFFFFFF


def build(path, size_mib=64, esp_mib=10):
    total = (size_mib * 1024 * 1024) // SECTOR
    disk = bytearray(SECTOR * total)

    entries = bytearray(128 * 128)

    def put(i, guid, first, last, name):
        e = bytearray(128)
        e[0:16] = guid
        e[16:32] = uuid.uuid4().bytes_le
        e[32:40] = struct.pack("<Q", first)
        e[40:48] = struct.pack("<Q", last)
        n = name.encode("utf-16-le")[:72]
        e[56 : 56 + len(n)] = n
        entries[i * 128 : (i + 1) * 128] = e

    esp_first = 2048
    esp_last = esp_first + (esp_mib * 1024 * 1024) // SECTOR - 1
    put(0, ESP_GUID, esp_first, esp_last, "ORANGE-ESP")
    put(1, DATA_GUID, esp_last + 1, total - 34, "ORANGE-ROOT")

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

    # Protective MBR: one 0xEE partition spanning the disk.
    disk[446:462] = (
        bytes([0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00])
        + struct.pack("<I", min(total - 1, 0xFFFFFFFF))
    )
    disk[510:512] = b"\x55\xAA"

    disk[SECTOR : SECTOR + 92] = header(1, total - 1, 2)
    disk[2 * SECTOR : 2 * SECTOR + len(entries)] = entries
    disk[(total - 1) * SECTOR : (total - 1) * SECTOR + 92] = header(total - 1, 1, total - 33)
    disk[(total - 33) * SECTOR : (total - 33) * SECTOR + len(entries)] = entries

    with open(path, "wb") as f:
        f.write(bytes(disk))

    print(f"mkdisk: {path} ({size_mib} MiB, ESP {esp_mib} MiB + data)")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "build/disk.img"
    build(out)
