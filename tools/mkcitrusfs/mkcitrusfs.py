#!/usr/bin/env python3
"""Create a CitrusFS image and populate it from a host directory.

Implements docs/design/006-citrusfs.md. The kernel reader in
kernel/fs/citrusfs is written from the same document; if you change one,
change both.
"""

import os
import struct
import sys
import time
import uuid
import zlib

BLOCK_SIZE = 4096
INODE_SIZE = 256
MAGIC = b"CTRS"
VERSION = 1
JOURNAL_BLOCKS = 32
ROOT_INODE = 1
MAX_EXTENTS = 8

MODE_DIR = 0x4000
MODE_REG = 0x8000

DT_REG, DT_DIR, DT_LNK = 1, 2, 3


def align_up(v, a):
    return (v + a - 1) // a * a


class Builder:
    def __init__(self, total_blocks, inode_count):
        self.total_blocks = total_blocks
        self.inode_count = inode_count
        self.blocks = bytearray(total_blocks * BLOCK_SIZE)

        bitmap_blocks = align_up(total_blocks, BLOCK_SIZE * 8) // (BLOCK_SIZE * 8)
        ibitmap_blocks = align_up(inode_count, BLOCK_SIZE * 8) // (BLOCK_SIZE * 8)
        itable_blocks = align_up(inode_count * INODE_SIZE, BLOCK_SIZE) // BLOCK_SIZE

        self.journal_start = 2
        self.block_bitmap_start = self.journal_start + JOURNAL_BLOCKS
        self.inode_bitmap_start = self.block_bitmap_start + bitmap_blocks
        self.inode_table_start = self.inode_bitmap_start + ibitmap_blocks
        self.data_start = self.inode_table_start + itable_blocks

        self.next_free_block = self.data_start
        self.next_free_inode = ROOT_INODE
        self.used_blocks = self.data_start

    # ── raw block access ──────────────────────────────────────────────────
    def write_block(self, n, data):
        assert len(data) <= BLOCK_SIZE, "block overrun"
        off = n * BLOCK_SIZE
        self.blocks[off : off + len(data)] = data

    def alloc_blocks(self, count):
        start = self.next_free_block
        if start + count > self.total_blocks:
            raise SystemExit("mkcitrusfs: out of space")
        self.next_free_block += count
        self.used_blocks += count
        for b in range(start, start + count):
            self.set_block_used(b)
        return start

    def set_block_used(self, b):
        off = self.block_bitmap_start * BLOCK_SIZE + b // 8
        self.blocks[off] |= 1 << (b % 8)

    def set_inode_used(self, i):
        idx = i - 1
        off = self.inode_bitmap_start * BLOCK_SIZE + idx // 8
        self.blocks[off] |= 1 << (idx % 8)

    def alloc_inode(self):
        i = self.next_free_inode
        self.next_free_inode += 1
        if i > self.inode_count:
            raise SystemExit("mkcitrusfs: out of inodes")
        self.set_inode_used(i)
        return i

    # ── inodes ────────────────────────────────────────────────────────────
    def write_inode(self, ino, mode, size, extents, links=1):
        now = int(time.time() * 1_000_000_000)
        buf = bytearray(INODE_SIZE)
        struct.pack_into("<HHII", buf, 0, mode, links, 0, 0)
        struct.pack_into("<I", buf, 12, len(extents))
        struct.pack_into("<Q", buf, 16, size)
        for k, t in enumerate((24, 32, 40, 48)):
            struct.pack_into("<Q", buf, t, now)
        for k, (start, count) in enumerate(extents[:MAX_EXTENTS]):
            struct.pack_into("<QII", buf, 56 + k * 16, start, count, 0)
        struct.pack_into("<I", buf, 152, 0)
        struct.pack_into("<I", buf, 156, zlib.crc32(bytes(buf[:152])) & 0xFFFFFFFF)

        off = self.inode_table_start * BLOCK_SIZE + (ino - 1) * INODE_SIZE
        self.blocks[off : off + INODE_SIZE] = buf

    # ── files and directories ─────────────────────────────────────────────
    def add_file(self, data):
        ino = self.alloc_inode()
        if len(data) == 0:
            self.write_inode(ino, MODE_REG | 0o644, 0, [])
            return ino
        nblocks = align_up(len(data), BLOCK_SIZE) // BLOCK_SIZE
        start = self.alloc_blocks(nblocks)
        off = start * BLOCK_SIZE
        self.blocks[off : off + len(data)] = data
        self.write_inode(ino, MODE_REG | 0o644, len(data), [(start, nblocks)])
        return ino

    @staticmethod
    def dirent(ino, name, dtype):
        raw = name.encode()
        rec = align_up(8 + len(raw), 8)
        e = bytearray(rec)
        struct.pack_into("<IHBB", e, 0, ino, rec, len(raw), dtype)
        e[8 : 8 + len(raw)] = raw
        return bytes(e)

    def add_dir(self, entries, ino=None, parent=None):
        """entries: list of (name, inode, dtype). Returns the directory inode."""
        if ino is None:
            ino = self.alloc_inode()
        if parent is None:
            parent = ino

        all_entries = [(".", ino, DT_DIR), ("..", parent, DT_DIR)] + entries

        blocks = []
        cur = bytearray()
        for name, e_ino, dtype in all_entries:
            rec = self.dirent(e_ino, name, dtype)
            if len(cur) + len(rec) > BLOCK_SIZE:
                blocks.append(cur)
                cur = bytearray()
            cur += rec
        blocks.append(cur)

        # The final record in each block runs to the end of the block, so a
        # reader can walk by rec_len without needing a count.
        padded = []
        for b in blocks:
            b = bytearray(b)
            if b:
                # find the last record and extend its rec_len
                pos, last = 0, 0
                while pos < len(b):
                    rl = struct.unpack_from("<H", b, pos + 4)[0]
                    last = pos
                    pos += rl
                struct.pack_into("<H", b, last + 4, BLOCK_SIZE - last)
            padded.append(bytes(b) + b"\x00" * (BLOCK_SIZE - len(b)))

        start = self.alloc_blocks(len(padded))
        for k, b in enumerate(padded):
            self.write_block(start + k, b)

        self.write_inode(
            ino, MODE_DIR | 0o755, len(padded) * BLOCK_SIZE,
            [(start, len(padded))], links=2,
        )
        return ino

    # ── superblock ────────────────────────────────────────────────────────
    def finish(self):
        sb = bytearray(BLOCK_SIZE)
        sb[0:4] = MAGIC
        struct.pack_into("<III", sb, 4, VERSION, BLOCK_SIZE, self.inode_count)
        struct.pack_into("<Q", sb, 16, self.total_blocks)
        struct.pack_into("<Q", sb, 24, self.total_blocks - self.used_blocks)
        struct.pack_into("<I", sb, 32, self.inode_count - (self.next_free_inode - 1))
        struct.pack_into("<I", sb, 36, 0)  # state: clean
        struct.pack_into("<Q", sb, 40, self.journal_start)
        struct.pack_into("<I", sb, 48, JOURNAL_BLOCKS)
        struct.pack_into("<I", sb, 52, ROOT_INODE)
        struct.pack_into("<Q", sb, 56, self.block_bitmap_start)
        struct.pack_into("<Q", sb, 64, self.inode_bitmap_start)
        struct.pack_into("<Q", sb, 72, self.inode_table_start)
        struct.pack_into("<Q", sb, 80, self.data_start)
        sb[88:104] = uuid.uuid4().bytes_le
        struct.pack_into("<I", sb, 104, zlib.crc32(bytes(sb[:104])) & 0xFFFFFFFF)

        self.write_block(0, bytes(sb))
        self.write_block(1, bytes(sb))

        # Mark metadata blocks as used.
        for b in range(0, self.data_start):
            self.set_block_used(b)


