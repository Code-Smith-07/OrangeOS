//! CitrusFS — read path.
//!
//! Implements docs/design/006-citrusfs.md. Any change here must be mirrored in
//! tools/mkcitrusfs/mkcitrusfs.py, which writes the same structures.
//!
//! Structures are declared `align(1)` and read through packed offsets: they
//! come off a disk and carry no alignment guarantee.

const std = @import("std");
const block = @import("../../drivers/block/block.zig");
const heap = @import("../../mm/heap.zig");
const console = @import("../../console.zig");

pub const BLOCK_SIZE: usize = 4096;
pub const INODE_SIZE: usize = 256;
pub const ROOT_INODE: u32 = 1;
pub const MAX_EXTENTS: usize = 8;

const SECTORS_PER_BLOCK = BLOCK_SIZE / block.SECTOR_SIZE;

pub const Error = error{
    BadMagic,
    BadVersion,
    NotFound,
    NotDirectory,
    NotFile,
    IoError,
    TooFragmented,
    NameTooLong,
};

pub const FileType = enum(u4) {
    regular = 0x8,
    directory = 0x4,
    symlink = 0xA,
    unknown = 0,
};

pub const Superblock = extern struct {
    magic: [4]u8,
    version: u32 align(1),
    block_size: u32 align(1),
    inode_count: u32 align(1),
    total_blocks: u64 align(1),
    free_blocks: u64 align(1),
    free_inodes: u32 align(1),
    state: u32 align(1),
    journal_start: u64 align(1),
    journal_blocks: u32 align(1),
    root_inode: u32 align(1),
    block_bitmap_start: u64 align(1),
    inode_bitmap_start: u64 align(1),
    inode_table_start: u64 align(1),
    data_start: u64 align(1),
    uuid: [16]u8,
    checksum: u32 align(1),
};

pub const Extent = extern struct {
    start_block: u64 align(1),
    block_count: u32 align(1),
    pad: u32 align(1),
};

pub const Inode = extern struct {
    mode: u16 align(1),
    links: u16 align(1),
    uid: u32 align(1),
    gid: u32 align(1),
    extent_count: u32 align(1),
    size: u64 align(1),
    atime: u64 align(1),
    mtime: u64 align(1),
    ctime: u64 align(1),
    btime: u64 align(1),
    extents: [MAX_EXTENTS]Extent,
    flags: u32 align(1),
    checksum: u32 align(1),

    pub fn fileType(self: *const Inode) FileType {
        return switch (@as(u4, @truncate(self.mode >> 12))) {
            0x8 => .regular,
            0x4 => .directory,
            0xA => .symlink,
            else => .unknown,
        };
    }

    pub fn isDir(self: *const Inode) bool {
        return self.fileType() == .directory;
    }
};

pub const DirEntry = extern struct {
    inode: u32 align(1),
    rec_len: u16 align(1),
    name_len: u8,
    type: u8,
};

