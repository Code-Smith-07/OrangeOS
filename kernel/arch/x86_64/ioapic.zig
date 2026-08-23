//! I/O APIC — routes device interrupts to CPUs.
//!
//! Each entry in its redirection table maps one global system interrupt to a
//! vector on a target CPU. Entries start masked; a driver unmasks its line
//! when it is ready to handle interrupts.

const vmm = @import("../../mm/vmm.zig");
const madt = @import("../../dev/acpi/madt.zig");

const REG_SELECT: usize = 0x00;
const REG_WINDOW: usize = 0x10;

const IOAPIC_ID: u32 = 0x00;
const IOAPIC_VERSION: u32 = 0x01;
const IOAPIC_REDTBL: u32 = 0x10;

pub const MASKED: u64 = 1 << 16;
pub const LEVEL_TRIGGERED: u64 = 1 << 15;
pub const ACTIVE_LOW: u64 = 1 << 13;
pub const LOGICAL_DEST: u64 = 1 << 11;

pub const Error = error{NoIoApic} || vmm.Error;

const Entry = struct {
    base_virt: u64,
    gsi_base: u32,
    gsi_count: u32,
};

var ioapics: [madt.MAX_IOAPICS]Entry = undefined;
var count: usize = 0;

fn regRead(base: u64, reg: u32) u32 {
    const sel: *volatile u32 = @ptrFromInt(base + REG_SELECT);
    const win: *volatile u32 = @ptrFromInt(base + REG_WINDOW);
    sel.* = reg;
    return win.*;
}

fn regWrite(base: u64, reg: u32, value: u32) void {
    const sel: *volatile u32 = @ptrFromInt(base + REG_SELECT);
    const win: *volatile u32 = @ptrFromInt(base + REG_WINDOW);
    sel.* = reg;
    win.* = value;
}

pub fn init() Error!void {
    const list = madt.ioApics();
    if (list.len == 0) return Error.NoIoApic;

    for (list) |info| {
        const virt = try vmm.mapMmio(info.address, 0x1000);
        // Version register bits 16-23 hold "max redirection entry".
        const max_entry = (regRead(virt, IOAPIC_VERSION) >> 16) & 0xFF;
        ioapics[count] = .{
            .base_virt = virt,
            .gsi_base = info.gsi_base,
            .gsi_count = max_entry + 1,
        };

        // Mask every line: nothing should fire until a driver asks for it.
        var i: u32 = 0;
        while (i <= max_entry) : (i += 1) {
            regWrite(virt, IOAPIC_REDTBL + i * 2, @intCast(MASKED));
            regWrite(virt, IOAPIC_REDTBL + i * 2 + 1, 0);
        }

        count += 1;
    }
}

fn forGsi(gsi: u32) ?*Entry {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = &ioapics[i];
        if (gsi >= e.gsi_base and gsi < e.gsi_base + e.gsi_count) return e;
    }
    return null;
}

/// Route a global system interrupt to `vector` on `apic_id`.
pub fn route(gsi: u32, vector: u8, apic_id: u8, flags: u64) void {
    const e = forGsi(gsi) orelse return;
    const index = gsi - e.gsi_base;

    const low: u32 = @intCast((flags & 0xFFFF) | vector);
    const high: u32 = @as(u32, apic_id) << 24;

    // Write the high half first: the entry stays masked until the low half
    // lands, so a partially-written entry can never fire.
    regWrite(e.base_virt, IOAPIC_REDTBL + index * 2 + 1, high);
    regWrite(e.base_virt, IOAPIC_REDTBL + index * 2, low);
}

/// Route a legacy ISA IRQ, honoring MADT overrides for polarity and trigger.
pub fn routeIrq(irq: u8, vector: u8, apic_id: u8) void {
    const gsi = madt.gsiForIrq(irq);
    const flags = madt.overrideFlags(irq);

    var entry_flags: u64 = 0;
    // Bits 0-1: polarity. 0b11 = active low.
    if (flags & 0b11 == 0b11) entry_flags |= ACTIVE_LOW;
    // Bits 2-3: trigger mode. 0b11 = level triggered.
    if ((flags >> 2) & 0b11 == 0b11) entry_flags |= LEVEL_TRIGGERED;

    route(gsi, vector, apic_id, entry_flags);
}

pub fn setMasked(gsi: u32, masked: bool) void {
    const e = forGsi(gsi) orelse return;
    const index = gsi - e.gsi_base;
    const reg = IOAPIC_REDTBL + index * 2;
    var low = regRead(e.base_virt, reg);
    if (masked) low |= @intCast(MASKED) else low &= ~@as(u32, @intCast(MASKED));
    regWrite(e.base_virt, reg, low);
}

pub fn ioApicCount() usize {
    return count;
}

pub fn totalGsis() u32 {
    var total: u32 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) total += ioapics[i].gsi_count;
    return total;
}
