//! 16550 UART driver — COM1 at 0x3F8.
//!
//! This is the first thing initialized at boot and the last thing that still
//! works when everything else is broken. Every other subsystem's diagnostics
//! flow through here.

const io = @import("../../arch/x86_64/io.zig");
const sched = @import("../../sched/sched.zig");
const spinlock = @import("../../sync/spinlock.zig");
const isr = @import("../../arch/x86_64/isr.zig");
const apic = @import("../../arch/x86_64/apic.zig");
const ioapic = @import("../../arch/x86_64/ioapic.zig");

const COM1: u16 = 0x3F8;

// Register offsets from the port base.
const DATA = 0; // also divisor low when DLAB is set
const INT_ENABLE = 1; // also divisor high when DLAB is set
const FIFO_CTRL = 2;
const LINE_CTRL = 3;
const MODEM_CTRL = 4;
const LINE_STATUS = 5;

const LSR_TX_EMPTY: u8 = 0x20;
const LSR_DATA_READY: u8 = 0x01;

const IER_RX_AVAILABLE: u8 = 0x01;

/// COM1 sits on ISA IRQ 4. The MADT may have remapped it, which is why the
/// routing goes through madt.gsiForIrq rather than assuming GSI 4.
const COM1_IRQ: u8 = 4;
pub const VECTOR_SERIAL: u8 = 0x24;

/// Input ring. Sized generously: a paste into the terminal arrives far faster
/// than a reader drains it, and dropping characters looks like flaky hardware.
const RX_CAPACITY = 1024;

var rx_buf: [RX_CAPACITY]u8 = undefined;
var rx_head: usize = 0;
var rx_tail: usize = 0;

var initialized: bool = false;

/// Configure COM1 for 115200 baud, 8 data bits, no parity, 1 stop bit.
/// Returns false if the loopback self-test fails (no UART present).
pub fn init() bool {
    io.outb(COM1 + INT_ENABLE, 0x00); // interrupts off; we poll in Phase 0
    io.outb(COM1 + LINE_CTRL, 0x80); // DLAB on, to set the baud divisor
    io.outb(COM1 + DATA, 0x01); // divisor 1 → 115200 baud
    io.outb(COM1 + INT_ENABLE, 0x00);
    io.outb(COM1 + LINE_CTRL, 0x03); // DLAB off, 8N1
    io.outb(COM1 + FIFO_CTRL, 0xC7); // FIFO on, clear both, 14-byte threshold
    io.outb(COM1 + MODEM_CTRL, 0x0B); // RTS/DSR set, IRQs enabled in MCR

    // Loopback self-test: send a byte and check it comes back.
    io.outb(COM1 + MODEM_CTRL, 0x1E); // loopback mode
    io.outb(COM1 + DATA, 0xAE);
    if (io.inb(COM1 + DATA) != 0xAE) return false;

    io.outb(COM1 + MODEM_CTRL, 0x0F); // back to normal operation
    initialized = true;
    return true;
}

inline fn txReady() bool {
    return (io.inb(COM1 + LINE_STATUS) & LSR_TX_EMPTY) != 0;
}

pub fn writeByte(c: u8) void {
    // Translate LF to CRLF so terminals render boot output correctly.
    if (c == '\n') {
        while (!txReady()) {}
        io.outb(COM1 + DATA, '\r');
    }
    while (!txReady()) {}
    io.outb(COM1 + DATA, c);
}

pub fn write(s: []const u8) void {
    for (s) |c| writeByte(c);
}

pub fn isInitialized() bool {
    return initialized;
}

// ── Input ────────────────────────────────────────────────────────────────────

inline fn rxEmpty() bool {
    return rx_head == rx_tail;
}

var rx_lock: spinlock.SpinLock = .{};

/// Stable address identifying "console input" for the scheduler's wait
/// queues. Any thread blocked reading fd 0 waits on this.
pub fn waitChannel() usize {
    return @intFromPtr(&rx_buf);
}

fn rxPush(c: u8) void {
    {
        const state = spinlock.acquireIrqSave(&rx_lock);
        defer spinlock.releaseIrqRestore(&rx_lock, state);

        const next = (rx_head + 1) % RX_CAPACITY;
        // Full: drop the newest rather than overwrite unread input. Losing the
        // most recent keystroke is less confusing than losing the oldest.
        if (next == rx_tail) return;
        rx_buf[rx_head] = c;
        rx_head = next;
    }

    // A reader blocked on the console has a byte now. Called from the RX
    // interrupt, so this must not be a path that can sleep - wakeChannel only
    // moves tasks onto run queues.
    sched.wakeChannel(waitChannel());
}

/// Take one byte, or null if nothing is buffered.
pub fn readByte() ?u8 {
    const state = spinlock.acquireIrqSave(&rx_lock);
    defer spinlock.releaseIrqRestore(&rx_lock, state);

    if (rxEmpty()) return null;
    const c = rx_buf[rx_tail];
    rx_tail = (rx_tail + 1) % RX_CAPACITY;
    return c;
}

pub fn hasInput() bool {
    const state = spinlock.acquireIrqSave(&rx_lock);
    defer spinlock.releaseIrqRestore(&rx_lock, state);
    return !rxEmpty();
}

fn rxHandler(frame: *isr.TrapFrame) void {
    _ = frame;
    // Drain the FIFO: the UART raises one interrupt for a burst, so stopping
    // after a single byte would leave the rest sitting there until the next
    // keystroke.
    while (io.inb(COM1 + LINE_STATUS) & LSR_DATA_READY != 0) {
        rxPush(io.inb(COM1 + DATA));
    }
    apic.eoi();
}

/// Turn on receive interrupts and route COM1's IRQ to this CPU.
/// Called after the APICs are up.
pub fn enableInput() void {
    isr.register(VECTOR_SERIAL, rxHandler);
    io.outb(COM1 + INT_ENABLE, IER_RX_AVAILABLE);
    ioapic.routeIrq(COM1_IRQ, VECTOR_SERIAL, 0);
    ioapic.setMasked(madtGsi(), false);
}

fn madtGsi() u32 {
    const madt = @import("../../dev/acpi/madt.zig");
    return madt.gsiForIrq(COM1_IRQ);
}
