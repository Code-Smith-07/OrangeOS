//! The user thread pointer on Arm64 (TPIDR_EL0). Programs can write it
//! themselves, so the scheduler reads it back when it switches away.

const cpu = @import("cpu.zig");

pub fn set(base: u64) void {
    cpu.write("tpidr_el0", base);
}
pub fn get() u64 {
    return cpu.read("tpidr_el0");
}
