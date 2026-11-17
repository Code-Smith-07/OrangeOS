//! Randomness sources on Arm64. The random-number instruction (RNDR) is
//! optional and not used yet, so the generator is seeded from interrupt
//! timing, as on an x86 processor without RDRAND.

const cpu = @import("cpu.zig");

pub fn cycles() u64 {
    return cpu.counter();
}
pub fn available() bool {
    return false;
}
pub fn word() ?u64 {
    return null;
}
