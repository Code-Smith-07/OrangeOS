//! tmpfs: a writable filesystem held in memory, mounted at /tmp.
//!
//! Directories are trees of inodes; a file is an array of physical frames,
//! with 0 for a hole that reads as zeros. There are no hard links, so each
//! inode has exactly one parent and one name while it is linked. An inode
//! also counts the handles held on it (open descriptors, resolved nodes, a
//! program being loaded); unlinking removes it from the tree but frees it
//! only when the last handle is released, which is what lets a program keep
//! using a file it has already deleted.
//!
//! One lock covers the whole filesystem. It is held for bounded steps: one
//! lookup walk, one metadata change, or one data copy of at most a system
//! call's 4 KiB buffer. Data pages count against a quota of a quarter of
//! physical memory, so filling /tmp cannot starve the kernel.
//!
//! Lock order: tmpfs -> heap -> pmm.

const std = @import("std");
const heap = @import("../../mm/heap.zig");
const pmm = @import("../../mm/pmm.zig");
const spinlock = @import("../../sync/spinlock.zig");

pub const MAX_NAME = 128;
pub const MAX_FILE_SIZE: u64 = 1 << 30;
const PAGE: u64 = pmm.PAGE_SIZE;

pub const Error = error{
    NotFound,
    NotDirectory,
    IsDirectory,
    Exists,
    NotEmpty,
    NoSpace,
    NameTooLong,
    InvalidArgument,
    FileTooBig,
    /// The file is sealed against this change.
    Sealed,
    /// The file is mapped shared, and this would take pages away from it.
    Busy,
};

/// Seals (fcntl F_ADD_SEALS), with Linux's values.
pub const SEAL_SEAL: u32 = 1;
pub const SEAL_SHRINK: u32 = 2;
pub const SEAL_GROW: u32 = 4;
pub const SEAL_WRITE: u32 = 8;
pub const SEAL_FUTURE_WRITE: u32 = 16;

pub const Kind = enum { file, directory };

pub const Inode = struct {
    kind: Kind,
    id: u32,
    /// Handles held outside the tree.
    refs: u32 = 0,
    /// Reachable from the root. An unlinked inode lives until refs is 0.
    linked: bool = true,
    parent: ?*Inode = null,
    /// Next entry in the parent's child list.
    sibling: ?*Inode = null,
    first_child: ?*Inode = null,
    name_len: u8 = 0,
    name: [MAX_NAME]u8 = undefined,
    size: u64 = 0,
    seals: u32 = 0,
    /// Shared mappings of this file, and how many are writable. A file mapped
    /// shared cannot shrink: its frames are in those address spaces.
    mappings: u32 = 0,
    writable_mappings: u32 = 0,
    /// Physical frame per file page; 0 is a hole.
    frames: ?[*]u64 = null,
    frame_capacity: usize = 0,

    fn nameSlice(self: *const Inode) []const u8 {
        return self.name[0..self.name_len];
    }
};

var lock: spinlock.SpinLock = .{};
var root: Inode = .{ .kind = .directory, .id = 1, .refs = 1 };
var next_id: u32 = 2;
var used_pages: u64 = 0;
var quota_pages: u64 = 0;

pub fn init() void {
    quota_pages = pmm.stats().total_pages / 4;
}

pub const Usage = struct { total_bytes: u64, free_bytes: u64 };

pub fn usage() Usage {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return .{ .total_bytes = quota_pages * PAGE, .free_bytes = (quota_pages -| used_pages) * PAGE };
}

// ── Handles ─────────────────────────────────────────────────────────────────

pub fn retain(inode: *Inode) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    inode.refs += 1;
}

pub fn release(inode: *Inode) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    std.debug.assert(inode.refs > 0);
    inode.refs -= 1;
    reapLocked(inode);
}

/// Free an inode nothing refers to any more.
fn reapLocked(inode: *Inode) void {
    if (inode.refs != 0 or inode.linked or inode == &root) return;
    std.debug.assert(inode.first_child == null);
    truncateLocked(inode, 0);
    if (inode.frames) |frames| heap.free(@ptrCast(frames));
    heap.destroy(inode);
}

pub fn isDir(inode: *const Inode) bool {
    return inode.kind == .directory;
}

pub fn size(inode: *const Inode) u64 {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return inode.size;
}

// ── Paths ───────────────────────────────────────────────────────────────────
// Paths here are relative to the mount point and already normalized by the
// VFS: components separated by single slashes, no "." or "..", and "" for
// the root itself.

