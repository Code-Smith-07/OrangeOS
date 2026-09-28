//! tmpfs: writable filesystems held in memory, the volumes /tmp and /data.
//!
//! /tmp lasts until the next boot. /data is the same kind of tree, but
//! persist.zig loads it from the data disk at boot and writes it back; its
//! volume is marked dirty by every change so that is known to be needed.
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
//! call's 4 KiB buffer. Data pages count against their volume's quota (for
//! /tmp a quarter of physical memory), so filling it cannot starve the
//! kernel.
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

/// One tree: its root, its page quota, and (for /data) whether it changed
/// since it was last written to disk.
pub const Volume = struct {
    root: Inode,
    used_pages: u64 = 0,
    quota_pages: u64 = 0,
    /// Written back to disk (persist.zig); changes set `dirty`.
    persistent: bool = false,
    dirty: bool = false,
};

pub const Inode = struct {
    kind: Kind,
    id: u32,
    volume: *Volume = &tmp,
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

pub var lock: spinlock.SpinLock = .{};
pub var tmp: Volume = .{ .root = .{ .kind = .directory, .id = 1, .refs = 1, .volume = &tmp } };
pub var data: Volume = .{ .root = .{ .kind = .directory, .id = 1, .refs = 1, .volume = &data } };
var next_id: u32 = 2;

pub fn init() void {
    tmp.quota_pages = pmm.stats().total_pages / 4;
}

pub const Usage = struct { total_bytes: u64, free_bytes: u64 };

pub fn usage(vol: *Volume) Usage {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return .{ .total_bytes = vol.quota_pages * PAGE, .free_bytes = (vol.quota_pages -| vol.used_pages) * PAGE };
}

fn changedLocked(vol: *Volume) void {
    if (vol.persistent) vol.dirty = true;
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
    if (inode.refs != 0 or inode.linked or inode == &inode.volume.root) return;
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

fn walkLocked(vol: *Volume, path: []const u8) Error!*Inode {
    var node: *Inode = &vol.root;
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

fn parentLocked(vol: *Volume, parts: Split) Error!*Inode {
    const parent = try walkLocked(vol, parts.parent);
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

fn newInodeLocked(vol: *Volume, kind: Kind, name: []const u8) Error!*Inode {
    const inode = heap.create(Inode) catch return Error.NoSpace;
    inode.* = .{ .kind = kind, .id = next_id, .volume = vol, .name_len = @intCast(name.len) };
    next_id +%= 1;
    if (next_id < 2) next_id = 2;
    @memcpy(inode.name[0..name.len], name);
    return inode;
}

/// Resolve a path to a retained inode.
pub fn lookup(vol: *Volume, path: []const u8) Error!*Inode {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const inode = try walkLocked(vol, path);
    inode.refs += 1;
    return inode;
}

/// Resolve a path to a retained inode, creating an empty file if it is
/// missing and `create` is set. `exclusive` requires the creation.
pub fn open(vol: *Volume, path: []const u8, create: bool, exclusive: bool) Error!*Inode {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (walkLocked(vol, path)) |inode| {
        if (create and exclusive) return Error.Exists;
        inode.refs += 1;
        return inode;
    } else |e| {
        if (e != Error.NotFound or !create) return e;
    }
    const parts = try split(path);
    const parent = try parentLocked(vol, parts);
    const inode = try newInodeLocked(vol, .file, parts.name);
    linkLocked(parent, inode);
    inode.refs = 1;
    changedLocked(vol);
    return inode;
}

pub fn mkdir(vol: *Volume, path: []const u8) Error!void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const parts = try split(path);
    const parent = try parentLocked(vol, parts);
    if (childLocked(parent, parts.name) != null) return Error.Exists;
    linkLocked(parent, try newInodeLocked(vol, .directory, parts.name));
    changedLocked(vol);
}

/// Remove a file (`directory` false) or an empty directory.
pub fn remove(vol: *Volume, path: []const u8, directory: bool) Error!void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const parts = try split(path);
    const parent = try parentLocked(vol, parts);
    const inode = childLocked(parent, parts.name) orelse return Error.NotFound;
    if (directory) {
        if (inode.kind != .directory) return Error.NotDirectory;
        if (inode.first_child != null) return Error.NotEmpty;
    } else if (inode.kind == .directory) return Error.IsDirectory;
    unlinkLocked(inode);
    reapLocked(inode);
    changedLocked(vol);
}

/// Move `from` to `to`, replacing a file there or an empty directory, as
/// rename(2) does.
pub fn rename(vol: *Volume, from: []const u8, to: []const u8) Error!void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const source_parts = try split(from);
    const target_parts = try split(to);
    const source_parent = try parentLocked(vol, source_parts);
    const source = childLocked(source_parent, source_parts.name) orelse return Error.NotFound;
    const target_parent = try parentLocked(vol, target_parts);
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
    changedLocked(vol);
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
pub fn write(inode: *Inode, offset: ?u64, bytes: []const u8) Error!Written {
    if (inode.kind == .directory) return Error.IsDirectory;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const start = offset orelse inode.size;
    if (start > MAX_FILE_SIZE or bytes.len > MAX_FILE_SIZE - start) return Error.FileTooBig;
    if (inode.seals & (SEAL_WRITE | SEAL_FUTURE_WRITE) != 0) return Error.Sealed;
    if (inode.seals & SEAL_GROW != 0 and start + bytes.len > inode.size) return Error.Sealed;
    const end = start + bytes.len;
    try ensureCapacityLocked(inode, @intCast((end + PAGE - 1) / PAGE));
    var done: usize = 0;
    while (done < bytes.len) {
        const position = start + done;
        const within: usize = @intCast(position % PAGE);
        const chunk = @min(PAGE - within, bytes.len - done);
        const slot = &inode.frames.?[@intCast(position / PAGE)];
        if (slot.* == 0) {
            const vol = inode.volume;
            if (vol.used_pages >= vol.quota_pages) break;
            slot.* = pmm.allocPageZeroed() catch break;
            vol.used_pages += 1;
        }
        const dest: [*]u8 = @ptrFromInt(pmm.physToVirt(slot.*));
        @memcpy(dest[within .. within + chunk], bytes[done .. done + chunk]);
        done += chunk;
    }
    if (done == 0 and bytes.len > 0) return Error.NoSpace;
    inode.size = @max(inode.size, start + done);
    if (inode.linked) changedLocked(inode.volume);
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
    if (inode.linked) changedLocked(inode.volume);
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
                inode.volume.used_pages -= 1;
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
    const inode = try newInodeLocked(&tmp, .file, "memfd");
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
        const vol = inode.volume;
        if (vol.used_pages >= vol.quota_pages) return null;
        slot.* = pmm.allocPageZeroed() catch return null;
        vol.used_pages += 1;
        // A shared mapping of a /data file may change it without a write.
        if (inode.linked) changedLocked(vol);
    }
    return slot.*;
}

// ── Saving and loading a volume (persist.zig) ───────────────────────────────
// A volume as a stream of records, depth first: a directory record, then its
// entries, then "up"; a file record carries its size and bytes (holes as
// zeros). The root is implicit. Loading refuses names and sizes a volume
// could not hold, so a damaged stream cannot build an impossible tree.

pub const RECORD_END: u8 = 0;
pub const RECORD_DIRECTORY: u8 = 1;
pub const RECORD_FILE: u8 = 2;
pub const RECORD_UP: u8 = 3;
const MAX_DEPTH = 128;

const zero_page = [_]u8{0} ** PAGE;

/// Whether the volume changed since it was last saved. A file mapped
/// writable and shared can change without a write call, so it counts too.
pub fn needsSaveLocked(vol: *Volume) bool {
    return vol.dirty or writablyMappedLocked(&vol.root);
}

fn writablyMappedLocked(dir: *const Inode) bool {
    var cursor = dir.first_child;
    while (cursor) |child| : (cursor = child.sibling) {
        if (child.writable_mappings > 0) return true;
        if (child.kind == .directory and writablyMappedLocked(child)) return true;
    }
    return false;
}

/// The byte length `saveLocked` produces.
pub fn savedSizeLocked(vol: *Volume) u64 {
    return childrenSize(&vol.root) + 1;
}

fn childrenSize(dir: *const Inode) u64 {
    var total: u64 = 0;
    var cursor = dir.first_child;
    while (cursor) |child| : (cursor = child.sibling) {
        total += 2 + child.name_len;
        total += if (child.kind == .directory) childrenSize(child) + 1 else 8 + child.size;
    }
    return total;
}

/// Write the volume to `sink` (`put(bytes)`), which has room for
/// `savedSizeLocked` bytes, and mark it clean.
pub fn saveLocked(vol: *Volume, sink: anytype) void {
    saveChildren(&vol.root, sink);
    sink.put(&.{RECORD_END});
    vol.dirty = false;
}

fn saveChildren(dir: *const Inode, sink: anytype) void {
    var cursor = dir.first_child;
    while (cursor) |child| : (cursor = child.sibling) {
        sink.put(&.{ if (child.kind == .directory) RECORD_DIRECTORY else RECORD_FILE, child.name_len });
        sink.put(child.nameSlice());
        if (child.kind == .directory) {
            saveChildren(child, sink);
            sink.put(&.{RECORD_UP});
            continue;
        }
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, child.size, .little);
        sink.put(&length);
        var page: u64 = 0;
        while (page * PAGE < child.size) : (page += 1) {
            const chunk: usize = @intCast(@min(PAGE, child.size - page * PAGE));
            const frame = frameAt(child, page);
            if (frame == 0) {
                sink.put(zero_page[0..chunk]);
            } else {
                const bytes: [*]const u8 = @ptrFromInt(pmm.physToVirt(frame));
                sink.put(bytes[0..chunk]);
            }
        }
    }
}

