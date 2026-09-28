//! Owned anonymous mappings of one address space.
//!
//! Every function here follows the change protocol in address_space.zig: the
//! space's VM lock is held for the whole operation, translations another CPU
//! may cache are invalidated there too, and detached frames and page tables
//! are freed only after in-flight kernel accesses have drained. Adding a
//! translation needs no invalidation (x86 does not cache non-present
//! entries); removing one or changing its permissions always does, because a
//! stale entry would be a use-after-free and OrangeOS treats a spurious fault
//! as a crash.
const std = @import("std");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");
const vfs = @import("../fs/vfs/vfs.zig");
const tmpfs = @import("../fs/tmpfs/tmpfs.zig");
const AddressSpace = @import("address_space.zig").AddressSpace;

pub const BASE: u64 = 0x0000_4000_0000_0000;
/// 16 TiB for anonymous memory, below the shared-mapping region at 96 TiB.
/// Reservations cost no memory, so allocators that reserve large pools up
/// front (V8's pointer-compression cage, PartitionAlloc's pools) fit.
pub const LIMIT: usize = 16 * 1024 * 1024 * 1024 * 1024;
pub const MAX_MAPPING: usize = 64 * 1024 * 1024;
pub const MAX_RESERVATION: usize = 64 * 1024 * 1024 * 1024;
/// Regions per address space. Every thread's stack is one; a browser process
/// holds thousands (Linux's default limit is 65530).
pub const MAX_MAPPINGS = 16384;
pub const Region = struct {
    address: u64 = 0,
    size: usize = 0,
    /// A reserve()d range whose pages are committed and decommitted
    /// explicitly (the native vm_* calls).
    sparse: bool = false,
    /// Pages appear when first touched, zero-filled, with `prot` (the Linux
    /// mmap model: vm_map, the main stack, thread stacks).
    lazy: bool = false,
    prot: u8 = 0,
    /// What a lazy region's pages come from.
    backing: Backing = .anonymous,

    fn end(self: Region) u64 {
        return self.address + self.size;
    }
};

pub const Backing = union(enum) {
    /// Zeroed frames of its own.
    anonymous,
    /// The frames of a tmpfs file (memfd or /tmp), shared with every other
    /// mapping of it; never freed by unmapping. `offset` is the file offset
    /// of the region's first byte.
    shared: struct { inode: *tmpfs.Inode, offset: u64 },
    /// Private copies of a file's pages, read on first touch.
    file: struct { ref: *FileRef, offset: u64 },
};

/// A file node shared by the region pieces mapping it (a vfs.Node is large;
/// region table entries stay small).
pub const FileRef = struct {
    refs: u32 = 1,
    node: vfs.Node,

    /// Takes over one reference on `node`.
    pub fn create(node: vfs.Node) Error!*FileRef {
        const ref = heap.create(FileRef) catch return error.OutOfMemory;
        ref.* = .{ .node = node };
        return ref;
    }

    pub fn release(self: *FileRef) void {
        if (@atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel) != 1) return;
        vfs.release(self.node);
        heap.destroy(self);
    }
};

fn ownsFrames(r: Region) bool {
    return r.backing != .shared;
}

fn writable(prot: u8) bool {
    return prot & 2 != 0;
}

/// Another region piece now refers to the backing (a split).
fn duplicateBacking(r: Region) void {
    switch (r.backing) {
        .anonymous => {},
        .shared => |b| tmpfs.beginMapping(b.inode, writable(r.prot), false) catch unreachable,
        .file => |b| _ = @atomicRmw(u32, &b.ref.refs, .Add, 1, .monotonic),
    }
}

fn releaseBacking(r: Region) void {
    switch (r.backing) {
        .anonymous => {},
        .shared => |b| tmpfs.endMapping(b.inode, writable(r.prot)),
        .file => |b| b.ref.release(),
    }
}

