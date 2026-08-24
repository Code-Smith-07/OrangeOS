//! AHCI (SATA) driver.
//!
//! AHCI is a DMA engine described by memory-mapped structures. For each port
//! we allocate:
//!   - a command list: 32 command headers
//!   - a received-FIS area, where the device posts completion status
//!   - one command table per slot, holding the SATA command and a
//!     scatter-gather list pointing at the data buffer
//!
//! Everything the device touches must be physically contiguous and reachable
//! by DMA, so buffers come from the buddy allocator and are handed to the
//! device as physical addresses.
//!
//! Phase 5 polls for completion rather than taking interrupts. Polling is
//! simpler to get right, and until there is a scheduler-driven I/O wait there
//! is nothing useful to do with the interrupt anyway.

const std = @import("std");
const pci = @import("../../dev/pci/pci.zig");
const vmm = @import("../../mm/vmm.zig");
const pmm = @import("../../mm/pmm.zig");
const block = @import("block.zig");
const console = @import("../../console.zig");
const tsc = @import("../../time/tsc.zig");

// Host control registers.
const HBA_CAP: usize = 0x00;
const HBA_GHC: usize = 0x04;
const HBA_IS: usize = 0x08;
const HBA_PI: usize = 0x0C;
const HBA_VS: usize = 0x10;

const GHC_AE: u32 = 1 << 31; // AHCI enable
const GHC_IE: u32 = 1 << 1; // interrupt enable
const GHC_HR: u32 = 1 << 0; // HBA reset

// Per-port registers, from the port's base.
const PORT_CLB: usize = 0x00;
const PORT_CLBU: usize = 0x04;
const PORT_FB: usize = 0x08;
const PORT_FBU: usize = 0x0C;
const PORT_IS: usize = 0x10;
const PORT_IE: usize = 0x14;
const PORT_CMD: usize = 0x18;
const PORT_TFD: usize = 0x20;
const PORT_SIG: usize = 0x24;
const PORT_SSTS: usize = 0x28;
const PORT_SERR: usize = 0x30;
const PORT_CI: usize = 0x38;

const CMD_ST: u32 = 1 << 0; // start
const CMD_FRE: u32 = 1 << 4; // FIS receive enable
const CMD_FR: u32 = 1 << 14; // FIS receive running
const CMD_CR: u32 = 1 << 15; // command list running

const TFD_BSY: u32 = 1 << 7;
const TFD_DRQ: u32 = 1 << 3;
const TFD_ERR: u32 = 1 << 0;

const SIG_ATA: u32 = 0x0000_0101;

const FIS_TYPE_REG_H2D: u8 = 0x27;

const ATA_CMD_READ_DMA_EX: u8 = 0x25;
const ATA_CMD_WRITE_DMA_EX: u8 = 0x35;
const ATA_CMD_IDENTIFY: u8 = 0xEC;

const PORT_COUNT = 32;
const CMD_SLOTS = 32;

/// Host-to-device register FIS — the SATA command packet.
const FisRegH2D = extern struct {
    fis_type: u8,
    pm_port_c: u8, // bit 7 set means "this is a command"
    command: u8,
    featurel: u8,
    lba0: u8,
    lba1: u8,
    lba2: u8,
    device: u8,
    lba3: u8,
    lba4: u8,
    lba5: u8,
    featureh: u8,
    countl: u8,
    counth: u8,
    icc: u8,
    control: u8,
    reserved: [4]u8,
};

const CommandHeader = extern struct {
    /// bits 0-4 FIS length in dwords, bit 6 write, bit 7 prefetchable
    flags: u16,
    prdt_length: u16,
    prd_byte_count: u32,
    ctba: u32,
    ctbau: u32,
    reserved: [4]u32,
};

const PrdtEntry = extern struct {
    dba: u32,
    dbau: u32,
    reserved: u32,
    /// bits 0-21 byte count minus one, bit 31 interrupt on completion
    dbc_flags: u32,
};

const CommandTable = extern struct {
    cfis: [64]u8,
    acmd: [16]u8,
    reserved: [48]u8,
    prdt: [8]PrdtEntry,
};

const Port = struct {
    hba_base: u64,
    index: u5,
    clb_phys: u64,
    fb_phys: u64,
    ctba_phys: u64,
    sectors: u64,
    /// Bounce buffer: DMA needs a physically contiguous target, and a caller's
    /// buffer may be neither contiguous nor DMA-reachable.
    bounce_phys: u64,
    bounce_virt: u64,
    bounce_sectors: u32,
};

var ports: [PORT_COUNT]Port = undefined;
var port_count: usize = 0;
var hba_virt: u64 = 0;

inline fn hbaRead(offset: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(hba_virt + offset);
    return p.*;
}

inline fn hbaWrite(offset: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(hba_virt + offset);
    p.* = value;
}

inline fn portBase(index: u5) u64 {
    return hba_virt + 0x100 + @as(u64, index) * 0x80;
}

