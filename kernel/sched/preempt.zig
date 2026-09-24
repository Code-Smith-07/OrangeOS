//! Short CPU-pinned sections which still accept timer/device/IPI interrupts.
//! Never sleep, yield, exit or take a lock held by a suspended task inside one.
const std = @import("std");
const percpu = @import("../arch/x86_64/percpu.zig");
const io = @import("../arch/x86_64/io.zig");
const spinlock = @import("../sync/spinlock.zig");

pub const Guard = struct {
    cpu: usize,
    depth: u32,

    pub fn release(self: Guard) void {
        const was = spinlock.interruptsEnabled();
        io.cli();
        const local = percpu.this();
        std.debug.assert(local.cpu_index == self.cpu and local.preempt_depth == self.depth);
        local.preempt_depth -= 1;
        // Honor a deferred timer reschedule only after the outermost guard.
        if (was and local.preempt_depth == 0) @import("sched.zig").preemptIfNeeded();
        if (was) io.sti();
    }
};

pub fn acquire() Guard {
    const was = spinlock.interruptsEnabled();
    io.cli();
    const local = percpu.this();
    local.preempt_depth += 1;
    const result = Guard{ .cpu = percpu.cpuIndex(), .depth = local.preempt_depth };
    if (was) io.sti();
    return result;
}