/// The backing of the part of `r` starting at `address`.
fn backingFrom(r: Region, address: u64) Backing {
    const delta = address - r.address;
    return switch (r.backing) {
        .anonymous => .anonymous,
        .shared => |b| .{ .shared = .{ .inode = b.inode, .offset = b.offset + delta } },
        .file => |b| .{ .file = .{ .ref = b.ref, .offset = b.offset + delta } },
    };
}

/// Regions in the first table: one page, counting the heap's 16-byte header.
/// That is more than the largest slab class, so the table is whole pages.
const INITIAL_REGIONS = (vmm.PAGE_SIZE - 16) / @sizeOf(Region);
comptime {
    std.debug.assert(INITIAL_REGIONS * @sizeOf(Region) > 2048);
}

/// Region metadata: sorted by address, never overlapping, grown on demand
/// from the kernel heap. Guarded by the owning AddressSpace's VM lock.
/// The array is always larger than the heap's slab classes, so it is whole
/// pages that go straight back to the page allocator, and it is freed as
/// soon as the last region goes: page accounting stays exact.
pub const State = struct {
    items: [*]Region = undefined,
    len: usize = 0,
    capacity: usize = 0,

    pub fn slice(self: *const State) []Region {
        return self.items[0..self.len];
    }

    /// Make room for one more region.
    fn ensureSpare(self: *State) Error!void {
        if (self.len < self.capacity) return;
        if (self.capacity >= MAX_MAPPINGS) return error.OutOfMemory;
        const grown: usize = @min(@max(INITIAL_REGIONS, self.capacity * 2), MAX_MAPPINGS);
        const raw = heap.alloc(grown * @sizeOf(Region)) catch return error.OutOfMemory;
        const items: [*]Region = @ptrCast(@alignCast(raw));
        if (self.capacity != 0) {
            @memcpy(items[0..self.len], self.items[0..self.len]);
            heap.free(@ptrCast(self.items));
        }
        self.items = items;
        self.capacity = grown;
    }

    fn insertAt(self: *State, index: usize, region: Region) void {
        std.debug.assert(self.len < self.capacity and index <= self.len);
        std.mem.copyBackwards(Region, self.items[index + 1 .. self.len + 1], self.items[index..self.len]);
        self.items[index] = region;
        self.len += 1;
    }

    fn removeAt(self: *State, index: usize) void {
        std.mem.copyForwards(Region, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
        self.len -= 1;
        if (self.len == 0) self.deinit();
    }

    fn deinit(self: *State) void {
        if (self.capacity != 0) heap.free(@ptrCast(self.items));
        self.* = .{};
    }
};
pub const Error = error{ Invalid, Unsupported, OutOfMemory, Exists };

/// Pages detached before one invalidation and drain. Bounds the stack buffer.
const BATCH_PAGES = 64;
/// A 256 KiB batch touches at most two 2 MiB blocks, each of which can empty
/// a page table, its directory and its directory-pointer table.
const BATCH_TABLES = 6;
const BLOCK_2M: u64 = 2 * 1024 * 1024;

fn sizeOf(length: u64, max: usize) Error!usize {
    if (length == 0 or length > max) return error.Invalid;
    return std.mem.alignForward(usize, @intCast(length), vmm.PAGE_SIZE);
}

/// Protections: 0 none, 1 read, 3 read/write, 5 read/execute. Execute alone
/// (4) means read/execute: x86 pages cannot be execute-only. Writable and
/// executable together is refused (W^X): a JIT writes code under read/write,
/// then flips it to read/execute, and each flip shoots down every CPU running
/// the program — which also gives those CPUs the serializing event that
/// cross-modified code requires before they execute it.
fn flagsFor(prot: u64) Error!u64 {
    return switch (prot) {
        0 => vmm.PRESENT | vmm.NO_EXECUTE,
        1 => vmm.PRESENT | vmm.USER | vmm.NO_EXECUTE,
        3 => vmm.PRESENT | vmm.USER | vmm.WRITABLE | vmm.NO_EXECUTE,
        4, 5 => vmm.PRESENT | vmm.USER,
        else => error.Unsupported,
    };
}

const Fit = struct { address: u64, index: usize };

/// The lowest free range of `size` bytes, so released addresses (including
/// holes between live regions) are reused, and where its region belongs in
/// the sorted table. One pass over the regions.
fn firstFit(state: *const State, size: usize) Error!Fit {
    var candidate = BASE;
    for (state.slice(), 0..) |r, i| {
        if (r.address >= candidate + size) return .{ .address = candidate, .index = i };
        candidate = @max(candidate, r.end());
    }
    if (candidate + size > BASE + LIMIT) return error.OutOfMemory;
    return .{ .address = candidate, .index = state.len };
}

fn checkUnmapped(pml4: u64, base: u64, size: usize) Error!void {
    // Never overwrite image/device/shared mappings, even for an unusual ELF.
    if (vmm.anyMapped(pml4, base, size)) return error.Invalid;
}

/// Index of the region wholly containing [address, address + length).
fn findContaining(state: *const State, address: u64, length: u64, max: usize) Error!usize {
    const size = try sizeOf(length, max);
    if (address % vmm.PAGE_SIZE != 0) return error.Invalid;
    const end = std.math.add(u64, address, size) catch return error.Invalid;
    // The last region starting at or below the address.
    var low: usize = 0;
    var high: usize = state.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (state.items[middle].address <= address) low = middle + 1 else high = middle;
    }
    if (low == 0) return error.Invalid;
    const r = state.items[low - 1];
    if (end <= r.end()) return low - 1;
    return error.Invalid;
}

