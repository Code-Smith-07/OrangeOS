//! The log port on Arm64 (a PL011), under the interface the console and
//! the terminal system calls use for the PC's COM1. Received bytes arrive
//! by interrupt into a small ring, as on the PC.

const uart = @import("uart.zig");
const gic = @import("gic.zig");
const isr = @import("isr.zig");
const cpu = @import("cpu.zig");
const bootinfo = @import("bootinfo.zig");
const spinlock = @import("../../sync/spinlock.zig");
const sched = @import("../../sched/sched.zig");

var initialized = false;

const RX_CAPACITY = 256;
var rx_buf: [RX_CAPACITY]u8 = undefined;
var rx_head: usize = 0;
var rx_tail: usize = 0;
var rx_lock: spinlock.SpinLock = .{};

pub fn init() bool {
    uart.init(null);
    initialized = true;
    return true;
}

pub fn writeByte(c: u8) void {
    uart.write(&[_]u8{c});
}

pub fn write(s: []const u8) void {
    uart.write(s);
}

pub fn isInitialized() bool {
    return initialized;
}

/// What a thread sleeps on while it waits for input.
pub fn waitChannel() usize {
    return @intFromPtr(&rx_buf);
}

fn drain() void {
    var got = false;
    {
        const state = spinlock.acquireIrqSave(&rx_lock);
        defer spinlock.releaseIrqRestore(&rx_lock, state);
        while (uart.readByte()) |c| {
            const next = (rx_head + 1) % RX_CAPACITY;
            if (next == rx_tail) continue; // full: drop
            rx_buf[rx_head] = c;
            rx_head = next;
            got = true;
        }
    }
    if (got) sched.wakeChannel(waitChannel());
}

fn rxHandler(_: *isr.TrapFrame) void {
    uart.clearInterrupts();
    drain();
}

pub fn readByte() ?u8 {
    const state = spinlock.acquireIrqSave(&rx_lock);
    defer spinlock.releaseIrqRestore(&rx_lock, state);
    if (rx_head == rx_tail) return null;
    const c = rx_buf[rx_tail];
    rx_tail = (rx_tail + 1) % RX_CAPACITY;
    return c;
}

pub fn hasInput() bool {
    const state = spinlock.acquireIrqSave(&rx_lock);
    defer spinlock.releaseIrqRestore(&rx_lock, state);
    return rx_head != rx_tail;
}

/// After the interrupt controller is up.
pub fn enableInput() void {
    const number = bootinfo.uart_interrupt orelse return;
    if (number >= 256) return;
    isr.register(@intCast(number), rxHandler);
    gic.enableShared(number, cpu.affinity());
    uart.enableReceiveInterrupt();
    drain(); // anything typed before now
}
