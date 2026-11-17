//! ATA disks on a legacy IDE controller, read and written by polling (PIO).
//!
//! This is the disk controller VirtualBox gives a new machine by default
//! (PIIX3/PIIX4 IDE), and what older PCs have. AHCI and NVMe are faster
//! and are tried first; this driver exists so OrangeOS still finds its
//! disk when neither is there.
//!
//! Two channels at the classic ports (0x1F0 and 0x170), a master and a
//! slave on each. Each drive is asked to IDENTIFY itself; packet devices
//! (the CD-ROM) are left alone. Transfers use 48-bit addresses when the
//! drive has them and 28-bit otherwise. Every wait has a deadline, so a
//! missing or stuck drive costs a moment at boot and nothing more.
const std = @import("std");
const io = @import("../../arch/arch.zig").io;
const pci = @import("../../dev/pci/pci.zig");
const block = @import("block.zig");
const console = @import("../../console.zig");
const tsc = @import("../../arch/arch.zig").tsc;

const Channel = struct { base: u16, control: u16 };
const CHANNELS = [_]Channel{
    .{ .base = 0x1F0, .control = 0x3F6 },
    .{ .base = 0x170, .control = 0x376 },
};

// Registers, as offsets from the channel's base port.
const REG_DATA = 0;
const REG_ERROR = 1;
const REG_COUNT = 2;
const REG_LBA0 = 3;
const REG_LBA1 = 4;
const REG_LBA2 = 5;
const REG_DRIVE = 6;
const REG_STATUS = 7;
const REG_COMMAND = 7;

const ST_ERR: u8 = 0x01;
const ST_DRQ: u8 = 0x08;
const ST_DF: u8 = 0x20;
const ST_BSY: u8 = 0x80;

const CMD_READ: u8 = 0x20;
const CMD_READ_EXT: u8 = 0x24;
const CMD_WRITE: u8 = 0x30;
const CMD_WRITE_EXT: u8 = 0x34;
const CMD_FLUSH: u8 = 0xE7;
const CMD_FLUSH_EXT: u8 = 0xEA;
const CMD_IDENTIFY: u8 = 0xEC;

const Drive = struct {
    channel: Channel,
    slave: bool,
    lba48: bool,
    sectors: u64,
};

var drives: [4]Drive = undefined;
var drive_count: usize = 0;

/// Reading the alternate status four times takes the 400 ns a drive is
/// allowed before its status is valid.
fn settle(ch: Channel) void {
    for (0..4) |_| _ = io.inb(ch.control);
}

/// Wait until the drive is not busy; with `need_data`, until it also has
/// data ready (or wants data). Error and fault bits end the wait at once.
fn wait(ch: Channel, need_data: bool, micros: u64) block.Error!void {
    const deadline = tsc.microsSinceBoot() + micros;
    while (true) {
        const status = io.inb(ch.base + REG_STATUS);
        if (status & ST_BSY == 0) {
            if (status & (ST_ERR | ST_DF) != 0) return block.Error.IoError;
            if (!need_data or status & ST_DRQ != 0) return;
        }
        if (tsc.microsSinceBoot() > deadline) return block.Error.Timeout;
        @import("../../arch/arch.zig").io.pause();
    }
}

fn select(d: *const Drive, lba_top: u8) void {
    io.outb(d.channel.base + REG_DRIVE, 0xE0 | (@as(u8, @intFromBool(d.slave)) << 4) | (lba_top & 0x0F));
    settle(d.channel);
}

/// Ask the drive on (channel, slave) what it is. Null when there is no
/// drive there, or it is a packet device.
fn identify(ch: Channel, slave: bool) ?Drive {
    io.outb(ch.base + REG_DRIVE, 0xA0 | (@as(u8, @intFromBool(slave)) << 4));
    settle(ch);
    io.outb(ch.base + REG_COUNT, 0);
    io.outb(ch.base + REG_LBA0, 0);
    io.outb(ch.base + REG_LBA1, 0);
    io.outb(ch.base + REG_LBA2, 0);
    io.outb(ch.base + REG_COMMAND, CMD_IDENTIFY);
    settle(ch);
    // No drive: the status reads 0, or 0xFF on a channel with nothing on it.
    const first = io.inb(ch.base + REG_STATUS);
    if (first == 0 or first == 0xFF) return null;
    wait(ch, false, 500_000) catch return null;
    // A packet device (ATAPI) signs itself in the address registers.
    if (io.inb(ch.base + REG_LBA1) != 0 or io.inb(ch.base + REG_LBA2) != 0) return null;
    wait(ch, true, 500_000) catch return null;
    var words: [256]u16 = undefined;
    for (&words) |*w| w.* = io.inw(ch.base + REG_DATA);
    const lba48 = words[83] & (1 << 10) != 0;
    const sectors: u64 = if (lba48)
        @as(u64, words[100]) | (@as(u64, words[101]) << 16) | (@as(u64, words[102]) << 32) | (@as(u64, words[103]) << 48)
    else
        @as(u64, words[60]) | (@as(u64, words[61]) << 16);
    if (sectors == 0) return null;
    return .{ .channel = ch, .slave = slave, .lba48 = lba48, .sectors = sectors };
}