/// Remove every translation in [address, address + size) and free what they
/// held, in batches: detach leaves, unlink emptied tables, invalidate the
/// batch on every resident CPU, wait for in-flight accesses, then free.
/// `owned` frames return to the PMM; borrowed frames (shared memory, the
/// framebuffer) belong to their object and are only unmapped. Caller holds
/// the VM lock.
pub fn detachLocked(space: *AddressSpace, address: u64, size: usize, owned: bool) void {
    std.debug.assert(address % vmm.PAGE_SIZE == 0 and size % vmm.PAGE_SIZE == 0);
    var off: usize = 0;
    while (off < size) {
        // Skip stretches with no page tables: a large reservation that was
        // barely touched costs a few lookups, not one per page.
        const next = vmm.nextPossiblyMapped(space.pml4, address + off, address + size) orelse break;
        off = next - address;
        const count = @min((size - off) / vmm.PAGE_SIZE, BATCH_PAGES);
        const start = address + off;
        var frames: [BATCH_PAGES]u64 = undefined;
        var frame_count: usize = 0;
        for (0..count) |i| {
            if (vmm.detachPage(space.pml4, start + i * vmm.PAGE_SIZE)) |phys| {
                frames[frame_count] = phys;
                frame_count += 1;
            }
        }
        // A page table can only have become empty if this batch touched it,
        // so checking the first page of each 2 MiB block is enough.
        var tables: [BATCH_TABLES]u64 = undefined;
        var table_count: usize = 0;
        var probe = start;
        const end = start + count * vmm.PAGE_SIZE;
        while (probe < end) : (probe = std.mem.alignForward(u64, probe + 1, BLOCK_2M)) {
            var unlinked: [3]u64 = undefined;
            const n = vmm.unlinkEmptyTables(space.pml4, probe, &unlinked);
            std.debug.assert(table_count + n <= BATCH_TABLES);
            @memcpy(tables[table_count..][0..n], unlinked[0..n]);
            table_count += n;
        }
        if (frame_count != 0 or table_count != 0) {
            space.invalidateRange(start, count);
            space.drainAccesses();
            if (owned) for (frames[0..frame_count]) |phys| pmm.freePage(phys);
            for (tables[0..table_count]) |phys| pmm.freePage(phys);
        }
        off += count * vmm.PAGE_SIZE;
    }
}

