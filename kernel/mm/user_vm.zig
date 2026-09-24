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

fn findContaining(state: *State, address: u64, length: u64) Error!*Region {
    const size = try sizeOf(length);
    if (address % vmm.PAGE_SIZE != 0) return error.Invalid;
    const end = std.math.add(u64, address, size) catch return error.Invalid;
    for (&state.regions) |*r| {
        if (r.size != 0 and address >= r.address and end <= r.address + r.size) return r;
    }
    return error.Invalid;
}

fn releasePages(pml4: u64, address: u64, size: usize) void {
    var off: usize = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        if (vmm.unmapPage(pml4, address + off)) |phys| pmm.freePage(phys);
    }
}

/// Release a page-aligned subrange. A middle removal splits one owned region
/// into two, so it needs a spare metadata slot before changing any mappings.
pub fn unmap(state: *State, pml4: u64, address: u64, length: u64) Error!void {
    const size = try sizeOf(length);
    const region = try findContaining(state, address, length);
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
        region.* = .{ .address = end, .size = @intCast(old_end - end) };
    } else {
        region.size = @intCast(address - region.address);
        if (right) |slot| slot.* = .{ .address = end, .size = @intCast(old_end - end) };
    }
}

pub fn protect(state: *State, pml4: u64, address: u64, length: u64, prot: u64) Error!void {
    const flags = try flagsFor(prot);
    _ = try findContaining(state, address, length);
    const size = try sizeOf(length);
    var off: usize = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        // Pages remain owned while PROT_NONE clears their user-access bit.
        const phys = vmm.translate(pml4, address + off) orelse unreachable;
        vmm.mapPage(pml4, address + off, phys, flags | vmm.OWNED) catch unreachable;
        vmm.invalidatePage(address + off);
    }
}

pub fn releaseAll(state: *State, pml4: u64) void {
    for (&state.regions) |*r| {
        if (r.size != 0) releasePages(pml4, r.address, r.size);
        r.* = .{};
    }
}