/// Program the address and count for one command of up to `count` sectors.
fn start(d: *const Drive, lba: u64, count: u32, command28: u8, command48: u8) void {
    const base = d.channel.base;
    if (d.lba48) {
        select(d, 0);
        // The high halves are written first, then the low ones.
        io.outb(base + REG_COUNT, @truncate(count >> 8));
        io.outb(base + REG_LBA0, @truncate(lba >> 24));
        io.outb(base + REG_LBA1, @truncate(lba >> 32));
        io.outb(base + REG_LBA2, @truncate(lba >> 40));
        io.outb(base + REG_COUNT, @truncate(count));
        io.outb(base + REG_LBA0, @truncate(lba));
        io.outb(base + REG_LBA1, @truncate(lba >> 8));
        io.outb(base + REG_LBA2, @truncate(lba >> 16));
        io.outb(base + REG_COMMAND, command48);
    } else {
        select(d, @truncate(lba >> 24));
        io.outb(base + REG_COUNT, @truncate(count));
        io.outb(base + REG_LBA0, @truncate(lba));
        io.outb(base + REG_LBA1, @truncate(lba >> 8));
        io.outb(base + REG_LBA2, @truncate(lba >> 16));
        io.outb(base + REG_COMMAND, command28);
    }
}

/// The most sectors one command may carry (a count of 0 means the maximum,
/// which this driver never relies on).
fn chunk(d: *const Drive, remaining: u32) u32 {
    return @min(remaining, if (d.lba48) @as(u32, 4096) else 255);
}

fn readSectors(ctx: *anyopaque, lba: u64, count: u32, buf: [*]u8) block.Error!void {
    const d: *const Drive = @ptrCast(@alignCast(ctx));
    if (!d.lba48 and lba + count > 0x0FFF_FFFF) return block.Error.OutOfRange;
    var done: u32 = 0;
    while (done < count) {
        const n = chunk(d, count - done);
        try wait(d.channel, false, 2_000_000);
        start(d, lba + done, n, CMD_READ, CMD_READ_EXT);
        for (0..n) |s| {
            try wait(d.channel, true, 5_000_000);
            const out = buf + (@as(usize, done) + s) * block.SECTOR_SIZE;
            var i: usize = 0;
            while (i < block.SECTOR_SIZE) : (i += 2) {
                const word = io.inw(d.channel.base + REG_DATA);
                out[i] = @truncate(word);
                out[i + 1] = @truncate(word >> 8);
            }
        }
        done += n;
    }
}

fn writeSectors(ctx: *anyopaque, lba: u64, count: u32, buf: [*]const u8) block.Error!void {
    const d: *const Drive = @ptrCast(@alignCast(ctx));
    if (!d.lba48 and lba + count > 0x0FFF_FFFF) return block.Error.OutOfRange;
    var done: u32 = 0;
    while (done < count) {
        const n = chunk(d, count - done);
        try wait(d.channel, false, 2_000_000);
        start(d, lba + done, n, CMD_WRITE, CMD_WRITE_EXT);
        for (0..n) |s| {
            try wait(d.channel, true, 5_000_000);
            const in = buf + (@as(usize, done) + s) * block.SECTOR_SIZE;
            var i: usize = 0;
            while (i < block.SECTOR_SIZE) : (i += 2) {
                io.outw(d.channel.base + REG_DATA, @as(u16, in[i]) | (@as(u16, in[i + 1]) << 8));
            }
        }
        // The drive is busy until the last sector is taken.
        try wait(d.channel, false, 5_000_000);
        done += n;
    }
}

fn flushCache(ctx: *anyopaque) block.Error!void {
    const d: *const Drive = @ptrCast(@alignCast(ctx));
    try wait(d.channel, false, 2_000_000);
    select(d, 0);
    io.outb(d.channel.base + REG_COMMAND, if (d.lba48) CMD_FLUSH_EXT else CMD_FLUSH);
    // A flush may take a while on a real disk.
    try wait(d.channel, false, 30_000_000);
}

/// Find ATA disks on a PCI IDE controller. Returns how many were registered.
pub fn init() usize {
    // Only where an IDE controller exists: probing the ports of a machine
    // without one would poke at whatever else lives there.
    const controller = pci.findByClass(0x01, 0x01, null) orelse return 0;
    // Native mode (bits 0 and 2 of the programming interface) moves the
    // ports to the controller's BARs, which this driver does not follow.
    if (controller.prog_if & 0x05 != 0) {
        console.warn("IDE controller in native mode is not supported yet", .{});
        return 0;
    }
    var found: usize = 0;
    for (CHANNELS) |ch| {
        // Polling only: tell the channel not to raise interrupts.
        io.outb(ch.control, 0x02);
        for ([_]bool{ false, true }) |slave| {
            if (drive_count == drives.len) break;
            const drive = identify(ch, slave) orelse continue;
            drives[drive_count] = drive;
            var name_buf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "ata{d}", .{found}) catch "ata";
            const n = block.makeName(name);
            _ = block.register(.{
                .name = n.buf,
                .name_len = n.len,
                .ctx = &drives[drive_count],
                .ops = .{ .read = readSectors, .write = writeSectors, .flush = flushCache },
                .sectors = drive.sectors,
            });
            console.print("[ ok ] ATA disk on the {s} channel ({s}), {s} addressing\n", .{
                if (ch.base == 0x1F0) "primary" else "secondary",
                if (slave) "slave" else "master",
                if (drive.lba48) "48-bit" else "28-bit",
            });
            drive_count += 1;
            found += 1;
        }
    }
    return found;
}