/// Map zeroed owned frames over a range known to be unmapped. On failure,
/// everything this call mapped (and any table it linked) is released.
fn populateLocked(space: *AddressSpace, address: u64, size: usize, flags: u64) Error!void {
    var off: usize = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        _ = vmm.allocAndMap(space.pml4, address + off, flags) catch {
            // mapPage can link empty intermediate tables before failing, so
            // the failed page's path is included in the release.
            detachLocked(space, address, off + vmm.PAGE_SIZE, true);
            return error.OutOfMemory;
        };
    }
}

pub fn map(space: *AddressSpace, length: u64, prot: u64) Error!u64 {
    const size = try sizeOf(length, MAX_MAPPING);
    const flags = try flagsFor(prot);
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    try state.ensureSpare();
    const fit = try firstFit(state, size);
    try checkUnmapped(space.pml4, fit.address, size);
    try populateLocked(space, fit.address, size, flags);
    state.insertAt(fit.index, .{ .address = fit.address, .size = size });
    return fit.address;
}

/// Reserve virtual addresses without allocating page tables or physical frames.
pub fn reserve(space: *AddressSpace, length: u64) Error!u64 {
    const size = try sizeOf(length, MAX_RESERVATION);
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    try state.ensureSpare();
    const fit = try firstFit(state, size);
    try checkUnmapped(space.pml4, fit.address, size);
    state.insertAt(fit.index, .{ .address = fit.address, .size = size, .sparse = true });
    return fit.address;
}

/// Release a page-aligned subrange. A middle removal splits one owned region
/// into two, so it needs a spare metadata slot before changing any mappings.
pub fn unmap(space: *AddressSpace, address: u64, length: u64) Error!void {
    const size = try sizeOf(length, LIMIT);
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    const contained = findContaining(state, address, length, LIMIT) catch null;
    if (contained == null or state.items[contained.?].lazy) return unmapLazyLocked(space, address, size);
    const index = contained.?;
    const region = state.items[index];
    const old_end = region.end();
    const end = address + size;
    const splits = address > region.address and end < old_end;
    if (splits) try state.ensureSpare();

    detachLocked(space, address, size, true);
    if (address == region.address and end == old_end) {
        state.removeAt(index);
    } else if (address == region.address) {
        state.items[index] = .{ .address = end, .size = @intCast(old_end - end), .sparse = region.sparse };
    } else {
        state.items[index].size = @intCast(address - region.address);
        if (splits) state.insertAt(index + 1, .{ .address = end, .size = @intCast(old_end - end), .sparse = region.sparse });
    }
}

pub fn protect(space: *AddressSpace, address: u64, length: u64, prot: u64) Error!void {
    const flags = try flagsFor(prot);
    const guard = space.lockVm();
    defer guard.unlock();
    if (findIndex(&space.anonymous_vm, address)) |i| {
        if (space.anonymous_vm.items[i].lazy) return protectLazyLocked(space, address, length, @intCast(if (prot == 4) 5 else prot));
    }
    const size = try sizeOf(length, MAX_MAPPING);
    const in_image = address % vmm.PAGE_SIZE == 0 and address >= space.image_start and
        address + size <= space.image_end and space.image_end > space.image_start;
    if (!in_image) _ = try findContaining(&space.anonymous_vm, address, length, MAX_MAPPING);
    // Sparse reservations can contain holes; fail before changing any page.
    var off: usize = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        if (vmm.translate(space.pml4, address + off) == null) return error.Invalid;
    }
    off = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        const phys = vmm.translate(space.pml4, address + off).?;
        vmm.mapPage(space.pml4, address + off, phys, flags | vmm.OWNED) catch unreachable;
    }
    // Both directions: a stale writable entry breaks read-only memory, and a
    // stale read-only one would fault (fatally) on a now-permitted write.
    space.invalidateRange(address, size / vmm.PAGE_SIZE);
}

