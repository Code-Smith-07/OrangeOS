//! The calendar clock on Arm64 machines: a PL031, which simply counts
//! seconds since 1970.

const cpu = @import("cpu.zig");
const bootinfo = @import("bootinfo.zig");

pub fn epoch() ?u64 {
    const base = bootinfo.rtc orelse return null;
    const seconds = @as(*volatile u32, @ptrFromInt(cpu.virt(base))).*;
    return if (seconds == 0) null else seconds;
}
