//! The fine-grained clock on Arm64: the generic counter. Its frequency is
//! told by the processor, so nothing is calibrated.

const cpu = @import("cpu.zig");

var boot_count: u64 = 0;

pub fn calibrate() void {
    boot_count = cpu.counter();
}
pub inline fn read() u64 {
    return cpu.counter();
}
pub fn frequencyHz() u64 {
    return cpu.counterHz();
}
/// Whole counts in a microsecond, 0 if the counter is slower than 1 MHz.
pub fn ticksPerUs() u64 {
    return cpu.counterHz() / 1_000_000;
}
pub fn isInvariant() bool {
    return true;
}
pub fn microsSinceBoot() u64 {
    const hz = cpu.counterHz();
    const elapsed = cpu.counter() - boot_count;
    return (elapsed / hz) * 1_000_000 + (elapsed % hz) * 1_000_000 / hz;
}
pub fn busyWaitUs(micros: u64) void {
    const until = microsSinceBoot() + micros;
    while (microsSinceBoot() < until) cpu.relax();
}

/// x86 needs a serializing read for precise intervals; reading the Arm
/// counter after an instruction barrier (cpu.counter) already is one.
pub inline fn readSerialized() u64 {
    return cpu.counter();
}