/// Commit zeroed physical pages inside one sparse reservation. Overlap is
/// rejected, so rollback on allocation failure never touches older commits.
pub fn commit(space: *AddressSpace, address: u64, length: u64, prot: u64) Error!void {
    const flags = try flagsFor(prot);
    if (prot == 0) return error.Invalid;
    const size = try sizeOf(length, MAX_MAPPING);
    const guard = space.lockVm();
    defer guard.unlock();
    const index = try findContaining(&space.anonymous_vm, address, length, MAX_MAPPING);
    if (!space.anonymous_vm.items[index].sparse) return error.Invalid;
    try checkUnmapped(space.pml4, address, size);
    try populateLocked(space, address, size, flags);
}

/// Return committed frames to the PMM while retaining the virtual reservation.
pub fn decommit(space: *AddressSpace, address: u64, length: u64) Error!void {
    const size = try sizeOf(length, MAX_MAPPING);
    const guard = space.lockVm();
    defer guard.unlock();
    const index = try findContaining(&space.anonymous_vm, address, length, MAX_MAPPING);
    if (!space.anonymous_vm.items[index].sparse) return error.Invalid;
    detachLocked(space, address, size, true);
}

/// Release every anonymous region. Used for final teardown (no task left in
/// the space) and by kernel tests resetting a space they own alone.
pub fn releaseAll(space: *AddressSpace) void {
    const guard = space.lockVm();
    defer guard.unlock();
    for (space.anonymous_vm.slice()) |r| {
        detachLocked(space, r.address, r.size, ownsFrames(r));
        releaseBacking(r);
    }
    space.anonymous_vm.deinit();
}

// ── Lazy regions: the Linux mmap model ──────────────────────────────────────
//
// A lazy region has one protection for all its pages, and a page is only
// given a frame when first touched (by the program, through a page fault,
// or by the kernel copying to or from it). mprotect, munmap and madvise
// split regions at their range boundaries, so a region never needs more
// than one protection. Contents survive protection changes: pages made
// PROT_NONE stay mapped for the kernel only, as a JIT expects.

/// Index of the region containing `address`, if any.
fn findIndex(state: *const State, address: u64) ?usize {
    var low: usize = 0;
    var high: usize = state.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (state.items[middle].address <= address) low = middle + 1 else high = middle;
    }
    if (low == 0) return null;
    return if (address < state.items[low - 1].end()) low - 1 else null;
}

/// Make `address` a region boundary, splitting the region containing it.
fn splitAt(state: *State, address: u64) Error!void {
    const i = findIndex(state, address) orelse return;
    const r = state.items[i];
    if (r.address == address) return;
    try state.ensureSpare();
    var right = r;
    right.address = address;
    right.size = @intCast(r.end() - address);
    right.backing = backingFrom(r, address);
    duplicateBacking(r);
    state.items[i].size = @intCast(address - r.address);
    state.insertAt(i + 1, right);
}

/// Range of region indices wholly inside [address, end), after splitting.
const Span = struct { first: usize, last: usize };

fn spanOf(state: *const State, address: u64, end: u64) ?Span {
    var first: ?usize = null;
    var last: usize = 0;
    for (state.slice(), 0..) |r, i| {
        if (r.end() <= address) continue;
        if (r.address >= end) break;
        if (first == null) first = i;
        last = i;
    }
    return if (first) |f| .{ .first = f, .last = last } else null;
}

pub const Placement = enum { anywhere, hint, fixed, fixed_noreplace };

/// mmap for anonymous private memory: a lazy region of `length` bytes with
/// `prot`. `address` is ignored (anywhere), preferred when free (hint),
/// required with whatever lazy mappings are there replaced (fixed), or
/// required and free (fixed_noreplace). Fixed placements stay inside the
/// anonymous arena.
pub fn mapLazy(space: *AddressSpace, address: u64, length: u64, prot: u64, placement: Placement) Error!u64 {
    return mapBacked(space, address, length, prot, placement, .anonymous);
}

