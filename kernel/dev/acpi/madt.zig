//! MADT — Multiple APIC Description Table.
//!
//! Entries are packed byte structures in firmware memory with no alignment
//! guarantee, so every pointer into them is `align(1)`.
//!
//! Describes the machine's interrupt topology: where the local APIC registers
//! live, which CPUs exist, where the I/O APICs are, and how legacy ISA IRQs
//! have been remapped onto global system interrupts.

const std = @import("std");
const acpi = @import("acpi.zig");
const console = @import("../../console.zig");

pub const Error = error{NoMadt};

const EntryType = enum(u8) {
    local_apic = 0,
    io_apic = 1,
    interrupt_source_override = 2,
    nmi_source = 3,
    local_apic_nmi = 4,
    local_apic_address_override = 5,
    _,
};

const EntryHeader = extern struct {
    type: EntryType,
    length: u8,
};

const LocalApic = extern struct {
    header: EntryHeader,
    acpi_processor_id: u8,
    apic_id: u8,
    flags: u32 align(1),
};

const IoApic = extern struct {
    header: EntryHeader,
    id: u8,
    reserved: u8,
    address: u32 align(1),
    gsi_base: u32 align(1),
};

const InterruptSourceOverride = extern struct {
    header: EntryHeader,
    bus: u8,
    source: u8,
    gsi: u32 align(1),
    flags: u16 align(1),
};

const LocalApicAddressOverride = extern struct {
    header: EntryHeader,
    reserved: u16 align(1),
    address: u64 align(1),
};

pub const MAX_CPUS = 32;
pub const MAX_IOAPICS = 4;
pub const MAX_OVERRIDES = 16;

pub const IoApicInfo = struct {
    id: u8,
    address: u64,
    gsi_base: u32,
};

pub const Override = struct {
    source: u8,
    gsi: u32,
    flags: u16,
};

var lapic_address: u64 = 0;
var cpu_apic_ids: [MAX_CPUS]u8 = undefined;
var cpu_count: usize = 0;
var ioapics: [MAX_IOAPICS]IoApicInfo = undefined;
var ioapic_count: usize = 0;
var overrides: [MAX_OVERRIDES]Override = undefined;
var override_count: usize = 0;
var pic_present: bool = false;

pub fn init() Error!void {
    const hdr = acpi.find("APIC") orelse return Error.NoMadt;
    const payload = acpi.payloadOf(hdr);

    lapic_address = std.mem.readInt(u32, payload[0..4], .little);
    const flags = std.mem.readInt(u32, payload[4..8], .little);
    pic_present = flags & 1 != 0;

    var offset: usize = 8;
    const end = hdr.length - @sizeOf(acpi.SdtHeader);

    while (offset + 2 <= end) {
        const e: *align(1) const EntryHeader = @ptrCast(payload + offset);
        if (e.length < 2) break; // malformed; refuse to loop forever

        switch (e.type) {
            .local_apic => {
                const la: *align(1) const LocalApic = @ptrCast(payload + offset);
                // Bit 0 = enabled, bit 1 = online-capable.
                if ((la.flags & 1 != 0 or la.flags & 2 != 0) and cpu_count < MAX_CPUS) {
                    cpu_apic_ids[cpu_count] = la.apic_id;
                    cpu_count += 1;
                }
            },
            .io_apic => {
                const io: *align(1) const IoApic = @ptrCast(payload + offset);
                if (ioapic_count < MAX_IOAPICS) {
                    ioapics[ioapic_count] = .{
                        .id = io.id,
                        .address = io.address,
                        .gsi_base = io.gsi_base,
                    };
                    ioapic_count += 1;
                }
            },
            .interrupt_source_override => {
                const iso: *align(1) const InterruptSourceOverride = @ptrCast(payload + offset);
                if (override_count < MAX_OVERRIDES) {
                    overrides[override_count] = .{
                        .source = iso.source,
                        .gsi = iso.gsi,
                        .flags = iso.flags,
                    };
                    override_count += 1;
                }
            },
            .local_apic_address_override => {
                const ov: *align(1) const LocalApicAddressOverride = @ptrCast(payload + offset);
                lapic_address = ov.address;
            },
            else => {},
        }

        offset += e.length;
    }
}

/// ISA IRQ -> global system interrupt, honoring any firmware remapping.
/// On most machines IRQ 0 (the PIT) is remapped to GSI 2.
pub fn gsiForIrq(irq: u8) u32 {
    var i: usize = 0;
    while (i < override_count) : (i += 1) {
        if (overrides[i].source == irq) return overrides[i].gsi;
    }
    return irq;
}

pub fn overrideFlags(irq: u8) u16 {
    var i: usize = 0;
    while (i < override_count) : (i += 1) {
        if (overrides[i].source == irq) return overrides[i].flags;
    }
    return 0;
}

pub fn lapicAddress() u64 {
    return lapic_address;
}

/// LAPIC id of the Nth enabled processor.
pub fn cpuApicId(index: usize) ?u8 {
    if (index >= cpu_count) return null;
    return cpu_apic_ids[index];
}

pub fn cpuCount() usize {
    return cpu_count;
}

pub fn ioApics() []const IoApicInfo {
    return ioapics[0..ioapic_count];
}

pub fn legacyPicPresent() bool {
    return pic_present;
}

pub fn report() void {
    console.print("[ ok ] MADT: {d} CPU(s), {d} I/O APIC(s), {d} IRQ override(s)\n", .{
        cpu_count, ioapic_count, override_count,
    });
    console.print("[info] LAPIC at 0x{x}, legacy PIC {s}\n", .{
        lapic_address,
        if (pic_present) "present" else "absent",
    });
}
