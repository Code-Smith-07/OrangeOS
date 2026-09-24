//! Owned anonymous mappings. Mutations are serialized per State and changed
//! local translations are invalidated before any frame or page-table reuse.
//! State belongs to the reference-counted AddressSpace. Only one task still
//! executes in it; remote shootdown, user-pointer pinning and coordinated
//! mutations are required before shared user threads.
const std = @import("std");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const tlb = @import("tlb.zig");
const spinlock = @import("../sync/spinlock.zig");

pub const BASE: u64 = 0x0000_4000_0000_0000;
pub const LIMIT: usize = 8 * 1024 * 1024 * 1024;
pub const MAX_MAPPING: usize = 64 * 1024 * 1024;
pub const MAX_RESERVATION: usize = 4 * 1024 * 1024 * 1024;
pub const MAX_MAPPINGS = 128;
pub const Region = struct { address: u64 = 0, size: usize = 0, sparse: bool = false };
pub const State = struct {
    lock: spinlock.SpinLock = .{},
    regions: [MAX_MAPPINGS]Region = [_]Region{.{}} ** MAX_MAPPINGS,
};
pub const Error = error{ Invalid, Unsupported, OutOfMemory };

fn sizeOf(length: u64, max: usize) Error!usize {
    if (length == 0 or length > max) return error.Invalid;
    return std.mem.alignForward(usize, @intCast(length), vmm.PAGE_SIZE);
}

fn flagsFor(prot: u64) Error!u64 {
    // Initial interpreter/runtime support only: no executable anonymous pages,
    // no JIT or writable/executable transitions until the sandbox exists.
    if (prot != 0 and prot != 1 and prot != 3) return error.Unsupported;
    return vmm.PRESENT | vmm.NO_EXECUTE |
        (if (prot != 0) vmm.USER else @as(u64, 0)) |
        (if (prot == 3) vmm.WRITABLE else @as(u64, 0));
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

pub fn map(state: *State, pml4: u64, length: u64, prot: u64) Error!u64 {
    const size = try sizeOf(length, MAX_MAPPING);
    const flags = try flagsFor(prot);
    state.lock.acquire();
    defer state.lock.release();
    const region = try emptySlot(state);
    const base = try firstFit(state, size);
    try checkUnmapped(pml4, base, size);
    var off: usize = 0;
    errdefer releasePages(pml4, base, off);
    while (off < size) : (off += vmm.PAGE_SIZE) {
        _ = vmm.allocAndMap(pml4, base + off, flags) catch {
            // mapPage can create empty intermediate tables before failing.
            vmm.pruneEmptyTables(pml4, base + off);
            return error.OutOfMemory;
        };
    }
    tlb.invalidateExclusiveRange(pml4, base, size / vmm.PAGE_SIZE);
    region.* = .{ .address = base, .size = size };
    return base;
}

/// Reserve virtual addresses without allocating page tables or physical frames.
pub fn reserve(state: *State, pml4: u64, length: u64) Error!u64 {
    const size = try sizeOf(length, MAX_RESERVATION);
    state.lock.acquire();
    defer state.lock.release();
    const region = try emptySlot(state);
    const base = try firstFit(state, size);
    try checkUnmapped(pml4, base, size);
    region.* = .{ .address = base, .size = size, .sparse = true };
    return base;
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

fn releasePages(pml4: u64, address: u64, size: usize) void {
    const Entry = struct { address: u64, phys: u64 };
    var off: usize = 0;
    while (off < size) {
        const count = @min((size - off) / vmm.PAGE_SIZE, 64);
        var entries: [64]Entry = undefined;
        var used: usize = 0;
        for (0..count) |i| {
            const va = address + off + i * vmm.PAGE_SIZE;
            if (vmm.detachPage(pml4, va)) |phys| {
                entries[used] = .{ .address = va, .phys = phys };
                used += 1;
            }
        }
        if (used != 0) {
            tlb.invalidateExclusiveRange(pml4, address + off, count);
            for (entries[0..used]) |entry| {
                pmm.freePage(entry.phys);
                vmm.pruneEmptyTables(pml4, entry.address);
            }
        }
        off += count * vmm.PAGE_SIZE;
    }
}

/// Release a page-aligned subrange. A middle removal splits one owned region
/// into two, so it needs a spare metadata slot before changing any mappings.
pub fn unmap(state: *State, pml4: u64, address: u64, length: u64) Error!void {
    const size = try sizeOf(length, MAX_RESERVATION);
    state.lock.acquire();
    defer state.lock.release();
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

    releasePages(pml4, address, size);
    if (address == region.address and end == old_end) {
        region.* = .{};
    } else if (address == region.address) {
        region.* = .{ .address = end, .size = @intCast(old_end - end), .sparse = region.sparse };
    } else {
        region.size = @intCast(address - region.address);
        if (right) |slot| slot.* = .{ .address = end, .size = @intCast(old_end - end), .sparse = region.sparse };
    }
}

pub fn protect(state: *State, pml4: u64, address: u64, length: u64, prot: u64) Error!void {
    const flags = try flagsFor(prot);
    state.lock.acquire();
    defer state.lock.release();
    _ = try findContaining(state, address, length, MAX_MAPPING);
    const size = try sizeOf(length, MAX_MAPPING);
    // Sparse reservations can contain holes; fail before changing any page.
    var off: usize = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        if (vmm.translate(pml4, address + off) == null) return error.Invalid;
    }
    off = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        const phys = vmm.translate(pml4, address + off).?;
        vmm.mapPage(pml4, address + off, phys, flags | vmm.OWNED) catch unreachable;
    }
    tlb.invalidateExclusiveRange(pml4, address, size / vmm.PAGE_SIZE);
}

/// Commit zeroed physical pages inside one sparse reservation. Overlap is
/// rejected, so rollback on allocation failure never touches older commits.
pub fn commit(state: *State, pml4: u64, address: u64, length: u64, prot: u64) Error!void {
    const flags = try flagsFor(prot);
    if (prot == 0) return error.Invalid;
    const size = try sizeOf(length, MAX_MAPPING);
    state.lock.acquire();
    defer state.lock.release();
    const region = try findContaining(state, address, length, MAX_MAPPING);
    if (!region.sparse) return error.Invalid;
    try checkUnmapped(pml4, address, size);
    var off: usize = 0;
    errdefer releasePages(pml4, address, off);
    while (off < size) : (off += vmm.PAGE_SIZE) {
        _ = vmm.allocAndMap(pml4, address + off, flags) catch {
            vmm.pruneEmptyTables(pml4, address + off);
            return error.OutOfMemory;
        };
    }
    tlb.invalidateExclusiveRange(pml4, address, size / vmm.PAGE_SIZE);
}

/// Return committed frames to the PMM while retaining the virtual reservation.
pub fn decommit(state: *State, pml4: u64, address: u64, length: u64) Error!void {
    const size = try sizeOf(length, MAX_MAPPING);
    state.lock.acquire();
    defer state.lock.release();
    const region = try findContaining(state, address, length, MAX_MAPPING);
    if (!region.sparse) return error.Invalid;
    releasePages(pml4, address, size);
}

pub fn releaseAll(state: *State, pml4: u64) void {
    state.lock.acquire();
    defer state.lock.release();
    for (&state.regions) |*r| {
        if (r.size != 0) releasePages(pml4, r.address, r.size);
        r.* = .{};
    }
}