/// mapLazy with a backing. On success the region owns the backing's
/// reference (see duplicateBacking); on failure the caller keeps it.
pub fn mapBacked(space: *AddressSpace, address: u64, length: u64, prot: u64, placement: Placement, backing: Backing) Error!u64 {
    const size = try sizeOf(length, MAX_RESERVATION);
    _ = try flagsFor(prot);
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    const inside = address % vmm.PAGE_SIZE == 0 and address >= BASE and address <= BASE + LIMIT - size;
    var base: u64 = 0;
    switch (placement) {
        .fixed, .fixed_noreplace => {
            if (!inside) return error.Invalid;
            if (spanOf(state, address, address + size) != null) {
                if (placement == .fixed_noreplace) return error.Exists;
                try unmapLazyLocked(space, address, size);
            }
            try checkUnmapped(space.pml4, address, size);
            base = address;
        },
        .hint => {
            if (inside and spanOf(state, address, address + size) == null and !vmm.anyMapped(space.pml4, address, size)) {
                base = address;
            } else base = (try firstFit(state, size)).address;
        },
        .anywhere => base = (try firstFit(state, size)).address,
    }
    try checkUnmapped(space.pml4, base, size);
    try state.ensureSpare();
    var at: usize = 0;
    while (at < state.len and state.items[at].address < base) : (at += 1) {}
    state.insertAt(at, .{ .address = base, .size = size, .lazy = true, .prot = @intCast(if (prot == 4) 5 else prot), .backing = backing });
    return base;
}

/// munmap over lazy regions: every part of [address, address + size) that
/// belongs to one goes; holes are allowed, as on Linux, but not a range
/// that touches no region or touches one managed by the native calls.
fn unmapLazyLocked(space: *AddressSpace, address: u64, size: usize) Error!void {
    const state = &space.anonymous_vm;
    const end = std.math.add(u64, address, size) catch return error.Invalid;
    if (address % vmm.PAGE_SIZE != 0) return error.Invalid;
    const span = spanOf(state, address, end) orelse return error.Invalid;
    for (state.items[span.first .. span.last + 1]) |r| if (!r.lazy) return error.Invalid;
    try splitAt(state, address);
    try splitAt(state, end);
    const inner = spanOf(state, address, end).?;
    var i = inner.last + 1;
    while (i > inner.first) {
        i -= 1;
        const r = state.items[i];
        detachLocked(space, r.address, r.size, ownsFrames(r));
        releaseBacking(r);
        state.removeAt(i);
    }
}

fn protectLazyLocked(space: *AddressSpace, address: u64, length: u64, prot: u8) Error!void {
    const state = &space.anonymous_vm;
    const size = try sizeOf(length, LIMIT);
    const end = address + size;
    // The whole range must be lazy regions without holes.
    var cursor = address;
    const span = spanOf(state, address, end) orelse return error.Invalid;
    for (state.items[span.first .. span.last + 1]) |r| {
        if (!r.lazy or r.address > cursor) return error.Invalid;
        cursor = r.end();
    }
    if (cursor < end) return error.Invalid;
    try splitAt(state, address);
    try splitAt(state, end);
    const inner = spanOf(state, address, end).?;
    // A shared mapping made writable must be allowed by the file's seals.
    for (state.items[inner.first .. inner.last + 1]) |r| switch (r.backing) {
        .shared => |b| if (!writable(r.prot) and writable(prot)) {
            tmpfs.changeMappingAccess(b.inode, true) catch return error.Unsupported;
            tmpfs.changeMappingAccess(b.inode, false) catch unreachable;
        },
        else => {},
    };
    for (state.items[inner.first .. inner.last + 1]) |*r| {
        switch (r.backing) {
            .shared => |b| if (writable(r.prot) != writable(prot)) tmpfs.changeMappingAccess(b.inode, writable(prot)) catch unreachable,
            else => {},
        }
        r.prot = prot;
        // Pages already present take the new protection now.
        const flags = (flagsFor(prot) catch unreachable) | (if (ownsFrames(r.*)) vmm.OWNED else 0);
        var page = r.address;
        while (vmm.nextPossiblyMapped(space.pml4, page, r.end())) |next| {
            page = next;
            const block_end = @min(r.end(), (page | (BLOCK_2M - 1)) + 1);
            while (page < block_end) : (page += vmm.PAGE_SIZE) {
                if (vmm.translate(space.pml4, page)) |phys| vmm.mapPage(space.pml4, page, phys, flags) catch unreachable;
            }
        }
    }
    space.invalidateRange(address, size / vmm.PAGE_SIZE);
}

