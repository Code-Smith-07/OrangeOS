# /data: a persistent volume on a data disk

Status: implemented 2026-09-28 (B11 for the browser). Code:
`kernel/fs/tmpfs/persist.zig`, `kernel/fs/tmpfs/tmpfs.zig` (volumes, save and
load), `tools/mkdata.py`. Tests: `tools/data_volume_smoke.py`,
`tools/browser_profile_smoke.py`.

## 1. Why this shape

Programs need a place whose files outlive a reboot: first the browser's
cookies, local storage and databases. The root filesystem (CitrusFS) is
read-only in the kernel, and a writable on-disk filesystem is a larger
project (allocation, journaling, fsck). What the browser needs now is a
small, crash-safe store with POSIX file semantics.

So `/data` is a second tmpfs volume, the same in-memory tree as `/tmp` with
its own quota, that is loaded from a separate data disk at boot and saved
back to it as a whole. Everything a program does (open, write, rename,
unlink, truncate, mmap, record locks) behaves as on `/tmp`, because it is
the same code.

The data disk is separate from the system disk: rebuilding or replacing the
system never touches saved data (`scripts/mkdisk.sh` runs
`tools/mkdata.py --keep`), and the preview can run the system disk as a
snapshot while `/data` persists.

## 2. Disk format

In 4 KiB blocks, on a whole disk (not a partition):

| Block | Contents |
|---|---|
| 0 | superblock: `OrangeOS data v1` (16 bytes), version 1 (u32), 0 (u32), slot size in blocks *n* (u64), CRC-32 of the preceding 32 bytes |
| 1 … *n* | slot 0: header block, then payload |
| 1+*n* … 2*n* | slot 1 |

Slot header: `ORDSLOT1`, generation (u64, 1 upwards), payload length (u64),
payload CRC-32, header CRC-32 (of the preceding 28 bytes). All little
endian; CRC-32 is IEEE (zlib's).

Payload: the tree, depth first. `1 len name` enters a directory, `3` leaves
it, `2 len name size bytes` is a file (holes written as zeros and restored as
holes), `0` ends. Loading rejects empty or oversized names, `/`, `.`, `..`,
duplicates, sizes over tmpfs's limit, depth over 128 and truncated streams,
and then leaves the volume empty rather than half built.

## 3. Saving

1. Under the tmpfs lock: if the volume changed (any change sets `dirty`; a
   file with a writable shared mapping counts as changed), copy the payload
   into freshly allocated pages and clear `dirty`. No disk I/O under the
   lock.
2. Write the payload into the slot not holding the newest save; flush the
   disk's write cache (ATA FLUSH CACHE EXT).
3. Write that slot's header with the next generation; flush again.

On failure the volume is marked dirty again. Loading takes the valid slot
(magic, header CRC, payload CRC, parse) with the highest generation, and
falls back to the other one. A crash or power loss at any point leaves
either the new save or the previous one, never a mixture.

Saves happen when a program asks, synchronously: `fsync`, `fdatasync` and
`syncfs` on a `/data` descriptor, and `sync` (native call 164, `fs_sync`).
A kernel thread also saves every 2 s while there are unsaved changes, for
programs that never ask.

## 4. Limits

- Each save writes the whole volume, so its cost grows with the volume
  (about 3 MiB per `fsync` in the test). Fine for a browser profile; the
  browser's cache stays in `/tmp`. An incremental format is the next step if
  volumes grow.
- The volume lives in memory: its quota is 7/8 of a slot (the rest is room
  for the records), and it counts against physical memory like `/tmp`.
- `rename` between `/tmp` and `/data` is `EXDEV`, as between filesystems.
- Without a data disk `/data` is a read-only directory of the root, and the
  browser keeps its profile in `/tmp`.
