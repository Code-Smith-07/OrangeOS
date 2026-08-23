//! 8253/8254 PIT — used only to calibrate faster timers.
//!
//! The PIT runs at a fixed, known frequency, which makes it the reference for
//! measuring the LAPIC timer and the TSC. Neither of those advertises its own
//! rate in a way we can trust, so we time them against this.
//!
//! Channel 2 is used because its gate is software-controlled and its output is
//! readable from port 0x61, so we can poll it without needing interrupts —
//! which do not exist yet when calibration runs.

const io = @import("../arch/x86_64/io.zig");

pub const FREQUENCY: u64 = 1_193_182; // Hz, fixed by the hardware

const CHANNEL2_DATA: u16 = 0x42;
const COMMAND: u16 = 0x43;
const CONTROL: u16 = 0x61; // channel 2 gate and output status

/// Arm channel 2 to count down for `micros` microseconds.
pub fn armChannel2(micros: u64) void {
    const divisor: u16 = @intCast((FREQUENCY * micros) / 1_000_000);

    // Enable the gate, keep the speaker off (bit 1).
    const ctrl = io.inb(CONTROL);
    io.outb(CONTROL, (ctrl & ~@as(u8, 0x02)) | 0x01);

    // Channel 2, lobyte+hibyte, mode 0 (interrupt on terminal count).
    io.outb(COMMAND, 0xB2);
    io.outb(CHANNEL2_DATA, @truncate(divisor));
    io.ioWait();
    io.outb(CHANNEL2_DATA, @truncate(divisor >> 8));

    // Toggle the gate low then high to start the count.
    const t = io.inb(CONTROL) & ~@as(u8, 0x01);
    io.outb(CONTROL, t);
    io.outb(CONTROL, t | 0x01);
}

/// True once channel 2 has counted down.
pub inline fn channel2Expired() bool {
    return io.inb(CONTROL) & 0x20 != 0;
}

/// Block until channel 2 finishes.
pub fn waitChannel2() void {
    while (!channel2Expired()) {}
}

/// Turn the gate back off.
pub fn stopChannel2() void {
    io.outb(CONTROL, io.inb(CONTROL) & ~@as(u8, 0x01));
}
