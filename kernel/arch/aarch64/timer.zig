//! The Arm generic timer: every processor has its own, and it interrupts
//! that processor 1000 times a second (the same tick rate as the x86
//! kernel, so the scheduler above will not care which machine it is on).

const cpu = @import("cpu.zig");
const gic = @import("gic.zig");
const std = @import("std");

pub const HZ = 1000;
/// The virtual timer is private interrupt 27 on every Arm machine.
pub const INTERRUPT: u32 = 27;

var interval: u64 = 0;
var interrupts: [cpu.MAX_CPUS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** cpu.MAX_CPUS;
pub var ticks: [cpu.MAX_CPUS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** cpu.MAX_CPUS;

/// On every processor, after gic.initProcessor().
pub fn start() void {
    interval = cpu.counterHz() / HZ;
    cpu.write("cntv_cval_el0", cpu.counter() + interval);
    cpu.write("cntv_ctl_el0", 1); // on, not masked
    gic.enablePrivate(@intCast(INTERRUPT));
}

pub fn tick() void {
    const me = cpu.index();
    _ = interrupts[me].fetchAdd(1, .monotonic);
    // Ticks measure time, so they are counted from the deadlines that have
    // passed, not from the interrupts that arrived: an emulated machine (or
    // a host that paused the virtual machine) delivers some late, and the
    // clock must not run slow because of it. The next deadline is the first
    // one still in the future, on the original grid: no drift.
    const deadline = cpu.read("cntv_cval_el0");
    const now = cpu.counter();
    const passed = 1 + (now -| deadline) / interval;
    _ = ticks[me].fetchAdd(passed, .monotonic);
    cpu.write("cntv_cval_el0", deadline + passed * interval);
}

pub fn interruptsOn(processor: usize) u64 {
    return interrupts[processor].load(.monotonic);
}

pub fn ticksOn(processor: usize) u64 {
    return ticks[processor].load(.monotonic);
}
