//! Virtual filesystem layer.
//!
//! Path resolution walks components from the root mount, one lookup at a time.
//! There is no dentry cache yet — every resolution re-reads directory blocks.
//! That is a deliberate Phase 5 simplification: caching before the semantics
//! are settled makes invalidation bugs that look like filesystem corruption.

const std = @import("std");
const block = @import("../../drivers/block/block.zig");
const citrusfs = @import("../citrusfs/citrusfs.zig");
const console = @import("../../console.zig");

pub const Error = error{
    NotMounted,
    NotFound,
    NotDirectory,
    NotFile,
    NameTooLong,
    TooManyOpen,
    BadFd,
    IoError,
};

pub const MAX_PATH = 256;
pub const MAX_OPEN = 32;

pub const Node = struct {
    inode_num: u32,
    inode: citrusfs.Inode,

    pub fn isDir(self: *const Node) bool {
        return self.inode.isDir();
    }

    pub fn size(self: *const Node) u64 {
        return self.inode.size;
    }
};

var root_fs: citrusfs.Fs = undefined;
var mounted: bool = false;

pub const OpenFile = struct {
    used: bool = false,
    node: Node = undefined,
    offset: u64 = 0,
};

var open_files: [MAX_OPEN]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN;

pub fn mountRoot(dev: *block.Device) !void {
    try citrusfs.mount(dev, &root_fs);
    mounted = true;
}

pub fn isMounted() bool {
    return mounted;
}

pub fn superblock() *const citrusfs.Superblock {
    return &root_fs.sb;
}

/// Resolve an absolute path to a node.
pub fn resolve(path: []const u8) Error!Node {
    if (!mounted) return Error.NotMounted;
    if (path.len == 0 or path[0] != '/') return Error.NotFound;
    if (path.len > MAX_PATH) return Error.NameTooLong;

    var node: Node = undefined;
    node.inode_num = root_fs.sb.root_inode;
    root_fs.readInode(node.inode_num, &node.inode) catch return Error.IoError;

    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;
        if (!node.isDir()) return Error.NotDirectory;

        const child = root_fs.lookup(&node.inode, component) catch |e| return switch (e) {
            citrusfs.Error.NotFound => Error.NotFound,
            citrusfs.Error.NotDirectory => Error.NotDirectory,
            else => Error.IoError,
        };

        node.inode_num = child;
        root_fs.readInode(child, &node.inode) catch return Error.IoError;
    }

    return node;
}

/// Read from a node at an explicit offset.
pub fn readAt(node: *const Node, offset: u64, buf: []u8) Error!usize {
    if (node.isDir()) return Error.NotFile;
    return root_fs.readFile(&node.inode, offset, buf) catch Error.IoError;
}

// ── File descriptors ─────────────────────────────────────────────────────────
// A single global table for now. It becomes per-process in Phase 6b, when fork
// has to decide what a child inherits.
//
// Descriptors start at 3. 0, 1 and 2 belong to stdin, stdout and stderr, and
// handing a file descriptor 0 makes read() route to the console instead of the
// file - which presents as a process hanging forever on a disk read.

/// First descriptor available for files.
pub const FD_BASE: i32 = 3;

pub fn open(path: []const u8) Error!i32 {
    const node = try resolve(path);

    var i: usize = 0;
    while (i < MAX_OPEN) : (i += 1) {
        if (open_files[i].used) continue;
        open_files[i] = .{ .used = true, .node = node, .offset = 0 };
        return @as(i32, @intCast(i)) + FD_BASE;
    }
    return Error.TooManyOpen;
}

pub fn close(fd: i32) Error!void {
    const i = try checkFd(fd);
    open_files[i].used = false;
}

pub fn read(fd: i32, buf: []u8) Error!usize {
    const i = try checkFd(fd);
    const f = &open_files[i];
    const n = try readAt(&f.node, f.offset, buf);
    f.offset += n;
    return n;
}

pub fn seek(fd: i32, offset: u64) Error!void {
    const i = try checkFd(fd);
    open_files[i].offset = offset;
}

pub fn statSize(fd: i32) Error!u64 {
    const i = try checkFd(fd);
    return open_files[i].node.size();
}

fn checkFd(fd: i32) Error!usize {
    if (fd < FD_BASE) return Error.BadFd; // 0/1/2 are the standard streams
    const i: i32 = fd - FD_BASE;
    if (i >= MAX_OPEN) return Error.BadFd;
    const idx: usize = @intCast(i);
    if (!open_files[idx].used) return Error.BadFd;
    return idx;
}

// ── Directory listing ────────────────────────────────────────────────────────

const ListCtx = struct {
    indent: usize,
};

fn printEntry(ctx: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool {
    const c: *ListCtx = @ptrCast(@alignCast(ctx));
    _ = c;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return true;
    console.print("         {s}{s}  (inode {d})\n", .{
        name,
        if (dtype == 2) "/" else "",
        ino,
    });
    return true;
}

/// Print a directory's contents — boot diagnostics, until there is a shell.
pub fn listDir(path: []const u8) Error!void {
    const node = try resolve(path);
    if (!node.isDir()) return Error.NotDirectory;

    console.print("[info] {s}:\n", .{path});
    var ctx = ListCtx{ .indent = 0 };
    root_fs.iterate(&node.inode, &ctx, printEntry) catch return Error.IoError;
}

/// Walk a directory, handing each entry to `visit`.
pub fn iterateDir(
    path: []const u8,
    ctx: *anyopaque,
    visit: *const fn (ctx: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool,
) Error!void {
    const node = try resolve(path);
    if (!node.isDir()) return Error.NotDirectory;
    root_fs.iterate(&node.inode, ctx, visit) catch return Error.IoError;
}

/// Read a whole file into `buf`. Returns the byte count.
pub fn readFileInto(path: []const u8, buf: []u8) Error!usize {
    const node = try resolve(path);
    if (node.isDir()) return Error.NotFile;
    if (node.size() > buf.len) return Error.IoError;
    return readAt(&node, 0, buf[0..@intCast(node.size())]);
}
