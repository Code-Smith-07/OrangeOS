//! Virtual filesystem layer.
//!
//! Two filesystems share one namespace: the read-only CitrusFS root, and a
//! writable in-memory tmpfs mounted at /tmp. Every path is normalized first
//! (no empty, "." or ".." components), then dispatched by its mount.
//!
//! CitrusFS resolution walks components from the root, one lookup at a time.
//! There is no dentry cache yet — every resolution re-reads directory blocks.
//! That is a deliberate Phase 5 simplification: caching before the semantics
//! are settled makes invalidation bugs that look like filesystem corruption.
//!
//! A `Node` from `resolve` may hold a tmpfs inode reference; whoever receives
//! one must pass it to `release` when done. CitrusFS nodes are plain values.

const std = @import("std");
const block = @import("../../drivers/block/block.zig");
const citrusfs = @import("../citrusfs/citrusfs.zig");
const tmpfs = @import("../tmpfs/tmpfs.zig");
const console = @import("../../console.zig");
const spinlock = @import("../../sync/spinlock.zig");

pub const Error = error{
    NotMounted,
    NotFound,
    NotDirectory,
    NotFile,
    IsDirectory,
    NameTooLong,
    TooManyOpen,
    BadFd,
    IoError,
    ReadOnly,
    Exists,
    NotEmpty,
    NoSpace,
    CrossDevice,
    InvalidArgument,
    FileTooBig,
    Busy,
    // Descriptor operations on pipes and other non-file objects.
    WouldBlock,
    BrokenPipe,
    Interrupted,
    NotSeekable,
    OutOfMemory,
    MessageTooLong,
    NotPermitted,
};

pub const MAX_PATH = 256;

/// Where the tmpfs is mounted.
const TMP_MOUNT = "/tmp";

pub const Node = union(enum) {
    citrus: Citrus,
    tmp: *tmpfs.Inode,

    pub const Citrus = struct { inode_num: u32, inode: citrusfs.Inode };

    pub fn isDir(self: *const Node) bool {
        return switch (self.*) {
            .citrus => |c| c.inode.isDir(),
            .tmp => |t| tmpfs.isDir(t),
        };
    }

    pub fn size(self: *const Node) u64 {
        return switch (self.*) {
            .citrus => |c| c.inode.size,
            .tmp => |t| tmpfs.size(t),
        };
    }

    pub fn writable(self: *const Node) bool {
        return self.* == .tmp;
    }
};

var root_fs: citrusfs.Fs = undefined;
var mounted: bool = false;

/// open() flags, as the system call takes them. Neither READ nor WRITE
/// means read-only.
pub const OPEN_READ: u32 = 1;
pub const OPEN_WRITE: u32 = 2;
pub const OPEN_CREATE: u32 = 4;
pub const OPEN_EXCLUSIVE: u32 = 8;
pub const OPEN_TRUNCATE: u32 = 16;
pub const OPEN_APPEND: u32 = 32;
pub const OPEN_DIRECTORY: u32 = 64;
/// Status flag: operations that would block fail with WouldBlock instead.
pub const OPEN_NONBLOCK: u32 = 128;
/// Descriptor flag: not inherited by programs this one starts.
pub const OPEN_CLOEXEC: u32 = 256;
pub const OPEN_KNOWN: u32 = 511;

pub fn mountRoot(dev: *block.Device) !void {
    try citrusfs.mount(dev, &root_fs);
    tmpfs.init();
    mounted = true;
}

pub fn isMounted() bool {
    return mounted;
}

pub fn superblock() *const citrusfs.Superblock {
    return &root_fs.sb;
}

// ── Paths ────────────────────────────────────────────────────────────────────

/// The canonical form of an absolute path: components joined by single
/// slashes, with "." dropped and ".." removing the previous component ("/.."
/// is "/"). The result lives in `out`.
pub fn normalize(path: []const u8, out: *[MAX_PATH]u8) Error![]const u8 {
    if (path.len == 0 or path[0] != '/') return Error.NotFound;
    // The input may be longer than MAX_PATH (a directory joined with a
    // relative path); the canonical result may not.
    var len: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            len = std.mem.lastIndexOfScalar(u8, out[0..len], '/') orelse 0;
            continue;
        }
        if (len + 1 + component.len > MAX_PATH) return Error.NameTooLong;
        out[len] = '/';
        @memcpy(out[len + 1 .. len + 1 + component.len], component);
        len += 1 + component.len;
    }
    if (len == 0) {
        out[0] = '/';
        len = 1;
    }
    return out[0..len];
}

/// The part of a normalized path inside the tmpfs ("" for the mount point),
/// or null when the path is on the root filesystem.
fn tmpRelative(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, TMP_MOUNT)) return null;
    if (path.len == TMP_MOUNT.len) return "";
    if (path[TMP_MOUNT.len] != '/') return null;
    return path[TMP_MOUNT.len + 1 ..];
}

