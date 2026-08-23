//! ACPI table discovery.
//!
//! The firmware describes the machine's interrupt topology, timers, and PCIe
//! configuration space through a tree of tables rooted at the RSDP. We walk
//! that tree to find the ones we need: MADT for interrupt controllers, FADT
//! for power control, HPET for a timer, MCFG for PCIe.
//!
//! ACPI structures live in firmware-owned memory and carry NO alignment
//! guarantee — the RSDP is only 16-byte aligned by convention and table
//! pointers inside the XSDT are packed. Every pointer into them is therefore
//! `align(1)`; assuming natural alignment panics on real firmware.
//!
//! We only *read* ACPI tables. Executing AML — the bytecode in the DSDT — is a
//! whole interpreter and is not needed for anything in the roadmap before
//! power management.

const std = @import("std");
const limine = @import("../../boot/limine_req.zig");
const pmm = @import("../../mm/pmm.zig");
const vmm = @import("../../mm/vmm.zig");
const console = @import("../../console.zig");

pub const Error = error{
    NoRsdp,
    BadRsdp,
    BadChecksum,
    TableNotFound,
};

/// Root System Description Pointer, v1 layout.
const Rsdp = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,
};

/// v2 extends v1 with a 64-bit XSDT pointer.
const Rsdp2 = extern struct {
    v1: Rsdp,
    length: u32,
    xsdt_address: u64 align(4),
    extended_checksum: u8,
    reserved: [3]u8,
};

/// Common header on every ACPI table.
pub const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub fn matches(self: *align(1) const SdtHeader, sig: *const [4]u8) bool {
        return std.mem.eql(u8, &self.signature, sig);
    }
};

var root_phys: u64 = 0;
var use_xsdt: bool = false;
var entry_count: usize = 0;
var acpi_revision: u8 = 0;

/// Sum of all bytes in a structure must be zero.
fn checksumOk(ptr: [*]const u8, len: usize) bool {
    var sum: u8 = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) sum +%= ptr[i];
    return sum == 0;
}

/// Limine may hand back either a physical address or an HHDM-relative one
/// depending on protocol revision. Normalize to a virtual address we can read.
fn toVirt(addr: u64) u64 {
    const hhdm = pmm.hhdmBase();
    return if (addr >= hhdm) addr else pmm.physToVirt(addr);
}

pub fn init() Error!void {
    const rsdp_addr = limine.rsdp() orelse return Error.NoRsdp;
    const rsdp: *align(1) const Rsdp = @ptrFromInt(toVirt(rsdp_addr));

    if (!std.mem.eql(u8, &rsdp.signature, "RSD PTR ")) return Error.BadRsdp;
    if (!checksumOk(@ptrCast(rsdp), @sizeOf(Rsdp))) return Error.BadChecksum;

    acpi_revision = rsdp.revision;

    if (rsdp.revision >= 2) {
        const rsdp2: *align(1) const Rsdp2 = @ptrFromInt(toVirt(rsdp_addr));
        if (checksumOk(@ptrCast(rsdp2), rsdp2.length) and rsdp2.xsdt_address != 0) {
            root_phys = rsdp2.xsdt_address;
            use_xsdt = true;
        }
    }
    if (root_phys == 0) {
        root_phys = rsdp.rsdt_address;
        use_xsdt = false;
    }

    const root: *align(1) const SdtHeader = @ptrFromInt(toVirt(root_phys));
    const payload = root.length - @sizeOf(SdtHeader);
    entry_count = payload / (if (use_xsdt) @as(usize, 8) else 4);
}

/// Physical address of the Nth table listed in the root table.
fn entryPhys(index: usize) u64 {
    const root_virt = toVirt(root_phys);
    const base = root_virt + @sizeOf(SdtHeader);
    if (use_xsdt) {
        // XSDT entries are 8 bytes but only 4-byte aligned in practice.
        const p: [*]align(1) const u64 = @ptrFromInt(base);
        return p[index];
    }
    const p: [*]align(1) const u32 = @ptrFromInt(base);
    return p[index];
}

/// Find a table by its 4-character signature.
pub fn find(sig: *const [4]u8) ?*align(1) const SdtHeader {
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const hdr: *align(1) const SdtHeader = @ptrFromInt(toVirt(entryPhys(i)));
        if (hdr.matches(sig)) return hdr;
    }
    return null;
}

pub fn revision() u8 {
    return acpi_revision;
}

pub fn tableCount() usize {
    return entry_count;
}

pub fn usingXsdt() bool {
    return use_xsdt;
}

/// List every table found, for boot diagnostics.
pub fn listTables() void {
    console.write("[info] ACPI tables: ");
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const hdr: *align(1) const SdtHeader = @ptrFromInt(toVirt(entryPhys(i)));
        console.print("{s} ", .{hdr.signature[0..4]});
    }
    console.write("\n");
}

/// Virtual address of a table's payload, past the common header.
pub fn payloadOf(hdr: *align(1) const SdtHeader) [*]align(1) const u8 {
    const base: [*]const u8 = @ptrCast(hdr);
    return base + @sizeOf(SdtHeader);
}

pub fn virtOf(phys: u64) u64 {
    return toVirt(phys);
}
