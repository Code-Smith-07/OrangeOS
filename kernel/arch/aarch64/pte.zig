//! Page table entries on Arm64 (4 KB pages, 48-bit addresses).
//!
//! The tables have the same shape as x86's: four levels of 512 entries,
//! indexed by the same address bits. Only the bits inside an entry differ,
//! and this file is the translation between the kernel's page flags
//! (mm/page_flags.zig) and Arm's descriptor.
const f = @import("../../mm/page_flags.zig");

pub const ADDR_MASK: u64 = 0x0000_FFFF_FFFF_F000;

const VALID: u64 = 1 << 0;
/// At the upper levels: 1 = points at a table, 0 = maps a block itself.
/// At the last level it must be 1.
const TABLE_OR_PAGE: u64 = 1 << 1;
const ATTR_DEVICE: u64 = 1 << 2; // memory attribute index 1 (boot.S sets MAIR)
const USER: u64 = 1 << 6; // AP[1]: user level may access
const READ_ONLY: u64 = 1 << 7; // AP[2]
const SHARED: u64 = 3 << 8; // inner shareable
const ACCESSED: u64 = 1 << 10; // without it the first touch faults
const NOT_GLOBAL: u64 = 1 << 11; // belongs to one address space
const KERNEL_NO_EXECUTE: u64 = 1 << 53; // PXN
const USER_NO_EXECUTE: u64 = 1 << 54; // UXN
const OWNED: u64 = 1 << 55; // software bit

pub inline fn present(entry: u64) bool {
    return entry & VALID != 0;
}
/// A present entry above the last level that maps memory itself.
pub inline fn huge(entry: u64) bool {
    return entry & (VALID | TABLE_OR_PAGE) == VALID;
}
pub inline fn owned(entry: u64) bool {
    return entry & OWNED != 0;
}
/// An entry that points at the next table down. Arm applies permissions at
/// the last level only, so `wanted` needs nothing here.
pub inline fn table(phys: u64, wanted: u64) u64 {
    _ = wanted;
    return phys | VALID | TABLE_OR_PAGE;
}
pub inline fn widen(entry: u64, wanted: u64) u64 {
    _ = wanted;
    return entry;
}

fn attributes(wanted: u64) u64 {
    var bits: u64 = VALID | ACCESSED;
    if (wanted & f.NO_CACHE != 0) bits |= ATTR_DEVICE else bits |= SHARED;
    if (wanted & f.WRITABLE == 0) bits |= READ_ONLY;
    if (wanted & f.USER != 0) {
        // A user page is never executable by the kernel.
        bits |= USER | NOT_GLOBAL | KERNEL_NO_EXECUTE;
        if (wanted & f.NO_EXECUTE != 0) bits |= USER_NO_EXECUTE;
    } else {
        bits |= USER_NO_EXECUTE;
        if (wanted & f.NO_EXECUTE != 0) bits |= KERNEL_NO_EXECUTE;
    }
    if (wanted & f.OWNED != 0) bits |= OWNED;
    return bits;
}

pub inline fn leaf(phys: u64, wanted: u64) u64 {
    return (phys & ADDR_MASK) | attributes(wanted) | TABLE_OR_PAGE;
}
pub inline fn block(phys: u64, wanted: u64) u64 {
    return (phys & ADDR_MASK) | attributes(wanted);
}

/// The kernel's flags for a present mapping entry.
pub fn flagsOf(entry: u64) u64 {
    var flags: u64 = f.PRESENT;
    if (entry & READ_ONLY == 0) flags |= f.WRITABLE;
    if (entry & ATTR_DEVICE != 0) flags |= f.NO_CACHE;
    if (entry & OWNED != 0) flags |= f.OWNED;
    if (huge(entry)) flags |= f.HUGE;
    if (entry & USER != 0) {
        flags |= f.USER;
        if (entry & USER_NO_EXECUTE != 0) flags |= f.NO_EXECUTE;
    } else if (entry & KERNEL_NO_EXECUTE != 0) flags |= f.NO_EXECUTE;
    return flags;
}

test "flags survive the round trip through an Arm entry" {
    const std = @import("std");
    const cases = [_]u64{
        f.PRESENT,
        f.PRESENT | f.WRITABLE | f.NO_EXECUTE,
        f.PRESENT | f.USER,
        f.PRESENT | f.USER | f.WRITABLE | f.NO_EXECUTE | f.OWNED,
        f.PRESENT | f.WRITABLE | f.NO_EXECUTE | f.NO_CACHE,
    };
    for (cases) |wanted| {
        const entry = leaf(0x4020_3000, wanted);
        try std.testing.expect(present(entry) and !huge(entry));
        try std.testing.expectEqual(wanted, flagsOf(entry));
        try std.testing.expectEqual(@as(u64, 0x4020_3000), entry & ADDR_MASK);
        const big = block(0x4020_0000, wanted);
        try std.testing.expect(present(big) and huge(big));
        try std.testing.expectEqual(wanted | f.HUGE, flagsOf(big));
    }
}

test "kernel text is executable by the kernel only, user pages never by the kernel" {
    const std = @import("std");
    const text = leaf(0, f.PRESENT);
    try std.testing.expect(text & KERNEL_NO_EXECUTE == 0 and text & USER_NO_EXECUTE != 0 and text & READ_ONLY != 0);
    const user_code = leaf(0, f.PRESENT | f.USER);
    try std.testing.expect(user_code & KERNEL_NO_EXECUTE != 0 and user_code & USER_NO_EXECUTE == 0);
    try std.testing.expect(!present(0) and !huge(0));
}
