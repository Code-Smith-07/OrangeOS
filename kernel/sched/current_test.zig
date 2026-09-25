//! Current-thread identity across migration. Run with -Druntime-test.
//!
//! Workers repeatedly note "this CPU's block", sleep so they resume on
//! whichever CPU picks them up next, then read both that block's current
//! task and `sched.currentTask()`. The block read goes stale whenever the
//! worker comes back elsewhere. That is the hazard which let a new thread,
//! preempted between finding its CPU and reading `current`, run another
//! thread's entry with that thread's already-consumed argument. The
//! accessor, a single GS-relative load, must always name the worker itself.

const std = @import("std");
const sched = @import("sched.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const io = @import("../arch/x86_64/io.zig");
const smp = @import("../arch/x86_64/smp.zig");
const tsc = @import("../time/tsc.zig");
const console = @import("../console.zig");

const WORKERS = 8;
const ROUNDS = 200;

const Worker = struct {
    self: ?*sched.Task = null,
    stale_block: u32 = 0,
    wrong_current: u32 = 0,
};

fn worker(arg: ?*anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(arg.?));
    while (@atomicLoad(?*sched.Task, &w.self, .acquire) == null) sched.sleepMs(1);
    const me: ?*anyopaque = @ptrCast(w.self.?);
    for (0..ROUNDS) |_| {
        io.cli();
        const block = percpu.this();
        io.sti();
        sched.sleepMs(1);
        if (@atomicLoad(?*anyopaque, &block.current, .acquire) != me) w.stale_block += 1;
        if (@as(?*anyopaque, @ptrCast(sched.currentTask())) != me) w.wrong_current += 1;
    }
}

pub fn run() void {
    var workers = [_]Worker{.{}} ** WORKERS;
    var tasks: [WORKERS]*sched.Task = undefined;
    var count: usize = 0;
    for (&workers, 0..) |*w, i| {
        tasks[i] = sched.spawn("current-probe", worker, w, .normal) catch break;
        @atomicStore(?*sched.Task, &w.self, tasks[i], .release);
        count += 1;
    }
    const me = sched.currentTask().?.tid;
    var stale: u32 = 0;
    var wrong: u32 = 0;
    for (tasks[0..count], workers[0..count]) |task, w| {
        const deadline = tsc.microsSinceBoot() + 30_000_000;
        while (sched.taskExitCode(task) == null) {
            if (tsc.microsSinceBoot() >= deadline) @panic("current-task probe worker did not exit");
            sched.sleepMs(5);
        }
        _ = sched.reapChild(task, me);
        stale += w.stale_block;
        wrong += w.wrong_current;
    }
    const reads = count * ROUNDS;
    // With one CPU nothing migrates and a stale block cannot be shown.
    const migrated = smp.cpusOnline() == 1 or stale > 0;
    if (count == WORKERS and wrong == 0 and migrated) {
        console.print("[pass] current task: {d} reads after resuming name the reader; {d} saved CPU blocks had gone stale\n", .{ reads, stale });
    } else {
        console.print("[FAIL] current task: {d}/{d} workers, {d} wrong current reads, {d} stale blocks\n", .{ count, WORKERS, wrong, stale });
    }
}