def build_tree(builder, host_dir, parent=None):
    """Recursively add a host directory tree, returning its inode.

    The directory's own inode is allocated FIRST, before any of its contents.
    Allocation is sequential, so doing it the other way round would give the
    root directory some inode other than 1 and break the superblock contract.
    """
    dir_ino = builder.alloc_inode()
    if parent is None:
        parent = dir_ino

    entries = []
    for name in sorted(os.listdir(host_dir)):
        path = os.path.join(host_dir, name)
        if os.path.isdir(path):
            child = build_tree(builder, path, parent=dir_ino)
            entries.append((name, child, DT_DIR))
        elif os.path.isfile(path):
            with open(path, "rb") as f:
                ino = builder.add_file(f.read())
            entries.append((name, ino, DT_REG))

    builder.add_dir(entries, ino=dir_ino, parent=parent)
    return dir_ino


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: mkcitrusfs.py <out.img> <source-dir> [size-mib]")
    out, src = sys.argv[1], sys.argv[2]
    size_mib = int(sys.argv[3]) if len(sys.argv) > 3 else 32

    total_blocks = size_mib * 1024 * 1024 // BLOCK_SIZE
    b = Builder(total_blocks, inode_count=1024)

    root = build_tree(b, src)
    assert root == ROOT_INODE, f"root inode is {root}, expected {ROOT_INODE}"

    b.finish()
    with open(out, "wb") as f:
        f.write(bytes(b.blocks))

    used = b.used_blocks * BLOCK_SIZE
    print(
        f"mkcitrusfs: {out}  {size_mib} MiB, "
        f"{b.next_free_inode - 1} inodes, {used // 1024} KiB used"
    )


if __name__ == "__main__":
    main()