fn childLocked(dir: *const Inode, name: []const u8) ?*Inode {
    var cursor = dir.first_child;
    while (cursor) |child| : (cursor = child.sibling) {
        if (std.mem.eql(u8, child.nameSlice(), name)) return child;
    }
    return null;
}

fn walkLocked(path: []const u8) Error!*Inode {
    var node: *Inode = &root;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        if (node.kind != .directory) return Error.NotDirectory;
        node = childLocked(node, component) orelse return Error.NotFound;
    }
    return node;
}

const Split = struct { parent: []const u8, name: []const u8 };

fn split(path: []const u8) Error!Split {
    if (path.len == 0) return Error.InvalidArgument; // the mount point itself
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const name = if (slash) |i| path[i + 1 ..] else path;
    if (name.len > MAX_NAME) return Error.NameTooLong;
    return .{ .parent = if (slash) |i| path[0..i] else "", .name = name };
}

fn parentLocked(parts: Split) Error!*Inode {
    const parent = try walkLocked(parts.parent);
    if (parent.kind != .directory) return Error.NotDirectory;
    return parent;
}

fn linkLocked(parent: *Inode, child: *Inode) void {
    child.parent = parent;
    child.sibling = parent.first_child;
    child.linked = true;
    parent.first_child = child;
}

fn unlinkLocked(child: *Inode) void {
    const parent = child.parent.?;
    var link = &parent.first_child;
    while (link.*) |entry| : (link = &entry.sibling) {
        if (entry == child) {
            link.* = child.sibling;
            break;
        }
    }
    child.sibling = null;
    child.parent = null;
    child.linked = false;
}

fn newInodeLocked(kind: Kind, name: []const u8) Error!*Inode {
    const inode = heap.create(Inode) catch return Error.NoSpace;
    inode.* = .{ .kind = kind, .id = next_id, .name_len = @intCast(name.len) };
    next_id +%= 1;
    if (next_id < 2) next_id = 2;
    @memcpy(inode.name[0..name.len], name);
    return inode;
}

/// Resolve a path to a retained inode.
pub fn lookup(path: []const u8) Error!*Inode {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const inode = try walkLocked(path);
    inode.refs += 1;
    return inode;
}

/// Resolve a path to a retained inode, creating an empty file if it is
/// missing and `create` is set. `exclusive` requires the creation.
pub fn open(path: []const u8, create: bool, exclusive: bool) Error!*Inode {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (walkLocked(path)) |inode| {
        if (create and exclusive) return Error.Exists;
        inode.refs += 1;
        return inode;
    } else |e| {
        if (e != Error.NotFound or !create) return e;
    }
    const parts = try split(path);
    const parent = try parentLocked(parts);
    const inode = try newInodeLocked(.file, parts.name);
    linkLocked(parent, inode);
    inode.refs = 1;
    return inode;
}

pub fn mkdir(path: []const u8) Error!void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const parts = try split(path);
    const parent = try parentLocked(parts);
    if (childLocked(parent, parts.name) != null) return Error.Exists;
    linkLocked(parent, try newInodeLocked(.directory, parts.name));
}

/// Remove a file (`directory` false) or an empty directory.
pub fn remove(path: []const u8, directory: bool) Error!void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const parts = try split(path);
    const parent = try parentLocked(parts);
    const inode = childLocked(parent, parts.name) orelse return Error.NotFound;
    if (directory) {
        if (inode.kind != .directory) return Error.NotDirectory;
        if (inode.first_child != null) return Error.NotEmpty;
    } else if (inode.kind == .directory) return Error.IsDirectory;
    unlinkLocked(inode);
    reapLocked(inode);
}

/// Move `from` to `to`, replacing a file there or an empty directory, as
/// rename(2) does.
pub fn rename(from: []const u8, to: []const u8) Error!void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const source_parts = try split(from);
    const target_parts = try split(to);
    const source_parent = try parentLocked(source_parts);
    const source = childLocked(source_parent, source_parts.name) orelse return Error.NotFound;
    const target_parent = try parentLocked(target_parts);
    // A directory cannot move beneath itself.
    var ancestor: ?*Inode = target_parent;
    while (ancestor) |a| : (ancestor = a.parent) {
        if (a == source) return Error.InvalidArgument;
    }
    if (childLocked(target_parent, target_parts.name)) |existing| {
        if (existing == source) return;
        if (source.kind == .directory) {
            if (existing.kind != .directory) return Error.NotDirectory;
            if (existing.first_child != null) return Error.NotEmpty;
        } else if (existing.kind == .directory) return Error.IsDirectory;
        unlinkLocked(existing);
        reapLocked(existing);
    }
    unlinkLocked(source);
    source.name_len = @intCast(target_parts.name.len);
    @memcpy(source.name[0..target_parts.name.len], target_parts.name);
    linkLocked(target_parent, source);
}