fn tmpError(e: tmpfs.Error) Error {
    return switch (e) {
        tmpfs.Error.NotFound => Error.NotFound,
        tmpfs.Error.NotDirectory => Error.NotDirectory,
        tmpfs.Error.IsDirectory => Error.IsDirectory,
        tmpfs.Error.Exists => Error.Exists,
        tmpfs.Error.NotEmpty => Error.NotEmpty,
        tmpfs.Error.NoSpace => Error.NoSpace,
        tmpfs.Error.NameTooLong => Error.NameTooLong,
        tmpfs.Error.InvalidArgument => Error.InvalidArgument,
        tmpfs.Error.FileTooBig => Error.FileTooBig,
        tmpfs.Error.Sealed => Error.NotPermitted,
        tmpfs.Error.Busy => Error.Busy,
    };
}

fn resolveCitrus(path: []const u8) Error!Node {
    var node: Node.Citrus = undefined;
    node.inode_num = root_fs.sb.root_inode;
    root_fs.readInode(node.inode_num, &node.inode) catch return Error.IoError;

    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        if (!node.inode.isDir()) return Error.NotDirectory;
        const child = root_fs.lookup(&node.inode, component) catch |e| return switch (e) {
            citrusfs.Error.NotFound => Error.NotFound,
            citrusfs.Error.NotDirectory => Error.NotDirectory,
            else => Error.IoError,
        };
        node.inode_num = child;
        root_fs.readInode(child, &node.inode) catch return Error.IoError;
    }
    return .{ .citrus = node };
}

/// Resolve an absolute path to a node. Pass the result to `release`.
pub fn resolve(path: []const u8) Error!Node {
    if (!mounted) return Error.NotMounted;
    var buffer: [MAX_PATH]u8 = undefined;
    const canonical = try normalize(path, &buffer);
    if (tmpRelative(canonical)) |relative| {
        return .{ .tmp = tmpfs.lookup(relative) catch |e| return tmpError(e) };
    }
    return resolveCitrus(canonical);
}

/// Drop the reference a node carries.
pub fn release(node: Node) void {
    switch (node) {
        .citrus => {},
        .tmp => |t| tmpfs.release(t),
    }
}

/// An additional reference to a node already held.
pub fn retain(node: Node) Node {
    switch (node) {
        .citrus => {},
        .tmp => |t| tmpfs.retain(t),
    }
    return node;
}

/// Read from a node at an explicit offset.
pub fn readAt(node: *const Node, offset: u64, buf: []u8) Error!usize {
    if (node.isDir()) return Error.NotFile;
    return switch (node.*) {
        .citrus => |*c| root_fs.readFile(&c.inode, offset, buf) catch Error.IoError,
        .tmp => |t| tmpfs.read(t, offset, buf) catch |e| tmpError(e),
    };
}

// ── Namespace changes ───────────────────────────────────────────────────────
// Only the tmpfs is writable. A change aimed at the root filesystem reports
// what POSIX would: EEXIST for something already there, EROFS otherwise.

fn readOnlyChange(canonical: []const u8, exists_is_error: bool) Error {
    const node = resolveCitrus(canonical) catch |e| return if (e == Error.NotFound) Error.ReadOnly else e;
    release(node);
    return if (exists_is_error) Error.Exists else Error.ReadOnly;
}

pub fn mkdir(path: []const u8) Error!void {
    if (!mounted) return Error.NotMounted;
    var buffer: [MAX_PATH]u8 = undefined;
    const canonical = try normalize(path, &buffer);
    const relative = tmpRelative(canonical) orelse return readOnlyChange(canonical, true);
    if (relative.len == 0) return Error.Exists;
    tmpfs.mkdir(relative) catch |e| return tmpError(e);
}

/// unlink (`directory` false) or rmdir.
pub fn remove(path: []const u8, directory: bool) Error!void {
    if (!mounted) return Error.NotMounted;
    var buffer: [MAX_PATH]u8 = undefined;
    const canonical = try normalize(path, &buffer);
    const relative = tmpRelative(canonical) orelse return readOnlyChange(canonical, false);
    if (relative.len == 0) return Error.Busy;
    tmpfs.remove(relative, directory) catch |e| return tmpError(e);
}

pub fn rename(from: []const u8, to: []const u8) Error!void {
    if (!mounted) return Error.NotMounted;
    var from_buffer: [MAX_PATH]u8 = undefined;
    var to_buffer: [MAX_PATH]u8 = undefined;
    const source = try normalize(from, &from_buffer);
    const target = try normalize(to, &to_buffer);
    const source_tmp = tmpRelative(source);
    const target_tmp = tmpRelative(target);
    if (source_tmp == null and target_tmp == null) return readOnlyChange(source, false);
    if (source_tmp == null or target_tmp == null) return Error.CrossDevice;
    if (source_tmp.?.len == 0 or target_tmp.?.len == 0) return Error.Busy;
    tmpfs.rename(source_tmp.?, target_tmp.?) catch |e| return tmpError(e);
}

