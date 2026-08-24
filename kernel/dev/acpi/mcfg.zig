//! MCFG — PCIe memory-mapped configuration space.
//!
//! Legacy PCI config access goes through two I/O ports and can only reach the
//! first 256 bytes of each device's config space. PCIe extends that to 4 KiB
//! and maps it into memory; MCFG tells us where.

const std = @import("std");
const acpi = @import("acpi.zig");

pub const Error = error{NoMcfg};

pub const Allocation = struct {
    base: u64,
    segment: u16,
    start_bus: u8,
    end_bus: u8,
};

const RawAllocation = extern struct {
    base: u64 align(1),
    segment: u16 align(1),
    start_bus: u8,
    end_bus: u8,
    reserved: u32 align(1),
};

pub const MAX_ALLOCATIONS = 4;

var allocations: [MAX_ALLOCATIONS]Allocation = undefined;
var count: usize = 0;

pub fn init() Error!void {
    const hdr = acpi.find("MCFG") orelse return Error.NoMcfg;
    const payload = acpi.payloadOf(hdr);

    // 8 reserved bytes precede the allocation array.
    var offset: usize = 8;
    const end = hdr.length - @sizeOf(acpi.SdtHeader);

    while (offset + @sizeOf(RawAllocation) <= end and count < MAX_ALLOCATIONS) {
        const raw: *align(1) const RawAllocation = @ptrCast(payload + offset);
        allocations[count] = .{
            .base = raw.base,
            .segment = raw.segment,
            .start_bus = raw.start_bus,
            .end_bus = raw.end_bus,
        };
        count += 1;
        offset += @sizeOf(RawAllocation);
    }
}

pub fn list() []const Allocation {
    return allocations[0..count];
}

/// ECAM address for one device's config space.
pub fn configAddress(bus: u8, device: u5, function: u3, offset: u12) ?u64 {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const a = allocations[i];
        if (bus < a.start_bus or bus > a.end_bus) continue;
        const bus_off = @as(u64, bus - a.start_bus) << 20;
        const dev_off = @as(u64, device) << 15;
        const fn_off = @as(u64, function) << 12;
        return a.base + bus_off + dev_off + fn_off + offset;
    }
    return null;
}