inline fn portRead(index: u5, offset: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(portBase(index) + offset);
    return p.*;
}

inline fn portWrite(index: u5, offset: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(portBase(index) + offset);
    p.* = value;
}

fn waitNotBusy(index: u5, timeout_us: u64) block.Error!void {
    const deadline = tsc.microsSinceBoot() + timeout_us;
    while (tsc.microsSinceBoot() < deadline) {
        const tfd = portRead(index, PORT_TFD);
        if (tfd & (TFD_BSY | TFD_DRQ) == 0) return;
        asm volatile ("pause");
    }
    return block.Error.Timeout;
}

fn stopPort(index: u5) void {
    var cmd = portRead(index, PORT_CMD);
    cmd &= ~(CMD_ST | CMD_FRE);
    portWrite(index, PORT_CMD, cmd);

    // Wait for the engines to actually stop before touching their pointers.
    const deadline = tsc.microsSinceBoot() + 500_000;
    while (tsc.microsSinceBoot() < deadline) {
        const c = portRead(index, PORT_CMD);
        if (c & (CMD_FR | CMD_CR) == 0) break;
        asm volatile ("pause");
    }
}

fn startPort(index: u5) void {
    const deadline = tsc.microsSinceBoot() + 500_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (portRead(index, PORT_CMD) & CMD_CR == 0) break;
        asm volatile ("pause");
    }
    var cmd = portRead(index, PORT_CMD);
    cmd |= CMD_FRE | CMD_ST;
    portWrite(index, PORT_CMD, cmd);
}

/// Issue one command on slot 0 and poll until it completes.
fn runCommand(
    port: *Port,
    ata_cmd: u8,
    lba: u64,
    sectors: u16,
    data_phys: u64,
    write: bool,
) block.Error!void {
    portWrite(port.index, PORT_IS, 0xFFFF_FFFF);
    portWrite(port.index, PORT_SERR, portRead(port.index, PORT_SERR));

    try waitNotBusy(port.index, 1_000_000);

    const headers: [*]volatile CommandHeader = @ptrFromInt(pmm.physToVirt(port.clb_phys));
    const table: *volatile CommandTable = @ptrFromInt(pmm.physToVirt(port.ctba_phys));

    // Zero the table so no stale PRDT entry survives.
    const table_bytes: [*]volatile u8 = @ptrCast(table);
    var z: usize = 0;
    while (z < @sizeOf(CommandTable)) : (z += 1) table_bytes[z] = 0;

    const byte_count: u32 = @as(u32, sectors) * @as(u32, block.SECTOR_SIZE);
    table.prdt[0] = .{
        .dba = @truncate(data_phys),
        .dbau = @truncate(data_phys >> 32),
        .reserved = 0,
        // The field is "byte count minus one"; a zero here means one byte.
        .dbc_flags = byte_count - 1,
    };

    const fis: *volatile FisRegH2D = @ptrCast(@alignCast(&table.cfis));
    fis.* = .{
        .fis_type = FIS_TYPE_REG_H2D,
        .pm_port_c = 0x80, // command, not control
        .command = ata_cmd,
        .featurel = 0,
        .lba0 = @truncate(lba),
        .lba1 = @truncate(lba >> 8),
        .lba2 = @truncate(lba >> 16),
        .device = 0x40, // LBA mode
        .lba3 = @truncate(lba >> 24),
        .lba4 = @truncate(lba >> 32),
        .lba5 = @truncate(lba >> 40),
        .featureh = 0,
        .countl = @truncate(sectors),
        .counth = @truncate(sectors >> 8),
        .icc = 0,
        .control = 0,
        .reserved = .{ 0, 0, 0, 0 },
    };

    const fis_dwords: u16 = @sizeOf(FisRegH2D) / 4;
    headers[0].flags = fis_dwords | (if (write) @as(u16, 1) << 6 else 0);
    headers[0].prdt_length = 1;
    headers[0].prd_byte_count = 0;
    headers[0].ctba = @truncate(port.ctba_phys);
    headers[0].ctbau = @truncate(port.ctba_phys >> 32);

    // Issue on slot 0.
    portWrite(port.index, PORT_CI, 1);

    const deadline = tsc.microsSinceBoot() + 3_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (portRead(port.index, PORT_CI) & 1 == 0) break;
        if (portRead(port.index, PORT_IS) & (1 << 30) != 0) return block.Error.IoError;
        asm volatile ("pause");
    } else return block.Error.Timeout;

    if (portRead(port.index, PORT_TFD) & TFD_ERR != 0) return block.Error.IoError;
}

fn readSectors(ctx: *anyopaque, lba: u64, count: u32, buf: [*]u8) block.Error!void {
    const port: *Port = @ptrCast(@alignCast(ctx));

    var done: u32 = 0;
    while (done < count) {
        const chunk = @min(count - done, port.bounce_sectors);
        try runCommand(port, ATA_CMD_READ_DMA_EX, lba + done, @intCast(chunk), port.bounce_phys, false);

        const src: [*]const u8 = @ptrFromInt(port.bounce_virt);
        const bytes = chunk * block.SECTOR_SIZE;
        @memcpy(
            buf[done * block.SECTOR_SIZE ..][0..bytes],
            src[0..bytes],
        );
        done += chunk;
    }
}