pub const Fs = struct {
    dev: *block.Device,
    sb: Superblock,

    /// One block of scratch, so callers do not each need their own.
    scratch: [BLOCK_SIZE]u8 align(8) = undefined,

    pub fn readBlock(self: *Fs, index: u64, buf: []u8) Error!void {
        if (buf.len < BLOCK_SIZE) return Error.IoError;
        self.dev.read(index * SECTORS_PER_BLOCK, SECTORS_PER_BLOCK, buf.ptr) catch {
            return Error.IoError;
        };
    }

    pub fn readInode(self: *Fs, ino: u32, out: *Inode) Error!void {
        if (ino == 0 or ino > self.sb.inode_count) return Error.NotFound;

        const per_block = BLOCK_SIZE / INODE_SIZE;
        const index = ino - 1;
        const blk = self.sb.inode_table_start + index / per_block;
        const offset = (index % per_block) * INODE_SIZE;

        var buf: [BLOCK_SIZE]u8 align(8) = undefined;
        try self.readBlock(blk, &buf);

        const src: *align(1) const Inode = @ptrCast(buf[offset..].ptr);
        out.* = src.*;
    }

    /// Map a file offset to the block holding it, walking the extent list.
    fn blockForOffset(self: *Fs, inode: *const Inode, offset: u64) ?u64 {
        _ = self;
        const target = offset / BLOCK_SIZE;
        var seen: u64 = 0;
        var i: usize = 0;
        while (i < inode.extent_count and i < MAX_EXTENTS) : (i += 1) {
            const e = inode.extents[i];
            if (target < seen + e.block_count) {
                return e.start_block + (target - seen);
            }
            seen += e.block_count;
        }
        return null;
    }

    /// Read up to `buf.len` bytes from `offset`. Returns bytes read.
    pub fn readFile(self: *Fs, inode: *const Inode, offset: u64, buf: []u8) Error!usize {
        if (offset >= inode.size) return 0;

        const remaining = inode.size - offset;
        const want = @min(buf.len, remaining);

        var done: usize = 0;
        var blkbuf: [BLOCK_SIZE]u8 align(8) = undefined;

        while (done < want) {
            const pos = offset + done;
            const blk = self.blockForOffset(inode, pos) orelse return Error.IoError;
            try self.readBlock(blk, &blkbuf);

            const in_block = pos % BLOCK_SIZE;
            const chunk = @min(BLOCK_SIZE - in_block, want - done);
            @memcpy(buf[done .. done + chunk], blkbuf[in_block .. in_block + chunk]);
            done += chunk;
        }

        return done;
    }

    /// Find `name` in a directory inode. Returns its inode number.
    pub fn lookup(self: *Fs, dir: *const Inode, name: []const u8) Error!u32 {
        if (!dir.isDir()) return Error.NotDirectory;
        if (name.len > 255) return Error.NameTooLong;

        var blkbuf: [BLOCK_SIZE]u8 align(8) = undefined;
        var pos: u64 = 0;

        while (pos < dir.size) : (pos += BLOCK_SIZE) {
            const blk = self.blockForOffset(dir, pos) orelse break;
            try self.readBlock(blk, &blkbuf);

            var off: usize = 0;
            while (off + @sizeOf(DirEntry) <= BLOCK_SIZE) {
                const e: *align(1) const DirEntry = @ptrCast(blkbuf[off..].ptr);
                if (e.rec_len < @sizeOf(DirEntry) or off + e.rec_len > BLOCK_SIZE) break;

                if (e.inode != 0 and e.name_len == name.len) {
                    const entry_name = blkbuf[off + 8 ..][0..e.name_len];
                    if (std.mem.eql(u8, entry_name, name)) return e.inode;
                }
                off += e.rec_len;
            }
        }

        return Error.NotFound;
    }

    /// Iterate a directory, calling `visit` per entry. Stops if it returns false.
    pub fn iterate(
        self: *Fs,
        dir: *const Inode,
        ctx: *anyopaque,
        visit: *const fn (ctx: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool,
    ) Error!void {
        if (!dir.isDir()) return Error.NotDirectory;

        var blkbuf: [BLOCK_SIZE]u8 align(8) = undefined;
        var pos: u64 = 0;

        while (pos < dir.size) : (pos += BLOCK_SIZE) {
            const blk = self.blockForOffset(dir, pos) orelse break;
            try self.readBlock(blk, &blkbuf);

            var off: usize = 0;
            while (off + @sizeOf(DirEntry) <= BLOCK_SIZE) {
                const e: *align(1) const DirEntry = @ptrCast(blkbuf[off..].ptr);
                if (e.rec_len < @sizeOf(DirEntry) or off + e.rec_len > BLOCK_SIZE) break;

                if (e.inode != 0 and e.name_len > 0) {
                    const name = blkbuf[off + 8 ..][0..e.name_len];
                    if (!visit(ctx, name, e.inode, e.type)) return;
                }
                off += e.rec_len;
            }
        }
    }
};

/// Read the superblock and validate it.
pub fn mount(dev: *block.Device, fs: *Fs) Error!void {
    fs.dev = dev;

    var buf: [BLOCK_SIZE]u8 align(8) = undefined;
    dev.read(0, SECTORS_PER_BLOCK, &buf) catch return Error.IoError;

    const sb: *align(1) const Superblock = @ptrCast(&buf);
    if (!std.mem.eql(u8, &sb.magic, "CTRS")) return Error.BadMagic;
    if (sb.version != 1) return Error.BadVersion;
    if (sb.block_size != BLOCK_SIZE) return Error.BadVersion;

    fs.sb = sb.*;
}
