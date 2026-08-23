//! Kernel timekeeping and the periodic tick.
//!
//! Two clocks with deliberately different jobs:
//!
//!   - The LAPIC tick drives PREEMPTION. It is best-effort: if the machine
//!     cannot service interrupts fast enough, ticks are simply missed. Under
//!     QEMU's TCG emulation on a non-x86 host, 1000 Hz loses a large fraction
//!     of them.
//!
//!   - The TSC drives TIMEKEEPING. It is a free-running counter that cannot be
//!     "missed", so wall-clock answers stay correct even when ticks are lost.
//!
//! Deriving uptime from the tick counter would make every timeout in the system
//! wrong on a machine that drops ticks, and wrong in a way that looks like a
//! calibration bug rather than a scheduling one.

const build_options = @import("build_options");
const apic = @import("../arch/x86_64/apic.zig");
const isr = @import("../arch/x86_64/isr.zig");
const tsc = @import("tsc.zig");
const pic = @import("../arch/x86_64/pic.zig");

pub const TICK_HZ: u32 = build_options.tick_hz;
const NS_PER_TICK: u64 = 1_000_000_000 / TICK_HZ;

var ticks: u64 = 0;
var boot_tsc: u64 = 0;

/// Called from the LAPIC timer interrupt, 1000 times a second.
fn tickHandler(frame: *isr.TrapFrame) void {
    _ = frame;
    ticks +%= 1;
    apic.eoi();
}

/// The spurious vector fires when an interrupt is withdrawn mid-delivery.
/// It must be handled and must NOT signal EOI.
fn spuriousHandler(frame: *isr.TrapFrame) void {
    _ = frame;
}

fn errorHandler(frame: *isr.TrapFrame) void {
    _ = frame;
    apic.eoi();
}

pub fn init() void {
    boot_tsc = tsc.read();

    isr.register(apic.VECTOR_TIMER, tickHandler);
    isr.register(apic.VECTOR_SPURIOUS, spuriousHandler);
    isr.register(apic.VECTOR_ERROR, errorHandler);

    apic.startTimer(TICK_HZ);
}

pub fn tickCount() u64 {
    return ticks;
}

/// Milliseconds since boot, from the TSC — not from the tick counter, which
/// under-reports on any machine that drops ticks.
pub fn millisSinceBoot() u64 {
    return monotonicNs() / 1_000_000;
}

/// Nanoseconds since boot. Uses the TSC when it is calibrated, since it has
/// far better resolution than the 1 ms tick.
pub fn monotonicNs() u64 {
    const per_us = tsc.ticksPerUs();
    if (per_us == 0) return ticks * NS_PER_TICK;
    return ((tsc.read() - boot_tsc) * 1000) / per_us;
}

/// Sleep by halting until the TSC says enough time has passed. Waiting on the
/// tick counter instead would sleep too long wherever ticks are dropped.
/// Replaced by a real blocking sleep once the scheduler exists in Phase 4.
pub fn busySleepMs(ms: u64) void {
    const target_ns = monotonicNs() + ms * 1_000_000;
    while (monotonicNs() < target_ns) {
        asm volatile ("hlt");
    }
}

/// Ticks actually observed per second, measured against the TSC. On real
/// hardware this matches TICK_HZ; under emulation it reveals dropped ticks.
pub fn measuredTickHz() u64 {
    const t0 = tickCount();
    const ns0 = monotonicNs();
    busySleepMs(500);
    const dt = tickCount() - t0;
    const dns = monotonicNs() - ns0;
    if (dns == 0) return 0;
    return (dt * 1_000_000_000) / dns;
}