fn writeSectors(ctx: *anyopaque, lba: u64, count: u32, buf: [*]const u8) block.Error!void {
    const port: *Port = @ptrCast(@alignCast(ctx));

    var done: u32 = 0;
    while (done < count) {
        const chunk = @min(count - done, port.bounce_sectors);
        const dst: [*]u8 = @ptrFromInt(port.bounce_virt);
        const bytes = chunk * block.SECTOR_SIZE;
        @memcpy(dst[0..bytes], buf[done * block.SECTOR_SIZE ..][0..bytes]);

        try runCommand(port, ATA_CMD_WRITE_DMA_EX, lba + done, @intCast(chunk), port.bounce_phys, true);
        done += chunk;
    }
}

/// IDENTIFY returns 512 bytes describing the device; word 100 onward holds the
/// 48-bit LBA sector count.
fn identify(port: *Port) block.Error!u64 {
    try runCommand(port, ATA_CMD_IDENTIFY, 0, 1, port.bounce_phys, false);

    const words: [*]const u16 = @ptrFromInt(port.bounce_virt);
    const lba48 = @as(u64, words[100]) |
        (@as(u64, words[101]) << 16) |
        (@as(u64, words[102]) << 32) |
        (@as(u64, words[103]) << 48);
    if (lba48 != 0) return lba48;

    // Fall back to the 28-bit count for older devices.
    return @as(u64, words[60]) | (@as(u64, words[61]) << 16);
}

fn setupPort(index: u5) !?*Port {
    const ssts = portRead(index, PORT_SSTS);
    const det = ssts & 0xF;
    const ipm = (ssts >> 8) & 0xF;
    // det 3 = device present and communication established; ipm 1 = active.
    if (det != 3 or ipm != 1) return null;
    if (portRead(index, PORT_SIG) != SIG_ATA) return null;

    stopPort(index);

    // Command list: 32 headers, 1 KiB, must be 1 KiB aligned.
    // FIS area: 256 bytes, must be 256-byte aligned.
    // One page each satisfies both alignments comfortably.
    const clb = try pmm.allocPageZeroed();
    const fb = try pmm.allocPageZeroed();
    const ctba = try pmm.allocPageZeroed();

    // 64 KiB bounce buffer = 128 sectors per transfer.
    const bounce_order = pmm.orderFor(16);
    const bounce = try pmm.allocOrder(bounce_order);

    portWrite(index, PORT_CLB, @truncate(clb));
    portWrite(index, PORT_CLBU, @truncate(clb >> 32));
    portWrite(index, PORT_FB, @truncate(fb));
    portWrite(index, PORT_FBU, @truncate(fb >> 32));
    portWrite(index, PORT_IE, 0); // polling, not interrupts

    startPort(index);

    ports[port_count] = .{
        .hba_base = hba_virt,
        .index = index,
        .clb_phys = clb,
        .fb_phys = fb,
        .ctba_phys = ctba,
        .sectors = 0,
        .bounce_phys = bounce,
        .bounce_virt = pmm.physToVirt(bounce),
        .bounce_sectors = 128,
    };
    const port = &ports[port_count];
    port_count += 1;

    port.sectors = identify(port) catch 0;
    return port;
}

pub fn init() !usize {
    const dev = pci.findByClass(0x01, 0x06, 0x01) orelse return 0;
    dev.enableBusMaster();

    const abar = dev.bar(5) orelse return 0;
    hba_virt = try vmm.mapMmio(abar, 0x2000);

    // Take ownership of the controller.
    hbaWrite(HBA_GHC, hbaRead(HBA_GHC) | GHC_AE);

    const pi = hbaRead(HBA_PI);
    const version = hbaRead(HBA_VS);
    console.print("[ ok ] AHCI {d}.{d} at 0x{x}, ports implemented 0x{x}\n", .{
        (version >> 16) & 0xFFFF, (version >> 8) & 0xFF, abar, pi,
    });

    var found: usize = 0;
    // Counter is u8, not u5: PORT_COUNT is 32 and a u5 tops out at 31, so the
    // final increment overflows before the loop condition is re-checked.
    var i: u8 = 0;
    while (i < PORT_COUNT) : (i += 1) {
        const index: u5 = @intCast(i);
        if (pi & (@as(u32, 1) << index) == 0) continue;
        const port = setupPort(index) catch continue orelse continue;
        if (port.sectors == 0) continue;

        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "sata{d}", .{found}) catch "sata";
        const n = block.makeName(name);

        _ = block.register(.{
            .name = n.buf,
            .name_len = n.len,
            .ctx = port,
            .ops = .{ .read = readSectors, .write = writeSectors },
            .sectors = port.sectors,
        });
        found += 1;
    }

    return found;
}
