//! Owned anonymous mappings. One thread owns each address space today; user
//! threads must add address-space locking and remote TLB invalidation first.
const std = @import("std");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");

pub const BASE: u64 = 0x0000_4000_0000_0000;
pub const LIMIT: usize = 256 * 1024 * 1024;
pub const MAX_MAPPING: usize = 64 * 1024 * 1024;
pub const MAX_MAPPINGS = 128;
pub const Region = struct { address: u64 = 0, size: usize = 0 };
pub const State = struct { regions: [MAX_MAPPINGS]Region = [_]Region{.{}} ** MAX_MAPPINGS };
pub const Error = error{ Invalid, Unsupported, OutOfMemory };

fn sizeOf(length: u64) Error!usize {
    if (length == 0 or length > MAX_MAPPING) return error.Invalid;
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

pub fn map(state: *State, pml4: u64, length: u64, prot: u64) Error!u64 {
    const size = try sizeOf(length);
    const flags = try flagsFor(prot);
    var slot: ?*Region = null;
    for (&state.regions) |*r| if (r.size == 0) {
        slot = r;
        break;
    };
    const region = slot orelse return error.OutOfMemory;
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
    // Never overwrite image/device/shared mappings, even for an unusual ELF.
    var off: usize = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        if (vmm.translate(pml4, base + off) != null) return error.Invalid;
    }
    off = 0;
    errdefer releasePages(pml4, base, off);
    while (off < size) : (off += vmm.PAGE_SIZE) {
        _ = vmm.allocAndMap(pml4, base + off, flags) catch {
            // mapPage can create empty intermediate tables before failing.
            vmm.pruneEmptyTables(pml4, base + off);
            return error.OutOfMemory;
        };
    }
    region.* = .{ .address = base, .size = size };
    return base;
}

fn find(state: *State, address: u64, length: u64) Error!*Region {
    const size = try sizeOf(length);
    if (address % vmm.PAGE_SIZE != 0) return error.Invalid;
    for (&state.regions) |*r| {
        if (r.size == size and r.address == address) return r;
    }
    return error.Invalid;
}

fn releasePages(pml4: u64, address: u64, size: usize) void {
    var off: usize = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        if (vmm.unmapPage(pml4, address + off)) |phys| pmm.freePage(phys);
    }
}

/// Whole-allocation unmap only; partial ranges are explicitly rejected.
pub fn unmap(state: *State, pml4: u64, address: u64, length: u64) Error!void {
    const region = try find(state, address, length);
    releasePages(pml4, address, region.size);
    region.* = .{};
}

pub fn protect(state: *State, pml4: u64, address: u64, length: u64, prot: u64) Error!void {
    const flags = try flagsFor(prot);
    const region = try find(state, address, length);
    var off: usize = 0;
    while (off < region.size) : (off += vmm.PAGE_SIZE) {
        // Pages remain owned while PROT_NONE clears their user-access bit.
        const phys = vmm.translate(pml4, address + off) orelse unreachable;
        vmm.mapPage(pml4, address + off, phys, flags) catch unreachable;
        vmm.invalidatePage(address + off);
    }
}

pub fn releaseAll(state: *State, pml4: u64) void {
    for (&state.regions) |*r| {
        if (r.size != 0) releasePages(pml4, r.address, r.size);
        r.* = .{};
    }
}