/// Build the (empty) volume from `source` (`get(buffer) bool`, false when
/// the stream ends early). On error the volume is left empty.
pub fn loadLocked(vol: *Volume, source: anytype) Error!void {
    loadRecordsLocked(vol, source) catch |e| {
        clearLocked(&vol.root);
        vol.dirty = false;
        return e;
    };
    vol.dirty = false;
}

fn loadRecordsLocked(vol: *Volume, source: anytype) Error!void {
    var stack: [MAX_DEPTH]*Inode = undefined;
    var depth: usize = 0;
    var dir: *Inode = &vol.root;
    while (true) {
        var kind: [1]u8 = undefined;
        if (!source.get(&kind)) return Error.InvalidArgument;
        switch (kind[0]) {
            RECORD_END => return if (depth == 0) {} else Error.InvalidArgument,
            RECORD_UP => {
                if (depth == 0) return Error.InvalidArgument;
                depth -= 1;
                dir = stack[depth];
            },
            RECORD_DIRECTORY, RECORD_FILE => {
                var name_len: [1]u8 = undefined;
                var name: [MAX_NAME]u8 = undefined;
                if (!source.get(&name_len) or name_len[0] == 0 or name_len[0] > MAX_NAME) return Error.InvalidArgument;
                const n = name[0..name_len[0]];
                if (!source.get(n)) return Error.InvalidArgument;
                if (std.mem.indexOfScalar(u8, n, '/') != null or std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..") or
                    childLocked(dir, n) != null) return Error.InvalidArgument;
                const inode = try newInodeLocked(vol, if (kind[0] == RECORD_DIRECTORY) .directory else .file, n);
                linkLocked(dir, inode);
                if (kind[0] == RECORD_DIRECTORY) {
                    if (depth == MAX_DEPTH) return Error.InvalidArgument;
                    stack[depth] = dir;
                    depth += 1;
                    dir = inode;
                    continue;
                }
                var length: [8]u8 = undefined;
                if (!source.get(&length)) return Error.InvalidArgument;
                const file_size = std.mem.readInt(u64, &length, .little);
                if (file_size > MAX_FILE_SIZE) return Error.InvalidArgument;
                try ensureCapacityLocked(inode, @intCast((file_size + PAGE - 1) / PAGE));
                var page: u64 = 0;
                while (page * PAGE < file_size) : (page += 1) {
                    const chunk: usize = @intCast(@min(PAGE, file_size - page * PAGE));
                    if (vol.used_pages >= vol.quota_pages) return Error.NoSpace;
                    const frame = pmm.allocPageZeroed() catch return Error.NoSpace;
                    const bytes: [*]u8 = @ptrFromInt(pmm.physToVirt(frame));
                    if (!source.get(bytes[0..chunk])) {
                        pmm.freePage(frame);
                        return Error.InvalidArgument;
                    }
                    // Pages of zeros stay holes.
                    if (std.mem.allEqual(u8, bytes[0..chunk], 0)) {
                        pmm.freePage(frame);
                    } else {
                        inode.frames.?[@intCast(page)] = frame;
                        vol.used_pages += 1;
                    }
                }
                inode.size = file_size;
            },
            else => return Error.InvalidArgument,
        }
    }
}

/// Unlink and free everything under `dir` (loading only: nothing else holds
/// these inodes yet).
fn clearLocked(dir: *Inode) void {
    while (dir.first_child) |child| {
        if (child.kind == .directory) clearLocked(child);
        unlinkLocked(child);
        reapLocked(child);
    }
}
