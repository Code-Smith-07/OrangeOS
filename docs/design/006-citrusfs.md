# CitrusFS — on-disk format

Version 1. Little-endian throughout. Block size 4096 bytes (8 sectors).

This document is the contract between `tools/mkcitrusfs` (host) and
`kernel/fs/citrusfs` (kernel). Both are written from it; neither may change
without the other.

## Layout

```
  block 0                 superblock
  block 1                 superblock backup (identical)
  blocks 2 .. 33          journal (32 blocks)
  block_bitmap_start ..   block allocation bitmap, 1 bit per block
  inode_bitmap_start ..   inode allocation bitmap, 1 bit per inode
  inode_table_start ..    inode table, 256 bytes per inode
  data_start .. end       data blocks
```

## Superblock (block 0, 4096 bytes)

| Offset | Size | Field |
|--------|------|-------|
| 0  | 4  | magic `"CTRS"` |
| 4  | 4  | version (1) |
| 8  | 4  | block_size (4096) |
| 12 | 4  | inode_count |
| 16 | 8  | total_blocks |
| 24 | 8  | free_blocks |
| 32 | 4  | free_inodes |
| 36 | 4  | state — 0 clean, 1 dirty |
| 40 | 8  | journal_start |
| 48 | 4  | journal_blocks |
| 52 | 4  | root_inode (always 1) |
| 56 | 8  | block_bitmap_start |
| 64 | 8  | inode_bitmap_start |
| 72 | 8  | inode_table_start |
| 80 | 8  | data_start |
| 88 | 16 | uuid |
| 104| 4  | checksum (CRC32 of bytes 0..104) |

## Inode (256 bytes)

Inode numbers are 1-based; inode 1 is the root directory.

| Offset | Size | Field |
|--------|------|-------|
| 0  | 2  | mode — see below |
| 2  | 2  | links |
| 4  | 4  | uid |
| 8  | 4  | gid |
| 12 | 4  | extent_count (0..8) |
| 16 | 8  | size in bytes |
| 24 | 8  | atime (ns since epoch) |
| 32 | 8  | mtime |
| 40 | 8  | ctime |
| 48 | 8  | btime |
| 56 | 96 | extents — 8 × { start_block u64, block_count u32, pad u32 } |
| 152| 4  | flags |
| 156| 4  | checksum |
| 160| 96 | reserved |

`mode` high nibble is the file type: `0x8` regular, `0x4` directory,
`0xA` symlink. Low 12 bits are permissions.

### Why extents

A 1 GiB contiguous file is one extent record, not 262,144 block pointers.
Eight inline extents cover any file that is not badly fragmented; an extent
tree for the rest is future work, and `extent_count == 8` with more data
remaining is currently an error rather than silent truncation.

## Directory entries

A directory's data blocks hold packed variable-length records. A record never
straddles a block boundary; the last record in a block has `rec_len` running
to the end of the block.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | inode (0 means a free/unused record) |
| 4 | 2 | rec_len — total record length, multiple of 8 |
| 6 | 1 | name_len |
| 7 | 1 | type — 1 regular, 2 directory, 3 symlink |
| 8 | name_len | name bytes, not null terminated |

Every directory begins with `.` and `..`.

## Journal

Write-ahead log for metadata, so a crash never leaves a half-updated
filesystem. A transaction is:

```
  descriptor block   magic "CTJD", sequence, block_count,
                     then block_count target block numbers (u64 each)
  data blocks        block_count blocks, in the same order
  commit block       magic "CTJC", same sequence
```

Recovery on mount: scan from `journal_start`. If a descriptor is followed by
its matching commit, replay its data blocks to their targets. A transaction
without a commit is discarded — the crash happened mid-write and none of it
counts. Replay is idempotent, so an interrupted replay is safe to repeat.
