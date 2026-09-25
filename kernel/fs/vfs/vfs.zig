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
};

pub const MAX_PATH = 256;
pub const MAX_OPEN = 32;

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
const OPEN_KNOWN: u32 = 127;

pub const OpenFile = struct {
    used: bool = false,
    node: Node = undefined,
    offset: u64 = 0,
    /// OPEN_READ/OPEN_WRITE/OPEN_APPEND as granted.
    mode: u32 = 0,
    /// Advanced on every open of this slot, so a read that ran without the
    /// table lock can tell whether its descriptor was closed and reused.
    generation: u32 = 0,
};

/// Descriptors are owned by one process and shared by its threads. The lock
/// is never held across disk I/O or node release.
pub const FileTable = struct {
    lock: spinlock.SpinLock = .{},
    entries: [MAX_OPEN]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN,

    pub fn clear(self: *FileTable) void {
        for (&self.entries) |*entry| {
            const node = blk: {
                const state = spinlock.acquireIrqSave(&self.lock);
                defer spinlock.releaseIrqRestore(&self.lock, state);
                if (!entry.used) continue;
                entry.used = false;
                break :blk entry.node;
            };
            release(node);
        }
    }
};

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
    if (path.len > MAX_PATH) return Error.NameTooLong;
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

// ── File descriptors ─────────────────────────────────────────────────────────
// The table is per process. A future fork/exec ABI must decide inheritance
// and shared offsets explicitly; the current spawn starts with an empty table.
//
// Descriptors start at 3. 0, 1 and 2 belong to stdin, stdout and stderr, and
// handing a file descriptor 0 makes read() route to the console instead of the
// file - which presents as a process hanging forever on a disk read.

/// First descriptor available for files.
pub const FD_BASE: i32 = 3;

