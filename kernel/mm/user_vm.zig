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
    sparse: bool = false,

    fn end(self: Region) u64 {
        return self.address + self.size;
    }
};

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
        const grown: usize = @min(@max(128, self.capacity * 2), MAX_MAPPINGS);
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
pub const Error = error{ Invalid, Unsupported, OutOfMemory };

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
    const size = try sizeOf(length, MAX_RESERVATION);
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    const index = try findContaining(state, address, length, MAX_RESERVATION);
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
    _ = try findContaining(&space.anonymous_vm, address, length, MAX_MAPPING);
    const size = try sizeOf(length, MAX_MAPPING);
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
    for (space.anonymous_vm.slice()) |r| detachLocked(space, r.address, r.size, true);
    space.anonymous_vm.deinit();
}
