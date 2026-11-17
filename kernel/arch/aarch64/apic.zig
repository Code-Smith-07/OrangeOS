//! The tick timer and interrupt acknowledgement on Arm64, under the names
//! the shared timekeeping code uses for the x86 local APIC.
//!
//! Every processor has its own generic timer; it interrupts that processor
//! at the tick rate. The numbers below are interrupt numbers on the GIC
//! (isr.zig dispatches by them), not x86 vectors.

const cpu = @import("cpu.zig");
const gic = @import("gic.zig");

/// The virtual timer is private interrupt 27 on every Arm machine.
pub const VECTOR_TIMER: u8 = 27;
/// These two x86 events have no Arm counterpart; the numbers are unused.
pub const VECTOR_SPURIOUS: u8 = 255;
pub const VECTOR_ERROR: u8 = 254;

var interval: u64 = 0;

/// On every processor: start ticking `hz` times a second.
pub fn startTimer(hz: u32) void {
    interval = cpu.counterHz() / hz;
    cpu.write("cntv_cval_el0", cpu.counter() + interval);
    cpu.write("cntv_ctl_el0", 1); // on, not masked
    gic.enablePrivate(@intCast(VECTOR_TIMER));
}

pub fn stopTimer() void {
    cpu.write("cntv_ctl_el0", 0);
}

/// Called by the interrupt dispatcher when the timer fires: set the next
/// deadline. It is the first one still in the future on the original grid,
/// so ticks do not drift; an emulated machine that delivers one late does
/// not then receive a burst.
pub fn rearm() void {
    const deadline = cpu.read("cntv_cval_el0");
    const now = cpu.counter();
    const passed = 1 + (now -| deadline) / interval;
    cpu.write("cntv_cval_el0", deadline + passed * interval);
}

/// The dispatcher has already told the controller the interrupt is being
/// handled (it must, before a handler that may switch threads).
pub fn eoi() void {}