fn openNode(path: []const u8, flags: u32) Error!Node {
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

pub fn open(table: *FileTable, path: []const u8, flags: u32) Error!i32 {
    if (flags & ~OPEN_KNOWN != 0) return Error.InvalidArgument;
    // Path resolution reads the disk; it runs before taking the table lock.
    const node = try openNode(path, flags);
    const mode = (if (flags & OPEN_WRITE != 0) OPEN_WRITE | (flags & OPEN_APPEND) else 0) |
        (if (flags & OPEN_READ != 0 or flags & OPEN_WRITE == 0) OPEN_READ else 0);

    const fd = blk: {
        const state = spinlock.acquireIrqSave(&table.lock);
        defer spinlock.releaseIrqRestore(&table.lock, state);
        for (&table.entries, 0..) |*entry, i| {
            if (entry.used) continue;
            entry.* = .{ .used = true, .node = node, .offset = 0, .mode = mode, .generation = entry.generation +% 1 };
            break :blk @as(i32, @intCast(i)) + FD_BASE;
        }
        break :blk null;
    };
    if (fd) |value| return value;
    release(node);
    return Error.TooManyOpen;
}

pub fn close(table: *FileTable, fd: i32) Error!void {
    const node = blk: {
        const state = spinlock.acquireIrqSave(&table.lock);
        defer spinlock.releaseIrqRestore(&table.lock, state);
        const i = try checkFd(table, fd);
        table.entries[i].used = false;
        break :blk table.entries[i].node;
    };
    release(node);
}

const Snapshot = struct { index: usize, file: OpenFile };

/// Copy a descriptor's entry and take a node reference, so the node stays
/// valid while the table lock is dropped for the transfer.
fn snapshot(table: *FileTable, fd: i32) Error!Snapshot {
    const state = spinlock.acquireIrqSave(&table.lock);
    defer spinlock.releaseIrqRestore(&table.lock, state);
    const i = try checkFd(table, fd);
    _ = retain(table.entries[i].node);
    return .{ .index = i, .file = table.entries[i] };
}

fn advance(table: *FileTable, taken: Snapshot, offset: u64) void {
    const state = spinlock.acquireIrqSave(&table.lock);
    defer spinlock.releaseIrqRestore(&table.lock, state);
    const entry = &table.entries[taken.index];
    if (entry.used and entry.generation == taken.file.generation) entry.offset = offset;
}

/// Read at the descriptor's offset and advance it. Two threads reading one
/// descriptor at once may both read from the same offset, like pread; the
/// offset only ever moves forward to the end of a completed read.
pub fn read(table: *FileTable, fd: i32, buf: []u8) Error!usize {
    const taken = try snapshot(table, fd);
    defer release(taken.file.node);
    if (taken.file.mode & OPEN_READ == 0) return Error.BadFd;
    const n = try readAt(&taken.file.node, taken.file.offset, buf);
    advance(table, taken, taken.file.offset + n);
    return n;
}

/// Write at the descriptor's offset (or the end, for an append descriptor)
/// and advance it.
pub fn write(table: *FileTable, fd: i32, data: []const u8) Error!usize {
    const taken = try snapshot(table, fd);
    defer release(taken.file.node);
    if (taken.file.mode & OPEN_WRITE == 0) return Error.BadFd;
    const inode = switch (taken.file.node) {
        .tmp => |t| t,
        .citrus => return Error.ReadOnly,
    };
    const at: ?u64 = if (taken.file.mode & OPEN_APPEND != 0) null else taken.file.offset;
    const written = tmpfs.write(inode, at, data) catch |e| return tmpError(e);
    advance(table, taken, written.end);
    return written.count;
}

/// pread: read at an explicit offset, leaving the descriptor's own alone.
pub fn readAtOffset(table: *FileTable, fd: i32, offset: u64, buf: []u8) Error!usize {
    const taken = try snapshot(table, fd);
    defer release(taken.file.node);
    if (taken.file.mode & OPEN_READ == 0) return Error.BadFd;
    return readAt(&taken.file.node, offset, buf);
}

/// pwrite: write at an explicit offset, leaving the descriptor's own alone.
/// Unlike Linux, an append descriptor still writes at the given offset, as
/// POSIX specifies.
pub fn writeAtOffset(table: *FileTable, fd: i32, offset: u64, data: []const u8) Error!usize {
    const taken = try snapshot(table, fd);
    defer release(taken.file.node);
    if (taken.file.mode & OPEN_WRITE == 0) return Error.BadFd;
    const inode = switch (taken.file.node) {
        .tmp => |t| t,
        .citrus => return Error.ReadOnly,
    };
    const written = tmpfs.write(inode, offset, data) catch |e| return tmpError(e);
    return written.count;
}

pub fn truncate(table: *FileTable, fd: i32, length: u64) Error!void {
    const taken = try snapshot(table, fd);
    defer release(taken.file.node);
    if (taken.file.mode & OPEN_WRITE == 0) return Error.InvalidArgument;
    switch (taken.file.node) {
        .tmp => |t| tmpfs.truncate(t, length) catch |e| return tmpError(e),
        .citrus => return Error.ReadOnly,
    }
}

pub fn seek(table: *FileTable, fd: i32, offset: u64) Error!void {
    const state = spinlock.acquireIrqSave(&table.lock);
    defer spinlock.releaseIrqRestore(&table.lock, state);
    const i = try checkFd(table, fd);
    table.entries[i].offset = offset;
}

pub const Whence = enum(u32) { set = 0, current = 1, end = 2 };

/// lseek semantics: move relative to the start, the current offset or the
/// end, and return the new offset. Negative results are rejected.
pub fn seekFrom(table: *FileTable, fd: i32, offset: i64, whence: Whence) Error!u64 {
    const taken = try snapshot(table, fd);
    defer release(taken.file.node);
    // The size of a tmpfs file is read under its own lock, not the table's.
    const end = taken.file.node.size();
    const state = spinlock.acquireIrqSave(&table.lock);
    defer spinlock.releaseIrqRestore(&table.lock, state);
    const entry = &table.entries[taken.index];
    if (!entry.used or entry.generation != taken.file.generation) return Error.BadFd;
    const base: i128 = switch (whence) {
        .set => 0,
        .current => entry.offset,
        .end => end,
    };
    const target = base + offset;
    if (target < 0 or target > std.math.maxInt(i64)) return Error.InvalidArgument;
    entry.offset = @intCast(target);
    return entry.offset;
}

pub const Status = struct { size: u64, directory: bool, mode: u32 };

pub fn statFd(table: *FileTable, fd: i32) Error!Status {
    const taken = try snapshot(table, fd);
    defer release(taken.file.node);
    return .{ .size = taken.file.node.size(), .directory = taken.file.node.isDir(), .mode = taken.file.mode };
}

pub fn statSize(table: *FileTable, fd: i32) Error!u64 {
    return (try statFd(table, fd)).size;
}

/// A read of an open directory, whose offset is an entry index: `begin`
/// takes a reference and the starting index, `entries` visits the entries,
/// and `end` advances the offset past the ones delivered.
pub const DirRead = struct {
    taken: Snapshot,

    pub fn begin(table: *FileTable, fd: i32) Error!DirRead {
        const taken = try snapshot(table, fd);
        if (!taken.file.node.isDir()) {
            release(taken.file.node);
            return Error.NotDirectory;
        }
        return .{ .taken = taken };
    }

    pub fn start(self: *const DirRead) u64 {
        return self.taken.file.offset;
    }

    pub fn entries(
        self: *const DirRead,
        ctx: *anyopaque,
        visit: *const fn (ctx: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool,
    ) Error!void {
        try iterateNode(&self.taken.file.node, ctx, visit);
    }

    pub fn end(self: *const DirRead, table: *FileTable, delivered: u64) void {
        advance(table, self.taken, self.taken.file.offset + delivered);
        release(self.taken.file.node);
    }
};

/// Caller holds the table lock.
fn checkFd(table: *const FileTable, fd: i32) Error!usize {
    if (fd < FD_BASE) return Error.BadFd; // 0/1/2 are the standard streams
    const i: i32 = fd - FD_BASE;
    if (i >= MAX_OPEN) return Error.BadFd;
    const idx: usize = @intCast(i);
    if (!table.entries[idx].used) return Error.BadFd;
    return idx;
}

// ── Directory listing ────────────────────────────────────────────────────────

fn iterateNode(
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