/// madvise(MADV_DONTNEED): release the frames of lazy pages in the range;
/// the next touch reads zeros.
pub fn discard(space: *AddressSpace, address: u64, length: u64) Error!void {
    const size = try sizeOf(length, LIMIT);
    if (address % vmm.PAGE_SIZE != 0) return error.Invalid;
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    const end = address + size;
    const span = spanOf(state, address, end) orelse return error.Invalid;
    for (state.items[span.first .. span.last + 1]) |r| if (!r.lazy) return error.Invalid;
    for (state.items[span.first .. span.last + 1]) |r| {
        const from = @max(r.address, address);
        const to = @min(r.end(), end);
        // Shared pages are only unmapped: their contents stay in the file.
        detachLocked(space, from, to - from, ownsFrames(r));
    }
}

/// mremap of one lazy region's range: shrink in place, grow in place when
/// the addresses after it are free, or (when allowed to move) move its
/// pages to a new range without copying them.
pub fn remap(space: *AddressSpace, address: u64, old_length: u64, new_length: u64, may_move: bool) Error!u64 {
    const old_size = try sizeOf(old_length, LIMIT);
    const new_size = try sizeOf(new_length, MAX_RESERVATION);
    if (address % vmm.PAGE_SIZE != 0) return error.Invalid;
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    const i = findIndex(state, address) orelse return error.Invalid;
    const r = state.items[i];
    if (!r.lazy or r.backing != .anonymous or address + old_size > r.end()) return error.Invalid;
    if (new_size == old_size) return address;
    if (new_size < old_size) {
        try unmapLazyLocked(space, address + new_size, old_size - new_size);
        return address;
    }
    // Grow in place: the range must end where the region does, and what
    // follows must be free.
    const grow_end = address + new_size;
    if (address + old_size == r.end() and grow_end <= BASE + LIMIT and
        spanOf(state, r.end(), grow_end) == null and !vmm.anyMapped(space.pml4, r.end(), grow_end - r.end()))
    {
        state.items[i].size = @intCast(grow_end - r.address);
        return address;
    }
    if (!may_move) return error.OutOfMemory;
    // Move: a new region, the present pages carried over, the old range gone.
    const fit = try firstFit(state, new_size);
    try state.ensureSpare();
    try checkUnmapped(space.pml4, fit.address, new_size);
    const flags = flagsFor(r.prot) catch unreachable;
    var moved: usize = 0;
    while (moved < old_size) : (moved += vmm.PAGE_SIZE) {
        const phys = vmm.translate(space.pml4, address + moved) orelse continue;
        vmm.mapPage(space.pml4, fit.address + moved, phys, flags | vmm.OWNED) catch {
            // Undo the copies made so far without freeing: the old range
            // still owns those frames.
            detachLocked(space, fit.address, moved + vmm.PAGE_SIZE, false);
            return error.OutOfMemory;
        };
    }
    var at: usize = 0;
    while (at < state.len and state.items[at].address < fit.address) : (at += 1) {}
    state.insertAt(at, .{ .address = fit.address, .size = new_size, .lazy = true, .prot = r.prot });
    // Detach the old translations without freeing: the frames moved.
    try splitAt(state, address);
    try splitAt(state, address + old_size);
    const inner = spanOf(state, address, address + old_size).?;
    var k = inner.last + 1;
    while (k > inner.first) {
        k -= 1;
        const old = state.items[k];
        detachLocked(space, old.address, old.size, false);
        state.removeAt(k);
    }
    return fit.address;
}

