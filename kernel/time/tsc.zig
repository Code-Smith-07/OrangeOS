//! Timestamp counter.
//!
//! The TSC increments at a constant rate on any CPU with the invariant-TSC
//! feature, which makes it the cheapest possible clock source: one rdtsc
//! instruction, no MMIO, no port I/O. We calibrate it against the PIT once at
//! boot and then never touch the PIT again.

const pit = @import("pit.zig");
const io = @import("../arch/x86_64/io.zig");

var ticks_per_us: u64 = 0;
var invariant: bool = false;

pub inline fn read() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

/// Serializing read — waits for prior instructions to retire. Slower, but the
/// right choice when measuring a specific interval.
pub inline fn readSerialized() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile (
        \\ lfence
        \\ rdtsc
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

/// CPUID leaf 0x80000007, EDX bit 8 reports invariant TSC.
fn detectInvariant() bool {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (@as(u32, 0x8000_0007)),
        : "ebx", "ecx"
    );
    return edx & (1 << 8) != 0;
}

/// Measure the TSC against a 10 ms PIT interval.
pub fn calibrate() void {
    invariant = detectInvariant();

    const CALIBRATION_US: u64 = 10_000;

    pit.armChannel2(CALIBRATION_US);
    const start = readSerialized();
    pit.waitChannel2();
    const end = readSerialized();
    pit.stopChannel2();

    const elapsed = end - start;
    ticks_per_us = elapsed / CALIBRATION_US;
}

pub fn ticksPerUs() u64 {
    return ticks_per_us;
}

pub fn frequencyHz() u64 {
    return ticks_per_us * 1_000_000;
}

pub fn isInvariant() bool {
    return invariant;
}

/// Microseconds since boot, derived from the TSC.
pub fn microsSinceBoot() u64 {
    if (ticks_per_us == 0) return 0;
    return read() / ticks_per_us;
}

/// Busy-wait. Only for early boot, before the scheduler exists.
pub fn busyWaitUs(micros: u64) void {
    if (ticks_per_us == 0) return;
    const target = read() + micros * ticks_per_us;
    while (read() < target) {
        asm volatile ("pause");
    }
}
