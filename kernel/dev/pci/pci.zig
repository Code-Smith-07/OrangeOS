//! PCI / PCIe enumeration.
//!
//! Two ways to reach a device's configuration space:
//!   - ECAM, mapped into memory, reaching all 4 KiB (PCIe)
//!   - the legacy 0xCF8/0xCFC port pair, reaching the first 256 bytes
//!
//! ECAM is used when MCFG describes it, with the port pair as fallback, so
//! the same driver code works on machines that predate PCIe.

const std = @import("std");
const io = @import("../../arch/x86_64/io.zig");
const mcfg = @import("../acpi/mcfg.zig");
const vmm = @import("../../mm/vmm.zig");
const console = @import("../../console.zig");

const CONFIG_ADDRESS: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

// Config space register offsets.
pub const REG_VENDOR_ID: u12 = 0x00;
pub const REG_DEVICE_ID: u12 = 0x02;
pub const REG_COMMAND: u12 = 0x04;
pub const REG_STATUS: u12 = 0x06;
pub const REG_REVISION: u12 = 0x08;
pub const REG_PROG_IF: u12 = 0x09;
pub const REG_SUBCLASS: u12 = 0x0A;
pub const REG_CLASS: u12 = 0x0B;
pub const REG_HEADER_TYPE: u12 = 0x0E;
pub const REG_BAR0: u12 = 0x10;
pub const REG_CAP_PTR: u12 = 0x34;
pub const REG_INTERRUPT_LINE: u12 = 0x3C;

// Command register bits.
pub const CMD_IO_SPACE: u16 = 1 << 0;
pub const CMD_MEMORY_SPACE: u16 = 1 << 1;
pub const CMD_BUS_MASTER: u16 = 1 << 2;
pub const CMD_INTERRUPT_DISABLE: u16 = 1 << 10;

var ecam_available = false;

pub const Address = struct {
    bus: u8,
    device: u5,
    function: u3,
};

pub const Device = struct {
    addr: Address,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    header_type: u8,

    pub fn read8(self: Device, offset: u12) u8 {
        return configRead8(self.addr, offset);
    }
    pub fn read16(self: Device, offset: u12) u16 {
        return configRead16(self.addr, offset);
    }
    pub fn read32(self: Device, offset: u12) u32 {
        return configRead32(self.addr, offset);
    }
    pub fn write16(self: Device, offset: u12, value: u16) void {
        configWrite16(self.addr, offset, value);
    }
    pub fn write32(self: Device, offset: u12, value: u32) void {
        configWrite32(self.addr, offset, value);
    }

    /// Turn on memory-space decoding and bus mastering, and mask legacy INTx.
    /// A device cannot DMA until it is a bus master, and its BARs do not
    /// respond until decoding is enabled.
    pub fn enableBusMaster(self: Device) void {
        var cmd = self.read16(REG_COMMAND);
        cmd |= CMD_MEMORY_SPACE | CMD_BUS_MASTER;
        cmd |= CMD_INTERRUPT_DISABLE;
        self.write16(REG_COMMAND, cmd);
    }

    /// Decode a 64-bit memory BAR. Bit 0 selects I/O vs memory; bits 1-2 give
    /// the type, where 0b10 means the BAR is 64 bits and consumes the next
    /// slot as its upper half.
    pub fn bar(self: Device, index: u3) ?u64 {
        const offset: u12 = REG_BAR0 + @as(u12, index) * 4;
        const low = self.read32(offset);
        if (low == 0) return null;
        if (low & 1 != 0) return low & 0xFFFF_FFFC; // I/O space

        const kind = (low >> 1) & 0b11;
        const base_low: u64 = low & 0xFFFF_FFF0;
        if (kind == 0b10) {
            const high = self.read32(offset + 4);
            return base_low | (@as(u64, high) << 32);
        }
        return base_low;
    }
};

fn legacyAddress(addr: Address, offset: u12) u32 {
    return 0x8000_0000 |
        (@as(u32, addr.bus) << 16) |
        (@as(u32, addr.device) << 11) |
        (@as(u32, addr.function) << 8) |
        (@as(u32, offset) & 0xFC);
}

pub fn configRead32(addr: Address, offset: u12) u32 {
    if (ecam_available) {
        if (mcfg.configAddress(addr.bus, addr.device, addr.function, offset)) |phys| {
            const p: *volatile u32 = @ptrFromInt(ecamVirt(phys));
            return p.*;
        }
    }
    io.outl(CONFIG_ADDRESS, legacyAddress(addr, offset));
    return io.inl(CONFIG_DATA);
}

pub fn configWrite32(addr: Address, offset: u12, value: u32) void {
    if (ecam_available) {
        if (mcfg.configAddress(addr.bus, addr.device, addr.function, offset)) |phys| {
            const p: *volatile u32 = @ptrFromInt(ecamVirt(phys));
            p.* = value;
            return;
        }
    }
    io.outl(CONFIG_ADDRESS, legacyAddress(addr, offset));
    io.outl(CONFIG_DATA, value);
}

