//! PL011 serial port: the kernel log on Arm machines.
//!
//! The address comes from the device tree; until that has been read the
//! QEMU "virt" address is used, so the very first lines are not lost.

const cpu = @import("cpu.zig");
const fmt = @import("../../lib/fmt.zig");
const std = @import("std");

const DR = 0x00; // data
const FR = 0x18; // flags
const IBRD = 0x24;
const FBRD = 0x28;
const LCRH = 0x2C;
const CR = 0x30; // control
const FR_TX_FULL: u32 = 1 << 5;
const FR_RX_EMPTY: u32 = 1 << 4;
const IMSC = 0x38; // interrupt mask
const ICR = 0x44; // interrupt clear
const RX_INTERRUPTS: u32 = (1 << 4) | (1 << 6); // data received, receive timeout

var base: u64 = cpu.HHDM + 0x0900_0000;
var lock = std.atomic.Value(bool).init(false);

fn reg(offset: u64) *volatile u32 {
    return @ptrFromInt(base + offset);
}

pub fn init(physical: ?u64) void {
    if (physical) |p| base = cpu.virt(p);
    reg(CR).* = 0;
    reg(LCRH).* = (3 << 5) | (1 << 4); // 8 bits, FIFO on
    reg(CR).* = (1 << 0) | (1 << 8) | (1 << 9); // on, send, receive
}

/// A received byte, if one is waiting.
pub fn readByte() ?u8 {
    if (reg(FR).* & FR_RX_EMPTY != 0) return null;
    return @truncate(reg(DR).*);
}

/// Interrupt when bytes arrive.
pub fn enableReceiveInterrupt() void {
    reg(ICR).* = 0x7FF;
    reg(IMSC).* = RX_INTERRUPTS;
}

/// Acknowledge the port's interrupt.
pub fn clearInterrupts() void {
    reg(ICR).* = RX_INTERRUPTS;
}

pub fn hasInput() bool {
    return reg(FR).* & FR_RX_EMPTY == 0;
}

/// Plain output, no lock: the console above has its own.
pub fn write(s: []const u8) void {
    raw(s);
}

fn put(c: u8) void {
    while (reg(FR).* & FR_TX_FULL != 0) {}
    reg(DR).* = c;
}

fn raw(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') put('\r');
        put(c);
    }
}

/// One whole line at a time, so lines from different processors never mix.
pub fn print(comptime format: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = fmt.bufPrint(&buf, format, args);
    const daif = cpu.read("daif");
    cpu.interruptsOff();
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) cpu.relax();
    raw(line);
    lock.store(false, .release);
    cpu.write("daif", daif);
}

/// For the crash handler: no lock (the holder may be the one that crashed).
pub fn emergency(comptime format: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    raw(fmt.bufPrint(&buf, format, args));
}
