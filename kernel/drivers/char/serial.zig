//! 16550 UART driver — COM1 at 0x3F8.
//!
//! This is the first thing initialized at boot and the last thing that still
//! works when everything else is broken. Every other subsystem's diagnostics
//! flow through here.

const io = @import("../../arch/x86_64/io.zig");

const COM1: u16 = 0x3F8;

// Register offsets from the port base.
const DATA = 0; // also divisor low when DLAB is set
const INT_ENABLE = 1; // also divisor high when DLAB is set
const FIFO_CTRL = 2;
const LINE_CTRL = 3;
const MODEM_CTRL = 4;
const LINE_STATUS = 5;

const LSR_TX_EMPTY: u8 = 0x20;

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