pub fn configRead16(addr: Address, offset: u12) u16 {
    const dword = configRead32(addr, offset & ~@as(u12, 3));
    const shift: u5 = @intCast((offset & 2) * 8);
    return @truncate(dword >> shift);
}

pub fn configWrite16(addr: Address, offset: u12, value: u16) void {
    const aligned = offset & ~@as(u12, 3);
    const shift: u5 = @intCast((offset & 2) * 8);
    var dword = configRead32(addr, aligned);
    dword &= ~(@as(u32, 0xFFFF) << shift);
    dword |= @as(u32, value) << shift;
    configWrite32(addr, aligned, dword);
}

pub fn configRead8(addr: Address, offset: u12) u8 {
    const dword = configRead32(addr, offset & ~@as(u12, 3));
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(dword >> shift);
}

var ecam_mapped_base: u64 = 0;
var ecam_phys_base: u64 = 0;

fn ecamVirt(phys: u64) u64 {
    return ecam_mapped_base + (phys - ecam_phys_base);
}

pub const MAX_DEVICES = 64;
var devices: [MAX_DEVICES]Device = undefined;
var device_count: usize = 0;

/// A vendor id of 0xFFFF is the spec's "no device here" answer. Zero is not
/// in the spec, but ECAM regions for buses the host bridge does not implement
/// read back as zero rather than all-ones, so both mean "absent".
fn deviceAbsent(vendor: u16) bool {
    return vendor == 0xFFFF or vendor == 0x0000;
}

fn probe(addr: Address) void {
    const vendor = configRead16(addr, REG_VENDOR_ID);
    if (deviceAbsent(vendor)) return;

    if (device_count >= MAX_DEVICES) return;

    const dev = Device{
        .addr = addr,
        .vendor_id = vendor,
        .device_id = configRead16(addr, REG_DEVICE_ID),
        .class_code = configRead8(addr, REG_CLASS),
        .subclass = configRead8(addr, REG_SUBCLASS),
        .prog_if = configRead8(addr, REG_PROG_IF),
        .header_type = configRead8(addr, REG_HEADER_TYPE),
    };
    devices[device_count] = dev;
    device_count += 1;
}

pub fn init() !void {
    // Map ECAM if the firmware described it.
    mcfg.init() catch {};
    const allocs = mcfg.list();
    if (allocs.len > 0) {
        const a = allocs[0];
        const buses: u64 = @as(u64, a.end_bus - a.start_bus) + 1;
        const size: usize = @intCast(buses * 256 * 4096);
        ecam_phys_base = a.base;
        ecam_mapped_base = try vmm.mapMmio(a.base, size);
        ecam_available = true;
    }

    device_count = 0;

    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var device: u8 = 0;
        while (device < 32) : (device += 1) {
            const base_addr = Address{
                .bus = @intCast(bus),
                .device = @intCast(device),
                .function = 0,
            };
            if (deviceAbsent(configRead16(base_addr, REG_VENDOR_ID))) continue;

            probe(base_addr);

            // Bit 7 of the header type marks a multi-function device.
            const header = configRead8(base_addr, REG_HEADER_TYPE);
            if (header & 0x80 == 0) continue;

            var function: u8 = 1;
            while (function < 8) : (function += 1) {
                probe(.{
                    .bus = @intCast(bus),
                    .device = @intCast(device),
                    .function = @intCast(function),
                });
            }
        }
    }
}

pub fn list() []const Device {
    return devices[0..device_count];
}

/// First device matching a class/subclass, optionally a prog-if too.
pub fn findByClass(class_code: u8, subclass: u8, prog_if: ?u8) ?Device {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        const d = devices[i];
        if (d.class_code != class_code or d.subclass != subclass) continue;
        if (prog_if) |p| {
            if (d.prog_if != p) continue;
        }
        return d;
    }
    return null;
}

pub fn findByVendor(vendor: u16, device_id: u16) ?Device {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        if (devices[i].vendor_id == vendor and devices[i].device_id == device_id) {
            return devices[i];
        }
    }
    return null;
}

fn className(class_code: u8, subclass: u8) []const u8 {
    return switch (class_code) {
        0x01 => switch (subclass) {
            0x01 => "IDE controller",
            0x06 => "SATA controller",
            0x08 => "NVMe controller",
            else => "storage controller",
        },
        0x02 => "network controller",
        0x03 => "display controller",
        0x04 => "multimedia",
        0x06 => switch (subclass) {
            0x00 => "host bridge",
            0x01 => "ISA bridge",
            0x04 => "PCI bridge",
            else => "bridge",
        },
        0x0C => switch (subclass) {
            0x03 => "USB controller",
            else => "serial bus",
        },
        else => "device",
    };
}

pub fn report() void {
    console.print("[ ok ] PCI: {d} devices ({s} config access)\n", .{
        device_count,
        if (ecam_available) "ECAM" else "legacy port",
    });
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        const d = devices[i];
        console.print("[info]   {d:0>2}:{d:0>2}.{d}  {x:0>4}:{x:0>4}  {s}\n", .{
            d.addr.bus, @as(u8, d.addr.device), @as(u8, d.addr.function),
            d.vendor_id, d.device_id, className(d.class_code, d.subclass),
        });
    }
}