// ── Data ────────────────────────────────────────────────────────────────────

fn frameAt(inode: *const Inode, page: u64) u64 {
    if (page >= inode.frame_capacity) return 0;
    return inode.frames.?[page];
}

fn ensureCapacityLocked(inode: *Inode, pages: usize) Error!void {
    if (pages <= inode.frame_capacity) return;
    const capacity = @max(pages, inode.frame_capacity * 2, 16);
    const bytes = capacity * @sizeOf(u64);
    const grown: [*]u64 = @ptrCast(@alignCast(heap.allocZeroed(bytes) catch return Error.NoSpace));
    if (inode.frames) |old| {
        @memcpy(grown[0..inode.frame_capacity], old[0..inode.frame_capacity]);
        heap.free(@ptrCast(old));
    }
    inode.frames = grown;
    inode.frame_capacity = capacity;
}

pub fn read(inode: *Inode, offset: u64, buf: []u8) Error!usize {
    if (inode.kind == .directory) return Error.IsDirectory;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (offset >= inode.size) return 0;
    const total: usize = @intCast(@min(buf.len, inode.size - offset));
    var done: usize = 0;
    while (done < total) {
        const position = offset + done;
        const within: usize = @intCast(position % PAGE);
        const chunk = @min(PAGE - within, total - done);
        const frame = frameAt(inode, position / PAGE);
        if (frame == 0) {
            @memset(buf[done .. done + chunk], 0);
        } else {
            const source: [*]const u8 = @ptrFromInt(pmm.physToVirt(frame));
            @memcpy(buf[done .. done + chunk], source[within .. within + chunk]);
        }
        done += chunk;
    }
    return total;
}

pub const Written = struct { count: usize, end: u64 };

/// Write at `offset`, or at the current end when `offset` is null (append).
pub fn write(inode: *Inode, offset: ?u64, data: []const u8) Error!Written {
    if (inode.kind == .directory) return Error.IsDirectory;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const start = offset orelse inode.size;
    if (start > MAX_FILE_SIZE or data.len > MAX_FILE_SIZE - start) return Error.FileTooBig;
    if (inode.seals & (SEAL_WRITE | SEAL_FUTURE_WRITE) != 0) return Error.Sealed;
    if (inode.seals & SEAL_GROW != 0 and start + data.len > inode.size) return Error.Sealed;
    const end = start + data.len;
    try ensureCapacityLocked(inode, @intCast((end + PAGE - 1) / PAGE));
    var done: usize = 0;
    while (done < data.len) {
        const position = start + done;
        const within: usize = @intCast(position % PAGE);
        const chunk = @min(PAGE - within, data.len - done);
        const slot = &inode.frames.?[@intCast(position / PAGE)];
        if (slot.* == 0) {
            if (used_pages >= quota_pages) break;
            slot.* = pmm.allocPageZeroed() catch break;
            used_pages += 1;
        }
        const dest: [*]u8 = @ptrFromInt(pmm.physToVirt(slot.*));
        @memcpy(dest[within .. within + chunk], data[done .. done + chunk]);
        done += chunk;
    }
    if (done == 0 and data.len > 0) return Error.NoSpace;
    inode.size = @max(inode.size, start + done);
    return .{ .count = done, .end = start + done };
}

pub fn truncate(inode: *Inode, length: u64) Error!void {
    if (inode.kind == .directory) return Error.IsDirectory;
    if (length > MAX_FILE_SIZE) return Error.FileTooBig;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (length < inode.size) {
        if (inode.seals & SEAL_SHRINK != 0) return Error.Sealed;
        if (inode.mappings > 0) return Error.Busy;
    } else if (length > inode.size and inode.seals & SEAL_GROW != 0) return Error.Sealed;
    truncateLocked(inode, length);
}

