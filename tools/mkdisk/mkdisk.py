#!/usr/bin/env python3
"""Create a sparse GPT development disk with an optional CitrusFS payload."""

import os
import struct
import sys
import tempfile
import uuid
import zlib

SECTOR = 512
ESP_GUID = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B").bytes_le
DATA_GUID = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4").bytes_le


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def copy_sparse(source, target, destination_offset):
    """Copy nonzero runs without materializing unwritten CitrusFS blocks."""
    offset = 0
    while True:
        chunk = source.read(1024 * 1024)
        if not chunk:
            return
        # Some hosts do not support SEEK_DATA/SEEK_HOLE. Test fixed-size
        # blocks instead, keeping the tool portable and the image sparse.
        for start in range(0, len(chunk), 4096):
            block = chunk[start:start + 4096]
            if any(block):
                target.seek(destination_offset + offset + start)
                target.write(block)
        offset += len(chunk)


def build(path, size_mib=64, esp_mib=10, citrus_path=None):
    if size_mib < esp_mib + 12 or esp_mib < 1:
        raise ValueError("disk must leave room for the ESP, data partition and GPT")
    total = (size_mib * 1024 * 1024) // SECTOR
    esp_first = 2048
    esp_last = esp_first + (esp_mib * 1024 * 1024) // SECTOR - 1
    data_first = esp_last + 1
    data_last = total - 34
    if data_first > data_last:
        raise ValueError("disk has no room for the data partition")
    if citrus_path and os.path.getsize(citrus_path) > (data_last - data_first + 1) * SECTOR:
        raise ValueError("CitrusFS image exceeds the data partition")

    entries = bytearray(128 * 128)

    def put(i, guid, first, last, name):
        entry = bytearray(128)
        entry[0:16] = guid
        entry[16:32] = uuid.uuid4().bytes_le
        entry[32:40] = struct.pack("<Q", first)
        entry[40:48] = struct.pack("<Q", last)
        name_bytes = name.encode("utf-16-le")[:72]
        entry[56:56 + len(name_bytes)] = name_bytes
        entries[i * 128:(i + 1) * 128] = entry

    put(0, ESP_GUID, esp_first, esp_last, "ORANGE-ESP")
    put(1, DATA_GUID, data_first, data_last, "ORANGE-ROOT")
    entries_crc = crc32(entries)
    disk_guid = uuid.uuid4().bytes_le

    def header(current, backup, entries_lba):
        result = bytearray(92)
        result[0:8] = b"EFI PART"
        struct.pack_into("<I", result, 8, 0x00010000)
        struct.pack_into("<I", result, 12, 92)
        struct.pack_into("<Q", result, 24, current)
        struct.pack_into("<Q", result, 32, backup)
        struct.pack_into("<Q", result, 40, 34)
        struct.pack_into("<Q", result, 48, total - 34)
        result[56:72] = disk_guid
        struct.pack_into("<Q", result, 72, entries_lba)
        struct.pack_into("<I", result, 80, 128)
        struct.pack_into("<I", result, 84, 128)
        struct.pack_into("<I", result, 88, entries_crc)
        struct.pack_into("<I", result, 16, crc32(result))
        return result

    mbr = bytearray(SECTOR)
    mbr[446:462] = (
        bytes([0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00])
        + struct.pack("<I", min(total - 1, 0xFFFFFFFF))
    )
    mbr[510:512] = b"\x55\xAA"

    parent = os.path.dirname(os.path.abspath(path))
    with tempfile.NamedTemporaryFile(prefix=".orange-disk-", dir=parent, delete=False) as disk:
        temp_path = disk.name
        try:
            disk.truncate(total * SECTOR)
            for offset, payload in (
                (0, mbr),
                (SECTOR, header(1, total - 1, 2)),
                (2 * SECTOR, entries),
                ((total - 33) * SECTOR, entries),
                ((total - 1) * SECTOR, header(total - 1, 1, total - 33)),
            ):
                disk.seek(offset)
                disk.write(payload)
            if citrus_path:
                with open(citrus_path, "rb") as citrus:
                    copy_sparse(citrus, disk, data_first * SECTOR)
        except BaseException:
            os.unlink(temp_path)
            raise
    try:
        os.replace(temp_path, path)
    except BaseException:
        os.unlink(temp_path)
        raise
    detail = f", CitrusFS at LBA {data_first}" if citrus_path else ""
    print(f"mkdisk: {path} ({size_mib} MiB, ESP {esp_mib} MiB + data{detail})")


if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "build/disk.img"
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    citrus = sys.argv[3] if len(sys.argv) > 3 else None
    build(output, size_mib=size, citrus_path=citrus)
