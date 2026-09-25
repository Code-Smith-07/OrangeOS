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
const AddressSpace = @import("address_space.zig").AddressSpace;

pub const BASE: u64 = 0x0000_4000_0000_0000;
pub const LIMIT: usize = 8 * 1024 * 1024 * 1024;
pub const MAX_MAPPING: usize = 64 * 1024 * 1024;
pub const MAX_RESERVATION: usize = 4 * 1024 * 1024 * 1024;
pub const MAX_MAPPINGS = 128;
pub const Region = struct { address: u64 = 0, size: usize = 0, sparse: bool = false };
/// Region metadata. Guarded by the owning AddressSpace's VM lock.
pub const State = struct {
    regions: [MAX_MAPPINGS]Region = [_]Region{.{}} ** MAX_MAPPINGS,
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

fn emptySlot(state: *State) Error!*Region {
    for (&state.regions) |*r| if (r.size == 0) {
        return r;
    };
    return error.OutOfMemory;
}

fn firstFit(state: *State, size: usize) Error!u64 {
    // First fit reuses released addresses, including holes between live regions.
    var base = BASE;
    while (true) {
        if (base + size > BASE + LIMIT) return error.OutOfMemory;
        var next = base;
        for (state.regions) |r| {
            if (r.size != 0 and base < r.address + r.size and base + size > r.address)
                next = @max(next, r.address + r.size);
        }
        if (next == base) break;
        base = next;
    }
    return base;
}

fn checkUnmapped(pml4: u64, base: u64, size: usize) Error!void {
    // Never overwrite image/device/shared mappings, even for an unusual ELF.
    var off: usize = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        if (vmm.translate(pml4, base + off) != null) return error.Invalid;
    }
}

fn findContaining(state: *State, address: u64, length: u64, max: usize) Error!*Region {
    const size = try sizeOf(length, max);
    if (address % vmm.PAGE_SIZE != 0) return error.Invalid;
    const end = std.math.add(u64, address, size) catch return error.Invalid;
    for (&state.regions) |*r| {
        if (r.size != 0 and address >= r.address and end <= r.address + r.size) return r;
    }
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
    const region = try emptySlot(state);
    const base = try firstFit(state, size);
    try checkUnmapped(space.pml4, base, size);
    try populateLocked(space, base, size, flags);
    region.* = .{ .address = base, .size = size };
    return base;
}

/// Reserve virtual addresses without allocating page tables or physical frames.
pub fn reserve(space: *AddressSpace, length: u64) Error!u64 {
    const size = try sizeOf(length, MAX_RESERVATION);
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    const region = try emptySlot(state);
    const base = try firstFit(state, size);
    try checkUnmapped(space.pml4, base, size);
    region.* = .{ .address = base, .size = size, .sparse = true };
    return base;
}

/// Release a page-aligned subrange. A middle removal splits one owned region
/// into two, so it needs a spare metadata slot before changing any mappings.
pub fn unmap(space: *AddressSpace, address: u64, length: u64) Error!void {
    const size = try sizeOf(length, MAX_RESERVATION);
    const guard = space.lockVm();
    defer guard.unlock();
    const state = &space.anonymous_vm;
    const region = try findContaining(state, address, length, MAX_RESERVATION);
    const old_end = region.address + region.size;
    const end = address + size;
    var right: ?*Region = null;
    if (address > region.address and end < old_end) {
        for (&state.regions) |*r| {
            if (r.size == 0) {
                right = r;
                break;
            }
        }
        if (right == null) return error.OutOfMemory;
    }

    detachLocked(space, address, size, true);
    if (address == region.address and end == old_end) {
        region.* = .{};
    } else if (address == region.address) {
        region.* = .{ .address = end, .size = @intCast(old_end - end), .sparse = region.sparse };
    } else {
        region.size = @intCast(address - region.address);
        if (right) |slot| slot.* = .{ .address = end, .size = @intCast(old_end - end), .sparse = region.sparse };
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
    const region = try findContaining(&space.anonymous_vm, address, length, MAX_MAPPING);
    if (!region.sparse) return error.Invalid;
    try checkUnmapped(space.pml4, address, size);
    try populateLocked(space, address, size, flags);
}

/// Return committed frames to the PMM while retaining the virtual reservation.
pub fn decommit(space: *AddressSpace, address: u64, length: u64) Error!void {
    const size = try sizeOf(length, MAX_MAPPING);
    const guard = space.lockVm();
    defer guard.unlock();
    const region = try findContaining(&space.anonymous_vm, address, length, MAX_MAPPING);
    if (!region.sparse) return error.Invalid;
    detachLocked(space, address, size, true);
}

/// Release every anonymous region. Used for final teardown (no task left in
/// the space) and by kernel tests resetting a space they own alone.
pub fn releaseAll(space: *AddressSpace) void {
    const guard = space.lockVm();
    defer guard.unlock();
    for (&space.anonymous_vm.regions) |*r| {
        if (r.size != 0) detachLocked(space, r.address, r.size, true);
        r.* = .{};
    }
}