pub const Access = enum { read, write, execute };

fn permits(prot: u8, access: Access) bool {
    return switch (access) {
        .read => prot & 1 != 0,
        .write => prot & 2 != 0,
        .execute => prot & 4 != 0,
    };
}

/// Give the page holding `address` a frame, if it lies in a lazy region that
/// permits `access`. True when the page is (now) present. Takes the VM lock:
/// call with interrupts enabled and no address-space access held.
pub fn faultIn(space: *AddressSpace, address: u64, access: Access) bool {
    const page = address & ~@as(u64, vmm.PAGE_SIZE - 1);
    var file_copy: ?u64 = null;
    defer if (file_copy) |frame| pmm.freePage(frame);
    while (true) {
        const step = blk: {
            const guard = space.lockVm();
            defer guard.unlock();
            break :blk faultStepLocked(space, page, access, &file_copy);
        };
        switch (step) {
            .resolved => return true,
            .refused => return false,
            // Read the file without the VM lock (it may wait for the disk),
            // then look again: the region may have changed meanwhile.
            .read => |request| {
                defer vfs.release(request.node);
                const frame = pmm.allocPageZeroed() catch return false;
                const bytes: [*]u8 = @ptrFromInt(pmm.physToVirt(frame));
                _ = vfs.readAt(&request.node, request.offset, bytes[0..vmm.PAGE_SIZE]) catch 0;
                file_copy = frame;
            },
        }
    }
}

const FaultStep = union(enum) {
    resolved,
    refused,
    read: struct { node: vfs.Node, offset: u64 },
};

/// Caller holds the VM lock. A file page read earlier arrives in `file_copy`
/// and is taken (set to null) when mapped.
fn faultStepLocked(space: *AddressSpace, page: u64, access: Access, file_copy: *?u64) FaultStep {
    const i = findIndex(&space.anonymous_vm, page) orelse return .refused;
    const r = space.anonymous_vm.items[i];
    if (!r.lazy or !permits(r.prot, access)) return .refused;
    // Another thread may have faulted it in meanwhile.
    if (vmm.translate(space.pml4, page) != null) return .resolved;
    const flags = flagsFor(r.prot) catch return .refused;
    switch (r.backing) {
        .anonymous => {
            _ = vmm.allocAndMap(space.pml4, page, flags) catch return .refused;
            return .resolved;
        },
        .shared => |b| {
            const phys = tmpfs.frameOf(b.inode, (b.offset + (page - r.address)) / vmm.PAGE_SIZE) orelse return .refused;
            vmm.mapPage(space.pml4, page, phys, flags) catch return .refused;
            return .resolved;
        },
        .file => |b| {
            const frame = file_copy.* orelse return .{ .read = .{ .node = vfs.retain(b.ref.node), .offset = b.offset + (page - r.address) } };
            vmm.mapPage(space.pml4, page, frame, flags | vmm.OWNED) catch return .refused;
            file_copy.* = null;
            return .resolved;
        },
    }
}

/// The main thread's stack: a lazy read/write region of `size` bytes ending
/// at `top`, with its top `eager` bytes present now (exec writes the
/// arguments there). Below it nothing is mapped, so an overflow faults.
pub fn mapStack(space: *AddressSpace, top: u64, size: usize, eager: usize) Error!void {
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    const base = top - size;
    try checkUnmapped(space.pml4, base, size);
    try state.ensureSpare();
    try populateLocked(space, top - eager, eager, flagsFor(3) catch unreachable);
    state.insertAt(state.len, .{ .address = base, .size = size, .lazy = true, .prot = 3 });
}
