//! Intel 82540EM (e1000) driver.
//!
//! The card is driven through two rings of descriptors in main memory. Each
//! descriptor points at a buffer and carries a status byte the card writes
//! when it is done. Software owns the tail pointer, hardware owns the head:
//! handing a descriptor over means advancing the tail, and getting one back
//! means seeing the status bit set.
//!
//! Everything the card touches must be physically contiguous and reachable by
//! DMA, so the rings and buffers come from the buddy allocator and are handed
//! over as physical addresses.

const std = @import("std");
const pci = @import("../../dev/pci/pci.zig");
const vmm = @import("../../mm/vmm.zig");
const pmm = @import("../../mm/pmm.zig");
const console = @import("../../console.zig");
const tsc = @import("../../time/tsc.zig");

const VENDOR_INTEL: u16 = 0x8086;
const DEVICE_82540EM: u16 = 0x100E;

// Registers, by byte offset from BAR0.
const REG_CTRL: usize = 0x0000;
const REG_STATUS: usize = 0x0008;
const REG_EERD: usize = 0x0014;
const REG_ICR: usize = 0x00C0;
const REG_IMS: usize = 0x00D0;
const REG_IMC: usize = 0x00D8;
const REG_RCTL: usize = 0x0100;
const REG_TCTL: usize = 0x0400;
const REG_RDBAL: usize = 0x2800;
const REG_RDBAH: usize = 0x2804;
const REG_RDLEN: usize = 0x2808;
const REG_RDH: usize = 0x2810;
const REG_RDT: usize = 0x2818;
const REG_TDBAL: usize = 0x3800;
const REG_TDBAH: usize = 0x3804;
const REG_TDLEN: usize = 0x3808;
const REG_TDH: usize = 0x3810;
const REG_TDT: usize = 0x3818;
const REG_MTA: usize = 0x5200;
const REG_RAL: usize = 0x5400;
const REG_RAH: usize = 0x5404;

const CTRL_RST: u32 = 1 << 26;
const CTRL_ASDE: u32 = 1 << 5;
const CTRL_SLU: u32 = 1 << 6;

const RCTL_EN: u32 = 1 << 1;
const RCTL_UPE: u32 = 1 << 3;
const RCTL_MPE: u32 = 1 << 4;
const RCTL_BAM: u32 = 1 << 15;
const RCTL_SECRC: u32 = 1 << 26;
const RCTL_BSIZE_2048: u32 = 0; // with BSEX clear

const TCTL_EN: u32 = 1 << 1;
const TCTL_PSP: u32 = 1 << 3;

const TXD_CMD_EOP: u8 = 1 << 0;
const TXD_CMD_IFCS: u8 = 1 << 1;
const TXD_CMD_RS: u8 = 1 << 3;
const TXD_STAT_DD: u8 = 1 << 0;

const RXD_STAT_DD: u8 = 1 << 0;
const RXD_STAT_EOP: u8 = 1 << 1;

pub const MTU: usize = 1500;
const BUFFER_SIZE: usize = 2048;
const RX_COUNT: usize = 32;
const TX_COUNT: usize = 32;

pub const Error = error{
    NoDevice,
    OutOfMemory,
    TxTimeout,
    TooLarge,
    InvalidOrder,
} || vmm.Error;

const RxDesc = extern struct {
    addr: u64 align(1),
    length: u16 align(1),
    checksum: u16 align(1),
    status: u8,
    errors: u8,
    special: u16 align(1),
};

const TxDesc = extern struct {
    addr: u64 align(1),
    length: u16 align(1),
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16 align(1),
};

var mmio: u64 = 0;
var mac: [6]u8 = undefined;
var present: bool = false;

var rx_ring: [*]volatile RxDesc = undefined;
var tx_ring: [*]volatile TxDesc = undefined;
var rx_buffers: [RX_COUNT]u64 = undefined; // virtual
var tx_buffers: [TX_COUNT]u64 = undefined;
var rx_next: usize = 0;
var tx_next: usize = 0;

var packets_sent: u64 = 0;
var packets_received: u64 = 0;

inline fn read(offset: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(mmio + offset);
    return p.*;
}

inline fn write(offset: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(mmio + offset);
    p.* = value;
}

/// QEMU populates the receive address registers from the command line, so the
/// MAC can be read directly rather than clocked out of the EEPROM.
fn readMac() void {
    const low = read(REG_RAL);
    const high = read(REG_RAH);

    mac[0] = @truncate(low);
    mac[1] = @truncate(low >> 8);
    mac[2] = @truncate(low >> 16);
    mac[3] = @truncate(low >> 24);
    mac[4] = @truncate(high);
    mac[5] = @truncate(high >> 8);
}