pub const Usage = struct { total_bytes: u64, free_bytes: u64, read_only: bool };

/// Capacity of the filesystem holding `path`.
pub fn usage(path: []const u8) Error!Usage {
    const node = try resolve(path);
    defer release(node);
    return switch (node) {
        .tmp => blk: {
            const u = tmpfs.usage();
            break :blk .{ .total_bytes = u.total_bytes, .free_bytes = u.free_bytes, .read_only = false };
        },
        .citrus => .{
            .total_bytes = root_fs.sb.total_blocks * root_fs.sb.block_size,
            .free_bytes = 0,
            .read_only = true,
        },
    };
}

// ── Nodes as open files ──────────────────────────────────────────────────────
// Descriptor tables and open file descriptions live in fs/fd.zig; these are
// the node-level operations they use.

/// Resolve `path` for open(): create, truncate and permission checks per
/// `flags`. Pass the result to `release`.
pub fn openNode(path: []const u8, flags: u32) Error!Node {
    if (!mounted) return Error.NotMounted;
    var buffer: [MAX_PATH]u8 = undefined;
    const canonical = try normalize(path, &buffer);
    const changes = flags & (OPEN_WRITE | OPEN_TRUNCATE | OPEN_APPEND) != 0;
    const node: Node = if (tmpRelative(canonical)) |relative|
        .{ .tmp = tmpfs.open(relative, flags & OPEN_CREATE != 0, flags & OPEN_EXCLUSIVE != 0) catch |e| return tmpError(e) }
    else blk: {
        const found = resolveCitrus(canonical) catch |e| {
            if (e == Error.NotFound and flags & OPEN_CREATE != 0) return Error.ReadOnly;
            return e;
        };
        if (flags & OPEN_CREATE != 0 and flags & OPEN_EXCLUSIVE != 0) return Error.Exists;
        break :blk found;
    };
    errdefer release(node);
    if (node.isDir()) {
        if (changes) return Error.IsDirectory;
    } else if (flags & OPEN_DIRECTORY != 0) return Error.NotDirectory;
    if (changes and !node.writable()) return Error.ReadOnly;
    if (flags & OPEN_TRUNCATE != 0 and flags & OPEN_WRITE != 0) {
        tmpfs.truncate(node.tmp, 0) catch |e| return tmpError(e);
    }
    return node;
}

/// Write to a tmpfs node at `offset`, or at its end when null (append).
pub fn writeNode(node: *const Node, offset: ?u64, data: []const u8) Error!tmpfs.Written {
    return switch (node.*) {
        .tmp => |t| tmpfs.write(t, offset, data) catch |e| tmpError(e),
        .citrus => Error.ReadOnly,
    };
}

pub fn truncateNode(node: *const Node, length: u64) Error!void {
    switch (node.*) {
        .tmp => |t| tmpfs.truncate(t, length) catch |e| return tmpError(e),
        .citrus => return Error.ReadOnly,
    }
}

// ── Directory listing ────────────────────────────────────────────────────────

pub fn iterateNode(
    node: *const Node,
    ctx: *anyopaque,
    visit: *const fn (ctx: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool,
) Error!void {
    if (!node.isDir()) return Error.NotDirectory;
    switch (node.*) {
        .citrus => |*c| root_fs.iterate(&c.inode, ctx, visit) catch return Error.IoError,
        .tmp => |t| tmpfs.iterate(t, ctx, visit) catch |e| return tmpError(e),
    }
}

fn printEntry(ctx: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool {
    _ = ctx;
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
    defer release(node);
    if (!node.isDir()) return Error.NotDirectory;
    console.print("[info] {s}:\n", .{path});
    var unused: u8 = 0;
    try iterateNode(&node, &unused, printEntry);
}

/// Walk a directory, handing each entry to `visit`.
pub fn iterateDir(
    path: []const u8,
    ctx: *anyopaque,
    visit: *const fn (ctx: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool,
) Error!void {
    const node = try resolve(path);
    defer release(node);
    try iterateNode(&node, ctx, visit);
}

/// Read a whole file into `buf`. Returns the byte count.
pub fn readFileInto(path: []const u8, buf: []u8) Error!usize {
    const node = try resolve(path);
    defer release(node);
    if (node.isDir()) return Error.NotFile;
    const length = node.size();
    if (length > buf.len) return Error.IoError;
    return readAt(&node, 0, buf[0..@intCast(length)]);
}