/// Shrinking frees whole pages past the end and zeroes the tail of the last
/// one, so a later extension reads zeros; growing leaves a hole.
fn truncateLocked(inode: *Inode, length: u64) void {
    if (length < inode.size) {
        const keep: usize = @intCast((length + PAGE - 1) / PAGE);
        var page = keep;
        while (page < inode.frame_capacity) : (page += 1) {
            const slot = &inode.frames.?[page];
            if (slot.* != 0) {
                pmm.freePage(slot.*);
                slot.* = 0;
                used_pages -= 1;
            }
        }
        const within: usize = @intCast(length % PAGE);
        if (within != 0) {
            const frame = frameAt(inode, length / PAGE);
            if (frame != 0) {
                const bytes: [*]u8 = @ptrFromInt(pmm.physToVirt(frame));
                @memset(bytes[within..PAGE], 0);
            }
        }
    }
    inode.size = length;
}

// ── Directories ─────────────────────────────────────────────────────────────

/// Visit "." and "..", then each entry, with CitrusFS's type codes (1 file,
/// 2 directory). The visitor runs under the filesystem lock and must only
/// copy what it is given.
pub fn iterate(
    dir: *Inode,
    ctx: *anyopaque,
    visit: *const fn (ctx: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool,
) Error!void {
    if (dir.kind != .directory) return Error.NotDirectory;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (!visit(ctx, ".", dir.id, 2)) return;
    if (!visit(ctx, "..", if (dir.parent) |p| p.id else dir.id, 2)) return;
    var cursor = dir.first_child;
    while (cursor) |child| : (cursor = child.sibling) {
        if (!visit(ctx, child.nameSlice(), child.id, if (child.kind == .directory) 2 else 1)) return;
    }
}

// ── Anonymous files and shared mappings ─────────────────────────────────────

/// memfd_create: a file in no directory, alive while referenced. Without
/// `sealable`, it starts sealed against further seals.
pub fn createAnonymous(sealable: bool) Error!*Inode {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const inode = try newInodeLocked(.file, "memfd");
    inode.linked = false;
    inode.refs = 1;
    inode.seals = if (sealable) 0 else SEAL_SEAL;
    return inode;
}

pub fn seals(inode: *Inode) u32 {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return inode.seals;
}

/// F_ADD_SEALS. Sealing writes while a writable shared mapping exists is
/// refused (Busy), as on Linux.
pub fn addSeals(inode: *Inode, add: u32) Error!void {
    if (add & ~(SEAL_SEAL | SEAL_SHRINK | SEAL_GROW | SEAL_WRITE | SEAL_FUTURE_WRITE) != 0) return Error.InvalidArgument;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (inode.seals & SEAL_SEAL != 0) return Error.Sealed;
    if (add & SEAL_WRITE != 0 and inode.writable_mappings > 0) return Error.Busy;
    inode.seals |= add;
}

/// A shared mapping of the file begins: it holds a reference, and a new
/// writable one is refused on a write-sealed file. (A mapping split in two by
/// mprotect or munmap is not new: `check_seals` is false.)
pub fn beginMapping(inode: *Inode, writable: bool, check_seals: bool) Error!void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (check_seals and writable and inode.seals & (SEAL_WRITE | SEAL_FUTURE_WRITE) != 0) return Error.Sealed;
    inode.refs += 1;
    inode.mappings += 1;
    if (writable) inode.writable_mappings += 1;
}

pub fn endMapping(inode: *Inode, writable: bool) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    inode.mappings -= 1;
    if (writable) inode.writable_mappings -= 1;
    inode.refs -= 1;
    reapLocked(inode);
}

/// A mapping's writability changed (mprotect).
pub fn changeMappingAccess(inode: *Inode, writable: bool) Error!void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (writable) {
        if (inode.seals & (SEAL_WRITE | SEAL_FUTURE_WRITE) != 0) return Error.Sealed;
        inode.writable_mappings += 1;
    } else inode.writable_mappings -= 1;
}

/// The frame holding page `index` of the file, allocated (zeroed) if it is
/// a hole; null past the end of the file or when memory runs out.
pub fn frameOf(inode: *Inode, index: u64) ?u64 {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (index * PAGE >= inode.size) return null;
    ensureCapacityLocked(inode, @intCast(index + 1)) catch return null;
    const slot = &inode.frames.?[@intCast(index)];
    if (slot.* == 0) {
        if (used_pages >= quota_pages) return null;
        slot.* = pmm.allocPageZeroed() catch return null;
        used_pages += 1;
    }
    return slot.*;
}