fn setupRx() !void {
    const ring_phys = try pmm.allocPageZeroed();
    rx_ring = @ptrFromInt(pmm.physToVirt(ring_phys));

    var i: usize = 0;
    while (i < RX_COUNT) : (i += 1) {
        const buf = try pmm.allocPageZeroed();
        rx_buffers[i] = pmm.physToVirt(buf);
        rx_ring[i].addr = buf;
        rx_ring[i].status = 0;
    }

    write(REG_RDBAL, @truncate(ring_phys));
    write(REG_RDBAH, @truncate(ring_phys >> 32));
    write(REG_RDLEN, RX_COUNT * @sizeOf(RxDesc));
    write(REG_RDH, 0);
    // Tail one behind head means "all descriptors are yours".
    write(REG_RDT, RX_COUNT - 1);

    write(REG_RCTL, RCTL_EN | RCTL_BAM | RCTL_SECRC | RCTL_BSIZE_2048 | RCTL_UPE | RCTL_MPE);
    rx_next = 0;
}

fn setupTx() !void {
    const ring_phys = try pmm.allocPageZeroed();
    tx_ring = @ptrFromInt(pmm.physToVirt(ring_phys));

    var i: usize = 0;
    while (i < TX_COUNT) : (i += 1) {
        const buf = try pmm.allocPageZeroed();
        tx_buffers[i] = pmm.physToVirt(buf);
        tx_ring[i].addr = buf;
        // DD set means "software may reuse this", which is true initially.
        tx_ring[i].status = TXD_STAT_DD;
        tx_ring[i].cmd = 0;
    }

    write(REG_TDBAL, @truncate(ring_phys));
    write(REG_TDBAH, @truncate(ring_phys >> 32));
    write(REG_TDLEN, TX_COUNT * @sizeOf(TxDesc));
    write(REG_TDH, 0);
    write(REG_TDT, 0);

    write(REG_TCTL, TCTL_EN | TCTL_PSP | (15 << 4) | (64 << 12));
    tx_next = 0;
}

pub fn init() Error!bool {
    const dev = pci.findByVendor(VENDOR_INTEL, DEVICE_82540EM) orelse return false;
    dev.enableBusMaster();

    const bar = dev.bar(0) orelse return Error.NoDevice;
    mmio = try vmm.mapMmio(bar, 0x20000);

    // Reset, then wait for the card to come back.
    write(REG_CTRL, read(REG_CTRL) | CTRL_RST);
    tsc.busyWaitUs(20_000);

    // Auto-negotiate speed and bring the link up.
    write(REG_CTRL, read(REG_CTRL) | CTRL_SLU | CTRL_ASDE);

    // Clear the multicast table filter; leaving it uninitialised makes the
    // card drop traffic it should accept.
    var i: usize = 0;
    while (i < 128) : (i += 1) write(REG_MTA + i * 4, 0);

    // Polling, not interrupts: there is nothing useful to do with a receive
    // interrupt until a socket layer can block a task on it.
    write(REG_IMC, 0xFFFF_FFFF);
    _ = read(REG_ICR);

    readMac();
    try setupRx();
    try setupTx();

    present = true;
    return true;
}

pub fn macAddress() [6]u8 {
    return mac;
}

pub fn isPresent() bool {
    return present;
}

pub fn linkUp() bool {
    return present and (read(REG_STATUS) & (1 << 1)) != 0;
}

/// Queue a frame for transmission and wait for the card to report it done.
pub fn send(frame: []const u8) Error!void {
    if (!present) return Error.NoDevice;
    if (frame.len > BUFFER_SIZE) return Error.TooLarge;

    const i = tx_next;
    // Wait for this slot to come back before overwriting it.
    const deadline = tsc.microsSinceBoot() + 1_000_000;
    while (tx_ring[i].status & TXD_STAT_DD == 0) {
        if (tsc.microsSinceBoot() > deadline) return Error.TxTimeout;
        asm volatile ("pause");
    }

    const dst: [*]u8 = @ptrFromInt(tx_buffers[i]);
    @memcpy(dst[0..frame.len], frame);

    tx_ring[i].length = @intCast(frame.len);
    tx_ring[i].cmd = TXD_CMD_EOP | TXD_CMD_IFCS | TXD_CMD_RS;
    tx_ring[i].status = 0;

    tx_next = (i + 1) % TX_COUNT;
    write(REG_TDT, @intCast(tx_next));

    packets_sent += 1;
}

/// Take one received frame, or null if the ring is empty.
/// The returned slice is only valid until the next call.
pub fn receive(out: []u8) ?usize {
    if (!present) return null;

    const i = rx_next;
    if (rx_ring[i].status & RXD_STAT_DD == 0) return null;

    const len = @min(@as(usize, rx_ring[i].length), out.len);
    const src: [*]const u8 = @ptrFromInt(rx_buffers[i]);
    @memcpy(out[0..len], src[0..len]);

    rx_ring[i].status = 0;
    rx_next = (i + 1) % RX_COUNT;

    // Handing the descriptor back means advancing the tail to the slot we
    // just finished with.
    write(REG_RDT, @intCast(i));

    packets_received += 1;
    return len;
}

pub fn stats() struct { sent: u64, received: u64 } {
    return .{ .sent = packets_sent, .received = packets_received };
}

pub fn report() void {
    if (!present) {
        console.info("no e1000 network card found", .{});
        return;
    }
    console.print("[ ok ] e1000: MAC {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}, link {s}\n", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
        if (linkUp()) "up" else "down",
    });
}
